import { createContext, ReactNode, useCallback, useContext, useEffect, useState } from 'react';
import type { Session } from '@supabase/supabase-js';
import { arrivedFromInvite, markSignedIn, q, supabase } from './supabase';

export type Role = 'owner' | 'admin' | 'accountant' | 'sales' | 'hr' | 'project_manager' | 'store' | 'staff';
export type Company = {
  id: string; name: string; tin: string | null; address: string | null; city: string | null; phone: string | null;
  email: string | null; bank_details: string | null; momo_details: string | null; help_center_enabled?: boolean; lead_ready_score?: number; site_count_limit?: number;
};
type Ctx = {
  session: Session | null; loading: boolean; recovery: boolean; welcome: boolean;
  companies: { company: Company; role: Role }[];
  company: Company | null; role: Role | null; cid: string;
  selectCompany: (id: string) => void; reload: () => Promise<void>; can: (...roles: Role[]) => boolean;
};

const SessionContext = createContext<Ctx>(null as any);
export const useSession = () => useContext(SessionContext);

const KEY = 'asnys.company';
const OLD_KEYS = ['edwuma.company', 'sika.company'];   // read so people who used an earlier name keep their chosen company
const readKey = () => { try { return localStorage.getItem(KEY) || OLD_KEYS.map(k => localStorage.getItem(k)).find(Boolean) || null; } catch { return null; } };

export function SessionProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session | null>(null);
  const [loading, setLoading] = useState(true);
  const [recovery, setRecovery] = useState(arrivedFromInvite);   // invited people choose a password first
  const [welcome] = useState(arrivedFromInvite);
  const [companies, setCompanies] = useState<{ company: Company; role: Role }[]>([]);
  const [currentId, setCurrentId] = useState<string | null>(readKey());

  const reload = useCallback(async () => {
    const { data: { session: s } } = await supabase.auth.getSession();
    setSession(s);
    if (!s) { setCompanies([]); setLoading(false); return; }
    // Accept any invitations sent to this (confirmed) email before loading the companies they give access to.
    try { await supabase.rpc('claim_my_invites'); } catch { /* older database without v2.5: nothing to claim */ }
    const rows = await q<any[]>(supabase.from('memberships').select('role, company:companies(*)').eq('user_id', s.user.id) as any);
    const list = rows.filter(r => r.company).map(r => ({ company: r.company as Company, role: r.role as Role }))
      .sort((a, b) => a.company.name.localeCompare(b.company.name));
    setCompanies(list);
    setLoading(false);
  }, []);

  useEffect(() => {
    reload().catch(() => setLoading(false));
    const { data } = supabase.auth.onAuthStateChange((event) => {
      if (event === 'PASSWORD_RECOVERY') setRecovery(true);
      if (event === 'SIGNED_IN') markSignedIn();   // links from emails and company sign-in count as this browser session
      if (event === 'SIGNED_IN' || event === 'SIGNED_OUT' || event === 'USER_UPDATED') {
        if (event === 'USER_UPDATED') setRecovery(false);
        reload().catch(() => setLoading(false));
      }
    });
    return () => data.subscription.unsubscribe();
  }, [reload]);

  const current = companies.find(c => c.company.id === currentId) || companies[0] || null;
  const selectCompany = (id: string) => { setCurrentId(id); try { localStorage.setItem(KEY, id); } catch { /* storage unavailable */ } };
  const can = (...roles: Role[]) => !!current && (current.role === 'owner' || current.role === 'admin' || roles.includes(current.role));

  return (
    <SessionContext.Provider value={{
      session, loading, recovery, welcome, companies, company: current?.company || null, role: current?.role || null,
      cid: current?.company.id || '', selectCompany, reload, can,
    }}>{children}</SessionContext.Provider>
  );
}
