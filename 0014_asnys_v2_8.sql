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
