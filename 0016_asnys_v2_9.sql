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
