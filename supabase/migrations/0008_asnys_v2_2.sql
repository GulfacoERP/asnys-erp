-- =====================================================================
-- Asnys ERP v2.2 — project site stores and project document control
--   1. Site stores run by the project team: receive at site, record usage against tasks, return, count; stock requests
--      from the main store with goods in transit; counts approved by the project manager up to a limit; materials plan
--   2. Document register per project: types, numbering, revisions, internal review, transmittals and client responses,
--      expiry alerts, required documents at start and close-out
--   3. Structured risk assessments (5 x 5 matrix, controls, residual risk, PM and HSE sign-off)
-- Run after 0007.
-- =====================================================================

-- ---------------------------------------------------------------- 1. Who may work a store
create or replace function public.on_project_team(pid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select can_manage_project(pid) or exists (
    select 1 from project_assignments pa join employees e on e.id = pa.employee_id
     where pa.project_id = pid and e.user_id = auth.uid() and pa.status = 'confirmed'
       and (pa.end_date is null or pa.end_date >= current_date - 30));
$$;

-- The store, accountants and owners use any store; a project's team uses that project's site stores.
create or replace function public.can_use_store(p_wh uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from warehouses w where w.id = p_wh and (
    has_role(w.company_id, array['owner','admin','accountant','store'])
    or (w.project_id is not null and w.kind = 'site' and on_project_team(w.project_id))));
$$;

alter table public.warehouses drop constraint if exists warehouses_kind_check;
alter table public.warehouses add constraint warehouses_kind_check check (kind in ('store','site','vehicle','shop','transit'));

-- Goods on the road between stores are still ours: they sit in a hidden "in transit" store until received.
create or replace function public.transit_wh(cid uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  select id into v from warehouses where company_id = cid and kind = 'transit';
  if v is null then
    insert into warehouses (company_id, code, name, kind, active) values (cid, 'TRANSIT', 'Goods in transit', 'transit', false) returning id into v;
  end if;
  return v;
end $$;

alter table public.companies add column if not exists site_count_limit numeric(14,2) not null default 1000;  -- GHS a project manager may approve on a site stocktake
alter table public.stock_issues add column if not exists task_id uuid references public.tasks(id) on delete set null;
alter table public.projects add column if not exists hse_officer_id uuid;
alter table public.projects alter column status set default 'planned';

-- ---------------------------------------------------------------- 2. Stock requests: site asks, main store sends, site confirms
create table public.stock_requests (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  number text,
  project_id uuid not null references public.projects(id) on delete cascade,
  from_warehouse_id uuid not null references public.warehouses(id),
  to_warehouse_id uuid not null references public.warehouses(id),
  needed_by date,
  notes text,
  status text not null default 'draft' check (status in ('draft','submitted','dispatched','received','cancelled')),
  requested_by uuid default auth.uid(),
  requested_email text,
  dispatched_at date, dispatched_by uuid, dispatch_note text,
  received_at date, received_by uuid, receive_note text,
  created_at timestamptz not null default now(),
  check (from_warehouse_id <> to_warehouse_id)
);
create table public.stock_request_lines (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.stock_requests(id) on delete cascade,
  company_id uuid not null references public.companies(id) on delete cascade,
  product_id uuid not null references public.products(id),
  qty numeric(14,3) not null check (qty > 0),
  dispatched_qty numeric(14,3) not null default 0,
  received_qty numeric(14,3) not null default 0,
  sort int not null default 0
);
create index on public.stock_requests (project_id);

create or replace function public.stock_request_defaults() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    new.company_id := (select company_id from projects where id = new.project_id);
    new.number := coalesce(new.number, next_number(new.company_id, 'SRQ', 'SRQ-'));
    new.requested_by := coalesce(auth.uid(), new.requested_by);
    new.requested_email := (select email from auth.users where id = new.requested_by);
    if new.status not in ('draft','submitted') then raise exception 'A new stock request starts as a draft'; end if;
    if (select project_id from warehouses where id = new.to_warehouse_id) is distinct from new.project_id then
      raise exception 'Deliver the request to this project''s site store';
    end if;
  elsif new.status is distinct from old.status and coalesce(current_setting('sika.posting', true), '') <> 'on'
        and not (old.status = 'draft' and new.status in ('submitted','cancelled')) and not (old.status = 'submitted' and new.status = 'cancelled') then
    raise exception 'Use Send or Receive to move a stock request on';
  end if;
  return new;
end $$;
create trigger stock_requests_defaults before insert or update on public.stock_requests for each row execute function public.stock_request_defaults();

create or replace function public.stock_request_line_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if (select status from stock_requests where id = coalesce(new.request_id, old.request_id)) not in ('draft','submitted')
     and coalesce(current_setting('sika.posting', true), '') <> 'on' then raise exception 'This request has been sent and cannot be changed'; end if;
  return coalesce(new, old);
end $$;
create trigger stock_request_lines_guard before insert or update or delete on public.stock_request_lines for each row execute function public.stock_request_line_guard();

-- The supplying store sends the goods: they leave its shelves and go "in transit".
create or replace function public.dispatch_stock_request(p_id uuid, p_lines jsonb, p_date date default current_date, p_note text default null)
returns text language plpgsql security definer set search_path = public as $$
declare r stock_requests; l record; rl stock_request_lines; p products; v_have numeric; v_tr uuid; n int := 0;
begin
  select * into r from stock_requests where id = p_id for update;
  if not found then raise exception 'Stock request not found'; end if;
  if not can_use_store(r.from_warehouse_id) then raise exception 'Only the supplying store can send this request'; end if;
  if r.status <> 'submitted' then raise exception '% is %', r.number, r.status; end if;
  v_tr := transit_wh(r.company_id);
  perform set_config('sika.posting','on', true);
  for l in select (x->>'line_id')::uuid line_id, round((x->>'qty')::numeric, 3) qty from jsonb_array_elements(p_lines) x loop
    continue when coalesce(l.qty, 0) <= 0;
    select * into rl from stock_request_lines where id = l.line_id and request_id = p_id;
    if not found then raise exception 'A line is not on this request'; end if;
    select * into p from products where id = rl.product_id;
    select coalesce(sum(qty), 0) into v_have from stock_levels where product_id = p.id and warehouse_id = r.from_warehouse_id;
    if v_have < l.qty then raise exception 'Only % % of % in stock at %', v_have, p.unit, p.name, (select name from warehouses where id = r.from_warehouse_id); end if;
    insert into stock_moves (company_id, product_id, warehouse_id, move_date, qty, unit_cost, reason, ref_type, ref_id, project_id)
    values (r.company_id, p.id, r.from_warehouse_id, p_date, -l.qty, p.cost, 'Sent to site ' || r.number, 'stock_request', r.id, r.project_id),
           (r.company_id, p.id, v_tr, p_date, l.qty, p.cost, 'In transit ' || r.number, 'stock_request', r.id, r.project_id);
    update stock_request_lines set dispatched_qty = l.qty where id = rl.id;
    n := n + 1;
  end loop;
  if n = 0 then raise exception 'Enter the quantity sent on at least one line'; end if;
  update stock_requests set status = 'dispatched', dispatched_at = p_date, dispatched_by = auth.uid(), dispatch_note = p_note where id = p_id;
  perform set_config('sika.posting','off', true);
  return r.number;
end $$;

-- The site confirms what arrived. Anything short is written off as lost in transit.
create or replace function public.receive_stock_request(p_id uuid, p_lines jsonb, p_date date default current_date, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r stock_requests; rl record; p products; v_tr uuid; v_q numeric; v_short numeric; v_loss numeric := 0; v_je uuid;
begin
  select * into r from stock_requests where id = p_id for update;
  if not found then raise exception 'Stock request not found'; end if;
  if not can_use_store(r.to_warehouse_id) then raise exception 'Only the project team or the store can confirm this delivery'; end if;
  if r.status <> 'dispatched' then raise exception '% has not been sent yet', r.number; end if;
  v_tr := transit_wh(r.company_id);
  perform set_config('sika.posting','on', true);
  for rl in select * from stock_request_lines where request_id = p_id and dispatched_qty > 0 loop
    v_q := coalesce((select round((x->>'qty')::numeric, 3) from jsonb_array_elements(p_lines) x where (x->>'line_id')::uuid = rl.id), rl.dispatched_qty);
    if v_q < 0 or v_q > rl.dispatched_qty then raise exception 'You can confirm at most % received for one line', rl.dispatched_qty; end if;
    select * into p from products where id = rl.product_id for update;
    if v_q > 0 then
      insert into stock_moves (company_id, product_id, warehouse_id, move_date, qty, unit_cost, reason, ref_type, ref_id, project_id)
      values (r.company_id, p.id, v_tr, p_date, -v_q, p.cost, 'Arrived ' || r.number, 'stock_request', r.id, r.project_id),
             (r.company_id, p.id, r.to_warehouse_id, p_date, v_q, p.cost, 'Received from store ' || r.number, 'stock_request', r.id, r.project_id);
    end if;
    v_short := rl.dispatched_qty - v_q;
    if v_short > 0 then
      update products set stock_qty = stock_qty - v_short where id = p.id;
      insert into stock_moves (company_id, product_id, warehouse_id, move_date, qty, unit_cost, reason, ref_type, ref_id, project_id)
      values (r.company_id, p.id, v_tr, p_date, -v_short, p.cost, 'Lost in transit ' || r.number, 'stock_request', r.id, r.project_id);
      v_loss := v_loss + round(v_short * p.cost, 2);
    end if;
    update stock_request_lines set received_qty = v_q where id = rl.id;
  end loop;
  update stock_requests set status = 'received', received_at = p_date, received_by = auth.uid(), receive_note = p_note where id = p_id;
  perform set_config('sika.posting','off', true);
  if v_loss > 0 then
    v_je := post_journal(r.company_id, p_date, 'Short delivery to site on ' || r.number || coalesce(': ' || p_note, ''),
      jsonb_build_array(jl(acct(r.company_id,'stock_adj'), v_loss, 0) || jsonb_build_object('project_id', r.project_id), jl(acct(r.company_id,'inventory'), 0, v_loss)), 'stock_request', r.id);
  end if;
  return jsonb_build_object('lost_value', v_loss);
end $$;

-- ---------------------------------------------------------------- 3. Materials plan and usage
create table public.project_material_plan (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  project_id uuid not null references public.projects(id) on delete cascade,
  product_id uuid not null references public.products(id),
  planned_qty numeric(14,3) not null check (planned_qty >= 0),
  note text,
  unique (project_id, product_id)
);
create or replace function public.material_plan_defaults() returns trigger
language plpgsql security definer set search_path = public as $$
begin new.company_id := (select company_id from projects where id = new.project_id); return new; end $$;
create trigger project_material_plan_defaults before insert or update on public.project_material_plan for each row execute function public.material_plan_defaults();

-- Planned vs used for each material, with what is at site, on the way, still requested, and lost on site counts.
create or replace function public.project_material_usage(p_project uuid)
returns table (product_id uuid, sku text, name text, unit text, planned numeric, used numeric, used_value numeric, at_site numeric,
               in_transit numeric, requested numeric, wastage numeric, wastage_value numeric, remaining numeric, used_pct numeric, over boolean)
language sql stable security definer set search_path = public as $$
  with pr as (select * from projects where id = p_project and is_member(company_id)),
  sites as (select w.id from warehouses w, pr where w.project_id = pr.id),
  u as (select l.product_id, sum(case when s.kind = 'issue' then l.qty else -l.qty end) q, sum(case when s.kind = 'issue' then 1 else -1 end * l.qty * coalesce(l.unit_cost, 0)) v
          from stock_issue_lines l join stock_issues s on s.id = l.issue_id where s.project_id = p_project and s.status = 'posted' group by l.product_id),
  st as (select sl.product_id, sum(sl.qty) q from stock_levels sl where sl.warehouse_id in (select id from sites) group by sl.product_id),
  rq as (select rl.product_id, sum(case when r.status = 'dispatched' then rl.dispatched_qty else 0 end) tr, sum(case when r.status = 'submitted' then rl.qty else 0 end) rq
           from stock_request_lines rl join stock_requests r on r.id = rl.request_id where r.project_id = p_project group by rl.product_id),
  wa as (select cl.product_id, sum(cl.system_qty - cl.counted_qty) q, sum((cl.system_qty - cl.counted_qty) * coalesce(cl.unit_cost, 0)) v
           from stock_count_lines cl join stock_counts c on c.id = cl.count_id where c.status = 'posted' and c.warehouse_id in (select id from sites) group by cl.product_id),
  ids as (select product_id from project_material_plan where project_id = p_project union select product_id from u union select product_id from st where q <> 0 union select product_id from rq)
  select p.id, p.sku, p.name, p.unit, mp.planned_qty, coalesce(u.q, 0), round(coalesce(u.v, 0), 2), coalesce(st.q, 0), coalesce(rq.tr, 0), coalesce(rq.rq, 0),
         coalesce(wa.q, 0), round(coalesce(wa.v, 0), 2),
         case when mp.planned_qty is not null then mp.planned_qty - coalesce(u.q, 0) end,
         case when mp.planned_qty > 0 then round(100 * coalesce(u.q, 0) / mp.planned_qty) end,
         mp.planned_qty is not null and coalesce(u.q, 0) > mp.planned_qty
    from ids join products p on p.id = ids.product_id
    left join project_material_plan mp on mp.project_id = p_project and mp.product_id = p.id
    left join u on u.product_id = p.id left join st on st.product_id = p.id left join rq on rq.product_id = p.id left join wa on wa.product_id = p.id
   where exists (select 1 from pr)
   order by p.name;
$$;

-- Stock held at every project site, for the stock controller.
create or replace function public.site_stock(cid uuid)
returns table (warehouse_id uuid, code text, warehouse text, project_id uuid, project text, project_status text, lines bigint, value numeric)
language sql stable security definer set search_path = public as $$
  select w.id, w.code, w.name, pj.id, coalesce(pj.number || ' ', '') || pj.name, pj.status,
         count(sl.product_id) filter (where sl.qty <> 0), coalesce(round(sum(sl.qty * p.cost), 2), 0)
    from warehouses w left join projects pj on pj.id = w.project_id
    left join stock_levels sl on sl.warehouse_id = w.id left join products p on p.id = sl.product_id
   where w.company_id = cid and w.kind = 'site' and is_member(cid)
   group by w.id, w.code, w.name, pj.id, pj.number, pj.name, pj.status
   order by w.code;
$$;

-- ---------------------------------------------------------------- 4. Store work by the project team (re-issued from 0007)
create or replace function public.receive_po(p_po uuid, p_lines jsonb, p_date date default current_date, p_warehouse uuid default null, p_reference text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare o purchase_orders; l record; pl po_lines; pr products; v_grn uuid; v_wh uuid; v_lines jsonb := '[]'::jsonb; v_total numeric := 0; v_amt numeric; v_acct uuid; v_je uuid; n int := 0;
begin
  select * into o from purchase_orders where id = p_po for update;
  if not found then raise exception 'Purchase order not found'; end if;
  if o.status not in ('approved','sent','partial') then raise exception 'Only an approved, open order can be received (this one is %)', o.status; end if;
  v_wh := coalesce(p_warehouse, o.warehouse_id, wh(o.company_id));
  if not exists (select 1 from warehouses where id = v_wh and company_id = o.company_id) then raise exception 'Choose one of your warehouses'; end if;
  if not (has_role(o.company_id, array['owner','admin','accountant','store']) or (p_warehouse is not null or o.warehouse_id is not null) and can_use_store(v_wh)
          or (o.project_id is not null and o.warehouse_id is null and p_warehouse is null and on_project_team(o.project_id))) then
    raise exception 'Only the store, an accountant or this project''s team can receive this delivery';
  end if;
  insert into goods_receipts (company_id, number, po_id, supplier_id, receipt_date, warehouse_id, reference)
  values (o.company_id, next_number(o.company_id, 'GRN', 'GRN-'), p_po, o.supplier_id, p_date, v_wh, p_reference) returning id into v_grn;
  perform set_config('sika.posting','on', true);
  perform set_config('sika.po','on', true);
  for l in select (x->>'line_id')::uuid line_id, round((x->>'qty')::numeric, 3) qty from jsonb_array_elements(p_lines) x loop
    continue when coalesce(l.qty, 0) = 0;
    select * into pl from po_lines where id = l.line_id and po_id = p_po for update;
    if not found then raise exception 'A line is not on this order'; end if;
    if l.qty < 0 or l.qty > pl.qty - pl.received_qty + 0.0005 then
      raise exception 'You can receive at most % of "%"', pl.qty - pl.received_qty, pl.description;
    end if;
    v_amt := round(l.qty * pl.unit_cost, 2);
    pr := null;
    if pl.product_id is not null then select * into pr from products where id = pl.product_id for update; end if;
    if pl.project_id is null and pr.id is not null and pr.item_type = 'stock' then
      update products set cost = round((greatest(stock_qty,0) * cost + l.qty * pl.unit_cost) / nullif(greatest(stock_qty,0) + l.qty, 0), 4),
                          stock_qty = stock_qty + l.qty, last_purchase_cost = pl.unit_cost where id = pr.id;
      insert into stock_moves (company_id, product_id, warehouse_id, move_date, qty, unit_cost, reason, ref_type, ref_id)
      values (o.company_id, pr.id, v_wh, p_date, l.qty, pl.unit_cost, 'Received ' || o.number, 'receipt', v_grn);
      v_acct := acct(o.company_id, 'inventory');
    else
      if pr.id is not null then update products set last_purchase_cost = pl.unit_cost where id = pr.id; end if;
      v_acct := coalesce(pl.account_id, pr.expense_account_id,
                         case when pl.project_id is not null then acct(o.company_id, 'project_materials') else acct(o.company_id, 'expense') end);
    end if;
    insert into goods_receipt_lines (receipt_id, company_id, po_line_id, product_id, qty, unit_cost, project_id)
    values (v_grn, o.company_id, pl.id, pl.product_id, l.qty, pl.unit_cost, pl.project_id);
    update po_lines set received_qty = received_qty + l.qty where id = pl.id;
    v_lines := v_lines || (jl(v_acct, v_amt, 0) || jsonb_build_object('project_id', pl.project_id, 'branch_id', o.branch_id));
    v_total := v_total + v_amt; n := n + 1;
  end loop;
  perform set_config('sika.posting','off', true);
  if n = 0 then raise exception 'Enter the quantity received on at least one line'; end if;
  if v_total > 0 then
    v_je := post_journal(o.company_id, p_date, 'Goods received on ' || o.number || coalesce(' (delivery note ' || p_reference || ')', ''),
      v_lines || jl(acct(o.company_id, 'grni'), 0, v_total), 'receipt', v_grn);
    update goods_receipts set journal_entry_id = v_je where id = v_grn;
  end if;
  update purchase_orders set status = case when exists (select 1 from po_lines where po_id = p_po and received_qty < qty) then 'partial' else 'received' end where id = p_po;
  perform set_config('sika.po','off', true);
  return v_grn;
end $$;

create or replace function public.post_stock_issue(p_id uuid) returns text
language plpgsql security definer set search_path = public as $$
declare s stock_issues; l record; p products; v_have numeric; v_val numeric := 0; v_amt numeric; v_target uuid; v_sign int; v_je uuid;
begin
  select * into s from stock_issues where id = p_id for update;
  if not found then raise exception 'Stock issue not found'; end if;
  if not (has_role(s.company_id, array['owner','admin','accountant','store'])
          or (s.project_id is not null and on_project_team(s.project_id) and coalesce((select project_id from warehouses where id = s.warehouse_id) = s.project_id, false))) then
    raise exception 'The project team can issue and return stock only through this project''s site store. Ask the store for anything else.';
  end if;
  if s.status <> 'draft' then raise exception '% is already posted', s.number; end if;
  if not exists (select 1 from stock_issue_lines where issue_id = p_id) then raise exception 'Add at least one item'; end if;
  if s.project_id is not null and (select status from projects where id = s.project_id) in ('closed','cancelled') then raise exception 'This project is closed'; end if;
  v_sign := case when s.kind = 'issue' then -1 else 1 end;
  v_target := coalesce(s.account_id, case when s.project_id is not null then acct(s.company_id, 'project_materials') else acct(s.company_id, 'expense') end);
  perform set_config('sika.posting','on', true);
  for l in select * from stock_issue_lines where issue_id = p_id order by sort loop
    select * into p from products where id = l.product_id for update;
    if p.item_type <> 'stock' then raise exception '% is not a stock item', p.name; end if;
    if s.kind = 'issue' then
      select coalesce(sum(qty), 0) into v_have from stock_levels where product_id = p.id and warehouse_id = s.warehouse_id;
      if v_have < l.qty then raise exception 'Only % % of % in stock at %', v_have, p.unit, p.name, (select name from warehouses where id = s.warehouse_id); end if;
    end if;
    v_amt := round(l.qty * p.cost, 2);
    update products set stock_qty = stock_qty + v_sign * l.qty where id = p.id;
    insert into stock_moves (company_id, product_id, warehouse_id, move_date, qty, unit_cost, reason, ref_type, ref_id, project_id)
    values (s.company_id, p.id, s.warehouse_id, s.issue_date, v_sign * l.qty, p.cost,
            case when s.kind = 'issue' then 'Issued ' else 'Returned ' end || s.number, 'stock_issue', s.id, s.project_id);
    update stock_issue_lines set unit_cost = p.cost, bill_price = coalesce(bill_price, p.price) where id = l.id;
    v_val := v_val + v_amt;
  end loop;
  update stock_issues set status = 'posted' where id = p_id;
  if v_val > 0 then
    v_je := post_journal(s.company_id, s.issue_date,
      case when s.kind = 'issue' then 'Stock issued ' else 'Stock returned ' end || s.number || coalesce(' — ' || (select coalesce(number || ' ', '') || name from projects where id = s.project_id), ''),
      case when s.kind = 'issue'
        then jsonb_build_array(jl(v_target, v_val, 0) || jsonb_build_object('project_id', s.project_id, 'cost_centre_id', s.cost_centre_id), jl(acct(s.company_id,'inventory'), 0, v_val))
        else jsonb_build_array(jl(acct(s.company_id,'inventory'), v_val, 0), jl(v_target, 0, v_val) || jsonb_build_object('project_id', s.project_id, 'cost_centre_id', s.cost_centre_id)) end,
      'stock_issue', s.id);
    update stock_issues set journal_entry_id = v_je where id = p_id;
  end if;
  perform set_config('sika.posting','off', true);
  return s.number;
end $$;

create or replace function public.post_transfer(p_id uuid) returns text
language plpgsql security definer set search_path = public as $$
declare t stock_transfers; l record; p products; v_have numeric;
begin
  select * into t from stock_transfers where id = p_id for update;
  if not found then raise exception 'Transfer not found'; end if;
  if not can_use_store(t.from_warehouse_id) then raise exception 'Only the store, or the team of the project whose site store it is, can send stock from %', (select name from warehouses where id = t.from_warehouse_id); end if;
  if t.status <> 'draft' then raise exception '% is already posted', t.number; end if;
  if not exists (select 1 from stock_transfer_lines where transfer_id = p_id) then raise exception 'Add at least one item'; end if;
  for l in select * from stock_transfer_lines where transfer_id = p_id loop
    select * into p from products where id = l.product_id;
    select coalesce(sum(qty), 0) into v_have from stock_levels where product_id = p.id and warehouse_id = t.from_warehouse_id;
    if v_have < l.qty then raise exception 'Only % % of % in stock at %', v_have, p.unit, p.name, (select name from warehouses where id = t.from_warehouse_id); end if;
    insert into stock_moves (company_id, product_id, warehouse_id, move_date, qty, unit_cost, reason, ref_type, ref_id)
    values (t.company_id, p.id, t.from_warehouse_id, t.transfer_date, -l.qty, p.cost, 'Transfer out ' || t.number, 'transfer', t.id),
           (t.company_id, p.id, t.to_warehouse_id, t.transfer_date, l.qty, p.cost, 'Transfer in ' || t.number, 'transfer', t.id);
  end loop;
  perform set_config('sika.posting','on', true);
  update stock_transfers set status = 'posted' where id = p_id;
  perform set_config('sika.posting','off', true);
  return t.number;
end $$;

create or replace function public.start_stock_count(cid uuid, p_warehouse uuid, p_date date default current_date, p_category text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  perform require_member(cid, array['owner','admin','accountant','sales','hr','project_manager','store','staff']);
  if not can_use_store(p_warehouse) then raise exception 'You cannot count this store'; end if;
  if not exists (select 1 from warehouses where id = p_warehouse and company_id = cid) then raise exception 'Choose one of your warehouses'; end if;
  insert into stock_counts (company_id, number, warehouse_id, count_date, notes)
  values (cid, next_number(cid, 'CNT', 'CNT-'), p_warehouse, p_date, case when p_category is not null then 'Category: ' || p_category end) returning id into v;
  insert into stock_count_lines (count_id, company_id, product_id, system_qty)
  select v, cid, p.id, coalesce(sl.qty, 0) from products p left join stock_levels sl on sl.product_id = p.id and sl.warehouse_id = p_warehouse
   where p.company_id = cid and p.item_type = 'stock' and p.active and (p_category is null or p.category = p_category)
   order by p.name;
  return v;
end $$;

-- Site stocktakes: differences are the project's wastage (5200, tagged to the project); the project manager approves up to the company limit.
create or replace function public.post_stock_count(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c stock_counts; l record; p products; v_now numeric; v_diff numeric; v_gain numeric := 0; v_loss numeric := 0; n int := 0; v_je uuid; v_proj uuid; v_acct boolean; v_other uuid;
begin
  select * into c from stock_counts where id = p_id for update;
  if not found then raise exception 'Stock count not found'; end if;
  v_acct := has_role(c.company_id, array['owner','admin','accountant']);
  select case when kind = 'site' then project_id end into v_proj from warehouses where id = c.warehouse_id;
  if not (v_acct or (v_proj is not null and can_manage_project(v_proj))) then raise exception 'Only an accountant, or the project manager for a site store, can post a stocktake'; end if;
  if c.status <> 'draft' then raise exception '% is already posted', c.number; end if;
  if exists (select 1 from stock_count_lines where count_id = p_id and counted_qty is null) then
    raise exception 'Enter a counted quantity on every line (enter 0 for none found), or remove lines you did not count';
  end if;
  perform set_config('sika.posting','on', true);
  for l in select * from stock_count_lines where count_id = p_id loop
    select * into p from products where id = l.product_id for update;
    select coalesce(sum(qty), 0) into v_now from stock_levels where product_id = p.id and warehouse_id = c.warehouse_id;
    v_diff := l.counted_qty - v_now;
    update stock_count_lines set unit_cost = p.cost where id = l.id;
    continue when v_diff = 0;
    update products set stock_qty = stock_qty + v_diff where id = p.id;
    insert into stock_moves (company_id, product_id, warehouse_id, move_date, qty, unit_cost, reason, ref_type, ref_id)
    values (c.company_id, p.id, c.warehouse_id, c.count_date, v_diff, p.cost, 'Stocktake ' || c.number, 'stock_count', c.id);
    if v_diff > 0 then v_gain := v_gain + round(v_diff * p.cost, 2); else v_loss := v_loss + round(-v_diff * p.cost, 2); end if;
    n := n + 1;
  end loop;
  if not v_acct and v_gain + v_loss > (select site_count_limit from companies where id = c.company_id) then
    raise exception 'The differences total GH₵ % (gains % and losses %), more than the GH₵ % a project manager can approve. Ask an accountant to post this count.',
      v_gain + v_loss, v_gain, v_loss, (select site_count_limit from companies where id = c.company_id);
  end if;
  v_other := case when v_proj is not null then acct(c.company_id,'project_materials') else acct(c.company_id,'stock_adj') end;
  update stock_counts set status = 'posted' where id = p_id;
  if v_gain + v_loss > 0 then
    v_je := post_journal(c.company_id, c.count_date, 'Stocktake ' || c.number || ' at ' || (select name from warehouses where id = c.warehouse_id),
      jsonb_build_array(jl(acct(c.company_id,'inventory'), v_gain, v_loss), jl(v_other, v_loss, v_gain) || jsonb_build_object('project_id', v_proj)), 'stock_count', c.id);
    update stock_counts set journal_entry_id = v_je where id = p_id;
  end if;
  perform set_config('sika.posting','off', true);
  return jsonb_build_object('lines_adjusted', n, 'gain', v_gain, 'loss', v_loss);
end $$;

-- ---------------------------------------------------------------- 5. Document control
create table public.doc_types (
  code text primary key,
  grp text not null,
  name text not null,
  prefix text not null,
  client_review boolean not null default false,   -- goes to the client or consultant for approval
  has_expiry boolean not null default false,
  sort int not null default 0
);
insert into public.doc_types (code, grp, name, prefix, client_review, has_expiry, sort) values
 ('contract','contract','Contract','CON',false,false,10), ('scope','contract','Scope of work','SOW',true,false,11), ('boq','contract','Bill of quantities','BOQ',true,false,12),
 ('variation','contract','Variation or change order','VO',true,false,13), ('instruction','contract','Client instruction','CI',false,false,14),
 ('shop_drawing','engineering','Shop drawing','SD',true,false,20), ('design_drawing','engineering','Design drawing','DWG',true,false,21),
 ('as_built','engineering','As-built drawing','ABD',true,false,22), ('calculation','engineering','Calculation','CAL',true,false,23),
 ('specification','engineering','Specification','SPC',false,false,24), ('datasheet','engineering','Datasheet','DS',false,false,25),
 ('method_statement','quality','Method statement','MS',true,false,30), ('itp','quality','Inspection and test plan','ITP',true,false,31),
 ('test_report','quality','Test report','TST',false,false,32), ('submittal','quality','Material submittal','MSA',true,false,33), ('ncr','quality','Non-conformance report','NCR',false,false,34),
 ('risk_assessment','hse','Risk assessment','RA',true,false,40), ('permit','hse','Permit to work','PTW',false,true,41), ('toolbox','hse','Toolbox talk','TBT',false,false,42),
 ('incident','hse','Incident report','INC',false,false,43), ('hse_inspection','hse','Safety inspection','HSI',false,false,44), ('insurance','hse','Insurance certificate','INS',false,true,45),
 ('diary','site','Daily site diary','SDY',false,false,50), ('photo','site','Site photos','PHO',false,false,51), ('delivery_note','site','Delivery note','DN',false,false,52),
 ('minutes','site','Minutes of meeting','MOM',false,false,53), ('rfi','site','Request for information','RFI',true,false,54),
 ('om_manual','handover','O&M manual','OMM',true,false,60), ('warranty','handover','Warranty','WAR',false,true,61), ('certificate','handover','Test certificate','CER',false,true,62),
 ('handover_cert','handover','Handover certificate','HOC',true,false,63), ('snag_list','handover','Snag list','SNG',false,false,64),
 ('other','other','Other','DOC',false,false,90)
on conflict (code) do nothing;
alter table public.doc_types enable row level security;
create policy "everyone reads document types" on public.doc_types for select using (auth.uid() is not null);

create table public.doc_register (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  project_id uuid not null references public.projects(id) on delete cascade,
  doc_type text not null references public.doc_types(code),
  seq int not null,
  number text not null,
  title text not null,
  description text,
  discipline text,                    -- civil, electrical, mechanical …
  task_id uuid references public.tasks(id) on delete set null,
  owner_id uuid default auth.uid(),
  expires_on date,
  confidential boolean not null default false,
  created_at timestamptz not null default now(),
  unique (project_id, doc_type, seq)
);
create index on public.doc_register (company_id, number);

create table public.doc_revisions (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  doc_id uuid not null references public.doc_register(id) on delete cascade,
  seq int not null,
  rev text not null,
  storage_path text,
  file_name text,
  size_bytes bigint,
  mime text,
  notes text,
  status text not null default 'draft' check (status in ('draft','in_review','ready','submitted','approved','approved_comments','rejected','for_info')),
  issued_for_construction boolean not null default false,
  uploaded_by uuid default auth.uid(),
  uploaded_email text,
  created_at timestamptz not null default now(),
  submitted_at timestamptz,
  reviewed_by uuid, reviewed_email text, reviewed_at timestamptz, review_note text,
  client_comments text, client_responded_at date,
  superseded_at timestamptz,
  unique (doc_id, seq)
);
create index on public.doc_revisions (doc_id);

create or replace function public.doc_register_defaults() returns trigger
language plpgsql security definer set search_path = public as $$
declare pj projects;
begin
  select * into pj from projects where id = new.project_id;
  new.company_id := pj.company_id;
  if tg_op = 'INSERT' then
    perform pg_advisory_xact_lock(hashtext(new.project_id::text || new.doc_type));
    new.seq := coalesce((select max(seq) from doc_register where project_id = new.project_id and doc_type = new.doc_type), 0) + 1;
    new.number := coalesce(pj.number, 'PRJ') || '-' || (select prefix from doc_types where code = new.doc_type) || '-' || lpad(new.seq::text, 4, '0');
  elsif (new.doc_type, new.project_id) is distinct from (old.doc_type, old.project_id) then
    raise exception 'A document''s type and project cannot change once it has a number. Add a new document instead.';
  else new.seq := old.seq; new.number := old.number;
  end if;
  return new;
end $$;
create trigger doc_register_defaults before insert or update on public.doc_register for each row execute function public.doc_register_defaults();
create trigger doc_register_closed_project before insert on public.doc_register for each row execute function public.closed_project_guard();

create or replace function public.doc_revision_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    if coalesce(current_setting('sika.docs', true), '') <> 'on' then raise exception 'Use Upload new revision'; end if;
  elsif tg_op = 'UPDATE' and coalesce(current_setting('sika.docs', true), '') <> 'on'
        and (new.status, new.rev, new.storage_path, new.superseded_at) is distinct from (old.status, old.rev, old.storage_path, old.superseded_at) then
    raise exception 'Use Submit, Review or a transmittal to change a revision';
  elsif tg_op = 'DELETE' and old.status <> 'draft' and coalesce(current_setting('sika.docs', true), '') <> 'on' then
    raise exception 'Only a draft revision can be deleted';
  end if;
  return coalesce(new, old);
end $$;
create trigger doc_revisions_guard before insert or update or delete on public.doc_revisions for each row execute function public.doc_revision_guard();

create or replace function public.can_see_doc(p_doc uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from doc_register d where d.id = p_doc and is_member(d.company_id)
    and (not d.confidential or can_manage_project(d.project_id) or has_role(d.company_id, array['owner','admin','accountant']) or d.owner_id = auth.uid()));
$$;

-- A new revision: A, B, C … while in design; 0, 1, 2 … once issued for construction. Older revisions are superseded.
create or replace function public.add_revision(p_doc uuid, p_path text, p_name text, p_size bigint default null, p_mime text default null,
  p_notes text default null, p_issue boolean default false, p_for_info boolean default false)
returns uuid language plpgsql security definer set search_path = public as $$
declare d doc_register; last doc_revisions; v_rev text; v_id uuid;
begin
  select * into d from doc_register where id = p_doc for update;
  if not found then raise exception 'Document not found'; end if;
  if not (on_project_team(d.project_id) or has_role(d.company_id, array['owner','admin','accountant'])) then raise exception 'Only the project team can add revisions'; end if;
  if (select status from projects where id = d.project_id) in ('closed','cancelled') then raise exception 'This project is closed. Reopen it to add documents.'; end if;
  if p_path is not null and split_part(p_path, '/', 1) <> d.company_id::text then raise exception 'The file was not stored in this company''s folder'; end if;
  select * into last from doc_revisions where doc_id = p_doc order by seq desc limit 1;
  v_rev := case
    when last.id is null then case when p_issue then '0' else 'A' end
    when last.rev ~ '^[0-9]+$' then (last.rev::int + 1)::text
    when p_issue then '0'
    when last.rev ~ '^[A-Y]$' then chr(ascii(last.rev) + 1)
    else last.rev || 'A' end;
  perform set_config('sika.docs','on', true);
  update doc_revisions set superseded_at = now() where doc_id = p_doc and superseded_at is null;
  insert into doc_revisions (company_id, doc_id, seq, rev, storage_path, file_name, size_bytes, mime, notes, status, issued_for_construction, uploaded_email)
  values (d.company_id, p_doc, coalesce(last.seq, 0) + 1, v_rev, p_path, p_name, p_size, p_mime, p_notes,
          case when p_for_info then 'for_info' else 'draft' end, p_issue or v_rev ~ '^[0-9]+$', (select email from auth.users where id = auth.uid()))
  returning id into v_id;
  perform set_config('sika.docs','off', true);
  return v_id;
end $$;

create or replace function public.submit_revision(p_rev uuid) returns void
language plpgsql security definer set search_path = public as $$
declare r doc_revisions; d doc_register;
begin
  select * into r from doc_revisions where id = p_rev for update;
  select * into d from doc_register where id = r.doc_id;
  if not (on_project_team(d.project_id) or has_role(d.company_id, array['owner','admin','accountant'])) then raise exception 'Only the project team can submit documents'; end if;
  if r.status not in ('draft','rejected') then raise exception 'Revision % is already %', r.rev, replace(r.status, '_', ' '); end if;
  if r.superseded_at is not null then raise exception 'A newer revision exists. Submit that one.'; end if;
  perform set_config('sika.docs','on', true);
  update doc_revisions set status = 'in_review', submitted_at = now() where id = p_rev;
  perform set_config('sika.docs','off', true);
end $$;

-- Internal check by the project manager (or owner/admin). Documents the client approves become "ready to send".
create or replace function public.review_revision(p_rev uuid, p_approve boolean, p_note text default null) returns text
language plpgsql security definer set search_path = public as $$
declare r doc_revisions; d doc_register; v_to text;
begin
  select * into r from doc_revisions where id = p_rev for update;
  select * into d from doc_register where id = r.doc_id;
  if not (can_manage_project(d.project_id) or has_role(d.company_id, array['owner','admin'])) then raise exception 'Only the project manager can review documents'; end if;
  if r.status <> 'in_review' then raise exception 'Revision % is not waiting for review', r.rev; end if;
  if not p_approve and coalesce(trim(p_note), '') = '' then raise exception 'Say what needs to change'; end if;
  v_to := case when not p_approve then 'rejected' when (select client_review from doc_types where code = d.doc_type) then 'ready' else 'approved' end;
  perform set_config('sika.docs','on', true);
  update doc_revisions set status = v_to, reviewed_by = auth.uid(), reviewed_email = (select email from auth.users where id = auth.uid()), reviewed_at = now(), review_note = p_note where id = p_rev;
  perform set_config('sika.docs','off', true);
  return v_to;
end $$;

-- Transmittals: what was sent to the client or consultant, why, and what came back.
create table public.transmittals (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  project_id uuid not null references public.projects(id) on delete cascade,
  number text,
  to_party text not null,
  to_person text,
  to_email text,
  purpose text not null default 'for_approval' check (purpose in ('for_approval','for_comment','for_information','for_construction','for_record')),
  sent_date date,
  response_due date,
  status text not null default 'draft' check (status in ('draft','sent','responded','closed')),
  notes text,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);
create table public.transmittal_items (
  id uuid primary key default gen_random_uuid(),
  transmittal_id uuid not null references public.transmittals(id) on delete cascade,
  company_id uuid not null references public.companies(id) on delete cascade,
  revision_id uuid not null references public.doc_revisions(id),
  copies int not null default 1,
  response text check (response in ('approved','approved_comments','rejected','noted')),
  comments text,
  responded_at date,
  unique (transmittal_id, revision_id)
);
create or replace function public.transmittal_defaults() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    new.company_id := (select company_id from projects where id = new.project_id);
    new.number := coalesce(new.number, (select coalesce(number, 'PRJ') from projects where id = new.project_id) || '-' || next_number(new.company_id, 'TRN', 'TRN-'));
    new.status := 'draft';
  elsif new.status is distinct from old.status and coalesce(current_setting('sika.docs', true), '') <> 'on' then
    raise exception 'Use Send or Record response';
  end if;
  return new;
end $$;
create trigger transmittals_defaults before insert or update on public.transmittals for each row execute function public.transmittal_defaults();
create trigger transmittals_closed_project before insert on public.transmittals for each row execute function public.closed_project_guard();
create or replace function public.transmittal_item_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if (select status from transmittals where id = coalesce(new.transmittal_id, old.transmittal_id)) <> 'draft' and coalesce(current_setting('sika.docs', true), '') <> 'on' then
    raise exception 'This transmittal has been sent. Record responses instead.';
  end if;
  if tg_op <> 'DELETE' and (select d.project_id from doc_revisions r join doc_register d on d.id = r.doc_id where r.id = new.revision_id)
     is distinct from (select project_id from transmittals where id = new.transmittal_id) then raise exception 'Only this project''s documents can go on its transmittal'; end if;
  return coalesce(new, old);
end $$;
create trigger transmittal_items_guard before insert or update or delete on public.transmittal_items for each row execute function public.transmittal_item_guard();

create or replace function public.send_transmittal(p_id uuid, p_date date default current_date, p_due date default null) returns text
language plpgsql security definer set search_path = public as $$
declare t transmittals; bad text;
begin
  select * into t from transmittals where id = p_id for update;
  if not found then raise exception 'Transmittal not found'; end if;
  if not (on_project_team(t.project_id) or has_role(t.company_id, array['owner','admin'])) then raise exception 'Only the project team can send transmittals'; end if;
  if t.status <> 'draft' then raise exception '% has already been sent', t.number; end if;
  if not exists (select 1 from transmittal_items where transmittal_id = p_id) then raise exception 'Add at least one document'; end if;
  select string_agg(d.number || ' rev ' || r.rev, ', ') into bad from transmittal_items i join doc_revisions r on r.id = i.revision_id join doc_register d on d.id = r.doc_id
   where i.transmittal_id = p_id and (r.status in ('draft','in_review','rejected') or (t.purpose = 'for_construction' and r.status not in ('approved','approved_comments')));
  if bad is not null then raise exception 'Not ready to send: % (%)', bad, case when t.purpose = 'for_construction' then 'only approved documents can be issued for construction' else 'review them first' end; end if;
  perform set_config('sika.docs','on', true);
  update transmittals set status = case when purpose in ('for_approval','for_comment') then 'sent' else 'closed' end, sent_date = p_date,
         response_due = case when purpose in ('for_approval','for_comment') then coalesce(p_due, p_date + 14) end where id = p_id;
  if t.purpose in ('for_approval','for_comment') then
    update doc_revisions set status = 'submitted' where id in (select revision_id from transmittal_items where transmittal_id = p_id) and status in ('ready','approved');
  elsif t.purpose = 'for_construction' then
    update doc_revisions set issued_for_construction = true where id in (select revision_id from transmittal_items where transmittal_id = p_id);
  end if;
  perform set_config('sika.docs','off', true);
  return t.number;
end $$;

create or replace function public.record_response(p_item uuid, p_response text, p_comments text default null, p_date date default current_date) returns void
language plpgsql security definer set search_path = public as $$
declare i transmittal_items; t transmittals;
begin
  select * into i from transmittal_items where id = p_item for update;
  select * into t from transmittals where id = i.transmittal_id for update;
  if not (on_project_team(t.project_id) or has_role(t.company_id, array['owner','admin'])) then raise exception 'Only the project team can record responses'; end if;
  if t.status not in ('sent','responded') then raise exception 'Send the transmittal first'; end if;
  if p_response not in ('approved','approved_comments','rejected','noted') then raise exception 'Unknown response'; end if;
  if p_response in ('approved_comments','rejected') and coalesce(trim(p_comments), '') = '' then raise exception 'Enter the client''s comments'; end if;
  perform set_config('sika.docs','on', true);
  update transmittal_items set response = p_response, comments = p_comments, responded_at = p_date where id = p_item;
  update doc_revisions set status = case p_response when 'noted' then 'for_info' else p_response end, client_comments = p_comments, client_responded_at = p_date
   where id = i.revision_id and status = 'submitted';
  if not exists (select 1 from transmittal_items where transmittal_id = t.id and response is null) then update transmittals set status = 'responded' where id = t.id; end if;
  perform set_config('sika.docs','off', true);
end $$;

-- Every time a file is opened, it is written to the audit trail.
create or replace function public.log_doc_access(p_rev uuid) returns void
language plpgsql security definer set search_path = public as $$
declare r doc_revisions; d doc_register;
begin
  select * into r from doc_revisions where id = p_rev;
  select * into d from doc_register where id = r.doc_id;
  if not can_see_doc(d.id) then raise exception 'You cannot open this document'; end if;
  insert into audit_log (company_id, action, table_name, row_id, detail) values (d.company_id, 'document.opened', 'doc_revisions', r.id,
    jsonb_build_object('number', d.number, 'rev', r.rev, 'file', r.file_name));
end $$;

-- ---------------------------------------------------------------- 6. Risk assessments
create table public.risk_assessments (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  project_id uuid not null references public.projects(id) on delete cascade,
  number text,
  version int not null default 1,
  title text not null,
  activity text,
  location text,
  task_id uuid references public.tasks(id) on delete set null,
  assessed_by uuid default auth.uid(),
  assessed_email text,
  assessed_on date not null default current_date,
  review_date date,
  status text not null default 'draft' check (status in ('draft','approved')),
  pm_signed_by uuid, pm_signed_email text, pm_signed_at timestamptz,
  hse_signed_by uuid, hse_signed_email text, hse_signed_at timestamptz,
  notes text,
  created_at timestamptz not null default now()
);
create table public.risk_items (
  id uuid primary key default gen_random_uuid(),
  ra_id uuid not null references public.risk_assessments(id) on delete cascade,
  company_id uuid not null references public.companies(id) on delete cascade,
  hazard text not null,
  consequence text,
  who_at_risk text,
  likelihood int not null check (likelihood between 1 and 5),
  severity int not null check (severity between 1 and 5),
  controls text,
  owner text,
  residual_likelihood int check (residual_likelihood between 1 and 5),
  residual_severity int check (residual_severity between 1 and 5),
  sort int not null default 0
);
create or replace function public.risk_band(score int) returns text language sql immutable as $$
  select case when score >= 15 then 'high' when score >= 5 then 'medium' else 'low' end;
$$;
create or replace function public.ra_defaults() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    new.company_id := (select company_id from projects where id = new.project_id);
    new.number := coalesce(new.number, next_number(new.company_id, 'RA', 'RA-'));
    new.assessed_email := (select email from auth.users where id = coalesce(new.assessed_by, auth.uid()));
    new.status := 'draft';
  elsif coalesce(current_setting('sika.docs', true), '') <> 'on' and (old.status = 'approved' or new.status is distinct from old.status
        or (new.pm_signed_by, new.hse_signed_by) is distinct from (old.pm_signed_by, old.hse_signed_by)) then
    raise exception 'A signed risk assessment cannot be changed. Use Revise to start a new version.';
  end if;
  return new;
end $$;
create trigger risk_assessments_defaults before insert or update on public.risk_assessments for each row execute function public.ra_defaults();
create trigger risk_assessments_closed_project before insert on public.risk_assessments for each row execute function public.closed_project_guard();
create or replace function public.risk_item_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if (select status from risk_assessments where id = coalesce(new.ra_id, old.ra_id)) <> 'draft' and coalesce(current_setting('sika.docs', true), '') <> 'on' then
    raise exception 'A signed risk assessment cannot be changed. Use Revise to start a new version.';
  end if;
  if tg_op <> 'DELETE' then new.company_id := (select company_id from risk_assessments where id = new.ra_id); end if;
  return coalesce(new, old);
end $$;
create trigger risk_items_guard before insert or update or delete on public.risk_items for each row execute function public.risk_item_guard();

-- Sign as project manager ('pm') or health and safety officer ('hse'). Both signatures approve it.
create or replace function public.sign_risk_assessment(p_id uuid, p_as text) returns text
language plpgsql security definer set search_path = public as $$
declare a risk_assessments; pj projects; v_email text;
begin
  select * into a from risk_assessments where id = p_id for update;
  if not found then raise exception 'Risk assessment not found'; end if;
  select * into pj from projects where id = a.project_id;
  if a.status <> 'draft' then raise exception '% is already approved', a.number; end if;
  if not exists (select 1 from risk_items where ra_id = p_id) then raise exception 'Add at least one hazard'; end if;
  if exists (select 1 from risk_items where ra_id = p_id and coalesce(trim(controls), '') = '') then raise exception 'Every hazard needs its control measures'; end if;
  if exists (select 1 from risk_items where ra_id = p_id and risk_band(likelihood * severity) = 'high' and (residual_likelihood is null or residual_severity is null)) then
    raise exception 'Rate the risk left after controls for every high risk';
  end if;
  v_email := (select email from auth.users where id = auth.uid());
  perform set_config('sika.docs','on', true);
  if p_as = 'pm' then
    if not can_manage_project(a.project_id) then raise exception 'Only the project manager can sign as project manager'; end if;
    update risk_assessments set pm_signed_by = auth.uid(), pm_signed_email = v_email, pm_signed_at = now() where id = p_id;
  elsif p_as = 'hse' then
    if not (auth.uid() = pj.hse_officer_id or (pj.hse_officer_id is null and has_role(a.company_id, array['owner','admin']))) then
      raise exception 'Only the project''s health and safety officer can sign here (set one on the project)';
    end if;
    update risk_assessments set hse_signed_by = auth.uid(), hse_signed_email = v_email, hse_signed_at = now() where id = p_id;
  else raise exception 'Sign as pm or hse';
  end if;
  update risk_assessments set status = 'approved' where id = p_id and pm_signed_by is not null and hse_signed_by is not null;
  perform set_config('sika.docs','off', true);
  return (select status from risk_assessments where id = p_id);
end $$;

create or replace function public.revise_risk_assessment(p_id uuid, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare a risk_assessments;
begin
  select * into a from risk_assessments where id = p_id for update;
  if not (on_project_team(a.project_id) or has_role(a.company_id, array['owner','admin'])) then raise exception 'Only the project team can revise this'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Give the reason for the revision'; end if;
  perform set_config('sika.docs','on', true);
  update risk_assessments set status = 'draft', version = version + 1, pm_signed_by = null, pm_signed_email = null, pm_signed_at = null,
         hse_signed_by = null, hse_signed_email = null, hse_signed_at = null,
         notes = coalesce(notes || E'\n', '') || 'Version ' || (version + 1) || ' (' || to_char(current_date, 'DD Mon YYYY') || '): ' || p_reason where id = p_id;
  perform set_config('sika.docs','off', true);
end $$;

-- ---------------------------------------------------------------- 7. Documents a project must have
create table public.project_doc_requirements (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  project_id uuid not null references public.projects(id) on delete cascade,
  doc_type text not null references public.doc_types(code),
  stage text not null check (stage in ('start','close')),
  note text,
  unique (project_id, doc_type, stage)
);
create trigger project_doc_requirements_defaults before insert or update on public.project_doc_requirements for each row execute function public.material_plan_defaults();

create or replace function public.standard_doc_requirements(p_project uuid) returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not can_manage_project(p_project) then raise exception 'Only the project manager can set the required documents'; end if;
  insert into project_doc_requirements (project_id, doc_type, stage, note) values
    (p_project, 'risk_assessment', 'start', 'Approved before work starts'), (p_project, 'method_statement', 'start', 'Approved before work starts'),
    (p_project, 'as_built', 'close', null), (p_project, 'om_manual', 'close', null), (p_project, 'certificate', 'close', 'Test certificates'),
    (p_project, 'handover_cert', 'close', 'Signed by the client')
  on conflict do nothing;
  get diagnostics n = row_count;
  return n;
end $$;

-- Is each required document in place? A document counts once its current revision is approved (or filed for information).
create or replace function public.project_doc_check(p_project uuid)
returns table (doc_type text, name text, stage text, note text, satisfied boolean, docs bigint)
language sql stable security definer set search_path = public as $$
  select q.doc_type, t.name, q.stage, q.note,
    exists (select 1 from doc_register d join doc_revisions r on r.doc_id = d.id and r.superseded_at is null
             where d.project_id = p_project and d.doc_type = q.doc_type and r.status in ('approved','approved_comments','for_info'))
    or (q.doc_type = 'risk_assessment' and exists (select 1 from risk_assessments a where a.project_id = p_project and a.status = 'approved')),
    (select count(*) from doc_register d where d.project_id = p_project and d.doc_type = q.doc_type)
  from project_doc_requirements q join doc_types t on t.code = q.doc_type
  where q.project_id = p_project and exists (select 1 from projects p where p.id = p_project and is_member(p.company_id))
  order by q.stage desc, t.sort;
$$;

-- Permits, insurances, warranties and certificates that have run out or will soon.
create or replace function public.doc_expiry_alerts(cid uuid, p_days int default 30)
returns table (doc_id uuid, number text, title text, doc_type text, project_id uuid, project text, expires_on date, days_left int)
language sql stable security definer set search_path = public as $$
  select d.id, d.number, d.title, t.name, p.id, coalesce(p.number || ' ', '') || p.name, d.expires_on, d.expires_on - current_date
    from doc_register d join doc_types t on t.code = d.doc_type join projects p on p.id = d.project_id
   where d.company_id = cid and d.expires_on is not null and d.expires_on <= current_date + p_days and p.status not in ('closed','cancelled')
     and can_see_doc(d.id)
   order by d.expires_on;
$$;

-- Search documents across every project.
create or replace function public.search_documents(cid uuid, p_search text default null, p_type text default null, p_status text default null,
  p_project uuid default null, p_limit int default 50, p_offset int default 0)
returns table (doc_id uuid, number text, title text, doc_type text, type_name text, grp text, project_id uuid, project text, rev text, status text,
               revision_id uuid, updated_at timestamptz, expires_on date, confidential boolean, total bigint)
language sql stable security definer set search_path = public as $$
  with x as (
    select d.*, t.name type_name, t.grp, coalesce(p.number || ' ', '') || p.name project_name, r.rev, r.status rstatus, r.id rid, coalesce(r.created_at, d.created_at) upd
      from doc_register d join doc_types t on t.code = d.doc_type join projects p on p.id = d.project_id
      left join lateral (select * from doc_revisions r where r.doc_id = d.id order by seq desc limit 1) r on true
     where d.company_id = cid and can_see_doc(d.id)
       and (p_project is null or d.project_id = p_project) and (p_type is null or d.doc_type = p_type or t.grp = p_type)
       and (p_status is null or r.status = p_status or (p_status = 'none' and r.id is null))
       and (p_search is null or d.number ilike '%' || p_search || '%' or d.title ilike '%' || p_search || '%' or coalesce(d.discipline, '') ilike '%' || p_search || '%'
            or coalesce(r.file_name, '') ilike '%' || p_search || '%'))
  select id, number, title, doc_type, type_name, grp, project_id, project_name, rev, rstatus, rid, upd, expires_on, confidential, count(*) over ()
    from x order by upd desc limit p_limit offset p_offset;
$$;

-- Existing project files move into the register as "Other" documents, filed for information.
do $$ declare f record; v_doc uuid; begin
  for f in select * from project_documents order by created_at loop
    insert into doc_register (company_id, project_id, doc_type, seq, number, title, owner_id, created_at)
    values (f.company_id, f.project_id, 'other', 0, '', f.name, f.uploaded_by, f.created_at) returning id into v_doc;
    perform set_config('sika.docs','on', true);
    insert into doc_revisions (company_id, doc_id, seq, rev, storage_path, file_name, size_bytes, status, uploaded_by, created_at)
    values (f.company_id, v_doc, 1, 'A', f.storage_path, f.name, f.size_bytes, 'for_info', f.uploaded_by, f.created_at);
    perform set_config('sika.docs','off', true);
  end loop;
end $$;

do $$ begin
  if exists (select 1 from information_schema.schemata where schema_name = 'storage') then
    execute $q$update storage.buckets set file_size_limit = 52428800 where id = 'project-docs'$q$;
  end if;
end $$;

-- ---------------------------------------------------------------- 8. Close-out checks now cover the site store and documents
alter function public.project_close_check(uuid) rename to project_close_check_v21;
create or replace function public.project_close_check(p_project uuid)
returns table (item text, n bigint, amount numeric, severity text, hint text)
language sql stable security definer set search_path = public as $$
  select * from project_close_check_v21(p_project)
  union all select * from (
    select 'Stock still in the site store'::text item,
      (select count(*) from stock_levels sl join warehouses w on w.id = sl.warehouse_id where w.project_id = p_project and sl.qty <> 0) n,
      (select round(sum(sl.qty * p.cost), 2) from stock_levels sl join warehouses w on w.id = sl.warehouse_id join products p on p.id = sl.product_id where w.project_id = p_project) amount,
      'block'::text severity, 'Site store: send it back to the main store, transfer it to another project, or count it out'::text hint
    union all select 'Stock requests not yet received', (select count(*) from stock_requests where project_id = p_project and status in ('submitted','dispatched')), null,
      'block', 'Site store: receive or cancel them'
    union all select 'Handover documents missing', (select count(*) from project_doc_check(p_project) where stage = 'close' and not satisfied), null,
      'block', 'Documents: upload and approve them'
    union all select 'Documents waiting for the client''s response', (select count(*) from doc_revisions r join doc_register d on d.id = r.doc_id
        where d.project_id = p_project and r.status = 'submitted' and r.superseded_at is null), null, 'warn', 'Documents: record the responses'
    union all select 'Risk assessments not signed off', (select count(*) from risk_assessments where project_id = p_project and status = 'draft'), null,
      'warn', 'Risk assessments: sign them or delete drafts'
  ) x where x.n > 0
$$;
revoke execute on function public.project_close_check_v21(uuid) from public, anon, authenticated;

-- Projects made from a template copy its required documents and materials plan.
alter function public.create_project_from_template(uuid, text, uuid, date, uuid) rename to create_project_from_template_v13;
create or replace function public.create_project_from_template(p_template uuid, p_name text, p_customer uuid, p_start date, p_sales_order uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  v := create_project_from_template_v13(p_template, p_name, p_customer, p_start, p_sales_order);
  insert into project_doc_requirements (project_id, doc_type, stage, note) select v, doc_type, stage, note from project_doc_requirements where project_id = p_template;
  insert into project_material_plan (project_id, product_id, planned_qty, note) select v, product_id, planned_qty, note from project_material_plan where project_id = p_template;
  return v;
end $$;
revoke execute on function public.create_project_from_template_v13(uuid, text, uuid, date, uuid) from public, anon, authenticated;

-- Nothing new for a closed project
do $$ declare t text; begin
  foreach t in array array['stock_requests','project_material_plan','project_doc_requirements'] loop
    execute format('create trigger %I before insert on public.%I for each row execute function public.closed_project_guard()', t || '_closed_project', t);
  end loop;
end $$;

-- ---------------------------------------------------------------- 9. Row-level security
-- Store documents: the store and accountants anywhere; a project's team in its own site store.
drop policy if exists "store and managers write issues" on public.stock_issues;
create policy "store and project team write issues" on public.stock_issues for all
  using (has_role(company_id, array['owner','admin','accountant','store']) or (project_id is not null and on_project_team(project_id) and can_use_store(warehouse_id)))
  with check (has_role(company_id, array['owner','admin','accountant','store']) or (project_id is not null and on_project_team(project_id) and can_use_store(warehouse_id)));
drop policy if exists "store and managers write issue lines" on public.stock_issue_lines;
create policy "store and project team write issue lines" on public.stock_issue_lines for all
  using (exists (select 1 from stock_issues s where s.id = issue_id and (has_role(s.company_id, array['owner','admin','accountant','store']) or (s.project_id is not null and on_project_team(s.project_id) and can_use_store(s.warehouse_id)))))
  with check (exists (select 1 from stock_issues s where s.id = issue_id and (has_role(s.company_id, array['owner','admin','accountant','store']) or (s.project_id is not null and on_project_team(s.project_id) and can_use_store(s.warehouse_id)))));
drop policy if exists "store writes" on public.stock_transfers;
create policy "store writes" on public.stock_transfers for all using (can_use_store(from_warehouse_id)) with check (can_use_store(from_warehouse_id));
drop policy if exists "store writes" on public.stock_transfer_lines;
create policy "store writes" on public.stock_transfer_lines for all
  using (exists (select 1 from stock_transfers t where t.id = transfer_id and can_use_store(t.from_warehouse_id)))
  with check (exists (select 1 from stock_transfers t where t.id = transfer_id and can_use_store(t.from_warehouse_id)));
drop policy if exists "store writes" on public.stock_counts;
create policy "store writes" on public.stock_counts for all using (can_use_store(warehouse_id)) with check (can_use_store(warehouse_id));
drop policy if exists "store writes" on public.stock_count_lines;
create policy "store writes" on public.stock_count_lines for all
  using (exists (select 1 from stock_counts c where c.id = count_id and can_use_store(c.warehouse_id)))
  with check (exists (select 1 from stock_counts c where c.id = count_id and can_use_store(c.warehouse_id)));
create policy "project team sets bins" on public.stock_levels for update using (can_use_store(warehouse_id));

alter table public.stock_requests enable row level security;
alter table public.stock_request_lines enable row level security;
create policy "members read requests" on public.stock_requests for select using (is_member(company_id));
create policy "team raises requests" on public.stock_requests for insert with check (on_project_team(project_id) or has_role(company_id, array['owner','admin','accountant','store']));
create policy "team edits requests" on public.stock_requests for update using (on_project_team(project_id) or has_role(company_id, array['owner','admin','accountant','store']));
create policy "team deletes draft requests" on public.stock_requests for delete using (status = 'draft' and (on_project_team(project_id) or has_role(company_id, array['owner','admin','accountant','store'])));
create policy "members read request lines" on public.stock_request_lines for select using (is_member(company_id));
create policy "team writes request lines" on public.stock_request_lines for all
  using (exists (select 1 from stock_requests r where r.id = request_id and (on_project_team(r.project_id) or has_role(r.company_id, array['owner','admin','accountant','store']))))
  with check (exists (select 1 from stock_requests r where r.id = request_id and (on_project_team(r.project_id) or has_role(r.company_id, array['owner','admin','accountant','store']))));

alter table public.project_material_plan enable row level security;
create policy "members read plan" on public.project_material_plan for select using (is_member(company_id));
create policy "managers write plan" on public.project_material_plan for all using (can_manage_project(project_id)) with check (can_manage_project(project_id));
alter table public.project_doc_requirements enable row level security;
create policy "members read requirements" on public.project_doc_requirements for select using (is_member(company_id));
create policy "managers write requirements" on public.project_doc_requirements for all using (can_manage_project(project_id)) with check (can_manage_project(project_id));

alter table public.doc_register enable row level security;
alter table public.doc_revisions enable row level security;
create policy "members read documents" on public.doc_register for select using (can_see_doc(id));
create policy "team adds documents" on public.doc_register for insert with check (on_project_team(project_id) or has_role(company_id, array['owner','admin','accountant']));
create policy "team edits documents" on public.doc_register for update using (on_project_team(project_id) or has_role(company_id, array['owner','admin','accountant']));
create policy "managers delete documents" on public.doc_register for delete using ((can_manage_project(project_id) or has_role(company_id, array['owner','admin']))
  and not exists (select 1 from doc_revisions r where r.doc_id = id and r.status not in ('draft')));
create policy "members read revisions" on public.doc_revisions for select using (can_see_doc(doc_id));
create policy "team edits revision notes" on public.doc_revisions for update using (exists (select 1 from doc_register d where d.id = doc_id and on_project_team(d.project_id)));
create policy "team deletes draft revisions" on public.doc_revisions for delete using (status = 'draft' and exists (select 1 from doc_register d where d.id = doc_id and on_project_team(d.project_id)));

alter table public.transmittals enable row level security;
alter table public.transmittal_items enable row level security;
create policy "members read transmittals" on public.transmittals for select using (is_member(company_id));
create policy "team writes transmittals" on public.transmittals for all using (on_project_team(project_id) or has_role(company_id, array['owner','admin']))
  with check (on_project_team(project_id) or has_role(company_id, array['owner','admin']));
create policy "members read transmittal items" on public.transmittal_items for select using (is_member(company_id));
create policy "team writes transmittal items" on public.transmittal_items for all
  using (exists (select 1 from transmittals t where t.id = transmittal_id and (on_project_team(t.project_id) or has_role(t.company_id, array['owner','admin']))))
  with check (exists (select 1 from transmittals t where t.id = transmittal_id and (on_project_team(t.project_id) or has_role(t.company_id, array['owner','admin']))));

alter table public.risk_assessments enable row level security;
alter table public.risk_items enable row level security;
create policy "members read risk assessments" on public.risk_assessments for select using (is_member(company_id));
create policy "team writes risk assessments" on public.risk_assessments for all using (on_project_team(project_id) or has_role(company_id, array['owner','admin']))
  with check (on_project_team(project_id) or has_role(company_id, array['owner','admin']));
create policy "members read risk items" on public.risk_items for select using (is_member(company_id));
create policy "team writes risk items" on public.risk_items for all
  using (exists (select 1 from risk_assessments a where a.id = ra_id and (on_project_team(a.project_id) or has_role(a.company_id, array['owner','admin']))))
  with check (exists (select 1 from risk_assessments a where a.id = ra_id and (on_project_team(a.project_id) or has_role(a.company_id, array['owner','admin']))));

-- Project team members (any role) may also upload to the project's file folder; files are read only through the register.
do $$ begin
  if exists (select 1 from information_schema.schemata where schema_name = 'storage') then
    execute $q$drop policy if exists "project docs: members delete" on storage.objects$q$;
    execute $q$create policy "project docs: managers delete" on storage.objects for delete to authenticated
      using (bucket_id = 'project-docs' and public.has_role(((storage.foldername(name))[1])::uuid, array['owner','admin']))$q$;
  end if;
end $$;

do $$ declare t text; begin
  foreach t in array array['stock_requests','doc_register','doc_revisions','transmittals','risk_assessments','project_material_plan','project_doc_requirements'] loop
    execute format('create trigger %I after insert or update or delete on public.%I for each row execute function public.audit_row()', t || '_audit', t);
  end loop;
end $$;

-- Sources in the ledger
alter function public.source_ref(text, uuid) rename to source_ref_v21;
create or replace function public.source_ref(p_type text, p_id uuid, out label text, out path text)
language plpgsql stable security definer set search_path = public as $$
begin
  if p_type = 'stock_request' then select 'Stock request ' || number, '/projects/' || project_id into label, path from stock_requests where id = p_id;
  else select s.label, s.path into label, path from source_ref_v21(p_type, p_id) s; end if;
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
revoke execute on function public.seed_leave_types(uuid) from authenticated;
revoke execute on function public.seed_asset_categories(uuid) from authenticated;
revoke execute on function public.next_number(uuid,text,text) from authenticated;
revoke execute on function public.project_cost_items(uuid) from authenticated;
revoke execute on function public.project_cost_totals(uuid) from authenticated;
revoke execute on function public.finalize_expense(uuid) from authenticated;
revoke execute on function public.doc_dims(text,uuid) from authenticated;
revoke execute on function public.wh(uuid) from authenticated;
revoke execute on function public.transit_wh(uuid) from authenticated;
revoke execute on function public.ledger_checks_v20(uuid) from authenticated;
revoke execute on function public.unposted_documents_v20(uuid) from authenticated;
revoke execute on function public.project_close_check_v21(uuid) from authenticated;
revoke execute on function public.create_project_from_template_v13(uuid, text, uuid, date, uuid) from authenticated;
grant execute on function public.public_help(uuid) to anon;
grant execute on function public.submit_case_public(uuid,text,text,text,text,text) to anon;
grant execute on function public.case_status_public(text,text) to anon;
grant execute on function public.reply_case_public(text,text,text,int) to anon;
