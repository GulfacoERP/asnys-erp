import { useState } from 'react';
import { Link, useNavigate, useParams, useSearchParams } from 'react-router-dom';
import { q, qPage, rpc, supabase } from '../lib/supabase';
import { useSession } from '../lib/session';
import { cedis, longDate, money, qty, today } from '../lib/format';
import { downloadCsv } from '../lib/download';
import { goodsReceivedPdf, purchaseOrderPdf, statementPdf } from '../lib/pdf';
import { ConfirmButton, Empty, Field, FormModal, Loading, PageHead, Panel, Select, Status, useAction, useLoad } from '../components/ui';
import { Pager, SearchBox, usePaged } from '../components/paging';
import { ApprovalBox } from './Finance';

export const PO_STATUS: Record<string, [string, string]> = {
  draft: ['Draft', ''], approved: ['Approved', 'good'], sent: ['Sent to supplier', 'warn'], partial: ['Part delivered', 'warn'],
  received: ['Delivered', 'good'], closed: ['Closed', ''], cancelled: ['Cancelled', 'bad'],
};
export const PoStatus = ({ s }: { s: string }) => <span className={'pill ' + (PO_STATUS[s]?.[1] || '')}>{PO_STATUS[s]?.[0] || s}</span>;
const poTotal = (lines: any[]) => lines.reduce((a, l) => a + Number(l.qty) * Number(l.unit_cost), 0);

// ---------------------------------------------------------------- List
export function PurchaseOrdersPage() {
  const { cid, can } = useSession();
  const nav = useNavigate();
  const [view, setView] = useState<'open' | 'draft' | 'done' | 'all'>('open');
  const [search, setSearch] = useState('');
  const statuses = { open: ['approved', 'sent', 'partial'], draft: ['draft'], done: ['received', 'closed', 'cancelled'], all: null }[view];
  const pg = usePaged(async (a, b) => {
    let x = supabase.from('purchase_orders').select('*, supplier:suppliers!inner(name), project:projects(number,name), warehouse:warehouses(code,name), lines:po_lines(qty,unit_cost,unit_price_fx,received_qty,billed_qty)', { count: 'exact' })
      .eq('company_id', cid).order('order_date', { ascending: false }).order('number', { ascending: false });
    if (statuses) x = x.in('status', statuses);
    if (search) x = x.or(`number.ilike.%${search}%,notes.ilike.%${search}%`, {});
    return qPage(x.range(a, b) as any);
  }, [cid, view, search]);
  const { data: counts } = useLoad(async () => {
    const rows = await q<any[]>(supabase.from('purchase_orders').select('status, expected_date').eq('company_id', cid).in('status', ['draft', 'approved', 'sent', 'partial']) as any);
    return { draft: rows.filter(r => r.status === 'draft').length, open: rows.filter(r => r.status !== 'draft').length, late: rows.filter(r => r.status !== 'draft' && r.expected_date && r.expected_date < today()).length };
  }, [cid]);
  const head = ['Order', 'Date', 'Supplier', 'Deliver to', 'Expected', 'Currency', 'Value in currency', 'Value (GHS)', 'Received %', 'Status'];
  const rows = pg.rows.map(o => { const t = poTotal(o.lines), rq = o.lines.reduce((s: number, l: any) => s + Number(l.qty), 0), rc = o.lines.reduce((s: number, l: any) => s + Number(l.received_qty), 0);
    return [o.number, o.order_date, o.supplier?.name, o.project ? `${o.project.number || ''} ${o.project.name}` : o.warehouse?.name || '', o.expected_date || '', o.currency && o.currency !== 'GHS' ? o.currency : 'GHS', money(fxTotal(o)), money(t), rq ? String(Math.round(rc / rq * 100)) : '0', PO_STATUS[o.status]?.[0]]; });
  return <>
    <PageHead title="Purchase orders" sub={counts ? `${counts.open} open · ${counts.draft} draft${counts.late ? ` · ${counts.late} late` : ''}` : undefined}>
      <button className="btn" type="button" onClick={() => downloadCsv('purchase-orders', head, rows)}>Download CSV</button>
      <Link className="btn" to="/inventory?tab=reorder">Reorder list</Link>
      {can('accountant', 'store', 'project_manager') && <Link className="btn primary" to="/purchase-orders/new">New purchase order</Link>}
    </PageHead>
    <div className="filters">
      <div className="actions" style={{ alignSelf: 'end' }}>{([['open', 'Waiting for delivery'], ['draft', 'Drafts'], ['done', 'Delivered and closed'], ['all', 'All']] as const).map(([k, l]) =>
        <button key={k} type="button" className={'btn small' + (view === k ? ' primary' : '')} onClick={() => setView(k)}>{l}</button>)}</div>
      <SearchBox value={search} onChange={setSearch} placeholder="Order number or note" id="po-search" />
    </div>
    <Loading error={pg.error} loading={pg.loading && !pg.data} />
    {pg.data && <Panel>
      {pg.rows.length ? <div className="scroll"><table>
        <thead><tr><th>Order</th><th>Supplier</th><th>Deliver to</th><th>Expected</th><th className="r">Value (GH₵)</th><th style={{ width: 120 }}>Delivered</th><th>Status</th></tr></thead>
        <tbody>{pg.rows.map(o => { const rq = o.lines.reduce((s: number, l: any) => s + Number(l.qty), 0), rc = o.lines.reduce((s: number, l: any) => s + Number(l.received_qty), 0);
          const late = ['approved', 'sent', 'partial'].includes(o.status) && o.expected_date && o.expected_date < today();
          return <tr key={o.id} className="click" tabIndex={0} onClick={() => nav('/purchase-orders/' + o.id)} onKeyDown={e => e.key === 'Enter' && nav('/purchase-orders/' + o.id)}>
            <td className="num"><b>{o.number}</b><br /><span className="muted" style={{ fontSize: 12 }}>{o.order_date}</span></td>
            <td>{o.supplier?.name}</td>
            <td>{o.project ? <><span className="pill">Site</span> {o.project.number} {o.project.name}</> : o.warehouse?.name}</td>
            <td className="num" style={{ color: late ? 'var(--bad)' : undefined }}>{o.expected_date || '—'}{late && <><br /><span style={{ fontSize: 12 }}>Late</span></>}</td>
            <td className="r num">{money(poTotal(o.lines))}{o.currency && o.currency !== 'GHS' && <><br /><span className="muted" style={{ fontSize: 12 }}>{o.currency} {money(fxTotal(o))}</span></>}</td>
            <td>{rq ? <span className="num" style={{ fontSize: 13 }}>{Math.round(rc / rq * 100)}%</span> : ''}</td>
            <td><PoStatus s={o.status} /></td></tr>; })}</tbody>
      </table></div> : <Empty>{view === 'open' ? 'No orders waiting for delivery.' : 'No purchase orders here.'} A purchase order tells a supplier exactly what to deliver, where and at what price. When the goods arrive, the store receives them against the order, and the supplier's bill is matched to what was received.</Empty>}
      <Pager {...pg} noun="orders" />
    </Panel>}
  </>;
}

const fxTotal = (o: any) => (o.lines || []).reduce((s: number, l: any) => s + Number(l.qty) * Number(o.currency && o.currency !== 'GHS' ? l.unit_price_fx ?? 0 : l.unit_cost), 0);

// ---------------------------------------------------------------- Create or edit a draft
type PoLine = { target: string; description: string; qty: string; unit_cost: string; taxable: boolean; project_id: string; request_id?: string | null };
const blankLine = (project = ''): PoLine => ({ target: '', description: '', qty: '1', unit_cost: '', taxable: true, project_id: project });

export function PoEditor() {
  const { id } = useParams();
  const [sp] = useSearchParams();
  const { cid } = useSession();
  const nav = useNavigate();
  const act = useAction();
  const [form, setForm] = useState<any | null>(null);
  const [lines, setLines] = useState<PoLine[]>([]);
  const { data, error, loading } = useLoad(async () => {
    const [suppliers, products, accounts, warehouses, projects, branches, prices] = await Promise.all([
      q<any[]>(supabase.from('suppliers').select('id,name,payment_terms_days').eq('company_id', cid).order('name') as any),
      q<any[]>(supabase.from('products').select('id,sku,name,unit,cost,last_purchase_cost,item_type,taxable,preferred_supplier_id').eq('company_id', cid).eq('active', true).order('name') as any),
      q<any[]>(supabase.from('accounts').select('id,code,name').eq('company_id', cid).in('type', ['expense', 'asset']).eq('active', true).order('code') as any),
      q<any[]>(supabase.from('warehouses').select('id,code,name,is_default').eq('company_id', cid).eq('active', true).order('code') as any),
      q<any[]>(supabase.from('projects').select('id,number,name').eq('company_id', cid).eq('is_template', false).in('status', ['planned', 'active', 'on_hold', 'done']).order('name') as any),
      q<any[]>(supabase.from('branches').select('id,code,name').eq('company_id', cid).eq('active', true).order('code') as any).catch(() => [] as any[]),
      q<any[]>(supabase.from('supplier_items').select('supplier_id,product_id,price').eq('company_id', cid) as any),
    ]);
    const currencies = await q<any[]>(supabase.from('currencies').select('code,name,rate').eq('company_id', cid).order('code') as any).catch(() => [] as any[]);
    const def = warehouses.find(w => w.is_default)?.id || warehouses[0]?.id || '';
    if (id) {
      const po = await q<any>(supabase.from('purchase_orders').select('*').eq('id', id).single() as any);
      const ls = await q<any[]>(supabase.from('po_lines').select('*').eq('po_id', id).order('sort') as any);
      setForm({ ...po, currency: po.currency || 'GHS', exchange_rate: String(po.exchange_rate || 1), deliver: po.project_id ? 'project' : 'store', warehouse_id: po.warehouse_id || def, project_id: po.project_id || '', expected_date: po.expected_date || '', notes: po.notes || '', terms: po.terms || '', branch_id: po.branch_id || '' });
      setLines(ls.map(l => ({ target: l.product_id ? 'p:' + l.product_id : l.account_id ? 'a:' + l.account_id : '', description: l.description, qty: String(Number(l.qty)), unit_cost: String(l.unit_price_fx ?? l.unit_cost), taxable: l.taxable, project_id: l.project_id || '', request_id: l.request_id })));
    } else {
      const proj = sp.get('project') || '';
      const sup = sp.get('supplier') || suppliers[0]?.id || '';
      setForm({ currency: 'GHS', exchange_rate: '1', supplier_id: sup, order_date: today(), expected_date: '', deliver: proj ? 'project' : 'store', warehouse_id: def, project_id: proj, branch_id: '', notes: '', terms: '' });
      const items = (sp.get('items') || '').split(',').filter(Boolean).map(s => s.split(':'));
      setLines(items.length ? items.map(([pid, n]) => { const p = products.find(x => x.id === pid);
        const price = prices.find(x => x.product_id === pid && x.supplier_id === sup)?.price ?? p?.last_purchase_cost ?? p?.cost ?? '';
        return { target: 'p:' + pid, description: p?.name || '', qty: n || '1', unit_cost: String(price), taxable: p?.taxable ?? true, project_id: '' }; }) : [blankLine(proj)]);
    }
    return { suppliers, products, accounts, warehouses, projects, branches, prices, currencies };
  }, [cid, id]);
  if (!data || !form) return <Loading error={error} loading={loading} />;
  if (!data.suppliers.length) return <><PageHead title="New purchase order" /><Empty>Add a supplier first. <Link to="/suppliers">Go to Suppliers</Link>.</Empty></>;

  const setLine = (i: number, patch: Partial<PoLine>) => setLines(ls => ls.map((l, j) => (j === i ? { ...l, ...patch } : l)));
  const cur = form.currency || 'GHS', fx = cur !== 'GHS', rate = Number(form.exchange_rate) || 1;
  const priceFor = (pid: string) => { const p = data.products.find(x => x.id === pid);
    const ghs = data.prices.find(x => x.product_id === pid && x.supplier_id === form.supplier_id)?.price ?? p?.last_purchase_cost ?? p?.cost ?? '';
    return ghs === '' ? '' : fx ? (Math.round(Number(ghs) / rate * 100) / 100) : ghs; };
  const pick = (i: number, v: string) => {
    if (v.startsWith('p:')) { const p = data.products.find(x => x.id === v.slice(2)); setLine(i, { target: v, description: p?.name || '', unit_cost: String(priceFor(v.slice(2))), taxable: p?.taxable ?? true }); }
    else { const a = data.accounts.find(x => x.id === v.slice(2)); setLine(i, { target: v, description: lines[i].description || a?.name || '' }); }
  };
  const total = lines.reduce((a, l) => a + (Number(l.qty) * Number(l.unit_cost) || 0), 0);
  const project = form.deliver === 'project' ? form.project_id : '';

  const save = () => act.run(async () => {
    const valid = lines.filter(l => (l.target || l.project_id || project) && l.description.trim() && Number(l.qty) > 0);
    if (!valid.length) throw new Error('Each line needs an item or expense account, a description and a quantity.');
    if (form.deliver === 'project' && !form.project_id) throw new Error('Choose the project the goods are delivered to.');
    if (fx && !(rate > 0)) throw new Error('Enter the exchange rate (GH₵ per 1 ' + cur + ').');
    const row = { currency: cur, exchange_rate: fx ? rate : 1, supplier_id: form.supplier_id, order_date: form.order_date, expected_date: form.expected_date || null, notes: form.notes || null, terms: form.terms || null,
      warehouse_id: form.deliver === 'store' ? form.warehouse_id || null : null, project_id: project || null, branch_id: form.branch_id || null };
    let poId = id;
    if (poId) {
      await q(supabase.from('purchase_orders').update(row).eq('id', poId) as any);
      await q(supabase.from('po_lines').delete().eq('po_id', poId) as any);
    } else poId = (await q<any>(supabase.from('purchase_orders').insert({ ...row, company_id: cid }).select('id').single() as any)).id;
    await q(supabase.from('po_lines').insert(valid.map((l, i) => ({
      po_id: poId, company_id: cid, product_id: l.target.startsWith('p:') ? l.target.slice(2) : null, account_id: l.target.startsWith('a:') ? l.target.slice(2) : null,
      description: l.description.trim(), qty: Number(l.qty), unit_cost: fx ? Math.round((Number(l.unit_cost) || 0) * rate * 100) / 100 : Number(l.unit_cost) || 0, unit_price_fx: fx ? Number(l.unit_cost) || 0 : null, taxable: l.taxable, project_id: l.project_id || project || null, request_id: l.request_id || null, sort: i,
    }))) as any);
    nav('/purchase-orders/' + poId, { replace: true });
  }, 'Order saved as a draft');

  return <>
    <PageHead title={id ? `Edit ${form.number}` : 'New purchase order'} sub="Prices exclude VAT. The order is a commitment, not a cost: nothing reaches the books until the goods are received.">
      <Link className="btn" to={id ? '/purchase-orders/' + id : '/purchase-orders'}>Cancel</Link>
      <button className="btn primary" type="button" disabled={act.busy} onClick={save}>Save draft</button>
    </PageHead>
    <Panel pad>
      <div className="grid-form">
        <Select label="Supplier" id="po-sup" value={form.supplier_id} onChange={v => setForm({ ...form, supplier_id: v })} options={data.suppliers.map(s => [s.id, s.name])} />
        <Field label="Order date" id="po-date" type="date" value={form.order_date} onChange={v => setForm({ ...form, order_date: v })} required />
        <Field label="Delivery expected" id="po-exp" type="date" value={form.expected_date} onChange={v => setForm({ ...form, expected_date: v })} />
        <Select label="Deliver to" id="po-deliver" value={form.deliver} onChange={v => setForm({ ...form, deliver: v })} options={[['store', 'One of our stores'], ['project', 'Straight to a project site']]} />
        {form.deliver === 'store'
          ? <Select label="Store" id="po-wh" value={form.warehouse_id} onChange={v => setForm({ ...form, warehouse_id: v })} options={data.warehouses.map(w => [w.id, `${w.code} · ${w.name}`])} />
          : <Select label="Project" id="po-proj" value={form.project_id} onChange={v => setForm({ ...form, project_id: v })} options={[['', 'Choose…'], ...data.projects.map(p => [p.id, `${p.number || ''} ${p.name}`] as [string, string])]} />}
        <Select label="Currency" id="po-cur" value={cur} onChange={v => setForm({ ...form, currency: v, exchange_rate: String(v === 'GHS' ? 1 : data.currencies.find(c => c.code === v)?.rate || '') })}
          options={[['GHS', 'GH₵ Ghana cedi'], ...data.currencies.map(c => [c.code, `${c.code} ${c.name}`] as [string, string])]} />
        {fx && <Field label={`GH₵ per 1 ${cur}`} id="po-rate" type="number" step="0.000001" min="0.000001" value={form.exchange_rate} onChange={v => setForm({ ...form, exchange_rate: v })} required />}
        {data.branches.length > 0 && <Select label="Branch" id="po-br" value={form.branch_id} onChange={v => setForm({ ...form, branch_id: v })} options={[['', '—'], ...data.branches.map(b => [b.id, `${b.code} ${b.name}`] as [string, string])]} />}
      </div>
    </Panel>
    <Panel title="Lines">
      <div className="scroll"><table className="lines">
        <thead><tr><th>Item or expense</th><th>Description</th><th className="r">Qty</th><th className="r">Unit price ({fx ? cur : 'GH₵'})</th><th>VAT</th>{form.deliver === 'store' && data.projects.length > 0 && <th>For project</th>}<th className="r">Amount</th><th></th></tr></thead>
        <tbody>{lines.map((l, i) => <tr key={i}>
          <td><select aria-label="Item or expense account" value={l.target} onChange={e => pick(i, e.target.value)} style={{ minWidth: 180 }}>
            <option value="">{project ? 'Project materials (5200)' : 'Choose…'}</option>
            <optgroup label="Items">{data.products.map(p => <option key={p.id} value={'p:' + p.id}>{p.sku} · {p.name}{p.item_type !== 'stock' ? ' (not stocked)' : ''}</option>)}</optgroup>
            <optgroup label="Expense or asset account">{data.accounts.map(a => <option key={a.id} value={'a:' + a.id}>{a.code} {a.name}</option>)}</optgroup></select></td>
          <td style={{ minWidth: 200 }}><input aria-label="Description" value={l.description} onChange={e => setLine(i, { description: e.target.value })} /></td>
          <td><input aria-label="Quantity" type="number" step="0.001" min="0" value={l.qty} onChange={e => setLine(i, { qty: e.target.value })} style={{ width: 90, textAlign: 'right' }} /></td>
          <td><input aria-label="Unit price" type="number" step="0.01" min="0" value={l.unit_cost} onChange={e => setLine(i, { unit_cost: e.target.value })} style={{ width: 110, textAlign: 'right' }} /></td>
          <td><input aria-label="Supplier charges VAT" type="checkbox" checked={l.taxable} onChange={e => setLine(i, { taxable: e.target.checked })} /></td>
          {form.deliver === 'store' && data.projects.length > 0 && <td><select aria-label="For project" value={l.project_id} onChange={e => setLine(i, { project_id: e.target.value })} style={{ minWidth: 120 }}>
            <option value="">Stock</option>{data.projects.map(p => <option key={p.id} value={p.id}>{p.number} {p.name}</option>)}</select></td>}
          <td className="r num">{money(Number(l.qty) * Number(l.unit_cost) || 0)}</td>
          <td><button className="btn ghost small" type="button" disabled={lines.length < 2} onClick={() => setLines(lines.filter((_, j) => j !== i))}>Remove</button></td>
        </tr>)}</tbody></table></div>
      <div className="body actions" style={{ justifyContent: 'space-between' }}><button className="btn small" type="button" onClick={() => setLines([...lines, blankLine()])}>Add line</button>
        <span>Order value <b className="num">{fx ? `${cur} ${money(total)}` : cedis(total)}</b>{fx && <span className="muted"> = {cedis(total * rate)} at {rate}</span>} <span className="muted">+ VAT where charged</span></span></div>
    </Panel>
    <Panel pad>
      <Field label="Delivery and payment terms (printed on the order)" id="po-terms" type="textarea" value={form.terms} onChange={v => setForm({ ...form, terms: v })} placeholder="e.g. Deliver to site gate, 8am–4pm. Payment 30 days after delivery." />
      <Field label="Internal note" id="po-notes" value={form.notes} onChange={v => setForm({ ...form, notes: v })} />
      <p className="muted" style={{ margin: 0, fontSize: 13 }}>Stock items delivered to a store go into stock at the order price. Lines for a project, and anything delivered to a site, are charged to the project when received.</p>
    </Panel>
  </>;
}

// ---------------------------------------------------------------- One order
export function PoView() {
  const { id } = useParams();
  const { cid, company, can } = useSession();
  const nav = useNavigate();
  const act = useAction();
  const [recv, setRecv] = useState<any | null>(null);
  const [bill, setBill] = useState<any | null>(null);
  const { data, error, loading, reload } = useLoad(async () => {
    const po = await q<any>(supabase.from('purchase_orders').select('*, supplier:suppliers(*), project:projects(id,number,name,status,location,country), warehouse:warehouses(id,code,name,address)').eq('id', id).single() as any);
    const [lines, receipts, warehouses, billLines] = await Promise.all([
      q<any[]>(supabase.from('po_lines').select('*, product:products(sku,unit,item_type), project:projects(number,name)').eq('po_id', id).order('sort') as any),
      q<any[]>(supabase.from('goods_receipts').select('*, warehouse:warehouses(code,name), lines:goods_receipt_lines(qty,unit_cost,po_line_id)').eq('po_id', id).order('created_at') as any),
      q<any[]>(supabase.from('warehouses').select('id,code,name').eq('company_id', cid).eq('active', true).order('code') as any),
      can('accountant') ? q<any[]>(supabase.from('bill_lines').select('qty, bill:bills(id,number,status,bill_date,supplier_ref), po_line:po_lines!inner(po_id)').eq('po_line.po_id', id) as any).catch(() => [] as any[]) : Promise.resolve([] as any[]),
    ]);
    const bills = Object.values(Object.fromEntries(billLines.filter(b => b.bill).map(b => [b.bill.id, b.bill]))) as any[];
    return { po, lines, receipts, warehouses, bills };
  }, [id, cid]);
  if (!data) return <Loading error={error} loading={loading} />;
  const { po, lines, receipts, warehouses, bills } = data;
  const open = ['approved', 'sent', 'partial'].includes(po.status);
  const total = poTotal(lines);
  const unbilledRecv = lines.some(l => Number(l.received_qty) > Number(l.billed_qty));
  const unbilledAny = lines.some(l => Number(l.qty) > Number(l.billed_qty));
  const deliverTo = po.project ? `Project site: ${po.project.number || ''} ${po.project.name}` : po.warehouse ? `${po.warehouse.name} (${po.warehouse.code})` : '';
  const pfx = po.currency && po.currency !== 'GHS';
  const pdf = () => purchaseOrderPdf({ company: company!, po, supplier: po.supplier, lines, deliverTo, site: [po.project?.location, po.project?.country].filter(Boolean).join(', ') || null });
  const setStatus = (s: string, msg: string) => act.run(async () => { await rpc('set_po_status', { p_po: id, p_status: s }); reload(); }, msg);

  return <>
    <PageHead title={po.number} sub={<><PoStatus s={po.status} /> <span className="muted">· {po.supplier?.name} · ordered {longDate(po.order_date)}{po.expected_date ? ' · due ' + longDate(po.expected_date) : ''} · {deliverTo}</span></>}>
      <Link className="btn" to="/purchase-orders">Back</Link>
      <button className="btn" type="button" onClick={pdf}>Order PDF</button>
      {po.status === 'draft' && <Link className="btn" to={`/purchase-orders/${id}/edit`}>Edit</Link>}
      {po.status === 'draft' && can('accountant') && <button className="btn primary" type="button" disabled={act.busy} onClick={() => act.run(async () => { await rpc('approve_po', { p_po: id }); reload(); }, 'Order approved. Send it to the supplier.')}>Approve</button>}
      {po.status === 'approved' && can('accountant', 'store') && <button className="btn" type="button" onClick={() => { pdf(); setStatus('sent', 'Marked as sent'); }}>Download and mark sent</button>}
      {open && can('accountant', 'store') && <button className="btn primary" type="button" onClick={() => setRecv({ date: today(), warehouse: po.warehouse_id || warehouses[0]?.id || '', ref: '', qty: Object.fromEntries(lines.map(l => [l.id, String(Math.max(Number(l.qty) - Number(l.received_qty), 0))])) })}>Receive goods</button>}
      {!['draft', 'cancelled'].includes(po.status) && can('accountant') && unbilledAny && <button className="btn" type="button" onClick={() => setBill({ ref: '', date: today(), all: !unbilledRecv })}>Bill from order</button>}
      {open && can('accountant', 'store') && (lines.some(l => Number(l.received_qty) > 0)
        ? <ConfirmButton label="Close order" confirm="Close it? Nothing more will be delivered." onConfirm={() => setStatus('closed', 'Order closed')} />
        : <ConfirmButton label="Cancel order" confirm="Cancel this order?" onConfirm={() => setStatus('cancelled', 'Order cancelled')} />)}
      {po.status === 'draft' && <ConfirmButton className="btn ghost" label="Delete" confirm="Delete this draft?" onConfirm={() => act.run(async () => { await q(supabase.from('purchase_orders').delete().eq('id', id) as any); nav('/purchase-orders'); }, 'Draft deleted')} />}
    </PageHead>
    {po.status === 'draft' && <ApprovalBox docType="purchase_order" docId={id!} onChange={reload} />}
    <div className="tiles">
      <div className="tile"><span>Order value (excl. VAT)</span><b>{pfx ? `${po.currency} ${money(lines.reduce((a, l) => a + Number(l.qty) * Number(l.unit_price_fx), 0))}` : cedis(total)}</b>{pfx && <span className="muted" style={{ fontSize: 12 }}>{cedis(total)} at {Number(po.exchange_rate)}</span>}</div>
      <div className="tile"><span>Received</span><b>{cedis(lines.reduce((a, l) => a + Number(l.received_qty) * Number(l.unit_cost), 0))}</b></div>
      <div className="tile"><span>Still to come</span><b>{cedis(lines.reduce((a, l) => a + Math.max(Number(l.qty) - Number(l.received_qty), 0) * Number(l.unit_cost), 0))}</b></div>
      <div className="tile"><span>Received, not yet billed</span><b>{cedis(lines.reduce((a, l) => a + Math.max(Number(l.received_qty) - Number(l.billed_qty), 0) * Number(l.unit_cost), 0))}</b></div>
    </div>
    <Panel title="What was ordered"><div className="scroll"><table>
      <thead><tr><th>Item</th><th className="r">Ordered</th><th className="r">Received</th><th className="r">Billed</th><th className="r">Unit price</th><th className="r">Amount ({pfx ? po.currency : 'GH₵'})</th></tr></thead>
      <tbody>{lines.map(l => <tr key={l.id}>
        <td className="wrap-cell">{l.product && <span className="muted num">{l.product.sku} · </span>}{l.description}{!l.taxable && <span className="pill" style={{ marginLeft: 6 }}>No VAT</span>}
          {l.project && <><br /><span className="muted" style={{ fontSize: 12 }}>For {l.project.number} {l.project.name}</span></>}</td>
        <td className="r num">{qty(l.qty)} {l.product?.unit || ''}</td>
        <td className="r num" style={{ color: Number(l.received_qty) >= Number(l.qty) ? 'var(--good)' : undefined }}>{qty(l.received_qty)}</td>
        <td className="r num">{qty(l.billed_qty)}</td><td className="r num">{pfx ? `${po.currency} ${money(l.unit_price_fx)}` : money(l.unit_cost)}</td><td className="r num">{pfx ? `${po.currency} ${money(Number(l.qty) * Number(l.unit_price_fx))}` : money(Number(l.qty) * Number(l.unit_cost))}</td></tr>)}</tbody>
      <tfoot><tr><td colSpan={5}>Total{pfx && <span className="muted" style={{ fontWeight: 400 }}> · GH₵ {money(total)} at {Number(po.exchange_rate)} (the order rate, used for stock and goods received)</span>}</td>
        <td className="r num">{pfx ? `${po.currency} ${money(lines.reduce((a, l) => a + Number(l.qty) * Number(l.unit_price_fx), 0))}` : money(total)}</td></tr></tfoot>
    </table></div>
      {(po.terms || po.notes) && <div className="body muted" style={{ fontSize: 13, whiteSpace: 'pre-wrap' }}>{[po.terms, po.notes].filter(Boolean).join('\n')}</div>}
    </Panel>
    <div className="two">
      <Panel title="Deliveries received">{receipts.length ? <div className="scroll"><table><tbody>{receipts.map(g => <tr key={g.id}>
        <td className="num"><b>{g.number}</b><br /><span className="muted" style={{ fontSize: 12 }}>{g.receipt_date}{g.reference ? ' · delivery note ' + g.reference : ''}</span></td>
        <td>{g.warehouse?.name || deliverTo}</td>
        <td className="r num">{money(g.lines.reduce((a: number, l: any) => a + Number(l.qty) * Number(l.unit_cost), 0))}</td>
        <td className="r"><button className="btn small" type="button" onClick={() => goodsReceivedPdf({ company: company!, grn: g, po, supplier: po.supplier, warehouse: g.warehouse?.name || deliverTo,
          lines: g.lines.map((x: any) => ({ ...x, description: lines.find(l => l.id === x.po_line_id)?.description || '' })) })}>GRN PDF</button></td></tr>)}</tbody></table></div>
        : <Empty>Nothing received yet.</Empty>}</Panel>
      {can('accountant') && <Panel title="Supplier bills">{bills.length ? <div className="scroll"><table><tbody>{bills.map(b => <tr key={b.id} className="click" onClick={() => nav(`/bills/${b.id}${b.status === 'draft' ? '/edit' : ''}`)}>
        <td className="num">{b.number || 'Draft'}</td><td className="num">{b.bill_date}</td><td>{b.supplier_ref}</td><td><Status s={b.status} kind="bill" /></td></tr>)}</tbody></table></div>
        : <Empty>Not billed yet. When the supplier's invoice arrives, use Bill from order: it fills in what was received at the order price{pfx ? ` in ${po.currency}, at the day's rate. The difference between that rate and the order rate goes to 4800 Foreign exchange gains and losses` : ''}; any difference in price is recorded as a price variance.</Empty>}</Panel>}
    </div>

    {recv && <FormModal title={`Receive goods on ${po.number}`} submit="Record delivery" busy={act.busy} onClose={() => setRecv(null)}
      onSave={() => act.run(async () => {
        const ls = lines.map(l => ({ line_id: l.id, qty: Number(recv.qty[l.id]) || 0 })).filter(l => l.qty > 0);
        if (!ls.length) throw new Error('Enter the quantity delivered on at least one line.');
        await rpc('receive_po', { p_po: id, p_lines: ls, p_date: recv.date, p_warehouse: po.project_id ? null : recv.warehouse || null, p_reference: recv.ref || null });
        setRecv(null); reload();
      }, 'Delivery recorded')}>
      <div className="grid-form">
        <Field label="Date received" id="rc-date" type="date" value={recv.date} onChange={v => setRecv({ ...recv, date: v })} required />
        {!po.project_id && <Select label="Into store" id="rc-wh" value={recv.warehouse} onChange={v => setRecv({ ...recv, warehouse: v })} options={warehouses.map(w => [w.id, `${w.code} · ${w.name}`])} />}
        <Field label="Supplier's delivery note / waybill no." id="rc-ref" value={recv.ref} onChange={v => setRecv({ ...recv, ref: v })} />
      </div>
      <div className="scroll"><table className="lines"><thead><tr><th>Item</th><th className="r">Outstanding</th><th className="r">Received now</th></tr></thead>
        <tbody>{lines.filter(l => Number(l.qty) > Number(l.received_qty)).map(l => <tr key={l.id}><td>{l.description}</td><td className="r num">{qty(Number(l.qty) - Number(l.received_qty))}</td>
          <td><input aria-label={'Quantity received: ' + l.description} type="number" step="0.001" min="0" max={Number(l.qty) - Number(l.received_qty)} value={recv.qty[l.id]}
            onChange={e => setRecv({ ...recv, qty: { ...recv.qty, [l.id]: e.target.value } })} style={{ width: 100, textAlign: 'right' }} /></td></tr>)}</tbody></table></div>
      <p className="muted" style={{ margin: 0, fontSize: 13 }}>Count what actually arrived and enter 0 for anything short or rejected. {po.project_id ? 'The goods are charged to the project straight away.' : 'Stock goes up in the store you choose.'} The value is held in Goods received not invoiced until the supplier's bill is posted.</p>
    </FormModal>}
    {bill && <FormModal title={`Bill from ${po.number}`} submit="Create draft bill" busy={act.busy} onClose={() => setBill(null)}
      onSave={() => act.run(async () => { const b = await rpc<string>('bill_from_po', { p_po: id, p_ref: bill.ref || null, p_date: bill.date, p_all: bill.all }); nav(`/bills/${b}/edit`); }, 'Draft bill created. Check it against the supplier invoice, then post.')}>
      <div className="grid-form">
        <Field label="Supplier's invoice no." id="bf-ref" value={bill.ref} onChange={v => setBill({ ...bill, ref: v })} />
        <Field label="Invoice date" id="bf-date" type="date" value={bill.date} onChange={v => setBill({ ...bill, date: v })} required />
      </div>
      <label className="check"><input type="checkbox" checked={bill.all} onChange={e => setBill({ ...bill, all: e.target.checked })} /> Include items not yet received (for services, or when you pay before delivery)</label>
      <p className="muted" style={{ margin: 0, fontSize: 13 }}>The bill lists what was received and not yet billed, at the order price. If the supplier charges a different price, change it on the bill: the difference goes to 5150 Purchase price variance (and to the project, for project lines). For an order in another currency the bill is in that currency at today's rate; the rate difference goes to 4800 Foreign exchange gains and losses.</p>
    </FormModal>}
  </>;
}

// ---------------------------------------------------------------- Supplier 360
export function Supplier360() {
  const { id } = useParams();
  const { cid, company, can } = useSession();
  const nav = useNavigate();
  const act = useAction();
  const [edit, setEdit] = useState<any | null>(null);
  const [price, setPrice] = useState<any | null>(null);
  const { data, error, loading, reload } = useLoad(async () => {
    const [s, k, orders, items, products] = await Promise.all([
      q<any>(supabase.from('suppliers').select('*').eq('id', id).single() as any),
      rpc<any>('supplier_summary', { p_supplier: id }),
      q<any[]>(supabase.from('purchase_orders').select('id,number,order_date,expected_date,status, lines:po_lines(qty,unit_cost,received_qty)').eq('supplier_id', id).order('order_date', { ascending: false }).limit(50) as any),
      q<any[]>(supabase.from('supplier_items').select('*, product:products(sku,name,unit,cost,last_purchase_cost)').eq('supplier_id', id) as any),
      q<any[]>(supabase.from('products').select('id,sku,name,cost').eq('company_id', cid).eq('active', true).neq('item_type', 'service').order('name') as any),
    ]);
    const bills = can('accountant') ? await q<any[]>(supabase.from('bills').select('id,number,bill_date,due_date,total,amount_paid,currency,exchange_rate,status,supplier_ref').eq('supplier_id', id).order('bill_date', { ascending: false }).limit(50) as any) : [];
    return { s, k: k || {}, orders, items, products, bills };
  }, [id, cid]);
  if (!data) return <Loading error={error} loading={loading} />;
  const { s, k, orders, items, products, bills } = data;
  const statement = () => act.run(async () => {
    const [docs, pays] = await Promise.all([
      q<any[]>(supabase.from('bills').select('*').eq('supplier_id', id).neq('status', 'draft') as any),
      q<any[]>(supabase.from('bill_payments').select('*, doc:bills!inner(supplier_id,exchange_rate)').eq('doc.supplier_id', id) as any),
    ]);
    statementPdf({ company: company!, party: s, kind: 'supplier', docs, payments: pays });
  });
  const saveSupplier = () => act.run(async () => {
    const row = { name: edit.name, phone: edit.phone || null, email: edit.email || null, tin: edit.tin || null, address: edit.address || null, city: edit.city || null,
      contact_name: edit.contact_name || null, category: edit.category || null, payment_terms_days: Number(edit.payment_terms_days) || 0, bank_name: edit.bank_name || null,
      bank_account: edit.bank_account || null, momo_number: edit.momo_number || null, notes: edit.notes || null, active: !!edit.active };
    await q(supabase.from('suppliers').update(row).eq('id', id) as any); setEdit(null); reload();
  }, 'Supplier saved');

  return <>
    <PageHead title={s.name} sub={<span className="muted">{[s.category, s.contact_name, s.phone, s.email, s.city, s.tin ? 'TIN ' + s.tin : null].filter(Boolean).join(' · ')}{!s.active && ' · inactive'}</span>}>
      <Link className="btn" to="/suppliers">Back</Link>
      {can('accountant') && <button className="btn" type="button" onClick={statement}>Statement PDF</button>}
      <button className="btn" type="button" onClick={() => setEdit(Object.fromEntries(Object.entries(s).map(([kk, v]) => [kk, v ?? ''])))}>Edit</button>
      {can('accountant', 'store', 'project_manager') && <Link className="btn primary" to={`/purchase-orders/new?supplier=${id}`}>New purchase order</Link>}
    </PageHead>
    <div className="tiles">
      {can('accountant') && <div className="tile"><span>We owe</span><b>{cedis(k.balance)}</b>{Number(k.overdue) > 0 && <span style={{ color: 'var(--bad)', fontSize: 12 }}>{cedis(k.overdue)} overdue</span>}</div>}
      {can('accountant') && <div className="tile"><span>Bought in the last 12 months</span><b>{cedis(k.spend_12m)}</b></div>}
      <div className="tile"><span>Open orders</span><b>{k.open_orders || 0}</b><span className="muted" style={{ fontSize: 12 }}>{cedis(k.open_order_value)} still to come</span></div>
      <div className="tile"><span>Delivered on time</span><b>{k.on_time_pct != null ? k.on_time_pct + '%' : '—'}</b><span className="muted" style={{ fontSize: 12 }}>{k.deliveries || 0} deliveries{k.avg_lead_days != null ? ` · ${k.avg_lead_days} days on average` : ''}</span></div>
    </div>
    <div className="two">
      <Panel title="Purchase orders">{orders.length ? <div className="scroll"><table><tbody>{orders.map(o => <tr key={o.id} className="click" onClick={() => nav('/purchase-orders/' + o.id)}>
        <td className="num">{o.number}</td><td className="num">{o.order_date}</td><td className="r num">{money(poTotal(o.lines))}</td><td><PoStatus s={o.status} /></td></tr>)}</tbody></table></div>
        : <Empty>No orders yet.</Empty>}</Panel>
      <Panel title="Price list (GH₵, excl. VAT)" actions={can('accountant', 'store') && <button className="btn small primary" type="button" onClick={() => setPrice({ product_id: products[0]?.id || '', price: '', supplier_sku: '', lead_days: '', min_qty: '' })}>Add item</button>}>
        {items.length ? <div className="scroll"><table><thead><tr><th>Item</th><th className="r">Price</th><th className="r">Lead time</th><th></th></tr></thead>
          <tbody>{items.map(i => <tr key={i.id}><td>{i.product?.name}{i.supplier_sku && <span className="muted"> · their code {i.supplier_sku}</span>}</td>
            <td className="r num">{money(i.price)}{i.product?.last_purchase_cost != null && Number(i.product.last_purchase_cost) !== Number(i.price) && <><br /><span className="muted" style={{ fontSize: 12 }}>last paid {money(i.product.last_purchase_cost)}</span></>}</td>
            <td className="r num">{i.lead_days != null ? i.lead_days + ' days' : ''}</td>
            <td className="r">{can('accountant', 'store') && <button className="btn small ghost" type="button" onClick={() => setPrice({ ...i, price: String(i.price), supplier_sku: i.supplier_sku || '', lead_days: i.lead_days ?? '', min_qty: i.min_qty ?? '' })}>Edit</button>}</td></tr>)}</tbody></table></div>
          : <Empty>No agreed prices. Add the items you buy from this supplier so new purchase orders fill in the right price.</Empty>}
      </Panel>
    </div>
    {can('accountant') && <Panel title="Bills">{bills.length ? <div className="scroll"><table>
      <thead><tr><th>Bill</th><th>Their invoice</th><th>Date</th><th>Due</th><th className="r">Total</th><th className="r">Owed</th><th>Status</th></tr></thead>
      <tbody>{bills.map(b => <tr key={b.id} className="click" onClick={() => nav(`/bills/${b.id}${b.status === 'draft' ? '/edit' : ''}`)}>
        <td className="num">{b.number || 'Draft'}</td><td>{b.supplier_ref}</td><td className="num">{b.bill_date}</td><td className="num">{b.due_date}</td>
        <td className="r num">{b.currency !== 'GHS' ? b.currency + ' ' : ''}{money(b.total)}</td><td className="r num">{money(Number(b.total) - Number(b.amount_paid))}</td><td><Status s={b.status} kind="bill" /></td></tr>)}</tbody>
    </table></div> : <Empty>No bills yet.</Empty>}</Panel>}
    {(s.bank_name || s.momo_number || s.notes) && <div className="note">{[s.bank_name && `Bank: ${s.bank_name} ${s.bank_account || ''}`, s.momo_number && `MoMo: ${s.momo_number}`, `Pays at ${s.payment_terms_days} days`, s.notes].filter(Boolean).join(' · ')}</div>}

    {edit && <FormModal title="Edit supplier" busy={act.busy} onClose={() => setEdit(null)} onSave={saveSupplier}>
      <Field label="Business name" id="su-name" value={edit.name} onChange={v => setEdit({ ...edit, name: v })} required />
      <div className="grid-form">
        <Field label="Contact person" id="su-contact" value={edit.contact_name} onChange={v => setEdit({ ...edit, contact_name: v })} />
        <Field label="What they supply" id="su-cat" value={edit.category} onChange={v => setEdit({ ...edit, category: v })} placeholder="e.g. Building materials" />
        <Field label="Phone" id="su-phone" value={edit.phone} onChange={v => setEdit({ ...edit, phone: v })} />
        <Field label="Email" id="su-email" type="email" value={edit.email} onChange={v => setEdit({ ...edit, email: v })} />
        <Field label="TIN" id="su-tin" value={edit.tin} onChange={v => setEdit({ ...edit, tin: v })} />
        <Field label="Town or city" id="su-city" value={edit.city} onChange={v => setEdit({ ...edit, city: v })} />
        <Field label="Payment terms (days)" id="su-terms" type="number" step="1" min="0" value={edit.payment_terms_days} onChange={v => setEdit({ ...edit, payment_terms_days: v })} />
        <Field label="Bank" id="su-bank" value={edit.bank_name} onChange={v => setEdit({ ...edit, bank_name: v })} />
        <Field label="Bank account no." id="su-acct" value={edit.bank_account} onChange={v => setEdit({ ...edit, bank_account: v })} />
        <Field label="MoMo number" id="su-momo" value={edit.momo_number} onChange={v => setEdit({ ...edit, momo_number: v })} />
      </div>
      <Field label="Address" id="su-addr" value={edit.address} onChange={v => setEdit({ ...edit, address: v })} />
      <Field label="Notes" id="su-notes" type="textarea" value={edit.notes} onChange={v => setEdit({ ...edit, notes: v })} />
      <label className="check"><input type="checkbox" checked={!!edit.active} onChange={e => setEdit({ ...edit, active: e.target.checked })} /> Active</label>
    </FormModal>}
    {price && <FormModal title={price.id ? 'Edit price' : 'Add to price list'} busy={act.busy} onClose={() => setPrice(null)}
      danger={price.id && <ConfirmButton className="btn danger" label="Remove" confirm="Remove?" onConfirm={() => act.run(async () => { await q(supabase.from('supplier_items').delete().eq('id', price.id) as any); setPrice(null); reload(); })} />}
      onSave={() => act.run(async () => {
        const row = { price: Number(price.price) || 0, supplier_sku: price.supplier_sku || null, lead_days: price.lead_days === '' ? null : Number(price.lead_days), min_qty: price.min_qty === '' ? null : Number(price.min_qty) };
        if (price.id) await q(supabase.from('supplier_items').update(row).eq('id', price.id) as any);
        else await q(supabase.from('supplier_items').insert({ ...row, company_id: cid, supplier_id: id, product_id: price.product_id }) as any);
        setPrice(null); reload();
      }, 'Price saved')}>
      {!price.id && <Select label="Item" id="sp-prod" value={price.product_id} onChange={v => setPrice({ ...price, product_id: v })} options={products.map(p => [p.id, `${p.sku} · ${p.name}`])} />}
      <div className="grid-form">
        <Field label="Price (GH₵, excl. VAT)" id="sp-price" type="number" step="0.01" min="0" value={price.price} onChange={v => setPrice({ ...price, price: v })} required />
        <Field label="Their item code" id="sp-sku" value={price.supplier_sku} onChange={v => setPrice({ ...price, supplier_sku: v })} />
        <Field label="Lead time (days)" id="sp-lead" type="number" step="1" min="0" value={price.lead_days} onChange={v => setPrice({ ...price, lead_days: v })} />
        <Field label="Minimum order" id="sp-min" type="number" step="0.001" min="0" value={price.min_qty} onChange={v => setPrice({ ...price, min_qty: v })} />
      </div>
    </FormModal>}
  </>;
}
