import { useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { q, rpc, supabase } from '../lib/supabase';
import { useSession } from '../lib/session';
import { longDate, money, today } from '../lib/format';
import { downloadCsv } from '../lib/download';
import { tablePdf } from '../lib/pdf';
import { receiptUrl, uploadReceipt } from '../lib/receipt';
import { DimSelects, useDims } from '../components/dims';
import { ConfirmButton, Downloads, Empty, Field, FormModal, Loading, PageHead, Panel, Select, useAction, useLoad, useToast } from '../components/ui';

const KIND: Record<string, string> = { purchase: 'Purchase', payment: 'Payment', cash_advance: 'Cash advance' };
const RS: Record<string, [string, string]> = { draft: ['Draft', ''], submitted: ['Waiting for approval', 'warn'], approved: ['Approved', 'good'], rejected: ['Rejected', 'bad'], cancelled: ['Cancelled', ''], done: ['Done', ''] };
const AS: Record<string, [string, string]> = { open: ['Open', 'warn'], submitted: ['To check', 'warn'], retired: ['Retired', 'good'], recovered: ['Recovered via payroll', 'bad'] };
const Pill = ({ m, s }: { m: Record<string, [string, string]>; s: string }) => { const [l, c] = m[s] || [s, '']; return <span className={'pill ' + c}>{l}</span>; };
const daysPast = (d: string) => Math.floor((Date.parse(today()) - Date.parse(d)) / 864e5);

function useLookups(cid: string) {
  return useLoad(async () => {
    const [accounts, banks, suppliers, projects, staff, team] = await Promise.all([
      q<any[]>(supabase.from('accounts').select('id,code,name,type').eq('company_id', cid).eq('active', true).in('type', ['expense', 'asset']).order('code') as any),
      q<any[]>(supabase.from('accounts').select('id,code,name').eq('company_id', cid).eq('is_bank', true).eq('active', true).order('code') as any),
      q<any[]>(supabase.from('suppliers').select('id,name').eq('company_id', cid).order('name') as any),
      q<any[]>(supabase.from('projects').select('id,number,name').eq('company_id', cid).in('status', ['planned', 'active']).order('name') as any),
      q<any[]>(supabase.from('employees').select('id,full_name,user_id').eq('company_id', cid).eq('status', 'active').order('full_name') as any).catch(() => []),
      q<any[]>(supabase.from('memberships').select('user_id,email').eq('company_id', cid) as any).catch(() => []),
    ]);
    const currencies = await q<any[]>(supabase.from('currencies').select('code,name,rate').eq('company_id', cid).order('code') as any).catch(() => [] as any[]);
    const expense = accounts.filter(a => a.type === 'expense');
    return { accounts, expense, banks, suppliers, projects, staff, team, currencies };
  }, [cid]);
}
const acctOpts = (list: any[]): [string, string][] => list.map(a => [a.id, `${a.code} ${a.name}`]);

/** Raise a request for money that is not part of a project purchase or a sales order. */
function NewRequest({ onClose, onSaved }: { onClose: () => void; onSaved: (id: string) => void }) {
  const { cid } = useSession();
  const act = useAction();
  const { data: L } = useLookups(cid);
  const { data: dims } = useDims(cid);
  const [f, setF] = useState<any>({ currency: 'GHS', kind: 'purchase', title: '', justification: '', amount: '', account_id: '', supplier_id: '', payee: '', project_id: '', branch_id: '', cost_centre_id: '', needed_by: '', employee_id: '' });
  const set = (k: string) => (v: any) => setF({ ...f, [k]: v });
  const { data: budget } = useLoad(() => f.account_id ? rpc<any[]>('spend_budget', { cid, p_account: f.account_id, p_date: f.needed_by || today() }).then(r => r[0]) : Promise.resolve(null), [cid, f.account_id]);
  const save = (submit: boolean) => act.run(async () => {
    if (!f.title.trim() || !(Number(f.amount) > 0)) throw new Error('Say what it is for and how much.');
    const fx = f.kind !== 'cash_advance' && f.currency !== 'GHS';
    const row: any = { company_id: cid, kind: f.kind, title: f.title.trim(), justification: f.justification || null, amount: fx ? 1 : Number(f.amount),
      currency: fx ? f.currency : 'GHS', fx_amount: fx ? Number(f.amount) : null, account_id: f.account_id || null,
      supplier_id: f.supplier_id || null, payee: f.payee || null, project_id: f.project_id || null, branch_id: f.branch_id || null, cost_centre_id: f.cost_centre_id || null,
      needed_by: f.needed_by || null, employee_id: f.kind === 'cash_advance' && f.employee_id ? f.employee_id : null };
    const r = await q<any>(supabase.from('spend_requests').insert(row).select('id').single() as any);
    if (submit) await rpc('submit_spend_request', { p_id: r.id });
    onSaved(r.id);
  }, submit ? 'Request sent for approval' : 'Saved as a draft');
  return <FormModal title="New request" submit="Send for approval" busy={act.busy} onClose={onClose} onSave={() => save(true)}
    danger={<button className="btn" type="button" disabled={act.busy} onClick={() => save(false)}>Save draft</button>}>
    <Select label="What do you need?" id="sr-kind" value={f.kind} onChange={set('kind')} options={[['purchase', 'To buy something (Finance raises a purchase order)'], ['payment', 'A payment to someone (service, fee, utility)'], ['cash_advance', 'A cash advance I will account for with receipts']]} />
    <Field label="What for" id="sr-title" value={f.title} onChange={set('title')} placeholder={f.kind === 'cash_advance' ? 'e.g. Trip to Kumasi for the stock count' : 'e.g. Generator servicing, office chairs, internet renewal'} required />
    <Field label="Why it is needed" id="sr-just" type="textarea" value={f.justification} onChange={set('justification')} required />
    <div className="grid-form">
      {f.kind !== 'cash_advance' && (L?.currencies || []).length > 0 && <Select label="Currency" id="sr-cur" value={f.currency} onChange={set('currency')} options={[['GHS', 'GH₵ Ghana cedi'], ...(L?.currencies || []).map(c => [c.code, `${c.code} ${c.name}`] as [string, string])]} />}
      <Field label={`Amount (${f.kind !== 'cash_advance' && f.currency !== 'GHS' ? f.currency : 'GH₵'})`} id="sr-amt" type="number" step="0.01" min="0.01" value={f.amount} onChange={set('amount')} required />
      <Field label="Needed by" id="sr-need" type="date" value={f.needed_by} onChange={set('needed_by')} />
      <Select label={f.kind === 'cash_advance' ? 'Mainly for (optional)' : 'Charge to'} id="sr-acct" value={f.account_id} onChange={set('account_id')} options={[['', 'Choose…'], ...acctOpts(L?.expense || [])]} />
      {f.kind !== 'cash_advance' && <Select label="Supplier" id="sr-sup" value={f.supplier_id} onChange={set('supplier_id')} options={[['', 'Not set up / not known yet'], ...(L?.suppliers || []).map(s => [s.id, s.name] as [string, string])]} />}
      {f.kind !== 'cash_advance' && !f.supplier_id && <Field label="Pay to" id="sr-payee" value={f.payee} onChange={set('payee')} />}
      {f.kind === 'cash_advance' && <Select label="Advance to" id="sr-emp" value={f.employee_id} onChange={set('employee_id')} options={[['', 'Me'], ...(L?.staff || []).map(s => [s.id, s.full_name] as [string, string])]} />}
      <Select label="Project (if any)" id="sr-pj" value={f.project_id} onChange={set('project_id')} options={[['', 'None: company overhead'], ...(L?.projects || []).map(p => [p.id, `${p.number || ''} ${p.name}`.trim()] as [string, string])]} />
      <DimSelects dims={dims} branch={f.branch_id} centre={f.cost_centre_id} onChange={(b, c) => setF({ ...f, branch_id: b, cost_centre_id: c })} idPrefix="sr" />
    </div>
    {f.kind !== 'cash_advance' && f.currency !== 'GHS' && Number(f.amount) > 0 && <p className="muted" style={{ margin: 0, fontSize: 13 }}>
      About GH₵ {money(Number(f.amount) * Number((L?.currencies || []).find(c => c.code === f.currency)?.rate || 0))} at today's rate; this is what counts for the budget and approval limits.</p>}
    {budget && <BudgetLine b={budget} amount={(Number(f.amount) || 0) * (f.kind !== 'cash_advance' && f.currency !== 'GHS' ? Number((L?.currencies || []).find(c => c.code === f.currency)?.rate || 1) : 1)} />}
  </FormModal>;
}

function BudgetLine({ b, amount }: { b: any; amount: number }) {
  const left = Number(b.remaining) - amount;
  if (!Number(b.budget)) return <p className="muted" style={{ margin: 0, fontSize: 13 }}>No budget is set for this account this year. Spent so far: GH₵ {money(b.actual)}; committed by open requests: GH₵ {money(b.committed)}.</p>;
  return <p style={{ margin: 0, fontSize: 13 }} className={left < 0 ? 'error' : 'muted'}>
    Budget this year GH₵ {money(b.budget)} · spent GH₵ {money(b.actual)} · committed GH₵ {money(b.committed)} · {left < 0 ? <b>over budget by GH₵ {money(-left)} after this request</b> : <>GH₵ {money(left)} left after this request</>}.
  </p>;
}

export function RequestsPage() {
  const { cid, can, session, company } = useSession();
  const nav = useNavigate();
  const fin = can('accountant');
  const [show, setShow] = useState(fin ? 'action' : 'mine');
  const [add, setAdd] = useState(false);
  const { data, error, loading } = useLoad(() => q<any[]>(supabase.from('spend_requests').select('*, account:accounts(code,name), supplier:suppliers(name), employee:employees(full_name), project:projects(number,name)').eq('company_id', cid).order('created_at', { ascending: false }) as any), [cid]);
  const F: [string, string, (r: any) => boolean][] = [
    ...(fin ? [['action', 'Approved, to action', (r: any) => r.status === 'approved'] as [string, string, (r: any) => boolean]] : []),
    ['mine', 'Mine', r => r.requested_by === session?.user.id],
    ['waiting', 'Waiting for approval', r => r.status === 'submitted'],
    ['done', 'Done', r => r.status === 'done'],
    ['closed', 'Rejected or cancelled', r => ['rejected', 'cancelled'].includes(r.status)],
    ['all', 'All', () => true],
  ];
  const list = (data || []).filter((F.find(x => x[0] === show) || F[0])[2]);
  const head = ['No.', 'Type', 'What for', 'Charged to', 'Amount (GHS)', 'Status', 'Raised'];
  const rows = list.map(r => [r.number, KIND[r.kind], r.title, r.account ? `${r.account.code} ${r.account.name}` : '', money(r.amount), RS[r.status][0], r.created_at.slice(0, 10)]);
  return <>
    <PageHead title="Requests" sub="Money for anything outside a project purchase or a sales order: purchases, payments and cash advances. Each is approved and checked against the budget before Finance acts on it.">
      <Downloads pdf={() => tablePdf({ company: company!, title: 'Spend requests', subtitle: longDate(today()), head, body: rows, rightAlign: [4], filename: 'requests-' + today() })} csv={() => downloadCsv('requests-' + today(), head, rows)} />
      <button className="btn primary" type="button" onClick={() => setAdd(true)}>New request</button>
    </PageHead>
    <Loading error={error} loading={loading && !data} />
    {data && <>
      <div className="chips">{F.map(([k, l, fn]) => <button key={k} type="button" className={'chip' + (show === k ? ' on' : '')} onClick={() => setShow(k)}>{l} <span>{data.filter(fn).length}</span></button>)}</div>
      <Panel>{list.length ? <div className="scroll"><table>
        <thead><tr><th>Request</th><th>Charged to</th><th className="r">Amount (GH₵)</th><th>Status</th></tr></thead>
        <tbody>{list.map(r => <tr key={r.id} className="clickable" onClick={() => nav('/requests/' + r.id)}>
          <td><Link to={'/requests/' + r.id} onClick={e => e.stopPropagation()}><b>{r.number}</b></Link> {r.title}<br /><span className="muted">{KIND[r.kind]}{r.kind === 'cash_advance' && r.employee ? ' to ' + r.employee.full_name : ''}{r.supplier ? ' · ' + r.supplier.name : r.payee ? ' · ' + r.payee : ''}{r.project ? ' · ' + r.project.number : ''}</span></td>
          <td>{r.account ? `${r.account.code} ${r.account.name}` : '—'}</td>
          <td className="r num">{money(r.amount)}{r.currency && r.currency !== 'GHS' && <><br /><span className="muted" style={{ fontSize: 12 }}>{r.currency} {money(r.fx_amount)}</span></>}</td>
          <td><Pill m={RS} s={r.status} />{r.outcome_ref && <><br /><span className="muted" style={{ fontSize: 12 }}>{r.outcome?.replace('_', ' ')} {r.outcome_ref}</span></>}</td></tr>)}</tbody></table></div>
        : <Empty>No requests here.</Empty>}</Panel>
    </>}
    {add && <NewRequest onClose={() => setAdd(false)} onSaved={id => { setAdd(false); nav('/requests/' + id); }} />}
  </>;
}

export function RequestView() {
  const { id } = useParams();
  const { cid, can, session } = useSession();
  const act = useAction();
  const nav = useNavigate();
  const fin = can('accountant');
  const [doIt, setDoIt] = useState<any | null>(null);
  const [decide, setDecide] = useState<any | null>(null);
  const { data: L } = useLookups(cid);
  const { data, error, loading, reload } = useLoad(async () => {
    const r = await q<any>(supabase.from('spend_requests').select('*, account:accounts(code,name), supplier:suppliers(name), employee:employees(full_name), project:projects(id,number,name), branch:branches(name), centre:cost_centres(name)').eq('id', id).single() as any);
    const [steps, budget, mine] = await Promise.all([
      q<any[]>(supabase.from('approval_steps').select('*').eq('doc_type', 'spend_request').eq('doc_id', id).order('step_no') as any).catch(() => []),
      r.account_id ? rpc<any[]>('spend_budget', { cid, p_account: r.account_id, p_date: r.needed_by || today() }).then(x => x[0]) : Promise.resolve(null),
      rpc<any[]>('my_approvals', { cid }).then(x => x.find(s => s.doc_id === id) || null),
    ]);
    return { r, steps, budget, mine };
  }, [id]);
  if (!data) return <Loading error={error} loading={loading} />;
  const { r, steps, budget, mine } = data;
  const who = (u: string | null) => L?.team.find(t => t.user_id === u)?.email || '';
  return <>
    <PageHead title={`${r.number} · ${r.title}`} sub={<>{KIND[r.kind]} of <b>{r.currency && r.currency !== 'GHS' ? `${r.currency} ${money(r.fx_amount)} (GH₵ ${money(r.amount)} at ${Number(r.exchange_rate)})` : `GH₵ ${money(r.amount)}`}</b> · raised by {who(r.requested_by) || 'a team member'} on {longDate(r.created_at.slice(0, 10))} · <Pill m={RS} s={r.status} /></>}>
      <button className="btn" type="button" onClick={() => nav('/requests')}>Back</button>
      {r.status === 'draft' && r.requested_by === session?.user.id && <button className="btn primary" type="button" disabled={act.busy} onClick={() => act.run(async () => { await rpc('submit_spend_request', { p_id: r.id }); reload(); }, 'Sent for approval')}>Send for approval</button>}
      {mine && <button className="btn primary" type="button" onClick={() => setDecide({ step: mine.step_id, note: '' })}>Approve or reject</button>}
      {r.status === 'approved' && fin && r.kind === 'purchase' && <button className="btn primary" type="button" onClick={() => setDoIt({ what: 'po', supplier: r.supplier_id || '' })}>Raise purchase order</button>}
      {r.status === 'approved' && fin && r.kind !== 'cash_advance' && <button className="btn" type="button" onClick={() => setDoIt({ what: 'bill', supplier: r.supplier_id || '' })}>Enter supplier bill</button>}
      {r.status === 'approved' && fin && r.kind === 'payment' && <button className="btn primary" type="button" onClick={() => setDoIt({ what: 'pay', from: '', date: today(), ref: '' })}>Pay now</button>}
      {r.status === 'approved' && fin && r.kind === 'cash_advance' && <button className="btn primary" type="button" onClick={() => setDoIt({ what: 'advance', from: '', date: today(), due: '' })}>Pay advance</button>}
      {['draft', 'submitted', 'approved'].includes(r.status) && (r.requested_by === session?.user.id || fin) && <ConfirmButton className="btn ghost" label="Cancel request" confirm="Cancel this request?" onConfirm={() => act.run(async () => { await rpc('cancel_spend_request', { p_id: r.id }); reload(); }, 'Cancelled')} />}
    </PageHead>
    <div className="two">
      <Panel title="Details" pad>
        <dl className="facts">
          <dt>Why</dt><dd style={{ whiteSpace: 'pre-wrap' }}>{r.justification}</dd>
          <dt>Charge to</dt><dd>{r.account ? `${r.account.code} ${r.account.name}` : '—'}</dd>
          {r.kind === 'cash_advance' ? <><dt>Advance to</dt><dd>{r.employee?.full_name || '—'}</dd></> : <><dt>Supplier / payee</dt><dd>{r.supplier?.name || r.payee || 'Not chosen yet'}</dd></>}
          <dt>Project</dt><dd>{r.project ? <Link to={'/projects/' + r.project.id}>{r.project.number} {r.project.name}</Link> : 'None: company overhead'}</dd>
          {(r.branch || r.centre) && <><dt>Branch / cost centre</dt><dd>{[r.branch?.name, r.centre?.name].filter(Boolean).join(' · ')}</dd></>}
          <dt>Needed by</dt><dd>{r.needed_by ? longDate(r.needed_by) : '—'}</dd>
          {r.outcome && <><dt>Result</dt><dd>{r.outcome === 'purchase_order' ? <Link to={'/purchase-orders/' + r.outcome_id}>Purchase order {r.outcome_ref}</Link>
            : r.outcome === 'bill' ? <Link to={'/bills/' + r.outcome_id}>Supplier bill (draft)</Link> : r.outcome === 'advance' ? <Link to={'/advances/' + r.outcome_id}>Advance {r.outcome_ref}</Link> : `Paid, journal ${r.outcome_ref}`}</dd></>}
        </dl>
        {budget && <div style={{ marginTop: 12 }}><BudgetLine b={budget} amount={['submitted', 'approved'].includes(r.status) ? 0 : Number(r.amount)} /></div>}
      </Panel>
      <Panel title="Approvals">{steps.length ? <div className="scroll"><table><tbody>{steps.map(s => <tr key={s.id}>
        <td className="num">{s.step_no}</td><td><b>{s.label}</b><br /><span className="muted" style={{ fontSize: 12 }}>{s.approver_role ? s.approver_role.replace('_', ' ') : who(s.approver_user)}</span></td>
        <td className="wrap-cell"><span className={'pill ' + ({ approved: 'good', rejected: 'bad', pending: 'warn', skipped: '' } as any)[s.status]}>{s.status}</span>{s.decided_email && <><br /><span className="muted" style={{ fontSize: 12, wordBreak: 'break-word' }}>{s.decided_email} · {s.decided_at?.slice(0, 10)}{s.note ? ': ' + s.note : ''}</span></>}</td></tr>)}</tbody></table></div>
        : <Empty>{r.status === 'draft' ? 'Not sent yet. Approval steps come from Settings → Approval rules (type "Spend request"); without rules, Finance approves.' : 'No approval steps.'}</Empty>}</Panel>
    </div>
    {decide && <FormModal title={`Decide ${r.number}`} submit="Approve" busy={act.busy} onClose={() => setDecide(null)}
      onSave={() => act.run(async () => { await rpc('decide_approval', { p_step: decide.step, p_approve: true, p_note: decide.note || null }); setDecide(null); reload(); }, 'Approved')}
      danger={<button className="btn danger" type="button" disabled={act.busy} onClick={() => act.run(async () => { await rpc('decide_approval', { p_step: decide.step, p_approve: false, p_note: decide.note || null }); setDecide(null); reload(); }, 'Rejected')}>Reject</button>}>
      <p style={{ margin: 0 }}>{KIND[r.kind]} of <b>GH₵ {money(r.amount)}</b>: {r.title}</p>
      {budget && <BudgetLine b={budget} amount={0} />}
      <Field label="Note (needed to reject)" id="dc-n" value={decide.note} onChange={v => setDecide({ ...decide, note: v })} />
    </FormModal>}
    {doIt && <FormModal title={{ po: 'Raise purchase order', bill: 'Enter supplier bill', pay: 'Pay now', advance: 'Pay cash advance' }[doIt.what as string]!} busy={act.busy} onClose={() => setDoIt(null)} onSave={() => act.run(async () => {
      if (doIt.what === 'po') { const v = await rpc<string>('request_to_po', { p_id: r.id, p_supplier: doIt.supplier || null }); nav('/purchase-orders/' + v); return; }
      if (doIt.what === 'bill') { const v = await rpc<string>('request_to_bill', { p_id: r.id, p_supplier: doIt.supplier || null }); nav('/bills/' + v); return; }
      if (doIt.what === 'pay') { await rpc('pay_spend_request', { p_id: r.id, p_from: doIt.from || null, p_date: doIt.date, p_reference: doIt.ref || null }); }
      if (doIt.what === 'advance') { const v = await rpc<string>('pay_advance', { p_request: r.id, p_from: doIt.from || null, p_date: doIt.date, p_due: doIt.due || null }); nav('/advances/' + v); return; }
      setDoIt(null); reload(); }, 'Done')}>
      {['po', 'bill'].includes(doIt.what) && <Select label="Supplier" id="do-s" value={doIt.supplier} onChange={v => setDoIt({ ...doIt, supplier: v })} options={[['', 'Choose…'], ...(L?.suppliers || []).map(s => [s.id, s.name] as [string, string])]} />}
      {['pay', 'advance'].includes(doIt.what) && <div className="grid-form">
        <Select label="Pay from" id="do-f" value={doIt.from} onChange={v => setDoIt({ ...doIt, from: v })} options={[['', 'Bank (default)'], ...acctOpts(L?.banks || [])]} />
        <Field label="Date" id="do-d" type="date" value={doIt.date} onChange={v => setDoIt({ ...doIt, date: v })} />
        {doIt.what === 'pay' && <Field label="Cheque or transfer reference" id="do-r" value={doIt.ref} onChange={v => setDoIt({ ...doIt, ref: v })} />}
        {doIt.what === 'advance' && <Field label="Retire by (blank = the company rule)" id="do-due" type="date" value={doIt.due} onChange={v => setDoIt({ ...doIt, due: v })} />}
      </div>}
      <p className="muted" style={{ margin: 0, fontSize: 13 }}>{{ po: 'Creates a draft purchase order for GH₵ ' + money(r.amount) + ' that you can edit, approve and send.', bill: 'Creates a draft bill with one line on the requested account. Adjust it to the supplier\'s invoice, then post it.',
        pay: 'Posts Dr ' + (r.account ? r.account.code + ' ' + r.account.name : 'expense') + ', Cr the account paid from.', advance: 'Posts Dr 1260 Staff cash advances, Cr the account paid from. The person must retire it with receipts.' }[doIt.what as string]}</p>
    </FormModal>}
  </>;
}

export function AdvancesPage() {
  const { cid, can, company } = useSession();
  const nav = useNavigate();
  const fin = can('accountant', 'hr');
  const [show, setShow] = useState('open');
  const { data, error, loading } = useLoad(() => q<any[]>(supabase.from('cash_advances').select('*, employee:employees(full_name,user_id)').eq('company_id', cid).order('issued_on', { ascending: false }) as any), [cid]);
  const all = data || [];
  const age = (a: any) => daysPast(a.due_on);
  const F: [string, string, (a: any) => boolean][] = [['open', 'Not retired', a => ['open', 'submitted'].includes(a.status)], ['overdue', 'Overdue', a => a.status === 'open' && age(a) > 0],
    ['check', 'To check', a => a.status === 'submitted'], ['retired', 'Retired', a => a.status === 'retired'], ['recovered', 'Recovered via payroll', a => a.status === 'recovered'], ['all', 'All', () => true]];
  const list = all.filter((F.find(x => x[0] === show) || F[0])[2]);
  const open = all.filter(a => a.status === 'open');
  const bucket = (lo: number, hi: number) => open.filter(a => age(a) >= lo && age(a) <= hi);
  const B: [string, any[]][] = [['Not yet due', open.filter(a => age(a) <= 0)], ['1–7 days late', bucket(1, 7)], ['8–30 days late', bucket(8, 30)], ['Over 30 days late', open.filter(a => age(a) > 30)]];
  const head = ['No.', 'Staff', 'Purpose', 'Amount (GHS)', 'Issued', 'Retire by', 'Days late', 'Status'];
  const rows = list.map(a => [a.number, a.employee?.full_name || '', a.purpose, money(a.amount), a.issued_on, a.due_on, a.status === 'open' && age(a) > 0 ? age(a) : '', AS[a.status][0]]);
  return <>
    <PageHead title="Cash advances" sub="Money given to staff for a job or trip, accounted for with receipts by the retire-by date. Raise one with Requests → New request → Cash advance.">
      <Downloads pdf={() => tablePdf({ company: company!, title: 'Cash advances', subtitle: longDate(today()), head, body: rows, rightAlign: [3, 6], filename: 'advances-' + today() })} csv={() => downloadCsv('advances-' + today(), head, rows)} />
    </PageHead>
    <Loading error={error} loading={loading && !data} />
    {data && <>
      {fin && <div className="tiles">{B.map(([l, xs]) => <div className="tile" key={l}><span>{l} ({xs.length})</span><b>{money(xs.reduce((s, a) => s + Number(a.amount), 0))}</b></div>)}</div>}
      <div className="chips">{F.map(([k, l, fn]) => <button key={k} type="button" className={'chip' + (show === k ? ' on' : '')} onClick={() => setShow(k)}>{l} <span>{all.filter(fn).length}</span></button>)}</div>
      <Panel>{list.length ? <div className="scroll"><table>
        <thead><tr><th>Advance</th><th>Staff</th><th className="r">Amount (GH₵)</th><th>Retire by</th><th>Status</th></tr></thead>
        <tbody>{list.map(a => <tr key={a.id} className="clickable" onClick={() => nav('/advances/' + a.id)}>
          <td><Link to={'/advances/' + a.id} onClick={e => e.stopPropagation()}><b>{a.number}</b></Link> {a.purpose}<br /><span className="muted" style={{ fontSize: 12 }}>issued {a.issued_on}</span></td>
          <td>{a.employee?.full_name}</td><td className="r num">{money(a.amount)}</td>
          <td className="num">{a.due_on}{a.status === 'open' && age(a) > 0 && <><br /><span className="pill bad">{age(a)} days late</span></>}</td>
          <td><Pill m={AS} s={a.status} /></td></tr>)}</tbody></table></div> : <Empty>No advances here.</Empty>}</Panel>
    </>}
  </>;
}

export function AdvanceView() {
  const { id } = useParams();
  const { cid, can, session } = useSession();
  const act = useAction();
  const toast = useToast();
  const nav = useNavigate();
  const fin = can('accountant');
  const { data: L } = useLookups(cid);
  const [line, setLine] = useState<any | null>(null);
  const [approve, setApprove] = useState<any | null>(null);
  const [back, setBack] = useState<string | null>(null);
  const [recover, setRecover] = useState<string | null>(null);
  const { data, error, loading, reload } = useLoad(async () => {
    const a = await q<any>(supabase.from('cash_advances').select('*, employee:employees(full_name,user_id), request:spend_requests(id,number), paid:accounts!cash_advances_paid_from_fkey(code,name)').eq('id', id).single() as any);
    const lines = await q<any[]>(supabase.from('advance_lines').select('*, account:accounts(code,name)').eq('advance_id', id).order('line_date') as any);
    const co = await q<any>(supabase.from('companies').select('advance_recover_after_days').eq('id', cid).single() as any).catch(() => ({ advance_recover_after_days: 30 }));
    return { a, lines, co };
  }, [id]);
  if (!data) return <Loading error={error} loading={loading} />;
  const { a, lines, co } = data;
  const holder = a.employee?.user_id === session?.user.id;
  const spent = lines.reduce((s, l) => s + Number(l.amount), 0);
  const diff = Number(a.amount) - spent;
  const late = a.status === 'open' ? daysPast(a.due_on) : 0;
  const editable = a.status === 'open' && (holder || fin);
  return <>
    <PageHead title={`${a.number} · ${a.purpose}`} sub={<>GH₵ {money(a.amount)} to <b>{a.employee?.full_name}</b> on {longDate(a.issued_on)} · retire by {longDate(a.due_on)} · <Pill m={AS} s={a.status} />{late > 0 && <> <span className="pill bad">{late} days late</span></>}</>}>
      <button className="btn" type="button" onClick={() => nav('/advances')}>Back</button>
      {editable && <button className="btn" type="button" onClick={() => setLine({ line_date: today(), description: '', account_id: '', amount: '', file: null })}>Add receipt</button>}
      {editable && <button className="btn primary" type="button" disabled={act.busy || !lines.length} onClick={() => act.run(async () => { await rpc('submit_retirement', { p_advance: a.id }); reload(); }, 'Sent to Finance')}>Submit for retirement</button>}
      {a.status === 'submitted' && fin && !holder && <><button className="btn" type="button" onClick={() => setBack('')}>Send back</button>
        <button className="btn primary" type="button" onClick={() => setApprove({ cash: '', date: today() })}>Approve retirement</button></>}
      {a.status === 'open' && fin && late >= Number(co.advance_recover_after_days) && <button className="btn danger" type="button" onClick={() => setRecover(String(Math.min(Number(a.amount), 500)))}>Recover through payroll</button>}
    </PageHead>
    {a.returned_note && a.status === 'open' && <div className="note" role="status"><b>Sent back by Finance:</b> {a.returned_note}</div>}
    <div className="tiles">
      <div className="tile"><span>Advanced</span><b>{money(a.amount)}</b></div>
      <div className="tile"><span>Receipts</span><b>{money(spent)}</b></div>
      <div className="tile"><span>{diff >= 0 ? 'To return in cash' : 'We owe them'}</span><b>{money(Math.abs(diff))}</b></div>
    </div>
    <Panel title="What it was spent on">{lines.length ? <div className="scroll"><table>
      <thead><tr><th>Date</th><th>Description</th><th>Account</th><th className="r">Amount (GH₵)</th><th>Receipt</th><th></th></tr></thead>
      <tbody>{lines.map(l => <tr key={l.id}><td className="num">{l.line_date}</td><td>{l.description}</td><td className="muted">{l.account?.code} {l.account?.name}</td><td className="r num">{money(l.amount)}</td>
        <td>{l.receipt_path ? <button className="btn ghost small" style={{ padding: 0 }} type="button" onClick={() => act.run(async () => window.open(await receiptUrl(l.receipt_path), '_blank', 'noopener'))}>View</button> : <span className="pill bad">missing</span>}</td>
        <td className="r">{editable && <ConfirmButton className="btn small ghost" label="Remove" confirm="Remove this line?" onConfirm={() => act.run(async () => { await q(supabase.from('advance_lines').delete().eq('id', l.id) as any); reload(); })} />}</td></tr>)}</tbody>
      <tfoot><tr><td></td><td>Total</td><td></td><td className="r num">{money(spent)}</td><td colSpan={2}></td></tr></tfoot></table></div>
      : <Empty>{editable ? 'Add each receipt: what it was, the amount and a photo. Then submit it to Finance by the retire-by date.' : 'No receipts yet.'}</Empty>}</Panel>
    {a.status === 'retired' && <p className="muted" style={{ margin: 0 }}>Retired on {longDate(a.retired_on)}: GH₵ {money(a.spent)} spent{Number(a.cash_returned) > 0 ? `, GH₵ ${money(a.cash_returned)} returned` : ''}{Number(a.reimbursed) > 0 ? `, GH₵ ${money(a.reimbursed)} reimbursed` : ''}.</p>}
    {a.status === 'recovered' && <p className="muted" style={{ margin: 0 }}>Not retired in time: moved to a staff loan on {longDate(a.retired_on)} and deducted from salary.</p>}

    {line && <FormModal title="Add a receipt" busy={act.busy} onClose={() => setLine(null)} onSave={() => act.run(async () => {
      if (!line.description.trim() || !(Number(line.amount) > 0) || !line.account_id) throw new Error('Enter what it was, the account and the amount.');
      const path = line.file ? await uploadReceipt(line.file, session!.user.id) : null;
      await q(supabase.from('advance_lines').insert({ advance_id: a.id, line_date: line.line_date, description: line.description.trim(), account_id: line.account_id, amount: Number(line.amount), receipt_path: path }) as any);
      if (!path) toast('Saved without a receipt. Attach one before submitting.', true);
      setLine(null); reload(); }, 'Added')}>
      <Field label="What it was" id="al-d" value={line.description} onChange={v => setLine({ ...line, description: v })} placeholder="e.g. STC bus fare Accra–Kumasi" required />
      <div className="grid-form">
        <Field label="Date" id="al-dt" type="date" value={line.line_date} onChange={v => setLine({ ...line, line_date: v })} />
        <Field label="Amount (GH₵)" id="al-a" type="number" step="0.01" min="0.01" value={line.amount} onChange={v => setLine({ ...line, amount: v })} required />
        <Select label="Type of cost" id="al-ac" value={line.account_id} onChange={v => setLine({ ...line, account_id: v })} options={[['', 'Choose…'], ...acctOpts(L?.expense || [])]} />
      </div>
      <div className="field"><label htmlFor="al-f">Receipt photo or PDF</label><input id="al-f" type="file" accept="image/*,application/pdf" capture="environment" onChange={e => setLine({ ...line, file: e.target.files?.[0] || null })} /></div>
    </FormModal>}
    {approve && <FormModal title={`Approve retirement of ${a.number}`} submit="Approve and post" busy={act.busy} onClose={() => setApprove(null)} onSave={() => act.run(async () => {
      await rpc('approve_retirement', { p_advance: a.id, p_cash: approve.cash || null, p_date: approve.date }); setApprove(null); reload(); }, 'Retirement posted')}>
      <p style={{ margin: 0 }}>Receipts GH₵ {money(spent)} against an advance of GH₵ {money(a.amount)}. {diff > 0 ? <>The staff member hands back <b>GH₵ {money(diff)}</b>.</> : diff < 0 ? <>We pay them <b>GH₵ {money(-diff)}</b>.</> : 'Nothing to settle.'}</p>
      <div className="grid-form">
        {diff !== 0 && <Select label={diff > 0 ? 'Cash returned into' : 'Reimbursed from'} id="ap-c" value={approve.cash} onChange={v => setApprove({ ...approve, cash: v })} options={[['', 'Bank (default)'], ...acctOpts(L?.banks || [])]} />}
        <Field label="Date" id="ap-d" type="date" value={approve.date} onChange={v => setApprove({ ...approve, date: v })} />
      </div>
      <p className="muted" style={{ margin: 0, fontSize: 13 }}>Posts each receipt to its account, the cash returned or paid, and clears 1260 Staff cash advances.</p>
    </FormModal>}
    {back !== null && <FormModal title="Send back to fix" submit="Send back" busy={act.busy} onClose={() => setBack(null)} onSave={() => act.run(async () => { await rpc('return_retirement', { p_advance: a.id, p_note: back }); setBack(null); reload(); }, 'Sent back')}>
      <Field label="What needs fixing" id="bk-n" value={back} onChange={setBack} placeholder="e.g. Hotel receipt is not readable; bus fare needs a ticket" required />
    </FormModal>}
    {recover !== null && <FormModal title="Recover through payroll" submit="Move to staff loan" busy={act.busy} onClose={() => setRecover(null)} onSave={() => act.run(async () => { await rpc('recover_advance', { p_advance: a.id, p_installment: Number(recover) || null }); setRecover(null); reload(); }, 'Moved to a staff loan')}>
      <p style={{ margin: 0 }}>{a.employee?.full_name} has not retired GH₵ {money(a.amount)} after {late} days. The full amount becomes a staff loan deducted from salary.</p>
      <Field label="Deduct per month (GH₵)" id="rc-i" type="number" step="0.01" min="1" value={recover} onChange={setRecover} />
    </FormModal>}
  </>;
}

const NOTES = ['200', '100', '50', '20', '10', '5', '2', '1'];
const COINS = ['0.5', '0.2', '0.1', '0.05', '0.01'];
const dname = (k: string) => Number(k) >= 1 ? `GH₵${k}` : `${Math.round(Number(k) * 100)}p`;

export function PettyCashPage() {
  const { cid, can, session } = useSession();
  const act = useAction();
  const fin = can('accountant');
  const { data: L } = useLookups(cid);
  const { data: dims } = useDims(cid);
  const [sel, setSel] = useState<string | null>(null);
  const [setup, setSetup] = useState<any | null>(null);
  const [vou, setVou] = useState<any | null>(null);
  const [cnt, setCnt] = useState<any | null>(null);
  const [okCount, setOkCount] = useState<any | null>(null);
  const [rep, setRep] = useState<any | null>(null);
  const { data, error, loading, reload } = useLoad(async () => {
    const floats = await q<any[]>(supabase.from('petty_floats').select('*, account:accounts(code)').eq('company_id', cid).order('name') as any);
    const pos = await Promise.all(floats.map(f => rpc<any[]>('float_position', { p_float: f.id }).then(r => r[0])));
    return floats.map((f, i) => ({ ...f, pos: pos[i] }));
  }, [cid]);
  const f = (data || []).find(x => x.id === sel) || (data || [])[0] || null;
  const { data: detail, reload: reloadDetail } = useLoad(async () => {
    if (!f) return null;
    const [vouchers, counts, reps] = await Promise.all([
      q<any[]>(supabase.from('petty_vouchers').select('*, account:accounts(code,name)').eq('float_id', f.id).order('voucher_date', { ascending: false }).limit(200) as any),
      q<any[]>(supabase.from('petty_counts').select('*').eq('float_id', f.id).order('created_at', { ascending: false }).limit(50) as any),
      q<any[]>(supabase.from('petty_replenishments').select('*').eq('float_id', f.id).order('created_at', { ascending: false }).limit(50) as any),
    ]);
    return { vouchers, counts, reps };
  }, [f?.id, data]);
  const refresh = () => { reload(); reloadDetail(); };
  const custodian = f && f.custodian_id === session?.user.id;
  const open = (detail?.vouchers || []).filter(v => !v.replenishment_id && v.status === 'recorded');
  const pending = (detail?.counts || []).find(c => c.status === 'submitted');
  const who = (u: string) => L?.team.find(t => t.user_id === u)?.email || '';
  const counted = cnt ? [...NOTES, ...COINS].reduce((s, k) => s + (Number(cnt[k]) || 0) * Number(k), 0) : 0;
  return <>
    <PageHead title="Petty cash" sub="Each float is held by one custodian, who records every payout as a voucher with its receipt and counts the cash. Finance tops it back up to the float only when the count agrees.">
      {fin && <button className="btn primary" type="button" onClick={() => setSetup({ name: '', custodian: '', amount: '', limit: '', days: '30', from: '', project: '', branch: '', centre: '' })}>New float</button>}
    </PageHead>
    <Loading error={error} loading={loading && !data} />
    {data && !data.length && <Panel><Empty>{fin ? 'No floats yet. Set one up for each office or site that keeps cash.' : 'You do not hold a petty cash float.'}</Empty></Panel>}
    {data && data.length > 0 && <>
      <div className="tiles">{data.map(x => <button key={x.id} type="button" className={'tile' + (x.id === f?.id ? ' on' : '')} style={{ textAlign: 'left', cursor: 'pointer', borderColor: x.id === f?.id ? 'var(--accent)' : undefined }} onClick={() => setSel(x.id)}>
        <span>{x.name} · {x.account?.code}</span><b>{money(x.pos?.expected_cash)}</b>
        <span>should be in the box of {money(x.float_amount)}{x.pos?.count_due ? ' · count due' : ''}</span></button>)}</div>
      {f && <>
        <div className="actions">
          {(custodian || fin) && <button className="btn primary" type="button" onClick={() => setVou({ voucher_date: today(), payee: '', description: '', account_id: '', amount: '', project_id: '', file: null })}>Record payout</button>}
          {(custodian || fin) && <button className="btn" type="button" disabled={!!pending} onClick={() => setCnt({ note: '' })}>Count cash</button>}
          {fin && pending && <button className="btn primary" type="button" onClick={() => setOkCount({ c: pending, treatment: 'expense', note: '' })}>Approve count difference</button>}
          {fin && !custodian && <button className="btn" type="button" disabled={!!pending} onClick={() => setRep({ from: '', date: today(), reject: [] as string[], note: '' })}>Replenish</button>}
          <span className="muted" style={{ fontSize: 13 }}>Custodian: {who(f.custodian_id) || '—'} · up to GH₵ {money(f.voucher_limit)} per voucher · count every {f.count_every_days} days{f.pos?.last_count ? ` · last counted ${f.pos.last_count}` : ' · never counted'}</span>
        </div>
        <div className="tiles">
          <div className="tile"><span>Float</span><b>{money(f.float_amount)}</b></div>
          <div className="tile"><span>Vouchers not yet replenished ({open.length})</span><b>{money(f.pos?.unreplenished)}</b></div>
          <div className="tile"><span>Cash that should be in the box</span><b>{money(f.pos?.expected_cash)}</b></div>
          <div className="tile"><span>Ledger ({f.account?.code})</span><b>{money(f.pos?.ledger)}</b></div>
        </div>
        <Panel title="Vouchers">{detail?.vouchers.length ? <div className="scroll"><table>
          <thead><tr><th>No.</th><th>Date</th><th>Paid to / for</th><th>Account</th><th className="r">GH₵</th><th>Receipt</th><th>Status</th><th></th></tr></thead>
          <tbody>{detail.vouchers.map(v => <tr key={v.id}><td className="num">{v.number}</td><td className="num">{v.voucher_date}</td><td><b>{v.payee}</b> · {v.description}</td>
            <td className="muted">{v.account?.code} {v.account?.name}</td><td className="r num">{money(v.amount)}</td>
            <td>{v.receipt_path ? <button className="btn ghost small" style={{ padding: 0 }} type="button" onClick={() => act.run(async () => window.open(await receiptUrl(v.receipt_path), '_blank', 'noopener'))}>View</button> : <span className="pill bad">missing</span>}</td>
            <td><span className={'pill ' + ({ recorded: 'warn', approved: 'good', rejected: 'bad' } as any)[v.status]}>{v.status === 'recorded' ? 'awaiting top-up' : v.status}</span>{v.reject_note && <><br /><span className="muted" style={{ fontSize: 12 }}>{v.reject_note}</span></>}</td>
            <td className="r">{v.status === 'recorded' && !v.replenishment_id && (custodian || fin) && <ConfirmButton className="btn small ghost" label="Remove" confirm="Remove this voucher?" onConfirm={() => act.run(async () => { await q(supabase.from('petty_vouchers').delete().eq('id', v.id) as any); refresh(); })} />}</td></tr>)}</tbody></table></div>
          : <Empty>No vouchers yet.</Empty>}</Panel>
        <div className="two even">
          <Panel title="Cash counts">{detail?.counts.length ? <div className="scroll"><table><tbody>{detail.counts.map(c => <tr key={c.id}>
            <td className="num">{c.count_date}<br /><span className="muted" style={{ fontSize: 12 }}>{who(c.counted_by)}</span></td>
            <td className="r num">{money(c.counted)}<br /><span className="muted" style={{ fontSize: 12 }}>expected {money(c.expected)}</span></td>
            <td>{Number(c.difference) === 0 ? <span className="pill good">agrees</span> : <span className={'pill ' + (c.status === 'approved' ? '' : 'bad')}>{Number(c.difference) < 0 ? 'short ' : 'over '}{money(Math.abs(c.difference))}</span>}
              {c.status === 'approved' && Number(c.difference) !== 0 && <><br /><span className="muted" style={{ fontSize: 12 }}>{c.treatment === 'custodian' ? 'charged to custodian' : c.treatment === 'expense' ? 'written off' : 'to income'}: {c.approval_note}</span></>}</td></tr>)}</tbody></table></div>
            : <Empty>Not counted yet.</Empty>}</Panel>
          <Panel title="Replenishments">{detail?.reps.length ? <div className="scroll"><table><tbody>{detail.reps.map(r => <tr key={r.id}>
            <td className="num">{r.number}<br /><span className="muted" style={{ fontSize: 12 }}>{r.rep_date}</span></td>
            <td className="r num">{money(r.amount)}<br /><span className="muted" style={{ fontSize: 12 }}>vouchers {money(r.vouchers_total)}{Number(r.topup) ? ` + shortage ${money(r.topup)}` : ''}</span></td></tr>)}</tbody></table></div>
            : <Empty>Not replenished yet.</Empty>}</Panel>
        </div>
      </>}
    </>}

    {setup && L && <FormModal title="New petty cash float" submit="Set up and fund" busy={act.busy} onClose={() => setSetup(null)} onSave={() => act.run(async () => {
      await rpc('create_petty_float', { cid, p_name: setup.name, p_custodian: setup.custodian || null, p_amount: Number(setup.amount), p_voucher_limit: Number(setup.limit), p_count_days: Number(setup.days) || 30,
        p_from: setup.from || null, p_project: setup.project || null, p_branch: setup.branch || null, p_cost_centre: setup.centre || null });
      setSetup(null); reload(); }, 'Float set up')}>
      <div className="grid-form">
        <Field label="Name" id="pf-n" value={setup.name} onChange={v => setSetup({ ...setup, name: v })} placeholder="e.g. Prestea site office" required />
        <Select label="Custodian (holds the cash)" id="pf-c" value={setup.custodian} onChange={v => setSetup({ ...setup, custodian: v })} options={[['', 'Choose…'], ...L.team.map(t => [t.user_id, t.email] as [string, string])]} />
        <Field label="Float (GH₵)" id="pf-a" type="number" step="0.01" min="1" value={setup.amount} onChange={v => setSetup({ ...setup, amount: v })} required />
        <Field label="Limit per voucher (GH₵)" id="pf-l" type="number" step="0.01" min="1" value={setup.limit} onChange={v => setSetup({ ...setup, limit: v })} required />
        <Field label="Count at least every (days)" id="pf-d" type="number" min="1" max="92" value={setup.days} onChange={v => setSetup({ ...setup, days: v })} />
        <Select label="Fund from" id="pf-f" value={setup.from} onChange={v => setSetup({ ...setup, from: v })} options={[['', 'Bank (default)'], ...acctOpts(L.banks)]} />
        <Select label="Project (site float)" id="pf-p" value={setup.project} onChange={v => setSetup({ ...setup, project: v })} options={[['', 'None'], ...L.projects.map(p => [p.id, `${p.number || ''} ${p.name}`.trim()] as [string, string])]} />
        <DimSelects dims={dims} branch={setup.branch} centre={setup.centre} onChange={(b, c) => setSetup({ ...setup, branch: b, centre: c })} idPrefix="pf" />
      </div>
      <p className="muted" style={{ margin: 0, fontSize: 13 }}>Creates its own ledger account (from 1020) and posts Dr petty cash, Cr the account you fund it from.</p>
    </FormModal>}
    {vou && f && L && <FormModal title={`Record a payout from ${f.name}`} busy={act.busy} onClose={() => setVou(null)} onSave={() => act.run(async () => {
      if (!vou.payee.trim() || !vou.description.trim() || !vou.account_id || !(Number(vou.amount) > 0)) throw new Error('Enter who was paid, what for, the type of cost and the amount.');
      const path = vou.file ? await uploadReceipt(vou.file, session!.user.id) : null;
      await q(supabase.from('petty_vouchers').insert({ float_id: f.id, voucher_date: vou.voucher_date, payee: vou.payee.trim(), description: vou.description.trim(), account_id: vou.account_id, amount: Number(vou.amount), project_id: vou.project_id || null, receipt_path: path }) as any);
      setVou(null); refresh(); }, 'Voucher recorded')}>
      <div className="grid-form">
        <Field label="Paid to" id="pv-p" value={vou.payee} onChange={v => setVou({ ...vou, payee: v })} placeholder="e.g. Melcom, Kwame (driver)" required />
        <Field label="Date" id="pv-d" type="date" value={vou.voucher_date} onChange={v => setVou({ ...vou, voucher_date: v })} />
        <Field label={`Amount (up to GH₵ ${money(f.voucher_limit)})`} id="pv-a" type="number" step="0.01" min="0.01" value={vou.amount} onChange={v => setVou({ ...vou, amount: v })} required />
        <Select label="Type of cost" id="pv-ac" value={vou.account_id} onChange={v => setVou({ ...vou, account_id: v })} options={[['', 'Choose…'], ...acctOpts(L.expense)]} />
        <Select label="Project" id="pv-pj" value={vou.project_id} onChange={v => setVou({ ...vou, project_id: v })} options={[['', f.project_id ? 'The float\'s project' : 'None'], ...L.projects.map(p => [p.id, `${p.number || ''} ${p.name}`.trim()] as [string, string])]} />
      </div>
      <Field label="What for" id="pv-w" value={vou.description} onChange={v => setVou({ ...vou, description: v })} required />
      <div className="field"><label htmlFor="pv-f">Receipt photo (needed before Finance tops up)</label><input id="pv-f" type="file" accept="image/*,application/pdf" capture="environment" onChange={e => setVou({ ...vou, file: e.target.files?.[0] || null })} /></div>
    </FormModal>}
    {cnt && f && <FormModal title={`Count the cash in ${f.name}`} submit="Save count" busy={act.busy} onClose={() => setCnt(null)} onSave={() => act.run(async () => {
      const den: Record<string, number> = {}; [...NOTES, ...COINS].forEach(k => { if (Number(cnt[k]) > 0) den[k] = Math.floor(Number(cnt[k])); });
      await rpc('count_petty_cash', { p_float: f.id, p_denominations: den, p_note: cnt.note || null }); setCnt(null); refresh(); }, 'Count saved')}>
      <p style={{ margin: 0 }}>How many of each note and coin are in the box?</p>
      <div className="denoms">{[...NOTES, ...COINS].map(k => <div className="field" key={k}><label htmlFor={'dn' + k}>{dname(k)}</label>
        <input id={'dn' + k} type="number" min="0" step="1" inputMode="numeric" value={cnt[k] || ''} onChange={e => setCnt({ ...cnt, [k]: e.target.value })} /></div>)}</div>
      <p style={{ margin: 0 }}>Counted <b>GH₵ {money(counted)}</b> · should be GH₵ {money(f.pos?.expected_cash)} · {Math.abs(counted - Number(f.pos?.expected_cash)) < 0.005 ? <span className="pill good">agrees</span> : <span className="pill bad">{counted < Number(f.pos?.expected_cash) ? 'short' : 'over'} by {money(Math.abs(counted - Number(f.pos?.expected_cash)))}</span>}</p>
      <Field label="Note (who witnessed the count, reason for any difference)" id="cn-n" value={cnt.note} onChange={v => setCnt({ ...cnt, note: v })} />
    </FormModal>}
    {okCount && f && <FormModal title="Approve cash count difference" submit="Approve and post" busy={act.busy} onClose={() => setOkCount(null)} onSave={() => act.run(async () => {
      await rpc('approve_petty_count', { p_count: okCount.c.id, p_treatment: okCount.treatment, p_note: okCount.note }); setOkCount(null); refresh(); }, 'Difference posted')}>
      <p style={{ margin: 0 }}>Counted GH₵ {money(okCount.c.counted)} against GH₵ {money(okCount.c.expected)} expected: <b>{Number(okCount.c.difference) < 0 ? 'short' : 'over'} by GH₵ {money(Math.abs(okCount.c.difference))}</b>. {okCount.c.note}</p>
      {Number(okCount.c.difference) < 0 && <Select label="Treat the shortage as" id="oc-t" value={okCount.treatment} onChange={v => setOkCount({ ...okCount, treatment: v })} options={[['expense', 'Cash shortage (6960), written off'], ['custodian', 'Owed by the custodian (staff loan, deducted from salary)']]} />}
      <Field label="Explanation" id="oc-n" value={okCount.note} onChange={v => setOkCount({ ...okCount, note: v })} required />
    </FormModal>}
    {rep && f && L && <FormModal title={`Replenish ${f.name}`} submit="Replenish" busy={act.busy} onClose={() => setRep(null)} onSave={() => act.run(async () => {
      await rpc('replenish_float', { p_float: f.id, p_from: rep.from || null, p_date: rep.date, p_reject: rep.reject, p_reject_note: rep.note || null }); setRep(null); refresh(); }, 'Float replenished')}>
      <p style={{ margin: 0 }}>Untick any voucher you do not accept. The float is topped up by the accepted vouchers plus any shortage already written off, back to GH₵ {money(f.float_amount)}.</p>
      {open.length ? <div className="scroll"><table><tbody>{open.map(v => <tr key={v.id}>
        <td><input type="checkbox" aria-label={'Accept ' + v.number} checked={!rep.reject.includes(v.id)} onChange={e => setRep({ ...rep, reject: e.target.checked ? rep.reject.filter((x: string) => x !== v.id) : [...rep.reject, v.id] })} /></td>
        <td className="num">{v.number}</td><td>{v.payee} · {v.description}{!v.receipt_path && <> <span className="pill bad">no receipt</span></>}</td><td className="r num">{money(v.amount)}</td></tr>)}</tbody></table></div> : <p className="muted" style={{ margin: 0 }}>No vouchers waiting.</p>}
      <p style={{ margin: 0 }}>Pay <b>GH₵ {money(open.filter(v => !rep.reject.includes(v.id)).reduce((s, v) => s + Number(v.amount), 0) + Math.max(0, Number(f.float_amount) - Number(f.pos?.ledger)))}</b></p>
      <div className="grid-form">
        <Select label="Pay from" id="rp-f" value={rep.from} onChange={v => setRep({ ...rep, from: v })} options={[['', 'Bank (default)'], ...acctOpts(L.banks)]} />
        <Field label="Date" id="rp-d" type="date" value={rep.date} onChange={v => setRep({ ...rep, date: v })} />
      </div>
      {rep.reject.length > 0 && <Field label="Why vouchers were rejected" id="rp-n" value={rep.note} onChange={v => setRep({ ...rep, note: v })} required />}
    </FormModal>}
  </>;
}
