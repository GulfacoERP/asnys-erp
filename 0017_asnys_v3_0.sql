-- Asnys ERP v3.0 — HR and payroll to the level of dedicated HR suites (PaySpace and similar)
--   1. Pay components: any number of earnings (taxable or not) and deductions per employee, recurring or one-off.
--   2. Salary history with effective dates, bulk increases, and automatic back pay (arrears) for backdated changes.
--   3. Joiners and leavers paid pro rata; off-cycle (interim and final) pay runs, with PAYE worked out on the month's total.
--   4. Employee self-service: own payslips, year-to-date tax summary, profile change requests approved by HR.
--   5. Employment details: manager (org chart), employment type, probation, contract end, next of kin; history of
--      promotions, transfers, salary changes, warnings and awards; employee documents with expiry.
--   6. Onboarding and exit checklists; exits with final pay, leave due, assets and loans to clear, access removed.
--   7. Leave: Ghana public holidays, working days counted without weekends and holidays, monthly accrual, carry-over,
--      approval by the employee's manager or HR.
--   8. Announcements to all staff, a department or a branch.
--   9. HR reports (headcount, joiners and leavers, turnover, payroll cost, leave liability) and the annual PAYE return.
-- Run after 0016.

-- ---------------------------------------------------------------- 0. Accounts and helpers
create or replace function public.seed_accounts_v30(cid uuid) returns void
language sql security definer set search_path = public as $$
  insert into accounts (company_id, code, name, type, system_key) values
  (cid, '2260', 'Other payroll deductions payable', 'liability', 'payroll_deductions')
  on conflict do nothing;
$$;
select public.seed_accounts_v30(id) from public.companies;

-- People who may see pay and personal records.
create or replace function public.is_hr(cid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select has_role(cid, array['owner','admin','hr']);
$$;

-- ---------------------------------------------------------------- 1. Employment details
alter table public.employees add column if not exists manager_id uuid references public.employees(id) on delete set null;
alter table public.employees add column if not exists employment_type text not null default 'permanent'
  check (employment_type in ('permanent','fixed_term','casual','contract','intern','national_service','consultant'));
alter table public.employees add column if not exists grade text;
alter table public.employees add column if not exists probation_end date;
alter table public.employees add column if not exists confirmed_on date;
alter table public.employees add column if not exists contract_end date;
alter table public.employees add column if not exists notice_days int;
alter table public.employees add column if not exists end_date date;
alter table public.employees add column if not exists date_of_birth date;
alter table public.employees add column if not exists gender text check (gender in ('female','male','other'));
alter table public.employees add column if not exists address text;
alter table public.employees add column if not exists next_of_kin_name text;
alter table public.employees add column if not exists next_of_kin_relation text;
alter table public.employees add column if not exists next_of_kin_phone text;
alter table public.employees add column if not exists emergency_phone text;

create table public.employee_events (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  employee_id uuid not null references public.employees(id) on delete cascade,
  kind text not null check (kind in ('hired','confirmation','promotion','transfer','title_change','salary_change','warning','disciplinary',
    'grievance','award','training','exit','note')),
  effective_date date not null default current_date,
  title text not null,
  details text,
  old_value jsonb,
  new_value jsonb,
  confidential boolean not null default false,
  created_by uuid default auth.uid(),
  created_email text,
  created_at timestamptz not null default now()
);
create index on public.employee_events (employee_id, effective_date desc);

create or replace function public.employee_event_defaults() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.company_id := (select company_id from employees where id = new.employee_id);
  if coalesce(current_setting('sika.hr', true), '') <> 'on' and not is_hr(new.company_id) then raise exception 'Only HR can add to an employee''s history'; end if;
  new.created_email := (select email from auth.users where id = auth.uid());
  return new;
end $$;
create trigger employee_events_defaults before insert on public.employee_events for each row execute function public.employee_event_defaults();

-- Changes of title, department, branch, manager or type are written to the history automatically.
create or replace function public.employee_history_log() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_title text; v_kind text;
begin
  if tg_op = 'INSERT' then
    perform set_config('sika.hr', 'on', true);
    insert into employee_events (company_id, employee_id, kind, effective_date, title, new_value)
    values (new.company_id, new.id, 'hired', coalesce(new.hire_date, current_date), 'Joined as ' || coalesce(new.job_title, 'employee'),
      jsonb_build_object('job_title', new.job_title, 'department', new.department, 'basic_salary', new.basic_salary));
    perform set_config('sika.hr', 'off', true);
    return null;
  end if;
  if (new.job_title, new.department, new.branch_id, new.manager_id, new.employment_type, new.grade)
     is not distinct from (old.job_title, old.department, old.branch_id, old.manager_id, old.employment_type, old.grade) then return null; end if;
  v_kind := case when new.branch_id is distinct from old.branch_id or new.department is distinct from old.department then 'transfer'
                 when new.grade is distinct from old.grade or new.job_title is distinct from old.job_title then 'title_change' else 'note' end;
  v_title := concat_ws('; ',
    case when new.job_title is distinct from old.job_title then 'Title: ' || coalesce(old.job_title, '—') || ' → ' || coalesce(new.job_title, '—') end,
    case when new.grade is distinct from old.grade then 'Grade: ' || coalesce(old.grade, '—') || ' → ' || coalesce(new.grade, '—') end,
    case when new.department is distinct from old.department then 'Department: ' || coalesce(old.department, '—') || ' → ' || coalesce(new.department, '—') end,
    case when new.branch_id is distinct from old.branch_id then 'Branch changed' end,
    case when new.manager_id is distinct from old.manager_id then 'Reports to: ' || coalesce((select full_name from employees where id = new.manager_id), 'nobody') end,
    case when new.employment_type is distinct from old.employment_type then 'Type: ' || old.employment_type || ' → ' || new.employment_type end);
  perform set_config('sika.hr', 'on', true);
  insert into employee_events (company_id, employee_id, kind, title, old_value, new_value)
  values (new.company_id, new.id, v_kind, v_title,
    jsonb_build_object('job_title', old.job_title, 'department', old.department, 'grade', old.grade, 'manager_id', old.manager_id),
    jsonb_build_object('job_title', new.job_title, 'department', new.department, 'grade', new.grade, 'manager_id', new.manager_id));
  perform set_config('sika.hr', 'off', true);
  return null;
end $$;
create trigger employees_history after insert or update on public.employees for each row execute function public.employee_history_log();

-- Promotion: title, grade and pay together, with one history line.
create table public.employee_documents (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  employee_id uuid not null references public.employees(id) on delete cascade,
  kind text not null default 'other' check (kind in ('contract','offer_letter','id_card','certificate','cv','medical','warning_letter','appraisal','exit','other')),
  title text not null,
  storage_path text not null,
  file_name text,
  expires_on date,
  visible_to_employee boolean not null default true,
  uploaded_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);
create index on public.employee_documents (employee_id);

-- ---------------------------------------------------------------- 2. Pay components and salary history
create table public.pay_components (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  code text not null,
  name text not null,
  kind text not null check (kind in ('earning','deduction')),
  taxable boolean not null default true,       -- earnings only: counts towards PAYE
  account_id uuid references public.accounts(id),  -- deductions only: where the money is owed (default 2260)
  system boolean not null default false,
  active boolean not null default true,
  sort int not null default 100,
  unique (company_id, code)
);
create table public.employee_pay_items (           -- every month from start to end
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  employee_id uuid not null references public.employees(id) on delete cascade,
  component_id uuid not null references public.pay_components(id),
  amount numeric(14,2) not null check (amount > 0),
  start_period date not null default date_trunc('month', current_date)::date,
  end_period date,
  note text,
  created_at timestamptz not null default now()
);
create table public.payroll_input_items (          -- once, in one month (or in one off-cycle run)
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  period date not null,
  run_id uuid,
  employee_id uuid not null references public.employees(id) on delete cascade,
  component_id uuid not null references public.pay_components(id),
  amount numeric(14,2) not null check (amount > 0),
  note text,
  created_at timestamptz not null default now()
);
create table public.payslip_items (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  payslip_id uuid not null references public.payslips(id) on delete cascade,
  component_id uuid references public.pay_components(id),
  code text not null,
  name text not null,
  kind text not null check (kind in ('earning','deduction')),
  taxable boolean not null default true,
  amount numeric(14,2) not null
);
create index on public.payslip_items (payslip_id);
create table public.salary_changes (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  employee_id uuid not null references public.employees(id) on delete cascade,
  effective_date date not null,
  basic_salary numeric(14,2) not null check (basic_salary >= 0),
  allowances numeric(14,2) not null default 0 check (allowances >= 0),
  kind text not null default 'increase' check (kind in ('increase','promotion','adjustment','decrease','bulk')),
  reason text,
  arrears_run_id uuid,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);
create index on public.salary_changes (employee_id, effective_date);

alter table public.payslips add column if not exists earnings_other numeric(14,2) not null default 0;
alter table public.payslips add column if not exists nontaxable numeric(14,2) not null default 0;
alter table public.payslips add column if not exists deductions_other numeric(14,2) not null default 0;
alter table public.payslips add column if not exists backpay numeric(14,2) not null default 0;
alter table public.payslips add column if not exists days_paid numeric(5,2);
alter table public.payslips add column if not exists days_in_month int;

alter table public.payroll_runs add column if not exists kind text not null default 'regular' check (kind in ('regular','interim','final'));
alter table public.payroll_runs add column if not exists note text;
alter table public.payroll_runs drop constraint if exists payroll_runs_company_id_period_key;
create unique index if not exists payroll_runs_one_regular on public.payroll_runs (company_id, period) where kind = 'regular';

create or replace function public.seed_pay_components(cid uuid) returns void
language sql security definer set search_path = public as $$
  insert into pay_components (company_id, code, name, kind, taxable, system, sort) values
    (cid, 'HOUSING', 'Housing allowance', 'earning', true, false, 10),
    (cid, 'TRANSPORT', 'Transport allowance', 'earning', true, false, 11),
    (cid, 'FUEL', 'Fuel allowance', 'earning', true, false, 12),
    (cid, 'RESPONSIBILITY', 'Responsibility allowance', 'earning', true, false, 13),
    (cid, 'SITE', 'Site / risk allowance', 'earning', true, false, 14),
    (cid, 'ACTING', 'Acting allowance', 'earning', true, false, 15),
    (cid, 'COMMISSION', 'Commission', 'earning', true, false, 20),
    (cid, 'LEAVEPAY', 'Leave pay (days not taken)', 'earning', true, false, 21),
    (cid, 'PRORATA', 'Salary for part month', 'earning', true, false, 22),
    (cid, 'BONUS', 'Bonus', 'earning', true, true, 30),
    (cid, 'BACKPAY', 'Back pay (arrears)', 'earning', true, true, 31),
    (cid, 'REIMBURSE', 'Reimbursement (not taxed)', 'earning', false, false, 40),
    (cid, 'UNION', 'Union dues', 'deduction', false, false, 60),
    (cid, 'WELFARE', 'Staff welfare', 'deduction', false, false, 61),
    (cid, 'CREDITUNION', 'Credit union savings', 'deduction', false, false, 62),
    (cid, 'COURT', 'Court order / garnishee', 'deduction', false, false, 63),
    (cid, 'OTHERDED', 'Other deduction', 'deduction', false, false, 69)
  on conflict (company_id, code) do nothing;
$$;
select public.seed_pay_components(id) from public.companies;

create or replace function public.pay_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare cid uuid; v_period date;
begin
  cid := coalesce(new.company_id, old.company_id);
  if tg_op <> 'DELETE' and tg_table_name in ('payroll_input_items','employee_pay_items') then
    cid := (select company_id from employees where id = new.employee_id);
  end if;
  if coalesce(current_setting('sika.hr', true), '') = 'on' then return coalesce(new, old); end if;
  if not has_role(cid, array['owner','admin','hr','accountant']) then raise exception 'Only HR or Finance can change pay'; end if;
  if tg_table_name = 'payroll_input_items' then
    v_period := coalesce(new.period, old.period);
    if coalesce(new.run_id, old.run_id) is not null then
      if exists (select 1 from payroll_runs where id = coalesce(new.run_id, old.run_id) and status <> 'draft') then raise exception 'That pay run is already posted'; end if;
    elsif exists (select 1 from payroll_runs where company_id = cid and period = date_trunc('month', v_period) and kind = 'regular' and status <> 'draft') then
      raise exception 'Payroll for % is already posted. Add it to next month or to an off-cycle run.', to_char(v_period, 'Mon YYYY');
    end if;
    if tg_op <> 'DELETE' then new.period := date_trunc('month', new.period)::date; end if;
  elsif tg_table_name = 'employee_pay_items' and tg_op <> 'DELETE' then
    new.start_period := date_trunc('month', new.start_period)::date;
    if new.end_period is not null then new.end_period := date_trunc('month', new.end_period)::date; end if;
  end if;
  if tg_op <> 'DELETE' and tg_table_name in ('payroll_input_items','employee_pay_items') then
    new.company_id := (select company_id from employees where id = new.employee_id);
    if (select company_id from pay_components where id = new.component_id) is distinct from new.company_id then raise exception 'Choose one of your own pay components'; end if;
  end if;
  return coalesce(new, old);
end $$;
create trigger pay_components_guard before insert or update or delete on public.pay_components for each row execute function public.pay_guard();
create trigger employee_pay_items_guard before insert or update or delete on public.employee_pay_items for each row execute function public.pay_guard();
create trigger payroll_input_items_guard before insert or update or delete on public.payroll_input_items for each row execute function public.pay_guard();

-- Pay in force on a date: the latest salary change on or before it, otherwise the employee record.
create or replace function public.emp_pay_at(p_employee uuid, p_date date, out basic numeric, out allowances numeric)
language sql stable security definer set search_path = public as $$
  select coalesce(sc.basic_salary, e.basic_salary), coalesce(sc.allowances, e.allowances)
  from employees e left join lateral (select basic_salary, allowances from salary_changes s where s.employee_id = e.id and s.effective_date <= p_date
    order by s.effective_date desc, s.created_at desc limit 1) sc on true
  where e.id = p_employee;
$$;

-- Change pay from a date. Backdated changes are paid as back pay in the next regular payroll.
create or replace function public.change_salary(p_employee uuid, p_effective date, p_basic numeric, p_allowances numeric default null,
  p_reason text default null, p_kind text default 'increase', p_title text default null, p_grade text default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare e employees; v uuid; v_allow numeric;
begin
  select * into e from employees where id = p_employee for update;
  if not found then raise exception 'Employee not found'; end if;
  if not is_hr(e.company_id) then raise exception 'Only HR, an owner or admin can change pay'; end if;
  if p_basic is null or p_basic < 0 then raise exception 'Enter the new basic salary'; end if;
  v_allow := coalesce(p_allowances, (emp_pay_at(e.id, p_effective)).allowances, e.allowances);
  insert into salary_changes (company_id, employee_id, effective_date, basic_salary, allowances, kind, reason)
  values (e.company_id, e.id, p_effective, round(p_basic, 2), round(v_allow, 2), p_kind, p_reason) returning id into v;
  if p_effective <= current_date then
    update employees set basic_salary = round(p_basic, 2), allowances = round(v_allow, 2),
      job_title = coalesce(p_title, job_title), grade = coalesce(p_grade, grade) where id = e.id;
  elsif p_title is not null or p_grade is not null then
    update employees set job_title = coalesce(p_title, job_title), grade = coalesce(p_grade, grade) where id = e.id;
  end if;
  perform set_config('sika.hr', 'on', true);
  insert into employee_events (company_id, employee_id, kind, effective_date, title, details, old_value, new_value, confidential)
  values (e.company_id, e.id, case when p_kind = 'promotion' then 'promotion' else 'salary_change' end, p_effective,
    case when p_kind = 'promotion' then 'Promoted' || coalesce(' to ' || p_title, '') else 'Pay changed' end,
    p_reason, jsonb_build_object('basic_salary', e.basic_salary, 'allowances', e.allowances, 'job_title', e.job_title),
    jsonb_build_object('basic_salary', round(p_basic, 2), 'allowances', round(v_allow, 2), 'job_title', coalesce(p_title, e.job_title)), true);
  perform set_config('sika.hr', 'off', true);
  return v;
end $$;

-- Raise many people at once: by a percentage and/or a fixed amount, optionally for one department.
create or replace function public.bulk_salary_change(cid uuid, p_effective date, p_percent numeric, p_amount numeric default 0,
  p_department text default null, p_reason text default null) returns int
language plpgsql security definer set search_path = public as $$
declare e record; n int := 0; cur record;
begin
  if not is_hr(cid) then raise exception 'Only HR, an owner or admin can change pay'; end if;
  if coalesce(p_percent, 0) = 0 and coalesce(p_amount, 0) = 0 then raise exception 'Enter a percentage or an amount'; end if;
  for e in select * from employees where company_id = cid and status = 'active' and (p_department is null or department = p_department) loop
    select * into cur from emp_pay_at(e.id, p_effective);
    perform change_salary(e.id, p_effective, round(cur.basic * (1 + coalesce(p_percent, 0) / 100.0) + coalesce(p_amount, 0), 2), cur.allowances,
      coalesce(p_reason, 'General increase'), 'bulk');
    n := n + 1;
  end loop;
  return n;
end $$;

-- ---------------------------------------------------------------- 3. Payroll calculation (regular and off-cycle runs)
create or replace function public.calc_run(p_run uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  r payroll_runs; cid uuid; v_period date; v_payday date; v_dim int; e record; pay record;
  v_days numeric; v_f numeric; v_basic numeric; v_allow numeric; v_ot numeric; v_bonus numeric;
  v_earn numeric; v_earn_tax numeric; v_earn_nontax numeric; v_ded numeric; v_back numeric; v_back_basic numeric;
  v_gross numeric; v_emp numeric; v_er numeric; v_t2 numeric; v_t3e numeric; v_t3r numeric; v_ot_tax numeric; v_ot_taxable numeric; v_ot_low numeric;
  v_ytd numeric; v_cap_left numeric; v_b_conc numeric; v_bonus_tax numeric; v_bonus_taxable numeric;
  v_relief_cap numeric; v_t3_relief numeric; v_t3_excess numeric; v_charge numeric; v_paye numeric; v_prior_charge numeric; v_prior_paye numeric;
  v_before numeric; v_loan numeric; v_net numeric; v_slip uuid; it record; v_start date; v_end date;
begin
  select * into r from payroll_runs where id = p_run;
  cid := r.company_id; v_period := r.period;
  v_payday := (v_period + interval '1 month - 1 day')::date;
  v_dim := extract(day from v_payday)::int;
  delete from payslips where run_id = p_run;

  for e in
    select * from employees x where x.company_id = cid and (
      (r.kind = 'regular' and coalesce(x.hire_date, v_period) <= v_payday
         and (x.status = 'active' or (x.end_date is not null and x.end_date >= v_period)) and (x.end_date is null or x.end_date >= v_period))
      or (r.kind <> 'regular' and exists (select 1 from payroll_input_items i where i.run_id = p_run and i.employee_id = x.id)))
    order by x.full_name
  loop
    -- Days paid: joiners and leavers in the month are paid pro rata to calendar days.
    v_start := greatest(v_period, coalesce(e.hire_date, v_period)); v_end := least(v_payday, coalesce(e.end_date, v_payday));
    v_days := case when r.kind = 'regular' then greatest(0, v_end - v_start + 1) else 0 end;
    v_f := case when r.kind = 'regular' then v_days / v_dim else 0 end;
    select * into pay from emp_pay_at(e.id, v_payday);
    v_basic := round(pay.basic * v_f, 2); v_allow := round(pay.allowances * v_f, 2);

    insert into payslips (run_id, company_id, employee_id, basic, allowances, gross, ssnit_employee, chargeable, paye, net, ssnit_employer, tier1, tier2,
      days_paid, days_in_month)
    values (p_run, cid, e.id, v_basic, v_allow, 0, 0, 0, 0, 0, 0, 0, 0, case when r.kind = 'regular' then v_days end, case when r.kind = 'regular' then v_dim end)
    returning id into v_slip;

    -- Recurring items (pro rata) and one-off items.
    if r.kind = 'regular' then
      insert into payslip_items (company_id, payslip_id, component_id, code, name, kind, taxable, amount)
      select cid, v_slip, c.id, c.code, c.name, c.kind, c.taxable, round(sum(p.amount) * case when c.kind = 'earning' then v_f else 1 end, 2)
      from employee_pay_items p join pay_components c on c.id = p.component_id
      where p.employee_id = e.id and p.start_period <= v_period and (p.end_period is null or p.end_period >= v_period) and c.active
      group by c.id, c.code, c.name, c.kind, c.taxable having sum(p.amount) > 0;
      insert into payslip_items (company_id, payslip_id, component_id, code, name, kind, taxable, amount)
      select cid, v_slip, c.id, c.code, c.name, c.kind, c.taxable, sum(i.amount)
      from payroll_input_items i join pay_components c on c.id = i.component_id
      where i.employee_id = e.id and i.period = v_period and i.run_id is null group by c.id, c.code, c.name, c.kind, c.taxable;
    else
      insert into payslip_items (company_id, payslip_id, component_id, code, name, kind, taxable, amount)
      select cid, v_slip, c.id, c.code, c.name, c.kind, c.taxable, sum(i.amount)
      from payroll_input_items i join pay_components c on c.id = i.component_id
      where i.employee_id = e.id and i.run_id = p_run group by c.id, c.code, c.name, c.kind, c.taxable;
    end if;
    delete from payslip_items where payslip_id = v_slip and amount <= 0;

    -- Back pay: the difference between the pay now in force for each month already posted and what was paid.
    v_back := 0; v_back_basic := 0;
    if r.kind = 'regular' and exists (select 1 from salary_changes sc where sc.employee_id = e.id and sc.arrears_run_id is null and sc.effective_date < v_period) then
      select coalesce(sum(greatest(0, round((emp_pay_at(e.id, (pr.period + interval '1 month - 1 day')::date)).basic * coalesce(ps.days_paid, 1) / coalesce(ps.days_in_month, 1), 2) - ps.basic)), 0),
             coalesce(sum(greatest(0, round((emp_pay_at(e.id, (pr.period + interval '1 month - 1 day')::date)).allowances * coalesce(ps.days_paid, 1) / coalesce(ps.days_in_month, 1), 2) - ps.allowances)), 0)
        into v_back_basic, v_back
      from payslips ps join payroll_runs pr on pr.id = ps.run_id
      where ps.employee_id = e.id and pr.kind = 'regular' and pr.status <> 'draft' and pr.period < v_period
        and pr.period >= (select date_trunc('month', min(sc.effective_date)) from salary_changes sc where sc.employee_id = e.id and sc.arrears_run_id is null);
      v_back := v_back + v_back_basic;
      if v_back > 0 then
        insert into payslip_items (company_id, payslip_id, component_id, code, name, kind, taxable, amount)
        select cid, v_slip, c.id, 'BACKPAY', c.name, 'earning', true, v_back from pay_components c where c.company_id = cid and c.code = 'BACKPAY';
      end if;
    end if;

    select coalesce(max(overtime), 0), coalesce(max(bonus), 0) into v_ot, v_bonus
      from payroll_inputs where company_id = cid and period = v_period and employee_id = e.id and r.kind = 'regular';
    v_bonus := v_bonus + coalesce((select sum(amount) from payslip_items where payslip_id = v_slip and code = 'BONUS'), 0);
    select coalesce(sum(amount) filter (where kind = 'earning' and code not in ('BONUS','BACKPAY')), 0),
           coalesce(sum(amount) filter (where kind = 'earning' and taxable and code not in ('BONUS','BACKPAY')), 0),
           coalesce(sum(amount) filter (where kind = 'earning' and not taxable), 0),
           coalesce(sum(amount) filter (where kind = 'deduction'), 0)
      into v_earn, v_earn_tax, v_earn_nontax, v_ded from payslip_items where payslip_id = v_slip;

    v_gross := v_basic + v_allow + v_ot + v_bonus + v_earn + v_back;
    -- SSNIT is on basic salary (including basic arrears).
    v_emp := round((v_basic + v_back_basic) * stat_rate('SSNIT_EMPLOYEE', v_payday), 2);
    v_er := round((v_basic + v_back_basic) * stat_rate('SSNIT_EMPLOYER', v_payday), 2);
    v_t2 := round((v_basic + v_back_basic) * stat_rate('TIER2', v_payday), 2);
    v_t3e := round(v_basic * e.tier3_employee_rate, 2);
    v_t3r := round(v_basic * e.tier3_employer_rate, 2);

    if v_ot > 0 and e.is_junior and (pay.basic + pay.allowances) * 12 <= stat_rate('OVERTIME_INCOME_LIMIT', v_payday) then
      v_ot_low := least(v_ot, 0.5 * pay.basic);
      v_ot_tax := round(v_ot_low * stat_rate('OVERTIME_LOW', v_payday) + (v_ot - v_ot_low) * stat_rate('OVERTIME_HIGH', v_payday), 2);
      v_ot_taxable := 0;
    else v_ot_tax := 0; v_ot_taxable := v_ot; end if;

    select coalesce(sum(s.bonus), 0) into v_ytd from payslips s join payroll_runs pr on pr.id = s.run_id
     where pr.company_id = cid and s.employee_id = e.id and pr.id <> p_run and extract(year from pr.period) = extract(year from v_period);
    v_cap_left := greatest(0, stat_rate('BONUS_CAP', v_payday) * pay.basic * 12 - v_ytd);
    v_b_conc := least(v_bonus, v_cap_left);
    v_bonus_tax := round(v_b_conc * stat_rate('BONUS_RATE', v_payday), 2);
    v_bonus_taxable := v_bonus - v_b_conc;

    v_relief_cap := round(stat_rate('TIER3_RELIEF', v_payday) * (v_basic + v_allow + v_earn_tax), 2);
    v_t3_relief := least(v_t3e, greatest(0, v_relief_cap - v_t3r));
    v_t3_excess := greatest(0, v_t3r - v_relief_cap);

    v_charge := v_basic + v_allow + v_earn_tax + v_back + v_ot_taxable + v_bonus_taxable + v_t3_excess - v_emp - v_t3_relief;
    -- PAYE is on the month's total: other posted runs this month are counted, and the tax already taken is deducted.
    select coalesce(sum(s.chargeable), 0), coalesce(sum(s.paye), 0) into v_prior_charge, v_prior_paye
      from payslips s join payroll_runs pr on pr.id = s.run_id
     where s.employee_id = e.id and pr.company_id = cid and pr.period = v_period and pr.id <> p_run and pr.status <> 'draft';
    v_paye := greatest(0, compute_paye(greatest(0, v_prior_charge + v_charge), v_payday) - v_prior_paye);

    v_before := v_gross - v_emp - v_t3e - v_paye - v_ot_tax - v_bonus_tax - v_ded;
    select coalesce(sum(least(installment, balance)), 0) into v_loan from employee_loans
     where employee_id = e.id and status = 'active' and issue_date <= v_payday and r.kind <> 'interim';
    v_loan := least(greatest(v_before, 0), v_loan);
    v_net := v_before - v_loan;

    update payslips set gross = v_gross, ssnit_employee = v_emp, chargeable = v_charge, paye = v_paye, net = v_net, ssnit_employer = v_er,
      tier1 = v_emp + v_er - v_t2, tier2 = v_t2, overtime = v_ot, bonus = v_bonus, overtime_tax = v_ot_tax, bonus_tax = v_bonus_tax,
      tier3_employee = v_t3e, tier3_employer = v_t3r, loan_deduction = v_loan,
      earnings_other = v_earn, nontaxable = v_earn_nontax, deductions_other = v_ded, backpay = v_back
    where id = v_slip;
  end loop;

  update payroll_runs x set gross = coalesce(s.gross, 0), paye = coalesce(s.tax, 0), ssnit_employee = coalesce(s.emp, 0),
    ssnit_employer = coalesce(s.er, 0), net = coalesce(s.net, 0)
  from (select sum(gross) gross, sum(paye + overtime_tax + bonus_tax) tax, sum(ssnit_employee) emp, sum(ssnit_employer) er, sum(net) net
          from payslips where run_id = p_run) s
  where x.id = p_run;
end $$;
revoke execute on function public.calc_run(uuid) from public, anon, authenticated;

create or replace function public.prepare_payroll(cid uuid, p_period date)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_run uuid; v_period date := date_trunc('month', p_period)::date; v_status text;
begin
  perform require_member(cid, array['owner','admin','hr','accountant']);
  select id, status into v_run, v_status from payroll_runs where company_id = cid and period = v_period and kind = 'regular';
  if v_run is not null and v_status <> 'draft' then raise exception 'Payroll for this month is already posted'; end if;
  if v_run is null then insert into payroll_runs (company_id, period, kind) values (cid, v_period, 'regular') returning id into v_run; end if;
  perform calc_run(v_run);
  return v_run;
end $$;

-- An off-cycle run (bonus, commission, final pay) holds only the items added to it.
create or replace function public.create_offcycle_run(cid uuid, p_period date, p_kind text, p_note text default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  perform require_member(cid, array['owner','admin','hr','accountant']);
  if p_kind not in ('interim','final') then raise exception 'Choose interim or final'; end if;
  insert into payroll_runs (company_id, period, kind, note) values (cid, date_trunc('month', p_period)::date, p_kind, p_note) returning id into v;
  return v;
end $$;
create or replace function public.recalc_run(p_run uuid) returns void
language plpgsql security definer set search_path = public as $$
declare r payroll_runs;
begin
  select * into r from payroll_runs where id = p_run;
  if not found then raise exception 'Pay run not found'; end if;
  perform require_member(r.company_id, array['owner','admin','hr','accountant']);
  if r.status <> 'draft' then raise exception 'This pay run is already posted'; end if;
  perform calc_run(p_run);
end $$;

-- Posting: as before, plus other deductions owed to their accounts, back pay settled, off-cycle labels.
create or replace function public.post_payroll(p_run uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  r payroll_runs; v_t1 numeric; v_t2 numeric; v_t3e numeric; v_t3r numeric; v_loans numeric;
  v_je uuid; v_date date; s record; ln record; v_left numeric; v_take numeric; v_lines jsonb := '[]'::jsonb; g record;
begin
  select * into r from payroll_runs where id = p_run for update;
  if not found then raise exception 'Payroll run not found'; end if;
  perform require_member(r.company_id, array['owner','admin','accountant']);
  if r.status <> 'draft' then raise exception 'This payroll is already posted'; end if;
  if r.gross = 0 then raise exception 'There are no payslips in this run'; end if;
  select sum(tier1), sum(tier2), sum(tier3_employee), sum(tier3_employer), sum(loan_deduction)
    into v_t1, v_t2, v_t3e, v_t3r, v_loans from payslips where run_id = p_run;
  v_date := case when r.kind = 'regular' then (r.period + interval '1 month - 1 day')::date else least(current_date, (r.period + interval '1 month - 1 day')::date) end;
  for g in select e.branch_id, e.cost_centre_id, sum(ps.gross) gross, sum(ps.ssnit_employer) er, sum(ps.tier3_employer) t3
             from payslips ps join employees e on e.id = ps.employee_id where ps.run_id = p_run group by 1, 2 loop
    v_lines := v_lines
      || (jl(acct(r.company_id,'salaries'), g.gross, 0) || jsonb_build_object('branch_id', g.branch_id, 'cost_centre_id', g.cost_centre_id))
      || (jl(acct(r.company_id,'employer_ssnit'), g.er, 0) || jsonb_build_object('branch_id', g.branch_id, 'cost_centre_id', g.cost_centre_id))
      || (jl(acct(r.company_id,'employer_tier3'), g.t3, 0) || jsonb_build_object('branch_id', g.branch_id, 'cost_centre_id', g.cost_centre_id));
  end loop;
  for g in select coalesce(c.account_id, acct(r.company_id, 'payroll_deductions')) acc, sum(i.amount) amt
             from payslip_items i join payslips ps on ps.id = i.payslip_id left join pay_components c on c.id = i.component_id
            where ps.run_id = p_run and i.kind = 'deduction' group by 1 loop
    v_lines := v_lines || jsonb_build_array(jl(g.acc, 0, g.amt));
  end loop;
  v_je := post_journal(r.company_id, v_date, 'Payroll ' || to_char(r.period, 'Mon YYYY') || case r.kind when 'interim' then ' (off-cycle)' when 'final' then ' (final pay)' else '' end,
    v_lines || jsonb_build_array(
      jl(acct(r.company_id,'paye'), 0, r.paye),
      jl(acct(r.company_id,'ssnit1'), 0, v_t1),
      jl(acct(r.company_id,'tier2'), 0, v_t2),
      jl(acct(r.company_id,'tier3'), 0, v_t3e + v_t3r),
      jl(acct(r.company_id,'staff_loans'), 0, v_loans),
      jl(acct(r.company_id,'net_pay'), 0, r.net)),
    'payroll', r.id);

  for s in select * from payslips where run_id = p_run and loan_deduction > 0 loop
    v_left := s.loan_deduction;
    for ln in select * from employee_loans where employee_id = s.employee_id and status = 'active' order by issue_date, created_at for update loop
      exit when v_left <= 0;
      v_take := least(v_left, ln.installment, ln.balance);
      update employee_loans set balance = balance - v_take, status = case when balance - v_take <= 0 then 'settled' else 'active' end where id = ln.id;
      insert into loan_repayments (company_id, loan_id, run_id, repay_date, amount) values (r.company_id, ln.id, p_run, v_date, v_take);
      v_left := v_left - v_take;
    end loop;
  end loop;
  if r.kind = 'regular' then
    update salary_changes sc set arrears_run_id = p_run
     where sc.arrears_run_id is null and sc.effective_date < r.period
       and sc.employee_id in (select employee_id from payslips where run_id = p_run);
  end if;
  update payroll_runs set status = 'posted', journal_entry_id = v_je where id = p_run;
end $$;

-- ---------------------------------------------------------------- 4. Self-service

-- Own payslips (posted runs only), with their items.
create or replace function public.my_payslips(p_year int default null, p_company uuid default null) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('slip', to_jsonb(s) - 'company_id', 'period', r.period, 'kind', r.kind, 'status', r.status,
      'company', jsonb_build_object('id', c.id, 'name', c.name, 'tin', c.tin, 'city', c.city, 'phone', c.phone, 'email', c.email),
      'employee', jsonb_build_object('full_name', e.full_name, 'staff_no', e.staff_no, 'job_title', e.job_title, 'department', e.department,
        'tin', e.tin, 'ssnit_no', e.ssnit_no, 'ghana_card', e.ghana_card, 'bank_name', e.bank_name, 'bank_account', e.bank_account),
      'items', coalesce((select jsonb_agg(jsonb_build_object('code', i.code, 'name', i.name, 'kind', i.kind, 'taxable', i.taxable, 'amount', i.amount) order by i.kind, i.name)
        from payslip_items i where i.payslip_id = s.id), '[]'::jsonb)) order by r.period desc, r.created_at desc), '[]'::jsonb)
  from payslips s join payroll_runs r on r.id = s.run_id join employees e on e.id = s.employee_id join companies c on c.id = r.company_id
  where e.user_id = auth.uid() and r.status in ('posted','paid') and (p_year is null or extract(year from r.period) = p_year) and (p_company is null or r.company_id = p_company);
$$;

-- Payslip items for HR and Finance (and the employee, through my_payslips).
create or replace function public.payslip_items_for_run(p_run uuid) returns setof payslip_items
language sql stable security definer set search_path = public as $$
  select i.* from payslip_items i join payslips s on s.id = i.payslip_id join payroll_runs r on r.id = s.run_id
  where s.run_id = p_run and has_role(r.company_id, array['owner','admin','hr','accountant']);
$$;

create table public.employee_change_requests (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  employee_id uuid not null references public.employees(id) on delete cascade,
  changes jsonb not null,
  note text,
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  decided_by uuid, decided_at timestamptz, decision_note text,
  created_at timestamptz not null default now()
);

-- Own record, documents shared with them, history (not confidential lines), manager.
create or replace function public.my_profile(p_company uuid default null) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'employee', to_jsonb(e) - 'basic_salary' - 'allowances' - 'cost_rate' - 'tier3_employee_rate' - 'tier3_employer_rate',
    'pay', jsonb_build_object('basic_salary', e.basic_salary, 'allowances', e.allowances),
    'manager', (select jsonb_build_object('full_name', m.full_name, 'job_title', m.job_title) from employees m where m.id = e.manager_id),
    'documents', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'title', d.title, 'kind', d.kind, 'storage_path', d.storage_path, 'expires_on', d.expires_on) order by d.created_at desc)
      from employee_documents d where d.employee_id = e.id and d.visible_to_employee), '[]'::jsonb),
    'history', coalesce((select jsonb_agg(jsonb_build_object('kind', h.kind, 'effective_date', h.effective_date, 'title', h.title) order by h.effective_date desc)
      from employee_events h where h.employee_id = e.id and not h.confidential), '[]'::jsonb),
    'requests', coalesce((select jsonb_agg(to_jsonb(q) order by q.created_at desc) from employee_change_requests q where q.employee_id = e.id), '[]'::jsonb))
  from employees e where e.user_id = auth.uid() and (p_company is null or e.company_id = p_company) order by e.created_at limit 1;
$$;


-- Staff ask to update their own contact, bank and next-of-kin details; HR approves.
create or replace function public.request_profile_change(p_changes jsonb, p_note text default null, p_company uuid default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare e employees; v uuid; k text; allowed text[] := array['phone','email','address','bank_name','bank_branch','bank_account','momo_number','pay_method',
  'next_of_kin_name','next_of_kin_relation','next_of_kin_phone','emergency_phone','tin','ssnit_no','ghana_card'];
begin
  select * into e from employees where user_id = auth.uid() and (p_company is null or company_id = p_company) order by created_at limit 1;
  if not found then raise exception 'Your login is not linked to an employee record. Ask HR.'; end if;
  for k in select jsonb_object_keys(p_changes) loop
    if not k = any(allowed) then raise exception 'You cannot change % yourself. Ask HR.', k; end if;
  end loop;
  insert into employee_change_requests (company_id, employee_id, changes, note) values (e.company_id, e.id, p_changes, p_note) returning id into v;
  perform notify(e.company_id, array['hr'], null, 'hr_profile_change', e.full_name || ' asked to update their details', null, '/employees', false);
  return v;
end $$;

create or replace function public.decide_profile_change(p_id uuid, p_approve boolean, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
declare q employee_change_requests; k text; v text;
begin
  select * into q from employee_change_requests where id = p_id for update;
  if not found then raise exception 'Not found'; end if;
  if not is_hr(q.company_id) then raise exception 'Only HR can approve this'; end if;
  if q.status <> 'pending' then raise exception 'Already decided'; end if;
  if p_approve then
    for k, v in select key, value from jsonb_each_text(q.changes) loop
      execute format('update public.employees set %I = $1 where id = $2', k) using nullif(v, ''), q.employee_id;
    end loop;
  end if;
  update employee_change_requests set status = case when p_approve then 'approved' else 'rejected' end, decided_by = auth.uid(), decided_at = now(), decision_note = p_note where id = p_id;
  perform notify_users(q.company_id, array[(select user_id from employees where id = q.employee_id)], 'hr_profile_decided',
    'Your details update was ' || case when p_approve then 'approved' else 'not approved' end, p_note, '/my/profile', false);
end $$;

-- Staff directory for everyone (no pay or personal data): names, titles, departments, managers, work contacts.
create or replace function public.staff_directory(cid uuid) returns table (id uuid, full_name text, job_title text, department text, branch text,
  manager_id uuid, email text, phone text, has_login boolean, location text)
language sql stable security definer set search_path = public as $$
  select e.id, e.full_name, e.job_title, e.department, b.name, e.manager_id, e.email, e.phone, e.user_id is not null, e.location
  from employees e left join branches b on b.id = e.branch_id
  where e.company_id = cid and e.status = 'active' and is_member(cid) order by e.full_name;
$$;

-- ---------------------------------------------------------------- 5. Onboarding and exit
create table public.hr_checklists (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  kind text not null check (kind in ('onboarding','offboarding')),
  name text not null,
  items jsonb not null default '[]'::jsonb,   -- [{"task":"…","owner":"hr|manager|it|finance|store|hse|employee","days":0}]
  active boolean not null default true
);
create table public.employee_tasks (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  employee_id uuid not null references public.employees(id) on delete cascade,
  kind text not null check (kind in ('onboarding','offboarding')),
  task text not null,
  owner text not null default 'hr',
  due_date date,
  status text not null default 'open' check (status in ('open','done','na')),
  done_by uuid, done_at timestamptz, note text,
  sort int not null default 0
);
create index on public.employee_tasks (employee_id, kind);

create or replace function public.seed_hr_checklists(cid uuid) returns void
language sql security definer set search_path = public as $$
  insert into hr_checklists (company_id, kind, name, items)
  select cid, x.kind, x.name, x.items::jsonb from (values
    ('onboarding', 'New employee', '[{"task":"Signed offer letter and employment contract on file","owner":"hr","days":-3},{"task":"Ghana Card, SSNIT number, TIN and bank or MoMo details recorded","owner":"hr","days":0},{"task":"Registered with SSNIT and the Tier 2 trustee","owner":"hr","days":7},{"task":"Login created and invitation sent","owner":"it","days":0},{"task":"Email address and phone line set up","owner":"it","days":0},{"task":"Laptop, tools and PPE issued (record in Assets)","owner":"store","days":0},{"task":"Company induction: policies, safety, emergency procedures","owner":"hse","days":1},{"task":"Policies read and acknowledged","owner":"employee","days":5},{"task":"Introduced to the team; job description explained","owner":"manager","days":1},{"task":"Objectives for probation agreed","owner":"manager","days":14},{"task":"Added to payroll from the start date","owner":"finance","days":0}]'),
    ('offboarding', 'Leaving employee', '[{"task":"Resignation or termination letter on file","owner":"hr","days":0},{"task":"Handover of work agreed with the manager","owner":"manager","days":0},{"task":"Laptop, tools, PPE, ID card and keys returned (check Assets)","owner":"store","days":0},{"task":"Cash advances retired and staff loans settled or deducted","owner":"finance","days":0},{"task":"Leave days due worked out and added to final pay","owner":"hr","days":0},{"task":"Final pay calculated and approved","owner":"finance","days":0},{"task":"Exit interview held","owner":"hr","days":0},{"task":"Email and system access removed","owner":"it","days":0},{"task":"Certificate of service issued","owner":"hr","days":7},{"task":"SSNIT and Tier 2 trustee informed","owner":"hr","days":14}]')
  ) as x(kind, name, items)
  where not exists (select 1 from hr_checklists h where h.company_id = cid);
$$;
select public.seed_hr_checklists(id) from public.companies;

create or replace function public.start_hr_checklist(p_employee uuid, p_kind text, p_checklist uuid default null, p_from date default null) returns int
language plpgsql security definer set search_path = public as $$
declare e employees; c hr_checklists; n int := 0; it jsonb; v_base date;
begin
  select * into e from employees where id = p_employee;
  if not is_hr(e.company_id) then raise exception 'Only HR can start a checklist'; end if;
  select * into c from hr_checklists where (id = p_checklist or (p_checklist is null and company_id = e.company_id and kind = p_kind and active)) order by name limit 1;
  if not found then raise exception 'Set up a % checklist first', p_kind; end if;
  v_base := coalesce(p_from, case when p_kind = 'onboarding' then e.hire_date else e.end_date end, current_date);
  for it in select value from jsonb_array_elements(c.items) loop
    n := n + 1;
    insert into employee_tasks (company_id, employee_id, kind, task, owner, due_date, sort)
    values (e.company_id, e.id, c.kind, it->>'task', coalesce(it->>'owner', 'hr'), v_base + coalesce((it->>'days')::int, 0), n);
  end loop;
  return n;
end $$;

create or replace function public.hr_task_step(p_id uuid, p_status text, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
declare t employee_tasks; v_mgr uuid;
begin
  select * into t from employee_tasks where id = p_id for update;
  select m.user_id into v_mgr from employees e join employees m on m.id = e.manager_id where e.id = t.employee_id;
  if not (is_hr(t.company_id) or (t.owner = 'finance' and has_role(t.company_id, array['accountant'])) or (t.owner = 'store' and has_role(t.company_id, array['store']))
          or (t.owner = 'hse' and is_hse(t.company_id)) or (t.owner = 'manager' and v_mgr = auth.uid())
          or (t.owner = 'employee' and exists (select 1 from employees where id = t.employee_id and user_id = auth.uid()))) then
    raise exception 'This task is for % to complete', t.owner;
  end if;
  if p_status not in ('open','done','na') then raise exception 'Unknown status'; end if;
  update employee_tasks set status = p_status, done_by = case when p_status = 'open' then null else auth.uid() end,
    done_at = case when p_status = 'open' then null else now() end, note = coalesce(p_note, note) where id = p_id;
end $$;

create table public.employee_exits (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  employee_id uuid not null references public.employees(id) on delete cascade,
  reason text not null check (reason in ('resignation','end_of_contract','dismissal','redundancy','retirement','death','mutual','other')),
  notice_date date not null default current_date,
  last_day date not null,
  eligible_rehire boolean,
  interview_notes text,
  leave_days_due numeric(6,2),
  status text not null default 'in_progress' check (status in ('in_progress','completed','cancelled')),
  completed_at timestamptz, completed_by uuid,
  created_at timestamptz not null default now()
);

create or replace function public.start_exit(p_employee uuid, p_reason text, p_notice date, p_last_day date, p_note text default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare e employees; v uuid; v_leave numeric;
begin
  select * into e from employees where id = p_employee for update;
  if not is_hr(e.company_id) then raise exception 'Only HR can start an exit'; end if;
  if exists (select 1 from employee_exits where employee_id = p_employee and status = 'in_progress') then raise exception 'An exit is already in progress'; end if;
  if p_last_day < p_notice then raise exception 'The last day cannot be before the notice date'; end if;
  select coalesce(sum(remaining), 0) into v_leave from leave_balances(e.company_id, extract(year from p_last_day)::int) b
   where b.employee_id = e.id and b.leave_code = 'annual';
  insert into employee_exits (company_id, employee_id, reason, notice_date, last_day, leave_days_due, interview_notes)
  values (e.company_id, e.id, p_reason, p_notice, p_last_day, greatest(v_leave, 0), p_note) returning id into v;
  update employees set end_date = p_last_day where id = e.id;
  perform start_hr_checklist(e.id, 'offboarding', null, p_last_day);
  perform set_config('sika.hr', 'on', true);
  insert into employee_events (company_id, employee_id, kind, effective_date, title, details)
  values (e.company_id, e.id, 'exit', p_last_day, 'Leaving: ' || replace(p_reason, '_', ' '), p_note);
  perform set_config('sika.hr', 'off', true);
  perform notify(e.company_id, array['hr','accountant','store'], null, 'hr_exit', e.full_name || ' is leaving on ' || to_char(p_last_day, 'DD Mon YYYY'),
    'Clear assets, advances and loans, and prepare final pay.', '/employees/' || e.id, false);
  return v;
end $$;

-- What must be cleared before someone leaves.
create or replace function public.exit_clearance(p_employee uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'assets', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'tag', a.tag, 'name', a.name)) from assets a where a.custodian_id = e.id and a.status = 'active'), '[]'::jsonb),
    'loans', coalesce((select sum(balance) from employee_loans where employee_id = e.id and status = 'active'), 0),
    'advances', coalesce((select sum(amount) from cash_advances where employee_id = e.id and status in ('open','submitted')), 0),
    'tasks_open', (select count(*) from employee_tasks where employee_id = e.id and kind = 'offboarding' and status = 'open'),
    'daily_rate', round(e.basic_salary / 22.0, 2))
  from employees e where e.id = p_employee and is_hr(e.company_id);
$$;

create or replace function public.complete_exit(p_exit uuid, p_force boolean default false) returns void
language plpgsql security definer set search_path = public as $$
declare x employee_exits; e employees; v_open int;
begin
  select * into x from employee_exits where id = p_exit for update;
  if not is_hr(x.company_id) then raise exception 'Only HR can complete an exit'; end if;
  if x.status <> 'in_progress' then raise exception 'This exit is not in progress'; end if;
  select count(*) into v_open from employee_tasks where employee_id = x.employee_id and kind = 'offboarding' and status = 'open';
  if v_open > 0 and not p_force then raise exception '% exit task% still open', v_open, case when v_open = 1 then ' is' else 's are' end; end if;
  select * into e from employees where id = x.employee_id for update;
  update employees set status = 'inactive', end_date = x.last_day where id = e.id;
  if e.user_id is not null then delete from memberships where company_id = e.company_id and user_id = e.user_id and role <> 'owner'; end if;
  update employee_exits set status = 'completed', completed_at = now(), completed_by = auth.uid() where id = p_exit;
end $$;

-- ---------------------------------------------------------------- 6. Leave: holidays, working days, accrual, manager approval
create table public.public_holidays (
  company_id uuid not null references public.companies(id) on delete cascade,
  holiday date not null,
  name text not null,
  primary key (company_id, holiday)
);
alter table public.leave_types add column if not exists accrual text not null default 'upfront' check (accrual in ('upfront','monthly'));
alter table public.leave_types add column if not exists carry_over_max numeric(5,1) not null default 0;
alter table public.leave_types add column if not exists counts text not null default 'working' check (counts in ('working','calendar'));
alter table public.leave_requests add column if not exists decided_by uuid;
alter table public.leave_requests add column if not exists decided_at timestamptz;
alter table public.leave_requests add column if not exists decision_note text;
alter table public.leave_requests add column if not exists half_day boolean not null default false;

-- Easter Sunday (Gregorian, anonymous algorithm).
create or replace function public.easter_sunday(y int) returns date language plpgsql immutable as $$
declare a int; b int; c int; d int; e int; f int; g int; h int; i int; k int; l int; m int;
begin
  a := y % 19; b := y / 100; c := y % 100; d := b / 4; e := b % 4; f := (b + 8) / 25; g := (b - f + 1) / 3;
  h := (19 * a + b - d - g + 15) % 30; i := c / 4; k := c % 4; l := (32 + 2 * e + 2 * i - h - k) % 7; m := (a + 11 * h + 22 * l) / 451;
  return make_date(y, (h + l - 7 * m + 114) / 31, ((h + l - 7 * m + 114) % 31) + 1);
end $$;

-- Ghana public holidays under the Public Holidays and Commemorative Days Act as amended in 2025. Eid al-Fitr, Shaqq Day
-- and Eid al-Adha follow the moon and are announced each year: add them when the dates are declared.
create or replace function public.seed_ghana_holidays_internal(cid uuid, y int) returns int
language plpgsql security definer set search_path = public as $$
declare n int; v_dec1 date := make_date(y, 12, 1);
begin
  insert into public_holidays (company_id, holiday, name) values
    (cid, make_date(y, 1, 1), 'New Year''s Day'), (cid, make_date(y, 1, 7), 'Constitution Day'), (cid, make_date(y, 3, 6), 'Independence Day'),
    (cid, easter_sunday(y) - 2, 'Good Friday'), (cid, easter_sunday(y) + 1, 'Easter Monday'), (cid, make_date(y, 5, 1), 'May Day (Workers'' Day)'),
    (cid, make_date(y, 7, 1), 'Republic Day'), (cid, make_date(y, 9, 21), 'Founder''s Day'),
    (cid, v_dec1 + ((5 - extract(dow from v_dec1)::int + 7) % 7), 'Farmers'' Day'),
    (cid, make_date(y, 12, 25), 'Christmas Day'), (cid, make_date(y, 12, 26), 'Boxing Day')
  on conflict do nothing;
  get diagnostics n = row_count;
  return n;
end $$;
revoke execute on function public.seed_ghana_holidays_internal(uuid, int) from public, anon, authenticated;
create or replace function public.seed_ghana_holidays(cid uuid, y int) returns int
language plpgsql security definer set search_path = public as $$
begin
  if not (is_hr(cid) or has_role(cid, array['accountant'])) then raise exception 'Only HR or Finance can set public holidays'; end if;
  return seed_ghana_holidays_internal(cid, y);
end $$;
do $$ declare c record; begin
  for c in select id from companies loop
    perform seed_ghana_holidays_internal(c.id, extract(year from current_date)::int);
    perform seed_ghana_holidays_internal(c.id, extract(year from current_date)::int + 1);
  end loop;
end $$;

create or replace function public.leave_days_between(cid uuid, p_start date, p_end date, p_counts text default 'working') returns numeric
language sql stable security definer set search_path = public as $$
  select count(*)::numeric from generate_series(p_start, p_end, interval '1 day') d
  where is_member(cid) and (p_counts = 'calendar' or (extract(isodow from d) < 6 and not exists (select 1 from public_holidays h where h.company_id = cid and h.holiday = d::date)));
$$;

create or replace function public.leave_request_defaults() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_counts text; v_mgr uuid; v_name text;
begin
  if tg_op = 'INSERT' or (new.start_date, new.end_date, new.half_day) is distinct from (old.start_date, old.end_date, old.half_day) then
    select counts into v_counts from leave_types where company_id = new.company_id and code = new.leave_type;
    new.days := case when new.half_day and new.start_date = new.end_date then 0.5 else leave_days_between(new.company_id, new.start_date, new.end_date, coalesce(v_counts, 'working')) end;
    if new.days <= 0 then raise exception 'Those dates are all weekends or public holidays'; end if;
  end if;
  if tg_op = 'INSERT' then
    select m.user_id, e.full_name into v_mgr, v_name from employees e left join employees m on m.id = e.manager_id where e.id = new.employee_id;
    perform notify(new.company_id, array['hr'], array[v_mgr], 'leave_request', v_name || ' asked for ' || new.days || ' day' || case when new.days = 1 then '' else 's' end || ' ' || replace(new.leave_type, '_', ' ') || ' leave',
      to_char(new.start_date, 'DD Mon') || ' to ' || to_char(new.end_date, 'DD Mon YYYY'), '/leave', false);
  end if;
  return new;
end $$;
create trigger leave_requests_defaults before insert or update on public.leave_requests for each row execute function public.leave_request_defaults();

-- HR or the employee's manager decides (never their own request).
create or replace function public.decide_leave(p_id uuid, p_approve boolean, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
declare q leave_requests; v_mgr uuid; v_self uuid; v_bal numeric;
begin
  select * into q from leave_requests where id = p_id for update;
  if not found then raise exception 'Leave request not found'; end if;
  select m.user_id, e.user_id into v_mgr, v_self from employees e left join employees m on m.id = e.manager_id where e.id = q.employee_id;
  if not (is_hr(q.company_id) or (v_mgr is not null and v_mgr = auth.uid())) then raise exception 'Only HR or the employee''s manager can decide'; end if;
  if v_self = auth.uid() then raise exception 'You cannot approve your own leave'; end if;
  if q.status <> 'pending' then raise exception 'Already decided'; end if;
  if p_approve then
    select remaining into v_bal from leave_balances(q.company_id, extract(year from q.start_date)::int) b where b.employee_id = q.employee_id and b.leave_code = q.leave_type;
    if v_bal is not null and v_bal < q.days and not is_hr(q.company_id) then raise exception 'Only % day(s) left. HR can approve beyond the balance.', v_bal; end if;
  end if;
  update leave_requests set status = case when p_approve then 'approved' else 'rejected' end, decided_by = auth.uid(), decided_at = now(), decision_note = p_note where id = p_id;
  perform notify_users(q.company_id, array[v_self], 'leave_decided', 'Your leave from ' || to_char(q.start_date, 'DD Mon') || ' was ' || case when p_approve then 'approved' else 'not approved' end, p_note, '/leave', false);
end $$;

-- Balances with pro rata for joiners, monthly accrual and carry-over from last year.
drop function if exists public.leave_balances(uuid, int);
create function public.leave_balances(cid uuid, p_year int)
returns table (employee_id uuid, full_name text, leave_code text, leave_name text, entitlement numeric, taken numeric, pending numeric, remaining numeric,
  carried numeric, accrued numeric)
language sql stable security definer set search_path = public as $$
  with base as (
    select e.id eid, e.full_name, t.code, t.name, t.accrual, t.carry_over_max,
      coalesce(en.days, t.days_per_year) full_days,
      -- months employed in the year (whole months from the hire month)
      case when e.hire_date is null or e.hire_date < make_date(p_year, 1, 1) then 12
           when extract(year from e.hire_date) > p_year then 0 else 13 - extract(month from e.hire_date) end::numeric months_in,
      case when p_year < extract(year from current_date) then 12 when p_year > extract(year from current_date) then 0 else extract(month from current_date) end::numeric months_to_date,
      coalesce(enp.days, t.days_per_year) prev_full,
      coalesce((select sum(days) from leave_requests r where r.employee_id = e.id and r.leave_type = t.code and r.status = 'approved' and extract(year from r.start_date) = p_year - 1), 0) prev_taken,
      coalesce((select sum(days) from leave_requests r where r.employee_id = e.id and r.leave_type = t.code and r.status = 'approved' and extract(year from r.start_date) = p_year), 0) taken,
      coalesce((select sum(days) from leave_requests r where r.employee_id = e.id and r.leave_type = t.code and r.status = 'pending' and extract(year from r.start_date) = p_year), 0) pending,
      e.hire_date
    from employees e cross join leave_types t
    left join leave_entitlements en on en.employee_id = e.id and en.leave_code = t.code and en.year = p_year
    left join leave_entitlements enp on enp.employee_id = e.id and enp.leave_code = t.code and enp.year = p_year - 1
    where e.company_id = cid and t.company_id = cid and e.status = 'active' and is_member(cid)
  ), calc as (
    select *, case when full_days is null then null else round(full_days * months_in / 12.0 * 2) / 2 end year_days,
      case when full_days is null or carry_over_max = 0 or (hire_date is not null and extract(year from hire_date) >= p_year) then 0
           else greatest(0, least(carry_over_max, prev_full - prev_taken)) end carried
    from base
  )
  select eid, full_name, code, name,
    case when year_days is null then null else year_days + carried end,
    taken, pending,
    case when year_days is null then null
         when accrual = 'monthly' then round(least(year_days, full_days * greatest(0, months_to_date - (12 - months_in)) / 12.0) * 2) / 2 + carried - taken
         else year_days + carried - taken end,
    carried,
    case when year_days is null then null when accrual = 'monthly' then round(least(year_days, full_days * greatest(0, months_to_date - (12 - months_in)) / 12.0) * 2) / 2 else year_days end
  from calc order by full_name, name;
$$;

-- ---------------------------------------------------------------- 7. Announcements
create table public.announcements (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  title text not null,
  body text not null,
  audience text not null default 'all' check (audience in ('all','department','branch')),
  audience_value text,
  pinned boolean not null default false,
  publish_on date not null default current_date,
  expires_on date,
  created_by uuid default auth.uid(),
  created_email text,
  created_at timestamptz not null default now()
);
create table public.announcement_reads (
  announcement_id uuid not null references public.announcements(id) on delete cascade,
  user_id uuid not null default auth.uid(),
  read_at timestamptz not null default now(),
  primary key (announcement_id, user_id)
);

create or replace function public.announcement_defaults() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_users uuid[];
begin
  if not is_hr(coalesce(new.company_id, old.company_id)) then raise exception 'Only HR, an owner or admin can post announcements'; end if;
  if tg_op = 'DELETE' then return old; end if;
  if tg_op = 'INSERT' then
    new.created_email := (select email from auth.users where id = auth.uid());
    select coalesce(array_agg(m.user_id), '{}') into v_users from memberships m
     where m.company_id = new.company_id and (new.audience = 'all' or exists (select 1 from employees e left join branches b on b.id = e.branch_id
       where e.user_id = m.user_id and e.company_id = new.company_id and ((new.audience = 'department' and e.department = new.audience_value) or (new.audience = 'branch' and (b.name = new.audience_value or b.code = new.audience_value)))));
    if new.publish_on <= current_date then
      perform notify_users(new.company_id, v_users, 'announcement', new.title, left(new.body, 160), '/', false);
    end if;
  end if;
  return new;
end $$;
create trigger announcements_defaults before insert or update or delete on public.announcements for each row execute function public.announcement_defaults();

create or replace function public.my_announcements(cid uuid) returns table (id uuid, title text, body text, pinned boolean, publish_on date, created_email text, read boolean, audience text, audience_value text)
language sql stable security definer set search_path = public as $$
  select a.id, a.title, a.body, a.pinned, a.publish_on, a.created_email, exists (select 1 from announcement_reads r where r.announcement_id = a.id and r.user_id = auth.uid()), a.audience, a.audience_value
  from announcements a
  where a.company_id = cid and is_member(cid) and a.publish_on <= current_date and (a.expires_on is null or a.expires_on >= current_date)
    and (a.audience = 'all' or is_hr(cid) or exists (select 1 from employees e left join branches b on b.id = e.branch_id where e.user_id = auth.uid() and e.company_id = cid
      and ((a.audience = 'department' and e.department = a.audience_value) or (a.audience = 'branch' and (b.name = a.audience_value or b.code = a.audience_value)))))
  order by a.pinned desc, a.publish_on desc, a.created_at desc limit 50;
$$;

-- ---------------------------------------------------------------- 8. Reports
create or replace function public.hr_report(cid uuid, p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v jsonb; v_start int; v_end int; v_leavers int;
begin
  if not has_role(cid, array['owner','admin','hr','accountant']) then raise exception 'Only HR and Finance can see HR reports'; end if;
  select count(*) into v_start from employees where company_id = cid and coalesce(hire_date, created_at::date) < p_from and (end_date is null or end_date >= p_from);
  select count(*) into v_end from employees where company_id = cid and coalesce(hire_date, created_at::date) <= p_to and (end_date is null or end_date > p_to) and (status = 'active' or end_date > p_to);
  select count(*) into v_leavers from employees where company_id = cid and end_date between p_from and p_to;
  v := jsonb_build_object(
    'headcount_start', v_start, 'headcount_end', v_end, 'leavers', v_leavers,
    'joiners', (select count(*) from employees where company_id = cid and hire_date between p_from and p_to),
    'turnover_pct', case when v_start + v_end > 0 then round(100.0 * v_leavers / ((v_start + v_end) / 2.0), 1) end,
    'by_department', coalesce((select jsonb_agg(jsonb_build_object('name', coalesce(department, 'Not set'), 'n', n, 'basic', basic) order by n desc)
      from (select department, count(*) n, sum(basic_salary) basic from employees where company_id = cid and status = 'active' group by department) x), '[]'::jsonb),
    'by_type', coalesce((select jsonb_agg(jsonb_build_object('name', employment_type, 'n', n)) from (select employment_type, count(*) n from employees where company_id = cid and status = 'active' group by 1) x), '[]'::jsonb),
    'by_gender', coalesce((select jsonb_agg(jsonb_build_object('name', coalesce(gender, 'not recorded'), 'n', n)) from (select gender, count(*) n from employees where company_id = cid and status = 'active' group by 1) x), '[]'::jsonb),
    'payroll_by_month', coalesce((select jsonb_agg(jsonb_build_object('period', period, 'gross', gross, 'employer', er, 'net', net, 'paye', paye, 'people', people) order by period)
      from (select r.period, sum(s.gross) gross, sum(s.ssnit_employer + s.tier3_employer) er, sum(s.net) net, sum(s.paye + s.overtime_tax + s.bonus_tax) paye, count(distinct s.employee_id) people
              from payroll_runs r join payslips s on s.run_id = r.id where r.company_id = cid and r.status <> 'draft' and r.period between date_trunc('month', p_from) and p_to group by r.period) x), '[]'::jsonb),
    'leave_liability', coalesce((select jsonb_build_object('days', sum(greatest(b.remaining, 0)), 'value', round(sum(greatest(b.remaining, 0) * e.basic_salary / 22.0), 2))
      from leave_balances(cid, extract(year from p_to)::int) b join employees e on e.id = b.employee_id where b.leave_code = 'annual'), '{}'::jsonb),
    'probation_ending', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'full_name', full_name, 'date', probation_end) order by probation_end)
      from employees where company_id = cid and status = 'active' and confirmed_on is null and probation_end between current_date - 30 and current_date + 60), '[]'::jsonb),
    'contracts_ending', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'full_name', full_name, 'date', contract_end, 'type', employment_type) order by contract_end)
      from employees where company_id = cid and status = 'active' and contract_end between current_date - 30 and current_date + 90), '[]'::jsonb),
    'documents_expiring', coalesce((select jsonb_agg(jsonb_build_object('employee', e.full_name, 'title', d.title, 'date', d.expires_on) order by d.expires_on)
      from employee_documents d join employees e on e.id = d.employee_id where d.company_id = cid and e.status = 'active' and d.expires_on between current_date - 30 and current_date + 60), '[]'::jsonb),
    'birthdays', coalesce((select jsonb_agg(jsonb_build_object('full_name', full_name, 'day', to_char(date_of_birth, 'DD Mon')) order by to_char(date_of_birth, 'MMDD'))
      from employees where company_id = cid and status = 'active' and date_of_birth is not null and extract(month from date_of_birth) = extract(month from current_date)), '[]'::jsonb));
  return v;
end $$;

-- Annual PAYE return: per employee for the year, from posted pay runs.
create or replace function public.paye_annual(cid uuid, p_year int)
returns table (employee_id uuid, full_name text, tin text, ghana_card text, ssnit_no text, months int, basic numeric, allowances numeric, other_earnings numeric,
  nontaxable numeric, overtime numeric, bonus numeric, gross numeric, ssnit_employee numeric, tier3_employee numeric, chargeable numeric, paye numeric,
  overtime_tax numeric, bonus_tax numeric, total_tax numeric)
language sql stable security definer set search_path = public as $$
  select e.id, e.full_name, e.tin, e.ghana_card, e.ssnit_no, count(distinct r.period)::int, sum(s.basic), sum(s.allowances), sum(s.earnings_other + s.backpay - s.nontaxable),
    sum(s.nontaxable), sum(s.overtime), sum(s.bonus), sum(s.gross), sum(s.ssnit_employee), sum(s.tier3_employee), sum(s.chargeable), sum(s.paye),
    sum(s.overtime_tax), sum(s.bonus_tax), sum(s.paye + s.overtime_tax + s.bonus_tax)
  from payslips s join payroll_runs r on r.id = s.run_id join employees e on e.id = s.employee_id
  where r.company_id = cid and r.status <> 'draft' and extract(year from r.period) = p_year and has_role(cid, array['owner','admin','hr','accountant'])
  group by e.id order by e.full_name;
$$;

-- ---------------------------------------------------------------- 9. Reminders (daily, with the existing job)
create or replace function public.run_hr_reminders() returns int
language plpgsql security definer set search_path = public as $$
declare r record; n int := 0;
begin
  -- Future-dated pay changes take effect on the employee record on their date.
  update employees e set basic_salary = sc.basic_salary, allowances = sc.allowances
  from (select distinct on (employee_id) employee_id, basic_salary, allowances from salary_changes where effective_date <= current_date
        order by employee_id, effective_date desc, created_at desc) sc
  where e.id = sc.employee_id and (e.basic_salary, e.allowances) is distinct from (sc.basic_salary, sc.allowances);
  for r in select e.*, m.user_id mgr from employees e left join employees m on m.id = e.manager_id
            where e.status = 'active' and e.confirmed_on is null and e.probation_end = current_date + 14 loop
    perform notify(r.company_id, array['hr'], array[r.mgr], 'hr_probation', 'Probation ends in 2 weeks: ' || r.full_name, 'Confirm, extend or end the appointment.', '/employees/' || r.id, true);
    n := n + 1;
  end loop;
  for r in select e.*, m.user_id mgr from employees e left join employees m on m.id = e.manager_id
            where e.status = 'active' and e.contract_end in (current_date + 30, current_date + 7) loop
    perform notify(r.company_id, array['hr'], array[r.mgr], 'hr_contract', 'Contract ends ' || to_char(r.contract_end, 'DD Mon YYYY') || ': ' || r.full_name, 'Renew or start the exit.', '/employees/' || r.id, true);
    n := n + 1;
  end loop;
  for r in select d.*, e.full_name from employee_documents d join employees e on e.id = d.employee_id where e.status = 'active' and d.expires_on = current_date + 30 loop
    perform notify(r.company_id, array['hr'], null, 'hr_document', r.title || ' for ' || r.full_name || ' expires in 30 days', null, '/employees/' || r.employee_id, true);
    n := n + 1;
  end loop;
  return n;
end $$;
revoke execute on function public.run_hr_reminders() from public, anon, authenticated;

create or replace function public.run_all_cash_reminders() returns int
language plpgsql security definer set search_path = public as $$
declare c record; n int := 0;
begin
  for c in select id from companies loop
    begin n := n + coalesce(run_cash_reminders_internal(c.id), 0); exception when others then null; end;
  end loop;
  begin n := n + coalesce(run_project_hold_reminders(), 0); exception when others then null; end;
  begin n := n + coalesce(run_hse_reminders(), 0); exception when others then null; end;
  begin n := n + coalesce(run_hr_reminders(), 0); exception when others then null; end;
  return n;
end $$;
revoke execute on function public.run_all_cash_reminders() from public, anon, authenticated;

-- ---------------------------------------------------------------- 10. New companies and HR policies
create or replace function public.company_seed_hr() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform set_config('sika.hr', 'on', true);
  perform seed_accounts_v30(new.id);
  perform seed_pay_components(new.id);
  perform seed_hr_checklists(new.id);
  perform seed_ghana_holidays_internal(new.id, extract(year from current_date)::int);
  perform seed_ghana_holidays_internal(new.id, extract(year from current_date)::int + 1);
  perform set_config('sika.hr', 'off', true);
  return null;
end $$;
create trigger companies_seed_hr after insert on public.companies for each row execute function public.company_seed_hr();

-- HR and admin policies share the policy register (HSE module); add the two areas.
alter table public.hse_policies drop constraint if exists hse_policies_area_check;
alter table public.hse_policies add constraint hse_policies_area_check
  check (area in ('safety','environment','quality','legal','tax_finance','labour','data_protection','anti_bribery','hr','admin','it','other'));

-- ---------------------------------------------------------------- 11. Security rules
do $$ declare t text; begin
  foreach t in array array['employee_events','employee_documents','pay_components','employee_pay_items','payroll_input_items','payslip_items','salary_changes',
                           'employee_change_requests','hr_checklists','employee_tasks','employee_exits','public_holidays','announcements'] loop
    execute format('alter table public.%I enable row level security', t);
  end loop;
end $$;
alter table public.announcement_reads enable row level security;
-- Pay and personal records: owners, admins and HR (Finance reads pay).
create policy "hr reads history" on public.employee_events for select using (is_hr(company_id));
create policy "hr writes history" on public.employee_events for insert with check (is_hr(company_id));
create policy "hr deletes history" on public.employee_events for delete using (is_hr(company_id) and kind in ('note','warning','disciplinary','grievance','award','training'));
create policy "hr documents" on public.employee_documents for all using (is_hr(company_id)) with check (is_hr(company_id));
create policy "pay readers" on public.pay_components for select using (is_member(company_id));
create policy "pay writers" on public.pay_components for all using (has_role(company_id, array['owner','admin','hr','accountant'])) with check (has_role(company_id, array['owner','admin','hr','accountant']));
create policy "pay items" on public.employee_pay_items for all using (has_role(company_id, array['owner','admin','hr','accountant'])) with check (has_role(company_id, array['owner','admin','hr','accountant']));
create policy "input items" on public.payroll_input_items for all using (has_role(company_id, array['owner','admin','hr','accountant'])) with check (has_role(company_id, array['owner','admin','hr','accountant']));
create policy "payslip items" on public.payslip_items for select using (has_role(company_id, array['owner','admin','hr','accountant']));
create policy "salary history" on public.salary_changes for select using (has_role(company_id, array['owner','admin','hr','accountant']));
create policy "change requests hr" on public.employee_change_requests for select using (is_hr(company_id));
create policy "checklists read" on public.hr_checklists for select using (is_member(company_id));
create policy "checklists write" on public.hr_checklists for all using (is_hr(company_id)) with check (is_hr(company_id));
create policy "tasks read" on public.employee_tasks for select using (has_role(company_id, array['owner','admin','hr','accountant','store']) or is_hse(company_id)
  or employee_id in (select my_employee_ids()) or exists (select 1 from employees e join employees m on m.id = e.manager_id where e.id = employee_id and m.user_id = auth.uid()));
create policy "tasks hr" on public.employee_tasks for all using (is_hr(company_id)) with check (is_hr(company_id));
create policy "exits hr" on public.employee_exits for all using (is_hr(company_id)) with check (is_hr(company_id));
create policy "exits finance" on public.employee_exits for select using (has_role(company_id, array['accountant']));
create policy "holidays read" on public.public_holidays for select using (is_member(company_id));
create policy "holidays write" on public.public_holidays for all using (is_hr(company_id) or has_role(company_id, array['accountant'])) with check (is_hr(company_id) or has_role(company_id, array['accountant']));
create policy "announcements hr" on public.announcements for all using (is_hr(company_id)) with check (is_hr(company_id));
create policy "own reads" on public.announcement_reads for all using (user_id = auth.uid()) with check (user_id = auth.uid());
-- Leave: staff see their own requests and their team's; HR sees all; decisions go through decide_leave.
drop policy if exists "members read leave" on public.leave_requests;
create policy "leave visible" on public.leave_requests for select using (is_hr(company_id) or employee_id in (select my_employee_ids())
  or exists (select 1 from employees e join employees m on m.id = e.manager_id where e.id = employee_id and m.user_id = auth.uid())
  or (has_role(company_id, array['project_manager','accountant']) and status = 'approved'));
drop policy if exists "members request leave" on public.leave_requests;
create policy "staff request own leave" on public.leave_requests for insert with check (status = 'pending' and (is_hr(company_id) or employee_id in (select my_employee_ids())));

do $$ declare t text; begin
  foreach t in array array['salary_changes','employee_events','employee_documents','pay_components','employee_pay_items','payroll_input_items','employee_exits','announcements','public_holidays'] loop
    execute format('create trigger %I after insert or update or delete on public.%I for each row execute function public.audit_row()', t || '_audit', t);
  end loop;
end $$;

revoke execute on function public.seed_accounts_v30(uuid) from public, anon, authenticated;
revoke execute on function public.seed_pay_components(uuid) from public, anon, authenticated;
revoke execute on function public.seed_hr_checklists(uuid) from public, anon, authenticated;
