import { ReactNode, useState } from 'react';
import { markSignedIn, setRemember, supabase, wantsRemember } from '../lib/supabase';
import { BRAND, BRAND_MARK, isWhiteLabel } from '../lib/brand';
import { useSession } from '../lib/session';
import { Logo, LogoMark } from '../components/Logo';

// Company sign-in (Microsoft 365 / Google Workspace). Turn providers on in Supabase → Authentication → Providers,
// then list them in VITE_SSO_PROVIDERS, e.g. "azure,google".
const SSO = String(import.meta.env.VITE_SSO_PROVIDERS || '').split(',').map(s => s.trim()).filter(s => ['azure', 'google'].includes(s)) as ('azure' | 'google')[];
const SSO_LABEL = { azure: 'Log in with Microsoft 365', google: 'Log in with Google' };
const EMAIL_OK = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;

/** Dark, layered sign-in screen: the form on a frosted card at left, two feature panels at right. */
function LoginShell({ children }: { children: ReactNode }) {
  return <div className="login">
    <div className="login-bg" aria-hidden="true"><i className="b1" /><i className="b2" /><i className="b3" /><i className="b4" /><i className="b5" /></div>
    <div className="login-grid">
      <div className="login-card">
        <div className="login-logo">{isWhiteLabel ? <><LogoMark size={52} /><span className="login-word"><b>{BRAND}</b></span></> : <Logo size={50} dark />}</div>
        {children}
      </div>
      <aside className="login-side" aria-label="About this system">
        <section className="promo promo-dark">
          <div className="promo-text">
            <p className="promo-kicker">Projects, money and people in one place</p>
            <h2>From tender to final payment</h2>
            <p>Register every tender, approve budgets before spending, certify milestones and chase each invoice until it is paid.</p>
            <span className="promo-chip">Built for Ghanaian businesses</span>
          </div>
          <DashboardArt />
        </section>
        <section className="promo promo-light">
          <div className="promo-text">
            <h2>Your whole team, on any phone</h2>
            <p>Staff accept an email invitation, choose a password and log time, expenses, leave and site stock from their phones.</p>
          </div>
          <div className="promo-badge" aria-hidden="true">{isWhiteLabel ? <span>{BRAND_MARK}</span> : <LogoMark size={64} radius={16} />}<svg viewBox="0 0 120 120"><circle cx="60" cy="60" r="50" /></svg></div>
        </section>
      </aside>
    </div>
  </div>;
}

/** Floating-label field like the label sitting inside the box, rising when you type. */
function FloatField({ id, label, type = 'text', value, onChange, onBlur, error, autoComplete, children }: {
  id: string; label: string; type?: string; value: string; onChange: (v: string) => void; onBlur?: () => void; error?: string; autoComplete?: string; children?: ReactNode;
}) {
  return <div className={'lf' + (error ? ' bad' : '')}>
    <input id={id} type={type} value={value} placeholder=" " autoComplete={autoComplete} aria-invalid={!!error} aria-describedby={error ? id + '-err' : undefined}
      onChange={e => onChange(e.target.value)} onBlur={onBlur} />
    <label htmlFor={id}>{label}</label>
    {children}
    {error && <div className="lf-err" id={id + '-err'}><span aria-hidden="true">!</span>{error}</div>}
  </div>;
}

function PasswordField({ id, label, value, onChange, autoComplete }: { id: string; label: string; value: string; onChange: (v: string) => void; autoComplete: string }) {
  const [show, setShow] = useState(false);
  return <FloatField id={id} label={label} type={show ? 'text' : 'password'} value={value} onChange={onChange} autoComplete={autoComplete}>
    <button type="button" className="lf-eye" onClick={() => setShow(s => !s)} aria-label={show ? 'Hide password' : 'Show password'}>{show ? 'Hide' : 'Show'}</button>
  </FloatField>;
}

export function AuthPage() {
  const [mode, setMode] = useState<'in' | 'up' | 'reset'>('in');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [remember, setRem] = useState(wantsRemember());
  const [touched, setTouched] = useState(false);
  const [msg, setMsg] = useState('');
  const [err, setErr] = useState('');
  const [busy, setBusy] = useState(false);
  const emailBad = touched && !EMAIL_OK.test(email.trim()) ? 'Valid email is required: name@company.com' : '';
  const ready = EMAIL_OK.test(email.trim()) && (mode === 'reset' || password.length > 0);

  const go = (m: typeof mode) => { setMode(m); setErr(''); setMsg(''); };
  const submit = async () => {
    setTouched(true);
    if (!ready) return;
    setBusy(true); setErr(''); setMsg('');
    try {
      if (mode === 'in') {
        setRemember(remember);
        const { error } = await supabase.auth.signInWithPassword({ email: email.trim(), password });
        if (error) throw new Error(/invalid login/i.test(error.message) ? 'That email and password do not match. Check them, or use "Forgot your password?".' : error.message);
        markSignedIn();
      } else if (mode === 'up') {
        if (password.length < 8) throw new Error('Use a password of at least 8 characters.');
        const { data, error } = await supabase.auth.signUp({ email: email.trim(), password, options: { emailRedirectTo: window.location.origin } });
        if (error) throw error;
        if (!data.session) setMsg('Check your email and click the confirmation link, then log in.');
      } else {
        const { error } = await supabase.auth.resetPasswordForEmail(email.trim(), { redirectTo: window.location.origin });
        if (error) throw error;
        setMsg('If that email has an account, a reset link is on its way. Check your inbox and spam folder.');
      }
    } catch (e: any) { setErr(e.message); }
    setBusy(false);
  };

  return <LoginShell>
    <form className="login-form" noValidate onSubmit={e => { e.preventDefault(); submit(); }}>
      <h1>{mode === 'in' ? 'Log In' : mode === 'up' ? 'Create your account' : 'Reset your password'}</h1>
      {mode === 'reset' && <p className="login-sub">Enter your work email and we'll send you a link to choose a new password.</p>}
      {mode === 'up' && <p className="login-sub">Set up your company on {BRAND}. Joining a company that already uses it? Ask HR or your administrator for an invitation instead.</p>}
      <FloatField id="email" label="Email address" type="email" value={email} onChange={v => { setEmail(v); if (touched && EMAIL_OK.test(v.trim())) setErr(''); }}
        onBlur={() => email && setTouched(true)} error={emailBad} autoComplete="username" />
      {mode !== 'reset' && <PasswordField id="password" label={mode === 'up' ? 'Password (at least 8 characters)' : 'Password'} value={password} onChange={setPassword}
        autoComplete={mode === 'up' ? 'new-password' : 'current-password'} />}
      {mode === 'in' && <label className="login-check"><input type="checkbox" checked={remember} onChange={e => setRem(e.target.checked)} /> Remember me</label>}
      {err && <div className="login-alert" role="alert">{err}</div>}
      {msg && <div className="login-note" role="status">{msg}</div>}
      <button className="login-btn" type="submit" disabled={busy || !ready} onClick={() => setTouched(true)}>
        <LockIcon />{busy ? 'Please wait…' : mode === 'in' ? 'Log In' : mode === 'up' ? 'Create account' : 'Send reset link'}</button>
      {mode === 'in' && SSO.map(p => <button key={p} type="button" className="login-btn alt" disabled={busy} onClick={async () => {
        setErr(''); setBusy(true); setRemember(remember); markSignedIn();
        const { error } = await supabase.auth.signInWithOAuth({ provider: p, options: { redirectTo: window.location.origin, scopes: p === 'azure' ? 'email' : undefined } });
        if (error) { setErr(error.message); setBusy(false); }
      }}>{p === 'azure' ? <MsIcon /> : <GIcon />}{SSO_LABEL[p]}</button>)}
      <div className="login-links">
        {mode === 'in' ? <>
          <button type="button" className="login-link" onClick={() => go('reset')}>Forgot your password?</button>
          <button type="button" className="login-link quiet" onClick={() => go('up')}>New company? Create an account</button>
        </> : <button type="button" className="login-link" onClick={() => go('in')}>Back to log in</button>}
      </div>
      {mode === 'in' && <p className="login-fine">Your company's records are visible only to its own members. On a shared computer, untick Remember me so you are logged out when the browser closes.</p>}
    </form>
  </LoginShell>;
}

export function NewPasswordPage({ welcome = false, temporary = false }: { welcome?: boolean; temporary?: boolean }) {
  const { session } = useSession();
  const [password, setPassword] = useState('');
  const [err, setErr] = useState('');
  const [busy, setBusy] = useState(false);
  const invitedTo = (session?.user.user_metadata as any)?.invited_to as string | undefined;
  return <LoginShell>
    <form className="login-form" noValidate onSubmit={async e => {
      e.preventDefault(); setBusy(true); setErr('');
      if (password.length < 8) { setErr('Use at least 8 characters.'); setBusy(false); return; }
      const { error } = await supabase.auth.updateUser(temporary ? { password, data: { must_change_password: false } } : { password });
      if (error) setErr(error.message); else markSignedIn();
      setBusy(false);
    }}>
      <h1>{temporary ? 'Choose your own password' : welcome ? `Welcome to ${invitedTo || BRAND}` : 'Choose a new password'}</h1>
      <p className="login-sub">{temporary ? <>You signed in with a temporary password. Choose your own now; from then on you log in with <b>{session?.user.email}</b> and that password.</> : welcome
        ? <>{invitedTo ? `You've been invited to use ${BRAND}. ` : ''}Choose a password. From now on you log in with <b>{session?.user.email || 'your email'}</b> and this password. If you forget it, use "Forgot your password?" on the log-in page.</>
        : <>Choose a new password for <b>{session?.user.email || 'your account'}</b>.</>}</p>
      <PasswordField id="newpw" label={welcome ? 'Password (at least 8 characters)' : 'New password'} value={password} onChange={setPassword} autoComplete="new-password" />
      {err && <div className="login-alert" role="alert">{err}</div>}
      <button className="login-btn" type="submit" disabled={busy || password.length < 8}><LockIcon />{busy ? 'Saving…' : 'Save password'}</button>
      {temporary && <button className="login-link" type="button" onClick={() => supabase.auth.signOut()}>Sign out</button>}
    </form>
  </LoginShell>;
}

const LockIcon = () => <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" aria-hidden="true"><rect x="4" y="10.5" width="16" height="10" rx="2" /><path d="M8 10.5V7.5a4 4 0 0 1 8 0v3" /></svg>;
const MsIcon = () => <svg width="16" height="16" viewBox="0 0 20 20" aria-hidden="true"><rect width="9" height="9" fill="#f25022" /><rect x="11" width="9" height="9" fill="#7fba00" /><rect y="11" width="9" height="9" fill="#00a4ef" /><rect x="11" y="11" width="9" height="9" fill="#ffb900" /></svg>;
const GIcon = () => <svg width="16" height="16" viewBox="0 0 20 20" aria-hidden="true"><circle cx="10" cy="10" r="8" fill="none" stroke="currentColor" strokeWidth="2.2" /><path d="M10 10h7" stroke="currentColor" strokeWidth="2.2" /></svg>;

/** Abstract dashboard: a chart card, a progress ring and stacked tiles on soft shapes. */
function DashboardArt() {
  return <svg className="promo-art" viewBox="0 0 360 300" aria-hidden="true">
    <defs>
      <linearGradient id="la1" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stopColor="#f0a39a" /><stop offset="1" stopColor="#d9625a" /></linearGradient>
      <linearGradient id="la2" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stopColor="#57c6a8" /><stop offset="1" stopColor="#1f7f69" /></linearGradient>
      <linearGradient id="la3" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stopColor="#b5793f" /><stop offset="1" stopColor="#7a4a22" /></linearGradient>
    </defs>
    <path d="M250 18c62 10 104 70 92 134-10 58-58 120-120 128-48 6-58-38-40-80 22-50-8-80 4-130 8-34 30-58 64-52z" fill="#3a2f55" opacity=".85" />
    <ellipse cx="300" cy="248" rx="46" ry="70" transform="rotate(-24 300 248)" fill="url(#la3)" opacity=".95" />
    <path d="M196 300c-6-40 22-76 64-76s74 34 70 76z" fill="url(#la1)" opacity=".9" />
    <g transform="translate(96 54)">
      <rect width="196" height="132" rx="12" fill="#f7f4ef" />
      <rect x="14" y="14" width="70" height="8" rx="4" fill="#c9c2b8" />
      <rect x="14" y="28" width="44" height="6" rx="3" fill="#e1dbd2" />
      {[34, 56, 44, 72, 60, 86].map((h, i) => <rect key={i} x={16 + i * 22} y={118 - h} width="14" height={h} rx="3" fill={i === 5 ? 'url(#la2)' : '#cfe7df'} />)}
      <polyline points="23,88 45,74 67,80 89,58 111,64 133,40" fill="none" stroke="#d9625a" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round" />
      <g transform="translate(166 40)"><circle r="18" fill="none" stroke="#e7e1d8" strokeWidth="6" /><circle r="18" fill="none" stroke="#1f7f69" strokeWidth="6" strokeDasharray="82 200" transform="rotate(-90)" strokeLinecap="round" /></g>
    </g>
    <g transform="translate(40 150)">
      <rect width="120" height="64" rx="10" fill="#ffffff" opacity=".96" />
      <circle cx="22" cy="22" r="9" fill="#57c6a8" />
      <rect x="38" y="16" width="62" height="6" rx="3" fill="#c9c2b8" />
      <rect x="38" y="27" width="40" height="5" rx="2.5" fill="#e1dbd2" />
      <rect x="14" y="44" width="92" height="8" rx="4" fill="#eef3f1" /><rect x="14" y="44" width="62" height="8" rx="4" fill="url(#la2)" />
    </g>
    <circle cx="70" cy="70" r="26" fill="none" stroke="#9fd3ea" strokeWidth="1.2" strokeDasharray="2 5" opacity=".6" />
  </svg>;
}
