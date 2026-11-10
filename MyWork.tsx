import { useRef, useState } from 'react';
import { rpc, supabase } from '../lib/supabase';
import { useSession } from '../lib/session';
import { money, today } from '../lib/format';
import { downloadCsv } from '../lib/download';
import { tablePdf } from '../lib/pdf';
import { uploadReceipt } from '../lib/receipt';
import { Empty, Field, Loading, Panel, Select, Status, useAction, useLoad } from '../components/ui';

/** Mobile-first screen for staff in the field: log hours and expenses, see what was approved. */
export function MyWorkPage({ standalone }: { standalone?: boolean }) {
  const { session, company } = useSession();
  const act = useAction();
  const [tab, setTab] = useState<'time' | 'expense'>('time');
  const fileRef = useRef<HTMLInputElement>(null);
  const [file, setFile] = useState<File | null>(null);
  const { data, error, loading, reload } = useLoad(() => rpc<any>('my_work', {}), []);
  const [t, setT] = useState({ project_id: '', task_id: '', work_date: today(), hours: '', note: '', billable: true });
  const [x, setX] = useState({ project_id: '', expense_date: today(), description: '', merchant: '', currency: 'GHS', amount: '', exchange_rate: '', account_id: '', billable: true });

  if (!data) return <Loading error={error} loading={loading} />;
  if (!data.employees.length) return <div className="panel body"><h2 style={{ fontSize: 18 }}>Your login is not linked to an employee record</h2>
    <p className="muted">Ask HR to open your employee record and enter <b>{session?.user.email}</b> under Sign-in email. Then reload this page.</p></div>;

  const proj = (id: string) => data.projects.find((p: any) => p.id === id);
  const xCompany = x.project_id ? proj(x.project_id)?.company_id : data.employees[0].company_id;
  const currencies = ['GHS', ...Array.from(new Set<string>(data.currencies.filter((c: any) => c.company_id === xCompany).map((c: any) => c.code)))];
  const defaultRate = (code: string) => data.currencies.find((c: any) => c.company_id === xCompany && c.code === code)?.rate;
  const cats = data.categories.filter((c: any) => c.company_id === xCompany);
  const weekHours = data.time.filter((r: any) => r.work_date >= new Date(Date.now() - 6 * 864e5).toISOString().slice(0, 10)).reduce((s: number, r: any) => s + Number(r.hours), 0);
  const owed = data.expenses.filter((e: any) => e.status === 'approved').reduce((s: number, e: any) => s + Number(e.amount_home), 0);

  const submitTime = () => act.run(async () => {
    if (!t.project_id) throw new Error('Choose a project.');
    await rpc('submit_time', { p_project: t.project_id, p_date: t.work_date, p_hours: Number(t.hours), p_task: t.task_id || null, p_note: t.note || null, p_billable: t.billable });
    setT({ ...t, hours: '', note: '' }); reload();
  }, 'Hours sent for approval');
  const submitExpense = () => act.run(async () => {
    if (!(Number(x.amount) > 0)) throw new Error('Enter the amount.');
    const receipt_path = file ? await uploadReceipt(file, session!.user.id) : null;
    await rpc('submit_expense', { p: { ...x, project_id: x.project_id || null, company_id: xCompany, exchange_rate: x.currency === 'GHS' ? 1 : (x.exchange_rate || defaultRate(x.currency) || null), receipt_path } });
    setX({ ...x, description: '', merchant: '', amount: '', exchange_rate: '' }); setFile(null); if (fileRef.current) fileRef.current.value = '';
    reload();
  }, 'Expense sent for approval');
  const withdraw = (id: string) => act.run(async () => { await supabase.from('expense_claims').delete().eq('id', id); reload(); }, 'Withdrawn');

  const eHead = ['Date', 'Description', 'Project', 'Currency', 'Amount', 'GHS', 'Status'];
  const eRows = data.expenses.map((e: any) => [e.expense_date, e.description, e.project || '', e.currency, money(e.amount), money(e.amount_home), e.status]);

  return <div style={{ display: 'grid', gap: 14, maxWidth: 640, margin: '0 auto', width: '100%' }}>
    {!standalone && <div className="head"><div><h1>My time & expenses</h1><p>{data.employees.map((e: any) => e.company).join(' · ')}</p></div></div>}
    <div className="tiles" style={{ gridTemplateColumns: 'repeat(2, minmax(0,1fr))' }}>
      <div className="tile"><span>Hours, last 7 days</span><b>{weekHours}</b></div>
      <div className="tile"><span>Approved, awaiting refund</span><b>GH₵ {money(owed)}</b></div>
    </div>
    <div className="actions">
      <button type="button" className={'btn' + (tab === 'time' ? ' primary' : '')} style={{ flex: 1 }} onClick={() => setTab('time')}>Log hours</button>
      <button type="button" className={'btn' + (tab === 'expense' ? ' primary' : '')} style={{ flex: 1 }} onClick={() => setTab('expense')}>Add expense</button>
    </div>

    {tab === 'time' && <Panel pad><form style={{ display: 'grid', gap: 12 }} onSubmit={e => { e.preventDefault(); submitTime(); }}>
      <Select label="Project" id="mt-proj" value={t.project_id} onChange={v => setT({ ...t, project_id: v, task_id: '' })} options={[['', 'Choose…'], ...data.projects.map((p: any) => [p.id, `${p.name} · ${p.company}`] as [string, string])]} required />
      {t.project_id && data.tasks.some((k: any) => k.project_id === t.project_id) && <Select label="Task" id="mt-task" value={t.task_id} onChange={v => setT({ ...t, task_id: v })}
        options={[['', 'General'], ...data.tasks.filter((k: any) => k.project_id === t.project_id).map((k: any) => [k.id, k.title] as [string, string])]} />}
      <div className="grid-form" style={{ gridTemplateColumns: '1fr 1fr' }}>
        <Field label="Date" id="mt-date" type="date" value={t.work_date} onChange={v => setT({ ...t, work_date: v })} required />
        <Field label="Hours" id="mt-hours" type="number" step="0.25" min="0.25" max="24" inputMode="decimal" value={t.hours} onChange={v => setT({ ...t, hours: v })} required />
      </div>
      <Field label="What did you work on?" id="mt-note" value={t.note} onChange={v => setT({ ...t, note: v })} />
      <label className="check"><input type="checkbox" checked={t.billable} onChange={e => setT({ ...t, billable: e.target.checked })} /> Billable to the client</label>
      <button className="btn primary" type="submit" disabled={act.busy}>{act.busy ? 'Sending…' : 'Send for approval'}</button>
    </form></Panel>}

    {tab === 'expense' && <Panel pad><form style={{ display: 'grid', gap: 12 }} onSubmit={e => { e.preventDefault(); submitExpense(); }}>
      <Select label="Project (optional)" id="me-proj" value={x.project_id} onChange={v => setX({ ...x, project_id: v, account_id: '', currency: 'GHS' })} options={[['', 'No project — general business'], ...data.projects.map((p: any) => [p.id, `${p.name} · ${p.company}`] as [string, string])]} />
      <Field label="What was it for?" id="me-desc" value={x.description} onChange={v => setX({ ...x, description: v })} placeholder="e.g. Taxi to client site, hotel night" required />
      <div className="grid-form" style={{ gridTemplateColumns: '1fr 1fr' }}>
        <Field label="Date" id="me-date" type="date" value={x.expense_date} onChange={v => setX({ ...x, expense_date: v })} required />
        <Field label="Paid to" id="me-merchant" value={x.merchant} onChange={v => setX({ ...x, merchant: v })} />
        <Select label="Currency" id="me-ccy" value={x.currency} onChange={v => setX({ ...x, currency: v, exchange_rate: '' })} options={currencies.map(c => [c, c] as [string, string])} />
        <Field label={`Amount (${x.currency})`} id="me-amt" type="number" step="0.01" min="0.01" inputMode="decimal" value={x.amount} onChange={v => setX({ ...x, amount: v })} required />
        {x.currency !== 'GHS' && <Field label={`GH₵ per 1 ${x.currency}`} id="me-rate" type="number" step="0.000001" min="0.000001" inputMode="decimal" value={x.exchange_rate || defaultRate(x.currency) || ''} onChange={v => setX({ ...x, exchange_rate: v })} required />}
        {cats.length > 0 && <Select label="Category" id="me-cat" value={x.account_id} onChange={v => setX({ ...x, account_id: v })} options={[['', 'Travel and project expenses'], ...cats.map((c: any) => [c.id, c.name] as [string, string])]} />}
      </div>
      {x.currency !== 'GHS' && Number(x.amount) > 0 && <p className="muted" style={{ margin: 0 }}>= GH₵ {money(Number(x.amount) * Number(x.exchange_rate || defaultRate(x.currency) || 0))}</p>}
      <div className="field"><label htmlFor="me-file">Receipt photo</label>
        <input id="me-file" ref={fileRef} type="file" accept="image/*,application/pdf" capture="environment" onChange={e => setFile(e.target.files?.[0] || null)} /></div>
      {x.project_id && <label className="check"><input type="checkbox" checked={x.billable} onChange={e => setX({ ...x, billable: e.target.checked })} /> Re-bill to the client</label>}
      <button className="btn primary" type="submit" disabled={act.busy}>{act.busy ? 'Sending…' : 'Send for approval'}</button>
    </form></Panel>}

    <Panel title="Recent hours">{data.time.length ? <div className="scroll"><table><tbody>{data.time.slice(0, 20).map((r: any) => <tr key={r.id}>
      <td className="num">{r.work_date}</td><td className="wrap-cell">{r.project}{r.note && <><br /><span className="muted">{r.note}</span></>}</td>
      <td className="r num">{r.hours} h</td><td><Status s={r.status} /></td></tr>)}</tbody></table></div> : <Empty>No hours logged yet.</Empty>}</Panel>
    <Panel title="My expenses" actions={data.expenses.length > 0 && <>
      <button className="btn small" type="button" onClick={() => tablePdf({ company: company || { name: data.employees[0].company }, title: 'Expense claims', subtitle: data.employees[0].full_name, head: eHead, body: eRows, rightAlign: [4, 5], filename: 'my-expenses' })}>PDF</button>
      <button className="btn small" type="button" onClick={() => downloadCsv('my-expenses', eHead, eRows)}>CSV</button></>}>
      {data.expenses.length ? <div className="scroll"><table><tbody>{data.expenses.slice(0, 20).map((e: any) => <tr key={e.id}>
        <td className="num">{e.expense_date}</td><td className="wrap-cell">{e.description}<br /><span className="muted">{e.project || e.company}{e.reject_reason ? ' · ' + e.reject_reason : ''}</span></td>
        <td className="r num">{e.currency} {money(e.amount)}{e.currency !== 'GHS' && <><br /><span className="muted">GH₵ {money(e.amount_home)}</span></>}</td>
        <td><Status s={e.status} />{e.status === 'submitted' && <><br /><button className="btn small ghost" type="button" style={{ padding: 0 }} onClick={() => withdraw(e.id)}>Withdraw</button></>}</td></tr>)}</tbody></table></div>
        : <Empty>No expenses yet.</Empty>}
    </Panel>
    <p className="muted" style={{ margin: 0, fontSize: 13 }}>Tip: on your phone, use your browser's "Add to Home screen" to open this like an app.</p>
  </div>;
}
