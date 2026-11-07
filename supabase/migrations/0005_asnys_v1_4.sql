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
