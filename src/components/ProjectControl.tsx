import { useState } from 'react';
import { Link } from 'react-router-dom';
import { q, rpc, supabase } from '../lib/supabase';
import { useSession } from '../lib/session';
import { cedis, longDate, money, today } from '../lib/format';
import { Empty, Field, FormModal, Panel, Select, useAction, useLoad } from './ui';
import { MeetingForm } from '../pages/Tenders';

const BUDGET: Record<string, [string, string]> = { none: ['Not submitted', 'bad'], submitted: ['Waiting for Finance', 'warn'], approved: ['Approved', 'good'], revised: ['Revised: waiting for Finance', 'warn'] };

/** Finance control on a project: registration, budget approval, reporting frequency, cost reconciliation and financial clearance. */
export function FinanceControl({ p, manage, onChange }: { p: any; manage: boolean; onChange: () => void }) {
  const { cid, can } = useSession();
  const act = useAction();
  const fin = can('accountant');
  const [reg, setReg] = useState<any | null>(null);
  const [dec, setDec] = useState<any | null>(null);
  const [clear, setClear] = useState<any | null>(null);
  const [rec, setRec] = useState<any | null>(null);
  const { data, reload } = useLoad(async () => ({
    centres: await q<any[]>(supabase.from('cost_centres').select('id,code,name').eq('company_id', cid).eq('active', true).order('code') as any).catch(() => [] as any[]),
    tender: p.tender_id ? await q<any>(supabase.from('tenders').select('id,number,contract_ref,awarded_value').eq('id', p.tender_id).single() as any).catch(() => null) : null,
    recs: await q<any[]>(supabase.from('project_cost_reconciliations').select('*').eq('project_id', p.id).order('created_at', { ascending: false }) as any),
    gate: await q<any>(supabase.from('companies').select('require_project_registration').eq('id', cid).single() as any).catch(() => ({ require_project_registration: true })),
  }), [p.id, cid]);
  if (!data || p.is_template) return null;
  const done = () => { reload(); onChange(); };
  const registered = !!p.finance_registered_at;
  const b = BUDGET[p.budget_status] || BUDGET.none;
  const lastRec = data.recs[0];
  const gateOn = data.gate?.require_project_registration !== false;
  return <Panel title="Finance control" actions={<>
    {!registered && fin && <button className="btn small primary" type="button" onClick={() => setReg({ cost_centre: p.cost_centre_id || data.centres[0]?.id || '', contract_ref: p.contract_ref || '', contract_value: String(p.contract_value || ''), note: '' })}>Register project</button>}
    {registered && manage && ['none', 'revised'].includes(p.budget_status) && <button className="btn small primary" type="button" onClick={() => act.run(async () => { await rpc('submit_project_budget', { p_project: p.id, p_note: null }); done(); }, 'Budget sent to Finance')}>Submit budget</button>}
    {fin && ['submitted', 'revised'].includes(p.budget_status) && <button className="btn small primary" type="button" onClick={() => setDec({ approve: true, note: '' })}>Approve budget</button>}
    {fin && ['submitted', 'revised'].includes(p.budget_status) && <button className="btn small" type="button" onClick={() => setDec({ approve: false, note: '' })}>Return budget</button>}
    {fin && registered && <button className="btn small" type="button" onClick={() => setRec({ from: lastRec ? lastRec.period_to : (p.actual_start || p.start_date || today()), to: today(), outcome: 'agreed', notes: '' })}>Reconcile costs</button>}
    {fin && p.status === 'done' && !p.fin_cleared_at && <button className="btn small primary" type="button" onClick={() => setClear({ note: '', force: false })}>Give financial clearance</button>}</>}>
    <div className="body" style={{ display: 'grid', gap: 10 }}>
      <div className="grid-form" style={{ alignItems: 'start' }}>
        <div><div className="label">Registered with Finance</div>{registered ? <span className="pill good">Yes · {longDate(p.finance_registered_at)}</span> : <span className="pill bad">Not yet</span>}
          {data.tender && <><br /><Link to={'/tenders/' + data.tender.id} style={{ fontSize: 13 }}>{data.tender.number}</Link></>}{p.contract_ref && <span className="muted" style={{ fontSize: 13 }}> · contract {p.contract_ref}</span>}</div>
        <div><div className="label">Budget</div><span className={'pill ' + b[1]}>{b[0]}</span>{p.budget_note && <><br /><span className="muted" style={{ fontSize: 12 }}>{p.budget_note}</span></>}</div>
        <div><div className="label">Progress reports</div>{manage ? <select aria-label="Report frequency" value={p.report_frequency || 'monthly'} onChange={e => act.run(async () => { await q(supabase.from('projects').update({ report_frequency: e.target.value }).eq('id', p.id) as any); done(); }, 'Saved')}>
          <option value="weekly">Weekly</option><option value="fortnightly">Fortnightly</option><option value="monthly">Monthly (by the 5th)</option></select> : <span>{p.report_frequency}</span>}</div>
        <div><div className="label">Cost reconciliation</div>{lastRec ? <span className={'pill ' + (lastRec.outcome === 'agreed' ? 'good' : 'warn')}>{longDate(lastRec.period_to)} · {lastRec.outcome}</span> : <span className="pill">Not yet</span>}</div>
        <div><div className="label">Financial clearance</div>{p.fin_cleared_at ? <span className="pill good">Given {longDate(p.fin_cleared_at)}</span> : <span className="pill">{p.status === 'done' ? 'Waiting' : 'At close-out'}</span>}
          {p.fin_clearance_note && <><br /><span className="muted" style={{ fontSize: 12 }}>{p.fin_clearance_note}</span></>}</div>
      </div>
      {gateOn && (!registered || !p.budget_approved_at) && <div className="note" style={{ background: 'var(--warn-soft)' }}>{!registered ? 'Finance has not registered this project yet.' : 'The budget has not been approved yet.'} Nothing can be spent on it until it has been registered and its budget approved (no purchase requests, orders, supplier bills, stock issues or expense claims).</div>}
      {data.recs.length > 0 && <details><summary className="muted" style={{ fontSize: 13, cursor: 'pointer' }}>Reconciliation history ({data.recs.length})</summary>
        <table><tbody>{data.recs.map(r => <tr key={r.id}><td className="num">{r.period_from} → {r.period_to}</td><td className="r num">ledger {money(r.ledger_total)}</td><td className="r num">report {money(r.report_total)}</td>
          <td>{r.outcome}</td><td className="wrap-cell muted">{r.notes} · {(r.reconciled_email || '').split('@')[0]}</td></tr>)}</tbody></table></details>}
    </div>
    {reg && <FormModal title={`Register ${p.number}`} submit="Register" busy={act.busy} onClose={() => setReg(null)} onSave={() => act.run(async () => {
      await rpc('register_project', { p_project: p.id, p_cost_centre: reg.cost_centre || null, p_branch: null, p_contract_ref: reg.contract_ref || null, p_contract_value: reg.contract_value ? Number(reg.contract_value) : null, p_note: reg.note || null }); setReg(null); done(); }, 'Registered; the project manager has been notified')}>
      <div className="grid-form">
        <Select label="Cost centre" id="pr-cc" value={reg.cost_centre} onChange={v => setReg({ ...reg, cost_centre: v })} options={[['', 'Choose…'], ...data.centres.map(c => [c.id, `${c.code} ${c.name}`] as [string, string])]} />
        <Field label="Contract or PO number" id="pr-ref" value={reg.contract_ref} onChange={v => setReg({ ...reg, contract_ref: v })} />
        <Field label={`Contract value (${p.currency}, excl. VAT)`} id="pr-val" type="number" step="0.01" min="0" value={reg.contract_value} onChange={v => setReg({ ...reg, contract_value: v })} />
      </div>
      <Field label="Note to the project manager" id="pr-note" value={reg.note} onChange={v => setReg({ ...reg, note: v })} />
      <p className="muted" style={{ margin: 0, fontSize: 13 }}>Project code {p.number}. Every cost on this project will be tagged to the project and this cost centre.</p>
    </FormModal>}
    {dec && <FormModal title={dec.approve ? 'Approve the budget' : 'Return the budget'} submit={dec.approve ? 'Approve' : 'Return'} busy={act.busy} onClose={() => setDec(null)} onSave={() => act.run(async () => {
      await rpc('approve_project_budget', { p_project: p.id, p_approve: dec.approve, p_note: dec.note || null }); setDec(null); done(); }, dec.approve ? 'Budget approved; spending can start' : 'Budget returned')}>
      <Field label={dec.approve ? 'Note (optional)' : 'What needs to change'} id="bd-note" type="textarea" value={dec.note} onChange={v => setDec({ ...dec, note: v })} />
      <p className="muted" style={{ margin: 0, fontSize: 13 }}>Check the cost budget against the contract value and the tender estimate on the Budget tab.</p>
    </FormModal>}
    {rec && <FormModal title="Reconcile project costs" submit="Record reconciliation" busy={act.busy} onClose={() => setRec(null)} onSave={() => act.run(async () => {
      await rpc('reconcile_project_costs', { p_project: p.id, p_from: rec.from, p_to: rec.to, p_outcome: rec.outcome, p_notes: rec.notes || null }); setRec(null); done(); }, 'Reconciliation recorded')}>
      <div className="grid-form"><Field label="From" id="rc-from" type="date" value={rec.from} onChange={v => setRec({ ...rec, from: v })} required />
        <Field label="To" id="rc-to" type="date" value={rec.to} onChange={v => setRec({ ...rec, to: v })} required />
        <Select label="Outcome" id="rc-out" value={rec.outcome} onChange={v => setRec({ ...rec, outcome: v })} options={[['agreed', 'All costs on the right project'], ['adjusted', 'Corrections made']]} /></div>
      <Field label={rec.outcome === 'adjusted' ? 'Corrections (journal numbers and what moved)' : 'Notes'} id="rc-notes" type="textarea" value={rec.notes} onChange={v => setRec({ ...rec, notes: v })} />
      <p className="muted" style={{ margin: 0, fontSize: 13 }}>Go through the project's lines in <Link to={`/project-costs?project=${p.id}`}>the cost report</Link> and the ledger (filter by this project). Move anything on the wrong project with a manual journal, then record the result here. The totals are captured automatically.</p>
    </FormModal>}
    {clear && <FormModal title="Financial clearance" submit="Give clearance" busy={act.busy} onClose={() => setClear(null)} onSave={() => act.run(async () => {
      await rpc('clear_project_finance', { p_project: p.id, p_note: clear.note || null, p_force: clear.force }); setClear(null); done(); }, 'Financial clearance given; the project can now be closed')}>
      <p style={{ margin: 0 }}>Confirm that everything is invoiced, costs are reconciled and receivables are collected or accounted for.</p>
      <label className="check"><input type="checkbox" checked={clear.force} onChange={e => setClear({ ...clear, force: e.target.checked })} /> Some invoices are still unpaid: clear anyway, with a note on how they will be collected</label>
      <Field label="Note" id="cl-note" type="textarea" value={clear.note} onChange={v => setClear({ ...clear, note: v })} placeholder="e.g. Retention of GH₵124,000 due after the defects period; followed up monthly" />
    </FormModal>}
  </Panel>;
}

/** Engineering's progress reports to Finance, and project meetings. */
export function ProgressTab({ p, manage, milestones, onChange }: { p: any; manage: boolean; milestones: any[]; onChange: () => void }) {
  const { cid, can } = useSession();
  const act = useAction();
  const [form, setForm] = useState<any | null>(null);
  const [review, setReview] = useState<any | null>(null);
  const [meet, setMeet] = useState<any | null>(null);
  const [cert, setCert] = useState<any | null>(null);
  const { data, reload } = useLoad(async () => ({
    reports: await q<any[]>(supabase.from('progress_reports').select('*').eq('project_id', p.id).order('period_end', { ascending: false }) as any),
    meetings: await q<any[]>(supabase.from('project_meetings').select('*').eq('project_id', p.id).order('meeting_date', { ascending: false }) as any),
    team: await rpc<boolean>('on_project_team', { pid: p.id }).catch(() => false),
  }), [p.id]);
  if (!data) return null;
  const done = () => { reload(); onChange(); };
  const locked = ['closed', 'cancelled'].includes(p.status);
  const open = milestones.filter(m => m.status === 'planned');
  return <>
    <Panel title="Progress reports to Finance" actions={!locked && (data.team || manage) && <button className="btn small primary" type="button" onClick={() => setForm({ period_end: today(), pct_complete: String(p.percent_complete_override ?? ''), work_done: '', next_period: '', milestones_reached: '', upcoming_commitments: '', upcoming_commitments_value: '', issues: '' })}>New progress report</button>}>
      {data.reports.length ? <div className="scroll"><table>
        <thead><tr><th>Report</th><th className="r">Complete</th><th>Work done and milestones</th><th>Coming up</th><th>Status</th><th></th></tr></thead>
        <tbody>{data.reports.map(r => <tr key={r.id}><td className="num"><b>{r.number}</b><br /><span className="muted" style={{ fontSize: 12 }}>to {r.period_end}</span></td><td className="r num">{r.pct_complete}%</td>
          <td className="wrap-cell" style={{ fontSize: 13 }}>{r.work_done}{r.milestones_reached && <><br /><b>Milestones:</b> {r.milestones_reached}</>}{r.issues && <><br /><span style={{ color: 'var(--bad)' }}>{r.issues}</span></>}</td>
          <td className="wrap-cell" style={{ fontSize: 13 }}>{r.next_period}{r.upcoming_commitments && <><br /><b>Commitments:</b> {r.upcoming_commitments}{r.upcoming_commitments_value ? ` (${cedis(r.upcoming_commitments_value)})` : ''}</>}</td>
          <td><span className={'pill ' + (r.status === 'reviewed' ? 'good' : r.status === 'submitted' ? 'warn' : '')}>{r.status === 'submitted' ? 'With Finance' : r.status === 'reviewed' ? 'Read by Finance' : 'Draft'}</span>
            {r.finance_note && <><br /><span className="muted" style={{ fontSize: 12 }}>{r.finance_note}</span></>}</td>
          <td className="r"><span className="actions" style={{ justifyContent: 'flex-end' }}>
            {r.status === 'draft' && (data.team || manage) && <button className="btn small primary" type="button" onClick={() => act.run(async () => { await rpc('submit_progress_report', { p_id: r.id }); done(); }, 'Sent to Finance')}>Submit</button>}
            {r.status === 'draft' && (data.team || manage) && <button className="btn small ghost" type="button" onClick={() => act.run(async () => { await q(supabase.from('progress_reports').delete().eq('id', r.id) as any); done(); })}>Delete</button>}
            {r.status === 'submitted' && can('accountant') && <button className="btn small" type="button" onClick={() => setReview({ id: r.id, note: '' })}>Mark read</button>}</span></td></tr>)}</tbody>
      </table></div> : <Empty>No progress reports yet. Engineering reports {p.report_frequency || 'monthly'}: work done, milestones reached, and purchases or commitments coming up, so Finance can plan cash and invoices.</Empty>}
    </Panel>
    {open.length > 0 && manage && !locked && <Panel title="Certify a milestone"><div className="scroll"><table><tbody>{open.map(m => <tr key={m.id}><td>{m.name}</td><td className="num">{m.due_date || ''}</td><td className="r num">{p.currency} {money(m.amount)}</td>
      <td className="r"><button className="btn small primary" type="button" onClick={() => setCert({ id: m.id, name: m.name, note: '', report: data.reports[0]?.id || '' })}>Certify</button></td></tr>)}</tbody></table></div>
      <div className="body muted" style={{ fontSize: 13 }}>Certifying tells Finance the contractual condition is met; they invoice it without waiting to be reminded.</div></Panel>}
    <Panel title="Meetings" actions={!locked && <button className="btn small" type="button" onClick={() => setMeet({ kind: data.meetings.some(m => m.kind === 'post_award') ? 'progress' : 'post_award', meeting_date: today(), attendees: '', minutes: '', decisions: '', responsibilities: '' })}>Record meeting</button>}>
      {data.meetings.length ? <div className="scroll"><table><tbody>{data.meetings.map(m => <tr key={m.id}><td className="num" style={{ width: 110 }}>{m.meeting_date}</td>
        <td className="wrap-cell"><b>{({ post_award: 'Post-award meeting', progress: 'Progress meeting', management: 'Management meeting', other: 'Meeting' } as any)[m.kind]}</b> <span className="muted">{m.attendees}</span>
          {m.minutes && <><br />{m.minutes}</>}{m.decisions && <><br /><b>Decisions:</b> {m.decisions}</>}{m.responsibilities && <><br /><b>Roles:</b> {m.responsibilities}</>}</td></tr>)}</tbody></table></div>
        : <Empty>Start with the post-award meeting: how the project will be executed and the role of each unit at each stage.</Empty>}
    </Panel>
    {form && <FormModal title="Progress report" submit="Save draft" busy={act.busy} onClose={() => setForm(null)} onSave={() => act.run(async () => {
      await q(supabase.from('progress_reports').insert({ project_id: p.id, company_id: cid, period_end: form.period_end, pct_complete: Number(form.pct_complete) || 0, work_done: form.work_done, next_period: form.next_period || null,
        milestones_reached: form.milestones_reached || null, upcoming_commitments: form.upcoming_commitments || null, upcoming_commitments_value: form.upcoming_commitments_value ? Number(form.upcoming_commitments_value) : null, issues: form.issues || null }) as any);
      setForm(null); done(); }, 'Saved. Submit it to send it to Finance.')}>
      <div className="grid-form"><Field label="Period to" id="pg-end" type="date" value={form.period_end} onChange={v => setForm({ ...form, period_end: v })} required />
        <Field label="% complete" id="pg-pct" type="number" step="1" min="0" max="100" value={form.pct_complete} onChange={v => setForm({ ...form, pct_complete: v })} required /></div>
      <Field label="Work done this period" id="pg-done" type="textarea" value={form.work_done} onChange={v => setForm({ ...form, work_done: v })} />
      <Field label="Milestones reached" id="pg-ms" value={form.milestones_reached} onChange={v => setForm({ ...form, milestones_reached: v })} />
      <Field label="Planned for next period" id="pg-next" type="textarea" value={form.next_period} onChange={v => setForm({ ...form, next_period: v })} />
      <div className="grid-form"><Field label="Purchases and commitments coming up" id="pg-com" value={form.upcoming_commitments} onChange={v => setForm({ ...form, upcoming_commitments: v })} placeholder="e.g. Crane hire, cable delivery" />
        <Field label="About how much (GH₵)" id="pg-comv" type="number" step="0.01" min="0" value={form.upcoming_commitments_value} onChange={v => setForm({ ...form, upcoming_commitments_value: v })} /></div>
      <Field label="Issues and delays" id="pg-iss" value={form.issues} onChange={v => setForm({ ...form, issues: v })} />
    </FormModal>}
    {review && <FormModal title="Mark as read by Finance" busy={act.busy} onClose={() => setReview(null)} onSave={() => act.run(async () => { await rpc('review_progress_report', { p_id: review.id, p_note: review.note || null }); setReview(null); done(); })}>
      <Field label="Finance note (cash flow, invoicing)" id="pg-fn" value={review.note} onChange={v => setReview({ ...review, note: v })} />
    </FormModal>}
    {cert && <FormModal title={`Certify: ${cert.name}`} submit="Certify" busy={act.busy} onClose={() => setCert(null)} onSave={() => act.run(async () => { await rpc('certify_milestone', { p_id: cert.id, p_note: cert.note, p_report: cert.report || null }); setCert(null); done(); }, 'Certified; Finance has been notified to invoice it')}>
      <Field label="How it was met" id="ct-note" type="textarea" value={cert.note} onChange={v => setCert({ ...cert, note: v })} placeholder="e.g. Client's site engineer signed the completion certificate on 12 Dec" />
      {data.reports.length > 0 && <Select label="Progress report" id="ct-rep" value={cert.report} onChange={v => setCert({ ...cert, report: v })} options={[['', '—'], ...data.reports.map(r => [r.id, `${r.number} to ${r.period_end}`] as [string, string])]} />}
    </FormModal>}
    {meet && <MeetingForm meet={meet} setMeet={setMeet} target={{ project_id: p.id }} cid={cid} onDone={done} />}
  </>;
}

const PAY_STATUS: Record<string, [string, string]> = {
  to_invoice: ['To invoice', ''], invoice_late: ['Late to invoice', 'bad'], draft_invoice: ['Draft invoice', 'warn'],
  awaiting_payment: ['Awaiting payment', 'warn'], overdue: ['Payment overdue', 'bad'], paid: ['Paid', 'good'],
};
const KIND_LABEL: Record<string, string> = { advance: 'Advance', milestone: 'Milestone', valuation: 'Valuation', completion: 'Completion', retention: 'Retention', other: 'Other' };

/** The contract's payment terms and the payment schedule they produce. */
export function ContractPayments({ p, manage, onChange }: { p: any; manage: boolean; onChange: () => void }) {
  const { can } = useSession();
  const act = useAction();
  const [terms, setTerms] = useState<any | null>(null);
  const [line, setLine] = useState<any | null>(null);
  const canEdit = (manage || can('accountant', 'sales')) && !['closed', 'cancelled'].includes(p.status);
  const canInvoice = manage || can('accountant', 'sales');
  const { data, reload } = useLoad(() => rpc<any[]>('project_payment_status', { p_project: p.id }), [p.id]);
  if (p.is_template) return null;
  const done = () => { reload(); onChange(); };
  const rows = data || [];
  const sum = (f: (r: any) => boolean) => rows.filter(f).reduce((a, r) => a + Number(r.amount), 0);
  const hasTerms = p.payment_terms_days != null;
  return <Panel title="Contract payment terms and schedule" actions={canEdit && <>
    <button className="btn small" type="button" onClick={() => setTerms({ payment_terms_days: p.payment_terms_days ?? 30, advance_pct: p.advance_pct ?? 0, retention_pct: p.retention_pct ?? 0, retention_release_days: p.retention_release_days ?? 365,
      billing_basis: p.billing_basis || 'milestones', valuation_day: p.valuation_day ?? 25, reminder_days: p.reminder_days ?? 7, contract_date: p.contract_date || p.start_date || '', payment_terms_notes: p.payment_terms_notes || '' })}>{hasTerms ? 'Edit terms' : 'Set terms'}</button>
    {hasTerms && <button className="btn small primary" type="button" disabled={act.busy} onClick={() => act.run(async () => { const n = await rpc<number>('generate_payment_schedule', { p_project: p.id }); done(); return n; }, 'Schedule built from the terms (invoiced lines kept)')}>{rows.length ? 'Rebuild schedule' : 'Build schedule'}</button>}
    {hasTerms && <button className="btn small" type="button" onClick={() => setLine({ kind: 'other', description: '', amount: '', invoice_on: today(), notes: '' })}>Add payment</button>}</>}>
    <div className="body" style={{ display: 'grid', gap: 10 }}>
      {hasTerms ? <div className="grid-form" style={{ alignItems: 'start' }}>
        <div><div className="label">Client pays</div><b>{p.payment_terms_days} days</b> after invoice</div>
        <div><div className="label">Advance</div><b>{Number(p.advance_pct)}%</b>{p.contract_date ? ` on ${longDate(p.contract_date)}` : ''}</div>
        <div><div className="label">Retention</div><b>{Number(p.retention_pct)}%</b>{Number(p.retention_pct) > 0 ? `, released ${p.retention_release_days} days after completion` : ''}</div>
        <div><div className="label">Billing</div><b>{p.billing_basis === 'monthly' ? `Monthly valuations (day ${p.valuation_day || 25})` : p.billing_basis === 'on_completion' ? 'On completion' : 'By milestones'}</b></div>
        <div><div className="label">Reminders</div><b>{p.reminder_days} days</b> before each date</div>
      </div> : <div className="note" style={{ background: 'var(--warn-soft)' }}>No payment terms set for this contract. Set them so invoices get the right due date and Finance and the project manager are reminded when to invoice and when the client must pay.</div>}
      {p.payment_terms_notes && <div className="muted" style={{ fontSize: 13 }}>{p.payment_terms_notes}</div>}
    </div>
    {rows.length > 0 && <div className="scroll"><table>
      <thead><tr><th>Payment</th><th>Invoice on</th><th>Client pays by</th><th className="r">Amount ({p.currency})</th><th>Status</th><th></th></tr></thead>
      <tbody>{rows.map(r => <tr key={r.id}><td><span className="pill">{KIND_LABEL[r.kind]}</span> {r.description}</td>
        <td className="num" style={{ color: r.status === 'invoice_late' ? 'var(--bad)' : undefined }}>{r.invoice_on}</td>
        <td className="num" style={{ color: r.status === 'overdue' ? 'var(--bad)' : undefined }}>{r.due_on}</td>
        <td className="r num">{money(r.amount)}{r.outstanding != null && Number(r.outstanding) > 0 && r.status !== 'draft_invoice' && <><br /><span className="muted" style={{ fontSize: 12 }}>owing {money(r.outstanding)} incl. VAT</span></>}</td>
        <td><span className={'pill ' + PAY_STATUS[r.status][1]}>{PAY_STATUS[r.status][0]}</span>{r.invoice_number && <><br /><Link to={'/invoices/' + r.invoice_id} style={{ fontSize: 12 }}>{r.invoice_number}</Link></>}
          {r.status === 'draft_invoice' && <><br /><Link to={'/invoices/' + r.invoice_id + '/edit'} style={{ fontSize: 12 }}>Open draft</Link></>}</td>
        <td className="r"><span className="actions" style={{ justifyContent: 'flex-end' }}>
          {!r.invoice_id && canInvoice && <button className="btn small primary" type="button" disabled={act.busy} onClick={() => act.run(async () => { await rpc('invoice_schedule_item', { p_id: r.id }); done(); }, 'Draft invoice created with the contract due date')}>Invoice</button>}
          {!r.invoice_id && canEdit && <button className="btn small ghost" type="button" onClick={() => setLine({ ...r, amount: String(r.amount), notes: '' })}>Edit</button>}</span></td></tr>)}</tbody>
      <tfoot><tr><td colSpan={3}>Scheduled {sum(() => true) !== Number(p.contract_value) && Number(p.contract_value) > 0 ? <span className="muted">(contract {money(p.contract_value)})</span> : ''}</td>
        <td className="r num">{money(sum(() => true))}</td><td colSpan={2} className="muted" style={{ fontSize: 12 }}>Paid {money(sum(r => r.status === 'paid'))} · to invoice {money(sum(r => !r.invoice_id))}</td></tr></tfoot>
    </table></div>}
    <div className="body muted" style={{ fontSize: 13 }}>Invoices on this project are due {hasTerms ? `${p.payment_terms_days} days` : 'by the default 30 days'} after their date. Finance and the project manager get a notification {p.reminder_days ?? 7} days before each invoice should be raised and before each payment is due, and again if either date is missed. Advances are not netted off later payments automatically; add a deduction line on the invoice where the contract requires it.</div>

    {terms && <FormModal title="Contract payment terms" busy={act.busy} onClose={() => setTerms(null)} onSave={() => act.run(async () => {
      await q(supabase.from('projects').update({ payment_terms_days: Number(terms.payment_terms_days), advance_pct: Number(terms.advance_pct) || 0, retention_pct: Number(terms.retention_pct) || 0,
        retention_release_days: Number(terms.retention_release_days) || 0, billing_basis: terms.billing_basis, valuation_day: terms.billing_basis === 'monthly' ? Number(terms.valuation_day) || 25 : null,
        reminder_days: Number(terms.reminder_days) || 0, contract_date: terms.contract_date || null, payment_terms_notes: terms.payment_terms_notes || null }).eq('id', p.id) as any);
      setTerms(null); done(); }, 'Terms saved. Build or rebuild the schedule to apply them.')}>
      <div className="grid-form">
        <Field label="Client pays within (days of invoice)" id="ct-days" type="number" step="1" min="0" max="365" value={terms.payment_terms_days} onChange={v => setTerms({ ...terms, payment_terms_days: v })} required />
        <Field label="Contract signed" id="ct-date" type="date" value={terms.contract_date} onChange={v => setTerms({ ...terms, contract_date: v })} />
        <Field label="Advance payment %" id="ct-adv" type="number" step="0.01" min="0" max="100" value={terms.advance_pct} onChange={v => setTerms({ ...terms, advance_pct: v })} />
        <Field label="Retention %" id="ct-ret" type="number" step="0.01" min="0" max="50" value={terms.retention_pct} onChange={v => setTerms({ ...terms, retention_pct: v })} />
        <Field label="Retention released after completion (days)" id="ct-rel" type="number" step="1" min="0" value={terms.retention_release_days} onChange={v => setTerms({ ...terms, retention_release_days: v })} />
        <Select label="Billing" id="ct-basis" value={terms.billing_basis} onChange={v => setTerms({ ...terms, billing_basis: v })} options={[['milestones', 'By milestones'], ['monthly', 'Monthly valuations'], ['on_completion', 'On completion']]} />
        {terms.billing_basis === 'monthly' && <Field label="Valuation day of the month" id="ct-vday" type="number" step="1" min="1" max="28" value={terms.valuation_day} onChange={v => setTerms({ ...terms, valuation_day: v })} />}
        <Field label="Remind this many days before" id="ct-rem" type="number" step="1" min="0" max="60" value={terms.reminder_days} onChange={v => setTerms({ ...terms, reminder_days: v })} />
      </div>
      <Field label="Other terms (as in the contract)" id="ct-notes" type="textarea" value={terms.payment_terms_notes} onChange={v => setTerms({ ...terms, payment_terms_notes: v })} placeholder="e.g. Interim certificates paid within 45 days; 2% late payment interest per month" />
      <p className="muted" style={{ margin: 0, fontSize: 13 }}>Contract value {p.currency} {money(p.contract_value)}. Milestones come from the Billing tab; monthly valuations split the balance evenly between the start and end dates.</p>
    </FormModal>}
    {line && <FormModal title={line.id ? 'Edit scheduled payment' : 'Add a scheduled payment'} busy={act.busy} onClose={() => setLine(null)} onSave={() => act.run(async () => {
      const row = { kind: line.kind, description: line.description, amount: Number(line.amount) || 0, invoice_on: line.invoice_on, ...(line.id ? {} : { due_on: null }) };
      if (line.id) await q(supabase.from('project_payment_schedule').update(row).eq('id', line.id) as any);
      else await q(supabase.from('project_payment_schedule').insert({ ...row, project_id: p.id, company_id: p.company_id, seq: 80 }) as any);
      setLine(null); done(); }, 'Saved')}
      danger={line.id && <button className="btn danger" type="button" onClick={() => act.run(async () => { await q(supabase.from('project_payment_schedule').delete().eq('id', line.id) as any); setLine(null); done(); })}>Remove</button>}>
      <div className="grid-form">
        <Select label="Type" id="pl-kind" value={line.kind} onChange={v => setLine({ ...line, kind: v })} options={Object.entries(KIND_LABEL) as [string, string][]} />
        <Field label={`Amount (${p.currency}, excl. VAT)`} id="pl-amt" type="number" step="0.01" min="0" value={line.amount} onChange={v => setLine({ ...line, amount: v })} required />
        <Field label="Invoice on" id="pl-on" type="date" value={line.invoice_on} onChange={v => setLine({ ...line, invoice_on: v })} required />
      </div>
      <Field label="Description" id="pl-desc" value={line.description} onChange={v => setLine({ ...line, description: v })} required />
      <p className="muted" style={{ margin: 0, fontSize: 13 }}>The client's due date is set from the contract terms ({p.payment_terms_days ?? 30} days after the invoice).</p>
    </FormModal>}
  </Panel>;
}
