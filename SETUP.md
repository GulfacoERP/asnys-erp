# Asnys ERP — Setup Guide

## What you need

You can have Asnys ERP live on the internet in about an hour, using three free accounts and these project files.

| Item | Why | Cost to start |
| --- | --- | --- |
| [Supabase](https://supabase.com) account | Database, logins and security | Free plan |
| [GitHub](https://github.com) account | Stores the code so Cloudflare can build it | Free |
| [Cloudflare](https://dash.cloudflare.com) account | Hosts the web app at a public address | Free (commercial use allowed) |
| [Node.js](https://nodejs.org) 20 LTS or newer | Only needed to run or change the app on your own computer | Free |

What is in the project:

- `supabase/migrations/0001_asnys.sql` — the core database: tables, security rules, Ghana tax engine and posting logic.
- `supabase/migrations/0002_asnys_v1_1.sql` — the v1.1 features (run after 0001).
- `supabase/migrations/0003_asnys_v1_2.sql` — the v1.2 features, including the private `receipts` storage bucket (run after 0002).
- `supabase/migrations/0004_asnys_v1_3.sql` — v1.3: project manager role and project workspace, customer 360, campaigns, partners, commissions, forecast, support cases and the public help centre, plus the private `project-docs` bucket (run after 0003).
- `supabase/migrations/0005_asnys_v1_4.sql` — v1.4: project purchase requests, committed cost, project tags in the ledger, project cost report and budget alerts, and HR training (run after 0004).
- `supabase/migrations/0006_asnys_v2_0.sql` — v2.0 for growing companies: branches and cost centres, approval chains, audit trail, bank and cash, opening balances, general ledger and books checks (run after 0005).
- `supabase/migrations/0007_asnys_v2_1.sql` — v2.1: inventory with several stores, purchase orders and goods received, stock issued to projects, transfers, stocktakes, supplier records, and the project lifecycle (start, hold, complete, close) (run after 0006).
- `supabase/migrations/0008_asnys_v2_2.sql` — v2.2: project site stores run by the project team, stock requests with goods in transit, materials plan, document register with revisions, reviews and transmittals, risk assessments and required documents (run after 0007).
- `supabase/migrations/0009_asnys_v2_3.sql` — v2.3: project cycle and financial control: tenders with pre-submission review, Finance registration and budget approval before any spending, progress reports, milestone certification, invoice follow-up, financial clearance, notifications (run after 0008).
- `supabase/migrations/0010_asnys_v2_4.sql` — v2.4: contract payment terms, payment schedules, due dates from the contract and payment reminders (run after 0009).
- `supabase/migrations/0011_asnys_v2_5.sql` — v2.5: staff invitations by email, sign-in status, password resets (run after 0010).
- `supabase/migrations/0012_asnys_v2_6.sql` — v2.6: contract management, asset check-out, audits and requests (run after 0011).
- `supabase/migrations/0013_asnys_v2_7.sql` — v2.7: spend requests, staff cash advances, petty cash floats, purchase orders in other currencies (run after 0012).
- `supabase/migrations/0014_asnys_v2_8.sql` — v2.8: projects on hold until further notice, new clients from the project form (run after 0013).
- `supabase/migrations/0015_asnys_v2_8_1.sql` — v2.8.1: one link between tenders and projects, which fixes "more than one relationship was found for 'tenders' and 'projects'" on the Tenders page (run after 0014).
- `supabase/migrations/0016_asnys_v2_9.sql` — v2.9: HSE & Compliance — incidents and investigation, corrective actions, toolbox talks and inductions, inspections, permits to work, compliance register, policies, sustainability (run after 0015).
- `supabase/migrations/0019_asnys_v3_1_1.sql` — v3.1.1: fleet reminders to owners and admins too, statutory inspections, choose how far ahead (run after 0018).
- `supabase/migrations/0018_asnys_v3_1.sql` — v3.1: Assets (locations, transfers, site requests, consumables, licences, Telegram alerts) and Fleet & Logistics (vehicles and papers, drivers, trips, fuel, service, vehicle requests, waybills, reports) (run after 0017).
- `supabase/migrations/0017_asnys_v3_0.sql` — v3.0: HR and payroll: pay components, back pay, off-cycle runs, self-service payslips and profile, employee history, documents, onboarding and exit, Ghana public holidays, leave accrual and manager approval, announcements, org chart, HR reports, annual PAYE return (run after 0016).
- `supabase/functions/invite-member/` — the Supabase function that emails invitations (see "What's new in v2.5").
- `docs/` — this guide and the product plan as PDFs.
- `src/` — the web app (React and TypeScript).
- `scripts/test-db.mjs` — 381 automatic checks of the money logic.
- `.env.example` — where your Supabase keys go.

The free Supabase plan is for building and pilots. Before your first paying client goes live, move to the paid plan so the database never pauses and is backed up daily.

## Set up the database (steps 1–3)

**Step 1 — Create the Supabase project**

1. Sign in at supabase.com and choose **New project**.
2. Name it `asnys-erp`, set a strong database password and store it safely.
3. Pick the region closest to Ghana from the list, then **Create new project**.

**Step 2 — Run the database script**

**New installation (quickest):** the folder `supabase/setup/` holds the same 13 files combined into three parts.

1. Open **SQL Editor → New query**, paste all of `part1_of_3.sql` and choose **Run**. Wait for "Success. No rows returned".
2. Open a new query and do the same with `part2_of_3.sql`, then `part3_of_3.sql`.
3. Check **Table Editor**: you should see tables such as `companies`, `accounts`, `invoices` and `contracts`.

If the editor struggles with a large paste, use the separate files instead:

1. Open **SQL Editor → New query**.
2. Open `supabase/migrations/0001_asnys.sql` in a text editor, copy everything, paste it into the query box.
3. Choose **Run**. You should see a success message.
4. Open a new query and do the same with `0002_asnys_v1_1.sql`, then `0003_asnys_v1_2.sql`, then `0004_asnys_v1_3.sql`, then `0005_asnys_v1_4.sql`, then `0006_asnys_v2_0.sql`, then `0007_asnys_v2_1.sql`, then `0008_asnys_v2_2.sql`, then `0009_asnys_v2_3.sql`, then `0010_asnys_v2_4.sql`, then `0011_asnys_v2_5.sql`, then `0012_asnys_v2_6.sql`, then `0013_asnys_v2_7.sql`, then `0014_asnys_v2_8.sql`, then `0015_asnys_v2_8_1.sql`, then `0016_asnys_v2_9.sql`, then `0017_asnys_v3_0.sql`, then `0018_asnys_v3_1.sql`, then `0019_asnys_v3_1_1.sql`. Run each file once per project, in number order.

**Upgrading an installation you already have:** run only the files you have not run yet, in number order (each "What's new" section below names its file). Never run a file twice, and never run the `setup/` parts on a database that already has Asnys in it.

**Step 3 — Copy your keys and set sign-in options**

1. **Project Settings → API**: copy the **Project URL** and the **anon public** key.
2. Never put the **service_role** key in the app or share it; it bypasses all security.
3. **Authentication → URL Configuration**: set **Site URL** to `http://localhost:5173` for now; change it after step 6.
4. Leave email confirmation on for live use, and add your own SMTP sender under **Authentication → SMTP Settings** before going live (the built-in sender is rate-limited).

Menu names in Supabase and Cloudflare change from time to time; if a label differs slightly, look for the nearest match.

## Run and publish the app (steps 4–6)

**Step 4 — Try it on your computer (optional)**

```bash
npm install
cp .env.example .env.local     # Windows: copy .env.example .env.local
```

Put your two values in `.env.local`:

```bash
VITE_SUPABASE_URL=https://your-project-ref.supabase.co
VITE_SUPABASE_ANON_KEY=your-anon-public-key
```

Then `npm run dev` and open http://localhost:5173.

**Step 5 — Put the code on GitHub**

Create a **private** repository named `asnys-erp`, then either upload the folder contents (leave out `node_modules`, `dist` and `.env.local`) or:

```bash
git init
git add .
git commit -m "Asnys ERP"
git branch -M main
git remote add origin https://github.com/YOUR-NAME/asnys-erp.git
git push -u origin main
```

**Step 6 — Publish on Cloudflare Pages**

1. Cloudflare dashboard → **Workers & Pages → Create → Pages → Connect to Git** → pick `asnys-erp`.
2. Build settings:

| Setting | Value |
| --- | --- |
| Framework preset | Vite (or None) |
| Build command | `npm run build` |
| Build output directory | `dist` |
| Environment variable | `VITE_SUPABASE_URL` = your Project URL |
| Environment variable | `VITE_SUPABASE_ANON_KEY` = your anon key |
| Environment variable | `NODE_VERSION` = `20` |
| Optional | `VITE_BRAND_NAME`, `VITE_BRAND_MARK` for a copy branded for one company (see "Showing a client company's own name") |

3. **Save and Deploy**. You get an address like `https://asnys-erp.pages.dev`.
4. In Supabase **Authentication → URL Configuration**, set **Site URL** to that address and add it and `http://localhost:5173` under **Redirect URLs**.
5. Optional: add your own domain under the Pages project's **Custom domains**, then update the Site URL.

Every push to `main` redeploys automatically. After changing environment variables, trigger a new deployment.

## First sign-in and company set-up (step 7)

- [ ] Open the app, **Create an account**, confirm the email, sign in.
- [ ] Enter company name, TIN, town and phone. A Ghana chart of accounts is created automatically.
- [ ] **Settings & team**: address, bank and Mobile Money details for invoices.
- [ ] **Journal → Manual journal**: opening bank, cash and MoMo balances (debit each, credit 3000 Owner's capital), plus opening debtors or creditors.
- [ ] **Inventory → Items & stock**: add items (or import them), then **Adjust → Opening stock**. Add any extra stores under **Stores & sites**.
- [ ] Add **Customers**, **Suppliers** and **Employees**.
- [ ] Deploy the invite function and set up SMTP ("What's new in v2.5"), then invite colleagues by email under **Settings & team** or **HR → Employees**.
- [ ] Post a first invoice and download its PDF to check your details.

| Action in the app | What it posts to the ledger |
| --- | --- |
| Post a sales invoice | Dr receivables; Cr sales/service revenue, VAT 15%, NHIL 2.5%, GETFund 2.5%; Dr cost of sales, Cr inventory at average cost |
| Record a customer payment | Dr cash, MoMo or bank; Cr receivables |
| Post a supplier bill | Dr inventory or expense; Dr VAT, NHIL, GETFund input (recoverable under Act 1151); Cr payables |
| Pay a supplier | Dr payables; Cr bank, MoMo or cash |
| Post payroll | Dr salaries and employer SSNIT; Cr PAYE, SSNIT Tier 1, Tier 2 and net salaries payable |
| Mark salaries paid | Dr net salaries payable; Cr bank, MoMo or cash |
| Stock adjustment | Dr/Cr inventory against stock adjustments (or owner's capital for opening stock) |

Posted documents are locked; correct them with a manual journal or a new document. Drafts can be edited or deleted.

## Monthly routine and downloads

1. **Payroll** → month → **Prepare payroll** → check → **Approve and post**.
2. Download **All payslips (PDF)** and the **Bank / MoMo payment list CSV**; pay staff; **Mark salaries paid**.
3. Download the **PAYE schedule** (file with GRA by the 15th of the next month) and the **SSNIT schedule** (Tier 1, 13.5%, to SSNIT within 14 days of the next month; Tier 2, 5%, to your trustee).
4. **Reports → VAT return → Last month** → download for the GRA VAT return.
5. Record payments to GRA or SSNIT with **Journal → Manual journal** (debit the payable, credit 1100 Bank).
6. Download **Trial balance**, **Profit and loss** and **Balance sheet**.

| Where | PDF | CSV |
| --- | --- | --- |
| Invoice page | Tax invoice with VAT, NHIL, GETFund and payments | — |
| Bill page | Supplier bill with input tax and payments | — |
| Customers / Suppliers | Statement of account per party; full list | Full list |
| Invoices / Bills lists | Register with tax columns and totals | Same |
| Inventory | Stock valuation by store; stock card per item; purchase orders, goods received notes and stores issue notes | Same |
| Payroll month | Each payslip; all payslips; PAYE schedule; SSNIT schedule | PAYE, SSNIT, bank/MoMo payment list |
| Reports | Profit and loss, balance sheet, trial balance, VAT return, debtors ageing | Same |
| Journal / Chart of accounts | General journal; account balances | Same |
| Employees / Leave | Staff list; leave register | Same |
| Projects | Project list; timesheet per project | Same |

PDFs show amounts in GHS because standard PDF fonts have no cedi sign; the screens use GH₵.

## What's new in v1.1

If you already ran 0001, just run 0002 in the SQL Editor; existing data is kept.

| Feature | Where | What it does in the books |
| --- | --- | --- |
| Credit notes | Sales → Credit notes, or **Credit note** on a posted invoice | Reverses sales and output VAT/NHIL/GETFund; optionally returns stock at cost; reduces the invoice balance |
| Invoice reversal | **Reverse invoice** on a posted invoice | Full credit note in one step, all stock returned |
| Quotes and sales orders | Sales → Quotes & orders | No posting; **Convert to invoice** creates a draft invoice |
| Recurring invoices | Sales → Recurring invoices | Creates due invoices (drafts, or posted automatically) when the dashboard opens or you press Generate |
| Multi-currency | Settings → Foreign currencies; currency on documents | Ledger always in GH₵ at the document rate; payment differences go to 4800 Foreign exchange gains and losses |
| Overtime tax | Payroll month → Overtime and bonuses; **Junior staff** on the employee | 5% up to half of monthly basic, 10% above, for junior staff earning up to GH₵18,000 a year; others through PAYE |
| Bonus tax | Same panel | 5% up to 15% of annual basic (cumulative for the year); excess through PAYE |
| Tier 3 pension | Employee → Tier 3 % fields | Deducted before PAYE, relieved up to 16.5% of monthly income; posted to 2230 |
| Staff loans | Payroll → Staff loans | Paid out to 1250; repaid automatically through payroll |
| Leave balances | Leave → Balances, Leave types | Annual leave defaults to 15 working days; adjust per employee |
| Recruitment, appraisals | People → Recruitment, Appraisals | Openings, applicants, hire into Employees; reviews with a signable PDF |
| Bank reconciliation, budgets, period lock | Accounting → Bank reconciliation, Budgets; Settings → Lock the books | Match statements and download the report; budget vs actual; block postings on or before the lock date |

Add to the monthly routine: reconcile bank and MoMo, then lock the month once the VAT return is filed. Accountants can open **Settings & team** for currencies and the lock date.

## What's new in v1.2

If you already ran 0001 and 0002, run only 0003.

| Feature | Where | What it does in the books |
| --- | --- | --- |
| Fixed asset register | Assets → Fixed assets → Register asset | Tags (AST-00001), location, custodian; Dr 1600, Cr bank/MoMo/cash/payables/capital |
| Depreciation | Fixed assets → Run depreciation | Straight line or reducing balance; one journal per run (Dr 6700, Cr 1610); never double-charges a month |
| Moves, maintenance, disposal | An asset's page | Movement history and service log; sale or write-off posts the gain or loss to 4850 |
| Leads and pipeline | CRM → Leads & pipeline | Leads convert to customers with a deal; six stages; **Quote** creates a quotation |
| Activities and field visits | CRM → Activities & visits | Calls, meetings, WhatsApp; **Check in with my location** on a phone |
| Sales force automation | CRM → Sales performance; customer owner and territory | Monthly targets vs invoiced sales net of credits, weighted pipeline, wins, activities, visits |
| Group of companies | Settings → Group of companies | Links subsidiaries you administer; each keeps its own books |
| Global resource management | Projects → Resource planner | Search staff across the group by skill, location and dates; availability after bookings and leave; assign with allocation and bill rate; salaries never shown |
| Multi-currency project billing | Project → Bill the client in; **Invoice approved work** | Approved hours × rate and re-billable expenses invoiced in the client's currency |
| Mobile time and expenses | My time & expenses (add to the phone's home screen) | Hours and expenses in any currency with receipt photos; approve under Projects → Approvals; Dr expense, Cr 2240; **Reimburse** pays |

To use **My time & expenses**, a person creates a login and HR enters that email as **Sign-in email** on their employee record. People from a sister company need only an assignment, not a membership. Android: Chrome → **Add to Home screen**. iPhone: Safari Share → **Add to Home Screen**.

Monthly: approve hours and expenses, invoice project work, reimburse staff, then run depreciation before closing. Book depreciation is separate from tax capital allowances.

## What's new in v1.3

If you already ran 0001 to 0003, run only 0004. Then in **Settings & team**, give your project leads the new **Project manager** role.

**Project management (modelled on NetSuite Project Management)**

| Feature | Where | What it does |
| --- | --- | --- |
| Project center | Projects → Project center | Every project with health, % complete, cost vs budget, invoiced, unbilled, forecast margin and open issues; **Only projects I manage**; PDF and CSV |
| Templates | Project center → Templates | A standard plan (tasks with estimates and dependencies, budget, billing milestones); **From template** copies it with dates shifted |
| Plan and Gantt | A project → Plan | Timeline with bars, key dates, dependency arrows and a today line; tasks cannot start before the task they depend on ends |
| Budget and forecast | A project → Budget | Cost and revenue budget by category vs actuals (labour at cost rate, expenses, supplier bills tagged to the project); what-if forecast |
| Billing | A project → Billing | Fixed-price milestones become **Ready to bill** when their task is done; **Invoice** drafts the invoice; time-and-materials billing of approved work |
| Issues, updates, documents | A project's tabs | Issue, risk and change-request log; weekly status updates with health; files up to 20 MB |
| Status report | A project → **Status report PDF** | One-page report for the client or sponsor |
| Order to project | A sales order → **Create project** | Fixed-price project with tasks from the order lines, optionally copying a template |
| Project costs on bills | Supplier bill → Project column | Materials and subcontractors land on the project's actual cost |
| Project manager role | Settings & team | Runs only the projects they manage: plan, budget, team, approvals and billing. Cannot see the ledger or salaries |

**CRM (modelled on NetSuite CRM)**

| Feature | Where | What it does |
| --- | --- | --- |
| Customer 360 | Customers → click a name | Lifetime sales, gross profit, balance and overdue, days to pay, pipeline, top products, contacts (with WhatsApp), invoices, quotes, deals, cases, projects, activities |
| Lead scoring | Leads & pipeline → Leads | Score out of 100 from contact details, deal size, source, partner, status and completed calls; **Sales-ready** flag at your threshold (Campaigns → Lead scoring) |
| Campaigns | CRM → Campaigns | Cost, leads, sales-ready, won value, cost per lead and ROI per radio slot, WhatsApp blast or event; leads CSV |
| Partners | CRM → Partners | Resellers and agents linked to leads and customers; their invoices carry the partner automatically |
| Commissions | CRM → Commissions | Rep and partner commission on net invoiced sales; **Post accrual** (Dr 6150, Cr 2250) once per period |
| Forecast | Sales performance & forecast | Six months of quota, invoiced, commit, weighted pipeline, best case and gap |
| CRM dashboard | CRM → CRM dashboard | Sales, marketing and service in one view |
| Support cases | Customer service → Support cases | CASE-00001 numbers; assign, prioritise, reply, internal notes, knowledge base answers; first-reply and resolution times; case PDF |
| Help centre | Customer service → Knowledge base → **Switch on** | Public page at `/help/<company id>`: answers, **Contact us**, **Track my case** with a code, replies and a 1–5 rating. No login needed |

The help centre link is safe to share. Customers see only published articles and their own case, and only with its code. Sending is rate-limited.

## What's new in v1.4

If you already ran 0001 to 0004, run only 0005.

**Project costs and budget control**

| Feature | Where | What it does |
| --- | --- | --- |
| Purchase requests | A project → Purchases → **Raise request** | Anyone on the project asks for materials, a subcontractor service, equipment hire or any other expense, with quantity, estimated cost, supplier and date needed (PR-00001) |
| Budget-checked approval | Purchases → **Approve** | The project manager approves requests that fit in the cost budget; anything that takes the project over budget needs an accountant or the owner |
| Committed cost | Budget tab, Project center, Purchases | Approved requests count against the budget at once, before the supplier invoices |
| Request to bill | Purchases → tick approved requests → **Create bill** | One draft supplier bill, every line tagged to the project; enter the real prices and post. Delete the draft and the requests go back to approved |
| Any other expense | Journal → **Manual journal** → Charge to project | Fuel, petty cash, accruals or reallocations charged to a project |
| Project tags in the ledger | Journal | Bill lines, expense claims and manual journals carry the project on the ledger line |
| Project costs report | Accounting → Project costs | Budget position per project (spent, committed, left, forecast, Within / Near limit / Over budget); every cost line with its source document and account; totals by ledger account to tie to the Journal. PDF and CSV |
| Budget alerts | Dashboard | Projects at 90% of their cost budget, over it, forecast to go over, or spending on a cost type with no budget. Accountants see all; a project manager sees their own |

Labour on projects is approved hours × each person's cost rate. It is a management cost: payroll posts salaries to the ledger in total, not by project.

**HR training (separate from projects)**

| Feature | Where | What it does |
| --- | --- | --- |
| Training requests | People → Training → **Request training** | Staff ask for themselves; managers and HR ask for anyone; reason, provider, estimated cost, preferred date and priority (TR-00001) |
| Approval | Training → Requests | HR approves or rejects with a note the requester sees |
| Sessions | Training → Sessions | Courses, certifications, safety inductions and workshops with dates, hours, cost and how long the certificate is valid; schedule approved requests onto a session; attendance PDF |
| Results and certificates | A session | Enrolled, attended, passed, failed or absent; score; certificate number; expiry worked out automatically |
| Employee records | Training → Employee records | Every training each employee has received, with hours, results and certificates; PDF and CSV per employee or for everyone |
| Expiring certificates | Training → Certificates | Expired or expiring within 60 days, with **Request renewal** |
| Training cost | A session → **Create bill** | Draft supplier bill to 6450 Staff training for the accountant to post |

Staff see only their own requests and training history; HR sees everyone.

## What's new in v2.0 — Asnys ERP

Sika ERP was renamed **Edwuma ERP** (now **Asnys ERP**). Version 2.0 is built for companies of 100 staff and more, with several branches. If you already ran 0001 to 0005, run only 0006. (The migration files were renamed `000x_edwuma…`, and later `000x_asnys…`; they are the same files, so do not run them again.)

**Every transaction in the books**

| Feature | Where | What it does |
| --- | --- | --- |
| General ledger | Accounting → General ledger | Any account, any period: opening balance, every line with running balance, branch, cost centre and project, and a link to the invoice, bill, payroll or other document behind it. Filter by source, branch, cost centre, project or text. PDF and CSV |
| Books check | General ledger → Books check | Proves the ledger agrees with the documents: trial balance; receivables vs unpaid invoices less unused credit notes; payables vs unpaid bills; stock vs quantity × cost; salaries payable; expense claims payable; fixed assets vs the register |
| Not in the books yet | General ledger → Not in the books yet | Draft invoices, bills and credit notes, unposted payroll, claims and hours awaiting approval, approved purchases not billed, approval steps waiting. Clear it before locking a month |
| Bank and cash | Accounting → Bank & cash | Money in (other income, owner's capital, loans received), money out (bank charges, fuel, petty cash, loan repayments, drawings) and transfers between bank, MoMo and cash. Each posts a journal; Void posts a reversal |
| Bank accounts | Chart of accounts → edit an asset account | Tick "bank, cash or MoMo account" for each extra bank account (e.g. 1110 Ecobank) |
| Opening balances | Company → Import from spreadsheet | Opening trial balance (any difference to 3050 Opening balance equity), customer balances as open invoices, supplier balances as open bills, opening stock |

**Growth features**

| Feature | Where | What it does |
| --- | --- | --- |
| Branches and cost centres | Settings → Branches and cost centres; on invoices, bills (per line), employees, projects, journals, bank & cash | Every ledger line carries them. Payroll cost is split by each employee's branch and cost centre. Reports → **By branch / cost centre** gives profit and loss side by side; every report can be filtered to one branch or cost centre |
| Approval chains | Settings → Approval rules; Overview → Waiting for my approval | Steps by amount for supplier bills, payroll, purchase requests and expense claims (e.g. Accountant from GH₵0, Managing director from GH₵20,000). A bill or payroll cannot post until approved; if the amount goes up it must be approved again; one person cannot approve two steps; rejections need a reason |
| Audit trail | Accounting → Audit trail | Every create, change and delete on customers, suppliers, products, staff (including salaries), invoices, bills, payments, payroll, bank & cash, chart of accounts, team and roles, settings and approvals — who, when, old and new values. Owners, admins and accountants only; nobody can edit it |
| Import from spreadsheet | Company → Import from spreadsheet | Customers, suppliers, products with opening stock, employees and the opening trial balance from Excel (.xlsx) or CSV. Download the template, fill it, check the preview (every row is validated), then import |
| Fast long lists | Invoices, bills, customers, suppliers, journal | Search and paging run in the database, so lists stay quick with years of data; downloads still include every matching row |
| Salary payment files | Payroll run → Downloads | Bank transfer file and MoMo bulk file, using each employee's pay method, bank, branch and account |
| Work sign-in | Sign-in page | "Microsoft 365" and "Google Workspace" buttons (see below) |
| API | Settings → Connect other systems | How POS tills, websites and BI tools read and write data through the REST API with the same security rules |

**Turn on Microsoft 365 or Google sign-in (optional)**

1. Supabase → **Authentication → Providers** → Azure (Microsoft) or Google → enable it and paste the client ID and secret from the Azure portal (App registrations) or Google Cloud console (OAuth client). Use the redirect address Supabase shows there.
2. In Cloudflare Pages → Settings → Environment variables add `VITE_SSO_PROVIDERS` = `azure` or `google` or `azure,google`, then redeploy.
3. Add each person under Team with their work email as usual; the first time they use the button, Asnys links their work account to that email.

**Hosting a company of 100 staff or more**

- Give the company its own Supabase project (run all ten files in it) on the **Pro** plan, so it never pauses and is backed up daily.
- Add **Point-in-time recovery** so you can rewind to any minute in the last 7 days.
- Start on the Small database server; move to Medium or Large under Settings → Compute when the dashboard shows high CPU at month-end.
- For heavy reporting at very large companies, add a **read replica** in Supabase and point BI tools at it.
- Before go-live: import the opening balances, run General ledger → **Books check** and make sure every row says **Agrees**.

## What's new in v2.1 — inventory, purchasing and the project lifecycle

If you already ran 0001 to 0006, run only `0007_asnys_v2_1.sql`. Existing stock moves into a store called **MAIN · Main store**; existing projects keep their status.

**Inventory**

| Feature | Where | What it does |
| --- | --- | --- |
| Items | Inventory → Items & stock | Stock items, items bought for use but not stocked, and services. Category, barcode, brand, unit, selling price, average cost, reorder level and quantity, maximum level, usual supplier. Search by name, code, barcode or brand |
| Stores and sites | Inventory → Stores & sites | Any number of stores: main warehouse, branch shops, a store on a project site, a delivery van. Stock is tracked per store, with a bin or shelf for each item |
| Stock by store | Inventory → Stock by store | Every item against every store in one grid |
| Stock card | Click an item | Every movement in and out (received, sold, issued to a project, returned, transferred, counted) with a running balance, linked to the document. PDF and CSV |
| Reorder list | Inventory → Reorder list | Items at or below their reorder level after counting what is already on order. Tick items and press **Purchase order for selected** |
| Valuation | Inventory → Valuation | Quantity × average cost by store, what is on order, last movement; slow movers highlighted. Agrees with account 1300 (General ledger → Books check) |
| Transfers | Inventory → Transfers | Move stock between stores. The store cannot send more than it holds. No effect on the books |
| Stocktakes | Inventory → Stocktakes | Start a count for a store (all items or one category), print a blank count sheet, type in what was found, then an accountant posts the differences to 5100 Stock adjustments |

**Buying from suppliers: request → order → receive → bill**

1. **Purchase order** (Purchasing → Purchase orders → New, or from the reorder list, or from approved project purchase requests). Choose the supplier, delivery date and where it goes: one of your stores, or **straight to a project site**. Prices fill in from the supplier's price list. Download the order PDF and send it.
2. **Approve.** An accountant approves it. If you set approval rules for purchase orders (Settings → Approval rules), the chain must finish first.
3. **Receive goods** when the delivery arrives. The storekeeper enters what actually came (part deliveries are fine) and the supplier's delivery note number; a goods received note (GRN) is created with a PDF. Stock goes up in the store, or, for site deliveries, the cost goes straight to the project. The value sits in **2050 Goods received not yet invoiced** until the bill arrives.
4. **Bill from order** when the supplier's invoice arrives. The bill fills in what was received at the order price. If the supplier charged a different price, change it on the bill; the difference goes to **5150 Purchase price variance** (and to the project for project lines). The bill can never count the same goods twice.
5. **Pay** the bill as usual.

Supplier page (click a supplier): what you owe and what is overdue, spend over 12 months, open orders, on-time delivery %, average lead time, the agreed price list, every order and bill, and a statement PDF.

**Materials on projects**

| How | Where | Cost to the project | Billing the client |
| --- | --- | --- | --- |
| From your own store | Project → Materials → **Issue from store** (or Inventory → Issues to projects) | When issued, at average cost, tagged to the project in the ledger (5200) | Tick **Bill client** and set the price; it goes on the next project invoice |
| Unused materials back | Project → Materials → **Return to store** | Comes off the project at the same cost | Reduces what is billed |
| Ordered for delivery to site | Project → Materials → **Order for delivery to site**, or Purchases tab → select approved requests → **Purchase order from selected** | Committed when the order is approved; actual cost when the delivery is received | Tick **Re-bill to client** on the supplier bill line |

**Invoice time, expenses and materials** on the project's Billing tab now adds store materials (issues less returns) and re-billable supplier costs to the draft invoice.

**Project lifecycle: starting, tracking and closing a project**

| Stage | How you get there | What it means |
| --- | --- | --- |
| Not started | New project | Planning; time and purchases can still be booked |
| In progress | **Start project** (records the actual start date) | Work is under way. **Put on hold** (needs a reason) and **Resume work** as needed |
| Completed | **Mark work complete** (records the finish date, sets 100%) | Work is done; billing and paying the last costs continue |
| Closed | **Close project** | Locked: no more time, expenses, purchase requests, orders, stock issues, tasks or milestones. Figures stay in every report. An accountant can **Reopen** with a reason |
| Cancelled | **Cancel** (needs a reason) | Stopped before completion |

Before closing, a **close-out checklist** shows what must be cleared (time or expenses waiting for approval, billable work, materials or milestones not invoiced, open purchase requests, orders not fully received, draft bills or stock issues) and what is worth checking (unfinished tasks, open issues, goods received but not billed by the supplier, unpaid client invoices). An accountant can close anyway with a written reason, which is kept in the history.

**Is the project on schedule?** The project's Overview shows its stage, planned and actual dates, and a schedule bar: where it should be by today from its dates (the black mark) against its % complete, with "On schedule", "Behind by about N days" or "Past its end date". The Project center has tabs for each stage (Not started, In progress, On hold, Completed, Closed) with the same bar for every project. Every stage change is in the History list with who, when and why.

**New role: Storekeeper.** Items, stores, receiving deliveries, issuing to projects, transfers and stocktakes, supplier price lists. Cannot see the ledger, approve orders or post stocktake differences.

## What's new in v2.2 — site stores and project documents

If you already ran 0001 to 0007, run only `0008_asnys_v2_2.sql`. Files already uploaded to a project's Documents tab move into its new document register as "Other" documents, revision A, for information.

**A project's own site store**

| Feature | Where | What it does |
| --- | --- | --- |
| Set up a site store | Project → Materials & site store → **Set up a site store** | A store that belongs to the project. The project manager and everyone assigned to the project (Team tab) can work it; they cannot touch other stores |
| Request from store | Site store → **Request from store** | The site asks the main store for items and quantities, with a needed-by date. The store sees it under Inventory → **Requests from sites** (and on the dashboard) and presses **Send** |
| Goods in transit | Automatic | Sent stock leaves the main store and is held "in transit" (still company stock) until the site confirms it |
| Confirm received | Site store → **Confirm received** | The site enters what actually arrived. Anything short is written off as lost in transit (5100 Stock adjustments, tagged to the project) with a note of what happened |
| Deliveries straight to site | Purchase order → deliver to the site store | The project team can receive the delivery at site and print the GRN |
| Record usage | Site store → **Record usage** | Daily usage against a task. Charged to the project (5200) at average cost. The team can only issue from its own site store; anything else comes through the store |
| Send back | Site store → **Send back** | Unused stock returns to the main store or moves to another project's site store |
| Site counts | Site store → **Count site stock** | The team counts; the project manager posts differences up to a limit set in Settings (default GH₵1,000), an accountant above it. Shortages are charged to the project as wastage |
| Materials plan | Site store → **Edit plan** | Quantities the job needs (from the bill of quantities). Shows planned, used, at site, on the way, requested, wastage and left to use; usage over plan is flagged and warned when recording usage |
| Stock at every site | Inventory → Requests from sites | Value held at each project site; finished projects still holding stock are flagged |

Closing a project now needs the site store empty and all stock requests received or cancelled.

**Project document control**

| Feature | Where | What it does |
| --- | --- | --- |
| Document register | Project → Documents → Register | Every document has a type, a number (e.g. PRJ-00012-SD-0003), a title, discipline, owner, optional task and expiry date. 33 types in six groups: contract and scope, engineering, quality, health and safety, site, handover |
| Revisions | Open a document → **Upload new revision** | Rev A, B, C while in design; 0, 1, 2 once issued for construction. Older revisions are marked superseded and greyed out, so the team works from the current one. Photos over 1.5 MB are reduced on upload; other files up to 50 MB |
| Internal review | **Submit for review** → project manager **Approve** or **Reject** (with reason) | Types the client approves (shop drawings, method statements, submittals, calculations, RFIs, O&M manuals…) become "Ready to send"; others become "Approved". Files filed for information (photos, minutes) skip review |
| Transmittals | Documents → Transmittals | A numbered cover sheet (PDF) listing documents and revisions sent to the client or consultant, with purpose (for approval, comment, information, construction, record), reply due date (default 14 days, late ones shown in red) and each reply: approved, approved with comments, rejected (revise and resubmit), noted. Only reviewed documents can be sent; only approved ones can be issued for construction |
| History | Open a document | Who uploaded, reviewed and sent each revision, when, and the client's comments |
| Confidential | Tick when adding | Only the project manager, accountants, owners and the person who added it can see it |
| Expiry alerts | Documents page and dashboard | Permits, insurances, warranties and certificates expired or expiring within 30 days (14 on the dashboard) |
| Search | Projects → Documents | Every document across all projects by number, title, file name or discipline; filter by type, status or project; CSV |
| Audit | Accounting → Audit trail | Every document, revision, transmittal and risk assessment change, and every time a file is opened |

**Risk assessments**

Project → Documents → Risk assessments. Each assessment (RA-00001) lists hazards with what could happen, who is at risk, likelihood and severity from 1 to 5 (score 1–4 low, 5–12 medium, 15–25 high), control measures, owner, and the rating after controls, with a 5 × 5 risk matrix. Every hazard needs controls and every high risk needs a rating after controls. The project manager and the project's health and safety officer (chosen on the same screen) sign it; once both have signed it is locked, and **Revise** starts a new version with the reason recorded. PDF for the site file.

**Required documents**

Project → Documents → Required documents. **Use standard list** asks for an approved risk assessment and method statement before work starts, and as-built drawings, O&M manuals, test certificates and the handover certificate before closing. Add or remove any type. Starting a project warns about missing start documents; missing close documents stop the project from closing. Set the list on a template and every project made from it gets it, along with the template's materials plan.

**Permissions in short**

| Who | Site store | Documents |
| --- | --- | --- |
| Project manager | Everything for their project's site store; post site counts up to the limit; edit the materials plan | Add, review and approve, send transmittals, delete unused documents, set required documents and the HSE officer, sign risk assessments |
| Project team (assigned on the Team tab) | Request stock, confirm deliveries, record usage, send back, count | Add documents and revisions, submit for review, send transmittals and record replies, write risk assessments; HSE officer signs |
| Storekeeper | Send requested stock to sites; any store | Read |
| Other staff | Read | Read (not confidential documents) |


## What's new in v2.3 — project cycle management and financial control

This release puts the Project Management Meeting's decisions into the system. The guiding rule: **no project exists operationally without also existing in Finance's monitoring.** If you already ran 0001 to 0008, run only `0009_asnys_v2_3.sql`. Projects that already exist count as registered with an approved budget, so nothing in progress is blocked.

The units map to roles: **Business Development** = Sales role, **Finance** = Accountant role, **Engineering** = Project manager role. Owners and admins can act for any unit.

**The five stages**

| Stage | What happens in Asnys | Who |
| --- | --- | --- |
| 1. Tender and business development | Projects → **Tenders** → Register tender: client, reference, deadline, estimated value and cost (margin), bid bond, engineering and finance leads, files. Finance and Engineering are notified at once. **Schedule pre-submission review**: date, summary report shared on, attendees. Each unit records its input and **signs off**; the decision is Go, Revise or No go. A tender can be marked **submitted** only after all three units have signed a Go. Changing any input clears the signatures | Business Development registers; all three units review |
| 2. Contract award and registration | **Record award**: contract, client PO or letter of award, number, date, value, signed copy. Finance and Engineering are notified. Finance presses **Register project**: project code, cost centre, project manager, dates, contract value. Record the **post-award meeting** (execution and each unit's role) on the tender or the project | Business Development records the award; Finance registers; Management holds the meeting |
| 3. Execution and cost monitoring | The project manager enters the budget and presses **Submit budget**; Finance **approves** or returns it. **Nothing can be spent on a project until Finance has registered it and approved its budget**: purchase requests, purchase orders, supplier bill lines, stock issues, stock requests and expense claims are refused. Changing an approved budget sends it back as a revision. Engineering submits **progress reports** (work done, milestones reached, purchases and commitments coming up with their value, issues) weekly, fortnightly or monthly by the 5th; Finance is notified and marks them read; late reports are flagged. Finance records a **cost reconciliation** per period (ledger total vs cost report, agreed or adjusted with the journal numbers) | Engineering reports; Finance captures, allocates and reconciles |
| 4. Milestones and invoicing | The project manager **certifies** a milestone with evidence (client sign-off, inspection) on Progress & meetings. Finance is notified automatically and the milestone moves to the top of the **billing schedule** (Project cycle page), which also shows uncertified milestones due in 30 days and approved time and materials not yet invoiced | Engineering certifies; Finance invoices |
| 5. Receivables and closure | Every unpaid invoice has a **follow-up log** (how, who, what was said, promised date and amount, next follow-up). **Receivables & follow-up** shows ageing (not due, 1–30, 31–60, 61–90, over 90 days) and flags overdue invoices with no follow-up, or whose next follow-up date has passed. **Report PDF** is the pending receivables report for management meetings. When work is complete Finance is notified; a project cannot be closed until Finance gives **financial clearance**, which needs a cost reconciliation since the last cost and all close-out items cleared. Unpaid invoices need a note on how they will be collected. Reopening withdraws clearance | Finance |

**Project cycle page** (Projects → Project cycle): counts of everything waiting at each stage (tenders being prepared, deadlines this week, unsigned reviews, awards not registered, budgets to approve, progress reports overdue, milestones ready to invoice, overdue invoices with no follow-up, projects awaiting clearance); the list of what Finance must register or approve; the billing schedule; reports due; invoices to chase; **who does what and by when** (19 duties from the meeting, editable by admins); and management meeting minutes.

**Notifications**: each person gets an inbox (Overview → Notifications, with an unread count) for the events their unit acts on: tender registered, review scheduled, tender submitted, award, project registered, budget submitted and decided, progress report submitted, milestone ready to invoice, work complete, financial clearance.

**Project finance** (Projects → Project finance, Finance only): for every project, the contract value, cost budget, spent plus committed, invoiced, received, outstanding and overdue, unbilled work, gross profit and margin, and whether it is registered, its budget approved, its reports up to date and its clearance given. PDF and CSV for management.

**Turning the gate off**: a company that does not want the registration rule can set `require_project_registration` to false on its row in the companies table (Supabase → Table editor). It is on by default.


## What's new in v2.4 — contract payment terms

If you already ran 0001 to 0009, run only `0010_asnys_v2_4.sql`.

Each contract now sets its own payment terms, and Asnys prompts Finance and the project manager when money is due.

| Feature | Where | What it does |
| --- | --- | --- |
| Terms on the award | Tender → **Record award** | Credit days, advance %, retention % and the contract's payment wording are captured with the award and carried to the project when Finance registers it |
| Contract payment terms | Project → Billing → **Set terms** | Client pays within N days of invoice; contract date; advance %; retention % and how many days after completion it is released; billing by milestones, monthly valuations (on a set day) or on completion; how many days ahead to remind |
| Payment schedule | Billing → **Build schedule** | Advance on signing, each milestone (or each monthly valuation, or the completion payment), and the retention release, each with the date to invoice and the date the client must pay. Rebuilding keeps lines already invoiced. Add or edit lines by hand |
| Status of each payment | Billing tab | To invoice, late to invoice, draft invoice, awaiting payment, payment overdue, paid, with the invoice number |
| Invoice from the schedule | **Invoice** on a line | Creates the draft invoice for that payment (milestones use the milestone billing); invoicing a milestone from its own table also ticks it off the schedule |
| Due dates from the contract | Every invoice on the project | The due date is the invoice date plus the contract's credit days, and moves if the draft's date changes. Typing your own due date overrides it |
| Prompts | Notifications | Finance and the project manager are told N days before an invoice should be raised and before a client payment is due, and again when either is missed. Each prompt is sent once |
| Payments calendar | Project cycle → Contract payments | Everything to invoice or collect in the next 30 days across all contracts, late items in red |

The reminders run whenever Finance or a project manager opens the dashboard. To send them every morning even when nobody logs in, enable the **pg_cron** extension in Supabase (Database → Extensions) and run once in the SQL editor:

```sql
select cron.schedule('asnys-payment-reminders', '0 6 * * *', $$select public.run_all_payment_reminders()$$);
select cron.schedule('asnys-contract-reminders', '5 6 * * *', $$select public.run_all_contract_reminders()$$);
select cron.schedule('asnys-cash-reminders', '10 6 * * *', $$select public.run_all_cash_reminders()$$);
```

Advances are not netted off later payments automatically. Where the contract recovers the advance from interim payments, add a deduction line on those invoices.


## What's new in v3.1 — Assets upgrade and Fleet & Logistics

If you already ran 0001 to 0017, run only `0018_asnys_v3_1.sql`. Free-text asset locations already in the register become entries in the new locations list, and every company gets a **Head office** location.

**Assets**
- **Locations**: head office, branches, sites, stores and yards, each with a manager. Assets → Locations.
- **Transfers**: Transfer on an asset sends it to another location. It shows **In transit** until the receiving manager presses Receive (with its condition) or Reject (with a reason). The sender can Recall it. Nothing else can be done to an asset while it is in transit.
- **Requests through the site**: a request for a site goes to that site's manager. They approve, decline, or **Pass to head office**, after which the storekeeper decides. Requests now have a quantity.
- **Accessories, components and consumables**: chargers, spare parts, PPE, toner. Stock per location, receive, issue, check out and return, transfer, adjust. Falling below the minimum alerts the storekeeper once.
- **Software licences**: seats, product key (shown only to the store and Finance), seats assigned to people or computers, reminder 30 days before expiry.
- **Warranty report**, **manufacturer / model / order number** on each asset, and **Import** of an existing register from Excel or CSV (Assets → Asset register → Import).
- **Telegram alerts (optional)**: Assets → Alerts. Needs the `pg_net` extension (Supabase → Database → Extensions → pg_net). Without it everything still works; only Telegram is skipped.

**Fleet & Logistics** (new home tile)
- **Vehicles**: registration, make, model, mileage, service interval by km or months, driver, project, link to the asset register. **Documents**: DVLA roadworthy, insurance, road use fee and others, with scans; reminders 30 and 7 days before expiry.
- **Drivers**: licence number, DVLA class, expiry (reminded), defensive-driving and medical dates.
- **Vehicle requests**: anyone asks; the transport officer allocates a vehicle and driver. Double bookings are refused.
- **Trips**: the driver starts and finishes each trip with the dashboard mileage. Mileage only goes forward; trips at weekends or outside 6:00–18:00 are marked.
- **Fuel**: litres, amount, mileage, receipt photo. Km per litre is worked out between full tanks and flagged if 20% worse than expected. The litres also feed HSE → Sustainability (CO2). The fuel log does **not** post to the books — keep recording fuel bills and expenses as usual, so nothing is counted twice.
- **Service and repairs**: job cards with cost and days off the road; a list of vehicles due by km or date.
- **Waybills**: deliveries, collections and transfers, by our vehicle, hired truck or courier. Print the waybill, dispatch, and on arrival record who received it, the quantities actually received and a photo of the signed copy. Short deliveries alert the transport officer.
- **Reports**: running cost per vehicle and per km, fuel economy, downtime, transport cost by project, papers and licences due.

**Reminders (0019)**: roadworthy, insurance, road use, permits, statutory inspections (crane, lifting gear), fire extinguishers and driving licences are reminded to transport officers, the storekeeper, owners and admins — first warning 30 days ahead (change it in Fleet → Reminders), again 7 days before, on the expiry day (the driver too), then weekly while expired. They arrive under the bell and, if set up, on Telegram. They need the daily schedule from the cash-reminders section (`asnys-cash-reminders`); if you set that up already, nothing more to do.

**Who does what**: tick **Transport officer** for a team member in Settings → Team (owners and admins). The storekeeper, Finance, owners and admins always count as transport officers. Drivers log fuel and run their own trips; project managers can raise and dispatch waybills.

## What's new in v3.0 — HR and payroll

If you already ran 0001 to 0016, run only `0017_asnys_v3_0.sql`. Existing payslip figures are unchanged; the new features add to them.

| Feature | Where | What it does |
| --- | --- | --- |
| Pay components | Payroll → Pay components | Housing, transport, fuel, responsibility, site, acting allowances, commission, leave pay, reimbursements (not taxed); union dues, welfare, credit union, court orders and other deductions. Add your own. Earnings are taxed or not; deductions are owed to 2260 Other payroll deductions payable or an account you choose |
| Regular items | Employee → Pay → Regular allowances and deductions | Paid every month from a start month to an optional end month; earnings pro rata for part months |
| One-off items | Payroll month → One-off pay this month | Commission, leave pay or a deduction for one month only |
| Pay changes and promotions | Employee → Pay → Change pay or promote; Payroll → Pay increase for many | Effective dates, reasons and history. A change dated in the past is paid automatically as **back pay** in the next regular payroll (with SSNIT on the basic arrears), once |
| Joiners and leavers | Automatic | Paid to the day in the month they join or leave (calendar days) |
| Off-cycle and final pay runs | Payroll → Off-cycle run | A separate run for a bonus, commission, correction or final pay. PAYE is worked out on the person's total for the month, less tax already deducted in posted runs |
| Self-service | My work → My payslips, My profile | Staff download their own payslips and a yearly statement of earnings and tax; they ask to update contact, bank, MoMo and next-of-kin details, and HR approves. They see documents HR shares with them |
| Employee profile | Employees → a name | Employment details (type, grade, manager, probation, contract end, notice), contact and next of kin, pay and its history, history of joins, promotions, transfers, warnings, awards (confidential lines hidden from the employee), documents with expiry, onboarding and exit tasks, certificate of service |
| Onboarding and exit | Employee → Onboarding and exit; HR → Joining & leaving | Checklists with an owner for each task (HR, manager, IT, Finance, Stores, HSE, employee). Start exit: reason, notice and last day, leave days due and their value, assets still held, loans and advances; completing the exit makes the person inactive and removes their sign-in |
| Leave | HR → Leave | Working days skip weekends and **public holidays** (Ghana holidays loaded for this year and next: New Year, Constitution Day, Independence Day, Good Friday, Easter Monday, May Day, Republic Day, Founder's Day, Farmers' Day, Christmas, Boxing Day; add Eid al-Fitr, Shaqq Day and Eid al-Adha when announced). Half days. Monthly earning and carry-over per leave type. The employee's manager or HR approves; nobody approves their own |
| Announcements | HR → Announcements; home screen | To all staff, a department or a branch, pinned or not, with notifications |
| Org chart | HR → Org chart | Who reports to whom, and a staff directory everyone can search (no pay or personal data) |
| Policies | HR → Policies | HR and admin policies (handbook, leave, code of conduct, IT use) with a PDF and version; staff confirm they have read each version (shared with the HSE policy register) |
| HR reports | HR → HR reports | Headcount, joiners and leavers, turnover, by department, type and gender, payroll cost by month, annual leave owed, probations, contracts and documents ending, birthdays, and the **annual PAYE return** for every employee (PDF and CSV) |
| Reminders | Daily job | Probation ending in 14 days, contract ending in 30 and 7 days, documents expiring in 30 days; future-dated pay changes applied on their date |

## What's new in v2.9 — HSE & Compliance (safety, compliance and sustainability)

If you already ran 0001 to 0015, run only `0016_asnys_v2_9.sql`. A new **HSE & Compliance** tile appears on the home screen, and every project gets a **Safety** tab. The module follows the structure of ISO 45001 (occupational health and safety), ISO 37301 (compliance management) and ISO 14001 with the GHG Protocol and GRI (environment and sustainability reporting). It does not by itself make a company certified; it holds the records an auditor asks for.

**HSE officers.** In Settings & team → Team and sign-in access, an owner or admin ticks **HSE officer** for the people who run safety (any role can also be an HSE officer). Owners and admins always count as HSE officers.

| Page | What it does | Who |
| --- | --- | --- |
| Overview | LTIFR (per 1,000,000 hours), TRIR (per 200,000 hours), days without a lost-time injury, near misses, toolbox talks, inspections, open and overdue actions, active permits, expired compliance items; your actions and policies to read; **Report PDF** for management review | Everyone |
| Incidents | Anyone reports an incident, near miss or unsafe condition from the phone, with photos. HSE and the project manager are told at once; owners and admins too for lost-time injuries, fatalities, dangerous occurrences, environmental incidents or high potential severity. Investigation: investigator, root cause, contributing factors, findings. Closing needs the root cause, every action verified or cancelled, and (if reportable) the report to the authority with its reference. Incident report PDF | Report: everyone. Investigate: HSE, project manager. Close: HSE |
| Actions | Corrective and preventive actions from incidents, inspections, audits and reviews, each with an owner and due date. The owner marks it done with a note; an HSE officer who did not do the work verifies it worked. Overdue reminders weekly | Raise: HSE, project manager |
| Talks & inductions | Toolbox talks with topic suggestions and attendance (staff ticked, subcontractors and casuals typed), printable sign-in sheet, upload the signed sheet. Company induction for new staff, site induction for each project, visitor induction, emergency drills, safety meetings. Inductions are valid 12 months (visitors 1 month). **Induction register** shows who is not inducted, expired or expiring. Optional **No induction, no work**: time cannot be booked to a project for someone without a valid site induction | Toolbox talks: anyone. Inductions: HSE, HR, project manager |
| Inspections | Seven ready checklists (site safety, electrical isolation and LOTO, work at height, vehicle pre-use, fire safety, office, toolbox talk) and your own. Pass, fail or N/A on the phone; Complete scores it and raises an action for every failed item. PDF | Anyone starts; HSE edits checklists |
| Permits | Hot work, electrical isolation (LOTO), work at height, confined space, excavation, lifting, general. At most 7 days. Issued by an HSE officer or the project manager, never by the person who asked for it. Suspend, resume, close with "work finished, area safe". Printable permit to post at the work place. Reminder if a permit runs past its time | Request: anyone. Issue: HSE, project manager |
| Risks | Every hazard from every project risk assessment in one register, highest remaining risk first (likelihood × severity) | Everyone |
| Compliance | Register of permits, licences, certificates, insurance and regular filings with owner, authority, reference, expiry or repeat, reminders before they are due and when they lapse, **Renewed / Filed** with the new date, and evidence files. **Add common Ghana items** gives a starting list (EPA permit, fire certificate, Factories Inspectorate, Energy Commission licence, tax and SSNIT clearance, insurance, ISO surveillance audits) | HSE, Finance, HR; the owner of each item |
| Policies | Publish policies with a PDF and version; each person confirms they have read each version; see who has not | Publish: HSE, HR |
| Sustainability | Fuel, electricity, water and waste each month, by project or company. Converted to tonnes of CO2e by scope (1: fuel burnt; 2: electricity bought) with editable emission factors: fuel from the UK DESNZ/DEFRA 2026 set, Ghana grid electricity from the IFI harmonised factor (0.360 kg/kWh); replace them with Energy Commission or supplier figures when you have them. Hours worked (timesheets plus site labour and subcontractors) for the safety rates and intensity. Report PDF laid out by GRI disclosure | Record: HSE, Finance, store, project managers |

The daily `asnys-cash-reminders` job also sends the HSE reminders (actions, compliance items, permits). Every register change is in the audit trail.

## What's new in v2.8 — projects on hold, clients from the project form

If you already ran 0001 to 0013, run only `0014_asnys_v2_8.sql`.

**On hold until further notice.** On a project's Overview, **Put on hold** works before the project starts as well as while it is in progress. Give the reason and, optionally, a **review date**; leave the date blank for "until further notice".

- The project page shows *On hold until further notice* (or *review on* the date), since when and why. Finance and the project manager are notified.
- While on hold, the project team cannot book new time, expense claims, purchase or spend requests, cash advances, purchase orders, stock issues or stock requests. Finance, admins and owners can still book costs that must be paid (security, standby, storage). Unused stock can always be returned to the store.
- **Change review date** sets or clears the date. When the date arrives, the project manager and Finance are reminded once (by the daily `asnys-cash-reminders` job).
- **Resume work** returns the project to where it was: Not started if work never began, otherwise In progress. Every hold, review date and resume is in the project's History.

**Clients from the project form.** The Client list on a new or edited project ends with **+ Add a new client…**; enter the name (and phone, email, TIN) and it is saved to Sales → Customers and linked to the project. The project header now shows where the work happens (location and country).

## What's new in v2.7 — requests, cash imprest and foreign-currency purchase orders

If you already ran 0001 to 0012, run only `0013_asnys_v2_7.sql`. It adds three accounts: 1260 Staff cash advances (imprest), 6960 Cash shortages and 4960 Cash overages.

**Requests** (My work → Requests; Finance also under Accounts) are for spending that is not a project purchase or a sales order: office repairs, utilities, fees, equipment, travel.

| Step | What happens |
| --- | --- |
| Raise | Anyone raises a **purchase**, a **payment** or a **cash advance**: what for, why, amount (in GH₵ or a foreign currency), the expense account it will be charged to, supplier or payee, branch, cost centre and project if any. The form shows the account's budget for the year, what has been spent, what is committed by other open requests, and what is left |
| Approve | The request goes through the approval chain for "Spend request" (Settings → Approval rules, by amount, e.g. head of department then Finance). With no rules set up, Finance approves every request. Nobody can approve their own request, and a submitted request cannot be changed |
| Act | Once approved, Finance **raises a purchase order** (draft, ready to send), **enters the supplier bill**, **pays now** (Dr the expense, Cr the bank, with a cheque or transfer reference) or **pays the advance**. The request records what was done, and the person who raised it is told |

**Cash advances (imprest)** (My work → Cash advances)

- Paying an advance posts Dr 1260 Staff cash advances, Cr bank, cash or MoMo, with a **retire-by date** (7 days after it is needed, by default).
- The holder adds each receipt (photo or PDF from the phone) with its type of cost, then presses **Submit for retirement**. Every line needs a receipt.
- Finance checks it and either **sends it back** with a note, or **approves**. Approval posts each receipt to its account and the cash handed back (or the amount owed to the staff member), and clears 1260 to zero for that advance.
- **Rules:** one advance at a time per person by default (`max_open_advances`), and **no new advance while one is overdue**.
  - The holder is reminded two days before the retire-by date and again when it passes; Finance is told when it is late.
  - After 30 days overdue (`advance_recover_after_days`), Finance can **recover through payroll**: the balance becomes a staff loan deducted monthly.
- The Advances page shows the **ageing**: not yet due, 1–7, 8–30 and over 30 days late.

**Petty cash floats (fixed imprest)** (My work → Petty cash)

- Finance sets up a float for each office or site: name, **custodian**, float amount, limit per voucher and how often it must be counted. It gets its own ledger account (from 1020) and is funded from the bank.
- The custodian records every payout as a **voucher** with its receipt. A voucher above the limit, or more than the cash left, is refused. The ledger stays at the float; the page shows the cash that should be in the box (float less vouchers not yet replenished).
- **Count cash:** enter how many of each note and coin (GH₵200 down to 1p). If it agrees, it is done. If not, Finance — not the person who counted — approves the difference: a shortage is written off to 6960 or charged to the custodian as a staff loan; an overage goes to 4960.
- **Replenish:** Finance (not the custodian) ticks the vouchers it accepts, and pays the accepted vouchers plus any shortage written off, bringing the float back to its full amount (Dr each expense, Cr bank). Rejected vouchers become the custodian's to make good.
  - Replenishment is **blocked** if the last count is older than 7 days, has an unapproved difference, or vouchers were added after it, or if an accepted voucher has no receipt.
- Custodians are reminded when a count is due.

**Books checks** now compare 1260 Staff cash advances with the advances not yet retired, and each petty cash account with its float.

To send advance and petty cash reminders every morning even when nobody logs in, also schedule:

```sql
select cron.schedule('asnys-cash-reminders', '10 6 * * *', $$select public.run_all_cash_reminders()$$);
```

**Purchase orders in other currencies.**

- Choose USD, EUR or any currency set up under Settings → Foreign currencies on the order. The rate fills in from Settings and can be changed while the order is a draft; it is fixed once the order is approved.
- Each line keeps the supplier's price (e.g. USD 3,850) and its GH₵ cost at the order rate. Approval limits, the goods-received accrual and stock values are in GH₵ at that rate.
- The PDF sent to the supplier shows prices and the total in USD.
- **Bill from order** makes the supplier bill in USD at the day's rate. When it is posted, the difference between the bill rate and the order rate goes to **4800 Foreign exchange gains and losses**; only a genuine change of price goes to 5150 Purchase price variance.
- Requests can also be raised in USD or EUR. The GH₵ equivalent at today's rate counts for budgets and approval limits, and the purchase order or bill made from the request keeps the currency.

**Print-outs.** Long document titles (for example a contract summary) now wrap on the right of the page instead of running over the company name, and every PDF writes amounts as "GHS".

## What's new in v2.6 — contracts, asset management and the Asnys logo

If you already ran 0001 to 0011, run only `0012_asnys_v2_6.sql`. Tenders already awarded become contracts automatically, and existing assets get a status and a first audit date in three months.

**Home screen.** There are now twelve tiles: Sales, Accounts, CRM, HR, Inventory, Projects, **Contracts**, **Assets**, Purchasing, Service, Settings and **My work** (time, expenses, approvals and notifications).

**Contracts** (Finance, Business Development and project managers)

| Feature | What it does |
| --- | --- |
| Contract register | Every contract in one list: with clients, suppliers and subcontractors, plus service contracts and leases. Each has a number (CON-0001), the other party and their reference, project, value and currency, dates, payment terms, advance and retention, and who manages it. Filters: Active, Ending or ended, With clients, Suppliers & subcontractors, Drafts, Closed. PDF and CSV |
| From tenders | When a tender is awarded, its client contract is created automatically with the value, reference, signing date and payment terms, and linked to the project once Finance registers it |
| Live figures | Original value, approved variations, revised value, amount invoiced (or billed by the supplier), paid, and remaining |
| Variations | Anyone managing the contract proposes a change (value up or down, extra days). Finance approves or rejects it; an approved extension moves the end date. Nobody can approve by editing the record |
| Bonds, guarantees and insurance | Performance bonds, advance payment guarantees, retention bonds, insurance and warranties, given or received, with bank, reference, amount and expiry. Mark them released, called or expired |
| Key dates and obligations | Reports, insurance renewals, end of the defects period, final account: each with a due date and the person responsible |
| Files | Upload the signed contract, LPO, variation instructions and letters; stored privately |
| Reminders | Before a contract ends (notice period set per contract; automatic renewals flagged), 30 days before a bond expires, a week before an obligation is due, and again when each is missed. A **Needs attention** list sits at the top of the register |

**Assets** (modelled on the Gulfaco asset system)

| Feature | What it does |
| --- | --- |
| Status | Ready to deploy, Deployed, Pending, Out for repair, Broken, Lost or stolen, Archived, separate from the accounting status. The register has filters for each, plus **Overdue back**, **Due for audit** and **Requestable** |
| Check out and check in | The storekeeper or Finance checks an asset out to a **person**, a **project site** or a **location**, with an expected return date. The person is notified and reminded if it is late. On check-in, record the condition it came back in |
| Audits | Each asset has a next audit date (every 12 months by default; change `asset_audit_months` on the company). **Audit** records where it was found and its condition; "not found" marks it lost. The Audits page lists everything due in 30 days and the audit history |
| Requests | Mark assets as requestable. Staff use **Request an asset** for a particular item or "any laptop"; the storekeeper approves and presses **Hand over**, which checks it out and closes the request |
| QR labels | Print an A4 sheet of 24 labels (tag, name, serial, company) for the assets listed, or one label from an asset's page. Scanning the code opens the asset in Asnys |
| Maintenance and movements | A maintenance schedule across all assets (last service, next due, total cost) and a log of every check-out, check-in, move, status change and audit |

Depreciation, disposals and the register value remain as before.

**The logo.** Asnys has a logo: an **A** built from two blocks with a gold keystone, in Asnys green. It is on the log-in page, the browser tab and the phone app icon. The files are in `docs/brand/`: the logo for light and dark backgrounds (SVG and PNG), the mark on its own, the app icon and a one-page sheet with the colours. A copy branded for one company keeps that company's letters instead.

## Renamed to Asnys ERP

Edwuma ERP is now **Asnys ERP**. Nothing needs to run in the database: the migration files were renamed `000x_asnys…` but they are the same files, so do not run them again. To finish the rename on a live install:

- Push the new code to GitHub; Cloudflare redeploys with the new name and icon. People who installed the phone app should remove it and add it to the home screen again to get the new icon.
- In Supabase (**Authentication → Emails → Templates**), change "Edwuma" to "Asnys" in the email templates and in your SMTP sender name.
- Optional: rename the Cloudflare Pages project or add a domain such as `erp.yourcompany.com.gh`, then update the Site URL and Redirect URLs in Supabase (step 6) and the `SITE_URL` secret.
- If you scheduled the daily payment reminders under the name `edwuma-payment-reminders`, it keeps working; no change needed.

Each user's chosen company carries over automatically.

### Showing a client company's own name

Every company's name already appears where its staff and customers see it. You type it in when the company is created, and can change it under **Settings & team → Company details**. It shows on:

- the top of the side menu, with the company's initials in the square (for example **AD** for Adom Distributors Ltd), and "Asnys ERP" in small type underneath;
- the browser tab, for example "Adom Distributors Ltd · Asnys ERP";
- every invoice, quote, receipt, payslip, purchase order and report PDF, with the TIN, address, bank and Mobile Money details;
- the invitation email ("You're invited to Adom Distributors Ltd") and the welcome page;
- the public help centre.

**A copy set up for one company only** (its own Supabase project and Cloudflare site, steps 1–6) can drop the Asnys name altogether. Before deploying, add these environment variables in Cloudflare Pages (or `.env.local`):

| Variable | Example | Effect |
| --- | --- | --- |
| `VITE_BRAND_NAME` | `Volta Engineering ERP` | Replaces "Asnys ERP" on the sign-in page, side menu, browser tab, installed phone app, PDF footers and help centre |
| `VITE_BRAND_MARK` | `VE` | The one or two letters in the logo square and the browser icon (defaults to the first letter of the name) |

Then redeploy. To use the company's own logo on the installed phone app, replace `public/icon-192.png` and `public/icon-512.png` with square PNGs of the logo before deploying. Also put the company's name in the Supabase email templates and SMTP sender name.

Leave both variables empty on the shared installation where many client companies sign up. Each company then sees its own name inside the app, with Asnys ERP as the product name.

### The log-in page

The log-in page has a dark background, with the form on a frosted card at the left and two panels about the system at the right; on phones only the form shows. The email box checks the address as you type ("Valid email is required: name@company.com"), and the password has a **Show** button. **Remember me** is ticked by default. On a shared computer, untick it and the person is logged out when the browser closes. **Forgot your password?** sends a reset link. If `VITE_SSO_PROVIDERS` is set, **Log in with Microsoft 365** and **Log in with Google** buttons appear under the main button. In a copy branded for one company, its name and initials replace Asnys ERP at the top of the card.

### Home screen and module tabs

The side menu is gone. After logging in, people see a **home screen of module tiles**: Sales, Accounts, CRM, HR, Inventory, Projects, Purchasing, Service and Settings. Each person only sees the tiles their role can use. **Today at a glance** (the figures that used to be the dashboard) sits underneath. Clicking a tile opens the module, and its pages run as **tabs along the top**: in Sales, for example, Invoices, Quotes & orders, Receivables, Credit notes, Recurring invoices and Customers. The **grid button** at the top left always goes back to the home screen. At the top right are **My time & expenses**, **Waiting for my approval**, **Notifications** (with the unread count) and the account menu, which shows the company and role and holds the company switcher, Settings and Sign out. On phones the tiles become a 3 × 3 grid of icons and the tabs scroll sideways.

## What's new in v2.5 — staff invitations and sign-in

If you already ran 0001 to 0010, run only `0011_asnys_v2_5.sql`, then deploy the email function (below).

Staff sign in with their own work email and a password they choose. Nobody needs to create an account first.

| Feature | Where | What it does |
| --- | --- | --- |
| Invite by email | Settings & team → **Team and sign-in access** | Type one or many work emails and a role, then press **Send invitation**. Each person gets an email with a link to set a password. Owners and admins can invite any role except owner. HR can invite staff (an admin can raise a role later) and sees a Team page for this |
| Invite from employee records | HR → Employees | A **Sign-in** column shows Has access, Invited, Email failed or Not invited. Tick employees and press **Invite selected to Asnys**, or open one and press **Invite to Asnys**. Their login is linked to their employee record, so My time & expenses works straight away |
| Accepting | The email link | Opens a **Welcome to Asnys ERP** page where they choose a password. They are added to the company with the invited role and linked to their employee record, and whoever invited them gets a notification. Someone who already has an Asnys login (for example, at another company in your group) gets a sign-in link instead and is added when they open it |
| Waiting invitations | Team and sign-in access | Status (Invited, Not sent yet, Email failed with the reason), when it was last emailed and how many times, who sent it. **Resend** or **Revoke**. A revoked link no longer gives access |
| Last sign-in | Team list | When each person last signed in, and which employee they are |
| Forgotten passwords | Sign-in screen → **Forgot password** | Anyone can reset their own password. Admins and HR can also press **Send password reset** next to a person on the team list |

**Security.** An invitation can only be claimed by someone who has confirmed the email address it was sent to. Keep **Confirm email** switched on in Supabase (**Authentication → Sign In / Providers → Email**). The service role key stays inside the Supabase function and never reaches the browser.

### Step A — Deploy the invite-member function

Either use the Supabase dashboard:

1. **Edge Functions → Deploy a new function → Via editor**.
2. Name it exactly `invite-member`.
3. Paste in the contents of `supabase/functions/invite-member/index.ts`, then press **Deploy**. Leave **Verify JWT** switched on.

Or use the command line:

```bash
npx supabase login
npx supabase link --project-ref your-project-ref
npx supabase functions deploy invite-member
```

Supabase provides `SUPABASE_URL`, `SUPABASE_ANON_KEY` and `SUPABASE_SERVICE_ROLE_KEY` to the function automatically. Optionally add a secret named `SITE_URL` (**Edge Functions → Secrets**) with your app's address, for example `https://erp.yourcompany.com.gh`, so email links always open the live app. The app's address must also be listed under **Authentication → URL Configuration → Redirect URLs** (step 6).

Until the function is deployed, invitations are still recorded and the app says so. People can sign up at your app's address with the invited email, and once they confirm it they are added with the right role automatically.

### Step B — Send email through your own email service (SMTP)

Supabase's built-in email sender is meant for testing and allows only a few emails an hour. That is not enough for inviting a team or for password resets. Before inviting staff:

1. Sign up with an email-sending service: for example Resend, Brevo, Postmark, Amazon SES or Zoho ZeptoMail. Google Workspace and Microsoft 365 SMTP also work for small teams.
2. Verify your domain with that service. It gives you SPF and DKIM DNS records to add at your domain registrar, which keeps messages out of spam.
3. In Supabase go to **Authentication → Emails → SMTP Settings**, switch on custom SMTP, and enter the host, port, username, password and a sender such as `Asnys ERP <no-reply@yourcompany.com.gh>`.
4. Under **Authentication → Rate Limits**, raise the emails-per-hour limit to suit your team.

### Step C — Word the emails

In **Authentication → Emails → Templates**, edit **Invite user**:

Subject: `You're invited to {{ .Data.invited_to }} on Asnys ERP`

```html
<h2>Welcome to {{ .Data.invited_to }}</h2>
<p>You have been invited to use Asnys ERP, our system for projects, timesheets, expenses, leave and stores.</p>
<p><a href="{{ .ConfirmationURL }}">Accept the invitation and choose your password</a></p>
<p>From then on, sign in with this email address ({{ .Email }}) and your password. If you forget it, use "Forgot password" on the sign-in screen.</p>
<p>This link expires. If it has, ask HR to resend your invitation.</p>
```

Also adjust **Magic Link** (the email sent to people who already have a login) and **Reset Password** so they mention your company and Asnys ERP.

## Roles and team access

The database enforces roles itself.

| Role | Can do | Cannot do |
| --- | --- | --- |
| Owner | Everything; one per company, cannot be removed | — |
| Admin | Everything, including the team | Change or remove the owner |
| Accountant | Bills, payments, journals, reports, post and pay payroll, all sales work | Manage the team |
| Sales | Customers, products, stock adjustments, invoices, customer payments | See salaries, the ledger or reports; post bills or journals |
| HR | Employees, approve leave, prepare payroll, invite staff by email, send password resets | Post payroll or journals; give anyone a role other than staff |
| Project manager | Create projects and templates; plan, budget, staff, approve time and expenses, and bill the projects they manage; CRM and service work | See the ledger or salaries; change other managers' projects |
| Storekeeper | Items, stores, receive goods on purchase orders, issue and return stock for projects, transfers, stock counts, supplier price lists; check assets out and in, audits, asset requests | See the ledger or salaries; approve orders; post stocktake differences |
| Staff | Projects, tasks, timesheets, leave requests | See salaries or the ledger; post money documents |

## Maintenance

**Tax-rate changes** — add dated rows in the SQL Editor; no redeploy needed:

```sql
update tax_rates set effective_to = '2026-12-31' where code = 'VAT' and effective_to is null;
insert into tax_rates values ('VAT', 'VAT', 0.15, '2027-01-01', null);

insert into paye_bands (effective_from, seq, width, rate) values
  ('2027-01-01', 1, 588, 0),
  ('2027-01-01', 2, 80, 0.05),
  -- ...one row per band from the GRA notice; null width = top band...
  ('2027-01-01', 7, null, 0.35);
```

PAYE bands are included from 1 September 2026 only; add earlier bands to run older months.

**Backups** — on the free plan, download key lists and reports as CSV regularly; the paid plan adds daily backups.

**Tests** — `npm run test:db` runs 330 checks against a throwaway copy of the database.

**Selling to clients** — each client signs up and creates their own company on the same installation, seeing only their data. For a client who wants a separate database, repeat steps 1–6 with a new Supabase project and Cloudflare site.

**Updating** — push code to GitHub; Cloudflare redeploys. Database changes go in a new numbered file in `supabase/migrations/`, run once in the SQL Editor.

## Troubleshooting and known limits

| You see | Fix |
| --- | --- |
| "Connect your database" | Add the two `VITE_SUPABASE_` variables and redeploy/restart. |
| Email never arrives | Check spam; set up SMTP in Supabase; check the Site URL. |
| Email link opens localhost | Update Site URL and Redirect URLs in Supabase. |
| "Your role cannot do this" | Ask the owner to change your role. |
| Invitation says the email service is not set up | Deploy the `invite-member` function (v2.5, step A). |
| Invite shows "Email failed: rate limit" | Set up custom SMTP and raise the email rate limit (v2.5, step B). |
| Invited person signed in but sees "create a company" | They signed up with a different address, or have not confirmed it. Check the email on the invitation, or revoke it and invite the address they use. |
| Invitation link expired | Press **Resend** on the team list. |
| "Only N of … in stock" | Post a supplier bill or stock adjustment first. |
| "No PAYE table covers …" | Add PAYE bands for that period. |
| Page not found after refresh | Keep `public/_redirects` in the repository. |
| Database paused | Restore it in Supabase, or move to the paid plan. |

Not in this version (each needs an account only you can set up): GRA e-invoicing device integration (GRA onboarding and credentials), Mobile Money payment collection (Paystack or Hubtel merchant keys), payslip and invoice emailing (an email-sending service and your domain).

Before using it for a client's statutory filings, have a Ghanaian chartered accountant check the VAT, PAYE and SSNIT outputs against real invoices and payslips.
