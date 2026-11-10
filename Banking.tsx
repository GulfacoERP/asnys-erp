import { useMemo, useState } from 'react';
import { q, rpc, supabase } from '../lib/supabase';
import { useSession } from '../lib/session';
import { cedis, longDate, money, r2, today } from '../lib/format';
import { downloadCsv } from '../lib/download';
import { tablePdf } from '../lib/pdf';
import { ConfirmButton, Downloads, Empty, Field, Loading, PageHead, Panel, Select, useAction, useLoad } from '../components/ui';

export function BankRecPage() {
  const { cid, company } = useSession();
  const act = useAction();
  const [account, setAccount] = useState('');
  const [date, setDate] = useState(today());
  const [balance, setBalance] = useState('');
  const [ticked, setTicked] = useState<Set<string>>(new Set());

  const { data: accounts } = useLoad(() => q<any[]>(supabase.from('accounts').select('id,code,name,system_key').eq('company_id', cid).in('system_key', ['bank', 'momo', 'cash']).order('code') as any), [cid]);
  const acc = account || accounts?.[0]?.id || '';
  const { data, error, loading, reload } = useLoad(async () => {
    if (!acc) return null;
    const [open, cleared, recs] = await Promise.all([
      q<any[]>(supabase.from('journal_lines').select('id,debit,credit,entry:journal_entries!inner(entry_no,entry_date,memo)').eq('account_id', acc).is('reconciliation_id', null).lte('entry.entry_date', date) as any),
      q<any[]>(supabase.from('journal_lines').select('debit,credit').eq('account_id', acc).not('reconciliation_id', 'is', null) as any),
      q<any[]>(supabase.from('bank_reconciliations').select('*').eq('account_id', acc).order('created_at', { ascending: false }) as any),
    ]);
    open.sort((a, b) => a.entry.entry_date.localeCompare(b.entry.entry_date) || a.entry.entry_no.localeCompare(b.entry.entry_no));
    return { open, opening: r2(cleared.reduce((s, l) => s + Number(l.debit) - Number(l.credit), 0)), recs };
  }, [acc, date]);

  const clearedNow = useMemo(() => {
    if (!data) return 0;
    return r2(data.opening + data.open.filter(l => ticked.has(l.id)).reduce((s, l) => s + Number(l.debit) - Number(l.credit), 0));
  }, [data, ticked]);
  const diff = r2((Number(balance) || 0) - clearedNow);
  const toggle = (id: string) => { const n = new Set(ticked); n.has(id) ? n.delete(id) : n.add(id); setTicked(n); };
  const accName = accounts?.find(a => a.id === acc);

  const finish = () => act.run(async () => {
    if (balance === '') throw new Error('Enter the closing balance from your statement.');
    await rpc('complete_reconciliation', { cid, p_account: acc, p_date: date, p_balance: Number(balance), p_lines: [...ticked] });
    const ticks = data!.open.filter(l => ticked.has(l.id));
    const rows = ticks.map(l => [l.entry.entry_date, l.entry.entry_no, l.entry.memo || '', Number(l.debit) ? money(l.debit) : '', Number(l.credit) ? money(l.credit) : '']);
    tablePdf({ company: company!, title: 'Bank reconciliation', subtitle: `${accName?.name} at ${longDate(date)}`, head: ['Date', 'Entry', 'Details', 'In (GHS)', 'Out (GHS)'], body: rows,
      foot: ['', '', `Statement balance ${money(balance)}`, '', ''], rightAlign: [3, 4], filename: `bank-reconciliation-${date}`,
      notes: `Opening reconciled balance GHS ${money(data!.opening)}. ${ticks.length} items cleared. Uncleared items remaining: ${data!.open.length - ticks.length}.` });
    setTicked(new Set()); setBalance(''); reload();
  }, 'Reconciled — the report has downloaded');

  return <>
    <PageHead title="Bank reconciliation" sub="Tick the items that appear on your bank or MoMo statement until the difference is zero." />
    <div className="filters">
      <Select label="Account" id="br-acc" value={acc} onChange={v => { setAccount(v); setTicked(new Set()); }} options={(accounts || []).map(a => [a.id, `${a.code} ${a.name}`])} />
      <Field label="Statement date" id="br-date" type="date" value={date} onChange={v => { setDate(v); setTicked(new Set()); }} />
      <Field label="Statement closing balance (GH₵)" id="br-bal" type="number" step="0.01" value={balance} onChange={setBalance} />
    </div>
    <Loading error={error} loading={loading && !data} />
    {data && <>
      <div className="tiles">
        <div className="tile"><span>Previously reconciled</span><b>{cedis(data.opening)}</b></div>
        <div className="tile"><span>Cleared balance</span><b>{cedis(clearedNow)}</b></div>
        <div className="tile"><span>Difference</span><b style={{ color: diff === 0 && balance !== '' ? 'var(--good)' : 'var(--bad)' }}>{cedis(diff)}</b></div>
      </div>
      <Panel title={`Uncleared items to ${longDate(date)}`} actions={<>
        <button className="btn small" type="button" onClick={() => setTicked(new Set(data.open.map(l => l.id)))}>Tick all</button>
        <button className="btn small primary" type="button" disabled={act.busy || diff !== 0 || balance === ''} onClick={finish}>Finish reconciliation</button></>}>
        {data.open.length ? <div className="scroll"><table>
          <thead><tr><th></th><th>Date</th><th>Entry</th><th>Details</th><th className="r">In (GH₵)</th><th className="r">Out (GH₵)</th></tr></thead>
          <tbody>{data.open.map(l => <tr key={l.id} className="click" onClick={() => toggle(l.id)}>
            <td><input type="checkbox" aria-label="Cleared" checked={ticked.has(l.id)} onChange={() => toggle(l.id)} onClick={e => e.stopPropagation()} /></td>
            <td className="num">{l.entry.entry_date}</td><td className="num">{l.entry.entry_no}</td><td className="wrap-cell">{l.entry.memo}</td>
            <td className="r num">{Number(l.debit) ? money(l.debit) : ''}</td><td className="r num">{Number(l.credit) ? money(l.credit) : ''}</td></tr>)}</tbody>
        </table></div> : <Empty>Everything up to this date is reconciled.</Empty>}
      </Panel>
      {data.recs.length > 0 && <Panel title="Completed reconciliations"><div className="scroll"><table>
        <thead><tr><th>Statement date</th><th className="r">Statement balance (GH₵)</th><th>Done on</th><th></th></tr></thead>
        <tbody>{data.recs.map((r, i) => <tr key={r.id}><td className="num">{r.statement_date}</td><td className="r num">{money(r.statement_balance)}</td><td className="num">{r.created_at.slice(0, 10)}</td>
          <td className="r">{i === 0 && <ConfirmButton className="btn small ghost" label="Undo" confirm="Undo the latest reconciliation?" onConfirm={() => act.run(async () => { await rpc('undo_reconciliation', { p_rec: r.id }); reload(); }, 'Reconciliation undone')} />}</td></tr>)}</tbody>
      </table></div></Panel>}
    </>}
  </>;
}

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

export function BudgetsPage() {
  const { cid, company } = useSession();
  const act = useAction();
  const [year, setYear] = useState(Number(today().slice(0, 4)));
  const [grid, setGrid] = useState<Record<string, string[]>>({});
  const { data, error, loading } = useLoad(async () => {
    const [accounts, budgets] = await Promise.all([
      q<any[]>(supabase.from('accounts').select('id,code,name,type').eq('company_id', cid).in('type', ['income', 'expense']).eq('active', true).order('code') as any),
      q<any[]>(supabase.from('budgets').select('*').eq('company_id', cid).eq('year', year) as any),
    ]);
    const g: Record<string, string[]> = {};
    accounts.forEach(a => { g[a.id] = Array(12).fill(''); });
    budgets.forEach(b => { if (g[b.account_id]) g[b.account_id][b.month - 1] = String(b.amount); });
    setGrid(g);
    return { accounts };
  }, [cid, year]);
  const total = (id: string) => (grid[id] || []).reduce((s, v) => s + (Number(v) || 0), 0);
  const head = ['Code', 'Account', ...MONTHS, 'Year (GHS)'];
  const rows = (data?.accounts || []).filter(a => total(a.id)).map(a => [a.code, a.name, ...grid[a.id].map(v => money(Number(v) || 0)), money(total(a.id))]);

  const save = () => act.run(async () => {
    const rows = Object.entries(grid).flatMap(([account_id, vals]) => vals.map((v, i) => ({ company_id: cid, account_id, year, month: i + 1, amount: Number(v) || 0 })));
    await q(supabase.from('budgets').upsert(rows) as any);
  }, 'Budget saved. Compare it under Reports → Budget vs actual.');

  return <>
    <PageHead title={`Budget ${year}`} sub="Monthly amounts for income and expense accounts. Type a yearly figure and press Spread to divide it over 12 months.">
      <select aria-label="Year" value={year} onChange={e => setYear(Number(e.target.value))} style={{ width: 'auto' }}>{[year - 1, year, year + 1].map(y => <option key={y} value={y}>{y}</option>)}</select>
      <Downloads pdf={() => tablePdf({ company: company!, title: 'Budget', subtitle: String(year), head, body: rows, rightAlign: Array.from({ length: 13 }, (_, i) => i + 2), landscape: true, filename: `budget-${year}` })} csv={() => downloadCsv(`budget-${year}`, head, rows)} />
      <button className="btn primary" type="button" disabled={act.busy} onClick={save}>Save budget</button>
    </PageHead>
    <Loading error={error} loading={loading && !data} />
    {data && <Panel><div className="scroll"><table className="lines">
      <thead><tr><th>Account</th>{MONTHS.map(m => <th key={m} className="r">{m}</th>)}<th className="r">Year</th><th></th></tr></thead>
      <tbody>{data.accounts.map(a => <tr key={a.id}>
        <td style={{ whiteSpace: 'nowrap' }}><span className="muted num">{a.code}</span> {a.name}</td>
        {MONTHS.map((m, i) => <td key={m}><input aria-label={`${a.name} ${m}`} type="number" step="1" style={{ width: 84, textAlign: 'right' }} value={grid[a.id]?.[i] ?? ''}
          onChange={e => setGrid({ ...grid, [a.id]: grid[a.id].map((v, j) => (j === i ? e.target.value : v)) })} /></td>)}
        <td className="r num">{money(total(a.id))}</td>
        <td><button className="btn small ghost" type="button" title="Divide the first month's figure as a yearly total over 12 months" onClick={() => {
          const yearly = Number(grid[a.id][0]) || 0; const each = Math.round((yearly / 12) * 100) / 100;
          setGrid({ ...grid, [a.id]: Array(12).fill(String(each)) });
        }}>Spread</button></td></tr>)}</tbody>
    </table></div><div className="body muted" style={{ fontSize: 13 }}>To spread a yearly figure, type it in January and press Spread.</div></Panel>}
  </>;
}
