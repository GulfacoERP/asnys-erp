-- Asnys ERP: new installation, part1 of 3.
-- Contains 0001_asnys.sql, 0002_asnys_v1_1.sql, 0003_asnys_v1_2.sql, 0004_asnys_v1_3.sql, 0005_asnys_v1_4.sql. Run part 1, then part 2, then part 3, once each, in a new Supabase project.


-- ======================================================================
-- 0001_asnys.sql
-- ======================================================================
-- Sika ERP database
-- Run once in the Supabase SQL editor (or `supabase db push`).
-- Multi-company: every business row carries company_id and is protected by row-level security.
-- Money postings (invoices, bills, payments, payroll, stock) happen only through the
-- SECURITY DEFINER functions at the bottom, which always write balanced journal entries.


-- =====================================================================
-- 1. Companies, members, roles
-- =====================================================================
create table public.companies (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  tin text,
  address text,
  city text,
  phone text,
  email text,
  bank_details text,
  momo_details text,
  currency text not null default 'GHS',
  created_at timestamptz not null default now()
);

create table public.memberships (
  company_id uuid not null references public.companies(id) on delete cascade,
  user_id uuid not null,
  email text,
  role text not null default 'staff'
    check (role in ('owner','admin','accountant','sales','hr','staff')),
  created_at timestamptz not null default now(),
  primary key (company_id, user_id)
);

create or replace function public.is_member(cid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from memberships where company_id = cid and user_id = auth.uid());
$$;

create or replace function public.has_role(cid uuid, roles text[])
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from memberships
                 where company_id = cid and user_id = auth.uid() and role = any(roles));
$$;

-- =====================================================================
-- 2. Statutory settings (shared by all companies, dated)
-- =====================================================================
create table public.tax_rates (
  code text not null,               -- VAT, NHIL, GETFUND
  name text not null,
  rate numeric(8,5) not null,
  effective_from date not null,
  effective_to date,
  primary key (code, effective_from)
);

-- VAT Act, 2025 (Act 1151), in force 1 January 2026: all three on the same taxable value.
insert into public.tax_rates values
  ('VAT','VAT',0.15,'2026-01-01',null),
  ('NHIL','NHIL',0.025,'2026-01-01',null),
  ('GETFUND','GETFund levy',0.025,'2026-01-01',null);

create table public.paye_bands (
  effective_from date not null,
  seq int not null,
  width numeric(14,2),              -- null = everything above
  rate numeric(6,4) not null,
  primary key (effective_from, seq)
);

-- Income Tax (Amendment) Act, 2026 (Act 1178), monthly resident bands, in force 1 September 2026.
insert into public.paye_bands values
  ('2026-09-01',1,588,0),
  ('2026-09-01',2,80,0.05),
  ('2026-09-01',3,100,0.10),
  ('2026-09-01',4,2900,0.175),
  ('2026-09-01',5,16000,0.25),
  ('2026-09-01',6,30332,0.30),
  ('2026-09-01',7,null,0.35);

create table public.statutory_rates (
  code text not null,               -- SSNIT_EMPLOYEE, SSNIT_EMPLOYER, TIER2
  rate numeric(8,5) not null,
  effective_from date not null,
  primary key (code, effective_from)
);
insert into public.statutory_rates values
  ('SSNIT_EMPLOYEE',0.055,'2015-01-01'),
  ('SSNIT_EMPLOYER',0.13,'2015-01-01'),
  ('TIER2',0.05,'2015-01-01');

create or replace function public.tax_rate(p_code text, p_date date)
returns numeric language sql stable set search_path = public as $$
  select rate from tax_rates
   where code = p_code and effective_from <= p_date
     and (effective_to is null or effective_to >= p_date)
   order by effective_from desc limit 1;
$$;

create or replace function public.stat_rate(p_code text, p_date date)
returns numeric language sql stable set search_path = public as $$
  select rate from statutory_rates
   where code = p_code and effective_from <= p_date
   order by effective_from desc limit 1;
$$;

create or replace function public.compute_paye(p_chargeable numeric, p_date date)
returns numeric language plpgsql stable set search_path = public as $$
declare
  v_from date;
  v_left numeric := greatest(coalesce(p_chargeable,0),0);
  v_tax numeric := 0;
  v_slice numeric;
  b record;
begin
  select max(effective_from) into v_from from paye_bands where effective_from <= p_date;
  if v_from is null then
    raise exception 'No PAYE table covers %. Add the bands for that period in paye_bands.', p_date;
  end if;
  for b in select * from paye_bands where effective_from = v_from order by seq loop
    exit when v_left <= 0;
    v_slice := case when b.width is null then v_left else least(v_left, b.width) end;
    v_tax := v_tax + v_slice * b.rate;
    v_left := v_left - v_slice;
  end loop;
  return round(v_tax, 2);
end $$;

-- =====================================================================
-- 3. Accounting core
-- =====================================================================
create table public.accounts (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  code text not null,
  name text not null,
  type text not null check (type in ('asset','liability','equity','income','expense')),
  system_key text,
  active boolean not null default true,
  unique (company_id, code),
  unique (company_id, system_key)
);

create table public.number_sequences (
  company_id uuid not null references public.companies(id) on delete cascade,
  key text not null,
  next_value int not null default 1,
  primary key (company_id, key)
);

create table public.journal_entries (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  entry_no text not null,
  entry_date date not null,
  memo text,
  source_type text,
  source_id uuid,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);

create table public.journal_lines (
  id uuid primary key default gen_random_uuid(),
  entry_id uuid not null references public.journal_entries(id) on delete cascade,
  company_id uuid not null references public.companies(id) on delete cascade,
  account_id uuid not null references public.accounts(id),
  debit numeric(14,2) not null default 0 check (debit >= 0),
  credit numeric(14,2) not null default 0 check (credit >= 0)
);
create index on public.journal_lines (company_id, account_id);
create index on public.journal_entries (company_id, entry_date);

create table public.audit_log (
  id bigserial primary key,
  company_id uuid,
  user_id uuid default auth.uid(),
  action text not null,
  detail jsonb,
  created_at timestamptz not null default now()
);

-- =====================================================================
-- 4. Sales, purchasing, inventory
-- =====================================================================
create table public.customers (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  name text not null,
  phone text, email text, tin text, address text, city text,
  created_at timestamptz not null default now()
);

create table public.suppliers (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  name text not null,
  phone text, email text, tin text, address text, city text,
  created_at timestamptz not null default now()
);

create table public.products (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  sku text not null,
  name text not null,
  unit text not null default 'each',
  price numeric(14,2) not null default 0,
  cost numeric(14,4) not null default 0,       -- weighted average cost
  stock_qty numeric(14,3) not null default 0,
  reorder_level numeric(14,3) not null default 0,
  taxable boolean not null default true,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (company_id, sku)
);

create table public.stock_moves (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  product_id uuid not null references public.products(id),
  move_date date not null,
  qty numeric(14,3) not null,                  -- + in, - out
  unit_cost numeric(14,4) not null,
  reason text not null,
  ref_type text, ref_id uuid,
  created_at timestamptz not null default now()
);

create table public.invoices (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  number text,
  customer_id uuid not null references public.customers(id),
  project_id uuid,
  invoice_date date not null default current_date,
  due_date date,
  status text not null default 'draft' check (status in ('draft','posted','paid')),
  subtotal numeric(14,2) not null default 0,
  vat numeric(14,2) not null default 0,
  nhil numeric(14,2) not null default 0,
  getfund numeric(14,2) not null default 0,
  total numeric(14,2) not null default 0,
  amount_paid numeric(14,2) not null default 0,
  notes text,
  journal_entry_id uuid references public.journal_entries(id),
  created_at timestamptz not null default now()
);

create table public.invoice_lines (
  id uuid primary key default gen_random_uuid(),
  invoice_id uuid not null references public.invoices(id) on delete cascade,
  company_id uuid not null references public.companies(id) on delete cascade,
  product_id uuid references public.products(id),
  description text not null,
  qty numeric(14,3) not null check (qty > 0),
  unit_price numeric(14,2) not null check (unit_price >= 0),
  taxable boolean not null default true,
  sort int not null default 0
);

create table public.payments (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  invoice_id uuid not null references public.invoices(id),
  payment_date date not null,
  amount numeric(14,2) not null check (amount > 0),
  method text not null check (method in ('cash','momo','bank')),
  reference text,
  journal_entry_id uuid references public.journal_entries(id),
  created_at timestamptz not null default now()
);

create table public.bills (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  number text,
  supplier_id uuid not null references public.suppliers(id),
  supplier_ref text,
  bill_date date not null default current_date,
  due_date date,
  status text not null default 'draft' check (status in ('draft','posted','paid')),
  subtotal numeric(14,2) not null default 0,
  vat numeric(14,2) not null default 0,
  nhil numeric(14,2) not null default 0,
  getfund numeric(14,2) not null default 0,
  total numeric(14,2) not null default 0,
  amount_paid numeric(14,2) not null default 0,
  notes text,
  journal_entry_id uuid references public.journal_entries(id),
  created_at timestamptz not null default now()
);

create table public.bill_lines (
  id uuid primary key default gen_random_uuid(),
  bill_id uuid not null references public.bills(id) on delete cascade,
  company_id uuid not null references public.companies(id) on delete cascade,
  product_id uuid references public.products(id),     -- stock purchase
  account_id uuid references public.accounts(id),     -- or an expense account
  description text not null,
  qty numeric(14,3) not null check (qty > 0),
  unit_cost numeric(14,2) not null check (unit_cost >= 0),
  taxable boolean not null default true,
  sort int not null default 0,
  check (product_id is not null or account_id is not null)
);

create table public.bill_payments (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  bill_id uuid not null references public.bills(id),
  payment_date date not null,
  amount numeric(14,2) not null check (amount > 0),
  method text not null check (method in ('cash','momo','bank')),
  reference text,
  journal_entry_id uuid references public.journal_entries(id),
  created_at timestamptz not null default now()
);

-- =====================================================================
-- 5. HR and payroll
-- =====================================================================
create table public.employees (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  staff_no text,
  full_name text not null,
  email text, phone text,
  job_title text, department text,
  hire_date date,
  basic_salary numeric(14,2) not null default 0,
  allowances numeric(14,2) not null default 0,
  ghana_card text, ssnit_no text, tin text,
  bank_name text, bank_account text, momo_number text,
  status text not null default 'active' check (status in ('active','inactive')),
  created_at timestamptz not null default now()
);

create table public.leave_requests (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  employee_id uuid not null references public.employees(id) on delete cascade,
  leave_type text not null default 'annual',
  start_date date not null,
  end_date date not null,
  days numeric(5,1) not null,
  reason text,
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  created_at timestamptz not null default now(),
  check (end_date >= start_date)
);

create table public.payroll_runs (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  period date not null,                         -- first day of month
  status text not null default 'draft' check (status in ('draft','posted','paid')),
  gross numeric(14,2) not null default 0,
  paye numeric(14,2) not null default 0,
  ssnit_employee numeric(14,2) not null default 0,
  ssnit_employer numeric(14,2) not null default 0,
  net numeric(14,2) not null default 0,
  journal_entry_id uuid references public.journal_entries(id),
  created_at timestamptz not null default now(),
  unique (company_id, period)
);

create table public.payslips (
  id uuid primary key default gen_random_uuid(),
  run_id uuid not null references public.payroll_runs(id) on delete cascade,
  company_id uuid not null references public.companies(id) on delete cascade,
  employee_id uuid not null references public.employees(id),
  basic numeric(14,2) not null,
  allowances numeric(14,2) not null,
  gross numeric(14,2) not null,
  ssnit_employee numeric(14,2) not null,
  chargeable numeric(14,2) not null,
  paye numeric(14,2) not null,
  net numeric(14,2) not null,
  ssnit_employer numeric(14,2) not null,
  tier1 numeric(14,2) not null,
  tier2 numeric(14,2) not null
);

-- =====================================================================
-- 6. Projects
-- =====================================================================
create table public.projects (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  name text not null,
  customer_id uuid references public.customers(id),
  start_date date, end_date date,
  budget numeric(14,2) not null default 0,
  hourly_rate numeric(14,2) not null default 0,
  status text not null default 'active' check (status in ('planned','active','on_hold','done')),
  description text,
  created_at timestamptz not null default now()
);
alter table public.invoices add constraint invoices_project_fk
  foreign key (project_id) references public.projects(id);

create table public.tasks (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  project_id uuid not null references public.projects(id) on delete cascade,
  title text not null,
  status text not null default 'todo' check (status in ('todo','doing','done')),
  assignee_id uuid references public.employees(id),
  due_date date,
  created_at timestamptz not null default now()
);

create table public.timesheets (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  project_id uuid not null references public.projects(id) on delete cascade,
  task_id uuid references public.tasks(id) on delete set null,
  employee_id uuid references public.employees(id),
  work_date date not null,
  hours numeric(5,2) not null check (hours > 0 and hours <= 24),
  billable boolean not null default true,
  note text,
  created_at timestamptz not null default now()
);

-- =====================================================================
-- 7. Row-level security
-- =====================================================================
alter table public.companies enable row level security;
alter table public.memberships enable row level security;
alter table public.tax_rates enable row level security;
alter table public.paye_bands enable row level security;
alter table public.statutory_rates enable row level security;

create policy "members read company" on public.companies for select using (is_member(id));
create policy "admins edit company" on public.companies for update using (has_role(id, array['owner','admin']));
create policy "members read memberships" on public.memberships for select using (is_member(company_id));
create policy "admins change roles" on public.memberships for update
  using (has_role(company_id, array['owner','admin']) and role <> 'owner' and user_id <> auth.uid())
  with check (role <> 'owner');
create policy "admins remove members" on public.memberships for delete
  using (has_role(company_id, array['owner','admin']) and role <> 'owner' and user_id <> auth.uid());
create policy "anyone signed in reads tax rates" on public.tax_rates for select using (auth.uid() is not null);
create policy "anyone signed in reads paye bands" on public.paye_bands for select using (auth.uid() is not null);
create policy "anyone signed in reads statutory rates" on public.statutory_rates for select using (auth.uid() is not null);

-- Read-only to members; written only by posting functions.
do $$ declare t text; begin
  foreach t in array array['stock_moves','payments','bill_payments','payslips','audit_log','number_sequences'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy "members read" on public.%I for select using (is_member(company_id))', t);
  end loop;
end $$;

-- The books: owners, admins and accountants only.
alter table public.journal_entries enable row level security;
alter table public.journal_lines enable row level security;
create policy "accountants read entries" on public.journal_entries for select using (has_role(company_id, array['owner','admin','accountant']));
create policy "accountants read lines" on public.journal_lines for select using (has_role(company_id, array['owner','admin','accountant']));

-- Master data: any member reads and writes.
do $$ declare t text; begin
  foreach t in array array['customers','suppliers','products','projects','tasks','timesheets','accounts'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy "members read" on public.%I for select using (is_member(company_id))', t);
    execute format('create policy "members insert" on public.%I for insert with check (is_member(company_id))', t);
    execute format('create policy "members update" on public.%I for update using (is_member(company_id))', t);
    execute format('create policy "members delete" on public.%I for delete using (is_member(company_id))', t);
  end loop;
end $$;

-- Products: stock and cost only change through stock functions.
create or replace function public.protect_product_stock() returns trigger language plpgsql as $$
begin
  if tg_op = 'INSERT' then
    if new.stock_qty <> 0 then
      raise exception 'New products start at zero stock. Use Opening stock to add quantities.';
    end if;
    return new;
  end if;
  if current_setting('sika.posting', true) is distinct from 'on'
     and (new.stock_qty is distinct from old.stock_qty or new.cost is distinct from old.cost) then
    raise exception 'Stock and cost change only through goods received, invoices or stock adjustments';
  end if;
  return new;
end $$;
create trigger products_protect before insert or update on public.products
  for each row execute function public.protect_product_stock();

-- Documents: editable only while draft.
do $$ declare t text; begin
  foreach t in array array['invoices','bills'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy "members read" on public.%I for select using (is_member(company_id))', t);
    execute format('create policy "members insert drafts" on public.%I for insert with check (is_member(company_id) and status = ''draft'')', t);
    execute format('create policy "members edit drafts" on public.%I for update using (is_member(company_id) and status = ''draft'') with check (status = ''draft'')', t);
    execute format('create policy "members delete drafts" on public.%I for delete using (is_member(company_id) and status = ''draft'')', t);
  end loop;
end $$;

alter table public.invoice_lines enable row level security;
create policy "members read" on public.invoice_lines for select using (is_member(company_id));
create policy "members write draft lines" on public.invoice_lines for all
  using (is_member(company_id) and exists (select 1 from invoices i where i.id = invoice_id and i.status = 'draft'))
  with check (is_member(company_id) and exists (select 1 from invoices i where i.id = invoice_id and i.status = 'draft'));

alter table public.bill_lines enable row level security;
create policy "members read" on public.bill_lines for select using (is_member(company_id));
create policy "members write draft lines" on public.bill_lines for all
  using (is_member(company_id) and exists (select 1 from bills b where b.id = bill_id and b.status = 'draft'))
  with check (is_member(company_id) and exists (select 1 from bills b where b.id = bill_id and b.status = 'draft'));

-- HR and payroll: owners, admins, HR and accountants only.
alter table public.employees enable row level security;
create policy "hr reads staff" on public.employees for select
  using (has_role(company_id, array['owner','admin','hr','accountant']));
create policy "hr writes staff" on public.employees for all
  using (has_role(company_id, array['owner','admin','hr']))
  with check (has_role(company_id, array['owner','admin','hr']));
alter table public.leave_requests enable row level security;
create policy "members read leave" on public.leave_requests for select using (is_member(company_id));
create policy "members request leave" on public.leave_requests for insert with check (is_member(company_id) and status = 'pending');
create policy "hr decides leave" on public.leave_requests for update using (has_role(company_id, array['owner','admin','hr']));
create policy "hr deletes leave" on public.leave_requests for delete using (has_role(company_id, array['owner','admin','hr']));
alter table public.payroll_runs enable row level security;
create policy "payroll staff read runs" on public.payroll_runs for select
  using (has_role(company_id, array['owner','admin','hr','accountant']));
drop policy "members read" on public.payslips;
create policy "payroll staff read payslips" on public.payslips for select
  using (has_role(company_id, array['owner','admin','hr','accountant']));

-- =====================================================================
-- 8. Helpers used by posting functions
-- =====================================================================
create or replace function public.require_member(cid uuid, roles text[] default null)
returns void language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Please sign in'; end if;
  if roles is null then
    if not is_member(cid) then raise exception 'You do not have access to this company'; end if;
  elsif not has_role(cid, roles) then
    raise exception 'Your role cannot do this. Ask an owner or admin.';
  end if;
end $$;

create or replace function public.acct(cid uuid, key text)
returns uuid language plpgsql stable security definer set search_path = public as $$
declare v uuid;
begin
  select id into v from accounts where company_id = cid and system_key = key;
  if v is null then raise exception 'Account % is missing from the chart of accounts', key; end if;
  return v;
end $$;

create or replace function public.next_number(cid uuid, p_key text, p_prefix text)
returns text language plpgsql security definer set search_path = public as $$
declare v int;
begin
  insert into number_sequences (company_id, key, next_value) values (cid, p_key, 2)
  on conflict (company_id, key) do update set next_value = number_sequences.next_value + 1
  returning next_value - 1 into v;
  return p_prefix || lpad(v::text, 5, '0');
end $$;

-- lines: [{"account_id": uuid, "debit": n, "credit": n}, ...]
create or replace function public.post_journal(cid uuid, p_date date, p_memo text, p_lines jsonb,
  p_source_type text default null, p_source_id uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
  v_dr numeric; v_cr numeric;
begin
  select coalesce(sum(round((l->>'debit')::numeric,2)),0), coalesce(sum(round((l->>'credit')::numeric,2)),0)
    into v_dr, v_cr from jsonb_array_elements(p_lines) l;
  if v_dr <> v_cr then
    raise exception 'Journal does not balance: debits % vs credits %', v_dr, v_cr;
  end if;
  if v_dr = 0 then raise exception 'Journal has no amounts'; end if;
  insert into journal_entries (company_id, entry_no, entry_date, memo, source_type, source_id)
  values (cid, next_number(cid, 'JE', 'JE-'), p_date, p_memo, p_source_type, p_source_id)
  returning id into v_id;
  insert into journal_lines (entry_id, company_id, account_id, debit, credit)
  select v_id, cid, (l->>'account_id')::uuid, round(coalesce((l->>'debit')::numeric,0),2), round(coalesce((l->>'credit')::numeric,0),2)
    from jsonb_array_elements(p_lines) l
   where round(coalesce((l->>'debit')::numeric,0),2) <> 0 or round(coalesce((l->>'credit')::numeric,0),2) <> 0;
  insert into audit_log (company_id, action, detail) values (cid, 'journal.posted', jsonb_build_object('entry_id', v_id, 'memo', p_memo));
  return v_id;
end $$;

create or replace function public.jl(a uuid, dr numeric, cr numeric)
returns jsonb language sql immutable as $$
  select jsonb_build_object('account_id', a, 'debit', coalesce(dr,0), 'credit', coalesce(cr,0));
$$;

-- =====================================================================
-- 9. Company set-up
-- =====================================================================
create or replace function public.seed_accounts(cid uuid)
returns void language sql security definer set search_path = public as $$
  insert into accounts (company_id, code, name, type, system_key) values
  (cid,'1000','Cash on hand','asset','cash'),
  (cid,'1010','Mobile Money wallet','asset','momo'),
  (cid,'1100','Bank account','asset','bank'),
  (cid,'1200','Trade receivables','asset','ar'),
  (cid,'1300','Inventory','asset','inventory'),
  (cid,'1410','VAT input','asset','vat_in'),
  (cid,'1420','NHIL input','asset','nhil_in'),
  (cid,'1430','GETFund levy input','asset','getf_in'),
  (cid,'1500','Equipment and vehicles','asset',null),
  (cid,'2000','Trade payables','liability','ap'),
  (cid,'2110','VAT output','liability','vat_out'),
  (cid,'2120','NHIL output','liability','nhil_out'),
  (cid,'2130','GETFund levy output','liability','getf_out'),
  (cid,'2200','PAYE payable','liability','paye'),
  (cid,'2210','SSNIT Tier 1 payable','liability','ssnit1'),
  (cid,'2220','Tier 2 pension payable','liability','tier2'),
  (cid,'2300','Net salaries payable','liability','net_pay'),
  (cid,'2400','Loans payable','liability',null),
  (cid,'3000','Owner''s capital','equity','capital'),
  (cid,'3100','Retained earnings','equity','retained'),
  (cid,'4000','Sales of goods','income','sales'),
  (cid,'4100','Service revenue','income','services'),
  (cid,'4900','Other income','income',null),
  (cid,'5000','Cost of goods sold','expense','cogs'),
  (cid,'5100','Stock adjustments','expense','stock_adj'),
  (cid,'6000','Salaries and wages','expense','salaries'),
  (cid,'6010','Employer SSNIT contribution','expense','employer_ssnit'),
  (cid,'6100','Rent','expense',null),
  (cid,'6200','Electricity and water','expense',null),
  (cid,'6300','Fuel and transport','expense',null),
  (cid,'6400','Telephone and internet','expense',null),
  (cid,'6500','Repairs and maintenance','expense',null),
  (cid,'6600','Bank and MoMo charges','expense',null),
  (cid,'6900','General expenses','expense','expense');
$$;

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
  return v;
end $$;

create or replace function public.add_member(cid uuid, p_email text, p_role text)
returns void language plpgsql security definer set search_path = public as $$
declare v_user uuid;
begin
  perform require_member(cid, array['owner','admin']);
  if p_role not in ('admin','accountant','sales','hr','staff') then raise exception 'Choose a valid role'; end if;
  select id into v_user from auth.users where lower(email) = lower(trim(p_email));
  if v_user is null then
    raise exception 'No account uses %. Ask them to sign up first, then add them again.', p_email;
  end if;
  insert into memberships (company_id, user_id, email, role) values (cid, v_user, lower(trim(p_email)), p_role)
  on conflict (company_id, user_id) do update set role = excluded.role;
end $$;

-- =====================================================================
-- 10. Stock
-- =====================================================================
-- p_kind: 'opening' (credit owner's capital) or 'adjustment' (stock adjustments expense)
create or replace function public.adjust_stock(p_product uuid, p_qty numeric, p_unit_cost numeric,
  p_date date, p_kind text, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare p products; v_value numeric; v_cost numeric; v_other uuid;
begin
  select * into p from products where id = p_product for update;
  if not found then raise exception 'Product not found'; end if;
  perform require_member(p.company_id, array['owner','admin','accountant','sales']);
  if p_qty = 0 then raise exception 'Quantity cannot be zero'; end if;
  if p.stock_qty + p_qty < 0 then raise exception 'Only % % of % in stock', p.stock_qty, p.unit, p.name; end if;
  v_cost := case when p_qty > 0 then coalesce(nullif(p_unit_cost,0), p.cost) else p.cost end;
  v_value := round(abs(p_qty) * v_cost, 2);
  perform set_config('sika.posting','on', true);
  update products set
    cost = case when p_qty > 0 and stock_qty + p_qty > 0
                then round((greatest(stock_qty,0) * cost + p_qty * v_cost) / (greatest(stock_qty,0) + p_qty), 4) else cost end,
    stock_qty = stock_qty + p_qty
  where id = p_product;
  perform set_config('sika.posting','off', true);
  insert into stock_moves (company_id, product_id, move_date, qty, unit_cost, reason)
  values (p.company_id, p_product, p_date, p_qty, v_cost, coalesce(p_note, p_kind));
  if v_value > 0 then
    v_other := case when p_kind = 'opening' then acct(p.company_id,'capital') else acct(p.company_id,'stock_adj') end;
    perform post_journal(p.company_id, p_date,
      (case when p_kind = 'opening' then 'Opening stock: ' else 'Stock adjustment: ' end) || p.name || coalesce(' (' || p_note || ')',''),
      case when p_qty > 0
        then jsonb_build_array(jl(acct(p.company_id,'inventory'), v_value, 0), jl(v_other, 0, v_value))
        else jsonb_build_array(jl(v_other, v_value, 0), jl(acct(p.company_id,'inventory'), 0, v_value)) end,
      'stock', p_product);
  end if;
end $$;

-- =====================================================================
-- 11. Sales invoices
-- =====================================================================
create or replace function public.post_invoice(p_invoice uuid)
returns text language plpgsql security definer set search_path = public as $$
declare
  inv invoices; l record; p products;
  v_taxable numeric := 0; v_sub numeric := 0; v_goods numeric := 0; v_services numeric := 0; v_cogs numeric := 0;
  v_vat numeric; v_nhil numeric; v_getf numeric; v_total numeric; v_je uuid; v_no text;
begin
  select * into inv from invoices where id = p_invoice for update;
  if not found then raise exception 'Invoice not found'; end if;
  perform require_member(inv.company_id, array['owner','admin','accountant','sales']);
  if inv.status <> 'draft' then raise exception 'This invoice is already posted'; end if;
  if not exists (select 1 from invoice_lines where invoice_id = p_invoice) then raise exception 'Add at least one line'; end if;

  if tax_rate('VAT', inv.invoice_date) is null then raise exception 'No VAT rate is set for %', inv.invoice_date; end if;
  perform set_config('sika.posting','on', true);
  for l in select * from invoice_lines where invoice_id = p_invoice order by sort loop
    v_sub := v_sub + round(l.qty * l.unit_price, 2);
    if l.taxable then v_taxable := v_taxable + round(l.qty * l.unit_price, 2); end if;
    if l.product_id is not null then
      select * into p from products where id = l.product_id for update;
      if p.stock_qty < l.qty then
        raise exception 'Only % % of % in stock', p.stock_qty, p.unit, p.name;
      end if;
      update products set stock_qty = stock_qty - l.qty where id = p.id;
      insert into stock_moves (company_id, product_id, move_date, qty, unit_cost, reason, ref_type, ref_id)
      values (inv.company_id, p.id, inv.invoice_date, -l.qty, p.cost, 'Sale', 'invoice', inv.id);
      v_cogs := v_cogs + round(l.qty * p.cost, 2);
      v_goods := v_goods + round(l.qty * l.unit_price, 2);
    else
      v_services := v_services + round(l.qty * l.unit_price, 2);
    end if;
  end loop;
  perform set_config('sika.posting','off', true);

  v_vat := round(v_taxable * tax_rate('VAT', inv.invoice_date), 2);
  v_nhil := round(v_taxable * tax_rate('NHIL', inv.invoice_date), 2);
  v_getf := round(v_taxable * tax_rate('GETFUND', inv.invoice_date), 2);
  v_total := v_sub + v_vat + v_nhil + v_getf;
  v_no := next_number(inv.company_id, 'INV', 'INV-');

  v_je := post_journal(inv.company_id, inv.invoice_date, 'Invoice ' || v_no,
    jsonb_build_array(
      jl(acct(inv.company_id,'ar'), v_total, 0),
      jl(acct(inv.company_id,'sales'), 0, v_goods),
      jl(acct(inv.company_id,'services'), 0, v_services),
      jl(acct(inv.company_id,'vat_out'), 0, v_vat),
      jl(acct(inv.company_id,'nhil_out'), 0, v_nhil),
      jl(acct(inv.company_id,'getf_out'), 0, v_getf),
      jl(acct(inv.company_id,'cogs'), v_cogs, 0),
      jl(acct(inv.company_id,'inventory'), 0, v_cogs)),
    'invoice', inv.id);

  update invoices set status = 'posted', number = v_no, subtotal = v_sub, vat = v_vat, nhil = v_nhil,
         getfund = v_getf, total = v_total, journal_entry_id = v_je,
         due_date = coalesce(due_date, invoice_date + 30)
   where id = p_invoice;
  return v_no;
end $$;

create or replace function public.record_payment(p_invoice uuid, p_amount numeric, p_date date,
  p_method text, p_reference text default null)
returns void language plpgsql security definer set search_path = public as $$
declare inv invoices; v_je uuid; v_pay uuid;
begin
  select * into inv from invoices where id = p_invoice for update;
  if not found then raise exception 'Invoice not found'; end if;
  perform require_member(inv.company_id, array['owner','admin','accountant','sales']);
  if inv.status = 'draft' then raise exception 'Post the invoice before recording a payment'; end if;
  if p_amount <= 0 then raise exception 'Amount must be more than zero'; end if;
  if round(p_amount,2) > inv.total - inv.amount_paid then
    raise exception 'Payment of % is more than the % still owed', p_amount, inv.total - inv.amount_paid;
  end if;
  insert into payments (company_id, invoice_id, payment_date, amount, method, reference)
  values (inv.company_id, inv.id, p_date, round(p_amount,2), p_method, p_reference) returning id into v_pay;
  v_je := post_journal(inv.company_id, p_date, 'Payment received for ' || inv.number,
    jsonb_build_array(jl(acct(inv.company_id, p_method), p_amount, 0), jl(acct(inv.company_id,'ar'), 0, p_amount)),
    'payment', v_pay);
  update payments set journal_entry_id = v_je where id = v_pay;
  update invoices set amount_paid = amount_paid + round(p_amount,2),
    status = case when amount_paid + round(p_amount,2) >= total then 'paid' else 'posted' end
   where id = inv.id;
end $$;

-- =====================================================================
-- 12. Supplier bills (purchases)
-- =====================================================================
create or replace function public.post_bill(p_bill uuid)
returns text language plpgsql security definer set search_path = public as $$
declare
  b bills; l record; v_lines jsonb := '[]'::jsonb;
  v_taxable numeric := 0; v_sub numeric := 0; v_amt numeric;
  v_vat numeric; v_nhil numeric; v_getf numeric; v_total numeric; v_je uuid; v_no text;
begin
  select * into b from bills where id = p_bill for update;
  if not found then raise exception 'Bill not found'; end if;
  perform require_member(b.company_id, array['owner','admin','accountant']);
  if b.status <> 'draft' then raise exception 'This bill is already posted'; end if;
  if not exists (select 1 from bill_lines where bill_id = p_bill) then raise exception 'Add at least one line'; end if;

  if tax_rate('VAT', b.bill_date) is null then raise exception 'No VAT rate is set for %', b.bill_date; end if;
  perform set_config('sika.posting','on', true);
  for l in select * from bill_lines where bill_id = p_bill order by sort loop
    v_amt := round(l.qty * l.unit_cost, 2);
    v_sub := v_sub + v_amt;
    if l.taxable then v_taxable := v_taxable + v_amt; end if;
    if l.product_id is not null then
      update products set
        cost = round((greatest(stock_qty,0) * cost + l.qty * l.unit_cost) / (greatest(stock_qty,0) + l.qty), 4),
        stock_qty = stock_qty + l.qty
       where id = l.product_id;
      insert into stock_moves (company_id, product_id, move_date, qty, unit_cost, reason, ref_type, ref_id)
      values (b.company_id, l.product_id, b.bill_date, l.qty, l.unit_cost, 'Goods received', 'bill', b.id);
      v_lines := v_lines || jl(acct(b.company_id,'inventory'), v_amt, 0);
    else
      v_lines := v_lines || jl(l.account_id, v_amt, 0);
    end if;
  end loop;
  perform set_config('sika.posting','off', true);

  -- NHIL and GETFund are recoverable input tax under Act 1151.
  v_vat := round(v_taxable * tax_rate('VAT', b.bill_date), 2);
  v_nhil := round(v_taxable * tax_rate('NHIL', b.bill_date), 2);
  v_getf := round(v_taxable * tax_rate('GETFUND', b.bill_date), 2);
  v_total := v_sub + v_vat + v_nhil + v_getf;
  v_no := next_number(b.company_id, 'BILL', 'BILL-');
  v_lines := v_lines
    || jl(acct(b.company_id,'vat_in'), v_vat, 0)
    || jl(acct(b.company_id,'nhil_in'), v_nhil, 0)
    || jl(acct(b.company_id,'getf_in'), v_getf, 0)
    || jl(acct(b.company_id,'ap'), 0, v_total);
  v_je := post_journal(b.company_id, b.bill_date, 'Supplier bill ' || v_no || coalesce(' (' || b.supplier_ref || ')',''), v_lines, 'bill', b.id);
  update bills set status = 'posted', number = v_no, subtotal = v_sub, vat = v_vat, nhil = v_nhil,
         getfund = v_getf, total = v_total, journal_entry_id = v_je, due_date = coalesce(due_date, bill_date + 30)
   where id = p_bill;
  return v_no;
end $$;

create or replace function public.pay_bill(p_bill uuid, p_amount numeric, p_date date, p_method text, p_reference text default null)
returns void language plpgsql security definer set search_path = public as $$
declare b bills; v_je uuid; v_pay uuid;
begin
  select * into b from bills where id = p_bill for update;
  if not found then raise exception 'Bill not found'; end if;
  perform require_member(b.company_id, array['owner','admin','accountant']);
  if b.status = 'draft' then raise exception 'Post the bill before paying it'; end if;
  if round(p_amount,2) > b.total - b.amount_paid or p_amount <= 0 then
    raise exception 'Amount must be between 0 and the % still owed', b.total - b.amount_paid;
  end if;
  insert into bill_payments (company_id, bill_id, payment_date, amount, method, reference)
  values (b.company_id, b.id, p_date, round(p_amount,2), p_method, p_reference) returning id into v_pay;
  v_je := post_journal(b.company_id, p_date, 'Payment to supplier for ' || b.number,
    jsonb_build_array(jl(acct(b.company_id,'ap'), p_amount, 0), jl(acct(b.company_id, p_method), 0, p_amount)),
    'bill_payment', v_pay);
  update bill_payments set journal_entry_id = v_je where id = v_pay;
  update bills set amount_paid = amount_paid + round(p_amount,2),
    status = case when amount_paid + round(p_amount,2) >= total then 'paid' else 'posted' end
   where id = b.id;
end $$;

-- =====================================================================
-- 13. Manual journals (accountants)
-- =====================================================================
create or replace function public.post_manual_journal(cid uuid, p_date date, p_memo text, p_lines jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
begin
  perform require_member(cid, array['owner','admin','accountant']);
  if exists (select 1 from jsonb_array_elements(p_lines) l
             where not exists (select 1 from accounts a where a.id = (l->>'account_id')::uuid and a.company_id = cid)) then
    raise exception 'An account does not belong to this company';
  end if;
  return post_journal(cid, p_date, p_memo, p_lines, 'manual', null);
end $$;

-- =====================================================================
-- 14. Payroll
-- =====================================================================
create or replace function public.prepare_payroll(cid uuid, p_period date)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_run uuid; v_period date := date_trunc('month', p_period)::date; v_status text;
  e record; v_emp numeric; v_er numeric; v_t2 numeric; v_gross numeric; v_charge numeric; v_paye numeric;
  v_payday date;
begin
  perform require_member(cid, array['owner','admin','hr','accountant']);
  v_payday := (v_period + interval '1 month - 1 day')::date;
  select id, status into v_run, v_status from payroll_runs where company_id = cid and period = v_period;
  if v_run is not null and v_status <> 'draft' then raise exception 'Payroll for this month is already posted'; end if;
  if v_run is null then
    insert into payroll_runs (company_id, period) values (cid, v_period) returning id into v_run;
  else
    delete from payslips where run_id = v_run;
  end if;
  for e in select * from employees where company_id = cid and status = 'active' order by full_name loop
    v_gross := e.basic_salary + e.allowances;
    v_emp := round(e.basic_salary * stat_rate('SSNIT_EMPLOYEE', v_payday), 2);
    v_er := round(e.basic_salary * stat_rate('SSNIT_EMPLOYER', v_payday), 2);
    v_t2 := round(e.basic_salary * stat_rate('TIER2', v_payday), 2);
    v_charge := v_gross - v_emp;
    v_paye := compute_paye(v_charge, v_payday);
    insert into payslips (run_id, company_id, employee_id, basic, allowances, gross, ssnit_employee, chargeable,
                          paye, net, ssnit_employer, tier1, tier2)
    values (v_run, cid, e.id, e.basic_salary, e.allowances, v_gross, v_emp, v_charge,
            v_paye, v_gross - v_emp - v_paye, v_er, v_emp + v_er - v_t2, v_t2);
  end loop;
  update payroll_runs r set
    gross = coalesce(s.gross,0), paye = coalesce(s.paye,0), ssnit_employee = coalesce(s.emp,0),
    ssnit_employer = coalesce(s.er,0), net = coalesce(s.net,0)
  from (select sum(gross) gross, sum(paye) paye, sum(ssnit_employee) emp, sum(ssnit_employer) er, sum(net) net
          from payslips where run_id = v_run) s
  where r.id = v_run;
  return v_run;
end $$;

create or replace function public.post_payroll(p_run uuid)
returns void language plpgsql security definer set search_path = public as $$
declare r payroll_runs; v_t1 numeric; v_t2 numeric; v_je uuid; v_date date;
begin
  select * into r from payroll_runs where id = p_run for update;
  if not found then raise exception 'Payroll run not found'; end if;
  perform require_member(r.company_id, array['owner','admin','accountant']);
  if r.status <> 'draft' then raise exception 'This payroll is already posted'; end if;
  if r.gross = 0 then raise exception 'There are no payslips in this run'; end if;
  select sum(tier1), sum(tier2) into v_t1, v_t2 from payslips where run_id = p_run;
  v_date := (r.period + interval '1 month - 1 day')::date;
  v_je := post_journal(r.company_id, v_date, 'Payroll ' || to_char(r.period, 'Mon YYYY'),
    jsonb_build_array(
      jl(acct(r.company_id,'salaries'), r.gross, 0),
      jl(acct(r.company_id,'employer_ssnit'), r.ssnit_employer, 0),
      jl(acct(r.company_id,'paye'), 0, r.paye),
      jl(acct(r.company_id,'ssnit1'), 0, v_t1),
      jl(acct(r.company_id,'tier2'), 0, v_t2),
      jl(acct(r.company_id,'net_pay'), 0, r.net)),
    'payroll', r.id);
  update payroll_runs set status = 'posted', journal_entry_id = v_je where id = p_run;
end $$;

create or replace function public.pay_payroll(p_run uuid, p_method text, p_date date)
returns void language plpgsql security definer set search_path = public as $$
declare r payroll_runs;
begin
  select * into r from payroll_runs where id = p_run for update;
  if not found then raise exception 'Payroll run not found'; end if;
  perform require_member(r.company_id, array['owner','admin','accountant']);
  if r.status <> 'posted' then raise exception 'Post the payroll before paying it'; end if;
  perform post_journal(r.company_id, p_date, 'Salaries paid ' || to_char(r.period, 'Mon YYYY'),
    jsonb_build_array(jl(acct(r.company_id,'net_pay'), r.net, 0), jl(acct(r.company_id, p_method), 0, r.net)),
    'payroll_payment', r.id);
  update payroll_runs set status = 'paid' where id = p_run;
end $$;

-- =====================================================================
-- 15. Reports
-- =====================================================================
create or replace function public.account_balances(cid uuid, p_from date, p_to date)
returns table (account_id uuid, code text, name text, type text, debit numeric, credit numeric)
language sql stable security definer set search_path = public as $$
  select a.id, a.code, a.name, a.type,
         coalesce(sum(l.debit),0)::numeric, coalesce(sum(l.credit),0)::numeric
    from accounts a
    left join (journal_lines l join journal_entries e
                 on e.id = l.entry_id and e.entry_date between p_from and p_to)
      on l.account_id = a.id
   where a.company_id = cid and has_role(cid, array['owner','admin','accountant'])
   group by a.id, a.code, a.name, a.type
   order by a.code;
$$;

create or replace function public.project_summary(cid uuid)
returns table (project_id uuid, hours numeric, billable_hours numeric, invoiced numeric, tasks_open bigint, tasks_done bigint)
language sql stable security definer set search_path = public as $$
  select p.id,
    coalesce((select sum(hours) from timesheets t where t.project_id = p.id),0),
    coalesce((select sum(hours) from timesheets t where t.project_id = p.id and t.billable),0),
    coalesce((select sum(subtotal) from invoices i where i.project_id = p.id and i.status <> 'draft'),0),
    (select count(*) from tasks k where k.project_id = p.id and k.status <> 'done'),
    (select count(*) from tasks k where k.project_id = p.id and k.status = 'done')
  from projects p where p.company_id = cid and is_member(cid);
$$;

create or replace function public.employee_directory(cid uuid)
returns table (id uuid, full_name text, job_title text, department text)
language sql stable security definer set search_path = public as $$
  select id, full_name, job_title, department from employees
   where company_id = cid and status = 'active' and is_member(cid) order by full_name;
$$;

-- Function permissions: signed-in users only.
revoke execute on all functions in schema public from public, anon;
grant execute on all functions in schema public to authenticated;
-- Internal helpers are not callable from the app.
revoke execute on function public.post_journal(uuid,date,text,jsonb,text,uuid) from authenticated;
revoke execute on function public.seed_accounts(uuid) from authenticated;
revoke execute on function public.next_number(uuid,text,text) from authenticated;


-- ======================================================================
-- 0002_asnys_v1_1.sql
-- ======================================================================
-- Sika ERP v1.1
-- Run once in the Supabase SQL editor AFTER 0001_sika_erp.sql.
-- Adds: credit notes and reversals, quotes and sales orders, recurring invoices, multi-currency,
-- payroll overtime/bonus tax, staff loans, Tier 3, leave balances, recruitment, appraisals,
-- bank reconciliation, budgets and period locking.

-- =====================================================================
-- 1. New system accounts (existing and future companies)
-- =====================================================================
create or replace function public.seed_accounts_v11(cid uuid)
returns void language sql security definer set search_path = public as $$
  insert into accounts (company_id, code, name, type, system_key) values
  (cid,'1250','Staff loans and advances','asset','staff_loans'),
  (cid,'2230','Tier 3 pension payable','liability','tier3'),
  (cid,'2500','Customer deposits and credits','liability',null),
  (cid,'4800','Foreign exchange gains and losses','income','fx'),
  (cid,'6020','Employer Tier 3 contribution','expense','employer_tier3')
  on conflict do nothing;
$$;
select public.seed_accounts_v11(id) from public.companies;

-- =====================================================================
-- 2. Period locking
-- =====================================================================
alter table public.companies add column if not exists locked_until date;

create or replace function public.post_journal(cid uuid, p_date date, p_memo text, p_lines jsonb,
  p_source_type text default null, p_source_id uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_id uuid; v_dr numeric; v_cr numeric; v_lock date;
begin
  select locked_until into v_lock from companies where id = cid;
  if v_lock is not null and p_date <= v_lock then
    raise exception 'The books are locked up to %. Date this on or after %, or ask an accountant to change the lock date.', v_lock, v_lock + 1;
  end if;
  select coalesce(sum(round((l->>'debit')::numeric,2)),0), coalesce(sum(round((l->>'credit')::numeric,2)),0)
    into v_dr, v_cr from jsonb_array_elements(p_lines) l;
  if v_dr <> v_cr then raise exception 'Journal does not balance: debits % vs credits %', v_dr, v_cr; end if;
  if v_dr = 0 then raise exception 'Journal has no amounts'; end if;
  insert into journal_entries (company_id, entry_no, entry_date, memo, source_type, source_id)
  values (cid, next_number(cid, 'JE', 'JE-'), p_date, p_memo, p_source_type, p_source_id)
  returning id into v_id;
  insert into journal_lines (entry_id, company_id, account_id, debit, credit)
  select v_id, cid, (l->>'account_id')::uuid, round(coalesce((l->>'debit')::numeric,0),2), round(coalesce((l->>'credit')::numeric,0),2)
    from jsonb_array_elements(p_lines) l
   where round(coalesce((l->>'debit')::numeric,0),2) <> 0 or round(coalesce((l->>'credit')::numeric,0),2) <> 0;
  insert into audit_log (company_id, action, detail) values (cid, 'journal.posted', jsonb_build_object('entry_id', v_id, 'memo', p_memo));
  return v_id;
end $$;

create or replace function public.set_lock_date(cid uuid, p_date date)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform require_member(cid, array['owner','admin','accountant']);
  update companies set locked_until = p_date where id = cid;
  insert into audit_log (company_id, action, detail) values (cid, 'books.locked', jsonb_build_object('until', p_date));
end $$;

-- =====================================================================
-- 3. Currencies and multi-currency documents
-- =====================================================================
create table public.currencies (
  company_id uuid not null references public.companies(id) on delete cascade,
  code text not null check (code ~ '^[A-Z]{3}$' and code <> 'GHS'),
  name text not null,
  rate numeric(14,6) not null check (rate > 0),   -- GHS per 1 unit
  updated_at timestamptz not null default now(),
  primary key (company_id, code)
);

alter table public.invoices add column if not exists currency text not null default 'GHS';
alter table public.invoices add column if not exists exchange_rate numeric(14,6) not null default 1 check (exchange_rate > 0);
alter table public.invoices add column if not exists amount_credited numeric(14,2) not null default 0;
alter table public.bills add column if not exists currency text not null default 'GHS';
alter table public.bills add column if not exists exchange_rate numeric(14,6) not null default 1 check (exchange_rate > 0);
alter table public.payments add column if not exists exchange_rate numeric(14,6) not null default 1;
alter table public.bill_payments add column if not exists exchange_rate numeric(14,6) not null default 1;

-- Sales invoice: amounts in the document currency, ledger in GHS at the invoice rate.
create or replace function public.post_invoice(p_invoice uuid)
returns text language plpgsql security definer set search_path = public as $$
declare
  inv invoices; l record; p products; x numeric;
  v_taxable numeric := 0; v_sub numeric := 0; v_goods numeric := 0; v_services numeric := 0; v_cogs numeric := 0;
  v_vat numeric; v_nhil numeric; v_getf numeric; v_total numeric; v_je uuid; v_no text;
  g_goods numeric; g_serv numeric; g_vat numeric; g_nhil numeric; g_getf numeric;
begin
  select * into inv from invoices where id = p_invoice for update;
  if not found then raise exception 'Invoice not found'; end if;
  perform require_member(inv.company_id, array['owner','admin','accountant','sales']);
  if inv.status <> 'draft' then raise exception 'This invoice is already posted'; end if;
  if not exists (select 1 from invoice_lines where invoice_id = p_invoice) then raise exception 'Add at least one line'; end if;
  if tax_rate('VAT', inv.invoice_date) is null then raise exception 'No VAT rate is set for %', inv.invoice_date; end if;
  x := inv.exchange_rate;

  perform set_config('sika.posting','on', true);
  for l in select * from invoice_lines where invoice_id = p_invoice order by sort loop
    v_sub := v_sub + round(l.qty * l.unit_price, 2);
    if l.taxable then v_taxable := v_taxable + round(l.qty * l.unit_price, 2); end if;
    if l.product_id is not null then
      select * into p from products where id = l.product_id for update;
      if p.stock_qty < l.qty then raise exception 'Only % % of % in stock', p.stock_qty, p.unit, p.name; end if;
      update products set stock_qty = stock_qty - l.qty where id = p.id;
      insert into stock_moves (company_id, product_id, move_date, qty, unit_cost, reason, ref_type, ref_id)
      values (inv.company_id, p.id, inv.invoice_date, -l.qty, p.cost, 'Sale', 'invoice', inv.id);
      v_cogs := v_cogs + round(l.qty * p.cost, 2);
      v_goods := v_goods + round(l.qty * l.unit_price, 2);
    else
      v_services := v_services + round(l.qty * l.unit_price, 2);
    end if;
  end loop;
  perform set_config('sika.posting','off', true);

  v_vat := round(v_taxable * tax_rate('VAT', inv.invoice_date), 2);
  v_nhil := round(v_taxable * tax_rate('NHIL', inv.invoice_date), 2);
  v_getf := round(v_taxable * tax_rate('GETFUND', inv.invoice_date), 2);
  v_total := v_sub + v_vat + v_nhil + v_getf;
  g_goods := round(v_goods * x, 2); g_serv := round(v_services * x, 2);
  g_vat := round(v_vat * x, 2); g_nhil := round(v_nhil * x, 2); g_getf := round(v_getf * x, 2);
  v_no := next_number(inv.company_id, 'INV', 'INV-');

  v_je := post_journal(inv.company_id, inv.invoice_date, 'Invoice ' || v_no || case when inv.currency <> 'GHS' then ' (' || inv.currency || ' at ' || x || ')' else '' end,
    jsonb_build_array(
      jl(acct(inv.company_id,'ar'), g_goods + g_serv + g_vat + g_nhil + g_getf, 0),
      jl(acct(inv.company_id,'sales'), 0, g_goods),
      jl(acct(inv.company_id,'services'), 0, g_serv),
      jl(acct(inv.company_id,'vat_out'), 0, g_vat),
      jl(acct(inv.company_id,'nhil_out'), 0, g_nhil),
      jl(acct(inv.company_id,'getf_out'), 0, g_getf),
      jl(acct(inv.company_id,'cogs'), v_cogs, 0),
      jl(acct(inv.company_id,'inventory'), 0, v_cogs)),
    'invoice', inv.id);

  update invoices set status = 'posted', number = v_no, subtotal = v_sub, vat = v_vat, nhil = v_nhil,
         getfund = v_getf, total = v_total, journal_entry_id = v_je, due_date = coalesce(due_date, invoice_date + 30)
   where id = p_invoice;
  return v_no;
end $$;

drop function if exists public.record_payment(uuid, numeric, date, text, text);
create or replace function public.record_payment(p_invoice uuid, p_amount numeric, p_date date,
  p_method text, p_reference text default null, p_rate numeric default null)
returns void language plpgsql security definer set search_path = public as $$
declare inv invoices; v_je uuid; v_pay uuid; v_rate numeric; g_bank numeric; g_ar numeric; v_out numeric;
begin
  select * into inv from invoices where id = p_invoice for update;
  if not found then raise exception 'Invoice not found'; end if;
  perform require_member(inv.company_id, array['owner','admin','accountant','sales']);
  if inv.status = 'draft' then raise exception 'Post the invoice before recording a payment'; end if;
  if p_amount <= 0 then raise exception 'Amount must be more than zero'; end if;
  v_out := inv.total - inv.amount_paid - inv.amount_credited;
  if round(p_amount,2) > v_out then raise exception 'Payment of % is more than the % still owed', p_amount, v_out; end if;
  v_rate := coalesce(nullif(p_rate,0), inv.exchange_rate);
  if inv.currency = 'GHS' then v_rate := 1; end if;
  g_bank := round(p_amount * v_rate, 2); g_ar := round(p_amount * inv.exchange_rate, 2);
  insert into payments (company_id, invoice_id, payment_date, amount, method, reference, exchange_rate)
  values (inv.company_id, inv.id, p_date, round(p_amount,2), p_method, p_reference, v_rate) returning id into v_pay;
  v_je := post_journal(inv.company_id, p_date, 'Payment received for ' || inv.number,
    jsonb_build_array(
      jl(acct(inv.company_id, p_method), g_bank, 0),
      jl(acct(inv.company_id,'ar'), 0, g_ar),
      jl(acct(inv.company_id,'fx'), greatest(g_ar - g_bank, 0), greatest(g_bank - g_ar, 0))),
    'payment', v_pay);
  update payments set journal_entry_id = v_je where id = v_pay;
  update invoices set amount_paid = amount_paid + round(p_amount,2),
    status = case when amount_paid + amount_credited + round(p_amount,2) >= total then 'paid' else 'posted' end
   where id = inv.id;
end $$;

create or replace function public.post_bill(p_bill uuid)
returns text language plpgsql security definer set search_path = public as $$
declare
  b bills; l record; v_lines jsonb := '[]'::jsonb; x numeric;
  v_taxable numeric := 0; v_sub numeric := 0; v_amt numeric; g_amt numeric; g_sum numeric := 0;
  v_vat numeric; v_nhil numeric; v_getf numeric; v_total numeric; v_je uuid; v_no text;
  g_vat numeric; g_nhil numeric; g_getf numeric;
begin
  select * into b from bills where id = p_bill for update;
  if not found then raise exception 'Bill not found'; end if;
  perform require_member(b.company_id, array['owner','admin','accountant']);
  if b.status <> 'draft' then raise exception 'This bill is already posted'; end if;
  if not exists (select 1 from bill_lines where bill_id = p_bill) then raise exception 'Add at least one line'; end if;
  if tax_rate('VAT', b.bill_date) is null then raise exception 'No VAT rate is set for %', b.bill_date; end if;
  x := b.exchange_rate;

  perform set_config('sika.posting','on', true);
  for l in select * from bill_lines where bill_id = p_bill order by sort loop
    v_amt := round(l.qty * l.unit_cost, 2);
    g_amt := round(v_amt * x, 2);
    v_sub := v_sub + v_amt; g_sum := g_sum + g_amt;
    if l.taxable then v_taxable := v_taxable + v_amt; end if;
    if l.product_id is not null then
      update products set
        cost = round((greatest(stock_qty,0) * cost + l.qty * l.unit_cost * x) / (greatest(stock_qty,0) + l.qty), 4),
        stock_qty = stock_qty + l.qty
       where id = l.product_id;
      insert into stock_moves (company_id, product_id, move_date, qty, unit_cost, reason, ref_type, ref_id)
      values (b.company_id, l.product_id, b.bill_date, l.qty, l.unit_cost * x, 'Goods received', 'bill', b.id);
      v_lines := v_lines || jl(acct(b.company_id,'inventory'), g_amt, 0);
    else
      v_lines := v_lines || jl(l.account_id, g_amt, 0);
    end if;
  end loop;
  perform set_config('sika.posting','off', true);

  v_vat := round(v_taxable * tax_rate('VAT', b.bill_date), 2);
  v_nhil := round(v_taxable * tax_rate('NHIL', b.bill_date), 2);
  v_getf := round(v_taxable * tax_rate('GETFUND', b.bill_date), 2);
  v_total := v_sub + v_vat + v_nhil + v_getf;
  g_vat := round(v_vat * x, 2); g_nhil := round(v_nhil * x, 2); g_getf := round(v_getf * x, 2);
  v_no := next_number(b.company_id, 'BILL', 'BILL-');
  v_lines := v_lines
    || jl(acct(b.company_id,'vat_in'), g_vat, 0)
    || jl(acct(b.company_id,'nhil_in'), g_nhil, 0)
    || jl(acct(b.company_id,'getf_in'), g_getf, 0)
    || jl(acct(b.company_id,'ap'), 0, g_sum + g_vat + g_nhil + g_getf);
  v_je := post_journal(b.company_id, b.bill_date, 'Supplier bill ' || v_no || coalesce(' (' || b.supplier_ref || ')',''), v_lines, 'bill', b.id);
  update bills set status = 'posted', number = v_no, subtotal = v_sub, vat = v_vat, nhil = v_nhil,
         getfund = v_getf, total = v_total, journal_entry_id = v_je, due_date = coalesce(due_date, bill_date + 30)
   where id = p_bill;
  return v_no;
end $$;

drop function if exists public.pay_bill(uuid, numeric, date, text, text);
create or replace function public.pay_bill(p_bill uuid, p_amount numeric, p_date date, p_method text,
  p_reference text default null, p_rate numeric default null)
returns void language plpgsql security definer set search_path = public as $$
declare b bills; v_je uuid; v_pay uuid; v_rate numeric; g_bank numeric; g_ap numeric;
begin
  select * into b from bills where id = p_bill for update;
  if not found then raise exception 'Bill not found'; end if;
  perform require_member(b.company_id, array['owner','admin','accountant']);
  if b.status = 'draft' then raise exception 'Post the bill before paying it'; end if;
  if round(p_amount,2) > b.total - b.amount_paid or p_amount <= 0 then
    raise exception 'Amount must be between 0 and the % still owed', b.total - b.amount_paid;
  end if;
  v_rate := case when b.currency = 'GHS' then 1 else coalesce(nullif(p_rate,0), b.exchange_rate) end;
  g_bank := round(p_amount * v_rate, 2); g_ap := round(p_amount * b.exchange_rate, 2);
  insert into bill_payments (company_id, bill_id, payment_date, amount, method, reference, exchange_rate)
  values (b.company_id, b.id, p_date, round(p_amount,2), p_method, p_reference, v_rate) returning id into v_pay;
  v_je := post_journal(b.company_id, p_date, 'Payment to supplier for ' || b.number,
    jsonb_build_array(
      jl(acct(b.company_id,'ap'), g_ap, 0),
      jl(acct(b.company_id, p_method), 0, g_bank),
      jl(acct(b.company_id,'fx'), greatest(g_bank - g_ap, 0), greatest(g_ap - g_bank, 0))),
    'bill_payment', v_pay);
  update bill_payments set journal_entry_id = v_je where id = v_pay;
  update bills set amount_paid = amount_paid + round(p_amount,2),
    status = case when amount_paid + round(p_amount,2) >= total then 'paid' else 'posted' end
   where id = b.id;
end $$;

-- =====================================================================
-- 4. Credit notes and invoice reversals
-- =====================================================================
create table public.credit_notes (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  number text,
  customer_id uuid not null references public.customers(id),
  invoice_id uuid references public.invoices(id),
  credit_date date not null default current_date,
  status text not null default 'draft' check (status in ('draft','posted')),
  reason text,
  currency text not null default 'GHS',
  exchange_rate numeric(14,6) not null default 1 check (exchange_rate > 0),
  subtotal numeric(14,2) not null default 0,
  vat numeric(14,2) not null default 0,
  nhil numeric(14,2) not null default 0,
  getfund numeric(14,2) not null default 0,
  total numeric(14,2) not null default 0,
  applied numeric(14,2) not null default 0,
  journal_entry_id uuid references public.journal_entries(id),
  created_at timestamptz not null default now()
);

create table public.credit_note_lines (
  id uuid primary key default gen_random_uuid(),
  credit_note_id uuid not null references public.credit_notes(id) on delete cascade,
  company_id uuid not null references public.companies(id) on delete cascade,
  product_id uuid references public.products(id),
  description text not null,
  qty numeric(14,3) not null check (qty > 0),
  unit_price numeric(14,2) not null check (unit_price >= 0),
  taxable boolean not null default true,
  restock boolean not null default false,
  sort int not null default 0
);

create or replace function public.post_credit_note(p_cn uuid)
returns text language plpgsql security definer set search_path = public as $$
declare
  cn credit_notes; inv invoices; l record; p products; x numeric;
  v_taxable numeric := 0; v_sub numeric := 0; v_goods numeric := 0; v_services numeric := 0; v_restock numeric := 0;
  v_vat numeric; v_nhil numeric; v_getf numeric; v_total numeric; v_no text; v_je uuid; v_apply numeric := 0;
  v_inv_no text; g_goods numeric; g_serv numeric; g_vat numeric; g_nhil numeric; g_getf numeric;
begin
  select * into cn from credit_notes where id = p_cn for update;
  if not found then raise exception 'Credit note not found'; end if;
  perform require_member(cn.company_id, array['owner','admin','accountant','sales']);
  if cn.status <> 'draft' then raise exception 'This credit note is already posted'; end if;
  if not exists (select 1 from credit_note_lines where credit_note_id = p_cn) then raise exception 'Add at least one line'; end if;
  if cn.invoice_id is not null then
    select * into inv from invoices where id = cn.invoice_id for update;
    if inv.status = 'draft' then raise exception 'The linked invoice is still a draft; delete or edit it instead'; end if;
    if inv.customer_id <> cn.customer_id then raise exception 'The linked invoice belongs to another customer'; end if;
    if inv.currency <> cn.currency then raise exception 'The credit note must be in the invoice currency (%)', inv.currency; end if;
    v_inv_no := inv.number;
  end if;
  x := cn.exchange_rate;

  perform set_config('sika.posting','on', true);
  for l in select * from credit_note_lines where credit_note_id = p_cn order by sort loop
    v_sub := v_sub + round(l.qty * l.unit_price, 2);
    if l.taxable then v_taxable := v_taxable + round(l.qty * l.unit_price, 2); end if;
    if l.product_id is not null then
      v_goods := v_goods + round(l.qty * l.unit_price, 2);
      if l.restock then
        select * into p from products where id = l.product_id for update;
        update products set stock_qty = stock_qty + l.qty where id = p.id;
        insert into stock_moves (company_id, product_id, move_date, qty, unit_cost, reason, ref_type, ref_id)
        values (cn.company_id, p.id, cn.credit_date, l.qty, p.cost, 'Customer return', 'credit_note', cn.id);
        v_restock := v_restock + round(l.qty * p.cost, 2);
      end if;
    else
      v_services := v_services + round(l.qty * l.unit_price, 2);
    end if;
  end loop;
  perform set_config('sika.posting','off', true);

  v_vat := round(v_taxable * tax_rate('VAT', cn.credit_date), 2);
  v_nhil := round(v_taxable * tax_rate('NHIL', cn.credit_date), 2);
  v_getf := round(v_taxable * tax_rate('GETFUND', cn.credit_date), 2);
  v_total := v_sub + v_vat + v_nhil + v_getf;
  g_goods := round(v_goods * x, 2); g_serv := round(v_services * x, 2);
  g_vat := round(v_vat * x, 2); g_nhil := round(v_nhil * x, 2); g_getf := round(v_getf * x, 2);
  v_no := next_number(cn.company_id, 'CN', 'CN-');

  v_je := post_journal(cn.company_id, cn.credit_date, 'Credit note ' || v_no || coalesce(' against ' || v_inv_no, ''),
    jsonb_build_array(
      jl(acct(cn.company_id,'sales'), g_goods, 0),
      jl(acct(cn.company_id,'services'), g_serv, 0),
      jl(acct(cn.company_id,'vat_out'), g_vat, 0),
      jl(acct(cn.company_id,'nhil_out'), g_nhil, 0),
      jl(acct(cn.company_id,'getf_out'), g_getf, 0),
      jl(acct(cn.company_id,'ar'), 0, g_goods + g_serv + g_vat + g_nhil + g_getf),
      jl(acct(cn.company_id,'inventory'), v_restock, 0),
      jl(acct(cn.company_id,'cogs'), 0, v_restock)),
    'credit_note', cn.id);

  if cn.invoice_id is not null then
    v_apply := least(v_total, inv.total - inv.amount_paid - inv.amount_credited);
    update invoices set amount_credited = amount_credited + v_apply,
      status = case when amount_paid + amount_credited + v_apply >= total then 'paid' else status end
     where id = inv.id;
  end if;
  update credit_notes set status = 'posted', number = v_no, subtotal = v_sub, vat = v_vat, nhil = v_nhil,
    getfund = v_getf, total = v_total, applied = v_apply, journal_entry_id = v_je where id = p_cn;
  return v_no;
end $$;

-- Full reversal: a credit note copying every line of the invoice, returning stock, posted at once.
create or replace function public.reverse_invoice(p_invoice uuid, p_date date, p_reason text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare inv invoices; v_cn uuid;
begin
  select * into inv from invoices where id = p_invoice;
  if not found then raise exception 'Invoice not found'; end if;
  perform require_member(inv.company_id, array['owner','admin','accountant','sales']);
  if inv.status = 'draft' then raise exception 'Drafts can simply be deleted'; end if;
  if exists (select 1 from credit_notes where invoice_id = p_invoice and status = 'posted' and total >= inv.total) then
    raise exception 'This invoice has already been reversed';
  end if;
  insert into credit_notes (company_id, customer_id, invoice_id, credit_date, reason, currency, exchange_rate)
  values (inv.company_id, inv.customer_id, inv.id, p_date, coalesce(p_reason, 'Reversal of ' || inv.number), inv.currency, inv.exchange_rate)
  returning id into v_cn;
  insert into credit_note_lines (credit_note_id, company_id, product_id, description, qty, unit_price, taxable, restock, sort)
  select v_cn, company_id, product_id, description, qty, unit_price, taxable, product_id is not null, sort
    from invoice_lines where invoice_id = p_invoice;
  perform post_credit_note(v_cn);
  return v_cn;
end $$;

-- =====================================================================
-- 5. Quotes and sales orders
-- =====================================================================
create table public.sales_quotes (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  number text,
  kind text not null default 'quote' check (kind in ('quote','order')),
  customer_id uuid not null references public.customers(id),
  quote_date date not null default current_date,
  valid_until date,
  status text not null default 'draft' check (status in ('draft','sent','accepted','declined','converted')),
  currency text not null default 'GHS',
  exchange_rate numeric(14,6) not null default 1,
  subtotal numeric(14,2) not null default 0,
  total numeric(14,2) not null default 0,
  notes text,
  invoice_id uuid references public.invoices(id),
  created_at timestamptz not null default now()
);

create table public.sales_quote_lines (
  id uuid primary key default gen_random_uuid(),
  quote_id uuid not null references public.sales_quotes(id) on delete cascade,
  company_id uuid not null references public.companies(id) on delete cascade,
  product_id uuid references public.products(id),
  description text not null,
  qty numeric(14,3) not null check (qty > 0),
  unit_price numeric(14,2) not null check (unit_price >= 0),
  taxable boolean not null default true,
  sort int not null default 0
);

create or replace function public.number_quote() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.number is null then
    new.number := case when new.kind = 'order' then next_number(new.company_id, 'SO', 'SO-') else next_number(new.company_id, 'QUO', 'QUO-') end;
  end if;
  return new;
end $$;
create trigger sales_quotes_number before insert on public.sales_quotes for each row execute function public.number_quote();

create or replace function public.convert_quote(p_quote uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare qt sales_quotes; v_inv uuid;
begin
  select * into qt from sales_quotes where id = p_quote for update;
  if not found then raise exception 'Quote not found'; end if;
  perform require_member(qt.company_id, array['owner','admin','accountant','sales']);
  if qt.status = 'converted' then raise exception 'Already converted to an invoice'; end if;
  insert into invoices (company_id, customer_id, invoice_date, notes, currency, exchange_rate)
  values (qt.company_id, qt.customer_id, current_date, coalesce(qt.notes, '') || case when qt.notes is null then '' else E'\n' end || 'From ' || qt.number,
          qt.currency, qt.exchange_rate)
  returning id into v_inv;
  insert into invoice_lines (invoice_id, company_id, product_id, description, qty, unit_price, taxable, sort)
  select v_inv, company_id, product_id, description, qty, unit_price, taxable, sort from sales_quote_lines where quote_id = p_quote;
  update sales_quotes set status = 'converted', invoice_id = v_inv where id = p_quote;
  return v_inv;
end $$;

-- =====================================================================
-- 6. Recurring invoices
-- =====================================================================
create table public.recurring_invoices (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  name text not null,
  customer_id uuid not null references public.customers(id),
  frequency text not null default 'monthly' check (frequency in ('weekly','monthly','quarterly','yearly')),
  next_date date not null,
  end_date date,
  auto_post boolean not null default false,
  active boolean not null default true,
  currency text not null default 'GHS',
  lines jsonb not null default '[]'::jsonb,   -- [{product_id, description, qty, unit_price, taxable}]
  notes text,
  last_generated date,
  created_at timestamptz not null default now()
);

create or replace function public.run_recurring(cid uuid)
returns int language plpgsql security definer set search_path = public as $$
declare
  r recurring_invoices; v_inv uuid; v_count int := 0; v_rate numeric; v_step interval; v_date date; l jsonb; i int;
begin
  perform require_member(cid, array['owner','admin','accountant','sales']);
  for r in select * from recurring_invoices where company_id = cid and active and next_date <= current_date
             and (end_date is null or next_date <= end_date) for update loop
    v_step := case r.frequency when 'weekly' then interval '7 days' when 'monthly' then interval '1 month'
                               when 'quarterly' then interval '3 months' else interval '1 year' end;
    v_date := r.next_date;
    while v_date <= current_date and (r.end_date is null or v_date <= r.end_date) loop
      v_rate := case when r.currency = 'GHS' then 1 else (select rate from currencies where company_id = cid and code = r.currency) end;
      if v_rate is null then raise exception 'Set an exchange rate for % under Settings before generating %', r.currency, r.name; end if;
      insert into invoices (company_id, customer_id, invoice_date, notes, currency, exchange_rate)
      values (cid, r.customer_id, v_date, coalesce(r.notes, r.name), r.currency, v_rate) returning id into v_inv;
      i := 0;
      for l in select * from jsonb_array_elements(r.lines) loop
        insert into invoice_lines (invoice_id, company_id, product_id, description, qty, unit_price, taxable, sort)
        values (v_inv, cid, nullif(l->>'product_id','')::uuid, l->>'description', (l->>'qty')::numeric,
                (l->>'unit_price')::numeric, coalesce((l->>'taxable')::boolean, true), i);
        i := i + 1;
      end loop;
      if r.auto_post then
        begin
          perform post_invoice(v_inv);
        exception when others then
          update invoices set notes = coalesce(notes,'') || E'\nNot posted automatically: ' || sqlerrm where id = v_inv;
        end;
      end if;
      v_count := v_count + 1;
      v_date := (v_date + v_step)::date;
    end loop;
    update recurring_invoices set next_date = v_date, last_generated = current_date,
      active = case when end_date is not null and v_date > end_date then false else active end
     where id = r.id;
  end loop;
  return v_count;
end $$;

-- =====================================================================
-- 7. Payroll extras: overtime and bonus tax, Tier 3, staff loans
-- =====================================================================
alter table public.employees add column if not exists is_junior boolean not null default false;
alter table public.employees add column if not exists tier3_employee_rate numeric(6,4) not null default 0 check (tier3_employee_rate >= 0 and tier3_employee_rate <= 0.5);
alter table public.employees add column if not exists tier3_employer_rate numeric(6,4) not null default 0 check (tier3_employer_rate >= 0 and tier3_employer_rate <= 0.5);

alter table public.payslips add column if not exists overtime numeric(14,2) not null default 0;
alter table public.payslips add column if not exists bonus numeric(14,2) not null default 0;
alter table public.payslips add column if not exists overtime_tax numeric(14,2) not null default 0;
alter table public.payslips add column if not exists bonus_tax numeric(14,2) not null default 0;
alter table public.payslips add column if not exists tier3_employee numeric(14,2) not null default 0;
alter table public.payslips add column if not exists tier3_employer numeric(14,2) not null default 0;
alter table public.payslips add column if not exists loan_deduction numeric(14,2) not null default 0;

alter table public.statutory_rates alter column rate type numeric(14,5);
insert into public.statutory_rates values
  ('OVERTIME_LOW', 0.05, '2015-01-01'),     -- junior staff, up to 50% of monthly basic
  ('OVERTIME_HIGH', 0.10, '2015-01-01'),    -- junior staff, above 50% of monthly basic
  ('OVERTIME_INCOME_LIMIT', 18000, '2015-01-01'), -- annual employment income limit for junior-staff rates
  ('BONUS_RATE', 0.05, '2015-01-01'),
  ('BONUS_CAP', 0.15, '2015-01-01'),        -- of annual basic salary, cumulative per year
  ('TIER3_RELIEF', 0.165, '2015-01-01')     -- of monthly income
on conflict do nothing;

create table public.payroll_inputs (
  company_id uuid not null references public.companies(id) on delete cascade,
  period date not null,
  employee_id uuid not null references public.employees(id) on delete cascade,
  overtime numeric(14,2) not null default 0 check (overtime >= 0),
  bonus numeric(14,2) not null default 0 check (bonus >= 0),
  primary key (company_id, period, employee_id)
);

create table public.employee_loans (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  employee_id uuid not null references public.employees(id),
  issue_date date not null,
  principal numeric(14,2) not null check (principal > 0),
  installment numeric(14,2) not null check (installment > 0),
  balance numeric(14,2) not null,
  status text not null default 'active' check (status in ('active','settled')),
  note text,
  journal_entry_id uuid references public.journal_entries(id),
  created_at timestamptz not null default now()
);

create table public.loan_repayments (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  loan_id uuid not null references public.employee_loans(id) on delete cascade,
  run_id uuid references public.payroll_runs(id),
  repay_date date not null,
  amount numeric(14,2) not null
);

create or replace function public.issue_loan(p_employee uuid, p_principal numeric, p_installment numeric,
  p_date date, p_method text, p_note text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare e employees; v_id uuid; v_je uuid;
begin
  select * into e from employees where id = p_employee;
  if not found then raise exception 'Employee not found'; end if;
  perform require_member(e.company_id, array['owner','admin','accountant']);
  if p_installment > p_principal then raise exception 'The monthly deduction cannot be more than the loan'; end if;
  insert into employee_loans (company_id, employee_id, issue_date, principal, installment, balance, note)
  values (e.company_id, e.id, p_date, round(p_principal,2), round(p_installment,2), round(p_principal,2), p_note) returning id into v_id;
  v_je := post_journal(e.company_id, p_date, 'Staff loan to ' || e.full_name,
    jsonb_build_array(jl(acct(e.company_id,'staff_loans'), p_principal, 0), jl(acct(e.company_id, p_method), 0, p_principal)),
    'loan', v_id);
  update employee_loans set journal_entry_id = v_je where id = v_id;
  return v_id;
end $$;

create or replace function public.prepare_payroll(cid uuid, p_period date)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_run uuid; v_period date := date_trunc('month', p_period)::date; v_status text; v_payday date;
  e record; v_ot numeric; v_bonus numeric; v_gross numeric; v_emp numeric; v_er numeric; v_t2 numeric;
  v_t3e numeric; v_t3r numeric; v_ot_tax numeric; v_ot_taxable numeric; v_ot_low numeric;
  v_ytd numeric; v_cap_left numeric; v_b_conc numeric; v_bonus_tax numeric; v_bonus_taxable numeric;
  v_relief_cap numeric; v_t3_relief numeric; v_t3_excess numeric; v_charge numeric; v_paye numeric;
  v_before numeric; v_loan numeric; v_net numeric;
begin
  perform require_member(cid, array['owner','admin','hr','accountant']);
  v_payday := (v_period + interval '1 month - 1 day')::date;
  select id, status into v_run, v_status from payroll_runs where company_id = cid and period = v_period;
  if v_run is not null and v_status <> 'draft' then raise exception 'Payroll for this month is already posted'; end if;
  if v_run is null then
    insert into payroll_runs (company_id, period) values (cid, v_period) returning id into v_run;
  else
    delete from payslips where run_id = v_run;
  end if;

  for e in select * from employees where company_id = cid and status = 'active' order by full_name loop
    select coalesce(max(overtime),0), coalesce(max(bonus),0) into v_ot, v_bonus
      from payroll_inputs where company_id = cid and period = v_period and employee_id = e.id;
    v_gross := e.basic_salary + e.allowances + v_ot + v_bonus;
    v_emp := round(e.basic_salary * stat_rate('SSNIT_EMPLOYEE', v_payday), 2);
    v_er := round(e.basic_salary * stat_rate('SSNIT_EMPLOYER', v_payday), 2);
    v_t2 := round(e.basic_salary * stat_rate('TIER2', v_payday), 2);
    v_t3e := round(e.basic_salary * e.tier3_employee_rate, 2);
    v_t3r := round(e.basic_salary * e.tier3_employer_rate, 2);

    -- Overtime: final tax for qualifying junior staff, otherwise ordinary employment income.
    if v_ot > 0 and e.is_junior and (e.basic_salary + e.allowances) * 12 <= stat_rate('OVERTIME_INCOME_LIMIT', v_payday) then
      v_ot_low := least(v_ot, 0.5 * e.basic_salary);
      v_ot_tax := round(v_ot_low * stat_rate('OVERTIME_LOW', v_payday) + (v_ot - v_ot_low) * stat_rate('OVERTIME_HIGH', v_payday), 2);
      v_ot_taxable := 0;
    else
      v_ot_tax := 0; v_ot_taxable := v_ot;
    end if;

    -- Bonus: 5% final tax within 15% of annual basic (cumulative this calendar year); excess through PAYE.
    select coalesce(sum(s.bonus),0) into v_ytd from payslips s join payroll_runs r on r.id = s.run_id
     where r.company_id = cid and s.employee_id = e.id and r.period <> v_period
       and extract(year from r.period) = extract(year from v_period);
    v_cap_left := greatest(0, stat_rate('BONUS_CAP', v_payday) * e.basic_salary * 12 - v_ytd);
    v_b_conc := least(v_bonus, v_cap_left);
    v_bonus_tax := round(v_b_conc * stat_rate('BONUS_RATE', v_payday), 2);
    v_bonus_taxable := v_bonus - v_b_conc;

    -- Tier 3: employee + employer contributions relieved up to 16.5% of monthly income.
    v_relief_cap := round(stat_rate('TIER3_RELIEF', v_payday) * (e.basic_salary + e.allowances), 2);
    v_t3_relief := least(v_t3e, greatest(0, v_relief_cap - v_t3r));
    v_t3_excess := greatest(0, v_t3r - v_relief_cap);

    v_charge := e.basic_salary + e.allowances + v_ot_taxable + v_bonus_taxable + v_t3_excess - v_emp - v_t3_relief;
    v_paye := compute_paye(v_charge, v_payday);
    v_before := v_gross - v_emp - v_t3e - v_paye - v_ot_tax - v_bonus_tax;
    select coalesce(sum(least(installment, balance)),0) into v_loan from employee_loans
     where employee_id = e.id and status = 'active' and issue_date <= v_payday;
    v_loan := least(greatest(v_before, 0), v_loan);
    v_net := v_before - v_loan;

    insert into payslips (run_id, company_id, employee_id, basic, allowances, gross, ssnit_employee, chargeable,
                          paye, net, ssnit_employer, tier1, tier2, overtime, bonus, overtime_tax, bonus_tax,
                          tier3_employee, tier3_employer, loan_deduction)
    values (v_run, cid, e.id, e.basic_salary, e.allowances, v_gross, v_emp, v_charge,
            v_paye, v_net, v_er, v_emp + v_er - v_t2, v_t2, v_ot, v_bonus, v_ot_tax, v_bonus_tax,
            v_t3e, v_t3r, v_loan);
  end loop;

  update payroll_runs r set
    gross = coalesce(s.gross,0), paye = coalesce(s.tax,0), ssnit_employee = coalesce(s.emp,0),
    ssnit_employer = coalesce(s.er,0), net = coalesce(s.net,0)
  from (select sum(gross) gross, sum(paye + overtime_tax + bonus_tax) tax, sum(ssnit_employee) emp,
               sum(ssnit_employer) er, sum(net) net from payslips where run_id = v_run) s
  where r.id = v_run;
  return v_run;
end $$;

create or replace function public.post_payroll(p_run uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  r payroll_runs; v_t1 numeric; v_t2 numeric; v_t3e numeric; v_t3r numeric; v_loans numeric;
  v_je uuid; v_date date; s record; ln record; v_left numeric; v_take numeric;
begin
  select * into r from payroll_runs where id = p_run for update;
  if not found then raise exception 'Payroll run not found'; end if;
  perform require_member(r.company_id, array['owner','admin','accountant']);
  if r.status <> 'draft' then raise exception 'This payroll is already posted'; end if;
  if r.gross = 0 then raise exception 'There are no payslips in this run'; end if;
  select sum(tier1), sum(tier2), sum(tier3_employee), sum(tier3_employer), sum(loan_deduction)
    into v_t1, v_t2, v_t3e, v_t3r, v_loans from payslips where run_id = p_run;
  v_date := (r.period + interval '1 month - 1 day')::date;
  v_je := post_journal(r.company_id, v_date, 'Payroll ' || to_char(r.period, 'Mon YYYY'),
    jsonb_build_array(
      jl(acct(r.company_id,'salaries'), r.gross, 0),
      jl(acct(r.company_id,'employer_ssnit'), r.ssnit_employer, 0),
      jl(acct(r.company_id,'employer_tier3'), v_t3r, 0),
      jl(acct(r.company_id,'paye'), 0, r.paye),
      jl(acct(r.company_id,'ssnit1'), 0, v_t1),
      jl(acct(r.company_id,'tier2'), 0, v_t2),
      jl(acct(r.company_id,'tier3'), 0, v_t3e + v_t3r),
      jl(acct(r.company_id,'staff_loans'), 0, v_loans),
      jl(acct(r.company_id,'net_pay'), 0, r.net)),
    'payroll', r.id);

  -- Apply loan deductions to loans, oldest first.
  for s in select * from payslips where run_id = p_run and loan_deduction > 0 loop
    v_left := s.loan_deduction;
    for ln in select * from employee_loans where employee_id = s.employee_id and status = 'active' order by issue_date, created_at for update loop
      exit when v_left <= 0;
      v_take := least(v_left, ln.installment, ln.balance);
      update employee_loans set balance = balance - v_take, status = case when balance - v_take <= 0 then 'settled' else 'active' end where id = ln.id;
      insert into loan_repayments (company_id, loan_id, run_id, repay_date, amount) values (r.company_id, ln.id, p_run, v_date, v_take);
      v_left := v_left - v_take;
    end loop;
  end loop;
  update payroll_runs set status = 'posted', journal_entry_id = v_je where id = p_run;
end $$;

-- =====================================================================
-- 8. Leave entitlements and balances
-- =====================================================================
create table public.leave_types (
  company_id uuid not null references public.companies(id) on delete cascade,
  code text not null,
  name text not null,
  days_per_year numeric(5,1),    -- null = no annual limit
  paid boolean not null default true,
  primary key (company_id, code)
);

create table public.leave_entitlements (
  company_id uuid not null references public.companies(id) on delete cascade,
  employee_id uuid not null references public.employees(id) on delete cascade,
  leave_code text not null,
  year int not null,
  days numeric(5,1) not null,      -- overrides the type's default, e.g. long service or carry-over
  primary key (employee_id, leave_code, year)
);

create or replace function public.seed_leave_types(cid uuid)
returns void language sql security definer set search_path = public as $$
  insert into leave_types (company_id, code, name, days_per_year, paid) values
  (cid,'annual','Annual',15,true),
  (cid,'sick','Sick',null,true),
  (cid,'maternity','Maternity',null,true),
  (cid,'paternity','Paternity',null,true),
  (cid,'compassionate','Compassionate',null,true),
  (cid,'study','Study',null,true),
  (cid,'unpaid','Unpaid',null,false)
  on conflict do nothing;
$$;
select public.seed_leave_types(id) from public.companies;

create or replace function public.leave_balances(cid uuid, p_year int)
returns table (employee_id uuid, full_name text, leave_code text, leave_name text,
               entitlement numeric, taken numeric, pending numeric, remaining numeric)
language sql stable security definer set search_path = public as $$
  select e.id, e.full_name, t.code, t.name,
    coalesce(en.days, t.days_per_year),
    coalesce((select sum(days) from leave_requests r where r.employee_id = e.id and r.leave_type = t.code
               and r.status = 'approved' and extract(year from r.start_date) = p_year), 0),
    coalesce((select sum(days) from leave_requests r where r.employee_id = e.id and r.leave_type = t.code
               and r.status = 'pending' and extract(year from r.start_date) = p_year), 0),
    coalesce(en.days, t.days_per_year) - coalesce((select sum(days) from leave_requests r where r.employee_id = e.id
               and r.leave_type = t.code and r.status = 'approved' and extract(year from r.start_date) = p_year), 0)
  from employees e
  cross join leave_types t
  left join leave_entitlements en on en.employee_id = e.id and en.leave_code = t.code and en.year = p_year
  where e.company_id = cid and t.company_id = cid and e.status = 'active' and is_member(cid)
  order by e.full_name, t.name;
$$;

-- =====================================================================
-- 9. Recruitment and appraisals
-- =====================================================================
create table public.job_openings (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  title text not null,
  department text,
  location text,
  employment_type text default 'Full-time',
  description text,
  closing_date date,
  status text not null default 'open' check (status in ('open','closed','filled')),
  created_at timestamptz not null default now()
);

create table public.applicants (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  opening_id uuid not null references public.job_openings(id) on delete cascade,
  full_name text not null,
  email text, phone text,
  stage text not null default 'applied' check (stage in ('applied','screening','interview','offer','hired','rejected')),
  rating int check (rating between 1 and 5),
  notes text,
  employee_id uuid references public.employees(id),
  created_at timestamptz not null default now()
);

create table public.appraisals (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  employee_id uuid not null references public.employees(id) on delete cascade,
  period_label text not null,          -- e.g. "2026 annual", "H1 2026"
  review_date date not null default current_date,
  reviewer text,
  rating int check (rating between 1 and 5),
  achievements text,
  strengths text,
  improvements text,
  goals text,
  employee_comments text,
  status text not null default 'draft' check (status in ('draft','completed')),
  created_at timestamptz not null default now()
);

-- =====================================================================
-- 10. Bank reconciliation
-- =====================================================================
create table public.bank_reconciliations (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  account_id uuid not null references public.accounts(id),
  statement_date date not null,
  statement_balance numeric(14,2) not null,
  completed_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);
alter table public.journal_lines add column if not exists reconciliation_id uuid references public.bank_reconciliations(id);

create or replace function public.complete_reconciliation(cid uuid, p_account uuid, p_date date, p_balance numeric, p_lines uuid[])
returns uuid language plpgsql security definer set search_path = public as $$
declare v_open numeric; v_sel numeric; v_bad int; v_id uuid;
begin
  perform require_member(cid, array['owner','admin','accountant']);
  if not exists (select 1 from accounts where id = p_account and company_id = cid and system_key in ('bank','momo','cash')) then
    raise exception 'Choose a bank, Mobile Money or cash account';
  end if;
  select count(*) into v_bad from journal_lines l join journal_entries e on e.id = l.entry_id
   where l.id = any(p_lines) and (l.account_id <> p_account or l.reconciliation_id is not null or e.entry_date > p_date);
  if v_bad > 0 or (select count(*) from journal_lines where id = any(p_lines)) <> coalesce(array_length(p_lines,1),0) then
    raise exception 'Some ticked lines are not valid for this account and date';
  end if;
  select coalesce(sum(debit - credit),0) into v_open from journal_lines where account_id = p_account and reconciliation_id is not null;
  select coalesce(sum(debit - credit),0) into v_sel from journal_lines where id = any(p_lines);
  if round(v_open + v_sel, 2) <> round(p_balance, 2) then
    raise exception 'Cleared balance % does not match the statement balance % (difference %)', round(v_open + v_sel,2), round(p_balance,2), round(p_balance - v_open - v_sel, 2);
  end if;
  insert into bank_reconciliations (company_id, account_id, statement_date, statement_balance)
  values (cid, p_account, p_date, p_balance) returning id into v_id;
  update journal_lines set reconciliation_id = v_id where id = any(p_lines);
  return v_id;
end $$;

create or replace function public.undo_reconciliation(p_rec uuid)
returns void language plpgsql security definer set search_path = public as $$
declare rec bank_reconciliations;
begin
  select * into rec from bank_reconciliations where id = p_rec;
  if not found then raise exception 'Reconciliation not found'; end if;
  perform require_member(rec.company_id, array['owner','admin','accountant']);
  if exists (select 1 from bank_reconciliations where account_id = rec.account_id and created_at > rec.created_at) then
    raise exception 'Undo the later reconciliations for this account first';
  end if;
  update journal_lines set reconciliation_id = null where reconciliation_id = p_rec;
  delete from bank_reconciliations where id = p_rec;
end $$;

-- =====================================================================
-- 11. Budgets
-- =====================================================================
create table public.budgets (
  company_id uuid not null references public.companies(id) on delete cascade,
  account_id uuid not null references public.accounts(id) on delete cascade,
  year int not null,
  month int not null check (month between 1 and 12),
  amount numeric(14,2) not null default 0,
  primary key (account_id, year, month)
);

create or replace function public.monthly_actuals(cid uuid, p_year int)
returns table (account_id uuid, month int, debit numeric, credit numeric)
language sql stable security definer set search_path = public as $$
  select l.account_id, extract(month from e.entry_date)::int, sum(l.debit), sum(l.credit)
    from journal_lines l join journal_entries e on e.id = l.entry_id
   where l.company_id = cid and extract(year from e.entry_date) = p_year
     and has_role(cid, array['owner','admin','accountant'])
   group by l.account_id, extract(month from e.entry_date);
$$;

-- =====================================================================
-- 12. New company set-up includes the v1.1 defaults
-- =====================================================================
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
  perform seed_leave_types(v);
  return v;
end $$;

-- =====================================================================
-- 13. Row-level security for new tables
-- =====================================================================
do $$ declare t text; begin
  -- any member reads and writes
  foreach t in array array['currencies','sales_quotes','recurring_invoices'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy "members read" on public.%I for select using (is_member(company_id))', t);
    execute format('create policy "members insert" on public.%I for insert with check (is_member(company_id))', t);
    execute format('create policy "members update" on public.%I for update using (is_member(company_id))', t);
    execute format('create policy "members delete" on public.%I for delete using (is_member(company_id))', t);
  end loop;
  -- HR data: owners, admins and HR write; accountants read
  foreach t in array array['job_openings','applicants','appraisals','leave_entitlements','payroll_inputs'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy "hr reads" on public.%I for select using (has_role(company_id, array[''owner'',''admin'',''hr'',''accountant'']))', t);
    execute format('create policy "hr writes" on public.%I for all using (has_role(company_id, array[''owner'',''admin'',''hr''])) with check (has_role(company_id, array[''owner'',''admin'',''hr'']))', t);
  end loop;
  -- accounting data written by accountants
  foreach t in array array['budgets'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy "accountants read" on public.%I for select using (has_role(company_id, array[''owner'',''admin'',''accountant'']))', t);
    execute format('create policy "accountants write" on public.%I for all using (has_role(company_id, array[''owner'',''admin'',''accountant''])) with check (has_role(company_id, array[''owner'',''admin'',''accountant'']))', t);
  end loop;
  -- read-only, written by functions
  foreach t in array array['bank_reconciliations','loan_repayments'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy "accountants read" on public.%I for select using (has_role(company_id, array[''owner'',''admin'',''accountant'',''hr'']))', t);
  end loop;
end $$;

alter table public.employee_loans enable row level security;
create policy "payroll staff read loans" on public.employee_loans for select using (has_role(company_id, array['owner','admin','accountant','hr']));

alter table public.leave_types enable row level security;
create policy "members read leave types" on public.leave_types for select using (is_member(company_id));
create policy "hr writes leave types" on public.leave_types for all
  using (has_role(company_id, array['owner','admin','hr'])) with check (has_role(company_id, array['owner','admin','hr']));

-- Credit notes: like invoices, editable only while draft.
alter table public.credit_notes enable row level security;
create policy "members read" on public.credit_notes for select using (is_member(company_id));
create policy "members insert drafts" on public.credit_notes for insert with check (is_member(company_id) and status = 'draft');
create policy "members edit drafts" on public.credit_notes for update using (is_member(company_id) and status = 'draft') with check (status = 'draft');
create policy "members delete drafts" on public.credit_notes for delete using (is_member(company_id) and status = 'draft');
alter table public.credit_note_lines enable row level security;
create policy "members read" on public.credit_note_lines for select using (is_member(company_id));
create policy "members write draft lines" on public.credit_note_lines for all
  using (is_member(company_id) and exists (select 1 from credit_notes c where c.id = credit_note_id and c.status = 'draft'))
  with check (is_member(company_id) and exists (select 1 from credit_notes c where c.id = credit_note_id and c.status = 'draft'));

alter table public.sales_quote_lines enable row level security;
create policy "members read" on public.sales_quote_lines for select using (is_member(company_id));
create policy "members write" on public.sales_quote_lines for all using (is_member(company_id)) with check (is_member(company_id));

-- Function permissions
revoke execute on all functions in schema public from public, anon;
grant execute on all functions in schema public to authenticated;
revoke execute on function public.post_journal(uuid,date,text,jsonb,text,uuid) from authenticated;
revoke execute on function public.seed_accounts(uuid) from authenticated;
revoke execute on function public.seed_accounts_v11(uuid) from authenticated;
revoke execute on function public.seed_leave_types(uuid) from authenticated;
revoke execute on function public.next_number(uuid,text,text) from authenticated;


-- ======================================================================
-- 0003_asnys_v1_2.sql
-- ======================================================================
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


-- ======================================================================
-- 0004_asnys_v1_3.sql
-- ======================================================================
-- Sika ERP v1.3
-- Run once in the Supabase SQL editor AFTER 0001, 0002 and 0003.
-- Adds: the Project Manager role; project templates, billing types and milestones, task planning (Gantt),
-- budgets and forecasts, issues, status updates, documents and portfolio KPIs; and CRM: customer 360,
-- campaigns and lead scoring, support cases with a public help centre and knowledge base, partners,
-- sales and partner commissions, and sales forecasting.

-- =====================================================================
-- 1. Project Manager role
-- =====================================================================
alter table public.memberships drop constraint if exists memberships_role_check;
alter table public.memberships add constraint memberships_role_check
  check (role in ('owner','admin','accountant','sales','hr','project_manager','staff'));

create or replace function public.add_member(cid uuid, p_email text, p_role text)
returns void language plpgsql security definer set search_path = public as $$
declare v_user uuid;
begin
  perform require_member(cid, array['owner','admin']);
  if p_role not in ('admin','accountant','sales','hr','project_manager','staff') then raise exception 'Choose a valid role'; end if;
  select id into v_user from auth.users where lower(email) = lower(trim(p_email));
  if v_user is null then
    raise exception 'No account uses %. Ask them to sign up first, then add them again.', p_email;
  end if;
  insert into memberships (company_id, user_id, email, role) values (cid, v_user, lower(trim(p_email)), p_role)
  on conflict (company_id, user_id) do update set role = excluded.role;
end $$;

-- =====================================================================
-- 2. New system accounts
-- =====================================================================
create or replace function public.seed_accounts_v13(cid uuid)
returns void language sql security definer set search_path = public as $$
  insert into accounts (company_id, code, name, type, system_key) values
  (cid,'2250','Commissions payable','liability','commission_pay'),
  (cid,'6150','Sales and partner commissions','expense','commissions')
  on conflict do nothing;
$$;
select public.seed_accounts_v13(id) from public.companies;

-- =====================================================================
-- 3. Projects: manager, billing type, numbering, templates
-- =====================================================================
alter table public.projects add column if not exists number text;
alter table public.projects add column if not exists manager_id uuid default auth.uid();
alter table public.projects add column if not exists billing_type text not null default 'time_materials'
  check (billing_type in ('time_materials','fixed_price','non_billable'));
alter table public.projects add column if not exists contract_value numeric(14,2) not null default 0;   -- project currency
alter table public.projects add column if not exists percent_complete_override int check (percent_complete_override between 0 and 100);
alter table public.projects add column if not exists health text not null default 'on_track' check (health in ('on_track','at_risk','off_track'));
alter table public.projects add column if not exists is_template boolean not null default false;
alter table public.projects add column if not exists sales_order_id uuid references public.sales_quotes(id) on delete set null;

create or replace function public.number_project() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if (new.number is null or new.number = '') and not new.is_template then new.number := next_number(new.company_id, 'PRJ', 'PRJ-'); end if;
  return new;
end $$;
create trigger projects_number before insert on public.projects for each row execute function public.number_project();

alter table public.tasks add column if not exists start_date date;
alter table public.tasks add column if not exists estimated_hours numeric(8,2);
alter table public.tasks add column if not exists percent_complete int check (percent_complete between 0 and 100);
alter table public.tasks add column if not exists predecessor_id uuid references public.tasks(id) on delete set null;
alter table public.tasks add column if not exists is_milestone boolean not null default false;
alter table public.tasks add column if not exists sort int not null default 0;
alter table public.tasks add column if not exists description text;

-- Who may manage a project: owners, admins, accountants and HR for any project; a project manager for their own.
create or replace function public.can_manage_project(pid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from projects p where p.id = pid and (
    has_role(p.company_id, array['owner','admin','accountant','hr'])
    or (has_role(p.company_id, array['project_manager']) and p.manager_id = auth.uid())));
$$;

create table public.project_milestones (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  project_id uuid not null references public.projects(id) on delete cascade,
  name text not null,
  due_date date,
  amount numeric(14,2) not null default 0,          -- project currency
  task_id uuid references public.tasks(id) on delete set null,
  status text not null default 'planned' check (status in ('planned','ready','invoiced')),
  invoice_id uuid references public.invoices(id) on delete set null,
  sort int not null default 0,
  created_at timestamptz not null default now()
);

create table public.project_budget_lines (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  project_id uuid not null references public.projects(id) on delete cascade,
  category text not null default 'labour' check (category in ('labour','expenses','materials','subcontract','other')),
  description text,
  cost_budget numeric(14,2) not null default 0,     -- GHS
  revenue_budget numeric(14,2) not null default 0,  -- GHS
  sort int not null default 0
);

create table public.project_issues (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  project_id uuid not null references public.projects(id) on delete cascade,
  task_id uuid references public.tasks(id) on delete set null,
  title text not null,
  description text,
  kind text not null default 'issue' check (kind in ('issue','risk','change_request')),
  severity text not null default 'medium' check (severity in ('low','medium','high','critical')),
  status text not null default 'open' check (status in ('open','in_progress','resolved','closed')),
  assignee_id uuid references public.employees(id) on delete set null,
  reported_by uuid default auth.uid(),
  due_date date,
  resolution text,
  resolved_at timestamptz,
  created_at timestamptz not null default now()
);

create table public.project_updates (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  project_id uuid not null references public.projects(id) on delete cascade,
  health text not null check (health in ('on_track','at_risk','off_track')),
  summary text not null,
  author_id uuid default auth.uid(),
  author_email text,
  created_at timestamptz not null default now()
);

create or replace function public.project_update_sync() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.author_email := (select email from auth.users where id = auth.uid());
  update projects set health = new.health where id = new.project_id;
  return new;
end $$;
create trigger project_updates_sync before insert on public.project_updates for each row execute function public.project_update_sync();

create table public.project_documents (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  project_id uuid not null references public.projects(id) on delete cascade,
  name text not null,
  storage_path text not null,
  size_bytes bigint,
  uploaded_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);

alter table public.bill_lines add column if not exists project_id uuid references public.projects(id) on delete set null;
alter table public.crm_activities add column if not exists project_id uuid references public.projects(id) on delete cascade;

-- Copy a template (or any project) into a new project, shifting dates to the new start.
create or replace function public.create_project_from_template(p_template uuid, p_name text, p_customer uuid, p_start date,
  p_sales_order uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare t projects; v_id uuid; v_shift int; r record; m jsonb := '{}'::jsonb; v_new uuid;
begin
  select * into t from projects where id = p_template;
  if not found then raise exception 'Template not found'; end if;
  perform require_member(t.company_id, array['owner','admin','accountant','hr','project_manager','sales']);
  v_shift := coalesce(p_start - t.start_date, 0);
  insert into projects (company_id, name, customer_id, start_date, end_date, budget, hourly_rate, status, description, currency,
                        location, country, billing_type, contract_value, manager_id, sales_order_id)
  values (t.company_id, p_name, p_customer, p_start, t.end_date + v_shift, t.budget, t.hourly_rate, 'planned', t.description, t.currency,
          t.location, t.country, t.billing_type, t.contract_value, auth.uid(), p_sales_order)
  returning id into v_id;
  for r in select * from tasks where project_id = p_template order by sort, created_at loop
    insert into tasks (company_id, project_id, title, status, due_date, start_date, estimated_hours, is_milestone, sort, description)
    values (t.company_id, v_id, r.title, 'todo', r.due_date + v_shift, r.start_date + v_shift, r.estimated_hours, r.is_milestone, r.sort, r.description)
    returning id into v_new;
    m := m || jsonb_build_object(r.id::text, v_new);
  end loop;
  update tasks n set predecessor_id = (m->>o.predecessor_id::text)::uuid
    from tasks o where o.project_id = p_template and o.predecessor_id is not null and n.id = (m->>o.id::text)::uuid;
  insert into project_budget_lines (company_id, project_id, category, description, cost_budget, revenue_budget, sort)
  select company_id, v_id, category, description, cost_budget, revenue_budget, sort from project_budget_lines where project_id = p_template;
  insert into project_milestones (company_id, project_id, name, due_date, amount, task_id, sort)
  select company_id, v_id, name, due_date + v_shift, amount, (m->>task_id::text)::uuid, sort from project_milestones where project_id = p_template;
  return v_id;
end $$;

-- Start a project from a sales order (with or without a template). Fixed price at the order value unless the template says otherwise.
create or replace function public.create_project_from_order(p_order uuid, p_template uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare o sales_quotes; v_id uuid; c customers;
begin
  select * into o from sales_quotes where id = p_order;
  if not found then raise exception 'Sales order not found'; end if;
  perform require_member(o.company_id, array['owner','admin','accountant','hr','project_manager','sales']);
  if exists (select 1 from projects where sales_order_id = p_order) then raise exception 'A project already exists for this order'; end if;
  select * into c from customers where id = o.customer_id;
  if p_template is not null then
    v_id := create_project_from_template(p_template, c.name || ' — ' || o.number, o.customer_id, current_date, p_order);
    update projects set currency = o.currency, contract_value = case when contract_value = 0 then o.subtotal else contract_value end where id = v_id;
  else
    insert into projects (company_id, name, customer_id, start_date, status, currency, billing_type, contract_value, description, sales_order_id)
    values (o.company_id, c.name || ' — ' || o.number, o.customer_id, current_date, 'planned', o.currency, 'fixed_price', o.subtotal, o.notes, p_order)
    returning id into v_id;
    insert into tasks (company_id, project_id, title, status, sort, description)
    select o.company_id, v_id, l.description, 'todo', l.sort, 'From ' || o.number || ': ' || l.qty || ' × ' || l.unit_price
      from sales_quote_lines l where l.quote_id = p_order;
    insert into project_milestones (company_id, project_id, name, amount, sort)
    values (o.company_id, v_id, 'Full contract value (' || o.number || ')', o.subtotal, 0);
  end if;
  return v_id;
end $$;

-- Draft invoice for one billing milestone, in the project's currency.
create or replace function public.invoice_milestone(p_milestone uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare ms project_milestones; pr projects; v_rate numeric; v_inv uuid;
begin
  select * into ms from project_milestones where id = p_milestone for update;
  if not found then raise exception 'Milestone not found'; end if;
  select * into pr from projects where id = ms.project_id;
  if not (can_manage_project(pr.id) or has_role(pr.company_id, array['sales'])) then raise exception 'Your role cannot invoice this project'; end if;
  if ms.status = 'invoiced' and ms.invoice_id is not null then raise exception 'This milestone is already invoiced'; end if;
  if pr.customer_id is null then raise exception 'Set a client on this project before invoicing'; end if;
  if ms.amount <= 0 then raise exception 'Give the milestone an amount first'; end if;
  v_rate := case when pr.currency = 'GHS' then 1 else (select rate from currencies where company_id = pr.company_id and code = pr.currency) end;
  if v_rate is null then raise exception 'Add % under Settings → Foreign currencies first', pr.currency; end if;
  insert into invoices (company_id, customer_id, project_id, invoice_date, currency, exchange_rate, notes)
  values (pr.company_id, pr.customer_id, pr.id, current_date, pr.currency, v_rate, 'Project ' || coalesce(pr.number, '') || ' ' || pr.name || ': milestone billing')
  returning id into v_inv;
  insert into invoice_lines (invoice_id, company_id, description, qty, unit_price, taxable, sort)
  values (v_inv, pr.company_id, 'Milestone: ' || ms.name, 1, ms.amount, true, 0);
  update project_milestones set status = 'invoiced', invoice_id = v_inv where id = p_milestone;
  return v_inv;
end $$;

-- A milestone becomes ready to bill when its linked task is done.
create or replace function public.task_milestone_ready() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'done' and old.status is distinct from 'done' then
    update project_milestones set status = 'ready' where task_id = new.id and status = 'planned';
    new.percent_complete := 100;
  end if;
  return new;
end $$;
create trigger tasks_milestone_ready before update on public.tasks for each row execute function public.task_milestone_ready();

-- Portfolio KPIs, all money in GHS.
create or replace function public.project_kpis(cid uuid)
returns table (project_id uuid, number text, name text, customer text, manager_id uuid, billing_type text, status text, health text,
  currency text, pct_complete int, est_hours numeric, actual_hours numeric, budget_cost numeric, actual_cost numeric,
  budget_revenue numeric, invoiced numeric, unbilled numeric, eac_cost numeric, forecast_margin numeric,
  overdue_tasks int, open_issues int, serious_issues int, last_update timestamptz, end_date date)
language sql stable security definer set search_path = public as $$
  with p as (
    select p.*, c.name as cust,
      case when p.currency = 'GHS' then 1 else coalesce((select rate from currencies x where x.company_id = p.company_id and x.code = p.currency), 1) end as fx
      from projects p left join customers c on c.id = p.customer_id
     where p.company_id = cid and not p.is_template and is_member(cid)
  ), t as (
    select project_id, sum(coalesce(estimated_hours,0)) est,
      sum(coalesce(estimated_hours,0) * coalesce(percent_complete, case status when 'done' then 100 when 'doing' then 50 else 0 end) / 100.0) est_done,
      count(*) n, count(*) filter (where status = 'done') n_done,
      count(*) filter (where status <> 'done' and due_date < current_date) overdue
    from tasks group by project_id
  ), ts as (
    select t.project_id, sum(t.hours) hrs, sum(t.hours * coalesce(e.cost_rate,0)) cost,
      sum(t.hours) filter (where coalesce(e.cost_rate,0) > 0) costed_hrs,
      sum(case when t.billable and t.invoice_id is null then t.hours * coalesce(t.bill_rate, 0) else 0 end) unbilled_ccy
    from timesheets t left join employees e on e.id = t.employee_id where t.status = 'approved' group by t.project_id
  ), ex as (
    select project_id, sum(amount_home) cost, sum(case when billable and invoice_id is null then amount_home else 0 end) unbilled
      from expense_claims where status in ('approved','reimbursed') and project_id is not null group by project_id
  ), bl as (
    select l.project_id, sum(l.qty * l.unit_cost * b.exchange_rate) cost
      from bill_lines l join bills b on b.id = l.bill_id where b.status <> 'draft' and l.project_id is not null group by l.project_id
  ), bud as (
    select project_id, sum(cost_budget) cost, sum(revenue_budget) rev from project_budget_lines group by project_id
  ), inv as (
    select project_id, sum(subtotal * exchange_rate) amt from invoices where status <> 'draft' and project_id is not null group by project_id
  ), ms as (
    select project_id, sum(amount) filter (where status = 'ready') ready from project_milestones group by project_id
  ), iss as (
    select project_id, count(*) filter (where status in ('open','in_progress')) n,
      count(*) filter (where status in ('open','in_progress') and severity in ('high','critical')) serious
      from project_issues group by project_id
  ), up as (select project_id, max(created_at) last_at from project_updates group by project_id)
  select p.id, p.number, p.name, p.cust, p.manager_id, p.billing_type, p.status, p.health, p.currency,
    coalesce(p.percent_complete_override,
      case when coalesce(t.est,0) > 0 then round(t.est_done / t.est * 100)::int
           when coalesce(t.n,0) > 0 then round(t.n_done::numeric / t.n * 100)::int else 0 end) as pct,
    coalesce(t.est,0), coalesce(ts.hrs,0), coalesce(bud.cost,0),
    round(coalesce(ts.cost,0) + coalesce(ex.cost,0) + coalesce(bl.cost,0), 2),
    round(coalesce(nullif(bud.rev,0), p.contract_value * p.fx, 0), 2),
    round(coalesce(inv.amt,0), 2),
    round(case when p.billing_type = 'time_materials' then coalesce(ts.unbilled_ccy,0) * p.fx + coalesce(ex.unbilled,0)
               when p.billing_type = 'fixed_price' then coalesce(ms.ready,0) * p.fx + coalesce(ex.unbilled,0) else 0 end, 2),
    -- Estimate at completion: actual cost plus remaining estimated hours at the average cost rate so far.
    round(coalesce(ts.cost,0) + coalesce(ex.cost,0) + coalesce(bl.cost,0)
      + greatest(coalesce(t.est,0) - coalesce(t.est_done,0), 0) * coalesce(ts.cost / nullif(ts.costed_hrs,0), 0), 2),
    round(coalesce(nullif(bud.rev,0), p.contract_value * p.fx, 0)
      - (coalesce(ts.cost,0) + coalesce(ex.cost,0) + coalesce(bl.cost,0)
         + greatest(coalesce(t.est,0) - coalesce(t.est_done,0), 0) * coalesce(ts.cost / nullif(ts.costed_hrs,0), 0)), 2),
    coalesce(t.overdue,0)::int, coalesce(iss.n,0)::int, coalesce(iss.serious,0)::int, up.last_at, p.end_date
  from p left join t on t.project_id = p.id left join ts on ts.project_id = p.id left join ex on ex.project_id = p.id
    left join bl on bl.project_id = p.id left join bud on bud.project_id = p.id left join inv on inv.project_id = p.id
    left join ms on ms.project_id = p.id left join iss on iss.project_id = p.id left join up on up.project_id = p.id
  order by p.status = 'done', p.name;
$$;

-- Actual cost by budget category for one project (GHS).
create or replace function public.project_actuals_by_category(p_project uuid)
returns table (category text, actual numeric)
language sql stable security definer set search_path = public as $$
  select 'labour', coalesce(sum(t.hours * coalesce(e.cost_rate,0)),0) from timesheets t left join employees e on e.id = t.employee_id
   where t.project_id = p_project and t.status = 'approved' and exists (select 1 from projects p where p.id = p_project and is_member(p.company_id))
  union all
  select 'expenses', coalesce(sum(amount_home),0) from expense_claims where project_id = p_project and status in ('approved','reimbursed')
     and exists (select 1 from projects p where p.id = p_project and is_member(p.company_id))
  union all
  select case when coalesce(a.type,'') = 'asset' or l.product_id is not null then 'materials' else 'subcontract' end, sum(l.qty * l.unit_cost * b.exchange_rate)
    from bill_lines l join bills b on b.id = l.bill_id left join accounts a on a.id = l.account_id
   where l.project_id = p_project and b.status <> 'draft' and exists (select 1 from projects p where p.id = p_project and is_member(p.company_id))
   group by 1;
$$;

-- =====================================================================
-- 5. CRM: campaigns, lead scoring, partners, commissions
-- =====================================================================
create table public.campaigns (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  name text not null,
  channel text not null default 'whatsapp' check (channel in ('whatsapp','sms','email','radio','tv','event','social','print','referral','other')),
  status text not null default 'planned' check (status in ('planned','active','completed')),
  start_date date, end_date date,
  budget numeric(14,2) not null default 0,
  actual_cost numeric(14,2) not null default 0,
  audience text,
  description text,
  created_at timestamptz not null default now()
);

create table public.partners (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  name text not null,
  kind text not null default 'reseller' check (kind in ('reseller','agent','referrer','distributor')),
  contact_name text, phone text, email text, city text,
  commission_rate numeric(6,4) not null default 0 check (commission_rate >= 0 and commission_rate <= 1),
  active boolean not null default true,
  notes text,
  created_at timestamptz not null default now()
);

alter table public.companies add column if not exists lead_ready_score int not null default 50;
alter table public.leads add column if not exists campaign_id uuid references public.campaigns(id) on delete set null;
alter table public.leads add column if not exists partner_id uuid references public.partners(id) on delete set null;
alter table public.leads add column if not exists score int not null default 0;
alter table public.leads add column if not exists sales_ready boolean not null default false;
alter table public.opportunities add column if not exists campaign_id uuid references public.campaigns(id) on delete set null;
alter table public.opportunities add column if not exists partner_id uuid references public.partners(id) on delete set null;
alter table public.customers add column if not exists partner_id uuid references public.partners(id) on delete set null;
alter table public.invoices add column if not exists partner_id uuid references public.partners(id) on delete set null;

-- Lead score out of 100: contact details, organisation, deal size, source, engagement.
create or replace function public.score_lead() returns trigger
language plpgsql security definer set search_path = public as $$
declare v int := 0; n int;
begin
  if coalesce(new.phone,'') <> '' then v := v + 10; end if;
  if coalesce(new.email,'') <> '' then v := v + 10; end if;
  if coalesce(new.organisation,'') <> '' then v := v + 10; end if;
  v := v + case when coalesce(new.estimated_value,0) >= 100000 then 30 when coalesce(new.estimated_value,0) >= 20000 then 20
                when coalesce(new.estimated_value,0) >= 5000 then 10 else 0 end;
  v := v + case new.source when 'referral' then 15 when 'event' then 10 when 'walk-in' then 10 when 'website' then 5 else 0 end;
  if new.partner_id is not null then v := v + 10; end if;
  if new.status = 'contacted' then v := v + 5; end if;
  if new.status = 'qualified' then v := v + 20; end if;
  if tg_op = 'UPDATE' then
    select count(*) into n from crm_activities where lead_id = new.id and done;
    v := v + least(n * 5, 20);
  end if;
  new.score := least(v, 100);
  new.sales_ready := new.status not in ('unqualified','converted')
    and new.score >= coalesce((select lead_ready_score from companies where id = new.company_id), 50);
  return new;
end $$;
create trigger leads_score before insert or update on public.leads for each row execute function public.score_lead();

create or replace function public.rescore_lead_from_activity() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.lead_id is not null then update leads set score = score where id = new.lead_id; end if;
  return new;
end $$;
create trigger activities_rescore after insert or update on public.crm_activities for each row execute function public.rescore_lead_from_activity();
update public.leads set score = score;   -- score existing leads

-- Changing the sales-ready threshold re-scores open leads.
create or replace function public.rescore_company_leads() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update leads set score = score where company_id = new.id and status <> 'converted';
  return new;
end $$;
create trigger companies_rescore_leads after update of lead_ready_score on public.companies
  for each row when (old.lead_ready_score is distinct from new.lead_ready_score) execute function public.rescore_company_leads();

create or replace function public.convert_lead(p_lead uuid, p_create_opportunity boolean default true)
returns uuid language plpgsql security definer set search_path = public as $$
declare l leads; v_cust uuid;
begin
  select * into l from leads where id = p_lead for update;
  if not found then raise exception 'Lead not found'; end if;
  perform require_member(l.company_id);
  if l.status = 'converted' then raise exception 'This lead is already a customer'; end if;
  insert into customers (company_id, name, phone, email, city, owner_id, territory_id, partner_id)
  values (l.company_id, coalesce(nullif(l.organisation,''), l.name), l.phone, l.email, l.city, l.owner_id, l.territory_id, l.partner_id)
  returning id into v_cust;
  if nullif(l.organisation,'') is not null then
    insert into customer_contacts (company_id, customer_id, name, phone, email) values (l.company_id, v_cust, l.name, l.phone, l.email);
  end if;
  if p_create_opportunity then
    insert into opportunities (company_id, title, customer_id, lead_id, stage, amount, probability, owner_id, campaign_id, partner_id)
    values (l.company_id, coalesce(nullif(l.organisation,''), l.name) || ' — first order', v_cust, l.id, 'qualification',
            coalesce(l.estimated_value,0), 25, l.owner_id, l.campaign_id, l.partner_id);
  end if;
  update leads set status = 'converted', customer_id = v_cust where id = p_lead;
  update crm_activities set customer_id = v_cust where lead_id = p_lead;
  return v_cust;
end $$;

-- Invoices inherit the customer's partner for partner commission.
create or replace function public.invoice_partner() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.partner_id is null then new.partner_id := (select partner_id from customers where id = new.customer_id); end if;
  return new;
end $$;
create trigger invoices_partner before insert on public.invoices for each row execute function public.invoice_partner();

create or replace function public.campaign_results(cid uuid)
returns table (campaign_id uuid, name text, channel text, status text, cost numeric, leads int, sales_ready int, converted int,
               opportunities int, won int, won_value numeric, cost_per_lead numeric, roi_pct numeric)
language sql stable security definer set search_path = public as $$
  select c.id, c.name, c.channel, c.status, c.actual_cost,
    (select count(*) from leads l where l.campaign_id = c.id)::int,
    (select count(*) from leads l where l.campaign_id = c.id and (l.sales_ready or l.status = 'converted'))::int,
    (select count(*) from leads l where l.campaign_id = c.id and l.status = 'converted')::int,
    (select count(*) from opportunities o where o.campaign_id = c.id)::int,
    (select count(*) from opportunities o where o.campaign_id = c.id and o.stage = 'won')::int,
    coalesce((select sum(o.amount * case when o.currency = 'GHS' then 1 else coalesce((select rate from currencies x where x.company_id = cid and x.code = o.currency),1) end)
                from opportunities o where o.campaign_id = c.id and o.stage = 'won'), 0),
    case when (select count(*) from leads l where l.campaign_id = c.id) > 0 then round(c.actual_cost / (select count(*) from leads l where l.campaign_id = c.id), 2) end,
    case when c.actual_cost > 0 then round((coalesce((select sum(o.amount * case when o.currency = 'GHS' then 1 else coalesce((select rate from currencies x where x.company_id = cid and x.code = o.currency),1) end)
                from opportunities o where o.campaign_id = c.id and o.stage = 'won'), 0) - c.actual_cost) / c.actual_cost * 100, 1) end
  from campaigns c where c.company_id = cid and is_member(cid) order by c.start_date desc nulls last, c.name;
$$;

create table public.sales_commission_rates (
  company_id uuid not null references public.companies(id) on delete cascade,
  user_id uuid not null,
  rate numeric(6,4) not null default 0 check (rate >= 0 and rate <= 1),
  primary key (company_id, user_id)
);

create table public.commission_runs (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  period_from date not null,
  period_to date not null,
  total numeric(14,2) not null,
  detail jsonb not null,
  journal_entry_id uuid references public.journal_entries(id),
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);

-- Commission on invoiced sales excluding tax, net of credit notes, in GHS.
create or replace function public.commission_report(cid uuid, p_from date, p_to date)
returns table (kind text, ref_id uuid, name text, base numeric, rate numeric, commission numeric)
language sql stable security definer set search_path = public as $$
  with s as (
    select i.sales_rep_id rep, i.partner_id partner, i.subtotal * i.exchange_rate amt from invoices i
     where i.company_id = cid and i.status <> 'draft' and i.invoice_date between p_from and p_to
    union all
    select i.sales_rep_id, i.partner_id, -cn.subtotal * cn.exchange_rate from credit_notes cn join invoices i on i.id = cn.invoice_id
     where cn.company_id = cid and cn.status = 'posted' and cn.credit_date between p_from and p_to
  )
  select 'rep', m.user_id, m.email, round(coalesce(sum(s.amt),0),2), coalesce(r.rate,0), round(coalesce(sum(s.amt),0) * coalesce(r.rate,0), 2)
    from memberships m left join s on s.rep = m.user_id left join sales_commission_rates r on r.company_id = cid and r.user_id = m.user_id
   where m.company_id = cid and has_role(cid, array['owner','admin','accountant','sales'])
   group by m.user_id, m.email, r.rate having coalesce(sum(s.amt),0) <> 0 or coalesce(r.rate,0) > 0
  union all
  select 'partner', pt.id, pt.name, round(coalesce(sum(s.amt),0),2), pt.commission_rate, round(coalesce(sum(s.amt),0) * pt.commission_rate, 2)
    from partners pt left join s on s.partner = pt.id
   where pt.company_id = cid and has_role(cid, array['owner','admin','accountant','sales'])
   group by pt.id, pt.name, pt.commission_rate having coalesce(sum(s.amt),0) <> 0
  order by 1 desc, 3;
$$;

create or replace function public.post_commissions(cid uuid, p_from date, p_to date, p_date date)
returns numeric language plpgsql security definer set search_path = public as $$
declare v numeric; v_detail jsonb; v_je uuid;
begin
  perform require_member(cid, array['owner','admin','accountant']);
  if exists (select 1 from commission_runs where company_id = cid and period_from <= p_to and period_to >= p_from) then
    raise exception 'Commission has already been posted for part of this period';
  end if;
  select coalesce(sum(commission),0), coalesce(jsonb_agg(to_jsonb(r)) filter (where commission <> 0), '[]') into v, v_detail
    from commission_report(cid, p_from, p_to) r;
  if v <= 0 then raise exception 'No commission is due for this period. Set rates for reps and partners first.'; end if;
  v_je := post_journal(cid, p_date, 'Commissions ' || to_char(p_from,'DD Mon') || ' – ' || to_char(p_to,'DD Mon YYYY'),
    jsonb_build_array(jl(acct(cid,'commissions'), v, 0), jl(acct(cid,'commission_pay'), 0, v)), 'commission', null);
  insert into commission_runs (company_id, period_from, period_to, total, detail, journal_entry_id) values (cid, p_from, p_to, v, v_detail, v_je);
  return v;
end $$;

-- Monthly forecast: quota, won, invoiced, and open pipeline by expected close month (GHS).
create or replace function public.sales_forecast(cid uuid, p_from date, p_months int default 6)
returns table (month date, quota numeric, won numeric, invoiced numeric, commit_value numeric, weighted numeric, best_case numeric)
language sql stable security definer set search_path = public as $$
  with m as (select (date_trunc('month', p_from) + (g || ' month')::interval)::date as mo from generate_series(0, greatest(p_months,1) - 1) g),
  fx as (select code, rate from currencies where company_id = cid)
  select m.mo,
    coalesce((select sum(amount) from sales_targets t where t.company_id = cid and make_date(t.year, t.month, 1) = m.mo), 0),
    coalesce((select sum(o.amount * coalesce((select rate from fx where code = o.currency), 1)) from opportunities o
               where o.company_id = cid and o.stage = 'won' and date_trunc('month', o.closed_at) = m.mo), 0),
    coalesce((select sum(i.subtotal * i.exchange_rate) from invoices i where i.company_id = cid and i.status <> 'draft' and date_trunc('month', i.invoice_date) = m.mo), 0),
    coalesce((select sum(o.amount * coalesce((select rate from fx where code = o.currency), 1)) from opportunities o
               where o.company_id = cid and o.stage = 'negotiation' and date_trunc('month', o.expected_close) = m.mo), 0),
    coalesce((select sum(o.amount * o.probability / 100.0 * coalesce((select rate from fx where code = o.currency), 1)) from opportunities o
               where o.company_id = cid and o.stage not in ('won','lost') and date_trunc('month', o.expected_close) = m.mo), 0),
    coalesce((select sum(o.amount * coalesce((select rate from fx where code = o.currency), 1)) from opportunities o
               where o.company_id = cid and o.stage not in ('won','lost') and date_trunc('month', o.expected_close) = m.mo), 0)
  from m where is_member(cid) order by m.mo;
$$;

-- =====================================================================
-- 6. Customer service: cases, knowledge base, public help centre
-- =====================================================================
alter table public.companies add column if not exists help_center_enabled boolean not null default false;

create table public.support_cases (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  number text,
  customer_id uuid references public.customers(id) on delete set null,
  contact_name text, email text, phone text,
  subject text not null,
  description text,
  channel text not null default 'phone' check (channel in ('phone','whatsapp','email','walk-in','web','social')),
  category text,
  priority text not null default 'medium' check (priority in ('low','medium','high','urgent')),
  status text not null default 'new' check (status in ('new','in_progress','waiting','resolved','closed')),
  assignee_id uuid,
  product_id uuid references public.products(id) on delete set null,
  opened_at timestamptz not null default now(),
  first_response_at timestamptz,
  resolved_at timestamptz,
  satisfaction int check (satisfaction between 1 and 5),
  access_token text not null default substr(replace(gen_random_uuid()::text, '-', ''), 1, 12),
  created_by uuid default auth.uid()
);

create table public.case_messages (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  case_id uuid not null references public.support_cases(id) on delete cascade,
  author_id uuid default auth.uid(),            -- null = the customer, via the help centre
  author_name text,
  body text not null,
  internal boolean not null default false,
  created_at timestamptz not null default now()
);

create table public.kb_articles (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  title text not null,
  body text not null,
  category text,
  published boolean not null default false,
  updated_at timestamptz not null default now()
);

create or replace function public.number_case() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.number is null then new.number := next_number(new.company_id, 'CASE', 'CASE-'); end if;
  if new.customer_id is null and (coalesce(new.email,'') <> '' or coalesce(new.phone,'') <> '') then
    new.customer_id := (select id from customers c where c.company_id = new.company_id
      and ((coalesce(new.email,'') <> '' and lower(c.email) = lower(new.email)) or (coalesce(new.phone,'') <> '' and replace(c.phone,' ','') = replace(new.phone,' ','')))
      limit 1);
  end if;
  return new;
end $$;
create trigger cases_number before insert on public.support_cases for each row execute function public.number_case();

create or replace function public.case_status_times() returns trigger
language plpgsql as $$
begin
  if new.status in ('resolved','closed') and old.status not in ('resolved','closed') then new.resolved_at := now(); end if;
  if new.status not in ('resolved','closed') and old.status in ('resolved','closed') then new.resolved_at := null; end if;
  return new;
end $$;
create trigger cases_times before update on public.support_cases for each row execute function public.case_status_times();

create or replace function public.case_message_effects() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.author_id is not null and not new.internal then
    update support_cases set first_response_at = coalesce(first_response_at, now()),
      status = case when status = 'new' then 'in_progress' else status end where id = new.case_id;
  elsif new.author_id is null then
    update support_cases set status = case when status in ('waiting','resolved') then 'in_progress' else status end where id = new.case_id;
  end if;
  return new;
end $$;
create trigger case_messages_effects after insert on public.case_messages for each row execute function public.case_message_effects();

create or replace function public.service_metrics(cid uuid, p_months int default 6)
returns table (month date, opened int, resolved int, avg_hours_to_resolve numeric, avg_hours_first_response numeric, csat numeric)
language sql stable security definer set search_path = public as $$
  select m.mo,
    (select count(*) from support_cases c where c.company_id = cid and date_trunc('month', c.opened_at) = m.mo)::int,
    (select count(*) from support_cases c where c.company_id = cid and date_trunc('month', c.resolved_at) = m.mo)::int,
    (select round(avg(extract(epoch from resolved_at - opened_at) / 3600)::numeric, 1) from support_cases c where c.company_id = cid and date_trunc('month', c.resolved_at) = m.mo),
    (select round(avg(extract(epoch from first_response_at - opened_at) / 3600)::numeric, 1) from support_cases c where c.company_id = cid and date_trunc('month', c.opened_at) = m.mo and first_response_at is not null),
    (select round(avg(satisfaction)::numeric, 2) from support_cases c where c.company_id = cid and date_trunc('month', c.resolved_at) = m.mo and satisfaction is not null)
  from (select (date_trunc('month', current_date) - (g || ' month')::interval)::date mo from generate_series(0, greatest(p_months,1) - 1) g) m
  where is_member(cid) order by m.mo;
$$;

-- Public help centre (no sign-in). Only works when the company has switched it on.
create or replace function public.public_help(p_company uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('name', c.name, 'phone', c.phone, 'email', c.email,
    'articles', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'title', a.title, 'body', a.body, 'category', a.category) order by a.category nulls last, a.title)
                           from kb_articles a where a.company_id = c.id and a.published), '[]'))
    from companies c where c.id = p_company and c.help_center_enabled;
$$;

create or replace function public.submit_case_public(p_company uuid, p_name text, p_email text, p_phone text, p_subject text, p_description text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v support_cases;
begin
  if not exists (select 1 from companies where id = p_company and help_center_enabled) then raise exception 'This help centre is not available'; end if;
  if coalesce(trim(p_subject),'') = '' or length(p_subject) > 200 then raise exception 'Give a short subject (up to 200 characters)'; end if;
  if length(coalesce(p_description,'')) > 5000 then raise exception 'Please keep the description under 5,000 characters'; end if;
  if coalesce(trim(p_email),'') = '' and coalesce(trim(p_phone),'') = '' then raise exception 'Give an email or phone number so we can reply'; end if;
  if (select count(*) from support_cases where company_id = p_company and opened_at > now() - interval '1 day'
        and ((coalesce(p_email,'') <> '' and lower(email) = lower(p_email)) or (coalesce(p_phone,'') <> '' and phone = p_phone))) >= 10 then
    raise exception 'Too many requests today. Please call us instead.';
  end if;
  insert into support_cases (company_id, contact_name, email, phone, subject, description, channel, created_by)
  values (p_company, left(p_name, 120), left(nullif(trim(p_email),''), 200), left(nullif(trim(p_phone),''), 40), trim(p_subject), p_description, 'web', null)
  returning * into v;
  return jsonb_build_object('number', v.number, 'token', v.access_token);
end $$;

create or replace function public.case_status_public(p_number text, p_token text)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('number', c.number, 'subject', c.subject, 'status', c.status, 'opened_at', c.opened_at,
    'resolved_at', c.resolved_at, 'satisfaction', c.satisfaction, 'company', co.name,
    'messages', coalesce((select jsonb_agg(jsonb_build_object('from', case when m.author_id is null then 'You' else coalesce(m.author_name, co.name) end,
                  'body', m.body, 'at', m.created_at) order by m.created_at) from case_messages m where m.case_id = c.id and not m.internal), '[]'))
    from support_cases c join companies co on co.id = c.company_id
   where upper(c.number) = upper(trim(p_number)) and c.access_token = trim(p_token) and co.help_center_enabled;
$$;

create or replace function public.reply_case_public(p_number text, p_token text, p_body text, p_rating int default null)
returns void language plpgsql security definer set search_path = public as $$
declare c support_cases;
begin
  select s.* into c from support_cases s join companies co on co.id = s.company_id
   where upper(s.number) = upper(trim(p_number)) and s.access_token = trim(p_token) and co.help_center_enabled;
  if not found then raise exception 'Case not found. Check the case number and access code.'; end if;
  if p_rating is not null then
    if p_rating not between 1 and 5 then raise exception 'Rate from 1 to 5'; end if;
    update support_cases set satisfaction = p_rating where id = c.id;
  end if;
  if coalesce(trim(p_body),'') <> '' then
    if length(p_body) > 5000 then raise exception 'Please keep the message under 5,000 characters'; end if;
    if (select count(*) from case_messages where case_id = c.id and author_id is null and created_at > now() - interval '1 hour') >= 20 then
      raise exception 'Too many messages. Please wait a while.';
    end if;
    insert into case_messages (company_id, case_id, author_id, author_name, body) values (c.company_id, c.id, null, coalesce(c.contact_name,'Customer'), p_body);
  end if;
end $$;

-- Staff reply: stores the author's email as the visible name.
create or replace function public.case_message_author() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.author_id is not null and new.author_name is null then
    new.author_name := split_part((select email from auth.users where id = new.author_id), '@', 1);
  end if;
  return new;
end $$;
create trigger case_messages_author before insert on public.case_messages for each row execute function public.case_message_author();

-- =====================================================================
-- 4. CRM: customer 360
-- =====================================================================
create or replace function public.customer_360(p_customer uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  with c as (select * from customers where id = p_customer and is_member(company_id)),
  i as (select i.* from invoices i join c on c.id = i.customer_id where i.status <> 'draft'),
  cogs as (select coalesce(sum(-m.qty * m.unit_cost),0) v from stock_moves m where m.ref_type in ('invoice','credit_note')
             and (m.ref_id in (select id from i) or m.ref_id in (select id from credit_notes where customer_id = p_customer)))
  select jsonb_build_object(
    'lifetime_sales', coalesce((select sum(subtotal * exchange_rate) from i), 0)
                      - coalesce((select sum(subtotal * exchange_rate) from credit_notes where customer_id = p_customer and status = 'posted'), 0),
    'outstanding', coalesce((select sum((total - amount_paid - amount_credited) * exchange_rate) from i), 0),
    'overdue', coalesce((select sum((total - amount_paid - amount_credited) * exchange_rate) from i where status = 'posted' and due_date < current_date), 0),
    'cost_of_sales', (select v from cogs),
    'gross_profit', coalesce((select sum(subtotal * exchange_rate) from i), 0)
                      - coalesce((select sum(subtotal * exchange_rate) from credit_notes where customer_id = p_customer and status = 'posted'), 0)
                      - (select v from cogs),
    'invoices', (select count(*) from i),
    'first_invoice', (select min(invoice_date) from i),
    'last_invoice', (select max(invoice_date) from i),
    'avg_days_to_pay', (select round(avg(p.payment_date - i.invoice_date)) from i join payments p on p.invoice_id = i.id where i.status = 'paid'),
    'open_pipeline', coalesce((select sum(o.amount * case when o.currency = 'GHS' then 1 else coalesce((select rate from currencies x where x.company_id = o.company_id and x.code = o.currency),1) end)
                        from opportunities o where o.customer_id = p_customer and o.stage not in ('won','lost')), 0),
    'open_cases', (select count(*) from support_cases where customer_id = p_customer and status not in ('resolved','closed')),
    'last_activity', (select max(coalesce(done_at, due_at, created_at)) from crm_activities where customer_id = p_customer),
    'top_products', coalesce((select jsonb_agg(x) from (
        select l.description as name, sum(l.qty) as qty, sum(l.qty * l.unit_price * i.exchange_rate) as revenue
          from invoice_lines l join i on i.id = l.invoice_id group by l.description order by 3 desc limit 5) x), '[]'))
  from c;
$$;

-- =====================================================================
-- 7. Re-issue project functions with the Project Manager role
-- =====================================================================
create or replace function public.assign_resource(p_project uuid, p_employee uuid, p_start date, p_end date,
  p_pct int, p_role text default null, p_bill_rate numeric default null, p_status text default 'confirmed')
returns uuid language plpgsql security definer set search_path = public as $$
declare pr projects; e employees; v uuid;
begin
  select * into pr from projects where id = p_project;
  if not found then raise exception 'Project not found'; end if;
  if not can_manage_project(p_project) then raise exception 'Only this project''s manager (or an admin) can assign people'; end if;
  select * into e from employees where id = p_employee;
  if not found or not same_group(pr.company_id, e.company_id) then raise exception 'That employee is not in your group of companies'; end if;
  insert into project_assignments (company_id, project_id, employee_id, employee_company_id, role, start_date, end_date, allocation_pct, bill_rate, status)
  values (pr.company_id, p_project, p_employee, e.company_id, p_role, p_start, p_end, p_pct, p_bill_rate, p_status)
  returning id into v;
  return v;
end $$;

create or replace function public.decide_time(p_ids uuid[], p_approve boolean)
returns int language plpgsql security definer set search_path = public as $$
declare v int := 0; t record;
begin
  for t in select * from timesheets where id = any(p_ids) and status = 'submitted' for update loop
    if not can_manage_project(t.project_id) then raise exception 'You can only approve time on projects you manage'; end if;
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
  if not (has_role(x.company_id, array['owner','admin','accountant']) or (x.project_id is not null and can_manage_project(x.project_id))) then
    raise exception 'You can only approve expenses on projects you manage';
  end if;
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

create or replace function public.search_resources(cid uuid, p_skills text[], p_location text, p_start date, p_end date)
returns table (employee_id uuid, company_id uuid, company_name text, full_name text, job_title text, department text,
               skills text[], location text, country text, matched int, peak_booked int, available int, leave_days int)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare v_end date := least(coalesce(p_end, p_start + 30), p_start + 366);
begin
  perform require_member(cid, array['owner','admin','accountant','hr','project_manager']);
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

create or replace function public.invoice_project(p_project uuid, p_to date default current_date)
returns uuid language plpgsql security definer set search_path = public as $$
declare pr projects; v_rate numeric; v_inv uuid; r record; i int := 0;
begin
  select * into pr from projects where id = p_project;
  if not found then raise exception 'Project not found'; end if;
  if not (can_manage_project(pr.id) or has_role(pr.company_id, array['sales'])) then raise exception 'Only this project''s manager, sales or accounts can bill it'; end if;
  if pr.customer_id is null then raise exception 'Set a client on this project before invoicing'; end if;
  v_rate := case when pr.currency = 'GHS' then 1 else (select rate from currencies where company_id = pr.company_id and code = pr.currency) end;
  if v_rate is null then raise exception 'Add % under Settings → Foreign currencies first', pr.currency; end if;
  if not exists (select 1 from timesheets where project_id = p_project and status = 'approved' and billable and invoice_id is null and work_date <= p_to)
     and not exists (select 1 from expense_claims where project_id = p_project and status in ('approved','reimbursed') and billable and invoice_id is null and expense_date <= p_to) then
    raise exception 'There is no approved, unbilled time or billable expense up to %', p_to;
  end if;

  insert into invoices (company_id, customer_id, project_id, invoice_date, currency, exchange_rate, notes)
  values (pr.company_id, pr.customer_id, p_project, current_date, pr.currency, v_rate, 'Project ' || coalesce(pr.number,'') || ': ' || pr.name || ', work to ' || to_char(p_to, 'DD Mon YYYY'))
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

-- =====================================================================
-- 8. Project documents storage (Supabase only)
-- =====================================================================
do $$ begin
  if exists (select 1 from information_schema.schemata where schema_name = 'storage') then
    execute $q$insert into storage.buckets (id, name, public) values ('project-docs', 'project-docs', false) on conflict (id) do nothing$q$;
    execute $q$create policy "project docs: members upload" on storage.objects for insert to authenticated
      with check (bucket_id = 'project-docs' and public.is_member(((storage.foldername(name))[1])::uuid))$q$;
    execute $q$create policy "project docs: members read" on storage.objects for select to authenticated
      using (bucket_id = 'project-docs' and public.is_member(((storage.foldername(name))[1])::uuid))$q$;
    execute $q$create policy "project docs: members delete" on storage.objects for delete to authenticated
      using (bucket_id = 'project-docs' and public.is_member(((storage.foldername(name))[1])::uuid))$q$;
  end if;
end $$;

-- =====================================================================
-- 9. New companies get the v1.3 accounts
-- =====================================================================
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
  perform seed_accounts_v13(v);
  perform seed_leave_types(v);
  perform seed_asset_categories(v);
  return v;
end $$;

-- =====================================================================
-- 10. Row-level security
-- =====================================================================
do $$ declare t text; begin
  foreach t in array array['project_issues','project_updates','project_documents','campaigns','partners','support_cases','case_messages','kb_articles'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy "members read" on public.%I for select using (is_member(company_id))', t);
    execute format('create policy "members insert" on public.%I for insert with check (is_member(company_id))', t);
    execute format('create policy "members update" on public.%I for update using (is_member(company_id))', t);
    execute format('create policy "members delete" on public.%I for delete using (is_member(company_id))', t);
  end loop;
  foreach t in array array['project_milestones','project_budget_lines'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy "members read" on public.%I for select using (is_member(company_id))', t);
    execute format('create policy "project managers write" on public.%I for all using (can_manage_project(project_id)) with check (can_manage_project(project_id))', t);
  end loop;
end $$;

alter table public.sales_commission_rates enable row level security;
create policy "members read rates" on public.sales_commission_rates for select using (is_member(company_id));
create policy "accountants set rates" on public.sales_commission_rates for all
  using (has_role(company_id, array['owner','admin','accountant'])) with check (has_role(company_id, array['owner','admin','accountant']));
alter table public.commission_runs enable row level security;
create policy "accountants read runs" on public.commission_runs for select using (has_role(company_id, array['owner','admin','accountant']));

-- Project assignments, time and expenses: the project manager now counts as a manager for their projects.
drop policy if exists "managers change" on public.project_assignments;
drop policy if exists "managers remove" on public.project_assignments;
create policy "managers change" on public.project_assignments for update using (can_manage_project(project_id));
create policy "managers remove" on public.project_assignments for delete using (can_manage_project(project_id));

drop policy if exists "managers log approved time" on public.timesheets;
drop policy if exists "managers edit time" on public.timesheets;
drop policy if exists "managers or owner delete unbilled time" on public.timesheets;
create policy "managers log approved time" on public.timesheets for insert
  with check (can_manage_project(project_id) or (is_member(company_id) and status = 'submitted'));
create policy "managers edit time" on public.timesheets for update using (can_manage_project(project_id));
create policy "managers or owner delete unbilled time" on public.timesheets for delete
  using (invoice_id is null and (can_manage_project(project_id) or (status = 'submitted' and employee_id in (select my_employee_ids()))));

drop policy if exists "approvers and claimant read" on public.expense_claims;
create policy "approvers and claimant read" on public.expense_claims for select
  using (has_role(company_id, array['owner','admin','accountant','hr']) or employee_id in (select my_employee_ids())
         or (project_id is not null and can_manage_project(project_id)));

-- Function permissions
revoke execute on all functions in schema public from public, anon;
grant execute on all functions in schema public to authenticated;
revoke execute on function public.post_journal(uuid,date,text,jsonb,text,uuid) from authenticated;
revoke execute on function public.seed_accounts(uuid) from authenticated;
revoke execute on function public.seed_accounts_v11(uuid) from authenticated;
revoke execute on function public.seed_accounts_v12(uuid) from authenticated;
revoke execute on function public.seed_accounts_v13(uuid) from authenticated;
revoke execute on function public.seed_leave_types(uuid) from authenticated;
revoke execute on function public.seed_asset_categories(uuid) from authenticated;
revoke execute on function public.next_number(uuid,text,text) from authenticated;
-- The help centre is the only thing open without signing in.
grant execute on function public.public_help(uuid) to anon;
grant execute on function public.submit_case_public(uuid,text,text,text,text,text) to anon;
grant execute on function public.case_status_public(text,text) to anon;
grant execute on function public.reply_case_public(text,text,text,int) to anon;


-- ======================================================================
-- 0005_asnys_v1_4.sql
-- ======================================================================
-- =====================================================================
-- Sika ERP v1.4
--   * Purchase requests on projects (materials, subcontractor services, equipment hire and any other expense)
--     with budget-checked approval, committed cost and conversion to a supplier bill
--   * Project tags on journal lines: supplier bills, expense claims and manual journals carry the project into the ledger
--   * Training in HR (separate from projects): training requests, approval, sessions, attendance,
--     certificates with expiry, and each employee's training history
--   * Project cost report (every cost line with its source document) and budget alerts
-- Run after 0004.
-- =====================================================================

-- ---------------------------------------------------------------- 1. Accounts for project costs and training
create or replace function public.seed_accounts_v14(cid uuid)
returns void language sql security definer set search_path = public as $$
  insert into accounts (company_id, code, name, type, system_key) values
  (cid,'5200','Project materials (direct)','expense','project_materials'),
  (cid,'5300','Subcontractor services','expense','subcontract'),
  (cid,'6250','Equipment and plant hire','expense','equipment_hire'),
  (cid,'6450','Staff training','expense','training')
  on conflict do nothing;
$$;
select public.seed_accounts_v14(id) from public.companies;

-- ---------------------------------------------------------------- 2. Cost categories
alter table public.project_budget_lines drop constraint if exists project_budget_lines_category_check;
alter table public.project_budget_lines add constraint project_budget_lines_category_check
  check (category in ('labour','expenses','materials','subcontract','equipment','other'));

create or replace function public.cost_category_for_account(a uuid) returns text
language sql stable security definer set search_path = public as $$
  select case x.system_key when 'project_materials' then 'materials' when 'inventory' then 'materials' when 'subcontract' then 'subcontract'
           when 'equipment_hire' then 'equipment' when 'reimburse' then 'expenses'
           else case when x.type = 'asset' then 'materials' else 'other' end end
    from accounts x where x.id = a;
$$;

-- ---------------------------------------------------------------- 3. Project tags in the ledger
alter table public.journal_lines add column if not exists project_id uuid references public.projects(id) on delete set null;
create index if not exists journal_lines_project on public.journal_lines (project_id) where project_id is not null;
alter table public.bill_lines add column if not exists project_category text
  check (project_category in ('materials','subcontract','equipment','other'));

create or replace function public.post_journal(cid uuid, p_date date, p_memo text, p_lines jsonb,
  p_source_type text default null, p_source_id uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_id uuid; v_dr numeric; v_cr numeric; v_lock date;
begin
  select locked_until into v_lock from companies where id = cid;
  if v_lock is not null and p_date <= v_lock then
    raise exception 'The books are locked up to %. Date this on or after %, or ask an accountant to change the lock date.', v_lock, v_lock + 1;
  end if;
  select coalesce(sum(round((l->>'debit')::numeric,2)),0), coalesce(sum(round((l->>'credit')::numeric,2)),0)
    into v_dr, v_cr from jsonb_array_elements(p_lines) l;
  if v_dr <> v_cr then raise exception 'Journal does not balance: debits % vs credits %', v_dr, v_cr; end if;
  if v_dr = 0 then raise exception 'Journal has no amounts'; end if;
  insert into journal_entries (company_id, entry_no, entry_date, memo, source_type, source_id)
  values (cid, next_number(cid, 'JE', 'JE-'), p_date, p_memo, p_source_type, p_source_id)
  returning id into v_id;
  insert into journal_lines (entry_id, company_id, account_id, debit, credit, project_id)
  select v_id, cid, (l->>'account_id')::uuid, round(coalesce((l->>'debit')::numeric,0),2), round(coalesce((l->>'credit')::numeric,0),2),
         nullif(l->>'project_id','')::uuid
    from jsonb_array_elements(p_lines) l
   where round(coalesce((l->>'debit')::numeric,0),2) <> 0 or round(coalesce((l->>'credit')::numeric,0),2) <> 0;
  insert into audit_log (company_id, action, detail) values (cid, 'journal.posted', jsonb_build_object('entry_id', v_id, 'memo', p_memo));
  return v_id;
end $$;

create or replace function public.post_manual_journal(cid uuid, p_date date, p_memo text, p_lines jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
begin
  perform require_member(cid, array['owner','admin','accountant']);
  if exists (select 1 from jsonb_array_elements(p_lines) l
             where not exists (select 1 from accounts a where a.id = (l->>'account_id')::uuid and a.company_id = cid)) then
    raise exception 'An account does not belong to this company';
  end if;
  if exists (select 1 from jsonb_array_elements(p_lines) l where nullif(l->>'project_id','') is not null
             and not exists (select 1 from projects p where p.id = (l->>'project_id')::uuid and p.company_id = cid and not p.is_template)) then
    raise exception 'A project does not belong to this company';
  end if;
  return post_journal(cid, p_date, p_memo, p_lines, 'manual', null);
end $$;

-- Supplier bills: each cost line carries its project into the ledger.
create or replace function public.post_bill(p_bill uuid)
returns text language plpgsql security definer set search_path = public as $$
declare
  b bills; l record; v_lines jsonb := '[]'::jsonb; x numeric;
  v_taxable numeric := 0; v_sub numeric := 0; v_amt numeric; g_amt numeric; g_sum numeric := 0;
  v_vat numeric; v_nhil numeric; v_getf numeric; v_total numeric; v_je uuid; v_no text;
  g_vat numeric; g_nhil numeric; g_getf numeric;
begin
  select * into b from bills where id = p_bill for update;
  if not found then raise exception 'Bill not found'; end if;
  perform require_member(b.company_id, array['owner','admin','accountant']);
  if b.status <> 'draft' then raise exception 'This bill is already posted'; end if;
  if not exists (select 1 from bill_lines where bill_id = p_bill) then raise exception 'Add at least one line'; end if;
  if tax_rate('VAT', b.bill_date) is null then raise exception 'No VAT rate is set for %', b.bill_date; end if;
  if exists (select 1 from bill_lines bl join projects pj on pj.id = bl.project_id where bl.bill_id = p_bill and pj.company_id <> b.company_id) then
    raise exception 'A bill line is tagged to another company''s project';
  end if;
  x := b.exchange_rate;

  perform set_config('sika.posting','on', true);
  for l in select * from bill_lines where bill_id = p_bill order by sort loop
    v_amt := round(l.qty * l.unit_cost, 2);
    g_amt := round(v_amt * x, 2);
    v_sub := v_sub + v_amt; g_sum := g_sum + g_amt;
    if l.taxable then v_taxable := v_taxable + v_amt; end if;
    if l.product_id is not null then
      update products set
        cost = round((greatest(stock_qty,0) * cost + l.qty * l.unit_cost * x) / (greatest(stock_qty,0) + l.qty), 4),
        stock_qty = stock_qty + l.qty
       where id = l.product_id;
      insert into stock_moves (company_id, product_id, move_date, qty, unit_cost, reason, ref_type, ref_id)
      values (b.company_id, l.product_id, b.bill_date, l.qty, l.unit_cost * x, 'Goods received', 'bill', b.id);
      v_lines := v_lines || (jl(acct(b.company_id,'inventory'), g_amt, 0) || jsonb_build_object('project_id', l.project_id));
    else
      v_lines := v_lines || (jl(l.account_id, g_amt, 0) || jsonb_build_object('project_id', l.project_id));
    end if;
  end loop;
  perform set_config('sika.posting','off', true);

  v_vat := round(v_taxable * tax_rate('VAT', b.bill_date), 2);
  v_nhil := round(v_taxable * tax_rate('NHIL', b.bill_date), 2);
  v_getf := round(v_taxable * tax_rate('GETFUND', b.bill_date), 2);
  v_total := v_sub + v_vat + v_nhil + v_getf;
  g_vat := round(v_vat * x, 2); g_nhil := round(v_nhil * x, 2); g_getf := round(v_getf * x, 2);
  v_no := next_number(b.company_id, 'BILL', 'BILL-');
  v_lines := v_lines
    || jl(acct(b.company_id,'vat_in'), g_vat, 0)
    || jl(acct(b.company_id,'nhil_in'), g_nhil, 0)
    || jl(acct(b.company_id,'getf_in'), g_getf, 0)
    || jl(acct(b.company_id,'ap'), 0, g_sum + g_vat + g_nhil + g_getf);
  v_je := post_journal(b.company_id, b.bill_date, 'Supplier bill ' || v_no || coalesce(' (' || b.supplier_ref || ')',''), v_lines, 'bill', b.id);
  update bills set status = 'posted', number = v_no, subtotal = v_sub, vat = v_vat, nhil = v_nhil,
         getfund = v_getf, total = v_total, journal_entry_id = v_je, due_date = coalesce(due_date, bill_date + 30)
   where id = p_bill;
  update project_requests set status = 'billed' where bill_id = p_bill and status = 'approved';
  return v_no;
end $$;

-- Expense claims: the expense line carries the project.
create or replace function public.decide_expense(p_id uuid, p_approve boolean, p_reason text default null)
returns void language plpgsql security definer set search_path = public as $$
declare x expense_claims; v_je uuid; e employees;
begin
  select * into x from expense_claims where id = p_id for update;
  if not found then raise exception 'Expense not found'; end if;
  if not (has_role(x.company_id, array['owner','admin','accountant']) or (x.project_id is not null and can_manage_project(x.project_id))) then
    raise exception 'You can only approve expenses on projects you manage';
  end if;
  if x.status <> 'submitted' then raise exception 'This expense has already been decided'; end if;
  if not p_approve then
    update expense_claims set status = 'rejected', reject_reason = p_reason, approved_by = auth.uid() where id = p_id;
    return;
  end if;
  select * into e from employees where id = x.employee_id;
  v_je := post_journal(x.company_id, x.expense_date, 'Expense claim: ' || e.full_name || ' — ' || x.description ||
            case when x.currency <> 'GHS' then ' (' || x.currency || ' ' || x.amount || ' at ' || x.exchange_rate || ')' else '' end,
    jsonb_build_array(jl(x.account_id, x.amount_home, 0) || jsonb_build_object('project_id', x.project_id),
                      jl(acct(x.company_id,'reimburse'), 0, x.amount_home)), 'expense', x.id);
  update expense_claims set status = 'approved', approved_by = auth.uid(), journal_entry_id = v_je where id = p_id;
end $$;

-- Tag the ledger lines of bills and expense claims posted before v1.4 (one project per account per document).
with lines as (
  select b.journal_entry_id entry_id, coalesce(l.account_id, inv.id) account_id, l.project_id
    from bill_lines l join bills b on b.id = l.bill_id
    left join accounts inv on inv.company_id = b.company_id and inv.system_key = 'inventory'
   where b.journal_entry_id is not null
), g as (
  select entry_id, account_id, min(project_id::text)::uuid project_id from lines group by 1, 2
  having count(*) = count(project_id) and count(distinct project_id) = 1
)
update public.journal_lines jl set project_id = g.project_id
  from g where jl.entry_id = g.entry_id and jl.account_id = g.account_id and jl.debit > 0 and jl.project_id is null;
update public.journal_lines jl set project_id = x.project_id
  from expense_claims x where x.journal_entry_id = jl.entry_id and jl.account_id = x.account_id and x.project_id is not null and jl.project_id is null;

-- ---------------------------------------------------------------- 4. Purchase requests on projects
create table public.project_requests (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  number text,
  project_id uuid not null references public.projects(id) on delete cascade,
  task_id uuid references public.tasks(id) on delete set null,
  kind text not null default 'material' check (kind in ('material','subcontract','equipment','other')),
  description text not null,
  product_id uuid references public.products(id) on delete set null,
  account_id uuid references public.accounts(id) on delete set null,   -- for "other": which expense account
  qty numeric(14,3) not null default 1 check (qty > 0),
  unit text,
  est_unit_cost numeric(14,2) not null default 0 check (est_unit_cost >= 0),   -- GHS, excluding VAT
  supplier_id uuid references public.suppliers(id) on delete set null,
  needed_by date,
  status text not null default 'submitted' check (status in ('draft','submitted','approved','rejected','billed','cancelled')),
  requested_by uuid default auth.uid(),
  requested_email text,
  decided_by uuid,
  decided_at timestamptz,
  reject_reason text,
  bill_id uuid references public.bills(id) on delete set null,
  notes text,
  created_at timestamptz not null default now()
);
create index on public.project_requests (project_id, status);
alter table public.bill_lines add column if not exists request_id uuid references public.project_requests(id) on delete set null;

create or replace function public.project_request_defaults() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    new.company_id := (select company_id from projects where id = new.project_id);
    if new.number is null then new.number := next_number(new.company_id, 'PR', 'PR-'); end if;
    new.requested_by := coalesce(auth.uid(), new.requested_by);
    new.requested_email := (select email from auth.users where id = new.requested_by);
    if new.status not in ('draft','submitted') then raise exception 'New requests start as draft or submitted'; end if;
  elsif new.status is distinct from old.status and new.status in ('approved','rejected','billed')
        and coalesce(current_setting('sika.requests', true), '') <> 'on' then
    raise exception 'Use Approve or Reject to decide a request';
  end if;
  if tg_op = 'UPDATE' and old.status in ('approved','billed') and coalesce(current_setting('sika.requests', true), '') <> 'on'
     and (new.qty, new.est_unit_cost, new.project_id) is distinct from (old.qty, old.est_unit_cost, old.project_id) then
    raise exception 'An approved request cannot be changed. Cancel it and raise a new one.';
  end if;
  return new;
end $$;
create trigger project_requests_defaults before insert or update on public.project_requests
  for each row execute function public.project_request_defaults();

-- ---------------------------------------------------------------- 5. Training records
create table public.trainings (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  title text not null,
  kind text not null default 'course' check (kind in ('course','certification','safety_induction','workshop','on_the_job')),
  provider text,
  supplier_id uuid references public.suppliers(id) on delete set null,
  start_date date, end_date date,
  location text,
  hours numeric(8,2),
  cost numeric(14,2) not null default 0 check (cost >= 0),     -- GHS total, excluding VAT
  status text not null default 'planned' check (status in ('planned','in_progress','completed','cancelled')),
  valid_months int check (valid_months > 0),                    -- certificates expire this many months after completion
  bill_id uuid references public.bills(id) on delete set null,
  notes text,
  created_at timestamptz not null default now()
);
create table public.training_attendees (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  training_id uuid not null references public.trainings(id) on delete cascade,
  employee_id uuid not null references public.employees(id) on delete cascade,
  status text not null default 'enrolled' check (status in ('enrolled','attended','passed','failed','absent')),
  score numeric(6,2),
  certificate_no text,
  certified_on date,
  expires_on date,
  unique (training_id, employee_id)
);

-- Training requests: staff ask for themselves, managers ask for their people; HR approves and schedules.
create table public.training_requests (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  number text,
  employee_id uuid not null references public.employees(id) on delete cascade,
  title text not null,
  reason text,
  provider text,
  est_cost numeric(14,2) not null default 0 check (est_cost >= 0),
  preferred_date date,
  priority text not null default 'normal' check (priority in ('low','normal','high','mandatory')),
  status text not null default 'submitted' check (status in ('submitted','approved','rejected','scheduled','completed','cancelled')),
  requested_by uuid default auth.uid(),
  requested_email text,
  decided_by uuid, decided_at timestamptz, decision_note text,
  training_id uuid references public.trainings(id) on delete set null,
  created_at timestamptz not null default now()
);

create or replace function public.training_request_defaults() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    new.company_id := (select company_id from employees where id = new.employee_id);
    new.number := next_number(new.company_id, 'TR', 'TR-');
    new.requested_by := coalesce(auth.uid(), new.requested_by);
    new.requested_email := (select email from auth.users where id = new.requested_by);
    if new.status <> 'submitted' then raise exception 'New training requests start as submitted'; end if;
  elsif new.status is distinct from old.status and new.status not in ('cancelled')
        and coalesce(current_setting('sika.training', true), '') <> 'on' then
    raise exception 'Use Approve, Reject or Schedule to change a training request';
  end if;
  return new;
end $$;
create trigger training_requests_defaults before insert or update on public.training_requests
  for each row execute function public.training_request_defaults();

create or replace function public.decide_training_request(p_id uuid, p_approve boolean, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare r training_requests;
begin
  select * into r from training_requests where id = p_id for update;
  if not found then raise exception 'Request not found'; end if;
  perform require_member(r.company_id, array['owner','admin','hr']);
  if r.status <> 'submitted' then raise exception '% has already been decided', r.number; end if;
  perform set_config('sika.training','on', true);
  update training_requests set status = case when p_approve then 'approved' else 'rejected' end,
    decided_by = auth.uid(), decided_at = now(), decision_note = p_note where id = p_id;
  perform set_config('sika.training','off', true);
end $$;

-- Put approved requests on a training session (new or existing) and enrol the employees.
create or replace function public.schedule_training_requests(p_ids uuid[], p_training uuid)
returns int language plpgsql security definer set search_path = public as $$
declare t trainings; n int;
begin
  select * into t from trainings where id = p_training;
  if not found then raise exception 'Training not found'; end if;
  perform require_member(t.company_id, array['owner','admin','hr']);
  if exists (select 1 from training_requests where id = any(p_ids) and (company_id <> t.company_id or status <> 'approved')) then
    raise exception 'Only approved requests can be scheduled';
  end if;
  insert into training_attendees (company_id, training_id, employee_id)
  select t.company_id, t.id, employee_id from training_requests where id = any(p_ids) on conflict (training_id, employee_id) do nothing;
  perform set_config('sika.training','on', true);
  update training_requests set status = 'scheduled', training_id = t.id where id = any(p_ids);
  perform set_config('sika.training','off', true);
  get diagnostics n = row_count;
  return n;
end $$;

-- When a session is completed, the requests on it are completed too.
create or replace function public.training_completed() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'completed' and old.status <> 'completed' then
    perform set_config('sika.training','on', true);
    update training_requests set status = 'completed' where training_id = new.id and status = 'scheduled';
    perform set_config('sika.training','off', true);
    update training_attendees set status = 'attended' where training_id = new.id and status = 'enrolled';
  end if;
  return new;
end $$;
create trigger trainings_completed after update on public.trainings for each row execute function public.training_completed();

-- Each employee's training record: every session they were on, with result and certificate.
create or replace function public.employee_training_history(cid uuid, p_employee uuid default null)
returns table (employee_id uuid, full_name text, department text, training_id uuid, title text, kind text, provider text,
               start_date date, end_date date, hours numeric, status text, score numeric, certificate_no text,
               certified_on date, expires_on date, cert_state text)
language sql stable security definer set search_path = public as $$
  select e.id, e.full_name, e.department, t.id, t.title, t.kind, t.provider, t.start_date, t.end_date, t.hours,
         a.status, a.score, a.certificate_no, a.certified_on, a.expires_on,
         case when a.expires_on is null then null when a.expires_on < current_date then 'expired'
              when a.expires_on < current_date + 60 then 'expiring' else 'valid' end
    from training_attendees a join trainings t on t.id = a.training_id join employees e on e.id = a.employee_id
   where t.company_id = cid and (p_employee is null or e.id = p_employee)
     and (has_role(cid, array['owner','admin','hr','accountant']) or e.id in (select my_employee_ids()))
   order by e.full_name, coalesce(t.start_date, t.end_date) desc nulls last;
$$;

create or replace function public.training_attendee_defaults() returns trigger
language plpgsql security definer set search_path = public as $$
declare t trainings;
begin
  select * into t from trainings where id = new.training_id;
  new.company_id := t.company_id;
  if new.status = 'passed' and new.certified_on is null then new.certified_on := coalesce(t.end_date, t.start_date, current_date); end if;
  if new.status = 'passed' and new.expires_on is null and t.valid_months is not null then
    new.expires_on := (new.certified_on + make_interval(months => t.valid_months))::date;
  end if;
  return new;
end $$;
create trigger training_attendees_defaults before insert or update on public.training_attendees
  for each row execute function public.training_attendee_defaults();

-- ---------------------------------------------------------------- 6. Approvals and billing of requests
create or replace function public.project_cost_items(cid uuid)
returns table (item_date date, project_id uuid, category text, source text, reference text, description text,
               account_code text, account_name text, amount numeric, in_ledger boolean, committed boolean, doc_id uuid)
language sql stable security definer set search_path = public as $$
  -- Labour: approved hours at each person's internal cost rate (a management cost; payroll posts salaries in total).
  select t.work_date, t.project_id, 'labour', 'Timesheet', e.full_name, coalesce(t.note, tk.title, ''),
         null::text, null::text, round(t.hours * coalesce(e.cost_rate,0), 2), false, false, t.id
    from timesheets t join projects p on p.id = t.project_id left join employees e on e.id = t.employee_id left join tasks tk on tk.id = t.task_id
   where p.company_id = cid and t.status = 'approved'
  union all
  -- Staff expense claims
  select x.expense_date, x.project_id, 'expenses', 'Expense claim', e.full_name, x.description, a.code, a.name, x.amount_home, true, false, x.id
    from expense_claims x join projects p on p.id = x.project_id left join employees e on e.id = x.employee_id left join accounts a on a.id = x.account_id
   where p.company_id = cid and x.status in ('approved','reimbursed')
  union all
  -- Supplier bills
  select b.bill_date, l.project_id,
         coalesce(l.project_category, case when l.product_id is not null then 'materials' else cost_category_for_account(l.account_id) end),
         'Supplier bill', b.number || coalesce(' · ' || s.name, ''), l.description,
         a.code, a.name, round(l.qty * l.unit_cost * b.exchange_rate, 2), true, false, b.id
    from bill_lines l join bills b on b.id = l.bill_id join projects p on p.id = l.project_id
    left join suppliers s on s.id = b.supplier_id
    left join accounts a on a.id = coalesce(l.account_id, (select id from accounts i where i.company_id = cid and i.system_key = 'inventory'))
   where p.company_id = cid and b.status <> 'draft'
  union all
  -- Manual journals tagged to a project (other costs, reallocations, accruals)
  select je.entry_date, jl.project_id, cost_category_for_account(jl.account_id), 'Journal', je.entry_no, coalesce(je.memo, ''),
         a.code, a.name, jl.debit - jl.credit, true, false, je.id
    from journal_lines jl join journal_entries je on je.id = jl.entry_id join accounts a on a.id = jl.account_id
   where jl.company_id = cid and jl.project_id is not null and je.source_type = 'manual' and a.type in ('expense','asset')
  union all
  -- Committed: approved purchase requests not yet on a posted bill
  select coalesce(r.needed_by, r.decided_at::date, r.created_at::date), r.project_id,
         case r.kind when 'material' then 'materials' else r.kind end, 'Purchase request', r.number, r.description,
         null, null, round(r.qty * r.est_unit_cost, 2), false, true, r.id
    from project_requests r left join bills b on b.id = r.bill_id
   where r.company_id = cid and (r.status = 'approved' or (r.status = 'billed' and (b.id is null or b.status = 'draft')))
$$;
revoke execute on function public.project_cost_items(uuid) from public;

create or replace function public.project_cost_totals(p_project uuid)
returns table (actual numeric, committed numeric, budget numeric)
language sql stable security definer set search_path = public as $$
  select coalesce(sum(i.amount) filter (where not i.committed), 0), coalesce(sum(i.amount) filter (where i.committed), 0),
         (select coalesce(sum(cost_budget),0) from project_budget_lines where project_id = p_project)
    from projects p left join lateral project_cost_items(p.company_id) i on i.project_id = p.id
   where p.id = p_project;
$$;
revoke execute on function public.project_cost_totals(uuid) from public;

create or replace function public.decide_request(p_ids uuid[], p_approve boolean, p_reason text default null)
returns int language plpgsql security definer set search_path = public as $$
declare r project_requests; n int := 0; tot record; v_amt numeric; v_acct boolean;
begin
  perform set_config('sika.requests','on', true);
  for r in select * from project_requests where id = any(p_ids) order by created_at for update loop
    v_acct := has_role(r.company_id, array['owner','admin','accountant']);
    if not (v_acct or can_manage_project(r.project_id)) then
      raise exception 'Only the project''s manager or an accountant can decide %', r.number;
    end if;
    if r.status <> 'submitted' then raise exception '% has already been decided', r.number; end if;
    if p_approve then
      v_amt := round(r.qty * r.est_unit_cost, 2);
      select * into tot from project_cost_totals(r.project_id);
      if not v_acct and (tot.budget = 0 or tot.actual + tot.committed + v_amt > tot.budget) then
        raise exception '% would take the project to GH₵ % against a cost budget of GH₵ %. An accountant or the owner must approve it.',
          r.number, to_char(tot.actual + tot.committed + v_amt, 'FM999,999,990.00'), to_char(tot.budget, 'FM999,999,990.00');
      end if;
      update project_requests set status = 'approved', decided_by = auth.uid(), decided_at = now(), reject_reason = null where id = r.id;
    else
      update project_requests set status = 'rejected', decided_by = auth.uid(), decided_at = now(), reject_reason = p_reason where id = r.id;
    end if;
    n := n + 1;
  end loop;
  perform set_config('sika.requests','off', true);
  return n;
end $$;

-- Turn approved requests into one draft supplier bill. The accountant enters the supplier's real prices and posts it.
create or replace function public.bill_requests(p_ids uuid[], p_supplier uuid, p_date date default current_date, p_ref text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare cid uuid; v_bill uuid; r record; i int := 0;
begin
  select company_id into cid from project_requests where id = any(p_ids) limit 1;
  if cid is null then raise exception 'Choose at least one request'; end if;
  perform require_member(cid, array['owner','admin','accountant']);
  if exists (select 1 from project_requests where id = any(p_ids) and (company_id <> cid or not (status = 'approved' or (status = 'billed' and bill_id is null)))) then
    raise exception 'Only approved requests that are not on a bill yet can be billed';
  end if;
  if not exists (select 1 from suppliers where id = p_supplier and company_id = cid) then raise exception 'Choose a supplier'; end if;
  insert into bills (company_id, supplier_id, supplier_ref, bill_date, currency, exchange_rate, notes)
  values (cid, p_supplier, p_ref, p_date, 'GHS', 1,
          'From purchase requests ' || (select string_agg(number, ', ' order by number) from project_requests where id = any(p_ids)))
  returning id into v_bill;
  for r in select * from project_requests where id = any(p_ids) order by number loop
    insert into bill_lines (bill_id, company_id, product_id, account_id, description, qty, unit_cost, taxable, sort, project_id, project_category, request_id)
    values (v_bill, cid, case when r.kind = 'material' then r.product_id end,
      case when r.kind = 'material' and r.product_id is not null then null
           else coalesce(case when r.kind = 'other' then r.account_id end,
                         acct(cid, case r.kind when 'material' then 'project_materials' when 'subcontract' then 'subcontract'
                                               when 'equipment' then 'equipment_hire' else 'expense' end)) end,
      r.number || ' — ' || r.description, r.qty, r.est_unit_cost, true, i, r.project_id,
      case r.kind when 'material' then 'materials' else r.kind end, r.id);
    i := i + 1;
  end loop;
  perform set_config('sika.requests','on', true);
  update project_requests set status = 'billed', bill_id = v_bill, supplier_id = coalesce(supplier_id, p_supplier) where id = any(p_ids);
  perform set_config('sika.requests','off', true);
  return v_bill;
end $$;

-- A deleted draft bill puts its requests back to approved.
create or replace function public.requests_unbill() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform set_config('sika.requests','on', true);
  update project_requests set status = 'approved', bill_id = null where bill_id = old.id and status = 'billed';
  perform set_config('sika.requests','off', true);
  return old;
end $$;
create trigger bills_unbill_requests before delete on public.bills for each row execute function public.requests_unbill();

-- Training cost as a draft supplier bill to 6450 Staff training.
create or replace function public.bill_training(p_training uuid, p_supplier uuid, p_date date default current_date)
returns uuid language plpgsql security definer set search_path = public as $$
declare t trainings; v_bill uuid;
begin
  select * into t from trainings where id = p_training for update;
  if not found then raise exception 'Training not found'; end if;
  perform require_member(t.company_id, array['owner','admin','accountant','hr']);
  if t.bill_id is not null then raise exception 'This training already has a bill'; end if;
  if t.cost <= 0 then raise exception 'Enter the training cost first'; end if;
  if not exists (select 1 from suppliers where id = p_supplier and company_id = t.company_id) then raise exception 'Choose the training provider as a supplier'; end if;
  insert into bills (company_id, supplier_id, bill_date, currency, exchange_rate, notes)
  values (t.company_id, p_supplier, p_date, 'GHS', 1, 'Training: ' || t.title) returning id into v_bill;
  insert into bill_lines (bill_id, company_id, account_id, description, qty, unit_cost, taxable, sort)
  values (v_bill, t.company_id, acct(t.company_id,'training'), 'Training: ' || t.title, 1, t.cost, true, 0);
  update trainings set bill_id = v_bill, supplier_id = p_supplier where id = p_training;
  return v_bill;
end $$;

-- ---------------------------------------------------------------- 7. Project costs: report, KPIs, alerts
create or replace function public.project_cost_report(cid uuid, p_from date, p_to date, p_project uuid default null)
returns table (item_date date, project_id uuid, project text, category text, source text, reference text, description text,
               account_code text, account_name text, amount numeric, in_ledger boolean, committed boolean, doc_id uuid)
language sql stable security definer set search_path = public as $$
  select i.item_date, i.project_id, coalesce(p.number || ' ', '') || p.name, i.category, i.source, i.reference, i.description,
         i.account_code, i.account_name, i.amount, i.in_ledger, i.committed, i.doc_id
    from project_cost_items(cid) i join projects p on p.id = i.project_id
   where (has_role(cid, array['owner','admin','accountant']) or can_manage_project(i.project_id))
     and (p_project is null or i.project_id = p_project)
     and (i.committed or i.item_date between p_from and p_to)
   order by p.name, i.item_date, i.source;
$$;

create or replace function public.project_actuals_by_category(p_project uuid)
returns table (category text, actual numeric)
language sql stable security definer set search_path = public as $$
  select i.category, sum(i.amount) from projects p cross join lateral project_cost_items(p.company_id) i
   where p.id = p_project and i.project_id = p_project and not i.committed and is_member(p.company_id)
   group by i.category;
$$;

create or replace function public.project_committed_by_category(p_project uuid)
returns table (category text, committed numeric)
language sql stable security definer set search_path = public as $$
  select i.category, sum(i.amount) from projects p cross join lateral project_cost_items(p.company_id) i
   where p.id = p_project and i.project_id = p_project and i.committed and is_member(p.company_id)
   group by i.category;
$$;

drop function if exists public.project_kpis(uuid);
create function public.project_kpis(cid uuid)
returns table (project_id uuid, number text, name text, customer text, manager_id uuid, billing_type text, status text, health text,
  currency text, pct_complete int, est_hours numeric, actual_hours numeric, budget_cost numeric, actual_cost numeric,
  budget_revenue numeric, invoiced numeric, unbilled numeric, eac_cost numeric, forecast_margin numeric,
  overdue_tasks int, open_issues int, serious_issues int, last_update timestamptz, end_date date,
  committed_cost numeric, pending_requests int)
language sql stable security definer set search_path = public as $$
  with p as (
    select p.*, c.name as cust,
      case when p.currency = 'GHS' then 1 else coalesce((select rate from currencies x where x.company_id = p.company_id and x.code = p.currency), 1) end as fx
      from projects p left join customers c on c.id = p.customer_id
     where p.company_id = cid and not p.is_template and is_member(cid)
  ), items as (
    select project_id, sum(amount) filter (where not committed) actual, sum(amount) filter (where committed) committed
      from project_cost_items(cid) group by project_id
  ), t as (
    select project_id, sum(coalesce(estimated_hours,0)) est,
      sum(coalesce(estimated_hours,0) * coalesce(percent_complete, case status when 'done' then 100 when 'doing' then 50 else 0 end) / 100.0) est_done,
      count(*) n, count(*) filter (where status = 'done') n_done,
      count(*) filter (where status <> 'done' and due_date < current_date) overdue
    from tasks group by project_id
  ), ts as (
    select t.project_id, sum(t.hours) hrs, sum(t.hours * coalesce(e.cost_rate,0)) cost,
      sum(t.hours) filter (where coalesce(e.cost_rate,0) > 0) costed_hrs,
      sum(case when t.billable and t.invoice_id is null then t.hours * coalesce(t.bill_rate, 0) else 0 end) unbilled_ccy
    from timesheets t left join employees e on e.id = t.employee_id where t.status = 'approved' group by t.project_id
  ), ex as (
    select project_id, sum(case when billable and invoice_id is null then amount_home else 0 end) unbilled
      from expense_claims where status in ('approved','reimbursed') and project_id is not null group by project_id
  ), bud as (
    select project_id, sum(cost_budget) cost, sum(revenue_budget) rev from project_budget_lines group by project_id
  ), inv as (
    select project_id, sum(subtotal * exchange_rate) amt from invoices where status <> 'draft' and project_id is not null group by project_id
  ), ms as (
    select project_id, sum(amount) filter (where status = 'ready') ready from project_milestones group by project_id
  ), iss as (
    select project_id, count(*) filter (where status in ('open','in_progress')) n,
      count(*) filter (where status in ('open','in_progress') and severity in ('high','critical')) serious
      from project_issues group by project_id
  ), up as (select project_id, max(created_at) last_at from project_updates group by project_id),
  rq as (select project_id, count(*) filter (where status = 'submitted') n from project_requests group by project_id),
  calc as (
    select p.*, coalesce(i.actual,0) act, coalesce(i.committed,0) com,
      coalesce(i.actual,0) + coalesce(i.committed,0)
        + greatest(coalesce(t.est,0) - coalesce(t.est_done,0), 0) * coalesce(ts.cost / nullif(ts.costed_hrs,0), 0) eac,
      coalesce(nullif(bud.rev,0), p.contract_value * p.fx, 0) rev
      from p left join items i on i.project_id = p.id left join t on t.project_id = p.id
      left join ts on ts.project_id = p.id left join bud on bud.project_id = p.id
  )
  select c.id, c.number, c.name, c.cust, c.manager_id, c.billing_type, c.status, c.health, c.currency,
    coalesce(c.percent_complete_override,
      case when coalesce(t.est,0) > 0 then round(t.est_done / t.est * 100)::int
           when coalesce(t.n,0) > 0 then round(t.n_done::numeric / t.n * 100)::int else 0 end),
    coalesce(t.est,0), coalesce(ts.hrs,0), coalesce(bud.cost,0), round(c.act, 2), round(c.rev, 2),
    round(coalesce(inv.amt,0), 2),
    round(case when c.billing_type = 'time_materials' then coalesce(ts.unbilled_ccy,0) * c.fx + coalesce(ex.unbilled,0)
               when c.billing_type = 'fixed_price' then coalesce(ms.ready,0) * c.fx + coalesce(ex.unbilled,0) else 0 end, 2),
    round(c.eac, 2), round(c.rev - c.eac, 2),
    coalesce(t.overdue,0)::int, coalesce(iss.n,0)::int, coalesce(iss.serious,0)::int, up.last_at, c.end_date,
    round(c.com, 2), coalesce(rq.n,0)::int
  from calc c left join t on t.project_id = c.id left join ts on ts.project_id = c.id left join ex on ex.project_id = c.id
    left join bud on bud.project_id = c.id left join inv on inv.project_id = c.id left join ms on ms.project_id = c.id
    left join iss on iss.project_id = c.id left join up on up.project_id = c.id left join rq on rq.project_id = c.id
  order by c.status = 'done', c.name;
$$;

-- Projects over, or close to, their cost budget. Accountants see all; a project manager sees their own.
create or replace function public.project_budget_alerts(cid uuid)
returns table (project_id uuid, number text, name text, manager_id uuid, budget_cost numeric, actual_cost numeric,
               committed_cost numeric, eac_cost numeric, used_pct int, level text, reason text, over_categories text[])
language sql stable security definer set search_path = public as $$
  with k as (select * from project_kpis(cid) where status <> 'done' and budget_cost > 0),
  cat as (   -- categories spending more than their budget line (or spending with no budget line at all)
    select s.project_id, array_agg(s.category order by s.category) cats
      from (select i.project_id, i.category, sum(i.amount) spent from project_cost_items(cid) i group by 1, 2) s
      left join (select project_id, category, sum(cost_budget) budget from project_budget_lines where company_id = cid group by 1, 2) b
        on b.project_id = s.project_id and b.category = s.category
     where s.spent > 0 and s.spent > coalesce(b.budget, 0)
     group by s.project_id)
  select k.project_id, k.number, k.name, k.manager_id, k.budget_cost, k.actual_cost, k.committed_cost, k.eac_cost,
    round((k.actual_cost + k.committed_cost) / k.budget_cost * 100)::int,
    case when k.actual_cost + k.committed_cost > k.budget_cost then 'over'
         when k.eac_cost > k.budget_cost then 'forecast_over' else 'warning' end,
    case when k.actual_cost + k.committed_cost > k.budget_cost then 'Spent and committed cost is over the cost budget'
         when k.eac_cost > k.budget_cost then 'Forecast cost at completion is over the cost budget'
         else 'Spent and committed cost has reached 90% of the cost budget' end,
    coalesce(cat.cats, '{}')
  from k left join cat on cat.project_id = k.project_id
  where (k.actual_cost + k.committed_cost >= k.budget_cost * 0.9 or k.eac_cost > k.budget_cost or cat.cats is not null)
    and (has_role(cid, array['owner','admin','accountant']) or k.manager_id = auth.uid())
  order by (k.actual_cost + k.committed_cost) / k.budget_cost desc;
$$;

-- ---------------------------------------------------------------- 8. New companies get the v1.4 accounts
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
  perform seed_accounts_v13(v);
  perform seed_accounts_v14(v);
  perform seed_leave_types(v);
  perform seed_asset_categories(v);
  return v;
end $$;

-- ---------------------------------------------------------------- 9. Row-level security
alter table public.project_requests enable row level security;
create policy "members read requests" on public.project_requests for select using (is_member(company_id));
create policy "members raise requests" on public.project_requests for insert
  with check (is_member(company_id));
create policy "requester or manager edits" on public.project_requests for update
  using ((requested_by = auth.uid() and status in ('draft','submitted')) or can_manage_project(project_id)
         or has_role(company_id, array['owner','admin','accountant']));
create policy "requester or manager deletes" on public.project_requests for delete
  using (status in ('draft','submitted','rejected','cancelled')
         and (requested_by = auth.uid() or can_manage_project(project_id) or has_role(company_id, array['owner','admin','accountant'])));

alter table public.trainings enable row level security;
alter table public.training_attendees enable row level security;
create policy "members read trainings" on public.trainings for select using (is_member(company_id));
create policy "hr writes trainings" on public.trainings for all
  using (has_role(company_id, array['owner','admin','hr'])) with check (has_role(company_id, array['owner','admin','hr']));
create policy "members read attendees" on public.training_attendees for select using (is_member(company_id));
create policy "hr writes attendees" on public.training_attendees for all
  using (has_role(company_id, array['owner','admin','hr'])) with check (has_role((select company_id from trainings where id = training_id), array['owner','admin','hr']));

alter table public.training_requests enable row level security;
create policy "hr, requester and employee read" on public.training_requests for select
  using (has_role(company_id, array['owner','admin','hr','accountant']) or requested_by = auth.uid() or employee_id in (select my_employee_ids()));
create policy "members request training" on public.training_requests for insert
  with check (is_member(company_id)   -- company_id is filled from the employee by the trigger
              and (employee_id in (select my_employee_ids()) or not has_role(company_id, array['staff'])));
create policy "requester edits or cancels" on public.training_requests for update
  using ((requested_by = auth.uid() and status = 'submitted') or has_role(company_id, array['owner','admin','hr']));
create policy "requester or hr deletes" on public.training_requests for delete
  using ((requested_by = auth.uid() and status in ('submitted','rejected','cancelled')) or has_role(company_id, array['owner','admin','hr']));

-- Function permissions
revoke execute on all functions in schema public from public, anon;
grant execute on all functions in schema public to authenticated;
revoke execute on function public.post_journal(uuid,date,text,jsonb,text,uuid) from authenticated;
revoke execute on function public.seed_accounts(uuid) from authenticated;
revoke execute on function public.seed_accounts_v11(uuid) from authenticated;
revoke execute on function public.seed_accounts_v12(uuid) from authenticated;
revoke execute on function public.seed_accounts_v13(uuid) from authenticated;
revoke execute on function public.seed_accounts_v14(uuid) from authenticated;
revoke execute on function public.seed_leave_types(uuid) from authenticated;
revoke execute on function public.seed_asset_categories(uuid) from authenticated;
revoke execute on function public.next_number(uuid,text,text) from authenticated;
revoke execute on function public.project_cost_items(uuid) from authenticated;
revoke execute on function public.project_cost_totals(uuid) from authenticated;
grant execute on function public.public_help(uuid) to anon;
grant execute on function public.submit_case_public(uuid,text,text,text,text,text) to anon;
grant execute on function public.case_status_public(text,text) to anon;
grant execute on function public.reply_case_public(text,text,text,int) to anon;

