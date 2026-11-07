import { useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { q, rpc, supabase } from '../lib/supabase';
import { useSession } from '../lib/session';
import { longDate, money, qty, today } from '../lib/format';
import { Empty, Field, FormModal, Panel, useAction, useLoad } from './ui';
import { StockIssueForm } from '../pages/Inventory';
import { PoStatus } from '../pages/Purchasing';

export const STAGES: [string, string, string][] = [['planned', 'Not started', ''], ['active', 'In progress', 'good'], ['on_hold', 'On hold', 'warn'], ['done', 'Completed', 'good'], ['closed', 'Closed', ''], ['cancelled', 'Cancelled', 'bad']];
export const Stage = ({ s }: { s: string }) => { const x = STAGES.find(v => v[0] === s); return <span className={'pill ' + (x?.[2] || '')}>{x?.[1] || s}</span>; };

const days = (a: string, b: string) => Math.round((Date.parse(b) - Date.parse(a)) / 864e5);

/** Where the project should be by today (from its dates) against where it is (% complete). */
export function schedule(p: { status: string; start_date?: string | null; end_date?: string | null; actual_start?: string | null; actual_end?: string | null }, pct: number) {
  const start = p.actual_start || p.start_date, end = p.end_date, t = today();
  if (!start || !end || end <= start) return null;
  const span = days(start, end);
  if (['done', 'closed'].includes(p.status)) {
    const fin = p.actual_end || t, late = days(end, fin);
    return { planned: 100, actual: 100, label: late > 0 ? `Finished ${late} day${late === 1 ? '' : 's'} late` : late < 0 ? `Finished ${-late} day${late === -1 ? '' : 's'} early` : 'Finished on time', tone: late > 0 ? 'warn' : 'good' };
  }
  if (p.status === 'cancelled') return null;
  if (p.status === 'planned') {
    const d = days(t, p.start_date || start);
    return { planned: 0, actual: pct, label: d > 0 ? `Starts in ${d} day${d === 1 ? '' : 's'}` : `Should have started ${-d} day${d === -1 ? '' : 's'} ago`, tone: d >= 0 ? '' : 'bad' };
  }
  const planned = Math.max(0, Math.min(100, Math.round(days(start, t) / span * 100)));
  if (t > end) { const d = days(end, t); return { planned: 100, actual: pct, label: `Past its end date by ${d} day${d === 1 ? '' : 's'}`, tone: 'bad' }; }
  const behind = Math.round((planned - pct) / 100 * span);
  return { planned, actual: pct, label: behind > 2 ? `Behind by about ${behind} days` : behind < -2 ? `Ahead by about ${-behind} days` : 'On schedule', tone: behind > Math.max(5, span * 0.1) ? 'bad' : behind > 2 ? 'warn' : 'good' };
}

export function ScheduleBar({ planned, actual }: { planned: number; actual: number }) {
  return <div style={{ position: 'relative', height: 10, background: 'var(--sunk)', borderRadius: 5, minWidth: 90 }} title={`Should be ${planned}% done by today, is ${actual}%`}>
    <div style={{ width: Math.min(actual, 100) + '%', height: '100%', borderRadius: 5, background: actual + 2 >= planned ? 'var(--good)' : actual + 10 >= planned ? 'var(--warn)' : 'var(--bad)' }} />
    <div style={{ position: 'absolute', left: `calc(${Math.min(planned, 100)}% - 1px)`, top: -3, width: 2, height: 16, background: 'var(--fg)' }} />
  </div>;
}

type Action = { key: string; label: string; primary?: boolean; note?: 'required' | 'optional'; date?: boolean; acctOnly?: boolean };
const ACTIONS: Record<string, Action[]> = {
  planned: [{ key: 'start', label: 'Start project', primary: true, date: true }, { key: 'cancel', label: 'Cancel project', note: 'required' }],
  active: [{ key: 'complete', label: 'Mark work complete', primary: true, date: true, note: 'optional' }, { key: 'hold', label: 'Put on hold', note: 'required' }, { key: 'cancel', label: 'Cancel', note: 'required' }],
  on_hold: [{ key: 'resume', label: 'Resume work', primary: true, note: 'optional' }, { key: 'complete', label: 'Mark work complete', date: true, note: 'optional' }, { key: 'cancel', label: 'Cancel', note: 'required' }],
  done: [{ key: 'close', label: 'Close project', primary: true, note: 'optional' }, { key: 'resume_work', label: 'More work needed', note: 'optional' }],
  closed: [{ key: 'reopen', label: 'Reopen', note: 'required', acctOnly: true }],
  cancelled: [{ key: 'reopen', label: 'Reopen', note: 'required', acctOnly: true }],
};
const DONE_MSG: Record<string, string> = { start: 'Project started', hold: 'Project on hold', resume: 'Work resumed', complete: 'Work marked complete. Close the project once everything is billed and paid for.', resume_work: 'Back in progress', close: 'Project closed. Nothing more can be booked to it.', reopen: 'Project reopened', cancel: 'Project cancelled' };

/** Stage, schedule, start/hold/complete/close actions, close-out checklist and status history for one project. */
export function ProjectLifecycle({ p, k, manage, onChange }: { p: any; k: any; manage: boolean; onChange: () => void }) {
  const { can } = useSession();
  const act = useAction();
  const acct = can('accountant');
  const [doing, setDoing] = useState<{ a: Action; note: string; date: string; force: boolean } | null>(null);
  const [history, setHistory] = useState(false);
  const { data, reload } = useLoad(async () => {
    const [check, log, docs] = await Promise.all([
      ['done', 'active', 'on_hold'].includes(p.status) ? rpc<any[]>('project_close_check', { p_project: p.id }) : Promise.resolve([] as any[]),
      q<any[]>(supabase.from('project_status_log').select('*').eq('project_id', p.id).order('changed_at', { ascending: false }) as any),
      p.status === 'planned' ? rpc<any[]>('project_doc_check', { p_project: p.id }).catch(() => [] as any[]) : Promise.resolve([] as any[]),
    ]);
    return { check, log, docs };
  }, [p.id, p.status]);
  const pct = Number(k?.pct_complete || 0);
  const sch = schedule(p, pct);
  const blocks = (data?.check || []).filter(c => c.severity === 'block');
  const warns = (data?.check || []).filter(c => c.severity === 'warn');
  const steps = ['planned', 'active', 'done', 'closed'];
  const idx = p.status === 'on_hold' ? 1 : p.status === 'cancelled' ? -1 : steps.indexOf(p.status);
  const actions = (ACTIONS[p.status] || []).filter(a => (manage || acct) && (!a.acctOnly || acct));

  return <Panel title={<div className="actions"><h2>Project stage</h2><Stage s={p.status} /></div>}
    actions={<>{actions.map(a => <button key={a.key} type="button" className={'btn small' + (a.primary ? ' primary' : '')} onClick={() => setDoing({ a, note: '', date: today(), force: false })}>{a.label}</button>)}
      <button type="button" className="btn small ghost" onClick={() => setHistory(!history)}>{history ? 'Hide history' : 'History'}</button></>}>
    <div className="body" style={{ display: 'grid', gap: 14 }}>
      <ol className="stepper" aria-label="Project stages">
        {steps.map((s, i) => <li key={s} className={i < idx ? 'done' : i === idx ? 'now' : ''}><span>{i + 1}</span>{p.status === 'on_hold' && s === 'active' ? 'On hold' : STAGES.find(x => x[0] === s)?.[1]}</li>)}
      </ol>
      <div className="grid-form" style={{ alignItems: 'center' }}>
        <div><div className="label">Planned</div><span className="num">{longDate(p.start_date) || '—'} → {longDate(p.end_date) || '—'}</span></div>
        <div><div className="label">Actual</div><span className="num">{p.actual_start ? longDate(p.actual_start) : 'Not started'}{p.actual_start ? ' → ' + (p.actual_end ? longDate(p.actual_end) : 'in progress') : ''}</span></div>
        {sch ? <div><div className="label">Schedule: <span className={'pill ' + sch.tone}>{sch.label}</span></div><ScheduleBar planned={sch.planned} actual={sch.actual} />
          <span className="muted" style={{ fontSize: 12 }}>{['done', 'closed'].includes(p.status) ? `Target end ${longDate(p.end_date)}` : `${pct}% complete; should be ${sch.planned}% by today`}</span></div>
          : <div className="muted" style={{ fontSize: 13 }}>Set a start and target end date to track the schedule.</div>}
      </div>
      {p.status === 'done' && data && <div className="note" style={{ background: blocks.length ? 'var(--warn-soft)' : 'var(--good-soft)' }}>
        {blocks.length ? <>Before closing: {blocks.map(b => b.item.toLowerCase() + ` (${b.n})`).join('; ')}.</> : <>Ready to close.{warns.length ? ' Worth checking: ' + warns.map(w => w.item.toLowerCase() + ` (${w.n})`).join('; ') + '.' : ''}</>}</div>}
      {p.status === 'closed' && <div className="note">Closed {p.closed_at ? longDate(p.closed_at) : ''}{p.close_notes ? ': ' + p.close_notes : ''}. Time, expenses, purchases and materials can no longer be booked to it.</div>}
      {history && data && (data.log.length ? <table><tbody>{data.log.map(l => <tr key={l.id}><td className="num" style={{ width: 150 }}>{l.changed_at.slice(0, 16).replace('T', ' ')}</td>
        <td>{l.from_status ? <><Stage s={l.from_status} /> → </> : ''}<Stage s={l.to_status} /></td><td className="wrap-cell">{l.note}</td><td className="muted">{(l.changed_email || '').split('@')[0]}</td></tr>)}</tbody></table>
        : <Empty>No stage changes recorded yet.</Empty>)}
    </div>

    {doing && <FormModal title={doing.a.label} submit={doing.a.label} busy={act.busy} onClose={() => setDoing(null)}
      onSave={() => act.run(async () => {
        await rpc('set_project_status', { p_project: p.id, p_action: doing.a.key, p_note: doing.note || null, p_date: doing.date, p_force: doing.force });
        setDoing(null); reload(); onChange();
      }, DONE_MSG[doing.a.key])}>
      {doing.a.key === 'close' && data && <>
        <p style={{ margin: 0 }}>Closing locks the project: no more time, expenses, purchase requests, orders or materials. Its figures stay in every report. An accountant can reopen it.</p>
        {data.check.length ? <table><tbody>{data.check.map(c => <tr key={c.item}>
          <td><span className={'pill ' + (c.severity === 'block' ? 'bad' : 'warn')}>{c.severity === 'block' ? 'Must clear' : 'Check'}</span></td>
          <td>{c.item} <b className="num">({c.n})</b>{c.amount != null && Number(c.amount) ? <span className="muted num"> · {money(c.amount)}</span> : ''}<br /><span className="muted" style={{ fontSize: 12 }}>{c.hint}</span></td></tr>)}</tbody></table>
          : <div className="note" style={{ background: 'var(--good-soft)' }}>Everything is approved, billed and paid. Nothing is outstanding.</div>}
        {blocks.length > 0 && acct && <label className="check"><input type="checkbox" checked={doing.force} onChange={e => setDoing({ ...doing, force: e.target.checked })} /> Close anyway (accountant). I have a reason, written below.</label>}
      </>}
      {doing.a.key === 'complete' && data && data.check.some(c => c.item === 'Tasks not finished') && <p className="muted" style={{ margin: 0 }}>Some tasks are not marked done. Completing the project sets it to 100%.</p>}
      {doing.a.key === 'start' && <p className="muted" style={{ margin: 0 }}>The actual start date is recorded and the schedule is tracked from it.</p>}
      {doing.a.key === 'start' && data && data.docs.some(d => d.stage === 'start' && !d.satisfied) && <div className="note" style={{ background: 'var(--warn-soft)' }}>
        Not yet approved before start: {data.docs.filter(d => d.stage === 'start' && !d.satisfied).map(d => d.name).join(', ')}. You can still start, but work should not begin without them.</div>}
      {doing.a.date && <Field label={doing.a.key === 'start' ? 'Actual start date' : 'Date the work finished'} id="lc-date" type="date" value={doing.date} onChange={v => setDoing({ ...doing, date: v })} required />}
      {doing.a.note && <Field label={doing.a.note === 'required' || doing.force ? 'Reason (required)' : 'Note (optional)'} id="lc-note" type="textarea" value={doing.note} onChange={v => setDoing({ ...doing, note: v })}
        placeholder={doing.a.key === 'hold' ? 'e.g. Waiting for the client\'s drawings' : doing.a.key === 'close' ? 'e.g. Handed over and signed off by the client' : ''} />}
    </FormModal>}
  </Panel>;
}

/** Materials on a project: from the store (issues and returns) and ordered from suppliers for delivery to site. */
export function ProjectMaterials({ p, manage, onChange }: { p: any; manage: boolean; onChange: () => void }) {
  const { can } = useSession();
  const nav = useNavigate();
  const [form, setForm] = useState<'issue' | 'return' | null>(null);
  const locked = ['closed', 'cancelled'].includes(p.status);
  const canIssue = !locked && (manage || can('accountant', 'store'));
  const { data, reload } = useLoad(async () => {
    const [issues, poLines] = await Promise.all([
      q<any[]>(supabase.from('stock_issues').select('id,number,kind,issue_date,status,issued_to, warehouse:warehouses(code), lines:stock_issue_lines(qty,unit_cost,billable,bill_price,invoice_id, product:products(name,unit))').eq('project_id', p.id).order('issue_date', { ascending: false }) as any),
      q<any[]>(supabase.from('po_lines').select('description,qty,received_qty,unit_cost, po:purchase_orders(id,number,status,expected_date, supplier:suppliers(name))').eq('project_id', p.id) as any),
    ]);
    return { issues, poLines };
  }, [p.id]);
  if (!data) return null;
  // Net quantity and cost by item (issues less returns)
  const net: Record<string, { name: string; unit: string; q: number; cost: number; billQ: number; billV: number; invoiced: number }> = {};
  for (const s of data.issues.filter(x => x.status === 'posted')) for (const l of s.lines) {
    const k = l.product?.name || '?', sign = s.kind === 'issue' ? 1 : -1;
    net[k] ??= { name: k, unit: l.product?.unit || '', q: 0, cost: 0, billQ: 0, billV: 0, invoiced: 0 };
    net[k].q += sign * Number(l.qty); net[k].cost += sign * Number(l.qty) * Number(l.unit_cost || 0);
    if (l.billable) { net[k].billQ += sign * Number(l.qty); net[k].billV += sign * Number(l.qty) * Number(l.bill_price || 0); if (l.invoice_id) net[k].invoiced += sign * Number(l.qty); }
  }
  const rows = Object.values(net).filter(r => r.q !== 0 || r.cost !== 0);
  const totalCost = rows.reduce((a, r) => a + r.cost, 0), totalBill = rows.reduce((a, r) => a + r.billV, 0);
  const pos = Object.values(Object.fromEntries(data.poLines.filter(l => l.po && l.po.status !== 'cancelled').map(l => [l.po.id, l.po]))) as any[];
  return <>
    <div className="tiles">
      <div className="tile"><span>Materials used (at cost)</span><b>{money(totalCost)}</b></div>
      <div className="tile"><span>To bill the client</span><b>{money(totalBill)}</b></div>
      <div className="tile"><span>On order for this project</span><b>{money(data.poLines.filter(l => l.po && ['approved', 'sent', 'partial'].includes(l.po.status)).reduce((a, l) => a + (Number(l.qty) - Number(l.received_qty)) * Number(l.unit_cost), 0))}</b></div>
    </div>
    <Panel title="Issued from stores and returned" actions={<>
      {canIssue && <button className="btn small" type="button" onClick={() => setForm('return')}>Return to store</button>}
      {canIssue && <button className="btn small primary" type="button" onClick={() => setForm('issue')}>Issue from store</button>}</>}>
      {rows.length ? <div className="scroll"><table>
        <thead><tr><th>Item</th><th className="r">Net quantity</th><th className="r">Cost (GH₵)</th><th className="r">Billable qty</th><th className="r">Invoiced</th><th className="r">Billable value ({p.currency})</th></tr></thead>
        <tbody>{rows.map(r => <tr key={r.name}><td>{r.name}</td><td className="r num">{qty(r.q)} {r.unit}</td><td className="r num">{money(r.cost)}</td><td className="r num">{r.billQ ? qty(r.billQ) : ''}</td>
          <td className="r num">{r.invoiced ? qty(r.invoiced) : ''}</td><td className="r num">{r.billV ? money(r.billV) : ''}</td></tr>)}</tbody>
        <tfoot><tr><td colSpan={2}>Total</td><td className="r num">{money(totalCost)}</td><td colSpan={2}></td><td className="r num">{money(totalBill)}</td></tr></tfoot>
      </table></div> : <Empty>No materials issued from the store yet.</Empty>}
      {data.issues.length > 0 && <div className="scroll" style={{ borderTop: '1px solid var(--line)' }}><table><tbody>{data.issues.map(s => <tr key={s.id} className="click" onClick={() => nav('/inventory/issues/' + s.id)}>
        <td className="num">{s.number}{s.kind === 'return' && <span className="pill warn" style={{ marginLeft: 6 }}>Return</span>}{s.status === 'draft' && <span className="pill" style={{ marginLeft: 6 }}>Draft</span>}</td>
        <td className="num">{s.issue_date}</td><td>{s.warehouse?.code}</td><td className="wrap-cell">{s.lines.map((l: any) => `${qty(l.qty)} ${l.product?.unit} ${l.product?.name}`).join(', ')}</td><td className="muted">{s.issued_to}</td></tr>)}</tbody></table></div>}
    </Panel>
    <Panel title="Ordered from suppliers for this project" actions={!locked && can('accountant', 'store', 'project_manager') && <Link className="btn small primary" to={`/purchase-orders/new?project=${p.id}`}>Order for delivery to site</Link>}>
      {pos.length ? <div className="scroll"><table>
        <thead><tr><th>Order</th><th>Supplier</th><th>What</th><th>Expected</th><th>Status</th></tr></thead>
        <tbody>{pos.map(o => { const ls = data.poLines.filter(l => l.po?.id === o.id); return <tr key={o.id} className="click" onClick={() => nav('/purchase-orders/' + o.id)}>
          <td className="num">{o.number}</td><td>{o.supplier?.name}</td><td className="wrap-cell">{ls.map(l => `${l.description} (${qty(l.received_qty)}/${qty(l.qty)} delivered)`).join('; ')}</td>
          <td className="num">{o.expected_date || ''}</td><td><PoStatus s={o.status} /></td></tr>; })}</tbody>
      </table></div> : <Empty>Nothing ordered for this project. Approved purchase requests can be turned into an order on the Purchases tab, or order directly here.</Empty>}
      <div className="body muted" style={{ fontSize: 13 }}>Materials from your own store are charged to the project when issued. Goods ordered for delivery to site are charged when the delivery is received. Both are tagged to the project in the ledger and show in the cost report.</div>
    </Panel>
    {form && <StockIssueForm kind={form} projectId={p.id} onClose={() => setForm(null)} onDone={() => { setForm(null); reload(); onChange(); }} />}
  </>;
}
