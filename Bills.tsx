import { ApprovalBox } from './Finance';
import { DimSelects, useDims } from '../components/dims';
import { useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { q, qPage, rpc, supabase } from '../lib/supabase';
import { fetchAll, Pager, SearchBox, usePaged } from '../components/paging';
import { useSession } from '../lib/session';
import { cedis, longDate, money, qty, r2, taxPreview, today } from '../lib/format';
import { downloadCsv } from '../lib/download';
import { billPdf, methodName, tablePdf } from '../lib/pdf';
import { ConfirmButton, Downloads, Empty, Field, FormModal, Loading, PageHead, Panel, Select, Status, useAction, useLoad } from '../components/ui';
import { amt, CurrencyFields, useCurrencies } from '../components/docs';

export function BillsPage() {
  const { cid, company } = useSession();
  const nav = useNavigate();
  const act = useAction();
  const [status, setStatus] = useState('all');
  const [search, setSearch] = useState('');
  const [from, setFrom] = useState('');
  const [to, setTo] = useState('');
  const isNo = (s: string) => /^[A-Z]{2,4}-?\d/i.test(s);
  const sel = search && !isNo(search) ? '*, supplier:suppliers!inner(name)' : '*, supplier:suppliers(name)';
  const build = () => {
    let qy: any = supabase.from('bills').select(sel, { count: 'exact' }).eq('company_id', cid);
    if (status !== 'all') qy = qy.eq('status', status);
    if (from) qy = qy.gte('bill_date', from);
    if (to) qy = qy.lte('bill_date', to);
    if (search) qy = isNo(search) ? qy.or(`number.ilike.%${search}%,supplier_ref.ilike.%${search}%`) : qy.ilike('supplier.name', `%${search}%`);
    return qy.order('bill_date', { ascending: false }).order('created_at', { ascending: false });
  };
  const pg = usePaged((a, b) => qPage(build().range(a, b)), [cid, status, search, from, to]);
  const head = ['Bill', 'Supplier ref.', 'Date', 'Supplier', 'Status', 'Currency', 'Subtotal', 'VAT', 'NHIL', 'GETFund', 'Total', 'Paid', 'Balance'];
  const toRows = (list: any[]) => list.map(b => [b.number || 'Draft', b.supplier_ref || '', b.bill_date, b.supplier?.name, b.status, b.currency || 'GHS', money(b.subtotal), money(b.vat), money(b.nhil), money(b.getfund), money(b.total), money(b.amount_paid), money(Number(b.total) - Number(b.amount_paid))]);
  const download = (kind: 'pdf' | 'csv') => act.run(async () => {
    const list = await fetchAll(async (a, b) => (await qPage(build().range(a, b))).rows as any[]);
    const sum = (k: string) => list.reduce((x, b) => x + Number(b[k]) * Number(b.exchange_rate || 1), 0);
    if (kind === 'csv') return downloadCsv('supplier-bills', head, toRows(list));
    tablePdf({ company: company!, title: 'Supplier bills', head, body: toRows(list), rightAlign: [6, 7, 8, 9, 10, 11, 12], landscape: true, filename: 'supplier-bills',
      foot: ['', '', '', '', 'Totals in GHS', '', money(sum('subtotal')), money(sum('vat')), money(sum('nhil')), money(sum('getfund')), money(sum('total')), money(sum('amount_paid')), money(sum('total') - sum('amount_paid'))] });
  });
  return <>
    <PageHead title="Supplier bills" sub={pg.data ? `${pg.total.toLocaleString()} bill${pg.total === 1 ? '' : 's'} match` : undefined}>
      <Downloads pdf={() => download('pdf')} csv={() => download('csv')} />
      <Link className="btn primary" to="/bills/new">New bill</Link>
    </PageHead>
    <div className="filters">
      <SearchBox value={search} onChange={setSearch} placeholder="Supplier, bill no. or their ref." id="b-search" />
      <Select label="Status" id="b-status" value={status} onChange={setStatus} options={[['all', 'All'], ['draft', 'Draft'], ['posted', 'Unpaid'], ['paid', 'Paid']]} />
      <Field label="From" id="b-from" type="date" value={from} onChange={setFrom} />
      <Field label="To" id="b-to" type="date" value={to} onChange={setTo} />
    </div>
    <Loading error={pg.error} loading={pg.loading && !pg.data} />
    {pg.data && <Panel>{pg.rows.length ? <div className="scroll"><table>
      <thead><tr><th>Bill</th><th>Date</th><th>Supplier</th><th>Their ref.</th><th className="r">Total</th><th className="r">Balance</th><th>Status</th></tr></thead>
      <tbody>{pg.rows.map((b: any) => <tr key={b.id} className="click" tabIndex={0} onClick={() => nav('/bills/' + b.id)} onKeyDown={e => e.key === 'Enter' && nav('/bills/' + b.id)}>
        <td className="num">{b.number || 'Draft'}</td><td className="num">{b.bill_date}</td><td>{b.supplier?.name}</td><td>{b.supplier_ref}</td>
        <td className="r num">{amt(b.total, b.currency)}</td><td className="r num">{money(Number(b.total) - Number(b.amount_paid))}</td><td><Status s={b.status} kind="bill" /></td></tr>)}</tbody>
    </table></div> : <Empty>No supplier bills match. Record stock purchases and expenses here.</Empty>}
      <Pager {...pg} noun="bills" />
    </Panel>}
  </>;
}

type Line = { target: string; description: string; qty: string; unit_cost: string; taxable: boolean; project_id?: string; project_category?: string; request_id?: string | null; cost_centre_id?: string; po_line_id?: string | null; billable?: boolean };
const emptyLine = (): Line => ({ target: '', description: '', qty: '1', unit_cost: '', taxable: true, project_id: '' });

export function BillEditor() {
  const { id } = useParams();
  const { cid } = useSession();
  const { data: dims } = useDims(cid);
  const { data: currencies } = useCurrencies(cid);
  const nav = useNavigate();
  const act = useAction();
  const [form, setForm] = useState<any>(null);
  const [lines, setLines] = useState<Line[]>([]);

  const { data, error, loading } = useLoad(async () => {
    const [suppliers, products, accounts, projects, warehouses] = await Promise.all([
      q<any[]>(supabase.from('suppliers').select('id,name').eq('company_id', cid).order('name') as any),
      q<any[]>(supabase.from('products').select('id,name,cost,unit').eq('company_id', cid).eq('active', true).order('name') as any),
      q<any[]>(supabase.from('accounts').select('id,code,name').eq('company_id', cid).in('type', ['expense', 'asset']).eq('active', true).order('code') as any),
      q<any[]>(supabase.from('projects').select('id,name,number').eq('company_id', cid).eq('is_template', false).in('status', ['planned', 'active', 'on_hold', 'done']).order('name') as any),
      q<any[]>(supabase.from('warehouses').select('id,code,name,is_default').eq('company_id', cid).eq('active', true).order('code') as any).catch(() => [] as any[]),
    ]);
    if (id) {
      const b = await q<any>(supabase.from('bills').select('*').eq('id', id).single() as any);
      if (b.status !== 'draft') throw new Error('Posted bills cannot be edited.');
      const ls = await q<any[]>(supabase.from('bill_lines').select('*').eq('bill_id', id).order('sort') as any);
      setForm({ supplier_id: b.supplier_id, supplier_ref: b.supplier_ref || '', bill_date: b.bill_date, due_date: b.due_date || '', notes: b.notes || '', currency: b.currency || 'GHS', exchange_rate: String(b.exchange_rate || 1), branch_id: b.branch_id || '', cost_centre_id: b.cost_centre_id || '', warehouse_id: b.warehouse_id || '' });
      setLines(ls.map(l => ({ target: l.product_id ? 'p:' + l.product_id : 'a:' + l.account_id, description: l.description, qty: String(l.qty), unit_cost: String(l.unit_cost), taxable: l.taxable, project_id: l.project_id || '', project_category: l.project_category || '', request_id: l.request_id, cost_centre_id: l.cost_centre_id || '', po_line_id: l.po_line_id, billable: !!l.billable })));
    } else {
      setForm({ supplier_id: suppliers[0]?.id || '', supplier_ref: '', bill_date: today(), due_date: '', notes: '', currency: 'GHS', exchange_rate: '1', branch_id: '', cost_centre_id: '', warehouse_id: '' });
      setLines([emptyLine()]);
    }
    return { suppliers, products, projects, warehouses, accounts: accounts.filter(a => !['1000', '1010', '1100', '1200', '1300', '1410', '1420', '1430'].includes(a.code)) };
  }, [cid, id]);

  if (!data || !form) return <Loading error={error} loading={loading} />;
  if (!data.suppliers.length) return <><PageHead title="New supplier bill" /><Empty>Add a supplier first. <Link to="/suppliers">Go to Suppliers</Link>.</Empty></>;

  const setLine = (i: number, patch: Partial<Line>) => setLines(ls => ls.map((l, j) => (j === i ? { ...l, ...patch } : l)));
  const pick = (i: number, v: string) => {
    if (v.startsWith('p:')) { const p = data.products.find(x => x.id === v.slice(2)); setLine(i, { target: v, description: p?.name || '', unit_cost: String(p?.cost ?? '') }); }
    else { const a = data.accounts.find(x => x.id === v.slice(2)); setLine(i, { target: v, description: lines[i].description || a?.name || '' }); }
  };
  const subtotal = lines.reduce((a, l) => a + r2(Number(l.qty) * Number(l.unit_cost) || 0), 0);
  const taxable = lines.filter(l => l.taxable).reduce((a, l) => a + r2(Number(l.qty) * Number(l.unit_cost) || 0), 0);
  const t = taxPreview(subtotal, taxable);

  const save = (post: boolean) => act.run(async () => {
    const valid = lines.filter(l => l.target && l.description.trim() && Number(l.qty) > 0);
    if (!valid.length) throw new Error('Each line needs a product or expense account, a description and a quantity.');
    const row = { supplier_id: form.supplier_id, supplier_ref: form.supplier_ref || null, bill_date: form.bill_date, due_date: form.due_date || null, notes: form.notes || null,
      branch_id: form.branch_id || null, cost_centre_id: form.cost_centre_id || null, warehouse_id: form.warehouse_id || null,
      currency: form.currency, exchange_rate: form.currency === 'GHS' ? 1 : Number(form.exchange_rate) };
    let billId = id;
    if (billId) {
      await q(supabase.from('bills').update(row).eq('id', billId) as any);
      await q(supabase.from('bill_lines').delete().eq('bill_id', billId) as any);
    } else billId = (await q<any>(supabase.from('bills').insert({ ...row, company_id: cid }).select('id').single() as any)).id;
    await q(supabase.from('bill_lines').insert(valid.map((l, i) => ({
      bill_id: billId, company_id: cid, product_id: l.target.startsWith('p:') ? l.target.slice(2) : null, account_id: l.target.startsWith('a:') ? l.target.slice(2) : null,
      description: l.description.trim(), qty: Number(l.qty), unit_cost: Number(l.unit_cost) || 0, taxable: l.taxable, sort: i, project_id: l.project_id || null, project_category: l.project_id ? (l.project_category || null) : null, request_id: l.request_id || null, cost_centre_id: l.cost_centre_id || form.cost_centre_id || null,
      po_line_id: l.po_line_id || null, billable: !!(l.project_id && l.billable),
    }))) as any);
    if (post) await rpc('post_bill', { p_bill: billId });
    nav('/bills/' + billId, { replace: true });
  }, post ? 'Bill posted: stock and input VAT recorded' : 'Draft saved');

  return <>
    <PageHead title={id ? 'Edit draft bill' : 'New supplier bill'} sub="Stock lines update quantities and average cost. VAT, NHIL and GETFund on purchases are recorded as recoverable input tax.">
      <Link className="btn" to={id ? '/bills/' + id : '/bills'}>Cancel</Link>
    </PageHead>
    <Panel>
      <div className="body grid-form">
        <Select label="Supplier" id="b-sup" value={form.supplier_id} onChange={v => setForm({ ...form, supplier_id: v })} options={data.suppliers.map(s => [s.id, s.name])} />
        <Field label="Supplier's invoice no." id="b-ref" value={form.supplier_ref} onChange={v => setForm({ ...form, supplier_ref: v })} />
        <Field label="Bill date" id="b-date" type="date" value={form.bill_date} onChange={v => setForm({ ...form, bill_date: v })} required />
        <Field label="Due date (default 30 days)" id="b-due" type="date" value={form.due_date} onChange={v => setForm({ ...form, due_date: v })} />
        <CurrencyFields idPrefix="b" currency={form.currency} rate={form.exchange_rate} currencies={currencies || []} onChange={(c, r) => setForm({ ...form, currency: c, exchange_rate: r })} />
        <DimSelects dims={dims} branch={form.branch_id} centre={form.cost_centre_id} onChange={(b, c) => setForm({ ...form, branch_id: b, cost_centre_id: c })} idPrefix="b" />
        {data.warehouses.length > 1 && <Select label="Stock goes into" id="b-wh" value={form.warehouse_id} onChange={v => setForm({ ...form, warehouse_id: v })} options={[['', 'Main store'], ...data.warehouses.filter(w => !w.is_default).map(w => [w.id, `${w.code} · ${w.name}`] as [string, string])]} />}
      </div>
      <div className="scroll"><table className="lines">
        <thead><tr><th>Stock item or expense</th><th>Description</th><th className="r">Qty</th><th className="r">Unit cost ({form.currency})</th><th>VAT</th>{data.projects.length > 0 && <th>Project</th>}{(dims?.centres.length || 0) > 0 && <th>Cost centre</th>}<th className="r">Amount</th><th></th></tr></thead>
        <tbody>{lines.map((l, i) => <tr key={i}>
          <td style={{ minWidth: 210 }}><select aria-label="Stock item or expense account" value={l.target} onChange={e => pick(i, e.target.value)}>
            <option value="">Choose…</option>
            <optgroup label="Stock items">{data.products.map(p => <option key={p.id} value={'p:' + p.id}>{p.name}</option>)}</optgroup>
            <optgroup label="Expense and asset accounts">{data.accounts.map(a => <option key={a.id} value={'a:' + a.id}>{a.code} {a.name}</option>)}</optgroup>
          </select></td>
          <td style={{ minWidth: 200 }}><input aria-label="Description" value={l.description} onChange={e => setLine(i, { description: e.target.value })} /></td>
          <td><input aria-label="Quantity" type="number" step="0.001" min="0" value={l.qty} onChange={e => setLine(i, { qty: e.target.value })} style={{ width: 90, textAlign: 'right' }} /></td>
          <td><input aria-label="Unit cost" type="number" step="0.01" min="0" value={l.unit_cost} onChange={e => setLine(i, { unit_cost: e.target.value })} style={{ width: 120, textAlign: 'right' }} /></td>
          <td><input aria-label="Supplier charged VAT" type="checkbox" checked={l.taxable} onChange={e => setLine(i, { taxable: e.target.checked })} /></td>
          {data.projects.length > 0 && <td><select aria-label="Charge to project" value={l.project_id || ''} onChange={e => setLine(i, { project_id: e.target.value })} style={{ minWidth: 130 }}>
            <option value="">—</option>{data.projects.map(p => <option key={p.id} value={p.id}>{p.number ? p.number + ' ' : ''}{p.name}</option>)}</select>
            {l.project_id && <select aria-label="Project cost type" value={l.project_category || ''} onChange={e => setLine(i, { project_category: e.target.value })} style={{ minWidth: 130, marginTop: 4 }}>
              <option value="">Cost type: automatic</option><option value="materials">Materials</option><option value="subcontract">Subcontractor</option>
              <option value="equipment">Equipment hire</option><option value="other">Other expense</option></select>}
            {l.project_id && <label className="check" style={{ fontSize: 12, marginTop: 4 }}><input type="checkbox" checked={!!l.billable} onChange={e => setLine(i, { billable: e.target.checked })} /> Re-bill to client</label>}
            {l.po_line_id && <div className="muted" style={{ fontSize: 11, marginTop: 2 }}>Matched to order</div>}</td>}
          {(dims?.centres.length || 0) > 0 && <td><select aria-label="Cost centre" value={l.cost_centre_id || ''} onChange={e => setLine(i, { cost_centre_id: e.target.value })} style={{ minWidth: 90 }}>
            <option value="">{form.cost_centre_id ? 'As bill' : '—'}</option>{dims!.centres.map(c => <option key={c.id} value={c.id}>{c.code}</option>)}</select></td>}
          <td className="r num">{money(Number(l.qty) * Number(l.unit_cost) || 0)}</td>
          <td><button className="btn ghost small" type="button" disabled={lines.length < 2} onClick={() => setLines(lines.filter((_, j) => j !== i))}>Remove</button></td>
        </tr>)}</tbody></table></div>
      <div style={{ padding: '0 16px' }}><button className="btn small" type="button" onClick={() => setLines([...lines, emptyLine()])}>Add line</button></div>
      <div className="totals">
        <span className="muted">Subtotal</span><span className="num">{money(t.subtotal)}</span>
        <span className="muted">VAT input 15%</span><span className="num">{money(t.vat)}</span>
        <span className="muted">NHIL input 2.5%</span><span className="num">{money(t.nhil)}</span>
        <span className="muted">GETFund input 2.5%</span><span className="num">{money(t.getfund)}</span>
        <span className="grand">Total</span><span className="grand num">{amt(t.total, form.currency)}</span>
      </div>
      <div className="body"><Field label="Notes (optional)" id="b-notes" type="textarea" value={form.notes} onChange={v => setForm({ ...form, notes: v })} /></div>
      <div className="body actions" style={{ justifyContent: 'flex-end', borderTop: '1px solid var(--line)' }}>
        <button className="btn" type="button" disabled={act.busy} onClick={() => save(false)}>Save draft</button>
        <button className="btn primary" type="button" disabled={act.busy} onClick={() => save(true)}>Save and post</button>
      </div>
    </Panel>
  </>;
}

export function BillView() {
  const { id } = useParams();
  const { company } = useSession();
  const nav = useNavigate();
  const act = useAction();
  const [pay, setPay] = useState<any | null>(null);
  const { data, error, loading, reload } = useLoad(async () => {
    const b = await q<any>(supabase.from('bills').select('*, supplier:suppliers(*)').eq('id', id).single() as any);
    const [lines, payments] = await Promise.all([
      q<any[]>(supabase.from('bill_lines').select('*').eq('bill_id', id).order('sort') as any),
      q<any[]>(supabase.from('bill_payments').select('*').eq('bill_id', id).order('payment_date') as any),
    ]);
    return { b, lines, payments };
  }, [id]);
  if (!data) return <Loading error={error} loading={loading} />;
  const { b, lines, payments } = data;
  const cur = b.currency || 'GHS';
  const due = r2(Number(b.total) - Number(b.amount_paid));
  return <>
    <PageHead title={b.number || 'Draft bill'} sub={<><Status s={b.status} kind="bill" /> <span className="muted">· {b.supplier.name}{b.supplier_ref ? ` · their ref. ${b.supplier_ref}` : ''}</span></>}>
      <Link className="btn" to="/bills">Back</Link>
      <button className="btn" type="button" onClick={() => billPdf({ company: company!, bill: b, supplier: b.supplier, lines, payments })}>Download PDF</button>
      {b.status === 'draft' && <>
        <ConfirmButton className="btn danger" label="Delete draft" confirm="Delete this draft?" onConfirm={() => act.run(async () => { await q(supabase.from('bills').delete().eq('id', id) as any); nav('/bills'); }, 'Draft deleted')} />
        <Link className="btn" to={`/bills/${id}/edit`}>Edit</Link>
        <button className="btn primary" type="button" disabled={act.busy} onClick={() => act.run(async () => { await rpc('post_bill', { p_bill: id }); reload(); }, 'Bill posted')}>Post bill</button>
      </>}
      {b.status === 'posted' && <button className="btn primary" type="button" onClick={() => setPay({ amount: String(due), method: 'bank', date: today(), reference: '', rate: String(b.exchange_rate) })}>Pay supplier</button>}
    </PageHead>
    {b.status === 'draft' && <ApprovalBox docType="bill" docId={id!} onChange={reload} />}
    <Panel>
      <div className="body grid-form">
        <div><div className="label">Date</div>{longDate(b.bill_date)}</div>
        <div><div className="label">Due</div>{longDate(b.due_date) || '—'}</div>
        <div><div className="label">Total</div><b className="num">{amt(b.total, cur)}</b></div>
        <div><div className="label">Balance owed</div><b className="num">{amt(due, cur)}</b></div>
        {cur !== 'GHS' && <div><div className="label">Exchange rate</div><span className="num">GH₵ {b.exchange_rate} per {cur}</span></div>}
      </div>
      <div className="scroll"><table>
        <thead><tr><th>Description</th><th className="r">Qty</th><th className="r">Unit cost</th><th className="r">Amount (GH₵)</th></tr></thead>
        <tbody>{lines.map(l => <tr key={l.id}><td className="wrap-cell">{l.description}{l.product_id && <span className="pill" style={{ marginLeft: 6 }}>Stock</span>}</td>
          <td className="r num">{qty(l.qty)}</td><td className="r num">{money(l.unit_cost)}</td><td className="r num">{money(Number(l.qty) * Number(l.unit_cost))}</td></tr>)}</tbody>
      </table></div>
      {b.status !== 'draft' && <div className="totals">
        <span className="muted">Subtotal</span><span className="num">{money(b.subtotal)}</span>
        <span className="muted">VAT input</span><span className="num">{money(b.vat)}</span>
        <span className="muted">NHIL input</span><span className="num">{money(b.nhil)}</span>
        <span className="muted">GETFund input</span><span className="num">{money(b.getfund)}</span>
        <span className="grand">Total</span><span className="grand num">{amt(b.total, cur)}</span></div>}
    </Panel>
    {payments.length > 0 && <Panel title="Payments made"><div className="scroll"><table>
      <thead><tr><th>Date</th><th>Method</th><th>Reference</th><th className="r">Amount (GH₵)</th></tr></thead>
      <tbody>{payments.map(p => <tr key={p.id}><td className="num">{p.payment_date}</td><td>{methodName(p.method)}</td><td>{p.reference}</td><td className="r num">{money(p.amount)}</td></tr>)}</tbody>
    </table></div></Panel>}
    {pay && <FormModal title={`Pay ${b.supplier.name}`} submit="Record payment" busy={act.busy} onClose={() => setPay(null)}
      onSave={() => act.run(async () => { await rpc('pay_bill', { p_bill: id, p_amount: Number(pay.amount), p_date: pay.date, p_method: pay.method, p_reference: pay.reference || null, p_rate: cur === 'GHS' ? null : Number(pay.rate) }); setPay(null); reload(); }, 'Payment recorded and posted')}>
      <div className="grid-form">
        {cur !== 'GHS' && <Field label={`Rate on payment day (GH₵ per ${cur})`} id="bp-rate" type="number" step="0.000001" min="0.000001" value={pay.rate} onChange={v => setPay({ ...pay, rate: v })} required />}
        <Field label={`Amount (${cur})`} id="bp-amt" type="number" step="0.01" min="0.01" value={pay.amount} onChange={v => setPay({ ...pay, amount: v })} required />
        <Select label="Paid from" id="bp-m" value={pay.method} onChange={v => setPay({ ...pay, method: v })} options={[['bank', 'Bank'], ['momo', 'Mobile Money'], ['cash', 'Cash']]} />
        <Field label="Date" id="bp-d" type="date" value={pay.date} onChange={v => setPay({ ...pay, date: v })} required />
        <Field label="Reference" id="bp-ref" value={pay.reference} onChange={v => setPay({ ...pay, reference: v })} />
      </div>
    </FormModal>}
  </>;
}
