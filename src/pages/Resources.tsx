import { useState } from 'react';
import { Link } from 'react-router-dom';
import { q, rpc, supabase } from '../lib/supabase';
import { useSession } from '../lib/session';
import { today } from '../lib/format';
import { downloadCsv } from '../lib/download';
import { tablePdf } from '../lib/pdf';
import { Downloads, Empty, Field, FormModal, Loading, PageHead, Panel, Select, useAction, useLoad } from '../components/ui';

const plusDays = (d: string, n: number) => { const x = new Date(d + 'T00:00:00Z'); x.setUTCDate(x.getUTCDate() + n); return x.toISOString().slice(0, 10); };

export function ResourcesPage() {
  const { cid, company } = useSession();
  const act = useAction();
  const [f, setF] = useState({ skills: '', location: '', start: today(), end: plusDays(today(), 30) });
  const [run, setRun] = useState(f);
  const [assign, setAssign] = useState<any | null>(null);
  const { data: group } = useLoad(() => rpc<any[]>('group_companies', { cid }), [cid]);
  const { data: projects } = useLoad(() => q<any[]>(supabase.from('projects').select('id,name,currency,hourly_rate').eq('company_id', cid).in('status', ['planned', 'active']).order('name') as any), [cid]);
  const { data, error, loading } = useLoad(() => rpc<any[]>('search_resources', {
    cid, p_skills: run.skills.split(',').map(s => s.trim()).filter(Boolean), p_location: run.location, p_start: run.start, p_end: run.end,
  }), [cid, JSON.stringify(run)]);
  const head = ['Name', 'Company', 'Job title', 'Skills', 'Location', 'Booked % (peak)', 'Available %', 'Leave days'];
  const rows = (data || []).map(r => [r.full_name, r.company_name, r.job_title || '', (r.skills || []).join(', '), [r.location, r.country].filter(Boolean).join(', '), String(r.peak_booked), String(r.available), String(r.leave_days)]);

  return <>
    <PageHead title="Resource planner" sub={group && group.length > 1 ? `Searching staff across ${group.length} companies: ${group.map(g => g.name).join(', ')}` : 'Searching this company. Link subsidiaries under Settings → Group of companies to search across them.'}>
      <Downloads pdf={() => tablePdf({ company: company!, title: 'Available staff', subtitle: `${run.start} to ${run.end}`, head, body: rows, rightAlign: [5, 6, 7], landscape: true, filename: 'resource-search',
        notes: run.skills ? 'Skills searched: ' + run.skills : undefined })} csv={() => downloadCsv('resource-search', head, rows)} />
    </PageHead>
    <Panel pad>
      <form className="filters" onSubmit={e => { e.preventDefault(); setRun(f); }}>
        <div className="field" style={{ width: 240 }}><label htmlFor="rs-skills">Skills (comma separated)</label><input id="rs-skills" value={f.skills} onChange={e => setF({ ...f, skills: e.target.value })} placeholder="e.g. SAP, AutoCAD, French" /></div>
        <div className="field" style={{ width: 170 }}><label htmlFor="rs-loc">Town or country</label><input id="rs-loc" value={f.location} onChange={e => setF({ ...f, location: e.target.value })} placeholder="e.g. Kumasi, Togo" /></div>
        <Field label="From" id="rs-from" type="date" value={f.start} onChange={v => setF({ ...f, start: v })} />
        <Field label="To" id="rs-to" type="date" value={f.end} onChange={v => setF({ ...f, end: v })} />
        <button className="btn primary" type="submit" style={{ marginBottom: 2 }}>Search</button>
      </form>
    </Panel>
    <Loading error={error} loading={loading && !data} />
    {data && <Panel title={`${data.length} ${data.length === 1 ? "person" : "people"}`}>{data.length ? <div className="scroll"><table>
      <thead><tr><th>Person</th><th>Skills</th><th>Location</th><th style={{ width: 170 }}>Availability</th><th></th></tr></thead>
      <tbody>{data.map(r => <tr key={r.employee_id}>
        <td><b>{r.full_name}</b><br /><span className="muted">{r.job_title}{r.company_id !== cid ? ' · ' + r.company_name : ''}</span></td>
        <td className="wrap-cell">{(r.skills || []).map((s: string) => <span key={s} className="pill" style={{ marginRight: 4, marginBottom: 2 }}>{s}</span>)}</td>
        <td>{[r.location, r.country].filter(Boolean).join(', ')}</td>
        <td><div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
          <div style={{ flex: 1, height: 8, background: 'var(--sunk)', borderRadius: 4, overflow: 'hidden' }}><div style={{ width: r.available + '%', height: '100%', background: r.available >= 50 ? 'var(--good)' : r.available > 0 ? 'var(--warn)' : 'var(--bad)' }} /></div>
          <span className="num" style={{ fontSize: 12 }}>{r.available}%</span></div>
          {r.leave_days > 0 && <span className="muted" style={{ fontSize: 12 }}>{r.leave_days} days on leave</span>}</td>
        <td className="r"><button className="btn small primary" type="button" disabled={!projects?.length} onClick={() => setAssign({ r, project_id: projects![0].id, start: run.start, end: run.end, pct: String(Math.max(10, Math.min(100, r.available || 100))), role: '', bill_rate: '', status: 'confirmed' })}>Assign</button></td></tr>)}</tbody>
    </table></div> : <Empty>No one matches. Add skills and locations on each employee's record.</Empty>}</Panel>}
    <p className="muted" style={{ margin: 0 }}>Availability is 100% less the highest total allocation on any day in the period. Salaries are never shown here.</p>

    {assign && projects && <FormModal title={`Assign ${assign.r.full_name}`} submit="Assign to project" busy={act.busy} onClose={() => setAssign(null)}
      onSave={() => act.run(async () => {
        await rpc('assign_resource', { p_project: assign.project_id, p_employee: assign.r.employee_id, p_start: assign.start, p_end: assign.end || null, p_pct: Number(assign.pct),
          p_role: assign.role || null, p_bill_rate: assign.bill_rate === '' ? null : Number(assign.bill_rate), p_status: assign.status });
        setAssign(null); setRun({ ...run });
      }, 'Assigned. They can now log time and expenses on this project.')}>
      <Select label="Project" id="as-proj" value={assign.project_id} onChange={v => setAssign({ ...assign, project_id: v })} options={projects.map(p => [p.id, `${p.name} (${p.currency})`])} />
      <div className="grid-form">
        <Field label="Role on project" id="as-role" value={assign.role} onChange={v => setAssign({ ...assign, role: v })} placeholder="e.g. Site engineer" />
        <Field label="From" id="as-from" type="date" value={assign.start} onChange={v => setAssign({ ...assign, start: v })} required />
        <Field label="To" id="as-to" type="date" value={assign.end} onChange={v => setAssign({ ...assign, end: v })} />
        <Field label="Allocation %" id="as-pct" type="number" step="5" min="5" max="100" value={assign.pct} onChange={v => setAssign({ ...assign, pct: v })} required />
        <Field label={`Bill rate per hour (${projects.find(p => p.id === assign.project_id)?.currency})`} id="as-rate" type="number" step="0.01" min="0" value={assign.bill_rate} onChange={v => setAssign({ ...assign, bill_rate: v })} />
        <Select label="Status" id="as-status" value={assign.status} onChange={v => setAssign({ ...assign, status: v })} options={[['confirmed', 'Confirmed'], ['proposed', 'Proposed (tentative)']]} />
      </div>
      <p className="muted" style={{ margin: 0, fontSize: 13 }}>Leave the bill rate empty to use the project's standard rate. <Link to="/projects">Projects</Link></p>
    </FormModal>}
  </>;
}
