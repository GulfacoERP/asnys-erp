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
