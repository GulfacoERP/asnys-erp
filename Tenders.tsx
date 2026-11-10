import { useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { q, qPage, rpc, supabase } from '../lib/supabase';
import { useSession } from '../lib/session';
import { cedis, longDate, money, today } from '../lib/format';
import { downloadCsv } from '../lib/download';
import { tablePdf } from '../lib/pdf';
import { ConfirmButton, Empty, Field, FormModal, Loading, PageHead, Panel, Select, useAction, useLoad } from '../components/ui';
import { Pager, SearchBox, usePaged } from '../components/paging';
import { uploadDocFile } from '../components/ProjectDocs';
import { VoidButton } from '../components/Void';

export const TENDER_STATUS: Record<string, [string, string]> = {
  registered: ['Registered', ''], preparing: ['Preparing', 'warn'], review: ['Pre-submission review', 'warn'], submitted: ['Submitted', 'warn'],
  awarded: ['Awarded', 'good'], lost: ['Lost', 'bad'], no_bid: ['Not bidding', ''], cancelled: ['Cancelled', ''], voided: ['Voided', 'bad'],
};
const KINDS: [string, string][] = [['tender', 'Tender'], ['rfq', 'Request for quotation'], ['quotation', 'Quotation'], ['eoi', 'Expression of interest'], ['prequalification', 'Prequalification'], ['direct_award', 'Direct award / PO']];
const FILE_KINDS: [string, string][] = [['tender_docs', 'Tender documents'], ['summary', 'Summary report'], ['pricing', 'Pricing'], ['technical', 'Technical proposal'], ['submission', 'Final submission'], ['contract', 'Signed contract'], ['purchase_order', 'Purchase order'], ['minutes', 'Minutes'], ['other', 'Other']];
export const TStatus = ({ s }: { s: string }) => <span className={'pill ' + (TENDER_STATUS[s]?.[1] || '')}>{TENDER_STATUS[s]?.[0] || s}</span>;
const margin = (t: any) => Number(t.est_value) > 0 ? Math.round((1 - Number(t.est_cost) / Number(t.est_value)) * 100) : null;

export function TendersPage() {
  const { cid, company, can } = useSession();
  const nav = useNavigate();
  const [view, setView] = useState<'open' | 'submitted' | 'awarded' | 'closed' | 'voided' | 'all'>('open');
  const [search, setSearch] = useState('');
  const [add, setAdd] = useState<any | null>(null);
  const act = useAction();
  const statuses = { open: ['registered', 'preparing', 'review'], submitted: ['submitted'], awarded: ['awarded'], closed: ['lost', 'no_bid', 'cancelled'], voided: ['voided'], all: null }[view];
  const pg = usePaged(async (a, b) => {
    let x = supabase.from('tenders').select('*, project:projects!tenders_project_id_fkey(id,number)', { count: 'exact' }).eq('company_id', cid).order('submission_deadline', { ascending: view === 'open', nullsFirst: false });
    if (statuses) x = x.in('status', statuses); else x = x.neq('status', 'voided');
    if (search) x = x.or(`number.ilike.%${search}%,title.ilike.%${search}%,client_name.ilike.%${search}%,client_ref.ilike.%${search}%`, {});
    return qPage(x.range(a, b) as any);
  }, [cid, view, search]);
  const { data: meta } = useLoad(async () => ({
    customers: await q<any[]>(supabase.from('customers').select('id,name').eq('company_id', cid).order('name') as any),
    team: await q<any[]>(supabase.from('memberships').select('user_id,email,role').eq('company_id', cid).order('email') as any),
    stats: await q<any[]>(supabase.from('tenders').select('status,est_value,awarded_value,submitted_value,result_date').eq('company_id', cid) as any),
  }), [cid]);
  const st = meta?.stats || [];
  const decided = st.filter(t => ['awarded', 'lost'].includes(t.status));
  const winRate = decided.length ? Math.round(100 * decided.filter(t => t.status === 'awarded').length / decided.length) : null;
  const head = ['No.', 'Title', 'Client', 'Type', 'Deadline', 'Est. value (GHS)', 'Est. margin %', 'Status', 'Project'];
  const rows = pg.rows.map(t => [t.number, t.title, t.client_name || '', KINDS.find(k => k[0] === t.kind)?.[1] || t.kind, t.submission_deadline ? t.submission_deadline.slice(0, 16).replace('T', ' ') : '', money(t.est_value), String(margin(t) ?? ''), TENDER_STATUS[t.status][0], t.project?.number || '']);
  return <>
    <PageHead title="Tenders and opportunities" sub={meta ? `${st.filter(t => ['registered', 'preparing', 'review'].includes(t.status)).length} being prepared · ${st.filter(t => t.status === 'submitted').length} awaiting result · win rate ${winRate ?? '—'}%` : undefined}>
      <button className="btn" type="button" onClick={() => tablePdf({ company: company!, title: 'Tender register', subtitle: longDate(today()), head, body: rows, rightAlign: [5, 6], landscape: true, filename: 'tender-register' })}>Register PDF</button>
      <button className="btn" type="button" onClick={() => downloadCsv('tender-register', head, rows)}>CSV</button>
      {can('sales', 'accountant', 'project_manager') && <button className="btn primary" type="button" onClick={() => setAdd({ title: '', kind: 'tender', customer_id: '', client_name: '', client_ref: '', location: '', deadline: '', est_value: '', est_cost: '', bid_bond_required: false, bid_bond_amount: '', engineering_lead_id: '', finance_lead_id: '', notes: '' })}>Register tender</button>}
    </PageHead>
    <div className="filters">
      <div className="actions" style={{ alignSelf: 'end' }}>{([['open', 'Being prepared'], ['submitted', 'Submitted'], ['awarded', 'Awarded'], ['closed', 'Lost or dropped'], ['all', 'All'], ['voided', 'Voided']] as const).map(([k, l]) =>
        <button key={k} type="button" className={'btn small' + (view === k ? ' primary' : '')} onClick={() => setView(k)}>{l}</button>)}</div>
      <SearchBox value={search} onChange={setSearch} placeholder="Number, title, client or reference" id="tn-search" />
    </div>
    <Loading error={pg.error} loading={pg.loading && !pg.data} />
    {pg.data && <Panel>{pg.rows.length ? <div className="scroll"><table>
      <thead><tr><th>Tender</th><th>Client</th><th>Deadline</th><th className="r">Est. value (GH₵)</th><th className="r">Margin</th><th>Status</th></tr></thead>
      <tbody>{pg.rows.map(t => { const soon = ['registered', 'preparing', 'review'].includes(t.status) && t.submission_deadline && Date.parse(t.submission_deadline) < Date.now() + 3 * 864e5;
        return <tr key={t.id} className="click" tabIndex={0} onClick={() => nav('/tenders/' + t.id)} onKeyDown={e => e.key === 'Enter' && nav('/tenders/' + t.id)}>
          <td><b>{t.title}</b><br /><span className="muted num" style={{ fontSize: 12 }}>{t.number} · {KINDS.find(k => k[0] === t.kind)?.[1]}</span></td>
          <td>{t.client_name}</td>
          <td className="num" style={{ color: soon ? 'var(--bad)' : undefined }}>{t.submission_deadline ? t.submission_deadline.slice(0, 16).replace('T', ' ') : '—'}</td>
          <td className="r num">{money(t.awarded_value ?? t.est_value)}</td><td className="r num">{margin(t) != null ? margin(t) + '%' : ''}</td>
          <td><TStatus s={t.status} />{t.project && <><br /><span className="muted num" style={{ fontSize: 12 }}>{t.project.number}</span></>}</td></tr>; })}</tbody>
    </table></div> : <Empty>{view === 'open' ? 'No tenders being prepared.' : 'Nothing here.'} Business Development registers every tender, quotation and procurement opportunity here; Finance and Engineering are notified at once.</Empty>}
      <Pager {...pg} noun="tenders" /></Panel>}
    {add && meta && <FormModal title="Register a tender or opportunity" busy={act.busy} onClose={() => setAdd(null)} onSave={() => act.run(async () => {
      const t = await q<any>(supabase.from('tenders').insert({ company_id: cid, title: add.title, kind: add.kind, customer_id: add.customer_id || null, client_name: add.customer_id ? null : add.client_name || null,
        client_ref: add.client_ref || null, location: add.location || null, submission_deadline: add.deadline ? new Date(add.deadline).toISOString() : null,
        est_value: Number(add.est_value) || 0, est_cost: Number(add.est_cost) || 0, bid_bond_required: add.bid_bond_required, bid_bond_amount: add.bid_bond_amount ? Number(add.bid_bond_amount) : null,
        engineering_lead_id: add.engineering_lead_id || null, finance_lead_id: add.finance_lead_id || null, notes: add.notes || null }).select('id').single() as any);
      nav('/tenders/' + t.id); }, 'Registered. Finance and Engineering have been notified.')}>
      <TenderFields f={add} set={setAdd} customers={meta.customers} team={meta.team} />
    </FormModal>}
  </>;
}

/** The tender's details: used to register a tender and to edit it later. */
function TenderFields({ f, set, customers, team }: { f: any; set: (v: any) => void; customers: any[]; team: any[] }) {
  const add = f, setAdd = set;
  const meta = { customers, team };
  return <>
      <Field label="Title" id="tn-title" value={add.title} onChange={v => setAdd({ ...add, title: v })} placeholder="e.g. Prestea 161 kV substation civil works" required />
    <div className="grid-form">
      <Select label="Type" id="tn-kind" value={add.kind} onChange={v => setAdd({ ...add, kind: v })} options={KINDS} />
      <Select label="Client" id="tn-cust" value={add.customer_id} onChange={v => setAdd({ ...add, customer_id: v })} options={[['', 'Not a customer yet'], ...meta.customers.map(c => [c.id, c.name] as [string, string])]} />
      {!add.customer_id && <Field label="Client name" id="tn-cname" value={add.client_name} onChange={v => setAdd({ ...add, client_name: v })} />}
      <Field label="Client's reference" id="tn-ref" value={add.client_ref} onChange={v => setAdd({ ...add, client_ref: v })} />
      <Field label="Submission deadline" id="tn-dl" type="datetime-local" value={add.deadline} onChange={v => setAdd({ ...add, deadline: v })} />
      <Field label="Location" id="tn-loc" value={add.location} onChange={v => setAdd({ ...add, location: v })} />
      <Field label="Estimated value (GH₵)" id="tn-val" type="number" step="0.01" min="0" value={add.est_value} onChange={v => setAdd({ ...add, est_value: v })} />
      <Field label="Estimated cost (GH₵)" id="tn-cost" type="number" step="0.01" min="0" value={add.est_cost} onChange={v => setAdd({ ...add, est_cost: v })} />
      <Select label="Engineering lead" id="tn-eng" value={add.engineering_lead_id} onChange={v => setAdd({ ...add, engineering_lead_id: v })} options={[['', '—'], ...meta.team.filter(m => ['project_manager', 'owner', 'admin'].includes(m.role)).map(m => [m.user_id, m.email] as [string, string])]} />
      <Select label="Finance lead" id="tn-fin" value={add.finance_lead_id} onChange={v => setAdd({ ...add, finance_lead_id: v })} options={[['', '—'], ...meta.team.filter(m => ['accountant', 'owner', 'admin'].includes(m.role)).map(m => [m.user_id, m.email] as [string, string])]} />
    </div>
    <label className="check"><input type="checkbox" checked={add.bid_bond_required} onChange={e => setAdd({ ...add, bid_bond_required: e.target.checked })} /> Bid bond or security required</label>
    {add.bid_bond_required && <Field label="Bid bond amount (GH₵)" id="tn-bond" type="number" step="0.01" min="0" value={add.bid_bond_amount} onChange={v => setAdd({ ...add, bid_bond_amount: v })} />}
    <Field label="Notes" id="tn-notes" type="textarea" value={add.notes} onChange={v => setAdd({ ...add, notes: v })} />
  </>;
}

/** A stored deadline as the value a date-and-time field expects (local time). */
const toLocalInput = (iso?: string | null) => { if (!iso) return ''; const d = new Date(iso); return new Date(d.getTime() - d.getTimezoneOffset() * 6e4).toISOString().slice(0, 16); };

export function TenderView() {
  const { id } = useParams();
  const { cid, can } = useSession();
  const nav = useNavigate();
  const act = useAction();
  const [review, setReview] = useState<any | null>(null);
  const [edit, setEdit] = useState<{ unit: string; text: string } | null>(null);
  const [move, setMove] = useState<any | null>(null);
  const [award, setAward] = useState<any | null>(null);
  const [reg, setReg] = useState<any | null>(null);
  const [file, setFile] = useState<any | null>(null);
  const [meet, setMeet] = useState<any | null>(null);
  const [details, setDetails] = useState<any | null>(null);
  const { data, error, loading, reload } = useLoad(async () => {
    const t = await q<any>(supabase.from('tenders').select('*, project:projects!tenders_project_id_fkey(id,number,name)').eq('id', id).single() as any);
    const [reviews, files, team, centres, meetings, customers] = await Promise.all([
      q<any[]>(supabase.from('tender_reviews').select('*').eq('tender_id', id).order('meeting_date', { ascending: false }) as any),
      q<any[]>(supabase.from('tender_files').select('*').eq('tender_id', id).order('created_at') as any),
      q<any[]>(supabase.from('memberships').select('user_id,email,role').eq('company_id', cid).order('email') as any),
      q<any[]>(supabase.from('cost_centres').select('id,code,name').eq('company_id', cid).eq('active', true).order('code') as any).catch(() => [] as any[]),
      q<any[]>(supabase.from('project_meetings').select('*').eq('tender_id', id).order('meeting_date', { ascending: false }) as any),
      q<any[]>(supabase.from('customers').select('id,name').eq('company_id', cid).order('name') as any),
    ]);
    return { t, reviews, files, team, centres, meetings, customers };
  }, [id, cid]);
  if (!data) return <Loading error={error} loading={loading} />;
  const { t, reviews, files, team, centres, meetings, customers } = data;
  const who = (u?: string | null) => team.find(m => m.user_id === u)?.email || '';
  const r = reviews[0];
  const open = ['registered', 'preparing', 'review'].includes(t.status);
  const unitCan = (u: string) => can(u === 'bd' ? 'sales' : u === 'finance' ? 'accountant' : 'project_manager');
  const units: [string, string, string][] = [['bd', 'Business Development', 'bd'], ['finance', 'Finance', 'finance'], ['engineering', 'Engineering', 'engineering']];
  const done = () => reload();
  const openFile = (f: any) => act.run(async () => { const { data: u, error: e } = await supabase.storage.from('project-docs').createSignedUrl(f.storage_path, 600); if (e) throw e; window.open(u.signedUrl, '_blank', 'noopener'); });
  return <>
    <PageHead title={t.title} sub={<><span className="num muted">{t.number}</span> <TStatus s={t.status} /> <span className="muted">· {KINDS.find(k => k[0] === t.kind)?.[1]} · {t.client_name}{t.client_ref ? ' · ref ' + t.client_ref : ''}</span></>}>
      <Link className="btn" to="/tenders">Back</Link>
      {t.status === 'registered' && <button className="btn" type="button" onClick={() => act.run(async () => { await rpc('set_tender_status', { p_id: id, p_to: 'preparing' }); done(); })}>Start preparing</button>}
      {open && !r && <button className="btn primary" type="button" onClick={() => setReview({ meeting_date: today(), summary_shared_on: '', attendees: '' })}>Schedule pre-submission review</button>}
      {!['awarded', 'lost', 'no_bid', 'cancelled'].includes(t.status) && can('sales', 'accountant', 'project_manager') && <button className="btn" type="button" onClick={() => setDetails({ title: t.title, kind: t.kind, customer_id: t.customer_id || '', client_name: t.customer_id ? '' : t.client_name || '', client_ref: t.client_ref || '', location: t.location || '', deadline: toLocalInput(t.submission_deadline), est_value: t.est_value ? String(t.est_value) : '', est_cost: t.est_cost ? String(t.est_cost) : '', bid_bond_required: !!t.bid_bond_required, bid_bond_amount: t.bid_bond_amount != null ? String(t.bid_bond_amount) : '', engineering_lead_id: t.engineering_lead_id || '', finance_lead_id: t.finance_lead_id || '', notes: t.notes || '' })}>Edit</button>}
      {open && <button className="btn primary" type="button" onClick={() => setMove({ to: 'submitted', date: today(), value: String(t.est_value || ''), note: '' })}>Mark submitted</button>}
      {(t.status === 'submitted' || (t.kind === 'direct_award' && open)) && can('sales', 'accountant') && <button className="btn primary" type="button" onClick={() => setAward({ type: t.kind === 'direct_award' ? 'purchase_order' : 'contract', ref: '', signed: today(), value: String(t.submitted_value || t.est_value || ''), note: '', file: null, days: String(t.payment_terms_days ?? 30), adv: String(t.advance_pct ?? 0), ret: String(t.retention_pct ?? 0), terms: t.payment_terms_notes || '' })}>Record award</button>}
      {t.status === 'submitted' && <button className="btn" type="button" onClick={() => setMove({ to: 'lost', date: today(), note: '' })}>Lost</button>}
      {open && <button className="btn ghost" type="button" onClick={() => setMove({ to: 'no_bid', date: today(), note: '' })}>Not bidding</button>}
      {t.status === 'awarded' && !t.project && can('accountant') && <button className="btn primary" type="button" onClick={() => setReg({ name: t.title, cost_centre: centres[0]?.id || '', manager: t.engineering_lead_id || '', start: today(), end: '', billing: 'fixed_price' })}>Register project</button>}
      {t.project && <Link className="btn" to={'/projects/' + t.project.id}>Project {t.project.number}</Link>}
      <VoidButton table="tenders" id={t.id} label={t.number || 'this tender'} small={false} onDone={done} />
    </PageHead>
    {t.status === 'voided' && <div className="note" style={{ background: 'var(--bad-soft, #fbebeb)' }}>Voided{t.voided_at ? ' on ' + longDate(t.voided_at.slice(0, 10)) : ''}: {t.void_reason}</div>}
    <div className="tiles">
      <div className="tile"><span>Deadline</span><b style={{ fontSize: 16 }}>{t.submission_deadline ? t.submission_deadline.slice(0, 16).replace('T', ' ') : '—'}</b></div>
      <div className="tile"><span>Estimated value / cost</span><b style={{ fontSize: 16 }}>{cedis(t.est_value)} / {money(t.est_cost)}</b>{margin(t) != null && <span className="muted" style={{ fontSize: 12 }}>margin {margin(t)}%</span>}</div>
      {t.submitted_value != null && <div className="tile"><span>Submitted</span><b style={{ fontSize: 16 }}>{cedis(t.submitted_value)}</b><span className="muted" style={{ fontSize: 12 }}>{longDate(t.submitted_at)}</span></div>}
      {t.status === 'awarded' && <div className="tile"><span>Awarded</span><b style={{ fontSize: 16 }}>{cedis(t.awarded_value)}</b><span className="muted" style={{ fontSize: 12 }}>{(t.award_type || '').replace('_', ' ')} {t.contract_ref} · {longDate(t.contract_signed_on)}</span></div>}
      <div className="tile"><span>Leads</span><b style={{ fontSize: 13 }}>BD {who(t.bd_owner_id).split('@')[0] || '—'} · Eng {who(t.engineering_lead_id).split('@')[0] || '—'} · Fin {who(t.finance_lead_id).split('@')[0] || '—'}</b></div>
    </div>
    {t.status === 'awarded' && !t.project && <div className="note" style={{ background: 'var(--warn-soft)' }}>Awarded but not yet registered. Finance must register the project and its cost centre before any spending, then hold the post-award meeting.</div>}
    {t.lost_reason && <div className="note">{TENDER_STATUS[t.status][0]}: {t.lost_reason}</div>}
    {t.bid_bond_required && <div className="note">Bid bond required{t.bid_bond_amount ? ': ' + cedis(t.bid_bond_amount) : ''}.</div>}

    <Panel title={<div className="actions"><h2>Pre-submission review</h2>{r && <span className={'pill ' + (r.decision === 'go' ? 'good' : r.decision === 'no_go' ? 'bad' : 'warn')}>{r.decision === 'go' ? 'Go' : r.decision === 'no_go' ? 'No go' : r.decision === 'revise' ? 'Revise' : 'Decision pending'}</span>}</div>}
      actions={r && open && <Select label="" id="rv-dec" value={r.decision || ''} onChange={v => act.run(async () => { await q(supabase.from('tender_reviews').update({ decision: v || null }).eq('id', r.id) as any); done(); })} options={[['', 'Decision…'], ['go', 'Go: submit'], ['revise', 'Revise and review again'], ['no_go', 'No go: do not bid']]} />}>
      {r ? <div className="body" style={{ display: 'grid', gap: 12 }}>
        <div className="muted" style={{ fontSize: 13 }}>Meeting {longDate(r.meeting_date)}{r.summary_shared_on ? ` · summary shared ${longDate(r.summary_shared_on)}` : ' · summary report not yet shared'}{r.attendees ? ' · ' + r.attendees : ''}</div>
        <div className="grid-form" style={{ alignItems: 'start' }}>{units.map(([u, label]) => { const input = r[u + '_input']; const ok = r[u + '_ok_by'];
          return <div key={u} style={{ border: '1px solid var(--line)', borderRadius: 8, padding: 12, display: 'grid', gap: 8 }}>
            <div className="actions" style={{ justifyContent: 'space-between' }}><b>{label}</b>{ok ? <span className="pill good">Signed</span> : <span className="pill warn">Not signed</span>}</div>
            <div style={{ whiteSpace: 'pre-wrap', fontSize: 14 }}>{input || <span className="muted">No input yet</span>}</div>
            {ok && <span className="muted" style={{ fontSize: 12 }}>{r[u + '_ok_email']} · {r[u + '_ok_at']?.slice(0, 10)}</span>}
            {open && (unitCan(u) || can('admin')) && <div className="actions">
              <button className="btn small" type="button" onClick={() => setEdit({ unit: u, text: input || '' })}>{input ? 'Edit input' : 'Add input'}</button>
              {!ok && input && <button className="btn small primary" type="button" disabled={act.busy} onClick={() => act.run(async () => { await rpc('sign_tender_review', { p_review: r.id, p_unit: u }); done(); }, label + ' signed off')}>Sign off</button>}</div>}
          </div>; })}</div>
        {r.minutes && <div className="note" style={{ whiteSpace: 'pre-wrap' }}>{r.minutes}</div>}
        {open && <div><button className="btn small ghost" type="button" onClick={() => setEdit({ unit: 'minutes', text: r.minutes || '' })}>Minutes</button></div>}
        <p className="muted" style={{ margin: 0, fontSize: 13 }}>Business Development takes each unit's input into the final tender documents. The tender can be marked submitted only when all three units have signed a "Go". Changing any input afterwards clears the signatures.</p>
      </div> : <Empty>Schedule the pre-submission review with Business Development, Finance and Engineering. Share the summary report with them before the meeting.</Empty>}
    </Panel>

    <div className="two">
      <Panel title="Files" actions={<button className="btn small primary" type="button" onClick={() => setFile({ kind: 'tender_docs', file: null })}>Upload</button>}>
        {files.length ? <div className="scroll"><table><tbody>{files.map(f => <tr key={f.id}><td><button className="btn ghost small" style={{ padding: 0 }} type="button" onClick={() => openFile(f)}>{f.name}</button></td>
          <td className="muted">{FILE_KINDS.find(k => k[0] === f.kind)?.[1]}</td><td className="muted num">{f.created_at.slice(0, 10)}</td></tr>)}</tbody></table></div>
          : <Empty>Tender documents, the summary report, pricing, the final submission and the signed contract or PO.</Empty>}
      </Panel>
      <Panel title="Meetings" actions={<button className="btn small" type="button" onClick={() => setMeet({ kind: t.status === 'awarded' ? 'post_award' : 'other', meeting_date: today(), attendees: '', minutes: '', decisions: '', responsibilities: '' })}>Record meeting</button>}>
        {meetings.length ? <div className="scroll"><table><tbody>{meetings.map(m => <tr key={m.id}><td className="num" style={{ width: 100 }}>{m.meeting_date}</td>
          <td className="wrap-cell"><b>{m.kind === 'post_award' ? 'Post-award meeting' : 'Meeting'}</b> <span className="muted">{m.attendees}</span>{m.decisions && <><br />{m.decisions}</>}{m.responsibilities && <><br /><span className="muted">Roles: {m.responsibilities}</span></>}</td></tr>)}</tbody></table></div>
          : <Empty>{t.status === 'awarded' ? 'Hold the post-award meeting: how the project will be executed and each unit\'s role at each stage.' : 'No meetings recorded.'}</Empty>}
      </Panel>
    </div>
    {t.notes && <div className="note" style={{ whiteSpace: 'pre-wrap' }}>{t.notes}</div>}

    {review && <FormModal title="Schedule the pre-submission review" busy={act.busy} onClose={() => setReview(null)} onSave={() => act.run(async () => {
      await q(supabase.from('tender_reviews').insert({ tender_id: id, company_id: cid, meeting_date: review.meeting_date, summary_shared_on: review.summary_shared_on || null, attendees: review.attendees || null }) as any); setReview(null); done(); }, 'Review scheduled; the units have been notified')}>
      <div className="grid-form"><Field label="Meeting date" id="rv-date" type="date" value={review.meeting_date} onChange={v => setReview({ ...review, meeting_date: v })} required />
        <Field label="Summary report shared on" id="rv-sum" type="date" value={review.summary_shared_on} onChange={v => setReview({ ...review, summary_shared_on: v })} /></div>
      <Field label="Attendees" id="rv-att" value={review.attendees} onChange={v => setReview({ ...review, attendees: v })} placeholder="BD, Finance, Engineering" />
      <p className="muted" style={{ margin: 0, fontSize: 13 }}>Upload the summary report under Files so everyone can read it before the meeting.</p>
    </FormModal>}
    {details && <FormModal title="Edit tender details" busy={act.busy} onClose={() => setDetails(null)} onSave={() => act.run(async () => {
      const cust = customers.find(c => c.id === details.customer_id);
      await q(supabase.from('tenders').update({ title: details.title, kind: details.kind, customer_id: details.customer_id || null, client_name: cust ? cust.name : details.client_name || null,
        client_ref: details.client_ref || null, location: details.location || null, submission_deadline: details.deadline ? new Date(details.deadline).toISOString() : null,
        est_value: Number(details.est_value) || 0, est_cost: Number(details.est_cost) || 0, bid_bond_required: details.bid_bond_required, bid_bond_amount: details.bid_bond_required && details.bid_bond_amount ? Number(details.bid_bond_amount) : null,
        engineering_lead_id: details.engineering_lead_id || null, finance_lead_id: details.finance_lead_id || null, notes: details.notes || null }).eq('id', id) as any);
      setDetails(null); done(); }, 'Tender details saved')}>
      <TenderFields f={details} set={setDetails} customers={customers} team={team} />
    </FormModal>}
    {edit && r && <FormModal title={edit.unit === 'minutes' ? 'Meeting minutes' : `${units.find(u => u[0] === edit.unit)?.[1]} input`} busy={act.busy} onClose={() => setEdit(null)} onSave={() => act.run(async () => {
      await q(supabase.from('tender_reviews').update({ [edit.unit === 'minutes' ? 'minutes' : edit.unit + '_input']: edit.text || null }).eq('id', r.id) as any); setEdit(null); done(); }, 'Saved')}>
      <Field label={edit.unit === 'finance' ? 'Pricing, cash flow, bid bond, payment terms, risks' : edit.unit === 'engineering' ? 'Scope, method, programme, resources, cost estimate' : edit.unit === 'bd' ? 'Client, competition, commercial terms, strategy' : 'Minutes'} id="rv-text" type="textarea" value={edit.text} onChange={v => setEdit({ ...edit, text: v })} />
      {edit.unit !== 'minutes' && <p className="muted" style={{ margin: 0, fontSize: 13 }}>Changing the input clears any sign-offs already given; they sign again.</p>}
    </FormModal>}
    {move && <FormModal title={move.to === 'submitted' ? 'Mark as submitted' : move.to === 'lost' ? 'Tender lost' : 'Not bidding'} busy={act.busy} onClose={() => setMove(null)} onSave={() => act.run(async () => {
      await rpc('set_tender_status', { p_id: id, p_to: move.to, p_note: move.note || null, p_date: move.date, p_value: move.value ? Number(move.value) : null }); setMove(null); done(); }, 'Updated')}>
      <div className="grid-form"><Field label="Date" id="mv-date" type="date" value={move.date} onChange={v => setMove({ ...move, date: v })} required />
        {move.to === 'submitted' && <Field label="Value submitted (GH₵)" id="mv-val" type="number" step="0.01" min="0" value={move.value} onChange={v => setMove({ ...move, value: v })} />}</div>
      {move.to !== 'submitted' && <Field label="Reason" id="mv-note" type="textarea" value={move.note} onChange={v => setMove({ ...move, note: v })} placeholder={move.to === 'lost' ? 'Who won, at what price, and what we learned' : 'Why we are not bidding'} />}
    </FormModal>}
    {award && <FormModal title="Record the award" submit="Record award" busy={act.busy} onClose={() => setAward(null)} onSave={() => act.run(async () => {
      if (award.file) { const f = await uploadDocFile(cid, 'tenders/' + id, award.file); await q(supabase.from('tender_files').insert({ tender_id: id, company_id: cid, kind: award.type === 'purchase_order' ? 'purchase_order' : 'contract', name: f.name, storage_path: f.path, size_bytes: f.size }) as any); }
      await q(supabase.from('tenders').update({ payment_terms_days: award.days ? Number(award.days) : null, advance_pct: Number(award.adv) || 0, retention_pct: Number(award.ret) || 0, payment_terms_notes: award.terms || null }).eq('id', id) as any);
      await rpc('award_tender', { p_id: id, p_type: award.type, p_ref: award.ref, p_signed: award.signed || null, p_value: Number(award.value), p_note: award.note || null }); setAward(null); done(); }, 'Award recorded; Finance and Engineering notified')}>
      <div className="grid-form">
        <Select label="Award by" id="aw-type" value={award.type} onChange={v => setAward({ ...award, type: v })} options={[['contract', 'Signed contract'], ['purchase_order', 'Client purchase order'], ['letter_of_award', 'Letter of award']]} />
        <Field label="Contract or PO number" id="aw-ref" value={award.ref} onChange={v => setAward({ ...award, ref: v })} required />
        <Field label="Signed or issued on" id="aw-date" type="date" value={award.signed} onChange={v => setAward({ ...award, signed: v })} />
        <Field label="Value (GH₵, excl. VAT)" id="aw-val" type="number" step="0.01" min="0" value={award.value} onChange={v => setAward({ ...award, value: v })} required />
      </div>
      <div className="grid-form">
        <Field label="Client pays within (days)" id="aw-days" type="number" step="1" min="0" value={award.days} onChange={v => setAward({ ...award, days: v })} />
        <Field label="Advance %" id="aw-adv" type="number" step="0.01" min="0" max="100" value={award.adv} onChange={v => setAward({ ...award, adv: v })} />
        <Field label="Retention %" id="aw-ret" type="number" step="0.01" min="0" max="50" value={award.ret} onChange={v => setAward({ ...award, ret: v })} />
      </div>
      <Field label="Payment terms in the contract" id="aw-terms" value={award.terms} onChange={v => setAward({ ...award, terms: v })} placeholder="e.g. Interim payments within 45 days; retention released after 12 months" />
      <div className="field"><label htmlFor="aw-file">Signed contract or PO (PDF)</label><input id="aw-file" type="file" onChange={e => setAward({ ...award, file: e.target.files?.[0] || null })} /></div>
      <Field label="Notes" id="aw-note" value={award.note} onChange={v => setAward({ ...award, note: v })} />
    </FormModal>}
    {reg && <FormModal title="Register the project" submit="Register" busy={act.busy} onClose={() => setReg(null)} onSave={() => act.run(async () => {
      const p = await rpc<string>('register_project_from_tender', { p_tender: id, p_name: reg.name, p_cost_centre: reg.cost_centre || null, p_manager: reg.manager || null, p_start: reg.start || null, p_end: reg.end || null, p_billing: reg.billing, p_branch: null });
      nav('/projects/' + p); }, 'Project registered; the project manager has been notified')}>
      <Field label="Project name" id="rg-name" value={reg.name} onChange={v => setReg({ ...reg, name: v })} required />
      <div className="grid-form">
        <Select label="Cost centre" id="rg-cc" value={reg.cost_centre} onChange={v => setReg({ ...reg, cost_centre: v })} options={[['', 'Choose…'], ...centres.map(c => [c.id, `${c.code} ${c.name}`] as [string, string])]} />
        <Select label="Project manager" id="rg-pm" value={reg.manager} onChange={v => setReg({ ...reg, manager: v })} options={[['', '—'], ...team.filter(m => ['project_manager', 'owner', 'admin'].includes(m.role)).map(m => [m.user_id, m.email] as [string, string])]} />
        <Field label="Start" id="rg-start" type="date" value={reg.start} onChange={v => setReg({ ...reg, start: v })} />
        <Field label="Target end" id="rg-end" type="date" value={reg.end} onChange={v => setReg({ ...reg, end: v })} />
        <Select label="Billing" id="rg-bill" value={reg.billing} onChange={v => setReg({ ...reg, billing: v })} options={[['fixed_price', 'Fixed price (milestones)'], ['time_materials', 'Time and materials']]} />
      </div>
      <p className="muted" style={{ margin: 0, fontSize: 13 }}>Creates the project code with the contract {t.contract_ref} worth {cedis(t.awarded_value)} and the cost centre. The project manager then submits the budget; spending starts once Finance approves it.{!centres.length && ' Add a cost centre under Settings first.'}</p>
    </FormModal>}
    {file && <FormModal title="Upload a file" busy={act.busy} onClose={() => setFile(null)} onSave={() => act.run(async () => {
      if (!file.file) throw new Error('Choose a file.');
      const f = await uploadDocFile(cid, 'tenders/' + id, file.file);
      await q(supabase.from('tender_files').insert({ tender_id: id, company_id: cid, kind: file.kind, name: f.name, storage_path: f.path, size_bytes: f.size }) as any); setFile(null); done(); }, 'Uploaded')}>
      <Select label="What it is" id="tf-kind" value={file.kind} onChange={v => setFile({ ...file, kind: v })} options={FILE_KINDS} />
      <div className="field"><label htmlFor="tf-file">File</label><input id="tf-file" type="file" onChange={e => setFile({ ...file, file: e.target.files?.[0] || null })} /></div>
    </FormModal>}
    {meet && <MeetingForm meet={meet} setMeet={setMeet} target={{ tender_id: id }} cid={cid} onDone={done} />}
  </>;
}

export function MeetingForm({ meet, setMeet, target, cid, onDone }: { meet: any; setMeet: (m: any) => void; target: any; cid: string; onDone: () => void }) {
  const act = useAction();
  return <FormModal title={meet.kind === 'post_award' ? 'Post-award meeting' : meet.kind === 'progress' ? 'Progress meeting' : meet.kind === 'management' ? 'Management meeting' : 'Meeting'} busy={act.busy} onClose={() => setMeet(null)} onSave={() => act.run(async () => {
    await q(supabase.from('project_meetings').insert({ ...target, company_id: cid, kind: meet.kind, meeting_date: meet.meeting_date, attendees: meet.attendees || null, minutes: meet.minutes || null, decisions: meet.decisions || null, responsibilities: meet.responsibilities || null }) as any);
    setMeet(null); onDone(); }, 'Meeting recorded')}>
    <div className="grid-form">
      <Select label="Meeting" id="mt-kind" value={meet.kind} onChange={v => setMeet({ ...meet, kind: v })} options={[['post_award', 'Post-award (kick-off)'], ['progress', 'Progress'], ['management', 'Management'], ['other', 'Other']]} />
      <Field label="Date" id="mt-date" type="date" value={meet.meeting_date} onChange={v => setMeet({ ...meet, meeting_date: v })} required />
    </div>
    <Field label="Attendees" id="mt-att" value={meet.attendees} onChange={v => setMeet({ ...meet, attendees: v })} />
    <Field label="Minutes" id="mt-min" type="textarea" value={meet.minutes} onChange={v => setMeet({ ...meet, minutes: v })} />
    <Field label="Decisions and actions" id="mt-dec" type="textarea" value={meet.decisions} onChange={v => setMeet({ ...meet, decisions: v })} />
    {meet.kind === 'post_award' && <Field label="Role of each unit at each stage" id="mt-roles" type="textarea" value={meet.responsibilities} onChange={v => setMeet({ ...meet, responsibilities: v })} placeholder="Engineering: weekly progress reports, certify milestones. Finance: invoice the advance within 3 days, monthly cost reconciliation. BD: client liaison on variations." />}
  </FormModal>;
}
