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
