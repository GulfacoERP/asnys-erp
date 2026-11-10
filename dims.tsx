import { q, supabase } from '../lib/supabase';
import { Select, useLoad } from './ui';

/** Branches and cost centres for this company (both lists are empty until set up under Settings). */
export function useDims(cid: string) {
  return useLoad(async () => ({
    branches: await q<any[]>(supabase.from('branches').select('id,code,name').eq('company_id', cid).eq('active', true).order('code') as any),
    centres: await q<any[]>(supabase.from('cost_centres').select('id,code,name').eq('company_id', cid).eq('active', true).order('code') as any),
  }), [cid]);
}

/** Branch and cost centre pickers; render nothing when the company uses neither. */
export function DimSelects({ dims, branch, centre, onChange, idPrefix }: { dims: { branches: any[]; centres: any[] } | null; branch: string; centre: string;
  onChange: (branch: string, centre: string) => void; idPrefix: string }) {
  if (!dims) return null;
  return <>
    {dims.branches.length > 0 && <Select label="Branch" id={idPrefix + '-branch'} value={branch || ''} onChange={v => onChange(v, centre)} options={[['', '—'], ...dims.branches.map(b => [b.id, `${b.code} ${b.name}`] as [string, string])]} />}
    {dims.centres.length > 0 && <Select label="Cost centre" id={idPrefix + '-cc'} value={centre || ''} onChange={v => onChange(branch, v)} options={[['', '—'], ...dims.centres.map(b => [b.id, `${b.code} ${b.name}`] as [string, string])]} />}
  </>;
}
