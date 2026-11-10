import { rpc, supabase } from '../lib/supabase';
import { useSession } from '../lib/session';
import type { InviteRow } from '../lib/invites';
import { FormModal, useToast } from './ui';

export type Slip = { email: string; ok: boolean; password?: string; note?: string; error?: string };

async function callLogins(body: Record<string, unknown>): Promise<Slip[]> {
  const { data, error } = await supabase.functions.invoke('invite-member', { body });
  if (error) {
    const res: Response | undefined = (error as any).context;
    let msg = '';
    if (res && typeof res.json === 'function') { try { msg = (await res.clone().json())?.error || ''; } catch { /* not JSON */ } }
    throw new Error(msg || 'The invite-member function is not set up, or is an older version. Paste the new code into Supabase → Edge Functions → invite-member and deploy.');
  }
  if (!Array.isArray(data?.results)) throw new Error('The invite-member function in Supabase is an older version. Paste the new code from this update and deploy it.');
  return data.results as Slip[];
}

/** Records the people as invited, then creates their logins with temporary passwords. */
export async function createLogins(cid: string, list: InviteRow[]): Promise<{ slips: Slip[]; note: string }> {
  const rows = await rpc<{ id: string | null; email: string; result: string }[]>('create_invites', { cid, p_list: list });
  const ids = rows.filter(r => r.result === 'invited' && r.id).map(r => r.id!);
  const members = rows.filter(r => r.result === 'already a member').map(r => r.email);
  const bad = rows.filter(r => r.result === 'invalid email').map(r => r.email || '(blank)');
  const slips = ids.length ? await callLogins({ action: 'create_login', company_id: cid, invite_ids: ids }) : [];
  const parts: string[] = [];
  if (members.length) parts.push(`Already on the team (use Set new password instead): ${members.join(', ')}.`);
  if (bad.length) parts.push(`Not valid email addresses: ${bad.join(', ')}.`);
  return { slips, note: parts.join(' ') };
}
/** Login for an invitation that is already recorded (e.g. an email invite that never arrived). */
export const loginForInvites = (cid: string, ids: string[]) => callLogins({ action: 'create_login', company_id: cid, invite_ids: ids });
export const setNewPassword = (cid: string, userId: string) => callLogins({ action: 'set_password', company_id: cid, user_id: userId });

/** Shows the temporary passwords once, to copy or print and hand over privately. */
export function PasswordSlips({ slips, note, onClose }: { slips: Slip[]; note?: string; onClose: () => void }) {
  const { company } = useSession();
  const toast = useToast();
  const site = window.location.origin;
  const good = slips.filter(s => s.ok && s.password);
  const text = good.map(s => `${company?.name || ''} — Asnys ERP\nGo to ${site}\nEmail: ${s.email}\nTemporary password: ${s.password}\nYou will be asked to choose your own password.`).join('\n\n');
  const print = () => {
    const w = window.open('', '_blank', 'width=720,height=900');
    if (!w) { toast('Allow pop-ups to print the slips.', true); return; }
    const esc = (t: string) => t.replace(/[&<>]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' } as any)[c]);
    w.document.write(`<html><head><title>Login slips</title><style>body{font-family:Arial,sans-serif;margin:24px}div{border:1px dashed #888;padding:14px 16px;margin:0 0 14px;page-break-inside:avoid}b{font-size:18px;letter-spacing:.5px}</style></head><body>${good.map(s =>
      `<div>${esc(company?.name || '')} — Asnys ERP<br>Open <u>${esc(site)}</u><br>Email: <b style="font-size:15px">${esc(s.email)}</b><br>Temporary password: <b>${esc(s.password!)}</b><br><small>Sign in and choose your own password. Do not share this slip.</small></div>`).join('')}</body></html>`);
    w.document.close(); w.focus(); w.print();
  };
  return <FormModal title="Logins created" submit="Done" onClose={onClose} onSave={onClose}>
    {good.length > 0 && <p style={{ margin: 0 }}>Give each person their password privately, by WhatsApp, SMS or a printed slip. It is shown <b>only now</b>. At their first sign-in they choose their own password.</p>}
    <div className="scroll"><table>
      <thead><tr><th>Email</th><th>Temporary password</th></tr></thead>
      <tbody>{slips.map(s => <tr key={s.email}>
        <td>{s.email}</td>
        <td>{s.password ? <code style={{ fontSize: 15, userSelect: 'all' }}>{s.password}</code> : s.ok ? <span className="muted">{s.note || 'Done'}</span> : <span className="pill bad">{s.error || 'Failed'}</span>}</td></tr>)}</tbody></table></div>
    {note && <p className="muted" style={{ margin: 0 }}>{note}</p>}
    {good.length > 0 && <div className="actions">
      <button className="btn" type="button" onClick={() => navigator.clipboard.writeText(text).then(() => toast('Copied. Paste each part into a private message.'), () => toast('Could not copy; select the passwords by hand.', true))}>Copy all</button>
      <button className="btn" type="button" onClick={print}>Print slips</button>
    </div>}
    <p className="muted" style={{ margin: 0, fontSize: 13 }}>They sign in at {site} with their email and this password. If someone forgets theirs, press Set new password next to them in Settings → Team.</p>
  </FormModal>;
}
