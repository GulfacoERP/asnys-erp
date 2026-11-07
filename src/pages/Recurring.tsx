import { useState } from 'react';
import { q, rpc, supabase } from '../lib/supabase';
import { useSession } from '../lib/session';
import { longDate, money, today } from '../lib/format';
import { downloadCsv } from '../lib/download';
import { tablePdf } from '../lib/pdf';
import { ConfirmButton, Downloads, Empty, Field, Loading, Modal, PageHead, Panel, Select, useAction, useLoad } from '../components/ui';
import { amt, cleanLines, emptyLine, Line, LineItems, linesFromRows, useCurrencies } from '../components/docs';

const FREQ: [string, string][] = [['weekly', 'Weekly'], ['monthly', 'Monthly'], ['quarterly', 'Quarterly'], ['yearly', 'Yearly']];

export function RecurringPage() {
  const { cid, company } = useSession();
  const act = useAction();
  const [edit, setEdit] = useState<any | null>(null);
  const [lines, setLines] = useState<Line[]>([]);
  const { data: currencies } = useCurrencies(cid);
  const { data, error, loading, reload } = useLoad(async () => {
    const [list, customers, products] = await Promise.all([
      q<any[]>(supabase.from('recurring_invoices').select('*, customer:customers(name)').eq('company_id', cid).order('next_date') as any),
      q<any[]>(supabase.from('customers').select('id,name').eq('company_id', cid).order('name') as any),
      q<any[]>(supabase.from('products').select('id,name,price,unit,taxable').eq('company_id', cid).eq('active', true).order('name') as any),
    ]);
    return { list, customers, products };
  }, [cid]);
  const total = (r: any) => (r.lines || []).reduce((a: number, l: any) => a + Number(l.qty) * Number(l.unit_price) * (l.taxable ? 1.2 : 1), 0);
  const head = ['Name', 'Customer', 'Every', 'Next invoice', 'Ends', 'Amount incl. tax', 'Auto-post', 'Active'];
  const rows = (data?.list || []).map(r => [r.name, r.customer?.name, r.frequency, r.next_date, r.end_date || '', `${r.currency} ${money(total(r))}`, r.auto_post ? 'Yes' : 'No', r.active ? 'Yes' : 'No']);

  const open = (r?: any) => {
    setEdit(r ? { ...r, end_date: r.end_date || '', notes: r.notes || '' }
      : { name: '', customer_id: data?.customers[0]?.id || '', frequency: 'monthly', next_date: today(), end_date: '', auto_post: false, active: true, currency: 'GHS', notes: '' });
    setLines(r ? linesFromRows(r.lines) : [emptyLine()]);
  };
  const save = () => act.run(async () => {
    const valid = cleanLines(lines);
    if (!valid.length) throw new Error('Add at least one line.');
    const row = { name: edit.name, customer_id: edit.customer_id, frequency: edit.frequency, next_date: edit.next_date, end_date: edit.end_date || null,
      auto_post: edit.auto_post, active: edit.active, currency: edit.currency, notes: edit.notes || null,
      lines: valid.map(l => ({ product_id: l.product_id || null, description: l.description.trim(), qty: Number(l.qty), unit_price: Number(l.unit_price) || 0, taxable: l.taxable })) };
    if (edit.id) await q(supabase.from('recurring_invoices').update(row).eq('id', edit.id) as any);
    else await q(supabase.from('recurring_invoices').insert({ ...row, company_id: cid }) as any);
    setEdit(null); reload();
  }, 'Recurring invoice saved');

  return <>
    <PageHead title="Recurring invoices" sub="Rent, retainers and subscriptions. Due invoices are created when you open the dashboard or press Generate.">
      <Downloads pdf={() => tablePdf({ company: company!, title: 'Recurring invoices', head, body: rows, rightAlign: [5], landscape: true, filename: 'recurring-invoices' })} csv={() => downloadCsv('recurring-invoices', head, rows)} />
      <button className="btn" type="button" disabled={act.busy} onClick={() => act.run(async () => { const n = await rpc<number>('run_recurring', { cid }); reload(); if (!n) throw new Error('Nothing is due today.'); }, 'Due invoices created — find them under Invoices')}>Generate due invoices</button>
      <button className="btn primary" type="button" disabled={!data?.customers.length} onClick={() => open()}>New recurring invoice</button>
    </PageHead>
    <Loading error={error} loading={loading && !data} />
    {data && <Panel>{data.list.length ? <div className="scroll"><table>
      <thead><tr><th>Name</th><th>Customer</th><th>Every</th><th>Next invoice</th><th className="r">Amount incl. tax</th><th>Posts</th><th></th></tr></thead>
      <tbody>{data.list.map(r => <tr key={r.id} style={r.active ? undefined : { opacity: .55 }}>
        <td><button className="btn ghost small" style={{ padding: 0, fontWeight: 600 }} type="button" onClick={() => open(r)}>{r.name}</button></td>
        <td>{r.customer?.name}</td><td style={{ textTransform: 'capitalize' }}>{r.frequency}</td>
        <td className="num">{r.active ? longDate(r.next_date) : 'Stopped'}</td><td className="r num">{amt(total(r), r.currency)}</td>
        <td>{r.auto_post ? <span className="pill good">Automatically</span> : <span className="pill">As draft</span>}</td>
        <td className="r"><ConfirmButton className="btn small ghost" label="Delete" confirm="Delete?" onConfirm={() => act.run(async () => { await q(supabase.from('recurring_invoices').delete().eq('id', r.id) as any); reload(); })} /></td></tr>)}</tbody>
    </table></div> : <Empty>No recurring invoices yet.</Empty>}</Panel>}
    {edit && data && <Modal title={edit.id ? 'Edit recurring invoice' : 'New recurring invoice'} onClose={() => setEdit(null)}
      footer={<><button className="btn" type="button" onClick={() => setEdit(null)}>Cancel</button><button className="btn primary" type="button" disabled={act.busy} onClick={save}>Save</button></>}>
      <div className="body">
        <Field label="Name" id="rc-name" value={edit.name} onChange={v => setEdit({ ...edit, name: v })} placeholder="e.g. Office rent, Shop 4" required />
        <div className="grid-form">
          <Select label="Customer" id="rc-cust" value={edit.customer_id} onChange={v => setEdit({ ...edit, customer_id: v })} options={data.customers.map(c => [c.id, c.name])} />
          <Select label="Every" id="rc-freq" value={edit.frequency} onChange={v => setEdit({ ...edit, frequency: v })} options={FREQ} />
          <Field label="Next invoice date" id="rc-next" type="date" value={edit.next_date} onChange={v => setEdit({ ...edit, next_date: v })} required />
          <Field label="End date (optional)" id="rc-end" type="date" value={edit.end_date} onChange={v => setEdit({ ...edit, end_date: v })} />
          {(currencies || []).length > 0 && <Select label="Currency" id="rc-ccy" value={edit.currency} onChange={v => setEdit({ ...edit, currency: v })} options={[['GHS', 'GHS'], ...(currencies || []).map(c => [c.code, c.code] as [string, string])]} />}
        </div>
        <label className="check"><input type="checkbox" checked={edit.auto_post} onChange={e => setEdit({ ...edit, auto_post: e.target.checked })} /> Post automatically (otherwise created as drafts to review)</label>
        <label className="check"><input type="checkbox" checked={edit.active} onChange={e => setEdit({ ...edit, active: e.target.checked })} /> Active</label>
      </div>
      <LineItems lines={lines} setLines={setLines} products={data.products} currency={edit.currency} />
      <div className="body"><Field label="Note on each invoice" id="rc-notes" value={edit.notes} onChange={v => setEdit({ ...edit, notes: v })} /></div>
    </Modal>}
  </>;
}
