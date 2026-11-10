import { useId } from 'react';
import { BRAND_MARK, isWhiteLabel } from '../lib/brand';

/** The Asnys mark: an A built from two blocks with a gold keystone. A copy branded for one company shows its letters instead. */
export function LogoMark({ size = 40, radius = 16 }: { size?: number; radius?: number }) {
  const id = 'lg' + useId().replace(/[^a-z0-9]/gi, '');
  if (isWhiteLabel) return <span className="mark" style={{ width: size, height: size, borderRadius: size * radius / 64, fontSize: size * (BRAND_MARK.length > 1 ? .36 : .45) }}>{BRAND_MARK}</span>;
  return <svg width={size} height={size} viewBox="0 0 64 64" role="img" aria-label="Asnys" style={{ flex: 'none', display: 'block' }}>
    <defs><linearGradient id={id} x1="0" y1="0" x2="1" y2="1"><stop offset="0" stopColor="#1f9468" /><stop offset="1" stopColor="#0a5444" /></linearGradient></defs>
    <rect width="64" height="64" rx={radius} fill={`url(#${id})`} />
    <path d="M12.5 50 L27.2 13.5 h7.6 L20.4 50z" fill="#fff" />
    <path d="M37.2 24.2 L51.5 50 h-8 L33.4 31.2z" fill="#fff" fillOpacity=".9" />
    <path d="M30.6 31.6 l5.4 5.4 -5.4 5.4 -5.4 -5.4z" fill="#f3b23a" />
  </svg>;
}

/** Mark plus the wordmark, for the log-in card and set-up screens. */
export function Logo({ size = 44, dark = false }: { size?: number; dark?: boolean }) {
  return <span className="logo" style={{ display: 'inline-flex', alignItems: 'center', gap: size * .28 }}>
    <LogoMark size={size} />
    {!isWhiteLabel && <span style={{ display: 'inline-flex', alignItems: 'baseline', gap: size * .14, lineHeight: 1 }}>
      <b style={{ font: `700 ${size * .74}px var(--display)`, letterSpacing: '-.02em', color: dark ? '#eef5f4' : '#123a2f' }}>asnys</b>
      <small style={{ font: `600 ${size * .22}px var(--body)`, letterSpacing: '.12em', color: dark ? '#9fd8cb' : 'var(--muted)' }}>ERP</small>
    </span>}
  </span>;
}
