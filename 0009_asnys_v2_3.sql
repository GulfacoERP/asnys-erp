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
