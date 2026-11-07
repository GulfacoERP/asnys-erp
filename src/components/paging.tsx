import { useEffect, useState } from 'react';
import { useLoad } from './ui';

/** Server-side paging for long lists. `fetchPage(from, to)` returns one page of rows and the total count. */
export function usePaged<T>(fetchPage: (from: number, to: number) => Promise<{ rows: T[]; total: number }>, deps: unknown[], pageSize = 50) {
  const [page, setPage] = useState(0);
  const key = JSON.stringify(deps);
  useEffect(() => setPage(0), [key]);
  const res = useLoad(() => fetchPage(page * pageSize, page * pageSize + pageSize - 1), [key, page]);
  const total = res.data?.total ?? 0;
  return { ...res, rows: res.data?.rows || [], total, page, setPage, pageSize, pages: Math.max(1, Math.ceil(total / pageSize)) };
}

export function Pager({ page, pages, total, pageSize, setPage, noun = 'records' }: { page: number; pages: number; total: number; pageSize: number; setPage: (n: number) => void; noun?: string }) {
  if (total <= pageSize) return total ? <div className="body muted" style={{ fontSize: 13 }}>{total.toLocaleString()} {noun}</div> : null;
  const first = page * pageSize + 1, last = Math.min(total, (page + 1) * pageSize);
  return <div className="body actions" style={{ justifyContent: 'space-between', borderTop: '1px solid var(--line)' }}>
    <span className="muted" style={{ fontSize: 13 }}>{first.toLocaleString()}–{last.toLocaleString()} of {total.toLocaleString()} {noun}</span>
    <span className="actions">
      <button className="btn small" type="button" disabled={page === 0} onClick={() => setPage(0)}>First</button>
      <button className="btn small" type="button" disabled={page === 0} onClick={() => setPage(page - 1)}>Previous</button>
      <span className="muted num" style={{ fontSize: 13 }}>Page {page + 1} of {pages}</span>
      <button className="btn small" type="button" disabled={page + 1 >= pages} onClick={() => setPage(page + 1)}>Next</button>
      <button className="btn small" type="button" disabled={page + 1 >= pages} onClick={() => setPage(pages - 1)}>Last</button>
    </span>
  </div>;
}

/** A search box that waits until typing pauses before searching. */
export function SearchBox({ value, onChange, placeholder, width = 260, id = 'search', label = 'Search' }: { value: string; onChange: (v: string) => void; placeholder: string; width?: number; id?: string; label?: string }) {
  const [v, setV] = useState(value);
  useEffect(() => { const t = setTimeout(() => { if (v !== value) onChange(v.trim()); }, 350); return () => clearTimeout(t); }, [v]); // eslint-disable-line react-hooks/exhaustive-deps
  return <div className="field" style={{ width }}><label htmlFor={id}>{label}</label><input id={id} value={v} onChange={e => setV(e.target.value)} placeholder={placeholder} /></div>;
}

/** Fetch every row of a filtered query in pages of 1,000 (for PDF and CSV downloads of long lists). */
export async function fetchAll<T>(fetchRange: (from: number, to: number) => Promise<T[]>, max = 20000): Promise<T[]> {
  const out: T[] = [];
  for (let from = 0; from < max; from += 1000) {
    const rows = await fetchRange(from, from + 999);
    out.push(...rows);
    if (rows.length < 1000) break;
  }
  return out;
}
