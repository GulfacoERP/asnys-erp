-- Asnys ERP: new installation, part3 of 3.
-- Contains 0010_asnys_v2_4.sql, 0011_asnys_v2_5.sql, 0012_asnys_v2_6.sql, 0013_asnys_v2_7.sql, 0014_asnys_v2_8.sql, 0015_asnys_v2_8_1.sql, 0016_asnys_v2_9.sql, 0017_asnys_v3_0.sql. Run part 1, then part 2, then part 3, once each, in a new Supabase project.


-- ======================================================================
-- 0010_asnys_v2_4.sql
-- ======================================================================
-- =====================================================================
-- Asnys ERP v2.4 — contract payment terms and payment schedules
--   Each contract (project) sets its own terms: credit days, advance, retention and its release, billing basis,
--   valuation day and how far ahead to remind. Asnys builds the payment schedule (when to invoice, when the
--   client must pay), gives project invoices their due date from the contract, and prompts Finance and the
--   project manager before each date and when one is missed.
-- Run after 0009.
-- =====================================================================

-- ---------------------------------------------------------------- 1. Terms on the contract
alter table public.projects add column if not exists contract_date date;
alter table public.projects add column if not exists payment_terms_days int check (payment_terms_days between 0 and 365);
alter table public.projects add column if not exists advance_pct numeric(5,2) not null default 0 check (advance_pct between 0 and 100);
alter table public.projects add column if not exists retention_pct numeric(5,2) not null default 0 check (retention_pct between 0 and 50);
alter table public.projects add column if not exists retention_release_days int not null default 365 check (retention_release_days between 0 and 1825);
alter table public.projects add column if not exists billing_basis text not null default 'milestones' check (billing_basis in ('milestones','monthly','on_completion'));
alter table public.projects add column if not exists valuation_day int check (valuation_day between 1 and 28);
alter table public.projects add column if not exists reminder_days int not null default 7 check (reminder_days between 0 and 60);
alter table public.projects add column if not exists payment_terms_notes text;

alter table public.tenders add column if not exists payment_terms_days int check (payment_terms_days between 0 and 365);
alter table public.tenders add column if not exists advance_pct numeric(5,2) not null default 0 check (advance_pct between 0 and 100);
alter table public.tenders add column if not exists retention_pct numeric(5,2) not null default 0 check (retention_pct between 0 and 50);
alter table public.tenders add column if not exists payment_terms_notes text;

-- Projects registered from an award take the award's terms.
create or replace function public.project_terms_from_tender() returns trigger
language plpgsql security definer set search_path = public as $$
declare t tenders;
begin
  if new.tender_id is not null then
    select * into t from tenders where id = new.tender_id;
    new.payment_terms_days := coalesce(new.payment_terms_days, t.payment_terms_days);
    new.advance_pct := case when coalesce(new.advance_pct, 0) = 0 then coalesce(t.advance_pct, 0) else new.advance_pct end;
    new.retention_pct := case when coalesce(new.retention_pct, 0) = 0 then coalesce(t.retention_pct, 0) else new.retention_pct end;
    new.payment_terms_notes := coalesce(new.payment_terms_notes, t.payment_terms_notes);
    new.contract_date := coalesce(new.contract_date, t.contract_signed_on);
  end if;
  return new;
end $$;
create trigger projects_terms_from_tender before insert on public.projects for each row execute function public.project_terms_from_tender();

-- ---------------------------------------------------------------- 2. Payment schedule
create table public.project_payment_schedule (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  project_id uuid not null references public.projects(id) on delete cascade,
  seq int not null default 0,
  kind text not null check (kind in ('advance','milestone','valuation','completion','retention','other')),
  description text not null,
  amount numeric(14,2) not null check (amount >= 0),   -- project currency, excluding VAT
  invoice_on date not null,                            -- when Finance should raise the invoice
  due_on date,                                         -- when the client should pay (invoice date + credit days)
  milestone_id uuid references public.project_milestones(id) on delete set null,
  invoice_id uuid references public.invoices(id) on delete set null,
  notes text,
  created_at timestamptz not null default now()
);
create index on public.project_payment_schedule (project_id, invoice_on);

create or replace function public.payment_schedule_defaults() returns trigger
language plpgsql security definer set search_path = public as $$
declare pr projects;
begin
  select * into pr from projects where id = new.project_id;
  new.company_id := pr.company_id;
  if new.due_on is null or (tg_op = 'UPDATE' and new.invoice_on is distinct from old.invoice_on and old.due_on = old.invoice_on + coalesce(pr.payment_terms_days, 30)) then
    new.due_on := new.invoice_on + coalesce(pr.payment_terms_days, 30);
  end if;
  if tg_op = 'UPDATE' and old.invoice_id is not null and (new.amount, new.kind) is distinct from (old.amount, old.kind) then
    raise exception 'This payment has been invoiced; change the invoice or add an adjustment line instead';
  end if;
  return new;
end $$;
create trigger project_payment_schedule_defaults before insert or update on public.project_payment_schedule for each row execute function public.payment_schedule_defaults();
create trigger project_payment_schedule_closed before insert on public.project_payment_schedule for each row execute function public.closed_project_guard();

-- Build the schedule from the contract terms. Lines already invoiced are kept; the rest are rebuilt.
create or replace function public.generate_payment_schedule(p_project uuid) returns int
language plpgsql security definer set search_path = public as $$
declare pr projects; v_start date; v_end date; v_cv numeric; v_adv numeric; v_ret numeric; v_rest numeric; n int := 0; m record; v_months int; d date; i int; v_each numeric;
begin
  select * into pr from projects where id = p_project for update;
  if not found then raise exception 'Project not found'; end if;
  if not (can_manage_project(p_project) or has_role(pr.company_id, array['owner','admin','accountant','sales'])) then raise exception 'Only Finance, Business Development or the project manager can set the payment schedule'; end if;
  if coalesce(pr.contract_value, 0) <= 0 then raise exception 'Enter the contract value first'; end if;
  v_start := coalesce(pr.contract_date, pr.actual_start, pr.start_date, current_date);
  v_end := coalesce(pr.end_date, v_start + 90);
  v_cv := pr.contract_value;
  v_adv := round(v_cv * pr.advance_pct / 100, 2);
  v_ret := round(v_cv * pr.retention_pct / 100, 2);
  delete from project_payment_schedule where project_id = p_project and invoice_id is null;
  -- what is already invoiced counts against the contract
  v_rest := v_cv - v_adv - v_ret - coalesce((select sum(amount) from project_payment_schedule where project_id = p_project and kind not in ('advance','retention')), 0);
  if v_adv > 0 and not exists (select 1 from project_payment_schedule where project_id = p_project and kind = 'advance') then
    insert into project_payment_schedule (project_id, seq, kind, description, amount, invoice_on)
    values (p_project, 1, 'advance', 'Advance payment ' || trim(to_char(pr.advance_pct, 'FM990.##')) || '% on signing', v_adv, v_start);
    n := n + 1;
  end if;
  if pr.billing_basis = 'milestones' then
    for m in select * from project_milestones where project_id = p_project and status <> 'invoiced' and id not in (select milestone_id from project_payment_schedule where milestone_id is not null) order by sort, due_date loop
      insert into project_payment_schedule (project_id, seq, kind, description, amount, invoice_on, milestone_id)
      values (p_project, 10 + n, 'milestone', m.name, m.amount, coalesce(m.due_date, v_end), m.id);
      n := n + 1;
    end loop;
  elsif pr.billing_basis = 'monthly' then
    v_months := greatest(1, (date_part('year', age(v_end, v_start)) * 12 + date_part('month', age(v_end, v_start)))::int + 1);
    v_each := round(greatest(v_rest, 0) / v_months, 2);
    for i in 1..v_months loop
      d := (date_trunc('month', v_start) + make_interval(months => i - 1))::date + coalesce(pr.valuation_day, 25) - 1;
      insert into project_payment_schedule (project_id, seq, kind, description, amount, invoice_on)
      values (p_project, 10 + i, 'valuation', 'Valuation ' || i || ' (' || to_char(d, 'Mon YYYY') || ')',
              case when i = v_months then greatest(v_rest, 0) - v_each * (v_months - 1) else v_each end, d);
      n := n + 1;
    end loop;
  else
    if v_rest > 0 then
      insert into project_payment_schedule (project_id, seq, kind, description, amount, invoice_on)
      values (p_project, 50, 'completion', 'On completion', v_rest, v_end);
      n := n + 1;
    end if;
  end if;
  if v_ret > 0 and not exists (select 1 from project_payment_schedule where project_id = p_project and kind = 'retention') then
    insert into project_payment_schedule (project_id, seq, kind, description, amount, invoice_on)
    values (p_project, 90, 'retention', 'Release of retention ' || trim(to_char(pr.retention_pct, 'FM990.##')) || '% after the defects period', v_ret, v_end + pr.retention_release_days);
    n := n + 1;
  end if;
  return n;
end $$;

-- Raise the invoice for a scheduled payment. Milestones go through the usual milestone billing.
create or replace function public.invoice_schedule_item(p_id uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare s project_payment_schedule; pr projects; v_rate numeric; v_inv uuid;
begin
  select * into s from project_payment_schedule where id = p_id for update;
  if not found then raise exception 'Scheduled payment not found'; end if;
  select * into pr from projects where id = s.project_id;
  if not (has_role(pr.company_id, array['owner','admin','accountant','sales']) or can_manage_project(pr.id)) then raise exception 'Your role cannot invoice this project'; end if;
  if s.invoice_id is not null then raise exception 'Already invoiced'; end if;
  if s.milestone_id is not null then
    v_inv := invoice_milestone(s.milestone_id);
  else
    if pr.customer_id is null then raise exception 'Set a client on this project before invoicing'; end if;
    v_rate := case when pr.currency = 'GHS' then 1 else (select rate from currencies where company_id = pr.company_id and code = pr.currency) end;
    if v_rate is null then raise exception 'Add % under Settings → Foreign currencies first', pr.currency; end if;
    insert into invoices (company_id, customer_id, project_id, invoice_date, currency, exchange_rate, branch_id, cost_centre_id, notes)
    values (pr.company_id, pr.customer_id, pr.id, current_date, pr.currency, v_rate, pr.branch_id, pr.cost_centre_id,
            'Project ' || coalesce(pr.number, '') || ' ' || pr.name || coalesce(' · contract ' || pr.contract_ref, '') ||
            '. Payment terms: ' || coalesce(pr.payment_terms_days, 30) || ' days.') returning id into v_inv;
    insert into invoice_lines (invoice_id, company_id, description, qty, unit_price, taxable, sort)
    values (v_inv, pr.company_id, s.description, 1, s.amount, true, 0);
  end if;
  update project_payment_schedule set invoice_id = v_inv where id = p_id;
  return v_inv;
end $$;

-- Invoicing a milestone from the Billing tab ticks it off the schedule too.
create or replace function public.milestone_to_schedule() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.invoice_id is not null and old.invoice_id is distinct from new.invoice_id then
    update project_payment_schedule set invoice_id = new.invoice_id where milestone_id = new.id and invoice_id is null;
  end if;
  return null;
end $$;
create trigger project_milestones_to_schedule after update on public.project_milestones for each row execute function public.milestone_to_schedule();

-- ---------------------------------------------------------------- 3. Project invoices take their due date from the contract
alter table public.invoices add column if not exists due_from_terms boolean not null default false;
create or replace function public.invoice_due_from_contract() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_days int;
begin
  if new.status <> 'draft' or new.project_id is null then return new; end if;
  select payment_terms_days into v_days from projects where id = new.project_id;
  if v_days is null then return new; end if;
  if tg_op = 'INSERT' then
    if new.due_date is null then new.due_date := new.invoice_date + v_days; new.due_from_terms := true; end if;
  elsif new.due_from_terms and (new.invoice_date is distinct from old.invoice_date or new.project_id is distinct from old.project_id)
        and new.due_date is not distinct from old.due_date then
    new.due_date := new.invoice_date + v_days;
  elsif new.due_date is distinct from old.due_date then
    new.due_from_terms := false;
  elsif new.due_date is null then
    new.due_date := new.invoice_date + v_days; new.due_from_terms := true;
  end if;
  return new;
end $$;
create trigger invoices_due_from_contract before insert or update on public.invoices for each row execute function public.invoice_due_from_contract();

-- ---------------------------------------------------------------- 4. What is coming: invoices to raise and payments to collect
create or replace function public.payment_calendar(cid uuid, p_days int default 30, p_project uuid default null)
returns table (kind text, project_id uuid, project text, customer text, manager_id uuid, ref_id uuid, description text, amount numeric, amount_ghs numeric,
               action_date date, days_left int, status text, invoice_id uuid, invoice_number text)
language sql stable security definer set search_path = public as $$
  with fx as (select p.id, case when p.currency = 'GHS' then 1 else coalesce((select rate from currencies x where x.company_id = p.company_id and x.code = p.currency), 1) end r from projects p where p.company_id = cid)
  -- scheduled payments not yet invoiced: Finance raises the invoice
  select 'to_invoice', p.id, coalesce(p.number || ' ', '') || p.name, c.name, p.manager_id, s.id, s.description, s.amount, round(s.amount * fx.r, 2),
         s.invoice_on, s.invoice_on - current_date,
         case when s.invoice_on < current_date then 'late' when s.invoice_on <= current_date + p.reminder_days then 'due_soon' else 'scheduled' end, null::uuid, null::text
    from project_payment_schedule s join projects p on p.id = s.project_id join fx on fx.id = p.id left join customers c on c.id = p.customer_id
   where p.company_id = cid and s.invoice_id is null and p.status not in ('cancelled') and (p_project is null or p.id = p_project)
     and s.invoice_on <= current_date + p_days and is_member(cid)
  union all
  -- invoices raised and not yet paid: Finance collects, the project manager knows
  select 'to_collect', p.id, coalesce(p.number || ' ', '') || p.name, c.name, p.manager_id, i.id, coalesce(s.description, 'Invoice ' || i.number),
         i.total - i.amount_paid - i.amount_credited, round((i.total - i.amount_paid - i.amount_credited) * i.exchange_rate, 2),
         i.due_date, i.due_date - current_date,
         case when i.due_date < current_date then 'overdue' when i.due_date <= current_date + p.reminder_days then 'due_soon' else 'not_due' end, i.id, i.number
    from invoices i join projects p on p.id = i.project_id left join customers c on c.id = i.customer_id
    left join lateral (select description from project_payment_schedule x where x.invoice_id = i.id limit 1) s on true
   where i.company_id = cid and i.status = 'posted' and i.total - i.amount_paid - i.amount_credited > 0.005 and (p_project is null or p.id = p_project)
     and i.due_date <= current_date + p_days and is_member(cid)
  order by 10;
$$;

-- Schedule with live status for one project.
create or replace function public.project_payment_status(p_project uuid)
returns table (id uuid, seq int, kind text, description text, amount numeric, invoice_on date, due_on date, milestone_id uuid, invoice_id uuid, invoice_number text,
               invoice_due date, billed numeric, paid numeric, outstanding numeric, status text)
language sql stable security definer set search_path = public as $$
  select s.id, s.seq, s.kind, s.description, s.amount, s.invoice_on, coalesce(i.due_date, s.due_on), s.milestone_id, s.invoice_id, i.number, i.due_date,
         i.total, i.amount_paid + i.amount_credited, i.total - i.amount_paid - i.amount_credited,
         case when s.invoice_id is null then case when s.invoice_on < current_date then 'invoice_late' else 'to_invoice' end
              when i.status = 'draft' then 'draft_invoice'
              when i.status = 'paid' or i.total - i.amount_paid - i.amount_credited <= 0.005 then 'paid'
              when i.due_date < current_date then 'overdue' else 'awaiting_payment' end
    from project_payment_schedule s left join invoices i on i.id = s.invoice_id
   where s.project_id = p_project and exists (select 1 from projects p where p.id = p_project and is_member(p.company_id))
   order by s.invoice_on, s.seq;
$$;


-- Reminders come from the system, so they reach the person who happened to trigger them too.
drop function public.notify(uuid, text[], uuid[], text, text, text, text);
create or replace function public.notify(cid uuid, p_roles text[], p_users uuid[], p_kind text, p_title text, p_body text default null, p_path text default null, p_include_self boolean default false)
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  insert into notifications (company_id, user_id, kind, title, body, path)
  select distinct cid, u, p_kind, p_title, p_body, p_path from (
    select m.user_id u from memberships m where m.company_id = cid and (m.role = any(p_roles) or m.role in ('owner','admin'))
    union select unnest(coalesce(p_users, '{}'::uuid[]))) x
  where u is not null and (p_include_self or u is distinct from auth.uid());
  get diagnostics n = row_count;
  return n;
end $$;

-- ---------------------------------------------------------------- 5. Prompts to Finance and the project manager
create table public.payment_reminders (
  company_id uuid not null references public.companies(id) on delete cascade,
  key text not null,
  sent_at timestamptz not null default now(),
  primary key (company_id, key)
);
alter table public.payment_reminders enable row level security;

-- Sends each prompt once: "invoice to raise" when within the contract's reminder days and again when late;
-- "payment due" before the client's due date and again when overdue. Safe to run as often as you like
-- (the app runs it when Finance or a project manager opens the dashboard; it can also run daily, see SETUP).
create or replace function public.run_payment_reminders(cid uuid) returns int
language plpgsql security definer set search_path = public as $$
declare r record; v_key text; n int := 0; v_ins int;
begin
  if auth.uid() is not null and not is_member(cid) then raise exception 'Not a member of this company'; end if;
  for r in select * from payment_calendar(cid, 60) where status in ('due_soon','late','overdue') loop
    v_key := r.kind || ':' || r.ref_id || ':' || case when r.status in ('late','overdue') then 'late' else 'soon' end;
    insert into payment_reminders (company_id, key) values (cid, v_key) on conflict do nothing;
    get diagnostics v_ins = row_count;
    continue when v_ins = 0;
    if r.kind = 'to_invoice' then
      perform notify(cid, array['accountant'], array[r.manager_id], 'payment.invoice_due',
        case when r.status = 'late' then 'Invoice not raised: ' else 'Invoice to raise: ' end || r.description || ' · ' || r.project,
        'GH₵ ' || to_char(r.amount_ghs, 'FM999,999,999,990.00') || case when r.status = 'late' then ' was due to be invoiced on ' else ' to be invoiced on ' end ||
        to_char(r.action_date, 'DD Mon YYYY') || ' under the contract terms.', '/projects/' || r.project_id, true);
    else
      perform notify(cid, array['accountant'], array[r.manager_id], 'payment.client_due',
        case when r.status = 'overdue' then 'Client payment overdue: ' else 'Client payment due: ' end || coalesce(r.invoice_number, '') || ' · ' || r.project,
        coalesce(r.customer, '') || ' owes GH₵ ' || to_char(r.amount_ghs, 'FM999,999,999,990.00') || case when r.status = 'overdue' then ', due on ' else ', due on ' end ||
        to_char(r.action_date, 'DD Mon YYYY') || case when r.status = 'overdue' then ' (' || (current_date - r.action_date) || ' days late). Follow up and log it.' else '.' end,
        '/invoices/' || r.ref_id, true);
    end if;
    n := n + 1;
  end loop;
  return n;
end $$;

-- For a scheduled job (Supabase pg_cron): reminders for every company.
create or replace function public.run_all_payment_reminders() returns int
language plpgsql security definer set search_path = public as $$
declare c record; n int := 0;
begin
  for c in select id from companies loop n := n + run_payment_reminders(c.id); end loop;
  return n;
end $$;

-- ---------------------------------------------------------------- 6. Security and audit
alter table public.project_payment_schedule enable row level security;
create policy "members read schedule" on public.project_payment_schedule for select using (is_member(company_id));
create policy "finance and pm write schedule" on public.project_payment_schedule for all
  using (can_manage_project(project_id) or has_role(company_id, array['owner','admin','accountant','sales']))
  with check (can_manage_project(project_id) or has_role((select company_id from projects where id = project_id), array['owner','admin','accountant','sales']));
create trigger project_payment_schedule_audit after insert or update or delete on public.project_payment_schedule for each row execute function public.audit_row();

-- Terms on a registered project are set by Finance, Business Development or the project manager (not other staff).
create or replace function public.project_terms_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if (new.payment_terms_days, new.advance_pct, new.retention_pct, new.retention_release_days, new.billing_basis, new.valuation_day, new.reminder_days, new.contract_date)
     is distinct from (old.payment_terms_days, old.advance_pct, old.retention_pct, old.retention_release_days, old.billing_basis, old.valuation_day, old.reminder_days, old.contract_date)
     and auth.uid() is not null and not (can_manage_project(new.id) or has_role(new.company_id, array['owner','admin','accountant','sales'])) then
    raise exception 'Only Finance, Business Development or the project manager can change the contract''s payment terms';
  end if;
  return new;
end $$;
create trigger projects_terms_guard before update on public.projects for each row execute function public.project_terms_guard();

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
revoke execute on function public.notify(uuid,text[],uuid[],text,text,text,text,boolean) from authenticated;
revoke execute on function public.run_all_payment_reminders() from authenticated;
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


-- ======================================================================
-- 0011_asnys_v2_5.sql
-- ======================================================================
-- Asnys ERP v2.5: invite staff by email.
-- HR or an admin enters a work email and role (or invites employees in bulk). The invite-member edge function
-- emails a link; the person sets a password and is added to the company with that role, linked to their
-- employee record. Run after 0001 to 0010.

-- ---------------------------------------------------------------- 1. Invitations
create table public.member_invites (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  email text not null,
  role text not null default 'staff' check (role in ('admin','accountant','sales','hr','project_manager','store','staff')),
  employee_id uuid references public.employees(id) on delete set null,
  invited_by uuid default auth.uid(),
  invited_at timestamptz not null default now(),
  last_sent_at timestamptz,
  send_count int not null default 0,
  send_method text,                     -- 'invite' (new account) or 'magic_link' (already has a login)
  status text not null default 'pending' check (status in ('pending','sent','accepted','revoked','failed')),
  error text,
  user_id uuid,
  accepted_at timestamptz,
  unique (company_id, email)
);
create index member_invites_email on public.member_invites (lower(email));

-- Who may invite whom: owners and admins any role but owner; HR only staff.
create or replace function public.can_invite(cid uuid, p_role text) returns boolean
language sql stable security definer set search_path = public as $$
  select has_role(cid, array['owner','admin']) or (p_role = 'staff' and has_role(cid, array['hr']))
$$;

-- p_list: [{"email": "...", "role": "staff", "employee_id": "..."}]. Returns one row per address with what happened.
create or replace function public.create_invites(cid uuid, p_list jsonb)
returns table (id uuid, email text, result text) language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
declare x jsonb; v_email text; v_role text; v_emp uuid; v_user uuid; v_id uuid;
begin
  perform require_member(cid, array['owner','admin','hr']);
  if jsonb_typeof(p_list) is distinct from 'array' or jsonb_array_length(p_list) = 0 then raise exception 'Add at least one email address'; end if;
  if jsonb_array_length(p_list) > 200 then raise exception 'Invite at most 200 people at a time'; end if;
  for x in select * from jsonb_array_elements(p_list) loop
    v_email := lower(trim(coalesce(x->>'email', '')));
    v_role := coalesce(nullif(x->>'role', ''), 'staff');
    v_emp := nullif(x->>'employee_id', '')::uuid;
    if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
      id := null; email := v_email; result := 'invalid email'; return next; continue;
    end if;
    if v_role = 'owner' or v_role not in ('admin','accountant','sales','hr','project_manager','store','staff') then raise exception 'Choose a valid role for %', v_email; end if;
    if not can_invite(cid, v_role) then raise exception 'HR can invite staff only; ask an admin to give % the % role', v_email, v_role; end if;
    if v_emp is not null and not exists (select 1 from employees e where e.id = v_emp and e.company_id = cid) then raise exception 'Employee not found'; end if;
    select m.user_id into v_user from memberships m where m.company_id = cid and lower(m.email) = v_email;
    if v_user is not null then
      if v_emp is not null then update employees set user_id = v_user where employees.id = v_emp and user_id is null; end if;
      id := null; email := v_email; result := 'already a member'; return next; continue;
    end if;
    insert into member_invites as mi (company_id, email, role, employee_id, invited_by)
    values (cid, v_email, v_role, v_emp, auth.uid())
    on conflict (company_id, email) do update set role = excluded.role, employee_id = coalesce(excluded.employee_id, mi.employee_id),
      invited_by = excluded.invited_by, invited_at = now(), status = 'pending', error = null, user_id = null, accepted_at = null
    returning mi.id into v_id;
    id := v_id; email := v_email; result := 'invited'; return next;
  end loop;
end $$;

-- What the edge function needs to send the emails; checks the caller may send each one.
create or replace function public.invites_to_send(cid uuid, p_ids uuid[])
returns table (id uuid, email text, role text, company_name text, has_login boolean)
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
begin
  perform require_member(cid, array['owner','admin','hr']);
  return query
    select i.id, i.email, i.role, c.name, exists (select 1 from auth.users u where lower(u.email) = i.email)
      from member_invites i join companies c on c.id = i.company_id
     where i.company_id = cid and i.id = any(p_ids) and i.status in ('pending','sent','failed') and can_invite(cid, i.role);
end $$;

create or replace function public.mark_invite_sent(p_id uuid, p_ok boolean, p_error text default null, p_method text default null)
returns void language plpgsql security definer set search_path = public as $$
declare i member_invites;
begin
  select * into i from member_invites where id = p_id;
  if not found then raise exception 'Invitation not found'; end if;
  perform require_member(i.company_id, array['owner','admin','hr']);
  if not can_invite(i.company_id, i.role) then raise exception 'You cannot send this invitation'; end if;
  if i.status in ('accepted','revoked') then return; end if;
  update member_invites set status = case when p_ok then 'sent' else 'failed' end, error = case when p_ok then null else left(p_error, 500) end,
         last_sent_at = case when p_ok then now() else last_sent_at end, send_count = send_count + case when p_ok then 1 else 0 end,
         send_method = coalesce(p_method, send_method)
   where id = p_id;
end $$;

create or replace function public.revoke_invite(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare i member_invites;
begin
  select * into i from member_invites where id = p_id;
  if not found then raise exception 'Invitation not found'; end if;
  perform require_member(i.company_id, array['owner','admin','hr']);
  if not can_invite(i.company_id, i.role) then raise exception 'You cannot revoke this invitation'; end if;
  if i.status = 'accepted' then raise exception 'Already accepted; remove them from the team instead'; end if;
  update member_invites set status = 'revoked' where id = p_id;
end $$;

-- Called by the app after every sign-in. Only a confirmed email address can claim an invitation, so nobody
-- can sign up with a colleague's address and take their place.
create or replace function public.claim_my_invites()
returns int language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_email text; v_confirmed timestamptz; r member_invites; n int := 0; v_emp uuid;
begin
  if v_uid is null then return 0; end if;
  select lower(u.email), u.email_confirmed_at into v_email, v_confirmed from auth.users u where u.id = v_uid;
  if v_email is null or v_confirmed is null then return 0; end if;
  for r in select * from member_invites where lower(email) = v_email and status in ('pending','sent','failed') loop
    insert into memberships (company_id, user_id, email, role) values (r.company_id, v_uid, v_email, r.role)
    on conflict (company_id, user_id) do nothing;            -- never changes the role of someone already in
    v_emp := r.employee_id;
    if v_emp is null then
      select e.id into v_emp from employees e where e.company_id = r.company_id and e.user_id is null and lower(e.email) = v_email limit 1;
    end if;
    if v_emp is not null then update employees set user_id = v_uid where id = v_emp and company_id = r.company_id and user_id is null; end if;
    update member_invites set status = 'accepted', accepted_at = now(), user_id = v_uid where id = r.id;
    perform notify(r.company_id, array[]::text[], array[r.invited_by], 'invite_accepted', v_email || ' joined as ' || replace(r.role, '_', ' '), null, '/settings', true);
    n := n + 1;
  end loop;
  return n;
end $$;

-- Team list with sign-in status, plus open invitations.
create or replace function public.team_access(cid uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform require_member(cid, array['owner','admin','hr']);
  return jsonb_build_object(
    'members', coalesce((select jsonb_agg(jsonb_build_object('user_id', m.user_id, 'email', coalesce(m.email, u.email), 'role', m.role,
                 'last_sign_in_at', u.last_sign_in_at, 'joined_at', m.created_at,
                 'employee', (select e.full_name from employees e where e.company_id = cid and e.user_id = m.user_id limit 1))
               order by m.role = 'owner' desc, coalesce(m.email, u.email))
               from memberships m left join auth.users u on u.id = m.user_id where m.company_id = cid), '[]'),
    'invites', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'email', i.email, 'role', i.role, 'status', i.status, 'error', i.error,
                 'invited_at', i.invited_at, 'last_sent_at', i.last_sent_at, 'send_count', i.send_count, 'employee_id', i.employee_id,
                 'employee', (select e.full_name from employees e where e.id = i.employee_id),
                 'invited_by', (select m.email from memberships m where m.company_id = cid and m.user_id = i.invited_by))
               order by i.invited_at desc)
               from member_invites i where i.company_id = cid and i.status <> 'accepted'), '[]'));
end $$;

-- Employee list status: Not invited / Invited / Has access.
create or replace function public.employee_access(cid uuid)
returns table (employee_id uuid, access text, email text)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  perform require_member(cid, array['owner','admin','hr']);
  return query
    select e.id,
      case when e.user_id is not null and exists (select 1 from memberships m where m.company_id = cid and m.user_id = e.user_id) then 'active'
           when i.status in ('pending','sent') then 'invited'
           when i.status = 'failed' then 'failed'
           else 'none' end,
      coalesce(i.email, lower(e.email))
    from employees e
    left join lateral (select * from member_invites mi where mi.company_id = cid and mi.status <> 'revoked'
                         and (mi.employee_id = e.id or (e.email is not null and mi.email = lower(trim(e.email))))
                       order by mi.invited_at desc limit 1) i on true
   where e.company_id = cid;
end $$;

-- The old link message pointed at a sign-up step that invitations now replace.
create or replace function public.link_employee_user(p_employee uuid, p_email text)
returns void language plpgsql security definer set search_path = public as $$
declare e employees; v_user uuid;
begin
  select * into e from employees where id = p_employee;
  if not found then raise exception 'Employee not found'; end if;
  perform require_member(e.company_id, array['owner','admin','hr']);
  if coalesce(trim(p_email),'') = '' then update employees set user_id = null where id = p_employee; return; end if;
  select id into v_user from auth.users where lower(email) = lower(trim(p_email));
  if v_user is null then raise exception 'No one has signed in with % yet. Press "Invite to Asnys" to email them an invitation.', p_email; end if;
  update employees set user_id = v_user where id = p_employee;
end $$;

alter table public.member_invites enable row level security;
create policy "admins and hr read invites" on public.member_invites for select using (has_role(company_id, array['owner','admin','hr']));
create trigger member_invites_audit after insert or update or delete on public.member_invites for each row execute function public.audit_row();

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
revoke execute on function public.notify(uuid,text[],uuid[],text,text,text,text,boolean) from authenticated;
revoke execute on function public.run_all_payment_reminders() from authenticated;
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


-- ======================================================================
-- 0012_asnys_v2_6.sql
-- ======================================================================
-- Asnys ERP v2.6: contract management, and asset check-out, audits, requests and reminders. Run after 0001 to 0011.
-- A register of every contract the company signs (with clients, suppliers, subcontractors, service and leases),
-- its variations, the bonds and guarantees behind it, key dates and obligations, and the signed files.

-- ---------------------------------------------------------------- 1. Contracts
create table public.contracts (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  number text,
  title text not null,
  kind text not null default 'client' check (kind in ('client','supplier','subcontract','service','lease','other')),
  customer_id uuid references public.customers(id) on delete set null,
  supplier_id uuid references public.suppliers(id) on delete set null,
  counterparty text,                                  -- name when not a customer or supplier record
  their_ref text,                                     -- the other party's contract, PO or LPO number
  project_id uuid references public.projects(id) on delete set null,
  tender_id uuid references public.tenders(id) on delete set null,
  value numeric(14,2) not null default 0 check (value >= 0),
  currency text not null default 'GHS',
  signed_on date,
  start_date date,
  end_date date,
  status text not null default 'draft' check (status in ('draft','active','on_hold','terminated','closed')),
  payment_terms_days int check (payment_terms_days between 0 and 365),
  advance_pct numeric(5,2) check (advance_pct between 0 and 100),
  retention_pct numeric(5,2) check (retention_pct between 0 and 100),
  notice_days int not null default 30 check (notice_days between 0 and 365),   -- remind this long before the end date
  auto_renew boolean not null default false,
  renewal_months int check (renewal_months between 1 and 120),
  owner_id uuid default auth.uid(),                   -- who manages the contract
  description text,
  termination_note text,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  check (end_date is null or start_date is null or end_date >= start_date)
);
create index contracts_company on public.contracts (company_id, status);
create unique index contracts_tender on public.contracts (tender_id) where tender_id is not null;

create table public.contract_variations (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  contract_id uuid not null references public.contracts(id) on delete cascade,
  number text,
  title text not null,
  description text,
  value_change numeric(14,2) not null default 0,      -- + adds to the contract, - omits work
  days_extension int not null default 0 check (days_extension >= 0),
  status text not null default 'proposed' check (status in ('proposed','approved','rejected')),
  requested_on date not null default current_date,
  decided_on date,
  decided_by uuid,
  decision_note text,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);

create table public.contract_securities (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  contract_id uuid not null references public.contracts(id) on delete cascade,
  kind text not null check (kind in ('bid_bond','performance_bond','advance_payment_guarantee','retention_bond','insurance','warranty','other')),
  direction text not null default 'given' check (direction in ('given','received')),   -- given by us, or received from the other party
  issuer text,                                        -- bank or insurer
  reference text,
  amount numeric(14,2) check (amount >= 0),
  issued_on date,
  expires_on date,
  status text not null default 'active' check (status in ('active','released','claimed','expired')),
  notes text,
  created_at timestamptz not null default now()
);

create table public.contract_obligations (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  contract_id uuid not null references public.contracts(id) on delete cascade,
  title text not null,                                -- e.g. Submit monthly HSE report, Renew insurance, Final account
  due_date date not null,
  responsible_id uuid,                                -- a user
  status text not null default 'open' check (status in ('open','done','waived')),
  done_on date,
  notes text,
  created_at timestamptz not null default now()
);

create table public.contract_files (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  contract_id uuid not null references public.contracts(id) on delete cascade,
  kind text not null default 'signed_contract' check (kind in ('signed_contract','variation','security','correspondence','other')),
  name text not null,
  storage_path text not null,                         -- project-docs bucket, <company>/contracts/<contract>/...
  size_bytes bigint,
  uploaded_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);

-- Who works with contracts: owners, admins, Finance, Business Development and project managers; anyone named as its owner.
create or replace function public.can_see_contract(c contracts) returns boolean
language sql stable security definer set search_path = public as $$
  select has_role(c.company_id, array['owner','admin','accountant','sales','project_manager']) or c.owner_id = auth.uid()
$$;
create or replace function public.can_edit_contract(c contracts) returns boolean
language sql stable security definer set search_path = public as $$
  select has_role(c.company_id, array['owner','admin','accountant','sales'])
      or c.owner_id = auth.uid()
      or (c.project_id is not null and can_manage_project(c.project_id))
$$;

create or replace function public.contract_defaults() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.number is null or new.number = '' then new.number := next_number(new.company_id, 'CON', 'CON-'); end if;
  if new.counterparty is null then
    new.counterparty := coalesce((select name from customers where id = new.customer_id), (select name from suppliers where id = new.supplier_id));
  end if;
  if new.project_id is not null and not exists (select 1 from projects where id = new.project_id and company_id = new.company_id) then raise exception 'Project not found'; end if;
  if tg_op = 'UPDATE' and new.status in ('terminated','closed') and old.status not in ('terminated','closed') and new.termination_note is null and new.status = 'terminated' then
    raise exception 'Say why the contract was terminated';
  end if;
  return new;
end $$;
create trigger contracts_defaults before insert or update on public.contracts for each row execute function public.contract_defaults();

create or replace function public.child_company() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  select company_id into new.company_id from contracts where id = new.contract_id;
  if new.company_id is null then raise exception 'Contract not found'; end if;
  return new;
end $$;
create trigger contract_variations_company before insert on public.contract_variations for each row execute function public.child_company();
create trigger contract_securities_company before insert on public.contract_securities for each row execute function public.child_company();
create trigger contract_obligations_company before insert on public.contract_obligations for each row execute function public.child_company();
create trigger contract_files_company before insert on public.contract_files for each row execute function public.child_company();

create or replace function public.variation_defaults() returns trigger
language plpgsql security definer set search_path = public as $$
declare c contracts;
begin
  select * into c from contracts where id = new.contract_id;
  if tg_op = 'INSERT' then
    new.number := 'VO-' || lpad((select count(*) + 1 from contract_variations where contract_id = new.contract_id)::text, 2, '0');
    new.status := 'proposed'; new.decided_on := null; new.decided_by := null;
    perform notify(c.company_id, array['accountant'], array[c.owner_id], 'variation_proposed',
      'Variation ' || new.number || ' proposed on ' || c.number, new.title || ' (' || to_char(new.value_change, 'FM999,999,999,990.00') || ')', '/contracts/' || c.id);
  elsif (new.status, new.value_change, new.days_extension) is distinct from (old.status, old.value_change, old.days_extension)
        and coalesce(current_setting('sika.contracts', true), '') <> 'on' then
    if old.status <> 'proposed' then raise exception 'This variation has been decided; propose a new one instead'; end if;
    if new.status <> old.status then raise exception 'Use Approve or Reject'; end if;
  end if;
  return new;
end $$;
create trigger contract_variations_defaults before insert or update on public.contract_variations for each row execute function public.variation_defaults();

-- Finance, owners and admins decide variations. An approved time extension moves the contract's end date.
create or replace function public.decide_variation(p_id uuid, p_approve boolean, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v contract_variations; c contracts;
begin
  select * into v from contract_variations where id = p_id;
  if not found then raise exception 'Variation not found'; end if;
  select * into c from contracts where id = v.contract_id;
  perform require_member(c.company_id, array['owner','admin','accountant']);
  if v.status <> 'proposed' then raise exception 'Already %', v.status; end if;
  perform set_config('sika.contracts', 'on', true);
  update contract_variations set status = case when p_approve then 'approved' else 'rejected' end, decided_on = current_date, decided_by = auth.uid(), decision_note = p_note where id = p_id;
  if p_approve and v.days_extension > 0 and c.end_date is not null then
    update contracts set end_date = end_date + v.days_extension where id = c.id;
  end if;
  perform set_config('sika.contracts', 'off', true);
  perform notify(c.company_id, array[]::text[], array[c.owner_id, v.created_by], 'variation_decided',
    v.number || ' on ' || c.number || ' ' || case when p_approve then 'approved' else 'rejected' end, p_note, '/contracts/' || c.id, true);
end $$;

-- ---------------------------------------------------------------- 2. Awarded tenders become client contracts
create or replace function public.contract_from_tender(p_tender uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare t tenders; v uuid; pj uuid;
begin
  select * into t from tenders where id = p_tender;
  if not found then raise exception 'Tender not found'; end if;
  if t.status <> 'awarded' then raise exception 'Only an awarded tender becomes a contract'; end if;
  select id into v from contracts where tender_id = p_tender;
  if v is not null then return v; end if;
  pj := coalesce(t.project_id, (select id from projects where tender_id = t.id limit 1));
  insert into contracts (company_id, title, kind, customer_id, counterparty, their_ref, project_id, tender_id, value, currency, signed_on, start_date, status,
                         payment_terms_days, advance_pct, retention_pct, owner_id, description)
  values (t.company_id, t.title, 'client', t.customer_id, t.client_name, t.contract_ref, pj, t.id, coalesce(t.awarded_value, 0), t.currency, t.contract_signed_on,
          coalesce((select start_date from projects where id = pj), t.contract_signed_on), 'active',
          (to_jsonb(t)->>'payment_terms_days')::int, (to_jsonb(t)->>'advance_pct')::numeric, (to_jsonb(t)->>'retention_pct')::numeric,
          coalesce(t.bd_owner_id, auth.uid()), 'Awarded on ' || t.number || coalesce(' (' || replace(t.award_type, '_', ' ') || ')', ''))
  returning id into v;
  return v;
end $$;

create or replace function public.tender_award_contract() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'awarded' and old.status is distinct from 'awarded' then perform contract_from_tender(new.id); end if;
  if new.project_id is not null and new.project_id is distinct from old.project_id then
    update contracts set project_id = new.project_id where tender_id = new.id and project_id is null;
  end if;
  return new;
end $$;
create trigger tenders_award_contract after update on public.tenders for each row execute function public.tender_award_contract();

-- Projects created from a tender pick up the contract.
create or replace function public.project_links_contract() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.tender_id is not null then update contracts set project_id = new.id where tender_id = new.tender_id and project_id is null; end if;
  return new;
end $$;
create trigger projects_link_contract after insert on public.projects for each row execute function public.project_links_contract();

-- Awards made before this release.
insert into contracts (company_id, title, kind, customer_id, counterparty, their_ref, project_id, tender_id, value, currency, signed_on, start_date, status, owner_id, created_by, description)
select t.company_id, t.title, 'client', t.customer_id, t.client_name, t.contract_ref, coalesce(t.project_id, (select id from projects p where p.tender_id = t.id limit 1)), t.id,
       coalesce(t.awarded_value, 0), t.currency, t.contract_signed_on, t.contract_signed_on, 'active', t.bd_owner_id, t.bd_owner_id, 'Awarded on ' || t.number
  from tenders t where t.status = 'awarded' and not exists (select 1 from contracts c where c.tender_id = t.id);

-- ---------------------------------------------------------------- 3. Register with live figures
create or replace function public.contract_register(cid uuid)
returns table (id uuid, number text, title text, kind text, counterparty text, their_ref text, project_id uuid, project text, status text, display_status text,
               currency text, value numeric, variations numeric, revised_value numeric, pending_variations int, billed numeric, paid numeric, remaining numeric,
               signed_on date, start_date date, end_date date, days_left int, owner_id uuid, owner_email text,
               securities_active int, securities_expiring int, obligations_open int, obligations_overdue int, auto_renew boolean)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  perform require_member(cid, array['owner','admin','accountant','sales','project_manager','hr','store','staff']);
  return query
  with v as (select contract_id, sum(value_change) filter (where status = 'approved') appr, count(*) filter (where status = 'proposed') pend
               from contract_variations where company_id = cid group by contract_id),
       inv as (select c.id cid2, sum(i.total) billed, sum(i.amount_paid) paid
                 from contracts c join invoices i on i.company_id = c.company_id and i.status <> 'draft'
                  and ((c.project_id is not null and i.project_id = c.project_id) or (c.project_id is null and c.customer_id is not null and i.customer_id = c.customer_id
                        and i.invoice_date >= coalesce(c.start_date, c.signed_on, '1900-01-01')))
                where c.company_id = cid and c.kind = 'client' group by c.id),
       bil as (select c.id cid2, sum(b.total) billed, sum(b.amount_paid) paid
                 from contracts c join bills b on b.company_id = c.company_id and b.status <> 'draft' and b.supplier_id = c.supplier_id
                  and (c.project_id is null or exists (select 1 from bill_lines l where l.bill_id = b.id and l.project_id = c.project_id))
                  and b.bill_date >= coalesce(c.start_date, c.signed_on, '1900-01-01')
                where c.company_id = cid and c.kind <> 'client' and c.supplier_id is not null group by c.id),
       s as (select contract_id, count(*) filter (where status = 'active') act,
                    count(*) filter (where status = 'active' and expires_on <= current_date + 30) soon
               from contract_securities where company_id = cid group by contract_id),
       o as (select contract_id, count(*) filter (where status = 'open') op, count(*) filter (where status = 'open' and due_date < current_date) late
               from contract_obligations where company_id = cid group by contract_id)
  select c.id, c.number, c.title, c.kind, c.counterparty, c.their_ref, c.project_id, coalesce(p.number || ' ', '') || p.name, c.status,
         case when c.status = 'active' and c.end_date < current_date then 'expired'
              when c.status = 'active' and c.end_date <= current_date + c.notice_days then 'ending_soon' else c.status end,
         c.currency, c.value, coalesce(v.appr, 0), c.value + coalesce(v.appr, 0), coalesce(v.pend, 0)::int,
         coalesce(inv.billed, bil.billed, 0), coalesce(inv.paid, bil.paid, 0), c.value + coalesce(v.appr, 0) - coalesce(inv.billed, bil.billed, 0),
         c.signed_on, c.start_date, c.end_date, (c.end_date - current_date)::int, c.owner_id,
         (select m.email from memberships m where m.company_id = cid and m.user_id = c.owner_id),
         coalesce(s.act, 0)::int, coalesce(s.soon, 0)::int, coalesce(o.op, 0)::int, coalesce(o.late, 0)::int, c.auto_renew
    from contracts c
    left join projects p on p.id = c.project_id
    left join v on v.contract_id = c.id left join inv on inv.cid2 = c.id left join bil on bil.cid2 = c.id
    left join s on s.contract_id = c.id left join o on o.contract_id = c.id
   where c.company_id = cid and can_see_contract(c)
   order by (c.status = 'active') desc, c.end_date nulls last, c.number;
end $$;

-- Everything needing attention, newest risk first.
create or replace function public.contract_alerts(cid uuid, p_days int default 30)
returns table (kind text, contract_id uuid, contract text, title text, due date, days_left int)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  perform require_member(cid, array['owner','admin','accountant','sales','project_manager','hr','store','staff']);
  return query
  select * from (
    select 'contract_end'::text, c.id, c.number, c.title || ' ends' || case when c.auto_renew then ' (renews automatically)' else '' end, c.end_date, (c.end_date - current_date)::int
      from contracts c where c.company_id = cid and c.status = 'active' and c.end_date is not null and c.end_date <= current_date + greatest(c.notice_days, p_days) and can_see_contract(c)
    union all
    select 'security_expiry', c.id, c.number, initcap(replace(s.kind, '_', ' ')) || coalesce(' ' || s.reference, '') || coalesce(' from ' || s.issuer, '') || ' expires', s.expires_on, (s.expires_on - current_date)::int
      from contract_securities s join contracts c on c.id = s.contract_id
     where s.company_id = cid and s.status = 'active' and s.expires_on is not null and s.expires_on <= current_date + p_days and can_see_contract(c)
    union all
    select 'obligation', c.id, c.number, o.title, o.due_date, (o.due_date - current_date)::int
      from contract_obligations o join contracts c on c.id = o.contract_id
     where o.company_id = cid and o.status = 'open' and o.due_date <= current_date + least(p_days, 14) and can_see_contract(c)
    union all
    select 'variation', c.id, c.number, v.number || ' awaiting decision: ' || v.title, v.requested_on, (v.requested_on - current_date)::int
      from contract_variations v join contracts c on c.id = v.contract_id
     where v.company_id = cid and v.status = 'proposed' and can_see_contract(c)
  ) x order by 6, 5;
end $$;

-- ---------------------------------------------------------------- 4. Reminders (contracts and assets), sent once each
create or replace function public.run_contract_reminders_internal(cid uuid) returns int
language plpgsql security definer set search_path = public as $$
declare r record; n int := 0; k text;
begin
  for r in select c.*, (c.end_date - current_date) dl from contracts c
            where c.company_id = cid and c.status = 'active' and c.end_date is not null and c.end_date <= current_date + c.notice_days loop
    k := 'con-end:' || r.id || ':' || r.end_date || ':' || case when r.dl < 0 then 'late' else 'soon' end;
    if not exists (select 1 from payment_reminders where company_id = cid and key = k) then
      insert into payment_reminders (company_id, key) values (cid, k);
      perform notify(cid, array['accountant'], array[r.owner_id], 'contract_ending',
        r.number || ' ' || r.title || case when r.dl < 0 then ' ended on ' else ' ends on ' end || to_char(r.end_date, 'DD Mon YYYY'),
        case when r.auto_renew then 'It renews automatically unless notice is given.' else 'Renew, extend or close it.' end, '/contracts/' || r.id, true);
      n := n + 1;
    end if;
  end loop;
  for r in select s.*, c.number cn, c.owner_id from contract_securities s join contracts c on c.id = s.contract_id
            where s.company_id = cid and s.status = 'active' and s.expires_on is not null and s.expires_on <= current_date + 30 loop
    k := 'con-sec:' || r.id || ':' || r.expires_on || ':' || case when r.expires_on < current_date then 'late' else 'soon' end;
    if not exists (select 1 from payment_reminders where company_id = cid and key = k) then
      insert into payment_reminders (company_id, key) values (cid, k);
      perform notify(cid, array['accountant'], array[r.owner_id], 'security_expiring',
        initcap(replace(r.kind, '_', ' ')) || ' on ' || r.cn || case when r.expires_on < current_date then ' expired on ' else ' expires on ' end || to_char(r.expires_on, 'DD Mon YYYY'),
        coalesce(r.issuer || ' ', '') || coalesce(r.reference, ''), '/contracts/' || r.contract_id, true);
      n := n + 1;
    end if;
  end loop;
  for r in select o.*, c.number cn, c.owner_id from contract_obligations o join contracts c on c.id = o.contract_id
            where o.company_id = cid and o.status = 'open' and o.due_date <= current_date + 7 loop
    k := 'con-obl:' || r.id || ':' || r.due_date || ':' || case when r.due_date < current_date then 'late' else 'soon' end;
    if not exists (select 1 from payment_reminders where company_id = cid and key = k) then
      insert into payment_reminders (company_id, key) values (cid, k);
      perform notify(cid, array[]::text[], array[r.owner_id, r.responsible_id], 'obligation_due',
        r.title || ' (' || r.cn || ')' || case when r.due_date < current_date then ' was due ' else ' is due ' end || to_char(r.due_date, 'DD Mon YYYY'), null, '/contracts/' || r.contract_id, true);
      n := n + 1;
    end if;
  end loop;
  -- Assets: maintenance coming due and warranties ending
  for r in select a.id, a.tag, a.name, a.custodian_id, m.next_due from assets a
             join lateral (select next_due from asset_maintenance x where x.asset_id = a.id order by service_date desc limit 1) m on true
            where a.company_id = cid and a.status = 'active' and m.next_due is not null and m.next_due <= current_date + 7 loop
    k := 'ast-mnt:' || r.id || ':' || r.next_due;
    if not exists (select 1 from payment_reminders where company_id = cid and key = k) then
      insert into payment_reminders (company_id, key) values (cid, k);
      perform notify(cid, array['accountant'], array[(select user_id from employees where id = r.custodian_id)], 'maintenance_due',
        'Maintenance due on ' || r.tag || ' ' || r.name || ': ' || to_char(r.next_due, 'DD Mon YYYY'), null, '/assets/' || r.id, true);
      n := n + 1;
    end if;
  end loop;
  for r in select a.* from assets a where a.company_id = cid and a.status = 'active' and a.warranty_until between current_date and current_date + 30 loop
    k := 'ast-war:' || r.id || ':' || r.warranty_until;
    if not exists (select 1 from payment_reminders where company_id = cid and key = k) then
      insert into payment_reminders (company_id, key) values (cid, k);
      perform notify(cid, array['accountant','store'], null, 'warranty_ending', 'Warranty on ' || r.tag || ' ' || r.name || ' ends ' || to_char(r.warranty_until, 'DD Mon YYYY'), null, '/assets/' || r.id, true);
      n := n + 1;
    end if;
  end loop;
  for r in select a.* from assets a where a.company_id = cid and a.status = 'active' and a.state <> 'archived' and a.next_audit is not null and a.next_audit <= current_date + 7 loop
    k := 'ast-aud:' || r.id || ':' || r.next_audit;
    if not exists (select 1 from payment_reminders where company_id = cid and key = k) then
      insert into payment_reminders (company_id, key) values (cid, k);
      perform notify(cid, array['store'], null, 'audit_due', 'Audit due on ' || r.tag || ' ' || r.name || ': ' || to_char(r.next_audit, 'DD Mon YYYY'), coalesce('At ' || r.location, null), '/assets/' || r.id, true);
      n := n + 1;
    end if;
  end loop;
  for r in select a.*, (select user_id from employees where id = a.custodian_id) uid from assets a
            where a.company_id = cid and a.state = 'deployed' and a.expected_return is not null and a.expected_return < current_date loop
    k := 'ast-ret:' || r.id || ':' || r.expected_return;
    if not exists (select 1 from payment_reminders where company_id = cid and key = k) then
      insert into payment_reminders (company_id, key) values (cid, k);
      perform notify(cid, array['store'], array[r.uid], 'asset_overdue', r.tag || ' ' || r.name || ' was due back on ' || to_char(r.expected_return, 'DD Mon YYYY'), null, '/assets/' || r.id, true);
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;

create or replace function public.run_contract_reminders(cid uuid) returns int
language plpgsql security definer set search_path = public as $$
begin
  perform require_member(cid, array['owner','admin','accountant','sales','project_manager','hr','store','staff']);
  return run_contract_reminders_internal(cid);
end $$;

create or replace function public.run_all_contract_reminders() returns int
language plpgsql security definer set search_path = public as $$
declare c record; n int := 0;
begin
  for c in select id from companies loop
    begin n := n + coalesce(run_contract_reminders_internal(c.id), 0);
    exception when others then null; end;
  end loop;
  return n;
end $$;

-- ---------------------------------------------------------------- 5. Asset maintenance schedule
create or replace function public.asset_maintenance_schedule(cid uuid)
returns table (asset_id uuid, tag text, name text, location text, custodian text, last_service date, last_description text, next_due date, days_left int, total_cost numeric, services int)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  perform require_member(cid, array['owner','admin','accountant','sales','project_manager','hr','store','staff']);
  return query
  select a.id, a.tag, a.name, a.location, e.full_name, l.service_date, l.description, l.next_due, (l.next_due - current_date)::int,
         coalesce((select sum(cost) from asset_maintenance m where m.asset_id = a.id), 0), (select count(*) from asset_maintenance m where m.asset_id = a.id)::int
    from assets a
    left join employees e on e.id = a.custodian_id
    left join lateral (select * from asset_maintenance x where x.asset_id = a.id order by service_date desc limit 1) l on true
   where a.company_id = cid and a.status = 'active'
   order by l.next_due nulls last, a.tag;
end $$;


-- ---------------------------------------------------------------- 7. Asset operations: status, check out and in, audits, requests
alter table public.assets add column if not exists state text not null default 'ready'
  check (state in ('ready','deployed','pending','repair','broken','lost','archived'));
alter table public.assets add column if not exists requestable boolean not null default false;
alter table public.assets add column if not exists holder_project uuid references public.projects(id) on delete set null;
alter table public.assets add column if not exists expected_return date;
alter table public.assets add column if not exists last_audit date;
alter table public.assets add column if not exists next_audit date;
alter table public.companies add column if not exists asset_audit_months int not null default 12 check (asset_audit_months between 1 and 60);
update public.assets set state = case when status <> 'active' then 'archived' when custodian_id is not null then 'deployed' else 'ready' end;
update public.assets set next_audit = current_date + 90 where status = 'active' and next_audit is null;

alter table public.asset_movements add column if not exists kind text not null default 'move' check (kind in ('move','checkout','checkin','audit','status'));
alter table public.asset_movements add column if not exists project_id uuid references public.projects(id) on delete set null;
alter table public.asset_movements add column if not exists expected_return date;
alter table public.asset_movements add column if not exists state_after text;
alter table public.asset_movements add column if not exists moved_by uuid default auth.uid();

create table public.asset_audits (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  asset_id uuid not null references public.assets(id) on delete cascade,
  audited_on date not null default current_date,
  audited_by uuid default auth.uid(),
  location text,
  condition text not null default 'good' check (condition in ('good','fair','poor','broken','missing')),
  note text,
  next_audit date
);

create table public.asset_requests (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  number text,
  asset_id uuid references public.assets(id) on delete set null,         -- a specific requestable asset, or
  category_id uuid references public.asset_categories(id) on delete set null,  -- any asset of a kind
  description text not null,
  requested_by uuid not null default auth.uid(),
  employee_id uuid references public.employees(id) on delete set null,
  project_id uuid references public.projects(id) on delete set null,
  needed_from date not null default current_date,
  needed_until date,
  status text not null default 'pending' check (status in ('pending','approved','fulfilled','rejected','cancelled')),
  decided_by uuid, decided_on date, decision_note text,
  fulfilled_asset_id uuid references public.assets(id) on delete set null,
  created_at timestamptz not null default now()
);

create or replace function public.asset_manager(cid uuid) returns boolean
language sql stable security definer set search_path = public as $$ select has_role(cid, array['owner','admin','accountant','store']) $$;

create or replace function public.asset_defaults() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.next_audit is null and new.status = 'active' then
    new.next_audit := current_date + make_interval(months => coalesce((select asset_audit_months from companies where id = new.company_id), 12));
  end if;
  if new.custodian_id is not null and new.state = 'ready' and tg_op = 'INSERT' then new.state := 'deployed'; end if;
  if new.status <> 'active' then new.state := 'archived'; end if;
  return new;
end $$;
create trigger assets_defaults before insert or update of status on public.assets for each row execute function public.asset_defaults();

-- Hand an asset to a person, a project site or a location.
create or replace function public.checkout_asset(p_asset uuid, p_employee uuid default null, p_project uuid default null, p_location text default null,
  p_expected_return date default null, p_note text default null, p_request uuid default null)
returns void language plpgsql security definer set search_path = public as $$
declare a assets;
begin
  select * into a from assets where id = p_asset for update;
  if not found then raise exception 'Asset not found'; end if;
  if not asset_manager(a.company_id) then raise exception 'Only the storekeeper, Finance or an admin can check assets out'; end if;
  if a.status <> 'active' or a.state in ('broken','lost','archived','repair') then raise exception '% is % and cannot be checked out', a.tag, replace(a.state, 'repair', 'out for repair'); end if;
  if a.state = 'deployed' then raise exception '% is already checked out; check it in first', a.tag; end if;
  if p_employee is null and p_project is null and coalesce(trim(p_location), '') = '' then raise exception 'Choose a person, a project or a location'; end if;
  if p_employee is not null and not exists (select 1 from employees where id = p_employee and company_id = a.company_id) then raise exception 'Employee not found'; end if;
  if p_project is not null and not exists (select 1 from projects where id = p_project and company_id = a.company_id) then raise exception 'Project not found'; end if;
  insert into asset_movements (company_id, asset_id, kind, from_location, to_location, from_custodian, to_custodian, project_id, expected_return, state_after, note)
  values (a.company_id, a.id, 'checkout', a.location, coalesce(nullif(trim(p_location), ''), (select coalesce(location, name) from projects where id = p_project), a.location),
          a.custodian_id, p_employee, p_project, p_expected_return, 'deployed', p_note);
  update assets set state = 'deployed', custodian_id = p_employee, holder_project = p_project, expected_return = p_expected_return,
         location = coalesce(nullif(trim(p_location), ''), (select coalesce(location, name) from projects where id = p_project), location)
   where id = a.id;
  if p_request is not null then update asset_requests set status = 'fulfilled', fulfilled_asset_id = a.id where id = p_request and company_id = a.company_id; end if;
  perform notify(a.company_id, array[]::text[], array[(select user_id from employees where id = p_employee),
          (select requested_by from asset_requests where id = p_request)], 'asset_checked_out',
    a.tag || ' ' || a.name || ' checked out to you' , case when p_expected_return is not null then 'Please return it by ' || to_char(p_expected_return, 'DD Mon YYYY') end, '/assets/' || a.id);
end $$;

create or replace function public.checkin_asset(p_asset uuid, p_state text default 'ready', p_location text default null, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare a assets;
begin
  select * into a from assets where id = p_asset for update;
  if not found then raise exception 'Asset not found'; end if;
  if not asset_manager(a.company_id) then raise exception 'Only the storekeeper, Finance or an admin can check assets in'; end if;
  if a.state <> 'deployed' then raise exception '% is not checked out', a.tag; end if;
  if p_state not in ('ready','pending','repair','broken','lost') then raise exception 'Choose the condition it came back in'; end if;
  insert into asset_movements (company_id, asset_id, kind, from_location, to_location, from_custodian, to_custodian, project_id, state_after, note)
  values (a.company_id, a.id, 'checkin', a.location, coalesce(nullif(trim(p_location), ''), a.location), a.custodian_id, null, a.holder_project, p_state, p_note);
  update assets set state = p_state, custodian_id = null, holder_project = null, expected_return = null, location = coalesce(nullif(trim(p_location), ''), location) where id = a.id;
end $$;

create or replace function public.set_asset_state(p_asset uuid, p_state text, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare a assets;
begin
  select * into a from assets where id = p_asset for update;
  if not found then raise exception 'Asset not found'; end if;
  if not asset_manager(a.company_id) then raise exception 'Only the storekeeper, Finance or an admin can change an asset''s status'; end if;
  if p_state not in ('ready','pending','repair','broken','lost','archived') then raise exception 'Choose a status'; end if;
  if a.state = 'deployed' and p_state not in ('lost') then raise exception 'Check % in first', a.tag; end if;
  if a.status <> 'active' and p_state <> 'archived' then raise exception '% has been disposed of', a.tag; end if;
  insert into asset_movements (company_id, asset_id, kind, from_location, to_location, from_custodian, to_custodian, state_after, note)
  values (a.company_id, a.id, 'status', a.location, a.location, a.custodian_id, case when p_state = 'lost' then null else a.custodian_id end, p_state, p_note);
  update assets set state = p_state, custodian_id = case when p_state = 'lost' then null else custodian_id end,
         holder_project = case when p_state = 'lost' then null else holder_project end where id = a.id;
end $$;

-- Confirm an asset is where it should be and in what condition; sets the next audit date.
create or replace function public.audit_asset(p_asset uuid, p_condition text default 'good', p_location text default null, p_note text default null, p_next date default null)
returns date language plpgsql security definer set search_path = public as $$
declare a assets; v_next date;
begin
  select * into a from assets where id = p_asset for update;
  if not found then raise exception 'Asset not found'; end if;
  if not asset_manager(a.company_id) then raise exception 'Only the storekeeper, Finance or an admin can audit assets'; end if;
  if a.status <> 'active' then raise exception '% has been disposed of', a.tag; end if;
  v_next := coalesce(p_next, current_date + make_interval(months => coalesce((select asset_audit_months from companies where id = a.company_id), 12)));
  insert into asset_audits (company_id, asset_id, location, condition, note, next_audit) values (a.company_id, a.id, coalesce(nullif(trim(p_location), ''), a.location), p_condition, p_note, v_next);
  insert into asset_movements (company_id, asset_id, kind, from_location, to_location, from_custodian, to_custodian, state_after, note)
  values (a.company_id, a.id, 'audit', a.location, coalesce(nullif(trim(p_location), ''), a.location), a.custodian_id, a.custodian_id,
          case p_condition when 'broken' then 'broken' when 'missing' then 'lost' else a.state end, 'Audit: ' || p_condition || coalesce(' · ' || p_note, ''));
  update assets set last_audit = current_date, next_audit = v_next, location = coalesce(nullif(trim(p_location), ''), location),
         state = case p_condition when 'broken' then 'broken' when 'missing' then 'lost' else state end,
         custodian_id = case when p_condition = 'missing' then null else custodian_id end
   where id = a.id;
  return v_next;
end $$;

-- Staff ask for equipment; the storekeeper approves and checks it out.
create or replace function public.request_asset(cid uuid, p_description text, p_asset uuid default null, p_category uuid default null, p_project uuid default null,
  p_from date default null, p_until date default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v uuid; v_emp uuid; n text;
begin
  perform require_member(cid, array['owner','admin','accountant','sales','project_manager','hr','store','staff']);
  if coalesce(trim(p_description), '') = '' and p_asset is null then raise exception 'Say what you need'; end if;
  if p_asset is not null and not exists (select 1 from assets where id = p_asset and company_id = cid and requestable and status = 'active') then raise exception 'That asset cannot be requested'; end if;
  if p_until is not null and p_until < coalesce(p_from, current_date) then raise exception 'The return date is before the start date'; end if;
  select id into v_emp from employees where company_id = cid and user_id = auth.uid() limit 1;
  n := next_number(cid, 'ARQ', 'ARQ-');
  insert into asset_requests (company_id, number, asset_id, category_id, description, employee_id, project_id, needed_from, needed_until)
  values (cid, n, p_asset, p_category, coalesce(nullif(trim(p_description), ''), (select tag || ' ' || name from assets where id = p_asset)), v_emp, p_project,
          coalesce(p_from, current_date), p_until)
  returning id into v;
  perform notify(cid, array['store'], null, 'asset_requested', n || ': ' || coalesce(nullif(trim(p_description), ''), 'asset requested'),
    (select email from memberships where company_id = cid and user_id = auth.uid()), '/assets/requests');
  return v;
end $$;

create or replace function public.decide_asset_request(p_id uuid, p_approve boolean, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare r asset_requests;
begin
  select * into r from asset_requests where id = p_id for update;
  if not found then raise exception 'Request not found'; end if;
  if r.requested_by = auth.uid() and not p_approve and not asset_manager(r.company_id) then
    if r.status not in ('pending','approved') then raise exception 'Already %', r.status; end if;
    update asset_requests set status = 'cancelled' where id = p_id; return;       -- the requester withdraws it
  end if;
  if not asset_manager(r.company_id) then raise exception 'Only the storekeeper, Finance or an admin can decide asset requests'; end if;
  if r.status <> 'pending' then raise exception 'Already %', r.status; end if;
  update asset_requests set status = case when p_approve then 'approved' else 'rejected' end, decided_by = auth.uid(), decided_on = current_date, decision_note = p_note where id = p_id;
  perform notify(r.company_id, array[]::text[], array[r.requested_by], 'asset_request_decided',
    r.number || ' ' || case when p_approve then 'approved' else 'declined' end, p_note, '/assets/requests', true);
end $$;

alter table public.asset_audits enable row level security;
create policy "members read audits" on public.asset_audits for select using (is_member(company_id));
alter table public.asset_requests enable row level security;
create policy "requests read" on public.asset_requests for select using (requested_by = auth.uid() or asset_manager(company_id) or has_role(company_id, array['project_manager','hr']));
create trigger asset_audits_audit after insert or update or delete on public.asset_audits for each row execute function public.audit_row();
create trigger asset_requests_audit after insert or update or delete on public.asset_requests for each row execute function public.audit_row();

-- ---------------------------------------------------------------- 6. Security
alter table public.contracts enable row level security;
create policy "contracts read" on public.contracts for select using (can_see_contract(contracts));
create policy "contracts add" on public.contracts for insert with check (has_role(company_id, array['owner','admin','accountant','sales','project_manager']));
create policy "contracts change" on public.contracts for update using (can_edit_contract(contracts)) with check (can_edit_contract(contracts));
create policy "contracts delete drafts" on public.contracts for delete using (status = 'draft' and has_role(company_id, array['owner','admin','accountant']));
do $$ declare t text; begin
  foreach t in array array['contract_variations','contract_securities','contract_obligations','contract_files'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy "read with contract" on public.%I for select using (exists (select 1 from contracts c where c.id = contract_id and can_see_contract(c)))', t);
    execute format('create policy "write with contract" on public.%I for all using (exists (select 1 from contracts c where c.id = contract_id and can_edit_contract(c))) with check (exists (select 1 from contracts c where c.id = contract_id and can_edit_contract(c)))', t);
    execute format('create trigger %I after insert or update or delete on public.%I for each row execute function public.audit_row()', t || '_audit', t);
  end loop;
end $$;
create trigger contracts_audit after insert or update or delete on public.contracts for each row execute function public.audit_row();

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


-- ======================================================================
-- 0013_asnys_v2_7.sql
-- ======================================================================
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


-- ======================================================================
-- 0014_asnys_v2_8.sql
-- ======================================================================
-- Asnys ERP v2.8 — projects on hold until further notice
--   1. A project can be put on hold before it starts as well as while it is in progress.
--   2. The hold records since when, why, and an optional review date (blank = until further notice).
--   3. Resuming returns a project to where it was: Not started if work never began, otherwise In progress.
--   4. While on hold, new time, expense claims, purchase requests, spend requests, cash advances, purchase orders,
--      stock issues and stock requests for the project are refused. Accountants, admins and owners can still book
--      costs that must be paid (security, standby, storage). Returns to store are always allowed.
--   5. The project manager and Finance are reminded when the review date arrives.
-- Run after 0013.

alter table public.projects add column if not exists hold_since date;
alter table public.projects add column if not exists hold_reason text;
alter table public.projects add column if not exists hold_review date;
alter table public.projects add column if not exists hold_reminded date;

-- Projects already on hold: take the date and reason from their last stage change.
update public.projects p set hold_since = l.changed_at::date, hold_reason = l.note
from (select distinct on (project_id) project_id, changed_at, note from public.project_status_log
      where to_status = 'on_hold' order by project_id, changed_at desc) l
where p.id = l.project_id and p.status = 'on_hold' and p.hold_since is null;
update public.projects set hold_since = current_date where status = 'on_hold' and hold_since is null;

drop function if exists public.set_project_status(uuid, text, text, date, boolean);
create or replace function public.set_project_status(p_project uuid, p_action text, p_note text default null, p_date date default current_date,
  p_force boolean default false, p_review date default null)
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
    when 'hold' then case when pr.status in ('planned','active') then 'on_hold' end
    when 'resume' then case when pr.status = 'on_hold' then case when pr.actual_start is null then 'planned' else 'active' end end
    when 'hold_review' then case when pr.status = 'on_hold' then 'on_hold' end
    when 'complete' then case when pr.status = 'active' or (pr.status = 'on_hold' and pr.actual_start is not null) then 'done' end
    when 'resume_work' then case when pr.status = 'done' then 'active' end
    when 'close' then case when pr.status = 'done' then 'closed' end
    when 'reopen' then case when pr.status in ('closed','cancelled') then case when pr.status = 'closed' then 'done' else 'planned' end end
    when 'cancel' then case when pr.status in ('planned','active','on_hold') then 'cancelled' end
  end;
  if v_to is null then raise exception 'You cannot % a project that is %', replace(p_action, '_', ' '), replace(pr.status, '_', ' '); end if;
  if p_action in ('hold','cancel','reopen') and coalesce(trim(p_note),'') = '' then raise exception 'Give a reason'; end if;
  if p_action in ('hold','hold_review') and p_review is not null and p_review < current_date then raise exception 'The review date cannot be in the past'; end if;
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
    actual_start = case when v_to = 'active' and p_action <> 'resume' then coalesce(actual_start, p_date) else actual_start end,
    actual_end = case when v_to = 'done' then p_date when p_action = 'resume_work' then null else actual_end end,
    closed_at = case when v_to = 'closed' then now() when p_action = 'reopen' then null else closed_at end,
    closed_by = case when v_to = 'closed' then auth.uid() when p_action = 'reopen' then null else closed_by end,
    close_notes = case when v_to = 'closed' then p_note else close_notes end,
    percent_complete_override = case when v_to = 'done' then 100 when p_action = 'resume_work' then null else percent_complete_override end,
    hold_since = case when p_action = 'hold' then current_date when v_to = 'on_hold' then hold_since end,
    hold_reason = case when p_action = 'hold' then trim(p_note) when v_to = 'on_hold' then hold_reason end,
    hold_review = case when p_action in ('hold','hold_review') then p_review when v_to = 'on_hold' then hold_review end,
    hold_reminded = case when p_action in ('hold','hold_review') then null when v_to = 'on_hold' then hold_reminded end
  where id = p_project;
  perform set_config('sika.lifecycle','off', true);
  select email into v_email from auth.users where id = auth.uid();
  insert into project_status_log (company_id, project_id, from_status, to_status, note, changed_email)
  values (pr.company_id, p_project, pr.status, v_to,
    case when p_force and p_action = 'close' then 'Closed with open items: ' || p_note
         when p_action in ('hold','hold_review') then concat_ws(' · ', nullif(trim(coalesce(p_note,'')), ''),
           case when p_review is null then 'Until further notice' else 'Review on ' || to_char(p_review, 'DD Mon YYYY') end)
         else p_note end, v_email);
  if p_action in ('hold','resume','cancel') then
    perform notify(pr.company_id, array['accountant'], array_remove(array[pr.manager_id], null), 'project_' || p_action,
      coalesce(pr.number || ' ', '') || pr.name || case p_action when 'hold' then ' is on hold' when 'resume' then ' has resumed' else ' was cancelled' end,
      case when p_action = 'hold' then trim(p_note) || case when p_review is null then ' (until further notice)' else ' (review on ' || to_char(p_review, 'DD Mon YYYY') || ')' end else p_note end,
      '/projects/' || p_project, false);
  end if;
  return v_to;
end $$;

-- Closed or cancelled: nothing new. On hold: no new work or spending except by Finance; returns to store always allowed.
create or replace function public.closed_project_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare st text; pid uuid; cid uuid; v_since date;
begin
  pid := new.project_id;
  if pid is null then return new; end if;
  select status, company_id, hold_since into st, cid, v_since from projects where id = pid;
  if st in ('closed','cancelled') then raise exception 'This project is %. Reopen it to book anything to it.', st; end if;
  if st = 'on_hold'
     and tg_table_name in ('timesheets','expense_claims','project_requests','spend_requests','cash_advances','po_lines','stock_issues','stock_requests')
     and not (tg_table_name = 'stock_issues' and coalesce(to_jsonb(new)->>'kind', 'issue') = 'return')
     and not has_role(cid, array['owner','admin','accountant']) then
    raise exception 'This project is on hold%. Resume work on the project first, or ask Finance to book it.',
      case when v_since is not null then ' since ' || to_char(v_since, 'DD Mon YYYY') else '' end;
  end if;
  return new;
end $$;

do $$ declare t text; begin
  foreach t in array array['spend_requests','cash_advances'] loop
    if not exists (select 1 from pg_trigger where tgname = t || '_closed_project') then
      execute format('create trigger %I before insert on public.%I for each row execute function public.closed_project_guard()', t || '_closed_project', t);
    end if;
  end loop;
end $$;

-- Daily: remind the project manager and Finance when a held project reaches its review date (once per review date).
create or replace function public.run_project_hold_reminders() returns int
language plpgsql security definer set search_path = public as $$
declare r record; n int := 0;
begin
  for r in select * from projects where status = 'on_hold' and hold_review is not null and hold_review <= current_date
             and (hold_reminded is null or hold_reminded < hold_review) loop
    perform notify(r.company_id, array['accountant'], array_remove(array[r.manager_id], null), 'project_hold_review',
      coalesce(r.number || ' ', '') || r.name || ': on-hold review due',
      'On hold since ' || to_char(coalesce(r.hold_since, current_date), 'DD Mon YYYY') || coalesce(': ' || r.hold_reason, '') ||
      '. Resume work, set a new review date, or cancel.', '/projects/' || r.id, true);
    update projects set hold_reminded = current_date where id = r.id;
    n := n + 1;
  end loop;
  return n;
end $$;
revoke execute on function public.run_project_hold_reminders() from public, anon, authenticated;

-- The daily cash reminder job (asnys-cash-reminders) now also sends the on-hold review reminders, so no new schedule is needed.
create or replace function public.run_all_cash_reminders() returns int
language plpgsql security definer set search_path = public as $$
declare c record; n int := 0;
begin
  for c in select id from companies loop
    begin n := n + coalesce(run_cash_reminders_internal(c.id), 0); exception when others then null; end;
  end loop;
  begin n := n + coalesce(run_project_hold_reminders(), 0); exception when others then null; end;
  return n;
end $$;
revoke execute on function public.run_all_cash_reminders() from public, anon, authenticated;


-- ======================================================================
-- 0015_asnys_v2_8_1.sql
-- ======================================================================
-- Asnys ERP v2.8.1 — one link between tenders and projects
-- A tender records the project it became (tenders.project_id) and a project records the tender it came from
-- (projects.tender_id). Two database links between the same tables made Supabase refuse pages that show a tender's
-- project ("more than one relationship was found for 'tenders' and 'projects'"). The project keeps its tender_id, but it
-- is no longer a database link; a trigger clears it when a tender is deleted, which is what the link did. Run after 0014.

alter table public.projects drop constraint if exists projects_tender_id_fkey;

create or replace function public.clear_project_tender() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update projects set tender_id = null where tender_id = old.id;
  return old;
end $$;
drop trigger if exists tenders_clear_project on public.tenders;
create trigger tenders_clear_project after delete on public.tenders for each row execute function public.clear_project_tender();

-- Tell Supabase's API to re-read the links now.
notify pgrst, 'reload schema';


-- ======================================================================
-- 0016_asnys_v2_9.sql
-- ======================================================================
-- Asnys ERP v2.9 — Safety, Compliance & Sustainability
-- Built around the structure of the international management-system standards:
--   ISO 45001 (occupational health and safety): hazard reporting, incidents and investigation, permits to work,
--     inspections, corrective and preventive actions, safety performance (LTIFR, TRIR).
--   ISO 37301 (compliance management): register of compliance obligations (permits, licences, filings, certificates,
--     insurance) with owners, evidence, renewal and reminders; policies that staff must read and acknowledge.
--   ISO 14001 and the GHG Protocol / GRI 302-306: energy, fuel, water and waste records converted to tonnes of CO2e by
--     scope with editable emission factors, for sustainability reporting.
-- HSE officer is a tick on a team member (any role can also be the HSE officer). Owners and admins always count as one.
-- Site safety: toolbox talks with attendance, company / site / visitor inductions with expiry (optional "no induction,
--   no work" rule on timesheets), emergency drills and safety meetings; a Safety tab on every project.
-- Run after 0015.

-- ---------------------------------------------------------------- 1. HSE officers
alter table public.memberships add column if not exists hse boolean not null default false;

create or replace function public.is_hse(cid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from memberships where company_id = cid and user_id = auth.uid() and (hse or role in ('owner','admin')));
$$;

create or replace function public.hse_users(cid uuid) returns uuid[]
language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(user_id), '{}') from memberships where company_id = cid and hse;
$$;

create or replace function public.set_member_hse(cid uuid, p_user uuid, p_on boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not has_role(cid, array['owner','admin']) then raise exception 'Only an owner or admin can choose HSE officers'; end if;
  update memberships set hse = p_on where company_id = cid and user_id = p_user;
  if not found then raise exception 'That person is not in this company'; end if;
end $$;

-- Notify only the people named (the general notify() also copies every owner and admin).
create or replace function public.notify_users(cid uuid, p_users uuid[], p_kind text, p_title text, p_body text default null, p_path text default null, p_include_self boolean default false)
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  insert into notifications (company_id, user_id, kind, title, body, path)
  select distinct cid, u, p_kind, p_title, p_body, p_path from unnest(coalesce(p_users, '{}'::uuid[])) u
  where u is not null and exists (select 1 from memberships m where m.company_id = cid and m.user_id = u) and (p_include_self or u is distinct from auth.uid());
  get diagnostics n = row_count;
  return n;
end $$;

-- Anyone in the company who is managing a project (its manager), or an HSE officer.
create or replace function public.hse_or_pm(cid uuid, pid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select is_hse(cid) or (pid is not null and exists (select 1 from projects where id = pid and manager_id = auth.uid()));
$$;

-- ---------------------------------------------------------------- 2. Incidents, near misses and observations
create table public.hse_incidents (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  number text,
  kind text not null default 'near_miss' check (kind in ('observation','near_miss','first_aid','medical_treatment','restricted_work',
    'lost_time','fatality','property_damage','environmental','dangerous_occurrence','vehicle','security','occupational_illness')),
  occurred_at timestamptz not null default now(),
  project_id uuid references public.projects(id) on delete set null,
  location text,
  description text not null,
  immediate_action text,
  persons_involved text,
  injured_employee_id uuid references public.employees(id) on delete set null,
  injured_name text,
  injury_nature text,
  body_part text,
  lost_days int not null default 0 check (lost_days >= 0),
  cost_estimate numeric(14,2),
  potential_severity int check (potential_severity between 1 and 5),
  reportable boolean not null default false,
  authority text,
  authority_ref text,
  reported_to_authority_on date,
  reported_by uuid default auth.uid(),
  reported_email text,
  investigator_id uuid,
  root_cause text,
  contributing_factors text,
  findings text,
  status text not null default 'reported' check (status in ('reported','investigating','action','closed')),
  closed_by uuid, closed_at timestamptz, closure_note text,
  created_at timestamptz not null default now()
);
create index on public.hse_incidents (company_id, occurred_at desc);

create table public.hse_files (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  parent_type text not null check (parent_type in ('incident','inspection','permit','obligation','policy','action','session')),
  parent_id uuid not null,
  name text not null,
  storage_path text not null,
  size_bytes bigint,
  note text,
  valid_until date,
  uploaded_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);
create index on public.hse_files (parent_type, parent_id);

create or replace function public.hse_incident_defaults() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    if not is_member(new.company_id) then raise exception 'You do not have access to this company'; end if;
    new.number := coalesce(new.number, next_number(new.company_id, 'INC', 'INC-'));
    new.status := 'reported';
    new.reported_by := coalesce(new.reported_by, auth.uid());
    new.reported_email := (select email from auth.users where id = new.reported_by);
    new.closed_by := null; new.closed_at := null;
    if new.occurred_at > now() + interval '1 hour' then raise exception 'The incident cannot be in the future'; end if;
  elsif coalesce(current_setting('sika.hse', true), '') <> 'on' then
    if new.status is distinct from old.status or new.closed_by is distinct from old.closed_by then
      raise exception 'Use Start investigation, Actions under way and Close to move an incident along';
    end if;
    if old.status = 'closed' then raise exception 'This incident is closed. An HSE officer can reopen it.'; end if;
    if not (hse_or_pm(old.company_id, old.project_id) or old.investigator_id = auth.uid()
            or (old.status = 'reported' and old.reported_by = auth.uid())) then
      raise exception 'Only the HSE officer, the investigator or the project manager can change this incident';
    end if;
    new.number := old.number; new.reported_by := old.reported_by; new.reported_email := old.reported_email; new.company_id := old.company_id;
  end if;
  return new;
end $$;
create trigger hse_incidents_defaults before insert or update on public.hse_incidents for each row execute function public.hse_incident_defaults();

-- Labels for messages.
create or replace function public.hse_kind_label(k text) returns text language sql immutable as $$
  select case k when 'observation' then 'Safety observation' when 'near_miss' then 'Near miss' when 'first_aid' then 'First-aid injury'
    when 'medical_treatment' then 'Medical treatment injury' when 'restricted_work' then 'Restricted work injury' when 'lost_time' then 'Lost-time injury'
    when 'fatality' then 'Fatality' when 'property_damage' then 'Property damage' when 'environmental' then 'Environmental incident'
    when 'dangerous_occurrence' then 'Dangerous occurrence' when 'vehicle' then 'Vehicle incident' when 'security' then 'Security incident'
    when 'occupational_illness' then 'Occupational illness' else k end;
$$;

-- Recordable (TRIR) and lost-time (LTIFR) classes.
create or replace function public.hse_recordable(k text) returns boolean language sql immutable as $$
  select k in ('medical_treatment','restricted_work','lost_time','fatality','occupational_illness');
$$;
create or replace function public.hse_lti(k text) returns boolean language sql immutable as $$
  select k in ('lost_time','fatality');
$$;

create or replace function public.hse_incident_notice() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_pm uuid; v_serious boolean;
begin
  select manager_id into v_pm from projects where id = new.project_id;
  v_serious := new.kind in ('lost_time','fatality','dangerous_occurrence','environmental') or coalesce(new.potential_severity, 0) >= 4;
  if v_serious then
    perform notify(new.company_id, array[]::text[], array_remove(hse_users(new.company_id) || v_pm, null), 'hse_incident',
      hse_kind_label(new.kind) || ' reported: ' || new.number, left(new.description, 160) || coalesce(' · ' || new.location, ''), '/hse/incidents/' || new.id, false);
  else
    perform notify_users(new.company_id, array_remove(hse_users(new.company_id) || v_pm, null), 'hse_incident',
      hse_kind_label(new.kind) || ' reported: ' || new.number, left(new.description, 160) || coalesce(' · ' || new.location, ''), '/hse/incidents/' || new.id, false);
  end if;
  return null;
end $$;
create trigger hse_incidents_notice after insert on public.hse_incidents for each row execute function public.hse_incident_notice();

-- ---------------------------------------------------------------- 3. Corrective and preventive actions (CAPA)
create table public.hse_actions (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  number text,
  source text not null default 'other' check (source in ('incident','inspection','audit','obligation','risk','observation','management_review','other')),
  source_id uuid,
  project_id uuid references public.projects(id) on delete set null,
  title text not null,
  description text,
  kind text not null default 'corrective' check (kind in ('corrective','preventive','improvement')),
  priority text not null default 'medium' check (priority in ('low','medium','high')),
  owner_id uuid,
  due_date date,
  status text not null default 'open' check (status in ('open','done','verified','cancelled')),
  done_by uuid, done_at timestamptz, done_note text,
  verified_by uuid, verified_at timestamptz, verify_note text,
  reminded_on date,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);
create index on public.hse_actions (company_id, status, due_date);
create index on public.hse_actions (source, source_id);

create or replace function public.hse_action_defaults() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    if coalesce(current_setting('sika.hse', true), '') <> 'on' and not hse_or_pm(new.company_id, new.project_id) then
      raise exception 'Only an HSE officer or the project manager can raise actions';
    end if;
    new.number := coalesce(new.number, next_number(new.company_id, 'CAPA', 'CAPA-'));
    new.status := 'open'; new.done_by := null; new.verified_by := null;
    new.created_by := coalesce(new.created_by, auth.uid());
  elsif coalesce(current_setting('sika.hse', true), '') <> 'on' then
    if (new.status, new.done_by, new.verified_by) is distinct from (old.status, old.done_by, old.verified_by) then
      raise exception 'Use Mark done, Verify, Reopen or Cancel to change an action';
    end if;
    if old.status in ('verified','cancelled') then raise exception 'This action is closed'; end if;
    if not hse_or_pm(old.company_id, old.project_id) then raise exception 'Only an HSE officer or the project manager can change this action'; end if;
    new.number := old.number; new.company_id := old.company_id; new.source := old.source; new.source_id := old.source_id;
  end if;
  return new;
end $$;
create trigger hse_actions_defaults before insert or update on public.hse_actions for each row execute function public.hse_action_defaults();

create or replace function public.hse_action_notice() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.owner_id is not null and (tg_op = 'INSERT' or new.owner_id is distinct from old.owner_id) then
    perform notify_users(new.company_id, array[new.owner_id], 'hse_action', 'Action for you: ' || new.number,
      new.title || coalesce(' · due ' || to_char(new.due_date, 'DD Mon YYYY'), ''), '/hse/actions', false);
  end if;
  return null;
end $$;
create trigger hse_actions_notice after insert or update on public.hse_actions for each row execute function public.hse_action_notice();

-- Owner (or HSE) marks done; a different person, an HSE officer, verifies it worked.
create or replace function public.hse_action_step(p_id uuid, p_action text, p_note text default null) returns text
language plpgsql security definer set search_path = public as $$
declare a hse_actions; v_to text;
begin
  select * into a from hse_actions where id = p_id for update;
  if not found then raise exception 'Action not found'; end if;
  if not is_member(a.company_id) then raise exception 'You do not have access to this company'; end if;
  if p_action = 'done' then
    if a.status <> 'open' then raise exception 'Only an open action can be marked done'; end if;
    if not (a.owner_id = auth.uid() or hse_or_pm(a.company_id, a.project_id)) then raise exception 'Only the action owner, the project manager or an HSE officer can mark it done'; end if;
    if coalesce(trim(p_note), '') = '' then raise exception 'Say what was done'; end if;
    v_to := 'done';
  elsif p_action = 'verify' then
    if a.status <> 'done' then raise exception 'Mark the action done before verifying it'; end if;
    if not is_hse(a.company_id) then raise exception 'Only an HSE officer can verify that an action worked'; end if;
    if a.done_by = auth.uid() then raise exception 'Someone other than the person who did the work must verify it'; end if;
    v_to := 'verified';
  elsif p_action = 'reopen' then
    if a.status not in ('done') then raise exception 'Only an action marked done can be sent back'; end if;
    if not is_hse(a.company_id) then raise exception 'Only an HSE officer can send an action back'; end if;
    if coalesce(trim(p_note), '') = '' then raise exception 'Say why it is not effective yet'; end if;
    v_to := 'open';
  elsif p_action = 'cancel' then
    if a.status not in ('open','done') then raise exception 'This action is already closed'; end if;
    if not is_hse(a.company_id) then raise exception 'Only an HSE officer can cancel an action'; end if;
    if coalesce(trim(p_note), '') = '' then raise exception 'Give a reason'; end if;
    v_to := 'cancelled';
  else raise exception 'Unknown step %', p_action;
  end if;
  perform set_config('sika.hse', 'on', true);
  update hse_actions set status = v_to,
    done_by = case when p_action = 'done' then auth.uid() when p_action = 'reopen' then null else done_by end,
    done_at = case when p_action = 'done' then now() when p_action = 'reopen' then null else done_at end,
    done_note = case when p_action = 'done' then p_note else done_note end,
    verified_by = case when p_action = 'verify' then auth.uid() else verified_by end,
    verified_at = case when p_action = 'verify' then now() else verified_at end,
    verify_note = case when p_action in ('verify','reopen','cancel') then p_note else verify_note end
  where id = p_id;
  perform set_config('sika.hse', 'off', true);
  if p_action = 'done' then
    perform notify_users(a.company_id, hse_users(a.company_id), 'hse_action_done', a.number || ' done: please verify', a.title, '/hse/actions', false);
  elsif p_action = 'reopen' and a.owner_id is not null then
    perform notify_users(a.company_id, array[a.owner_id], 'hse_action_reopened', a.number || ' sent back', p_note, '/hse/actions', false);
  end if;
  return v_to;
end $$;

-- Incident workflow: investigate → actions → close (root cause recorded, every action verified or cancelled).
create or replace function public.hse_incident_step(p_id uuid, p_action text, p_note text default null, p_investigator uuid default null) returns text
language plpgsql security definer set search_path = public as $$
declare i hse_incidents; v_to text; v_open int;
begin
  select * into i from hse_incidents where id = p_id for update;
  if not found then raise exception 'Incident not found'; end if;
  if not hse_or_pm(i.company_id, i.project_id) then raise exception 'Only an HSE officer or the project manager can do this'; end if;
  if p_action = 'investigate' then
    if i.status <> 'reported' then raise exception 'The investigation has already started'; end if;
    v_to := 'investigating';
  elsif p_action = 'actions' then
    if i.status not in ('reported','investigating') then raise exception 'This incident is already past investigation'; end if;
    if i.kind <> 'observation' and coalesce(trim(i.root_cause), '') = '' then raise exception 'Record the root cause first'; end if;
    v_to := 'action';
  elsif p_action = 'close' then
    if i.status = 'closed' then raise exception 'Already closed'; end if;
    if not is_hse(i.company_id) then raise exception 'Only an HSE officer can close an incident'; end if;
    if i.kind not in ('observation','near_miss') and coalesce(trim(i.root_cause), '') = '' then raise exception 'Record the root cause before closing'; end if;
    select count(*) into v_open from hse_actions where source = 'incident' and source_id = p_id and status in ('open','done');
    if v_open > 0 then raise exception '% action% still open or waiting for verification', v_open, case when v_open = 1 then ' is' else 's are' end; end if;
    if i.reportable and i.authority_ref is null and i.reported_to_authority_on is null then
      raise exception 'This incident is reportable: record when it was reported to the authority and their reference';
    end if;
    v_to := 'closed';
  elsif p_action = 'reopen' then
    if i.status <> 'closed' then raise exception 'Only a closed incident can be reopened'; end if;
    if not is_hse(i.company_id) then raise exception 'Only an HSE officer can reopen an incident'; end if;
    if coalesce(trim(p_note), '') = '' then raise exception 'Give a reason'; end if;
    v_to := 'action';
  else raise exception 'Unknown step %', p_action;
  end if;
  perform set_config('sika.hse', 'on', true);
  update hse_incidents set status = v_to,
    investigator_id = case when p_action = 'investigate' then coalesce(p_investigator, investigator_id, auth.uid()) else investigator_id end,
    closed_by = case when v_to = 'closed' then auth.uid() when p_action = 'reopen' then null else closed_by end,
    closed_at = case when v_to = 'closed' then now() when p_action = 'reopen' then null else closed_at end,
    closure_note = case when v_to = 'closed' or p_action = 'reopen' then p_note else closure_note end
  where id = p_id;
  perform set_config('sika.hse', 'off', true);
  if p_action = 'investigate' and coalesce(p_investigator, auth.uid()) <> auth.uid() then
    perform notify_users(i.company_id, array[p_investigator], 'hse_investigate', 'Investigate ' || i.number, left(i.description, 160), '/hse/incidents/' || p_id, false);
  end if;
  if i.reported_by is not null and v_to = 'closed' then
    perform notify_users(i.company_id, array[i.reported_by], 'hse_closed', i.number || ' closed', coalesce(p_note, 'Thank you for reporting it.'), '/hse/incidents/' || p_id, false);
  end if;
  return v_to;
end $$;

-- ---------------------------------------------------------------- 4. Inspections with checklists
create table public.hse_checklists (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  name text not null,
  kind text not null default 'inspection' check (kind in ('inspection','audit','pre_use','toolbox')),
  items jsonb not null default '[]'::jsonb,   -- ["Item to check", ...]
  active boolean not null default true,
  created_at timestamptz not null default now()
);
create table public.hse_inspections (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  number text,
  checklist_id uuid references public.hse_checklists(id) on delete set null,
  title text not null,
  kind text not null default 'inspection' check (kind in ('inspection','audit','pre_use','toolbox')),
  project_id uuid references public.projects(id) on delete set null,
  location text,
  inspected_on date not null default current_date,
  inspector_id uuid default auth.uid(),
  inspector_email text,
  attendees text,
  results jsonb not null default '[]'::jsonb, -- [{"item":"…","result":"pass|fail|na","note":"…"}]
  score numeric(5,1),
  status text not null default 'draft' check (status in ('draft','completed')),
  notes text,
  completed_at timestamptz,
  created_at timestamptz not null default now()
);
create index on public.hse_inspections (company_id, inspected_on desc);

create or replace function public.hse_inspection_defaults() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    if not is_member(new.company_id) then raise exception 'You do not have access to this company'; end if;
    new.number := coalesce(new.number, next_number(new.company_id, 'HSI', 'HSI-'));
    new.status := 'draft'; new.score := null; new.completed_at := null;
    new.inspector_id := coalesce(new.inspector_id, auth.uid());
    new.inspector_email := (select email from auth.users where id = new.inspector_id);
    if new.checklist_id is not null and jsonb_array_length(new.results) = 0 then
      select coalesce(jsonb_agg(jsonb_build_object('item', x, 'result', null, 'note', null)), '[]'::jsonb), max(c.kind)
        into new.results, new.kind
        from hse_checklists c, jsonb_array_elements_text(c.items) x where c.id = new.checklist_id;
      new.kind := coalesce(new.kind, 'inspection');
    end if;
  elsif coalesce(current_setting('sika.hse', true), '') <> 'on' then
    if old.status = 'completed' then raise exception 'A completed inspection cannot be changed'; end if;
    if new.status is distinct from old.status then raise exception 'Use Complete to finish the inspection'; end if;
    if not (old.inspector_id = auth.uid() or hse_or_pm(old.company_id, old.project_id)) then raise exception 'Only the inspector, the project manager or an HSE officer can change this inspection'; end if;
    new.number := old.number; new.company_id := old.company_id;
  end if;
  return new;
end $$;
create trigger hse_inspections_defaults before insert or update on public.hse_inspections for each row execute function public.hse_inspection_defaults();

-- Completing scores the checklist and raises a corrective action for every failed item.
create or replace function public.complete_hse_inspection(p_id uuid, p_due date default null) returns int
language plpgsql security definer set search_path = public as $$
declare s hse_inspections; v_pass int; v_fail int; v_blank int; r jsonb; n int := 0; v_owner uuid;
begin
  select * into s from hse_inspections where id = p_id for update;
  if not found then raise exception 'Inspection not found'; end if;
  if s.status = 'completed' then raise exception 'Already completed'; end if;
  if not (s.inspector_id = auth.uid() or hse_or_pm(s.company_id, s.project_id)) then raise exception 'Only the inspector, the project manager or an HSE officer can complete it'; end if;
  select count(*) filter (where e->>'result' = 'pass'), count(*) filter (where e->>'result' = 'fail'), count(*) filter (where coalesce(e->>'result','') = '')
    into v_pass, v_fail, v_blank from jsonb_array_elements(s.results) e;
  if v_blank > 0 then raise exception '% item% not answered. Mark each one pass, fail or not applicable.', v_blank, case when v_blank = 1 then ' is' else 's are' end; end if;
  if v_pass + v_fail = 0 then raise exception 'Mark at least one item as pass or fail'; end if;
  select manager_id into v_owner from projects where id = s.project_id;
  perform set_config('sika.hse', 'on', true);
  update hse_inspections set status = 'completed', completed_at = now(), score = round(100.0 * v_pass / (v_pass + v_fail), 1) where id = p_id;
  for r in select e from jsonb_array_elements(s.results) e where e->>'result' = 'fail' loop
    insert into hse_actions (company_id, source, source_id, project_id, title, description, kind, priority, owner_id, due_date)
    values (s.company_id, 'inspection', p_id, s.project_id, left('Fix: ' || (r->>'item'), 200),
      concat_ws(E'\n', s.number || ' ' || s.title || coalesce(' at ' || s.location, ''), nullif(r->>'note', '')),
      'corrective', 'medium', coalesce(v_owner, s.inspector_id), coalesce(p_due, current_date + 7));
    n := n + 1;
  end loop;
  perform set_config('sika.hse', 'off', true);
  return n;
end $$;

-- ---------------------------------------------------------------- 5. Permits to work
create table public.hse_permits (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  number text,
  kind text not null check (kind in ('hot_work','confined_space','height','electrical','excavation','lifting','general')),
  project_id uuid references public.projects(id) on delete set null,
  location text not null,
  work_description text not null,
  hazards text,
  precautions text,
  isolations text,
  gas_test text,
  ppe text,
  workers text,
  valid_from timestamptz not null,
  valid_to timestamptz not null,
  requested_by uuid default auth.uid(),
  requested_email text,
  issued_by uuid, issued_email text, issued_at timestamptz,
  status text not null default 'requested' check (status in ('requested','approved','suspended','closed','cancelled','rejected')),
  decision_note text,
  closed_by uuid, closed_at timestamptz, close_note text,
  reminded_on date,
  created_at timestamptz not null default now(),
  check (valid_to > valid_from)
);
create index on public.hse_permits (company_id, status, valid_to);

create or replace function public.hse_permit_defaults() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    if not is_member(new.company_id) then raise exception 'You do not have access to this company'; end if;
    new.number := coalesce(new.number, next_number(new.company_id, 'PTW', 'PTW-'));
    new.status := 'requested'; new.issued_by := null; new.issued_at := null; new.closed_by := null;
    new.requested_by := coalesce(new.requested_by, auth.uid());
    new.requested_email := (select email from auth.users where id = new.requested_by);
    if new.valid_to - new.valid_from > interval '7 days' then raise exception 'A permit can be valid for at most 7 days. Raise a new permit for longer work.'; end if;
  elsif coalesce(current_setting('sika.hse', true), '') <> 'on' then
    if (new.status, new.issued_by, new.closed_by) is distinct from (old.status, old.issued_by, old.closed_by) then
      raise exception 'Use Approve, Reject, Suspend, Resume, Close or Cancel to change a permit';
    end if;
    if old.status <> 'requested' then raise exception 'An approved permit cannot be changed. Cancel it and raise a new one.'; end if;
    if old.requested_by <> auth.uid() and not hse_or_pm(old.company_id, old.project_id) then raise exception 'Only the requester can change this permit'; end if;
    if new.valid_to - new.valid_from > interval '7 days' then raise exception 'A permit can be valid for at most 7 days'; end if;
    new.number := old.number; new.company_id := old.company_id; new.requested_by := old.requested_by; new.requested_email := old.requested_email;
  end if;
  return new;
end $$;
create trigger hse_permits_defaults before insert or update on public.hse_permits for each row execute function public.hse_permit_defaults();

create or replace function public.hse_permit_notice() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_pm uuid;
begin
  select manager_id into v_pm from projects where id = new.project_id;
  perform notify_users(new.company_id, array_remove(hse_users(new.company_id) || v_pm, null), 'hse_permit',
    'Permit to work requested: ' || new.number, replace(new.kind, '_', ' ') || ' at ' || new.location || ' · ' || to_char(new.valid_from, 'DD Mon HH24:MI'),
    '/hse/permits', false);
  return null;
end $$;
create trigger hse_permits_notice after insert on public.hse_permits for each row execute function public.hse_permit_notice();

-- The issuer (HSE officer or the project's manager) must not be the person who asked for the permit.
create or replace function public.hse_permit_step(p_id uuid, p_action text, p_note text default null) returns text
language plpgsql security definer set search_path = public as $$
declare p hse_permits; v_to text; v_email text;
begin
  select * into p from hse_permits where id = p_id for update;
  if not found then raise exception 'Permit not found'; end if;
  if not is_member(p.company_id) then raise exception 'You do not have access to this company'; end if;
  v_to := case p_action
    when 'approve' then case when p.status = 'requested' then 'approved' end
    when 'reject' then case when p.status = 'requested' then 'rejected' end
    when 'suspend' then case when p.status = 'approved' then 'suspended' end
    when 'resume' then case when p.status = 'suspended' then 'approved' end
    when 'close' then case when p.status in ('approved','suspended') then 'closed' end
    when 'cancel' then case when p.status in ('requested','approved','suspended') then 'cancelled' end end;
  if v_to is null then raise exception 'You cannot % a permit that is %', p_action, p.status; end if;
  if p_action in ('approve','reject','suspend','resume') then
    if not hse_or_pm(p.company_id, p.project_id) then raise exception 'Only an HSE officer or the project manager can % a permit', p_action; end if;
    if p_action = 'approve' and p.requested_by = auth.uid() then raise exception 'You cannot approve a permit you asked for. Another authorised person must issue it.'; end if;
    if p_action = 'approve' and p.valid_to < now() then raise exception 'This permit''s time has passed. Change the dates or raise a new one.'; end if;
  elsif p_action = 'close' then
    if not (p.requested_by = auth.uid() or hse_or_pm(p.company_id, p.project_id)) then raise exception 'Only the requester, the project manager or an HSE officer can close it'; end if;
  elsif p_action = 'cancel' then
    if not (p.requested_by = auth.uid() or hse_or_pm(p.company_id, p.project_id)) then raise exception 'Only the requester or the issuer can cancel it'; end if;
  end if;
  if p_action in ('reject','suspend','close','cancel') and coalesce(trim(p_note), '') = '' then
    raise exception '%', case p_action when 'close' then 'Confirm the work is finished and the area left safe' else 'Give a reason' end;
  end if;
  select email into v_email from auth.users where id = auth.uid();
  perform set_config('sika.hse', 'on', true);
  update hse_permits set status = v_to,
    issued_by = case when p_action = 'approve' then auth.uid() else issued_by end,
    issued_email = case when p_action = 'approve' then v_email else issued_email end,
    issued_at = case when p_action = 'approve' then now() else issued_at end,
    decision_note = case when p_action in ('approve','reject','suspend','resume','cancel') then coalesce(p_note, decision_note) else decision_note end,
    closed_by = case when v_to = 'closed' then auth.uid() else closed_by end,
    closed_at = case when v_to = 'closed' then now() else closed_at end,
    close_note = case when v_to = 'closed' then p_note else close_note end
  where id = p_id;
  perform set_config('sika.hse', 'off', true);
  if p.requested_by is not null and p.requested_by <> auth.uid() then
    perform notify_users(p.company_id, array[p.requested_by], 'hse_permit_' || p_action, p.number || ': permit ' || v_to, p_note, '/hse/permits', false);
  end if;
  return v_to;
end $$;

-- ---------------------------------------------------------------- 6. Compliance obligations (ISO 37301)
create table public.compliance_obligations (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  title text not null,
  category text not null default 'permit_licence' check (category in ('permit_licence','regulatory_filing','certification','insurance','contract','policy','other')),
  area text not null default 'safety' check (area in ('safety','environment','quality','legal','tax_finance','labour','data_protection','anti_bribery','other')),
  authority text,
  reference text,
  project_id uuid references public.projects(id) on delete set null,
  owner_id uuid,
  issued_on date,
  expires_on date,
  recurrence text not null default 'none' check (recurrence in ('none','monthly','quarterly','semiannual','annual')),
  lead_days int not null default 30 check (lead_days between 0 and 365),
  status text not null default 'active' check (status in ('active','not_compliant','retired')),
  requirement text,
  notes text,
  reminded_for date,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);
create index on public.compliance_obligations (company_id, expires_on);

create or replace function public.compliance_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not (is_hse(coalesce(new.company_id, old.company_id)) or has_role(coalesce(new.company_id, old.company_id), array['accountant','hr'])
          or (tg_op <> 'INSERT' and old.owner_id = auth.uid())) then
    raise exception 'Only an HSE or compliance officer, Finance, HR or the obligation''s owner can change the compliance register';
  end if;
  if tg_op = 'UPDATE' then new.company_id := old.company_id; end if;
  return coalesce(new, old);
end $$;
create trigger compliance_obligations_guard before insert or update or delete on public.compliance_obligations for each row execute function public.compliance_guard();

-- Renew: record the new certificate or filing (with its file uploaded separately) and move the dates on.
create or replace function public.renew_obligation(p_id uuid, p_issued date, p_expires date, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
declare o compliance_obligations;
begin
  select * into o from compliance_obligations where id = p_id for update;
  if not found then raise exception 'Not found'; end if;
  if p_expires is not null and p_issued is not null and p_expires <= p_issued then raise exception 'The new expiry must be after the issue date'; end if;
  update compliance_obligations set issued_on = coalesce(p_issued, issued_on), expires_on = p_expires, status = 'active', reminded_for = null,
    notes = concat_ws(E'\n', notes, to_char(current_date, 'DD Mon YYYY') || ': renewed' || coalesce(' — ' || p_note, '')) where id = p_id;
end $$;

-- Next date for a recurring filing.
create or replace function public.next_due(d date, rec text) returns date language sql immutable as $$
  select case rec when 'monthly' then d + interval '1 month' when 'quarterly' then d + interval '3 months'
    when 'semiannual' then d + interval '6 months' when 'annual' then d + interval '1 year' end::date;
$$;

-- ---------------------------------------------------------------- 7. Policies and acknowledgements
create table public.hse_policies (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  title text not null,
  area text not null default 'safety' check (area in ('safety','environment','quality','legal','tax_finance','labour','data_protection','anti_bribery','other')),
  version text not null default '1',
  effective_on date not null default current_date,
  review_on date,
  summary text,
  storage_path text,
  file_name text,
  requires_ack boolean not null default true,
  active boolean not null default true,
  owner_id uuid default auth.uid(),
  created_at timestamptz not null default now()
);
create table public.hse_policy_acks (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  policy_id uuid not null references public.hse_policies(id) on delete cascade,
  user_id uuid not null default auth.uid(),
  email text,
  version text not null,
  acknowledged_at timestamptz not null default now(),
  unique (policy_id, user_id, version)
);
create or replace function public.policy_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not (is_hse(coalesce(new.company_id, old.company_id)) or has_role(coalesce(new.company_id, old.company_id), array['hr'])) then
    raise exception 'Only an HSE or compliance officer, HR, an owner or admin can publish policies';
  end if;
  return coalesce(new, old);
end $$;
create trigger hse_policies_guard before insert or update or delete on public.hse_policies for each row execute function public.policy_guard();

create or replace function public.acknowledge_policy(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare p hse_policies;
begin
  select * into p from hse_policies where id = p_id;
  if not found or not p.active then raise exception 'Policy not found'; end if;
  if not is_member(p.company_id) then raise exception 'You do not have access to this company'; end if;
  insert into hse_policy_acks (company_id, policy_id, user_id, email, version)
  values (p.company_id, p_id, auth.uid(), (select email from auth.users where id = auth.uid()), p.version)
  on conflict (policy_id, user_id, version) do nothing;
end $$;

-- ---------------------------------------------------------------- 8. Sustainability: emission factors, records, hours worked
create table public.esg_factors (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  key text not null,
  name text not null,
  category text not null check (category in ('fuel','electricity','water','waste','travel','refrigerant','other')),
  scope int check (scope in (1,2,3)),
  unit text not null,
  kg_co2e numeric(14,6) not null default 0 check (kg_co2e >= 0),
  source text,
  waste_route text check (waste_route in ('landfill','recycled','reused','composted','incinerated','hazardous')),
  active boolean not null default true,
  unique (company_id, key)
);
create table public.esg_entries (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  period date not null,                       -- first day of the month
  factor_id uuid not null references public.esg_factors(id),
  quantity numeric(16,3) not null check (quantity >= 0),
  factor_used numeric(14,6),
  kg_co2e numeric(16,3),
  project_id uuid references public.projects(id) on delete set null,
  branch_id uuid,
  source_ref text,
  note text,
  entered_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);
create index on public.esg_entries (company_id, period);
create table public.hse_hours (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  period date not null,
  project_id uuid references public.projects(id) on delete set null,
  hours numeric(12,1) not null check (hours >= 0),
  headcount int,
  note text,
  created_at timestamptz not null default now()
);

create or replace function public.esg_entry_defaults() returns trigger
language plpgsql security definer set search_path = public as $$
declare f esg_factors;
begin
  if not (is_hse(new.company_id) or has_role(new.company_id, array['accountant','store','project_manager'])) then
    raise exception 'Only an HSE officer, Finance, the storekeeper or a project manager can record sustainability data';
  end if;
  select * into f from esg_factors where id = new.factor_id;
  if f.company_id is distinct from new.company_id then raise exception 'Choose one of your own emission factors'; end if;
  new.period := date_trunc('month', new.period)::date;
  if tg_op = 'INSERT' or new.factor_id is distinct from old.factor_id or new.quantity is distinct from old.quantity then
    new.factor_used := f.kg_co2e;
    new.kg_co2e := round(new.quantity * f.kg_co2e, 3);
  end if;
  return new;
end $$;
create trigger esg_entries_defaults before insert or update on public.esg_entries for each row execute function public.esg_entry_defaults();

create or replace function public.hse_hours_defaults() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not (is_hse(new.company_id) or has_role(new.company_id, array['hr','project_manager'])) then
    raise exception 'Only an HSE officer, HR or a project manager can record hours worked';
  end if;
  new.period := date_trunc('month', new.period)::date;
  return new;
end $$;
create trigger hse_hours_defaults before insert or update on public.hse_hours for each row execute function public.hse_hours_defaults();

create or replace function public.esg_factor_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(current_setting('sika.seed', true), '') <> 'on' and not (is_hse(coalesce(new.company_id, old.company_id)) or has_role(coalesce(new.company_id, old.company_id), array['accountant'])) then
    raise exception 'Only an HSE officer or Finance can change emission factors';
  end if;
  return coalesce(new, old);
end $$;
create trigger esg_factors_guard before insert or update or delete on public.esg_factors for each row execute function public.esg_factor_guard();

-- Default factors. Fuel: UK DESNZ/DEFRA 2026 conversion factors (the most widely used published set; no Ghana set exists).
-- Grid electricity: IFI harmonised grid emission factors v2.0 (2019), Ghana, combined margin. Replace with the Energy
-- Commission's figure when you have it. Water and waste are tracked as quantities (GRI 303 and 306) with no CO2e by default.
create or replace function public.seed_esg_factors(cid uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform set_config('sika.seed', 'on', true);
  insert into esg_factors (company_id, key, name, category, scope, unit, kg_co2e, source, waste_route) values
    (cid, 'diesel_l', 'Diesel (generators, plant, vehicles)', 'fuel', 1, 'litre', 2.58354, 'UK DESNZ/DEFRA 2026, diesel (average biofuel blend)', null),
    (cid, 'petrol_l', 'Petrol', 'fuel', 1, 'litre', 2.075, 'UK DESNZ/DEFRA 2026, petrol (average biofuel blend)', null),
    (cid, 'lpg_l', 'LPG', 'fuel', 1, 'litre', 1.55713, 'UK DESNZ/DEFRA 2026, LPG', null),
    (cid, 'grid_kwh', 'Grid electricity (ECG / NEDCo)', 'electricity', 2, 'kWh', 0.360, 'IFI harmonised grid emission factors v2.0 (2019), Ghana combined margin', null),
    (cid, 'solar_kwh', 'Own solar generation', 'electricity', null, 'kWh', 0, 'Renewable, zero emissions at the point of use', null),
    (cid, 'water_m3', 'Water used', 'water', null, 'm³', 0, 'Quantity only (GRI 303)', null),
    (cid, 'waste_landfill_kg', 'Waste to landfill', 'waste', null, 'kg', 0, 'Quantity only (GRI 306)', 'landfill'),
    (cid, 'waste_recycled_kg', 'Waste recycled', 'waste', null, 'kg', 0, 'Quantity only (GRI 306)', 'recycled'),
    (cid, 'waste_hazardous_kg', 'Hazardous waste (oil, batteries, chemicals)', 'waste', null, 'kg', 0, 'Quantity only (GRI 306)', 'hazardous')
  on conflict (company_id, key) do nothing;
  insert into hse_checklists (company_id, name, kind, items)
  select cid, x.name, x.kind, x.items::jsonb from (values
    ('Site safety inspection', 'inspection', '["Site access controlled and signage in place","Housekeeping: walkways clear, materials stacked safely","PPE worn correctly (helmet, boots, vest, gloves, eye protection)","Excavations barricaded and shored","Scaffolds tagged and inspected","Ladders in good condition and secured","Edge protection and harnesses for work at height","Electrical cables and distribution boards protected","Fire extinguishers in place, in date and accessible","First-aid kit stocked and first-aider on site","Plant and vehicles with valid inspection, banksman used","Permits to work in place for high-risk work","Toolbox talk held today","Welfare: water, toilets and shade available"]'),
    ('Electrical isolation and LOTO', 'inspection', '["Permit to work issued for the isolation","Circuit identified on drawings and labelled","Isolation point locked and tagged by each worker","Absence of voltage proved with a tested meter","Earthing applied where required","Stored energy (capacitors, springs) released","Insulated tools and arc-rated PPE in use","Barriers and warning signs at the work area","Re-energisation procedure agreed and communicated"]'),
    ('Work at height and scaffolding', 'inspection', '["Scaffold erected by a competent person and tagged","Base plates and sole boards on firm ground","Guardrails, mid-rails and toe boards fitted","Platforms fully boarded","Safe access by ladder or stair","Harness and lanyard inspected and anchored","Rescue plan in place","Tools tethered and exclusion zone below"]'),
    ('Vehicle and plant pre-use check', 'pre_use', '["Tyres and wheels","Brakes and handbrake","Lights, indicators and reverse alarm","Mirrors and windscreen","Seat belt","Fluid leaks (oil, fuel, hydraulic)","Fire extinguisher on board","Operator licence or certificate valid"]'),
    ('Fire safety and emergency', 'inspection', '["Fire exits marked and unobstructed","Extinguishers serviced and in date","Fire alarm tested","Assembly point signposted","Emergency contacts displayed","Flammables stored correctly","Emergency drill held in the last 6 months"]'),
    ('Office HSE walk-through', 'inspection', '["Trip hazards and trailing cables","Workstations set up correctly","Electrical equipment tested (PAT)","First-aid kit and trained first-aider","Fire extinguishers and exits","Kitchen and toilets clean","Air conditioning and lighting adequate"]'),
    ('Toolbox talk record', 'toolbox', '["Topic explained to the team","Hazards of today''s work discussed","Controls and PPE agreed","Questions answered","Attendance recorded"]')
  ) as x(name, kind, items)
  where not exists (select 1 from hse_checklists c where c.company_id = cid);
  perform set_config('sika.seed', 'off', true);
end $$;

do $$ declare c record; begin
  for c in select id from companies loop perform seed_esg_factors(c.id); end loop;
end $$;

create or replace function public.company_seed_hse() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform seed_esg_factors(new.id);
  return null;
end $$;
create trigger companies_seed_hse after insert on public.companies for each row execute function public.company_seed_hse();


-- ---------------------------------------------------------------- 8b. Toolbox talks, inductions, drills and safety meetings
-- Inductions: company induction for every new member of staff, a site induction for each project, and visitors.
-- Each attendee's induction is valid for a set number of months (default 12). A company can turn on
-- "no induction, no work": time cannot then be booked to a project for someone without a valid site induction.
alter table public.companies add column if not exists induction_valid_months int not null default 12 check (induction_valid_months between 1 and 60);
alter table public.companies add column if not exists require_site_induction boolean not null default false;

create table public.hse_sessions (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  number text,
  kind text not null check (kind in ('toolbox','site_induction','company_induction','visitor_induction','emergency_drill','safety_meeting')),
  project_id uuid references public.projects(id) on delete set null,
  held_on date not null default current_date,
  start_time time,
  duration_min int check (duration_min between 1 and 1440),
  topic text not null,
  content text,
  location text,
  presenter_id uuid default auth.uid(),
  presenter_name text,
  outcome text,
  status text not null default 'draft' check (status in ('draft','recorded')),
  recorded_at timestamptz,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);
create index on public.hse_sessions (company_id, held_on desc);
create index on public.hse_sessions (project_id, kind);
create table public.hse_session_attendees (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  session_id uuid not null references public.hse_sessions(id) on delete cascade,
  employee_id uuid references public.employees(id) on delete set null,
  name text not null,
  organisation text,
  attended boolean not null default true,
  valid_until date,
  note text
);
create index on public.hse_session_attendees (session_id);
create index on public.hse_session_attendees (employee_id);

create or replace function public.hse_session_defaults() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    if not is_member(new.company_id) then raise exception 'You do not have access to this company'; end if;
    if new.kind = 'site_induction' and new.project_id is null then raise exception 'Choose the project this site induction is for'; end if;
    if new.kind in ('site_induction','company_induction') and not (hse_or_pm(new.company_id, new.project_id) or has_role(new.company_id, array['hr'])) then
      raise exception 'Inductions are given by an HSE officer, HR or the project manager';
    end if;
    new.number := coalesce(new.number, next_number(new.company_id, (case new.kind when 'toolbox' then 'TBT' when 'emergency_drill' then 'DRL' when 'safety_meeting' then 'HSM' else 'IND' end),
      case new.kind when 'toolbox' then 'TBT-' when 'emergency_drill' then 'DRL-' when 'safety_meeting' then 'HSM-' else 'IND-' end));
    new.status := 'draft'; new.recorded_at := null;
    new.created_by := coalesce(new.created_by, auth.uid());
  elsif coalesce(current_setting('sika.hse', true), '') <> 'on' then
    if new.status is distinct from old.status then raise exception 'Use Record to finish the attendance list'; end if;
    if old.status = 'recorded' and not is_hse(old.company_id) then raise exception 'A recorded session can only be corrected by an HSE officer'; end if;
    if not (old.created_by = auth.uid() or old.presenter_id = auth.uid() or hse_or_pm(old.company_id, old.project_id)) then raise exception 'Only the presenter, the project manager or an HSE officer can change this'; end if;
    new.number := old.number; new.company_id := old.company_id; new.kind := old.kind;
  end if;
  return new;
end $$;
create trigger hse_sessions_defaults before insert or update on public.hse_sessions for each row execute function public.hse_session_defaults();

create or replace function public.hse_attendee_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare s hse_sessions;
begin
  select * into s from hse_sessions where id = coalesce(new.session_id, old.session_id);
  if coalesce(current_setting('sika.hse', true), '') <> 'on' then
    if s.status = 'recorded' and not is_hse(s.company_id) then raise exception 'This attendance list is recorded. An HSE officer can correct it.'; end if;
    if not (s.created_by = auth.uid() or s.presenter_id = auth.uid() or hse_or_pm(s.company_id, s.project_id)) then raise exception 'Only the presenter, the project manager or an HSE officer can change the attendance list'; end if;
  end if;
  if tg_op <> 'DELETE' then
    new.company_id := s.company_id;
    if new.employee_id is not null and coalesce(trim(new.name), '') = '' then new.name := (select full_name from employees where id = new.employee_id); end if;
  end if;
  return coalesce(new, old);
end $$;
create trigger hse_session_attendees_guard before insert or update or delete on public.hse_session_attendees for each row execute function public.hse_attendee_guard();

-- Record: locks the list and, for inductions, sets how long each attendee's induction is valid.
create or replace function public.record_hse_session(p_id uuid) returns int
language plpgsql security definer set search_path = public as $$
declare s hse_sessions; n int; v_months int;
begin
  select * into s from hse_sessions where id = p_id for update;
  if not found then raise exception 'Not found'; end if;
  if s.status = 'recorded' then raise exception 'Already recorded'; end if;
  if not (s.created_by = auth.uid() or s.presenter_id = auth.uid() or hse_or_pm(s.company_id, s.project_id)) then raise exception 'Only the presenter, the project manager or an HSE officer can record it'; end if;
  select count(*) into n from hse_session_attendees where session_id = p_id and attended;
  if n = 0 then raise exception 'Add the people who attended'; end if;
  select induction_valid_months into v_months from companies where id = s.company_id;
  perform set_config('sika.hse', 'on', true);
  if s.kind in ('site_induction','company_induction','visitor_induction') then
    update hse_session_attendees set valid_until = coalesce(valid_until, (s.held_on + make_interval(months => case when s.kind = 'visitor_induction' then 1 else v_months end))::date)
    where session_id = p_id and attended;
  end if;
  update hse_sessions set status = 'recorded', recorded_at = now() where id = p_id;
  perform set_config('sika.hse', 'off', true);
  return n;
end $$;

-- Is this employee inducted for the project (a valid site induction) — or for the company, when no project is given?
create or replace function public.is_inducted(p_employee uuid, p_project uuid default null, p_on date default current_date) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from hse_session_attendees a join hse_sessions s on s.id = a.session_id
    where a.employee_id = p_employee and a.attended and s.status = 'recorded' and a.valid_until >= p_on
      and ((p_project is not null and s.kind = 'site_induction' and s.project_id = p_project)
        or (p_project is null and s.kind = 'company_induction')));
$$;

-- Induction register: every employee with their company induction and, for each project they are on, their site induction.
create or replace function public.induction_register(cid uuid, p_project uuid default null)
returns table (employee_id uuid, full_name text, project_id uuid, kind text, held_on date, valid_until date, session_id uuid, state text)
language sql stable security definer set search_path = public as $$
  with people as (
    select e.id, e.full_name, null::uuid pid, 'company_induction'::text k from employees e
      where e.company_id = cid and is_member(cid) and p_project is null and coalesce(to_jsonb(e)->>'status', 'active') not in ('left','terminated','inactive')
    union
    select e.id, e.full_name, pa.project_id, 'site_induction' from project_assignments pa join employees e on e.id = pa.employee_id
      join projects p on p.id = pa.project_id
      where pa.company_id = cid and is_member(cid) and (p_project is null or pa.project_id = p_project) and p.status in ('planned','active','on_hold')
  ), last as (
    select distinct on (a.employee_id, s.kind, s.project_id) a.employee_id, s.kind, s.project_id, s.held_on, a.valid_until, s.id sid
    from hse_session_attendees a join hse_sessions s on s.id = a.session_id
    where s.company_id = cid and s.status = 'recorded' and a.attended and s.kind in ('company_induction','site_induction')
    order by a.employee_id, s.kind, s.project_id, a.valid_until desc nulls last
  )
  select pe.id, pe.full_name, pe.pid, pe.k, l.held_on, l.valid_until, l.sid,
    case when l.valid_until is null then 'missing' when l.valid_until < current_date then 'expired' when l.valid_until < current_date + 30 then 'expiring' else 'valid' end
  from people pe left join last l on l.employee_id = pe.id and l.kind = pe.k and l.project_id is not distinct from pe.pid
  order by pe.full_name, pe.pid nulls first;
$$;

-- "No induction, no work": time on a project needs a valid site induction when the company turns this on.
create or replace function public.timesheet_induction_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.employee_id is not null and new.project_id is not null
     and coalesce((select require_site_induction from companies where id = new.company_id), false)
     and not is_inducted(new.employee_id, new.project_id, new.work_date) then
    raise exception '% has no valid site induction for this project. Give the site induction first (HSE → Talks & inductions).',
      coalesce((select full_name from employees where id = new.employee_id), 'This person');
  end if;
  return new;
end $$;
create trigger timesheets_induction before insert on public.timesheets for each row execute function public.timesheet_induction_guard();

create or replace function public.set_induction_rules(cid uuid, p_required boolean, p_months int) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not (has_role(cid, array['owner','admin']) or is_hse(cid)) then raise exception 'Only an owner, admin or HSE officer can change induction rules'; end if;
  update companies set require_site_induction = p_required, induction_valid_months = coalesce(p_months, induction_valid_months) where id = cid;
end $$;

-- ---------------------------------------------------------------- 9. Performance figures
-- Hours worked = approved timesheet hours + hours recorded for site labour and subcontractors.
-- LTIFR = lost-time injuries × 1,000,000 / hours. TRIR = recordable injuries × 200,000 / hours.
create or replace function public.hse_stats(cid uuid, p_from date, p_to date, p_project uuid default null)
returns table (hours numeric, incidents int, observations int, near_misses int, first_aid int, recordables int, ltis int, fatalities int,
  lost_days int, ltifr numeric, trir numeric, open_actions int, overdue_actions int, inspections int, avg_score numeric,
  permits_active int, obligations_expired int, obligations_due int, toolbox_talks int, toolbox_attendance int, inductions int, drills int, days_since_lti int)
language plpgsql stable security definer set search_path = public as $$
declare h numeric;
begin
  perform require_member(cid);
  select coalesce((select sum(t.hours) from timesheets t where t.company_id = cid and t.work_date between p_from and p_to
           and coalesce(to_jsonb(t)->>'status', 'approved') = 'approved' and (p_project is null or t.project_id = p_project)), 0)
       + coalesce((select sum(x.hours) from hse_hours x where x.company_id = cid and x.period between date_trunc('month', p_from)::date and p_to
           and (p_project is null or x.project_id = p_project)), 0) into h;
  return query
  with i as (select * from hse_incidents x where x.company_id = cid and x.occurred_at::date between p_from and p_to and (p_project is null or x.project_id = p_project))
  select h,
    (select count(*)::int from i where i.kind <> 'observation'),
    (select count(*)::int from i where i.kind = 'observation'),
    (select count(*)::int from i where i.kind = 'near_miss'),
    (select count(*)::int from i where i.kind = 'first_aid'),
    (select count(*)::int from i where hse_recordable(i.kind)),
    (select count(*)::int from i where hse_lti(i.kind)),
    (select count(*)::int from i where i.kind = 'fatality'),
    (select coalesce(sum(i.lost_days), 0)::int from i),
    case when h > 0 then round((select count(*) from i where hse_lti(i.kind)) * 1000000.0 / h, 2) end,
    case when h > 0 then round((select count(*) from i where hse_recordable(i.kind)) * 200000.0 / h, 2) end,
    (select count(*)::int from hse_actions a where a.company_id = cid and a.status in ('open','done') and (p_project is null or a.project_id = p_project)),
    (select count(*)::int from hse_actions a where a.company_id = cid and a.status = 'open' and a.due_date < current_date and (p_project is null or a.project_id = p_project)),
    (select count(*)::int from hse_inspections s where s.company_id = cid and s.status = 'completed' and s.inspected_on between p_from and p_to and (p_project is null or s.project_id = p_project)),
    (select round(avg(s.score), 1) from hse_inspections s where s.company_id = cid and s.status = 'completed' and s.inspected_on between p_from and p_to and (p_project is null or s.project_id = p_project)),
    (select count(*)::int from hse_permits p where p.company_id = cid and p.status = 'approved' and now() between p.valid_from and p.valid_to and (p_project is null or p.project_id = p_project)),
    (select count(*)::int from compliance_obligations o where o.company_id = cid and o.status <> 'retired' and o.expires_on < current_date),
    (select count(*)::int from compliance_obligations o where o.company_id = cid and o.status <> 'retired' and o.expires_on between current_date and current_date + o.lead_days),
    (select count(*)::int from hse_sessions x where x.company_id = cid and x.kind = 'toolbox' and x.status = 'recorded' and x.held_on between p_from and p_to and (p_project is null or x.project_id = p_project)),
    (select count(*)::int from hse_session_attendees a join hse_sessions x on x.id = a.session_id where x.company_id = cid and x.kind = 'toolbox' and x.status = 'recorded' and a.attended and x.held_on between p_from and p_to and (p_project is null or x.project_id = p_project)),
    (select count(*)::int from hse_session_attendees a join hse_sessions x on x.id = a.session_id where x.company_id = cid and x.kind in ('site_induction','company_induction','visitor_induction') and x.status = 'recorded' and a.attended and x.held_on between p_from and p_to and (p_project is null or x.project_id = p_project)),
    (select count(*)::int from hse_sessions x where x.company_id = cid and x.kind = 'emergency_drill' and x.status = 'recorded' and x.held_on between p_from and p_to and (p_project is null or x.project_id = p_project)),
    (select (current_date - coalesce(max(x.occurred_at)::date,
        coalesce((select min(p.actual_start) from projects p where p.id = p_project), (select c.created_at::date from companies c where c.id = cid))))::int
       from hse_incidents x where x.company_id = cid and hse_lti(x.kind) and (p_project is null or x.project_id = p_project));
end $$;

-- Emissions and resources by category and scope (GHG Protocol; GRI 302, 303, 305, 306).
create or replace function public.esg_summary(cid uuid, p_from date, p_to date, p_project uuid default null)
returns table (category text, scope int, factor_key text, name text, unit text, quantity numeric, t_co2e numeric, waste_route text)
language sql stable security definer set search_path = public as $$
  select f.category, f.scope, f.key, f.name, f.unit, sum(e.quantity), round(sum(e.kg_co2e) / 1000.0, 3), f.waste_route
  from esg_entries e join esg_factors f on f.id = e.factor_id
  where e.company_id = cid and is_member(cid) and e.period between date_trunc('month', p_from)::date and p_to
    and (p_project is null or e.project_id = p_project)
  group by f.category, f.scope, f.key, f.name, f.unit, f.waste_route
  order by f.category, f.scope nulls last, f.name;
$$;

-- ---------------------------------------------------------------- 10. Reminders (daily)
create or replace function public.run_hse_reminders() returns int
language plpgsql security definer set search_path = public as $$
declare r record; n int := 0;
begin
  -- Actions past their due date: the owner, once a week.
  for r in select * from hse_actions where status = 'open' and due_date < current_date and owner_id is not null
             and (reminded_on is null or reminded_on <= current_date - 7) loop
    perform notify_users(r.company_id, array[r.owner_id], 'hse_action_overdue', r.number || ' is overdue', r.title || ' · was due ' || to_char(r.due_date, 'DD Mon YYYY'), '/hse/actions', true);
    update hse_actions set reminded_on = current_date where id = r.id; n := n + 1;
  end loop;
  -- Obligations: when they enter the reminder window, and again when they lapse.
  for r in select * from compliance_obligations where status <> 'retired' and expires_on is not null
             and expires_on <= current_date + lead_days and (reminded_for is null or (reminded_for < expires_on and current_date > expires_on) or reminded_for < current_date - 30) loop
    perform notify_users(r.company_id, array_remove(hse_users(r.company_id) || r.owner_id, null), 'compliance_due',
      case when r.expires_on < current_date then r.title || ' has expired' else r.title || ' is due ' || to_char(r.expires_on, 'DD Mon YYYY') end,
      coalesce(r.authority || ' · ', '') || coalesce(r.reference, ''), '/hse/obligations', true);
    update compliance_obligations set reminded_for = case when r.expires_on < current_date then current_date else r.expires_on end where id = r.id; n := n + 1;
  end loop;
  -- Permits still open after their end time.
  for r in select * from hse_permits where status in ('approved','suspended') and valid_to < now() and (reminded_on is null or reminded_on < current_date) loop
    perform notify_users(r.company_id, array_remove(array[r.requested_by, r.issued_by], null), 'hse_permit_expired',
      r.number || ' has run out: close it or raise a new permit', r.location, '/hse/permits', true);
    update hse_permits set reminded_on = current_date where id = r.id; n := n + 1;
  end loop;
  return n;
end $$;
revoke execute on function public.run_hse_reminders() from public, anon, authenticated;

-- Sent by the existing daily job (asnys-cash-reminders), with the cash and on-hold reminders.
create or replace function public.run_all_cash_reminders() returns int
language plpgsql security definer set search_path = public as $$
declare c record; n int := 0;
begin
  for c in select id from companies loop
    begin n := n + coalesce(run_cash_reminders_internal(c.id), 0); exception when others then null; end;
  end loop;
  begin n := n + coalesce(run_project_hold_reminders(), 0); exception when others then null; end;
  begin n := n + coalesce(run_hse_reminders(), 0); exception when others then null; end;
  return n;
end $$;
revoke execute on function public.run_all_cash_reminders() from public, anon, authenticated;

-- ---------------------------------------------------------------- 11. Security rules
do $$ declare t text; begin
  foreach t in array array['hse_incidents','hse_files','hse_actions','hse_checklists','hse_inspections','hse_permits','compliance_obligations',
                           'hse_policies','hse_policy_acks','esg_factors','esg_entries','hse_hours','hse_sessions','hse_session_attendees'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy "members read" on public.%I for select using (is_member(company_id))', t);
  end loop;
end $$;
-- Writes: anyone reports incidents, requests permits, starts inspections and adds files; the triggers above decide the rest.
create policy "members report" on public.hse_incidents for insert with check (is_member(company_id));
create policy "members update" on public.hse_incidents for update using (is_member(company_id));
create policy "hse deletes" on public.hse_incidents for delete using (is_hse(company_id) and status = 'reported');
create policy "members add files" on public.hse_files for insert with check (is_member(company_id));
create policy "hse removes files" on public.hse_files for delete using (is_hse(company_id) or uploaded_by = auth.uid());
create policy "raise actions" on public.hse_actions for insert with check (is_member(company_id));
create policy "edit actions" on public.hse_actions for update using (is_member(company_id));
create policy "hse checklists" on public.hse_checklists for all using (is_hse(company_id)) with check (is_hse(company_id));
create policy "start inspections" on public.hse_inspections for insert with check (is_member(company_id));
create policy "edit inspections" on public.hse_inspections for update using (is_member(company_id));
create policy "delete draft inspections" on public.hse_inspections for delete using (status = 'draft' and (inspector_id = auth.uid() or is_hse(company_id)));
create policy "request permits" on public.hse_permits for insert with check (is_member(company_id));
create policy "edit permits" on public.hse_permits for update using (is_member(company_id));
create policy "register obligations" on public.compliance_obligations for all using (is_member(company_id)) with check (is_member(company_id));
create policy "publish policies" on public.hse_policies for all using (is_member(company_id)) with check (is_member(company_id));
create policy "own acknowledgements" on public.hse_policy_acks for insert with check (user_id = auth.uid() and is_member(company_id));
create policy "edit factors" on public.esg_factors for all using (is_member(company_id)) with check (is_member(company_id));
create policy "record esg" on public.esg_entries for all using (is_member(company_id)) with check (is_member(company_id));
create policy "record sessions" on public.hse_sessions for insert with check (is_member(company_id));
create policy "edit sessions" on public.hse_sessions for update using (is_member(company_id));
create policy "delete draft sessions" on public.hse_sessions for delete using (status = 'draft' and (created_by = auth.uid() or is_hse(company_id)));
create policy "attendance" on public.hse_session_attendees for all using (is_member(company_id)) with check (is_member(company_id));
create policy "record hours" on public.hse_hours for all using (is_member(company_id)) with check (is_member(company_id));

-- Deleting sustainability records and hours: same people who can record them (the insert/update triggers do not run on delete).
create or replace function public.esg_delete_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not (is_hse(old.company_id) or has_role(old.company_id, array['accountant'])) then raise exception 'Only an HSE officer or Finance can delete these records'; end if;
  return old;
end $$;
create trigger esg_entries_delete before delete on public.esg_entries for each row execute function public.esg_delete_guard();
create trigger hse_hours_delete before delete on public.hse_hours for each row execute function public.esg_delete_guard();

-- Audit trail for the registers.
do $$ declare t text; begin
  foreach t in array array['hse_incidents','hse_actions','hse_permits','compliance_obligations','hse_policies','esg_factors','esg_entries','hse_sessions'] loop
    execute format('create trigger %I after insert or update or delete on public.%I for each row execute function public.audit_row()', t || '_audit', t);
  end loop;
end $$;

revoke execute on function public.seed_esg_factors(uuid) from public, anon, authenticated;
revoke execute on function public.hse_users(uuid) from public, anon, authenticated;
revoke execute on function public.notify_users(uuid,uuid[],text,text,text,text,boolean) from public, anon, authenticated;


-- ======================================================================
-- 0017_asnys_v3_0.sql
-- ======================================================================
-- Asnys ERP v3.0 — HR and payroll to the level of dedicated HR suites (PaySpace and similar)
--   1. Pay components: any number of earnings (taxable or not) and deductions per employee, recurring or one-off.
--   2. Salary history with effective dates, bulk increases, and automatic back pay (arrears) for backdated changes.
--   3. Joiners and leavers paid pro rata; off-cycle (interim and final) pay runs, with PAYE worked out on the month's total.
--   4. Employee self-service: own payslips, year-to-date tax summary, profile change requests approved by HR.
--   5. Employment details: manager (org chart), employment type, probation, contract end, next of kin; history of
--      promotions, transfers, salary changes, warnings and awards; employee documents with expiry.
--   6. Onboarding and exit checklists; exits with final pay, leave due, assets and loans to clear, access removed.
--   7. Leave: Ghana public holidays, working days counted without weekends and holidays, monthly accrual, carry-over,
--      approval by the employee's manager or HR.
--   8. Announcements to all staff, a department or a branch.
--   9. HR reports (headcount, joiners and leavers, turnover, payroll cost, leave liability) and the annual PAYE return.
-- Run after 0016.

-- ---------------------------------------------------------------- 0. Accounts and helpers
create or replace function public.seed_accounts_v30(cid uuid) returns void
language sql security definer set search_path = public as $$
  insert into accounts (company_id, code, name, type, system_key) values
  (cid, '2260', 'Other payroll deductions payable', 'liability', 'payroll_deductions')
  on conflict do nothing;
$$;
select public.seed_accounts_v30(id) from public.companies;

-- People who may see pay and personal records.
create or replace function public.is_hr(cid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select has_role(cid, array['owner','admin','hr']);
$$;

-- ---------------------------------------------------------------- 1. Employment details
alter table public.employees add column if not exists manager_id uuid references public.employees(id) on delete set null;
alter table public.employees add column if not exists employment_type text not null default 'permanent'
  check (employment_type in ('permanent','fixed_term','casual','contract','intern','national_service','consultant'));
alter table public.employees add column if not exists grade text;
alter table public.employees add column if not exists probation_end date;
alter table public.employees add column if not exists confirmed_on date;
alter table public.employees add column if not exists contract_end date;
alter table public.employees add column if not exists notice_days int;
alter table public.employees add column if not exists end_date date;
alter table public.employees add column if not exists date_of_birth date;
alter table public.employees add column if not exists gender text check (gender in ('female','male','other'));
alter table public.employees add column if not exists address text;
alter table public.employees add column if not exists next_of_kin_name text;
alter table public.employees add column if not exists next_of_kin_relation text;
alter table public.employees add column if not exists next_of_kin_phone text;
alter table public.employees add column if not exists emergency_phone text;

create table public.employee_events (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  employee_id uuid not null references public.employees(id) on delete cascade,
  kind text not null check (kind in ('hired','confirmation','promotion','transfer','title_change','salary_change','warning','disciplinary',
    'grievance','award','training','exit','note')),
  effective_date date not null default current_date,
  title text not null,
  details text,
  old_value jsonb,
  new_value jsonb,
  confidential boolean not null default false,
  created_by uuid default auth.uid(),
  created_email text,
  created_at timestamptz not null default now()
);
create index on public.employee_events (employee_id, effective_date desc);

create or replace function public.employee_event_defaults() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.company_id := (select company_id from employees where id = new.employee_id);
  if coalesce(current_setting('sika.hr', true), '') <> 'on' and not is_hr(new.company_id) then raise exception 'Only HR can add to an employee''s history'; end if;
  new.created_email := (select email from auth.users where id = auth.uid());
  return new;
end $$;
create trigger employee_events_defaults before insert on public.employee_events for each row execute function public.employee_event_defaults();

-- Changes of title, department, branch, manager or type are written to the history automatically.
create or replace function public.employee_history_log() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_title text; v_kind text;
begin
  if tg_op = 'INSERT' then
    perform set_config('sika.hr', 'on', true);
    insert into employee_events (company_id, employee_id, kind, effective_date, title, new_value)
    values (new.company_id, new.id, 'hired', coalesce(new.hire_date, current_date), 'Joined as ' || coalesce(new.job_title, 'employee'),
      jsonb_build_object('job_title', new.job_title, 'department', new.department, 'basic_salary', new.basic_salary));
    perform set_config('sika.hr', 'off', true);
    return null;
  end if;
  if (new.job_title, new.department, new.branch_id, new.manager_id, new.employment_type, new.grade)
     is not distinct from (old.job_title, old.department, old.branch_id, old.manager_id, old.employment_type, old.grade) then return null; end if;
  v_kind := case when new.branch_id is distinct from old.branch_id or new.department is distinct from old.department then 'transfer'
                 when new.grade is distinct from old.grade or new.job_title is distinct from old.job_title then 'title_change' else 'note' end;
  v_title := concat_ws('; ',
    case when new.job_title is distinct from old.job_title then 'Title: ' || coalesce(old.job_title, '—') || ' → ' || coalesce(new.job_title, '—') end,
    case when new.grade is distinct from old.grade then 'Grade: ' || coalesce(old.grade, '—') || ' → ' || coalesce(new.grade, '—') end,
    case when new.department is distinct from old.department then 'Department: ' || coalesce(old.department, '—') || ' → ' || coalesce(new.department, '—') end,
    case when new.branch_id is distinct from old.branch_id then 'Branch changed' end,
    case when new.manager_id is distinct from old.manager_id then 'Reports to: ' || coalesce((select full_name from employees where id = new.manager_id), 'nobody') end,
    case when new.employment_type is distinct from old.employment_type then 'Type: ' || old.employment_type || ' → ' || new.employment_type end);
  perform set_config('sika.hr', 'on', true);
  insert into employee_events (company_id, employee_id, kind, title, old_value, new_value)
  values (new.company_id, new.id, v_kind, v_title,
    jsonb_build_object('job_title', old.job_title, 'department', old.department, 'grade', old.grade, 'manager_id', old.manager_id),
    jsonb_build_object('job_title', new.job_title, 'department', new.department, 'grade', new.grade, 'manager_id', new.manager_id));
  perform set_config('sika.hr', 'off', true);
  return null;
end $$;
create trigger employees_history after insert or update on public.employees for each row execute function public.employee_history_log();

-- Promotion: title, grade and pay together, with one history line.
create table public.employee_documents (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  employee_id uuid not null references public.employees(id) on delete cascade,
  kind text not null default 'other' check (kind in ('contract','offer_letter','id_card','certificate','cv','medical','warning_letter','appraisal','exit','other')),
  title text not null,
  storage_path text not null,
  file_name text,
  expires_on date,
  visible_to_employee boolean not null default true,
  uploaded_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);
create index on public.employee_documents (employee_id);

-- ---------------------------------------------------------------- 2. Pay components and salary history
create table public.pay_components (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  code text not null,
  name text not null,
  kind text not null check (kind in ('earning','deduction')),
  taxable boolean not null default true,       -- earnings only: counts towards PAYE
  account_id uuid references public.accounts(id),  -- deductions only: where the money is owed (default 2260)
  system boolean not null default false,
  active boolean not null default true,
  sort int not null default 100,
  unique (company_id, code)
);
create table public.employee_pay_items (           -- every month from start to end
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  employee_id uuid not null references public.employees(id) on delete cascade,
  component_id uuid not null references public.pay_components(id),
  amount numeric(14,2) not null check (amount > 0),
  start_period date not null default date_trunc('month', current_date)::date,
  end_period date,
  note text,
  created_at timestamptz not null default now()
);
create table public.payroll_input_items (          -- once, in one month (or in one off-cycle run)
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  period date not null,
  run_id uuid,
  employee_id uuid not null references public.employees(id) on delete cascade,
  component_id uuid not null references public.pay_components(id),
  amount numeric(14,2) not null check (amount > 0),
  note text,
  created_at timestamptz not null default now()
);
create table public.payslip_items (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  payslip_id uuid not null references public.payslips(id) on delete cascade,
  component_id uuid references public.pay_components(id),
  code text not null,
  name text not null,
  kind text not null check (kind in ('earning','deduction')),
  taxable boolean not null default true,
  amount numeric(14,2) not null
);
create index on public.payslip_items (payslip_id);
create table public.salary_changes (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  employee_id uuid not null references public.employees(id) on delete cascade,
  effective_date date not null,
  basic_salary numeric(14,2) not null check (basic_salary >= 0),
  allowances numeric(14,2) not null default 0 check (allowances >= 0),
  kind text not null default 'increase' check (kind in ('increase','promotion','adjustment','decrease','bulk')),
  reason text,
  arrears_run_id uuid,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);
create index on public.salary_changes (employee_id, effective_date);

alter table public.payslips add column if not exists earnings_other numeric(14,2) not null default 0;
alter table public.payslips add column if not exists nontaxable numeric(14,2) not null default 0;
alter table public.payslips add column if not exists deductions_other numeric(14,2) not null default 0;
alter table public.payslips add column if not exists backpay numeric(14,2) not null default 0;
alter table public.payslips add column if not exists days_paid numeric(5,2);
alter table public.payslips add column if not exists days_in_month int;

alter table public.payroll_runs add column if not exists kind text not null default 'regular' check (kind in ('regular','interim','final'));
alter table public.payroll_runs add column if not exists note text;
alter table public.payroll_runs drop constraint if exists payroll_runs_company_id_period_key;
create unique index if not exists payroll_runs_one_regular on public.payroll_runs (company_id, period) where kind = 'regular';

create or replace function public.seed_pay_components(cid uuid) returns void
language sql security definer set search_path = public as $$
  insert into pay_components (company_id, code, name, kind, taxable, system, sort) values
    (cid, 'HOUSING', 'Housing allowance', 'earning', true, false, 10),
    (cid, 'TRANSPORT', 'Transport allowance', 'earning', true, false, 11),
    (cid, 'FUEL', 'Fuel allowance', 'earning', true, false, 12),
    (cid, 'RESPONSIBILITY', 'Responsibility allowance', 'earning', true, false, 13),
    (cid, 'SITE', 'Site / risk allowance', 'earning', true, false, 14),
    (cid, 'ACTING', 'Acting allowance', 'earning', true, false, 15),
    (cid, 'COMMISSION', 'Commission', 'earning', true, false, 20),
    (cid, 'LEAVEPAY', 'Leave pay (days not taken)', 'earning', true, false, 21),
    (cid, 'PRORATA', 'Salary for part month', 'earning', true, false, 22),
    (cid, 'BONUS', 'Bonus', 'earning', true, true, 30),
    (cid, 'BACKPAY', 'Back pay (arrears)', 'earning', true, true, 31),
    (cid, 'REIMBURSE', 'Reimbursement (not taxed)', 'earning', false, false, 40),
    (cid, 'UNION', 'Union dues', 'deduction', false, false, 60),
    (cid, 'WELFARE', 'Staff welfare', 'deduction', false, false, 61),
    (cid, 'CREDITUNION', 'Credit union savings', 'deduction', false, false, 62),
    (cid, 'COURT', 'Court order / garnishee', 'deduction', false, false, 63),
    (cid, 'OTHERDED', 'Other deduction', 'deduction', false, false, 69)
  on conflict (company_id, code) do nothing;
$$;
select public.seed_pay_components(id) from public.companies;

create or replace function public.pay_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare cid uuid; v_period date;
begin
  cid := coalesce(new.company_id, old.company_id);
  if tg_op <> 'DELETE' and tg_table_name in ('payroll_input_items','employee_pay_items') then
    cid := (select company_id from employees where id = new.employee_id);
  end if;
  if coalesce(current_setting('sika.hr', true), '') = 'on' then return coalesce(new, old); end if;
  if not has_role(cid, array['owner','admin','hr','accountant']) then raise exception 'Only HR or Finance can change pay'; end if;
  if tg_table_name = 'payroll_input_items' then
    v_period := coalesce(new.period, old.period);
    if coalesce(new.run_id, old.run_id) is not null then
      if exists (select 1 from payroll_runs where id = coalesce(new.run_id, old.run_id) and status <> 'draft') then raise exception 'That pay run is already posted'; end if;
    elsif exists (select 1 from payroll_runs where company_id = cid and period = date_trunc('month', v_period) and kind = 'regular' and status <> 'draft') then
      raise exception 'Payroll for % is already posted. Add it to next month or to an off-cycle run.', to_char(v_period, 'Mon YYYY');
    end if;
    if tg_op <> 'DELETE' then new.period := date_trunc('month', new.period)::date; end if;
  elsif tg_table_name = 'employee_pay_items' and tg_op <> 'DELETE' then
    new.start_period := date_trunc('month', new.start_period)::date;
    if new.end_period is not null then new.end_period := date_trunc('month', new.end_period)::date; end if;
  end if;
  if tg_op <> 'DELETE' and tg_table_name in ('payroll_input_items','employee_pay_items') then
    new.company_id := (select company_id from employees where id = new.employee_id);
    if (select company_id from pay_components where id = new.component_id) is distinct from new.company_id then raise exception 'Choose one of your own pay components'; end if;
  end if;
  return coalesce(new, old);
end $$;
create trigger pay_components_guard before insert or update or delete on public.pay_components for each row execute function public.pay_guard();
create trigger employee_pay_items_guard before insert or update or delete on public.employee_pay_items for each row execute function public.pay_guard();
create trigger payroll_input_items_guard before insert or update or delete on public.payroll_input_items for each row execute function public.pay_guard();

-- Pay in force on a date: the latest salary change on or before it, otherwise the employee record.
create or replace function public.emp_pay_at(p_employee uuid, p_date date, out basic numeric, out allowances numeric)
language sql stable security definer set search_path = public as $$
  select coalesce(sc.basic_salary, e.basic_salary), coalesce(sc.allowances, e.allowances)
  from employees e left join lateral (select basic_salary, allowances from salary_changes s where s.employee_id = e.id and s.effective_date <= p_date
    order by s.effective_date desc, s.created_at desc limit 1) sc on true
  where e.id = p_employee;
$$;

-- Change pay from a date. Backdated changes are paid as back pay in the next regular payroll.
create or replace function public.change_salary(p_employee uuid, p_effective date, p_basic numeric, p_allowances numeric default null,
  p_reason text default null, p_kind text default 'increase', p_title text default null, p_grade text default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare e employees; v uuid; v_allow numeric;
begin
  select * into e from employees where id = p_employee for update;
  if not found then raise exception 'Employee not found'; end if;
  if not is_hr(e.company_id) then raise exception 'Only HR, an owner or admin can change pay'; end if;
  if p_basic is null or p_basic < 0 then raise exception 'Enter the new basic salary'; end if;
  v_allow := coalesce(p_allowances, (emp_pay_at(e.id, p_effective)).allowances, e.allowances);
  insert into salary_changes (company_id, employee_id, effective_date, basic_salary, allowances, kind, reason)
  values (e.company_id, e.id, p_effective, round(p_basic, 2), round(v_allow, 2), p_kind, p_reason) returning id into v;
  if p_effective <= current_date then
    update employees set basic_salary = round(p_basic, 2), allowances = round(v_allow, 2),
      job_title = coalesce(p_title, job_title), grade = coalesce(p_grade, grade) where id = e.id;
  elsif p_title is not null or p_grade is not null then
    update employees set job_title = coalesce(p_title, job_title), grade = coalesce(p_grade, grade) where id = e.id;
  end if;
  perform set_config('sika.hr', 'on', true);
  insert into employee_events (company_id, employee_id, kind, effective_date, title, details, old_value, new_value, confidential)
  values (e.company_id, e.id, case when p_kind = 'promotion' then 'promotion' else 'salary_change' end, p_effective,
    case when p_kind = 'promotion' then 'Promoted' || coalesce(' to ' || p_title, '') else 'Pay changed' end,
    p_reason, jsonb_build_object('basic_salary', e.basic_salary, 'allowances', e.allowances, 'job_title', e.job_title),
    jsonb_build_object('basic_salary', round(p_basic, 2), 'allowances', round(v_allow, 2), 'job_title', coalesce(p_title, e.job_title)), true);
  perform set_config('sika.hr', 'off', true);
  return v;
end $$;

-- Raise many people at once: by a percentage and/or a fixed amount, optionally for one department.
create or replace function public.bulk_salary_change(cid uuid, p_effective date, p_percent numeric, p_amount numeric default 0,
  p_department text default null, p_reason text default null) returns int
language plpgsql security definer set search_path = public as $$
declare e record; n int := 0; cur record;
begin
  if not is_hr(cid) then raise exception 'Only HR, an owner or admin can change pay'; end if;
  if coalesce(p_percent, 0) = 0 and coalesce(p_amount, 0) = 0 then raise exception 'Enter a percentage or an amount'; end if;
  for e in select * from employees where company_id = cid and status = 'active' and (p_department is null or department = p_department) loop
    select * into cur from emp_pay_at(e.id, p_effective);
    perform change_salary(e.id, p_effective, round(cur.basic * (1 + coalesce(p_percent, 0) / 100.0) + coalesce(p_amount, 0), 2), cur.allowances,
      coalesce(p_reason, 'General increase'), 'bulk');
    n := n + 1;
  end loop;
  return n;
end $$;

-- ---------------------------------------------------------------- 3. Payroll calculation (regular and off-cycle runs)
create or replace function public.calc_run(p_run uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  r payroll_runs; cid uuid; v_period date; v_payday date; v_dim int; e record; pay record;
  v_days numeric; v_f numeric; v_basic numeric; v_allow numeric; v_ot numeric; v_bonus numeric;
  v_earn numeric; v_earn_tax numeric; v_earn_nontax numeric; v_ded numeric; v_back numeric; v_back_basic numeric;
  v_gross numeric; v_emp numeric; v_er numeric; v_t2 numeric; v_t3e numeric; v_t3r numeric; v_ot_tax numeric; v_ot_taxable numeric; v_ot_low numeric;
  v_ytd numeric; v_cap_left numeric; v_b_conc numeric; v_bonus_tax numeric; v_bonus_taxable numeric;
  v_relief_cap numeric; v_t3_relief numeric; v_t3_excess numeric; v_charge numeric; v_paye numeric; v_prior_charge numeric; v_prior_paye numeric;
  v_before numeric; v_loan numeric; v_net numeric; v_slip uuid; it record; v_start date; v_end date;
begin
  select * into r from payroll_runs where id = p_run;
  cid := r.company_id; v_period := r.period;
  v_payday := (v_period + interval '1 month - 1 day')::date;
  v_dim := extract(day from v_payday)::int;
  delete from payslips where run_id = p_run;

  for e in
    select * from employees x where x.company_id = cid and (
      (r.kind = 'regular' and coalesce(x.hire_date, v_period) <= v_payday
         and (x.status = 'active' or (x.end_date is not null and x.end_date >= v_period)) and (x.end_date is null or x.end_date >= v_period))
      or (r.kind <> 'regular' and exists (select 1 from payroll_input_items i where i.run_id = p_run and i.employee_id = x.id)))
    order by x.full_name
  loop
    -- Days paid: joiners and leavers in the month are paid pro rata to calendar days.
    v_start := greatest(v_period, coalesce(e.hire_date, v_period)); v_end := least(v_payday, coalesce(e.end_date, v_payday));
    v_days := case when r.kind = 'regular' then greatest(0, v_end - v_start + 1) else 0 end;
    v_f := case when r.kind = 'regular' then v_days / v_dim else 0 end;
    select * into pay from emp_pay_at(e.id, v_payday);
    v_basic := round(pay.basic * v_f, 2); v_allow := round(pay.allowances * v_f, 2);

    insert into payslips (run_id, company_id, employee_id, basic, allowances, gross, ssnit_employee, chargeable, paye, net, ssnit_employer, tier1, tier2,
      days_paid, days_in_month)
    values (p_run, cid, e.id, v_basic, v_allow, 0, 0, 0, 0, 0, 0, 0, 0, case when r.kind = 'regular' then v_days end, case when r.kind = 'regular' then v_dim end)
    returning id into v_slip;

    -- Recurring items (pro rata) and one-off items.
    if r.kind = 'regular' then
      insert into payslip_items (company_id, payslip_id, component_id, code, name, kind, taxable, amount)
      select cid, v_slip, c.id, c.code, c.name, c.kind, c.taxable, round(sum(p.amount) * case when c.kind = 'earning' then v_f else 1 end, 2)
      from employee_pay_items p join pay_components c on c.id = p.component_id
      where p.employee_id = e.id and p.start_period <= v_period and (p.end_period is null or p.end_period >= v_period) and c.active
      group by c.id, c.code, c.name, c.kind, c.taxable having sum(p.amount) > 0;
      insert into payslip_items (company_id, payslip_id, component_id, code, name, kind, taxable, amount)
      select cid, v_slip, c.id, c.code, c.name, c.kind, c.taxable, sum(i.amount)
      from payroll_input_items i join pay_components c on c.id = i.component_id
      where i.employee_id = e.id and i.period = v_period and i.run_id is null group by c.id, c.code, c.name, c.kind, c.taxable;
    else
      insert into payslip_items (company_id, payslip_id, component_id, code, name, kind, taxable, amount)
      select cid, v_slip, c.id, c.code, c.name, c.kind, c.taxable, sum(i.amount)
      from payroll_input_items i join pay_components c on c.id = i.component_id
      where i.employee_id = e.id and i.run_id = p_run group by c.id, c.code, c.name, c.kind, c.taxable;
    end if;
    delete from payslip_items where payslip_id = v_slip and amount <= 0;

    -- Back pay: the difference between the pay now in force for each month already posted and what was paid.
    v_back := 0; v_back_basic := 0;
    if r.kind = 'regular' and exists (select 1 from salary_changes sc where sc.employee_id = e.id and sc.arrears_run_id is null and sc.effective_date < v_period) then
      select coalesce(sum(greatest(0, round((emp_pay_at(e.id, (pr.period + interval '1 month - 1 day')::date)).basic * coalesce(ps.days_paid, 1) / coalesce(ps.days_in_month, 1), 2) - ps.basic)), 0),
             coalesce(sum(greatest(0, round((emp_pay_at(e.id, (pr.period + interval '1 month - 1 day')::date)).allowances * coalesce(ps.days_paid, 1) / coalesce(ps.days_in_month, 1), 2) - ps.allowances)), 0)
        into v_back_basic, v_back
      from payslips ps join payroll_runs pr on pr.id = ps.run_id
      where ps.employee_id = e.id and pr.kind = 'regular' and pr.status <> 'draft' and pr.period < v_period
        and pr.period >= (select date_trunc('month', min(sc.effective_date)) from salary_changes sc where sc.employee_id = e.id and sc.arrears_run_id is null);
      v_back := v_back + v_back_basic;
      if v_back > 0 then
        insert into payslip_items (company_id, payslip_id, component_id, code, name, kind, taxable, amount)
        select cid, v_slip, c.id, 'BACKPAY', c.name, 'earning', true, v_back from pay_components c where c.company_id = cid and c.code = 'BACKPAY';
      end if;
    end if;

    select coalesce(max(overtime), 0), coalesce(max(bonus), 0) into v_ot, v_bonus
      from payroll_inputs where company_id = cid and period = v_period and employee_id = e.id and r.kind = 'regular';
    v_bonus := v_bonus + coalesce((select sum(amount) from payslip_items where payslip_id = v_slip and code = 'BONUS'), 0);
    select coalesce(sum(amount) filter (where kind = 'earning' and code not in ('BONUS','BACKPAY')), 0),
           coalesce(sum(amount) filter (where kind = 'earning' and taxable and code not in ('BONUS','BACKPAY')), 0),
           coalesce(sum(amount) filter (where kind = 'earning' and not taxable), 0),
           coalesce(sum(amount) filter (where kind = 'deduction'), 0)
      into v_earn, v_earn_tax, v_earn_nontax, v_ded from payslip_items where payslip_id = v_slip;

    v_gross := v_basic + v_allow + v_ot + v_bonus + v_earn + v_back;
    -- SSNIT is on basic salary (including basic arrears).
    v_emp := round((v_basic + v_back_basic) * stat_rate('SSNIT_EMPLOYEE', v_payday), 2);
    v_er := round((v_basic + v_back_basic) * stat_rate('SSNIT_EMPLOYER', v_payday), 2);
    v_t2 := round((v_basic + v_back_basic) * stat_rate('TIER2', v_payday), 2);
    v_t3e := round(v_basic * e.tier3_employee_rate, 2);
    v_t3r := round(v_basic * e.tier3_employer_rate, 2);

    if v_ot > 0 and e.is_junior and (pay.basic + pay.allowances) * 12 <= stat_rate('OVERTIME_INCOME_LIMIT', v_payday) then
      v_ot_low := least(v_ot, 0.5 * pay.basic);
      v_ot_tax := round(v_ot_low * stat_rate('OVERTIME_LOW', v_payday) + (v_ot - v_ot_low) * stat_rate('OVERTIME_HIGH', v_payday), 2);
      v_ot_taxable := 0;
    else v_ot_tax := 0; v_ot_taxable := v_ot; end if;

    select coalesce(sum(s.bonus), 0) into v_ytd from payslips s join payroll_runs pr on pr.id = s.run_id
     where pr.company_id = cid and s.employee_id = e.id and pr.id <> p_run and extract(year from pr.period) = extract(year from v_period);
    v_cap_left := greatest(0, stat_rate('BONUS_CAP', v_payday) * pay.basic * 12 - v_ytd);
    v_b_conc := least(v_bonus, v_cap_left);
    v_bonus_tax := round(v_b_conc * stat_rate('BONUS_RATE', v_payday), 2);
    v_bonus_taxable := v_bonus - v_b_conc;

    v_relief_cap := round(stat_rate('TIER3_RELIEF', v_payday) * (v_basic + v_allow + v_earn_tax), 2);
    v_t3_relief := least(v_t3e, greatest(0, v_relief_cap - v_t3r));
    v_t3_excess := greatest(0, v_t3r - v_relief_cap);

    v_charge := v_basic + v_allow + v_earn_tax + v_back + v_ot_taxable + v_bonus_taxable + v_t3_excess - v_emp - v_t3_relief;
    -- PAYE is on the month's total: other posted runs this month are counted, and the tax already taken is deducted.
    select coalesce(sum(s.chargeable), 0), coalesce(sum(s.paye), 0) into v_prior_charge, v_prior_paye
      from payslips s join payroll_runs pr on pr.id = s.run_id
     where s.employee_id = e.id and pr.company_id = cid and pr.period = v_period and pr.id <> p_run and pr.status <> 'draft';
    v_paye := greatest(0, compute_paye(greatest(0, v_prior_charge + v_charge), v_payday) - v_prior_paye);

    v_before := v_gross - v_emp - v_t3e - v_paye - v_ot_tax - v_bonus_tax - v_ded;
    select coalesce(sum(least(installment, balance)), 0) into v_loan from employee_loans
     where employee_id = e.id and status = 'active' and issue_date <= v_payday and r.kind <> 'interim';
    v_loan := least(greatest(v_before, 0), v_loan);
    v_net := v_before - v_loan;

    update payslips set gross = v_gross, ssnit_employee = v_emp, chargeable = v_charge, paye = v_paye, net = v_net, ssnit_employer = v_er,
      tier1 = v_emp + v_er - v_t2, tier2 = v_t2, overtime = v_ot, bonus = v_bonus, overtime_tax = v_ot_tax, bonus_tax = v_bonus_tax,
      tier3_employee = v_t3e, tier3_employer = v_t3r, loan_deduction = v_loan,
      earnings_other = v_earn, nontaxable = v_earn_nontax, deductions_other = v_ded, backpay = v_back
    where id = v_slip;
  end loop;

  update payroll_runs x set gross = coalesce(s.gross, 0), paye = coalesce(s.tax, 0), ssnit_employee = coalesce(s.emp, 0),
    ssnit_employer = coalesce(s.er, 0), net = coalesce(s.net, 0)
  from (select sum(gross) gross, sum(paye + overtime_tax + bonus_tax) tax, sum(ssnit_employee) emp, sum(ssnit_employer) er, sum(net) net
          from payslips where run_id = p_run) s
  where x.id = p_run;
end $$;
revoke execute on function public.calc_run(uuid) from public, anon, authenticated;

create or replace function public.prepare_payroll(cid uuid, p_period date)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_run uuid; v_period date := date_trunc('month', p_period)::date; v_status text;
begin
  perform require_member(cid, array['owner','admin','hr','accountant']);
  select id, status into v_run, v_status from payroll_runs where company_id = cid and period = v_period and kind = 'regular';
  if v_run is not null and v_status <> 'draft' then raise exception 'Payroll for this month is already posted'; end if;
  if v_run is null then insert into payroll_runs (company_id, period, kind) values (cid, v_period, 'regular') returning id into v_run; end if;
  perform calc_run(v_run);
  return v_run;
end $$;

-- An off-cycle run (bonus, commission, final pay) holds only the items added to it.
create or replace function public.create_offcycle_run(cid uuid, p_period date, p_kind text, p_note text default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  perform require_member(cid, array['owner','admin','hr','accountant']);
  if p_kind not in ('interim','final') then raise exception 'Choose interim or final'; end if;
  insert into payroll_runs (company_id, period, kind, note) values (cid, date_trunc('month', p_period)::date, p_kind, p_note) returning id into v;
  return v;
end $$;
create or replace function public.recalc_run(p_run uuid) returns void
language plpgsql security definer set search_path = public as $$
declare r payroll_runs;
begin
  select * into r from payroll_runs where id = p_run;
  if not found then raise exception 'Pay run not found'; end if;
  perform require_member(r.company_id, array['owner','admin','hr','accountant']);
  if r.status <> 'draft' then raise exception 'This pay run is already posted'; end if;
  perform calc_run(p_run);
end $$;

-- Posting: as before, plus other deductions owed to their accounts, back pay settled, off-cycle labels.
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
  v_date := case when r.kind = 'regular' then (r.period + interval '1 month - 1 day')::date else least(current_date, (r.period + interval '1 month - 1 day')::date) end;
  for g in select e.branch_id, e.cost_centre_id, sum(ps.gross) gross, sum(ps.ssnit_employer) er, sum(ps.tier3_employer) t3
             from payslips ps join employees e on e.id = ps.employee_id where ps.run_id = p_run group by 1, 2 loop
    v_lines := v_lines
      || (jl(acct(r.company_id,'salaries'), g.gross, 0) || jsonb_build_object('branch_id', g.branch_id, 'cost_centre_id', g.cost_centre_id))
      || (jl(acct(r.company_id,'employer_ssnit'), g.er, 0) || jsonb_build_object('branch_id', g.branch_id, 'cost_centre_id', g.cost_centre_id))
      || (jl(acct(r.company_id,'employer_tier3'), g.t3, 0) || jsonb_build_object('branch_id', g.branch_id, 'cost_centre_id', g.cost_centre_id));
  end loop;
  for g in select coalesce(c.account_id, acct(r.company_id, 'payroll_deductions')) acc, sum(i.amount) amt
             from payslip_items i join payslips ps on ps.id = i.payslip_id left join pay_components c on c.id = i.component_id
            where ps.run_id = p_run and i.kind = 'deduction' group by 1 loop
    v_lines := v_lines || jsonb_build_array(jl(g.acc, 0, g.amt));
  end loop;
  v_je := post_journal(r.company_id, v_date, 'Payroll ' || to_char(r.period, 'Mon YYYY') || case r.kind when 'interim' then ' (off-cycle)' when 'final' then ' (final pay)' else '' end,
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
  if r.kind = 'regular' then
    update salary_changes sc set arrears_run_id = p_run
     where sc.arrears_run_id is null and sc.effective_date < r.period
       and sc.employee_id in (select employee_id from payslips where run_id = p_run);
  end if;
  update payroll_runs set status = 'posted', journal_entry_id = v_je where id = p_run;
end $$;

-- ---------------------------------------------------------------- 4. Self-service

-- Own payslips (posted runs only), with their items.
create or replace function public.my_payslips(p_year int default null, p_company uuid default null) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('slip', to_jsonb(s) - 'company_id', 'period', r.period, 'kind', r.kind, 'status', r.status,
      'company', jsonb_build_object('id', c.id, 'name', c.name, 'tin', c.tin, 'city', c.city, 'phone', c.phone, 'email', c.email),
      'employee', jsonb_build_object('full_name', e.full_name, 'staff_no', e.staff_no, 'job_title', e.job_title, 'department', e.department,
        'tin', e.tin, 'ssnit_no', e.ssnit_no, 'ghana_card', e.ghana_card, 'bank_name', e.bank_name, 'bank_account', e.bank_account),
      'items', coalesce((select jsonb_agg(jsonb_build_object('code', i.code, 'name', i.name, 'kind', i.kind, 'taxable', i.taxable, 'amount', i.amount) order by i.kind, i.name)
        from payslip_items i where i.payslip_id = s.id), '[]'::jsonb)) order by r.period desc, r.created_at desc), '[]'::jsonb)
  from payslips s join payroll_runs r on r.id = s.run_id join employees e on e.id = s.employee_id join companies c on c.id = r.company_id
  where e.user_id = auth.uid() and r.status in ('posted','paid') and (p_year is null or extract(year from r.period) = p_year) and (p_company is null or r.company_id = p_company);
$$;

-- Payslip items for HR and Finance (and the employee, through my_payslips).
create or replace function public.payslip_items_for_run(p_run uuid) returns setof payslip_items
language sql stable security definer set search_path = public as $$
  select i.* from payslip_items i join payslips s on s.id = i.payslip_id join payroll_runs r on r.id = s.run_id
  where s.run_id = p_run and has_role(r.company_id, array['owner','admin','hr','accountant']);
$$;

create table public.employee_change_requests (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  employee_id uuid not null references public.employees(id) on delete cascade,
  changes jsonb not null,
  note text,
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  decided_by uuid, decided_at timestamptz, decision_note text,
  created_at timestamptz not null default now()
);

-- Own record, documents shared with them, history (not confidential lines), manager.
create or replace function public.my_profile(p_company uuid default null) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'employee', to_jsonb(e) - 'basic_salary' - 'allowances' - 'cost_rate' - 'tier3_employee_rate' - 'tier3_employer_rate',
    'pay', jsonb_build_object('basic_salary', e.basic_salary, 'allowances', e.allowances),
    'manager', (select jsonb_build_object('full_name', m.full_name, 'job_title', m.job_title) from employees m where m.id = e.manager_id),
    'documents', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'title', d.title, 'kind', d.kind, 'storage_path', d.storage_path, 'expires_on', d.expires_on) order by d.created_at desc)
      from employee_documents d where d.employee_id = e.id and d.visible_to_employee), '[]'::jsonb),
    'history', coalesce((select jsonb_agg(jsonb_build_object('kind', h.kind, 'effective_date', h.effective_date, 'title', h.title) order by h.effective_date desc)
      from employee_events h where h.employee_id = e.id and not h.confidential), '[]'::jsonb),
    'requests', coalesce((select jsonb_agg(to_jsonb(q) order by q.created_at desc) from employee_change_requests q where q.employee_id = e.id), '[]'::jsonb))
  from employees e where e.user_id = auth.uid() and (p_company is null or e.company_id = p_company) order by e.created_at limit 1;
$$;


-- Staff ask to update their own contact, bank and next-of-kin details; HR approves.
create or replace function public.request_profile_change(p_changes jsonb, p_note text default null, p_company uuid default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare e employees; v uuid; k text; allowed text[] := array['phone','email','address','bank_name','bank_branch','bank_account','momo_number','pay_method',
  'next_of_kin_name','next_of_kin_relation','next_of_kin_phone','emergency_phone','tin','ssnit_no','ghana_card'];
begin
  select * into e from employees where user_id = auth.uid() and (p_company is null or company_id = p_company) order by created_at limit 1;
  if not found then raise exception 'Your login is not linked to an employee record. Ask HR.'; end if;
  for k in select jsonb_object_keys(p_changes) loop
    if not k = any(allowed) then raise exception 'You cannot change % yourself. Ask HR.', k; end if;
  end loop;
  insert into employee_change_requests (company_id, employee_id, changes, note) values (e.company_id, e.id, p_changes, p_note) returning id into v;
  perform notify(e.company_id, array['hr'], null, 'hr_profile_change', e.full_name || ' asked to update their details', null, '/employees', false);
  return v;
end $$;

create or replace function public.decide_profile_change(p_id uuid, p_approve boolean, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
declare q employee_change_requests; k text; v text;
begin
  select * into q from employee_change_requests where id = p_id for update;
  if not found then raise exception 'Not found'; end if;
  if not is_hr(q.company_id) then raise exception 'Only HR can approve this'; end if;
  if q.status <> 'pending' then raise exception 'Already decided'; end if;
  if p_approve then
    for k, v in select key, value from jsonb_each_text(q.changes) loop
      execute format('update public.employees set %I = $1 where id = $2', k) using nullif(v, ''), q.employee_id;
    end loop;
  end if;
  update employee_change_requests set status = case when p_approve then 'approved' else 'rejected' end, decided_by = auth.uid(), decided_at = now(), decision_note = p_note where id = p_id;
  perform notify_users(q.company_id, array[(select user_id from employees where id = q.employee_id)], 'hr_profile_decided',
    'Your details update was ' || case when p_approve then 'approved' else 'not approved' end, p_note, '/my/profile', false);
end $$;

-- Staff directory for everyone (no pay or personal data): names, titles, departments, managers, work contacts.
create or replace function public.staff_directory(cid uuid) returns table (id uuid, full_name text, job_title text, department text, branch text,
  manager_id uuid, email text, phone text, has_login boolean, location text)
language sql stable security definer set search_path = public as $$
  select e.id, e.full_name, e.job_title, e.department, b.name, e.manager_id, e.email, e.phone, e.user_id is not null, e.location
  from employees e left join branches b on b.id = e.branch_id
  where e.company_id = cid and e.status = 'active' and is_member(cid) order by e.full_name;
$$;

-- ---------------------------------------------------------------- 5. Onboarding and exit
create table public.hr_checklists (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  kind text not null check (kind in ('onboarding','offboarding')),
  name text not null,
  items jsonb not null default '[]'::jsonb,   -- [{"task":"…","owner":"hr|manager|it|finance|store|hse|employee","days":0}]
  active boolean not null default true
);
create table public.employee_tasks (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  employee_id uuid not null references public.employees(id) on delete cascade,
  kind text not null check (kind in ('onboarding','offboarding')),
  task text not null,
  owner text not null default 'hr',
  due_date date,
  status text not null default 'open' check (status in ('open','done','na')),
  done_by uuid, done_at timestamptz, note text,
  sort int not null default 0
);
create index on public.employee_tasks (employee_id, kind);

create or replace function public.seed_hr_checklists(cid uuid) returns void
language sql security definer set search_path = public as $$
  insert into hr_checklists (company_id, kind, name, items)
  select cid, x.kind, x.name, x.items::jsonb from (values
    ('onboarding', 'New employee', '[{"task":"Signed offer letter and employment contract on file","owner":"hr","days":-3},{"task":"Ghana Card, SSNIT number, TIN and bank or MoMo details recorded","owner":"hr","days":0},{"task":"Registered with SSNIT and the Tier 2 trustee","owner":"hr","days":7},{"task":"Login created and invitation sent","owner":"it","days":0},{"task":"Email address and phone line set up","owner":"it","days":0},{"task":"Laptop, tools and PPE issued (record in Assets)","owner":"store","days":0},{"task":"Company induction: policies, safety, emergency procedures","owner":"hse","days":1},{"task":"Policies read and acknowledged","owner":"employee","days":5},{"task":"Introduced to the team; job description explained","owner":"manager","days":1},{"task":"Objectives for probation agreed","owner":"manager","days":14},{"task":"Added to payroll from the start date","owner":"finance","days":0}]'),
    ('offboarding', 'Leaving employee', '[{"task":"Resignation or termination letter on file","owner":"hr","days":0},{"task":"Handover of work agreed with the manager","owner":"manager","days":0},{"task":"Laptop, tools, PPE, ID card and keys returned (check Assets)","owner":"store","days":0},{"task":"Cash advances retired and staff loans settled or deducted","owner":"finance","days":0},{"task":"Leave days due worked out and added to final pay","owner":"hr","days":0},{"task":"Final pay calculated and approved","owner":"finance","days":0},{"task":"Exit interview held","owner":"hr","days":0},{"task":"Email and system access removed","owner":"it","days":0},{"task":"Certificate of service issued","owner":"hr","days":7},{"task":"SSNIT and Tier 2 trustee informed","owner":"hr","days":14}]')
  ) as x(kind, name, items)
  where not exists (select 1 from hr_checklists h where h.company_id = cid);
$$;
select public.seed_hr_checklists(id) from public.companies;

create or replace function public.start_hr_checklist(p_employee uuid, p_kind text, p_checklist uuid default null, p_from date default null) returns int
language plpgsql security definer set search_path = public as $$
declare e employees; c hr_checklists; n int := 0; it jsonb; v_base date;
begin
  select * into e from employees where id = p_employee;
  if not is_hr(e.company_id) then raise exception 'Only HR can start a checklist'; end if;
  select * into c from hr_checklists where (id = p_checklist or (p_checklist is null and company_id = e.company_id and kind = p_kind and active)) order by name limit 1;
  if not found then raise exception 'Set up a % checklist first', p_kind; end if;
  v_base := coalesce(p_from, case when p_kind = 'onboarding' then e.hire_date else e.end_date end, current_date);
  for it in select value from jsonb_array_elements(c.items) loop
    n := n + 1;
    insert into employee_tasks (company_id, employee_id, kind, task, owner, due_date, sort)
    values (e.company_id, e.id, c.kind, it->>'task', coalesce(it->>'owner', 'hr'), v_base + coalesce((it->>'days')::int, 0), n);
  end loop;
  return n;
end $$;

create or replace function public.hr_task_step(p_id uuid, p_status text, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
declare t employee_tasks; v_mgr uuid;
begin
  select * into t from employee_tasks where id = p_id for update;
  select m.user_id into v_mgr from employees e join employees m on m.id = e.manager_id where e.id = t.employee_id;
  if not (is_hr(t.company_id) or (t.owner = 'finance' and has_role(t.company_id, array['accountant'])) or (t.owner = 'store' and has_role(t.company_id, array['store']))
          or (t.owner = 'hse' and is_hse(t.company_id)) or (t.owner = 'manager' and v_mgr = auth.uid())
          or (t.owner = 'employee' and exists (select 1 from employees where id = t.employee_id and user_id = auth.uid()))) then
    raise exception 'This task is for % to complete', t.owner;
  end if;
  if p_status not in ('open','done','na') then raise exception 'Unknown status'; end if;
  update employee_tasks set status = p_status, done_by = case when p_status = 'open' then null else auth.uid() end,
    done_at = case when p_status = 'open' then null else now() end, note = coalesce(p_note, note) where id = p_id;
end $$;

create table public.employee_exits (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  employee_id uuid not null references public.employees(id) on delete cascade,
  reason text not null check (reason in ('resignation','end_of_contract','dismissal','redundancy','retirement','death','mutual','other')),
  notice_date date not null default current_date,
  last_day date not null,
  eligible_rehire boolean,
  interview_notes text,
  leave_days_due numeric(6,2),
  status text not null default 'in_progress' check (status in ('in_progress','completed','cancelled')),
  completed_at timestamptz, completed_by uuid,
  created_at timestamptz not null default now()
);

create or replace function public.start_exit(p_employee uuid, p_reason text, p_notice date, p_last_day date, p_note text default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare e employees; v uuid; v_leave numeric;
begin
  select * into e from employees where id = p_employee for update;
  if not is_hr(e.company_id) then raise exception 'Only HR can start an exit'; end if;
  if exists (select 1 from employee_exits where employee_id = p_employee and status = 'in_progress') then raise exception 'An exit is already in progress'; end if;
  if p_last_day < p_notice then raise exception 'The last day cannot be before the notice date'; end if;
  select coalesce(sum(remaining), 0) into v_leave from leave_balances(e.company_id, extract(year from p_last_day)::int) b
   where b.employee_id = e.id and b.leave_code = 'annual';
  insert into employee_exits (company_id, employee_id, reason, notice_date, last_day, leave_days_due, interview_notes)
  values (e.company_id, e.id, p_reason, p_notice, p_last_day, greatest(v_leave, 0), p_note) returning id into v;
  update employees set end_date = p_last_day where id = e.id;
  perform start_hr_checklist(e.id, 'offboarding', null, p_last_day);
  perform set_config('sika.hr', 'on', true);
  insert into employee_events (company_id, employee_id, kind, effective_date, title, details)
  values (e.company_id, e.id, 'exit', p_last_day, 'Leaving: ' || replace(p_reason, '_', ' '), p_note);
  perform set_config('sika.hr', 'off', true);
  perform notify(e.company_id, array['hr','accountant','store'], null, 'hr_exit', e.full_name || ' is leaving on ' || to_char(p_last_day, 'DD Mon YYYY'),
    'Clear assets, advances and loans, and prepare final pay.', '/employees/' || e.id, false);
  return v;
end $$;

-- What must be cleared before someone leaves.
create or replace function public.exit_clearance(p_employee uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'assets', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'tag', a.tag, 'name', a.name)) from assets a where a.custodian_id = e.id and a.status = 'active'), '[]'::jsonb),
    'loans', coalesce((select sum(balance) from employee_loans where employee_id = e.id and status = 'active'), 0),
    'advances', coalesce((select sum(amount) from cash_advances where employee_id = e.id and status in ('open','submitted')), 0),
    'tasks_open', (select count(*) from employee_tasks where employee_id = e.id and kind = 'offboarding' and status = 'open'),
    'daily_rate', round(e.basic_salary / 22.0, 2))
  from employees e where e.id = p_employee and is_hr(e.company_id);
$$;

create or replace function public.complete_exit(p_exit uuid, p_force boolean default false) returns void
language plpgsql security definer set search_path = public as $$
declare x employee_exits; e employees; v_open int;
begin
  select * into x from employee_exits where id = p_exit for update;
  if not is_hr(x.company_id) then raise exception 'Only HR can complete an exit'; end if;
  if x.status <> 'in_progress' then raise exception 'This exit is not in progress'; end if;
  select count(*) into v_open from employee_tasks where employee_id = x.employee_id and kind = 'offboarding' and status = 'open';
  if v_open > 0 and not p_force then raise exception '% exit task% still open', v_open, case when v_open = 1 then ' is' else 's are' end; end if;
  select * into e from employees where id = x.employee_id for update;
  update employees set status = 'inactive', end_date = x.last_day where id = e.id;
  if e.user_id is not null then delete from memberships where company_id = e.company_id and user_id = e.user_id and role <> 'owner'; end if;
  update employee_exits set status = 'completed', completed_at = now(), completed_by = auth.uid() where id = p_exit;
end $$;

-- ---------------------------------------------------------------- 6. Leave: holidays, working days, accrual, manager approval
create table public.public_holidays (
  company_id uuid not null references public.companies(id) on delete cascade,
  holiday date not null,
  name text not null,
  primary key (company_id, holiday)
);
alter table public.leave_types add column if not exists accrual text not null default 'upfront' check (accrual in ('upfront','monthly'));
alter table public.leave_types add column if not exists carry_over_max numeric(5,1) not null default 0;
alter table public.leave_types add column if not exists counts text not null default 'working' check (counts in ('working','calendar'));
alter table public.leave_requests add column if not exists decided_by uuid;
alter table public.leave_requests add column if not exists decided_at timestamptz;
alter table public.leave_requests add column if not exists decision_note text;
alter table public.leave_requests add column if not exists half_day boolean not null default false;

-- Easter Sunday (Gregorian, anonymous algorithm).
create or replace function public.easter_sunday(y int) returns date language plpgsql immutable as $$
declare a int; b int; c int; d int; e int; f int; g int; h int; i int; k int; l int; m int;
begin
  a := y % 19; b := y / 100; c := y % 100; d := b / 4; e := b % 4; f := (b + 8) / 25; g := (b - f + 1) / 3;
  h := (19 * a + b - d - g + 15) % 30; i := c / 4; k := c % 4; l := (32 + 2 * e + 2 * i - h - k) % 7; m := (a + 11 * h + 22 * l) / 451;
  return make_date(y, (h + l - 7 * m + 114) / 31, ((h + l - 7 * m + 114) % 31) + 1);
end $$;

-- Ghana public holidays under the Public Holidays and Commemorative Days Act as amended in 2025. Eid al-Fitr, Shaqq Day
-- and Eid al-Adha follow the moon and are announced each year: add them when the dates are declared.
create or replace function public.seed_ghana_holidays_internal(cid uuid, y int) returns int
language plpgsql security definer set search_path = public as $$
declare n int; v_dec1 date := make_date(y, 12, 1);
begin
  insert into public_holidays (company_id, holiday, name) values
    (cid, make_date(y, 1, 1), 'New Year''s Day'), (cid, make_date(y, 1, 7), 'Constitution Day'), (cid, make_date(y, 3, 6), 'Independence Day'),
    (cid, easter_sunday(y) - 2, 'Good Friday'), (cid, easter_sunday(y) + 1, 'Easter Monday'), (cid, make_date(y, 5, 1), 'May Day (Workers'' Day)'),
    (cid, make_date(y, 7, 1), 'Republic Day'), (cid, make_date(y, 9, 21), 'Founder''s Day'),
    (cid, v_dec1 + ((5 - extract(dow from v_dec1)::int + 7) % 7), 'Farmers'' Day'),
    (cid, make_date(y, 12, 25), 'Christmas Day'), (cid, make_date(y, 12, 26), 'Boxing Day')
  on conflict do nothing;
  get diagnostics n = row_count;
  return n;
end $$;
revoke execute on function public.seed_ghana_holidays_internal(uuid, int) from public, anon, authenticated;
create or replace function public.seed_ghana_holidays(cid uuid, y int) returns int
language plpgsql security definer set search_path = public as $$
begin
  if not (is_hr(cid) or has_role(cid, array['accountant'])) then raise exception 'Only HR or Finance can set public holidays'; end if;
  return seed_ghana_holidays_internal(cid, y);
end $$;
do $$ declare c record; begin
  for c in select id from companies loop
    perform seed_ghana_holidays_internal(c.id, extract(year from current_date)::int);
    perform seed_ghana_holidays_internal(c.id, extract(year from current_date)::int + 1);
  end loop;
end $$;

create or replace function public.leave_days_between(cid uuid, p_start date, p_end date, p_counts text default 'working') returns numeric
language sql stable security definer set search_path = public as $$
  select count(*)::numeric from generate_series(p_start, p_end, interval '1 day') d
  where is_member(cid) and (p_counts = 'calendar' or (extract(isodow from d) < 6 and not exists (select 1 from public_holidays h where h.company_id = cid and h.holiday = d::date)));
$$;

create or replace function public.leave_request_defaults() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_counts text; v_mgr uuid; v_name text;
begin
  if tg_op = 'INSERT' or (new.start_date, new.end_date, new.half_day) is distinct from (old.start_date, old.end_date, old.half_day) then
    select counts into v_counts from leave_types where company_id = new.company_id and code = new.leave_type;
    new.days := case when new.half_day and new.start_date = new.end_date then 0.5 else leave_days_between(new.company_id, new.start_date, new.end_date, coalesce(v_counts, 'working')) end;
    if new.days <= 0 then raise exception 'Those dates are all weekends or public holidays'; end if;
  end if;
  if tg_op = 'INSERT' then
    select m.user_id, e.full_name into v_mgr, v_name from employees e left join employees m on m.id = e.manager_id where e.id = new.employee_id;
    perform notify(new.company_id, array['hr'], array[v_mgr], 'leave_request', v_name || ' asked for ' || new.days || ' day' || case when new.days = 1 then '' else 's' end || ' ' || replace(new.leave_type, '_', ' ') || ' leave',
      to_char(new.start_date, 'DD Mon') || ' to ' || to_char(new.end_date, 'DD Mon YYYY'), '/leave', false);
  end if;
  return new;
end $$;
create trigger leave_requests_defaults before insert or update on public.leave_requests for each row execute function public.leave_request_defaults();

-- HR or the employee's manager decides (never their own request).
create or replace function public.decide_leave(p_id uuid, p_approve boolean, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
declare q leave_requests; v_mgr uuid; v_self uuid; v_bal numeric;
begin
  select * into q from leave_requests where id = p_id for update;
  if not found then raise exception 'Leave request not found'; end if;
  select m.user_id, e.user_id into v_mgr, v_self from employees e left join employees m on m.id = e.manager_id where e.id = q.employee_id;
  if not (is_hr(q.company_id) or (v_mgr is not null and v_mgr = auth.uid())) then raise exception 'Only HR or the employee''s manager can decide'; end if;
  if v_self = auth.uid() then raise exception 'You cannot approve your own leave'; end if;
  if q.status <> 'pending' then raise exception 'Already decided'; end if;
  if p_approve then
    select remaining into v_bal from leave_balances(q.company_id, extract(year from q.start_date)::int) b where b.employee_id = q.employee_id and b.leave_code = q.leave_type;
    if v_bal is not null and v_bal < q.days and not is_hr(q.company_id) then raise exception 'Only % day(s) left. HR can approve beyond the balance.', v_bal; end if;
  end if;
  update leave_requests set status = case when p_approve then 'approved' else 'rejected' end, decided_by = auth.uid(), decided_at = now(), decision_note = p_note where id = p_id;
  perform notify_users(q.company_id, array[v_self], 'leave_decided', 'Your leave from ' || to_char(q.start_date, 'DD Mon') || ' was ' || case when p_approve then 'approved' else 'not approved' end, p_note, '/leave', false);
end $$;

-- Balances with pro rata for joiners, monthly accrual and carry-over from last year.
drop function if exists public.leave_balances(uuid, int);
create function public.leave_balances(cid uuid, p_year int)
returns table (employee_id uuid, full_name text, leave_code text, leave_name text, entitlement numeric, taken numeric, pending numeric, remaining numeric,
  carried numeric, accrued numeric)
language sql stable security definer set search_path = public as $$
  with base as (
    select e.id eid, e.full_name, t.code, t.name, t.accrual, t.carry_over_max,
      coalesce(en.days, t.days_per_year) full_days,
      -- months employed in the year (whole months from the hire month)
      case when e.hire_date is null or e.hire_date < make_date(p_year, 1, 1) then 12
           when extract(year from e.hire_date) > p_year then 0 else 13 - extract(month from e.hire_date) end::numeric months_in,
      case when p_year < extract(year from current_date) then 12 when p_year > extract(year from current_date) then 0 else extract(month from current_date) end::numeric months_to_date,
      coalesce(enp.days, t.days_per_year) prev_full,
      coalesce((select sum(days) from leave_requests r where r.employee_id = e.id and r.leave_type = t.code and r.status = 'approved' and extract(year from r.start_date) = p_year - 1), 0) prev_taken,
      coalesce((select sum(days) from leave_requests r where r.employee_id = e.id and r.leave_type = t.code and r.status = 'approved' and extract(year from r.start_date) = p_year), 0) taken,
      coalesce((select sum(days) from leave_requests r where r.employee_id = e.id and r.leave_type = t.code and r.status = 'pending' and extract(year from r.start_date) = p_year), 0) pending,
      e.hire_date
    from employees e cross join leave_types t
    left join leave_entitlements en on en.employee_id = e.id and en.leave_code = t.code and en.year = p_year
    left join leave_entitlements enp on enp.employee_id = e.id and enp.leave_code = t.code and enp.year = p_year - 1
    where e.company_id = cid and t.company_id = cid and e.status = 'active' and is_member(cid)
  ), calc as (
    select *, case when full_days is null then null else round(full_days * months_in / 12.0 * 2) / 2 end year_days,
      case when full_days is null or carry_over_max = 0 or (hire_date is not null and extract(year from hire_date) >= p_year) then 0
           else greatest(0, least(carry_over_max, prev_full - prev_taken)) end carried
    from base
  )
  select eid, full_name, code, name,
    case when year_days is null then null else year_days + carried end,
    taken, pending,
    case when year_days is null then null
         when accrual = 'monthly' then round(least(year_days, full_days * greatest(0, months_to_date - (12 - months_in)) / 12.0) * 2) / 2 + carried - taken
         else year_days + carried - taken end,
    carried,
    case when year_days is null then null when accrual = 'monthly' then round(least(year_days, full_days * greatest(0, months_to_date - (12 - months_in)) / 12.0) * 2) / 2 else year_days end
  from calc order by full_name, name;
$$;

-- ---------------------------------------------------------------- 7. Announcements
create table public.announcements (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  title text not null,
  body text not null,
  audience text not null default 'all' check (audience in ('all','department','branch')),
  audience_value text,
  pinned boolean not null default false,
  publish_on date not null default current_date,
  expires_on date,
  created_by uuid default auth.uid(),
  created_email text,
  created_at timestamptz not null default now()
);
create table public.announcement_reads (
  announcement_id uuid not null references public.announcements(id) on delete cascade,
  user_id uuid not null default auth.uid(),
  read_at timestamptz not null default now(),
  primary key (announcement_id, user_id)
);

create or replace function public.announcement_defaults() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_users uuid[];
begin
  if not is_hr(coalesce(new.company_id, old.company_id)) then raise exception 'Only HR, an owner or admin can post announcements'; end if;
  if tg_op = 'DELETE' then return old; end if;
  if tg_op = 'INSERT' then
    new.created_email := (select email from auth.users where id = auth.uid());
    select coalesce(array_agg(m.user_id), '{}') into v_users from memberships m
     where m.company_id = new.company_id and (new.audience = 'all' or exists (select 1 from employees e left join branches b on b.id = e.branch_id
       where e.user_id = m.user_id and e.company_id = new.company_id and ((new.audience = 'department' and e.department = new.audience_value) or (new.audience = 'branch' and (b.name = new.audience_value or b.code = new.audience_value)))));
    if new.publish_on <= current_date then
      perform notify_users(new.company_id, v_users, 'announcement', new.title, left(new.body, 160), '/', false);
    end if;
  end if;
  return new;
end $$;
create trigger announcements_defaults before insert or update or delete on public.announcements for each row execute function public.announcement_defaults();

create or replace function public.my_announcements(cid uuid) returns table (id uuid, title text, body text, pinned boolean, publish_on date, created_email text, read boolean, audience text, audience_value text)
language sql stable security definer set search_path = public as $$
  select a.id, a.title, a.body, a.pinned, a.publish_on, a.created_email, exists (select 1 from announcement_reads r where r.announcement_id = a.id and r.user_id = auth.uid()), a.audience, a.audience_value
  from announcements a
  where a.company_id = cid and is_member(cid) and a.publish_on <= current_date and (a.expires_on is null or a.expires_on >= current_date)
    and (a.audience = 'all' or is_hr(cid) or exists (select 1 from employees e left join branches b on b.id = e.branch_id where e.user_id = auth.uid() and e.company_id = cid
      and ((a.audience = 'department' and e.department = a.audience_value) or (a.audience = 'branch' and (b.name = a.audience_value or b.code = a.audience_value)))))
  order by a.pinned desc, a.publish_on desc, a.created_at desc limit 50;
$$;

-- ---------------------------------------------------------------- 8. Reports
create or replace function public.hr_report(cid uuid, p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v jsonb; v_start int; v_end int; v_leavers int;
begin
  if not has_role(cid, array['owner','admin','hr','accountant']) then raise exception 'Only HR and Finance can see HR reports'; end if;
  select count(*) into v_start from employees where company_id = cid and coalesce(hire_date, created_at::date) < p_from and (end_date is null or end_date >= p_from);
  select count(*) into v_end from employees where company_id = cid and coalesce(hire_date, created_at::date) <= p_to and (end_date is null or end_date > p_to) and (status = 'active' or end_date > p_to);
  select count(*) into v_leavers from employees where company_id = cid and end_date between p_from and p_to;
  v := jsonb_build_object(
    'headcount_start', v_start, 'headcount_end', v_end, 'leavers', v_leavers,
    'joiners', (select count(*) from employees where company_id = cid and hire_date between p_from and p_to),
    'turnover_pct', case when v_start + v_end > 0 then round(100.0 * v_leavers / ((v_start + v_end) / 2.0), 1) end,
    'by_department', coalesce((select jsonb_agg(jsonb_build_object('name', coalesce(department, 'Not set'), 'n', n, 'basic', basic) order by n desc)
      from (select department, count(*) n, sum(basic_salary) basic from employees where company_id = cid and status = 'active' group by department) x), '[]'::jsonb),
    'by_type', coalesce((select jsonb_agg(jsonb_build_object('name', employment_type, 'n', n)) from (select employment_type, count(*) n from employees where company_id = cid and status = 'active' group by 1) x), '[]'::jsonb),
    'by_gender', coalesce((select jsonb_agg(jsonb_build_object('name', coalesce(gender, 'not recorded'), 'n', n)) from (select gender, count(*) n from employees where company_id = cid and status = 'active' group by 1) x), '[]'::jsonb),
    'payroll_by_month', coalesce((select jsonb_agg(jsonb_build_object('period', period, 'gross', gross, 'employer', er, 'net', net, 'paye', paye, 'people', people) order by period)
      from (select r.period, sum(s.gross) gross, sum(s.ssnit_employer + s.tier3_employer) er, sum(s.net) net, sum(s.paye + s.overtime_tax + s.bonus_tax) paye, count(distinct s.employee_id) people
              from payroll_runs r join payslips s on s.run_id = r.id where r.company_id = cid and r.status <> 'draft' and r.period between date_trunc('month', p_from) and p_to group by r.period) x), '[]'::jsonb),
    'leave_liability', coalesce((select jsonb_build_object('days', sum(greatest(b.remaining, 0)), 'value', round(sum(greatest(b.remaining, 0) * e.basic_salary / 22.0), 2))
      from leave_balances(cid, extract(year from p_to)::int) b join employees e on e.id = b.employee_id where b.leave_code = 'annual'), '{}'::jsonb),
    'probation_ending', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'full_name', full_name, 'date', probation_end) order by probation_end)
      from employees where company_id = cid and status = 'active' and confirmed_on is null and probation_end between current_date - 30 and current_date + 60), '[]'::jsonb),
    'contracts_ending', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'full_name', full_name, 'date', contract_end, 'type', employment_type) order by contract_end)
      from employees where company_id = cid and status = 'active' and contract_end between current_date - 30 and current_date + 90), '[]'::jsonb),
    'documents_expiring', coalesce((select jsonb_agg(jsonb_build_object('employee', e.full_name, 'title', d.title, 'date', d.expires_on) order by d.expires_on)
      from employee_documents d join employees e on e.id = d.employee_id where d.company_id = cid and e.status = 'active' and d.expires_on between current_date - 30 and current_date + 60), '[]'::jsonb),
    'birthdays', coalesce((select jsonb_agg(jsonb_build_object('full_name', full_name, 'day', to_char(date_of_birth, 'DD Mon')) order by to_char(date_of_birth, 'MMDD'))
      from employees where company_id = cid and status = 'active' and date_of_birth is not null and extract(month from date_of_birth) = extract(month from current_date)), '[]'::jsonb));
  return v;
end $$;

-- Annual PAYE return: per employee for the year, from posted pay runs.
create or replace function public.paye_annual(cid uuid, p_year int)
returns table (employee_id uuid, full_name text, tin text, ghana_card text, ssnit_no text, months int, basic numeric, allowances numeric, other_earnings numeric,
  nontaxable numeric, overtime numeric, bonus numeric, gross numeric, ssnit_employee numeric, tier3_employee numeric, chargeable numeric, paye numeric,
  overtime_tax numeric, bonus_tax numeric, total_tax numeric)
language sql stable security definer set search_path = public as $$
  select e.id, e.full_name, e.tin, e.ghana_card, e.ssnit_no, count(distinct r.period)::int, sum(s.basic), sum(s.allowances), sum(s.earnings_other + s.backpay - s.nontaxable),
    sum(s.nontaxable), sum(s.overtime), sum(s.bonus), sum(s.gross), sum(s.ssnit_employee), sum(s.tier3_employee), sum(s.chargeable), sum(s.paye),
    sum(s.overtime_tax), sum(s.bonus_tax), sum(s.paye + s.overtime_tax + s.bonus_tax)
  from payslips s join payroll_runs r on r.id = s.run_id join employees e on e.id = s.employee_id
  where r.company_id = cid and r.status <> 'draft' and extract(year from r.period) = p_year and has_role(cid, array['owner','admin','hr','accountant'])
  group by e.id order by e.full_name;
$$;

-- ---------------------------------------------------------------- 9. Reminders (daily, with the existing job)
create or replace function public.run_hr_reminders() returns int
language plpgsql security definer set search_path = public as $$
declare r record; n int := 0;
begin
  -- Future-dated pay changes take effect on the employee record on their date.
  update employees e set basic_salary = sc.basic_salary, allowances = sc.allowances
  from (select distinct on (employee_id) employee_id, basic_salary, allowances from salary_changes where effective_date <= current_date
        order by employee_id, effective_date desc, created_at desc) sc
  where e.id = sc.employee_id and (e.basic_salary, e.allowances) is distinct from (sc.basic_salary, sc.allowances);
  for r in select e.*, m.user_id mgr from employees e left join employees m on m.id = e.manager_id
            where e.status = 'active' and e.confirmed_on is null and e.probation_end = current_date + 14 loop
    perform notify(r.company_id, array['hr'], array[r.mgr], 'hr_probation', 'Probation ends in 2 weeks: ' || r.full_name, 'Confirm, extend or end the appointment.', '/employees/' || r.id, true);
    n := n + 1;
  end loop;
  for r in select e.*, m.user_id mgr from employees e left join employees m on m.id = e.manager_id
            where e.status = 'active' and e.contract_end in (current_date + 30, current_date + 7) loop
    perform notify(r.company_id, array['hr'], array[r.mgr], 'hr_contract', 'Contract ends ' || to_char(r.contract_end, 'DD Mon YYYY') || ': ' || r.full_name, 'Renew or start the exit.', '/employees/' || r.id, true);
    n := n + 1;
  end loop;
  for r in select d.*, e.full_name from employee_documents d join employees e on e.id = d.employee_id where e.status = 'active' and d.expires_on = current_date + 30 loop
    perform notify(r.company_id, array['hr'], null, 'hr_document', r.title || ' for ' || r.full_name || ' expires in 30 days', null, '/employees/' || r.employee_id, true);
    n := n + 1;
  end loop;
  return n;
end $$;
revoke execute on function public.run_hr_reminders() from public, anon, authenticated;

create or replace function public.run_all_cash_reminders() returns int
language plpgsql security definer set search_path = public as $$
declare c record; n int := 0;
begin
  for c in select id from companies loop
    begin n := n + coalesce(run_cash_reminders_internal(c.id), 0); exception when others then null; end;
  end loop;
  begin n := n + coalesce(run_project_hold_reminders(), 0); exception when others then null; end;
  begin n := n + coalesce(run_hse_reminders(), 0); exception when others then null; end;
  begin n := n + coalesce(run_hr_reminders(), 0); exception when others then null; end;
  return n;
end $$;
revoke execute on function public.run_all_cash_reminders() from public, anon, authenticated;

-- ---------------------------------------------------------------- 10. New companies and HR policies
create or replace function public.company_seed_hr() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform set_config('sika.hr', 'on', true);
  perform seed_accounts_v30(new.id);
  perform seed_pay_components(new.id);
  perform seed_hr_checklists(new.id);
  perform seed_ghana_holidays_internal(new.id, extract(year from current_date)::int);
  perform seed_ghana_holidays_internal(new.id, extract(year from current_date)::int + 1);
  perform set_config('sika.hr', 'off', true);
  return null;
end $$;
create trigger companies_seed_hr after insert on public.companies for each row execute function public.company_seed_hr();

-- HR and admin policies share the policy register (HSE module); add the two areas.
alter table public.hse_policies drop constraint if exists hse_policies_area_check;
alter table public.hse_policies add constraint hse_policies_area_check
  check (area in ('safety','environment','quality','legal','tax_finance','labour','data_protection','anti_bribery','hr','admin','it','other'));

-- ---------------------------------------------------------------- 11. Security rules
do $$ declare t text; begin
  foreach t in array array['employee_events','employee_documents','pay_components','employee_pay_items','payroll_input_items','payslip_items','salary_changes',
                           'employee_change_requests','hr_checklists','employee_tasks','employee_exits','public_holidays','announcements'] loop
    execute format('alter table public.%I enable row level security', t);
  end loop;
end $$;
alter table public.announcement_reads enable row level security;
-- Pay and personal records: owners, admins and HR (Finance reads pay).
create policy "hr reads history" on public.employee_events for select using (is_hr(company_id));
create policy "hr writes history" on public.employee_events for insert with check (is_hr(company_id));
create policy "hr deletes history" on public.employee_events for delete using (is_hr(company_id) and kind in ('note','warning','disciplinary','grievance','award','training'));
create policy "hr documents" on public.employee_documents for all using (is_hr(company_id)) with check (is_hr(company_id));
create policy "pay readers" on public.pay_components for select using (is_member(company_id));
create policy "pay writers" on public.pay_components for all using (has_role(company_id, array['owner','admin','hr','accountant'])) with check (has_role(company_id, array['owner','admin','hr','accountant']));
create policy "pay items" on public.employee_pay_items for all using (has_role(company_id, array['owner','admin','hr','accountant'])) with check (has_role(company_id, array['owner','admin','hr','accountant']));
create policy "input items" on public.payroll_input_items for all using (has_role(company_id, array['owner','admin','hr','accountant'])) with check (has_role(company_id, array['owner','admin','hr','accountant']));
create policy "payslip items" on public.payslip_items for select using (has_role(company_id, array['owner','admin','hr','accountant']));
create policy "salary history" on public.salary_changes for select using (has_role(company_id, array['owner','admin','hr','accountant']));
create policy "change requests hr" on public.employee_change_requests for select using (is_hr(company_id));
create policy "checklists read" on public.hr_checklists for select using (is_member(company_id));
create policy "checklists write" on public.hr_checklists for all using (is_hr(company_id)) with check (is_hr(company_id));
create policy "tasks read" on public.employee_tasks for select using (has_role(company_id, array['owner','admin','hr','accountant','store']) or is_hse(company_id)
  or employee_id in (select my_employee_ids()) or exists (select 1 from employees e join employees m on m.id = e.manager_id where e.id = employee_id and m.user_id = auth.uid()));
create policy "tasks hr" on public.employee_tasks for all using (is_hr(company_id)) with check (is_hr(company_id));
create policy "exits hr" on public.employee_exits for all using (is_hr(company_id)) with check (is_hr(company_id));
create policy "exits finance" on public.employee_exits for select using (has_role(company_id, array['accountant']));
create policy "holidays read" on public.public_holidays for select using (is_member(company_id));
create policy "holidays write" on public.public_holidays for all using (is_hr(company_id) or has_role(company_id, array['accountant'])) with check (is_hr(company_id) or has_role(company_id, array['accountant']));
create policy "announcements hr" on public.announcements for all using (is_hr(company_id)) with check (is_hr(company_id));
create policy "own reads" on public.announcement_reads for all using (user_id = auth.uid()) with check (user_id = auth.uid());
-- Leave: staff see their own requests and their team's; HR sees all; decisions go through decide_leave.
drop policy if exists "members read leave" on public.leave_requests;
create policy "leave visible" on public.leave_requests for select using (is_hr(company_id) or employee_id in (select my_employee_ids())
  or exists (select 1 from employees e join employees m on m.id = e.manager_id where e.id = employee_id and m.user_id = auth.uid())
  or (has_role(company_id, array['project_manager','accountant']) and status = 'approved'));
drop policy if exists "members request leave" on public.leave_requests;
create policy "staff request own leave" on public.leave_requests for insert with check (status = 'pending' and (is_hr(company_id) or employee_id in (select my_employee_ids())));

do $$ declare t text; begin
  foreach t in array array['salary_changes','employee_events','employee_documents','pay_components','employee_pay_items','payroll_input_items','employee_exits','announcements','public_holidays'] loop
    execute format('create trigger %I after insert or update or delete on public.%I for each row execute function public.audit_row()', t || '_audit', t);
  end loop;
end $$;

revoke execute on function public.seed_accounts_v30(uuid) from public, anon, authenticated;
revoke execute on function public.seed_pay_components(uuid) from public, anon, authenticated;
revoke execute on function public.seed_hr_checklists(uuid) from public, anon, authenticated;

-- ================================================================ 0018_asnys_v3_1.sql
-- Asnys ERP v3.1 — Assets to match the Gulfaco asset system, and Fleet & Logistics
-- Assets
--   1. Locations register (head office, branches, sites, stores, regions) with a manager for each.
--   2. Manufacturer, model and order number on assets.
--   3. Transfers between locations: In transit until the receiving location confirms; reject or recall.
--   4. Requests routed through the site: the site manager approves, or passes it to head office.
--   5. Accessories, components and consumables: quantities per location, check out to people or into an asset,
--      low-stock alerts.
--   6. Software licences: seats, product key, assignment to people or computers, expiry reminders.
--   7. Telegram alerts (optional) for transfers, requests, decisions, low stock and fleet.
-- Fleet & Logistics
--   8. Vehicle file (registration, DVLA roadworthy, insurance, road-use documents with reminders), drivers and licences.
--   9. Trip log with mileage; fuel log with km per litre and unusual consumption flagged; fuel feeds the CO2 figures.
--  10. Service and repairs by mileage or date (job cards, downtime); vehicle requests allocated by the transport officer.
--  11. Waybills for deliveries and collections, own vehicle or hired transport, with signed proof of delivery.
--  12. Fleet reports: cost per vehicle and per km, fuel use, transport by project.
-- Transport officer is a tick on a team member (like HSE officer); owners, admins, Finance and the storekeeper count as one.
-- Run after 0017.

-- ---------------------------------------------------------------- 0. People who manage the fleet
alter table public.memberships add column if not exists transport boolean not null default false;
create or replace function public.is_transport(cid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from memberships where company_id = cid and user_id = auth.uid() and (transport or role in ('owner','admin','accountant','store')));
$$;
create or replace function public.transport_users(cid uuid) returns uuid[]
language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(user_id), '{}') from memberships where company_id = cid and (transport or role = 'store');
$$;
create or replace function public.set_member_transport(cid uuid, p_user uuid, p_on boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not has_role(cid, array['owner','admin']) then raise exception 'Only an owner or admin can choose transport officers'; end if;
  update memberships set transport = p_on where company_id = cid and user_id = p_user;
  if not found then raise exception 'That person is not in this company'; end if;
end $$;

-- ---------------------------------------------------------------- 1. Telegram alerts (optional)
-- Needs the pg_net extension (Supabase: Database → Extensions → pg_net). Without it, alerts are skipped quietly.
create table public.company_telegram (
  company_id uuid primary key references public.companies(id) on delete cascade,
  bot_token text,
  chat_id text,
  events text[] not null default '{transfer,request,decision,low_stock,fleet,signup}',
  enabled boolean not null default false,
  updated_at timestamptz not null default now()
);
create or replace function public.send_telegram(cid uuid, p_event text, p_text text) returns void
language plpgsql security definer set search_path = public as $$
declare t company_telegram;
begin
  select * into t from company_telegram where company_id = cid;
  if not found or not t.enabled or t.bot_token is null or t.chat_id is null or not (p_event = any(t.events)) then return; end if;
  if to_regnamespace('net') is null then return; end if;
  begin
    execute 'select net.http_post(url := $1, body := $2, headers := ''{"Content-Type":"application/json"}''::jsonb)'
      using 'https://api.telegram.org/bot' || t.bot_token || '/sendMessage', jsonb_build_object('chat_id', t.chat_id, 'text', left(p_text, 4000));
  exception when others then null;
  end;
end $$;
revoke execute on function public.send_telegram(uuid, text, text) from public, anon, authenticated;
create or replace function public.test_telegram(cid uuid) returns text
language plpgsql security definer set search_path = public as $$
begin
  if not has_role(cid, array['owner','admin']) then raise exception 'Only an owner or admin can set up Telegram'; end if;
  if to_regnamespace('net') is null then raise exception 'Turn on the pg_net extension in Supabase (Database → Extensions → pg_net) first'; end if;
  perform send_telegram(cid, (select coalesce(events[1], 'transfer') from company_telegram where company_id = cid), 'Asnys ERP: Telegram alerts are working for ' || (select name from companies where id = cid) || '.');
  return 'sent';
end $$;

-- ---------------------------------------------------------------- 2. Locations
create table public.asset_locations (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  name text not null,
  kind text not null default 'site' check (kind in ('head_office','branch','site','store','yard','other')),
  region text,
  address text,
  manager_id uuid,
  project_id uuid references public.projects(id) on delete set null,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (company_id, name)
);
insert into public.asset_locations (company_id, name, kind)
select id, 'Head office', 'head_office' from public.companies on conflict do nothing;
-- Existing free-text locations become entries.
insert into public.asset_locations (company_id, name, kind)
select distinct company_id, trim(location), 'other' from public.assets where coalesce(trim(location), '') <> '' on conflict do nothing;

alter table public.assets add column if not exists location_id uuid references public.asset_locations(id) on delete set null;
alter table public.assets add column if not exists manufacturer text;
alter table public.assets add column if not exists model text;
alter table public.assets add column if not exists order_number text;
update public.assets a set location_id = l.id from public.asset_locations l where l.company_id = a.company_id and l.name = trim(a.location) and a.location_id is null;
alter table public.assets drop constraint if exists assets_state_check;
alter table public.assets add constraint assets_state_check check (state in ('ready','deployed','pending','repair','broken','lost','archived','transit'));

create or replace function public.location_manager(p_location uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from asset_locations where id = p_location and manager_id = auth.uid());
$$;

create or replace function public.location_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(current_setting('sika.seed', true), '') <> 'on' and not asset_manager(coalesce(new.company_id, old.company_id)) then
    raise exception 'Only the storekeeper, Finance or an admin can change locations';
  end if;
  return coalesce(new, old);
end $$;
create trigger asset_locations_guard before insert or update or delete on public.asset_locations for each row execute function public.location_guard();

-- Keep the free-text location in step with the chosen location.
create or replace function public.asset_location_text() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.location_id is not null and (tg_op = 'INSERT' or new.location_id is distinct from old.location_id) then
    new.location := (select name from asset_locations where id = new.location_id);
  end if;
  return new;
end $$;
create trigger assets_location_text before insert or update of location_id on public.assets for each row execute function public.asset_location_text();

-- ---------------------------------------------------------------- 3. Transfers between locations
create table public.asset_transfers (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  number text,
  asset_id uuid not null references public.assets(id) on delete cascade,
  from_location_id uuid references public.asset_locations(id),
  to_location_id uuid not null references public.asset_locations(id),
  sent_by uuid default auth.uid(), sent_at timestamptz not null default now(),
  note text,
  waybill_id uuid,
  status text not null default 'in_transit' check (status in ('in_transit','received','rejected','recalled')),
  closed_by uuid, closed_at timestamptz, close_note text, condition text
);
create index on public.asset_transfers (company_id, status);

create or replace function public.send_asset_transfer(p_asset uuid, p_to uuid, p_note text default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare a assets; v uuid; n text; v_to asset_locations;
begin
  select * into a from assets where id = p_asset for update;
  if not found then raise exception 'Asset not found'; end if;
  if not (asset_manager(a.company_id) or location_manager(a.location_id)) then raise exception 'Only the storekeeper or the manager of the location holding it can send it'; end if;
  if a.state not in ('ready','pending','repair','broken') then raise exception '% is % — check it in first', a.tag, a.state; end if;
  select * into v_to from asset_locations where id = p_to and company_id = a.company_id and active;
  if not found then raise exception 'Choose where it is going'; end if;
  if a.location_id = p_to then raise exception '% is already at %', a.tag, v_to.name; end if;
  n := next_number(a.company_id, 'ATR', 'ATR-');
  insert into asset_transfers (company_id, number, asset_id, from_location_id, to_location_id, note) values (a.company_id, n, a.id, a.location_id, p_to, p_note) returning id into v;
  insert into asset_movements (company_id, asset_id, kind, from_location, to_location, note, state_after)
  values (a.company_id, a.id, 'move', a.location, v_to.name || ' (in transit)', concat_ws(' · ', n, p_note), 'transit');
  update assets set state = 'transit' where id = a.id;
  perform notify_users(a.company_id, array_remove(array[v_to.manager_id], null) || transport_users(a.company_id), 'asset_transfer', n || ': ' || a.tag || ' ' || a.name || ' is on its way to ' || v_to.name, p_note, '/assets/transfers', false);
  perform send_telegram(a.company_id, 'transfer', '🚚 ' || n || ': ' || a.tag || ' ' || a.name || ' sent from ' || coalesce(a.location, '—') || ' to ' || v_to.name || coalesce(' — ' || p_note, ''));
  return v;
end $$;

create or replace function public.close_asset_transfer(p_id uuid, p_action text, p_note text default null, p_condition text default 'good') returns void
language plpgsql security definer set search_path = public as $$
declare t asset_transfers; a assets; v_loc uuid; v_state text; v_name text;
begin
  select * into t from asset_transfers where id = p_id for update;
  if not found then raise exception 'Transfer not found'; end if;
  if t.status <> 'in_transit' then raise exception 'This transfer is already %', t.status; end if;
  if p_action = 'receive' then
    if not (asset_manager(t.company_id) or location_manager(t.to_location_id)) then raise exception 'Only the receiving location''s manager or the storekeeper can confirm receipt'; end if;
    v_loc := t.to_location_id; v_state := case when p_condition in ('broken') then 'broken' when p_condition = 'poor' then 'repair' else 'ready' end;
  elsif p_action = 'reject' then
    if not (asset_manager(t.company_id) or location_manager(t.to_location_id)) then raise exception 'Only the receiving location can reject it'; end if;
    if coalesce(trim(p_note), '') = '' then raise exception 'Say why it is rejected'; end if;
    v_loc := t.from_location_id; v_state := 'ready';
  elsif p_action = 'recall' then
    if not (asset_manager(t.company_id) or t.sent_by = auth.uid() or location_manager(t.from_location_id)) then raise exception 'Only the sender can recall it'; end if;
    v_loc := t.from_location_id; v_state := 'ready';
  else raise exception 'Unknown action %', p_action;
  end if;
  select * into a from assets where id = t.asset_id for update;
  select name into v_name from asset_locations where id = v_loc;
  perform set_config('sika.transfer', 'on', true);
  update asset_transfers set status = case p_action when 'receive' then 'received' when 'reject' then 'rejected' else 'recalled' end,
    closed_by = auth.uid(), closed_at = now(), close_note = p_note, condition = case when p_action = 'receive' then p_condition end where id = p_id;
  update assets set state = v_state, location_id = v_loc where id = a.id;
  insert into asset_movements (company_id, asset_id, kind, from_location, to_location, note, state_after)
  values (t.company_id, a.id, 'move', 'In transit', v_name, concat_ws(' · ', t.number, initcap(p_action) || case when p_action = 'receive' then 'd' else 'ed' end, p_note), v_state);
  perform set_config('sika.transfer', 'off', true);
  perform notify_users(t.company_id, array[t.sent_by], 'asset_transfer_' || p_action, t.number || ': ' || a.tag || ' ' || case p_action when 'receive' then 'received at ' when 'reject' then 'rejected, coming back to ' else 'recalled to ' end || coalesce(v_name, ''), p_note, '/assets/transfers', false);
  perform send_telegram(t.company_id, 'transfer', case p_action when 'receive' then '✅ ' when 'reject' then '⛔ ' else '↩️ ' end || t.number || ': ' || a.tag || ' ' || a.name || ' ' ||
    case p_action when 'receive' then 'received at ' || v_name || ' (' || p_condition || ')' when 'reject' then 'rejected — ' || p_note else 'recalled' end);
end $$;

-- While in transit, an asset can only be received, rejected or recalled.
create or replace function public.asset_transit_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if old.state = 'transit' and new.state is distinct from 'transit' and coalesce(current_setting('sika.transfer', true), '') <> 'on' then
    raise exception '% is in transit. Receive, reject or recall the transfer first.', old.tag;
  end if;
  return new;
end $$;
create trigger assets_transit_guard before update of state on public.assets for each row execute function public.asset_transit_guard();

-- ---------------------------------------------------------------- 4. Requests through the site, then head office
alter table public.asset_requests add column if not exists location_id uuid references public.asset_locations(id) on delete set null;
alter table public.asset_requests add column if not exists escalated boolean not null default false;
alter table public.asset_requests add column if not exists escalated_note text;
alter table public.asset_requests add column if not exists quantity int not null default 1 check (quantity > 0);

drop function if exists public.request_asset(uuid, text, uuid, uuid, uuid, date, date);
create or replace function public.request_asset(cid uuid, p_description text, p_asset uuid default null, p_category uuid default null, p_project uuid default null,
  p_from date default null, p_until date default null, p_location uuid default null, p_quantity int default 1)
returns uuid language plpgsql security definer set search_path = public as $$
declare v uuid; v_emp uuid; n text; v_mgr uuid; v_who text;
begin
  perform require_member(cid);
  if coalesce(trim(p_description), '') = '' and p_asset is null then raise exception 'Say what you need'; end if;
  if p_asset is not null and not exists (select 1 from assets where id = p_asset and company_id = cid and requestable and status = 'active') then raise exception 'That asset cannot be requested'; end if;
  if p_until is not null and p_until < coalesce(p_from, current_date) then raise exception 'The return date is before the start date'; end if;
  select id into v_emp from employees where company_id = cid and user_id = auth.uid() limit 1;
  select manager_id into v_mgr from asset_locations where id = p_location and company_id = cid;
  n := next_number(cid, 'ARQ', 'ARQ-');
  insert into asset_requests (company_id, number, asset_id, category_id, description, employee_id, project_id, needed_from, needed_until, location_id, quantity)
  values (cid, n, p_asset, p_category, coalesce(nullif(trim(p_description), ''), (select tag || ' ' || name from assets where id = p_asset)), v_emp, p_project,
          coalesce(p_from, current_date), p_until, p_location, greatest(coalesce(p_quantity, 1), 1))
  returning id into v;
  v_who := (select email from memberships where company_id = cid and user_id = auth.uid());
  if v_mgr is not null and v_mgr <> auth.uid() then
    perform notify_users(cid, array[v_mgr], 'asset_requested', n || ': ' || coalesce(nullif(trim(p_description), ''), 'asset requested'), v_who, '/assets/requests', false);
  else
    perform notify(cid, array['store'], null, 'asset_requested', n || ': ' || coalesce(nullif(trim(p_description), ''), 'asset requested'), v_who, '/assets/requests');
  end if;
  perform send_telegram(cid, 'request', '📝 ' || n || ': ' || coalesce(nullif(trim(p_description), ''), 'asset requested') || ' — ' || coalesce(split_part(v_who, '@', 1), '')
    || coalesce(' · ' || (select name from asset_locations where id = p_location), '') || ' · needed ' || to_char(coalesce(p_from, current_date), 'DD Mon') || coalesce(' to ' || to_char(p_until, 'DD Mon'), ''));
  return v;
end $$;

create or replace function public.decide_asset_request(p_id uuid, p_approve boolean, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare r asset_requests;
begin
  select * into r from asset_requests where id = p_id for update;
  if not found then raise exception 'Request not found'; end if;
  if r.requested_by = auth.uid() and not p_approve and not asset_manager(r.company_id) then
    if r.status not in ('pending','approved') then raise exception 'Already %', r.status; end if;
    update asset_requests set status = 'cancelled' where id = p_id; return;
  end if;
  if not (asset_manager(r.company_id) or (not r.escalated and location_manager(r.location_id))) then
    raise exception 'Only the site manager (or, once passed on, head office) can decide this request';
  end if;
  if r.requested_by = auth.uid() then raise exception 'You cannot approve your own request'; end if;
  if r.status <> 'pending' then raise exception 'Already %', r.status; end if;
  update asset_requests set status = case when p_approve then 'approved' else 'rejected' end, decided_by = auth.uid(), decided_on = current_date, decision_note = p_note where id = p_id;
  perform notify_users(r.company_id, array[r.requested_by], 'asset_request_decided', r.number || ' ' || case when p_approve then 'approved' else 'declined' end, p_note, '/assets/requests', true);
  perform send_telegram(r.company_id, 'decision', case when p_approve then '👍 ' else '👎 ' end || r.number || ' ' || case when p_approve then 'approved' else 'declined' end || ': ' || r.description || coalesce(' — ' || p_note, ''));
end $$;

-- The site manager passes a request on to head office (the storekeeper and Finance).
create or replace function public.escalate_asset_request(p_id uuid, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
declare r asset_requests;
begin
  select * into r from asset_requests where id = p_id for update;
  if not found then raise exception 'Request not found'; end if;
  if not (location_manager(r.location_id) or asset_manager(r.company_id)) then raise exception 'Only the site manager can pass a request on'; end if;
  if r.status <> 'pending' or r.escalated then raise exception 'This request has already been passed on or decided'; end if;
  update asset_requests set escalated = true, escalated_note = p_note where id = p_id;
  perform notify(r.company_id, array['store'], null, 'asset_requested', r.number || ' passed to head office: ' || r.description, p_note, '/assets/requests');
  perform send_telegram(r.company_id, 'request', '⬆️ ' || r.number || ' passed to head office: ' || r.description || coalesce(' — ' || p_note, ''));
end $$;

drop policy if exists "requests read" on public.asset_requests;
create policy "requests read" on public.asset_requests for select using (requested_by = auth.uid() or asset_manager(company_id) or has_role(company_id, array['project_manager','hr']) or location_manager(location_id));

-- ---------------------------------------------------------------- 5. Accessories, components and consumables
create table public.asset_items (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  kind text not null check (kind in ('accessory','component','consumable')),
  name text not null,
  category text,
  manufacturer text,
  model_no text,
  unit text not null default 'each',
  min_qty numeric(12,2) not null default 0,
  unit_cost numeric(14,2),
  requestable boolean not null default false,
  notes text,
  active boolean not null default true,
  created_at timestamptz not null default now()
);
create table public.asset_item_stock (
  item_id uuid not null references public.asset_items(id) on delete cascade,
  location_id uuid not null references public.asset_locations(id) on delete cascade,
  company_id uuid not null references public.companies(id) on delete cascade,
  qty numeric(12,2) not null default 0 check (qty >= 0),
  primary key (item_id, location_id)
);
create table public.asset_item_moves (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  item_id uuid not null references public.asset_items(id) on delete cascade,
  kind text not null check (kind in ('receive','checkout','checkin','consume','transfer','adjust')),
  location_id uuid references public.asset_locations(id),
  to_location_id uuid references public.asset_locations(id),
  qty numeric(12,2) not null,
  employee_id uuid references public.employees(id) on delete set null,
  asset_id uuid references public.assets(id) on delete set null,
  project_id uuid references public.projects(id) on delete set null,
  unit_cost numeric(14,2),
  note text,
  moved_by uuid default auth.uid(),
  moved_at timestamptz not null default now()
);
create index on public.asset_item_moves (item_id, moved_at desc);
create table public.asset_item_checkouts (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  item_id uuid not null references public.asset_items(id) on delete cascade,
  location_id uuid not null references public.asset_locations(id),
  employee_id uuid references public.employees(id) on delete set null,
  asset_id uuid references public.assets(id) on delete set null,
  qty numeric(12,2) not null check (qty > 0),
  returned_qty numeric(12,2) not null default 0,
  out_at timestamptz not null default now(),
  expected_return date,
  status text not null default 'out' check (status in ('out','returned')),
  note text
);

create or replace function public.item_total(p_item uuid) returns numeric
language sql stable security definer set search_path = public as $$ select coalesce(sum(qty), 0) from asset_item_stock where item_id = p_item; $$;

create or replace function public.item_stock_change(p_item uuid, p_location uuid, p_delta numeric) returns void
language plpgsql security definer set search_path = public as $$
declare i asset_items; v_have numeric;
begin
  select * into i from asset_items where id = p_item;
  insert into asset_item_stock (item_id, location_id, company_id, qty) values (p_item, p_location, i.company_id, 0) on conflict do nothing;
  select qty into v_have from asset_item_stock where item_id = p_item and location_id = p_location for update;
  if v_have + p_delta < 0 then raise exception 'Only % % of % at %', v_have, i.unit, i.name, (select name from asset_locations where id = p_location); end if;
  update asset_item_stock set qty = qty + p_delta where item_id = p_item and location_id = p_location;
  if p_delta < 0 and i.min_qty > 0 and item_total(p_item) < i.min_qty and item_total(p_item) - p_delta >= i.min_qty then
    perform notify(i.company_id, array['store'], null, 'low_stock', 'Low stock: ' || i.name, item_total(p_item) || ' ' || i.unit || ' left (minimum ' || i.min_qty || ')', '/assets/items', true);
    perform send_telegram(i.company_id, 'low_stock', '⚠️ Low stock: ' || i.name || ' — ' || item_total(p_item) || ' ' || i.unit || ' left (minimum ' || i.min_qty || ')');
  end if;
end $$;
revoke execute on function public.item_stock_change(uuid, uuid, numeric) from public, anon, authenticated;

-- Receive, issue, return, consume, transfer or adjust.
create or replace function public.item_move(p_item uuid, p_kind text, p_location uuid, p_qty numeric, p_to uuid default null, p_employee uuid default null,
  p_asset uuid default null, p_project uuid default null, p_unit_cost numeric default null, p_note text default null, p_checkout uuid default null, p_expected date default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare i asset_items; c asset_item_checkouts; v uuid;
begin
  select * into i from asset_items where id = p_item;
  if not found then raise exception 'Item not found'; end if;
  if not (asset_manager(i.company_id) or location_manager(p_location)) then raise exception 'Only the storekeeper or the location manager can move stock'; end if;
  if p_kind <> 'adjust' and coalesce(p_qty, 0) <= 0 then raise exception 'Enter a quantity'; end if;
  if p_kind = 'receive' then perform item_stock_change(p_item, p_location, p_qty);
    if p_unit_cost is not null then update asset_items set unit_cost = p_unit_cost where id = p_item; end if;
  elsif p_kind = 'consume' then perform item_stock_change(p_item, p_location, -p_qty);
  elsif p_kind = 'checkout' then
    if i.kind = 'consumable' then raise exception 'Consumables are used up, not checked out'; end if;
    if p_employee is null and p_asset is null then raise exception 'Check it out to a person or into an asset'; end if;
    perform item_stock_change(p_item, p_location, -p_qty);
    insert into asset_item_checkouts (company_id, item_id, location_id, employee_id, asset_id, qty, expected_return, note)
    values (i.company_id, p_item, p_location, p_employee, p_asset, p_qty, p_expected, p_note);
  elsif p_kind = 'checkin' then
    select * into c from asset_item_checkouts where id = p_checkout and item_id = p_item for update;
    if not found or c.status <> 'out' then raise exception 'Choose what is being returned'; end if;
    if p_qty > c.qty - c.returned_qty then raise exception 'Only % are out', c.qty - c.returned_qty; end if;
    perform item_stock_change(p_item, p_location, p_qty);
    update asset_item_checkouts set returned_qty = returned_qty + p_qty, status = case when returned_qty + p_qty >= qty then 'returned' else 'out' end where id = c.id;
    p_employee := c.employee_id; p_asset := c.asset_id;
  elsif p_kind = 'transfer' then
    if p_to is null or p_to = p_location then raise exception 'Choose where it is going'; end if;
    perform item_stock_change(p_item, p_location, -p_qty);
    perform item_stock_change(p_item, p_to, p_qty);
  elsif p_kind = 'adjust' then
    if coalesce(trim(p_note), '') = '' then raise exception 'Give a reason for the adjustment'; end if;
    perform item_stock_change(p_item, p_location, p_qty);
  else raise exception 'Unknown movement %', p_kind;
  end if;
  insert into asset_item_moves (company_id, item_id, kind, location_id, to_location_id, qty, employee_id, asset_id, project_id, unit_cost, note)
  values (i.company_id, p_item, p_kind, p_location, p_to, p_qty, p_employee, p_asset, p_project, coalesce(p_unit_cost, i.unit_cost), p_note) returning id into v;
  return v;
end $$;

-- ---------------------------------------------------------------- 6. Software licences
create table public.software_licences (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  name text not null,
  manufacturer text,
  product_key text,
  seats int not null default 1 check (seats > 0),
  licensed_to_name text,
  licensed_to_email text,
  purchase_date date,
  cost numeric(14,2),
  expires_on date,
  order_number text,
  supplier_id uuid references public.suppliers(id) on delete set null,
  reassignable boolean not null default true,
  notes text,
  reminded_on date,
  created_at timestamptz not null default now()
);
create table public.licence_seats (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  licence_id uuid not null references public.software_licences(id) on delete cascade,
  employee_id uuid references public.employees(id) on delete set null,
  asset_id uuid references public.assets(id) on delete set null,
  assigned_at timestamptz not null default now(),
  released_at timestamptz,
  note text,
  check (employee_id is not null or asset_id is not null)
);
create or replace function public.licence_seat_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare l software_licences; v_used int;
begin
  select * into l from software_licences where id = coalesce(new.licence_id, old.licence_id);
  if not asset_manager(l.company_id) then raise exception 'Only the storekeeper, Finance or an admin can assign licences'; end if;
  if tg_op = 'INSERT' then
    new.company_id := l.company_id;
    select count(*) into v_used from licence_seats where licence_id = l.id and released_at is null;
    if v_used >= l.seats then raise exception 'All % seats of % are in use. Free one first.', l.seats, l.name; end if;
  elsif tg_op = 'UPDATE' and old.released_at is null and new.released_at is not null and not l.reassignable then
    raise exception '% seats cannot be reassigned', l.name;
  end if;
  return coalesce(new, old);
end $$;
create trigger licence_seats_guard before insert or update or delete on public.licence_seats for each row execute function public.licence_seat_guard();

-- ---------------------------------------------------------------- 7. Fleet: vehicles, documents, drivers
create table public.vehicles (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  asset_id uuid references public.assets(id) on delete set null,
  reg_no text not null,
  make text, model text, year int,
  vehicle_type text not null default 'pickup' check (vehicle_type in ('car','pickup','van','truck','bus','motorbike','plant','crane','trailer','other')),
  fuel_type text not null default 'diesel' check (fuel_type in ('diesel','petrol','lpg','electric','hybrid')),
  chassis_no text, engine_no text, colour text,
  capacity_kg numeric(10,1), seats int,
  odometer numeric(10,0) not null default 0 check (odometer >= 0),
  tank_litres numeric(8,1),
  expected_km_per_l numeric(6,2),
  service_interval_km int,
  service_interval_months int,
  last_service_km numeric(10,0),
  last_service_date date,
  driver_id uuid references public.employees(id) on delete set null,
  project_id uuid references public.projects(id) on delete set null,
  location_id uuid references public.asset_locations(id) on delete set null,
  status text not null default 'available' check (status in ('available','in_use','maintenance','off_road','disposed')),
  notes text,
  created_at timestamptz not null default now(),
  unique (company_id, reg_no)
);
create table public.vehicle_documents (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  vehicle_id uuid not null references public.vehicles(id) on delete cascade,
  kind text not null check (kind in ('roadworthy','insurance','road_use','registration','permit','tracker','other')),
  reference text,
  provider text,
  issued_on date,
  expires_on date,
  cost numeric(14,2),
  storage_path text,
  reminded_for date,
  created_at timestamptz not null default now()
);
create table public.drivers (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  employee_id uuid not null references public.employees(id) on delete cascade,
  licence_no text,
  licence_class text,
  licence_expiry date,
  defensive_training_on date,
  medical_expiry date,
  active boolean not null default true,
  notes text,
  reminded_for date,
  unique (company_id, employee_id)
);

-- ---------------------------------------------------------------- 8. Trips, fuel, service, requests
create table public.vehicle_requests (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  number text,
  requested_by uuid not null default auth.uid(),
  employee_id uuid references public.employees(id) on delete set null,
  project_id uuid references public.projects(id) on delete set null,
  purpose text not null,
  origin text, destination text,
  from_at timestamptz not null, to_at timestamptz not null,
  passengers int, load_desc text,
  vehicle_type text,
  status text not null default 'pending' check (status in ('pending','approved','rejected','cancelled','done')),
  vehicle_id uuid references public.vehicles(id) on delete set null,
  driver_id uuid references public.employees(id) on delete set null,
  decided_by uuid, decided_at timestamptz, decision_note text,
  created_at timestamptz not null default now(),
  check (to_at > from_at)
);
create table public.vehicle_trips (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  number text,
  vehicle_id uuid not null references public.vehicles(id) on delete cascade,
  driver_id uuid references public.employees(id) on delete set null,
  project_id uuid references public.projects(id) on delete set null,
  request_id uuid references public.vehicle_requests(id) on delete set null,
  purpose text not null,
  origin text, destination text,
  start_at timestamptz, end_at timestamptz,
  odometer_start numeric(10,0), odometer_end numeric(10,0),
  distance_km numeric(10,0) generated always as (odometer_end - odometer_start) stored,
  passengers int, load_desc text,
  status text not null default 'planned' check (status in ('planned','in_progress','completed','cancelled')),
  out_of_hours boolean not null default false,
  note text,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);
create index on public.vehicle_trips (vehicle_id, start_at desc);
create table public.vehicle_fuel (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  vehicle_id uuid not null references public.vehicles(id) on delete cascade,
  filled_on date not null default current_date,
  litres numeric(10,2) not null check (litres > 0),
  cost numeric(14,2) not null default 0 check (cost >= 0),
  odometer numeric(10,0),
  full_tank boolean not null default true,
  station text,
  paid_by text not null default 'cash' check (paid_by in ('cash','fuel_card','account','advance','petty_cash','other')),
  driver_id uuid references public.employees(id) on delete set null,
  project_id uuid references public.projects(id) on delete set null,
  receipt_path text,
  km_per_l numeric(8,2),
  flagged boolean not null default false,
  esg_entry_id uuid,
  note text,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);
create index on public.vehicle_fuel (vehicle_id, filled_on desc);
create table public.vehicle_services (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  vehicle_id uuid not null references public.vehicles(id) on delete cascade,
  number text,
  service_date date not null default current_date,
  odometer numeric(10,0),
  kind text not null default 'service' check (kind in ('service','repair','tyres','battery','inspection','accident','bodywork','other')),
  description text not null,
  vendor text,
  cost numeric(14,2) not null default 0 check (cost >= 0),
  parts text,
  downtime_days numeric(6,1),
  next_due_km numeric(10,0),
  next_due_date date,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);

create or replace function public.fleet_defaults() returns trigger
language plpgsql security definer set search_path = public as $$
declare cid uuid := coalesce(new.company_id, old.company_id);
begin
  if tg_table_name = 'vehicle_requests' then
    if tg_op = 'INSERT' then
      if not is_member(new.company_id) then raise exception 'You do not have access to this company'; end if;
      new.number := next_number(new.company_id, 'VRQ', 'VRQ-'); new.status := 'pending'; new.requested_by := auth.uid();
      new.employee_id := coalesce(new.employee_id, (select id from employees where company_id = new.company_id and user_id = auth.uid() limit 1));
    elsif coalesce(current_setting('sika.fleet', true), '') <> 'on' and (new.status, new.vehicle_id) is distinct from (old.status, old.vehicle_id) then
      raise exception 'Use Approve, Decline or Cancel';
    end if;
    return new;
  end if;
  if tg_table_name = 'vehicle_trips' and tg_op = 'INSERT' then
    new.number := next_number(new.company_id, 'TRP', 'TRP-');
    if not (is_transport(new.company_id) or exists (select 1 from employees where id = new.driver_id and user_id = auth.uid())) then
      raise exception 'Only the transport officer or the trip''s driver can log a trip';
    end if;
    return new;
  end if;
  if tg_table_name = 'vehicle_services' and tg_op = 'INSERT' then new.number := next_number(new.company_id, 'JOB', 'JOB-'); end if;
  if tg_table_name in ('vehicles','vehicle_documents','drivers','vehicle_services') and coalesce(current_setting('sika.fleet', true), '') <> 'on' and not is_transport(cid) then
    raise exception 'Only the transport officer, storekeeper, Finance or an admin can change fleet records';
  end if;
  return coalesce(new, old);
end $$;
create trigger vehicles_guard before insert or update or delete on public.vehicles for each row execute function public.fleet_defaults();
create trigger vehicle_documents_guard before insert or update or delete on public.vehicle_documents for each row execute function public.fleet_defaults();
create trigger drivers_guard before insert or update or delete on public.drivers for each row execute function public.fleet_defaults();
create trigger vehicle_services_guard before insert or update or delete on public.vehicle_services for each row execute function public.fleet_defaults();
create trigger vehicle_requests_defaults before insert or update on public.vehicle_requests for each row execute function public.fleet_defaults();
create trigger vehicle_trips_defaults before insert on public.vehicle_trips for each row execute function public.fleet_defaults();

-- A service updates the vehicle's last service.
create or replace function public.vehicle_service_after() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform set_config('sika.fleet', 'on', true);
  update vehicles set last_service_km = case when new.kind = 'service' then coalesce(new.odometer, last_service_km) else last_service_km end,
    last_service_date = case when new.kind = 'service' then new.service_date else last_service_date end,
    odometer = greatest(odometer, coalesce(new.odometer, 0))
  where id = new.vehicle_id;
  perform set_config('sika.fleet', 'off', true);
  return null;
end $$;
create trigger vehicle_services_after after insert on public.vehicle_services for each row execute function public.vehicle_service_after();

create or replace function public.decide_vehicle_request(p_id uuid, p_action text, p_vehicle uuid default null, p_driver uuid default null, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
declare r vehicle_requests; v vehicles; v_clash text;
begin
  select * into r from vehicle_requests where id = p_id for update;
  if not found then raise exception 'Request not found'; end if;
  if p_action = 'cancel' then
    if not (r.requested_by = auth.uid() or is_transport(r.company_id)) then raise exception 'Only the requester can cancel'; end if;
    if r.status not in ('pending','approved') then raise exception 'Already %', r.status; end if;
  else
    if not is_transport(r.company_id) then raise exception 'Only the transport officer allocates vehicles'; end if;
    if r.status <> 'pending' then raise exception 'Already %', r.status; end if;
    if p_action = 'approve' then
      select * into v from vehicles where id = p_vehicle and company_id = r.company_id;
      if not found then raise exception 'Choose a vehicle'; end if;
      if v.status in ('maintenance','off_road','disposed') then raise exception '% is %', v.reg_no, replace(v.status, '_', ' '); end if;
      select q.number into v_clash from vehicle_requests q where q.vehicle_id = p_vehicle and q.status = 'approved' and q.id <> r.id and tstzrange(q.from_at, q.to_at) && tstzrange(r.from_at, r.to_at) limit 1;
      if v_clash is not null then raise exception '% is already booked then (%)', v.reg_no, v_clash; end if;
    elsif p_action = 'reject' and coalesce(trim(p_note), '') = '' then raise exception 'Give a reason';
    end if;
  end if;
  perform set_config('sika.fleet', 'on', true);
  update vehicle_requests set status = case p_action when 'approve' then 'approved' when 'reject' then 'rejected' else 'cancelled' end,
    vehicle_id = case when p_action = 'approve' then p_vehicle else vehicle_id end, driver_id = case when p_action = 'approve' then coalesce(p_driver, (select driver_id from vehicles where id = p_vehicle)) else driver_id end,
    decided_by = auth.uid(), decided_at = now(), decision_note = p_note where id = p_id;
  perform set_config('sika.fleet', 'off', true);
  if p_action <> 'cancel' then
    perform notify_users(r.company_id, array[r.requested_by, (select user_id from employees where id = coalesce(p_driver, (select driver_id from vehicles where id = p_vehicle)))],
      'vehicle_request', r.number || case when p_action = 'approve' then ': ' || (select reg_no from vehicles where id = p_vehicle) || ' allocated' else ' declined' end, p_note, '/fleet/requests', false);
    perform send_telegram(r.company_id, 'decision', '🚗 ' || r.number || case when p_action = 'approve' then ' — ' || (select reg_no from vehicles where id = p_vehicle) || ' allocated for ' || r.purpose else ' declined: ' || p_note end);
  end if;
end $$;

create or replace function public.vehicle_request_notice() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform notify_users(new.company_id, transport_users(new.company_id), 'vehicle_request', new.number || ': vehicle needed — ' || new.purpose,
    to_char(new.from_at, 'DD Mon HH24:MI') || ' to ' || to_char(new.to_at, 'DD Mon HH24:MI') || coalesce(' · ' || new.destination, ''), '/fleet/requests', false);
  perform send_telegram(new.company_id, 'request', '🚗 ' || new.number || ': vehicle needed — ' || new.purpose || ' · ' || to_char(new.from_at, 'DD Mon HH24:MI') || coalesce(' to ' || new.destination, ''));
  return null;
end $$;
create trigger vehicle_requests_notice after insert on public.vehicle_requests for each row execute function public.vehicle_request_notice();

-- Start and finish trips: mileage only goes forward; the vehicle is shown in use.
create or replace function public.trip_step(p_trip uuid, p_action text, p_odometer numeric default null, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
declare t vehicle_trips; v vehicles;
begin
  select * into t from vehicle_trips where id = p_trip for update;
  if not found then raise exception 'Trip not found'; end if;
  if not (is_transport(t.company_id) or exists (select 1 from employees where id = t.driver_id and user_id = auth.uid())) then raise exception 'Only the driver or the transport officer can update this trip'; end if;
  select * into v from vehicles where id = t.vehicle_id for update;
  perform set_config('sika.fleet', 'on', true);
  if p_action = 'start' then
    if t.status <> 'planned' then raise exception 'This trip has already started'; end if;
    if p_odometer is null then raise exception 'Enter the mileage at the start'; end if;
    if p_odometer < v.odometer then raise exception 'The mileage cannot be less than the last reading (% km)', v.odometer; end if;
    if v.status in ('in_use') and exists (select 1 from vehicle_trips where vehicle_id = v.id and status = 'in_progress') then raise exception '% is already on a trip', v.reg_no; end if;
    update vehicle_trips set status = 'in_progress', start_at = coalesce(start_at, now()), odometer_start = p_odometer,
      out_of_hours = extract(isodow from now()) > 5 or extract(hour from now()) not between 6 and 18 where id = t.id;
    update vehicles set status = 'in_use', odometer = p_odometer where id = v.id;
  elsif p_action = 'finish' then
    if t.status <> 'in_progress' then raise exception 'Start the trip first'; end if;
    if p_odometer is null or p_odometer < t.odometer_start then raise exception 'The mileage at the end must be at least % km', t.odometer_start; end if;
    if p_odometer - t.odometer_start > 2000 then raise exception 'That is more than 2,000 km in one trip. Check the reading.'; end if;
    update vehicle_trips set status = 'completed', end_at = now(), odometer_end = p_odometer, note = coalesce(p_note, note) where id = t.id;
    update vehicles set status = 'available', odometer = greatest(odometer, p_odometer) where id = v.id;
    if t.request_id is not null then update vehicle_requests set status = 'done' where id = t.request_id; end if;
  elsif p_action = 'cancel' then
    if t.status = 'completed' then raise exception 'A completed trip cannot be cancelled'; end if;
    update vehicle_trips set status = 'cancelled', note = coalesce(p_note, note) where id = t.id;
    if t.status = 'in_progress' then update vehicles set status = 'available' where id = v.id; end if;
  else raise exception 'Unknown action %', p_action;
  end if;
  perform set_config('sika.fleet', 'off', true);
end $$;

-- Fuel: km per litre between full tanks; low economy is flagged; the litres also go to the sustainability figures.
create or replace function public.vehicle_fuel_defaults() returns trigger
language plpgsql security definer set search_path = public as $$
declare v vehicles; p vehicle_fuel; v_litres numeric; v_factor uuid; v_esg uuid;
begin
  select * into v from vehicles where id = new.vehicle_id;
  new.company_id := v.company_id;
  if not (is_transport(v.company_id) or v.driver_id in (select my_employee_ids()) or exists (select 1 from vehicle_trips t where t.vehicle_id = v.id and t.status = 'in_progress' and t.driver_id in (select my_employee_ids()))) then
    raise exception 'Only the vehicle''s driver or the transport officer can log fuel';
  end if;
  if new.odometer is not null and new.odometer < (select coalesce(max(odometer), 0) from vehicle_fuel where vehicle_id = v.id and filled_on <= new.filled_on) then
    raise exception 'The mileage is lower than at the previous fill';
  end if;
  new.driver_id := coalesce(new.driver_id, v.driver_id); new.project_id := coalesce(new.project_id, v.project_id);
  if new.full_tank and new.odometer is not null then
    select * into p from vehicle_fuel where vehicle_id = v.id and full_tank and odometer is not null and odometer < new.odometer order by odometer desc limit 1;
    if found then
      select coalesce(sum(litres), 0) into v_litres from vehicle_fuel where vehicle_id = v.id and odometer > p.odometer and odometer < new.odometer;
      new.km_per_l := round((new.odometer - p.odometer) / nullif(v_litres + new.litres, 0), 2);
      new.flagged := v.expected_km_per_l is not null and new.km_per_l < v.expected_km_per_l * 0.8;
    end if;
  end if;
  -- Sustainability (scope 1): diesel or petrol litres.
  select id into v_factor from esg_factors where company_id = v.company_id and key = case v.fuel_type when 'petrol' then 'petrol_l' when 'lpg' then 'lpg_l' else 'diesel_l' end and active;
  if v_factor is not null and v.fuel_type in ('diesel','petrol','lpg') then
    perform set_config('sika.hse', 'on', true);
    insert into esg_entries (company_id, period, factor_id, quantity, factor_used, kg_co2e, project_id, source_ref, note)
    select v.company_id, date_trunc('month', new.filled_on)::date, f.id, new.litres, f.kg_co2e, round(new.litres * f.kg_co2e, 3), new.project_id, 'Fuel log ' || v.reg_no, new.station
    from esg_factors f where f.id = v_factor returning id into v_esg;
    new.esg_entry_id := v_esg;
  end if;
  perform set_config('sika.fleet', 'on', true);
  update vehicles set odometer = greatest(odometer, coalesce(new.odometer, 0)) where id = v.id;
  perform set_config('sika.fleet', 'off', true);
  return new;
end $$;
create trigger vehicle_fuel_defaults before insert on public.vehicle_fuel for each row execute function public.vehicle_fuel_defaults();
create or replace function public.vehicle_fuel_notice() returns trigger
language plpgsql security definer set search_path = public as $$
declare v vehicles;
begin
  if new.flagged then
    select * into v from vehicles where id = new.vehicle_id;
    perform notify_users(new.company_id, transport_users(new.company_id), 'fuel_flag', 'Fuel use high: ' || v.reg_no, new.km_per_l || ' km/l against ' || v.expected_km_per_l || ' expected. Check for leaks, misuse or a wrong reading.', '/fleet/fuel', true);
    perform send_telegram(new.company_id, 'fleet', '⛽ Fuel use high on ' || v.reg_no || ': ' || new.km_per_l || ' km/l (expected ' || v.expected_km_per_l || ')');
  end if;
  return null;
end $$;
create trigger vehicle_fuel_notice after insert on public.vehicle_fuel for each row execute function public.vehicle_fuel_notice();

-- Sustainability entries made from the fuel log are allowed without the HSE checks.
create or replace function public.esg_entry_defaults() returns trigger
language plpgsql security definer set search_path = public as $$
declare f esg_factors;
begin
  if coalesce(current_setting('sika.hse', true), '') <> 'on' and not (is_hse(new.company_id) or has_role(new.company_id, array['accountant','store','project_manager'])) then
    raise exception 'Only an HSE officer, Finance, the storekeeper or a project manager can record sustainability data';
  end if;
  select * into f from esg_factors where id = new.factor_id;
  if f.company_id is distinct from new.company_id then raise exception 'Choose one of your own emission factors'; end if;
  new.period := date_trunc('month', new.period)::date;
  if tg_op = 'INSERT' or new.factor_id is distinct from old.factor_id or new.quantity is distinct from old.quantity then
    new.factor_used := f.kg_co2e;
    new.kg_co2e := round(new.quantity * f.kg_co2e, 3);
  end if;
  return new;
end $$;

-- ---------------------------------------------------------------- 9. Waybills (deliveries and collections, own or hired transport)
create table public.waybills (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  number text,
  kind text not null default 'delivery' check (kind in ('delivery','collection','transfer','return')),
  transport text not null default 'own' check (transport in ('own','hired','courier')),
  vehicle_id uuid references public.vehicles(id) on delete set null,
  driver_id uuid references public.employees(id) on delete set null,
  transporter_id uuid references public.suppliers(id) on delete set null,
  truck_reg text, driver_name text, driver_phone text,
  project_id uuid references public.projects(id) on delete set null,
  customer_id uuid references public.customers(id) on delete set null,
  from_place text not null,
  to_place text not null,
  contact_name text, contact_phone text,
  planned_on date not null default current_date,
  dispatched_at timestamptz, expected_at timestamptz, delivered_at timestamptz,
  status text not null default 'draft' check (status in ('draft','dispatched','delivered','partial','cancelled')),
  received_by_name text,
  pod_path text,
  pod_note text,
  transport_cost numeric(14,2) not null default 0 check (transport_cost >= 0),
  po_id uuid,
  note text,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);
create table public.waybill_lines (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  waybill_id uuid not null references public.waybills(id) on delete cascade,
  product_id uuid references public.products(id) on delete set null,
  asset_id uuid references public.assets(id) on delete set null,
  description text not null,
  qty numeric(12,2) not null check (qty > 0),
  unit text,
  weight_kg numeric(10,1),
  delivered_qty numeric(12,2),
  note text,
  sort int not null default 0
);
create or replace function public.waybill_defaults() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    if not (is_transport(new.company_id) or has_role(new.company_id, array['project_manager','sales'])) then raise exception 'Only the transport officer, storekeeper, Finance or a project manager can raise waybills'; end if;
    new.number := next_number(new.company_id, 'WB', 'WB-'); new.status := 'draft';
  elsif coalesce(current_setting('sika.fleet', true), '') <> 'on' then
    if new.status is distinct from old.status then raise exception 'Use Dispatch, Delivered or Cancel'; end if;
    if old.status <> 'draft' and (new.from_place, new.to_place, new.vehicle_id, new.transport_cost) is distinct from (old.from_place, old.to_place, old.vehicle_id, old.transport_cost) and not is_transport(old.company_id) then
      raise exception 'A dispatched waybill can only be changed by the transport officer';
    end if;
    new.number := old.number;
  end if;
  return new;
end $$;
create trigger waybills_defaults before insert or update on public.waybills for each row execute function public.waybill_defaults();
create or replace function public.waybill_line_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare w waybills;
begin
  select * into w from waybills where id = coalesce(new.waybill_id, old.waybill_id);
  if coalesce(current_setting('sika.fleet', true), '') <> 'on' and w.status <> 'draft' then raise exception 'The waybill has been dispatched; its lines are fixed'; end if;
  if tg_op <> 'DELETE' then new.company_id := w.company_id; end if;
  return coalesce(new, old);
end $$;
create trigger waybill_lines_guard before insert or update or delete on public.waybill_lines for each row execute function public.waybill_line_guard();

create or replace function public.waybill_step(p_id uuid, p_action text, p_received_by text default null, p_note text default null, p_lines jsonb default null, p_pod text default null) returns text
language plpgsql security definer set search_path = public as $$
declare w waybills; v_to text; v_short int; l record;
begin
  select * into w from waybills where id = p_id for update;
  if not found then raise exception 'Waybill not found'; end if;
  perform set_config('sika.fleet', 'on', true);
  if p_action = 'dispatch' then
    if not (is_transport(w.company_id) or has_role(w.company_id, array['project_manager'])) then raise exception 'Only the transport officer or project manager can dispatch'; end if;
    if w.status <> 'draft' then raise exception 'Already %', w.status; end if;
    if not exists (select 1 from waybill_lines where waybill_id = p_id) then raise exception 'Add what is being carried'; end if;
    if w.transport = 'own' and w.vehicle_id is null then raise exception 'Choose the vehicle'; end if;
    if w.transport <> 'own' and coalesce(trim(w.truck_reg), '') = '' and w.transporter_id is null then raise exception 'Enter the transporter or truck registration'; end if;
    update waybills set status = 'dispatched', dispatched_at = now() where id = p_id; v_to := 'dispatched';
    perform notify_users(w.company_id, array[(select user_id from employees where id = w.driver_id), (select manager_id from projects where id = w.project_id)], 'waybill', w.number || ' on its way to ' || w.to_place, null, '/fleet/waybills', false);
    perform send_telegram(w.company_id, 'fleet', '📦 ' || w.number || ' dispatched: ' || w.from_place || ' → ' || w.to_place || coalesce(' · ' || (select reg_no from vehicles where id = w.vehicle_id), coalesce(' · ' || w.truck_reg, '')));
  elsif p_action = 'deliver' then
    if w.status <> 'dispatched' then raise exception 'Dispatch it first'; end if;
    if not (is_transport(w.company_id) or has_role(w.company_id, array['project_manager']) or exists (select 1 from employees where id = w.driver_id and user_id = auth.uid())) then raise exception 'Only the driver, the site or the transport officer can confirm delivery'; end if;
    if coalesce(trim(p_received_by), '') = '' then raise exception 'Enter the name of the person who received the goods'; end if;
    if p_lines is not null then
      for l in select (x->>'id')::uuid id, (x->>'delivered_qty')::numeric q from jsonb_array_elements(p_lines) x loop
        update waybill_lines set delivered_qty = l.q where id = l.id and waybill_id = p_id;
      end loop;
    end if;
    update waybill_lines set delivered_qty = coalesce(delivered_qty, qty) where waybill_id = p_id;
    select count(*) into v_short from waybill_lines where waybill_id = p_id and delivered_qty < qty;
    v_to := case when v_short > 0 then 'partial' else 'delivered' end;
    update waybills set status = v_to, delivered_at = now(), received_by_name = p_received_by, pod_note = p_note, pod_path = coalesce(p_pod, pod_path) where id = p_id;
    perform notify_users(w.company_id, transport_users(w.company_id) || array[w.created_by], 'waybill', w.number || ' ' || case when v_short > 0 then 'delivered short (' || v_short || ' line' || case when v_short = 1 then '' else 's' end || ')' else 'delivered' end || ' at ' || w.to_place, 'Received by ' || p_received_by, '/fleet/waybills', false);
    perform send_telegram(w.company_id, 'fleet', case when v_short > 0 then '⚠️ ' else '✅ ' end || w.number || ' ' || v_to || ' at ' || w.to_place || ' — received by ' || p_received_by);
  elsif p_action = 'cancel' then
    if not is_transport(w.company_id) then raise exception 'Only the transport officer can cancel'; end if;
    if w.status in ('delivered','partial') then raise exception 'A delivered waybill cannot be cancelled'; end if;
    if coalesce(trim(p_note), '') = '' then raise exception 'Give a reason'; end if;
    update waybills set status = 'cancelled', note = concat_ws(E'\n', note, 'Cancelled: ' || p_note) where id = p_id; v_to := 'cancelled';
  else raise exception 'Unknown action %', p_action;
  end if;
  perform set_config('sika.fleet', 'off', true);
  return v_to;
end $$;

-- ---------------------------------------------------------------- 10. Reports and reminders
create or replace function public.fleet_report(cid uuid, p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform require_member(cid);
  return jsonb_build_object(
    'vehicles', coalesce((select jsonb_agg(x order by x->>'reg_no') from (
      select jsonb_build_object('id', v.id, 'reg_no', v.reg_no, 'name', concat_ws(' ', v.make, v.model), 'type', v.vehicle_type, 'status', v.status, 'odometer', v.odometer,
        'km', coalesce((select sum(distance_km) from vehicle_trips t where t.vehicle_id = v.id and t.status = 'completed' and t.end_at::date between p_from and p_to), 0),
        'trips', (select count(*) from vehicle_trips t where t.vehicle_id = v.id and t.status = 'completed' and t.end_at::date between p_from and p_to),
        'litres', coalesce((select sum(litres) from vehicle_fuel f where f.vehicle_id = v.id and f.filled_on between p_from and p_to), 0),
        'fuel_cost', coalesce((select sum(cost) from vehicle_fuel f where f.vehicle_id = v.id and f.filled_on between p_from and p_to), 0),
        'service_cost', coalesce((select sum(cost) from vehicle_services s where s.vehicle_id = v.id and s.service_date between p_from and p_to), 0),
        'doc_cost', coalesce((select sum(cost) from vehicle_documents d where d.vehicle_id = v.id and d.issued_on between p_from and p_to), 0),
        'downtime', coalesce((select sum(downtime_days) from vehicle_services s where s.vehicle_id = v.id and s.service_date between p_from and p_to), 0),
        'km_per_l', (select round(avg(km_per_l), 2) from vehicle_fuel f where f.vehicle_id = v.id and f.km_per_l is not null and f.filled_on between p_from and p_to),
        'flags', (select count(*) from vehicle_fuel f where f.vehicle_id = v.id and f.flagged and f.filled_on between p_from and p_to),
        'service_due', case when v.service_interval_km is not null and v.odometer >= coalesce(v.last_service_km, 0) + v.service_interval_km - 500 then true
                            when v.service_interval_months is not null and coalesce(v.last_service_date, v.created_at::date) + make_interval(months => v.service_interval_months) <= current_date + 14 then true else false end) x
      from vehicles v where v.company_id = cid and v.status <> 'disposed') y), '[]'::jsonb),
    'projects', coalesce((select jsonb_agg(x) from (
      select jsonb_build_object('project_id', p.id, 'project', concat_ws(' ', p.number, p.name),
        'km', coalesce((select sum(distance_km) from vehicle_trips t where t.project_id = p.id and t.status = 'completed' and t.end_at::date between p_from and p_to), 0),
        'fuel_cost', coalesce((select sum(cost) from vehicle_fuel f where f.project_id = p.id and f.filled_on between p_from and p_to), 0),
        'waybills', (select count(*) from waybills w where w.project_id = p.id and w.planned_on between p_from and p_to and w.status <> 'cancelled'),
        'transport_cost', coalesce((select sum(transport_cost) from waybills w where w.project_id = p.id and w.planned_on between p_from and p_to and w.status <> 'cancelled'), 0)) x
      from projects p where p.company_id = cid and not p.is_template and (
        exists (select 1 from vehicle_trips t where t.project_id = p.id and t.end_at::date between p_from and p_to) or
        exists (select 1 from vehicle_fuel f where f.project_id = p.id and f.filled_on between p_from and p_to) or
        exists (select 1 from waybills w where w.project_id = p.id and w.planned_on between p_from and p_to))) y), '[]'::jsonb),
    'documents_due', coalesce((select jsonb_agg(jsonb_build_object('reg_no', v.reg_no, 'kind', d.kind, 'expires_on', d.expires_on) order by d.expires_on)
      from vehicle_documents d join vehicles v on v.id = d.vehicle_id where d.company_id = cid and v.status <> 'disposed' and d.expires_on <= current_date + 30
        and not exists (select 1 from vehicle_documents d2 where d2.vehicle_id = d.vehicle_id and d2.kind = d.kind and d2.expires_on > d.expires_on)), '[]'::jsonb),
    'licences_due', coalesce((select jsonb_agg(jsonb_build_object('name', e.full_name, 'licence_expiry', r.licence_expiry) order by r.licence_expiry)
      from drivers r join employees e on e.id = r.employee_id where r.company_id = cid and r.active and r.licence_expiry <= current_date + 30), '[]'::jsonb));
end $$;

create or replace function public.run_fleet_reminders() returns int
language plpgsql security definer set search_path = public as $$
declare r record; n int := 0;
begin
  for r in select d.*, v.reg_no from vehicle_documents d join vehicles v on v.id = d.vehicle_id
            where v.status <> 'disposed' and d.expires_on is not null and d.expires_on <= current_date + 30
              and not exists (select 1 from vehicle_documents d2 where d2.vehicle_id = d.vehicle_id and d2.kind = d.kind and d2.expires_on > d.expires_on)
              and (d.reminded_for is null or (d.expires_on < current_date and d.reminded_for >= d.expires_on - 30 and d.reminded_for < d.expires_on) or (d.expires_on - current_date <= 7 and d.reminded_for > d.expires_on - 7)) is not false
              and coalesce(d.reminded_for, '1900-01-01') <> current_date loop
    if r.reminded_for is null or (r.expires_on < current_date and r.reminded_for < r.expires_on) or (r.expires_on - current_date <= 7 and r.reminded_for < r.expires_on - 7) then
      perform notify_users(r.company_id, transport_users(r.company_id), 'fleet_document', r.reg_no || ': ' || replace(r.kind, '_', ' ') || case when r.expires_on < current_date then ' has expired' else ' expires ' || to_char(r.expires_on, 'DD Mon YYYY') end, r.reference, '/fleet/vehicles', true);
      perform send_telegram(r.company_id, 'fleet', '📄 ' || r.reg_no || ': ' || replace(r.kind, '_', ' ') || case when r.expires_on < current_date then ' has EXPIRED' else ' expires ' || to_char(r.expires_on, 'DD Mon YYYY') end);
      update vehicle_documents set reminded_for = current_date where id = r.id; n := n + 1;
    end if;
  end loop;
  for r in select d.*, e.full_name, e.user_id from drivers d join employees e on e.id = d.employee_id
            where d.active and d.licence_expiry is not null and d.licence_expiry <= current_date + 30 and (d.reminded_for is null or d.reminded_for < d.licence_expiry - 30 or (d.licence_expiry < current_date and d.reminded_for < d.licence_expiry)) loop
    perform notify_users(r.company_id, transport_users(r.company_id) || array[r.user_id], 'driver_licence', r.full_name || '''s driving licence ' || case when r.licence_expiry < current_date then 'has expired' else 'expires ' || to_char(r.licence_expiry, 'DD Mon YYYY') end, null, '/fleet/drivers', true);
    update drivers set reminded_for = current_date where id = r.id; n := n + 1;
  end loop;
  for r in select l.* from software_licences l where l.expires_on is not null and l.expires_on <= current_date + 30 and (l.reminded_on is null or (l.expires_on < current_date and l.reminded_on < l.expires_on)) loop
    perform notify(r.company_id, array['store'], null, 'licence_expiry', 'Licence ' || r.name || case when r.expires_on < current_date then ' has expired' else ' expires ' || to_char(r.expires_on, 'DD Mon YYYY') end, null, '/assets/licences', true);
    update software_licences set reminded_on = current_date where id = r.id; n := n + 1;
  end loop;
  return n;
end $$;
revoke execute on function public.run_fleet_reminders() from public, anon, authenticated;

create or replace function public.run_all_cash_reminders() returns int
language plpgsql security definer set search_path = public as $$
declare c record; n int := 0;
begin
  for c in select id from companies loop
    begin n := n + coalesce(run_cash_reminders_internal(c.id), 0); exception when others then null; end;
  end loop;
  begin n := n + coalesce(run_project_hold_reminders(), 0); exception when others then null; end;
  begin n := n + coalesce(run_hse_reminders(), 0); exception when others then null; end;
  begin n := n + coalesce(run_hr_reminders(), 0); exception when others then null; end;
  begin n := n + coalesce(run_fleet_reminders(), 0); exception when others then null; end;
  return n;
end $$;
revoke execute on function public.run_all_cash_reminders() from public, anon, authenticated;

-- New companies get a Head office location.
create or replace function public.company_seed_assets() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform set_config('sika.seed', 'on', true);
  insert into asset_locations (company_id, name, kind) values (new.id, 'Head office', 'head_office') on conflict do nothing;
  perform set_config('sika.seed', 'off', true);
  return null;
end $$;
create trigger companies_seed_assets after insert on public.companies for each row execute function public.company_seed_assets();

-- ---------------------------------------------------------------- 11. Security rules
do $$ declare t text; begin
  foreach t in array array['company_telegram','asset_locations','asset_transfers','asset_items','asset_item_stock','asset_item_moves','asset_item_checkouts',
                           'software_licences','licence_seats','vehicles','vehicle_documents','drivers','vehicle_requests','vehicle_trips','vehicle_fuel','vehicle_services','waybills','waybill_lines'] loop
    execute format('alter table public.%I enable row level security', t);
    if t <> 'company_telegram' then execute format('create policy "members read" on public.%I for select using (is_member(company_id))', t); end if;
  end loop;
end $$;
create policy "owners manage telegram" on public.company_telegram for all using (has_role(company_id, array['owner','admin'])) with check (has_role(company_id, array['owner','admin']));
create policy "store edits asset details" on public.assets for update using (asset_manager(company_id)) with check (asset_manager(company_id));
create policy "locations write" on public.asset_locations for all using (asset_manager(company_id)) with check (asset_manager(company_id));
create policy "items write" on public.asset_items for all using (asset_manager(company_id)) with check (asset_manager(company_id));
create policy "licences write" on public.software_licences for all using (asset_manager(company_id)) with check (asset_manager(company_id));
create policy "seats write" on public.licence_seats for all using (asset_manager(company_id)) with check (is_member(company_id));
create policy "fleet write vehicles" on public.vehicles for all using (is_transport(company_id)) with check (is_transport(company_id));
create policy "fleet write documents" on public.vehicle_documents for all using (is_transport(company_id)) with check (is_transport(company_id));
create policy "fleet write drivers" on public.drivers for all using (is_transport(company_id)) with check (is_transport(company_id));
create policy "fleet write services" on public.vehicle_services for all using (is_transport(company_id)) with check (is_transport(company_id));
create policy "anyone requests a vehicle" on public.vehicle_requests for insert with check (is_member(company_id));
create policy "requests update" on public.vehicle_requests for update using (is_member(company_id));
create policy "trips insert" on public.vehicle_trips for insert with check (is_member(company_id));
create policy "trips edit" on public.vehicle_trips for update using (is_transport(company_id));
create policy "fuel insert" on public.vehicle_fuel for insert with check (true);
create policy "fuel delete" on public.vehicle_fuel for delete using (is_transport(company_id));
create policy "waybills insert" on public.waybills for insert with check (is_member(company_id));
create policy "waybills edit" on public.waybills for update using (is_member(company_id));
create policy "waybills delete drafts" on public.waybills for delete using (status = 'draft' and is_transport(company_id));
create policy "waybill lines" on public.waybill_lines for all using (is_member(company_id)) with check (true);

do $$ declare t text; begin
  foreach t in array array['asset_locations','asset_transfers','asset_items','asset_item_moves','software_licences','licence_seats','vehicles','vehicle_documents','drivers','vehicle_fuel','vehicle_services','waybills'] loop
    execute format('create trigger %I after insert or update or delete on public.%I for each row execute function public.audit_row()', t || '_audit', t);
  end loop;
end $$;
revoke execute on function public.transport_users(uuid) from public, anon, authenticated;

-- ================================================================ 0019_asnys_v3_1_1.sql
-- Asnys ERP v3.1.1 — Fleet reminders reach admins as well as transport officers
--   * Roadworthy, insurance, road use, permits and statutory inspections: reminders 30 days before, 7 days before,
--     and on expiry, then every 7 days while it stays expired. Sent to transport officers, the storekeeper,
--     owners and admins (and the vehicle's driver when it has expired).
--   * New document kind: statutory inspection (crane, lifting gear, pressure vessel, fire extinguishers on the vehicle).
--   * Each company can choose how many days ahead the first reminder goes (default 30).
--   * Drivers' licences and medicals are reminded the same way.
-- Run after 0018. Safe to run more than once.

alter table public.vehicle_documents drop constraint if exists vehicle_documents_kind_check;
alter table public.vehicle_documents add constraint vehicle_documents_kind_check
  check (kind in ('roadworthy','insurance','road_use','registration','permit','tracker','inspection','fire_extinguisher','other'));
alter table public.companies add column if not exists fleet_reminder_days int not null default 30 check (fleet_reminder_days between 1 and 120);
alter table public.drivers add column if not exists medical_reminded_for date;

-- Who hears about fleet papers: transport officers, the storekeeper, owners and admins.
create or replace function public.fleet_alert_users(cid uuid) returns uuid[]
language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(user_id), '{}') from memberships where company_id = cid and (transport or role in ('store','owner','admin'));
$$;
revoke execute on function public.fleet_alert_users(uuid) from public, anon, authenticated;

-- One reminder per stage: first warning, final week, expiry, then weekly while expired.
create or replace function public.fleet_reminder_due(p_expires date, p_last date, p_lead int) returns boolean
language sql immutable as $$
  select p_expires is not null and p_expires <= current_date + p_lead and coalesce(p_last, '1900-01-01') < current_date and (
       p_last is null
    or p_last < p_expires - p_lead
    or (p_expires - current_date <= 7 and p_last < p_expires - 7)
    or (p_expires <= current_date and p_last < p_expires)
    or (p_expires < current_date and p_last <= current_date - 7));
$$;

create or replace function public.run_fleet_reminders() returns int
language plpgsql security definer set search_path = public as $$
declare r record; n int := 0; v_title text; v_kind text;
begin
  for r in select d.*, v.reg_no, v.driver_id as v_driver, c.fleet_reminder_days lead
             from vehicle_documents d join vehicles v on v.id = d.vehicle_id join companies c on c.id = d.company_id
            where v.status <> 'disposed' and d.expires_on is not null
              and not exists (select 1 from vehicle_documents d2 where d2.vehicle_id = d.vehicle_id and d2.kind = d.kind and d2.expires_on > d.expires_on)
              and fleet_reminder_due(d.expires_on, d.reminded_for, c.fleet_reminder_days) loop
    v_kind := case r.kind when 'roadworthy' then 'Roadworthy certificate' when 'insurance' then 'Insurance' when 'road_use' then 'Road use fee'
                          when 'inspection' then 'Statutory inspection' when 'fire_extinguisher' then 'Fire extinguisher service' else initcap(replace(r.kind, '_', ' ')) end;
    v_title := r.reg_no || ': ' || v_kind || case when r.expires_on < current_date then ' EXPIRED on ' || to_char(r.expires_on, 'DD Mon YYYY')
                                                  when r.expires_on = current_date then ' expires TODAY'
                                                  else ' due ' || to_char(r.expires_on, 'DD Mon YYYY') || ' (' || (r.expires_on - current_date) || ' days)' end;
    perform notify_users(r.company_id, fleet_alert_users(r.company_id)
      || case when r.expires_on <= current_date then array[(select user_id from employees where id = r.v_driver)] else '{}'::uuid[] end,
      'fleet_document', v_title, coalesce('Ref ' || r.reference, '') || case when r.expires_on < current_date then ' — do not use the vehicle on the road until renewed.' else '' end,
      '/fleet/vehicles/' || r.vehicle_id, true);
    perform send_telegram(r.company_id, 'fleet', case when r.expires_on <= current_date then '🚫 ' else '📄 ' end || v_title);
    update vehicle_documents set reminded_for = current_date where id = r.id; n := n + 1;
  end loop;

  for r in select d.*, e.full_name, e.user_id, c.fleet_reminder_days lead from drivers d join employees e on e.id = d.employee_id join companies c on c.id = d.company_id
            where d.active and fleet_reminder_due(d.licence_expiry, d.reminded_for, c.fleet_reminder_days) loop
    perform notify_users(r.company_id, fleet_alert_users(r.company_id) || array[r.user_id], 'driver_licence',
      r.full_name || '''s driving licence ' || case when r.licence_expiry < current_date then 'EXPIRED on ' || to_char(r.licence_expiry, 'DD Mon YYYY') else 'expires ' || to_char(r.licence_expiry, 'DD Mon YYYY') end,
      'Renew at DVLA.', '/fleet/drivers', true);
    perform send_telegram(r.company_id, 'fleet', '🪪 ' || r.full_name || '''s driving licence ' || case when r.licence_expiry < current_date then 'has EXPIRED' else 'expires ' || to_char(r.licence_expiry, 'DD Mon YYYY') end);
    update drivers set reminded_for = current_date where id = r.id; n := n + 1;
  end loop;

  for r in select d.*, e.full_name, e.user_id, c.fleet_reminder_days lead from drivers d join employees e on e.id = d.employee_id join companies c on c.id = d.company_id
            where d.active and fleet_reminder_due(d.medical_expiry, d.medical_reminded_for, c.fleet_reminder_days) loop
    perform notify_users(r.company_id, fleet_alert_users(r.company_id) || array[r.user_id], 'driver_licence',
      r.full_name || '''s driver medical ' || case when r.medical_expiry < current_date then 'has expired' else 'is due ' || to_char(r.medical_expiry, 'DD Mon YYYY') end, null, '/fleet/drivers', true);
    update drivers set medical_reminded_for = current_date where id = r.id; n := n + 1;
  end loop;

  for r in select l.* from software_licences l where l.expires_on is not null and l.expires_on <= current_date + 30 and (l.reminded_on is null or (l.expires_on < current_date and l.reminded_on < l.expires_on)) loop
    perform notify(r.company_id, array['store'], null, 'licence_expiry', 'Licence ' || r.name || case when r.expires_on < current_date then ' has expired' else ' expires ' || to_char(r.expires_on, 'DD Mon YYYY') end, null, '/assets/licences', true);
    update software_licences set reminded_on = current_date where id = r.id; n := n + 1;
  end loop;
  return n;
end $$;
revoke execute on function public.run_fleet_reminders() from public, anon, authenticated;

-- A renewed or corrected expiry date starts the reminders afresh.
create or replace function public.vehicle_document_reset() returns trigger
language plpgsql as $$
begin
  if new.expires_on is distinct from old.expires_on then new.reminded_for := null; end if;
  return new;
end $$;
drop trigger if exists vehicle_documents_reset on public.vehicle_documents;
create trigger vehicle_documents_reset before update on public.vehicle_documents for each row execute function public.vehicle_document_reset();

-- Owners or admins choose how far ahead the first reminder goes.
create or replace function public.set_fleet_reminder_days(cid uuid, p_days int) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not has_role(cid, array['owner','admin']) then raise exception 'Only an owner or admin can change this'; end if;
  if p_days not between 1 and 120 then raise exception 'Choose between 1 and 120 days'; end if;
  update companies set fleet_reminder_days = p_days where id = cid;
end $$;
