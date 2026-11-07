-- Asnys ERP v2.7: spend requests, staff cash advances (imprest) and petty cash floats. Run after 0001 to 0012.
-- Spending that has no project or sales order goes through a request, an approval chain and a budget check
-- before Finance turns it into a purchase order, a supplier bill, a payment or a cash advance.
-- Advances must be retired with receipts; petty cash floats are counted and replenished only when reconciled.

-- ---------------------------------------------------------------- 1. Accounts and settings
create or replace function public.seed_accounts_v27(cid uuid)
returns void language sql security definer set search_path = public as $$
  insert into accounts (company_id, code, name, type, system_key) values
  (cid,'1260','Staff cash advances (imprest)','asset','staff_advances'),
  (cid,'6960','Cash shortages','expense','cash_short'),
  (cid,'4960','Cash overages','income','cash_over')
  on conflict do nothing;
$$;
select public.seed_accounts_v27(id) from public.companies;

alter table public.companies add column if not exists advance_retire_days int not null default 7 check (advance_retire_days between 1 and 90);
alter table public.companies add column if not exists max_open_advances int not null default 1 check (max_open_advances between 1 and 10);
alter table public.companies add column if not exists advance_recover_after_days int not null default 30 check (advance_recover_after_days between 1 and 365);

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
  perform seed_accounts_v27(v);
  perform seed_leave_types(v);
  perform seed_asset_categories(v);
  perform wh(v);
  perform seed_cycle_responsibilities(v);
  return v;
end $$;

create or replace function public.is_finance(cid uuid) returns boolean
language sql stable security definer set search_path = public as $$ select has_role(cid, array['owner','admin','accountant']) $$;

-- A cash, MoMo or bank account of this company to pay from.
create or replace function public.paying_account(cid uuid, p_account uuid) returns uuid
language plpgsql stable security definer set search_path = public as $$
declare a accounts;
begin
  if p_account is null then return acct(cid, 'bank'); end if;
  select * into a from accounts where id = p_account and company_id = cid;
  if not found or not a.is_bank then raise exception 'Choose a cash, MoMo or bank account to pay from'; end if;
  return a.id;
end $$;

-- ---------------------------------------------------------------- 2. Spend requests
create table public.spend_requests (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  number text,
  kind text not null default 'purchase' check (kind in ('purchase','payment','cash_advance')),
  title text not null,
  justification text,
  amount numeric(14,2) not null check (amount > 0),         -- GHS
  account_id uuid references public.accounts(id),           -- what it will be spent on (expense account)
  branch_id uuid references public.branches(id) on delete set null,
  cost_centre_id uuid references public.cost_centres(id) on delete set null,
  project_id uuid references public.projects(id) on delete set null,
  supplier_id uuid references public.suppliers(id) on delete set null,
  payee text,
  employee_id uuid references public.employees(id) on delete set null,   -- who receives a cash advance
  needed_by date,
  status text not null default 'draft' check (status in ('draft','submitted','approved','rejected','cancelled','done')),
  requested_by uuid not null default auth.uid(),
  submitted_at timestamptz, approved_at timestamptz,
  outcome text check (outcome in ('purchase_order','bill','payment','advance')),
  outcome_id uuid, outcome_ref text,
  created_at timestamptz not null default now()
);
create index spend_requests_company on public.spend_requests (company_id, status);

create or replace function public.spend_request_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    new.number := next_number(new.company_id, 'SRQ', 'SRQ-');
    new.status := 'draft'; new.requested_by := coalesce(auth.uid(), new.requested_by);
    new.outcome := null; new.outcome_id := null; new.submitted_at := null; new.approved_at := null;
  elsif coalesce(current_setting('sika.spend', true), '') <> 'on' then
    if old.status <> 'draft' then raise exception '% has been submitted and can no longer be changed. Cancel it and raise a new one.', old.number; end if;
    if new.status <> old.status or new.outcome is distinct from old.outcome or new.requested_by <> old.requested_by then raise exception 'Use Submit or Cancel'; end if;
  end if;
  if new.account_id is not null and not exists (select 1 from accounts where id = new.account_id and company_id = new.company_id) then raise exception 'Account not found'; end if;
  if new.kind = 'cash_advance' and new.employee_id is null then
    select id into new.employee_id from employees where company_id = new.company_id and user_id = new.requested_by limit 1;
  end if;
  return new;
end $$;
create trigger spend_requests_guard before insert or update on public.spend_requests for each row execute function public.spend_request_guard();
create trigger spend_requests_spend_gate before insert on public.spend_requests for each row execute function public.project_spend_gate();

-- Budget for the account this year, spent so far, committed by open requests, and what is left.
create or replace function public.spend_budget(cid uuid, p_account uuid, p_date date default current_date)
returns table (budget numeric, actual numeric, committed numeric, remaining numeric)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare y int := extract(year from coalesce(p_date, current_date));
begin
  perform require_member(cid);
  return query
  select b.v, a.v, c.v, b.v - a.v - c.v from
    (select coalesce(sum(amount), 0) v from budgets where company_id = cid and account_id = p_account and year = y) b,
    (select coalesce(sum(l.debit - l.credit), 0) v from journal_lines l join journal_entries e on e.id = l.entry_id
      where l.company_id = cid and l.account_id = p_account and extract(year from e.entry_date) = y) a,
    (select coalesce(sum(amount), 0) v from spend_requests where company_id = cid and account_id = p_account and status in ('submitted','approved')
      and extract(year from coalesce(needed_by, created_at::date)) = y) c;
end $$;

-- Who has an advance that blocks another one.
create or replace function public.advance_block_reason(p_employee uuid) returns text
language plpgsql stable security definer set search_path = public as $$
declare e employees; n int; od text;
begin
  if p_employee is null then return null; end if;
  select * into e from employees where id = p_employee;
  select number into od from cash_advances where employee_id = p_employee and status = 'open' and due_on < current_date order by due_on limit 1;
  if od is not null then return e.full_name || ' has advance ' || od || ' overdue for retirement. Retire it before asking for another.'; end if;
  select count(*) into n from cash_advances where employee_id = p_employee and status in ('open','submitted');
  if n >= (select max_open_advances from companies where id = e.company_id) then
    return e.full_name || ' already has ' || n || ' advance(s) not yet retired.';
  end if;
  return null;
end $$;

create or replace function public.submit_spend_request(p_id uuid) returns int
language plpgsql security definer set search_path = public as $$
declare r spend_requests; n int; why text;
begin
  select * into r from spend_requests where id = p_id for update;
  if not found then raise exception 'Request not found'; end if;
  if r.requested_by <> auth.uid() and not is_finance(r.company_id) then raise exception 'Only the person who raised it can submit it'; end if;
  if r.status <> 'draft' then raise exception '% is already %', r.number, r.status; end if;
  if coalesce(trim(r.justification), '') = '' then raise exception 'Say why the money is needed'; end if;
  if r.kind in ('purchase','payment') and r.account_id is null then raise exception 'Choose what it will be charged to (the expense account)'; end if;
  if r.kind = 'cash_advance' then
    if r.employee_id is null then raise exception 'Choose who receives the advance (they need an employee record)'; end if;
    why := advance_block_reason(r.employee_id);
    if why is not null then raise exception '%', why; end if;
  end if;
  perform set_config('sika.spend', 'on', true);
  update spend_requests set status = 'submitted', submitted_at = now() where id = p_id;
  perform set_config('sika.spend', 'off', true);
  n := start_approval('spend_request', p_id);
  if n = 0 then          -- no chain set up: Finance approves every request
    insert into approval_steps (company_id, doc_type, doc_id, step_no, label, approver_role, amount)
    values (r.company_id, 'spend_request', p_id, 1, 'Finance', 'accountant', r.amount);
    n := 1;
  end if;
  perform notify(r.company_id, (select array_agg(coalesce(approver_role, 'owner')) from approval_steps where doc_type = 'spend_request' and doc_id = p_id and step_no = (select min(step_no) from approval_steps where doc_type = 'spend_request' and doc_id = p_id)),
    (select array_agg(approver_user) from approval_steps where doc_type = 'spend_request' and doc_id = p_id and approver_user is not null),
    'spend_request', r.number || ' needs approval: ' || r.title, 'GH₵ ' || to_char(r.amount, 'FM999,999,999,990.00'), '/requests/' || r.id);
  return n;
end $$;

create or replace function public.cancel_spend_request(p_id uuid, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
declare r spend_requests;
begin
  select * into r from spend_requests where id = p_id for update;
  if not found then raise exception 'Request not found'; end if;
  if r.requested_by <> auth.uid() and not is_finance(r.company_id) then raise exception 'Only the person who raised it or Finance can cancel it'; end if;
  if r.status not in ('draft','submitted','approved') then raise exception '% is already %', r.number, r.status; end if;
  perform set_config('sika.spend', 'on', true);
  update spend_requests set status = 'cancelled', justification = justification || coalesce(E'\nCancelled: ' || p_note, '') where id = p_id;
  update approval_steps set status = 'skipped' where doc_type = 'spend_request' and doc_id = p_id and status = 'pending';
  perform set_config('sika.spend', 'off', true);
end $$;

-- Requests join the approval chains (Settings → Approval rules, type "Spend request").
alter table public.approval_rules drop constraint if exists approval_rules_doc_type_check;
alter table public.approval_rules add constraint approval_rules_doc_type_check
  check (doc_type in ('bill','payroll','purchase_request','expense_claim','purchase_order','spend_request'));

alter function public.doc_info(text, uuid) rename to doc_info_v26;
create or replace function public.doc_info(p_type text, p_id uuid, out company_id uuid, out amount numeric, out label text, out path text)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  if p_type = 'spend_request' then
    select r.company_id, r.amount,
           r.number || ' · ' || case r.kind when 'cash_advance' then 'Cash advance' when 'payment' then 'Payment' else 'Purchase' end || ' · ' || r.title
             || coalesce(' · ' || (select email from memberships m where m.company_id = r.company_id and m.user_id = r.requested_by), ''),
           '/requests/' || r.id
      into company_id, amount, label, path from spend_requests r where r.id = p_id;
  else
    select d.company_id, d.amount, d.label, d.path into company_id, amount, label, path from doc_info_v26(p_type, p_id) d;
  end if;
end $$;

alter function public.decide_approval(uuid, boolean, text) rename to decide_approval_v26;
create or replace function public.decide_approval(p_step uuid, p_approve boolean, p_note text default null)
returns text language plpgsql security definer set search_path = public as $$
declare s approval_steps; r spend_requests; res text;
begin
  select * into s from approval_steps where id = p_step;
  if found and s.doc_type = 'spend_request' then
    select * into r from spend_requests where id = s.doc_id;
    if r.requested_by = auth.uid() then raise exception 'You cannot approve your own request'; end if;
  end if;
  res := decide_approval_v26(p_step, p_approve, p_note);
  if s.doc_type = 'spend_request' and res in ('approved','rejected') then
    perform set_config('sika.spend', 'on', true);
    update spend_requests set status = res, approved_at = case when res = 'approved' then now() end where id = s.doc_id;
    perform set_config('sika.spend', 'off', true);
    perform notify(r.company_id, case when res = 'approved' then array['accountant'] else array[]::text[] end, array[r.requested_by], 'spend_request_' || res,
      r.number || ' ' || res || ': ' || r.title, case when res = 'rejected' then p_note else 'Finance will now ' ||
        case r.kind when 'cash_advance' then 'pay the advance.' when 'payment' then 'make the payment.' else 'place the order.' end end, '/requests/' || r.id, true);
  elsif s.doc_type = 'spend_request' and res = 'pending' then
    perform notify(r.company_id, (select array_agg(coalesce(approver_role, 'owner')) from approval_steps where doc_type = 'spend_request' and doc_id = r.id and status = 'pending'
                                    and step_no = (select min(step_no) from approval_steps where doc_type = 'spend_request' and doc_id = r.id and status = 'pending')),
      null, 'spend_request', r.number || ' needs your approval: ' || r.title, null, '/requests/' || r.id);
  end if;
  return res;
end $$;

-- Finance acts on an approved request.
create or replace function public.spend_request_ready(p_id uuid) returns spend_requests
language plpgsql security definer set search_path = public as $$
declare r spend_requests;
begin
  select * into r from spend_requests where id = p_id for update;
  if not found then raise exception 'Request not found'; end if;
  if not is_finance(r.company_id) and not (r.kind = 'purchase' and has_role(r.company_id, array['store'])) then raise exception 'Only Finance can act on approved requests'; end if;
  if r.status <> 'approved' then raise exception '% is % and cannot be actioned', r.number, r.status; end if;
  if approval_state('spend_request', r.id) <> 'approved' then raise exception '% has not been fully approved', r.number; end if;
  return r;
end $$;

create or replace function public.spend_request_done(p_id uuid, p_outcome text, p_outcome_id uuid, p_ref text) returns void
language plpgsql security definer set search_path = public as $$
declare r spend_requests;
begin
  perform set_config('sika.spend', 'on', true);
  update spend_requests set status = 'done', outcome = p_outcome, outcome_id = p_outcome_id, outcome_ref = p_ref where id = p_id returning * into r;
  perform set_config('sika.spend', 'off', true);
  perform notify(r.company_id, array[]::text[], array[r.requested_by], 'spend_request_done', r.number || ': ' || replace(p_outcome, '_', ' ') || ' ' || coalesce(p_ref, '') || ' done', null, '/requests/' || r.id, true);
end $$;

create or replace function public.request_to_po(p_id uuid, p_supplier uuid default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare r spend_requests; v uuid; n text;
begin
  r := spend_request_ready(p_id);
  if r.kind <> 'purchase' then raise exception 'Only a purchase request becomes a purchase order'; end if;
  if coalesce(p_supplier, r.supplier_id) is null then raise exception 'Choose the supplier'; end if;
  insert into purchase_orders (company_id, supplier_id, order_date, expected_date, project_id, branch_id, notes)
  values (r.company_id, coalesce(p_supplier, r.supplier_id), current_date, r.needed_by, r.project_id, r.branch_id, 'From ' || r.number || ': ' || r.title)
  returning id, number into v, n;
  insert into po_lines (po_id, company_id, account_id, description, qty, unit_cost, project_id)
  values (v, r.company_id, r.account_id, r.title, 1, r.amount, r.project_id);
  perform spend_request_done(p_id, 'purchase_order', v, coalesce(n, (select number from purchase_orders where id = v)));
  return v;
end $$;

create or replace function public.request_to_bill(p_id uuid, p_supplier uuid default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare r spend_requests; v uuid;
begin
  r := spend_request_ready(p_id);
  if r.kind = 'cash_advance' then raise exception 'A cash advance is paid with Pay advance'; end if;
  if coalesce(p_supplier, r.supplier_id) is null then raise exception 'Choose the supplier'; end if;
  insert into bills (company_id, supplier_id, bill_date, supplier_ref) values (r.company_id, coalesce(p_supplier, r.supplier_id), current_date, r.number) returning id into v;
  insert into bill_lines (bill_id, company_id, account_id, description, qty, unit_cost, taxable, project_id, cost_centre_id)
  values (v, r.company_id, r.account_id, r.title, 1, r.amount, false, r.project_id, r.cost_centre_id);
  perform spend_request_done(p_id, 'bill', v, 'draft bill');
  return v;
end $$;

-- A direct payment (no supplier invoice): Dr the expense, Cr the bank.
create or replace function public.pay_spend_request(p_id uuid, p_from uuid default null, p_date date default current_date, p_reference text default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare r spend_requests; v_je uuid; v_from uuid;
begin
  r := spend_request_ready(p_id);
  if r.kind <> 'payment' then raise exception 'Only a payment request is paid directly'; end if;
  if not is_finance(r.company_id) then raise exception 'Only Finance can make payments'; end if;
  v_from := paying_account(r.company_id, p_from);
  v_je := post_journal(r.company_id, coalesce(p_date, current_date), r.number || ' ' || r.title || coalesce(' · ' || coalesce(r.payee, (select name from suppliers where id = r.supplier_id)), '') || coalesce(' · ' || p_reference, ''),
    jsonb_build_array(jl(r.account_id, r.amount, 0) || jsonb_build_object('project_id', r.project_id, 'branch_id', r.branch_id, 'cost_centre_id', r.cost_centre_id),
                      jl(v_from, 0, r.amount)), 'spend_request', r.id);
  perform spend_request_done(p_id, 'payment', v_je, (select entry_no from journal_entries where id = v_je));
  return v_je;
end $$;

-- ---------------------------------------------------------------- 3. Staff cash advances (imprest)
create table public.cash_advances (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  number text,
  request_id uuid references public.spend_requests(id) on delete set null,
  employee_id uuid not null references public.employees(id),
  purpose text not null,
  amount numeric(14,2) not null check (amount > 0),
  issued_on date not null default current_date,
  paid_from uuid references public.accounts(id),
  due_on date not null,                                    -- retire by
  project_id uuid references public.projects(id) on delete set null,
  branch_id uuid references public.branches(id) on delete set null,
  cost_centre_id uuid references public.cost_centres(id) on delete set null,
  status text not null default 'open' check (status in ('open','submitted','retired','recovered')),
  submitted_at timestamptz,
  returned_note text,                                      -- why Finance sent the retirement back
  spent numeric(14,2), cash_returned numeric(14,2), reimbursed numeric(14,2),
  retired_on date, retired_by uuid,
  loan_id uuid references public.employee_loans(id),
  journal_entry_id uuid references public.journal_entries(id),
  retire_entry_id uuid references public.journal_entries(id),
  created_at timestamptz not null default now()
);
create index cash_advances_employee on public.cash_advances (employee_id, status);

create table public.advance_lines (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  advance_id uuid not null references public.cash_advances(id) on delete cascade,
  line_date date not null default current_date,
  description text not null,
  account_id uuid not null references public.accounts(id),
  amount numeric(14,2) not null check (amount > 0),
  project_id uuid references public.projects(id) on delete set null,
  cost_centre_id uuid references public.cost_centres(id) on delete set null,
  receipt_path text,
  created_at timestamptz not null default now()
);

create or replace function public.advance_holder(a cash_advances) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from employees e where e.id = a.employee_id and e.user_id = auth.uid())
$$;

-- Lines can be changed only by the holder (or Finance) while the advance is open.
create or replace function public.advance_line_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare a cash_advances; r record;
begin
  r := case when tg_op = 'DELETE' then old else new end;
  select * into a from cash_advances where id = r.advance_id;
  if not found then raise exception 'Advance not found'; end if;
  if a.status <> 'open' then raise exception '% has been submitted for retirement; ask Finance to send it back to change it', a.number; end if;
  if not (advance_holder(a) or is_finance(a.company_id)) then raise exception 'Only the person holding the advance or Finance can record what it was spent on'; end if;
  if tg_op <> 'DELETE' then
    new.company_id := a.company_id;
    if not exists (select 1 from accounts where id = new.account_id and company_id = a.company_id and type in ('expense','asset')) then raise exception 'Choose an expense account'; end if;
    new.project_id := coalesce(new.project_id, a.project_id); new.cost_centre_id := coalesce(new.cost_centre_id, a.cost_centre_id);
    return new;
  end if;
  return old;
end $$;
create trigger advance_lines_guard before insert or update or delete on public.advance_lines for each row execute function public.advance_line_guard();
create trigger advance_lines_spend_gate before insert on public.advance_lines for each row execute function public.project_spend_gate();

-- Finance pays an approved cash-advance request: Dr Staff cash advances, Cr bank or cash.
create or replace function public.pay_advance(p_request uuid, p_from uuid default null, p_date date default current_date, p_due date default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare r spend_requests; v uuid; n text; v_from uuid; v_je uuid; why text; v_due date;
begin
  r := spend_request_ready(p_request);
  if r.kind <> 'cash_advance' then raise exception '% is not a cash advance request', r.number; end if;
  if not is_finance(r.company_id) then raise exception 'Only Finance can pay advances'; end if;
  why := advance_block_reason(r.employee_id);
  if why is not null then raise exception '%', why; end if;
  v_from := paying_account(r.company_id, p_from);
  v_due := coalesce(p_due, greatest(coalesce(r.needed_by, p_date), p_date) + (select advance_retire_days from companies where id = r.company_id));
  n := next_number(r.company_id, 'ADV', 'ADV-');
  insert into cash_advances (company_id, number, request_id, employee_id, purpose, amount, issued_on, paid_from, due_on, project_id, branch_id, cost_centre_id)
  values (r.company_id, n, r.id, r.employee_id, r.title, r.amount, coalesce(p_date, current_date), v_from, v_due, r.project_id, r.branch_id, r.cost_centre_id)
  returning id into v;
  v_je := post_journal(r.company_id, coalesce(p_date, current_date), 'Cash advance ' || n || ' to ' || (select full_name from employees where id = r.employee_id) || ': ' || r.title,
    jsonb_build_array(jl(acct(r.company_id, 'staff_advances'), r.amount, 0), jl(v_from, 0, r.amount)), 'cash_advance', v);
  update cash_advances set journal_entry_id = v_je where id = v;
  perform spend_request_done(p_request, 'advance', v, n);
  perform notify(r.company_id, array[]::text[], array[(select user_id from employees where id = r.employee_id)], 'advance_paid',
    'Advance ' || n || ' of GH₵ ' || to_char(r.amount, 'FM999,999,990.00') || ' paid to you', 'Retire it with receipts by ' || to_char(v_due, 'DD Mon YYYY') || '.', '/advances/' || v, true);
  return v;
end $$;

create or replace function public.submit_retirement(p_advance uuid) returns void
language plpgsql security definer set search_path = public as $$
declare a cash_advances; n int; nr int;
begin
  select * into a from cash_advances where id = p_advance for update;
  if not found then raise exception 'Advance not found'; end if;
  if not (advance_holder(a) or is_finance(a.company_id)) then raise exception 'Only the person holding the advance can submit it'; end if;
  if a.status <> 'open' then raise exception '% is already %', a.number, a.status; end if;
  select count(*), count(*) filter (where coalesce(receipt_path, '') = '') into n, nr from advance_lines where advance_id = a.id;
  if nr > 0 then raise exception 'Attach a receipt (a photo is fine) to every line before submitting. % line(s) have none.', nr; end if;
  update cash_advances set status = 'submitted', submitted_at = now(), returned_note = null where id = a.id;
  perform notify(a.company_id, array['accountant'], null, 'retirement_submitted', a.number || ' submitted for retirement',
    (select full_name from employees where id = a.employee_id) || ': ' || n || ' receipt(s)', '/advances/' || a.id);
end $$;

create or replace function public.return_retirement(p_advance uuid, p_note text) returns void
language plpgsql security definer set search_path = public as $$
declare a cash_advances;
begin
  select * into a from cash_advances where id = p_advance for update;
  if not found then raise exception 'Advance not found'; end if;
  if not is_finance(a.company_id) then raise exception 'Only Finance can send a retirement back'; end if;
  if a.status <> 'submitted' then raise exception '% is not waiting for checking', a.number; end if;
  if coalesce(trim(p_note), '') = '' then raise exception 'Say what needs fixing'; end if;
  update cash_advances set status = 'open', returned_note = p_note where id = a.id;
  perform notify(a.company_id, array[]::text[], array[(select user_id from employees where id = a.employee_id)], 'retirement_returned', a.number || ' sent back: ' || p_note, null, '/advances/' || a.id, true);
end $$;

-- Finance accepts the receipts: Dr each expense, Dr cash returned (or Cr cash reimbursed), Cr Staff cash advances.
create or replace function public.approve_retirement(p_advance uuid, p_cash uuid default null, p_date date default current_date) returns uuid
language plpgsql security definer set search_path = public as $$
declare a cash_advances; v_spent numeric; v_diff numeric; v_lines jsonb := '[]'::jsonb; l record; v_cash uuid; v_je uuid; who text;
begin
  select * into a from cash_advances where id = p_advance for update;
  if not found then raise exception 'Advance not found'; end if;
  if not is_finance(a.company_id) then raise exception 'Only Finance can approve a retirement'; end if;
  if advance_holder(a) and not has_role(a.company_id, array['owner']) then raise exception 'You cannot approve the retirement of your own advance'; end if;
  if a.status <> 'submitted' then raise exception '% has not been submitted for retirement', a.number; end if;
  select coalesce(sum(amount), 0) into v_spent from advance_lines where advance_id = a.id;
  v_diff := a.amount - v_spent;                 -- > 0: cash to return; < 0: we owe them
  v_cash := case when v_diff <> 0 then paying_account(a.company_id, p_cash) end;
  select full_name into who from employees where id = a.employee_id;
  for l in select * from advance_lines where advance_id = a.id loop
    v_lines := v_lines || jsonb_build_array(jl(l.account_id, l.amount, 0) || jsonb_build_object('project_id', l.project_id, 'cost_centre_id', l.cost_centre_id, 'branch_id', a.branch_id));
  end loop;
  if v_diff > 0 then v_lines := v_lines || jsonb_build_array(jl(v_cash, v_diff, 0)); end if;
  if v_diff < 0 then v_lines := v_lines || jsonb_build_array(jl(v_cash, 0, -v_diff)); end if;
  v_lines := v_lines || jsonb_build_array(jl(acct(a.company_id, 'staff_advances'), 0, a.amount));
  v_je := post_journal(a.company_id, coalesce(p_date, current_date), 'Retirement of ' || a.number || ' (' || who || ')' ||
            case when v_diff > 0 then ': GH₵ ' || to_char(v_diff, 'FM999,999,990.00') || ' returned' when v_diff < 0 then ': GH₵ ' || to_char(-v_diff, 'FM999,999,990.00') || ' reimbursed' else '' end,
            v_lines, 'advance_retirement', a.id);
  update cash_advances set status = 'retired', spent = v_spent, cash_returned = greatest(v_diff, 0), reimbursed = greatest(-v_diff, 0),
         retired_on = coalesce(p_date, current_date), retired_by = auth.uid(), retire_entry_id = v_je where id = a.id;
  perform notify(a.company_id, array[]::text[], array[(select user_id from employees where id = a.employee_id)], 'advance_retired', a.number || ' retired', null, '/advances/' || a.id, true);
  return v_je;
end $$;

-- Not retired long after the due date: move the balance to a staff loan recovered through payroll.
create or replace function public.recover_advance(p_advance uuid, p_installment numeric default null, p_date date default current_date) returns uuid
language plpgsql security definer set search_path = public as $$
declare a cash_advances; v_loan uuid; v_je uuid; v_days int;
begin
  select * into a from cash_advances where id = p_advance for update;
  if not found then raise exception 'Advance not found'; end if;
  if not is_finance(a.company_id) then raise exception 'Only Finance can recover an advance through payroll'; end if;
  if a.status <> 'open' then raise exception '% is %; only an open advance can be recovered', a.number, a.status; end if;
  select advance_recover_after_days into v_days from companies where id = a.company_id;
  if a.due_on + v_days > coalesce(p_date, current_date) then
    raise exception '% can be recovered through payroll from % (% days after it was due)', a.number, to_char(a.due_on + v_days, 'DD Mon YYYY'), v_days;
  end if;
  insert into employee_loans (company_id, employee_id, issue_date, principal, installment, balance, note)
  values (a.company_id, a.employee_id, coalesce(p_date, current_date), a.amount, least(coalesce(p_installment, a.amount), a.amount), a.amount, 'Unretired advance ' || a.number)
  returning id into v_loan;
  v_je := post_journal(a.company_id, coalesce(p_date, current_date), 'Unretired advance ' || a.number || ' moved to staff loan for payroll recovery',
    jsonb_build_array(jl(acct(a.company_id, 'staff_loans'), a.amount, 0), jl(acct(a.company_id, 'staff_advances'), 0, a.amount)), 'cash_advance', a.id);
  update employee_loans set journal_entry_id = v_je where id = v_loan;
  update cash_advances set status = 'recovered', loan_id = v_loan, retired_on = coalesce(p_date, current_date), retired_by = auth.uid(), retire_entry_id = v_je where id = a.id;
  perform notify(a.company_id, array[]::text[], array[(select user_id from employees where id = a.employee_id)], 'advance_recovered',
    a.number || ' will be deducted from your salary', 'GH₵ ' || to_char(least(coalesce(p_installment, a.amount), a.amount), 'FM999,999,990.00') || ' a month until repaid.', '/advances/' || a.id, true);
  return v_loan;
end $$;

-- ---------------------------------------------------------------- 4. Petty cash floats (fixed imprest)
create table public.petty_floats (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  name text not null,
  account_id uuid not null references public.accounts(id),
  custodian_id uuid not null,                    -- a user
  float_amount numeric(14,2) not null check (float_amount > 0),
  voucher_limit numeric(14,2) not null check (voucher_limit > 0),
  count_every_days int not null default 30 check (count_every_days between 1 and 92),
  project_id uuid references public.projects(id) on delete set null,
  branch_id uuid references public.branches(id) on delete set null,
  cost_centre_id uuid references public.cost_centres(id) on delete set null,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.petty_replenishments (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  float_id uuid not null references public.petty_floats(id) on delete cascade,
  number text,
  rep_date date not null,
  vouchers_total numeric(14,2) not null,
  topup numeric(14,2) not null,                  -- restores shortages already written off
  amount numeric(14,2) not null,
  paid_from uuid references public.accounts(id),
  journal_entry_id uuid references public.journal_entries(id),
  note text,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);

create table public.petty_vouchers (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  float_id uuid not null references public.petty_floats(id) on delete cascade,
  number text,
  voucher_date date not null default current_date,
  payee text not null,
  description text not null,
  account_id uuid not null references public.accounts(id),
  amount numeric(14,2) not null check (amount > 0),
  project_id uuid references public.projects(id) on delete set null,
  cost_centre_id uuid references public.cost_centres(id) on delete set null,
  receipt_path text,
  status text not null default 'recorded' check (status in ('recorded','approved','rejected')),
  reject_note text,
  replenishment_id uuid references public.petty_replenishments(id) on delete set null,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);

create table public.petty_counts (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  float_id uuid not null references public.petty_floats(id) on delete cascade,
  count_date date not null default current_date,
  counted_by uuid default auth.uid(),
  denominations jsonb not null default '{}',     -- {"200": 3, "50": 4, "0.5": 6, ...}
  counted numeric(14,2) not null,
  expected numeric(14,2) not null,
  difference numeric(14,2) not null,             -- counted - expected; negative is a shortage
  note text,
  status text not null default 'submitted' check (status in ('submitted','approved')),
  treatment text check (treatment in ('expense','custodian','none')),
  approved_by uuid, approved_at timestamptz, approval_note text,
  journal_entry_id uuid references public.journal_entries(id),
  created_at timestamptz not null default now()
);

create or replace function public.float_custodian(f petty_floats) returns boolean
language sql stable security definer set search_path = public as $$ select f.custodian_id = auth.uid() $$;

-- Ledger balance of the float, vouchers not yet replenished, and the cash that should be in the box.
create or replace function public.float_position(p_float uuid)
returns table (ledger numeric, unreplenished numeric, expected_cash numeric, last_count date, last_count_status text, count_due boolean)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare f petty_floats;
begin
  select * into f from petty_floats where id = p_float;
  return query
  select b.v, u.v, b.v - u.v, c.count_date, c.status,
         (c.count_date is null and u.v > 0) or c.count_date < current_date - f.count_every_days
    from (select coalesce(sum(debit - credit), 0) v from journal_lines where account_id = f.account_id) b,
         (select coalesce(sum(amount), 0) v from petty_vouchers where float_id = f.id and replenishment_id is null and status <> 'rejected') u
    left join lateral (select count_date, status from petty_counts where float_id = f.id order by count_date desc, created_at desc limit 1) c on true;
end $$;

create or replace function public.create_petty_float(cid uuid, p_name text, p_custodian uuid, p_amount numeric, p_voucher_limit numeric,
  p_count_days int default 30, p_from uuid default null, p_date date default current_date, p_project uuid default null, p_branch uuid default null, p_cost_centre uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_acct uuid; v_code int; v uuid; v_from uuid;
begin
  if not is_finance(cid) then raise exception 'Only Finance can set up petty cash floats'; end if;
  if coalesce(trim(p_name), '') = '' then raise exception 'Name the float (e.g. Prestea site petty cash)'; end if;
  if not exists (select 1 from memberships where company_id = cid and user_id = p_custodian) then raise exception 'The custodian must be on the team'; end if;
  if p_voucher_limit > p_amount then raise exception 'The limit per voucher cannot be more than the float'; end if;
  v_from := paying_account(cid, p_from);
  select coalesce(max(code::int), 1019) + 1 into v_code from accounts where company_id = cid and code ~ '^10[2-9][0-9]$';
  if v_code > 1099 then raise exception 'No free account codes left for petty cash (1020 to 1099)'; end if;
  insert into accounts (company_id, code, name, type) values (cid, v_code::text, 'Petty cash: ' || trim(p_name), 'asset') returning id into v_acct;
  insert into petty_floats (company_id, name, account_id, custodian_id, float_amount, voucher_limit, count_every_days, project_id, branch_id, cost_centre_id)
  values (cid, trim(p_name), v_acct, p_custodian, p_amount, p_voucher_limit, coalesce(p_count_days, 30), p_project, p_branch, p_cost_centre) returning id into v;
  perform post_journal(cid, coalesce(p_date, current_date), 'Petty cash float set up: ' || trim(p_name), jsonb_build_array(jl(v_acct, p_amount, 0) || jsonb_build_object('branch_id', p_branch), jl(v_from, 0, p_amount)), 'petty_float', v);
  perform notify(cid, array[]::text[], array[p_custodian], 'petty_float', 'You hold the petty cash float ' || trim(p_name), 'GH₵ ' || to_char(p_amount, 'FM999,999,990.00') || '. Record every payout as a voucher with its receipt.', '/petty-cash', true);
  return v;
end $$;

create or replace function public.petty_voucher_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare f petty_floats; p record;
begin
  select * into f from petty_floats where id = coalesce(new.float_id, old.float_id);
  if tg_op = 'DELETE' then
    if old.replenishment_id is not null or old.status <> 'recorded' then raise exception 'This voucher has been replenished and is in the books'; end if;
    if not (float_custodian(f) or is_finance(f.company_id)) then raise exception 'Only the custodian or Finance can remove it'; end if;
    return old;
  end if;
  if coalesce(current_setting('sika.petty', true), '') = 'on' then return new; end if;
  if tg_op = 'UPDATE' then
    if old.replenishment_id is not null or old.status <> 'recorded' then raise exception 'This voucher has been replenished and is in the books'; end if;
    if new.status <> old.status or new.replenishment_id is distinct from old.replenishment_id then raise exception 'Vouchers are approved when the float is replenished'; end if;
  else
    new.number := next_number(f.company_id, 'PCV', 'PCV-'); new.status := 'recorded'; new.replenishment_id := null; new.created_by := auth.uid();
  end if;
  if not f.active then raise exception '% is closed', f.name; end if;
  if not (float_custodian(f) or is_finance(f.company_id)) then raise exception 'Only the custodian of % or Finance can record vouchers', f.name; end if;
  new.company_id := f.company_id;
  if not exists (select 1 from accounts where id = new.account_id and company_id = f.company_id and type in ('expense','asset')) then raise exception 'Choose an expense account'; end if;
  if new.amount > f.voucher_limit then raise exception 'GH₵ % is over the limit of GH₵ % per voucher for %. Use a spend request for bigger payments.', new.amount, f.voucher_limit, f.name; end if;
  select * into p from float_position(f.id);
  if new.amount - (case when tg_op = 'UPDATE' then old.amount else 0 end) > p.expected_cash then
    raise exception 'Only GH₵ % should be left in %. Ask Finance to replenish it.', p.expected_cash, f.name;
  end if;
  new.project_id := coalesce(new.project_id, f.project_id); new.cost_centre_id := coalesce(new.cost_centre_id, f.cost_centre_id);
  return new;
end $$;
create trigger petty_vouchers_guard before insert or update or delete on public.petty_vouchers for each row execute function public.petty_voucher_guard();
create trigger petty_vouchers_spend_gate before insert on public.petty_vouchers for each row execute function public.project_spend_gate();

-- The custodian (or Finance) counts the cash by note and coin.
create or replace function public.count_petty_cash(p_float uuid, p_denominations jsonb, p_note text default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare f petty_floats; p record; v_counted numeric := 0; k text; v uuid; n numeric;
begin
  select * into f from petty_floats where id = p_float;
  if not found then raise exception 'Float not found'; end if;
  if not (float_custodian(f) or is_finance(f.company_id)) then raise exception 'Only the custodian or Finance can count %', f.name; end if;
  if exists (select 1 from petty_counts where float_id = f.id and status = 'submitted') then raise exception 'The last count of % is still waiting for Finance', f.name; end if;
  for k in select jsonb_object_keys(coalesce(p_denominations, '{}')) loop
    if k not in ('200','100','50','20','10','5','2','1','0.5','0.2','0.1','0.05','0.01') then raise exception 'Unknown note or coin: %', k; end if;
    n := (p_denominations->>k)::numeric;
    if n < 0 or n <> trunc(n) then raise exception 'Count whole notes and coins'; end if;
    v_counted := v_counted + n * k::numeric;
  end loop;
  select * into p from float_position(f.id);
  insert into petty_counts (company_id, float_id, denominations, counted, expected, difference, note, status, treatment, approved_at)
  values (f.company_id, f.id, coalesce(p_denominations, '{}'), round(v_counted, 2), p.expected_cash, round(v_counted - p.expected_cash, 2), p_note,
          case when round(v_counted - p.expected_cash, 2) = 0 then 'approved' else 'submitted' end,
          case when round(v_counted - p.expected_cash, 2) = 0 then 'none' end, case when round(v_counted - p.expected_cash, 2) = 0 then now() end)
  returning id into v;
  if round(v_counted - p.expected_cash, 2) <> 0 then
    perform notify(f.company_id, array['accountant'], null, 'petty_count_difference',
      f.name || ': cash count is ' || case when v_counted < p.expected_cash then 'short' else 'over' end || ' by GH₵ ' || to_char(abs(v_counted - p.expected_cash), 'FM999,999,990.00'),
      coalesce(p_note, ''), '/petty-cash', true);
  end if;
  return v;
end $$;

-- Finance (not the person who counted) accepts a difference: shortage to expense or charged to the custodian; overage to income.
create or replace function public.approve_petty_count(p_count uuid, p_treatment text default 'expense', p_note text default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare c petty_counts; f petty_floats; v_je uuid; d numeric; v_emp uuid; v_loan uuid; other uuid;
begin
  select * into c from petty_counts where id = p_count for update;
  if not found then raise exception 'Count not found'; end if;
  select * into f from petty_floats where id = c.float_id;
  if not is_finance(c.company_id) then raise exception 'Only Finance can approve a cash count difference'; end if;
  if c.counted_by = auth.uid() and not has_role(c.company_id, array['owner']) then raise exception 'Someone other than the person who counted must approve it'; end if;
  if c.status <> 'submitted' then raise exception 'This count is already approved'; end if;
  if coalesce(trim(p_note), '') = '' then raise exception 'Explain the difference'; end if;
  d := c.difference;
  if d < 0 then
    if p_treatment = 'custodian' then
      select id into v_emp from employees where company_id = c.company_id and user_id = f.custodian_id limit 1;
      if v_emp is null then raise exception 'The custodian has no employee record, so the shortage cannot be charged to them'; end if;
      insert into employee_loans (company_id, employee_id, issue_date, principal, installment, balance, note)
      values (c.company_id, v_emp, current_date, -d, -d, -d, 'Petty cash shortage: ' || f.name) returning id into v_loan;
      other := acct(c.company_id, 'staff_loans');
    else
      other := acct(c.company_id, 'cash_short');
    end if;
    v_je := post_journal(c.company_id, c.count_date, 'Petty cash shortage: ' || f.name || ' · ' || p_note,
      jsonb_build_array(jl(other, -d, 0) || jsonb_build_object('branch_id', f.branch_id, 'cost_centre_id', f.cost_centre_id), jl(f.account_id, 0, -d)), 'petty_count', c.id);
    if v_loan is not null then update employee_loans set journal_entry_id = v_je where id = v_loan; end if;
  else
    v_je := post_journal(c.company_id, c.count_date, 'Petty cash overage: ' || f.name || ' · ' || p_note,
      jsonb_build_array(jl(f.account_id, d, 0), jl(acct(c.company_id, 'cash_over'), 0, d)), 'petty_count', c.id);
  end if;
  update petty_counts set status = 'approved', treatment = case when d < 0 then coalesce(p_treatment, 'expense') else 'none' end,
         approved_by = auth.uid(), approved_at = now(), approval_note = p_note, journal_entry_id = v_je where id = c.id;
  return v_je;
end $$;

-- Top the float back up to its full amount: Dr each approved voucher's expense, Dr the float for written-off shortages, Cr the bank.
create or replace function public.replenish_float(p_float uuid, p_from uuid default null, p_date date default current_date, p_reject uuid[] default '{}', p_reject_note text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare f petty_floats; p record; v_from uuid; v_lines jsonb := '[]'::jsonb; v record; v_tot numeric := 0; v_top numeric; v_id uuid; v_je uuid; n text;
begin
  select * into f from petty_floats where id = p_float for update;
  if not found then raise exception 'Float not found'; end if;
  if not is_finance(f.company_id) then raise exception 'Only Finance can replenish petty cash'; end if;
  if f.custodian_id = auth.uid() and not has_role(f.company_id, array['owner']) then raise exception 'The custodian cannot replenish their own float'; end if;
  select * into p from float_position(f.id);
  if p.last_count_status = 'submitted' then raise exception 'The last cash count of % has a difference waiting for approval. Approve it first.', f.name; end if;
  if p.last_count is null then raise exception 'Count the cash in % before replenishing it', f.name; end if;
  if p.last_count < coalesce(p_date, current_date) - least(f.count_every_days, 7) then
    raise exception '% was last counted on %. Count it again (within 7 days) before replenishing.', f.name, to_char(p.last_count, 'DD Mon YYYY');
  end if;
  if exists (select 1 from petty_vouchers where float_id = f.id and replenishment_id is null and status = 'recorded' and created_at > (select max(created_at) from petty_counts where float_id = f.id)) then
    raise exception 'Vouchers were recorded after the last count. Count the cash again first.';
  end if;
  if exists (select 1 from petty_vouchers where float_id = f.id and replenishment_id is null and status = 'recorded' and coalesce(receipt_path, '') = '' and not (id = any(coalesce(p_reject, '{}')))) then
    raise exception 'Some vouchers have no receipt. Reject them or attach the receipts first.';
  end if;
  if coalesce(array_length(p_reject, 1), 0) > 0 and coalesce(trim(p_reject_note), '') = '' then raise exception 'Say why vouchers were rejected'; end if;
  v_from := paying_account(f.company_id, p_from);
  n := next_number(f.company_id, 'PCR', 'PCR-');
  insert into petty_replenishments (company_id, float_id, number, rep_date, vouchers_total, topup, amount, paid_from, note)
  values (f.company_id, f.id, n, coalesce(p_date, current_date), 0, 0, 0, v_from, p_reject_note) returning id into v_id;
  perform set_config('sika.petty', 'on', true);
  update petty_vouchers set status = 'rejected', reject_note = p_reject_note, replenishment_id = v_id
   where float_id = f.id and replenishment_id is null and status = 'recorded' and id = any(coalesce(p_reject, '{}'));
  for v in select * from petty_vouchers where float_id = f.id and replenishment_id is null and status = 'recorded' loop
    v_lines := v_lines || jsonb_build_array(jl(v.account_id, v.amount, 0) || jsonb_build_object('project_id', v.project_id, 'cost_centre_id', v.cost_centre_id, 'branch_id', f.branch_id));
    v_tot := v_tot + v.amount;
  end loop;
  update petty_vouchers set status = 'approved', replenishment_id = v_id where float_id = f.id and replenishment_id is null and status = 'recorded';
  perform set_config('sika.petty', 'off', true);
  v_top := f.float_amount - p.ledger;         -- shortages written off since the last top-up
  if v_top < 0 then v_top := 0; end if;
  if v_tot + v_top = 0 then raise exception 'Nothing to replenish: % is full', f.name; end if;
  if v_top > 0 then v_lines := v_lines || jsonb_build_array(jl(f.account_id, v_top, 0)); end if;
  v_lines := v_lines || jsonb_build_array(jl(v_from, 0, v_tot + v_top));
  v_je := post_journal(f.company_id, coalesce(p_date, current_date), 'Petty cash replenishment ' || n || ': ' || f.name, v_lines, 'petty_replenishment', v_id);
  update petty_replenishments set vouchers_total = v_tot, topup = v_top, amount = v_tot + v_top, journal_entry_id = v_je where id = v_id;
  perform notify(f.company_id, array[]::text[], array[f.custodian_id], 'petty_replenished', f.name || ' replenished with GH₵ ' || to_char(v_tot + v_top, 'FM999,999,990.00'),
    case when coalesce(array_length(p_reject, 1), 0) > 0 then array_length(p_reject, 1) || ' voucher(s) rejected: ' || p_reject_note end, '/petty-cash', true);
  return v_id;
end $$;

-- ---------------------------------------------------------------- 5. Books checks and reminders
alter function public.ledger_checks(uuid) rename to ledger_checks_v26;
create or replace function public.ledger_checks(cid uuid)
returns table (check_name text, ledger numeric, documents numeric, direct numeric, difference numeric, ok boolean, explanation text)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare bal numeric; doc numeric;
begin
  return query select * from ledger_checks_v26(cid);
  if not has_role(cid, array['owner','admin','accountant']) then return; end if;
  select coalesce(sum(l.debit - l.credit), 0) into bal from journal_lines l where l.account_id = acct(cid, 'staff_advances');
  select coalesce(sum(amount), 0) into doc from cash_advances where company_id = cid and status in ('open','submitted');
  return query select 'Staff cash advances vs advances not yet retired', bal, doc, 0::numeric, bal - doc, abs(bal - doc) < 0.01,
    'Every advance paid and not yet retired or recovered. A difference means something was posted to 1260 by hand.';
  select coalesce(sum(l.debit - l.credit), 0) into bal from journal_lines l join petty_floats f on f.account_id = l.account_id where f.company_id = cid;
  select coalesce(sum(f.float_amount + coalesce((select sum(c.difference) from petty_counts c where c.float_id = f.id and c.status = 'approved' and c.difference <> 0
            and c.approved_at > coalesce((select max(r.created_at) from petty_replenishments r where r.float_id = f.id), '-infinity')), 0)), 0)
    into doc from petty_floats f where f.company_id = cid;
  return query select 'Petty cash floats vs float amounts', bal, doc, 0::numeric, bal - doc, abs(bal - doc) < 0.01,
    'Each float''s ledger account should equal its float less any shortage written off since its last replenishment.';
end $$;

create or replace function public.cash_control_status(cid uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  perform require_member(cid);
  return jsonb_build_object(
    'my_requests_open', (select count(*) from spend_requests where company_id = cid and requested_by = me and status in ('draft','submitted','approved')),
    'to_action', case when is_finance(cid) then (select count(*) from spend_requests where company_id = cid and status = 'approved') else 0 end,
    'my_advances_open', (select count(*) from cash_advances a join employees e on e.id = a.employee_id where a.company_id = cid and e.user_id = me and a.status = 'open'),
    'my_advances_overdue', (select count(*) from cash_advances a join employees e on e.id = a.employee_id where a.company_id = cid and e.user_id = me and a.status = 'open' and a.due_on < current_date),
    'advances_overdue', case when is_finance(cid) then (select count(*) from cash_advances where company_id = cid and status = 'open' and due_on < current_date) else 0 end,
    'retirements_to_check', case when is_finance(cid) then (select count(*) from cash_advances where company_id = cid and status = 'submitted') else 0 end,
    'counts_to_approve', case when is_finance(cid) then (select count(*) from petty_counts where company_id = cid and status = 'submitted') else 0 end,
    'floats_count_due', (select count(*) from petty_floats f, float_position(f.id) p where f.company_id = cid and f.active and p.count_due and (is_finance(cid) or f.custodian_id = me)));
end $$;

create or replace function public.run_cash_reminders_internal(cid uuid) returns int
language plpgsql security definer set search_path = public as $$
declare r record; n int := 0; k text;
begin
  for r in select a.*, e.user_id uid, e.full_name from cash_advances a join employees e on e.id = a.employee_id
            where a.company_id = cid and a.status = 'open' and a.due_on <= current_date + 2 loop
    k := 'adv:' || r.id || ':' || case when r.due_on < current_date then 'late' else 'soon' end;
    if not exists (select 1 from payment_reminders where company_id = cid and key = k) then
      insert into payment_reminders (company_id, key) values (cid, k);
      perform notify(cid, case when r.due_on < current_date then array['accountant'] else array[]::text[] end, array[r.uid], 'advance_due',
        r.number || ' (' || r.full_name || ') ' || case when r.due_on < current_date then 'was due for retirement on ' else 'is due for retirement on ' end || to_char(r.due_on, 'DD Mon YYYY'),
        'GH₵ ' || to_char(r.amount, 'FM999,999,990.00') || ': ' || r.purpose, '/advances/' || r.id, true);
      n := n + 1;
    end if;
  end loop;
  for r in select f.*, p.last_count from petty_floats f, float_position(f.id) p where f.company_id = cid and f.active and p.count_due loop
    k := 'pcc:' || r.id || ':' || coalesce(r.last_count::text, 'never');
    if not exists (select 1 from payment_reminders where company_id = cid and key = k) then
      insert into payment_reminders (company_id, key) values (cid, k);
      perform notify(cid, array['accountant'], array[r.custodian_id], 'petty_count_due', 'Count the cash in ' || r.name,
        case when r.last_count is null then 'It has not been counted yet.' else 'Last counted ' || to_char(r.last_count, 'DD Mon YYYY') || '.' end, '/petty-cash', true);
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;
create or replace function public.run_cash_reminders(cid uuid) returns int
language plpgsql security definer set search_path = public as $$
begin perform require_member(cid); return run_cash_reminders_internal(cid); end $$;
create or replace function public.run_all_cash_reminders() returns int
language plpgsql security definer set search_path = public as $$
declare c record; n int := 0;
begin
  for c in select id from companies loop
    begin n := n + coalesce(run_cash_reminders_internal(c.id), 0); exception when others then null; end;
  end loop;
  return n;
end $$;


-- ---------------------------------------------------------------- 7. Purchase orders and requests in other currencies
-- A PO can be in USD, EUR or any currency set up in Settings. Each line keeps the supplier's price (unit_price_fx) and its
-- GHS cost at the order's rate (unit_cost), so stock, goods-received accruals and approval limits stay in GHS.
-- The supplier bill made from the order carries the order's currency at the day's rate. When it is posted, the rate
-- difference on goods already received goes to 4800 Foreign exchange gains and losses, and any price difference to 5150.
alter table public.purchase_orders add column if not exists currency text not null default 'GHS';
alter table public.purchase_orders add column if not exists exchange_rate numeric(14,6) not null default 1 check (exchange_rate > 0);
alter table public.po_lines add column if not exists unit_price_fx numeric(14,4) check (unit_price_fx >= 0);

create or replace function public.po_line_fx() returns trigger
language plpgsql security definer set search_path = public as $$
declare o purchase_orders;
begin
  select * into o from purchase_orders where id = new.po_id;
  if coalesce(o.currency, 'GHS') = 'GHS' then new.unit_price_fx := null; return new; end if;
  if new.unit_price_fx is null then new.unit_price_fx := round(new.unit_cost / o.exchange_rate, 4); end if;
  new.unit_cost := round(new.unit_price_fx * o.exchange_rate, 2);
  return new;
end $$;
create trigger po_lines_fx before insert or update on public.po_lines for each row execute function public.po_line_fx();

create or replace function public.po_currency_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.currency := upper(trim(coalesce(new.currency, 'GHS')));
  if new.currency = 'GHS' then new.exchange_rate := 1; end if;
  if tg_op = 'UPDATE' and (new.currency, new.exchange_rate) is distinct from (old.currency, old.exchange_rate) and old.status <> 'draft' then
    raise exception 'The currency and rate of % are fixed once it is approved', old.number;
  end if;
  return new;
end $$;
create trigger purchase_orders_currency before insert or update on public.purchase_orders for each row execute function public.po_currency_guard();

create or replace function public.po_rate_changed() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if (new.currency, new.exchange_rate) is distinct from (old.currency, old.exchange_rate) then
    update po_lines set unit_cost = round(unit_price_fx * new.exchange_rate, 2) where po_id = new.id and unit_price_fx is not null;
  end if;
  return new;
end $$;
create trigger purchase_orders_rate_changed after update on public.purchase_orders for each row execute function public.po_rate_changed();

create or replace function public.po_total_fx(p uuid) returns numeric language sql stable as $$
  select coalesce(round(sum(qty * coalesce(unit_price_fx, unit_cost)), 2), 0) from po_lines where po_id = p;
$$;

create or replace function public.bill_from_po(p_po uuid, p_ref text default null, p_date date default current_date, p_all boolean default false)
returns uuid language plpgsql security definer set search_path = public as $$
declare o purchase_orders; v_bill uuid; l record; i int := 0; q numeric; v_rate numeric;
begin
  select * into o from purchase_orders where id = p_po;
  if not found then raise exception 'Purchase order not found'; end if;
  perform require_member(o.company_id, array['owner','admin','accountant']);
  if o.status in ('draft','cancelled') then raise exception 'Approve the order first'; end if;
  v_rate := case when o.currency = 'GHS' then 1 else coalesce((select rate from currencies where company_id = o.company_id and code = o.currency), o.exchange_rate) end;
  insert into bills (company_id, supplier_id, supplier_ref, bill_date, warehouse_id, branch_id, currency, exchange_rate, notes)
  values (o.company_id, o.supplier_id, p_ref, p_date, o.warehouse_id, o.branch_id, o.currency, v_rate,
          'Purchase order ' || o.number || case when o.currency <> 'GHS' then ' (ordered at ' || o.exchange_rate || ')' else '' end) returning id into v_bill;
  for l in select * from po_lines where po_id = p_po order by sort loop
    q := case when p_all then l.qty - l.billed_qty else l.received_qty - l.billed_qty end;
    continue when q <= 0;
    insert into bill_lines (bill_id, company_id, product_id, account_id, description, qty, unit_cost, taxable, sort, project_id, request_id, po_line_id)
    values (v_bill, o.company_id, l.product_id, case when l.product_id is null then coalesce(l.account_id, acct(o.company_id, case when l.project_id is not null then 'project_materials' else 'expense' end)) end,
            l.description, q, coalesce(l.unit_price_fx, l.unit_cost), l.taxable, i, l.project_id, l.request_id, l.id);
    i := i + 1;
  end loop;
  if i = 0 then delete from bills where id = v_bill; raise exception 'Nothing on this order is waiting to be billed. Receive the goods first.'; end if;
  return v_bill;
end $$;

-- Supplier bills: rate differences against the order go to exchange gains and losses.
create or replace function public.post_bill(p_bill uuid)
returns text language plpgsql security definer set search_path = public as $$
declare
  b bills; l record; pr products; pl po_lines; v_lines jsonb := '[]'::jsonb; x numeric; v_dims jsonb;
  v_taxable numeric := 0; v_sub numeric := 0; v_amt numeric; g_amt numeric; g_sum numeric := 0; v_q numeric; v_r numeric; v_grni numeric; v_part numeric; v_fx numeric; po purchase_orders;
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
      if v_q > 0 then   -- already received: clear the accrual; rate difference to 4800, price difference to 5150
        v_grni := round(v_q * pl.unit_cost, 2);
        v_part := round(g_amt * v_q / l.qty, 2);
        v_fx := 0;
        select * into po from purchase_orders where id = pl.po_id;
        if pl.unit_price_fx is not null and po.currency = b.currency then
          v_fx := round(v_q * l.unit_cost * (x - po.exchange_rate), 2);      -- same foreign price, different rate
        end if;
        v_lines := v_lines || jl(acct(b.company_id,'grni'), v_grni, 0)
                           || (jl(acct(b.company_id,'ppv'), greatest(v_part - v_grni - v_fx, 0), greatest(v_grni + v_fx - v_part, 0)) || v_dims);
        if v_fx <> 0 then v_lines := v_lines || jl(acct(b.company_id,'fx'), greatest(v_fx, 0), greatest(-v_fx, 0)); end if;
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

-- Requests can be in a foreign currency; the GHS equivalent drives budgets and approval limits.
alter table public.spend_requests add column if not exists currency text not null default 'GHS';
alter table public.spend_requests add column if not exists fx_amount numeric(14,2) check (fx_amount > 0);
alter table public.spend_requests add column if not exists exchange_rate numeric(14,6) not null default 1 check (exchange_rate > 0);
create or replace function public.spend_request_fx() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.currency := upper(trim(coalesce(new.currency, 'GHS')));
  if new.currency = 'GHS' then new.exchange_rate := 1; new.fx_amount := null; return new; end if;
  if new.kind = 'cash_advance' then raise exception 'Cash advances are paid in GH₵'; end if;
  if new.fx_amount is null then raise exception 'Enter the amount in %', new.currency; end if;
  if tg_op = 'INSERT' or new.exchange_rate is null then
    new.exchange_rate := coalesce((select rate from currencies where company_id = new.company_id and code = new.currency), new.exchange_rate);
  end if;
  new.amount := round(new.fx_amount * new.exchange_rate, 2);
  return new;
end $$;
create trigger spend_requests_fx before insert or update on public.spend_requests for each row execute function public.spend_request_fx();

create or replace function public.request_to_po(p_id uuid, p_supplier uuid default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare r spend_requests; v uuid; n text;
begin
  r := spend_request_ready(p_id);
  if r.kind <> 'purchase' then raise exception 'Only a purchase request becomes a purchase order'; end if;
  if coalesce(p_supplier, r.supplier_id) is null then raise exception 'Choose the supplier'; end if;
  insert into purchase_orders (company_id, supplier_id, order_date, expected_date, project_id, branch_id, notes, currency, exchange_rate)
  values (r.company_id, coalesce(p_supplier, r.supplier_id), current_date, r.needed_by, r.project_id, r.branch_id, 'From ' || r.number || ': ' || r.title, r.currency, r.exchange_rate)
  returning id, number into v, n;
  insert into po_lines (po_id, company_id, account_id, description, qty, unit_cost, unit_price_fx, project_id)
  values (v, r.company_id, r.account_id, r.title, 1, r.amount, r.fx_amount, r.project_id);
  perform spend_request_done(p_id, 'purchase_order', v, coalesce(n, (select number from purchase_orders where id = v)));
  return v;
end $$;

create or replace function public.request_to_bill(p_id uuid, p_supplier uuid default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare r spend_requests; v uuid;
begin
  r := spend_request_ready(p_id);
  if r.kind = 'cash_advance' then raise exception 'A cash advance is paid with Pay advance'; end if;
  if coalesce(p_supplier, r.supplier_id) is null then raise exception 'Choose the supplier'; end if;
  insert into bills (company_id, supplier_id, bill_date, supplier_ref, currency, exchange_rate) values (r.company_id, coalesce(p_supplier, r.supplier_id), current_date, r.number, r.currency, r.exchange_rate) returning id into v;
  insert into bill_lines (bill_id, company_id, account_id, description, qty, unit_cost, taxable, project_id, cost_centre_id)
  values (v, r.company_id, r.account_id, r.title, 1, coalesce(r.fx_amount, r.amount), false, r.project_id, r.cost_centre_id);
  perform spend_request_done(p_id, 'bill', v, 'draft bill');
  return v;
end $$;

-- ---------------------------------------------------------------- 6. Security
alter table public.spend_requests enable row level security;
create policy "requests read" on public.spend_requests for select using (
  requested_by = auth.uid() or is_finance(company_id)
  or exists (select 1 from approval_steps s where s.doc_type = 'spend_request' and s.doc_id = spend_requests.id
             and (s.approver_user = auth.uid() or (s.approver_role is not null and has_role(s.company_id, array[s.approver_role])) or s.decided_by = auth.uid())));
create policy "requests add" on public.spend_requests for insert with check (is_member(company_id));
create policy "requests edit drafts" on public.spend_requests for update using (requested_by = auth.uid() and status = 'draft') with check (requested_by = auth.uid());
create policy "requests delete drafts" on public.spend_requests for delete using (requested_by = auth.uid() and status = 'draft');

alter table public.cash_advances enable row level security;
create policy "advances read" on public.cash_advances for select using (is_finance(company_id) or advance_holder(cash_advances) or has_role(company_id, array['hr']));
alter table public.advance_lines enable row level security;
create policy "advance lines read" on public.advance_lines for select using (exists (select 1 from cash_advances a where a.id = advance_id and (is_finance(a.company_id) or advance_holder(a))));
create policy "advance lines write" on public.advance_lines for all using (exists (select 1 from cash_advances a where a.id = advance_id and (is_finance(a.company_id) or advance_holder(a))))
  with check (exists (select 1 from cash_advances a where a.id = advance_id and (is_finance(a.company_id) or advance_holder(a))));

alter table public.petty_floats enable row level security;
create policy "floats read" on public.petty_floats for select using (is_finance(company_id) or custodian_id = auth.uid());
create policy "floats edit" on public.petty_floats for update using (is_finance(company_id)) with check (is_finance(company_id));
alter table public.petty_vouchers enable row level security;
create policy "vouchers read" on public.petty_vouchers for select using (exists (select 1 from petty_floats f where f.id = float_id and (is_finance(f.company_id) or f.custodian_id = auth.uid())));
create policy "vouchers write" on public.petty_vouchers for all using (exists (select 1 from petty_floats f where f.id = float_id and (is_finance(f.company_id) or f.custodian_id = auth.uid())))
  with check (exists (select 1 from petty_floats f where f.id = float_id and (is_finance(f.company_id) or f.custodian_id = auth.uid())));
alter table public.petty_counts enable row level security;
create policy "counts read" on public.petty_counts for select using (exists (select 1 from petty_floats f where f.id = float_id and (is_finance(f.company_id) or f.custodian_id = auth.uid())));
alter table public.petty_replenishments enable row level security;
create policy "replenishments read" on public.petty_replenishments for select using (exists (select 1 from petty_floats f where f.id = float_id and (is_finance(f.company_id) or f.custodian_id = auth.uid())));

do $$ declare t text; begin
  foreach t in array array['spend_requests','cash_advances','advance_lines','petty_floats','petty_vouchers','petty_counts','petty_replenishments'] loop
    execute format('create trigger %I after insert or update or delete on public.%I for each row execute function public.audit_row()', t || '_audit', t);
  end loop;
end $$;

-- Finance can open receipt photos attached to advances and petty cash vouchers.
do $$ begin
  if exists (select 1 from information_schema.schemata where schema_name = 'storage') then
    execute $q$create policy "receipts: imprest finance read" on storage.objects for select to authenticated
      using (bucket_id = 'receipts' and (
        exists (select 1 from public.advance_lines l where l.receipt_path = name and public.is_finance(l.company_id))
        or exists (select 1 from public.petty_vouchers v where v.receipt_path = name and public.is_finance(v.company_id))))$q$;
  end if;
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
revoke execute on function public.seed_accounts_v27(uuid) from authenticated;
revoke execute on function public.doc_info_v26(text,uuid) from authenticated;
revoke execute on function public.decide_approval_v26(uuid,boolean,text) from authenticated;
revoke execute on function public.ledger_checks_v26(uuid) from authenticated;
revoke execute on function public.spend_request_ready(uuid) from authenticated;
revoke execute on function public.spend_request_done(uuid,text,uuid,text) from authenticated;
revoke execute on function public.run_cash_reminders_internal(uuid) from authenticated;
revoke execute on function public.run_all_cash_reminders() from authenticated;
revoke execute on function public.seed_leave_types(uuid) from authenticated;
revoke execute on function public.seed_asset_categories(uuid) from authenticated;
revoke execute on function public.seed_cycle_responsibilities(uuid) from authenticated;
revoke execute on function public.next_number(uuid,text,text) from authenticated;
revoke execute on function public.notify(uuid,text[],uuid[],text,text,text,text,boolean) from authenticated;
revoke execute on function public.run_all_payment_reminders() from authenticated;
revoke execute on function public.run_all_contract_reminders() from authenticated;
revoke execute on function public.run_contract_reminders_internal(uuid) from authenticated;
revoke execute on function public.child_company() from authenticated;
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
