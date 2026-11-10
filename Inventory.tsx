import { useEffect, useState } from 'react';
import { Link, useNavigate, useParams, useSearchParams } from 'react-router-dom';
import { q, qPage, rpc, supabase } from '../lib/supabase';
import { useSession } from '../lib/session';
import { cedis, longDate, money, qty, today } from '../lib/format';
import { downloadCsv } from '../lib/download';
import { stockIssuePdf, tablePdf } from '../lib/pdf';
import { ConfirmButton, Downloads, Empty, Field, FormModal, Loading, PageHead, Panel, Select, useAction, useLoad } from '../components/ui';
import { Pager, SearchBox, usePaged } from '../components/paging';

export const ITEM_TYPES: [string, string][] = [['stock', 'Stock item (we keep it in a store)'], ['non_stock', 'Bought for use, not kept in stock'], ['service', 'Service']];
const typeName = (t: string) => ({ stock: 'Stock', non_stock: 'Not stocked', service: 'Service' } as Record<string, string>)[t] || t;

function useWarehouses(cid: string) {
  return useLoad(() => q<any[]>(supabase.from('warehouses').select('*').eq('company_id', cid).order('code') as any), [cid]);
}
const Tabs = <T extends string>({ value, onChange, tabs }: { value: T; onChange: (t: T) => void; tabs: [T, string][] }) =>
  <div className="actions" style={{ overflowX: 'auto', flexWrap: 'nowrap' }}>{tabs.map(([t, l]) => <button key={t} type="button" className={'btn small' + (value === t ? ' primary' : '')} onClick={() => onChange(t)}>{l}</button>)}</div>;

// ---------------------------------------------------------------- Items, stock levels, reorder, valuation
type InvTab = 'items' | 'levels' | 'reorder' | 'valuation';
export function InventoryPage() {
  const { cid, company, can } = useSession();
  const nav = useNavigate();
  const [sp, setSp] = useSearchParams();
  const tab = (sp.get('tab') as InvTab) || 'items';
  const setTab = (t: InvTab) => setSp(t === 'items' ? {} : { tab: t }, { replace: true });
  const act = useAction();
  const [search, setSearch] = useState('');
  const [category, setCategory] = useState('');
  const [wh, setWh] = useState('');
  const [edit, setEdit] = useState<any | null>(null);
  const [adjust, setAdjust] = useState<any | null>(null);
  const [picked, setPicked] = useState<Record<string, string>>({});
  const { data: whs } = useWarehouses(cid);
  const { data: meta, reload: reloadMeta } = useLoad(async () => {
    const [cats, suppliers, accounts] = await Promise.all([
      q<any[]>(supabase.from('products').select('category').eq('company_id', cid).not('category', 'is', null) as any),
      q<any[]>(supabase.from('suppliers').select('id,name').eq('company_id', cid).order('name') as any),
      q<any[]>(supabase.from('accounts').select('id,code,name').eq('company_id', cid).eq('type', 'expense').eq('active', true).order('code') as any).catch(() => [] as any[]),
    ]);
    return { cats: Array.from(new Set(cats.map(c => c.category))).sort() as string[], suppliers, accounts };
  }, [cid]);
  const pg = usePaged(async (a, b) => {
    let x = supabase.from('products').select('*, levels:stock_levels(warehouse_id,qty), supplier:suppliers(name)', { count: 'exact' }).eq('company_id', cid).order('name');
    if (search) x = x.or(`name.ilike.%${search}%,sku.ilike.%${search}%,barcode.eq.${search},brand.ilike.%${search}%`, {});
    if (category) x = x.eq('category', category);
    return qPage(x.range(a, b) as any);
  }, [cid, search, category, tab]);
  const val = useLoad(async () => tab === 'valuation' || tab === 'levels' ? rpc<any[]>('stock_valuation', { cid, p_warehouse: wh || null }) : null, [cid, wh, tab]);
  const ro = useLoad(async () => tab === 'reorder' ? rpc<any[]>('reorder_suggestions', { cid, p_warehouse: wh || null }) : null, [cid, wh, tab]);

  const save = () => act.run(async () => {
    const row: any = { sku: edit.sku, name: edit.name, unit: edit.unit || 'each', price: Number(edit.price) || 0, reorder_level: Number(edit.reorder_level) || 0, reorder_qty: Number(edit.reorder_qty) || 0,
      max_level: edit.max_level === '' ? null : Number(edit.max_level), taxable: edit.taxable, active: edit.active, item_type: edit.item_type, category: edit.category || null, barcode: edit.barcode || null,
      brand: edit.brand || null, description: edit.description || null, preferred_supplier_id: edit.preferred_supplier_id || null, expense_account_id: edit.item_type !== 'stock' ? edit.expense_account_id || null : null };
    if (edit.id) await q(supabase.from('products').update(row).eq('id', edit.id) as any);
    else await q(supabase.from('products').insert({ ...row, cost: Number(edit.cost) || 0, company_id: cid }) as any);
    setEdit(null); pg.reload(); reloadMeta();
  }, 'Item saved');
  const saveAdjust = () => act.run(async () => {
    const n = Number(adjust.qty);
    if (!n) throw new Error('Enter a quantity other than zero.');
    await rpc('adjust_stock', { p_product: adjust.product.id, p_qty: adjust.direction === 'out' ? -Math.abs(n) : Math.abs(n), p_unit_cost: Number(adjust.cost) || 0, p_date: adjust.date, p_kind: adjust.kind, p_note: adjust.note || null });
    setAdjust(null); pg.reload();
  }, 'Stock updated and posted to the ledger');

  const whName = (w: string) => whs?.find(x => x.id === w)?.code || '';
  const vRows = (val.data || []).filter(r => Number(r.qty) !== 0 || tab === 'levels');
  const vTotal = vRows.reduce((a, r) => a + Number(r.value), 0);
  const vHead = ['SKU', 'Item', 'Category', 'Unit', 'Qty', 'Avg cost (GHS)', 'Value (GHS)', 'On order', 'Last movement'];
  const vBody = vRows.map(r => [r.sku, r.name, r.category || '', r.unit, qty(r.qty), money(r.cost), money(r.value), qty(r.on_order), r.last_move || '']);
  const reorder = ro.data || [];
  const orderSelected = () => {
    const sel = reorder.filter(r => picked[r.product_id]);
    if (!sel.length) return;
    const sup = sel[0].supplier_id;
    nav(`/purchase-orders/new?${sup ? 'supplier=' + sup + '&' : ''}items=${sel.map(r => `${r.product_id}:${picked[r.product_id]}`).join(',')}`);
  };

  return <>
    <PageHead title="Inventory" sub={whs ? `${whs.filter(w => w.active).length} store${whs.length === 1 ? '' : 's'} · ${pg.total} items` : undefined}>
      {tab === 'valuation' && <Downloads pdf={() => tablePdf({ company: company!, title: 'Stock valuation', subtitle: `${wh ? whs?.find(w => w.id === wh)?.name : 'All stores'} · ${longDate(today())}`, head: vHead, body: vBody,
        foot: ['', '', '', '', '', 'Total', money(vTotal), '', ''], rightAlign: [4, 5, 6, 7], landscape: true, filename: 'stock-valuation-' + today() })} csv={() => downloadCsv('stock-valuation-' + today(), vHead, vBody)} />}
      <Link className="btn" to="/inventory/warehouses">Stores</Link>
      {can('accountant', 'store') && <button className="btn primary" type="button" onClick={() => setEdit({ sku: '', name: '', item_type: 'stock', category: category || '', unit: 'each', price: '', cost: '', reorder_level: '', reorder_qty: '', max_level: '', taxable: true, active: true, barcode: '', brand: '', description: '', preferred_supplier_id: '', expense_account_id: '' })}>Add item</button>}
    </PageHead>
    <Tabs value={tab} onChange={setTab} tabs={[['items', 'Items'], ['levels', 'Stock by store'], ['reorder', 'Reorder list'], ['valuation', 'Valuation']]} />
    <div className="filters">
      {tab === 'items' && <><SearchBox value={search} onChange={setSearch} placeholder="Name, code, barcode or brand" id="inv-search" />
        {meta && meta.cats.length > 0 && <Select label="Category" id="inv-cat" value={category} onChange={setCategory} options={[['', 'All'], ...meta.cats.map(c => [c, c] as [string, string])]} />}</>}
      {tab !== 'items' && tab !== 'levels' && whs && whs.length > 1 && <Select label="Store" id="inv-wh" value={wh} onChange={setWh} options={[['', 'All stores'], ...whs.map(w => [w.id, `${w.code} · ${w.name}`] as [string, string])]} />}
    </div>

    {tab === 'items' && <><Loading error={pg.error} loading={pg.loading && !pg.data} />
      {pg.data && <Panel>{pg.rows.length ? <div className="scroll"><table>
        <thead><tr><th>Code</th><th>Item</th><th className="r">Price (GH₵)</th><th className="r">Avg cost</th><th className="r">On hand</th>{whs && whs.length > 1 && <th>Where</th>}<th>Level</th><th></th></tr></thead>
        <tbody>{pg.rows.map(p => <tr key={p.id} style={p.active ? undefined : { opacity: .55 }}>
          <td className="num">{p.sku}{p.barcode && <><br /><span className="muted" style={{ fontSize: 11 }}>{p.barcode}</span></>}</td>
          <td><Link to={'/inventory/items/' + p.id} style={{ fontWeight: 600 }}>{p.name}</Link>{p.item_type !== 'stock' && <span className="pill" style={{ marginLeft: 6 }}>{typeName(p.item_type)}</span>}
            {!p.taxable && <span className="pill" style={{ marginLeft: 6 }}>VAT exempt</span>}
            {(p.category || p.brand) && <><br /><span className="muted" style={{ fontSize: 12 }}>{[p.category, p.brand].filter(Boolean).join(' · ')}</span></>}</td>
          <td className="r num">{money(p.price)}</td><td className="r num">{p.item_type === 'service' ? '' : money(p.cost)}</td>
          <td className="r num">{p.item_type === 'stock' ? `${qty(p.stock_qty)} ${p.unit}` : ''}</td>
          {whs && whs.length > 1 && <td className="muted" style={{ fontSize: 12 }}>{p.levels.filter((l: any) => Number(l.qty)).map((l: any) => `${whName(l.warehouse_id)} ${qty(l.qty)}`).join(' · ')}</td>}
          <td>{p.item_type !== 'stock' ? '' : Number(p.reorder_level) > 0 && Number(p.stock_qty) <= Number(p.reorder_level) ? <span className="pill bad">Reorder</span> : <span className="pill good">OK</span>}</td>
          <td className="r">{p.item_type === 'stock' && can('accountant') && <button className="btn small" type="button" onClick={() => setAdjust({ product: p, qty: '', cost: p.cost, direction: 'in', kind: Number(p.stock_qty) === 0 ? 'opening' : 'adjustment', date: today(), note: '' })}>Adjust</button>}</td>
        </tr>)}</tbody></table></div>
        : <Empty>{search || category ? 'No matches.' : 'No items yet. Add one, or import your item list from a spreadsheet, then enter opening quantities with Adjust.'}</Empty>}
        <Pager {...pg} noun="items" /></Panel>}</>}

    {tab === 'levels' && whs && <Panel>{val.data ? <LevelsGrid cid={cid} whs={whs.filter(w => w.active)} items={val.data} /> : <Loading loading />}</Panel>}

    {tab === 'reorder' && <Panel title="Items at or below their reorder level" actions={can('accountant', 'store', 'project_manager') && <button className="btn small primary" type="button" disabled={!Object.values(picked).some(Boolean)} onClick={orderSelected}>Purchase order for selected</button>}>
      {!ro.data ? <Loading loading /> : reorder.length ? <div className="scroll"><table>
        <thead><tr><th style={{ width: 28 }}></th><th>Item</th><th className="r">On hand</th><th className="r">On order</th><th className="r">Reorder at</th><th>Supplier</th><th className="r">Order qty</th><th className="r">Est. cost</th></tr></thead>
        <tbody>{reorder.map(r => <tr key={r.product_id}>
          <td><input type="checkbox" aria-label={'Select ' + r.name} checked={!!picked[r.product_id]} onChange={e => setPicked({ ...picked, [r.product_id]: e.target.checked ? String(Number(r.suggested)) : '' })} /></td>
          <td><Link to={'/inventory/items/' + r.product_id}>{r.name}</Link><br /><span className="muted num" style={{ fontSize: 12 }}>{r.sku}</span></td>
          <td className="r num" style={{ color: Number(r.on_hand) <= 0 ? 'var(--bad)' : undefined }}>{qty(r.on_hand)} {r.unit}</td><td className="r num">{qty(r.on_order)}</td><td className="r num">{qty(r.reorder_level)}</td>
          <td>{meta?.suppliers.find(s => s.id === r.supplier_id)?.name || <span className="muted">Not set</span>}</td>
          <td className="r">{picked[r.product_id] ? <input aria-label={'Order quantity for ' + r.name} type="number" min="0" step="0.001" value={picked[r.product_id]} onChange={e => setPicked({ ...picked, [r.product_id]: e.target.value })} style={{ width: 90, textAlign: 'right' }} /> : <span className="num">{qty(r.suggested)}</span>}</td>
          <td className="r num">{money(Number(picked[r.product_id] || r.suggested) * Number(r.unit_cost || 0))}</td></tr>)}</tbody>
      </table></div> : <Empty>Nothing to reorder. Set a reorder level on each item to see it here when stock (plus anything already on order) falls to that level.</Empty>}
      <div className="body muted" style={{ fontSize: 13 }}>Suggested quantity is the item's reorder quantity, or enough to reach its maximum level (twice the reorder level if none is set). Pick items from the same supplier to put them on one order.</div>
    </Panel>}

    {tab === 'valuation' && <Panel>{!val.data ? <Loading loading /> : vRows.length ? <div className="scroll"><table>
      <thead><tr><th>Item</th><th className="r">Qty</th><th className="r">Avg cost (GH₵)</th><th className="r">Value (GH₵)</th><th className="r">On order</th><th>Last movement</th></tr></thead>
      <tbody>{vRows.map(r => <tr key={r.product_id}><td><Link to={'/inventory/items/' + r.product_id}>{r.name}</Link> <span className="muted num" style={{ fontSize: 12 }}>{r.sku}</span></td>
        <td className="r num">{qty(r.qty)} {r.unit}</td><td className="r num">{money(r.cost)}</td><td className="r num">{money(r.value)}</td><td className="r num">{Number(r.on_order) ? qty(r.on_order) : ''}</td>
        <td className="num" style={{ color: r.last_move && r.last_move < new Date(Date.now() - 180 * 864e5).toISOString().slice(0, 10) ? 'var(--warn)' : undefined }}>{r.last_move || '—'}</td></tr>)}</tbody>
      <tfoot><tr><td colSpan={3}>Total stock value</td><td className="r num">{money(vTotal)}</td><td colSpan={2}></td></tr></tfoot>
    </table></div> : <Empty>No stock on hand.</Empty>}
      <div className="body muted" style={{ fontSize: 13 }}>Average cost (weighted). Items with no movement for six months are highlighted as slow-moving. The total agrees with account 1300 Inventory; see General ledger → Books check.</div></Panel>}

    {edit && meta && <FormModal title={edit.id ? 'Edit item' : 'Add item'} onClose={() => setEdit(null)} onSave={save} busy={act.busy}>
      <ItemFields edit={edit} setEdit={setEdit} meta={meta} />
    </FormModal>}
    {adjust && <FormModal title={`Adjust stock: ${adjust.product.name}`} onClose={() => setAdjust(null)} onSave={saveAdjust} busy={act.busy} submit="Post adjustment">
      <p className="muted" style={{ margin: 0 }}>In stock now: {qty(adjust.product.stock_qty)} {adjust.product.unit}. Adjustments apply to the main store; use a stocktake for other stores.</p>
      <div className="grid-form">
        <Select label="Type" id="ad-kind" value={adjust.kind} onChange={v => setAdjust({ ...adjust, kind: v, direction: v === 'opening' ? 'in' : adjust.direction })}
          options={[['opening', 'Opening stock (credits opening balance equity)'], ['adjustment', 'Damage, loss or found stock']]} />
        {adjust.kind === 'adjustment' && <Select label="Direction" id="ad-dir" value={adjust.direction} onChange={v => setAdjust({ ...adjust, direction: v })} options={[['in', 'Add to stock'], ['out', 'Remove from stock']]} />}
        <Field label="Quantity" id="ad-qty" type="number" step="0.001" min="0" value={adjust.qty} onChange={v => setAdjust({ ...adjust, qty: v })} required />
        {adjust.direction === 'in' && <Field label="Unit cost (GH₵)" id="ad-cost" type="number" step="0.01" min="0" value={adjust.cost} onChange={v => setAdjust({ ...adjust, cost: v })} />}
        <Field label="Date" id="ad-date" type="date" value={adjust.date} onChange={v => setAdjust({ ...adjust, date: v })} required />
      </div>
      <Field label="Note" id="ad-note" value={adjust.note} onChange={v => setAdjust({ ...adjust, note: v })} placeholder="e.g. Water damage in store" />
    </FormModal>}
  </>;
}

function ItemFields({ edit, setEdit, meta }: { edit: any; setEdit: (e: any) => void; meta: { cats: string[]; suppliers: any[]; accounts: any[] } }) {
  const set = (k: string) => (v: any) => setEdit({ ...edit, [k]: v });
  return <>
    <div className="grid-form">
      <Field label="Code (SKU)" id="it-sku" value={edit.sku} onChange={set('sku')} required />
      <Select label="Type" id="it-type" value={edit.item_type} onChange={set('item_type')} options={ITEM_TYPES} />
    </div>
    <Field label="Name" id="it-name" value={edit.name} onChange={set('name')} required />
    <div className="grid-form">
      <div className="field"><label htmlFor="it-cat">Category</label><input id="it-cat" list="it-cats" value={edit.category || ''} onChange={e => set('category')(e.target.value)} placeholder="e.g. Building materials" />
        <datalist id="it-cats">{meta.cats.map(c => <option key={c} value={c} />)}</datalist></div>
      <Field label="Unit" id="it-unit" value={edit.unit} onChange={set('unit')} placeholder="each, bag, carton, kg, m" />
      <Field label="Barcode" id="it-bar" value={edit.barcode} onChange={set('barcode')} />
      <Field label="Brand" id="it-brand" value={edit.brand} onChange={set('brand')} />
      <Field label="Selling price (GH₵, excl. VAT)" id="it-price" type="number" step="0.01" min="0" value={edit.price} onChange={set('price')} />
      {!edit.id && edit.item_type !== 'service' && <Field label="Starting cost (GH₵)" id="it-cost" type="number" step="0.01" min="0" value={edit.cost} onChange={set('cost')} />}
      {edit.item_type === 'stock' && <>
        <Field label="Reorder when stock falls to" id="it-rl" type="number" step="1" min="0" value={edit.reorder_level} onChange={set('reorder_level')} />
        <Field label="Reorder quantity" id="it-rq" type="number" step="1" min="0" value={edit.reorder_qty} onChange={set('reorder_qty')} />
        <Field label="Maximum level" id="it-max" type="number" step="1" min="0" value={edit.max_level ?? ''} onChange={set('max_level')} /></>}
      {edit.item_type !== 'service' && <Select label="Usual supplier" id="it-sup" value={edit.preferred_supplier_id || ''} onChange={set('preferred_supplier_id')} options={[['', '—'], ...meta.suppliers.map(s => [s.id, s.name] as [string, string])]} />}
      {edit.item_type !== 'stock' && meta.accounts.length > 0 && <Select label="Expense account when bought" id="it-acct" value={edit.expense_account_id || ''} onChange={set('expense_account_id')} options={[['', '6900 General expenses (or project materials)'], ...meta.accounts.map(a => [a.id, `${a.code} ${a.name}`] as [string, string])]} />}
    </div>
    <Field label="Description" id="it-desc" type="textarea" value={edit.description} onChange={set('description')} />
    <label className="check"><input type="checkbox" checked={edit.taxable} onChange={e => set('taxable')(e.target.checked)} /> Charge VAT, NHIL and GETFund on sales</label>
    {edit.id && <label className="check"><input type="checkbox" checked={edit.active} onChange={e => set('active')(e.target.checked)} /> Active</label>}
  </>;
}

function LevelsGrid({ whs, items }: { cid: string; whs: any[]; items: any[] }) {
  const { cid } = useSession();
  const { data } = useLoad(() => q<any[]>(supabase.from('stock_levels').select('product_id,warehouse_id,qty,bin').eq('company_id', cid) as any), [cid]);
  if (!data) return <Loading loading />;
  const at = (p: string, w: string) => data.find(l => l.product_id === p && l.warehouse_id === w);
  const rows = items.filter(i => Number(i.qty) !== 0 || data.some(l => l.product_id === i.product_id && Number(l.qty)));
  const head = ['Item', ...whs.map(w => w.code), 'Total'];
  return <>{rows.length ? <div className="scroll"><table>
    <thead><tr><th>Item</th>{whs.map(w => <th key={w.id} className="r" title={w.name}>{w.code}</th>)}<th className="r">Total</th></tr></thead>
    <tbody>{rows.map(i => <tr key={i.product_id}><td><Link to={'/inventory/items/' + i.product_id}>{i.name}</Link> <span className="muted" style={{ fontSize: 12 }}>{i.unit}</span></td>
      {whs.map(w => { const l = at(i.product_id, w.id); return <td key={w.id} className="r num" style={{ color: l && Number(l.qty) < 0 ? 'var(--bad)' : undefined }}>{l && Number(l.qty) ? qty(l.qty) : <span className="muted">—</span>}{l?.bin && <><br /><span className="muted" style={{ fontSize: 11 }}>{l.bin}</span></>}</td>; })}
      <td className="r num"><b>{qty(i.qty)}</b></td></tr>)}</tbody>
  </table></div> : <Empty>No stock in any store.</Empty>}
    <div className="body"><button className="btn small" type="button" onClick={() => downloadCsv('stock-by-store-' + today(), head, rows.map(i => [i.name, ...whs.map(w => qty(at(i.product_id, w.id)?.qty || 0)), qty(i.qty)]))}>Download CSV</button></div></>;
}

// ---------------------------------------------------------------- One item: stock by store, stock ledger, suppliers
export function ItemView() {
  const { id } = useParams();
  const { cid, company, can } = useSession();
  const act = useAction();
  const [from, setFrom] = useState(today().slice(0, 5) + '01-01');
  const [to, setTo] = useState(today());
  const [wh, setWh] = useState('');
  const [edit, setEdit] = useState<any | null>(null);
  const { data: whs } = useWarehouses(cid);
  const { data, error, loading, reload } = useLoad(async () => {
    const [p, levels, prices, cats, suppliers, accounts] = await Promise.all([
      q<any>(supabase.from('products').select('*, supplier:suppliers(id,name)').eq('id', id).single() as any),
      q<any[]>(supabase.from('stock_levels').select('*').eq('product_id', id) as any),
      q<any[]>(supabase.from('supplier_items').select('*, supplier:suppliers(id,name)').eq('product_id', id).order('price') as any),
      q<any[]>(supabase.from('products').select('category').eq('company_id', cid).not('category', 'is', null) as any),
      q<any[]>(supabase.from('suppliers').select('id,name').eq('company_id', cid).order('name') as any),
      q<any[]>(supabase.from('accounts').select('id,code,name').eq('company_id', cid).eq('type', 'expense').eq('active', true).order('code') as any).catch(() => [] as any[]),
    ]);
    return { p, levels, prices, meta: { cats: Array.from(new Set(cats.map(c => c.category))).sort() as string[], suppliers, accounts } };
  }, [id, cid]);
  const led = useLoad(() => rpc<any[]>('stock_ledger', { cid, p_product: id, p_from: from, p_to: to, p_warehouse: wh || null }), [cid, id, from, to, wh]);
  if (!data) return <Loading error={error} loading={loading} />;
  const { p, levels, prices, meta } = data;
  const rows = led.data || [];
  const opening = rows[0]?.opening ?? 0;
  const head = ['Date', 'Store', 'What', 'Project', 'In', 'Out', 'Balance', 'Unit cost (GHS)', 'Value (GHS)'];
  const body = rows.map(r => [r.move_date, r.warehouse || '', r.reason || '', r.project || '', r.qty_in ? qty(r.qty_in) : '', r.qty_out ? qty(r.qty_out) : '', qty(r.balance), money(r.unit_cost), money(r.value)]);
  const refLink = (r: any) => r.ref_type === 'invoice' ? '/invoices/' + r.ref_id : r.ref_type === 'bill' ? '/bills/' + r.ref_id : r.ref_type === 'stock_issue' ? '/inventory/issues/' + r.ref_id
    : r.ref_type === 'stock_count' ? '/inventory/counts/' + r.ref_id : r.ref_type === 'transfer' ? '/inventory/transfers' : r.ref_type === 'credit_note' ? '/credit-notes/' + r.ref_id : null;
  return <>
    <PageHead title={p.name} sub={<span className="muted">{[p.sku, typeName(p.item_type), p.category, p.brand, p.barcode && 'barcode ' + p.barcode].filter(Boolean).join(' · ')}</span>}>
      <Link className="btn" to="/inventory">Back</Link>
      {can('accountant', 'store') && <button className="btn" type="button" onClick={() => setEdit(Object.fromEntries(Object.entries(p).map(([k, v]) => [k, v ?? ''])))}>Edit</button>}
      {can('accountant', 'store', 'project_manager') && p.item_type !== 'service' && <Link className="btn primary" to={`/purchase-orders/new?${p.preferred_supplier_id ? 'supplier=' + p.preferred_supplier_id + '&' : ''}items=${p.id}:${Number(p.reorder_qty) || 1}`}>Order more</Link>}
    </PageHead>
    <div className="tiles">
      <div className="tile"><span>On hand</span><b>{qty(p.stock_qty)} {p.unit}</b>{Number(p.reorder_level) > 0 && <span className="muted" style={{ fontSize: 12 }}>reorder at {qty(p.reorder_level)}</span>}</div>
      <div className="tile"><span>Average cost</span><b>{cedis(p.cost)}</b>{p.last_purchase_cost != null && <span className="muted" style={{ fontSize: 12 }}>last bought at {money(p.last_purchase_cost)}</span>}</div>
      <div className="tile"><span>Stock value</span><b>{cedis(Number(p.stock_qty) * Number(p.cost))}</b></div>
      <div className="tile"><span>Selling price</span><b>{cedis(p.price)}</b>{Number(p.cost) > 0 && Number(p.price) > 0 && <span className="muted" style={{ fontSize: 12 }}>margin {Math.round((1 - Number(p.cost) / Number(p.price)) * 100)}%</span>}</div>
    </div>
    <div className="two">
      <Panel title="In each store">{levels.filter(l => Number(l.qty)).length ? <div className="scroll"><table><tbody>{levels.filter(l => Number(l.qty)).map(l => { const w = whs?.find(x => x.id === l.warehouse_id);
        return <tr key={l.warehouse_id}><td>{w?.name} <span className="muted">{w?.code}</span></td>
          <td>{can('accountant', 'store') ? <input aria-label={'Bin or shelf in ' + (w?.name || '')} placeholder="Bin / shelf" defaultValue={l.bin || ''} style={{ width: 110 }}
            onBlur={e => e.target.value !== (l.bin || '') && act.run(async () => { await q(supabase.from('stock_levels').update({ bin: e.target.value || null }).eq('product_id', id).eq('warehouse_id', l.warehouse_id) as any); }, 'Bin saved')} /> : l.bin}</td>
          <td className="r num">{qty(l.qty)} {p.unit}</td></tr>; })}</tbody></table></div> : <Empty>None in stock.</Empty>}</Panel>
      <Panel title="Suppliers">{prices.length ? <div className="scroll"><table><tbody>{prices.map(s => <tr key={s.id}><td><Link to={'/suppliers/' + s.supplier?.id}>{s.supplier?.name}</Link>{s.supplier?.id === p.preferred_supplier_id && <span className="pill good" style={{ marginLeft: 6 }}>Usual</span>}</td>
        <td className="r num">{money(s.price)}</td><td className="r muted">{s.lead_days != null ? s.lead_days + ' days' : ''}</td></tr>)}</tbody></table></div>
        : <Empty>{p.supplier ? <>Usually bought from <Link to={'/suppliers/' + p.supplier.id}>{p.supplier.name}</Link>. Add agreed prices on the supplier's page.</> : 'No supplier prices yet.'}</Empty>}</Panel>
    </div>
    <Panel title="Stock card" actions={<Downloads pdf={() => tablePdf({ company: company!, title: `Stock card: ${p.name}`, subtitle: `${p.sku} · ${longDate(from)} to ${longDate(to)} · opening ${qty(opening)} ${p.unit}`, head, body, rightAlign: [4, 5, 6, 7, 8], landscape: true, filename: `stock-card-${p.sku}` })}
      csv={() => downloadCsv(`stock-card-${p.sku}`, head, body)} />}>
      <div className="body filters" style={{ borderBottom: '1px solid var(--line)' }}>
        <Field label="From" id="sl-from" type="date" value={from} onChange={setFrom} /><Field label="To" id="sl-to" type="date" value={to} onChange={setTo} />
        {whs && whs.length > 1 && <Select label="Store" id="sl-wh" value={wh} onChange={setWh} options={[['', 'All stores'], ...whs.map(w => [w.id, w.code] as [string, string])]} />}
      </div>
      {rows.length ? <div className="scroll"><table>
        <thead><tr><th>Date</th><th>Store</th><th>What</th><th className="r">In</th><th className="r">Out</th><th className="r">Balance</th><th className="r">Unit cost</th></tr></thead>
        <tbody><tr><td colSpan={5} className="muted">Opening balance</td><td className="r num">{qty(opening)}</td><td></td></tr>
          {rows.map(r => { const href = refLink(r); return <tr key={r.move_id}><td className="num">{r.move_date}</td><td>{r.warehouse}</td>
            <td>{href ? <Link to={href}>{r.reason}</Link> : r.reason}{r.project && <span className="muted"> · {r.project}</span>}</td>
            <td className="r num">{r.qty_in ? qty(r.qty_in) : ''}</td><td className="r num">{r.qty_out ? qty(r.qty_out) : ''}</td><td className="r num"><b>{qty(r.balance)}</b></td><td className="r num">{money(r.unit_cost)}</td></tr>; })}</tbody>
      </table></div> : <Empty>No movements in this period.</Empty>}
    </Panel>
    {edit && <FormModal title="Edit item" onClose={() => setEdit(null)} busy={act.busy} onSave={() => act.run(async () => {
      const row: any = { sku: edit.sku, name: edit.name, unit: edit.unit || 'each', price: Number(edit.price) || 0, reorder_level: Number(edit.reorder_level) || 0, reorder_qty: Number(edit.reorder_qty) || 0,
        max_level: edit.max_level === '' ? null : Number(edit.max_level), taxable: edit.taxable, active: edit.active, item_type: edit.item_type, category: edit.category || null, barcode: edit.barcode || null,
        brand: edit.brand || null, description: edit.description || null, preferred_supplier_id: edit.preferred_supplier_id || null, expense_account_id: edit.item_type !== 'stock' ? edit.expense_account_id || null : null };
      if (row.item_type !== 'stock' && Number(p.stock_qty) !== 0) throw new Error('This item has stock on hand. Bring it to zero (issue, sell or adjust) before changing its type.');
      await q(supabase.from('products').update(row).eq('id', id) as any); setEdit(null); reload(); }, 'Item saved')}>
      <ItemFields edit={edit} setEdit={setEdit} meta={meta} />
    </FormModal>}
  </>;
}

// ---------------------------------------------------------------- Stores
export function WarehousesPage() {
  const { cid, can } = useSession();
  const act = useAction();
  const [edit, setEdit] = useState<any | null>(null);
  const { data, error, loading, reload } = useLoad(async () => {
    const [whs, branches, projects, levels] = await Promise.all([
      q<any[]>(supabase.from('warehouses').select('*, branch:branches(code), project:projects(number,name)').eq('company_id', cid).order('code') as any),
      q<any[]>(supabase.from('branches').select('id,code,name').eq('company_id', cid).order('code') as any).catch(() => [] as any[]),
      q<any[]>(supabase.from('projects').select('id,number,name').eq('company_id', cid).eq('is_template', false).in('status', ['planned', 'active', 'on_hold']).order('name') as any),
      q<any[]>(supabase.from('stock_levels').select('warehouse_id,qty,product:products(cost)').eq('company_id', cid) as any),
    ]);
    return { whs, branches, projects, levels };
  }, [cid]);
  if (!data) return <Loading error={error} loading={loading} />;
  const value = (w: string) => data.levels.filter(l => l.warehouse_id === w).reduce((a, l) => a + Number(l.qty) * Number(l.product?.cost || 0), 0);
  return <>
    <PageHead title="Stores and sites" sub="Every place you keep stock: the main store, branch shops, project site stores, even a delivery van.">
      <Link className="btn" to="/inventory">Back</Link>
      {can('accountant', 'store') && <button className="btn primary" type="button" onClick={() => setEdit({ code: '', name: '', kind: 'store', address: '', branch_id: '', project_id: '', active: true })}>Add store</button>}
    </PageHead>
    <Panel><div className="scroll"><table>
      <thead><tr><th>Code</th><th>Name</th><th>Type</th><th>Branch or project</th><th className="r">Stock value (GH₵)</th><th></th></tr></thead>
      <tbody>{data.whs.map(w => <tr key={w.id} style={w.active ? undefined : { opacity: .55 }}><td className="num"><b>{w.code}</b></td><td>{w.name}{w.is_default && <span className="pill good" style={{ marginLeft: 6 }}>Default</span>}<br /><span className="muted" style={{ fontSize: 12 }}>{w.address}</span></td>
        <td>{({ store: 'Store', site: 'Project site', vehicle: 'Vehicle', shop: 'Shop' } as Record<string, string>)[w.kind]}</td>
        <td>{[w.branch?.code, w.project && `${w.project.number} ${w.project.name}`].filter(Boolean).join(' · ')}</td>
        <td className="r num">{money(value(w.id))}</td>
        <td className="r">{can('accountant', 'store') && <button className="btn small ghost" type="button" onClick={() => setEdit({ ...w, address: w.address || '', branch_id: w.branch_id || '', project_id: w.project_id || '' })}>Edit</button>}</td></tr>)}</tbody>
    </table></div></Panel>
    {edit && <FormModal title={edit.id ? 'Edit store' : 'Add store'} busy={act.busy} onClose={() => setEdit(null)} onSave={() => act.run(async () => {
      const row = { code: edit.code.trim().toUpperCase(), name: edit.name, kind: edit.kind, address: edit.address || null, branch_id: edit.branch_id || null, project_id: edit.project_id || null, active: !!edit.active };
      if (!edit.active && value(edit.id) !== 0) throw new Error('Move or count out the stock in this store before making it inactive.');
      if (edit.id) await q(supabase.from('warehouses').update(row).eq('id', edit.id) as any); else await q(supabase.from('warehouses').insert({ ...row, company_id: cid }) as any);
      setEdit(null); reload(); }, 'Store saved')}>
      <div className="grid-form">
        <Field label="Code" id="wh-code" value={edit.code} onChange={v => setEdit({ ...edit, code: v })} placeholder="e.g. KSI, SITE-AIR" required />
        <Select label="Type" id="wh-kind" value={edit.kind} onChange={v => setEdit({ ...edit, kind: v })} options={[['store', 'Store or warehouse'], ['shop', 'Shop'], ['site', 'Project site store'], ['vehicle', 'Vehicle']]} />
      </div>
      <Field label="Name" id="wh-name" value={edit.name} onChange={v => setEdit({ ...edit, name: v })} required />
      <Field label="Address or digital address" id="wh-addr" value={edit.address} onChange={v => setEdit({ ...edit, address: v })} />
      <div className="grid-form">
        {data.branches.length > 0 && <Select label="Branch" id="wh-br" value={edit.branch_id} onChange={v => setEdit({ ...edit, branch_id: v })} options={[['', '—'], ...data.branches.map(b => [b.id, `${b.code} ${b.name}`] as [string, string])]} />}
        {edit.kind === 'site' && <Select label="Project" id="wh-proj" value={edit.project_id} onChange={v => setEdit({ ...edit, project_id: v })} options={[['', '—'], ...data.projects.map(p => [p.id, `${p.number} ${p.name}`] as [string, string])]} />}
      </div>
      {edit.id && !edit.is_default && <label className="check"><input type="checkbox" checked={!!edit.active} onChange={e => setEdit({ ...edit, active: e.target.checked })} /> Active</label>}
      <p className="muted" style={{ margin: 0, fontSize: 13 }}>Stock sitting in a project site store is still yours (an asset). It becomes project cost only when issued to the project.</p>
    </FormModal>}
  </>;
}

// ---------------------------------------------------------------- Issue to project / return from project
export function StockIssueForm({ kind, projectId, onClose, onDone }: { kind: 'issue' | 'return'; projectId?: string; onClose: () => void; onDone: () => void }) {
  const { cid, can } = useSession();
  const act = useAction();
  const storeUser = can('accountant', 'store');
  const { data } = useLoad(async () => {
    const [whs, products, projects, levels, issued, tasks, usage] = await Promise.all([
      q<any[]>(supabase.from('warehouses').select('id,code,name,is_default,project_id').eq('company_id', cid).eq('active', true).order('code') as any),
      q<any[]>(supabase.from('products').select('id,sku,name,unit,price,cost').eq('company_id', cid).eq('item_type', 'stock').eq('active', true).order('name') as any),
      q<any[]>(supabase.from('projects').select('id,number,name,billing_type').eq('company_id', cid).eq('is_template', false).in('status', ['planned', 'active', 'on_hold', 'done']).order('name') as any),
      q<any[]>(supabase.from('stock_levels').select('product_id,warehouse_id,qty').eq('company_id', cid) as any),
      projectId && kind === 'return' ? q<any[]>(supabase.from('stock_issue_lines').select('product_id,qty,billable,bill_price, issue:stock_issues!inner(project_id,kind,status)').eq('issue.project_id', projectId).eq('issue.status', 'posted') as any) : Promise.resolve([] as any[]),
      projectId ? q<any[]>(supabase.from('tasks').select('id,title').eq('project_id', projectId).neq('status', 'done').order('sort') as any) : Promise.resolve([] as any[]),
      projectId ? rpc<any[]>('project_material_usage', { p_project: projectId }).catch(() => [] as any[]) : Promise.resolve([] as any[]),
    ]);
    return { whs: storeUser ? whs : whs.filter(w => projectId && w.project_id === projectId), products, projects, levels, issued, tasks, usage };
  }, [cid, projectId, kind]);
  const [f, setF] = useState<any>(null);
  useEffect(() => {
    if (!data || f) return;
    const site = data.whs.find(w => w.project_id === projectId);
    setF({ warehouse_id: site?.id || data.whs.find(w => w.is_default)?.id || data.whs[0]?.id || '', project_id: projectId || '', issue_date: today(), issued_to: '', notes: '', task_id: '',
      lines: [{ product_id: '', qty: '', billable: data.projects.find(p => p.id === projectId)?.billing_type === 'time_materials', bill_price: '' }] });
  }, [data]); // eslint-disable-line react-hooks/exhaustive-deps
  if (data && !data.whs.length) return <FormModal title="No site store" submit="Close" onClose={onClose} onSave={onClose}><p style={{ margin: 0 }}>This project has no site store yet. Ask the project manager to set one up on the Materials tab, or ask the store to issue the materials.</p></FormModal>;
  if (!data || !f) return null;
  const planOf = (pid: string) => data.usage.find(u => u.product_id === pid);
  const have = (pid: string) => Number(data.levels.find(l => l.product_id === pid && l.warehouse_id === f.warehouse_id)?.qty || 0);
  const net = (pid: string) => data.issued.filter(l => l.product_id === pid).reduce((a, l) => a + (l.issue.kind === 'issue' ? 1 : -1) * Number(l.qty), 0);
  const choices = kind === 'return' && projectId ? data.products.filter(p => net(p.id) > 0) : data.products.filter(p => have(p.id) > 0);
  const setLine = (i: number, patch: any) => setF({ ...f, lines: f.lines.map((l: any, j: number) => j === i ? { ...l, ...patch } : l) });
  const proj = data.projects.find(p => p.id === f.project_id);
  const save = (post: boolean) => act.run(async () => {
    const ls = f.lines.filter((l: any) => l.product_id && Number(l.qty) > 0);
    if (!ls.length) throw new Error('Add at least one item and quantity.');
    if (!f.project_id && !projectId) throw new Error('Choose the project.');
    const doc = await q<any>(supabase.from('stock_issues').insert({ company_id: cid, kind, warehouse_id: f.warehouse_id, project_id: f.project_id || null, issue_date: f.issue_date, issued_to: f.issued_to || null, notes: f.notes || null, task_id: f.task_id || null }).select('id').single() as any);
    await q(supabase.from('stock_issue_lines').insert(ls.map((l: any, i: number) => ({ issue_id: doc.id, company_id: cid, product_id: l.product_id, qty: Number(l.qty), billable: !!l.billable, bill_price: l.bill_price === '' ? null : Number(l.bill_price), sort: i }))) as any);
    if (post) await rpc('post_stock_issue', { p_id: doc.id });
    onDone();
  }, post ? (kind === 'issue' ? 'Stock issued and charged to the project' : 'Return booked back into stock') : 'Saved as a draft');
  return <FormModal title={kind === 'issue' ? 'Issue stock to a project' : 'Return stock from a project'} submit={kind === 'issue' ? 'Issue now' : 'Return now'} busy={act.busy} onClose={onClose} onSave={() => save(true)}
    danger={<button className="btn" type="button" disabled={act.busy} onClick={() => save(false)}>Save draft</button>}>
    <div className="grid-form">
      <Select label={kind === 'issue' ? 'From store' : 'Back into store'} id="si-wh" value={f.warehouse_id} onChange={v => setF({ ...f, warehouse_id: v })} options={data.whs.map(w => [w.id, `${w.code} · ${w.name}`])} />
      {!projectId && <Select label="Project" id="si-proj" value={f.project_id} onChange={v => setF({ ...f, project_id: v })} options={[['', 'Choose…'], ...data.projects.map(p => [p.id, `${p.number || ''} ${p.name}`] as [string, string])]} />}
      <Field label="Date" id="si-date" type="date" value={f.issue_date} onChange={v => setF({ ...f, issue_date: v })} required />
      <Field label={kind === 'issue' ? 'Collected by' : 'Returned by'} id="si-who" value={f.issued_to} onChange={v => setF({ ...f, issued_to: v })} placeholder="Name of foreman or driver" />
      {data.tasks.length > 0 && <Select label="Used for task" id="si-task" value={f.task_id} onChange={v => setF({ ...f, task_id: v })} options={[['', '—'], ...data.tasks.map(t => [t.id, t.title] as [string, string])]} />}
    </div>
    {kind === 'issue' && f.lines.some((l: any) => { const u = planOf(l.product_id); return u && u.planned != null && Number(u.used) + Number(l.qty || 0) > Number(u.planned); }) &&
      <div className="note" style={{ background: 'var(--warn-soft)' }}>Over the materials plan: {f.lines.filter((l: any) => { const u = planOf(l.product_id); return u && u.planned != null && Number(u.used) + Number(l.qty || 0) > Number(u.planned); })
        .map((l: any) => { const u = planOf(l.product_id)!; return `${u.name} (planned ${qty(u.planned)}, used ${qty(u.used)}, now ${qty(Number(u.used) + Number(l.qty))})`; }).join('; ')}. You can still issue it; the project manager sees it on the materials plan.</div>}
    <div className="scroll"><table className="lines"><thead><tr><th>Item</th><th className="r">{kind === 'issue' ? 'In store' : 'Issued (net)'}</th><th className="r">Qty</th>{proj?.billing_type !== 'non_billable' && <><th>Bill client</th><th className="r">Price to client</th></>}<th></th></tr></thead>
      <tbody>{f.lines.map((l: any, i: number) => { const p = data.products.find(x => x.id === l.product_id); return <tr key={i}>
        <td><select aria-label="Item" value={l.product_id} onChange={e => { const pp = data.products.find(x => x.id === e.target.value); const prev = data.issued.find(x => x.product_id === e.target.value);
          setLine(i, { product_id: e.target.value, bill_price: prev?.bill_price != null ? String(prev.bill_price) : pp ? String(pp.price) : '', billable: prev ? prev.billable : l.billable }); }} style={{ minWidth: 200 }}>
          <option value="">Choose…</option>{choices.map(x => <option key={x.id} value={x.id}>{x.sku} · {x.name}</option>)}</select></td>
        <td className="r num">{p ? `${qty(kind === 'issue' || !projectId ? have(p.id) : net(p.id))} ${p.unit}` : ''}</td>
        <td><input aria-label="Quantity" type="number" step="0.001" min="0" value={l.qty} onChange={e => setLine(i, { qty: e.target.value })} style={{ width: 90, textAlign: 'right' }} /></td>
        {proj?.billing_type !== 'non_billable' && <><td><input type="checkbox" aria-label="Bill to client" checked={!!l.billable} onChange={e => setLine(i, { billable: e.target.checked })} /></td>
          <td>{l.billable && <input aria-label="Price to client" type="number" step="0.01" min="0" value={l.bill_price} onChange={e => setLine(i, { bill_price: e.target.value })} style={{ width: 100, textAlign: 'right' }} />}</td></>}
        <td><button className="btn ghost small" type="button" disabled={f.lines.length < 2} onClick={() => setF({ ...f, lines: f.lines.filter((_: any, j: number) => j !== i) })}>Remove</button></td></tr>; })}</tbody></table></div>
    <div><button className="btn small" type="button" onClick={() => setF({ ...f, lines: [...f.lines, { product_id: '', qty: '', billable: f.lines[0]?.billable, bill_price: '' }] })}>Add item</button></div>
    <Field label="Note" id="si-note" value={f.notes} onChange={v => setF({ ...f, notes: v })} />
    <p className="muted" style={{ margin: 0, fontSize: 13 }}>{kind === 'issue'
      ? 'Stock leaves the store at average cost and is charged to the project as materials (5200). Ticked items are added to the client\'s next project invoice at the price shown.'
      : 'Unused materials go back into stock at average cost and come off the project\'s materials cost. A return also reduces what the client is billed.'}</p>
  </FormModal>;
}

export function StockIssuesPage() {
  const { cid, can } = useSession();
  const nav = useNavigate();
  const [form, setForm] = useState<'issue' | 'return' | null>(null);
  const [view, setView] = useState<'all' | 'draft'>('all');
  const pg = usePaged(async (a, b) => {
    let x = supabase.from('stock_issues').select('*, project:projects(number,name), warehouse:warehouses(code), lines:stock_issue_lines(qty,unit_cost)', { count: 'exact' }).eq('company_id', cid).order('issue_date', { ascending: false }).order('number', { ascending: false });
    if (view === 'draft') x = x.eq('status', 'draft');
    return qPage(x.range(a, b) as any);
  }, [cid, view]);
  return <>
    <PageHead title="Issues to projects" sub="Materials taken from a store for a project, and unused materials brought back.">
      {can('accountant', 'store', 'project_manager') && <><button className="btn" type="button" onClick={() => setForm('return')}>Return from project</button>
        <button className="btn primary" type="button" onClick={() => setForm('issue')}>Issue to project</button></>}
    </PageHead>
    <Tabs value={view} onChange={setView} tabs={[['all', 'All'], ['draft', 'Drafts']]} />
    <Loading error={pg.error} loading={pg.loading && !pg.data} />
    {pg.data && <Panel>{pg.rows.length ? <div className="scroll"><table>
      <thead><tr><th>No.</th><th>Date</th><th>Project</th><th>Store</th><th>Collected by</th><th className="r">Cost (GH₵)</th><th>Status</th></tr></thead>
      <tbody>{pg.rows.map(s => <tr key={s.id} className="click" onClick={() => nav('/inventory/issues/' + s.id)}><td className="num"><b>{s.number}</b>{s.kind === 'return' && <span className="pill warn" style={{ marginLeft: 6 }}>Return</span>}</td>
        <td className="num">{s.issue_date}</td><td>{s.project ? `${s.project.number || ''} ${s.project.name}` : '—'}</td><td>{s.warehouse?.code}</td><td>{s.issued_to}</td>
        <td className="r num">{s.status === 'posted' ? money(s.lines.reduce((a: number, l: any) => a + Number(l.qty) * Number(l.unit_cost || 0), 0)) : ''}</td>
        <td><span className={'pill ' + (s.status === 'posted' ? 'good' : '')}>{s.status === 'posted' ? 'Posted' : 'Draft'}</span></td></tr>)}</tbody>
    </table></div> : <Empty>Nothing issued yet. Issue materials from a store to a project so their cost lands on the project at the moment they are used.</Empty>}
      <Pager {...pg} noun="documents" /></Panel>}
    {form && <StockIssueForm kind={form} onClose={() => setForm(null)} onDone={() => { setForm(null); pg.reload(); }} />}
  </>;
}

export function StockIssueView() {
  const { id } = useParams();
  const { company } = useSession();
  const nav = useNavigate();
  const act = useAction();
  const { data, error, loading, reload } = useLoad(async () => {
    const s = await q<any>(supabase.from('stock_issues').select('*, project:projects(id,number,name), warehouse:warehouses(code,name)').eq('id', id).single() as any);
    const lines = await q<any[]>(supabase.from('stock_issue_lines').select('*, product:products(sku,name,unit,cost)').eq('issue_id', id).order('sort') as any);
    return { s, lines };
  }, [id]);
  if (!data) return <Loading error={error} loading={loading} />;
  const { s, lines } = data;
  const projName = s.project ? `${s.project.number || ''} ${s.project.name}` : '';
  return <>
    <PageHead title={s.number} sub={<span className="muted">{s.kind === 'return' ? 'Return from' : 'Issue to'} {projName || 'internal use'} · {s.warehouse?.name} · {longDate(s.issue_date)}{s.issued_to ? ' · ' + s.issued_to : ''}</span>}>
      <Link className="btn" to="/inventory/issues">Back</Link>
      {s.project && <Link className="btn" to={'/projects/' + s.project.id}>Project</Link>}
      <button className="btn" type="button" onClick={() => stockIssuePdf({ company: company!, doc: s, warehouse: s.warehouse?.name || '', project: projName, lines })}>Print note</button>
      {s.status === 'draft' && <><ConfirmButton className="btn ghost" label="Delete" confirm="Delete this draft?" onConfirm={() => act.run(async () => { await q(supabase.from('stock_issues').delete().eq('id', id) as any); nav('/inventory/issues'); }, 'Deleted')} />
        <button className="btn primary" type="button" disabled={act.busy} onClick={() => act.run(async () => { await rpc('post_stock_issue', { p_id: id }); reload(); }, 'Posted')}>Post</button></>}
    </PageHead>
    <Panel><div className="scroll"><table>
      <thead><tr><th>Item</th><th className="r">Qty</th><th className="r">Cost each (GH₵)</th><th className="r">Cost</th><th>Bill client</th><th className="r">Price to client</th></tr></thead>
      <tbody>{lines.map(l => <tr key={l.id}><td>{l.product?.name} <span className="muted num">{l.product?.sku}</span></td><td className="r num">{qty(l.qty)} {l.product?.unit}</td>
        <td className="r num">{money(l.unit_cost ?? l.product?.cost)}</td><td className="r num">{money(Number(l.qty) * Number(l.unit_cost ?? l.product?.cost))}</td>
        <td>{l.billable ? (l.invoice_id ? <Link to={'/invoices/' + l.invoice_id}>Invoiced</Link> : 'Yes, not yet invoiced') : 'No'}</td><td className="r num">{l.billable ? money(l.bill_price) : ''}</td></tr>)}</tbody>
    </table></div>{s.notes && <div className="body muted">{s.notes}</div>}</Panel>
  </>;
}

// ---------------------------------------------------------------- Transfers between stores
export function TransfersPage() {
  const { cid, can } = useSession();
  const act = useAction();
  const [f, setF] = useState<any | null>(null);
  const { data: whs } = useWarehouses(cid);
  const { data: products } = useLoad(() => q<any[]>(supabase.from('products').select('id,sku,name,unit').eq('company_id', cid).eq('item_type', 'stock').eq('active', true).order('name') as any), [cid]);
  const { data: levels } = useLoad(() => q<any[]>(supabase.from('stock_levels').select('product_id,warehouse_id,qty').eq('company_id', cid) as any), [cid, f === null]);
  const pg = usePaged(async (a, b) => qPage(supabase.from('stock_transfers').select('*, src:warehouses!stock_transfers_from_warehouse_id_fkey(code), dst:warehouses!stock_transfers_to_warehouse_id_fkey(code), lines:stock_transfer_lines(qty, product:products(name,unit))', { count: 'exact' })
    .eq('company_id', cid).order('transfer_date', { ascending: false }).order('number', { ascending: false }).range(a, b) as any), [cid]);
  const have = (pid: string) => Number(levels?.find(l => l.product_id === pid && l.warehouse_id === f?.from)?.qty || 0);
  const save = (post: boolean) => act.run(async () => {
    const ls = f.lines.filter((l: any) => l.product_id && Number(l.qty) > 0);
    if (!ls.length) throw new Error('Add at least one item and quantity.');
    if (f.from === f.to) throw new Error('Choose two different stores.');
    const t = await q<any>(supabase.from('stock_transfers').insert({ company_id: cid, from_warehouse_id: f.from, to_warehouse_id: f.to, transfer_date: f.date, notes: f.notes || null }).select('id').single() as any);
    await q(supabase.from('stock_transfer_lines').insert(ls.map((l: any) => ({ transfer_id: t.id, company_id: cid, product_id: l.product_id, qty: Number(l.qty) }))) as any);
    if (post) await rpc('post_transfer', { p_id: t.id });
    setF(null); pg.reload();
  }, post ? 'Stock moved' : 'Draft saved');
  return <>
    <PageHead title="Transfers between stores" sub="Moving stock does not change its value or the books; only where it is.">
      <Link className="btn" to="/inventory">Inventory</Link>
      {can('accountant', 'store') && whs && whs.length > 1 && <button className="btn primary" type="button" onClick={() => setF({ from: whs.find(w => w.is_default)?.id || whs[0].id, to: whs.find(w => !w.is_default)?.id || '', date: today(), notes: '', lines: [{ product_id: '', qty: '' }] })}>New transfer</button>}
    </PageHead>
    {whs && whs.length < 2 && <div className="note">You have one store. Add another under <Link to="/inventory/warehouses">Stores</Link> to move stock between them.</div>}
    <Loading error={pg.error} loading={pg.loading && !pg.data} />
    {pg.data && <Panel>{pg.rows.length ? <div className="scroll"><table>
      <thead><tr><th>No.</th><th>Date</th><th>From → to</th><th>Items</th><th>Status</th><th></th></tr></thead>
      <tbody>{pg.rows.map(t => <tr key={t.id}><td className="num">{t.number}</td><td className="num">{t.transfer_date}</td><td>{t.src?.code} → {t.dst?.code}</td>
        <td className="wrap-cell">{t.lines.map((l: any) => `${qty(l.qty)} ${l.product?.unit} ${l.product?.name}`).join(', ')}</td>
        <td><span className={'pill ' + (t.status === 'posted' ? 'good' : '')}>{t.status === 'posted' ? 'Moved' : 'Draft'}</span></td>
        <td className="r">{t.status === 'draft' && can('accountant', 'store') && <span className="actions" style={{ justifyContent: 'flex-end' }}>
          <ConfirmButton className="btn small ghost" label="Delete" confirm="Delete?" onConfirm={() => act.run(async () => { await q(supabase.from('stock_transfers').delete().eq('id', t.id) as any); pg.reload(); })} />
          <button className="btn small primary" type="button" onClick={() => act.run(async () => { await rpc('post_transfer', { p_id: t.id }); pg.reload(); }, 'Stock moved')}>Post</button></span>}</td></tr>)}</tbody>
    </table></div> : <Empty>No transfers yet.</Empty>}<Pager {...pg} noun="transfers" /></Panel>}
    {f && whs && products && <FormModal title="Move stock between stores" submit="Move now" busy={act.busy} onClose={() => setF(null)} onSave={() => save(true)}
      danger={<button className="btn" type="button" disabled={act.busy} onClick={() => save(false)}>Save draft</button>}>
      <div className="grid-form">
        <Select label="From" id="tr-from" value={f.from} onChange={v => setF({ ...f, from: v })} options={whs.filter(w => w.active).map(w => [w.id, `${w.code} · ${w.name}`])} />
        <Select label="To" id="tr-to" value={f.to} onChange={v => setF({ ...f, to: v })} options={[['', 'Choose…'], ...whs.filter(w => w.active && w.id !== f.from).map(w => [w.id, `${w.code} · ${w.name}`] as [string, string])]} />
        <Field label="Date" id="tr-date" type="date" value={f.date} onChange={v => setF({ ...f, date: v })} required />
      </div>
      <div className="scroll"><table className="lines"><thead><tr><th>Item</th><th className="r">Available</th><th className="r">Qty to move</th><th></th></tr></thead>
        <tbody>{f.lines.map((l: any, i: number) => <tr key={i}>
          <td><select aria-label="Item" value={l.product_id} onChange={e => setF({ ...f, lines: f.lines.map((x: any, j: number) => j === i ? { ...x, product_id: e.target.value } : x) })} style={{ minWidth: 200 }}>
            <option value="">Choose…</option>{products.filter(p => have(p.id) > 0).map(p => <option key={p.id} value={p.id}>{p.sku} · {p.name}</option>)}</select></td>
          <td className="r num">{l.product_id ? qty(have(l.product_id)) : ''}</td>
          <td><input aria-label="Quantity" type="number" step="0.001" min="0" value={l.qty} onChange={e => setF({ ...f, lines: f.lines.map((x: any, j: number) => j === i ? { ...x, qty: e.target.value } : x) })} style={{ width: 90, textAlign: 'right' }} /></td>
          <td><button className="btn ghost small" type="button" disabled={f.lines.length < 2} onClick={() => setF({ ...f, lines: f.lines.filter((_: any, j: number) => j !== i) })}>Remove</button></td></tr>)}</tbody></table></div>
      <div><button className="btn small" type="button" onClick={() => setF({ ...f, lines: [...f.lines, { product_id: '', qty: '' }] })}>Add item</button></div>
      <Field label="Note" id="tr-note" value={f.notes} onChange={v => setF({ ...f, notes: v })} placeholder="e.g. Truck GT 4471-22, driver Kofi" />
    </FormModal>}
  </>;
}

// ---------------------------------------------------------------- Stocktakes
export function StockCountsPage() {
  const { cid, can } = useSession();
  const nav = useNavigate();
  const act = useAction();
  const [f, setF] = useState<any | null>(null);
  const { data: whs } = useWarehouses(cid);
  const { data: cats } = useLoad(async () => Array.from(new Set((await q<any[]>(supabase.from('products').select('category').eq('company_id', cid).not('category', 'is', null) as any)).map(c => c.category))).sort() as string[], [cid]);
  const pg = usePaged(async (a, b) => qPage(supabase.from('stock_counts').select('*, warehouse:warehouses(code,name), lines:stock_count_lines(system_qty,counted_qty,unit_cost)', { count: 'exact' })
    .eq('company_id', cid).order('count_date', { ascending: false }).order('number', { ascending: false }).range(a, b) as any), [cid]);
  return <>
    <PageHead title="Stocktakes" sub="Count what is on the shelf, compare it with the books, and post the difference.">
      <Link className="btn" to="/inventory">Inventory</Link>
      {can('accountant', 'store') && whs && <button className="btn primary" type="button" onClick={() => setF({ warehouse: whs.find(w => w.is_default)?.id || whs[0]?.id, date: today(), category: '' })}>Start a count</button>}
    </PageHead>
    <Loading error={pg.error} loading={pg.loading && !pg.data} />
    {pg.data && <Panel>{pg.rows.length ? <div className="scroll"><table>
      <thead><tr><th>No.</th><th>Date</th><th>Store</th><th className="r">Lines counted</th><th className="r">Difference (GH₵)</th><th>Status</th></tr></thead>
      <tbody>{pg.rows.map(c => { const done = c.lines.filter((l: any) => l.counted_qty != null).length; const diff = c.lines.reduce((a: number, l: any) => a + (l.counted_qty == null ? 0 : (Number(l.counted_qty) - Number(l.system_qty)) * Number(l.unit_cost || 0)), 0);
        return <tr key={c.id} className="click" onClick={() => nav('/inventory/counts/' + c.id)}><td className="num">{c.number}</td><td className="num">{c.count_date}</td><td>{c.warehouse?.name}{c.notes && <span className="muted"> · {c.notes}</span>}</td>
          <td className="r num">{done} / {c.lines.length}</td><td className="r num" style={{ color: diff < 0 ? 'var(--bad)' : undefined }}>{c.status === 'posted' ? money(diff) : ''}</td>
          <td><span className={'pill ' + (c.status === 'posted' ? 'good' : 'warn')}>{c.status === 'posted' ? 'Posted' : 'Counting'}</span></td></tr>; })}</tbody>
    </table></div> : <Empty>No stocktakes yet. Count each store at least once a year (at year end), and fast-moving or valuable items more often.</Empty>}<Pager {...pg} noun="counts" /></Panel>}
    {f && whs && <FormModal title="Start a stocktake" submit="Create count sheet" busy={act.busy} onClose={() => setF(null)}
      onSave={() => act.run(async () => { const id = await rpc<string>('start_stock_count', { cid, p_warehouse: f.warehouse, p_date: f.date, p_category: f.category || null }); nav('/inventory/counts/' + id); }, 'Count sheet ready')}>
      <div className="grid-form">
        <Select label="Store" id="sc-wh" value={f.warehouse} onChange={v => setF({ ...f, warehouse: v })} options={whs.filter(w => w.active).map(w => [w.id, `${w.code} · ${w.name}`])} />
        <Field label="Count date" id="sc-date" type="date" value={f.date} onChange={v => setF({ ...f, date: v })} required />
        {cats && cats.length > 0 && <Select label="Items" id="sc-cat" value={f.category} onChange={v => setF({ ...f, category: v })} options={[['', 'Every item'], ...cats.map(c => [c, 'Only ' + c] as [string, string])]} />}
      </div>
      <p className="muted" style={{ margin: 0, fontSize: 13 }}>The sheet lists every stock item with the quantity the books expect. Print it for the counters (without the expected figures), then type in what they found.</p>
    </FormModal>}
  </>;
}

export function StockCountView() {
  const { id } = useParams();
  const { company, can } = useSession();
  const nav = useNavigate();
  const act = useAction();
  const [counts, setCounts] = useState<Record<string, string>>({});
  const [hideZero, setHideZero] = useState(false);
  const { data, error, loading, reload } = useLoad(async () => {
    const c = await q<any>(supabase.from('stock_counts').select('*, warehouse:warehouses(code,name)').eq('id', id).single() as any);
    const lines = await q<any[]>(supabase.from('stock_count_lines').select('*, product:products(sku,name,unit,cost,category)').eq('count_id', id) as any);
    lines.sort((a, b) => (a.product?.name || '').localeCompare(b.product?.name || ''));
    setCounts(Object.fromEntries(lines.map(l => [l.id, l.counted_qty == null ? '' : String(Number(l.counted_qty))])));
    return { c, lines };
  }, [id]);
  if (!data) return <Loading error={error} loading={loading} />;
  const { c, lines } = data;
  const draft = c.status === 'draft';
  const val = (l: any) => counts[l.id] === '' || counts[l.id] === undefined ? null : Number(counts[l.id]);
  const cost = (l: any) => Number(l.unit_cost ?? l.product?.cost ?? 0);
  const shown = lines.filter(l => !hideZero || Number(l.system_qty) !== 0 || val(l));
  const diff = lines.reduce((a, l) => a + (val(l) == null ? 0 : (Number(val(l)) - Number(l.system_qty)) * cost(l)), 0);
  const saveCounts = () => act.run(async () => {
    for (const l of lines) {
      const v = counts[l.id] === '' ? null : Number(counts[l.id]);
      if (v !== (l.counted_qty == null ? null : Number(l.counted_qty))) await q(supabase.from('stock_count_lines').update({ counted_qty: v }).eq('id', l.id) as any);
    }
    reload();
  }, 'Counts saved');
  const sheet = () => tablePdf({ company: company!, title: `Count sheet ${c.number}`, subtitle: `${c.warehouse?.name} · ${longDate(c.count_date)}`, head: ['Code', 'Item', 'Unit', 'Counted', 'Counted by'],
    body: lines.map(l => [l.product?.sku, l.product?.name, l.product?.unit, '', '']), filename: `count-sheet-${c.number}` });
  return <>
    <PageHead title={`Stocktake ${c.number}`} sub={<span className="muted">{c.warehouse?.name} · {longDate(c.count_date)} · {draft ? 'counting' : 'posted'}{c.notes ? ' · ' + c.notes : ''}</span>}>
      <Link className="btn" to="/inventory/counts">Back</Link>
      <button className="btn" type="button" onClick={sheet}>Blank count sheet PDF</button>
      {draft && <ConfirmButton className="btn ghost" label="Delete" confirm="Delete this count?" onConfirm={() => act.run(async () => { await q(supabase.from('stock_counts').delete().eq('id', id) as any); nav('/inventory/counts'); })} />}
      {draft && <button className="btn" type="button" disabled={act.busy} onClick={saveCounts}>Save counts</button>}
      {draft && can('accountant') && <ConfirmButton className="btn primary" label="Post differences" confirm={`Post a ${diff < 0 ? 'loss' : 'gain'} of ${cedis(Math.abs(diff))}?`}
        onConfirm={() => act.run(async () => { await saveCounts(); const r = await rpc<any>('post_stock_count', { p_id: id }); reload(); return r; }, 'Stocktake posted: stock and the books now match the count')} />}
    </PageHead>
    <div className="tiles">
      <div className="tile"><span>Lines counted</span><b>{lines.filter(l => val(l) != null).length} / {lines.length}</b></div>
      <div className="tile"><span>Items with a difference</span><b>{lines.filter(l => val(l) != null && Number(val(l)) !== Number(l.system_qty)).length}</b></div>
      <div className="tile"><span>Net difference at cost</span><b style={{ color: diff < 0 ? 'var(--bad)' : diff > 0 ? 'var(--good)' : undefined }}>{cedis(diff)}</b></div>
    </div>
    <Panel title={<label className="check"><input type="checkbox" checked={hideZero} onChange={e => setHideZero(e.target.checked)} /> Hide items the books say are not here</label>}
      actions={draft && <button className="btn small" type="button" onClick={() => setCounts(Object.fromEntries(lines.map(l => [l.id, counts[l.id] === '' ? String(Number(l.system_qty)) : counts[l.id]])))}>Fill blanks with the expected quantity</button>}>
      <div className="scroll"><table>
        <thead><tr><th>Item</th><th className="r">Expected</th><th className="r">Counted</th><th className="r">Difference</th><th className="r">Value (GH₵)</th></tr></thead>
        <tbody>{shown.map(l => { const v = val(l), d = v == null ? null : v - Number(l.system_qty); return <tr key={l.id}>
          <td>{l.product?.name} <span className="muted num" style={{ fontSize: 12 }}>{l.product?.sku}</span></td>
          <td className="r num">{qty(l.system_qty)} {l.product?.unit}</td>
          <td className="r">{draft ? <input aria-label={'Counted: ' + l.product?.name} type="number" step="0.001" min="0" value={counts[l.id] ?? ''} onChange={e => setCounts({ ...counts, [l.id]: e.target.value })} style={{ width: 100, textAlign: 'right' }} />
            : <span className="num">{qty(l.counted_qty)}</span>}</td>
          <td className="r num" style={{ color: d ? (d < 0 ? 'var(--bad)' : 'var(--good)') : undefined }}>{d == null ? '' : d > 0 ? '+' + qty(d) : qty(d)}</td>
          <td className="r num">{d ? money(d * cost(l)) : ''}</td></tr>; })}</tbody>
      </table></div>
      <div className="body muted" style={{ fontSize: 13 }}>Enter 0 for an item you could not find. Posting moves stock to what you counted (allowing for anything sold or received since the sheet was made) and books the difference to 5100 Stock adjustments.</div>
    </Panel>
  </>;
}
