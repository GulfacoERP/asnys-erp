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
