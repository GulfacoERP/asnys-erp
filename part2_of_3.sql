-- Asnys ERP: new installation, part2 of 3.
-- Contains 0006_asnys_v2_0.sql, 0007_asnys_v2_1.sql, 0008_asnys_v2_2.sql, 0009_asnys_v2_3.sql. Run part 1, then part 2, then part 3, once each, in a new Supabase project.


-- ======================================================================
-- 0006_asnys_v2_0.sql
-- ======================================================================
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


-- ======================================================================
-- 0007_asnys_v2_1.sql
-- ======================================================================
-- =====================================================================
-- Asnys ERP v2.1 — inventory, purchasing and the project lifecycle
--   1. Warehouses (stores and sites) with stock per warehouse; stock, non-stock and service items; categories, barcodes
--   2. Purchase orders to suppliers, approval, goods received notes (GRN) and three-way match into supplier bills
--   3. Stock issued from a store to a project (and returns), costed and billable to the client
--   4. Stock transfers between warehouses, stocktakes with variances, reorder suggestions, valuation and stock ledger
--   5. Supplier records: terms, bank details, price lists, performance
--   6. Project lifecycle: start, hold, resume, complete, close (with a close-out checklist), reopen, cancel; status history
-- Run after 0006.
-- =====================================================================

-- ---------------------------------------------------------------- 1. Accounts and roles
create or replace function public.seed_accounts_v21(cid uuid)
returns void language sql security definer set search_path = public as $$
  insert into accounts (company_id, code, name, type, system_key) values
  (cid,'2050','Goods received not yet invoiced','liability','grni'),
  (cid,'5150','Purchase price variance','expense','ppv')
  on conflict do nothing;
$$;
select public.seed_accounts_v21(id) from public.companies;

alter table public.memberships drop constraint if exists memberships_role_check;
alter table public.memberships add constraint memberships_role_check
  check (role in ('owner','admin','accountant','sales','hr','project_manager','store','staff'));
create or replace function public.add_member(cid uuid, p_email text, p_role text)
returns void language plpgsql security definer set search_path = public as $$
declare v_user uuid;
begin
  perform require_member(cid, array['owner','admin']);
  if p_role not in ('admin','accountant','sales','hr','project_manager','store','staff') then raise exception 'Choose a valid role'; end if;
  select id into v_user from auth.users where lower(email) = lower(trim(p_email));
  if v_user is null then
    raise exception 'No account uses %. Ask them to sign up first, then add them again.', p_email;
  end if;
  insert into memberships (company_id, user_id, email, role) values (cid, v_user, lower(trim(p_email)), p_role)
  on conflict (company_id, user_id) do update set role = excluded.role;
end $$;
alter table public.approval_rules drop constraint if exists approval_rules_approver_role_check;
alter table public.approval_rules add constraint approval_rules_approver_role_check
  check (approver_role in ('owner','admin','accountant','sales','hr','project_manager','store'));

-- ---------------------------------------------------------------- 2. Warehouses and stock per warehouse
create table public.warehouses (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  code text not null,
  name text not null,
  kind text not null default 'store' check (kind in ('store','site','vehicle','shop')),
  address text,
  branch_id uuid references public.branches(id) on delete set null,
  project_id uuid references public.projects(id) on delete set null,     -- a site store for one project
  is_default boolean not null default false,
  active boolean not null default true,
  unique (company_id, code)
);
create unique index warehouses_one_default on public.warehouses (company_id) where is_default;

create or replace function public.wh(cid uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  select id into v from warehouses where company_id = cid and is_default;
  if v is null then
    insert into warehouses (company_id, code, name, is_default) values (cid, 'MAIN', 'Main store', true)
    on conflict (company_id, code) do update set is_default = true returning id into v;
  end if;
  return v;
end $$;
select public.wh(id) from public.companies;

create table public.stock_levels (
  company_id uuid not null references public.companies(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete cascade,
  warehouse_id uuid not null references public.warehouses(id) on delete cascade,
  qty numeric(14,3) not null default 0,
  bin text,
  primary key (product_id, warehouse_id)
);

alter table public.stock_moves add column if not exists warehouse_id uuid references public.warehouses(id);
alter table public.stock_moves add column if not exists project_id uuid references public.projects(id) on delete set null;
update public.stock_moves m set warehouse_id = public.wh(m.company_id) where warehouse_id is null;
insert into public.stock_levels (company_id, product_id, warehouse_id, qty)
select p.company_id, p.id, public.wh(p.company_id), p.stock_qty from public.products p where p.stock_qty <> 0
on conflict do nothing;
create index if not exists stock_moves_product on public.stock_moves (product_id, move_date);

alter table public.invoices add column if not exists warehouse_id uuid references public.warehouses(id) on delete set null;
alter table public.bills add column if not exists warehouse_id uuid references public.warehouses(id) on delete set null;
alter table public.credit_notes add column if not exists warehouse_id uuid references public.warehouses(id) on delete set null;

create or replace function public.stock_move_warehouse() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if (select item_type from products where id = new.product_id) <> 'stock' then
    raise exception '% is not kept in stock, so it has no stock to move', (select name from products where id = new.product_id);
  end if;
  if new.warehouse_id is null then
    if new.ref_type = 'invoice' then new.warehouse_id := (select warehouse_id from invoices where id = new.ref_id);
    elsif new.ref_type = 'bill' then new.warehouse_id := (select warehouse_id from bills where id = new.ref_id);
    elsif new.ref_type = 'credit_note' then new.warehouse_id := (select warehouse_id from credit_notes where id = new.ref_id);
    end if;
    new.warehouse_id := coalesce(new.warehouse_id, wh(new.company_id));
  end if;
  return new;
end $$;
create trigger stock_moves_warehouse before insert on public.stock_moves for each row execute function public.stock_move_warehouse();

create or replace function public.stock_move_level() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into stock_levels (company_id, product_id, warehouse_id, qty) values (new.company_id, new.product_id, new.warehouse_id, new.qty)
  on conflict (product_id, warehouse_id) do update set qty = stock_levels.qty + excluded.qty;
  return null;
end $$;
create trigger stock_moves_level after insert on public.stock_moves for each row execute function public.stock_move_level();

-- ---------------------------------------------------------------- 3. Items
alter table public.products add column if not exists item_type text not null default 'stock' check (item_type in ('stock','non_stock','service'));
alter table public.products add column if not exists category text;
alter table public.products add column if not exists barcode text;
alter table public.products add column if not exists brand text;
alter table public.products add column if not exists description text;
alter table public.products add column if not exists reorder_qty numeric(14,3) not null default 0;
alter table public.products add column if not exists max_level numeric(14,3);
alter table public.products add column if not exists preferred_supplier_id uuid references public.suppliers(id) on delete set null;
alter table public.products add column if not exists last_purchase_cost numeric(14,4);
alter table public.products add column if not exists expense_account_id uuid references public.accounts(id) on delete set null;   -- for non-stock and service purchases
create unique index if not exists products_barcode on public.products (company_id, barcode) where barcode is not null and barcode <> '';

-- ---------------------------------------------------------------- 4. Suppliers
alter table public.suppliers add column if not exists contact_name text;
alter table public.suppliers add column if not exists category text;
alter table public.suppliers add column if not exists payment_terms_days int not null default 30;
alter table public.suppliers add column if not exists bank_name text;
alter table public.suppliers add column if not exists bank_account text;
alter table public.suppliers add column if not exists momo_number text;
alter table public.suppliers add column if not exists notes text;
alter table public.suppliers add column if not exists active boolean not null default true;

create table public.supplier_items (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  supplier_id uuid not null references public.suppliers(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete cascade,
  supplier_sku text,
  price numeric(14,2) not null default 0,     -- GHS, excluding VAT
  lead_days int,
  min_qty numeric(14,3),
  unique (supplier_id, product_id)
);

-- ---------------------------------------------------------------- 5. Purchase orders, goods received, three-way match
create table public.purchase_orders (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  number text,
  supplier_id uuid not null references public.suppliers(id),
  order_date date not null default current_date,
  expected_date date,
  warehouse_id uuid references public.warehouses(id) on delete set null,
  project_id uuid references public.projects(id) on delete set null,      -- deliver straight to this project
  branch_id uuid references public.branches(id) on delete set null,
  status text not null default 'draft' check (status in ('draft','approved','sent','partial','received','closed','cancelled')),
  notes text,
  terms text,
  created_by uuid default auth.uid(),
  approved_by uuid,
  approved_at timestamptz,
  created_at timestamptz not null default now()
);
create table public.po_lines (
  id uuid primary key default gen_random_uuid(),
  po_id uuid not null references public.purchase_orders(id) on delete cascade,
  company_id uuid not null references public.companies(id) on delete cascade,
  product_id uuid references public.products(id),
  account_id uuid references public.accounts(id),       -- for services or items not kept in stock
  description text not null,
  qty numeric(14,3) not null check (qty > 0),
  unit_cost numeric(14,2) not null default 0 check (unit_cost >= 0),   -- GHS, excluding VAT
  taxable boolean not null default true,
  received_qty numeric(14,3) not null default 0,
  billed_qty numeric(14,3) not null default 0,
  project_id uuid references public.projects(id) on delete set null,
  request_id uuid references public.project_requests(id) on delete set null,
  sort int not null default 0
);
create index on public.po_lines (po_id);
create index on public.po_lines (project_id) where project_id is not null;
alter table public.bill_lines add column if not exists po_line_id uuid references public.po_lines(id) on delete set null;
alter table public.bill_lines add column if not exists billable boolean not null default false;
alter table public.bill_lines add column if not exists invoice_id uuid references public.invoices(id) on delete set null;

create table public.goods_receipts (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  number text not null,
  po_id uuid not null references public.purchase_orders(id),
  supplier_id uuid not null references public.suppliers(id),
  receipt_date date not null,
  warehouse_id uuid references public.warehouses(id),
  reference text,            -- supplier's delivery note / waybill
  notes text,
  received_by uuid default auth.uid(),
  journal_entry_id uuid references public.journal_entries(id),
  created_at timestamptz not null default now()
);
create table public.goods_receipt_lines (
  id uuid primary key default gen_random_uuid(),
  receipt_id uuid not null references public.goods_receipts(id) on delete cascade,
  company_id uuid not null references public.companies(id) on delete cascade,
  po_line_id uuid not null references public.po_lines(id),
  product_id uuid references public.products(id),
  qty numeric(14,3) not null,
  unit_cost numeric(14,2) not null,
  project_id uuid references public.projects(id) on delete set null
);

alter table public.project_requests drop constraint if exists project_requests_status_check;
alter table public.project_requests add constraint project_requests_status_check
  check (status in ('draft','submitted','approved','rejected','ordered','billed','cancelled'));
create or replace function public.project_request_defaults() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    new.company_id := (select company_id from projects where id = new.project_id);
    if new.number is null then new.number := next_number(new.company_id, 'PR', 'PR-'); end if;
    new.requested_by := coalesce(auth.uid(), new.requested_by);
    new.requested_email := (select email from auth.users where id = new.requested_by);
    if new.status not in ('draft','submitted') then raise exception 'New requests start as draft or submitted'; end if;
  elsif new.status is distinct from old.status and new.status in ('approved','rejected','billed','ordered')
        and coalesce(current_setting('sika.requests', true), '') <> 'on' then
    raise exception 'Use Approve or Reject to decide a request';
  end if;
  if tg_op = 'UPDATE' and old.status in ('approved','billed','ordered') and coalesce(current_setting('sika.requests', true), '') <> 'on'
     and (new.qty, new.est_unit_cost, new.project_id) is distinct from (old.qty, old.est_unit_cost, old.project_id) then
    raise exception 'An approved request cannot be changed. Cancel it and raise a new one.';
  end if;
  return new;
end $$;

create or replace function public.po_defaults() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    if new.number is null then new.number := next_number(new.company_id, 'PO', 'PO-'); end if;
    if new.status <> 'draft' then raise exception 'A new purchase order starts as a draft'; end if;
    new.warehouse_id := coalesce(new.warehouse_id, case when new.project_id is null then wh(new.company_id) end);
  elsif new.status is distinct from old.status and coalesce(current_setting('sika.po', true), '') <> 'on' then
    raise exception 'Use Approve, Receive, Close or Cancel to change a purchase order';
  end if;
  return new;
end $$;
create trigger purchase_orders_defaults before insert or update on public.purchase_orders for each row execute function public.po_defaults();

create or replace function public.po_line_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare st text;
begin
  select status into st from purchase_orders where id = coalesce(new.po_id, old.po_id);
  if st <> 'draft' and coalesce(current_setting('sika.po', true), '') <> 'on' then raise exception 'Only a draft purchase order can be changed'; end if;
  if tg_op <> 'DELETE' and new.product_id is null and new.account_id is null and new.project_id is null then
    raise exception 'Each line needs an item, an expense account or a project';
  end if;
  return coalesce(new, old);
end $$;
create trigger po_lines_guard before insert or update or delete on public.po_lines for each row execute function public.po_line_guard();

create or replace function public.po_total(p uuid) returns numeric language sql stable as $$
  select coalesce(round(sum(qty * unit_cost), 2), 0) from po_lines where po_id = p;
$$;

-- Approval chains cover purchase orders too.
alter table public.approval_rules drop constraint if exists approval_rules_doc_type_check;
alter table public.approval_rules add constraint approval_rules_doc_type_check
  check (doc_type in ('bill','payroll','purchase_request','expense_claim','purchase_order'));
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
  elsif p_type = 'purchase_order' then
    select o.company_id, po_total(o.id), o.number || ' · ' || s.name, '/purchase-orders/' || o.id
      into company_id, amount, label, path from purchase_orders o join suppliers s on s.id = o.supplier_id where o.id = p_id;
  end if;
end $$;

create or replace function public.approve_po(p_po uuid) returns void
language plpgsql security definer set search_path = public as $$
declare o purchase_orders; st text;
begin
  select * into o from purchase_orders where id = p_po for update;
  if not found then raise exception 'Purchase order not found'; end if;
  perform require_member(o.company_id, array['owner','admin','accountant']);
  if o.status <> 'draft' then raise exception '% is already %', o.number, o.status; end if;
  if not exists (select 1 from po_lines where po_id = p_po) then raise exception 'Add at least one line'; end if;
  st := approval_state('purchase_order', p_po);
  if st in ('not_started','pending','rejected','changed') then
    raise exception '% needs approval first (%). Submit it for approval.', o.number,
      case st when 'not_started' then 'not submitted yet' when 'pending' then 'still waiting' when 'rejected' then 'it was rejected' else 'the amount went up after approval' end;
  end if;
  perform set_config('sika.po','on', true);
  update purchase_orders set status = 'approved', approved_by = auth.uid(), approved_at = now() where id = p_po;
  perform set_config('sika.po','off', true);
end $$;

create or replace function public.set_po_status(p_po uuid, p_status text) returns void
language plpgsql security definer set search_path = public as $$
declare o purchase_orders;
begin
  select * into o from purchase_orders where id = p_po for update;
  if not found then raise exception 'Purchase order not found'; end if;
  perform require_member(o.company_id, array['owner','admin','accountant','store']);
  if p_status = 'sent' and o.status <> 'approved' then raise exception 'Approve the order before sending it';
  elsif p_status = 'cancelled' then
    if exists (select 1 from po_lines where po_id = p_po and (received_qty > 0 or billed_qty > 0)) then raise exception 'Goods were received or billed on this order. Close it instead.'; end if;
    perform set_config('sika.requests','on', true);
    update project_requests set status = 'approved' where id in (select request_id from po_lines where po_id = p_po) and status = 'ordered';
    perform set_config('sika.requests','off', true);
  elsif p_status = 'closed' and o.status not in ('partial','received','sent','approved') then raise exception 'Only an open order can be closed';
  elsif p_status not in ('sent','cancelled','closed') then raise exception 'Unknown status';
  end if;
  perform set_config('sika.po','on', true);
  update purchase_orders set status = p_status where id = p_po;
  perform set_config('sika.po','off', true);
end $$;

-- One purchase order from approved project purchase requests.
create or replace function public.po_from_requests(p_ids uuid[], p_supplier uuid, p_expected date default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare cid uuid; v_po uuid; r record; i int := 0; v_proj uuid;
begin
  select company_id into cid from project_requests where id = any(p_ids) limit 1;
  if cid is null then raise exception 'Choose at least one request'; end if;
  perform require_member(cid, array['owner','admin','accountant','store']);
  if exists (select 1 from project_requests where id = any(p_ids) and (company_id <> cid or status <> 'approved')) then
    raise exception 'Only approved requests can go on a purchase order';
  end if;
  select case when count(distinct project_id) = 1 then min(project_id::text)::uuid end into v_proj from project_requests where id = any(p_ids);
  insert into purchase_orders (company_id, supplier_id, expected_date, project_id, notes)
  values (cid, p_supplier, p_expected, v_proj, 'From purchase requests ' || (select string_agg(number, ', ' order by number) from project_requests where id = any(p_ids)))
  returning id into v_po;
  for r in select * from project_requests where id = any(p_ids) order by number loop
    insert into po_lines (po_id, company_id, product_id, account_id, description, qty, unit_cost, project_id, request_id, sort)
    values (v_po, cid, case when r.kind = 'material' then r.product_id end,
      case when r.kind = 'material' and r.product_id is not null then null
           else coalesce(case when r.kind = 'other' then r.account_id end,
                         acct(cid, case r.kind when 'material' then 'project_materials' when 'subcontract' then 'subcontract' when 'equipment' then 'equipment_hire' else 'expense' end)) end,
      r.number || ' — ' || r.description, r.qty, r.est_unit_cost, r.project_id, r.id, i);
    i := i + 1;
  end loop;
  perform set_config('sika.requests','on', true);
  update project_requests set status = 'ordered', supplier_id = coalesce(supplier_id, p_supplier) where id = any(p_ids);
  perform set_config('sika.requests','off', true);
  return v_po;
end $$;

-- Goods received note: stock into the store (or straight to the project), accrued against 2050 until the supplier's bill arrives.
create or replace function public.receive_po(p_po uuid, p_lines jsonb, p_date date default current_date, p_warehouse uuid default null, p_reference text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare o purchase_orders; l record; pl po_lines; pr products; v_grn uuid; v_wh uuid; v_lines jsonb := '[]'::jsonb; v_total numeric := 0; v_amt numeric; v_acct uuid; v_je uuid; n int := 0;
begin
  select * into o from purchase_orders where id = p_po for update;
  if not found then raise exception 'Purchase order not found'; end if;
  perform require_member(o.company_id, array['owner','admin','accountant','store']);
  if o.status not in ('approved','sent','partial') then raise exception 'Only an approved, open order can be received (this one is %)', o.status; end if;
  v_wh := coalesce(p_warehouse, o.warehouse_id, wh(o.company_id));
  if not exists (select 1 from warehouses where id = v_wh and company_id = o.company_id) then raise exception 'Choose one of your warehouses'; end if;
  insert into goods_receipts (company_id, number, po_id, supplier_id, receipt_date, warehouse_id, reference)
  values (o.company_id, next_number(o.company_id, 'GRN', 'GRN-'), p_po, o.supplier_id, p_date, v_wh, p_reference) returning id into v_grn;
  perform set_config('sika.posting','on', true);
  perform set_config('sika.po','on', true);
  for l in select (x->>'line_id')::uuid line_id, round((x->>'qty')::numeric, 3) qty from jsonb_array_elements(p_lines) x loop
    continue when coalesce(l.qty, 0) = 0;
    select * into pl from po_lines where id = l.line_id and po_id = p_po for update;
    if not found then raise exception 'A line is not on this order'; end if;
    if l.qty < 0 or l.qty > pl.qty - pl.received_qty + 0.0005 then
      raise exception 'You can receive at most % of "%"', pl.qty - pl.received_qty, pl.description;
    end if;
    v_amt := round(l.qty * pl.unit_cost, 2);
    pr := null;
    if pl.product_id is not null then select * into pr from products where id = pl.product_id for update; end if;
    if pl.project_id is null and pr.id is not null and pr.item_type = 'stock' then
      update products set cost = round((greatest(stock_qty,0) * cost + l.qty * pl.unit_cost) / nullif(greatest(stock_qty,0) + l.qty, 0), 4),
                          stock_qty = stock_qty + l.qty, last_purchase_cost = pl.unit_cost where id = pr.id;
      insert into stock_moves (company_id, product_id, warehouse_id, move_date, qty, unit_cost, reason, ref_type, ref_id)
      values (o.company_id, pr.id, v_wh, p_date, l.qty, pl.unit_cost, 'Received ' || o.number, 'receipt', v_grn);
      v_acct := acct(o.company_id, 'inventory');
    else
      if pr.id is not null then update products set last_purchase_cost = pl.unit_cost where id = pr.id; end if;
      v_acct := coalesce(pl.account_id, pr.expense_account_id,
                         case when pl.project_id is not null then acct(o.company_id, 'project_materials') else acct(o.company_id, 'expense') end);
    end if;
    insert into goods_receipt_lines (receipt_id, company_id, po_line_id, product_id, qty, unit_cost, project_id)
    values (v_grn, o.company_id, pl.id, pl.product_id, l.qty, pl.unit_cost, pl.project_id);
    update po_lines set received_qty = received_qty + l.qty where id = pl.id;
    v_lines := v_lines || (jl(v_acct, v_amt, 0) || jsonb_build_object('project_id', pl.project_id, 'branch_id', o.branch_id));
    v_total := v_total + v_amt; n := n + 1;
  end loop;
  perform set_config('sika.posting','off', true);
  if n = 0 then raise exception 'Enter the quantity received on at least one line'; end if;
  if v_total > 0 then
    v_je := post_journal(o.company_id, p_date, 'Goods received on ' || o.number || coalesce(' (delivery note ' || p_reference || ')', ''),
      v_lines || jl(acct(o.company_id, 'grni'), 0, v_total), 'receipt', v_grn);
    update goods_receipts set journal_entry_id = v_je where id = v_grn;
  end if;
  update purchase_orders set status = case when exists (select 1 from po_lines where po_id = p_po and received_qty < qty) then 'partial' else 'received' end where id = p_po;
  perform set_config('sika.po','off', true);
  return v_grn;
end $$;

-- Draft supplier bill for what was received (or ordered) and not yet billed. The accountant checks prices against the supplier's invoice and posts.
create or replace function public.bill_from_po(p_po uuid, p_ref text default null, p_date date default current_date, p_all boolean default false)
returns uuid language plpgsql security definer set search_path = public as $$
declare o purchase_orders; v_bill uuid; l record; i int := 0; q numeric;
begin
  select * into o from purchase_orders where id = p_po;
  if not found then raise exception 'Purchase order not found'; end if;
  perform require_member(o.company_id, array['owner','admin','accountant']);
  if o.status in ('draft','cancelled') then raise exception 'Approve the order first'; end if;
  insert into bills (company_id, supplier_id, supplier_ref, bill_date, warehouse_id, branch_id, currency, exchange_rate, notes)
  values (o.company_id, o.supplier_id, p_ref, p_date, o.warehouse_id, o.branch_id, 'GHS', 1, 'Purchase order ' || o.number) returning id into v_bill;
  for l in select * from po_lines where po_id = p_po order by sort loop
    q := case when p_all then l.qty - l.billed_qty else l.received_qty - l.billed_qty end;
    continue when q <= 0;
    insert into bill_lines (bill_id, company_id, product_id, account_id, description, qty, unit_cost, taxable, sort, project_id, request_id, po_line_id)
    values (v_bill, o.company_id, l.product_id, case when l.product_id is null then coalesce(l.account_id, acct(o.company_id, case when l.project_id is not null then 'project_materials' else 'expense' end)) end, l.description, q, l.unit_cost, l.taxable, i, l.project_id, l.request_id, l.id);
    i := i + 1;
  end loop;
  if i = 0 then delete from bills where id = v_bill; raise exception 'Nothing on this order is waiting to be billed. Receive the goods first.'; end if;
  return v_bill;
end $$;

-- Supplier bills: stock and non-stock items, purchase-order matching (GRNI and price variance), projects and cost centres.
create or replace function public.post_bill(p_bill uuid)
returns text language plpgsql security definer set search_path = public as $$
declare
  b bills; l record; pr products; pl po_lines; v_lines jsonb := '[]'::jsonb; x numeric; v_dims jsonb;
  v_taxable numeric := 0; v_sub numeric := 0; v_amt numeric; g_amt numeric; g_sum numeric := 0; v_q numeric; v_r numeric; v_grni numeric; v_part numeric;
  v_vat numeric; v_nhil numeric; v_getf numeric; v_total numeric; v_je uuid; v_no text; v_wh uuid;
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
  x := b.exchange_rate; v_wh := coalesce(b.warehouse_id, wh(b.company_id));

  perform set_config('sika.posting','on', true);
  perform set_config('sika.po','on', true);
  for l in select * from bill_lines where bill_id = p_bill order by sort loop
    v_amt := round(l.qty * l.unit_cost, 2);
    g_amt := round(v_amt * x, 2);
    v_sub := v_sub + v_amt; g_sum := g_sum + g_amt;
    if l.taxable then v_taxable := v_taxable + v_amt; end if;
    v_dims := jsonb_build_object('project_id', l.project_id, 'cost_centre_id', l.cost_centre_id);
    pr := null;
    if l.product_id is not null then select * into pr from products where id = l.product_id for update; end if;
    v_q := 0;
    if l.po_line_id is not null then
      select * into pl from po_lines where id = l.po_line_id for update;
      v_q := least(l.qty, greatest(pl.received_qty - pl.billed_qty, 0));
      if v_q > 0 then   -- already received: clear the accrual, price difference to 5150
        v_grni := round(v_q * pl.unit_cost, 2);
        v_part := round(g_amt * v_q / l.qty, 2);
        v_lines := v_lines || jl(acct(b.company_id,'grni'), v_grni, 0)
                           || (jl(acct(b.company_id,'ppv'), greatest(v_part - v_grni, 0), greatest(v_grni - v_part, 0)) || v_dims);
      end if;
      update po_lines set billed_qty = billed_qty + l.qty, received_qty = greatest(received_qty, billed_qty + l.qty) where id = pl.id;
    end if;
    v_r := l.qty - v_q;                                  -- not received through a GRN: posts as before
    if v_r > 0 then
      v_part := g_amt - case when v_q > 0 then round(g_amt * v_q / l.qty, 2) else 0 end;
      if pr.id is not null and pr.item_type = 'stock' and l.project_id is null then
        update products set
          cost = round((greatest(stock_qty,0) * cost + v_part) / nullif(greatest(stock_qty,0) + v_r, 0), 4),
          stock_qty = stock_qty + v_r, last_purchase_cost = round(v_part / v_r, 4)
         where id = pr.id;
        insert into stock_moves (company_id, product_id, warehouse_id, move_date, qty, unit_cost, reason, ref_type, ref_id)
        values (b.company_id, pr.id, v_wh, b.bill_date, v_r, round(v_part / v_r, 4), 'Goods received', 'bill', b.id);
        v_lines := v_lines || (jl(acct(b.company_id,'inventory'), v_part, 0) || v_dims);
      else
        v_lines := v_lines || (jl(coalesce(l.account_id, pr.expense_account_id,
                     case when l.project_id is not null then acct(b.company_id,'project_materials') else acct(b.company_id,'expense') end), v_part, 0) || v_dims);
      end if;
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
  perform set_config('sika.requests','on', true);
  update project_requests set status = 'billed' where id in (select request_id from bill_lines where bill_id = p_bill and request_id is not null) and status = 'ordered';
  perform set_config('sika.requests','off', true);
  update purchase_orders o set status = 'received'
   where o.id in (select pl2.po_id from bill_lines l2 join po_lines pl2 on pl2.id = l2.po_line_id where l2.bill_id = p_bill)
     and o.status in ('approved','sent','partial') and not exists (select 1 from po_lines z where z.po_id = o.id and z.received_qty < z.qty);
  perform set_config('sika.po','off', true);
  return v_no;
end $$;

-- Sales invoices: service and non-stock items do not touch stock; stock comes out of the invoice's warehouse.
create or replace function public.post_invoice(p_invoice uuid)
returns text language plpgsql security definer set search_path = public as $$
declare
  inv invoices; l record; p products; x numeric; v_wh uuid; v_have numeric;
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
  x := inv.exchange_rate; v_wh := coalesce(inv.warehouse_id, wh(inv.company_id));

  perform set_config('sika.posting','on', true);
  for l in select * from invoice_lines where invoice_id = p_invoice order by sort loop
    v_sub := v_sub + round(l.qty * l.unit_price, 2);
    if l.taxable then v_taxable := v_taxable + round(l.qty * l.unit_price, 2); end if;
    p := null;
    if l.product_id is not null then select * into p from products where id = l.product_id for update; end if;
    if p.id is not null and p.item_type = 'stock' then
      select coalesce(sum(qty), 0) into v_have from stock_levels where product_id = p.id and warehouse_id = v_wh;
      if v_have < l.qty then
        raise exception 'Only % % of % in stock at %', v_have, p.unit, p.name, (select name from warehouses where id = v_wh);
      end if;
      update products set stock_qty = stock_qty - l.qty where id = p.id;
      insert into stock_moves (company_id, product_id, warehouse_id, move_date, qty, unit_cost, reason, ref_type, ref_id)
      values (inv.company_id, p.id, v_wh, inv.invoice_date, -l.qty, p.cost, 'Sale', 'invoice', inv.id);
      v_cogs := v_cogs + round(l.qty * p.cost, 2);
      v_goods := v_goods + round(l.qty * l.unit_price, 2);
    elsif p.id is not null and p.item_type = 'non_stock' then
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

-- ---------------------------------------------------------------- 6. Stock issued to projects (and returned)
create table public.stock_issues (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  number text,
  kind text not null default 'issue' check (kind in ('issue','return')),
  warehouse_id uuid not null references public.warehouses(id),
  project_id uuid references public.projects(id) on delete set null,
  cost_centre_id uuid references public.cost_centres(id) on delete set null,
  account_id uuid references public.accounts(id),       -- for internal use without a project (default 6900)
  issue_date date not null default current_date,
  issued_to text,                                       -- person or site collecting
  notes text,
  status text not null default 'draft' check (status in ('draft','posted')),
  journal_entry_id uuid references public.journal_entries(id),
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);
create table public.stock_issue_lines (
  id uuid primary key default gen_random_uuid(),
  issue_id uuid not null references public.stock_issues(id) on delete cascade,
  company_id uuid not null references public.companies(id) on delete cascade,
  product_id uuid not null references public.products(id),
  qty numeric(14,3) not null check (qty > 0),
  unit_cost numeric(14,4),                              -- average cost when posted
  billable boolean not null default false,
  bill_price numeric(14,2),                             -- price to the client (project currency), default the selling price
  invoice_id uuid references public.invoices(id) on delete set null,
  sort int not null default 0
);
create index on public.stock_issue_lines (issue_id);

create or replace function public.stock_issue_defaults() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' and new.number is null then
    new.number := next_number(new.company_id, case when new.kind = 'return' then 'RET' else 'ISS' end, case when new.kind = 'return' then 'RET-' else 'ISS-' end);
  end if;
  if tg_op = 'INSERT' and new.status <> 'draft' then raise exception 'A new stock issue starts as a draft'; end if;
  if tg_op = 'UPDATE' and old.status = 'posted' and coalesce(current_setting('sika.posting', true), '') <> 'on' then raise exception 'A posted stock issue cannot be changed'; end if;
  return new;
end $$;
create trigger stock_issues_defaults before insert or update on public.stock_issues for each row execute function public.stock_issue_defaults();
create or replace function public.stock_issue_line_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if (select status from stock_issues where id = coalesce(new.issue_id, old.issue_id)) = 'posted'
     and coalesce(current_setting('sika.posting', true), '') <> 'on' then raise exception 'A posted stock issue cannot be changed'; end if;
  return coalesce(new, old);
end $$;
create trigger stock_issue_lines_guard before insert or update or delete on public.stock_issue_lines for each row execute function public.stock_issue_line_guard();

create or replace function public.post_stock_issue(p_id uuid) returns text
language plpgsql security definer set search_path = public as $$
declare s stock_issues; l record; p products; v_have numeric; v_val numeric := 0; v_amt numeric; v_target uuid; v_sign int; v_je uuid;
begin
  select * into s from stock_issues where id = p_id for update;
  if not found then raise exception 'Stock issue not found'; end if;
  if not (has_role(s.company_id, array['owner','admin','accountant','store']) or (s.project_id is not null and can_manage_project(s.project_id))) then
    raise exception 'Only the store, an accountant or the project''s manager can post this';
  end if;
  if s.status <> 'draft' then raise exception '% is already posted', s.number; end if;
  if not exists (select 1 from stock_issue_lines where issue_id = p_id) then raise exception 'Add at least one item'; end if;
  if s.project_id is not null and (select status from projects where id = s.project_id) in ('closed','cancelled') then raise exception 'This project is closed'; end if;
  v_sign := case when s.kind = 'issue' then -1 else 1 end;
  v_target := coalesce(s.account_id, case when s.project_id is not null then acct(s.company_id, 'project_materials') else acct(s.company_id, 'expense') end);
  perform set_config('sika.posting','on', true);
  for l in select * from stock_issue_lines where issue_id = p_id order by sort loop
    select * into p from products where id = l.product_id for update;
    if p.item_type <> 'stock' then raise exception '% is not a stock item', p.name; end if;
    if s.kind = 'issue' then
      select coalesce(sum(qty), 0) into v_have from stock_levels where product_id = p.id and warehouse_id = s.warehouse_id;
      if v_have < l.qty then raise exception 'Only % % of % in stock at %', v_have, p.unit, p.name, (select name from warehouses where id = s.warehouse_id); end if;
    end if;
    v_amt := round(l.qty * p.cost, 2);
    update products set stock_qty = stock_qty + v_sign * l.qty where id = p.id;
    insert into stock_moves (company_id, product_id, warehouse_id, move_date, qty, unit_cost, reason, ref_type, ref_id, project_id)
    values (s.company_id, p.id, s.warehouse_id, s.issue_date, v_sign * l.qty, p.cost,
            case when s.kind = 'issue' then 'Issued ' else 'Returned ' end || s.number, 'stock_issue', s.id, s.project_id);
    update stock_issue_lines set unit_cost = p.cost, bill_price = coalesce(bill_price, p.price) where id = l.id;
    v_val := v_val + v_amt;
  end loop;
  update stock_issues set status = 'posted' where id = p_id;
  if v_val > 0 then
    v_je := post_journal(s.company_id, s.issue_date,
      case when s.kind = 'issue' then 'Stock issued ' else 'Stock returned ' end || s.number || coalesce(' — ' || (select coalesce(number || ' ', '') || name from projects where id = s.project_id), ''),
      case when s.kind = 'issue'
        then jsonb_build_array(jl(v_target, v_val, 0) || jsonb_build_object('project_id', s.project_id, 'cost_centre_id', s.cost_centre_id), jl(acct(s.company_id,'inventory'), 0, v_val))
        else jsonb_build_array(jl(acct(s.company_id,'inventory'), v_val, 0), jl(v_target, 0, v_val) || jsonb_build_object('project_id', s.project_id, 'cost_centre_id', s.cost_centre_id)) end,
      'stock_issue', s.id);
    update stock_issues set journal_entry_id = v_je where id = p_id;
  end if;
  perform set_config('sika.posting','off', true);
  return s.number;
end $$;

-- ---------------------------------------------------------------- 7. Transfers between warehouses
create table public.stock_transfers (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  number text,
  from_warehouse_id uuid not null references public.warehouses(id),
  to_warehouse_id uuid not null references public.warehouses(id),
  transfer_date date not null default current_date,
  notes text,
  status text not null default 'draft' check (status in ('draft','posted')),
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  check (from_warehouse_id <> to_warehouse_id)
);
create table public.stock_transfer_lines (
  id uuid primary key default gen_random_uuid(),
  transfer_id uuid not null references public.stock_transfers(id) on delete cascade,
  company_id uuid not null references public.companies(id) on delete cascade,
  product_id uuid not null references public.products(id),
  qty numeric(14,3) not null check (qty > 0)
);
create or replace function public.transfer_defaults() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then new.number := coalesce(new.number, next_number(new.company_id, 'TRF', 'TRF-')); new.status := 'draft';
  elsif old.status = 'posted' and coalesce(current_setting('sika.posting', true), '') <> 'on' then raise exception 'A posted transfer cannot be changed'; end if;
  return new;
end $$;
create trigger stock_transfers_defaults before insert or update on public.stock_transfers for each row execute function public.transfer_defaults();

create or replace function public.post_transfer(p_id uuid) returns text
language plpgsql security definer set search_path = public as $$
declare t stock_transfers; l record; p products; v_have numeric;
begin
  select * into t from stock_transfers where id = p_id for update;
  if not found then raise exception 'Transfer not found'; end if;
  perform require_member(t.company_id, array['owner','admin','accountant','store']);
  if t.status <> 'draft' then raise exception '% is already posted', t.number; end if;
  if not exists (select 1 from stock_transfer_lines where transfer_id = p_id) then raise exception 'Add at least one item'; end if;
  for l in select * from stock_transfer_lines where transfer_id = p_id loop
    select * into p from products where id = l.product_id;
    select coalesce(sum(qty), 0) into v_have from stock_levels where product_id = p.id and warehouse_id = t.from_warehouse_id;
    if v_have < l.qty then raise exception 'Only % % of % in stock at %', v_have, p.unit, p.name, (select name from warehouses where id = t.from_warehouse_id); end if;
    insert into stock_moves (company_id, product_id, warehouse_id, move_date, qty, unit_cost, reason, ref_type, ref_id)
    values (t.company_id, p.id, t.from_warehouse_id, t.transfer_date, -l.qty, p.cost, 'Transfer out ' || t.number, 'transfer', t.id),
           (t.company_id, p.id, t.to_warehouse_id, t.transfer_date, l.qty, p.cost, 'Transfer in ' || t.number, 'transfer', t.id);
  end loop;
  perform set_config('sika.posting','on', true);
  update stock_transfers set status = 'posted' where id = p_id;
  perform set_config('sika.posting','off', true);
  return t.number;
end $$;

-- ---------------------------------------------------------------- 8. Stocktakes
create table public.stock_counts (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  number text,
  warehouse_id uuid not null references public.warehouses(id),
  count_date date not null default current_date,
  notes text,
  status text not null default 'draft' check (status in ('draft','posted')),
  journal_entry_id uuid references public.journal_entries(id),
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);
create table public.stock_count_lines (
  id uuid primary key default gen_random_uuid(),
  count_id uuid not null references public.stock_counts(id) on delete cascade,
  company_id uuid not null references public.companies(id) on delete cascade,
  product_id uuid not null references public.products(id),
  system_qty numeric(14,3) not null,
  counted_qty numeric(14,3),
  unit_cost numeric(14,4),
  unique (count_id, product_id)
);

create or replace function public.start_stock_count(cid uuid, p_warehouse uuid, p_date date default current_date, p_category text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  perform require_member(cid, array['owner','admin','accountant','store']);
  if not exists (select 1 from warehouses where id = p_warehouse and company_id = cid) then raise exception 'Choose one of your warehouses'; end if;
  insert into stock_counts (company_id, number, warehouse_id, count_date, notes)
  values (cid, next_number(cid, 'CNT', 'CNT-'), p_warehouse, p_date, case when p_category is not null then 'Category: ' || p_category end) returning id into v;
  insert into stock_count_lines (count_id, company_id, product_id, system_qty)
  select v, cid, p.id, coalesce(sl.qty, 0) from products p left join stock_levels sl on sl.product_id = p.id and sl.warehouse_id = p_warehouse
   where p.company_id = cid and p.item_type = 'stock' and p.active and (p_category is null or p.category = p_category)
   order by p.name;
  return v;
end $$;

-- Post the count: every difference adjusts stock at average cost (Dr/Cr 5100 Stock adjustments).
create or replace function public.post_stock_count(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c stock_counts; l record; p products; v_now numeric; v_diff numeric; v_gain numeric := 0; v_loss numeric := 0; n int := 0; v_je uuid;
begin
  select * into c from stock_counts where id = p_id for update;
  if not found then raise exception 'Stock count not found'; end if;
  perform require_member(c.company_id, array['owner','admin','accountant']);
  if c.status <> 'draft' then raise exception '% is already posted', c.number; end if;
  if exists (select 1 from stock_count_lines where count_id = p_id and counted_qty is null) then
    raise exception 'Enter a counted quantity on every line (enter 0 for none found), or remove lines you did not count';
  end if;
  perform set_config('sika.posting','on', true);
  for l in select * from stock_count_lines where count_id = p_id loop
    select * into p from products where id = l.product_id for update;
    select coalesce(sum(qty), 0) into v_now from stock_levels where product_id = p.id and warehouse_id = c.warehouse_id;
    v_diff := l.counted_qty - v_now;
    update stock_count_lines set unit_cost = p.cost where id = l.id;
    continue when v_diff = 0;
    update products set stock_qty = stock_qty + v_diff where id = p.id;
    insert into stock_moves (company_id, product_id, warehouse_id, move_date, qty, unit_cost, reason, ref_type, ref_id)
    values (c.company_id, p.id, c.warehouse_id, c.count_date, v_diff, p.cost, 'Stocktake ' || c.number, 'stock_count', c.id);
    if v_diff > 0 then v_gain := v_gain + round(v_diff * p.cost, 2); else v_loss := v_loss + round(-v_diff * p.cost, 2); end if;
    n := n + 1;
  end loop;
  update stock_counts set status = 'posted' where id = p_id;
  if v_gain + v_loss > 0 then
    v_je := post_journal(c.company_id, c.count_date, 'Stocktake ' || c.number || ' at ' || (select name from warehouses where id = c.warehouse_id),
      jsonb_build_array(jl(acct(c.company_id,'inventory'), v_gain, v_loss), jl(acct(c.company_id,'stock_adj'), v_loss, v_gain)), 'stock_count', c.id);
    update stock_counts set journal_entry_id = v_je where id = p_id;
  end if;
  perform set_config('sika.posting','off', true);
  return jsonb_build_object('lines_adjusted', n, 'gain', v_gain, 'loss', v_loss);
end $$;

-- Stock tables are changed only by posting functions.
create or replace function public.stock_doc_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare st text;
begin
  if tg_table_name = 'stock_transfer_lines' then select status into st from stock_transfers where id = coalesce(new.transfer_id, old.transfer_id);
  else select status into st from stock_counts where id = coalesce(new.count_id, old.count_id); end if;
  if st = 'posted' and coalesce(current_setting('sika.posting', true), '') <> 'on' then raise exception 'This document is posted and cannot be changed'; end if;
  return coalesce(new, old);
end $$;
create trigger stock_transfer_lines_guard before insert or update or delete on public.stock_transfer_lines for each row execute function public.stock_doc_guard();
create trigger stock_count_lines_guard before insert or update or delete on public.stock_count_lines for each row execute function public.stock_doc_guard();
create or replace function public.stock_count_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'UPDATE' and old.status = 'posted' and coalesce(current_setting('sika.posting', true), '') <> 'on' then raise exception 'A posted stocktake cannot be changed'; end if;
  return new;
end $$;
create trigger stock_counts_guard before update on public.stock_counts for each row execute function public.stock_count_guard();

-- ---------------------------------------------------------------- 9. Reports
create or replace function public.stock_valuation(cid uuid, p_warehouse uuid default null)
returns table (product_id uuid, sku text, name text, category text, unit text, qty numeric, cost numeric, value numeric,
               reorder_level numeric, on_order numeric, last_move date)
language sql stable security definer set search_path = public as $$
  select p.id, p.sku, p.name, p.category, p.unit,
         case when p_warehouse is null then p.stock_qty else coalesce((select qty from stock_levels where product_id = p.id and warehouse_id = p_warehouse), 0) end,
         p.cost,
         round(p.cost * case when p_warehouse is null then p.stock_qty else coalesce((select qty from stock_levels where product_id = p.id and warehouse_id = p_warehouse), 0) end, 2),
         p.reorder_level,
         coalesce((select sum(l.qty - l.received_qty) from po_lines l join purchase_orders o on o.id = l.po_id
                    where l.product_id = p.id and o.status in ('approved','sent','partial') and l.project_id is null), 0),
         (select max(move_date) from stock_moves m where m.product_id = p.id and (p_warehouse is null or m.warehouse_id = p_warehouse))
    from products p
   where p.company_id = cid and p.item_type = 'stock' and is_member(cid)
   order by p.name;
$$;

create or replace function public.stock_ledger(cid uuid, p_product uuid, p_from date, p_to date, p_warehouse uuid default null)
returns table (move_id uuid, move_date date, warehouse text, reason text, ref_type text, ref_id uuid, project text, qty_in numeric, qty_out numeric,
               balance numeric, unit_cost numeric, value numeric, opening numeric)
language sql stable security definer set search_path = public as $$
  with f as (select m.* from stock_moves m where m.company_id = cid and m.product_id = p_product and is_member(cid)
               and (p_warehouse is null or m.warehouse_id = p_warehouse)),
  op as (select coalesce(sum(qty), 0) v from f where move_date < p_from),
  r as (select f.*, (select v from op) + sum(f.qty) over (order by f.move_date, f.created_at, f.id) bal from f where f.move_date between p_from and p_to)
  select r.id, r.move_date, w.code, r.reason, r.ref_type, r.ref_id, pj.number,
         case when r.qty > 0 then r.qty end, case when r.qty < 0 then -r.qty end, r.bal, r.unit_cost, round(r.qty * r.unit_cost, 2), (select v from op)
    from r left join warehouses w on w.id = r.warehouse_id left join projects pj on pj.id = r.project_id
   order by r.move_date, r.created_at, r.id;
$$;

-- What to order: items at or below their reorder level, less what is already on order.
create or replace function public.reorder_suggestions(cid uuid, p_warehouse uuid default null)
returns table (product_id uuid, sku text, name text, unit text, on_hand numeric, on_order numeric, reorder_level numeric, suggested numeric,
               supplier_id uuid, supplier text, unit_cost numeric)
language sql stable security definer set search_path = public as $$
  select * from (
    select p.id, p.sku, p.name, p.unit,
      case when p_warehouse is null then p.stock_qty else coalesce((select qty from stock_levels where product_id = p.id and warehouse_id = p_warehouse), 0) end oh,
      coalesce((select sum(l.qty - l.received_qty) from po_lines l join purchase_orders o on o.id = l.po_id
                 where l.product_id = p.id and o.status in ('draft','approved','sent','partial') and l.project_id is null
                   and (p_warehouse is null or o.warehouse_id = p_warehouse)), 0) oo,
      p.reorder_level,
      greatest(coalesce(nullif(p.reorder_qty, 0), coalesce(p.max_level, p.reorder_level * 2) - p.stock_qty), 1) sug,
      coalesce(p.preferred_supplier_id, (select si.supplier_id from supplier_items si where si.product_id = p.id order by si.price limit 1)) sup,
      null::text, coalesce((select si.price from supplier_items si where si.product_id = p.id and si.supplier_id = p.preferred_supplier_id),
                           (select min(si.price) from supplier_items si where si.product_id = p.id), p.last_purchase_cost, p.cost)
      from products p where p.company_id = cid and p.item_type = 'stock' and p.active and p.reorder_level > 0 and is_member(cid)
  ) x
  where x.oh + x.oo <= x.reorder_level;
$$;

create or replace function public.supplier_summary(p_supplier uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  with s as (select * from suppliers where id = p_supplier and is_member(company_id))
  select jsonb_build_object(
    'balance', coalesce((select sum(round((total - amount_paid) * exchange_rate, 2)) from bills where supplier_id = p_supplier and status = 'posted'), 0),
    'overdue', coalesce((select sum(round((total - amount_paid) * exchange_rate, 2)) from bills where supplier_id = p_supplier and status = 'posted' and due_date < current_date), 0),
    'spend_12m', coalesce((select sum(round(subtotal * exchange_rate, 2)) from bills where supplier_id = p_supplier and status <> 'draft' and bill_date > current_date - 365), 0),
    'open_orders', (select count(*) from purchase_orders where supplier_id = p_supplier and status in ('approved','sent','partial')),
    'open_order_value', coalesce((select sum((l.qty - l.received_qty) * l.unit_cost) from po_lines l join purchase_orders o on o.id = l.po_id
                                   where o.supplier_id = p_supplier and o.status in ('approved','sent','partial')), 0),
    'deliveries', (select count(*) from goods_receipts where supplier_id = p_supplier),
    'on_time_pct', (select round(100.0 * count(*) filter (where g.receipt_date <= coalesce(o.expected_date, g.receipt_date)) / nullif(count(*), 0))
                      from goods_receipts g join purchase_orders o on o.id = g.po_id where g.supplier_id = p_supplier),
    'avg_lead_days', (select round(avg(g.receipt_date - o.order_date)) from goods_receipts g join purchase_orders o on o.id = g.po_id where g.supplier_id = p_supplier),
    'last_order', (select max(order_date) from purchase_orders where supplier_id = p_supplier and status <> 'cancelled'))
  from s;
$$;


-- Books check and the to-do list cover the new documents.
alter function public.ledger_checks(uuid) rename to ledger_checks_v20;
create or replace function public.ledger_checks(cid uuid)
returns table (check_name text, ledger numeric, documents numeric, direct numeric, difference numeric, ok boolean, explanation text)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare bal numeric; doc numeric;
begin
  return query select * from ledger_checks_v20(cid);
  if not has_role(cid, array['owner','admin','accountant']) then return; end if;
  select coalesce(sum(l.credit - l.debit),0) into bal from journal_lines l where l.account_id = acct(cid,'grni');
  select coalesce(round(sum(greatest(pl.received_qty - pl.billed_qty, 0) * pl.unit_cost), 2),0) into doc
    from po_lines pl where pl.company_id = cid and pl.received_qty > pl.billed_qty;
  return query select 'Goods received not invoiced vs deliveries waiting for a supplier bill', bal, doc, 0::numeric, bal - doc, abs(bal - doc) < 1,
    'Goods received on purchase orders that the supplier has not billed yet. Use Bill from order when the supplier invoice arrives.';
  select coalesce(round(sum(sl.qty * p.cost), 2),0) into bal from stock_levels sl join products p on p.id = sl.product_id where p.company_id = cid and p.item_type = 'stock';
  select coalesce(round(sum(stock_qty * cost), 2),0) into doc from products where company_id = cid and item_type = 'stock';
  return query select 'Stock by warehouse vs total stock', bal, doc, 0::numeric, bal - doc, abs(bal - doc) < 1,
    'The sum of every warehouse''s stock against each item''s total quantity.';
end $$;
revoke execute on function public.ledger_checks_v20(uuid) from public, anon, authenticated;

alter function public.unposted_documents(uuid) rename to unposted_documents_v20;
create or replace function public.unposted_documents(cid uuid)
returns table (kind text, n bigint, amount numeric, oldest date, path text)
language sql stable security definer set search_path = public as $$
  select * from unposted_documents_v20(cid)
  union all select * from (
    select 'Purchase orders not yet approved', count(*), coalesce(sum(po_total(id)),0), min(order_date), '/purchase-orders' from purchase_orders where company_id = cid and status = 'draft'
    union all select 'Orders waiting for delivery', count(*), coalesce(sum(po_total(id)),0), min(coalesce(expected_date, order_date)), '/purchase-orders' from purchase_orders where company_id = cid and status in ('approved','sent','partial')
    union all select 'Received, waiting for the supplier''s bill', count(distinct po_id), coalesce(sum((received_qty - billed_qty) * unit_cost),0), null::date, '/purchase-orders' from po_lines where company_id = cid and received_qty > billed_qty
    union all select 'Draft stock issues and returns', count(*), 0::numeric, min(issue_date), '/inventory/issues' from stock_issues where company_id = cid and status = 'draft'
    union all select 'Draft transfers', count(*), 0::numeric, min(transfer_date), '/inventory/transfers' from stock_transfers where company_id = cid and status = 'draft'
    union all select 'Stocktakes not posted', count(*), 0::numeric, min(count_date), '/inventory/counts' from stock_counts where company_id = cid and status = 'draft'
  ) x where has_role(cid, array['owner','admin','accountant']);
$$;
revoke execute on function public.unposted_documents_v20(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------- 10. Project costs include stock issues, goods received for projects and open orders
create or replace function public.project_cost_items(cid uuid)
returns table (item_date date, project_id uuid, category text, source text, reference text, description text,
               account_code text, account_name text, amount numeric, in_ledger boolean, committed boolean, doc_id uuid)
language sql stable security definer set search_path = public as $$
  select t.work_date, t.project_id, 'labour', 'Timesheet', e.full_name, coalesce(t.note, tk.title, ''),
         null::text, null::text, round(t.hours * coalesce(e.cost_rate,0), 2), false, false, t.id
    from timesheets t join projects p on p.id = t.project_id left join employees e on e.id = t.employee_id left join tasks tk on tk.id = t.task_id
   where p.company_id = cid and t.status = 'approved'
  union all
  select x.expense_date, x.project_id, 'expenses', 'Expense claim', e.full_name, x.description, a.code, a.name, x.amount_home, true, false, x.id
    from expense_claims x join projects p on p.id = x.project_id left join employees e on e.id = x.employee_id left join accounts a on a.id = x.account_id
   where p.company_id = cid and x.status in ('approved','reimbursed')
  union all
  -- Supplier bills not matched to a goods receipt
  select b.bill_date, l.project_id,
         coalesce(l.project_category, case when l.product_id is not null then 'materials' else cost_category_for_account(l.account_id) end),
         'Supplier bill', b.number || coalesce(' · ' || s.name, ''), l.description,
         a.code, a.name, round(l.qty * l.unit_cost * b.exchange_rate, 2), true, false, b.id
    from bill_lines l join bills b on b.id = l.bill_id join projects p on p.id = l.project_id
    left join suppliers s on s.id = b.supplier_id
    left join accounts a on a.id = coalesce(l.account_id, (select id from accounts i where i.company_id = cid and i.system_key = 'project_materials'))
   where p.company_id = cid and b.status <> 'draft' and l.po_line_id is null
  union all
  -- Goods received for a project, stock issued to or returned from a project, and price differences on matched bills
  select je.entry_date, jl.project_id,
         case when je.source_type = 'stock_issue' or a.system_key in ('ppv','inventory') then 'materials' else cost_category_for_account(jl.account_id) end,
         case je.source_type when 'receipt' then 'Goods received' when 'stock_issue' then 'Stock from store' else 'Bill price difference' end,
         je.entry_no || ' · ' || coalesce((select number from goods_receipts where id = je.source_id), (select number from stock_issues where id = je.source_id),
                                          (select number from bills where id = je.source_id), ''),
         coalesce(je.memo, ''), a.code, a.name, jl.debit - jl.credit, true, false, je.id
    from journal_lines jl join journal_entries je on je.id = jl.entry_id join accounts a on a.id = jl.account_id
   where jl.company_id = cid and jl.project_id is not null and a.type in ('expense','asset')
     and (je.source_type in ('receipt','stock_issue') or (je.source_type = 'bill' and a.system_key = 'ppv'))
  union all
  select je.entry_date, jl.project_id, cost_category_for_account(jl.account_id), 'Journal', je.entry_no, coalesce(je.memo, ''),
         a.code, a.name, jl.debit - jl.credit, true, false, je.id
    from journal_lines jl join journal_entries je on je.id = jl.entry_id join accounts a on a.id = jl.account_id
   where jl.company_id = cid and jl.project_id is not null and je.source_type = 'manual' and a.type in ('expense','asset')
  union all
  select coalesce(r.needed_by, r.decided_at::date, r.created_at::date), r.project_id,
         case r.kind when 'material' then 'materials' else r.kind end, 'Purchase request', r.number, r.description,
         null, null, round(r.qty * r.est_unit_cost, 2), false, true, r.id
    from project_requests r left join bills b on b.id = r.bill_id
   where r.company_id = cid and (r.status = 'approved' or (r.status = 'billed' and (b.id is null or b.status = 'draft')))
  union all
  -- Ordered for a project and not yet received
  select coalesce(o.expected_date, o.order_date), l.project_id,
         case when l.product_id is not null then 'materials' else cost_category_for_account(l.account_id) end,
         'Purchase order', o.number, l.description, null, null, round((l.qty - l.received_qty) * l.unit_cost, 2), false, true, o.id
    from po_lines l join purchase_orders o on o.id = l.po_id
   where o.company_id = cid and l.project_id is not null and o.status in ('approved','sent','partial') and l.qty > l.received_qty
$$;
revoke execute on function public.project_cost_items(uuid) from public;

create or replace function public.cost_category_for_account(a uuid) returns text
language sql stable security definer set search_path = public as $$
  select case x.system_key when 'project_materials' then 'materials' when 'inventory' then 'materials' when 'ppv' then 'materials' when 'subcontract' then 'subcontract'
           when 'equipment_hire' then 'equipment' when 'reimburse' then 'expenses'
           else case when x.type = 'asset' then 'materials' else 'other' end end
    from accounts x where x.id = a;
$$;

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
  elsif p_type in ('payroll','payroll_payment') then select 'Payroll ' || to_char(period, 'Mon YYYY'), '/payroll/' || id into label, path from payroll_runs where id = p_id;
  elsif p_type in ('asset','asset_disposal') then select 'Asset · ' || coalesce(tag, name), '/assets/' || id into label, path from assets where id = p_id;
  elsif p_type = 'cash' then select 'Bank & cash ' || coalesce(number, ''), '/bank-cash?id=' || id into label, path from cash_transactions where id = p_id;
  elsif p_type = 'expense' then select 'Expense claim · ' || coalesce(e.full_name, ''), null into label, path from expense_claims x left join employees e on e.id = x.employee_id where x.id = p_id;
  elsif p_type = 'stock' then select 'Stock · ' || name, '/inventory/items/' || id into label, path from products where id = p_id;
  elsif p_type = 'receipt' then select 'Goods received ' || g.number, '/purchase-orders/' || g.po_id into label, path from goods_receipts g where g.id = p_id;
  elsif p_type = 'stock_issue' then select 'Stock issue ' || number, '/inventory/issues/' || id into label, path from stock_issues where id = p_id;
  elsif p_type = 'stock_count' then select 'Stocktake ' || number, '/inventory/counts/' || id into label, path from stock_counts where id = p_id;
  end if;
end $$;

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
  elsif p_type = 'receipt' then select o.branch_id, w.branch_id into branch_id, cost_centre_id from goods_receipts g join purchase_orders o on o.id = g.po_id
          left join warehouses w on w.id = g.warehouse_id where g.id = p_id; cost_centre_id := null; branch_id := coalesce(branch_id, (select w2.branch_id from goods_receipts g2 join warehouses w2 on w2.id = g2.warehouse_id where g2.id = p_id));
  elsif p_type = 'stock_issue' then select w.branch_id, s.cost_centre_id into branch_id, cost_centre_id from stock_issues s left join warehouses w on w.id = s.warehouse_id where s.id = p_id;
  elsif p_type = 'stock_count' then select w.branch_id into branch_id from stock_counts c join warehouses w on w.id = c.warehouse_id where c.id = p_id;
  end if;
end $$;

-- Billing a time-and-materials project now also bills materials from the store and re-billable supplier costs.
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
     and not exists (select 1 from expense_claims where project_id = p_project and status in ('approved','reimbursed') and billable and invoice_id is null and expense_date <= p_to)
     and not exists (select 1 from stock_issue_lines l join stock_issues s on s.id = l.issue_id where s.project_id = p_project and s.status = 'posted' and l.billable and l.invoice_id is null and s.issue_date <= p_to)
     and not exists (select 1 from bill_lines l join bills b on b.id = l.bill_id where l.project_id = p_project and b.status <> 'draft' and l.billable and l.invoice_id is null and b.bill_date <= p_to) then
    raise exception 'There is no approved, unbilled time, billable expense or billable material up to %', p_to;
  end if;

  insert into invoices (company_id, customer_id, project_id, invoice_date, currency, exchange_rate, notes, branch_id, cost_centre_id)
  values (pr.company_id, pr.customer_id, p_project, current_date, pr.currency, v_rate, 'Project ' || coalesce(pr.number,'') || ': ' || pr.name || ', work to ' || to_char(p_to, 'DD Mon YYYY'),
          pr.branch_id, pr.cost_centre_id)
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
  -- Materials from the store: issues less returns, per item and price
  for r in select p.name, p.unit, l.bill_price, sum(case when s.kind = 'issue' then l.qty else -l.qty end) q, p.taxable
             from stock_issue_lines l join stock_issues s on s.id = l.issue_id join products p on p.id = l.product_id
            where s.project_id = p_project and s.status = 'posted' and l.billable and l.invoice_id is null and s.issue_date <= p_to
            group by p.name, p.unit, l.bill_price, p.taxable having sum(case when s.kind = 'issue' then l.qty else -l.qty end) > 0 order by p.name loop
    insert into invoice_lines (invoice_id, company_id, description, qty, unit_price, taxable, sort)
    values (v_inv, pr.company_id, 'Materials supplied: ' || r.name || ' (' || r.unit || ')', r.q, round(coalesce(r.bill_price, 0) / v_rate, 2), r.taxable, i);
    i := i + 1;
  end loop;
  -- Supplier costs marked "bill to client"
  for r in select l.description, l.qty, round(l.unit_cost * b.exchange_rate / v_rate, 2) price from bill_lines l join bills b on b.id = l.bill_id
            where l.project_id = p_project and b.status <> 'draft' and l.billable and l.invoice_id is null and b.bill_date <= p_to order by b.bill_date loop
    insert into invoice_lines (invoice_id, company_id, description, qty, unit_price, taxable, sort)
    values (v_inv, pr.company_id, 'Supplied: ' || r.description, r.qty, r.price, true, i);
    i := i + 1;
  end loop;
  update timesheets set invoice_id = v_inv where project_id = p_project and status = 'approved' and billable and invoice_id is null and work_date <= p_to;
  update expense_claims set invoice_id = v_inv where project_id = p_project and status in ('approved','reimbursed') and billable and invoice_id is null and expense_date <= p_to;
  perform set_config('sika.posting','on', true);
  update stock_issue_lines l set invoice_id = v_inv from stock_issues s
   where s.id = l.issue_id and s.project_id = p_project and s.status = 'posted' and l.billable and l.invoice_id is null and s.issue_date <= p_to;
  perform set_config('sika.posting','off', true);
  update bill_lines l set invoice_id = v_inv from bills b where b.id = l.bill_id and l.project_id = p_project and b.status <> 'draft' and l.billable and l.invoice_id is null and b.bill_date <= p_to;
  return v_inv;
end $$;

-- ---------------------------------------------------------------- 11. Project lifecycle
alter table public.projects drop constraint if exists projects_status_check;
alter table public.projects add constraint projects_status_check check (status in ('planned','active','on_hold','done','closed','cancelled'));
alter table public.projects add column if not exists actual_start date;
alter table public.projects add column if not exists actual_end date;
alter table public.projects add column if not exists closed_at timestamptz;
alter table public.projects add column if not exists closed_by uuid;
alter table public.projects add column if not exists close_notes text;
update public.projects set actual_start = coalesce(actual_start, start_date) where status in ('active','on_hold','done');

create table public.project_status_log (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  project_id uuid not null references public.projects(id) on delete cascade,
  from_status text, to_status text not null,
  note text,
  changed_by uuid default auth.uid(),
  changed_email text,
  changed_at timestamptz not null default now()
);
create index on public.project_status_log (project_id, changed_at);

-- The status of a project changes only through the lifecycle actions below.
create or replace function public.project_status_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    if new.status not in ('planned','active') and not new.is_template then new.status := 'planned'; end if;
    if new.status = 'active' then new.actual_start := coalesce(new.actual_start, new.start_date, current_date); end if;
  elsif new.status is distinct from old.status and coalesce(current_setting('sika.lifecycle', true), '') <> 'on' then
    raise exception 'Use Start, Hold, Resume, Complete, Close or Reopen to change a project''s status';
  end if;
  return new;
end $$;
create trigger projects_status_guard before insert or update on public.projects for each row execute function public.project_status_guard();

-- Close-out checklist. severity: block = must be cleared before closing; warn = check, but you may close.
create or replace function public.project_close_check(p_project uuid)
returns table (item text, n bigint, amount numeric, severity text, hint text)
language sql stable security definer set search_path = public as $$
  with p as (select * from projects where id = p_project and is_member(company_id))
  select * from (
    select 'Tasks not finished' item, (select count(*) from tasks where project_id = p_project and status <> 'done') n, null::numeric amount, 'warn' severity, 'Plan tab: mark them done or remove them' hint
    union all select 'Time sheets waiting for approval', (select count(*) from timesheets where project_id = p_project and status = 'submitted'),
      (select sum(hours) from timesheets where project_id = p_project and status = 'submitted'), 'block', 'Approvals: approve or reject them'
    union all select 'Expense claims waiting for approval', (select count(*) from expense_claims where project_id = p_project and status = 'submitted'),
      (select sum(amount_home) from expense_claims where project_id = p_project and status = 'submitted'), 'block', 'Approvals: approve or reject them'
    union all select 'Billable time not invoiced', (select count(*) from timesheets t, p where t.project_id = p_project and t.status = 'approved' and t.billable and t.invoice_id is null and p.billing_type = 'time_materials'),
      null, 'block', 'Billing tab: Invoice approved time and expenses'
    union all select 'Billable expenses not invoiced', (select count(*) from expense_claims x where x.project_id = p_project and x.status in ('approved','reimbursed') and x.billable and x.invoice_id is null),
      (select sum(amount_home) from expense_claims x where x.project_id = p_project and x.status in ('approved','reimbursed') and x.billable and x.invoice_id is null), 'block', 'Billing tab: invoice them'
    union all select 'Billable materials not invoiced', (select count(*) from stock_issue_lines l join stock_issues s on s.id = l.issue_id where s.project_id = p_project and s.status = 'posted' and l.billable and l.invoice_id is null),
      null, 'block', 'Billing tab: invoice them'
    union all select 'Milestones not invoiced', (select count(*) from project_milestones where project_id = p_project and status <> 'invoiced'),
      (select sum(amount) from project_milestones where project_id = p_project and status <> 'invoiced'), 'block', 'Billing tab: invoice or delete them'
    union all select 'Purchase requests still open', (select count(*) from project_requests where project_id = p_project and status in ('draft','submitted','approved')),
      (select sum(qty * est_unit_cost) from project_requests where project_id = p_project and status in ('draft','submitted','approved')), 'block', 'Purchases tab: order, bill or cancel them'
    union all select 'Purchase orders not fully received', (select count(distinct o.id) from po_lines l join purchase_orders o on o.id = l.po_id where l.project_id = p_project and o.status in ('draft','approved','sent','partial') and l.received_qty < l.qty),
      null, 'block', 'Purchase orders: receive or close them'
    union all select 'Goods received but not billed by the supplier', (select count(*) from po_lines where project_id = p_project and received_qty > billed_qty),
      (select sum((received_qty - billed_qty) * unit_cost) from po_lines where project_id = p_project and received_qty > billed_qty), 'warn', 'Accounts: bill from the purchase order when the supplier invoice arrives'
    union all select 'Draft supplier bills for this project', (select count(distinct b.id) from bill_lines l join bills b on b.id = l.bill_id where l.project_id = p_project and b.status = 'draft'),
      null, 'block', 'Supplier bills: post or delete them'
    union all select 'Draft stock issues or returns', (select count(*) from stock_issues where project_id = p_project and status = 'draft'), null, 'block', 'Inventory → Issue to project: post or delete them'
    union all select 'Open issues and risks', (select count(*) from project_issues where project_id = p_project and status in ('open','in_progress')), null, 'warn', 'Issues tab: resolve or close them'
    union all select 'Client invoices not fully paid', (select count(*) from invoices where project_id = p_project and status = 'posted'),
      (select sum((total - amount_paid - amount_credited) * exchange_rate) from invoices where project_id = p_project and status = 'posted'), 'warn', 'Collect payment; closing does not stop you receiving it'
  ) x where n > 0;
$$;

create or replace function public.set_project_status(p_project uuid, p_action text, p_note text default null, p_date date default current_date, p_force boolean default false)
returns text language plpgsql security definer set search_path = public as $$
declare pr projects; v_to text; v_acct boolean; v_blocks int; v_email text;
begin
  select * into pr from projects where id = p_project for update;
  if not found then raise exception 'Project not found'; end if;
  if pr.is_template then raise exception 'Templates do not have a status'; end if;
  v_acct := has_role(pr.company_id, array['owner','admin','accountant']);
  if not (v_acct or can_manage_project(p_project)) then raise exception 'Only the project''s manager or an accountant can do this'; end if;
  v_to := case p_action
    when 'start' then case when pr.status in ('planned') then 'active' end
    when 'hold' then case when pr.status = 'active' then 'on_hold' end
    when 'resume' then case when pr.status = 'on_hold' then 'active' end
    when 'complete' then case when pr.status in ('active','on_hold') then 'done' end
    when 'resume_work' then case when pr.status = 'done' then 'active' end
    when 'close' then case when pr.status = 'done' then 'closed' end
    when 'reopen' then case when pr.status in ('closed','cancelled') then case when pr.status = 'closed' then 'done' else 'planned' end end
    when 'cancel' then case when pr.status in ('planned','active','on_hold') then 'cancelled' end
  end;
  if v_to is null then raise exception 'You cannot % a project that is %', replace(p_action, '_', ' '), replace(pr.status, '_', ' '); end if;
  if p_action in ('hold','cancel','reopen') and coalesce(trim(p_note),'') = '' then raise exception 'Give a reason'; end if;
  if p_action = 'reopen' and not v_acct then raise exception 'Only an accountant, admin or the owner can reopen a closed project'; end if;
  if p_action = 'close' then
    select count(*) into v_blocks from project_close_check(p_project) where severity = 'block';
    if v_blocks > 0 and not (p_force and v_acct and coalesce(trim(p_note),'') <> '') then
      raise exception '% item% must be cleared before closing (see the close-out checklist). An accountant can close anyway with a reason.', v_blocks, case when v_blocks = 1 then '' else 's' end;
    end if;
  end if;
  if p_action = 'cancel' and exists (select 1 from timesheets where project_id = p_project and status = 'approved') and not v_acct then
    raise exception 'Time has been booked to this project. Complete and close it instead, or ask an accountant.';
  end if;
  perform set_config('sika.lifecycle','on', true);
  update projects set status = v_to,
    actual_start = case when v_to = 'active' then coalesce(actual_start, p_date) else actual_start end,
    actual_end = case when v_to = 'done' then p_date when p_action = 'resume_work' then null else actual_end end,
    closed_at = case when v_to = 'closed' then now() when p_action = 'reopen' then null else closed_at end,
    closed_by = case when v_to = 'closed' then auth.uid() when p_action = 'reopen' then null else closed_by end,
    close_notes = case when v_to = 'closed' then p_note else close_notes end,
    percent_complete_override = case when v_to = 'done' then 100 when p_action = 'resume_work' then null else percent_complete_override end
  where id = p_project;
  perform set_config('sika.lifecycle','off', true);
  select email into v_email from auth.users where id = auth.uid();
  insert into project_status_log (company_id, project_id, from_status, to_status, note, changed_email)
  values (pr.company_id, p_project, pr.status, v_to, case when p_force and p_action = 'close' then 'Closed with open items: ' || p_note else p_note end, v_email);
  return v_to;
end $$;

-- Nothing new can be booked to a closed or cancelled project.
create or replace function public.closed_project_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare st text; pid uuid;
begin
  pid := new.project_id;
  if pid is null then return new; end if;
  select status into st from projects where id = pid;
  if st in ('closed','cancelled') then raise exception 'This project is %. Reopen it to book anything to it.', st; end if;
  return new;
end $$;
do $$ declare t text; begin
  foreach t in array array['timesheets','expense_claims','project_requests','tasks','stock_issues','po_lines','bill_lines','project_milestones'] loop
    execute format('create trigger %I before insert on public.%I for each row execute function public.closed_project_guard()', t || '_closed_project', t);
  end loop;
end $$;

-- ---------------------------------------------------------------- 12. New companies
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
  perform seed_accounts_v21(v);
  perform seed_leave_types(v);
  perform seed_asset_categories(v);
  perform wh(v);
  return v;
end $$;

-- ---------------------------------------------------------------- 13. Row-level security
alter table public.warehouses enable row level security;
create policy "members read warehouses" on public.warehouses for select using (is_member(company_id));
create policy "managers write warehouses" on public.warehouses for all using (has_role(company_id, array['owner','admin','accountant','store'])) with check (has_role(company_id, array['owner','admin','accountant','store']));
alter table public.stock_levels enable row level security;
create policy "members read levels" on public.stock_levels for select using (is_member(company_id));
create policy "store sets bins" on public.stock_levels for update using (has_role(company_id, array['owner','admin','accountant','store']));

alter table public.supplier_items enable row level security;
create policy "members read price lists" on public.supplier_items for select using (is_member(company_id));
create policy "buyers write price lists" on public.supplier_items for all using (has_role(company_id, array['owner','admin','accountant','store'])) with check (has_role(company_id, array['owner','admin','accountant','store']));

alter table public.purchase_orders enable row level security;
alter table public.po_lines enable row level security;
create policy "members read orders" on public.purchase_orders for select using (is_member(company_id));
create policy "buyers create orders" on public.purchase_orders for insert with check (has_role(company_id, array['owner','admin','accountant','store','project_manager']));
create policy "buyers edit draft orders" on public.purchase_orders for update using (has_role(company_id, array['owner','admin','accountant','store','project_manager']));
create policy "buyers delete draft orders" on public.purchase_orders for delete using (status = 'draft' and has_role(company_id, array['owner','admin','accountant','store','project_manager']));
create policy "members read order lines" on public.po_lines for select using (is_member(company_id));
create policy "buyers write order lines" on public.po_lines for all using (has_role(company_id, array['owner','admin','accountant','store','project_manager'])) with check (has_role(company_id, array['owner','admin','accountant','store','project_manager']));

alter table public.goods_receipts enable row level security;
alter table public.goods_receipt_lines enable row level security;
create policy "members read receipts" on public.goods_receipts for select using (is_member(company_id));
create policy "members read receipt lines" on public.goods_receipt_lines for select using (is_member(company_id));

alter table public.stock_issues enable row level security;
alter table public.stock_issue_lines enable row level security;
create policy "members read issues" on public.stock_issues for select using (is_member(company_id));
create policy "store and managers write issues" on public.stock_issues for all
  using (has_role(company_id, array['owner','admin','accountant','store']) or (project_id is not null and can_manage_project(project_id)))
  with check (has_role(company_id, array['owner','admin','accountant','store']) or (project_id is not null and can_manage_project(project_id)));
create policy "members read issue lines" on public.stock_issue_lines for select using (is_member(company_id));
create policy "store and managers write issue lines" on public.stock_issue_lines for all
  using (exists (select 1 from stock_issues s where s.id = issue_id and (has_role(s.company_id, array['owner','admin','accountant','store']) or (s.project_id is not null and can_manage_project(s.project_id)))))
  with check (exists (select 1 from stock_issues s where s.id = issue_id and (has_role(s.company_id, array['owner','admin','accountant','store']) or (s.project_id is not null and can_manage_project(s.project_id)))));

do $$ declare t text; begin
  foreach t in array array['stock_transfers','stock_transfer_lines','stock_counts','stock_count_lines'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy "members read" on public.%I for select using (is_member(company_id))', t);
    execute format('create policy "store writes" on public.%I for all using (has_role(company_id, array[''owner'',''admin'',''accountant'',''store''])) with check (has_role(company_id, array[''owner'',''admin'',''accountant'',''store'']))', t);
  end loop;
end $$;

alter table public.project_status_log enable row level security;
create policy "members read status log" on public.project_status_log for select using (is_member(company_id));

-- The store role can work with products and suppliers.
create policy "store edits products" on public.products for update using (has_role(company_id, array['store']));
create policy "store adds products" on public.products for insert with check (has_role(company_id, array['store']));

-- Audit the new documents
do $$ declare t text; begin
  foreach t in array array['warehouses','purchase_orders','stock_issues','stock_transfers','stock_counts','supplier_items'] loop
    execute format('create trigger %I after insert or update or delete on public.%I for each row execute function public.audit_row()', t || '_audit', t);
  end loop;
end $$;

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
revoke execute on function public.seed_accounts_v21(uuid) from authenticated;
revoke execute on function public.seed_leave_types(uuid) from authenticated;
revoke execute on function public.seed_asset_categories(uuid) from authenticated;
revoke execute on function public.next_number(uuid,text,text) from authenticated;
revoke execute on function public.project_cost_items(uuid) from authenticated;
revoke execute on function public.project_cost_totals(uuid) from authenticated;
revoke execute on function public.finalize_expense(uuid) from authenticated;
revoke execute on function public.doc_dims(text,uuid) from authenticated;
revoke execute on function public.wh(uuid) from authenticated;
grant execute on function public.public_help(uuid) to anon;
grant execute on function public.submit_case_public(uuid,text,text,text,text,text) to anon;
grant execute on function public.case_status_public(text,text) to anon;
grant execute on function public.reply_case_public(text,text,text,int) to anon;
revoke execute on function public.ledger_checks_v20(uuid) from authenticated;
revoke execute on function public.unposted_documents_v20(uuid) from authenticated;


-- ======================================================================
-- 0008_asnys_v2_2.sql
-- ======================================================================
-- =====================================================================
-- Asnys ERP v2.2 — project site stores and project document control
--   1. Site stores run by the project team: receive at site, record usage against tasks, return, count; stock requests
--      from the main store with goods in transit; counts approved by the project manager up to a limit; materials plan
--   2. Document register per project: types, numbering, revisions, internal review, transmittals and client responses,
--      expiry alerts, required documents at start and close-out
--   3. Structured risk assessments (5 x 5 matrix, controls, residual risk, PM and HSE sign-off)
-- Run after 0007.
-- =====================================================================

-- ---------------------------------------------------------------- 1. Who may work a store
create or replace function public.on_project_team(pid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select can_manage_project(pid) or exists (
    select 1 from project_assignments pa join employees e on e.id = pa.employee_id
     where pa.project_id = pid and e.user_id = auth.uid() and pa.status = 'confirmed'
       and (pa.end_date is null or pa.end_date >= current_date - 30));
$$;

-- The store, accountants and owners use any store; a project's team uses that project's site stores.
create or replace function public.can_use_store(p_wh uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from warehouses w where w.id = p_wh and (
    has_role(w.company_id, array['owner','admin','accountant','store'])
    or (w.project_id is not null and w.kind = 'site' and on_project_team(w.project_id))));
$$;

alter table public.warehouses drop constraint if exists warehouses_kind_check;
alter table public.warehouses add constraint warehouses_kind_check check (kind in ('store','site','vehicle','shop','transit'));

-- Goods on the road between stores are still ours: they sit in a hidden "in transit" store until received.
create or replace function public.transit_wh(cid uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  select id into v from warehouses where company_id = cid and kind = 'transit';
  if v is null then
    insert into warehouses (company_id, code, name, kind, active) values (cid, 'TRANSIT', 'Goods in transit', 'transit', false) returning id into v;
  end if;
  return v;
end $$;

alter table public.companies add column if not exists site_count_limit numeric(14,2) not null default 1000;  -- GHS a project manager may approve on a site stocktake
alter table public.stock_issues add column if not exists task_id uuid references public.tasks(id) on delete set null;
alter table public.projects add column if not exists hse_officer_id uuid;
alter table public.projects alter column status set default 'planned';

-- ---------------------------------------------------------------- 2. Stock requests: site asks, main store sends, site confirms
create table public.stock_requests (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  number text,
  project_id uuid not null references public.projects(id) on delete cascade,
  from_warehouse_id uuid not null references public.warehouses(id),
  to_warehouse_id uuid not null references public.warehouses(id),
  needed_by date,
  notes text,
  status text not null default 'draft' check (status in ('draft','submitted','dispatched','received','cancelled')),
  requested_by uuid default auth.uid(),
  requested_email text,
  dispatched_at date, dispatched_by uuid, dispatch_note text,
  received_at date, received_by uuid, receive_note text,
  created_at timestamptz not null default now(),
  check (from_warehouse_id <> to_warehouse_id)
);
create table public.stock_request_lines (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.stock_requests(id) on delete cascade,
  company_id uuid not null references public.companies(id) on delete cascade,
  product_id uuid not null references public.products(id),
  qty numeric(14,3) not null check (qty > 0),
  dispatched_qty numeric(14,3) not null default 0,
  received_qty numeric(14,3) not null default 0,
  sort int not null default 0
);
create index on public.stock_requests (project_id);

create or replace function public.stock_request_defaults() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    new.company_id := (select company_id from projects where id = new.project_id);
    new.number := coalesce(new.number, next_number(new.company_id, 'SRQ', 'SRQ-'));
    new.requested_by := coalesce(auth.uid(), new.requested_by);
    new.requested_email := (select email from auth.users where id = new.requested_by);
    if new.status not in ('draft','submitted') then raise exception 'A new stock request starts as a draft'; end if;
    if (select project_id from warehouses where id = new.to_warehouse_id) is distinct from new.project_id then
      raise exception 'Deliver the request to this project''s site store';
    end if;
  elsif new.status is distinct from old.status and coalesce(current_setting('sika.posting', true), '') <> 'on'
        and not (old.status = 'draft' and new.status in ('submitted','cancelled')) and not (old.status = 'submitted' and new.status = 'cancelled') then
    raise exception 'Use Send or Receive to move a stock request on';
  end if;
  return new;
end $$;
create trigger stock_requests_defaults before insert or update on public.stock_requests for each row execute function public.stock_request_defaults();

create or replace function public.stock_request_line_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if (select status from stock_requests where id = coalesce(new.request_id, old.request_id)) not in ('draft','submitted')
     and coalesce(current_setting('sika.posting', true), '') <> 'on' then raise exception 'This request has been sent and cannot be changed'; end if;
  return coalesce(new, old);
end $$;
create trigger stock_request_lines_guard before insert or update or delete on public.stock_request_lines for each row execute function public.stock_request_line_guard();

-- The supplying store sends the goods: they leave its shelves and go "in transit".
create or replace function public.dispatch_stock_request(p_id uuid, p_lines jsonb, p_date date default current_date, p_note text default null)
returns text language plpgsql security definer set search_path = public as $$
declare r stock_requests; l record; rl stock_request_lines; p products; v_have numeric; v_tr uuid; n int := 0;
begin
  select * into r from stock_requests where id = p_id for update;
  if not found then raise exception 'Stock request not found'; end if;
  if not can_use_store(r.from_warehouse_id) then raise exception 'Only the supplying store can send this request'; end if;
  if r.status <> 'submitted' then raise exception '% is %', r.number, r.status; end if;
  v_tr := transit_wh(r.company_id);
  perform set_config('sika.posting','on', true);
  for l in select (x->>'line_id')::uuid line_id, round((x->>'qty')::numeric, 3) qty from jsonb_array_elements(p_lines) x loop
    continue when coalesce(l.qty, 0) <= 0;
    select * into rl from stock_request_lines where id = l.line_id and request_id = p_id;
    if not found then raise exception 'A line is not on this request'; end if;
    select * into p from products where id = rl.product_id;
    select coalesce(sum(qty), 0) into v_have from stock_levels where product_id = p.id and warehouse_id = r.from_warehouse_id;
    if v_have < l.qty then raise exception 'Only % % of % in stock at %', v_have, p.unit, p.name, (select name from warehouses where id = r.from_warehouse_id); end if;
    insert into stock_moves (company_id, product_id, warehouse_id, move_date, qty, unit_cost, reason, ref_type, ref_id, project_id)
    values (r.company_id, p.id, r.from_warehouse_id, p_date, -l.qty, p.cost, 'Sent to site ' || r.number, 'stock_request', r.id, r.project_id),
           (r.company_id, p.id, v_tr, p_date, l.qty, p.cost, 'In transit ' || r.number, 'stock_request', r.id, r.project_id);
    update stock_request_lines set dispatched_qty = l.qty where id = rl.id;
    n := n + 1;
  end loop;
  if n = 0 then raise exception 'Enter the quantity sent on at least one line'; end if;
  update stock_requests set status = 'dispatched', dispatched_at = p_date, dispatched_by = auth.uid(), dispatch_note = p_note where id = p_id;
  perform set_config('sika.posting','off', true);
  return r.number;
end $$;

-- The site confirms what arrived. Anything short is written off as lost in transit.
create or replace function public.receive_stock_request(p_id uuid, p_lines jsonb, p_date date default current_date, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r stock_requests; rl record; p products; v_tr uuid; v_q numeric; v_short numeric; v_loss numeric := 0; v_je uuid;
begin
  select * into r from stock_requests where id = p_id for update;
  if not found then raise exception 'Stock request not found'; end if;
  if not can_use_store(r.to_warehouse_id) then raise exception 'Only the project team or the store can confirm this delivery'; end if;
  if r.status <> 'dispatched' then raise exception '% has not been sent yet', r.number; end if;
  v_tr := transit_wh(r.company_id);
  perform set_config('sika.posting','on', true);
  for rl in select * from stock_request_lines where request_id = p_id and dispatched_qty > 0 loop
    v_q := coalesce((select round((x->>'qty')::numeric, 3) from jsonb_array_elements(p_lines) x where (x->>'line_id')::uuid = rl.id), rl.dispatched_qty);
    if v_q < 0 or v_q > rl.dispatched_qty then raise exception 'You can confirm at most % received for one line', rl.dispatched_qty; end if;
    select * into p from products where id = rl.product_id for update;
    if v_q > 0 then
      insert into stock_moves (company_id, product_id, warehouse_id, move_date, qty, unit_cost, reason, ref_type, ref_id, project_id)
      values (r.company_id, p.id, v_tr, p_date, -v_q, p.cost, 'Arrived ' || r.number, 'stock_request', r.id, r.project_id),
             (r.company_id, p.id, r.to_warehouse_id, p_date, v_q, p.cost, 'Received from store ' || r.number, 'stock_request', r.id, r.project_id);
    end if;
    v_short := rl.dispatched_qty - v_q;
    if v_short > 0 then
      update products set stock_qty = stock_qty - v_short where id = p.id;
      insert into stock_moves (company_id, product_id, warehouse_id, move_date, qty, unit_cost, reason, ref_type, ref_id, project_id)
      values (r.company_id, p.id, v_tr, p_date, -v_short, p.cost, 'Lost in transit ' || r.number, 'stock_request', r.id, r.project_id);
      v_loss := v_loss + round(v_short * p.cost, 2);
    end if;
    update stock_request_lines set received_qty = v_q where id = rl.id;
  end loop;
  update stock_requests set status = 'received', received_at = p_date, received_by = auth.uid(), receive_note = p_note where id = p_id;
  perform set_config('sika.posting','off', true);
  if v_loss > 0 then
    v_je := post_journal(r.company_id, p_date, 'Short delivery to site on ' || r.number || coalesce(': ' || p_note, ''),
      jsonb_build_array(jl(acct(r.company_id,'stock_adj'), v_loss, 0) || jsonb_build_object('project_id', r.project_id), jl(acct(r.company_id,'inventory'), 0, v_loss)), 'stock_request', r.id);
  end if;
  return jsonb_build_object('lost_value', v_loss);
end $$;

-- ---------------------------------------------------------------- 3. Materials plan and usage
create table public.project_material_plan (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  project_id uuid not null references public.projects(id) on delete cascade,
  product_id uuid not null references public.products(id),
  planned_qty numeric(14,3) not null check (planned_qty >= 0),
  note text,
  unique (project_id, product_id)
);
create or replace function public.material_plan_defaults() returns trigger
language plpgsql security definer set search_path = public as $$
begin new.company_id := (select company_id from projects where id = new.project_id); return new; end $$;
create trigger project_material_plan_defaults before insert or update on public.project_material_plan for each row execute function public.material_plan_defaults();

-- Planned vs used for each material, with what is at site, on the way, still requested, and lost on site counts.
create or replace function public.project_material_usage(p_project uuid)
returns table (product_id uuid, sku text, name text, unit text, planned numeric, used numeric, used_value numeric, at_site numeric,
               in_transit numeric, requested numeric, wastage numeric, wastage_value numeric, remaining numeric, used_pct numeric, over boolean)
language sql stable security definer set search_path = public as $$
  with pr as (select * from projects where id = p_project and is_member(company_id)),
  sites as (select w.id from warehouses w, pr where w.project_id = pr.id),
  u as (select l.product_id, sum(case when s.kind = 'issue' then l.qty else -l.qty end) q, sum(case when s.kind = 'issue' then 1 else -1 end * l.qty * coalesce(l.unit_cost, 0)) v
          from stock_issue_lines l join stock_issues s on s.id = l.issue_id where s.project_id = p_project and s.status = 'posted' group by l.product_id),
  st as (select sl.product_id, sum(sl.qty) q from stock_levels sl where sl.warehouse_id in (select id from sites) group by sl.product_id),
  rq as (select rl.product_id, sum(case when r.status = 'dispatched' then rl.dispatched_qty else 0 end) tr, sum(case when r.status = 'submitted' then rl.qty else 0 end) rq
           from stock_request_lines rl join stock_requests r on r.id = rl.request_id where r.project_id = p_project group by rl.product_id),
  wa as (select cl.product_id, sum(cl.system_qty - cl.counted_qty) q, sum((cl.system_qty - cl.counted_qty) * coalesce(cl.unit_cost, 0)) v
           from stock_count_lines cl join stock_counts c on c.id = cl.count_id where c.status = 'posted' and c.warehouse_id in (select id from sites) group by cl.product_id),
  ids as (select product_id from project_material_plan where project_id = p_project union select product_id from u union select product_id from st where q <> 0 union select product_id from rq)
  select p.id, p.sku, p.name, p.unit, mp.planned_qty, coalesce(u.q, 0), round(coalesce(u.v, 0), 2), coalesce(st.q, 0), coalesce(rq.tr, 0), coalesce(rq.rq, 0),
         coalesce(wa.q, 0), round(coalesce(wa.v, 0), 2),
         case when mp.planned_qty is not null then mp.planned_qty - coalesce(u.q, 0) end,
         case when mp.planned_qty > 0 then round(100 * coalesce(u.q, 0) / mp.planned_qty) end,
         mp.planned_qty is not null and coalesce(u.q, 0) > mp.planned_qty
    from ids join products p on p.id = ids.product_id
    left join project_material_plan mp on mp.project_id = p_project and mp.product_id = p.id
    left join u on u.product_id = p.id left join st on st.product_id = p.id left join rq on rq.product_id = p.id left join wa on wa.product_id = p.id
   where exists (select 1 from pr)
   order by p.name;
$$;

-- Stock held at every project site, for the stock controller.
create or replace function public.site_stock(cid uuid)
returns table (warehouse_id uuid, code text, warehouse text, project_id uuid, project text, project_status text, lines bigint, value numeric)
language sql stable security definer set search_path = public as $$
  select w.id, w.code, w.name, pj.id, coalesce(pj.number || ' ', '') || pj.name, pj.status,
         count(sl.product_id) filter (where sl.qty <> 0), coalesce(round(sum(sl.qty * p.cost), 2), 0)
    from warehouses w left join projects pj on pj.id = w.project_id
    left join stock_levels sl on sl.warehouse_id = w.id left join products p on p.id = sl.product_id
   where w.company_id = cid and w.kind = 'site' and is_member(cid)
   group by w.id, w.code, w.name, pj.id, pj.number, pj.name, pj.status
   order by w.code;
$$;

-- ---------------------------------------------------------------- 4. Store work by the project team (re-issued from 0007)
create or replace function public.receive_po(p_po uuid, p_lines jsonb, p_date date default current_date, p_warehouse uuid default null, p_reference text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare o purchase_orders; l record; pl po_lines; pr products; v_grn uuid; v_wh uuid; v_lines jsonb := '[]'::jsonb; v_total numeric := 0; v_amt numeric; v_acct uuid; v_je uuid; n int := 0;
begin
  select * into o from purchase_orders where id = p_po for update;
  if not found then raise exception 'Purchase order not found'; end if;
  if o.status not in ('approved','sent','partial') then raise exception 'Only an approved, open order can be received (this one is %)', o.status; end if;
  v_wh := coalesce(p_warehouse, o.warehouse_id, wh(o.company_id));
  if not exists (select 1 from warehouses where id = v_wh and company_id = o.company_id) then raise exception 'Choose one of your warehouses'; end if;
  if not (has_role(o.company_id, array['owner','admin','accountant','store']) or (p_warehouse is not null or o.warehouse_id is not null) and can_use_store(v_wh)
          or (o.project_id is not null and o.warehouse_id is null and p_warehouse is null and on_project_team(o.project_id))) then
    raise exception 'Only the store, an accountant or this project''s team can receive this delivery';
  end if;
  insert into goods_receipts (company_id, number, po_id, supplier_id, receipt_date, warehouse_id, reference)
  values (o.company_id, next_number(o.company_id, 'GRN', 'GRN-'), p_po, o.supplier_id, p_date, v_wh, p_reference) returning id into v_grn;
  perform set_config('sika.posting','on', true);
  perform set_config('sika.po','on', true);
  for l in select (x->>'line_id')::uuid line_id, round((x->>'qty')::numeric, 3) qty from jsonb_array_elements(p_lines) x loop
    continue when coalesce(l.qty, 0) = 0;
    select * into pl from po_lines where id = l.line_id and po_id = p_po for update;
    if not found then raise exception 'A line is not on this order'; end if;
    if l.qty < 0 or l.qty > pl.qty - pl.received_qty + 0.0005 then
      raise exception 'You can receive at most % of "%"', pl.qty - pl.received_qty, pl.description;
    end if;
    v_amt := round(l.qty * pl.unit_cost, 2);
    pr := null;
    if pl.product_id is not null then select * into pr from products where id = pl.product_id for update; end if;
    if pl.project_id is null and pr.id is not null and pr.item_type = 'stock' then
      update products set cost = round((greatest(stock_qty,0) * cost + l.qty * pl.unit_cost) / nullif(greatest(stock_qty,0) + l.qty, 0), 4),
                          stock_qty = stock_qty + l.qty, last_purchase_cost = pl.unit_cost where id = pr.id;
      insert into stock_moves (company_id, product_id, warehouse_id, move_date, qty, unit_cost, reason, ref_type, ref_id)
      values (o.company_id, pr.id, v_wh, p_date, l.qty, pl.unit_cost, 'Received ' || o.number, 'receipt', v_grn);
      v_acct := acct(o.company_id, 'inventory');
    else
      if pr.id is not null then update products set last_purchase_cost = pl.unit_cost where id = pr.id; end if;
      v_acct := coalesce(pl.account_id, pr.expense_account_id,
                         case when pl.project_id is not null then acct(o.company_id, 'project_materials') else acct(o.company_id, 'expense') end);
    end if;
    insert into goods_receipt_lines (receipt_id, company_id, po_line_id, product_id, qty, unit_cost, project_id)
    values (v_grn, o.company_id, pl.id, pl.product_id, l.qty, pl.unit_cost, pl.project_id);
    update po_lines set received_qty = received_qty + l.qty where id = pl.id;
    v_lines := v_lines || (jl(v_acct, v_amt, 0) || jsonb_build_object('project_id', pl.project_id, 'branch_id', o.branch_id));
    v_total := v_total + v_amt; n := n + 1;
  end loop;
  perform set_config('sika.posting','off', true);
  if n = 0 then raise exception 'Enter the quantity received on at least one line'; end if;
  if v_total > 0 then
    v_je := post_journal(o.company_id, p_date, 'Goods received on ' || o.number || coalesce(' (delivery note ' || p_reference || ')', ''),
      v_lines || jl(acct(o.company_id, 'grni'), 0, v_total), 'receipt', v_grn);
    update goods_receipts set journal_entry_id = v_je where id = v_grn;
  end if;
  update purchase_orders set status = case when exists (select 1 from po_lines where po_id = p_po and received_qty < qty) then 'partial' else 'received' end where id = p_po;
  perform set_config('sika.po','off', true);
  return v_grn;
end $$;

create or replace function public.post_stock_issue(p_id uuid) returns text
language plpgsql security definer set search_path = public as $$
declare s stock_issues; l record; p products; v_have numeric; v_val numeric := 0; v_amt numeric; v_target uuid; v_sign int; v_je uuid;
begin
  select * into s from stock_issues where id = p_id for update;
  if not found then raise exception 'Stock issue not found'; end if;
  if not (has_role(s.company_id, array['owner','admin','accountant','store'])
          or (s.project_id is not null and on_project_team(s.project_id) and coalesce((select project_id from warehouses where id = s.warehouse_id) = s.project_id, false))) then
    raise exception 'The project team can issue and return stock only through this project''s site store. Ask the store for anything else.';
  end if;
  if s.status <> 'draft' then raise exception '% is already posted', s.number; end if;
  if not exists (select 1 from stock_issue_lines where issue_id = p_id) then raise exception 'Add at least one item'; end if;
  if s.project_id is not null and (select status from projects where id = s.project_id) in ('closed','cancelled') then raise exception 'This project is closed'; end if;
  v_sign := case when s.kind = 'issue' then -1 else 1 end;
  v_target := coalesce(s.account_id, case when s.project_id is not null then acct(s.company_id, 'project_materials') else acct(s.company_id, 'expense') end);
  perform set_config('sika.posting','on', true);
  for l in select * from stock_issue_lines where issue_id = p_id order by sort loop
    select * into p from products where id = l.product_id for update;
    if p.item_type <> 'stock' then raise exception '% is not a stock item', p.name; end if;
    if s.kind = 'issue' then
      select coalesce(sum(qty), 0) into v_have from stock_levels where product_id = p.id and warehouse_id = s.warehouse_id;
      if v_have < l.qty then raise exception 'Only % % of % in stock at %', v_have, p.unit, p.name, (select name from warehouses where id = s.warehouse_id); end if;
    end if;
    v_amt := round(l.qty * p.cost, 2);
    update products set stock_qty = stock_qty + v_sign * l.qty where id = p.id;
    insert into stock_moves (company_id, product_id, warehouse_id, move_date, qty, unit_cost, reason, ref_type, ref_id, project_id)
    values (s.company_id, p.id, s.warehouse_id, s.issue_date, v_sign * l.qty, p.cost,
            case when s.kind = 'issue' then 'Issued ' else 'Returned ' end || s.number, 'stock_issue', s.id, s.project_id);
    update stock_issue_lines set unit_cost = p.cost, bill_price = coalesce(bill_price, p.price) where id = l.id;
    v_val := v_val + v_amt;
  end loop;
  update stock_issues set status = 'posted' where id = p_id;
  if v_val > 0 then
    v_je := post_journal(s.company_id, s.issue_date,
      case when s.kind = 'issue' then 'Stock issued ' else 'Stock returned ' end || s.number || coalesce(' — ' || (select coalesce(number || ' ', '') || name from projects where id = s.project_id), ''),
      case when s.kind = 'issue'
        then jsonb_build_array(jl(v_target, v_val, 0) || jsonb_build_object('project_id', s.project_id, 'cost_centre_id', s.cost_centre_id), jl(acct(s.company_id,'inventory'), 0, v_val))
        else jsonb_build_array(jl(acct(s.company_id,'inventory'), v_val, 0), jl(v_target, 0, v_val) || jsonb_build_object('project_id', s.project_id, 'cost_centre_id', s.cost_centre_id)) end,
      'stock_issue', s.id);
    update stock_issues set journal_entry_id = v_je where id = p_id;
  end if;
  perform set_config('sika.posting','off', true);
  return s.number;
end $$;

create or replace function public.post_transfer(p_id uuid) returns text
language plpgsql security definer set search_path = public as $$
declare t stock_transfers; l record; p products; v_have numeric;
begin
  select * into t from stock_transfers where id = p_id for update;
  if not found then raise exception 'Transfer not found'; end if;
  if not can_use_store(t.from_warehouse_id) then raise exception 'Only the store, or the team of the project whose site store it is, can send stock from %', (select name from warehouses where id = t.from_warehouse_id); end if;
  if t.status <> 'draft' then raise exception '% is already posted', t.number; end if;
  if not exists (select 1 from stock_transfer_lines where transfer_id = p_id) then raise exception 'Add at least one item'; end if;
  for l in select * from stock_transfer_lines where transfer_id = p_id loop
    select * into p from products where id = l.product_id;
    select coalesce(sum(qty), 0) into v_have from stock_levels where product_id = p.id and warehouse_id = t.from_warehouse_id;
    if v_have < l.qty then raise exception 'Only % % of % in stock at %', v_have, p.unit, p.name, (select name from warehouses where id = t.from_warehouse_id); end if;
    insert into stock_moves (company_id, product_id, warehouse_id, move_date, qty, unit_cost, reason, ref_type, ref_id)
    values (t.company_id, p.id, t.from_warehouse_id, t.transfer_date, -l.qty, p.cost, 'Transfer out ' || t.number, 'transfer', t.id),
           (t.company_id, p.id, t.to_warehouse_id, t.transfer_date, l.qty, p.cost, 'Transfer in ' || t.number, 'transfer', t.id);
  end loop;
  perform set_config('sika.posting','on', true);
  update stock_transfers set status = 'posted' where id = p_id;
  perform set_config('sika.posting','off', true);
  return t.number;
end $$;

create or replace function public.start_stock_count(cid uuid, p_warehouse uuid, p_date date default current_date, p_category text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  perform require_member(cid, array['owner','admin','accountant','sales','hr','project_manager','store','staff']);
  if not can_use_store(p_warehouse) then raise exception 'You cannot count this store'; end if;
  if not exists (select 1 from warehouses where id = p_warehouse and company_id = cid) then raise exception 'Choose one of your warehouses'; end if;
  insert into stock_counts (company_id, number, warehouse_id, count_date, notes)
  values (cid, next_number(cid, 'CNT', 'CNT-'), p_warehouse, p_date, case when p_category is not null then 'Category: ' || p_category end) returning id into v;
  insert into stock_count_lines (count_id, company_id, product_id, system_qty)
  select v, cid, p.id, coalesce(sl.qty, 0) from products p left join stock_levels sl on sl.product_id = p.id and sl.warehouse_id = p_warehouse
   where p.company_id = cid and p.item_type = 'stock' and p.active and (p_category is null or p.category = p_category)
   order by p.name;
  return v;
end $$;

-- Site stocktakes: differences are the project's wastage (5200, tagged to the project); the project manager approves up to the company limit.
create or replace function public.post_stock_count(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c stock_counts; l record; p products; v_now numeric; v_diff numeric; v_gain numeric := 0; v_loss numeric := 0; n int := 0; v_je uuid; v_proj uuid; v_acct boolean; v_other uuid;
begin
  select * into c from stock_counts where id = p_id for update;
  if not found then raise exception 'Stock count not found'; end if;
  v_acct := has_role(c.company_id, array['owner','admin','accountant']);
  select case when kind = 'site' then project_id end into v_proj from warehouses where id = c.warehouse_id;
  if not (v_acct or (v_proj is not null and can_manage_project(v_proj))) then raise exception 'Only an accountant, or the project manager for a site store, can post a stocktake'; end if;
  if c.status <> 'draft' then raise exception '% is already posted', c.number; end if;
  if exists (select 1 from stock_count_lines where count_id = p_id and counted_qty is null) then
    raise exception 'Enter a counted quantity on every line (enter 0 for none found), or remove lines you did not count';
  end if;
  perform set_config('sika.posting','on', true);
  for l in select * from stock_count_lines where count_id = p_id loop
    select * into p from products where id = l.product_id for update;
    select coalesce(sum(qty), 0) into v_now from stock_levels where product_id = p.id and warehouse_id = c.warehouse_id;
    v_diff := l.counted_qty - v_now;
    update stock_count_lines set unit_cost = p.cost where id = l.id;
    continue when v_diff = 0;
    update products set stock_qty = stock_qty + v_diff where id = p.id;
    insert into stock_moves (company_id, product_id, warehouse_id, move_date, qty, unit_cost, reason, ref_type, ref_id)
    values (c.company_id, p.id, c.warehouse_id, c.count_date, v_diff, p.cost, 'Stocktake ' || c.number, 'stock_count', c.id);
    if v_diff > 0 then v_gain := v_gain + round(v_diff * p.cost, 2); else v_loss := v_loss + round(-v_diff * p.cost, 2); end if;
    n := n + 1;
  end loop;
  if not v_acct and v_gain + v_loss > (select site_count_limit from companies where id = c.company_id) then
    raise exception 'The differences total GH₵ % (gains % and losses %), more than the GH₵ % a project manager can approve. Ask an accountant to post this count.',
      v_gain + v_loss, v_gain, v_loss, (select site_count_limit from companies where id = c.company_id);
  end if;
  v_other := case when v_proj is not null then acct(c.company_id,'project_materials') else acct(c.company_id,'stock_adj') end;
  update stock_counts set status = 'posted' where id = p_id;
  if v_gain + v_loss > 0 then
    v_je := post_journal(c.company_id, c.count_date, 'Stocktake ' || c.number || ' at ' || (select name from warehouses where id = c.warehouse_id),
      jsonb_build_array(jl(acct(c.company_id,'inventory'), v_gain, v_loss), jl(v_other, v_loss, v_gain) || jsonb_build_object('project_id', v_proj)), 'stock_count', c.id);
    update stock_counts set journal_entry_id = v_je where id = p_id;
  end if;
  perform set_config('sika.posting','off', true);
  return jsonb_build_object('lines_adjusted', n, 'gain', v_gain, 'loss', v_loss);
end $$;

-- ---------------------------------------------------------------- 5. Document control
create table public.doc_types (
  code text primary key,
  grp text not null,
  name text not null,
  prefix text not null,
  client_review boolean not null default false,   -- goes to the client or consultant for approval
  has_expiry boolean not null default false,
  sort int not null default 0
);
insert into public.doc_types (code, grp, name, prefix, client_review, has_expiry, sort) values
 ('contract','contract','Contract','CON',false,false,10), ('scope','contract','Scope of work','SOW',true,false,11), ('boq','contract','Bill of quantities','BOQ',true,false,12),
 ('variation','contract','Variation or change order','VO',true,false,13), ('instruction','contract','Client instruction','CI',false,false,14),
 ('shop_drawing','engineering','Shop drawing','SD',true,false,20), ('design_drawing','engineering','Design drawing','DWG',true,false,21),
 ('as_built','engineering','As-built drawing','ABD',true,false,22), ('calculation','engineering','Calculation','CAL',true,false,23),
 ('specification','engineering','Specification','SPC',false,false,24), ('datasheet','engineering','Datasheet','DS',false,false,25),
 ('method_statement','quality','Method statement','MS',true,false,30), ('itp','quality','Inspection and test plan','ITP',true,false,31),
 ('test_report','quality','Test report','TST',false,false,32), ('submittal','quality','Material submittal','MSA',true,false,33), ('ncr','quality','Non-conformance report','NCR',false,false,34),
 ('risk_assessment','hse','Risk assessment','RA',true,false,40), ('permit','hse','Permit to work','PTW',false,true,41), ('toolbox','hse','Toolbox talk','TBT',false,false,42),
 ('incident','hse','Incident report','INC',false,false,43), ('hse_inspection','hse','Safety inspection','HSI',false,false,44), ('insurance','hse','Insurance certificate','INS',false,true,45),
 ('diary','site','Daily site diary','SDY',false,false,50), ('photo','site','Site photos','PHO',false,false,51), ('delivery_note','site','Delivery note','DN',false,false,52),
 ('minutes','site','Minutes of meeting','MOM',false,false,53), ('rfi','site','Request for information','RFI',true,false,54),
 ('om_manual','handover','O&M manual','OMM',true,false,60), ('warranty','handover','Warranty','WAR',false,true,61), ('certificate','handover','Test certificate','CER',false,true,62),
 ('handover_cert','handover','Handover certificate','HOC',true,false,63), ('snag_list','handover','Snag list','SNG',false,false,64),
 ('other','other','Other','DOC',false,false,90)
on conflict (code) do nothing;
alter table public.doc_types enable row level security;
create policy "everyone reads document types" on public.doc_types for select using (auth.uid() is not null);

create table public.doc_register (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  project_id uuid not null references public.projects(id) on delete cascade,
  doc_type text not null references public.doc_types(code),
  seq int not null,
  number text not null,
  title text not null,
  description text,
  discipline text,                    -- civil, electrical, mechanical …
  task_id uuid references public.tasks(id) on delete set null,
  owner_id uuid default auth.uid(),
  expires_on date,
  confidential boolean not null default false,
  created_at timestamptz not null default now(),
  unique (project_id, doc_type, seq)
);
create index on public.doc_register (company_id, number);

create table public.doc_revisions (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  doc_id uuid not null references public.doc_register(id) on delete cascade,
  seq int not null,
  rev text not null,
  storage_path text,
  file_name text,
  size_bytes bigint,
  mime text,
  notes text,
  status text not null default 'draft' check (status in ('draft','in_review','ready','submitted','approved','approved_comments','rejected','for_info')),
  issued_for_construction boolean not null default false,
  uploaded_by uuid default auth.uid(),
  uploaded_email text,
  created_at timestamptz not null default now(),
  submitted_at timestamptz,
  reviewed_by uuid, reviewed_email text, reviewed_at timestamptz, review_note text,
  client_comments text, client_responded_at date,
  superseded_at timestamptz,
  unique (doc_id, seq)
);
create index on public.doc_revisions (doc_id);

create or replace function public.doc_register_defaults() returns trigger
language plpgsql security definer set search_path = public as $$
declare pj projects;
begin
  select * into pj from projects where id = new.project_id;
  new.company_id := pj.company_id;
  if tg_op = 'INSERT' then
    perform pg_advisory_xact_lock(hashtext(new.project_id::text || new.doc_type));
    new.seq := coalesce((select max(seq) from doc_register where project_id = new.project_id and doc_type = new.doc_type), 0) + 1;
    new.number := coalesce(pj.number, 'PRJ') || '-' || (select prefix from doc_types where code = new.doc_type) || '-' || lpad(new.seq::text, 4, '0');
  elsif (new.doc_type, new.project_id) is distinct from (old.doc_type, old.project_id) then
    raise exception 'A document''s type and project cannot change once it has a number. Add a new document instead.';
  else new.seq := old.seq; new.number := old.number;
  end if;
  return new;
end $$;
create trigger doc_register_defaults before insert or update on public.doc_register for each row execute function public.doc_register_defaults();
create trigger doc_register_closed_project before insert on public.doc_register for each row execute function public.closed_project_guard();

create or replace function public.doc_revision_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    if coalesce(current_setting('sika.docs', true), '') <> 'on' then raise exception 'Use Upload new revision'; end if;
  elsif tg_op = 'UPDATE' and coalesce(current_setting('sika.docs', true), '') <> 'on'
        and (new.status, new.rev, new.storage_path, new.superseded_at) is distinct from (old.status, old.rev, old.storage_path, old.superseded_at) then
    raise exception 'Use Submit, Review or a transmittal to change a revision';
  elsif tg_op = 'DELETE' and old.status <> 'draft' and coalesce(current_setting('sika.docs', true), '') <> 'on' then
    raise exception 'Only a draft revision can be deleted';
  end if;
  return coalesce(new, old);
end $$;
create trigger doc_revisions_guard before insert or update or delete on public.doc_revisions for each row execute function public.doc_revision_guard();

create or replace function public.can_see_doc(p_doc uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from doc_register d where d.id = p_doc and is_member(d.company_id)
    and (not d.confidential or can_manage_project(d.project_id) or has_role(d.company_id, array['owner','admin','accountant']) or d.owner_id = auth.uid()));
$$;

-- A new revision: A, B, C … while in design; 0, 1, 2 … once issued for construction. Older revisions are superseded.
create or replace function public.add_revision(p_doc uuid, p_path text, p_name text, p_size bigint default null, p_mime text default null,
  p_notes text default null, p_issue boolean default false, p_for_info boolean default false)
returns uuid language plpgsql security definer set search_path = public as $$
declare d doc_register; last doc_revisions; v_rev text; v_id uuid;
begin
  select * into d from doc_register where id = p_doc for update;
  if not found then raise exception 'Document not found'; end if;
  if not (on_project_team(d.project_id) or has_role(d.company_id, array['owner','admin','accountant'])) then raise exception 'Only the project team can add revisions'; end if;
  if (select status from projects where id = d.project_id) in ('closed','cancelled') then raise exception 'This project is closed. Reopen it to add documents.'; end if;
  if p_path is not null and split_part(p_path, '/', 1) <> d.company_id::text then raise exception 'The file was not stored in this company''s folder'; end if;
  select * into last from doc_revisions where doc_id = p_doc order by seq desc limit 1;
  v_rev := case
    when last.id is null then case when p_issue then '0' else 'A' end
    when last.rev ~ '^[0-9]+$' then (last.rev::int + 1)::text
    when p_issue then '0'
    when last.rev ~ '^[A-Y]$' then chr(ascii(last.rev) + 1)
    else last.rev || 'A' end;
  perform set_config('sika.docs','on', true);
  update doc_revisions set superseded_at = now() where doc_id = p_doc and superseded_at is null;
  insert into doc_revisions (company_id, doc_id, seq, rev, storage_path, file_name, size_bytes, mime, notes, status, issued_for_construction, uploaded_email)
  values (d.company_id, p_doc, coalesce(last.seq, 0) + 1, v_rev, p_path, p_name, p_size, p_mime, p_notes,
          case when p_for_info then 'for_info' else 'draft' end, p_issue or v_rev ~ '^[0-9]+$', (select email from auth.users where id = auth.uid()))
  returning id into v_id;
  perform set_config('sika.docs','off', true);
  return v_id;
end $$;

create or replace function public.submit_revision(p_rev uuid) returns void
language plpgsql security definer set search_path = public as $$
declare r doc_revisions; d doc_register;
begin
  select * into r from doc_revisions where id = p_rev for update;
  select * into d from doc_register where id = r.doc_id;
  if not (on_project_team(d.project_id) or has_role(d.company_id, array['owner','admin','accountant'])) then raise exception 'Only the project team can submit documents'; end if;
  if r.status not in ('draft','rejected') then raise exception 'Revision % is already %', r.rev, replace(r.status, '_', ' '); end if;
  if r.superseded_at is not null then raise exception 'A newer revision exists. Submit that one.'; end if;
  perform set_config('sika.docs','on', true);
  update doc_revisions set status = 'in_review', submitted_at = now() where id = p_rev;
  perform set_config('sika.docs','off', true);
end $$;

-- Internal check by the project manager (or owner/admin). Documents the client approves become "ready to send".
create or replace function public.review_revision(p_rev uuid, p_approve boolean, p_note text default null) returns text
language plpgsql security definer set search_path = public as $$
declare r doc_revisions; d doc_register; v_to text;
begin
  select * into r from doc_revisions where id = p_rev for update;
  select * into d from doc_register where id = r.doc_id;
  if not (can_manage_project(d.project_id) or has_role(d.company_id, array['owner','admin'])) then raise exception 'Only the project manager can review documents'; end if;
  if r.status <> 'in_review' then raise exception 'Revision % is not waiting for review', r.rev; end if;
  if not p_approve and coalesce(trim(p_note), '') = '' then raise exception 'Say what needs to change'; end if;
  v_to := case when not p_approve then 'rejected' when (select client_review from doc_types where code = d.doc_type) then 'ready' else 'approved' end;
  perform set_config('sika.docs','on', true);
  update doc_revisions set status = v_to, reviewed_by = auth.uid(), reviewed_email = (select email from auth.users where id = auth.uid()), reviewed_at = now(), review_note = p_note where id = p_rev;
  perform set_config('sika.docs','off', true);
  return v_to;
end $$;

-- Transmittals: what was sent to the client or consultant, why, and what came back.
create table public.transmittals (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  project_id uuid not null references public.projects(id) on delete cascade,
  number text,
  to_party text not null,
  to_person text,
  to_email text,
  purpose text not null default 'for_approval' check (purpose in ('for_approval','for_comment','for_information','for_construction','for_record')),
  sent_date date,
  response_due date,
  status text not null default 'draft' check (status in ('draft','sent','responded','closed')),
  notes text,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);
create table public.transmittal_items (
  id uuid primary key default gen_random_uuid(),
  transmittal_id uuid not null references public.transmittals(id) on delete cascade,
  company_id uuid not null references public.companies(id) on delete cascade,
  revision_id uuid not null references public.doc_revisions(id),
  copies int not null default 1,
  response text check (response in ('approved','approved_comments','rejected','noted')),
  comments text,
  responded_at date,
  unique (transmittal_id, revision_id)
);
create or replace function public.transmittal_defaults() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    new.company_id := (select company_id from projects where id = new.project_id);
    new.number := coalesce(new.number, (select coalesce(number, 'PRJ') from projects where id = new.project_id) || '-' || next_number(new.company_id, 'TRN', 'TRN-'));
    new.status := 'draft';
  elsif new.status is distinct from old.status and coalesce(current_setting('sika.docs', true), '') <> 'on' then
    raise exception 'Use Send or Record response';
  end if;
  return new;
end $$;
create trigger transmittals_defaults before insert or update on public.transmittals for each row execute function public.transmittal_defaults();
create trigger transmittals_closed_project before insert on public.transmittals for each row execute function public.closed_project_guard();
create or replace function public.transmittal_item_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if (select status from transmittals where id = coalesce(new.transmittal_id, old.transmittal_id)) <> 'draft' and coalesce(current_setting('sika.docs', true), '') <> 'on' then
    raise exception 'This transmittal has been sent. Record responses instead.';
  end if;
  if tg_op <> 'DELETE' and (select d.project_id from doc_revisions r join doc_register d on d.id = r.doc_id where r.id = new.revision_id)
     is distinct from (select project_id from transmittals where id = new.transmittal_id) then raise exception 'Only this project''s documents can go on its transmittal'; end if;
  return coalesce(new, old);
end $$;
create trigger transmittal_items_guard before insert or update or delete on public.transmittal_items for each row execute function public.transmittal_item_guard();

create or replace function public.send_transmittal(p_id uuid, p_date date default current_date, p_due date default null) returns text
language plpgsql security definer set search_path = public as $$
declare t transmittals; bad text;
begin
  select * into t from transmittals where id = p_id for update;
  if not found then raise exception 'Transmittal not found'; end if;
  if not (on_project_team(t.project_id) or has_role(t.company_id, array['owner','admin'])) then raise exception 'Only the project team can send transmittals'; end if;
  if t.status <> 'draft' then raise exception '% has already been sent', t.number; end if;
  if not exists (select 1 from transmittal_items where transmittal_id = p_id) then raise exception 'Add at least one document'; end if;
  select string_agg(d.number || ' rev ' || r.rev, ', ') into bad from transmittal_items i join doc_revisions r on r.id = i.revision_id join doc_register d on d.id = r.doc_id
   where i.transmittal_id = p_id and (r.status in ('draft','in_review','rejected') or (t.purpose = 'for_construction' and r.status not in ('approved','approved_comments')));
  if bad is not null then raise exception 'Not ready to send: % (%)', bad, case when t.purpose = 'for_construction' then 'only approved documents can be issued for construction' else 'review them first' end; end if;
  perform set_config('sika.docs','on', true);
  update transmittals set status = case when purpose in ('for_approval','for_comment') then 'sent' else 'closed' end, sent_date = p_date,
         response_due = case when purpose in ('for_approval','for_comment') then coalesce(p_due, p_date + 14) end where id = p_id;
  if t.purpose in ('for_approval','for_comment') then
    update doc_revisions set status = 'submitted' where id in (select revision_id from transmittal_items where transmittal_id = p_id) and status in ('ready','approved');
  elsif t.purpose = 'for_construction' then
    update doc_revisions set issued_for_construction = true where id in (select revision_id from transmittal_items where transmittal_id = p_id);
  end if;
  perform set_config('sika.docs','off', true);
  return t.number;
end $$;

create or replace function public.record_response(p_item uuid, p_response text, p_comments text default null, p_date date default current_date) returns void
language plpgsql security definer set search_path = public as $$
declare i transmittal_items; t transmittals;
begin
  select * into i from transmittal_items where id = p_item for update;
  select * into t from transmittals where id = i.transmittal_id for update;
  if not (on_project_team(t.project_id) or has_role(t.company_id, array['owner','admin'])) then raise exception 'Only the project team can record responses'; end if;
  if t.status not in ('sent','responded') then raise exception 'Send the transmittal first'; end if;
  if p_response not in ('approved','approved_comments','rejected','noted') then raise exception 'Unknown response'; end if;
  if p_response in ('approved_comments','rejected') and coalesce(trim(p_comments), '') = '' then raise exception 'Enter the client''s comments'; end if;
  perform set_config('sika.docs','on', true);
  update transmittal_items set response = p_response, comments = p_comments, responded_at = p_date where id = p_item;
  update doc_revisions set status = case p_response when 'noted' then 'for_info' else p_response end, client_comments = p_comments, client_responded_at = p_date
   where id = i.revision_id and status = 'submitted';
  if not exists (select 1 from transmittal_items where transmittal_id = t.id and response is null) then update transmittals set status = 'responded' where id = t.id; end if;
  perform set_config('sika.docs','off', true);
end $$;

-- Every time a file is opened, it is written to the audit trail.
create or replace function public.log_doc_access(p_rev uuid) returns void
language plpgsql security definer set search_path = public as $$
declare r doc_revisions; d doc_register;
begin
  select * into r from doc_revisions where id = p_rev;
  select * into d from doc_register where id = r.doc_id;
  if not can_see_doc(d.id) then raise exception 'You cannot open this document'; end if;
  insert into audit_log (company_id, action, table_name, row_id, detail) values (d.company_id, 'document.opened', 'doc_revisions', r.id,
    jsonb_build_object('number', d.number, 'rev', r.rev, 'file', r.file_name));
end $$;

-- ---------------------------------------------------------------- 6. Risk assessments
create table public.risk_assessments (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  project_id uuid not null references public.projects(id) on delete cascade,
  number text,
  version int not null default 1,
  title text not null,
  activity text,
  location text,
  task_id uuid references public.tasks(id) on delete set null,
  assessed_by uuid default auth.uid(),
  assessed_email text,
  assessed_on date not null default current_date,
  review_date date,
  status text not null default 'draft' check (status in ('draft','approved')),
  pm_signed_by uuid, pm_signed_email text, pm_signed_at timestamptz,
  hse_signed_by uuid, hse_signed_email text, hse_signed_at timestamptz,
  notes text,
  created_at timestamptz not null default now()
);
create table public.risk_items (
  id uuid primary key default gen_random_uuid(),
  ra_id uuid not null references public.risk_assessments(id) on delete cascade,
  company_id uuid not null references public.companies(id) on delete cascade,
  hazard text not null,
  consequence text,
  who_at_risk text,
  likelihood int not null check (likelihood between 1 and 5),
  severity int not null check (severity between 1 and 5),
  controls text,
  owner text,
  residual_likelihood int check (residual_likelihood between 1 and 5),
  residual_severity int check (residual_severity between 1 and 5),
  sort int not null default 0
);
create or replace function public.risk_band(score int) returns text language sql immutable as $$
  select case when score >= 15 then 'high' when score >= 5 then 'medium' else 'low' end;
$$;
create or replace function public.ra_defaults() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    new.company_id := (select company_id from projects where id = new.project_id);
    new.number := coalesce(new.number, next_number(new.company_id, 'RA', 'RA-'));
    new.assessed_email := (select email from auth.users where id = coalesce(new.assessed_by, auth.uid()));
    new.status := 'draft';
  elsif coalesce(current_setting('sika.docs', true), '') <> 'on' and (old.status = 'approved' or new.status is distinct from old.status
        or (new.pm_signed_by, new.hse_signed_by) is distinct from (old.pm_signed_by, old.hse_signed_by)) then
    raise exception 'A signed risk assessment cannot be changed. Use Revise to start a new version.';
  end if;
  return new;
end $$;
create trigger risk_assessments_defaults before insert or update on public.risk_assessments for each row execute function public.ra_defaults();
create trigger risk_assessments_closed_project before insert on public.risk_assessments for each row execute function public.closed_project_guard();
create or replace function public.risk_item_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if (select status from risk_assessments where id = coalesce(new.ra_id, old.ra_id)) <> 'draft' and coalesce(current_setting('sika.docs', true), '') <> 'on' then
    raise exception 'A signed risk assessment cannot be changed. Use Revise to start a new version.';
  end if;
  if tg_op <> 'DELETE' then new.company_id := (select company_id from risk_assessments where id = new.ra_id); end if;
  return coalesce(new, old);
end $$;
create trigger risk_items_guard before insert or update or delete on public.risk_items for each row execute function public.risk_item_guard();

-- Sign as project manager ('pm') or health and safety officer ('hse'). Both signatures approve it.
create or replace function public.sign_risk_assessment(p_id uuid, p_as text) returns text
language plpgsql security definer set search_path = public as $$
declare a risk_assessments; pj projects; v_email text;
begin
  select * into a from risk_assessments where id = p_id for update;
  if not found then raise exception 'Risk assessment not found'; end if;
  select * into pj from projects where id = a.project_id;
  if a.status <> 'draft' then raise exception '% is already approved', a.number; end if;
  if not exists (select 1 from risk_items where ra_id = p_id) then raise exception 'Add at least one hazard'; end if;
  if exists (select 1 from risk_items where ra_id = p_id and coalesce(trim(controls), '') = '') then raise exception 'Every hazard needs its control measures'; end if;
  if exists (select 1 from risk_items where ra_id = p_id and risk_band(likelihood * severity) = 'high' and (residual_likelihood is null or residual_severity is null)) then
    raise exception 'Rate the risk left after controls for every high risk';
  end if;
  v_email := (select email from auth.users where id = auth.uid());
  perform set_config('sika.docs','on', true);
  if p_as = 'pm' then
    if not can_manage_project(a.project_id) then raise exception 'Only the project manager can sign as project manager'; end if;
    update risk_assessments set pm_signed_by = auth.uid(), pm_signed_email = v_email, pm_signed_at = now() where id = p_id;
  elsif p_as = 'hse' then
    if not (auth.uid() = pj.hse_officer_id or (pj.hse_officer_id is null and has_role(a.company_id, array['owner','admin']))) then
      raise exception 'Only the project''s health and safety officer can sign here (set one on the project)';
    end if;
    update risk_assessments set hse_signed_by = auth.uid(), hse_signed_email = v_email, hse_signed_at = now() where id = p_id;
  else raise exception 'Sign as pm or hse';
  end if;
  update risk_assessments set status = 'approved' where id = p_id and pm_signed_by is not null and hse_signed_by is not null;
  perform set_config('sika.docs','off', true);
  return (select status from risk_assessments where id = p_id);
end $$;

create or replace function public.revise_risk_assessment(p_id uuid, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare a risk_assessments;
begin
  select * into a from risk_assessments where id = p_id for update;
  if not (on_project_team(a.project_id) or has_role(a.company_id, array['owner','admin'])) then raise exception 'Only the project team can revise this'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Give the reason for the revision'; end if;
  perform set_config('sika.docs','on', true);
  update risk_assessments set status = 'draft', version = version + 1, pm_signed_by = null, pm_signed_email = null, pm_signed_at = null,
         hse_signed_by = null, hse_signed_email = null, hse_signed_at = null,
         notes = coalesce(notes || E'\n', '') || 'Version ' || (version + 1) || ' (' || to_char(current_date, 'DD Mon YYYY') || '): ' || p_reason where id = p_id;
  perform set_config('sika.docs','off', true);
end $$;

-- ---------------------------------------------------------------- 7. Documents a project must have
create table public.project_doc_requirements (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  project_id uuid not null references public.projects(id) on delete cascade,
  doc_type text not null references public.doc_types(code),
  stage text not null check (stage in ('start','close')),
  note text,
  unique (project_id, doc_type, stage)
);
create trigger project_doc_requirements_defaults before insert or update on public.project_doc_requirements for each row execute function public.material_plan_defaults();

create or replace function public.standard_doc_requirements(p_project uuid) returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not can_manage_project(p_project) then raise exception 'Only the project manager can set the required documents'; end if;
  insert into project_doc_requirements (project_id, doc_type, stage, note) values
    (p_project, 'risk_assessment', 'start', 'Approved before work starts'), (p_project, 'method_statement', 'start', 'Approved before work starts'),
    (p_project, 'as_built', 'close', null), (p_project, 'om_manual', 'close', null), (p_project, 'certificate', 'close', 'Test certificates'),
    (p_project, 'handover_cert', 'close', 'Signed by the client')
  on conflict do nothing;
  get diagnostics n = row_count;
  return n;
end $$;

-- Is each required document in place? A document counts once its current revision is approved (or filed for information).
create or replace function public.project_doc_check(p_project uuid)
returns table (doc_type text, name text, stage text, note text, satisfied boolean, docs bigint)
language sql stable security definer set search_path = public as $$
  select q.doc_type, t.name, q.stage, q.note,
    exists (select 1 from doc_register d join doc_revisions r on r.doc_id = d.id and r.superseded_at is null
             where d.project_id = p_project and d.doc_type = q.doc_type and r.status in ('approved','approved_comments','for_info'))
    or (q.doc_type = 'risk_assessment' and exists (select 1 from risk_assessments a where a.project_id = p_project and a.status = 'approved')),
    (select count(*) from doc_register d where d.project_id = p_project and d.doc_type = q.doc_type)
  from project_doc_requirements q join doc_types t on t.code = q.doc_type
  where q.project_id = p_project and exists (select 1 from projects p where p.id = p_project and is_member(p.company_id))
  order by q.stage desc, t.sort;
$$;

-- Permits, insurances, warranties and certificates that have run out or will soon.
create or replace function public.doc_expiry_alerts(cid uuid, p_days int default 30)
returns table (doc_id uuid, number text, title text, doc_type text, project_id uuid, project text, expires_on date, days_left int)
language sql stable security definer set search_path = public as $$
  select d.id, d.number, d.title, t.name, p.id, coalesce(p.number || ' ', '') || p.name, d.expires_on, d.expires_on - current_date
    from doc_register d join doc_types t on t.code = d.doc_type join projects p on p.id = d.project_id
   where d.company_id = cid and d.expires_on is not null and d.expires_on <= current_date + p_days and p.status not in ('closed','cancelled')
     and can_see_doc(d.id)
   order by d.expires_on;
$$;

-- Search documents across every project.
create or replace function public.search_documents(cid uuid, p_search text default null, p_type text default null, p_status text default null,
  p_project uuid default null, p_limit int default 50, p_offset int default 0)
returns table (doc_id uuid, number text, title text, doc_type text, type_name text, grp text, project_id uuid, project text, rev text, status text,
               revision_id uuid, updated_at timestamptz, expires_on date, confidential boolean, total bigint)
language sql stable security definer set search_path = public as $$
  with x as (
    select d.*, t.name type_name, t.grp, coalesce(p.number || ' ', '') || p.name project_name, r.rev, r.status rstatus, r.id rid, coalesce(r.created_at, d.created_at) upd
      from doc_register d join doc_types t on t.code = d.doc_type join projects p on p.id = d.project_id
      left join lateral (select * from doc_revisions r where r.doc_id = d.id order by seq desc limit 1) r on true
     where d.company_id = cid and can_see_doc(d.id)
       and (p_project is null or d.project_id = p_project) and (p_type is null or d.doc_type = p_type or t.grp = p_type)
       and (p_status is null or r.status = p_status or (p_status = 'none' and r.id is null))
       and (p_search is null or d.number ilike '%' || p_search || '%' or d.title ilike '%' || p_search || '%' or coalesce(d.discipline, '') ilike '%' || p_search || '%'
            or coalesce(r.file_name, '') ilike '%' || p_search || '%'))
  select id, number, title, doc_type, type_name, grp, project_id, project_name, rev, rstatus, rid, upd, expires_on, confidential, count(*) over ()
    from x order by upd desc limit p_limit offset p_offset;
$$;

-- Existing project files move into the register as "Other" documents, filed for information.
do $$ declare f record; v_doc uuid; begin
  for f in select * from project_documents order by created_at loop
    insert into doc_register (company_id, project_id, doc_type, seq, number, title, owner_id, created_at)
    values (f.company_id, f.project_id, 'other', 0, '', f.name, f.uploaded_by, f.created_at) returning id into v_doc;
    perform set_config('sika.docs','on', true);
    insert into doc_revisions (company_id, doc_id, seq, rev, storage_path, file_name, size_bytes, status, uploaded_by, created_at)
    values (f.company_id, v_doc, 1, 'A', f.storage_path, f.name, f.size_bytes, 'for_info', f.uploaded_by, f.created_at);
    perform set_config('sika.docs','off', true);
  end loop;
end $$;

do $$ begin
  if exists (select 1 from information_schema.schemata where schema_name = 'storage') then
    execute $q$update storage.buckets set file_size_limit = 52428800 where id = 'project-docs'$q$;
  end if;
end $$;

-- ---------------------------------------------------------------- 8. Close-out checks now cover the site store and documents
alter function public.project_close_check(uuid) rename to project_close_check_v21;
create or replace function public.project_close_check(p_project uuid)
returns table (item text, n bigint, amount numeric, severity text, hint text)
language sql stable security definer set search_path = public as $$
  select * from project_close_check_v21(p_project)
  union all select * from (
    select 'Stock still in the site store'::text item,
      (select count(*) from stock_levels sl join warehouses w on w.id = sl.warehouse_id where w.project_id = p_project and sl.qty <> 0) n,
      (select round(sum(sl.qty * p.cost), 2) from stock_levels sl join warehouses w on w.id = sl.warehouse_id join products p on p.id = sl.product_id where w.project_id = p_project) amount,
      'block'::text severity, 'Site store: send it back to the main store, transfer it to another project, or count it out'::text hint
    union all select 'Stock requests not yet received', (select count(*) from stock_requests where project_id = p_project and status in ('submitted','dispatched')), null,
      'block', 'Site store: receive or cancel them'
    union all select 'Handover documents missing', (select count(*) from project_doc_check(p_project) where stage = 'close' and not satisfied), null,
      'block', 'Documents: upload and approve them'
    union all select 'Documents waiting for the client''s response', (select count(*) from doc_revisions r join doc_register d on d.id = r.doc_id
        where d.project_id = p_project and r.status = 'submitted' and r.superseded_at is null), null, 'warn', 'Documents: record the responses'
    union all select 'Risk assessments not signed off', (select count(*) from risk_assessments where project_id = p_project and status = 'draft'), null,
      'warn', 'Risk assessments: sign them or delete drafts'
  ) x where x.n > 0
$$;
revoke execute on function public.project_close_check_v21(uuid) from public, anon, authenticated;

-- Projects made from a template copy its required documents and materials plan.
alter function public.create_project_from_template(uuid, text, uuid, date, uuid) rename to create_project_from_template_v13;
create or replace function public.create_project_from_template(p_template uuid, p_name text, p_customer uuid, p_start date, p_sales_order uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  v := create_project_from_template_v13(p_template, p_name, p_customer, p_start, p_sales_order);
  insert into project_doc_requirements (project_id, doc_type, stage, note) select v, doc_type, stage, note from project_doc_requirements where project_id = p_template;
  insert into project_material_plan (project_id, product_id, planned_qty, note) select v, product_id, planned_qty, note from project_material_plan where project_id = p_template;
  return v;
end $$;
revoke execute on function public.create_project_from_template_v13(uuid, text, uuid, date, uuid) from public, anon, authenticated;

-- Nothing new for a closed project
do $$ declare t text; begin
  foreach t in array array['stock_requests','project_material_plan','project_doc_requirements'] loop
    execute format('create trigger %I before insert on public.%I for each row execute function public.closed_project_guard()', t || '_closed_project', t);
  end loop;
end $$;

-- ---------------------------------------------------------------- 9. Row-level security
-- Store documents: the store and accountants anywhere; a project's team in its own site store.
drop policy if exists "store and managers write issues" on public.stock_issues;
create policy "store and project team write issues" on public.stock_issues for all
  using (has_role(company_id, array['owner','admin','accountant','store']) or (project_id is not null and on_project_team(project_id) and can_use_store(warehouse_id)))
  with check (has_role(company_id, array['owner','admin','accountant','store']) or (project_id is not null and on_project_team(project_id) and can_use_store(warehouse_id)));
drop policy if exists "store and managers write issue lines" on public.stock_issue_lines;
create policy "store and project team write issue lines" on public.stock_issue_lines for all
  using (exists (select 1 from stock_issues s where s.id = issue_id and (has_role(s.company_id, array['owner','admin','accountant','store']) or (s.project_id is not null and on_project_team(s.project_id) and can_use_store(s.warehouse_id)))))
  with check (exists (select 1 from stock_issues s where s.id = issue_id and (has_role(s.company_id, array['owner','admin','accountant','store']) or (s.project_id is not null and on_project_team(s.project_id) and can_use_store(s.warehouse_id)))));
drop policy if exists "store writes" on public.stock_transfers;
create policy "store writes" on public.stock_transfers for all using (can_use_store(from_warehouse_id)) with check (can_use_store(from_warehouse_id));
drop policy if exists "store writes" on public.stock_transfer_lines;
create policy "store writes" on public.stock_transfer_lines for all
  using (exists (select 1 from stock_transfers t where t.id = transfer_id and can_use_store(t.from_warehouse_id)))
  with check (exists (select 1 from stock_transfers t where t.id = transfer_id and can_use_store(t.from_warehouse_id)));
drop policy if exists "store writes" on public.stock_counts;
create policy "store writes" on public.stock_counts for all using (can_use_store(warehouse_id)) with check (can_use_store(warehouse_id));
drop policy if exists "store writes" on public.stock_count_lines;
create policy "store writes" on public.stock_count_lines for all
  using (exists (select 1 from stock_counts c where c.id = count_id and can_use_store(c.warehouse_id)))
  with check (exists (select 1 from stock_counts c where c.id = count_id and can_use_store(c.warehouse_id)));
create policy "project team sets bins" on public.stock_levels for update using (can_use_store(warehouse_id));

alter table public.stock_requests enable row level security;
alter table public.stock_request_lines enable row level security;
create policy "members read requests" on public.stock_requests for select using (is_member(company_id));
create policy "team raises requests" on public.stock_requests for insert with check (on_project_team(project_id) or has_role(company_id, array['owner','admin','accountant','store']));
create policy "team edits requests" on public.stock_requests for update using (on_project_team(project_id) or has_role(company_id, array['owner','admin','accountant','store']));
create policy "team deletes draft requests" on public.stock_requests for delete using (status = 'draft' and (on_project_team(project_id) or has_role(company_id, array['owner','admin','accountant','store'])));
create policy "members read request lines" on public.stock_request_lines for select using (is_member(company_id));
create policy "team writes request lines" on public.stock_request_lines for all
  using (exists (select 1 from stock_requests r where r.id = request_id and (on_project_team(r.project_id) or has_role(r.company_id, array['owner','admin','accountant','store']))))
  with check (exists (select 1 from stock_requests r where r.id = request_id and (on_project_team(r.project_id) or has_role(r.company_id, array['owner','admin','accountant','store']))));

alter table public.project_material_plan enable row level security;
create policy "members read plan" on public.project_material_plan for select using (is_member(company_id));
create policy "managers write plan" on public.project_material_plan for all using (can_manage_project(project_id)) with check (can_manage_project(project_id));
alter table public.project_doc_requirements enable row level security;
create policy "members read requirements" on public.project_doc_requirements for select using (is_member(company_id));
create policy "managers write requirements" on public.project_doc_requirements for all using (can_manage_project(project_id)) with check (can_manage_project(project_id));

alter table public.doc_register enable row level security;
alter table public.doc_revisions enable row level security;
create policy "members read documents" on public.doc_register for select using (can_see_doc(id));
create policy "team adds documents" on public.doc_register for insert with check (on_project_team(project_id) or has_role(company_id, array['owner','admin','accountant']));
create policy "team edits documents" on public.doc_register for update using (on_project_team(project_id) or has_role(company_id, array['owner','admin','accountant']));
create policy "managers delete documents" on public.doc_register for delete using ((can_manage_project(project_id) or has_role(company_id, array['owner','admin']))
  and not exists (select 1 from doc_revisions r where r.doc_id = id and r.status not in ('draft')));
create policy "members read revisions" on public.doc_revisions for select using (can_see_doc(doc_id));
create policy "team edits revision notes" on public.doc_revisions for update using (exists (select 1 from doc_register d where d.id = doc_id and on_project_team(d.project_id)));
create policy "team deletes draft revisions" on public.doc_revisions for delete using (status = 'draft' and exists (select 1 from doc_register d where d.id = doc_id and on_project_team(d.project_id)));

alter table public.transmittals enable row level security;
alter table public.transmittal_items enable row level security;
create policy "members read transmittals" on public.transmittals for select using (is_member(company_id));
create policy "team writes transmittals" on public.transmittals for all using (on_project_team(project_id) or has_role(company_id, array['owner','admin']))
  with check (on_project_team(project_id) or has_role(company_id, array['owner','admin']));
create policy "members read transmittal items" on public.transmittal_items for select using (is_member(company_id));
create policy "team writes transmittal items" on public.transmittal_items for all
  using (exists (select 1 from transmittals t where t.id = transmittal_id and (on_project_team(t.project_id) or has_role(t.company_id, array['owner','admin']))))
  with check (exists (select 1 from transmittals t where t.id = transmittal_id and (on_project_team(t.project_id) or has_role(t.company_id, array['owner','admin']))));

alter table public.risk_assessments enable row level security;
alter table public.risk_items enable row level security;
create policy "members read risk assessments" on public.risk_assessments for select using (is_member(company_id));
create policy "team writes risk assessments" on public.risk_assessments for all using (on_project_team(project_id) or has_role(company_id, array['owner','admin']))
  with check (on_project_team(project_id) or has_role(company_id, array['owner','admin']));
create policy "members read risk items" on public.risk_items for select using (is_member(company_id));
create policy "team writes risk items" on public.risk_items for all
  using (exists (select 1 from risk_assessments a where a.id = ra_id and (on_project_team(a.project_id) or has_role(a.company_id, array['owner','admin']))))
  with check (exists (select 1 from risk_assessments a where a.id = ra_id and (on_project_team(a.project_id) or has_role(a.company_id, array['owner','admin']))));

-- Project team members (any role) may also upload to the project's file folder; files are read only through the register.
do $$ begin
  if exists (select 1 from information_schema.schemata where schema_name = 'storage') then
    execute $q$drop policy if exists "project docs: members delete" on storage.objects$q$;
    execute $q$create policy "project docs: managers delete" on storage.objects for delete to authenticated
      using (bucket_id = 'project-docs' and public.has_role(((storage.foldername(name))[1])::uuid, array['owner','admin']))$q$;
  end if;
end $$;

do $$ declare t text; begin
  foreach t in array array['stock_requests','doc_register','doc_revisions','transmittals','risk_assessments','project_material_plan','project_doc_requirements'] loop
    execute format('create trigger %I after insert or update or delete on public.%I for each row execute function public.audit_row()', t || '_audit', t);
  end loop;
end $$;

-- Sources in the ledger
alter function public.source_ref(text, uuid) rename to source_ref_v21;
create or replace function public.source_ref(p_type text, p_id uuid, out label text, out path text)
language plpgsql stable security definer set search_path = public as $$
begin
  if p_type = 'stock_request' then select 'Stock request ' || number, '/projects/' || project_id into label, path from stock_requests where id = p_id;
  else select s.label, s.path into label, path from source_ref_v21(p_type, p_id) s; end if;
end $$;

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
revoke execute on function public.seed_accounts_v21(uuid) from authenticated;
revoke execute on function public.seed_leave_types(uuid) from authenticated;
revoke execute on function public.seed_asset_categories(uuid) from authenticated;
revoke execute on function public.next_number(uuid,text,text) from authenticated;
revoke execute on function public.project_cost_items(uuid) from authenticated;
revoke execute on function public.project_cost_totals(uuid) from authenticated;
revoke execute on function public.finalize_expense(uuid) from authenticated;
revoke execute on function public.doc_dims(text,uuid) from authenticated;
revoke execute on function public.wh(uuid) from authenticated;
revoke execute on function public.transit_wh(uuid) from authenticated;
revoke execute on function public.ledger_checks_v20(uuid) from authenticated;
revoke execute on function public.unposted_documents_v20(uuid) from authenticated;
revoke execute on function public.project_close_check_v21(uuid) from authenticated;
revoke execute on function public.create_project_from_template_v13(uuid, text, uuid, date, uuid) from authenticated;
grant execute on function public.public_help(uuid) to anon;
grant execute on function public.submit_case_public(uuid,text,text,text,text,text) to anon;
grant execute on function public.case_status_public(text,text) to anon;
grant execute on function public.reply_case_public(text,text,text,int) to anon;


-- ======================================================================
-- 0009_asnys_v2_3.sql
-- ======================================================================
-- =====================================================================
-- Asnys ERP v2.3 — project cycle management and financial control
-- From the Project Management Meeting (project cycle management and financial control systems):
--   1. Tender register with a pre-submission review by Business Development, Finance and Engineering
--   2. Contract award -> Finance registers the project (code, cost centre) and approves its budget; no spending before that
--   3. Engineering progress reports to Finance, reporting deadlines, periodic project cost reconciliation
--   4. Milestone certification with automatic notice to Finance; billing schedule
--   5. Invoice follow-up until paid, receivables by project, financial clearance before a project closes
--   6. Notifications inbox; responsibilities and deadlines for each unit at each stage; project finance overview
-- Run after 0008.
-- =====================================================================

-- ---------------------------------------------------------------- 1. Notifications
create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  user_id uuid not null,
  kind text not null,
  title text not null,
  body text,
  path text,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  read_at timestamptz
);
create index on public.notifications (user_id, read_at, created_at desc);
alter table public.notifications enable row level security;
create policy "read own notifications" on public.notifications for select using (user_id = auth.uid());
create policy "mark own notifications" on public.notifications for update using (user_id = auth.uid());
create policy "clear own notifications" on public.notifications for delete using (user_id = auth.uid());

-- Send to everyone holding any of the roles (owners and admins always see finance and project-cycle notices), plus named users.
create or replace function public.notify(cid uuid, p_roles text[], p_users uuid[], p_kind text, p_title text, p_body text default null, p_path text default null)
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  insert into notifications (company_id, user_id, kind, title, body, path)
  select distinct cid, u, p_kind, p_title, p_body, p_path from (
    select m.user_id u from memberships m where m.company_id = cid and (m.role = any(p_roles) or m.role in ('owner','admin'))
    union select unnest(coalesce(p_users, '{}'::uuid[]))) x
  where u is not null and u is distinct from auth.uid();
  get diagnostics n = row_count;
  return n;
end $$;

-- ---------------------------------------------------------------- 2. Tenders (Business Development)
create table public.tenders (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  number text,
  title text not null,
  kind text not null default 'tender' check (kind in ('tender','rfq','quotation','eoi','prequalification','direct_award')),
  customer_id uuid references public.customers(id) on delete set null,
  client_name text,
  client_ref text,
  opportunity_id uuid references public.opportunities(id) on delete set null,
  location text,
  submission_deadline timestamptz,
  site_visit_date date,
  est_value numeric(14,2) not null default 0,     -- GHS, what we expect to bid
  est_cost numeric(14,2) not null default 0,      -- GHS, our estimated cost
  currency text not null default 'GHS',
  bid_bond_required boolean not null default false,
  bid_bond_amount numeric(14,2),
  status text not null default 'registered' check (status in ('registered','preparing','review','submitted','awarded','lost','no_bid','cancelled')),
  bd_owner_id uuid default auth.uid(),            -- Business Development
  engineering_lead_id uuid,
  finance_lead_id uuid,
  notes text,
  submitted_at date,
  submitted_value numeric(14,2),
  result_date date,
  lost_reason text,
  award_type text check (award_type in ('contract','purchase_order','letter_of_award')),
  contract_ref text,
  contract_signed_on date,
  awarded_value numeric(14,2),
  award_notes text,
  project_id uuid references public.projects(id) on delete set null,
  created_at timestamptz not null default now()
);
create table public.tender_reviews (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  tender_id uuid not null references public.tenders(id) on delete cascade,
  meeting_date date not null,
  attendees text,
  summary_shared_on date,                          -- summary report circulated before the meeting
  bd_input text, finance_input text, engineering_input text,
  decision text check (decision in ('go','no_go','revise')),
  minutes text,
  bd_ok_by uuid, bd_ok_email text, bd_ok_at timestamptz,
  finance_ok_by uuid, finance_ok_email text, finance_ok_at timestamptz,
  engineering_ok_by uuid, engineering_ok_email text, engineering_ok_at timestamptz,
  created_at timestamptz not null default now()
);
create table public.tender_files (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  tender_id uuid not null references public.tenders(id) on delete cascade,
  kind text not null default 'tender_docs' check (kind in ('tender_docs','summary','pricing','technical','submission','contract','purchase_order','minutes','other')),
  name text not null,
  storage_path text not null,
  size_bytes bigint,
  uploaded_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);

alter table public.projects add column if not exists tender_id uuid references public.tenders(id) on delete set null;

create or replace function public.tender_defaults() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    new.number := coalesce(new.number, next_number(new.company_id, 'TND', 'TND-'));
    new.status := 'registered';
    if new.client_name is null and new.customer_id is not null then new.client_name := (select name from customers where id = new.customer_id); end if;
  elsif new.status is distinct from old.status and coalesce(current_setting('sika.cycle', true), '') <> 'on' then
    raise exception 'Use the tender actions (Start preparing, Submit, Award, Lost) to change its status';
  elsif old.status in ('awarded','lost','no_bid','cancelled') and coalesce(current_setting('sika.cycle', true), '') <> 'on'
        and (new.awarded_value, new.contract_ref, new.est_value) is distinct from (old.awarded_value, old.contract_ref, old.est_value) then
    raise exception 'This tender is closed';
  end if;
  return new;
end $$;
create trigger tenders_defaults before insert or update on public.tenders for each row execute function public.tender_defaults();

-- Finance and Engineering hear about every tender as soon as it is registered.
create or replace function public.tender_registered_notice() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform notify(new.company_id, array['accountant','project_manager'], array[new.engineering_lead_id, new.finance_lead_id], 'tender.registered',
    'New ' || replace(new.kind, '_', ' ') || ' ' || new.number || ': ' || new.title,
    coalesce(new.client_name, '') || coalesce(' · deadline ' || to_char(new.submission_deadline, 'DD Mon YYYY HH24:MI'), '') ||
    case when new.est_value > 0 then ' · about GH₵ ' || to_char(new.est_value, 'FM999,999,999,990') else '' end, '/tenders/' || new.id);
  return null;
end $$;
create trigger tenders_registered after insert on public.tenders for each row execute function public.tender_registered_notice();

create or replace function public.tender_review_defaults() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    new.company_id := (select company_id from tenders where id = new.tender_id);
    perform set_config('sika.cycle','on', true);
    update tenders set status = 'review' where id = new.tender_id and status in ('registered','preparing');
    perform set_config('sika.cycle','off', true);
    perform notify(new.company_id, array['accountant','project_manager','sales'], null, 'tender.review',
      'Pre-submission review for ' || (select number || ' ' || title from tenders where id = new.tender_id) || ' on ' || to_char(new.meeting_date, 'DD Mon YYYY'),
      'Read the summary and bring your unit''s input.', '/tenders/' || new.tender_id);
  elsif coalesce(current_setting('sika.cycle', true), '') <> 'on' and
        ((new.bd_ok_by, new.finance_ok_by, new.engineering_ok_by) is distinct from (old.bd_ok_by, old.finance_ok_by, old.engineering_ok_by)) then
    raise exception 'Use Sign off';
  elsif coalesce(current_setting('sika.cycle', true), '') <> 'on' and (old.bd_ok_by is not null or old.finance_ok_by is not null or old.engineering_ok_by is not null)
        and (new.decision, new.bd_input, new.finance_input, new.engineering_input) is distinct from (old.decision, old.bd_input, old.finance_input, old.engineering_input) then
    -- any change after a unit signed clears the signatures
    new.bd_ok_by := null; new.bd_ok_at := null; new.bd_ok_email := null;
    new.finance_ok_by := null; new.finance_ok_at := null; new.finance_ok_email := null;
    new.engineering_ok_by := null; new.engineering_ok_at := null; new.engineering_ok_email := null;
  end if;
  return new;
end $$;
create trigger tender_reviews_defaults before insert or update on public.tender_reviews for each row execute function public.tender_review_defaults();

-- Each unit signs off the review: Business Development (sales), Finance (accountant), Engineering (project manager).
create or replace function public.sign_tender_review(p_review uuid, p_unit text) returns void
language plpgsql security definer set search_path = public as $$
declare r tender_reviews; v_email text;
begin
  select * into r from tender_reviews where id = p_review for update;
  if not found then raise exception 'Review not found'; end if;
  if not has_role(r.company_id, case p_unit when 'bd' then array['sales'] when 'finance' then array['accountant'] when 'engineering' then array['project_manager'] else array['none'] end)
     and not has_role(r.company_id, array['owner','admin']) then
    raise exception 'Only % can sign for %', case p_unit when 'bd' then 'Business Development (sales role)' when 'finance' then 'Finance (accountant role)' else 'Engineering (project manager role)' end,
      case p_unit when 'bd' then 'Business Development' when 'finance' then 'Finance' else 'Engineering' end;
  end if;
  if coalesce(trim(case p_unit when 'bd' then r.bd_input when 'finance' then r.finance_input else r.engineering_input end), '') = '' then
    raise exception 'Record your unit''s input before signing';
  end if;
  v_email := (select email from auth.users where id = auth.uid());
  perform set_config('sika.cycle','on', true);
  if p_unit = 'bd' then update tender_reviews set bd_ok_by = auth.uid(), bd_ok_email = v_email, bd_ok_at = now() where id = p_review;
  elsif p_unit = 'finance' then update tender_reviews set finance_ok_by = auth.uid(), finance_ok_email = v_email, finance_ok_at = now() where id = p_review;
  elsif p_unit = 'engineering' then update tender_reviews set engineering_ok_by = auth.uid(), engineering_ok_email = v_email, engineering_ok_at = now() where id = p_review;
  else raise exception 'Unit is bd, finance or engineering'; end if;
  perform set_config('sika.cycle','off', true);
end $$;

-- Move a tender along. Submitting needs a review with all three units signed and a "go" decision.
create or replace function public.set_tender_status(p_id uuid, p_to text, p_note text default null, p_date date default current_date, p_value numeric default null)
returns void language plpgsql security definer set search_path = public as $$
declare t tenders;
begin
  select * into t from tenders where id = p_id for update;
  if not found then raise exception 'Tender not found'; end if;
  if not has_role(t.company_id, array['owner','admin','sales','accountant','project_manager']) then raise exception 'Only Business Development, Finance or Engineering can update tenders'; end if;
  if p_to = 'preparing' and t.status <> 'registered' then raise exception 'Only a newly registered tender can start preparation'; end if;
  if p_to = 'submitted' then
    if t.status not in ('registered','preparing','review') then raise exception 'This tender is %', t.status; end if;
    if not exists (select 1 from tender_reviews where tender_id = p_id and decision = 'go'
                    and bd_ok_by is not null and finance_ok_by is not null and engineering_ok_by is not null) then
      raise exception 'Hold the pre-submission review first: Business Development, Finance and Engineering must each record their input and sign off a "go" decision';
    end if;
  end if;
  if p_to in ('lost','no_bid','cancelled') and coalesce(trim(p_note), '') = '' then raise exception 'Give the reason'; end if;
  if p_to = 'lost' and t.status <> 'submitted' then raise exception 'Only a submitted tender can be lost'; end if;
  if p_to not in ('preparing','submitted','lost','no_bid','cancelled') then raise exception 'Use Award for a won tender'; end if;
  perform set_config('sika.cycle','on', true);
  update tenders set status = p_to,
    submitted_at = case when p_to = 'submitted' then p_date else submitted_at end,
    submitted_value = case when p_to = 'submitted' then coalesce(p_value, est_value) else submitted_value end,
    result_date = case when p_to in ('lost','no_bid','cancelled') then p_date else result_date end,
    lost_reason = case when p_to in ('lost','no_bid','cancelled') then p_note else lost_reason end
   where id = p_id;
  perform set_config('sika.cycle','off', true);
  if p_to = 'submitted' then
    perform notify(t.company_id, array['accountant','project_manager'], null, 'tender.submitted', t.number || ' submitted: ' || t.title,
      'Value GH₵ ' || to_char(coalesce(p_value, t.est_value), 'FM999,999,999,990'), '/tenders/' || p_id);
  end if;
end $$;

-- Contract signed or PO received: Finance and Engineering are told at once, and Finance must register the project.
create or replace function public.award_tender(p_id uuid, p_type text, p_ref text, p_signed date, p_value numeric, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare t tenders;
begin
  select * into t from tenders where id = p_id for update;
  if not found then raise exception 'Tender not found'; end if;
  if not has_role(t.company_id, array['owner','admin','sales','accountant']) then raise exception 'Only Business Development or Finance can record an award'; end if;
  if t.status not in ('submitted') and not (t.kind = 'direct_award' and t.status in ('registered','preparing','review')) then
    raise exception 'Only a submitted tender can be awarded (or a direct award)';
  end if;
  if coalesce(trim(p_ref), '') = '' or p_value is null or p_value <= 0 then raise exception 'Enter the contract or PO number and its value'; end if;
  perform set_config('sika.cycle','on', true);
  update tenders set status = 'awarded', award_type = p_type, contract_ref = p_ref, contract_signed_on = p_signed, awarded_value = p_value,
         award_notes = p_note, result_date = coalesce(p_signed, current_date) where id = p_id;
  perform set_config('sika.cycle','off', true);
  perform notify(t.company_id, array['accountant','project_manager'], array[t.engineering_lead_id, t.finance_lead_id], 'tender.awarded',
    'Awarded: ' || t.number || ' ' || t.title || ' (' || replace(p_type, '_', ' ') || ' ' || p_ref || ')',
    'GH₵ ' || to_char(p_value, 'FM999,999,999,990') || '. Finance: register the project and its cost centre before any spending. Then hold the post-award meeting.', '/tenders/' || p_id);
end $$;

-- ---------------------------------------------------------------- 3. Finance registers the project; no spending before registration and an approved budget
alter table public.projects add column if not exists contract_ref text;
alter table public.projects add column if not exists finance_registered_by uuid;
alter table public.projects add column if not exists finance_registered_at timestamptz;
alter table public.projects add column if not exists budget_status text not null default 'none' check (budget_status in ('none','submitted','approved','revised'));
alter table public.projects add column if not exists budget_approved_by uuid;
alter table public.projects add column if not exists budget_approved_at timestamptz;
alter table public.projects add column if not exists budget_note text;
alter table public.projects add column if not exists fin_cleared_by uuid;
alter table public.projects add column if not exists fin_cleared_at timestamptz;
alter table public.projects add column if not exists fin_clearance_note text;
alter table public.projects add column if not exists report_frequency text not null default 'monthly' check (report_frequency in ('weekly','fortnightly','monthly'));
alter table public.companies add column if not exists require_project_registration boolean not null default true;

-- Projects that already exist keep working: they count as registered with an approved budget.
update public.projects set finance_registered_at = coalesce(finance_registered_at, created_at), budget_status = 'approved', budget_approved_at = coalesce(budget_approved_at, created_at)
 where not is_template;

create or replace function public.project_finance_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(current_setting('sika.cycle', true), '') = 'on' then return new; end if;
  if tg_op = 'INSERT' then
    new.finance_registered_by := null; new.finance_registered_at := null; new.budget_status := 'none'; new.budget_approved_by := null; new.budget_approved_at := null;
    new.fin_cleared_by := null; new.fin_cleared_at := null;
  elsif (new.finance_registered_at, new.budget_status, new.budget_approved_at, new.fin_cleared_at, new.number)
        is distinct from (old.finance_registered_at, old.budget_status, old.budget_approved_at, old.fin_cleared_at, old.number) then
    raise exception 'Project registration, budget approval and financial clearance are done by Finance with their own buttons';
  elsif old.finance_registered_at is not null and new.cost_centre_id is distinct from old.cost_centre_id and not has_role(new.company_id, array['owner','admin','accountant']) then
    raise exception 'Only Finance can change a registered project''s cost centre';
  end if;
  return new;
end $$;
create trigger projects_finance_guard before insert or update on public.projects for each row execute function public.project_finance_guard();

-- Finance registers the project: confirms the project code, contract and cost centre.
create or replace function public.register_project(p_project uuid, p_cost_centre uuid, p_branch uuid default null, p_contract_ref text default null, p_contract_value numeric default null, p_note text default null)
returns text language plpgsql security definer set search_path = public as $$
declare pr projects;
begin
  select * into pr from projects where id = p_project for update;
  if not found then raise exception 'Project not found'; end if;
  if not has_role(pr.company_id, array['owner','admin','accountant']) then raise exception 'Only Finance registers projects'; end if;
  if pr.finance_registered_at is not null then raise exception '% is already registered', pr.number; end if;
  if p_cost_centre is null then raise exception 'Every project needs a cost centre. Add one under Settings → Branches and cost centres.'; end if;
  if not exists (select 1 from cost_centres where id = p_cost_centre and company_id = pr.company_id) then raise exception 'Choose one of your cost centres'; end if;
  perform set_config('sika.cycle','on', true);
  update projects set finance_registered_by = auth.uid(), finance_registered_at = now(), cost_centre_id = p_cost_centre, branch_id = coalesce(p_branch, branch_id),
         contract_ref = coalesce(p_contract_ref, contract_ref), contract_value = coalesce(p_contract_value, contract_value) where id = p_project;
  perform set_config('sika.cycle','off', true);
  perform notify(pr.company_id, array['project_manager'], array[pr.manager_id], 'project.registered', pr.number || ' ' || pr.name || ' is registered with Finance',
    'Submit the budget for approval. Spending can start once Finance approves it.' || coalesce(' ' || p_note, ''), '/projects/' || p_project);
  return pr.number;
end $$;

-- Finance creates the project straight from an awarded tender.
create or replace function public.register_project_from_tender(p_tender uuid, p_name text, p_cost_centre uuid, p_manager uuid, p_start date, p_end date,
  p_billing text default 'fixed_price', p_branch uuid default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare t tenders; v uuid;
begin
  select * into t from tenders where id = p_tender for update;
  if not found then raise exception 'Tender not found'; end if;
  if not has_role(t.company_id, array['owner','admin','accountant']) then raise exception 'Only Finance registers projects'; end if;
  if t.status <> 'awarded' then raise exception 'Only an awarded tender becomes a project'; end if;
  if t.project_id is not null then raise exception 'This award already has project %', (select number from projects where id = t.project_id); end if;
  insert into projects (company_id, name, customer_id, status, start_date, end_date, manager_id, billing_type, contract_value, currency, location, description, hourly_rate, tender_id, contract_ref)
  values (t.company_id, coalesce(nullif(trim(p_name), ''), t.title), t.customer_id, 'planned', p_start, p_end, p_manager, p_billing, t.awarded_value, 'GHS', t.location,
          'From ' || t.number || ' (' || replace(t.award_type, '_', ' ') || ' ' || t.contract_ref || ')', 0, t.id, t.contract_ref)
  returning id into v;
  perform set_config('sika.cycle','on', true);
  update tenders set project_id = v where id = p_tender;
  perform set_config('sika.cycle','off', true);
  perform register_project(v, p_cost_centre, p_branch, t.contract_ref, t.awarded_value);
  return v;
end $$;

create or replace function public.submit_project_budget(p_project uuid, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
declare pr projects; v_cost numeric;
begin
  select * into pr from projects where id = p_project for update;
  if not can_manage_project(p_project) then raise exception 'Only the project manager can submit the budget'; end if;
  if pr.finance_registered_at is null then raise exception 'Finance must register the project first'; end if;
  select coalesce(sum(cost_budget), 0) into v_cost from project_budget_lines where project_id = p_project;
  if v_cost <= 0 then raise exception 'Enter the cost budget (Budget tab) before submitting it'; end if;
  perform set_config('sika.cycle','on', true);
  update projects set budget_status = 'submitted', budget_note = p_note where id = p_project;
  perform set_config('sika.cycle','off', true);
  perform notify(pr.company_id, array['accountant'], null, 'budget.submitted', 'Budget for approval: ' || pr.number || ' ' || pr.name,
    'Cost budget GH₵ ' || to_char(v_cost, 'FM999,999,999,990') || coalesce('. ' || p_note, ''), '/projects/' || p_project);
end $$;

create or replace function public.approve_project_budget(p_project uuid, p_approve boolean, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
declare pr projects;
begin
  select * into pr from projects where id = p_project for update;
  if not has_role(pr.company_id, array['owner','admin','accountant']) then raise exception 'Only Finance approves project budgets'; end if;
  if pr.budget_status not in ('submitted','revised') then raise exception 'No budget is waiting for approval'; end if;
  if not p_approve and coalesce(trim(p_note), '') = '' then raise exception 'Say what needs to change'; end if;
  perform set_config('sika.cycle','on', true);
  update projects set budget_status = case when p_approve then 'approved' else 'none' end,
         budget_approved_by = case when p_approve then auth.uid() else budget_approved_by end,
         budget_approved_at = case when p_approve then now() else budget_approved_at end, budget_note = p_note where id = p_project;
  perform set_config('sika.cycle','off', true);
  perform notify(pr.company_id, array['project_manager'], array[pr.manager_id], 'budget.decided',
    case when p_approve then 'Budget approved: ' else 'Budget returned: ' end || pr.number || ' ' || pr.name, p_note, '/projects/' || p_project);
end $$;

-- Changing an approved budget sends it back for approval (spending may continue against the last approved budget).
create or replace function public.budget_line_changed() returns trigger
language plpgsql security definer set search_path = public as $$
declare pid uuid := coalesce(new.project_id, old.project_id);
begin
  perform set_config('sika.cycle','on', true);
  update projects set budget_status = 'revised' where id = pid and budget_status = 'approved' and not is_template;
  perform set_config('sika.cycle','off', true);
  return null;
end $$;
create trigger project_budget_lines_changed after insert or update or delete on public.project_budget_lines for each row execute function public.budget_line_changed();

-- The gate: nothing is bought, issued or claimed for a project Finance has not registered with an approved budget.
create or replace function public.project_spend_gate() returns trigger
language plpgsql security definer set search_path = public as $$
declare pr projects; pid uuid;
begin
  pid := new.project_id;
  if pid is null then return new; end if;
  if tg_table_name = 'stock_issues' then
    if to_jsonb(new)->>'kind' = 'return' then return new; end if;
  end if;
  select * into pr from projects where id = pid;
  if pr.is_template or not (select require_project_registration from companies where id = pr.company_id) then return new; end if;
  if pr.finance_registered_at is null then
    raise exception '% is not registered with Finance yet, so nothing can be spent on it. Ask Finance to register it (project code and cost centre).', coalesce(pr.number, pr.name);
  end if;
  if pr.budget_approved_at is null then
    raise exception '% has no approved budget yet. The project manager submits the budget and Finance approves it before spending starts.', coalesce(pr.number, pr.name);
  end if;
  return new;
end $$;
do $$ declare t text; begin
  foreach t in array array['project_requests','po_lines','bill_lines','stock_issues','expense_claims','stock_requests'] loop
    execute format('create trigger %I before insert on public.%I for each row execute function public.project_spend_gate()', t || '_spend_gate', t);
  end loop;
end $$;

-- Projects that exist operationally but not yet in Finance's system.
create or replace function public.unregistered_projects(cid uuid)
returns table (project_id uuid, number text, name text, status text, manager_id uuid, created_at timestamptz, registered boolean, budget_status text)
language sql stable security definer set search_path = public as $$
  select id, number, name, status, manager_id, created_at, finance_registered_at is not null, budget_status from projects
   where company_id = cid and not is_template and status not in ('closed','cancelled') and is_member(cid)
     and (finance_registered_at is null or budget_approved_at is null or budget_status in ('submitted','revised'))
   order by created_at;
$$;

-- ---------------------------------------------------------------- 4. Meetings (post-award, progress, management) and progress reports from Engineering
create table public.project_meetings (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  project_id uuid references public.projects(id) on delete cascade,
  tender_id uuid references public.tenders(id) on delete cascade,
  kind text not null check (kind in ('post_award','progress','management','other')),
  meeting_date date not null,
  attendees text,
  agenda text,
  minutes text,
  decisions text,
  responsibilities text,                       -- who does what at each stage (post-award meeting)
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  check (project_id is not null or tender_id is not null or kind = 'management')
);
create or replace function public.meeting_defaults() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.company_id := coalesce((select company_id from projects where id = new.project_id), (select company_id from tenders where id = new.tender_id), new.company_id);
  return new;
end $$;
create trigger project_meetings_defaults before insert or update on public.project_meetings for each row execute function public.meeting_defaults();

create table public.progress_reports (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  project_id uuid not null references public.projects(id) on delete cascade,
  number text,
  period_end date not null,
  pct_complete int not null check (pct_complete between 0 and 100),
  work_done text not null,
  next_period text,
  milestones_reached text,
  upcoming_commitments text,          -- purchases, subcontracts, hires expected next period
  upcoming_commitments_value numeric(14,2),
  issues text,
  status text not null default 'draft' check (status in ('draft','submitted','reviewed')),
  submitted_by uuid, submitted_email text, submitted_at timestamptz,
  reviewed_by uuid, reviewed_email text, reviewed_at timestamptz, finance_note text,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);
create index on public.progress_reports (project_id, period_end desc);
create or replace function public.progress_report_defaults() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    new.company_id := (select company_id from projects where id = new.project_id);
    new.number := coalesce(new.number, (select coalesce(number, 'PRJ') from projects where id = new.project_id) || '-PR' || lpad(((select count(*) from progress_reports where project_id = new.project_id) + 1)::text, 3, '0'));
    new.status := 'draft';
  elsif coalesce(current_setting('sika.cycle', true), '') <> 'on' and (new.status is distinct from old.status or old.status <> 'draft') then
    raise exception 'A submitted progress report cannot be changed';
  end if;
  return new;
end $$;
create trigger progress_reports_defaults before insert or update on public.progress_reports for each row execute function public.progress_report_defaults();
create trigger progress_reports_closed_project before insert on public.progress_reports for each row execute function public.closed_project_guard();

create or replace function public.submit_progress_report(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare r progress_reports; pr projects;
begin
  select * into r from progress_reports where id = p_id for update;
  select * into pr from projects where id = r.project_id;
  if not on_project_team(r.project_id) then raise exception 'Only the project team can submit progress reports'; end if;
  if r.status <> 'draft' then raise exception 'Already submitted'; end if;
  perform set_config('sika.cycle','on', true);
  update progress_reports set status = 'submitted', submitted_by = auth.uid(), submitted_email = (select email from auth.users where id = auth.uid()), submitted_at = now() where id = p_id;
  update projects set percent_complete_override = r.pct_complete where id = r.project_id and r.pct_complete is not null;
  perform set_config('sika.cycle','off', true);
  perform notify(pr.company_id, array['accountant'], null, 'progress.submitted', 'Progress report ' || r.number || ': ' || pr.name || ' at ' || r.pct_complete || '%',
    coalesce('Milestones reached: ' || r.milestones_reached || '. ', '') || coalesce('Coming up: ' || r.upcoming_commitments ||
      coalesce(' (about GH₵ ' || to_char(r.upcoming_commitments_value, 'FM999,999,990') || ')', ''), ''), '/projects/' || r.project_id);
end $$;

create or replace function public.review_progress_report(p_id uuid, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
declare r progress_reports;
begin
  select * into r from progress_reports where id = p_id for update;
  if not has_role(r.company_id, array['owner','admin','accountant']) then raise exception 'Only Finance marks reports as reviewed'; end if;
  if r.status <> 'submitted' then raise exception 'Not waiting for Finance'; end if;
  perform set_config('sika.cycle','on', true);
  update progress_reports set status = 'reviewed', reviewed_by = auth.uid(), reviewed_email = (select email from auth.users where id = auth.uid()), reviewed_at = now(), finance_note = p_note where id = p_id;
  perform set_config('sika.cycle','off', true);
end $$;

-- Which active projects owe a progress report (weekly 7 days, fortnightly 14, monthly by the 5th for the month before).
create or replace function public.reports_due(cid uuid)
returns table (project_id uuid, number text, name text, manager_id uuid, frequency text, last_period date, due_on date, days_overdue int)
language sql stable security definer set search_path = public as $$
  select p.id, p.number, p.name, p.manager_id, p.report_frequency, lr.last, d.due, greatest(current_date - d.due, 0)
    from projects p
    left join lateral (select max(period_end) last from progress_reports r where r.project_id = p.id and r.status <> 'draft') lr on true
    cross join lateral (select case p.report_frequency
        when 'weekly' then coalesce(lr.last, coalesce(p.actual_start, p.start_date)) + 7
        when 'fortnightly' then coalesce(lr.last, coalesce(p.actual_start, p.start_date)) + 14
        else case when lr.last is null then (date_trunc('month', coalesce(p.actual_start, p.start_date)) + interval '1 month')::date + 4
                  else (date_trunc('month', lr.last) + interval '2 month')::date + 4 end end due) d
   where p.company_id = cid and is_member(cid) and not p.is_template and p.status in ('active','on_hold')
     and d.due <= current_date + 3
   order by d.due;
$$;

-- ---------------------------------------------------------------- 5. Milestones: certified by Engineering, Finance notified
alter table public.project_milestones add column if not exists certified_by uuid;
alter table public.project_milestones add column if not exists certified_email text;
alter table public.project_milestones add column if not exists certified_at timestamptz;
alter table public.project_milestones add column if not exists certification_note text;
alter table public.project_milestones add column if not exists progress_report_id uuid references public.progress_reports(id) on delete set null;

create or replace function public.certify_milestone(p_id uuid, p_note text, p_report uuid default null) returns void
language plpgsql security definer set search_path = public as $$
declare m project_milestones;
begin
  select * into m from project_milestones where id = p_id for update;
  if not found then raise exception 'Milestone not found'; end if;
  if not can_manage_project(m.project_id) then raise exception 'Only the project manager certifies milestones'; end if;
  if m.status = 'invoiced' then raise exception 'Already invoiced'; end if;
  if coalesce(trim(p_note), '') = '' then raise exception 'Say how the milestone was met (e.g. the client''s sign-off or the inspection)'; end if;
  update project_milestones set status = 'ready', certified_by = auth.uid(), certified_email = (select email from auth.users where id = auth.uid()),
         certified_at = now(), certification_note = p_note, progress_report_id = p_report where id = p_id;
end $$;

-- Whenever a milestone becomes billable (certified, or its task finished), Finance is told.
create or replace function public.milestone_ready_notice() returns trigger
language plpgsql security definer set search_path = public as $$
declare pr projects;
begin
  if new.status = 'ready' and old.status is distinct from 'ready' then
    select * into pr from projects where id = new.project_id;
    perform notify(new.company_id, array['accountant'], null, 'milestone.ready', 'Ready to invoice: ' || new.name || ' · ' || pr.number || ' ' || pr.name,
      pr.currency || ' ' || to_char(new.amount, 'FM999,999,999,990.00') || coalesce('. ' || new.certification_note, ''), '/projects/' || new.project_id);
  end if;
  return null;
end $$;
create trigger project_milestones_ready_notice after update on public.project_milestones for each row execute function public.milestone_ready_notice();

-- What Finance should invoice, and when.
create or replace function public.billing_schedule(cid uuid, p_days int default 30)
returns table (kind text, project_id uuid, project text, customer text, item_id uuid, item text, due_date date, currency text, amount numeric, amount_ghs numeric, ready boolean, certified_note text)
language sql stable security definer set search_path = public as $$
  select 'milestone', p.id, coalesce(p.number || ' ', '') || p.name, c.name, m.id, m.name, m.due_date, p.currency, m.amount,
         round(m.amount * case when p.currency = 'GHS' then 1 else coalesce((select rate from currencies x where x.company_id = p.company_id and x.code = p.currency), 1) end, 2),
         m.status = 'ready', m.certification_note
    from project_milestones m join projects p on p.id = m.project_id left join customers c on c.id = p.customer_id
   where p.company_id = cid and has_role(cid, array['owner','admin','accountant','sales','project_manager']) and not p.is_template
     and m.status in ('planned','ready') and (m.status = 'ready' or m.due_date <= current_date + p_days)
  union all
  select 'time_materials', k.project_id, coalesce(k.number || ' ', '') || k.name, k.customer, null, 'Approved time, expenses and materials not yet invoiced', null, 'GHS', k.unbilled, k.unbilled, true, null
    from project_kpis(cid) k where k.unbilled > 0 and k.billing_type = 'time_materials'
  order by 11 desc, 7 nulls last;
$$;

-- ---------------------------------------------------------------- 6. Every invoice followed up until paid
create table public.invoice_followups (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  invoice_id uuid not null references public.invoices(id) on delete cascade,
  followup_date date not null default current_date,
  method text not null check (method in ('call','email','visit','letter','whatsapp','statement','other')),
  contact text,
  note text not null,
  promised_date date,
  promised_amount numeric(14,2),
  next_action_date date,
  created_by uuid default auth.uid(),
  created_email text,
  created_at timestamptz not null default now()
);
create index on public.invoice_followups (invoice_id, followup_date desc);
create or replace function public.followup_defaults() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.company_id := (select company_id from invoices where id = new.invoice_id);
  new.created_email := coalesce(new.created_email, (select email from auth.users where id = auth.uid()));
  return new;
end $$;
create trigger invoice_followups_defaults before insert on public.invoice_followups for each row execute function public.followup_defaults();

-- Unpaid invoices with age, project and the latest follow-up: the pending receivables report for management meetings.
create or replace function public.receivables_report(cid uuid, p_as_of date default current_date, p_project uuid default null)
returns table (invoice_id uuid, number text, invoice_date date, due_date date, customer_id uuid, customer text, project_id uuid, project text,
               currency text, outstanding numeric, outstanding_ghs numeric, days_overdue int, bucket text,
               last_followup date, last_note text, promised_date date, promised_amount numeric, next_action date, needs_action boolean)
language sql stable security definer set search_path = public as $$
  select i.id, i.number, i.invoice_date, i.due_date, c.id, c.name, p.id, coalesce(p.number || ' ', '') || p.name,
         i.currency, i.total - i.amount_paid - i.amount_credited, round((i.total - i.amount_paid - i.amount_credited) * i.exchange_rate, 2),
         greatest(p_as_of - coalesce(i.due_date, i.invoice_date), 0),
         case when coalesce(i.due_date, i.invoice_date) >= p_as_of then 'Not due' when p_as_of - i.due_date <= 30 then '1-30 days'
              when p_as_of - i.due_date <= 60 then '31-60 days' when p_as_of - i.due_date <= 90 then '61-90 days' else 'Over 90 days' end,
         f.followup_date, f.note, f.promised_date, f.promised_amount, f.next_action_date,
         (coalesce(i.due_date, i.invoice_date) < p_as_of and (f.id is null or coalesce(f.next_action_date, f.followup_date + 14) <= p_as_of))
    from invoices i join customers c on c.id = i.customer_id left join projects p on p.id = i.project_id
    left join lateral (select * from invoice_followups x where x.invoice_id = i.id order by followup_date desc, created_at desc limit 1) f on true
   where i.company_id = cid and has_role(cid, array['owner','admin','accountant','sales']) and i.status = 'posted'
     and i.total - i.amount_paid - i.amount_credited > 0.005 and (p_project is null or i.project_id = p_project)
   order by 12 desc, i.due_date;
$$;

-- Invoices falling due soon or overdue with no follow-up: Finance sees them without being reminded.
create or replace function public.invoice_alerts(cid uuid)
returns table (invoice_id uuid, number text, customer text, project text, due_date date, outstanding_ghs numeric, alert text)
language sql stable security definer set search_path = public as $$
  select invoice_id, number, customer, project, due_date, outstanding_ghs,
         case when days_overdue > 0 then 'Overdue ' || days_overdue || ' days, ' || case when last_followup is null then 'no follow-up yet' else 'next action due' end
              else 'Due ' || to_char(due_date, 'DD Mon') end
    from receivables_report(cid)
   where needs_action or due_date between current_date and current_date + 7
   order by due_date;
$$;

-- ---------------------------------------------------------------- 7. Cost reconciliation and financial clearance
create table public.project_cost_reconciliations (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  project_id uuid not null references public.projects(id) on delete cascade,
  period_from date not null,
  period_to date not null,
  ledger_total numeric(14,2) not null,        -- project-tagged expense lines in the ledger
  report_total numeric(14,2) not null,        -- ledger-backed lines in the project cost report
  items int not null,
  outcome text not null check (outcome in ('agreed','adjusted')),
  notes text,
  reconciled_by uuid default auth.uid(),
  reconciled_email text,
  created_at timestamptz not null default now()
);
create or replace function public.reconcile_project_costs(p_project uuid, p_from date, p_to date, p_outcome text, p_notes text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare pr projects; v_ledger numeric; v_report numeric; n int; v uuid;
begin
  select * into pr from projects where id = p_project;
  if not has_role(pr.company_id, array['owner','admin','accountant']) then raise exception 'Only Finance reconciles project costs'; end if;
  if p_outcome = 'adjusted' and coalesce(trim(p_notes), '') = '' then raise exception 'Describe the adjustments (e.g. journal JE-00123 moved fuel to PRJ-00004)'; end if;
  select coalesce(sum(l.debit - l.credit), 0) into v_ledger from journal_lines l join journal_entries e on e.id = l.entry_id join accounts a on a.id = l.account_id
   where l.project_id = p_project and a.type = 'expense' and e.entry_date between p_from and p_to;
  select coalesce(sum(amount) filter (where in_ledger and category <> 'labour'), 0), count(*) into v_report, n from project_cost_items(pr.company_id)
   where project_id = p_project and item_date between p_from and p_to;
  insert into project_cost_reconciliations (company_id, project_id, period_from, period_to, ledger_total, report_total, items, outcome, notes, reconciled_email)
  values (pr.company_id, p_project, p_from, p_to, v_ledger, v_report, n, p_outcome, p_notes, (select email from auth.users where id = auth.uid())) returning id into v;
  return v;
end $$;

-- Finance confirms the project is settled: everything billed, costs reconciled, receivables collected or accounted for.
create or replace function public.clear_project_finance(p_project uuid, p_note text default null, p_force boolean default false) returns void
language plpgsql security definer set search_path = public as $$
declare pr projects; v_out numeric; v_blocks int;
begin
  select * into pr from projects where id = p_project for update;
  if not has_role(pr.company_id, array['owner','admin','accountant']) then raise exception 'Only Finance gives financial clearance'; end if;
  if pr.status <> 'done' then raise exception 'Mark the work complete first'; end if;
  select count(*) into v_blocks from project_close_check_v22(p_project) where severity = 'block';
  if v_blocks > 0 then raise exception '% close-out item% still open. Clear them first (see the checklist).', v_blocks, case when v_blocks = 1 then ' is' else 's are' end; end if;
  if not exists (select 1 from project_cost_reconciliations where project_id = p_project and created_at > coalesce(
       (select max(je.created_at) from journal_lines l join journal_entries je on je.id = l.entry_id where l.project_id = p_project), '1900-01-01')) then
    raise exception 'Reconcile the project''s costs first (Project costs → Reconcile), so every cost is on the right project';
  end if;
  select coalesce(sum((total - amount_paid - amount_credited) * exchange_rate), 0) into v_out from invoices where project_id = p_project and status = 'posted';
  if v_out > 0.005 and not (p_force and coalesce(trim(p_note), '') <> '') then
    raise exception 'GH₵ % is still owed on this project''s invoices. Collect it, or clear with a note on how it will be collected or written off.', to_char(v_out, 'FM999,999,990.00');
  end if;
  perform set_config('sika.cycle','on', true);
  update projects set fin_cleared_by = auth.uid(), fin_cleared_at = now(), fin_clearance_note = p_note where id = p_project;
  perform set_config('sika.cycle','off', true);
  perform notify(pr.company_id, array['project_manager'], array[pr.manager_id], 'project.cleared', 'Financial clearance given: ' || pr.number || ' ' || pr.name,
    'The project can now be closed.' || coalesce(' ' || p_note, ''), '/projects/' || p_project);
end $$;

-- Close-out now also needs financial clearance; reopening withdraws it.
alter function public.project_close_check(uuid) rename to project_close_check_v22;
create or replace function public.project_close_check(p_project uuid)
returns table (item text, n bigint, amount numeric, severity text, hint text)
language sql stable security definer set search_path = public as $$
  select * from project_close_check_v22(p_project)
  union all
  select 'Financial clearance not given', 1::bigint, null::numeric, 'block', 'Finance: reconcile costs, then give financial clearance'
   where not exists (select 1 from projects where id = p_project and fin_cleared_at is not null)
     and (select require_project_registration from companies c join projects p on p.company_id = c.id where p.id = p_project)
$$;
revoke execute on function public.project_close_check_v22(uuid) from public, anon, authenticated;

create or replace function public.withdraw_clearance_on_reopen() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.fin_cleared_at is not null and new.status is distinct from old.status and new.status not in ('closed') and not (old.status = 'done' and new.status = 'done') then
    new.fin_cleared_at := null; new.fin_cleared_by := null;
  end if;
  return new;
end $$;
create trigger projects_reopen_clearance before update on public.projects for each row execute function public.withdraw_clearance_on_reopen();

-- When the work is complete, Finance is told to start close-out.
create or replace function public.project_done_notice() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'done' and old.status is distinct from 'done' then
    perform notify(new.company_id, array['accountant'], null, 'project.done', 'Work complete: ' || new.number || ' ' || new.name,
      'Finance: invoice what is left, reconcile costs, follow up receivables, then give financial clearance.', '/projects/' || new.id);
  end if;
  return null;
end $$;
create trigger projects_done_notice after update on public.projects for each row execute function public.project_done_notice();

-- ---------------------------------------------------------------- 8. Management view: every project's financial position
create or replace function public.project_finance_overview(cid uuid)
returns table (project_id uuid, number text, name text, customer text, status text, manager_id uuid, registered boolean, budget_status text, cleared boolean,
               contract_value numeric, budget_cost numeric, actual_cost numeric, committed_cost numeric, invoiced numeric, received numeric, outstanding numeric,
               overdue numeric, unbilled numeric, gross_profit numeric, margin_pct numeric, forecast_margin numeric, pct_complete int, last_report date, report_overdue boolean)
language sql stable security definer set search_path = public as $$
  with k as (select * from project_kpis(cid)),
  inv as (select project_id,
                 sum(round(subtotal * exchange_rate, 2)) invoiced,                                        -- excluding VAT
                 sum(round(amount_paid * exchange_rate, 2)) received,                                     -- cash, including VAT
                 sum(round((total - amount_paid - amount_credited) * exchange_rate, 2)) outstanding,
                 sum(round((total - amount_paid - amount_credited) * exchange_rate, 2)) filter (where due_date < current_date) overdue
            from invoices where company_id = cid and status in ('posted','paid') and project_id is not null group by project_id),
  due as (select project_id from reports_due(cid) where days_overdue > 0)
  select p.id, p.number, p.name, k.customer, p.status, p.manager_id, p.finance_registered_at is not null, p.budget_status, p.fin_cleared_at is not null,
         round(p.contract_value * case when p.currency = 'GHS' then 1 else coalesce((select rate from currencies x where x.company_id = cid and x.code = p.currency), 1) end, 2),
         k.budget_cost, k.actual_cost, k.committed_cost, coalesce(inv.invoiced, 0), coalesce(inv.received, 0), coalesce(inv.outstanding, 0), coalesce(inv.overdue, 0), k.unbilled,
         coalesce(inv.invoiced, 0) - k.actual_cost,
         case when coalesce(inv.invoiced, 0) > 0 then round(100 * (inv.invoiced - k.actual_cost) / inv.invoiced, 1) end,
         k.forecast_margin, k.pct_complete,
         (select max(period_end) from progress_reports r where r.project_id = p.id and r.status <> 'draft'),
         p.id in (select project_id from due)
    from projects p join k on k.project_id = p.id left join inv on inv.project_id = p.id
   where p.company_id = cid and has_role(cid, array['owner','admin','accountant']) and not p.is_template
   order by p.status = 'closed', p.number;
$$;

-- ---------------------------------------------------------------- 9. Responsibilities and reporting deadlines at each stage
create table public.cycle_responsibilities (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  stage text not null check (stage in ('tender','award','execution','invoicing','closure')),
  unit text not null check (unit in ('business_development','finance','engineering','management')),
  responsibility text not null,
  deadline text,
  sort int not null default 0
);
create or replace function public.seed_cycle_responsibilities(cid uuid) returns void
language sql security definer set search_path = public as $$
  insert into cycle_responsibilities (company_id, stage, unit, responsibility, deadline, sort)
  select cid, s, u, r, d, n from (values
   ('tender','business_development','Register every tender, quotation and procurement opportunity in Asnys','Same day it is received',1),
   ('tender','business_development','Share the tender summary report with Finance and Engineering before the pre-submission review','At least 2 working days before the review',2),
   ('tender','finance','Review pricing, cash flow, bid bond and payment terms; record Finance input and sign off','At the pre-submission review',3),
   ('tender','engineering','Review scope, method, programme and cost estimate; record Engineering input and sign off','At the pre-submission review',4),
   ('tender','business_development','Take the units'' inputs into the final tender documents, contract or PO','Before submission',5),
   ('award','business_development','Record the award (contract or PO number, value, date) and upload the signed document','Within 1 working day of signing',6),
   ('award','finance','Register the project: project code, cost centre, contract value','Within 2 working days of the award',7),
   ('award','engineering','Prepare and submit the project budget for Finance approval','Within 5 working days of registration',8),
   ('award','management','Hold the post-award meeting: execution plan and each unit''s role at each stage','Within 1 week of the award',9),
   ('execution','engineering','Submit progress reports: work done, milestones reached, upcoming purchases and commitments','By the project''s reporting frequency (monthly by the 5th)',10),
   ('execution','engineering','Raise purchase requests in Asnys for every material, subcontract and hire','Before committing to any supplier',11),
   ('execution','finance','Capture and allocate every cost to the right project and cost centre','Within 2 working days of receiving the bill or claim',12),
   ('execution','finance','Reconcile each project''s costs and correct misallocations','Monthly',13),
   ('invoicing','engineering','Certify milestones with evidence (client sign-off, inspection)','Within 2 working days of completion',14),
   ('invoicing','finance','Invoice certified milestones and approved time and materials','Within 3 working days of certification',15),
   ('closure','finance','Follow up every unpaid invoice and record each contact','Weekly for overdue invoices',16),
   ('closure','finance','Present the pending receivables report at the management meeting','Every management meeting',17),
   ('closure','finance','Give financial clearance before the project is closed','When work is complete',18),
   ('closure','engineering','Hand over close-out documents and return site stock','Before financial clearance',19)
  ) v(s, u, r, d, n)
  where not exists (select 1 from cycle_responsibilities where company_id = cid);
$$;
select public.seed_cycle_responsibilities(id) from public.companies;

-- What is waiting at each stage, for the Project cycle page.
create or replace function public.cycle_status(cid uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'tenders_open', (select count(*) from tenders where company_id = cid and status in ('registered','preparing','review')),
    'tenders_due_7', (select count(*) from tenders where company_id = cid and status in ('registered','preparing','review') and submission_deadline < now() + interval '7 days'),
    'reviews_unsigned', (select count(*) from tender_reviews r join tenders t on t.id = r.tender_id where t.company_id = cid and t.status = 'review'
                           and (r.bd_ok_by is null or r.finance_ok_by is null or r.engineering_ok_by is null)),
    'awards_unregistered', (select count(*) from tenders where company_id = cid and status = 'awarded' and project_id is null),
    'projects_unregistered', (select count(*) from projects where company_id = cid and not is_template and finance_registered_at is null and status not in ('closed','cancelled')),
    'budgets_waiting', (select count(*) from projects where company_id = cid and budget_status in ('submitted','revised')),
    'reports_overdue', (select count(*) from reports_due(cid) where days_overdue > 0),
    'reports_to_review', (select count(*) from progress_reports where company_id = cid and status = 'submitted'),
    'milestones_ready', (select count(*) from project_milestones m join projects p on p.id = m.project_id where p.company_id = cid and m.status = 'ready'),
    'invoices_overdue', (select count(*) from receivables_report(cid) where days_overdue > 0),
    'invoices_no_followup', (select count(*) from receivables_report(cid) where needs_action),
    'receivable_total', (select coalesce(sum(outstanding_ghs), 0) from receivables_report(cid)),
    'awaiting_clearance', (select count(*) from projects where company_id = cid and status = 'done' and fin_cleared_at is null))
  where is_member(cid);
$$;

-- ---------------------------------------------------------------- 10. New companies, security, audit
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
  perform seed_accounts_v21(v);
  perform seed_leave_types(v);
  perform seed_asset_categories(v);
  perform wh(v);
  perform seed_cycle_responsibilities(v);
  return v;
end $$;

alter table public.tenders enable row level security;
alter table public.tender_reviews enable row level security;
alter table public.tender_files enable row level security;
create policy "members read tenders" on public.tenders for select using (is_member(company_id));
create policy "units write tenders" on public.tenders for insert with check (has_role(company_id, array['owner','admin','sales','accountant','project_manager']));
create policy "units edit tenders" on public.tenders for update using (has_role(company_id, array['owner','admin','sales','accountant','project_manager']));
create policy "bd deletes new tenders" on public.tenders for delete using (status = 'registered' and has_role(company_id, array['owner','admin','sales']));
create policy "members read reviews" on public.tender_reviews for select using (is_member(company_id));
create policy "units write reviews" on public.tender_reviews for all using (has_role(company_id, array['owner','admin','sales','accountant','project_manager']))
  with check (exists (select 1 from tenders t where t.id = tender_id and has_role(t.company_id, array['owner','admin','sales','accountant','project_manager'])));
create policy "members read tender files" on public.tender_files for select using (is_member(company_id));
create policy "units write tender files" on public.tender_files for all using (has_role(company_id, array['owner','admin','sales','accountant','project_manager']))
  with check (has_role(company_id, array['owner','admin','sales','accountant','project_manager']));

alter table public.project_meetings enable row level security;
create policy "members read meetings" on public.project_meetings for select using (is_member(company_id));
create policy "team writes meetings" on public.project_meetings for all
  using ((project_id is not null and on_project_team(project_id)) or has_role(company_id, array['owner','admin','accountant','sales']))
  with check ((project_id is not null and on_project_team(project_id)) or has_role(coalesce(company_id, (select company_id from tenders where id = tender_id)), array['owner','admin','accountant','sales','project_manager']));

alter table public.progress_reports enable row level security;
create policy "members read progress" on public.progress_reports for select using (is_member(company_id));
create policy "team writes progress" on public.progress_reports for insert with check (on_project_team(project_id));
create policy "team edits draft progress" on public.progress_reports for update using (on_project_team(project_id));
create policy "team deletes draft progress" on public.progress_reports for delete using (status = 'draft' and on_project_team(project_id));

alter table public.invoice_followups enable row level security;
create policy "finance reads follow-ups" on public.invoice_followups for select using (has_role(company_id, array['owner','admin','accountant','sales']));
create policy "finance writes follow-ups" on public.invoice_followups for insert with check (exists (select 1 from invoices i where i.id = invoice_id and has_role(i.company_id, array['owner','admin','accountant','sales'])));
create policy "author deletes follow-ups" on public.invoice_followups for delete using (created_by = auth.uid());

alter table public.project_cost_reconciliations enable row level security;
create policy "members read reconciliations" on public.project_cost_reconciliations for select using (is_member(company_id));

alter table public.cycle_responsibilities enable row level security;
create policy "members read responsibilities" on public.cycle_responsibilities for select using (is_member(company_id));
create policy "admins write responsibilities" on public.cycle_responsibilities for all using (has_role(company_id, array['owner','admin'])) with check (has_role(company_id, array['owner','admin']));

do $$ declare t text; begin
  foreach t in array array['tenders','tender_reviews','project_meetings','progress_reports','invoice_followups','project_cost_reconciliations','cycle_responsibilities'] loop
    execute format('create trigger %I after insert or update or delete on public.%I for each row execute function public.audit_row()', t || '_audit', t);
  end loop;
end $$;

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
revoke execute on function public.seed_accounts_v21(uuid) from authenticated;
revoke execute on function public.seed_leave_types(uuid) from authenticated;
revoke execute on function public.seed_asset_categories(uuid) from authenticated;
revoke execute on function public.seed_cycle_responsibilities(uuid) from authenticated;
revoke execute on function public.next_number(uuid,text,text) from authenticated;
revoke execute on function public.notify(uuid,text[],uuid[],text,text,text,text) from authenticated;
revoke execute on function public.project_cost_items(uuid) from authenticated;
revoke execute on function public.project_cost_totals(uuid) from authenticated;
revoke execute on function public.finalize_expense(uuid) from authenticated;
revoke execute on function public.doc_dims(text,uuid) from authenticated;
revoke execute on function public.wh(uuid) from authenticated;
revoke execute on function public.transit_wh(uuid) from authenticated;
revoke execute on function public.ledger_checks_v20(uuid) from authenticated;
revoke execute on function public.unposted_documents_v20(uuid) from authenticated;
revoke execute on function public.project_close_check_v21(uuid) from authenticated;
revoke execute on function public.project_close_check_v22(uuid) from authenticated;
revoke execute on function public.create_project_from_template_v13(uuid, text, uuid, date, uuid) from authenticated;
grant execute on function public.public_help(uuid) to anon;
grant execute on function public.submit_case_public(uuid,text,text,text,text,text) to anon;
grant execute on function public.case_status_public(text,text) to anon;
grant execute on function public.reply_case_public(text,text,text,int) to anon;

