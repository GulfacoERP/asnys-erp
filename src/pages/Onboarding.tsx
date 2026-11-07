import { useState } from 'react';
import { rpc, supabase } from '../lib/supabase';
import { useSession } from '../lib/session';
import { BRAND, BRAND_MARK, isWhiteLabel } from '../lib/brand';
import { Field } from '../components/ui';
import { Logo } from '../components/Logo';

export function Onboarding() {
  const { reload, selectCompany, session } = useSession();
  const [f, setF] = useState({ name: '', tin: '', city: '', phone: '' });
  const [err, setErr] = useState('');
  const [busy, setBusy] = useState(false);
  const set = (k: keyof typeof f) => (v: string) => setF({ ...f, [k]: v });

  return <div className="center">
    <form className="card" onSubmit={async e => {
      e.preventDefault(); setBusy(true); setErr('');
      try {
        const id = await rpc<string>('create_company', { p_name: f.name, p_tin: f.tin || null, p_city: f.city || null, p_phone: f.phone || null, p_email: null });
        selectCompany(id);
        await reload();
      } catch (e: any) { setErr(e.message); setBusy(false); }
    }}>
      <div className="brand">{isWhiteLabel ? <><div className="mark">{BRAND_MARK}</div><b>{BRAND}</b></> : <Logo size={38} />}</div>
      <div><h1 style={{ fontSize: 22 }}>Set up your company</h1>
        <p className="muted" style={{ margin: '4px 0 0' }}>We'll create a Ghana chart of accounts with VAT, NHIL, GETFund, PAYE and SSNIT accounts ready to use.</p></div>
      <Field label="Company name" id="cname" value={f.name} onChange={set('name')} required />
      <Field label="TIN (optional)" id="ctin" value={f.tin} onChange={set('tin')} placeholder="C00XXXXXXXX" />
      <div className="grid-form">
        <Field label="Town or city" id="ccity" value={f.city} onChange={set('city')} />
        <Field label="Phone" id="cphone" value={f.phone} onChange={set('phone')} />
      </div>
      {err && <div className="error" role="alert">{err}</div>}
      <button className="btn primary" type="submit" disabled={busy}>{busy ? 'Setting up…' : 'Create company'}</button>
      <div className="note">Joining an existing company instead? Ask its owner to add <b>{session?.user.email}</b> under Settings & team, then sign in again.</div>
      <button className="btn ghost small" type="button" onClick={() => supabase.auth.signOut()}>Sign out</button>
    </form>
  </div>;
}
