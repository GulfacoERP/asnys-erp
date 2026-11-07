import { ApprovalBox } from './Finance';
import { useEffect, useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { q, rpc, supabase } from '../lib/supabase';
import { useSession } from '../lib/session';
import { cedis, money, monthName, today } from '../lib/format';
import { downloadCsv } from '../lib/download';
import { allPayslipsPdf, payslipPdf, tablePdf } from '../lib/pdf';
import { ConfirmButton, Downloads, Empty, Field, FormModal, Loading, PageHead, Panel, Select, Status, useAction, useLoad } from '../components/ui';

export function PayrollPage() {
  const { cid, can, company } = useSession();
  const nav = useNavigate();
  const act = useAction();
  const [month, setMonth] = useState(today().slice(0, 7));
  const [loan, setLoan] = useState<any | null>(null);
  const { data, error, loading, reload } = useLoad(async () => {
    const [runs, loans, staff] = await Promise.all([
      q<any[]>(supabase.from('payroll_runs').select('*').eq('company_id', cid).order('period', { ascending: false }) as any),
      q<any[]>(supabase.from('employee_loans').select('*, emp:employees(full_name)').eq('company_id', cid).order('issue_date', { ascending: false }) as any),
      q<any[]>(supabase.from('employees').select('id,full_name').eq('company_id', cid).eq('status', 'active').order('full_name') as any),
    ]);
    return { runs, loans, staff };
  }, [cid]);
  const lHead = ['Employee', 'Issued', 'Loan (GHS)', 'Monthly deduction', 'Balance', 'Status', 'Note'];
  const lRows = (data?.loans || []).map(l => [l.emp?.full_name, l.issue_date, money(l.principal), money(l.installment), money(l.balance), l.status, l.note || '']);

  return <>
    <PageHead title="Payroll" sub="PAYE: Act 1178 monthly bands. SSNIT 5.5% / 13% of basic. Overtime and bonus final taxes, Tier 3 relief and staff loans are applied automatically.">
      <div className="field" style={{ width: 160 }}><label htmlFor="pr-month">Month</label><input id="pr-month" type="month" value={month} onChange={e => setMonth(e.target.value)} /></div>
      {can('hr', 'accountant') && <button className="btn primary" type="button" style={{ alignSelf: 'end' }} disabled={act.busy}
        onClick={() => act.run(async () => { const id = await rpc<string>('prepare_payroll', { cid, p_period: month + '-01' }); nav('/payroll/' + id); }, 'Payroll prepared')}>Prepare payroll</button>}
    </PageHead>
    <Loading error={error} loading={loading && !data} />
    {data && <Panel title="Payroll months">{data.runs.length ? <div className="scroll"><table>
      <thead><tr><th>Month</th><th className="r">Gross (GH₵)</th><th className="r">Taxes</th><th className="r">SSNIT staff</th><th className="r">SSNIT employer</th><th className="r">Net pay</th><th>Status</th></tr></thead>
      <tbody>{data.runs.map(r => <tr key={r.id} className="click" tabIndex={0} onClick={() => nav('/payroll/' + r.id)} onKeyDown={e => e.key === 'Enter' && nav('/payroll/' + r.id)}>
        <td>{monthName(r.period)}</td><td className="r num">{money(r.gross)}</td><td className="r num">{money(r.paye)}</td>
        <td className="r num">{money(r.ssnit_employee)}</td><td className="r num">{money(r.ssnit_employer)}</td><td className="r num">{money(r.net)}</td>
        <td><Status s={r.status} kind="payroll" /></td></tr>)}</tbody>
    </table></div> : <Empty>No payroll yet. Add employees with their basic salary, pick a month and choose Prepare payroll.</Empty>}</Panel>}

    {data && <Panel title="Staff loans and advances" actions={<>
      <Downloads pdf={() => tablePdf({ company: company!, title: 'Staff loans', head: lHead, body: lRows, rightAlign: [2, 3, 4], filename: 'staff-loans' })} csv={() => downloadCsv('staff-loans', lHead, lRows)} />
      {can('accountant') && <button className="btn small primary" type="button" disabled={!data.staff.length} onClick={() => setLoan({ employee_id: data.staff[0].id, principal: '', installment: '', date: today(), method: 'bank', note: '' })}>Issue loan</button>}</>}>
      {data.loans.length ? <div className="scroll"><table>
        <thead><tr><th>Employee</th><th>Issued</th><th className="r">Loan (GH₵)</th><th className="r">Monthly</th><th className="r">Balance</th><th>Status</th></tr></thead>
        <tbody>{data.loans.map(l => <tr key={l.id}><td>{l.emp?.full_name}{l.note && <span className="muted"> · {l.note}</span>}</td><td className="num">{l.issue_date}</td>
          <td className="r num">{money(l.principal)}</td><td className="r num">{money(l.installment)}</td><td className="r num">{money(l.balance)}</td>
          <td><span className={'pill ' + (l.status === 'active' ? 'warn' : 'good')}>{l.status === 'active' ? 'Repaying' : 'Settled'}</span></td></tr>)}</tbody>
      </table></div> : <Empty>No staff loans. Loans are repaid through payroll at the monthly amount you set.</Empty>}
    </Panel>}

    {loan && data && <FormModal title="Issue staff loan" submit="Issue and post" busy={act.busy} onClose={() => setLoan(null)}
      onSave={() => act.run(async () => {
        await rpc('issue_loan', { p_employee: loan.employee_id, p_principal: Number(loan.principal), p_installment: Number(loan.installment), p_date: loan.date, p_method: loan.method, p_note: loan.note || null });
        setLoan(null); reload();
      }, 'Loan issued and posted')}>
      <Select label="Employee" id="ln-emp" value={loan.employee_id} onChange={v => setLoan({ ...loan, employee_id: v })} options={data.staff.map(s => [s.id, s.full_name])} />
      <div className="grid-form">
        <Field label="Loan amount (GH₵)" id="ln-amt" type="number" step="0.01" min="1" value={loan.principal} onChange={v => setLoan({ ...loan, principal: v })} required />
        <Field label="Deduct each month (GH₵)" id="ln-inst" type="number" step="0.01" min="1" value={loan.installment} onChange={v => setLoan({ ...loan, installment: v })} required />
        <Field label="Date paid out" id="ln-date" type="date" value={loan.date} onChange={v => setLoan({ ...loan, date: v })} required />
        <Select label="Paid from" id="ln-m" value={loan.method} onChange={v => setLoan({ ...loan, method: v })} options={[['bank', 'Bank'], ['momo', 'Mobile Money'], ['cash', 'Cash']]} />
      </div>
      <Field label="Note" id="ln-note" value={loan.note} onChange={v => setLoan({ ...loan, note: v })} placeholder="e.g. School fees advance" />
      {Number(loan.principal) > 0 && Number(loan.installment) > 0 && <p className="muted" style={{ margin: 0 }}>Repaid in about {Math.ceil(Number(loan.principal) / Number(loan.installment))} months.</p>}
    </FormModal>}
  </>;
}

export function PayrollRunPage() {
  const { id } = useParams();
  const { cid, company, can } = useSession();
  const act = useAction();
  const [method, setMethod] = useState('bank');
  const [inputs, setInputs] = useState<Record<string, { overtime: string; bonus: string }>>({});
  const { data, error, loading, reload } = useLoad(async () => {
    const run = await q<any>(supabase.from('payroll_runs').select('*').eq('id', id).single() as any);
    const [slips, ins] = await Promise.all([
      q<any[]>(supabase.from('payslips').select('*, emp:employees(*)').eq('run_id', id) as any),
      q<any[]>(supabase.from('payroll_inputs').select('*').eq('company_id', run.company_id).eq('period', run.period) as any),
    ]);
    slips.sort((a, b) => a.emp.full_name.localeCompare(b.emp.full_name));
    return { run, slips, ins };
  }, [id]);
  useEffect(() => {
    if (!data) return;
    const m: Record<string, { overtime: string; bonus: string }> = {};
    data.slips.forEach(s => { const i = data.ins.find(x => x.employee_id === s.employee_id); m[s.employee_id] = { overtime: i ? String(i.overtime) : '', bonus: i ? String(i.bonus) : '' }; });
    setInputs(m);
  }, [data]);
  if (!data) return <Loading error={error} loading={loading} />;
  const { run, slips } = data;
  const period = monthName(run.period);
  const tag = run.period.slice(0, 7);
  const n = (s: any, k: string) => Number(s[k] || 0);
  const sum = (k: string) => slips.reduce((a, s) => a + n(s, k), 0);
  const tax = (s: any) => n(s, 'paye') + n(s, 'overtime_tax') + n(s, 'bonus_tax');
  const c = company!;
  const draft = run.status === 'draft';

  const saveInputs = () => act.run(async () => {
    const rows = Object.entries(inputs).map(([employee_id, v]) => ({ company_id: cid, period: run.period, employee_id, overtime: Number(v.overtime) || 0, bonus: Number(v.bonus) || 0 }));
    await q(supabase.from('payroll_inputs').upsert(rows) as any);
    await rpc('prepare_payroll', { cid, p_period: run.period });
    reload();
  }, 'Overtime and bonuses applied; payslips recalculated');

  const paye = {
    head: ['Staff no.', 'Name', 'TIN / Ghana Card', 'Basic', 'Allowances', 'Overtime', 'Bonus', 'SSNIT 5.5%', 'Tier 3', 'Chargeable', 'PAYE', 'Overtime tax', 'Bonus tax', 'Total tax (GHS)'],
    rows: slips.map(s => [s.emp.staff_no || '', s.emp.full_name, s.emp.tin || s.emp.ghana_card || '', money(s.basic), money(s.allowances), money(s.overtime), money(s.bonus),
      money(s.ssnit_employee), money(s.tier3_employee), money(s.chargeable), money(s.paye), money(s.overtime_tax), money(s.bonus_tax), money(tax(s))]),
    foot: ['', 'Totals', '', money(sum('basic')), money(sum('allowances')), money(sum('overtime')), money(sum('bonus')), money(sum('ssnit_employee')), money(sum('tier3_employee')),
      money(sum('chargeable')), money(sum('paye')), money(sum('overtime_tax')), money(sum('bonus_tax')), money(sum('paye') + sum('overtime_tax') + sum('bonus_tax'))],
  };
  const ssnit = {
    head: ['SSNIT no.', 'Ghana Card', 'Name', 'Basic salary', 'Employee 5.5%', 'Employer 13%', 'Total 18.5%', 'Tier 1 to SSNIT 13.5%', 'Tier 2 5% (GHS)'],
    rows: slips.map(s => [s.emp.ssnit_no || '', s.emp.ghana_card || '', s.emp.full_name, money(s.basic), money(s.ssnit_employee), money(s.ssnit_employer), money(n(s, 'ssnit_employee') + n(s, 'ssnit_employer')), money(s.tier1), money(s.tier2)]),
    foot: ['', '', 'Totals', money(sum('basic')), money(sum('ssnit_employee')), money(sum('ssnit_employer')), money(sum('ssnit_employee') + sum('ssnit_employer')), money(sum('tier1')), money(sum('tier2'))],
  };
  const tier3 = {
    head: ['Name', 'SSNIT no.', 'Basic salary', 'Employee Tier 3', 'Employer Tier 3', 'Total (GHS)'],
    rows: slips.filter(s => n(s, 'tier3_employee') + n(s, 'tier3_employer') > 0).map(s => [s.emp.full_name, s.emp.ssnit_no || '', money(s.basic), money(s.tier3_employee), money(s.tier3_employer), money(n(s, 'tier3_employee') + n(s, 'tier3_employer'))]),
  };
  const bank = {
    head: ['Name', 'Bank', 'Account no.', 'MoMo number', 'Net pay (GHS)', 'Reference'],
    rows: slips.map(s => [s.emp.full_name, s.emp.bank_name || '', s.emp.bank_account || '', s.emp.momo_number || '', money(s.net), `Salary ${tag}`]),
  };
  // Bulk payment files: bank transfers for staff paid by bank, a MoMo bulk list for staff paid by MoMo.
  const byBank = slips.filter(s => (s.emp.pay_method || 'bank') === 'bank');
  const byMomo = slips.filter(s => s.emp.pay_method === 'momo');
  const missing = slips.filter(s => ((s.emp.pay_method || 'bank') === 'bank' && !s.emp.bank_account) || (s.emp.pay_method === 'momo' && !s.emp.momo_number));
  const bankFile = () => downloadCsv(`salary-bank-transfers-${tag}`, ['Beneficiary name', 'Bank', 'Branch', 'Account number', 'Amount', 'Narration', 'Staff no.'],
    [...byBank.map(s => [s.emp.full_name, s.emp.bank_name || '', s.emp.bank_branch || '', s.emp.bank_account || '', Number(s.net).toFixed(2), `Salary ${tag}`, s.emp.staff_no || '']),
     ['TOTAL', '', '', '', byBank.reduce((a, s) => a + n(s, 'net'), 0).toFixed(2), `${byBank.length} transfers`, '']]);
  const momoFile = () => downloadCsv(`salary-momo-bulk-${tag}`, ['Phone number', 'Name', 'Amount', 'Reference'],
    byMomo.map(s => [(s.emp.momo_number || '').replace(/\D/g, '').replace(/^0/, '233'), s.emp.full_name, Number(s.net).toFixed(2), `Salary ${tag}`]));

  return <>
    <PageHead title={`Payroll · ${period}`} sub={<><Status s={run.status} kind="payroll" /> <span className="muted">· {slips.length} payslips</span></>}>
      <Link className="btn" to="/payroll">Back</Link>
      {draft && can('hr', 'accountant') && <button className="btn" type="button" disabled={act.busy} onClick={() => act.run(async () => { await rpc('prepare_payroll', { cid, p_period: run.period }); reload(); }, 'Recalculated from current salaries')}>Recalculate</button>}
      {draft && can('accountant') && <ConfirmButton className="btn primary" label="Approve and post" confirm="Post to the ledger? It cannot be edited after." onConfirm={() => act.run(async () => { await rpc('post_payroll', { p_run: id }); reload(); }, 'Payroll posted')} />}
      {run.status === 'posted' && can('accountant') && <>
        <select aria-label="Pay from" value={method} onChange={e => setMethod(e.target.value)} style={{ width: 'auto' }}><option value="bank">From bank</option><option value="momo">From MoMo</option><option value="cash">Cash</option></select>
        <button className="btn primary" type="button" disabled={act.busy} onClick={() => act.run(async () => { await rpc('pay_payroll', { p_run: id, p_method: method, p_date: today() }); reload(); }, 'Salaries marked as paid')}>Mark salaries paid</button></>}
    </PageHead>
    {draft && <ApprovalBox docType="payroll" docId={id!} />}
    <div className="tiles">
      <div className="tile"><span>Gross pay</span><b>{cedis(run.gross)}</b></div>
      <div className="tile"><span>PAYE + overtime/bonus tax to GRA</span><b>{cedis(run.paye)}</b></div>
      <div className="tile"><span>Tier 1 to SSNIT</span><b>{cedis(sum('tier1'))}</b></div>
      <div className="tile"><span>Tier 2 to trustee</span><b>{cedis(sum('tier2'))}</b></div>
      <div className="tile"><span>Net pay to staff</span><b>{cedis(run.net)}</b></div>
    </div>

    {draft && can('hr') && slips.length > 0 && <Panel title="Overtime and bonuses this month" actions={<button className="btn small primary" type="button" disabled={act.busy} onClick={saveInputs}>Apply and recalculate</button>}>
      <div className="scroll"><table className="lines">
        <thead><tr><th>Employee</th><th>Grade</th><th className="r">Overtime (GH₵)</th><th className="r">Bonus (GH₵)</th></tr></thead>
        <tbody>{slips.map(s => <tr key={s.employee_id}><td>{s.emp.full_name}</td>
          <td>{s.emp.is_junior ? <span className="pill">Junior staff</span> : <span className="muted">Senior</span>}</td>
          <td className="r"><input aria-label={`Overtime for ${s.emp.full_name}`} type="number" step="0.01" min="0" style={{ width: 120, textAlign: 'right' }} value={inputs[s.employee_id]?.overtime ?? ''}
            onChange={e => setInputs({ ...inputs, [s.employee_id]: { ...inputs[s.employee_id], overtime: e.target.value } })} /></td>
          <td className="r"><input aria-label={`Bonus for ${s.emp.full_name}`} type="number" step="0.01" min="0" style={{ width: 120, textAlign: 'right' }} value={inputs[s.employee_id]?.bonus ?? ''}
            onChange={e => setInputs({ ...inputs, [s.employee_id]: { ...inputs[s.employee_id], bonus: e.target.value } })} /></td></tr>)}</tbody>
      </table></div>
      <div className="body muted" style={{ fontSize: 13 }}>Junior staff earning up to GH₵18,000 a year pay 5% on overtime up to half their monthly basic and 10% above; others' overtime goes through PAYE. Bonuses pay 5% up to 15% of annual basic (counted across the year); the excess goes through PAYE.</div>
    </Panel>}

    <Panel title="Downloads" pad>
      <div className="actions">
        <button className="btn primary" type="button" disabled={!slips.length} onClick={() => allPayslipsPdf(c, run.period, slips.map(s => ({ slip: s, emp: s.emp })))}>All payslips (PDF)</button>
        <button className="btn" type="button" onClick={() => tablePdf({ company: c, title: 'PAYE schedule', subtitle: period, head: paye.head, body: paye.rows, foot: paye.foot, rightAlign: [3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13], landscape: true, filename: `paye-schedule-${tag}`, notes: 'File with GRA and pay by the 15th of the following month. Overtime and bonus taxes are final taxes remitted with PAYE.' })}>PAYE schedule PDF</button>
        <button className="btn" type="button" onClick={() => downloadCsv(`paye-schedule-${tag}`, paye.head, [...paye.rows, paye.foot])}>PAYE CSV</button>
        <button className="btn" type="button" onClick={() => tablePdf({ company: c, title: 'SSNIT contribution schedule', subtitle: period, head: ssnit.head, body: ssnit.rows, foot: ssnit.foot, rightAlign: [3, 4, 5, 6, 7, 8], landscape: true, filename: `ssnit-schedule-${tag}`, notes: 'Remit Tier 1 (13.5%) to SSNIT within 14 days of the following month; Tier 2 (5%) to your trustee.' })}>SSNIT schedule PDF</button>
        <button className="btn" type="button" onClick={() => downloadCsv(`ssnit-schedule-${tag}`, ssnit.head, [...ssnit.rows, ssnit.foot])}>SSNIT CSV</button>
        {tier3.rows.length > 0 && <button className="btn" type="button" onClick={() => tablePdf({ company: c, title: 'Tier 3 contributions', subtitle: period, head: tier3.head, body: tier3.rows, rightAlign: [2, 3, 4, 5], filename: `tier3-schedule-${tag}` })}>Tier 3 schedule PDF</button>}
        <button className="btn" type="button" onClick={() => downloadCsv(`salary-payment-list-${tag}`, bank.head, bank.rows)}>Payment list CSV</button>
        {byBank.length > 0 && <button className="btn" type="button" onClick={bankFile}>Bank transfer file ({byBank.length})</button>}
        {byMomo.length > 0 && <button className="btn" type="button" onClick={momoFile}>MoMo bulk file ({byMomo.length})</button>}
      </div>
      {missing.length > 0 && <p style={{ color: 'var(--bad)', fontSize: 13, marginBottom: 0 }}>{missing.length} employee{missing.length === 1 ? ' has' : 's have'} no {missing.length === 1 ? 'account' : 'accounts'} for their payment method: {missing.slice(0, 6).map(s => s.emp.full_name).join(', ')}{missing.length > 6 ? '…' : ''}. Add them under Employees.</p>}
      <p className="muted" style={{ fontSize: 13, marginBottom: 0 }}>Check your bank's bulk-upload layout; most accept these columns or let you map them. The salary cost is split by each employee's branch and cost centre in the books.</p>
    </Panel>

    <Panel title="Payslips">{slips.length ? <div className="scroll"><table>
      <thead><tr><th>Employee</th><th className="r">Basic</th><th className="r">Allowances</th><th className="r">Overtime</th><th className="r">Bonus</th><th className="r">SSNIT + Tier 3</th><th className="r">All taxes</th><th className="r">Loan</th><th className="r">Net pay</th><th></th></tr></thead>
      <tbody>{slips.map(s => <tr key={s.id}>
        <td><b>{s.emp.full_name}</b><br /><span className="muted">{s.emp.job_title}</span></td>
        <td className="r num">{money(s.basic)}</td><td className="r num">{money(s.allowances)}</td><td className="r num">{money(s.overtime)}</td><td className="r num">{money(s.bonus)}</td>
        <td className="r num">{money(n(s, 'ssnit_employee') + n(s, 'tier3_employee'))}</td><td className="r num">{money(tax(s))}</td><td className="r num">{money(s.loan_deduction)}</td>
        <td className="r num"><b>{money(s.net)}</b></td>
        <td className="r"><button className="btn small" type="button" onClick={() => payslipPdf(c, run.period, s, s.emp)}>Payslip PDF</button></td></tr>)}</tbody>
      <tfoot><tr><td>Totals (GH₵)</td><td className="r num">{money(sum('basic'))}</td><td className="r num">{money(sum('allowances'))}</td><td className="r num">{money(sum('overtime'))}</td><td className="r num">{money(sum('bonus'))}</td>
        <td className="r num">{money(sum('ssnit_employee') + sum('tier3_employee'))}</td><td className="r num">{money(sum('paye') + sum('overtime_tax') + sum('bonus_tax'))}</td><td className="r num">{money(sum('loan_deduction'))}</td>
        <td className="r num">{money(sum('net'))}</td><td /></tr></tfoot>
    </table></div> : <Empty>No active employees had pay for this month.</Empty>}</Panel>
    {!draft && <p className="muted" style={{ margin: 0 }}>Record payments of PAYE to GRA, SSNIT and Tier 3 with a manual journal (debit the payable, credit bank).</p>}
  </>;
}
