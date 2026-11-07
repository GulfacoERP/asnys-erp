import { useState } from 'react';
import { Link, useSearchParams } from 'react-router-dom';
import { rpc } from '../lib/supabase';
import { useSession } from '../lib/session';
import { cedis, longDate, money, today, yearStart } from '../lib/format';
import { downloadCsv } from '../lib/download';
import { tablePdf } from '../lib/pdf';
import { Downloads, Empty, Field, Loading, PageHead, Panel, useLoad } from '../components/ui';

const CAT: Record<string, string> = { labour: 'Labour', expenses: 'Travel and expenses', materials: 'Materials', subcontract: 'Subcontractors', equipment: 'Equipment hire', other: 'Other expenses' };
const verdict = (budget: number, used: number, eac: number) =>
  !budget ? ['No budget', ''] : used > budget ? ['Over budget', 'bad'] : eac > budget ? ['Forecast over', 'warn'] : used >= budget * 0.9 ? ['Near limit', 'warn'] : ['Within budget', 'good'];

/** Project costs for the accountant: budget position per project and every cost line with its source document. */
export function ProjectCostsPage() {
  const { cid, company } = useSession();
  const [params, setParams] = useSearchParams();
  const [from, setFrom] = useState(yearStart());
  const [to, setTo] = useState(today());
  const project = params.get('project') || '';
  const [view, setView] = useState<'summary' | 'lines' | 'accounts'>(project ? 'lines' : 'summary');
  const { data, error, loading } = useLoad(async () => {
    const [kpis, lines] = await Promise.all([
      rpc<any[]>('project_kpis', { cid }),
      rpc<any[]>('project_cost_report', { cid, p_from: from, p_to: to, p_project: project || null }),
    ]);
    return { kpis, lines };
  }, [cid, from, to, project]);
  const period = `${longDate(from)} to ${longDate(to)}`;
  const kpis = (data?.kpis || []).filter(k => !project || k.project_id === project);
  const lines = data?.lines || [];
  const actualLines = lines.filter(l => !l.committed);
  const spentIn = (pid: string) => actualLines.filter(l => l.project_id === pid).reduce((s, l) => s + Number(l.amount), 0);
  const tot = (f: string) => kpis.reduce((s, k) => s + Number(k[f] || 0), 0);

  const sHead = ['Project', 'Status', 'Cost budget', 'Spent to date', 'Committed', 'Left to spend', '% used', 'Forecast cost', `Spent ${from} to ${to}`, 'Budget position'];
  const sRows = kpis.map(k => { const used = Number(k.actual_cost) + Number(k.committed_cost), b = Number(k.budget_cost);
    return [`${k.number || ''} ${k.name}`.trim(), k.status, money(b), money(k.actual_cost), money(k.committed_cost), money(b - used), b ? Math.round(used / b * 100) + '%' : '—', money(k.eac_cost), money(spentIn(k.project_id)), verdict(b, used, Number(k.eac_cost))[0]]; });
  const lHead = ['Date', 'Project', 'Cost type', 'Source', 'Reference', 'Description', 'Account', 'Amount (GHS)', 'In ledger'];
  const lRows = lines.map(l => [l.item_date, l.project, CAT[l.category] || l.category, l.committed ? 'Committed (purchase request)' : l.source, l.reference || '', l.description || '',
    l.account_code ? `${l.account_code} ${l.account_name}` : '', money(l.amount), l.committed ? 'Not yet' : l.in_ledger ? 'Yes' : 'No (management cost)']);
  const byAcct = Object.values(actualLines.filter(l => l.in_ledger).reduce((m: any, l) => {
    const key = l.account_code; m[key] = m[key] || { code: l.account_code, name: l.account_name, amount: 0, n: 0 }; m[key].amount += Number(l.amount); m[key].n++; return m; }, {})) as any[];
  byAcct.sort((a, b) => a.code.localeCompare(b.code));
  const aHead = ['Account', 'Lines', 'Charged to projects (GHS)'];
  const aRows = byAcct.map(a => [`${a.code} ${a.name}`, String(a.n), money(a.amount)]);
  const labour = actualLines.filter(l => !l.in_ledger).reduce((s, l) => s + Number(l.amount), 0);
  const title = project ? `Project costs: ${kpis[0]?.name || ''}` : 'Project costs';

  return <>
    <PageHead title={title} sub="Budget position for every project, and each cost line with the document it came from. Money in GH₵ excluding VAT.">
      {view === 'summary' && <Downloads pdf={() => tablePdf({ company: company!, title: 'Project budget position', subtitle: `Life to date at ${longDate(to)}; period spend ${period}`, head: sHead, body: sRows, rightAlign: [2, 3, 4, 5, 6, 7, 8], landscape: true, filename: `project-budgets-${to}`,
        foot: ['Total', '', money(tot('budget_cost')), money(tot('actual_cost')), money(tot('committed_cost')), money(tot('budget_cost') - tot('actual_cost') - tot('committed_cost')), '', money(tot('eac_cost')), money(actualLines.reduce((s, l) => s + Number(l.amount), 0)), ''] })}
        csv={() => downloadCsv(`project-budgets-${to}`, sHead, sRows)} />}
      {view === 'lines' && <Downloads pdf={() => tablePdf({ company: company!, title, subtitle: period + ' (committed items at any date)', head: lHead, body: lRows, rightAlign: [7], landscape: true, filename: `project-cost-lines-${from}-${to}`,
        foot: ['', '', '', '', '', '', 'Total spent', money(actualLines.reduce((s, l) => s + Number(l.amount), 0)), ''] })}
        csv={() => downloadCsv(`project-cost-lines-${from}-${to}`, lHead, lRows)} />}
      {view === 'accounts' && <Downloads pdf={() => tablePdf({ company: company!, title: 'Project costs by ledger account', subtitle: period, head: aHead, body: aRows, rightAlign: [1, 2], filename: `project-costs-by-account-${from}-${to}`,
        notes: `Labour of GH₵ ${money(labour)} is a management cost (approved hours × cost rate) and is not in the ledger by project; payroll posts salaries in total.` })}
        csv={() => downloadCsv(`project-costs-by-account-${from}-${to}`, aHead, aRows)} />}
    </PageHead>
    <Panel pad><div className="filters">
      <Field label="From" id="pc-from" type="date" value={from} onChange={setFrom} />
      <Field label="To" id="pc-to" type="date" value={to} onChange={setTo} />
      <div className="field" style={{ width: 240 }}><label htmlFor="pc-proj">Project</label>
        <select id="pc-proj" value={project} onChange={e => setParams(e.target.value ? { project: e.target.value } : {})}>
          <option value="">All projects</option>{(data?.kpis || []).map(k => <option key={k.project_id} value={k.project_id}>{k.number ? k.number + ' ' : ''}{k.name}</option>)}</select></div>
    </div></Panel>
    <div className="actions">
      {([['summary', 'Budget position'], ['lines', 'Cost lines'], ['accounts', 'By ledger account']] as const).map(([v, l]) =>
        <button key={v} type="button" className={'btn small' + (view === v ? ' primary' : '')} onClick={() => setView(v)}>{l}</button>)}
    </div>
    <Loading error={error} loading={loading && !data} />

    {data && view === 'summary' && <Panel>{kpis.length ? <div className="scroll"><table>
      <thead><tr><th>Project</th><th className="r">Cost budget</th><th className="r">Spent</th><th className="r">Committed</th><th className="r">Left</th><th className="r">Forecast</th><th className="r">Spent in period</th><th>Position</th></tr></thead>
      <tbody>{kpis.map(k => { const used = Number(k.actual_cost) + Number(k.committed_cost), b = Number(k.budget_cost); const [v, c] = verdict(b, used, Number(k.eac_cost));
        return <tr key={k.project_id}><td><Link to={'/projects/' + k.project_id}><b>{k.name}</b></Link><br /><span className="muted num">{k.number}</span> <span className="muted">· {k.status}</span></td>
          <td className="r num">{money(b)}</td><td className="r num">{money(k.actual_cost)}</td><td className="r num">{money(k.committed_cost)}</td>
          <td className="r num" style={{ color: b - used < 0 ? 'var(--bad)' : undefined }}>{money(b - used)}</td><td className="r num">{money(k.eac_cost)}</td>
          <td className="r num"><button className="btn ghost small" type="button" style={{ padding: 0 }} onClick={() => { setParams({ project: k.project_id }); setView('lines'); }}>{money(spentIn(k.project_id))}</button></td>
          <td><span className={'pill ' + c}>{v}</span>{b > 0 && <span className="muted num" style={{ fontSize: 12 }}> {Math.round(used / b * 100)}%</span>}</td></tr>; })}</tbody>
      <tfoot><tr><td>Total</td><td className="r num">{money(tot('budget_cost'))}</td><td className="r num">{money(tot('actual_cost'))}</td><td className="r num">{money(tot('committed_cost'))}</td>
        <td className="r num">{money(tot('budget_cost') - tot('actual_cost') - tot('committed_cost'))}</td><td className="r num">{money(tot('eac_cost'))}</td>
        <td className="r num">{money(actualLines.reduce((s, l) => s + Number(l.amount), 0))}</td><td></td></tr></tfoot>
    </table></div> : <Empty>No projects yet.</Empty>}
      <div className="body muted" style={{ fontSize: 13 }}>Spent, committed and budget are for the life of the project. "Spent in period" uses the dates above. Over budget = spent plus committed is more than the cost budget; forecast over = the estimate at completion is.</div>
    </Panel>}

    {data && view === 'lines' && <Panel>{lines.length ? <div className="scroll"><table>
      <thead><tr><th>Date</th>{!project && <th>Project</th>}<th>Cost type</th><th>Source</th><th>Description and account</th><th className="r">Amount (GH₵)</th></tr></thead>
      <tbody>{lines.map((l, i) => <tr key={i} style={l.committed ? { opacity: .7 } : undefined}>
        <td className="num">{l.item_date}</td>{!project && <td>{l.project}</td>}<td>{CAT[l.category] || l.category}</td>
        <td>{l.committed ? <span className="pill warn">Committed</span> : l.source}<br /><span className="muted num" style={{ fontSize: 12 }}>{l.reference}</span></td>
        <td className="wrap-cell">{l.description}<br /><span className="muted" style={{ fontSize: 12 }}>{l.account_code ? `${l.account_code} ${l.account_name}` : l.committed ? 'Not posted yet' : 'Management cost, not in the ledger'}</span></td>
        <td className="r num">{money(l.amount)}</td></tr>)}</tbody>
      <tfoot><tr><td colSpan={project ? 4 : 5}>Spent in period (committed excluded)</td><td className="r num">{money(actualLines.reduce((s, l) => s + Number(l.amount), 0))}</td></tr></tfoot>
    </table></div> : <Empty>No project costs in this period.</Empty>}</Panel>}

    {data && view === 'accounts' && <Panel title="Ledger check">{byAcct.length ? <div className="scroll"><table>
      <thead><tr><th>Account</th><th className="r">Lines</th><th className="r">Charged to projects (GH₵)</th></tr></thead>
      <tbody>{byAcct.map(a => <tr key={a.code}><td><span className="num">{a.code}</span> {a.name}</td><td className="r num">{a.n}</td><td className="r num">{money(a.amount)}</td></tr>)}</tbody>
      <tfoot><tr><td>Total in the ledger</td><td></td><td className="r num">{money(byAcct.reduce((s, a) => s + a.amount, 0))}</td></tr></tfoot>
    </table></div> : <Empty>No ledger postings charged to projects in this period.</Empty>}
      <div className="body muted" style={{ fontSize: 13 }}>Every supplier bill line, expense claim and manual journal charged to a project is tagged with that project in the ledger; the Journal shows the tag on each line, so these totals tie to it.
        Labour ({cedis(labour)} in this period) is a management cost, approved hours × cost rate, and is not posted by project.</div>
    </Panel>}
  </>;
}
