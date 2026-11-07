import { useState } from 'react';
import { Link, useSearchParams } from 'react-router-dom';
import { q, qPage, rpc, supabase } from '../lib/supabase';
import { useSession } from '../lib/session';
import { cedis, longDate, money, today, yearStart } from '../lib/format';
import { downloadCsv } from '../lib/download';
import { tablePdf } from '../lib/pdf';
import { Downloads, Empty, Field, FormModal, Loading, PageHead, Panel, Select, useAction, useLoad } from '../components/ui';
import { Pager, SearchBox, usePaged } from '../components/paging';

function useMeta(cid: string) {
  return useLoad(async () => {
    const [accounts, branches, centres, projects] = await Promise.all([
      q<any[]>(supabase.from('accounts').select('id,code,name,type,is_bank,system_key,active').eq('company_id', cid).order('code') as any),
      q<any[]>(supabase.from('branches').select('id,code,name').eq('company_id', cid).eq('active', true).order('code') as any),
      q<any[]>(supabase.from('cost_centres').select('id,code,name').eq('company_id', cid).eq('active', true).order('code') as any),
      q<any[]>(supabase.from('projects').select('id,number,name').eq('company_id', cid).eq('is_template', false).order('name') as any),
    ]);
    return { accounts, branches, centres, projects };
  }, [cid]);
}
const SOURCES: [string, string][] = [['', 'All sources'], ['invoice', 'Invoices'], ['payment', 'Customer receipts'], ['credit_note', 'Credit notes'], ['bill', 'Supplier bills'],
  ['bill_payment', 'Supplier payments'], ['payroll', 'Payroll'], ['payroll_payment', 'Salary payments'], ['expense', 'Expense claims'], ['reimbursement', 'Reimbursements'],
  ['cash', 'Bank & cash'], ['manual', 'Manual journals'], ['opening', 'Opening balances'], ['stock', 'Stock'], ['asset', 'Assets'], ['depreciation', 'Depreciation'], ['commission', 'Commissions']];

// ---------------------------------------------------------------- General ledger
export function GeneralLedgerPage() {
  const { cid, company } = useSession();
  const act = useAction();
  const [params, setParams] = useSearchParams();
  const [tab, setTab] = useState<'ledger' | 'checks' | 'unposted'>('ledger');
  const [from, setFrom] = useState(yearStart());
  const [to, setTo] = useState(today());
  const [f, setF] = useState({ branch: '', centre: '', project: '', source: '', search: '' });
  const account = params.get('account') || '';
  const { data: meta } = useMeta(cid);
  const acct = meta?.accounts.find(a => a.id === account);
  const args = (a: number, b: number) => ({ cid, p_account: account, p_from: from, p_to: to, p_branch: f.branch || null, p_cost_centre: f.centre || null,
    p_project: f.project || null, p_source: f.source || null, p_search: f.search || null, p_limit: b - a + 1, p_offset: a });
  const pg = usePaged(async (a, b) => {
    if (!account) return { rows: [], total: 0 };
    const rows = await rpc<any[]>('general_ledger', args(a, b));
    return { rows, total: Number(rows[0]?.total_rows || 0), opening: rows[0]?.opening };
  }, [cid, account, from, to, JSON.stringify(f)], 200);
  const { data: checks } = useLoad(() => tab === 'checks' ? rpc<any[]>('ledger_checks', { cid }) : Promise.resolve(null), [cid, tab]);
  const { data: unposted } = useLoad(() => tab === 'unposted' ? rpc<any[]>('unposted_documents', { cid }) : Promise.resolve(null), [cid, tab]);
  const natural = acct && ['asset', 'expense'].includes(acct.type) ? 1 : -1;  // show balances the natural way round
  const bal = (v: any) => { const n = Number(v) * natural; return `${money(Math.abs(n))} ${n < 0 ? (natural === 1 ? 'Cr' : 'Dr') : (natural === 1 ? 'Dr' : 'Cr')}`; };
  const opening = pg.rows[0]?.opening ?? (pg.data as any)?.opening ?? 0;
  const head = ['Date', 'Entry', 'Source document', 'Memo', 'Branch', 'Cost centre', 'Project', 'Debit', 'Credit', 'Balance'];
  const download = (kind: 'pdf' | 'csv') => act.run(async () => {
    const all: any[] = []; for (let a = 0; a < 50000; a += 5000) { const r = await rpc<any[]>('general_ledger', args(a, a + 4999)); all.push(...r); if (r.length < 5000) break; }
    const op = all[0]?.opening ?? 0;
    const body = [['', '', '', 'Opening balance', '', '', '', '', '', bal(op)], ...all.map(r => [r.entry_date, r.entry_no, r.ref_label || '', r.memo || '', r.branch || '', r.cost_centre || '', r.project || '',
      Number(r.debit) ? money(r.debit) : '', Number(r.credit) ? money(r.credit) : '', bal(r.balance)])];
    const dr = all.reduce((s, r) => s + Number(r.debit), 0), cr = all.reduce((s, r) => s + Number(r.credit), 0);
    const foot = ['', '', '', 'Totals and closing balance', '', '', '', money(dr), money(cr), bal(Number(op) + dr - cr)];
    const name = `ledger-${acct?.code}-${from}-to-${to}`;
    if (kind === 'csv') return downloadCsv(name, head, [...body, foot]);
    tablePdf({ company: company!, title: `General ledger: ${acct?.code} ${acct?.name}`, subtitle: `${longDate(from)} to ${longDate(to)}`, head, body, foot, rightAlign: [7, 8, 9], landscape: true, filename: name });
  });

  return <>
    <PageHead title="General ledger" sub="Every transaction in the books, by account, with running balances and a link to the document that created it.">
      {tab === 'ledger' && account && <Downloads pdf={() => download('pdf')} csv={() => download('csv')} />}
      <Link className="btn" to="/journal">Journal</Link>
    </PageHead>
    <div className="actions">
      {([['ledger', 'Account ledger'], ['checks', 'Books check'], ['unposted', 'Not in the books yet']] as const).map(([k, l]) =>
        <button key={k} type="button" className={'btn small' + (tab === k ? ' primary' : '')} onClick={() => setTab(k)}>{l}</button>)}
    </div>

    {tab === 'ledger' && <>
      <Panel pad><div className="filters">
        <div className="field" style={{ width: 280 }}><label htmlFor="gl-acct">Account</label>
          <select id="gl-acct" value={account} onChange={e => setParams(e.target.value ? { account: e.target.value } : {})}>
            <option value="">Choose an account…</option>{(meta?.accounts || []).map(a => <option key={a.id} value={a.id}>{a.code} {a.name}</option>)}</select></div>
        <Field label="From" id="gl-from" type="date" value={from} onChange={setFrom} />
        <Field label="To" id="gl-to" type="date" value={to} onChange={setTo} />
        <Select label="Source" id="gl-src" value={f.source} onChange={v => setF({ ...f, source: v })} options={SOURCES} />
        {(meta?.branches.length || 0) > 0 && <Select label="Branch" id="gl-br" value={f.branch} onChange={v => setF({ ...f, branch: v })} options={[['', 'All'], ...meta!.branches.map(b => [b.id, b.code] as [string, string])]} />}
        {(meta?.centres.length || 0) > 0 && <Select label="Cost centre" id="gl-cc" value={f.centre} onChange={v => setF({ ...f, centre: v })} options={[['', 'All'], ...meta!.centres.map(b => [b.id, b.code] as [string, string])]} />}
        {(meta?.projects.length || 0) > 0 && <Select label="Project" id="gl-pj" value={f.project} onChange={v => setF({ ...f, project: v })} options={[['', 'All'], ...meta!.projects.map(b => [b.id, b.number || b.name] as [string, string])]} />}
        <SearchBox value={f.search} onChange={v => setF({ ...f, search: v })} placeholder="Memo, entry or document no." id="gl-search" width={220} />
      </div></Panel>
      {!account ? <Empty>Choose an account to see every transaction on it. Tip: open the Chart of accounts and click Ledger next to any account.</Empty> : <>
        <Loading error={pg.error} loading={pg.loading && !pg.data} />
        {pg.data && <Panel title={`${acct?.code} ${acct?.name}`} actions={<span className="muted">{longDate(from)} to {longDate(to)}</span>}>
          <div className="scroll"><table>
            <thead><tr><th>Date</th><th>Entry</th><th>Source document</th><th>Memo</th><th className="r">Debit</th><th className="r">Credit</th><th className="r">Balance</th></tr></thead>
            <tbody>
              {pg.page === 0 && <tr className="section"><td colSpan={6}>Opening balance at {longDate(from)}</td><td className="r num">{bal(opening)}</td></tr>}
              {pg.rows.map((r: any) => <tr key={r.line_id}>
                <td className="num">{r.entry_date}</td><td className="num">{r.entry_no}</td>
                <td>{r.ref_path ? <Link to={r.ref_path}>{r.ref_label}</Link> : r.ref_label}</td>
                <td className="wrap-cell">{r.memo}{(r.branch || r.cost_centre || r.project) && <> {[r.branch, r.cost_centre, r.project].filter(Boolean).map((x: string) => <span key={x} className="pill" style={{ marginLeft: 4 }}>{x}</span>)}</>}</td>
                <td className="r num">{Number(r.debit) ? money(r.debit) : ''}</td><td className="r num">{Number(r.credit) ? money(r.credit) : ''}</td><td className="r num">{bal(r.balance)}</td></tr>)}
            </tbody>
          </table></div>
          {!pg.rows.length && <Empty>No transactions on this account in this period{f.search || f.source || f.branch || f.centre || f.project ? ' with these filters' : ''}.</Empty>}
          <Pager {...pg} noun="lines" />
        </Panel>}
      </>}
    </>}

    {tab === 'checks' && <Panel title="Books check: do the control accounts agree with the documents?">{checks ? <div className="scroll"><table>
      <thead><tr><th>Check</th><th className="r">Ledger</th><th className="r">Documents</th><th className="r">Difference</th><th>Result</th></tr></thead>
      <tbody>{checks.map(c => <tr key={c.check_name}><td className="wrap-cell" style={{ maxWidth: 420 }}><b>{c.check_name}</b><br /><span className="muted" style={{ fontSize: 12 }}>{c.explanation}</span></td>
        <td className="r num">{money(c.ledger)}</td><td className="r num">{money(c.documents)}{Number(c.direct) ? <><br /><span className="muted" style={{ fontSize: 12 }}>+ {money(c.direct)} direct</span></> : null}</td>
        <td className="r num">{money(c.difference)}</td><td>{c.ok ? <span className="pill good">Agrees</span> : <span className="pill bad">Check this</span>}</td></tr>)}</tbody>
    </table></div> : <Loading loading />}
      <div className="body muted" style={{ fontSize: 13 }}>Every invoice, receipt, credit note, bill, payment, payroll, expense claim, stock movement, asset and bank transaction posts its own balanced journal. These checks prove the totals in the ledger match the documents behind them. Run them before closing each month.</div>
    </Panel>}

    {tab === 'unposted' && <Panel title="Not in the books yet">{unposted ? <div className="scroll"><table>
      <thead><tr><th>What</th><th className="r">Count</th><th className="r">Amount (GH₵)</th><th>Oldest</th><th></th></tr></thead>
      <tbody>{unposted.map(u => <tr key={u.kind} style={Number(u.n) ? undefined : { opacity: .55 }}><td>{u.kind}</td><td className="r num">{Number(u.n)}</td>
        <td className="r num">{u.kind.includes('hours') ? Number(u.amount) + ' h' : money(u.amount)}</td><td className="num">{u.oldest || ''}</td>
        <td className="r">{Number(u.n) > 0 && <Link className="btn small" to={u.path}>Open</Link>}</td></tr>)}</tbody>
    </table></div> : <Loading loading />}
      <div className="body muted" style={{ fontSize: 13 }}>Drafts and items waiting for approval are not in the ledger. Clear this list before you lock a month.</div>
    </Panel>}
  </>;
}

// ---------------------------------------------------------------- Bank and cash
export function BankCashPage() {
  const { cid, company } = useSession();
  const act = useAction();
  const [params] = useSearchParams();
  const [edit, setEdit] = useState<any | null>(null);
  const [voiding, setVoiding] = useState<any | null>(null);
  const [kind, setKind] = useState('');
  const [acc, setAcc] = useState('');
  const [from, setFrom] = useState(yearStart());
  const [to, setTo] = useState(today());
  const { data: meta } = useMeta(cid);
  const { data: bals, reload: reloadBals } = useLoad(() => rpc<any[]>('account_balances', { cid, p_from: '1900-01-01', p_to: today() }), [cid]);
  const banks = (meta?.accounts || []).filter(a => a.is_bank && a.active);
  const others = (meta?.accounts || []).filter(a => !a.is_bank && a.active && !['ar', 'ap', 'inventory', 'vat_in', 'nhil_in', 'getf_in', 'vat_out', 'nhil_out', 'getf_out'].includes(a.system_key));
  const build = () => {
    let qy: any = supabase.from('cash_transactions').select('*, account:accounts!cash_transactions_account_id_fkey(code,name), counter:accounts!cash_transactions_counter_account_id_fkey(code,name)', { count: 'exact' })
      .eq('company_id', cid).gte('txn_date', from).lte('txn_date', to);
    if (kind) qy = qy.eq('kind', kind);
    if (acc) qy = qy.or(`account_id.eq.${acc},counter_account_id.eq.${acc}`);
    if (params.get('id')) qy = qy.eq('id', params.get('id'));
    return qy.order('txn_date', { ascending: false }).order('created_at', { ascending: false });
  };
  const pg = usePaged((a, b) => qPage(build().range(a, b)), [cid, kind, acc, from, to, params.get('id')]);
  const balOf = (id: string) => { const b = bals?.find(x => x.account_id === id); return b ? Number(b.debit) - Number(b.credit) : 0; };
  const head = ['No.', 'Date', 'Type', 'From', 'To / account', 'Payee', 'Description', 'Reference', 'Amount (GHS)', 'Status'];
  const rows = pg.rows.map((t: any) => [t.number, t.txn_date, t.kind, `${t.account.code} ${t.account.name}`, `${t.counter.code} ${t.counter.name}`, t.payee || '', t.description, t.reference || '', money(t.amount), t.status]);
  const KIND: Record<string, string> = { receive: 'Money in', spend: 'Money out', transfer: 'Transfer' };

  return <>
    <PageHead title="Bank and cash" sub="Money in and out that is not a customer receipt or supplier payment, and transfers between your own accounts. Each one posts to the books.">
      <Downloads pdf={() => tablePdf({ company: company!, title: 'Bank and cash transactions', subtitle: `${longDate(from)} to ${longDate(to)}`, head, body: rows, rightAlign: [8], landscape: true, filename: `bank-cash-${from}-${to}` })}
        csv={() => downloadCsv(`bank-cash-${from}-${to}`, head, rows)} />
      <Link className="btn" to="/bank-reconciliation">Reconcile</Link>
      <button className="btn" type="button" onClick={() => setEdit({ kind: 'transfer', date: today(), account: banks[0]?.id || '', counter: banks[1]?.id || '', amount: '', description: '', payee: '', reference: '', branch: '', centre: '', project: '' })}>Transfer</button>
      <button className="btn" type="button" onClick={() => setEdit({ kind: 'spend', date: today(), account: banks[0]?.id || '', counter: '', amount: '', description: '', payee: '', reference: '', branch: '', centre: '', project: '' })}>Money out</button>
      <button className="btn primary" type="button" onClick={() => setEdit({ kind: 'receive', date: today(), account: banks[0]?.id || '', counter: '', amount: '', description: '', payee: '', reference: '', branch: '', centre: '', project: '' })}>Money in</button>
    </PageHead>
    {bals && <div className="tiles">{banks.map(b => <div key={b.id} className="tile"><span>{b.code} {b.name}</span><b>{cedis(balOf(b.id))}</b>
      <Link to={`/ledger?account=${b.id}`} style={{ fontSize: 12 }}>Ledger</Link></div>)}</div>}
    <div className="filters">
      <Select label="Type" id="cb-kind" value={kind} onChange={setKind} options={[['', 'All'], ['receive', 'Money in'], ['spend', 'Money out'], ['transfer', 'Transfers']]} />
      <Select label="Account" id="cb-acc" value={acc} onChange={setAcc} options={[['', 'All accounts'], ...banks.map(b => [b.id, `${b.code} ${b.name}`] as [string, string])]} />
      <Field label="From" id="cb-from" type="date" value={from} onChange={setFrom} />
      <Field label="To" id="cb-to" type="date" value={to} onChange={setTo} />
    </div>
    <Loading error={pg.error} loading={pg.loading && !pg.data} />
    {pg.data && <Panel>{pg.rows.length ? <div className="scroll"><table>
      <thead><tr><th>No.</th><th>Date</th><th>What</th><th>Accounts</th><th className="r">Amount (GH₵)</th><th></th></tr></thead>
      <tbody>{pg.rows.map((t: any) => <tr key={t.id} style={t.status === 'voided' ? { opacity: .5, textDecoration: 'line-through' } : undefined}>
        <td className="num">{t.number}</td><td className="num">{t.txn_date}</td>
        <td className="wrap-cell"><span className={'pill ' + (t.kind === 'receive' ? 'good' : t.kind === 'spend' ? 'warn' : '')}>{KIND[t.kind]}</span> {t.description}
          {(t.payee || t.reference) && <><br /><span className="muted" style={{ fontSize: 12 }}>{[t.payee, t.reference].filter(Boolean).join(' · ')}</span></>}</td>
        <td style={{ fontSize: 13 }}>{t.kind === 'receive' ? <>{t.counter.code} {t.counter.name} → {t.account.name}</> : t.kind === 'spend' ? <>{t.account.name} → {t.counter.code} {t.counter.name}</> : <>{t.account.name} → {t.counter.name}</>}</td>
        <td className="r num">{money(t.amount)}</td>
        <td className="r">{t.status === 'posted' && <button className="btn small ghost" type="button" onClick={() => setVoiding({ t, date: today() })}>Void</button>}{t.status === 'voided' && <span className="pill">Voided</span>}</td></tr>)}</tbody>
    </table></div> : <Empty>No bank or cash transactions in this period. Use Money in for income like rent or interest, owner's capital or a loan received; Money out for bank charges, fuel, petty cash, loan repayments or drawings; Transfer to move money between bank, MoMo and cash.</Empty>}
      <Pager {...pg} noun="transactions" />
    </Panel>}

    {edit && meta && <FormModal title={KIND[edit.kind]} submit="Post" busy={act.busy} onClose={() => setEdit(null)}
      onSave={() => act.run(async () => {
        if (!edit.counter) throw new Error(edit.kind === 'transfer' ? 'Choose the account the money goes to.' : 'Choose the account this is for.');
        await rpc('post_cash_transaction', { cid, p_kind: edit.kind, p_date: edit.date, p_account: edit.account, p_counter: edit.counter, p_amount: Number(edit.amount), p_description: edit.description,
          p_payee: edit.payee || null, p_reference: edit.reference || null, p_branch: edit.branch || null, p_cost_centre: edit.centre || null, p_project: edit.project || null });
        setEdit(null); pg.reload(); reloadBals();
      }, 'Posted to the books')}>
      <div className="grid-form">
        <Select label="Type" id="cx-kind" value={edit.kind} onChange={v => setEdit({ ...edit, kind: v, counter: '' })} options={[['receive', 'Money in'], ['spend', 'Money out'], ['transfer', 'Transfer between my accounts']]} />
        <Field label="Date" id="cx-date" type="date" value={edit.date} onChange={v => setEdit({ ...edit, date: v })} required />
        <Select label={edit.kind === 'receive' ? 'Into' : 'From'} id="cx-acc" value={edit.account} onChange={v => setEdit({ ...edit, account: v })} options={banks.map(b => [b.id, `${b.code} ${b.name}`] as [string, string])} />
        <Select label={edit.kind === 'transfer' ? 'To' : edit.kind === 'receive' ? 'What is it (income, capital, loan…)' : 'What is it for (expense, loan repayment…)'} id="cx-counter" value={edit.counter} onChange={v => setEdit({ ...edit, counter: v })}
          options={[['', 'Choose…'], ...(edit.kind === 'transfer' ? banks.filter(b => b.id !== edit.account) : others.filter(a => edit.kind === 'receive' ? a.type !== 'expense' : true)).map(a => [a.id, `${a.code} ${a.name}`] as [string, string])]} />
        <Field label="Amount (GH₵)" id="cx-amt" type="number" step="0.01" min="0.01" value={edit.amount} onChange={v => setEdit({ ...edit, amount: v })} required />
        {edit.kind !== 'transfer' && <Field label={edit.kind === 'receive' ? 'Received from' : 'Paid to'} id="cx-payee" value={edit.payee} onChange={v => setEdit({ ...edit, payee: v })} />}
        <Field label="Reference (cheque, MoMo or bank ref.)" id="cx-ref" value={edit.reference} onChange={v => setEdit({ ...edit, reference: v })} />
        {meta.branches.length > 0 && <Select label="Branch" id="cx-br" value={edit.branch} onChange={v => setEdit({ ...edit, branch: v })} options={[['', '—'], ...meta.branches.map(b => [b.id, `${b.code} ${b.name}`] as [string, string])]} />}
        {meta.centres.length > 0 && <Select label="Cost centre" id="cx-cc" value={edit.centre} onChange={v => setEdit({ ...edit, centre: v })} options={[['', '—'], ...meta.centres.map(b => [b.id, `${b.code} ${b.name}`] as [string, string])]} />}
        {edit.kind === 'spend' && meta.projects.length > 0 && <Select label="Charge to project" id="cx-pj" value={edit.project} onChange={v => setEdit({ ...edit, project: v })} options={[['', '—'], ...meta.projects.map(b => [b.id, `${b.number || ''} ${b.name}`.trim()] as [string, string])]} />}
      </div>
      <Field label="Description" id="cx-desc" value={edit.description} onChange={v => setEdit({ ...edit, description: v })} placeholder={edit.kind === 'receive' ? 'e.g. Rent for the spare office, November' : edit.kind === 'spend' ? 'e.g. Bank charges, October' : 'e.g. Cash float for Kumasi'} required />
      <p className="muted" style={{ margin: 0, fontSize: 13 }}>Customer receipts belong on the invoice, supplier payments on the bill, and purchases with VAT on a supplier bill, so tax and balances stay right.</p>
    </FormModal>}
    {voiding && <FormModal title={`Void ${voiding.t.number}`} submit="Void" busy={act.busy} onClose={() => setVoiding(null)}
      onSave={() => act.run(async () => { await rpc('void_cash_transaction', { p_id: voiding.t.id, p_date: voiding.date }); setVoiding(null); pg.reload(); reloadBals(); }, 'Voided: a reversing journal was posted')}>
      <p style={{ margin: 0 }}>{voiding.t.description}, {cedis(voiding.t.amount)}. A reversing journal is posted; the original stays in the books for the audit trail.</p>
      <Field label="Date of the reversal" id="vd-date" type="date" value={voiding.date} onChange={v => setVoiding({ ...voiding, date: v })} required />
    </FormModal>}
  </>;
}

// ---------------------------------------------------------------- Approvals inbox
const DOC_NAME: Record<string, string> = { bill: 'Supplier bill', payroll: 'Payroll', purchase_request: 'Purchase request', expense_claim: 'Expense claim' };
export function ApprovalsInboxPage() {
  const { cid, can } = useSession();
  const act = useAction();
  const [reject, setReject] = useState<any | null>(null);
  const { data, error, loading, reload } = useLoad(async () => {
    const [mine, recent] = await Promise.all([
      rpc<any[]>('my_approvals', { cid }),
      q<any[]>(supabase.from('approval_steps').select('*').eq('company_id', cid).neq('status', 'pending').order('decided_at', { ascending: false, nullsFirst: false }).limit(40) as any),
    ]);
    return { mine, recent };
  }, [cid]);
  if (!data) return <Loading error={error} loading={loading} />;
  return <>
    <PageHead title="Waiting for my approval" sub={`${data.mine.length} item${data.mine.length === 1 ? '' : 's'}. Approval chains are set under Settings & team → Approval rules.`} />
    <Panel>{data.mine.length ? <div className="scroll"><table>
      <thead><tr><th>Document</th><th className="r">Amount (GH₵)</th><th>Step</th><th>Waiting since</th><th></th></tr></thead>
      <tbody>{data.mine.map(s => <tr key={s.step_id}>
        <td className="wrap-cell"><span className="pill">{DOC_NAME[s.doc_type]}</span> {s.path ? <Link to={s.path}>{s.doc_label}</Link> : s.doc_label}
          {s.requested_email && <><br /><span className="muted" style={{ fontSize: 12 }}>Submitted by {s.requested_email}</span></>}</td>
        <td className="r num">{money(s.amount)}</td><td>{s.step_label}<br /><span className="muted" style={{ fontSize: 12 }}>Step {s.step_no} of {s.steps_total}</span></td>
        <td className="num">{String(s.waiting_since).slice(0, 16).replace('T', ' ')}</td>
        <td className="r"><span className="actions" style={{ justifyContent: 'flex-end' }}>
          <button className="btn small primary" type="button" disabled={act.busy} onClick={() => act.run(async () => { await rpc('decide_approval', { p_step: s.step_id, p_approve: true, p_note: null }); reload(); }, 'Approved')}>Approve</button>
          <button className="btn small" type="button" onClick={() => setReject({ s, note: '' })}>Reject</button></span></td></tr>)}</tbody>
    </table></div> : <Empty>Nothing is waiting for you.</Empty>}</Panel>
    {can('accountant') && <Panel title="Recent decisions">{data.recent.length ? <div className="scroll"><table>
      <thead><tr><th>When</th><th>Document</th><th>Step</th><th className="r">Amount</th><th>Decision</th></tr></thead>
      <tbody>{data.recent.map(s => <tr key={s.id}><td className="num">{s.decided_at ? s.decided_at.slice(0, 16).replace('T', ' ') : ''}</td><td>{DOC_NAME[s.doc_type]}</td>
        <td>{s.label}</td><td className="r num">{money(s.amount)}</td>
        <td><span className={'pill ' + (s.status === 'approved' ? 'good' : s.status === 'rejected' ? 'bad' : '')}>{s.status}</span> <span className="muted" style={{ fontSize: 12 }}>{s.decided_email}{s.note ? ' · ' + s.note : ''}</span></td></tr>)}</tbody>
    </table></div> : <Empty>No decisions yet.</Empty>}</Panel>}
    {reject && <FormModal title="Reject" submit="Reject" busy={act.busy} onClose={() => setReject(null)}
      onSave={() => act.run(async () => { await rpc('decide_approval', { p_step: reject.s.step_id, p_approve: false, p_note: reject.note }); setReject(null); reload(); }, 'Rejected')}>
      <p style={{ margin: 0 }}>{reject.s.doc_label}, {cedis(reject.s.amount)}</p>
      <Field label="Reason (the submitter sees this)" id="ia-note" value={reject.note} onChange={v => setReject({ ...reject, note: v })} required />
    </FormModal>}
  </>;
}

/** Approval status, steps and the Submit button for a bill or a payroll run. */
export function ApprovalBox({ docType, docId, onChange }: { docType: 'bill' | 'payroll' | 'purchase_order'; docId: string; onChange?: () => void }) {
  const act = useAction();
  const { data, reload } = useLoad(async () => {
    const [state, steps] = await Promise.all([
      rpc<string>('approval_state', { p_type: docType, p_id: docId }),
      q<any[]>(supabase.from('approval_steps').select('*').eq('doc_type', docType).eq('doc_id', docId).order('step_no') as any),
    ]);
    return { state, steps };
  }, [docType, docId]);
  if (!data || data.state === 'not_required') return null;
  const LABEL: Record<string, [string, string]> = { not_started: ['Needs approval before posting', 'warn'], pending: ['Waiting for approval', 'warn'], approved: ['Approved', 'good'], rejected: ['Rejected', 'bad'], changed: ['Changed after approval: submit again', 'warn'] };
  const [l, c] = LABEL[data.state] || [data.state, ''];
  return <Panel title={<div className="actions"><h2>Approval</h2><span className={'pill ' + c}>{l}</span></div>}
    actions={['not_started', 'rejected', 'changed'].includes(data.state) && <button className="btn small primary" type="button" disabled={act.busy}
      onClick={() => act.run(async () => { await rpc('start_approval', { p_type: docType, p_id: docId }); reload(); onChange?.(); }, 'Sent for approval')}>Submit for approval</button>}>
    {data.steps.length > 0 && <div className="scroll"><table><tbody>{data.steps.map(s => <tr key={s.id}>
      <td className="num" style={{ width: 60 }}>Step {s.step_no}</td><td>{s.label}</td>
      <td><span className={'pill ' + (s.status === 'approved' ? 'good' : s.status === 'rejected' ? 'bad' : s.status === 'pending' ? 'warn' : '')}>{s.status}</span></td>
      <td className="muted" style={{ fontSize: 12 }}>{s.decided_email}{s.decided_at ? ' · ' + s.decided_at.slice(0, 16).replace('T', ' ') : ''}{s.note ? ' · ' + s.note : ''}</td></tr>)}</tbody></table></div>}
  </Panel>;
}

// ---------------------------------------------------------------- Audit trail
const TABLES: [string, string][] = [['', 'Everything'], ['invoices', 'Invoices'], ['payments', 'Customer receipts'], ['credit_notes', 'Credit notes'], ['bills', 'Supplier bills'],
  ['bill_payments', 'Supplier payments'], ['cash_transactions', 'Bank & cash'], ['payroll_runs', 'Payroll'], ['employees', 'Employees'], ['customers', 'Customers'], ['suppliers', 'Suppliers'],
  ['products', 'Products'], ['accounts', 'Chart of accounts'], ['expense_claims', 'Expense claims'], ['project_requests', 'Purchase requests'], ['memberships', 'Team and roles'],
  ['companies', 'Company settings'], ['approval_rules', 'Approval rules'], ['bill', 'Approvals: bills'], ['payroll', 'Approvals: payroll'], ['assets', 'Assets'],
  ['purchase_orders', 'Purchase orders'], ['stock_issues', 'Stock issues'], ['stock_transfers', 'Stock transfers'], ['stock_counts', 'Stocktakes'], ['warehouses', 'Warehouses'], ['purchase_order', 'Approvals: purchase orders']];
const show = (v: any) => (v === null || v === undefined ? '—' : typeof v === 'object' ? JSON.stringify(v) : String(v));

export function AuditPage() {
  const { cid, company } = useSession();
  const act = useAction();
  const [from, setFrom] = useState(today().slice(0, 8) + '01');
  const [to, setTo] = useState(today());
  const [table, setTable] = useState('');
  const [user, setUser] = useState('');
  const [search, setSearch] = useState('');
  const args = (a: number, b: number) => ({ cid, p_from: from, p_to: to, p_table: table || null, p_user: user || null, p_search: search || null, p_row: null, p_limit: b - a + 1, p_offset: a });
  const pg = usePaged(async (a, b) => { const rows = await rpc<any[]>('audit_trail', args(a, b)); return { rows, total: Number(rows[0]?.total || 0) }; }, [cid, from, to, table, user, search], 100);
  const changes = (r: any) => {
    if (r.detail && !r.old_data && !r.new_data) return Object.entries(r.detail).map(([k, v]) => `${k}: ${show(v)}`).join(' · ');
    if (r.action.endsWith('.insert')) return 'Created';
    if (r.action.endsWith('.delete')) return 'Deleted: ' + (r.old_data?.name || r.old_data?.number || r.old_data?.description || r.old_data?.email || '');
    return Object.keys(r.new_data || {}).map(k => `${k}: ${show(r.old_data?.[k])} → ${show(r.new_data[k])}`).join(' · ');
  };
  const head = ['When', 'Who', 'Action', 'Record', 'Changes'];
  const download = (kind: 'pdf' | 'csv') => act.run(async () => {
    const all: any[] = []; for (let a = 0; a < 20000; a += 1000) { const r = await rpc<any[]>('audit_trail', args(a, a + 999)); all.push(...r); if (r.length < 1000) break; }
    const body = all.map(r => [r.created_at.slice(0, 19).replace('T', ' '), r.user_email || 'system', r.action, r.row_id || '', changes(r)]);
    if (kind === 'csv') return downloadCsv(`audit-trail-${from}-${to}`, head, body);
    tablePdf({ company: company!, title: 'Audit trail', subtitle: `${longDate(from)} to ${longDate(to)}`, head, body, landscape: true, filename: `audit-trail-${from}-${to}` });
  });
  return <>
    <PageHead title="Audit trail" sub="Who created, changed or deleted what, and when — with the old and new values. Entries cannot be edited or removed.">
      <Downloads pdf={() => download('pdf')} csv={() => download('csv')} />
    </PageHead>
    <div className="filters">
      <Field label="From" id="au-from" type="date" value={from} onChange={setFrom} />
      <Field label="To" id="au-to" type="date" value={to} onChange={setTo} />
      <Select label="Area" id="au-table" value={table} onChange={setTable} options={TABLES} />
      <SearchBox value={user} onChange={setUser} placeholder="Email" id="au-user" width={180} label="Person" />
      <SearchBox value={search} onChange={setSearch} placeholder="Any value, e.g. INV-00012" id="au-search" width={200} label="Containing" />
    </div>
    <Loading error={pg.error} loading={pg.loading && !pg.data} />
    {pg.data && <Panel>{pg.rows.length ? <div className="scroll"><table>
      <thead><tr><th style={{ width: 140 }}>When</th><th>Who</th><th>Action</th><th>Changes</th></tr></thead>
      <tbody>{pg.rows.map((r: any) => <tr key={r.id}><td className="num" style={{ fontSize: 13 }}>{r.created_at.slice(0, 19).replace('T', ' ')}</td>
        <td style={{ fontSize: 13 }}>{r.user_email || <span className="muted">system</span>}</td>
        <td><span className={'pill ' + (r.action.endsWith('.delete') || r.action.endsWith('rejected') ? 'bad' : r.action.endsWith('.insert') ? 'good' : '')}>{r.action}</span></td>
        <td className="wrap-cell" style={{ fontSize: 13, maxWidth: 520 }}>{changes(r)}</td></tr>)}</tbody>
    </table></div> : <Empty>Nothing recorded with these filters.</Empty>}
      <Pager {...pg} noun="entries" />
    </Panel>}
  </>;
}


