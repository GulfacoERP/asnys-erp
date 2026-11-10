-- =====================================================================
-- Asnys ERP v2.0 — built for growth
--   1. Branches and cost centres on documents, payroll and every ledger line; reports by branch / cost centre
--   2. Approval chains with amount limits for supplier bills, payroll, purchase requests and expense claims
--   3. Full audit trail: who changed what, when, old and new values
--   4. Bank and cash transactions: money in, money out and transfers not tied to an invoice or bill
--   5. Opening balances: trial balance, customer and supplier balances, opening stock
--   6. General ledger with running balances and source documents; control-account checks; unposted documents
--   7. Paged customer/supplier balances for large companies
-- Run after 0005.
-- =====================================================================

-- ---------------------------------------------------------------- 1. Accounts
alter table public.accounts add column if not exists is_bank boolean not null default false;
update public.accounts set is_bank = true where system_key in ('cash','momo','bank');

create or replace function public.seed_accounts_v20(cid uuid)
returns void language sql security definer set search_path = public as $$
  insert into accounts (company_id, code, name, type, system_key) values
  (cid,'3050','Opening balance equity','equity','opening')
  on conflict do nothing;
  update accounts set is_bank = true where company_id = cid and system_key in ('cash','momo','bank');
$$;
select public.seed_accounts_v20(id) from public.companies;

-- ---------------------------------------------------------------- 2. Branches and cost centres
create table public.branches (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  code text not null,
  name text not null,
  address text,
  active boolean not null default true,
  unique (company_id, code)
);
create table public.cost_centres (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  code text not null,
  name text not null,
  parent_id uuid references public.cost_centres(id) on delete set null,
  active boolean not null default true,
  unique (company_id, code)
);

do $$ declare t text; begin
  foreach t in array array['invoices','bills','credit_notes','expense_claims','projects','employees','assets','journal_lines'] loop
    execute format('alter table public.%I add column if not exists branch_id uuid references public.branches(id) on delete set null', t);
    execute format('alter table public.%I add column if not exists cost_centre_id uuid references public.cost_centres(id) on delete set null', t);
  end loop;
end $$;
alter table public.bill_lines add column if not exists cost_centre_id uuid references public.cost_centres(id) on delete set null;
create index if not exists journal_lines_branch on public.journal_lines (branch_id) where branch_id is not null;
create index if not exists journal_lines_cc on public.journal_lines (cost_centre_id) where cost_centre_id is not null;
create index if not exists journal_lines_entry on public.journal_lines (entry_id);
create index if not exists journal_lines_account on public.journal_lines (account_id);

-- ---------------------------------------------------------------- 3. Bank and cash transactions (table first: dimensions read it)
create table public.cash_transactions (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  number text,
  txn_date date not null,
  kind text not null check (kind in ('receive','spend','transfer')),
  account_id uuid not null references public.accounts(id),          -- the cash, MoMo or bank account (money from, for a transfer)
  counter_account_id uuid not null references public.accounts(id),  -- income/expense/liability/equity account, or the bank account money goes to
  amount numeric(14,2) not null check (amount > 0),
  payee text,
  reference text,
  description text not null,
  branch_id uuid references public.branches(id) on delete set null,
  cost_centre_id uuid references public.cost_centres(id) on delete set null,
  project_id uuid references public.projects(id) on delete set null,
  status text not null default 'posted' check (status in ('posted','voided')),
  journal_entry_id uuid references public.journal_entries(id),
  void_entry_id uuid references public.journal_entries(id),
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);

-- The branch and cost centre of the document behind a ledger entry.
create or replace function public.doc_dims(p_type text, p_id uuid, out branch_id uuid, out cost_centre_id uuid)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  if p_id is null then return; end if;
  if p_type = 'invoice' then select i.branch_id, i.cost_centre_id into branch_id, cost_centre_id from invoices i where i.id = p_id;
  elsif p_type = 'payment' then select i.branch_id, i.cost_centre_id into branch_id, cost_centre_id from payments p join invoices i on i.id = p.invoice_id where p.id = p_id;
  elsif p_type = 'credit_note' then select coalesce(c.branch_id, i.branch_id), coalesce(c.cost_centre_id, i.cost_centre_id) into branch_id, cost_centre_id
          from credit_notes c left join invoices i on i.id = c.invoice_id where c.id = p_id;
  elsif p_type = 'bill' then select b.branch_id, b.cost_centre_id into branch_id, cost_centre_id from bills b where b.id = p_id;
  elsif p_type = 'bill_payment' then select b.branch_id, b.cost_centre_id into branch_id, cost_centre_id from bill_payments p join bills b on b.id = p.bill_id where p.id = p_id;
  elsif p_type = 'expense' then select coalesce(x.branch_id, pr.branch_id, e.branch_id), coalesce(x.cost_centre_id, pr.cost_centre_id, e.cost_centre_id) into branch_id, cost_centre_id
          from expense_claims x left join projects pr on pr.id = x.project_id left join employees e on e.id = x.employee_id where x.id = p_id;
  elsif p_type in ('asset','asset_disposal') then select a.branch_id, a.cost_centre_id into branch_id, cost_centre_id from assets a where a.id = p_id;
  elsif p_type = 'cash' then select c.branch_id, c.cost_centre_id into branch_id, cost_centre_id from cash_transactions c where c.id = p_id;
  end if;
end $$;

create or replace function public.journal_line_dims() returns trigger
language plpgsql security definer set search_path = public as $$
declare st text; sid uuid; b uuid; c uuid;
begin
  if new.branch_id is null or new.cost_centre_id is null then
    select source_type, source_id into st, sid from journal_entries where id = new.entry_id;
    select d.branch_id, d.cost_centre_id into b, c from doc_dims(st, sid) d;
    new.branch_id := coalesce(new.branch_id, b);
    new.cost_centre_id := coalesce(new.cost_centre_id, c);
  end if;
  if new.project_id is not null and (new.branch_id is null or new.cost_centre_id is null) then
    select coalesce(new.branch_id, p.branch_id), coalesce(new.cost_centre_id, p.cost_centre_id) into new.branch_id, new.cost_centre_id from projects p where p.id = new.project_id;
  end if;
  return new;
end $$;
create trigger journal_lines_dims before insert on public.journal_lines for each row execute function public.journal_line_dims();

-- post_journal reads branch, cost centre and project from each line.
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
  insert into journal_lines (entry_id, company_id, account_id, debit, credit, project_id, branch_id, cost_centre_id)
  select v_id, cid, (l->>'account_id')::uuid, round(coalesce((l->>'debit')::numeric,0),2), round(coalesce((l->>'credit')::numeric,0),2),
         nullif(l->>'project_id','')::uuid, nullif(l->>'branch_id','')::uuid, nullif(l->>'cost_centre_id','')::uuid
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
  if exists (select 1 from jsonb_array_elements(p_lines) l where
               (nullif(l->>'branch_id','') is not null and not exists (select 1 from branches b where b.id = (l->>'branch_id')::uuid and b.company_id = cid))
            or (nullif(l->>'cost_centre_id','') is not null and not exists (select 1 from cost_centres c where c.id = (l->>'cost_centre_id')::uuid and c.company_id = cid))) then
    raise exception 'A branch or cost centre does not belong to this company';
  end if;
  return post_journal(cid, p_date, p_memo, p_lines, 'manual', null);
end $$;

-- Supplier bills: project and cost centre per line.
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
      v_lines := v_lines || (jl(acct(b.company_id,'inventory'), g_amt, 0) || jsonb_build_object('project_id', l.project_id, 'cost_centre_id', l.cost_centre_id));
    else
      v_lines := v_lines || (jl(l.account_id, g_amt, 0) || jsonb_build_object('project_id', l.project_id, 'cost_centre_id', l.cost_centre_id));
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

-- Payroll: salary costs split by each employee's branch and cost centre.
create or replace function public.post_payroll(p_run uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  r payroll_runs; v_t1 numeric; v_t2 numeric; v_t3e numeric; v_t3r numeric; v_loans numeric;
  v_je uuid; v_date date; s record; ln record; v_left numeric; v_take numeric; v_lines jsonb := '[]'::jsonb; g record;
begin
  select * into r from payroll_runs where id = p_run for update;
  if not found then raise exception 'Payroll run not found'; end if;
  perform require_member(r.company_id, array['owner','admin','accountant']);
  if r.status <> 'draft' then raise exception 'This payroll is already posted'; end if;
  if r.gross = 0 then raise exception 'There are no payslips in this run'; end if;
  select sum(tier1), sum(tier2), sum(tier3_employee), sum(tier3_employer), sum(loan_deduction)
    into v_t1, v_t2, v_t3e, v_t3r, v_loans from payslips where run_id = p_run;
  v_date := (r.period + interval '1 month - 1 day')::date;
  for g in select e.branch_id, e.cost_centre_id, sum(ps.gross) gross, sum(ps.ssnit_employer) er, sum(ps.tier3_employer) t3
             from payslips ps join employees e on e.id = ps.employee_id where ps.run_id = p_run group by 1, 2 loop
    v_lines := v_lines
      || (jl(acct(r.company_id,'salaries'), g.gross, 0) || jsonb_build_object('branch_id', g.branch_id, 'cost_centre_id', g.cost_centre_id))
      || (jl(acct(r.company_id,'employer_ssnit'), g.er, 0) || jsonb_build_object('branch_id', g.branch_id, 'cost_centre_id', g.cost_centre_id))
      || (jl(acct(r.company_id,'employer_tier3'), g.t3, 0) || jsonb_build_object('branch_id', g.branch_id, 'cost_centre_id', g.cost_centre_id));
  end loop;
  v_je := post_journal(r.company_id, v_date, 'Payroll ' || to_char(r.period, 'Mon YYYY'),
    v_lines || jsonb_build_array(
      jl(acct(r.company_id,'paye'), 0, r.paye),
      jl(acct(r.company_id,'ssnit1'), 0, v_t1),
      jl(acct(r.company_id,'tier2'), 0, v_t2),
      jl(acct(r.company_id,'tier3'), 0, v_t3e + v_t3r),
      jl(acct(r.company_id,'staff_loans'), 0, v_loans),
      jl(acct(r.company_id,'net_pay'), 0, r.net)),
    'payroll', r.id);

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

-- Balances with optional branch, cost centre and project filters (used by every report).
drop function if exists public.account_balances(uuid, date, date);
create function public.account_balances(cid uuid, p_from date, p_to date,
  p_branch uuid default null, p_cost_centre uuid default null, p_project uuid default null)
returns table (account_id uuid, code text, name text, type text, debit numeric, credit numeric)
language sql stable security definer set search_path = public as $$
  select a.id, a.code, a.name, a.type, coalesce(sum(l.debit),0)::numeric, coalesce(sum(l.credit),0)::numeric
    from accounts a
    left join (journal_lines l join journal_entries e on e.id = l.entry_id and e.entry_date between p_from and p_to)
      on l.account_id = a.id
     and (p_branch is null or l.branch_id = p_branch)
     and (p_cost_centre is null or l.cost_centre_id = p_cost_centre)
     and (p_project is null or l.project_id = p_project)
   where a.company_id = cid and has_role(cid, array['owner','admin','accountant'])
   group by a.id, a.code, a.name, a.type
   order by a.code;
$$;

-- Income and expenses side by side per branch or per cost centre.
create or replace function public.pl_by_dimension(cid uuid, p_from date, p_to date, p_dim text)
returns table (dim_id uuid, dim_name text, account_id uuid, code text, name text, type text, amount numeric)
language sql stable security definer set search_path = public as $$
  select case when p_dim = 'branch' then l.branch_id else l.cost_centre_id end,
         coalesce(case when p_dim = 'branch' then b.code || ' ' || b.name else c.code || ' ' || c.name end, 'Not assigned'),
         a.id, a.code, a.name, a.type,
         sum(case when a.type = 'income' then l.credit - l.debit else l.debit - l.credit end)
    from journal_lines l join journal_entries e on e.id = l.entry_id join accounts a on a.id = l.account_id
    left join branches b on b.id = l.branch_id left join cost_centres c on c.id = l.cost_centre_id
   where l.company_id = cid and a.type in ('income','expense') and e.entry_date between p_from and p_to
     and has_role(cid, array['owner','admin','accountant'])
   group by 1, 2, 3, 4, 5, 6
   order by 2, 4;
$$;

-- ---------------------------------------------------------------- 4. Approval chains
create table public.approval_rules (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  doc_type text not null check (doc_type in ('bill','payroll','purchase_request','expense_claim')),
  step_no int not null check (step_no between 1 and 9),
  min_amount numeric(14,2) not null default 0 check (min_amount >= 0),     -- GHS; the step applies at or above this amount
  approver_role text check (approver_role in ('owner','admin','accountant','sales','hr','project_manager')),
  approver_user uuid,
  label text not null,
  check (approver_role is not null or approver_user is not null)
);
create table public.approval_steps (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  doc_type text not null,
  doc_id uuid not null,
  step_no int not null,
  label text not null,
  approver_role text,
  approver_user uuid,
  amount numeric(14,2) not null,
  status text not null default 'pending' check (status in ('pending','approved','rejected','skipped')),
  requested_by uuid default auth.uid(),
  decided_by uuid, decided_email text, decided_at timestamptz, note text,
  created_at timestamptz not null default now()
);
create index on public.approval_steps (company_id, status);
create index on public.approval_steps (doc_type, doc_id);
alter table public.project_requests add column if not exists first_approved_by uuid;
alter table public.expense_claims add column if not exists first_approved_by uuid;

-- Company, amount (GHS), a label and a link for any document that can need approval.
create or replace function public.doc_info(p_type text, p_id uuid, out company_id uuid, out amount numeric, out label text, out path text)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  if p_type = 'bill' then
    select b.company_id, round(coalesce((select sum(qty * unit_cost) from bill_lines where bill_id = b.id), 0) * b.exchange_rate, 2),
           coalesce(b.number, 'Draft bill') || ' · ' || coalesce(s.name, '') || coalesce(' · ' || b.supplier_ref, ''), '/bills/' || b.id
      into company_id, amount, label, path from bills b left join suppliers s on s.id = b.supplier_id where b.id = p_id;
  elsif p_type = 'payroll' then
    select r.company_id, r.gross, 'Payroll ' || to_char(r.period, 'Mon YYYY'), '/payroll/' || r.id into company_id, amount, label, path from payroll_runs r where r.id = p_id;
  elsif p_type = 'purchase_request' then
    select r.company_id, round(r.qty * r.est_unit_cost, 2), r.number || ' · ' || r.description || ' · ' || p.name, '/projects/' || r.project_id
      into company_id, amount, label, path from project_requests r join projects p on p.id = r.project_id where r.id = p_id;
  elsif p_type = 'expense_claim' then
    select x.company_id, x.amount_home, 'Expense claim · ' || e.full_name || ' · ' || x.description, '/approvals'
      into company_id, amount, label, path from expense_claims x left join employees e on e.id = x.employee_id where x.id = p_id;
  end if;
end $$;

create or replace function public.approval_required(p_type text, p_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from approval_rules r, doc_info(p_type, p_id) d
                  where r.company_id = d.company_id and r.doc_type = p_type and d.amount >= r.min_amount);
$$;

-- not_required | not_started | pending | approved | rejected | changed (amount went up after approval)
create or replace function public.approval_state(p_type text, p_id uuid) returns text
language plpgsql stable security definer set search_path = public as $$
declare n int; n_pending int; n_rej int; v_max numeric; v_amt numeric;
begin
  select count(*), count(*) filter (where status = 'pending'), count(*) filter (where status = 'rejected'), max(amount)
    into n, n_pending, n_rej, v_max from approval_steps where doc_type = p_type and doc_id = p_id;
  if n = 0 then return case when approval_required(p_type, p_id) then 'not_started' else 'not_required' end; end if;
  if n_rej > 0 then return 'rejected'; end if;
  if n_pending > 0 then return 'pending'; end if;
  select amount into v_amt from doc_info(p_type, p_id);
  if v_amt > v_max + 0.005 and approval_required(p_type, p_id) then return 'changed'; end if;
  return 'approved';
end $$;

create or replace function public.start_approval(p_type text, p_id uuid) returns int
language plpgsql security definer set search_path = public as $$
declare d record; n int;
begin
  select * into d from doc_info(p_type, p_id);
  if d.company_id is null then raise exception 'Document not found'; end if;
  perform require_member(d.company_id);
  if approval_state(p_type, p_id) = 'pending' then raise exception 'This is already waiting for approval'; end if;
  delete from approval_steps where doc_type = p_type and doc_id = p_id;
  insert into approval_steps (company_id, doc_type, doc_id, step_no, label, approver_role, approver_user, amount)
  select d.company_id, p_type, p_id, r.step_no, r.label, r.approver_role, r.approver_user, d.amount
    from approval_rules r where r.company_id = d.company_id and r.doc_type = p_type and d.amount >= r.min_amount
   order by r.step_no;
  get diagnostics n = row_count;
  insert into audit_log (company_id, action, table_name, row_id, detail)
  values (d.company_id, 'approval.submitted', p_type, p_id, jsonb_build_object('label', d.label, 'amount', d.amount, 'steps', n));
  return n;
end $$;

create or replace function public.can_approve_step(s approval_steps) returns boolean
language sql stable security definer set search_path = public as $$
  select s.status = 'pending'
     and not exists (select 1 from approval_steps o where o.doc_type = s.doc_type and o.doc_id = s.doc_id and o.status = 'pending' and o.step_no < s.step_no)
     and (has_role(s.company_id, array['owner'])
          or ((s.approver_user = auth.uid() or (s.approver_role is not null and has_role(s.company_id, array[s.approver_role])))
              and not exists (select 1 from approval_steps o where o.doc_type = s.doc_type and o.doc_id = s.doc_id and o.status = 'approved' and o.decided_by = auth.uid())));
$$;

-- Approved expense claims post to the books (shared by the normal approval and the last step of an approval chain).
create or replace function public.finalize_expense(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare x expense_claims; v_je uuid; e employees;
begin
  select * into x from expense_claims where id = p_id for update;
  if x.status <> 'submitted' then raise exception 'This expense has already been decided'; end if;
  select * into e from employees where id = x.employee_id;
  v_je := post_journal(x.company_id, x.expense_date, 'Expense claim: ' || e.full_name || ' — ' || x.description ||
            case when x.currency <> 'GHS' then ' (' || x.currency || ' ' || x.amount || ' at ' || x.exchange_rate || ')' else '' end,
    jsonb_build_array(jl(x.account_id, x.amount_home, 0) || jsonb_build_object('project_id', x.project_id),
                      jl(acct(x.company_id,'reimburse'), 0, x.amount_home)), 'expense', x.id);
  update expense_claims set status = 'approved', approved_by = coalesce(first_approved_by, auth.uid()), journal_entry_id = v_je where id = p_id;
end $$;

create or replace function public.decide_approval(p_step uuid, p_approve boolean, p_note text default null)
returns text language plpgsql security definer set search_path = public as $$
declare s approval_steps; v_email text; v_left int;
begin
  select * into s from approval_steps where id = p_step for update;
  if not found then raise exception 'Approval step not found'; end if;
  if s.status <> 'pending' then raise exception 'This step has already been decided'; end if;
  if not can_approve_step(s) then
    raise exception 'You cannot decide this step. It may be waiting for an earlier approver, need a different role, or you approved an earlier step.';
  end if;
  if not p_approve and coalesce(trim(p_note),'') = '' then raise exception 'Give a reason for rejecting'; end if;
  select email into v_email from auth.users where id = auth.uid();
  update approval_steps set status = case when p_approve then 'approved' else 'rejected' end,
    decided_by = auth.uid(), decided_email = v_email, decided_at = now(), note = p_note where id = p_step;
  insert into audit_log (company_id, action, table_name, row_id, detail)
  values (s.company_id, case when p_approve then 'approval.approved' else 'approval.rejected' end, s.doc_type, s.doc_id,
          jsonb_build_object('step', s.step_no, 'label', s.label, 'note', p_note, 'amount', s.amount));
  if not p_approve then
    update approval_steps set status = 'skipped' where doc_type = s.doc_type and doc_id = s.doc_id and status = 'pending';
    perform set_config('sika.requests','on', true);
    if s.doc_type = 'purchase_request' then
      update project_requests set status = 'rejected', reject_reason = p_note, decided_by = auth.uid(), decided_at = now() where id = s.doc_id;
    elsif s.doc_type = 'expense_claim' then
      update expense_claims set status = 'rejected', reject_reason = p_note, approved_by = auth.uid() where id = s.doc_id and status = 'submitted';
    end if;
    perform set_config('sika.requests','off', true);
    return 'rejected';
  end if;
  select count(*) into v_left from approval_steps where doc_type = s.doc_type and doc_id = s.doc_id and status = 'pending';
  if v_left = 0 then
    if s.doc_type = 'purchase_request' then
      perform set_config('sika.requests','on', true);
      update project_requests set status = 'approved', decided_by = auth.uid(), decided_at = now() where id = s.doc_id and status = 'submitted';
      perform set_config('sika.requests','off', true);
    elsif s.doc_type = 'expense_claim' then
      perform finalize_expense(s.doc_id);
    end if;
    return 'approved';
  end if;
  return 'pending';
end $$;

-- Steps waiting on me now.
create or replace function public.my_approvals(cid uuid)
returns table (step_id uuid, doc_type text, doc_id uuid, step_no int, step_label text, steps_total int, amount numeric,
               doc_label text, path text, requested_email text, waiting_since timestamptz)
language sql stable security definer set search_path = public as $$
  select s.id, s.doc_type, s.doc_id, s.step_no, s.label,
         (select count(*)::int from approval_steps o where o.doc_type = s.doc_type and o.doc_id = s.doc_id),
         s.amount, d.label, d.path, (select email from auth.users u where u.id = s.requested_by),
         coalesce((select max(o.decided_at) from approval_steps o where o.doc_type = s.doc_type and o.doc_id = s.doc_id and o.status = 'approved'), s.created_at)
    from approval_steps s cross join lateral doc_info(s.doc_type, s.doc_id) d
   where s.company_id = cid and is_member(cid) and can_approve_step(s)
   order by s.created_at;
$$;

-- Enforce: a bill or payroll run that needs approval cannot be posted without it.
create or replace function public.enforce_approval() returns trigger
language plpgsql security definer set search_path = public as $$
declare t text := case tg_table_name when 'bills' then 'bill' else 'payroll' end; st text;
begin
  if old.status = 'draft' and new.status <> 'draft' then
    st := approval_state(t, new.id);
    if st in ('not_started','pending','rejected','changed') then
      raise exception '% needs approval before posting (%). Submit it for approval first.',
        case t when 'bill' then 'This bill' else 'This payroll' end,
        case st when 'not_started' then 'not submitted yet' when 'pending' then 'still waiting' when 'rejected' then 'it was rejected'
                else 'the amount went up after it was approved' end;
    end if;
  end if;
  return new;
end $$;
create trigger bills_enforce_approval before update on public.bills for each row execute function public.enforce_approval();
create trigger payroll_enforce_approval before update on public.payroll_runs for each row execute function public.enforce_approval();

-- Purchase requests and expense claims: the first approval (project manager or accountant) then the finance chain above the limit.
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
    if r.first_approved_by is not null and p_approve then raise exception '% is waiting for the approval chain', r.number; end if;
    if p_approve then
      v_amt := round(r.qty * r.est_unit_cost, 2);
      select * into tot from project_cost_totals(r.project_id);
      if not v_acct and (tot.budget = 0 or tot.actual + tot.committed + v_amt > tot.budget) then
        raise exception '% would take the project to GH₵ % against a cost budget of GH₵ %. An accountant or the owner must approve it.',
          r.number, to_char(tot.actual + tot.committed + v_amt, 'FM999,999,990.00'), to_char(tot.budget, 'FM999,999,990.00');
      end if;
      if approval_required('purchase_request', r.id) then
        update project_requests set first_approved_by = auth.uid() where id = r.id;
        perform start_approval('purchase_request', r.id);
      else
        update project_requests set status = 'approved', decided_by = auth.uid(), decided_at = now(), reject_reason = null where id = r.id;
      end if;
    else
      update project_requests set status = 'rejected', decided_by = auth.uid(), decided_at = now(), reject_reason = p_reason where id = r.id;
      update approval_steps set status = 'skipped' where doc_type = 'purchase_request' and doc_id = r.id and status = 'pending';
    end if;
    n := n + 1;
  end loop;
  perform set_config('sika.requests','off', true);
  return n;
end $$;

create or replace function public.decide_expense(p_id uuid, p_approve boolean, p_reason text default null)
returns void language plpgsql security definer set search_path = public as $$
declare x expense_claims;
begin
  select * into x from expense_claims where id = p_id for update;
  if not found then raise exception 'Expense not found'; end if;
  if not (has_role(x.company_id, array['owner','admin','accountant']) or (x.project_id is not null and can_manage_project(x.project_id))) then
    raise exception 'You can only approve expenses on projects you manage';
  end if;
  if x.status <> 'submitted' then raise exception 'This expense has already been decided'; end if;
  if x.first_approved_by is not null and p_approve then raise exception 'This claim is waiting for the approval chain'; end if;
  if not p_approve then
    update expense_claims set status = 'rejected', reject_reason = p_reason, approved_by = auth.uid() where id = p_id;
    update approval_steps set status = 'skipped' where doc_type = 'expense_claim' and doc_id = p_id and status = 'pending';
    return;
  end if;
  if approval_required('expense_claim', p_id) then
    update expense_claims set first_approved_by = auth.uid() where id = p_id;
    perform start_approval('expense_claim', p_id);
    return;
  end if;
  perform finalize_expense(p_id);
end $$;

-- ---------------------------------------------------------------- 5. Audit trail
alter table public.audit_log add column if not exists table_name text;
alter table public.audit_log add column if not exists row_id uuid;
alter table public.audit_log add column if not exists user_email text;
alter table public.audit_log add column if not exists old_data jsonb;
alter table public.audit_log add column if not exists new_data jsonb;
create index if not exists audit_log_company_time on public.audit_log (company_id, created_at desc);
create index if not exists audit_log_row on public.audit_log (row_id);

create or replace function public.audit_fill() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.user_id := coalesce(new.user_id, auth.uid());
  if new.user_email is null and new.user_id is not null then new.user_email := (select email from auth.users where id = new.user_id); end if;
  return new;
end $$;
create trigger audit_log_fill before insert on public.audit_log for each row execute function public.audit_fill();

create or replace function public.audit_row() returns trigger
language plpgsql security definer set search_path = public as $$
declare o jsonb; n jsonb; d_old jsonb := '{}'; d_new jsonb := '{}'; k text; cid uuid; rid uuid;
  ignore text[] := array['stock_qty','cost','score','sales_ready','updated_at','last_depreciated','accumulated_depreciation','percent_complete'];
begin
  if tg_op <> 'INSERT' then o := to_jsonb(old); end if;
  if tg_op <> 'DELETE' then n := to_jsonb(new); end if;
  cid := coalesce((n->>'company_id')::uuid, (o->>'company_id')::uuid, case when tg_table_name = 'companies' then coalesce((n->>'id')::uuid, (o->>'id')::uuid) end);
  rid := coalesce((n->>'id')::uuid, (o->>'id')::uuid);
  if tg_op = 'UPDATE' then
    for k in select jsonb_object_keys(n) loop
      if k <> all(ignore) and (o->k) is distinct from (n->k) then
        d_old := d_old || jsonb_build_object(k, o->k); d_new := d_new || jsonb_build_object(k, n->k);
      end if;
    end loop;
    if d_new = '{}'::jsonb then return null; end if;
    o := d_old; n := d_new;
  end if;
  insert into audit_log (company_id, action, table_name, row_id, old_data, new_data)
  values (cid, tg_table_name || '.' || lower(tg_op), tg_table_name, rid, o, n);
  return null;
end $$;

do $$ declare t text; begin
  foreach t in array array['accounts','customers','suppliers','products','employees','invoices','bills','credit_notes','payments','bill_payments',
                           'payroll_runs','expense_claims','project_requests','memberships','companies','approval_rules','cash_transactions',
                           'branches','cost_centres','assets','project_budget_lines','sales_quotes'] loop
    if to_regclass('public.' || t) is not null then
      execute format('create trigger %I after insert or update or delete on public.%I for each row execute function public.audit_row()', t || '_audit', t);
    end if;
  end loop;
end $$;

-- Read the trail: owners, admins and accountants.
drop policy if exists "members read" on public.audit_log;
create policy "managers read audit" on public.audit_log for select using (has_role(company_id, array['owner','admin','accountant']));

create or replace function public.audit_trail(cid uuid, p_from date, p_to date, p_table text default null, p_user text default null,
  p_search text default null, p_row uuid default null, p_limit int default 200, p_offset int default 0)
returns table (id bigint, created_at timestamptz, user_email text, action text, table_name text, row_id uuid, old_data jsonb, new_data jsonb, detail jsonb, total bigint)
language sql stable security definer set search_path = public as $$
  select l.id, l.created_at, l.user_email, l.action, l.table_name, l.row_id, l.old_data, l.new_data, l.detail, count(*) over()
    from audit_log l
   where l.company_id = cid and has_role(cid, array['owner','admin','accountant'])
     and l.created_at >= p_from and l.created_at < p_to + 1
     and (p_table is null or l.table_name = p_table)
     and (p_user is null or l.user_email ilike '%' || p_user || '%')
     and (p_row is null or l.row_id = p_row)
     and (p_search is null or l.action ilike '%' || p_search || '%' or coalesce(l.new_data::text,'') ilike '%' || p_search || '%'
          or coalesce(l.old_data::text,'') ilike '%' || p_search || '%' or coalesce(l.detail::text,'') ilike '%' || p_search || '%')
   order by l.created_at desc, l.id desc
   limit least(p_limit, 1000) offset p_offset;
$$;

-- ---------------------------------------------------------------- 6. Bank and cash transactions: posting
create or replace function public.post_cash_transaction(cid uuid, p_kind text, p_date date, p_account uuid, p_counter uuid, p_amount numeric,
  p_description text, p_payee text default null, p_reference text default null,
  p_branch uuid default null, p_cost_centre uuid default null, p_project uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare a accounts; c accounts; v_id uuid; v_je uuid; v_dims jsonb;
begin
  perform require_member(cid, array['owner','admin','accountant']);
  select * into a from accounts where id = p_account and company_id = cid;
  select * into c from accounts where id = p_counter and company_id = cid;
  if a.id is null or c.id is null then raise exception 'Choose accounts from this company''s chart'; end if;
  if not a.is_bank then raise exception '% is not a cash, MoMo or bank account. Mark it as a bank account in the chart of accounts first.', a.name; end if;
  if round(coalesce(p_amount,0),2) <= 0 then raise exception 'Enter an amount above zero'; end if;
  if coalesce(trim(p_description),'') = '' then raise exception 'Describe the transaction'; end if;
  if p_kind = 'transfer' then
    if not c.is_bank or c.id = a.id then raise exception 'A transfer goes to a different cash, MoMo or bank account'; end if;
  elsif p_kind in ('receive','spend') then
    if c.is_bank then raise exception 'To move money between your own accounts, use Transfer'; end if;
    if c.system_key in ('ar','ap','inventory','vat_in','nhil_in','getf_in','vat_out','nhil_out','getf_out') then
      raise exception '% is kept by its own documents. Use an invoice, bill, payment or stock adjustment instead.', c.name;
    end if;
  else raise exception 'Unknown transaction type';
  end if;
  insert into cash_transactions (company_id, number, txn_date, kind, account_id, counter_account_id, amount, payee, reference, description, branch_id, cost_centre_id, project_id)
  values (cid, next_number(cid, 'CB', 'CB-'), p_date, p_kind, p_account, p_counter, round(p_amount,2), p_payee, p_reference, p_description, p_branch, p_cost_centre, p_project)
  returning id into v_id;
  v_dims := jsonb_build_object('project_id', p_project, 'branch_id', p_branch, 'cost_centre_id', p_cost_centre);
  v_je := post_journal(cid, p_date,
    case p_kind when 'receive' then 'Money in' when 'spend' then 'Money out' else 'Transfer' end || ': ' || p_description || coalesce(' — ' || p_payee, ''),
    case p_kind
      when 'receive' then jsonb_build_array(jl(a.id, p_amount, 0) || v_dims, jl(c.id, 0, p_amount) || v_dims)
      when 'spend' then jsonb_build_array(jl(c.id, p_amount, 0) || v_dims, jl(a.id, 0, p_amount) || v_dims)
      else jsonb_build_array(jl(c.id, p_amount, 0) || v_dims, jl(a.id, 0, p_amount) || v_dims) end,
    'cash', v_id);
  update cash_transactions set journal_entry_id = v_je where id = v_id;
  return v_id;
end $$;

create or replace function public.void_cash_transaction(p_id uuid, p_date date default current_date)
returns void language plpgsql security definer set search_path = public as $$
declare t cash_transactions; v_je uuid;
begin
  select * into t from cash_transactions where id = p_id for update;
  if not found then raise exception 'Transaction not found'; end if;
  perform require_member(t.company_id, array['owner','admin','accountant']);
  if t.status = 'voided' then raise exception 'Already voided'; end if;
  v_je := post_journal(t.company_id, p_date, 'Void ' || t.number || ': ' || t.description,
    (select jsonb_agg(jsonb_build_object('account_id', l.account_id, 'debit', l.credit, 'credit', l.debit, 'project_id', l.project_id,
                                         'branch_id', l.branch_id, 'cost_centre_id', l.cost_centre_id))
       from journal_lines l where l.entry_id = t.journal_entry_id), 'cash', t.id);
  update cash_transactions set status = 'voided', void_entry_id = v_je where id = p_id;
end $$;

-- ---------------------------------------------------------------- 7. Opening balances
-- Trial balance at the start date. Receivables, payables and stock come from their own opening items; any difference goes to 3050.
create or replace function public.post_opening_balances(cid uuid, p_date date, p_lines jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_dr numeric; v_cr numeric; v_lines jsonb;
begin
  perform require_member(cid, array['owner','admin','accountant']);
  if exists (select 1 from jsonb_array_elements(p_lines) l join accounts a on a.id = (l->>'account_id')::uuid
              where a.company_id <> cid or a.system_key in ('ar','ap','inventory','opening')) then
    raise exception 'Receivables, payables and stock come from opening customer and supplier balances and opening stock, not from the trial balance';
  end if;
  if exists (select 1 from jsonb_array_elements(p_lines) l where not exists (select 1 from accounts a where a.id = (l->>'account_id')::uuid)) then
    raise exception 'An account was not found';
  end if;
  select coalesce(sum(round((l->>'debit')::numeric,2)),0), coalesce(sum(round((l->>'credit')::numeric,2)),0) into v_dr, v_cr from jsonb_array_elements(p_lines) l;
  v_lines := p_lines;
  if v_dr <> v_cr then v_lines := v_lines || jl(acct(cid,'opening'), greatest(v_cr - v_dr, 0), greatest(v_dr - v_cr, 0)); end if;
  return post_journal(cid, p_date, 'Opening balances', v_lines, 'opening', null);
end $$;

-- An outstanding customer invoice from the old system.
create or replace function public.opening_receivable(p_customer uuid, p_date date, p_amount numeric, p_ref text default null, p_due date default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare c customers; v_id uuid; v_je uuid; v_no text;
begin
  select * into c from customers where id = p_customer;
  if not found then raise exception 'Customer not found'; end if;
  perform require_member(c.company_id, array['owner','admin','accountant']);
  if round(coalesce(p_amount,0),2) <= 0 then raise exception 'The opening balance must be above zero'; end if;
  v_no := coalesce(nullif(trim(p_ref),''), next_number(c.company_id, 'OB', 'OB-'));
  insert into invoices (company_id, number, customer_id, invoice_date, due_date, status, subtotal, total, currency, exchange_rate, notes)
  values (c.company_id, v_no, c.id, p_date, coalesce(p_due, p_date), 'posted', round(p_amount,2), round(p_amount,2), 'GHS', 1, 'Opening balance brought forward')
  returning id into v_id;
  insert into invoice_lines (invoice_id, company_id, description, qty, unit_price, taxable) values (v_id, c.company_id, 'Opening balance brought forward', 1, round(p_amount,2), false);
  v_je := post_journal(c.company_id, p_date, 'Opening balance: ' || c.name || ' (' || v_no || ')',
    jsonb_build_array(jl(acct(c.company_id,'ar'), p_amount, 0), jl(acct(c.company_id,'opening'), 0, p_amount)), 'invoice', v_id);
  update invoices set journal_entry_id = v_je where id = v_id;
  return v_id;
end $$;

-- An unpaid supplier bill from the old system.
create or replace function public.opening_payable(p_supplier uuid, p_date date, p_amount numeric, p_ref text default null, p_due date default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare s suppliers; v_id uuid; v_je uuid; v_no text;
begin
  select * into s from suppliers where id = p_supplier;
  if not found then raise exception 'Supplier not found'; end if;
  perform require_member(s.company_id, array['owner','admin','accountant']);
  if round(coalesce(p_amount,0),2) <= 0 then raise exception 'The opening balance must be above zero'; end if;
  v_no := next_number(s.company_id, 'OBB', 'OBB-');
  insert into bills (company_id, number, supplier_id, supplier_ref, bill_date, due_date, status, subtotal, total, currency, exchange_rate, notes)
  values (s.company_id, v_no, s.id, p_ref, p_date, coalesce(p_due, p_date), 'posted', round(p_amount,2), round(p_amount,2), 'GHS', 1, 'Opening balance brought forward')
  returning id into v_id;
  insert into bill_lines (bill_id, company_id, account_id, description, qty, unit_cost, taxable) values (v_id, s.company_id, acct(s.company_id,'opening'), 'Opening balance brought forward', 1, round(p_amount,2), false);
  v_je := post_journal(s.company_id, p_date, 'Opening balance: ' || s.name || coalesce(' (' || p_ref || ')',''),
    jsonb_build_array(jl(acct(s.company_id,'opening'), p_amount, 0), jl(acct(s.company_id,'ap'), 0, p_amount)), 'bill', v_id);
  update bills set journal_entry_id = v_je where id = v_id;
  return v_id;
end $$;

-- Opening stock now goes to opening balance equity (3050) instead of the owner's capital.
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
    v_other := case when p_kind = 'opening' then acct(p.company_id,'opening') else acct(p.company_id,'stock_adj') end;
    perform post_journal(p.company_id, p_date,
      (case when p_kind = 'opening' then 'Opening stock: ' else 'Stock adjustment: ' end) || p.name || coalesce(' (' || p_note || ')',''),
      case when p_qty > 0
        then jsonb_build_array(jl(acct(p.company_id,'inventory'), v_value, 0), jl(v_other, 0, v_value))
        else jsonb_build_array(jl(v_other, v_value, 0), jl(acct(p.company_id,'inventory'), 0, v_value)) end,
      'stock', p_product);
  end if;
end $$;

-- ---------------------------------------------------------------- 8. General ledger, source documents, checks
create or replace function public.source_ref(p_type text, p_id uuid, out label text, out path text)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  label := initcap(replace(coalesce(p_type, 'manual'), '_', ' '));
  if p_id is null then return; end if;
  if p_type = 'invoice' then select 'Invoice ' || coalesce(number, ''), '/invoices/' || id into label, path from invoices where id = p_id;
  elsif p_type = 'payment' then select 'Receipt · ' || coalesce(i.number, ''), '/invoices/' || i.id into label, path from payments p join invoices i on i.id = p.invoice_id where p.id = p_id;
  elsif p_type = 'credit_note' then select 'Credit note ' || coalesce(number, ''), '/credit-notes/' || id into label, path from credit_notes where id = p_id;
  elsif p_type = 'bill' then select 'Bill ' || coalesce(number, ''), '/bills/' || id into label, path from bills where id = p_id;
  elsif p_type = 'bill_payment' then select 'Payment · ' || coalesce(b.number, ''), '/bills/' || b.id into label, path from bill_payments p join bills b on b.id = p.bill_id where p.id = p_id;
  elsif p_type in ('payroll','payroll_payment') then select label || ' ' || to_char(period, 'Mon YYYY'), '/payroll/' || id into label, path from payroll_runs where id = p_id;
  elsif p_type in ('asset','asset_disposal') then select label || ' · ' || coalesce(tag, name), '/assets/' || id into label, path from assets where id = p_id;
  elsif p_type = 'cash' then select 'Bank & cash ' || coalesce(number, ''), '/bank-cash?id=' || id into label, path from cash_transactions where id = p_id;
  elsif p_type = 'expense' then select 'Expense claim · ' || coalesce(e.full_name, ''), null into label, path from expense_claims x left join employees e on e.id = x.employee_id where x.id = p_id;
  elsif p_type = 'stock' then select 'Stock · ' || name, '/products' into label, path from products where id = p_id;
  end if;
end $$;

create or replace function public.general_ledger(cid uuid, p_account uuid, p_from date, p_to date,
  p_branch uuid default null, p_cost_centre uuid default null, p_project uuid default null, p_source text default null,
  p_search text default null, p_limit int default 500, p_offset int default 0)
returns table (line_id uuid, entry_id uuid, entry_no text, entry_date date, memo text, source_type text, source_id uuid,
               debit numeric, credit numeric, balance numeric, branch text, cost_centre text, project text,
               ref_label text, ref_path text, opening numeric, total_rows bigint)
language sql stable security definer set search_path = public as $$
  with f as (
    select l.*, e.entry_no, e.entry_date, e.memo, e.source_type, e.source_id, e.created_at
      from journal_lines l join journal_entries e on e.id = l.entry_id
     where l.company_id = cid and l.account_id = p_account and has_role(cid, array['owner','admin','accountant'])
       and (p_branch is null or l.branch_id = p_branch) and (p_cost_centre is null or l.cost_centre_id = p_cost_centre)
       and (p_project is null or l.project_id = p_project) and (p_source is null or e.source_type = p_source)
  ), op as (select coalesce(sum(debit - credit), 0) v from f where entry_date < p_from),
  rows as (
    select f.*, (select v from op) + sum(f.debit - f.credit) over (order by f.entry_date, f.created_at, f.entry_no, f.id) bal
      from f where f.entry_date between p_from and p_to
  )
  select r.id, r.entry_id, r.entry_no, r.entry_date, r.memo, r.source_type, r.source_id, r.debit, r.credit, r.bal,
         b.code, c.code, p.number, s.label, s.path, (select v from op), count(*) over()
    from rows r left join branches b on b.id = r.branch_id left join cost_centres c on c.id = r.cost_centre_id
    left join projects p on p.id = r.project_id cross join lateral source_ref(r.source_type, r.source_id) s
   where (p_search is null or r.memo ilike '%' || p_search || '%' or r.entry_no ilike '%' || p_search || '%' or s.label ilike '%' || p_search || '%')
   order by r.entry_date, r.created_at, r.entry_no, r.id
   limit least(p_limit, 5000) offset p_offset;
$$;

-- Control accounts against the documents behind them: proof that every transaction reached the books.
create or replace function public.ledger_checks(cid uuid)
returns table (check_name text, ledger numeric, documents numeric, direct numeric, difference numeric, ok boolean, explanation text)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare bal numeric; doc numeric; dir numeric;
begin
  if not has_role(cid, array['owner','admin','accountant']) then return; end if;
  select coalesce(sum(debit),0), coalesce(sum(credit),0) into bal, doc from journal_lines where company_id = cid;
  return query select 'Trial balance (debits vs credits)', bal, doc, 0::numeric, bal - doc, bal = doc, 'Every journal must balance.';

  select coalesce(sum(l.debit - l.credit),0), coalesce(sum(l.debit - l.credit) filter (where e.source_type not in ('invoice','payment','credit_note')),0)
    into bal, dir from journal_lines l join journal_entries e on e.id = l.entry_id where l.account_id = acct(cid,'ar');
  select coalesce(sum(round((total - amount_paid - amount_credited) * exchange_rate, 2)),0)
       - coalesce((select sum(round((total - applied) * exchange_rate, 2)) from credit_notes where company_id = cid and status = 'posted'),0)
    into doc from invoices where company_id = cid and status <> 'draft';
  return query select 'Trade receivables vs unpaid invoices less unused credit notes', bal, doc, dir, bal - doc - dir, abs(bal - doc - dir) < 1,
    'Customer balances in the ledger against open invoices and credit notes not yet used.' ||
    case when dir <> 0 then ' Includes GH₵ ' || to_char(dir, 'FM999,999,990.00') || ' posted to receivables by journal, not by a customer document.' else '' end;

  select coalesce(sum(l.credit - l.debit),0), coalesce(sum(l.credit - l.debit) filter (where e.source_type not in ('bill','bill_payment')),0)
    into bal, dir from journal_lines l join journal_entries e on e.id = l.entry_id where l.account_id = acct(cid,'ap');
  select coalesce(sum(round((total - amount_paid) * exchange_rate, 2)),0) into doc from bills where company_id = cid and status <> 'draft';
  return query select 'Trade payables vs unpaid bills', bal, doc, dir, bal - doc - dir, abs(bal - doc - dir) < 1,
    'Supplier balances in the ledger against open bills.' ||
    case when dir <> 0 then ' Includes GH₵ ' || to_char(dir, 'FM999,999,990.00') || ' posted to payables without a supplier bill (assets bought on credit or journals); record a supplier bill or a payment journal to settle it.' else '' end;

  select coalesce(sum(l.debit - l.credit),0) into bal from journal_lines l where l.account_id = acct(cid,'inventory');
  select coalesce(round(sum(stock_qty * cost), 2),0) into doc from products where company_id = cid;
  return query select 'Inventory vs stock on hand at cost', bal, doc, 0::numeric, bal - doc, abs(bal - doc) < greatest(1, abs(doc) * 0.001), 'Stock account against quantity × average cost of every product.';
  select coalesce(sum(l.credit - l.debit),0) into bal from journal_lines l where l.account_id = acct(cid,'net_pay');
  select coalesce(sum(net),0) into doc from payroll_runs where company_id = cid and status = 'posted';
  return query select 'Net salaries payable vs posted, unpaid payroll', bal, doc, 0::numeric, bal - doc, abs(bal - doc) < 1, 'Salaries posted but not yet paid.';
  select coalesce(sum(l.credit - l.debit),0) into bal from journal_lines l where l.account_id = acct(cid,'reimburse');
  select coalesce(sum(amount_home),0) into doc from expense_claims where company_id = cid and status = 'approved';
  return query select 'Expense claims payable vs approved, unpaid claims', bal, doc, 0::numeric, bal - doc, abs(bal - doc) < 1, 'Staff claims approved but not yet reimbursed.';
  select coalesce(sum(l.debit - l.credit),0) into bal from journal_lines l where l.account_id = acct(cid,'fa_cost');
  select coalesce(sum(cost),0) into doc from assets where company_id = cid and status = 'active';
  return query select 'Fixed assets at cost vs asset register', bal, doc, 0::numeric, bal - doc, abs(bal - doc) < 1, 'Asset cost account against active assets in the register.';
end $$;

-- Documents not in the books yet, or waiting on someone.
create or replace function public.unposted_documents(cid uuid)
returns table (kind text, n bigint, amount numeric, oldest date, path text)
language sql stable security definer set search_path = public as $$
  select * from (
    select 'Draft invoices', count(*), coalesce(sum(subtotal),0)::numeric, min(invoice_date), '/invoices' from invoices where company_id = cid and status = 'draft'
    union all select 'Draft supplier bills', count(*), coalesce((select sum(l.qty * l.unit_cost * b2.exchange_rate) from bill_lines l join bills b2 on b2.id = l.bill_id where b2.company_id = cid and b2.status = 'draft'),0), min(bill_date), '/bills' from bills where company_id = cid and status = 'draft'
    union all select 'Draft credit notes', count(*), coalesce(sum(subtotal),0)::numeric, min(credit_date), '/credit-notes' from credit_notes where company_id = cid and status = 'draft'
    union all select 'Payroll not posted', count(*), coalesce(sum(gross),0), min(period), '/payroll' from payroll_runs where company_id = cid and status = 'draft'
    union all select 'Expense claims awaiting approval', count(*), coalesce(sum(amount_home),0), min(expense_date), '/approvals' from expense_claims where company_id = cid and status = 'submitted'
    union all select 'Timesheets awaiting approval (hours)', count(*), coalesce(sum(hours),0), min(work_date), '/approvals' from timesheets where company_id = cid and status = 'submitted'
    union all select 'Approved purchase requests not billed', count(*), coalesce(sum(qty * est_unit_cost),0), min(created_at)::date, '/project-costs' from project_requests where company_id = cid and status = 'approved'
    union all select 'Steps waiting in approval chains', count(*), coalesce(sum(amount),0), min(created_at)::date, '/approvals-inbox' from approval_steps where company_id = cid and status = 'pending'
  ) x where has_role(cid, array['owner','admin','accountant']);
$$;

-- Paged customer or supplier list with balances (GHS).
create or replace function public.party_balances(cid uuid, p_kind text, p_search text default null, p_limit int default 50, p_offset int default 0)
returns table (id uuid, name text, phone text, email text, tin text, city text, address text, owner_id uuid, territory_id uuid, partner_id uuid,
               owed numeric, overdue numeric, total_rows bigint)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  if not is_member(cid) then return; end if;
  if p_kind = 'customer' then
    return query
      select c.id, c.name, c.phone, c.email, c.tin, c.city, c.address, c.owner_id, c.territory_id, c.partner_id,
             coalesce(sum(round((i.total - i.amount_paid - i.amount_credited) * i.exchange_rate, 2)), 0)::numeric,
             coalesce(sum(round((i.total - i.amount_paid - i.amount_credited) * i.exchange_rate, 2)) filter (where i.due_date < current_date), 0)::numeric,
             count(*) over()
        from customers c left join invoices i on i.customer_id = c.id and i.status = 'posted'
       where c.company_id = cid and (p_search is null or c.name ilike '%' || p_search || '%' or coalesce(c.phone,'') ilike '%' || p_search || '%'
             or coalesce(c.city,'') ilike '%' || p_search || '%' or coalesce(c.tin,'') ilike '%' || p_search || '%')
       group by c.id order by c.name limit least(p_limit, 500) offset p_offset;
  else
    return query
      select s.id, s.name, s.phone, s.email, s.tin, s.city, s.address, null::uuid, null::uuid, null::uuid,
             coalesce(sum(round((b.total - b.amount_paid) * b.exchange_rate, 2)), 0)::numeric,
             coalesce(sum(round((b.total - b.amount_paid) * b.exchange_rate, 2)) filter (where b.due_date < current_date), 0)::numeric,
             count(*) over()
        from suppliers s left join bills b on b.supplier_id = s.id and b.status = 'posted'
       where s.company_id = cid and (p_search is null or s.name ilike '%' || p_search || '%' or coalesce(s.phone,'') ilike '%' || p_search || '%'
             or coalesce(s.city,'') ilike '%' || p_search || '%' or coalesce(s.tin,'') ilike '%' || p_search || '%')
       group by s.id order by s.name limit least(p_limit, 500) offset p_offset;
  end if;
end $$;

-- Search indexes for large lists
create index if not exists invoices_company_date on public.invoices (company_id, invoice_date desc);
create index if not exists bills_company_date on public.bills (company_id, bill_date desc);
create index if not exists invoices_customer on public.invoices (customer_id);
create index if not exists bills_supplier on public.bills (supplier_id);
create index if not exists customers_company_name on public.customers (company_id, name);
create index if not exists suppliers_company_name on public.suppliers (company_id, name);
create index if not exists products_company_name on public.products (company_id, name);
create index if not exists payslips_run on public.payslips (run_id);
create index if not exists timesheets_project on public.timesheets (project_id, status);

-- Salary bank account details for the payment file
alter table public.employees add column if not exists bank_branch text;
alter table public.employees add column if not exists pay_method text not null default 'bank' check (pay_method in ('bank','momo','cash'));

-- ---------------------------------------------------------------- 9. New companies
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
  perform seed_accounts_v20(v);
  perform seed_leave_types(v);
  perform seed_asset_categories(v);
  return v;
end $$;

-- ---------------------------------------------------------------- 10. Row-level security
alter table public.branches enable row level security;
alter table public.cost_centres enable row level security;
create policy "members read branches" on public.branches for select using (is_member(company_id));
create policy "accountants manage branches" on public.branches for all using (has_role(company_id, array['owner','admin','accountant'])) with check (has_role(company_id, array['owner','admin','accountant']));
create policy "members read cost centres" on public.cost_centres for select using (is_member(company_id));
create policy "accountants manage cost centres" on public.cost_centres for all using (has_role(company_id, array['owner','admin','accountant'])) with check (has_role(company_id, array['owner','admin','accountant']));

alter table public.approval_rules enable row level security;
create policy "members read rules" on public.approval_rules for select using (is_member(company_id));
create policy "owners manage rules" on public.approval_rules for all using (has_role(company_id, array['owner','admin'])) with check (has_role(company_id, array['owner','admin']));
alter table public.approval_steps enable row level security;
create policy "members read steps" on public.approval_steps for select using (is_member(company_id));

alter table public.cash_transactions enable row level security;
create policy "accountants read cash" on public.cash_transactions for select using (has_role(company_id, array['owner','admin','accountant']));

-- Function permissions
revoke execute on all functions in schema public from public, anon;
grant execute on all functions in schema public to authenticated;
revoke execute on function public.post_journal(uuid,date,text,jsonb,text,uuid) from authenticated;
revoke execute on function public.seed_accounts(uuid) from authenticated;
revoke execute on function public.seed_accounts_v11(uuid) from authenticated;
revoke execute on function public.seed_accounts_v12(uuid) from authenticated;
revoke execute on function public.seed_accounts_v13(uuid) from authenticated;
revoke execute on function public.seed_accounts_v14(uuid) from authenticated;
revoke execute on function public.seed_accounts_v20(uuid) from authenticated;
revoke execute on function public.seed_leave_types(uuid) from authenticated;
revoke execute on function public.seed_asset_categories(uuid) from authenticated;
revoke execute on function public.next_number(uuid,text,text) from authenticated;
revoke execute on function public.project_cost_items(uuid) from authenticated;
revoke execute on function public.project_cost_totals(uuid) from authenticated;
revoke execute on function public.finalize_expense(uuid) from authenticated;
revoke execute on function public.doc_dims(text,uuid) from authenticated;
grant execute on function public.public_help(uuid) to anon;
grant execute on function public.submit_case_public(uuid,text,text,text,text,text) to anon;
grant execute on function public.case_status_public(text,text) to anon;
grant execute on function public.reply_case_public(text,text,text,int) to anon;
