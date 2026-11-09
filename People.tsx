import { useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { q, rpc, supabase } from '../lib/supabase';
import { useSession, type Company } from '../lib/session';
import { longDate, money, monthName, today } from '../lib/format';
import { downloadCsv } from '../lib/download';
import { payslipPdf, tablePdf } from '../lib/pdf';
import { uploadDocFile } from '../components/ProjectDocs';
import { ConfirmButton, Empty, Field, FormModal, Loading, PageHead, Panel, Select, useAction, useLoad } from '../components/ui';
import { EmployeeEditor, toEditable } from './HR';

const EMP_TYPES: Record<string, string> = { permanent: 'Permanent', fixed_term: 'Fixed-term contract', contract: 'Contract (project)', casual: 'Casual', intern: 'Intern', national_service: 'National service', consultant: 'Consultant' };
const EVENT_KINDS: [string, string][] = [['note', 'Note'], ['confirmation', 'Confirmed in post'], ['warning', 'Warning'], ['disciplinary', 'Disciplinary action'], ['grievance', 'Grievance'], ['award', 'Award or commendation'], ['training', 'Training completed']];
const EVENT_LABEL: Record<string, string> = { hired: 'Joined', confirmation: 'Confirmed', promotion: 'Promotion', transfer: 'Transfer', title_change: 'Title change', salary_change: 'Pay change', warning: 'Warning', disciplinary: 'Disciplinary', grievance: 'Grievance', award: 'Award', training: 'Training', exit: 'Leaving', note: 'Note' };
const DOC_KINDS: [string, string][] = [['contract', 'Employment contract'], ['offer_letter', 'Offer letter'], ['id_card', 'ID (Ghana Card, passport)'], ['certificate', 'Certificate or qualification'], ['cv', 'CV'], ['medical', 'Medical certificate'], ['warning_letter', 'Warning letter'], ['appraisal', 'Appraisal'], ['exit', 'Exit document'], ['other', 'Other']];
const EXIT_REASONS: [string, string][] = [['resignation', 'Resignation'], ['end_of_contract', 'End of contract'], ['dismissal', 'Dismissal'], ['redundancy', 'Redundancy'], ['retirement', 'Retirement'], ['mutual', 'Mutual agreement'], ['death', 'Death'], ['other', 'Other']];
const OWNERS: Record<string, string> = { hr: 'HR', manager: 'Manager', it: 'IT', finance: 'Finance', store: 'Stores', hse: 'HSE', employee: 'Employee' };
const label = (list: [string, string][], v: string) => list.find(x => x[0] === v)?.[1] || v;
const openFile = async (path: string) => { const { data, error } = await supabase.storage.from('project-docs').createSignedUrl(path, 600); if (error) throw error; window.open(data.signedUrl, '_blank', 'noopener'); };

// ---------------------------------------------------------------- Employee profile
export function EmployeeProfilePage() {
  const { id } = useParams();
  const { cid, can, company } = useSession();
  const nav = useNavigate();
  const act = useAction();
  const hr = can('hr');
  const [tab, setTab] = useState<'overview' | 'pay' | 'history' | 'documents' | 'tasks'>('overview');
  const [edit, setEdit] = useState<any | null>(null);
  const [payChange, setPayChange] = useState<any | null>(null);
  const [payItem, setPayItem] = useState<any | null>(null);
  const [event, setEvent] = useState<any | null>(null);
  const [doc, setDoc] = useState<any | null>(null);
  const [exit, setExit] = useState<any | null>(null);
  const { data, error, loading, reload } = useLoad(async () => {
    const e = await q<any>(supabase.from('employees').select('*').eq('id', id).single() as any);
    const [mgr, reports, changes, items, comps, events, docs, tasks, exits, requests, balances, clearance] = await Promise.all([
      e.manager_id ? q<any>(supabase.from('employees').select('id,full_name,job_title').eq('id', e.manager_id).single() as any).catch(() => null) : Promise.resolve(null),
      q<any[]>(supabase.from('employees').select('id,full_name,job_title').eq('manager_id', id).eq('status', 'active').order('full_name') as any).catch(() => [] as any[]),
      q<any[]>(supabase.from('salary_changes').select('*').eq('employee_id', id).order('effective_date', { ascending: false }) as any).catch(() => [] as any[]),
      q<any[]>(supabase.from('employee_pay_items').select('*, comp:pay_components(name,kind,taxable)').eq('employee_id', id).order('start_period', { ascending: false }) as any).catch(() => [] as any[]),
      q<any[]>(supabase.from('pay_components').select('*').eq('company_id', cid).eq('active', true).order('sort') as any).catch(() => [] as any[]),
      q<any[]>(supabase.from('employee_events').select('*').eq('employee_id', id).order('effective_date', { ascending: false }).order('created_at', { ascending: false }) as any).catch(() => [] as any[]),
      q<any[]>(supabase.from('employee_documents').select('*').eq('employee_id', id).order('created_at', { ascending: false }) as any).catch(() => [] as any[]),
      q<any[]>(supabase.from('employee_tasks').select('*').eq('employee_id', id).order('kind').order('sort') as any).catch(() => [] as any[]),
      q<any[]>(supabase.from('employee_exits').select('*').eq('employee_id', id).order('created_at', { ascending: false }) as any).catch(() => [] as any[]),
      q<any[]>(supabase.from('employee_change_requests').select('*').eq('employee_id', id).order('created_at', { ascending: false }) as any).catch(() => [] as any[]),
      rpc<any[]>('leave_balances', { cid, p_year: Number(today().slice(0, 4)) }).then(b => b.filter(x => x.employee_id === id && x.entitlement != null)).catch(() => [] as any[]),
      hr ? rpc<any>('exit_clearance', { p_employee: id }).catch(() => null) : Promise.resolve(null),
    ]);
    return { e, mgr, reports, changes, items, comps, events, docs, tasks, exits, requests, balances, clearance };
  }, [id, cid]);
  if (!data) return <Loading error={error} loading={loading} />;
  const { e } = data;
  const exitOpen = data.exits.find(x => x.status === 'in_progress');
  const pending = data.requests.filter(r => r.status === 'pending');
  const today0 = today();
  const flags = [
    e.probation_end && !e.confirmed_on && e.probation_end >= today0 ? `On probation until ${longDate(e.probation_end)}` : null,
    e.probation_end && !e.confirmed_on && e.probation_end < today0 ? `Probation ended ${longDate(e.probation_end)}: confirm or extend` : null,
    e.contract_end ? `Contract ends ${longDate(e.contract_end)}` : null,
    exitOpen ? `Leaving on ${longDate(exitOpen.last_day)}` : null,
  ].filter(Boolean);
  const certificate = () => tablePdf({ company: company!, title: 'Certificate of service', subtitle: longDate(today()), head: ['', ''], filename: `certificate-of-service-${e.full_name}`,
    body: [['Name', e.full_name], ['Staff no.', e.staff_no || '—'], ['Position', e.job_title || '—'], ['Department', e.department || '—'], ['Employed from', e.hire_date ? longDate(e.hire_date) : '—'],
      ['Employed to', e.end_date ? longDate(e.end_date) : 'Still employed'], ['Type of employment', EMP_TYPES[e.employment_type] || e.employment_type]],
    notes: 'This is to certify that the above-named person was employed by the company for the period stated. Signed for the company: ____________________' });
  return <>
    <PageHead title={e.full_name} sub={<>{[e.job_title, e.department, EMP_TYPES[e.employment_type]].filter(Boolean).join(' · ')}{e.staff_no ? ' · ' + e.staff_no : ''} {e.status === 'active' ? <span className="pill good">Active</span> : <span className="pill">Left {e.end_date ? longDate(e.end_date) : ''}</span>}</>}>
      <Link className="btn" to="/employees">Back</Link>
      {hr && <button className="btn" type="button" onClick={() => setEdit(toEditable(e))}>Edit details</button>}
      {hr && e.status === 'active' && !exitOpen && <button className="btn" type="button" onClick={() => setExit({ reason: 'resignation', notice: today(), last_day: today(), note: '' })}>Start exit</button>}
      {hr && <button className="btn" type="button" onClick={certificate}>Certificate of service</button>}
    </PageHead>
    {flags.length > 0 && <div className="note" style={{ background: 'var(--warn-soft)', marginBottom: 12 }}>{flags.join(' · ')}</div>}
    {pending.length > 0 && hr && <Panel title="Details update requested" pad>{pending.map(r => <div key={r.id} className="actions" style={{ justifyContent: 'space-between' }}>
      <span>{Object.entries(r.changes).map(([k, v]) => `${k.replace(/_/g, ' ')}: ${v}`).join(' · ')}{r.note ? ` (${r.note})` : ''}</span>
      <span className="actions"><button className="btn small primary" type="button" onClick={() => act.run(async () => { await rpc('decide_profile_change', { p_id: r.id, p_approve: true }); reload(); }, 'Approved and applied')}>Approve</button>
        <button className="btn small" type="button" onClick={() => act.run(async () => { await rpc('decide_profile_change', { p_id: r.id, p_approve: false }); reload(); }, 'Declined')}>Decline</button></span></div>)}</Panel>}
    <div className="actions" style={{ marginBottom: 12 }}>{([['overview', 'Overview'], ['pay', 'Pay'], ['history', 'History'], ['documents', 'Documents'], ['tasks', 'Onboarding and exit']] as const).map(([k, l]) =>
      <button key={k} type="button" className={'btn small' + (tab === k ? ' primary' : '')} onClick={() => setTab(k)}>{l}</button>)}</div>

    {tab === 'overview' && <div className="grid-2">
      <Panel title="Employment" pad><dl className="kv">
        <dt>Joined</dt><dd>{e.hire_date ? longDate(e.hire_date) : '—'}</dd>
        <dt>Reports to</dt><dd>{data.mgr ? <Link to={'/employees/' + data.mgr.id}>{data.mgr.full_name}</Link> : '—'}</dd>
        <dt>Grade</dt><dd>{e.grade || '—'}</dd>
        <dt>Probation</dt><dd>{e.confirmed_on ? `Confirmed ${longDate(e.confirmed_on)}` : e.probation_end ? `Until ${longDate(e.probation_end)}` : '—'}</dd>
        <dt>Contract ends</dt><dd>{e.contract_end ? longDate(e.contract_end) : '—'}</dd>
        <dt>Notice</dt><dd>{e.notice_days ? `${e.notice_days} days` : '—'}</dd>
        <dt>Team</dt><dd>{data.reports.length ? data.reports.map((r: any) => <span key={r.id}><Link to={'/employees/' + r.id}>{r.full_name}</Link>{' '}</span>) : '—'}</dd>
      </dl></Panel>
      <Panel title="Contact and personal" pad><dl className="kv">
        <dt>Phone</dt><dd>{e.phone || '—'}</dd><dt>Email</dt><dd>{e.email || '—'}</dd><dt>Address</dt><dd>{e.address || '—'}</dd>
        <dt>Date of birth</dt><dd>{e.date_of_birth ? longDate(e.date_of_birth) : '—'}</dd>
        <dt>Next of kin</dt><dd>{[e.next_of_kin_name, e.next_of_kin_relation, e.next_of_kin_phone].filter(Boolean).join(' · ') || '—'}</dd>
        <dt>Emergency</dt><dd>{e.emergency_phone || '—'}</dd>
        <dt>IDs</dt><dd>{[e.ghana_card && 'Ghana Card ' + e.ghana_card, e.ssnit_no && 'SSNIT ' + e.ssnit_no, e.tin && 'TIN ' + e.tin].filter(Boolean).join(' · ') || '—'}</dd>
        <dt>Paid by</dt><dd>{e.pay_method === 'momo' ? `MoMo ${e.momo_number || ''}` : e.pay_method === 'cash' ? 'Cash' : [e.bank_name, e.bank_branch, e.bank_account].filter(Boolean).join(' · ') || '—'}</dd>
      </dl></Panel>
      <Panel title={`Leave ${today().slice(0, 4)}`}>{data.balances.length ? <table><tbody>{data.balances.map((b: any) => <tr key={b.leave_code}><td>{b.leave_name}</td><td className="r num">{b.remaining} of {b.entitlement} days left{Number(b.carried) ? ` (${b.carried} carried)` : ''}</td></tr>)}</tbody></table> : <Empty>No leave limits set.</Empty>}</Panel>
    </div>}

    {tab === 'pay' && <>
      <Panel title="Salary" actions={hr && <button className="btn small primary" type="button" onClick={() => setPayChange({ effective: today(), basic: String(e.basic_salary), allowances: String(e.allowances), kind: 'increase', reason: '', title: '', grade: '' })}>Change pay or promote</button>}>
        <div className="tiles" style={{ padding: 12 }}>
          <div className="tile"><span>Basic per month</span><b>{money(e.basic_salary)}</b></div>
          <div className="tile"><span>Allowances (taxed)</span><b>{money(e.allowances)}</b></div>
          <div className="tile"><span>Other regular pay</span><b>{money(data.items.filter((i: any) => i.comp?.kind === 'earning' && !i.end_period).reduce((a: number, i: any) => a + Number(i.amount), 0))}</b></div>
        </div>
        {data.changes.length ? <table><thead><tr><th>From</th><th>Change</th><th className="r">Basic</th><th className="r">Allowances</th><th>Reason</th><th>Back pay</th></tr></thead>
          <tbody>{data.changes.map((c: any) => <tr key={c.id}><td className="num">{longDate(c.effective_date)}{c.effective_date > today() && <span className="pill warn" style={{ marginLeft: 6 }}>Scheduled</span>}</td><td>{c.kind}</td>
            <td className="r num">{money(c.basic_salary)}</td><td className="r num">{money(c.allowances)}</td><td>{c.reason}</td><td className="muted">{c.arrears_run_id ? 'Settled' : c.effective_date < today().slice(0, 8) + '01' ? 'Paid in the next payroll' : ''}</td></tr>)}</tbody></table>
          : <div className="body muted" style={{ fontSize: 13 }}>No pay changes recorded yet. A change with a past date is paid as back pay in the next regular payroll.</div>}
      </Panel>
      <Panel title="Regular allowances and deductions" actions={can('hr', 'accountant') && <button className="btn small primary" type="button" onClick={() => setPayItem({ component_id: data.comps[0]?.id || '', amount: '', start: today().slice(0, 7), end: '', note: '' })}>Add</button>}>
        {data.items.length ? <table><tbody>{data.items.map((i: any) => <tr key={i.id}><td>{i.comp?.name}{i.comp?.kind === 'deduction' ? <span className="pill" style={{ marginLeft: 6 }}>Deduction</span> : !i.comp?.taxable ? <span className="pill" style={{ marginLeft: 6 }}>Not taxed</span> : null}</td>
          <td className="r num">{money(i.amount)} / month</td><td className="muted">{monthName(i.start_period)} → {i.end_period ? monthName(i.end_period) : 'ongoing'}</td><td className="muted">{i.note}</td>
          <td className="r">{can('hr', 'accountant') && !i.end_period && <button className="btn small ghost" type="button" onClick={() => act.run(async () => { await q(supabase.from('employee_pay_items').update({ end_period: today().slice(0, 8) + '01' }).eq('id', i.id) as any); reload(); }, 'Ends this month')}>End</button>}</td></tr>)}</tbody></table>
          : <Empty>Add housing, transport, fuel or other allowances, and union dues, welfare or other deductions, paid every month.</Empty>}
      </Panel>
    </>}

    {tab === 'history' && <Panel title="Employment history" actions={hr && <button className="btn small primary" type="button" onClick={() => setEvent({ kind: 'note', date: today(), title: '', details: '', confidential: false })}>Add</button>}>
      {data.events.length ? <table><tbody>{data.events.map((h: any) => <tr key={h.id}><td className="num" style={{ whiteSpace: 'nowrap' }}>{longDate(h.effective_date)}</td>
        <td><span className={'pill ' + (['warning', 'disciplinary'].includes(h.kind) ? 'bad' : ['promotion', 'award', 'confirmation'].includes(h.kind) ? 'good' : '')}>{EVENT_LABEL[h.kind] || h.kind}</span></td>
        <td><b>{h.title}</b>{h.details && <div className="muted" style={{ fontSize: 13 }}>{h.details}</div>}</td><td className="muted">{(h.created_email || '').split('@')[0]}{h.confidential ? ' · confidential' : ''}</td></tr>)}</tbody></table>
        : <Empty>Nothing recorded yet.</Empty>}
    </Panel>}

    {tab === 'documents' && <Panel title="Documents" actions={hr && <button className="btn small primary" type="button" onClick={() => setDoc({ kind: 'contract', title: '', expires_on: '', visible: true, file: null })}>Upload</button>}>
      {data.docs.length ? <table><tbody>{data.docs.map((d: any) => <tr key={d.id}><td><button type="button" className="btn small ghost" onClick={() => act.run(() => openFile(d.storage_path))}>{d.title}</button></td><td>{label(DOC_KINDS, d.kind)}</td>
        <td className="num" style={{ color: d.expires_on && d.expires_on < today() ? 'var(--bad)' : undefined }}>{d.expires_on ? 'Expires ' + longDate(d.expires_on) : ''}</td><td className="muted">{d.visible_to_employee ? 'Employee can see' : 'HR only'}</td>
        <td className="r">{hr && <ConfirmButton className="btn small ghost" label="Delete" confirm="Delete this document?" onConfirm={() => act.run(async () => { await q(supabase.from('employee_documents').delete().eq('id', d.id) as any); reload(); })} />}</td></tr>)}</tbody></table>
        : <Empty>Upload the contract, offer letter, ID copies, certificates and letters. Expiring documents remind HR 30 days before.</Empty>}
    </Panel>}

    {tab === 'tasks' && <>
      {exitOpen && data.clearance && <Panel title={`Leaving on ${longDate(exitOpen.last_day)} · ${label(EXIT_REASONS, exitOpen.reason)}`} actions={hr && <>
        <ConfirmButton className="btn small primary" label="Complete exit" confirm="Make inactive from the last day and remove their sign-in?" onConfirm={() => act.run(async () => { await rpc('complete_exit', { p_exit: exitOpen.id, p_force: false }); reload(); }, 'Exit completed')} />
        <ConfirmButton className="btn small" label="Complete anyway" confirm="Some tasks are still open. Complete the exit anyway?" onConfirm={() => act.run(async () => { await rpc('complete_exit', { p_exit: exitOpen.id, p_force: true }); reload(); }, 'Exit completed')} /></>}>
        <div className="tiles" style={{ padding: 12 }}>
          <div className="tile"><span>Assets still held</span><b style={{ color: data.clearance.assets.length ? 'var(--bad)' : undefined }}>{data.clearance.assets.length}</b><span>{data.clearance.assets.map((a: any) => a.tag).join(', ') || 'none'}</span></div>
          <div className="tile"><span>Staff loan balance</span><b>{money(data.clearance.loans)}</b><span>deduct from final pay</span></div>
          <div className="tile"><span>Cash advances open</span><b>{money(data.clearance.advances)}</b><span>retire or recover</span></div>
          <div className="tile"><span>Leave days due</span><b>{exitOpen.leave_days_due ?? 0}</b><span>≈ {money(Number(exitOpen.leave_days_due || 0) * Number(data.clearance.daily_rate))} at {money(data.clearance.daily_rate)} a day (basic ÷ 22)</span></div>
        </div>
        <div className="body muted" style={{ fontSize: 13 }}>Final pay: the regular payroll pays salary to the last day automatically. Add leave pay (item "Leave pay") in that month's payroll, or create an off-cycle "Final pay" run to pay earlier.</div>
      </Panel>}
      <Panel title="Onboarding and exit tasks" actions={hr && <>
        {!data.tasks.some((t: any) => t.kind === 'onboarding') && <button className="btn small primary" type="button" onClick={() => act.run(async () => { await rpc('start_hr_checklist', { p_employee: e.id, p_kind: 'onboarding' }); reload(); }, 'Onboarding checklist started')}>Start onboarding checklist</button>}</>}>
        {data.tasks.length ? <TaskTable rows={data.tasks} onChange={reload} /> : <Empty>No checklist yet. Start onboarding for a new joiner; starting an exit creates the leaving checklist.</Empty>}
      </Panel>
      {data.exits.filter((x: any) => x.status !== 'in_progress').map((x: any) => <div key={x.id} className="note">Left {longDate(x.last_day)} · {label(EXIT_REASONS, x.reason)}{x.interview_notes ? ' · ' + x.interview_notes : ''}</div>)}
    </>}

    {edit && <EmployeeEditor initial={edit} onClose={() => setEdit(null)} onSaved={() => { setEdit(null); reload(); }} />}
    {payChange && <FormModal title="Change pay or promote" busy={act.busy} onClose={() => setPayChange(null)} onSave={() => act.run(async () => {
      await rpc('change_salary', { p_employee: e.id, p_effective: payChange.effective, p_basic: Number(payChange.basic), p_allowances: Number(payChange.allowances) || 0, p_reason: payChange.reason || null,
        p_kind: payChange.kind, p_title: payChange.title || null, p_grade: payChange.grade || null }); setPayChange(null); reload(); }, 'Saved. A past date is paid as back pay in the next regular payroll.')}>
      <div className="grid-form">
        <Select label="What" id="pc-kind" value={payChange.kind} onChange={v => setPayChange({ ...payChange, kind: v })} options={[['increase', 'Pay increase'], ['promotion', 'Promotion'], ['adjustment', 'Correction'], ['decrease', 'Decrease']]} />
        <Field label="Effective from" id="pc-eff" type="date" value={payChange.effective} onChange={v => setPayChange({ ...payChange, effective: v })} required />
        <Field label="New basic per month (GH₵)" id="pc-basic" type="number" step="0.01" min="0" value={payChange.basic} onChange={v => setPayChange({ ...payChange, basic: v })} required />
        <Field label="New allowances per month (GH₵)" id="pc-allow" type="number" step="0.01" min="0" value={payChange.allowances} onChange={v => setPayChange({ ...payChange, allowances: v })} />
        {payChange.kind === 'promotion' && <Field label="New job title" id="pc-title" value={payChange.title} onChange={v => setPayChange({ ...payChange, title: v })} />}
        {payChange.kind === 'promotion' && <Field label="New grade" id="pc-grade" value={payChange.grade} onChange={v => setPayChange({ ...payChange, grade: v })} />}
      </div>
      <Field label="Reason" id="pc-reason" value={payChange.reason} onChange={v => setPayChange({ ...payChange, reason: v })} />
      {Number(payChange.basic) !== Number(e.basic_salary) && Number(e.basic_salary) > 0 && <p className="muted" style={{ margin: 0 }}>{Number(payChange.basic) > Number(e.basic_salary) ? '+' : ''}{(100 * (Number(payChange.basic) - Number(e.basic_salary)) / Number(e.basic_salary)).toFixed(1)}% on basic</p>}
    </FormModal>}
    {payItem && <FormModal title="Regular allowance or deduction" busy={act.busy} onClose={() => setPayItem(null)} onSave={() => act.run(async () => {
      await q(supabase.from('employee_pay_items').insert({ company_id: cid, employee_id: e.id, component_id: payItem.component_id, amount: Number(payItem.amount), start_period: payItem.start + '-01', end_period: payItem.end ? payItem.end + '-01' : null, note: payItem.note || null }) as any);
      setPayItem(null); reload(); }, 'Added')}>
      <div className="grid-form">
        <Select label="Item" id="pit-comp" value={payItem.component_id} onChange={v => setPayItem({ ...payItem, component_id: v })} options={data.comps.filter((c: any) => !c.system).map((c: any) => [c.id, `${c.name} (${c.kind === 'deduction' ? 'deduction' : c.taxable ? 'taxed' : 'not taxed'})`] as [string, string])} />
        <Field label="Amount per month (GH₵)" id="pit-amt" type="number" step="0.01" min="0.01" value={payItem.amount} onChange={v => setPayItem({ ...payItem, amount: v })} required />
        <Field label="From month" id="pit-start" type="month" value={payItem.start} onChange={v => setPayItem({ ...payItem, start: v })} required />
        <Field label="Until month (blank = ongoing)" id="pit-end" type="month" value={payItem.end} onChange={v => setPayItem({ ...payItem, end: v })} />
      </div>
      <Field label="Note" id="pit-note" value={payItem.note} onChange={v => setPayItem({ ...payItem, note: v })} />
    </FormModal>}
    {event && <FormModal title="Add to history" busy={act.busy} onClose={() => setEvent(null)} onSave={() => act.run(async () => {
      await q(supabase.from('employee_events').insert({ company_id: cid, employee_id: e.id, kind: event.kind, effective_date: event.date, title: event.title || label(EVENT_KINDS, event.kind), details: event.details || null, confidential: event.confidential }) as any);
      if (event.kind === 'confirmation') await q(supabase.from('employees').update({ confirmed_on: event.date }).eq('id', e.id) as any);
      setEvent(null); reload(); }, 'Added')}>
      <div className="grid-form">
        <Select label="What" id="ev-kind" value={event.kind} onChange={v => setEvent({ ...event, kind: v, confidential: ['warning', 'disciplinary', 'grievance'].includes(v) })} options={EVENT_KINDS} />
        <Field label="Date" id="ev-date" type="date" value={event.date} onChange={v => setEvent({ ...event, date: v })} />
      </div>
      <Field label="Title" id="ev-title" value={event.title} onChange={v => setEvent({ ...event, title: v })} placeholder={event.kind === 'warning' ? 'e.g. First written warning: lateness' : ''} />
      <Field label="Details" id="ev-details" type="textarea" value={event.details} onChange={v => setEvent({ ...event, details: v })} />
      <label className="check"><input type="checkbox" checked={event.confidential} onChange={ev => setEvent({ ...event, confidential: ev.target.checked })} /> Confidential (not shown to the employee)</label>
    </FormModal>}
    {doc && <FormModal title="Upload document" busy={act.busy} onClose={() => setDoc(null)} onSave={() => act.run(async () => {
      if (!doc.file) throw new Error('Choose a file');
      const f = await uploadDocFile(cid, 'hr/' + e.id, doc.file);
      await q(supabase.from('employee_documents').insert({ company_id: cid, employee_id: e.id, kind: doc.kind, title: doc.title || f.name, storage_path: f.path, file_name: f.name, expires_on: doc.expires_on || null, visible_to_employee: doc.visible }) as any);
      setDoc(null); reload(); }, 'Uploaded')}>
      <div className="grid-form">
        <Select label="Kind" id="dc-kind" value={doc.kind} onChange={v => setDoc({ ...doc, kind: v, visible: !['warning_letter', 'medical'].includes(v) })} options={DOC_KINDS} />
        <Field label="Title" id="dc-title" value={doc.title} onChange={v => setDoc({ ...doc, title: v })} />
        <Field label="Expires (if any)" id="dc-exp" type="date" value={doc.expires_on} onChange={v => setDoc({ ...doc, expires_on: v })} />
      </div>
      <div className="field"><label htmlFor="dc-file">File</label><input id="dc-file" type="file" onChange={ev => setDoc({ ...doc, file: ev.target.files?.[0] || null })} /></div>
      <label className="check"><input type="checkbox" checked={doc.visible} onChange={ev => setDoc({ ...doc, visible: ev.target.checked })} /> The employee can see it in My profile</label>
    </FormModal>}
    {exit && <FormModal title={`Start exit: ${e.full_name}`} submit="Start exit" busy={act.busy} onClose={() => setExit(null)} onSave={() => act.run(async () => {
      await rpc('start_exit', { p_employee: e.id, p_reason: exit.reason, p_notice: exit.notice, p_last_day: exit.last_day, p_note: exit.note || null }); setExit(null); setTab('tasks'); reload(); }, 'Exit started. HR, Finance and Stores have been told.')}>
      <div className="grid-form">
        <Select label="Reason" id="ex-reason" value={exit.reason} onChange={v => setExit({ ...exit, reason: v })} options={EXIT_REASONS} />
        <Field label="Notice given on" id="ex-notice" type="date" value={exit.notice} onChange={v => setExit({ ...exit, notice: v })} />
        <Field label="Last working day" id="ex-last" type="date" value={exit.last_day} onChange={v => setExit({ ...exit, last_day: v })} />
      </div>
      <Field label="Notes (exit interview, handover)" id="ex-note" type="textarea" value={exit.note} onChange={v => setExit({ ...exit, note: v })} />
      <p className="muted" style={{ margin: 0, fontSize: 13 }}>Creates the leaving checklist (assets back, advances and loans cleared, leave pay, final pay, access removed). They are paid to the last day in that month's payroll. Completing the exit makes them inactive and removes their sign-in.</p>
    </FormModal>}
  </>;
}

function TaskTable({ rows, onChange, showEmployee }: { rows: any[]; onChange: () => void; showEmployee?: (id: string) => string }) {
  const act = useAction();
  return <table><tbody>{rows.map(t => <tr key={t.id}>
    <td style={{ width: 28 }}><input type="checkbox" aria-label={t.task} checked={t.status !== 'open'} onChange={ev => act.run(async () => { await rpc('hr_task_step', { p_id: t.id, p_status: ev.target.checked ? 'done' : 'open' }); onChange(); })} /></td>
    <td style={{ textDecoration: t.status === 'na' ? 'line-through' : undefined }}>{t.task}{showEmployee && <div className="muted" style={{ fontSize: 12 }}>{showEmployee(t.employee_id)} · {t.kind === 'onboarding' ? 'joining' : 'leaving'}</div>}</td>
    <td><span className="pill">{OWNERS[t.owner] || t.owner}</span></td>
    <td className="num" style={{ color: t.status === 'open' && t.due_date && t.due_date < today() ? 'var(--bad)' : undefined }}>{t.due_date ? longDate(t.due_date) : ''}</td>
    <td className="r">{t.status === 'open' && <button className="btn small ghost" type="button" onClick={() => act.run(async () => { await rpc('hr_task_step', { p_id: t.id, p_status: 'na' }); onChange(); })}>Not needed</button>}</td></tr>)}</tbody></table>;
}

// ---------------------------------------------------------------- HR tasks for everyone who owns one
export function HrTasksPage() {
  const { cid } = useSession();
  const { data, error, loading, reload } = useLoad(async () => {
    const [tasks, staff] = await Promise.all([
      q<any[]>(supabase.from('employee_tasks').select('*').eq('company_id', cid).eq('status', 'open').order('due_date') as any),
      rpc<any[]>('staff_directory', { cid }).catch(() => [] as any[]),
    ]);
    return { tasks, staff };
  }, [cid]);
  const name = (id: string) => data?.staff.find(s => s.id === id)?.full_name || 'Former employee';
  return <>
    <PageHead title="Joining and leaving tasks" sub="Open onboarding and exit tasks you can see: yours as a manager, HR, Finance, Stores, IT or HSE." />
    <Loading error={error} loading={loading && !data} />
    {data && <Panel>{data.tasks.length ? <TaskTable rows={data.tasks} onChange={reload} showEmployee={name} /> : <Empty>Nothing open.</Empty>}</Panel>}
  </>;
}

// ---------------------------------------------------------------- Pay components
export function PayComponentsPage() {
  const { cid, can } = useSession();
  const act = useAction();
  const [form, setForm] = useState<any | null>(null);
  const { data, error, loading, reload } = useLoad(async () => {
    const [comps, accts] = await Promise.all([
      q<any[]>(supabase.from('pay_components').select('*').eq('company_id', cid).order('kind').order('sort') as any),
      q<any[]>(supabase.from('accounts').select('id,code,name').eq('company_id', cid).eq('type', 'liability').order('code') as any).catch(() => [] as any[]),
    ]);
    return { comps, accts };
  }, [cid]);
  const edit = can('hr', 'accountant');
  return <>
    <PageHead title="Pay components" sub="Allowances, other earnings and deductions used on payslips. Earnings can be taxed or not; deductions are owed to the account you choose.">
      <Link className="btn" to="/payroll">Back</Link>
      {edit && <button className="btn primary" type="button" onClick={() => setForm({ code: '', name: '', kind: 'earning', taxable: true, account_id: '', active: true, sort: 100 })}>Add</button>}
    </PageHead>
    <Loading error={error} loading={loading && !data} />
    {data && <Panel><table><thead><tr><th>Name</th><th>Code</th><th>Type</th><th>Tax</th><th>Owed to</th><th></th></tr></thead>
      <tbody>{data.comps.map(c => <tr key={c.id} style={{ opacity: c.active ? 1 : 0.5 }}><td>{c.name}{c.system && <span className="pill" style={{ marginLeft: 6 }}>Built in</span>}</td><td className="num">{c.code}</td>
        <td>{c.kind === 'earning' ? 'Earning' : 'Deduction'}</td><td>{c.kind === 'earning' ? (c.taxable ? 'Taxed (PAYE)' : 'Not taxed') : 'After tax'}</td>
        <td>{c.kind === 'deduction' ? (data.accts.find(a => a.id === c.account_id) ? `${data.accts.find(a => a.id === c.account_id)!.code} ${data.accts.find(a => a.id === c.account_id)!.name}` : '2260 Other payroll deductions payable') : ''}</td>
        <td className="r">{edit && !c.system && <button className="btn small ghost" type="button" onClick={() => setForm({ ...c, account_id: c.account_id || '' })}>Edit</button>}</td></tr>)}</tbody></table>
      <div className="body muted" style={{ fontSize: 13 }}>Ghana taxes most cash allowances as employment income; mark an earning "not taxed" only for genuine reimbursements of business costs. SSNIT is always on basic salary. Bonus and back pay are built in: bonus gets the 5% bonus tax up to 15% of annual basic.</div></Panel>}
    {form && <FormModal title={form.id ? 'Edit pay component' : 'Add pay component'} busy={act.busy} onClose={() => setForm(null)} onSave={() => act.run(async () => {
      const row = { code: form.code.toUpperCase().replace(/[^A-Z0-9]/g, ''), name: form.name, kind: form.kind, taxable: form.kind === 'earning' ? form.taxable : false, account_id: form.kind === 'deduction' ? form.account_id || null : null, active: form.active, sort: Number(form.sort) || 100 };
      if (!row.code) throw new Error('Give it a short code, e.g. MEAL');
      if (form.id) await q(supabase.from('pay_components').update(row).eq('id', form.id) as any); else await q(supabase.from('pay_components').insert({ ...row, company_id: cid }) as any);
      setForm(null); reload(); }, 'Saved')}>
      <div className="grid-form">
        <Field label="Name" id="pcm-name" value={form.name} onChange={v => setForm({ ...form, name: v })} required />
        <Field label="Code" id="pcm-code" value={form.code} onChange={v => setForm({ ...form, code: v })} placeholder="e.g. MEAL" required />
        <Select label="Type" id="pcm-kind" value={form.kind} onChange={v => setForm({ ...form, kind: v })} options={[['earning', 'Earning'], ['deduction', 'Deduction']]} />
        {form.kind === 'deduction' && <Select label="Owed to (account)" id="pcm-acct" value={form.account_id} onChange={v => setForm({ ...form, account_id: v })} options={[['', '2260 Other payroll deductions payable'], ...data!.accts.map(a => [a.id, `${a.code} ${a.name}`] as [string, string])]} />}
      </div>
      {form.kind === 'earning' && <label className="check"><input type="checkbox" checked={form.taxable} onChange={e => setForm({ ...form, taxable: e.target.checked })} /> Taxed through PAYE</label>}
      <label className="check"><input type="checkbox" checked={form.active} onChange={e => setForm({ ...form, active: e.target.checked })} /> In use</label>
    </FormModal>}
  </>;
}

// ---------------------------------------------------------------- Self-service: payslips and profile
export function MyPayslipsPage() {
  const { cid } = useSession();
  const [year, setYear] = useState(Number(today().slice(0, 4)));
  const { data, error, loading } = useLoad(() => rpc<any[]>('my_payslips', { p_year: year, p_company: cid }), [year, cid]);
  const slips = data || [];
  const sum = (k: string) => slips.reduce((a, s) => a + Number(s.slip[k] || 0), 0);
  const pdf = (s: any) => payslipPdf(s.company as Company, s.period, { ...s.slip, items: s.items, run_kind: s.kind }, s.employee);
  const certificate = () => slips.length && tablePdf({ company: slips[0].company as Company, title: `Statement of earnings and tax ${year}`, subtitle: `${slips[0].employee.full_name}${slips[0].employee.tin ? ' · TIN ' + slips[0].employee.tin : ''}${slips[0].employee.ghana_card ? ' · ' + slips[0].employee.ghana_card : ''}`,
    head: ['Month', 'Gross', 'SSNIT', 'Chargeable', 'PAYE and final taxes', 'Net (GHS)'], rightAlign: [1, 2, 3, 4, 5], filename: `earnings-and-tax-${year}`,
    body: [...slips].reverse().map(s => [monthName(s.period) + (s.kind !== 'regular' ? ' (off-cycle)' : ''), money(s.slip.gross), money(s.slip.ssnit_employee), money(s.slip.chargeable), money(Number(s.slip.paye) + Number(s.slip.overtime_tax) + Number(s.slip.bonus_tax)), money(s.slip.net)]),
    foot: ['Total', money(sum('gross')), money(sum('ssnit_employee')), money(sum('chargeable')), money(sum('paye') + sum('overtime_tax') + sum('bonus_tax')), money(sum('net'))],
    notes: 'Taken from the payslips posted by your employer. PAYE was deducted and paid to the Ghana Revenue Authority by the employer.' });
  return <>
    <PageHead title="My payslips" sub="Your payslips and a yearly statement of earnings and tax.">
      <select aria-label="Year" value={year} onChange={e => setYear(Number(e.target.value))} style={{ width: 'auto' }}>{[0, 1, 2, 3].map(d => Number(today().slice(0, 4)) - d).map(y => <option key={y} value={y}>{y}</option>)}</select>
      <button className="btn" type="button" disabled={!slips.length} onClick={certificate}>Year statement (PDF)</button>
    </PageHead>
    <Loading error={error} loading={loading && !data} />
    {data && <>
      {slips.length > 0 && <div className="tiles" style={{ marginBottom: 12 }}>
        <div className="tile"><span>Gross pay {year}</span><b>{money(sum('gross'))}</b></div>
        <div className="tile"><span>Tax (PAYE and final taxes)</span><b>{money(sum('paye') + sum('overtime_tax') + sum('bonus_tax'))}</b></div>
        <div className="tile"><span>SSNIT</span><b>{money(sum('ssnit_employee'))}</b></div>
        <div className="tile"><span>Net pay</span><b>{money(sum('net'))}</b></div>
      </div>}
      <Panel>{slips.length ? <table><thead><tr><th>Month</th><th className="r">Gross</th><th className="r">Deductions</th><th className="r">Net pay</th><th></th></tr></thead>
        <tbody>{slips.map(s => <tr key={s.slip.id}><td>{monthName(s.period)}{s.kind !== 'regular' && <span className="pill" style={{ marginLeft: 6 }}>{s.kind === 'final' ? 'Final pay' : 'Off-cycle'}</span>}</td>
          <td className="r num">{money(s.slip.gross)}</td><td className="r num">{money(Number(s.slip.gross) - Number(s.slip.net))}</td><td className="r num"><b>{money(s.slip.net)}</b></td>
          <td className="r"><button className="btn small" type="button" onClick={() => pdf(s)}>Download</button></td></tr>)}</tbody></table>
        : <Empty>No payslips for {year}. Payslips appear here once payroll is posted. If you expected some, ask HR to link your login to your employee record.</Empty>}</Panel>
    </>}
  </>;
}

export function MyProfilePage() {
  const { cid } = useSession();
  const act = useAction();
  const [form, setForm] = useState<any | null>(null);
  const { data, error, loading, reload } = useLoad(() => rpc<any>('my_profile', { p_company: cid }), [cid]);
  if (loading && !data) return <Loading loading />;
  if (error) return <Loading error={error} />;
  if (!data) return <><PageHead title="My profile" /><Empty>Your login is not linked to an employee record yet. Ask HR to link it (Employees → you → Edit details → Sign-in email).</Empty></>;
  const e = data.employee;
  const fields: [string, string][] = [['phone', 'Phone'], ['email', 'Personal email'], ['address', 'Address'], ['bank_name', 'Bank'], ['bank_branch', 'Bank branch'], ['bank_account', 'Account no.'], ['momo_number', 'MoMo number'],
    ['next_of_kin_name', 'Next of kin'], ['next_of_kin_relation', 'Relationship'], ['next_of_kin_phone', 'Next of kin phone'], ['emergency_phone', 'Emergency phone'], ['tin', 'TIN'], ['ssnit_no', 'SSNIT no.'], ['ghana_card', 'Ghana Card']];
  return <>
    <PageHead title="My profile" sub={[e.job_title, e.department, data.manager ? 'reports to ' + data.manager.full_name : null].filter(Boolean).join(' · ')}>
      <Link className="btn" to="/my/payslips">My payslips</Link>
      <button className="btn primary" type="button" onClick={() => setForm(Object.fromEntries(fields.map(([k]) => [k, e[k] || ''])))}>Update my details</button>
    </PageHead>
    <div className="grid-2">
      <Panel title="My details" pad><dl className="kv">
        <dt>Staff no.</dt><dd>{e.staff_no || '—'}</dd><dt>Joined</dt><dd>{e.hire_date ? longDate(e.hire_date) : '—'}</dd>
        <dt>Type</dt><dd>{EMP_TYPES[e.employment_type] || '—'}</dd>
        {fields.map(([k, l]) => <span key={k} style={{ display: 'contents' }}><dt>{l}</dt><dd>{e[k] || '—'}</dd></span>)}
      </dl></Panel>
      <div style={{ display: 'grid', gap: 16 }}>
        <Panel title="My documents">{data.documents.length ? <table><tbody>{data.documents.map((d: any) => <tr key={d.id}><td><button type="button" className="btn small ghost" onClick={() => act.run(() => openFile(d.storage_path))}>{d.title}</button></td><td className="muted">{label(DOC_KINDS, d.kind)}</td></tr>)}</tbody></table> : <Empty>None shared with you yet.</Empty>}</Panel>
        <Panel title="My history">{data.history.length ? <table><tbody>{data.history.map((h: any, i: number) => <tr key={i}><td className="num">{longDate(h.effective_date)}</td><td>{h.title}</td></tr>)}</tbody></table> : <Empty>Nothing yet.</Empty>}</Panel>
        {data.requests.length > 0 && <Panel title="My update requests"><table><tbody>{data.requests.map((r: any) => <tr key={r.id}><td>{Object.keys(r.changes).map(k => k.replace(/_/g, ' ')).join(', ')}</td>
          <td><span className={'pill ' + (r.status === 'approved' ? 'good' : r.status === 'rejected' ? 'bad' : 'warn')}>{r.status === 'pending' ? 'Waiting for HR' : r.status}</span></td></tr>)}</tbody></table></Panel>}
      </div>
    </div>
    {form && <FormModal title="Update my details" submit="Send to HR" busy={act.busy} onClose={() => setForm(null)} onSave={() => act.run(async () => {
      const changes = Object.fromEntries(Object.entries(form).filter(([k, v]) => k !== 'note' && String(v || '') !== String(e[k] || '')));
      if (!Object.keys(changes).length) throw new Error('Nothing changed');
      await rpc('request_profile_change', { p_changes: changes, p_note: form.note || null, p_company: cid }); setForm(null); reload(); }, 'Sent to HR for approval')}>
      <div className="grid-form">{fields.map(([k, l]) => <Field key={k} label={l} id={'mp-' + k} value={form[k]} onChange={v => setForm({ ...form, [k]: v })} />)}</div>
      <Field label="Note to HR" id="mp-note" value={form.note || ''} onChange={v => setForm({ ...form, note: v })} />
      <p className="muted" style={{ margin: 0, fontSize: 13 }}>HR checks and approves the change. Pay, title and department are changed only by HR.</p>
    </FormModal>}
  </>;
}

// ---------------------------------------------------------------- Org chart and directory
export function OrgChartPage() {
  const { cid } = useSession();
  const [find, setFind] = useState('');
  const { data, error, loading } = useLoad(() => rpc<any[]>('staff_directory', { cid }), [cid]);
  const people = data || [];
  const kids = (id: string | null) => people.filter(p => (p.manager_id || null) === id || (id === null && p.manager_id && !people.some(x => x.id === p.manager_id)));
  const Node = ({ p, depth }: { p: any; depth: number }) => {
    const sub = people.filter(x => x.manager_id === p.id);
    return <li><div className="org-card"><b>{p.full_name}</b><span>{p.job_title || '—'}</span><span className="muted">{[p.department, p.branch].filter(Boolean).join(' · ')}</span>{sub.length > 0 && <span className="muted">{sub.length} report{sub.length === 1 ? '' : 's'}</span>}</div>
      {sub.length > 0 && depth < 8 && <ul>{sub.map(s => <Node key={s.id} p={s} depth={depth + 1} />)}</ul>}</li>;
  };
  const hits = find ? people.filter(p => `${p.full_name} ${p.job_title} ${p.department} ${p.email} ${p.phone}`.toLowerCase().includes(find.toLowerCase())) : [];
  return <>
    <PageHead title="Organisation chart" sub="Who reports to whom. Set each person's manager under Employees → Edit details → Reports to.">
      <div className="field" style={{ width: 240 }}><label htmlFor="org-find">Find someone</label><input id="org-find" value={find} onChange={e => setFind(e.target.value)} placeholder="Name, title, department" /></div>
    </PageHead>
    <Loading error={error} loading={loading && !data} />
    {find && <Panel title="Directory">{hits.length ? <table><tbody>{hits.map(p => <tr key={p.id}><td><b>{p.full_name}</b><br /><span className="muted">{p.job_title}</span></td><td>{p.department}</td><td>{p.email}</td><td>{p.phone}</td></tr>)}</tbody></table> : <Empty>No match.</Empty>}</Panel>}
    {data && !find && <Panel>{people.length ? <div className="org"><ul>{kids(null).map(p => <Node key={p.id} p={p} depth={0} />)}</ul></div> : <Empty>No staff yet.</Empty>}</Panel>}
  </>;
}

// ---------------------------------------------------------------- Announcements
export function AnnouncementsPanel() {
  const { cid } = useSession();
  const { data, reload } = useLoad(() => rpc<any[]>('my_announcements', { cid }).catch(() => [] as any[]), [cid]);
  const list = (data || []).filter(a => a.pinned || !a.read).slice(0, 4);
  if (!list.length) return null;
  return <Panel title="Announcements" actions={<Link className="btn small" to="/announcements">All</Link>}>
    {list.map(a => <div key={a.id} className="body" style={{ borderBottom: '1px solid var(--line)' }}>
      <div className="actions" style={{ justifyContent: 'space-between' }}><b>{a.pinned ? '📌 ' : ''}{a.title}</b><span className="muted" style={{ fontSize: 12 }}>{longDate(a.publish_on)}</span></div>
      <div style={{ whiteSpace: 'pre-wrap', fontSize: 14 }}>{a.body}</div>
      {!a.read && <button className="btn small ghost" type="button" style={{ padding: 0 }} onClick={async () => { await supabase.from('announcement_reads').insert({ announcement_id: a.id }); reload(); }}>Mark as read</button>}
    </div>)}
  </Panel>;
}

export function AnnouncementsPage() {
  const { cid, can } = useSession();
  const act = useAction();
  const [form, setForm] = useState<any | null>(null);
  const { data, error, loading, reload } = useLoad(() => rpc<any[]>('my_announcements', { cid }), [cid]);
  return <>
    <PageHead title="Announcements" sub="News, policy changes, holidays and payroll notices for all staff, a department or a branch.">
      {can('hr') && <button className="btn primary" type="button" onClick={() => setForm({ title: '', body: '', audience: 'all', audience_value: '', pinned: false, publish_on: today(), expires_on: '' })}>New announcement</button>}
    </PageHead>
    <Loading error={error} loading={loading && !data} />
    {data && (data.length ? data.map(a => <Panel key={a.id} title={<div className="actions"><h2>{a.title}</h2>{a.pinned && <span className="pill">Pinned</span>}{a.audience !== 'all' && <span className="pill">{a.audience_value}</span>}</div>}
      actions={can('hr') && <ConfirmButton className="btn small ghost" label="Delete" confirm="Delete this announcement?" onConfirm={() => act.run(async () => { await q(supabase.from('announcements').delete().eq('id', a.id) as any); reload(); })} />} pad>
      <div style={{ whiteSpace: 'pre-wrap' }}>{a.body}</div><div className="muted" style={{ fontSize: 12, marginTop: 8 }}>{longDate(a.publish_on)} · {(a.created_email || '').split('@')[0]}</div></Panel>)
      : <Panel><Empty>No announcements.</Empty></Panel>)}
    {form && <FormModal title="New announcement" submit="Publish" busy={act.busy} onClose={() => setForm(null)} onSave={() => act.run(async () => {
      await q(supabase.from('announcements').insert({ company_id: cid, title: form.title, body: form.body, audience: form.audience, audience_value: form.audience === 'all' ? null : form.audience_value, pinned: form.pinned, publish_on: form.publish_on, expires_on: form.expires_on || null }) as any);
      setForm(null); reload(); }, 'Published; everyone it is for has been notified')}>
      <Field label="Title" id="an-title" value={form.title} onChange={v => setForm({ ...form, title: v })} required />
      <Field label="Message" id="an-body" type="textarea" value={form.body} onChange={v => setForm({ ...form, body: v })} />
      <div className="grid-form">
        <Select label="For" id="an-aud" value={form.audience} onChange={v => setForm({ ...form, audience: v })} options={[['all', 'All staff'], ['department', 'One department'], ['branch', 'One branch']]} />
        {form.audience !== 'all' && <Field label={form.audience === 'department' ? 'Department (as on employee records)' : 'Branch name or code'} id="an-val" value={form.audience_value} onChange={v => setForm({ ...form, audience_value: v })} required />}
        <Field label="Show from" id="an-from" type="date" value={form.publish_on} onChange={v => setForm({ ...form, publish_on: v })} />
        <Field label="Until (optional)" id="an-to" type="date" value={form.expires_on} onChange={v => setForm({ ...form, expires_on: v })} />
      </div>
      <label className="check"><input type="checkbox" checked={form.pinned} onChange={e => setForm({ ...form, pinned: e.target.checked })} /> Pin to the top of everyone's home screen</label>
    </FormModal>}
  </>;
}

// ---------------------------------------------------------------- HR reports and the annual PAYE return
export function HrReportsPage() {
  const { cid, company } = useSession();
  const [from, setFrom] = useState(today().slice(0, 4) + '-01-01');
  const [to, setTo] = useState(today());
  const [year, setYear] = useState(Number(today().slice(0, 4)));
  const { data, error, loading } = useLoad(async () => {
    const [rep, annual] = await Promise.all([rpc<any>('hr_report', { cid, p_from: from, p_to: to }), rpc<any[]>('paye_annual', { cid, p_year: year })]);
    return { rep, annual };
  }, [cid, from, to, year]);
  const r = data?.rep;
  const aHead = ['Name', 'TIN', 'Ghana Card', 'SSNIT no.', 'Months', 'Basic', 'Allowances', 'Other taxable', 'Not taxed', 'Overtime', 'Bonus', 'Gross', 'SSNIT 5.5%', 'Chargeable', 'PAYE', 'Overtime tax', 'Bonus tax', 'Total tax (GHS)'];
  const aRows = (data?.annual || []).map(a => [a.full_name, a.tin || '', a.ghana_card || '', a.ssnit_no || '', a.months, money(a.basic), money(a.allowances), money(a.other_earnings), money(a.nontaxable), money(a.overtime), money(a.bonus), money(a.gross), money(a.ssnit_employee), money(a.chargeable), money(a.paye), money(a.overtime_tax), money(a.bonus_tax), money(a.total_tax)]);
  const tot = (k: string) => (data?.annual || []).reduce((s, a) => s + Number(a[k] || 0), 0);
  return <>
    <PageHead title="HR reports" sub="Headcount, joiners and leavers, turnover, payroll cost, leave owed, and the annual PAYE return.">
      <div className="field" style={{ width: 150 }}><label htmlFor="hr-from">From</label><input id="hr-from" type="date" value={from} onChange={e => setFrom(e.target.value)} /></div>
      <div className="field" style={{ width: 150 }}><label htmlFor="hr-to">To</label><input id="hr-to" type="date" value={to} onChange={e => setTo(e.target.value)} /></div>
    </PageHead>
    <Loading error={error} loading={loading && !data} />
    {r && <>
      <div className="tiles">
        <div className="tile"><span>Headcount now</span><b>{r.headcount_end}</b><span>{r.headcount_start} at the start</span></div>
        <div className="tile"><span>Joiners</span><b>{r.joiners}</b></div>
        <div className="tile"><span>Leavers</span><b>{r.leavers}</b></div>
        <div className="tile"><span>Staff turnover</span><b>{r.turnover_pct != null ? r.turnover_pct + '%' : '—'}</b><span>leavers ÷ average headcount</span></div>
        <div className="tile"><span>Annual leave owed</span><b>{money(r.leave_liability?.value)}</b><span>{r.leave_liability?.days ?? 0} days (basic ÷ 22 a day)</span></div>
      </div>
      <div className="grid-2" style={{ marginTop: 16 }}>
        <Panel title="By department">{r.by_department.length ? <table><thead><tr><th>Department</th><th className="r">People</th><th className="r">Basic pay a month</th></tr></thead><tbody>{r.by_department.map((d: any) => <tr key={d.name}><td>{d.name}</td><td className="r num">{d.n}</td><td className="r num">{money(d.basic)}</td></tr>)}</tbody></table> : <Empty>No staff.</Empty>}</Panel>
        <Panel title="By type and gender"><table><tbody>{r.by_type.map((d: any) => <tr key={d.name}><td>{EMP_TYPES[d.name] || d.name}</td><td className="r num">{d.n}</td></tr>)}{r.by_gender.map((d: any) => <tr key={'g' + d.name}><td style={{ textTransform: 'capitalize' }}>{d.name}</td><td className="r num">{d.n}</td></tr>)}</tbody></table></Panel>
        <Panel title="Payroll cost by month">{r.payroll_by_month.length ? <table><thead><tr><th>Month</th><th className="r">People</th><th className="r">Gross</th><th className="r">Employer pension</th><th className="r">Total cost</th></tr></thead>
          <tbody>{r.payroll_by_month.map((m: any) => <tr key={m.period}><td>{monthName(m.period)}</td><td className="r num">{m.people}</td><td className="r num">{money(m.gross)}</td><td className="r num">{money(m.employer)}</td><td className="r num">{money(Number(m.gross) + Number(m.employer))}</td></tr>)}</tbody></table> : <Empty>No payroll posted in this period.</Empty>}</Panel>
        <Panel title="Coming up">{[...r.probation_ending.map((x: any) => ['Probation ends', x.full_name, x.date, x.id]), ...r.contracts_ending.map((x: any) => ['Contract ends', x.full_name, x.date, x.id]), ...r.documents_expiring.map((x: any) => [x.title + ' expires', x.employee, x.date, null])].length
          ? <table><tbody>{[...r.probation_ending.map((x: any) => ['Probation ends', x.full_name, x.date, x.id]), ...r.contracts_ending.map((x: any) => ['Contract ends', x.full_name, x.date, x.id]), ...r.documents_expiring.map((x: any) => [x.title + ' expires', x.employee, x.date, null])]
            .sort((a, b) => String(a[2]).localeCompare(String(b[2]))).map((x, i) => <tr key={i}><td className="num">{longDate(x[2])}</td><td>{x[0]}</td><td>{x[3] ? <Link to={'/employees/' + x[3]}>{x[1]}</Link> : x[1]}</td></tr>)}</tbody></table>
          : <Empty>No probations, contracts or documents ending soon.</Empty>}
          {r.birthdays.length > 0 && <div className="body muted" style={{ fontSize: 13 }}>Birthdays this month: {r.birthdays.map((b: any) => `${b.full_name} (${b.day})`).join(', ')}</div>}</Panel>
      </div>
    </>}
    {data && <Panel title={`Annual PAYE return ${year}`} actions={<>
      <select aria-label="Year" value={year} onChange={e => setYear(Number(e.target.value))} style={{ width: 'auto' }}>{[0, 1, 2].map(d => Number(today().slice(0, 4)) - d).map(y => <option key={y} value={y}>{y}</option>)}</select>
      <button className="btn small" type="button" disabled={!aRows.length} onClick={() => tablePdf({ company: company!, title: `Annual PAYE return ${year}`, subtitle: `Employer TIN ${company?.tin || '—'}`, head: aHead, body: aRows, landscape: true, filename: `paye-annual-${year}`,
        foot: ['Totals', '', '', '', '', money(tot('basic')), money(tot('allowances')), money(tot('other_earnings')), money(tot('nontaxable')), money(tot('overtime')), money(tot('bonus')), money(tot('gross')), money(tot('ssnit_employee')), money(tot('chargeable')), money(tot('paye')), money(tot('overtime_tax')), money(tot('bonus_tax')), money(tot('total_tax'))],
        rightAlign: [4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17], notes: 'From every posted pay run in the year, including off-cycle runs. Check the layout GRA asks for on the annual return before filing.' })}>PDF</button>
      <button className="btn small" type="button" disabled={!aRows.length} onClick={() => downloadCsv(`paye-annual-${year}`, aHead, aRows)}>CSV</button></>}>
      {aRows.length ? <div className="scroll"><table><thead><tr><th>Employee</th><th>TIN</th><th className="r">Months</th><th className="r">Gross</th><th className="r">Chargeable</th><th className="r">Total tax</th></tr></thead>
        <tbody>{data.annual.map(a => <tr key={a.employee_id}><td>{a.full_name}</td><td className="num">{a.tin || <span className="muted">missing</span>}</td><td className="r num">{a.months}</td><td className="r num">{money(a.gross)}</td><td className="r num">{money(a.chargeable)}</td><td className="r num">{money(a.total_tax)}</td></tr>)}</tbody></table></div>
        : <Empty>No payroll posted in {year}.</Empty>}
    </Panel>}
  </>;
}

// ---------------------------------------------------------------- Public holidays (on the Leave page)
export function HolidaysPanel() {
  const { cid, can } = useSession();
  const act = useAction();
  const [year, setYear] = useState(Number(today().slice(0, 4)));
  const [form, setForm] = useState<any | null>(null);
  const { data, reload } = useLoad(() => q<any[]>(supabase.from('public_holidays').select('*').eq('company_id', cid).gte('holiday', `${year}-01-01`).lte('holiday', `${year}-12-31`).order('holiday') as any).catch(() => [] as any[]), [cid, year]);
  const edit = can('hr', 'accountant');
  return <Panel title="Public holidays" actions={<>
    <select aria-label="Year" value={year} onChange={e => setYear(Number(e.target.value))} style={{ width: 'auto' }}>{[-1, 0, 1].map(d => Number(today().slice(0, 4)) + d).map(y => <option key={y} value={y}>{y}</option>)}</select>
    {edit && <button className="btn small" type="button" onClick={() => act.run(async () => { await rpc('seed_ghana_holidays', { cid, y: year }); reload(); }, 'Ghana holidays added')}>Add Ghana holidays for {year}</button>}
    {edit && <button className="btn small primary" type="button" onClick={() => setForm({ holiday: '', name: '' })}>Add</button>}</>}>
    {data?.length ? <table><tbody>{data.map(h => <tr key={h.holiday}><td className="num">{longDate(h.holiday)}</td><td>{h.name}</td><td className="muted">{new Date(h.holiday + 'T12:00').toLocaleDateString('en-GB', { weekday: 'long' })}</td>
      <td className="r">{edit && <button className="btn small ghost" type="button" onClick={() => act.run(async () => { await q(supabase.from('public_holidays').delete().eq('company_id', cid).eq('holiday', h.holiday) as any); reload(); })}>Remove</button>}</td></tr>)}</tbody></table>
      : <Empty>No holidays for {year}.</Empty>}
    <div className="body muted" style={{ fontSize: 13 }}>Leave days skip weekends and these dates. Eid al-Fitr, Shaqq Day (the day after) and Eid al-Adha follow the moon: add them when the government announces the dates. Add any extra day declared, or a holiday moved to a Monday, the same way.</div>
    {form && <FormModal title="Add a public holiday" busy={act.busy} onClose={() => setForm(null)} onSave={() => act.run(async () => { await q(supabase.from('public_holidays').insert({ company_id: cid, holiday: form.holiday, name: form.name }) as any); setForm(null); reload(); }, 'Added')}>
      <div className="grid-form">
        <Field label="Date" id="ph-date" type="date" value={form.holiday} onChange={v => setForm({ ...form, holiday: v })} required />
        <Field label="Name" id="ph-name" value={form.name} onChange={v => setForm({ ...form, name: v })} placeholder="e.g. Eid al-Fitr" required />
      </div>
    </FormModal>}
  </Panel>;
}
