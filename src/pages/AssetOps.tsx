import { useState } from 'react';
import { Link } from 'react-router-dom';
import QRCode from 'qrcode';
import { jsPDF } from 'jspdf';
import { q, rpc, supabase } from '../lib/supabase';
import { useSession, type Company } from '../lib/session';
import { longDate, money, today } from '../lib/format';
import { downloadCsv } from '../lib/download';
import { tablePdf } from '../lib/pdf';
import { Downloads, Empty, Field, FormModal, Loading, PageHead, Panel, Select, useAction, useLoad } from '../components/ui';
import { SendTransferModal, locOpts } from './AssetMore';

/** Day-to-day state of an asset (separate from its accounting status: in use, disposed, written off). */
export const ASSET_STATES: Record<string, [string, string]> = {
  ready: ['Ready to deploy', 'good'], deployed: ['Deployed', ''], pending: ['Pending', 'warn'], repair: ['Out for repair', 'warn'],
  broken: ['Broken', 'bad'], lost: ['Lost or stolen', 'bad'], archived: ['Archived', ''], transit: ['In transit', 'warn'],
};
export const StatePill = ({ s }: { s: string }) => { const [l, c] = ASSET_STATES[s] || [s, '']; return <span className={'pill ' + c}>{l}</span>; };
export const holderText = (a: any) => a.custodian?.full_name || (a.project ? `${a.project.number || ''} ${a.project.name}`.trim() : '') || '';
const soon = (d: number) => new Date(Date.now() + d * 864e5).toISOString().slice(0, 10);
export const ASSET_FILTERS: [string, string, (a: any) => boolean][] = [
  ['active', 'In use', a => a.status === 'active'],
  ['deployed', 'Deployed', a => a.state === 'deployed'],
  ['ready', 'Ready to deploy', a => a.status === 'active' && a.state === 'ready'],
  ['pending', 'Pending', a => a.state === 'pending'],
  ['transit', 'In transit', a => a.state === 'transit'],
  ['undeployable', 'Repair or broken', a => ['repair', 'broken'].includes(a.state)],
  ['lost', 'Lost or stolen', a => a.state === 'lost'],
  ['overdue', 'Overdue back', a => a.state === 'deployed' && a.expected_return && a.expected_return < today()],
  ['auditdue', 'Due for audit', a => a.status === 'active' && a.state !== 'archived' && a.next_audit && a.next_audit <= soon(30)],
  ['requestable', 'Requestable', a => a.requestable && a.status === 'active'],
  ['gone', 'Disposed', a => a.status !== 'active'],
  ['all', 'All', () => true],
];

/** A4 sheet of 24 labels (3 × 8), each with a QR code that opens the asset in Asnys. */
export async function labelsPdf(company: Company, assets: any[]) {
  if (!assets.length) throw new Error('No assets to label.');
  const doc = new jsPDF({ unit: 'mm', format: 'a4' });
  const W = 63.5, H = 33.9, X0 = 7.2, Y0 = 12.9, GAP = 2.5;
  for (let i = 0; i < assets.length; i++) {
    const a = assets[i], k = i % 24;
    if (i && !k) doc.addPage();
    const x = X0 + (k % 3) * (W + GAP), y = Y0 + Math.floor(k / 3) * H;
    const url = `${window.location.origin}/assets/${a.id}`;
    const png = await QRCode.toDataURL(url, { margin: 0, width: 240, errorCorrectionLevel: 'M' });
    doc.setDrawColor(220); doc.roundedRect(x, y + 1, W, H - 2, 2, 2);
    doc.addImage(png, 'PNG', x + 3, y + 4, 25, 25);
    doc.setFont('helvetica', 'bold'); doc.setFontSize(13); doc.setTextColor(20);
    doc.text(a.tag || '', x + 31, y + 11);
    doc.setFont('helvetica', 'normal'); doc.setFontSize(8.5); doc.setTextColor(60);
    doc.text(doc.splitTextToSize(a.name || '', W - 34).slice(0, 2), x + 31, y + 16);
    if (a.serial_no) doc.text(doc.splitTextToSize('S/N ' + a.serial_no, W - 34).slice(0, 1), x + 31, y + 24);
    doc.setFontSize(7); doc.setTextColor(110);
    doc.text(doc.splitTextToSize(company.name, W - 34).slice(0, 1), x + 31, y + 28.5);
  }
  doc.save(`asset-labels-${today()}.pdf`);
}

/** Check out, check in, audit and status buttons on an asset, with their forms. */
export function AssetOps({ a, staff, onDone }: { a: any; staff: any[]; onDone: () => void }) {
  const { cid, company, can } = useSession();
  const act = useAction();
  const [out, setOut] = useState<any | null>(null);
  const [back, setBack] = useState<any | null>(null);
  const [audit, setAudit] = useState<any | null>(null);
  const [state, setState] = useState<any | null>(null);
  const [send, setSend] = useState(false);
  const { data: projects } = useLoad(() => out ? q<any[]>(supabase.from('projects').select('id,number,name').eq('company_id', cid).in('status', ['planned', 'active']).order('name') as any) : Promise.resolve([]), [cid, !!out]);
  const mgr = can('accountant', 'store');
  if (a.status !== 'active') return null;
  return <>
    <button className="btn" type="button" onClick={() => act.run(() => labelsPdf(company!, [a]))}>QR label</button>
    {mgr && a.state === 'deployed' && <button className="btn primary" type="button" onClick={() => setBack({ state: 'ready', location: '', note: '' })}>Check in</button>}
    {mgr && ['ready', 'pending'].includes(a.state) && <button className="btn primary" type="button" onClick={() => setOut({ to: 'employee', employee: '', project: '', location: '', expected: '', note: '' })}>Check out</button>}
    {mgr && <button className="btn" type="button" onClick={() => setAudit({ condition: 'good', location: a.location || '', note: '', next: '' })}>Audit</button>}
    {mgr && ['ready', 'pending', 'repair', 'broken'].includes(a.state) && <button className="btn" type="button" title="Send to another location; it stays In transit until received" onClick={() => setSend(true)}>Transfer</button>}
    {a.state === 'transit' && <Link className="btn" to="/assets/transfers">In transit — open transfers</Link>}
    {mgr && !['deployed', 'transit'].includes(a.state) && <button className="btn" type="button" onClick={() => setState({ state: a.state === 'ready' ? 'repair' : 'ready', note: '' })}>Change status</button>}
    {mgr && <button className="btn" type="button" title="Staff can ask for it from Assets → Requests" onClick={() => act.run(async () => { await q(supabase.from('assets').update({ requestable: !a.requestable }).eq('id', a.id) as any); onDone(); }, a.requestable ? 'No longer requestable' : 'Staff can now request it')}>{a.requestable ? 'Stop requests' : 'Allow requests'}</button>}

    {send && <SendTransferModal asset={a} onClose={() => setSend(false)} onDone={() => { setSend(false); onDone(); }} />}
    {out && <FormModal title={`Check out ${a.tag}`} submit="Check out" busy={act.busy} onClose={() => setOut(null)} onSave={() => act.run(async () => {
      await rpc('checkout_asset', { p_asset: a.id, p_employee: out.to === 'employee' ? out.employee || null : null, p_project: out.to === 'project' ? out.project || null : null,
        p_location: out.location || null, p_expected_return: out.expected || null, p_note: out.note || null, p_request: out.request || null });
      setOut(null); onDone(); }, 'Checked out')}>
      <Select label="Check out to" id="co-to" value={out.to} onChange={v => setOut({ ...out, to: v })} options={[['employee', 'A person'], ['project', 'A project site'], ['location', 'A location only']]} />
      <div className="grid-form">
        {out.to === 'employee' && <Select label="Person" id="co-emp" value={out.employee} onChange={v => setOut({ ...out, employee: v })} options={[['', 'Choose…'], ...staff.map(s => [s.id, s.full_name] as [string, string])]} />}
        {out.to === 'project' && <Select label="Project" id="co-pj" value={out.project} onChange={v => setOut({ ...out, project: v })} options={[['', 'Choose…'], ...(projects || []).map(p => [p.id, `${p.number || ''} ${p.name}`.trim()] as [string, string])]} />}
        <Field label={out.to === 'location' ? 'Location' : 'Location (optional)'} id="co-loc" value={out.location} onChange={v => setOut({ ...out, location: v })} placeholder="e.g. Tema yard, Prestea site office" />
        <Field label="Expected back" id="co-exp" type="date" value={out.expected} onChange={v => setOut({ ...out, expected: v })} />
      </div>
      <Field label="Note" id="co-note" value={out.note} onChange={v => setOut({ ...out, note: v })} />
      <p className="muted" style={{ margin: 0, fontSize: 13 }}>The person is notified and reminded if it is not back on time.</p>
    </FormModal>}
    {back && <FormModal title={`Check in ${a.tag}`} submit="Check in" busy={act.busy} onClose={() => setBack(null)} onSave={() => act.run(async () => {
      await rpc('checkin_asset', { p_asset: a.id, p_state: back.state, p_location: back.location || null, p_note: back.note || null }); setBack(null); onDone(); }, 'Checked in')}>
      <p style={{ margin: 0 }}>Currently with <b>{holderText(a) || a.location || '—'}</b>.</p>
      <div className="grid-form">
        <Select label="Came back" id="ci-st" value={back.state} onChange={v => setBack({ ...back, state: v })} options={[['ready', 'In good order (ready to deploy)'], ['pending', 'Needs checking (pending)'], ['repair', 'Needs repair'], ['broken', 'Broken'], ['lost', 'Did not come back (lost)']]} />
        <Field label="Now at" id="ci-loc" value={back.location} onChange={v => setBack({ ...back, location: v })} placeholder={a.location || 'e.g. Main store'} />
      </div>
      <Field label="Note" id="ci-note" value={back.note} onChange={v => setBack({ ...back, note: v })} />
    </FormModal>}
    {audit && <FormModal title={`Audit ${a.tag}`} submit="Record audit" busy={act.busy} onClose={() => setAudit(null)} onSave={() => act.run(async () => {
      await rpc('audit_asset', { p_asset: a.id, p_condition: audit.condition, p_location: audit.location || null, p_note: audit.note || null, p_next: audit.next || null }); setAudit(null); onDone(); }, 'Audit recorded')}>
      <div className="grid-form">
        <Select label="Condition found" id="au-c" value={audit.condition} onChange={v => setAudit({ ...audit, condition: v })} options={[['good', 'Good'], ['fair', 'Fair'], ['poor', 'Poor'], ['broken', 'Broken'], ['missing', 'Not found']]} />
        <Field label="Found at" id="au-l" value={audit.location} onChange={v => setAudit({ ...audit, location: v })} />
        <Field label="Next audit (blank = the company interval)" id="au-n" type="date" value={audit.next} onChange={v => setAudit({ ...audit, next: v })} />
      </div>
      <Field label="Note" id="au-note" value={audit.note} onChange={v => setAudit({ ...audit, note: v })} />
    </FormModal>}
    {state && <FormModal title={`Status of ${a.tag}`} busy={act.busy} onClose={() => setState(null)} onSave={() => act.run(async () => {
      await rpc('set_asset_state', { p_asset: a.id, p_state: state.state, p_note: state.note || null }); setState(null); onDone(); }, 'Status changed')}>
      <Select label="Status" id="st-s" value={state.state} onChange={v => setState({ ...state, state: v })} options={Object.entries(ASSET_STATES).filter(([k]) => !['deployed', 'transit'].includes(k)).map(([k, [l]]) => [k, l] as [string, string])} />
      <Field label="Note (e.g. sent to Toyota Ghana for brake repair)" id="st-n" value={state.note} onChange={v => setState({ ...state, note: v })} />
      <p className="muted" style={{ margin: 0, fontSize: 13 }}>Archived keeps it on the books but out of use. To sell or write it off, use Sell or write off.</p>
    </FormModal>}
  </>;
}

/** Staff ask for equipment; the storekeeper approves and checks it out. */
export function AssetRequestsPage() {
  const { cid, can, session } = useSession();
  const act = useAction();
  const mgr = can('accountant', 'store');
  const [show, setShow] = useState('open');
  const [ask, setAsk] = useState<any | null>(null);
  const [give, setGive] = useState<any | null>(null);
  const { data, error, loading, reload } = useLoad(async () => {
    const [reqs, avail, cats, projects, staff, locs] = await Promise.all([
      q<any[]>(supabase.from('asset_requests').select('*, asset:assets!asset_requests_asset_id_fkey(id,tag,name), category:asset_categories(name), employee:employees(id,full_name), project:projects(number,name), given:assets!asset_requests_fulfilled_asset_id_fkey(id,tag)').eq('company_id', cid).order('created_at', { ascending: false }) as any),
      q<any[]>(supabase.from('assets').select('id,tag,name,state,requestable,category_id').eq('company_id', cid).eq('status', 'active').order('tag') as any),
      q<any[]>(supabase.from('asset_categories').select('id,name').eq('company_id', cid).order('name') as any),
      q<any[]>(supabase.from('projects').select('id,number,name').eq('company_id', cid).in('status', ['planned', 'active']).order('name') as any),
      q<any[]>(supabase.from('employees').select('id,full_name,user_id').eq('company_id', cid).eq('status', 'active').order('full_name') as any).catch(() => []),
      q<any[]>(supabase.from('asset_locations').select('id,name,manager_id,active').eq('company_id', cid).order('name') as any).catch(() => [] as any[]),
    ]);
    return { reqs, avail, cats, projects, staff, locs };
  }, [cid]);
  const me = session?.user.id;
  const locOf = (id?: string | null) => (data?.locs || []).find(l => l.id === id);
  const siteMgr = (r: any) => !r.escalated && !!r.location_id && locOf(r.location_id)?.manager_id === me && r.requested_by !== me;
  const canDecide = (r: any) => (mgr && r.requested_by !== me) || siteMgr(r);
  const F: [string, string, (r: any) => boolean][] = [['open', 'Open', r => ['pending', 'approved'].includes(r.status)], ['site', 'For my site', r => r.status === 'pending' && siteMgr(r)], ['mine', 'Mine', r => r.requested_by === session?.user.id],
    ['done', 'Fulfilled', r => r.status === 'fulfilled'], ['closed', 'Declined or cancelled', r => ['rejected', 'cancelled'].includes(r.status)], ['all', 'All', () => true]];
  const list = (data?.reqs || []).filter((F.find(f => f[0] === show) || F[0])[2]);
  const RS: Record<string, string> = { pending: 'warn', approved: 'good', fulfilled: '', rejected: 'bad', cancelled: '' };
  return <>
    <PageHead title="Asset requests" sub="Ask for a laptop, tool or equipment. Your site manager approves or passes it to head office; the storekeeper hands it over. For a vehicle, use Fleet → Vehicle requests.">
      <button className="btn primary" type="button" onClick={() => setAsk({ asset: '', category: '', description: '', project: '', from: today(), until: '', location: '', quantity: '1' })}>Request an asset</button>
    </PageHead>
    <Loading error={error} loading={loading && !data} />
    {data && <>
      <div className="chips">{F.map(([k, l, fn]) => <button key={k} type="button" className={'chip' + (show === k ? ' on' : '')} onClick={() => setShow(k)}>{l} <span>{data.reqs.filter(fn).length}</span></button>)}</div>
      <Panel>{list.length ? <div className="scroll"><table>
        <thead><tr><th>Request</th><th>For</th><th>When</th><th>Status</th><th></th></tr></thead>
        <tbody>{list.map(r => <tr key={r.id}>
          <td><b className="num">{r.number}</b> {r.asset ? <Link to={'/assets/' + r.asset.id}>{r.asset.tag} {r.asset.name}</Link> : r.description}
            {r.asset && r.description !== `${r.asset.tag} ${r.asset.name}` && <><br /><span className="muted">{r.description}</span></>}{r.category && <><br /><span className="muted">Any {r.category.name}</span></>}</td>
          <td>{r.employee?.full_name || '—'}{r.quantity > 1 && <span className="muted"> × {r.quantity}</span>}{r.project && <><br /><span className="muted">{r.project.number} {r.project.name}</span></>}{r.location_id && <><br /><span className="muted">at {locOf(r.location_id)?.name}</span>{r.escalated ? <span className="pill" style={{ marginLeft: 4 }} title={r.escalated_note || ''}>head office</span> : ''}</>}</td>
          <td className="num">{r.needed_from}{r.needed_until ? ' → ' + r.needed_until : ''}</td>
          <td><span className={'pill ' + RS[r.status]}>{r.status}</span>{r.given && <><br /><Link to={'/assets/' + r.given.id} style={{ fontSize: 12 }}>{r.given.tag}</Link></>}{r.decision_note && <><br /><span className="muted" style={{ fontSize: 12 }}>{r.decision_note}</span></>}</td>
          <td className="r" style={{ whiteSpace: 'nowrap' }}>
            {canDecide(r) && r.status === 'pending' && <>
              <button className="btn small" type="button" disabled={act.busy} onClick={() => act.run(async () => { await rpc('decide_asset_request', { p_id: r.id, p_approve: true }); reload(); }, 'Approved')}>Approve</button>{' '}
              <button className="btn small ghost" type="button" disabled={act.busy} onClick={() => act.run(async () => { await rpc('decide_asset_request', { p_id: r.id, p_approve: false }); reload(); }, 'Declined')}>Decline</button>{' '}
              {siteMgr(r) && <button className="btn small ghost" type="button" title="Not available on site: send it to head office" disabled={act.busy} onClick={() => act.run(async () => { await rpc('escalate_asset_request', { p_id: r.id, p_note: 'Not available on site' }); reload(); }, 'Passed to head office')}>Pass to head office</button>}</>}
            {mgr && r.status === 'approved' && <button className="btn small primary" type="button" onClick={() => setGive({ r, asset: r.asset?.id || '', expected: r.needed_until || '' })}>Hand over</button>}
            {!mgr && r.requested_by === session?.user.id && ['pending', 'approved'].includes(r.status) && <button className="btn small ghost" type="button" disabled={act.busy} onClick={() => act.run(async () => { await rpc('decide_asset_request', { p_id: r.id, p_approve: false }); reload(); }, 'Request withdrawn')}>Withdraw</button>}
          </td></tr>)}</tbody></table></div> : <Empty>No requests here.</Empty>}</Panel>
    </>}
    {ask && data && <FormModal title="Request an asset" submit="Send request" busy={act.busy} onClose={() => setAsk(null)} onSave={() => act.run(async () => {
      await rpc('request_asset', { cid, p_description: ask.description, p_asset: ask.asset || null, p_category: ask.category || null, p_project: ask.project || null, p_from: ask.from || null, p_until: ask.until || null, p_location: ask.location || null, p_quantity: Number(ask.quantity) || 1 });
      setAsk(null); setShow('mine'); reload(); }, ask.location && locOf(ask.location)?.manager_id ? 'Request sent to the site manager' : 'Request sent to the store')}>
      <Select label="A particular item" id="rq-a" value={ask.asset} onChange={v => setAsk({ ...ask, asset: v })} options={[['', 'No, describe what you need below'], ...data.avail.filter(a => a.requestable).map(a => [a.id, `${a.tag} ${a.name}${a.state !== 'ready' ? ' (in use now)' : ''}`] as [string, string])]} />
      {!ask.asset && <Select label="Kind of asset" id="rq-c" value={ask.category} onChange={v => setAsk({ ...ask, category: v })} options={[['', 'Any'], ...data.cats.map(c => [c.id, c.name] as [string, string])]} />}
      <Field label="What you need and why" id="rq-d" type="textarea" value={ask.description} onChange={v => setAsk({ ...ask, description: v })} placeholder="e.g. Laptop for the new site engineer at Prestea" />
      <div className="grid-form">
        <Select label="For project" id="rq-p" value={ask.project} onChange={v => setAsk({ ...ask, project: v })} options={[['', 'None'], ...data.projects.map(p => [p.id, `${p.number || ''} ${p.name}`.trim()] as [string, string])]} />
        <Field label="Needed from" id="rq-f" type="date" value={ask.from} onChange={v => setAsk({ ...ask, from: v })} />
        <Field label="Until (blank if permanent)" id="rq-u" type="date" value={ask.until} onChange={v => setAsk({ ...ask, until: v })} />
        <Select label="Needed at (your site or office)" id="rq-l" value={ask.location} onChange={v => setAsk({ ...ask, location: v })} options={locOpts(data.locs, 'Head office / not sure')} />
        {!ask.asset && <Field label="How many" id="rq-q" type="number" step="1" min="1" value={ask.quantity} onChange={v => setAsk({ ...ask, quantity: v })} />}
      </div>
      <p className="muted" style={{ margin: 0, fontSize: 13 }}>A request for a site goes to that site's manager first. If they don't have it, they pass it to head office.</p>
    </FormModal>}
    {give && data && <FormModal title={`Hand over for ${give.r.number}`} submit="Check out" busy={act.busy} onClose={() => setGive(null)} onSave={() => act.run(async () => {
      if (!give.asset) throw new Error('Choose the asset to give.');
      await rpc('checkout_asset', { p_asset: give.asset, p_employee: give.r.employee?.id || null, p_project: give.r.employee ? null : give.r.project_id, p_location: null, p_expected_return: give.expected || null, p_note: give.r.number, p_request: give.r.id });
      setGive(null); reload(); }, 'Handed over')}>
      <Select label="Asset" id="gv-a" value={give.asset} onChange={v => setGive({ ...give, asset: v })} options={[['', 'Choose…'], ...data.avail.filter(a => ['ready', 'pending'].includes(a.state) && (!give.r.category_id || a.category_id === give.r.category_id)).map(a => [a.id, `${a.tag} ${a.name}`] as [string, string])]} />
      <Field label="Expected back" id="gv-e" type="date" value={give.expected} onChange={v => setGive({ ...give, expected: v })} />
      <p className="muted" style={{ margin: 0, fontSize: 13 }}>Checked out to {give.r.employee?.full_name || 'the project'}; the request is marked fulfilled.</p>
    </FormModal>}
  </>;
}

/** Due-for-audit list and audit history. */
export function AssetAuditsPage() {
  const { cid, company } = useSession();
  const { data, error, loading } = useLoad(async () => {
    const [due, hist] = await Promise.all([
      q<any[]>(supabase.from('assets').select('id,tag,name,location,state,next_audit,last_audit, custodian:employees(full_name)').eq('company_id', cid).eq('status', 'active').neq('state', 'archived').order('next_audit', { nullsFirst: true }) as any),
      q<any[]>(supabase.from('asset_audits').select('*, asset:assets(id,tag,name)').eq('company_id', cid).order('audited_on', { ascending: false }).limit(300) as any),
    ]);
    return { due, hist };
  }, [cid]);
  const dueList = (data?.due || []).filter(a => !a.next_audit || a.next_audit <= soon(30));
  const head = ['Tag', 'Asset', 'Location', 'With', 'Last audit', 'Next audit'];
  const rows = dueList.map(a => [a.tag, a.name, a.location || '', a.custodian?.full_name || '', a.last_audit || 'Never', a.next_audit || '']);
  return <>
    <PageHead title="Asset audits" sub="Confirm each asset is where the register says, and in what condition. Open an asset and press Audit, or scan its QR label.">
      <Downloads pdf={() => tablePdf({ company: company!, title: 'Assets due for audit', subtitle: longDate(today()), head, body: rows, filename: 'audit-due-' + today() })} csv={() => downloadCsv('audit-due-' + today(), head, rows)} />
    </PageHead>
    <Loading error={error} loading={loading && !data} />
    {data && <>
      <Panel title={`Due in the next 30 days (${dueList.length})`}>{dueList.length ? <div className="scroll"><table>
        <thead><tr><th>Asset</th><th>Location / with</th><th>Last audit</th><th>Next audit</th></tr></thead>
        <tbody>{dueList.map(a => <tr key={a.id}><td><Link to={'/assets/' + a.id}><b>{a.tag}</b></Link> {a.name}</td><td>{a.location || '—'}<br /><span className="muted">{a.custodian?.full_name}</span></td>
          <td className="num">{a.last_audit || 'Never'}</td><td className="num"><span className={'pill ' + (!a.next_audit || a.next_audit < today() ? 'bad' : 'warn')}>{a.next_audit || 'not set'}</span></td></tr>)}</tbody></table></div>
        : <Empty>Nothing due. Every asset has been audited on schedule.</Empty>}</Panel>
      <Panel title="Audit history">{data.hist.length ? <div className="scroll"><table>
        <thead><tr><th>Date</th><th>Asset</th><th>Found at</th><th>Condition</th><th>Next</th></tr></thead>
        <tbody>{data.hist.map(h => <tr key={h.id}><td className="num">{h.audited_on}</td><td><Link to={'/assets/' + h.asset?.id}>{h.asset?.tag}</Link> {h.asset?.name}{h.note && <><br /><span className="muted">{h.note}</span></>}</td>
          <td>{h.location}</td><td><span className={'pill ' + ({ good: 'good', fair: '', poor: 'warn', broken: 'bad', missing: 'bad' } as any)[h.condition]}>{h.condition === 'missing' ? 'not found' : h.condition}</span></td><td className="num">{h.next_audit}</td></tr>)}</tbody></table></div>
        : <Empty>No audits recorded yet.</Empty>}</Panel>
    </>}
  </>;
}

/** Service schedule across all assets, from each asset's maintenance log. */
export function AssetMaintenancePage() {
  const { cid, company } = useSession();
  const { data, error, loading } = useLoad(() => rpc<any[]>('asset_maintenance_schedule', { cid }), [cid]);
  const list = data || [];
  const head = ['Tag', 'Asset', 'Location', 'With', 'Last service', 'Work done', 'Next due', 'Services', 'Total cost (GHS)'];
  const rows = list.map(r => [r.tag, r.name, r.location || '', r.custodian || '', r.last_service || '', r.last_description || '', r.next_due || '', r.services, money(r.total_cost)]);
  return <>
    <PageHead title="Maintenance" sub="Log each service on the asset's page with its next due date; you are reminded a week before.">
      <Downloads pdf={() => tablePdf({ company: company!, title: 'Maintenance schedule', subtitle: longDate(today()), head, body: rows, rightAlign: [7, 8], landscape: true, filename: 'maintenance-' + today() })} csv={() => downloadCsv('maintenance-' + today(), head, rows)} />
    </PageHead>
    <Loading error={error} loading={loading && !data} />
    {data && <Panel>{list.length ? <div className="scroll"><table>
      <thead><tr><th>Asset</th><th>Last service</th><th>Next due</th><th className="r">Services</th><th className="r">Total cost (GH₵)</th></tr></thead>
      <tbody>{list.map(r => <tr key={r.asset_id}><td><Link to={'/assets/' + r.asset_id}><b>{r.tag}</b></Link> {r.name}<br /><span className="muted">{[r.location, r.custodian].filter(Boolean).join(' · ')}</span></td>
        <td>{r.last_service ? <>{r.last_service}<br /><span className="muted">{r.last_description}</span></> : <span className="muted">Never serviced</span>}</td>
        <td className="num">{r.next_due ? <span className={'pill ' + (r.days_left < 0 ? 'bad' : r.days_left <= 7 ? 'warn' : '')}>{r.next_due}</span> : '—'}</td>
        <td className="r num">{r.services}</td><td className="r num">{money(r.total_cost)}</td></tr>)}</tbody></table></div> : <Empty>No assets in use.</Empty>}</Panel>}
  </>;
}

/** Every check-out, check-in, move, status change and audit across all assets. */
export function AssetMovementsPage() {
  const { cid, company } = useSession();
  const [kind, setKind] = useState('');
  const { data, error, loading } = useLoad(() => q<any[]>(supabase.from('asset_movements').select('*, asset:assets(id,tag,name), from:employees!asset_movements_from_custodian_fkey(full_name), to:employees!asset_movements_to_custodian_fkey(full_name), project:projects(number,name)').eq('company_id', cid).order('created_at', { ascending: false }).limit(500) as any), [cid]);
  const KIND: Record<string, string> = { checkout: 'Checked out', checkin: 'Checked in', move: 'Moved', audit: 'Audited', status: 'Status' };
  const list = (data || []).filter(m => !kind || m.kind === kind);
  const head = ['Date', 'Asset', 'What', 'From', 'To', 'Note'];
  const rows = list.map(m => [m.move_date, `${m.asset?.tag} ${m.asset?.name}`, KIND[m.kind] + (m.state_after && m.kind !== 'checkout' ? ` (${(ASSET_STATES[m.state_after] || [m.state_after])[0]})` : ''),
    [m.from_location, m.from?.full_name].filter(Boolean).join(' · '), [m.to_location, m.to?.full_name, m.project && `${m.project.number || ''} ${m.project.name}`].filter(Boolean).join(' · '), m.note || '']);
  return <>
    <PageHead title="Asset movements">
      <Downloads pdf={() => tablePdf({ company: company!, title: 'Asset movements', subtitle: longDate(today()), head, body: rows, landscape: true, filename: 'asset-movements-' + today() })} csv={() => downloadCsv('asset-movements-' + today(), head, rows)} />
    </PageHead>
    <div className="filters"><Select label="Show" id="mv-k" value={kind} onChange={setKind} options={[['', 'Everything'], ...Object.entries(KIND) as [string, string][]]} /></div>
    <Loading error={error} loading={loading && !data} />
    {data && <Panel>{list.length ? <div className="scroll"><table>
      <thead><tr>{head.map(h => <th key={h}>{h}</th>)}</tr></thead>
      <tbody>{list.map((m, i) => <tr key={m.id}><td className="num">{rows[i][0]}</td><td><Link to={'/assets/' + m.asset?.id}>{m.asset?.tag}</Link> {m.asset?.name}</td><td>{rows[i][2]}</td><td>{rows[i][3]}</td><td>{rows[i][4]}{m.expected_return && <><br /><span className="muted" style={{ fontSize: 12 }}>back by {m.expected_return}</span></>}</td><td className="muted">{m.note}</td></tr>)}</tbody></table></div>
      : <Empty>No movements yet.</Empty>}</Panel>}
  </>;
}
