import { useState } from 'react';
import { rpc } from '../lib/supabase';
import { useSession } from '../lib/session';
import { longDate, today } from '../lib/format';
import { downloadCsv } from '../lib/download';
import { tablePdf } from '../lib/pdf';
import { Pager, SearchBox, usePaged } from '../components/paging';
import { Downloads, Empty, Field, Loading, PageHead, Panel, Select, useAction, useLoad } from '../components/ui';
import { VoidButton } from '../components/Void';

/** Friendly names for the areas of the system, grouped by module. Unknown tables fall back to their name. */
const AREAS: Record<string, [string, string]> = {
  sign_in: ['Sign-ins', 'Access'], memberships: ['Team and roles', 'Access'], member_invites: ['Invitations', 'Access'], companies: ['Company settings', 'Settings'],
  company_telegram: ['Telegram settings', 'Settings'], company_email: ['Email settings', 'Settings'], approval_rules: ['Approval rules', 'Settings'],
  invoices: ['Invoices', 'Sales'], payments: ['Customer receipts', 'Sales'], credit_notes: ['Credit notes', 'Sales'], customers: ['Customers', 'Sales'], sales_quotes: ['Quotes', 'Sales'],
  bills: ['Supplier bills', 'Purchasing'], bill_payments: ['Supplier payments', 'Purchasing'], suppliers: ['Suppliers', 'Purchasing'], purchase_orders: ['Purchase orders', 'Purchasing'],
  cash_transactions: ['Bank and cash', 'Accounts'], journal_entries: ['Journals', 'Accounts'], accounts: ['Chart of accounts', 'Accounts'], bill: ['Approvals: bills', 'Accounts'],
  payroll: ['Approvals: payroll', 'HR'], purchase_order: ['Approvals: purchase orders', 'Purchasing'], purchase_request: ['Approvals: purchase requests', 'Projects'], expense_claim: ['Approvals: expenses', 'Projects'],
  approval_steps: ['Approval steps', 'Accounts'], spend_requests: ['Spend requests', 'Accounts'], cash_advances: ['Cash advances', 'Accounts'], petty_vouchers: ['Petty cash', 'Accounts'], petty_counts: ['Petty cash counts', 'Accounts'],
  employees: ['Employees', 'HR'], payroll_runs: ['Payroll', 'HR'], leave_requests: ['Leave', 'HR'], employee_events: ['Employment history', 'HR'], employee_documents: ['Employee documents', 'HR'],
  salary_changes: ['Pay changes', 'HR'], employee_pay_items: ['Pay items', 'HR'], employee_change_requests: ['Profile changes', 'HR'], employee_exits: ['Exits', 'HR'], announcements: ['Announcements', 'HR'],
  training_requests: ['Training requests', 'HR'], trainings: ['Training', 'HR'], timesheets: ['Timesheets', 'Projects'], expense_claims: ['Expense claims', 'Projects'],
  projects: ['Projects', 'Projects'], tasks: ['Tasks', 'Projects'], project_requests: ['Purchase requests', 'Projects'], project_budget_lines: ['Budgets', 'Projects'], progress_reports: ['Progress reports', 'Projects'],
  doc_register: ['Documents', 'Projects'], doc_revisions: ['Document revisions', 'Projects'], tenders: ['Tenders', 'Projects'], contracts: ['Contracts', 'Contracts'], contract_variations: ['Variations', 'Contracts'],
  products: ['Products', 'Stock'], warehouses: ['Stores', 'Stock'], stock_issues: ['Stock issues', 'Stock'], stock_transfers: ['Stock transfers', 'Stock'], stock_counts: ['Stocktakes', 'Stock'], stock_requests: ['Stock requests', 'Stock'],
  assets: ['Assets', 'Assets'], asset_requests: ['Asset requests', 'Assets'], asset_transfers: ['Asset transfers', 'Assets'], asset_locations: ['Locations', 'Assets'], asset_items: ['Consumables', 'Assets'],
  asset_item_moves: ['Consumable movements', 'Assets'], software_licences: ['Licences', 'Assets'], licence_seats: ['Licence seats', 'Assets'],
  vehicles: ['Vehicles', 'Fleet'], vehicle_documents: ['Vehicle papers', 'Fleet'], drivers: ['Drivers', 'Fleet'], vehicle_trips: ['Trips', 'Fleet'], vehicle_fuel: ['Fuel', 'Fleet'],
  vehicle_services: ['Service and repairs', 'Fleet'], vehicle_requests: ['Vehicle requests', 'Fleet'], waybills: ['Waybills', 'Fleet'],
  hse_incidents: ['Incidents', 'HSE'], hse_actions: ['Corrective actions', 'HSE'], hse_permits: ['Permits', 'HSE'], hse_inspections: ['Inspections', 'HSE'], hse_sessions: ['Toolbox talks and inductions', 'HSE'],
  compliance_obligations: ['Compliance register', 'HSE'], hse_policies: ['Policies', 'HSE'], esg_entries: ['Sustainability', 'HSE'], leads: ['Leads', 'CRM'], support_cases: ['Support cases', 'Service'],
};
const VOIDABLE = new Set(['tenders','sales_quotes','purchase_orders','project_requests','expense_claims','leave_requests','timesheets','stock_requests','asset_requests','training_requests','contract_variations','vehicle_requests','vehicle_trips','hse_permits','employee_change_requests','contracts','risk_assessments','hse_inspections','hse_sessions','leads']);
const areaName = (t?: string | null) => (t && AREAS[t]?.[0]) || (t ? t.replace(/_/g, ' ').replace(/^./, c => c.toUpperCase()) : '');
const HIDE = new Set(['id', 'company_id', 'created_at', 'updated_at', '_label', 'created_by', 'search', 'fts']);
const show = (v: any): string => v === null || v === undefined || v === '' ? '—' : typeof v === 'boolean' ? (v ? 'yes' : 'no') : typeof v === 'object' ? JSON.stringify(v).slice(0, 80) : String(v).slice(0, 120);
const label = (r: any) => {
  const d = { ...(r.old_data || {}), ...(r.new_data || {}) };
  return d._label || d.number || d.entry_no || d.reg_no || d.tag || d.name || d.full_name || d.title || d.email || d.description || r.detail?.email || '';
};
function verb(r: any) {
  if (r.action === 'user.signed_in') return ['Signed in', 'good'];
  if (r.action === 'entry.voided') return ['Voided', 'bad'];
  if (r.action.endsWith('.insert')) return ['Created', 'good'];
  if (r.action.endsWith('.delete')) return ['Deleted', 'bad'];
  if (r.action.endsWith('.update')) return [r.new_data?.status ? `Status → ${String(r.new_data.status).replace(/_/g, ' ')}` : 'Changed', r.new_data?.status === 'voided' ? 'bad' : ''];
  return [r.action.replace(/[._]/g, ' '), 'warn'];
}
function details(r: any): string {
  if (r.action === 'user.signed_in') return '';
  if (r.detail && !r.old_data && !r.new_data) return Object.entries(r.detail).filter(([k]) => k !== 'email').map(([k, v]) => `${k.replace(/_/g, ' ')}: ${show(v)}`).join(' · ');
  if (r.action.endsWith('.insert') || r.action.endsWith('.delete')) return '';
  return Object.keys(r.new_data || {}).filter(k => !HIDE.has(k)).map(k => `${k.replace(/_/g, ' ')}: ${show(r.old_data?.[k])} → ${show(r.new_data[k])}`).join(' · ');
}

/** Everything people did in the system: who, what, when, with old and new values. Entries cannot be edited or removed. */
export function ActivityPage() {
  const { cid, company } = useSession();
  const act = useAction();
  const [from, setFrom] = useState(new Date(Date.now() - 6 * 864e5).toISOString().slice(0, 10));
  const [to, setTo] = useState(today());
  const [table, setTable] = useState('');
  const [kind, setKind] = useState('');
  const [user, setUser] = useState('');
  const [search, setSearch] = useState('');
  const [tick, setTick] = useState(0);
  const { data: areas } = useLoad(() => rpc<any[]>('audit_areas', { cid, p_from: from, p_to: to }).catch(() => [] as any[]), [cid, from, to]);
  const args = (a: number, b: number) => ({ cid, p_from: from, p_to: to, p_table: table || null, p_user: user || null, p_search: search || null, p_kind: kind || null, p_limit: b - a + 1, p_offset: a });
  const pg = usePaged(async (a, b) => { const rows = await rpc<any[]>('activity_log', args(a, b)); return { rows, total: Number(rows[0]?.total || 0) }; }, [cid, from, to, table, kind, user, search, tick], 100);
  const head = ['When', 'Who', 'Area', 'What', 'Record', 'Details'];
  const download = (fmt: 'pdf' | 'csv') => act.run(async () => {
    const all: any[] = []; for (let a = 0; a < 20000; a += 1000) { const r = await rpc<any[]>('activity_log', args(a, a + 999)); all.push(...r); if (r.length < 1000) break; }
    const body = all.map(r => [r.created_at.slice(0, 19).replace('T', ' '), r.user_email || 'system', areaName(r.table_name), verb(r)[0], String(label(r)), details(r)]);
    if (fmt === 'csv') return downloadCsv(`activity-log-${from}-${to}`, head, body);
    tablePdf({ company: company!, title: 'Activity log', subtitle: `${longDate(from)} to ${longDate(to)}`, head, body, landscape: true, filename: `activity-log-${from}-${to}` });
  });
  const areaOpts: [string, string][] = [['', 'Every area'], ...(areas || []).map(a => [a.table_name, `${areaName(a.table_name)} (${a.n})`] as [string, string])];
  return <>
    <PageHead title="Activity log" sub="Everything done in Asnys: who created, changed, approved, voided or deleted what, and when, with the old and new values, plus every sign-in. Nobody can edit or remove these entries.">
      <Downloads pdf={() => download('pdf')} csv={() => download('csv')} />
    </PageHead>
    <div className="filters">
      <Field label="From" id="ac-from" type="date" value={from} onChange={setFrom} />
      <Field label="To" id="ac-to" type="date" value={to} onChange={setTo} />
      <Select label="Area" id="ac-area" value={table} onChange={setTable} options={areaOpts} />
      <Select label="What" id="ac-kind" value={kind} onChange={setKind} options={[['', 'Anything'], ['insert', 'Created'], ['update', 'Changed'], ['delete', 'Deleted'], ['sign_in', 'Sign-ins'], ['other', 'Approvals, voids and other actions']]} />
      <SearchBox value={user} onChange={setUser} placeholder="Email" id="ac-user" width={170} label="Person" />
      <SearchBox value={search} onChange={setSearch} placeholder="e.g. TND-00012, a name, an amount" id="ac-search" width={220} label="Containing" />
    </div>
    <Loading error={pg.error} loading={pg.loading && !pg.data} />
    {pg.data && <Panel>{pg.rows.length ? <div className="scroll"><table>
      <thead><tr><th style={{ width: 130 }}>When</th><th>Who</th><th>What</th><th>Details</th><th></th></tr></thead>
      <tbody>{pg.rows.map((r: any) => { const [v, c] = verb(r); const l = label(r); return <tr key={r.id}>
        <td className="num" style={{ fontSize: 13 }}>{r.created_at.slice(0, 16).replace('T', ' ')}</td>
        <td style={{ fontSize: 13 }}>{r.user_email || <span className="muted">system</span>}</td>
        <td><span className={'pill ' + c}>{v}</span> <span style={{ fontSize: 13 }}>{areaName(r.table_name)}</span>{l && <><br /><b style={{ fontSize: 13, fontWeight: 600 }}>{String(l).slice(0, 80)}</b></>}</td>
        <td className="wrap-cell muted" style={{ fontSize: 13, maxWidth: 520 }}>{details(r)}</td>
        <td className="r">{r.row_id && r.action.endsWith('.insert') && VOIDABLE.has(r.table_name) && <VoidButton table={r.table_name} id={r.row_id} label={String(l || areaName(r.table_name))} onDone={() => setTick(x => x + 1)} />}</td></tr>; })}</tbody>
    </table></div> : <Empty>Nothing recorded with these filters.</Empty>}
      <Pager {...pg} noun="entries" />
    </Panel>}
  </>;
}
