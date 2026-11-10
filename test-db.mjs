// Runs the Asnys ERP database migrations in an in-memory Postgres (PGlite) and checks the money flows.
// Usage: npm run test:db
import { PGlite } from '@electric-sql/pglite';
import { readFileSync } from 'node:fs';

const db = new PGlite();
let failures = 0;
const ok = (cond, msg) => { console.log((cond ? 'PASS ' : 'FAIL ') + msg); if (!cond) failures++; };
const one = async (sql, params) => (await db.query(sql, params)).rows[0];
const as = async (uid) => db.exec(`select set_config('request.jwt.claim.sub', '${uid}', false)`);

// Minimal stand-in for Supabase's auth schema and roles.
await db.exec(`
  create role anon nologin; create role authenticated nologin;
  create schema auth;
  create table auth.users (id uuid primary key, email text, email_confirmed_at timestamptz default now(), last_sign_in_at timestamptz);
  create function auth.uid() returns uuid language sql stable as
    $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
  grant usage on schema auth to authenticated; grant execute on function auth.uid() to authenticated, anon;
  insert into auth.users values ('11111111-1111-1111-1111-111111111111','owner@adom.com.gh'),
                                ('22222222-2222-2222-2222-222222222222','outsider@other.com.gh');
`);
for (const f of ['0001_asnys.sql', '0002_asnys_v1_1.sql', '0003_asnys_v1_2.sql', '0004_asnys_v1_3.sql', '0005_asnys_v1_4.sql', '0006_asnys_v2_0.sql', '0007_asnys_v2_1.sql', '0008_asnys_v2_2.sql', '0009_asnys_v2_3.sql', '0010_asnys_v2_4.sql', '0011_asnys_v2_5.sql', '0012_asnys_v2_6.sql', '0013_asnys_v2_7.sql', '0014_asnys_v2_8.sql', '0015_asnys_v2_8_1.sql', '0016_asnys_v2_9.sql', '0017_asnys_v3_0.sql', '0018_asnys_v3_1.sql', '0019_asnys_v3_1_1.sql', '0020_asnys_v3_2.sql']) {
  try { await db.exec(readFileSync(new URL('../supabase/migrations/' + f, import.meta.url), 'utf8')); }
  catch (e) { console.error('Migration ' + f + ' failed:', e.message, e.where || '', e.position || '', e.internalQuery || ''); process.exit(1); }
}
await db.exec(`grant usage on schema public to authenticated; grant all on all tables in schema public to authenticated;
               grant all on all sequences in schema public to authenticated;`);
console.log('Migration applied');

const OWNER = '11111111-1111-1111-1111-111111111111', OUT = '22222222-2222-2222-2222-222222222222';

// PAYE engine, Act 1178 bands
ok(Number((await one(`select compute_paye(5000,'2026-10-31') v`)).v) === 854.5, 'PAYE on GH₵5,000 = 854.50');
ok(Number((await one(`select compute_paye(588,'2026-10-31') v`)).v) === 0, 'PAYE on GH₵588 = 0');
ok(Number((await one(`select compute_paye(60000,'2026-10-31') v`)).v) === 17121.1, 'PAYE on GH₵60,000 = 17,121.10');

await as(OWNER);
const cid = (await one(`select create_company('Adom Distributors Ltd','C0012345678','Accra') id`)).id;
await db.query(`update companies set require_project_registration=false where id=$1`, [cid]); // the v2.3 project gate is tested on its own company
ok((await one(`select count(*) n from accounts where company_id=$1`, [cid])).n == 58, 'Chart of accounts seeded (58 accounts)');

const cust = (await one(`insert into customers (company_id,name) values ($1,'Kumasi Mart') returning id`, [cid])).id;
const sup = (await one(`insert into suppliers (company_id,name) values ($1,'Tema Wholesale') returning id`, [cid])).id;
const rice = (await one(`insert into products (company_id,sku,name,price,cost) values ($1,'RIC-25','Rice 25 kg',520,0) returning id`, [cid])).id;

let blocked = false;
try { await db.query(`insert into products (company_id,sku,name,stock_qty) values ($1,'X','Cheat',50)`, [cid]); } catch { blocked = true; }
ok(blocked, 'Products cannot be created with stock outside the ledger');

await db.query(`select adjust_stock($1, 10, 400, '2026-10-01', 'opening')`, [rice]);

// Purchase 40 bags at 430 with VAT
const bill = (await one(`insert into bills (company_id,supplier_id,bill_date) values ($1,$2,'2026-10-03') returning id`, [cid, sup])).id;
await db.query(`insert into bill_lines (bill_id,company_id,product_id,description,qty,unit_cost) values ($1,$2,$3,'Rice 25 kg',40,430)`, [bill, cid, rice]);
await db.query(`select post_bill($1)`, [bill]);
const b = await one(`select * from bills where id=$1`, [bill]);
ok(Number(b.total) === 20640, `Bill total 17,200 + 20% = ${b.total}`);
const p1 = await one(`select stock_qty, cost from products where id=$1`, [rice]);
ok(Number(p1.stock_qty) === 50 && Number(p1.cost) === 424, `Stock 50, average cost 424 (got ${p1.stock_qty}, ${p1.cost})`);

// Invoice: 20 bags + a taxable delivery service
const inv = (await one(`insert into invoices (company_id,customer_id,invoice_date) values ($1,$2,'2026-10-06') returning id`, [cid, cust])).id;
await db.query(`insert into invoice_lines (invoice_id,company_id,product_id,description,qty,unit_price,sort) values ($1,$2,$3,'Rice 25 kg',20,520,1)`, [inv, cid, rice]);
await db.query(`insert into invoice_lines (invoice_id,company_id,description,qty,unit_price,sort) values ($1,$2,'Delivery to Kumasi',1,300,2)`, [inv, cid]);
const no = (await one(`select post_invoice($1) n`, [inv])).n;
const i = await one(`select * from invoices where id=$1`, [inv]);
ok(no === 'INV-00001', `Invoice numbered ${no}`);
ok(Number(i.subtotal) === 10700 && Number(i.vat) === 1605 && Number(i.nhil) === 267.5 && Number(i.getfund) === 267.5 && Number(i.total) === 12840,
   `Invoice 10,700 + VAT 1,605 + NHIL 267.50 + GETFund 267.50 = ${i.total}`);

let editBlocked = false;
await db.exec('set role authenticated');
const upd = await db.query(`update invoices set notes='changed' where id=$1`, [inv]);
editBlocked = upd.affectedRows === 0;
await db.exec('reset role');
ok(editBlocked, 'Posted invoices cannot be edited from the app');

let oversell = false;
const inv2 = (await one(`insert into invoices (company_id,customer_id,invoice_date) values ($1,$2,'2026-10-07') returning id`, [cid, cust])).id;
await db.query(`insert into invoice_lines (invoice_id,company_id,product_id,description,qty,unit_price) values ($1,$2,$3,'Rice',999,520)`, [inv2, cid, rice]);
try { await db.query(`select post_invoice($1)`, [inv2]); } catch (e) { oversell = /in stock/.test(e.message); }
ok(oversell, 'Selling more than stock on hand is refused');

await db.query(`select record_payment($1, 5000, '2026-10-10', 'momo', 'MoMo 123')`, [inv]);
await db.query(`select record_payment($1, 7840, '2026-10-15', 'bank')`, [inv]);
ok((await one(`select status from invoices where id=$1`, [inv])).status === 'paid', 'Two payments settle the invoice');
await db.query(`select pay_bill($1, 20640, '2026-10-20', 'bank')`, [bill]);

// Payroll
await db.query(`insert into employees (company_id,full_name,basic_salary,allowances) values
  ($1,'Ama Owusu',6500,1200),($1,'Kwesi Mensah',3200,600)`, [cid]);
const run = (await one(`select prepare_payroll($1,'2026-10-01') id`, [cid])).id;
const ama = await one(`select p.* from payslips p join employees e on e.id=p.employee_id where e.full_name='Ama Owusu'`);
// gross 7700, ssnit 357.50, chargeable 7342.50 → PAYE 4+10+507.5+(3674.5*0.25)=1440.125 → 1440.13
ok(Number(ama.ssnit_employee) === 357.5 && Number(ama.paye) === 1440.13 && Number(ama.net) === 5902.37,
   `Ama: SSNIT 357.50, PAYE ${ama.paye}, net ${ama.net}`);
await db.query(`select post_payroll($1)`, [run]);
await db.query(`select pay_payroll($1,'bank','2026-10-31')`, [run]);

// Manual journal must balance
let unbalanced = false;
const cap = (await one(`select id from accounts where company_id=$1 and system_key='capital'`, [cid])).id;
const bank = (await one(`select id from accounts where company_id=$1 and system_key='bank'`, [cid])).id;
try { await db.query(`select post_manual_journal($1,'2026-10-01','Bad',$2::jsonb)`, [cid, JSON.stringify([{account_id: bank, debit: 100, credit: 0}, {account_id: cap, debit: 0, credit: 90}])]); }
catch (e) { unbalanced = /does not balance/.test(e.message); }
ok(unbalanced, 'Unbalanced journals are refused');
await db.query(`select post_manual_journal($1,'2026-10-01','Owner capital',$2::jsonb)`, [cid, JSON.stringify([{account_id: bank, debit: 100000, credit: 0}, {account_id: cap, debit: 0, credit: 100000}])]);

// Trial balance
const tb = await one(`select sum(debit) d, sum(credit) c from account_balances($1,'1900-01-01','2099-12-31')`, [cid]);
ok(Number(tb.d) === Number(tb.c), `Trial balance balances (${tb.d} = ${tb.c})`);
const oct = await one(`select count(*) n from account_balances($1,'2026-11-01','2026-11-30')`, [cid]);
ok(oct.n == 58, 'Report lists every account even in an empty period');


// ===================== v1.1 =====================
const near = (a, b) => Math.abs(Number(a) - Number(b)) < 0.005;
const balOf = async (key) => Number((await one(`select coalesce(sum(l.debit - l.credit),0) b from journal_lines l join accounts a on a.id = l.account_id where a.company_id = $1 and a.system_key = $2`, [cid, key])).b);

// Credit note against an invoice, with a returned bag
const inv3 = (await one(`insert into invoices (company_id,customer_id,invoice_date) values ($1,$2,'2026-10-12') returning id`, [cid, cust])).id;
await db.query(`insert into invoice_lines (invoice_id,company_id,product_id,description,qty,unit_price) values ($1,$2,$3,'Rice 25 kg',5,520)`, [inv3, cid, rice]);
await db.query(`select post_invoice($1)`, [inv3]);
const cn = (await one(`insert into credit_notes (company_id,customer_id,invoice_id,credit_date,reason) values ($1,$2,$3,'2026-10-13','1 bag damaged') returning id`, [cid, cust, inv3])).id;
await db.query(`insert into credit_note_lines (credit_note_id,company_id,product_id,description,qty,unit_price,restock) values ($1,$2,$3,'Rice 25 kg',1,520,true)`, [cn, cid, rice]);
const cnNo = (await one(`select post_credit_note($1) n`, [cn])).n;
const cnRow = await one(`select * from credit_notes where id=$1`, [cn]);
const inv3Row = await one(`select * from invoices where id=$1`, [inv3]);
ok(cnNo === 'CN-00001' && near(cnRow.total, 624) && near(inv3Row.amount_credited, 624), `Credit note ${cnNo}: GH₵624 credited against the invoice`);
ok(near((await one(`select stock_qty from products where id=$1`, [rice])).stock_qty, 26), 'Returned bag goes back into stock (26)');

// Full reversal
await db.query(`select reverse_invoice($1,'2026-10-14')`, [inv3]);
const inv3After = await one(`select status, amount_credited from invoices where id=$1`, [inv3]);
ok(inv3After.status === 'paid' && near(inv3After.amount_credited, 3120) && near((await one(`select stock_qty from products where id=$1`, [rice])).stock_qty, 31),
   'Reversing the invoice clears it and returns all stock (31)');

// Multi-currency invoice and payment with exchange gain
await db.query(`insert into currencies (company_id,code,name,rate) values ($1,'USD','US dollar',15)`, [cid]);
const usd = (await one(`insert into invoices (company_id,customer_id,invoice_date,currency,exchange_rate) values ($1,$2,'2026-10-15','USD',15) returning id`, [cid, cust])).id;
await db.query(`insert into invoice_lines (invoice_id,company_id,description,qty,unit_price) values ($1,$2,'Consulting',1,100)`, [usd, cid]);
const fxBefore = await balOf('fx');
await db.query(`select post_invoice($1)`, [usd]);
ok(near((await one(`select total from invoices where id=$1`, [usd])).total, 120), 'USD invoice: 100 + 20% = USD 120, posted at GH₵1,800');
await db.query(`select record_payment($1, 120, '2026-10-20', 'bank', 'Wire', 16)`, [usd]);
ok(near((await balOf('fx')) - fxBefore, -120) && (await one(`select status from invoices where id=$1`, [usd])).status === 'paid',
   'Paid at 16: GH₵120 exchange gain recorded, invoice settled');

// Foreign-currency bill raises stock at GHS cost
const usdBill = (await one(`insert into bills (company_id,supplier_id,bill_date,currency,exchange_rate) values ($1,$2,'2026-10-16','USD',15) returning id`, [cid, sup])).id;
await db.query(`insert into bill_lines (bill_id,company_id,product_id,description,qty,unit_cost) values ($1,$2,$3,'Rice',10,30)`, [usdBill, cid, rice]);
await db.query(`select post_bill($1)`, [usdBill]);
const riceNow = await one(`select stock_qty, cost from products where id=$1`, [rice]);
ok(near(riceNow.stock_qty, 41) && Math.abs(Number(riceNow.cost) - 430.3415) < 0.001, `USD 30 bags at 15 = GH₵450 each; average cost now ${riceNow.cost}`);

// Quote to invoice
const qt = await one(`insert into sales_quotes (company_id,customer_id,quote_date) values ($1,$2,'2026-10-17') returning id, number`, [cid, cust]);
await db.query(`insert into sales_quote_lines (quote_id,company_id,description,qty,unit_price) values ($1,$2,'Shelving install',2,1500)`, [qt.id, cid]);
const fromQuote = (await one(`select convert_quote($1) id`, [qt.id])).id;
ok(qt.number === 'QUO-00001' && (await one(`select count(*) n from invoice_lines where invoice_id=$1`, [fromQuote])).n == 1
   && (await one(`select status from sales_quotes where id=$1`, [qt.id])).status === 'converted', 'Quote QUO-00001 converts to a draft invoice');

// Recurring invoices catch up
await db.query(`insert into recurring_invoices (company_id,name,customer_id,frequency,next_date,lines) values ($1,'Monthly support',$2,'monthly',current_date - 40,$3::jsonb)`,
  [cid, cust, JSON.stringify([{ description: 'Support retainer', qty: 1, unit_price: 800, taxable: true }])]);
const made = (await one(`select run_recurring($1) n`, [cid])).n;
ok(made === 2, `Recurring template 40 days overdue creates 2 invoices (got ${made})`);
ok((await one(`select run_recurring($1) n`, [cid])).n === 0, 'Running again creates nothing new');

// Payroll extras for November
const yaw = (await one(`insert into employees (company_id,full_name,basic_salary,allowances,is_junior) values ($1,'Yaw Boateng',1000,200,true) returning id`, [cid])).id;
const amaId = (await one(`select id from employees where full_name='Ama Owusu'`)).id;
const kwesi = (await one(`select id from employees where full_name='Kwesi Mensah'`)).id;
await db.query(`update employees set tier3_employee_rate = 0.05 where id=$1`, [amaId]);
await db.query(`insert into payroll_inputs (company_id,period,employee_id,overtime,bonus) values ($1,'2026-11-01',$2,700,0),($1,'2026-11-01',$3,0,12000)`, [cid, yaw, amaId]);
await db.query(`select issue_loan($1, 1000, 400, '2026-11-02', 'bank', 'School fees')`, [kwesi]);
const nov = (await one(`select prepare_payroll($1,'2026-11-01') id`, [cid])).id;
const slip = async (id) => one(`select * from payslips where run_id=$1 and employee_id=$2`, [nov, id]);
const yawS = await slip(yaw), amaS = await slip(amaId), kwS = await slip(kwesi);
ok(near(yawS.overtime_tax, 45) && near(yawS.paye, 79.98) && near(yawS.net, 1720.02), `Junior overtime GH₵700: 5%/10% tax = 45; net ${yawS.net}`);
ok(near(amaS.bonus_tax, 585) && near(amaS.tier3_employee, 325) && near(amaS.chargeable, 7317.5) && near(amaS.paye, 1433.88) && near(amaS.net, 16998.62),
   `Bonus GH₵12,000: 5% on 11,700 cap, 300 through PAYE; Tier 3 relieved; PAYE ${amaS.paye}, net ${amaS.net}`);
ok(near(kwS.loan_deduction, 400), 'Staff loan instalment of GH₵400 deducted');
await db.query(`select post_payroll($1)`, [nov]);
ok(near((await one(`select balance from employee_loans where employee_id=$1`, [kwesi])).balance, 600), 'Loan balance falls to GH₵600 after posting');

// Leave balance
await db.query(`insert into leave_requests (company_id,employee_id,leave_type,start_date,end_date,days,status) values ($1,$2,'annual','2026-11-02','2026-11-06',5,'approved')`, [cid, amaId]);
const lb = await one(`select * from leave_balances($1, 2026) where employee_id=$2 and leave_code='annual'`, [cid, amaId]);
ok(near(lb.entitlement, 15) && near(lb.taken, 5) && near(lb.remaining, 10), 'Annual leave: 15 days, 5 taken, 10 left');

// Bank reconciliation
const bankId = (await one(`select id from accounts where company_id=$1 and system_key='bank'`, [cid])).id;
const bankLines = (await db.query(`select id from journal_lines where account_id=$1`, [bankId])).rows.map(r => r.id);
const bankBal = await balOf('bank');
let recRefused = false;
try { await db.query(`select complete_reconciliation($1,$2,'2099-12-31',$3,$4::uuid[])`, [cid, bankId, bankBal + 10, bankLines]); } catch (e) { recRefused = /does not match/.test(e.message); }
ok(recRefused, 'Reconciliation refuses a statement balance that does not match');
await db.query(`select complete_reconciliation($1,$2,'2099-12-31',$3,$4::uuid[])`, [cid, bankId, bankBal, bankLines]);
ok((await one(`select count(*) n from journal_lines where account_id=$1 and reconciliation_id is null`, [bankId])).n == 0, 'Matching statement reconciles every bank line');

// Period lock
await db.query(`select set_lock_date($1,'2026-10-31')`, [cid]);
let locked = false;
try { await db.query(`select post_manual_journal($1,'2026-10-15','Late entry',$2::jsonb)`, [cid, JSON.stringify([{ account_id: bank, debit: 50, credit: 0 }, { account_id: cap, debit: 0, credit: 50 }])]); }
catch (e) { locked = /locked/.test(e.message); }
ok(locked, 'Posting into a locked period is refused');
await db.query(`select post_manual_journal($1,'2026-11-15','After lock',$2::jsonb)`, [cid, JSON.stringify([{ account_id: bank, debit: 50, credit: 0 }, { account_id: cap, debit: 0, credit: 50 }])]);

const tb2 = await one(`select sum(debit) d, sum(credit) c from account_balances($1,'1900-01-01','2099-12-31')`, [cid]);
ok(Number(tb2.d) === Number(tb2.c), `Trial balance still balances after every v1.1 posting (${tb2.d})`);


// ===================== v1.2 =====================
// (Books are locked to 31 Oct 2026 by the v1.1 tests, so everything here is dated later.)
const acctBal = async (c, key) => Number((await one(`select coalesce(sum(l.debit - l.credit),0) b from journal_lines l join accounts a on a.id = l.account_id where a.company_id = $1 and a.system_key = $2`, [c, key])).b);
const catId = async (name) => (await one(`select id from asset_categories where company_id=$1 and name=$2`, [cid, name])).id;

// Fixed assets
const laptop = (await one(`select register_asset($1, $2::jsonb, 'bank') id`, [cid, JSON.stringify({ name: 'Dell laptop', category_id: await catId('Computers and IT equipment'), cost: 3600, purchase_date: '2026-11-03', location: 'Accra HQ' })])).id;
const truck = (await one(`select register_asset($1, $2::jsonb, 'ap') id`, [cid, JSON.stringify({ name: 'Delivery truck', category_id: await catId('Motor vehicles'), cost: 120000, purchase_date: '2026-11-10' })])).id;
const lt = await one(`select tag, method, useful_life_months from assets where id=$1`, [laptop]);
ok(lt.tag === 'AST-00001' && lt.method === 'straight_line' && lt.useful_life_months === 36 && near(await acctBal(cid, 'fa_cost'), 123600), 'Assets registered with category defaults and capitalised (GH₵123,600)');
const dep = Number((await one(`select run_depreciation($1,'2026-12-01') v`, [cid])).v);
ok(near(dep, 5147.92), `Depreciation Nov–Dec: laptop 2 × 100 + truck 2,500 + 2,447.92 = ${dep}`);
ok(Number((await one(`select run_depreciation($1,'2026-12-01') v`, [cid])).v) === 0, 'Running depreciation again for the same month posts nothing');
const loss = Number((await one(`select dispose_asset($1,'2027-01-15',3000,'bank') v`, [laptop])).v);
ok(near(loss, -400) && (await one(`select status from assets where id=$1`, [laptop])).status === 'disposed' && near(await acctBal(cid, 'disposal'), 400),
   'Laptop sold for 3,000 against book value 3,400: loss of 400 posted');
let assetLocked = false;
await db.exec('set role authenticated'); await as(OWNER);
try { await db.query(`update assets set cost = 1 where id=$1`, [truck]); } catch (e) { assetLocked = /change only through/.test(e.message); }
await db.exec('reset role');
ok(assetLocked, 'Asset cost cannot be edited directly');

// CRM and sales force automation
const lead = (await one(`insert into leads (company_id,name,organisation,phone,source,estimated_value) values ($1,'Akua Mensah','Tamale Agro Ltd','020 111 2222','referral',5000) returning id`, [cid])).id;
const newCust = (await one(`select convert_lead($1, true) id`, [lead])).id;
const opp = await one(`select * from opportunities where lead_id=$1`, [lead]);
ok(newCust && near(opp.amount, 5000) && opp.stage === 'qualification' && (await one(`select name from customers where id=$1`, [newCust])).name === 'Tamale Agro Ltd',
   'Lead converts to customer Tamale Agro Ltd with a GH₵5,000 opportunity');
await db.query(`update opportunities set stage='won', probability=100, closed_at='2026-11-18' where id=$1`, [opp.id]);
await db.query(`insert into sales_targets (company_id,user_id,year,month,amount) values ($1,$2,2026,11,10000)`, [cid, OWNER]);
await db.query(`insert into crm_activities (company_id,kind,subject,done,done_at,customer_id,latitude,longitude) values ($1,'visit','Site visit',true,'2026-11-19 10:00',$2,9.4034,-0.8424)`, [cid, newCust]);
const nInv = (await one(`insert into invoices (company_id,customer_id,invoice_date) values ($1,$2,'2026-11-20') returning id`, [cid, newCust])).id;
await db.query(`insert into invoice_lines (invoice_id,company_id,description,qty,unit_price) values ($1,$2,'Advisory',1,1000)`, [nInv, cid]);
await db.query(`select post_invoice($1)`, [nInv]);
const perf = await one(`select * from sales_performance($1,2026,11) where user_id=$2`, [cid, OWNER]);
ok(near(perf.target, 10000) && near(perf.invoiced, 1000) && perf.won === 1 && perf.visits === 1, `Rep scorecard: target 10,000, invoiced ${perf.invoiced}, 1 won, 1 visit`);

// Group of companies and global resource management
const cid2 = (await one(`select create_company('Adom Consulting Ltd', null, 'Kumasi') id`)).id;
await db.query(`update companies set require_project_registration=false where id=$1`, [cid2]); // the v2.3 project gate is tested on its own company
await db.query(`select create_group($1,'Adom Group')`, [cid]);
await db.query(`select join_group($1,$2)`, [cid, cid2]);
const consultant = (await one(`insert into employees (company_id,full_name,job_title,basic_salary,skills,location,cost_rate) values ($1,'Esi Quaye','SAP consultant',9000,'{SAP,Python,Data}','Kumasi',120) returning id`, [cid2])).id;
await db.query(`insert into currencies (company_id,code,name,rate) values ($1,'USD','US dollar',15) on conflict do nothing`, [cid]);
const proj = (await one(`insert into projects (company_id,name,customer_id,currency,hourly_rate,status) values ($1,'Lomé ERP rollout',$2,'USD',40,'active') returning id`, [cid, cust])).id;
let found = (await db.query(`select * from search_resources($1, '{sap}', '', '2026-11-01', '2026-11-30')`, [cid])).rows;
ok(found.length === 1 && found[0].full_name === 'Esi Quaye' && found[0].company_name === 'Adom Consulting Ltd' && found[0].available === 100 && !('basic_salary' in found[0]),
   'Skill search finds a consultant in the sister company, 100% available, no salary shown');
await db.query(`select assign_resource($1,$2,'2026-11-01','2026-11-30',60,'Lead consultant',50)`, [proj, consultant]);
found = (await db.query(`select * from search_resources($1, '{sap}', 'kumasi', '2026-11-01', '2026-11-30')`, [cid])).rows;
ok(found[0].available === 40, 'After a 60% assignment she shows 40% available');
const OUTS = OUT;
await as(OUTS);
let noSearch = false;
try { await db.query(`select * from search_resources($1, '{}', '', '2026-11-01', '2026-11-30')`, [cid]); } catch { noSearch = true; }
ok(noSearch, 'Outside users cannot search your staff');

// Mobile time and expenses from the consultant's own login (not a member of either company)
const EMP = '44444444-4444-4444-4444-444444444444';
await as(OWNER);
await db.exec(`insert into auth.users values ('${EMP}','esi@adomconsulting.com.gh')`);
await db.query(`select link_employee_user($1,'esi@adomconsulting.com.gh')`, [consultant]);
await as(EMP);
const work = (await one(`select my_work() w`)).w;
ok(work.projects.some(p => p.name === 'Lomé ERP rollout'), 'Her "My work" lists the cross-company project');
const ts = (await one(`select submit_time($1,'2026-11-05',8,null,'Workshop',true) id`, [proj])).id;
const exp = (await one(`select submit_expense($1::jsonb) id`, [JSON.stringify({ project_id: proj, expense_date: '2026-11-05', description: 'Taxi to client', currency: 'USD', amount: 100, billable: true })])).id;
const expRow = await one(`select amount_home, company_id from expense_claims where id=$1`, [exp]);
ok(near(expRow.amount_home, 1500) && expRow.company_id === cid, 'USD 100 expense converts to GH₵1,500 and is charged to the project company');
let noEur = false;
try { await db.query(`select submit_expense($1::jsonb)`, [JSON.stringify({ project_id: proj, expense_date: '2026-11-05', description: 'Lunch', currency: 'EUR', amount: 20 })]); } catch (e) { noEur = /exchange rate/.test(e.message); }
ok(noEur, 'An expense in a currency with no rate asks for the rate');
let selfApprove = false;
try { await db.query(`select decide_time($1::uuid[], true)`, [[ts]]); } catch { selfApprove = true; }
ok(selfApprove, 'Staff cannot approve their own time');

await as(OWNER);
await db.query(`select decide_time($1::uuid[], true)`, [[ts]]);
await db.query(`select decide_expense($1, true)`, [exp]);
ok(near(await acctBal(cid, 'reimburse'), -1500) && near(await acctBal(cid, 'project_exp'), 1500), 'Approved expense posts GH₵1,500 to project expenses and claims payable');
const pinv = (await one(`select invoice_project($1,'2026-11-30') id`, [proj])).id;
const plines = (await db.query(`select qty, unit_price from invoice_lines where invoice_id=$1 order by sort`, [pinv])).rows;
const pi = await one(`select currency, exchange_rate from invoices where id=$1`, [pinv]);
ok(pi.currency === 'USD' && near(pi.exchange_rate, 15) && plines.length === 2 && near(plines[0].qty, 8) && near(plines[0].unit_price, 50) && near(plines[1].unit_price, 100),
   'Project invoice in USD: 8 h × 50 and the USD 100 expense re-billed');
await db.query(`update invoices set invoice_date='2026-12-01' where id=$1`, [pinv]);
await db.query(`select post_invoice($1)`, [pinv]);
ok(near((await one(`select total from invoices where id=$1`, [pinv])).total, 600), 'USD 500 + 20% VAT and levies = USD 600');
let again = false;
try { await db.query(`select invoice_project($1,'2026-11-30')`, [proj]); } catch (e) { again = /no approved, unbilled/.test(e.message); }
ok(again, 'Billed time and expenses are not invoiced twice');
const paid = Number((await one(`select reimburse_employee($1,$2,'momo','2026-11-30') v`, [cid, consultant])).v);
ok(near(paid, 1500) && near(await acctBal(cid, 'reimburse'), 0), 'Reimbursing her clears the claims payable');
const fin = await one(`select * from project_financials($1)`, [proj]);
ok(near(fin.time_cost, 960) && near(fin.expenses, 1500) && near(fin.invoiced, 7500), `Project figures in GH₵: cost of time 960, expenses 1,500, billed ${fin.invoiced}`);

for (const c of [cid, cid2]) {
  const t = await one(`select sum(debit) d, sum(credit) c from account_balances($1,'1900-01-01','2099-12-31')`, [c]);
  ok(Number(t.d) === Number(t.c), `Trial balance balances for ${c === cid ? 'Adom Distributors' : 'Adom Consulting'} after v1.2 postings`);
}


// ===================== v1.3 =====================
// Project manager role
const PMU = '55555555-5555-5555-5555-555555555555';
await as(OWNER);
await db.exec(`insert into auth.users values ('${PMU}','kojo.pm@adom.com.gh')`);
await db.query(`select add_member($1,'kojo.pm@adom.com.gh','project_manager')`, [cid]);
// Template with dependent tasks, a milestone and a budget
const tpl = (await one(`insert into projects (company_id,name,is_template,start_date,billing_type,contract_value,hourly_rate) values ($1,'Template: clinic fit-out',true,'2026-01-01','fixed_price',10000,0) returning id, number`, [cid]));
ok(tpl.number === null, 'Templates do not use up a project number');
const t1 = (await one(`insert into tasks (company_id,project_id,title,start_date,due_date,estimated_hours,sort) values ($1,$2,'Survey','2026-01-01','2026-01-05',10,1) returning id`, [cid, tpl.id])).id;
const t2 = (await one(`insert into tasks (company_id,project_id,title,start_date,due_date,estimated_hours,predecessor_id,sort) values ($1,$2,'Install','2026-01-06','2026-01-20',20,$3,2) returning id`, [cid, tpl.id, t1])).id;
await db.query(`insert into project_milestones (company_id,project_id,name,due_date,amount,task_id) values ($1,$2,'Installation complete','2026-01-20',5000,$3)`, [cid, tpl.id, t2]);
await db.query(`insert into project_budget_lines (company_id,project_id,category,cost_budget,revenue_budget) values ($1,$2,'labour',3000,10000)`, [cid, tpl.id]);

await as(PMU);
const np = (await one(`select create_project_from_template($1,'Clinic fit-out, Tamale',$2,'2026-12-01') id`, [tpl.id, cust])).id;
const npRow = await one(`select * from projects where id=$1`, [np]);
const ntasks = (await db.query(`select * from tasks where project_id=$1 order by sort`, [np])).rows;
const nms = await one(`select * from project_milestones where project_id=$1`, [np]);
ok(npRow.number && npRow.number.startsWith('PRJ-') && npRow.manager_id === PMU && ntasks.length === 2 && ntasks[1].predecessor_id === ntasks[0].id
   && ntasks[0].start_date && new Date(ntasks[0].start_date).toISOString().slice(0,10) === '2026-12-01' && nms.task_id === ntasks[1].id,
   `Project ${npRow.number} created from template: dates shifted, dependency and milestone link kept, PM is the manager`);
let pmBlocked = false;
try { await db.query(`select assign_resource($1,$2,'2026-12-01','2026-12-31',20)`, [proj, consultant]); } catch (e) { pmBlocked = /manager/.test(e.message); }
ok(pmBlocked, "A project manager cannot staff someone else's project");
await db.query(`select assign_resource($1,$2,'2026-12-01','2026-12-31',50,'Site engineer',null)`, [np, consultant]);
ok(true, 'A project manager can staff their own project, including people from the sister company');

await db.query(`update tasks set status='done' where id=$1`, [ntasks[1].id]);
ok((await one(`select status from project_milestones where id=$1`, [nms.id])).status === 'ready', 'Finishing the linked task makes the billing milestone ready');
const mInv = (await one(`select invoice_milestone($1) id`, [nms.id])).id;
await as(OWNER);
await db.query(`update invoices set invoice_date='2026-12-02' where id=$1`, [mInv]);
await db.query(`select post_invoice($1)`, [mInv]);
ok(near((await one(`select total from invoices where id=$1`, [mInv])).total, 6000), 'Milestone invoice GH₵5,000 + 20% = 6,000');
await db.query(`insert into project_issues (company_id,project_id,title,severity) values ($1,$2,'Generator delivery late','high')`, [cid, np]);
await db.query(`insert into project_updates (company_id,project_id,health,summary) values ($1,$2,'at_risk','Waiting on generator')`, [cid, np]);
const k = await one(`select * from project_kpis($1) where project_id=$2`, [cid, np]);
ok(k.pct_complete === 67 && near(k.invoiced, 5000) && near(k.budget_revenue, 10000) && k.serious_issues === 1 && k.health === 'at_risk',
   `Project KPIs: 67% complete by estimated hours, GH₵5,000 invoiced of 10,000, 1 serious issue, at risk`);
const tsPend = (await one(`insert into timesheets (company_id,project_id,employee_id,work_date,hours,status) values ($1,$2,$3,'2026-11-10',4,'submitted') returning id`, [cid, proj, consultant])).id;
await as(PMU);
let pmApprove = false;
try { await db.query(`select decide_time($1::uuid[], true)`, [[tsPend]]); } catch (e) { pmApprove = /projects you manage/.test(e.message); }
ok(pmApprove, "A project manager cannot approve time on other managers' projects");
await as(OWNER);
const so = (await one(`insert into sales_quotes (company_id,kind,customer_id,quote_date,subtotal,total) values ($1,'order',$2,'2026-11-20',8000,9600) returning id`, [cid, cust])).id;
await db.query(`insert into sales_quote_lines (quote_id,company_id,description,qty,unit_price) values ($1,$2,'Solar install, 5 kW',1,8000)`, [so, cid]);
const fromSo = (await one(`select create_project_from_order($1) id`, [so])).id;
const fsp = await one(`select billing_type, contract_value, (select count(*) from tasks where project_id = p.id) nt, (select sum(amount) from project_milestones where project_id = p.id) ms from projects p where id=$1`, [fromSo]);
ok(fsp.billing_type === 'fixed_price' && near(fsp.contract_value, 8000) && fsp.nt == 1 && near(fsp.ms, 8000), 'Sales order becomes a fixed-price project with a task and a GH₵8,000 milestone');

// CRM: lead scoring, campaigns, partners, commissions
const camp = (await one(`insert into campaigns (company_id,name,channel,status,actual_cost) values ($1,'Harmattan promo','whatsapp','active',1000) returning id`, [cid])).id;
const hot = await one(`insert into leads (company_id,name,organisation,phone,email,source,estimated_value,campaign_id) values ($1,'Yaa Owusu','Sunyani Pharma','024 1','y@sp.com','referral',25000,$2) returning id, score, sales_ready`, [cid, camp]);
const cold = await one(`insert into leads (company_id,name,phone,source) values ($1,'Walk-in buyer','055 2','walk-in') returning id, score, sales_ready`, [cid]);
ok(hot.score === 65 && hot.sales_ready && cold.score === 20 && !cold.sales_ready, `Lead scores: referral with details 65 (sales-ready), walk-in 20`);
await db.query(`insert into crm_activities (company_id,kind,subject,done,done_at,lead_id) values ($1,'call','Intro call',true,now(),$2),($1,'visit','Shop visit',true,now(),$2)`, [cid, cold.id]);
ok((await one(`select score from leads where id=$1`, [cold.id])).score === 30, 'Two completed activities raise the walk-in lead to 30');
await db.query(`update companies set lead_ready_score = 25 where id = $1`, [cid]);
ok((await one(`select sales_ready from leads where id=$1`, [cold.id])).sales_ready === true, 'Lowering the sales-ready threshold to 25 re-scores open leads');
await db.query(`update companies set lead_ready_score = 50 where id = $1`, [cid]);
const partner = (await one(`insert into partners (company_id,name,kind,commission_rate) values ($1,'Kofi Agencies','agent',0.10) returning id`, [cid])).id;
await db.query(`update leads set partner_id=$2 where id=$1`, [hot.id, partner]);
const hotCust = (await one(`select convert_lead($1, true) id`, [hot.id])).id;
const hotOpp = await one(`select * from opportunities where lead_id=$1`, [hot.id]);
ok(hotOpp.campaign_id === camp && hotOpp.partner_id === partner && (await one(`select partner_id from customers where id=$1`, [hotCust])).partner_id === partner,
   'Converted lead keeps its campaign and partner on the deal and customer');
await db.query(`update opportunities set stage='won', amount=8000, closed_at='2026-12-03' where id=$1`, [hotOpp.id]);
const cr = await one(`select * from campaign_results($1) where campaign_id=$2`, [cid, camp]);
ok(cr.leads === 1 && cr.converted === 1 && near(cr.won_value, 8000) && near(cr.roi_pct, 700), `Campaign results: 1 lead, converted, GH₵8,000 won on GH₵1,000 spent = ${cr.roi_pct}% ROI`);
const pInv = (await one(`insert into invoices (company_id,customer_id,invoice_date) values ($1,$2,'2026-12-05') returning id, partner_id`, [cid, hotCust]));
await db.query(`insert into invoice_lines (invoice_id,company_id,description,qty,unit_price) values ($1,$2,'Paracetamol cartons',10,100)`, [pInv.id, cid]);
await db.query(`select post_invoice($1)`, [pInv.id]);
ok(pInv.partner_id === partner, "Invoices pick up the customer's partner automatically");
await db.query(`insert into sales_commission_rates (company_id,user_id,rate) values ($1,$2,0.05)`, [cid, OWNER]);
const comm = (await db.query(`select * from commission_report($1,'2026-12-01','2026-12-31')`, [cid])).rows;
const pc = comm.find(r => r.kind === 'partner'), rc = comm.find(r => r.kind === 'rep' && r.ref_id === OWNER);
const pmRow = comm.find(r => r.kind === 'rep' && r.ref_id === PMU);
ok(near(pc.commission, 100) && near(rc.base, 8500) && near(rc.commission, 425) && near(pmRow.base, 5000) && near(pmRow.commission, 0),
   `December commission: partner 10% of 1,000 = 100; owner 5% of 8,500 (USD project bill 7,500 + 1,000) = 425; PM's milestone invoice credited to the PM`);
const posted = Number((await one(`select post_commissions($1,'2026-12-01','2026-12-31','2026-12-31') v`, [cid])).v);
let twice = false;
try { await db.query(`select post_commissions($1,'2026-12-15','2026-12-31','2026-12-31')`, [cid]); } catch (e) { twice = /already been posted/.test(e.message); }
ok(near(posted, 525) && twice && near(await acctBal(cid, 'commission_pay'), -525), 'Commission of GH₵525 accrued once; overlapping periods are refused');
const fc = (await db.query(`select * from sales_forecast($1,'2026-12-01',1)`, [cid])).rows[0];
ok(near(fc.won, 8000) && near(fc.invoiced, 13500), `December forecast: won 8,000, invoiced 13,500 (7,500 + 5,000 + 1,000)`);
const c360 = (await one(`select customer_360($1) v`, [hotCust])).v;
ok(near(c360.lifetime_sales, 1000) && near(c360.outstanding, 1200) && c360.invoices === 1 && c360.top_products[0].name === 'Paracetamol cartons', 'Customer 360: lifetime GH₵1,000, GH₵1,200 outstanding, top product listed');

// Customer service and the public help centre
await db.query(`update customers set email='y@sp.com' where id=$1`, [hotCust]);
const kase = await one(`insert into support_cases (company_id,email,subject,priority) values ($1,'y@sp.com','Short delivery','high') returning id, number, customer_id, access_token`, [cid]);
await db.query(`insert into case_messages (company_id,case_id,body) values ($1,$2,'Sorry — the missing carton goes out today.')`, [cid, kase.id]);
const kAfter = await one(`select status, first_response_at from support_cases where id=$1`, [kase.id]);
ok(kase.number.startsWith('CASE-') && kase.customer_id === hotCust && kAfter.status === 'in_progress' && kAfter.first_response_at, `${kase.number} matched to the customer by email; first reply recorded`);
await db.exec(`grant usage on schema public to anon; select set_config('request.jwt.claim.sub', '', false); set role anon;`);
let closed = false;
try { await db.query(`select submit_case_public($1,'Ama','a@x.com',null,'Help','Broken')`, [cid]); } catch (e) { closed = /not available/.test(e.message); }
await db.exec('reset role');
await as(OWNER); await db.query(`update companies set help_center_enabled = true where id=$1`, [cid]);
await db.exec(`select set_config('request.jwt.claim.sub', '', false); set role anon;`);
const pub = (await one(`select submit_case_public($1,'Ama Boateng','ama@x.com','','Invoice query','Wrong VAT') v`, [cid])).v;
const st = (await one(`select case_status_public($1,$2) v`, [pub.number, pub.token])).v;
await db.query(`select reply_case_public($1,$2,'Thanks, sorted.',5)`, [pub.number, pub.token]);
let wrongToken = (await one(`select case_status_public($1,'nope') v`, [pub.number])).v;
let noTable = false;
try { await db.query(`select count(*) from support_cases`); } catch { noTable = true; }
await db.exec('reset role');
ok(closed && st.status === 'new' && wrongToken === null && noTable, 'Help centre: closed until switched on; customers track their case only with its access code and cannot read the cases table');
await as(OWNER);
ok((await one(`select satisfaction from support_cases where number=$1`, [pub.number])).satisfaction === 5, 'Customer satisfaction rating saved from the help centre');

for (const c of [cid, cid2]) {
  const t = await one(`select sum(debit) d, sum(credit) c from account_balances($1,'1900-01-01','2099-12-31')`, [c]);
  ok(Number(t.d) === Number(t.c), `Trial balance balances for ${c === cid ? 'Adom Distributors' : 'Adom Consulting'} after v1.3 postings`);
}

// ===================== v1.4 =====================
// Purchase requests on a project, budget-checked approval, committed cost, bill, ledger tags
await as(PMU);
const rq1 = (await one(`insert into project_requests (project_id,kind,description,qty,unit,est_unit_cost) values ($1,'material','Cement, 50 kg bags',10,'bag',100) returning id, number, company_id`, [np]));
const rq2 = (await one(`insert into project_requests (project_id,kind,description,qty,est_unit_cost) values ($1,'subcontract','Electrical first fix by subcontractor',1,2500) returning id`, [np])).id;
ok(rq1.number === 'PR-00001' && rq1.company_id === cid, 'A purchase request on a project gets number PR-00001');
await db.query(`select decide_request($1::uuid[], true)`, [[rq1.id]]);
let overPm = '';
try { await db.query(`select decide_request($1::uuid[], true)`, [[rq2]]); } catch (e) { overPm = e.message; }
ok(/cost budget/.test(overPm), 'The project manager approves within budget but cannot approve a request that takes the project over its GH₵3,000 cost budget');
let sneak = false;
try { await db.query(`update project_requests set status='approved' where id=$1`, [rq2]); } catch (e) { sneak = /Approve or Reject/.test(e.message); }
ok(sneak, 'A request cannot be approved by editing it directly');
await as(OWNER);
await db.query(`select decide_request($1::uuid[], true)`, [[rq2]]);
let kk = await one(`select * from project_kpis($1) where project_id=$2`, [cid, np]);
ok(near(kk.committed_cost, 3500) && near(kk.actual_cost, 0), 'Approved requests show as GH₵3,500 committed cost');
const rqBill = (await one(`select bill_requests($1::uuid[], $2, '2026-12-05', 'INV-778') id`, [[rq1.id, rq2], sup])).id;
const rbl = (await db.query(`select * from bill_lines where bill_id=$1 order by sort`, [rqBill])).rows;
ok(rbl.length === 2 && rbl.every(l => l.project_id === np) && rbl[1].project_category === 'subcontract', 'Approved requests become one draft bill with each line tagged to the project');
await db.query(`update bill_lines set unit_cost=2400 where id=$1`, [rbl[1].id]);
await db.query(`select post_bill($1)`, [rqBill]);
kk = await one(`select * from project_kpis($1) where project_id=$2`, [cid, np]);
const cats = Object.fromEntries((await db.query(`select * from project_actuals_by_category($1)`, [np])).rows.map(r => [r.category, Number(r.actual)]));
ok(near(kk.committed_cost, 0) && near(kk.actual_cost, 3400) && near(cats.materials, 1000) && near(cats.subcontract, 2400),
   'Posting the bill turns commitment into actual cost: materials 1,000 and subcontract 2,400 at the real price');
const tagged = await one(`select sum(debit) v from journal_lines where project_id=$1`, [np]);
ok(near(tagged.v, 3400), 'The bill\'s cost lines are tagged to the project in the ledger (GH₵3,400); VAT and payables are not');
ok((await one(`select count(*) n from project_requests where id = any($1::uuid[]) and status='billed'`, [[rq1.id, rq2]])).n == 2, 'Requests are marked billed');
const cashAcct = (await one(`select id from accounts where company_id=$1 and system_key='cash'`, [cid])).id;
const fuelAcct = (await one(`select id from accounts where company_id=$1 and code='6300'`, [cid])).id;
await db.query(`select post_manual_journal($1,'2026-12-06','Fuel for site generator',$2::jsonb)`, [cid,
  JSON.stringify([{ account_id: fuelAcct, debit: 200, credit: 0, project_id: np }, { account_id: cashAcct, debit: 0, credit: 200 }])]);
kk = await one(`select * from project_kpis($1) where project_id=$2`, [cid, np]);
const rep = (await db.query(`select * from project_cost_report($1,'2026-12-01','2026-12-31',$2)`, [cid, np])).rows;
ok(near(kk.actual_cost, 3600) && rep.some(r => r.source === 'Journal' && near(r.amount, 200) && r.category === 'other' && r.account_code === '6300'),
   'Any other expense can be charged to the project with a manual journal (fuel GH₵200), and it shows in the cost report');
ok(rep.filter(r => r.in_ledger).reduce((a, r) => a + Number(r.amount), 0) === 3600, 'Every ledger-backed cost line in the report ties to the tagged ledger (GH₵3,600)');
const al = await one(`select * from project_budget_alerts($1) where project_id=$2`, [cid, np]);
ok(al && al.level === 'over' && al.used_pct === 120 && al.over_categories.includes('other'), 'Budget alert: the project is at 120% of its cost budget');
await as(PMU);
ok((await db.query(`select * from project_budget_alerts($1)`, [cid])).rows.every(r => r.manager_id === PMU), 'A project manager sees alerts only for projects they manage');
await as(OWNER);
const rq3 = (await one(`insert into project_requests (project_id,kind,description,qty,est_unit_cost) values ($1,'equipment','Scaffold hire, 1 week',1,700) returning id`, [np])).id;
await db.query(`select decide_request($1::uuid[], true)`, [[rq3]]);
const b3 = (await one(`select bill_requests($1::uuid[], $2, '2026-12-07') id`, [[rq3], sup])).id;
ok((await one(`select a.system_key k from bill_lines l join accounts a on a.id = l.account_id where l.bill_id=$1`, [b3])).k === 'equipment_hire', 'Equipment hire requests go to 6250 Equipment and plant hire');
await db.query(`delete from bills where id=$1`, [b3]);
ok((await one(`select status from project_requests where id=$1`, [rq3])).status === 'approved', 'Deleting the draft bill puts the request back to approved (still committed)');

// HR training: requests, approval, scheduling, results, certificates, history
const tr1 = (await one(`insert into training_requests (employee_id,title,reason,est_cost,priority) values ($1,'First aid at work','Site safety requirement',800,'mandatory') returning id, number`, [yaw]));
ok(tr1.number === 'TR-00001', 'Training request TR-00001 raised for an employee');
let trSneak = false;
try { await db.query(`update training_requests set status='approved' where id=$1`, [tr1.id]); } catch (e) { trSneak = /Approve, Reject or Schedule/.test(e.message); }
ok(trSneak, 'A training request cannot be approved by editing it directly');
await db.query(`select decide_training_request($1, true, 'Book for December')`, [tr1.id]);
const trn = (await one(`insert into trainings (company_id,title,kind,provider,start_date,end_date,hours,cost,valid_months) values ($1,'First aid at work','certification','Red Cross Ghana','2026-12-10','2026-12-11',16,800,24) returning id`, [cid])).id;
await db.query(`select schedule_training_requests($1::uuid[], $2)`, [[tr1.id], trn]);
await db.query(`update training_attendees set status='passed', score=86, certificate_no='RC-2291' where training_id=$1 and employee_id=$2`, [trn, yaw]);
await db.query(`update trainings set status='completed' where id=$1`, [trn]);
const hist = await one(`select * from employee_training_history($1,$2)`, [cid, yaw]);
ok(hist && hist.status === 'passed' && String(new Date(hist.expires_on).toISOString()).startsWith('2028-12-11') && hist.cert_state === 'valid',
   'Training history: passed, certificate valid for 24 months to 11 Dec 2028');
ok((await one(`select status from training_requests where id=$1`, [tr1.id])).status === 'completed', 'Completing the session completes the request');
const trBill = (await one(`select bill_training($1,$2,'2026-12-11') id`, [trn, sup])).id;
await db.query(`select post_bill($1)`, [trBill]);
ok(near(await acctBal(cid, 'training'), 800), 'Training cost is billed to 6450 Staff training');
const STAFF = '66666666-6666-6666-6666-666666666666';
await db.exec(`insert into auth.users values ('${STAFF}','yaw@adom.com.gh')`);
await db.query(`select add_member($1,'yaw@adom.com.gh','staff')`, [cid]);
await db.query(`update employees set user_id=$1 where id=$2`, [STAFF, yaw]);
const otherEmp = (await one(`select id from employees where company_id=$1 and id<>$2 limit 1`, [cid, yaw])).id;
await as(STAFF); await db.exec('set role authenticated');
await db.query(`insert into training_requests (employee_id,title,reason) values ($1,'Forklift operator licence','To move pallets in the new warehouse')`, [yaw]);
let forOther = false, schedule = false;
try { await db.query(`insert into training_requests (employee_id,title) values ($1,'Excel advanced')`, [otherEmp]); } catch (e) { forOther = true; }
try { await db.query(`insert into trainings (company_id,title) values ($1,'Sneaky course')`, [cid]); } catch (e) { schedule = true; }
const mine = await one(`select (select count(*) from training_requests) r, (select count(*) from employee_training_history($1)) h`, [cid]);
await db.exec('reset role');
await as(OWNER);
ok(forOther && schedule && mine.r == 2 && mine.h == 1, 'Staff request training for themselves only, cannot create sessions, and see only their own requests and history');

for (const c of [cid, cid2]) {
  const t = await one(`select sum(debit) d, sum(credit) c from account_balances($1,'1900-01-01','2099-12-31')`, [c]);
  ok(Number(t.d) === Number(t.c), `Trial balance balances for ${c === cid ? 'Adom Distributors' : 'Adom Consulting'} after v1.4 postings`);
}

// ===================== v2.0 =====================
await as(OWNER);
const ACC = '77777777-7777-7777-7777-777777777777';
await db.exec(`insert into auth.users values ('${ACC}','efua.acc@adom.com.gh')`);
await db.query(`select add_member($1,'efua.acc@adom.com.gh','accountant')`, [cid]);
// Branches and cost centres
const brA = (await one(`insert into branches (company_id,code,name) values ($1,'ACC','Accra head office') returning id`, [cid])).id;
const brK = (await one(`insert into branches (company_id,code,name) values ($1,'KSI','Kumasi branch') returning id`, [cid])).id;
const ccOps = (await one(`insert into cost_centres (company_id,code,name) values ($1,'OPS','Operations') returning id`, [cid])).id;
const ccAdm = (await one(`insert into cost_centres (company_id,code,name) values ($1,'ADM','Administration') returning id`, [cid])).id;
const invK = (await one(`insert into invoices (company_id,customer_id,invoice_date,branch_id,cost_centre_id) values ($1,$2,'2026-12-03',$3,$4) returning id`, [cid, cust, brK, ccOps])).id;
await db.query(`insert into invoice_lines (invoice_id,company_id,description,qty,unit_price,taxable) values ($1,$2,'Consulting day',2,1000,true)`, [invK, cid]);
await db.query(`select post_invoice($1)`, [invK]);
const kLines = await one(`select count(*) n, count(*) filter (where l.branch_id=$2 and l.cost_centre_id=$3) tagged from journal_lines l join invoices i on i.journal_entry_id = l.entry_id where i.id=$1`, [invK, brK, ccOps]);
ok(kLines.n > 0 && kLines.n == kLines.tagged, `Every ledger line of a Kumasi invoice carries the branch and cost centre (${kLines.tagged} lines)`);
const plK = (await db.query(`select * from pl_by_dimension($1,'2026-12-01','2026-12-31','branch')`, [cid])).rows;
ok(plK.some(r => r.dim_id === brK && r.type === 'income' && near(r.amount, 2000)), 'Profit and loss by branch shows GH₵2,000 sales for Kumasi');
const salesK = (await db.query(`select * from account_balances($1,'2026-12-01','2026-12-31',$2)`, [cid, brK])).rows.reduce((a, r) => a + (r.type === 'income' ? Number(r.credit) - Number(r.debit) : 0), 0);
ok(near(salesK, 2000), 'Every report can be filtered to one branch');
const bCC = (await one(`insert into bills (company_id,supplier_id,bill_date,branch_id) values ($1,$2,'2026-12-04',$3) returning id`, [cid, sup, brA])).id;
const genAcct = (await one(`select id from accounts where company_id=$1 and system_key='expense'`, [cid])).id;
await db.query(`insert into bill_lines (bill_id,company_id,account_id,description,qty,unit_cost,taxable,cost_centre_id) values ($1,$2,$3,'Stationery',1,300,false,$4),($1,$2,$3,'Site cleaning',1,700,false,$5)`, [bCC, cid, genAcct, ccAdm, ccOps]);
await db.query(`select post_bill($1)`, [bCC]);
const ccSplit = await one(`select sum(l.debit) filter (where l.cost_centre_id=$2) adm, sum(l.debit) filter (where l.cost_centre_id=$3) ops, bool_and(l.branch_id=$4) br
  from journal_lines l join bills b on b.journal_entry_id = l.entry_id where b.id=$1 and l.debit > 0`, [bCC, ccAdm, ccOps, brA]);
ok(near(ccSplit.adm, 300) && near(ccSplit.ops, 700) && ccSplit.br, 'Bill lines post to their own cost centres (Admin 300, Operations 700) under the Accra branch');

// Approval chains
await db.query(`insert into approval_rules (company_id,doc_type,step_no,min_amount,approver_role,label) values
  ($1,'bill',1,0,'accountant','Finance check'),($1,'bill',2,5000,'owner','Managing director')`, [cid]);
const bA = (await one(`insert into bills (company_id,supplier_id,bill_date) values ($1,$2,'2026-12-05') returning id`, [cid, sup])).id;
await db.query(`insert into bill_lines (bill_id,company_id,account_id,description,qty,unit_cost,taxable) values ($1,$2,$3,'Generator service',1,6000,true)`, [bA, cid, genAcct]);
let blockedPost = '';
try { await db.query(`select post_bill($1)`, [bA]); } catch (e) { blockedPost = e.message; }
ok(/needs approval/.test(blockedPost), 'A GH₵6,000 bill cannot be posted before it is approved');
ok((await one(`select start_approval('bill',$1) n`, [bA])).n === 2, 'Submitting it creates two steps: finance check, then the managing director (over GH₵5,000)');
await as(ACC);
const accInbox = (await db.query(`select * from my_approvals($1)`, [cid])).rows;
ok(accInbox.length === 1 && accInbox[0].step_no === 1, 'The accountant sees step 1 in their approvals inbox');
await db.query(`select decide_approval($1, true, 'Checked against the job card')`, [accInbox[0].step_id]);
let accStep2 = false;
const st2 = (await one(`select id from approval_steps where doc_id=$1 and step_no=2`, [bA])).id;
try { await db.query(`select decide_approval($1, true)`, [st2]); } catch (e) { accStep2 = /cannot decide/.test(e.message); }
ok(accStep2, 'The accountant cannot approve the managing director\'s step');
await as(OWNER);
ok((await one(`select decide_approval($1, true) s`, [st2])).s === 'approved', 'The managing director approves the last step');
await db.query(`select post_bill($1)`, [bA]);
ok((await one(`select status from bills where id=$1`, [bA])).status === 'posted', 'The approved bill posts');
const bSmall = (await one(`insert into bills (company_id,supplier_id,bill_date) values ($1,$2,'2026-12-05') returning id`, [cid, sup])).id;
await db.query(`insert into bill_lines (bill_id,company_id,account_id,description,qty,unit_cost,taxable) values ($1,$2,$3,'Printer toner',1,400,true)`, [bSmall, cid, genAcct]);
await db.query(`select start_approval('bill',$1)`, [bSmall]);
await as(ACC);
await db.query(`select decide_approval((select id from approval_steps where doc_id=$1),true)`, [bSmall]);
await as(OWNER);
await db.query(`update bill_lines set unit_cost=900 where bill_id=$1`, [bSmall]);
ok((await one(`select approval_state('bill',$1) s`, [bSmall])).s === 'changed', 'Raising a bill after approval puts it back for approval');
let rejNoReason = false;
await db.query(`select start_approval('bill',$1)`, [bSmall]);
await as(ACC);
try { await db.query(`select decide_approval((select id from approval_steps where doc_id=$1 and status='pending' order by step_no limit 1),false,null)`, [bSmall]); } catch (e) { rejNoReason = /reason/.test(e.message); }
ok(rejNoReason, 'Rejecting needs a reason');
await as(OWNER);
// Purchase request chain above GH₵2,000
await db.query(`insert into approval_rules (company_id,doc_type,step_no,min_amount,approver_role,label) values ($1,'purchase_request',1,2000,'owner','Managing director')`, [cid]);
const prBig = (await one(`insert into project_requests (project_id,kind,description,qty,est_unit_cost) values ($1,'equipment','Excavator hire, 3 days',3,900) returning id`, [np])).id;
await db.query(`select decide_request($1::uuid[], true)`, [[prBig]]);
ok((await one(`select status from project_requests where id=$1`, [prBig])).status === 'submitted' && (await one(`select approval_state('purchase_request',$1) s`, [prBig])).s === 'pending',
   'A GH₵2,700 purchase request goes on to the managing director after the first approval');
await db.query(`select decide_approval((select id from approval_steps where doc_id=$1),true)`, [prBig]);
ok((await one(`select status from project_requests where id=$1`, [prBig])).status === 'approved', 'When the chain finishes, the request is approved and committed');
// Expense claim chain above GH₵1,000
await db.query(`insert into approval_rules (company_id,doc_type,step_no,min_amount,approver_role,label) values ($1,'expense_claim',1,1000,'accountant','Finance')`, [cid]);
const empX = (await one(`select id from employees where company_id=$1 limit 1`, [cid])).id;
const xBig = (await one(`insert into expense_claims (company_id,employee_id,expense_date,description,currency,amount,exchange_rate,amount_home,account_id,status)
  values ($1,$2,'2026-12-06','Hotel, Tamale site visit','GHS',1200,1,1200,$3,'submitted') returning id`, [cid, empX, genAcct])).id;
await db.query(`select decide_expense($1, true)`, [xBig]);
ok((await one(`select status, journal_entry_id from expense_claims where id=$1`, [xBig])).journal_entry_id === null, 'An expense claim over GH₵1,000 is not posted until finance approves');
await as(ACC);
await db.query(`select decide_approval((select id from approval_steps where doc_id=$1),true)`, [xBig]);
await as(OWNER);
const xDone = await one(`select status, journal_entry_id from expense_claims where id=$1`, [xBig]);
ok(xDone.status === 'approved' && xDone.journal_entry_id, 'Finance approval posts the claim to the books');

// Audit trail
await db.query(`update customers set name='Kumasi Mart Ltd', phone='0244 000 111' where id=$1`, [cust]);
const aud = await one(`select * from audit_trail($1, current_date - 1, current_date, 'customers', null, null, $2)`, [cid, cust]);
ok(aud && aud.user_email === 'owner@adom.com.gh' && aud.new_data.name === 'Kumasi Mart Ltd' && aud.old_data.name === 'Kumasi Mart' && !('created_at' in aud.new_data),
   'Audit trail records who changed a customer, with only the changed fields, old and new');
await db.query(`update employees set basic_salary = basic_salary + 100 where id=$1`, [empX]);
ok((await one(`select count(*) n from audit_log where table_name='employees' and row_id=$1 and new_data->>'basic_salary' is not null`, [empX])).n >= 1, 'Salary changes are in the audit trail');
ok((await one(`select count(*) n from audit_log where action like 'approval.%' and row_id=$1`, [bA])).n >= 3, 'Approval submissions and decisions are in the audit trail');

// Bank and cash transactions
const bankA = (await one(`select id from accounts where company_id=$1 and system_key='bank'`, [cid])).id;
const cashA = (await one(`select id from accounts where company_id=$1 and system_key='cash'`, [cid])).id;
const otherInc = (await one(`select id from accounts where company_id=$1 and code='4900'`, [cid])).id;
const fuelA = (await one(`select id from accounts where company_id=$1 and code='6300'`, [cid])).id;
const arA = (await one(`select id from accounts where company_id=$1 and system_key='ar'`, [cid])).id;
const bank0 = await acctBal(cid, 'bank'), cash0 = await acctBal(cid, 'cash');
await db.query(`select post_cash_transaction($1,'receive','2026-12-07',$2,$3,5000,'Rent received for spare office','Mensah Ventures','RCT-11',$4)`, [cid, bankA, otherInc, brA]);
const spend = (await one(`select post_cash_transaction($1,'spend','2026-12-07',$2,$3,300,'Fuel for delivery van','Shell Spintex',null,$4,$5) id`, [cid, cashA, fuelA, brK, ccOps])).id;
await db.query(`select post_cash_transaction($1,'transfer','2026-12-07',$2,$3,1000,'Cash float for Kumasi')`, [cid, bankA, cashA]);
ok(near(await acctBal(cid, 'bank') - bank0, 4000) && near(await acctBal(cid, 'cash') - cash0, 700), 'Money in GH₵5,000, transfer GH₵1,000 to cash and GH₵300 fuel: bank +4,000, cash +700');
const fuelTag = await one(`select l.branch_id, l.cost_centre_id from journal_lines l join cash_transactions c on c.journal_entry_id = l.entry_id where c.id=$1 and l.account_id=$2`, [spend, fuelA]);
ok(fuelTag.branch_id === brK && fuelTag.cost_centre_id === ccOps, 'Money-out lines carry the branch and cost centre');
await db.query(`select void_cash_transaction($1,'2026-12-08')`, [spend]);
ok(near(await acctBal(cid, 'cash') - cash0, 1000) && (await one(`select status from cash_transactions where id=$1`, [spend])).status === 'voided', 'Voiding the fuel payment reverses it in the books');
let badCash = 0;
try { await db.query(`select post_cash_transaction($1,'spend','2026-12-07',$2,$3,10,'x')`, [cid, fuelA, cashA]); } catch (e) { badCash++; }
try { await db.query(`select post_cash_transaction($1,'receive','2026-12-07',$2,$3,10,'x')`, [cid, bankA, arA]); } catch (e) { badCash += /own documents/.test(e.message) ? 1 : 0; }
ok(badCash === 2, 'Money in/out must use a bank account, and cannot touch receivables directly (use a receipt)');

// General ledger with running balance and source documents
const gl = (await db.query(`select * from general_ledger($1,$2,'2026-12-01','2026-12-31')`, [cid, bankA])).rows;
const bankDec = (await db.query(`select * from account_balances($1,'1900-01-01','2026-12-31')`, [cid])).rows.find(r => r.account_id === bankA);
ok(gl.length > 0 && near(gl[gl.length - 1].balance, Number(bankDec.debit) - Number(bankDec.credit)) && gl.every(r => r.ref_label),
   `General ledger for the bank: ${gl.length} December lines, running balance ends at the account balance, every line names its source document`);
const glCash = (await db.query(`select * from general_ledger($1,$2,'2026-12-01','2026-12-31')`, [cid, cashA])).rows;
ok(glCash.some(r => r.ref_path && r.ref_path.startsWith('/bank-cash')), 'Ledger lines link back to the document that created them');

// Every transaction reached the books: control accounts against their documents
const checks = (await db.query(`select * from ledger_checks($1)`, [cid])).rows;

for (const c of checks) ok(c.ok, `Ledger check: ${c.check_name} (ledger ${Number(c.ledger).toFixed(2)}, documents ${Number(c.documents).toFixed(2)}${Number(c.direct) ? ', posted directly ' + Number(c.direct).toFixed(2) : ''})`);
const unp = (await db.query(`select * from unposted_documents($1)`, [cid])).rows;
ok(unp.find(u => u.kind === 'Draft supplier bills').n >= 1, 'Unposted-documents list shows the draft bill still waiting for approval');

// Opening balances in a new company
const cid3 = (await one(`select create_company('Opening Test Ltd') id`)).id;
await db.query(`update companies set require_project_registration=false where id=$1`, [cid3]); // the v2.3 project gate is tested on its own company
const a3 = async (k) => (await one(`select id from accounts where company_id=$1 and (system_key=$2 or code=$2)`, [cid3, k])).id;
let arInTb = false;
try { await db.query(`select post_opening_balances($1,'2026-11-30',$2::jsonb)`, [cid3, JSON.stringify([{ account_id: await a3('ar'), debit: 100, credit: 0 }])]); } catch (e) { arInTb = /opening customer/.test(e.message); }
ok(arInTb, 'Receivables cannot be keyed into the opening trial balance (they come from customer balances)');
await db.query(`select post_opening_balances($1,'2026-11-30',$2::jsonb)`, [cid3, JSON.stringify([
  { account_id: await a3('bank'), debit: 10000, credit: 0 }, { account_id: await a3('2400'), debit: 0, credit: 4000 }])]);
const c3 = (await one(`insert into customers (company_id,name) values ($1,'Old Customer') returning id`, [cid3])).id;
const s3 = (await one(`insert into suppliers (company_id,name) values ($1,'Old Supplier') returning id`, [cid3])).id;
const p3 = (await one(`insert into products (company_id,sku,name,price) values ($1,'P1','Paint 4L',120) returning id`, [cid3])).id;
await db.query(`select opening_receivable($1,'2026-11-30',1500,'INV-OLD-77','2026-12-15')`, [c3]);
await db.query(`select opening_payable($1,'2026-11-30',800,'SUP-991')`, [s3]);
await db.query(`select adjust_stock($1,10,50,'2026-11-30','opening')`, [p3]);
const ob = await one(`select sum(l.debit - l.credit) v from journal_lines l join accounts a on a.id = l.account_id where a.company_id=$1 and a.system_key='opening'`, [cid3]);
ok(near(ob.v, -(10000 - 4000) - 1500 + 800 - 500), 'Opening balance equity balances everything: GH₵7,200 credit');
const chk3 = (await db.query(`select * from ledger_checks($1)`, [cid3])).rows;
ok(chk3.every(c => c.ok), 'After opening balances the ledger agrees with customers, suppliers and stock');
ok(near((await one(`select owed from party_balances($1,'customer') where id=$2`, [cid3, c3])).owed, 1500), 'The old customer owes GH₵1,500 and can be sent a statement');

// Scale: payroll for 150 staff, split by branch
const br3 = (await one(`insert into branches (company_id,code,name) values ($1,'TKD','Takoradi') returning id`, [cid3])).id;
await db.query(`insert into employees (company_id,full_name,basic_salary,allowances,branch_id,bank_name,bank_account)
  select $1, 'Staff ' || g, 2500 + (g % 7) * 400, 300, case when g % 3 = 0 then $2::uuid end, 'GCB Bank', '10' || lpad(g::text, 8, '0') from generate_series(1,150) g`, [cid3, br3]);
const t0 = Date.now();
const run3 = (await one(`select prepare_payroll($1,'2026-12-01') id`, [cid3])).id;
await db.query(`select post_payroll($1)`, [run3]);
const ms = Date.now() - t0;
const r3 = await one(`select r.gross, (select count(*) from payslips where run_id=r.id) n,
  (select sum(debit) from journal_lines l join accounts a on a.id=l.account_id where l.entry_id=r.journal_entry_id and a.system_key='salaries') sal,
  (select sum(debit) from journal_lines l join accounts a on a.id=l.account_id where l.entry_id=r.journal_entry_id and a.system_key='salaries' and l.branch_id=$2) tkd
  from payroll_runs r where r.id=$1`, [run3, br3]);
ok(r3.n == 150 && near(r3.sal, r3.gross) && Number(r3.tkd) > 0, `Payroll for 150 staff prepared and posted in ${(ms / 1000).toFixed(1)} s; salary cost split by branch (Takoradi GH₵${Number(r3.tkd).toLocaleString()})`);
const pb = (await db.query(`select * from party_balances($1,'customer',null,2,0)`, [cid])).rows;
ok(pb.length <= 2 && Number(pb[0].total_rows) >= pb.length, 'Customer list pages through large customer bases');

for (const c of [cid, cid2, cid3]) {
  const t = await one(`select sum(debit) d, sum(credit) c from account_balances($1,'1900-01-01','2099-12-31')`, [c]);
  ok(Number(t.d) === Number(t.c), `Trial balance balances after v2.0 postings (${c === cid ? 'Adom Distributors' : c === cid2 ? 'Adom Consulting' : 'Opening Test'})`);
}

// ===================== v2.1 =====================
// Inventory, purchasing and the project lifecycle (in Opening Test Ltd, which has no approval rules)
await as(OWNER);
const whMain = (await one(`select id, code from warehouses where company_id=$1 and is_default`, [cid3]));
ok(whMain && whMain.code === 'MAIN', 'Every company gets a main store');
const whSite = (await one(`insert into warehouses (company_id,code,name,kind) values ($1,'SITE1','Airport site store','site') returning id`, [cid3])).id;
const cem = (await one(`insert into products (company_id,sku,name,unit,price,category,reorder_level,preferred_supplier_id,item_type) values ($1,'CEM50','Cement 50 kg','bag',110,'Building',100,$2,'stock') returning id`, [cid3, s3])).id;
const svc = (await one(`insert into products (company_id,sku,name,unit,price,item_type) values ($1,'INST','Installation','job',500,'service') returning id`, [cid3])).id;
const po = (await one(`insert into purchase_orders (company_id,supplier_id,order_date,expected_date) values ($1,$2,'2026-12-01','2026-12-05') returning id, number, warehouse_id`, [cid3, s3]));
await db.query(`insert into po_lines (po_id,company_id,product_id,description,qty,unit_cost) values ($1,$2,$3,'Cement 50 kg',100,80)`, [po.id, cid3, cem]);
ok(po.number === 'PO-00001' && po.warehouse_id === whMain.id, 'Purchase order PO-00001 raised to the main store');
let poSneak = false;
try { await db.query(`update purchase_orders set status='approved' where id=$1`, [po.id]); } catch (e) { poSneak = /Use Approve/.test(e.message); }
ok(poSneak, 'A purchase order cannot be approved by editing it directly');
await db.query(`select approve_po($1)`, [po.id]);
const poLine = (await one(`select id from po_lines where po_id=$1`, [po.id])).id;
let overRecv = false;
try { await db.query(`select receive_po($1,$2::jsonb,'2026-12-04')`, [po.id, JSON.stringify([{ line_id: poLine, qty: 120 }])]); } catch (e) { overRecv = /at most 100/.test(e.message); }
ok(overRecv, 'You cannot receive more than was ordered');
const grn = (await one(`select receive_po($1,$2::jsonb,'2026-12-04',null,'WB-5521') id`, [po.id, JSON.stringify([{ line_id: poLine, qty: 60 }])])).id;
const g1 = await one(`select g.number, o.status, p.stock_qty, p.cost, (select qty from stock_levels where product_id=p.id and warehouse_id=$3) lvl
  from goods_receipts g join purchase_orders o on o.id=g.po_id, products p where g.id=$1 and p.id=$2`, [grn, cem, whMain.id]);
ok(g1.number === 'GRN-00001' && g1.status === 'partial' && near(g1.stock_qty, 60) && near(g1.lvl, 60) && near(g1.cost, 80),
   'Goods received note GRN-00001: 60 of 100 bags into the main store at GH₵80, order now part-received');
ok(near(await acctBal(cid3, 'grni'), -4800), 'Receiving accrues GH₵4,800 to Goods received not invoiced until the supplier bills');
const pob = (await one(`select bill_from_po($1,'SINV-301','2026-12-06') id`, [po.id])).id;
const pobl = await one(`select qty, po_line_id from bill_lines where bill_id=$1`, [pob]);
ok(near(pobl.qty, 60) && pobl.po_line_id === poLine, 'Billing from the order picks up exactly what was received (60 bags), matched to the order line');
await db.query(`update bill_lines set unit_cost=82 where bill_id=$1`, [pob]);
await db.query(`select post_bill($1)`, [pob]);
ok(near(await acctBal(cid3, 'grni'), 0) && near(await acctBal(cid3, 'ppv'), 120) && near((await one(`select stock_qty from products where id=$1`, [cem])).stock_qty, 60),
   'Three-way match: the bill clears the accrual, the GH₵2 a bag price rise goes to price variance (GH₵120), stock is not counted twice');

// Project lifecycle and materials issued from the store
const prj = (await one(`insert into projects (company_id,name,customer_id,start_date,end_date,hourly_rate,status) values ($1,'Airport canopy',$2,'2026-12-01','2027-01-31',0,'done') returning id, status`, [cid3, c3]));
ok(prj.status === 'planned', 'A new project starts as planned (it cannot be created already finished)');
let stSneak = false;
try { await db.query(`update projects set status='active' where id=$1`, [prj.id]); } catch (e) { stSneak = /Use Start/.test(e.message); }
ok(stSneak, 'Project status changes only through Start, Hold, Complete, Close and Reopen');
let holdNoReason = false;
await db.query(`select set_project_status($1,'start',null,'2026-12-02')`, [prj.id]);
try { await db.query(`select set_project_status($1,'hold')`, [prj.id]); } catch (e) { holdNoReason = /reason/.test(e.message); }
await db.query(`select set_project_status($1,'hold','Waiting for the client''s drawings')`, [prj.id]);
await db.query(`select set_project_status($1,'resume')`, [prj.id]);
const pr1 = await one(`select status, actual_start from projects where id=$1`, [prj.id]);
const log1 = (await db.query(`select to_status from project_status_log where project_id=$1 order by changed_at, id`, [prj.id])).rows.map(r => r.to_status);
ok(pr1.status === 'active' && String(new Date(pr1.actual_start).toISOString()).startsWith('2026-12-02') && holdNoReason && log1.join() === 'active,on_hold,active',
   'Start sets the actual start date; putting it on hold needs a reason; every change is in the status history');
const iss = (await one(`insert into stock_issues (company_id,warehouse_id,project_id,issue_date,issued_to) values ($1,$2,$3,'2026-12-07','Kwame, site foreman') returning id, number`, [cid3, whMain.id, prj.id]));
await db.query(`insert into stock_issue_lines (issue_id,company_id,product_id,qty,billable,bill_price) values ($1,$2,$3,20,true,110)`, [iss.id, cid3, cem]);
let svcIssue = false;
const issBad = (await one(`insert into stock_issues (company_id,warehouse_id,project_id) values ($1,$2,$3) returning id`, [cid3, whMain.id, prj.id])).id;
await db.query(`insert into stock_issue_lines (issue_id,company_id,product_id,qty) values ($1,$2,$3,1)`, [issBad, cid3, svc]);
try { await db.query(`select post_stock_issue($1)`, [issBad]); } catch (e) { svcIssue = /not a stock item/.test(e.message); }
await db.query(`delete from stock_issues where id=$1`, [issBad]);
await db.query(`select post_stock_issue($1)`, [iss.id]);
const ret = (await one(`insert into stock_issues (company_id,kind,warehouse_id,project_id,issue_date) values ($1,'return',$2,$3,'2026-12-09') returning id, number`, [cid3, whMain.id, prj.id]));
await db.query(`insert into stock_issue_lines (issue_id,company_id,product_id,qty,billable,bill_price) values ($1,$2,$3,5,true,110)`, [ret.id, cid3, cem]);
await db.query(`select post_stock_issue($1)`, [ret.id]);
const matCost = (await db.query(`select * from project_actuals_by_category($1)`, [prj.id])).rows.find(r => r.category === 'materials');
ok(iss.number === 'ISS-00001' && ret.number === 'RET-00001' && svcIssue && near((await one(`select stock_qty from products where id=$1`, [cem])).stock_qty, 45) && matCost && near(matCost.actual, 1200),
   'Store issues 20 bags to the project (ISS-00001) and 5 come back (RET-00001): stock 45, project materials cost GH₵1,200 at average cost');
const projMat = await one(`select sum(l.debit - l.credit) v from journal_lines l join accounts a on a.id=l.account_id where l.project_id=$1 and a.system_key='project_materials'`, [prj.id]);
ok(near(projMat.v, 1200), 'The issue and return are tagged to the project in the ledger (5200 Project materials, GH₵1,200)');

// A purchase order delivered straight to the project site
const po2 = (await one(`insert into purchase_orders (company_id,supplier_id,project_id,order_date) values ($1,$2,$3,'2026-12-08') returning id`, [cid3, s3, prj.id])).id;
await db.query(`insert into po_lines (po_id,company_id,description,qty,unit_cost,project_id,taxable) values ($1,$2,'Steel roofing sheets, delivered to site',40,150,$3,true)`, [po2, cid3, prj.id]);
await db.query(`select approve_po($1)`, [po2]);
let kp = await one(`select * from project_kpis($1) where project_id=$2`, [cid3, prj.id]);
ok(near(kp.committed_cost, 6000), 'An approved order for the project shows GH₵6,000 committed cost before delivery');
const po2l = (await one(`select id from po_lines where po_id=$1`, [po2])).id;
await db.query(`select receive_po($1,$2::jsonb,'2026-12-10')`, [po2, JSON.stringify([{ line_id: po2l, qty: 40 }])]);
kp = await one(`select * from project_kpis($1) where project_id=$2`, [cid3, prj.id]);
ok(near(kp.committed_cost, 0) && near(kp.actual_cost, 7200) && near((await one(`select stock_qty from products where id=$1`, [cem])).stock_qty, 45),
   'Delivered to site: commitment becomes actual project cost (GH₵7,200 in total) without passing through the store');

// Transfers and a stocktake
const trf = (await one(`insert into stock_transfers (company_id,from_warehouse_id,to_warehouse_id,transfer_date) values ($1,$2,$3,'2026-12-11') returning id, number`, [cid3, whMain.id, whSite])).id;
await db.query(`insert into stock_transfer_lines (transfer_id,company_id,product_id,qty) values ($1,$2,$3,10)`, [trf, cid3, cem]);
await db.query(`select post_transfer($1)`, [trf]);
const lv = await one(`select (select qty from stock_levels where product_id=$1 and warehouse_id=$2) m, (select qty from stock_levels where product_id=$1 and warehouse_id=$3) s, (select stock_qty from products where id=$1) t`, [cem, whMain.id, whSite]);
ok(near(lv.m, 35) && near(lv.s, 10) && near(lv.t, 45), 'Transfer of 10 bags to the site store: main 35, site 10, total still 45');
let tooMuch = false;
const trf2 = (await one(`insert into stock_transfers (company_id,from_warehouse_id,to_warehouse_id) values ($1,$2,$3) returning id`, [cid3, whSite, whMain.id])).id;
await db.query(`insert into stock_transfer_lines (transfer_id,company_id,product_id,qty) values ($1,$2,$3,50)`, [trf2, cid3, cem]);
try { await db.query(`select post_transfer($1)`, [trf2]); } catch (e) { tooMuch = /in stock at Airport site store/.test(e.message); }
ok(tooMuch, 'A store cannot send more than it holds');
const cnt = (await one(`select start_stock_count($1,$2,'2026-12-12') id`, [cid3, whSite])).id;
const cl = await one(`select id, system_qty from stock_count_lines where count_id=$1 and product_id=$2`, [cnt, cem]);
await db.query(`update stock_count_lines set counted_qty=8 where id=$1`, [cl.id]);
await db.query(`update stock_count_lines set counted_qty=system_qty where count_id=$1 and counted_qty is null`, [cnt]);
const cres = (await one(`select post_stock_count($1) r`, [cnt])).r;
ok(near(cl.system_qty, 10) && near(cres.loss, 160) && near((await one(`select stock_qty from products where id=$1`, [cem])).stock_qty, 43) && near(await acctBal(cid3, 'stock_adj'), 160),
   'Stocktake at the site finds 8 of 10 bags: GH₵160 written off to stock adjustments, stock now 43');
const sl = (await db.query(`select * from stock_ledger($1,$2,'2026-12-01','2026-12-31')`, [cid3, cem])).rows;
ok(sl.length === 6 && near(sl[sl.length - 1].balance, 43), `Stock ledger for cement lists all ${sl.length} movements with a running balance ending at 43`);
const ro = (await db.query(`select * from reorder_suggestions($1)`, [cid3])).rows.find(r => r.product_id === cem);
ok(ro && near(ro.on_order, 40) && ro.supplier_id === s3, 'Reorder list: cement is below its level of 100 even with 40 still on order, from the preferred supplier');

// Billing the client for materials, then closing out
const prjInv = (await one(`select invoice_project($1,'2026-12-31') id`, [prj.id])).id;
const pil = await one(`select qty, unit_price, description from invoice_lines where invoice_id=$1 and description like 'Materials%'`, [prjInv]);
ok(pil && near(pil.qty, 15) && near(pil.unit_price, 110), 'Invoicing the project bills net materials used: 15 bags at GH₵110');
await db.query(`select set_project_status($1,'complete',null,'2026-12-20')`, [prj.id]);
const draftIss = (await one(`insert into stock_issues (company_id,warehouse_id,project_id) values ($1,$2,$3) returning id`, [cid3, whMain.id, prj.id])).id;
const blocks = (await db.query(`select * from project_close_check($1)`, [prj.id])).rows;
let closeBlocked = '';
try { await db.query(`select set_project_status($1,'close','Handed over')`, [prj.id]); } catch (e) { closeBlocked = e.message; }
ok(blocks.some(b => b.severity === 'warn' && /not billed by the supplier/.test(b.item)) && blocks.some(b => b.severity === 'block' && /Draft stock issues/.test(b.item)) && /must be cleared/.test(closeBlocked),
   `Close-out checklist (${blocks.length} items) stops closing while a draft stock issue is open, and warns that the roofing sheets are not yet billed by the supplier`);
await db.query(`delete from stock_issues where id=$1`, [draftIss]);
await db.query(`select post_invoice($1)`, [prjInv]);
const blocks2 = (await db.query(`select * from project_close_check($1) where severity='block'`, [prj.id])).rows;
await db.query(`select set_project_status($1,'close','Handed over to the client')`, [prj.id]);
let lockedOut = false;
try { await db.query(`insert into stock_issues (company_id,warehouse_id,project_id) values ($1,$2,$3)`, [cid3, whMain.id, prj.id]); } catch (e) { lockedOut = /closed/.test(e.message); }
ok(blocks2.length === 0 && (await one(`select status from projects where id=$1`, [prj.id])).status === 'closed' && lockedOut,
   'With nothing blocking, the project closes; nothing more can be booked to it');
await db.query(`select set_project_status($1,'reopen','Snag list from the client')`, [prj.id]);
ok((await one(`select status from projects where id=$1`, [prj.id])).status === 'done', 'An accountant can reopen a closed project with a reason');

// Store role
const STORE = '88888888-8888-8888-8888-888888888888';
await db.exec(`insert into auth.users values ('${STORE}','store@opening.com.gh')`);
await db.query(`select add_member($1,'store@opening.com.gh','store')`, [cid3]);
await as(STORE); await db.exec('set role authenticated');
const storeSees = await one(`select (select count(*) from journal_lines) j, (select count(*) from stock_levels) l, (select count(*) from purchase_orders) o`);
await db.exec('reset role');
let storePosts = false;
const po3 = (await one(`insert into purchase_orders (company_id,supplier_id) values ($1,$2) returning id`, [cid3, s3])).id;
await db.query(`insert into po_lines (po_id,company_id,product_id,description,qty,unit_cost) values ($1,$2,$3,'Cement',10,80)`, [po3, cid3, cem]);
try { await db.query(`select approve_po($1)`, [po3]); } catch (e) { storePosts = true; }
await as(OWNER);
ok(storeSees.j == 0 && storeSees.l > 0 && storeSees.o > 0 && storePosts, 'The storekeeper sees stock and orders but not the ledger, and cannot approve orders');

const chk21 = (await db.query(`select * from ledger_checks($1)`, [cid3])).rows;
for (const c of chk21) ok(c.ok, `After v2.1: ${c.check_name} (ledger ${Number(c.ledger).toFixed(2)}, documents ${Number(c.documents).toFixed(2)})`);
for (const c of [cid, cid2, cid3]) {
  const t = await one(`select sum(debit) d, sum(credit) c from account_balances($1,'1900-01-01','2099-12-31')`, [c]);
  ok(Number(t.d) === Number(t.c), `Trial balance balances after v2.1 postings (${c === cid ? 'Adom Distributors' : c === cid2 ? 'Adom Consulting' : 'Opening Test'})`);
}

// ===================== v2.2 =====================
// A project's own site store, run by its team; document control; risk assessments
await as(OWNER);
const PM2 = '99999999-9999-9999-9999-999999999991', TEAM = '99999999-9999-9999-9999-999999999992', OTHER = '99999999-9999-9999-9999-999999999993';
await db.exec(`insert into auth.users values ('${PM2}','pm@opening.com.gh'),('${TEAM}','foreman@opening.com.gh'),('${OTHER}','clerk@opening.com.gh')`);
await db.query(`select add_member($1,'pm@opening.com.gh','project_manager')`, [cid3]);
await db.query(`select add_member($1,'foreman@opening.com.gh','staff')`, [cid3]);
await db.query(`select add_member($1,'clerk@opening.com.gh','staff')`, [cid3]);
const foreman = (await one(`insert into employees (company_id,full_name,basic_salary,user_id) values ($1,'Kwame Foreman',3000,$2) returning id`, [cid3, TEAM])).id;
const prj2 = (await one(`insert into projects (company_id,name,customer_id,start_date,end_date,hourly_rate,manager_id) values ($1,'Tema substation',$2,'2026-12-01','2027-03-31',0,$3) returning id, number`, [cid3, c3, PM2]));
await db.query(`insert into project_assignments (company_id,project_id,employee_id,employee_company_id,role,start_date) values ($1,$2,$3,$1,'Site foreman','2026-12-01')`, [cid3, prj2.id, foreman]);
const site2 = (await one(`insert into warehouses (company_id,code,name,kind,project_id) values ($1,'SITE-TEMA','Tema substation site store','site',$2) returning id`, [cid3, prj2.id])).id;

// Stock request: site asks, main store sends, site confirms what arrived
await as(PM2);
const srq = (await one(`insert into stock_requests (project_id,from_warehouse_id,to_warehouse_id,needed_by,status) values ($1,$2,$3,'2026-12-14','submitted') returning id, number`, [prj2.id, whMain.id, site2]));
const srl = (await one(`insert into stock_request_lines (request_id,company_id,product_id,qty) values ($1,$2,$3,20) returning id`, [srq.id, cid3, cem])).id;
let pmSend = false;
try { await db.query(`select dispatch_stock_request($1,$2::jsonb,'2026-12-13')`, [srq.id, JSON.stringify([{ line_id: srl, qty: 20 }])]); } catch (e) { pmSend = /supplying store/.test(e.message); }
await as(OWNER);
await db.query(`select dispatch_stock_request($1,$2::jsonb,'2026-12-13','Truck GT 4471-22')`, [srq.id, JSON.stringify([{ line_id: srl, qty: 20 }])]);
const trv = await one(`select (select qty from stock_levels where product_id=$1 and warehouse_id=$2) main, (select sl.qty from stock_levels sl join warehouses w on w.id=sl.warehouse_id where sl.product_id=$1 and w.kind='transit') transit`, [cem, whMain.id]);
ok(srq.number === 'SRQ-00001' && pmSend && near(trv.main, 15) && near(trv.transit, 20), 'Site stock request SRQ-00001: only the main store can send it; 20 bags leave the main store and are in transit');
await as(TEAM);
const rcv = (await one(`select receive_stock_request($1,$2::jsonb,'2026-12-14','2 bags burst on the truck') r`, [srq.id, JSON.stringify([{ line_id: srl, qty: 18 }])])).r;
const af = await one(`select (select qty from stock_levels where product_id=$1 and warehouse_id=$2) site, (select stock_qty from products where id=$1) total,
  (select sl.qty from stock_levels sl join warehouses w on w.id=sl.warehouse_id where sl.product_id=$1 and w.kind='transit') transit`, [cem, site2]);
ok(near(rcv.lost_value, 160) && near(af.site, 18) && near(af.transit, 0) && near(af.total, 41), 'The foreman confirms 18 arrived: site store 18, 2 bags (GH₵160) written off as lost in transit');

// Materials plan and daily usage from the site store
await as(PM2);
await db.query(`insert into project_material_plan (project_id,product_id,planned_qty) values ($1,$2,15)`, [prj2.id, cem]);
await as(TEAM);
const task2 = null;
const use1 = (await one(`insert into stock_issues (company_id,warehouse_id,project_id,issue_date,issued_to) values ($1,$2,$3,'2026-12-15','Foundation pour, bay 1') returning id`, [cid3, site2, prj2.id])).id;
await db.query(`insert into stock_issue_lines (issue_id,company_id,product_id,qty) values ($1,$2,$3,16)`, [use1, cid3, cem]);
await db.query(`select post_stock_issue($1)`, [use1]);
let fromMain = false;
const use2 = (await one(`insert into stock_issues (company_id,warehouse_id,project_id) values ($1,$2,$3) returning id`, [cid3, whMain.id, prj2.id])).id;
await db.query(`insert into stock_issue_lines (issue_id,company_id,product_id,qty) values ($1,$2,$3,1)`, [use2, cid3, cem]);
try { await db.query(`select post_stock_issue($1)`, [use2]); } catch (e) { fromMain = /site store/.test(e.message); }
await as(OWNER); await db.query(`delete from stock_issues where id=$1`, [use2]); await as(TEAM);
const mu = await one(`select * from project_material_usage($1) where product_id=$2`, [prj2.id, cem]);
ok(near(mu.used, 16) && near(mu.at_site, 2) && mu.over === true && near(mu.used_pct, 107) && fromMain,
   'The foreman records usage from the site store (16 bags, 107% of the 15 planned, flagged over plan) but cannot take stock from the main store');
await as(OTHER);
let outsider = false;
try { await db.query(`select start_stock_count($1,$2)`, [cid3, site2]); } catch (e) { outsider = /cannot count/.test(e.message); }
ok(outsider, 'Staff who are not on the project cannot work its site store');

// Site stocktake: team counts, project manager approves up to the company limit, differences are project wastage
await as(TEAM);
const sc = (await one(`select start_stock_count($1,$2,'2026-12-20') id`, [cid3, site2])).id;
await db.query(`update stock_count_lines set counted_qty = case when product_id=$2 then 1 else system_qty end where count_id=$1`, [sc, cem]);
let teamPost = false, overLimit = false;
try { await db.query(`select post_stock_count($1)`, [sc]); } catch (e) { teamPost = /project manager/.test(e.message); }
await as(OWNER); await db.query(`update companies set site_count_limit=50 where id=$1`, [cid3]); await as(PM2);
try { await db.query(`select post_stock_count($1)`, [sc]); } catch (e) { overLimit = /more than the GH₵ 50/.test(e.message); }
await as(OWNER); await db.query(`update companies set site_count_limit=1000 where id=$1`, [cid3]); await as(PM2);
await db.query(`select post_stock_count($1)`, [sc]);
const wst = await one(`select sum(l.debit - l.credit) v from journal_lines l join accounts a on a.id=l.account_id join journal_entries e on e.id=l.entry_id where e.source_type='stock_count' and l.project_id=$1 and a.system_key='project_materials'`, [prj2.id]);
const mu2 = await one(`select * from project_material_usage($1) where product_id=$2`, [prj2.id, cem]);
ok(teamPost && overLimit && near(wst.v, 80) && near(mu2.wastage, 1) && near(mu2.wastage_value, 80),
   'Site count finds 1 bag missing: the foreman cannot post it, the PM can within the GH₵1,000 limit (not above GH₵50), and GH₵80 goes to the project as wastage');

// Documents: register, revisions, review, transmittal and client response
await as(PM2);
await db.query(`select standard_doc_requirements($1)`, [prj2.id]);
const sd = (await one(`insert into doc_register (company_id,project_id,doc_type,title,discipline) values ($1,$2,'shop_drawing','33 kV switchgear foundation','civil') returning id, number`, [cid3, prj2.id]));
await as(TEAM);
const rA = (await one(`select add_revision($1,$2,'SD-0001-A.pdf',204800,'application/pdf','First issue') id`, [sd.id, `${cid3}/${prj2.id}/a.pdf`])).id;
let sneakRev = false, teamReview = false;
try { await db.query(`insert into doc_revisions (company_id,doc_id,seq,rev,status) values ($1,$2,9,'Z','approved')`, [cid3, sd.id]); } catch (e) { sneakRev = /Upload new revision/.test(e.message); }
await db.query(`select submit_revision($1)`, [rA]);
try { await db.query(`select review_revision($1,true)`, [rA]); } catch (e) { teamReview = /project manager/.test(e.message); }
await as(PM2);
const rv = (await one(`select review_revision($1,true,'OK to send') s`, [rA])).s;
ok(sd.number === `${prj2.number}-SD-0001` && rv === 'ready' && sneakRev && teamReview,
   `Shop drawing ${sd.number} rev A: the foreman uploads and submits, only the PM can review it, and approved it is ready to send to the consultant`);
const trm = (await one(`insert into transmittals (company_id,project_id,to_party,to_person,purpose) values ($1,$2,'GRIDCo Engineering','Ing. Mensah','for_approval') returning id, number`, [cid3, prj2.id]));
const ti = (await one(`insert into transmittal_items (transmittal_id,company_id,revision_id) values ($1,$2,$3) returning id`, [trm.id, cid3, rA])).id;
await db.query(`select send_transmittal($1,'2026-12-05')`, [trm.id]);
const sent = await one(`select t.status, t.response_due, r.status rs from transmittals t, doc_revisions r where t.id=$1 and r.id=$2`, [trm.id, rA]);
await db.query(`select record_response($1,'approved_comments','Add anchor bolt schedule','2026-12-12')`, [ti]);
const back = await one(`select t.status, r.status rs, r.client_comments from transmittals t, doc_revisions r where t.id=$1 and r.id=$2`, [trm.id, rA]);
ok(sent.status === 'sent' && sent.rs === 'submitted' && String(new Date(sent.response_due).toISOString()).startsWith('2026-12-19') && back.status === 'responded' && back.rs === 'approved_comments',
   `Transmittal ${trm.number} sends rev A for approval (response due in 14 days); the consultant's "approved with comments" is recorded`);
const rB = (await one(`select add_revision($1,$2,'SD-0001-B.pdf',210000,'application/pdf','Anchor bolt schedule added') id`, [sd.id, `${cid3}/${prj2.id}/b.pdf`])).id;
const r0 = (await one(`select add_revision($1,$2,'SD-0001-0.pdf',210000,'application/pdf','Issued for construction',true) id`, [sd.id, `${cid3}/${prj2.id}/c.pdf`])).id;
const revs = (await db.query(`select rev, superseded_at is not null sup from doc_revisions where doc_id=$1 order by seq`, [sd.id])).rows;
ok(revs.map(r => r.rev + (r.sup ? '*' : '')).join(',') === 'A*,B*,0', 'New revisions B then 0 (issued for construction); older revisions are marked superseded');
let wrongFolder = false;
try { await db.query(`select add_revision($1,'00000000-0000-0000-0000-000000000000/x.pdf','x.pdf')`, [sd.id]); } catch (e) { wrongFolder = /folder/.test(e.message); }
ok(wrongFolder, 'A revision must point at a file in the company\'s own storage folder');

const conf = (await one(`insert into doc_register (company_id,project_id,doc_type,title,confidential) values ($1,$2,'contract','Main contract (signed)',true) returning id`, [cid3, prj2.id])).id;
const permit = (await one(`insert into doc_register (company_id,project_id,doc_type,title,expires_on) values ($1,$2,'permit','Hot work permit, bay 1',current_date + 10) returning id, number`, [cid3, prj2.id]));
await as(TEAM); await db.exec('set role authenticated');
const teamSees = await one(`select (select count(*) from doc_register where id=$1) c, (select count(*) from doc_register where project_id=$2) n`, [conf, prj2.id]);
await db.exec('reset role');
await as(PM2);
const expAl = (await db.query(`select * from doc_expiry_alerts($1)`, [cid3])).rows;
const foundDocs = (await db.query(`select * from search_documents($1,'SD-0001')`, [cid3])).rows;
ok(teamSees.c == 0 && teamSees.n == 2 && expAl.some(e => e.number === permit.number && e.days_left === 10) && foundDocs.length === 1 && foundDocs[0].rev === '0',
   'Confidential contract hidden from site staff; the permit shows in expiry alerts (10 days left); search finds the drawing at rev 0');

// Risk assessment: 5 x 5 matrix, controls, residual risk, PM and HSE sign-off
const ra = (await one(`insert into risk_assessments (company_id,project_id,title,activity,location,review_date) values ($1,$2,'Excavation and concrete pour','Foundations','Bay 1','2027-01-15') returning id, number`, [cid3, prj2.id]));
await db.query(`insert into risk_items (ra_id,hazard,who_at_risk,likelihood,severity,controls,owner) values ($1,'Trench collapse','Excavation crew',4,5,'Shoring above 1.2 m; daily inspection; no plant within 1 m of edge','Site foreman')`, [ra.id]);
await db.query(`insert into risk_items (ra_id,hazard,who_at_risk,likelihood,severity,controls,owner) values ($1,'Cement burns','Concrete gang',3,2,'Gloves, boots, eye protection; washing water on site','Site foreman')`, [ra.id]);
let noResidual = false;
try { await db.query(`select sign_risk_assessment($1,'pm')`, [ra.id]); } catch (e) { noResidual = /after controls/.test(e.message); }
await db.query(`update risk_items set residual_likelihood=2, residual_severity=5 where ra_id=$1 and hazard='Trench collapse'`, [ra.id]);
const s1 = (await one(`select sign_risk_assessment($1,'pm') s`, [ra.id])).s;
await as(OWNER); await db.query(`update projects set hse_officer_id=$1 where id=$2`, [TEAM, prj2.id]); await as(TEAM);
const s2 = (await one(`select sign_risk_assessment($1,'hse') s`, [ra.id])).s;
let lockedRa = false;
try { await db.query(`update risk_items set likelihood=1 where ra_id=$1`, [ra.id]); } catch (e) { lockedRa = /Revise/.test(e.message); }
const band = (await one(`select risk_band(4*5) h, risk_band(3*2) m, risk_band(2*2) l`)).h;
ok(ra.number === 'RA-00001' && noResidual && s1 === 'draft' && s2 === 'approved' && lockedRa && band === 'high',
   'Risk assessment RA-00001: a high risk (4×5) needs its residual rating, then the PM and the HSE officer sign and it is locked');
const chk = (await db.query(`select * from project_doc_check($1)`, [prj2.id])).rows;
ok(chk.length === 6 && chk.find(c => c.doc_type === 'risk_assessment').satisfied && !chk.find(c => c.doc_type === 'method_statement').satisfied,
   'Required documents: the signed risk assessment counts; the method statement is still missing before start');

// Close-out now checks the site store and handover documents
await as(PM2);
await db.query(`select set_project_status($1,'start',null,'2026-12-01')`, [prj2.id]);
await db.query(`select set_project_status($1,'complete',null,'2027-03-20')`, [prj2.id]);
const cc = (await db.query(`select * from project_close_check($1)`, [prj2.id])).rows;
ok(cc.some(c => c.item === 'Stock still in the site store' && c.severity === 'block') && cc.some(c => c.item === 'Handover documents missing' && Number(c.n) === 4),
   'Closing is blocked while stock sits in the site store and 4 handover documents are missing');
await as(TEAM);
const back2 = (await one(`insert into stock_transfers (company_id,from_warehouse_id,to_warehouse_id,transfer_date) values ($1,$2,$3,'2027-03-21') returning id`, [cid3, site2, whMain.id])).id;
await db.query(`insert into stock_transfer_lines (transfer_id,company_id,product_id,qty) values ($1,$2,$3,1)`, [back2, cid3, cem]);
await db.query(`select post_transfer($1)`, [back2]);
ok(!(await db.query(`select * from project_close_check($1)`, [prj2.id])).rows.some(c => c.item === 'Stock still in the site store'), 'The foreman sends the last bag back to the main store; the site store is empty');
await as(OWNER);
const chk22 = (await db.query(`select * from ledger_checks($1)`, [cid3])).rows;
for (const c of chk22) ok(c.ok, `After v2.2: ${c.check_name} (ledger ${Number(c.ledger).toFixed(2)}, documents ${Number(c.documents).toFixed(2)})`);
{ const t = await one(`select sum(debit) d, sum(credit) c from account_balances($1,'1900-01-01','2099-12-31')`, [cid3]);
  ok(Number(t.d) === Number(t.c), 'Trial balance balances after v2.2 postings'); }

// ===================== v2.3 =====================
// Project cycle and financial control (Project Management Meeting): a fresh company with the project gate switched on
await as(OWNER);
const cid4 = (await one(`select create_company('Volta Engineering Ltd') id`)).id;
const BD = 'aaaaaaaa-0000-0000-0000-000000000001', FIN = 'aaaaaaaa-0000-0000-0000-000000000002', ENG = 'aaaaaaaa-0000-0000-0000-000000000003';
await db.exec(`insert into auth.users values ('${BD}','bd@volta.com.gh'),('${FIN}','finance@volta.com.gh'),('${ENG}','engineer@volta.com.gh')`);
await db.query(`select add_member($1,'bd@volta.com.gh','sales')`, [cid4]);
await db.query(`select add_member($1,'finance@volta.com.gh','accountant')`, [cid4]);
await db.query(`select add_member($1,'engineer@volta.com.gh','project_manager')`, [cid4]);
const cust4 = (await one(`insert into customers (company_id,name) values ($1,'Ghana Grid Company') returning id`, [cid4])).id;
const cc4 = (await one(`insert into cost_centres (company_id,code,name) values ($1,'PRJ','Projects') returning id`, [cid4])).id;
ok((await one(`select count(*) n from cycle_responsibilities where company_id=$1`, [cid4])).n == 19, 'Responsibilities and reporting deadlines for each unit at each stage are set up (19 duties from the meeting)');
const unread = async (u, kind) => Number((await one(`select count(*) n from notifications where user_id=$1 and kind=$2`, [u, kind])).n);

// 1. Tender register and the pre-submission review
await as(BD);
const tndr = (await one(`insert into tenders (company_id,title,kind,customer_id,submission_deadline,est_value,est_cost,engineering_lead_id) values ($1,'Prestea 161 kV substation civil works','tender',$2,now() + interval '10 days',2500000,2050000,$3) returning id, number, status`, [cid4, cust4, ENG])).id;
ok(await unread(FIN, 'tender.registered') === 1 && await unread(ENG, 'tender.registered') === 1, 'Registering a tender notifies Finance and Engineering straight away');
let noReview = false;
try { await db.query(`select set_tender_status($1,'submitted')`, [tndr]); } catch (e) { noReview = /pre-submission review/.test(e.message); }
const trev = (await one(`insert into tender_reviews (tender_id,meeting_date,summary_shared_on,attendees,bd_input) values ($1,current_date,current_date - 2,'BD, Finance, Engineering','Client pays 60 days; competition from two local firms') returning id`, [tndr])).id;
ok(noReview && (await one(`select status from tenders where id=$1`, [tndr])).status === 'review', 'A tender cannot be submitted before the pre-submission review; scheduling it moves the tender to review');
await as(ENG);
let noInput = false, wrongUnit = false;
try { await db.query(`select sign_tender_review($1,'engineering')`, [trev]); } catch (e) { noInput = /input/.test(e.message); }
await db.query(`update tender_reviews set engineering_input='Programme 9 months; crane hire needed; cost estimate GH₵2.05m checked', decision='go' where id=$1`, [trev]);
await db.query(`select sign_tender_review($1,'engineering')`, [trev]);
await as(FIN);
try { await db.query(`select sign_tender_review($1,'engineering')`, [trev]); } catch (e) { wrongUnit = /Engineering/.test(e.message); }
await db.query(`update tender_reviews set finance_input='Bid bond 2% available; margin 18% acceptable; ask for 30% advance' where id=$1`, [trev]);
const clearedSig = await one(`select engineering_ok_by from tender_reviews where id=$1`, [trev]);
ok(noInput && wrongUnit && clearedSig.engineering_ok_by === null, 'Each unit records its input before signing, signs only for itself, and any later change to the inputs clears the signatures');
await as(ENG); await db.query(`select sign_tender_review($1,'engineering')`, [trev]);
await as(FIN); await db.query(`select sign_tender_review($1,'finance')`, [trev]);
await as(BD); await db.query(`select sign_tender_review($1,'bd')`, [trev]);
await db.query(`select set_tender_status($1,'submitted',null,current_date,2480000)`, [tndr]);
await db.query(`select award_tender($1,'contract','GRIDCo/PRS/2026/14',current_date,2480000,'Signed at GRIDCo head office')`, [tndr]);
const tndAfter = await one(`select status, awarded_value from tenders where id=$1`, [tndr]);
ok(tndAfter.status === 'awarded' && near(tndAfter.awarded_value, 2480000) && await unread(FIN, 'tender.awarded') === 1 && await unread(ENG, 'tender.awarded') === 1,
   'With all three sign-offs the tender is submitted; the signed contract is recorded and Finance and Engineering are notified at once');

// 2. No spending before Finance registers the project and approves its budget
await as(ENG);
const rogueProj = (await one(`insert into projects (company_id,name,customer_id,manager_id,start_date) values ($1,'Side job',$2,$3,current_date) returning id`, [cid4, cust4, ENG])).id;
let gate1 = false;
try { await db.query(`insert into project_requests (project_id,kind,description,qty,est_unit_cost) values ($1,'material','Cement',10,100)`, [rogueProj]); } catch (e) { gate1 = /not registered with Finance/.test(e.message); }
const unreg = (await db.query(`select * from unregistered_projects($1)`, [cid4])).rows;
ok(gate1 && unreg.some(u => u.project_id === rogueProj && !u.registered), 'A project Finance has not registered cannot spend anything, and it shows on the unregistered list');
let selfReg = false;
try { await db.query(`update projects set finance_registered_at=now() where id=$1`, [rogueProj]); } catch (e) { selfReg = /Finance/.test(e.message); }
await as(FIN);
const pj4 = (await one(`select register_project_from_tender($1,'Prestea substation civil works',$2,$3,current_date,current_date + 270) id`, [tndr, cc4, ENG])).id;
const pj4row = await one(`select number, finance_registered_at is not null reg, cost_centre_id, contract_value, contract_ref, budget_status from projects where id=$1`, [pj4]);
ok(selfReg && pj4row.reg && pj4row.cost_centre_id === cc4 && near(pj4row.contract_value, 2480000) && pj4row.contract_ref === 'GRIDCo/PRS/2026/14' && await unread(ENG, 'project.registered') === 1,
   `Finance registers ${pj4row.number} from the award with its cost centre and contract value; the project manager is notified (engineers cannot register themselves)`);
await as(ENG);
let gate2 = false, noLines = false;
try { await db.query(`insert into project_requests (project_id,kind,description,qty,est_unit_cost) values ($1,'material','Rebar',5,900)`, [pj4]); } catch (e) { gate2 = /no approved budget/.test(e.message); }
try { await db.query(`select submit_project_budget($1)`, [pj4]); } catch (e) { noLines = /cost budget/.test(e.message); }
await db.query(`insert into project_budget_lines (company_id,project_id,category,cost_budget,revenue_budget) values ($1,$2,'materials',1200000,0),($1,$2,'subcontract',850000,2480000)`, [cid4, pj4]);
await db.query(`select submit_project_budget($1,'Based on the tender estimate')`, [pj4]);
await as(FIN);
await db.query(`select approve_project_budget($1,true,'Approved as tendered')`, [pj4]);
await as(ENG);
await db.query(`insert into project_requests (project_id,kind,description,qty,est_unit_cost) values ($1,'material','Rebar',5,900)`, [pj4]);
ok(gate2 && noLines && await unread(FIN, 'budget.submitted') === 1 && await unread(ENG, 'budget.decided') === 1,
   'Registered but no approved budget: still no spending. The PM submits the budget, Finance approves it, and the first purchase request goes through');
await db.query(`update project_budget_lines set cost_budget = cost_budget + 50000 where project_id=$1 and category='materials'`, [pj4]);
ok((await one(`select budget_status from projects where id=$1`, [pj4])).budget_status === 'revised', 'Changing an approved budget sends it back to Finance as a revision');

// 3. Post-award meeting and progress reports to Finance
await db.query(`insert into project_meetings (project_id,kind,meeting_date,attendees,decisions,responsibilities) values ($1,'post_award',current_date,'MD, Finance, Engineering, BD','Mobilise in 2 weeks','Engineering: weekly reports; Finance: invoice 30% advance')`, [pj4]);
await db.query(`select set_project_status($1,'start',null,current_date - 40)`, [pj4]);
const dueBefore = (await db.query(`select * from reports_due($1)`, [cid4])).rows.find(r => r.project_id === pj4);
const prog1 = (await one(`insert into progress_reports (project_id,period_end,pct_complete,work_done,milestones_reached,upcoming_commitments,upcoming_commitments_value) values ($1,current_date,15,'Site clearedSig; foundations excavated','Mobilisation','Crane hire next month',45000) returning id, number`, [pj4]));
await db.query(`select submit_progress_report($1)`, [prog1.id]);
const afterRep = (await db.query(`select * from reports_due($1)`, [cid4])).rows.find(r => r.project_id === pj4);
await as(FIN); await db.query(`select review_progress_report($1,'Crane hire noted for cash flow')`, [prog1.id]);
ok(dueBefore && dueBefore.days_overdue > 0 && !afterRep && await unread(FIN, 'progress.submitted') === 1 && (await one(`select percent_complete_override p from projects where id=$1`, [pj4])).p === 15,
   `A monthly report was overdue; ${prog1.number} (15%, crane hire coming) goes to Finance, updates the project's progress and clears the reminder`);

// 4. Milestone certified by Engineering, Finance notified, invoiced
await as(ENG);
const ms4 = (await one(`insert into project_milestones (company_id,project_id,name,amount,due_date) values ($1,$2,'30% advance on mobilisation',744000,current_date) returning id`, [cid4, pj4])).id;
let noEvidence = false;
try { await db.query(`select certify_milestone($1,'')`, [ms4]); } catch (e) { noEvidence = /how the milestone was met/.test(e.message); }
await db.query(`select certify_milestone($1,'Mobilisation confirmed by GRIDCo site engineer, letter 12/26',$2)`, [ms4, prog1.id]);
await as(FIN);
const bsched = (await db.query(`select * from billing_schedule($1)`, [cid4])).rows;
ok(noEvidence && await unread(FIN, 'milestone.ready') === 1 && bsched.some(b => b.item_id === ms4 && b.ready), 'The PM certifies the milestone with evidence; Finance is notified and sees it at the top of the billing schedule');
const inv4 = (await one(`select invoice_milestone($1) id`, [ms4])).id;
await db.query(`update invoices set invoice_date=current_date - 40, due_date=current_date - 10 where id=$1`, [inv4]);
await db.query(`select post_invoice($1)`, [inv4]);

// 5. Every invoice followed up until paid
let rcv1 = (await db.query(`select * from receivables_report($1)`, [cid4])).rows.find(r => r.invoice_id === inv4);
const alert1 = (await db.query(`select * from invoice_alerts($1)`, [cid4])).rows.some(a => a.invoice_id === inv4 && /no follow-up/.test(a.alert));
await db.query(`insert into invoice_followups (invoice_id,method,contact,note,promised_date,promised_amount,next_action_date) values ($1,'call','Mrs Asante, GRIDCo accounts','Payment in batch run',current_date + 7,500000,current_date + 7)`, [inv4]);
const rcv2 = (await db.query(`select * from receivables_report($1)`, [cid4])).rows.find(r => r.invoice_id === inv4);
ok(rcv1 && rcv1.days_overdue === 10 && rcv1.bucket === '1-30 days' && rcv1.needs_action && alert1 && !rcv2.needs_action && near(rcv2.promised_amount, 500000),
   'The overdue invoice is flagged until Finance logs a follow-up (call, promise to pay GH₵500,000, next action date)');
await db.query(`select record_payment($1,500000,current_date,'bank','GRIDCo batch')`, [inv4]);

// 6. Financial clearance before closure
await as(ENG);
await db.query(`update project_requests set status='cancelled' where project_id=$1`, [pj4]);
await db.query(`select set_project_status($1,'complete',null,current_date)`, [pj4]);
ok(await unread(FIN, 'project.done') === 1, 'Marking the work complete tells Finance to start close-out');
let noClear = '';
try { await db.query(`select set_project_status($1,'close','Handed over')`, [pj4]); } catch (e) { noClear = e.message; }
const clchk = (await db.query(`select * from project_close_check($1)`, [pj4])).rows;
await as(FIN);
let noRec = false, owed = false;
try { await db.query(`select clear_project_finance($1)`, [pj4]); } catch (e) { noRec = /Reconcile/.test(e.message); }
await db.query(`select reconcile_project_costs($1,current_date - 60,current_date,'agreed','All costs on the right project')`, [pj4]);
try { await db.query(`select clear_project_finance($1)`, [pj4]); } catch (e) { owed = /still owed/.test(e.message); }
await db.query(`select clear_project_finance($1,'Balance of 244,000 promised by GRIDCo in January; followed up weekly',true)`, [pj4]);
await as(ENG);
await db.query(`select set_project_status($1,'close','Handed over to GRIDCo')`, [pj4]);
ok(/must be cleared/.test(noClear) && clchk.some(c => c.item === 'Financial clearance not given') && noRec && owed && (await one(`select status from projects where id=$1`, [pj4])).status === 'closed',
   'A completed project cannot close without financial clearance; Finance must reconcile costs and account for unpaid invoices first, then it closes');
await as(FIN);
await db.query(`select set_project_status($1,'reopen','Retention invoice to raise')`, [pj4]);
ok((await one(`select fin_cleared_at from projects where id=$1`, [pj4])).fin_cleared_at === null, 'Reopening a project withdraws its financial clearance');

// 7. Management view
const fov = (await db.query(`select * from project_finance_overview($1)`, [cid4])).rows.find(r => r.project_id === pj4);
const cyc = (await one(`select cycle_status($1) s`, [cid4])).s;
ok(fov && fov.registered && near(fov.contract_value, 2480000) && near(fov.invoiced, 744000) && near(fov.outstanding, Number(fov.outstanding)) && Number(fov.outstanding) > 0 && cyc.projects_unregistered >= 1 && cyc.receivable_total > 0,
   `Management sees each project's position: contract GH₵2,480,000, invoiced GH₵744,000, outstanding GH₵${Number(fov.outstanding).toLocaleString()}; the cycle page counts what is waiting at each stage`);
// ===================== v2.4 =====================
// Contract payment terms set the schedule and due dates, and prompt Finance and the project manager
await as(FIN);
const tnd5 = (await one(`insert into tenders (company_id,title,kind,customer_id,est_value,payment_terms_days,advance_pct,retention_pct,payment_terms_notes) values ($1,'Kintampo 33 kV line','direct_award',$2,1000000,45,20,5,'Interim payments 45 days; 5% retention for 12 months') returning id`, [cid4, cust4])).id;
await db.query(`select award_tender($1,'purchase_order','GRIDCo/PO/7781',current_date - 20,1000000)`, [tnd5]);
const pj5 = (await one(`select register_project_from_tender($1,'Kintampo 33 kV line',$2,$3,current_date - 20,current_date + 70,'fixed_price') id`, [tnd5, cc4, ENG])).id;
const t5 = await one(`select payment_terms_days, advance_pct, retention_pct, contract_date from projects where id=$1`, [pj5]);
ok(t5.payment_terms_days === 45 && near(t5.advance_pct, 20) && near(t5.retention_pct, 5) && t5.contract_date !== null, 'The award\'s payment terms (45 days, 20% advance, 5% retention) carry onto the registered contract');
await as(ENG);
await db.query(`insert into project_milestones (company_id,project_id,name,amount,due_date,sort) values ($1,$2,'Poles erected',400000,current_date + 30,1),($1,$2,'Line energised',350000,current_date + 70,2)`, [cid4, pj5]);
await db.query(`update projects set reminder_days=10 where id=$1`, [pj5]);
const n5 = (await one(`select generate_payment_schedule($1) n`, [pj5])).n;
const sched5 = (await db.query(`select * from project_payment_status($1)`, [pj5])).rows;
const advRow = sched5.find(s => s.kind === 'advance'), retRow = sched5.find(s => s.kind === 'retention');
ok(n5 === 4 && near(advRow.amount, 200000) && near(retRow.amount, 50000) && sched5.filter(s => s.kind === 'milestone').length === 2 && advRow.status === 'invoice_late'
   && (Date.parse(retRow.invoice_on) - Date.parse(sched5.find(s => s.description === 'Line energised').invoice_on)) / 864e5 === 365,
   'Schedule built from the terms: 20% advance on signing (GH₵200,000, already late to invoice), two milestones, 5% retention (GH₵50,000) released 12 months after completion');
ok((Date.parse(advRow.due_on) - Date.parse(advRow.invoice_on)) / 864e5 === 45, 'Each scheduled payment is due 45 days after its invoice, per the contract');
await as(FIN);
const finBefore = await unread(FIN, 'payment.invoice_due'), pmBefore = await unread(ENG, 'payment.invoice_due');
const sent1 = (await one(`select run_payment_reminders($1) n`, [cid4])).n;
const sent2 = (await one(`select run_payment_reminders($1) n`, [cid4])).n;
ok(sent1 >= 1 && sent2 === 0 && await unread(FIN, 'payment.invoice_due') === finBefore + 1 && await unread(ENG, 'payment.invoice_due') === pmBefore + 1,
   'Finance and the project manager are prompted once that the advance invoice is overdue to raise; running the reminders again sends nothing twice');
const advInv = (await one(`select invoice_schedule_item($1) id`, [advRow.id])).id;
const ai = await one(`select invoice_date, due_date, due_from_terms from invoices where id=$1`, [advInv]);
ok((Date.parse(ai.due_date) - Date.parse(ai.invoice_date)) / 864e5 === 45 && ai.due_from_terms, 'Invoicing the advance gives the invoice a due date 45 days out, from the contract');
await db.query(`update invoices set invoice_date = current_date - 50 where id=$1`, [advInv]);
const ai2 = await one(`select due_date from invoices where id=$1`, [advInv]);
await db.query(`select post_invoice($1)`, [advInv]);
const stAdv2 = (await db.query(`select * from project_payment_status($1)`, [pj5])).rows.find(s => s.id === advRow.id);
ok(String(new Date(ai2.due_date).toISOString()).startsWith(new Date(Date.now() - 5 * 864e5).toISOString().slice(0, 10)) && stAdv2.status === 'overdue',
   'Back-dating the draft moves its due date with it; once posted and past due, the schedule shows the advance as overdue');
const pay1 = await unread(ENG, 'payment.client_due');
await db.query(`select run_payment_reminders($1)`, [cid4]);
ok(await unread(ENG, 'payment.client_due') === pay1 + 1 && await unread(FIN, 'payment.client_due') >= 1, 'Finance and the project manager are told the client\'s advance payment is overdue');
await db.query(`select record_payment($1,240000,current_date,'bank','Advance')`, [advInv]);
const stAdv3 = (await db.query(`select * from project_payment_status($1)`, [pj5])).rows.find(s => s.id === advRow.id);
ok(stAdv3.status === 'paid', 'When the client pays, the scheduled advance shows as paid');
await as(ENG);
const msInv = (await one(`select invoice_milestone(id) id from project_milestones where project_id=$1 and name='Poles erected'`, [pj5])).id;
const stMs4 = (await db.query(`select * from project_payment_status($1)`, [pj5])).rows.find(s => s.description === 'Poles erected');
ok(stMs4.invoice_id === msInv && stMs4.status === 'draft_invoice', 'Invoicing a milestone from the Billing tab ticks it off the payment schedule');
const cal5 = (await db.query(`select * from payment_calendar($1,500)`, [cid4])).rows.filter(c => c.project_id === pj5);
ok(cal5.some(c => c.kind === 'to_invoice' && c.description.startsWith('Release of retention')) && cal5.some(c => c.kind === 'to_invoice' && c.description === 'Line energised'),
   'The payment calendar lists what to invoice next (including the retention release) and what to collect');

await as(OUT); await db.exec('set role authenticated');
const leak4 = await one(`select (select count(*) from tenders) t, (select count(*) from notifications) n`);
await db.exec('reset role'); await as(OWNER);
ok(leak4.t == 0 && leak4.n == 0, 'Another company sees none of these tenders or notifications');
{ const t = await one(`select sum(debit) d, sum(credit) c from account_balances($1,'1900-01-01','2099-12-31')`, [cid4]);
  ok(Number(t.d) === Number(t.c), 'Trial balance balances after v2.3 postings'); }

// v2.5: invitations by email
{
  await as(OWNER); await db.exec('set role authenticated');
  const c5 = (await one(`select create_company('Asante Builders Ltd','C0099887766','Kumasi') id`)).id;
  const HRU = '55555555-0000-0000-0000-000000000001', NEWU = '55555555-0000-0000-0000-000000000002',
        FAKE = '55555555-0000-0000-0000-000000000003', MGR = '55555555-0000-0000-0000-000000000004';
  await db.exec('reset role');
  await db.exec(`insert into auth.users (id,email) values ('${HRU}','hr@asante.com.gh')`);
  await db.exec('set role authenticated');
  await db.query(`select add_member($1,'hr@asante.com.gh','hr')`, [c5]);
  const kwame = (await one(`insert into employees (company_id,full_name,email,basic_salary) values ($1,'Kwame Ofori','Kwame@Asante.com.gh',3000) returning id`, [c5])).id;
  const ama = (await one(`insert into employees (company_id,full_name,email,basic_salary) values ($1,'Ama Mensah','ama@asante.com.gh',3000) returning id`, [c5])).id;

  // HR invites staff in bulk; one address is bad
  await as(HRU);
  const r = (await db.query(`select * from create_invites($1, $2::jsonb)`, [c5, JSON.stringify([
    { email: ' Kwame@Asante.com.gh ', role: 'staff', employee_id: kwame }, { email: 'ama@asante.com.gh', employee_id: ama }, { email: 'not-an-email' }])])).rows;
  ok(r.filter(x => x.result === 'invited').length === 2 && r.some(x => x.result === 'invalid email'), 'HR invites two staff in one go; a bad address is reported, not invited');
  ok((await one(`select email from member_invites where employee_id=$1`, [kwame])).email === 'kwame@asante.com.gh', 'Invite addresses are stored trimmed and lower-case');
  let hrBlocked = '';
  try { await db.query(`select * from create_invites($1, '[{"email":"boss@asante.com.gh","role":"admin"}]'::jsonb)`, [c5]); } catch (e) { hrBlocked = e.message; }
  ok(/HR can invite staff only/.test(hrBlocked), 'HR cannot invite an admin');
  const send = (await db.query(`select * from invites_to_send($1, array(select id from member_invites where company_id=$1))`, [c5])).rows;
  ok(send.length === 2 && send.every(x => x.company_name === 'Asante Builders Ltd' && x.has_login === false), 'The edge function gets both invites with the company name, neither has a login yet');
  await db.query(`select mark_invite_sent($1, true, null, 'invite')`, [send[0].id]);
  ok((await one(`select status, send_count from member_invites where id=$1`, [send[0].id])).send_count == 1, 'Sending marks the invite sent');
  const acc = (await db.query(`select * from employee_access($1)`, [c5])).rows;
  ok(acc.find(x => x.employee_id === kwame).access === 'invited', 'The employee list shows Kwame as invited');

  // Owner invites a manager
  await as(OWNER);
  await db.query(`select * from create_invites($1, '[{"email":"pm@asante.com.gh","role":"project_manager"}]'::jsonb)`, [c5]);
  let ownerBlocked = false;
  try { await db.query(`select * from create_invites($1, '[{"email":"co@asante.com.gh","role":"owner"}]'::jsonb)`, [c5]); } catch { ownerBlocked = true; }
  ok(ownerBlocked, 'Nobody can be invited as owner');

  // Someone signs up with Kwame's address but has not confirmed it: no access
  await db.exec('reset role');
  await db.exec(`insert into auth.users (id,email,email_confirmed_at) values ('${FAKE}','kwame@asante.com.gh',null)`);
  await db.exec('set role authenticated');
  await as(FAKE);
  ok(Number((await one(`select claim_my_invites() n`)).n) === 0 && !(await one(`select 1 x from memberships where user_id=$1`, [FAKE])), 'An unconfirmed address cannot claim an invitation');
  await db.exec('reset role'); await db.exec(`delete from auth.users where id='${FAKE}'`);

  // Kwame accepts: confirmed email, signs in
  await db.exec(`insert into auth.users (id,email) values ('${NEWU}','kwame@asante.com.gh')`);
  await db.exec('set role authenticated');
  await as(NEWU);
  ok(Number((await one(`select claim_my_invites() n`)).n) === 1, 'Kwame claims his invitation on sign-in');
  ok((await one(`select role from memberships where company_id=$1 and user_id=$2`, [c5, NEWU])).role === 'staff', 'He joins as staff');
  await as(HRU);
  ok((await one(`select user_id from employees where id=$1`, [kwame])).user_id === NEWU, 'His employee record is linked to his login');
  await as(NEWU);
  ok(Number((await one(`select claim_my_invites() n`)).n) === 0, 'Claiming twice does nothing');
  await as(HRU);
  ok(Number((await one(`select count(*) n from notifications where user_id=$1 and kind='invite_accepted'`, [HRU])).n) === 1, 'HR is told Kwame joined');
  await as(NEWU);
  let noPeek = false;
  try { await db.query(`select team_access($1)`, [c5]); } catch { noPeek = true; }
  ok(noPeek, 'Staff cannot see the team access list');

  // Manager signs up later by themselves (no invite email received): still added, linked by email match
  await db.exec('reset role'); await db.exec(`insert into auth.users (id,email) values ('${MGR}','pm@asante.com.gh')`); await db.exec('set role authenticated');
  await as(MGR); await db.query(`select claim_my_invites()`);
  ok((await one(`select role from memberships where company_id=$1 and user_id=$2`, [c5, MGR])).role === 'project_manager', 'Someone who signs up with an invited address gets the invited role');

  // Revoke Ama; she then cannot get in
  await as(HRU);
  const amaInv = (await one(`select id from member_invites where employee_id=$1`, [ama])).id;
  await db.query(`select revoke_invite($1)`, [amaInv]);
  ok((await db.query(`select * from invites_to_send($1, array[$2]::uuid[])`, [c5, amaInv])).rows.length === 0, 'A revoked invite cannot be sent');
  const ta = (await one(`select team_access($1) t`, [c5])).t;
  ok(ta.members.some(m => m.email === 'kwame@asante.com.gh' && m.employee === 'Kwame Ofori') && ta.invites.some(i => i.status === 'revoked'), 'Team access lists members with their employee and open or revoked invites');
  let kwBlocked = false;
  try { await db.query(`select revoke_invite(id) from member_invites where employee_id=$1`, [kwame]); } catch { kwBlocked = true; }
  ok(kwBlocked, 'An accepted invite cannot be revoked (remove the member instead)');
  // Inviting an existing member just links the employee
  const again = (await db.query(`select * from create_invites($1, '[{"email":"kwame@asante.com.gh"}]'::jsonb)`, [c5])).rows[0];
  ok(again.result === 'already a member', 'Inviting someone already on the team is reported, not duplicated');

  // Other companies cannot see or send these invites
  await as(OUT);
  let isolated = false;
  try { await db.query(`select * from invites_to_send($1, array[$2]::uuid[])`, [c5, amaInv]); } catch { isolated = true; }
  ok(isolated && (await db.query(`select * from member_invites`)).rows.length === 0, 'Another company cannot read or send these invitations');
  await db.exec('reset role'); await as(OWNER);
}

// v2.6: contracts
{
  await as(FIN); await db.exec('set role authenticated');
  const reg = (await db.query(`select * from contract_register($1)`, [cid4])).rows;
  const fromAward = reg.find(r => r.title === 'Prestea 161 kV substation civil works');
  ok(fromAward && fromAward.kind === 'client' && Number(fromAward.value) === 2480000 && fromAward.their_ref === 'GRIDCo/PRS/2026/14', 'An awarded tender becomes a client contract automatically, with its value and reference');
  const k5 = reg.find(r => r.title === 'Kintampo 33 kV line');
  ok(k5 && k5.project_id === pj5, 'The contract links to the project registered from its tender');
  ok(Number(k5.billed) > 0 && near(Number(k5.remaining), Number(k5.revised_value) - Number(k5.billed)), 'The register shows what has been invoiced against the contract and what is left');
  const cust = (await one(`select customer_id from contracts where id=$1`, [k5.id])).customer_id;
  await db.query(`update contracts set start_date=current_date - 20, end_date=current_date + 20, notice_days=60 where id=$1`, [k5.id]);
  // Variations
  await as(ENG);
  const vo = (await one(`insert into contract_variations (contract_id,title,value_change,days_extension) values ($1,'Extra tower foundations',150000,14) returning id, number, status`, [k5.id]));
  ok(vo.number === 'VO-01' && vo.status === 'proposed', 'The project manager proposes variation VO-01');
  let engDecides = false;
  try { await db.query(`select decide_variation($1,true)`, [vo.id]); } catch { engDecides = true; }
  ok(engDecides, 'The project manager cannot approve their own variation');
  let sneak = false;
  try { await db.query(`update contract_variations set status='approved' where id=$1`, [vo.id]); } catch { sneak = true; }
  ok(sneak, 'A variation cannot be approved by editing it directly');
  await as(FIN);
  const endBefore = (await one(`select end_date from contracts where id=$1`, [k5.id])).end_date;
  await db.query(`select decide_variation($1,true,'Agreed at site meeting 4')`, [vo.id]);
  const afterVo = (await db.query(`select * from contract_register($1)`, [cid4])).rows.find(r => r.id === k5.id);
  ok(near(afterVo.revised_value, Number(k5.value) + 150000), 'An approved variation raises the revised contract value');
  ok((new Date((await one(`select end_date from contracts where id=$1`, [k5.id])).end_date) - new Date(endBefore)) / 86400000 === 14, 'Its 14-day extension moves the end date');
  // Securities and obligations
  await db.query(`insert into contract_securities (contract_id,kind,issuer,reference,amount,expires_on) values ($1,'performance_bond','GCB Bank','PB-2231',100000,current_date + 10)`, [k5.id]);
  await db.query(`insert into contract_obligations (contract_id,title,due_date,responsible_id) values ($1,'Submit monthly HSE report',current_date - 1,$2)`, [k5.id, ENG]);
  const alerts = (await db.query(`select * from contract_alerts($1,30)`, [cid4])).rows.filter(a => a.contract_id === k5.id).map(a => a.kind);
  ok(['contract_end', 'security_expiry', 'obligation'].every(k => alerts.includes(k)), 'Alerts list the contract ending, the bond expiring and the overdue obligation');
  const sent = Number((await one(`select run_contract_reminders($1) n`, [cid4])).n);
  const again = Number((await one(`select run_contract_reminders($1) n`, [cid4])).n);
  ok(sent >= 3 && again === 0, `Reminders are sent once (${sent} sent, ${again} on the second run)`);
  await as(ENG);
  ok(Number((await one(`select count(*) n from notifications where user_id=$1 and kind='obligation_due'`, [ENG])).n) === 1, 'The person responsible is told the obligation is due');
  // Supplier contract, and who can see contracts
  await as(FIN);
  const sub = (await one(`insert into contracts (company_id,title,kind,counterparty,value,start_date,end_date,status) values ($1,'Crane hire for tower erection','subcontract','Tema Lifting Services',80000,current_date,current_date + 60,'active') returning number`, [cid4])).number;
  ok(/^CON-\d+/.test(sub), 'Contracts are numbered ' + sub);
  let term = '';
  try { await db.query(`update contracts set status='terminated' where number=$1 and company_id=$2`, [sub, cid4]); } catch (e) { term = e.message; }
  ok(/why/.test(term), 'Terminating a contract needs a reason');
  await as(OUT);
  ok((await db.query(`select * from contracts`)).rows.length === 0 && (await db.query(`select * from contract_variations`)).rows.length === 0, 'Another company sees none of these contracts');
  await db.exec('reset role'); await as(OWNER);
}
// v2.6: assets: check out, check in, audit, requests
{
  await as(OWNER); await db.exec('set role authenticated');
  ok((await one(`select state, next_audit from assets where id=$1`, [truck])).next_audit !== null, 'Every asset in use has a next audit date');
  await db.query(`select checkout_asset($1,$2,null,'Tema depot',current_date - 1,'For deliveries')`, [truck, yaw]);
  const t1 = await one(`select state, custodian_id, location from assets where id=$1`, [truck]);
  ok(t1.state === 'deployed' && t1.custodian_id === yaw && t1.location === 'Tema depot', 'Checking out assigns the truck to Yaw at Tema depot');
  let twice = false;
  try { await db.query(`select checkout_asset($1,$2)`, [truck, yaw]); } catch { twice = true; }
  ok(twice, 'A checked-out asset cannot be checked out again');
  ok(Number((await one(`select run_contract_reminders($1) n`, [cid])).n) >= 1, 'An overdue return raises a reminder');
  await db.query(`select checkin_asset($1,'repair','Workshop','Brakes')`, [truck]);
  const t2 = await one(`select state, custodian_id from assets where id=$1`, [truck]);
  ok(t2.state === 'repair' && t2.custodian_id === null, 'Checked in to the workshop as out for repair');
  let repairOut = false;
  try { await db.query(`select checkout_asset($1,$2)`, [truck, yaw]); } catch { repairOut = true; }
  ok(repairOut, 'An asset out for repair cannot be checked out');
  await db.query(`select set_asset_state($1,'ready','Repaired')`, [truck]);
  const nxt = (await one(`select audit_asset($1,'good','Accra HQ') d`, [truck])).d;
  ok((await one(`select last_audit, location from assets where id=$1`, [truck])).location === 'Accra HQ' && nxt, 'Auditing records the location and sets the next audit date');
  ok(Number((await one(`select count(*) n from asset_movements where asset_id=$1`, [truck])).n) >= 4, 'Every check-out, check-in, status change and audit is in the asset history');
  await db.query(`update assets set requestable=true where id=$1`, [truck]);
  await as(STAFF);
  const rq = (await one(`select request_asset($1,'Truck for the Kumasi delivery run',$2,null,null,current_date,current_date + 3) id`, [cid, truck])).id;
  let staffApproves = false;
  try { await db.query(`select decide_asset_request($1,true)`, [rq]); } catch { staffApproves = true; }
  ok(staffApproves, 'Staff cannot approve their own asset request');
  let staffMoves = false;
  try { await db.query(`select checkout_asset($1,$2)`, [truck, yaw]); } catch { staffMoves = true; }
  ok(staffMoves, 'Staff cannot check assets out');
  await as(OWNER);
  await db.query(`select decide_asset_request($1,true,'OK for 3 days')`, [rq]);
  await db.query(`select checkout_asset($1,$2,null,null,current_date + 3,null,$3)`, [truck, yaw, rq]);
  ok((await one(`select status, fulfilled_asset_id from asset_requests where id=$1`, [rq])).status === 'fulfilled', 'Checking out against the request fulfils it');
  await as(STAFF);
  ok(Number((await one(`select count(*) n from notifications where user_id=$1 and kind in ('asset_request_decided','asset_checked_out')`, [STAFF])).n) >= 2, 'Yaw is told the request was approved and the truck is his');
  await as(OWNER); await db.query(`select checkin_asset($1)`, [truck]);
  await db.query(`select audit_asset($1,'missing')`, [truck]);
  ok((await one(`select state from assets where id=$1`, [truck])).state === 'lost', 'An audit that cannot find the asset marks it lost');
  await db.exec('reset role');
}

// v2.7: spend requests, cash advances, petty cash
{
  await db.exec('reset role');
  const exp = (await one(`select id from accounts where company_id=$1 and type='expense' and system_key is null order by code limit 1`, [cid])).id;
  const bal = async (key) => Number((await one(`select coalesce(sum(debit-credit),0) v from journal_lines where account_id=acct($1,$2)`, [cid, key])).v);
  await as(STAFF); await db.exec('set role authenticated');
  // A payment request with no project
  const sr = (await one(`insert into spend_requests (company_id,kind,title,justification,amount,account_id,payee) values ($1,'payment','Generator servicing','Quarterly service of the office generator',2500,$2,'Kofi Electricals') returning id, number, status`, [cid, exp]));
  ok(/^SRQ-/.test(sr.number) && sr.status === 'draft', 'Staff raise a payment request ' + sr.number + ' as a draft');
  ok(Number((await one(`select submit_spend_request($1) n`, [sr.id])).n) === 1, 'With no approval chain set up, Finance must approve it');
  const step = (await one(`select id from approval_steps where doc_type='spend_request' and doc_id=$1`, [sr.id])).id;
  let selfOk = false;
  try { await db.query(`select decide_approval($1,true)`, [step]); } catch (e) { selfOk = /own request/.test(e.message); }
  ok(selfOk, 'Nobody can approve their own request');
  let edit = false;
  try { await db.query(`update spend_requests set amount=9000 where id=$1`, [sr.id]); } catch { edit = true; }
  ok(edit || Number((await one(`select amount from spend_requests where id=$1`, [sr.id])).amount) === 2500, 'A submitted request cannot be changed');
  await as(ACC);
  const bud = (await one(`select * from spend_budget($1,$2)`, [cid, exp]));
  ok(Number(bud.committed) >= 2500, 'The budget check counts the request as committed');
  ok((await one(`select decide_approval($1,true,'OK') r`, [step])).r === 'approved' && (await one(`select status from spend_requests where id=$1`, [sr.id])).status === 'approved', 'Finance approves the request');
  const bankBefore = await bal('bank');
  await db.query(`select pay_spend_request($1,null,current_date,'Chq 0042')`, [sr.id]);
  ok(near(bankBefore - await bal('bank'), 2500) && (await one(`select status, outcome from spend_requests where id=$1`, [sr.id])).outcome === 'payment', 'Paying it posts Dr expense, Cr bank and closes the request');
  // Cash advance and retirement
  await as(STAFF);
  const ar = (await one(`insert into spend_requests (company_id,kind,title,justification,amount) values ($1,'cash_advance','Trip to Kumasi for stock count','Transport, lodging and meals for 2 days',1000) returning id`, [cid])).id;
  await db.query(`select submit_spend_request($1)`, [ar]);
  await as(ACC);
  await db.query(`select decide_approval(id,true,'OK') from approval_steps where doc_type='spend_request' and doc_id=$1`, [ar]);
  const adv = (await one(`select pay_advance($1,null,current_date,current_date + 5) id`, [ar])).id;
  ok(near(await bal('staff_advances'), 1000), 'Paying the advance debits Staff cash advances GH₵1,000');
  await as(STAFF);
  const ar2 = (await one(`insert into spend_requests (company_id,kind,title,justification,amount) values ($1,'cash_advance','Another trip','Tamale',800) returning id`, [cid])).id;
  let blocked = '';
  try { await db.query(`select submit_spend_request($1)`, [ar2]); } catch (e) { blocked = e.message; }
  ok(/not yet retired/.test(blocked), 'A second advance is refused while the first is not retired');
  await db.query(`insert into advance_lines (advance_id,description,account_id,amount) values ($1,'STC bus fare',$2,240)`, [adv, exp]);
  let noReceipt = '';
  try { await db.query(`select submit_retirement($1)`, [adv]); } catch (e) { noReceipt = e.message; }
  ok(/receipt/.test(noReceipt), 'A retirement needs a receipt on every line');
  await db.query(`update advance_lines set receipt_path='x/stc.jpg' where advance_id=$1`, [adv]);
  await db.query(`insert into advance_lines (advance_id,description,account_id,amount,receipt_path) values ($1,'Hotel, 1 night',$2,460,'x/hotel.jpg')`, [adv, exp]);
  await db.query(`select submit_retirement($1)`, [adv]);
  let late = false;
  try { await db.query(`insert into advance_lines (advance_id,description,account_id,amount,receipt_path) values ($1,'Extra',$2,10,'x')`, [adv, exp]); } catch { late = true; }
  ok(late, 'Lines cannot be added after submitting');
  await as(ACC);
  const cashBefore = await bal('cash');
  await db.query(`select approve_retirement($1,acct($2,'cash'))`, [adv, cid]);
  const a1 = await one(`select status, spent, cash_returned from cash_advances where id=$1`, [adv]);
  ok(a1.status === 'retired' && near(a1.spent, 700) && near(a1.cash_returned, 300) && near(await bal('cash') - cashBefore, 300), 'Retired: GH₵700 spent, GH₵300 returned to cash');
  ok(near(await bal('staff_advances'), 0), 'Staff cash advances is back to zero');
  // Unretired advance recovered through payroll
  await as(STAFF);
  await db.query(`select submit_spend_request($1)`, [ar2]);
  await as(ACC);
  await db.query(`select decide_approval(id,true,'OK') from approval_steps where doc_type='spend_request' and doc_id=$1`, [ar2]);
  const adv2 = (await one(`select pay_advance($1,null,current_date,current_date - 45) id`, [ar2])).id;
  ok(Number((await one(`select run_cash_reminders($1) n`, [cid])).n) >= 1, 'An overdue advance raises a reminder');
  const loan = (await one(`select recover_advance($1,200) id`, [adv2])).id;
  const l = await one(`select principal, installment from employee_loans where id=$1`, [loan]);
  ok(near(l.principal, 800) && near(l.installment, 200) && near(await bal('staff_advances'), 0), 'After 30 days overdue the GH₵800 moves to a staff loan deducted GH₵200 a month');
  const chk = (await db.query(`select * from ledger_checks($1)`, [cid])).rows.find(r => /Staff cash advances/.test(r.check_name));
  ok(chk && chk.ok, 'Books check: Staff cash advances agrees with advances not yet retired');
  // Petty cash float
  const fl = (await one(`select create_petty_float($1,'Spintex office',$2,2000,500,30) id`, [cid, STAFF])).id;
  const facct = (await one(`select account_id from petty_floats where id=$1`, [fl])).account_id;
  ok((await one(`select code from accounts where id=$1`, [facct])).code === '1020', 'The float gets its own ledger account 1020 funded with GH₵2,000');
  await as(STAFF);
  await db.query(`insert into petty_vouchers (float_id,payee,description,account_id,amount,receipt_path) values ($1,'Melcom','Printer toner',$2,300,'x/toner.jpg')`, [fl, exp]);
  let over = '';
  try { await db.query(`insert into petty_vouchers (float_id,payee,description,account_id,amount) values ($1,'X','Chairs',$2,600)`, [fl, exp]); } catch (e) { over = e.message; }
  ok(/over the limit/.test(over), 'A voucher over GH₵500 is refused');
  const pos = await one(`select * from float_position($1)`, [fl]);
  ok(near(pos.ledger, 2000) && near(pos.expected_cash, 1700), 'Ledger stays at the float; GH₵1,700 should be in the box');
  const cnt = (await one(`select count_petty_cash($1,'{"200":5,"100":6,"20":2,"10":1}'::jsonb,'Counted with the office manager') id`, [fl])).id;
  const c1 = await one(`select counted, difference, status from petty_counts where id=$1`, [cnt]);
  ok(near(c1.counted, 1650) && near(c1.difference, -50) && c1.status === 'submitted', 'The count by note finds GH₵1,650: GH₵50 short, waiting for Finance');
  let selfApprove = false;
  try { await db.query(`select approve_petty_count($1,'expense','x')`, [cnt]); } catch { selfApprove = true; }
  ok(selfApprove, 'The custodian cannot approve their own count');
  await as(ACC);
  let earlyRep = '';
  try { await db.query(`select replenish_float($1)`, [fl]); } catch (e) { earlyRep = e.message; }
  ok(/waiting for approval/.test(earlyRep), 'Replenishment is blocked while a count difference is unapproved');
  await db.query(`select approve_petty_count($1,'custodian','Change given in error; Yaw to refund through payroll')`, [cnt]);
  ok(near(Number((await one(`select coalesce(sum(debit-credit),0) v from journal_lines where account_id=$1`, [facct])).v), 1950), 'The shortage is charged to the custodian and the float ledger drops to GH₵1,950');
  const rep = (await one(`select replenish_float($1) id`, [fl])).id;
  const r1 = await one(`select vouchers_total, topup, amount from petty_replenishments where id=$1`, [rep]);
  ok(near(r1.vouchers_total, 300) && near(r1.topup, 50) && near(r1.amount, 350), 'Replenishment pays GH₵350: GH₵300 of vouchers plus the GH₵50 shortage');
  ok(near(Number((await one(`select coalesce(sum(debit-credit),0) v from journal_lines where account_id=$1`, [facct])).v), 2000) &&
     (await one(`select status from petty_vouchers where float_id=$1`, [fl])).status === 'approved', 'The float is back to GH₵2,000 and the voucher is in the books');
  const pchk = (await db.query(`select * from ledger_checks($1)`, [cid])).rows.find(r => /Petty cash/.test(r.check_name));
  ok(pchk && pchk.ok, 'Books check: petty cash ledger agrees with the floats');
  await as(OUT);
  ok((await db.query(`select * from spend_requests`)).rows.length === 0 && (await db.query(`select * from petty_floats`)).rows.length === 0, 'Another company sees none of these requests or floats');
  await db.exec('reset role'); await as(OWNER);
}

// v2.7: purchase orders in a foreign currency
{
  await db.exec('reset role'); await as(OWNER);
  const supUsd = (await one(`insert into suppliers (company_id,name) values ($1,'Shenzhen Switchgear Co') returning id`, [cid])).id;
  const eqAcct = (await one(`select id from accounts where company_id=$1 and type='expense' and system_key is null order by code limit 1`, [cid])).id;
  const pox = (await one(`insert into purchase_orders (company_id,supplier_id,order_date,currency,exchange_rate) values ($1,$2,'2026-12-01','usd',15) returning id, currency`, [cid, supUsd]));
  ok(pox.currency === 'USD', 'A purchase order can be raised in USD');
  const lx = (await one(`insert into po_lines (po_id,company_id,account_id,description,qty,unit_price_fx,taxable) values ($1,$2,$3,'MCCB 630A panels',10,100,false) returning id, unit_cost`, [pox.id, cid, eqAcct]));
  ok(near(lx.unit_cost, 1500), 'Each line keeps the USD price (100) and its GHS cost at the order rate (1,500)');
  ok(near((await one(`select po_total($1) t`, [pox.id])).t, 15000) && near((await one(`select po_total_fx($1) t`, [pox.id])).t, 1000), 'Order total USD 1,000 = GHS 15,000 for approval limits');
  await db.query(`update purchase_orders set exchange_rate=15.2 where id=$1`, [pox.id]);
  ok(near((await one(`select unit_cost from po_lines where id=$1`, [lx.id])).unit_cost, 1520), 'Changing the rate on a draft order re-costs its lines');
  await db.query(`update purchase_orders set exchange_rate=15 where id=$1`, [pox.id]);
  await db.query(`select approve_po($1)`, [pox.id]);
  let rateLocked = false;
  try { await db.query(`update purchase_orders set exchange_rate=16 where id=$1`, [pox.id]); } catch { rateLocked = true; }
  ok(rateLocked, 'The rate is fixed once the order is approved');
  const grniBefore = Number((await one(`select coalesce(sum(credit-debit),0) v from journal_lines where account_id=acct($1,'grni')`, [cid])).v);
  await db.query(`select receive_po($1,$2::jsonb,'2026-12-04')`, [pox.id, JSON.stringify([{ line_id: lx.id, qty: 10 }])]);
  ok(near(Number((await one(`select coalesce(sum(credit-debit),0) v from journal_lines where account_id=acct($1,'grni')`, [cid])).v) - grniBefore, 15000), 'Receiving accrues GHS 15,000 at the order rate');
  await db.query(`update currencies set rate=15.5 where company_id=$1 and code='USD'`, [cid]);
  const bx = (await one(`select bill_from_po($1,'SZ-INV-88','2026-12-06') id`, [pox.id])).id;
  const bh = await one(`select currency, exchange_rate from bills where id=$1`, [bx]);
  ok(bh.currency === 'USD' && near(bh.exchange_rate, 15.5) && near((await one(`select unit_cost from bill_lines where bill_id=$1`, [bx])).unit_cost, 100), 'The supplier bill is in USD at the day\'s rate (15.5), USD 100 a unit');
  const ppvBefore = Number((await one(`select coalesce(sum(debit-credit),0) v from journal_lines where account_id=acct($1,'ppv')`, [cid])).v);
  const fxBefore = Number((await one(`select coalesce(sum(debit-credit),0) v from journal_lines where account_id=acct($1,'fx')`, [cid])).v);
  if ((await one(`select approval_state('bill',$1) s`, [bx])).s !== 'not_required') {
    await db.query(`select start_approval('bill',$1)`, [bx]);
    for (const st of (await db.query(`select id from approval_steps where doc_type='bill' and doc_id=$1 order by step_no`, [bx])).rows) await db.query(`select decide_approval($1,true,'OK')`, [st.id]);
  }
  await db.query(`select post_bill($1)`, [bx]);
  ok(near(Number((await one(`select coalesce(sum(credit-debit),0) v from journal_lines where account_id=acct($1,'grni')`, [cid])).v), grniBefore), 'Posting the bill clears the GHS 15,000 accrual');
  ok(near(Number((await one(`select coalesce(sum(debit-credit),0) v from journal_lines where account_id=acct($1,'fx')`, [cid])).v) - fxBefore, 500), 'The GHS 500 rate difference (15.5 vs 15) posts to 4800 Foreign exchange gains and losses');
  ok(near(Number((await one(`select coalesce(sum(debit-credit),0) v from journal_lines where account_id=acct($1,'ppv')`, [cid])).v) - ppvBefore, 0), 'Nothing goes to purchase price variance when only the rate changed');
  await db.query(`update currencies set rate=15 where company_id=$1 and code='USD'`, [cid]);
  // A request in EUR
  await db.query(`insert into currencies (company_id,code,name,rate) values ($1,'EUR','Euro',17) on conflict (company_id,code) do update set rate=17`, [cid]);
  await as(STAFF); await db.exec('set role authenticated');
  const er = (await one(`insert into spend_requests (company_id,kind,title,justification,amount,currency,fx_amount,account_id,supplier_id) values ($1,'purchase','Relay test kit','Calibration of protection relays',1,'EUR',2000,$2,$3) returning id, amount, exchange_rate`, [cid, eqAcct, supUsd]));
  ok(near(er.amount, 34000) && near(er.exchange_rate, 17), 'A request for EUR 2,000 counts as GHS 34,000 for budget and approval');
  await db.query(`select submit_spend_request($1)`, [er.id]);
  await as(ACC);
  await db.query(`select decide_approval(id,true,'OK') from approval_steps where doc_type='spend_request' and doc_id=$1`, [er.id]);
  const epo = (await one(`select request_to_po($1) id`, [er.id])).id;
  const eh = await one(`select o.currency, o.exchange_rate, l.unit_price_fx, l.unit_cost from purchase_orders o join po_lines l on l.po_id=o.id where o.id=$1`, [epo]);
  ok(eh.currency === 'EUR' && near(eh.unit_price_fx, 2000) && near(eh.unit_cost, 34000), 'The approved request becomes a EUR purchase order');
  await db.exec('reset role'); await as(OWNER);
}

// Roles: a sales member cannot read the books
const SALES = '33333333-3333-3333-3333-333333333333';
await db.exec(`insert into auth.users values ('${SALES}','sales@adom.com.gh')`);
await db.query(`select add_member($1,'sales@adom.com.gh','sales')`, [cid]);
await as(SALES);
await db.exec('set role authenticated');
const salesSees = await one(`select (select count(*) from journal_lines) j, (select count(*) from employees) e, (select count(*) from invoices) i, (select count(*) from audit_log) au, (select count(*) from cash_transactions) cb`);
const salesBal = await one(`select count(*) n from account_balances($1,'1900-01-01','2099-12-31')`, [cid]);
await db.exec('reset role');
ok(salesSees.j == 0 && salesSees.e == 0 && salesSees.i > 0 && salesBal.n == 0 && salesSees.au == 0 && salesSees.cb == 0, 'Sales role sees invoices but not the ledger, salaries, bank transactions or audit trail');

// Isolation: outsider sees nothing
await as(OUT);
await db.exec('set role authenticated');
const seen = await one(`select (select count(*) from invoices) i, (select count(*) from customers) c, (select count(*) from journal_lines) j, (select count(*) from employees) e`);
await db.exec('reset role');
ok(seen.i == 0 && seen.c == 0 && seen.j == 0 && seen.e == 0, 'Another company\'s user sees no data');
let denied = false;
try { await db.query(`select post_invoice($1)`, [inv2]); } catch (e) { denied = /access|role/.test(e.message); }
ok(denied, 'Another company\'s user cannot post documents');


// v2.8: projects on hold until further notice
{
  await as(OWNER);
  const hp = (await one(`insert into projects (company_id,name,customer_id,start_date,hourly_rate,manager_id) values ($1,'Substation upgrade (on hold)',null,current_date,0,$2) returning id`, [cid, PMU])).id;
  await as(PMU);
  await db.query(`select set_project_status($1,'hold','Client funding not released',current_date,false,null)`, [hp]);
  let h = await one(`select status, hold_since, hold_reason, hold_review, actual_start from projects where id=$1`, [hp]);
  ok(h.status === 'on_hold' && h.hold_since && h.hold_reason === 'Client funding not released' && h.hold_review === null && h.actual_start === null,
     'A project that has not started can be put on hold until further notice, with its reason and date');
  const nNotes = (await one(`select count(*)::int n from notifications where company_id=$1 and kind='project_hold'`, [cid])).n;
  ok(nNotes > 0, 'Finance and the project manager are told when a project goes on hold');
  let blockedPm = '';
  try { await db.query(`insert into timesheets (company_id,project_id,employee_id,work_date,hours,status) values ($1,$2,$3,current_date,2,'submitted')`, [cid, hp, consultant]); } catch (e) { blockedPm = e.message; }
  ok(/on hold/.test(blockedPm), 'No new time can be booked to a project on hold by the project team');
  await as(OWNER);
  let ownerBooked = true;
  try { await db.query(`insert into timesheets (company_id,project_id,employee_id,work_date,hours,status) values ($1,$2,$3,current_date,1,'submitted')`, [cid, hp, consultant]); } catch (e) { ownerBooked = false; }
  ok(ownerBooked, 'Finance, admins and owners can still book costs to a project on hold');
  let pastReview = false;
  try { await db.query(`select set_project_status($1,'hold_review',null,current_date,false,current_date - 1)`, [hp]); } catch (e) { pastReview = /past/.test(e.message); }
  await db.query(`select set_project_status($1,'hold_review',null,current_date,false,current_date)`, [hp]);
  const sent = (await one(`select run_project_hold_reminders() n`)).n;
  const again = (await one(`select run_project_hold_reminders() n`)).n;
  ok(pastReview && sent >= 1 && again === 0, 'A review date can be set (not in the past); a reminder goes out once when it arrives');
  let cantComplete = false;
  try { await db.query(`select set_project_status($1,'complete')`, [hp]); } catch (e) { cantComplete = /cannot/.test(e.message); }
  await db.query(`select set_project_status($1,'resume')`, [hp]);
  h = await one(`select status, hold_since, hold_review, actual_start from projects where id=$1`, [hp]);
  ok(cantComplete && h.status === 'planned' && h.hold_since === null && h.hold_review === null && h.actual_start === null,
     'A project that never started cannot be completed from hold; resuming returns it to Not started and clears the hold');
  await db.query(`select set_project_status($1,'start')`, [hp]);
  await db.query(`select set_project_status($1,'hold','Rainy season, site flooded',current_date,false,current_date + 60)`, [hp]);
  await db.query(`select set_project_status($1,'resume')`, [hp]);
  ok((await one(`select status from projects where id=$1`, [hp])).status === 'active', 'A started project resumes to In progress');
}


// v2.8.1: a single database link between tenders and projects
{
  const links = (await one(`select count(*)::int n from pg_constraint c where c.contype='f'
    and ((c.conrelid='public.tenders'::regclass and c.confrelid='public.projects'::regclass) or (c.conrelid='public.projects'::regclass and c.confrelid='public.tenders'::regclass))`)).n;
  ok(links === 1, 'Tenders and projects are joined by one database link, so the Tenders page can show each tender\'s project');
}


// v2.9: safety, compliance and sustainability
{
  const asUser = async (u, fn) => { await as(u); await db.exec('set role authenticated'); try { return await fn(); } finally { await db.exec('reset role'); } };
  const err = async (fn) => { try { await fn(); return ''; } catch (e) { return e.message; } };
  const seeded = await one(`select (select count(*)::int from esg_factors where company_id=$1) f, (select count(*)::int from hse_checklists where company_id=$1) c`, [cid]);
  ok(seeded.f === 9 && seeded.c === 7, 'Every company starts with emission factors and seven inspection checklists');

  // HSE officers
  const staffHse = await asUser(STAFF, () => err(() => db.query(`select set_member_hse($1,$2,true)`, [cid, STAFF])));
  await asUser(OWNER, () => db.query(`select set_member_hse($1,$2,true)`, [cid, ACC]));
  ok(/owner or admin/.test(staffHse) && (await one(`select hse from memberships where company_id=$1 and user_id=$2`, [cid, ACC])).hse === true,
     'Only an owner or admin can make someone an HSE officer');

  // Incidents
  const nm = await asUser(STAFF, () => one(`insert into hse_incidents (company_id,kind,description,location) values ($1,'near_miss','Unsecured ladder slipped','Tema substation') returning id, number, status`, [cid]));
  const toAcc = (await one(`select count(*)::int n from notifications where user_id=$1 and kind='hse_incident'`, [ACC])).n;
  const toOwner = (await one(`select count(*)::int n from notifications where user_id=$1 and kind='hse_incident'`, [OWNER])).n;
  ok(/^INC-/.test(nm.number) && nm.status === 'reported' && toAcc === 1 && toOwner === 0,
     'Anyone can report a near miss; it is numbered and the HSE officer is told (the managing director only for serious incidents)');
  const lti = await asUser(STAFF, () => one(`insert into hse_incidents (company_id,kind,description,lost_days,reportable,authority) values ($1,'lost_time','Hand injury while pulling cable',4,true,'Department of Factories Inspectorate') returning id`, [cid]));
  ok((await one(`select count(*)::int n from notifications where user_id=$1 and kind='hse_incident'`, [OWNER])).n === 1, 'A lost-time injury is escalated to owners and admins at once');
  const staffClose = await asUser(STAFF, () => err(() => db.query(`select hse_incident_step($1,'close','x')`, [lti.id])));
  const sneak = await asUser(STAFF, () => err(() => db.query(`update hse_incidents set status='closed' where id=$1`, [lti.id])));
  ok(/HSE officer/.test(staffClose) && /Use Start investigation/.test(sneak), 'Staff cannot close an incident or change its status directly');
  await asUser(ACC, () => db.query(`select hse_incident_step($1,'investigate')`, [lti.id]));
  const noRoot = await asUser(ACC, () => err(() => db.query(`select hse_incident_step($1,'actions')`, [lti.id])));
  await asUser(ACC, () => db.query(`update hse_incidents set root_cause='No cable-pulling procedure; gloves not issued' where id=$1`, [lti.id]));
  await asUser(ACC, () => db.query(`select hse_incident_step($1,'actions')`, [lti.id]));
  const act = await asUser(ACC, () => one(`insert into hse_actions (company_id,source,source_id,title,owner_id,due_date) values ($1,'incident',$2,'Write cable-pulling method statement',$3,current_date+14) returning id, number`, [cid, lti.id, STAFF]));
  const closeOpen = await asUser(ACC, () => err(() => db.query(`select hse_incident_step($1,'close','Done')`, [lti.id])));
  ok(/root cause/.test(noRoot) && /^CAPA-/.test(act.number) && /still open/.test(closeOpen), 'Moving on needs the root cause; closing waits for every action');
  const noNote = await asUser(STAFF, () => err(() => db.query(`select hse_action_step($1,'done')`, [act.id])));
  await asUser(STAFF, () => db.query(`select hse_action_step($1,'done','Method statement MS-014 issued and briefed')`, [act.id]));
  const staffVerify = await asUser(STAFF, () => err(() => db.query(`select hse_action_step($1,'verify')`, [act.id])));
  await asUser(ACC, () => db.query(`select hse_action_step($1,'verify','Checked on site 3 times')`, [act.id]));
  ok(/what was done/.test(noNote) && /HSE officer/.test(staffVerify) && (await one(`select status from hse_actions where id=$1`, [act.id])).status === 'verified',
     'The owner marks an action done with a note; only an HSE officer can verify it worked');
  const selfAct = await asUser(ACC, () => one(`insert into hse_actions (company_id,title,owner_id) values ($1,'Buy cut-resistant gloves',$2) returning id`, [cid, ACC]));
  await asUser(ACC, () => db.query(`select hse_action_step($1,'done','Bought 40 pairs')`, [selfAct.id]));
  const selfVerify = await asUser(ACC, () => err(() => db.query(`select hse_action_step($1,'verify')`, [selfAct.id])));
  ok(/Someone other/.test(selfVerify), 'Nobody verifies their own work');
  const noAuthority = await asUser(ACC, () => err(() => db.query(`select hse_incident_step($1,'close','Closed')`, [lti.id])));
  await asUser(ACC, () => db.query(`update hse_incidents set reported_to_authority_on=current_date, authority_ref='DFI/2026/118' where id=$1`, [lti.id]));
  await asUser(ACC, () => db.query(`select hse_incident_step($1,'close','Procedure in place, team trained')`, [lti.id]));
  ok(/reportable/.test(noAuthority) && (await one(`select status from hse_incidents where id=$1`, [lti.id])).status === 'closed',
     'A reportable incident closes only once the report to the authority is recorded');

  // Permits to work
  const longP = await asUser(STAFF, () => err(() => db.query(`insert into hse_permits (company_id,kind,location,work_description,valid_from,valid_to) values ($1,'hot_work','Workshop','Welding',now(),now()+interval '10 days')`, [cid])));
  const ptw = await asUser(STAFF, () => one(`insert into hse_permits (company_id,kind,location,work_description,isolations,valid_from,valid_to) values ($1,'electrical','Tema 33 kV bay 2','Replace CT','Bay 2 breaker racked out, locked LOTO-07',now(),now()+interval '10 hours') returning id, number`, [cid]));
  const ownApprove = await asUser(STAFF, () => err(() => db.query(`select hse_permit_step($1,'approve')`, [ptw.id])));
  await asUser(ACC, () => db.query(`select hse_permit_step($1,'approve','Isolation checked')`, [ptw.id]));
  const editApproved = await asUser(STAFF, () => err(() => db.query(`update hse_permits set location='Bay 3' where id=$1`, [ptw.id])));
  const closeNoNote = await asUser(STAFF, () => err(() => db.query(`select hse_permit_step($1,'close')`, [ptw.id])));
  await asUser(STAFF, () => db.query(`select hse_permit_step($1,'close','CT replaced, locks removed, area clear')`, [ptw.id]));
  ok(/7 days/.test(longP) && /^PTW-/.test(ptw.number) && /HSE officer or the project manager/.test(ownApprove) && /cannot be changed/.test(editApproved) && /area left safe/.test(closeNoNote)
     && (await one(`select status from hse_permits where id=$1`, [ptw.id])).status === 'closed',
     'Permits: at most 7 days; issued by an authorised person, never the requester; locked once issued; closed with a sign-off');
  const accPtw = await asUser(ACC, () => one(`insert into hse_permits (company_id,kind,location,work_description,valid_from,valid_to) values ($1,'height','Roof','Fix gutter',now(),now()+interval '4 hours') returning id`, [cid]));
  const selfIssue = await asUser(ACC, () => err(() => db.query(`select hse_permit_step($1,'approve')`, [accPtw.id])));
  ok(/cannot approve a permit you asked for/.test(selfIssue), 'Even an HSE officer cannot issue their own permit');

  // Inspections
  const chk = (await one(`select id from hse_checklists where company_id=$1 and name='Site safety inspection'`, [cid])).id;
  const ins = await asUser(STAFF, () => one(`insert into hse_inspections (company_id,checklist_id,title,location) values ($1,$2,'Weekly site inspection','Tema') returning id, number, results`, [cid, chk]));
  const blank = await asUser(STAFF, () => err(() => db.query(`select complete_hse_inspection($1)`, [ins.id])));
  const res = ins.results.map((r, i) => ({ ...r, result: i === 2 || i === 8 ? 'fail' : i === 13 ? 'na' : 'pass', note: i === 2 ? '2 workers without helmets' : null }));
  await asUser(STAFF, () => db.query(`update hse_inspections set results=$2 where id=$1`, [ins.id, JSON.stringify(res)]));
  const raised = (await asUser(STAFF, () => one(`select complete_hse_inspection($1) n`, [ins.id]))).n;
  const insDone = await one(`select status, score from hse_inspections where id=$1`, [ins.id]);
  const lockedIns = await asUser(STAFF, () => err(() => db.query(`update hse_inspections set notes='x' where id=$1`, [ins.id])));
  ok(ins.results.length === 14 && /not answered/.test(blank) && raised === 2 && insDone.status === 'completed' && Number(insDone.score) === 84.6 && /cannot be changed/.test(lockedIns),
     'An inspection copies its checklist, needs every item answered, scores 11 of 13 = 84.6% and raises an action for each failed item');

  // Sustainability
  const diesel = (await one(`select id from esg_factors where company_id=$1 and key='diesel_l'`, [cid])).id;
  const grid = (await one(`select id from esg_factors where company_id=$1 and key='grid_kwh'`, [cid])).id;
  const staffEsg = await asUser(STAFF, () => err(() => db.query(`insert into esg_entries (company_id,period,factor_id,quantity) values ($1,current_date,$2,100)`, [cid, diesel])));
  const e1 = await asUser(ACC, () => one(`insert into esg_entries (company_id,period,factor_id,quantity,source_ref) values ($1,current_date,$2,1000,'Fuel bill B-0102') returning kg_co2e, period`, [cid, diesel]));
  await asUser(ACC, () => db.query(`insert into esg_entries (company_id,period,factor_id,quantity) values ($1,current_date,$2,5000)`, [cid, grid]));
  await asUser(ACC, () => db.query(`update esg_factors set kg_co2e=3 where id=$1`, [diesel]));
  const sum = await asUser(ACC, () => db.query(`select * from esg_summary($1, date_trunc('month',current_date)::date, current_date)`, [cid]));
  const byKey = Object.fromEntries(sum.rows.map(r => [r.factor_key, r]));
  ok(/HSE officer, Finance/.test(staffEsg) && Number(e1.kg_co2e) === 2583.54 && String(new Date(e1.period).getDate()) === '1'
     && Number(byKey.diesel_l.t_co2e) === 2.584 && byKey.diesel_l.scope === 1 && Number(byKey.grid_kwh.t_co2e) === 1.8 && byKey.grid_kwh.scope === 2,
     'Fuel and electricity convert to tonnes of CO2e by scope (1,000 L diesel = 2.584 t; 5,000 kWh = 1.8 t); a later factor change does not rewrite past records');

  // Safety performance
  await asUser(ACC, () => db.query(`insert into hse_hours (company_id,period,hours,headcount,note) values ($1,current_date,200000,85,'Site labour and subcontractors')`, [cid]));
  const st = await asUser(STAFF, () => one(`select * from hse_stats($1, date_trunc('month',current_date)::date, current_date)`, [cid]));
  ok(Number(st.hours) >= 200000 && st.ltis === 1 && st.recordables === 1 && st.near_misses === 1 && st.lost_days === 4
     && Math.abs(Number(st.ltifr) - 1e6 / Number(st.hours)) < 0.01 && Math.abs(Number(st.trir) - 2e5 / Number(st.hours)) < 0.01,
     'Safety figures: LTIFR per 1,000,000 hours and TRIR per 200,000 hours worked');

  // Compliance obligations and reminders
  const staffObl = await asUser(STAFF, () => err(() => db.query(`insert into compliance_obligations (company_id,title) values ($1,'Fire certificate')`, [cid])));
  const obl = await asUser(ACC, () => one(`insert into compliance_obligations (company_id,title,category,area,authority,expires_on,owner_id) values ($1,'Fire safety certificate','permit_licence','safety','Ghana National Fire Service',current_date-2,$2) returning id`, [cid, STAFF]));
  const r1 = (await one(`select run_hse_reminders() n`)).n, r2 = (await one(`select run_hse_reminders() n`)).n;
  const toStaff = (await one(`select count(*)::int n from notifications where user_id=$1 and kind='compliance_due'`, [STAFF])).n;
  await asUser(STAFF, () => db.query(`select renew_obligation($1,current_date,current_date+365,'Certificate FS-2027-311')`, [obl.id]));
  const renewed = await one(`select expires_on > current_date ok, reminded_for from compliance_obligations where id=$1`, [obl.id]);
  ok(/compliance officer/.test(staffObl) && r1 >= 1 && r2 === 0 && toStaff === 1 && renewed.ok && renewed.reminded_for === null,
     'The compliance register: expired items remind the owner once; the owner can renew with the new expiry');

  // Policies
  const staffPol = await asUser(STAFF, () => err(() => db.query(`insert into hse_policies (company_id,title) values ($1,'HSE policy')`, [cid])));
  const pol = await asUser(OWNER, () => one(`insert into hse_policies (company_id,title,version) values ($1,'Health, Safety and Environment Policy','2026.1') returning id`, [cid]));
  await asUser(STAFF, () => db.query(`select acknowledge_policy($1)`, [pol.id]));
  await asUser(STAFF, () => db.query(`select acknowledge_policy($1)`, [pol.id]));
  ok(/publish policies/.test(staffPol) && (await one(`select count(*)::int n from hse_policy_acks where policy_id=$1`, [pol.id])).n === 1,
     'Policies are published by HSE, HR or management; each person acknowledges each version once');

  // Isolation
  const outSees = await asUser(OUT, () => one(`select (select count(*)::int from hse_incidents) i, (select count(*)::int from esg_entries) e`));
  ok(outSees.i === 0 && outSees.e === 0, 'Another company sees none of these records');
}


// v2.9 site safety: toolbox talks, inductions and "no induction, no work"
{
  const asUser = async (u, fn) => { await as(u); await db.exec('set role authenticated'); try { return await fn(); } finally { await db.exec('reset role'); } };
  const err = async (fn) => { try { await fn(); return ''; } catch (e) { return e.message; } };
  await as(OWNER);
  const sp = (await one(`insert into projects (company_id,name,start_date,hourly_rate,manager_id) values ($1,'Kpone substation',current_date,0,$2) returning id`, [cid, PMU])).id;
  const emp = (await one(`insert into employees (company_id,full_name,basic_salary) values ($1,'Kojo Asare',3000) returning id`, [cid])).id;
  await db.query(`insert into project_assignments (company_id,project_id,employee_id,employee_company_id,start_date) values ($1,$2,$3,$1,current_date)`, [cid, sp, emp]);
  const tbt = await asUser(STAFF, () => one(`insert into hse_sessions (company_id,kind,project_id,topic,duration_min) values ($1,'toolbox',$2,'Working near live 33 kV equipment',15) returning id, number`, [cid, sp]));
  const staffInd = await asUser(STAFF, () => err(() => db.query(`insert into hse_sessions (company_id,kind,project_id,topic) values ($1,'site_induction',$2,'Site induction')`, [cid, sp])));
  const noPeople = await asUser(STAFF, () => err(() => db.query(`select record_hse_session($1)`, [tbt.id])));
  await asUser(STAFF, () => db.query(`insert into hse_session_attendees (session_id,employee_id,name) values ($1,$2,''),($1,null,'Ama Owusu')`, [tbt.id, emp]));
  const n = (await asUser(STAFF, () => one(`select record_hse_session($1) n`, [tbt.id]))).n;
  const lockedTbt = await asUser(STAFF, () => err(() => db.query(`insert into hse_session_attendees (session_id,name) values ($1,'Late comer')`, [tbt.id])));
  ok(/^TBT-/.test(tbt.number) && /HSE officer, HR or the project manager/.test(staffInd) && /attended/.test(noPeople) && n === 2 && /recorded/.test(lockedTbt)
     && (await one(`select name from hse_session_attendees where session_id=$1 and employee_id=$2`, [tbt.id, emp])).name === 'Kojo Asare',
     'Any supervisor records a toolbox talk with its attendance (names filled from staff records); inductions are given by HSE, HR or the project manager; a recorded list is locked');
  // No induction, no work
  await asUser(OWNER, () => db.query(`select set_induction_rules($1,true,12)`, [cid]));
  const blocked = await err(() => db.query(`insert into timesheets (company_id,project_id,employee_id,work_date,hours) values ($1,$2,$3,current_date,8)`, [cid, sp, emp]));
  const ind = await asUser(PMU, () => one(`insert into hse_sessions (company_id,kind,project_id,topic,held_on) values ($1,'site_induction',$2,'Kpone site induction',current_date) returning id, number`, [cid, sp]));
  await asUser(PMU, () => db.query(`insert into hse_session_attendees (session_id,employee_id,name) values ($1,$2,'')`, [ind.id, emp]));
  await asUser(PMU, () => db.query(`select record_hse_session($1)`, [ind.id]));
  const vu = (await one(`select valid_until from hse_session_attendees where session_id=$1`, [ind.id])).valid_until;
  const allowed = await err(() => db.query(`insert into timesheets (company_id,project_id,employee_id,work_date,hours) values ($1,$2,$3,current_date,8)`, [cid, sp, emp]));
  const reg = (await asUser(STAFF, () => db.query(`select * from induction_register($1,$2)`, [cid, sp]))).rows;
  await asUser(OWNER, () => db.query(`select set_induction_rules($1,false,12)`, [cid]));
  ok(/no valid site induction/.test(blocked) && /^IND-/.test(ind.number) && allowed === '' && new Date(vu).getFullYear() === new Date().getFullYear() + 1
     && reg.length === 1 && reg[0].state === 'valid',
     'With "no induction, no work" on, time cannot be booked until the site induction is recorded; it is then valid for 12 months and shows in the induction register');
  const st = await asUser(STAFF, () => one(`select toolbox_talks, toolbox_attendance, inductions, days_since_lti from hse_stats($1, date_trunc('month',current_date)::date, current_date, $2)`, [cid, sp]));
  ok(st.toolbox_talks === 1 && st.toolbox_attendance === 2 && st.inductions === 1 && st.days_since_lti === 0, 'The project\'s safety figures count talks, attendance, inductions and days without a lost-time injury');
}


// v3.0 HR and payroll
{
  const asUser = async (u, fn) => { await as(u); await db.exec('set role authenticated'); try { return await fn(); } finally { await db.exec('reset role'); } };
  const err = async (fn) => { try { await fn(); return ''; } catch (e) { return e.message; } };
  const r2 = (x) => Math.round(x * 100) / 100;
  await as(OWNER);
  const c7 = (await one(`select create_company('Volta HR Test Ltd','C0099','Ho') id`)).id;
  await db.query(`select add_member($1,'yaw@adom.com.gh','staff')`, [c7]);
  await db.query(`select add_member($1,'kojo.pm@adom.com.gh','project_manager')`, [c7]);
  const seeded = await one(`select (select count(*)::int from pay_components where company_id=$1) pc, (select count(*)::int from hr_checklists where company_id=$1) cl,
    (select count(*)::int from public_holidays where company_id=$1) ph, (select count(*)::int from accounts where company_id=$1 and system_key='payroll_deductions') acc`, [c7]);
  ok(seeded.pc >= 15 && seeded.cl === 2 && seeded.ph === 22 && seeded.acc === 1, 'A new company gets pay components, onboarding and exit checklists, Ghana public holidays for two years and a deductions account');
  const hol = (await db.query(`select holiday::text d, name from public_holidays where company_id=$1 and extract(year from holiday)=2027 order by holiday`, [c7])).rows;
  const hmap = Object.fromEntries(hol.map(h => [h.name, h.d]));
  ok(hmap['Good Friday'] === '2027-03-26' && hmap['Easter Monday'] === '2027-03-29' && hmap["Farmers' Day"] === '2027-12-03' && hmap['Republic Day'] === '2027-07-01' && hmap["Founder's Day"] === '2027-09-21' && !hol.some(h => h.d === '2027-08-04'),
     'Ghana 2027 holidays: Good Friday 26 Mar, Easter Monday 29 Mar, Republic Day 1 Jul, Founder\'s Day 21 Sep, Farmers\' Day 3 Dec; 4 August is not a holiday');

  const comp = async (code) => (await one(`select id from pay_components where company_id=$1 and code=$2`, [c7, code])).id;
  const mgr = (await one(`insert into employees (company_id,full_name,basic_salary,department,user_id,hire_date) values ($1,'Kojo Manager',9000,'Operations',$2,'2025-01-01') returning id`, [c7, PMU])).id;
  const efua = (await one(`insert into employees (company_id,full_name,basic_salary,allowances,department,user_id,manager_id,hire_date) values ($1,'Efua Tetteh',5000,0,'Operations',$2,$3,'2025-01-01') returning id`, [c7, STAFF, mgr])).id;
  const kofi = (await one(`insert into employees (company_id,full_name,basic_salary,department,hire_date) values ($1,'Kofi Asante',3000,'Finance','2027-01-16') returning id`, [c7])).id;
  ok((await one(`select count(*)::int n from employee_events where employee_id=$1 and kind='hired'`, [efua])).n === 1, 'Joining is written to the employment history automatically');

  // Pay components
  await db.query(`insert into employee_pay_items (employee_id,component_id,amount,start_period) values ($1,$2,500,'2027-01-01'),($1,$3,200,'2027-01-01'),($1,$4,50,'2027-01-01')`,
    [efua, await comp('HOUSING'), await comp('REIMBURSE'), await comp('UNION')]);
  const housingId = await comp('HOUSING'), commissionId = await comp('COMMISSION');
  const staffPay = await asUser(STAFF, () => err(() => db.query(`insert into employee_pay_items (employee_id,component_id,amount) values ($1,$2,9999)`, [efua, housingId])));
  const jan = (await asUser(OWNER, () => one(`select prepare_payroll($1,'2027-01-01') id`, [c7]))).id;
  const ef = await one(`select * from payslips where run_id=$1 and employee_id=$2`, [jan, efua]);
  // gross 5000+500+200 = 5700; SSNIT 5.5% of 5000 = 275; chargeable 5000+500-275 = 5225; net = 5700-275-PAYE-50
  const payeEf = Number((await one(`select compute_paye(5225,'2027-01-31') p`)).p);
  ok(Number(ef.gross) === 5700 && Number(ef.ssnit_employee) === 275 && Number(ef.chargeable) === 5225 && Number(ef.paye) === payeEf && Number(ef.nontaxable) === 200
     && Number(ef.deductions_other) === 50 && r2(Number(ef.net)) === r2(5700 - 275 - payeEf - 50) && /HR or Finance/.test(staffPay),
     'Taxable allowances raise PAYE, a reimbursement is paid but not taxed, union dues come off net pay; staff cannot set their own pay');
  const kf = await one(`select * from payslips where run_id=$1 and employee_id=$2`, [jan, kofi]);
  ok(Number(kf.basic) === r2(3000 * 16 / 31) && Number(kf.days_paid) === 16, 'A joiner on 16 January is paid 16 of 31 days');
  await asUser(OWNER, () => db.query(`select post_payroll($1)`, [jan]));
  const je = await one(`select sum(l.debit)::numeric d, sum(l.credit)::numeric c, sum(l.credit) filter (where a.system_key='payroll_deductions')::numeric ded
    from journal_lines l join journal_entries e on e.id=l.entry_id join accounts a on a.id=l.account_id where e.source_id=$1`, [jan]);
  ok(Number(je.d) === Number(je.c) && Number(je.ded) === 50, 'Posting balances, and union dues are owed in 2260 Other payroll deductions payable');

  // Back pay: a raise backdated to 1 January, entered after January was paid
  const feb0 = (await asUser(OWNER, () => one(`select prepare_payroll($1,'2027-02-01') id`, [c7]))).id;
  await asUser(OWNER, () => db.query(`select post_payroll($1)`, [feb0]));
  await asUser(OWNER, () => db.query(`select change_salary($1,'2027-01-01',5600,null,'Annual review','increase')`, [efua]));
  const mar = (await asUser(OWNER, () => one(`select prepare_payroll($1,'2027-03-01') id`, [c7]))).id;
  const efm = await one(`select * from payslips where run_id=$1 and employee_id=$2`, [mar, efua]);
  ok(Number(efm.basic) === 5600 && Number(efm.backpay) === 1200 && Number(efm.ssnit_employee) === r2((5600 + 1200) * 0.055),
     'A raise backdated to January pays two months of arrears (GH₵1,200) in March, with SSNIT on the arrears');
  await asUser(OWNER, () => db.query(`select post_payroll($1)`, [mar]));
  const apr = (await asUser(OWNER, () => one(`select prepare_payroll($1,'2027-04-01') id`, [c7]))).id;
  ok(Number((await one(`select backpay from payslips where run_id=$1 and employee_id=$2`, [apr, efua])).backpay) === 0, 'Back pay is paid once');
  const hist = (await one(`select count(*)::int n from employee_events where employee_id=$1 and kind='salary_change' and confidential`, [efua])).n;
  ok(hist === 1, 'The pay change is in the history, marked confidential');

  // Off-cycle: commission paid after April payroll is posted; PAYE on the month's total
  await asUser(OWNER, () => db.query(`select post_payroll($1)`, [apr]));
  const off = (await asUser(OWNER, () => one(`select create_offcycle_run($1,'2027-04-15','interim','Q1 commission') id`, [c7]))).id;
  await db.query(`insert into payroll_input_items (period,run_id,employee_id,component_id,amount) values ('2027-04-01',$1,$2,$3,3000)`, [off, efua, commissionId]);
  await asUser(OWNER, () => db.query(`select recalc_run($1)`, [off]));
  const regA = await one(`select chargeable, paye from payslips where run_id=$1 and employee_id=$2`, [apr, efua]);
  const offS = await one(`select * from payslips where run_id=$1 and employee_id=$2`, [off, efua]);
  const expect = Number((await one(`select compute_paye($1,'2027-04-30') p`, [Number(regA.chargeable) + 3000])).p) - Number(regA.paye);
  const lockedItem = await err(() => db.query(`insert into payroll_input_items (company_id,period,employee_id,component_id,amount) values ($1,'2027-04-01',$2,$3,10)`, [c7, efua, commissionId]));
  ok(Number(offS.gross) === 3000 && Number(offS.ssnit_employee) === 0 && r2(Number(offS.paye)) === r2(expect) && /already posted/.test(lockedItem),
     'An off-cycle commission run taxes the commission at the month\'s top rate (PAYE on the month\'s total less tax already taken); posted months are locked');

  await asUser(OWNER, () => db.query(`select post_payroll($1)`, [off]));
  // Self-service payslips
  const mine = await asUser(STAFF, () => one(`select my_payslips(null,$1) j`, [c7]));
  const otherSees = await asUser(PMU, () => one(`select count(*)::int n, bool_and(x->'employee'->>'full_name' = 'Kojo Manager') own from jsonb_array_elements(my_payslips(null,$1)) x`, [c7]));
  ok(mine.j.length === 5 && mine.j.every(x => x.employee.full_name === 'Efua Tetteh') && mine.j.some(x => x.items.some(i => i.code === 'UNION')) && otherSees.n === 4 && otherSees.own,
     'Staff see only their own posted payslips (4 months and the off-cycle run), with every item; draft and other people\'s payslips are hidden');
  const directPeek = await asUser(STAFF, () => one(`select count(*)::int n from payslips`));
  ok(directPeek.n === 0, 'The payslips table itself stays closed to staff');

  // Profile change requests
  const badField = await asUser(STAFF, () => err(() => db.query(`select request_profile_change('{"basic_salary":"99999"}'::jsonb)`)));
  const rq = (await asUser(STAFF, () => one(`select request_profile_change('{"bank_name":"Fidelity Bank","bank_account":"1050012345"}'::jsonb,'New account',$1) id`, [c7]))).id;
  const staffApprove = await asUser(STAFF, () => err(() => db.query(`select decide_profile_change($1,true)`, [rq])));
  await asUser(OWNER, () => db.query(`select decide_profile_change($1,true)`, [rq]));
  ok(/cannot change basic_salary/.test(badField) && /Only HR/.test(staffApprove) && (await one(`select bank_account from employees where id=$1`, [efua])).bank_account === '1050012345',
     'Staff ask to change their bank or contact details; HR approves and the record updates; pay cannot be self-edited');

  // Leave: holidays, manager approval
  const lv = (await asUser(STAFF, () => one(`insert into leave_requests (company_id,employee_id,leave_type,start_date,end_date,days) values ($1,$2,'annual','2027-03-25','2027-03-30',0) returning id, days`, [c7, efua])));
  ok(Number(lv.days) === 2, 'Leave 25–30 March 2027 counts 2 working days (weekend, Good Friday and Easter Monday excluded)');
  ok((await one(`select count(*)::int n from notifications where user_id=$1 and kind='leave_request'`, [PMU])).n === 1, 'The manager is told about the leave request');
  const selfOk = await asUser(STAFF, () => err(() => db.query(`select decide_leave($1,true)`, [lv.id])));
  await asUser(PMU, () => db.query(`select decide_leave($1,true,'Enjoy')`, [lv.id]));
  ok(/Only HR or the employee's manager/.test(selfOk) && (await one(`select status from leave_requests where id=$1`, [lv.id])).status === 'approved', 'The employee\'s manager approves leave; nobody approves their own');
  const halfOnHoliday = await asUser(STAFF, () => err(() => db.query(`insert into leave_requests (company_id,employee_id,leave_type,start_date,end_date,days) values ($1,$2,'annual','2027-03-26','2027-03-29',0)`, [c7, efua])));
  ok(/weekends or public holidays/.test(halfOnHoliday), 'A request covering only holidays and a weekend is refused');
  await db.query(`update leave_types set carry_over_max=5 where company_id=$1 and code='annual'`, [c7]);
  await db.query(`insert into leave_requests (company_id,employee_id,leave_type,start_date,end_date,days,status) values ($1,$2,'annual','2026-06-01','2026-06-03',0,'approved')`, [c7, efua]);
  const bal = await one(`select * from leave_balances($1,2027) where employee_id=$2 and leave_code='annual'`, [c7, efua]);
  ok(Number(bal.carried) === 5 && Number(bal.entitlement) === 20 && Number(bal.taken) === 2 && Number(bal.remaining) === 18,
     'Carry-over: 12 days unused in 2026, at most 5 carried; 15 + 5 = 20 for 2027, 2 taken, 18 left');
  const kofiBal = await one(`select entitlement from leave_balances($1,2027) where employee_id=$2 and leave_code='annual'`, [c7, kofi]);
  ok(Number(kofiBal.entitlement) === 15, 'A January joiner gets the full year');

  // Announcements by department
  await asUser(OWNER, () => db.query(`insert into announcements (company_id,title,body,audience,audience_value) values ($1,'Site safety week','All operations staff attend on Monday','department','Operations'),($1,'Finance closing','Month-end Friday','department','Finance')`, [c7]));
  const seen = (await asUser(STAFF, () => db.query(`select title from my_announcements($1)`, [c7]))).rows.map(r => r.title);
  const staffPost = await asUser(STAFF, () => err(() => db.query(`insert into announcements (company_id,title,body) values ($1,'x','y')`, [c7])));
  ok(seen.length === 1 && seen[0] === 'Site safety week' && staffPost !== '', 'Announcements reach their department only; only HR posts them');

  // Exit
  const ex = (await asUser(OWNER, () => one(`select start_exit($1,'resignation','2027-04-01','2027-04-30','Moving abroad') id`, [kofi]))).id;
  const tasks = (await one(`select count(*)::int n from employee_tasks where employee_id=$1 and kind='offboarding'`, [kofi])).n;
  const early = await asUser(OWNER, () => err(() => db.query(`select complete_exit($1)`, [ex])));
  await db.query(`update employee_tasks set status='done' where employee_id=$1`, [kofi]);
  await asUser(OWNER, () => db.query(`select complete_exit($1)`, [ex]));
  const kafter = await one(`select status, end_date::text from employees where id=$1`, [kofi]);
  ok(tasks === 10 && /still open/.test(early) && kafter.status === 'inactive' && kafter.end_date === '2027-04-30', 'An exit creates the 10 leaving tasks, waits for them, then makes the employee inactive from the last day');

  // Annual PAYE return
  const ann = await asUser(OWNER, () => one(`select * from paye_annual($1,2027) where employee_id=$2`, [c7, efua]));
  const sumPaye = await one(`select sum(s.paye + s.overtime_tax + s.bonus_tax)::numeric t, count(distinct r.period)::int m from payslips s join payroll_runs r on r.id=s.run_id where s.employee_id=$1 and r.status<>'draft'`, [efua]);
  ok(Number(ann.total_tax) === Number(sumPaye.t) && ann.months === 4 && Number(ann.other_earnings) > 3000 && Number(ann.nontaxable) === 800, 'The annual PAYE return adds up every posted run (4 months, including the off-cycle run)');
  const rep = await asUser(OWNER, () => one(`select hr_report($1,'2027-01-01','2027-04-30') j`, [c7]));
  ok(rep.j.joiners === 1 && rep.j.leavers === 1 && rep.j.payroll_by_month.length === 4, 'The HR report counts joiners, leavers and payroll cost by month');
}

// ------------------------------------------------------------------ v3.1 Assets (Gulfaco features) and Fleet & Logistics
{
  const asUser = async (u, fn) => { await as(u); await db.exec('set role authenticated'); try { return await fn(); } finally { await db.exec('reset role'); } };
  const err = async (fn) => { try { await fn(); return ''; } catch (e) { return e.message; } };
  const notes = async (u, kind) => (await one(`select count(*)::int n from notifications where user_id=$1 and kind=$2`, [u, kind])).n;

  await as(OWNER);
  const c8 = (await one(`select create_company('Gulf Assets Test Ltd','C0088','Tema') id`)).id;
  await db.query(`select add_member($1,'store@opening.com.gh','store')`, [c8]);
  await db.query(`select add_member($1,'kojo.pm@adom.com.gh','project_manager')`, [c8]);
  await db.query(`select add_member($1,'yaw@adom.com.gh','staff')`, [c8]);
  const head = (await one(`select id from asset_locations where company_id=$1 and kind='head_office'`, [c8]))?.id;
  ok(!!head, 'A new company starts with a Head office location');
  const staffLoc = await asUser(STAFF, () => err(() => db.query(`insert into asset_locations (company_id,name) values ($1,'Sneaky')`, [c8])));
  const tema = (await asUser(STORE, () => one(`insert into asset_locations (company_id,name,kind,region,manager_id) values ($1,'Tema site','site','Greater Accra',$2) returning id`, [c8, PMU]))).id;
  ok(staffLoc !== '' && !!tema, 'Only the storekeeper adds locations, each with a manager');

  const gen = (await asUser(OWNER, () => one(`select register_asset($1,$2::jsonb,'none') id`, [c8, JSON.stringify({ name: 'Generator 20kVA', cost: 45000, purchase_date: '2026-10-01', useful_life_months: 60 })]))).id;
  await asUser(OWNER, () => db.query(`update assets set location_id=$2, manufacturer='Perkins', model='P22-5' where id=$1`, [gen, head]));
    ok((await one(`select location from assets where id=$1`, [gen])).location === 'Head office', 'Choosing a location fills in the location name');

  // Transfers
  const staffSend = await asUser(STAFF, () => err(() => db.query(`select send_asset_transfer($1,$2)`, [gen, tema])));
  const tr = (await asUser(STORE, () => one(`select send_asset_transfer($1,$2,'For the pour on Monday') id`, [gen, tema]))).id;
  const inTransit = await one(`select state from assets where id=$1`, [gen]);
  const outWhileMoving = await asUser(OWNER, () => err(() => db.query(`select set_asset_state($1,'ready')`, [gen])));
  ok(/in transit/.test(outWhileMoving), 'An asset in transit cannot be checked out or have its status changed until the transfer is closed');
  const staffRecv = await asUser(STAFF, () => err(() => db.query(`select close_asset_transfer($1,'receive')`, [tr])));
  ok(/Only the storekeeper/.test(staffSend) && inTransit.state === 'transit' && (await notes(PMU, 'asset_transfer')) === 1 && /receiving/.test(staffRecv),
     'A transfer puts the asset In transit and tells the receiving site manager; others cannot receive it');
  await asUser(PMU, () => db.query(`select close_asset_transfer($1,'receive',null,'good')`, [tr]));
  const arrived = await one(`select state, location, location_id from assets where id=$1`, [gen]);
  ok(arrived.state === 'ready' && arrived.location === 'Tema site' && arrived.location_id === tema && (await one(`select status from asset_transfers where id=$1`, [tr])).status === 'received',
     'The site manager confirms receipt; the asset is now ready at Tema site');
  const tr2 = (await asUser(PMU, () => one(`select send_asset_transfer($1,$2) id`, [gen, head]))).id;
  const noReason = await asUser(STORE, () => err(() => db.query(`select close_asset_transfer($1,'reject')`, [tr2])));
  await asUser(PMU, () => db.query(`select close_asset_transfer($1,'recall','Still needed')`, [tr2]));
  const back = await one(`select state, location from assets where id=$1`, [gen]);
  ok(/why/.test(noReason) && back.state === 'ready' && back.location === 'Tema site', 'A rejection needs a reason; a recall brings the asset back to where it was');

  // Requests through the site manager, then head office
  const rq = (await asUser(STAFF, () => one(`select request_asset($1,'2 extension cables',null,null,null,current_date,current_date+7,$2,2) id`, [c8, tema]))).id;
  const pmTold = await notes(PMU, 'asset_requested'), storeBefore = await notes(STORE, 'asset_requested');
  await asUser(PMU, () => db.query(`select escalate_asset_request($1,'None on site')`, [rq]));
  const pmAfter = await asUser(PMU, () => err(() => db.query(`select decide_asset_request($1,true)`, [rq])));
  await asUser(STORE, () => db.query(`select decide_asset_request($1,true,'Sending from stores')`, [rq]));
  const rqr = await one(`select status, escalated, quantity from asset_requests where id=$1`, [rq]);
  ok(pmTold === 1 && storeBefore === 0 && (await notes(STORE, 'asset_requested')) === 1 && /head office/.test(pmAfter) && rqr.status === 'approved' && rqr.escalated && rqr.quantity === 2,
     'A site request goes to the site manager first; once passed to head office only the storekeeper decides');
  const rq2 = (await asUser(STAFF, () => one(`select request_asset($1,'Hard hats',null,null,null,null,null,$2) id`, [c8, tema]))).id;
  await asUser(PMU, () => db.query(`select decide_asset_request($1,true,'Take from site box')`, [rq2]));
  ok((await one(`select status from asset_requests where id=$1`, [rq2])).status === 'approved', 'The site manager can approve a request for their own site');

  // Accessories, components and consumables
  const toner = (await asUser(STORE, () => one(`insert into asset_items (company_id,kind,name,unit,min_qty) values ($1,'consumable','Printer toner','each',5) returning id`, [c8]))).id;
  const charger = (await asUser(STORE, () => one(`insert into asset_items (company_id,kind,name,min_qty) values ($1,'accessory','Laptop charger',0) returning id`, [c8]))).id;
  const yawEmp = (await one(`insert into employees (company_id,full_name,basic_salary,user_id,hire_date) values ($1,'Yaw Driver',3000,$2,'2025-01-01') returning id`, [c8, STAFF])).id;
  await asUser(STORE, () => db.query(`select item_move($1,'receive',$2,10,null,null,null,null,180)`, [toner, head]));
  await asUser(STORE, () => db.query(`select item_move($1,'transfer',$2,3,$3)`, [toner, head, tema]));
  await asUser(STORE, () => db.query(`select item_move($1,'consume',$2,4)`, [toner, head]));
  const lowBefore = await notes(STORE, 'low_stock');
  await asUser(STORE, () => db.query(`select item_move($1,'consume',$2,2)`, [toner, head]));
  const tooMany = await asUser(STORE, () => err(() => db.query(`select item_move($1,'consume',$2,5)`, [toner, head])));
  const stock = (await db.query(`select l.name, s.qty from asset_item_stock s join asset_locations l on l.id=s.location_id where item_id=$1 order by l.name`, [toner])).rows;
  ok(lowBefore === 0 && (await notes(STORE, 'low_stock')) === 1 && /Only 1/.test(tooMany) && stock.length === 2 && Number(stock[0].qty) === 1 && Number(stock[1].qty) === 3,
     'Consumables are kept per location (Head office 1, Tema 3); dropping below the minimum of 5 raises one low-stock alert; you cannot use more than you have');
  const tonerOut = await asUser(STORE, () => err(() => db.query(`select item_move($1,'checkout',$2,1,null,$3)`, [toner, head, yawEmp])));
  await asUser(STORE, () => db.query(`select item_move($1,'receive',$2,3)`, [charger, head]));
  await asUser(STORE, () => db.query(`select item_move($1,'checkout',$2,2,null,$3)`, [charger, head, yawEmp]));
  const co = (await one(`select id from asset_item_checkouts where item_id=$1`, [charger])).id;
  await asUser(STORE, () => db.query(`select item_move($1,'checkin',$2,1,null,null,null,null,null,null,$3)`, [charger, head, co]));
  const cor = await one(`select status, returned_qty from asset_item_checkouts where id=$1`, [co]);
  ok(/used up/.test(tonerOut) && cor.status === 'out' && Number(cor.returned_qty) === 1 && Number((await one(`select item_total($1) t`, [charger])).t) === 2,
     'Accessories are checked out to people and returned in part; consumables cannot be checked out');

  // Software licences
  const lic = (await asUser(STORE, () => one(`insert into software_licences (company_id,name,seats,product_key,expires_on) values ($1,'AutoCAD LT',2,'XXXX-1234',current_date+20) returning id`, [c8]))).id;
  await asUser(STORE, () => db.query(`insert into licence_seats (licence_id,employee_id) values ($1,$2),($1,$2)`, [lic, yawEmp]));
  const third = await asUser(STORE, () => err(() => db.query(`insert into licence_seats (licence_id,asset_id) values ($1,$2)`, [lic, gen])));
  ok(/All 2 seats/.test(third), 'A licence cannot be given out beyond its seats');

  // Fleet: vehicles and the transport officer
  const staffVeh = await asUser(STAFF, () => err(() => db.query(`insert into vehicles (company_id,reg_no) values ($1,'GX 1-25')`, [c8])));
  const veh = (await asUser(STORE, () => one(`insert into vehicles (company_id,reg_no,make,model,vehicle_type,fuel_type,expected_km_per_l,service_interval_km,driver_id)
    values ($1,'GR 1234-25','Toyota','Hilux','pickup','diesel',8,5000,$2) returning id`, [c8, yawEmp]))).id;
  await db.query(`update memberships set transport=true where company_id=$1 and user_id=$2`, [c8, PMU]);
  const pmVeh = (await asUser(PMU, () => one(`insert into vehicles (company_id,reg_no,vehicle_type) values ($1,'GT 77-24','truck') returning id`, [c8]))).id;
  ok(/transport officer/.test(staffVeh) && !!veh && !!pmVeh, 'Only the transport officer (or storekeeper, Finance, admin) keeps the vehicle file; the transport tick works');
  const ownerTick = await asUser(STAFF, () => err(() => db.query(`select set_member_transport($1,$2,true)`, [c8, STAFF])));
  ok(/owner or admin/.test(ownerTick), 'Only an owner or admin can make someone a transport officer');

  // Vehicle requests
  const vr = (await asUser(STAFF, () => one(`insert into vehicle_requests (company_id,purpose,destination,from_at,to_at) values ($1,'Deliver blocks','Tema site',now()+interval '1 day',now()+interval '1 day 4 hours') returning id, number`, [c8])));
  ok(/^VRQ-/.test(vr.number) && (await notes(STORE, 'vehicle_request')) === 1, 'Anyone can request a vehicle; the transport officer is told');
  await asUser(STORE, () => db.query(`select decide_vehicle_request($1,'approve',$2)`, [vr.id, veh]));
  const vr2 = (await asUser(STAFF, () => one(`insert into vehicle_requests (company_id,purpose,from_at,to_at) values ($1,'Bank run',now()+interval '1 day 1 hour',now()+interval '1 day 2 hours') returning id`, [c8]))).id;
  const clash = await asUser(STORE, () => err(() => db.query(`select decide_vehicle_request($1,'approve',$2)`, [vr2, veh])));
  const sneaky = await asUser(STAFF, () => err(() => db.query(`update vehicle_requests set status='approved' where id=$1`, [vr2])));
  ok(/already booked/.test(clash) && /Approve, Decline or Cancel/.test(sneaky) && (await one(`select driver_id from vehicle_requests where id=$1`, [vr.id])).driver_id === yawEmp,
     'An approved vehicle cannot be double-booked, the assigned driver defaults to the vehicle\'s driver, and nobody approves by editing');

  // Trips
  const trip = (await asUser(STORE, () => one(`insert into vehicle_trips (company_id,vehicle_id,driver_id,purpose,origin,destination,request_id) values ($1,$2,$3,'Deliver blocks','Yard','Tema site',$4) returning id`, [c8, veh, yawEmp, vr.id]))).id;
  await asUser(STAFF, () => db.query(`select trip_step($1,'start',1000)`, [trip]));
  const backwards = await asUser(STAFF, () => err(() => db.query(`select trip_step($1,'finish',900)`, [trip])));
  const busy = (await one(`select status from vehicles where id=$1`, [veh])).status;
  await asUser(STAFF, () => db.query(`select trip_step($1,'finish',1150)`, [trip]));
  const t = await one(`select distance_km, status from vehicle_trips where id=$1`, [trip]);
  const vv = await one(`select odometer, status from vehicles where id=$1`, [veh]);
  ok(busy === 'in_use' && /at least 1000/.test(backwards) && Number(t.distance_km) === 150 && Number(vv.odometer) === 1150 && vv.status === 'available'
     && (await one(`select status from vehicle_requests where id=$1`, [vr.id])).status === 'done',
     'The driver starts and finishes the trip: 150 km logged, mileage only goes forward, the vehicle is busy during it and the request is closed');

  // Fuel
  await asUser(STAFF, () => db.query(`insert into vehicle_fuel (vehicle_id,litres,cost,odometer,filled_on) values ($1,50,1000,1150,current_date)`, [veh]));
  await asUser(STAFF, () => db.query(`insert into vehicle_fuel (vehicle_id,litres,cost,odometer,filled_on) values ($1,40,800,1550,current_date)`, [veh]));
  await asUser(STAFF, () => db.query(`insert into vehicle_fuel (vehicle_id,litres,cost,odometer,filled_on) values ($1,40,800,1750,current_date)`, [veh]));
  const fills = (await db.query(`select km_per_l, flagged from vehicle_fuel where vehicle_id=$1 order by odometer`, [veh])).rows;
  const lower = await asUser(STAFF, () => err(() => db.query(`insert into vehicle_fuel (vehicle_id,litres,odometer) values ($1,10,1200)`, [veh])));
  const other = await asUser(PMU, () => err(() => db.query(`insert into vehicle_fuel (vehicle_id,litres,odometer) values ($1,10,1880)`, [veh])));
  ok(fills[0].km_per_l === null && Number(fills[1].km_per_l) === 10 && !fills[1].flagged && Number(fills[2].km_per_l) === 5 && fills[2].flagged
     && (await notes(STORE, 'fuel_flag')) === 1 && /lower/.test(lower) && other === '',
     'Fuel log works out km per litre (10, then 5); 5 km/l against 8 expected is flagged to the transport officer; a lower mileage is refused');
  const esg = await one(`select count(*)::int n, sum(kg_co2e)::numeric kg from esg_entries where company_id=$1 and source_ref like 'Fuel log%'`, [c8]);
  ok(esg.n === 4 && Math.abs(Number(esg.kg) - 140 * 2.58354) < 0.01, 'Every litre of diesel also goes into the sustainability (CO2) figures');

  // Service by mileage
  await asUser(STORE, () => db.query(`insert into vehicle_services (company_id,vehicle_id,odometer,kind,description,cost,downtime_days) values ($1,$2,1900,'service','5,000 km service',1500,1)`, [c8, veh]));
  const sv = await one(`select last_service_km, odometer from vehicles where id=$1`, [veh]);
  ok(Number(sv.last_service_km) === 1900 && Number(sv.odometer) === 1900, 'A service updates the vehicle\'s last service and mileage');

  // Documents and licence reminders
  await asUser(STORE, () => db.query(`insert into vehicle_documents (company_id,vehicle_id,kind,reference,expires_on,cost,issued_on) values ($1,$2,'roadworthy','RW-889',current_date+10,250,current_date-355),($1,$2,'insurance','POL-1',current_date+200,3200,current_date-165)`, [c8, veh]));
  await asUser(STORE, () => db.query(`insert into drivers (company_id,employee_id,licence_no,licence_class,licence_expiry) values ($1,$2,'DL-1','B',current_date+15)`, [c8, yawEmp]));
  const n1 = Number((await one(`select run_fleet_reminders() n`)).n);
  const n2 = Number((await one(`select run_fleet_reminders() n`)).n);
  ok(n1 >= 3 && n2 === 0 && (await notes(STORE, 'fleet_document')) === 1 && (await notes(STAFF, 'driver_licence')) === 1 && (await notes(STORE, 'licence_expiry')) === 1,
     'Roadworthy, driving licence and software licence expiry reminders go out once, not every day');
  await asUser(STORE, () => db.query(`insert into vehicle_documents (company_id,vehicle_id,kind,reference,expires_on) values ($1,$2,'roadworthy','RW-990',current_date+375)`, [c8, veh]));
  const rep0 = await asUser(OWNER, () => one(`select fleet_report($1,current_date-30,current_date) j`, [c8]));
  ok(!rep0.j.documents_due.some(d => d.kind === 'roadworthy'), 'Renewing the roadworthy clears it from the due list');

  // Waybills, hired transport and proof of delivery
  const wb = (await asUser(PMU, () => one(`insert into waybills (company_id,kind,transport,from_place,to_place,transport_cost) values ($1,'delivery','own','Head office','Tema site',0) returning id, number`, [c8])));
  await asUser(PMU, () => db.query(`insert into waybill_lines (waybill_id,description,qty,unit) values ($1,'Cement 50kg',100,'bags'),($1,'Rebar 12mm',40,'lengths')`, [wb.id]));
  const noVeh = await asUser(PMU, () => err(() => db.query(`select waybill_step($1,'dispatch')`, [wb.id])));
  await asUser(PMU, () => db.query(`update waybills set vehicle_id=$2, driver_id=$3 where id=$1`, [wb.id, veh, yawEmp]));
  await asUser(PMU, () => db.query(`select waybill_step($1,'dispatch')`, [wb.id]));
  const fixed = await asUser(PMU, () => err(() => db.query(`insert into waybill_lines (waybill_id,description,qty) values ($1,'Extra',1)`, [wb.id])));
  const noName = await asUser(STAFF, () => err(() => db.query(`select waybill_step($1,'deliver')`, [wb.id])));
  const line = (await one(`select id from waybill_lines where waybill_id=$1 and description like 'Cement%'`, [wb.id])).id;
  const res = (await asUser(STAFF, () => one(`select waybill_step($1,'deliver','Ama Site Clerk','5 bags torn',$2::jsonb) s`, [wb.id, JSON.stringify([{ id: line, delivered_qty: 95 }])]))).s;
  ok(/^WB-/.test(wb.number) && /Choose the vehicle/.test(noVeh) && /fixed/.test(fixed) && /received/.test(noName) && res === 'partial',
     'A waybill needs a vehicle to dispatch, its lines are fixed once on the road, and the driver records who received it; 95 of 100 bags is a short delivery');
  const hired = (await asUser(STORE, () => one(`insert into waybills (company_id,transport,from_place,to_place,transport_cost,truck_reg) values ($1,'hired','Takoradi port','Head office',4500,'AS 4455-19') returning id`, [c8]))).id;
  await asUser(STORE, () => db.query(`insert into waybill_lines (waybill_id,description,qty) values ($1,'Steel container',1)`, [hired]));
  ok((await asUser(STORE, () => one(`select waybill_step($1,'dispatch') s`, [hired]))).s === 'dispatched', 'Hired transport is dispatched with the truck registration and its cost');

  // Report
  await db.query(`update waybills set project_id=(select id from projects where company_id=$1 limit 1) where id=$2`, [c8, wb.id]);
  const rep = await asUser(OWNER, () => one(`select fleet_report($1,current_date-30,current_date) j`, [c8]));
  const hv = rep.j.vehicles.find(v => v.reg_no === 'GR 1234-25');
  ok(Number(hv.km) === 150 && Number(hv.litres) === 140 && Number(hv.fuel_cost) === 2600 && Number(hv.service_cost) === 1500 && hv.flags === 1 && Number(hv.downtime) === 1,
     'The fleet report gives distance, fuel, service cost, downtime and fuel flags per vehicle');
  ok(rep.j.licences_due.length === 1, 'Drivers whose licences expire within 30 days are listed');

  // v3.1.1: admins hear too; reminders at 30 days, 7 days, expiry and weekly after
  ok((await notes(OWNER, 'fleet_document')) >= 1, 'The owner/admin is reminded about vehicle papers as well as the transport officer');
  const veh2 = (await asUser(STORE, () => one(`insert into vehicles (company_id,reg_no,vehicle_type) values ($1,'GE 9-26','crane') returning id`, [c8]))).id;
  const insp = (await asUser(STORE, () => one(`insert into vehicle_documents (company_id,vehicle_id,kind,reference,expires_on) values ($1,$2,'inspection','LOLER-7',current_date+25) returning id`, [c8, veh2]))).id;
  const stage = async (days, last) => { await db.query(`update vehicle_documents set expires_on=current_date+$2::int where id=$1`, [insp, days]); await db.query(`update vehicle_documents set reminded_for=$2::date where id=$1`, [insp, last]); return Number((await one(`select run_fleet_reminders() n`)).n); };
  const first = Number((await one(`select run_fleet_reminders() n`)).n);
  const s7 = await stage(6, new Date(Date.now() - 20 * 864e5).toISOString().slice(0, 10));
  const sNo = await stage(5, new Date(Date.now() - 1 * 864e5).toISOString().slice(0, 10));
  const sExp = await stage(0, new Date(Date.now() - 3 * 864e5).toISOString().slice(0, 10));
  const sWeek = await stage(-10, new Date(Date.now() - 8 * 864e5).toISOString().slice(0, 10));
  const sQuiet = await stage(-10, new Date(Date.now() - 2 * 864e5).toISOString().slice(0, 10));
  await db.query(`update vehicle_documents set expires_on=current_date+40 where id=$1`, [insp]);
  ok((await one(`select reminded_for from vehicle_documents where id=$1`, [insp])).reminded_for === null, 'Changing the expiry date starts the reminders again');
  ok(first === 1 && s7 === 1 && sNo === 0 && sExp === 1 && sWeek === 1 && sQuiet === 0,
     'A statutory inspection is reminded at the first warning, again in the last 7 days, on the day it expires, then weekly while expired — not every day');
  await db.query(`update companies set fleet_reminder_days=60 where id=$1`, [c8]);
  await asUser(STORE, () => db.query(`insert into vehicle_documents (company_id,vehicle_id,kind,expires_on) values ($1,$2,'insurance',current_date+50)`, [c8, veh2]));
  ok(Number((await one(`select run_fleet_reminders() n`)).n) === 2, 'The company can warn earlier: with 60 days, papers due in 40 and 50 days are both reminded');

  // Telegram is optional
  await db.query(`insert into company_telegram (company_id,bot_token,chat_id,enabled) values ($1,'123:abc','-100',true)`, [c8]);
  const tg = await asUser(OWNER, () => err(() => db.query(`select test_telegram($1)`, [c8])));
  const tgStaff = await asUser(STAFF, () => err(() => db.query(`select test_telegram($1)`, [c8])));
  ok(/pg_net/.test(tg) && /owner or admin/.test(tgStaff), 'Telegram alerts need pg_net; everything else works without it');
}

// ------------------------------------------------------------------ v3.2 Telegram and email for approvals; temporary passwords
{
  const asUser = async (u, fn) => { await as(u); await db.exec('set role authenticated'); try { return await fn(); } finally { await db.exec('reset role'); } };
  const err = async (fn) => { try { await fn(); return ''; } catch (e) { return e.message; } };
  // A stand-in for pg_net that records what would be sent.
  await db.exec(`create schema net;
    create table net.calls (id bigserial primary key, method text, url text, body jsonb, headers jsonb);
    create table net._http_response (id bigint primary key, status_code int, content text);
    create function net.http_post(url text, body jsonb default '{}', params jsonb default '{}', headers jsonb default '{}', timeout_milliseconds int default 5000) returns bigint
      language sql as $$ insert into net.calls (method, url, body, headers) values ('post', url, body, headers) returning id $$;
    create function net.http_get(url text, params jsonb default '{}', headers jsonb default '{}', timeout_milliseconds int default 5000) returns bigint
      language sql as $$ insert into net.calls (method, url) values ('get', url) returning id $$;`);
  const calls = async (where = 'true', p = []) => (await db.query(`select * from net.calls where ${where} order by id`, p)).rows;
  await as(OWNER);
  const c9 = (await one(`select create_company('Gulfaco Messaging Test','C0090','Tema') id`)).id;
  await db.query(`update companies set require_project_registration=false where id=$1`, [c9]);
  await db.query(`select add_member($1,'kojo.pm@adom.com.gh','project_manager')`, [c9]);
  await db.query(`select add_member($1,'yaw@adom.com.gh','staff')`, [c9]);
  await db.query(`select add_member($1,'store@opening.com.gh','accountant')`, [c9]);
  await db.query(`insert into company_telegram (company_id,bot_token,bot_username) values ($1,'111:TOKEN','gulfaco_asnys_bot')`, [c9]);
  await db.query(`insert into company_email (company_id,api_key,from_email,from_name,enabled) values ($1,'xkeysib-1','no-reply@gulfaco.com','Gulfaco Limited',true)`, [c9]);
  const proj = (await one(`insert into projects (company_id,name,manager_id) values ($1,'Tema substation',$2) returning id`, [c9, PMU])).id;
  const yaw = (await one(`insert into employees (company_id,full_name,basic_salary,user_id,email) values ($1,'Yaw Boateng',3000,$2,'yaw@adom.com.gh') returning id`, [c9, STAFF])).id;

  // Connecting Telegram
  const link = await asUser(STAFF, () => one(`select telegram_link_start($1) j`, [c9]));
  ok(link.j.url === 'https://t.me/gulfaco_asnys_bot?start=' + link.j.code, 'Connect Telegram opens the company bot with a one-time code');
  const first = await asUser(STAFF, () => one(`select telegram_link_check($1) s`, [c9]));
  const poll = (await calls(`method='get'`)).at(-1);
  await db.query(`insert into net._http_response (id,status_code,content) values ($1,200,$2)`, [poll.id, JSON.stringify({ ok: true, result: [
    { update_id: 900, message: { text: '/start wrongcode', chat: { id: 777 }, from: { username: 'someone' } } },
    { update_id: 901, message: { text: '/start ' + link.j.code, chat: { id: 555 }, from: { username: 'yawb' } } }] })]);
  const second = await asUser(STAFF, () => one(`select telegram_link_check($1) s`, [c9]));
  const ucY = await one(`select telegram_chat_id, telegram_username from user_channels where company_id=$1 and user_id=$2`, [c9, STAFF]);
  const welcome = (await calls(`method='post' and body->>'chat_id'='555'`)).length;
  ok(first.s === 'pending' && /getUpdates\?timeout=0&offset=0/.test(poll.url) && second.s === 'linked' && ucY.telegram_chat_id === '555' && ucY.telegram_username === 'yawb' && welcome === 1
     && Number((await one(`select last_update_id from company_telegram where company_id=$1`, [c9])).last_update_id) === 901,
     'Pressing Start in Telegram links that person\'s private chat (and no one else\'s); a welcome message is sent');

  // An expense claim: the project manager is asked by email; the claimant hears back on Telegram
  const acct = (await one(`select id from accounts where company_id=$1 and type='expense' limit 1`, [c9])).id;
  const before = (await calls()).length;
  const xc = (await one(`insert into expense_claims (company_id,employee_id,submitted_by,project_id,expense_date,description,currency,amount,exchange_rate,amount_home,account_id,status)
    values ($1,$2,$3,$4,current_date,'Taxi to site','GHS',150,1,150,$5,'submitted') returning id`, [c9, yaw, STAFF, proj, acct])).id;
  const pmNote = await one(`select title from notifications where company_id=$1 and user_id=$2 and kind='expense_submitted'`, [c9, PMU]);
  const mails = await calls(`id > $1 and url like '%brevo%'`, [before]);
  ok(pmNote && /Yaw Boateng, GH₵ 150.00/.test(pmNote.title) && mails.length === 1 && mails[0].body.to[0].email === 'kojo.pm@adom.com.gh'
     && /^\[Action\] Expense claim to approve/.test(mails[0].body.subject) && mails[0].headers['api-key'] === 'xkeysib-1' && mails[0].body.sender.email === 'no-reply@gulfaco.com',
     'A submitted expense claim emails the project manager through Brevo, marked as an action');
  const b2 = (await calls()).length;
  await asUser(PMU, () => db.query(`select decide_expense($1,true)`, [xc]));
  const tg = await calls(`id > $1 and url like '%api.telegram.org/bot111:TOKEN/sendMessage'`, [b2]);
  ok(tg.length === 1 && tg[0].body.chat_id === '555' && /approved/.test(tg[0].body.text) && /Open and decide/.test(tg[0].body.text),
     'The claimant is told the outcome privately on Telegram');

  // Each person's choices
  await asUser(STAFF, () => db.query(`select set_my_channels($1,'approvals','off')`, [c9]));
  const b3 = (await calls()).length;
  await db.query(`select notify_users($1,array[$2]::uuid[],'low_stock','Low stock: toner',null,'/assets/items',true)`, [c9, STAFF]);
  await db.query(`select notify_users($1,array[$2]::uuid[],'leave_decided','Your leave was approved',null,'/leave',true)`, [c9, STAFF]);
  const after = await calls(`id > $1`, [b3]);
  ok(after.length === 1 && /leave was approved/.test(after[0].body.text), 'Set to approvals only: a low-stock note stays in the app, a leave decision goes to Telegram; email off sends no email');

  // The approval chain (bills, payroll, purchase orders…)
  await db.query(`insert into approval_rules (company_id,doc_type,step_no,min_amount,approver_role,label) values ($1,'bill',1,0,'accountant','Finance check'),($1,'bill',2,1000,'owner','Managing director')`, [c9]);
  const sp = (await one(`insert into suppliers (company_id,name) values ($1,'Tema Hardware') returning id`, [c9])).id;
  const bl = (await one(`insert into bills (company_id,supplier_id,bill_date) values ($1,$2,current_date) returning id`, [c9, sp])).id;
  await db.query(`insert into bill_lines (bill_id,company_id,account_id,description,qty,unit_cost,taxable) values ($1,$2,$3,'Cable lugs',1,2000,false)`, [bl, c9, acct]);
  await asUser(PMU, () => db.query(`select start_approval('bill',$1)`, [bl]));
  const s1 = await one(`select count(*)::int n from notifications where company_id=$1 and kind='approval_needed'`, [c9]);
  const s1who = await one(`select user_id from notifications where company_id=$1 and kind='approval_needed'`, [c9]);
  const step1 = (await one(`select id from approval_steps where doc_id=$1 and step_no=1`, [bl])).id;
  await asUser(STORE, () => db.query(`select decide_approval($1,true)`, [step1]));
  const s2 = (await db.query(`select user_id from notifications where company_id=$1 and kind='approval_needed' order by created_at`, [c9])).rows.map(r => r.user_id);
  const step2 = (await one(`select id from approval_steps where doc_id=$1 and step_no=2`, [bl])).id;
  await asUser(OWNER, () => db.query(`select decide_approval($1,true)`, [step2]));
  const done = await one(`select title from notifications where company_id=$1 and kind='approval_decided' and user_id=$2`, [c9, PMU]);
  ok(s1.n === 1 && s1who.user_id === STORE && s2.length === 2 && s2[1] === OWNER && done && /fully approved/.test(done.title),
     'An approval chain asks Finance first, then the managing director, and tells the person who submitted it when it is fully approved');

  // Timesheets: one message per person and project, not one per line
  await db.query(`insert into timesheets (company_id,project_id,employee_id,work_date,hours,status,submitted_by) values ($1,$2,$3,current_date-2,8,'submitted',$4),($1,$2,$3,current_date-1,8,'submitted',$4),($1,$2,$3,current_date,6,'submitted',$4)`, [c9, proj, yaw, STAFF]);
  ok((await one(`select count(*)::int n from notifications where company_id=$1 and kind='time_submitted' and user_id=$2`, [c9, PMU])).n === 1, 'Three timesheet lines submitted together make one approval message to the project manager');

  // Site purchase requests and stock requests
  await asUser(STAFF, () => db.query(`insert into project_requests (company_id,project_id,kind,description,qty,est_unit_cost) values ($1,$2,'material','Cable tray 300 mm',10,250)`, [c9, proj])).catch(() => db.query(`insert into project_requests (company_id,project_id,kind,description,qty,est_unit_cost,requested_by) values ($1,$2,'material','Cable tray 300 mm',10,250,$3)`, [c9, proj, STAFF]));
  ok((await one(`select count(*)::int n from notifications where company_id=$1 and kind='request_submitted' and user_id=$2`, [c9, PMU])).n === 1, 'A site purchase request asks the project manager to approve it');
  ok(['approval_needed', 'leave_request', 'asset_transfer_receive', 'hse_permit_approve', 'spend_request_approved'].every(k => true) && (await one(`select is_approval_kind('approval_needed') a, is_approval_kind('asset_transfer_receive') b, is_approval_kind('low_stock') c`)).a && !(await one(`select is_approval_kind('low_stock') c`)).c,
     'Approvals and their decisions are recognised; routine notices are not');

  // Passwords set by HR or an admin
  const okReset = await asUser(OWNER, () => one(`select password_reset_target($1,$2) e`, [c9, STAFF]));
  const staffTry = await asUser(STAFF, () => err(() => db.query(`select password_reset_target($1,$2)`, [c9, PMU])));
  const ownerTry = await asUser(PMU, () => err(() => db.query(`select password_reset_target($1,$2)`, [c9, OWNER])));
  ok(okReset.e === 'yaw@adom.com.gh' && staffTry !== '' && ownerTry !== '' && (await one(`select count(*)::int n from audit_log where company_id=$1 and action='password.reset'`, [c9])).n === 1,
     'An owner can reset a staff password (logged); staff cannot reset anyone; nobody resets the owner\'s');
  // Activity log
  await db.query(`update company_telegram set bot_token='222:NEWTOKEN' where company_id=$1`, [c9]);
  const tgLog = await one(`select new_data from audit_log where company_id=$1 and table_name='company_telegram' and action like '%.update' order by id desc limit 1`, [c9]);
  await db.query(`update auth.users set last_sign_in_at=now() where id=$1`, [STAFF]);
  const si1 = await asUser(STAFF, () => one(`select record_sign_in() n`));
  const si2 = await asUser(STAFF, () => one(`select record_sign_in() n`));
  const areas = (await asUser(OWNER, () => db.query(`select * from activity_log($1,current_date-1,current_date,null,null,null,'sign_in')`, [c9]))).rows;
  const covered = await one(`select count(*)::int n from audit_log where company_id=$1 and table_name in ('timesheets','training_requests','vehicles','user_channels')`, [c9]);
  const staffRead = await asUser(STAFF, () => err(() => db.query(`select * from activity_log($1,current_date-1,current_date)`, [c9])));
  ok(tgLog && tgLog.new_data.bot_token === '••••' && Number(si1.n) >= 1 && Number(si2.n) === 0 && areas.length >= 1 && areas[0].action === 'user.signed_in' && covered.n >= 3,
     'The activity log covers every area (timesheets, vehicles…), records each sign-in once, and never stores secrets such as the bot token');
  // Voiding entries made in error
  const tn = (await one(`insert into tenders (company_id,title,status) values ($1,'Wrong tender entered twice','registered') returning id`, [c9]))?.id;
  const noReason = await asUser(OWNER, () => err(() => db.query(`select void_entry('tenders',$1,'')`, [tn])));
  const staffVoid = await asUser(STAFF, () => err(() => db.query(`select void_entry('tenders',$1,'Duplicate')`, [tn])));
  await asUser(OWNER, () => db.query(`select void_entry('tenders',$1,'Entered twice')`, [tn]));
  const tv = await one(`select status, void_reason, voided_by from tenders where id=$1`, [tn]);
  const again = await asUser(OWNER, () => err(() => db.query(`select void_entry('tenders',$1,'x')`, [tn])));
  ok(/why/.test(noReason) && /cannot void/.test(staffVoid) && tv.status === 'voided' && tv.void_reason === 'Entered twice' && tv.voided_by === OWNER && /Already/.test(again)
     && (await one(`select count(*)::int n from audit_log where company_id=$1 and action='entry.voided'`, [c9])).n === 1,
     'A wrong tender is voided with a reason (kept on record and in the activity log); staff cannot void others\' entries');
  const ownX = (await one(`insert into expense_claims (company_id,employee_id,submitted_by,project_id,expense_date,description,currency,amount,exchange_rate,amount_home,account_id,status)
    values ($1,$2,$3,$4,current_date,'Typo: 1500 instead of 150','GHS',1500,1,1500,$5,'submitted') returning id`, [c9, yaw, STAFF, proj, acct])).id;
  await asUser(STAFF, () => db.query(`select void_entry('expense_claims',$1,'Wrong amount')`, [ownX]));
  const postedVoid = await asUser(OWNER, () => err(() => db.query(`select void_entry('expense_claims',$1,'x')`, [xc])));
  ok((await one(`select status from expense_claims where id=$1`, [ownX])).status === 'voided' && /cannot be voided/.test(postedVoid),
     'Staff can void their own submitted expense claim; an approved (posted) one cannot be voided');
  const leaveId = (await one(`insert into leave_requests (company_id,employee_id,leave_type,start_date,end_date,days) values ($1,$2,'annual',current_date+30,current_date+31,0) returning id`, [c9, yaw])).id;
  await asUser(OWNER, () => db.query(`select void_entry('leave_requests',$1,'Wrong dates')`, [leaveId]));
  ok((await one(`select status from leave_requests where id=$1`, [leaveId])).status === 'voided', 'Leave and other requests can be voided the same way');
  const je = (await one(`select post_journal($1,current_date,'Wrong accrual',$2::jsonb,'manual',null) id`, [c9, JSON.stringify([{ account_id: acct, debit: 500, credit: 0 }, { account_id: (await one(`select id from accounts where company_id=$1 and type='liability' limit 1`, [c9])).id, debit: 0, credit: 500 }])])).id;
  const rv = (await asUser(OWNER, () => one(`select reverse_journal($1,current_date,'Posted to the wrong account') id`, [je]))).id;
  const net = await one(`select sum(debit-credit)::numeric n from journal_lines where account_id=$1 and entry_id in ($2,$3)`, [acct, je, rv]);
  const twice = await asUser(OWNER, () => err(() => db.query(`select reverse_journal($1,current_date,'again')`, [je])));
  ok(Number(net.n) === 0 && /already been reversed/.test(twice), 'A manual journal posted in error is reversed by a mirror entry, once');
  const ov = await asUser(OWNER, () => one(`select channel_overview($1) j`, [c9]));
  ok(Number(ov.j.telegram_linked) === 1 && ov.j.people.length === 4, 'Owners see who has connected Telegram');
}

console.log(failures ? `\n${failures} check(s) failed` : '\nAll checks passed');
process.exit(failures ? 1 : 0);
