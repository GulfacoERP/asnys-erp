-- Asnys ERP: new installation, part3 of 3.
-- Contains 0010_asnys_v2_4.sql, 0011_asnys_v2_5.sql, 0012_asnys_v2_6.sql, 0013_asnys_v2_7.sql. Run part 1, then part 2, then part 3, once each, in a new Supabase project.


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

