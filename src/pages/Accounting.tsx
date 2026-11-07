import { useState } from 'react';
import { Link } from 'react-router-dom';
import { qPage } from '../lib/supabase';
import { Pager, usePaged } from '../components/paging';
import { q, rpc, supabase } from '../lib/supabase';
import { useSession } from '../lib/session';
import { longDate, money, monthStart, r2, today } from '../lib/format';
import { downloadCsv } from '../lib/download';
import { tablePdf } from '../lib/pdf';
import { Downloads, Empty, Field, FormModal, Loading, PageHead, Panel, Select, useAction, useLoad } from '../components/ui';

const TYPES: [string, string][] = [['asset', 'Asset'], ['liability', 'Liability'], ['equity', 'Equity'], ['income', 'Income'], ['expense', 'Expense']];

export function AccountsPage() {
  const { cid, company } = useSession();
  const [edit, setEdit] = useState<any | null>(null);
  const act = useAction();
  const { data, error, loading, reload } = useLoad(() => rpc<any[]>('account_balances', { cid, p_from: '1900-01-01', p_to: today() }), [cid]);
  const { data: accts, reload: reloadAccts } = useLoad(() => q<any[]>(supabase.from('accounts').select('*').eq('company_id', cid) as any), [cid]);
  const bal = (a: any) => (['asset', 'expense'].includes(a.type) ? Number(a.debit) - Number(a.credit) : Number(a.credit) - Number(a.debit));
  const head = ['Code', 'Account', 'Type', 'Balance (GHS)'];
  const rows = (data || []).map(a => [a.code, a.name, a.type, money(bal(a))]);
  const meta = (id: string) => accts?.find(a => a.id === id);

  const save = () => act.run(async () => {
    const row = { code: edit.code.trim(), name: edit.name.trim(), type: edit.type, active: edit.active, is_bank: edit.type === 'asset' && !!edit.is_bank };
    if (edit.id) await q(supabase.from('accounts').update(row).eq('id', edit.id) as any);
    else await q(supabase.from('accounts').insert({ ...row, company_id: cid }) as any);
    setEdit(null); reload(); reloadAccts();
  }, 'Account saved');

  return <>
    <PageHead title="Chart of accounts" sub="Balances to today. System accounts used by invoices, bills and payroll cannot change type.">
      <Downloads pdf={() => tablePdf({ company: company!, title: 'Chart of accounts', subtitle: 'Balances at ' + longDate(today()), head, body: rows, rightAlign: [3], filename: 'chart-of-accounts' })}
        csv={() => downloadCsv('chart-of-accounts', head, rows)} />
      <button className="btn primary" type="button" onClick={() => setEdit({ code: '', name: '', type: 'expense', active: true })}>Add account</button>
    </PageHead>
    <Loading error={error} loading={loading && !data} />
    {data && <Panel><div className="scroll"><table>
      <thead><tr><th>Code</th><th>Account</th><th>Type</th><th className="r">Balance (GH₵)</th><th></th></tr></thead>
      <tbody>{data.map(a => { const m = meta(a.account_id); return <tr key={a.account_id} style={m && !m.active ? { opacity: .5 } : undefined}>
        <td className="num">{a.code}</td>
        <td><button className="btn ghost small" style={{ padding: 0, fontWeight: 500 }} type="button" onClick={() => m && setEdit(m)}>{a.name}</button>{m?.system_key && <span className="pill" style={{ marginLeft: 6 }}>System</span>}{m?.is_bank && <span className="pill good" style={{ marginLeft: 6 }}>Bank / cash</span>}</td>
        <td>{TYPES.find(t => t[0] === a.type)?.[1]}</td><td className="r num">{money(bal(a))}</td>
        <td className="r"><Link className="btn small ghost" to={`/ledger?account=${a.account_id}`}>Ledger</Link></td></tr>; })}</tbody>
    </table></div></Panel>}
    {edit && <FormModal title={edit.id ? 'Edit account' : 'Add account'} onClose={() => setEdit(null)} onSave={save} busy={act.busy}>
      <div className="grid-form">
        <Field label="Code" id="ac-code" value={edit.code} onChange={v => setEdit({ ...edit, code: v })} required />
        {edit.system_key ? <div className="field"><label>Type</label><input value={edit.type} disabled /></div>
          : <Select label="Type" id="ac-type" value={edit.type} onChange={v => setEdit({ ...edit, type: v })} options={TYPES} />}
      </div>
      <Field label="Name" id="ac-name" value={edit.name} onChange={v => setEdit({ ...edit, name: v })} required />
      {!edit.system_key && <label className="check"><input type="checkbox" checked={edit.active} onChange={e => setEdit({ ...edit, active: e.target.checked })} /> Active</label>}
      {edit.type === 'asset' && !['cash', 'momo', 'bank'].includes(edit.system_key) && <label className="check"><input type="checkbox" checked={!!edit.is_bank} onChange={e => setEdit({ ...edit, is_bank: e.target.checked })} /> This is a bank, cash or MoMo account (shows under Bank & cash, reconciliation and payments)</label>}
    </FormModal>}
  </>;
}

export function JournalPage() {
  const { cid, company } = useSession();
  const act = useAction();
  const [from, setFrom] = useState(monthStart());
  const [to, setTo] = useState(today());
  const [source, setSource] = useState('');
  const [manual, setManual] = useState<any | null>(null);
  const { data: meta } = useLoad(async () => {
    const [accounts, projects, branches, centres] = await Promise.all([
      q<any[]>(supabase.from('accounts').select('id,code,name,type').eq('company_id', cid).eq('active', true).order('code') as any),
      q<any[]>(supabase.from('projects').select('id,number,name').eq('company_id', cid).eq('is_template', false).order('name') as any),
      q<any[]>(supabase.from('branches').select('id,code,name').eq('company_id', cid).eq('active', true).order('code') as any),
      q<any[]>(supabase.from('cost_centres').select('id,code,name').eq('company_id', cid).eq('active', true).order('code') as any),
    ]);
    return { accounts, projects, branches, centres };
  }, [cid]);
  const build = () => {
    let qy: any = supabase.from('journal_entries').select('*, lines:journal_lines(debit,credit,account:accounts(code,name),project:projects(number,name),branch:branches(code),cc:cost_centres(code))', { count: 'exact' })
      .eq('company_id', cid).gte('entry_date', from).lte('entry_date', to);
    if (source) qy = qy.eq('source_type', source);
    return qy.order('entry_date', { ascending: false }).order('created_at', { ascending: false });
  };
  const pg = usePaged((a, b) => qPage(build().range(a, b)), [cid, from, to, source], 100);
  const head = ['Entry', 'Date', 'Memo', 'Account', 'Project', 'Branch', 'Cost centre', 'Debit (GHS)', 'Credit (GHS)'];
  const toRows = (entries: any[]) => entries.flatMap(e => e.lines.map((l: any, i: number) => [i ? '' : e.entry_no, i ? '' : e.entry_date, i ? '' : (e.memo || ''), `${l.account.code} ${l.account.name}`,
    l.project ? `${l.project.number || ''} ${l.project.name}`.trim() : '', l.branch?.code || '', l.cc?.code || '', Number(l.debit) ? money(l.debit) : '', Number(l.credit) ? money(l.credit) : '']));
  const period = `${longDate(from)} to ${longDate(to)}`;
  const download = (kind: 'pdf' | 'csv') => act.run(async () => {
    const all: any[] = []; for (let a = 0; a < 20000; a += 1000) { const r = await qPage(build().range(a, a + 999)); all.push(...r.rows); if (r.rows.length < 1000) break; }
    if (kind === 'csv') return downloadCsv(`journal-${from}-to-${to}`, head, toRows(all));
    tablePdf({ company: company!, title: 'General journal', subtitle: period, head, body: toRows(all), rightAlign: [7, 8], landscape: true, filename: `journal-${from}-to-${to}` });
  });
  const blank = () => ({ account_id: '', debit: '', credit: '', project_id: '', branch_id: '', cost_centre_id: '' });
  const dr = manual ? r2(manual.lines.reduce((a: number, l: any) => a + (Number(l.debit) || 0), 0)) : 0;
  const cr = manual ? r2(manual.lines.reduce((a: number, l: any) => a + (Number(l.credit) || 0), 0)) : 0;
  const setL = (i: number, p: any) => setManual({ ...manual, lines: manual.lines.map((l: any, j: number) => (j === i ? { ...l, ...p } : l)) });
  const typeOf = (id: string) => meta?.accounts.find(a => a.id === id)?.type;
  const SOURCES: [string, string][] = [['', 'All sources'], ['invoice', 'Invoices'], ['payment', 'Customer receipts'], ['credit_note', 'Credit notes'], ['bill', 'Supplier bills'], ['bill_payment', 'Supplier payments'],
    ['payroll', 'Payroll'], ['payroll_payment', 'Salary payments'], ['expense', 'Expense claims'], ['reimbursement', 'Reimbursements'], ['cash', 'Bank & cash'], ['manual', 'Manual journals'],
    ['opening', 'Opening balances'], ['stock', 'Stock'], ['asset', 'Assets'], ['depreciation', 'Depreciation'], ['asset_disposal', 'Asset disposals'], ['commission', 'Commissions'], ['loan', 'Staff loans']];

  return <>
    <PageHead title="Journal" sub="Every posting in the books, newest first. Use the General ledger for one account with running balances.">
      <Downloads pdf={() => download('pdf')} csv={() => download('csv')} />
      <Link className="btn" to="/ledger">General ledger</Link>
      <button className="btn primary" type="button" onClick={() => setManual({ date: today(), memo: '', lines: [blank(), blank()] })}>Manual journal</button>
    </PageHead>
    <div className="filters"><Field label="From" id="j-from" type="date" value={from} onChange={setFrom} /><Field label="To" id="j-to" type="date" value={to} onChange={setTo} />
      <Select label="Source" id="j-src" value={source} onChange={setSource} options={SOURCES} /></div>
    <Loading error={pg.error} loading={pg.loading && !pg.data} />
    {pg.data && <Panel>{pg.rows.length ? <div className="scroll"><table>
      <thead><tr><th>Entry</th><th>Date</th><th>Details</th><th className="r">Debit</th><th className="r">Credit</th></tr></thead>
      <tbody>{pg.rows.map((e: any) => e.lines.map((l: any, i: number) => <tr key={e.id + i}>
        <td className="num">{i ? '' : e.entry_no}</td><td className="num">{i ? '' : e.entry_date}</td>
        <td>{i === 0 && <><b>{e.memo}</b><br /></>}<span className="muted num">{l.account.code}</span> {l.account.name}
          {l.project && <span className="pill" style={{ marginLeft: 6 }}>{l.project.number || l.project.name}</span>}
          {l.branch && <span className="pill" style={{ marginLeft: 4 }}>{l.branch.code}</span>}{l.cc && <span className="pill" style={{ marginLeft: 4 }}>{l.cc.code}</span>}</td>
        <td className="r num">{Number(l.debit) ? money(l.debit) : ''}</td><td className="r num">{Number(l.credit) ? money(l.credit) : ''}</td></tr>))}</tbody>
    </table></div> : <Empty>No entries in this period.</Empty>}
      <Pager {...pg} noun="journal entries" />
    </Panel>}
    {manual && meta && <FormModal title="Manual journal" submit="Post journal" busy={act.busy} onClose={() => setManual(null)}
      onSave={() => act.run(async () => {
        if (dr !== cr || dr === 0) throw new Error(`Debits (${money(dr)}) must equal credits (${money(cr)}) and not be zero.`);
        const lines = manual.lines.filter((l: any) => l.account_id && (Number(l.debit) || Number(l.credit))).map((l: any) => ({ account_id: l.account_id, debit: Number(l.debit) || 0, credit: Number(l.credit) || 0,
          project_id: l.project_id || null, branch_id: l.branch_id || null, cost_centre_id: l.cost_centre_id || null }));
        await rpc('post_manual_journal', { cid, p_date: manual.date, p_memo: manual.memo, p_lines: lines });
        setManual(null); pg.reload();
      }, 'Journal posted')}>
      <div className="grid-form">
        <Field label="Date" id="mj-date" type="date" value={manual.date} onChange={v => setManual({ ...manual, date: v })} required />
        <Field label="Memo" id="mj-memo" value={manual.memo} onChange={v => setManual({ ...manual, memo: v })} placeholder="e.g. PAYE paid to GRA for October" required />
      </div>
      <div className="scroll"><table className="lines"><thead><tr><th>Account</th><th>Project</th>{meta.branches.length > 0 && <th>Branch</th>}{meta.centres.length > 0 && <th>Cost centre</th>}<th className="r">Debit</th><th className="r">Credit</th></tr></thead>
        <tbody>{manual.lines.map((l: any, i: number) => <tr key={i}>
          <td style={{ minWidth: 200 }}><select aria-label="Account" value={l.account_id} onChange={e => setL(i, { account_id: e.target.value })}><option value="">Choose…</option>
            {meta.accounts.map(a => <option key={a.id} value={a.id}>{a.code} {a.name}</option>)}</select></td>
          <td><select aria-label="Charge to project" value={l.project_id || ''} onChange={e => setL(i, { project_id: e.target.value })} style={{ minWidth: 110 }} disabled={!['expense', 'asset'].includes(typeOf(l.account_id))}>
            <option value="">—</option>{meta.projects.map(p => <option key={p.id} value={p.id}>{p.number ? p.number + ' ' : ''}{p.name}</option>)}</select></td>
          {meta.branches.length > 0 && <td><select aria-label="Branch" value={l.branch_id} onChange={e => setL(i, { branch_id: e.target.value })} style={{ minWidth: 90 }}>
            <option value="">—</option>{meta.branches.map(b => <option key={b.id} value={b.id}>{b.code}</option>)}</select></td>}
          {meta.centres.length > 0 && <td><select aria-label="Cost centre" value={l.cost_centre_id} onChange={e => setL(i, { cost_centre_id: e.target.value })} style={{ minWidth: 90 }}>
            <option value="">—</option>{meta.centres.map(b => <option key={b.id} value={b.id}>{b.code}</option>)}</select></td>}
          <td><input aria-label="Debit" type="number" step="0.01" min="0" value={l.debit} onChange={e => setL(i, { debit: e.target.value })} style={{ width: 110, textAlign: 'right' }} /></td>
          <td><input aria-label="Credit" type="number" step="0.01" min="0" value={l.credit} onChange={e => setL(i, { credit: e.target.value })} style={{ width: 110, textAlign: 'right' }} /></td>
        </tr>)}</tbody>
        <tfoot><tr><td><button className="btn small" type="button" onClick={() => setManual({ ...manual, lines: [...manual.lines, blank()] })}>Add line</button></td>
          <td colSpan={1 + (meta.branches.length > 0 ? 1 : 0) + (meta.centres.length > 0 ? 1 : 0)}></td><td className="r num">{money(dr)}</td><td className="r num">{money(cr)}</td></tr></tfoot></table></div>
      {dr !== cr && <div className="error">Out of balance by {money(Math.abs(dr - cr))}</div>}
      <p className="muted" style={{ margin: 0, fontSize: 13 }}>Pick a project on an expense line to charge a cost to it. Branch and cost centre put the line in those reports. For money paid or received through the bank, Bank & cash is quicker.</p>
    </FormModal>}
  </>;
}
