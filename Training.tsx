import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { q, rpc, supabase } from '../lib/supabase';
import { useSession } from '../lib/session';
import { cedis, longDate, money, today } from '../lib/format';
import { downloadCsv } from '../lib/download';
import { tablePdf } from '../lib/pdf';
import { ConfirmButton, Downloads, Empty, Field, FormModal, Loading, PageHead, Panel, Select, useAction, useLoad } from '../components/ui';

const KINDS: [string, string][] = [['course', 'Course'], ['certification', 'Certification'], ['safety_induction', 'Safety induction'], ['workshop', 'Workshop or seminar'], ['on_the_job', 'On-the-job training']];
const PRIORITY: [string, string][] = [['low', 'Low'], ['normal', 'Normal'], ['high', 'High'], ['mandatory', 'Mandatory (legal or safety)']];
const REQ_STATUS: Record<string, [string, string]> = { submitted: ['Awaiting HR', 'warn'], approved: ['Approved', 'good'], rejected: ['Rejected', 'bad'], scheduled: ['Scheduled', 'good'], completed: ['Completed', 'good'], cancelled: ['Cancelled', ''] };
const SESSION_STATUS: [string, string][] = [['planned', 'Planned'], ['in_progress', 'In progress'], ['completed', 'Completed'], ['cancelled', 'Cancelled']];
const RESULT: [string, string][] = [['enrolled', 'Enrolled'], ['attended', 'Attended'], ['passed', 'Passed'], ['failed', 'Failed'], ['absent', 'Absent']];
const kindName = (k: string) => KINDS.find(x => x[0] === k)?.[1] || k;
const certPill = (s: string | null) => s === 'expired' ? <span className="pill bad">Expired</span> : s === 'expiring' ? <span className="pill warn">Expires soon</span> : s === 'valid' ? <span className="pill good">Valid</span> : null;

type Tab = 'requests' | 'sessions' | 'records' | 'certificates';

/** HR training: requests from staff and managers, approval, sessions, attendance and results, certificates, and each employee's history. */
export function TrainingPage() {
  const { cid, company, can, role } = useSession();
  const nav = useNavigate();
  const act = useAction();
  const hr = can('hr');
  const [tab, setTab] = useState<Tab>('requests');
  const [show, setShow] = useState<'open' | 'all'>('open');
  const [req, setReq] = useState<any | null>(null);
  const [decide, setDecide] = useState<any | null>(null);
  const [ticked, setTicked] = useState<Set<string>>(new Set());
  const [sched, setSched] = useState<any | null>(null);
  const [sess, setSess] = useState<any | null>(null);
  const [open, setOpen] = useState<string | null>(null);
  const [emp, setEmp] = useState('');
  const { data, error, loading, reload } = useLoad(async () => {
    // HR and accountants read the employee list; other managers get names only (no salaries); staff only themselves.
    const people = can('hr', 'accountant')
      ? await q<any[]>(supabase.from('employees').select('id,full_name,department,job_title').eq('company_id', cid).eq('status', 'active').order('full_name') as any).catch(() => [] as any[])
      : role !== 'staff' ? ((await rpc<any[]>('group_employee_names', { cid }).catch(() => [] as any[])) || []).filter(e => e.company_id === cid) : [];
    const mine = role === 'staff' || !people.length ? ((await rpc<any>('my_work', {}).catch(() => null))?.employees || []).filter((e: any) => e.company_id === cid) : [];
    const [requests, sessions, history, suppliers] = await Promise.all([
      q<any[]>(supabase.from('training_requests').select('*').eq('company_id', cid).order('created_at', { ascending: false }) as any),
      q<any[]>(supabase.from('trainings').select('*, attendees:training_attendees(id,employee_id,status,score,certificate_no,certified_on,expires_on)').eq('company_id', cid).order('start_date', { ascending: false, nullsFirst: true }) as any),
      rpc<any[]>('employee_training_history', { cid, p_employee: null }),
      hr ? q<any[]>(supabase.from('suppliers').select('id,name').eq('company_id', cid).order('name') as any).catch(() => [] as any[]) : Promise.resolve([]),
    ]);
    const staff = people.length ? people : mine.map((e: any) => ({ id: e.id, full_name: e.full_name }));
    return { staff, requests, sessions, history, suppliers };
  }, [cid]);
  if (!data) return <Loading error={error} loading={loading} />;
  const name = (id: string) => data.staff.find(s => s.id === id)?.full_name || data.history.find(h => h.employee_id === id)?.full_name || 'Me';
  const requests = data.requests.filter(r => show === 'all' || ['submitted', 'approved', 'scheduled'].includes(r.status));
  const pending = data.requests.filter(r => r.status === 'submitted').length;
  const certs = data.history.filter(h => h.expires_on);
  const soon = certs.filter(h => h.cert_state !== 'valid');
  const records = data.history.filter(h => !emp || h.employee_id === emp);
  const toggle = (id: string) => { const n = new Set(ticked); n.has(id) ? n.delete(id) : n.add(id); setTicked(n); };
  const selected = data.requests.filter(r => ticked.has(r.id) && r.status === 'approved');
  const openSession = data.sessions.find(s => s.id === open);

  const rHead = ['Request', 'Date', 'Employee', 'Training', 'Reason', 'Priority', 'Est. cost (GHS)', 'Preferred date', 'Requested by', 'Status', 'HR note'];
  const rRows = data.requests.map(r => [r.number, r.created_at.slice(0, 10), name(r.employee_id), r.title, r.reason || '', r.priority, money(r.est_cost), r.preferred_date || '', (r.requested_email || '').split('@')[0], REQ_STATUS[r.status][0], r.decision_note || '']);
  const hHead = ['Employee', 'Department', 'Training', 'Type', 'Provider', 'Start', 'End', 'Hours', 'Result', 'Score', 'Certificate', 'Expires'];
  const hRows = records.map(h => [h.full_name, h.department || '', h.title, kindName(h.kind), h.provider || '', h.start_date || '', h.end_date || '', h.hours ? String(Number(h.hours)) : '', h.status, h.score != null ? String(Number(h.score)) : '', h.certificate_no || '', h.expires_on || '']);
  const sHead = ['Training', 'Type', 'Provider', 'Start', 'End', 'Hours', 'Cost (GHS)', 'Attendees', 'Passed', 'Status'];
  const sRows = data.sessions.map(s => [s.title, kindName(s.kind), s.provider || '', s.start_date || '', s.end_date || '', s.hours ? String(Number(s.hours)) : '', money(s.cost), String(s.attendees.length), String(s.attendees.filter((a: any) => a.status === 'passed').length), s.status]);

  const saveAttendee = (a: any, patch: any) => act.run(async () => { await q(supabase.from('training_attendees').update(patch).eq('id', a.id) as any); reload(); });

  return <>
    <PageHead title="Training" sub={hr ? `${pending} request${pending === 1 ? '' : 's'} awaiting approval · ${data.sessions.filter(s => s.status === 'planned').length} sessions planned · ${soon.length} certificate${soon.length === 1 ? '' : 's'} expired or expiring in 60 days`
      : 'Ask for training and see the training you have received.'}>
      {tab === 'requests' && <Downloads pdf={() => tablePdf({ company: company!, title: 'Training requests', subtitle: longDate(today()), head: rHead, body: rRows, rightAlign: [6], landscape: true, filename: 'training-requests' })} csv={() => downloadCsv('training-requests', rHead, rRows)} />}
      {tab === 'sessions' && <Downloads pdf={() => tablePdf({ company: company!, title: 'Training sessions', head: sHead, body: sRows, rightAlign: [5, 6, 7, 8], landscape: true, filename: 'training-sessions' })} csv={() => downloadCsv('training-sessions', sHead, sRows)} />}
      {tab === 'records' && <Downloads pdf={() => tablePdf({ company: company!, title: emp ? `Training record: ${name(emp)}` : 'Training records, all employees', subtitle: longDate(today()), head: hHead, body: hRows, rightAlign: [7, 9], landscape: true, filename: emp ? `training-record-${name(emp)}` : 'training-records' })}
        csv={() => downloadCsv(emp ? `training-record-${name(emp)}` : 'training-records', hHead, hRows)} />}
      <button className="btn primary" type="button" disabled={!data.staff.length} title={data.staff.length ? undefined : 'Your login is not linked to an employee record yet. Ask HR.'}
        onClick={() => setReq({ employee_id: data.staff.length === 1 ? data.staff[0].id : '', title: '', reason: '', provider: '', est_cost: '', preferred_date: '', priority: 'normal' })}>Request training</button>
      {hr && <button className="btn" type="button" onClick={() => setSess({ title: '', kind: 'course', provider: '', start_date: '', end_date: '', location: '', hours: '', cost: '', valid_months: '', status: 'planned', notes: '' })}>New session</button>}
    </PageHead>
    <div className="actions">
      {([['requests', `Requests${pending ? ` (${pending})` : ''}`], ['sessions', 'Sessions'], ['records', hr || can('accountant') ? 'Employee records' : 'My training'], ['certificates', `Certificates${soon.length ? ` (${soon.length})` : ''}`]] as [Tab, string][])
        .filter(([t]) => hr || t !== 'sessions').map(([t, l]) => <button key={t} type="button" className={'btn small' + (tab === t ? ' primary' : '')} onClick={() => setTab(t)}>{l}</button>)}
    </div>

    {tab === 'requests' && <Panel title={<div className="actions"><h2>Training requests</h2>
        <button type="button" className={'btn small' + (show === 'open' ? ' primary' : '')} onClick={() => setShow('open')}>Open</button>
        <button type="button" className={'btn small' + (show === 'all' ? ' primary' : '')} onClick={() => setShow('all')}>All</button></div>}
      actions={hr && selected.length > 0 && <button className="btn small primary" type="button" onClick={() => setSched({ training_id: data.sessions.find(s => s.status === 'planned')?.id || 'new', title: selected[0].title, provider: selected[0].provider || '', start_date: selected[0].preferred_date || '', end_date: '', hours: '', cost: String(selected.reduce((s, r) => s + Number(r.est_cost), 0) || ''), kind: 'course', valid_months: '' })}>Schedule {selected.length} on a session</button>}>
      {requests.length ? <div className="scroll"><table>
        <thead><tr>{hr && <th style={{ width: 28 }}></th>}<th>Request</th><th>Employee</th><th>Training</th><th className="r">Est. cost (GH₵)</th><th>Status</th><th></th></tr></thead>
        <tbody>{requests.map(r => { const [st, c] = REQ_STATUS[r.status]; return <tr key={r.id}>
          {hr && <td>{r.status === 'approved' && <input type="checkbox" aria-label={'Select ' + r.number} checked={ticked.has(r.id)} onChange={() => toggle(r.id)} />}</td>}
          <td className="num">{r.number}<br /><span className="muted" style={{ fontSize: 12 }}>{r.created_at.slice(0, 10)} · {(r.requested_email || '').split('@')[0]}</span></td>
          <td>{name(r.employee_id)}</td>
          <td className="wrap-cell"><b>{r.title}</b>{r.priority !== 'normal' && <span className={'pill ' + (r.priority === 'mandatory' || r.priority === 'high' ? 'bad' : '')} style={{ marginLeft: 6 }}>{r.priority}</span>}
            {r.reason && <><br /><span className="muted">{r.reason}</span></>}
            {(r.provider || r.preferred_date) && <><br /><span className="muted" style={{ fontSize: 12 }}>{[r.provider, r.preferred_date && 'from ' + r.preferred_date].filter(Boolean).join(' · ')}</span></>}</td>
          <td className="r num">{money(r.est_cost)}</td>
          <td><span className={'pill ' + c}>{st}</span>{r.decision_note && <><br /><span className="muted" style={{ fontSize: 12 }}>{r.decision_note}</span></>}
            {r.training_id && <><br /><button className="btn ghost small" type="button" style={{ padding: 0, fontSize: 12 }} onClick={() => { setTab('sessions'); setOpen(r.training_id); }}>{data.sessions.find(s => s.id === r.training_id)?.title || 'Session'}</button></>}</td>
          <td className="r"><span className="actions" style={{ justifyContent: 'flex-end' }}>
            {hr && r.status === 'submitted' && <><button className="btn small primary" type="button" onClick={() => setDecide({ r, approve: true, note: '' })}>Approve</button>
              <button className="btn small" type="button" onClick={() => setDecide({ r, approve: false, note: '' })}>Reject</button></>}
            {r.status === 'submitted' && <ConfirmButton className="btn small ghost" label="Cancel" confirm={`Cancel ${r.number}?`} onConfirm={() => act.run(async () => { await q(supabase.from('training_requests').update({ status: 'cancelled' }).eq('id', r.id) as any); reload(); }, 'Cancelled')} />}
          </span></td></tr>; })}</tbody>
      </table></div> : <Empty>{show === 'open' ? 'No open training requests.' : 'No training requests yet.'} Anyone can ask for training for themselves; managers and HR can ask for anyone. HR approves, then puts approved requests on a session.</Empty>}
    </Panel>}

    {tab === 'sessions' && hr && <Panel>{data.sessions.length ? <div className="scroll"><table>
      <thead><tr><th>Training</th><th>Dates</th><th className="r">Hours</th><th className="r">Cost (GH₵)</th><th className="r">Attendees</th><th>Status</th></tr></thead>
      <tbody>{data.sessions.map(s => <tr key={s.id} className="click" tabIndex={0} onClick={() => setOpen(s.id)} onKeyDown={e => e.key === 'Enter' && setOpen(s.id)}>
        <td><b>{s.title}</b><br /><span className="muted">{kindName(s.kind)}{s.provider ? ' · ' + s.provider : ''}{s.location ? ' · ' + s.location : ''}</span></td>
        <td className="num">{s.start_date || '—'}{s.end_date && s.end_date !== s.start_date ? ' → ' + s.end_date : ''}</td>
        <td className="r num">{s.hours ? Number(s.hours) : ''}</td><td className="r num">{money(s.cost)}{s.bill_id && <><br /><span className="pill good">Billed</span></>}</td>
        <td className="r num">{s.attendees.length}{s.attendees.some((a: any) => a.status === 'passed') && <span className="muted"> ({s.attendees.filter((a: any) => a.status === 'passed').length} passed)</span>}</td>
        <td><span className={'pill ' + (s.status === 'completed' ? 'good' : s.status === 'cancelled' ? '' : 'warn')}>{SESSION_STATUS.find(x => x[0] === s.status)?.[1]}</span></td></tr>)}</tbody>
    </table></div> : <Empty>No sessions yet. Create one for each course, induction or workshop, then add attendees or schedule approved requests onto it.</Empty>}</Panel>}

    {tab === 'records' && <>
      {(hr || can('accountant')) && <Panel pad><div className="filters"><div className="field" style={{ width: 280 }}><label htmlFor="tr-emp">Employee</label>
        <select id="tr-emp" value={emp} onChange={e => setEmp(e.target.value)}><option value="">All employees</option>{data.staff.map(s => <option key={s.id} value={s.id}>{s.full_name}</option>)}</select></div>
        {emp && <div className="muted" style={{ alignSelf: 'end', paddingBottom: 8 }}>{records.length} training{records.length === 1 ? '' : 's'} · {records.reduce((s, h) => s + Number(h.hours || 0), 0)} hours · {records.filter(h => h.cert_state === 'valid').length} valid certificate{records.filter(h => h.cert_state === 'valid').length === 1 ? '' : 's'}</div>}
      </div></Panel>}
      <Panel>{records.length ? <div className="scroll"><table>
        <thead><tr>{!emp && <th>Employee</th>}<th>Training</th><th>Dates</th><th className="r">Hours</th><th>Result</th><th>Certificate</th></tr></thead>
        <tbody>{records.map((h, i) => <tr key={i}>
          {!emp && <td><button className="btn ghost small" type="button" style={{ padding: 0, fontWeight: 600 }} onClick={() => setEmp(h.employee_id)}>{h.full_name}</button><br /><span className="muted">{h.department}</span></td>}
          <td><b>{h.title}</b><br /><span className="muted">{kindName(h.kind)}{h.provider ? ' · ' + h.provider : ''}</span></td>
          <td className="num">{h.start_date || '—'}{h.end_date && h.end_date !== h.start_date ? ' → ' + h.end_date : ''}</td>
          <td className="r num">{h.hours ? Number(h.hours) : ''}</td>
          <td><span className={'pill ' + (h.status === 'passed' ? 'good' : h.status === 'failed' || h.status === 'absent' ? 'bad' : '')}>{RESULT.find(x => x[0] === h.status)?.[1]}</span>{h.score != null && <span className="muted num"> {Number(h.score)}%</span>}</td>
          <td>{h.certificate_no && <span className="num">{h.certificate_no}</span>}{h.expires_on && <><br /><span className="muted num" style={{ fontSize: 12 }}>to {h.expires_on}</span> {certPill(h.cert_state)}</>}</td></tr>)}</tbody>
      </table></div> : <Empty>No training recorded yet.</Empty>}</Panel>
    </>}

    {tab === 'certificates' && <Panel title="Certificates expired or expiring in the next 60 days">{soon.length ? <div className="scroll"><table>
      <thead><tr><th>Employee</th><th>Certificate</th><th>Expires</th><th></th></tr></thead>
      <tbody>{soon.sort((a, b) => a.expires_on.localeCompare(b.expires_on)).map((h, i) => <tr key={i}><td>{h.full_name}</td><td>{h.title}<br /><span className="muted num">{h.certificate_no}</span></td>
        <td className="num">{h.expires_on} {certPill(h.cert_state)}</td>
        <td className="r">{data.staff.some(s => s.id === h.employee_id) && <button className="btn small" type="button" onClick={() => setReq({ employee_id: h.employee_id, title: h.title + ' (renewal)', reason: `Certificate ${h.certificate_no || ''} expires ${h.expires_on}`, provider: h.provider || '', est_cost: '', preferred_date: '', priority: 'mandatory' })}>Request renewal</button>}</td></tr>)}</tbody>
    </table></div> : <Empty>{certs.length ? 'All certificates are valid for at least 60 more days.' : 'No certificates recorded yet. Set "Certificate valid for" on a session and mark attendees as passed.'}</Empty>}</Panel>}

    {req && <FormModal title="Request training" submit="Send to HR" busy={act.busy} onClose={() => setReq(null)}
      onSave={() => act.run(async () => {
        if (!req.employee_id) throw new Error('Choose who the training is for.');
        await q(supabase.from('training_requests').insert({ employee_id: req.employee_id, company_id: cid, title: req.title, reason: req.reason || null, provider: req.provider || null,
          est_cost: Number(req.est_cost) || 0, preferred_date: req.preferred_date || null, priority: req.priority }) as any);
        setReq(null); setTab('requests'); reload();
      }, 'Request sent to HR')}>
      <Select label="Training for" id="rq-emp" value={req.employee_id} onChange={v => setReq({ ...req, employee_id: v })} options={[['', 'Choose…'], ...data.staff.map(s => [s.id, s.full_name] as [string, string])]} />
      <Field label="Training needed" id="rq-title" value={req.title} onChange={v => setReq({ ...req, title: v })} placeholder="e.g. Forklift operator licence, Advanced Excel, First aid" required />
      <Field label="Why is it needed?" id="rq-reason" type="textarea" value={req.reason} onChange={v => setReq({ ...req, reason: v })} />
      <div className="grid-form">
        <Field label="Suggested provider" id="rq-prov" value={req.provider} onChange={v => setReq({ ...req, provider: v })} />
        <Field label="Estimated cost (GH₵)" id="rq-cost" type="number" step="0.01" min="0" value={req.est_cost} onChange={v => setReq({ ...req, est_cost: v })} />
        <Field label="Preferred start" id="rq-date" type="date" value={req.preferred_date} onChange={v => setReq({ ...req, preferred_date: v })} />
        <Select label="Priority" id="rq-pri" value={req.priority} onChange={v => setReq({ ...req, priority: v })} options={PRIORITY} />
      </div>
    </FormModal>}

    {decide && <FormModal title={`${decide.approve ? 'Approve' : 'Reject'} ${decide.r.number}`} submit={decide.approve ? 'Approve' : 'Reject'} busy={act.busy} onClose={() => setDecide(null)}
      onSave={() => act.run(async () => { await rpc('decide_training_request', { p_id: decide.r.id, p_approve: decide.approve, p_note: decide.note || null }); setDecide(null); reload(); }, decide.approve ? 'Approved' : 'Rejected')}>
      <p style={{ margin: 0 }}><b>{decide.r.title}</b> for {name(decide.r.employee_id)}{Number(decide.r.est_cost) ? `, estimated ${cedis(decide.r.est_cost)}` : ''}.</p>
      <Field label="Note to the requester" id="dc-note" value={decide.note} onChange={v => setDecide({ ...decide, note: v })} placeholder={decide.approve ? 'e.g. Booked with the March intake' : 'e.g. Not in this year\'s budget'} />
    </FormModal>}

    {sched && <FormModal title={`Schedule ${selected.length} request${selected.length === 1 ? '' : 's'}`} submit="Schedule" busy={act.busy} onClose={() => setSched(null)}
      onSave={() => act.run(async () => {
        let tid = sched.training_id;
        if (tid === 'new') tid = (await q<any>(supabase.from('trainings').insert({ company_id: cid, title: sched.title, kind: sched.kind, provider: sched.provider || null, start_date: sched.start_date || null,
          end_date: sched.end_date || null, hours: Number(sched.hours) || null, cost: Number(sched.cost) || 0, valid_months: Number(sched.valid_months) || null }).select('id').single() as any)).id;
        await rpc('schedule_training_requests', { p_ids: selected.map(r => r.id), p_training: tid });
        setSched(null); setTicked(new Set()); reload();
      }, 'Scheduled and enrolled')}>
      <p style={{ margin: 0 }}>{selected.map(r => name(r.employee_id)).join(', ')}</p>
      <Select label="Session" id="sc-sess" value={sched.training_id} onChange={v => setSched({ ...sched, training_id: v })}
        options={[['new', 'A new session'], ...data.sessions.filter(s => ['planned', 'in_progress'].includes(s.status)).map(s => [s.id, `${s.title}${s.start_date ? ' · ' + s.start_date : ''}`] as [string, string])]} />
      {sched.training_id === 'new' && <><Field label="Title" id="sc-title" value={sched.title} onChange={v => setSched({ ...sched, title: v })} required />
        <div className="grid-form">
          <Select label="Type" id="sc-kind" value={sched.kind} onChange={v => setSched({ ...sched, kind: v })} options={KINDS} />
          <Field label="Provider" id="sc-prov" value={sched.provider} onChange={v => setSched({ ...sched, provider: v })} />
          <Field label="Start" id="sc-start" type="date" value={sched.start_date} onChange={v => setSched({ ...sched, start_date: v })} />
          <Field label="End" id="sc-end" type="date" value={sched.end_date} onChange={v => setSched({ ...sched, end_date: v })} />
          <Field label="Hours" id="sc-hrs" type="number" step="0.5" min="0" value={sched.hours} onChange={v => setSched({ ...sched, hours: v })} />
          <Field label="Total cost (GH₵)" id="sc-cost" type="number" step="0.01" min="0" value={sched.cost} onChange={v => setSched({ ...sched, cost: v })} />
          <Field label="Certificate valid for (months)" id="sc-valid" type="number" step="1" min="1" value={sched.valid_months} onChange={v => setSched({ ...sched, valid_months: v })} />
        </div></>}
    </FormModal>}

    {sess && <FormModal title={sess.id ? 'Edit session' : 'New training session'} busy={act.busy} onClose={() => setSess(null)}
      danger={sess.id && <ConfirmButton className="btn danger" label="Delete" confirm="Delete this session and its attendance records?" onConfirm={() => act.run(async () => { await q(supabase.from('trainings').delete().eq('id', sess.id) as any); setSess(null); setOpen(null); reload(); })} />}
      onSave={() => act.run(async () => {
        const row = { title: sess.title, kind: sess.kind, provider: sess.provider || null, start_date: sess.start_date || null, end_date: sess.end_date || null, location: sess.location || null,
          hours: sess.hours === '' ? null : Number(sess.hours), cost: Number(sess.cost) || 0, valid_months: Number(sess.valid_months) || null, status: sess.status, notes: sess.notes || null };
        if (sess.id) await q(supabase.from('trainings').update(row).eq('id', sess.id) as any);
        else { const r = await q<any>(supabase.from('trainings').insert({ ...row, company_id: cid }).select('id').single() as any); setOpen(r.id); setTab('sessions'); }
        setSess(null); reload();
      }, 'Session saved')}>
      <Field label="Title" id="ss-title" value={sess.title} onChange={v => setSess({ ...sess, title: v })} placeholder="e.g. Fire safety and first aid, December" required />
      <div className="grid-form">
        <Select label="Type" id="ss-kind" value={sess.kind} onChange={v => setSess({ ...sess, kind: v })} options={KINDS} />
        <Field label="Provider or trainer" id="ss-prov" value={sess.provider} onChange={v => setSess({ ...sess, provider: v })} />
        <Field label="Start" id="ss-start" type="date" value={sess.start_date} onChange={v => setSess({ ...sess, start_date: v })} />
        <Field label="End" id="ss-end" type="date" value={sess.end_date} onChange={v => setSess({ ...sess, end_date: v })} />
        <Field label="Location" id="ss-loc" value={sess.location} onChange={v => setSess({ ...sess, location: v })} />
        <Field label="Hours" id="ss-hrs" type="number" step="0.5" min="0" value={sess.hours} onChange={v => setSess({ ...sess, hours: v })} />
        <Field label="Total cost (GH₵, excl. VAT)" id="ss-cost" type="number" step="0.01" min="0" value={sess.cost} onChange={v => setSess({ ...sess, cost: v })} />
        <Field label="Certificate valid for (months)" id="ss-valid" type="number" step="1" min="1" value={sess.valid_months} onChange={v => setSess({ ...sess, valid_months: v })} />
        <Select label="Status" id="ss-status" value={sess.status} onChange={v => setSess({ ...sess, status: v })} options={SESSION_STATUS} />
      </div>
      <Field label="Notes" id="ss-notes" type="textarea" value={sess.notes} onChange={v => setSess({ ...sess, notes: v })} />
    </FormModal>}

    {openSession && !sess && <SessionPanel s={openSession} staff={data.staff} suppliers={data.suppliers} name={name} busy={act.busy} onClose={() => setOpen(null)}
      onEdit={() => setSess(Object.fromEntries(Object.entries(openSession).filter(([kk]) => kk !== 'attendees').map(([kk, v]) => [kk, v ?? ''])))}
      onAdd={(ids: string[]) => act.run(async () => { await q(supabase.from('training_attendees').insert(ids.map(e => ({ training_id: openSession.id, employee_id: e, company_id: cid }))) as any); reload(); }, 'Added')}
      onRemove={(a: any) => act.run(async () => { await q(supabase.from('training_attendees').delete().eq('id', a.id) as any); reload(); })}
      onSaveAttendee={saveAttendee}
      onComplete={() => act.run(async () => { await q(supabase.from('trainings').update({ status: 'completed' }).eq('id', openSession.id) as any); reload(); }, 'Session completed; requests on it are completed')}
      onBill={(supplier: string) => act.run(async () => { const id = await rpc<string>('bill_training', { p_training: openSession.id, p_supplier: supplier, p_date: openSession.end_date || openSession.start_date || today() }); nav(`/bills/${id}/edit`); }, 'Draft bill created for the accountant to post')}
      onPdf={() => tablePdf({ company: company!, title: `Attendance: ${openSession.title}`, subtitle: [openSession.provider, openSession.start_date && longDate(openSession.start_date)].filter(Boolean).join(' · '),
        head: ['Employee', 'Result', 'Score', 'Certificate', 'Expires', 'Signature'], body: openSession.attendees.map((a: any) => [name(a.employee_id), a.status, a.score != null ? String(Number(a.score)) : '', a.certificate_no || '', a.expires_on || '', '']),
        filename: `attendance-${openSession.title}` })} />}
  </>;
}

function SessionPanel({ s, staff, suppliers, name, busy, onClose, onEdit, onAdd, onRemove, onSaveAttendee, onComplete, onBill, onPdf }: any) {
  const [pick, setPick] = useState<string[]>([]);
  const [supplier, setSupplier] = useState(suppliers[0]?.id || '');
  const avail = staff.filter((e: any) => !s.attendees.some((a: any) => a.employee_id === e.id));
  return <FormModal title={s.title} submit="Close" busy={busy} onClose={onClose} onSave={onClose}
    danger={<span className="actions"><button className="btn" type="button" onClick={onEdit}>Edit session</button><button className="btn" type="button" onClick={onPdf}>Attendance PDF</button></span>}>
    <p className="muted" style={{ margin: 0 }}>{kindName(s.kind)}{s.provider ? ' · ' + s.provider : ''}{s.start_date ? ' · ' + s.start_date : ''}{s.end_date && s.end_date !== s.start_date ? ' → ' + s.end_date : ''}
      {s.hours ? ` · ${Number(s.hours)} h` : ''} · {cedis(s.cost)}{s.valid_months ? ` · certificate valid ${s.valid_months} months` : ''} · <b>{SESSION_STATUS.find(x => x[0] === s.status)?.[1]}</b></p>
    {s.attendees.length ? <div className="scroll"><table className="lines">
      <thead><tr><th>Attendee</th><th>Result</th><th className="r">Score %</th><th>Certificate no.</th><th>Expires</th><th></th></tr></thead>
      <tbody>{s.attendees.map((a: any) => <tr key={a.id}>
        <td>{name(a.employee_id)}</td>
        <td><select aria-label="Result" style={{ minWidth: 110 }} value={a.status} onChange={e => onSaveAttendee(a, { status: e.target.value })}>{RESULT.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select></td>
        <td><input aria-label="Score" type="number" min="0" max="100" step="1" defaultValue={a.score ?? ''} style={{ width: 70, textAlign: 'right' }} onBlur={e => e.target.value !== String(a.score ?? '') && onSaveAttendee(a, { score: e.target.value === '' ? null : Number(e.target.value) })} /></td>
        <td><input aria-label="Certificate number" defaultValue={a.certificate_no || ''} style={{ width: 120 }} onBlur={e => e.target.value !== (a.certificate_no || '') && onSaveAttendee(a, { certificate_no: e.target.value || null })} /></td>
        <td className="num">{a.expires_on || ''}</td>
        <td><button className="btn small ghost" type="button" onClick={() => onRemove(a)}>Remove</button></td></tr>)}</tbody>
    </table></div> : <Empty>No attendees yet.</Empty>}
    {avail.length > 0 && <div className="actions">
      <select aria-label="Add attendees" multiple value={pick} onChange={e => setPick(Array.from(e.target.selectedOptions).map(o => o.value))} style={{ minWidth: 240, minHeight: 90 }}>
        {avail.map((e: any) => <option key={e.id} value={e.id}>{e.full_name}{e.department ? ' · ' + e.department : ''}</option>)}</select>
      <button className="btn small" type="button" disabled={!pick.length} onClick={() => { onAdd(pick); setPick([]); }}>Add {pick.length || ''} attendee{pick.length === 1 ? '' : 's'}</button>
    </div>}
    <div className="actions">
      {s.status !== 'completed' && s.status !== 'cancelled' && <button className="btn primary" type="button" onClick={onComplete}>Mark session completed</button>}
      {Number(s.cost) > 0 && !s.bill_id && suppliers.length > 0 && <><select aria-label="Provider as supplier" value={supplier} onChange={e => setSupplier(e.target.value)}>
        {suppliers.map((x: any) => <option key={x.id} value={x.id}>{x.name}</option>)}</select>
        <button className="btn" type="button" onClick={() => onBill(supplier)}>Create bill for {cedis(s.cost)}</button></>}
      {s.bill_id && <span className="pill good">Cost billed to 6450 Staff training</span>}
    </div>
    <p className="muted" style={{ margin: 0, fontSize: 13 }}>Marking an attendee Passed records the certificate date and, if the session has a validity period, its expiry. Completing the session marks enrolled people as attended.</p>
  </FormModal>;
}
