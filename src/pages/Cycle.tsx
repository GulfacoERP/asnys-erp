import { useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { q, rpc, supabase } from '../lib/supabase';
import { useSession } from '../lib/session';
import { cedis, longDate, money, today } from '../lib/format';
import { downloadCsv } from '../lib/download';
import { tablePdf } from '../lib/pdf';
import { ConfirmButton, Empty, Field, FormModal, Loading, PageHead, Panel, Select, useAction, useLoad } from '../components/ui';
import { MeetingForm } from './Tenders';

const STAGES: [string, string][] = [['tender', '1. Tender and business development'], ['award', '2. Contract award and project registration'], ['execution', '3. Execution and cost monitoring'],
  ['invoicing', '4. Milestones and invoicing'], ['closure', '5. Receivables and project closure']];
const UNITS: [string, string][] = [['business_development', 'Business Development'], ['finance', 'Finance'], ['engineering', 'Engineering'], ['management', 'Management']];

/** One page for the whole project cycle: what is waiting at each stage, who is responsible, and the deadlines. */
export function CyclePage() {
  const { cid, can } = useSession();
  const nav = useNavigate();
  const act = useAction();
  const [edit, setEdit] = useState<any | null>(null);
  const [meet, setMeet] = useState<any | null>(null);
  const fin = can('accountant');
  const { data, error, loading, reload } = useLoad(async () => {
    const [s, resp, billing, due, unreg, alerts, meetings, awards, payments] = await Promise.all([
      rpc<any>('cycle_status', { cid }),
      q<any[]>(supabase.from('cycle_responsibilities').select('*').eq('company_id', cid).order('sort') as any),
      rpc<any[]>('billing_schedule', { cid, p_days: 30 }).catch(() => [] as any[]),
      rpc<any[]>('reports_due', { cid }).catch(() => [] as any[]),
      rpc<any[]>('unregistered_projects', { cid }).catch(() => [] as any[]),
      fin || can('sales') ? rpc<any[]>('invoice_alerts', { cid }).catch(() => [] as any[]) : Promise.resolve([] as any[]),
      q<any[]>(supabase.from('project_meetings').select('*').eq('company_id', cid).eq('kind', 'management').order('meeting_date', { ascending: false }).limit(5) as any),
      q<any[]>(supabase.from('tenders').select('id,number,title,awarded_value,contract_ref,result_date').eq('company_id', cid).eq('status', 'awarded').is('project_id', null) as any),
      rpc<any[]>('payment_calendar', { cid, p_days: 30, p_project: null }).catch(() => [] as any[]),
    ]);
    return { s: s || {}, resp, billing, due, unreg, alerts, meetings, awards, payments };
  }, [cid]);
  if (!data) return <Loading error={error} loading={loading} />;
  const { s } = data;
  const card = (label: string, n: number, to: string, bad = false) => <Link to={to} className="tile" style={{ textDecoration: 'none', color: 'inherit' }}><span>{label}</span><b style={{ color: n > 0 && bad ? 'var(--bad)' : undefined }}>{n}</b></Link>;
  return <>
    <PageHead title="Project cycle" sub="From tender to final payment. No project should exist operationally without also existing in Finance's monitoring.">
      <Link className="btn" to="/receivables">Receivables</Link>
      {fin && <Link className="btn" to="/project-finance">Project finance</Link>}
      <button className="btn" type="button" onClick={() => setMeet({ kind: 'management', meeting_date: today(), attendees: '', minutes: '', decisions: '' })}>Record management meeting</button>
    </PageHead>
    <div className="tiles">
      {card('Tenders being prepared', s.tenders_open, '/tenders')}
      {card('Deadlines in 7 days', s.tenders_due_7, '/tenders', true)}
      {card('Reviews not fully signed', s.reviews_unsigned, '/tenders', true)}
      {card('Awards not registered', s.awards_unregistered, '/tenders', true)}
      {card('Projects not registered', s.projects_unregistered, '/project-cycle#unregistered', true)}
      {card('Budgets for approval', s.budgets_waiting, '/project-cycle#unregistered', true)}
      {card('Progress reports overdue', s.reports_overdue, '/project-cycle#reports', true)}
      {card('Reports for Finance to read', s.reports_to_review, '/project-cycle#reports')}
      {card('Milestones ready to invoice', s.milestones_ready, '/project-cycle#billing', true)}
      {card('Invoices overdue', s.invoices_overdue, '/receivables', true)}
      {card('Overdue with no follow-up', s.invoices_no_followup, '/receivables', true)}
      {card('Awaiting financial clearance', s.awaiting_clearance, '/projects', true)}
    </div>

    {(data.awards.length > 0 || data.unreg.length > 0) && <Panel title={<h2 id="unregistered">Waiting for Finance: registration and budgets</h2>}><div className="scroll"><table>
      <thead><tr><th>Item</th><th>Waiting for</th><th></th></tr></thead>
      <tbody>{data.awards.map(a => <tr key={a.id} className="click" onClick={() => nav('/tenders/' + a.id)}><td><b>{a.number}</b> {a.title}<br /><span className="muted" style={{ fontSize: 12 }}>{a.contract_ref} · {cedis(a.awarded_value)} · awarded {longDate(a.result_date)}</span></td>
        <td><span className="pill bad">Project not registered</span></td><td className="r">{fin && <button className="btn small primary" type="button">Register</button>}</td></tr>)}
        {data.unreg.map(u => <tr key={u.project_id} className="click" onClick={() => nav('/projects/' + u.project_id)}><td><b>{u.number}</b> {u.name}</td>
          <td><span className={'pill ' + (!u.registered ? 'bad' : 'warn')}>{!u.registered ? 'Not registered with Finance' : u.budget_status === 'submitted' ? 'Budget waiting for approval' : u.budget_status === 'revised' ? 'Revised budget waiting' : 'Budget not submitted'}</span></td><td /></tr>)}</tbody>
    </table></div><div className="body muted" style={{ fontSize: 13 }}>Until Finance registers a project and approves its budget, nothing can be spent on it: no purchase requests, orders, supplier bills, stock issues or expense claims.</div></Panel>}

    <Panel title={<h2 id="payments">Contract payments: next 30 days</h2>}>{data.payments.length ? <div className="scroll"><table>
      <thead><tr><th>When</th><th>Action</th><th>Project and client</th><th>What</th><th className="r">GH₵</th></tr></thead>
      <tbody>{data.payments.map((r, i) => <tr key={i} className="click" onClick={() => nav(r.kind === 'to_invoice' ? '/projects/' + r.project_id : '/invoices/' + r.ref_id)}>
        <td className="num" style={{ color: ['late', 'overdue'].includes(r.status) ? 'var(--bad)' : undefined }}>{r.action_date}<br /><span style={{ fontSize: 12 }}>{r.days_left < 0 ? `${-r.days_left} days late` : r.days_left === 0 ? 'today' : `in ${r.days_left} days`}</span></td>
        <td>{r.kind === 'to_invoice' ? <span className={'pill ' + (r.status === 'late' ? 'bad' : 'warn')}>Raise invoice</span> : <span className={'pill ' + (r.status === 'overdue' ? 'bad' : 'warn')}>{r.status === 'overdue' ? 'Payment overdue' : 'Payment due'}</span>}</td>
        <td>{r.project}<br /><span className="muted" style={{ fontSize: 12 }}>{r.customer}</span></td><td className="wrap-cell">{r.description}{r.invoice_number && <span className="muted"> · {r.invoice_number}</span>}</td>
        <td className="r num">{money(r.amount_ghs)}</td></tr>)}</tbody></table></div>
      : <Empty>No contract payments to invoice or collect in the next 30 days. Set each contract's payment terms on the project's Billing tab.</Empty>}</Panel>
    <div className="two">
      <Panel title={<h2 id="billing">Billing schedule: next 30 days</h2>}>{data.billing.length ? <div className="scroll"><table>
        <thead><tr><th>Project</th><th>What</th><th>Due</th><th className="r">GH₵</th></tr></thead>
        <tbody>{data.billing.map((b, i) => <tr key={i} className="click" onClick={() => nav('/projects/' + b.project_id)}><td>{b.project}<br /><span className="muted" style={{ fontSize: 12 }}>{b.customer}</span></td>
          <td className="wrap-cell">{b.item}{b.ready ? <span className="pill good" style={{ marginLeft: 6 }}>Ready to invoice</span> : <span className="pill" style={{ marginLeft: 6 }}>Not certified</span>}{b.certified_note && <><br /><span className="muted" style={{ fontSize: 12 }}>{b.certified_note}</span></>}</td>
          <td className="num" style={{ color: b.due_date && b.due_date < today() ? 'var(--bad)' : undefined }}>{b.due_date || ''}</td><td className="r num">{money(b.amount_ghs)}</td></tr>)}</tbody></table></div>
        : <Empty>Nothing due to be invoiced in the next 30 days.</Empty>}</Panel>
      <Panel title={<h2 id="reports">Progress reports due</h2>}>{data.due.length ? <div className="scroll"><table><tbody>{data.due.map(d => <tr key={d.project_id} className="click" onClick={() => nav('/projects/' + d.project_id)}>
        <td><b>{d.number}</b> {d.name}<br /><span className="muted" style={{ fontSize: 12 }}>{d.frequency}{d.last_period ? ' · last ' + longDate(d.last_period) : ' · none yet'}</span></td>
        <td className="num" style={{ color: d.days_overdue > 0 ? 'var(--bad)' : undefined }}>{d.days_overdue > 0 ? `${d.days_overdue} days late` : 'due ' + longDate(d.due_on)}</td></tr>)}</tbody></table></div>
        : <Empty>All progress reports are up to date.</Empty>}</Panel>
    </div>
    {data.alerts.length > 0 && <Panel title="Invoices to chase" actions={<Link className="btn small" to="/receivables">Receivables</Link>}><div className="scroll"><table><tbody>{data.alerts.slice(0, 10).map(a => <tr key={a.invoice_id} className="click" onClick={() => nav('/invoices/' + a.invoice_id)}>
      <td className="num">{a.number}</td><td>{a.customer}<br /><span className="muted" style={{ fontSize: 12 }}>{a.project}</span></td><td className="r num">{money(a.outstanding_ghs)}</td><td style={{ color: /Overdue/.test(a.alert) ? 'var(--bad)' : undefined }}>{a.alert}</td></tr>)}</tbody></table></div></Panel>}

    <Panel title="Who does what, and by when" actions={can('admin') && <button className="btn small" type="button" onClick={() => setEdit({ stage: 'execution', unit: 'engineering', responsibility: '', deadline: '' })}>Add duty</button>}>
      {STAGES.map(([st, label]) => { const rows = data.resp.filter(r => r.stage === st); return rows.length ? <div key={st}>
        <div className="body" style={{ paddingBottom: 4 }}><b>{label}</b></div>
        <div className="scroll"><table><tbody>{rows.map(r => <tr key={r.id}><td style={{ width: 170 }}><span className="pill">{UNITS.find(u => u[0] === r.unit)?.[1]}</span></td><td className="wrap-cell">{r.responsibility}</td>
          <td className="muted wrap-cell" style={{ width: 240 }}>{r.deadline}</td>
          <td className="r" style={{ width: 160, whiteSpace: 'nowrap' }}>{can('admin') && <span className="actions" style={{ justifyContent: 'flex-end', flexWrap: 'nowrap' }}><button className="btn small ghost" type="button" onClick={() => setEdit({ ...r, deadline: r.deadline || '' })}>Edit</button>
            <ConfirmButton className="btn small ghost" label="Remove" confirm="Remove?" onConfirm={() => act.run(async () => { await q(supabase.from('cycle_responsibilities').delete().eq('id', r.id) as any); reload(); })} /></span>}</td></tr>)}</tbody></table></div></div> : null; })}
    </Panel>
    <Panel title="Management meetings">{data.meetings.length ? <div className="scroll"><table><tbody>{data.meetings.map(m => <tr key={m.id}><td className="num" style={{ width: 110 }}>{m.meeting_date}</td>
      <td className="wrap-cell">{m.attendees && <span className="muted">{m.attendees}<br /></span>}{m.minutes}{m.decisions && <><br /><b>Decisions:</b> {m.decisions}</>}</td></tr>)}</tbody></table></div>
      : <Empty>Record each management meeting. Finance brings the pending receivables report (Receivables → PDF).</Empty>}</Panel>

    {edit && <FormModal title={edit.id ? 'Edit duty' : 'Add duty'} busy={act.busy} onClose={() => setEdit(null)} onSave={() => act.run(async () => {
      const row = { stage: edit.stage, unit: edit.unit, responsibility: edit.responsibility, deadline: edit.deadline || null };
      if (edit.id) await q(supabase.from('cycle_responsibilities').update(row).eq('id', edit.id) as any);
      else await q(supabase.from('cycle_responsibilities').insert({ ...row, company_id: cid, sort: data.resp.length + 1 }) as any);
      setEdit(null); reload(); }, 'Saved')}>
      <div className="grid-form"><Select label="Stage" id="dy-stage" value={edit.stage} onChange={v => setEdit({ ...edit, stage: v })} options={STAGES} />
        <Select label="Unit" id="dy-unit" value={edit.unit} onChange={v => setEdit({ ...edit, unit: v })} options={UNITS} /></div>
      <Field label="Responsibility" id="dy-resp" type="textarea" value={edit.responsibility} onChange={v => setEdit({ ...edit, responsibility: v })} />
      <Field label="Deadline" id="dy-dl" value={edit.deadline} onChange={v => setEdit({ ...edit, deadline: v })} placeholder="e.g. Within 2 working days of the award" />
    </FormModal>}
    {meet && <MeetingForm meet={meet} setMeet={setMeet} target={{}} cid={cid} onDone={reload} />}
  </>;
}

/** Every unpaid invoice with its age and the last follow-up: the pending receivables report for management meetings. */
export function ReceivablesPage() {
  const { cid, company } = useSession();
  const nav = useNavigate();
  const act = useAction();
  const [follow, setFollow] = useState<any | null>(null);
  const [only, setOnly] = useState('');
  const { data, error, loading, reload } = useLoad(() => rpc<any[]>('receivables_report', { cid, p_as_of: today(), p_project: null }), [cid]);
  if (!data) return <Loading error={error} loading={loading} />;
  const rows = data.filter(r => !only || (only === 'action' ? r.needs_action : r.bucket === only));
  const buckets = ['Not due', '1-30 days', '31-60 days', '61-90 days', 'Over 90 days'];
  const tot = (f: (r: any) => boolean) => data.filter(f).reduce((a, r) => a + Number(r.outstanding_ghs), 0);
  const head = ['Invoice', 'Customer', 'Project', 'Due', 'Days overdue', 'Outstanding (GHS)', 'Last follow-up', 'Promised', 'Next action'];
  const body = rows.map(r => [r.number, r.customer, r.project || '', r.due_date || '', String(r.days_overdue), money(r.outstanding_ghs), r.last_followup ? `${r.last_followup}: ${r.last_note}` : 'None',
    r.promised_date ? `${r.promised_date}${r.promised_amount ? ' GHS ' + money(r.promised_amount) : ''}` : '', r.next_action || '']);
  return <>
    <PageHead title="Receivables and follow-up" sub={`${data.length} unpaid invoices · ${cedis(tot(() => true))} outstanding · ${cedis(tot(r => r.days_overdue > 0))} overdue`}>
      <button className="btn" type="button" onClick={() => tablePdf({ company: company!, title: 'Pending receivables report', subtitle: 'For the management meeting · ' + longDate(today()), head, body, rightAlign: [4, 5], landscape: true,
        foot: ['', '', '', '', 'Total', money(rows.reduce((a, r) => a + Number(r.outstanding_ghs), 0)), '', '', ''], filename: 'pending-receivables-' + today(),
        notes: buckets.map(b => `${b}: GHS ${money(tot(r => r.bucket === b))}`).join('   ·   ') })}>Report PDF</button>
      <button className="btn" type="button" onClick={() => downloadCsv('receivables-' + today(), head, body)}>CSV</button>
    </PageHead>
    <div className="tiles">{buckets.map(b => <button key={b} type="button" className="tile" style={{ textAlign: 'left', cursor: 'pointer', outline: only === b ? '2px solid var(--accent)' : undefined }} onClick={() => setOnly(only === b ? '' : b)}>
      <span>{b}</span><b style={{ fontSize: 17, color: b !== 'Not due' && tot(r => r.bucket === b) > 0 ? 'var(--bad)' : undefined }}>{money(tot(r => r.bucket === b))}</b></button>)}
      <button type="button" className="tile" style={{ textAlign: 'left', cursor: 'pointer', outline: only === 'action' ? '2px solid var(--accent)' : undefined }} onClick={() => setOnly(only === 'action' ? '' : 'action')}>
        <span>Needs a follow-up now</span><b style={{ fontSize: 17, color: 'var(--bad)' }}>{data.filter(r => r.needs_action).length}</b></button></div>
    <Panel>{rows.length ? <div className="scroll"><table>
      <thead><tr><th>Invoice</th><th>Customer and project</th><th>Due</th><th className="r">Outstanding (GH₵)</th><th>Last follow-up</th><th></th></tr></thead>
      <tbody>{rows.map(r => <tr key={r.invoice_id}>
        <td className="num"><button className="btn ghost small" style={{ padding: 0 }} type="button" onClick={() => nav('/invoices/' + r.invoice_id)}>{r.number}</button></td>
        <td>{r.customer}{r.project && <><br /><span className="muted" style={{ fontSize: 12 }}>{r.project}</span></>}</td>
        <td className="num" style={{ color: r.days_overdue > 0 ? 'var(--bad)' : undefined }}>{r.due_date}{r.days_overdue > 0 && <><br /><span style={{ fontSize: 12 }}>{r.days_overdue} days late</span></>}</td>
        <td className="r num">{money(r.outstanding_ghs)}</td>
        <td className="wrap-cell" style={{ fontSize: 13 }}>{r.last_followup ? <>{r.last_followup}: {r.last_note}{r.promised_date && <><br /><span className="pill good">Promised {r.promised_date}{r.promised_amount ? ' · ' + money(r.promised_amount) : ''}</span></>}
          {r.next_action && <span className="muted"> · next {r.next_action}</span>}</> : <span className="muted">None</span>}{r.needs_action && <span className="pill bad" style={{ marginLeft: 6 }}>Follow up</span>}</td>
        <td className="r"><button className="btn small" type="button" onClick={() => setFollow({ invoice_id: r.invoice_id, number: r.number, method: 'call', contact: '', note: '', promised_date: '', promised_amount: '', next_action_date: '' })}>Log follow-up</button></td></tr>)}</tbody>
    </table></div> : <Empty>Nothing outstanding.</Empty>}</Panel>
    {follow && <FollowUpForm f={follow} setF={setFollow} onDone={reload} busy={act.busy} run={act.run} />}
  </>;
}

export function FollowUpForm({ f, setF, onDone, busy, run }: { f: any; setF: (x: any) => void; onDone: () => void; busy: boolean; run: (fn: () => Promise<unknown>, msg?: string) => Promise<boolean> }) {
  return <FormModal title={`Follow up ${f.number}`} busy={busy} onClose={() => setF(null)} onSave={() => run(async () => {
    await q(supabase.from('invoice_followups').insert({ invoice_id: f.invoice_id, company_id: '00000000-0000-0000-0000-000000000000', method: f.method, contact: f.contact || null, note: f.note,
      promised_date: f.promised_date || null, promised_amount: f.promised_amount ? Number(f.promised_amount) : null, next_action_date: f.next_action_date || null }) as any);
    setF(null); onDone(); }, 'Follow-up logged')}>
    <div className="grid-form">
      <Select label="How" id="fu-m" value={f.method} onChange={v => setF({ ...f, method: v })} options={[['call', 'Phone call'], ['email', 'Email'], ['visit', 'Visit'], ['whatsapp', 'WhatsApp'], ['letter', 'Letter'], ['statement', 'Statement sent'], ['other', 'Other']]} />
      <Field label="Spoke to" id="fu-c" value={f.contact} onChange={v => setF({ ...f, contact: v })} />
    </div>
    <Field label="What was said" id="fu-n" type="textarea" value={f.note} onChange={v => setF({ ...f, note: v })} />
    <div className="grid-form">
      <Field label="Promised to pay on" id="fu-pd" type="date" value={f.promised_date} onChange={v => setF({ ...f, promised_date: v })} />
      <Field label="Amount promised (GH₵)" id="fu-pa" type="number" step="0.01" min="0" value={f.promised_amount} onChange={v => setF({ ...f, promised_amount: v })} />
      <Field label="Next follow-up on" id="fu-nx" type="date" value={f.next_action_date} onChange={v => setF({ ...f, next_action_date: v })} />
    </div>
    <p className="muted" style={{ margin: 0, fontSize: 13 }}>Without a next date, the invoice comes back on the follow-up list in 14 days.</p>
  </FormModal>;
}

/** Management view: each project's money position. */
export function ProjectFinancePage() {
  const { cid, company } = useSession();
  const nav = useNavigate();
  const [show, setShow] = useState('open');
  const { data, error, loading } = useLoad(() => rpc<any[]>('project_finance_overview', { cid }), [cid]);
  if (!data) return <Loading error={error} loading={loading} />;
  const rows = data.filter(r => show === 'all' || (show === 'open' ? !['closed', 'cancelled'].includes(r.status) : r.status === 'closed'));
  const sum = (k: string) => rows.reduce((a, r) => a + Number(r[k] || 0), 0);
  const head = ['Project', 'Customer', 'Stage', 'Registered', 'Budget', 'Contract', 'Cost budget', 'Spent', 'Committed', 'Invoiced (excl. VAT)', 'Received', 'Outstanding', 'Overdue', 'Unbilled', 'Gross profit', 'Margin %', 'Last report'];
  const body = rows.map(r => [`${r.number} ${r.name}`, r.customer || '', r.status, r.registered ? 'Yes' : 'NO', r.budget_status, money(r.contract_value), money(r.budget_cost), money(r.actual_cost), money(r.committed_cost),
    money(r.invoiced), money(r.received), money(r.outstanding), money(r.overdue), money(r.unbilled), money(r.gross_profit), r.margin_pct == null ? '' : String(r.margin_pct), r.last_report || '']);
  return <>
    <PageHead title="Project finance" sub={`${rows.length} projects · contracts ${cedis(sum('contract_value'))} · invoiced ${cedis(sum('invoiced'))} · outstanding ${cedis(sum('outstanding'))} · gross profit ${cedis(sum('gross_profit'))}`}>
      <button className="btn" type="button" onClick={() => tablePdf({ company: company!, title: 'Project financial position', subtitle: longDate(today()), head, body, rightAlign: [5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15], landscape: true, filename: 'project-finance-' + today(),
        notes: 'GHS. Spent = actual cost in the ledger plus approved labour. Received and outstanding include VAT; invoiced and gross profit exclude it.' })}>PDF</button>
      <button className="btn" type="button" onClick={() => downloadCsv('project-finance-' + today(), head, body)}>CSV</button>
    </PageHead>
    <div className="actions">{([['open', 'Open'], ['closed', 'Closed'], ['all', 'All']] as const).map(([k, l]) => <button key={k} type="button" className={'btn small' + (show === k ? ' primary' : '')} onClick={() => setShow(k)}>{l}</button>)}</div>
    <Panel>{rows.length ? <div className="scroll"><table>
      <thead><tr><th>Project</th><th className="r">Contract</th><th className="r">Spent + committed</th><th className="r">Invoiced</th><th className="r">Received</th><th className="r">Outstanding</th><th className="r">Gross profit</th><th>Control</th></tr></thead>
      <tbody>{rows.map(r => <tr key={r.project_id} className="click" onClick={() => nav('/projects/' + r.project_id)}>
        <td><b>{r.number}</b> {r.name}<br /><span className="muted" style={{ fontSize: 12 }}>{r.customer || 'Internal'} · {r.status} · {r.pct_complete}%</span></td>
        <td className="r num">{money(r.contract_value)}</td>
        <td className="r num" style={{ color: Number(r.budget_cost) > 0 && Number(r.actual_cost) + Number(r.committed_cost) > Number(r.budget_cost) ? 'var(--bad)' : undefined }}>{money(Number(r.actual_cost) + Number(r.committed_cost))}<br /><span className="muted" style={{ fontSize: 12 }}>of {money(r.budget_cost)}</span></td>
        <td className="r num">{money(r.invoiced)}{Number(r.unbilled) > 0 && <><br /><span className="muted" style={{ fontSize: 12 }}>+{money(r.unbilled)} unbilled</span></>}</td>
        <td className="r num">{money(r.received)}</td>
        <td className="r num" style={{ color: Number(r.overdue) > 0 ? 'var(--bad)' : undefined }}>{money(r.outstanding)}{Number(r.overdue) > 0 && <><br /><span style={{ fontSize: 12 }}>{money(r.overdue)} overdue</span></>}</td>
        <td className="r num" style={{ color: Number(r.gross_profit) < 0 ? 'var(--bad)' : undefined }}>{money(r.gross_profit)}{r.margin_pct != null && <><br /><span className="muted" style={{ fontSize: 12 }}>{r.margin_pct}%</span></>}</td>
        <td style={{ fontSize: 12 }}>{!r.registered ? <span className="pill bad">Not registered</span> : r.budget_status !== 'approved' ? <span className="pill warn">Budget {r.budget_status}</span> : <span className="pill good">Registered</span>}
          {r.report_overdue && <><br /><span className="pill bad">Report overdue</span></>}{r.cleared && <><br /><span className="pill good">Cleared</span></>}</td></tr>)}</tbody>
      <tfoot><tr><td>Total</td><td className="r num">{money(sum('contract_value'))}</td><td className="r num">{money(sum('actual_cost') + sum('committed_cost'))}</td><td className="r num">{money(sum('invoiced'))}</td>
        <td className="r num">{money(sum('received'))}</td><td className="r num">{money(sum('outstanding'))}</td><td className="r num">{money(sum('gross_profit'))}</td><td /></tr></tfoot>
    </table></div> : <Empty>No projects.</Empty>}</Panel>
  </>;
}

/** Inbox of notices sent by the system. */
export function NotificationsPage() {
  const { session } = useSession();
  const nav = useNavigate();
  const act = useAction();
  const { data, reload } = useLoad(() => q<any[]>(supabase.from('notifications').select('*').eq('user_id', session?.user.id).order('created_at', { ascending: false }).limit(200) as any), [session?.user.id]);
  const unread = (data || []).filter(n => !n.read_at);
  return <>
    <PageHead title="Notifications" sub={`${unread.length} unread`}>
      {unread.length > 0 && <button className="btn" type="button" onClick={() => act.run(async () => { await q(supabase.from('notifications').update({ read_at: new Date().toISOString() }).eq('user_id', session?.user.id).is('read_at', null) as any); reload(); window.dispatchEvent(new Event('asnys:notes')); })}>Mark all read</button>}
    </PageHead>
    <Panel>{data && data.length ? <div className="scroll"><table><tbody>{data.map(n => <tr key={n.id} className="click" style={n.read_at ? { opacity: .6 } : undefined}
      onClick={() => act.run(async () => { if (!n.read_at) await q(supabase.from('notifications').update({ read_at: new Date().toISOString() }).eq('id', n.id) as any); window.dispatchEvent(new Event('asnys:notes')); if (n.path) nav(n.path); else reload(); })}>
      <td style={{ width: 12 }}>{!n.read_at && <span style={{ display: 'inline-block', width: 8, height: 8, borderRadius: 4, background: 'var(--accent)' }} />}</td>
      <td className="wrap-cell"><b>{n.title}</b>{n.body && <><br /><span className="muted">{n.body}</span></>}</td>
      <td className="muted num" style={{ width: 140 }}>{n.created_at.slice(0, 16).replace('T', ' ')}</td></tr>)}</tbody></table></div>
      : <Empty>No notifications. Tenders, awards, budgets, progress reports, milestones ready to invoice and close-outs are announced here to the people who act on them.</Empty>}</Panel>
  </>;
}
