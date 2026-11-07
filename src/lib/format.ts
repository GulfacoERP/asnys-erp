export const money = (n: number | string | null | undefined) =>
  Number(n || 0).toLocaleString('en-GH', { minimumFractionDigits: 2, maximumFractionDigits: 2 });

export const cedis = (n: number | string | null | undefined) => 'GH₵ ' + money(n);

export const qty = (n: number | string | null | undefined) =>
  Number(n || 0).toLocaleString('en-GH', { maximumFractionDigits: 3 });

export const r2 = (n: number) => Math.round((n + Number.EPSILON) * 100) / 100;

export function today() {
  const d = new Date();
  return new Date(d.getTime() - d.getTimezoneOffset() * 60000).toISOString().slice(0, 10);
}

export function monthStart(d = today()) { return d.slice(0, 8) + '01'; }

export function yearStart(d = today()) { return d.slice(0, 5) + '01-01'; }

export function longDate(iso?: string | null) {
  if (!iso) return '';
  const [y, m, d] = iso.slice(0, 10).split('-').map(Number);
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return `${d} ${months[m - 1]} ${y}`;
}

export function monthName(iso: string) {
  const [y, m] = iso.split('-').map(Number);
  return new Date(Date.UTC(y, m - 1, 1)).toLocaleString('en-GB', { month: 'long', year: 'numeric', timeZone: 'UTC' });
}

/** Ghana VAT Act 2025 (Act 1151): VAT 15%, NHIL 2.5%, GETFund 2.5% on the same taxable value. Preview only — the database computes the posted figures. */
export function taxPreview(subtotal: number, taxable: number) {
  const vat = r2(taxable * 0.15), nhil = r2(taxable * 0.025), getfund = r2(taxable * 0.025);
  return { subtotal: r2(subtotal), vat, nhil, getfund, total: r2(subtotal + vat + nhil + getfund) };
}

export function workingDays(start: string, end: string) {
  let n = 0;
  const d = new Date(start + 'T00:00:00Z'), e = new Date(end + 'T00:00:00Z');
  while (d <= e) { const w = d.getUTCDay(); if (w !== 0 && w !== 6) n++; d.setUTCDate(d.getUTCDate() + 1); }
  return n;
}

export const statusPill = (s: string): string =>
  ({ paid: 'good', posted: 'warn', draft: '', approved: 'good', pending: 'warn', rejected: 'bad', active: 'good', done: 'good', on_hold: 'warn', planned: '',
    submitted: 'warn', reimbursed: 'good', disposed: '', written_off: 'bad', new: 'warn', contacted: '', qualified: 'good', unqualified: 'bad', converted: 'good',
    proposed: 'warn', confirmed: 'good', won: 'good', lost: 'bad',
    in_progress: 'warn', waiting: '', resolved: 'good', closed: '', completed: 'good', ready: 'warn', invoiced: 'good', urgent: 'bad', high: 'bad' } as Record<string, string>)[s] ?? '';

export const statusLabel = (s: string, kind: 'invoice' | 'bill' | 'payroll' | 'other' = 'other') => {
  if (s === 'posted') return kind === 'payroll' ? 'Posted' : 'Unpaid';
  if (s === 'on_hold') return 'On hold';
  if (s === 'in_progress') return 'In progress';
  if (s === 'written_off') return 'Written off';
  return s.charAt(0).toUpperCase() + s.slice(1);
};
