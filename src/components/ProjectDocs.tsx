import { Fragment, useState } from 'react';
import { q, rpc, supabase } from '../lib/supabase';
import { useSession } from '../lib/session';
import { longDate, today } from '../lib/format';
import { downloadCsv } from '../lib/download';
import { riskAssessmentPdf, transmittalPdf } from '../lib/pdf';
import { ConfirmButton, Empty, Field, FormModal, Modal, Panel, Select, useAction, useLoad, useToast } from './ui';

export const GROUPS: [string, string][] = [['contract', 'Contract and scope'], ['engineering', 'Engineering'], ['quality', 'Quality'], ['hse', 'Health and safety'], ['site', 'Site'], ['handover', 'Handover'], ['other', 'Other']];
export const REV_STATUS: Record<string, [string, string]> = {
  draft: ['Draft', ''], in_review: ['In internal review', 'warn'], ready: ['Ready to send', 'warn'], submitted: ['With the client', 'warn'],
  approved: ['Approved', 'good'], approved_comments: ['Approved with comments', 'good'], rejected: ['Rejected: revise', 'bad'], for_info: ['For information', ''],
};
export const RevStatus = ({ s }: { s?: string | null }) => s ? <span className={'pill ' + (REV_STATUS[s]?.[1] || '')}>{REV_STATUS[s]?.[0] || s}</span> : <span className="pill">No file yet</span>;
const PURPOSES: [string, string][] = [['for_approval', 'For approval'], ['for_comment', 'For comment'], ['for_information', 'For information'], ['for_construction', 'Issued for construction'], ['for_record', 'For record']];
const RESPONSES: [string, string][] = [['approved', 'Approved'], ['approved_comments', 'Approved with comments'], ['rejected', 'Rejected: revise and resubmit'], ['noted', 'Noted']];
const band = (n: number) => n >= 15 ? ['High', 'bad'] : n >= 5 ? ['Medium', 'warn'] : ['Low', 'good'];
export const RiskChip = ({ l, s }: { l?: number | null; s?: number | null }) => { if (!l || !s) return <span className="muted">—</span>; const [t, c] = band(l * s); return <span className={'pill ' + c}>{l}×{s} = {l * s} {t}</span>; };

/** Shrink phone photos before upload (long side 2000 px, JPEG). Other files go up as they are. */
async function prepare(file: File): Promise<File> {
  if (!file.type.startsWith('image/') || file.type === 'image/gif' || file.size < 1.5e6) return file;
  try {
    const img = await createImageBitmap(file);
    const k = Math.min(1, 2000 / Math.max(img.width, img.height));
    const c = document.createElement('canvas'); c.width = Math.round(img.width * k); c.height = Math.round(img.height * k);
    c.getContext('2d')!.drawImage(img, 0, 0, c.width, c.height);
    const blob: Blob = await new Promise(res => c.toBlob(b => res(b!), 'image/jpeg', 0.8));
    return blob.size < file.size ? new File([blob], file.name.replace(/\.\w+$/, '') + '.jpg', { type: 'image/jpeg' }) : file;
  } catch { return file; }
}
export async function uploadDocFile(companyId: string, projectId: string, f: File) {
  const file = await prepare(f);
  if (file.size > 50e6) throw new Error(`${file.name} is larger than 50 MB. Split it or reduce its size.`);
  const path = `${companyId}/${projectId}/${crypto.randomUUID()}-${file.name.replace(/[^\w.-]+/g, '_')}`;
  const { error } = await supabase.storage.from('project-docs').upload(path, file);
  if (error) throw new Error('Upload failed: ' + error.message);
  return { path, name: file.name, size: file.size, mime: file.type || null };
}
export async function openRevision(r: any) {
  await rpc('log_doc_access', { p_rev: r.id });
  const { data, error } = await supabase.storage.from('project-docs').createSignedUrl(r.storage_path, 600);
  if (error) throw error;
  window.open(data.signedUrl, '_blank', 'noopener');
}
const current = (d: any) => (d.revisions || []).slice().sort((a: any, b: any) => b.seq - a.seq)[0];

type Sub = 'register' | 'transmittals' | 'risks' | 'required';
export function ProjectDocuments({ p, manage, tasks, team, templateOnly }: { p: any; manage: boolean; tasks: any[]; team: any[] | null; templateOnly?: boolean }) {
  const { cid } = useSession();
  const act = useAction();
  const [sub, setSub] = useState<Sub>(templateOnly ? 'required' : 'register');
  const [grp, setGrp] = useState('');
  const [search, setSearch] = useState('');
  const [doc, setDoc] = useState<string | null>(null);
  const [add, setAdd] = useState<any | null>(null);
  const locked = ['closed', 'cancelled'].includes(p.status);
  const { data, reload } = useLoad(async () => {
    const [types, docs, onTeam, check] = await Promise.all([
      q<any[]>(supabase.from('doc_types').select('*').order('sort') as any),
      q<any[]>(supabase.from('doc_register').select('*, revisions:doc_revisions(id,seq,rev,status,file_name,storage_path,created_at,superseded_at)').eq('project_id', p.id).order('doc_type').order('seq') as any),
      rpc<boolean>('on_project_team', { pid: p.id }).catch(() => false),
      rpc<any[]>('project_doc_check', { p_project: p.id }).catch(() => [] as any[]),
    ]);
    return { types, docs, onTeam, check };
  }, [p.id]);
  if (!data) return null;
  const typeOf = (c: string) => data.types.find(t => t.code === c);
  const canWork = !locked && (data.onTeam || manage);
  const list = data.docs.filter(d => (!grp || typeOf(d.doc_type)?.grp === grp) && (!search || (d.number + ' ' + d.title + ' ' + (d.discipline || '')).toLowerCase().includes(search.toLowerCase())));
  const missing = data.check.filter(c => !c.satisfied);
  const head = ['Number', 'Title', 'Type', 'Discipline', 'Rev', 'Status', 'Updated', 'Expires'];
  const rows = list.map(d => { const r = current(d); return [d.number, d.title, typeOf(d.doc_type)?.name, d.discipline || '', r?.rev || '', r ? REV_STATUS[r.status]?.[0] : 'No file', (r?.created_at || d.created_at).slice(0, 10), d.expires_on || '']; });

  if (templateOnly) return <Required p={p} manage={manage} types={data.types} check={data.check} onChange={reload} />;
  return <>
    <div className="actions" style={{ overflowX: 'auto', flexWrap: 'nowrap' }}>
      {([['register', `Register (${data.docs.length})`], ['transmittals', 'Transmittals'], ['risks', 'Risk assessments'], ['required', `Required documents${missing.length ? ` (${missing.length} missing)` : ''}`]] as [Sub, string][]).map(([k, l]) =>
        <button key={k} type="button" className={'btn small' + (sub === k ? ' primary' : ' ghost')} onClick={() => setSub(k)}>{l}</button>)}
    </div>
    {sub === 'register' && <Panel title={<div className="actions"><h2>Document register</h2></div>} actions={<>
      <button className="btn small" type="button" onClick={() => downloadCsv(`document-register-${p.number || p.name}`, head, rows)}>Register CSV</button>
      {canWork && <button className="btn small primary" type="button" onClick={() => setAdd({ doc_type: 'shop_drawing', title: '', discipline: '', expires_on: '', confidential: false, task_id: '', file: null, for_info: false })}>New document</button>}</>}>
      <div className="body filters" style={{ borderBottom: '1px solid var(--line)' }}>
        <Select label="Group" id="dr-grp" value={grp} onChange={setGrp} options={[['', 'All documents'], ...GROUPS]} />
        <Field label="Find" id="dr-find" value={search} onChange={setSearch} placeholder="Number, title or discipline" />
      </div>
      {list.length ? <div className="scroll"><table>
        <thead><tr><th>Number</th><th>Title</th><th>Type</th><th>Rev</th><th>Status</th><th>Updated</th></tr></thead>
        <tbody>{list.map(d => { const r = current(d); const exp = d.expires_on && d.expires_on <= new Date(Date.now() + 30 * 864e5).toISOString().slice(0, 10);
          return <tr key={d.id} className="click" tabIndex={0} onClick={() => setDoc(d.id)} onKeyDown={e => e.key === 'Enter' && setDoc(d.id)}>
            <td className="num"><b>{d.number}</b></td>
            <td className="wrap-cell">{d.title}{d.confidential && <span className="pill" style={{ marginLeft: 6 }}>Confidential</span>}
              {d.discipline && <span className="muted"> · {d.discipline}</span>}
              {d.expires_on && <><br /><span style={{ fontSize: 12, color: exp ? 'var(--bad)' : 'var(--muted)' }}>{d.expires_on < today() ? 'Expired' : 'Expires'} {longDate(d.expires_on)}</span></>}</td>
            <td>{typeOf(d.doc_type)?.name}</td><td className="num">{r?.rev || ''}</td><td><RevStatus s={r?.status} /></td><td className="num">{(r?.created_at || d.created_at).slice(0, 10)}</td></tr>; })}</tbody>
      </table></div> : <Empty>{data.docs.length ? 'No documents match.' : 'No documents yet. Add the scope, drawings, method statements, permits, minutes and handover files here. Each gets a number and keeps every revision.'}</Empty>}
    </Panel>}
    {sub === 'transmittals' && <Transmittals p={p} docs={data.docs} types={data.types} canWork={canWork} onChange={reload} />}
    {sub === 'risks' && <RiskAssessments p={p} manage={manage} canWork={canWork} tasks={tasks} team={team} />}
    {sub === 'required' && <Required p={p} manage={manage && !locked} types={data.types} check={data.check} onChange={reload} />}

    {doc && <DocModal docId={doc} p={p} manage={manage} canWork={canWork} types={data.types} onClose={() => setDoc(null)} onChange={reload} />}
    {add && <FormModal title="New document" submit={add.file ? 'Add and upload' : 'Add'} busy={act.busy} onClose={() => setAdd(null)} onSave={() => act.run(async () => {
      const d = await q<any>(supabase.from('doc_register').insert({ company_id: cid, project_id: p.id, doc_type: add.doc_type, title: add.title, discipline: add.discipline || null,
        expires_on: add.expires_on || null, confidential: add.confidential, task_id: add.task_id || null, seq: 0, number: '' }).select('id').single() as any);
      if (add.file) { const f = await uploadDocFile(p.company_id, p.id, add.file); await rpc('add_revision', { p_doc: d.id, p_path: f.path, p_name: f.name, p_size: f.size, p_mime: f.mime, p_notes: null, p_issue: false, p_for_info: add.for_info }); }
      setAdd(null); reload(); setDoc(d.id); }, 'Document added')}>
      <div className="grid-form">
        <div className="field"><label htmlFor="nd-type">Type</label><select id="nd-type" value={add.doc_type} onChange={e => setAdd({ ...add, doc_type: e.target.value })}>
          {GROUPS.map(([g, gl]) => <optgroup key={g} label={gl}>{data.types.filter(t => t.grp === g).map(t => <option key={t.code} value={t.code}>{t.name} ({t.prefix})</option>)}</optgroup>)}</select></div>
        <Field label="Discipline" id="nd-disc" value={add.discipline} onChange={v => setAdd({ ...add, discipline: v })} placeholder="civil, electrical, mechanical…" />
        {typeOf(add.doc_type)?.has_expiry && <Field label="Expires on" id="nd-exp" type="date" value={add.expires_on} onChange={v => setAdd({ ...add, expires_on: v })} />}
        {tasks.length > 0 && <Select label="For task" id="nd-task" value={add.task_id} onChange={v => setAdd({ ...add, task_id: v })} options={[['', '—'], ...tasks.map(t => [t.id, t.title] as [string, string])]} />}
      </div>
      <Field label="Title" id="nd-title" value={add.title} onChange={v => setAdd({ ...add, title: v })} placeholder="e.g. 33 kV switchgear foundation" required />
      <div className="field"><label htmlFor="nd-file">File (optional now)</label><input id="nd-file" type="file" onChange={e => setAdd({ ...add, file: e.target.files?.[0] || null })} /></div>
      {add.file && <label className="check"><input type="checkbox" checked={add.for_info} onChange={e => setAdd({ ...add, for_info: e.target.checked })} /> File for information only (no review needed, e.g. photos, minutes)</label>}
      <label className="check"><input type="checkbox" checked={add.confidential} onChange={e => setAdd({ ...add, confidential: e.target.checked })} /> Confidential (only the project manager, accountants and owners can see it)</label>
      <p className="muted" style={{ margin: 0, fontSize: 13 }}>Number: {p.number}-{typeOf(add.doc_type)?.prefix}-next. {typeOf(add.doc_type)?.client_review ? 'This type goes to the client or consultant for approval after internal review.' : 'This type is approved internally.'}</p>
    </FormModal>}
  </>;
}

function DocModal({ docId, p, manage, canWork, types, onClose, onChange }: { docId: string; p: any; manage: boolean; canWork: boolean; types: any[]; onClose: () => void; onChange: () => void }) {
  const act = useAction();
  const [up, setUp] = useState<any | null>(null);
  const [review, setReview] = useState<any | null>(null);
  const [edit, setEdit] = useState<any | null>(null);
  const { data, reload } = useLoad(async () => ({
    d: await q<any>(supabase.from('doc_register').select('*').eq('id', docId).single() as any),
    revs: await q<any[]>(supabase.from('doc_revisions').select('*').eq('doc_id', docId).order('seq', { ascending: false }) as any),
    trn: await q<any[]>(supabase.from('transmittal_items').select('revision_id,response,comments,responded_at, t:transmittals(number,to_party,sent_date,purpose)').in('revision_id', (await q<any[]>(supabase.from('doc_revisions').select('id').eq('doc_id', docId) as any)).map(r => r.id)) as any).catch(() => [] as any[]),
  }), [docId]);
  if (!data) return null;
  const { d, revs } = data;
  const t = types.find(x => x.code === d.doc_type);
  const cur = revs[0];
  const done = () => { reload(); onChange(); };
  return <Modal wide title={`${d.number} · ${d.title}`} onClose={onClose}>
    <div className="body" style={{ display: 'grid', gap: 12 }}>
      <div className="muted" style={{ fontSize: 13 }}>{t?.name}{d.discipline ? ' · ' + d.discipline : ''}{d.expires_on ? ' · expires ' + longDate(d.expires_on) : ''}{d.confidential ? ' · confidential' : ''}
        {t?.client_review ? ' · client approval needed' : ''}</div>
      <div className="actions">
        {cur?.storage_path && <button className="btn small" type="button" onClick={() => act.run(() => openRevision(cur))}>Open rev {cur.rev}</button>}
        {canWork && <button className="btn small primary" type="button" onClick={() => setUp({ file: null, notes: '', issue: false, for_info: false })}>Upload new revision</button>}
        {canWork && cur && ['draft', 'rejected'].includes(cur.status) && <button className="btn small" type="button" disabled={act.busy} onClick={() => act.run(async () => { await rpc('submit_revision', { p_rev: cur.id }); done(); }, 'Sent for review')}>Submit for review</button>}
        {manage && cur?.status === 'in_review' && <><button className="btn small primary" type="button" disabled={act.busy} onClick={() => act.run(async () => { const s = await rpc<string>('review_revision', { p_rev: cur.id, p_approve: true, p_note: null }); done(); return s; }, t?.client_review ? 'Approved internally: ready to send on a transmittal' : 'Approved')}>Approve</button>
          <button className="btn small" type="button" onClick={() => setReview({ note: '' })}>Reject</button></>}
        {canWork && <button className="btn small ghost" type="button" onClick={() => setEdit({ title: d.title, discipline: d.discipline || '', expires_on: d.expires_on || '', confidential: d.confidential })}>Edit details</button>}
        {manage && !revs.some(r => r.status !== 'draft') && <ConfirmButton className="btn small ghost" label="Delete" confirm="Delete this document?" onConfirm={() => act.run(async () => { await q(supabase.from('doc_register').delete().eq('id', docId) as any); onChange(); onClose(); }, 'Deleted')} />}
      </div>
      {revs.length ? <div className="scroll"><table>
        <thead><tr><th>Rev</th><th>File</th><th>Status</th><th>History</th></tr></thead>
        <tbody>{revs.map(r => <tr key={r.id} style={r.superseded_at ? { opacity: .6 } : undefined}>
          <td className="num"><b>{r.rev}</b>{r.issued_for_construction && <><br /><span className="pill good" style={{ fontSize: 11 }}>IFC</span></>}</td>
          <td className="wrap-cell">{r.storage_path ? <button className="btn ghost small" style={{ padding: 0 }} type="button" onClick={() => act.run(() => openRevision(r))}>{r.file_name}</button> : <span className="muted">No file</span>}
            {r.size_bytes ? <span className="muted" style={{ fontSize: 12 }}> · {Math.max(1, Math.round(r.size_bytes / 1024))} KB</span> : ''}{r.notes && <><br /><span className="muted" style={{ fontSize: 12 }}>{r.notes}</span></>}</td>
          <td><RevStatus s={r.status} />{r.superseded_at && <><br /><span className="muted" style={{ fontSize: 12 }}>Superseded</span></>}</td>
          <td className="wrap-cell muted" style={{ fontSize: 12 }}>Uploaded {r.created_at.slice(0, 10)} by {(r.uploaded_email || '').split('@')[0]}
            {r.reviewed_at && <><br />Reviewed {r.reviewed_at.slice(0, 10)} by {(r.reviewed_email || '').split('@')[0]}{r.review_note ? ': ' + r.review_note : ''}</>}
            {data.trn.filter(x => x.revision_id === r.id).map((x, i) => <span key={i}><br />{x.t?.number} to {x.t?.to_party} {x.t?.sent_date || ''}{x.response ? ` → ${RESPONSES.find(y => y[0] === x.response)?.[1]} ${x.responded_at || ''}` : ''}{x.comments ? ': ' + x.comments : ''}</span>)}</td></tr>)}</tbody>
      </table></div> : <Empty>No revisions yet. Upload the first file.</Empty>}
    </div>
    {up && <FormModal title={`New revision of ${d.number}`} submit="Upload" busy={act.busy} onClose={() => setUp(null)} onSave={() => act.run(async () => {
      if (!up.file) throw new Error('Choose a file.');
      const f = await uploadDocFile(p.company_id, p.id, up.file);
      await rpc('add_revision', { p_doc: docId, p_path: f.path, p_name: f.name, p_size: f.size, p_mime: f.mime, p_notes: up.notes || null, p_issue: up.issue, p_for_info: up.for_info });
      setUp(null); done(); }, 'Revision uploaded; the previous one is superseded')}>
      <div className="field"><label htmlFor="ur-file">File</label><input id="ur-file" type="file" onChange={e => setUp({ ...up, file: e.target.files?.[0] || null })} /></div>
      <Field label="What changed" id="ur-notes" value={up.notes} onChange={v => setUp({ ...up, notes: v })} placeholder="e.g. Anchor bolt schedule added per consultant's comments" />
      <label className="check"><input type="checkbox" checked={up.issue} onChange={e => setUp({ ...up, issue: e.target.checked })} /> Issue for construction (numbered revisions 0, 1, 2…)</label>
      <label className="check"><input type="checkbox" checked={up.for_info} onChange={e => setUp({ ...up, for_info: e.target.checked })} /> For information only (no review)</label>
      <p className="muted" style={{ margin: 0, fontSize: 13 }}>Next revision: {cur ? (/^\d+$/.test(cur.rev) ? String(Number(cur.rev) + 1) : up.issue ? '0' : String.fromCharCode(cur.rev.charCodeAt(0) + 1)) : up.issue ? '0' : 'A'}. Photos larger than 1.5 MB are reduced before upload; other files up to 50 MB.</p>
    </FormModal>}
    {review && <FormModal title={`Reject rev ${cur.rev}`} submit="Reject" busy={act.busy} onClose={() => setReview(null)} onSave={() => act.run(async () => { await rpc('review_revision', { p_rev: cur.id, p_approve: false, p_note: review.note }); setReview(null); done(); }, 'Sent back to the author')}>
      <Field label="What needs to change" id="rv-note" type="textarea" value={review.note} onChange={v => setReview({ note: v })} />
    </FormModal>}
    {edit && <FormModal title="Edit details" busy={act.busy} onClose={() => setEdit(null)} onSave={() => act.run(async () => {
      await q(supabase.from('doc_register').update({ title: edit.title, discipline: edit.discipline || null, expires_on: edit.expires_on || null, confidential: edit.confidential }).eq('id', docId) as any); setEdit(null); done(); }, 'Saved')}>
      <Field label="Title" id="ed-title" value={edit.title} onChange={v => setEdit({ ...edit, title: v })} required />
      <div className="grid-form"><Field label="Discipline" id="ed-disc" value={edit.discipline} onChange={v => setEdit({ ...edit, discipline: v })} />
        <Field label="Expires on" id="ed-exp" type="date" value={edit.expires_on} onChange={v => setEdit({ ...edit, expires_on: v })} /></div>
      {manage && <label className="check"><input type="checkbox" checked={edit.confidential} onChange={e => setEdit({ ...edit, confidential: e.target.checked })} /> Confidential</label>}
    </FormModal>}
  </Modal>;
}

function Transmittals({ p, docs, types, canWork, onChange }: { p: any; docs: any[]; types: any[]; canWork: boolean; onChange: () => void }) {
  const { company } = useSession();
  const act = useAction();
  const toast = useToast();
  const [form, setForm] = useState<any | null>(null);
  const [open, setOpen] = useState<string | null>(null);
  const [resp, setResp] = useState<any | null>(null);
  const [send, setSend] = useState<any | null>(null);
  const { data, reload } = useLoad(async () => q<any[]>(supabase.from('transmittals').select('*, items:transmittal_items(id,copies,response,comments,responded_at, rev:doc_revisions(id,rev,status, doc:doc_register(number,title,doc_type)))').eq('project_id', p.id).order('created_at', { ascending: false }) as any), [p.id]);
  if (!data) return null;
  const sendable = docs.map(d => ({ d, r: current(d) })).filter(x => x.r && !['draft', 'in_review', 'rejected'].includes(x.r.status));
  const t = data.find(x => x.id === open);
  const done = () => { reload(); onChange(); };
  const pdf = (x: any) => transmittalPdf({ company: company!, t: x, project: `${p.number || ''} ${p.name}`, items: x.items.map((i: any) => ({ number: i.rev?.doc?.number, title: i.rev?.doc?.title, rev: i.rev?.rev, type: types.find(y => y.code === i.rev?.doc?.doc_type)?.name, copies: i.copies, response: i.response })) });
  return <Panel title="Transmittals" actions={canWork && sendable.length > 0 && <button className="btn small primary" type="button" onClick={() => setForm({ to_party: '', to_person: '', to_email: '', purpose: 'for_approval', notes: '', picked: {} })}>New transmittal</button>}>
    {data.length ? <div className="scroll"><table>
      <thead><tr><th>Transmittal</th><th>To</th><th>Purpose</th><th>Documents</th><th>Sent</th><th>Reply due</th><th>Status</th></tr></thead>
      <tbody>{data.map(x => { const late = x.status === 'sent' && x.response_due && x.response_due < today();
        return <tr key={x.id} className="click" onClick={() => setOpen(x.id)}><td className="num"><b>{x.number}</b></td><td>{x.to_party}{x.to_person && <span className="muted"> · {x.to_person}</span>}</td>
        <td>{PURPOSES.find(y => y[0] === x.purpose)?.[1]}</td><td className="num">{x.items.length}</td><td className="num">{x.sent_date || ''}</td>
        <td className="num" style={{ color: late ? 'var(--bad)' : undefined }}>{x.response_due || ''}{late ? ' (late)' : ''}</td>
        <td><span className={'pill ' + ({ draft: '', sent: 'warn', responded: 'good', closed: '' } as any)[x.status]}>{({ draft: 'Draft', sent: 'Waiting for reply', responded: 'Replied', closed: 'Sent' } as any)[x.status]}</span></td></tr>; })}</tbody>
    </table></div> : <Empty>No transmittals yet. A transmittal is the cover sheet that goes with documents to the client or consultant: what was sent, which revision, why, and the reply.</Empty>}

    {form && <FormModal title="New transmittal" submit="Save draft" busy={act.busy} onClose={() => setForm(null)} onSave={() => act.run(async () => {
      const ids = Object.keys(form.picked).filter(k => form.picked[k]);
      if (!ids.length) throw new Error('Tick at least one document.');
      const x = await q<any>(supabase.from('transmittals').insert({ project_id: p.id, company_id: p.company_id, to_party: form.to_party, to_person: form.to_person || null, to_email: form.to_email || null, purpose: form.purpose, notes: form.notes || null }).select('id').single() as any);
      await q(supabase.from('transmittal_items').insert(ids.map(id => ({ transmittal_id: x.id, company_id: p.company_id, revision_id: id }))) as any);
      setForm(null); reload(); setOpen(x.id); }, 'Draft transmittal saved')}>
      <div className="grid-form">
        <Field label="To (company)" id="tm-to" value={form.to_party} onChange={v => setForm({ ...form, to_party: v })} placeholder="Client or consultant" required />
        <Field label="Attention" id="tm-person" value={form.to_person} onChange={v => setForm({ ...form, to_person: v })} />
        <Field label="Email" id="tm-email" type="email" value={form.to_email} onChange={v => setForm({ ...form, to_email: v })} />
        <Select label="Purpose" id="tm-purpose" value={form.purpose} onChange={v => setForm({ ...form, purpose: v })} options={PURPOSES} />
      </div>
      <div className="scroll" style={{ maxHeight: 260 }}><table className="lines"><thead><tr><th></th><th>Document</th><th>Rev</th><th>Status</th></tr></thead>
        <tbody>{sendable.map(({ d, r }) => { const ok = form.purpose !== 'for_construction' || ['approved', 'approved_comments'].includes(r.status);
          return <tr key={r.id} style={ok ? undefined : { opacity: .5 }}><td><input type="checkbox" aria-label={'Include ' + d.number} disabled={!ok} checked={!!form.picked[r.id]} onChange={e => setForm({ ...form, picked: { ...form.picked, [r.id]: e.target.checked } })} /></td>
            <td>{d.number} · {d.title}</td><td className="num">{r.rev}</td><td><RevStatus s={r.status} /></td></tr>; })}</tbody></table></div>
      <Field label="Note" id="tm-notes" value={form.notes} onChange={v => setForm({ ...form, notes: v })} />
      <p className="muted" style={{ margin: 0, fontSize: 13 }}>Only reviewed documents can be sent. Issued for construction needs approved documents.</p>
    </FormModal>}
    {t && <Modal title={`${t.number} to ${t.to_party}`} onClose={() => setOpen(null)}>
      <div className="body" style={{ display: 'grid', gap: 12 }}>
        <div className="muted" style={{ fontSize: 13 }}>{PURPOSES.find(y => y[0] === t.purpose)?.[1]}{t.to_person ? ' · attn ' + t.to_person : ''}{t.sent_date ? ' · sent ' + longDate(t.sent_date) : ' · not sent yet'}{t.response_due ? ' · reply due ' + longDate(t.response_due) : ''}</div>
        <div className="actions">
          <button className="btn small" type="button" onClick={() => pdf(t)}>Cover sheet PDF</button>
          {t.status === 'draft' && canWork && <button className="btn small primary" type="button" onClick={() => setSend({ date: today(), due: '' })}>Mark as sent</button>}
          {t.status === 'draft' && canWork && <ConfirmButton className="btn small ghost" label="Delete" confirm="Delete this draft?" onConfirm={() => act.run(async () => { await q(supabase.from('transmittals').delete().eq('id', t.id) as any); setOpen(null); done(); })} />}
          {t.to_email && <a className="btn small" href={`mailto:${t.to_email}?subject=${encodeURIComponent(t.number + ' ' + p.name)}&body=${encodeURIComponent('Please find attached the documents listed on transmittal ' + t.number + '.')}`} onClick={() => toast('Attach the cover sheet PDF and the files to the email')}>Email</a>}
        </div>
        <div className="scroll"><table>
          <thead><tr><th>Document</th><th>Rev</th><th>Reply</th><th></th></tr></thead>
          <tbody>{t.items.map((i: any) => <tr key={i.id}><td>{i.rev?.doc?.number} · {i.rev?.doc?.title}</td><td className="num">{i.rev?.rev}</td>
            <td className="wrap-cell">{i.response ? <><span className={'pill ' + (i.response === 'rejected' ? 'bad' : 'good')}>{RESPONSES.find(y => y[0] === i.response)?.[1]}</span> <span className="muted" style={{ fontSize: 12 }}>{i.responded_at}{i.comments ? ': ' + i.comments : ''}</span></> : <span className="muted">—</span>}</td>
            <td className="r">{['sent', 'responded'].includes(t.status) && canWork && <button className="btn small" type="button" onClick={() => setResp({ id: i.id, response: 'approved', comments: '', date: today() })}>Record reply</button>}</td></tr>)}</tbody>
        </table></div>
      </div>
      {send && <FormModal title={`Send ${t.number}`} submit="Mark as sent" busy={act.busy} onClose={() => setSend(null)} onSave={() => act.run(async () => { await rpc('send_transmittal', { p_id: t.id, p_date: send.date, p_due: send.due || null }); setSend(null); done(); }, 'Sent')}>
        <div className="grid-form"><Field label="Date sent" id="ts-date" type="date" value={send.date} onChange={v => setSend({ ...send, date: v })} required />
          {['for_approval', 'for_comment'].includes(t.purpose) && <Field label="Reply due (default 14 days)" id="ts-due" type="date" value={send.due} onChange={v => setSend({ ...send, due: v })} />}</div>
      </FormModal>}
      {resp && <FormModal title="Record the reply" busy={act.busy} onClose={() => setResp(null)} onSave={() => act.run(async () => { await rpc('record_response', { p_item: resp.id, p_response: resp.response, p_comments: resp.comments || null, p_date: resp.date }); setResp(null); done(); }, 'Reply recorded')}>
        <div className="grid-form"><Select label="Reply" id="rs-resp" value={resp.response} onChange={v => setResp({ ...resp, response: v })} options={RESPONSES} />
          <Field label="Date" id="rs-date" type="date" value={resp.date} onChange={v => setResp({ ...resp, date: v })} required /></div>
        <Field label="Comments" id="rs-com" type="textarea" value={resp.comments} onChange={v => setResp({ ...resp, comments: v })} />
      </FormModal>}
    </Modal>}
  </Panel>;
}

function RiskAssessments({ p, manage, canWork, tasks, team }: { p: any; manage: boolean; canWork: boolean; tasks: any[]; team: any[] | null }) {
  const { company, session, can } = useSession();
  const act = useAction();
  const [open, setOpen] = useState<string | null>(null);
  const [form, setForm] = useState<any | null>(null);
  const [hse, setHse] = useState<string>(p.hse_officer_id || '');
  const { data, reload } = useLoad(async () => q<any[]>(supabase.from('risk_assessments').select('*, items:risk_items(*)').eq('project_id', p.id).order('created_at', { ascending: false }) as any), [p.id]);
  if (!data) return null;
  const ra = data.find(x => x.id === open);
  return <Panel title="Risk assessments" actions={<>
    {manage && team && <select aria-label="Health and safety officer" value={hse} onChange={e => { const v = e.target.value; setHse(v); act.run(async () => { await q(supabase.from('projects').update({ hse_officer_id: v || null }).eq('id', p.id) as any); }, 'Health and safety officer set'); }}>
      <option value="">HSE officer: not set (owner signs)</option>{team.map(t => <option key={t.user_id} value={t.user_id}>HSE officer: {t.email}</option>)}</select>}
    {canWork && <button className="btn small primary" type="button" onClick={() => setForm({ title: '', activity: '', location: '', task_id: '', review_date: '' })}>New risk assessment</button>}</>}>
    {data.length ? <div className="scroll"><table>
      <thead><tr><th>No.</th><th>Activity</th><th>Hazards</th><th>Highest risk</th><th>Review by</th><th>Status</th></tr></thead>
      <tbody>{data.map(x => { const top = x.items.reduce((m: any, i: any) => (!m || i.likelihood * i.severity > m.likelihood * m.severity ? i : m), null);
        return <tr key={x.id} className="click" onClick={() => setOpen(x.id)}><td className="num"><b>{x.number}</b> <span className="muted">v{x.version}</span></td>
          <td>{x.title}{x.location && <span className="muted"> · {x.location}</span>}</td><td className="num">{x.items.length}</td>
          <td>{top ? <RiskChip l={top.likelihood} s={top.severity} /> : ''}</td>
          <td className="num" style={{ color: x.review_date && x.review_date < today() ? 'var(--bad)' : undefined }}>{x.review_date || ''}</td>
          <td><span className={'pill ' + (x.status === 'approved' ? 'good' : 'warn')}>{x.status === 'approved' ? 'Signed off' : x.pm_signed_by || x.hse_signed_by ? 'One signature' : 'Draft'}</span></td></tr>; })}</tbody>
    </table></div> : <Empty>No risk assessments yet. Assess each activity before it starts: hazards, who could be hurt, likelihood and severity, the controls, and the risk left after them.</Empty>}

    {form && <FormModal title="New risk assessment" busy={act.busy} onClose={() => setForm(null)} onSave={() => act.run(async () => {
      const x = await q<any>(supabase.from('risk_assessments').insert({ project_id: p.id, company_id: p.company_id, title: form.title, activity: form.activity || null, location: form.location || null, task_id: form.task_id || null, review_date: form.review_date || null }).select('id').single() as any);
      setForm(null); reload(); setOpen(x.id); }, 'Created: add the hazards')}>
      <Field label="Activity being assessed" id="ra-title" value={form.title} onChange={v => setForm({ ...form, title: v })} placeholder="e.g. Excavation and concrete pour" required />
      <div className="grid-form"><Field label="Location" id="ra-loc" value={form.location} onChange={v => setForm({ ...form, location: v })} />
        {tasks.length > 0 && <Select label="Task" id="ra-task" value={form.task_id} onChange={v => setForm({ ...form, task_id: v })} options={[['', '—'], ...tasks.map(t => [t.id, t.title] as [string, string])]} />}
        <Field label="Review by" id="ra-rev" type="date" value={form.review_date} onChange={v => setForm({ ...form, review_date: v })} /></div>
    </FormModal>}
    {ra && <RaEditor ra={ra} p={p} manage={manage} canWork={canWork} isHse={session?.user.id === p.hse_officer_id || (!p.hse_officer_id && can('admin'))} company={company} onClose={() => setOpen(null)} onChange={reload} />}
  </Panel>;
}

function RaEditor({ ra, p, manage, canWork, isHse, company, onClose, onChange }: any) {
  const act = useAction();
  const [items, setItems] = useState<any[]>(ra.items.slice().sort((a: any, b: any) => a.sort - b.sort).map((i: any) => ({ ...i })));
  const [revise, setRevise] = useState<string | null>(null);
  const draft = ra.status === 'draft' && canWork;
  const set = (k: number, patch: any) => setItems(items.map((x, j) => j === k ? { ...x, ...patch } : x));
  const save = () => act.run(async () => {
    const bad = items.find(i => !i.hazard?.trim());
    if (bad) throw new Error('Every row needs a hazard.');
    await q(supabase.from('risk_items').delete().eq('ra_id', ra.id) as any);
    if (items.length) await q(supabase.from('risk_items').insert(items.map((i, k) => ({ ra_id: ra.id, company_id: ra.company_id, hazard: i.hazard, consequence: i.consequence || null, who_at_risk: i.who_at_risk || null,
      likelihood: Number(i.likelihood), severity: Number(i.severity), controls: i.controls || null, owner: i.owner || null,
      residual_likelihood: i.residual_likelihood ? Number(i.residual_likelihood) : null, residual_severity: i.residual_severity ? Number(i.residual_severity) : null, sort: k }))) as any);
    onChange();
  }, 'Saved');
  const sign = (as: string) => act.run(async () => { await save(); const s = await rpc<string>('sign_risk_assessment', { p_id: ra.id, p_as: as }); onChange(); return s; }, 'Signed');
  const n5 = [1, 2, 3, 4, 5].map(n => [String(n), String(n)] as [string, string]);
  return <Modal wide title={`${ra.number} v${ra.version} · ${ra.title}`} onClose={onClose}>
    <div className="body" style={{ display: 'grid', gap: 12 }}>
      <div className="muted" style={{ fontSize: 13 }}>{[ra.location, 'assessed ' + longDate(ra.assessed_on) + ' by ' + (ra.assessed_email || '').split('@')[0], ra.review_date && 'review by ' + longDate(ra.review_date)].filter(Boolean).join(' · ')}<br />
        Project manager: {ra.pm_signed_at ? `signed by ${ra.pm_signed_email} ${ra.pm_signed_at.slice(0, 10)}` : 'not signed'} · HSE: {ra.hse_signed_at ? `signed by ${ra.hse_signed_email} ${ra.hse_signed_at.slice(0, 10)}` : 'not signed'}</div>
      <div className="actions">
        <button className="btn small" type="button" onClick={() => riskAssessmentPdf({ company, ra: { ...ra, items }, project: `${p.number || ''} ${p.name}` })}>PDF</button>
        {draft && <button className="btn small" type="button" disabled={act.busy} onClick={save}>Save</button>}
        {ra.status === 'draft' && manage && !ra.pm_signed_by && <button className="btn small primary" type="button" disabled={act.busy} onClick={() => sign('pm')}>Sign as project manager</button>}
        {ra.status === 'draft' && isHse && !ra.hse_signed_by && <button className="btn small primary" type="button" disabled={act.busy} onClick={() => sign('hse')}>Sign as HSE officer</button>}
        {ra.status === 'approved' && canWork && <button className="btn small" type="button" onClick={() => setRevise('')}>Revise</button>}
      </div>
      <div className="scroll"><table className="lines">
        <thead><tr><th>Hazard and consequence</th><th>Who</th><th>L</th><th>S</th><th>Risk</th><th>Controls</th><th>Owner</th><th>L after</th><th>S after</th><th>Left</th><th></th></tr></thead>
        <tbody>{items.map((i, k) => <tr key={k}>
          <td style={{ minWidth: 190 }}>{draft ? <><input aria-label="Hazard" value={i.hazard || ''} onChange={e => set(k, { hazard: e.target.value })} placeholder="Hazard" style={{ display: 'block', width: '100%' }} />
            <input aria-label="Consequence" value={i.consequence || ''} onChange={e => set(k, { consequence: e.target.value })} placeholder="What could happen" style={{ display: 'block', width: '100%', marginTop: 4 }} /></> : <>{i.hazard}{i.consequence && <><br /><span className="muted">{i.consequence}</span></>}</>}</td>
          <td style={{ minWidth: 110 }}>{draft ? <input aria-label="Who is at risk" value={i.who_at_risk || ''} onChange={e => set(k, { who_at_risk: e.target.value })} style={{ display: 'block', width: '100%' }} /> : i.who_at_risk}</td>
          {(['likelihood', 'severity'] as const).map(f => <td key={f}>{draft ? <select aria-label={f} value={i[f]} onChange={e => set(k, { [f]: e.target.value })} style={{ minWidth: 56 }}>{n5.map(([v]) => <option key={v}>{v}</option>)}</select> : i[f]}</td>)}
          <td><RiskChip l={Number(i.likelihood)} s={Number(i.severity)} /></td>
          <td style={{ minWidth: 200 }}>{draft ? <textarea aria-label="Control measures" value={i.controls || ''} onChange={e => set(k, { controls: e.target.value })} rows={2} /> : <span style={{ whiteSpace: 'pre-wrap' }}>{i.controls}</span>}</td>
          <td style={{ minWidth: 100 }}>{draft ? <input aria-label="Owner" value={i.owner || ''} onChange={e => set(k, { owner: e.target.value })} style={{ display: 'block', width: '100%' }} /> : i.owner}</td>
          {(['residual_likelihood', 'residual_severity'] as const).map(f => <td key={f}>{draft ? <select aria-label={f} value={i[f] || ''} onChange={e => set(k, { [f]: e.target.value })}><option value="">–</option>{n5.map(([v]) => <option key={v}>{v}</option>)}</select> : i[f] || '–'}</td>)}
          <td><RiskChip l={Number(i.residual_likelihood)} s={Number(i.residual_severity)} /></td>
          <td>{draft && <button className="btn ghost small" type="button" onClick={() => setItems(items.filter((_, j) => j !== k))}>Remove</button>}</td></tr>)}</tbody>
      </table></div>
      {draft && <div><button className="btn small" type="button" onClick={() => setItems([...items, { hazard: '', likelihood: 3, severity: 3, controls: '' }])}>Add hazard</button></div>}
      <RiskMatrix items={items} />
      <p className="muted" style={{ margin: 0, fontSize: 13 }}>Likelihood (L) and severity (S) from 1 to 5. Score 1–4 low, 5–12 medium, 15–25 high. Every hazard needs controls; every high risk needs a rating after controls. Once both signatures are in, the assessment is locked; Revise starts a new version.</p>
      {ra.notes && <div className="note" style={{ whiteSpace: 'pre-wrap' }}>{ra.notes}</div>}
    </div>
    {revise !== null && <FormModal title={`Revise ${ra.number}`} submit="Start new version" busy={act.busy} onClose={() => setRevise(null)} onSave={() => act.run(async () => { await rpc('revise_risk_assessment', { p_id: ra.id, p_reason: revise }); setRevise(null); onChange(); }, 'New version started')}>
      <Field label="Why it is being revised" id="rv-why" value={revise} onChange={setRevise} placeholder="e.g. Method changed after site meeting; incident on 12 Dec" />
    </FormModal>}
  </Modal>;
}

/** 5 x 5 matrix: how many hazards fall in each cell before controls. */
export function RiskMatrix({ items }: { items: any[] }) {
  const cell = (l: number, s: number) => items.filter(i => Number(i.likelihood) === l && Number(i.severity) === s).length;
  const col = (n: number) => n >= 15 ? 'var(--bad-soft)' : n >= 5 ? 'var(--warn-soft)' : 'var(--good-soft)';
  return <div style={{ display: 'inline-grid', width: 'fit-content', gridTemplateColumns: 'auto repeat(5, 34px)', gap: 3, alignItems: 'center', fontSize: 11 }} aria-label="Risk matrix">
    {[5, 4, 3, 2, 1].map(l => <Fragment key={l}>
      <span className="muted" style={{ paddingRight: 6 }}>{l === 3 ? 'Likelihood ' : ''}{l}</span>
      {[1, 2, 3, 4, 5].map(s => <div key={l + '-' + s} style={{ height: 26, background: col(l * s), borderRadius: 4, display: 'grid', placeItems: 'center', fontWeight: 600 }}>{cell(l, s) || ''}</div>)}</Fragment>)}
    <span />{[1, 2, 3, 4, 5].map(s => <span key={'s' + s} className="muted" style={{ textAlign: 'center' }}>{s}</span>)}
    <span /><span className="muted" style={{ gridColumn: 'span 5', textAlign: 'center' }}>Severity</span>
  </div>;
}

function Required({ p, manage, types, check, onChange }: { p: any; manage: boolean; types: any[]; check: any[]; onChange: () => void }) {
  const act = useAction();
  const [add, setAdd] = useState<any | null>(null);
  const { data: reqs, reload } = useLoad(() => q<any[]>(supabase.from('project_doc_requirements').select('id,doc_type,stage').eq('project_id', p.id) as any), [p.id]);
  const done = () => { reload(); onChange(); };
  return <Panel title="Documents this project must have" actions={manage && <>
    {!check.length && <button className="btn small" type="button" disabled={act.busy} onClick={() => act.run(async () => { await rpc('standard_doc_requirements', { p_project: p.id }); done(); }, 'Standard list added')}>Use standard list</button>}
    <button className="btn small primary" type="button" onClick={() => setAdd({ doc_type: 'method_statement', stage: 'start', note: '' })}>Add</button></>}>
    {check.length ? <div className="scroll"><table>
      <thead><tr><th>Needed</th><th>Document</th><th>Note</th><th>In place</th><th></th></tr></thead>
      <tbody>{check.map(c => { const r = reqs?.find(x => x.doc_type === c.doc_type && x.stage === c.stage); return <tr key={c.doc_type + c.stage}>
        <td>{c.stage === 'start' ? 'Before work starts' : 'Before closing'}</td><td>{c.name}</td><td className="muted">{c.note}</td>
        <td>{c.satisfied ? <span className="pill good">Yes</span> : <span className="pill bad">{Number(c.docs) ? 'Not approved yet' : 'Missing'}</span>}</td>
        <td className="r">{manage && r && <ConfirmButton className="btn small ghost" label="Remove" confirm="Remove?" onConfirm={() => act.run(async () => { await q(supabase.from('project_doc_requirements').delete().eq('id', r.id) as any); done(); })} />}</td></tr>; })}</tbody>
    </table></div> : <Empty>No required documents set. The standard list asks for an approved risk assessment and method statement before work starts, and as-built drawings, O&M manuals, test certificates and the handover certificate before closing.</Empty>}
    <div className="body muted" style={{ fontSize: 13 }}>A document counts once its current revision is approved (or filed for information). Missing start documents show as a warning when you start the project; missing close documents stop the project from closing. Templates carry their list to new projects.</div>
    {add && <FormModal title="Add a required document" busy={act.busy} onClose={() => setAdd(null)} onSave={() => act.run(async () => {
      await q(supabase.from('project_doc_requirements').insert({ project_id: p.id, company_id: p.company_id, doc_type: add.doc_type, stage: add.stage, note: add.note || null }) as any); setAdd(null); done(); }, 'Added')}>
      <div className="grid-form">
        <div className="field"><label htmlFor="rq-type">Document</label><select id="rq-type" value={add.doc_type} onChange={e => setAdd({ ...add, doc_type: e.target.value })}>
          {GROUPS.map(([g, gl]) => <optgroup key={g} label={gl}>{types.filter(t => t.grp === g).map(t => <option key={t.code} value={t.code}>{t.name}</option>)}</optgroup>)}</select></div>
        <Select label="Needed" id="rq-stage" value={add.stage} onChange={v => setAdd({ ...add, stage: v })} options={[['start', 'Before work starts'], ['close', 'Before closing']]} />
      </div>
      <Field label="Note" id="rq-note" value={add.note} onChange={v => setAdd({ ...add, note: v })} />
    </FormModal>}
  </Panel>;
}
