import { useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { q, rpc, supabase } from '../lib/supabase';
import { useSession } from '../lib/session';
import { cedis, money } from '../lib/format';
import { statementPdf } from '../lib/pdf';
import { ConfirmButton, Empty, Field, FormModal, Loading, PageHead, Panel, Status, useAction, useLoad } from '../components/ui';
import { amt } from '../components/docs';
import { ActivityList } from './CRM';

/** Customer 360: one screen with everything about a customer — money, deals, service, people, history. */
export function Customer360() {
  const { id } = useParams();
  const { cid, company, can } = useSession();
  const nav = useNavigate();
  const act = useAction();
  const [contact, setContact] = useState<any | null>(null);
  const [tab, setTab] = useState<'sales' | 'deals' | 'service' | 'projects'>('sales');
  const { data: team } = useLoad(() => q<any[]>(supabase.from('memberships').select('user_id,email').eq('company_id', cid) as any), [cid]);
  const { data, error, loading, reload } = useLoad(async () => {
    const [c, k, contacts, invoices, opps, quotes, cases, projects] = await Promise.all([
      q<any>(supabase.from('customers').select('*, territory:sales_territories(name), partner:partners(name)').eq('id', id).single() as any),
      rpc<any>('customer_360', { p_customer: id }),
      q<any[]>(supabase.from('customer_contacts').select('*').eq('customer_id', id).order('name') as any),
      q<any[]>(supabase.from('invoices').select('id,number,invoice_date,due_date,total,amount_paid,amount_credited,currency,status').eq('customer_id', id).order('invoice_date', { ascending: false }).limit(50) as any),
      q<any[]>(supabase.from('opportunities').select('*').eq('customer_id', id).order('created_at', { ascending: false }) as any),
      q<any[]>(supabase.from('sales_quotes').select('id,number,kind,quote_date,total,currency,status').eq('customer_id', id).order('quote_date', { ascending: false }).limit(30) as any),
      q<any[]>(supabase.from('support_cases').select('id,number,subject,status,priority,opened_at').eq('customer_id', id).order('opened_at', { ascending: false }) as any),
      q<any[]>(supabase.from('projects').select('id,number,name,status,health').eq('customer_id', id).eq('is_template', false).order('created_at', { ascending: false }) as any),
    ]);
    return { c, k: k || {}, contacts, invoices, opps, quotes, cases, projects };
  }, [id]);
  if (!data) return <Loading error={error} loading={loading} />;
  const { c, k, contacts, invoices, opps, quotes, cases, projects } = data;
  const owner = team?.find(t => t.user_id === c.owner_id)?.email;
  const statement = () => act.run(async () => {
    const [docs, pays, credits] = await Promise.all([
      q<any[]>(supabase.from('invoices').select('*').eq('customer_id', id).neq('status', 'draft') as any),
      q<any[]>(supabase.from('payments').select('*, doc:invoices!inner(customer_id,exchange_rate)').eq('doc.customer_id', id) as any),
      q<any[]>(supabase.from('credit_notes').select('*').eq('customer_id', id).eq('status', 'posted') as any),
    ]);
    statementPdf({ company: company!, party: c, kind: 'customer', docs, payments: pays, credits });
  });
  const margin = Number(k.lifetime_sales) ? Math.round(Number(k.gross_profit) / Number(k.lifetime_sales) * 100) : null;

  return <>
    <PageHead title={c.name} sub={<>{[c.phone, c.email, c.city].filter(Boolean).join(' · ')}{owner && <> · Account owner {owner.split('@')[0]}</>}
      {c.territory && <> · {c.territory.name}</>}{c.partner && <> · via {c.partner.name}</>}</>}>
      <Link className="btn" to="/customers">Back</Link>
      <button className="btn" type="button" onClick={statement}>Statement PDF</button>
      <Link className="btn" to={`/quotes/new?customer=${id}`}>New quote</Link>
      {can('sales') && <Link className="btn primary" to={`/invoices/new?customer=${id}`}>New invoice</Link>}
    </PageHead>
    <div className="tiles">
      <div className="tile"><span>Lifetime sales (excl. VAT)</span><b>{cedis(k.lifetime_sales)}</b></div>
      <div className="tile"><span>Gross profit</span><b>{cedis(k.gross_profit)}{margin != null && <span className="muted" style={{ fontSize: 13 }}> {margin}%</span>}</b></div>
      <div className="tile"><span>Owes us</span><b>{cedis(k.outstanding)}</b>{Number(k.overdue) > 0 && <span style={{ color: 'var(--bad)', fontSize: 12 }}>{cedis(k.overdue)} overdue</span>}</div>
      <div className="tile"><span>Pays in (average)</span><b>{k.avg_days_to_pay != null ? `${k.avg_days_to_pay} days` : '—'}</b></div>
      <div className="tile"><span>Open pipeline</span><b>{cedis(k.open_pipeline)}</b></div>
      <div className="tile"><span>Open support cases</span><b>{k.open_cases ?? 0}</b></div>
    </div>
    <div className="two">
      <Panel title="Contacts" actions={<button className="btn small" type="button" onClick={() => setContact({ name: '', job_title: '', phone: '', email: '' })}>Add contact</button>}>
        {contacts.length ? <div className="scroll"><table><tbody>{contacts.map(p => <tr key={p.id}>
          <td><b>{p.name}</b><br /><span className="muted">{p.job_title}</span></td><td className="num">{p.phone}<br /><span className="muted">{p.email}</span></td>
          <td className="r">{p.phone && <a className="btn small ghost" href={`https://wa.me/${p.phone.replace(/\D/g, '').replace(/^0/, '233')}`} target="_blank" rel="noreferrer">WhatsApp</a>}
            <button className="btn small ghost" type="button" onClick={() => setContact({ ...p, job_title: p.job_title || '', phone: p.phone || '', email: p.email || '' })}>Edit</button></td></tr>)}</tbody></table></div>
          : <Empty>No contacts yet. Add the buyer, the accountant who pays you, and the decision maker.</Empty>}
      </Panel>
      <Panel title="What they buy most">{(k.top_products || []).length ? <div className="scroll"><table>
        <thead><tr><th>Item</th><th className="r">Qty</th><th className="r">Revenue (GH₵)</th></tr></thead>
        <tbody>{k.top_products.map((p: any) => <tr key={p.name}><td>{p.name}</td><td className="r num">{money(p.qty)}</td><td className="r num">{money(p.revenue)}</td></tr>)}</tbody>
      </table></div> : <Empty>No sales yet.</Empty>}
        <div className="body muted" style={{ fontSize: 13 }}>Customer since {k.first_invoice || '—'} · last invoice {k.last_invoice || '—'} · {k.invoices || 0} invoices</div>
      </Panel>
    </div>
    <div className="actions">
      {([['sales', `Invoices & quotes`], ['deals', `Opportunities (${opps.length})`], ['service', `Support cases (${cases.length})`], ['projects', `Projects (${projects.length})`]] as const).map(([t, l]) =>
        <button key={t} type="button" className={'btn small' + (tab === t ? ' primary' : '')} onClick={() => setTab(t)}>{l}</button>)}
    </div>
    {tab === 'sales' && <div className="two">
      <Panel title="Invoices">{invoices.length ? <div className="scroll"><table>
        <thead><tr><th>Invoice</th><th>Date</th><th className="r">Total</th><th className="r">Balance</th><th>Status</th></tr></thead>
        <tbody>{invoices.map(i => <tr key={i.id} className="click" onClick={() => nav('/invoices/' + i.id)}><td className="num">{i.number || 'Draft'}</td><td className="num">{i.invoice_date}</td>
          <td className="r num">{amt(i.total, i.currency)}</td><td className="r num">{money(Number(i.total) - Number(i.amount_paid) - Number(i.amount_credited || 0))}</td><td><Status s={i.status} kind="invoice" /></td></tr>)}</tbody>
      </table></div> : <Empty>No invoices.</Empty>}</Panel>
      <Panel title="Quotes and orders">{quotes.length ? <div className="scroll"><table>
        <thead><tr><th>No.</th><th>Date</th><th className="r">Total</th><th>Status</th></tr></thead>
        <tbody>{quotes.map(x => <tr key={x.id} className="click" onClick={() => nav('/quotes/' + x.id)}><td className="num">{x.number || 'Draft'} <span className="muted">{x.kind === 'order' ? 'order' : ''}</span></td>
          <td className="num">{x.quote_date}</td><td className="r num">{amt(x.total, x.currency)}</td><td><Status s={x.status} /></td></tr>)}</tbody>
      </table></div> : <Empty>No quotes.</Empty>}</Panel>
    </div>}
    {tab === 'deals' && <Panel title="Opportunities" actions={<Link className="btn small" to="/crm">Open pipeline</Link>}>{opps.length ? <div className="scroll"><table>
      <thead><tr><th>Opportunity</th><th>Stage</th><th className="r">Amount</th><th className="r">Probability</th><th>Expected close</th></tr></thead>
      <tbody>{opps.map(o => <tr key={o.id}><td>{o.title}</td><td><Status s={o.stage} /></td><td className="r num">{amt(o.amount, o.currency)}</td><td className="r num">{o.probability}%</td><td className="num">{o.expected_close}</td></tr>)}</tbody>
    </table></div> : <Empty>No opportunities.</Empty>}</Panel>}
    {tab === 'service' && <Panel title="Support cases" actions={<Link className="btn small primary" to={`/cases?new=${id}`}>New case</Link>}>{cases.length ? <div className="scroll"><table>
      <thead><tr><th>Case</th><th>Subject</th><th>Priority</th><th>Status</th><th>Opened</th></tr></thead>
      <tbody>{cases.map(x => <tr key={x.id} className="click" onClick={() => nav('/cases/' + x.id)}><td className="num">{x.number}</td><td>{x.subject}</td><td><Status s={x.priority} /></td><td><Status s={x.status} /></td><td className="num">{x.opened_at.slice(0, 10)}</td></tr>)}</tbody>
    </table></div> : <Empty>No support cases.</Empty>}</Panel>}
    {tab === 'projects' && <Panel title="Projects">{projects.length ? <div className="scroll"><table>
      <tbody>{projects.map(x => <tr key={x.id} className="click" onClick={() => nav('/projects/' + x.id)}><td className="num">{x.number}</td><td>{x.name}</td><td><Status s={x.status} /></td></tr>)}</tbody>
    </table></div> : <Empty>No projects.</Empty>}</Panel>}
    <ActivityList cid={cid} filter={{ customer_id: id! }} team={team} />

    {contact && <FormModal title={contact.id ? 'Edit contact' : 'Add contact'} busy={act.busy} onClose={() => setContact(null)}
      danger={contact.id && <ConfirmButton className="btn danger" label="Delete" confirm="Delete contact?" onConfirm={() => act.run(async () => { await q(supabase.from('customer_contacts').delete().eq('id', contact.id) as any); setContact(null); reload(); })} />}
      onSave={() => act.run(async () => {
        const row = { name: contact.name, job_title: contact.job_title || null, phone: contact.phone || null, email: contact.email || null };
        if (contact.id) await q(supabase.from('customer_contacts').update(row).eq('id', contact.id) as any);
        else await q(supabase.from('customer_contacts').insert({ ...row, company_id: c.company_id, customer_id: id }) as any);
        setContact(null); reload();
      }, 'Contact saved')}>
      <div className="grid-form">
        <Field label="Name" id="ct-name" value={contact.name} onChange={v => setContact({ ...contact, name: v })} required />
        <Field label="Job title" id="ct-job" value={contact.job_title} onChange={v => setContact({ ...contact, job_title: v })} placeholder="e.g. Procurement officer" />
        <Field label="Phone" id="ct-phone" value={contact.phone} onChange={v => setContact({ ...contact, phone: v })} />
        <Field label="Email" id="ct-email" type="email" value={contact.email} onChange={v => setContact({ ...contact, email: v })} />
      </div>
    </FormModal>}
  </>;
}
