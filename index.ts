// Asnys ERP: staff logins.
//   action "invite" (default): emails invitations.
//   action "create_login":     creates logins with a temporary password (no email needed) and returns the passwords.
//   action "set_password":     gives an existing member a new temporary password.
// People with a temporary password must choose their own at their next sign-in.
// Deploy:  Supabase → Edge Functions → invite-member → Code → paste → Deploy updates (Verify JWT stays on).
// Secrets: SUPABASE_URL, SUPABASE_ANON_KEY and SUPABASE_SERVICE_ROLE_KEY are provided by Supabase automatically.
//          Optionally set SITE_URL (e.g. https://asnys-erp.pages.dev) so email links open your app.
// The service role key stays here on the server; the browser never sees it. Every action is checked by the
// database as the signed-in person first (owners and admins; HR for staff only).
import { createClient } from 'npm:@supabase/supabase-js@2.45.4';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

// Easy to read out or type from a phone: Word-1234-word, about 40 bits of randomness.
const WORDS = ['Tema', 'Volta', 'Kumasi', 'Accra', 'Takoradi', 'Ho', 'Tamale', 'Sunyani', 'Koforidua', 'Cape', 'Ada', 'Keta', 'Aburi', 'Elmina', 'Bole', 'Wa',
  'Cocoa', 'Kente', 'Baobab', 'Shea', 'Mango', 'Palm', 'River', 'Harbour', 'Savanna', 'Forest', 'Falcon', 'Eagle', 'Lion', 'Gazelle', 'Hornbill', 'Pepper'];
const LOWER = 'abcdefghjkmnpqrstuvwxyz';
function tempPassword() {
  const r = new Uint32Array(5);
  crypto.getRandomValues(r);
  const digits = String(1000 + (r[1] % 9000));
  return `${WORDS[r[0] % WORDS.length]}-${digits}-${LOWER[r[2] % LOWER.length]}${LOWER[r[3] % LOWER.length]}${LOWER[r[4] % LOWER.length]}`;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json({ error: 'Use POST' }, 405);

  const url = Deno.env.get('SUPABASE_URL')!;
  const anon = Deno.env.get('SUPABASE_ANON_KEY')!;
  const service = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
  const auth = req.headers.get('Authorization') || '';
  if (!auth.startsWith('Bearer ')) return json({ error: 'Sign in first' }, 401);

  let body: { action?: string; company_id?: string; invite_ids?: string[]; user_id?: string; redirect_to?: string };
  try { body = await req.json(); } catch { return json({ error: 'Send JSON' }, 400); }
  const action = body.action || 'invite';
  if (!body.company_id) return json({ error: 'company_id is required' }, 400);

  // Acts as the signed-in person, so the database checks what they may do.
  const asUser = createClient(url, anon, { global: { headers: { Authorization: auth } }, auth: { persistSession: false } });
  const admin = createClient(url, service, { auth: { persistSession: false, autoRefreshToken: false } });

  // ---------------------------------------------------------------- New password for an existing member
  if (action === 'set_password') {
    if (!body.user_id) return json({ error: 'user_id is required' }, 400);
    const { data: email, error } = await asUser.rpc('password_reset_target', { cid: body.company_id, p_user: body.user_id });
    if (error) return json({ error: error.message }, 403);
    const password = tempPassword();
    const { error: e } = await admin.auth.admin.updateUserById(body.user_id, { password, user_metadata: { must_change_password: true } });
    if (e) return json({ error: e.message }, 400);
    return json({ results: [{ email, ok: true, password }] });
  }

  if (!Array.isArray(body.invite_ids) || !body.invite_ids.length) return json({ error: 'invite_ids are required' }, 400);
  if (body.invite_ids.length > 200) return json({ error: 'At most 200 at a time' }, 400);

  // ---------------------------------------------------------------- Logins with a temporary password
  if (action === 'create_login') {
    const { data: invites, error } = await asUser.rpc('invites_for_password', { cid: body.company_id, p_ids: body.invite_ids });
    if (error) return json({ error: error.message }, 403);
    const results: { id: string; email: string; ok: boolean; password?: string; note?: string; error?: string }[] = [];
    for (const inv of (invites || []) as { id: string; email: string; role: string; company_name: string; user_id: string | null; signed_in: boolean }[]) {
      const password = tempPassword();
      let err: string | undefined; let note: string | undefined; let pw: string | undefined = password;
      if (!inv.user_id) {
        const { error: e } = await admin.auth.admin.createUser({
          email: inv.email, password, email_confirm: true,
          user_metadata: { must_change_password: true, invited_to: inv.company_name, invited_role: inv.role },
        });
        if (e) err = e.message;
      } else if (!inv.signed_in) {
        // Invited by email before but never signed in: give them a password instead.
        const { error: e } = await admin.auth.admin.updateUserById(inv.user_id, { password, email_confirm: true, user_metadata: { must_change_password: true, invited_to: inv.company_name } });
        if (e) err = e.message;
      } else {
        // Already uses Asnys (perhaps for another company): keep their password; they are added at their next sign-in.
        pw = undefined; note = 'Already has a login. They sign in with their existing password and are added to this company.';
      }
      await asUser.rpc('mark_invite_sent', { p_id: inv.id, p_ok: !err, p_error: err ?? null, p_method: 'password' });
      results.push({ id: inv.id, email: inv.email, ok: !err, password: err ? undefined : pw, note, error: err });
    }
    return json({ sent: results.filter(r => r.ok).length, failed: results.filter(r => !r.ok).length, results });
  }

  // ---------------------------------------------------------------- Email invitations (as before)
  const { data: invites, error } = await asUser.rpc('invites_to_send', { cid: body.company_id, p_ids: body.invite_ids });
  if (error) return json({ error: error.message }, 403);

  // Links go back to the app. SITE_URL wins; otherwise the app's own address, which must be in Supabase's redirect URLs.
  const site = (Deno.env.get('SITE_URL') || body.redirect_to || '').replace(/\/$/, '');
  const redirectTo = site ? `${site}/` : undefined;

  const plain = createClient(url, anon, { auth: { persistSession: false } });
  const results: { id: string; email: string; ok: boolean; method?: string; error?: string }[] = [];

  for (const inv of (invites || []) as { id: string; email: string; role: string; company_name: string; has_login: boolean }[]) {
    let method = inv.has_login ? 'magic_link' : 'invite';
    let err: string | undefined;
    if (!inv.has_login) {
      const { error: e } = await admin.auth.admin.inviteUserByEmail(inv.email, {
        redirectTo, data: { invited_to: inv.company_name, invited_role: inv.role },
      });
      if (e && /already|registered|exists/i.test(e.message)) method = 'magic_link';
      else if (e) err = e.message;
    }
    if (method === 'magic_link') {
      // Already has an Asnys login (perhaps for another company): a sign-in link adds them on arrival.
      const { error: e } = await plain.auth.signInWithOtp({ email: inv.email, options: { shouldCreateUser: false, emailRedirectTo: redirectTo } });
      if (e) err = e.message;
    }
    await asUser.rpc('mark_invite_sent', { p_id: inv.id, p_ok: !err, p_error: err ?? null, p_method: method });
    results.push({ id: inv.id, email: inv.email, ok: !err, method, error: err });
  }
  return json({ sent: results.filter(r => r.ok).length, failed: results.filter(r => !r.ok).length, results });
});
