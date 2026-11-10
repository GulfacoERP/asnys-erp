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
