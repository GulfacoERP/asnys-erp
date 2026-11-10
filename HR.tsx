import { DimSelects, useDims } from '../components/dims';
import { useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { q, rpc, supabase } from '../lib/supabase';
import { useSession } from '../lib/session';
import { longDate, money, today, workingDays } from '../lib/format';
import { downloadCsv } from '../lib/download';
import { tablePdf } from '../lib/pdf';
import { Downloads, Empty, Field, FormModal, Loading, PageHead, Panel, Select, Status, useAction, useLoad, useToast } from '../components/ui';
import { inviteAndSend } from '../lib/invites';
import { createLogins, PasswordSlips, type Slip } from '../components/Logins';
import { HolidaysPanel } from './People';

const blank = { staff_no: '', full_name: '', email: '', phone: '', job_title: '', department: '', hire_date: '', basic_salary: '', allowances: '', ghana_card: '', ssnit_no: '', tin: '', bank_name: '', bank_branch: '', bank_account: '', momo_number: '', pay_method: 'bank', branch_id: '', cost_centre_id: '', status: 'active', is_junior: false, tier3_employee_rate: '', tier3_employer_rate: '', skills: '', location: '', country: 'Ghana', cost_rate: '', login_email: '' };

function AccessPill({ a }: { a?: { access: string; email: string } }) {
  if (!a || a.access === 'none') return <span className="muted">Not invited</span>;
  const [label, cls] = ({ active: ['Has access', 'good'], invited: ['Invited', 'warn'], failed: ['Email failed', 'bad'] } as Record<string, string[]>)[a.access] || [a.access, ''];
  return <span className={'pill ' + cls} title={a.email}>{label}</span>;
}

export function EmployeesPage() {
  const { cid, company, can } = useSession();
  const [edit, setEdit] = useState<any | null>(null);
  const [show, setShow] = useState('active');
  const act = useAction();
  const { data, error, loading, reload } = useLoad(() => q<any[]>(supabase.from('employees').select('*').eq('company_id', cid).order('full_name') as any), [cid]);
  const list = (data || []).filter(e => show === 'all' || e.status === show);
  const toast = useToast();
  const [picked, setPicked] = useState<string[]>([]);
  const { data: access, reload: reloadAccess } = useLoad(() => can('hr') ? rpc<any[]>('employee_access', { cid }) : Promise.resolve([]), [cid]);
  const accessOf = (id: string) => (access || []).find(a => a.employee_id === id);
  const invitable = (e: any) => e.status === 'active' && accessOf(e.id)?.access !== 'active';
  const [slips, setSlips] = useState<{ slips: Slip[]; note?: string } | null>(null);
  const inviteEmployees = (emps: any[], emailFor: (e: any) => string, how: 'password' | 'email' = 'email') => act.run(async () => {
    const withEmail = emps.filter(e => emailFor(e));
    const missing = emps.filter(e => !emailFor(e)).map(e => e.full_name);
    if (!withEmail.length) throw new Error('Add an email address to the employee record first.');
    if (how === 'password') {
      const r = await createLogins(cid, withEmail.map(e => ({ email: emailFor(e), role: 'staff', employee_id: e.id })));
      setSlips({ slips: r.slips, note: [r.note, missing.length ? `No email on file for: ${missing.join(', ')}.` : ''].filter(Boolean).join(' ') }); setPicked([]); reloadAccess(); return;
    }
    let m = await inviteAndSend(cid, withEmail.map(e => ({ email: emailFor(e), role: 'staff', employee_id: e.id })));
    if (missing.length) m += ` No email on file for: ${missing.join(', ')}.`;
    toast(m, /could not|not set up|Not valid|No email/.test(m)); setPicked([]); reloadAccess();
  });
  const head = ['Staff no.', 'Name', 'Job title', 'Department', 'Hire date', 'Basic (GHS)', 'Allowances (GHS)', 'SSNIT no.', 'Ghana Card', 'Phone', 'Status'];
  const rows = list.map(e => [e.staff_no || '', e.full_name, e.job_title || '', e.department || '', e.hire_date || '', money(e.basic_salary), money(e.allowances), e.ssnit_no || '', e.ghana_card || '', e.phone || '', e.status]);
  const editable = can('hr');
  const nav = useNavigate();

  return <>
    <PageHead title="Employees" sub={data ? `${data.filter(e => e.status === 'active').length} active staff` : undefined}>
      <Downloads pdf={() => tablePdf({ company: company!, title: 'Staff list', subtitle: longDate(today()), head, body: rows, rightAlign: [5, 6], landscape: true, filename: 'staff-list' })}
        csv={() => downloadCsv('staff-list', head, rows)} />
      {editable && picked.length > 0 && <>
        <button className="btn primary" type="button" disabled={act.busy} title="A temporary password for each, to hand over; no email needed" onClick={() => inviteEmployees(list.filter(e => picked.includes(e.id)), e => (e.email || '').trim(), 'password')}>Create logins ({picked.length})</button>
        <button className="btn" type="button" disabled={act.busy} onClick={() => inviteEmployees(list.filter(e => picked.includes(e.id)), e => (e.email || '').trim())}>Email invitations ({picked.length})</button></>}
      {editable && <button className="btn primary" type="button" onClick={() => setEdit({ ...blank, hire_date: today() })}>Add employee</button>}
    </PageHead>
    <div className="filters"><Select label="Show" id="e-show" value={show} onChange={setShow} options={[['active', 'Active'], ['inactive', 'Left the company'], ['all', 'All']]} /></div>
    <Loading error={error} loading={loading && !data} />
    {data && <Panel>{list.length ? <div className="scroll"><table>
      <thead><tr>{editable && <th style={{ width: 28 }}><input type="checkbox" aria-label="Select everyone without access" checked={picked.length > 0 && picked.length === list.filter(invitable).length}
        onChange={ev => setPicked(ev.target.checked ? list.filter(invitable).map(e => e.id) : [])} /></th>}<th>Name</th><th>Job title</th><th>Department</th><th className="r">Basic (GH₵)</th><th className="r">Allowances</th><th>SSNIT no.</th><th>Status</th>{editable && <th>Sign-in</th>}</tr></thead>
      <tbody>{list.map(e => <tr key={e.id}>
        {editable && <td>{invitable(e) && <input type="checkbox" aria-label={`Select ${e.full_name}`} checked={picked.includes(e.id)} onChange={ev => setPicked(ev.target.checked ? [...picked, e.id] : picked.filter(x => x !== e.id))} />}</td>}
        <td><Link to={'/employees/' + e.id} style={{ fontWeight: 600 }}>{e.full_name}</Link>
          {e.staff_no && <span className="muted num"> · {e.staff_no}</span>}</td>
        <td>{e.job_title}</td><td>{e.department}</td><td className="r num">{money(e.basic_salary)}</td><td className="r num">{money(e.allowances)}</td>
        <td className="num">{e.ssnit_no}</td><td><Status s={e.status} /></td>
        {editable && <td><AccessPill a={accessOf(e.id)} /></td>}</tr>)}</tbody>
    </table></div> : <Empty>No employees yet.</Empty>}</Panel>}
    {edit && <EmployeeEditor initial={edit} onClose={() => setEdit(null)} onSaved={id => { setEdit(null); if (!edit.id) nav('/employees/' + id); else reload(); }} />}
    {slips && <PasswordSlips slips={slips.slips} note={slips.note} onClose={() => setSlips(null)} />}
  </>;
}

/** Add or edit an employee (used by the staff list and the employee profile). */
export function EmployeeEditor({ initial, onClose, onSaved }: { initial: any; onClose: () => void; onSaved: (id: string) => void }) {
  const { cid, can } = useSession();
  const { data: dims } = useDims(cid);
  const [edit, setEdit] = useState<any>(initial);
  const act = useAction();
  const toast = useToast();
  const { data: others } = useLoad(() => q<any[]>(supabase.from('employees').select('id,full_name').eq('company_id', cid).eq('status', 'active').order('full_name') as any), [cid]);
  const { data: access, reload: reloadAccess } = useLoad(() => can('hr') && edit.id ? rpc<any[]>('employee_access', { cid }) : Promise.resolve([]), [cid]);
  const accessOf = (id: string) => (access || []).find(a => a.employee_id === id);
  const [slips, setSlips] = useState<{ slips: Slip[]; note?: string } | null>(null);
  const inviteEmployees = (emps: any[], emailFor: (e: any) => string, how: 'password' | 'email' = 'email') => act.run(async () => {
    const withEmail = emps.filter(e => emailFor(e));
    if (!withEmail.length) throw new Error('Add an email address to the employee record first.');
    if (how === 'password') { const r = await createLogins(cid, withEmail.map(e => ({ email: emailFor(e), role: 'staff', employee_id: e.id }))); setSlips(r); reloadAccess(); return; }
    const m = await inviteAndSend(cid, withEmail.map(e => ({ email: emailFor(e), role: 'staff', employee_id: e.id })));
    toast(m, /could not|not set up|Not valid|No email/.test(m)); reloadAccess();
  });
  const set = (k: string) => (v: any) => setEdit({ ...edit, [k]: v });
  const save = () => act.run(async () => {
    const row: any = { ...edit };
    delete row.id; delete row.created_at; delete row.company_id; delete row.login_was;
    row.branch_id = row.branch_id || null; row.cost_centre_id = row.cost_centre_id || null; row.manager_id = row.manager_id || null;
    row.basic_salary = Number(row.basic_salary) || 0; row.allowances = Number(row.allowances) || 0; row.hire_date = row.hire_date || null;
    for (const k of ['probation_end', 'confirmed_on', 'contract_end', 'date_of_birth', 'end_date', 'gender', 'grade']) row[k] = row[k] || null;
    row.notice_days = row.notice_days === '' || row.notice_days == null ? null : Number(row.notice_days);
    row.employment_type = row.employment_type || 'permanent';
    row.skills = String(row.skills || '').split(',').map((x: string) => x.trim()).filter(Boolean); row.cost_rate = row.cost_rate === '' ? null : Number(row.cost_rate);
    const login = row.login_email; delete row.login_email; delete row.user_id;
    row.tier3_employee_rate = (Number(row.tier3_employee_rate) || 0) / 100; row.tier3_employer_rate = (Number(row.tier3_employer_rate) || 0) / 100;
    let empId = edit.id;
    if (empId) await q(supabase.from('employees').update(row).eq('id', empId) as any);
    else empId = (await q<any>(supabase.from('employees').insert({ ...row, company_id: cid }).select('id').single() as any)).id;
    if (login !== edit.login_was) await rpc('link_employee_user', { p_employee: empId, p_email: login || '' });
    onSaved(empId);
  }, 'Employee saved');
  return <FormModal title={edit.id ? 'Edit employee' : 'Add employee'} onClose={onClose} onSave={save} busy={act.busy}>
      <div className="grid-form">
        <Field label="Full name" id="em-name" value={edit.full_name} onChange={set('full_name')} required />
        <Field label="Staff no." id="em-no" value={edit.staff_no} onChange={set('staff_no')} />
        <Field label="Job title" id="em-job" value={edit.job_title} onChange={set('job_title')} />
        <Field label="Department" id="em-dept" value={edit.department} onChange={set('department')} />
        <Field label="Hire date" id="em-hire" type="date" value={edit.hire_date} onChange={set('hire_date')} />
        <Select label="Status" id="em-status" value={edit.status} onChange={set('status')} options={[['active', 'Active'], ['inactive', 'Left the company']]} />
        <DimSelects dims={dims} branch={edit.branch_id} centre={edit.cost_centre_id} onChange={(b, c) => setEdit({ ...edit, branch_id: b, cost_centre_id: c })} idPrefix="em" />
      </div>
      <div className="label">Employment</div>
      <div className="grid-form">
        <Select label="Type" id="em-type" value={edit.employment_type || 'permanent'} onChange={set('employment_type')} options={[['permanent', 'Permanent'], ['fixed_term', 'Fixed-term contract'], ['contract', 'Contract (project)'], ['casual', 'Casual'], ['intern', 'Intern'], ['national_service', 'National service'], ['consultant', 'Consultant']]} />
        <Field label="Grade" id="em-grade" value={edit.grade || ''} onChange={set('grade')} />
        <Select label="Reports to" id="em-mgr" value={edit.manager_id || ''} onChange={set('manager_id')} options={[['', 'Nobody'], ...(others || []).filter((o: any) => o.id !== edit.id).map((o: any) => [o.id, o.full_name] as [string, string])]} />
        <Field label="Probation ends" id="em-prob" type="date" value={edit.probation_end || ''} onChange={set('probation_end')} />
        <Field label="Confirmed on" id="em-conf" type="date" value={edit.confirmed_on || ''} onChange={set('confirmed_on')} />
        <Field label="Contract ends" id="em-cend" type="date" value={edit.contract_end || ''} onChange={set('contract_end')} />
        <Field label="Notice period (days)" id="em-notice" type="number" min="0" value={edit.notice_days ?? ''} onChange={set('notice_days')} />
      </div>
      <div className="label">Personal and next of kin</div>
      <div className="grid-form">
        <Field label="Date of birth" id="em-dob" type="date" value={edit.date_of_birth || ''} onChange={set('date_of_birth')} />
        <Select label="Gender" id="em-gender" value={edit.gender || ''} onChange={set('gender')} options={[['', '—'], ['female', 'Female'], ['male', 'Male'], ['other', 'Other']]} />
        <Field label="Address" id="em-addr" value={edit.address || ''} onChange={set('address')} />
        <Field label="Next of kin" id="em-nok" value={edit.next_of_kin_name || ''} onChange={set('next_of_kin_name')} />
        <Field label="Relationship" id="em-nokr" value={edit.next_of_kin_relation || ''} onChange={set('next_of_kin_relation')} />
        <Field label="Next of kin phone" id="em-nokp" value={edit.next_of_kin_phone || ''} onChange={set('next_of_kin_phone')} />
        <Field label="Emergency phone" id="em-emerg" value={edit.emergency_phone || ''} onChange={set('emergency_phone')} />
      </div>
      <div className="label">Pay</div>
      <div className="grid-form">
        <Field label="Basic salary per month (GH₵)" id="em-basic" type="number" step="0.01" min="0" value={edit.basic_salary} onChange={set('basic_salary')} required />
        <Field label="Taxable allowances per month (GH₵)" id="em-allow" type="number" step="0.01" min="0" value={edit.allowances} onChange={set('allowances')} />
        <Field label="Tier 3: employee % of basic" id="em-t3e" type="number" step="0.01" min="0" value={edit.tier3_employee_rate} onChange={set('tier3_employee_rate')} />
        <Field label="Tier 3: employer % of basic" id="em-t3r" type="number" step="0.01" min="0" value={edit.tier3_employer_rate} onChange={set('tier3_employer_rate')} />
      </div>
      <label className="check"><input type="checkbox" checked={!!edit.is_junior} onChange={e => setEdit({ ...edit, is_junior: e.target.checked })} /> Junior staff (qualifies for 5% / 10% overtime tax if annual income is GH₵18,000 or less)</label>
      <div className="label">Skills and location (for the resource planner)</div>
      <Field label="Skills, comma separated" id="em-skills" value={edit.skills} onChange={set('skills')} placeholder="e.g. AutoCAD, Twi, Forklift licence, SAP" />
      <div className="grid-form">
        <Field label="Based in (town)" id="em-loc" value={edit.location} onChange={set('location')} />
        <Field label="Country" id="em-country" value={edit.country} onChange={set('country')} />
        <Field label="Internal cost per hour (GH₵)" id="em-cost" type="number" step="0.01" min="0" value={edit.cost_rate} onChange={set('cost_rate')} />
        <Field label="Sign-in email (for My time & expenses)" id="em-login" type="email" value={edit.login_email === '(linked)' ? '' : edit.login_email} onChange={set('login_email')} placeholder={edit.login_was ? 'Linked — type a new email to change' : 'their work email'} />
      </div>
      {edit.id && !edit.login_was && <div className="actions" style={{ marginTop: -4 }}>
        <button className="btn small primary" type="button" disabled={act.busy} onClick={() => inviteEmployees([edit], e => (e.login_email && e.login_email !== '(linked)' ? e.login_email : e.email || '').trim(), 'password')}>Create login</button>{' '}
        <button className="btn small" type="button" disabled={act.busy} onClick={() => inviteEmployees([edit], e => (e.login_email && e.login_email !== '(linked)' ? e.login_email : e.email || '').trim())}>Email invitation</button>
        {slips && <PasswordSlips slips={slips.slips} note={slips.note} onClose={() => setSlips(null)} />}
        <span className="muted" style={{ fontSize: 13 }}>{accessOf(edit.id)?.access === 'invited' ? `Invited as ${accessOf(edit.id).email}. Press again to resend.` : 'Emails them a link to set a password and sign in as staff. Uses the sign-in email above, or their contact email.'}</span>
      </div>}
      <div className="label">Statutory IDs</div>
      <div className="grid-form">
        <Field label="Ghana Card no." id="em-card" value={edit.ghana_card} onChange={set('ghana_card')} placeholder="GHA-000000000-0" />
        <Field label="SSNIT no." id="em-ssnit" value={edit.ssnit_no} onChange={set('ssnit_no')} />
        <Field label="TIN" id="em-tin" value={edit.tin} onChange={set('tin')} />
      </div>
      <div className="label">Contact and payment</div>
      <div className="grid-form">
        <Field label="Phone" id="em-phone" value={edit.phone} onChange={set('phone')} />
        <Field label="Email" id="em-email" type="email" value={edit.email} onChange={set('email')} />
        <Select label="Salary paid by" id="em-paym" value={edit.pay_method || 'bank'} onChange={set('pay_method')} options={[['bank', 'Bank transfer'], ['momo', 'Mobile Money'], ['cash', 'Cash']]} />
        <Field label="Bank name" id="em-bank" value={edit.bank_name} onChange={set('bank_name')} />
        <Field label="Bank branch" id="em-bbr" value={edit.bank_branch || ''} onChange={set('bank_branch')} />
        <Field label="Account no." id="em-acct" value={edit.bank_account} onChange={set('bank_account')} />
        <Field label="MoMo number" id="em-momo" value={edit.momo_number} onChange={set('momo_number')} />
      </div>
  </FormModal>;
}

/** The form's starting values for an existing employee. */
export const toEditable = (e: any) => ({ ...blank, ...Object.fromEntries(Object.entries(e).map(([k, v]) => [k, v ?? ''])), tier3_employee_rate: e.tier3_employee_rate ? String(Number(e.tier3_employee_rate) * 100) : '', tier3_employer_rate: e.tier3_employer_rate ? String(Number(e.tier3_employer_rate) * 100) : '', skills: (e.skills || []).join(', '), cost_rate: e.cost_rate ?? '', login_email: e.user_id ? '(linked)' : '', login_was: e.user_id ? '(linked)' : '' });

export function LeavePage() {
  const { cid, company, can } = useSession();
  const [tab, setTab] = useState<'requests' | 'balances' | 'types' | 'holidays'>('requests');
  const [year, setYear] = useState(Number(today().slice(0, 4)));
  const [req, setReq] = useState<any | null>(null);
  const [type, setType] = useState<any | null>(null);
  const [override, setOverride] = useState<any | null>(null);
  const act = useAction();
  const { data, error, loading, reload } = useLoad(async () => {
    const [staff, leave, types, balances, me] = await Promise.all([
      rpc<any[]>('employee_directory', { cid }),
      q<any[]>(supabase.from('leave_requests').select('*').eq('company_id', cid).order('start_date', { ascending: false }) as any),
      q<any[]>(supabase.from('leave_types').select('*').eq('company_id', cid).order('name') as any),
      rpc<any[]>('leave_balances', { cid, p_year: year }),
      rpc<any>('my_profile', { p_company: cid }).catch(() => null),
    ]);
    return { staff, leave, types, balances, myId: me?.employee?.id as string | undefined };
  }, [cid, year]);
  const name = (id: string) => data?.staff.find(s => s.id === id)?.full_name || 'Former employee';
  const typeName = (code: string) => data?.types.find(t => t.code === code)?.name || code;
  const head = ['Employee', 'Type', 'From', 'To', 'Working days', 'Reason', 'Status'];
  const rows = (data?.leave || []).map(l => [name(l.employee_id), typeName(l.leave_type), l.start_date, l.end_date, String(l.days), l.reason || '', l.status]);
  const limited = (data?.balances || []).filter(b => b.entitlement != null);
  const bHead = ['Employee', 'Leave type', 'Entitlement', 'Taken', 'Pending', 'Remaining'];
  const bRows = limited.map(b => [b.full_name, b.leave_name, String(b.entitlement), String(b.taken), String(b.pending), String(b.remaining)]);
  const decide = (id: string, status: string) => act.run(async () => { await rpc('decide_leave', { p_id: id, p_approve: status === 'approved', p_note: null }); reload(); }, status === 'approved' ? 'Leave approved' : 'Leave rejected');
  const hr = can('hr');
  const [preview, setPreview] = useState<{ key: string; days: number } | null>(null);
  const balanceFor = (emp: string, code: string) => data?.balances.find(b => b.employee_id === emp && b.leave_code === code);

  return <>
    <PageHead title="Leave" sub="Requests, approvals and balances. Working days skip weekends and public holidays. The employee's manager or HR approves.">
      {tab === 'requests' && <Downloads pdf={() => tablePdf({ company: company!, title: 'Leave register', head, body: rows, rightAlign: [4], landscape: true, filename: 'leave-register' })} csv={() => downloadCsv('leave-register', head, rows)} />}
      {tab === 'balances' && <Downloads pdf={() => tablePdf({ company: company!, title: 'Leave balances', subtitle: String(year), head: bHead, body: bRows, rightAlign: [2, 3, 4, 5], filename: `leave-balances-${year}` })} csv={() => downloadCsv(`leave-balances-${year}`, bHead, bRows)} />}
      <button className="btn primary" type="button" disabled={!data?.staff.length || (!hr && !data?.myId)} onClick={() => setReq({ employee_id: hr ? (data!.myId || data!.staff[0].id) : data!.myId, leave_type: 'annual', start_date: today(), end_date: today(), reason: '', half_day: false })}>Request leave</button>
    </PageHead>
    <div className="actions">
      {([['requests', 'Requests'], ['balances', 'Balances'], ['types', 'Leave types'], ['holidays', 'Public holidays']] as [typeof tab, string][]).map(([k, l]) =>
        <button key={k} type="button" className={'btn small' + (tab === k ? ' primary' : '')} onClick={() => setTab(k)}>{l}</button>)}
      {tab === 'balances' && <select aria-label="Year" value={year} onChange={e => setYear(Number(e.target.value))} style={{ width: 'auto' }}>
        {[year - 1, year, year + 1].map(y => <option key={y} value={y}>{y}</option>)}</select>}
    </div>
    <Loading error={error} loading={loading && !data} />
    {data && tab === 'requests' && <Panel>{data.leave.length ? <div className="scroll"><table>
      <thead><tr><th>Employee</th><th>Type</th><th>Dates</th><th className="r">Days</th><th>Reason</th><th>Status</th><th></th></tr></thead>
      <tbody>{data.leave.map(l => <tr key={l.id}>
        <td>{name(l.employee_id)}</td><td>{typeName(l.leave_type)}</td>
        <td className="num">{l.start_date} → {l.end_date}</td><td className="r num">{l.days}</td><td className="wrap-cell">{l.reason}</td><td><Status s={l.status} /></td>
        <td className="r">{l.status === 'pending' && l.employee_id !== data.myId && <span className="actions">
          <button className="btn small" type="button" onClick={() => decide(l.id, 'approved')}>Approve</button>
          <button className="btn small danger" type="button" onClick={() => decide(l.id, 'rejected')}>Reject</button></span>}</td></tr>)}</tbody>
    </table></div> : <Empty>{data.staff.length ? 'No leave requests yet.' : 'Add employees first.'}</Empty>}</Panel>}
    {data && tab === 'balances' && <Panel>{limited.length ? <div className="scroll"><table>
      <thead><tr><th>Employee</th><th>Leave type</th><th className="r">Entitlement</th><th className="r">Taken</th><th className="r">Pending</th><th className="r">Remaining</th><th></th></tr></thead>
      <tbody>{limited.map(b => <tr key={b.employee_id + b.leave_code}><td>{b.full_name}</td><td>{b.leave_name}</td>
        <td className="r num">{b.entitlement}</td><td className="r num">{b.taken}</td><td className="r num">{b.pending}</td>
        <td className="r num"><span className={'pill ' + (Number(b.remaining) < 0 ? 'bad' : Number(b.remaining) <= 2 ? 'warn' : 'good')}>{b.remaining}</span></td>
        <td className="r">{can('hr') && <button className="btn small ghost" type="button" onClick={() => setOverride({ employee_id: b.employee_id, name: b.full_name, leave_code: b.leave_code, leave_name: b.leave_name, days: String(b.entitlement) })}>Adjust</button>}</td></tr>)}</tbody>
    </table></div> : <Empty>Set yearly days on a leave type to track balances.</Empty>}</Panel>}
    {data && tab === 'types' && <Panel>{<div className="scroll"><table>
      <thead><tr><th>Leave type</th><th className="r">Days per year</th><th>Paid</th><th>Earned</th><th className="r">Carry over</th><th>Counts</th><th></th></tr></thead>
      <tbody>{data.types.map(t => <tr key={t.code}><td>{t.name}</td><td className="r num">{t.days_per_year ?? 'No limit'}</td><td>{t.paid ? 'Yes' : 'No'}</td>
        <td>{t.accrual === 'monthly' ? 'Monthly' : 'From 1 January'}</td><td className="r num">{Number(t.carry_over_max || 0) ? `up to ${t.carry_over_max}` : '—'}</td><td>{t.counts === 'calendar' ? 'Calendar days' : 'Working days'}</td>
        <td className="r">{can('hr') && <button className="btn small ghost" type="button" onClick={() => setType({ ...t, days_per_year: t.days_per_year ?? '', carry_over_max: String(t.carry_over_max ?? 0), accrual: t.accrual || 'upfront', counts: t.counts || 'working' })}>Edit</button>}</td></tr>)}</tbody>
    </table></div>}
      <div className="body muted" style={{ fontSize: 13 }}>Annual leave defaults to 15 working days, the Labour Act minimum. Joiners get a share of the year from their hire month. Set limits, monthly earning and carry-over to match your contracts.</div></Panel>}
    {tab === 'holidays' && <HolidaysPanel />}

    {req && data && <FormModal title="Request leave" submit="Submit request" busy={act.busy} onClose={() => setReq(null)}
      onSave={() => act.run(async () => {
        if (req.end_date < req.start_date) throw new Error('The end date is before the start date.');
        await q(supabase.from('leave_requests').insert({ ...req, company_id: cid, days: 0, reason: req.reason || null }) as any);
        setReq(null); reload();
      }, 'Leave requested')}>
      {hr ? <Select label="Employee" id="lv-emp" value={req.employee_id} onChange={v => setReq({ ...req, employee_id: v })} options={data.staff.map(s => [s.id, s.full_name])} />
        : <p style={{ margin: 0 }}>For <b>{name(req.employee_id)}</b></p>}
      <div className="grid-form">
        <Select label="Type" id="lv-type" value={req.leave_type} onChange={v => setReq({ ...req, leave_type: v })} options={data.types.map(t => [t.code, t.name])} />
        <Field label="From" id="lv-from" type="date" value={req.start_date} onChange={v => setReq({ ...req, start_date: v })} required />
        <Field label="To" id="lv-to" type="date" value={req.end_date} onChange={v => setReq({ ...req, end_date: v })} required />
      </div>
      {req.start_date === req.end_date && <label className="check"><input type="checkbox" checked={!!req.half_day} onChange={e => setReq({ ...req, half_day: e.target.checked })} /> Half day</label>}
      {(() => { const key = `${req.start_date}|${req.end_date}|${req.leave_type}`;
        if (preview?.key !== key && req.start_date && req.end_date && req.end_date >= req.start_date) rpc<number>('leave_days_between', { cid, p_start: req.start_date, p_end: req.end_date, p_counts: data.types.find(t => t.code === req.leave_type)?.counts || 'working' }).then(d => setPreview({ key, days: Number(d) })).catch(() => setPreview({ key, days: workingDays(req.start_date, req.end_date) }));
        const days = req.half_day && req.start_date === req.end_date ? 0.5 : preview?.key === key ? preview.days : workingDays(req.start_date, req.end_date); const b = balanceFor(req.employee_id, req.leave_type);
        return <p className={Number(b?.remaining) < days && b?.entitlement != null ? 'error' : 'muted'} style={{ margin: 0 }}>{days} working days
          {b && b.entitlement != null ? ` · ${b.remaining} of ${b.entitlement} days left this year` : ''}</p>; })()}
      <Field label="Reason (optional)" id="lv-reason" type="textarea" value={req.reason} onChange={v => setReq({ ...req, reason: v })} />
    </FormModal>}
    {type && <FormModal title={`Leave type: ${type.name}`} busy={act.busy} onClose={() => setType(null)}
      onSave={() => act.run(async () => { await q(supabase.from('leave_types').update({ name: type.name, days_per_year: type.days_per_year === '' ? null : Number(type.days_per_year), paid: type.paid, accrual: type.accrual, carry_over_max: Number(type.carry_over_max) || 0, counts: type.counts }).eq('company_id', cid).eq('code', type.code) as any); setType(null); reload(); }, 'Leave type saved')}>
      <Field label="Name" id="lt-name" value={type.name} onChange={v => setType({ ...type, name: v })} required />
      <Field label="Working days per year (blank = no limit)" id="lt-days" type="number" step="0.5" min="0" value={type.days_per_year} onChange={v => setType({ ...type, days_per_year: v })} />
      <div className="grid-form">
        <Select label="Earned" id="lt-acc" value={type.accrual} onChange={v => setType({ ...type, accrual: v })} options={[['upfront', 'All available from 1 January'], ['monthly', 'Earned month by month']]} />
        <Field label="Carry unused days into next year (max)" id="lt-carry" type="number" step="0.5" min="0" value={type.carry_over_max} onChange={v => setType({ ...type, carry_over_max: v })} />
        <Select label="Counts" id="lt-counts" value={type.counts} onChange={v => setType({ ...type, counts: v })} options={[['working', 'Working days (skip weekends and holidays)'], ['calendar', 'Calendar days (e.g. maternity)']]} />
      </div>
      <label className="check"><input type="checkbox" checked={type.paid} onChange={e => setType({ ...type, paid: e.target.checked })} /> Paid leave</label>
    </FormModal>}
    {override && <FormModal title={`${override.leave_name} for ${override.name}, ${year}`} busy={act.busy} onClose={() => setOverride(null)}
      onSave={() => act.run(async () => { await q(supabase.from('leave_entitlements').upsert({ company_id: cid, employee_id: override.employee_id, leave_code: override.leave_code, year, days: Number(override.days) }) as any); setOverride(null); reload(); }, 'Entitlement updated')}>
      <Field label="Days for this year (before any carried over, which is added automatically)" id="ov-days" type="number" step="0.5" min="0" value={override.days} onChange={v => setOverride({ ...override, days: v })} required />
    </FormModal>}
  </>;
}
