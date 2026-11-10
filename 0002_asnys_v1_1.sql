-- Sika ERP v1.1
-- Run once in the Supabase SQL editor AFTER 0001_sika_erp.sql.
-- Adds: credit notes and reversals, quotes and sales orders, recurring invoices, multi-currency,
-- payroll overtime/bonus tax, staff loans, Tier 3, leave balances, recruitment, appraisals,
-- bank reconciliation, budgets and period locking.

-- =====================================================================
-- 1. New system accounts (existing and future companies)
-- =====================================================================
create or replace function public.seed_accounts_v11(cid uuid)
returns void language sql security definer set search_path = public as $$
  insert into accounts (company_id, code, name, type, system_key) values
  (cid,'1250','Staff loans and advances','asset','staff_loans'),
  (cid,'2230','Tier 3 pension payable','liability','tier3'),
  (cid,'2500','Customer deposits and credits','liability',null),
  (cid,'4800','Foreign exchange gains and losses','income','fx'),
  (cid,'6020','Employer Tier 3 contribution','expense','employer_tier3')
  on conflict do nothing;
$$;
select public.seed_accounts_v11(id) from public.companies;

-- =====================================================================
-- 2. Period locking
-- =====================================================================
alter table public.companies add column if not exists locked_until date;

create or replace function public.post_journal(cid uuid, p_date date, p_memo text, p_lines jsonb,
  p_source_type text default null, p_source_id uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_id uuid; v_dr numeric; v_cr numeric; v_lock date;
begin
  select locked_until into v_lock from companies where id = cid;
  if v_lock is not null and p_date <= v_lock then
    raise exception 'The books are locked up to %. Date this on or after %, or ask an accountant to change the lock date.', v_lock, v_lock + 1;
  end if;
  select coalesce(sum(round((l->>'debit')::numeric,2)),0), coalesce(sum(round((l->>'credit')::numeric,2)),0)
    into v_dr, v_cr from jsonb_array_elements(p_lines) l;
  if v_dr <> v_cr then raise exception 'Journal does not balance: debits % vs credits %', v_dr, v_cr; end if;
  if v_dr = 0 then raise exception 'Journal has no amounts'; end if;
  insert into journal_entries (company_id, entry_no, entry_date, memo, source_type, source_id)
  values (cid, next_number(cid, 'JE', 'JE-'), p_date, p_memo, p_source_type, p_source_id)
  returning id into v_id;
  insert into journal_lines (entry_id, company_id, account_id, debit, credit)
  select v_id, cid, (l->>'account_id')::uuid, round(coalesce((l->>'debit')::numeric,0),2), round(coalesce((l->>'credit')::numeric,0),2)
    from jsonb_array_elements(p_lines) l
   where round(coalesce((l->>'debit')::numeric,0),2) <> 0 or round(coalesce((l->>'credit')::numeric,0),2) <> 0;
  insert into audit_log (company_id, action, detail) values (cid, 'journal.posted', jsonb_build_object('entry_id', v_id, 'memo', p_memo));
  return v_id;
end $$;

create or replace function public.set_lock_date(cid uuid, p_date date)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform require_member(cid, array['owner','admin','accountant']);
  update companies set locked_until = p_date where id = cid;
  insert into audit_log (company_id, action, detail) values (cid, 'books.locked', jsonb_build_object('until', p_date));
end $$;

-- =====================================================================
-- 3. Currencies and multi-currency documents
-- =====================================================================
create table public.currencies (
  company_id uuid not null references public.companies(id) on delete cascade,
  code text not null check (code ~ '^[A-Z]{3}$' and code <> 'GHS'),
  name text not null,
  rate numeric(14,6) not null check (rate > 0),   -- GHS per 1 unit
  updated_at timestamptz not null default now(),
  primary key (company_id, code)
);

alter table public.invoices add column if not exists currency text not null default 'GHS';
alter table public.invoices add column if not exists exchange_rate numeric(14,6) not null default 1 check (exchange_rate > 0);
alter table public.invoices add column if not exists amount_credited numeric(14,2) not null default 0;
alter table public.bills add column if not exists currency text not null default 'GHS';
alter table public.bills add column if not exists exchange_rate numeric(14,6) not null default 1 check (exchange_rate > 0);
alter table public.payments add column if not exists exchange_rate numeric(14,6) not null default 1;
alter table public.bill_payments add column if not exists exchange_rate numeric(14,6) not null default 1;

-- Sales invoice: amounts in the document currency, ledger in GHS at the invoice rate.
create or replace function public.post_invoice(p_invoice uuid)
returns text language plpgsql security definer set search_path = public as $$
declare
  inv invoices; l record; p products; x numeric;
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
  x := inv.exchange_rate;

  perform set_config('sika.posting','on', true);
  for l in select * from invoice_lines where invoice_id = p_invoice order by sort loop
    v_sub := v_sub + round(l.qty * l.unit_price, 2);
    if l.taxable then v_taxable := v_taxable + round(l.qty * l.unit_price, 2); end if;
    if l.product_id is not null then
      select * into p from products where id = l.product_id for update;
      if p.stock_qty < l.qty then raise exception 'Only % % of % in stock', p.stock_qty, p.unit, p.name; end if;
      update products set stock_qty = stock_qty - l.qty where id = p.id;
      insert into stock_moves (company_id, product_id, move_date, qty, unit_cost, reason, ref_type, ref_id)
      values (inv.company_id, p.id, inv.invoice_date, -l.qty, p.cost, 'Sale', 'invoice', inv.id);
      v_cogs := v_cogs + round(l.qty * p.cost, 2);
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

drop function if exists public.record_payment(uuid, numeric, date, text, text);
create or replace function public.record_payment(p_invoice uuid, p_amount numeric, p_date date,
  p_method text, p_reference text default null, p_rate numeric default null)
returns void language plpgsql security definer set search_path = public as $$
declare inv invoices; v_je uuid; v_pay uuid; v_rate numeric; g_bank numeric; g_ar numeric; v_out numeric;
begin
  select * into inv from invoices where id = p_invoice for update;
  if not found then raise exception 'Invoice not found'; end if;
  perform require_member(inv.company_id, array['owner','admin','accountant','sales']);
  if inv.status = 'draft' then raise exception 'Post the invoice before recording a payment'; end if;
  if p_amount <= 0 then raise exception 'Amount must be more than zero'; end if;
  v_out := inv.total - inv.amount_paid - inv.amount_credited;
  if round(p_amount,2) > v_out then raise exception 'Payment of % is more than the % still owed', p_amount, v_out; end if;
  v_rate := coalesce(nullif(p_rate,0), inv.exchange_rate);
  if inv.currency = 'GHS' then v_rate := 1; end if;
  g_bank := round(p_amount * v_rate, 2); g_ar := round(p_amount * inv.exchange_rate, 2);
  insert into payments (company_id, invoice_id, payment_date, amount, method, reference, exchange_rate)
  values (inv.company_id, inv.id, p_date, round(p_amount,2), p_method, p_reference, v_rate) returning id into v_pay;
  v_je := post_journal(inv.company_id, p_date, 'Payment received for ' || inv.number,
    jsonb_build_array(
      jl(acct(inv.company_id, p_method), g_bank, 0),
      jl(acct(inv.company_id,'ar'), 0, g_ar),
      jl(acct(inv.company_id,'fx'), greatest(g_ar - g_bank, 0), greatest(g_bank - g_ar, 0))),
    'payment', v_pay);
  update payments set journal_entry_id = v_je where id = v_pay;
  update invoices set amount_paid = amount_paid + round(p_amount,2),
    status = case when amount_paid + amount_credited + round(p_amount,2) >= total then 'paid' else 'posted' end
   where id = inv.id;
end $$;

create or replace function public.post_bill(p_bill uuid)
returns text language plpgsql security definer set search_path = public as $$
declare
  b bills; l record; v_lines jsonb := '[]'::jsonb; x numeric;
  v_taxable numeric := 0; v_sub numeric := 0; v_amt numeric; g_amt numeric; g_sum numeric := 0;
  v_vat numeric; v_nhil numeric; v_getf numeric; v_total numeric; v_je uuid; v_no text;
  g_vat numeric; g_nhil numeric; g_getf numeric;
begin
  select * into b from bills where id = p_bill for update;
  if not found then raise exception 'Bill not found'; end if;
  perform require_member(b.company_id, array['owner','admin','accountant']);
  if b.status <> 'draft' then raise exception 'This bill is already posted'; end if;
  if not exists (select 1 from bill_lines where bill_id = p_bill) then raise exception 'Add at least one line'; end if;
  if tax_rate('VAT', b.bill_date) is null then raise exception 'No VAT rate is set for %', b.bill_date; end if;
  x := b.exchange_rate;

  perform set_config('sika.posting','on', true);
  for l in select * from bill_lines where bill_id = p_bill order by sort loop
    v_amt := round(l.qty * l.unit_cost, 2);
    g_amt := round(v_amt * x, 2);
    v_sub := v_sub + v_amt; g_sum := g_sum + g_amt;
    if l.taxable then v_taxable := v_taxable + v_amt; end if;
    if l.product_id is not null then
      update products set
        cost = round((greatest(stock_qty,0) * cost + l.qty * l.unit_cost * x) / (greatest(stock_qty,0) + l.qty), 4),
        stock_qty = stock_qty + l.qty
       where id = l.product_id;
      insert into stock_moves (company_id, product_id, move_date, qty, unit_cost, reason, ref_type, ref_id)
      values (b.company_id, l.product_id, b.bill_date, l.qty, l.unit_cost * x, 'Goods received', 'bill', b.id);
      v_lines := v_lines || jl(acct(b.company_id,'inventory'), g_amt, 0);
    else
      v_lines := v_lines || jl(l.account_id, g_amt, 0);
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
  return v_no;
end $$;

drop function if exists public.pay_bill(uuid, numeric, date, text, text);
create or replace function public.pay_bill(p_bill uuid, p_amount numeric, p_date date, p_method text,
  p_reference text default null, p_rate numeric default null)
returns void language plpgsql security definer set search_path = public as $$
declare b bills; v_je uuid; v_pay uuid; v_rate numeric; g_bank numeric; g_ap numeric;
begin
  select * into b from bills where id = p_bill for update;
  if not found then raise exception 'Bill not found'; end if;
  perform require_member(b.company_id, array['owner','admin','accountant']);
  if b.status = 'draft' then raise exception 'Post the bill before paying it'; end if;
  if round(p_amount,2) > b.total - b.amount_paid or p_amount <= 0 then
    raise exception 'Amount must be between 0 and the % still owed', b.total - b.amount_paid;
  end if;
  v_rate := case when b.currency = 'GHS' then 1 else coalesce(nullif(p_rate,0), b.exchange_rate) end;
  g_bank := round(p_amount * v_rate, 2); g_ap := round(p_amount * b.exchange_rate, 2);
  insert into bill_payments (company_id, bill_id, payment_date, amount, method, reference, exchange_rate)
  values (b.company_id, b.id, p_date, round(p_amount,2), p_method, p_reference, v_rate) returning id into v_pay;
  v_je := post_journal(b.company_id, p_date, 'Payment to supplier for ' || b.number,
    jsonb_build_array(
      jl(acct(b.company_id,'ap'), g_ap, 0),
      jl(acct(b.company_id, p_method), 0, g_bank),
      jl(acct(b.company_id,'fx'), greatest(g_bank - g_ap, 0), greatest(g_ap - g_bank, 0))),
    'bill_payment', v_pay);
  update bill_payments set journal_entry_id = v_je where id = v_pay;
  update bills set amount_paid = amount_paid + round(p_amount,2),
    status = case when amount_paid + round(p_amount,2) >= total then 'paid' else 'posted' end
   where id = b.id;
end $$;

-- =====================================================================
-- 4. Credit notes and invoice reversals
-- =====================================================================
create table public.credit_notes (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  number text,
  customer_id uuid not null references public.customers(id),
  invoice_id uuid references public.invoices(id),
  credit_date date not null default current_date,
  status text not null default 'draft' check (status in ('draft','posted')),
  reason text,
  currency text not null default 'GHS',
  exchange_rate numeric(14,6) not null default 1 check (exchange_rate > 0),
  subtotal numeric(14,2) not null default 0,
  vat numeric(14,2) not null default 0,
  nhil numeric(14,2) not null default 0,
  getfund numeric(14,2) not null default 0,
  total numeric(14,2) not null default 0,
  applied numeric(14,2) not null default 0,
  journal_entry_id uuid references public.journal_entries(id),
  created_at timestamptz not null default now()
);

create table public.credit_note_lines (
  id uuid primary key default gen_random_uuid(),
  credit_note_id uuid not null references public.credit_notes(id) on delete cascade,
  company_id uuid not null references public.companies(id) on delete cascade,
  product_id uuid references public.products(id),
  description text not null,
  qty numeric(14,3) not null check (qty > 0),
  unit_price numeric(14,2) not null check (unit_price >= 0),
  taxable boolean not null default true,
  restock boolean not null default false,
  sort int not null default 0
);

create or replace function public.post_credit_note(p_cn uuid)
returns text language plpgsql security definer set search_path = public as $$
declare
  cn credit_notes; inv invoices; l record; p products; x numeric;
  v_taxable numeric := 0; v_sub numeric := 0; v_goods numeric := 0; v_services numeric := 0; v_restock numeric := 0;
  v_vat numeric; v_nhil numeric; v_getf numeric; v_total numeric; v_no text; v_je uuid; v_apply numeric := 0;
  v_inv_no text; g_goods numeric; g_serv numeric; g_vat numeric; g_nhil numeric; g_getf numeric;
begin
  select * into cn from credit_notes where id = p_cn for update;
  if not found then raise exception 'Credit note not found'; end if;
  perform require_member(cn.company_id, array['owner','admin','accountant','sales']);
  if cn.status <> 'draft' then raise exception 'This credit note is already posted'; end if;
  if not exists (select 1 from credit_note_lines where credit_note_id = p_cn) then raise exception 'Add at least one line'; end if;
  if cn.invoice_id is not null then
    select * into inv from invoices where id = cn.invoice_id for update;
    if inv.status = 'draft' then raise exception 'The linked invoice is still a draft; delete or edit it instead'; end if;
    if inv.customer_id <> cn.customer_id then raise exception 'The linked invoice belongs to another customer'; end if;
    if inv.currency <> cn.currency then raise exception 'The credit note must be in the invoice currency (%)', inv.currency; end if;
    v_inv_no := inv.number;
  end if;
  x := cn.exchange_rate;

  perform set_config('sika.posting','on', true);
  for l in select * from credit_note_lines where credit_note_id = p_cn order by sort loop
    v_sub := v_sub + round(l.qty * l.unit_price, 2);
    if l.taxable then v_taxable := v_taxable + round(l.qty * l.unit_price, 2); end if;
    if l.product_id is not null then
      v_goods := v_goods + round(l.qty * l.unit_price, 2);
      if l.restock then
        select * into p from products where id = l.product_id for update;
        update products set stock_qty = stock_qty + l.qty where id = p.id;
        insert into stock_moves (company_id, product_id, move_date, qty, unit_cost, reason, ref_type, ref_id)
        values (cn.company_id, p.id, cn.credit_date, l.qty, p.cost, 'Customer return', 'credit_note', cn.id);
        v_restock := v_restock + round(l.qty * p.cost, 2);
      end if;
    else
      v_services := v_services + round(l.qty * l.unit_price, 2);
    end if;
  end loop;
  perform set_config('sika.posting','off', true);

  v_vat := round(v_taxable * tax_rate('VAT', cn.credit_date), 2);
  v_nhil := round(v_taxable * tax_rate('NHIL', cn.credit_date), 2);
  v_getf := round(v_taxable * tax_rate('GETFUND', cn.credit_date), 2);
  v_total := v_sub + v_vat + v_nhil + v_getf;
  g_goods := round(v_goods * x, 2); g_serv := round(v_services * x, 2);
  g_vat := round(v_vat * x, 2); g_nhil := round(v_nhil * x, 2); g_getf := round(v_getf * x, 2);
  v_no := next_number(cn.company_id, 'CN', 'CN-');

  v_je := post_journal(cn.company_id, cn.credit_date, 'Credit note ' || v_no || coalesce(' against ' || v_inv_no, ''),
    jsonb_build_array(
      jl(acct(cn.company_id,'sales'), g_goods, 0),
      jl(acct(cn.company_id,'services'), g_serv, 0),
      jl(acct(cn.company_id,'vat_out'), g_vat, 0),
      jl(acct(cn.company_id,'nhil_out'), g_nhil, 0),
      jl(acct(cn.company_id,'getf_out'), g_getf, 0),
      jl(acct(cn.company_id,'ar'), 0, g_goods + g_serv + g_vat + g_nhil + g_getf),
      jl(acct(cn.company_id,'inventory'), v_restock, 0),
      jl(acct(cn.company_id,'cogs'), 0, v_restock)),
    'credit_note', cn.id);

  if cn.invoice_id is not null then
    v_apply := least(v_total, inv.total - inv.amount_paid - inv.amount_credited);
    update invoices set amount_credited = amount_credited + v_apply,
      status = case when amount_paid + amount_credited + v_apply >= total then 'paid' else status end
     where id = inv.id;
  end if;
  update credit_notes set status = 'posted', number = v_no, subtotal = v_sub, vat = v_vat, nhil = v_nhil,
    getfund = v_getf, total = v_total, applied = v_apply, journal_entry_id = v_je where id = p_cn;
  return v_no;
end $$;

-- Full reversal: a credit note copying every line of the invoice, returning stock, posted at once.
create or replace function public.reverse_invoice(p_invoice uuid, p_date date, p_reason text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare inv invoices; v_cn uuid;
begin
  select * into inv from invoices where id = p_invoice;
  if not found then raise exception 'Invoice not found'; end if;
  perform require_member(inv.company_id, array['owner','admin','accountant','sales']);
  if inv.status = 'draft' then raise exception 'Drafts can simply be deleted'; end if;
  if exists (select 1 from credit_notes where invoice_id = p_invoice and status = 'posted' and total >= inv.total) then
    raise exception 'This invoice has already been reversed';
  end if;
  insert into credit_notes (company_id, customer_id, invoice_id, credit_date, reason, currency, exchange_rate)
  values (inv.company_id, inv.customer_id, inv.id, p_date, coalesce(p_reason, 'Reversal of ' || inv.number), inv.currency, inv.exchange_rate)
  returning id into v_cn;
  insert into credit_note_lines (credit_note_id, company_id, product_id, description, qty, unit_price, taxable, restock, sort)
  select v_cn, company_id, product_id, description, qty, unit_price, taxable, product_id is not null, sort
    from invoice_lines where invoice_id = p_invoice;
  perform post_credit_note(v_cn);
  return v_cn;
end $$;

-- =====================================================================
-- 5. Quotes and sales orders
-- =====================================================================
create table public.sales_quotes (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  number text,
  kind text not null default 'quote' check (kind in ('quote','order')),
  customer_id uuid not null references public.customers(id),
  quote_date date not null default current_date,
  valid_until date,
  status text not null default 'draft' check (status in ('draft','sent','accepted','declined','converted')),
  currency text not null default 'GHS',
  exchange_rate numeric(14,6) not null default 1,
  subtotal numeric(14,2) not null default 0,
  total numeric(14,2) not null default 0,
  notes text,
  invoice_id uuid references public.invoices(id),
  created_at timestamptz not null default now()
);

create table public.sales_quote_lines (
  id uuid primary key default gen_random_uuid(),
  quote_id uuid not null references public.sales_quotes(id) on delete cascade,
  company_id uuid not null references public.companies(id) on delete cascade,
  product_id uuid references public.products(id),
  description text not null,
  qty numeric(14,3) not null check (qty > 0),
  unit_price numeric(14,2) not null check (unit_price >= 0),
  taxable boolean not null default true,
  sort int not null default 0
);

create or replace function public.number_quote() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.number is null then
    new.number := case when new.kind = 'order' then next_number(new.company_id, 'SO', 'SO-') else next_number(new.company_id, 'QUO', 'QUO-') end;
  end if;
  return new;
end $$;
create trigger sales_quotes_number before insert on public.sales_quotes for each row execute function public.number_quote();

create or replace function public.convert_quote(p_quote uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare qt sales_quotes; v_inv uuid;
begin
  select * into qt from sales_quotes where id = p_quote for update;
  if not found then raise exception 'Quote not found'; end if;
  perform require_member(qt.company_id, array['owner','admin','accountant','sales']);
  if qt.status = 'converted' then raise exception 'Already converted to an invoice'; end if;
  insert into invoices (company_id, customer_id, invoice_date, notes, currency, exchange_rate)
  values (qt.company_id, qt.customer_id, current_date, coalesce(qt.notes, '') || case when qt.notes is null then '' else E'\n' end || 'From ' || qt.number,
          qt.currency, qt.exchange_rate)
  returning id into v_inv;
  insert into invoice_lines (invoice_id, company_id, product_id, description, qty, unit_price, taxable, sort)
  select v_inv, company_id, product_id, description, qty, unit_price, taxable, sort from sales_quote_lines where quote_id = p_quote;
  update sales_quotes set status = 'converted', invoice_id = v_inv where id = p_quote;
  return v_inv;
end $$;

-- =====================================================================
-- 6. Recurring invoices
-- =====================================================================
create table public.recurring_invoices (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  name text not null,
  customer_id uuid not null references public.customers(id),
  frequency text not null default 'monthly' check (frequency in ('weekly','monthly','quarterly','yearly')),
  next_date date not null,
  end_date date,
  auto_post boolean not null default false,
  active boolean not null default true,
  currency text not null default 'GHS',
  lines jsonb not null default '[]'::jsonb,   -- [{product_id, description, qty, unit_price, taxable}]
  notes text,
  last_generated date,
  created_at timestamptz not null default now()
);

create or replace function public.run_recurring(cid uuid)
returns int language plpgsql security definer set search_path = public as $$
declare
  r recurring_invoices; v_inv uuid; v_count int := 0; v_rate numeric; v_step interval; v_date date; l jsonb; i int;
begin
  perform require_member(cid, array['owner','admin','accountant','sales']);
  for r in select * from recurring_invoices where company_id = cid and active and next_date <= current_date
             and (end_date is null or next_date <= end_date) for update loop
    v_step := case r.frequency when 'weekly' then interval '7 days' when 'monthly' then interval '1 month'
                               when 'quarterly' then interval '3 months' else interval '1 year' end;
    v_date := r.next_date;
    while v_date <= current_date and (r.end_date is null or v_date <= r.end_date) loop
      v_rate := case when r.currency = 'GHS' then 1 else (select rate from currencies where company_id = cid and code = r.currency) end;
      if v_rate is null then raise exception 'Set an exchange rate for % under Settings before generating %', r.currency, r.name; end if;
      insert into invoices (company_id, customer_id, invoice_date, notes, currency, exchange_rate)
      values (cid, r.customer_id, v_date, coalesce(r.notes, r.name), r.currency, v_rate) returning id into v_inv;
      i := 0;
      for l in select * from jsonb_array_elements(r.lines) loop
        insert into invoice_lines (invoice_id, company_id, product_id, description, qty, unit_price, taxable, sort)
        values (v_inv, cid, nullif(l->>'product_id','')::uuid, l->>'description', (l->>'qty')::numeric,
                (l->>'unit_price')::numeric, coalesce((l->>'taxable')::boolean, true), i);
        i := i + 1;
      end loop;
      if r.auto_post then
        begin
          perform post_invoice(v_inv);
        exception when others then
          update invoices set notes = coalesce(notes,'') || E'\nNot posted automatically: ' || sqlerrm where id = v_inv;
        end;
      end if;
      v_count := v_count + 1;
      v_date := (v_date + v_step)::date;
    end loop;
    update recurring_invoices set next_date = v_date, last_generated = current_date,
      active = case when end_date is not null and v_date > end_date then false else active end
     where id = r.id;
  end loop;
  return v_count;
end $$;

-- =====================================================================
-- 7. Payroll extras: overtime and bonus tax, Tier 3, staff loans
-- =====================================================================
alter table public.employees add column if not exists is_junior boolean not null default false;
alter table public.employees add column if not exists tier3_employee_rate numeric(6,4) not null default 0 check (tier3_employee_rate >= 0 and tier3_employee_rate <= 0.5);
alter table public.employees add column if not exists tier3_employer_rate numeric(6,4) not null default 0 check (tier3_employer_rate >= 0 and tier3_employer_rate <= 0.5);

alter table public.payslips add column if not exists overtime numeric(14,2) not null default 0;
alter table public.payslips add column if not exists bonus numeric(14,2) not null default 0;
alter table public.payslips add column if not exists overtime_tax numeric(14,2) not null default 0;
alter table public.payslips add column if not exists bonus_tax numeric(14,2) not null default 0;
alter table public.payslips add column if not exists tier3_employee numeric(14,2) not null default 0;
alter table public.payslips add column if not exists tier3_employer numeric(14,2) not null default 0;
alter table public.payslips add column if not exists loan_deduction numeric(14,2) not null default 0;

alter table public.statutory_rates alter column rate type numeric(14,5);
insert into public.statutory_rates values
  ('OVERTIME_LOW', 0.05, '2015-01-01'),     -- junior staff, up to 50% of monthly basic
  ('OVERTIME_HIGH', 0.10, '2015-01-01'),    -- junior staff, above 50% of monthly basic
  ('OVERTIME_INCOME_LIMIT', 18000, '2015-01-01'), -- annual employment income limit for junior-staff rates
  ('BONUS_RATE', 0.05, '2015-01-01'),
  ('BONUS_CAP', 0.15, '2015-01-01'),        -- of annual basic salary, cumulative per year
  ('TIER3_RELIEF', 0.165, '2015-01-01')     -- of monthly income
on conflict do nothing;

create table public.payroll_inputs (
  company_id uuid not null references public.companies(id) on delete cascade,
  period date not null,
  employee_id uuid not null references public.employees(id) on delete cascade,
  overtime numeric(14,2) not null default 0 check (overtime >= 0),
  bonus numeric(14,2) not null default 0 check (bonus >= 0),
  primary key (company_id, period, employee_id)
);

create table public.employee_loans (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  employee_id uuid not null references public.employees(id),
  issue_date date not null,
  principal numeric(14,2) not null check (principal > 0),
  installment numeric(14,2) not null check (installment > 0),
  balance numeric(14,2) not null,
  status text not null default 'active' check (status in ('active','settled')),
  note text,
  journal_entry_id uuid references public.journal_entries(id),
  created_at timestamptz not null default now()
);

create table public.loan_repayments (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  loan_id uuid not null references public.employee_loans(id) on delete cascade,
  run_id uuid references public.payroll_runs(id),
  repay_date date not null,
  amount numeric(14,2) not null
);

create or replace function public.issue_loan(p_employee uuid, p_principal numeric, p_installment numeric,
  p_date date, p_method text, p_note text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare e employees; v_id uuid; v_je uuid;
begin
  select * into e from employees where id = p_employee;
  if not found then raise exception 'Employee not found'; end if;
  perform require_member(e.company_id, array['owner','admin','accountant']);
  if p_installment > p_principal then raise exception 'The monthly deduction cannot be more than the loan'; end if;
  insert into employee_loans (company_id, employee_id, issue_date, principal, installment, balance, note)
  values (e.company_id, e.id, p_date, round(p_principal,2), round(p_installment,2), round(p_principal,2), p_note) returning id into v_id;
  v_je := post_journal(e.company_id, p_date, 'Staff loan to ' || e.full_name,
    jsonb_build_array(jl(acct(e.company_id,'staff_loans'), p_principal, 0), jl(acct(e.company_id, p_method), 0, p_principal)),
    'loan', v_id);
  update employee_loans set journal_entry_id = v_je where id = v_id;
  return v_id;
end $$;

create or replace function public.prepare_payroll(cid uuid, p_period date)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_run uuid; v_period date := date_trunc('month', p_period)::date; v_status text; v_payday date;
  e record; v_ot numeric; v_bonus numeric; v_gross numeric; v_emp numeric; v_er numeric; v_t2 numeric;
  v_t3e numeric; v_t3r numeric; v_ot_tax numeric; v_ot_taxable numeric; v_ot_low numeric;
  v_ytd numeric; v_cap_left numeric; v_b_conc numeric; v_bonus_tax numeric; v_bonus_taxable numeric;
  v_relief_cap numeric; v_t3_relief numeric; v_t3_excess numeric; v_charge numeric; v_paye numeric;
  v_before numeric; v_loan numeric; v_net numeric;
begin
  perform require_member(cid, array['owner','admin','hr','accountant']);
  v_payday := (v_period + interval '1 month - 1 day')::date;
  select id, status into v_run, v_status from payroll_runs where company_id = cid and period = v_period;
  if v_run is not null and v_status <> 'draft' then raise exception 'Payroll for this month is already posted'; end if;
  if v_run is null then
    insert into payroll_runs (company_id, period) values (cid, v_period) returning id into v_run;
  else
    delete from payslips where run_id = v_run;
  end if;

  for e in select * from employees where company_id = cid and status = 'active' order by full_name loop
    select coalesce(max(overtime),0), coalesce(max(bonus),0) into v_ot, v_bonus
      from payroll_inputs where company_id = cid and period = v_period and employee_id = e.id;
    v_gross := e.basic_salary + e.allowances + v_ot + v_bonus;
    v_emp := round(e.basic_salary * stat_rate('SSNIT_EMPLOYEE', v_payday), 2);
    v_er := round(e.basic_salary * stat_rate('SSNIT_EMPLOYER', v_payday), 2);
    v_t2 := round(e.basic_salary * stat_rate('TIER2', v_payday), 2);
    v_t3e := round(e.basic_salary * e.tier3_employee_rate, 2);
    v_t3r := round(e.basic_salary * e.tier3_employer_rate, 2);

    -- Overtime: final tax for qualifying junior staff, otherwise ordinary employment income.
    if v_ot > 0 and e.is_junior and (e.basic_salary + e.allowances) * 12 <= stat_rate('OVERTIME_INCOME_LIMIT', v_payday) then
      v_ot_low := least(v_ot, 0.5 * e.basic_salary);
      v_ot_tax := round(v_ot_low * stat_rate('OVERTIME_LOW', v_payday) + (v_ot - v_ot_low) * stat_rate('OVERTIME_HIGH', v_payday), 2);
      v_ot_taxable := 0;
    else
      v_ot_tax := 0; v_ot_taxable := v_ot;
    end if;

    -- Bonus: 5% final tax within 15% of annual basic (cumulative this calendar year); excess through PAYE.
    select coalesce(sum(s.bonus),0) into v_ytd from payslips s join payroll_runs r on r.id = s.run_id
     where r.company_id = cid and s.employee_id = e.id and r.period <> v_period
       and extract(year from r.period) = extract(year from v_period);
    v_cap_left := greatest(0, stat_rate('BONUS_CAP', v_payday) * e.basic_salary * 12 - v_ytd);
    v_b_conc := least(v_bonus, v_cap_left);
    v_bonus_tax := round(v_b_conc * stat_rate('BONUS_RATE', v_payday), 2);
    v_bonus_taxable := v_bonus - v_b_conc;

    -- Tier 3: employee + employer contributions relieved up to 16.5% of monthly income.
    v_relief_cap := round(stat_rate('TIER3_RELIEF', v_payday) * (e.basic_salary + e.allowances), 2);
    v_t3_relief := least(v_t3e, greatest(0, v_relief_cap - v_t3r));
    v_t3_excess := greatest(0, v_t3r - v_relief_cap);

    v_charge := e.basic_salary + e.allowances + v_ot_taxable + v_bonus_taxable + v_t3_excess - v_emp - v_t3_relief;
    v_paye := compute_paye(v_charge, v_payday);
    v_before := v_gross - v_emp - v_t3e - v_paye - v_ot_tax - v_bonus_tax;
    select coalesce(sum(least(installment, balance)),0) into v_loan from employee_loans
     where employee_id = e.id and status = 'active' and issue_date <= v_payday;
    v_loan := least(greatest(v_before, 0), v_loan);
    v_net := v_before - v_loan;

    insert into payslips (run_id, company_id, employee_id, basic, allowances, gross, ssnit_employee, chargeable,
                          paye, net, ssnit_employer, tier1, tier2, overtime, bonus, overtime_tax, bonus_tax,
                          tier3_employee, tier3_employer, loan_deduction)
    values (v_run, cid, e.id, e.basic_salary, e.allowances, v_gross, v_emp, v_charge,
            v_paye, v_net, v_er, v_emp + v_er - v_t2, v_t2, v_ot, v_bonus, v_ot_tax, v_bonus_tax,
            v_t3e, v_t3r, v_loan);
  end loop;

  update payroll_runs r set
    gross = coalesce(s.gross,0), paye = coalesce(s.tax,0), ssnit_employee = coalesce(s.emp,0),
    ssnit_employer = coalesce(s.er,0), net = coalesce(s.net,0)
  from (select sum(gross) gross, sum(paye + overtime_tax + bonus_tax) tax, sum(ssnit_employee) emp,
               sum(ssnit_employer) er, sum(net) net from payslips where run_id = v_run) s
  where r.id = v_run;
  return v_run;
end $$;

create or replace function public.post_payroll(p_run uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  r payroll_runs; v_t1 numeric; v_t2 numeric; v_t3e numeric; v_t3r numeric; v_loans numeric;
  v_je uuid; v_date date; s record; ln record; v_left numeric; v_take numeric;
begin
  select * into r from payroll_runs where id = p_run for update;
  if not found then raise exception 'Payroll run not found'; end if;
  perform require_member(r.company_id, array['owner','admin','accountant']);
  if r.status <> 'draft' then raise exception 'This payroll is already posted'; end if;
  if r.gross = 0 then raise exception 'There are no payslips in this run'; end if;
  select sum(tier1), sum(tier2), sum(tier3_employee), sum(tier3_employer), sum(loan_deduction)
    into v_t1, v_t2, v_t3e, v_t3r, v_loans from payslips where run_id = p_run;
  v_date := (r.period + interval '1 month - 1 day')::date;
  v_je := post_journal(r.company_id, v_date, 'Payroll ' || to_char(r.period, 'Mon YYYY'),
    jsonb_build_array(
      jl(acct(r.company_id,'salaries'), r.gross, 0),
      jl(acct(r.company_id,'employer_ssnit'), r.ssnit_employer, 0),
      jl(acct(r.company_id,'employer_tier3'), v_t3r, 0),
      jl(acct(r.company_id,'paye'), 0, r.paye),
      jl(acct(r.company_id,'ssnit1'), 0, v_t1),
      jl(acct(r.company_id,'tier2'), 0, v_t2),
      jl(acct(r.company_id,'tier3'), 0, v_t3e + v_t3r),
      jl(acct(r.company_id,'staff_loans'), 0, v_loans),
      jl(acct(r.company_id,'net_pay'), 0, r.net)),
    'payroll', r.id);

  -- Apply loan deductions to loans, oldest first.
  for s in select * from payslips where run_id = p_run and loan_deduction > 0 loop
    v_left := s.loan_deduction;
    for ln in select * from employee_loans where employee_id = s.employee_id and status = 'active' order by issue_date, created_at for update loop
      exit when v_left <= 0;
      v_take := least(v_left, ln.installment, ln.balance);
      update employee_loans set balance = balance - v_take, status = case when balance - v_take <= 0 then 'settled' else 'active' end where id = ln.id;
      insert into loan_repayments (company_id, loan_id, run_id, repay_date, amount) values (r.company_id, ln.id, p_run, v_date, v_take);
      v_left := v_left - v_take;
    end loop;
  end loop;
  update payroll_runs set status = 'posted', journal_entry_id = v_je where id = p_run;
end $$;

-- =====================================================================
-- 8. Leave entitlements and balances
-- =====================================================================
create table public.leave_types (
  company_id uuid not null references public.companies(id) on delete cascade,
  code text not null,
  name text not null,
  days_per_year numeric(5,1),    -- null = no annual limit
  paid boolean not null default true,
  primary key (company_id, code)
);

create table public.leave_entitlements (
  company_id uuid not null references public.companies(id) on delete cascade,
  employee_id uuid not null references public.employees(id) on delete cascade,
  leave_code text not null,
  year int not null,
  days numeric(5,1) not null,      -- overrides the type's default, e.g. long service or carry-over
  primary key (employee_id, leave_code, year)
);

create or replace function public.seed_leave_types(cid uuid)
returns void language sql security definer set search_path = public as $$
  insert into leave_types (company_id, code, name, days_per_year, paid) values
  (cid,'annual','Annual',15,true),
  (cid,'sick','Sick',null,true),
  (cid,'maternity','Maternity',null,true),
  (cid,'paternity','Paternity',null,true),
  (cid,'compassionate','Compassionate',null,true),
  (cid,'study','Study',null,true),
  (cid,'unpaid','Unpaid',null,false)
  on conflict do nothing;
$$;
select public.seed_leave_types(id) from public.companies;

create or replace function public.leave_balances(cid uuid, p_year int)
returns table (employee_id uuid, full_name text, leave_code text, leave_name text,
               entitlement numeric, taken numeric, pending numeric, remaining numeric)
language sql stable security definer set search_path = public as $$
  select e.id, e.full_name, t.code, t.name,
    coalesce(en.days, t.days_per_year),
    coalesce((select sum(days) from leave_requests r where r.employee_id = e.id and r.leave_type = t.code
               and r.status = 'approved' and extract(year from r.start_date) = p_year), 0),
    coalesce((select sum(days) from leave_requests r where r.employee_id = e.id and r.leave_type = t.code
               and r.status = 'pending' and extract(year from r.start_date) = p_year), 0),
    coalesce(en.days, t.days_per_year) - coalesce((select sum(days) from leave_requests r where r.employee_id = e.id
               and r.leave_type = t.code and r.status = 'approved' and extract(year from r.start_date) = p_year), 0)
  from employees e
  cross join leave_types t
  left join leave_entitlements en on en.employee_id = e.id and en.leave_code = t.code and en.year = p_year
  where e.company_id = cid and t.company_id = cid and e.status = 'active' and is_member(cid)
  order by e.full_name, t.name;
$$;

-- =====================================================================
-- 9. Recruitment and appraisals
-- =====================================================================
create table public.job_openings (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  title text not null,
  department text,
  location text,
  employment_type text default 'Full-time',
  description text,
  closing_date date,
  status text not null default 'open' check (status in ('open','closed','filled')),
  created_at timestamptz not null default now()
);

create table public.applicants (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  opening_id uuid not null references public.job_openings(id) on delete cascade,
  full_name text not null,
  email text, phone text,
  stage text not null default 'applied' check (stage in ('applied','screening','interview','offer','hired','rejected')),
  rating int check (rating between 1 and 5),
  notes text,
  employee_id uuid references public.employees(id),
  created_at timestamptz not null default now()
);

create table public.appraisals (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  employee_id uuid not null references public.employees(id) on delete cascade,
  period_label text not null,          -- e.g. "2026 annual", "H1 2026"
  review_date date not null default current_date,
  reviewer text,
  rating int check (rating between 1 and 5),
  achievements text,
  strengths text,
  improvements text,
  goals text,
  employee_comments text,
  status text not null default 'draft' check (status in ('draft','completed')),
  created_at timestamptz not null default now()
);

-- =====================================================================
-- 10. Bank reconciliation
-- =====================================================================
create table public.bank_reconciliations (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  account_id uuid not null references public.accounts(id),
  statement_date date not null,
  statement_balance numeric(14,2) not null,
  completed_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);
alter table public.journal_lines add column if not exists reconciliation_id uuid references public.bank_reconciliations(id);

create or replace function public.complete_reconciliation(cid uuid, p_account uuid, p_date date, p_balance numeric, p_lines uuid[])
returns uuid language plpgsql security definer set search_path = public as $$
declare v_open numeric; v_sel numeric; v_bad int; v_id uuid;
begin
  perform require_member(cid, array['owner','admin','accountant']);
  if not exists (select 1 from accounts where id = p_account and company_id = cid and system_key in ('bank','momo','cash')) then
    raise exception 'Choose a bank, Mobile Money or cash account';
  end if;
  select count(*) into v_bad from journal_lines l join journal_entries e on e.id = l.entry_id
   where l.id = any(p_lines) and (l.account_id <> p_account or l.reconciliation_id is not null or e.entry_date > p_date);
  if v_bad > 0 or (select count(*) from journal_lines where id = any(p_lines)) <> coalesce(array_length(p_lines,1),0) then
    raise exception 'Some ticked lines are not valid for this account and date';
  end if;
  select coalesce(sum(debit - credit),0) into v_open from journal_lines where account_id = p_account and reconciliation_id is not null;
  select coalesce(sum(debit - credit),0) into v_sel from journal_lines where id = any(p_lines);
  if round(v_open + v_sel, 2) <> round(p_balance, 2) then
    raise exception 'Cleared balance % does not match the statement balance % (difference %)', round(v_open + v_sel,2), round(p_balance,2), round(p_balance - v_open - v_sel, 2);
  end if;
  insert into bank_reconciliations (company_id, account_id, statement_date, statement_balance)
  values (cid, p_account, p_date, p_balance) returning id into v_id;
  update journal_lines set reconciliation_id = v_id where id = any(p_lines);
  return v_id;
end $$;

create or replace function public.undo_reconciliation(p_rec uuid)
returns void language plpgsql security definer set search_path = public as $$
declare rec bank_reconciliations;
begin
  select * into rec from bank_reconciliations where id = p_rec;
  if not found then raise exception 'Reconciliation not found'; end if;
  perform require_member(rec.company_id, array['owner','admin','accountant']);
  if exists (select 1 from bank_reconciliations where account_id = rec.account_id and created_at > rec.created_at) then
    raise exception 'Undo the later reconciliations for this account first';
  end if;
  update journal_lines set reconciliation_id = null where reconciliation_id = p_rec;
  delete from bank_reconciliations where id = p_rec;
end $$;

-- =====================================================================
-- 11. Budgets
-- =====================================================================
create table public.budgets (
  company_id uuid not null references public.companies(id) on delete cascade,
  account_id uuid not null references public.accounts(id) on delete cascade,
  year int not null,
  month int not null check (month between 1 and 12),
  amount numeric(14,2) not null default 0,
  primary key (account_id, year, month)
);

create or replace function public.monthly_actuals(cid uuid, p_year int)
returns table (account_id uuid, month int, debit numeric, credit numeric)
language sql stable security definer set search_path = public as $$
  select l.account_id, extract(month from e.entry_date)::int, sum(l.debit), sum(l.credit)
    from journal_lines l join journal_entries e on e.id = l.entry_id
   where l.company_id = cid and extract(year from e.entry_date) = p_year
     and has_role(cid, array['owner','admin','accountant'])
   group by l.account_id, extract(month from e.entry_date);
$$;

-- =====================================================================
-- 12. New company set-up includes the v1.1 defaults
-- =====================================================================
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
  perform seed_leave_types(v);
  return v;
end $$;

-- =====================================================================
-- 13. Row-level security for new tables
-- =====================================================================
do $$ declare t text; begin
  -- any member reads and writes
  foreach t in array array['currencies','sales_quotes','recurring_invoices'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy "members read" on public.%I for select using (is_member(company_id))', t);
    execute format('create policy "members insert" on public.%I for insert with check (is_member(company_id))', t);
    execute format('create policy "members update" on public.%I for update using (is_member(company_id))', t);
    execute format('create policy "members delete" on public.%I for delete using (is_member(company_id))', t);
  end loop;
  -- HR data: owners, admins and HR write; accountants read
  foreach t in array array['job_openings','applicants','appraisals','leave_entitlements','payroll_inputs'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy "hr reads" on public.%I for select using (has_role(company_id, array[''owner'',''admin'',''hr'',''accountant'']))', t);
    execute format('create policy "hr writes" on public.%I for all using (has_role(company_id, array[''owner'',''admin'',''hr''])) with check (has_role(company_id, array[''owner'',''admin'',''hr'']))', t);
  end loop;
  -- accounting data written by accountants
  foreach t in array array['budgets'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy "accountants read" on public.%I for select using (has_role(company_id, array[''owner'',''admin'',''accountant'']))', t);
    execute format('create policy "accountants write" on public.%I for all using (has_role(company_id, array[''owner'',''admin'',''accountant''])) with check (has_role(company_id, array[''owner'',''admin'',''accountant'']))', t);
  end loop;
  -- read-only, written by functions
  foreach t in array array['bank_reconciliations','loan_repayments'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy "accountants read" on public.%I for select using (has_role(company_id, array[''owner'',''admin'',''accountant'',''hr'']))', t);
  end loop;
end $$;

alter table public.employee_loans enable row level security;
create policy "payroll staff read loans" on public.employee_loans for select using (has_role(company_id, array['owner','admin','accountant','hr']));

alter table public.leave_types enable row level security;
create policy "members read leave types" on public.leave_types for select using (is_member(company_id));
create policy "hr writes leave types" on public.leave_types for all
  using (has_role(company_id, array['owner','admin','hr'])) with check (has_role(company_id, array['owner','admin','hr']));

-- Credit notes: like invoices, editable only while draft.
alter table public.credit_notes enable row level security;
create policy "members read" on public.credit_notes for select using (is_member(company_id));
create policy "members insert drafts" on public.credit_notes for insert with check (is_member(company_id) and status = 'draft');
create policy "members edit drafts" on public.credit_notes for update using (is_member(company_id) and status = 'draft') with check (status = 'draft');
create policy "members delete drafts" on public.credit_notes for delete using (is_member(company_id) and status = 'draft');
alter table public.credit_note_lines enable row level security;
create policy "members read" on public.credit_note_lines for select using (is_member(company_id));
create policy "members write draft lines" on public.credit_note_lines for all
  using (is_member(company_id) and exists (select 1 from credit_notes c where c.id = credit_note_id and c.status = 'draft'))
  with check (is_member(company_id) and exists (select 1 from credit_notes c where c.id = credit_note_id and c.status = 'draft'));

alter table public.sales_quote_lines enable row level security;
create policy "members read" on public.sales_quote_lines for select using (is_member(company_id));
create policy "members write" on public.sales_quote_lines for all using (is_member(company_id)) with check (is_member(company_id));

-- Function permissions
revoke execute on all functions in schema public from public, anon;
grant execute on all functions in schema public to authenticated;
revoke execute on function public.post_journal(uuid,date,text,jsonb,text,uuid) from authenticated;
revoke execute on function public.seed_accounts(uuid) from authenticated;
revoke execute on function public.seed_accounts_v11(uuid) from authenticated;
revoke execute on function public.seed_leave_types(uuid) from authenticated;
revoke execute on function public.next_number(uuid,text,text) from authenticated;
