import { ApprovalRulesPanel, DevelopersPanel, DimensionsPanel } from './AdminPanels';
import { useState } from 'react';
import { q, rpc, supabase } from '../lib/supabase';
import { useSession } from '../lib/session';
import { ConfirmButton, Field, Loading, PageHead, Panel, Select, useAction, useLoad } from '../components/ui';
import { TeamAccess } from '../components/TeamAccess';

const ROLES: [string, string][] = [
  ['admin', 'Admin — everything, including team'],
  ['accountant', 'Accountant — books, bills, payroll, reports'],
  ['sales', 'Sales — customers, invoices, products'],
  ['hr', 'HR — employees, leave, payroll preparation'],
  ['project_manager', 'Project manager — runs the projects they manage: plan, budget, team, approvals, billing'],
  ['store', 'Storekeeper — items, warehouses, receiving goods, issues to projects, transfers and stock counts (no access to the books)'],
  ['staff', 'Staff — projects, timesheets, leave requests'],
];

export function SettingsPage() {
  const { cid, company, reload, session, can } = useSession();
  const act = useAction();
  const [f, setF] = useState<any>(company);
  const set = (k: string) => (v: string) => setF({ ...f, [k]: v });

  if (!can('accountant')) return <>
    <PageHead title="Team" sub="Invite staff to sign in with their work email." />
    {can('hr') && <TeamAccess roles={ROLES} />}
  </>;
  return <>
    <PageHead title="Settings & team" sub="Company details appear on every invoice, payslip and report." />
    {can() && <Panel title="Company details" pad>
      <form onSubmit={e => { e.preventDefault(); act.run(async () => {
        const { name, tin, address, city, phone, email, bank_details, momo_details } = f;
        await q(supabase.from('companies').update({ name, tin, address, city, phone, email, bank_details, momo_details, site_count_limit: Number(f.site_count_limit ?? 1000) || 0 }).eq('id', cid) as any);
        await reload();
      }, 'Company details saved'); }} style={{ display: 'grid', gap: 12 }}>
        <div className="grid-form">
          <Field label="Company name" id="s-name" value={f.name} onChange={set('name')} required />
          <Field label="TIN" id="s-tin" value={f.tin} onChange={set('tin')} />
          <Field label="Phone" id="s-phone" value={f.phone} onChange={set('phone')} />
          <Field label="Email" id="s-email" type="email" value={f.email} onChange={set('email')} />
          <Field label="Address or digital address" id="s-addr" value={f.address} onChange={set('address')} />
          <Field label="Town or city" id="s-city" value={f.city} onChange={set('city')} />
        </div>
        <div className="grid-form">
          <Field label="Bank details printed on invoices" id="s-bank" value={f.bank_details} onChange={set('bank_details')} placeholder="GCB Bank, Accra Main, A/C 1234567890" />
          <Field label="Mobile Money details printed on invoices" id="s-momo" value={f.momo_details} onChange={set('momo_details')} placeholder="MTN MoMo 024 000 0000, Adom Distributors" />
          <Field label="Site stocktake differences a project manager may approve (GH₵)" id="s-scl" type="number" step="1" min="0" value={f.site_count_limit ?? 1000} onChange={set('site_count_limit')} />
        </div>
        <div><button className="btn primary" type="submit" disabled={act.busy}>Save details</button></div>
      </form>
    </Panel>}
    <GroupPanel />
    <DimensionsPanel />
    <ApprovalRulesPanel />
    <CurrenciesPanel />
    <LockPanel />
    <DevelopersPanel />
    {can('hr') && <TeamAccess roles={ROLES} />}
  </>;
}

function CurrenciesPanel() {
  const { cid } = useSession();
  const act = useAction();
  const [add, setAdd] = useState({ code: '', name: '', rate: '' });
  const { data, reload } = useLoad(() => q<any[]>(supabase.from('currencies').select('*').eq('company_id', cid).order('code') as any), [cid]);
  return <Panel title="Foreign currencies">
    <div className="body muted" style={{ fontSize: 13 }}>Rates are GH₵ per 1 unit and fill in new documents automatically; you can still change the rate on each document. Books are always kept in GH₵.</div>
    {data && data.length > 0 && <div className="scroll"><table>
      <thead><tr><th>Code</th><th>Name</th><th className="r">GH₵ per unit</th><th>Updated</th><th></th></tr></thead>
      <tbody>{data.map(c => <tr key={c.code}><td className="num">{c.code}</td><td>{c.name}</td>
        <td className="r"><input aria-label={`Rate for ${c.code}`} type="number" step="0.000001" min="0.000001" defaultValue={c.rate} style={{ width: 130, textAlign: 'right' }}
          onBlur={e => { if (Number(e.target.value) > 0 && Number(e.target.value) !== Number(c.rate)) act.run(async () => { await q(supabase.from('currencies').update({ rate: Number(e.target.value), updated_at: new Date().toISOString() }).eq('company_id', cid).eq('code', c.code) as any); reload(); }, `${c.code} rate updated`); }} /></td>
        <td className="num">{c.updated_at.slice(0, 10)}</td>
        <td className="r"><ConfirmButton className="btn small ghost" label="Remove" confirm="Remove?" onConfirm={() => act.run(async () => { await q(supabase.from('currencies').delete().eq('company_id', cid).eq('code', c.code) as any); reload(); })} /></td></tr>)}</tbody>
    </table></div>}
    <form className="body grid-form" style={{ borderTop: '1px solid var(--line)' }} onSubmit={e => { e.preventDefault(); act.run(async () => {
      await q(supabase.from('currencies').insert({ company_id: cid, code: add.code.trim().toUpperCase(), name: add.name.trim(), rate: Number(add.rate) }) as any);
      setAdd({ code: '', name: '', rate: '' }); reload(); }, 'Currency added'); }}>
      <Field label="Code" id="cu-code" value={add.code} onChange={v => setAdd({ ...add, code: v })} placeholder="USD" required />
      <Field label="Name" id="cu-name" value={add.name} onChange={v => setAdd({ ...add, name: v })} placeholder="US dollar" required />
      <Field label="GH₵ per 1 unit" id="cu-rate" type="number" step="0.000001" min="0.000001" value={add.rate} onChange={v => setAdd({ ...add, rate: v })} required />
      <div className="field" style={{ alignSelf: 'end' }}><button className="btn primary" type="submit" disabled={act.busy}>Add currency</button></div>
    </form>
  </Panel>;
}

function LockPanel() {
  const { cid, company, reload, can } = useSession();
  const act = useAction();
  const [d, setD] = useState((company as any)?.locked_until || '');
  if (!can('accountant')) return null;
  return <Panel title="Lock the books" pad>
    <p className="muted" style={{ marginTop: 0 }}>After you file a VAT return or close a month, lock it so nothing can be posted on or before that date. {(company as any)?.locked_until ? `Currently locked up to ${(company as any).locked_until}.` : 'Nothing is locked yet.'}</p>
    <div className="filters">
      <Field label="Locked up to and including" id="lk-date" type="date" value={d} onChange={setD} />
      <button className="btn primary" type="button" style={{ marginBottom: 2 }} disabled={act.busy} onClick={() => act.run(async () => { await rpc('set_lock_date', { cid, p_date: d || null }); await reload(); }, d ? 'Books locked' : 'Lock removed')}>{d ? 'Save lock date' : 'Remove lock'}</button>
    </div>
  </Panel>;
}

function GroupPanel() {
  const { cid, companies, can } = useSession();
  const act = useAction();
  const [name, setName] = useState('');
  const [other, setOther] = useState('');
  const { data, reload } = useLoad(() => rpc<any[]>('group_companies', { cid }), [cid]);
  if (!can()) return null;
  const grouped = (data || []).length > 1;
  const candidates = companies.filter(c => (c.role === 'owner' || c.role === 'admin') && c.company.id !== cid && !(data || []).some(g => g.id === c.company.id));
  return <Panel title="Group of companies" pad>
    <p className="muted" style={{ marginTop: 0 }}>Link subsidiaries so managers can search and assign staff across them, and staff can log time on sister companies' projects. Each company keeps its own books.</p>
    {grouped && <div className="scroll"><table><tbody>{data!.map(g => <tr key={g.id}><td>{g.name}{g.is_current && <span className="muted"> (this company)</span>}</td><td className="muted">{g.city}</td></tr>)}</tbody></table></div>}
    <div className="filters" style={{ marginTop: 12 }}>
      {!grouped && <><Field label="Group name" id="gp-name" value={name} onChange={setName} placeholder="e.g. Adom Group" />
        <button className="btn" type="button" style={{ marginBottom: 2 }} disabled={!name || act.busy} onClick={() => act.run(async () => { await rpc('create_group', { cid, p_name: name }); reload(); }, 'Group created')}>Create group</button></>}
      {candidates.length > 0 && <><Select label="Add a company you administer" id="gp-other" value={other} onChange={setOther} options={[['', 'Choose…'], ...candidates.map(c => [c.company.id, c.company.name] as [string, string])]} />
        <button className="btn primary" type="button" style={{ marginBottom: 2 }} disabled={!other || act.busy} onClick={() => act.run(async () => {
          if (!grouped) { if (!name) throw new Error('Name the group first.'); await rpc('create_group', { cid, p_name: name }); }
          await rpc('join_group', { cid, p_other: other }); setOther(''); reload(); }, 'Company linked')}>Link company</button></>}
      {grouped && <ConfirmButton className="btn danger" label="Leave group" confirm="Remove this company from the group?" onConfirm={() => act.run(async () => { await rpc('leave_group', { cid }); reload(); }, 'Left the group')} />}
    </div>
    {!candidates.length && !grouped && <p className="muted" style={{ fontSize: 13, marginBottom: 0 }}>To link another company, create it from the sign-up screen with the same login (or ask its owner to make you an admin), then come back here.</p>}
  </Panel>;
}
