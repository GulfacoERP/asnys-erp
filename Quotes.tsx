import { useState } from 'react';
import { Link, useNavigate, useParams, useSearchParams } from 'react-router-dom';
import { q, rpc, supabase } from '../lib/supabase';
import { useSession } from '../lib/session';
import { longDate, money, r2, today } from '../lib/format';
import { downloadCsv } from '../lib/download';
import { quotePdf, tablePdf } from '../lib/pdf';
import { ConfirmButton, Downloads, Empty, Field, FormModal, Loading, PageHead, Panel, Select, Status, useAction, useLoad } from '../components/ui';
import { amt, cleanLines, CurrencyFields, DocLines, emptyLine, Line, LineItems, linesFromRows, useCurrencies } from '../components/docs';

const KIND_LABEL = { quote: 'Quotes', order: 'Sales orders' } as const;
const STATUS: [string, string][] = [['draft', 'Draft'], ['sent', 'Sent'], ['accepted', 'Accepted'], ['declined', 'Declined']];

export function QuotesPage() {
  const { cid, company } = useSession();
  const nav = useNavigate();
  const [kind, setKind] = useState<'quote' | 'order'>('quote');
  const { data, error, loading } = useLoad(() =>
    q<any[]>(supabase.from('sales_quotes').select('*, customer:customers(name)').eq('company_id', cid).order('created_at', { ascending: false }) as any), [cid]);
  const list = (data || []).filter(x => x.kind === kind);
  const head = ['Number', 'Date', 'Customer', 'Valid until', 'Currency', 'Total', 'Status'];
  const rows = list.map(x => [x.number, x.quote_date, x.customer?.name, x.valid_until || '', x.currency, money(x.total), x.status]);
  return <>
    <PageHead title="Quotes and sales orders" sub="Nothing posts to the ledger until you convert to an invoice and post it.">
      <Downloads pdf={() => tablePdf({ company: company!, title: KIND_LABEL[kind], head, body: rows, rightAlign: [5], filename: KIND_LABEL[kind].toLowerCase().replace(' ', '-') })} csv={() => downloadCsv(KIND_LABEL[kind].toLowerCase().replace(' ', '-'), head, rows)} />
      <Link className="btn primary" to={`/quotes/new?kind=${kind}`}>New {kind === 'quote' ? 'quote' : 'sales order'}</Link>
    </PageHead>
    <div className="actions">
      <button type="button" className={'btn small' + (kind === 'quote' ? ' primary' : '')} onClick={() => setKind('quote')}>Quotes</button>
      <button type="button" className={'btn small' + (kind === 'order' ? ' primary' : '')} onClick={() => setKind('order')}>Sales orders</button>
    </div>
    <Loading error={error} loading={loading && !data} />
    {data && <Panel>{list.length ? <div className="scroll"><table>
      <thead><tr><th>Number</th><th>Date</th><th>Customer</th><th className="r">Total</th><th>Status</th></tr></thead>
      <tbody>{list.map(x => <tr key={x.id} className="click" tabIndex={0} onClick={() => nav('/quotes/' + x.id)} onKeyDown={e => e.key === 'Enter' && nav('/quotes/' + x.id)}>
        <td className="num">{x.number}</td><td className="num">{x.quote_date}</td><td>{x.customer?.name}</td><td className="r num">{amt(x.total, x.currency)}</td><td><Status s={x.status} /></td></tr>)}</tbody>
    </table></div> : <Empty>No {KIND_LABEL[kind].toLowerCase()} yet.</Empty>}</Panel>}
  </>;
}

export function QuoteEditor() {
  const { id } = useParams();
  const [params] = useSearchParams();
  const { cid } = useSession();
  const nav = useNavigate();
  const act = useAction();
  const { data: currencies } = useCurrencies(cid);
  const [form, setForm] = useState<any>(null);
  const [lines, setLines] = useState<Line[]>([]);
  const { data, error, loading } = useLoad(async () => {
    const [customers, products] = await Promise.all([
      q<any[]>(supabase.from('customers').select('id,name').eq('company_id', cid).order('name') as any),
      q<any[]>(supabase.from('products').select('id,name,price,unit,taxable,stock_qty').eq('company_id', cid).eq('active', true).order('name') as any),
    ]);
    if (id) {
      const x = await q<any>(supabase.from('sales_quotes').select('*').eq('id', id).single() as any);
      if (x.status === 'converted') throw new Error('This has been converted to an invoice and can no longer be edited.');
      const ls = await q<any[]>(supabase.from('sales_quote_lines').select('*').eq('quote_id', id).order('sort') as any);
      setForm({ ...x, valid_until: x.valid_until || '', notes: x.notes || '', exchange_rate: String(x.exchange_rate) });
      setLines(linesFromRows(ls));
    } else {
      const kind = params.get('kind') === 'order' ? 'order' : 'quote';
      const d = new Date(); d.setDate(d.getDate() + 30);
      setForm({ kind, customer_id: params.get('customer') || customers[0]?.id || '', quote_date: today(), valid_until: kind === 'quote' ? d.toISOString().slice(0, 10) : '', status: 'draft', notes: '', currency: 'GHS', exchange_rate: '1' });
      setLines([emptyLine()]);
    }
    return { customers, products };
  }, [cid, id]);
  if (!data || !form) return <Loading error={error} loading={loading} />;
  if (!data.customers.length) return <Empty>Add a customer first. <Link to="/customers">Go to Customers</Link>.</Empty>;

  const save = () => act.run(async () => {
    const valid = cleanLines(lines);
    if (!valid.length) throw new Error('Add at least one line.');
    const sub = valid.reduce((a, l) => a + r2(Number(l.qty) * Number(l.unit_price)), 0);
    const tx = valid.filter(l => l.taxable).reduce((a, l) => a + r2(Number(l.qty) * Number(l.unit_price)), 0);
    const row = { kind: form.kind, customer_id: form.customer_id, quote_date: form.quote_date, valid_until: form.valid_until || null, status: form.status,
      notes: form.notes || null, currency: form.currency, exchange_rate: form.currency === 'GHS' ? 1 : Number(form.exchange_rate), subtotal: sub, total: r2(sub + r2(tx * 0.15) + r2(tx * 0.025) * 2) };
    let qid = id;
    if (qid) {
      await q(supabase.from('sales_quotes').update(row).eq('id', qid) as any);
      await q(supabase.from('sales_quote_lines').delete().eq('quote_id', qid) as any);
    } else qid = (await q<any>(supabase.from('sales_quotes').insert({ ...row, company_id: cid }).select('id').single() as any)).id;
    await q(supabase.from('sales_quote_lines').insert(valid.map((l, i) => ({ quote_id: qid, company_id: cid, product_id: l.product_id || null, description: l.description.trim(),
      qty: Number(l.qty), unit_price: Number(l.unit_price) || 0, taxable: l.taxable, sort: i }))) as any);
    nav('/quotes/' + qid, { replace: true });
  }, 'Saved');

  const label = form.kind === 'order' ? 'sales order' : 'quote';
  return <>
    <PageHead title={id ? `Edit ${label}` : `New ${label}`}><Link className="btn" to={id ? '/quotes/' + id : '/quotes'}>Cancel</Link></PageHead>
    <Panel>
      <div className="body grid-form">
        <Select label="Customer" id="qt-cust" value={form.customer_id} onChange={v => setForm({ ...form, customer_id: v })} options={data.customers.map(c => [c.id, c.name])} />
        <Field label="Date" id="qt-date" type="date" value={form.quote_date} onChange={v => setForm({ ...form, quote_date: v })} required />
        {form.kind === 'quote' && <Field label="Valid until" id="qt-valid" type="date" value={form.valid_until} onChange={v => setForm({ ...form, valid_until: v })} />}
        <Select label="Status" id="qt-status" value={form.status} onChange={v => setForm({ ...form, status: v })} options={STATUS} />
        <CurrencyFields idPrefix="qt" currency={form.currency} rate={form.exchange_rate} currencies={currencies || []} onChange={(c, r) => setForm({ ...form, currency: c, exchange_rate: r })} />
      </div>
      <LineItems lines={lines} setLines={setLines} products={data.products} currency={form.currency} />
      <div className="body"><Field label="Notes and terms" id="qt-notes" type="textarea" value={form.notes} onChange={v => setForm({ ...form, notes: v })} placeholder="Delivery within 7 days. 50% deposit on order." /></div>
      <div className="body actions" style={{ justifyContent: 'flex-end', borderTop: '1px solid var(--line)' }}>
        <button className="btn primary" type="button" disabled={act.busy} onClick={save}>Save {label}</button></div>
    </Panel>
  </>;
}

export function QuoteView() {
  const { id } = useParams();
  const { company, cid, can } = useSession();
  const [mkProject, setMkProject] = useState<string | null>(null);
  const { data: templates } = useLoad(() => q<any[]>(supabase.from('projects').select('id,name').eq('company_id', cid).eq('is_template', true).order('name') as any), [cid]);
  const nav = useNavigate();
  const act = useAction();
  const { data, error, loading, reload } = useLoad(async () => {
    const x = await q<any>(supabase.from('sales_quotes').select('*, customer:customers(*), invoice:invoices(id,number)').eq('id', id).single() as any);
    const lines = await q<any[]>(supabase.from('sales_quote_lines').select('*').eq('quote_id', id).order('sort') as any);
    const projects = await q<any[]>(supabase.from('projects').select('id,name,number').eq('sales_order_id', id) as any);
    return { x, lines, projects };
  }, [id]);
  if (!data) return <Loading error={error} loading={loading} />;
  const { x, lines, projects } = data;
  const setStatus = (status: string) => act.run(async () => { await q(supabase.from('sales_quotes').update({ status }).eq('id', id) as any); reload(); }, 'Status updated');
  return <>
    <PageHead title={x.number} sub={<><Status s={x.status} /> <span className="muted">· {x.kind === 'order' ? 'Sales order' : 'Quote'} for {x.customer.name}</span></>}>
      <Link className="btn" to="/quotes">Back</Link>
      <button className="btn" type="button" onClick={() => quotePdf({ company: company!, quote: x, customer: x.customer, lines })}>Download PDF</button>
      {x.status !== 'converted' && <>
        <ConfirmButton className="btn danger" label="Delete" confirm="Delete?" onConfirm={() => act.run(async () => { await q(supabase.from('sales_quotes').delete().eq('id', id) as any); nav('/quotes'); }, 'Deleted')} />
        <Link className="btn" to={`/quotes/${id}/edit`}>Edit</Link>
        {x.status === 'draft' && <button className="btn" type="button" onClick={() => setStatus('sent')}>Mark sent</button>}
        {x.kind === 'quote' && x.status !== 'accepted' && <button className="btn" type="button" onClick={() => setStatus('accepted')}>Mark accepted</button>}
        <button className="btn primary" type="button" disabled={act.busy} onClick={() => act.run(async () => { const inv = await rpc<string>('convert_quote', { p_quote: id }); nav(`/invoices/${inv}/edit`); }, 'Draft invoice created')}>Convert to invoice</button></>}
      {x.invoice && <Link className="btn primary" to={'/invoices/' + x.invoice.id}>Open invoice {x.invoice.number || '(draft)'}</Link>}
      {projects.map(p => <Link key={p.id} className="btn" to={'/projects/' + p.id}>Project {p.number}</Link>)}
      {x.kind === 'order' && !projects.length && can('sales', 'project_manager') && <button className="btn" type="button" onClick={() => setMkProject('')}>Create project</button>}
    </PageHead>
    {mkProject !== null && <FormModal title="Create a project from this order" submit="Create project" busy={act.busy} onClose={() => setMkProject(null)}
      onSave={() => act.run(async () => { const pid = await rpc<string>('create_project_from_order', { p_order: id, p_template: mkProject || null }); nav('/projects/' + pid); }, 'Project created')}>
      <p style={{ margin: 0 }}>Makes a fixed-price project for {x.customer.name} worth the order total (excl. VAT) in {x.currency}, with one task per order line and a single billing milestone you can split later. You become the project manager.</p>
      {(templates || []).length > 0 && <Select label="Also copy the plan from a template" id="mk-tpl" value={mkProject} onChange={setMkProject} options={[['', 'No template'], ...templates!.map(t => [t.id, t.name] as [string, string])]} />}
    </FormModal>}
    <Panel>
      <div className="body grid-form">
        <div><div className="label">Date</div>{longDate(x.quote_date)}</div>
        {x.valid_until && <div><div className="label">Valid until</div>{longDate(x.valid_until)}</div>}
        <div><div className="label">Total incl. tax (estimate)</div><b className="num">{amt(x.total, x.currency)}</b></div>
      </div>
      <DocLines lines={lines} currency={x.currency} />
      {x.notes && <div className="body note">{x.notes}</div>}
    </Panel>
  </>;
}
