import { useState } from 'react';
import { Link, useNavigate, useParams, useSearchParams } from 'react-router-dom';
import { q, rpc, supabase } from '../lib/supabase';
import { useSession } from '../lib/session';
import { longDate, money, today } from '../lib/format';
import { downloadCsv } from '../lib/download';
import { creditNotePdf, tablePdf } from '../lib/pdf';
import { ConfirmButton, Downloads, Empty, Field, Loading, PageHead, Panel, Select, Status, useAction, useLoad } from '../components/ui';
import { amt, cleanLines, CurrencyFields, DocLines, emptyLine, Line, LineItems, linesFromRows, useCurrencies } from '../components/docs';

export function CreditNotesPage() {
  const { cid, company } = useSession();
  const nav = useNavigate();
  const { data, error, loading } = useLoad(() =>
    q<any[]>(supabase.from('credit_notes').select('*, customer:customers(name), invoice:invoices(number)').eq('company_id', cid).order('credit_date', { ascending: false }) as any), [cid]);
  const head = ['Credit note', 'Date', 'Customer', 'Against invoice', 'Currency', 'Value', 'VAT', 'NHIL', 'GETFund', 'Total', 'Status'];
  const rows = (data || []).map(c => [c.number || 'Draft', c.credit_date, c.customer?.name, c.invoice?.number || '', c.currency, money(c.subtotal), money(c.vat), money(c.nhil), money(c.getfund), money(c.total), c.status]);
  return <>
    <PageHead title="Credit notes" sub="Refunds, returns and corrections to posted invoices. Posting reduces sales and output VAT.">
      <Downloads pdf={() => tablePdf({ company: company!, title: 'Credit notes', head, body: rows, rightAlign: [5, 6, 7, 8, 9], landscape: true, filename: 'credit-notes' })} csv={() => downloadCsv('credit-notes', head, rows)} />
      <Link className="btn primary" to="/credit-notes/new">New credit note</Link>
    </PageHead>
    <Loading error={error} loading={loading && !data} />
    {data && <Panel>{data.length ? <div className="scroll"><table>
      <thead><tr><th>Credit note</th><th>Date</th><th>Customer</th><th>Invoice</th><th className="r">Total</th><th>Status</th></tr></thead>
      <tbody>{data.map(c => <tr key={c.id} className="click" tabIndex={0} onClick={() => nav('/credit-notes/' + c.id)} onKeyDown={e => e.key === 'Enter' && nav('/credit-notes/' + c.id)}>
        <td className="num">{c.number || 'Draft'}</td><td className="num">{c.credit_date}</td><td>{c.customer?.name}</td><td className="num">{c.invoice?.number}</td>
        <td className="r num">{amt(c.total, c.currency)}</td><td><Status s={c.status} /></td></tr>)}</tbody>
    </table></div> : <Empty>No credit notes yet. Open a posted invoice and choose Credit note or Reverse invoice.</Empty>}</Panel>}
  </>;
}

export function CreditNoteEditor() {
  const { id } = useParams();
  const [params] = useSearchParams();
  const fromInvoice = params.get('invoice');
  const { cid } = useSession();
  const nav = useNavigate();
  const act = useAction();
  const { data: currencies } = useCurrencies(cid);
  const [form, setForm] = useState<any>(null);
  const [lines, setLines] = useState<Line[]>([]);

  const { data, error, loading } = useLoad(async () => {
    const [customers, products, invoices] = await Promise.all([
      q<any[]>(supabase.from('customers').select('id,name').eq('company_id', cid).order('name') as any),
      q<any[]>(supabase.from('products').select('id,name,price,unit,taxable,stock_qty').eq('company_id', cid).order('name') as any),
      q<any[]>(supabase.from('invoices').select('id,number,customer_id,currency,exchange_rate').eq('company_id', cid).neq('status', 'draft').order('invoice_date', { ascending: false }) as any),
    ]);
    if (id) {
      const cn = await q<any>(supabase.from('credit_notes').select('*').eq('id', id).single() as any);
      if (cn.status !== 'draft') throw new Error('Posted credit notes cannot be edited.');
      const ls = await q<any[]>(supabase.from('credit_note_lines').select('*').eq('credit_note_id', id).order('sort') as any);
      setForm({ customer_id: cn.customer_id, invoice_id: cn.invoice_id || '', credit_date: cn.credit_date, reason: cn.reason || '', currency: cn.currency, exchange_rate: String(cn.exchange_rate) });
      setLines(linesFromRows(ls));
    } else if (fromInvoice) {
      const inv = invoices.find(i => i.id === fromInvoice);
      const ls = await q<any[]>(supabase.from('invoice_lines').select('*').eq('invoice_id', fromInvoice).order('sort') as any);
      setForm({ customer_id: inv?.customer_id || customers[0]?.id, invoice_id: fromInvoice, credit_date: today(), reason: '', currency: inv?.currency || 'GHS', exchange_rate: String(inv?.exchange_rate || 1) });
      setLines(linesFromRows(ls).map(l => ({ ...l, restock: !!l.product_id })));
    } else {
      setForm({ customer_id: customers[0]?.id || '', invoice_id: '', credit_date: today(), reason: '', currency: 'GHS', exchange_rate: '1' });
      setLines([emptyLine()]);
    }
    return { customers, products, invoices };
  }, [cid, id, fromInvoice]);

  if (!data || !form) return <Loading error={error} loading={loading} />;
  const custInvoices = data.invoices.filter(i => i.customer_id === form.customer_id);

  const save = (post: boolean) => act.run(async () => {
    const valid = cleanLines(lines);
    if (!valid.length) throw new Error('Add at least one line.');
    const row = { customer_id: form.customer_id, invoice_id: form.invoice_id || null, credit_date: form.credit_date, reason: form.reason || null,
      currency: form.currency, exchange_rate: form.currency === 'GHS' ? 1 : Number(form.exchange_rate) };
    let cnId = id;
    if (cnId) {
      await q(supabase.from('credit_notes').update(row).eq('id', cnId) as any);
      await q(supabase.from('credit_note_lines').delete().eq('credit_note_id', cnId) as any);
    } else cnId = (await q<any>(supabase.from('credit_notes').insert({ ...row, company_id: cid }).select('id').single() as any)).id;
    await q(supabase.from('credit_note_lines').insert(valid.map((l, i) => ({ credit_note_id: cnId, company_id: cid, product_id: l.product_id || null,
      description: l.description.trim(), qty: Number(l.qty), unit_price: Number(l.unit_price) || 0, taxable: l.taxable, restock: !!l.restock && !!l.product_id, sort: i }))) as any);
    if (post) await rpc('post_credit_note', { p_cn: cnId });
    nav('/credit-notes/' + cnId, { replace: true });
  }, post ? 'Credit note posted' : 'Draft saved');

  return <>
    <PageHead title={id ? 'Edit draft credit note' : 'New credit note'} sub="Remove lines you are not crediting, or lower quantities for a partial credit.">
      <Link className="btn" to={id ? '/credit-notes/' + id : fromInvoice ? '/invoices/' + fromInvoice : '/credit-notes'}>Cancel</Link>
    </PageHead>
    <Panel>
      <div className="body grid-form">
        <Select label="Customer" id="cn-cust" value={form.customer_id} onChange={v => setForm({ ...form, customer_id: v, invoice_id: '' })} options={data.customers.map(c => [c.id, c.name])} />
        <Select label="Against invoice (optional)" id="cn-inv" value={form.invoice_id} onChange={v => {
          const inv = data.invoices.find(i => i.id === v);
          setForm({ ...form, invoice_id: v, ...(inv ? { currency: inv.currency, exchange_rate: String(inv.exchange_rate) } : {}) });
        }} options={[['', 'None (customer credit)'], ...custInvoices.map(i => [i.id, i.number] as [string, string])]} />
        <Field label="Date" id="cn-date" type="date" value={form.credit_date} onChange={v => setForm({ ...form, credit_date: v })} required />
        {!form.invoice_id && <CurrencyFields idPrefix="cn" currency={form.currency} rate={form.exchange_rate} currencies={currencies || []} onChange={(c, r) => setForm({ ...form, currency: c, exchange_rate: r })} />}
      </div>
      <LineItems lines={lines} setLines={setLines} products={data.products} restock currency={form.currency} />
      <div className="body"><Field label="Reason (printed on the credit note)" id="cn-reason" value={form.reason} onChange={v => setForm({ ...form, reason: v })} placeholder="e.g. 2 cartons returned damaged" /></div>
      <div className="body actions" style={{ justifyContent: 'flex-end', borderTop: '1px solid var(--line)' }}>
        <button className="btn" type="button" disabled={act.busy} onClick={() => save(false)}>Save draft</button>
        <button className="btn primary" type="button" disabled={act.busy} onClick={() => save(true)}>Save and post</button>
      </div>
    </Panel>
  </>;
}

export function CreditNoteView() {
  const { id } = useParams();
  const { company } = useSession();
  const nav = useNavigate();
  const act = useAction();
  const { data, error, loading, reload } = useLoad(async () => {
    const cn = await q<any>(supabase.from('credit_notes').select('*, customer:customers(*), invoice:invoices(id,number)').eq('id', id).single() as any);
    const lines = await q<any[]>(supabase.from('credit_note_lines').select('*').eq('credit_note_id', id).order('sort') as any);
    return { cn, lines };
  }, [id]);
  if (!data) return <Loading error={error} loading={loading} />;
  const { cn, lines } = data;
  return <>
    <PageHead title={cn.number || 'Draft credit note'} sub={<><Status s={cn.status} /> <span className="muted">· {cn.customer.name}{cn.invoice ? ' · against ' : ''}</span>{cn.invoice && <Link to={'/invoices/' + cn.invoice.id}>{cn.invoice.number}</Link>}</>}>
      <Link className="btn" to="/credit-notes">Back</Link>
      <button className="btn" type="button" onClick={() => creditNotePdf({ company: company!, cn, customer: cn.customer, lines, invoiceNo: cn.invoice?.number })}>Download PDF</button>
      {cn.status === 'draft' && <>
        <ConfirmButton className="btn danger" label="Delete draft" confirm="Delete?" onConfirm={() => act.run(async () => { await q(supabase.from('credit_notes').delete().eq('id', id) as any); nav('/credit-notes'); }, 'Draft deleted')} />
        <Link className="btn" to={`/credit-notes/${id}/edit`}>Edit</Link>
        <button className="btn primary" type="button" disabled={act.busy} onClick={() => act.run(async () => { await rpc('post_credit_note', { p_cn: id }); reload(); }, 'Credit note posted')}>Post credit note</button></>}
    </PageHead>
    <Panel>
      <div className="body grid-form">
        <div><div className="label">Date</div>{longDate(cn.credit_date)}</div>
        <div><div className="label">Total credit</div><b className="num">{amt(cn.total, cn.currency)}</b></div>
        <div><div className="label">Applied to invoice</div><span className="num">{money(cn.applied)}</span></div>
        {cn.reason && <div><div className="label">Reason</div>{cn.reason}</div>}
      </div>
      <DocLines lines={lines} currency={cn.currency} showRestock />
      {cn.status === 'posted' && <div className="totals">
        <span className="muted">Value</span><span className="num">{money(cn.subtotal)}</span>
        <span className="muted">VAT 15%</span><span className="num">{money(cn.vat)}</span>
        <span className="muted">NHIL 2.5%</span><span className="num">{money(cn.nhil)}</span>
        <span className="muted">GETFund 2.5%</span><span className="num">{money(cn.getfund)}</span>
        <span className="grand">Total credit</span><span className="grand num">{amt(cn.total, cn.currency)}</span></div>}
      {cn.status === 'posted' && Number(cn.total) > Number(cn.applied) && <div className="body note">{amt(Number(cn.total) - Number(cn.applied), cn.currency)} was not needed against the invoice and stays as a credit on the customer's account. It shows on their statement.</div>}
    </Panel>
  </>;
}
