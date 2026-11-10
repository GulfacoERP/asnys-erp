import { useState } from 'react';
import { q, rpc, supabase } from '../lib/supabase';
import { useSession } from '../lib/session';
import { longDate, money, monthStart, r2, today, yearStart } from '../lib/format';
import { downloadCsv } from '../lib/download';
import { Cell, tablePdf } from '../lib/pdf';
import { Downloads, Field, Loading, PageHead, Panel, useLoad } from '../components/ui';

type Tab = 'pl' | 'bs' | 'tb' | 'vat' | 'aging' | 'budget' | 'dim';
const TABS: [Tab, string][] = [['pl', 'Profit and loss'], ['bs', 'Balance sheet'], ['tb', 'Trial balance'], ['vat', 'VAT return'], ['aging', 'Debtors ageing'], ['budget', 'Budget vs actual'], ['dim', 'By branch / cost centre']];

type Report = { title: string; head: string[]; rows: Cell[][]; foot?: Cell[]; right: number[]; bold: number[]; sections: number[]; notes?: string; period: string };

export function ReportsPage() {
  const { cid, company } = useSession();
  const [tab, setTab] = useState<Tab>('pl');
  const [from, setFrom] = useState(yearStart());
  const [to, setTo] = useState(today());
  const [branch, setBranch] = useState('');
  const [centre, setCentre] = useState('');
  const [dim, setDim] = useState<'branch' | 'cost_centre'>('branch');
  const { data: dims } = useLoad(async () => ({
    branches: await q<any[]>(supabase.from('branches').select('id,code,name').eq('company_id', cid).order('code') as any),
    centres: await q<any[]>(supabase.from('cost_centres').select('id,code,name').eq('company_id', cid).order('code') as any),
  }), [cid]);
  const { data: dimRows } = useLoad(() => tab === 'dim' ? rpc<any[]>('pl_by_dimension', { cid, p_from: from, p_to: to, p_dim: dim }) : Promise.resolve(null), [cid, from, to, dim, tab]);

  const { data, error, loading } = useLoad(async () => {
    const yr = Number(to.slice(0, 4));
    const [range, cumulative, invoices, budgets, actuals] = await Promise.all([
      rpc<any[]>('account_balances', { cid, p_from: from, p_to: to, p_branch: branch || null, p_cost_centre: centre || null }),
      rpc<any[]>('account_balances', { cid, p_from: '1900-01-01', p_to: to, p_branch: branch || null, p_cost_centre: centre || null }),
      q<any[]>(supabase.from('invoices').select('number,invoice_date,due_date,total,amount_paid,amount_credited,exchange_rate,status,customer:customers(name)').eq('company_id', cid).eq('status', 'posted') as any),
      q<any[]>(supabase.from('budgets').select('account_id,month,amount').eq('company_id', cid).eq('year', yr) as any),
      rpc<any[]>('monthly_actuals', { cid, p_year: yr }),
    ]);
    return { range, cumulative, invoices, budgets, actuals };
  }, [cid, from, to, branch, centre]);

  const scope = [branch && dims?.branches.find(b => b.id === branch)?.name, centre && dims?.centres.find(c => c.id === centre)?.name].filter(Boolean).join(' · ');
  const base: Report | null = tab === 'dim' ? (dimRows ? buildDim(dimRows, dim, from, to) : null) : data ? build(tab, data, from, to) : null;
  const report: Report | null = base && scope && tab !== 'dim' ? { ...base, period: `${base.period} · ${scope}` } : base;
  const asAt = tab === 'bs' || tab === 'aging' || tab === 'budget';
  const file = `${TABS.find(t => t[0] === tab)![1].toLowerCase().replace(/\s+/g, '-')}-${asAt ? to : from + '-to-' + to}`;

  return <>
    <PageHead title="Reports" sub="Built from the general ledger. Download any report as PDF or CSV.">
      {report && <Downloads
        pdf={() => tablePdf({ company: company!, title: report.title, subtitle: report.period, head: report.head, body: report.rows, foot: report.foot, rightAlign: report.right, boldRows: [...report.bold, ...report.sections], filename: file, notes: report.notes })}
        csv={() => downloadCsv(file, report.head, [...report.rows, ...(report.foot ? [report.foot] : [])])} />}
    </PageHead>
    <div className="actions">{TABS.map(([k, l]) => <button key={k} type="button" className={'btn small' + (tab === k ? ' primary' : '')} onClick={() => setTab(k)}>{l}</button>)}</div>
    <div className="filters">
      {!asAt && <Field label="From" id="r-from" type="date" value={from} onChange={setFrom} />}
      <Field label={tab === 'budget' ? 'Year to date up to' : asAt ? 'As at' : 'To'} id="r-to" type="date" value={to} onChange={setTo} />
      {tab !== 'dim' && (dims?.branches.length || 0) > 0 && <div className="field" style={{ width: 180 }}><label htmlFor="r-br">Branch</label>
        <select id="r-br" value={branch} onChange={e => setBranch(e.target.value)}><option value="">All branches</option>{dims!.branches.map(b => <option key={b.id} value={b.id}>{b.code} {b.name}</option>)}</select></div>}
      {tab !== 'dim' && (dims?.centres.length || 0) > 0 && <div className="field" style={{ width: 180 }}><label htmlFor="r-cc">Cost centre</label>
        <select id="r-cc" value={centre} onChange={e => setCentre(e.target.value)}><option value="">All cost centres</option>{dims!.centres.map(b => <option key={b.id} value={b.id}>{b.code} {b.name}</option>)}</select></div>}
      {tab === 'dim' && <div className="field" style={{ width: 180 }}><label htmlFor="r-dim">Columns</label>
        <select id="r-dim" value={dim} onChange={e => setDim(e.target.value as any)}><option value="branch">Branches</option><option value="cost_centre">Cost centres</option></select></div>}
      {tab === 'vat' && <button className="btn small" type="button" style={{ marginBottom: 2 }} onClick={() => {
        const d = new Date(today() + 'T00:00:00Z'); d.setUTCDate(0); const end = d.toISOString().slice(0, 10); setFrom(monthStart(end)); setTo(end);
      }}>Last month</button>}
    </div>
    <Loading error={error} loading={loading && !data} />
    {report && <Panel title={report.title} actions={<span className="muted">{report.period}</span>}><div className="scroll"><table>
      <thead><tr>{report.head.map((h, i) => <th key={h} className={report.right.includes(i) ? 'r' : ''}>{h.replace('GHS', 'GH₵')}</th>)}</tr></thead>
      <tbody>{report.rows.map((r, i) => <tr key={i} className={report.sections.includes(i) ? 'section' : ''} style={report.bold.includes(i) ? { fontWeight: 600 } : undefined}>
        {r.map((c, j) => <td key={j} className={(report.right.includes(j) ? 'r num' : '')}>{c}</td>)}</tr>)}</tbody>
      {report.foot && <tfoot><tr>{report.foot.map((c, j) => <td key={j} className={report.right.includes(j) ? 'r num' : ''}>{c}</td>)}</tr></tfoot>}
    </table></div>{report.notes && <div className="body muted" style={{ fontSize: 13 }}>{report.notes}</div>}</Panel>}
  </>;
}

function build(tab: Tab, d: { range: any[]; cumulative: any[]; invoices: any[]; budgets: any[]; actuals: any[] }, from: string, to: string): Report {
  if (tab === 'budget') {
    const m = Number(to.slice(5, 7)), yr = to.slice(0, 4);
    const accts = d.cumulative.filter(a => a.type === 'income' || a.type === 'expense');
    const rows: Cell[][] = [], sections: number[] = [], bold: number[] = [];
    let netB = 0, netA = 0;
    for (const type of ['income', 'expense']) {
      sections.push(rows.length); rows.push([type === 'income' ? 'Income' : 'Expenses', '', '', '', '']);
      let tb = 0, ta = 0;
      accts.filter(a => a.type === type).forEach(a => {
        const b = d.budgets.filter(x => x.account_id === a.account_id && x.month <= m).reduce((s, x) => s + Number(x.amount), 0);
        const act = d.actuals.filter(x => x.account_id === a.account_id && x.month <= m).reduce((s, x) => s + (type === 'income' ? Number(x.credit) - Number(x.debit) : Number(x.debit) - Number(x.credit)), 0);
        if (!b && !act) return;
        tb += b; ta += act;
        const v = type === 'income' ? act - b : b - act;
        rows.push([`${a.code}  ${a.name}`, money(b), money(act), money(v), b ? Math.round((act / b) * 100) + '%' : '—']);
      });
      bold.push(rows.length); rows.push([type === 'income' ? 'Total income' : 'Total expenses', money(tb), money(ta), money(type === 'income' ? ta - tb : tb - ta), tb ? Math.round((ta / tb) * 100) + '%' : '—']);
      if (type === 'income') { netB += tb; netA += ta; } else { netB -= tb; netA -= ta; }
    }
    return { title: 'Budget vs actual', period: `Jan to ${longDate(to)} ${yr}`.replace(` ${yr} ${yr}`, ` ${yr}`), head: ['Account', 'Budget (GHS)', 'Actual (GHS)', 'Favourable / (adverse)', '% of budget'],
      rows, foot: ['Net profit', money(netB), money(netA), money(netA - netB), netB ? Math.round((netA / netB) * 100) + '%' : '—'], right: [1, 2, 3, 4], bold, sections,
      notes: 'Positive variance is favourable: income above budget or expenses below budget.' };
  }
  const period = `${longDate(from)} to ${longDate(to)}`;
  const net = (a: any, debitNormal: boolean) => (debitNormal ? 1 : -1) * (Number(a.debit) - Number(a.credit));
  const nonzero = (a: any) => Number(a.debit) !== 0 || Number(a.credit) !== 0;

  if (tab === 'tb') {
    let td = 0, tc = 0;
    const rows = d.cumulative.filter(nonzero).map(a => {
      const v = r2(Number(a.debit) - Number(a.credit)); const dr = v > 0 ? v : 0, cr = v < 0 ? -v : 0; td += dr; tc += cr;
      return [a.code, a.name, dr ? money(dr) : '', cr ? money(cr) : ''];
    });
    return { title: 'Trial balance', period: 'As at ' + longDate(to), head: ['Code', 'Account', 'Debit (GHS)', 'Credit (GHS)'], rows, foot: ['', 'Totals', money(td), money(tc)], right: [2, 3], bold: [], sections: [],
      notes: r2(td) === r2(tc) ? 'Debits equal credits: the books balance.' : `Out of balance by ${money(Math.abs(td - tc))}.` };
  }

  if (tab === 'pl') {
    const inc = d.range.filter(a => a.type === 'income' && nonzero(a));
    const cogs = d.range.filter(a => a.type === 'expense' && a.code.startsWith('5') && nonzero(a));
    const exp = d.range.filter(a => a.type === 'expense' && !a.code.startsWith('5') && nonzero(a));
    const sum = (xs: any[], dn: boolean) => r2(xs.reduce((s, a) => s + net(a, dn), 0));
    const ti = sum(inc, false), tcogs = sum(cogs, true), te = sum(exp, true), gp = r2(ti - tcogs), np = r2(gp - te);
    const rows: Cell[][] = [], bold: number[] = [], sections: number[] = [];
    const sec = (t: string) => { sections.push(rows.length); rows.push([t, '']); };
    const tot = (t: string, v: number) => { bold.push(rows.length); rows.push([t, money(v)]); };
    sec('Income'); inc.forEach(a => rows.push([`${a.code}  ${a.name}`, money(net(a, false))])); tot('Total income', ti);
    sec('Cost of sales'); cogs.forEach(a => rows.push([`${a.code}  ${a.name}`, money(net(a, true))])); tot('Gross profit', gp);
    sec('Operating expenses'); exp.forEach(a => rows.push([`${a.code}  ${a.name}`, money(net(a, true))])); tot('Total expenses', te);
    return { title: 'Profit and loss', period, head: ['Account', 'Amount (GHS)'], rows, foot: [np >= 0 ? 'Net profit' : 'Net loss', money(np)], right: [1], bold, sections };
  }

  if (tab === 'bs') {
    const c = d.cumulative.filter(nonzero);
    const assets = c.filter(a => a.type === 'asset'), liab = c.filter(a => a.type === 'liability'), eq = c.filter(a => a.type === 'equity');
    const profit = r2(c.filter(a => a.type === 'income').reduce((s, a) => s + net(a, false), 0) - c.filter(a => a.type === 'expense').reduce((s, a) => s + net(a, true), 0));
    const sum = (xs: any[], dn: boolean) => r2(xs.reduce((s, a) => s + net(a, dn), 0));
    const ta = sum(assets, true), tl = sum(liab, false), teq = r2(sum(eq, false) + profit);
    const rows: Cell[][] = [], bold: number[] = [], sections: number[] = [];
    const sec = (t: string) => { sections.push(rows.length); rows.push([t, '']); };
    const tot = (t: string, v: number) => { bold.push(rows.length); rows.push([t, money(v)]); };
    sec('Assets'); assets.forEach(a => rows.push([`${a.code}  ${a.name}`, money(net(a, true))])); tot('Total assets', ta);
    sec('Liabilities'); liab.forEach(a => rows.push([`${a.code}  ${a.name}`, money(net(a, false))])); tot('Total liabilities', tl);
    sec('Equity'); eq.forEach(a => rows.push([`${a.code}  ${a.name}`, money(net(a, false))])); rows.push(['Profit to date (not yet closed)', money(profit)]); tot('Total equity', teq);
    return { title: 'Balance sheet', period: 'As at ' + longDate(to), head: ['Account', 'Amount (GHS)'], rows, foot: ['Liabilities and equity', money(tl + teq)], right: [1], bold, sections,
      notes: r2(ta) === r2(tl + teq) ? 'Total assets equal liabilities plus equity.' : `Difference of ${money(Math.abs(ta - tl - teq))} — check the trial balance.` };
  }

  if (tab === 'vat') {
    const get = (code: string) => d.range.find(a => a.code === code);
    const out = (code: string) => { const a = get(code); return a ? r2(Number(a.credit) - Number(a.debit)) : 0; };
    const inn = (code: string) => { const a = get(code); return a ? r2(Number(a.debit) - Number(a.credit)) : 0; };
    const sales = d.range.filter(a => a.type === 'income').reduce((s, a) => s + net(a, false), 0);
    const rows: Cell[][] = [
      ['Output tax (on sales)', '', '', ''],
      ['VAT 15%', money(out('2110')), '', ''], ['NHIL 2.5%', money(out('2120')), '', ''], ['GETFund levy 2.5%', money(out('2130')), '', ''],
      ['Input tax (on purchases)', '', '', ''],
      ['VAT 15%', '', money(inn('1410')), ''], ['NHIL 2.5%', '', money(inn('1420')), ''], ['GETFund levy 2.5%', '', money(inn('1430')), ''],
      ['Net payable to GRA', '', '', ''],
      ['VAT', '', '', money(out('2110') - inn('1410'))], ['NHIL', '', '', money(out('2120') - inn('1420'))], ['GETFund levy', '', '', money(out('2130') - inn('1430'))],
    ];
    const totOut = out('2110') + out('2120') + out('2130'), totIn = inn('1410') + inn('1420') + inn('1430');
    return { title: 'VAT return summary', period, head: ['Item', 'Output (GHS)', 'Input (GHS)', 'Net (GHS)'], rows, foot: ['Total', money(totOut), money(totIn), money(totOut - totIn)],
      right: [1, 2, 3], bold: [], sections: [0, 4, 8],
      notes: `Sales in period (excl. tax): GHS ${money(sales)}. Rates per the VAT Act, 2025 (Act 1151). This summary supports your GRA return; it does not include payments already made to GRA. File and pay by the last working day of the following month.` };
  }

  // Debtors ageing
  const asAt = to;
  const days = (due: string) => Math.floor((Date.parse(asAt) - Date.parse(due)) / 864e5);
  const buckets: Record<string, { name: string; b: number[] }> = {};
  d.invoices.forEach(i => {
    const bal = (Number(i.total) - Number(i.amount_paid) - Number(i.amount_credited || 0)) * Number(i.exchange_rate || 1); if (bal <= 0.004 || i.invoice_date > asAt) return;
    const n = days(i.due_date || i.invoice_date); const k = i.customer?.name || '—';
    buckets[k] = buckets[k] || { name: k, b: [0, 0, 0, 0, 0] };
    const idx = n <= 0 ? 0 : n <= 30 ? 1 : n <= 60 ? 2 : n <= 90 ? 3 : 4;
    buckets[k].b[idx] += bal;
  });
  const list = Object.values(buckets).sort((a, b) => a.name.localeCompare(b.name));
  const tot = [0, 0, 0, 0, 0]; list.forEach(x => x.b.forEach((v, i) => { tot[i] += v; }));
  return { title: 'Debtors ageing', period: 'As at ' + longDate(asAt), head: ['Customer', 'Not yet due', '1–30 days', '31–60 days', '61–90 days', 'Over 90 days', 'Total (GHS)'],
    rows: list.map(x => [x.name, ...x.b.map(money), money(x.b.reduce((a, v) => a + v, 0))]),
    foot: ['Total', ...tot.map(money), money(tot.reduce((a, v) => a + v, 0))], right: [1, 2, 3, 4, 5, 6], bold: [], sections: [] };
}


/** Profit and loss with one column per branch or cost centre. */
function buildDim(rows: any[], dim: 'branch' | 'cost_centre', from: string, to: string): Report {
  const cols = Array.from(new Set(rows.map(r => r.dim_name))).sort((a, b) => (a === 'Not assigned' ? 1 : b === 'Not assigned' ? -1 : a.localeCompare(b)));
  const accts = Array.from(new Map(rows.map(r => [r.account_id, r])).values()).sort((a: any, b: any) => a.code.localeCompare(b.code));
  const val = (acc: string, col: string) => rows.filter(r => r.account_id === acc && r.dim_name === col).reduce((s, r) => s + Number(r.amount), 0);
  const out: Cell[][] = []; const sections: number[] = []; const bold: number[] = [];
  const totals: Record<string, Record<string, number>> = { income: {}, expense: {} };
  for (const type of ['income', 'expense']) {
    sections.push(out.length); out.push([type === 'income' ? 'Income' : 'Expenses', ...cols.map(() => ''), '']);
    for (const a of accts.filter((x: any) => x.type === type) as any[]) {
      const vals = cols.map(c => val(a.account_id, c));
      cols.forEach((c, i) => { totals[type][c] = (totals[type][c] || 0) + vals[i]; });
      out.push([`${a.code} ${a.name}`, ...vals.map(v => (v ? money(v) : '')), money(vals.reduce((s, v) => s + v, 0))]);
    }
    bold.push(out.length); out.push([type === 'income' ? 'Total income' : 'Total expenses', ...cols.map(c => money(totals[type][c] || 0)), money(cols.reduce((s, c) => s + (totals[type][c] || 0), 0))]);
  }
  const net = cols.map(c => (totals.income[c] || 0) - (totals.expense[c] || 0));
  return { title: `Profit and loss by ${dim === 'branch' ? 'branch' : 'cost centre'}`, head: ['Account (GHS)', ...cols, 'Total'], rows: out,
    foot: ['Net profit', ...net.map(v => money(v)), money(net.reduce((s, v) => s + v, 0))], right: cols.map((_, i) => i + 1).concat([cols.length + 1]), bold, sections,
    period: `${longDate(from)} to ${longDate(to)}`, notes: '"Not assigned" holds postings with no ' + (dim === 'branch' ? 'branch' : 'cost centre') + '. Set defaults on employees, projects and documents to reduce it.' };
}
