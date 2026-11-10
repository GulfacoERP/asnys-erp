-- =====================================================================
-- Asnys ERP v2.1 — inventory, purchasing and the project lifecycle
--   1. Warehouses (stores and sites) with stock per warehouse; stock, non-stock and service items; categories, barcodes
--   2. Purchase orders to suppliers, approval, goods received notes (GRN) and three-way match into supplier bills
--   3. Stock issued from a store to a project (and returns), costed and billable to the client
--   4. Stock transfers between warehouses, stocktakes with variances, reorder suggestions, valuation and stock ledger
--   5. Supplier records: terms, bank details, price lists, performance
--   6. Project lifecycle: start, hold, resume, complete, close (with a close-out checklist), reopen, cancel; status history
-- Run after 0006.
-- =====================================================================

-- ---------------------------------------------------------------- 1. Accounts and roles
create or replace function public.seed_accounts_v21(cid uuid)
returns void language sql security definer set search_path = public as $$
  insert into accounts (company_id, code, name, type, system_key) values
  (cid,'2050','Goods received not yet invoiced','liability','grni'),
  (cid,'5150','Purchase price variance','expense','ppv')
  on conflict do nothing;
$$;
select public.seed_accounts_v21(id) from public.companies;

alter table public.memberships drop constraint if exists memberships_role_check;
alter table public.memberships add constraint memberships_role_check
  check (role in ('owner','admin','accountant','sales','hr','project_manager','store','staff'));
create or replace function public.add_member(cid uuid, p_email text, p_role text)
returns void language plpgsql security definer set search_path = public as $$
declare v_user uuid;
begin
  perform require_member(cid, array['owner','admin']);
  if p_role not in ('admin','accountant','sales','hr','project_manager','store','staff') then raise exception 'Choose a valid role'; end if;
  select id into v_user from auth.users where lower(email) = lower(trim(p_email));
  if v_user is null then
    raise exception 'No account uses %. Ask them to sign up first, then add them again.', p_email;
  end if;
  insert into memberships (company_id, user_id, email, role) values (cid, v_user, lower(trim(p_email)), p_role)
  on conflict (company_id, user_id) do update set role = excluded.role;
end $$;
alter table public.approval_rules drop constraint if exists approval_rules_approver_role_check;
alter table public.approval_rules add constraint approval_rules_approver_role_check
  check (approver_role in ('owner','admin','accountant','sales','hr','project_manager','store'));

-- ---------------------------------------------------------------- 2. Warehouses and stock per warehouse
create table public.warehouses (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  code text not null,
  name text not null,
  kind text not null default 'store' check (kind in ('store','site','vehicle','shop')),
  address text,
  branch_id uuid references public.branches(id) on delete set null,
  project_id uuid references public.projects(id) on delete set null,     -- a site store for one project
  is_default boolean not null default false,
  active boolean not null default true,
  unique (company_id, code)
);
create unique index warehouses_one_default on public.warehouses (company_id) where is_default;

create or replace function public.wh(cid uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  select id into v from warehouses where company_id = cid and is_default;
  if v is null then
    insert into warehouses (company_id, code, name, is_default) values (cid, 'MAIN', 'Main store', true)
    on conflict (company_id, code) do update set is_default = true returning id into v;
  end if;
  return v;
end $$;
select public.wh(id) from public.companies;

create table public.stock_levels (
  company_id uuid not null references public.companies(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete cascade,
  warehouse_id uuid not null references public.warehouses(id) on delete cascade,
  qty numeric(14,3) not null default 0,
  bin text,
  primary key (product_id, warehouse_id)
);

alter table public.stock_moves add column if not exists warehouse_id uuid references public.warehouses(id);
alter table public.stock_moves add column if not exists project_id uuid references public.projects(id) on delete set null;
update public.stock_moves m set warehouse_id = public.wh(m.company_id) where warehouse_id is null;
insert into public.stock_levels (company_id, product_id, warehouse_id, qty)
select p.company_id, p.id, public.wh(p.company_id), p.stock_qty from public.products p where p.stock_qty <> 0
on conflict do nothing;
create index if not exists stock_moves_product on public.stock_moves (product_id, move_date);

alter table public.invoices add column if not exists warehouse_id uuid references public.warehouses(id) on delete set null;
alter table public.bills add column if not exists warehouse_id uuid references public.warehouses(id) on delete set null;
alter table public.credit_notes add column if not exists warehouse_id uuid references public.warehouses(id) on delete set null;

create or replace function public.stock_move_warehouse() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if (select item_type from products where id = new.product_id) <> 'stock' then
    raise exception '% is not kept in stock, so it has no stock to move', (select name from products where id = new.product_id);
  end if;
  if new.warehouse_id is null then
    if new.ref_type = 'invoice' then new.warehouse_id := (select warehouse_id from invoices where id = new.ref_id);
    elsif new.ref_type = 'bill' then new.warehouse_id := (select warehouse_id from bills where id = new.ref_id);
    elsif new.ref_type = 'credit_note' then new.warehouse_id := (select warehouse_id from credit_notes where id = new.ref_id);
    end if;
    new.warehouse_id := coalesce(new.warehouse_id, wh(new.company_id));
  end if;
  return new;
end $$;
create trigger stock_moves_warehouse before insert on public.stock_moves for each row execute function public.stock_move_warehouse();

create or replace function public.stock_move_level() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into stock_levels (company_id, product_id, warehouse_id, qty) values (new.company_id, new.product_id, new.warehouse_id, new.qty)
  on conflict (product_id, warehouse_id) do update set qty = stock_levels.qty + excluded.qty;
  return null;
end $$;
create trigger stock_moves_level after insert on public.stock_moves for each row execute function public.stock_move_level();

-- ---------------------------------------------------------------- 3. Items
alter table public.products add column if not exists item_type text not null default 'stock' check (item_type in ('stock','non_stock','service'));
alter table public.products add column if not exists category text;
alter table public.products add column if not exists barcode text;
alter table public.products add column if not exists brand text;
alter table public.products add column if not exists description text;
alter table public.products add column if not exists reorder_qty numeric(14,3) not null default 0;
alter table public.products add column if not exists max_level numeric(14,3);
alter table public.products add column if not exists preferred_supplier_id uuid references public.suppliers(id) on delete set null;
alter table public.products add column if not exists last_purchase_cost numeric(14,4);
alter table public.products add column if not exists expense_account_id uuid references public.accounts(id) on delete set null;   -- for non-stock and service purchases
create unique index if not exists products_barcode on public.products (company_id, barcode) where barcode is not null and barcode <> '';

-- ---------------------------------------------------------------- 4. Suppliers
alter table public.suppliers add column if not exists contact_name text;
alter table public.suppliers add column if not exists category text;
alter table public.suppliers add column if not exists payment_terms_days int not null default 30;
alter table public.suppliers add column if not exists bank_name text;
alter table public.suppliers add column if not exists bank_account text;
alter table public.suppliers add column if not exists momo_number text;
alter table public.suppliers add column if not exists notes text;
alter table public.suppliers add column if not exists active boolean not null default true;

create table public.supplier_items (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  supplier_id uuid not null references public.suppliers(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete cascade,
  supplier_sku text,
  price numeric(14,2) not null default 0,     -- GHS, excluding VAT
  lead_days int,
  min_qty numeric(14,3),
  unique (supplier_id, product_id)
);

-- ---------------------------------------------------------------- 5. Purchase orders, goods received, three-way match
create table public.purchase_orders (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  number text,
  supplier_id uuid not null references public.suppliers(id),
  order_date date not null default current_date,
  expected_date date,
  warehouse_id uuid references public.warehouses(id) on delete set null,
  project_id uuid references public.projects(id) on delete set null,      -- deliver straight to this project
  branch_id uuid references public.branches(id) on delete set null,
  status text not null default 'draft' check (status in ('draft','approved','sent','partial','received','closed','cancelled')),
  notes text,
  terms text,
  created_by uuid default auth.uid(),
  approved_by uuid,
  approved_at timestamptz,
  created_at timestamptz not null default now()
);
create table public.po_lines (
  id uuid primary key default gen_random_uuid(),
  po_id uuid not null references public.purchase_orders(id) on delete cascade,
  company_id uuid not null references public.companies(id) on delete cascade,
  product_id uuid references public.products(id),
  account_id uuid references public.accounts(id),       -- for services or items not kept in stock
  description text not null,
  qty numeric(14,3) not null check (qty > 0),
  unit_cost numeric(14,2) not null default 0 check (unit_cost >= 0),   -- GHS, excluding VAT
  taxable boolean not null default true,
  received_qty numeric(14,3) not null default 0,
  billed_qty numeric(14,3) not null default 0,
  project_id uuid references public.projects(id) on delete set null,
  request_id uuid references public.project_requests(id) on delete set null,
  sort int not null default 0
);
create index on public.po_lines (po_id);
create index on public.po_lines (project_id) where project_id is not null;
alter table public.bill_lines add column if not exists po_line_id uuid references public.po_lines(id) on delete set null;
alter table public.bill_lines add column if not exists billable boolean not null default false;
alter table public.bill_lines add column if not exists invoice_id uuid references public.invoices(id) on delete set null;

create table public.goods_receipts (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  number text not null,
  po_id uuid not null references public.purchase_orders(id),
  supplier_id uuid not null references public.suppliers(id),
  receipt_date date not null,
  warehouse_id uuid references public.warehouses(id),
  reference text,            -- supplier's delivery note / waybill
  notes text,
  received_by uuid default auth.uid(),
  journal_entry_id uuid references public.journal_entries(id),
  created_at timestamptz not null default now()
);
create table public.goods_receipt_lines (
  id uuid primary key default gen_random_uuid(),
  receipt_id uuid not null references public.goods_receipts(id) on delete cascade,
  company_id uuid not null references public.companies(id) on delete cascade,
  po_line_id uuid not null references public.po_lines(id),
  product_id uuid references public.products(id),
  qty numeric(14,3) not null,
  unit_cost numeric(14,2) not null,
  project_id uuid references public.projects(id) on delete set null
);

alter table public.project_requests drop constraint if exists project_requests_status_check;
alter table public.project_requests add constraint project_requests_status_check
  check (status in ('draft','submitted','approved','rejected','ordered','billed','cancelled'));
create or replace function public.project_request_defaults() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    new.company_id := (select company_id from projects where id = new.project_id);
    if new.number is null then new.number := next_number(new.company_id, 'PR', 'PR-'); end if;
    new.requested_by := coalesce(auth.uid(), new.requested_by);
    new.requested_email := (select email from auth.users where id = new.requested_by);
    if new.status not in ('draft','submitted') then raise exception 'New requests start as draft or submitted'; end if;
  elsif new.status is distinct from old.status and new.status in ('approved','rejected','billed','ordered')
        and coalesce(current_setting('sika.requests', true), '') <> 'on' then
    raise exception 'Use Approve or Reject to decide a request';
  end if;
  if tg_op = 'UPDATE' and old.status in ('approved','billed','ordered') and coalesce(current_setting('sika.requests', true), '') <> 'on'
     and (new.qty, new.est_unit_cost, new.project_id) is distinct from (old.qty, old.est_unit_cost, old.project_id) then
    raise exception 'An approved request cannot be changed. Cancel it and raise a new one.';
  end if;
  return new;
end $$;

create or replace function public.po_defaults() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    if new.number is null then new.number := next_number(new.company_id, 'PO', 'PO-'); end if;
    if new.status <> 'draft' then raise exception 'A new purchase order starts as a draft'; end if;
    new.warehouse_id := coalesce(new.warehouse_id, case when new.project_id is null then wh(new.company_id) end);
  elsif new.status is distinct from old.status and coalesce(current_setting('sika.po', true), '') <> 'on' then
    raise exception 'Use Approve, Receive, Close or Cancel to change a purchase order';
  end if;
  return new;
end $$;
create trigger purchase_orders_defaults before insert or update on public.purchase_orders for each row execute function public.po_defaults();

create or replace function public.po_line_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare st text;
begin
  select status into st from purchase_orders where id = coalesce(new.po_id, old.po_id);
  if st <> 'draft' and coalesce(current_setting('sika.po', true), '') <> 'on' then raise exception 'Only a draft purchase order can be changed'; end if;
  if tg_op <> 'DELETE' and new.product_id is null and new.account_id is null and new.project_id is null then
    raise exception 'Each line needs an item, an expense account or a project';
  end if;
  return coalesce(new, old);
end $$;
create trigger po_lines_guard before insert or update or delete on public.po_lines for each row execute function public.po_line_guard();

create or replace function public.po_total(p uuid) returns numeric language sql stable as $$
  select coalesce(round(sum(qty * unit_cost), 2), 0) from po_lines where po_id = p;
$$;

-- Approval chains cover purchase orders too.
alter table public.approval_rules drop constraint if exists approval_rules_doc_type_check;
alter table public.approval_rules add constraint approval_rules_doc_type_check
  check (doc_type in ('bill','payroll','purchase_request','expense_claim','purchase_order'));
create or replace function public.doc_info(p_type text, p_id uuid, out company_id uuid, out amount numeric, out label text, out path text)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  if p_type = 'bill' then
    select b.company_id, round(coalesce((select sum(qty * unit_cost) from bill_lines where bill_id = b.id), 0) * b.exchange_rate, 2),
           coalesce(b.number, 'Draft bill') || ' · ' || coalesce(s.name, '') || coalesce(' · ' || b.supplier_ref, ''), '/bills/' || b.id
      into company_id, amount, label, path from bills b left join suppliers s on s.id = b.supplier_id where b.id = p_id;
  elsif p_type = 'payroll' then
    select r.company_id, r.gross, 'Payroll ' || to_char(r.period, 'Mon YYYY'), '/payroll/' || r.id into company_id, amount, label, path from payroll_runs r where r.id = p_id;
  elsif p_type = 'purchase_request' then
    select r.company_id, round(r.qty * r.est_unit_cost, 2), r.number || ' · ' || r.description || ' · ' || p.name, '/projects/' || r.project_id
      into company_id, amount, label, path from project_requests r join projects p on p.id = r.project_id where r.id = p_id;
  elsif p_type = 'expense_claim' then
    select x.company_id, x.amount_home, 'Expense claim · ' || e.full_name || ' · ' || x.description, '/approvals'
      into company_id, amount, label, path from expense_claims x left join employees e on e.id = x.employee_id where x.id = p_id;
  elsif p_type = 'purchase_order' then
    select o.company_id, po_total(o.id), o.number || ' · ' || s.name, '/purchase-orders/' || o.id
      into company_id, amount, label, path from purchase_orders o join suppliers s on s.id = o.supplier_id where o.id = p_id;
  end if;
end $$;

create or replace function public.approve_po(p_po uuid) returns void
language plpgsql security definer set search_path = public as $$
declare o purchase_orders; st text;
begin
  select * into o from purchase_orders where id = p_po for update;
  if not found then raise exception 'Purchase order not found'; end if;
  perform require_member(o.company_id, array['owner','admin','accountant']);
  if o.status <> 'draft' then raise exception '% is already %', o.number, o.status; end if;
  if not exists (select 1 from po_lines where po_id = p_po) then raise exception 'Add at least one line'; end if;
  st := approval_state('purchase_order', p_po);
  if st in ('not_started','pending','rejected','changed') then
    raise exception '% needs approval first (%). Submit it for approval.', o.number,
      case st when 'not_started' then 'not submitted yet' when 'pending' then 'still waiting' when 'rejected' then 'it was rejected' else 'the amount went up after approval' end;
  end if;
  perform set_config('sika.po','on', true);
  update purchase_orders set status = 'approved', approved_by = auth.uid(), approved_at = now() where id = p_po;
  perform set_config('sika.po','off', true);
end $$;

create or replace function public.set_po_status(p_po uuid, p_status text) returns void
language plpgsql security definer set search_path = public as $$
declare o purchase_orders;
begin
  select * into o from purchase_orders where id = p_po for update;
  if not found then raise exception 'Purchase order not found'; end if;
  perform require_member(o.company_id, array['owner','admin','accountant','store']);
  if p_status = 'sent' and o.status <> 'approved' then raise exception 'Approve the order before sending it';
  elsif p_status = 'cancelled' then
    if exists (select 1 from po_lines where po_id = p_po and (received_qty > 0 or billed_qty > 0)) then raise exception 'Goods were received or billed on this order. Close it instead.'; end if;
    perform set_config('sika.requests','on', true);
    update project_requests set status = 'approved' where id in (select request_id from po_lines where po_id = p_po) and status = 'ordered';
    perform set_config('sika.requests','off', true);
  elsif p_status = 'closed' and o.status not in ('partial','received','sent','approved') then raise exception 'Only an open order can be closed';
  elsif p_status not in ('sent','cancelled','closed') then raise exception 'Unknown status';
  end if;
  perform set_config('sika.po','on', true);
  update purchase_orders set status = p_status where id = p_po;
  perform set_config('sika.po','off', true);
end $$;

-- One purchase order from approved project purchase requests.
create or replace function public.po_from_requests(p_ids uuid[], p_supplier uuid, p_expected date default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare cid uuid; v_po uuid; r record; i int := 0; v_proj uuid;
begin
  select company_id into cid from project_requests where id = any(p_ids) limit 1;
  if cid is null then raise exception 'Choose at least one request'; end if;
  perform require_member(cid, array['owner','admin','accountant','store']);
  if exists (select 1 from project_requests where id = any(p_ids) and (company_id <> cid or status <> 'approved')) then
    raise exception 'Only approved requests can go on a purchase order';
  end if;
  select case when count(distinct project_id) = 1 then min(project_id::text)::uuid end into v_proj from project_requests where id = any(p_ids);
  insert into purchase_orders (company_id, supplier_id, expected_date, project_id, notes)
  values (cid, p_supplier, p_expected, v_proj, 'From purchase requests ' || (select string_agg(number, ', ' order by number) from project_requests where id = any(p_ids)))
  returning id into v_po;
  for r in select * from project_requests where id = any(p_ids) order by number loop
    insert into po_lines (po_id, company_id, product_id, account_id, description, qty, unit_cost, project_id, request_id, sort)
    values (v_po, cid, case when r.kind = 'material' then r.product_id end,
      case when r.kind = 'material' and r.product_id is not null then null
           else coalesce(case when r.kind = 'other' then r.account_id end,
                         acct(cid, case r.kind when 'material' then 'project_materials' when 'subcontract' then 'subcontract' when 'equipment' then 'equipment_hire' else 'expense' end)) end,
      r.number || ' — ' || r.description, r.qty, r.est_unit_cost, r.project_id, r.id, i);
    i := i + 1;
  end loop;
  perform set_config('sika.requests','on', true);
  update project_requests set status = 'ordered', supplier_id = coalesce(supplier_id, p_supplier) where id = any(p_ids);
  perform set_config('sika.requests','off', true);
  return v_po;
end $$;

-- Goods received note: stock into the store (or straight to the project), accrued against 2050 until the supplier's bill arrives.
create or replace function public.receive_po(p_po uuid, p_lines jsonb, p_date date default current_date, p_warehouse uuid default null, p_reference text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare o purchase_orders; l record; pl po_lines; pr products; v_grn uuid; v_wh uuid; v_lines jsonb := '[]'::jsonb; v_total numeric := 0; v_amt numeric; v_acct uuid; v_je uuid; n int := 0;
begin
  select * into o from purchase_orders where id = p_po for update;
  if not found then raise exception 'Purchase order not found'; end if;
  perform require_member(o.company_id, array['owner','admin','accountant','store']);
  if o.status not in ('approved','sent','partial') then raise exception 'Only an approved, open order can be received (this one is %)', o.status; end if;
  v_wh := coalesce(p_warehouse, o.warehouse_id, wh(o.company_id));
  if not exists (select 1 from warehouses where id = v_wh and company_id = o.company_id) then raise exception 'Choose one of your warehouses'; end if;
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

-- Draft supplier bill for what was received (or ordered) and not yet billed. The accountant checks prices against the supplier's invoice and posts.
create or replace function public.bill_from_po(p_po uuid, p_ref text default null, p_date date default current_date, p_all boolean default false)
returns uuid language plpgsql security definer set search_path = public as $$
declare o purchase_orders; v_bill uuid; l record; i int := 0; q numeric;
begin
  select * into o from purchase_orders where id = p_po;
  if not found then raise exception 'Purchase order not found'; end if;
  perform require_member(o.company_id, array['owner','admin','accountant']);
  if o.status in ('draft','cancelled') then raise exception 'Approve the order first'; end if;
  insert into bills (company_id, supplier_id, supplier_ref, bill_date, warehouse_id, branch_id, currency, exchange_rate, notes)
  values (o.company_id, o.supplier_id, p_ref, p_date, o.warehouse_id, o.branch_id, 'GHS', 1, 'Purchase order ' || o.number) returning id into v_bill;
  for l in select * from po_lines where po_id = p_po order by sort loop
    q := case when p_all then l.qty - l.billed_qty else l.received_qty - l.billed_qty end;
    continue when q <= 0;
    insert into bill_lines (bill_id, company_id, product_id, account_id, description, qty, unit_cost, taxable, sort, project_id, request_id, po_line_id)
    values (v_bill, o.company_id, l.product_id, case when l.product_id is null then coalesce(l.account_id, acct(o.company_id, case when l.project_id is not null then 'project_materials' else 'expense' end)) end, l.description, q, l.unit_cost, l.taxable, i, l.project_id, l.request_id, l.id);
    i := i + 1;
  end loop;
  if i = 0 then delete from bills where id = v_bill; raise exception 'Nothing on this order is waiting to be billed. Receive the goods first.'; end if;
  return v_bill;
end $$;

-- Supplier bills: stock and non-stock items, purchase-order matching (GRNI and price variance), projects and cost centres.
create or replace function public.post_bill(p_bill uuid)
returns text language plpgsql security definer set search_path = public as $$
declare
  b bills; l record; pr products; pl po_lines; v_lines jsonb := '[]'::jsonb; x numeric; v_dims jsonb;
  v_taxable numeric := 0; v_sub numeric := 0; v_amt numeric; g_amt numeric; g_sum numeric := 0; v_q numeric; v_r numeric; v_grni numeric; v_part numeric;
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
      if v_q > 0 then   -- already received: clear the accrual, price difference to 5150
        v_grni := round(v_q * pl.unit_cost, 2);
        v_part := round(g_amt * v_q / l.qty, 2);
        v_lines := v_lines || jl(acct(b.company_id,'grni'), v_grni, 0)
                           || (jl(acct(b.company_id,'ppv'), greatest(v_part - v_grni, 0), greatest(v_grni - v_part, 0)) || v_dims);
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

-- Sales invoices: service and non-stock items do not touch stock; stock comes out of the invoice's warehouse.
create or replace function public.post_invoice(p_invoice uuid)
returns text language plpgsql security definer set search_path = public as $$
declare
  inv invoices; l record; p products; x numeric; v_wh uuid; v_have numeric;
  v_taxable numeric := 0; v_sub numeric := 0; v_goods numeric := 0; v_services numeric := 0; v_cogs numeric := 0;
  v_vat numeric; v_nhil numeric; v_getf numeric; v_total numeric; v_je uuid; v_no text;
  g_goods numeric; g_serv numeric; g_vat numeric; g_nhil numeric; g_getf numeric;
begin
  select * into inv from invoices where id = p_invoice for update;
  if not found then raise exception 'Invoice not found'; end if;
  perform require_member(inv.company_id, array['owner','admin','accountant','sales']);
  if inv.status <> 'draft' then raise exception 'This invoice is already posted'; end if;
  if not exists (select 1 from invoice_lines where invoice_id = p_invoice) then raise exception 'Add at least one line'; end if;
  if tax_rate('VAT', inv.invoice_date) is null then raise exception 'No VAT rate is set for %', inv.invoice_date; end if;
  x := inv.exchange_rate; v_wh := coalesce(inv.warehouse_id, wh(inv.company_id));

  perform set_config('sika.posting','on', true);
  for l in select * from invoice_lines where invoice_id = p_invoice order by sort loop
    v_sub := v_sub + round(l.qty * l.unit_price, 2);
    if l.taxable then v_taxable := v_taxable + round(l.qty * l.unit_price, 2); end if;
    p := null;
    if l.product_id is not null then select * into p from products where id = l.product_id for update; end if;
    if p.id is not null and p.item_type = 'stock' then
      select coalesce(sum(qty), 0) into v_have from stock_levels where product_id = p.id and warehouse_id = v_wh;
      if v_have < l.qty then
        raise exception 'Only % % of % in stock at %', v_have, p.unit, p.name, (select name from warehouses where id = v_wh);
      end if;
      update products set stock_qty = stock_qty - l.qty where id = p.id;
      insert into stock_moves (company_id, product_id, warehouse_id, move_date, qty, unit_cost, reason, ref_type, ref_id)
      values (inv.company_id, p.id, v_wh, inv.invoice_date, -l.qty, p.cost, 'Sale', 'invoice', inv.id);
      v_cogs := v_cogs + round(l.qty * p.cost, 2);
      v_goods := v_goods + round(l.qty * l.unit_price, 2);
    elsif p.id is not null and p.item_type = 'non_stock' then
      v_goods := v_goods + round(l.qty * l.unit_price, 2);
    else
      v_services := v_services + round(l.qty * l.unit_price, 2);
    end if;
  end loop;
  perform set_config('sika.posting','off', true);

  v_vat := round(v_taxable * tax_rate('VAT', inv.invoice_date), 2);
  v_nhil := round(v_taxable * tax_rate('NHIL', inv.invoice_date), 2);
  v_getf := round(v_taxable * tax_rate('GETFUND', inv.invoice_date), 2);
  v_total := v_sub + v_vat + v_nhil + v_getf;
  g_goods := round(v_goods * x, 2); g_serv := round(v_services * x, 2);
  g_vat := round(v_vat * x, 2); g_nhil := round(v_nhil * x, 2); g_getf := round(v_getf * x, 2);
  v_no := next_number(inv.company_id, 'INV', 'INV-');
  v_je := post_journal(inv.company_id, inv.invoice_date, 'Invoice ' || v_no || case when inv.currency <> 'GHS' then ' (' || inv.currency || ' at ' || x || ')' else '' end,
    jsonb_build_array(
      jl(acct(inv.company_id,'ar'), g_goods + g_serv + g_vat + g_nhil + g_getf, 0),
      jl(acct(inv.company_id,'sales'), 0, g_goods),
      jl(acct(inv.company_id,'services'), 0, g_serv),
      jl(acct(inv.company_id,'vat_out'), 0, g_vat),
      jl(acct(inv.company_id,'nhil_out'), 0, g_nhil),
      jl(acct(inv.company_id,'getf_out'), 0, g_getf),
      jl(acct(inv.company_id,'cogs'), v_cogs, 0),
      jl(acct(inv.company_id,'inventory'), 0, v_cogs)),
    'invoice', inv.id);
  update invoices set status = 'posted', number = v_no, subtotal = v_sub, vat = v_vat, nhil = v_nhil,
         getfund = v_getf, total = v_total, journal_entry_id = v_je, due_date = coalesce(due_date, invoice_date + 30)
   where id = p_invoice;
  return v_no;
end $$;

-- ---------------------------------------------------------------- 6. Stock issued to projects (and returned)
create table public.stock_issues (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  number text,
  kind text not null default 'issue' check (kind in ('issue','return')),
  warehouse_id uuid not null references public.warehouses(id),
  project_id uuid references public.projects(id) on delete set null,
  cost_centre_id uuid references public.cost_centres(id) on delete set null,
  account_id uuid references public.accounts(id),       -- for internal use without a project (default 6900)
  issue_date date not null default current_date,
  issued_to text,                                       -- person or site collecting
  notes text,
  status text not null default 'draft' check (status in ('draft','posted')),
  journal_entry_id uuid references public.journal_entries(id),
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);
create table public.stock_issue_lines (
  id uuid primary key default gen_random_uuid(),
  issue_id uuid not null references public.stock_issues(id) on delete cascade,
  company_id uuid not null references public.companies(id) on delete cascade,
  product_id uuid not null references public.products(id),
  qty numeric(14,3) not null check (qty > 0),
  unit_cost numeric(14,4),                              -- average cost when posted
  billable boolean not null default false,
  bill_price numeric(14,2),                             -- price to the client (project currency), default the selling price
  invoice_id uuid references public.invoices(id) on delete set null,
  sort int not null default 0
);
create index on public.stock_issue_lines (issue_id);

create or replace function public.stock_issue_defaults() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' and new.number is null then
    new.number := next_number(new.company_id, case when new.kind = 'return' then 'RET' else 'ISS' end, case when new.kind = 'return' then 'RET-' else 'ISS-' end);
  end if;
  if tg_op = 'INSERT' and new.status <> 'draft' then raise exception 'A new stock issue starts as a draft'; end if;
  if tg_op = 'UPDATE' and old.status = 'posted' and coalesce(current_setting('sika.posting', true), '') <> 'on' then raise exception 'A posted stock issue cannot be changed'; end if;
  return new;
end $$;
create trigger stock_issues_defaults before insert or update on public.stock_issues for each row execute function public.stock_issue_defaults();
create or replace function public.stock_issue_line_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if (select status from stock_issues where id = coalesce(new.issue_id, old.issue_id)) = 'posted'
     and coalesce(current_setting('sika.posting', true), '') <> 'on' then raise exception 'A posted stock issue cannot be changed'; end if;
  return coalesce(new, old);
end $$;
create trigger stock_issue_lines_guard before insert or update or delete on public.stock_issue_lines for each row execute function public.stock_issue_line_guard();

create or replace function public.post_stock_issue(p_id uuid) returns text
language plpgsql security definer set search_path = public as $$
declare s stock_issues; l record; p products; v_have numeric; v_val numeric := 0; v_amt numeric; v_target uuid; v_sign int; v_je uuid;
begin
  select * into s from stock_issues where id = p_id for update;
  if not found then raise exception 'Stock issue not found'; end if;
  if not (has_role(s.company_id, array['owner','admin','accountant','store']) or (s.project_id is not null and can_manage_project(s.project_id))) then
    raise exception 'Only the store, an accountant or the project''s manager can post this';
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

-- ---------------------------------------------------------------- 7. Transfers between warehouses
create table public.stock_transfers (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  number text,
  from_warehouse_id uuid not null references public.warehouses(id),
  to_warehouse_id uuid not null references public.warehouses(id),
  transfer_date date not null default current_date,
  notes text,
  status text not null default 'draft' check (status in ('draft','posted')),
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  check (from_warehouse_id <> to_warehouse_id)
);
create table public.stock_transfer_lines (
  id uuid primary key default gen_random_uuid(),
  transfer_id uuid not null references public.stock_transfers(id) on delete cascade,
  company_id uuid not null references public.companies(id) on delete cascade,
  product_id uuid not null references public.products(id),
  qty numeric(14,3) not null check (qty > 0)
);
create or replace function public.transfer_defaults() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then new.number := coalesce(new.number, next_number(new.company_id, 'TRF', 'TRF-')); new.status := 'draft';
  elsif old.status = 'posted' and coalesce(current_setting('sika.posting', true), '') <> 'on' then raise exception 'A posted transfer cannot be changed'; end if;
  return new;
end $$;
create trigger stock_transfers_defaults before insert or update on public.stock_transfers for each row execute function public.transfer_defaults();

create or replace function public.post_transfer(p_id uuid) returns text
language plpgsql security definer set search_path = public as $$
declare t stock_transfers; l record; p products; v_have numeric;
begin
  select * into t from stock_transfers where id = p_id for update;
  if not found then raise exception 'Transfer not found'; end if;
  perform require_member(t.company_id, array['owner','admin','accountant','store']);
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

-- ---------------------------------------------------------------- 8. Stocktakes
create table public.stock_counts (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  number text,
  warehouse_id uuid not null references public.warehouses(id),
  count_date date not null default current_date,
  notes text,
  status text not null default 'draft' check (status in ('draft','posted')),
  journal_entry_id uuid references public.journal_entries(id),
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);
create table public.stock_count_lines (
  id uuid primary key default gen_random_uuid(),
  count_id uuid not null references public.stock_counts(id) on delete cascade,
  company_id uuid not null references public.companies(id) on delete cascade,
  product_id uuid not null references public.products(id),
  system_qty numeric(14,3) not null,
  counted_qty numeric(14,3),
  unit_cost numeric(14,4),
  unique (count_id, product_id)
);

create or replace function public.start_stock_count(cid uuid, p_warehouse uuid, p_date date default current_date, p_category text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  perform require_member(cid, array['owner','admin','accountant','store']);
  if not exists (select 1 from warehouses where id = p_warehouse and company_id = cid) then raise exception 'Choose one of your warehouses'; end if;
  insert into stock_counts (company_id, number, warehouse_id, count_date, notes)
  values (cid, next_number(cid, 'CNT', 'CNT-'), p_warehouse, p_date, case when p_category is not null then 'Category: ' || p_category end) returning id into v;
  insert into stock_count_lines (count_id, company_id, product_id, system_qty)
  select v, cid, p.id, coalesce(sl.qty, 0) from products p left join stock_levels sl on sl.product_id = p.id and sl.warehouse_id = p_warehouse
   where p.company_id = cid and p.item_type = 'stock' and p.active and (p_category is null or p.category = p_category)
   order by p.name;
  return v;
end $$;

-- Post the count: every difference adjusts stock at average cost (Dr/Cr 5100 Stock adjustments).
create or replace function public.post_stock_count(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c stock_counts; l record; p products; v_now numeric; v_diff numeric; v_gain numeric := 0; v_loss numeric := 0; n int := 0; v_je uuid;
begin
  select * into c from stock_counts where id = p_id for update;
  if not found then raise exception 'Stock count not found'; end if;
  perform require_member(c.company_id, array['owner','admin','accountant']);
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
  update stock_counts set status = 'posted' where id = p_id;
  if v_gain + v_loss > 0 then
    v_je := post_journal(c.company_id, c.count_date, 'Stocktake ' || c.number || ' at ' || (select name from warehouses where id = c.warehouse_id),
      jsonb_build_array(jl(acct(c.company_id,'inventory'), v_gain, v_loss), jl(acct(c.company_id,'stock_adj'), v_loss, v_gain)), 'stock_count', c.id);
    update stock_counts set journal_entry_id = v_je where id = p_id;
  end if;
  perform set_config('sika.posting','off', true);
  return jsonb_build_object('lines_adjusted', n, 'gain', v_gain, 'loss', v_loss);
end $$;

-- Stock tables are changed only by posting functions.
create or replace function public.stock_doc_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare st text;
begin
  if tg_table_name = 'stock_transfer_lines' then select status into st from stock_transfers where id = coalesce(new.transfer_id, old.transfer_id);
  else select status into st from stock_counts where id = coalesce(new.count_id, old.count_id); end if;
  if st = 'posted' and coalesce(current_setting('sika.posting', true), '') <> 'on' then raise exception 'This document is posted and cannot be changed'; end if;
  return coalesce(new, old);
end $$;
create trigger stock_transfer_lines_guard before insert or update or delete on public.stock_transfer_lines for each row execute function public.stock_doc_guard();
create trigger stock_count_lines_guard before insert or update or delete on public.stock_count_lines for each row execute function public.stock_doc_guard();
create or replace function public.stock_count_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'UPDATE' and old.status = 'posted' and coalesce(current_setting('sika.posting', true), '') <> 'on' then raise exception 'A posted stocktake cannot be changed'; end if;
  return new;
end $$;
create trigger stock_counts_guard before update on public.stock_counts for each row execute function public.stock_count_guard();

-- ---------------------------------------------------------------- 9. Reports
create or replace function public.stock_valuation(cid uuid, p_warehouse uuid default null)
returns table (product_id uuid, sku text, name text, category text, unit text, qty numeric, cost numeric, value numeric,
               reorder_level numeric, on_order numeric, last_move date)
language sql stable security definer set search_path = public as $$
  select p.id, p.sku, p.name, p.category, p.unit,
         case when p_warehouse is null then p.stock_qty else coalesce((select qty from stock_levels where product_id = p.id and warehouse_id = p_warehouse), 0) end,
         p.cost,
         round(p.cost * case when p_warehouse is null then p.stock_qty else coalesce((select qty from stock_levels where product_id = p.id and warehouse_id = p_warehouse), 0) end, 2),
         p.reorder_level,
         coalesce((select sum(l.qty - l.received_qty) from po_lines l join purchase_orders o on o.id = l.po_id
                    where l.product_id = p.id and o.status in ('approved','sent','partial') and l.project_id is null), 0),
         (select max(move_date) from stock_moves m where m.product_id = p.id and (p_warehouse is null or m.warehouse_id = p_warehouse))
    from products p
   where p.company_id = cid and p.item_type = 'stock' and is_member(cid)
   order by p.name;
$$;

create or replace function public.stock_ledger(cid uuid, p_product uuid, p_from date, p_to date, p_warehouse uuid default null)
returns table (move_id uuid, move_date date, warehouse text, reason text, ref_type text, ref_id uuid, project text, qty_in numeric, qty_out numeric,
               balance numeric, unit_cost numeric, value numeric, opening numeric)
language sql stable security definer set search_path = public as $$
  with f as (select m.* from stock_moves m where m.company_id = cid and m.product_id = p_product and is_member(cid)
               and (p_warehouse is null or m.warehouse_id = p_warehouse)),
  op as (select coalesce(sum(qty), 0) v from f where move_date < p_from),
  r as (select f.*, (select v from op) + sum(f.qty) over (order by f.move_date, f.created_at, f.id) bal from f where f.move_date between p_from and p_to)
  select r.id, r.move_date, w.code, r.reason, r.ref_type, r.ref_id, pj.number,
         case when r.qty > 0 then r.qty end, case when r.qty < 0 then -r.qty end, r.bal, r.unit_cost, round(r.qty * r.unit_cost, 2), (select v from op)
    from r left join warehouses w on w.id = r.warehouse_id left join projects pj on pj.id = r.project_id
   order by r.move_date, r.created_at, r.id;
$$;

-- What to order: items at or below their reorder level, less what is already on order.
create or replace function public.reorder_suggestions(cid uuid, p_warehouse uuid default null)
returns table (product_id uuid, sku text, name text, unit text, on_hand numeric, on_order numeric, reorder_level numeric, suggested numeric,
               supplier_id uuid, supplier text, unit_cost numeric)
language sql stable security definer set search_path = public as $$
  select * from (
    select p.id, p.sku, p.name, p.unit,
      case when p_warehouse is null then p.stock_qty else coalesce((select qty from stock_levels where product_id = p.id and warehouse_id = p_warehouse), 0) end oh,
      coalesce((select sum(l.qty - l.received_qty) from po_lines l join purchase_orders o on o.id = l.po_id
                 where l.product_id = p.id and o.status in ('draft','approved','sent','partial') and l.project_id is null
                   and (p_warehouse is null or o.warehouse_id = p_warehouse)), 0) oo,
      p.reorder_level,
      greatest(coalesce(nullif(p.reorder_qty, 0), coalesce(p.max_level, p.reorder_level * 2) - p.stock_qty), 1) sug,
      coalesce(p.preferred_supplier_id, (select si.supplier_id from supplier_items si where si.product_id = p.id order by si.price limit 1)) sup,
      null::text, coalesce((select si.price from supplier_items si where si.product_id = p.id and si.supplier_id = p.preferred_supplier_id),
                           (select min(si.price) from supplier_items si where si.product_id = p.id), p.last_purchase_cost, p.cost)
      from products p where p.company_id = cid and p.item_type = 'stock' and p.active and p.reorder_level > 0 and is_member(cid)
  ) x
  where x.oh + x.oo <= x.reorder_level;
$$;

create or replace function public.supplier_summary(p_supplier uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  with s as (select * from suppliers where id = p_supplier and is_member(company_id))
  select jsonb_build_object(
    'balance', coalesce((select sum(round((total - amount_paid) * exchange_rate, 2)) from bills where supplier_id = p_supplier and status = 'posted'), 0),
    'overdue', coalesce((select sum(round((total - amount_paid) * exchange_rate, 2)) from bills where supplier_id = p_supplier and status = 'posted' and due_date < current_date), 0),
    'spend_12m', coalesce((select sum(round(subtotal * exchange_rate, 2)) from bills where supplier_id = p_supplier and status <> 'draft' and bill_date > current_date - 365), 0),
    'open_orders', (select count(*) from purchase_orders where supplier_id = p_supplier and status in ('approved','sent','partial')),
    'open_order_value', coalesce((select sum((l.qty - l.received_qty) * l.unit_cost) from po_lines l join purchase_orders o on o.id = l.po_id
                                   where o.supplier_id = p_supplier and o.status in ('approved','sent','partial')), 0),
    'deliveries', (select count(*) from goods_receipts where supplier_id = p_supplier),
    'on_time_pct', (select round(100.0 * count(*) filter (where g.receipt_date <= coalesce(o.expected_date, g.receipt_date)) / nullif(count(*), 0))
                      from goods_receipts g join purchase_orders o on o.id = g.po_id where g.supplier_id = p_supplier),
    'avg_lead_days', (select round(avg(g.receipt_date - o.order_date)) from goods_receipts g join purchase_orders o on o.id = g.po_id where g.supplier_id = p_supplier),
    'last_order', (select max(order_date) from purchase_orders where supplier_id = p_supplier and status <> 'cancelled'))
  from s;
$$;


-- Books check and the to-do list cover the new documents.
alter function public.ledger_checks(uuid) rename to ledger_checks_v20;
create or replace function public.ledger_checks(cid uuid)
returns table (check_name text, ledger numeric, documents numeric, direct numeric, difference numeric, ok boolean, explanation text)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare bal numeric; doc numeric;
begin
  return query select * from ledger_checks_v20(cid);
  if not has_role(cid, array['owner','admin','accountant']) then return; end if;
  select coalesce(sum(l.credit - l.debit),0) into bal from journal_lines l where l.account_id = acct(cid,'grni');
  select coalesce(round(sum(greatest(pl.received_qty - pl.billed_qty, 0) * pl.unit_cost), 2),0) into doc
    from po_lines pl where pl.company_id = cid and pl.received_qty > pl.billed_qty;
  return query select 'Goods received not invoiced vs deliveries waiting for a supplier bill', bal, doc, 0::numeric, bal - doc, abs(bal - doc) < 1,
    'Goods received on purchase orders that the supplier has not billed yet. Use Bill from order when the supplier invoice arrives.';
  select coalesce(round(sum(sl.qty * p.cost), 2),0) into bal from stock_levels sl join products p on p.id = sl.product_id where p.company_id = cid and p.item_type = 'stock';
  select coalesce(round(sum(stock_qty * cost), 2),0) into doc from products where company_id = cid and item_type = 'stock';
  return query select 'Stock by warehouse vs total stock', bal, doc, 0::numeric, bal - doc, abs(bal - doc) < 1,
    'The sum of every warehouse''s stock against each item''s total quantity.';
end $$;
revoke execute on function public.ledger_checks_v20(uuid) from public, anon, authenticated;

alter function public.unposted_documents(uuid) rename to unposted_documents_v20;
create or replace function public.unposted_documents(cid uuid)
returns table (kind text, n bigint, amount numeric, oldest date, path text)
language sql stable security definer set search_path = public as $$
  select * from unposted_documents_v20(cid)
  union all select * from (
    select 'Purchase orders not yet approved', count(*), coalesce(sum(po_total(id)),0), min(order_date), '/purchase-orders' from purchase_orders where company_id = cid and status = 'draft'
    union all select 'Orders waiting for delivery', count(*), coalesce(sum(po_total(id)),0), min(coalesce(expected_date, order_date)), '/purchase-orders' from purchase_orders where company_id = cid and status in ('approved','sent','partial')
    union all select 'Received, waiting for the supplier''s bill', count(distinct po_id), coalesce(sum((received_qty - billed_qty) * unit_cost),0), null::date, '/purchase-orders' from po_lines where company_id = cid and received_qty > billed_qty
    union all select 'Draft stock issues and returns', count(*), 0::numeric, min(issue_date), '/inventory/issues' from stock_issues where company_id = cid and status = 'draft'
    union all select 'Draft transfers', count(*), 0::numeric, min(transfer_date), '/inventory/transfers' from stock_transfers where company_id = cid and status = 'draft'
    union all select 'Stocktakes not posted', count(*), 0::numeric, min(count_date), '/inventory/counts' from stock_counts where company_id = cid and status = 'draft'
  ) x where has_role(cid, array['owner','admin','accountant']);
$$;
revoke execute on function public.unposted_documents_v20(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------- 10. Project costs include stock issues, goods received for projects and open orders
create or replace function public.project_cost_items(cid uuid)
returns table (item_date date, project_id uuid, category text, source text, reference text, description text,
               account_code text, account_name text, amount numeric, in_ledger boolean, committed boolean, doc_id uuid)
language sql stable security definer set search_path = public as $$
  select t.work_date, t.project_id, 'labour', 'Timesheet', e.full_name, coalesce(t.note, tk.title, ''),
         null::text, null::text, round(t.hours * coalesce(e.cost_rate,0), 2), false, false, t.id
    from timesheets t join projects p on p.id = t.project_id left join employees e on e.id = t.employee_id left join tasks tk on tk.id = t.task_id
   where p.company_id = cid and t.status = 'approved'
  union all
  select x.expense_date, x.project_id, 'expenses', 'Expense claim', e.full_name, x.description, a.code, a.name, x.amount_home, true, false, x.id
    from expense_claims x join projects p on p.id = x.project_id left join employees e on e.id = x.employee_id left join accounts a on a.id = x.account_id
   where p.company_id = cid and x.status in ('approved','reimbursed')
  union all
  -- Supplier bills not matched to a goods receipt
  select b.bill_date, l.project_id,
         coalesce(l.project_category, case when l.product_id is not null then 'materials' else cost_category_for_account(l.account_id) end),
         'Supplier bill', b.number || coalesce(' · ' || s.name, ''), l.description,
         a.code, a.name, round(l.qty * l.unit_cost * b.exchange_rate, 2), true, false, b.id
    from bill_lines l join bills b on b.id = l.bill_id join projects p on p.id = l.project_id
    left join suppliers s on s.id = b.supplier_id
    left join accounts a on a.id = coalesce(l.account_id, (select id from accounts i where i.company_id = cid and i.system_key = 'project_materials'))
   where p.company_id = cid and b.status <> 'draft' and l.po_line_id is null
  union all
  -- Goods received for a project, stock issued to or returned from a project, and price differences on matched bills
  select je.entry_date, jl.project_id,
         case when je.source_type = 'stock_issue' or a.system_key in ('ppv','inventory') then 'materials' else cost_category_for_account(jl.account_id) end,
         case je.source_type when 'receipt' then 'Goods received' when 'stock_issue' then 'Stock from store' else 'Bill price difference' end,
         je.entry_no || ' · ' || coalesce((select number from goods_receipts where id = je.source_id), (select number from stock_issues where id = je.source_id),
                                          (select number from bills where id = je.source_id), ''),
         coalesce(je.memo, ''), a.code, a.name, jl.debit - jl.credit, true, false, je.id
    from journal_lines jl join journal_entries je on je.id = jl.entry_id join accounts a on a.id = jl.account_id
   where jl.company_id = cid and jl.project_id is not null and a.type in ('expense','asset')
     and (je.source_type in ('receipt','stock_issue') or (je.source_type = 'bill' and a.system_key = 'ppv'))
  union all
  select je.entry_date, jl.project_id, cost_category_for_account(jl.account_id), 'Journal', je.entry_no, coalesce(je.memo, ''),
         a.code, a.name, jl.debit - jl.credit, true, false, je.id
    from journal_lines jl join journal_entries je on je.id = jl.entry_id join accounts a on a.id = jl.account_id
   where jl.company_id = cid and jl.project_id is not null and je.source_type = 'manual' and a.type in ('expense','asset')
  union all
  select coalesce(r.needed_by, r.decided_at::date, r.created_at::date), r.project_id,
         case r.kind when 'material' then 'materials' else r.kind end, 'Purchase request', r.number, r.description,
         null, null, round(r.qty * r.est_unit_cost, 2), false, true, r.id
    from project_requests r left join bills b on b.id = r.bill_id
   where r.company_id = cid and (r.status = 'approved' or (r.status = 'billed' and (b.id is null or b.status = 'draft')))
  union all
  -- Ordered for a project and not yet received
  select coalesce(o.expected_date, o.order_date), l.project_id,
         case when l.product_id is not null then 'materials' else cost_category_for_account(l.account_id) end,
         'Purchase order', o.number, l.description, null, null, round((l.qty - l.received_qty) * l.unit_cost, 2), false, true, o.id
    from po_lines l join purchase_orders o on o.id = l.po_id
   where o.company_id = cid and l.project_id is not null and o.status in ('approved','sent','partial') and l.qty > l.received_qty
$$;
revoke execute on function public.project_cost_items(uuid) from public;

create or replace function public.cost_category_for_account(a uuid) returns text
language sql stable security definer set search_path = public as $$
  select case x.system_key when 'project_materials' then 'materials' when 'inventory' then 'materials' when 'ppv' then 'materials' when 'subcontract' then 'subcontract'
           when 'equipment_hire' then 'equipment' when 'reimburse' then 'expenses'
           else case when x.type = 'asset' then 'materials' else 'other' end end
    from accounts x where x.id = a;
$$;

create or replace function public.source_ref(p_type text, p_id uuid, out label text, out path text)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  label := initcap(replace(coalesce(p_type, 'manual'), '_', ' '));
  if p_id is null then return; end if;
  if p_type = 'invoice' then select 'Invoice ' || coalesce(number, ''), '/invoices/' || id into label, path from invoices where id = p_id;
  elsif p_type = 'payment' then select 'Receipt · ' || coalesce(i.number, ''), '/invoices/' || i.id into label, path from payments p join invoices i on i.id = p.invoice_id where p.id = p_id;
  elsif p_type = 'credit_note' then select 'Credit note ' || coalesce(number, ''), '/credit-notes/' || id into label, path from credit_notes where id = p_id;
  elsif p_type = 'bill' then select 'Bill ' || coalesce(number, ''), '/bills/' || id into label, path from bills where id = p_id;
  elsif p_type = 'bill_payment' then select 'Payment · ' || coalesce(b.number, ''), '/bills/' || b.id into label, path from bill_payments p join bills b on b.id = p.bill_id where p.id = p_id;
  elsif p_type in ('payroll','payroll_payment') then select 'Payroll ' || to_char(period, 'Mon YYYY'), '/payroll/' || id into label, path from payroll_runs where id = p_id;
  elsif p_type in ('asset','asset_disposal') then select 'Asset · ' || coalesce(tag, name), '/assets/' || id into label, path from assets where id = p_id;
  elsif p_type = 'cash' then select 'Bank & cash ' || coalesce(number, ''), '/bank-cash?id=' || id into label, path from cash_transactions where id = p_id;
  elsif p_type = 'expense' then select 'Expense claim · ' || coalesce(e.full_name, ''), null into label, path from expense_claims x left join employees e on e.id = x.employee_id where x.id = p_id;
  elsif p_type = 'stock' then select 'Stock · ' || name, '/inventory/items/' || id into label, path from products where id = p_id;
  elsif p_type = 'receipt' then select 'Goods received ' || g.number, '/purchase-orders/' || g.po_id into label, path from goods_receipts g where g.id = p_id;
  elsif p_type = 'stock_issue' then select 'Stock issue ' || number, '/inventory/issues/' || id into label, path from stock_issues where id = p_id;
  elsif p_type = 'stock_count' then select 'Stocktake ' || number, '/inventory/counts/' || id into label, path from stock_counts where id = p_id;
  end if;
end $$;

create or replace function public.doc_dims(p_type text, p_id uuid, out branch_id uuid, out cost_centre_id uuid)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  if p_id is null then return; end if;
  if p_type = 'invoice' then select i.branch_id, i.cost_centre_id into branch_id, cost_centre_id from invoices i where i.id = p_id;
  elsif p_type = 'payment' then select i.branch_id, i.cost_centre_id into branch_id, cost_centre_id from payments p join invoices i on i.id = p.invoice_id where p.id = p_id;
  elsif p_type = 'credit_note' then select coalesce(c.branch_id, i.branch_id), coalesce(c.cost_centre_id, i.cost_centre_id) into branch_id, cost_centre_id
          from credit_notes c left join invoices i on i.id = c.invoice_id where c.id = p_id;
  elsif p_type = 'bill' then select b.branch_id, b.cost_centre_id into branch_id, cost_centre_id from bills b where b.id = p_id;
  elsif p_type = 'bill_payment' then select b.branch_id, b.cost_centre_id into branch_id, cost_centre_id from bill_payments p join bills b on b.id = p.bill_id where p.id = p_id;
  elsif p_type = 'expense' then select coalesce(x.branch_id, pr.branch_id, e.branch_id), coalesce(x.cost_centre_id, pr.cost_centre_id, e.cost_centre_id) into branch_id, cost_centre_id
          from expense_claims x left join projects pr on pr.id = x.project_id left join employees e on e.id = x.employee_id where x.id = p_id;
  elsif p_type in ('asset','asset_disposal') then select a.branch_id, a.cost_centre_id into branch_id, cost_centre_id from assets a where a.id = p_id;
  elsif p_type = 'cash' then select c.branch_id, c.cost_centre_id into branch_id, cost_centre_id from cash_transactions c where c.id = p_id;
  elsif p_type = 'receipt' then select o.branch_id, w.branch_id into branch_id, cost_centre_id from goods_receipts g join purchase_orders o on o.id = g.po_id
          left join warehouses w on w.id = g.warehouse_id where g.id = p_id; cost_centre_id := null; branch_id := coalesce(branch_id, (select w2.branch_id from goods_receipts g2 join warehouses w2 on w2.id = g2.warehouse_id where g2.id = p_id));
  elsif p_type = 'stock_issue' then select w.branch_id, s.cost_centre_id into branch_id, cost_centre_id from stock_issues s left join warehouses w on w.id = s.warehouse_id where s.id = p_id;
  elsif p_type = 'stock_count' then select w.branch_id into branch_id from stock_counts c join warehouses w on w.id = c.warehouse_id where c.id = p_id;
  end if;
end $$;

-- Billing a time-and-materials project now also bills materials from the store and re-billable supplier costs.
create or replace function public.invoice_project(p_project uuid, p_to date default current_date)
returns uuid language plpgsql security definer set search_path = public as $$
declare pr projects; v_rate numeric; v_inv uuid; r record; i int := 0;
begin
  select * into pr from projects where id = p_project;
  if not found then raise exception 'Project not found'; end if;
  if not (can_manage_project(pr.id) or has_role(pr.company_id, array['sales'])) then raise exception 'Only this project''s manager, sales or accounts can bill it'; end if;
  if pr.customer_id is null then raise exception 'Set a client on this project before invoicing'; end if;
  v_rate := case when pr.currency = 'GHS' then 1 else (select rate from currencies where company_id = pr.company_id and code = pr.currency) end;
  if v_rate is null then raise exception 'Add % under Settings → Foreign currencies first', pr.currency; end if;
  if not exists (select 1 from timesheets where project_id = p_project and status = 'approved' and billable and invoice_id is null and work_date <= p_to)
     and not exists (select 1 from expense_claims where project_id = p_project and status in ('approved','reimbursed') and billable and invoice_id is null and expense_date <= p_to)
     and not exists (select 1 from stock_issue_lines l join stock_issues s on s.id = l.issue_id where s.project_id = p_project and s.status = 'posted' and l.billable and l.invoice_id is null and s.issue_date <= p_to)
     and not exists (select 1 from bill_lines l join bills b on b.id = l.bill_id where l.project_id = p_project and b.status <> 'draft' and l.billable and l.invoice_id is null and b.bill_date <= p_to) then
    raise exception 'There is no approved, unbilled time, billable expense or billable material up to %', p_to;
  end if;

  insert into invoices (company_id, customer_id, project_id, invoice_date, currency, exchange_rate, notes, branch_id, cost_centre_id)
  values (pr.company_id, pr.customer_id, p_project, current_date, pr.currency, v_rate, 'Project ' || coalesce(pr.number,'') || ': ' || pr.name || ', work to ' || to_char(p_to, 'DD Mon YYYY'),
          pr.branch_id, pr.cost_centre_id)
  returning id into v_inv;

  for r in select e.full_name, coalesce(t.bill_rate, pr.hourly_rate) as rate, sum(t.hours) as hrs, min(t.work_date) as d1, max(t.work_date) as d2
             from timesheets t join employees e on e.id = t.employee_id
            where t.project_id = p_project and t.status = 'approved' and t.billable and t.invoice_id is null and t.work_date <= p_to
            group by e.full_name, coalesce(t.bill_rate, pr.hourly_rate) order by e.full_name loop
    insert into invoice_lines (invoice_id, company_id, description, qty, unit_price, taxable, sort)
    values (v_inv, pr.company_id, 'Professional time: ' || r.full_name || ' (' || to_char(r.d1,'DD Mon') || '–' || to_char(r.d2,'DD Mon YYYY') || ')', r.hrs, coalesce(r.rate,0), true, i);
    i := i + 1;
  end loop;
  for r in select x.* from expense_claims x where x.project_id = p_project and x.status in ('approved','reimbursed') and x.billable and x.invoice_id is null and x.expense_date <= p_to order by x.expense_date loop
    insert into invoice_lines (invoice_id, company_id, description, qty, unit_price, taxable, sort)
    values (v_inv, pr.company_id, 'Expense: ' || r.description || ' (' || r.currency || ' ' || to_char(r.amount, 'FM999,999,990.00') || ', ' || to_char(r.expense_date,'DD Mon YYYY') || ')',
            1, round(r.amount_home / v_rate, 2), true, i);
    i := i + 1;
  end loop;
  -- Materials from the store: issues less returns, per item and price
  for r in select p.name, p.unit, l.bill_price, sum(case when s.kind = 'issue' then l.qty else -l.qty end) q, p.taxable
             from stock_issue_lines l join stock_issues s on s.id = l.issue_id join products p on p.id = l.product_id
            where s.project_id = p_project and s.status = 'posted' and l.billable and l.invoice_id is null and s.issue_date <= p_to
            group by p.name, p.unit, l.bill_price, p.taxable having sum(case when s.kind = 'issue' then l.qty else -l.qty end) > 0 order by p.name loop
    insert into invoice_lines (invoice_id, company_id, description, qty, unit_price, taxable, sort)
    values (v_inv, pr.company_id, 'Materials supplied: ' || r.name || ' (' || r.unit || ')', r.q, round(coalesce(r.bill_price, 0) / v_rate, 2), r.taxable, i);
    i := i + 1;
  end loop;
  -- Supplier costs marked "bill to client"
  for r in select l.description, l.qty, round(l.unit_cost * b.exchange_rate / v_rate, 2) price from bill_lines l join bills b on b.id = l.bill_id
            where l.project_id = p_project and b.status <> 'draft' and l.billable and l.invoice_id is null and b.bill_date <= p_to order by b.bill_date loop
    insert into invoice_lines (invoice_id, company_id, description, qty, unit_price, taxable, sort)
    values (v_inv, pr.company_id, 'Supplied: ' || r.description, r.qty, r.price, true, i);
    i := i + 1;
  end loop;
  update timesheets set invoice_id = v_inv where project_id = p_project and status = 'approved' and billable and invoice_id is null and work_date <= p_to;
  update expense_claims set invoice_id = v_inv where project_id = p_project and status in ('approved','reimbursed') and billable and invoice_id is null and expense_date <= p_to;
  perform set_config('sika.posting','on', true);
  update stock_issue_lines l set invoice_id = v_inv from stock_issues s
   where s.id = l.issue_id and s.project_id = p_project and s.status = 'posted' and l.billable and l.invoice_id is null and s.issue_date <= p_to;
  perform set_config('sika.posting','off', true);
  update bill_lines l set invoice_id = v_inv from bills b where b.id = l.bill_id and l.project_id = p_project and b.status <> 'draft' and l.billable and l.invoice_id is null and b.bill_date <= p_to;
  return v_inv;
end $$;

-- ---------------------------------------------------------------- 11. Project lifecycle
alter table public.projects drop constraint if exists projects_status_check;
alter table public.projects add constraint projects_status_check check (status in ('planned','active','on_hold','done','closed','cancelled'));
alter table public.projects add column if not exists actual_start date;
alter table public.projects add column if not exists actual_end date;
alter table public.projects add column if not exists closed_at timestamptz;
alter table public.projects add column if not exists closed_by uuid;
alter table public.projects add column if not exists close_notes text;
update public.projects set actual_start = coalesce(actual_start, start_date) where status in ('active','on_hold','done');

create table public.project_status_log (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  project_id uuid not null references public.projects(id) on delete cascade,
  from_status text, to_status text not null,
  note text,
  changed_by uuid default auth.uid(),
  changed_email text,
  changed_at timestamptz not null default now()
);
create index on public.project_status_log (project_id, changed_at);

-- The status of a project changes only through the lifecycle actions below.
create or replace function public.project_status_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    if new.status not in ('planned','active') and not new.is_template then new.status := 'planned'; end if;
    if new.status = 'active' then new.actual_start := coalesce(new.actual_start, new.start_date, current_date); end if;
  elsif new.status is distinct from old.status and coalesce(current_setting('sika.lifecycle', true), '') <> 'on' then
    raise exception 'Use Start, Hold, Resume, Complete, Close or Reopen to change a project''s status';
  end if;
  return new;
end $$;
create trigger projects_status_guard before insert or update on public.projects for each row execute function public.project_status_guard();

-- Close-out checklist. severity: block = must be cleared before closing; warn = check, but you may close.
create or replace function public.project_close_check(p_project uuid)
returns table (item text, n bigint, amount numeric, severity text, hint text)
language sql stable security definer set search_path = public as $$
  with p as (select * from projects where id = p_project and is_member(company_id))
  select * from (
    select 'Tasks not finished' item, (select count(*) from tasks where project_id = p_project and status <> 'done') n, null::numeric amount, 'warn' severity, 'Plan tab: mark them done or remove them' hint
    union all select 'Time sheets waiting for approval', (select count(*) from timesheets where project_id = p_project and status = 'submitted'),
      (select sum(hours) from timesheets where project_id = p_project and status = 'submitted'), 'block', 'Approvals: approve or reject them'
    union all select 'Expense claims waiting for approval', (select count(*) from expense_claims where project_id = p_project and status = 'submitted'),
      (select sum(amount_home) from expense_claims where project_id = p_project and status = 'submitted'), 'block', 'Approvals: approve or reject them'
    union all select 'Billable time not invoiced', (select count(*) from timesheets t, p where t.project_id = p_project and t.status = 'approved' and t.billable and t.invoice_id is null and p.billing_type = 'time_materials'),
      null, 'block', 'Billing tab: Invoice approved time and expenses'
    union all select 'Billable expenses not invoiced', (select count(*) from expense_claims x where x.project_id = p_project and x.status in ('approved','reimbursed') and x.billable and x.invoice_id is null),
      (select sum(amount_home) from expense_claims x where x.project_id = p_project and x.status in ('approved','reimbursed') and x.billable and x.invoice_id is null), 'block', 'Billing tab: invoice them'
    union all select 'Billable materials not invoiced', (select count(*) from stock_issue_lines l join stock_issues s on s.id = l.issue_id where s.project_id = p_project and s.status = 'posted' and l.billable and l.invoice_id is null),
      null, 'block', 'Billing tab: invoice them'
    union all select 'Milestones not invoiced', (select count(*) from project_milestones where project_id = p_project and status <> 'invoiced'),
      (select sum(amount) from project_milestones where project_id = p_project and status <> 'invoiced'), 'block', 'Billing tab: invoice or delete them'
    union all select 'Purchase requests still open', (select count(*) from project_requests where project_id = p_project and status in ('draft','submitted','approved')),
      (select sum(qty * est_unit_cost) from project_requests where project_id = p_project and status in ('draft','submitted','approved')), 'block', 'Purchases tab: order, bill or cancel them'
    union all select 'Purchase orders not fully received', (select count(distinct o.id) from po_lines l join purchase_orders o on o.id = l.po_id where l.project_id = p_project and o.status in ('draft','approved','sent','partial') and l.received_qty < l.qty),
      null, 'block', 'Purchase orders: receive or close them'
    union all select 'Goods received but not billed by the supplier', (select count(*) from po_lines where project_id = p_project and received_qty > billed_qty),
      (select sum((received_qty - billed_qty) * unit_cost) from po_lines where project_id = p_project and received_qty > billed_qty), 'warn', 'Accounts: bill from the purchase order when the supplier invoice arrives'
    union all select 'Draft supplier bills for this project', (select count(distinct b.id) from bill_lines l join bills b on b.id = l.bill_id where l.project_id = p_project and b.status = 'draft'),
      null, 'block', 'Supplier bills: post or delete them'
    union all select 'Draft stock issues or returns', (select count(*) from stock_issues where project_id = p_project and status = 'draft'), null, 'block', 'Inventory → Issue to project: post or delete them'
    union all select 'Open issues and risks', (select count(*) from project_issues where project_id = p_project and status in ('open','in_progress')), null, 'warn', 'Issues tab: resolve or close them'
    union all select 'Client invoices not fully paid', (select count(*) from invoices where project_id = p_project and status = 'posted'),
      (select sum((total - amount_paid - amount_credited) * exchange_rate) from invoices where project_id = p_project and status = 'posted'), 'warn', 'Collect payment; closing does not stop you receiving it'
  ) x where n > 0;
$$;

create or replace function public.set_project_status(p_project uuid, p_action text, p_note text default null, p_date date default current_date, p_force boolean default false)
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
    when 'hold' then case when pr.status = 'active' then 'on_hold' end
    when 'resume' then case when pr.status = 'on_hold' then 'active' end
    when 'complete' then case when pr.status in ('active','on_hold') then 'done' end
    when 'resume_work' then case when pr.status = 'done' then 'active' end
    when 'close' then case when pr.status = 'done' then 'closed' end
    when 'reopen' then case when pr.status in ('closed','cancelled') then case when pr.status = 'closed' then 'done' else 'planned' end end
    when 'cancel' then case when pr.status in ('planned','active','on_hold') then 'cancelled' end
  end;
  if v_to is null then raise exception 'You cannot % a project that is %', replace(p_action, '_', ' '), replace(pr.status, '_', ' '); end if;
  if p_action in ('hold','cancel','reopen') and coalesce(trim(p_note),'') = '' then raise exception 'Give a reason'; end if;
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
    actual_start = case when v_to = 'active' then coalesce(actual_start, p_date) else actual_start end,
    actual_end = case when v_to = 'done' then p_date when p_action = 'resume_work' then null else actual_end end,
    closed_at = case when v_to = 'closed' then now() when p_action = 'reopen' then null else closed_at end,
    closed_by = case when v_to = 'closed' then auth.uid() when p_action = 'reopen' then null else closed_by end,
    close_notes = case when v_to = 'closed' then p_note else close_notes end,
    percent_complete_override = case when v_to = 'done' then 100 when p_action = 'resume_work' then null else percent_complete_override end
  where id = p_project;
  perform set_config('sika.lifecycle','off', true);
  select email into v_email from auth.users where id = auth.uid();
  insert into project_status_log (company_id, project_id, from_status, to_status, note, changed_email)
  values (pr.company_id, p_project, pr.status, v_to, case when p_force and p_action = 'close' then 'Closed with open items: ' || p_note else p_note end, v_email);
  return v_to;
end $$;

-- Nothing new can be booked to a closed or cancelled project.
create or replace function public.closed_project_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare st text; pid uuid;
begin
  pid := new.project_id;
  if pid is null then return new; end if;
  select status into st from projects where id = pid;
  if st in ('closed','cancelled') then raise exception 'This project is %. Reopen it to book anything to it.', st; end if;
  return new;
end $$;
do $$ declare t text; begin
  foreach t in array array['timesheets','expense_claims','project_requests','tasks','stock_issues','po_lines','bill_lines','project_milestones'] loop
    execute format('create trigger %I before insert on public.%I for each row execute function public.closed_project_guard()', t || '_closed_project', t);
  end loop;
end $$;

-- ---------------------------------------------------------------- 12. New companies
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
  perform seed_leave_types(v);
  perform seed_asset_categories(v);
  perform wh(v);
  return v;
end $$;

-- ---------------------------------------------------------------- 13. Row-level security
alter table public.warehouses enable row level security;
create policy "members read warehouses" on public.warehouses for select using (is_member(company_id));
create policy "managers write warehouses" on public.warehouses for all using (has_role(company_id, array['owner','admin','accountant','store'])) with check (has_role(company_id, array['owner','admin','accountant','store']));
alter table public.stock_levels enable row level security;
create policy "members read levels" on public.stock_levels for select using (is_member(company_id));
create policy "store sets bins" on public.stock_levels for update using (has_role(company_id, array['owner','admin','accountant','store']));

alter table public.supplier_items enable row level security;
create policy "members read price lists" on public.supplier_items for select using (is_member(company_id));
create policy "buyers write price lists" on public.supplier_items for all using (has_role(company_id, array['owner','admin','accountant','store'])) with check (has_role(company_id, array['owner','admin','accountant','store']));

alter table public.purchase_orders enable row level security;
alter table public.po_lines enable row level security;
create policy "members read orders" on public.purchase_orders for select using (is_member(company_id));
create policy "buyers create orders" on public.purchase_orders for insert with check (has_role(company_id, array['owner','admin','accountant','store','project_manager']));
create policy "buyers edit draft orders" on public.purchase_orders for update using (has_role(company_id, array['owner','admin','accountant','store','project_manager']));
create policy "buyers delete draft orders" on public.purchase_orders for delete using (status = 'draft' and has_role(company_id, array['owner','admin','accountant','store','project_manager']));
create policy "members read order lines" on public.po_lines for select using (is_member(company_id));
create policy "buyers write order lines" on public.po_lines for all using (has_role(company_id, array['owner','admin','accountant','store','project_manager'])) with check (has_role(company_id, array['owner','admin','accountant','store','project_manager']));

alter table public.goods_receipts enable row level security;
alter table public.goods_receipt_lines enable row level security;
create policy "members read receipts" on public.goods_receipts for select using (is_member(company_id));
create policy "members read receipt lines" on public.goods_receipt_lines for select using (is_member(company_id));

alter table public.stock_issues enable row level security;
alter table public.stock_issue_lines enable row level security;
create policy "members read issues" on public.stock_issues for select using (is_member(company_id));
create policy "store and managers write issues" on public.stock_issues for all
  using (has_role(company_id, array['owner','admin','accountant','store']) or (project_id is not null and can_manage_project(project_id)))
  with check (has_role(company_id, array['owner','admin','accountant','store']) or (project_id is not null and can_manage_project(project_id)));
create policy "members read issue lines" on public.stock_issue_lines for select using (is_member(company_id));
create policy "store and managers write issue lines" on public.stock_issue_lines for all
  using (exists (select 1 from stock_issues s where s.id = issue_id and (has_role(s.company_id, array['owner','admin','accountant','store']) or (s.project_id is not null and can_manage_project(s.project_id)))))
  with check (exists (select 1 from stock_issues s where s.id = issue_id and (has_role(s.company_id, array['owner','admin','accountant','store']) or (s.project_id is not null and can_manage_project(s.project_id)))));

do $$ declare t text; begin
  foreach t in array array['stock_transfers','stock_transfer_lines','stock_counts','stock_count_lines'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy "members read" on public.%I for select using (is_member(company_id))', t);
    execute format('create policy "store writes" on public.%I for all using (has_role(company_id, array[''owner'',''admin'',''accountant'',''store''])) with check (has_role(company_id, array[''owner'',''admin'',''accountant'',''store'']))', t);
  end loop;
end $$;

alter table public.project_status_log enable row level security;
create policy "members read status log" on public.project_status_log for select using (is_member(company_id));

-- The store role can work with products and suppliers.
create policy "store edits products" on public.products for update using (has_role(company_id, array['store']));
create policy "store adds products" on public.products for insert with check (has_role(company_id, array['store']));

-- Audit the new documents
do $$ declare t text; begin
  foreach t in array array['warehouses','purchase_orders','stock_issues','stock_transfers','stock_counts','supplier_items'] loop
    execute format('create trigger %I after insert or update or delete on public.%I for each row execute function public.audit_row()', t || '_audit', t);
  end loop;
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
grant execute on function public.public_help(uuid) to anon;
grant execute on function public.submit_case_public(uuid,text,text,text,text,text) to anon;
grant execute on function public.case_status_public(text,text) to anon;
grant execute on function public.reply_case_public(text,text,text,int) to anon;
revoke execute on function public.ledger_checks_v20(uuid) from authenticated;
revoke execute on function public.unposted_documents_v20(uuid) from authenticated;
