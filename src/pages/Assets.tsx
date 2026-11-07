import { useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import { q, rpc, supabase } from '../lib/supabase';
import { useSession } from '../lib/session';
import { cedis, longDate, money, today } from '../lib/format';
import { downloadCsv } from '../lib/download';
import { tablePdf } from '../lib/pdf';
import { Downloads, Empty, Field, FormModal, Loading, PageHead, Panel, Select, Status, useAction, useLoad } from '../components/ui';
import { ASSET_FILTERS, ASSET_STATES, AssetOps, StatePill, holderText, labelsPdf } from './AssetOps';

const FUNDING: [string, string][] = [
  ['bank', 'Paid from bank'], ['momo', 'Paid from Mobile Money'], ['cash', 'Paid in cash'], ['ap', 'Owed to the supplier'],
  ['capital', "Owner's contribution or opening balance"], ['none', 'Already in the books (e.g. a bill posted to 1600)'],
];
const nbv = (a: any) => Number(a.cost) - Number(a.accumulated_depreciation);
const methodText = (a: any) => (a.method === 'straight_line' ? `Straight line, ${a.useful_life_months} months` : `Reducing balance, ${Math.round(Number(a.annual_rate) * 100)}% a year`);

export function AssetsPage() {
  const { cid, company, can } = useSession();
  const act = useAction();
  const [show, setShow] = useState('active');
  const [search, setSearch] = useState('');
  const [busyLabels, setBusyLabels] = useState(false);
  const [reg, setReg] = useState<any | null>(null);
  const [dep, setDep] = useState<string | null>(null);
  const [cats, setCats] = useState(false);
  const { data, error, loading, reload } = useLoad(async () => {
    const [assets, categories, staff] = await Promise.all([
      q<any[]>(supabase.from('assets').select('*, category:asset_categories(name), custodian:employees(full_name), project:projects!assets_holder_project_fkey(number,name)').eq('company_id', cid).order('tag') as any),
      q<any[]>(supabase.from('asset_categories').select('*').eq('company_id', cid).order('name') as any),
      q<any[]>(supabase.from('employees').select('id,full_name').eq('company_id', cid).eq('status', 'active').order('full_name') as any).catch(() => []),
    ]);
    return { assets, categories, staff };
  }, [cid]);
  const filt = (ASSET_FILTERS.find(f => f[0] === show) || ASSET_FILTERS[0]);
  const list = (data?.assets || []).filter(filt[2])
    .filter(a => !search || `${a.tag} ${a.name} ${a.serial_no || ''} ${a.location || ''} ${holderText(a)}`.toLowerCase().includes(search.toLowerCase()));
  const sum = (f: (a: any) => number) => list.reduce((s, a) => s + f(a), 0);
  const head = ['Tag', 'Asset', 'Category', 'Serial no.', 'Location', 'With', 'Purchased', 'Cost (GHS)', 'Acc. depreciation', 'Book value', 'Status'];
  const rows = list.map(a => [a.tag, a.name, a.category?.name || '', a.serial_no || '', a.location || '', holderText(a), a.purchase_date, money(a.cost), money(a.accumulated_depreciation), money(nbv(a)), a.status === 'active' ? (ASSET_STATES[a.state] || [a.state])[0] : a.status]);
  const foot = ['', 'Totals', '', '', '', '', '', money(sum(a => Number(a.cost))), money(sum(a => Number(a.accumulated_depreciation))), money(sum(nbv)), ''];

  const save = () => act.run(async () => {
    const p = { ...reg, cost: Number(reg.cost), salvage_value: Number(reg.salvage_value) || 0, opening_depreciation: Number(reg.opening_depreciation) || 0 };
    if (!(p.cost > 0)) throw new Error('Enter the cost.');
    await rpc('register_asset', { cid, p, p_funding: reg.funding });
    setReg(null); reload();
  }, 'Asset registered');

  return <>
    <PageHead title="Asset register" sub={data ? `${data.assets.filter(a => a.status === 'active').length} in use · cost ${cedis(sum(a => Number(a.cost)))} · book value ${cedis(sum(nbv))}` : undefined}>
      <Downloads pdf={() => tablePdf({ company: company!, title: 'Fixed asset register', subtitle: longDate(today()), head, body: rows, foot, rightAlign: [7, 8, 9], landscape: true, filename: 'asset-register-' + today() })}
        csv={() => downloadCsv('asset-register-' + today(), head, [...rows, foot])} />
      <button className="btn" type="button" disabled={busyLabels || !list.length} title="A4 sheet of QR labels for the assets listed" onClick={() => { setBusyLabels(true); act.run(() => labelsPdf(company!, list)).finally(() => setBusyLabels(false)); }}>{busyLabels ? 'Making labels…' : `QR labels (${list.length})`}</button>
      {can('accountant') && <>
        <button className="btn" type="button" onClick={() => setCats(true)}>Categories</button>
        <button className="btn" type="button" onClick={() => setDep(today().slice(0, 7))}>Run depreciation</button>
        <button className="btn primary" type="button" onClick={() => setReg({ name: '', category_id: data?.categories[0]?.id || '', serial_no: '', location: '', custodian_id: '', purchase_date: today(), in_service_date: '', cost: '', salvage_value: '', opening_depreciation: '', warranty_until: '', notes: '', funding: 'bank', method: '', useful_life_months: '', annual_rate: '' })}>Register asset</button></>}
    </PageHead>
    {data && <div className="chips">{ASSET_FILTERS.map(([k, l, fn]) => { const n = data.assets.filter(fn).length; return (n > 0 || ['active', 'all'].includes(k) || show === k) && <button key={k} type="button" className={'chip' + (show === k ? ' on' : '')} onClick={() => setShow(k)}>{l} <span>{n}</span></button>; })}</div>}
    <div className="filters">
      <div className="field" style={{ width: 260 }}><label htmlFor="as-search">Search</label><input id="as-search" placeholder="Tag, name, serial, location, person" value={search} onChange={e => setSearch(e.target.value)} /></div>
    </div>
    <Loading error={error} loading={loading && !data} />
    {data && <Panel>{list.length ? <div className="scroll"><table>
      <thead><tr><th>Tag</th><th>Asset</th><th>Location / custodian</th><th className="r">Cost (GH₵)</th><th className="r">Book value</th><th>Status</th></tr></thead>
      <tbody>{list.map(a => <tr key={a.id}>
        <td className="num"><Link to={'/assets/' + a.id}>{a.tag}</Link></td>
        <td><b>{a.name}</b><br /><span className="muted">{a.category?.name}{a.serial_no ? ' · ' + a.serial_no : ''}</span></td>
        <td>{a.location || '—'}<br /><span className="muted">{holderText(a)}{a.state === 'deployed' && a.expected_return ? ` · back by ${a.expected_return}` : ''}</span></td>
        <td className="r num">{money(a.cost)}</td><td className="r num">{money(nbv(a))}</td><td>{a.status === 'active' ? <StatePill s={a.state} /> : <Status s={a.status} />}{a.status === 'active' && a.next_audit && a.next_audit < today() && <><br /><span className="pill bad" style={{ fontSize: 11 }}>audit overdue</span></>}</td></tr>)}</tbody>
      <tfoot><tr><td></td><td>Totals</td><td></td><td className="r num">{money(sum(a => Number(a.cost)))}</td><td className="r num">{money(sum(nbv))}</td><td></td></tr></tfoot>
    </table></div> : <Empty>{data.assets.length ? 'No assets match.' : 'No assets yet. Register your computers, vehicles, furniture and machinery.'}</Empty>}</Panel>}
    <p className="muted" style={{ margin: 0 }}>Depreciation here is for your books. Ghana tax uses separate capital allowance rates in the Income Tax Act, worked out on your tax return.</p>

    {reg && data && <FormModal title="Register asset" submit="Register and post" busy={act.busy} onClose={() => setReg(null)} onSave={save}>
      <Field label="Asset name" id="ra-name" value={reg.name} onChange={v => setReg({ ...reg, name: v })} placeholder="e.g. Toyota Hilux GR-1234-24" required />
      <div className="grid-form">
        <Select label="Category" id="ra-cat" value={reg.category_id} onChange={v => setReg({ ...reg, category_id: v })} options={data.categories.map(c => [c.id, c.name])} />
        <Field label="Serial or registration no." id="ra-serial" value={reg.serial_no} onChange={v => setReg({ ...reg, serial_no: v })} />
        <Field label="Location" id="ra-loc" value={reg.location} onChange={v => setReg({ ...reg, location: v })} placeholder="e.g. Tema warehouse" />
        <Select label="Custodian" id="ra-cust" value={reg.custodian_id} onChange={v => setReg({ ...reg, custodian_id: v })} options={[['', 'Nobody'], ...data.staff.map(s => [s.id, s.full_name] as [string, string])]} />
        <Field label="Purchase date" id="ra-pdate" type="date" value={reg.purchase_date} onChange={v => setReg({ ...reg, purchase_date: v })} required />
        <Field label="In service from (if later)" id="ra-sdate" type="date" value={reg.in_service_date} onChange={v => setReg({ ...reg, in_service_date: v })} />
        <Field label="Cost (GH₵)" id="ra-cost" type="number" step="0.01" min="0.01" value={reg.cost} onChange={v => setReg({ ...reg, cost: v })} required />
        <Field label="Residual value (GH₵)" id="ra-salv" type="number" step="0.01" min="0" value={reg.salvage_value} onChange={v => setReg({ ...reg, salvage_value: v })} />
        <Field label="Warranty until" id="ra-war" type="date" value={reg.warranty_until} onChange={v => setReg({ ...reg, warranty_until: v })} />
        <Select label="How it was paid for" id="ra-fund" value={reg.funding} onChange={v => setReg({ ...reg, funding: v })} options={FUNDING} />
      </div>
      <details><summary className="muted" style={{ cursor: 'pointer' }}>Different depreciation, or an asset you already owned</summary>
        <div className="grid-form" style={{ marginTop: 10 }}>
          <Select label="Method" id="ra-meth" value={reg.method} onChange={v => setReg({ ...reg, method: v })} options={[['', 'Use the category default'], ['straight_line', 'Straight line'], ['reducing_balance', 'Reducing balance']]} />
          {reg.method === 'straight_line' && <Field label="Useful life (months)" id="ra-life" type="number" step="1" min="1" value={reg.useful_life_months} onChange={v => setReg({ ...reg, useful_life_months: v })} />}
          {reg.method === 'reducing_balance' && <Field label="Annual rate (e.g. 0.25 for 25%)" id="ra-rate" type="number" step="0.01" min="0.01" max="1" value={reg.annual_rate} onChange={v => setReg({ ...reg, annual_rate: v })} />}
          <Field label="Depreciation already charged (GH₵)" id="ra-open" type="number" step="0.01" min="0" value={reg.opening_depreciation} onChange={v => setReg({ ...reg, opening_depreciation: v })} />
        </div>
        <p className="muted" style={{ fontSize: 13 }}>For an asset you already owned, enter its original cost and the depreciation charged so far, and choose "Owner's contribution or opening balance". It then depreciates from next month.</p>
      </details>
      <Field label="Notes" id="ra-notes" value={reg.notes} onChange={v => setReg({ ...reg, notes: v })} />
    </FormModal>}

    {dep && <FormModal title="Run depreciation" submit="Post depreciation" busy={act.busy} onClose={() => setDep(null)}
      onSave={() => act.run(async () => { const v = await rpc<number>('run_depreciation', { cid, p_period: dep + '-01' }); setDep(null); reload(); if (!Number(v)) throw new Error('Nothing to depreciate: every asset is already up to date for that month.'); }, 'Depreciation posted')}>
      <p className="muted" style={{ margin: 0 }}>Charges depreciation for every month up to the one you choose that has not been charged yet, in one journal entry. Running it twice does not double-charge.</p>
      <div className="field" style={{ maxWidth: 200 }}><label htmlFor="dp-month">Up to and including</label><input id="dp-month" type="month" value={dep} onChange={e => setDep(e.target.value)} /></div>
    </FormModal>}

    {cats && data && <CategoriesModal cid={cid} categories={data.categories} onClose={() => { setCats(false); reload(); }} />}
  </>;
}

function CategoriesModal({ cid, categories, onClose }: { cid: string; categories: any[]; onClose: () => void }) {
  const act = useAction();
  const [edit, setEdit] = useState<any>({ name: '', method: 'straight_line', useful_life_months: '60', annual_rate: '' });
  return <FormModal title="Asset categories" submit="Add category" busy={act.busy} onClose={onClose}
    onSave={() => act.run(async () => {
      await q(supabase.from('asset_categories').insert({ company_id: cid, name: edit.name, method: edit.method,
        useful_life_months: edit.method === 'straight_line' ? Number(edit.useful_life_months) : null, annual_rate: edit.method === 'reducing_balance' ? Number(edit.annual_rate) : null }) as any);
      onClose();
    }, 'Category added')}>
    <div className="scroll"><table><thead><tr><th>Category</th><th>Default depreciation</th></tr></thead>
      <tbody>{categories.map(c => <tr key={c.id}><td>{c.name}</td><td>{c.method === 'straight_line' ? `Straight line, ${c.useful_life_months / 12} years` : `Reducing balance, ${Math.round(c.annual_rate * 100)}%`}</td></tr>)}</tbody></table></div>
    <div className="label">New category</div>
    <div className="grid-form">
      <Field label="Name" id="ac2-name" value={edit.name} onChange={v => setEdit({ ...edit, name: v })} required />
      <Select label="Method" id="ac2-meth" value={edit.method} onChange={v => setEdit({ ...edit, method: v })} options={[['straight_line', 'Straight line'], ['reducing_balance', 'Reducing balance']]} />
      {edit.method === 'straight_line'
        ? <Field label="Useful life (months)" id="ac2-life" type="number" step="1" min="1" value={edit.useful_life_months} onChange={v => setEdit({ ...edit, useful_life_months: v })} required />
        : <Field label="Annual rate (0.25 = 25%)" id="ac2-rate" type="number" step="0.01" min="0.01" max="1" value={edit.annual_rate} onChange={v => setEdit({ ...edit, annual_rate: v })} required />}
    </div>
  </FormModal>;
}

export function AssetView() {
  const { id } = useParams();
  const { company, can, cid } = useSession();
  const act = useAction();
  const [move, setMove] = useState<any | null>(null);
  const [maint, setMaint] = useState<any | null>(null);
  const [disp, setDisp] = useState<any | null>(null);
  const { data, error, loading, reload } = useLoad(async () => {
    const a = await q<any>(supabase.from('assets').select('*, category:asset_categories(name), custodian:employees(full_name), supplier:suppliers(name), project:projects!assets_holder_project_fkey(id,number,name)').eq('id', id).single() as any);
    const [deps, moves, maints, staff] = await Promise.all([
      q<any[]>(supabase.from('asset_depreciation').select('*').eq('asset_id', id).order('period') as any),
      q<any[]>(supabase.from('asset_movements').select('*, from:employees!asset_movements_from_custodian_fkey(full_name), to:employees!asset_movements_to_custodian_fkey(full_name)').eq('asset_id', id).order('move_date', { ascending: false }) as any),
      q<any[]>(supabase.from('asset_maintenance').select('*').eq('asset_id', id).order('service_date', { ascending: false }) as any),
      q<any[]>(supabase.from('employees').select('id,full_name').eq('company_id', cid).eq('status', 'active').order('full_name') as any).catch(() => []),
    ]);
    return { a, deps, moves, maints, staff };
  }, [id]);
  if (!data) return <Loading error={error} loading={loading} />;
  const { a, deps, moves, maints, staff } = data;
  const depHead = ['Month', 'Depreciation (GHS)', 'Accumulated', 'Book value'];
  let acc = Number(a.accumulated_depreciation) - deps.reduce((s, d) => s + Number(d.amount), 0);
  const depRows = deps.map(d => { acc += Number(d.amount); return [d.period.slice(0, 7), money(d.amount), money(acc), money(Number(a.cost) - acc)]; });
  const mHead = ['Date', 'Work done', 'Vendor', 'Cost (GHS)', 'Next due'];
  const mRows = maints.map(m => [m.service_date, m.description, m.vendor || '', money(m.cost), m.next_due || '']);

  return <>
    <PageHead title={`${a.tag} · ${a.name}`} sub={<>{a.status === 'active' ? <StatePill s={a.state} /> : <Status s={a.status} />} <span className="muted">· {a.category?.name} · {methodText(a)}</span></>}>
      <Link className="btn" to="/assets">Back</Link>
      <AssetOps a={a} staff={staff} onDone={reload} />
      <Downloads pdf={() => tablePdf({ company: company!, title: `Depreciation: ${a.tag} ${a.name}`, head: depHead, body: depRows, rightAlign: [1, 2, 3], filename: `depreciation-${a.tag}`,
        notes: `Cost GHS ${money(a.cost)}, residual GHS ${money(a.salvage_value)}. ${methodText(a)}. Purchased ${longDate(a.purchase_date)}${a.location ? ', located at ' + a.location : ''}.` })} />
      {a.status === 'active' && can('hr', 'accountant') && <button className="btn" type="button" onClick={() => setMove({ date: today(), location: a.location || '', custodian: a.custodian_id || '', note: '' })}>Move or reassign</button>}
      {a.status === 'active' && <button className="btn" type="button" onClick={() => setMaint({ service_date: today(), description: '', vendor: '', cost: '', next_due: '' })}>Log maintenance</button>}
      {a.status === 'active' && can('accountant') && <button className="btn primary" type="button" onClick={() => setDisp({ date: today(), proceeds: '', method: 'bank' })}>Sell or write off</button>}
    </PageHead>
    <div className="tiles">
      <div className="tile"><span>Cost</span><b>{cedis(a.cost)}</b></div>
      <div className="tile"><span>Accumulated depreciation</span><b>{cedis(a.accumulated_depreciation)}</b></div>
      <div className="tile"><span>Book value</span><b>{cedis(nbv(a))}</b></div>
      <div className="tile"><span>{a.status === 'active' ? 'Depreciated to' : 'Disposed'}</span><b style={{ fontSize: 16 }}>{a.status === 'active' ? (a.last_depreciated ? a.last_depreciated.slice(0, 7) : 'Not yet') : `${longDate(a.disposal_date)} for ${money(a.disposal_proceeds)}`}</b></div>
    </div>
    <Panel pad><div className="grid-form">
      <div><div className="label">Serial / registration</div>{a.serial_no || '—'}</div>
      <div><div className="label">Location</div>{a.location || '—'}</div>
      <div><div className="label">With</div>{a.custodian?.full_name || (a.project ? <Link to={'/projects/' + a.project.id}>{a.project.number} {a.project.name}</Link> : '—')}{a.expected_return ? <span className={a.expected_return < today() ? 'pill bad' : 'muted'}> back by {a.expected_return}</span> : null}</div>
      <div><div className="label">Audit</div>{a.last_audit ? `Last ${a.last_audit}` : 'Never audited'}{a.next_audit ? <> · next <span className={a.next_audit < today() ? 'pill bad' : ''}>{a.next_audit}</span></> : ''}</div>
      <div><div className="label">Staff can request it</div>{a.requestable ? 'Yes' : 'No'}</div>
      <div><div className="label">Supplier</div>{a.supplier?.name || '—'}</div>
      <div><div className="label">Purchased</div>{longDate(a.purchase_date)}</div>
      <div><div className="label">Warranty</div>{a.warranty_until ? longDate(a.warranty_until) + (a.warranty_until < today() ? ' (expired)' : '') : '—'}</div>
    </div>{a.notes && <p className="muted">{a.notes}</p>}</Panel>
    <div className="two">
      <Panel title="Depreciation history" actions={<button className="btn small" type="button" onClick={() => downloadCsv(`depreciation-${a.tag}`, depHead, depRows)}>CSV</button>}>
        {deps.length ? <div className="scroll"><table><thead><tr>{depHead.map((h, i) => <th key={h} className={i ? 'r' : ''}>{h.replace('GHS', 'GH₵')}</th>)}</tr></thead>
          <tbody>{depRows.map((r, i) => <tr key={i}>{r.map((c, j) => <td key={j} className={'num' + (j ? ' r' : '')}>{c}</td>)}</tr>)}</tbody></table></div> : <Empty>No depreciation charged yet.</Empty>}
      </Panel>
      <div style={{ display: 'grid', gap: 16, alignContent: 'start' }}>
        <Panel title="Movements">{moves.length ? <div className="scroll"><table><tbody>{moves.map(m => <tr key={m.id}>
          <td className="num">{m.move_date}</td><td className="wrap-cell"><b style={{ fontWeight: 600 }}>{({ checkout: 'Checked out', checkin: 'Checked in', move: 'Moved', audit: 'Audited', status: 'Status' } as any)[m.kind] || 'Moved'}</b>{m.state_after && m.kind !== 'checkout' ? ` · ${(ASSET_STATES[m.state_after] || [m.state_after])[0]}` : ''} · {[m.to_location, m.to?.full_name].filter(Boolean).join(' · ') || '—'}{m.note && <><br /><span className="muted">{m.note}</span></>}</td></tr>)}</tbody></table></div> : <Empty>None.</Empty>}</Panel>
        <Panel title="Maintenance" actions={mRows.length > 0 && <Downloads pdf={() => tablePdf({ company: company!, title: `Maintenance log: ${a.tag} ${a.name}`, head: mHead, body: mRows, rightAlign: [3], filename: `maintenance-${a.tag}` })} />}>
          {maints.length ? <div className="scroll"><table><tbody>{maints.map(m => <tr key={m.id}>
            <td className="num">{m.service_date}</td><td className="wrap-cell">{m.description}<br /><span className="muted">{[m.vendor, m.next_due && 'next due ' + m.next_due].filter(Boolean).join(' · ')}</span></td>
            <td className="r num">{money(m.cost)}</td></tr>)}</tbody></table></div> : <Empty>No maintenance logged.</Empty>}
        </Panel>
      </div>
    </div>

    {move && <FormModal title="Move or reassign" busy={act.busy} onClose={() => setMove(null)}
      onSave={() => act.run(async () => { await rpc('move_asset', { p_asset: id, p_date: move.date, p_location: move.location || null, p_custodian: move.custodian || null, p_note: move.note || null }); setMove(null); reload(); }, 'Asset moved')}>
      <div className="grid-form">
        <Field label="Date" id="mv-date" type="date" value={move.date} onChange={v => setMove({ ...move, date: v })} required />
        <Field label="New location" id="mv-loc" value={move.location} onChange={v => setMove({ ...move, location: v })} />
        <Select label="New custodian" id="mv-cust" value={move.custodian} onChange={v => setMove({ ...move, custodian: v })} options={[['', 'Nobody'], ...staff.map(s => [s.id, s.full_name] as [string, string])]} />
      </div>
      <Field label="Note" id="mv-note" value={move.note} onChange={v => setMove({ ...move, note: v })} />
    </FormModal>}
    {maint && <FormModal title="Log maintenance" busy={act.busy} onClose={() => setMaint(null)}
      onSave={() => act.run(async () => { await q(supabase.from('asset_maintenance').insert({ company_id: a.company_id, asset_id: id, service_date: maint.service_date, description: maint.description, vendor: maint.vendor || null, cost: Number(maint.cost) || 0, next_due: maint.next_due || null }) as any); setMaint(null); reload(); }, 'Maintenance logged')}>
      <Field label="Work done" id="mt-desc" value={maint.description} onChange={v => setMaint({ ...maint, description: v })} placeholder="e.g. 10,000 km service, new tyres" required />
      <div className="grid-form">
        <Field label="Date" id="mt-date" type="date" value={maint.service_date} onChange={v => setMaint({ ...maint, service_date: v })} required />
        <Field label="Vendor" id="mt-vendor" value={maint.vendor} onChange={v => setMaint({ ...maint, vendor: v })} />
        <Field label="Cost (GH₵)" id="mt-cost" type="number" step="0.01" min="0" value={maint.cost} onChange={v => setMaint({ ...maint, cost: v })} />
        <Field label="Next service due" id="mt-next" type="date" value={maint.next_due} onChange={v => setMaint({ ...maint, next_due: v })} />
      </div>
      <p className="muted" style={{ margin: 0, fontSize: 13 }}>This is a log only. Record the payment as a supplier bill to 6500 Repairs and maintenance.</p>
    </FormModal>}
    {disp && <FormModal title={`Sell or write off ${a.tag}`} submit="Post disposal" busy={act.busy} onClose={() => setDisp(null)}
      onSave={() => act.run(async () => { await rpc('dispose_asset', { p_asset: id, p_date: disp.date, p_proceeds: Number(disp.proceeds) || 0, p_method: disp.method }); setDisp(null); reload(); }, 'Disposal posted')}>
      <p className="muted" style={{ margin: 0 }}>Depreciation is brought up to the month before the disposal date first. Book value is then compared with the proceeds and any gain or loss is posted to 4850.</p>
      <div className="grid-form">
        <Field label="Date" id="dsp-date" type="date" value={disp.date} onChange={v => setDisp({ ...disp, date: v })} required />
        <Field label="Sale proceeds (GH₵, 0 to write off)" id="dsp-amt" type="number" step="0.01" min="0" value={disp.proceeds} onChange={v => setDisp({ ...disp, proceeds: v })} />
        {Number(disp.proceeds) > 0 && <Select label="Received into" id="dsp-m" value={disp.method} onChange={v => setDisp({ ...disp, method: v })} options={[['bank', 'Bank'], ['momo', 'Mobile Money'], ['cash', 'Cash']]} />}
      </div>
      <p className="muted" style={{ margin: 0, fontSize: 13 }}>Current book value: {cedis(nbv(a))} (before this month's depreciation).</p>
    </FormModal>}
  </>;
}
