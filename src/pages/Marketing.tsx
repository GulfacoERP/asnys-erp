import { useState } from 'react';
import { Link } from 'react-router-dom';
import { q, rpc, supabase } from '../lib/supabase';
import { useSession } from '../lib/session';
import { cedis, money, monthStart, today } from '../lib/format';
import { downloadCsv } from '../lib/download';
import { tablePdf } from '../lib/pdf';
import { ConfirmButton, Downloads, Empty, Field, FormModal, Loading, PageHead, Panel, Select, Status, useAction, useLoad } from '../components/ui';

const CHANNELS: [string, string][] = [['whatsapp', 'WhatsApp'], ['sms', 'SMS'], ['email', 'Email'], ['radio', 'Radio'], ['tv', 'TV'], ['event', 'Event or trade fair'], ['social', 'Social media'], ['print', 'Print / flyers'], ['referral', 'Referral drive'], ['other', 'Other']];
const MON = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const mlabel = (d: string) => `${MON[Number(d.slice(5, 7)) - 1]} ${d.slice(2, 4)}`;

/** Tiny bar chart drawn with divs: one group per month, up to 3 series. */
function Bars({ rows, series }: { rows: any[]; series: { key: string; label: string; colour: string }[] }) {
  const max = Math.max(1, ...rows.flatMap(r => series.map(s => Number(r[s.key]) || 0)));
  return <div>
    <div style={{ display: 'flex', gap: 10, alignItems: 'flex-end', height: 150, padding: '8px 4px 0', overflowX: 'auto' }} role="img" aria-label={series.map(s => s.label).join(', ') + ' by month'}>
      {rows.map(r => <div key={r.month} style={{ flex: '1 0 44px', display: 'grid', gap: 4, justifyItems: 'center' }}>
        <div style={{ display: 'flex', gap: 2, alignItems: 'flex-end', height: 120 }}>
          {series.map(s => <div key={s.key} title={`${s.label}: ${money(r[s.key])}`} style={{ width: 10, height: Math.max(1, (Number(r[s.key]) || 0) / max * 120), background: s.colour, borderRadius: '3px 3px 0 0' }} />)}</div>
        <span className="muted" style={{ fontSize: 11 }}>{mlabel(r.month)}</span></div>)}
    </div>
    <div className="actions" style={{ fontSize: 12, marginTop: 6 }}>{series.map(s => <span key={s.key}><span style={{ display: 'inline-block', width: 10, height: 10, background: s.colour, borderRadius: 2, marginRight: 4 }} />{s.label}</span>)}</div>
  </div>;
}

// ---------------------------------------------------------------- CRM dashboard
export function CrmDashboard() {
  const { cid } = useSession();
  const back = (n: number) => { const d = new Date(); d.setUTCDate(1); d.setUTCMonth(d.getUTCMonth() - n); return d.toISOString().slice(0, 10); };
  const { data, error, loading } = useLoad(async () => {
    const now = new Date();
    const [forecast, service, campaigns, perf, leads, cases] = await Promise.all([
      rpc<any[]>('sales_forecast', { cid, p_from: back(5), p_months: 9 }),
      rpc<any[]>('service_metrics', { cid, p_months: 6 }),
      rpc<any[]>('campaign_results', { cid }),
      rpc<any[]>('sales_performance', { cid, p_year: now.getFullYear(), p_month: now.getMonth() + 1 }),
      q<any[]>(supabase.from('leads').select('id,status,sales_ready,score').eq('company_id', cid).neq('status', 'converted') as any),
      q<any[]>(supabase.from('support_cases').select('id,status,priority').eq('company_id', cid).not('status', 'in', '(resolved,closed)') as any),
    ]);
    return { forecast, service, campaigns, perf, leads, cases };
  }, [cid]);
  if (!data) return <Loading error={error} loading={loading} />;
  const thisMonth = data.forecast.find(f => f.month === monthStart(today())) || {};
  const ahead = data.forecast.filter(f => f.month >= monthStart(today()));
  const svc = data.service[data.service.length - 1] || {};
  const team = data.perf.reduce((a, r) => ({ target: a.target + Number(r.target), invoiced: a.invoiced + Number(r.invoiced), visits: a.visits + Number(r.visits), acts: a.acts + Number(r.activities_done) }), { target: 0, invoiced: 0, visits: 0, acts: 0 });
  return <>
    <PageHead title="CRM dashboard" sub="Sales, marketing and customer service at a glance. Money in GH₵ excluding VAT.">
      <Link className="btn" to="/crm">Pipeline</Link><Link className="btn" to="/cases">Cases</Link>
    </PageHead>
    <div className="tiles">
      <div className="tile"><span>Invoiced this month</span><b>{cedis(team.invoiced)}</b>{team.target > 0 && <span className="muted" style={{ fontSize: 12 }}>{Math.round(team.invoiced / team.target * 100)}% of {money(team.target)} target</span>}</div>
      <div className="tile"><span>Commit this month</span><b>{cedis(thisMonth.commit_value)}</b><span className="muted" style={{ fontSize: 12 }}>deals in negotiation</span></div>
      <div className="tile"><span>Weighted pipeline (next 3 months)</span><b>{cedis(ahead.slice(0, 3).reduce((s, f) => s + Number(f.weighted), 0))}</b></div>
      <div className="tile"><span>Sales-ready leads</span><b>{data.leads.filter(l => l.sales_ready).length}</b><span className="muted" style={{ fontSize: 12 }}>of {data.leads.length} open leads</span></div>
      <div className="tile"><span>Open cases</span><b>{data.cases.length}</b><span className="muted" style={{ fontSize: 12 }}>{data.cases.filter(c => ['high', 'urgent'].includes(c.priority)).length} high priority</span></div>
      <div className="tile"><span>Customer rating (this month)</span><b>{svc.csat != null ? `${svc.csat} / 5` : '—'}</b></div>
    </div>
    <div className="two">
      <Panel title="Sales: quota, invoiced and pipeline by month" pad>
        <Bars rows={data.forecast} series={[{ key: 'quota', label: 'Quota', colour: 'var(--line-strong, #9aa3ad)' }, { key: 'invoiced', label: 'Invoiced', colour: 'var(--accent)' }, { key: 'weighted', label: 'Weighted pipeline', colour: 'var(--warn)' }]} />
      </Panel>
      <Panel title="Service: cases opened and resolved" pad>
        <Bars rows={data.service} series={[{ key: 'opened', label: 'Opened', colour: 'var(--warn)' }, { key: 'resolved', label: 'Resolved', colour: 'var(--good)' }]} />
        <p className="muted" style={{ fontSize: 13, marginBottom: 0 }}>This month: first reply in {svc.avg_hours_first_response ?? '—'} h on average, resolved in {svc.avg_hours_to_resolve ?? '—'} h.</p>
      </Panel>
    </div>
    <div className="two">
      <Panel title="Sales team this month" actions={<Link className="btn small" to="/sales-performance">Details</Link>}>{data.perf.length ? <div className="scroll"><table>
        <thead><tr><th>Rep</th><th className="r">Invoiced</th><th className="r">Target</th><th className="r">Visits</th></tr></thead>
        <tbody>{data.perf.map(r => <tr key={r.user_id}><td>{r.email.split('@')[0]}</td><td className="r num">{money(r.invoiced)}</td><td className="r num">{money(r.target)}</td><td className="r num">{r.visits}</td></tr>)}</tbody>
      </table></div> : <Empty>No reps.</Empty>}</Panel>
      <Panel title="Marketing campaigns" actions={<Link className="btn small" to="/campaigns">All campaigns</Link>}>{data.campaigns.length ? <div className="scroll"><table>
        <thead><tr><th>Campaign</th><th className="r">Leads</th><th className="r">Won (GH₵)</th><th className="r">ROI</th></tr></thead>
        <tbody>{data.campaigns.slice(0, 6).map(c => <tr key={c.campaign_id}><td>{c.name}</td><td className="r num">{c.leads}</td><td className="r num">{money(c.won_value)}</td>
          <td className="r num" style={{ color: Number(c.roi_pct) < 0 ? 'var(--bad)' : undefined }}>{c.roi_pct != null ? c.roi_pct + '%' : '—'}</td></tr>)}</tbody>
      </table></div> : <Empty>No campaigns yet.</Empty>}</Panel>
    </div>
  </>;
}

// ---------------------------------------------------------------- Campaigns
export function CampaignsPage() {
  const { cid, company, can, reload: reloadSession } = useSession();
  const act = useAction();
  const [edit, setEdit] = useState<any | null>(null);
  const [threshold, setThreshold] = useState<string | null>(null);
  const { data, error, loading, reload } = useLoad(async () => {
    const [results, rows] = await Promise.all([rpc<any[]>('campaign_results', { cid }), q<any[]>(supabase.from('campaigns').select('*').eq('company_id', cid) as any)]);
    return { results, rows };
  }, [cid]);
  const head = ['Campaign', 'Channel', 'Status', 'Cost (GHS)', 'Leads', 'Sales-ready', 'Converted', 'Deals', 'Won', 'Won value (GHS)', 'Cost per lead', 'ROI %'];
  const body = (data?.results || []).map(c => [c.name, c.channel, c.status, money(c.cost), String(c.leads), String(c.sales_ready), String(c.converted), String(c.opportunities), String(c.won), money(c.won_value), c.cost_per_lead != null ? money(c.cost_per_lead) : '', c.roi_pct != null ? String(c.roi_pct) : '']);
  const audience = (c: any) => act.run(async () => {
    const leads = await q<any[]>(supabase.from('leads').select('name,organisation,phone,email,city,status,score').eq('campaign_id', c.campaign_id).order('score', { ascending: false }) as any);
    downloadCsv(`campaign-${c.name}-leads`, ['Name', 'Organisation', 'Phone', 'Email', 'Town', 'Status', 'Score'], leads.map(l => [l.name, l.organisation || '', l.phone || '', l.email || '', l.city || '', l.status, String(l.score)]));
  });

  return <>
    <PageHead title="Marketing campaigns" sub={`Tag leads and deals with a campaign to see what each one brings in. A lead is sales-ready at a score of ${company?.lead_ready_score ?? 50} or more.`}>
      <Downloads pdf={() => tablePdf({ company: company!, title: 'Campaign results', subtitle: today(), head, body, rightAlign: [3, 4, 5, 6, 7, 8, 9, 10, 11], landscape: true, filename: 'campaign-results' })} csv={() => downloadCsv('campaign-results', head, body)} />
      {can('admin') && <button className="btn" type="button" onClick={() => setThreshold(String(company?.lead_ready_score ?? 50))}>Lead scoring</button>}
      <button className="btn primary" type="button" onClick={() => setEdit({ name: '', channel: 'whatsapp', status: 'planned', start_date: today(), end_date: '', budget: '', actual_cost: '', audience: '', description: '' })}>New campaign</button>
    </PageHead>
    <Loading error={error} loading={loading && !data} />
    {data && <Panel>{data.results.length ? <div className="scroll"><table>
      <thead><tr><th>Campaign</th><th className="r">Cost</th><th className="r">Leads</th><th className="r">Sales-ready</th><th className="r">Won</th><th className="r">Won value</th><th className="r">Cost / lead</th><th className="r">ROI</th><th></th></tr></thead>
      <tbody>{data.results.map(c => <tr key={c.campaign_id}>
        <td><button className="btn ghost small" type="button" style={{ padding: 0, fontWeight: 600 }} onClick={() => { const r = data.rows.find(x => x.id === c.campaign_id); setEdit(Object.fromEntries(Object.entries(r).map(([k, v]) => [k, v ?? '']))); }}>{c.name}</button>
          <br /><span className="muted">{CHANNELS.find(x => x[0] === c.channel)?.[1]}</span> <Status s={c.status} /></td>
        <td className="r num">{money(c.cost)}</td><td className="r num">{c.leads}</td><td className="r num">{c.sales_ready}</td><td className="r num">{c.won}</td><td className="r num">{money(c.won_value)}</td>
        <td className="r num">{c.cost_per_lead != null ? money(c.cost_per_lead) : '—'}</td>
        <td className="r num" style={{ color: Number(c.roi_pct) < 0 ? 'var(--bad)' : Number(c.roi_pct) > 0 ? 'var(--good)' : undefined }}>{c.roi_pct != null ? c.roi_pct + '%' : '—'}</td>
        <td className="r"><button className="btn small" type="button" disabled={!c.leads} onClick={() => audience(c)}>Leads CSV</button></td></tr>)}</tbody>
    </table></div> : <Empty>No campaigns yet. Create one for each radio slot, WhatsApp blast, flyer run or trade fair.</Empty>}</Panel>}
    <Panel title="How lead scores work" pad>
      <p className="muted" style={{ margin: 0, fontSize: 13 }}>Out of 100: phone 10, email 10, organisation 10; estimated value from GH₵5,000 = 10, 20,000 = 20, 100,000 = 30; source referral 15, event or walk-in 10, website 5; came through a partner 10; contacted 5, qualified 20; each completed call or visit 5 (up to 20). Scores update automatically.</p>
    </Panel>
    {edit && <FormModal title={edit.id ? 'Edit campaign' : 'New campaign'} busy={act.busy} onClose={() => setEdit(null)}
      danger={edit.id && <ConfirmButton className="btn danger" label="Delete" confirm="Delete campaign? Leads keep their data." onConfirm={() => act.run(async () => { await q(supabase.from('campaigns').delete().eq('id', edit.id) as any); setEdit(null); reload(); })} />}
      onSave={() => act.run(async () => {
        const row = { name: edit.name, channel: edit.channel, status: edit.status, start_date: edit.start_date || null, end_date: edit.end_date || null, budget: Number(edit.budget) || 0, actual_cost: Number(edit.actual_cost) || 0, audience: edit.audience || null, description: edit.description || null };
        if (edit.id) await q(supabase.from('campaigns').update(row).eq('id', edit.id) as any); else await q(supabase.from('campaigns').insert({ ...row, company_id: cid }) as any);
        setEdit(null); reload();
      }, 'Campaign saved')}>
      <Field label="Campaign name" id="cp-name" value={edit.name} onChange={v => setEdit({ ...edit, name: v })} placeholder="e.g. Adom FM breakfast show — November" required />
      <div className="grid-form">
        <Select label="Channel" id="cp-ch" value={edit.channel} onChange={v => setEdit({ ...edit, channel: v })} options={CHANNELS} />
        <Select label="Status" id="cp-st" value={edit.status} onChange={v => setEdit({ ...edit, status: v })} options={[['planned', 'Planned'], ['active', 'Running'], ['completed', 'Completed']]} />
        <Field label="Start" id="cp-start" type="date" value={edit.start_date} onChange={v => setEdit({ ...edit, start_date: v })} />
        <Field label="End" id="cp-end" type="date" value={edit.end_date} onChange={v => setEdit({ ...edit, end_date: v })} />
        <Field label="Budget (GH₵)" id="cp-bud" type="number" step="0.01" min="0" value={edit.budget} onChange={v => setEdit({ ...edit, budget: v })} />
        <Field label="Actual cost so far (GH₵)" id="cp-cost" type="number" step="0.01" min="0" value={edit.actual_cost} onChange={v => setEdit({ ...edit, actual_cost: v })} />
      </div>
      <Field label="Target audience" id="cp-aud" value={edit.audience} onChange={v => setEdit({ ...edit, audience: v })} placeholder="e.g. Provision shops in Kumasi" />
      <Field label="Message and offer" id="cp-desc" type="textarea" value={edit.description} onChange={v => setEdit({ ...edit, description: v })} />
    </FormModal>}
    {threshold != null && <FormModal title="Lead scoring" busy={act.busy} onClose={() => setThreshold(null)}
      onSave={() => act.run(async () => { await q(supabase.from('companies').update({ lead_ready_score: Number(threshold) }).eq('id', cid) as any); await reloadSession(); setThreshold(null); reload(); }, 'Saved')}>
      <Field label="A lead is sales-ready from this score" id="ls-th" type="number" step="5" min="0" max="100" value={threshold} onChange={setThreshold} required />
      <p className="muted" style={{ margin: 0, fontSize: 13 }}>Sales-ready leads are flagged on the Leads list so reps call them first.</p>
    </FormModal>}
  </>;
}

// ---------------------------------------------------------------- Partners
export function PartnersPage() {
  const { cid, company } = useSession();
  const act = useAction();
  const [edit, setEdit] = useState<any | null>(null);
  const { data, error, loading, reload } = useLoad(async () => {
    const [partners, leads, customers, report] = await Promise.all([
      q<any[]>(supabase.from('partners').select('*').eq('company_id', cid).order('name') as any),
      q<any[]>(supabase.from('leads').select('partner_id,status').eq('company_id', cid).not('partner_id', 'is', null) as any),
      q<any[]>(supabase.from('customers').select('partner_id').eq('company_id', cid).not('partner_id', 'is', null) as any),
      rpc<any[]>('commission_report', { cid, p_from: today().slice(0, 4) + '-01-01', p_to: today() }).catch(() => [] as any[]),
    ]);
    return { partners, leads, customers, report };
  }, [cid]);
  const count = (arr: any[], id: string) => arr.filter(x => x.partner_id === id).length;
  const ytd = (id: string) => data?.report.find(r => r.kind === 'partner' && r.ref_id === id);
  const head = ['Partner', 'Type', 'Contact', 'Phone', 'Town', 'Commission %', 'Leads', 'Customers', 'Sales YTD (GHS)', 'Commission YTD'];
  const body = (data?.partners || []).map(p => [p.name, p.kind, p.contact_name || '', p.phone || '', p.city || '', String(Number(p.commission_rate) * 100), String(count(data!.leads, p.id)), String(count(data!.customers, p.id)), money(ytd(p.id)?.base || 0), money(ytd(p.id)?.commission || 0)]);
  return <>
    <PageHead title="Partners and resellers" sub="Agents, resellers and referrers who bring you business. Link them to leads and customers; their commission is worked out from invoices.">
      <Downloads pdf={() => tablePdf({ company: company!, title: 'Partners', head, body, rightAlign: [5, 6, 7, 8, 9], landscape: true, filename: 'partners' })} csv={() => downloadCsv('partners', head, body)} />
      <Link className="btn" to="/commissions">Commissions</Link>
      <button className="btn primary" type="button" onClick={() => setEdit({ name: '', kind: 'reseller', contact_name: '', phone: '', email: '', city: '', commission_rate: '', active: true, notes: '' })}>Add partner</button>
    </PageHead>
    <Loading error={error} loading={loading && !data} />
    {data && <Panel>{data.partners.length ? <div className="scroll"><table>
      <thead><tr><th>Partner</th><th>Contact</th><th className="r">Commission</th><th className="r">Leads</th><th className="r">Customers</th><th className="r">Sales this year</th><th className="r">Earned this year</th></tr></thead>
      <tbody>{data.partners.map(p => <tr key={p.id} style={p.active ? undefined : { opacity: .6 }}>
        <td><button className="btn ghost small" type="button" style={{ padding: 0, fontWeight: 600 }} onClick={() => setEdit({ ...Object.fromEntries(Object.entries(p).map(([k, v]) => [k, v ?? ''])), commission_rate: String(Math.round(Number(p.commission_rate) * 10000) / 100), active: p.active })}>{p.name}</button>
          <br /><span className="muted">{p.kind}{p.city ? ' · ' + p.city : ''}</span></td>
        <td>{p.contact_name}<br /><span className="muted num">{p.phone}</span></td>
        <td className="r num">{Math.round(Number(p.commission_rate) * 10000) / 100}%</td><td className="r num">{count(data.leads, p.id)}</td><td className="r num">{count(data.customers, p.id)}</td>
        <td className="r num">{money(ytd(p.id)?.base || 0)}</td><td className="r num">{money(ytd(p.id)?.commission || 0)}</td></tr>)}</tbody>
    </table></div> : <Empty>No partners yet.</Empty>}</Panel>}
    {edit && <FormModal title={edit.id ? 'Edit partner' : 'Add partner'} busy={act.busy} onClose={() => setEdit(null)}
      danger={edit.id && <ConfirmButton className="btn danger" label="Delete" confirm="Delete partner?" onConfirm={() => act.run(async () => { await q(supabase.from('partners').delete().eq('id', edit.id) as any); setEdit(null); reload(); })} />}
      onSave={() => act.run(async () => {
        const rate = Number(edit.commission_rate) / 100;
        if (!(rate >= 0 && rate <= 1)) throw new Error('Commission must be between 0 and 100%.');
        const row = { name: edit.name, kind: edit.kind, contact_name: edit.contact_name || null, phone: edit.phone || null, email: edit.email || null, city: edit.city || null, commission_rate: rate, active: edit.active, notes: edit.notes || null };
        if (edit.id) await q(supabase.from('partners').update(row).eq('id', edit.id) as any); else await q(supabase.from('partners').insert({ ...row, company_id: cid }) as any);
        setEdit(null); reload();
      }, 'Partner saved')}>
      <Field label="Partner name" id="pt-name" value={edit.name} onChange={v => setEdit({ ...edit, name: v })} required />
      <div className="grid-form">
        <Select label="Type" id="pt-kind" value={edit.kind} onChange={v => setEdit({ ...edit, kind: v })} options={[['reseller', 'Reseller'], ['agent', 'Sales agent'], ['referrer', 'Referrer'], ['distributor', 'Distributor']]} />
        <Field label="Commission % of sales (excl. VAT)" id="pt-rate" type="number" step="0.5" min="0" max="100" value={edit.commission_rate} onChange={v => setEdit({ ...edit, commission_rate: v })} />
        <Field label="Contact person" id="pt-contact" value={edit.contact_name} onChange={v => setEdit({ ...edit, contact_name: v })} />
        <Field label="Phone" id="pt-phone" value={edit.phone} onChange={v => setEdit({ ...edit, phone: v })} />
        <Field label="Email" id="pt-email" type="email" value={edit.email} onChange={v => setEdit({ ...edit, email: v })} />
        <Field label="Town" id="pt-city" value={edit.city} onChange={v => setEdit({ ...edit, city: v })} />
      </div>
      <label className="check"><input type="checkbox" checked={edit.active} onChange={e => setEdit({ ...edit, active: e.target.checked })} /> Active</label>
      <Field label="Notes" id="pt-notes" type="textarea" value={edit.notes} onChange={v => setEdit({ ...edit, notes: v })} />
    </FormModal>}
  </>;
}

// ---------------------------------------------------------------- Commissions
export function CommissionsPage() {
  const { cid, company, can } = useSession();
  const act = useAction();
  const [range, setRange] = useState({ from: monthStart(today()), to: today() });
  const [rates, setRates] = useState<Record<string, string> | null>(null);
  const [post, setPost] = useState<string | null>(null);
  const acct = can('accountant');
  const { data, error, loading, reload } = useLoad(async () => {
    const [report, team, rateRows, runs] = await Promise.all([
      rpc<any[]>('commission_report', { cid, p_from: range.from, p_to: range.to }),
      q<any[]>(supabase.from('memberships').select('user_id,email,role').eq('company_id', cid).order('email') as any),
      q<any[]>(supabase.from('sales_commission_rates').select('*').eq('company_id', cid) as any),
      acct ? q<any[]>(supabase.from('commission_runs').select('*').eq('company_id', cid).order('period_to', { ascending: false }) as any) : Promise.resolve([]),
    ]);
    return { report, team, rateRows, runs };
  }, [cid, range.from, range.to]);
  const total = (data?.report || []).reduce((s, r) => s + Number(r.commission), 0);
  const head = ['Type', 'Name', 'Net sales (GHS)', 'Rate %', 'Commission (GHS)'];
  const body = (data?.report || []).map(r => [r.kind === 'rep' ? 'Sales rep' : 'Partner', r.name, money(r.base), String(Number(r.rate) * 100), money(r.commission)]);
  return <>
    <PageHead title="Sales commissions" sub="Commission on invoiced sales excluding VAT, less credit notes, for each rep (the person who raised the invoice) and each partner.">
      <Downloads pdf={() => tablePdf({ company: company!, title: 'Commission statement', subtitle: `${range.from} to ${range.to}`, head, body, foot: ['', 'Total', '', '', money(total)], rightAlign: [2, 3, 4], filename: `commissions-${range.from}-${range.to}` })} csv={() => downloadCsv(`commissions-${range.from}-${range.to}`, head, body)} />
      {acct && <><button className="btn" type="button" onClick={() => setRates(Object.fromEntries((data?.team || []).map(t => [t.user_id, String(Number(data!.rateRows.find(r => r.user_id === t.user_id)?.rate || 0) * 100)])))}>Rep rates</button>
        <button className="btn primary" type="button" disabled={total <= 0} onClick={() => setPost(range.to)}>Post accrual</button></>}
    </PageHead>
    <Panel pad><div className="filters">
      <Field label="From" id="cm-from" type="date" value={range.from} onChange={v => setRange({ ...range, from: v })} />
      <Field label="To" id="cm-to" type="date" value={range.to} onChange={v => setRange({ ...range, to: v })} />
    </div></Panel>
    <Loading error={error} loading={loading && !data} />
    {data && <Panel>{data.report.length ? <div className="scroll"><table>
      <thead><tr><th>Who</th><th className="r">Net sales (GH₵)</th><th className="r">Rate</th><th className="r">Commission</th></tr></thead>
      <tbody>{data.report.map(r => <tr key={r.kind + r.ref_id}><td>{r.name} <span className="pill">{r.kind === 'rep' ? 'Rep' : 'Partner'}</span></td><td className="r num">{money(r.base)}</td><td className="r num">{Math.round(Number(r.rate) * 10000) / 100}%</td><td className="r num">{money(r.commission)}</td></tr>)}</tbody>
      <tfoot><tr><td colSpan={3}>Total</td><td className="r num">{money(total)}</td></tr></tfoot>
    </table></div> : <Empty>No commissionable sales in this period. Set rep rates here and partner rates on the Partners page.</Empty>}</Panel>}
    {acct && data && data.runs.length > 0 && <Panel title="Posted commission accruals"><div className="scroll"><table>
      <thead><tr><th>Period</th><th className="r">Total (GH₵)</th><th>Posted</th></tr></thead>
      <tbody>{data.runs.map(r => <tr key={r.id}><td className="num">{r.period_from} → {r.period_to}</td><td className="r num">{money(r.total)}</td><td className="num">{r.created_at.slice(0, 10)}</td></tr>)}</tbody>
    </table></div></Panel>}
    {rates && data && <FormModal title="Commission rates for sales reps (% of net sales)" busy={act.busy} onClose={() => setRates(null)}
      onSave={() => act.run(async () => {
        await q(supabase.from('sales_commission_rates').upsert(Object.entries(rates).map(([user_id, v]) => ({ company_id: cid, user_id, rate: Math.min(Math.max(Number(v) || 0, 0), 100) / 100 }))) as any);
        setRates(null); reload();
      }, 'Rates saved')}>
      {data.team.map(t => <Field key={t.user_id} label={`${t.email} (${t.role})`} id={'cr-' + t.user_id} type="number" step="0.5" min="0" max="100" value={rates[t.user_id]} onChange={v => setRates({ ...rates, [t.user_id]: v })} />)}
    </FormModal>}
    {post && <FormModal title="Post commission accrual" submit={`Post ${cedis(total)}`} busy={act.busy} onClose={() => setPost(null)}
      onSave={() => act.run(async () => { await rpc('post_commissions', { cid, p_from: range.from, p_to: range.to, p_date: post }); setPost(null); reload(); }, 'Commission posted to the books')}>
      <p style={{ margin: 0 }}>Records {cedis(total)} for {range.from} to {range.to}: debit 6150 Sales commissions, credit 2250 Commissions payable. Pay reps through payroll (as a bonus) and partners as a supplier bill against 2250.</p>
      <Field label="Posting date" id="cm-date" type="date" value={post} onChange={setPost} required />
    </FormModal>}
  </>;
}
