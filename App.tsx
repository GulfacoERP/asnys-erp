import { ReactNode, useEffect, useRef, useState } from 'react';
import { Link, Navigate, Route, Routes, useLocation } from 'react-router-dom';
import { configured, supabase } from './lib/supabase';
import { useSession } from './lib/session';
import { AuthPage, NewPasswordPage } from './pages/Auth';
import { Onboarding } from './pages/Onboarding';
import { Home } from './pages/Home';
import { PartiesPage } from './pages/Parties';
import { InvoicesPage, InvoiceEditor, InvoiceView } from './pages/Invoices';
import { BillsPage, BillEditor, BillView } from './pages/Bills';
import { AccountsPage, JournalPage } from './pages/Accounting';
import { ReportsPage } from './pages/Reports';
import { EmployeesPage, LeavePage } from './pages/HR';
import { PayrollPage, PayrollRunPage } from './pages/Payroll';
import { ProjectsPage, ProjectView } from './pages/Projects';
import { SettingsPage } from './pages/Settings';
import { CreditNotesPage, CreditNoteEditor, CreditNoteView } from './pages/CreditNotes';
import { QuotesPage, QuoteEditor, QuoteView } from './pages/Quotes';
import { RecurringPage } from './pages/Recurring';
import { RecruitmentPage, AppraisalsPage } from './pages/Recruitment';
import { BankRecPage, BudgetsPage } from './pages/Banking';
import { AssetsPage, AssetView } from './pages/Assets';
import { AnnouncementsPage, EmployeeProfilePage, HrReportsPage, HrTasksPage, MyPayslipsPage, MyProfilePage, OrgChartPage, PayComponentsPage } from './pages/People';
import { HseActionsPage, HseDashboardPage, HseIncidentView, HseIncidentsPage, HseInspectionView, HseInspectionsPage, HseObligationsPage, HsePermitsPage, HsePoliciesPage, HseRisksPage, HseSustainabilityPage, HseSessionsPage, HseSessionView, HseInductionsPage } from './pages/Hse';
import { CrmPage, ActivitiesPage, SalesPerformancePage } from './pages/CRM';
import { ResourcesPage } from './pages/Resources';
import { MyWorkPage } from './pages/MyWork';
import { ApprovalsPage } from './pages/Approvals';
import { Customer360 } from './pages/Customer360';
import { ProjectCostsPage } from './pages/ProjectCosts';
import { TrainingPage } from './pages/Training';
import { ApprovalsInboxPage, AuditPage, BankCashPage, GeneralLedgerPage } from './pages/Finance';
import { ImportPage } from './pages/Import';
import { InventoryPage, ItemView, StockCountView, StockCountsPage, StockIssueView, StockIssuesPage, TransfersPage, WarehousesPage } from './pages/Inventory';
import { DocumentsPage } from './pages/Documents';
import { TendersPage, TenderView } from './pages/Tenders';
import { CyclePage, NotificationsPage, ProjectFinancePage, ReceivablesPage } from './pages/Cycle';
import { StockRequestsPage } from './components/SiteStore';
import { PoEditor, PoView, PurchaseOrdersPage, Supplier360 } from './pages/Purchasing';
import { CasesPage, CaseView, KnowledgePage, PublicHelp } from './pages/Service';
import { BRAND, BRAND_MARK, PRODUCT, initials, isWhiteLabel } from './lib/brand';
import { ModuleIcon, TOP_PAGES, activeTab, moduleFor } from './lib/modules';
import { CampaignsPage, CommissionsPage, CrmDashboard, PartnersPage } from './pages/Marketing';
import { Logo, LogoMark } from './components/Logo';
import { ContractListPage, ContractView, ContractsPage } from './pages/Contracts';
import { AssetAuditsPage, AssetMaintenancePage, AssetMovementsPage, AssetRequestsPage } from './pages/AssetOps';
import { AdvanceView, AdvancesPage, PettyCashPage, RequestView, RequestsPage } from './pages/Spend';

export default function App() {
  const { session, loading, companies, recovery, welcome } = useSession();
  const help = location.pathname.match(/^\/help\/([0-9a-f-]{36})\/?$/i);
  if (help && configured) return <PublicHelp companyId={help[1]} />;
  if (!configured) return <NotConfigured />;
  if (loading) return <Starting />;
  if (recovery && (session || !welcome)) return <NewPasswordPage welcome={welcome} />;
  if (!session) return <AuthPage />;
  if (!companies.length) return <NoCompany />;
  return <Shell />;
}

/** Module tabs; fades the right edge while more tabs are hidden, and keeps the current tab in view. */
function TabStrip({ label, hue, children }: { label: string; hue: string; children: ReactNode }) {
  const ref = useRef<HTMLElement>(null);
  const [more, setMore] = useState(false);
  const loc = useLocation();
  useEffect(() => {
    const el = ref.current; if (!el) return;
    const check = () => setMore(el.scrollLeft + el.clientWidth < el.scrollWidth - 4);
    const on = el.querySelector<HTMLElement>('a.on');
    if (on && (on.offsetLeft + on.offsetWidth > el.scrollLeft + el.clientWidth || on.offsetLeft < el.scrollLeft)) el.scrollLeft = on.offsetLeft - 24;
    check(); el.addEventListener('scroll', check); window.addEventListener('resize', check);
    return () => { el.removeEventListener('scroll', check); window.removeEventListener('resize', check); };
  }, [loc.pathname]);
  return <nav ref={ref} className={'tb-tabs' + (more ? ' more' : '')} aria-label={label} style={{ '--hue': hue } as any}>{children}</nav>;
}

function Shell() {
  const { company, companies, selectCompany, role, can, session } = useSession();
  const loc = useLocation();
  const unread = useUnread(session?.user.id);
  const [last, setLast] = useState<string | null>(() => { try { return sessionStorage.getItem('asnys.module'); } catch { return null; } });
  const mod = moduleFor(loc.pathname, last);
  useEffect(() => {
    if (mod && mod.id !== last) { setLast(mod.id); try { sessionStorage.setItem('asnys.module', mod.id); } catch { /* storage unavailable */ } }
  }, [mod?.id]);
  const tabs = mod ? mod.pages.filter(p => !p.roles || can(...p.roles)) : [];
  const tab = mod ? activeTab(mod, loc.pathname) : null;
  const home = loc.pathname === '/';
  const where = mod ? mod.name : TOP_PAGES[loc.pathname] || '';
  useEffect(() => { document.title = [where, company?.name, BRAND].filter(Boolean).join(' · '); }, [where, company?.name]);
  const mark = isWhiteLabel ? BRAND_MARK : initials(company?.name);
  const email = session?.user.email || '';
  const menu = useRef<HTMLDetailsElement>(null);
  useEffect(() => {   // close the account menu on a click elsewhere or Escape
    const close = (e: Event) => { const d = menu.current; if (d?.open && (e instanceof KeyboardEvent ? e.key === 'Escape' : !d.contains(e.target as Node))) d.open = false; };
    document.addEventListener('click', close); document.addEventListener('keydown', close);
    return () => { document.removeEventListener('click', close); document.removeEventListener('keydown', close); };
  }, []);
  return (
    <div className="app">
      <header className="topbar">
        <Link to="/" className={'tb-home' + (home ? ' on' : '')} aria-label="All modules" title="All modules"><ModuleIcon id="grid" size={22} /></Link>
        {mod
          ? <Link to={tabs[0]?.to || '/'} className="tb-mod" style={{ '--hue': mod.hue } as any}><span className="tb-ico"><ModuleIcon id={mod.id} size={18} /></span><b>{mod.name}</b></Link>
          : <Link to="/" className="tb-mod tb-co" title={company?.name}><span className="mark">{mark}</span>
              <span className="tb-co-name"><b>{home || !where ? (isWhiteLabel ? BRAND : company?.name) : where}</b>{(home || !where) && <small>{isWhiteLabel ? company?.name : PRODUCT}</small>}</span></Link>}
        {mod && tabs.length > 0 && <TabStrip label={`${mod.name} pages`} hue={mod.hue}>
          {tabs.map(p => <Link key={p.to} to={p.to} className={tab?.to === p.to ? 'on' : ''} aria-current={tab?.to === p.to ? 'page' : undefined}>{p.label}</Link>)}
        </TabStrip>}
        <div className="tb-right">
          <Link to="/my" className={'tb-btn' + (loc.pathname === '/my' ? ' on' : '')} title="My time & expenses" aria-label="My time & expenses"><ModuleIcon id="clock" size={20} /></Link>
          <Link to="/approvals-inbox" className={'tb-btn' + (loc.pathname === '/approvals-inbox' ? ' on' : '')} title="Waiting for my approval" aria-label="Waiting for my approval"><ModuleIcon id="check" size={20} /></Link>
          <Link to="/notifications" className={'tb-btn' + (loc.pathname === '/notifications' ? ' on' : '')} title="Notifications" aria-label={`Notifications${unread ? `, ${unread} unread` : ''}`}>
            <ModuleIcon id="bell" size={20} />{unread > 0 && <span className="tb-dot">{unread > 99 ? '99+' : unread}</span>}</Link>
          <details className="tb-user" key={loc.pathname} ref={menu}>
            <summary aria-label="Account and company"><span className="avatar">{(email[0] || '?').toUpperCase()}</span></summary>
            <div className="tb-menu">
              <b>{company?.name}</b>
              <span className="muted">{email}<br /><span style={{ textTransform: 'capitalize' }}>{(role || '').replace('_', ' ')}</span></span>
              {companies.length > 1 && <select aria-label="Switch company" value={company?.id} onChange={e => selectCompany(e.target.value)}>
                {companies.map(c => <option key={c.company.id} value={c.company.id}>{c.company.name}</option>)}
              </select>}
              {can('accountant', 'hr') && <Link to="/settings">Settings & team</Link>}
              <button className="btn small" type="button" onClick={() => supabase.auth.signOut()}>Sign out</button>
            </div>
          </details>
        </div>
      </header>
      <main><div className="wrap" key={company?.id}>
        <Routes>
          <Route path="/" element={<Home />} />
          <Route path="/customers" element={<PartiesPage kind="customer" />} />
          <Route path="/suppliers" element={<PartiesPage kind="supplier" />} />
          <Route path="/products" element={<Navigate to="/inventory" replace />} />
          <Route path="/inventory" element={<InventoryPage />} />
          <Route path="/inventory/items/:id" element={<ItemView />} />
          <Route path="/inventory/warehouses" element={<WarehousesPage />} />
          <Route path="/inventory/issues" element={<StockIssuesPage />} />
          <Route path="/inventory/issues/:id" element={<StockIssueView />} />
          <Route path="/inventory/transfers" element={<TransfersPage />} />
          <Route path="/inventory/requests" element={<StockRequestsPage />} />
          <Route path="/documents" element={<DocumentsPage />} />
          <Route path="/tenders" element={<TendersPage />} />
          <Route path="/tenders/:id" element={<TenderView />} />
          <Route path="/project-cycle" element={<CyclePage />} />
          <Route path="/receivables" element={<ReceivablesPage />} />
          <Route path="/project-finance" element={<ProjectFinancePage />} />
          <Route path="/notifications" element={<NotificationsPage />} />
          <Route path="/inventory/counts" element={<StockCountsPage />} />
          <Route path="/inventory/counts/:id" element={<StockCountView />} />
          <Route path="/purchase-orders" element={<PurchaseOrdersPage />} />
          <Route path="/purchase-orders/new" element={<PoEditor />} />
          <Route path="/purchase-orders/:id/edit" element={<PoEditor />} />
          <Route path="/purchase-orders/:id" element={<PoView />} />
          <Route path="/suppliers/:id" element={<Supplier360 />} />
          <Route path="/invoices" element={<InvoicesPage />} />
          <Route path="/invoices/new" element={<InvoiceEditor />} />
          <Route path="/invoices/:id/edit" element={<InvoiceEditor />} />
          <Route path="/invoices/:id" element={<InvoiceView />} />
          <Route path="/bills" element={<BillsPage />} />
          <Route path="/bills/new" element={<BillEditor />} />
          <Route path="/bills/:id/edit" element={<BillEditor />} />
          <Route path="/bills/:id" element={<BillView />} />
          <Route path="/accounts" element={<AccountsPage />} />
          <Route path="/journal" element={<JournalPage />} />
          <Route path="/reports" element={<ReportsPage />} />
          <Route path="/employees" element={<EmployeesPage />} />
          <Route path="/leave" element={<LeavePage />} />
          <Route path="/payroll" element={<PayrollPage />} />
          <Route path="/payroll/components" element={<PayComponentsPage />} />
          <Route path="/payroll/:id" element={<PayrollRunPage />} />
          <Route path="/employees/:id" element={<EmployeeProfilePage />} />
          <Route path="/org-chart" element={<OrgChartPage />} />
          <Route path="/announcements" element={<AnnouncementsPage />} />
          <Route path="/hr-reports" element={<HrReportsPage />} />
          <Route path="/hr-tasks" element={<HrTasksPage />} />
          <Route path="/my/payslips" element={<MyPayslipsPage />} />
          <Route path="/my/profile" element={<MyProfilePage />} />
          <Route path="/projects" element={<ProjectsPage />} />
          <Route path="/projects/:id" element={<ProjectView />} />
          <Route path="/settings" element={<SettingsPage />} />
          <Route path="/credit-notes" element={<CreditNotesPage />} />
          <Route path="/credit-notes/new" element={<CreditNoteEditor />} />
          <Route path="/credit-notes/:id/edit" element={<CreditNoteEditor />} />
          <Route path="/credit-notes/:id" element={<CreditNoteView />} />
          <Route path="/quotes" element={<QuotesPage />} />
          <Route path="/quotes/new" element={<QuoteEditor />} />
          <Route path="/quotes/:id/edit" element={<QuoteEditor />} />
          <Route path="/quotes/:id" element={<QuoteView />} />
          <Route path="/recurring" element={<RecurringPage />} />
          <Route path="/recruitment" element={<RecruitmentPage />} />
          <Route path="/appraisals" element={<AppraisalsPage />} />
          <Route path="/bank-reconciliation" element={<BankRecPage />} />
          <Route path="/budgets" element={<BudgetsPage />} />
          <Route path="/assets" element={<AssetsPage />} />
          <Route path="/assets/requests" element={<AssetRequestsPage />} />
          <Route path="/assets/audits" element={<AssetAuditsPage />} />
          <Route path="/assets/maintenance" element={<AssetMaintenancePage />} />
          <Route path="/assets/movements" element={<AssetMovementsPage />} />
          <Route path="/contracts" element={<ContractsPage />} />
          <Route path="/requests" element={<RequestsPage />} />
          <Route path="/requests/:id" element={<RequestView />} />
          <Route path="/advances" element={<AdvancesPage />} />
          <Route path="/advances/:id" element={<AdvanceView />} />
          <Route path="/petty-cash" element={<PettyCashPage />} />
          <Route path="/contracts/variations" element={<ContractListPage what="variations" />} />
          <Route path="/contracts/securities" element={<ContractListPage what="securities" />} />
          <Route path="/contracts/obligations" element={<ContractListPage what="obligations" />} />
          <Route path="/contracts/:id" element={<ContractView />} />
          <Route path="/assets/:id" element={<AssetView />} />
          <Route path="/hse" element={<HseDashboardPage />} />
          <Route path="/hse/incidents" element={<HseIncidentsPage />} />
          <Route path="/hse/incidents/:id" element={<HseIncidentView />} />
          <Route path="/hse/actions" element={<HseActionsPage />} />
          <Route path="/hse/talks" element={<HseSessionsPage />} />
          <Route path="/hse/talks/:id" element={<HseSessionView />} />
          <Route path="/hse/inductions" element={<HseInductionsPage />} />
          <Route path="/hse/inspections" element={<HseInspectionsPage />} />
          <Route path="/hse/inspections/:id" element={<HseInspectionView />} />
          <Route path="/hse/permits" element={<HsePermitsPage />} />
          <Route path="/hse/risks" element={<HseRisksPage />} />
          <Route path="/hse/obligations" element={<HseObligationsPage />} />
          <Route path="/hse/policies" element={<HsePoliciesPage />} />
          <Route path="/hse/sustainability" element={<HseSustainabilityPage />} />
          <Route path="/crm" element={<CrmPage />} />
          <Route path="/activities" element={<ActivitiesPage />} />
          <Route path="/sales-performance" element={<SalesPerformancePage />} />
          <Route path="/resources" element={<ResourcesPage />} />
          <Route path="/my" element={<MyWorkPage />} />
          <Route path="/approvals" element={<ApprovalsPage />} />
          <Route path="/customers/:id" element={<Customer360 />} />
          <Route path="/project-costs" element={<ProjectCostsPage />} />
          <Route path="/training" element={<TrainingPage />} />
          <Route path="/ledger" element={<GeneralLedgerPage />} />
          <Route path="/bank-cash" element={<BankCashPage />} />
          <Route path="/approvals-inbox" element={<ApprovalsInboxPage />} />
          <Route path="/audit" element={<AuditPage />} />
          <Route path="/import" element={<ImportPage />} />
          <Route path="/cases" element={<CasesPage />} />
          <Route path="/cases/:id" element={<CaseView />} />
          <Route path="/knowledge" element={<KnowledgePage />} />
          <Route path="/crm-dashboard" element={<CrmDashboard />} />
          <Route path="/campaigns" element={<CampaignsPage />} />
          <Route path="/partners" element={<PartnersPage />} />
          <Route path="/commissions" element={<CommissionsPage />} />
          <Route path="*" element={<Navigate to="/" replace />} />
        </Routes>
      </div></main>
    </div>
  );
}

function NotConfigured() {
  return <div className="center"><div className="card">
    <div className="brand">{isWhiteLabel ? <><div className="mark">{BRAND_MARK}</div><b>{BRAND}</b></> : <Logo size={36} />}</div>
    <h1 style={{ fontSize: 20 }}>Connect your database</h1>
    <p className="muted" style={{ margin: 0 }}>Set <code>VITE_SUPABASE_URL</code> and <code>VITE_SUPABASE_ANON_KEY</code> in <code>.env.local</code> (or in Cloudflare Pages environment variables), then reload. The setup guide walks through it.</p>
  </div></div>;
}

/** A signed-in person with no company: a field worker linked as an employee gets the mobile screen; everyone else sets up a company. */
function NoCompany() {
  const [mode, setMode] = useState<'loading' | 'work' | 'setup'>('loading');
  useEffect(() => {
    supabase.rpc('my_work').then(({ data }) => setMode((data as any)?.employees?.length ? 'work' : 'setup'), () => setMode('setup'));
  }, []);
  if (mode === 'loading') return <div className="center muted">Loading…</div>;
  if (mode === 'setup') return <Onboarding />;
  return <main style={{ padding: '16px' }}>
    <div className="wrap" style={{ maxWidth: 640 }}>
      <div className="head"><div className="brand"><LogoMark size={34} radius={14} /><b>My time & expenses</b></div>
        <div className="actions"><button className="btn small" type="button" onClick={() => setMode('setup')}>Set up a company</button>
          <button className="btn small" type="button" onClick={() => supabase.auth.signOut()}>Sign out</button></div></div>
      <MyWorkPage standalone />
    </div>
  </main>;
}

/** Unread notifications, refreshed every minute and whenever they are read. */
function useUnread(uid?: string) {
  const [n, setN] = useState(0);
  useEffect(() => {
    if (!uid) return;
    let live = true;
    const load = async () => { const { count } = await supabase.from('notifications').select('id', { count: 'exact', head: true }).eq('user_id', uid).is('read_at', null); if (live) setN(count || 0); };
    load();
    const t = window.setInterval(load, 60000);
    window.addEventListener('asnys:notes', load);
    return () => { live = false; window.clearInterval(t); window.removeEventListener('asnys:notes', load); };
  }, [uid]);
  return n;
}

/** The first screen while the app checks the sign-in. If that takes too long, offer a way out instead of spinning forever. */
function Starting() {
  const [slow, setSlow] = useState(false);
  useEffect(() => { const t = setTimeout(() => setSlow(true), 8000); return () => clearTimeout(t); }, []);
  const restart = async () => {
    try { Object.keys(localStorage).filter(k => k.startsWith('sb-')).forEach(k => localStorage.removeItem(k)); } catch { /* storage unavailable */ }
    location.reload();
  };
  return <div className="center muted" style={{ flexDirection: 'column', gap: 12, textAlign: 'center' }}>
    <span>Loading…</span>
    {slow && <><span style={{ fontSize: 14 }}>This is taking longer than usual. Check your internet connection, then try again.</span>
      <div className="actions" style={{ justifyContent: 'center' }}>
        <button className="btn" type="button" onClick={() => location.reload()}>Try again</button>
        <button className="btn primary" type="button" onClick={restart}>Sign in again</button></div></>}
  </div>;
}
