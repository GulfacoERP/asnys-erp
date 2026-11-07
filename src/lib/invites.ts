import { rpc, supabase } from './supabase';

export type InviteRow = { email: string; role?: string; employee_id?: string | null };

/** Calls the invite-member edge function. Works out when it has not been deployed yet. */
export async function sendInvites(cid: string, ids: string[]): Promise<{ sent: number; failed: number; notDeployed: boolean; errors: string[] }> {
  if (!ids.length) return { sent: 0, failed: 0, notDeployed: false, errors: [] };
  const { data, error } = await supabase.functions.invoke('invite-member', { body: { company_id: cid, invite_ids: ids, redirect_to: window.location.origin } });
  if (error) {
    const res: Response | undefined = (error as any).context;
    let msg = '';
    if (res && typeof res.json === 'function') { try { msg = (await res.clone().json())?.error || ''; } catch { /* not JSON */ } }
    if (msg) throw new Error(msg);
    return { sent: 0, failed: 0, notDeployed: true, errors: [] };   // 404 or blocked request: function missing
  }
  const errs = ((data?.results || []) as any[]).filter(r => !r.ok).map(r => `${r.email}: ${r.error}`);
  return { sent: data?.sent || 0, failed: data?.failed || 0, notDeployed: false, errors: errs };
}

/** Records the invitations, emails them, and says plainly what happened. */
export async function inviteAndSend(cid: string, list: InviteRow[]): Promise<string> {
  const rows = await rpc<{ id: string | null; email: string; result: string }[]>('create_invites', { cid, p_list: list });
  const ids = rows.filter(r => r.result === 'invited' && r.id).map(r => r.id!);
  const members = rows.filter(r => r.result === 'already a member').map(r => r.email);
  const bad = rows.filter(r => r.result === 'invalid email').map(r => r.email || '(blank)');
  const parts: string[] = [];
  if (ids.length) {
    const s = await sendInvites(cid, ids);
    if (s.notDeployed) parts.push(`${ids.length} invitation${ids.length > 1 ? 's' : ''} recorded, but the invite email service is not set up yet (see SETUP, "Staff invitations"). Until then, ask them to sign up at ${window.location.origin} with that email; they are added automatically once they confirm it.`);
    else {
      if (s.sent) parts.push(`${s.sent} invitation${s.sent > 1 ? 's' : ''} emailed.`);
      if (s.failed) parts.push(`${s.failed} could not be sent (${s.errors.join('; ')}).`);
    }
  }
  if (members.length) parts.push(`Already on the team: ${members.join(', ')}.`);
  if (bad.length) parts.push(`Not valid email addresses: ${bad.join(', ')}.`);
  return parts.join(' ') || 'Nothing to send.';
}

export async function sendPasswordReset(email: string) {
  const { error } = await supabase.auth.resetPasswordForEmail(email, { redirectTo: window.location.origin });
  if (error) throw new Error(error.message);
}

export const splitEmails = (s: string) => s.split(/[\s,;]+/).map(x => x.trim()).filter(Boolean);
