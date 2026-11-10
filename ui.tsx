import { createContext, ReactNode, useCallback, useContext, useEffect, useRef, useState } from 'react';
import { statusLabel, statusPill } from '../lib/format';

// ---------------------------------------------------------------- Toasts
type ToastFn = (msg: string, bad?: boolean) => void;
const ToastCtx = createContext<ToastFn>(() => {});
export const useToast = () => useContext(ToastCtx);
export function ToastProvider({ children }: { children: ReactNode }) {
  const [t, setT] = useState<{ msg: string; bad?: boolean } | null>(null);
  const timer = useRef<number>();
  const show = useCallback<ToastFn>((msg, bad) => {
    setT({ msg, bad });
    window.clearTimeout(timer.current);
    timer.current = window.setTimeout(() => setT(null), bad ? 6000 : 2800);
  }, []);
  return <ToastCtx.Provider value={show}>{children}{t && <div className={'toast' + (t.bad ? ' bad' : '')} role="status">{t.msg}</div>}</ToastCtx.Provider>;
}

// ---------------------------------------------------------------- Data loading
export function useLoad<T>(fn: () => Promise<T>, deps: unknown[]) {
  const [data, setData] = useState<T | null>(null);
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(true);
  const run = useCallback(async () => {
    setLoading(true);
    try { setData(await fn()); setError(''); } catch (e: any) { setError(e.message || String(e)); }
    setLoading(false);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, deps);
  useEffect(() => { run(); }, [run]);
  return { data, error, loading, reload: run, setData };
}

/** Wraps an async action with a busy flag and error toast. */
export function useAction() {
  const toast = useToast();
  const [busy, setBusy] = useState(false);
  const run = async (fn: () => Promise<unknown>, success?: string) => {
    setBusy(true);
    try { await fn(); if (success) toast(success); return true; }
    catch (e: any) { toast(e.message || String(e), true); return false; }
    finally { setBusy(false); }
  };
  return { busy, run };
}

// ---------------------------------------------------------------- Layout pieces
export function PageHead({ title, sub, children }: { title: string; sub?: ReactNode; children?: ReactNode }) {
  return <div className="head"><div><h1>{title}</h1>{sub && <p>{sub}</p>}</div>{children && <div className="actions">{children}</div>}</div>;
}

export function Panel({ title, actions, children, pad }: { title?: ReactNode; actions?: ReactNode; children: ReactNode; pad?: boolean }) {
  return <section className="panel">
    {(title || actions) && <header>{typeof title === 'string' ? <h2>{title}</h2> : title}{actions && <div className="actions">{actions}</div>}</header>}
    {pad ? <div className="body">{children}</div> : children}
  </section>;
}

export function Loading({ error, loading }: { error?: string; loading?: boolean }) {
  if (error) return <div className="panel body error" role="alert">{error}</div>;
  if (loading) return <div className="empty">Loading…</div>;
  return null;
}

export function Empty({ children }: { children: ReactNode }) { return <div className="empty">{children}</div>; }

export function Status({ s, kind }: { s: string; kind?: 'invoice' | 'bill' | 'payroll' | 'other' }) {
  return <span className={'pill ' + statusPill(s)}>{statusLabel(s, kind)}</span>;
}

// ---------------------------------------------------------------- Form fields
type FieldProps = { label: string; id: string; value: any; onChange: (v: any) => void; type?: string; required?: boolean; placeholder?: string; step?: string; min?: string; max?: string; inputMode?: 'decimal' | 'numeric' | 'text' | 'tel' | 'email' };
export function Field({ label, id, value, onChange, type = 'text', ...rest }: FieldProps) {
  return <div className="field"><label htmlFor={id}>{label}</label>
    {type === 'textarea'
      ? <textarea id={id} value={value ?? ''} onChange={e => onChange(e.target.value)} placeholder={rest.placeholder} />
      : <input id={id} type={type} value={value ?? ''} onChange={e => onChange(type === 'number' ? e.target.value : e.target.value)} {...rest} />}
  </div>;
}

export function Select({ label, id, value, onChange, options, required }: { label: string; id: string; value: any; onChange: (v: string) => void; options: [string, string][]; required?: boolean }) {
  return <div className="field"><label htmlFor={id}>{label}</label>
    <select id={id} value={value ?? ''} onChange={e => onChange(e.target.value)} required={required}>
      {options.map(([v, l]) => <option key={v} value={v}>{l}</option>)}
    </select></div>;
}

// ---------------------------------------------------------------- Modal
export function Modal({ title, onClose, children, footer, wide }: { title: string; onClose: () => void; children: ReactNode; footer?: ReactNode; wide?: boolean }) {
  useEffect(() => {
    const k = (e: KeyboardEvent) => { if (e.key === 'Escape') onClose(); };
    window.addEventListener('keydown', k);
    return () => window.removeEventListener('keydown', k);
  }, [onClose]);
  return <div className="modal-bg" onMouseDown={e => { if (e.target === e.currentTarget) onClose(); }}>
    <div className={'modal' + (wide ? ' wide' : '')} role="dialog" aria-modal="true" aria-label={title}>
      <header><h2>{title}</h2><button className="btn ghost small" onClick={onClose} type="button">Close</button></header>
      {children}
      {footer && <footer>{footer}</footer>}
    </div>
  </div>;
}

/** A modal form with a submit button; returns to caller via onSave. */
export function FormModal({ title, onClose, onSave, busy, submit = 'Save', children, danger }: {
  title: string; onClose: () => void; onSave: () => void; busy?: boolean; submit?: string; children: ReactNode; danger?: ReactNode;
}) {
  return <Modal title={title} onClose={onClose}>
    <form onSubmit={e => { e.preventDefault(); onSave(); }}>
      <div className="body">{children}</div>
      <footer>{danger}<span style={{ flex: 1 }} /><button className="btn" type="button" onClick={onClose}>Cancel</button>
        <button className="btn primary" type="submit" disabled={busy}>{busy ? 'Saving…' : submit}</button></footer>
    </form>
  </Modal>;
}

/** Two-step confirmation (the browser confirm dialog is avoided so it works everywhere). */
export function ConfirmButton({ label, confirm, onConfirm, className = 'btn', disabled }: { label: string; confirm: string; onConfirm: () => void; className?: string; disabled?: boolean }) {
  const [asking, setAsking] = useState(false);
  if (!asking) return <button type="button" className={className} disabled={disabled} onClick={() => setAsking(true)}>{label}</button>;
  return <span className="actions"><span className="muted">{confirm}</span>
    <button type="button" className="btn primary small" onClick={() => { setAsking(false); onConfirm(); }}>Yes</button>
    <button type="button" className="btn small" onClick={() => setAsking(false)}>No</button></span>;
}

/** PDF + CSV download buttons. */
export function Downloads({ pdf, csv }: { pdf?: () => void; csv?: () => void }) {
  return <>{pdf && <button className="btn" type="button" onClick={pdf}>Download PDF</button>}
    {csv && <button className="btn" type="button" onClick={csv}>Download CSV</button>}</>;
}
