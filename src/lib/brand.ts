/** Product name and per-installation branding. A copy set up for one company can show its own name everywhere
 *  by setting VITE_BRAND_NAME (and optionally VITE_BRAND_MARK, the letter in the square) before building. */
export const PRODUCT = 'Asnys ERP';
const env = import.meta.env as Record<string, string | undefined>;
export const BRAND = (env.VITE_BRAND_NAME || '').trim() || PRODUCT;
export const BRAND_MARK = ((env.VITE_BRAND_MARK || '').trim() || BRAND.charAt(0)).slice(0, 2).toUpperCase();
export const isWhiteLabel = BRAND !== PRODUCT;
/** Initials for a company's square: "Volta Engineering Ltd" → "VE". */
export const initials = (name?: string | null) =>
  (name || '').replace(/\b(ltd|limited|plc|inc|llc|co|company|ghana)\b\.?/gi, '').trim().split(/\s+/).filter(Boolean).slice(0, 2).map(w => w[0]).join('').toUpperCase() || BRAND_MARK;
