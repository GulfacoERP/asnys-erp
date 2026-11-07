import type { Role } from './session';

/** The app is organised as modules opened from tiles on the home screen; each module's pages are tabs along the top. */
export type ModPage = { to: string; label: string; roles?: Role[]; also?: string[] };
export type Module = { id: string; name: string; blurb: string; hue: string; pages: ModPage[] };

export const MODULES: Module[] = [
  { id: 'sales', name: 'Sales', blurb: 'Invoices, quotes, credit notes and customers', hue: '#1f8a5b', pages: [
    { to: '/invoices', label: 'Invoices' }, { to: '/quotes', label: 'Quotes & orders' },
    { to: '/receivables', label: 'Receivables & follow-up', roles: ['accountant', 'sales'] }, { to: '/credit-notes', label: 'Credit notes' },
    { to: '/recurring', label: 'Recurring invoices' }, { to: '/customers', label: 'Customers' }] },
  { id: 'accounts', name: 'Accounts', blurb: 'Reports, ledger, bank, budgets and bills', hue: '#2f6fb0', pages: [
    { to: '/reports', label: 'Reports', roles: ['accountant'] }, { to: '/ledger', label: 'General ledger', roles: ['accountant'] },
    { to: '/journal', label: 'Journal', roles: ['accountant'] }, { to: '/bank-cash', label: 'Bank & cash', roles: ['accountant'] },
    { to: '/bank-reconciliation', label: 'Bank reconciliation', roles: ['accountant'] }, { to: '/budgets', label: 'Budgets', roles: ['accountant'] },
    { to: '/requests', label: 'Requests', roles: ['accountant'] }, { to: '/advances', label: 'Cash advances', roles: ['accountant'] }, { to: '/petty-cash', label: 'Petty cash', roles: ['accountant'] },
    { to: '/accounts', label: 'Chart of accounts', roles: ['accountant'] }, { to: '/audit', label: 'Audit trail', roles: ['accountant'] }] },
  { id: 'crm', name: 'CRM', blurb: 'Leads, pipeline, visits, campaigns and partners', hue: '#b4562b', pages: [
    { to: '/crm-dashboard', label: 'CRM dashboard' }, { to: '/crm', label: 'Leads & pipeline' }, { to: '/activities', label: 'Activities & visits' },
    { to: '/sales-performance', label: 'Performance & forecast' }, { to: '/campaigns', label: 'Campaigns' }, { to: '/partners', label: 'Partners' },
    { to: '/commissions', label: 'Commissions', roles: ['sales', 'accountant'] }] },
  { id: 'hr', name: 'HR', blurb: 'Employees, leave, payroll, recruitment and training', hue: '#8a4fb3', pages: [
    { to: '/employees', label: 'Employees', roles: ['hr', 'accountant'] }, { to: '/leave', label: 'Leave' },
    { to: '/payroll', label: 'Payroll', roles: ['hr', 'accountant'] }, { to: '/recruitment', label: 'Recruitment', roles: ['hr', 'accountant'] },
    { to: '/appraisals', label: 'Appraisals', roles: ['hr', 'accountant'] }, { to: '/training', label: 'Training' }] },
  { id: 'inventory', name: 'Inventory', blurb: 'Items, stores, site requests, transfers and counts', hue: '#a87512', pages: [
    { to: '/inventory', label: 'Items & stock', also: ['/inventory/items'] }, { to: '/inventory/issues', label: 'Issues to projects', roles: ['accountant', 'store', 'project_manager'] },
    { to: '/inventory/requests', label: 'Requests from sites', roles: ['accountant', 'store', 'project_manager'] },
    { to: '/inventory/transfers', label: 'Transfers', roles: ['accountant', 'store'] }, { to: '/inventory/counts', label: 'Stocktakes', roles: ['accountant', 'store'] },
    { to: '/inventory/warehouses', label: 'Stores & sites' }] },
  { id: 'projects', name: 'Projects', blurb: 'Tenders, project cycle, budgets, documents and costs', hue: '#0f7d86', pages: [
    { to: '/project-cycle', label: 'Project cycle' }, { to: '/tenders', label: 'Tenders' }, { to: '/projects', label: 'Project center' },
    { to: '/project-finance', label: 'Project finance', roles: ['accountant'] }, { to: '/resources', label: 'Resource planner', roles: ['hr', 'accountant', 'project_manager'] },
    { to: '/approvals', label: 'Approvals', roles: ['hr', 'accountant', 'project_manager'] }, { to: '/project-costs', label: 'Project costs', roles: ['accountant', 'project_manager'] },
    { to: '/documents', label: 'Documents' }] },
  { id: 'contracts', name: 'Contracts', blurb: 'Contract register, variations, bonds and key dates', hue: '#7a5a1e', pages: [
    { to: '/contracts', label: 'Contracts', roles: ['accountant', 'sales', 'project_manager'] },
    { to: '/contracts/variations', label: 'Variations', roles: ['accountant', 'sales', 'project_manager'] },
    { to: '/contracts/securities', label: 'Bonds & guarantees', roles: ['accountant', 'sales', 'project_manager'] },
    { to: '/contracts/obligations', label: 'Key dates & obligations', roles: ['accountant', 'sales', 'project_manager'] },
    { to: '/tenders', label: 'Tenders', roles: ['accountant', 'sales', 'project_manager'] }] },
  { id: 'assets', name: 'Assets', blurb: 'Asset register, check-out, audits, requests and upkeep', hue: '#3a6f8f', pages: [
    { to: '/assets', label: 'Asset register' }, { to: '/assets/requests', label: 'Requests' }, { to: '/assets/audits', label: 'Audits' },
    { to: '/assets/maintenance', label: 'Maintenance' }, { to: '/assets/movements', label: 'Movements' }] },
  { id: 'purchasing', name: 'Purchasing', blurb: 'Purchase orders, supplier bills and suppliers', hue: '#5d6b2f', pages: [
    { to: '/purchase-orders', label: 'Purchase orders', roles: ['accountant', 'store', 'project_manager'] },
    { to: '/bills', label: 'Supplier bills', roles: ['accountant'] }, { to: '/suppliers', label: 'Suppliers' }] },
  { id: 'service', name: 'Service', blurb: 'Support cases and the knowledge base', hue: '#b03a5b', pages: [
    { to: '/cases', label: 'Support cases' }, { to: '/knowledge', label: 'Knowledge base' }] },
  { id: 'settings', name: 'Settings', blurb: 'Company details, team access and imports', hue: '#5b6670', pages: [
    { to: '/settings', label: 'Settings & team', roles: ['accountant', 'hr'] }, { to: '/import', label: 'Import from spreadsheet', roles: ['accountant', 'hr', 'sales'] }] },
  { id: 'mywork', name: 'My work', blurb: 'Time, expenses, requests, advances and approvals', hue: '#1d6b55', pages: [
    { to: '/my', label: 'My time & expenses' }, { to: '/requests', label: 'Requests' }, { to: '/advances', label: 'Cash advances' }, { to: '/petty-cash', label: 'Petty cash' },
    { to: '/approvals-inbox', label: 'Waiting for my approval' }, { to: '/notifications', label: 'Notifications' }] },
];

/** Pages that sit above the modules, reached from the top bar. */
export const TOP_PAGES: Record<string, string> = {};

const hit = (path: string, to: string) => path === to || path.startsWith(to + '/');

/** Which module a path belongs to. A page in two modules (supplier bills, project costs) stays in the one you came from. */
export function moduleFor(path: string, last?: string | null): Module | null {
  const owns = (m: Module) => m.pages.some(p => hit(path, p.to) || (p.also || []).some(a => hit(path, a)));
  const prev = MODULES.find(m => m.id === last);
  if (prev && owns(prev)) return prev;
  return MODULES.find(owns) || null;
}

/** The tab to highlight: the longest page path that the current path falls under. */
export function activeTab(m: Module, path: string) {
  let best: ModPage | null = null, len = -1;
  for (const p of m.pages) for (const t of [p.to, ...(p.also || [])]) if (hit(path, t) && t.length > len) { best = p; len = t.length; }
  return best;
}

export function ModuleIcon({ id, size = 26 }: { id: string; size?: number }) {
  const p = { width: size, height: size, viewBox: '0 0 24 24', fill: 'none', stroke: 'currentColor', strokeWidth: 1.7, strokeLinecap: 'round' as const, strokeLinejoin: 'round' as const, 'aria-hidden': true };
  switch (id) {
    case 'sales': return <svg {...p}><path d="M6 3h9l3 3v15l-2.5-1.5L13 21l-2.5-1.5L8 21l-2-1.5V3z" /><path d="M9 9h6M9 13h6M9 17h3" /></svg>;
    case 'accounts': return <svg {...p}><path d="M4 20V10M10 20V4M16 20v-7M22 20H2" /><path d="M16 9l3-3 2 2" /></svg>;
    case 'crm': return <svg {...p}><circle cx="9" cy="8" r="3.5" /><path d="M2.5 20c.8-3.6 3.3-5.5 6.5-5.5s5.7 1.9 6.5 5.5" /><path d="M16 4.5a3.5 3.5 0 0 1 0 7M18.5 14.8c1.7.8 2.7 2.5 3 5.2" /></svg>;
    case 'hr': return <svg {...p}><rect x="3" y="5" width="18" height="15" rx="2" /><circle cx="9" cy="11.5" r="2.5" /><path d="M5.5 17.5c.6-1.8 1.9-2.8 3.5-2.8s2.9 1 3.5 2.8M15 10h3.5M15 13.5h3.5M9 5V3h6v2" /></svg>;
    case 'inventory': return <svg {...p}><path d="M3 7.5L12 3l9 4.5v9L12 21l-9-4.5z" /><path d="M3 7.5l9 4.5 9-4.5M12 12v9M7.5 5.2l9 4.6" /></svg>;
    case 'projects': return <svg {...p}><path d="M3 21h18M5 21V10l7-5 7 5v11" /><path d="M9 21v-6h6v6M12 5V2.5M10 2.5h4" /></svg>;
    case 'purchasing': return <svg {...p}><path d="M3 4h2.5l2.2 11h10.6L20.5 7H7" /><circle cx="9.5" cy="19" r="1.6" /><circle cx="16.5" cy="19" r="1.6" /></svg>;
    case 'service': return <svg {...p}><path d="M4 13v-1a8 8 0 0 1 16 0v1" /><rect x="3" y="13" width="4" height="6" rx="1.5" /><rect x="17" y="13" width="4" height="6" rx="1.5" /><path d="M19 19c0 1.5-1.5 2.5-4 2.5h-2" /></svg>;
    case 'settings': return <svg {...p}><circle cx="12" cy="12" r="3" /><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z" /></svg>;
    case 'contracts': return <svg {...p}><path d="M14 3H6.5A1.5 1.5 0 0 0 5 4.5v15A1.5 1.5 0 0 0 6.5 21h11a1.5 1.5 0 0 0 1.5-1.5V8z" /><path d="M14 3v5h5M8.5 12.5h7M8.5 16h3.5" /><path d="M13.5 18.5c1-1.6 1.8-1.6 2.3-.4.3.7.9.7 1.7-.2" /></svg>;
    case 'assets': return <svg {...p}><rect x="3" y="6" width="18" height="12" rx="2" /><path d="M7 10v4M10 10v4M12.5 10v4M16 10v4M18 10v4" /><path d="M8 3.5h8" /></svg>;
    case 'mywork': return <svg {...p}><circle cx="12" cy="8" r="3.5" /><path d="M5 20.5c.7-3.6 3.4-5.5 7-5.5s6.3 1.9 7 5.5" /><path d="M17.5 3.5l1.2 1.2 2.3-2.3" /></svg>;
    case 'grid': return <svg {...p}><rect x="4" y="4" width="6" height="6" rx="1.2" /><rect x="14" y="4" width="6" height="6" rx="1.2" /><rect x="4" y="14" width="6" height="6" rx="1.2" /><rect x="14" y="14" width="6" height="6" rx="1.2" /></svg>;
    case 'bell': return <svg {...p}><path d="M6 16V11a6 6 0 0 1 12 0v5l1.5 2h-15z" /><path d="M10 20.5a2 2 0 0 0 4 0" /></svg>;
    case 'check': return <svg {...p}><rect x="4" y="3.5" width="16" height="18" rx="2" /><path d="M8.5 12.5l2.5 2.5 4.5-5M9 3.5V2h6v1.5" /></svg>;
    case 'clock': return <svg {...p}><circle cx="12" cy="12" r="8.5" /><path d="M12 7.5V12l3 2" /></svg>;
    default: return null;
  }
}
