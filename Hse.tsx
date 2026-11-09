import { useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { q, rpc, supabase } from '../lib/supabase';
import { useSession } from '../lib/session';
import { longDate, today } from '../lib/format';
import { downloadCsv } from '../lib/download';
import { tablePdf } from '../lib/pdf';
import { uploadDocFile } from '../components/ProjectDocs';
import { ConfirmButton, Empty, Field, FormModal, Loading, PageHead, Panel, Select, useAction, useLoad } from '../components/ui';

// ---------------------------------------------------------------- Shared lists and helpers
export const INC_KINDS: [string, string, string][] = [
  ['observation', 'Safety observation (unsafe act or condition)', ''], ['near_miss', 'Near miss', 'warn'], ['first_aid', 'First-aid injury', 'warn'],
  ['medical_treatment', 'Medical treatment injury', 'bad'], ['restricted_work', 'Restricted work injury', 'bad'], ['lost_time', 'Lost-time injury', 'bad'],
  ['fatality', 'Fatality', 'bad'], ['occupational_illness', 'Occupational illness', 'bad'], ['property_damage', 'Property or equipment damage', 'warn'],
  ['environmental', 'Environmental (spill, emission, waste)', 'bad'], ['dangerous_occurrence', 'Dangerous occurrence', 'bad'], ['vehicle', 'Vehicle incident', 'warn'],
  ['security', 'Security incident', 'warn'],
];
const kindLabel = (k: string) => INC_KINDS.find(x => x[0] === k)?.[1].replace(/ \(.*\)$/, '') || k;
const KindPill = ({ k }: { k: string }) => <span className={'pill ' + (INC_KINDS.find(x => x[0] === k)?.[2] || '')}>{kindLabel(k)}</span>;
const INC_STATUS: Record<string, [string, string]> = { reported: ['Reported', 'warn'], investigating: ['Investigating', 'warn'], action: ['Actions under way', ''], closed: ['Closed', 'good'] };
const ACT_STATUS: Record<string, [string, string]> = { open: ['Open', 'warn'], done: ['Done, to verify', ''], verified: ['Verified', 'good'], cancelled: ['Cancelled', ''] };
export const PERMIT_KINDS: [string, string][] = [['hot_work', 'Hot work (welding, cutting, grinding)'], ['electrical', 'Electrical isolation / live work (LOTO)'], ['height', 'Work at height'],
  ['confined_space', 'Confined space entry'], ['excavation', 'Excavation'], ['lifting', 'Lifting operation'], ['general', 'General work']];
const PERMIT_STATUS: Record<string, [string, string]> = { requested: ['Waiting for approval', 'warn'], approved: ['Issued', 'good'], suspended: ['Suspended', 'bad'], closed: ['Closed', ''], cancelled: ['Cancelled', ''], rejected: ['Rejected', 'bad'] };
const OBL_CATS: [string, string][] = [['permit_licence', 'Permit or licence'], ['regulatory_filing', 'Regulatory filing or return'], ['certification', 'Certification (ISO etc.)'], ['insurance', 'Insurance'], ['contract', 'Contract requirement'], ['policy', 'Internal policy'], ['other', 'Other']];
const AREAS: [string, string][] = [['safety', 'Health and safety'], ['environment', 'Environment'], ['quality', 'Quality'], ['legal', 'Legal and corporate'], ['tax_finance', 'Tax and finance'], ['labour', 'Labour and HR'], ['data_protection', 'Data protection'], ['anti_bribery', 'Anti-bribery'], ['other', 'Other']];
const RECUR: [string, string][] = [['none', 'Fixed expiry date'], ['monthly', 'Every month'], ['quarterly', 'Every quarter'], ['semiannual', 'Every 6 months'], ['annual', 'Every year']];
const label = (list: [string, string][], v: string) => list.find(x => x[0] === v)?.[1] || v;
const Pill = ({ map, s }: { map: Record<string, [string, string]>; s: string }) => <span className={'pill ' + (map[s]?.[1] || '')}>{map[s]?.[0] || s}</span>;
const dt = (iso?: string | null) => iso ? iso.slice(0, 16).replace('T', ' ') : '';
const toLocal = (iso?: string | null) => { if (!iso) return ''; const d = new Date(iso); return new Date(d.getTime() - d.getTimezoneOffset() * 6e4).toISOString().slice(0, 16); };
const nowLocal = (addH = 0) => toLocal(new Date(Date.now() + addH * 36e5).toISOString());
const n1 = (v: any) => v == null ? '—' : Number(v).toLocaleString('en-GB', { maximumFractionDigits: 2 });
const PERIODS: [string, string][] = [['month', 'This month'], ['ytd', 'Year to date'], ['12m', 'Last 12 months'], ['lastyear', 'Last year']];
function periodRange(p: string): [string, string] {
  const t = today(), y = Number(t.slice(0, 4));
  if (p === 'month') return [t.slice(0, 8) + '01', t];
  if (p === 'ytd') return [`${y}-01-01`, t];
  if (p === 'lastyear') return [`${y - 1}-01-01`, `${y - 1}-12-31`];
  const d = new Date(); d.setFullYear(d.getFullYear() - 1); d.setDate(d.getDate() + 1); return [d.toISOString().slice(0, 10), t];
}
const oblState = (o: any): [string, string] => {
  if (o.status === 'retired') return ['Retired', ''];
  if (o.status === 'not_compliant') return ['Not compliant', 'bad'];
  if (!o.expires_on) return ['No expiry', 'good'];
  if (o.expires_on < today()) return ['Expired', 'bad'];
  const days = Math.round((Date.parse(o.expires_on) - Date.parse(today())) / 864e5);
  return days <= (o.lead_days ?? 30) ? [`Due in ${days} day${days === 1 ? '' : 's'}`, 'warn'] : ['Compliant', 'good'];
};

/** People and projects for pickers, and whether this person is an HSE officer. */
function useHseBasics() {
  const { cid, session, can } = useSession();
  const { data } = useLoad(async () => {
    const [team, projects, staff] = await Promise.all([
      q<any[]>(supabase.from('memberships').select('*').eq('company_id', cid).order('email') as any),
      q<any[]>(supabase.from('projects').select('id,number,name,manager_id,status').eq('company_id', cid).eq('is_template', false).order('number', { ascending: false }) as any).catch(() => [] as any[]),
      q<any[]>(supabase.from('employees').select('id,full_name').eq('company_id', cid).order('full_name') as any).catch(() => [] as any[]),
    ]);
    return { team, projects, staff };
  }, [cid]);
  const me = session?.user.id;
  const hse = can() || !!data?.team.find(m => m.user_id === me)?.hse;
  const pm = (pid?: string | null) => !!pid && data?.projects.find(p => p.id === pid)?.manager_id === me;
  const who = (u?: string | null) => (data?.team.find(m => m.user_id === u)?.email || '').split('@')[0];
  const proj = (pid?: string | null) => { const p = data?.projects.find(x => x.id === pid); return p ? `${p.number || ''} ${p.name}`.trim() : ''; };
  const projOpts: [string, string][] = [['', 'Not on a project (office, workshop, yard)'], ...(data?.projects || []).filter(p => !['closed', 'cancelled'].includes(p.status)).map(p => [p.id, `${p.number || ''} ${p.name}`.trim()] as [string, string])];
  const teamOpts: [string, string][] = [['', '—'], ...(data?.team || []).map(m => [m.user_id, m.email] as [string, string])];
  return { ready: !!data, team: data?.team || [], staff: data?.staff || [], hse, pm, who, proj, projOpts, teamOpts, me };
}

function Files({ type, id, canAdd }: { type: string; id: string; canAdd: boolean }) {
  const { cid } = useSession();
  const act = useAction();
  const { data, reload } = useLoad(() => q<any[]>(supabase.from('hse_files').select('*').eq('parent_type', type).eq('parent_id', id).order('created_at') as any), [type, id]);
  const open = (f: any) => act.run(async () => { const { data: u, error } = await supabase.storage.from('project-docs').createSignedUrl(f.storage_path, 600); if (error) throw error; window.open(u.signedUrl, '_blank', 'noopener'); });
  const add = (files: FileList | null) => files && act.run(async () => {
    for (const file of Array.from(files)) {
      const f = await uploadDocFile(cid, 'hse', file);
      await q(supabase.from('hse_files').insert({ company_id: cid, parent_type: type, parent_id: id, name: f.name, storage_path: f.path, size_bytes: f.size }) as any);
    }
    reload();
  }, 'Uploaded');
  return <Panel title="Photos and files" actions={canAdd && <label className="btn small">{act.busy ? 'Uploading…' : 'Add photos or files'}<input type="file" multiple hidden onChange={e => add(e.target.files)} /></label>}>
    {data?.length ? <table><tbody>{data.map(f => <tr key={f.id}><td><button type="button" className="btn small ghost" onClick={() => open(f)}>{f.name}</button></td>
      <td className="muted">{longDate(f.created_at)}</td><td className="r muted">{f.size_bytes ? Math.round(f.size_bytes / 1024) + ' KB' : ''}</td></tr>)}</tbody></table>
      : <Empty>No photos or files yet. Add photos of the scene, statements, certificates or reports.</Empty>}
  </Panel>;
}

// ---------------------------------------------------------------- Report an incident or observation (anyone)
export function ReportIncident({ onClose, onDone }: { onClose: () => void; onDone: (id: string) => void }) {
  const { cid } = useSession();
  const b = useHseBasics();
  const act = useAction();
  const [f, setF] = useState<any>({ kind: 'observation', occurred_at: nowLocal(), project_id: '', location: '', description: '', immediate_action: '', persons_involved: '', injured_employee_id: '', injury_nature: '', body_part: '', lost_days: '', potential_severity: '' });
  const set = (k: string) => (v: any) => setF({ ...f, [k]: v });
  const injury = ['first_aid', 'medical_treatment', 'restricted_work', 'lost_time', 'fatality', 'occupational_illness'].includes(f.kind);
  return <FormModal title="Report an incident or safety observation" submit="Send report" busy={act.busy} onClose={onClose} onSave={() => act.run(async () => {
    const r = await q<any>(supabase.from('hse_incidents').insert({ company_id: cid, kind: f.kind, occurred_at: new Date(f.occurred_at).toISOString(), project_id: f.project_id || null,
      location: f.location || null, description: f.description, immediate_action: f.immediate_action || null, persons_involved: f.persons_involved || null,
      injured_employee_id: f.injured_employee_id || null, injury_nature: f.injury_nature || null, body_part: f.body_part || null,
      lost_days: Number(f.lost_days) || 0, potential_severity: f.potential_severity ? Number(f.potential_severity) : null }).select('id').single() as any);
    onDone(r.id); }, 'Report sent to the HSE officer. Thank you.')}>
    <p className="muted" style={{ margin: 0, fontSize: 13 }}>Report anything unsafe, even when nobody was hurt. Reports are used to prevent harm, not to blame.</p>
    <Select label="What happened?" id="ri-kind" value={f.kind} onChange={set('kind')} options={INC_KINDS.map(k => [k[0], k[1]] as [string, string])} />
    <div className="grid-form">
      <Field label="When" id="ri-when" type="datetime-local" value={f.occurred_at} onChange={set('occurred_at')} required />
      <Select label="Project" id="ri-proj" value={f.project_id} onChange={set('project_id')} options={b.projOpts} />
      <Field label="Where exactly" id="ri-loc" value={f.location} onChange={set('location')} placeholder="e.g. Tema substation, bay 2" />
      <Select label="How bad could it have been?" id="ri-pot" value={f.potential_severity} onChange={set('potential_severity')} options={[['', '—'], ['1', '1 · Negligible'], ['2', '2 · Minor'], ['3', '3 · Moderate'], ['4', '4 · Major'], ['5', '5 · Catastrophic']]} />
    </div>
    <Field label="Describe what happened or what you saw" id="ri-desc" type="textarea" value={f.description} onChange={set('description')} required />
    <Field label="What was done straight away" id="ri-imm" type="textarea" value={f.immediate_action} onChange={set('immediate_action')} />
    <Field label="People involved or witnesses" id="ri-people" value={f.persons_involved} onChange={set('persons_involved')} />
    {injury && <div className="grid-form">
      <Select label="Injured person" id="ri-emp" value={f.injured_employee_id} onChange={set('injured_employee_id')} options={[['', 'Not an employee / not listed'], ...b.staff.map(s => [s.id, s.full_name] as [string, string])]} />
      <Field label="Injury" id="ri-inj" value={f.injury_nature} onChange={set('injury_nature')} placeholder="e.g. cut, burn, fracture" />
      <Field label="Part of the body" id="ri-body" value={f.body_part} onChange={set('body_part')} />
      <Field label="Days off work (so far)" id="ri-lost" type="number" min="0" value={f.lost_days} onChange={set('lost_days')} />
    </div>}
    <p className="muted" style={{ margin: 0, fontSize: 13 }}>After sending, open the report to add photos.</p>
  </FormModal>;
}

// ---------------------------------------------------------------- Dashboard
export function HseDashboardPage() {
  const { cid, company, session } = useSession();
  const nav = useNavigate();
  const b = useHseBasics();
  const [period, setPeriod] = useState('ytd');
  const [report, setReport] = useState(false);
  const [from, to] = periodRange(period);
  const { data, error, loading } = useLoad(async () => {
    const [stats, incidents, actions, obligations, policies, acks] = await Promise.all([
      rpc<any[]>('hse_stats', { cid, p_from: from, p_to: to }),
      q<any[]>(supabase.from('hse_incidents').select('id,number,kind,occurred_at,location,description,status').eq('company_id', cid).order('occurred_at', { ascending: false }).limit(8) as any),
      q<any[]>(supabase.from('hse_actions').select('*').eq('company_id', cid).in('status', ['open', 'done']).order('due_date', { nullsFirst: false }).limit(200) as any),
      q<any[]>(supabase.from('compliance_obligations').select('*').eq('company_id', cid).neq('status', 'retired').order('expires_on', { nullsFirst: false }) as any),
      q<any[]>(supabase.from('hse_policies').select('id,title,version,requires_ack').eq('company_id', cid).eq('active', true) as any),
      q<any[]>(supabase.from('hse_policy_acks').select('policy_id,version').eq('company_id', cid).eq('user_id', session!.user.id) as any),
    ]);
    return { s: stats[0], incidents, actions, obligations, policies, acks };
  }, [cid, from, to]);
  const s = data?.s;
  const mine = (data?.actions || []).filter(a => a.owner_id === b.me && a.status === 'open');
  const overdue = (data?.actions || []).filter(a => a.status === 'open' && a.due_date && a.due_date < today());
  const toVerify = (data?.actions || []).filter(a => a.status === 'done');
  const dueObl = (data?.obligations || []).filter(o => ['bad', 'warn'].includes(oblState(o)[1]));
  const toRead = (data?.policies || []).filter(p => p.requires_ack && !data!.acks.some(a => a.policy_id === p.id && a.version === p.version));
  const pdf = () => s && tablePdf({ company: company!, title: 'Health, safety and compliance performance', subtitle: `${longDate(from)} to ${longDate(to)}`,
    head: ['Measure', 'Value', 'Basis'], rightAlign: [1], filename: `hse-performance-${from}-${to}`,
    body: [['Hours worked', n1(s.hours), 'Approved timesheets plus recorded site and subcontractor hours'],
      ['Lost-time injuries (LTI)', s.ltis, 'Lost-time injuries and fatalities'], ['Lost-time injury frequency rate (LTIFR)', n1(s.ltifr), 'LTIs × 1,000,000 ÷ hours worked'],
      ['Total recordable injuries', s.recordables, 'Medical treatment, restricted work, lost time, fatality, occupational illness'],
      ['Total recordable injury rate (TRIR)', n1(s.trir), 'Recordables × 200,000 ÷ hours worked'], ['Fatalities', s.fatalities, ''], ['Days lost', s.lost_days, ''],
      ['First-aid cases', s.first_aid, ''], ['Near misses reported', s.near_misses, 'Leading indicator'], ['Safety observations reported', s.observations, 'Leading indicator'],
      ['Days without a lost-time injury', s.days_since_lti ?? '—', 'Company-wide, to today'], ['Toolbox talks held', s.toolbox_talks, `${s.toolbox_attendance} attendances`],
      ['People inducted', s.inductions, 'Company, site and visitor inductions'], ['Emergency drills', s.drills, ''], ['Inspections completed', s.inspections, ''], ['Average inspection score', s.avg_score != null ? s.avg_score + '%' : '—', 'Items passed ÷ items checked'],
      ['Open corrective actions', s.open_actions, `${s.overdue_actions} overdue`], ['Compliance obligations expired', s.obligations_expired, `${s.obligations_due} due soon`]],
    notes: 'Rates follow common international practice: LTIFR per 1,000,000 hours (ILO / ISO 45001 reporting) and TRIR per 200,000 hours (OSHA).' });
  return <>
    <PageHead title="Health, safety and compliance" sub="ISO 45001 safety · ISO 37301 compliance · ISO 14001 and GHG Protocol sustainability">
      <select aria-label="Period" value={period} onChange={e => setPeriod(e.target.value)} style={{ width: 'auto' }}>{PERIODS.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select>
      <button className="btn" type="button" onClick={pdf} disabled={!s}>Report PDF</button>
      <button className="btn primary" type="button" onClick={() => setReport(true)}>Report incident or hazard</button>
    </PageHead>
    <Loading error={error} loading={loading && !data} />
    {s && <>
      <div className="tiles">
        <div className="tile"><span>LTIFR (per 1,000,000 h)</span><b>{n1(s.ltifr)}</b><span>{s.ltis} lost-time injur{s.ltis === 1 ? 'y' : 'ies'} · {n1(s.hours)} h worked</span></div>
        <div className="tile"><span>TRIR (per 200,000 h)</span><b>{n1(s.trir)}</b><span>{s.recordables} recordable · {s.lost_days} days lost</span></div>
        <div className="tile"><span>Near misses and observations</span><b>{s.near_misses + s.observations}</b><span>{s.near_misses} near miss{s.near_misses === 1 ? '' : 'es'} · {s.observations} observation{s.observations === 1 ? '' : 's'}</span></div>
        <div className="tile"><span>Days without a lost-time injury</span><b style={{ color: 'var(--good)' }}>{s.days_since_lti ?? '—'}</b><span>company-wide</span></div>
        <div className="tile"><span>Toolbox talks and inductions</span><b>{s.toolbox_talks}</b><span>{s.toolbox_attendance} attendances · {s.inductions} inducted · {s.drills} drill{s.drills === 1 ? '' : 's'}</span></div>
        <div className="tile"><span>Inspections</span><b>{s.inspections}</b><span>average score {s.avg_score != null ? s.avg_score + '%' : '—'}</span></div>
        <div className="tile"><span>Corrective actions open</span><b style={{ color: s.overdue_actions ? 'var(--bad)' : undefined }}>{s.open_actions}</b><span>{s.overdue_actions} overdue</span></div>
        <div className="tile"><span>Permits active now</span><b>{s.permits_active}</b><span><Link to="/hse/permits">Permits to work</Link></span></div>
        <div className="tile"><span>Compliance register</span><b style={{ color: s.obligations_expired ? 'var(--bad)' : undefined }}>{s.obligations_expired}</b><span>expired · {s.obligations_due} due soon</span></div>
      </div>
      {!s.hours && <div className="note" style={{ marginTop: 12 }}>No hours worked recorded for this period, so LTIFR and TRIR cannot be worked out. Hours come from approved timesheets; add site labour and subcontractor hours on <Link to="/hse/sustainability">Sustainability → Hours worked</Link>.</div>}
      {toRead.length > 0 && <Panel title="Policies for you to read" pad><div style={{ display: 'grid', gap: 6 }}>{toRead.map(p => <div key={p.id}><Link to="/hse/policies">{p.title}</Link> <span className="muted">version {p.version}</span></div>)}</div></Panel>}
      {mine.length > 0 && <Panel title="Your actions"><ActionTable rows={mine} b={b} /></Panel>}
      <div className="grid-2">
        <Panel title="Latest reports" actions={<Link className="btn small" to="/hse/incidents">All</Link>}>
          {data!.incidents.length ? <table><tbody>{data!.incidents.map(i => <tr key={i.id} className="click" onClick={() => nav('/hse/incidents/' + i.id)}>
            <td className="num" style={{ whiteSpace: 'nowrap' }}>{i.number}<br /><span className="muted" style={{ fontSize: 12 }}>{dt(i.occurred_at)}</span></td><td><KindPill k={i.kind} /><div className="wrap-cell" style={{ fontSize: 13 }}>{i.description.slice(0, 90)}</div></td>
            <td><Pill map={INC_STATUS} s={i.status} /></td></tr>)}</tbody></table> : <Empty>Nothing reported yet.</Empty>}
        </Panel>
        <Panel title="Needs attention">
          {overdue.length + toVerify.length + dueObl.length ? <table><tbody>
            {overdue.slice(0, 6).map(a => <tr key={a.id}><td><span className="pill bad">Overdue</span></td><td><Link to="/hse/actions">{a.number}</Link> {a.title}</td><td className="muted">{b.who(a.owner_id)}</td></tr>)}
            {toVerify.slice(0, 6).map(a => <tr key={a.id}><td><span className="pill">To verify</span></td><td><Link to="/hse/actions">{a.number}</Link> {a.title}</td><td className="muted">{b.who(a.done_by)}</td></tr>)}
            {dueObl.slice(0, 8).map(o => <tr key={o.id}><td><span className={'pill ' + oblState(o)[1]}>{oblState(o)[0]}</span></td><td><Link to="/hse/obligations">{o.title}</Link></td><td className="muted">{o.authority}</td></tr>)}
          </tbody></table> : <Empty>Nothing overdue, nothing waiting for verification, nothing expiring.</Empty>}
        </Panel>
      </div>
    </>}
    {report && <ReportIncident onClose={() => setReport(false)} onDone={id => nav('/hse/incidents/' + id)} />}
  </>;
}

// ---------------------------------------------------------------- Incidents
export function HseIncidentsPage() {
  const { cid, company } = useSession();
  const nav = useNavigate();
  const b = useHseBasics();
  const [view, setView] = useState('open');
  const [kind, setKind] = useState('');
  const [report, setReport] = useState(false);
  const { data, error, loading } = useLoad(() => q<any[]>(supabase.from('hse_incidents').select('*').eq('company_id', cid).order('occurred_at', { ascending: false }).limit(1000) as any), [cid]);
  const rows = (data || []).filter(i => (view === 'all' || (view === 'open' ? i.status !== 'closed' : view === 'injuries' ? ['first_aid', 'medical_treatment', 'restricted_work', 'lost_time', 'fatality', 'occupational_illness'].includes(i.kind) : i.status === 'closed')) && (!kind || i.kind === kind));
  const head = ['No.', 'When', 'Type', 'Project', 'Location', 'What happened', 'Days lost', 'Status'];
  const body = rows.map(i => [i.number, dt(i.occurred_at), kindLabel(i.kind), b.proj(i.project_id), i.location || '', i.description, i.lost_days || '', INC_STATUS[i.status][0]]);
  return <>
    <PageHead title="Incidents, near misses and observations" sub={data ? `${data.filter(i => i.status !== 'closed').length} open · ${data.length} in total` : undefined}>
      <button className="btn" type="button" onClick={() => tablePdf({ company: company!, title: 'Incident register', subtitle: longDate(today()), head, body, landscape: true, filename: 'incident-register' })}>Register PDF</button>
      <button className="btn" type="button" onClick={() => downloadCsv('incident-register', head, body)}>CSV</button>
      <button className="btn primary" type="button" onClick={() => setReport(true)}>Report incident or hazard</button>
    </PageHead>
    <div className="filters"><div className="actions" style={{ alignSelf: 'end' }}>{([['open', 'Open'], ['injuries', 'Injuries'], ['closed', 'Closed'], ['all', 'All']] as const).map(([k, l]) =>
      <button key={k} type="button" className={'btn small' + (view === k ? ' primary' : '')} onClick={() => setView(k)}>{l}</button>)}</div>
      <Select label="Type" id="inc-kind" value={kind} onChange={setKind} options={[['', 'All types'], ...INC_KINDS.map(k => [k[0], kindLabel(k[0])] as [string, string])]} /></div>
    <Loading error={error} loading={loading && !data} />
    {data && <Panel>{rows.length ? <div className="scroll"><table>
      <thead><tr><th>Report</th><th>Type</th><th>What happened</th><th>Where</th><th>Status</th></tr></thead>
      <tbody>{rows.map(i => <tr key={i.id} className="click" tabIndex={0} onClick={() => nav('/hse/incidents/' + i.id)} onKeyDown={e => e.key === 'Enter' && nav('/hse/incidents/' + i.id)}>
        <td className="num">{i.number}<br /><span className="muted" style={{ fontSize: 12 }}>{dt(i.occurred_at)}</span></td><td><KindPill k={i.kind} /></td>
        <td className="wrap-cell">{i.description.slice(0, 140)}</td><td>{[b.proj(i.project_id), i.location].filter(Boolean).join(' · ')}</td><td><Pill map={INC_STATUS} s={i.status} /></td></tr>)}</tbody>
    </table></div> : <Empty>Nothing here. Everyone can report incidents, near misses and unsafe conditions from this page or the HSE home page.</Empty>}</Panel>}
    {report && <ReportIncident onClose={() => setReport(false)} onDone={id => nav('/hse/incidents/' + id)} />}
  </>;
}

export function HseIncidentView() {
  const { id } = useParams();
  const { cid, company } = useSession();
  const b = useHseBasics();
  const act = useAction();
  const [edit, setEdit] = useState<any | null>(null);
  const [step, setStep] = useState<{ a: string; title: string; note: string; inv?: string } | null>(null);
  const [newAct, setNewAct] = useState<any | null>(null);
  const { data, error, loading, reload } = useLoad(async () => {
    const i = await q<any>(supabase.from('hse_incidents').select('*').eq('id', id).single() as any);
    const actions = await q<any[]>(supabase.from('hse_actions').select('*').eq('source', 'incident').eq('source_id', id).order('created_at') as any);
    return { i, actions };
  }, [id]);
  if (!data) return <Loading error={error} loading={loading} />;
  const { i, actions } = data;
  const manage = b.hse || b.pm(i.project_id) || i.investigator_id === b.me;
  const canEdit = i.status !== 'closed' && (manage || (i.status === 'reported' && i.reported_by === b.me));
  const pdf = () => tablePdf({ company: company!, title: `Incident report ${i.number}`, subtitle: kindLabel(i.kind), head: ['', ''], filename: `incident-${i.number}`,
    body: [['Type', kindLabel(i.kind)], ['When', dt(i.occurred_at)], ['Project', b.proj(i.project_id) || '—'], ['Location', i.location || '—'], ['Reported by', `${i.reported_email || ''} on ${longDate(i.created_at)}`],
      ['What happened', i.description], ['Immediate action', i.immediate_action || '—'], ['People involved', i.persons_involved || '—'],
      ['Injury', [i.injury_nature, i.body_part].filter(Boolean).join(', ') || '—'], ['Days lost', String(i.lost_days || 0)], ['Potential severity', i.potential_severity ? i.potential_severity + ' of 5' : '—'],
      ['Investigator', b.who(i.investigator_id) || '—'], ['Root cause', i.root_cause || '—'], ['Contributing factors', i.contributing_factors || '—'], ['Findings', i.findings || '—'],
      ['Reportable to authority', i.reportable ? `Yes · ${i.authority || ''} · ${i.authority_ref || 'reference not recorded'} · ${i.reported_to_authority_on ? longDate(i.reported_to_authority_on) : 'date not recorded'}` : 'No'],
      ...actions.map(a => [`Action ${a.number}`, `${a.title} · ${b.who(a.owner_id)} · due ${a.due_date ? longDate(a.due_date) : '—'} · ${ACT_STATUS[a.status][0]}`] as [string, string]),
      ['Status', INC_STATUS[i.status][0] + (i.closed_at ? ` · ${longDate(i.closed_at)} · ${i.closure_note || ''}` : '')]] });
  const steps: [string, string][] = i.status === 'reported' ? [['investigate', 'Start investigation']] : i.status === 'investigating' ? [['actions', 'Root cause found: actions under way']] : i.status === 'action' ? [['close', 'Close incident']] : [['reopen', 'Reopen']];
  return <>
    <PageHead title={`${i.number} · ${kindLabel(i.kind)}`} sub={<><Pill map={INC_STATUS} s={i.status} /> {dt(i.occurred_at)}{i.location ? ' · ' + i.location : ''}{b.proj(i.project_id) ? ' · ' + b.proj(i.project_id) : ''}</>}>
      <Link className="btn" to="/hse/incidents">Back</Link>
      <button className="btn" type="button" onClick={pdf}>Report PDF</button>
      {canEdit && <button className="btn" type="button" onClick={() => setEdit({ ...i, occurred_at: toLocal(i.occurred_at), lost_days: String(i.lost_days ?? 0), potential_severity: i.potential_severity ? String(i.potential_severity) : '', investigator_id: i.investigator_id || '' })}>{manage ? 'Edit and investigate' : 'Edit'}</button>}
      {manage && steps.filter(([a]) => !['close', 'reopen'].includes(a) || b.hse).map(([a, l]) => <button key={a} className="btn primary" type="button" onClick={() => setStep({ a, title: l, note: '', inv: i.investigator_id || b.me || '' })}>{l}</button>)}
    </PageHead>
    <div className="grid-2">
      <Panel title="What happened" pad><div style={{ display: 'grid', gap: 10 }}>
        <div>{i.description}</div>
        {i.immediate_action && <div><div className="label">Immediate action</div>{i.immediate_action}</div>}
        {i.persons_involved && <div><div className="label">People involved</div>{i.persons_involved}</div>}
        {(i.injury_nature || i.body_part || i.lost_days > 0) && <div><div className="label">Injury</div>{[i.injury_nature, i.body_part].filter(Boolean).join(', ')}{i.lost_days ? ` · ${i.lost_days} days lost` : ''}</div>}
        <div className="muted" style={{ fontSize: 13 }}>Reported by {i.reported_email} on {longDate(i.created_at)}{i.potential_severity ? ` · potential severity ${i.potential_severity} of 5` : ''}</div>
      </div></Panel>
      <Panel title="Investigation" pad><div style={{ display: 'grid', gap: 10 }}>
        <div><div className="label">Investigator</div>{b.who(i.investigator_id) || <span className="muted">Not assigned</span>}</div>
        <div><div className="label">Root cause</div>{i.root_cause || <span className="muted">Not recorded yet. Ask "why?" until you reach the cause a fix can remove.</span>}</div>
        {i.contributing_factors && <div><div className="label">Contributing factors</div>{i.contributing_factors}</div>}
        {i.findings && <div><div className="label">Findings and lessons</div>{i.findings}</div>}
        <div><div className="label">Reportable to an authority</div>{i.reportable ? `Yes · ${i.authority || 'authority not named'} · ${i.authority_ref || 'no reference yet'}${i.reported_to_authority_on ? ' · reported ' + longDate(i.reported_to_authority_on) : ''}` : 'No'}</div>
        {i.closed_at && <div><div className="label">Closed</div>{longDate(i.closed_at)} · {b.who(i.closed_by)}{i.closure_note ? ': ' + i.closure_note : ''}</div>}
      </div></Panel>
    </div>
    <Panel title="Corrective and preventive actions" actions={manage && i.status !== 'closed' && <button className="btn small primary" type="button" onClick={() => setNewAct({ source: 'incident', source_id: i.id, project_id: i.project_id || '', title: '', description: '', kind: 'corrective', priority: 'medium', owner_id: '', due_date: '' })}>Add action</button>}>
      {actions.length ? <ActionTable rows={actions} b={b} onChange={reload} /> : <Empty>No actions yet. Every cause found should have an action that removes or controls it.</Empty>}
    </Panel>
    <Files type="incident" id={i.id} canAdd />
    {edit && <FormModal title={`Edit ${i.number}`} busy={act.busy} onClose={() => setEdit(null)} onSave={() => act.run(async () => {
      await q(supabase.from('hse_incidents').update({ kind: edit.kind, occurred_at: new Date(edit.occurred_at).toISOString(), project_id: edit.project_id || null, location: edit.location || null,
        description: edit.description, immediate_action: edit.immediate_action || null, persons_involved: edit.persons_involved || null, injured_employee_id: edit.injured_employee_id || null,
        injury_nature: edit.injury_nature || null, body_part: edit.body_part || null, lost_days: Number(edit.lost_days) || 0, potential_severity: edit.potential_severity ? Number(edit.potential_severity) : null,
        ...(manage ? { investigator_id: edit.investigator_id || null, root_cause: edit.root_cause || null, contributing_factors: edit.contributing_factors || null, findings: edit.findings || null,
          reportable: !!edit.reportable, authority: edit.authority || null, authority_ref: edit.authority_ref || null, reported_to_authority_on: edit.reported_to_authority_on || null, cost_estimate: edit.cost_estimate ? Number(edit.cost_estimate) : null } : {}) }).eq('id', i.id) as any);
      setEdit(null); reload(); }, 'Saved')}>
      <div className="grid-form">
        <Select label="Type" id="ie-kind" value={edit.kind} onChange={v => setEdit({ ...edit, kind: v })} options={INC_KINDS.map(k => [k[0], kindLabel(k[0])] as [string, string])} />
        <Field label="When" id="ie-when" type="datetime-local" value={edit.occurred_at} onChange={v => setEdit({ ...edit, occurred_at: v })} />
        <Select label="Project" id="ie-proj" value={edit.project_id || ''} onChange={v => setEdit({ ...edit, project_id: v })} options={b.projOpts} />
        <Field label="Location" id="ie-loc" value={edit.location} onChange={v => setEdit({ ...edit, location: v })} />
        <Field label="Injury" id="ie-inj" value={edit.injury_nature} onChange={v => setEdit({ ...edit, injury_nature: v })} />
        <Field label="Part of the body" id="ie-body" value={edit.body_part} onChange={v => setEdit({ ...edit, body_part: v })} />
        <Field label="Days lost" id="ie-lost" type="number" min="0" value={edit.lost_days} onChange={v => setEdit({ ...edit, lost_days: v })} />
        <Select label="Potential severity" id="ie-pot" value={edit.potential_severity} onChange={v => setEdit({ ...edit, potential_severity: v })} options={[['', '—'], ['1', '1 · Negligible'], ['2', '2 · Minor'], ['3', '3 · Moderate'], ['4', '4 · Major'], ['5', '5 · Catastrophic']]} />
      </div>
      <Field label="What happened" id="ie-desc" type="textarea" value={edit.description} onChange={v => setEdit({ ...edit, description: v })} />
      <Field label="Immediate action" id="ie-imm" type="textarea" value={edit.immediate_action} onChange={v => setEdit({ ...edit, immediate_action: v })} />
      <Field label="People involved or witnesses" id="ie-people" value={edit.persons_involved} onChange={v => setEdit({ ...edit, persons_involved: v })} />
      {manage && <>
        <h3 style={{ margin: '8px 0 0' }}>Investigation</h3>
        <Select label="Investigator" id="ie-inv" value={edit.investigator_id} onChange={v => setEdit({ ...edit, investigator_id: v })} options={b.teamOpts} />
        <Field label="Root cause (keep asking why)" id="ie-root" type="textarea" value={edit.root_cause} onChange={v => setEdit({ ...edit, root_cause: v })} />
        <Field label="Contributing factors (people, equipment, method, environment, management)" id="ie-contrib" type="textarea" value={edit.contributing_factors} onChange={v => setEdit({ ...edit, contributing_factors: v })} />
        <Field label="Findings and lessons learned" id="ie-find" type="textarea" value={edit.findings} onChange={v => setEdit({ ...edit, findings: v })} />
        <Field label="Estimated cost (GH₵)" id="ie-cost" type="number" step="0.01" min="0" value={edit.cost_estimate ?? ''} onChange={v => setEdit({ ...edit, cost_estimate: v })} />
        <label className="check"><input type="checkbox" checked={!!edit.reportable} onChange={e => setEdit({ ...edit, reportable: e.target.checked })} /> Must be reported to an authority (e.g. Factories Inspectorate, EPA, Labour Department)</label>
        {edit.reportable && <div className="grid-form">
          <Field label="Authority" id="ie-auth" value={edit.authority} onChange={v => setEdit({ ...edit, authority: v })} />
          <Field label="Date reported" id="ie-authd" type="date" value={edit.reported_to_authority_on || ''} onChange={v => setEdit({ ...edit, reported_to_authority_on: v })} />
          <Field label="Their reference" id="ie-authr" value={edit.authority_ref} onChange={v => setEdit({ ...edit, authority_ref: v })} />
        </div>}
      </>}
    </FormModal>}
    {step && <FormModal title={step.title} submit={step.title} busy={act.busy} onClose={() => setStep(null)} onSave={() => act.run(async () => {
      await rpc('hse_incident_step', { p_id: i.id, p_action: step.a, p_note: step.note || null, p_investigator: step.a === 'investigate' ? step.inv || null : null }); setStep(null); reload(); }, 'Done')}>
      {step.a === 'investigate' && <Select label="Who investigates" id="is-inv" value={step.inv} onChange={v => setStep({ ...step, inv: v })} options={b.teamOpts} />}
      {step.a === 'actions' && <p style={{ margin: 0 }}>Make sure the root cause is recorded (Edit and investigate), then add an action for each cause.</p>}
      {step.a === 'close' && <p style={{ margin: 0 }}>Closing needs the root cause, every action verified or cancelled and, if reportable, the report to the authority recorded.</p>}
      {['close', 'reopen'].includes(step.a) && <Field label={step.a === 'reopen' ? 'Reason (required)' : 'Closing note'} id="is-note" type="textarea" value={step.note} onChange={v => setStep({ ...step, note: v })} />}
    </FormModal>}
    {newAct && <ActionForm f={newAct} setF={setNewAct} b={b} onDone={() => { setNewAct(null); reload(); }} cid={cid} />}
  </>;
}

// ---------------------------------------------------------------- Actions (CAPA)
function ActionForm({ f, setF, b, onDone, cid }: { f: any; setF: (v: any) => void; b: ReturnType<typeof useHseBasics>; onDone: () => void; cid: string }) {
  const act = useAction();
  return <FormModal title={f.id ? `Edit ${f.number}` : 'New corrective or preventive action'} busy={act.busy} onClose={() => setF(null)} onSave={() => act.run(async () => {
    const row = { title: f.title, description: f.description || null, kind: f.kind, priority: f.priority, owner_id: f.owner_id || null, due_date: f.due_date || null, project_id: f.project_id || null };
    if (f.id) await q(supabase.from('hse_actions').update(row).eq('id', f.id) as any);
    else await q(supabase.from('hse_actions').insert({ ...row, company_id: cid, source: f.source || 'other', source_id: f.source_id || null }) as any);
    onDone(); }, f.id ? 'Saved' : 'Action raised; the owner has been told')}>
    <Field label="What must be done" id="ac-title" value={f.title} onChange={v => setF({ ...f, title: v })} required />
    <div className="grid-form">
      <Select label="Type" id="ac-kind" value={f.kind} onChange={v => setF({ ...f, kind: v })} options={[['corrective', 'Corrective (fix a cause)'], ['preventive', 'Preventive (stop it happening)'], ['improvement', 'Improvement']]} />
      <Select label="Priority" id="ac-pri" value={f.priority} onChange={v => setF({ ...f, priority: v })} options={[['high', 'High'], ['medium', 'Medium'], ['low', 'Low']]} />
      <Select label="Owner" id="ac-owner" value={f.owner_id} onChange={v => setF({ ...f, owner_id: v })} options={b.teamOpts} />
      <Field label="Due" id="ac-due" type="date" value={f.due_date} onChange={v => setF({ ...f, due_date: v })} />
      {!f.source_id && <Select label="Project" id="ac-proj" value={f.project_id || ''} onChange={v => setF({ ...f, project_id: v })} options={b.projOpts} />}
      {!f.id && !f.source_id && <Select label="Raised from" id="ac-src" value={f.source || 'other'} onChange={v => setF({ ...f, source: v })} options={[['audit', 'Audit'], ['management_review', 'Management review'], ['risk', 'Risk assessment'], ['observation', 'Observation'], ['other', 'Other']]} />}
    </div>
    <Field label="Details" id="ac-desc" type="textarea" value={f.description} onChange={v => setF({ ...f, description: v })} />
  </FormModal>;
}

function ActionTable({ rows, b, onChange }: { rows: any[]; b: ReturnType<typeof useHseBasics>; onChange?: () => void }) {
  const act = useAction();
  const [step, setStep] = useState<{ a: any; s: string; title: string; note: string } | null>(null);
  return <><div className="scroll"><table>
    <thead><tr><th>Action</th><th>Owner</th><th>Due</th><th>Status</th><th></th></tr></thead>
    <tbody>{rows.map(a => { const late = a.status === 'open' && a.due_date && a.due_date < today(); const mine = a.owner_id === b.me; const mgr = b.hse || b.pm(a.project_id);
      return <tr key={a.id}>
        <td><b>{a.title}</b><br /><span className="muted num" style={{ fontSize: 12 }}>{a.number} · {a.kind} · {a.priority} priority · from {a.source.replace('_', ' ')}</span>
          {a.done_note && <div className="muted" style={{ fontSize: 12 }}>Done: {a.done_note}</div>}{a.verify_note && <div className="muted" style={{ fontSize: 12 }}>Check: {a.verify_note}</div>}</td>
        <td>{b.who(a.owner_id) || <span className="muted">Nobody</span>}</td>
        <td className="num" style={{ color: late ? 'var(--bad)' : undefined }}>{a.due_date ? longDate(a.due_date) : '—'}</td>
        <td><Pill map={ACT_STATUS} s={a.status} /></td>
        <td className="r" style={{ whiteSpace: 'nowrap' }}>{onChange && <>
          {a.status === 'open' && (mine || mgr) && <button className="btn small primary" type="button" onClick={() => setStep({ a, s: 'done', title: 'Mark done', note: '' })}>Mark done</button>}
          {a.status === 'done' && b.hse && a.done_by !== b.me && <button className="btn small primary" type="button" onClick={() => setStep({ a, s: 'verify', title: 'Verify it worked', note: '' })}>Verify</button>}
          {a.status === 'done' && b.hse && <button className="btn small" type="button" onClick={() => setStep({ a, s: 'reopen', title: 'Send back', note: '' })}>Send back</button>}
          {['open', 'done'].includes(a.status) && b.hse && <button className="btn small ghost" type="button" onClick={() => setStep({ a, s: 'cancel', title: 'Cancel action', note: '' })}>Cancel</button>}
        </>}</td></tr>; })}</tbody>
  </table></div>
    {step && <FormModal title={`${step.title}: ${step.a.number}`} submit={step.title} busy={act.busy} onClose={() => setStep(null)} onSave={() => act.run(async () => {
      await rpc('hse_action_step', { p_id: step.a.id, p_action: step.s, p_note: step.note || null }); setStep(null); onChange?.(); }, 'Done')}>
      <p style={{ margin: 0 }}>{step.a.title}</p>
      <Field label={step.s === 'done' ? 'What was done (required)' : step.s === 'verify' ? 'How you checked it works' : 'Reason (required)'} id="as-note" type="textarea" value={step.note} onChange={v => setStep({ ...step, note: v })} />
    </FormModal>}
  </>;
}

export function HseActionsPage() {
  const { cid, company } = useSession();
  const b = useHseBasics();
  const [view, setView] = useState('open');
  const [form, setForm] = useState<any | null>(null);
  const { data, error, loading, reload } = useLoad(() => q<any[]>(supabase.from('hse_actions').select('*').eq('company_id', cid).order('due_date', { nullsFirst: false }).limit(2000) as any), [cid]);
  const rows = (data || []).filter(a => view === 'all' ? true : view === 'mine' ? a.owner_id === b.me && ['open', 'done'].includes(a.status)
    : view === 'overdue' ? a.status === 'open' && a.due_date && a.due_date < today() : view === 'verify' ? a.status === 'done' : view === 'closed' ? ['verified', 'cancelled'].includes(a.status) : a.status === 'open');
  const head = ['No.', 'Action', 'Type', 'Priority', 'From', 'Owner', 'Due', 'Status', 'Done', 'Verified'];
  const body = rows.map(a => [a.number, a.title, a.kind, a.priority, a.source, b.who(a.owner_id), a.due_date || '', ACT_STATUS[a.status][0], a.done_at ? a.done_at.slice(0, 10) : '', a.verified_at ? a.verified_at.slice(0, 10) : '']);
  return <>
    <PageHead title="Corrective and preventive actions" sub="Every action has an owner and a due date; an HSE officer other than the person who did it verifies that it worked.">
      <button className="btn" type="button" onClick={() => tablePdf({ company: company!, title: 'Corrective and preventive actions', subtitle: longDate(today()), head, body, landscape: true, filename: 'capa-register' })}>PDF</button>
      <button className="btn" type="button" onClick={() => downloadCsv('capa-register', head, body)}>CSV</button>
      {b.hse && <button className="btn primary" type="button" onClick={() => setForm({ title: '', description: '', kind: 'corrective', priority: 'medium', owner_id: '', due_date: '', project_id: '', source: 'other' })}>New action</button>}
    </PageHead>
    <div className="filters"><div className="actions" style={{ alignSelf: 'end' }}>{([['open', 'Open'], ['mine', 'Mine'], ['overdue', 'Overdue'], ['verify', 'To verify'], ['closed', 'Closed'], ['all', 'All']] as const).map(([k, l]) =>
      <button key={k} type="button" className={'btn small' + (view === k ? ' primary' : '')} onClick={() => setView(k)}>{l}</button>)}</div></div>
    <Loading error={error} loading={loading && !data} />
    {data && <Panel>{rows.length ? <ActionTable rows={rows} b={b} onChange={reload} /> : <Empty>Nothing here.</Empty>}</Panel>}
    {form && <ActionForm f={form} setF={setForm} b={b} cid={cid} onDone={() => { setForm(null); reload(); }} />}
  </>;
}

// ---------------------------------------------------------------- Inspections and checklists
export function HseInspectionsPage() {
  const { cid, company } = useSession();
  const nav = useNavigate();
  const b = useHseBasics();
  const act = useAction();
  const [start, setStart] = useState<any | null>(null);
  const [lists, setLists] = useState(false);
  const [cl, setCl] = useState<any | null>(null);
  const { data, error, loading, reload } = useLoad(async () => {
    const [ins, checklists] = await Promise.all([
      q<any[]>(supabase.from('hse_inspections').select('id,number,title,kind,project_id,location,inspected_on,inspector_email,score,status').eq('company_id', cid).order('inspected_on', { ascending: false }).limit(1000) as any),
      q<any[]>(supabase.from('hse_checklists').select('*').eq('company_id', cid).order('name') as any),
    ]);
    return { ins, checklists };
  }, [cid]);
  const head = ['No.', 'Date', 'Inspection', 'Project / location', 'Inspector', 'Score', 'Status'];
  const body = (data?.ins || []).map(s => [s.number, s.inspected_on, s.title, [b.proj(s.project_id), s.location].filter(Boolean).join(' · '), (s.inspector_email || '').split('@')[0], s.score != null ? s.score + '%' : '', s.status]);
  return <>
    <PageHead title="Inspections, audits and toolbox talks" sub="Use a checklist on site (phone or tablet). Every failed item becomes a corrective action.">
      <button className="btn" type="button" onClick={() => tablePdf({ company: company!, title: 'Inspection register', subtitle: longDate(today()), head, body, landscape: true, filename: 'inspection-register' })}>PDF</button>
      {b.hse && <button className="btn" type="button" onClick={() => setLists(!lists)}>{lists ? 'Hide checklists' : 'Checklists'}</button>}
      <button className="btn primary" type="button" onClick={() => setStart({ checklist_id: data?.checklists.find(c => c.active)?.id || '', title: '', project_id: '', location: '', inspected_on: today(), attendees: '' })}>Start inspection</button>
    </PageHead>
    <Loading error={error} loading={loading && !data} />
    {lists && data && <Panel title="Checklists" actions={<button className="btn small primary" type="button" onClick={() => setCl({ name: '', kind: 'inspection', items: '', active: true })}>New checklist</button>}>
      <table><tbody>{data.checklists.map(c => <tr key={c.id}><td><b>{c.name}</b><br /><span className="muted" style={{ fontSize: 12 }}>{c.kind.replace('_', ' ')} · {c.items.length} items{c.active ? '' : ' · not in use'}</span></td>
        <td className="r"><button className="btn small" type="button" onClick={() => setCl({ ...c, items: c.items.join('\n') })}>Edit</button></td></tr>)}</tbody></table>
    </Panel>}
    {data && <Panel>{data.ins.length ? <div className="scroll"><table>
      <thead><tr><th>Inspection</th><th>Where</th><th>Inspector</th><th className="r">Score</th><th>Status</th></tr></thead>
      <tbody>{data.ins.map(s => <tr key={s.id} className="click" tabIndex={0} onClick={() => nav('/hse/inspections/' + s.id)} onKeyDown={e => e.key === 'Enter' && nav('/hse/inspections/' + s.id)}>
        <td><b>{s.title}</b><br /><span className="muted num" style={{ fontSize: 12 }}>{s.number} · {longDate(s.inspected_on)}</span></td>
        <td>{[b.proj(s.project_id), s.location].filter(Boolean).join(' · ')}</td><td>{(s.inspector_email || '').split('@')[0]}</td>
        <td className="r num" style={{ color: s.score != null && s.score < 80 ? 'var(--bad)' : undefined }}>{s.score != null ? s.score + '%' : ''}</td>
        <td>{s.status === 'completed' ? <span className="pill good">Completed</span> : <span className="pill warn">In progress</span>}</td></tr>)}</tbody>
    </table></div> : <Empty>No inspections yet. Seven checklists are ready: site safety, electrical isolation (LOTO), work at height, vehicle pre-use, fire safety, office and toolbox talk.</Empty>}</Panel>}
    {start && data && <FormModal title="Start an inspection" submit="Start" busy={act.busy} onClose={() => setStart(null)} onSave={() => act.run(async () => {
      const c = data.checklists.find(x => x.id === start.checklist_id);
      const r = await q<any>(supabase.from('hse_inspections').insert({ company_id: cid, checklist_id: start.checklist_id || null, title: start.title || c?.name || 'Inspection', project_id: start.project_id || null,
        location: start.location || null, inspected_on: start.inspected_on, attendees: start.attendees || null }).select('id').single() as any);
      nav('/hse/inspections/' + r.id); })}>
      <Select label="Checklist" id="st-cl" value={start.checklist_id} onChange={v => setStart({ ...start, checklist_id: v })} options={data.checklists.filter(c => c.active).map(c => [c.id, c.name] as [string, string])} />
      <div className="grid-form">
        <Field label="Title (optional)" id="st-title" value={start.title} onChange={v => setStart({ ...start, title: v })} />
        <Field label="Date" id="st-date" type="date" value={start.inspected_on} onChange={v => setStart({ ...start, inspected_on: v })} />
        <Select label="Project" id="st-proj" value={start.project_id} onChange={v => setStart({ ...start, project_id: v })} options={b.projOpts} />
        <Field label="Location" id="st-loc" value={start.location} onChange={v => setStart({ ...start, location: v })} />
      </div>
      <Field label="Attendees (for toolbox talks and audits)" id="st-att" type="textarea" value={start.attendees} onChange={v => setStart({ ...start, attendees: v })} />
    </FormModal>}
    {cl && <FormModal title={cl.id ? 'Edit checklist' : 'New checklist'} busy={act.busy} onClose={() => setCl(null)} onSave={() => act.run(async () => {
      const row = { name: cl.name, kind: cl.kind, items: cl.items.split('\n').map((s: string) => s.trim()).filter(Boolean), active: cl.active };
      if (!row.items.length) throw new Error('Add at least one item to check');
      if (cl.id) await q(supabase.from('hse_checklists').update(row).eq('id', cl.id) as any); else await q(supabase.from('hse_checklists').insert({ ...row, company_id: cid }) as any);
      setCl(null); reload(); }, 'Checklist saved')}>
      <div className="grid-form">
        <Field label="Name" id="cl-name" value={cl.name} onChange={v => setCl({ ...cl, name: v })} required />
        <Select label="Type" id="cl-kind" value={cl.kind} onChange={v => setCl({ ...cl, kind: v })} options={[['inspection', 'Inspection'], ['audit', 'Audit'], ['pre_use', 'Pre-use check'], ['toolbox', 'Toolbox talk']]} />
      </div>
      <Field label="Items to check (one per line)" id="cl-items" type="textarea" value={cl.items} onChange={v => setCl({ ...cl, items: v })} />
      <label className="check"><input type="checkbox" checked={cl.active} onChange={e => setCl({ ...cl, active: e.target.checked })} /> In use</label>
      <p className="muted" style={{ margin: 0, fontSize: 13 }}>Changing a checklist does not change inspections already started.</p>
    </FormModal>}
  </>;
}

export function HseInspectionView() {
  const { id } = useParams();
  const { company } = useSession();
  const b = useHseBasics();
  const act = useAction();
  const [res, setRes] = useState<any[] | null>(null);
  const [due, setDue] = useState('');
  const { data, error, loading, reload } = useLoad(async () => {
    const s = await q<any>(supabase.from('hse_inspections').select('*').eq('id', id).single() as any);
    const actions = await q<any[]>(supabase.from('hse_actions').select('*').eq('source', 'inspection').eq('source_id', id).order('created_at') as any);
    setRes(s.results); return { s, actions };
  }, [id]);
  if (!data || !res) return <Loading error={error} loading={loading} />;
  const { s, actions } = data;
  const editable = s.status === 'draft' && (s.inspector_id === b.me || b.hse || b.pm(s.project_id));
  const setItem = (k: number, patch: any) => setRes(res.map((r, i) => i === k ? { ...r, ...patch } : r));
  const counts = { pass: res.filter(r => r.result === 'pass').length, fail: res.filter(r => r.result === 'fail').length, na: res.filter(r => r.result === 'na').length, blank: res.filter(r => !r.result).length };
  const save = () => act.run(async () => { await q(supabase.from('hse_inspections').update({ results: res, notes: s.notes }).eq('id', s.id) as any); reload(); }, 'Saved');
  const pdf = () => tablePdf({ company: company!, title: `${s.number} ${s.title}`, subtitle: `${longDate(s.inspected_on)} · ${[b.proj(s.project_id), s.location].filter(Boolean).join(' · ')} · inspector ${s.inspector_email || ''}${s.score != null ? ` · score ${s.score}%` : ''}`,
    head: ['#', 'Item', 'Result', 'Note'], body: res.map((r, i) => [i + 1, r.item, r.result === 'pass' ? 'Pass' : r.result === 'fail' ? 'FAIL' : r.result === 'na' ? 'N/A' : '', r.note || '']),
    filename: `inspection-${s.number}`, notes: s.attendees ? 'Attendees: ' + s.attendees : undefined });
  return <>
    <PageHead title={`${s.number} · ${s.title}`} sub={<>{longDate(s.inspected_on)} · {[b.proj(s.project_id), s.location].filter(Boolean).join(' · ')} · {(s.inspector_email || '').split('@')[0]} {s.status === 'completed' ? <span className="pill good">Completed · {s.score}%</span> : <span className="pill warn">In progress</span>}</>}>
      <Link className="btn" to="/hse/inspections">Back</Link>
      <button className="btn" type="button" onClick={pdf}>PDF</button>
      {editable && <button className="btn" type="button" onClick={save} disabled={act.busy}>Save</button>}
      {editable && <button className="btn primary" type="button" disabled={act.busy} onClick={() => act.run(async () => {
        await q(supabase.from('hse_inspections').update({ results: res }).eq('id', s.id) as any);
        const n = await rpc<number>('complete_hse_inspection', { p_id: s.id, p_due: due || null }); reload(); return n; }, 'Inspection completed. An action was raised for each failed item.')}>Complete</button>}
    </PageHead>
    {editable && <div className="note">{counts.pass} pass · {counts.fail} fail · {counts.na} not applicable · <b>{counts.blank} still to check</b>. Save as you go; Complete scores it and raises an action for each failed item
      {counts.fail > 0 && <> due on <input type="date" aria-label="Due date for actions" value={due} onChange={e => setDue(e.target.value)} style={{ width: 'auto', display: 'inline-block' }} /> (default in 7 days)</>}.</div>}
    <Panel>{res.map((r, k) => <div key={k} style={{ display: 'grid', gap: 6, padding: '10px 16px', borderBottom: '1px solid var(--line)' }}>
      <div className="actions" style={{ justifyContent: 'space-between' }}><span><span className="muted num">{k + 1}.</span> {r.item}</span>
        {editable ? <div className="actions">{([['pass', 'Pass', 'good'], ['fail', 'Fail', 'bad'], ['na', 'N/A', '']] as const).map(([v, l]) =>
          <button key={v} type="button" className={'btn small' + (r.result === v ? ' primary' : '')} style={r.result === v && v === 'fail' ? { background: 'var(--bad)', borderColor: 'var(--bad)' } : undefined} onClick={() => setItem(k, { result: v })}>{l}</button>)}</div>
          : <span className={'pill ' + (r.result === 'pass' ? 'good' : r.result === 'fail' ? 'bad' : '')}>{r.result === 'pass' ? 'Pass' : r.result === 'fail' ? 'Fail' : 'N/A'}</span>}</div>
      {editable && r.result === 'fail' && <input aria-label={`Note for item ${k + 1}`} placeholder="What is wrong? (goes on the action)" value={r.note || ''} onChange={e => setItem(k, { note: e.target.value })} />}
      {!editable && r.note && <span className="muted" style={{ fontSize: 13 }}>{r.note}</span>}
    </div>)}</Panel>
    {s.attendees && <Panel title="Attendees" pad>{s.attendees}</Panel>}
    {actions.length > 0 && <Panel title="Actions raised"><ActionTable rows={actions} b={b} onChange={reload} /></Panel>}
    <Files type="inspection" id={s.id} canAdd />
  </>;
}

// ---------------------------------------------------------------- Permits to work
export function HsePermitsPage() {
  const { cid, company } = useSession();
  const b = useHseBasics();
  const act = useAction();
  const [view, setView] = useState('live');
  const [form, setForm] = useState<any | null>(null);
  const [step, setStep] = useState<{ p: any; a: string; title: string; note: string } | null>(null);
  const { data, error, loading, reload } = useLoad(() => q<any[]>(supabase.from('hse_permits').select('*').eq('company_id', cid).order('valid_from', { ascending: false }).limit(1000) as any), [cid]);
  const now = new Date().toISOString();
  const live = (p: any) => p.status === 'approved' && p.valid_from <= now && p.valid_to >= now;
  const overrun = (p: any) => ['approved', 'suspended'].includes(p.status) && p.valid_to < now;
  const rows = (data || []).filter(p => view === 'all' ? true : view === 'waiting' ? p.status === 'requested' : view === 'live' ? ['requested', 'approved', 'suspended'].includes(p.status) : ['closed', 'cancelled', 'rejected'].includes(p.status));
  const permitPdf = (p: any) => tablePdf({ company: company!, title: `Permit to work ${p.number}`, subtitle: label(PERMIT_KINDS, p.kind), head: ['', ''], filename: `permit-${p.number}`,
    body: [['Type of work', label(PERMIT_KINDS, p.kind)], ['Location', p.location], ['Project', b.proj(p.project_id) || '—'], ['Work to be done', p.work_description], ['Valid', `${dt(p.valid_from)} to ${dt(p.valid_to)}`],
      ['Hazards', p.hazards || '—'], ['Precautions and controls', p.precautions || '—'], ['Isolations (lock-out / tag-out)', p.isolations || '—'], ['Gas test', p.gas_test || '—'], ['PPE', p.ppe || '—'], ['Workers on this permit', p.workers || '—'],
      ['Requested by', `${p.requested_email || ''} on ${dt(p.created_at)}`], ['Issued by', p.issued_email ? `${p.issued_email} on ${dt(p.issued_at)}` : 'NOT YET ISSUED — WORK MUST NOT START'],
      ['Status', PERMIT_STATUS[p.status][0] + (p.decision_note ? ' · ' + p.decision_note : '')], ['Closed', p.closed_at ? `${dt(p.closed_at)} · ${p.close_note || ''}` : 'Work finished, area safe, isolations removed: sign ______________ time ______']],
    notes: 'Keep this permit at the work place. Work stops if conditions change, and the permit is suspended. Close the permit when the work is finished and the area is left safe.' });
  return <>
    <PageHead title="Permits to work" sub="High-risk work starts only on an issued permit. The issuer (HSE officer or the project manager) cannot be the person who asked for it.">
      <button className="btn primary" type="button" onClick={() => setForm({ kind: 'hot_work', project_id: '', location: '', work_description: '', hazards: '', precautions: '', isolations: '', gas_test: '', ppe: '', workers: '', valid_from: nowLocal(), valid_to: nowLocal(10) })}>Request a permit</button>
    </PageHead>
    <div className="filters"><div className="actions" style={{ alignSelf: 'end' }}>{([['live', 'Current'], ['waiting', 'Waiting for approval'], ['done', 'Closed'], ['all', 'All']] as const).map(([k, l]) =>
      <button key={k} type="button" className={'btn small' + (view === k ? ' primary' : '')} onClick={() => setView(k)}>{l}</button>)}</div></div>
    <Loading error={error} loading={loading && !data} />
    {data && <Panel>{rows.length ? <div className="scroll"><table>
      <thead><tr><th>Permit</th><th>Work</th><th>Valid</th><th>Status</th><th></th></tr></thead>
      <tbody>{rows.map(p => { const mgr = b.hse || b.pm(p.project_id); const mine = p.requested_by === b.me;
        return <tr key={p.id}>
          <td><b>{label(PERMIT_KINDS, p.kind).replace(/ \(.*\)$/, '')}</b><br /><span className="muted num" style={{ fontSize: 12 }}>{p.number} · {(p.requested_email || '').split('@')[0]}</span></td>
          <td className="wrap-cell">{p.work_description}<br /><span className="muted" style={{ fontSize: 12 }}>{[b.proj(p.project_id), p.location].filter(Boolean).join(' · ')}</span></td>
          <td className="num" style={{ fontSize: 13 }}>{dt(p.valid_from)}<br />to {dt(p.valid_to)}</td>
          <td><Pill map={PERMIT_STATUS} s={p.status} />{live(p) && <><br /><span className="pill good">Active now</span></>}{overrun(p) && <><br /><span className="pill bad">Time ran out</span></>}</td>
          <td className="r" style={{ whiteSpace: 'nowrap' }}>
            <button className="btn small" type="button" onClick={() => permitPdf(p)}>Print</button>
            {p.status === 'requested' && mgr && !mine && <button className="btn small primary" type="button" onClick={() => setStep({ p, a: 'approve', title: 'Issue permit', note: '' })}>Issue</button>}
            {p.status === 'requested' && mgr && !mine && <button className="btn small" type="button" onClick={() => setStep({ p, a: 'reject', title: 'Reject', note: '' })}>Reject</button>}
            {p.status === 'approved' && mgr && <button className="btn small" type="button" onClick={() => setStep({ p, a: 'suspend', title: 'Suspend (stop work)', note: '' })}>Suspend</button>}
            {p.status === 'suspended' && mgr && <button className="btn small" type="button" onClick={() => setStep({ p, a: 'resume', title: 'Resume', note: '' })}>Resume</button>}
            {['approved', 'suspended'].includes(p.status) && (mine || mgr) && <button className="btn small primary" type="button" onClick={() => setStep({ p, a: 'close', title: 'Close permit', note: '' })}>Close</button>}
            {['requested', 'approved', 'suspended'].includes(p.status) && (mine || mgr) && <button className="btn small ghost" type="button" onClick={() => setStep({ p, a: 'cancel', title: 'Cancel permit', note: '' })}>Cancel</button>}
          </td></tr>; })}</tbody>
    </table></div> : <Empty>No permits here. Request one for hot work, electrical isolation, work at height, confined spaces, excavation or lifting.</Empty>}</Panel>}
    {form && <FormModal title="Request a permit to work" submit="Send request" busy={act.busy} onClose={() => setForm(null)} onSave={() => act.run(async () => {
      await q(supabase.from('hse_permits').insert({ company_id: cid, kind: form.kind, project_id: form.project_id || null, location: form.location, work_description: form.work_description,
        hazards: form.hazards || null, precautions: form.precautions || null, isolations: form.isolations || null, gas_test: form.gas_test || null, ppe: form.ppe || null, workers: form.workers || null,
        valid_from: new Date(form.valid_from).toISOString(), valid_to: new Date(form.valid_to).toISOString() }) as any);
      setForm(null); reload(); }, 'Permit requested. The HSE officer and project manager have been told.')}>
      <div className="grid-form">
        <Select label="Type of work" id="pw-kind" value={form.kind} onChange={v => setForm({ ...form, kind: v })} options={PERMIT_KINDS} />
        <Select label="Project" id="pw-proj" value={form.project_id} onChange={v => setForm({ ...form, project_id: v })} options={b.projOpts} />
        <Field label="Exact location" id="pw-loc" value={form.location} onChange={v => setForm({ ...form, location: v })} required />
        <Field label="From" id="pw-from" type="datetime-local" value={form.valid_from} onChange={v => setForm({ ...form, valid_from: v })} required />
        <Field label="To (at most 7 days)" id="pw-to" type="datetime-local" value={form.valid_to} onChange={v => setForm({ ...form, valid_to: v })} required />
      </div>
      <Field label="Work to be done" id="pw-work" type="textarea" value={form.work_description} onChange={v => setForm({ ...form, work_description: v })} required />
      <Field label="Hazards" id="pw-haz" type="textarea" value={form.hazards} onChange={v => setForm({ ...form, hazards: v })} />
      <Field label="Precautions and controls" id="pw-prec" type="textarea" value={form.precautions} onChange={v => setForm({ ...form, precautions: v })} />
      {['electrical', 'confined_space', 'excavation'].includes(form.kind) && <Field label="Isolations (what is isolated, lock and tag numbers)" id="pw-iso" type="textarea" value={form.isolations} onChange={v => setForm({ ...form, isolations: v })} />}
      {['confined_space', 'hot_work'].includes(form.kind) && <Field label="Gas test (O₂, LEL, H₂S, CO readings and time)" id="pw-gas" value={form.gas_test} onChange={v => setForm({ ...form, gas_test: v })} />}
      <div className="grid-form">
        <Field label="PPE required" id="pw-ppe" value={form.ppe} onChange={v => setForm({ ...form, ppe: v })} />
        <Field label="Workers on this permit" id="pw-workers" value={form.workers} onChange={v => setForm({ ...form, workers: v })} />
      </div>
    </FormModal>}
    {step && <FormModal title={`${step.title}: ${step.p.number}`} submit={step.title} busy={act.busy} onClose={() => setStep(null)} onSave={() => act.run(async () => {
      await rpc('hse_permit_step', { p_id: step.p.id, p_action: step.a, p_note: step.note || null }); setStep(null); reload(); }, 'Done')}>
      {step.a === 'approve' && <p style={{ margin: 0 }}>Issue only after checking the controls on site: isolations locked and proven dead, gas test done, fire watch, barriers and PPE in place.</p>}
      <Field label={step.a === 'close' ? 'Work finished and area left safe (required)' : step.a === 'approve' || step.a === 'resume' ? 'Conditions or note' : 'Reason (required)'} id="ps-note" type="textarea" value={step.note} onChange={v => setStep({ ...step, note: v })} />
    </FormModal>}
  </>;
}

// ---------------------------------------------------------------- Risk register (from project risk assessments)
export function HseRisksPage() {
  const { cid, company } = useSession();
  const b = useHseBasics();
  const [band, setBand] = useState('');
  const { data, error, loading } = useLoad(() => q<any[]>(supabase.from('risk_items').select('*, ra:risk_assessments(id,number,title,status,project_id,review_date)').eq('company_id', cid).limit(3000) as any), [cid]);
  const score = (l: number, s: number) => (l || 0) * (s || 0);
  const bandOf = (n: number) => n >= 15 ? 'high' : n >= 5 ? 'medium' : 'low';
  const rows = (data || []).map(r => ({ ...r, inh: score(r.likelihood, r.severity), res: r.residual_likelihood ? score(r.residual_likelihood, r.residual_severity) : null }))
    .filter(r => !band || bandOf(r.res ?? r.inh) === band).sort((a, b) => (b.res ?? b.inh) - (a.res ?? a.inh));
  const head = ['Hazard', 'Consequence', 'Who', 'Initial (L×S)', 'Controls', 'Residual (L×S)', 'Owner', 'Assessment', 'Project'];
  const body = rows.map(r => [r.hazard, r.consequence || '', r.who_at_risk || '', `${r.likelihood}×${r.severity}=${r.inh}`, r.controls || '', r.res != null ? `${r.residual_likelihood}×${r.residual_severity}=${r.res}` : '', r.owner || '', r.ra?.number || '', b.proj(r.ra?.project_id)]);
  const Score = ({ n }: { n: number | null }) => n == null ? <span className="muted">—</span> : <span className={'pill ' + (bandOf(n) === 'high' ? 'bad' : bandOf(n) === 'medium' ? 'warn' : 'good')}>{n}</span>;
  return <>
    <PageHead title="Hazard and risk register" sub="Every hazard from every project risk assessment, highest remaining risk first. Score = likelihood × severity (1–25): 15+ high, 5–14 medium, under 5 low.">
      <button className="btn" type="button" onClick={() => tablePdf({ company: company!, title: 'Hazard and risk register', subtitle: longDate(today()), head, body, landscape: true, filename: 'risk-register' })}>PDF</button>
      <button className="btn" type="button" onClick={() => downloadCsv('risk-register', head, body)}>CSV</button>
    </PageHead>
    <div className="filters"><div className="actions" style={{ alignSelf: 'end' }}>{([['', 'All'], ['high', 'High'], ['medium', 'Medium'], ['low', 'Low']] as const).map(([k, l]) =>
      <button key={k} type="button" className={'btn small' + (band === k ? ' primary' : '')} onClick={() => setBand(k)}>{l}</button>)}</div></div>
    <Loading error={error} loading={loading && !data} />
    {data && <Panel>{rows.length ? <div className="scroll"><table>
      <thead><tr><th>Hazard</th><th>Initial</th><th>Controls</th><th>Remaining</th><th>Assessment</th></tr></thead>
      <tbody>{rows.map(r => <tr key={r.id}><td><b>{r.hazard}</b>{r.consequence && <><br /><span className="muted" style={{ fontSize: 12 }}>{r.consequence}{r.who_at_risk ? ' · ' + r.who_at_risk : ''}</span></>}</td>
        <td><Score n={r.inh} /></td><td className="wrap-cell" style={{ fontSize: 13 }}>{r.controls}</td><td><Score n={r.res} /></td>
        <td>{r.ra && <Link to={`/projects/${r.ra.project_id}`}>{r.ra.number}</Link>}<br /><span className="muted" style={{ fontSize: 12 }}>{b.proj(r.ra?.project_id)}{r.ra?.status === 'approved' ? '' : ' · draft'}</span></td></tr>)}</tbody>
    </table></div> : <Empty>No hazards yet. Risk assessments are written on each project (Project → Documents → Risk assessments) and appear here. For the office, workshop or yard, use an internal project such as "Head office".</Empty>}</Panel>}
  </>;
}

// ---------------------------------------------------------------- Compliance register (ISO 37301)
const COMMON_OBLIGATIONS: [string, string, string, string][] = [
  ['EPA environmental permit', 'permit_licence', 'environment', 'Environmental Protection Agency'],
  ['Fire safety certificate', 'permit_licence', 'safety', 'Ghana National Fire Service'],
  ['Factories Inspectorate registration of workplace', 'permit_licence', 'safety', 'Department of Factories Inspectorate'],
  ['Electrical contractor / wiring licence', 'permit_licence', 'safety', 'Energy Commission'],
  ['Workmen\'s compensation insurance', 'insurance', 'labour', 'Insurer'],
  ['Contractor\'s all-risk and third-party insurance', 'insurance', 'legal', 'Insurer'],
  ['Tax clearance certificate', 'regulatory_filing', 'tax_finance', 'Ghana Revenue Authority'],
  ['SSNIT clearance certificate', 'regulatory_filing', 'labour', 'SSNIT'],
  ['Annual return', 'regulatory_filing', 'legal', 'Office of the Registrar of Companies'],
  ['Data controller registration', 'permit_licence', 'data_protection', 'Data Protection Commission'],
  ['ISO 45001 certification (surveillance audit)', 'certification', 'safety', 'Certification body'],
  ['ISO 14001 certification (surveillance audit)', 'certification', 'environment', 'Certification body'],
  ['ISO 9001 certification (surveillance audit)', 'certification', 'quality', 'Certification body'],
];

export function HseObligationsPage() {
  const { cid, company, can } = useSession();
  const b = useHseBasics();
  const act = useAction();
  const [view, setView] = useState('attention');
  const [form, setForm] = useState<any | null>(null);
  const [renew, setRenew] = useState<any | null>(null);
  const [quick, setQuick] = useState<string[] | null>(null);
  const [files, setFiles] = useState<any | null>(null);
  const { data, error, loading, reload } = useLoad(() => q<any[]>(supabase.from('compliance_obligations').select('*').eq('company_id', cid).order('expires_on', { nullsFirst: false }) as any), [cid]);
  const manager = b.hse || can('accountant', 'hr');
  const rows = (data || []).filter(o => view === 'all' ? true : view === 'attention' ? ['bad', 'warn'].includes(oblState(o)[1]) : view === 'retired' ? o.status === 'retired' : o.status !== 'retired' && o.area === view);
  const head = ['Obligation', 'Type', 'Area', 'Authority', 'Reference', 'Owner', 'Issued', 'Expires', 'Repeats', 'State'];
  const body = rows.map(o => [o.title, label(OBL_CATS, o.category), label(AREAS, o.area), o.authority || '', o.reference || '', b.who(o.owner_id), o.issued_on || '', o.expires_on || '', label(RECUR, o.recurrence), oblState(o)[0]]);
  const blank = { title: '', category: 'permit_licence', area: 'safety', authority: '', reference: '', project_id: '', owner_id: '', issued_on: '', expires_on: '', recurrence: 'none', lead_days: '30', status: 'active', requirement: '', notes: '' };
  return <>
    <PageHead title="Compliance register" sub={data ? `${data.filter(o => oblState(o)[0] === 'Expired').length} expired · ${data.filter(o => oblState(o)[1] === 'warn').length} due soon · ${data.filter(o => o.status !== 'retired').length} tracked` : undefined}>
      <button className="btn" type="button" onClick={() => tablePdf({ company: company!, title: 'Compliance obligations register', subtitle: longDate(today()), head, body, landscape: true, filename: 'compliance-register' })}>PDF</button>
      <button className="btn" type="button" onClick={() => downloadCsv('compliance-register', head, body)}>CSV</button>
      {manager && <button className="btn" type="button" onClick={() => setQuick([])}>Add common Ghana items</button>}
      {manager && <button className="btn primary" type="button" onClick={() => setForm(blank)}>Add obligation</button>}
    </PageHead>
    <div className="filters"><div className="actions" style={{ alignSelf: 'end', flexWrap: 'wrap' }}>{([['attention', 'Needs attention'], ['all', 'All'], ...AREAS.slice(0, 6), ['retired', 'Retired']] as [string, string][]).map(([k, l]) =>
      <button key={k} type="button" className={'btn small' + (view === k ? ' primary' : '')} onClick={() => setView(k)}>{l}</button>)}</div></div>
    <Loading error={error} loading={loading && !data} />
    {data && <Panel>{rows.length ? <div className="scroll"><table>
      <thead><tr><th>Obligation</th><th>Authority</th><th>Owner</th><th>Expires</th><th>State</th><th></th></tr></thead>
      <tbody>{rows.map(o => { const [st, tone] = oblState(o); const mine = o.owner_id === b.me;
        return <tr key={o.id}><td><b>{o.title}</b><br /><span className="muted" style={{ fontSize: 12 }}>{label(OBL_CATS, o.category)} · {label(AREAS, o.area)}{o.reference ? ' · ' + o.reference : ''}{b.proj(o.project_id) ? ' · ' + b.proj(o.project_id) : ''}</span></td>
          <td>{o.authority}</td><td>{b.who(o.owner_id) || <span className="muted">Nobody</span>}</td>
          <td className="num">{o.expires_on ? longDate(o.expires_on) : '—'}{o.recurrence !== 'none' && <><br /><span className="muted" style={{ fontSize: 12 }}>{label(RECUR, o.recurrence).toLowerCase()}</span></>}</td>
          <td><span className={'pill ' + tone}>{st}</span></td>
          <td className="r" style={{ whiteSpace: 'nowrap' }}>
            <button className="btn small" type="button" onClick={() => setFiles(o)}>Evidence</button>
            {(manager || mine) && o.status !== 'retired' && <button className="btn small primary" type="button" onClick={() => {
              const nxt = o.recurrence !== 'none' && o.expires_on ? new Date(new Date(o.expires_on).setMonth(new Date(o.expires_on).getMonth() + ({ monthly: 1, quarterly: 3, semiannual: 6, annual: 12 } as any)[o.recurrence])).toISOString().slice(0, 10) : '';
              setRenew({ o, issued: today(), expires: nxt, note: '' }); }}>{o.category === 'regulatory_filing' ? 'Filed' : 'Renewed'}</button>}
            {(manager || mine) && <button className="btn small" type="button" onClick={() => setForm({ ...o, project_id: o.project_id || '', owner_id: o.owner_id || '', issued_on: o.issued_on || '', expires_on: o.expires_on || '', lead_days: String(o.lead_days), requirement: o.requirement || '', notes: o.notes || '', authority: o.authority || '', reference: o.reference || '' })}>Edit</button>}
          </td></tr>; })}</tbody>
    </table></div> : <Empty>{view === 'attention' ? 'Nothing expired or due soon.' : 'Nothing here.'} List every permit, licence, certificate, insurance and regular filing the company must keep, with its owner and expiry. Reminders go out before each one is due.</Empty>}</Panel>}
    {form && <FormModal title={form.id ? 'Edit obligation' : 'Add a compliance obligation'} busy={act.busy} onClose={() => setForm(null)} onSave={() => act.run(async () => {
      const row = { title: form.title, category: form.category, area: form.area, authority: form.authority || null, reference: form.reference || null, project_id: form.project_id || null, owner_id: form.owner_id || null,
        issued_on: form.issued_on || null, expires_on: form.expires_on || null, recurrence: form.recurrence, lead_days: Number(form.lead_days) || 30, status: form.status, requirement: form.requirement || null, notes: form.notes || null };
      if (form.id) await q(supabase.from('compliance_obligations').update(row).eq('id', form.id) as any); else await q(supabase.from('compliance_obligations').insert({ ...row, company_id: cid }) as any);
      setForm(null); reload(); }, 'Saved')}>
      <Field label="Obligation" id="ob-title" value={form.title} onChange={v => setForm({ ...form, title: v })} placeholder="e.g. EPA environmental permit for the Tema yard" required />
      <div className="grid-form">
        <Select label="Type" id="ob-cat" value={form.category} onChange={v => setForm({ ...form, category: v })} options={OBL_CATS} />
        <Select label="Area" id="ob-area" value={form.area} onChange={v => setForm({ ...form, area: v })} options={AREAS} />
        <Field label="Authority or issuer" id="ob-auth" value={form.authority} onChange={v => setForm({ ...form, authority: v })} />
        <Field label="Reference / certificate no." id="ob-ref" value={form.reference} onChange={v => setForm({ ...form, reference: v })} />
        <Select label="Owner (responsible)" id="ob-owner" value={form.owner_id} onChange={v => setForm({ ...form, owner_id: v })} options={b.teamOpts} />
        <Select label="Project (if only for one)" id="ob-proj" value={form.project_id} onChange={v => setForm({ ...form, project_id: v })} options={[['', 'Whole company'], ...b.projOpts.slice(1)]} />
        <Field label="Issued or last filed" id="ob-iss" type="date" value={form.issued_on} onChange={v => setForm({ ...form, issued_on: v })} />
        <Field label="Expires or next due" id="ob-exp" type="date" value={form.expires_on} onChange={v => setForm({ ...form, expires_on: v })} />
        <Select label="Repeats" id="ob-rec" value={form.recurrence} onChange={v => setForm({ ...form, recurrence: v })} options={RECUR} />
        <Field label="Remind this many days before" id="ob-lead" type="number" min="0" max="365" value={form.lead_days} onChange={v => setForm({ ...form, lead_days: v })} />
        <Select label="Status" id="ob-st" value={form.status} onChange={v => setForm({ ...form, status: v })} options={[['active', 'Active'], ['not_compliant', 'Not compliant (needs action)'], ['retired', 'Retired (no longer applies)']]} />
      </div>
      <Field label="What is required (conditions, what to submit)" id="ob-req" type="textarea" value={form.requirement} onChange={v => setForm({ ...form, requirement: v })} />
      <Field label="Notes" id="ob-notes" type="textarea" value={form.notes} onChange={v => setForm({ ...form, notes: v })} />
    </FormModal>}
    {renew && <FormModal title={`${renew.o.category === 'regulatory_filing' ? 'Record filing' : 'Record renewal'}: ${renew.o.title}`} busy={act.busy} onClose={() => setRenew(null)} onSave={() => act.run(async () => {
      await rpc('renew_obligation', { p_id: renew.o.id, p_issued: renew.issued || null, p_expires: renew.expires || null, p_note: renew.note || null }); setRenew(null); reload(); }, 'Recorded. Upload the certificate or receipt under Evidence.')}>
      <div className="grid-form">
        <Field label={renew.o.category === 'regulatory_filing' ? 'Filed on' : 'New certificate issued'} id="rn-iss" type="date" value={renew.issued} onChange={v => setRenew({ ...renew, issued: v })} />
        <Field label={renew.o.category === 'regulatory_filing' ? 'Next due' : 'New expiry'} id="rn-exp" type="date" value={renew.expires} onChange={v => setRenew({ ...renew, expires: v })} />
      </div>
      <Field label="Note (certificate number, receipt)" id="rn-note" value={renew.note} onChange={v => setRenew({ ...renew, note: v })} />
    </FormModal>}
    {quick && <FormModal title="Add common obligations for a Ghanaian contractor" submit={`Add ${quick.length}`} busy={act.busy} onClose={() => setQuick(null)} onSave={() => act.run(async () => {
      const have = new Set((data || []).map(o => o.title.toLowerCase()));
      const add = COMMON_OBLIGATIONS.filter(c => quick.includes(c[0]) && !have.has(c[0].toLowerCase()));
      if (add.length) await q(supabase.from('compliance_obligations').insert(add.map(([title, category, area, authority]) => ({ company_id: cid, title, category, area, authority, recurrence: category === 'certification' || category === 'insurance' || title.startsWith('Annual') ? 'annual' : 'none' }))) as any);
      setQuick(null); reload(); }, 'Added. Open each one to set the owner, reference and expiry.')}>
      <p className="muted" style={{ margin: 0, fontSize: 13 }}>A starting list. Tick those that apply, then set the owner, reference and expiry on each. Check the exact requirements with each authority.</p>
      {COMMON_OBLIGATIONS.map(([t, , , a]) => <label key={t} className="check"><input type="checkbox" checked={quick.includes(t)} onChange={e => setQuick(e.target.checked ? [...quick, t] : quick.filter(x => x !== t))} /> {t} <span className="muted">· {a}</span></label>)}
    </FormModal>}
    {files && <FormModal title={`Evidence: ${files.title}`} submit="Done" onClose={() => setFiles(null)} onSave={() => setFiles(null)}>
      <Files type="obligation" id={files.id} canAdd={manager || files.owner_id === b.me} />
      {files.notes && <div className="muted" style={{ whiteSpace: 'pre-wrap', fontSize: 13 }}>{files.notes}</div>}
    </FormModal>}
  </>;
}

// ---------------------------------------------------------------- Policies
export function HsePoliciesPage() {
  const { cid, can, session } = useSession();
  const b = useHseBasics();
  const act = useAction();
  const [form, setForm] = useState<any | null>(null);
  const [who, setWho] = useState<any | null>(null);
  const { data, error, loading, reload } = useLoad(async () => {
    const [policies, acks] = await Promise.all([
      q<any[]>(supabase.from('hse_policies').select('*').eq('company_id', cid).order('title') as any),
      q<any[]>(supabase.from('hse_policy_acks').select('policy_id,user_id,version,acknowledged_at,email').eq('company_id', cid) as any),
    ]);
    return { policies, acks };
  }, [cid]);
  const manager = b.hse || can('hr');
  const me = session!.user.id;
  const open = (p: any) => act.run(async () => { const { data: u, error: e } = await supabase.storage.from('project-docs').createSignedUrl(p.storage_path, 600); if (e) throw e; window.open(u.signedUrl, '_blank', 'noopener'); });
  const acked = (p: any, u: string) => data?.acks.find(a => a.policy_id === p.id && a.user_id === u && a.version === p.version);
  return <>
    <PageHead title="Policies" sub="Policies everyone must read: health and safety, environment, quality, code of conduct, anti-bribery, data protection. Each person confirms they have read each version.">
      {manager && <button className="btn primary" type="button" onClick={() => setForm({ title: '', area: 'safety', version: '1', effective_on: today(), review_on: '', summary: '', requires_ack: true, active: true, file: null })}>Publish policy</button>}
    </PageHead>
    <Loading error={error} loading={loading && !data} />
    {data && <Panel>{data.policies.length ? <div className="scroll"><table>
      <thead><tr><th>Policy</th><th>Version</th><th>Review</th><th>Read by</th><th></th></tr></thead>
      <tbody>{data.policies.filter(p => p.active || manager).map(p => { const n = new Set(data.acks.filter(a => a.policy_id === p.id && a.version === p.version).map(a => a.user_id)).size; const mineOk = acked(p, me);
        return <tr key={p.id}><td><b>{p.title}</b>{!p.active && <span className="pill" style={{ marginLeft: 6 }}>Withdrawn</span>}<br /><span className="muted" style={{ fontSize: 12 }}>{label(AREAS, p.area)} · from {longDate(p.effective_on)}</span>{p.summary && <div style={{ fontSize: 13 }}>{p.summary}</div>}</td>
          <td className="num">{p.version}</td><td className="num" style={{ color: p.review_on && p.review_on < today() ? 'var(--bad)' : undefined }}>{p.review_on ? longDate(p.review_on) : '—'}</td>
          <td>{p.requires_ack ? <button type="button" className="btn small ghost" onClick={() => setWho(p)} disabled={!manager}>{n} of {b.team.length}</button> : <span className="muted">Not required</span>}</td>
          <td className="r" style={{ whiteSpace: 'nowrap' }}>
            {p.storage_path && <button className="btn small" type="button" onClick={() => open(p)}>Read</button>}
            {p.requires_ack && p.active && (mineOk ? <span className="pill good">You confirmed {longDate(mineOk.acknowledged_at)}</span>
              : <button className="btn small primary" type="button" onClick={() => act.run(async () => { await rpc('acknowledge_policy', { p_id: p.id }); reload(); }, 'Thank you. Recorded.')}>I have read and understood it</button>)}
            {manager && <button className="btn small" type="button" onClick={() => setForm({ ...p, review_on: p.review_on || '', summary: p.summary || '', file: null })}>Edit</button>}
          </td></tr>; })}</tbody>
    </table></div> : <Empty>No policies published yet. Start with your Health, Safety and Environment policy signed by the managing director (ISO 45001 and 14001 clause 5.2).</Empty>}</Panel>}
    {form && <FormModal title={form.id ? 'Edit policy' : 'Publish a policy'} busy={act.busy} onClose={() => setForm(null)} onSave={() => act.run(async () => {
      let file = {};
      if (form.file) { const f = await uploadDocFile(cid, 'policies', form.file); file = { storage_path: f.path, file_name: f.name }; }
      const row = { title: form.title, area: form.area, version: form.version, effective_on: form.effective_on, review_on: form.review_on || null, summary: form.summary || null, requires_ack: form.requires_ack, active: form.active, ...file };
      if (form.id) await q(supabase.from('hse_policies').update(row).eq('id', form.id) as any); else await q(supabase.from('hse_policies').insert({ ...row, company_id: cid }) as any);
      setForm(null); reload(); }, 'Policy saved')}>
      <Field label="Title" id="po-title" value={form.title} onChange={v => setForm({ ...form, title: v })} required />
      <div className="grid-form">
        <Select label="Area" id="po-area" value={form.area} onChange={v => setForm({ ...form, area: v })} options={AREAS} />
        <Field label="Version" id="po-ver" value={form.version} onChange={v => setForm({ ...form, version: v })} required />
        <Field label="Effective from" id="po-eff" type="date" value={form.effective_on} onChange={v => setForm({ ...form, effective_on: v })} />
        <Field label="Review by" id="po-rev" type="date" value={form.review_on} onChange={v => setForm({ ...form, review_on: v })} />
      </div>
      <Field label="Short summary" id="po-sum" type="textarea" value={form.summary} onChange={v => setForm({ ...form, summary: v })} />
      <div className="field"><label htmlFor="po-file">Policy document (PDF){form.file_name ? ` · current: ${form.file_name}` : ''}</label><input id="po-file" type="file" accept=".pdf,.doc,.docx" onChange={e => setForm({ ...form, file: e.target.files?.[0] || null })} /></div>
      <label className="check"><input type="checkbox" checked={form.requires_ack} onChange={e => setForm({ ...form, requires_ack: e.target.checked })} /> Everyone must confirm they have read it</label>
      <label className="check"><input type="checkbox" checked={form.active} onChange={e => setForm({ ...form, active: e.target.checked })} /> In force</label>
      {form.id && <p className="muted" style={{ margin: 0, fontSize: 13 }}>Change the version number when the content changes: everyone is then asked to read and confirm it again.</p>}
    </FormModal>}
    {who && data && <FormModal title={`Who has read: ${who.title} v${who.version}`} submit="Close" onClose={() => setWho(null)} onSave={() => setWho(null)}>
      <table><tbody>{b.team.map(m => { const a = acked(who, m.user_id); return <tr key={m.user_id}><td>{m.email}</td><td>{a ? <span className="pill good">{longDate(a.acknowledged_at)}</span> : <span className="pill warn">Not yet</span>}</td></tr>; })}</tbody></table>
    </FormModal>}
  </>;
}

// ---------------------------------------------------------------- Sustainability (ISO 14001, GHG Protocol, GRI)
export function HseSustainabilityPage() {
  const { cid, company, can } = useSession();
  const b = useHseBasics();
  const act = useAction();
  const [period, setPeriod] = useState('ytd');
  const [tab, setTab] = useState<'records' | 'hours' | 'factors'>('records');
  const [entry, setEntry] = useState<any | null>(null);
  const [hours, setHours] = useState<any | null>(null);
  const [factor, setFactor] = useState<any | null>(null);
  const [from, to] = periodRange(period);
  const { data, error, loading, reload } = useLoad(async () => {
    const [summary, entries, factors, hrs, stats] = await Promise.all([
      rpc<any[]>('esg_summary', { cid, p_from: from, p_to: to }),
      q<any[]>(supabase.from('esg_entries').select('*, factor:esg_factors(name,unit,category,scope)').eq('company_id', cid).gte('period', from.slice(0, 8) + '01').lte('period', to).order('period', { ascending: false }).limit(2000) as any),
      q<any[]>(supabase.from('esg_factors').select('*').eq('company_id', cid).order('category').order('name') as any),
      q<any[]>(supabase.from('hse_hours').select('*').eq('company_id', cid).gte('period', from.slice(0, 8) + '01').lte('period', to).order('period', { ascending: false }) as any),
      rpc<any[]>('hse_stats', { cid, p_from: from, p_to: to }),
    ]);
    return { summary, entries, factors, hrs, s: stats[0] };
  }, [cid, from, to]);
  const canRecord = b.hse || can('accountant', 'store', 'project_manager');
  const canFactors = b.hse || can('accountant');
  const canHours = b.hse || can('hr', 'project_manager');
  const sum = data?.summary || [];
  const scopeT = (sc: number) => sum.filter(r => r.scope === sc).reduce((a, r) => a + Number(r.t_co2e || 0), 0);
  const total = scopeT(1) + scopeT(2) + scopeT(3);
  const kwh = sum.filter(r => r.category === 'electricity').reduce((a, r) => a + Number(r.quantity), 0);
  const water = sum.filter(r => r.category === 'water').reduce((a, r) => a + Number(r.quantity), 0);
  const waste = sum.filter(r => r.category === 'waste');
  const wasteTotal = waste.reduce((a, r) => a + Number(r.quantity), 0);
  const diverted = waste.filter(r => ['recycled', 'reused', 'composted'].includes(r.waste_route)).reduce((a, r) => a + Number(r.quantity), 0);
  const hoursK = Number(data?.s?.hours || 0) / 1000;
  const pdf = () => tablePdf({ company: company!, title: 'Sustainability report', subtitle: `${longDate(from)} to ${longDate(to)}`, landscape: true, filename: `sustainability-${from}-${to}`,
    head: ['Disclosure', 'Item', 'Quantity', 'Unit', 't CO2e', 'Factor source'], rightAlign: [2, 4],
    body: [...sum.map(r => [r.category === 'waste' ? 'GRI 306 Waste' : r.category === 'water' ? 'GRI 303 Water' : r.scope ? `GRI 305 Scope ${r.scope}` : 'GRI 302 Energy', r.name, n1(r.quantity), r.unit, r.scope ? n1(r.t_co2e) : '', data!.factors.find(f => f.key === r.factor_key)?.source || '']),
      ['GRI 305-1', 'Total Scope 1 (direct: fuel burnt)', '', '', n1(scopeT(1)), ''], ['GRI 305-2', 'Total Scope 2 (purchased electricity, location-based)', '', '', n1(scopeT(2)), ''],
      ['GRI 305', 'Total Scope 1 + 2 + 3', '', '', n1(total), ''], ['GRI 305-4', 'Intensity: t CO2e per 1,000 hours worked', hoursK ? n1(total / hoursK) : '—', '', '', ''],
      ['GRI 306-4', 'Waste diverted from disposal', wasteTotal ? Math.round(100 * diverted / wasteTotal) + '%' : '—', '', '', ''],
      ['GRI 403-9', 'Lost-time injury frequency rate (per 1,000,000 h)', n1(data!.s?.ltifr), '', '', ''], ['GRI 403-9', 'Recordable injury rate (per 200,000 h)', n1(data!.s?.trir), '', '', ''],
      ['GRI 403-9', 'Hours worked', n1(data!.s?.hours), 'h', '', '']],
    notes: 'Emissions follow the GHG Protocol Corporate Standard (operational control). Scope 2 is location-based. Each record keeps the factor used when it was entered.' });
  return <>
    <PageHead title="Sustainability" sub="Energy, fuel, water and waste, converted to greenhouse-gas emissions by scope (GHG Protocol), for ISO 14001 and GRI reporting.">
      <select aria-label="Period" value={period} onChange={e => setPeriod(e.target.value)} style={{ width: 'auto' }}>{PERIODS.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select>
      <button className="btn" type="button" onClick={pdf} disabled={!data}>Report PDF</button>
      <button className="btn" type="button" disabled={!data} onClick={() => downloadCsv(`sustainability-${from}-${to}`, ['Month', 'Item', 'Quantity', 'Unit', 'Scope', 'kg CO2e', 'Factor used', 'Project', 'Reference', 'Note'],
        data!.entries.map(e => [e.period.slice(0, 7), e.factor?.name, e.quantity, e.factor?.unit, e.factor?.scope ?? '', e.kg_co2e, e.factor_used, b.proj(e.project_id), e.source_ref || '', e.note || '']))}>CSV</button>
      {canRecord && <button className="btn primary" type="button" onClick={() => setEntry({ period: today().slice(0, 7), factor_id: data?.factors.find(f => f.active)?.id || '', quantity: '', project_id: '', source_ref: '', note: '' })}>Record usage</button>}
    </PageHead>
    <Loading error={error} loading={loading && !data} />
    {data && <>
      <div className="tiles">
        <div className="tile"><span>Total emissions</span><b>{n1(total)} t</b><span>CO2e, scope 1 + 2 + 3</span></div>
        <div className="tile"><span>Scope 1 · fuel burnt</span><b>{n1(scopeT(1))} t</b><span>generators, plant, vehicles</span></div>
        <div className="tile"><span>Scope 2 · electricity bought</span><b>{n1(scopeT(2))} t</b><span>{n1(kwh)} kWh in total</span></div>
        <div className="tile"><span>Intensity</span><b>{hoursK ? n1(total / hoursK) : '—'}</b><span>t CO2e per 1,000 hours worked</span></div>
        <div className="tile"><span>Water</span><b>{n1(water)} m³</b><span>used</span></div>
        <div className="tile"><span>Waste diverted</span><b>{wasteTotal ? Math.round(100 * diverted / wasteTotal) + '%' : '—'}</b><span>{n1(wasteTotal)} kg in total</span></div>
      </div>
      <Panel title="By source">{sum.length ? <table>
        <thead><tr><th>Source</th><th>Scope</th><th className="r">Quantity</th><th className="r">t CO2e</th></tr></thead>
        <tbody>{sum.map(r => <tr key={r.factor_key}><td>{r.name}</td><td>{r.scope ? `Scope ${r.scope}` : <span className="muted">{r.category}</span>}</td><td className="r num">{n1(r.quantity)} {r.unit}</td><td className="r num">{r.scope ? n1(r.t_co2e) : ''}</td></tr>)}</tbody>
      </table> : <Empty>Nothing recorded for this period. Record fuel from fuel bills and logs, electricity from ECG bills or meters, water and waste each month.</Empty>}</Panel>
      <div className="actions" style={{ margin: '4px 0 8px' }}>{([['records', 'Records'], ['hours', 'Hours worked'], ['factors', 'Emission factors']] as const).map(([k, l]) =>
        <button key={k} type="button" className={'btn small' + (tab === k ? ' primary' : '')} onClick={() => setTab(k)}>{l}</button>)}</div>
      {tab === 'records' && <Panel>{data.entries.length ? <div className="scroll"><table>
        <thead><tr><th>Month</th><th>Item</th><th className="r">Quantity</th><th className="r">kg CO2e</th><th>Project / reference</th><th></th></tr></thead>
        <tbody>{data.entries.map(e => <tr key={e.id}><td className="num">{e.period.slice(0, 7)}</td><td>{e.factor?.name}</td><td className="r num">{n1(e.quantity)} {e.factor?.unit}</td><td className="r num">{n1(e.kg_co2e)}</td>
          <td>{[b.proj(e.project_id), e.source_ref, e.note].filter(Boolean).join(' · ')}</td>
          <td className="r">{canFactors && <ConfirmButton className="btn small ghost" label="Delete" confirm="Delete this record?" onConfirm={() => act.run(async () => { await q(supabase.from('esg_entries').delete().eq('id', e.id) as any); reload(); }, 'Deleted')} />}</td></tr>)}</tbody>
      </table></div> : <Empty>No records in this period.</Empty>}</Panel>}
      {tab === 'hours' && <Panel title="Hours worked (for safety rates and intensity)" actions={canHours && <button className="btn small primary" type="button" onClick={() => setHours({ period: today().slice(0, 7), project_id: '', hours: '', headcount: '', note: '' })}>Add hours</button>}>
        <div className="body muted" style={{ fontSize: 13 }}>Approved timesheet hours count automatically ({n1(data.s?.hours)} h in total for this period, including the rows below). Add hours worked by site labour, casuals and subcontractors that are not on timesheets.</div>
        {data.hrs.length ? <table><tbody>{data.hrs.map(h => <tr key={h.id}><td className="num">{h.period.slice(0, 7)}</td><td>{b.proj(h.project_id) || 'Company'}</td><td className="r num">{n1(h.hours)} h</td><td className="r">{h.headcount ? h.headcount + ' people' : ''}</td><td className="muted">{h.note}</td>
          <td className="r">{canFactors && <ConfirmButton className="btn small ghost" label="Delete" confirm="Delete?" onConfirm={() => act.run(async () => { await q(supabase.from('hse_hours').delete().eq('id', h.id) as any); reload(); }, 'Deleted')} />}</td></tr>)}</tbody></table> : <Empty>No extra hours recorded.</Empty>}
      </Panel>}
      {tab === 'factors' && <Panel title="Emission factors" actions={canFactors && <button className="btn small primary" type="button" onClick={() => setFactor({ key: '', name: '', category: 'fuel', scope: '1', unit: '', kg_co2e: '', source: '', waste_route: '', active: true })}>Add factor</button>}>
        <div className="body muted" style={{ fontSize: 13 }}>kg of CO2 equivalent for each unit used. Fuel factors are the UK government (DESNZ/DEFRA) 2026 set; grid electricity uses the IFI harmonised factor for Ghana. Replace them with Ghana Energy Commission or supplier figures when you have them. Changing a factor applies to new records only.</div>
        <div className="scroll"><table><thead><tr><th>Item</th><th>Scope</th><th className="r">kg CO2e per unit</th><th>Source</th><th></th></tr></thead>
          <tbody>{data.factors.map(f => <tr key={f.id}><td>{f.name}{!f.active && <span className="pill" style={{ marginLeft: 6 }}>Not in use</span>}<br /><span className="muted" style={{ fontSize: 12 }}>per {f.unit} · {f.category}</span></td>
            <td>{f.scope ? `Scope ${f.scope}` : '—'}</td><td className="r num">{Number(f.kg_co2e).toLocaleString('en-GB', { maximumFractionDigits: 6 })}</td><td className="wrap-cell" style={{ fontSize: 12 }}>{f.source}</td>
            <td className="r">{canFactors && <button className="btn small" type="button" onClick={() => setFactor({ ...f, scope: f.scope ? String(f.scope) : '', kg_co2e: String(f.kg_co2e), waste_route: f.waste_route || '', source: f.source || '' })}>Edit</button>}</td></tr>)}</tbody></table></div>
      </Panel>}
    </>}
    {entry && data && <FormModal title="Record usage" busy={act.busy} onClose={() => setEntry(null)} onSave={() => act.run(async () => {
      await q(supabase.from('esg_entries').insert({ company_id: cid, period: entry.period + '-01', factor_id: entry.factor_id, quantity: Number(entry.quantity), project_id: entry.project_id || null, source_ref: entry.source_ref || null, note: entry.note || null }) as any);
      setEntry(null); reload(); }, 'Recorded')}>
      <div className="grid-form">
        <Field label="Month" id="es-month" type="month" value={entry.period} onChange={v => setEntry({ ...entry, period: v })} required />
        <Select label="What" id="es-factor" value={entry.factor_id} onChange={v => setEntry({ ...entry, factor_id: v })} options={data.factors.filter(f => f.active).map(f => [f.id, `${f.name} (${f.unit})`] as [string, string])} />
        <Field label={`Quantity (${data.factors.find(f => f.id === entry.factor_id)?.unit || ''})`} id="es-qty" type="number" step="0.001" min="0" value={entry.quantity} onChange={v => setEntry({ ...entry, quantity: v })} required />
        <Select label="Project" id="es-proj" value={entry.project_id} onChange={v => setEntry({ ...entry, project_id: v })} options={[['', 'Company (office, yard, fleet)'], ...b.projOpts.slice(1)]} />
        <Field label="Reference (bill, meter reading)" id="es-ref" value={entry.source_ref} onChange={v => setEntry({ ...entry, source_ref: v })} />
        <Field label="Note" id="es-note" value={entry.note} onChange={v => setEntry({ ...entry, note: v })} />
      </div>
      {entry.quantity && <p className="muted" style={{ margin: 0 }}>≈ {n1(Number(entry.quantity) * Number(data.factors.find(f => f.id === entry.factor_id)?.kg_co2e || 0))} kg CO2e</p>}
    </FormModal>}
    {hours && <FormModal title="Add hours worked" busy={act.busy} onClose={() => setHours(null)} onSave={() => act.run(async () => {
      await q(supabase.from('hse_hours').insert({ company_id: cid, period: hours.period + '-01', project_id: hours.project_id || null, hours: Number(hours.hours), headcount: hours.headcount ? Number(hours.headcount) : null, note: hours.note || null }) as any);
      setHours(null); reload(); }, 'Saved')}>
      <div className="grid-form">
        <Field label="Month" id="hh-month" type="month" value={hours.period} onChange={v => setHours({ ...hours, period: v })} required />
        <Select label="Project" id="hh-proj" value={hours.project_id} onChange={v => setHours({ ...hours, project_id: v })} options={[['', 'Company'], ...b.projOpts.slice(1)]} />
        <Field label="Hours" id="hh-hours" type="number" step="0.5" min="0" value={hours.hours} onChange={v => setHours({ ...hours, hours: v })} required />
        <Field label="People" id="hh-head" type="number" min="0" value={hours.headcount} onChange={v => setHours({ ...hours, headcount: v })} />
      </div>
      <Field label="Who (e.g. casual labour, ABC Scaffolding Ltd)" id="hh-note" value={hours.note} onChange={v => setHours({ ...hours, note: v })} />
    </FormModal>}
    {factor && <FormModal title={factor.id ? 'Edit emission factor' : 'Add emission factor'} busy={act.busy} onClose={() => setFactor(null)} onSave={() => act.run(async () => {
      const row = { name: factor.name, category: factor.category, scope: factor.scope ? Number(factor.scope) : null, unit: factor.unit, kg_co2e: Number(factor.kg_co2e) || 0, source: factor.source || null, waste_route: factor.category === 'waste' ? factor.waste_route || null : null, active: factor.active };
      if (factor.id) await q(supabase.from('esg_factors').update(row).eq('id', factor.id) as any);
      else await q(supabase.from('esg_factors').insert({ ...row, company_id: cid, key: (factor.name || 'item').toLowerCase().replace(/[^a-z0-9]+/g, '_').slice(0, 40) + '_' + Math.random().toString(36).slice(2, 6) }) as any);
      setFactor(null); reload(); }, 'Saved')}>
      <div className="grid-form">
        <Field label="Name" id="ef-name" value={factor.name} onChange={v => setFactor({ ...factor, name: v })} required />
        <Select label="Category" id="ef-cat" value={factor.category} onChange={v => setFactor({ ...factor, category: v })} options={[['fuel', 'Fuel'], ['electricity', 'Electricity'], ['water', 'Water'], ['waste', 'Waste'], ['travel', 'Travel'], ['refrigerant', 'Refrigerant'], ['other', 'Other']]} />
        <Select label="GHG scope" id="ef-scope" value={factor.scope} onChange={v => setFactor({ ...factor, scope: v })} options={[['', 'Not counted as emissions'], ['1', 'Scope 1 (direct)'], ['2', 'Scope 2 (purchased energy)'], ['3', 'Scope 3 (value chain)']]} />
        <Field label="Unit" id="ef-unit" value={factor.unit} onChange={v => setFactor({ ...factor, unit: v })} placeholder="litre, kWh, kg, km" required />
        <Field label="kg CO2e per unit" id="ef-kg" type="number" step="0.000001" min="0" value={factor.kg_co2e} onChange={v => setFactor({ ...factor, kg_co2e: v })} />
        {factor.category === 'waste' && <Select label="Waste goes to" id="ef-route" value={factor.waste_route} onChange={v => setFactor({ ...factor, waste_route: v })} options={[['landfill', 'Landfill'], ['recycled', 'Recycled'], ['reused', 'Reused'], ['composted', 'Composted'], ['incinerated', 'Incinerated'], ['hazardous', 'Hazardous waste contractor']]} />}
      </div>
      <Field label="Source of the factor" id="ef-src" value={factor.source} onChange={v => setFactor({ ...factor, source: v })} />
      <label className="check"><input type="checkbox" checked={factor.active} onChange={e => setFactor({ ...factor, active: e.target.checked })} /> In use</label>
    </FormModal>}
  </>;
}


// ---------------------------------------------------------------- Toolbox talks, inductions, drills and safety meetings
export const SESSION_KINDS: [string, string][] = [['toolbox', 'Toolbox talk'], ['site_induction', 'Site induction (project)'], ['company_induction', 'Company induction (new staff)'],
  ['visitor_induction', 'Visitor induction'], ['emergency_drill', 'Emergency drill'], ['safety_meeting', 'Safety meeting / committee']];
const TOOLBOX_TOPICS = ['Working near live electrical equipment', 'Lock-out / tag-out', 'Working at height and harness use', 'Manual handling and cable drums', 'Excavations and underground services',
  'Lifting operations and slinging', 'Heat stress and hydration', 'PPE: correct use and care', 'Housekeeping and slips, trips, falls', 'Hot work and fire prevention', 'Hand and power tools',
  'Vehicle and plant movement on site', 'Emergency procedure and assembly point', 'Chemical and fuel handling, spills', 'Lessons from a recent incident'];

export function SessionForm({ f, setF, onDone, fixedProject }: { f: any; setF: (v: any) => void; onDone: (id: string) => void; fixedProject?: string }) {
  const { cid } = useSession();
  const b = useHseBasics();
  const act = useAction();
  return <FormModal title="Record a toolbox talk, induction or drill" submit="Next: attendance" busy={act.busy} onClose={() => setF(null)} onSave={() => act.run(async () => {
    const r = await q<any>(supabase.from('hse_sessions').insert({ company_id: cid, kind: f.kind, project_id: (fixedProject || f.project_id) || null, held_on: f.held_on, start_time: f.start_time || null,
      duration_min: f.duration_min ? Number(f.duration_min) : null, topic: f.topic || label(SESSION_KINDS, f.kind), content: f.content || null, location: f.location || null,
      presenter_id: f.presenter_id || null, presenter_name: f.presenter_name || null }).select('id').single() as any);
    onDone(r.id); })}>
    <div className="grid-form">
      <Select label="What" id="ss-kind" value={f.kind} onChange={v => setF({ ...f, kind: v })} options={SESSION_KINDS} />
      {!fixedProject && <Select label={f.kind === 'site_induction' ? 'Project (required)' : 'Project'} id="ss-proj" value={f.project_id} onChange={v => setF({ ...f, project_id: v })} options={b.projOpts} />}
      <Field label="Date" id="ss-date" type="date" value={f.held_on} onChange={v => setF({ ...f, held_on: v })} required />
      <Field label="Start time" id="ss-time" type="time" value={f.start_time} onChange={v => setF({ ...f, start_time: v })} />
      <Field label="Minutes" id="ss-min" type="number" min="1" value={f.duration_min} onChange={v => setF({ ...f, duration_min: v })} />
      <Field label="Location" id="ss-loc" value={f.location} onChange={v => setF({ ...f, location: v })} />
      <Select label="Presented by" id="ss-pres" value={f.presenter_id} onChange={v => setF({ ...f, presenter_id: v })} options={b.teamOpts} />
      {!f.presenter_id && <Field label="Presenter (if not on the system)" id="ss-presn" value={f.presenter_name} onChange={v => setF({ ...f, presenter_name: v })} />}
    </div>
    <Field label="Topic" id="ss-topic" value={f.topic} onChange={v => setF({ ...f, topic: v })} placeholder={f.kind === 'toolbox' ? 'e.g. Working near live 33 kV equipment' : ''} />
    {f.kind === 'toolbox' && <div className="actions" style={{ flexWrap: 'wrap' }}>{TOOLBOX_TOPICS.map(t => <button key={t} type="button" className="btn small ghost" onClick={() => setF({ ...f, topic: t })}>{t}</button>)}</div>}
    <Field label={f.kind.includes('induction') ? 'What was covered (site rules, hazards, emergency, PPE, welfare, permits)' : 'Key points covered'} id="ss-content" type="textarea" value={f.content} onChange={v => setF({ ...f, content: v })} />
  </FormModal>;
}

export function HseSessionsPage() {
  const { cid } = useSession();
  const nav = useNavigate();
  const b = useHseBasics();
  const [kind, setKind] = useState('');
  const [form, setForm] = useState<any | null>(null);
  const { data, error, loading } = useLoad(() => q<any[]>(supabase.from('hse_sessions').select('*, attendees:hse_session_attendees(id,attended)').eq('company_id', cid).order('held_on', { ascending: false }).limit(1000) as any), [cid]);
  const rows = (data || []).filter(s => !kind || s.kind === kind);
  return <>
    <PageHead title="Toolbox talks, inductions and drills" sub="Daily toolbox talks, inductions for new staff, for each site and for visitors, emergency drills and safety meetings, with who attended.">
      <Link className="btn" to="/hse/inductions">Induction register</Link>
      <button className="btn primary" type="button" onClick={() => setForm({ kind: 'toolbox', project_id: '', held_on: today(), start_time: '07:00', duration_min: '15', topic: '', content: '', location: '', presenter_id: b.me || '', presenter_name: '' })}>Record</button>
    </PageHead>
    <div className="filters"><div className="actions" style={{ alignSelf: 'end', flexWrap: 'wrap' }}>{([['', 'All'], ...SESSION_KINDS] as [string, string][]).map(([k, l]) =>
      <button key={k} type="button" className={'btn small' + (kind === k ? ' primary' : '')} onClick={() => setKind(k)}>{l.replace(/ \(.*\)$/, '')}</button>)}</div></div>
    <Loading error={error} loading={loading && !data} />
    {data && <Panel>{rows.length ? <div className="scroll"><table>
      <thead><tr><th>Date</th><th>What</th><th>Topic</th><th>Project</th><th className="r">People</th><th>Status</th></tr></thead>
      <tbody>{rows.map(s => <tr key={s.id} className="click" tabIndex={0} onClick={() => nav('/hse/talks/' + s.id)} onKeyDown={e => e.key === 'Enter' && nav('/hse/talks/' + s.id)}>
        <td className="num">{longDate(s.held_on)}<br /><span className="muted" style={{ fontSize: 12 }}>{s.number}</span></td><td>{label(SESSION_KINDS, s.kind).replace(/ \(.*\)$/, '')}</td>
        <td className="wrap-cell">{s.topic}</td><td>{b.proj(s.project_id)}</td><td className="r num">{s.attendees.filter((a: any) => a.attended).length}</td>
        <td>{s.status === 'recorded' ? <span className="pill good">Recorded</span> : <span className="pill warn">Attendance open</span>}</td></tr>)}</tbody>
    </table></div> : <Empty>Nothing recorded yet. Supervisors record each morning's toolbox talk here; HSE, HR or the project manager record inductions.</Empty>}</Panel>}
    {form && <SessionForm f={form} setF={setForm} onDone={id => nav('/hse/talks/' + id)} />}
  </>;
}

export function HseSessionView() {
  const { id } = useParams();
  const { company } = useSession();
  const b = useHseBasics();
  const act = useAction();
  const [pick, setPick] = useState<string[]>([]);
  const [extra, setExtra] = useState('');
  const { data, error, loading, reload } = useLoad(async () => {
    const s = await q<any>(supabase.from('hse_sessions').select('*').eq('id', id).single() as any);
    const att = await q<any[]>(supabase.from('hse_session_attendees').select('*').eq('session_id', id).order('name') as any);
    let team: any[] = [];
    if (s.project_id) team = await q<any[]>(supabase.from('project_assignments').select('employee_id').eq('project_id', s.project_id) as any).catch(() => [] as any[]);
    return { s, att, team: team.map(t => t.employee_id) };
  }, [id]);
  if (!data) return <Loading error={error} loading={loading} />;
  const { s, att, team } = data;
  const editable = s.status === 'draft' ? (s.created_by === b.me || s.presenter_id === b.me || b.hse || b.pm(s.project_id)) : b.hse;
  const induction = s.kind.includes('induction');
  const have = new Set(att.map(a => a.employee_id).filter(Boolean));
  const staffOpts = [...b.staff].sort((x, y) => Number(team.includes(y.id)) - Number(team.includes(x.id)) || x.full_name.localeCompare(y.full_name)).filter(e => !have.has(e.id));
  const add = () => act.run(async () => {
    const rows = [...pick.map(eid => ({ session_id: s.id, employee_id: eid, name: '' })),
      ...extra.split('\n').map(l => l.trim()).filter(Boolean).map(l => { const [name, org] = l.split(',').map(x => x.trim()); return { session_id: s.id, employee_id: null, name, organisation: org || null }; })];
    if (!rows.length) throw new Error('Tick staff or type names');
    await q(supabase.from('hse_session_attendees').insert(rows) as any); setPick([]); setExtra(''); reload(); }, 'Added');
  const sheet = () => tablePdf({ company: company!, title: `${label(SESSION_KINDS, s.kind).replace(/ \(.*\)$/, '')} ${s.number}`,
    subtitle: `${s.topic} · ${longDate(s.held_on)}${s.start_time ? ' ' + s.start_time.slice(0, 5) : ''}${s.duration_min ? ` · ${s.duration_min} min` : ''}${b.proj(s.project_id) ? ' · ' + b.proj(s.project_id) : ''}${s.location ? ' · ' + s.location : ''}`,
    head: ['#', 'Name', 'Company', induction ? 'Valid until' : 'Attended', 'Signature'],
    body: [...att.map((a, i) => [i + 1, a.name, a.organisation || company!.name, induction ? (a.valid_until || '') : (a.attended ? 'Yes' : 'No'), '']), ...Array.from({ length: Math.max(0, 12 - att.length) }, (_, i) => [att.length + i + 1, '', '', '', ''])],
    filename: `${s.number}-attendance`, notes: `Presented by ${s.presenter_name || b.who(s.presenter_id) || '__________'}. ${s.content ? 'Covered: ' + s.content : ''}` });
  return <>
    <PageHead title={`${s.number} · ${s.topic}`} sub={<>{label(SESSION_KINDS, s.kind)} · {longDate(s.held_on)}{b.proj(s.project_id) ? ' · ' + b.proj(s.project_id) : ''} · presented by {s.presenter_name || b.who(s.presenter_id)} {s.status === 'recorded' ? <span className="pill good">Recorded</span> : <span className="pill warn">Attendance open</span>}</>}>
      <Link className="btn" to="/hse/talks">Back</Link>
      <button className="btn" type="button" onClick={sheet}>Sign-in sheet PDF</button>
      {s.status === 'draft' && editable && <button className="btn primary" type="button" disabled={act.busy} onClick={() => act.run(async () => { await rpc('record_hse_session', { p_id: s.id }); reload(); }, induction ? 'Recorded. Each person is inducted until the date shown.' : 'Recorded')}>Record</button>}
    </PageHead>
    {s.content && <Panel title="Covered" pad><div style={{ whiteSpace: 'pre-wrap' }}>{s.content}</div></Panel>}
    <Panel title={`Attendance (${att.filter(a => a.attended).length})`}>
      {att.length ? <table><tbody>{att.map(a => <tr key={a.id}><td>{a.name}</td><td className="muted">{a.organisation || (a.employee_id ? 'Staff' : '')}</td>
        <td>{induction && a.valid_until ? <span className={'pill ' + (a.valid_until < today() ? 'bad' : 'good')}>Valid until {longDate(a.valid_until)}</span> : ''}</td>
        <td className="r">{editable && <ConfirmButton className="btn small ghost" label="Remove" confirm="Remove from the list?" onConfirm={() => act.run(async () => { await q(supabase.from('hse_session_attendees').delete().eq('id', a.id) as any); reload(); })} />}</td></tr>)}</tbody></table>
        : <Empty>Nobody on the list yet.</Empty>}
      {editable && <div className="body" style={{ display: 'grid', gap: 10, borderTop: '1px solid var(--line)' }}>
        <div className="label">Add staff{team.length ? ' (project team first)' : ''}</div>
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(220px, 1fr))', gap: 4, maxHeight: 260, overflowY: 'auto' }}>
          {staffOpts.map(e => <label key={e.id} className="check"><input type="checkbox" checked={pick.includes(e.id)} onChange={ev => setPick(ev.target.checked ? [...pick, e.id] : pick.filter(x => x !== e.id))} /> {e.full_name}{team.includes(e.id) ? <span className="muted"> · team</span> : ''}</label>)}
        </div>
        <Field label="Others: one per line, name then company (subcontractors, casuals, visitors)" id="sv-extra" type="textarea" value={extra} onChange={setExtra} placeholder={'Ama Owusu, ABC Scaffolding Ltd\nYaw Boateng, casual'} />
        <div><button className="btn primary" type="button" onClick={add} disabled={act.busy}>Add to list</button> <span className="muted" style={{ fontSize: 13 }}>Print the sign-in sheet for signatures, then Record. Upload the signed sheet below.</span></div>
      </div>}
    </Panel>
    <Files type="session" id={s.id} canAdd />
  </>;
}

export function HseInductionsPage() {
  const { cid, company, can } = useSession();
  const b = useHseBasics();
  const act = useAction();
  const [proj, setProj] = useState('');
  const [state, setState] = useState('gaps');
  const { data, error, loading, reload } = useLoad(async () => {
    const [reg, co] = await Promise.all([
      rpc<any[]>('induction_register', { cid, p_project: proj || null }),
      q<any>(supabase.from('companies').select('require_site_induction,induction_valid_months').eq('id', cid).single() as any).catch(() => null),
    ]);
    return { reg, co };
  }, [cid, proj]);
  const rows = (data?.reg || []).filter(r => state === 'all' || (state === 'gaps' ? r.state !== 'valid' : r.state === state));
  const ST: Record<string, [string, string]> = { valid: ['Valid', 'good'], expiring: ['Expires within 30 days', 'warn'], expired: ['Expired', 'bad'], missing: ['Not inducted', 'bad'] };
  const head = ['Employee', 'Induction', 'Project', 'Inducted on', 'Valid until', 'State'];
  const body = rows.map(r => [r.full_name, r.kind === 'company_induction' ? 'Company' : 'Site', b.proj(r.project_id), r.held_on || '', r.valid_until || '', ST[r.state][0]]);
  return <>
    <PageHead title="Induction register" sub="Who has had the company induction, and the site induction for each project they are assigned to (Project → Team).">
      <Link className="btn" to="/hse/talks">Back</Link>
      <button className="btn" type="button" onClick={() => tablePdf({ company: company!, title: 'Induction register', subtitle: longDate(today()), head, body, filename: 'induction-register' })}>PDF</button>
      <button className="btn" type="button" onClick={() => downloadCsv('induction-register', head, body)}>CSV</button>
    </PageHead>
    {data?.co && (b.hse || can()) && <Panel title="Induction rules" pad><div className="actions" style={{ flexWrap: 'wrap', gap: 16 }}>
      <label className="check"><input type="checkbox" checked={data.co.require_site_induction} onChange={e => act.run(async () => { await rpc('set_induction_rules', { cid, p_required: e.target.checked, p_months: data.co.induction_valid_months }); reload(); }, e.target.checked ? 'No induction, no work: on' : 'Turned off')} /> <b>No induction, no work</b>: time cannot be booked to a project for someone without a valid site induction</label>
      <span>Inductions valid for <select aria-label="Months valid" style={{ width: 'auto', display: 'inline-block' }} value={data.co.induction_valid_months} onChange={e => act.run(async () => { await rpc('set_induction_rules', { cid, p_required: data.co.require_site_induction, p_months: Number(e.target.value) }); reload(); }, 'Saved')}>{[6, 12, 24, 36].map(m => <option key={m} value={m}>{m} months</option>)}</select> (visitors: 1 month)</span>
    </div></Panel>}
    <div className="filters">
      <Select label="Project" id="ir-proj" value={proj} onChange={setProj} options={[['', 'Company induction and all projects'], ...b.projOpts.slice(1)]} />
      <div className="actions" style={{ alignSelf: 'end' }}>{([['gaps', 'Gaps'], ['missing', 'Not inducted'], ['expired', 'Expired'], ['expiring', 'Expiring'], ['valid', 'Valid'], ['all', 'All']] as const).map(([k, l]) =>
        <button key={k} type="button" className={'btn small' + (state === k ? ' primary' : '')} onClick={() => setState(k)}>{l}</button>)}</div>
    </div>
    <Loading error={error} loading={loading && !data} />
    {data && <Panel>{rows.length ? <div className="scroll"><table>
      <thead><tr><th>Employee</th><th>Induction</th><th>Inducted</th><th>Valid until</th><th>State</th></tr></thead>
      <tbody>{rows.map((r, i) => <tr key={i}><td>{r.full_name}</td><td>{r.kind === 'company_induction' ? 'Company' : 'Site · ' + b.proj(r.project_id)}</td>
        <td className="num">{r.held_on ? (r.session_id ? <Link to={'/hse/talks/' + r.session_id}>{longDate(r.held_on)}</Link> : longDate(r.held_on)) : '—'}</td><td className="num">{r.valid_until ? longDate(r.valid_until) : '—'}</td>
        <td><span className={'pill ' + ST[r.state][1]}>{ST[r.state][0]}</span></td></tr>)}</tbody>
    </table></div> : <Empty>{state === 'gaps' ? 'No gaps: everyone has a valid induction.' : 'Nothing here.'}</Empty>}</Panel>}
  </>;
}

// ---------------------------------------------------------------- Safety tab on a project
export function ProjectSafety({ p }: { p: any }) {
  const { cid } = useSession();
  const nav = useNavigate();
  const b = useHseBasics();
  const [report, setReport] = useState(false);
  const [talk, setTalk] = useState<any | null>(null);
  const start = p.actual_start || p.start_date || today();
  const { data, error, loading } = useLoad(async () => {
    const [stats, incidents, permits, sessions, inspections, actions, reg] = await Promise.all([
      rpc<any[]>('hse_stats', { cid, p_from: start < today() ? start : today(), p_to: today(), p_project: p.id }),
      q<any[]>(supabase.from('hse_incidents').select('id,number,kind,occurred_at,description,status').eq('project_id', p.id).order('occurred_at', { ascending: false }).limit(20) as any),
      q<any[]>(supabase.from('hse_permits').select('id,number,kind,location,valid_from,valid_to,status').eq('project_id', p.id).in('status', ['requested', 'approved', 'suspended']).order('valid_from') as any),
      q<any[]>(supabase.from('hse_sessions').select('id,number,kind,topic,held_on,status, attendees:hse_session_attendees(id)').eq('project_id', p.id).order('held_on', { ascending: false }).limit(15) as any),
      q<any[]>(supabase.from('hse_inspections').select('id,number,title,inspected_on,score,status').eq('project_id', p.id).order('inspected_on', { ascending: false }).limit(10) as any),
      q<any[]>(supabase.from('hse_actions').select('*').eq('project_id', p.id).in('status', ['open', 'done']).order('due_date', { nullsFirst: false }) as any),
      rpc<any[]>('induction_register', { cid, p_project: p.id }),
    ]);
    return { s: stats[0], incidents, permits, sessions, inspections, actions, reg };
  }, [p.id, cid]);
  if (!data) return <Loading error={error} loading={loading} />;
  const { s } = data;
  const notInducted = data.reg.filter(r => r.state !== 'valid');
  const todayTalk = data.sessions.some(x => x.kind === 'toolbox' && x.held_on === today());
  return <>
    <div className="actions" style={{ marginBottom: 12, flexWrap: 'wrap' }}>
      <button className="btn primary" type="button" onClick={() => setReport(true)}>Report incident or hazard</button>
      <button className="btn" type="button" onClick={() => setTalk({ kind: 'toolbox', project_id: p.id, held_on: today(), start_time: '07:00', duration_min: '15', topic: '', content: '', location: p.location || '', presenter_id: b.me || '', presenter_name: '' })}>Record toolbox talk</button>
      <button className="btn" type="button" onClick={() => setTalk({ kind: 'site_induction', project_id: p.id, held_on: today(), start_time: '', duration_min: '45', topic: `${p.name} site induction`, content: '', location: p.location || '', presenter_id: b.me || '', presenter_name: '' })}>Site induction</button>
      <Link className="btn" to="/hse/permits">Request permit to work</Link>
      <Link className="btn" to="/hse/inspections">Start inspection</Link>
    </div>
    <div className="tiles">
      <div className="tile"><span>Days without a lost-time injury</span><b style={{ color: 'var(--good)' }}>{s.days_since_lti ?? '—'}</b><span>{s.ltis} LTI · {s.recordables} recordable since the start</span></div>
      <div className="tile"><span>LTIFR · TRIR</span><b>{n1(s.ltifr)} · {n1(s.trir)}</b><span>{n1(s.hours)} hours worked</span></div>
      <div className="tile"><span>Toolbox talks</span><b>{s.toolbox_talks}</b><span>{s.toolbox_attendance} attendances{todayTalk ? ' · today done' : ' · none today'}</span></div>
      <div className="tile"><span>Site inductions</span><b style={{ color: notInducted.length ? 'var(--bad)' : undefined }}>{data.reg.length - notInducted.length} / {data.reg.length}</b><span>team members inducted</span></div>
      <div className="tile"><span>Near misses and observations</span><b>{s.near_misses + s.observations}</b><span>reported since the start</span></div>
      <div className="tile"><span>Actions open</span><b style={{ color: s.overdue_actions ? 'var(--bad)' : undefined }}>{s.open_actions}</b><span>{s.overdue_actions} overdue</span></div>
    </div>
    {notInducted.length > 0 && <div className="note" style={{ marginTop: 12, background: 'var(--warn-soft)' }}>Not inducted for this site: {notInducted.map(r => r.full_name).join(', ')}. Give the site induction before they start work.</div>}
    <div className="grid-2" style={{ marginTop: 16 }}>
      <Panel title="Permits to work open">{data.permits.length ? <table><tbody>{data.permits.map(w => <tr key={w.id}><td className="num">{w.number}</td><td>{label(PERMIT_KINDS, w.kind).replace(/ \(.*\)$/, '')}<br /><span className="muted" style={{ fontSize: 12 }}>{w.location} · until {dt(w.valid_to)}</span></td><td><Pill map={PERMIT_STATUS} s={w.status} /></td></tr>)}</tbody></table> : <Empty>No open permits.</Empty>}</Panel>
      <Panel title="Incidents and observations">{data.incidents.length ? <table><tbody>{data.incidents.map(i => <tr key={i.id} className="click" onClick={() => nav('/hse/incidents/' + i.id)}><td className="num" style={{ whiteSpace: 'nowrap' }}>{i.number}<br /><span className="muted" style={{ fontSize: 12 }}>{dt(i.occurred_at)}</span></td><td><KindPill k={i.kind} /><div style={{ fontSize: 13 }}>{i.description.slice(0, 80)}</div></td><td><Pill map={INC_STATUS} s={i.status} /></td></tr>)}</tbody></table> : <Empty>Nothing reported on this project.</Empty>}</Panel>
      <Panel title="Talks, inductions and drills">{data.sessions.length ? <table><tbody>{data.sessions.map(x => <tr key={x.id} className="click" onClick={() => nav('/hse/talks/' + x.id)}><td className="num">{longDate(x.held_on)}</td><td>{x.topic}<br /><span className="muted" style={{ fontSize: 12 }}>{label(SESSION_KINDS, x.kind).replace(/ \(.*\)$/, '')} · {x.attendees.length} people</span></td></tr>)}</tbody></table> : <Empty>No toolbox talks or inductions recorded yet.</Empty>}</Panel>
      <Panel title="Inspections">{data.inspections.length ? <table><tbody>{data.inspections.map(x => <tr key={x.id} className="click" onClick={() => nav('/hse/inspections/' + x.id)}><td className="num">{longDate(x.inspected_on)}</td><td>{x.title}</td><td className="r num">{x.score != null ? x.score + '%' : <span className="pill warn">In progress</span>}</td></tr>)}</tbody></table> : <Empty>No inspections yet.</Empty>}</Panel>
    </div>
    {data.actions.length > 0 && <Panel title="Open safety actions"><ActionTable rows={data.actions} b={b} /></Panel>}
    {report && <ReportIncident onClose={() => setReport(false)} onDone={id => nav('/hse/incidents/' + id)} />}
    {talk && <SessionForm f={talk} setF={setTalk} fixedProject={p.id} onDone={id => nav('/hse/talks/' + id)} />}
  </>;
}
