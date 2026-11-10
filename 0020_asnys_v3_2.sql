-- Asnys ERP v3.2 — Approvals reach people on Telegram and by email; HR creates logins with temporary passwords
--   1. Every approval in the system raises a notification to the people who must decide, and tells the requester
--      the outcome. Flows that had no notification now have one: the approval chain (bills, payroll, purchase orders,
--      purchase requests and expense claims above the limits), site purchase requests, expense claims, timesheets,
--      training requests, document reviews and stock requests from sites.
--   2. Each person can connect their own Telegram (a private chat with the company's bot). Notifications go to
--      them personally, not to a group. Everyone chooses: all notifications, approvals only, or none.
--   3. Approval emails through Brevo's API (an API key and a verified sender address; no SMTP needed).
--   4. HR and admins can create logins with a temporary password and reset passwords (with the updated
--      invite-member function). People must choose their own password at first sign-in.
-- Telegram and email need the pg_net extension (Database → Extensions → pg_net). Without it, everything else
-- works and the in-app notifications are unchanged.
-- Run after 0019.

-- ---------------------------------------------------------------- 0. Sending through pg_net (skipped quietly when it is off)
create or replace function public.http_post_safe(p_url text, p_body jsonb, p_headers jsonb default '{"Content-Type":"application/json"}') returns bigint
language plpgsql security definer set search_path = public as $$
declare v bigint;
begin
  if to_regnamespace('net') is null then return null; end if;
  begin
    execute 'select net.http_post(url := $1, body := $2, headers := $3)' into v using p_url, p_body, p_headers;
  exception when others then return null;
  end;
  return v;
end $$;
revoke execute on function public.http_post_safe(text, jsonb, jsonb) from public, anon, authenticated;

-- ---------------------------------------------------------------- 1. Company settings
alter table public.company_telegram add column if not exists bot_username text;
alter table public.company_telegram add column if not exists personal boolean not null default true;   -- private messages to people who connect
alter table public.company_telegram add column if not exists app_url text not null default 'https://asnys-erp.pages.dev';
alter table public.company_telegram add column if not exists last_update_id bigint;
-- The group chat is now optional: "enabled" switches the group on; private messages only need the bot token.

create table if not exists public.company_email (
  company_id uuid primary key references public.companies(id) on delete cascade,
  provider text not null default 'brevo' check (provider in ('brevo')),
  api_key text,
  from_email text,
  from_name text,
  enabled boolean not null default false,
  updated_at timestamptz not null default now()
);
alter table public.company_email enable row level security;
drop policy if exists "owners manage email" on public.company_email;
create policy "owners manage email" on public.company_email for all using (has_role(company_id, array['owner','admin'])) with check (has_role(company_id, array['owner','admin']));

-- ---------------------------------------------------------------- 2. Each person's channels
create table if not exists public.user_channels (
  company_id uuid not null references public.companies(id) on delete cascade,
  user_id uuid not null,
  telegram_chat_id text,
  telegram_username text,
  telegram_linked_at timestamptz,
  telegram_code text,
  telegram_code_at timestamptz,
  telegram_poll_id bigint,
  telegram_poll_at timestamptz,
  telegram_level text not null default 'all' check (telegram_level in ('all','approvals','off')),
  email_level text not null default 'approvals' check (email_level in ('all','approvals','off')),
  updated_at timestamptz not null default now(),
  primary key (company_id, user_id)
);
alter table public.user_channels enable row level security;
drop policy if exists "own channels" on public.user_channels;
create policy "own channels" on public.user_channels for select using (user_id = auth.uid() or has_role(company_id, array['owner','admin']));

create table if not exists public.message_log (
  id bigserial primary key,
  company_id uuid not null references public.companies(id) on delete cascade,
  user_id uuid,
  channel text not null check (channel in ('telegram','email')),
  notification_id uuid,
  title text,
  request_id bigint,
  status text not null default 'queued' check (status in ('queued','skipped')),
  note text,
  created_at timestamptz not null default now()
);
create index if not exists message_log_company on public.message_log (company_id, created_at desc);
alter table public.message_log enable row level security;
drop policy if exists "admins read log" on public.message_log;
create policy "admins read log" on public.message_log for select using (has_role(company_id, array['owner','admin']) or user_id = auth.uid());

-- My settings (and whether the company has Telegram and email set up), for the Notifications page.
create or replace function public.my_channels(cid uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare uc user_channels; t company_telegram; e company_email;
begin
  perform require_member(cid);
  select * into uc from user_channels where company_id = cid and user_id = auth.uid();
  select * into t from company_telegram where company_id = cid;
  select * into e from company_email where company_id = cid;
  return jsonb_build_object(
    'telegram_ready', t.bot_token is not null and t.personal and t.bot_username is not null,
    'bot_username', t.bot_username,
    'email_ready', coalesce(e.enabled, false) and e.api_key is not null and e.from_email is not null,
    'pg_net', to_regnamespace('net') is not null,
    'telegram_linked', uc.telegram_chat_id is not null,
    'telegram_username', uc.telegram_username,
    'telegram_linked_at', uc.telegram_linked_at,
    'telegram_level', coalesce(uc.telegram_level, 'all'),
    'email_level', coalesce(uc.email_level, 'approvals'),
    'email', (select coalesce(m.email, u.email) from memberships m left join auth.users u on u.id = m.user_id where m.company_id = cid and m.user_id = auth.uid()));
end $$;

create or replace function public.set_my_channels(cid uuid, p_telegram_level text, p_email_level text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform require_member(cid);
  if p_telegram_level not in ('all','approvals','off') or p_email_level not in ('all','approvals','off') then raise exception 'Choose all, approvals or off'; end if;
  insert into user_channels (company_id, user_id, telegram_level, email_level) values (cid, auth.uid(), p_telegram_level, p_email_level)
  on conflict (company_id, user_id) do update set telegram_level = excluded.telegram_level, email_level = excluded.email_level, updated_at = now();
end $$;

-- ---------------------------------------------------------------- 3. Which notifications are approvals
-- Requests that wait for someone's decision, and the decisions that go back to the person who asked.
create or replace function public.is_approval_kind(p_kind text) returns boolean
language sql immutable as $$
  select p_kind = any(array[
      'approval_needed','approval_decided','request_submitted','request_decided','expense_submitted','expense_decided',
      'time_submitted','time_decided','training_request','training_decided','doc_review','doc_reviewed','stock_request',
      'leave_request','leave_decided','hr_profile_change','hr_profile_decided','asset_requested','asset_request_decided',
      'asset_transfer','vehicle_request','spend_request','spend_request_done','budget.submitted','budget.decided',
      'progress.submitted','retirement_submitted','retirement_returned','variation_proposed','variation_decided',
      'tender.review','project.registered','hse_permit','hse_action_done','hse_investigate','petty_count_difference'])
    or p_kind like 'spend_request\_%' or p_kind like 'asset_transfer\_%' or p_kind like 'hse_permit\_%';
$$;

-- ---------------------------------------------------------------- 4. Delivery: every new notification goes to Telegram and email as each person chose
create or replace function public.tg_escape(t text) returns text language sql immutable as $$
  select replace(replace(replace(coalesce(t, ''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;');
$$;

create or replace function public.deliver_notification() returns trigger
language plpgsql security definer set search_path = public as $$
declare uc user_channels; t company_telegram; e company_email; v_appr boolean; v_url text; v_email text; v_req bigint; v_text text;
begin
  begin
    select * into t from company_telegram where company_id = new.company_id;
    select * into e from company_email where company_id = new.company_id;
    if t.company_id is null and e.company_id is null then return null; end if;
    select * into uc from user_channels where company_id = new.company_id and user_id = new.user_id;
    v_appr := is_approval_kind(new.kind);
    v_url := rtrim(coalesce(t.app_url, 'https://asnys-erp.pages.dev'), '/') || coalesce(new.path, '/notifications');

    -- Telegram, privately
    if t.bot_token is not null and t.personal and uc.telegram_chat_id is not null
       and (uc.telegram_level = 'all' or (uc.telegram_level = 'approvals' and v_appr)) then
      v_text := case when v_appr then '🔔 ' else '' end || '<b>' || tg_escape(new.title) || '</b>'
             || coalesce(E'\n' || tg_escape(new.body), '') || E'\n\n<a href="' || tg_escape(v_url) || '">' || case when v_appr then 'Open and decide' else 'Open in Asnys' end || '</a>';
      v_req := http_post_safe('https://api.telegram.org/bot' || t.bot_token || '/sendMessage',
        jsonb_build_object('chat_id', uc.telegram_chat_id, 'text', left(v_text, 4000), 'parse_mode', 'HTML', 'disable_web_page_preview', true));
      insert into message_log (company_id, user_id, channel, notification_id, title, request_id, status, note)
      values (new.company_id, new.user_id, 'telegram', new.id, new.title, v_req, case when v_req is null then 'skipped' else 'queued' end, case when v_req is null then 'pg_net is off' end);
    end if;

    -- Email through Brevo
    if coalesce(e.enabled, false) and e.api_key is not null and e.from_email is not null
       and (coalesce(uc.email_level, 'approvals') = 'all' or (coalesce(uc.email_level, 'approvals') = 'approvals' and v_appr)) then
      select coalesce(m.email, u.email) into v_email from memberships m left join auth.users u on u.id = m.user_id where m.company_id = new.company_id and m.user_id = new.user_id;
      if v_email is not null then
        v_req := http_post_safe('https://api.brevo.com/v3/smtp/email',
          jsonb_build_object(
            'sender', jsonb_build_object('email', e.from_email, 'name', coalesce(e.from_name, (select name from companies where id = new.company_id))),
            'to', jsonb_build_array(jsonb_build_object('email', v_email)),
            'subject', left(case when v_appr then '[Action] ' else '' end || new.title, 200),
            'htmlContent', '<div style="font-family:Arial,sans-serif;font-size:15px;color:#17231e">'
              || '<p style="margin:0 0 8px"><b>' || tg_escape(new.title) || '</b></p>'
              || coalesce('<p style="margin:0 0 16px;white-space:pre-wrap">' || tg_escape(new.body) || '</p>', '')
              || '<p><a href="' || tg_escape(v_url) || '" style="background:#1d6b55;color:#fff;padding:10px 16px;border-radius:8px;text-decoration:none;display:inline-block">'
              || case when v_appr then 'Open and decide' else 'Open in Asnys ERP' end || '</a></p>'
              || '<p style="color:#5b6b63;font-size:12px">Sent by Asnys ERP for ' || tg_escape((select name from companies where id = new.company_id))
              || '. Change what you receive under Notifications → Settings.</p></div>',
            'textContent', new.title || coalesce(E'\n' || new.body, '') || E'\n\n' || v_url),
          jsonb_build_object('api-key', e.api_key, 'Content-Type', 'application/json', 'accept', 'application/json'));
        insert into message_log (company_id, user_id, channel, notification_id, title, request_id, status, note)
        values (new.company_id, new.user_id, 'email', new.id, new.title, v_req, case when v_req is null then 'skipped' else 'queued' end, case when v_req is null then 'pg_net is off' else v_email end);
      end if;
    end if;
  exception when others then
    null;   -- sending must never stop the work that raised the notification
  end;
  return null;
end $$;
drop trigger if exists notifications_deliver on public.notifications;
create trigger notifications_deliver after insert on public.notifications for each row execute function public.deliver_notification();

-- ---------------------------------------------------------------- 5. Connecting a person's Telegram
-- The app opens t.me/<bot>?start=<code>; the person presses Start; the app then asks the database to look for it.
create or replace function public.telegram_link_start(cid uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t company_telegram; v_code text := substr(md5(gen_random_uuid()::text || clock_timestamp()::text), 1, 12);
begin
  perform require_member(cid);
  select * into t from company_telegram where company_id = cid;
  if t.bot_token is null or t.bot_username is null then raise exception 'Telegram is not set up for this company yet. Ask an owner or admin to add the bot under Settings → Telegram & email.'; end if;
  insert into user_channels (company_id, user_id, telegram_code, telegram_code_at) values (cid, auth.uid(), v_code, now())
  on conflict (company_id, user_id) do update set telegram_code = v_code, telegram_code_at = now(), telegram_poll_id = null, updated_at = now();
  return jsonb_build_object('code', v_code, 'url', 'https://t.me/' || ltrim(t.bot_username, '@') || '?start=' || v_code, 'bot_username', ltrim(t.bot_username, '@'));
end $$;

-- Reads Telegram's reply to an earlier getUpdates, links anyone in this company who pressed Start with their code,
-- then asks again. Returns linked, pending or expired.
create or replace function public.telegram_link_check(cid uuid) returns text
language plpgsql security definer set search_path = public as $$
declare uc user_channels; t company_telegram; v_content text; v_json jsonb; u jsonb; v_text text; v_code text; v_max bigint; v_chat text; r record; v_req bigint;
begin
  perform require_member(cid);
  select * into uc from user_channels where company_id = cid and user_id = auth.uid();
  if uc.telegram_chat_id is not null then return 'linked'; end if;
  if uc.telegram_code is null then raise exception 'Press Connect Telegram first'; end if;
  if uc.telegram_code_at < now() - interval '30 minutes' then return 'expired'; end if;
  select * into t from company_telegram where company_id = cid;
  if t.bot_token is null then raise exception 'Telegram is not set up for this company'; end if;
  if to_regnamespace('net') is null then raise exception 'Turn on the pg_net extension in Supabase (Database → Extensions → pg_net) first'; end if;

  if uc.telegram_poll_id is not null then
    begin
      execute 'select content from net._http_response where id = $1' into v_content using uc.telegram_poll_id;
    exception when others then v_content := null;
    end;
    if v_content is null and uc.telegram_poll_at > now() - interval '15 seconds' then return 'pending'; end if;
    update user_channels set telegram_poll_id = null where company_id = cid and user_id = auth.uid();
    if v_content is not null then
      begin v_json := v_content::jsonb; exception when others then v_json := null; end;
      v_max := t.last_update_id;
      for u in select * from jsonb_array_elements(coalesce(v_json->'result', '[]'::jsonb)) loop
        v_max := greatest(coalesce(v_max, 0), (u->>'update_id')::bigint);
        v_text := u->'message'->>'text';
        if v_text like '/start %' then
          v_code := trim(split_part(v_text, ' ', 2));
          v_chat := u->'message'->'chat'->>'id';
          for r in update user_channels set telegram_chat_id = v_chat, telegram_username = u->'message'->'from'->>'username', telegram_linked_at = now(),
                     telegram_code = null, updated_at = now()
                    where company_id = cid and telegram_code = v_code and telegram_chat_id is null returning user_id loop
            perform http_post_safe('https://api.telegram.org/bot' || t.bot_token || '/sendMessage',
              jsonb_build_object('chat_id', v_chat, 'text', '✅ Connected to Asnys ERP for ' || (select name from companies where id = cid)
                || '. You will get your approvals and notifications here. Change what you receive in Asnys under Notifications → Settings.'));
          end loop;
        end if;
      end loop;
      if v_max is distinct from t.last_update_id then update company_telegram set last_update_id = v_max where company_id = cid; end if;
      if exists (select 1 from user_channels where company_id = cid and user_id = auth.uid() and telegram_chat_id is not null) then return 'linked'; end if;
    end if;
  end if;

  execute 'select net.http_get(url := $1)' into v_req
    using 'https://api.telegram.org/bot' || t.bot_token || '/getUpdates?timeout=0&offset=' || coalesce((select last_update_id from company_telegram where company_id = cid) + 1, 0);
  update user_channels set telegram_poll_id = v_req, telegram_poll_at = now() where company_id = cid and user_id = auth.uid();
  return 'pending';
end $$;

create or replace function public.telegram_unlink(cid uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform require_member(cid);
  update user_channels set telegram_chat_id = null, telegram_username = null, telegram_linked_at = null, telegram_code = null, updated_at = now()
   where company_id = cid and user_id = auth.uid();
end $$;

-- Sends me a test on each channel I have.
create or replace function public.test_my_channels(cid uuid) returns text
language plpgsql security definer set search_path = public as $$
begin
  perform require_member(cid);
  if to_regnamespace('net') is null then raise exception 'Turn on the pg_net extension in Supabase (Database → Extensions → pg_net) first'; end if;
  insert into notifications (company_id, user_id, kind, title, body, path)
  values (cid, auth.uid(), 'approval_needed', 'Test: this is how an approval looks', 'Nothing to do; this is a test from Notifications → Settings.', '/notifications');
  return 'sent';
end $$;

-- Owners and admins: how many people have connected.
create or replace function public.channel_overview(cid uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not has_role(cid, array['owner','admin']) then raise exception 'Only an owner or admin can see this'; end if;
  return jsonb_build_object(
    'members', (select count(*) from memberships where company_id = cid),
    'telegram_linked', (select count(*) from user_channels where company_id = cid and telegram_chat_id is not null),
    'email_off', (select count(*) from user_channels where company_id = cid and email_level = 'off'),
    'last_24h', (select coalesce(jsonb_object_agg(channel, n), '{}') from (select channel, count(*) n from message_log where company_id = cid and created_at > now() - interval '1 day' group by channel) x),
    'people', coalesce((select jsonb_agg(jsonb_build_object('email', coalesce(m.email, u.email), 'role', m.role, 'telegram', c.telegram_chat_id is not null,
                 'telegram_level', coalesce(c.telegram_level, 'all'), 'email_level', coalesce(c.email_level, 'approvals')) order by coalesce(m.email, u.email))
               from memberships m left join auth.users u on u.id = m.user_id left join user_channels c on c.company_id = m.company_id and c.user_id = m.user_id
              where m.company_id = cid), '[]'));
end $$;

-- ---------------------------------------------------------------- 6. Approval notifications for the flows that had none
-- 6a. The approval chain (bills, payroll, purchase orders, purchase requests and expense claims above the limits).
alter table public.approval_steps add column if not exists notified_at timestamptz;

create or replace function public.step_approvers(s approval_steps) returns uuid[]
language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(distinct u), '{}') from (
    select s.approver_user u where s.approver_user is not null
    union select m.user_id from memberships m where m.company_id = s.company_id and s.approver_role is not null and m.role = s.approver_role
    union select m.user_id from memberships m where m.company_id = s.company_id and m.role = 'owner'
      and not exists (select 1 from memberships x where x.company_id = s.company_id and ((s.approver_role is not null and x.role = s.approver_role) or x.user_id = s.approver_user))
  ) x where u is not null and not exists (select 1 from approval_steps o where o.doc_type = s.doc_type and o.doc_id = s.doc_id and o.status = 'approved' and o.decided_by = u);
$$;

create or replace function public.approval_step_notice() returns trigger
language plpgsql security definer set search_path = public as $$
declare cur approval_steps; d record; v_left int; v_rej boolean; v_amt text;
begin
  if new.doc_type = 'spend_request' then return null; end if;   -- spend requests already notify themselves
  select * into d from doc_info(new.doc_type, new.doc_id);
  v_amt := case when new.amount is not null then ' (GH₵ ' || to_char(new.amount, 'FM999,999,999,990.00') || ')' else '' end;
  -- The step now waiting, if nobody has been told about it yet.
  select * into cur from approval_steps where doc_type = new.doc_type and doc_id = new.doc_id and status = 'pending' order by step_no limit 1;
  if found and cur.notified_at is null then
    update approval_steps set notified_at = now() where id = cur.id;
    perform notify_users(cur.company_id, step_approvers(cur), 'approval_needed',
      'Approval needed: ' || coalesce(d.label, replace(new.doc_type, '_', ' ')) || v_amt,
      'Step ' || cur.step_no || ' of ' || (select count(*) from approval_steps where doc_type = new.doc_type and doc_id = new.doc_id) || ': ' || cur.label
        || coalesce(' · asked by ' || (select email from memberships where company_id = cur.company_id and user_id = cur.requested_by), ''),
      '/approvals-inbox', false);
  end if;
  -- The outcome, back to whoever asked.
  if tg_op = 'UPDATE' and new.status is distinct from old.status and new.status in ('approved','rejected') then
    select count(*) filter (where status = 'pending'), bool_or(status = 'rejected') into v_left, v_rej from approval_steps where doc_type = new.doc_type and doc_id = new.doc_id;
    if new.status = 'rejected' or (v_left = 0 and not coalesce(v_rej, false)) then
      perform notify_users(new.company_id, array[new.requested_by], 'approval_decided',
        coalesce(d.label, replace(new.doc_type, '_', ' ')) || case when new.status = 'rejected' then ' was rejected' else ' is fully approved' end,
        case when new.status = 'rejected' then coalesce('Reason: ' || new.note, null) end, coalesce(d.path, '/approvals-inbox'), false);
    end if;
  end if;
  return null;
exception when others then return null;
end $$;
drop trigger if exists approval_steps_notice on public.approval_steps;
create trigger approval_steps_notice after insert or update on public.approval_steps for each row execute function public.approval_step_notice();

-- Project managers of a project, or Finance when there is none.
create or replace function public.project_deciders(cid uuid, pid uuid) returns uuid[]
language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(distinct u), '{}') from (
    select p.manager_id u from projects p where p.id = pid and p.manager_id is not null
    union select m.user_id from memberships m where m.company_id = cid and m.role = 'accountant'
      and (pid is null or not exists (select 1 from projects p where p.id = pid and p.manager_id is not null))
  ) x where u is not null;
$$;
revoke execute on function public.project_deciders(uuid, uuid) from public, anon, authenticated;
revoke execute on function public.step_approvers(approval_steps) from public, anon, authenticated;

-- 6b. Site purchase requests (first approval by the project manager).
create or replace function public.project_request_notice() returns trigger
language plpgsql security definer set search_path = public as $$
declare p projects;
begin
  select * into p from projects where id = new.project_id;
  if new.status = 'submitted' and (tg_op = 'INSERT' or old.status is distinct from 'submitted') then
    perform notify_users(new.company_id, project_deciders(new.company_id, new.project_id), 'request_submitted',
      coalesce(new.number, 'Purchase request') || ' needs approval: ' || coalesce(new.description, new.kind),
      concat_ws(' · ', p.number || ' ' || p.name, new.qty || ' × GH₵ ' || to_char(coalesce(new.est_unit_cost, 0), 'FM999,999,990.00'), new.requested_email), '/approvals', false);
  elsif tg_op = 'UPDATE' and new.status in ('approved','rejected') and old.status is distinct from new.status then
    perform notify_users(new.company_id, array[new.requested_by], 'request_decided',
      coalesce(new.number, 'Your request') || ' was ' || new.status, case when new.status = 'rejected' then 'Reason: ' || new.reject_reason end, '/my', false);
  end if;
  return null;
exception when others then return null;
end $$;
drop trigger if exists project_requests_notice on public.project_requests;
create trigger project_requests_notice after insert or update of status on public.project_requests for each row execute function public.project_request_notice();

-- 6c. Expense claims.
create or replace function public.expense_notice() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_who text;
begin
  select full_name into v_who from employees where id = new.employee_id;
  if new.status = 'submitted' and (tg_op = 'INSERT' or old.status is distinct from 'submitted') then
    perform notify_users(new.company_id, project_deciders(new.company_id, new.project_id), 'expense_submitted',
      'Expense claim to approve: ' || coalesce(v_who, 'staff') || ', GH₵ ' || to_char(coalesce(new.amount_home, new.amount, 0), 'FM999,999,990.00'),
      left(coalesce(new.description, ''), 300), '/approvals', false);
  elsif tg_op = 'UPDATE' and new.status in ('approved','rejected') and old.status is distinct from new.status then
    perform notify_users(new.company_id, array[new.submitted_by, (select user_id from employees where id = new.employee_id)], 'expense_decided',
      'Your expense claim of GH₵ ' || to_char(coalesce(new.amount_home, new.amount, 0), 'FM999,999,990.00') || ' was ' || new.status,
      case when new.status = 'rejected' then 'Reason: ' || new.reject_reason end, '/my', false);
  end if;
  return null;
exception when others then return null;
end $$;
drop trigger if exists expense_claims_notice on public.expense_claims;
create trigger expense_claims_notice after insert or update of status on public.expense_claims for each row execute function public.expense_notice();

-- 6d. Timesheets: one message per person, project and day, however many lines were submitted.
create or replace function public.timesheet_notice() returns trigger
language plpgsql security definer set search_path = public as $$
declare p projects; v_who text; v_user uuid;
begin
  select * into p from projects where id = new.project_id;
  select full_name, user_id into v_who, v_user from employees where id = new.employee_id;
  if new.status = 'submitted' and (tg_op = 'INSERT' or old.status is distinct from 'submitted') then
    if exists (select 1 from notifications n where n.company_id = p.company_id and n.kind = 'time_submitted' and n.read_at is null
                 and n.created_at > now() - interval '12 hours' and n.title = 'Time to approve: ' || coalesce(v_who, 'staff') || ' on ' || coalesce(p.number, p.name)) then
      return null;
    end if;
    perform notify_users(p.company_id, project_deciders(p.company_id, p.id), 'time_submitted',
      'Time to approve: ' || coalesce(v_who, 'staff') || ' on ' || coalesce(p.number, p.name), p.name, '/approvals', false);
  elsif tg_op = 'UPDATE' and new.status = 'rejected' and old.status = 'submitted' then
    perform notify_users(p.company_id, array[v_user, new.submitted_by], 'time_decided', 'Time rejected on ' || coalesce(p.number, p.name), 'Ask the project manager why, correct it and submit again.', '/my', false);
  end if;
  return null;
exception when others then return null;
end $$;
drop trigger if exists timesheets_notice on public.timesheets;
create trigger timesheets_notice after insert or update of status on public.timesheets for each row execute function public.timesheet_notice();

-- 6e. Training requests (HR decides).
create or replace function public.training_request_notice() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'submitted' and tg_op = 'INSERT' then
    perform notify_users(new.company_id, (select coalesce(array_agg(user_id), '{}') from memberships where company_id = new.company_id and role = 'hr'), 'training_request',
      coalesce(new.number, 'Training request') || ' to decide: ' || (select full_name from employees where id = new.employee_id), new.requested_email, '/training', false);
  elsif tg_op = 'UPDATE' and new.status in ('approved','rejected') and old.status is distinct from new.status then
    perform notify_users(new.company_id, array[new.requested_by, (select user_id from employees where id = new.employee_id)], 'training_decided',
      coalesce(new.number, 'Training request') || ' was ' || new.status, new.decision_note, '/training', false);
  end if;
  return null;
exception when others then return null;
end $$;
drop trigger if exists training_requests_notice on public.training_requests;
create trigger training_requests_notice after insert or update of status on public.training_requests for each row execute function public.training_request_notice();

-- 6f. Document revisions sent for review (project manager), and the result back to whoever uploaded it.
create or replace function public.doc_review_notice() returns trigger
language plpgsql security definer set search_path = public as $$
declare d doc_register; p projects;
begin
  select * into d from doc_register where id = new.doc_id;
  select * into p from projects where id = d.project_id;
  if new.status = 'in_review' and old.status is distinct from 'in_review' then
    perform notify_users(d.company_id, project_deciders(d.company_id, d.project_id), 'doc_review',
      'Document to review: ' || coalesce(d.number, '') || ' rev ' || coalesce(new.rev, '') || ' ' || coalesce(d.title, ''), coalesce(p.number || ' ' || p.name, ''),
      '/projects/' || d.project_id, false);
  elsif old.status = 'in_review' and new.status in ('approved','approved_comments','rejected','ready') then
    perform notify_users(d.company_id, array[new.uploaded_by], 'doc_reviewed',
      coalesce(d.number, 'Document') || ' rev ' || coalesce(new.rev, '') || ': ' || replace(new.status, '_', ' '), new.review_note, '/projects/' || d.project_id, false);
  end if;
  return null;
exception when others then return null;
end $$;
drop trigger if exists doc_revisions_notice on public.doc_revisions;
create trigger doc_revisions_notice after update of status on public.doc_revisions for each row execute function public.doc_review_notice();

-- 6g. Stock requests from sites (the storekeeper dispatches).
create or replace function public.stock_request_notice() returns trigger
language plpgsql security definer set search_path = public as $$
declare p projects;
begin
  select * into p from projects where id = new.project_id;
  if new.status = 'submitted' and (tg_op = 'INSERT' or old.status is distinct from 'submitted') then
    perform notify_users(new.company_id, (select coalesce(array_agg(user_id), '{}') from memberships where company_id = new.company_id and role = 'store'), 'stock_request',
      coalesce(new.number, 'Stock request') || ' from ' || coalesce(p.number || ' ' || p.name, 'a site') || ' to dispatch',
      concat_ws(' · ', new.requested_email, 'needed by ' || to_char(new.needed_by, 'DD Mon')), '/inventory/requests', false);
  elsif tg_op = 'UPDATE' and new.status = 'dispatched' and old.status is distinct from 'dispatched' then
    perform notify_users(new.company_id, array[new.requested_by], 'stock_request', coalesce(new.number, 'Your stock request') || ' has been dispatched', new.dispatch_note, '/inventory/requests', false);
  end if;
  return null;
exception when others then return null;
end $$;
drop trigger if exists stock_requests_notice on public.stock_requests;
create trigger stock_requests_notice after insert or update of status on public.stock_requests for each row execute function public.stock_request_notice();

-- ---------------------------------------------------------------- 7. Logins with a temporary password (used by the invite-member function)
-- Invitations to give a password to: their login, if one exists, and whether it has ever signed in.
create or replace function public.invites_for_password(cid uuid, p_ids uuid[])
returns table (id uuid, email text, role text, company_name text, user_id uuid, signed_in boolean)
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
begin
  perform require_member(cid, array['owner','admin','hr']);
  return query
    select i.id, i.email, i.role, c.name, u.id, u.last_sign_in_at is not null
      from member_invites i join companies c on c.id = i.company_id left join auth.users u on lower(u.email) = lower(i.email)
     where i.company_id = cid and i.id = any(p_ids) and i.status in ('pending','sent','failed') and can_invite(cid, i.role);
end $$;

-- Whether the caller may set a new password for this member. Owners and admins: anyone but the owner;
-- HR: staff only. Nobody resets their own this way. Logged.
create or replace function public.password_reset_target(cid uuid, p_user uuid) returns text
language plpgsql security definer set search_path = public as $$
declare m memberships; v_email text;
begin
  perform require_member(cid, array['owner','admin','hr']);
  select * into m from memberships where company_id = cid and user_id = p_user;
  if not found then raise exception 'That person is not in this company'; end if;
  if p_user = auth.uid() then raise exception 'Change your own password from your account menu'; end if;
  if m.role = 'owner' then raise exception 'The owner''s password cannot be reset by others'; end if;
  if not has_role(cid, array['owner','admin']) and m.role <> 'staff' then raise exception 'HR can reset passwords for staff only. Ask an admin.'; end if;
  select email into v_email from auth.users where id = p_user;
  insert into audit_log (company_id, action, table_name, row_id, detail) values (cid, 'password.reset', 'memberships', p_user, jsonb_build_object('email', v_email));
  return v_email;
end $$;

-- The app shows Set new password only where it is allowed.
create or replace function public.can_reset_password(cid uuid, p_role text, p_user uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select p_user is distinct from auth.uid() and p_role <> 'owner'
     and (has_role(cid, array['owner','admin']) or (p_role = 'staff' and has_role(cid, array['hr'])));
$$;


-- ---------------------------------------------------------------- 8. Activity log for the whole system
-- Secrets never go into the log.
create or replace function public.audit_row() returns trigger
language plpgsql security definer set search_path = public as $$
declare o jsonb; n jsonb; d_old jsonb := '{}'; d_new jsonb := '{}'; k text; cid uuid; rid uuid;
  ignore text[] := array['stock_qty','cost','score','sales_ready','updated_at','last_depreciated','accumulated_depreciation','percent_complete',
                         'telegram_poll_id','telegram_poll_at','reminded_for','reminded_on','notified_at'];
  secret text[] := array['bot_token','api_key','product_key','password','telegram_code','token','secret'];
begin
  if tg_op <> 'INSERT' then o := to_jsonb(old); end if;
  if tg_op <> 'DELETE' then n := to_jsonb(new); end if;
  cid := coalesce((n->>'company_id')::uuid, (o->>'company_id')::uuid, case when tg_table_name = 'companies' then coalesce((n->>'id')::uuid, (o->>'id')::uuid) end);
  begin rid := coalesce((n->>'id')::uuid, (o->>'id')::uuid); exception when others then rid := null; end;
  if tg_op = 'UPDATE' then
    for k in select jsonb_object_keys(n) loop
      if k <> all(ignore) and (o->k) is distinct from (n->k) then
        d_old := d_old || jsonb_build_object(k, o->k); d_new := d_new || jsonb_build_object(k, n->k);
      end if;
    end loop;
    if d_new = '{}'::jsonb then return null; end if;
    -- keep a name or number so the line says which record changed
    foreach k in array array['number','name','full_name','title','reg_no','tag','email','description'] loop
      if (to_jsonb(new)) ? k and not d_new ? k then d_new := d_new || jsonb_build_object('_label', to_jsonb(new)->k); exit; end if;
    end loop;
    o := d_old; n := d_new;
  end if;
  foreach k in array secret loop   -- a changed secret shows as changed, never its value
    if o ? k then o := o || jsonb_build_object(k, case when o->>k is null then null else '••••' end); end if;
    if n ? k then n := n || jsonb_build_object(k, case when n->>k is null then null else '••••' end); end if;
  end loop;
  insert into audit_log (company_id, action, table_name, row_id, old_data, new_data)
  values (cid, tg_table_name || '.' || lower(tg_op), tg_table_name, rid, o, n);
  return null;
end $$;

-- Every business table is logged, not only the money ones.
do $$ declare t text; begin
  for t in select c.table_name from information_schema.columns c join information_schema.tables x on x.table_schema = c.table_schema and x.table_name = c.table_name
            where c.table_schema = 'public' and c.column_name = 'company_id' and x.table_type = 'BASE TABLE'
              and c.table_name not in ('audit_log','notifications','message_log','user_channels','company_telegram','company_email','announcement_reads',
                                       'payment_reminders','journal_lines','asset_item_stock','esg_entries_cache')
              and not exists (select 1 from pg_trigger g join pg_proc p on p.oid = g.tgfoid where g.tgrelid = ('public.' || c.table_name)::regclass and p.proname = 'audit_row') loop
    execute format('create trigger %I after insert or update or delete on public.%I for each row execute function public.audit_row()', left(t, 50) || '_audit', t);
  end loop;
end $$;
-- Settings tables: logged, with their secrets hidden by audit_row.
do $$ declare t text; begin
  foreach t in array array['company_telegram','company_email'] loop
    if not exists (select 1 from pg_trigger g join pg_proc p on p.oid = g.tgfoid where g.tgrelid = ('public.' || t)::regclass and p.proname = 'audit_row') then
      execute format('create trigger %I after insert or update or delete on public.%I for each row execute function public.audit_row()', t || '_audit', t);
    end if;
  end loop;
end $$;

-- Sign-ins: recorded once per real sign-in (from the login time Supabase keeps).
alter table public.memberships add column if not exists last_sign_in_logged timestamptz;
create or replace function public.record_sign_in() returns int
language plpgsql security definer set search_path = public as $$
declare v_at timestamptz; v_email text; m record; n int := 0;
begin
  if auth.uid() is null then return 0; end if;
  select last_sign_in_at, email into v_at, v_email from auth.users where id = auth.uid();
  if v_at is null then return 0; end if;
  for m in select company_id from memberships where user_id = auth.uid() and (last_sign_in_logged is null or last_sign_in_logged < v_at) loop
    insert into audit_log (company_id, action, table_name, row_id, detail) values (m.company_id, 'user.signed_in', 'sign_in', auth.uid(), jsonb_build_object('email', v_email, 'at', v_at));
    update memberships set last_sign_in_logged = v_at where company_id = m.company_id and user_id = auth.uid();
    n := n + 1;
  end loop;
  return n;
end $$;

-- What has been logged, by area, for the filter list.
create or replace function public.audit_areas(cid uuid, p_from date, p_to date) returns table (table_name text, n bigint)
language sql stable security definer set search_path = public as $$
  select l.table_name, count(*) from audit_log l
   where l.company_id = cid and has_role(cid, array['owner','admin','accountant']) and l.created_at >= p_from and l.created_at < p_to + 1 and l.table_name is not null
   group by l.table_name order by 2 desc;
$$;

-- The trail, with an action filter (created, changed, deleted, sign-in, other).
create or replace function public.activity_log(cid uuid, p_from date, p_to date, p_table text default null, p_user text default null,
  p_search text default null, p_kind text default null, p_limit int default 100, p_offset int default 0)
returns table (id bigint, created_at timestamptz, user_email text, action text, table_name text, row_id uuid, old_data jsonb, new_data jsonb, detail jsonb, total bigint)
language sql stable security definer set search_path = public as $$
  select l.id, l.created_at, l.user_email, l.action, l.table_name, l.row_id, l.old_data, l.new_data, l.detail, count(*) over()
    from audit_log l
   where l.company_id = cid and has_role(cid, array['owner','admin','accountant'])
     and l.created_at >= p_from and l.created_at < p_to + 1
     and (p_table is null or l.table_name = p_table)
     and (p_user is null or l.user_email ilike '%' || p_user || '%')
     and (p_kind is null or (p_kind = 'insert' and l.action like '%.insert') or (p_kind = 'update' and l.action like '%.update')
          or (p_kind = 'delete' and l.action like '%.delete') or (p_kind = 'sign_in' and l.action = 'user.signed_in')
          or (p_kind = 'other' and l.action not like '%.insert' and l.action not like '%.update' and l.action not like '%.delete' and l.action <> 'user.signed_in'))
     and (p_search is null or l.action ilike '%' || p_search || '%' or coalesce(l.new_data::text,'') ilike '%' || p_search || '%'
          or coalesce(l.old_data::text,'') ilike '%' || p_search || '%' or coalesce(l.detail::text,'') ilike '%' || p_search || '%')
   order by l.created_at desc, l.id desc
   limit least(p_limit, 1000) offset p_offset;
$$;


-- ---------------------------------------------------------------- 9. Void entries made in error
-- Anything that has not been posted to the books can be voided with a reason. It stays on record (marked Voided,
-- with who, when and why) and drops out of totals, approvals and reminders. Posted money entries are corrected by
-- reversal instead: invoices with a credit note, bank and cash entries with Void, journals with Reverse.
create table if not exists public.void_rules (
  table_name text primary key,
  label text not null,
  from_status text[] not null,
  roles text[] not null,           -- who may void besides the person who entered it (owners and admins always can)
  creator_col text                 -- the column holding who entered it; that person may void their own
);
insert into public.void_rules (table_name, label, from_status, roles, creator_col) values
  ('tenders',              'Tender',              '{registered,preparing,review,submitted,no_bid,lost}', '{sales,accountant}', null),
  ('sales_quotes',         'Quote',               '{draft,sent,declined}',            '{sales,accountant}', null),
  ('purchase_orders',      'Purchase order',      '{draft,approved,sent}',            '{accountant,store}', 'created_by'),
  ('project_requests',     'Purchase request',    '{draft,submitted,approved}',       '{accountant,project_manager}', 'requested_by'),
  ('expense_claims',       'Expense claim',       '{submitted}',                      '{accountant}', 'submitted_by'),
  ('leave_requests',       'Leave request',       '{pending,approved}',               '{hr}', 'employee_id'),
  ('timesheets',           'Timesheet line',      '{submitted}',                      '{accountant,project_manager}', 'submitted_by'),
  ('stock_requests',       'Stock request',       '{draft,submitted}',                '{store,accountant}', 'requested_by'),
  ('asset_requests',       'Asset request',       '{pending,approved}',               '{store,accountant}', 'requested_by'),
  ('training_requests',    'Training request',    '{submitted,approved}',             '{hr}', 'requested_by'),
  ('contract_variations',  'Variation',           '{proposed}',                       '{accountant,project_manager,sales}', 'created_by'),
  ('vehicle_requests',     'Vehicle request',     '{pending,approved}',               '{store,accountant}', 'requested_by'),
  ('vehicle_trips',        'Trip',                '{planned}',                        '{store,accountant}', 'created_by'),
  ('hse_permits',          'Permit',              '{requested}',                      '{}', 'requested_by'),
  ('employee_change_requests','Profile change',   '{pending}',                        '{hr}', 'employee_id'),
  ('contracts',            'Contract',            '{draft}',                          '{accountant,sales}', 'created_by'),
  ('risk_assessments',     'Risk assessment',     '{draft}',                          '{project_manager}', 'assessed_by'),
  ('hse_inspections',      'Inspection',          '{draft}',                          '{}', null),
  ('hse_sessions',         'Toolbox talk / induction', '{draft}',                     '{}', 'created_by'),
  ('leads',                'Lead',                '{new,contacted,qualified,unqualified}', '{sales}', null)
on conflict (table_name) do update set label = excluded.label, from_status = excluded.from_status, roles = excluded.roles, creator_col = excluded.creator_col;
delete from public.void_rules where table_name in ('progress_reports','petty_vouchers','waybills');
alter table public.void_rules enable row level security;
drop policy if exists "read void rules" on public.void_rules;
create policy "read void rules" on public.void_rules for select using (true);

-- 'voided' becomes a valid status, and the reason is kept on the entry.
do $$ declare r record; c record; v_def text; begin
  for r in select table_name from void_rules where to_regclass('public.' || table_name) is not null loop
    execute format('alter table public.%I add column if not exists void_reason text', r.table_name);
    execute format('alter table public.%I add column if not exists voided_at timestamptz', r.table_name);
    execute format('alter table public.%I add column if not exists voided_by uuid', r.table_name);
    for c in select con.conname, pg_get_constraintdef(con.oid) def from pg_constraint con join pg_attribute a on a.attrelid = con.conrelid and a.attnum = any(con.conkey)
              where con.conrelid = ('public.' || r.table_name)::regclass and con.contype = 'c' and a.attname = 'status' loop
      if c.def not like '%''voided''%' then
        v_def := regexp_replace(c.def, '\](\)+)$', ', ''voided''::text]\1');
        if v_def = c.def then raise exception 'Could not add voided to %', r.table_name; end if;
        execute format('alter table public.%I drop constraint %I', r.table_name, c.conname);
        execute format('alter table public.%I add constraint %I %s', r.table_name, c.conname, v_def);
      end if;
    end loop;
  end loop;
end $$;

-- The person who entered it (an employee column means that employee's login).
create or replace function public.entry_owner(p_col text, p_table text, p_id uuid) returns uuid
language plpgsql stable security definer set search_path = public as $$
declare v uuid;
begin
  if p_col is null then return null; end if;
  execute format('select %I from public.%I where id = $1', p_col, p_table) into v using p_id;
  if p_col = 'employee_id' then select user_id into v from employees where id = v; end if;
  return v;
end $$;
revoke execute on function public.entry_owner(text, text, uuid) from public, anon, authenticated;

create or replace function public.void_entry(p_table text, p_id uuid, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare vr void_rules; v_cid uuid; v_status text; v_creator uuid; f text;
begin
  select * into vr from void_rules where table_name = p_table;
  if not found then raise exception 'This kind of entry cannot be voided here'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Say why it is being voided'; end if;
  execute format('select company_id, status from public.%I where id = $1 for update', p_table) into v_cid, v_status using p_id;
  if v_cid is null then raise exception '% not found', vr.label; end if;
  v_creator := entry_owner(vr.creator_col, p_table, p_id);
  if not (has_role(v_cid, array['owner','admin']) or has_role(v_cid, vr.roles) or (v_creator is not null and v_creator = auth.uid())) then
    raise exception 'You cannot void this %. Ask an admin.', lower(vr.label);
  end if;
  if v_status = 'voided' then raise exception 'Already voided'; end if;
  if not (v_status = any(vr.from_status)) then
    raise exception 'A % that is % cannot be voided. %', lower(vr.label), replace(v_status, '_', ' '),
      case when p_table = 'purchase_orders' then 'Goods have been received against it; close it instead.'
           when p_table = 'expense_claims' then 'It has been posted; reverse it with a journal.'
           when p_table = 'tenders' then 'An awarded tender has a project; cancel the project instead.'
           else 'It has already gone through.' end;
  end if;
  if p_table = 'timesheets' and exists (select 1 from timesheets where id = p_id and invoice_id is not null) then raise exception 'This time has been invoiced'; end if;
  -- Let the update through the usual "use the buttons" guards; the void itself is the controlled action.
  foreach f in array array['sika.cycle','sika.docs','sika.fleet','sika.hr','sika.hse','sika.po','sika.requests','sika.spend','sika.training','sika.petty','sika.contracts','sika.lifecycle'] loop
    perform set_config(f, 'on', true);
  end loop;
  execute format('update public.%I set status = ''voided'', void_reason = $2, voided_at = now(), voided_by = auth.uid() where id = $1', p_table) using p_id, trim(p_reason);
  foreach f in array array['sika.cycle','sika.docs','sika.fleet','sika.hr','sika.hse','sika.po','sika.requests','sika.spend','sika.training','sika.petty','sika.contracts','sika.lifecycle'] loop
    perform set_config(f, 'off', true);
  end loop;
  -- Nothing waits for approval on a voided entry.
  update approval_steps set status = 'skipped' where doc_id = p_id and status = 'pending';
  insert into audit_log (company_id, action, table_name, row_id, detail) values (v_cid, 'entry.voided', p_table, p_id, jsonb_build_object('what', vr.label, 'was', v_status, 'reason', trim(p_reason)));
end $$;

-- Who may void a given entry (for showing the button).
create or replace function public.can_void(p_table text, p_id uuid) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare vr void_rules; v_cid uuid; v_status text; v_creator uuid;
begin
  select * into vr from void_rules where table_name = p_table;
  if not found then return false; end if;
  execute format('select company_id, status from public.%I where id = $1', p_table) into v_cid, v_status using p_id;
  if v_cid is null or not (v_status = any(vr.from_status)) then return false; end if;
  v_creator := entry_owner(vr.creator_col, p_table, p_id);
  return has_role(v_cid, array['owner','admin']) or has_role(v_cid, vr.roles) or (v_creator is not null and v_creator = auth.uid());
end $$;

-- Manual journals posted in error: reverse them (a mirror entry dated when you choose). The original stays.
alter table public.journal_entries add column if not exists reversed_by_entry uuid;
create or replace function public.reverse_journal(p_entry uuid, p_date date, p_reason text) returns uuid
language plpgsql security definer set search_path = public as $$
declare e journal_entries; v uuid;
begin
  select * into e from journal_entries where id = p_entry for update;
  if not found then raise exception 'Journal not found'; end if;
  perform require_member(e.company_id, array['owner','admin','accountant']);
  if coalesce(trim(p_reason), '') = '' then raise exception 'Say why it is being reversed'; end if;
  if e.reversed_by_entry is not null then raise exception 'This journal has already been reversed'; end if;
  if coalesce(e.source_type, 'manual') not in ('manual','journal','opening') then
    raise exception 'This journal was posted by a % — correct it there (credit note, void, or the document''s own reversal).', replace(e.source_type, '_', ' ');
  end if;
  v := post_journal(e.company_id, p_date, 'Reversal of ' || e.entry_no || ': ' || trim(p_reason),
    (select jsonb_agg(jsonb_build_object('account_id', l.account_id, 'debit', l.credit, 'credit', l.debit, 'project_id', l.project_id,
                                         'branch_id', l.branch_id, 'cost_centre_id', l.cost_centre_id, 'description', 'Reversal'))
       from journal_lines l where l.entry_id = e.id), 'reversal', e.id);
  update journal_entries set reversed_by_entry = v where id = e.id;
  insert into audit_log (company_id, action, table_name, row_id, detail) values (e.company_id, 'journal.reversed', 'journal_entries', e.id, jsonb_build_object('entry', e.entry_no, 'reason', trim(p_reason)));
  return v;
end $$;
