import { useState } from 'react';
import { q, supabase } from '../lib/supabase';
import { useSession } from '../lib/session';
import { cedis } from '../lib/format';
import { ConfirmButton, Empty, Field, FormModal, Panel, Select, useAction, useLoad } from '../components/ui';

// ---------------------------------------------------------------- Branches and cost centres
export function DimensionsPanel() {
  const { cid, can } = useSession();
  const act = useAction();
  const [edit, setEdit] = useState<any | null>(null);
  const { data, reload } = useLoad(async () => ({
    branches: await q<any[]>(supabase.from('branches').select('*').eq('company_id', cid).order('code') as any),
    centres: await q<any[]>(supabase.from('cost_centres').select('*').eq('company_id', cid).order('code') as any),
  }), [cid]);
  if (!can('accountant') || !data) return null;
  const table = (kind: 'branches' | 'cost_centres', rows: any[]) => rows.length ? <div className="scroll"><table><tbody>{rows.map(r => <tr key={r.id} style={r.active ? undefined : { opacity: .5 }}>
    <td className="num" style={{ width: 70 }}>{r.code}</td><td>{r.name}{r.address && <span className="muted"> · {r.address}</span>}</td>
    <td className="r"><button className="btn small ghost" type="button" onClick={() => setEdit({ kind, ...r, address: r.address || '' })}>Edit</button></td></tr>)}</tbody></table></div>
    : <Empty>None yet.</Empty>;
  return <Panel title="Branches and cost centres" pad>
    <p className="muted" style={{ marginTop: 0, fontSize: 13 }}>Tag invoices, bills, employees, projects and journals with a branch and cost centre to get profit and loss for each one (Reports → By branch / cost centre). Payroll cost follows each employee's branch and cost centre.</p>
    <div className="two">
      <div><div className="actions" style={{ justifyContent: 'space-between' }}><div className="label">Branches</div>
        <button className="btn small" type="button" onClick={() => setEdit({ kind: 'branches', code: '', name: '', address: '', active: true })}>Add branch</button></div>{table('branches', data.branches)}</div>
      <div><div className="actions" style={{ justifyContent: 'space-between' }}><div className="label">Cost centres</div>
        <button className="btn small" type="button" onClick={() => setEdit({ kind: 'cost_centres', code: '', name: '', active: true })}>Add cost centre</button></div>{table('cost_centres', data.centres)}</div>
    </div>
    {edit && <FormModal title={(edit.id ? 'Edit ' : 'Add ') + (edit.kind === 'branches' ? 'branch' : 'cost centre')} busy={act.busy} onClose={() => setEdit(null)}
      onSave={() => act.run(async () => {
        const row: any = { code: edit.code.trim().toUpperCase(), name: edit.name.trim(), active: edit.active };
        if (edit.kind === 'branches') row.address = edit.address || null;
        if (edit.id) await q(supabase.from(edit.kind).update(row).eq('id', edit.id) as any);
        else await q(supabase.from(edit.kind).insert({ ...row, company_id: cid }) as any);
        setEdit(null); reload();
      }, 'Saved')}>
      <div className="grid-form">
        <Field label="Short code" id="dm-code" value={edit.code} onChange={v => setEdit({ ...edit, code: v })} placeholder={edit.kind === 'branches' ? 'e.g. KSI' : 'e.g. OPS'} required />
        <Field label="Name" id="dm-name" value={edit.name} onChange={v => setEdit({ ...edit, name: v })} placeholder={edit.kind === 'branches' ? 'e.g. Kumasi branch' : 'e.g. Operations'} required />
        {edit.kind === 'branches' && <Field label="Address" id="dm-addr" value={edit.address} onChange={v => setEdit({ ...edit, address: v })} />}
      </div>
      <label className="check"><input type="checkbox" checked={edit.active} onChange={e => setEdit({ ...edit, active: e.target.checked })} /> Active</label>
    </FormModal>}
  </Panel>;
}

// ---------------------------------------------------------------- Approval rules
const DOCS: [string, string][] = [['bill', 'Supplier bills'], ['payroll', 'Payroll runs'], ['purchase_request', 'Project purchase requests'], ['expense_claim', 'Staff expense claims'], ['purchase_order', 'Purchase orders']];
const ROLE_NAMES: [string, string][] = [['owner', 'Owner'], ['admin', 'Admin'], ['accountant', 'Accountant'], ['hr', 'HR'], ['project_manager', 'Project manager'], ['sales', 'Sales'], ['store', 'Storekeeper']];

export function ApprovalRulesPanel() {
  const { cid, can } = useSession();
  const act = useAction();
  const [edit, setEdit] = useState<any | null>(null);
  const { data, reload } = useLoad(async () => ({
    rules: await q<any[]>(supabase.from('approval_rules').select('*').eq('company_id', cid).order('doc_type').order('step_no') as any),
    team: await q<any[]>(supabase.from('memberships').select('user_id,email,role').eq('company_id', cid).order('email') as any),
  }), [cid]);
  if (!can('admin') || !data) return null;
  const who = (r: any) => r.approver_user ? data.team.find(t => t.user_id === r.approver_user)?.email || 'A specific person' : `Anyone with the ${ROLE_NAMES.find(x => x[0] === r.approver_role)?.[1]} role`;
  return <Panel title="Approval rules" actions={<button className="btn small primary" type="button" onClick={() => setEdit({ doc_type: 'bill', step_no: '1', min_amount: '0', who: 'role:accountant', label: '' })}>Add step</button>}>
    {data.rules.length ? <div className="scroll"><table>
      <thead><tr><th>Document</th><th>Step</th><th className="r">Applies from (GH₵)</th><th>Approver</th><th></th></tr></thead>
      <tbody>{data.rules.map(r => <tr key={r.id}><td>{DOCS.find(d => d[0] === r.doc_type)?.[1]}</td><td>{r.step_no}. {r.label}</td><td className="r num">{cedis(r.min_amount)}</td><td>{who(r)}</td>
        <td className="r"><ConfirmButton className="btn small ghost" label="Remove" confirm="Remove this step? Documents already waiting keep their steps." onConfirm={() => act.run(async () => { await q(supabase.from('approval_rules').delete().eq('id', r.id) as any); reload(); })} /></td></tr>)}</tbody>
    </table></div> : <Empty>No approval rules. Bills and payroll post straight away, and purchase requests and expense claims need only the usual approval.</Empty>}
    <div className="body muted" style={{ fontSize: 13 }}>Each step applies when the document is at or above its amount, in step order. Example for bills: step 1 Accountant from GH₵0, step 2 Owner from GH₵20,000.
      A person cannot approve two steps of the same document (except the owner). Bills and payroll that need approval cannot be posted until every step is approved; if the amount goes up afterwards, it must be approved again.
      For purchase requests and expense claims, these steps come after the project manager's or accountant's normal approval.</div>
    {edit && <FormModal title="Add approval step" busy={act.busy} onClose={() => setEdit(null)}
      onSave={() => act.run(async () => {
        const [kind, val] = edit.who.split(':');
        await q(supabase.from('approval_rules').insert({ company_id: cid, doc_type: edit.doc_type, step_no: Number(edit.step_no), min_amount: Number(edit.min_amount) || 0,
          approver_role: kind === 'role' ? val : null, approver_user: kind === 'user' ? val : null,
          label: edit.label || (kind === 'role' ? ROLE_NAMES.find(x => x[0] === val)?.[1] : data.team.find(t => t.user_id === val)?.email) }) as any);
        setEdit(null); reload();
      }, 'Approval step added')}>
      <div className="grid-form">
        <Select label="Document" id="ar-doc" value={edit.doc_type} onChange={v => setEdit({ ...edit, doc_type: v })} options={DOCS} />
        <Select label="Step" id="ar-step" value={edit.step_no} onChange={v => setEdit({ ...edit, step_no: v })} options={[1, 2, 3, 4, 5].map(n => [String(n), String(n)] as [string, string])} />
        <Field label="Applies from amount (GH₵)" id="ar-min" type="number" step="1" min="0" value={edit.min_amount} onChange={v => setEdit({ ...edit, min_amount: v })} />
        <Select label="Approver" id="ar-who" value={edit.who} onChange={v => setEdit({ ...edit, who: v })}
          options={[...ROLE_NAMES.map(([v, l]) => ['role:' + v, `Anyone with the ${l} role`] as [string, string]), ...data.team.map(t => ['user:' + t.user_id, t.email] as [string, string])]} />
      </div>
      <Field label="Name of the step" id="ar-label" value={edit.label} onChange={v => setEdit({ ...edit, label: v })} placeholder="e.g. Finance manager, Managing director" />
    </FormModal>}
  </Panel>;
}

// ---------------------------------------------------------------- API access for other systems
export function DevelopersPanel() {
  const { cid, can } = useSession();
  const [open, setOpen] = useState(false);
  if (!can('admin')) return null;
  const url = import.meta.env.VITE_SUPABASE_URL || 'https://YOUR-PROJECT.supabase.co';
  return <Panel title="Connect other systems (API)" actions={<button className="btn small" type="button" onClick={() => setOpen(!open)}>{open ? 'Hide' : 'Show how'}</button>} pad>
    <p className="muted" style={{ margin: 0, fontSize: 13 }}>Point-of-sale tills, e-commerce sites, banks' payment notifications and BI tools can read and write Asnys data through its REST API, with the same security rules as people.</p>
    {open && <div style={{ display: 'grid', gap: 10, marginTop: 12, fontSize: 14 }}>
      <ol style={{ margin: 0, paddingLeft: 20, display: 'grid', gap: 6 }}>
        <li>Create a login for the system (e.g. <code>pos@yourcompany.com</code>) and add it under Team with the narrowest role it needs (Sales for invoices, Accountant for the books).</li>
        <li>The system signs in to get a token: <code>POST {url}/auth/v1/token?grant_type=password</code> with the email and password and the header <code>apikey: (your anon key)</code>.</li>
        <li>It then calls the API with <code>Authorization: Bearer (token)</code>. Every table is under <code>{url}/rest/v1/</code> and every action under <code>{url}/rest/v1/rpc/</code>.</li>
      </ol>
      <pre style={{ background: 'var(--sunk)', padding: 12, borderRadius: 8, overflowX: 'auto', margin: 0, fontSize: 12 }}>{`# Create a draft invoice, add a line, post it
curl -X POST '${url}/rest/v1/invoices' -H 'apikey: ANON_KEY' -H 'Authorization: Bearer TOKEN' \\
  -H 'Content-Type: application/json' -H 'Prefer: return=representation' \\
  -d '{"company_id":"${cid}","customer_id":"CUSTOMER_ID","invoice_date":"2026-11-02"}'
curl -X POST '${url}/rest/v1/invoice_lines' ... -d '{"invoice_id":"INVOICE_ID","company_id":"${cid}","description":"Rice 25 kg","qty":4,"unit_price":520}'
curl -X POST '${url}/rest/v1/rpc/post_invoice' ... -d '{"p_invoice":"INVOICE_ID"}'

# Read the trial balance
curl -X POST '${url}/rest/v1/rpc/account_balances' ... -d '{"cid":"${cid}","p_from":"2026-01-01","p_to":"2026-12-31"}'`}</pre>
      <p className="muted" style={{ margin: 0, fontSize: 13 }}>Your company id is <code>{cid}</code>. To push changes out to other systems as they happen, add a Database Webhook in Supabase (Database → Webhooks) on the tables you need. The setup guide lists every action.</p>
    </div>}
  </Panel>;
}
