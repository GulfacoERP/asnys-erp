import { useState } from 'react';
import { Link, useNavigate, useParams, useSearchParams } from 'react-router-dom';
import { q, qPage, rpc, supabase } from '../lib/supabase';
import { fetchAll, Pager, SearchBox, usePaged } from '../components/paging';
import { useSession } from '../lib/session';
import { cedis, longDate, money, qty, r2, taxPreview, today } from '../lib/format';
import { downloadCsv } from '../lib/download';
import { invoicePdf, methodName, tablePdf } from '../lib/pdf';
import { ConfirmButton, Downloads, Empty, Field, FormModal, Loading, PageHead, Panel, Select, Status, useAction, useLoad } from '../components/ui';
import { amt, CurrencyFields, useCurrencies } from '../components/docs';
import { DimSelects, useDims } from '../components/dims';
import { FollowUpForm } from './Cycle';

// ---------------------------------------------------------------- List (paged on the server, so it stays fast for years of invoices)
export function InvoicesPage() {
  const { cid, company } = useSession();
  const nav = useNavigate();
  const [status, setStatus] = useState('all');
  const [from, setFrom] = useState('');
  const [to, setTo] = useState('');
  const [search, setSearch] = useState('');
  const [branch, setBranch] = useState('');
  const { data: branches } = useLoad(() => q<any[]>(supabase.from('branches').select('id,code,name').eq('company_id', cid).eq('active', true).order('code') as any), [cid]);
  const build = (sel: string, opts?: any) => {
    let qy: any = supabase.from('invoices').select(sel, opts).eq('company_id', cid);
    if (status !== 'all') qy = status === 'overdue' ? qy.eq('status', 'posted').lt('due_date', today()) : qy.eq('status', status);
    if (from) qy = qy.gte('invoice_date', from);
    if (to) qy = qy.lte('invoice_date', to);
    if (branch) qy = qy.eq('branch_id', branch);
    if (search) qy = /^[A-Z]{2,4}-?\d/i.test(search) ? qy.ilike('number', `%${search}%`) : qy.ilike('customer.name', `%${search}%`);
    return qy.order('invoice_date', { ascending: false }).order('created_at', { ascending: false });
  };
  const sel = search && !/^[A-Z]{2,4}-?\d/i.test(search) ? '*, customer:customers!inner(name)' : '*, customer:customers(name)';
  const pg = usePaged((a, b) => qPage(build(sel, { count: 'exact' }).range(a, b)), [cid, status, from, to, search, branch]);
  const bal = (i: any) => Number(i.total) - Number(i.amount_paid) - Number(i.amount_credited || 0);
  const head = ['Invoice', 'Date', 'Due', 'Customer', 'Status', 'Currency', 'Subtotal', 'VAT', 'NHIL', 'GETFund', 'Total', 'Paid', 'Credited', 'Balance'];
  const toRows = (list: any[]) => list.map(i => [i.number || 'Draft', i.invoice_date, i.due_date || '', i.customer?.name, i.status, i.currency || 'GHS', money(i.subtotal), money(i.vat), money(i.nhil), money(i.getfund), money(i.total), money(i.amount_paid), money(i.amount_credited), money(bal(i))]);
  const period = from || to ? `${from ? longDate(from) : 'Start'} to ${to ? longDate(to) : 'today'}` : undefined;
  const all = () => fetchAll(async (a, b) => (await qPage(build(sel, { count: 'exact' }).range(a, b))).rows as any[]);
  const download = (kind: 'pdf' | 'csv') => act.run(async () => {
    const list = await all();
    const sum = (k: string) => list.reduce((x, i) => x + Number(i[k]) * Number(i.exchange_rate || 1), 0);
    if (kind === 'csv') return downloadCsv('invoices', head, toRows(list));
    tablePdf({ company: company!, title: 'Sales invoices', subtitle: period, head, body: toRows(list), rightAlign: [6, 7, 8, 9, 10, 11, 12, 13], landscape: true, filename: 'invoices',
      foot: ['', '', '', '', 'Totals in GHS', '', money(sum('subtotal')), money(sum('vat')), money(sum('nhil')), money(sum('getfund')), money(sum('total')), money(sum('amount_paid')), money(sum('amount_credited')), money(sum('total') - sum('amount_paid') - sum('amount_credited'))] });
  });
  const act = useAction();

  return <>
    <PageHead title="Invoices" sub={pg.data ? `${pg.total.toLocaleString()} invoice${pg.total === 1 ? '' : 's'} match` : undefined}>
      <Downloads pdf={() => download('pdf')} csv={() => download('csv')} />
      <Link className="btn primary" to="/invoices/new">New invoice</Link>
    </PageHead>
    <div className="filters">
      <SearchBox value={search} onChange={setSearch} placeholder="Customer name or invoice number" id="f-search" />
      <Select label="Status" id="f-status" value={status} onChange={setStatus} options={[['all', 'All'], ['draft', 'Draft'], ['posted', 'Unpaid'], ['overdue', 'Overdue'], ['paid', 'Paid']]} />
      <Field label="From" id="f-from" type="date" value={from} onChange={setFrom} />
      <Field label="To" id="f-to" type="date" value={to} onChange={setTo} />
      {(branches || []).length > 0 && <Select label="Branch" id="f-branch" value={branch} onChange={setBranch} options={[['', 'All branches'], ...branches!.map(b => [b.id, `${b.code} ${b.name}`] as [string, string])]} />}
    </div>
    <Loading error={pg.error} loading={pg.loading && !pg.data} />
    {pg.data && <Panel>{pg.rows.length ? <div className="scroll"><table>
      <thead><tr><th>Invoice</th><th>Date</th><th>Customer</th><th className="r">Total</th><th className="r">Balance</th><th>Status</th></tr></thead>
      <tbody>{pg.rows.map((i: any) => <tr key={i.id} className="click" tabIndex={0} onClick={() => nav('/invoices/' + i.id)} onKeyDown={e => e.key === 'Enter' && nav('/invoices/' + i.id)}>
        <td className="num">{i.number || 'Draft'}</td><td className="num">{i.invoice_date}</td><td>{i.customer?.name}</td>
        <td className="r num">{amt(i.total, i.currency)}</td><td className="r num">{money(bal(i))}</td>
        <td><Status s={i.status} kind="invoice" />{i.status === 'posted' && i.due_date && i.due_date < today() && <span className="pill bad" style={{ marginLeft: 4 }}>Overdue</span>}</td></tr>)}</tbody>
    </table></div> : <Empty>No invoices match.</Empty>}
      <Pager {...pg} noun="invoices" />
    </Panel>}
  </>;
}

// ---------------------------------------------------------------- Editor
type Line = { product_id: string; description: string; qty: string; unit_price: string; taxable: boolean };
const emptyLine = (): Line => ({ product_id: '', description: '', qty: '1', unit_price: '', taxable: true });

export function InvoiceEditor() {
  const { id } = useParams();
  const { cid } = useSession();
  const { data: dims } = useDims(cid);
  const { data: currencies } = useCurrencies(cid);
  const nav = useNavigate();
  const act = useAction();
  const [form, setForm] = useState<any>(null);
  const [lines, setLines] = useState<Line[]>([]);
  const [params] = useSearchParams();

  const { data, error, loading } = useLoad(async () => {
    const [customers, products, projects, warehouses] = await Promise.all([
      q<any[]>(supabase.from('customers').select('id,name').eq('company_id', cid).order('name') as any),
      q<any[]>(supabase.from('products').select('id,name,sku,price,stock_qty,unit,taxable').eq('company_id', cid).eq('active', true).order('name') as any),
      q<any[]>(supabase.from('projects').select('id,name').eq('company_id', cid).eq('is_template', false).in('status', ['planned', 'active', 'on_hold', 'done']).order('name') as any),
      q<any[]>(supabase.from('warehouses').select('id,code,name,is_default').eq('company_id', cid).eq('active', true).order('code') as any).catch(() => [] as any[]),
    ]);
    if (id) {
      const inv = await q<any>(supabase.from('invoices').select('*').eq('id', id).single() as any);
      if (inv.status !== 'draft') throw new Error('Posted invoices cannot be edited. Issue a new invoice or record a payment instead.');
      const ls = await q<any[]>(supabase.from('invoice_lines').select('*').eq('invoice_id', id).order('sort') as any);
      setForm({ customer_id: inv.customer_id, invoice_date: inv.invoice_date, due_date: inv.due_date || '', project_id: inv.project_id || '', notes: inv.notes || '', currency: inv.currency || 'GHS', exchange_rate: String(inv.exchange_rate || 1), branch_id: inv.branch_id || '', cost_centre_id: inv.cost_centre_id || '', warehouse_id: inv.warehouse_id || '' });
      setLines(ls.map(l => ({ product_id: l.product_id || '', description: l.description, qty: String(l.qty), unit_price: String(l.unit_price), taxable: l.taxable })));
    } else {
      setForm({ customer_id: params.get('customer') || customers[0]?.id || '', invoice_date: today(), due_date: '', project_id: '', notes: '', currency: 'GHS', exchange_rate: '1', branch_id: '', cost_centre_id: '', warehouse_id: '' });
      setLines([emptyLine()]);
    }
    return { customers, products, projects, warehouses };
  }, [cid, id]);

  if (!data || !form) return <Loading error={error} loading={loading} />;
  if (!data.customers.length) return <><PageHead title="New invoice" /><Empty>Add a customer first. <Link to="/customers">Go to Customers</Link>.</Empty></>;

  const setLine = (i: number, patch: Partial<Line>) => setLines(ls => ls.map((l, j) => (j === i ? { ...l, ...patch } : l)));
  const pickProduct = (i: number, pid: string) => {
    const p = data.products.find(x => x.id === pid);
    setLine(i, p ? { product_id: pid, description: p.name, unit_price: String(p.price), taxable: p.taxable } : { product_id: '', description: '' });
  };
  const subtotal = lines.reduce((a, l) => a + r2(Number(l.qty) * Number(l.unit_price) || 0), 0);
  const taxable = lines.filter(l => l.taxable).reduce((a, l) => a + r2(Number(l.qty) * Number(l.unit_price) || 0), 0);
  const t = taxPreview(subtotal, taxable);

  const save = (post: boolean) => act.run(async () => {
    const valid = lines.filter(l => l.description.trim() && Number(l.qty) > 0);
    if (!valid.length) throw new Error('Add at least one line with a description and quantity.');
    if (form.currency !== 'GHS' && !(Number(form.exchange_rate) > 0)) throw new Error('Enter the exchange rate for ' + form.currency + '.');
    const row = { customer_id: form.customer_id, invoice_date: form.invoice_date, due_date: form.due_date || null, project_id: form.project_id || null, notes: form.notes || null,
      currency: form.currency, exchange_rate: form.currency === 'GHS' ? 1 : Number(form.exchange_rate), branch_id: form.branch_id || null, cost_centre_id: form.cost_centre_id || null, warehouse_id: form.warehouse_id || null };
    let invId = id;
    if (invId) {
      await q(supabase.from('invoices').update(row).eq('id', invId) as any);
      await q(supabase.from('invoice_lines').delete().eq('invoice_id', invId) as any);
    } else {
      invId = (await q<any>(supabase.from('invoices').insert({ ...row, company_id: cid }).select('id').single() as any)).id;
    }
    await q(supabase.from('invoice_lines').insert(valid.map((l, i) => ({
      invoice_id: invId, company_id: cid, product_id: l.product_id || null, description: l.description.trim(),
      qty: Number(l.qty), unit_price: Number(l.unit_price) || 0, taxable: l.taxable, sort: i,
    }))) as any);
    if (post) await rpc('post_invoice', { p_invoice: invId });
    nav('/invoices/' + invId, { replace: true });
  }, post ? 'Invoice posted to the ledger' : 'Draft saved');

  return <>
    <PageHead title={id ? 'Edit draft invoice' : 'New invoice'} sub="VAT 15%, NHIL 2.5% and GETFund 2.5% are charged on the same taxable value.">
      <Link className="btn" to={id ? '/invoices/' + id : '/invoices'}>Cancel</Link>
    </PageHead>
    <Panel>
      <div className="body grid-form">
        <Select label="Customer" id="i-cust" value={form.customer_id} onChange={v => setForm({ ...form, customer_id: v })} options={data.customers.map(c => [c.id, c.name])} />
        <Field label="Invoice date" id="i-date" type="date" value={form.invoice_date} onChange={v => setForm({ ...form, invoice_date: v })} required />
        <Field label="Due date (default 30 days)" id="i-due" type="date" value={form.due_date} onChange={v => setForm({ ...form, due_date: v })} />
        <CurrencyFields idPrefix="i" currency={form.currency} rate={form.exchange_rate} currencies={currencies || []} onChange={(c, r) => setForm({ ...form, currency: c, exchange_rate: r })} />
        <DimSelects dims={dims} branch={form.branch_id} centre={form.cost_centre_id} onChange={(b, c) => setForm({ ...form, branch_id: b, cost_centre_id: c })} idPrefix="i" />
        {data.warehouses.length > 1 && <Select label="Goods leave from" id="i-wh" value={form.warehouse_id} onChange={v => setForm({ ...form, warehouse_id: v })} options={[['', 'Main store'], ...data.warehouses.filter(w => !w.is_default).map(w => [w.id, `${w.code} · ${w.name}`] as [string, string])]} />}
        {data.projects.length > 0 && <Select label="Project (optional)" id="i-proj" value={form.project_id} onChange={v => setForm({ ...form, project_id: v })} options={[['', 'None'], ...data.projects.map(p => [p.id, p.name] as [string, string])]} />}
      </div>
      <div className="scroll"><table className="lines">
        <thead><tr><th>Product</th><th>Description</th><th className="r">Qty</th><th className="r">Unit price ({form.currency})</th><th>VAT</th><th className="r">Amount</th><th></th></tr></thead>
        <tbody>{lines.map((l, i) => {
          const p = data.products.find(x => x.id === l.product_id);
          const short = p && Number(l.qty) > Number(p.stock_qty);
          return <tr key={i}>
            <td style={{ minWidth: 190 }}><select aria-label="Product" value={l.product_id} onChange={e => pickProduct(i, e.target.value)}>
              <option value="">Service or other</option>
              {data.products.map(x => <option key={x.id} value={x.id}>{x.name} ({qty(x.stock_qty)} {x.unit})</option>)}</select></td>
            <td style={{ minWidth: 200 }}><input aria-label="Description" value={l.description} onChange={e => setLine(i, { description: e.target.value })} placeholder="What you are charging for" />
              {short && <div className="error">Only {qty(p.stock_qty)} {p.unit} in stock</div>}</td>
            <td><input aria-label="Quantity" type="number" step="0.001" min="0" value={l.qty} onChange={e => setLine(i, { qty: e.target.value })} style={{ width: 90, textAlign: 'right' }} /></td>
            <td><input aria-label="Unit price" type="number" step="0.01" min="0" value={l.unit_price} onChange={e => setLine(i, { unit_price: e.target.value })} style={{ width: 120, textAlign: 'right' }} /></td>
            <td><input aria-label="Charge VAT" type="checkbox" checked={l.taxable} onChange={e => setLine(i, { taxable: e.target.checked })} /></td>
            <td className="r num">{money(Number(l.qty) * Number(l.unit_price) || 0)}</td>
            <td><button className="btn ghost small" type="button" disabled={lines.length < 2} onClick={() => setLines(lines.filter((_, j) => j !== i))}>Remove</button></td>
          </tr>;
        })}</tbody></table></div>
      <div style={{ padding: '0 16px' }}><button className="btn small" type="button" onClick={() => setLines([...lines, emptyLine()])}>Add line</button></div>
      <div className="totals">
        <span className="muted">Subtotal</span><span className="num">{money(t.subtotal)}</span>
        <span className="muted">VAT 15%</span><span className="num">{money(t.vat)}</span>
        <span className="muted">NHIL 2.5%</span><span className="num">{money(t.nhil)}</span>
        <span className="muted">GETFund 2.5%</span><span className="num">{money(t.getfund)}</span>
        <span className="grand">Total</span><span className="grand num">{amt(t.total, form.currency)}</span>
      </div>
      <div className="body"><Field label="Notes on the invoice (optional)" id="i-notes" type="textarea" value={form.notes} onChange={v => setForm({ ...form, notes: v })} /></div>
      <div className="body actions" style={{ justifyContent: 'flex-end', borderTop: '1px solid var(--line)' }}>
        <button className="btn" type="button" disabled={act.busy} onClick={() => save(false)}>Save draft</button>
        <button className="btn primary" type="button" disabled={act.busy} onClick={() => save(true)}>Save and post</button>
      </div>
    </Panel>
  </>;
}

// ---------------------------------------------------------------- View
export function InvoiceView() {
  const { id } = useParams();
  const { company } = useSession();
  const nav = useNavigate();
  const act = useAction();
  const [pay, setPay] = useState<any | null>(null);
  const { data, error, loading, reload } = useLoad(async () => {
    const inv = await q<any>(supabase.from('invoices').select('*, customer:customers(*), project:projects(name)').eq('id', id).single() as any);
    const [lines, payments, credits] = await Promise.all([
      q<any[]>(supabase.from('invoice_lines').select('*').eq('invoice_id', id).order('sort') as any),
      q<any[]>(supabase.from('payments').select('*').eq('invoice_id', id).order('payment_date') as any),
      q<any[]>(supabase.from('credit_notes').select('id,number,credit_date,total,applied,status').eq('invoice_id', id).order('created_at') as any),
    ]);
    return { inv, lines, payments, credits };
  }, [id]);
  if (!data) return <Loading error={error} loading={loading} />;
  const { inv, lines, payments, credits } = data;
  const cur = inv.currency || 'GHS';
  const due = r2(Number(inv.total) - Number(inv.amount_paid) - Number(inv.amount_credited || 0));
  const pdf = () => invoicePdf({ company: company!, invoice: inv, customer: inv.customer, lines, payments, credits });

  return <>
    <PageHead title={inv.number || 'Draft invoice'} sub={<><Status s={inv.status} kind="invoice" /> {inv.journal_entry_id && <span className="muted"> · posted to the ledger</span>}</>}>
      <Link className="btn" to="/invoices">Back</Link>
      <button className="btn" type="button" onClick={pdf}>Download PDF</button>
      {inv.status === 'draft' && <>
        <ConfirmButton className="btn danger" label="Delete draft" confirm="Delete this draft?" onConfirm={() => act.run(async () => { await q(supabase.from('invoices').delete().eq('id', id) as any); nav('/invoices'); }, 'Draft deleted')} />
        <Link className="btn" to={`/invoices/${id}/edit`}>Edit</Link>
        <button className="btn primary" type="button" disabled={act.busy} onClick={() => act.run(async () => { await rpc('post_invoice', { p_invoice: id }); reload(); }, 'Invoice posted')}>Post invoice</button>
      </>}
      {inv.status !== 'draft' && <>
        <ConfirmButton label="Reverse invoice" confirm="Credit the whole invoice and return its stock?" onConfirm={() => act.run(async () => { const cn = await rpc<string>('reverse_invoice', { p_invoice: id, p_date: today(), p_reason: null }); nav('/credit-notes/' + cn); }, 'Invoice reversed with a credit note')} />
        <Link className="btn" to={`/credit-notes/new?invoice=${id}`}>Credit note</Link></>}
      {inv.status === 'posted' && <button className="btn primary" type="button" onClick={() => setPay({ amount: String(due), method: 'momo', date: today(), reference: '', rate: String(inv.exchange_rate) })}>Record payment</button>}
    </PageHead>
    <article className="doc">
      <div className="doc-top">
        <div className="brand"><div className="mark">{company?.name.charAt(0)}</div><div><b style={{ fontSize: 16 }}>{company?.name}</b>
          <div className="muted" style={{ fontSize: 13 }}>{[company?.city, company?.tin && 'TIN ' + company.tin].filter(Boolean).join(' · ')}</div></div></div>
        <div className="meta"><span>{inv.status === 'draft' ? 'Draft invoice' : 'Tax invoice'}</span><b className="num">{inv.number || '—'}</b>
          <span>Date</span><b className="num">{longDate(inv.invoice_date)}</b><span>Due</span><b className="num">{longDate(inv.due_date) || '—'}</b>
          {inv.project && <><span>Project</span><b>{inv.project.name}</b></>}
          {cur !== 'GHS' && <><span>Currency</span><b className="num">{cur} @ {inv.exchange_rate}</b></>}</div>
      </div>
      <div><div className="label">Bill to</div><b>{inv.customer.name}</b>
        <div className="muted">{[inv.customer.city, inv.customer.tin && 'TIN ' + inv.customer.tin, inv.customer.phone].filter(Boolean).join(' · ')}</div></div>
      <div className="scroll"><table>
        <thead><tr><th>Description</th><th className="r">Qty</th><th className="r">Unit price</th><th className="r">Amount ({cur})</th></tr></thead>
        <tbody>{lines.map(l => <tr key={l.id}><td className="wrap-cell">{l.description}{!l.taxable && <span className="pill" style={{ marginLeft: 6 }}>Exempt</span>}</td>
          <td className="r num">{qty(l.qty)}</td><td className="r num">{money(l.unit_price)}</td><td className="r num">{money(Number(l.qty) * Number(l.unit_price))}</td></tr>)}</tbody>
      </table></div>
      {inv.status === 'draft'
        ? <div className="note">Totals and tax are calculated when you post the invoice.</div>
        : <div className="totals" style={{ padding: 0 }}>
          <span className="muted">Taxable value</span><span className="num">{money(inv.subtotal)}</span>
          <span className="muted">VAT 15%</span><span className="num">{money(inv.vat)}</span>
          <span className="muted">NHIL 2.5%</span><span className="num">{money(inv.nhil)}</span>
          <span className="muted">GETFund levy 2.5%</span><span className="num">{money(inv.getfund)}</span>
          <span className="grand">Total</span><span className="grand num">{amt(inv.total, cur)}</span>
          {Number(inv.amount_credited) > 0 && <><span className="muted">Credited</span><span className="num">{money(inv.amount_credited)}</span></>}
          {Number(inv.amount_paid) > 0 && <><span className="muted">Paid</span><span className="num">{money(inv.amount_paid)}</span></>}
          {(Number(inv.amount_paid) > 0 || Number(inv.amount_credited) > 0) && <><span className="grand">Balance due</span><span className="grand num">{amt(due, cur)}</span></>}
        </div>}
      {inv.notes && <div className="note">{inv.notes}</div>}
    </article>
    {credits.length > 0 && <Panel title="Credit notes"><div className="scroll"><table>
      <thead><tr><th>Credit note</th><th>Date</th><th className="r">Total</th><th className="r">Applied to this invoice</th><th>Status</th></tr></thead>
      <tbody>{credits.map(c => <tr key={c.id} className="click" onClick={() => nav('/credit-notes/' + c.id)}><td className="num">{c.number || 'Draft'}</td><td className="num">{c.credit_date}</td>
        <td className="r num">{money(c.total)}</td><td className="r num">{money(c.applied)}</td><td><Status s={c.status} /></td></tr>)}</tbody>
    </table></div></Panel>}
    {payments.length > 0 && <Panel title="Payments received"><div className="scroll"><table>
      <thead><tr><th>Date</th><th>Method</th><th>Reference</th><th className="r">Amount ({cur})</th></tr></thead>
      <tbody>{payments.map(p => <tr key={p.id}><td className="num">{p.payment_date}</td><td>{methodName(p.method)}</td><td>{p.reference}</td><td className="r num">{money(p.amount)}</td></tr>)}</tbody>
    </table></div></Panel>}
    {inv.status === 'posted' && <InvoiceFollowUps inv={inv} />}
    {pay && <FormModal title={`Record payment for ${inv.number}`} submit="Record payment" busy={act.busy} onClose={() => setPay(null)}
      onSave={() => act.run(async () => {
        await rpc('record_payment', { p_invoice: id, p_amount: Number(pay.amount), p_date: pay.date, p_method: pay.method, p_reference: pay.reference || null, p_rate: cur === 'GHS' ? null : Number(pay.rate) });
        setPay(null); reload();
      }, 'Payment recorded and posted')}>
      <p className="muted" style={{ margin: 0 }}>Balance due: {amt(due, cur)}</p>
      <div className="grid-form">
        {cur !== 'GHS' && <Field label={`Rate on payment day (GH₵ per ${cur})`} id="py-rate" type="number" step="0.000001" min="0.000001" value={pay.rate} onChange={v => setPay({ ...pay, rate: v })} required />}
        <Field label={`Amount (${cur})`} id="py-amt" type="number" step="0.01" min="0.01" value={pay.amount} onChange={v => setPay({ ...pay, amount: v })} required />
        <Select label="Paid by" id="py-m" value={pay.method} onChange={v => setPay({ ...pay, method: v })} options={[['momo', 'Mobile Money'], ['bank', 'Bank transfer or cheque'], ['cash', 'Cash']]} />
        <Field label="Date" id="py-d" type="date" value={pay.date} onChange={v => setPay({ ...pay, date: v })} required />
        <Field label="Reference" id="py-ref" value={pay.reference} onChange={v => setPay({ ...pay, reference: v })} placeholder="MoMo ID, cheque no." />
      </div>
    </FormModal>}
  </>;
}

/** Every unpaid invoice is followed up until it is paid: who was contacted, what they said, promises and the next date. */
function InvoiceFollowUps({ inv }: { inv: any }) {
  const { can } = useSession();
  const act = useAction();
  const [f, setF] = useState<any | null>(null);
  const { data, reload } = useLoad(() => q<any[]>(supabase.from('invoice_followups').select('*').eq('invoice_id', inv.id).order('followup_date', { ascending: false }) as any).catch(() => [] as any[]), [inv.id]);
  if (!can('accountant', 'sales')) return null;
  return <Panel title="Follow-up" actions={<button className="btn small primary" type="button" onClick={() => setF({ invoice_id: inv.id, number: inv.number, method: 'call', contact: '', note: '', promised_date: '', promised_amount: '', next_action_date: '' })}>Log follow-up</button>}>
    {data && data.length ? <div className="scroll"><table><tbody>{data.map(x => <tr key={x.id}><td className="num" style={{ width: 100 }}>{x.followup_date}</td><td style={{ width: 90 }}>{x.method}</td>
      <td className="wrap-cell">{x.contact && <b>{x.contact}: </b>}{x.note}{x.promised_date && <><br /><span className="pill good">Promised {x.promised_date}{x.promised_amount ? ' · ' + money(x.promised_amount) : ''}</span></>}
        {x.next_action_date && <span className="muted"> · next {x.next_action_date}</span>}</td><td className="muted" style={{ width: 110 }}>{(x.created_email || '').split('@')[0]}</td></tr>)}</tbody></table></div>
      : <Empty>{inv.due_date && inv.due_date < today() ? 'Overdue and not followed up yet.' : 'No follow-up yet.'}</Empty>}
    {f && <FollowUpForm f={f} setF={setF} onDone={reload} busy={act.busy} run={act.run} />}
  </Panel>;
}
