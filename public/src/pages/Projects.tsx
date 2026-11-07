import { useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { q, rpc, supabase } from '../lib/supabase';
import { useSession } from '../lib/session';
import { cedis, longDate, money, today } from '../lib/format';
import { downloadCsv } from '../lib/download';
import { projectReportPdf, tablePdf } from '../lib/pdf';
import { ConfirmButton, Downloads, Empty, Field, FormModal, Loading, PageHead, Panel, Select, Status, useAction, useLoad } from '../components/ui';
import { amt, useCurrencies } from '../components/docs';
import { Gantt } from '../components/Gantt';
import { DimSelects, useDims } from '../components/dims';
import { ProjectPurchases } from '../components/ProjectPurchases';
import { ActivityList } from './CRM';
import { SiteStore } from '../components/SiteStore';
import { ContractPayments, FinanceControl, ProgressTab } from '../components/ProjectControl';
import { ProjectDocuments } from '../components/ProjectDocs';
import { ProjectLifecycle, ProjectMaterials, ScheduleBar, Stage, schedule } from '../components/ProjectLifecycle';

const BILLING: [string, string][] = [['time_materials', 'Time and materials'], ['fixed_price', 'Fixed price (milestones)'], ['non_billable', 'Internal / non-billable']];
const HEALTH: [string, string, string][] = [['on_track', 'On track', 'good'], ['at_risk', 'At risk', 'warn'], ['off_track', 'Off track', 'bad']];
const CATS: [string, string][] = [['labour', 'Labour'], ['expenses', 'Travel and expenses'], ['materials', 'Materials'], ['subcontract', 'Subcontractors'], ['equipment', 'Equipment hire'], ['other', 'Other expenses']];
const Health = ({ h }: { h: string }) => { const x = HEALTH.find(v => v[0] === h) || HEALTH[0]; return <span className={'pill ' + x[2]}>{x[1]}</span>; };
const Bar = ({ pct, colour }: { pct: number; colour?: string }) => <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
  <div style={{ flex: 1, minWidth: 60, height: 7, background: 'var(--sunk)', borderRadius: 4, overflow: 'hidden' }}>
    <div style={{ width: Math.max(0, Math.min(pct, 100)) + '%', height: '100%', background: colour || (pct > 100 ? 'var(--bad)' : 'var(--accent)') }} /></div>
  <span className="num" style={{ fontSize: 12 }}>{Math.round(pct)}%</span></div>;

function ProjectForm({ edit, setEdit, customers, currencies, team, onClose, onSave, busy }: any) {
  const set = (k: string) => (v: any) => setEdit({ ...edit, [k]: v });
  const { cid } = useSession();
  const { data: dims } = useDims(cid);
  return <FormModal title={edit.id ? (edit.is_template ? 'Edit template' : 'Edit project') : edit.is_template ? 'New template' : 'New project'} onClose={onClose} onSave={onSave} busy={busy}>
    <Field label={edit.is_template ? 'Template name' : 'Project name'} id="pj-name" value={edit.name} onChange={set('name')} required />
    <div className="grid-form">
      {!edit.is_template && <Select label="Client" id="pj-cust" value={edit.customer_id} onChange={set('customer_id')} options={[['', 'Internal project'], ...customers.map((c: any) => [c.id, c.name]), [NEW_CLIENT, '+ Add a new client…']]} />}
      {!edit.is_template && edit.customer_id === NEW_CLIENT && <>
        <Field label="New client name" id="pj-nc-name" value={edit.new_client_name || ''} onChange={set('new_client_name')} required placeholder="e.g. Ghana Grid Company Ltd" />
        <Field label="Client phone" id="pj-nc-phone" value={edit.new_client_phone || ''} onChange={set('new_client_phone')} />
        <Field label="Client email" id="pj-nc-email" type="email" value={edit.new_client_email || ''} onChange={set('new_client_email')} />
        <Field label="Client TIN" id="pj-nc-tin" value={edit.new_client_tin || ''} onChange={set('new_client_tin')} />
      </>}
      <Select label="Billing" id="pj-bill" value={edit.billing_type} onChange={set('billing_type')} options={BILLING} />
      {!edit.is_template && team && <Select label="Project manager" id="pj-pm" value={edit.manager_id || ''} onChange={set('manager_id')} options={[['', '—'], ...team.map((t: any) => [t.user_id, t.email])]} />}
      <Field label="Start" id="pj-start" type="date" value={edit.start_date} onChange={set('start_date')} />
      <Field label="Target end" id="pj-end" type="date" value={edit.end_date} onChange={set('end_date')} />
      <Select label="Bill the client in" id="pj-ccy" value={edit.currency} onChange={set('currency')} options={[['GHS', 'GHS — Ghana cedi'], ...(currencies || []).map((c: any) => [c.code, `${c.code} — ${c.name}`])]} />
      {edit.billing_type === 'fixed_price' && <Field label={`Contract value (${edit.currency}, excl. VAT)`} id="pj-contract" type="number" step="0.01" min="0" value={edit.contract_value} onChange={set('contract_value')} />}
      {edit.billing_type === 'time_materials' && <Field label={`Standard rate per hour (${edit.currency})`} id="pj-rate" type="number" step="0.01" min="0" value={edit.hourly_rate} onChange={set('hourly_rate')} />}
      <Field label="Where the work happens" id="pj-loc" value={edit.location} onChange={set('location')} placeholder="e.g. Lomé" />
      <Field label="Country" id="pj-country" value={edit.country} onChange={set('country')} />
      {!edit.is_template && <DimSelects dims={dims} branch={edit.branch_id || ''} centre={edit.cost_centre_id || ''} onChange={(b, c) => setEdit({ ...edit, branch_id: b, cost_centre_id: c })} idPrefix="pj" />}
    </div>
    <Field label="Description and scope" id="pj-desc" type="textarea" value={edit.description} onChange={set('description')} />
    {!edit.id && !edit.is_template && <label className="check"><input type="checkbox" checked={edit.status === 'active'} onChange={e => setEdit({ ...edit, status: e.target.checked ? 'active' : 'planned' })} /> Work has already started (otherwise use Start project when it does)</label>}
  </FormModal>;
}

const NEW_CLIENT = '__new_client';
/** A client typed into the project form is saved as a customer first, so it shows on the project, quotes and invoices. */
async function withClient(e: any, cid: string) {
  if (e.customer_id !== NEW_CLIENT) return e;
  const name = (e.new_client_name || '').trim();
  if (!name) throw new Error('Enter the new client\'s name, or choose a client from the list');
  const c = await q<any>(supabase.from('customers').insert({ company_id: cid, name, phone: e.new_client_phone || null, email: e.new_client_email || null, tin: e.new_client_tin || null }).select('id').single() as any);
  return { ...e, customer_id: c.id };
}
const toRow = (e: any) => ({ name: e.name, customer_id: e.customer_id || null, ...(e.id ? {} : { status: e.status === 'active' ? 'active' : 'planned' }), start_date: e.start_date || null, end_date: e.end_date || null,
  hourly_rate: Number(e.hourly_rate) || 0, description: e.description || null, currency: e.currency || 'GHS', location: e.location || null, country: e.country || null,
  billing_type: e.billing_type, contract_value: Number(e.contract_value) || 0, is_template: !!e.is_template,
  branch_id: e.branch_id || null, cost_centre_id: e.cost_centre_id || null, ...(e.manager_id !== undefined ? { manager_id: e.manager_id || null } : {}) });
const blank = (tpl = false) => ({ name: '', customer_id: '', status: 'planned', start_date: today(), end_date: '', hourly_rate: '', description: '', currency: 'GHS', location: '', country: '',
  billing_type: 'time_materials', contract_value: '', is_template: tpl });

function useTeam(cid: string) {
  return useLoad(() => q<any[]>(supabase.from('memberships').select('user_id,email,role').eq('company_id', cid).order('email') as any), [cid]);
}

// ---------------------------------------------------------------- Project center (portfolio)
export function ProjectsPage() {
  const { cid, company, session, role } = useSession();
  const nav = useNavigate();
  const act = useAction();
  const [mine, setMine] = useState(role === 'project_manager');
  const [stage, setStage] = useState<'open' | 'planned' | 'active' | 'on_hold' | 'done' | 'closed' | 'all'>('open');
  const [tab, setTab] = useState<'projects' | 'templates'>('projects');
  const [edit, setEdit] = useState<any | null>(null);
  const [fromTpl, setFromTpl] = useState<any | null>(null);
  const { data: currencies } = useCurrencies(cid);
  const { data: team } = useTeam(cid);
  const { data, error, loading, reload } = useLoad(async () => {
    const [kpis, templates, customers, dates] = await Promise.all([
      rpc<any[]>('project_kpis', { cid }),
      q<any[]>(supabase.from('projects').select('*').eq('company_id', cid).eq('is_template', true).order('name') as any),
      q<any[]>(supabase.from('customers').select('id,name').eq('company_id', cid).order('name') as any),
      q<any[]>(supabase.from('projects').select('id,status,start_date,end_date,actual_start,actual_end').eq('company_id', cid).eq('is_template', false) as any),
    ]);
    return { kpis, templates, customers, dates };
  }, [cid]);
  const inStage = (k: any, st: string) => st === 'all' || (st === 'open' ? ['planned', 'active', 'on_hold', 'done'].includes(k.status) : st === 'closed' ? ['closed', 'cancelled'].includes(k.status) : k.status === st);
  const mineList = (data?.kpis || []).filter(k => !mine || k.manager_id === session?.user.id);
  const list = mineList.filter(k => inStage(k, stage));
  const projDates = (id: string) => data?.dates.find(d => d.id === id) || {};
  const sum = (f: string) => list.reduce((s, k) => s + Number(k[f] || 0), 0);
  const pmName = (id: string) => team?.find(t => t.user_id === id)?.email.split('@')[0] || '—';
  const head = ['No.', 'Project', 'Client', 'Manager', 'Billing', 'Health', '% complete', 'Budget cost', 'Actual cost', 'Committed', 'Forecast cost', 'Revenue (budget)', 'Invoiced', 'Unbilled', 'Forecast margin', 'Open issues', 'Overdue tasks'];
  const rows = list.map(k => [k.number || '', k.name, k.customer || 'Internal', pmName(k.manager_id), k.billing_type, k.health, String(k.pct_complete), money(k.budget_cost), money(k.actual_cost), money(k.committed_cost), money(k.eac_cost),
    money(k.budget_revenue), money(k.invoiced), money(k.unbilled), money(k.forecast_margin), String(k.open_issues), String(k.overdue_tasks)]);

  return <>
    <PageHead title="Project center" sub={data ? `${list.length} projects · budget revenue ${cedis(sum('budget_revenue'))} · invoiced ${cedis(sum('invoiced'))} · unbilled ${cedis(sum('unbilled'))} · forecast margin ${cedis(sum('forecast_margin'))}` : undefined}>
      <Downloads pdf={() => tablePdf({ company: company!, title: 'Project portfolio', subtitle: longDate(today()), head, body: rows, rightAlign: [6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16], landscape: true, filename: 'project-portfolio-' + today(),
        notes: 'Money in GH₵. Forecast cost = actual cost + remaining estimated hours at the average cost rate so far.' })} csv={() => downloadCsv('project-portfolio-' + today(), head, rows)} />
      <Link className="btn" to="/resources">Resource planner</Link>
      {data && data.templates.length > 0 && <button className="btn" type="button" onClick={() => setFromTpl({ template: data.templates[0].id, name: '', customer_id: '', start: today() })}>From template</button>}
      <button className="btn primary" type="button" onClick={() => setEdit(blank(tab === 'templates'))}>{tab === 'templates' ? 'New template' : 'New project'}</button>
    </PageHead>
    <div className="actions">
      <button type="button" className={'btn small' + (tab === 'projects' ? ' primary' : '')} onClick={() => setTab('projects')}>Projects</button>
      <button type="button" className={'btn small' + (tab === 'templates' ? ' primary' : '')} onClick={() => setTab('templates')}>Templates ({data?.templates.length || 0})</button>
      {tab === 'projects' && <label className="check" style={{ marginLeft: 8 }}><input type="checkbox" checked={mine} onChange={e => setMine(e.target.checked)} /> Only projects I manage</label>}
    </div>
    {tab === 'projects' && <div className="actions" style={{ overflowX: 'auto', flexWrap: 'nowrap' }}>{([['open', 'All open'], ['planned', 'Not started'], ['active', 'In progress'], ['on_hold', 'On hold'], ['done', 'Completed, to close'], ['closed', 'Closed'], ['all', 'Everything']] as const).map(([v, l]) =>
      <button key={v} type="button" className={'btn small' + (stage === v ? ' primary' : ' ghost')} onClick={() => setStage(v)}>{l} <span className="muted num">{mineList.filter(k => inStage(k, v)).length}</span></button>)}</div>}
    <Loading error={error} loading={loading && !data} />
    {data && tab === 'projects' && <Panel>{list.length ? <div className="scroll"><table>
      <thead><tr><th>Project</th><th>Stage</th><th>Health</th><th style={{ width: 150 }}>Progress vs schedule</th><th style={{ width: 140 }}>Spent + committed vs budget</th><th className="r">Invoiced (GH₵)</th><th className="r">Unbilled</th><th className="r">Forecast margin</th><th className="r">Issues</th></tr></thead>
      <tbody>{list.map(k => <tr key={k.project_id} className="click" tabIndex={0} onClick={() => nav('/projects/' + k.project_id)} onKeyDown={e => e.key === 'Enter' && nav('/projects/' + k.project_id)}>
        <td><b>{k.name}</b>{k.currency !== 'GHS' && <span className="pill" style={{ marginLeft: 6 }}>{k.currency}</span>}<br />
          <span className="muted num">{k.number}</span> <span className="muted">· {k.customer || 'Internal'} · {pmName(k.manager_id)}{k.overdue_tasks > 0 ? ` · ${k.overdue_tasks} overdue` : ''}</span></td>
        <td><Stage s={k.status} /></td>
        <td><Health h={k.health} /></td>
        <td>{(() => { const sc = schedule({ ...projDates(k.project_id), status: k.status }, Number(k.pct_complete)); return sc && !['done', 'closed'].includes(k.status)
          ? <><ScheduleBar planned={sc.planned} actual={sc.actual} /><span className={sc.tone === 'bad' ? '' : 'muted'} style={{ fontSize: 12, color: sc.tone === 'bad' ? 'var(--bad)' : undefined }}>{k.pct_complete}% · {sc.label}</span></>
          : <Bar pct={k.pct_complete} colour="var(--accent)" />; })()}</td>
        <td>{Number(k.budget_cost) > 0 ? <>{(() => { const used = Number(k.actual_cost) + Number(k.committed_cost), fc = Math.max(Number(k.eac_cost), used), b = Number(k.budget_cost);
            return <span title={`Spent ${money(k.actual_cost)}, committed ${money(k.committed_cost)}, forecast ${money(k.eac_cost)} of ${money(b)}`}><Bar pct={used / b * 100} colour={used > b ? 'var(--bad)' : fc > b ? 'var(--warn)' : 'var(--good)'} /></span>; })()}
          {k.pending_requests > 0 && <span className="muted" style={{ fontSize: 12 }}>{k.pending_requests} request{k.pending_requests > 1 ? 's' : ''} to approve</span>}</> : <span className="muted">No budget</span>}</td>
        <td className="r num">{money(k.invoiced)}</td><td className="r num">{money(k.unbilled)}</td>
        <td className="r num" style={{ color: Number(k.forecast_margin) < 0 ? 'var(--bad)' : undefined }}>{money(k.forecast_margin)}</td>
        <td className="r num">{k.serious_issues > 0 ? <span className="pill bad">{k.open_issues}</span> : k.open_issues}</td></tr>)}</tbody>
    </table></div> : <Empty>{mine ? 'You do not manage any projects yet.' : 'No projects yet.'}</Empty>}</Panel>}
    {data && tab === 'templates' && <Panel>{data.templates.length ? <div className="scroll"><table>
      <thead><tr><th>Template</th><th>Billing</th><th></th></tr></thead>
      <tbody>{data.templates.map(t => <tr key={t.id}><td><Link to={'/projects/' + t.id}><b>{t.name}</b></Link><br /><span className="muted">{t.description}</span></td>
        <td>{BILLING.find(b => b[0] === t.billing_type)?.[1]}</td>
        <td className="r"><button className="btn small primary" type="button" onClick={() => setFromTpl({ template: t.id, name: '', customer_id: '', start: today() })}>Use</button></td></tr>)}</tbody>
    </table></div> : <Empty>No templates yet. A template holds a standard task plan with estimates and dependencies, a budget and billing milestones. New projects copy it with dates shifted.</Empty>}</Panel>}

    {edit && <ProjectForm edit={edit} setEdit={setEdit} customers={data?.customers || []} currencies={currencies} team={null} busy={act.busy} onClose={() => setEdit(null)}
      onSave={() => act.run(async () => { const r = await q<any>(supabase.from('projects').insert({ ...toRow(await withClient(edit, cid)), company_id: cid }).select('id').single() as any); setEdit(null); nav('/projects/' + r.id); }, edit.is_template ? 'Template created — add its tasks, budget and milestones' : 'Project created')} />}
    {fromTpl && data && <FormModal title="New project from template" submit="Create project" busy={act.busy} onClose={() => setFromTpl(null)}
      onSave={() => act.run(async () => { const id = await rpc<string>('create_project_from_template', { p_template: fromTpl.template, p_name: fromTpl.name, p_customer: fromTpl.customer_id || null, p_start: fromTpl.start, p_sales_order: null }); nav('/projects/' + id); }, 'Project created from template')}>
      <Select label="Template" id="ft-tpl" value={fromTpl.template} onChange={v => setFromTpl({ ...fromTpl, template: v })} options={data.templates.map(t => [t.id, t.name])} />
      <Field label="Project name" id="ft-name" value={fromTpl.name} onChange={v => setFromTpl({ ...fromTpl, name: v })} required />
      <div className="grid-form">
        <Select label="Client" id="ft-cust" value={fromTpl.customer_id} onChange={v => setFromTpl({ ...fromTpl, customer_id: v })} options={[['', 'Internal'], ...data.customers.map(c => [c.id, c.name] as [string, string])]} />
        <Field label="Start date" id="ft-start" type="date" value={fromTpl.start} onChange={v => setFromTpl({ ...fromTpl, start: v })} required />
      </div>
      <p className="muted" style={{ margin: 0, fontSize: 13 }}>Tasks, estimates, dependencies, budget lines and milestones are copied; all dates move to the new start. You become the project manager.</p>
    </FormModal>}
  </>;
}

// ---------------------------------------------------------------- One project
type Tab = 'overview' | 'plan' | 'budget' | 'progress' | 'purchases' | 'materials' | 'team' | 'time' | 'billing' | 'issues' | 'documents';
const TABS: [Tab, string][] = [['overview', 'Overview'], ['plan', 'Plan'], ['budget', 'Budget'], ['progress', 'Progress & meetings'], ['purchases', 'Purchases'], ['materials', 'Materials & site store'], ['team', 'Team'], ['time', 'Time & expenses'], ['billing', 'Billing'], ['issues', 'Issues & risks'], ['documents', 'Documents']];

export function ProjectView() {
  const { id } = useParams();
  const { cid, company, can, session } = useSession();
  const nav = useNavigate();
  const act = useAction();
  const [tab, setTab] = useState<Tab>('overview');
  const { data: currencies } = useCurrencies(cid);
  const { data: team } = useTeam(cid);
  const [edit, setEdit] = useState<any | null>(null);
  const [task, setTask] = useState<any | null>(null);
  const [time, setTime] = useState<any | null>(null);
  const [billTo, setBillTo] = useState<string | null>(null);
  const [ms, setMs] = useState<any | null>(null);
  const [issue, setIssue] = useState<any | null>(null);
  const [upd, setUpd] = useState({ health: 'on_track', summary: '' });
  const [budget, setBudget] = useState<any[] | null>(null);
  const [whatIf, setWhatIf] = useState({ hours: '', rate: '' });

  const { data, error, loading, reload } = useLoad(async () => {
    const p = await q<any>(supabase.from('projects').select('*, customer:customers(id,name)').eq('id', id).single() as any);
    const [tasks, times, assignments, names, customers, invoices, expenses, kpis, milestones, budgetLines, actuals, issues, updates, docs, manage, committedRows] = await Promise.all([
      q<any[]>(supabase.from('tasks').select('*').eq('project_id', id).order('sort').order('start_date', { nullsFirst: false }) as any),
      q<any[]>(supabase.from('timesheets').select('*').eq('project_id', id).order('work_date', { ascending: false }) as any),
      rpc<any[]>('project_team', { p_project: id }),
      rpc<any[]>('group_employee_names', { cid }),
      q<any[]>(supabase.from('customers').select('id,name').eq('company_id', cid).order('name') as any),
      q<any[]>(supabase.from('invoices').select('id,number,invoice_date,subtotal,total,status,currency').eq('project_id', id).order('invoice_date', { ascending: false }) as any),
      q<any[]>(supabase.from('expense_claims').select('*').eq('project_id', id).order('expense_date', { ascending: false }) as any),
      rpc<any[]>('project_kpis', { cid }),
      q<any[]>(supabase.from('project_milestones').select('*').eq('project_id', id).order('sort').order('due_date') as any),
      q<any[]>(supabase.from('project_budget_lines').select('*').eq('project_id', id).order('sort') as any),
      rpc<any[]>('project_actuals_by_category', { p_project: id }),
      q<any[]>(supabase.from('project_issues').select('*').eq('project_id', id).order('created_at', { ascending: false }) as any),
      q<any[]>(supabase.from('project_updates').select('*').eq('project_id', id).order('created_at', { ascending: false }).limit(30) as any),
      q<any[]>(supabase.from('project_documents').select('*').eq('project_id', id).order('created_at', { ascending: false }) as any),
      rpc<boolean>('can_manage_project', { pid: id }),
      rpc<any[]>('project_committed_by_category', { p_project: id }),
    ]);
    return { p, tasks, times, assignments, names, customers, invoices, expenses, k: kpis.find(k => k.project_id === id) || null, milestones, budgetLines, actuals, issues, updates, docs, manage, committedRows };
  }, [id, cid]);
  if (!data) return <Loading error={error} loading={loading} />;
  const { p, tasks, times, assignments, names, customers, invoices, expenses, k, milestones, budgetLines, actuals, issues, updates, docs, manage, committedRows } = data;
  const who = (eid: string | null) => names.find(s => s.id === eid)?.full_name || '';
  const staff = names.filter(n => n.company_id === cid || assignments.some(t => t.employee_id === n.id));
  const fx = p.currency === 'GHS' ? 1 : Number(currencies?.find(c => c.code === p.currency)?.rate || 1);
  const setStatus = (t: any, status: string) => act.run(async () => { await q(supabase.from('tasks').update({ status }).eq('id', t.id) as any); reload(); });
  const tHead = ['Date', 'Employee', 'Task', 'Hours', 'Billable', 'Status', 'Invoiced', 'Note'];
  const tRows = times.map(t => [t.work_date, who(t.employee_id), tasks.find(x => x.id === t.task_id)?.title || '', String(t.hours), t.billable ? 'Yes' : 'No', t.status, t.invoice_id ? 'Yes' : '', t.note || '']);
  const xHead = ['Date', 'Employee', 'Description', 'Currency', 'Amount', 'GHS', 'Billable', 'Status'];
  const xRows = expenses.map(x => [x.expense_date, who(x.employee_id), x.description, x.currency, money(x.amount), money(x.amount_home), x.billable ? 'Yes' : 'No', x.status]);
  const tpl = p.is_template;
  const actual = (cat: string) => Number(actuals.find(a => a.category === cat)?.actual || 0);
  const committed = (cat: string) => Number(committedRows.find(a => a.category === cat)?.committed || 0);

  // what-if forecast (not saved)
  const defHrs = Math.max(Number(k?.est_hours || 0) * (1 - Number(k?.pct_complete || 0) / 100), 0);
  const defRate = Number(k?.actual_hours) > 0 ? actual('labour') / Number(k?.actual_hours) : 0;
  const remainingHrs = whatIf.hours === '' ? defHrs : Number(whatIf.hours);
  const avgRate = whatIf.rate === '' ? defRate : Number(whatIf.rate);
  const wiCost = Number(k?.actual_cost || 0) + Number(k?.committed_cost || 0) + remainingHrs * avgRate;
  const wiMargin = Number(k?.budget_revenue || 0) - wiCost;

  const saveBudget = () => act.run(async () => {
    const rows = budget!.filter(b => b.category);
    await q(supabase.from('project_budget_lines').delete().eq('project_id', id) as any);
    if (rows.length) await q(supabase.from('project_budget_lines').insert(rows.map((b, i) => ({ company_id: p.company_id, project_id: id, category: b.category, description: b.description || null,
      cost_budget: Number(b.cost_budget) || 0, revenue_budget: Number(b.revenue_budget) || 0, sort: i }))) as any);
    setBudget(null); reload();
  }, 'Budget saved');


  const report = () => projectReportPdf({ company: company!, p, k, tasks, milestones, issues, update: updates[0] || null, customerName: p.customer?.name });

  return <>
    <PageHead title={(tpl ? 'Template: ' : '') + p.name} sub={<>{!tpl && <><span className="num muted">{p.number}</span> <Stage s={p.status} /> <Health h={p.health} /> </>}
      <span className="muted">· {p.customer?.name || (tpl ? 'Template' : 'Internal')}{p.location || p.country ? ' · ' + [p.location, p.country].filter(Boolean).join(', ') : ''} · {BILLING.find(b => b[0] === p.billing_type)?.[1]} in {p.currency}{p.manager_id ? ' · PM ' + (team?.find(t => t.user_id === p.manager_id)?.email.split('@')[0] || '') : ''}</span></>}>
      <Link className="btn" to="/projects">Back</Link>
      {!tpl && <button className="btn" type="button" onClick={report}>Status report PDF</button>}
      {manage && <button className="btn" type="button" onClick={() => setEdit({ ...p, customer_id: p.customer?.id || '', start_date: p.start_date || '', end_date: p.end_date || '', description: p.description || '', location: p.location || '', country: p.country || '', manager_id: p.manager_id || '' })}>Edit</button>}
    </PageHead>
    <div className="actions" style={{ overflowX: 'auto', flexWrap: 'nowrap' }}>
      {TABS.filter(([t]) => !tpl || ['plan', 'budget', 'billing', 'documents'].includes(t) || t === 'overview').map(([t, l]) => [t, t === 'purchases' && k?.pending_requests ? `${l} (${k.pending_requests})` : l] as [Tab, string]).map(([t, l]) => <button key={t} type="button" className={'btn small' + (tab === t ? ' primary' : '')} onClick={() => setTab(t)}>{l}</button>)}
    </div>

    {tab === 'overview' && <>
      {!tpl && <ProjectLifecycle p={p} k={k} manage={!!manage} onChange={reload} />}
      {!tpl && <FinanceControl p={p} manage={!!manage} onChange={reload} />}
      {k && <div className="tiles">
        <div className="tile"><span>Complete</span><b>{k.pct_complete}%</b></div>
        <div className="tile"><span>Hours: approved / estimated</span><b>{Number(k.actual_hours)} / {Number(k.est_hours)}</b></div>
        <div className="tile"><span>Cost: spent + committed / budget</span><b style={{ fontSize: 16, color: Number(k.budget_cost) > 0 && Number(k.actual_cost) + Number(k.committed_cost) > Number(k.budget_cost) ? 'var(--bad)' : undefined }}>
          {cedis(Number(k.actual_cost) + Number(k.committed_cost))} / {money(k.budget_cost)}</b></div>
        <div className="tile"><span>Revenue: invoiced / budget</span><b style={{ fontSize: 16 }}>{cedis(k.invoiced)} / {money(k.budget_revenue)}</b></div>
        <div className="tile"><span>Unbilled work</span><b>{cedis(k.unbilled)}</b></div>
        <div className="tile"><span>Forecast margin</span><b style={{ color: Number(k.forecast_margin) < 0 ? 'var(--bad)' : undefined }}>{cedis(k.forecast_margin)}</b></div>
      </div>}
      {p.description && <div className="note" style={{ whiteSpace: 'pre-wrap' }}>{p.description}</div>}
      <div className="two">
        <Panel title="Status updates">
          {!tpl && <form className="body" style={{ display: 'grid', gap: 10, borderBottom: '1px solid var(--line)' }} onSubmit={e => { e.preventDefault(); act.run(async () => {
            await q(supabase.from('project_updates').insert({ company_id: p.company_id, project_id: id, health: upd.health, summary: upd.summary }) as any); setUpd({ ...upd, summary: '' }); reload(); }, 'Update posted'); }}>
            <Field label="What happened this week, and what's next?" id="up-sum" type="textarea" value={upd.summary} onChange={v => setUpd({ ...upd, summary: v })} />
            <div className="actions"><Select label="Health" id="up-health" value={upd.health} onChange={v => setUpd({ ...upd, health: v })} options={HEALTH.map(h => [h[0], h[1]])} />
              <button className="btn primary" type="submit" style={{ alignSelf: 'end' }} disabled={!upd.summary || act.busy}>Post update</button></div>
          </form>}
          {updates.length ? <div className="scroll"><table><tbody>{updates.map(u => <tr key={u.id}><td style={{ width: 100 }}><Health h={u.health} /><br /><span className="muted num" style={{ fontSize: 12 }}>{u.created_at.slice(0, 10)}</span></td>
            <td className="wrap-cell">{u.summary}<br /><span className="muted" style={{ fontSize: 12 }}>{u.author_email}</span></td></tr>)}</tbody></table></div> : <Empty>No updates yet. Post one each week so sponsors and clients can follow along.</Empty>}
        </Panel>
        <div style={{ display: 'grid', gap: 16, alignContent: 'start' }}>
          <Panel title="Milestones">{milestones.length ? <div className="scroll"><table><tbody>{milestones.map(m => <tr key={m.id}><td>{m.name}<br /><span className="muted num" style={{ fontSize: 12 }}>{m.due_date || ''}</span></td>
            <td className="r num">{money(m.amount)}</td><td><span className={'pill ' + (m.status === 'invoiced' ? 'good' : m.status === 'ready' ? 'warn' : '')}>{m.status === 'ready' ? 'Ready to bill' : m.status}</span></td></tr>)}</tbody></table></div> : <Empty>No milestones.</Empty>}</Panel>
          <Panel title="Open issues and risks">{issues.filter(i => ['open', 'in_progress'].includes(i.status)).length ? <div className="scroll"><table><tbody>
            {issues.filter(i => ['open', 'in_progress'].includes(i.status)).slice(0, 6).map(i => <tr key={i.id}><td>{i.title}</td><td><span className={'pill ' + (['high', 'critical'].includes(i.severity) ? 'bad' : '')}>{i.severity}</span></td></tr>)}</tbody></table></div> : <Empty>None open.</Empty>}</Panel>
          {!tpl && <ActivityList cid={cid} filter={{ project_id: id! }} team={team} compact />}
        </div>
      </div>
    </>}

    {tab === 'plan' && <>
      <Panel title="Timeline" actions={<button className="btn small primary" type="button" onClick={() => setTask({ title: '', assignee_id: '', start_date: '', due_date: '', status: 'todo', estimated_hours: '', percent_complete: '', predecessor_id: '', is_milestone: false, description: '' })}>Add task</button>} pad>
        <Gantt tasks={tasks} onPick={tid => { const t = tasks.find(x => x.id === tid); if (t) setTask({ ...t, assignee_id: t.assignee_id || '', start_date: t.start_date || '', due_date: t.due_date || '', estimated_hours: t.estimated_hours ?? '', percent_complete: t.percent_complete ?? '', predecessor_id: t.predecessor_id || '', description: t.description || '' }); }} />
      </Panel>
      <Panel title="Tasks" actions={<Downloads csv={() => downloadCsv(`tasks-${p.name}`, ['Task', 'Start', 'Due', 'Estimated hours', 'Status', '% complete', 'Assigned', 'Depends on'], tasks.map(t => [t.title, t.start_date || '', t.due_date || '', String(t.estimated_hours ?? ''), t.status, String(t.percent_complete ?? ''), who(t.assignee_id), tasks.find(x => x.id === t.predecessor_id)?.title || '']))} />}>
        {tasks.length ? <div className="scroll"><table>
          <thead><tr><th>Task</th><th>Dates</th><th className="r">Est. hrs</th><th>Depends on</th><th>Assigned</th><th>Status</th><th></th></tr></thead>
          <tbody>{tasks.map(t => <tr key={t.id}><td><b>{t.title}</b>{t.is_milestone && <span className="pill" style={{ marginLeft: 6 }}>Milestone</span>}</td>
            <td className="num" style={{ color: t.status !== 'done' && t.due_date && t.due_date < today() ? 'var(--bad)' : undefined }}>{t.start_date || '—'} → {t.due_date || '—'}</td>
            <td className="r num">{t.estimated_hours ?? ''}</td><td>{tasks.find(x => x.id === t.predecessor_id)?.title}</td><td>{who(t.assignee_id)}</td>
            <td>{t.status === 'done' ? <span className="pill good">Done</span> : <span className="pill">{t.status === 'doing' ? `In progress ${t.percent_complete ?? 50}%` : 'To do'}</span>}</td>
            <td className="r"><span className="actions" style={{ justifyContent: 'flex-end' }}>
              {t.status !== 'done' && !tpl && <button className="btn small" type="button" onClick={() => setStatus(t, t.status === 'todo' ? 'doing' : 'done')}>{t.status === 'todo' ? 'Start' : 'Done'}</button>}
              <button className="btn small ghost" type="button" onClick={() => setTask({ ...t, assignee_id: t.assignee_id || '', start_date: t.start_date || '', due_date: t.due_date || '', estimated_hours: t.estimated_hours ?? '', percent_complete: t.percent_complete ?? '', predecessor_id: t.predecessor_id || '', description: t.description || '' })}>Edit</button></span></td></tr>)}</tbody>
        </table></div> : <Empty>No tasks yet.</Empty>}
      </Panel>
    </>}

    {tab === 'budget' && <>
      <Panel title="Budget vs actual (GH₵)" actions={manage && (budget
        ? <><button className="btn small" type="button" onClick={() => setBudget(null)}>Cancel</button><button className="btn small primary" type="button" onClick={saveBudget}>Save budget</button></>
        : <button className="btn small primary" type="button" onClick={() => setBudget(budgetLines.length ? budgetLines.map(b => ({ ...b })) : [{ category: 'labour', description: '', cost_budget: '', revenue_budget: '' }])}>Edit budget</button>)}>
        {budget ? <div className="scroll"><table className="lines">
          <thead><tr><th>Category</th><th>Description</th><th className="r">Cost budget</th><th className="r">Revenue budget</th><th></th></tr></thead>
          <tbody>{budget.map((b, i) => <tr key={i}>
            <td><select aria-label="Category" value={b.category} onChange={e => setBudget(budget.map((x, j) => j === i ? { ...x, category: e.target.value } : x))}>{CATS.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select></td>
            <td><input aria-label="Description" value={b.description || ''} onChange={e => setBudget(budget.map((x, j) => j === i ? { ...x, description: e.target.value } : x))} /></td>
            <td><input aria-label="Cost budget" type="number" step="0.01" min="0" style={{ width: 120, textAlign: 'right' }} value={b.cost_budget} onChange={e => setBudget(budget.map((x, j) => j === i ? { ...x, cost_budget: e.target.value } : x))} /></td>
            <td><input aria-label="Revenue budget" type="number" step="0.01" min="0" style={{ width: 120, textAlign: 'right' }} value={b.revenue_budget} onChange={e => setBudget(budget.map((x, j) => j === i ? { ...x, revenue_budget: e.target.value } : x))} /></td>
            <td><button className="btn small ghost" type="button" onClick={() => setBudget(budget.filter((_, j) => j !== i))}>Remove</button></td></tr>)}</tbody>
          <tfoot><tr><td colSpan={5}><button className="btn small" type="button" onClick={() => setBudget([...budget, { category: 'materials', description: '', cost_budget: '', revenue_budget: '' }])}>Add line</button></td></tr></tfoot>
        </table></div> : <div className="scroll"><table>
          <thead><tr><th>Category</th><th className="r">Cost budget</th><th className="r">Spent</th><th className="r">Committed</th><th className="r">Left</th><th style={{ width: 150 }}>Used</th><th className="r">Revenue budget</th></tr></thead>
          <tbody>{CATS.map(([c, l]) => { const b = budgetLines.filter(x => x.category === c); const cb = b.reduce((s, x) => s + Number(x.cost_budget), 0), rb = b.reduce((s, x) => s + Number(x.revenue_budget), 0);
            const used = actual(c) + committed(c);
            if (!cb && !rb && !used) return null;
            return <tr key={c}><td>{l}{!cb && used > 0 && <span className="pill bad" style={{ marginLeft: 6 }}>No budget</span>}
                {b.some(x => x.description) && <><br /><span className="muted" style={{ fontSize: 12 }}>{b.map(x => x.description).filter(Boolean).join('; ')}</span></>}</td>
              <td className="r num">{money(cb)}</td><td className="r num">{money(actual(c))}</td><td className="r num">{committed(c) ? money(committed(c)) : ''}</td>
              <td className="r num" style={{ color: cb - used < 0 ? 'var(--bad)' : undefined }}>{money(cb - used)}</td>
              <td>{cb ? <Bar pct={used / cb * 100} /> : <span className="muted">—</span>}</td><td className="r num">{money(rb)}</td></tr>; })}</tbody>
          <tfoot><tr><td>Total</td><td className="r num">{money(k?.budget_cost)}</td><td className="r num">{money(k?.actual_cost)}</td><td className="r num">{money(k?.committed_cost)}</td>
            <td className="r num" style={{ color: Number(k?.budget_cost) - Number(k?.actual_cost) - Number(k?.committed_cost) < 0 ? 'var(--bad)' : undefined }}>{money(Number(k?.budget_cost) - Number(k?.actual_cost) - Number(k?.committed_cost))}</td><td></td>
            <td className="r num">{money(budgetLines.reduce((s, x) => s + Number(x.revenue_budget), 0) || Number(p.contract_value) * fx)}</td></tr></tfoot>
        </table></div>}
        <div className="body muted" style={{ fontSize: 13 }}>Spent: labour = approved hours × each person's internal cost rate; approved expense claims; posted supplier bills tagged to this project; manual journals charged to it.
          Committed: approved purchase requests not yet on a posted bill. If no revenue budget is set, the contract value is used. <Link to={`/project-costs?project=${id}`}>Line-by-line cost report</Link></div>
      </Panel>
      {!tpl && k && <Panel title="Forecast and what-if" pad>
        <div className="grid-form">
          <Field label="Remaining hours" id="wi-hrs" type="number" step="1" min="0" value={whatIf.hours} onChange={v => setWhatIf({ ...whatIf, hours: v })} placeholder={String(Math.round(defHrs))} />
          <Field label="Average cost per hour (GH₵)" id="wi-rate" type="number" step="0.01" min="0" value={whatIf.rate} onChange={v => setWhatIf({ ...whatIf, rate: v })} placeholder={money(defRate)} />
          <div><div className="label">Forecast cost at completion</div><b className="num">{cedis(wiCost)}</b></div>
          <div><div className="label">Forecast margin</div><b className="num" style={{ color: wiMargin < 0 ? 'var(--bad)' : 'var(--good)' }}>{cedis(wiMargin)}</b>
            {Number(k.budget_revenue) > 0 && <span className="muted"> ({Math.round(wiMargin / Number(k.budget_revenue) * 100)}%)</span>}</div>
        </div>
        <p className="muted" style={{ fontSize: 13, marginBottom: 0 }}>Change the remaining hours or cost rate to test scenarios. Nothing is saved.</p>
      </Panel>}
    </>}

    {tab === 'progress' && !tpl && <ProgressTab p={p} manage={!!manage} milestones={milestones} onChange={reload} />}
    {tab === 'purchases' && !tpl && <ProjectPurchases p={p} k={k} manage={!!manage} tasks={tasks} onChange={reload} />}
    {tab === 'materials' && !tpl && <><SiteStore p={p} manage={!!manage} onChange={reload} /><ProjectMaterials p={p} manage={!!manage} onChange={reload} /></>}

    {tab === 'team' && <Panel title="Team" actions={manage && <Link className="btn small primary" to="/resources">Find and assign people</Link>}>
      {assignments.length ? <div className="scroll"><table>
        <thead><tr><th>Person</th><th>Role</th><th>Dates</th><th className="r">Allocation</th><th className="r">Bill rate ({p.currency})</th><th>Status</th><th></th></tr></thead>
        <tbody>{assignments.map(t => <tr key={t.id}><td><b>{t.full_name}</b><br /><span className="muted">{t.job_title}{t.company_name !== company?.name ? ' · ' + t.company_name : ''}</span></td>
          <td>{t.role}</td><td className="num">{t.start_date} → {t.end_date || 'open'}</td><td className="r num">{t.allocation_pct}%</td>
          <td className="r num">{t.bill_rate != null ? money(t.bill_rate) : <span className="muted">{money(p.hourly_rate)}</span>}</td><td><Status s={t.status} /></td>
          <td className="r">{manage && <ConfirmButton className="btn small ghost" label="Remove" confirm="Remove from project?" onConfirm={() => act.run(async () => { await q(supabase.from('project_assignments').delete().eq('id', t.id) as any); reload(); })} />}</td></tr>)}</tbody>
      </table></div> : <Empty>No one assigned yet. Staff of this company can still log time; people from sister companies need an assignment.</Empty>}
    </Panel>}

    {tab === 'time' && <>
      <Panel title="Timesheets" actions={<>
        <Downloads pdf={() => tablePdf({ company: company!, title: `Timesheet: ${p.name}`, head: tHead, body: tRows, foot: ['', '', 'Total hours', String(times.reduce((s, t) => s + Number(t.hours), 0)), '', '', '', ''], rightAlign: [3], landscape: true, filename: `timesheet-${p.name}` })}
          csv={() => downloadCsv(`timesheet-${p.name}`, tHead, tRows)} />
        <Link className="btn small" to="/my">Log my time</Link>
        {manage && <Link className="btn small" to="/approvals">Approvals</Link>}
        {manage && <button className="btn small primary" type="button" onClick={() => setTime({ work_date: today(), employee_id: staff[0]?.id || '', task_id: '', hours: '', billable: p.billing_type !== 'non_billable', note: '' })}>Log time for someone</button>}</>}>
        {times.length ? <div className="scroll"><table>
          <thead><tr><th>Date</th><th>Employee</th><th>Task</th><th className="r">Hours</th><th>Billable</th><th>Status</th><th>Note</th></tr></thead>
          <tbody>{times.map(t => <tr key={t.id}><td className="num">{t.work_date}</td><td>{who(t.employee_id)}</td><td>{tasks.find(x => x.id === t.task_id)?.title}</td>
            <td className="r num">{t.hours}</td><td>{t.billable ? 'Yes' : 'No'}</td><td><Status s={t.status} />{t.invoice_id && <span className="pill good" style={{ marginLeft: 4 }}>Invoiced</span>}</td><td className="wrap-cell">{t.note}</td></tr>)}</tbody>
        </table></div> : <Empty>No time logged yet.</Empty>}
      </Panel>
      <Panel title="Expenses" actions={expenses.length > 0 && <Downloads pdf={() => tablePdf({ company: company!, title: `Expenses: ${p.name}`, head: xHead, body: xRows, rightAlign: [4, 5], landscape: true, filename: `expenses-${p.name}` })} csv={() => downloadCsv(`expenses-${p.name}`, xHead, xRows)} />}>
        {expenses.length ? <div className="scroll"><table>
          <thead><tr><th>Date</th><th>Employee</th><th>What</th><th className="r">Amount</th><th className="r">GH₵</th><th>Status</th></tr></thead>
          <tbody>{expenses.map(x => <tr key={x.id}><td className="num">{x.expense_date}</td><td>{who(x.employee_id)}</td><td className="wrap-cell">{x.description}{x.billable && <span className="pill" style={{ marginLeft: 6 }}>Re-bill</span>}</td>
            <td className="r num">{x.currency} {money(x.amount)}</td><td className="r num">{money(x.amount_home)}</td><td><Status s={x.status} />{x.invoice_id && <span className="pill good" style={{ marginLeft: 4 }}>Invoiced</span>}</td></tr>)}</tbody>
        </table></div> : <Empty>No expenses yet. Staff add them from My time & expenses.</Empty>}
      </Panel>
    </>}

    {tab === 'billing' && <>
      {!tpl && <ContractPayments p={p} manage={!!manage} onChange={reload} />}
      <Panel title={`Billing milestones (${p.currency})`} actions={manage && <button className="btn small primary" type="button" onClick={() => setMs({ name: '', due_date: '', amount: '', task_id: '' })}>Add milestone</button>}>
        {milestones.length ? <div className="scroll"><table>
          <thead><tr><th>Milestone</th><th>Due</th><th>Linked task</th><th className="r">Amount</th><th>Status</th><th></th></tr></thead>
          <tbody>{milestones.map(m => <tr key={m.id}><td>{m.name}</td><td className="num">{m.due_date}</td><td>{tasks.find(t => t.id === m.task_id)?.title}</td><td className="r num">{money(m.amount)}</td>
            <td><span className={'pill ' + (m.status === 'invoiced' ? 'good' : m.status === 'ready' ? 'warn' : '')}>{m.status === 'ready' ? 'Ready to bill' : m.status === 'invoiced' ? 'Invoiced' : 'Planned'}</span></td>
            <td className="r"><span className="actions" style={{ justifyContent: 'flex-end' }}>
              {m.status !== 'invoiced' && !tpl && (manage || can('sales')) && <button className="btn small primary" type="button" disabled={act.busy} onClick={() => act.run(async () => { const inv = await rpc<string>('invoice_milestone', { p_milestone: m.id }); nav(`/invoices/${inv}/edit`); }, 'Draft invoice created')}>Invoice</button>}
              {m.invoice_id && <Link className="btn small" to={'/invoices/' + m.invoice_id}>Open invoice</Link>}
              {manage && m.status !== 'invoiced' && <button className="btn small ghost" type="button" onClick={() => setMs({ ...m, due_date: m.due_date || '', task_id: m.task_id || '' })}>Edit</button>}</span></td></tr>)}</tbody>
          <tfoot><tr><td colSpan={3}>Total {p.billing_type === 'fixed_price' && Number(p.contract_value) ? `(contract ${money(p.contract_value)})` : ''}</td><td className="r num">{money(milestones.reduce((s, m) => s + Number(m.amount), 0))}</td><td colSpan={2}></td></tr></tfoot>
        </table></div> : <Empty>{p.billing_type === 'fixed_price' ? 'Split the contract value into milestones. Link each one to a task so it becomes ready to bill when that task is done.' : 'Optional for time-and-materials projects, e.g. an upfront deposit.'}</Empty>}
      </Panel>
      {!tpl && p.billing_type !== 'non_billable' && <Panel title="Time, expenses and materials" pad>
        <div className="actions"><span className="muted">Unbilled approved work: <b className="num">{cedis(k?.unbilled)}</b></span>
          {(manage || can('sales')) && <button className="btn primary" type="button" onClick={() => setBillTo(today())}>Invoice time, expenses and materials</button>}</div>
      </Panel>}
      {invoices.length > 0 && <Panel title="Invoices for this project"><div className="scroll"><table>
        <thead><tr><th>Invoice</th><th>Date</th><th className="r">Total</th><th>Status</th></tr></thead>
        <tbody>{invoices.map(i => <tr key={i.id} className="click" onClick={() => nav('/invoices/' + i.id)}><td className="num">{i.number || 'Draft'}</td><td className="num">{i.invoice_date}</td><td className="r num">{amt(i.total, i.currency)}</td><td><Status s={i.status} kind="invoice" /></td></tr>)}</tbody>
      </table></div></Panel>}
    </>}

    {tab === 'issues' && <Panel title="Issues, risks and change requests" actions={<>
      <Downloads csv={() => downloadCsv(`issues-${p.name}`, ['Type', 'Title', 'Severity', 'Status', 'Assigned', 'Due', 'Resolution'], issues.map(i => [i.kind, i.title, i.severity, i.status, who(i.assignee_id), i.due_date || '', i.resolution || '']))} />
      <button className="btn small primary" type="button" onClick={() => setIssue({ kind: 'issue', title: '', description: '', severity: 'medium', status: 'open', assignee_id: '', due_date: '', task_id: '', resolution: '' })}>Log issue or risk</button></>}>
      {issues.length ? <div className="scroll"><table>
        <thead><tr><th>Issue</th><th>Severity</th><th>Assigned</th><th>Due</th><th>Status</th><th></th></tr></thead>
        <tbody>{issues.map(i => <tr key={i.id} style={['resolved', 'closed'].includes(i.status) ? { opacity: .6 } : undefined}>
          <td className="wrap-cell"><span className="pill">{i.kind === 'change_request' ? 'Change' : i.kind === 'risk' ? 'Risk' : 'Issue'}</span> <b>{i.title}</b>{i.task_id && <span className="muted"> · {tasks.find(t => t.id === i.task_id)?.title}</span>}
            {i.description && <><br /><span className="muted">{i.description}</span></>}{i.resolution && <><br /><span style={{ color: 'var(--good)' }}>{i.resolution}</span></>}</td>
          <td><span className={'pill ' + (['high', 'critical'].includes(i.severity) ? 'bad' : i.severity === 'medium' ? 'warn' : '')}>{i.severity}</span></td>
          <td>{who(i.assignee_id)}</td><td className="num" style={{ color: i.due_date && i.due_date < today() && !['resolved', 'closed'].includes(i.status) ? 'var(--bad)' : undefined }}>{i.due_date}</td>
          <td>{i.status.replace('_', ' ')}</td>
          <td className="r"><button className="btn small ghost" type="button" onClick={() => setIssue({ ...i, description: i.description || '', assignee_id: i.assignee_id || '', due_date: i.due_date || '', task_id: i.task_id || '', resolution: i.resolution || '' })}>Edit</button></td></tr>)}</tbody>
      </table></div> : <Empty>No issues logged.</Empty>}
    </Panel>}

    {tab === 'documents' && <ProjectDocuments p={p} manage={!!manage} tasks={tasks} team={team} templateOnly={tpl} />}

    {edit && <ProjectForm edit={edit} setEdit={setEdit} customers={customers} currencies={currencies} team={tpl ? null : team} busy={act.busy} onClose={() => setEdit(null)}
      onSave={() => act.run(async () => { await q(supabase.from('projects').update(toRow(await withClient(edit, cid))).eq('id', id) as any); setEdit(null); reload(); }, 'Saved')} />}
    {billTo && <FormModal title={`Invoice ${p.name}`} submit="Create draft invoice" busy={act.busy} onClose={() => setBillTo(null)}
      onSave={() => act.run(async () => { const inv = await rpc<string>('invoice_project', { p_project: id, p_to: billTo }); nav(`/invoices/${inv}/edit`); }, 'Draft invoice created')}>
      <p className="muted" style={{ margin: 0 }}>Bills approved, unbilled hours (hours × each person's bill rate), re-billable expenses, materials from the store marked "bill client" (less returns) and supplier costs marked "re-bill" up to this date, in {p.currency}.</p>
      <Field label="Include work up to" id="bt-date" type="date" value={billTo} onChange={setBillTo} required />
      {p.currency !== 'GHS' && <p className="muted" style={{ margin: 0, fontSize: 13 }}>Work for a client outside Ghana may be zero-rated for VAT. Untick VAT on the draft if it applies; confirm with your accountant.</p>}
    </FormModal>}
    {ms && <FormModal title={ms.id ? 'Edit milestone' : 'Add milestone'} busy={act.busy} onClose={() => setMs(null)}
      danger={ms.id && <ConfirmButton className="btn danger" label="Delete" confirm="Delete?" onConfirm={() => act.run(async () => { await q(supabase.from('project_milestones').delete().eq('id', ms.id) as any); setMs(null); reload(); })} />}
      onSave={() => act.run(async () => {
        const row = { name: ms.name, due_date: ms.due_date || null, amount: Number(ms.amount) || 0, task_id: ms.task_id || null };
        if (ms.id) await q(supabase.from('project_milestones').update(row).eq('id', ms.id) as any);
        else await q(supabase.from('project_milestones').insert({ ...row, company_id: p.company_id, project_id: id, sort: milestones.length }) as any);
        setMs(null); reload();
      }, 'Milestone saved')}>
      <Field label="Milestone" id="ms-name" value={ms.name} onChange={v => setMs({ ...ms, name: v })} placeholder="e.g. 30% mobilisation, Design sign-off" required />
      <div className="grid-form">
        <Field label={`Amount (${p.currency}, excl. VAT)`} id="ms-amt" type="number" step="0.01" min="0" value={ms.amount} onChange={v => setMs({ ...ms, amount: v })} required />
        <Field label="Due" id="ms-due" type="date" value={ms.due_date} onChange={v => setMs({ ...ms, due_date: v })} />
        <Select label="Ready to bill when this task is done" id="ms-task" value={ms.task_id} onChange={v => setMs({ ...ms, task_id: v })} options={[['', 'Mark ready myself'], ...tasks.map(t => [t.id, t.title] as [string, string])]} />
      </div>
      {Number(p.contract_value) > 0 && <div className="actions">{[10, 20, 30, 40, 50].map(pc => <button key={pc} className="btn small" type="button" onClick={() => setMs({ ...ms, amount: String(Math.round(Number(p.contract_value) * pc) / 100) })}>{pc}% of contract</button>)}</div>}
      {ms.id && ms.status === 'planned' && <p className="muted" style={{ margin: 0, fontSize: 13 }}>To make it billable, certify it on the Progress & meetings tab; Finance is notified to invoice it.</p>}
    </FormModal>}
    {task && <FormModal title={task.id ? 'Edit task' : 'Add task'} busy={act.busy} onClose={() => setTask(null)}
      danger={task.id && <ConfirmButton className="btn danger" label="Delete" confirm="Delete task?" onConfirm={() => act.run(async () => { await q(supabase.from('tasks').delete().eq('id', task.id) as any); setTask(null); reload(); })} />}
      onSave={() => act.run(async () => {
        if (task.start_date && task.due_date && task.due_date < task.start_date) throw new Error('The due date is before the start date.');
        const pred = tasks.find(t => t.id === task.predecessor_id);
        if (pred && pred.due_date && task.start_date && task.start_date <= pred.due_date) throw new Error(`This task depends on "${pred.title}", which finishes ${pred.due_date}. Start it after that.`);
        const row = { title: task.title, assignee_id: task.assignee_id || null, start_date: task.start_date || null, due_date: task.due_date || null, status: task.status,
          estimated_hours: task.estimated_hours === '' ? null : Number(task.estimated_hours), percent_complete: task.percent_complete === '' ? null : Number(task.percent_complete),
          predecessor_id: task.predecessor_id || null, is_milestone: !!task.is_milestone, description: task.description || null };
        if (task.id) await q(supabase.from('tasks').update(row).eq('id', task.id) as any);
        else await q(supabase.from('tasks').insert({ ...row, project_id: id, company_id: p.company_id, sort: tasks.length }) as any);
        setTask(null); reload();
      }, 'Task saved')}>
      <Field label="Task" id="tk-title" value={task.title} onChange={v => setTask({ ...task, title: v })} required />
      <div className="grid-form">
        <Field label="Start" id="tk-start" type="date" value={task.start_date} onChange={v => setTask({ ...task, start_date: v })} />
        <Field label="Due" id="tk-due" type="date" value={task.due_date} onChange={v => setTask({ ...task, due_date: v })} />
        <Field label="Estimated hours" id="tk-est" type="number" step="0.5" min="0" value={task.estimated_hours} onChange={v => setTask({ ...task, estimated_hours: v })} />
        <Select label="Depends on" id="tk-pred" value={task.predecessor_id} onChange={v => setTask({ ...task, predecessor_id: v })} options={[['', 'Nothing'], ...tasks.filter(t => t.id !== task.id).map(t => [t.id, t.title] as [string, string])]} />
        <Select label="Assigned to" id="tk-who" value={task.assignee_id} onChange={v => setTask({ ...task, assignee_id: v })} options={[['', 'Unassigned'], ...staff.filter(s => s.company_id === cid).map(s => [s.id, s.full_name] as [string, string])]} />
        <Select label="Status" id="tk-status" value={task.status} onChange={v => setTask({ ...task, status: v })} options={[['todo', 'To do'], ['doing', 'In progress'], ['done', 'Done']]} />
        {task.status === 'doing' && <Field label="% complete" id="tk-pct" type="number" step="5" min="0" max="100" value={task.percent_complete} onChange={v => setTask({ ...task, percent_complete: v })} />}
      </div>
      <label className="check"><input type="checkbox" checked={!!task.is_milestone} onChange={e => setTask({ ...task, is_milestone: e.target.checked })} /> Key date (shows as a diamond on the timeline)</label>
      <Field label="Notes" id="tk-desc" type="textarea" value={task.description} onChange={v => setTask({ ...task, description: v })} />
    </FormModal>}
    {issue && <FormModal title={issue.id ? 'Edit issue' : 'Log issue or risk'} busy={act.busy} onClose={() => setIssue(null)}
      danger={issue.id && <ConfirmButton className="btn danger" label="Delete" confirm="Delete?" onConfirm={() => act.run(async () => { await q(supabase.from('project_issues').delete().eq('id', issue.id) as any); setIssue(null); reload(); })} />}
      onSave={() => act.run(async () => {
        const done = ['resolved', 'closed'].includes(issue.status);
        const row = { kind: issue.kind, title: issue.title, description: issue.description || null, severity: issue.severity, status: issue.status, assignee_id: issue.assignee_id || null,
          due_date: issue.due_date || null, task_id: issue.task_id || null, resolution: issue.resolution || null, resolved_at: done ? (issue.resolved_at || new Date().toISOString()) : null };
        if (issue.id) await q(supabase.from('project_issues').update(row).eq('id', issue.id) as any);
        else await q(supabase.from('project_issues').insert({ ...row, company_id: p.company_id, project_id: id }) as any);
        setIssue(null); reload();
      }, 'Saved')}>
      <div className="grid-form">
        <Select label="Type" id="is-kind" value={issue.kind} onChange={v => setIssue({ ...issue, kind: v })} options={[['issue', 'Issue (happening now)'], ['risk', 'Risk (might happen)'], ['change_request', 'Change request']]} />
        <Select label="Severity" id="is-sev" value={issue.severity} onChange={v => setIssue({ ...issue, severity: v })} options={[['low', 'Low'], ['medium', 'Medium'], ['high', 'High'], ['critical', 'Critical']]} />
        <Select label="Status" id="is-status" value={issue.status} onChange={v => setIssue({ ...issue, status: v })} options={[['open', 'Open'], ['in_progress', 'In progress'], ['resolved', 'Resolved'], ['closed', 'Closed']]} />
      </div>
      <Field label="Title" id="is-title" value={issue.title} onChange={v => setIssue({ ...issue, title: v })} required />
      <Field label="Description" id="is-desc" type="textarea" value={issue.description} onChange={v => setIssue({ ...issue, description: v })} />
      <div className="grid-form">
        <Select label="Assigned to" id="is-who" value={issue.assignee_id} onChange={v => setIssue({ ...issue, assignee_id: v })} options={[['', 'Unassigned'], ...staff.map(s => [s.id, s.full_name] as [string, string])]} />
        <Field label="Resolve by" id="is-due" type="date" value={issue.due_date} onChange={v => setIssue({ ...issue, due_date: v })} />
        <Select label="Affects task" id="is-task" value={issue.task_id} onChange={v => setIssue({ ...issue, task_id: v })} options={[['', '—'], ...tasks.map(t => [t.id, t.title] as [string, string])]} />
      </div>
      {['resolved', 'closed'].includes(issue.status) && <Field label="Resolution" id="is-res" value={issue.resolution} onChange={v => setIssue({ ...issue, resolution: v })} />}
    </FormModal>}
    {time && <FormModal title="Log time (approved)" busy={act.busy} onClose={() => setTime(null)}
      onSave={() => act.run(async () => {
        const asg = assignments.find(t => t.employee_id === time.employee_id && t.bill_rate != null);
        await q(supabase.from('timesheets').insert({ project_id: id, company_id: p.company_id, work_date: time.work_date, employee_id: time.employee_id || null, task_id: time.task_id || null,
          hours: Number(time.hours), billable: time.billable, note: time.note || null, status: 'approved', bill_rate: asg ? asg.bill_rate : p.hourly_rate, approved_by: session?.user.id }) as any);
        setTime(null); reload();
      }, 'Time logged')}>
      <div className="grid-form">
        <Field label="Date" id="ts-date" type="date" value={time.work_date} onChange={v => setTime({ ...time, work_date: v })} required />
        <Select label="Employee" id="ts-emp" value={time.employee_id} onChange={v => setTime({ ...time, employee_id: v })} options={staff.map(s => [s.id, s.full_name] as [string, string])} />
        <Select label="Task" id="ts-task" value={time.task_id} onChange={v => setTime({ ...time, task_id: v })} options={[['', 'General'], ...tasks.map(t => [t.id, t.title] as [string, string])]} />
        <Field label="Hours" id="ts-hours" type="number" step="0.25" min="0.25" value={time.hours} onChange={v => setTime({ ...time, hours: v })} required />
      </div>
      <label className="check"><input type="checkbox" checked={time.billable} onChange={e => setTime({ ...time, billable: e.target.checked })} /> Billable to the client</label>
      <Field label="Note" id="ts-note" value={time.note} onChange={v => setTime({ ...time, note: v })} />
    </FormModal>}
  </>;
}
