import { useState } from 'react';
import { Link } from 'react-router-dom';
import { q, rpc, supabase } from '../lib/supabase';
import { fetchAll, Pager, SearchBox, usePaged } from '../components/paging';
import { useSession } from '../lib/session';
import { money } from '../lib/format';
import { downloadCsv } from '../lib/download';
import { statementPdf, tablePdf } from '../lib/pdf';
import { ConfirmButton, Downloads, Empty, Field, FormModal, Loading, PageHead, Panel, Select, useAction, useLoad } from '../components/ui';

type Kind = 'customer' | 'supplier';
const blank = { name: '', phone: '', email: '', tin: '', address: '', city: '' };

export function PartiesPage({ kind }: { kind: Kind }) {
  const { cid, company } = useSession();
  const table = kind === 'customer' ? 'customers' : 'suppliers';
  const docTable = kind === 'customer' ? 'invoices' : 'bills';
  const payTable = kind === 'customer' ? 'payments' : 'bill_payments';
  const fk = kind === 'customer' ? 'customer_id' : 'supplier_id';
  const title = kind === 'customer' ? 'Customers' : 'Suppliers';
  const [edit, setEdit] = useState<any | null>(null);
  const [search, setSearch] = useState('');
  const act = useAction();
  const { data: extra } = useLoad(async () => kind === 'customer' ? {
    team: await q<any[]>(supabase.from('memberships').select('user_id,email').eq('company_id', cid) as any),
    territories: await q<any[]>(supabase.from('sales_territories').select('id,name').eq('company_id', cid).order('name') as any),
    partners: await q<any[]>(supabase.from('partners').select('id,name').eq('company_id', cid).eq('active', true).order('name') as any),
  } : null, [cid, kind]);

  // Paged on the server with balances worked out in the database, so thousands of customers stay quick.
  const pg = usePaged(async (a, b) => {
    const rows = await rpc<any[]>('party_balances', { cid, p_kind: kind, p_search: search || null, p_limit: b - a + 1, p_offset: a });
    return { rows, total: Number(rows[0]?.total_rows || 0) };
  }, [cid, kind, search]);
  const reload = pg.reload;

  const save = () => act.run(async () => {
    const row = { ...edit }; delete row.owed; delete row.overdue; delete row.total_rows; if (kind === 'customer') { row.owner_id = row.owner_id || null; row.territory_id = row.territory_id || null; row.partner_id = row.partner_id || null; } else { delete row.owner_id; delete row.territory_id; delete row.partner_id; }
    if (row.id) await q(supabase.from(table).update(row).eq('id', row.id) as any);
    else await q(supabase.from(table).insert({ ...row, company_id: cid }) as any);
    setEdit(null); reload();
  }, kind === 'customer' ? 'Customer saved' : 'Supplier saved');

  const remove = (id: string) => act.run(async () => {
    await q(supabase.from(table).delete().eq('id', id) as any); setEdit(null); reload();
  }, 'Deleted');

  const statement = (p: any) => act.run(async () => {
    const [docs, pays, credits] = await Promise.all([
      q<any[]>(supabase.from(docTable).select('*').eq(fk, p.id).neq('status', 'draft') as any),
      q<any[]>(supabase.from(payTable).select(`*, doc:${docTable}!inner(${fk},exchange_rate)`).eq(`doc.${fk}`, p.id) as any),
      kind === 'customer' ? q<any[]>(supabase.from('credit_notes').select('*').eq('customer_id', p.id).eq('status', 'posted') as any) : Promise.resolve([]),
    ]);
    statementPdf({ company: company!, party: p, kind, docs, payments: pays, credits });
  });

  const list = pg.rows;
  const head = ['Name', 'Phone', 'Email', 'TIN', 'Town', kind === 'customer' ? 'Owes us (GHS equiv.)' : 'We owe (GHS equiv.)', 'Overdue'];
  const toRows = (l: any[]) => l.map(p => [p.name, p.phone || '', p.email || '', p.tin || '', p.city || '', money(p.owed), money(p.overdue)]);
  const allRows = async () => toRows(await fetchAll(async (a, b) => rpc<any[]>('party_balances', { cid, p_kind: kind, p_search: search || null, p_limit: b - a + 1, p_offset: a }), 50000));

  return <>
    <PageHead title={title} sub={pg.data ? `${pg.total.toLocaleString()} ${title.toLowerCase()}${search ? ' match' : ''}` : undefined}>
      <Downloads pdf={() => act.run(async () => tablePdf({ company: company!, title, head, body: await allRows(), rightAlign: [5, 6], filename: title.toLowerCase() }))}
        csv={() => act.run(async () => downloadCsv(title.toLowerCase(), head, await allRows()))} />
      <button className="btn primary" type="button" onClick={() => setEdit({ ...blank })}>Add {kind}</button>
    </PageHead>
    <div className="filters"><SearchBox value={search} onChange={setSearch} placeholder="Name, phone, town or TIN" id="p-search" /></div>
    <Loading error={pg.error} loading={pg.loading && !pg.data} />
    {pg.data && <Panel>
      {list.length ? <div className="scroll"><table>
        <thead><tr><th>Name</th><th>Phone</th><th>Town</th><th>TIN</th><th className="r">{head[5].replace('GHS', 'GH₵')}</th><th className="r">Overdue</th><th></th></tr></thead>
        <tbody>{list.map(p => <tr key={p.id}>
          <td>{kind === 'customer' ? <Link to={'/customers/' + p.id} style={{ fontWeight: 600 }}>{p.name}</Link>
            : <Link to={'/suppliers/' + p.id} style={{ fontWeight: 600 }}>{p.name}</Link>}</td>
          <td className="num">{p.phone}</td><td>{p.city}</td><td className="num">{p.tin}</td><td className="r num">{money(p.owed)}</td><td className="r num" style={{ color: Number(p.overdue) > 0 ? 'var(--bad)' : undefined }}>{Number(p.overdue) ? money(p.overdue) : ''}</td>
          <td className="r"><span className="actions" style={{ justifyContent: 'flex-end' }}>{<button className="btn small ghost" type="button" onClick={() => setEdit(p)}>Edit</button>}
            <button className="btn small" type="button" onClick={() => statement(p)}>Statement PDF</button></span></td></tr>)}</tbody>
      </table></div> : <Empty>{search ? 'No matches.' : `No ${title.toLowerCase()} yet. Add your first one, or import them from a spreadsheet.`}</Empty>}
      <Pager {...pg} noun={title.toLowerCase()} />
    </Panel>}
    {edit && <FormModal title={edit.id ? `Edit ${kind}` : `Add ${kind}`} onClose={() => setEdit(null)} onSave={save} busy={act.busy}
      danger={edit.id && <ConfirmButton className="btn danger" label="Delete" confirm="Delete?" onConfirm={() => remove(edit.id)} />}>
      <Field label="Business or person name" id="p-name" value={edit.name} onChange={v => setEdit({ ...edit, name: v })} required />
      <div className="grid-form">
        <Field label="Phone" id="p-phone" value={edit.phone} onChange={v => setEdit({ ...edit, phone: v })} />
        <Field label="Email" id="p-email" type="email" value={edit.email} onChange={v => setEdit({ ...edit, email: v })} />
        <Field label="TIN or Ghana Card" id="p-tin" value={edit.tin} onChange={v => setEdit({ ...edit, tin: v })} />
        <Field label="Town or city" id="p-city" value={edit.city} onChange={v => setEdit({ ...edit, city: v })} />
      </div>
      <Field label="Address or digital address" id="p-addr" value={edit.address} onChange={v => setEdit({ ...edit, address: v })} />
      {kind === 'customer' && extra && <div className="grid-form">
        <Select label="Account owner (sales rep)" id="p-owner" value={edit.owner_id || ''} onChange={v => setEdit({ ...edit, owner_id: v })} options={[['', 'Nobody'], ...extra.team.map(t => [t.user_id, t.email] as [string, string])]} />
        {extra.territories.length > 0 && <Select label="Territory" id="p-terr" value={edit.territory_id || ''} onChange={v => setEdit({ ...edit, territory_id: v })} options={[['', 'None'], ...extra.territories.map(t => [t.id, t.name] as [string, string])]} />}
        {extra.partners.length > 0 && <Select label="Introduced by partner" id="p-partner" value={edit.partner_id || ''} onChange={v => setEdit({ ...edit, partner_id: v })} options={[['', 'None'], ...extra.partners.map(t => [t.id, t.name] as [string, string])]} />}
      </div>}
    </FormModal>}
  </>;
}
