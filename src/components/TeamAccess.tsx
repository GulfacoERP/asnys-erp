import { useState } from 'react';
import { q, rpc, supabase } from '../lib/supabase';
import { useSession } from '../lib/session';
import { inviteAndSend, sendInvites, sendPasswordReset, splitEmails } from '../lib/invites';
import { ConfirmButton, Field, Loading, Panel, Select, useAction, useLoad, useToast } from './ui';

export const INVITE_STATUS: Record<string, [string, string]> = {
  pending: ['Not sent yet', 'warn'], sent: ['Invited', ''], failed: ['Email failed', 'bad'], revoked: ['Revoked', ''], accepted: ['Accepted', 'good'],
};
const ago = (d?: string | null) => {
  if (!d) return 'Never';
  const days = Math.floor((Date.now() - new Date(d).getTime()) / 86400000);
  return days <= 0 ? 'Today' : days === 1 ? 'Yesterday' : days < 60 ? `${days} days ago` : d.slice(0, 10);
};

export function TeamAccess({ roles }: { roles: [string, string][] }) {
  const { cid, session, can } = useSession();
  const act = useAction();
  const toast = useToast();
  const admin = can();                                 // owners and admins manage roles; HR invites staff
  const roleOpts = admin ? roles : roles.filter(([v]) => v === 'staff');
  const [form, setForm] = useState({ emails: '', role: admin ? 'staff' : 'staff' });
  const { data, error, loading, reload } = useLoad(() => rpc<{ members: any[]; invites: any[] }>('team_access', { cid }), [cid]);
  const open = (data?.invites || []).filter(i => i.status !== 'revoked');
  const revoked = (data?.invites || []).filter(i => i.status === 'revoked');

  const say = (m: string) => toast(m, /could not|not set up|Not valid/.test(m));

  return <Panel title="Team and sign-in access">
    <form className="body" style={{ display: 'grid', gap: 12 }} onSubmit={e => { e.preventDefault(); act.run(async () => {
      const list = splitEmails(form.emails).map(email => ({ email, role: form.role }));
      if (!list.length) throw new Error('Type at least one email address.');
      say(await inviteAndSend(cid, list)); setForm({ ...form, emails: '' }); reload();
    }); }}>
      <div className="grid-form">
        <Field label="Invite by work email (several? one per line or separated by commas)" id="inv-emails" type="textarea" value={form.emails} onChange={v => setForm({ ...form, emails: v })} placeholder="kwame@yourcompany.com.gh" required />
        <Select label="Role" id="inv-role" value={form.role} onChange={v => setForm({ ...form, role: v })} options={roleOpts} />
      </div>
      <div className="actions"><button className="btn primary" type="submit" disabled={act.busy}>Send invitation</button>
        <span className="muted">They get an email with a link to set a password, then sign in with their email. {admin ? '' : 'HR can invite staff; an admin can raise their role later.'} To invite staff from their employee records, use HR → Employees.</span></div>
    </form>
    <Loading error={error} loading={loading && !data} />
    {data && <>
      <div className="scroll" style={{ borderTop: '1px solid var(--line)' }}><table>
        <thead><tr><th>Email</th><th>Employee</th><th>Role</th><th>Last sign-in</th><th></th></tr></thead>
        <tbody>{data.members.map(m => { const me = m.user_id === session?.user.id; return <tr key={m.user_id}>
          <td>{m.email}{me && <span className="muted"> (you)</span>}</td>
          <td>{m.employee || <span className="muted">Not linked</span>}</td>
          <td>{!admin || m.role === 'owner' || me ? <span style={{ textTransform: 'capitalize' }}>{m.role.replace('_', ' ')}</span>
            : <select aria-label={`Role for ${m.email}`} value={m.role} style={{ width: 'auto' }} onChange={e => act.run(async () => { await q(supabase.from('memberships').update({ role: e.target.value }).eq('company_id', cid).eq('user_id', m.user_id) as any); reload(); }, 'Role updated')}>
              {roles.map(([v]) => <option key={v} value={v}>{v.replace('_', ' ')}</option>)}</select>}</td>
          <td className="muted">{ago(m.last_sign_in_at)}</td>
          <td className="r" style={{ whiteSpace: 'nowrap' }}>
            {!me && m.email && <ConfirmButton className="btn small ghost" label="Send password reset" confirm={`Email ${m.email} a link to choose a new password?`} onConfirm={() => act.run(() => sendPasswordReset(m.email), `Password reset link sent to ${m.email}`)} />}
            {admin && m.role !== 'owner' && !me && <ConfirmButton className="btn small danger" label="Remove" confirm="Remove their access to this company?" onConfirm={() => act.run(async () => { await q(supabase.from('memberships').delete().eq('company_id', cid).eq('user_id', m.user_id) as any); reload(); }, 'Removed')} />}
          </td></tr>; })}</tbody></table></div>
      {open.length > 0 && <>
        <div className="body label" style={{ borderTop: '1px solid var(--line)', marginBottom: 0 }}>Invitations waiting to be accepted</div>
        <div className="scroll"><table>
          <thead><tr><th>Email</th><th>Employee</th><th>Role</th><th>Status</th><th>Last emailed</th><th></th></tr></thead>
          <tbody>{open.map(i => <tr key={i.id}>
            <td>{i.email}<div className="muted" style={{ fontSize: 12 }}>by {i.invited_by || 'someone'} · {ago(i.invited_at)}</div></td>
            <td>{i.employee || ''}</td>
            <td style={{ textTransform: 'capitalize' }}>{i.role.replace('_', ' ')}</td>
            <td><span className={'pill ' + INVITE_STATUS[i.status][1]}>{INVITE_STATUS[i.status][0]}</span>{i.error && <div className="muted" style={{ fontSize: 12 }}>{i.error}</div>}</td>
            <td className="muted">{i.last_sent_at ? `${ago(i.last_sent_at)}${i.send_count > 1 ? ` (${i.send_count} times)` : ''}` : 'Not yet'}</td>
            <td className="r" style={{ whiteSpace: 'nowrap' }}>
              {(admin || i.role === 'staff') && <>
                <button className="btn small" type="button" disabled={act.busy} onClick={() => act.run(async () => {
                  const s = await sendInvites(cid, [i.id]);
                  say(s.notDeployed ? 'The invite email service is not set up yet (see SETUP, "Staff invitations"). They can still sign up with this email and will be added automatically.' : s.sent ? `Invitation emailed to ${i.email}` : `Could not send: ${s.errors.join('; ')}`); reload(); })}>{i.last_sent_at ? 'Resend' : 'Send'}</button>
                <ConfirmButton className="btn small ghost" label="Revoke" confirm={`Cancel the invitation to ${i.email}? The link will no longer give access.`} onConfirm={() => act.run(async () => { await rpc('revoke_invite', { p_id: i.id }); reload(); }, 'Invitation revoked')} />
              </>}
            </td></tr>)}</tbody></table></div>
      </>}
      {revoked.length > 0 && <div className="body muted" style={{ fontSize: 13, borderTop: '1px solid var(--line)' }}>Revoked: {revoked.map(i => i.email).join(', ')}. Invite them again above if needed.</div>}
    </>}
  </Panel>;
}
