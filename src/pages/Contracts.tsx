import { useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { q, rpc, supabase } from '../lib/supabase';
import { useSession } from '../lib/session';
import { longDate, money, today } from '../lib/format';
import { downloadCsv } from '../lib/download';
import { tablePdf } from '../lib/pdf';
import { uploadDocFile } from '../components/ProjectDocs';
import { ConfirmButton, Downloads, Empty, Field, FormModal, Loading, PageHead, Panel, Select, useAction, useLoad } from '../components/ui';

export const KINDS: [string, string][] = [['client', 'Client contract'], ['supplier', 'Supply contract'], ['subcontract', 'Subcontract'], ['service', 'Service or maintenance'], ['lease', 'Lease or rental'], ['other', 'Other']];
const kindName = (k: string) => (KINDS.find(x => x[0] === k) || [k, k])[1];
const STATE: Record<string, [string, string]> = {
  draft: ['Draft', ''], active: ['Active', 'good'], ending_soon: ['Ending soon', 'warn'], expired: ['Past end date', 'bad'],
  on_hold: ['On hold', 'warn'], terminated: ['Terminated', 'bad'], closed: ['Closed', ''],
};
const SEC_KINDS: [string, string][] = [['performance_bond', 'Performance bond'], ['advance_payment_guarantee', 'Advance payment guarantee'], ['retention_bond', 'Retention bond'],
  ['bid_bond', 'Bid bond'], ['insurance', 'Insurance (CAR, third party)'], ['warranty', 'Warranty'], ['other', 'Other']];
const secName = (k: string) => (SEC_KINDS.find(x => x[0] === k) || [k, k])[1];
const Pill = ({ s }: { s: string }) => { const [l, c] = STATE[s] || [s, '']; return <span className={'pill ' + c}>{l}</span>; };
const days = (n: number | null | undefined) => n == null ? '' : n === 0 ? 'today' : n === -1 ? 'yesterday' : n === 1 ? 'tomorrow' : n < 0 ? `${-n} days ago` : `in ${n} days`;
const blank = { title: '', kind: 'client', customer_id: '', supplier_id: '', counterparty: '', their_ref: '', project_id: '', value: '', currency: 'GHS',
  signed_on: '', start_date: today(), end_date: '', status: 'active', payment_terms_days: '', advance_pct: '', retention_pct: '', notice_days: '30', auto_renew: false, renewal_months: '', description: '' };

function useParties(cid: string) {
  return useLoad(async () => {
    const [customers, suppliers, projects] = await Promise.all([
      q<any[]>(supabase.from('customers').select('id,name').eq('company_id', cid).order('name') as any),
      q<any[]>(supabase.from('suppliers').select('id,name').eq('company_id', cid).order('name') as any),
      q<any[]>(supabase.from('projects').select('id,number,name').eq('company_id', cid).order('name') as any),
    ]);
    return { customers, suppliers, projects };
  }, [cid]);
}

/** Add or edit a contract. */
function ContractForm({ initial, onClose, onSaved }: { initial: any; onClose: () => void; onSaved: (id: string) => void }) {
  const { cid } = useSession();
  const act = useAction();
  const [f, setF] = useState<any>(initial);
  const { data: p } = useParties(cid);
  const set = (k: string) => (v: any) => setF({ ...f, [k]: v });
  const client = f.kind === 'client';
  return <FormModal title={f.id ? `Edit ${f.number}` : 'New contract'} busy={act.busy} onClose={onClose} onSave={() => act.run(async () => {
    const num = (v: any) => v === '' || v == null ? null : Number(v);
    const row: any = { title: f.title.trim(), kind: f.kind, customer_id: client ? f.customer_id || null : null, supplier_id: client ? null : f.supplier_id || null,
      counterparty: f.counterparty?.trim() || null, their_ref: f.their_ref || null, project_id: f.project_id || null, value: Number(f.value) || 0, currency: f.currency || 'GHS',
      signed_on: f.signed_on || null, start_date: f.start_date || null, end_date: f.end_date || null, status: f.status,
      payment_terms_days: num(f.payment_terms_days), advance_pct: num(f.advance_pct), retention_pct: num(f.retention_pct), notice_days: Number(f.notice_days) || 30,
      auto_renew: !!f.auto_renew, renewal_months: f.auto_renew ? num(f.renewal_months) : null, description: f.description || null };
    if (!row.title) throw new Error('Give the contract a title.');
    if (!row.customer_id && !row.supplier_id && !row.counterparty) throw new Error('Choose who the contract is with.');
    if (f.id) { if (!f.counterparty_typed) delete row.counterparty; await q(supabase.from('contracts').update(row).eq('id', f.id) as any); onSaved(f.id); }
    else { const r = await q<any>(supabase.from('contracts').insert({ ...row, company_id: cid }).select('id').single() as any); onSaved(r.id); }
  }, 'Contract saved')}>
    <Field label="Title" id="ct-title" value={f.title} onChange={set('title')} placeholder="e.g. Prestea 161 kV substation civil works" required />
    <div className="grid-form">
      <Select label="Type" id="ct-kind" value={f.kind} onChange={set('kind')} options={KINDS} />
      {client
        ? <Select label="Client" id="ct-cust" value={f.customer_id} onChange={set('customer_id')} options={[['', 'Not a customer record (type below)'], ...(p?.customers || []).map(c => [c.id, c.name] as [string, string])]} />
        : <Select label="Supplier or subcontractor" id="ct-sup" value={f.supplier_id} onChange={set('supplier_id')} options={[['', 'Not a supplier record (type below)'], ...(p?.suppliers || []).map(c => [c.id, c.name] as [string, string])]} />}
      {!(client ? f.customer_id : f.supplier_id) && <Field label="Other party's name" id="ct-cp" value={f.counterparty} onChange={v => setF({ ...f, counterparty: v, counterparty_typed: true })} />}
      <Field label="Their reference (contract, PO or LPO no.)" id="ct-ref" value={f.their_ref} onChange={set('their_ref')} />
      <Select label="Project" id="ct-pj" value={f.project_id} onChange={set('project_id')} options={[['', 'None (company-wide)'], ...(p?.projects || []).map(x => [x.id, `${x.number || ''} ${x.name}`.trim()] as [string, string])]} />
      <Select label="Status" id="ct-st" value={f.status} onChange={set('status')} options={[['draft', 'Draft (not signed yet)'], ['active', 'Active'], ['on_hold', 'On hold'], ['closed', 'Closed'], ['terminated', 'Terminated']]} />
      <Field label="Contract value" id="ct-val" type="number" step="0.01" min="0" value={f.value} onChange={set('value')} />
      <Field label="Currency" id="ct-cur" value={f.currency} onChange={set('currency')} />
      <Field label="Signed on" id="ct-sig" type="date" value={f.signed_on} onChange={set('signed_on')} />
      <Field label="Starts" id="ct-start" type="date" value={f.start_date} onChange={set('start_date')} />
      <Field label="Ends" id="ct-end" type="date" value={f.end_date} onChange={set('end_date')} />
      <Field label="Remind me this many days before the end" id="ct-not" type="number" min="0" value={f.notice_days} onChange={set('notice_days')} />
      <Field label="Payment within (days of invoice)" id="ct-pt" type="number" min="0" value={f.payment_terms_days} onChange={set('payment_terms_days')} />
      <Field label="Advance %" id="ct-adv" type="number" step="0.01" min="0" max="100" value={f.advance_pct} onChange={set('advance_pct')} />
      <Field label="Retention %" id="ct-ret" type="number" step="0.01" min="0" max="100" value={f.retention_pct} onChange={set('retention_pct')} />
    </div>
    {f.status === 'terminated' && <Field label="Why it was terminated" id="ct-term" type="textarea" value={f.termination_note || ''} onChange={set('termination_note')} required />}
    <label className="check"><input type="checkbox" checked={!!f.auto_renew} onChange={e => setF({ ...f, auto_renew: e.target.checked })} /> Renews automatically unless notice is given</label>
    {f.auto_renew && <Field label="Renews for (months)" id="ct-renm" type="number" min="1" value={f.renewal_months} onChange={set('renewal_months')} />}
    <Field label="Scope and key terms" id="ct-desc" type="textarea" value={f.description} onChange={set('description')} />
  </FormModal>;
}

export function ContractsPage() {
  const { cid, company, can } = useSession();
  const nav = useNavigate();
  const [show, setShow] = useState('live');
  const [search, setSearch] = useState('');
  const [add, setAdd] = useState<any | null>(null);
  const { data, error, loading } = useLoad(async () => {
    try { await rpc('run_contract_reminders', { cid }); } catch { /* best effort */ }
    const [list, alerts] = await Promise.all([rpc<any[]>('contract_register', { cid }), rpc<any[]>('contract_alerts', { cid, p_days: 30 })]);
    return { list, alerts };
  }, [cid]);
  const FILTERS: [string, string, (c: any) => boolean][] = [
    ['live', 'Active', c => ['active', 'ending_soon', 'expired', 'on_hold'].includes(c.display_status)],
    ['ending', 'Ending or ended', c => ['ending_soon', 'expired'].includes(c.display_status)],
    ['client', 'With clients', c => c.kind === 'client'],
    ['suppliers', 'Suppliers & subcontractors', c => c.kind !== 'client'],
    ['draft', 'Drafts', c => c.status === 'draft'],
    ['done', 'Closed or terminated', c => ['closed', 'terminated'].includes(c.status)],
    ['all', 'All', () => true],
  ];
  const fl = FILTERS.find(x => x[0] === show)!;
  const list = (data?.list || []).filter(fl[2]).filter(c => !search || `${c.number} ${c.title} ${c.counterparty || ''} ${c.their_ref || ''} ${c.project || ''}`.toLowerCase().includes(search.toLowerCase()));
  const head = ['No.', 'Contract', 'Type', 'With', 'Project', 'Status', 'Currency', 'Value', 'Variations', 'Revised value', 'Billed', 'Paid', 'Remaining', 'Starts', 'Ends'];
  const rows = list.map(c => [c.number, c.title, kindName(c.kind), c.counterparty || '', c.project || '', (STATE[c.display_status] || [c.display_status])[0], c.currency,
    money(c.value), money(c.variations), money(c.revised_value), money(c.billed), money(c.paid), money(c.remaining), c.start_date || '', c.end_date || '']);
  return <>
    <PageHead title="Contracts" sub={data ? `${data.list.filter(c => c.status === 'active').length} active · ${data.alerts.length} need attention` : undefined}>
      <Downloads pdf={() => tablePdf({ company: company!, title: 'Contract register', subtitle: `${fl[1]} · ${longDate(today())}`, head, body: rows, rightAlign: [7, 8, 9, 10, 11, 12], landscape: true, filename: 'contract-register-' + today() })}
        csv={() => downloadCsv('contract-register-' + today(), head, rows)} />
      {can('accountant', 'sales', 'project_manager') && <button className="btn primary" type="button" onClick={() => setAdd({ ...blank })}>New contract</button>}
    </PageHead>
    <Loading error={error} loading={loading && !data} />
    {data && data.alerts.length > 0 && <Panel title="Needs attention">
      <div className="scroll"><table><tbody>{data.alerts.slice(0, 12).map((a, i) => <tr key={i}>
        <td style={{ width: 140 }}><span className={'pill ' + (a.days_left < 0 ? 'bad' : 'warn')}>{{ contract_end: 'Contract end', security_expiry: 'Bond / guarantee', obligation: 'Key date', variation: 'Variation' }[a.kind as string]}</span></td>
        <td><Link to={'/contracts/' + a.contract_id}>{a.contract}</Link> · {a.title}</td>
        <td className="num" style={{ whiteSpace: 'nowrap' }}>{a.kind === 'variation' ? `raised ${a.due}` : `${a.due} · ${days(a.days_left)}`}</td></tr>)}</tbody></table></div>
    </Panel>}
    {data && <>
      <div className="chips" role="tablist">{FILTERS.map(([k, l, fn]) => <button key={k} type="button" role="tab" aria-selected={show === k} className={'chip' + (show === k ? ' on' : '')} onClick={() => setShow(k)}>{l} <span>{data.list.filter(fn).length}</span></button>)}</div>
      <div className="filters"><div className="field" style={{ width: 300 }}><label htmlFor="ct-search">Search</label><input id="ct-search" placeholder="Number, title, party, reference, project" value={search} onChange={e => setSearch(e.target.value)} /></div></div>
      <Panel>{list.length ? <div className="scroll"><table>
        <thead><tr><th>Contract</th><th>Status</th><th className="r">Revised value</th><th className="r">Billed</th><th className="r">Remaining</th><th>Ends</th><th></th></tr></thead>
        <tbody>{list.map(c => <tr key={c.id} className="clickable" onClick={() => nav('/contracts/' + c.id)}>
          <td><Link to={'/contracts/' + c.id} onClick={e => e.stopPropagation()}><b>{c.number}</b></Link> {c.title}<br /><span className="muted"><b style={{ fontWeight: 600, color: 'var(--fg)' }}>{c.counterparty}</b> · {kindName(c.kind)}{c.project ? ' · ' + c.project : ''}{c.their_ref ? ' · ' + c.their_ref : ''}</span></td>
          <td><Pill s={c.display_status} />{c.pending_variations > 0 && <><br /><span className="muted" style={{ fontSize: 12 }}>{c.pending_variations} variation{c.pending_variations > 1 ? 's' : ''} pending</span></>}</td>
          <td className="r num">{c.currency !== 'GHS' ? c.currency + ' ' : ''}{money(c.revised_value)}</td>
          <td className="r num">{money(c.billed)}</td><td className="r num">{money(c.remaining)}</td>
          <td className="num">{c.end_date || '—'}{c.end_date && c.status === 'active' && <><br /><span className="muted" style={{ fontSize: 12 }}>{days(c.days_left)}</span></>}</td>
          <td>{(c.securities_expiring > 0 || c.obligations_overdue > 0) && <span className="pill bad" title="Bond expiring or key date overdue">!</span>}</td>
        </tr>)}</tbody></table></div>
        : <Empty>{data.list.length ? 'No contracts match.' : 'No contracts yet. Awarded tenders are added here automatically; add supplier, subcontract, service and lease contracts with New contract.'}</Empty>}</Panel>
    </>}
    {add && <ContractForm initial={add} onClose={() => setAdd(null)} onSaved={id => { setAdd(null); nav('/contracts/' + id); }} />}
  </>;
}

export function ContractView() {
  const { id } = useParams();
  const { cid, company, can, session } = useSession();
  const act = useAction();
  const nav = useNavigate();
  const [edit, setEdit] = useState<any | null>(null);
  const [vo, setVo] = useState<any | null>(null);
  const [decide, setDecide] = useState<any | null>(null);
  const [sec, setSec] = useState<any | null>(null);
  const [obl, setObl] = useState<any | null>(null);
  const [file, setFile] = useState<{ kind: string; f: File | null } | null>(null);
  const { data, error, loading, reload } = useLoad(async () => {
    const c = await q<any>(supabase.from('contracts').select('*, project:projects(id,number,name), tender:tenders(id,number)').eq('id', id).single() as any);
    const [figs, vars, secs, obls, files, team] = await Promise.all([
      rpc<any[]>('contract_register', { cid }).then(r => r.find(x => x.id === id)),
      q<any[]>(supabase.from('contract_variations').select('*').eq('contract_id', id).order('created_at') as any),
      q<any[]>(supabase.from('contract_securities').select('*').eq('contract_id', id).order('expires_on') as any),
      q<any[]>(supabase.from('contract_obligations').select('*').eq('contract_id', id).order('due_date') as any),
      q<any[]>(supabase.from('contract_files').select('*').eq('contract_id', id).order('created_at', { ascending: false }) as any),
      q<any[]>(supabase.from('memberships').select('user_id,email').eq('company_id', cid) as any),
    ]);
    return { c, figs, vars, secs, obls, files, team };
  }, [id]);
  if (!data) return <Loading error={error} loading={loading} />;
  const { c, figs, vars, secs, obls, files, team } = data;
  const finance = can('accountant');
  const editor = can('accountant', 'sales') || c.owner_id === session?.user.id || can('project_manager');
  const who = (u: string | null) => team.find(t => t.user_id === u)?.email || '';
  const cur = c.currency !== 'GHS' ? c.currency + ' ' : 'GH₵ ';
  const openFile = (f: any) => act.run(async () => { const { data: u, error: e } = await supabase.storage.from('project-docs').createSignedUrl(f.storage_path, 600); if (e) throw e; window.open(u.signedUrl, '_blank', 'noopener'); });
  const pcur = (c.currency || 'GHS') + ' ';   // PDF fonts have no cedi sign
  const summaryPdf = () => tablePdf({ company: company!, title: `${c.number} ${c.title}`, subtitle: `${kindName(c.kind)} with ${c.counterparty || ''}${c.their_ref ? ' · ' + c.their_ref : ''}`,
    head: ['Item', 'Detail'], body: [
      ['Status', (STATE[figs?.display_status] || [c.status])[0]], ['Project', c.project ? `${c.project.number || ''} ${c.project.name}` : '—'],
      ['Signed', c.signed_on || '—'], ['Period', `${c.start_date || '?'} to ${c.end_date || 'open'}`],
      ['Original value', pcur + money(c.value)], ['Approved variations', pcur + money(figs?.variations)], ['Revised value', pcur + money(figs?.revised_value)],
      ['Billed to date', pcur + money(figs?.billed)], ['Paid to date', pcur + money(figs?.paid)], ['Remaining to bill', pcur + money(figs?.remaining)],
      ['Payment terms', c.payment_terms_days != null ? `${c.payment_terms_days} days` : '—'], ['Advance / retention', `${c.advance_pct ?? 0}% / ${c.retention_pct ?? 0}%`],
      ...vars.map(v => [`${v.number} ${v.title}`, `${v.status} · ${money(v.value_change)}${v.days_extension ? ` · +${v.days_extension} days` : ''}`]),
      ...secs.map(s => [secName(s.kind), `${s.issuer || ''} ${s.reference || ''} · ${money(s.amount)} · expires ${s.expires_on || '—'} · ${s.status}`]),
      ...obls.map(o => [o.title, `${o.due_date} · ${o.status}`]),
    ], filename: `contract-${c.number}` });
  return <>
    <PageHead title={`${c.number} · ${c.title}`} sub={<>{kindName(c.kind)} with <b>{c.counterparty || '—'}</b>{c.their_ref ? ` · their ref ${c.their_ref}` : ''} · <Pill s={figs?.display_status || c.status} /></>}>
      <button className="btn" type="button" onClick={() => nav('/contracts')}>Back</button>
      <button className="btn" type="button" onClick={summaryPdf}>Summary PDF</button>
      {editor && <button className="btn" type="button" onClick={() => setEdit({ ...blank, ...Object.fromEntries(Object.entries(c).map(([k, v]) => [k, v ?? ''])) })}>Edit</button>}
      {c.status === 'draft' && editor && <button className="btn primary" type="button" disabled={act.busy} onClick={() => act.run(async () => { await q(supabase.from('contracts').update({ status: 'active' }).eq('id', c.id) as any); reload(); }, 'Contract is now active')}>Mark signed and active</button>}
    </PageHead>
    <div className="tiles">
      <div className="tile"><span>Original value ({cur.trim()})</span><b>{money(c.value)}</b></div>
      <div className="tile"><span>Approved variations</span><b>{money(figs?.variations)}</b></div>
      <div className="tile"><span>Revised value</span><b>{money(figs?.revised_value)}</b></div>
      <div className="tile"><span>{c.kind === 'client' ? 'Invoiced' : 'Billed by them'}</span><b>{money(figs?.billed)}</b></div>
      <div className="tile"><span>Paid</span><b>{money(figs?.paid)}</b></div>
      <div className="tile"><span>Remaining</span><b>{money(figs?.remaining)}</b></div>
    </div>
    <div className="two">
      <Panel title="Terms" pad>
        <dl className="facts">
          <dt>Project</dt><dd>{c.project ? <Link to={'/projects/' + c.project.id}>{c.project.number} {c.project.name}</Link> : 'None'}</dd>
          {c.tender && <><dt>Tender</dt><dd><Link to={'/tenders/' + c.tender.id}>{c.tender.number}</Link></dd></>}
          <dt>Signed</dt><dd>{c.signed_on ? longDate(c.signed_on) : 'Not recorded'}</dd>
          <dt>Period</dt><dd>{c.start_date ? longDate(c.start_date) : '?'} to {c.end_date ? longDate(c.end_date) : 'open-ended'}{figs?.end_date && c.status === 'active' ? ` (${days(figs.days_left)})` : ''}</dd>
          <dt>Payment</dt><dd>{c.payment_terms_days != null ? `Within ${c.payment_terms_days} days of invoice` : '—'}{c.advance_pct ? ` · ${c.advance_pct}% advance` : ''}{c.retention_pct ? ` · ${c.retention_pct}% retention` : ''}</dd>
          <dt>Renewal</dt><dd>{c.auto_renew ? `Renews automatically${c.renewal_months ? ` for ${c.renewal_months} months` : ''}` : 'Does not renew automatically'} · reminder {c.notice_days} days before the end</dd>
          <dt>Managed by</dt><dd>{who(c.owner_id) || '—'}</dd>
          {c.termination_note && <><dt>Terminated</dt><dd>{c.termination_note}</dd></>}
        </dl>
        {c.description && <p style={{ whiteSpace: 'pre-wrap', marginBottom: 0 }}>{c.description}</p>}
        {c.project && <p className="muted" style={{ fontSize: 13, marginBottom: 0 }}>Payment schedule and reminders: <Link to={'/projects/' + c.project.id}>project → Billing</Link>.</p>}
      </Panel>
      <Panel title="Signed copies and correspondence" actions={editor && <button className="btn small" type="button" onClick={() => setFile({ kind: 'signed_contract', f: null })}>Upload</button>}>
        {files.length ? <div className="scroll"><table><tbody>{files.map(f => <tr key={f.id}>
          <td><button className="btn ghost small" style={{ padding: 0 }} type="button" onClick={() => openFile(f)}>{f.name}</button><br /><span className="muted" style={{ fontSize: 12 }}>{f.kind.replace('_', ' ')} · {f.created_at.slice(0, 10)}</span></td>
          <td className="r">{editor && <ConfirmButton className="btn small ghost" label="Remove" confirm="Remove this file?" onConfirm={() => act.run(async () => { await q(supabase.from('contract_files').delete().eq('id', f.id) as any); reload(); })} />}</td></tr>)}</tbody></table></div>
          : <Empty>Upload the signed contract, letter of award, LPO and key letters so everyone works from the same copy.</Empty>}
      </Panel>
    </div>

    <Panel title="Variations and change orders" actions={editor && <button className="btn small" type="button" onClick={() => setVo({ title: '', description: '', value_change: '', days_extension: '0' })}>Propose variation</button>}>
      {vars.length ? <div className="scroll"><table>
        <thead><tr><th>No.</th><th>Change</th><th className="r">Value</th><th className="r">Extra days</th><th>Status</th><th></th></tr></thead>
        <tbody>{vars.map(v => <tr key={v.id}><td className="num">{v.number}</td><td>{v.title}{v.description && <><br /><span className="muted">{v.description}</span></>}<br /><span className="muted" style={{ fontSize: 12 }}>raised {v.requested_on}{v.decided_on ? ` · decided ${v.decided_on}${v.decision_note ? ': ' + v.decision_note : ''}` : ''}</span></td>
          <td className="r num">{money(v.value_change)}</td><td className="r num">{v.days_extension || ''}</td>
          <td><span className={'pill ' + ({ approved: 'good', rejected: 'bad', proposed: 'warn' } as any)[v.status]}>{v.status}</span></td>
          <td className="r" style={{ whiteSpace: 'nowrap' }}>{v.status === 'proposed' && finance && <button className="btn small" type="button" onClick={() => setDecide({ ...v, note: '' })}>Decide</button>}</td></tr>)}</tbody>
        <tfoot><tr><td></td><td>Approved total</td><td className="r num">{money(figs?.variations)}</td><td colSpan={3}></td></tr></tfoot></table></div>
        : <Empty>No variations. Record extra work, omissions and time extensions here; Finance approves them and the revised value and end date update.</Empty>}
    </Panel>

    <div className="two even">
      <Panel title="Bonds, guarantees and insurance" actions={editor && <button className="btn small" type="button" onClick={() => setSec({ kind: 'performance_bond', direction: 'given', issuer: '', reference: '', amount: '', issued_on: '', expires_on: '' })}>Add</button>}>
        {secs.length ? <div className="scroll"><table><tbody>{secs.map(s => <tr key={s.id}>
          <td><b>{secName(s.kind)}</b> <span className="muted">({s.direction === 'given' ? 'we gave' : 'we hold'})</span><br /><span className="muted">{[s.issuer, s.reference].filter(Boolean).join(' · ')}</span></td>
          <td className="r num">{money(s.amount)}</td>
          <td className="num">{s.expires_on || '—'}<br /><span className={'pill ' + (s.status !== 'active' ? '' : s.expires_on && s.expires_on < today() ? 'bad' : s.expires_on && s.expires_on <= new Date(Date.now() + 30 * 864e5).toISOString().slice(0, 10) ? 'warn' : 'good')}>{s.status}</span></td>
          <td className="r">{editor && s.status === 'active' && <select aria-label={`Update ${secName(s.kind)}`} value="" style={{ width: 'auto', padding: '4px 6px', fontSize: 13 }} onChange={e => { const v = e.target.value; if (v) act.run(async () => { await q(supabase.from('contract_securities').update({ status: v }).eq('id', s.id) as any); reload(); }, 'Updated'); }}>
            <option value="">Mark…</option><option value="released">Released</option><option value="claimed">Called</option><option value="expired">Expired</option></select>}</td></tr>)}</tbody></table></div>
          : <Empty>Track performance bonds, advance payment guarantees, retention bonds and insurance with their expiry dates. You are reminded 30 days before each expires.</Empty>}
      </Panel>
      <Panel title="Key dates and obligations" actions={editor && <button className="btn small" type="button" onClick={() => setObl({ title: '', due_date: '', responsible_id: session?.user.id || '', notes: '' })}>Add</button>}>
        {obls.length ? <div className="scroll"><table><tbody>{obls.map(o => <tr key={o.id}>
          <td>{o.title}<br /><span className="muted" style={{ fontSize: 12 }}>{who(o.responsible_id)}{o.notes ? ' · ' + o.notes : ''}</span></td>
          <td className="num">{o.due_date}<br />{o.status === 'open' ? <span className={'pill ' + (o.due_date < today() ? 'bad' : 'warn')}>{o.due_date < today() ? 'overdue' : 'open'}</span> : <span className="pill good">{o.status}{o.done_on ? ' ' + o.done_on : ''}</span>}</td>
          <td className="r" style={{ width: 1 }}>{editor && o.status === 'open' && <button className="btn small" type="button" disabled={act.busy} onClick={() => act.run(async () => { await q(supabase.from('contract_obligations').update({ status: 'done', done_on: today() }).eq('id', o.id) as any); reload(); }, 'Marked done')}>Done</button>}</td></tr>)}</tbody></table></div>
          : <Empty>Add the dates the contract commits you to: reports, insurance renewals, defects period end, final account. The person responsible is reminded a week ahead.</Empty>}
      </Panel>
    </div>

    {edit && <ContractForm initial={edit} onClose={() => setEdit(null)} onSaved={() => { setEdit(null); reload(); }} />}
    {vo && <FormModal title="Propose a variation" busy={act.busy} onClose={() => setVo(null)} onSave={() => act.run(async () => {
      if (!vo.title.trim()) throw new Error('Describe the change.');
      await q(supabase.from('contract_variations').insert({ contract_id: c.id, title: vo.title.trim(), description: vo.description || null, value_change: Number(vo.value_change) || 0, days_extension: Number(vo.days_extension) || 0 }) as any);
      setVo(null); reload(); }, 'Variation sent to Finance')}>
      <Field label="Change" id="vo-t" value={vo.title} onChange={v => setVo({ ...vo, title: v })} placeholder="e.g. Extra tower foundations at chainage 4+200" required />
      <div className="grid-form">
        <Field label={`Value change (${c.currency}); negative for omissions`} id="vo-v" type="number" step="0.01" value={vo.value_change} onChange={v => setVo({ ...vo, value_change: v })} />
        <Field label="Extra days on the end date" id="vo-d" type="number" min="0" value={vo.days_extension} onChange={v => setVo({ ...vo, days_extension: v })} />
      </div>
      <Field label="Details, instruction reference" id="vo-desc" type="textarea" value={vo.description} onChange={v => setVo({ ...vo, description: v })} />
    </FormModal>}
    {decide && <FormModal title={`Decide ${decide.number}`} submit="Approve" busy={act.busy} onClose={() => setDecide(null)}
      onSave={() => act.run(async () => { await rpc('decide_variation', { p_id: decide.id, p_approve: true, p_note: decide.note || null }); setDecide(null); reload(); }, 'Variation approved')}
      danger={<button className="btn danger" type="button" disabled={act.busy} onClick={() => act.run(async () => { await rpc('decide_variation', { p_id: decide.id, p_approve: false, p_note: decide.note || null }); setDecide(null); reload(); }, 'Variation rejected')}>Reject</button>}>
      <p style={{ margin: 0 }}><b>{decide.title}</b>: {money(decide.value_change)}{decide.days_extension ? `, ${decide.days_extension} extra days` : ''}.</p>
      <Field label="Note (agreed at, instruction no.)" id="dv-n" value={decide.note} onChange={v => setDecide({ ...decide, note: v })} />
    </FormModal>}
    {sec && <FormModal title="Bond, guarantee or insurance" busy={act.busy} onClose={() => setSec(null)} onSave={() => act.run(async () => {
      await q(supabase.from('contract_securities').insert({ contract_id: c.id, kind: sec.kind, direction: sec.direction, issuer: sec.issuer || null, reference: sec.reference || null,
        amount: sec.amount === '' ? null : Number(sec.amount), issued_on: sec.issued_on || null, expires_on: sec.expires_on || null }) as any); setSec(null); reload(); }, 'Added')}>
      <div className="grid-form">
        <Select label="Type" id="sc-k" value={sec.kind} onChange={v => setSec({ ...sec, kind: v })} options={SEC_KINDS} />
        <Select label="Direction" id="sc-d" value={sec.direction} onChange={v => setSec({ ...sec, direction: v })} options={[['given', 'We gave it to them'], ['received', 'They gave it to us']]} />
        <Field label="Bank or insurer" id="sc-i" value={sec.issuer} onChange={v => setSec({ ...sec, issuer: v })} />
        <Field label="Reference" id="sc-r" value={sec.reference} onChange={v => setSec({ ...sec, reference: v })} />
        <Field label="Amount" id="sc-a" type="number" step="0.01" min="0" value={sec.amount} onChange={v => setSec({ ...sec, amount: v })} />
        <Field label="Issued" id="sc-is" type="date" value={sec.issued_on} onChange={v => setSec({ ...sec, issued_on: v })} />
        <Field label="Expires" id="sc-e" type="date" value={sec.expires_on} onChange={v => setSec({ ...sec, expires_on: v })} />
      </div>
    </FormModal>}
    {obl && <FormModal title="Key date or obligation" busy={act.busy} onClose={() => setObl(null)} onSave={() => act.run(async () => {
      if (!obl.title.trim() || !obl.due_date) throw new Error('Enter what is due and when.');
      await q(supabase.from('contract_obligations').insert({ contract_id: c.id, title: obl.title.trim(), due_date: obl.due_date, responsible_id: obl.responsible_id || null, notes: obl.notes || null }) as any); setObl(null); reload(); }, 'Added')}>
      <Field label="What is due" id="ob-t" value={obl.title} onChange={v => setObl({ ...obl, title: v })} placeholder="e.g. Monthly HSE report, renew CAR insurance, end of defects period" required />
      <div className="grid-form">
        <Field label="Due" id="ob-d" type="date" value={obl.due_date} onChange={v => setObl({ ...obl, due_date: v })} required />
        <Select label="Responsible" id="ob-r" value={obl.responsible_id} onChange={v => setObl({ ...obl, responsible_id: v })} options={[['', 'Nobody in particular'], ...team.map(t => [t.user_id, t.email] as [string, string])]} />
      </div>
      <Field label="Notes" id="ob-n" value={obl.notes} onChange={v => setObl({ ...obl, notes: v })} />
    </FormModal>}
    {file && <FormModal title="Upload a contract file" submit="Upload" busy={act.busy} onClose={() => setFile(null)} onSave={() => act.run(async () => {
      if (!file.f) throw new Error('Choose a file.');
      const u = await uploadDocFile(cid, 'contracts/' + c.id, file.f);
      await q(supabase.from('contract_files').insert({ contract_id: c.id, kind: file.kind, name: u.name, storage_path: u.path, size_bytes: u.size }) as any); setFile(null); reload(); }, 'Uploaded')}>
      <Select label="What it is" id="cf-k" value={file.kind} onChange={v => setFile({ ...file, kind: v })} options={[['signed_contract', 'Signed contract, LPO or award letter'], ['variation', 'Variation instruction'], ['security', 'Bond or guarantee'], ['correspondence', 'Letter or correspondence'], ['other', 'Other']]} />
      <div className="field"><label htmlFor="cf-f">File (up to 50 MB)</label><input id="cf-f" type="file" onChange={e => setFile({ ...file, f: e.target.files?.[0] || null })} /></div>
    </FormModal>}
  </>;
}

/** All variations, bonds or key dates across contracts. */
export function ContractListPage({ what }: { what: 'variations' | 'securities' | 'obligations' }) {
  const { cid, company } = useSession();
  const [show, setShow] = useState(what === 'variations' ? 'proposed' : 'open');
  const table = { variations: 'contract_variations', securities: 'contract_securities', obligations: 'contract_obligations' }[what];
  const order = { variations: 'requested_on', securities: 'expires_on', obligations: 'due_date' }[what];
  const { data, error, loading } = useLoad(() => q<any[]>(supabase.from(table).select('*, contract:contracts(id,number,title,counterparty)').eq('company_id', cid).order(order, { ascending: what !== 'variations', nullsFirst: false }) as any), [cid, what]);
  const soon = new Date(Date.now() + 30 * 864e5).toISOString().slice(0, 10);
  const FILTERS: Record<string, [string, string, (r: any) => boolean][]> = {
    variations: [['proposed', 'Awaiting decision', r => r.status === 'proposed'], ['approved', 'Approved', r => r.status === 'approved'], ['rejected', 'Rejected', r => r.status === 'rejected'], ['all', 'All', () => true]],
    securities: [['open', 'Active', r => r.status === 'active'], ['soon', 'Expiring in 30 days', r => r.status === 'active' && r.expires_on && r.expires_on <= soon], ['done', 'Released or claimed', r => r.status !== 'active'], ['all', 'All', () => true]],
    obligations: [['open', 'Open', r => r.status === 'open'], ['late', 'Overdue', r => r.status === 'open' && r.due_date < today()], ['done', 'Done', r => r.status !== 'open'], ['all', 'All', () => true]],
  };
  const fl = FILTERS[what].find(f => f[0] === show) || FILTERS[what][0];
  const list = (data || []).filter(fl[2]);
  const title = { variations: 'Variations', securities: 'Bonds & guarantees', obligations: 'Key dates & obligations' }[what];
  const head = what === 'variations' ? ['Contract', 'No.', 'Change', 'Value', 'Days', 'Status', 'Raised'] : what === 'securities' ? ['Contract', 'Type', 'Issuer', 'Reference', 'Amount', 'Expires', 'Status'] : ['Contract', 'What', 'Due', 'Status'];
  const rows = list.map(r => what === 'variations' ? [r.contract?.number, r.number, r.title, money(r.value_change), r.days_extension || '', r.status, r.requested_on]
    : what === 'securities' ? [r.contract?.number, secName(r.kind), r.issuer || '', r.reference || '', money(r.amount), r.expires_on || '', r.status]
    : [r.contract?.number, r.title, r.due_date, r.status]);
  return <>
    <PageHead title={title}><Downloads pdf={() => tablePdf({ company: company!, title, subtitle: `${fl[1]} · ${longDate(today())}`, head, body: rows, filename: what + '-' + today() })} csv={() => downloadCsv(what + '-' + today(), head, rows)} /></PageHead>
    <Loading error={error} loading={loading && !data} />
    {data && <>
      <div className="chips">{FILTERS[what].map(([k, l, fn]) => <button key={k} type="button" className={'chip' + (show === k ? ' on' : '')} onClick={() => setShow(k)}>{l} <span>{data.filter(fn).length}</span></button>)}</div>
      <Panel>{list.length ? <div className="scroll"><table>
        <thead><tr>{head.map((h, i) => <th key={i} className={['Value', 'Amount', 'Days'].includes(h) ? 'r' : ''}>{h}</th>)}</tr></thead>
        <tbody>{list.map(r => <tr key={r.id}>
          <td><Link to={'/contracts/' + r.contract?.id}>{r.contract?.number}</Link><br /><span className="muted" style={{ fontSize: 12 }}>{r.contract?.counterparty}</span></td>
          {what === 'variations' && <><td className="num">{r.number}</td><td>{r.title}</td><td className="r num">{money(r.value_change)}</td><td className="r num">{r.days_extension || ''}</td><td><span className={'pill ' + ({ approved: 'good', rejected: 'bad', proposed: 'warn' } as any)[r.status]}>{r.status}</span></td><td className="num">{r.requested_on}</td></>}
          {what === 'securities' && <><td>{secName(r.kind)}</td><td>{r.issuer}</td><td>{r.reference}</td><td className="r num">{money(r.amount)}</td><td className="num">{r.expires_on}</td><td><span className={'pill ' + (r.status === 'active' && r.expires_on && r.expires_on < today() ? 'bad' : r.status === 'active' && r.expires_on && r.expires_on <= soon ? 'warn' : '')}>{r.status}</span></td></>}
          {what === 'obligations' && <><td>{r.title}</td><td className="num">{r.due_date}</td><td><span className={'pill ' + (r.status === 'open' && r.due_date < today() ? 'bad' : r.status === 'open' ? 'warn' : 'good')}>{r.status === 'open' && r.due_date < today() ? 'overdue' : r.status}</span></td></>}
        </tr>)}</tbody></table></div> : <Empty>Nothing here.</Empty>}</Panel>
    </>}
  </>;
}
