import { useState } from 'react';
import { q, supabase } from '../lib/supabase';
import { useSession } from '../lib/session';
import { longDate, today } from '../lib/format';
import { downloadCsv } from '../lib/download';
import { appraisalPdf, tablePdf } from '../lib/pdf';
import { ConfirmButton, Downloads, Empty, Field, FormModal, Loading, PageHead, Panel, Select, Status, useAction, useLoad } from '../components/ui';

const STAGES: [string, string][] = [['applied', 'Applied'], ['screening', 'Screening'], ['interview', 'Interview'], ['offer', 'Offer'], ['hired', 'Hired'], ['rejected', 'Rejected']];
const stageLabel = (s: string) => STAGES.find(x => x[0] === s)?.[1] || s;

export function RecruitmentPage() {
  const { cid, company, can } = useSession();
  const act = useAction();
  const [sel, setSel] = useState<string>('');
  const [job, setJob] = useState<any | null>(null);
  const [app, setApp] = useState<any | null>(null);
  const [hire, setHire] = useState<any | null>(null);
  const { data, error, loading, reload } = useLoad(async () => {
    const [jobs, apps] = await Promise.all([
      q<any[]>(supabase.from('job_openings').select('*').eq('company_id', cid).order('created_at', { ascending: false }) as any),
      q<any[]>(supabase.from('applicants').select('*').eq('company_id', cid).order('created_at', { ascending: false }) as any),
    ]);
    return { jobs, apps };
  }, [cid]);
  const current = data?.jobs.find(j => j.id === sel) || data?.jobs[0];
  const apps = (data?.apps || []).filter(a => a.opening_id === current?.id);
  const head = ['Applicant', 'Email', 'Phone', 'Stage', 'Rating', 'Notes'];
  const rows = apps.map(a => [a.full_name, a.email || '', a.phone || '', stageLabel(a.stage), a.rating ? String(a.rating) : '', a.notes || '']);
  const write = can('hr');

  const saveJob = () => act.run(async () => {
    const row = { title: job.title, department: job.department || null, location: job.location || null, employment_type: job.employment_type || null, description: job.description || null, closing_date: job.closing_date || null, status: job.status };
    if (job.id) await q(supabase.from('job_openings').update(row).eq('id', job.id) as any);
    else { const r = await q<any>(supabase.from('job_openings').insert({ ...row, company_id: cid }).select('id').single() as any); setSel(r.id); }
    setJob(null); reload();
  }, 'Job opening saved');
  const saveApp = () => act.run(async () => {
    const row = { full_name: app.full_name, email: app.email || null, phone: app.phone || null, stage: app.stage, rating: app.rating ? Number(app.rating) : null, notes: app.notes || null };
    if (app.id) await q(supabase.from('applicants').update(row).eq('id', app.id) as any);
    else await q(supabase.from('applicants').insert({ ...row, opening_id: current.id, company_id: cid }) as any);
    setApp(null); reload();
  }, 'Applicant saved');
  const doHire = () => act.run(async () => {
    const emp = await q<any>(supabase.from('employees').insert({ company_id: cid, full_name: hire.full_name, email: hire.email || null, phone: hire.phone || null,
      job_title: current.title, department: current.department, hire_date: hire.hire_date, basic_salary: Number(hire.basic) || 0, allowances: Number(hire.allowances) || 0 }).select('id').single() as any);
    await q(supabase.from('applicants').update({ stage: 'hired', employee_id: emp.id }).eq('id', hire.id) as any);
    setHire(null); reload();
  }, 'Hired — added to Employees. Complete their SSNIT and bank details there.');

  return <>
    <PageHead title="Recruitment" sub="Job openings and applicants. Hiring someone adds them to Employees.">
      {current && <Downloads pdf={() => tablePdf({ company: company!, title: `Applicants: ${current.title}`, head, body: rows, filename: `applicants-${current.title}` })} csv={() => downloadCsv(`applicants-${current.title}`, head, rows)} />}
      {write && <button className="btn primary" type="button" onClick={() => setJob({ title: '', department: '', location: '', employment_type: 'Full-time', description: '', closing_date: '', status: 'open' })}>New job opening</button>}
    </PageHead>
    <Loading error={error} loading={loading && !data} />
    {data && !data.jobs.length && <Empty>No job openings yet.</Empty>}
    {data && current && <div className="two" style={{ gridTemplateColumns: 'minmax(0,1fr) minmax(0,2fr)' }}>
      <Panel title="Openings"><div className="scroll"><table><tbody>{data.jobs.map(j => <tr key={j.id} className="click" onClick={() => setSel(j.id)} style={j.id === current.id ? { background: 'var(--accent-soft)' } : undefined}>
        <td><b>{j.title}</b><br /><span className="muted">{[j.department, j.closing_date && 'closes ' + j.closing_date].filter(Boolean).join(' · ')}</span></td>
        <td className="r"><span className={'pill ' + (j.status === 'open' ? 'good' : '')}>{j.status}</span><br /><span className="muted num">{data.apps.filter(a => a.opening_id === j.id).length} applicants</span></td></tr>)}</tbody></table></div></Panel>
      <Panel title={current.title} actions={write && <><button className="btn small" type="button" onClick={() => setJob({ ...current, department: current.department || '', location: current.location || '', description: current.description || '', closing_date: current.closing_date || '' })}>Edit opening</button>
        <button className="btn small primary" type="button" onClick={() => setApp({ full_name: '', email: '', phone: '', stage: 'applied', rating: '', notes: '' })}>Add applicant</button></>}>
        {current.description && <div className="body muted" style={{ whiteSpace: 'pre-wrap' }}>{current.description}</div>}
        {apps.length ? <div className="scroll"><table>
          <thead><tr><th>Applicant</th><th>Stage</th><th className="r">Rating</th><th></th></tr></thead>
          <tbody>{apps.map(a => <tr key={a.id}>
            <td><b>{a.full_name}</b><br /><span className="muted">{[a.phone, a.email].filter(Boolean).join(' · ')}</span></td>
            <td>{write && a.stage !== 'hired' ? <select aria-label={`Stage for ${a.full_name}`} value={a.stage} style={{ width: 'auto' }} onChange={e => act.run(async () => { await q(supabase.from('applicants').update({ stage: e.target.value }).eq('id', a.id) as any); reload(); })}>
              {STAGES.filter(s => s[0] !== 'hired').map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select> : <span className="pill good">{stageLabel(a.stage)}</span>}</td>
            <td className="r num">{a.rating ? '★'.repeat(a.rating) : ''}</td>
            <td className="r">{write && <span className="actions">
              <button className="btn small ghost" type="button" onClick={() => setApp({ ...a, email: a.email || '', phone: a.phone || '', rating: a.rating || '', notes: a.notes || '' })}>Edit</button>
              {a.stage === 'offer' && <button className="btn small primary" type="button" onClick={() => setHire({ ...a, hire_date: today(), basic: '', allowances: '' })}>Hire</button>}</span>}</td></tr>)}</tbody>
        </table></div> : <Empty>No applicants yet.</Empty>}
      </Panel>
    </div>}
    {job && <FormModal title={job.id ? 'Edit job opening' : 'New job opening'} busy={act.busy} onClose={() => setJob(null)} onSave={saveJob}>
      <Field label="Job title" id="jb-title" value={job.title} onChange={v => setJob({ ...job, title: v })} required />
      <div className="grid-form">
        <Field label="Department" id="jb-dept" value={job.department} onChange={v => setJob({ ...job, department: v })} />
        <Field label="Location" id="jb-loc" value={job.location} onChange={v => setJob({ ...job, location: v })} />
        <Select label="Type" id="jb-type" value={job.employment_type} onChange={v => setJob({ ...job, employment_type: v })} options={[['Full-time', 'Full-time'], ['Part-time', 'Part-time'], ['Contract', 'Contract'], ['National service', 'National service'], ['Internship', 'Internship']]} />
        <Field label="Closing date" id="jb-close" type="date" value={job.closing_date} onChange={v => setJob({ ...job, closing_date: v })} />
        <Select label="Status" id="jb-status" value={job.status} onChange={v => setJob({ ...job, status: v })} options={[['open', 'Open'], ['closed', 'Closed'], ['filled', 'Filled']]} />
      </div>
      <Field label="Description and requirements" id="jb-desc" type="textarea" value={job.description} onChange={v => setJob({ ...job, description: v })} />
    </FormModal>}
    {app && <FormModal title={app.id ? 'Edit applicant' : 'Add applicant'} busy={act.busy} onClose={() => setApp(null)} onSave={saveApp}
      danger={app.id && <ConfirmButton className="btn danger" label="Delete" confirm="Delete?" onConfirm={() => act.run(async () => { await q(supabase.from('applicants').delete().eq('id', app.id) as any); setApp(null); reload(); })} />}>
      <Field label="Full name" id="ap-name" value={app.full_name} onChange={v => setApp({ ...app, full_name: v })} required />
      <div className="grid-form">
        <Field label="Phone" id="ap-phone" value={app.phone} onChange={v => setApp({ ...app, phone: v })} />
        <Field label="Email" id="ap-email" type="email" value={app.email} onChange={v => setApp({ ...app, email: v })} />
        <Select label="Stage" id="ap-stage" value={app.stage} onChange={v => setApp({ ...app, stage: v })} options={STAGES.filter(s => s[0] !== 'hired')} />
        <Select label="Rating" id="ap-rating" value={String(app.rating)} onChange={v => setApp({ ...app, rating: v })} options={[['', 'Not rated'], ['1', '1'], ['2', '2'], ['3', '3'], ['4', '4'], ['5', '5']]} />
      </div>
      <Field label="Interview notes" id="ap-notes" type="textarea" value={app.notes} onChange={v => setApp({ ...app, notes: v })} />
    </FormModal>}
    {hire && <FormModal title={`Hire ${hire.full_name}`} submit="Hire and add to Employees" busy={act.busy} onClose={() => setHire(null)} onSave={doHire}>
      <p className="muted" style={{ margin: 0 }}>{current?.title}{current?.department ? ', ' + current.department : ''}</p>
      <div className="grid-form">
        <Field label="Start date" id="hr-date" type="date" value={hire.hire_date} onChange={v => setHire({ ...hire, hire_date: v })} required />
        <Field label="Basic salary (GH₵/month)" id="hr-basic" type="number" step="0.01" min="0" value={hire.basic} onChange={v => setHire({ ...hire, basic: v })} required />
        <Field label="Allowances (GH₵/month)" id="hr-allow" type="number" step="0.01" min="0" value={hire.allowances} onChange={v => setHire({ ...hire, allowances: v })} />
      </div>
    </FormModal>}
  </>;
}

export function AppraisalsPage() {
  const { cid, company, can } = useSession();
  const act = useAction();
  const [edit, setEdit] = useState<any | null>(null);
  const { data, error, loading, reload } = useLoad(async () => {
    const [list, staff] = await Promise.all([
      q<any[]>(supabase.from('appraisals').select('*, emp:employees(full_name,job_title,department)').eq('company_id', cid).order('review_date', { ascending: false }) as any),
      q<any[]>(supabase.from('employees').select('id,full_name').eq('company_id', cid).eq('status', 'active').order('full_name') as any),
    ]);
    return { list, staff };
  }, [cid]);
  const head = ['Employee', 'Period', 'Review date', 'Reviewer', 'Rating', 'Status'];
  const rows = (data?.list || []).map(a => [a.emp?.full_name, a.period_label, a.review_date, a.reviewer || '', a.rating ? String(a.rating) : '', a.status]);
  const set = (k: string) => (v: any) => setEdit({ ...edit, [k]: v });
  const save = () => act.run(async () => {
    const row: any = { ...edit }; delete row.emp; delete row.id; delete row.created_at;
    row.rating = row.rating ? Number(row.rating) : null;
    if (edit.id) await q(supabase.from('appraisals').update(row).eq('id', edit.id) as any);
    else await q(supabase.from('appraisals').insert({ ...row, company_id: cid }) as any);
    setEdit(null); reload();
  }, 'Appraisal saved');

  return <>
    <PageHead title="Appraisals" sub="Performance reviews with ratings, goals and a signable PDF.">
      <Downloads pdf={() => tablePdf({ company: company!, title: 'Appraisals', head, body: rows, rightAlign: [4], filename: 'appraisals' })} csv={() => downloadCsv('appraisals', head, rows)} />
      {can('hr') && <button className="btn primary" type="button" disabled={!data?.staff.length} onClick={() => setEdit({ employee_id: data!.staff[0].id, period_label: `${today().slice(0, 4)} annual`, review_date: today(), reviewer: '', rating: '', achievements: '', strengths: '', improvements: '', goals: '', employee_comments: '', status: 'draft' })}>New appraisal</button>}
    </PageHead>
    <Loading error={error} loading={loading && !data} />
    {data && <Panel>{data.list.length ? <div className="scroll"><table>
      <thead><tr><th>Employee</th><th>Period</th><th>Review date</th><th>Rating</th><th>Status</th><th></th></tr></thead>
      <tbody>{data.list.map(a => <tr key={a.id}>
        <td>{can('hr') ? <button className="btn ghost small" style={{ padding: 0, fontWeight: 600 }} type="button" onClick={() => setEdit(Object.fromEntries(Object.entries(a).map(([k, v]) => [k, v ?? ''])))}>{a.emp?.full_name}</button> : a.emp?.full_name}</td>
        <td>{a.period_label}</td><td className="num">{longDate(a.review_date)}</td><td className="num">{a.rating ? `${a.rating} / 5` : '—'}</td>
        <td><Status s={a.status === 'completed' ? 'done' : 'draft'} /></td>
        <td className="r"><button className="btn small" type="button" onClick={() => appraisalPdf(company!, a, a.emp)}>PDF</button></td></tr>)}</tbody>
    </table></div> : <Empty>No appraisals yet.</Empty>}</Panel>}
    {edit && data && <FormModal title={edit.id ? 'Edit appraisal' : 'New appraisal'} busy={act.busy} onClose={() => setEdit(null)} onSave={save}
      danger={edit.id && <ConfirmButton className="btn danger" label="Delete" confirm="Delete?" onConfirm={() => act.run(async () => { await q(supabase.from('appraisals').delete().eq('id', edit.id) as any); setEdit(null); reload(); })} />}>
      <div className="grid-form">
        <Select label="Employee" id="ar-emp" value={edit.employee_id} onChange={set('employee_id')} options={data.staff.map(s => [s.id, s.full_name])} />
        <Field label="Period" id="ar-period" value={edit.period_label} onChange={set('period_label')} required />
        <Field label="Review date" id="ar-date" type="date" value={edit.review_date} onChange={set('review_date')} required />
        <Field label="Reviewer" id="ar-reviewer" value={edit.reviewer} onChange={set('reviewer')} />
        <Select label="Overall rating" id="ar-rating" value={String(edit.rating)} onChange={set('rating')} options={[['', 'Not rated'], ['1', '1 — Below expectations'], ['2', '2 — Needs improvement'], ['3', '3 — Meets expectations'], ['4', '4 — Exceeds expectations'], ['5', '5 — Outstanding']]} />
        <Select label="Status" id="ar-status" value={edit.status} onChange={set('status')} options={[['draft', 'Draft'], ['completed', 'Completed']]} />
      </div>
      <Field label="Achievements this period" id="ar-ach" type="textarea" value={edit.achievements} onChange={set('achievements')} />
      <Field label="Strengths" id="ar-str" type="textarea" value={edit.strengths} onChange={set('strengths')} />
      <Field label="Areas to improve" id="ar-imp" type="textarea" value={edit.improvements} onChange={set('improvements')} />
      <Field label="Goals for next period" id="ar-goals" type="textarea" value={edit.goals} onChange={set('goals')} />
      <Field label="Employee comments" id="ar-com" type="textarea" value={edit.employee_comments} onChange={set('employee_comments')} />
    </FormModal>}
  </>;
}
