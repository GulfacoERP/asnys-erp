import { createClient } from '@supabase/supabase-js';

const url = import.meta.env.VITE_SUPABASE_URL as string | undefined;
const key = import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined;

export const configured = Boolean(url && key);
/** Read before the client consumes the link: true when someone arrived from an invitation email. */
export const arrivedFromInvite = typeof window !== 'undefined' && /(^|[#&?])type=invite(&|$)/.test(window.location.hash + '&' + window.location.search.slice(1));
// "Remember me": when it was unticked, a session cookie marks the browser session; if the browser was closed
// since, the cookie is gone and the saved login is cleared before the client reads it.
const REMEMBER = 'asnys.remember', LIVE = 'asnys_live';
export const wantsRemember = () => { try { return localStorage.getItem(REMEMBER) !== '0'; } catch { return true; } };
export const setRemember = (on: boolean) => { try { localStorage.setItem(REMEMBER, on ? '1' : '0'); } catch { /* storage unavailable */ } };
export const markSignedIn = () => { if (typeof document !== 'undefined') document.cookie = `${LIVE}=1; path=/; SameSite=Lax`; };
try {
  if (typeof document !== 'undefined' && !wantsRemember() && !document.cookie.split('; ').some(c => c.startsWith(LIVE + '='))) {
    Object.keys(localStorage).filter(k => k.startsWith('sb-') && k.endsWith('-auth-token')).forEach(k => localStorage.removeItem(k));
  }
} catch { /* storage unavailable */ }

/** Tabs share one sign-in lock. If another tab has held it for 5 seconds (a stuck or sleeping tab), take it over
 *  instead of waiting forever, which left the app on "Loading…". */
const lock = async <R,>(name: string, _timeout: number, fn: () => Promise<R>): Promise<R> => {
  const locks = typeof navigator !== 'undefined' ? (navigator as any).locks : null;
  if (!locks?.request) return fn();
  const ac = new AbortController();
  const t = setTimeout(() => ac.abort(), 5000);
  try {
    return await locks.request(name, { mode: 'exclusive', signal: ac.signal }, async () => { clearTimeout(t); return fn(); });
  } catch (e: any) {
    clearTimeout(t);
    if (e?.name === 'AbortError') return locks.request(name, { steal: true }, fn);
    throw e;
  }
};
export const supabase = createClient(url || 'https://missing.supabase.co', key || 'missing', { auth: { lock } });

/** Unwraps a Supabase response, throwing its message so screens can show it. */
export async function q<T = any>(p: PromiseLike<{ data: T; error: { message: string } | null }>): Promise<T> {
  const { data, error } = await p;
  if (error) throw new Error(cleanError(error.message));
  return data;
}

export async function rpc<T = any>(fn: string, args: Record<string, unknown>): Promise<T> {
  return q<T>(supabase.rpc(fn, args) as any);
}

function cleanError(m: string) {
  if (/row-level security/i.test(m)) return 'You do not have permission to do that. Ask an owner or admin to check your role.';
  if (/duplicate key.*sku/i.test(m)) return 'Another product already uses that SKU.';
  if (/duplicate key/i.test(m)) return 'That record already exists.';
  return m;
}

/** One page of rows plus the total count (query must be built with { count: 'exact' } and .range()). */
export async function qPage<T = any>(p: PromiseLike<{ data: T[] | null; count: number | null; error: { message: string } | null }>): Promise<{ rows: T[]; total: number }> {
  const { data, count, error } = await p;
  if (error) throw new Error(cleanError(error.message));
  return { rows: data || [], total: count ?? (data || []).length };
}
