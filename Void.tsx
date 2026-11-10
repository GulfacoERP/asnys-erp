import { useState } from 'react';
import { rpc } from '../lib/supabase';
import { Field, FormModal, useAction, useLoad } from './ui';

/** Void an entry made in error, with a reason. Shows only to people allowed to void it, and only while it can be voided. */
export function VoidButton({ table, id, label, onDone, small = true, check = true }: { table: string; id: string; label?: string; onDone: () => void; small?: boolean; check?: boolean }) {
  const act = useAction();
  const [open, setOpen] = useState(false);
  const [reason, setReason] = useState('');
  const { data: allowed } = useLoad(() => check ? rpc<boolean>('can_void', { p_table: table, p_id: id }).catch(() => false) : Promise.resolve(true), [table, id]);
  if (!allowed) return null;
  return <>
    <button className={'btn ghost' + (small ? ' small' : '')} type="button" title="Entered in error? Void it with a reason; it stays on record" onClick={e => { e.stopPropagation(); setOpen(true); }}>Void</button>
    {open && <FormModal title={`Void ${label || 'this entry'}`} submit="Void" danger busy={act.busy} onClose={() => setOpen(false)} onSave={() => act.run(async () => {
      await rpc('void_entry', { p_table: table, p_id: id, p_reason: reason }); setOpen(false); setReason(''); onDone();
    }, 'Voided. It stays on record, marked Voided, and appears in the activity log.')}>
      <p style={{ margin: 0 }}>Use this for an entry made in error, such as a duplicate or the wrong details. It is kept on record, marked <b>Voided</b> with your reason, and no longer counts anywhere.</p>
      <Field label="Why is it being voided?" id="void-reason" value={reason} onChange={setReason} placeholder="e.g. Entered twice; wrong client" required />
    </FormModal>}
  </>;
}

/** Small note under a voided entry. */
export const VoidedNote = ({ r }: { r: any }) => r?.status === 'voided' ? <><br /><span className="pill bad" style={{ fontSize: 11 }}>Voided</span>{r.void_reason && <span className="muted" style={{ fontSize: 12 }}> {r.void_reason}</span>}</> : null;
