import { useState } from 'react';
import { Link } from 'react-router-dom';
import { q, rpc, supabase } from '../lib/supabase';
import { useSession } from '../lib/session';
import { money, today } from '../lib/format';
import { downloadCsv } from '../lib/download';
import { tablePdf } from '../lib/pdf';
import { receiptUrl } from '../lib/receipt';
import { Downloads, Empty, Field, FormModal, Loading, PageHead, Panel, Select, useAction, useLoad } from '../components/ui';

export function ApprovalsPage() {
  const { cid, company, can, role, session } = useSession();
  const pmOnly = role === 'project_manager';
  const act = useAction();
  const [ticked, setTicked] = useState<Set<string>>(new Set());
  const [reject, setReject] = useState<any | null>(null);
  const [pay, setPay] = useState<any | null>(null);
  const { data, error, loading, reload } = useLoad(async () => {
    const [time, expenses, approved, names] = await Promise.all([
      q<any[]>(supabase.from('timesheets').select('*, project:projects(name,manager_id)').eq('company_id', cid).eq('status', 'submitted').order('work_date') as any),
      q<any[]>(supabase.from('expense_claims').select('*, project:projects(name,manager_id), account:accounts(name)').eq('company_id', cid).eq('status', 'submitted').order('expense_date') as any),
      q<any[]>(supabase.from('expense_claims').select('employee_id, amount_home').eq('company_id', cid).eq('status', 'approved') as any),
      rpc<any[]>('group_employee_names', { cid }),
    ]);
    if (pmOnly) {   // project managers approve only for the projects they run
      const mineOnly = (r: any) => r.project?.manager_id === session?.user.id;
      time.splice(0, time.length, ...time.filter(mineOnly)); expenses.splice(0, expenses.length, ...expenses.filter(mineOnly));
    }
    const nm = (id: string) => names.find(n => n.id === id)?.full_name || 'Unknown';
    time.forEach(t => { t.emp = { full_name: nm(t.employee_id) }; });
    expenses.forEach(x => { x.emp = { full_name: nm(x.employee_id) }; });
    const owed: Record<string, { name: string; total: number; n: number }> = {};
    approved.forEach(a => { owed[a.employee_id] = owed[a.employee_id] || { name: nm(a.employee_id), total: 0, n: 0 }; owed[a.employee_id].total += Number(a.amount_home); owed[a.employee_id].n++; });
    return { time, expenses, owed };
  }, [cid]);
  const toggle = (id: string) => { const n = new Set(ticked); n.has(id) ? n.delete(id) : n.add(id); setTicked(n); };
  const decideTime = (ok: boolean) => act.run(async () => { await rpc('decide_time', { p_ids: [...ticked], p_approve: ok }); setTicked(new Set()); reload(); }, ok ? 'Hours approved' : 'Hours rejected');
  const approveExp = (id: string) => act.run(async () => { await rpc('decide_expense', { p_id: id, p_approve: true, p_reason: null }); reload(); }, 'Expense approved');
  const openReceipt = (path: string) => act.run(async () => { const url = await receiptUrl(path); window.open(url, '_blank', 'noopener'); });

  const head = ['Date', 'Employee', 'Project', 'Description', 'Currency', 'Amount', 'GHS', 'Billable'];
  const rows = (data?.expenses || []).map(x => [x.expense_date, x.emp?.full_name, x.project?.name || '', x.description, x.currency, money(x.amount), money(x.amount_home), x.billable ? 'Yes' : 'No']);

  return <>
    <PageHead title="Approvals" sub="Hours and expenses sent in by staff, including people from other companies in your group working on your projects.">
      <Downloads pdf={() => tablePdf({ company: company!, title: 'Expenses awaiting approval', subtitle: today(), head, body: rows, rightAlign: [5, 6], landscape: true, filename: 'expenses-pending' })} csv={() => downloadCsv('expenses-pending', head, rows)} />
    </PageHead>
    <Loading error={error} loading={loading && !data} />
    {data && <>
      <Panel title={`Hours (${data.time.length})`} actions={data.time.length > 0 && <>
        <button className="btn small" type="button" onClick={() => setTicked(new Set(data.time.map(t => t.id)))}>Tick all</button>
        <button className="btn small danger" type="button" disabled={!ticked.size || act.busy} onClick={() => decideTime(false)}>Reject</button>
        <button className="btn small primary" type="button" disabled={!ticked.size || act.busy} onClick={() => decideTime(true)}>Approve {ticked.size || ''}</button></>}>
        {data.time.length ? <div className="scroll"><table>
          <thead><tr><th></th><th>Date</th><th>Employee</th><th>Project</th><th className="r">Hours</th><th>Billable</th></tr></thead>
          <tbody>{data.time.map(t => <tr key={t.id} className="click" onClick={() => toggle(t.id)}>
            <td><input type="checkbox" aria-label="Select" checked={ticked.has(t.id)} onChange={() => toggle(t.id)} onClick={e => e.stopPropagation()} /></td>
            <td className="num">{t.work_date}</td><td>{t.emp?.full_name || '(other company)'}</td><td className="wrap-cell">{t.project?.name}{t.note && <><br /><span className="muted">{t.note}</span></>}</td>
            <td className="r num">{t.hours}</td><td>{t.billable ? 'Yes' : 'No'}</td></tr>)}</tbody>
        </table></div> : <Empty>No hours waiting.</Empty>}
      </Panel>

      <Panel title={`Expenses (${data.expenses.length})`}>{data.expenses.length ? <div className="scroll"><table>
        <thead><tr><th>Date</th><th>Employee</th><th>What</th><th className="r">Amount</th><th>Receipt</th><th></th></tr></thead>
        <tbody>{data.expenses.map(x => <tr key={x.id}>
          <td className="num">{x.expense_date}</td><td>{x.emp?.full_name}</td>
          <td className="wrap-cell">{x.description}<br /><span className="muted">{[x.project?.name, x.account?.name, x.merchant, x.billable && 'Re-bill to client'].filter(Boolean).join(' · ')}</span></td>
          <td className="r num">{x.currency} {money(x.amount)}{x.currency !== 'GHS' && <><br /><span className="muted">GH₵ {money(x.amount_home)} @ {x.exchange_rate}</span></>}</td>
          <td>{x.receipt_path ? <button className="btn small" type="button" onClick={() => openReceipt(x.receipt_path)}>View</button> : <span className="pill warn">None</span>}</td>
          <td className="r">{x.first_approved_by ? <Link className="pill warn" to="/approvals-inbox">In finance approval</Link> : (can('accountant') || x.project?.manager_id === session?.user.id) && <span className="actions" style={{ justifyContent: 'flex-end' }}>
            <button className="btn small danger" type="button" onClick={() => setReject({ id: x.id, reason: '' })}>Reject</button>
            <button className="btn small primary" type="button" disabled={act.busy} onClick={() => approveExp(x.id)}>Approve</button></span>}</td></tr>)}</tbody>
      </table></div> : <Empty>No expenses waiting.</Empty>}</Panel>

      <Panel title="Approved, to reimburse">{Object.keys(data.owed).length ? <div className="scroll"><table>
        <thead><tr><th>Employee</th><th className="r">Claims</th><th className="r">Owed (GH₵)</th><th></th></tr></thead>
        <tbody>{Object.entries(data.owed).map(([id, o]) => <tr key={id}><td>{o.name}</td><td className="r num">{o.n}</td><td className="r num">{money(o.total)}</td>
          <td className="r">{can('accountant') && <button className="btn small primary" type="button" onClick={() => setPay({ id, name: o.name, total: o.total, method: 'momo', date: today() })}>Reimburse</button>}</td></tr>)}</tbody>
      </table></div> : <Empty>Nothing to reimburse.</Empty>}</Panel>
    </>}
    {reject && <FormModal title="Reject expense" submit="Reject" busy={act.busy} onClose={() => setReject(null)}
      onSave={() => act.run(async () => { await rpc('decide_expense', { p_id: reject.id, p_approve: false, p_reason: reject.reason || null }); setReject(null); reload(); }, 'Expense rejected')}>
      <Field label="Reason (the employee sees this)" id="rj-reason" value={reject.reason} onChange={v => setReject({ ...reject, reason: v })} placeholder="e.g. Please attach the receipt" required />
    </FormModal>}
    {pay && <FormModal title={`Reimburse ${pay.name}`} submit={`Pay GH₵ ${money(pay.total)}`} busy={act.busy} onClose={() => setPay(null)}
      onSave={() => act.run(async () => { await rpc('reimburse_employee', { cid, p_employee: pay.id, p_method: pay.method, p_date: pay.date }); setPay(null); reload(); }, 'Reimbursement posted')}>
      <div className="grid-form">
        <Select label="Paid from" id="rb-m" value={pay.method} onChange={v => setPay({ ...pay, method: v })} options={[['momo', 'Mobile Money'], ['bank', 'Bank'], ['cash', 'Cash']]} />
        <Field label="Date" id="rb-date" type="date" value={pay.date} onChange={v => setPay({ ...pay, date: v })} required />
      </div>
    </FormModal>}
  </>;
}
