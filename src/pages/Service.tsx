import { useEffect, useState } from 'react';
import { Link, useNavigate, useParams, useSearchParams } from 'react-router-dom';
import { q, rpc, supabase } from '../lib/supabase';
import { useSession } from '../lib/session';
import { today } from '../lib/format';
import { downloadCsv } from '../lib/download';
import { casePdf, tablePdf } from '../lib/pdf';
import { BRAND } from '../lib/brand';
import { ConfirmButton, Downloads, Empty, Field, FormModal, Loading, PageHead, Panel, Select, Status, useAction, useLoad } from '../components/ui';

const CHANNELS: [string, string][] = [['phone', 'Phone call'], ['whatsapp', 'WhatsApp'], ['email', 'Email'], ['walk-in', 'Walk-in'], ['web', 'Help centre'], ['social', 'Social media']];
const PRIORITY: [string, string][] = [['low', 'Low'], ['medium', 'Medium'], ['high', 'High'], ['urgent', 'Urgent']];
const CASE_STATUS: [string, string][] = [['new', 'New'], ['in_progress', 'In progress'], ['waiting', 'Waiting on customer'], ['resolved', 'Resolved'], ['closed', 'Closed']];
const hrs = (a: string, b?: string | null) => (b ? Math.round((Date.parse(b) - Date.parse(a)) / 36e5 * 10) / 10 : null);
const helpUrl = (cid: string) => `${location.origin}/help/${cid}`;

function useTeam(cid: string) {
  return useLoad(() => q<any[]>(supabase.from('memberships').select('user_id,email').eq('company_id', cid).order('email') as any), [cid]);
}

// ---------------------------------------------------------------- Case list
export function CasesPage() {
  const { cid, company, session } = useSession();
  const nav = useNavigate();
  const act = useAction();
  const [params, setParams] = useSearchParams();
  const [filter, setFilter] = useState<'open' | 'mine' | 'all'>('open');
  const [edit, setEdit] = useState<any | null>(params.get('new') !== null ? { customer_id: params.get('new') || '', contact_name: '', email: '', phone: '', subject: '', description: '', channel: 'phone', category: '', priority: 'medium', assignee_id: '' } : null);
  const { data: team } = useTeam(cid);
  const { data, error, loading } = useLoad(async () => {
    const [cases, customers] = await Promise.all([
      q<any[]>(supabase.from('support_cases').select('*, customer:customers(name)').eq('company_id', cid).order('opened_at', { ascending: false }).limit(500) as any),
      q<any[]>(supabase.from('customers').select('id,name,phone,email').eq('company_id', cid).order('name') as any),
    ]);
    return { cases, customers };
  }, [cid]);
  const isOpen = (c: any) => !['resolved', 'closed'].includes(c.status);
  const list = (data?.cases || []).filter(c => filter === 'all' || (isOpen(c) && (filter === 'open' || c.assignee_id === session?.user.id)));
  const who = (id: string | null) => team?.find(t => t.user_id === id)?.email.split('@')[0] || '';
  const head = ['Case', 'Opened', 'Customer', 'Subject', 'Channel', 'Priority', 'Status', 'Assigned', 'First reply (hrs)', 'Resolved in (hrs)', 'Rating'];
  const rows = list.map(c => [c.number, c.opened_at.slice(0, 10), c.customer?.name || c.contact_name || '', c.subject, c.channel, c.priority, c.status, who(c.assignee_id),
    String(hrs(c.opened_at, c.first_response_at) ?? ''), String(hrs(c.opened_at, c.resolved_at) ?? ''), c.satisfaction ? String(c.satisfaction) : '']);
  const open = (data?.cases || []).filter(isOpen);

  return <>
    <PageHead title="Support cases" sub={data ? `${open.length} open · ${open.filter(c => ['high', 'urgent'].includes(c.priority)).length} high priority · ${open.filter(c => !c.assignee_id).length} unassigned` : undefined}>
      <Downloads pdf={() => tablePdf({ company: company!, title: 'Support cases', subtitle: today(), head, body: rows, landscape: true, filename: 'cases-' + today() })} csv={() => downloadCsv('cases-' + today(), head, rows)} />
      <Link className="btn" to="/knowledge">Knowledge base</Link>
      <button className="btn primary" type="button" onClick={() => setEdit({ customer_id: '', contact_name: '', email: '', phone: '', subject: '', description: '', channel: 'phone', category: '', priority: 'medium', assignee_id: session?.user.id })}>New case</button>
    </PageHead>
    <div className="actions">
      {([['open', 'Open'], ['mine', 'Assigned to me'], ['all', 'All']] as const).map(([k, l]) => <button key={k} type="button" className={'btn small' + (filter === k ? ' primary' : '')} onClick={() => setFilter(k)}>{l}</button>)}
    </div>
    <Loading error={error} loading={loading && !data} />
    {data && <Panel>{list.length ? <div className="scroll"><table>
      <thead><tr><th>Case</th><th>Customer</th><th>Subject</th><th>Priority</th><th>Status</th><th>Assigned</th><th>Age</th></tr></thead>
      <tbody>{list.map(c => <tr key={c.id} className="click" tabIndex={0} onClick={() => nav('/cases/' + c.id)} onKeyDown={e => e.key === 'Enter' && nav('/cases/' + c.id)}>
        <td className="num">{c.number}<br /><span className="muted" style={{ fontSize: 12 }}>{CHANNELS.find(x => x[0] === c.channel)?.[1]}</span></td>
        <td>{c.customer?.name || c.contact_name}</td><td className="wrap-cell">{c.subject}</td><td><Status s={c.priority} /></td><td><Status s={c.status} /></td>
        <td>{who(c.assignee_id) || <span className="pill warn">Unassigned</span>}</td>
        <td className="num">{Math.max(0, Math.floor((Date.now() - Date.parse(c.opened_at)) / 864e5))}d</td></tr>)}</tbody>
    </table></div> : <Empty>{filter === 'all' ? 'No cases yet. Log complaints, returns and questions here so nothing is forgotten.' : 'Nothing open. Well done.'}</Empty>}</Panel>}

    {edit && data && <FormModal title="New support case" busy={act.busy} onClose={() => { setEdit(null); setParams({}); }}
      onSave={() => act.run(async () => {
        const r = await q<any>(supabase.from('support_cases').insert({ company_id: cid, customer_id: edit.customer_id || null, contact_name: edit.contact_name || null, email: edit.email || null, phone: edit.phone || null,
          subject: edit.subject, description: edit.description || null, channel: edit.channel, category: edit.category || null, priority: edit.priority, assignee_id: edit.assignee_id || null }).select('id').single() as any);
        nav('/cases/' + r.id);
      }, 'Case opened')}>
      <div className="grid-form">
        <Select label="Customer" id="cs-cust" value={edit.customer_id} onChange={v => { const c = data.customers.find(x => x.id === v); setEdit({ ...edit, customer_id: v, phone: edit.phone || c?.phone || '', email: edit.email || c?.email || '' }); }}
          options={[['', 'Not a customer yet / unknown'], ...data.customers.map(c => [c.id, c.name] as [string, string])]} />
        <Field label="Contact person" id="cs-contact" value={edit.contact_name} onChange={v => setEdit({ ...edit, contact_name: v })} />
        <Field label="Phone" id="cs-phone" value={edit.phone} onChange={v => setEdit({ ...edit, phone: v })} />
        <Field label="Email" id="cs-email" type="email" value={edit.email} onChange={v => setEdit({ ...edit, email: v })} />
        <Select label="Came in by" id="cs-chan" value={edit.channel} onChange={v => setEdit({ ...edit, channel: v })} options={CHANNELS} />
        <Select label="Priority" id="cs-pri" value={edit.priority} onChange={v => setEdit({ ...edit, priority: v })} options={PRIORITY} />
        <Field label="Category" id="cs-cat" value={edit.category} onChange={v => setEdit({ ...edit, category: v })} placeholder="e.g. Delivery, Billing, Faulty item" />
        <Select label="Assign to" id="cs-who" value={edit.assignee_id || ''} onChange={v => setEdit({ ...edit, assignee_id: v })} options={[['', 'Unassigned'], ...(team || []).map(t => [t.user_id, t.email] as [string, string])]} />
      </div>
      <Field label="Subject" id="cs-subj" value={edit.subject} onChange={v => setEdit({ ...edit, subject: v })} required />
      <Field label="What happened?" id="cs-desc" type="textarea" value={edit.description} onChange={v => setEdit({ ...edit, description: v })} />
    </FormModal>}
  </>;
}

// ---------------------------------------------------------------- One case
export function CaseView() {
  const { id } = useParams();
  const { cid, company } = useSession();
  const act = useAction();
  const [reply, setReply] = useState({ body: '', internal: false, status: '' });
  const { data: team } = useTeam(cid);
  const { data, error, loading, reload } = useLoad(async () => {
    const [k, messages, articles] = await Promise.all([
      q<any>(supabase.from('support_cases').select('*, customer:customers(id,name)').eq('id', id).single() as any),
      q<any[]>(supabase.from('case_messages').select('*').eq('case_id', id).order('created_at') as any),
      q<any[]>(supabase.from('kb_articles').select('id,title,body').eq('company_id', cid).eq('published', true).order('title') as any),
    ]);
    return { k, messages, articles };
  }, [id]);
  if (!data) return <Loading error={error} loading={loading} />;
  const { k, messages, articles } = data;
  const update = (patch: any, msg?: string) => act.run(async () => { await q(supabase.from('support_cases').update(patch).eq('id', id) as any); reload(); }, msg);
  const trackLink = `${helpUrl(k.company_id)}?case=${encodeURIComponent(k.number)}&code=${k.access_token}`;
  const waText = `Hello${k.contact_name ? ' ' + k.contact_name : ''}, your case ${k.number} with ${company?.name} is being handled. Follow it here: ${trackLink}`;

  return <>
    <PageHead title={`${k.number}: ${k.subject}`} sub={<><Status s={k.status} /> <Status s={k.priority} /> <span className="muted">· {CHANNELS.find(x => x[0] === k.channel)?.[1]} · opened {k.opened_at.slice(0, 16).replace('T', ' ')}
      {k.first_response_at && ` · first reply in ${hrs(k.opened_at, k.first_response_at)} h`}{k.resolved_at && ` · resolved in ${hrs(k.opened_at, k.resolved_at)} h`}{k.satisfaction && ` · rated ${k.satisfaction}/5`}</span></>}>
      <Link className="btn" to="/cases">Back</Link>
      <button className="btn" type="button" onClick={() => casePdf(company!, k, messages)}>Case PDF</button>
      {company?.help_center_enabled && k.phone && <a className="btn" href={`https://wa.me/${k.phone.replace(/\D/g, '').replace(/^0/, '233')}?text=${encodeURIComponent(waText)}`} target="_blank" rel="noreferrer">Send tracking link</a>}
      {!['resolved', 'closed'].includes(k.status) ? <button className="btn primary" type="button" onClick={() => update({ status: 'resolved' }, 'Marked resolved')}>Resolve</button>
        : <button className="btn" type="button" onClick={() => update({ status: 'in_progress' }, 'Reopened')}>Reopen</button>}
    </PageHead>
    <div className="two">
      <div style={{ display: 'grid', gap: 16, alignContent: 'start' }}>
        {k.description && <div className="note" style={{ whiteSpace: 'pre-wrap' }}>{k.description}</div>}
        <Panel title="Conversation">
          {messages.length ? <div style={{ display: 'grid', gap: 10, padding: 16 }}>{messages.map(m => <div key={m.id} style={{
            padding: '10px 12px', borderRadius: 8, maxWidth: '88%', justifySelf: m.author_id ? 'end' : 'start', whiteSpace: 'pre-wrap',
            background: m.internal ? 'var(--warn-bg, #fff7e0)' : m.author_id ? 'var(--accent-soft, var(--sunk))' : 'var(--sunk)', border: m.internal ? '1px dashed var(--warn)' : '1px solid var(--line)' }}>
            <div className="muted" style={{ fontSize: 12, marginBottom: 4 }}>{m.author_name || (m.author_id ? 'Staff' : 'Customer')}{m.internal ? ' · internal note' : ''} · {m.created_at.slice(0, 16).replace('T', ' ')}</div>{m.body}</div>)}</div>
            : <Empty>No replies yet.</Empty>}
          <form className="body" style={{ display: 'grid', gap: 10, borderTop: '1px solid var(--line)' }} onSubmit={e => { e.preventDefault(); act.run(async () => {
            await q(supabase.from('case_messages').insert({ company_id: k.company_id, case_id: id, body: reply.body, internal: reply.internal }) as any);
            if (reply.status) await q(supabase.from('support_cases').update({ status: reply.status }).eq('id', id) as any);
            setReply({ body: '', internal: false, status: '' }); reload(); }, reply.internal ? 'Note added' : 'Reply saved'); }}>
            <Field label={reply.internal ? 'Internal note (the customer never sees this)' : 'Reply to the customer'} id="cv-body" type="textarea" value={reply.body} onChange={v => setReply({ ...reply, body: v })} />
            {articles.length > 0 && !reply.internal && <Select label="Insert a knowledge base answer" id="cv-kb" value="" onChange={v => { const a = articles.find(x => x.id === v); if (a) setReply({ ...reply, body: (reply.body ? reply.body + '\n\n' : '') + a.body }); }}
              options={[['', '—'], ...articles.map(a => [a.id, a.title] as [string, string])]} />}
            <div className="actions">
              <label className="check"><input type="checkbox" checked={reply.internal} onChange={e => setReply({ ...reply, internal: e.target.checked })} /> Internal note</label>
              <select aria-label="Then set status" value={reply.status} onChange={e => setReply({ ...reply, status: e.target.value })}>
                <option value="">Keep status</option>{CASE_STATUS.map(([v, l]) => <option key={v} value={v}>Then: {l}</option>)}</select>
              <button className="btn primary" type="submit" disabled={!reply.body.trim() || act.busy}>{reply.internal ? 'Add note' : 'Save reply'}</button>
            </div>
            {!reply.internal && <p className="muted" style={{ margin: 0, fontSize: 12 }}>Replies show on the customer's tracking page{company?.help_center_enabled ? '' : ' once the help centre is switched on'}. Call or WhatsApp them as well if it is urgent.</p>}
          </form>
        </Panel>
      </div>
      <Panel title="Details" pad>
        <div style={{ display: 'grid', gap: 12 }}>
          <div><div className="label">Customer</div>{k.customer ? <Link to={'/customers/' + k.customer.id}>{k.customer.name}</Link> : <span className="muted">Not linked</span>}
            <div className="muted" style={{ fontSize: 13 }}>{[k.contact_name, k.phone, k.email].filter(Boolean).join(' · ')}</div></div>
          <Select label="Status" id="cv-status" value={k.status} onChange={v => update({ status: v })} options={CASE_STATUS} />
          <Select label="Priority" id="cv-pri" value={k.priority} onChange={v => update({ priority: v })} options={PRIORITY} />
          <Select label="Assigned to" id="cv-who" value={k.assignee_id || ''} onChange={v => update({ assignee_id: v || null }, 'Assigned')} options={[['', 'Unassigned'], ...(team || []).map(t => [t.user_id, t.email] as [string, string])]} />
          <Field label="Category" id="cv-cat" value={k.category || ''} onChange={v => update({ category: v || null })} />
          {company?.help_center_enabled && <div><div className="label">Customer tracking code</div><span className="num">{k.number} · {k.access_token}</span>
            <div><button className="btn small ghost" type="button" style={{ padding: 0 }} onClick={() => navigator.clipboard?.writeText(trackLink)}>Copy tracking link</button></div></div>}
          <ConfirmButton className="btn small ghost" label="Delete case" confirm="Delete this case and its messages?" onConfirm={() => act.run(async () => { await q(supabase.from('support_cases').delete().eq('id', id) as any); history.back(); })} />
        </div>
      </Panel>
    </div>
  </>;
}

// ---------------------------------------------------------------- Knowledge base
export function KnowledgePage() {
  const { cid, company, can, reload: reloadSession } = useSession();
  const act = useAction();
  const [edit, setEdit] = useState<any | null>(null);
  const { data, error, loading, reload } = useLoad(() => q<any[]>(supabase.from('kb_articles').select('*').eq('company_id', cid).order('category', { nullsFirst: false }).order('title') as any), [cid]);
  const on = !!company?.help_center_enabled;
  return <>
    <PageHead title="Knowledge base and help centre" sub="Answers to common questions. Published articles appear on your public help centre and can be dropped into case replies.">
      <Link className="btn" to="/cases">Cases</Link>
      <button className="btn primary" type="button" onClick={() => setEdit({ title: '', category: '', body: '', published: true })}>New article</button>
    </PageHead>
    <Panel title="Public help centre" pad>
      <div className="actions">
        <span>{on ? <span className="pill good">On</span> : <span className="pill">Off</span>} Customers can read published answers, open a case without signing in, follow it with a case number and code, reply and rate the service.</span>
        {can('admin') && <button className={'btn small' + (on ? '' : ' primary')} type="button" onClick={() => act.run(async () => { await q(supabase.from('companies').update({ help_center_enabled: !on }).eq('id', cid) as any); await reloadSession(); }, on ? 'Help centre switched off' : 'Help centre switched on')}>{on ? 'Switch off' : 'Switch on'}</button>}
      </div>
      {on && <p style={{ marginBottom: 0 }}>Share this link on WhatsApp, your website and receipts: <a href={helpUrl(cid)} target="_blank" rel="noreferrer" className="num">{helpUrl(cid)}</a>{' '}
        <button className="btn small ghost" type="button" onClick={() => navigator.clipboard?.writeText(helpUrl(cid))}>Copy</button></p>}
    </Panel>
    <Loading error={error} loading={loading && !data} />
    {data && <Panel>{data.length ? <div className="scroll"><table>
      <thead><tr><th>Article</th><th>Category</th><th>Status</th><th>Updated</th></tr></thead>
      <tbody>{data.map(a => <tr key={a.id} className="click" onClick={() => setEdit({ ...a, category: a.category || '' })}><td><b>{a.title}</b><br /><span className="muted">{a.body.slice(0, 110)}{a.body.length > 110 ? '…' : ''}</span></td>
        <td>{a.category}</td><td>{a.published ? <span className="pill good">Published</span> : <span className="pill">Draft</span>}</td><td className="num">{a.updated_at.slice(0, 10)}</td></tr>)}</tbody>
    </table></div> : <Empty>No articles yet. Start with your delivery times, returns policy, payment options (MoMo numbers, bank) and opening hours.</Empty>}</Panel>}
    {edit && <FormModal title={edit.id ? 'Edit article' : 'New article'} busy={act.busy} onClose={() => setEdit(null)}
      danger={edit.id && <ConfirmButton className="btn danger" label="Delete" confirm="Delete article?" onConfirm={() => act.run(async () => { await q(supabase.from('kb_articles').delete().eq('id', edit.id) as any); setEdit(null); reload(); })} />}
      onSave={() => act.run(async () => {
        const row = { title: edit.title, category: edit.category || null, body: edit.body, published: edit.published, updated_at: new Date().toISOString() };
        if (edit.id) await q(supabase.from('kb_articles').update(row).eq('id', edit.id) as any);
        else await q(supabase.from('kb_articles').insert({ ...row, company_id: cid }) as any);
        setEdit(null); reload();
      }, 'Article saved')}>
      <Field label="Question or title" id="kb-title" value={edit.title} onChange={v => setEdit({ ...edit, title: v })} placeholder="e.g. How long does delivery to Kumasi take?" required />
      <Field label="Category" id="kb-cat" value={edit.category} onChange={v => setEdit({ ...edit, category: v })} placeholder="e.g. Delivery, Payments, Returns" />
      <Field label="Answer" id="kb-body" type="textarea" value={edit.body} onChange={v => setEdit({ ...edit, body: v })} required />
      <label className="check"><input type="checkbox" checked={edit.published} onChange={e => setEdit({ ...edit, published: e.target.checked })} /> Published (visible on the help centre)</label>
    </FormModal>}
  </>;
}

// ---------------------------------------------------------------- Public help centre (no sign-in)
export function PublicHelp({ companyId }: { companyId: string }) {
  const sp = new URLSearchParams(location.search);
  const [search, setSearch] = useState('');
  const [openA, setOpenA] = useState<string | null>(null);
  const [mode, setMode] = useState<'faq' | 'new' | 'track'>(sp.get('case') ? 'track' : 'faq');
  const [form, setForm] = useState({ name: '', email: '', phone: '', subject: '', description: '' });
  const [track, setTrack] = useState({ number: sp.get('case') || '', code: sp.get('code') || '' });
  const [kase, setKase] = useState<any | null>(null);
  const [created, setCreated] = useState<any | null>(null);
  const [msg, setMsg] = useState({ body: '', err: '', busy: false });
  const { data, error, loading } = useLoad(() => rpc<any>('public_help', { p_company: companyId }), [companyId]);
  const run = async (fn: () => Promise<void>) => { setMsg(m => ({ ...m, err: '', busy: true })); try { await fn(); } catch (e: any) { setMsg(m => ({ ...m, err: e.message || String(e) })); } setMsg(m => ({ ...m, busy: false })); };
  const lookup = (n = track.number, c = track.code) => run(async () => { const r = await rpc<any>('case_status_public', { p_number: n, p_token: c }); if (!r) throw new Error('Case not found. Check the case number and code.'); setKase(r); });
  // eslint-disable-next-line react-hooks/exhaustive-deps
  useEffect(() => { if (sp.get('case') && sp.get('code')) lookup(sp.get('case')!, sp.get('code')!); }, []);

  if (loading) return <div className="center muted">Loading…</div>;
  if (error || !data) return <div className="center"><div className="panel body" style={{ maxWidth: 420 }}><h1 style={{ fontSize: 20 }}>Help centre unavailable</h1><p className="muted">This help centre is switched off or the link is wrong.</p></div></div>;
  const articles = (data.articles || []).filter((a: any) => !search || (a.title + ' ' + a.body).toLowerCase().includes(search.toLowerCase()));
  const cats = Array.from(new Set(articles.map((a: any) => a.category || 'General'))) as string[];

  return <div style={{ minHeight: '100vh', background: 'var(--bg)' }}>
    <div style={{ maxWidth: 760, margin: '0 auto', padding: '28px 16px 60px', display: 'grid', gap: 16 }}>
      <div><div className="brand" style={{ gap: 10 }}><div className="mark">{data.name.charAt(0)}</div><h1 style={{ margin: 0, fontSize: 24 }}>{data.name} help centre</h1></div>
        <p className="muted" style={{ margin: '6px 0 0' }}>{[data.phone && 'Call ' + data.phone, data.email].filter(Boolean).join(' · ')}</p></div>
      <div className="actions">
        {([['faq', 'Answers'], ['new', 'Contact us'], ['track', 'Track my case']] as const).map(([k, l]) => <button key={k} type="button" className={'btn' + (mode === k ? ' primary' : '')} onClick={() => { setMode(k); setMsg({ body: '', err: '', busy: false }); }}>{l}</button>)}
      </div>
      {msg.err && <div className="panel body error" role="alert">{msg.err}</div>}

      {mode === 'faq' && <>
        <div className="field"><input aria-label="Search answers" placeholder="Search answers" value={search} onChange={e => setSearch(e.target.value)} /></div>
        {articles.length ? cats.map(cat => <Panel key={cat} title={cat}><div>{articles.filter((a: any) => (a.category || 'General') === cat).map((a: any) => <div key={a.id} style={{ borderTop: '1px solid var(--line)' }}>
          <button type="button" className="btn ghost" style={{ width: '100%', justifyContent: 'space-between', padding: '12px 16px', fontWeight: 600, textAlign: 'left', whiteSpace: 'normal' }} aria-expanded={openA === a.id} onClick={() => setOpenA(openA === a.id ? null : a.id)}>
            {a.title}<span aria-hidden>{openA === a.id ? '−' : '+'}</span></button>
          {openA === a.id && <div style={{ padding: '0 16px 14px', whiteSpace: 'pre-wrap' }}>{a.body}</div>}</div>)}</div></Panel>)
          : <Empty>{search ? 'No answers match. Contact us and we will help.' : 'No answers published yet. Contact us below.'}</Empty>}
      </>}

      {mode === 'new' && (created
        ? <Panel pad><h2 style={{ marginTop: 0 }}>Thank you. We have your request.</h2>
          <p>Your case number is <b className="num">{created.number}</b> and your code is <b className="num">{created.token}</b>. Keep them to follow your case and reply.</p>
          <button className="btn primary" type="button" onClick={() => { setTrack({ number: created.number, code: created.token }); setMode('track'); lookup(created.number, created.token); }}>Follow my case</button></Panel>
        : <Panel pad><form style={{ display: 'grid', gap: 12 }} onSubmit={e => { e.preventDefault(); run(async () => {
            const r = await rpc<any>('submit_case_public', { p_company: companyId, p_name: form.name, p_email: form.email, p_phone: form.phone, p_subject: form.subject, p_description: form.description }); setCreated(r); }); }}>
          <div className="grid-form">
            <Field label="Your name" id="ph-name" value={form.name} onChange={v => setForm({ ...form, name: v })} required />
            <Field label="Phone" id="ph-phone" value={form.phone} onChange={v => setForm({ ...form, phone: v })} inputMode="tel" />
            <Field label="Email" id="ph-email" type="email" value={form.email} onChange={v => setForm({ ...form, email: v })} />
          </div>
          <Field label="Subject" id="ph-subj" value={form.subject} onChange={v => setForm({ ...form, subject: v })} required />
          <Field label="How can we help?" id="ph-desc" type="textarea" value={form.description} onChange={v => setForm({ ...form, description: v })} />
          <p className="muted" style={{ margin: 0, fontSize: 13 }}>Give a phone number or email so we can reply. We use them only for this request.</p>
          <div><button className="btn primary" type="submit" disabled={msg.busy}>Send</button></div>
        </form></Panel>)}

      {mode === 'track' && <>
        <Panel pad><form className="filters" onSubmit={e => { e.preventDefault(); lookup(); }}>
          <Field label="Case number" id="ph-num" value={track.number} onChange={v => setTrack({ ...track, number: v })} placeholder="CASE-00001" required />
          <Field label="Code" id="ph-code" value={track.code} onChange={v => setTrack({ ...track, code: v })} required />
          <button className="btn primary" type="submit" disabled={msg.busy} style={{ marginBottom: 2 }}>Find</button>
        </form></Panel>
        {kase && <Panel title={`${kase.number}: ${kase.subject}`} actions={<Status s={kase.status} />}>
          <div style={{ display: 'grid', gap: 10, padding: 16 }}>{kase.messages.length ? kase.messages.map((m: any, i: number) => <div key={i} style={{ padding: '10px 12px', borderRadius: 8, background: 'var(--sunk)', whiteSpace: 'pre-wrap', justifySelf: m.from === 'You' ? 'end' : 'start', maxWidth: '88%' }}>
            <div className="muted" style={{ fontSize: 12 }}>{m.from} · {String(m.at).slice(0, 16).replace('T', ' ')}</div>{m.body}</div>) : <span className="muted">We have your request and will reply soon.</span>}</div>
          <form className="body" style={{ display: 'grid', gap: 10, borderTop: '1px solid var(--line)' }} onSubmit={e => { e.preventDefault(); run(async () => {
            await rpc('reply_case_public', { p_number: kase.number, p_token: track.code, p_body: msg.body, p_rating: null }); setMsg(m => ({ ...m, body: '' })); await lookup(kase.number, track.code); }); }}>
            <Field label="Add a message" id="ph-reply" type="textarea" value={msg.body} onChange={v => setMsg({ ...msg, body: v })} />
            <div><button className="btn primary" type="submit" disabled={!msg.body.trim() || msg.busy}>Send</button></div>
          </form>
          {['resolved', 'closed'].includes(kase.status) && <div className="body" style={{ borderTop: '1px solid var(--line)' }}>
            <div className="label">{kase.satisfaction ? `You rated us ${kase.satisfaction} out of 5. Thank you.` : 'How did we do?'}</div>
            <div className="actions">{[1, 2, 3, 4, 5].map(n => <button key={n} type="button" className={'btn small' + (kase.satisfaction === n ? ' primary' : '')} aria-label={`${n} out of 5`}
              onClick={() => run(async () => { await rpc('reply_case_public', { p_number: kase.number, p_token: track.code, p_body: '', p_rating: n }); await lookup(kase.number, track.code); })}>{'★'.repeat(n)}</button>)}</div></div>}
        </Panel>}
      </>}
      <p className="muted" style={{ fontSize: 12, textAlign: 'center' }}>Powered by {BRAND}</p>
    </div>
  </div>;
}
