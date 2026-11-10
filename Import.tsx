import { useState } from 'react';
import { q, rpc, supabase } from '../lib/supabase';
import { useSession } from '../lib/session';
import { cedis, money, today } from '../lib/format';
import { downloadCsv } from '../lib/download';
import { readSheet, toIsoDate, toNum } from '../lib/sheet';
import { Empty, Field, PageHead, Panel, useAction } from '../components/ui';

type Kind = 'customers' | 'suppliers' | 'products' | 'employees' | 'opening_tb';
type Col = { key: string; label: string; required?: boolean; kind?: 'num' | 'date' | 'bool'; example: string };
const SPECS: Record<Kind, { title: string; who: string; cols: Col[]; note: string }> = {
  customers: { title: 'Customers', who: 'accountant or sales', note: 'Opening balance = what the customer owed on the opening date. It becomes an open item you can collect against, age and put on a statement.',
    cols: [{ key: 'name', label: 'Name', required: true, example: 'Kumasi Mart Ltd' }, { key: 'phone', label: 'Phone', example: '0244123456' }, { key: 'email', label: 'Email', example: 'accounts@kumasimart.com' },
      { key: 'tin', label: 'TIN', example: 'C0012345678' }, { key: 'city', label: 'Town', example: 'Kumasi' }, { key: 'address', label: 'Address', example: 'AK-039-5028' },
      { key: 'opening_balance', label: 'Opening balance', kind: 'num', example: '1500' }, { key: 'reference', label: 'Old invoice no.', example: 'INV-OLD-77' }, { key: 'due_date', label: 'Due date', kind: 'date', example: '2026-12-15' }] },
  suppliers: { title: 'Suppliers', who: 'accountant', note: 'Opening balance = what you owed the supplier on the opening date.',
    cols: [{ key: 'name', label: 'Name', required: true, example: 'Tema Wholesale' }, { key: 'phone', label: 'Phone', example: '0302123456' }, { key: 'email', label: 'Email', example: '' },
      { key: 'tin', label: 'TIN', example: '' }, { key: 'city', label: 'Town', example: 'Tema' }, { key: 'address', label: 'Address', example: '' },
      { key: 'opening_balance', label: 'Opening balance', kind: 'num', example: '800' }, { key: 'reference', label: 'Their invoice no.', example: 'SUP-991' }, { key: 'due_date', label: 'Due date', kind: 'date', example: '' }] },
  products: { title: 'Items and opening stock', who: 'accountant or sales', note: 'Opening quantity and unit cost post the stock value to the books on the opening date.',
    cols: [{ key: 'sku', label: 'SKU', required: true, example: 'RIC-25' }, { key: 'name', label: 'Name', required: true, example: 'Rice 25 kg' }, { key: 'unit', label: 'Unit', example: 'bag' },
      { key: 'price', label: 'Selling price', kind: 'num', example: '520' }, { key: 'taxable', label: 'VAT applies (yes/no)', kind: 'bool', example: 'yes' }, { key: 'reorder_level', label: 'Reorder level', kind: 'num', example: '20' },
      { key: 'category', label: 'Category', example: 'Food' }, { key: 'barcode', label: 'Barcode', example: '' }, { key: 'item_type', label: 'Type (stock/non_stock/service)', example: 'stock' }, { key: 'reorder_qty', label: 'Reorder quantity', kind: 'num', example: '50' },
      { key: 'opening_qty', label: 'Opening quantity', kind: 'num', example: '100' }, { key: 'opening_cost', label: 'Opening unit cost', kind: 'num', example: '410' }] },
  employees: { title: 'Employees', who: 'HR', note: 'Branch and cost centre use the short codes set under Settings. Pay method is bank, momo or cash.',
    cols: [{ key: 'full_name', label: 'Full name', required: true, example: 'Ama Owusu' }, { key: 'staff_no', label: 'Staff no.', example: 'E001' }, { key: 'job_title', label: 'Job title', example: 'Accountant' },
      { key: 'department', label: 'Department', example: 'Finance' }, { key: 'hire_date', label: 'Hire date', kind: 'date', example: '2024-03-01' }, { key: 'basic_salary', label: 'Basic salary', kind: 'num', required: true, example: '4500' },
      { key: 'allowances', label: 'Allowances', kind: 'num', example: '600' }, { key: 'ghana_card', label: 'Ghana Card', example: 'GHA-000000000-0' }, { key: 'ssnit_no', label: 'SSNIT no.', example: 'C123456789012' },
      { key: 'tin', label: 'TIN', example: '' }, { key: 'pay_method', label: 'Pay method', example: 'bank' }, { key: 'bank_name', label: 'Bank', example: 'GCB Bank' }, { key: 'bank_branch', label: 'Bank branch', example: 'Adum' },
      { key: 'bank_account', label: 'Account no.', example: '1021130000001' }, { key: 'momo_number', label: 'MoMo number', example: '' }, { key: 'phone', label: 'Phone', example: '0244000000' },
      { key: 'email', label: 'Email', example: '' }, { key: 'branch', label: 'Branch code', example: 'KSI' }, { key: 'cost_centre', label: 'Cost centre code', example: 'OPS' }, { key: 'is_junior', label: 'Junior staff (yes/no)', kind: 'bool', example: 'no' }] },
  opening_tb: { title: 'Opening trial balance', who: 'accountant', note: 'All accounts except receivables, payables and stock (those come from the customer, supplier and product imports). Any difference goes to 3050 Opening balance equity.',
    cols: [{ key: 'code', label: 'Account code', required: true, example: '1100' }, { key: 'name', label: 'Account name (for reference)', example: 'Bank account' },
      { key: 'debit', label: 'Debit', kind: 'num', example: '25000' }, { key: 'credit', label: 'Credit', kind: 'num', example: '' }] },
};
const norm = (s: string) => s.toLowerCase().replace(/[^a-z0-9]/g, '');
const yes = (v: string) => /^(y|yes|true|1|x)$/i.test(String(v || '').trim());

export function ImportPage() {
  const { cid, can } = useSession();
  const act = useAction();
  const [kind, setKind] = useState<Kind>('customers');
  const [rows, setRows] = useState<any[] | null>(null);
  const [fileName, setFileName] = useState('');
  const [openDate, setOpenDate] = useState(() => { const d = new Date(); d.setUTCDate(0); return d.toISOString().slice(0, 10); });
  const [progress, setProgress] = useState('');
  const [done, setDone] = useState<string | null>(null);
  const spec = SPECS[kind];
  const allowed = kind === 'employees' ? can('hr') : kind === 'opening_tb' || kind === 'suppliers' ? can('accountant') : can('accountant', 'sales');

  const load = (file: File) => act.run(async () => {
    setDone(null); setFileName(file.name);
    const grid = await readSheet(file);
    if (grid.length < 2) throw new Error('The file has no data rows under the header.');
    const header = grid[0].map(norm);
    const idx = spec.cols.map(c => header.findIndex(h => h === norm(c.label) || h === norm(c.key)));
    const missing = spec.cols.filter((c, i) => c.required && idx[i] < 0);
    if (missing.length) throw new Error(`Missing column${missing.length > 1 ? 's' : ''}: ${missing.map(m => m.label).join(', ')}. Download the template to see the headings.`);
    let ctx: any = {};
    if (kind === 'opening_tb') ctx.accounts = await q<any[]>(supabase.from('accounts').select('id,code,name,system_key').eq('company_id', cid) as any);
    if (kind === 'employees') {
      ctx.branches = await q<any[]>(supabase.from('branches').select('id,code').eq('company_id', cid) as any);
      ctx.centres = await q<any[]>(supabase.from('cost_centres').select('id,code').eq('company_id', cid) as any);
    }
    if (['customers', 'suppliers'].includes(kind)) ctx.existing = new Set((await fetchNames(kind as any, cid)).map(n => n.toLowerCase()));
    if (kind === 'products') ctx.existing = new Set((await q<any[]>(supabase.from('products').select('sku').eq('company_id', cid) as any)).map(p => String(p.sku).toLowerCase()));
    const seen = new Set<string>();
    const out = grid.slice(1).map((r, n) => {
      const v: any = { _row: n + 2, _errors: [] as string[] };
      spec.cols.forEach((c, i) => {
        const raw = idx[i] >= 0 ? String(r[idx[i]] ?? '').trim() : '';
        if (c.kind === 'num') { const x = toNum(raw); if (Number.isNaN(x)) v._errors.push(`${c.label} is not a number`); v[c.key] = x; }
        else if (c.kind === 'date') { const d = toIsoDate(raw); if (raw && !d) v._errors.push(`${c.label} is not a date`); v[c.key] = d; }
        else if (c.kind === 'bool') v[c.key] = raw ? yes(raw) : null;
        else v[c.key] = raw;
        if (c.required && (v[c.key] === '' || v[c.key] === null)) v._errors.push(`${c.label} is required`);
      });
      const key = String(v.name || v.sku || v.full_name || v.code || '').toLowerCase();
      if (['customers', 'suppliers', 'products'].includes(kind)) {
        const k = kind === 'products' ? String(v.sku).toLowerCase() : key;
        if (ctx.existing.has(k)) v._skip = 'Already exists';
        if (seen.has(k)) v._errors.push('Duplicate in this file'); seen.add(k);
      }
      if (v.opening_balance != null && v.opening_balance < 0) v._errors.push('Opening balance cannot be negative');
      if (kind === 'products' && (v.opening_qty || 0) > 0 && !(v.opening_cost > 0)) v._errors.push('Opening unit cost is needed with an opening quantity');
      if (kind === 'employees') {
        if (v.branch) { v.branch_id = ctx.branches.find((b: any) => b.code.toLowerCase() === v.branch.toLowerCase())?.id; if (!v.branch_id) v._errors.push(`Branch ${v.branch} not found`); }
        if (v.cost_centre) { v.cost_centre_id = ctx.centres.find((b: any) => b.code.toLowerCase() === v.cost_centre.toLowerCase())?.id; if (!v.cost_centre_id) v._errors.push(`Cost centre ${v.cost_centre} not found`); }
        if (v.pay_method && !['bank', 'momo', 'cash'].includes(v.pay_method.toLowerCase())) v._errors.push('Pay method must be bank, momo or cash');
      }
      if (kind === 'opening_tb') {
        const a = ctx.accounts.find((x: any) => x.code === v.code);
        if (!a) v._errors.push(`Account ${v.code} not found`);
        else { v.account_id = a.id; v.account_name = a.name; if (['ar', 'ap', 'inventory', 'opening'].includes(a.system_key)) v._errors.push(`${a.name} comes from the customer, supplier or product import`); }
        if (!(v.debit > 0) && !(v.credit > 0)) v._skip = 'No amount';
      }
      return v;
    });
    setRows(out);
  });

  const good = (rows || []).filter(r => !r._errors.length && !r._skip);
  const bad = (rows || []).filter(r => r._errors.length);
  const tbDr = kind === 'opening_tb' ? good.reduce((s, r) => s + (r.debit || 0), 0) : 0, tbCr = kind === 'opening_tb' ? good.reduce((s, r) => s + (r.credit || 0), 0) : 0;

  const run = () => act.run(async () => {
    if (bad.length) throw new Error(`Fix the ${bad.length} row${bad.length === 1 ? '' : 's'} with problems first (or remove them from the file).`);
    if (!can('accountant') && good.some(r => (r.opening_balance || 0) > 0)) throw new Error('Only an accountant can bring in opening balances. Remove the Opening balance column or ask an accountant to import.');
    let n = 0;
    const step = (label: string) => setProgress(`${label} ${++n} of ${good.length}…`);
    if (kind === 'opening_tb') {
      await rpc('post_opening_balances', { cid, p_date: openDate, p_lines: good.map(r => ({ account_id: r.account_id, debit: r.debit || 0, credit: r.credit || 0 })) });
      setDone(`Opening trial balance posted at ${openDate}${tbDr !== tbCr ? `; the difference of ${cedis(Math.abs(tbDr - tbCr))} went to 3050 Opening balance equity` : ''}.`);
    } else if (kind === 'customers' || kind === 'suppliers') {
      for (let i = 0; i < good.length; i += 200) {
        const batch = good.slice(i, i + 200);
        const ins = await q<any[]>(supabase.from(kind).insert(batch.map(r => ({ company_id: cid, name: r.name, phone: r.phone || null, email: r.email || null, tin: r.tin || null, city: r.city || null, address: r.address || null }))).select('id,name') as any);
        for (const r of batch) {
          step('Saving');
          if (r.opening_balance > 0) {
            const id = ins.find(x => x.name === r.name)?.id;
            await rpc(kind === 'customers' ? 'opening_receivable' : 'opening_payable', { [kind === 'customers' ? 'p_customer' : 'p_supplier']: id, p_date: openDate, p_amount: r.opening_balance, p_ref: r.reference || null, p_due: r.due_date || null });
          }
        }
      }
      setDone(`${good.length} ${kind} imported${good.some(r => r.opening_balance > 0) ? `, with opening balances totalling ${cedis(good.reduce((s, r) => s + (r.opening_balance || 0), 0))}` : ''}.`);
    } else if (kind === 'products') {
      for (let i = 0; i < good.length; i += 200) {
        const batch = good.slice(i, i + 200);
        const ins = await q<any[]>(supabase.from('products').insert(batch.map(r => ({ company_id: cid, sku: r.sku, name: r.name, unit: r.unit || 'each', price: r.price || 0, taxable: r.taxable ?? true, reorder_level: r.reorder_level || 0, reorder_qty: r.reorder_qty || 0, category: r.category || null, barcode: r.barcode || null, item_type: ['non_stock', 'service'].includes(String(r.item_type || '').toLowerCase().replace(/[- ]/g, '_')) ? String(r.item_type).toLowerCase().replace(/[- ]/g, '_') : 'stock' }))).select('id,sku') as any);
        for (const r of batch) {
          step('Saving');
          if ((r.opening_qty || 0) > 0) await rpc('adjust_stock', { p_product: ins.find(x => x.sku === r.sku)?.id, p_qty: r.opening_qty, p_unit_cost: r.opening_cost, p_date: openDate, p_kind: 'opening', p_note: 'Opening stock (import)' });
        }
      }
      setDone(`${good.length} products imported${good.some(r => r.opening_qty > 0) ? `, opening stock worth ${cedis(good.reduce((s, r) => s + (r.opening_qty || 0) * (r.opening_cost || 0), 0))} posted` : ''}.`);
    } else {
      for (let i = 0; i < good.length; i += 200) {
        await q(supabase.from('employees').insert(good.slice(i, i + 200).map(r => ({ company_id: cid, full_name: r.full_name, staff_no: r.staff_no || null, job_title: r.job_title || null, department: r.department || null,
          hire_date: r.hire_date, basic_salary: r.basic_salary || 0, allowances: r.allowances || 0, ghana_card: r.ghana_card || null, ssnit_no: r.ssnit_no || null, tin: r.tin || null,
          pay_method: (r.pay_method || 'bank').toLowerCase(), bank_name: r.bank_name || null, bank_branch: r.bank_branch || null, bank_account: r.bank_account || null, momo_number: r.momo_number || null,
          phone: r.phone || null, email: r.email || null, branch_id: r.branch_id || null, cost_centre_id: r.cost_centre_id || null, is_junior: !!r.is_junior }))) as any);
        n += Math.min(200, good.length - i); setProgress(`Saving ${n} of ${good.length}…`);
      }
      setDone(`${good.length} employees imported.`);
    }
    setProgress(''); setRows(null);
  }, 'Import finished');

  return <>
    <PageHead title="Import from a spreadsheet" sub="Bring customers, suppliers, products, staff and opening balances across from your old system or Excel in one go." />
    <div className="actions">{(Object.keys(SPECS) as Kind[]).map(k => <button key={k} type="button" className={'btn small' + (kind === k ? ' primary' : '')} onClick={() => { setKind(k); setRows(null); setDone(null); }}>{SPECS[k].title}</button>)}</div>
    <Panel title={spec.title} pad>
      <ol style={{ margin: '0 0 12px', paddingLeft: 20, display: 'grid', gap: 4 }}>
        <li>Download the template and fill one row per {kind === 'opening_tb' ? 'account' : kind === 'employees' ? 'person' : kind.replace(/s$/, '')}. Keep the headings.</li>
        <li>Save it as Excel (.xlsx) or CSV and choose it below. Nothing is saved until you press Import.</li>
      </ol>
      <p className="muted" style={{ marginTop: 0, fontSize: 13 }}>{spec.note} Needs the {spec.who} role.</p>
      <div className="filters">
        <button className="btn" type="button" style={{ alignSelf: 'end' }} onClick={() => downloadCsv(`asnys-template-${kind}`, spec.cols.map(c => c.label), [spec.cols.map(c => c.example)])}>Download template</button>
        {['customers', 'suppliers', 'products', 'opening_tb'].includes(kind) && <Field label="Opening balance date" id="im-date" type="date" value={openDate} onChange={setOpenDate} />}
        <div className="field"><label htmlFor="im-file">Spreadsheet (.xlsx or .csv)</label>
          <input id="im-file" type="file" accept=".xlsx,.csv,text/csv" disabled={!allowed} onChange={e => { const f = e.target.files?.[0]; if (f) load(f); e.target.value = ''; }} /></div>
      </div>
      {!allowed && <p style={{ color: 'var(--bad)', margin: 0 }}>Your role cannot import {spec.title.toLowerCase()}.</p>}
      {done && <div className="note" role="status" style={{ marginTop: 12 }}>{done}</div>}
    </Panel>
    {rows && <Panel title={`${fileName}: ${good.length} ready, ${bad.length} with problems${rows.filter(r => r._skip).length ? `, ${rows.filter(r => r._skip).length} skipped` : ''}`}
      actions={<button className="btn primary" type="button" disabled={act.busy || !good.length || bad.length > 0} onClick={run}>{progress || `Import ${good.length}`}</button>}>
      {kind === 'opening_tb' && <div className="body">Debits {cedis(tbDr)} · Credits {cedis(tbCr)}{tbDr !== tbCr && <> · difference {cedis(Math.abs(tbDr - tbCr))} will go to 3050 Opening balance equity</>}</div>}
      {rows.length ? <div className="scroll"><table>
        <thead><tr><th>Row</th>{spec.cols.slice(0, 6).map(c => <th key={c.key}>{c.label}</th>)}<th>Check</th></tr></thead>
        <tbody>{[...bad, ...rows.filter(r => !r._errors.length)].slice(0, 200).map(r => <tr key={r._row} style={r._skip ? { opacity: .5 } : undefined}>
          <td className="num">{r._row}</td>{spec.cols.slice(0, 6).map(c => <td key={c.key} className={c.kind === 'num' ? 'num' : ''}>{c.kind === 'num' ? (r[c.key] != null && !Number.isNaN(r[c.key]) ? money(r[c.key]) : '') : c.kind === 'bool' ? (r[c.key] == null ? '' : r[c.key] ? 'Yes' : 'No') : r[c.key]}</td>)}
          <td>{r._errors.length ? <span style={{ color: 'var(--bad)', fontSize: 13 }}>{r._errors.join('; ')}</span> : r._skip ? <span className="muted" style={{ fontSize: 13 }}>{r._skip}, skipped</span> : <span className="pill good">OK</span>}</td></tr>)}</tbody>
      </table></div> : <Empty>No rows.</Empty>}
      {rows.length > 200 && <div className="body muted" style={{ fontSize: 13 }}>Showing the first 200 rows (problems first). All {rows.length} are checked.</div>}
    </Panel>}
  </>;
}

async function fetchNames(table: 'customers' | 'suppliers', cid: string) {
  const out: string[] = [];
  for (let a = 0; a < 100000; a += 1000) {
    const r = await q<any[]>(supabase.from(table).select('name').eq('company_id', cid).range(a, a + 999) as any);
    out.push(...r.map(x => x.name)); if (r.length < 1000) break;
  }
  return out;
}
