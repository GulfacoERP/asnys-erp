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
