-- Sika ERP v1.2
-- Run once in the Supabase SQL editor AFTER 0001 and 0002.
-- Adds: fixed asset management, CRM, sales force automation, groups of companies (subsidiaries),
-- global resource management, multi-currency project billing, and time and expense claims with approval.

-- =====================================================================
-- 1. New system accounts
-- =====================================================================
create or replace function public.seed_accounts_v12(cid uuid)
returns void language sql security definer set search_path = public as $$
  insert into accounts (company_id, code, name, type, system_key) values
  (cid,'1600','Fixed assets at cost','asset','fa_cost'),
  (cid,'1610','Accumulated depreciation','asset','fa_accdep'),
  (cid,'2240','Employee expense claims payable','liability','reimburse'),
  (cid,'4850','Gain or loss on asset disposal','income','disposal'),
  (cid,'6700','Depreciation','expense','depreciation'),
  (cid,'6800','Project travel and expenses','expense','project_exp')
  on conflict do nothing;
$$;
select public.seed_accounts_v12(id) from public.companies;

create or replace function public.create_company(p_name text, p_tin text default null, p_city text default null,
  p_phone text default null, p_email text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v uuid; v_email text;
begin
  if auth.uid() is null then raise exception 'Please sign in'; end if;
  if coalesce(trim(p_name),'') = '' then raise exception 'Company name is required'; end if;
  select email into v_email from auth.users where id = auth.uid();
  insert into companies (name, tin, city, phone, email) values (trim(p_name), p_tin, p_city, p_phone, coalesce(p_email, v_email))
  returning id into v;
  insert into memberships (company_id, user_id, email, role) values (v, auth.uid(), v_email, 'owner');
  perform seed_accounts(v);
  perform seed_accounts_v11(v);
  perform seed_accounts_v12(v);
  perform seed_leave_types(v);
  perform seed_asset_categories(v);
  return v;
end $$;

-- =====================================================================
-- 2. Fixed assets
-- =====================================================================
create table public.asset_categories (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  name text not null,
  method text not null default 'straight_line' check (method in ('straight_line','reducing_balance')),
  useful_life_months int check (useful_life_months > 0),
  annual_rate numeric(6,4) check (annual_rate > 0 and annual_rate <= 1),
  unique (company_id, name)
);

create or replace function public.seed_asset_categories(cid uuid)
returns void language sql security definer set search_path = public as $$
  insert into asset_categories (company_id, name, method, useful_life_months, annual_rate) values
  (cid,'Computers and IT equipment','straight_line',36,null),
  (cid,'Motor vehicles','reducing_balance',null,0.25),
  (cid,'Furniture and fittings','straight_line',60,null),
  (cid,'Plant and machinery','straight_line',120,null),
  (cid,'Office equipment','straight_line',60,null),
  (cid,'Buildings','straight_line',600,null)
  on conflict do nothing;
$$;
select public.seed_asset_categories(id) from public.companies;

create table public.assets (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  tag text,
  name text not null,
  category_id uuid references public.asset_categories(id),
  serial_no text,
  location text,
  custodian_id uuid references public.employees(id) on delete set null,
  supplier_id uuid references public.suppliers(id),
  purchase_date date not null,
  in_service_date date not null,
  depreciation_start date not null,
  cost numeric(14,2) not null check (cost > 0),
  salvage_value numeric(14,2) not null default 0 check (salvage_value >= 0),
  method text not null check (method in ('straight_line','reducing_balance')),
  useful_life_months int,
  annual_rate numeric(6,4),
  accumulated_depreciation numeric(14,2) not null default 0,
  last_depreciated date,                       -- month start of the last depreciated month
  status text not null default 'active' check (status in ('active','disposed','written_off')),
  disposal_date date,
  disposal_proceeds numeric(14,2),
  warranty_until date,
  notes text,
  journal_entry_id uuid references public.journal_entries(id),
  created_at timestamptz not null default now(),
  check (salvage_value < cost),
  check ((method = 'straight_line' and useful_life_months > 0) or (method = 'reducing_balance' and annual_rate > 0))
);

create table public.asset_depreciation (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  asset_id uuid not null references public.assets(id) on delete cascade,
  period date not null,
  amount numeric(14,2) not null,
  journal_entry_id uuid references public.journal_entries(id),
  unique (asset_id, period)
);

create table public.asset_movements (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  asset_id uuid not null references public.assets(id) on delete cascade,
  move_date date not null default current_date,
  from_location text, to_location text,
  from_custodian uuid references public.employees(id) on delete set null,
  to_custodian uuid references public.employees(id) on delete set null,
  note text,
  created_at timestamptz not null default now()
);

create table public.asset_maintenance (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  asset_id uuid not null references public.assets(id) on delete cascade,
  service_date date not null,
  description text not null,
  vendor text,
  cost numeric(14,2) not null default 0,
  next_due date,
  created_at timestamptz not null default now()
);

create or replace function public.number_asset() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.tag is null or new.tag = '' then new.tag := next_number(new.company_id, 'AST', 'AST-'); end if;
  return new;
end $$;
create trigger assets_number before insert on public.assets for each row execute function public.number_asset();

-- p_funding: bank | momo | cash (paid now), ap (owed to supplier), capital (owner contributed / opening),
--            none (already in the books, e.g. a supplier bill posted to 1600)
create or replace function public.register_asset(cid uuid, p jsonb, p_funding text)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_id uuid; v_cost numeric; v_open numeric; v_cat asset_categories; v_method text; v_life int; v_rate numeric;
  v_je uuid; v_credit uuid; v_purchase date; v_service date; v_start date;
begin
  perform require_member(cid, array['owner','admin','accountant']);
  v_cost := round((p->>'cost')::numeric, 2);
  v_open := round(coalesce((p->>'opening_depreciation')::numeric, 0), 2);
  if v_open < 0 or v_open >= v_cost then raise exception 'Opening depreciation must be less than the cost'; end if;
  if nullif(p->>'category_id','') is not null then
    select * into v_cat from asset_categories where id = (p->>'category_id')::uuid and company_id = cid;
  end if;
  v_method := coalesce(nullif(p->>'method',''), v_cat.method, 'straight_line');
  v_life := coalesce(nullif(p->>'useful_life_months','')::int, v_cat.useful_life_months);
  v_rate := coalesce(nullif(p->>'annual_rate','')::numeric, v_cat.annual_rate);
  v_purchase := (p->>'purchase_date')::date;
  v_service := coalesce(nullif(p->>'in_service_date','')::date, v_purchase);
  -- Opening assets start depreciating the month after registration; new assets from the in-service month.
  v_start := date_trunc('month', case when v_open > 0 then coalesce(nullif(p->>'depreciation_start','')::date, (current_date + interval '1 month')::date) else v_service end)::date;

  insert into assets (company_id, name, category_id, serial_no, location, custodian_id, supplier_id, purchase_date, in_service_date,
    depreciation_start, cost, salvage_value, method, useful_life_months, annual_rate, accumulated_depreciation, warranty_until, notes, tag)
  values (cid, p->>'name', v_cat.id, nullif(p->>'serial_no',''), nullif(p->>'location',''), nullif(p->>'custodian_id','')::uuid,
    nullif(p->>'supplier_id','')::uuid, v_purchase, v_service, v_start, v_cost, round(coalesce((p->>'salvage_value')::numeric,0),2),
    v_method, case when v_method = 'straight_line' then v_life end, case when v_method = 'reducing_balance' then v_rate end,
    v_open, nullif(p->>'warranty_until','')::date, nullif(p->>'notes',''), nullif(p->>'tag',''))
  returning id into v_id;

  if p_funding <> 'none' then
    v_credit := case p_funding when 'ap' then acct(cid,'ap') when 'capital' then acct(cid,'capital') else acct(cid, p_funding) end;
    v_je := post_journal(cid, v_purchase, 'Asset acquired: ' || (p->>'name'),
      jsonb_build_array(jl(acct(cid,'fa_cost'), v_cost, 0), jl(acct(cid,'fa_accdep'), 0, v_open), jl(v_credit, 0, v_cost - v_open)),
      'asset', v_id);
    update assets set journal_entry_id = v_je where id = v_id;
  elsif v_open > 0 then
    v_je := post_journal(cid, v_purchase, 'Opening depreciation: ' || (p->>'name'),
      jsonb_build_array(jl(acct(cid,'capital'), v_open, 0), jl(acct(cid,'fa_accdep'), 0, v_open)), 'asset', v_id);
  end if;
  insert into asset_movements (company_id, asset_id, move_date, to_location, to_custodian, note)
  values (cid, v_id, v_service, nullif(p->>'location',''), nullif(p->>'custodian_id','')::uuid, 'Placed in service');
  return v_id;
end $$;

-- Depreciates every active asset for each month up to p_period that has not been depreciated yet.
-- One journal entry per run, dated the last day of p_period.
create or replace function public.run_depreciation(cid uuid, p_period date)
returns numeric language plpgsql security definer set search_path = public as $$
declare
  a assets; m date; v_amt numeric; v_total numeric := 0; v_end date := date_trunc('month', p_period)::date;
  v_rows jsonb := '[]'::jsonb; v_je uuid; v_acc numeric; v_last date;
begin
  perform require_member(cid, array['owner','admin','accountant']);
  for a in select * from assets where company_id = cid and status = 'active' and depreciation_start <= v_end for update loop
    v_acc := a.accumulated_depreciation; v_last := a.last_depreciated;
    m := greatest(a.depreciation_start, coalesce((a.last_depreciated + interval '1 month')::date, a.depreciation_start));
    while m <= v_end loop
      v_amt := case when a.method = 'straight_line' then round((a.cost - a.salvage_value) / a.useful_life_months, 2)
                    else round((a.cost - v_acc) * a.annual_rate / 12, 2) end;
      v_amt := least(v_amt, a.cost - a.salvage_value - v_acc);
      exit when v_amt <= 0;
      v_rows := v_rows || jsonb_build_object('asset', a.id, 'period', m, 'amount', v_amt);
      v_acc := v_acc + v_amt; v_total := v_total + v_amt; v_last := m;
      m := (m + interval '1 month')::date;
    end loop;
    update assets set accumulated_depreciation = v_acc, last_depreciated = v_last where id = a.id;
  end loop;
  if v_total > 0 then
    v_je := post_journal(cid, (v_end + interval '1 month - 1 day')::date, 'Depreciation to ' || to_char(v_end, 'Mon YYYY'),
      jsonb_build_array(jl(acct(cid,'depreciation'), v_total, 0), jl(acct(cid,'fa_accdep'), 0, v_total)), 'depreciation', null);
    insert into asset_depreciation (company_id, asset_id, period, amount, journal_entry_id)
    select cid, (r->>'asset')::uuid, (r->>'period')::date, (r->>'amount')::numeric, v_je from jsonb_array_elements(v_rows) r;
  end if;
  return v_total;
end $$;

-- p_method: bank | momo | cash for sale proceeds; proceeds 0 = write-off.
create or replace function public.dispose_asset(p_asset uuid, p_date date, p_proceeds numeric, p_method text default 'bank')
returns numeric language plpgsql security definer set search_path = public as $$
declare a assets; v_nbv numeric; v_gain numeric; v_prior date;
begin
  select * into a from assets where id = p_asset;
  if not found then raise exception 'Asset not found'; end if;
  perform require_member(a.company_id, array['owner','admin','accountant']);
  if a.status <> 'active' then raise exception 'This asset has already been disposed of'; end if;
  v_prior := (date_trunc('month', p_date) - interval '1 month')::date;
  if v_prior >= a.depreciation_start then perform run_depreciation(a.company_id, v_prior); end if;
  select * into a from assets where id = p_asset for update;
  v_nbv := a.cost - a.accumulated_depreciation;
  v_gain := round(coalesce(p_proceeds,0) - v_nbv, 2);
  perform post_journal(a.company_id, p_date, (case when coalesce(p_proceeds,0) > 0 then 'Asset sold: ' else 'Asset written off: ' end) || a.name || ' (' || a.tag || ')',
    jsonb_build_array(
      jl(acct(a.company_id, p_method), coalesce(p_proceeds,0), 0),
      jl(acct(a.company_id,'fa_accdep'), a.accumulated_depreciation, 0),
      jl(acct(a.company_id,'fa_cost'), 0, a.cost),
      jl(acct(a.company_id,'disposal'), greatest(-v_gain,0), greatest(v_gain,0))),
    'asset_disposal', a.id);
  update assets set status = case when coalesce(p_proceeds,0) > 0 then 'disposed' else 'written_off' end,
    disposal_date = p_date, disposal_proceeds = coalesce(p_proceeds,0) where id = p_asset;
  return v_gain;
end $$;

create or replace function public.move_asset(p_asset uuid, p_date date, p_location text, p_custodian uuid, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare a assets;
begin
  select * into a from assets where id = p_asset for update;
  if not found then raise exception 'Asset not found'; end if;
  perform require_member(a.company_id, array['owner','admin','accountant','hr']);
  insert into asset_movements (company_id, asset_id, move_date, from_location, to_location, from_custodian, to_custodian, note)
  values (a.company_id, a.id, p_date, a.location, p_location, a.custodian_id, p_custodian, p_note);
  update assets set location = p_location, custodian_id = p_custodian where id = p_asset;
end $$;

-- =====================================================================
-- 3. CRM and sales force automation
-- =====================================================================
create table public.sales_territories (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  name text not null,
  region text,
  unique (company_id, name)
);

alter table public.customers add column if not exists owner_id uuid;
alter table public.customers add column if not exists territory_id uuid references public.sales_territories(id) on delete set null;
alter table public.invoices add column if not exists sales_rep_id uuid default auth.uid();

create table public.customer_contacts (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  customer_id uuid not null references public.customers(id) on delete cascade,
  name text not null, job_title text, phone text, email text,
  created_at timestamptz not null default now()
);

create table public.leads (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  name text not null,
  organisation text,
  phone text, email text, city text,
  source text,                               -- referral, walk-in, website, social media, event, cold call
  status text not null default 'new' check (status in ('new','contacted','qualified','unqualified','converted')),
  owner_id uuid default auth.uid(),
  territory_id uuid references public.sales_territories(id) on delete set null,
  estimated_value numeric(14,2),
  notes text,
  customer_id uuid references public.customers(id),
  created_at timestamptz not null default now()
);

create table public.opportunities (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  title text not null,
  customer_id uuid references public.customers(id),
  lead_id uuid references public.leads(id),
  stage text not null default 'prospecting' check (stage in ('prospecting','qualification','proposal','negotiation','won','lost')),
  amount numeric(14,2) not null default 0,
  currency text not null default 'GHS',
  probability int not null default 10 check (probability between 0 and 100),
  expected_close date,
  owner_id uuid default auth.uid(),
  lost_reason text,
  closed_at date,
  created_at timestamptz not null default now()
);
alter table public.sales_quotes add column if not exists opportunity_id uuid references public.opportunities(id) on delete set null;

create table public.crm_activities (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  kind text not null default 'call' check (kind in ('call','meeting','visit','email','whatsapp','task','note')),
  subject text not null,
  due_at timestamptz,
  done boolean not null default false,
  done_at timestamptz,
  outcome text,
  lead_id uuid references public.leads(id) on delete cascade,
  opportunity_id uuid references public.opportunities(id) on delete cascade,
  customer_id uuid references public.customers(id) on delete cascade,
  owner_id uuid default auth.uid(),
  latitude numeric(9,6), longitude numeric(9,6),   -- field visit check-in
  created_at timestamptz not null default now()
);

create table public.sales_targets (
  company_id uuid not null references public.companies(id) on delete cascade,
  user_id uuid not null,
  year int not null,
  month int not null check (month between 1 and 12),
  amount numeric(14,2) not null default 0,
  primary key (company_id, user_id, year, month)
);

create or replace function public.stage_probability(s text) returns int language sql immutable as $$
  select case s when 'prospecting' then 10 when 'qualification' then 25 when 'proposal' then 50
                when 'negotiation' then 75 when 'won' then 100 else 0 end;
$$;

create or replace function public.convert_lead(p_lead uuid, p_create_opportunity boolean default true)
returns uuid language plpgsql security definer set search_path = public as $$
declare l leads; v_cust uuid;
begin
  select * into l from leads where id = p_lead for update;
  if not found then raise exception 'Lead not found'; end if;
  perform require_member(l.company_id);
  if l.status = 'converted' then raise exception 'This lead is already a customer'; end if;
  insert into customers (company_id, name, phone, email, city, owner_id, territory_id)
  values (l.company_id, coalesce(nullif(l.organisation,''), l.name), l.phone, l.email, l.city, l.owner_id, l.territory_id)
  returning id into v_cust;
  if nullif(l.organisation,'') is not null then
    insert into customer_contacts (company_id, customer_id, name, phone, email) values (l.company_id, v_cust, l.name, l.phone, l.email);
  end if;
  if p_create_opportunity then
    insert into opportunities (company_id, title, customer_id, lead_id, stage, amount, probability, owner_id)
    values (l.company_id, coalesce(nullif(l.organisation,''), l.name) || ' — first order', v_cust, l.id, 'qualification',
            coalesce(l.estimated_value,0), 25, l.owner_id);
  end if;
  update leads set status = 'converted', customer_id = v_cust where id = p_lead;
  update crm_activities set customer_id = v_cust where lead_id = p_lead;
  return v_cust;
end $$;

-- Rep scorecard for a month. Managers see everyone; sales staff see themselves.
create or replace function public.sales_performance(cid uuid, p_year int, p_month int)
returns table (user_id uuid, email text, target numeric, invoiced numeric, pipeline numeric, weighted numeric,
               won int, lost int, activities_done int, visits int)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare v_mgr boolean; v_from date := make_date(p_year, p_month, 1); v_to date := (make_date(p_year, p_month, 1) + interval '1 month - 1 day')::date;
begin
  perform require_member(cid);
  v_mgr := has_role(cid, array['owner','admin','accountant']);
  return query
  select m.user_id, m.email,
    coalesce((select t.amount from sales_targets t where t.company_id = cid and t.user_id = m.user_id and t.year = p_year and t.month = p_month), 0)::numeric,
    coalesce((select sum(i.subtotal * i.exchange_rate - 0) from invoices i where i.company_id = cid and i.sales_rep_id = m.user_id
              and i.status <> 'draft' and i.invoice_date between v_from and v_to), 0)::numeric
      - coalesce((select sum(c.subtotal * c.exchange_rate) from credit_notes c join invoices i on i.id = c.invoice_id
              where c.company_id = cid and i.sales_rep_id = m.user_id and c.status = 'posted' and c.credit_date between v_from and v_to), 0)::numeric,
    coalesce((select sum(o.amount * coalesce((select rate from currencies x where x.company_id = cid and x.code = o.currency), 1))
              from opportunities o where o.company_id = cid and o.owner_id = m.user_id and o.stage not in ('won','lost')), 0)::numeric,
    coalesce((select sum(o.amount * o.probability / 100.0 * coalesce((select rate from currencies x where x.company_id = cid and x.code = o.currency), 1))
              from opportunities o where o.company_id = cid and o.owner_id = m.user_id and o.stage not in ('won','lost')), 0)::numeric,
    (select count(*) from opportunities o where o.company_id = cid and o.owner_id = m.user_id and o.stage = 'won' and o.closed_at between v_from and v_to)::int,
    (select count(*) from opportunities o where o.company_id = cid and o.owner_id = m.user_id and o.stage = 'lost' and o.closed_at between v_from and v_to)::int,
    (select count(*) from crm_activities a where a.company_id = cid and a.owner_id = m.user_id and a.done and a.done_at::date between v_from and v_to)::int,
    (select count(*) from crm_activities a where a.company_id = cid and a.owner_id = m.user_id and a.done and a.kind = 'visit' and a.done_at::date between v_from and v_to)::int
  from memberships m
  where m.company_id = cid and (v_mgr or m.user_id = auth.uid())
  order by m.email;
end $$;

-- =====================================================================
-- 4. Groups of companies (subsidiaries)
-- =====================================================================
create table public.company_groups (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);
alter table public.companies add column if not exists group_id uuid references public.company_groups(id) on delete set null;

create or replace function public.create_group(cid uuid, p_name text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  perform require_member(cid, array['owner','admin']);
  if (select group_id from companies where id = cid) is not null then raise exception 'This company is already in a group'; end if;
  insert into company_groups (name) values (p_name) returning id into v;
  update companies set group_id = v where id = cid;
  return v;
end $$;

-- Link another company you administer into the same group. You must be owner/admin of both.
create or replace function public.join_group(cid uuid, p_other uuid)
returns void language plpgsql security definer set search_path = public as $$
declare g uuid;
begin
  perform require_member(cid, array['owner','admin']);
  perform require_member(p_other, array['owner','admin']);
  select group_id into g from companies where id = cid;
  if g is null then raise exception 'Create a group for this company first'; end if;
  if (select group_id from companies where id = p_other) is not null then raise exception 'That company is already in a group'; end if;
  update companies set group_id = g where id = p_other;
end $$;

create or replace function public.leave_group(cid uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform require_member(cid, array['owner','admin']);
  update companies set group_id = null where id = cid;
end $$;

create or replace function public.group_companies(cid uuid)
returns table (id uuid, name text, city text, is_current boolean)
language sql stable security definer set search_path = public as $$
  select c.id, c.name, c.city, c.id = cid from companies c
   where is_member(cid) and (c.id = cid or (c.group_id is not null and c.group_id = (select group_id from companies where id = cid)))
   order by c.name;
$$;

create or replace function public.same_group(a uuid, b uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select a = b or exists (select 1 from companies x join companies y on x.group_id = y.group_id where x.id = a and y.id = b and x.group_id is not null);
$$;

-- =====================================================================
-- 5. Global resource management
-- =====================================================================
alter table public.employees add column if not exists skills text[] not null default '{}';
alter table public.employees add column if not exists location text;
alter table public.employees add column if not exists country text default 'Ghana';
alter table public.employees add column if not exists user_id uuid;
alter table public.employees add column if not exists cost_rate numeric(14,2);    -- internal cost per hour, GHS

create table public.project_assignments (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,       -- the project's company
  project_id uuid not null references public.projects(id) on delete cascade,
  employee_id uuid not null references public.employees(id) on delete cascade,
  employee_company_id uuid not null references public.companies(id) on delete cascade,
  role text,
  start_date date not null,
  end_date date,
  allocation_pct int not null default 100 check (allocation_pct between 1 and 100),
  bill_rate numeric(14,2),                     -- per hour, in the project's currency
  status text not null default 'confirmed' check (status in ('proposed','confirmed')),
  created_at timestamptz not null default now(),
  check (end_date is null or end_date >= start_date)
);

-- Managers search staff across every company in their group. Salaries are never returned.
create or replace function public.search_resources(cid uuid, p_skills text[], p_location text, p_start date, p_end date)
returns table (employee_id uuid, company_id uuid, company_name text, full_name text, job_title text, department text,
               skills text[], location text, country text, matched int, peak_booked int, available int, leave_days int)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare v_end date := least(coalesce(p_end, p_start + 30), p_start + 366);
begin
  perform require_member(cid, array['owner','admin','accountant','hr']);
  return query
  with staff as (
    select e.*, c.name as cname from employees e join companies c on c.id = e.company_id
     where e.status = 'active' and same_group(cid, e.company_id)
  ), scored as (
    select s.*,
      (select count(*) from unnest(coalesce(p_skills, '{}')) want where exists (select 1 from unnest(s.skills) have where have ilike '%' || want || '%'))::int as m,
      coalesce((select max(day_total) from (
         select sum(pa.allocation_pct) as day_total from generate_series(p_start, v_end, interval '1 day') d
           join project_assignments pa on pa.employee_id = s.id and d::date between pa.start_date and coalesce(pa.end_date, '9999-12-31')
          group by d) t), 0)::int as booked,
      coalesce((select sum(greatest(0, least(r.end_date, v_end) - greatest(r.start_date, p_start) + 1)) from leave_requests r
                 where r.employee_id = s.id and r.status = 'approved' and r.start_date <= v_end and r.end_date >= p_start), 0)::int as lv
    from staff s
  )
  select sc.id, sc.company_id, sc.cname, sc.full_name, sc.job_title, sc.department, sc.skills, sc.location, sc.country,
         sc.m, sc.booked, greatest(0, 100 - sc.booked), sc.lv
    from scored sc
   where (coalesce(array_length(p_skills,1),0) = 0 or sc.m > 0)
     and (coalesce(p_location,'') = '' or sc.location ilike '%' || p_location || '%' or sc.country ilike '%' || p_location || '%')
   order by sc.m desc, greatest(0, 100 - sc.booked) desc, sc.full_name;
end $$;

create or replace function public.assign_resource(p_project uuid, p_employee uuid, p_start date, p_end date,
  p_pct int, p_role text default null, p_bill_rate numeric default null, p_status text default 'confirmed')
returns uuid language plpgsql security definer set search_path = public as $$
declare pr projects; e employees; v uuid;
begin
  select * into pr from projects where id = p_project;
  if not found then raise exception 'Project not found'; end if;
  perform require_member(pr.company_id, array['owner','admin','accountant','hr']);
  select * into e from employees where id = p_employee;
  if not found or not same_group(pr.company_id, e.company_id) then raise exception 'That employee is not in your group of companies'; end if;
  insert into project_assignments (company_id, project_id, employee_id, employee_company_id, role, start_date, end_date, allocation_pct, bill_rate, status)
  values (pr.company_id, p_project, p_employee, e.company_id, p_role, p_start, p_end, p_pct, p_bill_rate, p_status)
  returning id into v;
  return v;
end $$;

-- Names (no pay data) of active staff across the group, for showing who logged time or expenses.
create or replace function public.group_employee_names(cid uuid)
returns table (id uuid, company_id uuid, full_name text, job_title text)
language sql stable security definer set search_path = public as $$
  select e.id, e.company_id, e.full_name, e.job_title from employees e
   where is_member(cid) and same_group(cid, e.company_id) order by e.full_name;
$$;

-- Assignment list with employee names, for the project's company or the employee's company.
create or replace function public.project_team(p_project uuid)
returns table (id uuid, employee_id uuid, full_name text, job_title text, company_name text, role text, start_date date, end_date date,
               allocation_pct int, bill_rate numeric, status text)
language sql stable security definer set search_path = public as $$
  select pa.id, e.id, e.full_name, e.job_title, c.name, pa.role, pa.start_date, pa.end_date, pa.allocation_pct, pa.bill_rate, pa.status
    from project_assignments pa join employees e on e.id = pa.employee_id join companies c on c.id = pa.employee_company_id
   where pa.project_id = p_project and (is_member(pa.company_id) or is_member(pa.employee_company_id))
   order by pa.start_date, e.full_name;
$$;

-- =====================================================================
-- 6. Projects in any currency; time and expenses with approval
-- =====================================================================
alter table public.projects add column if not exists currency text not null default 'GHS';
alter table public.projects add column if not exists location text;
alter table public.projects add column if not exists country text;

alter table public.timesheets add column if not exists status text not null default 'approved'
  check (status in ('submitted','approved','rejected'));
alter table public.timesheets add column if not exists bill_rate numeric(14,2);
alter table public.timesheets add column if not exists submitted_by uuid;
alter table public.timesheets add column if not exists approved_by uuid;
alter table public.timesheets add column if not exists invoice_id uuid references public.invoices(id) on delete set null;

create table public.expense_claims (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,   -- company bearing the cost
  employee_id uuid not null references public.employees(id),
  submitted_by uuid default auth.uid(),
  project_id uuid references public.projects(id) on delete set null,
  expense_date date not null,
  account_id uuid references public.accounts(id),
  description text not null,
  merchant text,
  currency text not null default 'GHS',
  amount numeric(14,2) not null check (amount > 0),
  exchange_rate numeric(14,6) not null default 1 check (exchange_rate > 0),     -- GHS per 1 unit
  amount_home numeric(14,2) not null,
  billable boolean not null default false,
  receipt_path text,
  status text not null default 'submitted' check (status in ('submitted','approved','rejected','reimbursed')),
  reject_reason text,
  approved_by uuid,
  journal_entry_id uuid references public.journal_entries(id),
  invoice_id uuid references public.invoices(id) on delete set null,
  created_at timestamptz not null default now()
);

-- Employee records linked to the signed-in user, in any company.
create or replace function public.my_employee_ids() returns setof uuid
language sql stable security definer set search_path = public as $$
  select id from employees where user_id = auth.uid() and status = 'active';
$$;

create or replace function public.link_employee_user(p_employee uuid, p_email text)
returns void language plpgsql security definer set search_path = public as $$
declare e employees; v_user uuid;
begin
  select * into e from employees where id = p_employee;
  if not found then raise exception 'Employee not found'; end if;
  perform require_member(e.company_id, array['owner','admin','hr']);
  if coalesce(trim(p_email),'') = '' then update employees set user_id = null where id = p_employee; return; end if;
  select id into v_user from auth.users where lower(email) = lower(trim(p_email));
  if v_user is null then raise exception 'No account uses %. Ask them to create a Sika ERP account first.', p_email; end if;
  update employees set user_id = v_user where id = p_employee;
end $$;

-- Everything the mobile "My work" screen needs in one call.
create or replace function public.my_work()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'employees', coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'company_id', e.company_id, 'company', c.name, 'full_name', e.full_name))
                   from employees e join companies c on c.id = e.company_id where e.user_id = auth.uid() and e.status = 'active'), '[]'),
    'projects', coalesce((select jsonb_agg(distinct jsonb_build_object('id', p.id, 'name', p.name, 'company_id', p.company_id, 'company', c.name, 'currency', p.currency))
                   from projects p join companies c on c.id = p.company_id
                  where p.status in ('planned','active') and (
                        exists (select 1 from project_assignments pa join employees e on e.id = pa.employee_id
                                 where pa.project_id = p.id and e.user_id = auth.uid() and (pa.end_date is null or pa.end_date >= current_date - 31))
                     or exists (select 1 from employees e where e.user_id = auth.uid() and e.company_id = p.company_id))), '[]'),
    'tasks', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'project_id', t.project_id, 'title', t.title))
                   from tasks t where t.status <> 'done' and t.project_id in (
                     select p.id from projects p where exists (select 1 from project_assignments pa join employees e on e.id = pa.employee_id where pa.project_id = p.id and e.user_id = auth.uid())
                        or exists (select 1 from employees e where e.user_id = auth.uid() and e.company_id = p.company_id))), '[]'),
    'time', coalesce((select jsonb_agg(x order by x->>'work_date' desc) from (
                   select jsonb_build_object('id', t.id, 'work_date', t.work_date, 'hours', t.hours, 'project', p.name, 'status', t.status, 'note', t.note, 'billable', t.billable) x
                     from timesheets t join projects p on p.id = t.project_id join employees e on e.id = t.employee_id
                    where e.user_id = auth.uid() and t.work_date >= current_date - 62 order by t.work_date desc limit 60) q), '[]'),
    'expenses', coalesce((select jsonb_agg(x order by x->>'expense_date' desc) from (
                   select jsonb_build_object('id', x.id, 'expense_date', x.expense_date, 'description', x.description, 'currency', x.currency, 'amount', x.amount,
                          'amount_home', x.amount_home, 'status', x.status, 'reject_reason', x.reject_reason, 'project', p.name, 'company', c.name) x
                     from expense_claims x join employees e on e.id = x.employee_id join companies c on c.id = x.company_id left join projects p on p.id = x.project_id
                    where e.user_id = auth.uid() order by x.expense_date desc limit 60) q), '[]'),
    'currencies', coalesce((select jsonb_agg(distinct jsonb_build_object('company_id', cu.company_id, 'code', cu.code, 'rate', cu.rate))
                   from currencies cu where cu.company_id in (select company_id from employees where user_id = auth.uid())
                      or cu.company_id in (select pa.company_id from project_assignments pa join employees e on e.id = pa.employee_id where e.user_id = auth.uid())), '[]'),
    'categories', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'company_id', a.company_id, 'name', a.name))
                   from accounts a where a.type = 'expense' and a.active and coalesce(a.system_key,'') not in ('cogs','stock_adj','salaries','employer_ssnit','employer_tier3','depreciation')
                     and (a.company_id in (select company_id from employees where user_id = auth.uid())
                       or a.company_id in (select pa.company_id from project_assignments pa join employees e on e.id = pa.employee_id where e.user_id = auth.uid()))), '[]')
  );
$$;

-- Which of my employee records may log against this project?
create or replace function public.my_employee_for_project(p_project uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select e.id from employees e join projects p on p.id = p_project
   where e.user_id = auth.uid() and e.status = 'active'
     and (e.company_id = p.company_id or exists (select 1 from project_assignments pa where pa.project_id = p.id and pa.employee_id = e.id))
   order by (e.company_id = p.company_id) desc limit 1;
$$;

create or replace function public.submit_time(p_project uuid, p_date date, p_hours numeric, p_task uuid default null,
  p_note text default null, p_billable boolean default true)
returns uuid language plpgsql security definer set search_path = public as $$
declare pr projects; v_emp uuid; v_rate numeric; v uuid;
begin
  if auth.uid() is null then raise exception 'Please sign in'; end if;
  select * into pr from projects where id = p_project;
  if not found then raise exception 'Project not found'; end if;
  v_emp := my_employee_for_project(p_project);
  if v_emp is null then raise exception 'You are not on this project. Ask your manager to assign you, or to link your login to your employee record.'; end if;
  if p_hours <= 0 or p_hours > 24 then raise exception 'Hours must be between 0 and 24'; end if;
  select coalesce(max(bill_rate) filter (where bill_rate is not null), null) into v_rate from project_assignments
   where project_id = p_project and employee_id = v_emp and p_date between start_date and coalesce(end_date, '9999-12-31');
  insert into timesheets (company_id, project_id, task_id, employee_id, work_date, hours, billable, note, status, bill_rate, submitted_by)
  values (pr.company_id, p_project, p_task, v_emp, p_date, p_hours, p_billable, p_note, 'submitted', coalesce(v_rate, pr.hourly_rate), auth.uid())
  returning id into v;
  return v;
end $$;

-- Submit an expense. Cost sits with the project's company, or the employee's own company when there is no project.
create or replace function public.submit_expense(p jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_emp uuid; v_cid uuid; v_proj uuid := nullif(p->>'project_id','')::uuid; v_rate numeric; v_amt numeric; v_ccy text; v uuid; v_acct uuid;
begin
  if auth.uid() is null then raise exception 'Please sign in'; end if;
  if v_proj is not null then
    v_emp := my_employee_for_project(v_proj);
    select company_id into v_cid from projects where id = v_proj;
    if v_emp is null then raise exception 'You are not on this project'; end if;
  else
    select id, company_id into v_emp, v_cid from employees where user_id = auth.uid() and status = 'active'
     and (nullif(p->>'company_id','') is null or company_id = (p->>'company_id')::uuid) order by created_at limit 1;
    if v_emp is null then raise exception 'Your login is not linked to an employee record. Ask HR to link it.'; end if;
  end if;
  v_ccy := upper(coalesce(nullif(p->>'currency',''), 'GHS'));
  v_amt := round((p->>'amount')::numeric, 2);
  v_rate := case when v_ccy = 'GHS' then 1 else coalesce(nullif(p->>'exchange_rate','')::numeric, (select rate from currencies where company_id = v_cid and code = v_ccy)) end;
  if v_rate is null or v_rate <= 0 then raise exception 'Enter the exchange rate for %', v_ccy; end if;
  v_acct := nullif(p->>'account_id','')::uuid;
  if v_acct is not null and not exists (select 1 from accounts where id = v_acct and company_id = v_cid and type = 'expense') then
    v_acct := null;
  end if;
  insert into expense_claims (company_id, employee_id, project_id, expense_date, account_id, description, merchant, currency, amount, exchange_rate,
                              amount_home, billable, receipt_path)
  values (v_cid, v_emp, v_proj, (p->>'expense_date')::date, coalesce(v_acct, acct(v_cid, 'project_exp')), p->>'description', nullif(p->>'merchant',''),
          v_ccy, v_amt, v_rate, round(v_amt * v_rate, 2), coalesce((p->>'billable')::boolean, false), nullif(p->>'receipt_path',''))
  returning id into v;
  return v;
end $$;

create or replace function public.decide_time(p_ids uuid[], p_approve boolean)
returns int language plpgsql security definer set search_path = public as $$
declare v int := 0; t record;
begin
  for t in select * from timesheets where id = any(p_ids) and status = 'submitted' for update loop
    perform require_member(t.company_id, array['owner','admin','accountant','hr']);
    update timesheets set status = case when p_approve then 'approved' else 'rejected' end, approved_by = auth.uid() where id = t.id;
    v := v + 1;
  end loop;
  return v;
end $$;

create or replace function public.decide_expense(p_id uuid, p_approve boolean, p_reason text default null)
returns void language plpgsql security definer set search_path = public as $$
declare x expense_claims; v_je uuid; e employees;
begin
  select * into x from expense_claims where id = p_id for update;
  if not found then raise exception 'Expense not found'; end if;
  perform require_member(x.company_id, array['owner','admin','accountant']);
  if x.status <> 'submitted' then raise exception 'This expense has already been decided'; end if;
  if not p_approve then
    update expense_claims set status = 'rejected', reject_reason = p_reason, approved_by = auth.uid() where id = p_id;
    return;
  end if;
  select * into e from employees where id = x.employee_id;
  v_je := post_journal(x.company_id, x.expense_date, 'Expense claim: ' || e.full_name || ' — ' || x.description ||
            case when x.currency <> 'GHS' then ' (' || x.currency || ' ' || x.amount || ' at ' || x.exchange_rate || ')' else '' end,
    jsonb_build_array(jl(x.account_id, x.amount_home, 0), jl(acct(x.company_id,'reimburse'), 0, x.amount_home)), 'expense', x.id);
  update expense_claims set status = 'approved', approved_by = auth.uid(), journal_entry_id = v_je where id = p_id;
end $$;

create or replace function public.reimburse_employee(cid uuid, p_employee uuid, p_method text, p_date date)
returns numeric language plpgsql security definer set search_path = public as $$
declare v numeric; e employees;
begin
  perform require_member(cid, array['owner','admin','accountant']);
  select coalesce(sum(amount_home),0) into v from expense_claims where company_id = cid and employee_id = p_employee and status = 'approved';
  if v <= 0 then raise exception 'Nothing approved to reimburse'; end if;
  select * into e from employees where id = p_employee;
  perform post_journal(cid, p_date, 'Expenses reimbursed to ' || e.full_name,
    jsonb_build_array(jl(acct(cid,'reimburse'), v, 0), jl(acct(cid, p_method), 0, v)), 'reimbursement', p_employee);
  update expense_claims set status = 'reimbursed' where company_id = cid and employee_id = p_employee and status = 'approved';
  return v;
end $$;

-- Bill a project's approved, unbilled time and billable expenses in the project's currency.
create or replace function public.invoice_project(p_project uuid, p_to date default current_date)
returns uuid language plpgsql security definer set search_path = public as $$
declare pr projects; v_rate numeric; v_inv uuid; r record; i int := 0;
begin
  select * into pr from projects where id = p_project;
  if not found then raise exception 'Project not found'; end if;
  perform require_member(pr.company_id, array['owner','admin','accountant','sales']);
  if pr.customer_id is null then raise exception 'Set a client on this project before invoicing'; end if;
  v_rate := case when pr.currency = 'GHS' then 1 else (select rate from currencies where company_id = pr.company_id and code = pr.currency) end;
  if v_rate is null then raise exception 'Add % under Settings → Foreign currencies first', pr.currency; end if;
  if not exists (select 1 from timesheets where project_id = p_project and status = 'approved' and billable and invoice_id is null and work_date <= p_to)
     and not exists (select 1 from expense_claims where project_id = p_project and status in ('approved','reimbursed') and billable and invoice_id is null and expense_date <= p_to) then
    raise exception 'There is no approved, unbilled time or billable expense up to %', p_to;
  end if;

  insert into invoices (company_id, customer_id, project_id, invoice_date, currency, exchange_rate, notes)
  values (pr.company_id, pr.customer_id, p_project, current_date, pr.currency, v_rate, 'Project: ' || pr.name || ', work to ' || to_char(p_to, 'DD Mon YYYY'))
  returning id into v_inv;

  for r in select e.full_name, coalesce(t.bill_rate, pr.hourly_rate) as rate, sum(t.hours) as hrs, min(t.work_date) as d1, max(t.work_date) as d2
             from timesheets t join employees e on e.id = t.employee_id
            where t.project_id = p_project and t.status = 'approved' and t.billable and t.invoice_id is null and t.work_date <= p_to
            group by e.full_name, coalesce(t.bill_rate, pr.hourly_rate) order by e.full_name loop
    insert into invoice_lines (invoice_id, company_id, description, qty, unit_price, taxable, sort)
    values (v_inv, pr.company_id, 'Professional time: ' || r.full_name || ' (' || to_char(r.d1,'DD Mon') || '–' || to_char(r.d2,'DD Mon YYYY') || ')', r.hrs, coalesce(r.rate,0), true, i);
    i := i + 1;
  end loop;
  for r in select x.* from expense_claims x where x.project_id = p_project and x.status in ('approved','reimbursed') and x.billable and x.invoice_id is null and x.expense_date <= p_to order by x.expense_date loop
    insert into invoice_lines (invoice_id, company_id, description, qty, unit_price, taxable, sort)
    values (v_inv, pr.company_id, 'Expense: ' || r.description || ' (' || r.currency || ' ' || to_char(r.amount, 'FM999,999,990.00') || ', ' || to_char(r.expense_date,'DD Mon YYYY') || ')',
            1, round(r.amount_home / v_rate, 2), true, i);
    i := i + 1;
  end loop;
  update timesheets set invoice_id = v_inv where project_id = p_project and status = 'approved' and billable and invoice_id is null and work_date <= p_to;
  update expense_claims set invoice_id = v_inv where project_id = p_project and status in ('approved','reimbursed') and billable and invoice_id is null and expense_date <= p_to;
  return v_inv;
end $$;

-- Project profitability in GHS: billed vs cost of time (employee cost rate) and expenses.
create or replace function public.project_financials(p_project uuid)
returns table (hours numeric, approved_hours numeric, unbilled_hours numeric, time_cost numeric, expenses numeric, invoiced numeric)
language sql stable security definer set search_path = public as $$
  select
    coalesce((select sum(hours) from timesheets where project_id = p_project), 0),
    coalesce((select sum(hours) from timesheets where project_id = p_project and status = 'approved'), 0),
    coalesce((select sum(hours) from timesheets where project_id = p_project and status = 'approved' and billable and invoice_id is null), 0),
    coalesce((select sum(t.hours * coalesce(e.cost_rate,0)) from timesheets t join employees e on e.id = t.employee_id where t.project_id = p_project and t.status = 'approved'), 0),
    coalesce((select sum(amount_home) from expense_claims where project_id = p_project and status in ('approved','reimbursed')), 0),
    coalesce((select sum(subtotal * exchange_rate) from invoices where project_id = p_project and status <> 'draft'), 0)
  where exists (select 1 from projects p where p.id = p_project and is_member(p.company_id));
$$;

-- =====================================================================
-- 7. Receipt photos (Supabase Storage). Skipped where storage is not present.
-- =====================================================================
do $$ begin
  if exists (select 1 from information_schema.schemata where schema_name = 'storage') then
    execute $q$insert into storage.buckets (id, name, public) values ('receipts', 'receipts', false) on conflict (id) do nothing$q$;
    execute $q$create policy "receipts: upload to own folder" on storage.objects for insert to authenticated
      with check (bucket_id = 'receipts' and (storage.foldername(name))[1] = auth.uid()::text)$q$;
    execute $q$create policy "receipts: owner and approvers read" on storage.objects for select to authenticated
      using (bucket_id = 'receipts' and ((storage.foldername(name))[1] = auth.uid()::text
        or exists (select 1 from public.expense_claims x where x.receipt_path = name and public.has_role(x.company_id, array['owner','admin','accountant','hr']))))$q$;
  end if;
end $$;

-- =====================================================================
-- 8. Row-level security
-- =====================================================================
do $$ declare t text; begin
  foreach t in array array['sales_territories','customer_contacts','leads','opportunities','crm_activities','asset_categories','asset_maintenance'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy "members read" on public.%I for select using (is_member(company_id))', t);
    execute format('create policy "members insert" on public.%I for insert with check (is_member(company_id))', t);
    execute format('create policy "members update" on public.%I for update using (is_member(company_id))', t);
    execute format('create policy "members delete" on public.%I for delete using (is_member(company_id))', t);
  end loop;
end $$;

alter table public.assets enable row level security;
create policy "members read assets" on public.assets for select using (is_member(company_id));
create policy "accountants edit asset details" on public.assets for update
  using (has_role(company_id, array['owner','admin','accountant'])) with check (has_role(company_id, array['owner','admin','accountant']));

create or replace function public.protect_asset_figures() returns trigger language plpgsql as $$
begin
  if current_user in ('authenticated','anon') and (new.cost is distinct from old.cost or new.accumulated_depreciation is distinct from old.accumulated_depreciation
     or new.status is distinct from old.status or new.last_depreciated is distinct from old.last_depreciated or new.salvage_value is distinct from old.salvage_value
     or new.method is distinct from old.method or new.useful_life_months is distinct from old.useful_life_months or new.annual_rate is distinct from old.annual_rate) then
    raise exception 'Cost, depreciation and status change only through register, depreciation and disposal';
  end if;
  return new;
end $$;
create trigger assets_protect before update on public.assets for each row execute function public.protect_asset_figures();

alter table public.asset_depreciation enable row level security;
create policy "members read" on public.asset_depreciation for select using (is_member(company_id));
alter table public.asset_movements enable row level security;
create policy "members read" on public.asset_movements for select using (is_member(company_id));

alter table public.sales_targets enable row level security;
create policy "members read targets" on public.sales_targets for select using (is_member(company_id));
create policy "managers set targets" on public.sales_targets for all
  using (has_role(company_id, array['owner','admin','accountant'])) with check (has_role(company_id, array['owner','admin','accountant']));

alter table public.company_groups enable row level security;
create policy "group members read" on public.company_groups for select
  using (exists (select 1 from companies c where c.group_id = company_groups.id and is_member(c.id)));

alter table public.project_assignments enable row level security;
create policy "both companies read" on public.project_assignments for select using (is_member(company_id) or is_member(employee_company_id));
create policy "managers change" on public.project_assignments for update using (has_role(company_id, array['owner','admin','accountant','hr']));
create policy "managers remove" on public.project_assignments for delete using (has_role(company_id, array['owner','admin','accountant','hr']));

-- Timesheets: staff submit; managers approve. Replaces the open policies from 0001.
drop policy if exists "members insert" on public.timesheets;
drop policy if exists "members update" on public.timesheets;
drop policy if exists "members delete" on public.timesheets;
drop policy if exists "members read" on public.timesheets;
create policy "read own company or own time" on public.timesheets for select
  using (is_member(company_id) or employee_id in (select my_employee_ids()));
create policy "managers log approved time" on public.timesheets for insert
  with check (has_role(company_id, array['owner','admin','accountant','hr']) or (is_member(company_id) and status = 'submitted'));
create policy "managers edit time" on public.timesheets for update using (has_role(company_id, array['owner','admin','accountant','hr']));
create policy "managers or owner delete unbilled time" on public.timesheets for delete
  using (invoice_id is null and (has_role(company_id, array['owner','admin','accountant','hr'])
         or (status = 'submitted' and employee_id in (select my_employee_ids()))));

alter table public.expense_claims enable row level security;
create policy "approvers and claimant read" on public.expense_claims for select
  using (has_role(company_id, array['owner','admin','accountant','hr']) or employee_id in (select my_employee_ids()));
create policy "claimant withdraws submitted" on public.expense_claims for delete
  using (status = 'submitted' and employee_id in (select my_employee_ids()));

-- Function permissions
revoke execute on all functions in schema public from public, anon;
grant execute on all functions in schema public to authenticated;
revoke execute on function public.post_journal(uuid,date,text,jsonb,text,uuid) from authenticated;
revoke execute on function public.seed_accounts(uuid) from authenticated;
revoke execute on function public.seed_accounts_v11(uuid) from authenticated;
revoke execute on function public.seed_accounts_v12(uuid) from authenticated;
revoke execute on function public.seed_leave_types(uuid) from authenticated;
revoke execute on function public.seed_asset_categories(uuid) from authenticated;
revoke execute on function public.next_number(uuid,text,text) from authenticated;
