import { useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { q, rpc, supabase } from '../lib/supabase';
import { useSession } from '../lib/session';
import { cedis, money, today } from '../lib/format';
import { downloadCsv } from '../lib/download';
import { tablePdf } from '../lib/pdf';
import { ConfirmButton, Downloads, Empty, Field, FormModal, Panel, Select, useAction, useLoad } from './ui';

export const REQUEST_KINDS: [string, string][] = [['material', 'Materials'], ['subcontract', 'Subcontractor service'], ['equipment', 'Equipment or plant hire'], ['other', 'Other expense']];
const kindName = (k: string) => REQUEST_KINDS.find(x => x[0] === k)?.[1] || k;
const statusText: Record<string, string> = { draft: 'Draft', submitted: 'Awaiting approval', approved: 'Approved', rejected: 'Rejected', ordered: 'On a purchase order', billed: 'On a bill', cancelled: 'Cancelled' };

/** Purchase requests raised on a project: materials, subcontractor services, equipment hire or any other expense. */
export function ProjectPurchases({ p, k, manage, tasks, onChange }: { p: any; k: any; manage: boolean; tasks: any[]; onChange: () => void }) {
  const { cid, company, can, session } = useSession();
  const nav = useNavigate();
  const act = useAction();
  const acct = can('accountant');
  const [edit, setEdit] = useState<any | null>(null);
  const [ticked, setTicked] = useState<Set<string>>(new Set());
  const [bill, setBill] = useState<any | null>(null);
  const [order, setOrder] = useState<any | null>(null);
  const buyer = can('accountant', 'store');
  const [reject, setReject] = useState<any | null>(null);
  const [show, setShow] = useState<'open' | 'all'>('open');
  const { data, reload } = useLoad(async () => {
    const [reqs, suppliers, products, accounts, poLines] = await Promise.all([
      q<any[]>(supabase.from('project_requests').select('*, supplier:suppliers(name), bill:bills(id,number,status)').eq('project_id', p.id).order('created_at', { ascending: false }) as any),
      q<any[]>(supabase.from('suppliers').select('id,name').eq('company_id', cid).order('name') as any),
      q<any[]>(supabase.from('products').select('id,name,cost,unit').eq('company_id', cid).eq('active', true).order('name') as any).catch(() => [] as any[]),
      q<any[]>(supabase.from('accounts').select('id,code,name').eq('company_id', cid).eq('type', 'expense').eq('active', true).order('code') as any).catch(() => [] as any[]),
      q<any[]>(supabase.from('po_lines').select('request_id, qty, received_qty, po:purchase_orders(id,number,status)').eq('project_id', p.id) as any).catch(() => [] as any[]),
    ]);
    return { reqs, suppliers, products, accounts, poLines };
  }, [p.id, cid]);
  const refresh = () => { reload(); onChange(); };
  const reqs = (data?.reqs || []).filter(r => show === 'all' || ['draft', 'submitted', 'approved', 'ordered'].includes(r.status) || (r.status === 'billed' && r.bill?.status === 'draft'));
  const budget = Number(k?.budget_cost || 0), spent = Number(k?.actual_cost || 0), committed = Number(k?.committed_cost || 0);
  const headroom = budget - spent - committed;
  const amt = (r: any) => Number(r.qty) * Number(r.est_unit_cost);
  const canDecide = manage || acct;
  const toggle = (id: string) => { const n = new Set(ticked); n.has(id) ? n.delete(id) : n.add(id); setTicked(n); };
  const head = ['Request', 'Date', 'Type', 'Description', 'Qty', 'Unit', 'Est. unit cost (GHS)', 'Est. total (GHS)', 'Supplier', 'Needed by', 'Requested by', 'Status', 'Bill'];
  const rows = (data?.reqs || []).map(r => [r.number, r.created_at.slice(0, 10), kindName(r.kind), r.description, String(Number(r.qty)), r.unit || '', money(r.est_unit_cost), money(amt(r)),
    r.supplier?.name || '', r.needed_by || '', (r.requested_email || '').split('@')[0], statusText[r.status], r.bill?.number || (r.bill ? 'Draft' : '')]);
  const sel = reqs.filter(r => ticked.has(r.id));
  const selTotal = sel.reduce((s, r) => s + amt(r), 0);

  return <>
    <div className="tiles">
      <div className="tile"><span>Cost budget</span><b>{cedis(budget)}</b></div>
      <div className="tile"><span>Spent</span><b>{cedis(spent)}</b></div>
      <div className="tile"><span>Committed (approved requests)</span><b>{cedis(committed)}</b></div>
      <div className="tile"><span>Left to spend</span><b style={{ color: headroom < 0 ? 'var(--bad)' : undefined }}>{cedis(headroom)}</b>
        {budget > 0 && <span className="muted" style={{ fontSize: 12 }}>{Math.round((spent + committed) / budget * 100)}% used or committed</span>}</div>
    </div>
    <Panel title={<div className="actions"><h2>Purchase requests</h2>
        <button type="button" className={'btn small' + (show === 'open' ? ' primary' : '')} onClick={() => setShow('open')}>Open</button>
        <button type="button" className={'btn small' + (show === 'all' ? ' primary' : '')} onClick={() => setShow('all')}>All</button></div>}
      actions={<>
        <Downloads pdf={() => tablePdf({ company: company!, title: `Purchase requests: ${p.name}`, subtitle: p.number, head, body: rows, rightAlign: [4, 6, 7], landscape: true, filename: `requests-${p.number || p.name}` })}
          csv={() => downloadCsv(`requests-${p.number || p.name}`, head, rows)} />
        {buyer && sel.length > 0 && sel.every(r => r.status === 'approved') && <button className="btn small" type="button" onClick={() => setOrder({ supplier_id: sel.find(r => r.supplier_id)?.supplier_id || data?.suppliers[0]?.id || '', expected: '' })}>Purchase order from {sel.length} selected</button>}
        {acct && sel.length > 0 && <button className="btn small" type="button" onClick={() => setBill({ supplier_id: sel.find(r => r.supplier_id)?.supplier_id || data?.suppliers[0]?.id || '', date: today(), ref: '' })}>Create bill from {sel.length} selected</button>}
        {canDecide && sel.length > 0 && sel.every(r => r.status === 'submitted') && <button className="btn small" type="button" disabled={act.busy}
          onClick={() => act.run(async () => { await rpc('decide_request', { p_ids: sel.map(r => r.id), p_approve: true }); setTicked(new Set()); refresh(); }, `${sel.length} approved`)}>Approve {sel.length} selected</button>}
        <button className="btn small primary" type="button" onClick={() => setEdit({ kind: 'material', description: '', product_id: '', account_id: '', qty: '1', unit: '', est_unit_cost: '', supplier_id: '', needed_by: '', task_id: '', notes: '' })}>Raise request</button></>}>
      {reqs.length ? <div className="scroll"><table>
        <thead><tr><th style={{ width: 28 }}></th><th>Request</th><th>What</th><th className="r">Qty</th><th className="r">Est. total (GH₵)</th><th>Needed by</th><th>Status</th><th></th></tr></thead>
        <tbody>{reqs.map(r => { const mine = r.requested_by === session?.user.id; const pickable = r.status === 'submitted' ? canDecide : (r.status === 'approved' || (r.status === 'billed' && !r.bill)) && (acct || buyer);
          return <tr key={r.id}>
          <td>{pickable && <input type="checkbox" aria-label={'Select ' + r.number} checked={ticked.has(r.id)} onChange={() => toggle(r.id)} />}</td>
          <td className="num">{r.number}<br /><span className="muted" style={{ fontSize: 12 }}>{r.created_at.slice(0, 10)} · {(r.requested_email || '').split('@')[0]}</span></td>
          <td className="wrap-cell"><span className="pill">{kindName(r.kind)}</span> {r.description}
            {(r.supplier || r.task_id) && <><br /><span className="muted" style={{ fontSize: 12 }}>{[r.supplier?.name, tasks.find(t => t.id === r.task_id)?.title].filter(Boolean).join(' · ')}</span></>}
            {r.reject_reason && <><br /><span style={{ color: 'var(--bad)', fontSize: 12 }}>{r.reject_reason}</span></>}</td>
          <td className="r num">{Number(r.qty)} {r.unit}</td><td className="r num">{money(amt(r))}</td><td className="num">{r.needed_by}</td>
          <td><span className={'pill ' + ({ submitted: 'warn', approved: 'good', rejected: 'bad', billed: 'good' } as any)[r.status]}>{r.status === 'submitted' && r.first_approved_by ? 'In finance approval' : statusText[r.status]}</span>
            {r.bill && <><br /><Link to={`/bills/${r.bill.id}${r.bill.status === 'draft' ? '/edit' : ''}`} style={{ fontSize: 12 }}>{r.bill.number || 'Draft bill'}</Link></>}
            {(data?.poLines || []).filter(l => l.request_id === r.id && l.po).map(l => <span key={l.po.id}><br /><Link to={'/purchase-orders/' + l.po.id} style={{ fontSize: 12 }}>{l.po.number}</Link>
              <span className="muted" style={{ fontSize: 12 }}> · {Number(l.received_qty) >= Number(l.qty) ? 'delivered' : Number(l.received_qty) > 0 ? `${Number(l.received_qty)} of ${Number(l.qty)} delivered` : l.po.status === 'draft' ? 'order not approved' : 'awaiting delivery'}</span></span>)}</td>
          <td className="r"><span className="actions" style={{ justifyContent: 'flex-end' }}>
            {r.status === 'submitted' && canDecide && !r.first_approved_by && <>
              <button className="btn small primary" type="button" disabled={act.busy} onClick={() => act.run(async () => { await rpc('decide_request', { p_ids: [r.id], p_approve: true }); refresh(); }, `${r.number} approved`)}>Approve</button>
              <button className="btn small" type="button" onClick={() => setReject({ r, reason: '' })}>Reject</button></>}
            {r.status === 'draft' && mine && <button className="btn small" type="button" onClick={() => act.run(async () => { await q(supabase.from('project_requests').update({ status: 'submitted' }).eq('id', r.id) as any); refresh(); }, 'Sent for approval')}>Submit</button>}
            {['draft', 'submitted'].includes(r.status) && (mine || canDecide) && <button className="btn small ghost" type="button" onClick={() => setEdit(Object.fromEntries(Object.entries(r).map(([kk, v]) => [kk, v ?? ''])))}>Edit</button>}
            {['draft', 'submitted', 'approved'].includes(r.status) && (mine || canDecide) && <ConfirmButton className="btn small ghost" label="Cancel" confirm={`Cancel ${r.number}?`}
              onConfirm={() => act.run(async () => { await q(supabase.from('project_requests').update({ status: 'cancelled' }).eq('id', r.id) as any); refresh(); }, 'Cancelled')} />}
          </span></td></tr>; })}</tbody>
      </table></div> : <Empty>No open requests. Anyone on the project can raise one for materials, a subcontractor, equipment hire or any other cost; the project manager approves it within budget, and an accountant approves anything over budget.</Empty>}
      <div className="body muted" style={{ fontSize: 13 }}>Approved requests count as committed cost straight away. The storekeeper or an accountant puts them on a purchase order to the supplier; when the goods arrive on site they are received against the order and become actual cost.
        Small one-off purchases can go straight onto a supplier bill instead. Materials already in your store are issued from the Materials tab.
        For costs already paid (fuel, petty cash), an accountant can post a manual journal and pick this project on the expense line.</div>
    </Panel>

    {edit && data && <FormModal title={edit.id ? `Edit ${edit.number}` : 'Raise a purchase request'} submit={edit.id ? 'Save' : 'Send for approval'} busy={act.busy} onClose={() => setEdit(null)}
      onSave={() => act.run(async () => {
        if (!(Number(edit.qty) > 0)) throw new Error('Enter a quantity.');
        const row = { kind: edit.kind, description: edit.description, product_id: edit.kind === 'material' ? edit.product_id || null : null, account_id: edit.kind === 'other' ? edit.account_id || null : null,
          qty: Number(edit.qty), unit: edit.unit || null, est_unit_cost: Number(edit.est_unit_cost) || 0, supplier_id: edit.supplier_id || null, needed_by: edit.needed_by || null,
          task_id: edit.task_id || null, notes: edit.notes || null };
        if (edit.id) await q(supabase.from('project_requests').update(row).eq('id', edit.id) as any);
        else await q(supabase.from('project_requests').insert({ ...row, project_id: p.id, company_id: p.company_id, status: 'submitted' }) as any);
        setEdit(null); refresh();
      }, edit.id ? 'Saved' : 'Request sent for approval')}>
      <div className="grid-form">
        <Select label="Type" id="pr-kind" value={edit.kind} onChange={v => setEdit({ ...edit, kind: v })} options={REQUEST_KINDS} />
        {edit.kind === 'material' && data.products.length > 0 && <Select label="Stock item (optional)" id="pr-prod" value={edit.product_id} onChange={v => { const pr = data.products.find(x => x.id === v);
          setEdit({ ...edit, product_id: v, description: edit.description || pr?.name || '', unit: edit.unit || pr?.unit || '', est_unit_cost: edit.est_unit_cost || (pr ? String(pr.cost) : '') }); }}
          options={[['', 'Not a stock item'], ...data.products.map(x => [x.id, x.name] as [string, string])]} />}
        {edit.kind === 'other' && data.accounts.length > 0 && <Select label="Expense account" id="pr-acct" value={edit.account_id} onChange={v => setEdit({ ...edit, account_id: v })}
          options={[['', '6900 General expenses'], ...data.accounts.map(a => [a.id, `${a.code} ${a.name}`] as [string, string])]} />}
      </div>
      <Field label="What is needed" id="pr-desc" value={edit.description} onChange={v => setEdit({ ...edit, description: v })} placeholder={edit.kind === 'subcontract' ? 'e.g. Electrical first fix, blocks A and B' : edit.kind === 'equipment' ? 'e.g. Scaffold hire, 2 weeks' : 'e.g. Cement, 50 kg bags'} required />
      <div className="grid-form">
        <Field label="Quantity" id="pr-qty" type="number" step="0.001" min="0" value={edit.qty} onChange={v => setEdit({ ...edit, qty: v })} required />
        <Field label="Unit" id="pr-unit" value={edit.unit} onChange={v => setEdit({ ...edit, unit: v })} placeholder="bag, day, lot" />
        <Field label="Estimated unit cost (GH₵, excl. VAT)" id="pr-cost" type="number" step="0.01" min="0" value={edit.est_unit_cost} onChange={v => setEdit({ ...edit, est_unit_cost: v })} required />
        <Field label="Needed by" id="pr-need" type="date" value={edit.needed_by} onChange={v => setEdit({ ...edit, needed_by: v })} />
        <Select label="Preferred supplier" id="pr-sup" value={edit.supplier_id} onChange={v => setEdit({ ...edit, supplier_id: v })} options={[['', 'Not decided'], ...data.suppliers.map(s => [s.id, s.name] as [string, string])]} />
        {tasks.length > 0 && <Select label="For task" id="pr-task" value={edit.task_id} onChange={v => setEdit({ ...edit, task_id: v })} options={[['', '—'], ...tasks.map(t => [t.id, t.title] as [string, string])]} />}
      </div>
      <Field label="Notes" id="pr-notes" type="textarea" value={edit.notes} onChange={v => setEdit({ ...edit, notes: v })} />
      <p className="muted" style={{ margin: 0, fontSize: 13 }}>Estimated total {cedis(Number(edit.qty) * Number(edit.est_unit_cost) || 0)}. Left in the cost budget: {cedis(headroom)}.
        {budget > 0 && Number(edit.qty) * Number(edit.est_unit_cost) > headroom && <b style={{ color: 'var(--bad)' }}> This is over budget, so an accountant or the owner must approve it.</b>}</p>
    </FormModal>}
    {reject && <FormModal title={`Reject ${reject.r.number}`} submit="Reject" busy={act.busy} onClose={() => setReject(null)}
      onSave={() => act.run(async () => { await rpc('decide_request', { p_ids: [reject.r.id], p_approve: false, p_reason: reject.reason || null }); setReject(null); refresh(); }, 'Rejected')}>
      <Field label="Reason (the requester sees this)" id="rj-reason" value={reject.reason} onChange={v => setReject({ ...reject, reason: v })} />
    </FormModal>}
    {order && data && <FormModal title="Create a purchase order" submit="Create draft order" busy={act.busy} onClose={() => setOrder(null)}
      onSave={() => act.run(async () => {
        const id = await rpc<string>('po_from_requests', { p_ids: sel.map(r => r.id), p_supplier: order.supplier_id, p_expected: order.expected || null });
        nav('/purchase-orders/' + id);
      }, 'Draft purchase order created. Check prices, then approve and send it.')}>
      <p style={{ margin: 0 }}>{sel.length} request{sel.length === 1 ? '' : 's'}, estimated {cedis(selTotal)}. The goods are delivered to the project, and each line is tagged to {p.name}.</p>
      <div className="grid-form">
        <Select label="Supplier" id="po-sup" value={order.supplier_id} onChange={v => setOrder({ ...order, supplier_id: v })} options={data.suppliers.map(s => [s.id, s.name] as [string, string])} />
        <Field label="Delivery expected" id="po-exp" type="date" value={order.expected} onChange={v => setOrder({ ...order, expected: v })} />
      </div>
    </FormModal>}
    {bill && data && <FormModal title="Create a supplier bill" submit="Create draft bill" busy={act.busy} onClose={() => setBill(null)}
      onSave={() => act.run(async () => {
        const id = await rpc<string>('bill_requests', { p_ids: sel.map(r => r.id), p_supplier: bill.supplier_id, p_date: bill.date, p_ref: bill.ref || null });
        nav(`/bills/${id}/edit`);
      }, 'Draft bill created. Enter the supplier\'s actual prices, then post it.')}>
      <p style={{ margin: 0 }}>{sel.length} request{sel.length === 1 ? '' : 's'}, estimated {cedis(selTotal)}. Each becomes a bill line tagged to {p.name}.</p>
      <div className="grid-form">
        <Select label="Supplier" id="bq-sup" value={bill.supplier_id} onChange={v => setBill({ ...bill, supplier_id: v })} options={data.suppliers.map(s => [s.id, s.name] as [string, string])} />
        <Field label="Supplier's invoice no." id="bq-ref" value={bill.ref} onChange={v => setBill({ ...bill, ref: v })} />
        <Field label="Bill date" id="bq-date" type="date" value={bill.date} onChange={v => setBill({ ...bill, date: v })} required />
      </div>
    </FormModal>}
  </>;
}


