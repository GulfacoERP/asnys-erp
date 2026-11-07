// Asnys ERP: sends staff invitations.
// Deploy:  supabase functions deploy invite-member
// Secrets: SUPABASE_URL, SUPABASE_ANON_KEY and SUPABASE_SERVICE_ROLE_KEY are provided by Supabase automatically.
//          Optionally set SITE_URL (e.g. https://erp.yourcompany.com.gh) so links open your app.
// The service role key stays here on the server; the browser never sees it.
import { createClient } from 'npm:@supabase/supabase-js@2.45.4';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json({ error: 'Use POST' }, 405);

  const url = Deno.env.get('SUPABASE_URL')!;
  const anon = Deno.env.get('SUPABASE_ANON_KEY')!;
  const service = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
  const auth = req.headers.get('Authorization') || '';
  if (!auth.startsWith('Bearer ')) return json({ error: 'Sign in first' }, 401);

  let body: { company_id?: string; invite_ids?: string[]; redirect_to?: string };
  try { body = await req.json(); } catch { return json({ error: 'Send JSON' }, 400); }
  if (!body.company_id || !Array.isArray(body.invite_ids) || !body.invite_ids.length) return json({ error: 'company_id and invite_ids are required' }, 400);
  if (body.invite_ids.length > 200) return json({ error: 'At most 200 at a time' }, 400);

  // Acts as the signed-in person, so the database checks they may invite (owner, admin, or HR for staff).
  const asUser = createClient(url, anon, { global: { headers: { Authorization: auth } }, auth: { persistSession: false } });
  const { data: invites, error } = await asUser.rpc('invites_to_send', { cid: body.company_id, p_ids: body.invite_ids });
  if (error) return json({ error: error.message }, 403);

  // Links go back to the app. SITE_URL wins; otherwise the app's own address, which must be in Supabase's redirect URLs.
  const site = (Deno.env.get('SITE_URL') || body.redirect_to || '').replace(/\/$/, '');
  const redirectTo = site ? `${site}/` : undefined;

  const admin = createClient(url, service, { auth: { persistSession: false, autoRefreshToken: false } });
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
