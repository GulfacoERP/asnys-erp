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
