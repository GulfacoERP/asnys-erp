import { q, supabase } from '../lib/supabase';
import { money, qty, r2, taxPreview } from '../lib/format';
import { useLoad } from './ui';

export type Currency = { code: string; name: string; rate: number };

/** "GH₵ 1,200.00" for cedis, "USD 1,200.00" otherwise. */
export const amt = (n: number | string | null | undefined, code?: string | null) =>
  (!code || code === 'GHS' ? 'GH₵ ' : code + ' ') + money(n);

export function useCurrencies(cid: string) {
  return useLoad(() => q<Currency[]>(supabase.from('currencies').select('code,name,rate').eq('company_id', cid).order('code') as any), [cid]);
}

/** Currency select and exchange rate (GH₵ per unit). */
export function CurrencyFields({ currency, rate, currencies, onChange, idPrefix }: {
  currency: string; rate: string | number; currencies: Currency[]; idPrefix: string;
  onChange: (currency: string, rate: string) => void;
}) {
  if (!currencies.length) return null;
  return <>
    <div className="field"><label htmlFor={idPrefix + '-ccy'}>Currency</label>
      <select id={idPrefix + '-ccy'} value={currency} onChange={e => {
        const c = currencies.find(x => x.code === e.target.value);
        onChange(e.target.value, c ? String(c.rate) : '1');
      }}>
        <option value="GHS">GHS — Ghana cedi</option>
        {currencies.map(c => <option key={c.code} value={c.code}>{c.code} — {c.name}</option>)}
      </select></div>
    {currency !== 'GHS' && <div className="field"><label htmlFor={idPrefix + '-rate'}>Rate: GH₵ per 1 {currency}</label>
      <input id={idPrefix + '-rate'} type="number" step="0.000001" min="0.000001" value={rate} onChange={e => onChange(currency, e.target.value)} required /></div>}
  </>;
}

export type Line = { product_id: string; description: string; qty: string; unit_price: string; taxable: boolean; restock?: boolean };
export const emptyLine = (): Line => ({ product_id: '', description: '', qty: '1', unit_price: '', taxable: true, restock: false });

export function linesFromRows(rows: any[]): Line[] {
  return rows.map(l => ({ product_id: l.product_id || '', description: l.description, qty: String(l.qty), unit_price: String(l.unit_price), taxable: l.taxable !== false, restock: !!l.restock }));
}

export function cleanLines(lines: Line[]) {
  return lines.filter(l => l.description.trim() && Number(l.qty) > 0);
}

/** Line-item table for quotes, orders, credit notes and recurring templates. */
export function LineItems({ lines, setLines, products, restock, currency }: {
  lines: Line[]; setLines: (l: Line[]) => void; products: any[]; restock?: boolean; currency: string;
}) {
  const set = (i: number, patch: Partial<Line>) => setLines(lines.map((l, j) => (j === i ? { ...l, ...patch } : l)));
  const pick = (i: number, pid: string) => {
    const p = products.find(x => x.id === pid);
    set(i, p ? { product_id: pid, description: p.name, unit_price: String(p.price), taxable: p.taxable } : { product_id: '', restock: false });
  };
  const sub = lines.reduce((a, l) => a + r2(Number(l.qty) * Number(l.unit_price) || 0), 0);
  const tx = lines.filter(l => l.taxable).reduce((a, l) => a + r2(Number(l.qty) * Number(l.unit_price) || 0), 0);
  const t = taxPreview(sub, tx);
  return <>
    <div className="scroll"><table className="lines">
      <thead><tr><th>Product</th><th>Description</th><th className="r">Qty</th><th className="r">Unit price ({currency})</th><th>VAT</th>{restock && <th>Return to stock</th>}<th className="r">Amount</th><th></th></tr></thead>
      <tbody>{lines.map((l, i) => <tr key={i}>
        <td style={{ minWidth: 180 }}><select aria-label="Product" value={l.product_id} onChange={e => pick(i, e.target.value)}>
          <option value="">Service or other</option>
          {products.map(p => <option key={p.id} value={p.id}>{p.name}{p.stock_qty != null ? ` (${qty(p.stock_qty)} ${p.unit})` : ''}</option>)}</select></td>
        <td style={{ minWidth: 190 }}><input aria-label="Description" value={l.description} onChange={e => set(i, { description: e.target.value })} /></td>
        <td><input aria-label="Quantity" type="number" step="0.001" min="0" value={l.qty} onChange={e => set(i, { qty: e.target.value })} style={{ width: 90, textAlign: 'right' }} /></td>
        <td><input aria-label="Unit price" type="number" step="0.01" min="0" value={l.unit_price} onChange={e => set(i, { unit_price: e.target.value })} style={{ width: 120, textAlign: 'right' }} /></td>
        <td><input aria-label="Charge VAT" type="checkbox" checked={l.taxable} onChange={e => set(i, { taxable: e.target.checked })} /></td>
        {restock && <td><input aria-label="Return to stock" type="checkbox" disabled={!l.product_id} checked={!!l.restock} onChange={e => set(i, { restock: e.target.checked })} /></td>}
        <td className="r num">{money(Number(l.qty) * Number(l.unit_price) || 0)}</td>
        <td><button className="btn ghost small" type="button" disabled={lines.length < 2} onClick={() => setLines(lines.filter((_, j) => j !== i))}>Remove</button></td>
      </tr>)}</tbody></table></div>
    <div style={{ padding: '0 16px' }}><button className="btn small" type="button" onClick={() => setLines([...lines, emptyLine()])}>Add line</button></div>
    <div className="totals">
      <span className="muted">Subtotal</span><span className="num">{money(t.subtotal)}</span>
      <span className="muted">VAT 15%</span><span className="num">{money(t.vat)}</span>
      <span className="muted">NHIL 2.5%</span><span className="num">{money(t.nhil)}</span>
      <span className="muted">GETFund 2.5%</span><span className="num">{money(t.getfund)}</span>
      <span className="grand">Total</span><span className="grand num">{amt(t.total, currency)}</span>
    </div>
  </>;
}

/** Read-only line table + tax totals for a posted or saved document. */
export function DocLines({ lines, currency, showRestock }: { lines: any[]; currency: string; showRestock?: boolean }) {
  return <div className="scroll"><table>
    <thead><tr><th>Description</th><th className="r">Qty</th><th className="r">Unit price</th><th className="r">Amount ({currency})</th></tr></thead>
    <tbody>{lines.map(l => <tr key={l.id}><td className="wrap-cell">{l.description}
      {!l.taxable && <span className="pill" style={{ marginLeft: 6 }}>Exempt</span>}
      {showRestock && l.restock && <span className="pill good" style={{ marginLeft: 6 }}>Returned to stock</span>}</td>
      <td className="r num">{qty(l.qty)}</td><td className="r num">{money(l.unit_price)}</td><td className="r num">{money(Number(l.qty) * Number(l.unit_price))}</td></tr>)}</tbody>
  </table></div>;
}
