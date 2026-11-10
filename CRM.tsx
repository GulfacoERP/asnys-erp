import { useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { q, rpc, supabase } from '../lib/supabase';
import { useSession } from '../lib/session';
import { cedis, longDate, money, today } from '../lib/format';
import { downloadCsv } from '../lib/download';
import { tablePdf } from '../lib/pdf';
import { ConfirmButton, Downloads, Empty, Field, FormModal, Loading, PageHead, Panel, Select, Status, useAction, useLoad } from '../components/ui';
import { amt } from '../components/docs';

const STAGES: [string, string, number][] = [
  ['prospecting', 'Prospecting', 10], ['qualification', 'Qualification', 25], ['proposal', 'Proposal sent', 50],
  ['negotiation', 'Negotiation', 75], ['won', 'Won', 100], ['lost', 'Lost', 0],
];
const SOURCES: [string, string][] = [['referral', 'Referral'], ['walk-in', 'Walk-in'], ['website', 'Website'], ['social', 'Social media / WhatsApp'], ['event', 'Trade fair or event'], ['cold call', 'Cold call'], ['other', 'Other']];
const LEAD_STATUS: [string, string][] = [['new', 'New'], ['contacted', 'Contacted'], ['qualified', 'Qualified'], ['unqualified', 'Not a fit']];
const KINDS: [string, string][] = [['call', 'Call'], ['visit', 'Field visit'], ['meeting', 'Meeting'], ['whatsapp', 'WhatsApp'], ['email', 'Email'], ['task', 'Task'], ['note', 'Note']];

function useTeam(cid: string) {
  return useLoad(() => q<any[]>(supabase.from('memberships').select('user_id,email,role').eq('company_id', cid).order('email') as any), [cid]);
}
const who = (team: any[] | null, id: string | null) => team?.find(t => t.user_id === id)?.email?.split('@')[0] || '—';

export function CrmPage() {
  const { cid, company, session } = useSession();
  const nav = useNavigate();
  const act = useAction();
  const [tab, setTab] = useState<'pipeline' | 'leads'>('pipeline');
  const [mine, setMine] = useState(false);
  const [readyOnly, setReadyOnly] = useState(false);
  const [lead, setLead] = useState<any | null>(null);
  const [opp, setOpp] = useState<any | null>(null);
  const { data: team } = useTeam(cid);
  const { data, error, loading, reload } = useLoad(async () => {
    const [leads, opps, customers, territories, currencies, campaigns, partners] = await Promise.all([
      q<any[]>(supabase.from('leads').select('*').eq('company_id', cid).order('created_at', { ascending: false }) as any),
      q<any[]>(supabase.from('opportunities').select('*, customer:customers(name)').eq('company_id', cid).order('expected_close', { nullsFirst: false }) as any),
      q<any[]>(supabase.from('customers').select('id,name').eq('company_id', cid).order('name') as any),
      q<any[]>(supabase.from('sales_territories').select('*').eq('company_id', cid).order('name') as any),
      q<any[]>(supabase.from('currencies').select('code,rate').eq('company_id', cid) as any),
      q<any[]>(supabase.from('campaigns').select('id,name,status').eq('company_id', cid).order('start_date', { ascending: false, nullsFirst: false }) as any),
      q<any[]>(supabase.from('partners').select('id,name').eq('company_id', cid).eq('active', true).order('name') as any),
    ]);
    return { leads, opps, customers, territories, currencies, campaigns, partners };
  }, [cid]);
  const me = session?.user.id;
  const fx = (code: string) => (code === 'GHS' ? 1 : Number(data?.currencies.find(c => c.code === code)?.rate || 0));
  const opps = (data?.opps || []).filter(o => !mine || o.owner_id === me);
  const open = opps.filter(o => !['won', 'lost'].includes(o.stage));
  const pipe = open.reduce((s, o) => s + Number(o.amount) * fx(o.currency), 0);
  const weighted = open.reduce((s, o) => s + Number(o.amount) * fx(o.currency) * o.probability / 100, 0);
  const leads = (data?.leads || []).filter(l => l.status !== 'converted' && (!mine || l.owner_id === me) && (!readyOnly || l.sales_ready)).sort((a, b) => b.score - a.score);
  const nameOf = (arr: any[] | undefined, id: string | null) => arr?.find(x => x.id === id)?.name || '';

  const oHead = ['Opportunity', 'Customer', 'Stage', 'Amount', 'Currency', 'Probability %', 'Expected close', 'Owner'];
  const oRows = opps.map(o => [o.title, o.customer?.name || '', o.stage, money(o.amount), o.currency, String(o.probability), o.expected_close || '', who(team, o.owner_id)]);
  const lHead = ['Name', 'Organisation', 'Phone', 'Email', 'Town', 'Source', 'Campaign', 'Partner', 'Status', 'Score', 'Sales-ready', 'Est. value (GHS)', 'Owner'];
  const lRows = leads.map(l => [l.name, l.organisation || '', l.phone || '', l.email || '', l.city || '', l.source || '', nameOf(data?.campaigns, l.campaign_id), nameOf(data?.partners, l.partner_id), l.status, String(l.score), l.sales_ready ? 'Yes' : '', money(l.estimated_value), who(team, l.owner_id)]);

  const saveLead = () => act.run(async () => {
    const row = { name: lead.name, organisation: lead.organisation || null, phone: lead.phone || null, email: lead.email || null, city: lead.city || null, source: lead.source || null,
      status: lead.status, owner_id: lead.owner_id || null, territory_id: lead.territory_id || null, campaign_id: lead.campaign_id || null, partner_id: lead.partner_id || null, estimated_value: Number(lead.estimated_value) || null, notes: lead.notes || null };
    if (lead.id) await q(supabase.from('leads').update(row).eq('id', lead.id) as any);
    else await q(supabase.from('leads').insert({ ...row, company_id: cid }) as any);
    setLead(null); reload();
  }, 'Lead saved');
  const saveOpp = () => act.run(async () => {
    const closing = ['won', 'lost'].includes(opp.stage);
    const row = { title: opp.title, customer_id: opp.customer_id || null, stage: opp.stage, amount: Number(opp.amount) || 0, currency: opp.currency, probability: Number(opp.probability),
      expected_close: opp.expected_close || null, owner_id: opp.owner_id || null, campaign_id: opp.campaign_id || null, partner_id: opp.partner_id || null, lost_reason: opp.stage === 'lost' ? opp.lost_reason || null : null, closed_at: closing ? (opp.closed_at || today()) : null };
    if (opp.id) await q(supabase.from('opportunities').update(row).eq('id', opp.id) as any);
    else await q(supabase.from('opportunities').insert({ ...row, company_id: cid }) as any);
    setOpp(null); reload();
  }, 'Opportunity saved');
  const quoteFrom = (o: any) => act.run(async () => {
    if (!o.customer_id) throw new Error('Choose a customer for this opportunity first.');
    const qt = await q<any>(supabase.from('sales_quotes').insert({ company_id: cid, customer_id: o.customer_id, opportunity_id: o.id, quote_date: today(), currency: o.currency, exchange_rate: fx(o.currency) || 1, notes: o.title }).select('id').single() as any);
    if (['prospecting', 'qualification'].includes(o.stage)) await q(supabase.from('opportunities').update({ stage: 'proposal', probability: 50 }).eq('id', o.id) as any);
    nav(`/quotes/${qt.id}/edit`);
  });

  return <>
    <PageHead title="CRM" sub={data ? `${open.length} open deals · pipeline ${cedis(pipe)} · weighted ${cedis(weighted)}` : undefined}>
      {tab === 'pipeline'
        ? <Downloads pdf={() => tablePdf({ company: company!, title: 'Sales pipeline', subtitle: longDate(today()), head: oHead, body: oRows, rightAlign: [3, 5], landscape: true, filename: 'pipeline-' + today(), notes: `Open pipeline GHS ${money(pipe)}; weighted by probability GHS ${money(weighted)}.` })} csv={() => downloadCsv('pipeline-' + today(), oHead, oRows)} />
        : <Downloads pdf={() => tablePdf({ company: company!, title: 'Leads', head: lHead, body: lRows, rightAlign: [9, 11], landscape: true, filename: 'leads' })} csv={() => downloadCsv('leads', lHead, lRows)} />}
      <button className="btn" type="button" onClick={() => setLead({ name: '', organisation: '', phone: '', email: '', city: '', source: 'referral', status: 'new', owner_id: me, territory_id: '', campaign_id: '', partner_id: '', estimated_value: '', notes: '' })}>New lead</button>
      <button className="btn primary" type="button" onClick={() => setOpp({ title: '', customer_id: data?.customers[0]?.id || '', stage: 'prospecting', amount: '', currency: 'GHS', probability: 10, expected_close: '', owner_id: me, lost_reason: '', campaign_id: '', partner_id: '' })}>New opportunity</button>
    </PageHead>
    <div className="actions">
      <button type="button" className={'btn small' + (tab === 'pipeline' ? ' primary' : '')} onClick={() => setTab('pipeline')}>Pipeline</button>
      <button type="button" className={'btn small' + (tab === 'leads' ? ' primary' : '')} onClick={() => setTab('leads')}>Leads ({leads.length})</button>
      <label className="check" style={{ marginLeft: 8 }}><input type="checkbox" checked={mine} onChange={e => setMine(e.target.checked)} /> Only mine</label>
      {tab === 'leads' && <label className="check"><input type="checkbox" checked={readyOnly} onChange={e => setReadyOnly(e.target.checked)} /> Sales-ready only</label>}
      <span style={{ flex: 1 }} /><Link className="btn small ghost" to="/crm-dashboard">CRM dashboard</Link>
    </div>
    <Loading error={error} loading={loading && !data} />

    {data && tab === 'pipeline' && <div className="board" style={{ gridTemplateColumns: 'repeat(auto-fit, minmax(190px, 1fr))' }}>
      {STAGES.map(([k, label]) => {
        const col = opps.filter(o => o.stage === k);
        const tot = col.reduce((s, o) => s + Number(o.amount) * fx(o.currency), 0);
        return <div className="column" key={k}>
          <h3>{label} · {col.length}<br /><span className="num" style={{ fontWeight: 400 }}>{cedis(tot)}</span></h3>
          {col.map(o => <div className="task" key={o.id}>
            <button className="btn ghost small" type="button" style={{ padding: 0, justifyContent: 'flex-start', fontWeight: 600, whiteSpace: 'normal', textAlign: 'left' }}
              onClick={() => setOpp({ ...o, customer_id: o.customer_id || '', expected_close: o.expected_close || '', lost_reason: o.lost_reason || '', campaign_id: o.campaign_id || '', partner_id: o.partner_id || '' })}>{o.title}</button>
            <span className="muted" style={{ fontSize: 12 }}>{o.customer?.name} · {amt(o.amount, o.currency)}{o.expected_close ? ' · ' + o.expected_close : ''}</span>
            <span className="muted" style={{ fontSize: 12 }}>{who(team, o.owner_id)} · {o.probability}%</span>
            {!['won', 'lost'].includes(k) && <div className="row"><button className="btn small" type="button" onClick={() => quoteFrom(o)}>Quote</button></div>}
          </div>)}
        </div>;
      })}
    </div>}

    {data && tab === 'leads' && <Panel>{leads.length ? <div className="scroll"><table>
      <thead><tr><th>Lead</th><th>Contact</th><th>Source</th><th className="r">Score</th><th className="r">Est. value</th><th>Owner</th><th>Status</th><th></th></tr></thead>
      <tbody>{leads.map(l => <tr key={l.id}>
        <td><button className="btn ghost small" style={{ padding: 0, fontWeight: 600 }} type="button" onClick={() => setLead(Object.fromEntries(Object.entries(l).map(([k, v]) => [k, v ?? ''])))}>{l.organisation || l.name}</button>
          {l.organisation && <><br /><span className="muted">{l.name}</span></>}</td>
        <td className="num">{l.phone}<br /><span className="muted">{l.city}</span></td><td>{l.source}{(l.campaign_id || l.partner_id) && <><br /><span className="muted" style={{ fontSize: 12 }}>{[nameOf(data.campaigns, l.campaign_id), nameOf(data.partners, l.partner_id)].filter(Boolean).join(' · ')}</span></>}</td>
        <td className="r"><span className={'pill ' + (l.sales_ready ? 'good' : l.score >= 30 ? 'warn' : '')} title={l.sales_ready ? 'Sales-ready' : 'Score out of 100'}>{l.score}{l.sales_ready ? ' · ready' : ''}</span></td>
        <td className="r num">{l.estimated_value ? money(l.estimated_value) : ''}</td><td>{who(team, l.owner_id)}</td><td><Status s={l.status} /></td>
        <td className="r"><ConfirmButton className="btn small primary" label="Convert" confirm="Make a customer and a deal?" onConfirm={() => act.run(async () => { await rpc('convert_lead', { p_lead: l.id, p_create_opportunity: true }); reload(); setTab('pipeline'); }, 'Customer and opportunity created')} /></td></tr>)}</tbody>
    </table></div> : <Empty>No open leads.</Empty>}</Panel>}

    {lead && data && <FormModal title={lead.id ? 'Edit lead' : 'New lead'} busy={act.busy} onClose={() => setLead(null)} onSave={saveLead}
      danger={lead.id && <ConfirmButton className="btn danger" label="Delete" confirm="Delete?" onConfirm={() => act.run(async () => { await q(supabase.from('leads').delete().eq('id', lead.id) as any); setLead(null); reload(); })} />}>
      <div className="grid-form">
        <Field label="Contact name" id="ld-name" value={lead.name} onChange={v => setLead({ ...lead, name: v })} required />
        <Field label="Organisation" id="ld-org" value={lead.organisation} onChange={v => setLead({ ...lead, organisation: v })} />
        <Field label="Phone" id="ld-phone" value={lead.phone} onChange={v => setLead({ ...lead, phone: v })} />
        <Field label="Email" id="ld-email" type="email" value={lead.email} onChange={v => setLead({ ...lead, email: v })} />
        <Field label="Town" id="ld-city" value={lead.city} onChange={v => setLead({ ...lead, city: v })} />
        <Select label="Source" id="ld-src" value={lead.source} onChange={v => setLead({ ...lead, source: v })} options={SOURCES} />
        <Select label="Status" id="ld-status" value={lead.status} onChange={v => setLead({ ...lead, status: v })} options={LEAD_STATUS} />
        <Field label="Estimated value (GH₵)" id="ld-val" type="number" step="0.01" min="0" value={lead.estimated_value} onChange={v => setLead({ ...lead, estimated_value: v })} />
        <Select label="Owner" id="ld-owner" value={lead.owner_id} onChange={v => setLead({ ...lead, owner_id: v })} options={(team || []).map(t => [t.user_id, t.email])} />
        {data.territories.length > 0 && <Select label="Territory" id="ld-terr" value={lead.territory_id} onChange={v => setLead({ ...lead, territory_id: v })} options={[['', 'None'], ...data.territories.map(t => [t.id, t.name] as [string, string])]} />}
        {data.campaigns.length > 0 && <Select label="Campaign" id="ld-camp" value={lead.campaign_id || ''} onChange={v => setLead({ ...lead, campaign_id: v })} options={[['', 'None'], ...data.campaigns.map(t => [t.id, t.name] as [string, string])]} />}
        {data.partners.length > 0 && <Select label="Partner" id="ld-partner" value={lead.partner_id || ''} onChange={v => setLead({ ...lead, partner_id: v })} options={[['', 'None'], ...data.partners.map(t => [t.id, t.name] as [string, string])]} />}
      </div>
      {lead.id && <p className="muted" style={{ margin: 0, fontSize: 13 }}>Score {lead.score}/100{lead.sales_ready === true ? ' — sales-ready' : ''}. It updates when you save and as calls and visits are completed.</p>}
      <Field label="Notes" id="ld-notes" type="textarea" value={lead.notes} onChange={v => setLead({ ...lead, notes: v })} />
    </FormModal>}

    {opp && data && <FormModal title={opp.id ? 'Opportunity' : 'New opportunity'} busy={act.busy} onClose={() => setOpp(null)} onSave={saveOpp}
      danger={opp.id && <ConfirmButton className="btn danger" label="Delete" confirm="Delete?" onConfirm={() => act.run(async () => { await q(supabase.from('opportunities').delete().eq('id', opp.id) as any); setOpp(null); reload(); })} />}>
      <Field label="What are they buying?" id="op-title" value={opp.title} onChange={v => setOpp({ ...opp, title: v })} placeholder="e.g. 200 bags of rice monthly" required />
      <div className="grid-form">
        <Select label="Customer" id="op-cust" value={opp.customer_id} onChange={v => setOpp({ ...opp, customer_id: v })} options={[['', '—'], ...data.customers.map(c => [c.id, c.name] as [string, string])]} />
        <Select label="Stage" id="op-stage" value={opp.stage} onChange={v => setOpp({ ...opp, stage: v, probability: STAGES.find(s => s[0] === v)![2] })} options={STAGES.map(s => [s[0], s[1]])} />
        <Field label="Amount" id="op-amt" type="number" step="0.01" min="0" value={opp.amount} onChange={v => setOpp({ ...opp, amount: v })} />
        <Select label="Currency" id="op-ccy" value={opp.currency} onChange={v => setOpp({ ...opp, currency: v })} options={[['GHS', 'GHS'], ...data.currencies.map(c => [c.code, c.code] as [string, string])]} />
        <Field label="Probability %" id="op-prob" type="number" step="5" min="0" max="100" value={opp.probability} onChange={v => setOpp({ ...opp, probability: v })} />
        <Field label="Expected close" id="op-close" type="date" value={opp.expected_close} onChange={v => setOpp({ ...opp, expected_close: v })} />
        <Select label="Owner" id="op-owner" value={opp.owner_id || ''} onChange={v => setOpp({ ...opp, owner_id: v })} options={(team || []).map(t => [t.user_id, t.email])} />
        {data.campaigns.length > 0 && <Select label="Campaign" id="op-camp" value={opp.campaign_id || ''} onChange={v => setOpp({ ...opp, campaign_id: v })} options={[['', 'None'], ...data.campaigns.map(t => [t.id, t.name] as [string, string])]} />}
        {data.partners.length > 0 && <Select label="Partner" id="op-partner" value={opp.partner_id || ''} onChange={v => setOpp({ ...opp, partner_id: v })} options={[['', 'None'], ...data.partners.map(t => [t.id, t.name] as [string, string])]} />}
      </div>
      {opp.stage === 'lost' && <Field label="Why was it lost?" id="op-lost" value={opp.lost_reason} onChange={v => setOpp({ ...opp, lost_reason: v })} placeholder="Price, competitor, timing…" />}
      {opp.id && <ActivityList cid={cid} filter={{ opportunity_id: opp.id }} team={team} compact />}
    </FormModal>}
  </>;
}

/** Field-visit check-in using the phone's location. */
function useCheckIn() {
  const [pos, setPos] = useState<{ latitude: number; longitude: number } | null>(null);
  const [msg, setMsg] = useState('');
  const get = () => {
    if (!navigator.geolocation) { setMsg('Location is not available on this device.'); return; }
    setMsg('Getting location…');
    navigator.geolocation.getCurrentPosition(p => { setPos({ latitude: +p.coords.latitude.toFixed(6), longitude: +p.coords.longitude.toFixed(6) }); setMsg(''); },
      () => setMsg('Location permission was refused. The visit is saved without a location.'), { enableHighAccuracy: true, timeout: 15000 });
  };
  return { pos, msg, get, reset: () => { setPos(null); setMsg(''); } };
}

export function ActivityList({ cid, filter, team, compact }: { cid: string; filter?: Record<string, string>; team: any[] | null; compact?: boolean }) {
  const { session, company } = useSession();
  const act = useAction();
  const loc = useCheckIn();
  const [mine, setMine] = useState(!filter);
  const [showDone, setShowDone] = useState(false);
  const [edit, setEdit] = useState<any | null>(null);
  const { data, reload } = useLoad(async () => {
    let qy = supabase.from('crm_activities').select('*, customer:customers(name), lead:leads(name,organisation), opp:opportunities(title)').eq('company_id', cid);
    if (filter) for (const [k, v] of Object.entries(filter)) qy = qy.eq(k, v);
    const [acts, customers] = await Promise.all([
      q<any[]>(qy.order('due_at', { ascending: true, nullsFirst: false }).limit(300) as any),
      compact ? Promise.resolve([]) : q<any[]>(supabase.from('customers').select('id,name').eq('company_id', cid).order('name') as any),
    ]);
    return { acts, customers };
  }, [cid, JSON.stringify(filter)]);
  const list = (data?.acts || []).filter(a => (showDone || !a.done) && (!mine || a.owner_id === session?.user.id));
  const about = (a: any) => a.customer?.name || a.lead?.organisation || a.lead?.name || a.opp?.title || '';
  const head = ['Due', 'Type', 'Subject', 'About', 'Owner', 'Done', 'Outcome', 'Location'];
  const rows = list.map(a => [a.due_at ? a.due_at.slice(0, 16).replace('T', ' ') : '', a.kind, a.subject, about(a), who(team, a.owner_id), a.done ? 'Yes' : 'No', a.outcome || '', a.latitude ? `${a.latitude}, ${a.longitude}` : '']);

  const save = () => act.run(async () => {
    const row: any = { kind: edit.kind, subject: edit.subject, due_at: edit.due_at ? new Date(edit.due_at).toISOString() : null, outcome: edit.outcome || null, done: edit.done,
      done_at: edit.done ? new Date().toISOString() : null, customer_id: edit.customer_id || null, ...(filter || {}) };
    if (loc.pos) Object.assign(row, loc.pos);
    if (edit.id) await q(supabase.from('crm_activities').update(row).eq('id', edit.id) as any);
    else await q(supabase.from('crm_activities').insert({ ...row, company_id: cid }) as any);
    setEdit(null); loc.reset(); reload();
  }, 'Saved');
  const complete = (a: any) => act.run(async () => { await q(supabase.from('crm_activities').update({ done: true, done_at: new Date().toISOString() }).eq('id', a.id) as any); reload(); }, 'Marked done');

  const table = list.length ? <div className="scroll"><table>
    <thead><tr><th>Due</th><th>Activity</th>{!compact && <th>About</th>}<th>Owner</th><th></th></tr></thead>
    <tbody>{list.map(a => <tr key={a.id} style={a.done ? { opacity: .6 } : undefined}>
      <td className="num" style={{ color: !a.done && a.due_at && a.due_at.slice(0, 10) < today() ? 'var(--bad)' : undefined }}>{a.due_at ? a.due_at.slice(0, 16).replace('T', ' ') : '—'}</td>
      <td><span className="pill">{KINDS.find(k => k[0] === a.kind)?.[1]}</span> {a.subject}{a.outcome && <><br /><span className="muted">{a.outcome}</span></>}
        {a.latitude && <><br /><a href={`https://www.google.com/maps?q=${a.latitude},${a.longitude}`} target="_blank" rel="noreferrer" style={{ fontSize: 12 }}>Checked in here</a></>}</td>
      {!compact && <td>{about(a)}</td>}<td>{who(team, a.owner_id)}</td>
      <td className="r"><span className="actions" style={{ justifyContent: 'flex-end' }}>
        {!a.done && <button className="btn small" type="button" onClick={() => complete(a)}>Done</button>}
        <button className="btn small ghost" type="button" onClick={() => setEdit({ ...a, due_at: a.due_at ? a.due_at.slice(0, 16) : '', outcome: a.outcome || '', customer_id: a.customer_id || '' })}>Edit</button></span></td></tr>)}</tbody>
  </table></div> : <Empty>No activities.</Empty>;

  return <>
    {compact ? <><div className="label">Activities</div>{table}<div><button className="btn small" type="button" onClick={() => setEdit({ kind: 'call', subject: '', due_at: '', done: false, outcome: '', customer_id: '' })}>Add activity</button></div></>
      : <Panel title={<div className="actions"><h2>Activities</h2>
          <label className="check"><input type="checkbox" checked={mine} onChange={e => setMine(e.target.checked)} /> Only mine</label>
          <label className="check"><input type="checkbox" checked={showDone} onChange={e => setShowDone(e.target.checked)} /> Show done</label></div>}
        actions={<><Downloads pdf={() => tablePdf({ company: company!, title: 'Sales activities', head, body: rows, landscape: true, filename: 'activities-' + today() })} csv={() => downloadCsv('activities-' + today(), head, rows)} />
          <button className="btn small primary" type="button" onClick={() => setEdit({ kind: 'visit', subject: '', due_at: '', done: true, outcome: '', customer_id: data?.customers[0]?.id || '' })}>Log visit or call</button></>}>{table}</Panel>}
    {edit && <FormModal title={edit.id ? 'Edit activity' : 'New activity'} busy={act.busy} onClose={() => { setEdit(null); loc.reset(); }} onSave={save}>
      <div className="grid-form">
        <Select label="Type" id="av-kind" value={edit.kind} onChange={v => setEdit({ ...edit, kind: v })} options={KINDS} />
        <Field label="When (or due)" id="av-due" type="datetime-local" value={edit.due_at} onChange={v => setEdit({ ...edit, due_at: v })} />
        {!compact && !filter && <Select label="Customer" id="av-cust" value={edit.customer_id} onChange={v => setEdit({ ...edit, customer_id: v })} options={[['', '—'], ...(data?.customers || []).map(c => [c.id, c.name] as [string, string])]} />}
      </div>
      <Field label="Subject" id="av-subj" value={edit.subject} onChange={v => setEdit({ ...edit, subject: v })} placeholder="e.g. Delivered samples, met the buyer" required />
      <Field label="Outcome / next step" id="av-out" type="textarea" value={edit.outcome} onChange={v => setEdit({ ...edit, outcome: v })} />
      <label className="check"><input type="checkbox" checked={edit.done} onChange={e => setEdit({ ...edit, done: e.target.checked })} /> Done</label>
      {edit.kind === 'visit' && <div className="actions"><button className="btn small" type="button" onClick={loc.get}>Check in with my location</button>
        <span className="muted" style={{ fontSize: 13 }}>{loc.pos ? `Location captured: ${loc.pos.latitude}, ${loc.pos.longitude}` : loc.msg}</span></div>}
    </FormModal>}
  </>;
}

export function ActivitiesPage() {
  const { cid } = useSession();
  const { data: team } = useTeam(cid);
  return <>
    <PageHead title="Activities and field visits" sub="Calls, visits and follow-ups. On a phone, Check in records where a field visit happened." />
    <ActivityList cid={cid} team={team} />
  </>;
}

const MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];

export function SalesPerformancePage() {
  const { cid, company, can } = useSession();
  const act = useAction();
  const [ym, setYm] = useState(today().slice(0, 7));
  const [targets, setTargets] = useState<Record<string, string> | null>(null);
  const [terr, setTerr] = useState(false);
  const [y, m] = ym.split('-').map(Number);
  const { data, error, loading, reload } = useLoad(() => rpc<any[]>('sales_performance', { cid, p_year: y, p_month: m }), [cid, ym]);
  const { data: forecast } = useLoad(() => rpc<any[]>('sales_forecast', { cid, p_from: ym + '-01', p_months: 6 }), [cid, ym]);
  const { data: territories, reload: reloadT } = useLoad(() => q<any[]>(supabase.from('sales_territories').select('*').eq('company_id', cid).order('name') as any), [cid]);
  const [newTerr, setNewTerr] = useState({ name: '', region: '' });
  const pct = (r: any) => (Number(r.target) ? Math.round(Number(r.invoiced) / Number(r.target) * 100) : null);
  const head = ['Sales rep', 'Target (GHS)', 'Invoiced (GHS)', '% of target', 'Open pipeline', 'Weighted pipeline', 'Won', 'Lost', 'Activities done', 'Field visits'];
  const rows = (data || []).map(r => [r.email, money(r.target), money(r.invoiced), pct(r) == null ? '—' : pct(r) + '%', money(r.pipeline), money(r.weighted), String(r.won), String(r.lost), String(r.activities_done), String(r.visits)]);
  const tot = (k: string) => (data || []).reduce((s, r) => s + Number(r[k]), 0);

  return <>
    <PageHead title="Sales performance" sub="Targets against invoiced sales (net of credit notes), pipeline and field activity per rep.">
      <div className="field" style={{ width: 170 }}><label htmlFor="sp-month">Month</label><input id="sp-month" type="month" value={ym} onChange={e => setYm(e.target.value)} /></div>
      <div style={{ alignSelf: 'end' }} className="actions">
        <Downloads pdf={() => tablePdf({ company: company!, title: 'Sales performance', subtitle: `${MONTHS[m - 1]} ${y}`, head, body: rows, rightAlign: [1, 2, 3, 4, 5, 6, 7, 8, 9], landscape: true, filename: `sales-performance-${ym}`,
          foot: ['Team', money(tot('target')), money(tot('invoiced')), tot('target') ? Math.round(tot('invoiced') / tot('target') * 100) + '%' : '—', money(tot('pipeline')), money(tot('weighted')), String(tot('won')), String(tot('lost')), String(tot('activities_done')), String(tot('visits'))] })}
          csv={() => downloadCsv(`sales-performance-${ym}`, head, rows)} />
        {can('accountant') && <><button className="btn" type="button" onClick={() => setTerr(true)}>Territories</button>
          <button className="btn primary" type="button" onClick={() => setTargets(Object.fromEntries((data || []).map(r => [r.user_id, String(Number(r.target) || '')])))}>Set targets</button></>}
      </div>
    </PageHead>
    <Loading error={error} loading={loading && !data} />
    {data && <Panel>{data.length ? <div className="scroll"><table>
      <thead><tr><th>Rep</th><th className="r">Target</th><th className="r">Invoiced (GH₵)</th><th style={{ width: 160 }}>Achieved</th><th className="r">Weighted pipeline</th><th className="r">Won / lost</th><th className="r">Activities</th><th className="r">Visits</th></tr></thead>
      <tbody>{data.map(r => { const p = pct(r); return <tr key={r.user_id}>
        <td>{r.email}</td><td className="r num">{money(r.target)}</td><td className="r num">{money(r.invoiced)}</td>
        <td>{p == null ? <span className="muted">No target</span> : <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
          <div style={{ flex: 1, height: 8, background: 'var(--sunk)', borderRadius: 4, overflow: 'hidden' }}><div style={{ width: Math.min(p, 100) + '%', height: '100%', background: p >= 100 ? 'var(--good)' : p >= 60 ? 'var(--warn)' : 'var(--bad)' }} /></div>
          <span className="num" style={{ fontSize: 12 }}>{p}%</span></div>}</td>
        <td className="r num">{money(r.weighted)}</td><td className="r num">{r.won} / {r.lost}</td><td className="r num">{r.activities_done}</td><td className="r num">{r.visits}</td></tr>; })}</tbody>
    </table></div> : <Empty>No team members yet.</Empty>}</Panel>}
    {forecast && <Panel title="Forecast: next six months (GH₵, excl. VAT)" actions={<Downloads csv={() => downloadCsv(`sales-forecast-${ym}`, ['Month', 'Quota', 'Invoiced', 'Won deals', 'Commit', 'Weighted pipeline', 'Best case'],
        forecast.map(f => [f.month.slice(0, 7), money(f.quota), money(f.invoiced), money(f.won), money(f.commit_value), money(f.weighted), money(f.best_case)]))} />}>
      <div className="scroll"><table>
        <thead><tr><th>Month</th><th className="r">Quota</th><th className="r">Invoiced</th><th className="r">Won deals</th><th className="r">Commit</th><th className="r">Weighted</th><th className="r">Best case</th><th className="r">Gap to quota</th></tr></thead>
        <tbody>{forecast.map(f => { const gap = Number(f.quota) - Number(f.invoiced) - Number(f.weighted); return <tr key={f.month}>
          <td>{MONTHS[Number(f.month.slice(5, 7)) - 1]} {f.month.slice(0, 4)}</td><td className="r num">{money(f.quota)}</td><td className="r num">{money(f.invoiced)}</td><td className="r num">{money(f.won)}</td>
          <td className="r num">{money(f.commit_value)}</td><td className="r num">{money(f.weighted)}</td><td className="r num">{money(f.best_case)}</td>
          <td className="r num" style={{ color: Number(f.quota) && gap > 0 ? 'var(--bad)' : 'var(--good)' }}>{Number(f.quota) ? money(Math.max(gap, 0)) : '—'}</td></tr>; })}</tbody>
      </table></div>
      <div className="body muted" style={{ fontSize: 13 }}>Commit = deals in negotiation expected to close that month. Weighted = open deals × probability. Best case = all open deals. Gap = quota less invoiced and weighted pipeline.</div>
    </Panel>}
    <p className="muted" style={{ margin: 0 }}>Invoices count for the person who created them. Pipeline is converted to GH₵ at today's rates under Settings.</p>

    {targets && data && <FormModal title={`Targets for ${MONTHS[m - 1]} ${y} (GH₵, excl. VAT)`} busy={act.busy} onClose={() => setTargets(null)}
      onSave={() => act.run(async () => {
        await q(supabase.from('sales_targets').upsert(Object.entries(targets).map(([user_id, v]) => ({ company_id: cid, user_id, year: y, month: m, amount: Number(v) || 0 }))) as any);
        setTargets(null); reload();
      }, 'Targets saved')}>
      {data.map(r => <Field key={r.user_id} label={r.email} id={'tg-' + r.user_id} type="number" step="100" min="0" value={targets[r.user_id] || ''} onChange={v => setTargets({ ...targets, [r.user_id]: v })} />)}
    </FormModal>}
    {terr && <FormModal title="Sales territories" submit="Add territory" busy={act.busy} onClose={() => setTerr(false)}
      onSave={() => act.run(async () => { await q(supabase.from('sales_territories').insert({ company_id: cid, name: newTerr.name, region: newTerr.region || null }) as any); setNewTerr({ name: '', region: '' }); reloadT(); }, 'Territory added')}>
      {(territories || []).length > 0 && <div className="scroll"><table><tbody>{territories!.map(t => <tr key={t.id}><td>{t.name}</td><td className="muted">{t.region}</td>
        <td className="r"><ConfirmButton className="btn small ghost" label="Remove" confirm="Remove?" onConfirm={() => act.run(async () => { await q(supabase.from('sales_territories').delete().eq('id', t.id) as any); reloadT(); })} /></td></tr>)}</tbody></table></div>}
      <div className="grid-form">
        <Field label="Territory" id="tr-name" value={newTerr.name} onChange={v => setNewTerr({ ...newTerr, name: v })} placeholder="e.g. Ashanti North" required />
        <Select label="Region" id="tr-region" value={newTerr.region} onChange={v => setNewTerr({ ...newTerr, region: v })} options={[['', '—'], ...['Greater Accra', 'Ashanti', 'Eastern', 'Western', 'Western North', 'Central', 'Volta', 'Oti', 'Northern', 'Savannah', 'North East', 'Upper East', 'Upper West', 'Bono', 'Bono East', 'Ahafo'].map(r => [r, r] as [string, string])]} />
      </div>
      <p className="muted" style={{ margin: 0, fontSize: 13 }}>Assign customers to territories and owners on the Customers page.</p>
    </FormModal>}
  </>;
}
