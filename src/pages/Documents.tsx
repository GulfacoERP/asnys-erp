import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { q, rpc, supabase } from '../lib/supabase';
import { useSession } from '../lib/session';
import { longDate } from '../lib/format';
import { downloadCsv } from '../lib/download';
import { Empty, Loading, PageHead, Panel, Select, useAction, useLoad } from '../components/ui';
import { Pager, SearchBox, usePaged } from '../components/paging';
import { GROUPS, REV_STATUS, RevStatus, openRevision } from '../components/ProjectDocs';

/** Every project document in one place: search by number, title, file name or discipline; filter by type, status or project. */
export function DocumentsPage() {
  const { cid } = useSession();
  const nav = useNavigate();
  const act = useAction();
  const [search, setSearch] = useState('');
  const [type, setType] = useState('');
  const [status, setStatus] = useState('');
  const [project, setProject] = useState('');
  const { data: meta } = useLoad(async () => ({
    types: await q<any[]>(supabase.from('doc_types').select('code,name,grp').order('sort') as any),
    projects: await q<any[]>(supabase.from('projects').select('id,number,name').eq('company_id', cid).eq('is_template', false).order('name') as any),
    expiring: await rpc<any[]>('doc_expiry_alerts', { cid, p_days: 30 }).catch(() => [] as any[]),
  }), [cid]);
  const args = (a: number, b: number) => ({ cid, p_search: search || null, p_type: type || null, p_status: status || null, p_project: project || null, p_limit: b - a + 1, p_offset: a });
  const pg = usePaged(async (a, b) => { const rows = await rpc<any[]>('search_documents', args(a, b)); return { rows, total: Number(rows[0]?.total || 0) }; }, [cid, search, type, status, project]);
  return <>
    <PageHead title="Documents" sub="Drawings, method statements, permits, minutes and handover files across every project.">
      <button className="btn" type="button" onClick={() => act.run(async () => { const rows = await rpc<any[]>('search_documents', args(0, 4999));
        downloadCsv('documents', ['Number', 'Title', 'Type', 'Project', 'Rev', 'Status', 'Updated', 'Expires'], rows.map(r => [r.number, r.title, r.type_name, r.project, r.rev || '', r.status ? REV_STATUS[r.status]?.[0] : 'No file', r.updated_at.slice(0, 10), r.expires_on || ''])); })}>Download CSV</button>
    </PageHead>
    {meta && meta.expiring.length > 0 && <Panel title={`Expiring or expired (${meta.expiring.length})`}><div className="scroll"><table><tbody>{meta.expiring.map(e => <tr key={e.doc_id} className="click" onClick={() => nav('/projects/' + e.project_id)}>
      <td className="num">{e.number}</td><td>{e.title} <span className="muted">· {e.doc_type}</span></td><td>{e.project}</td>
      <td className="num" style={{ color: e.days_left < 0 ? 'var(--bad)' : 'var(--warn)' }}>{e.days_left < 0 ? `Expired ${longDate(e.expires_on)}` : `${e.days_left} days left`}</td></tr>)}</tbody></table></div></Panel>}
    <div className="filters">
      <SearchBox value={search} onChange={setSearch} placeholder="Number, title, file or discipline" id="doc-search" />
      {meta && <Select label="Type" id="doc-type" value={type} onChange={setType} options={[['', 'All'], ...GROUPS.map(([g, l]) => [g, 'All ' + l.toLowerCase()] as [string, string]), ...meta.types.map(t => [t.code, t.name] as [string, string])]} />}
      <Select label="Status" id="doc-status" value={status} onChange={setStatus} options={[['', 'Any'], ...Object.entries(REV_STATUS).map(([k, v]) => [k, v[0]] as [string, string]), ['none', 'No file yet']]} />
      {meta && <Select label="Project" id="doc-proj" value={project} onChange={setProject} options={[['', 'All projects'], ...meta.projects.map(p => [p.id, `${p.number || ''} ${p.name}`] as [string, string])]} />}
    </div>
    <Loading error={pg.error} loading={pg.loading && !pg.data} />
    {pg.data && <Panel>{pg.rows.length ? <div className="scroll"><table>
      <thead><tr><th>Number</th><th>Title</th><th>Project</th><th>Rev</th><th>Status</th><th>Updated</th><th></th></tr></thead>
      <tbody>{pg.rows.map(r => <tr key={r.doc_id}><td className="num"><b>{r.number}</b></td><td className="wrap-cell">{r.title}{r.confidential && <span className="pill" style={{ marginLeft: 6 }}>Confidential</span>}<br /><span className="muted" style={{ fontSize: 12 }}>{r.type_name}</span></td>
        <td><button className="btn ghost small" style={{ padding: 0 }} type="button" onClick={() => nav('/projects/' + r.project_id)}>{r.project}</button></td>
        <td className="num">{r.rev || ''}</td><td><RevStatus s={r.status} /></td><td className="num">{r.updated_at.slice(0, 10)}</td>
        <td className="r">{r.revision_id && <button className="btn small" type="button" onClick={() => act.run(async () => { const rev = await q<any>(supabase.from('doc_revisions').select('id,storage_path').eq('id', r.revision_id).single() as any); if (!rev.storage_path) throw new Error('No file on this revision.'); await openRevision(rev); })}>Open</button>}</td></tr>)}</tbody>
    </table></div> : <Empty>No documents match.</Empty>}<Pager {...pg} noun="documents" /></Panel>}
  </>;
}
