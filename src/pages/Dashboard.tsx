import { Link, useNavigate } from 'react-router-dom';
import { q, rpc, supabase } from '../lib/supabase';
import { useSession } from '../lib/session';
import { cedis, longDate, money, monthStart, qty, today } from '../lib/format';
import { Empty, Loading, PageHead, Panel, Status, useLoad } from '../components/ui';

export function Dashboard({ embedded = false }: { embedded?: boolean } = {}) {
  const { cid, company, can } = useSession();
  const nav = useNavigate();
  const { data, error, loading } = useLoad(async () => {
    if (can('sales', 'accountant')) { try { await rpc('run_recurring', { cid }); } catch { /* shown on the Recurring page */ } }
    const [invoices, products, bills] = await Promise.all([
      q<any[]>(supabase.from('invoices').select('id,number,invoice_date,due_date,status,subtotal,total,amount_paid,amount_credited,currency,exchange_rate,customer:customers(name)').eq('company_id', cid).order('created_at', { ascending: false }).limit(200) as any),
      q<any[]>(supabase.from('products').select('id,name,stock_qty,reorder_level,cost,unit').eq('company_id', cid).eq('active', true).eq('item_type', 'stock') as any),
      can('accountant') ? q<any[]>(supabase.from('bills').select('total,amount_paid,status,exchange_rate').eq('company_id', cid).neq('status', 'draft') as any) : Promise.resolve([]),
    ]);
    const bal = can('accountant') ? await rpc<any[]>('account_balances', { cid, p_from: '1900-01-01', p_to: today() }) : [];
    const alerts = can('accountant', 'project_manager') ? await rpc<any[]>('project_budget_alerts', { cid }).catch(() => [] as any[]) : [];
    const waiting = await rpc<any[]>('my_approvals', { cid }).catch(() => [] as any[]);
    const expiring = await rpc<any[]>('doc_expiry_alerts', { cid, p_days: 14 }).catch(() => [] as any[]);
    if (can('accountant', 'project_manager')) { try { await rpc('run_payment_reminders', { cid }); } catch { /* reminders are best effort */ } }
    try { await rpc('run_contract_reminders', { cid }); } catch { /* contract and asset reminders are best effort */ }
    try { await rpc('run_cash_reminders', { cid }); } catch { /* advance and petty cash reminders are best effort */ }
    const cash = await rpc<any>('cash_control_status', { cid }).catch(() => null);
    const cycle = can('accountant', 'sales', 'project_manager') ? await rpc<any>('cycle_status', { cid }).catch(() => null) : null;
    const siteReqs = can('accountant', 'store') ? await q<any[]>(supabase.from('stock_requests').select('id').eq('company_id', cid).eq('status', 'submitted') as any).catch(() => [] as any[]) : [];
    const orders = can('accountant', 'store', 'project_manager') ? await q<any[]>(supabase.from('purchase_orders').select('id,number,expected_date,status, supplier:suppliers(name)').eq('company_id', cid).in('status', ['approved', 'sent', 'partial']).order('expected_date', { nullsFirst: false }) as any).catch(() => [] as any[]) : [];
    return { invoices, products, bills, bal, alerts, waiting, orders, expiring, siteReqs, cycle, cash };
  }, [cid]);

  if (!data) return <Loading error={error} loading={loading} />;
  const m = monthStart();
  const posted = data.invoices.filter(i => i.status !== 'draft');
  const fx = (i: any) => Number(i.exchange_rate || 1);
  const due = (i: any) => Number(i.total) - Number(i.amount_paid) - Number(i.amount_credited || 0);
  const sales = posted.filter(i => i.invoice_date >= m).reduce((a, i) => a + Number(i.subtotal) * fx(i), 0);
  const owed = posted.reduce((a, i) => a + due(i) * fx(i), 0);
  const overdue = posted.filter(i => i.status === 'posted' && i.due_date && i.due_date < today());
  const payable = data.bills.reduce((a, b) => a + (Number(b.total) - Number(b.amount_paid)) * fx(b), 0);
  const stock = data.products.reduce((a, p) => a + Number(p.stock_qty) * Number(p.cost), 0);
  const low = data.products.filter(p => Number(p.reorder_level) > 0 && Number(p.stock_qty) <= Number(p.reorder_level));
  const by = (code: string) => data.bal.find(b => b.code === code);
  const cash = ['1000', '1010', '1100'].reduce((a, c) => { const b = by(c); return a + (b ? Number(b.debit) - Number(b.credit) : 0); }, 0);
  const taxDue = ['2110', '2120', '2130'].reduce((a, c) => { const b = by(c); return a + (b ? Number(b.credit) - Number(b.debit) : 0); }, 0)
    - ['1410', '1420', '1430'].reduce((a, c) => { const b = by(c); return a + (b ? Number(b.debit) - Number(b.credit) : 0); }, 0);

  return <>
    <PageHead title={embedded ? 'Today at a glance' : company?.name || 'Dashboard'} sub={embedded ? undefined : longDate(today())}>
      <Link className="btn" to="/bills/new">New bill</Link>
      <Link className="btn primary" to="/invoices/new">New invoice</Link>
    </PageHead>
    <div className="tiles">
      <div className="tile"><span>Sales this month (excl. tax)</span><b>{cedis(sales)}</b></div>
      <div className="tile"><span>Owed by customers</span><b>{cedis(owed)}</b></div>
      {can('accountant') && <div className="tile"><span>Cash, MoMo and bank</span><b>{cedis(cash)}</b></div>}
      {can('accountant') && <div className="tile"><span>Owed to suppliers</span><b>{cedis(payable)}</b></div>}
      {can('accountant') && <div className="tile"><span>{taxDue >= 0 ? 'Net VAT, NHIL, GETFund due' : 'VAT credit (input exceeds output)'}</span><b>{cedis(Math.abs(taxDue))}</b></div>}
      <div className="tile"><span>Stock value at cost</span><b>{cedis(stock)}</b></div>
    </div>
    {data.cycle && (() => { const c = data.cycle; const items = [
        can('accountant') && c.awards_unregistered + c.projects_unregistered > 0 && `${c.awards_unregistered + c.projects_unregistered} project${c.awards_unregistered + c.projects_unregistered === 1 ? '' : 's'} to register`,
        can('accountant') && c.budgets_waiting > 0 && `${c.budgets_waiting} budget${c.budgets_waiting === 1 ? '' : 's'} to approve`,
        can('accountant') && c.milestones_ready > 0 && `${c.milestones_ready} milestone${c.milestones_ready === 1 ? '' : 's'} ready to invoice`,
        can('accountant', 'sales') && c.invoices_no_followup > 0 && `${c.invoices_no_followup} overdue invoice${c.invoices_no_followup === 1 ? '' : 's'} to follow up`,
        c.tenders_due_7 > 0 && `${c.tenders_due_7} tender deadline${c.tenders_due_7 === 1 ? '' : 's'} this week`,
        c.reports_overdue > 0 && `${c.reports_overdue} progress report${c.reports_overdue === 1 ? '' : 's'} overdue`,
        can('accountant') && c.awaiting_clearance > 0 && `${c.awaiting_clearance} project${c.awaiting_clearance === 1 ? '' : 's'} awaiting financial clearance`].filter(Boolean);
      return items.length ? <div className="note actions" style={{ justifyContent: 'space-between' }}><span>Project cycle: {items.join(' · ')}.</span><Link className="btn small primary" to="/project-cycle">Open</Link></div> : null; })()}
    {data.cash && (() => { const c = data.cash; const parts: [number, string, string][] = [
        [c.to_action, 'approved request(s) to action', '/requests'], [c.retirements_to_check, 'advance retirement(s) to check', '/advances'],
        [c.advances_overdue, 'advance(s) overdue for retirement', '/advances'], [c.counts_to_approve, 'petty cash count(s) with a difference', '/petty-cash'],
        [c.floats_count_due, 'petty cash float(s) due for counting', '/petty-cash'], [c.my_advances_overdue, 'of your advances overdue: retire with receipts', '/advances']];
      const show = parts.filter(([n]) => Number(n) > 0);
      return show.length > 0 && <div className={'note actions' + (Number(c.advances_overdue) + Number(c.my_advances_overdue) > 0 ? ' warn' : '')} style={{ justifyContent: 'space-between' }}>
        <span>{show.map(([n, l], i) => <span key={l}>{i > 0 && ' · '}<b>{n}</b> {l}</span>)}.</span><Link className="btn small" to={show[0][2]}>Open</Link></div>; })()}
    {data.siteReqs.length > 0 && <div className="note actions" style={{ justifyContent: 'space-between' }}>
      <span><b>{data.siteReqs.length}</b> stock request{data.siteReqs.length === 1 ? '' : 's'} from project sites waiting to be sent.</span><Link className="btn small primary" to="/inventory/requests">Send</Link></div>}
    {data.expiring.length > 0 && <div className="note actions" style={{ justifyContent: 'space-between', background: 'var(--warn-soft)' }}>
      <span><b>{data.expiring.length}</b> permit{data.expiring.length === 1 ? '' : 's'}, certificate{data.expiring.length === 1 ? '' : 's'} or warrant{data.expiring.length === 1 ? 'y' : 'ies'} expired or expiring within 14 days: {data.expiring.slice(0, 3).map(e => e.number).join(', ')}{data.expiring.length > 3 ? '…' : ''}.</span>
      <Link className="btn small" to="/documents">Documents</Link></div>}
    {data.orders.length > 0 && <div className="note actions" style={{ justifyContent: 'space-between' }}>
      <span><b>{data.orders.length}</b> purchase order{data.orders.length === 1 ? ' is' : 's are'} waiting for delivery{data.orders.filter(o => o.expected_date && o.expected_date < today()).length ? <>, <b style={{ color: 'var(--bad)' }}>{data.orders.filter(o => o.expected_date && o.expected_date < today()).length} late</b></> : ''}
        {data.orders.filter(o => o.expected_date === today()).length ? `, ${data.orders.filter(o => o.expected_date === today()).length} due today` : ''}.</span>
      <Link className="btn small" to="/purchase-orders">Purchase orders</Link></div>}
    {data.waiting.length > 0 && <div className="note actions" style={{ justifyContent: 'space-between' }}>
      <span><b>{data.waiting.length}</b> item{data.waiting.length === 1 ? ' is' : 's are'} waiting for your approval, worth {cedis(data.waiting.reduce((a, w) => a + Number(w.amount), 0))}.</span>
      <Link className="btn small primary" to="/approvals-inbox">Review</Link></div>}
    {data.alerts.length > 0 && <Panel title={`Project budget alerts (${data.alerts.length})`} actions={<Link className="btn small" to="/project-costs">Project costs report</Link>}>
      <div className="scroll"><table>
        <thead><tr><th>Project</th><th className="r">Cost budget</th><th className="r">Spent</th><th className="r">Committed</th><th className="r">Forecast</th><th>Alert</th></tr></thead>
        <tbody>{data.alerts.map(a => <tr key={a.project_id} className="click" onClick={() => nav('/projects/' + a.project_id)}>
          <td><b>{a.name}</b><br /><span className="muted num">{a.number}</span>{a.over_categories.length > 0 && <span className="muted" style={{ fontSize: 12 }}> · over in: {a.over_categories.map((c: string) => ({ labour: 'labour', expenses: 'travel and expenses', materials: 'materials', subcontract: 'subcontractors', equipment: 'equipment hire', other: 'other expenses' } as Record<string, string>)[c] || c).join(', ')}</span>}</td>
          <td className="r num">{money(a.budget_cost)}</td><td className="r num">{money(a.actual_cost)}</td><td className="r num">{money(a.committed_cost)}</td><td className="r num">{money(a.eac_cost)}</td>
          <td><span className={'pill ' + (a.level === 'over' ? 'bad' : 'warn')}>{a.level === 'over' ? `Over budget · ${a.used_pct}%` : a.level === 'forecast_over' ? 'Forecast over budget' : `Near limit · ${a.used_pct}%`}</span>
            <br /><span className="muted" style={{ fontSize: 12 }}>{a.reason}</span></td></tr>)}</tbody>
      </table></div>
    </Panel>}
    <div className="two">
      <Panel title="Recent invoices" actions={<Link className="btn small" to="/invoices">All invoices</Link>}>
        {data.invoices.length ? <div className="scroll"><table>
          <thead><tr><th>Invoice</th><th>Customer</th><th>Date</th><th className="r">Total (GH₵)</th><th>Status</th></tr></thead>
          <tbody>{data.invoices.slice(0, 8).map(i => <tr key={i.id} className="click" onClick={() => nav('/invoices/' + i.id)}>
            <td className="num">{i.number || 'Draft'}</td><td>{i.customer?.name}</td><td className="num">{i.invoice_date}</td>
            <td className="r num">{(i.currency && i.currency !== 'GHS' ? i.currency + ' ' : '') + money(i.total)}</td><td><Status s={i.status} kind="invoice" /></td></tr>)}</tbody>
        </table></div> : <Empty>No invoices yet. <Link to="/invoices/new">Create your first invoice</Link>.</Empty>}
      </Panel>
      <div style={{ display: 'grid', gap: 16, alignContent: 'start' }}>
        <Panel title="Overdue" actions={<span className="muted">{overdue.length}</span>}>
          {overdue.length ? <div className="scroll"><table><tbody>{overdue.slice(0, 6).map(i => <tr key={i.id} className="click" onClick={() => nav('/invoices/' + i.id)}>
            <td>{i.customer?.name}<br /><span className="muted num">{i.number} · due {i.due_date}</span></td>
            <td className="r num">{money(due(i))}</td></tr>)}</tbody></table></div>
            : <Empty>Nothing overdue.</Empty>}
        </Panel>
        <Panel title="Reorder soon" actions={<Link className="btn small" to="/inventory?tab=reorder">Reorder list ({low.length})</Link>}>
          {low.length ? <div className="scroll"><table><tbody>{low.slice(0, 6).map(p => <tr key={p.id} className="click" onClick={() => nav('/inventory/items/' + p.id)}>
            <td>{p.name}</td><td className="r num"><span className="pill bad">{qty(p.stock_qty)} {p.unit}</span></td></tr>)}</tbody></table></div>
            : <Empty>All products are above their reorder level.</Empty>}
        </Panel>
      </div>
    </div>
  </>;
}
