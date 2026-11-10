import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { q, rpc, supabase } from '../lib/supabase';
import { useSession } from '../lib/session';
import { cedis, money, qty, today } from '../lib/format';
import { downloadCsv } from '../lib/download';
import { ConfirmButton, Empty, Field, FormModal, Panel, Select, useAction, useLoad } from './ui';
import { StockIssueForm } from '../pages/Inventory';

const REQ: Record<string, [string, string]> = { draft: ['Draft', ''], submitted: ['Waiting for the store', 'warn'], dispatched: ['On the way', 'warn'], received: ['Received', 'good'], cancelled: ['Cancelled', ''] };

/** The project's own store on site: stock there, daily usage, requests from the main store, returns, counts and the materials plan. */
export function SiteStore({ p, manage, onChange }: { p: any; manage: boolean; onChange: () => void }) {
  const { cid, can } = useSession();
  const nav = useNavigate();
  const act = useAction();
  const storeUser = can('accountant', 'store');
  const locked = ['closed', 'cancelled'].includes(p.status);
  const [setup, setSetup] = useState<any | null>(null);
  const [usage, setUsage] = useState(false);
  const [ret, setRet] = useState<any | null>(null);
  const [req, setReq] = useState<any | null>(null);
  const [send, setSend] = useState<any | null>(null);
  const [recv, setRecv] = useState<any | null>(null);
  const [plan, setPlan] = useState<any[] | null>(null);
  const { data, reload } = useLoad(async () => {
    const [sites, others, team, use, requests, products, limit] = await Promise.all([
      q<any[]>(supabase.from('warehouses').select('id,code,name,address').eq('project_id', p.id).eq('kind', 'site').eq('active', true).order('code') as any),
      q<any[]>(supabase.from('warehouses').select('id,code,name,kind,is_default,project_id').eq('company_id', cid).eq('active', true).order('code') as any),
      rpc<boolean>('on_project_team', { pid: p.id }).catch(() => false),
      rpc<any[]>('project_material_usage', { p_project: p.id }).catch(() => [] as any[]),
      q<any[]>(supabase.from('stock_requests').select('*, src:warehouses!stock_requests_from_warehouse_id_fkey(code,name), lines:stock_request_lines(id,qty,dispatched_qty,received_qty, product:products(name,unit))').eq('project_id', p.id).order('created_at', { ascending: false }) as any),
      q<any[]>(supabase.from('products').select('id,sku,name,unit,cost').eq('company_id', cid).eq('item_type', 'stock').eq('active', true).order('name') as any),
      q<any>(supabase.from('companies').select('site_count_limit').eq('id', cid).single() as any).catch(() => ({ site_count_limit: 1000 })),
    ]);
    const ids = sites.map(s => s.id);
    const levels = ids.length ? await q<any[]>(supabase.from('stock_levels').select('warehouse_id,product_id,qty,bin, product:products(sku,name,unit,cost)').in('warehouse_id', ids) as any) : [];
    const counts = ids.length ? await q<any[]>(supabase.from('stock_counts').select('id,number,count_date,status,warehouse_id').in('warehouse_id', ids).order('count_date', { ascending: false }).limit(10) as any) : [];
    return { sites, others, team, use, requests, products, levels: levels.filter(l => Number(l.qty) !== 0), counts, limit: Number(limit?.site_count_limit ?? 1000) };
  }, [p.id, cid]);
  if (!data) return null;
  const { sites, levels, use, requests } = data;
  const canWork = !locked && (data.team || storeUser);
  const site = sites[0];
  const mains = data.others.filter(w => w.kind !== 'site' && w.kind !== 'transit');
  const refresh = () => { reload(); onChange(); };
  const stockValue = levels.reduce((a, l) => a + Number(l.qty) * Number(l.product?.cost || 0), 0);
  const usedValue = use.reduce((a, u) => a + Number(u.used_value), 0);
  const wasteValue = use.reduce((a, u) => a + Number(u.wastage_value), 0);
  const openReqs = requests.filter(r => ['draft', 'submitted', 'dispatched'].includes(r.status));
  const atSite = (pid: string, wh: string) => Number(levels.find(l => l.product_id === pid && l.warehouse_id === wh)?.qty || 0);

  if (!site) return <Panel title="Site store" actions={!locked && (manage || storeUser) && <button className="btn small primary" type="button" onClick={() => setSetup({ code: 'SITE-' + (p.number || '').replace(/\D/g, '').replace(/^0+/, ''), name: p.name + ' site store', address: p.location || '' })}>Set up a site store</button>}>
    <Empty>No site store yet. Set one up when materials will be kept on site: the project team then receives deliveries, records daily usage, returns unused stock and counts it, all under this project. Stock on site stays company stock until it is used.</Empty>
    {setup && <FormModal title="Set up a site store" busy={act.busy} onClose={() => setSetup(null)} onSave={() => act.run(async () => {
      await q(supabase.from('warehouses').insert({ company_id: p.company_id, code: setup.code.trim().toUpperCase(), name: setup.name, kind: 'site', address: setup.address || null, project_id: p.id }) as any);
      setSetup(null); refresh(); }, 'Site store ready')}>
      <div className="grid-form"><Field label="Code" id="ss-code" value={setup.code} onChange={v => setSetup({ ...setup, code: v })} required />
        <Field label="Name" id="ss-name" value={setup.name} onChange={v => setSetup({ ...setup, name: v })} required /></div>
      <Field label="Where on site" id="ss-addr" value={setup.address} onChange={v => setSetup({ ...setup, address: v })} placeholder="e.g. Container 2, north gate" />
      <p className="muted" style={{ margin: 0, fontSize: 13 }}>The project manager and everyone assigned to the project (Team tab) can work this store. They cannot touch other stores.</p>
    </FormModal>}
  </Panel>;

  return <>
    <div className="tiles">
      <div className="tile"><span>Stock at site ({site.code})</span><b>{cedis(stockValue)}</b><span className="muted" style={{ fontSize: 12 }}>{levels.length} item{levels.length === 1 ? '' : 's'}</span></div>
      <div className="tile"><span>Materials used</span><b>{cedis(usedValue)}</b></div>
      <div className="tile"><span>Wastage found on site counts</span><b style={{ color: wasteValue > 0 ? 'var(--bad)' : undefined }}>{cedis(wasteValue)}</b></div>
      <div className="tile"><span>Requests open</span><b>{openReqs.length}</b><span className="muted" style={{ fontSize: 12 }}>{requests.filter(r => r.status === 'dispatched').length} on the way</span></div>
    </div>

    <Panel title={`Stock at site · ${site.name}`} actions={canWork && <>
      <button className="btn small" type="button" onClick={() => setReq({ from: mains.find(w => w.is_default)?.id || mains[0]?.id || '', needed_by: '', notes: '', lines: [{ product_id: '', qty: '' }] })}>Request from store</button>
      {levels.length > 0 && <button className="btn small" type="button" onClick={() => setRet({ to: mains.find(w => w.is_default)?.id || mains[0]?.id || '', date: today(), notes: '', qty: {} })}>Send back</button>}
      {levels.length > 0 && <button className="btn small" type="button" disabled={act.busy} onClick={() => act.run(async () => { const id = await rpc<string>('start_stock_count', { cid, p_warehouse: site.id, p_date: today(), p_category: null }); nav('/inventory/counts/' + id); }, 'Count sheet ready')}>Count site stock</button>}
      {levels.length > 0 && <button className="btn small primary" type="button" onClick={() => setUsage(true)}>Record usage</button>}</>}>
      {levels.length ? <div className="scroll"><table>
        <thead><tr><th>Item</th><th>Bin</th><th className="r">At site</th><th className="r">Value (GH₵)</th></tr></thead>
        <tbody>{levels.map(l => <tr key={l.product_id}><td>{l.product?.name} <span className="muted num" style={{ fontSize: 12 }}>{l.product?.sku}</span></td><td>{l.bin}</td>
          <td className="r num">{qty(l.qty)} {l.product?.unit}</td><td className="r num">{money(Number(l.qty) * Number(l.product?.cost || 0))}</td></tr>)}</tbody>
      </table></div> : <Empty>Nothing at site. Request materials from the store, or have suppliers deliver here (purchase order → deliver to {site.code}).</Empty>}
      {data.counts.filter(c => c.status === 'draft').map(c => <div key={c.id} className="body"><button className="btn small" type="button" onClick={() => nav('/inventory/counts/' + c.id)}>Continue count {c.number}</button></div>)}
      <div className="body muted" style={{ fontSize: 13 }}>Usage is charged to the project at average cost when recorded. Site counts: the team counts, the project manager posts differences up to {cedis(data.limit)} (an accountant above that), and any shortage is charged to the project as wastage.</div>
    </Panel>

    <Panel title="Materials plan vs used" actions={<>
      <button className="btn small" type="button" onClick={() => downloadCsv(`materials-${p.number || p.name}`, ['Item', 'Unit', 'Planned', 'Used', 'Used %', 'At site', 'In transit', 'Requested', 'Wastage', 'Remaining'],
        use.map(u => [u.name, u.unit, u.planned == null ? '' : qty(u.planned), qty(u.used), u.used_pct == null ? '' : String(u.used_pct), qty(u.at_site), qty(u.in_transit), qty(u.requested), qty(u.wastage), u.remaining == null ? '' : qty(u.remaining)]))}>Download CSV</button>
      {manage && !locked && <button className="btn small primary" type="button" onClick={() => setPlan(use.filter(u => u.planned != null).map(u => ({ product_id: u.product_id, planned_qty: String(Number(u.planned)) })).concat([{ product_id: '', planned_qty: '' }]))}>Edit plan</button>}</>}>
      {use.length ? <div className="scroll"><table>
        <thead><tr><th>Item</th><th className="r">Planned</th><th className="r">Used</th><th style={{ width: 110 }}></th><th className="r">At site</th><th className="r">On the way</th><th className="r">Requested</th><th className="r">Wastage</th><th className="r">Left to use</th></tr></thead>
        <tbody>{use.map(u => <tr key={u.product_id}><td>{u.name} <span className="muted" style={{ fontSize: 12 }}>{u.unit}</span>{u.over && <span className="pill bad" style={{ marginLeft: 6 }}>Over plan</span>}</td>
          <td className="r num">{u.planned == null ? <span className="muted">—</span> : qty(u.planned)}</td><td className="r num">{qty(u.used)}</td>
          <td>{u.used_pct != null && <div style={{ height: 7, background: 'var(--sunk)', borderRadius: 4, overflow: 'hidden' }}><div style={{ width: Math.min(Number(u.used_pct), 100) + '%', height: '100%', background: u.over ? 'var(--bad)' : 'var(--accent)' }} /></div>}</td>
          <td className="r num">{Number(u.at_site) ? qty(u.at_site) : ''}</td><td className="r num">{Number(u.in_transit) ? qty(u.in_transit) : ''}</td><td className="r num">{Number(u.requested) ? qty(u.requested) : ''}</td>
          <td className="r num" style={{ color: Number(u.wastage) > 0 ? 'var(--bad)' : undefined }}>{Number(u.wastage) ? qty(u.wastage) : ''}</td>
          <td className="r num" style={{ color: u.remaining != null && Number(u.remaining) < 0 ? 'var(--bad)' : undefined }}>{u.remaining == null ? '' : qty(u.remaining)}</td></tr>)}</tbody>
      </table></div> : <Empty>No materials planned or used yet. The project manager can enter the quantities the job needs (from the bill of quantities) to track usage against them.</Empty>}
    </Panel>

    <Panel title="Stock requests">{requests.length ? <div className="scroll"><table>
      <thead><tr><th>Request</th><th>From</th><th>What</th><th>Needed by</th><th>Status</th><th></th></tr></thead>
      <tbody>{requests.map(r => <tr key={r.id}><td className="num">{r.number}<br /><span className="muted" style={{ fontSize: 12 }}>{r.created_at.slice(0, 10)} · {(r.requested_email || '').split('@')[0]}</span></td>
        <td>{r.src?.code}</td>
        <td className="wrap-cell">{r.lines.map((l: any) => `${qty(r.status === 'received' ? l.received_qty : r.status === 'dispatched' ? l.dispatched_qty : l.qty)} ${l.product?.unit} ${l.product?.name}`
          + (r.status === 'received' && Number(l.received_qty) < Number(l.dispatched_qty) ? ` (${qty(Number(l.dispatched_qty) - Number(l.received_qty))} short)` : '')).join(', ')}
          {(r.dispatch_note || r.receive_note) && <><br /><span className="muted" style={{ fontSize: 12 }}>{[r.dispatch_note, r.receive_note].filter(Boolean).join(' · ')}</span></>}</td>
        <td className="num">{r.needed_by || ''}</td><td><span className={'pill ' + REQ[r.status][1]}>{REQ[r.status][0]}</span></td>
        <td className="r"><span className="actions" style={{ justifyContent: 'flex-end' }}>
          {r.status === 'submitted' && storeUser && <button className="btn small primary" type="button" onClick={() => setSend({ r, date: today(), note: '', qty: Object.fromEntries(r.lines.map((l: any) => [l.id, String(Number(l.qty))])) })}>Send</button>}
          {r.status === 'dispatched' && canWork && <button className="btn small primary" type="button" onClick={() => setRecv({ r, date: today(), note: '', qty: Object.fromEntries(r.lines.map((l: any) => [l.id, String(Number(l.dispatched_qty))])) })}>Confirm received</button>}
          {['draft', 'submitted'].includes(r.status) && canWork && <ConfirmButton className="btn small ghost" label="Cancel" confirm={`Cancel ${r.number}?`} onConfirm={() => act.run(async () => { await q(supabase.from('stock_requests').update({ status: 'cancelled' }).eq('id', r.id) as any); refresh(); }, 'Cancelled')} />}
        </span></td></tr>)}</tbody>
    </table></div> : <Empty>No requests yet. The site asks for stock from the main store; the store sends it; the site confirms what arrived. Anything short is written off as lost in transit.</Empty>}</Panel>

    {usage && <StockIssueForm kind="issue" projectId={p.id} onClose={() => setUsage(false)} onDone={() => { setUsage(false); refresh(); }} />}
    {req && <FormModal title="Request stock from the store" submit="Send request" busy={act.busy} onClose={() => setReq(null)} onSave={() => act.run(async () => {
      const ls = req.lines.filter((l: any) => l.product_id && Number(l.qty) > 0);
      if (!ls.length) throw new Error('Add at least one item and quantity.');
      const r = await q<any>(supabase.from('stock_requests').insert({ project_id: p.id, company_id: p.company_id, from_warehouse_id: req.from, to_warehouse_id: site.id, needed_by: req.needed_by || null, notes: req.notes || null, status: 'submitted' }).select('id').single() as any);
      await q(supabase.from('stock_request_lines').insert(ls.map((l: any, i: number) => ({ request_id: r.id, company_id: p.company_id, product_id: l.product_id, qty: Number(l.qty), sort: i }))) as any);
      setReq(null); refresh(); }, 'Request sent to the store')}>
      <div className="grid-form">
        <Select label="From" id="rq-from" value={req.from} onChange={v => setReq({ ...req, from: v })} options={mains.map(w => [w.id, `${w.code} · ${w.name}`])} />
        <Field label="Needed on site by" id="rq-need" type="date" value={req.needed_by} onChange={v => setReq({ ...req, needed_by: v })} />
      </div>
      <div className="scroll"><table className="lines"><thead><tr><th>Item</th><th className="r">Planned left</th><th className="r">Qty</th><th></th></tr></thead>
        <tbody>{req.lines.map((l: any, i: number) => { const u = use.find(x => x.product_id === l.product_id); return <tr key={i}>
          <td><select aria-label="Item" value={l.product_id} onChange={e => setReq({ ...req, lines: req.lines.map((x: any, j: number) => j === i ? { ...x, product_id: e.target.value } : x) })} style={{ minWidth: 200 }}>
            <option value="">Choose…</option>{data.products.map(x => <option key={x.id} value={x.id}>{x.sku} · {x.name}</option>)}</select></td>
          <td className="r num">{u?.remaining != null ? qty(Number(u.remaining) - Number(u.at_site) - Number(u.in_transit) - Number(u.requested)) : ''}</td>
          <td><input aria-label="Quantity" type="number" step="0.001" min="0" value={l.qty} onChange={e => setReq({ ...req, lines: req.lines.map((x: any, j: number) => j === i ? { ...x, qty: e.target.value } : x) })} style={{ width: 90, textAlign: 'right' }} /></td>
          <td><button className="btn ghost small" type="button" disabled={req.lines.length < 2} onClick={() => setReq({ ...req, lines: req.lines.filter((_: any, j: number) => j !== i) })}>Remove</button></td></tr>; })}</tbody></table></div>
      <div><button className="btn small" type="button" onClick={() => setReq({ ...req, lines: [...req.lines, { product_id: '', qty: '' }] })}>Add item</button></div>
      <Field label="Note for the store" id="rq-note" value={req.notes} onChange={v => setReq({ ...req, notes: v })} />
    </FormModal>}
    {send && <FormModal title={`Send ${send.r.number} to site`} submit="Send" busy={act.busy} onClose={() => setSend(null)} onSave={() => act.run(async () => {
      await rpc('dispatch_stock_request', { p_id: send.r.id, p_lines: send.r.lines.map((l: any) => ({ line_id: l.id, qty: Number(send.qty[l.id]) || 0 })), p_date: send.date, p_note: send.note || null }); setSend(null); refresh(); }, 'Sent. The site confirms what arrives.')}>
      <div className="grid-form"><Field label="Date sent" id="sd-date" type="date" value={send.date} onChange={v => setSend({ ...send, date: v })} required />
        <Field label="Vehicle and driver" id="sd-note" value={send.note} onChange={v => setSend({ ...send, note: v })} placeholder="e.g. GT 4471-22, Kofi" /></div>
      <table className="lines"><thead><tr><th>Item</th><th className="r">Asked for</th><th className="r">Sending</th></tr></thead><tbody>{send.r.lines.map((l: any) => <tr key={l.id}><td>{l.product?.name}</td><td className="r num">{qty(l.qty)}</td>
        <td><input aria-label={'Sending: ' + l.product?.name} type="number" step="0.001" min="0" value={send.qty[l.id]} onChange={e => setSend({ ...send, qty: { ...send.qty, [l.id]: e.target.value } })} style={{ width: 90, textAlign: 'right' }} /></td></tr>)}</tbody></table>
    </FormModal>}
    {recv && <FormModal title={`Confirm what arrived on ${recv.r.number}`} submit="Confirm" busy={act.busy} onClose={() => setRecv(null)} onSave={() => act.run(async () => {
      const r = await rpc<any>('receive_stock_request', { p_id: recv.r.id, p_lines: recv.r.lines.map((l: any) => ({ line_id: l.id, qty: Number(recv.qty[l.id]) || 0 })), p_date: recv.date, p_note: recv.note || null });
      setRecv(null); refresh(); return r; }, 'Received into the site store')}>
      <Field label="Date received" id="rv-date" type="date" value={recv.date} onChange={v => setRecv({ ...recv, date: v })} required />
      <table className="lines"><thead><tr><th>Item</th><th className="r">Sent</th><th className="r">Arrived</th></tr></thead><tbody>{recv.r.lines.filter((l: any) => Number(l.dispatched_qty) > 0).map((l: any) => <tr key={l.id}><td>{l.product?.name}</td><td className="r num">{qty(l.dispatched_qty)}</td>
        <td><input aria-label={'Arrived: ' + l.product?.name} type="number" step="0.001" min="0" max={Number(l.dispatched_qty)} value={recv.qty[l.id]} onChange={e => setRecv({ ...recv, qty: { ...recv.qty, [l.id]: e.target.value } })} style={{ width: 90, textAlign: 'right' }} /></td></tr>)}</tbody></table>
      {recv.r.lines.some((l: any) => Number(recv.qty[l.id] || 0) < Number(l.dispatched_qty)) && <>
        <div className="note" style={{ background: 'var(--warn-soft)' }}>Less arrived than was sent. The difference is written off as lost in transit and recorded against this project.</div>
        <Field label="What happened" id="rv-note" value={recv.note} onChange={v => setRecv({ ...recv, note: v })} placeholder="e.g. 2 bags burst on the truck" /></>}
    </FormModal>}
    {ret && <FormModal title="Send stock back from site" submit="Send now" busy={act.busy} onClose={() => setRet(null)} onSave={() => act.run(async () => {
      const ls = levels.filter(l => Number(ret.qty[l.product_id]) > 0);
      if (!ls.length) throw new Error('Enter a quantity for at least one item.');
      const t = await q<any>(supabase.from('stock_transfers').insert({ company_id: p.company_id, from_warehouse_id: site.id, to_warehouse_id: ret.to, transfer_date: ret.date, notes: ret.notes || null }).select('id').single() as any);
      await q(supabase.from('stock_transfer_lines').insert(ls.map(l => ({ transfer_id: t.id, company_id: p.company_id, product_id: l.product_id, qty: Number(ret.qty[l.product_id]) }))) as any);
      await rpc('post_transfer', { p_id: t.id }); setRet(null); refresh(); }, 'Stock sent back')}>
      <div className="grid-form"><Select label="To" id="rt-to" value={ret.to} onChange={v => setRet({ ...ret, to: v })} options={data.others.filter(w => w.id !== site.id && w.kind !== 'transit').map(w => [w.id, `${w.code} · ${w.name}${w.kind === 'site' ? ' (another project)' : ''}`])} />
        <Field label="Date" id="rt-date" type="date" value={ret.date} onChange={v => setRet({ ...ret, date: v })} required /></div>
      <table className="lines"><thead><tr><th>Item</th><th className="r">At site</th><th className="r">Send</th></tr></thead><tbody>{levels.map(l => <tr key={l.product_id}><td>{l.product?.name}</td><td className="r num">{qty(atSite(l.product_id, site.id))}</td>
        <td><input aria-label={'Send back: ' + l.product?.name} type="number" step="0.001" min="0" max={Number(l.qty)} value={ret.qty[l.product_id] ?? ''} onChange={e => setRet({ ...ret, qty: { ...ret.qty, [l.product_id]: e.target.value } })} style={{ width: 90, textAlign: 'right' }} /></td></tr>)}</tbody></table>
      <div><button className="btn small" type="button" onClick={() => setRet({ ...ret, qty: Object.fromEntries(levels.map(l => [l.product_id, String(Number(l.qty))])) })}>Send everything</button></div>
      <Field label="Note" id="rt-note" value={ret.notes} onChange={v => setRet({ ...ret, notes: v })} placeholder="e.g. Unused at end of foundations" />
    </FormModal>}
    {plan && <FormModal title="Materials plan" busy={act.busy} onClose={() => setPlan(null)} onSave={() => act.run(async () => {
      const rows = plan.filter(r => r.product_id && r.planned_qty !== '');
      await q(supabase.from('project_material_plan').delete().eq('project_id', p.id) as any);
      if (rows.length) await q(supabase.from('project_material_plan').insert(rows.map(r => ({ project_id: p.id, company_id: p.company_id, product_id: r.product_id, planned_qty: Number(r.planned_qty) }))) as any);
      setPlan(null); refresh(); }, 'Plan saved')}>
      <p className="muted" style={{ margin: 0, fontSize: 13 }}>Quantities the job needs, e.g. from the bill of quantities. Usage over these is flagged.</p>
      <table className="lines"><thead><tr><th>Item</th><th className="r">Planned qty</th><th></th></tr></thead><tbody>{plan.map((r, i) => <tr key={i}>
        <td><select aria-label="Item" value={r.product_id} onChange={e => setPlan(plan.map((x, j) => j === i ? { ...x, product_id: e.target.value } : x))} style={{ minWidth: 220 }}>
          <option value="">Choose…</option>{data.products.map(x => <option key={x.id} value={x.id}>{x.sku} · {x.name} ({x.unit})</option>)}</select></td>
        <td><input aria-label="Planned quantity" type="number" step="0.001" min="0" value={r.planned_qty} onChange={e => setPlan(plan.map((x, j) => j === i ? { ...x, planned_qty: e.target.value } : x))} style={{ width: 100, textAlign: 'right' }} /></td>
        <td><button className="btn ghost small" type="button" onClick={() => setPlan(plan.filter((_, j) => j !== i))}>Remove</button></td></tr>)}</tbody></table>
      <div><button className="btn small" type="button" onClick={() => setPlan([...plan, { product_id: '', planned_qty: '' }])}>Add item</button></div>
    </FormModal>}
  </>;
}

/** For the main store: every request from project sites, with Send. */
export function StockRequestsPage() {
  const { cid, can } = useSession();
  const nav = useNavigate();
  const act = useAction();
  const [view, setView] = useState<'open' | 'all'>('open');
  const [send, setSend] = useState<any | null>(null);
  const { data, reload } = useLoad(async () => {
    let x = supabase.from('stock_requests').select('*, project:projects(id,number,name), src:warehouses!stock_requests_from_warehouse_id_fkey(code), dst:warehouses!stock_requests_to_warehouse_id_fkey(code,name), lines:stock_request_lines(id,qty,dispatched_qty,received_qty, product:products(name,unit))')
      .eq('company_id', cid).order('created_at', { ascending: false }).limit(200);
    if (view === 'open') x = x.in('status', ['submitted', 'dispatched']);
    return q<any[]>(x as any);
  }, [cid, view]);
  const { data: sites } = useLoad(() => rpc<any[]>('site_stock', { cid }).catch(() => [] as any[]), [cid]);
  return <>
    <div className="head"><div><h1>Requests from sites</h1><p>Project site stores ask for stock; the store sends it; the site confirms what arrived.</p></div></div>
    <div className="actions">{([['open', 'Waiting'], ['all', 'All']] as const).map(([k, l]) => <button key={k} type="button" className={'btn small' + (view === k ? ' primary' : '')} onClick={() => setView(k)}>{l}</button>)}</div>
    <Panel>{data && data.length ? <div className="scroll"><table>
      <thead><tr><th>Request</th><th>Project and site</th><th>What</th><th>Needed by</th><th>Status</th><th></th></tr></thead>
      <tbody>{data.map(r => <tr key={r.id}><td className="num">{r.number}<br /><span className="muted" style={{ fontSize: 12 }}>{r.created_at.slice(0, 10)} · from {r.src?.code}</span></td>
        <td><button className="btn ghost small" style={{ padding: 0 }} type="button" onClick={() => nav('/projects/' + r.project?.id)}>{r.project?.number} {r.project?.name}</button><br /><span className="muted" style={{ fontSize: 12 }}>{r.dst?.name}</span></td>
        <td className="wrap-cell">{r.lines.map((l: any) => `${qty(l.qty)} ${l.product?.unit} ${l.product?.name}`).join(', ')}</td>
        <td className="num" style={{ color: r.status === 'submitted' && r.needed_by && r.needed_by <= today() ? 'var(--bad)' : undefined }}>{r.needed_by || ''}</td>
        <td><span className={'pill ' + REQ[r.status][1]}>{REQ[r.status][0]}</span></td>
        <td className="r">{r.status === 'submitted' && can('accountant', 'store') && <button className="btn small primary" type="button" onClick={() => setSend({ r, date: today(), note: '', qty: Object.fromEntries(r.lines.map((l: any) => [l.id, String(Number(l.qty))])) })}>Send</button>}</td></tr>)}</tbody>
    </table></div> : <Empty>{data ? 'Nothing waiting.' : 'Loading…'}</Empty>}</Panel>
    {sites && sites.length > 0 && <Panel title="Stock held at project sites"><div className="scroll"><table>
      <thead><tr><th>Site store</th><th>Project</th><th className="r">Items</th><th className="r">Value (GH₵)</th></tr></thead>
      <tbody>{sites.map(s => <tr key={s.warehouse_id}><td>{s.code} · {s.warehouse}</td><td>{s.project}{['done', 'closed', 'cancelled'].includes(s.project_status) && Number(s.value) > 0 && <span className="pill bad" style={{ marginLeft: 6 }}>Project finished: bring stock back</span>}</td>
        <td className="r num">{s.lines}</td><td className="r num">{money(s.value)}</td></tr>)}</tbody></table></div></Panel>}
    {send && <FormModal title={`Send ${send.r.number} to ${send.r.dst?.name}`} submit="Send" busy={act.busy} onClose={() => setSend(null)} onSave={() => act.run(async () => {
      await rpc('dispatch_stock_request', { p_id: send.r.id, p_lines: send.r.lines.map((l: any) => ({ line_id: l.id, qty: Number(send.qty[l.id]) || 0 })), p_date: send.date, p_note: send.note || null }); setSend(null); reload(); }, 'Sent. The site confirms what arrives.')}>
      <div className="grid-form"><Field label="Date sent" id="sp-date" type="date" value={send.date} onChange={v => setSend({ ...send, date: v })} required />
        <Field label="Vehicle and driver" id="sp-note" value={send.note} onChange={v => setSend({ ...send, note: v })} /></div>
      <table className="lines"><thead><tr><th>Item</th><th className="r">Asked for</th><th className="r">Sending</th></tr></thead><tbody>{send.r.lines.map((l: any) => <tr key={l.id}><td>{l.product?.name}</td><td className="r num">{qty(l.qty)}</td>
        <td><input aria-label={'Sending: ' + l.product?.name} type="number" step="0.001" min="0" value={send.qty[l.id]} onChange={e => setSend({ ...send, qty: { ...send.qty, [l.id]: e.target.value } })} style={{ width: 90, textAlign: 'right' }} /></td></tr>)}</tbody></table>
    </FormModal>}
  </>;
}
