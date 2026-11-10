import { useEffect, useRef, useState } from 'react';
import { q, rpc, supabase } from '../lib/supabase';
import { useSession } from '../lib/session';
import { ConfirmButton, Field, Loading, PageHead, Panel, Select, useAction, useLoad, useToast } from '../components/ui';
import { FleetReminderPanel } from './AssetMore';

const LEVELS: [string, string][] = [['all', 'Everything'], ['approvals', 'Approvals only (requests to decide, and decisions on mine)'], ['off', 'Nothing']];

// ---------------------------------------------------------------- Each person: Telegram and email
export function MyChannelsPanel() {
  const { cid } = useSession();
  const act = useAction();
  const toast = useToast();
  const [waiting, setWaiting] = useState(false);
  const timer = useRef<number | null>(null);
  const { data, error, reload } = useLoad(() => rpc<any>('my_channels', { cid }), [cid]);
  useEffect(() => () => { if (timer.current) window.clearTimeout(timer.current); }, []);
  if (error) return null;   // older database
  if (!data) return <Panel title="How you are notified"><Loading loading /></Panel>;

  const poll = (tries: number) => {
    timer.current = window.setTimeout(async () => {
      try {
        const s = await rpc<string>('telegram_link_check', { cid });
        if (s === 'linked') { setWaiting(false); toast('Telegram connected. You will get your notifications there.'); reload(); return; }
        if (s === 'expired' || tries <= 0) { setWaiting(false); toast('Not connected yet. Open Telegram, press Start in the chat with the bot, then press Check again.', true); return; }
        poll(tries - 1);
      } catch (e: any) { setWaiting(false); toast(e.message, true); }
    }, 3000);
  };
  const connect = () => act.run(async () => {
    const r = await rpc<any>('telegram_link_start', { cid });
    window.open(r.url, '_blank', 'noopener');
    setWaiting(true); await rpc('telegram_link_check', { cid }).catch(() => null); poll(30);
  });
  const save = (tg: string, em: string) => act.run(async () => { await rpc('set_my_channels', { cid, p_telegram_level: tg, p_email_level: em }); reload(); }, 'Saved');

  return <Panel title="How you are notified" pad>
    <p className="muted" style={{ marginTop: 0 }}>Everything always appears here under the bell. You can also get it on your phone.</p>
    <div className="grid-form">
      <div>
        <div className="label">Telegram (private chat)</div>
        {!data.telegram_ready ? <p className="muted" style={{ margin: '4px 0' }}>Not set up for the company yet. An owner or admin adds the bot under Settings → Telegram & email.</p>
          : data.telegram_linked ? <p style={{ margin: '4px 0' }}><span className="pill good">Connected</span> {data.telegram_username ? '@' + data.telegram_username : ''}{' '}
              <ConfirmButton className="btn small ghost" label="Disconnect" confirm="Stop Telegram messages to this account?" onConfirm={() => act.run(async () => { await rpc('telegram_unlink', { cid }); reload(); }, 'Disconnected')} /></p>
          : <div style={{ margin: '4px 0' }}>
              <button className="btn primary" type="button" disabled={act.busy || waiting} onClick={connect}>{waiting ? 'Waiting for Telegram…' : 'Connect Telegram'}</button>
              {waiting && <button className="btn" type="button" style={{ marginLeft: 6 }} onClick={() => { if (timer.current) window.clearTimeout(timer.current); poll(10); }}>Check again</button>}
              <p className="muted" style={{ fontSize: 13, margin: '6px 0 0' }}>Telegram opens the chat with @{data.bot_username}. Press <b>Start</b>, then come back here; it connects within a few seconds. On a computer without Telegram, open this page on your phone.</p>
            </div>}
        {data.telegram_linked && <Select label="Send to Telegram" id="mc-tg" value={data.telegram_level} onChange={v => save(v, data.email_level)} options={LEVELS} />}
      </div>
      <div>
        <div className="label">Email</div>
        {!data.email_ready ? <p className="muted" style={{ margin: '4px 0' }}>Not set up for the company yet.</p>
          : <><p style={{ margin: '4px 0' }}>To <b>{data.email}</b></p>
            <Select label="Send by email" id="mc-em" value={data.email_level} onChange={v => save(data.telegram_level, v)} options={LEVELS} /></>}
      </div>
    </div>
    {(data.telegram_linked || data.email_ready) && data.pg_net && <div className="actions" style={{ marginTop: 10 }}>
      <button className="btn" type="button" disabled={act.busy} onClick={() => act.run(async () => { await rpc('test_my_channels', { cid }); }, 'Test sent. It should arrive within a minute.')}>Send me a test</button></div>}
  </Panel>;
}

// ---------------------------------------------------------------- Owners and admins: the company bot and email sender
export function MessagingSettingsPage() {
  const { cid, can } = useSession();
  const act = useAction();
  const [tg, setTg] = useState<any | null>(null);
  const [em, setEm] = useState<any | null>(null);
  const { data, error, loading, reload } = useLoad(async () => {
    const [t, e, ov] = await Promise.all([
      q<any>(supabase.from('company_telegram').select('*').eq('company_id', cid).maybeSingle() as any).catch(() => null),
      q<any>(supabase.from('company_email').select('*').eq('company_id', cid).maybeSingle() as any).catch(() => null),
      rpc<any>('channel_overview', { cid }).catch(() => null),
    ]);
    return { t, e, ov };
  }, [cid]);
  if (!can()) return <><PageHead title="Telegram & email" /><Panel pad><p className="muted" style={{ margin: 0 }}>Only an owner or admin can set these up. Your own choices are under Notifications.</p></Panel><MyChannelsPanel /></>;
  const t = tg || { bot_token: data?.t?.bot_token || '', bot_username: data?.t?.bot_username || '', personal: data?.t?.personal ?? true, app_url: data?.t?.app_url || window.location.origin,
    chat_id: data?.t?.chat_id || '', enabled: data?.t?.enabled ?? false, events: data?.t?.events || ['transfer', 'request', 'decision', 'low_stock', 'fleet'] };
  const e = em || { api_key: data?.e?.api_key || '', from_email: data?.e?.from_email || '', from_name: data?.e?.from_name || '', enabled: data?.e?.enabled ?? false };
  const saveTg = () => act.run(async () => {
    if (t.bot_token && !/^\d+:[\w-]{20,}$/.test(t.bot_token.trim())) throw new Error('That does not look like a bot token. It looks like 7123456789:AAH… and comes from @BotFather.');
    await q(supabase.from('company_telegram').upsert({ company_id: cid, bot_token: t.bot_token.trim() || null, bot_username: t.bot_username.trim().replace(/^@/, '') || null, personal: t.personal,
      app_url: t.app_url.trim().replace(/\/$/, '') || window.location.origin, chat_id: t.chat_id.trim() || null, enabled: t.enabled, events: t.events, updated_at: new Date().toISOString() }) as any);
    setTg(null); reload();
  }, 'Saved');
  const saveEm = () => act.run(async () => {
    if (e.enabled && (!e.api_key.trim() || !/^\S+@\S+\.\S+$/.test(e.from_email.trim()))) throw new Error('Enter the Brevo API key and the sender address.');
    await q(supabase.from('company_email').upsert({ company_id: cid, provider: 'brevo', api_key: e.api_key.trim() || null, from_email: e.from_email.trim() || null, from_name: e.from_name.trim() || null, enabled: e.enabled, updated_at: new Date().toISOString() }) as any);
    setEm(null); reload();
  }, 'Saved');
  const ov = data?.ov;
  return <>
    <PageHead title="Telegram & email" sub="Approvals and notifications go to each person privately on Telegram and by email, as well as in the app." />
    <Loading error={error} loading={loading && !data} />
    {data && <>
      <Panel title="1. Telegram bot" pad>
        <ol className="muted" style={{ marginTop: 0, paddingLeft: 18 }}>
          <li>In Telegram, open <b>@BotFather</b>, send <code>/newbot</code>, give it a name (e.g. Gulfaco Asnys) and a username ending in <code>bot</code>.</li>
          <li>Copy the token BotFather gives you and the bot's username into the boxes below, and save.</li>
          <li>In Supabase, turn on the <b>pg_net</b> extension (Database → Extensions).</li>
          <li>Each person then opens <b>Notifications</b> in Asnys and presses <b>Connect Telegram</b>.</li>
        </ol>
        <div className="grid-form">
          <Field label="Bot token" id="ms-tok" value={t.bot_token} onChange={v => setTg({ ...t, bot_token: v })} placeholder="7123456789:AAH…" />
          <Field label="Bot username" id="ms-user" value={t.bot_username} onChange={v => setTg({ ...t, bot_username: v })} placeholder="gulfaco_asnys_bot" />
          <Field label="App address (for links in messages)" id="ms-url" value={t.app_url} onChange={v => setTg({ ...t, app_url: v })} />
        </div>
        <label className="check"><input type="checkbox" checked={t.personal} onChange={x => setTg({ ...t, personal: x.target.checked })} /> Send private messages to people who connect</label>
        <details style={{ marginTop: 8 }}><summary className="muted" style={{ cursor: 'pointer' }}>Also post some alerts to a group (optional)</summary>
          <div className="grid-form" style={{ marginTop: 8 }}><Field label="Group chat id" id="ms-chat" value={t.chat_id} onChange={v => setTg({ ...t, chat_id: v })} placeholder="-1001234567890" /></div>
          <label className="check"><input type="checkbox" checked={t.enabled} onChange={x => setTg({ ...t, enabled: x.target.checked })} /> Post transfers, requests, low stock and fleet alerts to the group too</label>
        </details>
        <div className="actions" style={{ marginTop: 10 }}><button className="btn primary" type="button" disabled={act.busy || !tg} onClick={saveTg}>Save</button></div>
      </Panel>
      <Panel title="2. Email (Brevo)" pad>
        <ol className="muted" style={{ marginTop: 0, paddingLeft: 18 }}>
          <li>In Brevo: <b>Settings → Senders, domains → Senders → Add a sender</b>, e.g. <code>no-reply@gulfaco.com</code>. Brevo emails a code to that mailbox to confirm it. (Authenticating the domain as well keeps mail out of spam.)</li>
          <li><b>SMTP & API → API keys → Generate a new API key</b>, name it Asnys, copy it.</li>
          <li>Paste the key and the sender below, tick Send emails, save.</li>
        </ol>
        <div className="grid-form">
          <Field label="Brevo API key" id="ms-key" type="password" value={e.api_key} onChange={v => setEm({ ...e, api_key: v })} placeholder="xkeysib-…" />
          <Field label="Sender address" id="ms-from" value={e.from_email} onChange={v => setEm({ ...e, from_email: v })} placeholder="no-reply@gulfaco.com" />
          <Field label="Sender name" id="ms-name" value={e.from_name} onChange={v => setEm({ ...e, from_name: v })} placeholder="Gulfaco Limited" />
        </div>
        <label className="check"><input type="checkbox" checked={e.enabled} onChange={x => setEm({ ...e, enabled: x.target.checked })} /> <b>Send emails</b> (approvals by default; each person can change it)</label>
        <div className="actions" style={{ marginTop: 10 }}><button className="btn primary" type="button" disabled={act.busy || !em} onClick={saveEm}>Save</button></div>
      </Panel>
      {ov && <Panel title={`Who is connected: ${ov.telegram_linked} of ${ov.members} on Telegram`}>
        <div className="scroll"><table><thead><tr><th>Person</th><th>Role</th><th>Telegram</th><th>Email</th></tr></thead>
          <tbody>{ov.people.map((p: any) => <tr key={p.email}><td>{p.email}</td><td style={{ textTransform: 'capitalize' }}>{String(p.role).replace('_', ' ')}</td>
            <td>{p.telegram ? <span className="pill good">{p.telegram_level === 'all' ? 'Everything' : p.telegram_level === 'approvals' ? 'Approvals' : 'Off'}</span> : <span className="muted">Not connected</span>}</td>
            <td>{p.email_level === 'all' ? 'Everything' : p.email_level === 'approvals' ? 'Approvals' : 'Off'}</td></tr>)}</tbody></table></div>
        <p className="muted body" style={{ margin: 0, fontSize: 13 }}>Sent in the last 24 hours: {Object.entries(ov.last_24h || {}).map(([k, n]) => `${n} by ${k}`).join(', ') || 'none'}. Ask people to open Notifications and press Connect Telegram.</p>
      </Panel>}
      <FleetReminderPanel />
      <MyChannelsPanel />
    </>}
  </>;
}
