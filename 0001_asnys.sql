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
