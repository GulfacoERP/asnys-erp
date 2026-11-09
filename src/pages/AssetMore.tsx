import { useState } from 'react';
import { Link } from 'react-router-dom';
import { q, rpc, supabase } from '../lib/supabase';
import { useSession } from '../lib/session';
import { cedis, longDate, money, today } from '../lib/format';
import { downloadCsv } from '../lib/download';
import { tablePdf } from '../lib/pdf';
import { readSheet, toIsoDate, toNum } from '../lib/sheet';
import { ConfirmButton, Downloads, Empty, Field, FormModal, Loading, PageHead, Panel, Select, useAction, useLoad } from '../components/ui';

// ---------------------------------------------------------------- Shared
export const LOC_KINDS: [string, string][] = [['head_office', 'Head office'], ['branch', 'Branch or regional office'], ['site', 'Project site'], ['store', 'Store or warehouse'], ['yard', 'Yard or workshop'], ['other', 'Other']];
const kindName = (k: string) => LOC_KINDS.find(x => x[0] === k)?.[1] || k;
const soon = (d: number) => new Date(Date.now() + d * 864e5).toISOString().slice(0, 10);
const n0 = (v: any) => Number(v || 0).toLocaleString('en-GB', { maximumFractionDigits: 2 });

export function useLocations() {
  const { cid } = useSession();
  return useLoad(() => q<any[]>(supabase.from('asset_locations').select('*').eq('company_id', cid).order('kind').order('name') as any).catch(() => [] as any[]), [cid]);
}
export const locOpts = (locs: any[] | null | undefined, first?: string): [string, string][] =>
  [...(first !== undefined ? [['', first] as [string, string]] : []), ...(locs || []).filter(l => l.active).map(l => [l.id, l.name] as [string, string])];

// ---------------------------------------------------------------- Locations
export function AssetLocationsPage() {
  const { cid, can, session } = useSession();
  const act = useAction();
  const mgr = can('accountant', 'store');
  const [edit, setEdit] = useState<any | null>(null);
  const { data, error, loading, reload } = useLoad(async () => {
    const [locs, team, projects, assets, stock] = await Promise.all([
      q<any[]>(supabase.from('asset_locations').select('*').eq('company_id', cid).order('name') as any),
      q<any[]>(supabase.from('memberships').select('user_id,email,role').eq('company_id', cid).order('email') as any),
      q<any[]>(supabase.from('projects').select('id,number,name,status').eq('company_id', cid).eq('is_template', false).order('number', { ascending: false }) as any).catch(() => [] as any[]),
      q<any[]>(supabase.from('assets').select('id,location_id,state,cost').eq('company_id', cid).eq('status', 'active') as any),
      q<any[]>(supabase.from('asset_item_stock').select('location_id,qty').eq('company_id', cid) as any).catch(() => [] as any[]),
    ]);
    return { locs, team, projects, assets, stock };
  }, [cid]);
  const who = (u?: string | null) => data?.team.find(m => m.user_id === u)?.email || '';
  const save = () => act.run(async () => {
    const row = { company_id: cid, name: edit.name.trim(), kind: edit.kind, region: edit.region || null, address: edit.address || null, manager_id: edit.manager_id || null, project_id: edit.project_id || null, active: edit.active };
    if (!row.name) throw new Error('Give the location a name.');
    if (edit.id) await q(supabase.from('asset_locations').update(row).eq('id', edit.id) as any); else await q(supabase.from('asset_locations').insert(row) as any);
    setEdit(null); reload();
  }, 'Location saved');
  return <>
    <PageHead title="Locations" sub="Head office, branches, sites and stores. Each has a manager who receives transfers and approves requests for that place.">
      {mgr && <button className="btn primary" type="button" onClick={() => setEdit({ name: '', kind: 'site', region: '', address: '', manager_id: '', project_id: '', active: true })}>Add location</button>}
    </PageHead>
    <Loading error={error} loading={loading && !data} />
    {data && <Panel>{data.locs.length ? <div className="scroll"><table>
      <thead><tr><th>Location</th><th>Kind</th><th>Manager</th><th className="r">Assets</th><th className="r">In transit to it</th><th className="r">Stock items</th><th></th></tr></thead>
      <tbody>{data.locs.map(l => { const here = data.assets.filter(a => a.location_id === l.id); return <tr key={l.id} style={l.active ? undefined : { opacity: .55 }}>
        <td><b>{l.name}</b>{l.region && <><br /><span className="muted">{l.region}{l.address ? ' · ' + l.address : ''}</span></>}{l.project_id && <><br /><Link to={'/projects/' + l.project_id} style={{ fontSize: 12 }}>{(p => p ? `${p.number || ''} ${p.name}` : 'Project')(data.projects.find(p => p.id === l.project_id))}</Link></>}</td>
        <td>{kindName(l.kind)}{!l.active && <span className="pill"> closed</span>}</td>
        <td>{who(l.manager_id) || <span className="muted">Nobody (the store decides)</span>}{l.manager_id === session?.user.id && <span className="pill good" style={{ marginLeft: 6 }}>you</span>}</td>
        <td className="r num"><Link to={'/assets?loc=' + l.id}>{here.filter(a => a.state !== 'transit').length}</Link></td>
        <td className="r num">{here.filter(a => a.state === 'transit').length || ''}</td>
        <td className="r num">{n0(data.stock.filter(s => s.location_id === l.id).reduce((s, x) => s + Number(x.qty), 0)) || ''}</td>
        <td className="r">{mgr && <button className="btn small" type="button" onClick={() => setEdit({ ...l, region: l.region || '', address: l.address || '', manager_id: l.manager_id || '', project_id: l.project_id || '' })}>Edit</button>}</td></tr>; })}</tbody></table></div>
      : <Empty>No locations yet.</Empty>}</Panel>}
    {edit && data && <FormModal title={edit.id ? 'Edit location' : 'Add location'} busy={act.busy} onClose={() => setEdit(null)} onSave={save}>
      <div className="grid-form">
        <Field label="Name" id="lc-n" value={edit.name} onChange={v => setEdit({ ...edit, name: v })} placeholder="e.g. Takoradi branch, Prestea site" required />
        <Select label="Kind" id="lc-k" value={edit.kind} onChange={v => setEdit({ ...edit, kind: v })} options={LOC_KINDS} />
        <Field label="Region" id="lc-r" value={edit.region} onChange={v => setEdit({ ...edit, region: v })} placeholder="e.g. Western" />
        <Field label="Address or GPS (GhanaPost)" id="lc-a" value={edit.address} onChange={v => setEdit({ ...edit, address: v })} />
        <Select label="Manager (receives transfers, approves requests)" id="lc-m" value={edit.manager_id} onChange={v => setEdit({ ...edit, manager_id: v })} options={[['', 'Nobody'], ...data.team.map(m => [m.user_id, m.email] as [string, string])]} />
        <Select label="Linked project" id="lc-p" value={edit.project_id} onChange={v => setEdit({ ...edit, project_id: v })} options={[['', 'None'], ...data.projects.filter(p => !['closed', 'cancelled'].includes(p.status) || p.id === edit.project_id).map(p => [p.id, `${p.number || ''} ${p.name}`.trim()] as [string, string])]} />
      </div>
      {edit.id && <label className="check"><input type="checkbox" checked={edit.active} onChange={e => setEdit({ ...edit, active: e.target.checked })} /> Open (untick when a site closes; its history stays)</label>}
    </FormModal>}
  </>;
}

// ---------------------------------------------------------------- Transfers
export function SendTransferModal({ asset, onClose, onDone }: { asset: any; onClose: () => void; onDone: () => void }) {
  const act = useAction();
  const { data: locs } = useLocations();
  const [f, setF] = useState({ to: '', note: '' });
  return <FormModal title={`Transfer ${asset.tag}`} submit="Send" busy={act.busy} onClose={onClose} onSave={() => act.run(async () => {
    if (!f.to) throw new Error('Choose where it is going.');
    await rpc('send_asset_transfer', { p_asset: asset.id, p_to: f.to, p_note: f.note || null }); onDone();
  }, 'Sent. It shows In transit until the other side confirms receipt.')}>
    <p style={{ margin: 0 }}>From <b>{asset.location || '—'}</b></p>
    <Select label="To" id="tr-to" value={f.to} onChange={v => setF({ ...f, to: v })} options={locOpts((locs || []).filter(l => l.id !== asset.location_id), 'Choose…')} />
    <Field label="Note (driver, waybill, reason)" id="tr-n" value={f.note} onChange={v => setF({ ...f, note: v })} placeholder="e.g. On GR 1234-25 with Yaw, for the Monday pour" />
    <p className="muted" style={{ margin: 0, fontSize: 13 }}>The receiving location's manager is told and confirms when it arrives, or rejects it. You can recall it while it is on the way.</p>
  </FormModal>;
}

const TR_STATUS: Record<string, [string, string]> = { in_transit: ['In transit', 'warn'], received: ['Received', 'good'], rejected: ['Rejected', 'bad'], recalled: ['Recalled', ''] };
export function AssetTransfersPage() {
  const { cid, can, session, company } = useSession();
  const act = useAction();
  const me = session?.user.id;
  const [show, setShow] = useState('open');
  const [close, setClose] = useState<any | null>(null);
  const [send, setSend] = useState<any | null>(null);
  const [pick, setPick] = useState('');
  const { data, error, loading, reload } = useLoad(async () => {
    const [trs, locs, assets] = await Promise.all([
      q<any[]>(supabase.from('asset_transfers').select('*, asset:assets(id,tag,name)').eq('company_id', cid).order('sent_at', { ascending: false }).limit(500) as any),
      q<any[]>(supabase.from('asset_locations').select('id,name,manager_id').eq('company_id', cid) as any),
      q<any[]>(supabase.from('assets').select('id,tag,name,location,location_id,state').eq('company_id', cid).eq('status', 'active').in('state', ['ready', 'pending', 'repair', 'broken']).order('tag') as any),
    ]);
    return { trs, locs, assets };
  }, [cid]);
  const loc = (id?: string | null) => data?.locs.find(l => l.id === id);
  const mgr = can('accountant', 'store');
  const F: [string, string, (t: any) => boolean][] = [['open', 'In transit', t => t.status === 'in_transit'], ['mine', 'Coming to me', t => t.status === 'in_transit' && loc(t.to_location_id)?.manager_id === me],
    ['done', 'Received', t => t.status === 'received'], ['back', 'Rejected or recalled', t => ['rejected', 'recalled'].includes(t.status)], ['all', 'All', () => true]];
  const list = (data?.trs || []).filter((F.find(f => f[0] === show) || F[0])[2]);
  const head = ['Transfer', 'Asset', 'From', 'To', 'Sent', 'Status', 'Closed', 'Note'];
  const rows = list.map(t => [t.number, `${t.asset?.tag} ${t.asset?.name}`, loc(t.from_location_id)?.name || '', loc(t.to_location_id)?.name || '', t.sent_at.slice(0, 10), TR_STATUS[t.status][0], t.closed_at?.slice(0, 10) || '', [t.note, t.close_note].filter(Boolean).join(' / ')]);
  const canSendFrom = (a: any) => mgr || loc(a.location_id)?.manager_id === me;
  return <>
    <PageHead title="Transfers" sub="Moving assets between head office, branches and sites. Nothing is lost on the road: each transfer stays In transit until the receiving side confirms.">
      <Downloads pdf={() => tablePdf({ company: company!, title: 'Asset transfers', subtitle: longDate(today()), head, body: rows, landscape: true, filename: 'transfers-' + today() })} csv={() => downloadCsv('transfers-' + today(), head, rows)} />
      <button className="btn primary" type="button" onClick={() => setSend('pick')}>Send an asset</button>
    </PageHead>
    <Loading error={error} loading={loading && !data} />
    {data && <>
      <div className="chips">{F.map(([k, l, fn]) => <button key={k} type="button" className={'chip' + (show === k ? ' on' : '')} onClick={() => setShow(k)}>{l} <span>{data.trs.filter(fn).length}</span></button>)}</div>
      <Panel>{list.length ? <div className="scroll"><table>
        <thead><tr><th>Transfer</th><th>Asset</th><th>From → to</th><th>Sent</th><th>Status</th><th></th></tr></thead>
        <tbody>{list.map(t => { const receiver = mgr || loc(t.to_location_id)?.manager_id === me; const sender = mgr || t.sent_by === me || loc(t.from_location_id)?.manager_id === me; return <tr key={t.id}>
          <td className="num"><b>{t.number}</b></td>
          <td><Link to={'/assets/' + t.asset_id}>{t.asset?.tag}</Link> {t.asset?.name}{t.note && <><br /><span className="muted">{t.note}</span></>}</td>
          <td>{loc(t.from_location_id)?.name || '—'} → <b>{loc(t.to_location_id)?.name}</b></td>
          <td className="num">{t.sent_at.slice(0, 16).replace('T', ' ')}</td>
          <td><span className={'pill ' + TR_STATUS[t.status][1]}>{TR_STATUS[t.status][0]}</span>{t.condition && t.condition !== 'good' && <span className="pill warn"> {t.condition}</span>}{t.close_note && <><br /><span className="muted" style={{ fontSize: 12 }}>{t.close_note}</span></>}</td>
          <td className="r" style={{ whiteSpace: 'nowrap' }}>{t.status === 'in_transit' && <>
            {receiver && <button className="btn small primary" type="button" onClick={() => setClose({ t, action: 'receive', condition: 'good', note: '' })}>Receive</button>}{' '}
            {receiver && <button className="btn small" type="button" onClick={() => setClose({ t, action: 'reject', note: '' })}>Reject</button>}{' '}
            {sender && <button className="btn small ghost" type="button" onClick={() => setClose({ t, action: 'recall', note: '' })}>Recall</button>}</>}</td></tr>; })}</tbody></table></div>
        : <Empty>{show === 'mine' ? 'Nothing on its way to a location you manage.' : 'No transfers here.'}</Empty>}</Panel>
    </>}
    {close && <FormModal title={`${close.action === 'receive' ? 'Receive' : close.action === 'reject' ? 'Reject' : 'Recall'} ${close.t.number}`} submit={close.action === 'receive' ? 'Confirm receipt' : close.action === 'reject' ? 'Reject' : 'Recall'} busy={act.busy} onClose={() => setClose(null)}
      onSave={() => act.run(async () => { await rpc('close_asset_transfer', { p_id: close.t.id, p_action: close.action, p_note: close.note || null, p_condition: close.condition || 'good' }); setClose(null); reload(); }, 'Done')}>
      <p style={{ margin: 0 }}>{close.t.asset?.tag} {close.t.asset?.name}</p>
      {close.action === 'receive' && <Select label="Condition on arrival" id="tc-c" value={close.condition} onChange={v => setClose({ ...close, condition: v })} options={[['good', 'Good'], ['fair', 'Fair'], ['poor', 'Poor (needs repair)'], ['broken', 'Broken']]} />}
      <Field label={close.action === 'reject' ? 'Why is it rejected?' : 'Note'} id="tc-n" value={close.note} onChange={v => setClose({ ...close, note: v })} required={close.action === 'reject'} />
      {close.action === 'reject' && <p className="muted" style={{ margin: 0, fontSize: 13 }}>It goes back to {loc(close.t.from_location_id)?.name || 'where it came from'}.</p>}
    </FormModal>}
    {send === 'pick' && data && <FormModal title="Send an asset" submit="Next" onClose={() => setSend(null)} onSave={() => { const a = data.assets.find(x => x.id === pick); if (a) setSend(a); }}>
      <Select label="Asset" id="ts-a" value={pick} onChange={setPick} options={[['', 'Choose…'], ...data.assets.filter(canSendFrom).map(a => [a.id, `${a.tag} ${a.name} — ${a.location || 'no location'}`] as [string, string])]} />
      <p className="muted" style={{ margin: 0, fontSize: 13 }}>Only assets that are not checked out are listed. Check an asset in first to send it.</p>
    </FormModal>}
    {send && send !== 'pick' && <SendTransferModal asset={send} onClose={() => setSend(null)} onDone={() => { setSend(null); setShow('open'); reload(); }} />}
  </>;
}

// ---------------------------------------------------------------- Accessories, components and consumables
const ITEM_KINDS: [string, string][] = [['accessory', 'Accessory (charger, mouse, headset)'], ['component', 'Component (RAM, disk, spare part)'], ['consumable', 'Consumable (toner, PPE, paper)']];
const MOVE_KINDS: Record<string, string> = { receive: 'Received', checkout: 'Checked out', checkin: 'Returned', consume: 'Used', transfer: 'Transferred', adjust: 'Adjusted' };
export function AssetItemsPage() {
  const { cid, can, company } = useSession();
  const act = useAction();
  const mgr = can('accountant', 'store');
  const [kind, setKind] = useState('all');
  const [edit, setEdit] = useState<any | null>(null);
  const [mv, setMv] = useState<any | null>(null);
  const [hist, setHist] = useState<any | null>(null);
  const { data, error, loading, reload } = useLoad(async () => {
    const [items, stock, outs, locs, staff, assets, projects] = await Promise.all([
      q<any[]>(supabase.from('asset_items').select('*').eq('company_id', cid).order('name') as any),
      q<any[]>(supabase.from('asset_item_stock').select('*').eq('company_id', cid) as any),
      q<any[]>(supabase.from('asset_item_checkouts').select('*, employee:employees(full_name), asset:assets(tag,name)').eq('company_id', cid).eq('status', 'out') as any),
      q<any[]>(supabase.from('asset_locations').select('id,name,active,manager_id').eq('company_id', cid).order('name') as any),
      q<any[]>(supabase.from('employees').select('id,full_name').eq('company_id', cid).eq('status', 'active').order('full_name') as any).catch(() => [] as any[]),
      q<any[]>(supabase.from('assets').select('id,tag,name').eq('company_id', cid).eq('status', 'active').order('tag') as any),
      q<any[]>(supabase.from('projects').select('id,number,name').eq('company_id', cid).in('status', ['planned', 'active']).order('name') as any).catch(() => [] as any[]),
    ]);
    return { items, stock, outs, locs, staff, assets, projects };
  }, [cid]);
  const total = (id: string) => (data?.stock || []).filter(s => s.item_id === id).reduce((s, x) => s + Number(x.qty), 0);
  const at = (id: string, loc: string) => Number((data?.stock || []).find(s => s.item_id === id && s.location_id === loc)?.qty || 0);
  const out = (id: string) => (data?.outs || []).filter(o => o.item_id === id).reduce((s, o) => s + Number(o.qty) - Number(o.returned_qty), 0);
  const list = (data?.items || []).filter(i => kind === 'all' || (kind === 'low' ? i.min_qty > 0 && total(i.id) < Number(i.min_qty) : i.kind === kind));
  const head = ['Item', 'Kind', 'Unit', 'In stock', 'Out', 'Minimum', 'Value (GHS)', ...(data?.locs || []).filter(l => l.active).map(l => l.name)];
  const rows = list.map(i => [i.name, i.kind, i.unit, n0(total(i.id)), n0(out(i.id)), n0(i.min_qty), money(total(i.id) * Number(i.unit_cost || 0)), ...(data?.locs || []).filter(l => l.active).map(l => n0(at(i.id, l.id)))]);
  const doMove = () => act.run(async () => {
    await rpc('item_move', { p_item: mv.item.id, p_kind: mv.kind, p_location: mv.location, p_qty: Number(mv.qty), p_to: mv.to || null, p_employee: mv.employee || null, p_asset: mv.asset || null,
      p_project: mv.project || null, p_unit_cost: mv.unit_cost ? Number(mv.unit_cost) : null, p_note: mv.note || null, p_checkout: mv.checkout || null, p_expected: mv.expected || null });
    setMv(null); reload();
  }, 'Recorded');
  return <>
    <PageHead title="Accessories, components and consumables" sub="Items counted by quantity, kept per location. You are alerted when stock falls below the minimum.">
      <Downloads pdf={() => tablePdf({ company: company!, title: 'Accessories, components and consumables', subtitle: longDate(today()), head, body: rows, landscape: true, rightAlign: [3, 4, 5, 6], filename: 'items-' + today() })} csv={() => downloadCsv('items-' + today(), head, rows)} />
      {mgr && <button className="btn primary" type="button" onClick={() => setEdit({ kind: 'consumable', name: '', category: '', manufacturer: '', model_no: '', unit: 'each', min_qty: '', unit_cost: '', requestable: false, notes: '', active: true })}>Add item</button>}
    </PageHead>
    <Loading error={error} loading={loading && !data} />
    {data && <>
      <div className="chips">{[['all', 'All'], ['accessory', 'Accessories'], ['component', 'Components'], ['consumable', 'Consumables'], ['low', 'Below minimum']].map(([k, l]) =>
        <button key={k} type="button" className={'chip' + (kind === k ? ' on' : '')} onClick={() => setKind(k)}>{l} <span>{data.items.filter(i => k === 'all' || (k === 'low' ? i.min_qty > 0 && total(i.id) < Number(i.min_qty) : i.kind === k)).length}</span></button>)}</div>
      <Panel>{list.length ? <div className="scroll"><table>
        <thead><tr><th>Item</th><th className="r">In stock</th><th>Where</th><th className="r">Out with people</th><th className="r">Minimum</th><th></th></tr></thead>
        <tbody>{list.map(i => { const t = total(i.id), low = Number(i.min_qty) > 0 && t < Number(i.min_qty); return <tr key={i.id}>
          <td><b>{i.name}</b><br /><span className="muted">{i.kind}{i.manufacturer ? ' · ' + i.manufacturer : ''}{i.model_no ? ' ' + i.model_no : ''}{i.unit_cost ? ` · ${cedis(i.unit_cost)} per ${i.unit}` : ''}</span></td>
          <td className="r num"><b>{n0(t)}</b> {i.unit}{low && <><br /><span className="pill bad">low</span></>}</td>
          <td className="wrap-cell muted" style={{ fontSize: 13 }}>{data.stock.filter(s => s.item_id === i.id && Number(s.qty) > 0).map(s => `${data.locs.find(l => l.id === s.location_id)?.name}: ${n0(s.qty)}`).join(' · ') || '—'}</td>
          <td className="r num">{out(i.id) ? n0(out(i.id)) : ''}</td>
          <td className="r num">{Number(i.min_qty) ? n0(i.min_qty) : ''}</td>
          <td className="r" style={{ whiteSpace: 'nowrap' }}>{mgr && <>
            <select aria-label={`Action for ${i.name}`} value="" style={{ width: 'auto' }} onChange={e => { const k = e.target.value; if (k === 'edit') setEdit({ ...i, category: i.category || '', manufacturer: i.manufacturer || '', model_no: i.model_no || '', min_qty: String(i.min_qty), unit_cost: i.unit_cost ?? '', notes: i.notes || '' }); else if (k === 'history') setHist(i); else if (k) setMv({ item: i, kind: k, location: data.locs.find(l => at(i.id, l.id) > 0)?.id || data.locs[0]?.id, qty: '', to: '', employee: '', asset: '', project: '', unit_cost: '', note: '', checkout: '', expected: '' }); }}>
              <option value="">Record…</option><option value="receive">Receive stock</option>
              {i.kind === 'consumable' ? <option value="consume">Issue / use</option> : <><option value="checkout">Check out</option><option value="checkin">Return</option></>}
              <option value="transfer">Transfer to another location</option><option value="adjust">Adjust count</option><option value="history">History</option><option value="edit">Edit</option></select></>}</td></tr>; })}</tbody></table></div>
        : <Empty>{data.items.length ? 'Nothing here.' : 'No items yet. Add chargers, spare parts, PPE, toner and the like.'}</Empty>}</Panel>
      {data.outs.length > 0 && <Panel title="Checked out">
        <div className="scroll"><table><tbody>{data.outs.map(o => { const i = data.items.find(x => x.id === o.item_id); return <tr key={o.id}>
          <td>{i?.name}</td><td>{o.employee?.full_name || (o.asset ? `In ${o.asset.tag} ${o.asset.name}` : '')}</td><td className="num r">{n0(Number(o.qty) - Number(o.returned_qty))}</td>
          <td className="num">{o.out_at.slice(0, 10)}{o.expected_return && <span className={o.expected_return < today() ? 'pill bad' : 'muted'}> back by {o.expected_return}</span>}</td></tr>; })}</tbody></table></div></Panel>}
    </>}
    {edit && <FormModal title={edit.id ? 'Edit item' : 'Add item'} busy={act.busy} onClose={() => setEdit(null)} onSave={() => act.run(async () => {
      const row = { company_id: cid, kind: edit.kind, name: edit.name.trim(), category: edit.category || null, manufacturer: edit.manufacturer || null, model_no: edit.model_no || null, unit: edit.unit || 'each',
        min_qty: Number(edit.min_qty) || 0, unit_cost: edit.unit_cost === '' ? null : Number(edit.unit_cost), requestable: edit.requestable, notes: edit.notes || null, active: edit.active };
      if (!row.name) throw new Error('Name the item.');
      if (edit.id) await q(supabase.from('asset_items').update(row).eq('id', edit.id) as any); else await q(supabase.from('asset_items').insert(row) as any);
      setEdit(null); reload(); }, 'Saved')}>
      <div className="grid-form">
        <Select label="Kind" id="it-k" value={edit.kind} onChange={v => setEdit({ ...edit, kind: v })} options={ITEM_KINDS} />
        <Field label="Name" id="it-n" value={edit.name} onChange={v => setEdit({ ...edit, name: v })} placeholder="e.g. HP 85A toner, Safety boots size 42" required />
        <Field label="Category" id="it-c" value={edit.category} onChange={v => setEdit({ ...edit, category: v })} placeholder="e.g. IT, PPE, Plant spares" />
        <Field label="Manufacturer" id="it-m" value={edit.manufacturer} onChange={v => setEdit({ ...edit, manufacturer: v })} />
        <Field label="Model or part no." id="it-mn" value={edit.model_no} onChange={v => setEdit({ ...edit, model_no: v })} />
        <Field label="Unit" id="it-u" value={edit.unit} onChange={v => setEdit({ ...edit, unit: v })} placeholder="each, box, pair, litre" />
        <Field label="Minimum to keep (alert below this)" id="it-min" type="number" step="0.01" min="0" value={edit.min_qty} onChange={v => setEdit({ ...edit, min_qty: v })} />
        <Field label="Unit cost (GH₵)" id="it-cost" type="number" step="0.01" min="0" value={edit.unit_cost} onChange={v => setEdit({ ...edit, unit_cost: v })} />
      </div>
      <Field label="Notes" id="it-no" value={edit.notes} onChange={v => setEdit({ ...edit, notes: v })} />
    </FormModal>}
    {mv && data && <FormModal title={`${({ receive: 'Receive', consume: 'Issue', checkout: 'Check out', checkin: 'Return', transfer: 'Transfer', adjust: 'Adjust' } as any)[mv.kind]} ${mv.item.name}`} submit="Record" busy={act.busy} onClose={() => setMv(null)} onSave={doMove}>
      {mv.kind === 'checkin' ? <Select label="What is coming back" id="mv-co" value={mv.checkout} onChange={v => { const o = data.outs.find(x => x.id === v); setMv({ ...mv, checkout: v, location: o?.location_id || mv.location, qty: o ? String(Number(o.qty) - Number(o.returned_qty)) : mv.qty }); }}
        options={[['', 'Choose…'], ...data.outs.filter(o => o.item_id === mv.item.id).map(o => [o.id, `${o.employee?.full_name || o.asset?.tag || ''} — ${n0(Number(o.qty) - Number(o.returned_qty))} out since ${o.out_at.slice(0, 10)}`] as [string, string])]} /> : null}
      <div className="grid-form">
        <Select label={mv.kind === 'receive' || mv.kind === 'checkin' ? 'Into location' : 'From location'} id="mv-l" value={mv.location} onChange={v => setMv({ ...mv, location: v })} options={data.locs.filter(l => l.active).map(l => [l.id, `${l.name} (${n0(at(mv.item.id, l.id))})`] as [string, string])} />
        <Field label={mv.kind === 'adjust' ? 'Change (+ found, − missing)' : `Quantity (${mv.item.unit})`} id="mv-q" type="number" step="0.01" value={mv.qty} onChange={v => setMv({ ...mv, qty: v })} required />
        {mv.kind === 'transfer' && <Select label="To location" id="mv-t" value={mv.to} onChange={v => setMv({ ...mv, to: v })} options={locOpts(data.locs.filter(l => l.id !== mv.location), 'Choose…')} />}
        {mv.kind === 'receive' && <Field label="Unit cost (GH₵)" id="mv-c" type="number" step="0.01" min="0" value={mv.unit_cost} onChange={v => setMv({ ...mv, unit_cost: v })} />}
        {mv.kind === 'checkout' && <Select label="To a person" id="mv-e" value={mv.employee} onChange={v => setMv({ ...mv, employee: v })} options={[['', '—'], ...data.staff.map(s => [s.id, s.full_name] as [string, string])]} />}
        {mv.kind === 'checkout' && <Select label="Or fitted into an asset" id="mv-a" value={mv.asset} onChange={v => setMv({ ...mv, asset: v })} options={[['', '—'], ...data.assets.map(a => [a.id, `${a.tag} ${a.name}`] as [string, string])]} />}
        {mv.kind === 'checkout' && <Field label="Expected back" id="mv-x" type="date" value={mv.expected} onChange={v => setMv({ ...mv, expected: v })} />}
        {mv.kind === 'consume' && <Select label="Issued to" id="mv-e2" value={mv.employee} onChange={v => setMv({ ...mv, employee: v })} options={[['', '—'], ...data.staff.map(s => [s.id, s.full_name] as [string, string])]} />}
        {mv.kind === 'consume' && <Select label="For project" id="mv-p" value={mv.project} onChange={v => setMv({ ...mv, project: v })} options={[['', 'None'], ...data.projects.map(p => [p.id, `${p.number || ''} ${p.name}`.trim()] as [string, string])]} />}
      </div>
      <Field label={mv.kind === 'adjust' ? 'Reason (required)' : 'Note'} id="mv-n" value={mv.note} onChange={v => setMv({ ...mv, note: v })} />
    </FormModal>}
    {hist && <ItemHistory item={hist} locs={data?.locs || []} onClose={() => setHist(null)} />}
  </>;
}
function ItemHistory({ item, locs, onClose }: { item: any; locs: any[]; onClose: () => void }) {
  const { data } = useLoad(() => q<any[]>(supabase.from('asset_item_moves').select('*, employee:employees(full_name), asset:assets(tag)').eq('item_id', item.id).order('moved_at', { ascending: false }).limit(200) as any), [item.id]);
  const ln = (id?: string) => locs.find(l => l.id === id)?.name || '';
  return <FormModal title={`History: ${item.name}`} submit="Close" onClose={onClose} onSave={onClose}>
    {!data ? <Loading loading /> : data.length ? <div className="scroll"><table><tbody>{data.map(m => <tr key={m.id}>
      <td className="num">{m.moved_at.slice(0, 10)}</td><td>{MOVE_KINDS[m.kind]}</td><td className="num r">{n0(m.qty)}</td>
      <td className="muted">{[ln(m.location_id) + (m.to_location_id ? ' → ' + ln(m.to_location_id) : ''), m.employee?.full_name, m.asset?.tag, m.note].filter(Boolean).join(' · ')}</td></tr>)}</tbody></table></div> : <Empty>No movements yet.</Empty>}
  </FormModal>;
}

// ---------------------------------------------------------------- Software licences
export function LicencesPage() {
  const { cid, can, company } = useSession();
  const act = useAction();
  const mgr = can('accountant', 'store');
  const [edit, setEdit] = useState<any | null>(null);
  const [seat, setSeat] = useState<any | null>(null);
  const [showKey, setShowKey] = useState<string | null>(null);
  const { data, error, loading, reload } = useLoad(async () => {
    const [lics, seats, staff, assets, sups] = await Promise.all([
      q<any[]>(supabase.from('software_licences').select('*, supplier:suppliers(name)').eq('company_id', cid).order('name') as any),
      q<any[]>(supabase.from('licence_seats').select('*, employee:employees(full_name), asset:assets(tag,name)').eq('company_id', cid).is('released_at', null) as any),
      q<any[]>(supabase.from('employees').select('id,full_name').eq('company_id', cid).eq('status', 'active').order('full_name') as any).catch(() => [] as any[]),
      q<any[]>(supabase.from('assets').select('id,tag,name').eq('company_id', cid).eq('status', 'active').order('tag') as any),
      q<any[]>(supabase.from('suppliers').select('id,name').eq('company_id', cid).order('name') as any).catch(() => [] as any[]),
    ]);
    return { lics, seats, staff, assets, sups };
  }, [cid]);
  const used = (id: string) => (data?.seats || []).filter(s => s.licence_id === id);
  const head = ['Software', 'Seats', 'In use', 'Free', 'Licensed to', 'Expires', 'Cost (GHS)', 'Order no.'];
  const rows = (data?.lics || []).map(l => [l.name, l.seats, used(l.id).length, l.seats - used(l.id).length, l.licensed_to_name || '', l.expires_on || 'Perpetual', money(l.cost || 0), l.order_number || '']);
  return <>
    <PageHead title="Software licences" sub="Seats, product keys and renewals. Assign seats to people or computers; you are reminded 30 days before a licence expires.">
      <Downloads pdf={() => tablePdf({ company: company!, title: 'Software licences', subtitle: longDate(today()), head, body: rows, rightAlign: [1, 2, 3, 6], filename: 'licences-' + today() })} csv={() => downloadCsv('licences-' + today(), head, rows)} />
      {mgr && <button className="btn primary" type="button" onClick={() => setEdit({ name: '', manufacturer: '', product_key: '', seats: '1', licensed_to_name: '', licensed_to_email: '', purchase_date: today(), cost: '', expires_on: '', order_number: '', supplier_id: '', reassignable: true, notes: '' })}>Add licence</button>}
    </PageHead>
    <Loading error={error} loading={loading && !data} />
    {data && <Panel>{data.lics.length ? <div className="scroll"><table>
      <thead><tr><th>Software</th><th className="r">Seats used</th><th>Assigned to</th><th>Expires</th><th></th></tr></thead>
      <tbody>{data.lics.map(l => { const u = used(l.id); const exp = l.expires_on && l.expires_on < today(); return <tr key={l.id}>
        <td><b>{l.name}</b><br /><span className="muted">{[l.manufacturer, l.licensed_to_name, l.supplier?.name].filter(Boolean).join(' · ')}</span>
          {mgr && l.product_key && <><br /><button className="btn small ghost" type="button" style={{ padding: '0 6px' }} onClick={() => setShowKey(showKey === l.id ? null : l.id)}>{showKey === l.id ? <code>{l.product_key}</code> : 'Show key'}</button></>}</td>
        <td className="r num"><b>{u.length}</b> / {l.seats}{u.length >= l.seats && <><br /><span className="pill warn">full</span></>}</td>
        <td className="wrap-cell">{u.map(s => <span key={s.id} className="pill" style={{ marginRight: 4, marginBottom: 2 }}>{s.employee?.full_name || s.asset?.tag}{mgr && l.reassignable && <button type="button" aria-label="Free this seat" style={{ border: 0, background: 'none', cursor: 'pointer', padding: '0 0 0 4px' }}
          onClick={() => act.run(async () => { await q(supabase.from('licence_seats').update({ released_at: new Date().toISOString() }).eq('id', s.id) as any); reload(); }, 'Seat freed')}>×</button>}</span>)}</td>
        <td className="num">{l.expires_on ? <span className={exp ? 'pill bad' : l.expires_on <= soon(30) ? 'pill warn' : ''}>{l.expires_on}{exp ? ' expired' : ''}</span> : <span className="muted">Perpetual</span>}</td>
        <td className="r" style={{ whiteSpace: 'nowrap' }}>{mgr && <>
          {u.length < l.seats && <button className="btn small primary" type="button" onClick={() => setSeat({ l, to: 'employee', employee: '', asset: '', note: '' })}>Assign seat</button>}{' '}
          <button className="btn small" type="button" onClick={() => setEdit({ ...l, seats: String(l.seats), manufacturer: l.manufacturer || '', product_key: l.product_key || '', licensed_to_name: l.licensed_to_name || '', licensed_to_email: l.licensed_to_email || '', purchase_date: l.purchase_date || '', cost: l.cost ?? '', expires_on: l.expires_on || '', order_number: l.order_number || '', supplier_id: l.supplier_id || '', notes: l.notes || '' })}>Edit</button></>}</td></tr>; })}</tbody></table></div>
      : <Empty>No licences yet. Add Microsoft 365, AutoCAD, antivirus, accounting software and the like.</Empty>}</Panel>}
    {edit && data && <FormModal title={edit.id ? 'Edit licence' : 'Add licence'} busy={act.busy} onClose={() => setEdit(null)} onSave={() => act.run(async () => {
      const { supplier, id, ...rest } = edit;
      const row = { ...rest, company_id: cid, seats: Number(edit.seats) || 1, cost: edit.cost === '' ? null : Number(edit.cost), purchase_date: edit.purchase_date || null, expires_on: edit.expires_on || null, supplier_id: edit.supplier_id || null, reminded_on: null };
      if (!row.name?.trim()) throw new Error('Name the software.');
      if (id) await q(supabase.from('software_licences').update(row).eq('id', id) as any); else await q(supabase.from('software_licences').insert(row) as any);
      setEdit(null); reload(); }, 'Saved')}>
      <div className="grid-form">
        <Field label="Software" id="li-n" value={edit.name} onChange={v => setEdit({ ...edit, name: v })} placeholder="e.g. Microsoft 365 Business Standard" required />
        <Field label="Publisher" id="li-m" value={edit.manufacturer} onChange={v => setEdit({ ...edit, manufacturer: v })} />
        <Field label="Seats" id="li-s" type="number" step="1" min="1" value={edit.seats} onChange={v => setEdit({ ...edit, seats: v })} required />
        <Field label="Product key" id="li-k" value={edit.product_key} onChange={v => setEdit({ ...edit, product_key: v })} />
        <Field label="Licensed to (name)" id="li-tn" value={edit.licensed_to_name} onChange={v => setEdit({ ...edit, licensed_to_name: v })} />
        <Field label="Licensed to (email)" id="li-te" type="email" value={edit.licensed_to_email} onChange={v => setEdit({ ...edit, licensed_to_email: v })} />
        <Field label="Purchased" id="li-p" type="date" value={edit.purchase_date} onChange={v => setEdit({ ...edit, purchase_date: v })} />
        <Field label="Expires (blank = perpetual)" id="li-x" type="date" value={edit.expires_on} onChange={v => setEdit({ ...edit, expires_on: v })} />
        <Field label="Cost (GH₵)" id="li-c" type="number" step="0.01" min="0" value={edit.cost} onChange={v => setEdit({ ...edit, cost: v })} />
        <Field label="Order no." id="li-o" value={edit.order_number} onChange={v => setEdit({ ...edit, order_number: v })} />
        <Select label="Supplier" id="li-su" value={edit.supplier_id} onChange={v => setEdit({ ...edit, supplier_id: v })} options={[['', '—'], ...data.sups.map(s => [s.id, s.name] as [string, string])]} />
      </div>
      <label className="check"><input type="checkbox" checked={edit.reassignable} onChange={e => setEdit({ ...edit, reassignable: e.target.checked })} /> Seats can be moved to someone else</label>
      <Field label="Notes" id="li-no" value={edit.notes} onChange={v => setEdit({ ...edit, notes: v })} />
    </FormModal>}
    {seat && data && <FormModal title={`Assign a seat of ${seat.l.name}`} submit="Assign" busy={act.busy} onClose={() => setSeat(null)} onSave={() => act.run(async () => {
      await q(supabase.from('licence_seats').insert({ company_id: cid, licence_id: seat.l.id, employee_id: seat.to === 'employee' ? seat.employee || null : null, asset_id: seat.to === 'asset' ? seat.asset || null : null, note: seat.note || null }) as any);
      setSeat(null); reload(); }, 'Seat assigned')}>
      <Select label="Assign to" id="se-to" value={seat.to} onChange={v => setSeat({ ...seat, to: v })} options={[['employee', 'A person'], ['asset', 'A computer or device']]} />
      {seat.to === 'employee' ? <Select label="Person" id="se-e" value={seat.employee} onChange={v => setSeat({ ...seat, employee: v })} options={[['', 'Choose…'], ...data.staff.map(s => [s.id, s.full_name] as [string, string])]} />
        : <Select label="Asset" id="se-a" value={seat.asset} onChange={v => setSeat({ ...seat, asset: v })} options={[['', 'Choose…'], ...data.assets.map(a => [a.id, `${a.tag} ${a.name}`] as [string, string])]} />}
      <Field label="Note" id="se-n" value={seat.note} onChange={v => setSeat({ ...seat, note: v })} />
    </FormModal>}
  </>;
}

// ---------------------------------------------------------------- Warranty report
export function WarrantyPage() {
  const { cid, company } = useSession();
  const [show, setShow] = useState('90');
  const { data, error, loading } = useLoad(() => q<any[]>(supabase.from('assets').select('id,tag,name,manufacturer,model,serial_no,location,warranty_until,purchase_date,supplier:suppliers(name)').eq('company_id', cid).eq('status', 'active').not('warranty_until', 'is', null).order('warranty_until') as any), [cid]);
  const F: [string, string, (a: any) => boolean][] = [['expired', 'Expired', a => a.warranty_until < today()], ['30', 'Ending in 30 days', a => a.warranty_until >= today() && a.warranty_until <= soon(30)],
    ['90', 'Ending in 90 days', a => a.warranty_until >= today() && a.warranty_until <= soon(90)], ['valid', 'Under warranty', a => a.warranty_until >= today()], ['all', 'All', () => true]];
  const list = (data || []).filter((F.find(f => f[0] === show) || F[2])[2]);
  const head = ['Tag', 'Asset', 'Make / model', 'Serial', 'Location', 'Supplier', 'Purchased', 'Warranty until', 'Days left'];
  const days = (d: string) => Math.round((new Date(d).getTime() - new Date(today()).getTime()) / 864e5);
  const rows = list.map(a => [a.tag, a.name, [a.manufacturer, a.model].filter(Boolean).join(' '), a.serial_no || '', a.location || '', a.supplier?.name || '', a.purchase_date || '', a.warranty_until, days(a.warranty_until)]);
  return <>
    <PageHead title="Warranty report" sub="Claim repairs before the warranty runs out. Set the warranty date when registering an asset.">
      <Downloads pdf={() => tablePdf({ company: company!, title: 'Warranty report', subtitle: (F.find(f => f[0] === show) || F[2])[1] + ' · ' + longDate(today()), head, body: rows, landscape: true, rightAlign: [8], filename: 'warranty-' + today() })} csv={() => downloadCsv('warranty-' + today(), head, rows)} />
    </PageHead>
    <Loading error={error} loading={loading && !data} />
    {data && <>
      <div className="chips">{F.map(([k, l, fn]) => <button key={k} type="button" className={'chip' + (show === k ? ' on' : '')} onClick={() => setShow(k)}>{l} <span>{data.filter(fn).length}</span></button>)}</div>
      <Panel>{list.length ? <div className="scroll"><table>
        <thead><tr><th>Asset</th><th>Make / model</th><th>Supplier</th><th>Warranty until</th><th className="r">Days left</th></tr></thead>
        <tbody>{list.map(a => { const d = days(a.warranty_until); return <tr key={a.id}>
          <td><Link to={'/assets/' + a.id}>{a.tag}</Link> {a.name}<br /><span className="muted">{a.serial_no || ''}{a.location ? ' · ' + a.location : ''}</span></td>
          <td>{[a.manufacturer, a.model].filter(Boolean).join(' ') || '—'}</td><td>{a.supplier?.name || '—'}</td>
          <td className="num">{a.warranty_until}</td><td className="r num"><span className={d < 0 ? 'pill bad' : d <= 30 ? 'pill warn' : ''}>{d}</span></td></tr>; })}</tbody></table></div>
        : <Empty>No assets here.</Empty>}</Panel>
    </>}
  </>;
}

// ---------------------------------------------------------------- Import assets from a spreadsheet
const IMPORT_COLS = ['Name', 'Category', 'Tag', 'Serial', 'Manufacturer', 'Model', 'Location', 'Purchase date', 'Cost', 'Warranty until', 'Order number', 'Accumulated depreciation', 'Notes'];
export function AssetImportPage() {
  const { cid, can } = useSession();
  const act = useAction();
  const [rows, setRows] = useState<any[] | null>(null);
  const [funding, setFunding] = useState('capital');
  const [done, setDone] = useState<string[] | null>(null);
  const { data } = useLoad(async () => {
    const [cats, locs] = await Promise.all([
      q<any[]>(supabase.from('asset_categories').select('id,name').eq('company_id', cid) as any),
      q<any[]>(supabase.from('asset_locations').select('id,name').eq('company_id', cid) as any),
    ]);
    return { cats, locs };
  }, [cid]);
  const read = (file: File) => act.run(async () => {
    const grid = await readSheet(file);
    if (grid.length < 2) throw new Error('The file has no rows.');
    const h = grid[0].map(x => String(x).trim().toLowerCase());
    const col = (name: string) => h.findIndex(x => x === name.toLowerCase() || x.replace(/[^a-z]/g, '') === name.toLowerCase().replace(/[^a-z]/g, ''));
    const get = (r: string[], n: string) => { const i = col(n); return i < 0 ? '' : String(r[i] ?? '').trim(); };
    if (col('Name') < 0 || col('Cost') < 0) throw new Error('The first row needs at least the headings Name and Cost.');
    setDone(null);
    setRows(grid.slice(1).filter(r => r.some(c => String(c).trim())).map((r, i) => {
      const cat = data?.cats.find(c => c.name.toLowerCase() === get(r, 'Category').toLowerCase());
      const loc = data?.locs.find(l => l.name.toLowerCase() === get(r, 'Location').toLowerCase());
      const cost = toNum(get(r, 'Cost')), pd = toIsoDate(get(r, 'Purchase date')), wd = get(r, 'Warranty until') ? toIsoDate(get(r, 'Warranty until')) : null, accd = toNum(get(r, 'Accumulated depreciation'));
      const problems = [!get(r, 'Name') && 'no name', !(cost && cost > 0) && 'no cost', !pd && 'purchase date missing or unreadable', get(r, 'Category') && !cat && `category "${get(r, 'Category')}" not found`,
        get(r, 'Warranty until') && !wd && 'warranty date unreadable', Number.isNaN(accd) && 'depreciation unreadable'].filter(Boolean);
      return { line: i + 2, name: get(r, 'Name'), category_id: cat?.id || data?.cats[0]?.id || '', tag: get(r, 'Tag'), serial_no: get(r, 'Serial'), manufacturer: get(r, 'Manufacturer'), model: get(r, 'Model'),
        location: get(r, 'Location'), location_id: loc?.id || null, newLoc: get(r, 'Location') && !loc ? get(r, 'Location') : '', purchase_date: pd, cost, warranty_until: wd, order_number: get(r, 'Order number'), opening_depreciation: accd || 0, notes: get(r, 'Notes'), problems };
    }));
  });
  const run = () => act.run(async () => {
    const good = (rows || []).filter(r => !r.problems.length);
    const out: string[] = [];
    const locIds: Record<string, string> = Object.fromEntries((data?.locs || []).map(l => [l.name.toLowerCase(), l.id]));
    for (const r of good) {
      try {
        if (r.newLoc && !locIds[r.newLoc.toLowerCase()]) {
          const l = await q<any>(supabase.from('asset_locations').insert({ company_id: cid, name: r.newLoc, kind: 'other' }).select('id').single() as any);
          locIds[r.newLoc.toLowerCase()] = l.id;
        }
        const id = await rpc<string>('register_asset', { cid, p_funding: funding, p: { name: r.name, category_id: r.category_id, tag: r.tag, serial_no: r.serial_no, location: r.location, purchase_date: r.purchase_date, cost: r.cost, warranty_until: r.warranty_until, opening_depreciation: r.opening_depreciation, notes: r.notes } });
        await q(supabase.from('assets').update({ manufacturer: r.manufacturer || null, model: r.model || null, order_number: r.order_number || null, location_id: r.location ? locIds[r.location.toLowerCase()] || null : null }).eq('id', id) as any);
        out.push(`Row ${r.line}: ${r.name} registered`);
      } catch (e: any) { out.push(`Row ${r.line}: ${r.name} — ${e.message}`); }
    }
    setDone(out); setRows(null);
  });
  if (!can('accountant')) return <><PageHead title="Import assets" /><Panel pad><p className="muted" style={{ margin: 0 }}>Only Finance or an admin can import assets, because each one is posted to the books.</p></Panel></>;
  return <>
    <PageHead title="Import assets" sub="Bring your existing register in from Excel or CSV. Each row is registered and posted to the fixed asset accounts.">
      <button className="btn" type="button" onClick={() => downloadCsv('asset-import-template', IMPORT_COLS, [['Dell Latitude 5440', 'Computers and IT equipment', '', 'SN12345', 'Dell', 'Latitude 5440', 'Head office', '2025-03-14', '14500', '2028-03-13', 'PO-00123', '2400', '']])}>Download template</button>
    </PageHead>
    <Panel pad>
      <div className="grid-form">
        <div className="field"><label htmlFor="im-f">Spreadsheet (.xlsx or .csv)</label><input id="im-f" type="file" accept=".csv,.xlsx,.xls" onChange={e => { const f = e.target.files?.[0]; if (f) read(f); e.target.value = ''; }} /></div>
        <Select label="How these were paid for" id="im-fund" value={funding} onChange={setFunding} options={[['capital', "Already owned (opening balance)"], ['none', 'Already in the books'], ['ap', 'Owed to suppliers'], ['bank', 'Paid from bank']]} />
      </div>
      <p className="muted" style={{ fontSize: 13, marginBottom: 0 }}>Headings: {IMPORT_COLS.join(', ')}. Only Name, Cost and Purchase date are required. Unknown locations are created. Category names must match your asset categories (blank uses the first one). Leave Tag blank to number automatically.</p>
    </Panel>
    {rows && <Panel title={`${rows.length} rows read · ${rows.filter(r => !r.problems.length).length} ready`} actions={<button className="btn primary" type="button" disabled={act.busy || !rows.some(r => !r.problems.length)} onClick={run}>{act.busy ? 'Importing…' : `Import ${rows.filter(r => !r.problems.length).length}`}</button>}>
      <div className="scroll"><table><thead><tr><th>Row</th><th>Asset</th><th>Location</th><th>Purchased</th><th className="r">Cost</th><th>Check</th></tr></thead>
        <tbody>{rows.map(r => <tr key={r.line}><td className="num">{r.line}</td><td>{r.name}<br /><span className="muted">{[r.tag, r.manufacturer, r.model, r.serial_no].filter(Boolean).join(' · ')}</span></td>
          <td>{r.location}{r.newLoc && <span className="pill"> new</span>}</td><td className="num">{r.purchase_date}</td><td className="r num">{money(r.cost)}</td>
          <td>{r.problems.length ? <span className="pill bad">{r.problems.join('; ')}</span> : <span className="pill good">OK</span>}</td></tr>)}</tbody></table></div>
    </Panel>}
    {done && <Panel title="Result"><ul className="body" style={{ margin: 0 }}>{done.map((d, i) => <li key={i}>{d}</li>)}</ul></Panel>}
  </>;
}

// ---------------------------------------------------------------- Telegram alerts
const TG_EVENTS: [string, string][] = [['transfer', 'Transfers sent, received, rejected'], ['request', 'New asset and vehicle requests'], ['decision', 'Approvals and declines'], ['low_stock', 'Low stock'], ['fleet', 'Fleet: dispatches, deliveries, fuel flags, expiring documents']];
export function TelegramPanel() {
  const { cid, can } = useSession();
  const act = useAction();
  const [f, setF] = useState<any | null>(null);
  const { data, reload } = useLoad(() => q<any>(supabase.from('company_telegram').select('*').eq('company_id', cid).maybeSingle() as any).catch(() => null), [cid]);
  if (!can()) return null;
  const cur = f || { bot_token: data?.bot_token || '', chat_id: data?.chat_id || '', events: data?.events || TG_EVENTS.map(e => e[0]), enabled: data?.enabled ?? false };
  const save = () => act.run(async () => {
    await q(supabase.from('company_telegram').upsert({ company_id: cid, bot_token: cur.bot_token.trim() || null, chat_id: cur.chat_id.trim() || null, events: cur.events, enabled: cur.enabled, updated_at: new Date().toISOString() }) as any);
    setF(null); reload();
  }, 'Saved');
  return <Panel title="Telegram alerts" pad>
    <p className="muted" style={{ marginTop: 0 }}>Send asset and fleet alerts to a Telegram group as well as in Asnys. In Telegram, talk to <b>@BotFather</b>, send <code>/newbot</code> and copy the token; add the bot to your group, then get the group's chat id (it starts with -100). In Supabase, turn on the <b>pg_net</b> extension (Database → Extensions).</p>
    <div className="grid-form">
      <Field label="Bot token" id="tg-t" value={cur.bot_token} onChange={v => setF({ ...cur, bot_token: v })} placeholder="123456789:AA…" />
      <Field label="Chat id" id="tg-c" value={cur.chat_id} onChange={v => setF({ ...cur, chat_id: v })} placeholder="-1001234567890" />
    </div>
    <div style={{ display: 'grid', gap: 4, margin: '10px 0' }}>{TG_EVENTS.map(([k, l]) => <label key={k} className="check"><input type="checkbox" checked={cur.events.includes(k)} onChange={e => setF({ ...cur, events: e.target.checked ? [...cur.events, k] : cur.events.filter((x: string) => x !== k) })} /> {l}</label>)}</div>
    <label className="check"><input type="checkbox" checked={cur.enabled} onChange={e => setF({ ...cur, enabled: e.target.checked })} /> <b>Send alerts</b></label>
    <div className="actions" style={{ marginTop: 10 }}>
      <button className="btn primary" type="button" disabled={act.busy} onClick={save}>Save</button>
      {data?.enabled && <ConfirmButton label="Send a test message" confirm="Send a test message to the Telegram chat now?" onConfirm={() => act.run(async () => { await rpc('test_telegram', { cid }); }, 'Test sent. If nothing arrives within a minute, check the token and chat id.')} />}
    </div>
  </Panel>;
}
export function AssetSettingsPage() {
  return <>
    <PageHead title="Asset and fleet alerts" sub="Who is told about what, and where." />
    <TelegramPanel />
    <Panel pad><p className="muted" style={{ margin: 0 }}>In-app alerts always go to the people concerned: location managers for transfers and site requests, the storekeeper for low stock and head-office requests, and transport officers for the fleet. Tick transport officers in Settings → Team.</p></Panel>
  </>;
}
