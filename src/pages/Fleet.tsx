import { useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { q, rpc, supabase } from '../lib/supabase';
import { useSession } from '../lib/session';
import { cedis, longDate, money, today } from '../lib/format';
import { downloadCsv } from '../lib/download';
import { tablePdf, waybillPdf } from '../lib/pdf';
import { uploadDocFile } from '../components/ProjectDocs';
import { ConfirmButton, Downloads, Empty, Field, FormModal, Loading, PageHead, Panel, Select, useAction, useLoad } from '../components/ui';

// ---------------------------------------------------------------- Shared
export const VEHICLE_TYPES: [string, string][] = [['car', 'Car'], ['pickup', 'Pickup'], ['van', 'Van'], ['truck', 'Truck / tipper'], ['bus', 'Bus'], ['motorbike', 'Motorbike'], ['plant', 'Plant (excavator, loader, grader)'], ['crane', 'Crane'], ['trailer', 'Trailer'], ['other', 'Other']];
const FUELS: [string, string][] = [['diesel', 'Diesel'], ['petrol', 'Petrol'], ['lpg', 'LPG'], ['electric', 'Electric'], ['hybrid', 'Hybrid']];
export const DOC_KINDS: [string, string][] = [['roadworthy', 'DVLA roadworthy certificate'], ['insurance', 'Insurance'], ['road_use', 'Road use fee'], ['registration', 'Registration (DVLA)'], ['permit', 'Permit (axle load, hazardous goods)'], ['tracker', 'Tracker subscription'], ['other', 'Other']];
const V_STATUS: Record<string, [string, string]> = { available: ['Available', 'good'], in_use: ['On a trip', ''], maintenance: ['In the workshop', 'warn'], off_road: ['Off the road', 'bad'], disposed: ['Disposed', ''] };
const TRIP_STATUS: Record<string, [string, string]> = { planned: ['Planned', ''], in_progress: ['On the road', 'warn'], completed: ['Completed', 'good'], cancelled: ['Cancelled', ''] };
const REQ_STATUS: Record<string, [string, string]> = { pending: ['Waiting', 'warn'], approved: ['Vehicle allocated', 'good'], rejected: ['Declined', 'bad'], cancelled: ['Cancelled', ''], done: ['Done', ''] };
const WB_STATUS: Record<string, [string, string]> = { draft: ['Draft', ''], dispatched: ['On the road', 'warn'], delivered: ['Delivered', 'good'], partial: ['Delivered short', 'bad'], cancelled: ['Cancelled', ''] };
const SVC_KINDS: [string, string][] = [['service', 'Scheduled service'], ['repair', 'Repair'], ['tyres', 'Tyres'], ['battery', 'Battery'], ['inspection', 'Inspection'], ['accident', 'Accident repair'], ['bodywork', 'Bodywork'], ['other', 'Other']];
const label = (list: [string, string][], v: string) => list.find(x => x[0] === v)?.[1] || v;
const Pill = ({ map, s }: { map: Record<string, [string, string]>; s: string }) => <span className={'pill ' + (map[s]?.[1] || '')}>{map[s]?.[0] || s}</span>;
const km = (v: any) => v == null || v === '' ? '—' : Number(v).toLocaleString('en-GB', { maximumFractionDigits: 0 });
const n2 = (v: any) => v == null ? '—' : Number(v).toLocaleString('en-GB', { maximumFractionDigits: 2 });
const soon = (d: number) => new Date(Date.now() + d * 864e5).toISOString().slice(0, 10);
const dt = (iso?: string | null) => iso ? iso.slice(0, 16).replace('T', ' ') : '';
const toLocal = (iso?: string | null) => { if (!iso) return ''; const d = new Date(iso); return new Date(d.getTime() - d.getTimezoneOffset() * 6e4).toISOString().slice(0, 16); };
const nowLocal = (addH = 0) => toLocal(new Date(Date.now() + addH * 36e5).toISOString());
const fromLocal = (v: string) => v ? new Date(v).toISOString() : null;
export const serviceDue = (v: any) => (v.service_interval_km && Number(v.odometer) >= Number(v.last_service_km || 0) + Number(v.service_interval_km) - 500)
  || (v.service_interval_months && v.last_service_date && new Date(new Date(v.last_service_date).setMonth(new Date(v.last_service_date).getMonth() + Number(v.service_interval_months))).toISOString().slice(0, 10) <= soon(14));
const vName = (v: any) => v ? `${v.reg_no}${v.make || v.model ? ' · ' + [v.make, v.model].filter(Boolean).join(' ') : ''}` : '';

function useFleet() {
  const { cid, session, can } = useSession();
  const { data, error, loading, reload } = useLoad(async () => {
    const [team, staff, projects, vehicles, drivers] = await Promise.all([
      q<any[]>(supabase.from('memberships').select('user_id,email,role,transport').eq('company_id', cid).order('email') as any).catch(() => [] as any[]),
      q<any[]>(supabase.from('employees').select('id,full_name,user_id,phone').eq('company_id', cid).eq('status', 'active').order('full_name') as any).catch(() => [] as any[]),
      q<any[]>(supabase.from('projects').select('id,number,name,status,location').eq('company_id', cid).eq('is_template', false).order('number', { ascending: false }) as any).catch(() => [] as any[]),
      q<any[]>(supabase.from('vehicles').select('*').eq('company_id', cid).order('reg_no') as any),
      q<any[]>(supabase.from('drivers').select('*').eq('company_id', cid) as any),
    ]);
    return { team, staff, projects, vehicles, drivers };
  }, [cid]);
  const me = session?.user.id;
  const transport = can('accountant', 'store') || !!data?.team.find(m => m.user_id === me)?.transport;
  const myEmp = (data?.staff || []).filter(s => s.user_id === me).map(s => s.id);
  const emp = (id?: string | null) => data?.staff.find(s => s.id === id)?.full_name || '';
  const proj = (id?: string | null) => { const p = data?.projects.find(x => x.id === id); return p ? `${p.number || ''} ${p.name}`.trim() : ''; };
  const veh = (id?: string | null) => data?.vehicles.find(v => v.id === id);
  const projOpts = (first = 'None'): [string, string][] => [['', first], ...(data?.projects || []).filter(p => !['closed', 'cancelled'].includes(p.status)).map(p => [p.id, `${p.number || ''} ${p.name}`.trim()] as [string, string])];
  const driverOpts = (first = '—'): [string, string][] => {
    const ids = new Set((data?.drivers || []).filter(d => d.active).map(d => d.employee_id));
    return [['', first], ...(data?.staff || []).filter(s => ids.has(s.id)).map(s => [s.id, s.full_name] as [string, string]), ...(data?.staff || []).filter(s => !ids.has(s.id)).map(s => [s.id, s.full_name + ' (not a registered driver)'] as [string, string])];
  };
  const vehOpts = (first = 'Choose…', all = false): [string, string][] => [['', first], ...(data?.vehicles || []).filter(v => all || !['disposed', 'off_road'].includes(v.status)).map(v => [v.id, vName(v) + (v.status !== 'available' ? ` (${V_STATUS[v.status][0].toLowerCase()})` : '')] as [string, string])];
  return { cid, data, error, loading, reload, me, transport, myEmp, emp, proj, veh, projOpts, driverOpts, vehOpts };
}
const ago = (d: string) => Math.round((new Date(d).getTime() - new Date(today()).getTime()) / 864e5);

// ---------------------------------------------------------------- Vehicles
const blankVehicle = { reg_no: '', make: '', model: '', year: '', vehicle_type: 'pickup', fuel_type: 'diesel', chassis_no: '', engine_no: '', colour: '', capacity_kg: '', seats: '', odometer: '0', tank_litres: '', expected_km_per_l: '', service_interval_km: '5000', service_interval_months: '6', last_service_km: '', last_service_date: '', driver_id: '', project_id: '', location_id: '', asset_id: '', status: 'available', notes: '' };
function VehicleForm({ f, setF, basics, assets, locs }: { f: any; setF: (v: any) => void; basics: ReturnType<typeof useFleet>; assets: any[]; locs: any[] }) {
  const s = (k: string) => (v: string) => setF({ ...f, [k]: v });
  return <>
    <div className="grid-form">
      <Field label="Registration no." id="vh-r" value={f.reg_no} onChange={v => setF({ ...f, reg_no: v.toUpperCase() })} placeholder="GR 1234-25" required />
      <Select label="Type" id="vh-t" value={f.vehicle_type} onChange={s('vehicle_type')} options={VEHICLE_TYPES} />
      <Field label="Make" id="vh-mk" value={f.make} onChange={s('make')} placeholder="Toyota" />
      <Field label="Model" id="vh-md" value={f.model} onChange={s('model')} placeholder="Hilux 2.4D" />
      <Field label="Year" id="vh-y" type="number" step="1" min="1950" value={f.year} onChange={s('year')} />
      <Select label="Fuel" id="vh-f" value={f.fuel_type} onChange={s('fuel_type')} options={FUELS} />
      <Field label="Mileage now (km)" id="vh-o" type="number" step="1" min="0" value={f.odometer} onChange={s('odometer')} />
      <Field label="Expected km per litre" id="vh-e" type="number" step="0.1" min="0" value={f.expected_km_per_l} onChange={s('expected_km_per_l')} placeholder="e.g. 9 for a pickup" />
      <Field label="Service every (km)" id="vh-si" type="number" step="500" min="0" value={f.service_interval_km} onChange={s('service_interval_km')} />
      <Field label="or every (months)" id="vh-sm" type="number" step="1" min="0" value={f.service_interval_months} onChange={s('service_interval_months')} />
      <Field label="Last service at (km)" id="vh-lk" type="number" step="1" min="0" value={f.last_service_km} onChange={s('last_service_km')} />
      <Field label="Last service date" id="vh-ld" type="date" value={f.last_service_date} onChange={s('last_service_date')} />
      <Select label="Usual driver" id="vh-d" value={f.driver_id} onChange={s('driver_id')} options={basics.driverOpts('None')} />
      <Select label="Assigned to project" id="vh-p" value={f.project_id} onChange={s('project_id')} options={basics.projOpts()} />
      <Select label="Based at" id="vh-l" value={f.location_id} onChange={s('location_id')} options={[['', '—'], ...locs.map(l => [l.id, l.name] as [string, string])]} />
      <Select label="Asset register entry" id="vh-a" value={f.asset_id} onChange={s('asset_id')} options={[['', 'Not linked (e.g. leased)'], ...assets.map(a => [a.id, `${a.tag} ${a.name}`] as [string, string])]} />
    </div>
    <details><summary className="muted" style={{ cursor: 'pointer' }}>Chassis, engine, capacity</summary>
      <div className="grid-form" style={{ marginTop: 10 }}>
        <Field label="Chassis / VIN" id="vh-ch" value={f.chassis_no} onChange={s('chassis_no')} />
        <Field label="Engine no." id="vh-en" value={f.engine_no} onChange={s('engine_no')} />
        <Field label="Colour" id="vh-co" value={f.colour} onChange={s('colour')} />
        <Field label="Payload (kg)" id="vh-ca" type="number" step="1" min="0" value={f.capacity_kg} onChange={s('capacity_kg')} />
        <Field label="Seats" id="vh-se" type="number" step="1" min="0" value={f.seats} onChange={s('seats')} />
        <Field label="Tank (litres)" id="vh-tk" type="number" step="1" min="0" value={f.tank_litres} onChange={s('tank_litres')} />
      </div></details>
    <Field label="Notes" id="vh-n" value={f.notes} onChange={s('notes')} />
  </>;
}
const vehicleRow = (cid: string, f: any) => {
  const num = (v: any) => v === '' || v == null ? null : Number(v);
  return { company_id: cid, reg_no: f.reg_no.trim(), make: f.make || null, model: f.model || null, year: num(f.year), vehicle_type: f.vehicle_type, fuel_type: f.fuel_type, chassis_no: f.chassis_no || null, engine_no: f.engine_no || null,
    colour: f.colour || null, capacity_kg: num(f.capacity_kg), seats: num(f.seats), odometer: num(f.odometer) || 0, tank_litres: num(f.tank_litres), expected_km_per_l: num(f.expected_km_per_l), service_interval_km: num(f.service_interval_km),
    service_interval_months: num(f.service_interval_months), last_service_km: num(f.last_service_km), last_service_date: f.last_service_date || null, driver_id: f.driver_id || null, project_id: f.project_id || null,
    location_id: f.location_id || null, asset_id: f.asset_id || null, status: f.status, notes: f.notes || null };
};
const editable = (v: any) => Object.fromEntries(Object.keys(blankVehicle).map(k => [k, v[k] == null ? '' : String(v[k])]));

export function FleetPage() {
  const b = useFleet();
  const { company } = useSession();
  const act = useAction();
  const nav = useNavigate();
  const [show, setShow] = useState('active');
  const [add, setAdd] = useState<any | null>(null);
  const { data: extra } = useLoad(async () => {
    const [docs, assets, locs, reqs, wbs, flags] = await Promise.all([
      q<any[]>(supabase.from('vehicle_documents').select('vehicle_id,kind,expires_on').eq('company_id', b.cid) as any),
      q<any[]>(supabase.from('assets').select('id,tag,name').eq('company_id', b.cid).eq('status', 'active').order('tag') as any),
      q<any[]>(supabase.from('asset_locations').select('id,name').eq('company_id', b.cid).eq('active', true).order('name') as any).catch(() => [] as any[]),
      q<any[]>(supabase.from('vehicle_requests').select('id').eq('company_id', b.cid).eq('status', 'pending') as any),
      q<any[]>(supabase.from('waybills').select('id').eq('company_id', b.cid).eq('status', 'dispatched') as any),
      q<any[]>(supabase.from('vehicle_fuel').select('id').eq('company_id', b.cid).eq('flagged', true).gte('filled_on', soon(-30)) as any),
    ]);
    return { docs, assets, locs, reqs, wbs, flags };
  }, [b.cid]);
  const latest = (vid: string, kind: string) => (extra?.docs || []).filter(d => d.vehicle_id === vid && d.kind === kind).sort((x, y) => (y.expires_on || '').localeCompare(x.expires_on || ''))[0]?.expires_on;
  const docState = (vid: string) => {
    const off = ['plant', 'crane'].includes(b.veh(vid)?.vehicle_type);   // site plant: insurance only
    const ks = (off ? ['insurance'] : ['roadworthy', 'insurance', 'road_use']).map(k => [k, latest(vid, k)] as [string, string | undefined]);
    const bad = ks.filter(([, d]) => !d || d < today()), warn = ks.filter(([, d]) => d && d >= today() && d <= soon(30));
    return { bad, warn };
  };
  const vs = (b.data?.vehicles || []).filter(v => show === 'all' || (show === 'active' ? v.status !== 'disposed' : show === 'due' ? serviceDue(v) || docState(v.id).bad.length + docState(v.id).warn.length > 0 : v.status === show));
  const head = ['Reg. no.', 'Vehicle', 'Type', 'Driver', 'Project', 'Mileage (km)', 'Status', 'Roadworthy', 'Insurance', 'Road use', 'Service due'];
  const rows = vs.map(v => [v.reg_no, [v.make, v.model, v.year].filter(Boolean).join(' '), label(VEHICLE_TYPES, v.vehicle_type), b.emp(v.driver_id), b.proj(v.project_id), km(v.odometer), V_STATUS[v.status][0],
    latest(v.id, 'roadworthy') || 'missing', latest(v.id, 'insurance') || 'missing', latest(v.id, 'road_use') || 'missing', serviceDue(v) ? 'Yes' : '']);
  const all = b.data?.vehicles.filter(v => v.status !== 'disposed') || [];
  return <>
    <PageHead title="Fleet" sub="Vehicles, plant and their papers. Expiring roadworthy, insurance and road-use documents are flagged 30 days ahead.">
      <Downloads pdf={() => tablePdf({ company: company!, title: 'Fleet register', subtitle: longDate(today()), head, body: rows, landscape: true, rightAlign: [5], filename: 'fleet-' + today() })} csv={() => downloadCsv('fleet-' + today(), head, rows)} />
      {b.transport && <button className="btn primary" type="button" onClick={() => setAdd({ ...blankVehicle })}>Add vehicle</button>}
    </PageHead>
    <Loading error={b.error} loading={b.loading && !b.data} />
    {b.data && <>
      <div className="tiles">
        <div className="tile"><span>Vehicles and plant</span><b>{all.length}</b></div>
        <div className="tile"><span>On a trip now</span><b>{all.filter(v => v.status === 'in_use').length}</b></div>
        <div className="tile"><span>Off the road or in the workshop</span><b>{all.filter(v => ['maintenance', 'off_road'].includes(v.status)).length}</b></div>
        <div className="tile"><Link to="/fleet/requests">Vehicle requests waiting</Link><b>{extra?.reqs.length ?? '…'}</b></div>
        <div className="tile"><Link to="/fleet/waybills">Deliveries on the road</Link><b>{extra?.wbs.length ?? '…'}</b></div>
        <div className="tile"><Link to="/fleet/fuel">Fuel flags (30 days)</Link><b className={extra?.flags.length ? 'bad' : ''}>{extra?.flags.length ?? '…'}</b></div>
      </div>
      <div className="chips">{[['active', 'In the fleet'], ['available', 'Available'], ['in_use', 'On a trip'], ['maintenance', 'Workshop'], ['off_road', 'Off the road'], ['due', 'Needs attention'], ['disposed', 'Disposed'], ['all', 'All']].map(([k, l]) =>
        <button key={k} type="button" className={'chip' + (show === k ? ' on' : '')} onClick={() => setShow(k)}>{l}</button>)}</div>
      <Panel>{vs.length ? <div className="scroll"><table>
        <thead><tr><th>Vehicle</th><th>Driver / project</th><th className="r">Mileage</th><th>Papers</th><th>Status</th></tr></thead>
        <tbody>{vs.map(v => { const d = docState(v.id); return <tr key={v.id} style={{ cursor: 'pointer' }} onClick={() => nav('/fleet/vehicles/' + v.id)}>
          <td><Link to={'/fleet/vehicles/' + v.id}><b>{v.reg_no}</b></Link><br /><span className="muted">{[v.make, v.model, v.year].filter(Boolean).join(' ')} · {label(VEHICLE_TYPES, v.vehicle_type)}</span></td>
          <td>{b.emp(v.driver_id) || <span className="muted">No driver</span>}<br /><span className="muted">{b.proj(v.project_id)}</span></td>
          <td className="r num">{km(v.odometer)}{serviceDue(v) && <><br /><span className="pill warn">service due</span></>}</td>
          <td className="wrap-cell">{d.bad.map(([k, x]) => <span key={k} className="pill bad" style={{ marginRight: 4 }}>{label(DOC_KINDS, k).replace('DVLA ', '').replace(' certificate', '')} {x ? 'expired' : 'missing'}</span>)}
            {d.warn.map(([k, x]) => <span key={k} className="pill warn" style={{ marginRight: 4 }}>{label(DOC_KINDS, k).replace('DVLA ', '').replace(' certificate', '')} {x}</span>)}
            {!d.bad.length && !d.warn.length && <span className="pill good">In order</span>}</td>
          <td><Pill map={V_STATUS} s={v.status} /></td></tr>; })}</tbody></table></div>
        : <Empty>{b.data.vehicles.length ? 'None here.' : 'No vehicles yet. Add your pickups, trucks, plant and motorbikes.'}</Empty>}</Panel>
    </>}
    {add && b.data && <FormModal title="Add vehicle" busy={act.busy} onClose={() => setAdd(null)} onSave={() => act.run(async () => {
      if (!add.reg_no.trim()) throw new Error('Enter the registration number.');
      const v = await q<any>(supabase.from('vehicles').insert(vehicleRow(b.cid, add)).select('id').single() as any);
      setAdd(null); nav('/fleet/vehicles/' + v.id);
    }, 'Vehicle added. Now add its roadworthy, insurance and road-use documents.')}>
      <VehicleForm f={add} setF={setAdd} basics={b} assets={extra?.assets || []} locs={extra?.locs || []} />
    </FormModal>}
  </>;
}

export function VehicleView() {
  const { id } = useParams();
  const b = useFleet();
  const { company } = useSession();
  const act = useAction();
  const [tab, setTab] = useState('trips');
  const [edit, setEdit] = useState<any | null>(null);
  const [doc, setDoc] = useState<any | null>(null);
  const [fuel, setFuel] = useState<any | null>(null);
  const [svc, setSvc] = useState<any | null>(null);
  const [trip, setTrip] = useState<any | null>(null);
  const { data, error, loading, reload } = useLoad(async () => {
    const [docs, trips, fills, svcs, assets, locs] = await Promise.all([
      q<any[]>(supabase.from('vehicle_documents').select('*').eq('vehicle_id', id).order('expires_on', { ascending: false }) as any),
      q<any[]>(supabase.from('vehicle_trips').select('*').eq('vehicle_id', id).order('created_at', { ascending: false }).limit(300) as any),
      q<any[]>(supabase.from('vehicle_fuel').select('*').eq('vehicle_id', id).order('filled_on', { ascending: false }).order('odometer', { ascending: false }).limit(300) as any),
      q<any[]>(supabase.from('vehicle_services').select('*').eq('vehicle_id', id).order('service_date', { ascending: false }) as any),
      q<any[]>(supabase.from('assets').select('id,tag,name').eq('status', 'active').order('tag') as any),
      q<any[]>(supabase.from('asset_locations').select('id,name').eq('active', true).order('name') as any).catch(() => [] as any[]),
    ]);
    return { docs, trips, fills, svcs, assets, locs };
  }, [id]);
  const v = b.veh(id);
  if (!b.data || !data) return <Loading error={b.error || error} loading={b.loading || loading} />;
  if (!v) return <><PageHead title="Vehicle not found" /><Link className="btn" to="/fleet">Back to the fleet</Link></>;
  const done = () => { reload(); b.reload(); };
  const isDriver = b.myEmp.includes(v.driver_id);
  const latest = (k: string) => data.docs.filter(d => d.kind === k)[0];
  const openFile = (p: string) => act.run(async () => { const { data: u, error: e } = await supabase.storage.from('project-docs').createSignedUrl(p, 600); if (e) throw e; window.open(u.signedUrl, '_blank', 'noopener'); });
  const cost = (xs: any[], k = 'cost') => xs.reduce((s, x) => s + Number(x[k] || 0), 0);
  const tripKm = data.trips.filter(t => t.status === 'completed').reduce((s, t) => s + Number(t.distance_km || 0), 0);
  const nextKm = v.service_interval_km ? Number(v.last_service_km || 0) + Number(v.service_interval_km) : null;
  return <>
    <PageHead title={v.reg_no} sub={<><Pill map={V_STATUS} s={v.status} /> <span className="muted">· {[v.make, v.model, v.year].filter(Boolean).join(' ')} · {label(VEHICLE_TYPES, v.vehicle_type)} · {label(FUELS, v.fuel_type)}</span></>}>
      <Link className="btn" to="/fleet">Back</Link>
      {(b.transport || isDriver) && <button className="btn" type="button" onClick={() => setFuel({ filled_on: today(), litres: '', cost: '', odometer: '', full_tank: true, station: '', paid_by: 'cash', project_id: v.project_id || '', note: '', file: null })}>Log fuel</button>}
      {b.transport && <>
        <button className="btn" type="button" onClick={() => setTrip({ driver_id: v.driver_id || '', project_id: v.project_id || '', purpose: '', origin: '', destination: '', passengers: '', load_desc: '' })}>New trip</button>
        <button className="btn" type="button" onClick={() => setSvc({ service_date: today(), odometer: String(v.odometer), kind: 'service', description: '', vendor: '', cost: '', parts: '', downtime_days: '', next_due_km: nextKm ? String(Number(v.odometer) + Number(v.service_interval_km)) : '', next_due_date: '' })}>Job card</button>
        <button className="btn" type="button" onClick={() => setDoc({ kind: 'roadworthy', reference: '', provider: '', issued_on: today(), expires_on: '', cost: '', file: null })}>Add document</button>
        <button className="btn" type="button" onClick={() => setEdit(editable(v))}>Edit</button></>}
    </PageHead>
    <div className="tiles">
      <div className="tile"><span>Mileage</span><b>{km(v.odometer)} km</b></div>
      <div className="tile"><span>Next service</span><b className={serviceDue(v) ? 'bad' : ''} style={{ fontSize: 16 }}>{nextKm ? `${km(nextKm)} km` : '—'}{v.last_service_date && v.service_interval_months ? ` or ${new Date(new Date(v.last_service_date).setMonth(new Date(v.last_service_date).getMonth() + Number(v.service_interval_months))).toISOString().slice(0, 10)}` : ''}</b></div>
      <div className="tile"><span>Fuel economy (recent)</span><b>{(xs => xs.length ? n2(xs.reduce((s, f) => s + Number(f.km_per_l), 0) / xs.length) + ' km/l' : '—')(data.fills.filter(f => f.km_per_l).slice(0, 5))}</b></div>
      <div className="tile"><span>Running cost (all time)</span><b>{cedis(cost(data.fills) + cost(data.svcs) + cost(data.docs))}</b></div>
    </div>
    <Panel pad><div className="grid-form">
      <div><div className="label">Driver</div>{b.emp(v.driver_id) || '—'}</div>
      <div><div className="label">Project</div>{v.project_id ? <Link to={'/projects/' + v.project_id}>{b.proj(v.project_id)}</Link> : '—'}</div>
      <div><div className="label">Asset register</div>{v.asset_id ? <Link to={'/assets/' + v.asset_id}>{(a => a ? `${a.tag} ${a.name}` : 'Open')(data.assets.find(a => a.id === v.asset_id))}</Link> : 'Not linked'}</div>
      {['roadworthy', 'insurance', 'road_use'].map(k => { const d = latest(k); return <div key={k}><div className="label">{label(DOC_KINDS, k)}</div>
        {d ? <span className={d.expires_on < today() ? 'pill bad' : d.expires_on <= soon(30) ? 'pill warn' : ''}>{d.expires_on ? `to ${d.expires_on}` : 'no expiry'}{d.expires_on && d.expires_on < today() ? ' expired' : ''}</span> : <span className="pill bad">missing</span>}</div>; })}
      <div><div className="label">Chassis / engine</div>{[v.chassis_no, v.engine_no].filter(Boolean).join(' · ') || '—'}</div>
      <div><div className="label">Expected economy</div>{v.expected_km_per_l ? `${v.expected_km_per_l} km/l (below ${n2(v.expected_km_per_l * 0.8)} is flagged)` : 'Not set'}</div>
    </div>{v.notes && <p className="muted">{v.notes}</p>}
      {b.transport && <div className="actions" style={{ marginTop: 10 }}>{v.status !== 'in_use' && <Select label="Status" id="vv-st" value={v.status} onChange={s => act.run(async () => { await q(supabase.from('vehicles').update({ status: s }).eq('id', v.id) as any); done(); }, 'Status changed')}
        options={Object.entries(V_STATUS).filter(([k]) => k !== 'in_use').map(([k, [l]]) => [k, l] as [string, string])} />}</div>}
    </Panel>
    <div className="chips">{[['trips', `Trips (${data.trips.length})`], ['fuel', `Fuel (${data.fills.length})`], ['service', `Service and repairs (${data.svcs.length})`], ['docs', `Documents (${data.docs.length})`]].map(([k, l]) =>
      <button key={k} type="button" className={'chip' + (tab === k ? ' on' : '')} onClick={() => setTab(k)}>{l}</button>)}</div>
    {tab === 'trips' && <Panel title={`${km(tripKm)} km on completed trips`}><TripTable trips={data.trips} b={b} onDone={done} /></Panel>}
    {tab === 'fuel' && <Panel title={`${n2(cost(data.fills, 'litres'))} litres · ${cedis(cost(data.fills))}`}><FuelTable fills={data.fills} b={b} /></Panel>}
    {tab === 'service' && <Panel title={`${cedis(cost(data.svcs))} · ${n2(cost(data.svcs, 'downtime_days'))} days off the road`}
      actions={data.svcs.length > 0 && <Downloads pdf={() => tablePdf({ company: company!, title: `Service history: ${v.reg_no}`, subtitle: [v.make, v.model].filter(Boolean).join(' '), head: ['Job', 'Date', 'Mileage', 'Kind', 'Work done', 'Vendor', 'Cost (GHS)'],
        body: data.svcs.map(s => [s.number || '', s.service_date, km(s.odometer), label(SVC_KINDS, s.kind), s.description, s.vendor || '', money(s.cost)]), rightAlign: [2, 6], filename: `service-${v.reg_no}` })} />}>
      {data.svcs.length ? <div className="scroll"><table><tbody>{data.svcs.map(s => <tr key={s.id}>
        <td className="num">{s.number}<br /><span className="muted">{s.service_date}</span></td><td className="r num">{km(s.odometer)} km</td>
        <td className="wrap-cell"><b style={{ fontWeight: 600 }}>{label(SVC_KINDS, s.kind)}</b> · {s.description}<br /><span className="muted">{[s.vendor, s.parts, s.downtime_days && `${s.downtime_days} days off the road`, s.next_due_km && `next at ${km(s.next_due_km)} km`].filter(Boolean).join(' · ')}</span></td>
        <td className="r num">{money(s.cost)}</td></tr>)}</tbody></table></div> : <Empty>No service or repairs logged.</Empty>}</Panel>}
    {tab === 'docs' && <Panel>{data.docs.length ? <div className="scroll"><table><tbody>{data.docs.map(d => { const cur = latest(d.kind)?.id === d.id; return <tr key={d.id} style={cur ? undefined : { opacity: .6 }}>
      <td><b>{label(DOC_KINDS, d.kind)}</b>{!cur && <span className="muted"> (replaced)</span>}<br /><span className="muted">{[d.reference, d.provider].filter(Boolean).join(' · ')}</span></td>
      <td className="num">{d.issued_on || ''} → {d.expires_on ? <span className={cur && d.expires_on < today() ? 'pill bad' : cur && d.expires_on <= soon(30) ? 'pill warn' : ''}>{d.expires_on}</span> : 'no expiry'}</td>
      <td className="r num">{d.cost ? money(d.cost) : ''}</td>
      <td className="r">{d.storage_path && <button className="btn small" type="button" onClick={() => openFile(d.storage_path)}>View</button>}{' '}
        {b.transport && cur && <button className="btn small" type="button" onClick={() => setDoc({ kind: d.kind, reference: '', provider: d.provider || '', issued_on: today(), expires_on: '', cost: '', file: null })}>Renew</button>}</td></tr>; })}</tbody></table></div>
      : <Empty>No documents. Add the DVLA roadworthy certificate, insurance and road-use fee so you are reminded before they expire.</Empty>}</Panel>}

    {edit && <FormModal title={`Edit ${v.reg_no}`} busy={act.busy} onClose={() => setEdit(null)} onSave={() => act.run(async () => { await q(supabase.from('vehicles').update(vehicleRow(b.cid, edit)).eq('id', v.id) as any); setEdit(null); done(); }, 'Saved')}>
      <VehicleForm f={edit} setF={setEdit} basics={b} assets={data.assets} locs={data.locs} />
    </FormModal>}
    {doc && <FormModal title={`${label(DOC_KINDS, doc.kind)} for ${v.reg_no}`} busy={act.busy} onClose={() => setDoc(null)} onSave={() => act.run(async () => {
      if (!doc.expires_on && doc.kind !== 'registration') throw new Error('Enter the expiry date so you can be reminded.');
      let path: string | null = null; if (doc.file) path = (await uploadDocFile(b.cid, 'fleet', doc.file)).path;
      await q(supabase.from('vehicle_documents').insert({ company_id: b.cid, vehicle_id: v.id, kind: doc.kind, reference: doc.reference || null, provider: doc.provider || null, issued_on: doc.issued_on || null, expires_on: doc.expires_on || null, cost: doc.cost ? Number(doc.cost) : null, storage_path: path }) as any);
      setDoc(null); done(); }, 'Document saved')}>
      <div className="grid-form">
        <Select label="Document" id="vd-k" value={doc.kind} onChange={x => setDoc({ ...doc, kind: x })} options={DOC_KINDS} />
        <Field label="Certificate / policy no." id="vd-r" value={doc.reference} onChange={x => setDoc({ ...doc, reference: x })} />
        <Field label="Issued by" id="vd-p" value={doc.provider} onChange={x => setDoc({ ...doc, provider: x })} placeholder={doc.kind === 'insurance' ? 'e.g. Enterprise Insurance' : 'e.g. DVLA Tema'} />
        <Field label="Cost (GH₵)" id="vd-c" type="number" step="0.01" min="0" value={doc.cost} onChange={x => setDoc({ ...doc, cost: x })} />
        <Field label="Issued" id="vd-i" type="date" value={doc.issued_on} onChange={x => setDoc({ ...doc, issued_on: x })} />
        <Field label="Expires" id="vd-x" type="date" value={doc.expires_on} onChange={x => setDoc({ ...doc, expires_on: x })} />
      </div>
      <div className="field"><label htmlFor="vd-f">Scan or photo (optional)</label><input id="vd-f" type="file" accept="image/*,.pdf" onChange={e => setDoc({ ...doc, file: e.target.files?.[0] || null })} /></div>
      <p className="muted" style={{ margin: 0, fontSize: 13 }}>The transport officer is reminded 30 days and 7 days before expiry, and when it lapses. Adding a newer one replaces the old one. Record the payment itself as a bill or expense.</p>
    </FormModal>}
    {fuel && <FuelForm f={fuel} setF={setFuel} vehicle={v} b={b} onClose={() => setFuel(null)} onDone={() => { setFuel(null); done(); }} />}
    {svc && <FormModal title={`Job card for ${v.reg_no}`} busy={act.busy} onClose={() => setSvc(null)} onSave={() => act.run(async () => {
      if (!svc.description.trim()) throw new Error('Describe the work done.');
      await q(supabase.from('vehicle_services').insert({ company_id: b.cid, vehicle_id: v.id, service_date: svc.service_date, odometer: svc.odometer ? Number(svc.odometer) : null, kind: svc.kind, description: svc.description, vendor: svc.vendor || null,
        cost: Number(svc.cost) || 0, parts: svc.parts || null, downtime_days: svc.downtime_days ? Number(svc.downtime_days) : null, next_due_km: svc.next_due_km ? Number(svc.next_due_km) : null, next_due_date: svc.next_due_date || null }) as any);
      setSvc(null); done(); }, 'Job card saved')}>
      <div className="grid-form">
        <Select label="Kind" id="sv-k" value={svc.kind} onChange={x => setSvc({ ...svc, kind: x })} options={SVC_KINDS} />
        <Field label="Date" id="sv-d" type="date" value={svc.service_date} onChange={x => setSvc({ ...svc, service_date: x })} required />
        <Field label="Mileage (km)" id="sv-o" type="number" step="1" min="0" value={svc.odometer} onChange={x => setSvc({ ...svc, odometer: x })} />
        <Field label="Workshop" id="sv-v" value={svc.vendor} onChange={x => setSvc({ ...svc, vendor: x })} placeholder="e.g. Toyota Ghana, own mechanic" />
        <Field label="Cost (GH₵)" id="sv-c" type="number" step="0.01" min="0" value={svc.cost} onChange={x => setSvc({ ...svc, cost: x })} />
        <Field label="Days off the road" id="sv-dt" type="number" step="0.5" min="0" value={svc.downtime_days} onChange={x => setSvc({ ...svc, downtime_days: x })} />
        <Field label="Next due at (km)" id="sv-nk" type="number" step="1" min="0" value={svc.next_due_km} onChange={x => setSvc({ ...svc, next_due_km: x })} />
        <Field label="or next due date" id="sv-nd" type="date" value={svc.next_due_date} onChange={x => setSvc({ ...svc, next_due_date: x })} />
      </div>
      <Field label="Work done" id="sv-w" type="textarea" value={svc.description} onChange={x => setSvc({ ...svc, description: x })} placeholder="e.g. 10,000 km service: oil, oil filter, air filter; front brake pads" required />
      <Field label="Parts used" id="sv-p" value={svc.parts} onChange={x => setSvc({ ...svc, parts: x })} />
      <p className="muted" style={{ margin: 0, fontSize: 13 }}>A scheduled service resets the service counter. Record the payment as a supplier bill or expense to 6500 Repairs and maintenance.</p>
    </FormModal>}
    {trip && <TripForm t={trip} setT={setTrip} vehicle={v} b={b} onClose={() => setTrip(null)} onDone={() => { setTrip(null); done(); }} />}
  </>;
}

function FuelForm({ f, setF, vehicle, b, onClose, onDone, vehicles }: { f: any; setF: (v: any) => void; vehicle?: any; b: ReturnType<typeof useFleet>; onClose: () => void; onDone: () => void; vehicles?: [string, string][] }) {
  const act = useAction();
  const v = vehicle || b.veh(f.vehicle_id);
  return <FormModal title={`Log fuel${v ? ' for ' + v.reg_no : ''}`} busy={act.busy} onClose={onClose} onSave={() => act.run(async () => {
    if (!v) throw new Error('Choose the vehicle.');
    if (!(Number(f.litres) > 0)) throw new Error('Enter the litres.');
    let path: string | null = null; if (f.file) path = (await uploadDocFile(b.cid, 'fleet', f.file)).path;
    await q(supabase.from('vehicle_fuel').insert({ company_id: b.cid, vehicle_id: v.id, filled_on: f.filled_on, litres: Number(f.litres), cost: Number(f.cost) || 0, odometer: f.odometer ? Number(f.odometer) : null,
      full_tank: f.full_tank, station: f.station || null, paid_by: f.paid_by, project_id: f.project_id || null, receipt_path: path, note: f.note || null }) as any);
    onDone(); }, 'Fuel logged')}>
    {vehicles && <Select label="Vehicle" id="fu-v" value={f.vehicle_id} onChange={x => setF({ ...f, vehicle_id: x })} options={vehicles} />}
    <div className="grid-form">
      <Field label="Date" id="fu-d" type="date" value={f.filled_on} onChange={x => setF({ ...f, filled_on: x })} required />
      <Field label="Litres" id="fu-l" type="number" step="0.01" min="0.01" value={f.litres} onChange={x => setF({ ...f, litres: x })} required />
      <Field label="Amount paid (GH₵)" id="fu-c" type="number" step="0.01" min="0" value={f.cost} onChange={x => setF({ ...f, cost: x })} />
      <Field label={`Mileage now${v ? ` (last ${km(v.odometer)})` : ''}`} id="fu-o" type="number" step="1" min="0" value={f.odometer} onChange={x => setF({ ...f, odometer: x })} />
      <Field label="Filling station" id="fu-s" value={f.station} onChange={x => setF({ ...f, station: x })} placeholder="e.g. GOIL Spintex" />
      <Select label="Paid by" id="fu-p" value={f.paid_by} onChange={x => setF({ ...f, paid_by: x })} options={[['cash', 'Cash'], ['fuel_card', 'Fuel card / coupon'], ['account', 'Station account'], ['advance', 'Driver advance'], ['petty_cash', 'Petty cash'], ['other', 'Other']]} />
      <Select label="For project" id="fu-pj" value={f.project_id} onChange={x => setF({ ...f, project_id: x })} options={b.projOpts()} />
    </div>
    <label className="check"><input type="checkbox" checked={f.full_tank} onChange={e => setF({ ...f, full_tank: e.target.checked })} /> Filled to full (needed to work out km per litre)</label>
    <div className="field"><label htmlFor="fu-r">Receipt photo</label><input id="fu-r" type="file" accept="image/*,.pdf" capture="environment" onChange={e => setF({ ...f, file: e.target.files?.[0] || null })} /></div>
    <p className="muted" style={{ margin: 0, fontSize: 13 }}>With the mileage on two full tanks, Asnys works out km per litre and flags it if it is 20% worse than expected. The litres also count in the CO2 figures. This log does not post to the books; record the fuel bill or expense as usual.</p>
  </FormModal>;
}
function FuelTable({ fills, b, showVehicle }: { fills: any[]; b: ReturnType<typeof useFleet>; showVehicle?: boolean }) {
  const act = useAction();
  const open = (p: string) => act.run(async () => { const { data: u, error: e } = await supabase.storage.from('project-docs').createSignedUrl(p, 600); if (e) throw e; window.open(u.signedUrl, '_blank', 'noopener'); });
  return fills.length ? <div className="scroll"><table>
    <thead><tr><th>Date</th>{showVehicle && <th>Vehicle</th>}<th className="r">Litres</th><th className="r">GH₵</th><th className="r">Mileage</th><th className="r">km/l</th><th>Where / who</th><th></th></tr></thead>
    <tbody>{fills.map(f => <tr key={f.id}>
      <td className="num">{f.filled_on}</td>{showVehicle && <td><Link to={'/fleet/vehicles/' + f.vehicle_id}>{b.veh(f.vehicle_id)?.reg_no}</Link></td>}
      <td className="r num">{n2(f.litres)}{!f.full_tank && <span className="muted"> part</span>}</td><td className="r num">{money(f.cost)}</td><td className="r num">{km(f.odometer)}</td>
      <td className="r num">{f.km_per_l ? <span className={f.flagged ? 'pill bad' : ''}>{n2(f.km_per_l)}</span> : ''}</td>
      <td className="muted">{[f.station, b.emp(f.driver_id), b.proj(f.project_id)].filter(Boolean).join(' · ')}</td>
      <td className="r">{f.receipt_path && <button className="btn small" type="button" onClick={() => open(f.receipt_path)}>Receipt</button>}</td></tr>)}</tbody></table></div> : <Empty>No fuel logged.</Empty>;
}

// ---------------------------------------------------------------- Trips
function TripForm({ t, setT, vehicle, b, onClose, onDone }: { t: any; setT: (v: any) => void; vehicle?: any; b: ReturnType<typeof useFleet>; onClose: () => void; onDone: () => void }) {
  const act = useAction();
  return <FormModal title={vehicle ? `New trip for ${vehicle.reg_no}` : 'New trip'} busy={act.busy} onClose={onClose} onSave={() => act.run(async () => {
    const vid = vehicle?.id || t.vehicle_id;
    if (!vid) throw new Error('Choose the vehicle.');
    if (!t.purpose.trim()) throw new Error('Say what the trip is for.');
    await q(supabase.from('vehicle_trips').insert({ company_id: b.cid, vehicle_id: vid, driver_id: t.driver_id || null, project_id: t.project_id || null, request_id: t.request_id || null, purpose: t.purpose, origin: t.origin || null, destination: t.destination || null,
      passengers: t.passengers ? Number(t.passengers) : null, load_desc: t.load_desc || null }) as any);
    onDone(); }, 'Trip planned. The driver starts it with the mileage when leaving.')}>
    {!vehicle && <Select label="Vehicle" id="tp-v" value={t.vehicle_id} onChange={x => setT({ ...t, vehicle_id: x, driver_id: t.driver_id || b.veh(x)?.driver_id || '' })} options={b.vehOpts()} />}
    <div className="grid-form">
      <Select label="Driver" id="tp-d" value={t.driver_id} onChange={x => setT({ ...t, driver_id: x })} options={b.driverOpts()} />
      <Select label="Project" id="tp-p" value={t.project_id} onChange={x => setT({ ...t, project_id: x })} options={b.projOpts()} />
      <Field label="From" id="tp-o" value={t.origin} onChange={x => setT({ ...t, origin: x })} placeholder="e.g. Head office yard" />
      <Field label="To" id="tp-to" value={t.destination} onChange={x => setT({ ...t, destination: x })} placeholder="e.g. Prestea site" />
      <Field label="Passengers" id="tp-pa" type="number" step="1" min="0" value={t.passengers} onChange={x => setT({ ...t, passengers: x })} />
      <Field label="Load" id="tp-l" value={t.load_desc} onChange={x => setT({ ...t, load_desc: x })} />
    </div>
    <Field label="Purpose" id="tp-pu" value={t.purpose} onChange={x => setT({ ...t, purpose: x })} placeholder="e.g. Deliver rebar to site; staff pickup" required />
  </FormModal>;
}
function TripTable({ trips, b, onDone, showVehicle }: { trips: any[]; b: ReturnType<typeof useFleet>; onDone: () => void; showVehicle?: boolean }) {
  const act = useAction();
  const [step, setStep] = useState<any | null>(null);
  return <>
    {trips.length ? <div className="scroll"><table>
      <thead><tr><th>Trip</th>{showVehicle && <th>Vehicle</th>}<th>Route / purpose</th><th>Driver</th><th className="r">km</th><th>Status</th><th></th></tr></thead>
      <tbody>{trips.map(t => { const mine = b.transport || b.myEmp.includes(t.driver_id); const v = b.veh(t.vehicle_id); return <tr key={t.id}>
        <td className="num"><b>{t.number}</b><br /><span className="muted">{dt(t.start_at) || dt(t.created_at)}</span></td>
        {showVehicle && <td><Link to={'/fleet/vehicles/' + t.vehicle_id}>{v?.reg_no}</Link></td>}
        <td className="wrap-cell">{[t.origin, t.destination].filter(Boolean).join(' → ')}<br /><span className="muted">{t.purpose}{t.project_id ? ' · ' + b.proj(t.project_id) : ''}</span></td>
        <td>{b.emp(t.driver_id) || '—'}</td>
        <td className="r num">{t.distance_km != null ? km(t.distance_km) : t.odometer_start ? `from ${km(t.odometer_start)}` : ''}</td>
        <td><Pill map={TRIP_STATUS} s={t.status} />{t.out_of_hours && <><br /><span className="pill warn" title="Started at a weekend or outside 6:00–18:00">out of hours</span></>}</td>
        <td className="r" style={{ whiteSpace: 'nowrap' }}>{mine && t.status === 'planned' && <button className="btn small primary" type="button" onClick={() => setStep({ t, action: 'start', odometer: v ? String(v.odometer) : '', note: '' })}>Start</button>}
          {mine && t.status === 'in_progress' && <button className="btn small primary" type="button" onClick={() => setStep({ t, action: 'finish', odometer: '', note: '' })}>Finish</button>}{' '}
          {b.transport && ['planned', 'in_progress'].includes(t.status) && <ConfirmButton className="btn small ghost" label="Cancel" confirm={`Cancel ${t.number}?`} onConfirm={() => act.run(async () => { await rpc('trip_step', { p_trip: t.id, p_action: 'cancel' }); onDone(); }, 'Cancelled')} />}</td></tr>; })}</tbody></table></div>
      : <Empty>No trips.</Empty>}
    {step && <FormModal title={`${step.action === 'start' ? 'Start' : 'Finish'} ${step.t.number}`} submit={step.action === 'start' ? 'Start trip' : 'Finish trip'} busy={act.busy} onClose={() => setStep(null)}
      onSave={() => act.run(async () => { await rpc('trip_step', { p_trip: step.t.id, p_action: step.action, p_odometer: step.odometer === '' ? null : Number(step.odometer), p_note: step.note || null }); setStep(null); onDone(); }, step.action === 'start' ? 'Safe journey' : 'Trip completed')}>
      <Field label={`Mileage on the dashboard (km)${step.action === 'finish' ? `, started at ${km(step.t.odometer_start)}` : ''}`} id="ts-o" type="number" step="1" min="0" value={step.odometer} onChange={x => setStep({ ...step, odometer: x })} required />
      {step.action === 'finish' && <Field label="Note (delays, fuel bought, faults noticed)" id="ts-n" value={step.note} onChange={x => setStep({ ...step, note: x })} />}
    </FormModal>}
  </>;
}
export function TripsPage() {
  const b = useFleet();
  const { company } = useSession();
  const [show, setShow] = useState('open');
  const [add, setAdd] = useState<any | null>(null);
  const { data, error, loading, reload } = useLoad(() => q<any[]>(supabase.from('vehicle_trips').select('*').eq('company_id', b.cid).order('created_at', { ascending: false }).limit(1000) as any), [b.cid]);
  const F: [string, string, (t: any) => boolean][] = [['open', 'Planned or on the road', t => ['planned', 'in_progress'].includes(t.status)], ['mine', 'My trips', t => b.myEmp.includes(t.driver_id)],
    ['done', 'Completed', t => t.status === 'completed'], ['ooh', 'Out of hours', t => t.out_of_hours], ['all', 'All', () => true]];
  const list = (data || []).filter((F.find(f => f[0] === show) || F[0])[2]);
  const head = ['Trip', 'Date', 'Vehicle', 'Driver', 'From', 'To', 'Purpose', 'Project', 'Start km', 'End km', 'Distance', 'Status'];
  const rows = list.map(t => [t.number, (t.start_at || t.created_at).slice(0, 10), b.veh(t.vehicle_id)?.reg_no || '', b.emp(t.driver_id), t.origin || '', t.destination || '', t.purpose, b.proj(t.project_id), km(t.odometer_start), km(t.odometer_end), km(t.distance_km), TRIP_STATUS[t.status][0]]);
  return <>
    <PageHead title="Trip log" sub="Every journey with its mileage. Drivers start and finish their own trips from their phone.">
      <Downloads pdf={() => tablePdf({ company: company!, title: 'Trip log', subtitle: longDate(today()), head, body: rows, landscape: true, rightAlign: [8, 9, 10], filename: 'trips-' + today() })} csv={() => downloadCsv('trips-' + today(), head, rows)} />
      {b.transport && <button className="btn primary" type="button" onClick={() => setAdd({ vehicle_id: '', driver_id: '', project_id: '', purpose: '', origin: '', destination: '', passengers: '', load_desc: '' })}>New trip</button>}
    </PageHead>
    <Loading error={error || b.error} loading={(loading && !data) || !b.data} />
    {data && b.data && <>
      <div className="chips">{F.map(([k, l, fn]) => <button key={k} type="button" className={'chip' + (show === k ? ' on' : '')} onClick={() => setShow(k)}>{l} <span>{data.filter(fn).length}</span></button>)}</div>
      <Panel><TripTable trips={list} b={b} onDone={() => { reload(); b.reload(); }} showVehicle /></Panel>
    </>}
    {add && <TripForm t={add} setT={setAdd} b={b} onClose={() => setAdd(null)} onDone={() => { setAdd(null); reload(); }} />}
  </>;
}

// ---------------------------------------------------------------- Fuel log
export function FuelPage() {
  const b = useFleet();
  const { company } = useSession();
  const [show, setShow] = useState('30');
  const [add, setAdd] = useState<any | null>(null);
  const { data, error, loading, reload } = useLoad(() => q<any[]>(supabase.from('vehicle_fuel').select('*').eq('company_id', b.cid).order('filled_on', { ascending: false }).order('created_at', { ascending: false }).limit(2000) as any), [b.cid]);
  const F: [string, string, (f: any) => boolean][] = [['30', 'Last 30 days', f => f.filled_on >= soon(-30)], ['flag', 'Flagged', f => f.flagged], ['month', 'This month', f => f.filled_on >= today().slice(0, 8) + '01'], ['all', 'All', () => true]];
  const list = (data || []).filter((F.find(f => f[0] === show) || F[0])[2]);
  const head = ['Date', 'Vehicle', 'Litres', 'GHS', 'Mileage', 'km/l', 'Flag', 'Station', 'Driver', 'Project', 'Paid by'];
  const rows = list.map(f => [f.filled_on, b.veh(f.vehicle_id)?.reg_no || '', n2(f.litres), money(f.cost), km(f.odometer), f.km_per_l ? n2(f.km_per_l) : '', f.flagged ? 'High use' : '', f.station || '', b.emp(f.driver_id), b.proj(f.project_id), f.paid_by]);
  const tot = list.reduce((s, f) => ({ l: s.l + Number(f.litres), c: s.c + Number(f.cost) }), { l: 0, c: 0 });
  const mine = (b.data?.vehicles || []).filter(v => b.transport || b.myEmp.includes(v.driver_id));
  return <>
    <PageHead title="Fuel log" sub={`${n2(tot.l)} litres · ${cedis(tot.c)}${tot.l ? ` · GH₵ ${n2(tot.c / tot.l)} a litre` : ''}`}>
      <Downloads pdf={() => tablePdf({ company: company!, title: 'Fuel log', subtitle: (F.find(f => f[0] === show) || F[0])[1], head, body: rows, landscape: true, rightAlign: [2, 3, 4, 5], foot: ['Total', '', n2(tot.l), money(tot.c), '', '', '', '', '', '', ''], filename: 'fuel-' + today() })} csv={() => downloadCsv('fuel-' + today(), head, rows)} />
      {mine.length > 0 && <button className="btn primary" type="button" onClick={() => setAdd({ vehicle_id: mine.length === 1 ? mine[0].id : '', filled_on: today(), litres: '', cost: '', odometer: '', full_tank: true, station: '', paid_by: 'cash', project_id: '', note: '', file: null })}>Log fuel</button>}
    </PageHead>
    <Loading error={error || b.error} loading={(loading && !data) || !b.data} />
    {data && b.data && <>
      <div className="chips">{F.map(([k, l, fn]) => <button key={k} type="button" className={'chip' + (show === k ? ' on' : '')} onClick={() => setShow(k)}>{l} <span>{data.filter(fn).length}</span></button>)}</div>
      <Panel><FuelTable fills={list} b={b} showVehicle /></Panel>
    </>}
    {add && <FuelForm f={add} setF={setAdd} b={b} vehicles={[['', 'Choose…'], ...mine.map(v => [v.id, vName(v)] as [string, string])]} onClose={() => setAdd(null)} onDone={() => { setAdd(null); reload(); b.reload(); }} />}
  </>;
}

// ---------------------------------------------------------------- Service and repairs
export function FleetServicePage() {
  const b = useFleet();
  const { company } = useSession();
  const { data, error, loading } = useLoad(() => q<any[]>(supabase.from('vehicle_services').select('*').eq('company_id', b.cid).order('service_date', { ascending: false }).limit(1000) as any), [b.cid]);
  const due = (b.data?.vehicles || []).filter(v => v.status !== 'disposed' && serviceDue(v));
  const head = ['Job', 'Date', 'Vehicle', 'Mileage', 'Kind', 'Work done', 'Workshop', 'Days off road', 'Cost (GHS)'];
  const rows = (data || []).map(s => [s.number || '', s.service_date, b.veh(s.vehicle_id)?.reg_no || '', km(s.odometer), label(SVC_KINDS, s.kind), s.description, s.vendor || '', s.downtime_days || '', money(s.cost)]);
  return <>
    <PageHead title="Service and repairs" sub="Job cards for every service and repair. Services fall due by mileage or by date, whichever comes first.">
      <Downloads pdf={() => tablePdf({ company: company!, title: 'Fleet service and repairs', subtitle: longDate(today()), head, body: rows, landscape: true, rightAlign: [3, 7, 8], filename: 'fleet-service-' + today() })} csv={() => downloadCsv('fleet-service-' + today(), head, rows)} />
    </PageHead>
    <Loading error={error || b.error} loading={(loading && !data) || !b.data} />
    {b.data && <Panel title={`Service due (${due.length})`}>{due.length ? <div className="scroll"><table><tbody>{due.map(v => <tr key={v.id}>
      <td><Link to={'/fleet/vehicles/' + v.id}><b>{v.reg_no}</b></Link> {[v.make, v.model].filter(Boolean).join(' ')}</td>
      <td className="num">{km(v.odometer)} km now</td>
      <td className="num">{v.service_interval_km ? `due at ${km(Number(v.last_service_km || 0) + Number(v.service_interval_km))} km` : ''}{v.last_service_date ? ` · last ${v.last_service_date}` : ''}</td></tr>)}</tbody></table></div>
      : <Empty>Nothing due in the next 500 km or two weeks.</Empty>}</Panel>}
    {data && b.data && <Panel title="Job cards">{data.length ? <div className="scroll"><table><tbody>{data.map(s => <tr key={s.id}>
      <td className="num">{s.number}<br /><span className="muted">{s.service_date}</span></td><td><Link to={'/fleet/vehicles/' + s.vehicle_id}>{b.veh(s.vehicle_id)?.reg_no}</Link><br /><span className="muted">{km(s.odometer)} km</span></td>
      <td className="wrap-cell"><b style={{ fontWeight: 600 }}>{label(SVC_KINDS, s.kind)}</b> · {s.description}<br /><span className="muted">{[s.vendor, s.downtime_days && `${s.downtime_days} days off the road`].filter(Boolean).join(' · ')}</span></td>
      <td className="r num">{money(s.cost)}</td></tr>)}</tbody></table></div> : <Empty>No job cards yet. Open a vehicle and press Job card.</Empty>}</Panel>}
  </>;
}

// ---------------------------------------------------------------- Drivers
export function DriversPage() {
  const b = useFleet();
  const { company } = useSession();
  const act = useAction();
  const [edit, setEdit] = useState<any | null>(null);
  const ds = b.data?.drivers || [];
  const head = ['Driver', 'Licence no.', 'Class', 'Licence expires', 'Defensive driving', 'Medical expires', 'Vehicles', 'Active'];
  const rows = ds.map(d => [b.emp(d.employee_id), d.licence_no || '', d.licence_class || '', d.licence_expiry || '', d.defensive_training_on || '', d.medical_expiry || '', (b.data?.vehicles || []).filter(v => v.driver_id === d.employee_id).map(v => v.reg_no).join(', '), d.active ? 'Yes' : 'No']);
  return <>
    <PageHead title="Drivers" sub="Driving licences (DVLA class), defensive-driving training and medicals, with reminders 30 days before a licence expires.">
      <Downloads pdf={() => tablePdf({ company: company!, title: 'Drivers', subtitle: longDate(today()), head, body: rows, landscape: true, filename: 'drivers-' + today() })} csv={() => downloadCsv('drivers-' + today(), head, rows)} />
      {b.transport && <button className="btn primary" type="button" onClick={() => setEdit({ employee_id: '', licence_no: '', licence_class: 'B', licence_expiry: '', defensive_training_on: '', medical_expiry: '', active: true, notes: '' })}>Add driver</button>}
    </PageHead>
    <Loading error={b.error} loading={b.loading && !b.data} />
    {b.data && <Panel>{ds.length ? <div className="scroll"><table>
      <thead><tr><th>Driver</th><th>Licence</th><th>Expires</th><th>Training / medical</th><th>Vehicles</th><th></th></tr></thead>
      <tbody>{ds.map(d => <tr key={d.id} style={d.active ? undefined : { opacity: .55 }}>
        <td><b>{b.emp(d.employee_id)}</b>{!d.active && <span className="muted"> (inactive)</span>}</td>
        <td>{d.licence_no || '—'}{d.licence_class && <span className="muted"> · class {d.licence_class}</span>}</td>
        <td className="num">{d.licence_expiry ? <span className={d.licence_expiry < today() ? 'pill bad' : d.licence_expiry <= soon(30) ? 'pill warn' : ''}>{d.licence_expiry}</span> : <span className="pill bad">not recorded</span>}</td>
        <td className="muted">{[d.defensive_training_on && 'trained ' + d.defensive_training_on, d.medical_expiry && 'medical to ' + d.medical_expiry].filter(Boolean).join(' · ') || '—'}</td>
        <td>{b.data!.vehicles.filter(v => v.driver_id === d.employee_id).map(v => <Link key={v.id} to={'/fleet/vehicles/' + v.id} style={{ marginRight: 6 }}>{v.reg_no}</Link>)}</td>
        <td className="r">{b.transport && <button className="btn small" type="button" onClick={() => setEdit({ ...d, licence_no: d.licence_no || '', licence_class: d.licence_class || '', licence_expiry: d.licence_expiry || '', defensive_training_on: d.defensive_training_on || '', medical_expiry: d.medical_expiry || '', notes: d.notes || '' })}>Edit</button>}</td></tr>)}</tbody></table></div>
      : <Empty>No drivers yet. Add the employees who drive company vehicles.</Empty>}</Panel>}
    {edit && b.data && <FormModal title={edit.id ? `Edit ${b.emp(edit.employee_id)}` : 'Add driver'} busy={act.busy} onClose={() => setEdit(null)} onSave={() => act.run(async () => {
      if (!edit.employee_id) throw new Error('Choose the employee.');
      const row = { company_id: b.cid, employee_id: edit.employee_id, licence_no: edit.licence_no || null, licence_class: edit.licence_class || null, licence_expiry: edit.licence_expiry || null, defensive_training_on: edit.defensive_training_on || null,
        medical_expiry: edit.medical_expiry || null, active: edit.active, notes: edit.notes || null, reminded_for: null };
      if (edit.id) await q(supabase.from('drivers').update(row).eq('id', edit.id) as any); else await q(supabase.from('drivers').insert(row) as any);
      setEdit(null); b.reload(); }, 'Saved')}>
      <div className="grid-form">
        {!edit.id && <Select label="Employee" id="dr-e" value={edit.employee_id} onChange={x => setEdit({ ...edit, employee_id: x })} options={[['', 'Choose…'], ...b.data.staff.filter(s => !ds.some(d => d.employee_id === s.id)).map(s => [s.id, s.full_name] as [string, string])]} />}
        <Field label="Licence no." id="dr-n" value={edit.licence_no} onChange={x => setEdit({ ...edit, licence_no: x })} />
        <Select label="Licence class" id="dr-c" value={edit.licence_class} onChange={x => setEdit({ ...edit, licence_class: x })} options={[['', '—'], ['A', 'A — motorcycle'], ['B', 'B — car, pickup'], ['C', 'C — light truck'], ['D', 'D — bus'], ['E', 'E — heavy goods'], ['F', 'F — articulated'], ['G', 'G — plant / earth-moving']]} />
        <Field label="Licence expires" id="dr-x" type="date" value={edit.licence_expiry} onChange={x => setEdit({ ...edit, licence_expiry: x })} />
        <Field label="Defensive driving training" id="dr-t" type="date" value={edit.defensive_training_on} onChange={x => setEdit({ ...edit, defensive_training_on: x })} />
        <Field label="Medical fitness expires" id="dr-m" type="date" value={edit.medical_expiry} onChange={x => setEdit({ ...edit, medical_expiry: x })} />
      </div>
      {edit.id && <label className="check"><input type="checkbox" checked={edit.active} onChange={e => setEdit({ ...edit, active: e.target.checked })} /> Active driver</label>}
      <Field label="Notes" id="dr-no" value={edit.notes} onChange={x => setEdit({ ...edit, notes: x })} />
    </FormModal>}
  </>;
}

// ---------------------------------------------------------------- Vehicle requests
export function VehicleRequestsPage() {
  const b = useFleet();
  const act = useAction();
  const [show, setShow] = useState('open');
  const [ask, setAsk] = useState<any | null>(null);
  const [give, setGive] = useState<any | null>(null);
  const [trip, setTrip] = useState<any | null>(null);
  const { data, error, loading, reload } = useLoad(() => q<any[]>(supabase.from('vehicle_requests').select('*').eq('company_id', b.cid).order('from_at', { ascending: false }).limit(1000) as any), [b.cid]);
  const F: [string, string, (r: any) => boolean][] = [['open', 'Open', r => ['pending', 'approved'].includes(r.status)], ['mine', 'Mine', r => r.requested_by === b.me], ['done', 'Done', r => r.status === 'done'], ['closed', 'Declined or cancelled', r => ['rejected', 'cancelled'].includes(r.status)], ['all', 'All', () => true]];
  const list = (data || []).filter((F.find(f => f[0] === show) || F[0])[2]);
  return <>
    <PageHead title="Vehicle requests" sub="Ask for a vehicle; the transport officer allocates one and a driver. Double bookings are refused.">
      <button className="btn primary" type="button" onClick={() => setAsk({ purpose: '', origin: '', destination: '', from_at: nowLocal(2), to_at: nowLocal(6), passengers: '', load_desc: '', vehicle_type: '', project_id: '' })}>Request a vehicle</button>
    </PageHead>
    <Loading error={error || b.error} loading={(loading && !data) || !b.data} />
    {data && b.data && <>
      <div className="chips">{F.map(([k, l, fn]) => <button key={k} type="button" className={'chip' + (show === k ? ' on' : '')} onClick={() => setShow(k)}>{l} <span>{data.filter(fn).length}</span></button>)}</div>
      <Panel>{list.length ? <div className="scroll"><table>
        <thead><tr><th>Request</th><th>When</th><th>For</th><th>Status</th><th></th></tr></thead>
        <tbody>{list.map(r => <tr key={r.id}>
          <td><b className="num">{r.number}</b> {r.purpose}<br /><span className="muted">{[r.origin, r.destination].filter(Boolean).join(' → ')}{r.passengers ? ` · ${r.passengers} people` : ''}{r.load_desc ? ' · ' + r.load_desc : ''}{r.vehicle_type ? ' · wants ' + label(VEHICLE_TYPES, r.vehicle_type).toLowerCase() : ''}</span></td>
          <td className="num">{dt(toLocal(r.from_at))}<br /><span className="muted">to {dt(toLocal(r.to_at))}</span></td>
          <td>{b.emp(r.employee_id) || '—'}{r.project_id && <><br /><span className="muted">{b.proj(r.project_id)}</span></>}</td>
          <td><Pill map={REQ_STATUS} s={r.status} />{r.vehicle_id && <><br /><Link to={'/fleet/vehicles/' + r.vehicle_id} style={{ fontSize: 12 }}>{b.veh(r.vehicle_id)?.reg_no}</Link>{r.driver_id && <span className="muted" style={{ fontSize: 12 }}> · {b.emp(r.driver_id)}</span>}</>}{r.decision_note && <><br /><span className="muted" style={{ fontSize: 12 }}>{r.decision_note}</span></>}</td>
          <td className="r" style={{ whiteSpace: 'nowrap' }}>
            {b.transport && r.status === 'pending' && <><button className="btn small primary" type="button" onClick={() => setGive({ r, action: 'approve', vehicle: '', driver: '', note: '' })}>Allocate</button>{' '}
              <button className="btn small" type="button" onClick={() => setGive({ r, action: 'reject', note: '' })}>Decline</button></>}
            {b.transport && r.status === 'approved' && <button className="btn small primary" type="button" onClick={() => setTrip({ vehicle_id: r.vehicle_id, driver_id: r.driver_id || '', project_id: r.project_id || '', request_id: r.id, purpose: r.purpose, origin: r.origin || '', destination: r.destination || '', passengers: r.passengers || '', load_desc: r.load_desc || '' })}>Make trip</button>}{' '}
            {(r.requested_by === b.me || b.transport) && ['pending', 'approved'].includes(r.status) && <ConfirmButton className="btn small ghost" label="Cancel" confirm={`Cancel ${r.number}?`} onConfirm={() => act.run(async () => { await rpc('decide_vehicle_request', { p_id: r.id, p_action: 'cancel' }); reload(); }, 'Cancelled')} />}</td></tr>)}</tbody></table></div>
        : <Empty>No requests here.</Empty>}</Panel>
    </>}
    {ask && b.data && <FormModal title="Request a vehicle" submit="Send request" busy={act.busy} onClose={() => setAsk(null)} onSave={() => act.run(async () => {
      if (!ask.purpose.trim()) throw new Error('Say what the vehicle is for.');
      await q(supabase.from('vehicle_requests').insert({ company_id: b.cid, purpose: ask.purpose, origin: ask.origin || null, destination: ask.destination || null, from_at: fromLocal(ask.from_at), to_at: fromLocal(ask.to_at),
        passengers: ask.passengers ? Number(ask.passengers) : null, load_desc: ask.load_desc || null, vehicle_type: ask.vehicle_type || null, project_id: ask.project_id || null }) as any);
      setAsk(null); setShow('mine'); reload(); }, 'Request sent to the transport officer')}>
      <Field label="What for" id="vr-p" value={ask.purpose} onChange={x => setAsk({ ...ask, purpose: x })} placeholder="e.g. Take the survey team to Tarkwa" required />
      <div className="grid-form">
        <Field label="From" id="vr-o" value={ask.origin} onChange={x => setAsk({ ...ask, origin: x })} />
        <Field label="To" id="vr-d" value={ask.destination} onChange={x => setAsk({ ...ask, destination: x })} />
        <Field label="Needed from" id="vr-f" type="datetime-local" value={ask.from_at} onChange={x => setAsk({ ...ask, from_at: x })} required />
        <Field label="Back by" id="vr-t" type="datetime-local" value={ask.to_at} onChange={x => setAsk({ ...ask, to_at: x })} required />
        <Field label="Passengers" id="vr-pa" type="number" step="1" min="0" value={ask.passengers} onChange={x => setAsk({ ...ask, passengers: x })} />
        <Field label="Load" id="vr-l" value={ask.load_desc} onChange={x => setAsk({ ...ask, load_desc: x })} placeholder="e.g. 2 t of cement" />
        <Select label="Kind of vehicle" id="vr-k" value={ask.vehicle_type} onChange={x => setAsk({ ...ask, vehicle_type: x })} options={[['', 'Any'], ...VEHICLE_TYPES]} />
        <Select label="Project" id="vr-pj" value={ask.project_id} onChange={x => setAsk({ ...ask, project_id: x })} options={b.projOpts()} />
      </div>
    </FormModal>}
    {give && b.data && <FormModal title={`${give.action === 'approve' ? 'Allocate a vehicle to' : 'Decline'} ${give.r.number}`} busy={act.busy} onClose={() => setGive(null)} onSave={() => act.run(async () => {
      await rpc('decide_vehicle_request', { p_id: give.r.id, p_action: give.action, p_vehicle: give.vehicle || null, p_driver: give.driver || null, p_note: give.note || null }); setGive(null); reload(); }, give.action === 'approve' ? 'Vehicle allocated' : 'Declined')}>
      <p style={{ margin: 0 }}>{give.r.purpose} · {dt(toLocal(give.r.from_at))} to {dt(toLocal(give.r.to_at))}</p>
      {give.action === 'approve' && <div className="grid-form">
        <Select label="Vehicle" id="vg-v" value={give.vehicle} onChange={x => setGive({ ...give, vehicle: x })} options={b.vehOpts()} />
        <Select label="Driver (blank = the vehicle's driver)" id="vg-d" value={give.driver} onChange={x => setGive({ ...give, driver: x })} options={b.driverOpts('Usual driver')} />
      </div>}
      <Field label={give.action === 'reject' ? 'Reason' : 'Note'} id="vg-n" value={give.note} onChange={x => setGive({ ...give, note: x })} required={give.action === 'reject'} />
    </FormModal>}
    {trip && <TripForm t={trip} setT={setTrip} vehicle={b.veh(trip.vehicle_id)} b={b} onClose={() => setTrip(null)} onDone={() => { setTrip(null); reload(); }} />}
  </>;
}

// ---------------------------------------------------------------- Waybills
export function WaybillsPage() {
  const b = useFleet();
  const { company } = useSession();
  const act = useAction();
  const nav = useNavigate();
  const [show, setShow] = useState('open');
  const [add, setAdd] = useState<any | null>(null);
  const { data, error, loading } = useLoad(async () => {
    const [wbs, sups] = await Promise.all([
      q<any[]>(supabase.from('waybills').select('*, transporter:suppliers(name)').eq('company_id', b.cid).order('created_at', { ascending: false }).limit(1000) as any),
      q<any[]>(supabase.from('suppliers').select('id,name').eq('company_id', b.cid).order('name') as any).catch(() => [] as any[]),
    ]);
    return { wbs, sups };
  }, [b.cid]);
  const F: [string, string, (w: any) => boolean][] = [['open', 'Draft or on the road', w => ['draft', 'dispatched'].includes(w.status)], ['short', 'Delivered short', w => w.status === 'partial'],
    ['done', 'Delivered', w => w.status === 'delivered'], ['hired', 'Hired transport', w => w.transport !== 'own'], ['all', 'All', () => true]];
  const list = (data?.wbs || []).filter((F.find(f => f[0] === show) || F[0])[2]);
  const head = ['Waybill', 'Date', 'Kind', 'From', 'To', 'Carried by', 'Project', 'Status', 'Received by', 'Transport cost (GHS)'];
  const carrier = (w: any) => w.transport === 'own' ? b.veh(w.vehicle_id)?.reg_no || '' : [w.transporter?.name, w.truck_reg].filter(Boolean).join(' ');
  const rows = list.map(w => [w.number, w.planned_on, w.kind, w.from_place, w.to_place, carrier(w), b.proj(w.project_id), WB_STATUS[w.status][0], w.received_by_name || '', money(w.transport_cost)]);
  return <>
    <PageHead title="Waybills and deliveries" sub="Deliveries to sites and customers, collections, own trucks or hired transport, with signed proof of delivery.">
      <Downloads pdf={() => tablePdf({ company: company!, title: 'Waybills', subtitle: longDate(today()), head, body: rows, landscape: true, rightAlign: [9], filename: 'waybills-' + today() })} csv={() => downloadCsv('waybills-' + today(), head, rows)} />
      <button className="btn primary" type="button" onClick={() => setAdd({ kind: 'delivery', transport: 'own', vehicle_id: '', driver_id: '', transporter_id: '', truck_reg: '', driver_name: '', driver_phone: '', project_id: '', from_place: '', to_place: '', contact_name: '', contact_phone: '', planned_on: today(), transport_cost: '', note: '' })}>New waybill</button>
    </PageHead>
    <Loading error={error || b.error} loading={(loading && !data) || !b.data} />
    {data && b.data && <>
      <div className="chips">{F.map(([k, l, fn]) => <button key={k} type="button" className={'chip' + (show === k ? ' on' : '')} onClick={() => setShow(k)}>{l} <span>{data.wbs.filter(fn).length}</span></button>)}</div>
      <Panel>{list.length ? <div className="scroll"><table>
        <thead><tr><th>Waybill</th><th>Route</th><th>Carried by</th><th className="r">Cost</th><th>Status</th></tr></thead>
        <tbody>{list.map(w => <tr key={w.id} style={{ cursor: 'pointer' }} onClick={() => nav('/fleet/waybills/' + w.id)}>
          <td><Link to={'/fleet/waybills/' + w.id}><b>{w.number}</b></Link><br /><span className="muted">{w.planned_on} · {w.kind}</span></td>
          <td>{w.from_place} → <b>{w.to_place}</b>{w.project_id && <><br /><span className="muted">{b.proj(w.project_id)}</span></>}</td>
          <td>{carrier(w) || '—'}{w.transport !== 'own' && <span className="pill" style={{ marginLeft: 4 }}>{w.transport}</span>}</td>
          <td className="r num">{Number(w.transport_cost) ? money(w.transport_cost) : ''}</td>
          <td><Pill map={WB_STATUS} s={w.status} />{w.received_by_name && <><br /><span className="muted" style={{ fontSize: 12 }}>by {w.received_by_name}</span></>}</td></tr>)}</tbody></table></div>
        : <Empty>No waybills here.</Empty>}</Panel>
    </>}
    {add && data && <FormModal title="New waybill" submit="Create and add items" busy={act.busy} onClose={() => setAdd(null)} onSave={() => act.run(async () => {
      const w = await q<any>(supabase.from('waybills').insert(waybillRow(b.cid, add)).select('id').single() as any); nav('/fleet/waybills/' + w.id); }, 'Waybill created')}>
      <WaybillFields f={add} setF={setAdd} b={b} sups={data.sups} />
    </FormModal>}
  </>;
}
const waybillRow = (cid: string, f: any) => ({ company_id: cid, kind: f.kind, transport: f.transport, vehicle_id: f.transport === 'own' ? f.vehicle_id || null : null, driver_id: f.transport === 'own' ? f.driver_id || null : null,
  transporter_id: f.transport !== 'own' ? f.transporter_id || null : null, truck_reg: f.transport !== 'own' ? f.truck_reg || null : null, driver_name: f.transport !== 'own' ? f.driver_name || null : null, driver_phone: f.transport !== 'own' ? f.driver_phone || null : null,
  project_id: f.project_id || null, from_place: f.from_place.trim(), to_place: f.to_place.trim(), contact_name: f.contact_name || null, contact_phone: f.contact_phone || null, planned_on: f.planned_on, transport_cost: Number(f.transport_cost) || 0, note: f.note || null });
function WaybillFields({ f, setF, b, sups }: { f: any; setF: (v: any) => void; b: ReturnType<typeof useFleet>; sups: any[] }) {
  const s = (k: string) => (v: string) => setF({ ...f, [k]: v });
  return <>
    <div className="grid-form">
      <Select label="Kind" id="wb-k" value={f.kind} onChange={s('kind')} options={[['delivery', 'Delivery'], ['collection', 'Collection (from a supplier or port)'], ['transfer', 'Transfer between sites'], ['return', 'Return']]} />
      <Select label="Transport" id="wb-t" value={f.transport} onChange={s('transport')} options={[['own', 'Our vehicle'], ['hired', 'Hired truck'], ['courier', 'Courier']]} />
      <Field label="From" id="wb-f" value={f.from_place} onChange={s('from_place')} placeholder="e.g. Head office store" required />
      <Field label="To" id="wb-to" value={f.to_place} onChange={s('to_place')} placeholder="e.g. Prestea site" required />
      <Select label="Project" id="wb-p" value={f.project_id} onChange={x => setF({ ...f, project_id: x, to_place: f.to_place || b.data?.projects.find(p => p.id === x)?.location || '' })} options={b.projOpts()} />
      <Field label="Date" id="wb-d" type="date" value={f.planned_on} onChange={s('planned_on')} required />
      {f.transport === 'own' ? <>
        <Select label="Vehicle" id="wb-v" value={f.vehicle_id} onChange={x => setF({ ...f, vehicle_id: x, driver_id: f.driver_id || b.veh(x)?.driver_id || '' })} options={b.vehOpts('Choose before dispatch')} />
        <Select label="Driver" id="wb-dr" value={f.driver_id} onChange={s('driver_id')} options={b.driverOpts()} />
      </> : <>
        <Select label="Transporter (supplier)" id="wb-tr" value={f.transporter_id} onChange={s('transporter_id')} options={[['', '—'], ...sups.map(x => [x.id, x.name] as [string, string])]} />
        <Field label="Truck registration" id="wb-tg" value={f.truck_reg} onChange={x => setF({ ...f, truck_reg: x.toUpperCase() })} />
        <Field label="Driver's name" id="wb-dn" value={f.driver_name} onChange={s('driver_name')} />
        <Field label="Driver's phone" id="wb-dp" value={f.driver_phone} onChange={s('driver_phone')} />
      </>}
      <Field label="Receiver on site" id="wb-cn" value={f.contact_name} onChange={s('contact_name')} />
      <Field label="Receiver's phone" id="wb-cp" value={f.contact_phone} onChange={s('contact_phone')} />
      <Field label={f.transport === 'own' ? 'Transport cost to charge (GH₵, optional)' : 'Haulage charge (GH₵)'} id="wb-c" type="number" step="0.01" min="0" value={f.transport_cost} onChange={s('transport_cost')} />
    </div>
    <Field label="Instructions" id="wb-n" value={f.note} onChange={s('note')} placeholder="e.g. Offload at the north gate; call the foreman 30 minutes before" />
  </>;
}
export function WaybillView() {
  const { id } = useParams();
  const b = useFleet();
  const { company, can } = useSession();
  const act = useAction();
  const nav = useNavigate();
  const [line, setLine] = useState<any | null>(null);
  const [edit, setEdit] = useState<any | null>(null);
  const [pod, setPod] = useState<any | null>(null);
  const [cancel, setCancel] = useState<string | null>(null);
  const { data, error, loading, reload } = useLoad(async () => {
    const [w, lines, sups, products] = await Promise.all([
      q<any>(supabase.from('waybills').select('*, transporter:suppliers(name)').eq('id', id).single() as any),
      q<any[]>(supabase.from('waybill_lines').select('*').eq('waybill_id', id).order('sort').order('id') as any),
      q<any[]>(supabase.from('suppliers').select('id,name').order('name') as any).catch(() => [] as any[]),
      q<any[]>(supabase.from('products').select('id,name,unit').order('name').limit(2000) as any).catch(() => [] as any[]),
    ]);
    return { w, lines, sups, products };
  }, [id]);
  if (!data || !b.data) return <Loading error={error || b.error} loading={loading || b.loading} />;
  const { w, lines } = data;
  const draft = w.status === 'draft';
  const canEdit = draft && (b.transport || w.created_by === b.me || can('project_manager'));
  const pmRole = can('project_manager');
  const canDeliver = w.status === 'dispatched' && (b.transport || pmRole || b.myEmp.includes(w.driver_id));
  const openPod = () => act.run(async () => { const { data: u, error: e } = await supabase.storage.from('project-docs').createSignedUrl(w.pod_path, 600); if (e) throw e; window.open(u.signedUrl, '_blank', 'noopener'); });
  const print = () => waybillPdf({ company: company!, w, lines, vehicle: vName(b.veh(w.vehicle_id)), driver: b.emp(w.driver_id), transporter: w.transporter?.name || '', project: b.proj(w.project_id) });
  return <>
    <PageHead title={w.number} sub={<><Pill map={WB_STATUS} s={w.status} /> <span className="muted">· {w.from_place} → {w.to_place}{w.project_id ? ' · ' + b.proj(w.project_id) : ''}</span></>}>
      <Link className="btn" to="/fleet/waybills">Back</Link>
      <button className="btn" type="button" onClick={print}>Print waybill</button>
      {canEdit && <button className="btn" type="button" onClick={() => setEdit(Object.fromEntries(Object.entries(w).map(([k, v]) => [k, v == null ? '' : String(v)])))}>Edit</button>}
      {draft && (b.transport || pmRole) && <button className="btn primary" type="button" disabled={act.busy} onClick={() => act.run(async () => { await rpc('waybill_step', { p_id: w.id, p_action: 'dispatch' }); reload(); }, 'Dispatched. Print the waybill to go with the load.')}>Dispatch</button>}
      {canDeliver && <button className="btn primary" type="button" onClick={() => setPod({ received_by: '', note: '', file: null, qty: Object.fromEntries(lines.map(l => [l.id, String(l.qty)])) })}>Confirm delivery</button>}
      {b.transport && ['draft', 'dispatched'].includes(w.status) && <button className="btn ghost" type="button" onClick={() => setCancel('')}>Cancel</button>}
      {draft && b.transport && <ConfirmButton className="btn danger" label="Delete" confirm="Delete this draft waybill?" onConfirm={() => act.run(async () => { await q(supabase.from('waybills').delete().eq('id', w.id) as any); nav('/fleet/waybills'); }, 'Deleted')} />}
    </PageHead>
    <Panel pad><div className="grid-form">
      <div><div className="label">Kind</div>{w.kind}</div>
      <div><div className="label">Date</div>{longDate(w.planned_on)}</div>
      <div><div className="label">Carried by</div>{w.transport === 'own' ? (w.vehicle_id ? <Link to={'/fleet/vehicles/' + w.vehicle_id}>{vName(b.veh(w.vehicle_id))}</Link> : <span className="pill warn">no vehicle yet</span>) : [w.transporter?.name, w.truck_reg].filter(Boolean).join(' · ') || '—'}</div>
      <div><div className="label">Driver</div>{b.emp(w.driver_id) || [w.driver_name, w.driver_phone].filter(Boolean).join(' · ') || '—'}</div>
      <div><div className="label">Receiver</div>{[w.contact_name, w.contact_phone].filter(Boolean).join(' · ') || '—'}</div>
      <div><div className="label">Transport cost</div>{Number(w.transport_cost) ? cedis(w.transport_cost) : '—'}</div>
      {w.dispatched_at && <div><div className="label">Dispatched</div>{dt(toLocal(w.dispatched_at))}</div>}
      {w.delivered_at && <div><div className="label">Delivered</div>{dt(toLocal(w.delivered_at))} · received by <b>{w.received_by_name}</b>{w.pod_path && <> · <button className="btn small" type="button" onClick={openPod}>Signed copy</button></>}</div>}
    </div>{w.note && <p className="muted" style={{ whiteSpace: 'pre-wrap' }}>{w.note}</p>}{w.pod_note && <p><b>On delivery:</b> {w.pod_note}</p>}</Panel>
    <Panel title="Items" actions={canEdit && <button className="btn small primary" type="button" onClick={() => setLine({ product_id: '', description: '', qty: '1', unit: '', weight_kg: '' })}>Add item</button>}>
      {lines.length ? <div className="scroll"><table>
        <thead><tr><th>#</th><th>Description</th><th className="r">Qty sent</th><th className="r">Weight (kg)</th><th className="r">Received</th><th></th></tr></thead>
        <tbody>{lines.map((l, i) => <tr key={l.id}><td className="num">{i + 1}</td><td>{l.description}</td><td className="r num">{n2(l.qty)} {l.unit || ''}</td><td className="r num">{l.weight_kg ? n2(l.weight_kg) : ''}</td>
          <td className="r num">{l.delivered_qty != null ? <span className={Number(l.delivered_qty) < Number(l.qty) ? 'pill bad' : ''}>{n2(l.delivered_qty)}</span> : ''}</td>
          <td className="r">{canEdit && <button className="btn small ghost" type="button" onClick={() => act.run(async () => { await q(supabase.from('waybill_lines').delete().eq('id', l.id) as any); reload(); })}>Remove</button>}</td></tr>)}</tbody>
        <tfoot><tr><td></td><td>Total weight</td><td></td><td className="r num">{n2(lines.reduce((s, l) => s + Number(l.weight_kg || 0), 0))}</td><td></td><td></td></tr></tfoot></table></div>
        : <Empty>Add what is being carried.</Empty>}
    </Panel>
    {line && <FormModal title="Add item" busy={act.busy} onClose={() => setLine(null)} onSave={() => act.run(async () => {
      if (!line.description.trim() || !(Number(line.qty) > 0)) throw new Error('Describe the item and give a quantity.');
      await q(supabase.from('waybill_lines').insert({ company_id: w.company_id, waybill_id: w.id, product_id: line.product_id || null, description: line.description, qty: Number(line.qty), unit: line.unit || null, weight_kg: line.weight_kg ? Number(line.weight_kg) : null, sort: lines.length }) as any);
      setLine(null); reload(); }, 'Added')}>
      <Select label="From your products (optional)" id="wl-p" value={line.product_id} onChange={x => { const p = data.products.find(y => y.id === x); setLine({ ...line, product_id: x, description: p?.name || line.description, unit: p?.unit || line.unit }); }} options={[['', '—'], ...data.products.map(p => [p.id, p.name] as [string, string])]} />
      <Field label="Description" id="wl-d" value={line.description} onChange={x => setLine({ ...line, description: x })} required />
      <div className="grid-form">
        <Field label="Quantity" id="wl-q" type="number" step="0.01" min="0.01" value={line.qty} onChange={x => setLine({ ...line, qty: x })} required />
        <Field label="Unit" id="wl-u" value={line.unit} onChange={x => setLine({ ...line, unit: x })} placeholder="bags, lengths, pcs" />
        <Field label="Weight (kg)" id="wl-w" type="number" step="0.1" min="0" value={line.weight_kg} onChange={x => setLine({ ...line, weight_kg: x })} />
      </div>
    </FormModal>}
    {edit && <FormModal title={`Edit ${w.number}`} busy={act.busy} onClose={() => setEdit(null)} onSave={() => act.run(async () => { await q(supabase.from('waybills').update(waybillRow(w.company_id, edit)).eq('id', w.id) as any); setEdit(null); reload(); }, 'Saved')}>
      <WaybillFields f={edit} setF={setEdit} b={b} sups={data.sups} />
    </FormModal>}
    {pod && <FormModal title={`Confirm delivery of ${w.number}`} submit="Confirm delivery" busy={act.busy} onClose={() => setPod(null)} onSave={() => act.run(async () => {
      let path: string | null = null; if (pod.file) path = (await uploadDocFile(w.company_id, 'fleet', pod.file)).path;
      const s = await rpc<string>('waybill_step', { p_id: w.id, p_action: 'deliver', p_received_by: pod.received_by, p_note: pod.note || null, p_lines: lines.map(l => ({ id: l.id, delivered_qty: Number(pod.qty[l.id] ?? l.qty) })), p_pod: path });
      setPod(null); reload(); if (s === 'partial') throw new Error('Recorded as delivered short. The transport officer has been told.'); }, 'Delivered')}>
      <div className="scroll"><table><thead><tr><th>Item</th><th className="r">Sent</th><th className="r">Received</th></tr></thead>
        <tbody>{lines.map(l => <tr key={l.id}><td>{l.description}</td><td className="r num">{n2(l.qty)}</td>
          <td className="r"><input aria-label={`Received of ${l.description}`} type="number" step="0.01" min="0" style={{ width: 90, textAlign: 'right' }} value={pod.qty[l.id]} onChange={e => setPod({ ...pod, qty: { ...pod.qty, [l.id]: e.target.value } })} /></td></tr>)}</tbody></table></div>
      <Field label="Received by (name)" id="pd-r" value={pod.received_by} onChange={x => setPod({ ...pod, received_by: x })} required />
      <Field label="Remarks (damage, shortage)" id="pd-n" value={pod.note} onChange={x => setPod({ ...pod, note: x })} />
      <div className="field"><label htmlFor="pd-f">Photo of the signed waybill</label><input id="pd-f" type="file" accept="image/*,.pdf" capture="environment" onChange={e => setPod({ ...pod, file: e.target.files?.[0] || null })} /></div>
    </FormModal>}
    {cancel !== null && <FormModal title={`Cancel ${w.number}`} submit="Cancel waybill" danger busy={act.busy} onClose={() => setCancel(null)} onSave={() => act.run(async () => { await rpc('waybill_step', { p_id: w.id, p_action: 'cancel', p_note: cancel }); setCancel(null); reload(); }, 'Cancelled')}>
      <Field label="Reason" id="wc-r" value={cancel} onChange={setCancel} required />
    </FormModal>}
  </>;
}

// ---------------------------------------------------------------- Reports
const PERIODS: [string, string][] = [['month', 'This month'], ['last', 'Last month'], ['ytd', 'Year to date'], ['12m', 'Last 12 months']];
function range(p: string): [string, string] {
  const t = today(), y = Number(t.slice(0, 4)), m = Number(t.slice(5, 7));
  if (p === 'month') return [t.slice(0, 8) + '01', t];
  if (p === 'last') { const s = new Date(Date.UTC(y, m - 2, 1)), e = new Date(Date.UTC(y, m - 1, 0)); return [s.toISOString().slice(0, 10), e.toISOString().slice(0, 10)]; }
  if (p === 'ytd') return [`${y}-01-01`, t];
  return [soon(-365), t];
}
export function FleetReportsPage() {
  const { cid, company } = useSession();
  const [p, setP] = useState('month');
  const [from, to] = range(p);
  const { data, error, loading } = useLoad(() => rpc<any>('fleet_report', { cid, p_from: from, p_to: to }), [cid, from, to]);
  const vs: any[] = data?.vehicles || [];
  const cost = (v: any) => Number(v.fuel_cost) + Number(v.service_cost) + Number(v.doc_cost);
  const T = vs.reduce((s, v) => ({ km: s.km + Number(v.km), l: s.l + Number(v.litres), c: s.c + cost(v) }), { km: 0, l: 0, c: 0 });
  const head = ['Vehicle', 'Trips', 'km', 'Litres', 'km/l', 'Fuel (GHS)', 'Service (GHS)', 'Papers (GHS)', 'Total (GHS)', 'GHS per km', 'Days off road', 'Fuel flags'];
  const rows = vs.map(v => [`${v.reg_no} ${v.name}`.trim(), v.trips, km(v.km), n2(v.litres), v.km_per_l ? n2(v.km_per_l) : '', money(v.fuel_cost), money(v.service_cost), money(v.doc_cost), money(cost(v)), Number(v.km) ? n2(cost(v) / Number(v.km)) : '', n2(v.downtime), v.flags || '']);
  const ph = ['Project', 'km driven', 'Fuel (GHS)', 'Waybills', 'Haulage (GHS)', 'Total transport (GHS)'];
  const pr = (data?.projects || []).map((x: any) => [x.project, km(x.km), money(x.fuel_cost), x.waybills, money(x.transport_cost), money(Number(x.fuel_cost) + Number(x.transport_cost))]);
  const sub = `${longDate(from)} to ${longDate(to)}`;
  return <>
    <PageHead title="Fleet reports" sub="Running cost per vehicle and per km, fuel economy, downtime, and what transport costs each project.">
      <div className="field" style={{ width: 180 }}><label htmlFor="fr-p">Period</label><select id="fr-p" value={p} onChange={e => setP(e.target.value)}>{PERIODS.map(([k, l]) => <option key={k} value={k}>{l}</option>)}</select></div>
    </PageHead>
    <Loading error={error} loading={loading && !data} />
    {data && <>
      <div className="tiles">
        <div className="tile"><span>Distance</span><b>{km(T.km)} km</b></div>
        <div className="tile"><span>Fuel</span><b>{n2(T.l)} L</b></div>
        <div className="tile"><span>Running cost</span><b>{cedis(T.c)}</b></div>
        <div className="tile"><span>Cost per km</span><b>{T.km ? 'GH₵ ' + n2(T.c / T.km) : '—'}</b></div>
      </div>
      <Panel title="By vehicle" actions={<Downloads pdf={() => tablePdf({ company: company!, title: 'Fleet running costs', subtitle: sub, head, body: rows, landscape: true, rightAlign: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11], filename: 'fleet-costs-' + from })} csv={() => downloadCsv('fleet-costs-' + from, head, rows)} />}>
        {vs.length ? <div className="scroll"><table><thead><tr>{head.map((h, i) => <th key={h} className={i ? 'r' : ''}>{h.replace('GHS', 'GH₵')}</th>)}</tr></thead>
          <tbody>{vs.map((v, i) => <tr key={v.id}><td><Link to={'/fleet/vehicles/' + v.id}>{v.reg_no}</Link> <span className="muted">{v.name}</span>{v.service_due && <span className="pill warn" style={{ marginLeft: 4 }}>service due</span>}</td>
            {rows[i].slice(1).map((c, j) => <td key={j} className={'r num' + (j === 10 && c ? ' bad' : '')}>{c}</td>)}</tr>)}</tbody></table></div> : <Empty>No vehicles.</Empty>}
        <p className="muted body" style={{ margin: 0, fontSize: 13 }}>Fuel and service costs come from the fuel log and job cards; papers are roadworthy, insurance and road-use fees issued in the period. The books (Reports) remain the official figures.</p>
      </Panel>
      <Panel title="Transport by project" actions={pr.length > 0 && <Downloads pdf={() => tablePdf({ company: company!, title: 'Transport cost by project', subtitle: sub, head: ph, body: pr, rightAlign: [1, 2, 3, 4, 5], filename: 'transport-by-project-' + from })} csv={() => downloadCsv('transport-by-project-' + from, ph, pr)} />}>
        {pr.length ? <div className="scroll"><table><thead><tr>{ph.map((h, i) => <th key={h} className={i ? 'r' : ''}>{h.replace('GHS', 'GH₵')}</th>)}</tr></thead>
          <tbody>{pr.map((r: any[], i: number) => <tr key={i}>{r.map((c, j) => <td key={j} className={j ? 'r num' : ''}>{c}</td>)}</tr>)}</tbody></table></div> : <Empty>No trips, fuel or waybills against projects in this period.</Empty>}
      </Panel>
      <div className="two">
        <Panel title="Vehicle papers due in 30 days">{data.documents_due.length ? <div className="scroll"><table><tbody>{data.documents_due.map((d: any, i: number) => <tr key={i}><td>{d.reg_no}</td><td>{label(DOC_KINDS, d.kind)}</td>
          <td className="num"><span className={d.expires_on < today() ? 'pill bad' : 'pill warn'}>{d.expires_on}</span></td><td className="r num muted">{ago(d.expires_on)} days</td></tr>)}</tbody></table></div> : <Empty>All in order.</Empty>}</Panel>
        <Panel title="Driving licences due in 30 days">{data.licences_due.length ? <div className="scroll"><table><tbody>{data.licences_due.map((d: any, i: number) => <tr key={i}><td>{d.name}</td>
          <td className="num"><span className={d.licence_expiry < today() ? 'pill bad' : 'pill warn'}>{d.licence_expiry}</span></td></tr>)}</tbody></table></div> : <Empty>All in order.</Empty>}</Panel>
      </div>
    </>}
  </>;
}
