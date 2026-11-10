/**
 * Read spreadsheets in the browser with no third-party library:
 *   - CSV (comma, semicolon or tab separated, quoted fields, UTF-8 with or without BOM)
 *   - Excel .xlsx: first worksheet, shared and inline strings, numbers, booleans
 * Returns rows of strings; the first row is the header.
 */
export async function readSheet(file: File): Promise<string[][]> {
  if (/\.xlsx$/i.test(file.name)) return readXlsx(await file.arrayBuffer());
  if (/\.xls$/i.test(file.name)) throw new Error('Old .xls files are not supported. In Excel choose File → Save As → Excel Workbook (.xlsx) or CSV.');
  return parseCsv(await file.text());
}

export function parseCsv(text: string): string[][] {
  text = text.replace(/^﻿/, '');
  const first = text.split(/\r?\n/, 1)[0] || '';
  const sep = [',', ';', '\t'].map(s => [s, first.split(s).length] as const).sort((a, b) => b[1] - a[1])[0][0];
  const rows: string[][] = []; let row: string[] = []; let cell = ''; let q = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (q) {
      if (c === '"') { if (text[i + 1] === '"') { cell += '"'; i++; } else q = false; } else cell += c;
    } else if (c === '"') q = true;
    else if (c === sep) { row.push(cell); cell = ''; }
    else if (c === '\n' || c === '\r') { if (c === '\r' && text[i + 1] === '\n') i++; row.push(cell); rows.push(row); row = []; cell = ''; }
    else cell += c;
  }
  if (cell !== '' || row.length) { row.push(cell); rows.push(row); }
  return rows.filter(r => r.some(c => c.trim() !== '')).map(r => r.map(c => c.trim()));
}

// ---- minimal .xlsx (zip + XML) reader
async function inflate(data: Uint8Array): Promise<Uint8Array> {
  const ds = new (window as any).DecompressionStream('deflate-raw');
  const stream = new Blob([data]).stream().pipeThrough(ds);
  return new Uint8Array(await new Response(stream).arrayBuffer());
}

async function unzip(buf: ArrayBuffer, want: (name: string) => boolean): Promise<Record<string, string>> {
  const v = new DataView(buf); const u8 = new Uint8Array(buf); const out: Record<string, string> = {};
  let eocd = -1;
  for (let i = buf.byteLength - 22; i >= Math.max(0, buf.byteLength - 66000); i--) if (v.getUint32(i, true) === 0x06054b50) { eocd = i; break; }
  if (eocd < 0) throw new Error('This file is not a valid .xlsx workbook.');
  let p = v.getUint32(eocd + 16, true); const n = v.getUint16(eocd + 10, true);
  const dec = new TextDecoder();
  for (let k = 0; k < n; k++) {
    if (v.getUint32(p, true) !== 0x02014b50) break;
    const method = v.getUint16(p + 10, true), size = v.getUint32(p + 20, true);
    const nameLen = v.getUint16(p + 28, true), extraLen = v.getUint16(p + 30, true), commentLen = v.getUint16(p + 32, true);
    const local = v.getUint32(p + 42, true);
    const name = dec.decode(u8.subarray(p + 46, p + 46 + nameLen));
    if (want(name)) {
      const lNameLen = v.getUint16(local + 26, true), lExtraLen = v.getUint16(local + 28, true);
      const start = local + 30 + lNameLen + lExtraLen;
      const raw = u8.subarray(start, start + size);
      const bytes = method === 0 ? raw : method === 8 ? await inflate(raw) : (() => { throw new Error('Unsupported compression in this workbook.'); })();
      out[name] = dec.decode(bytes);
    }
    p += 46 + nameLen + extraLen + commentLen;
  }
  return out;
}

const colIndex = (ref: string) => { let n = 0; for (const ch of ref.replace(/\d+/g, '')) n = n * 26 + (ch.charCodeAt(0) - 64); return n - 1; };

async function readXlsx(buf: ArrayBuffer): Promise<string[][]> {
  const files = await unzip(buf, n => n === 'xl/sharedStrings.xml' || n === 'xl/workbook.xml' || n === 'xl/_rels/workbook.xml.rels' || /^xl\/worksheets\/sheet\d+\.xml$/.test(n));
  const parse = (x: string) => new DOMParser().parseFromString(x, 'application/xml');
  const shared = files['xl/sharedStrings.xml'] ? Array.from(parse(files['xl/sharedStrings.xml']).getElementsByTagName('si')).map(si => Array.from(si.getElementsByTagName('t')).map(t => t.textContent || '').join('')) : [];
  // The first sheet in workbook order
  let sheetPath = Object.keys(files).filter(k => k.startsWith('xl/worksheets/')).sort()[0];
  if (files['xl/workbook.xml'] && files['xl/_rels/workbook.xml.rels']) {
    const first = parse(files['xl/workbook.xml']).getElementsByTagName('sheet')[0];
    const rid = first?.getAttribute('r:id') || first?.getAttributeNS('http://schemas.openxmlformats.org/officeDocument/2006/relationships', 'id');
    const rel = Array.from(parse(files['xl/_rels/workbook.xml.rels']).getElementsByTagName('Relationship')).find(r => r.getAttribute('Id') === rid);
    const target = rel?.getAttribute('Target');
    if (target) { const path = target.startsWith('/') ? target.slice(1) : 'xl/' + target.replace(/^\.\//, ''); if (files[path]) sheetPath = path; }
  }
  if (!sheetPath) throw new Error('No worksheet found in this workbook.');
  const doc = parse(files[sheetPath]);
  const rows: string[][] = [];
  for (const r of Array.from(doc.getElementsByTagName('row'))) {
    const out: string[] = [];
    for (const c of Array.from(r.getElementsByTagName('c'))) {
      const i = colIndex(c.getAttribute('r') || 'A1'); const t = c.getAttribute('t');
      const vEl = c.getElementsByTagName('v')[0]; let val = vEl?.textContent ?? '';
      if (t === 's') val = shared[Number(val)] ?? '';
      else if (t === 'inlineStr') val = Array.from(c.getElementsByTagName('t')).map(x => x.textContent || '').join('');
      else if (t === 'b') val = val === '1' ? 'TRUE' : 'FALSE';
      while (out.length < i) out.push('');
      out[i] = String(val).trim();
    }
    rows[Number(r.getAttribute('r') || rows.length + 1) - 1] = out;
  }
  return Array.from(rows, r => r || []).filter(r => r.some(c => c !== ''));
}

/** Excel stores dates as day numbers; accept those, ISO dates and dd/mm/yyyy. */
export function toIsoDate(v: string): string | null {
  if (!v) return null;
  if (/^\d{4}-\d{2}-\d{2}/.test(v)) return v.slice(0, 10);
  const m = v.match(/^(\d{1,2})[/.-](\d{1,2})[/.-](\d{4})$/);
  if (m) return `${m[3]}-${m[2].padStart(2, '0')}-${m[1].padStart(2, '0')}`;
  if (/^\d{4,5}(\.\d+)?$/.test(v)) { const d = new Date(Date.UTC(1899, 11, 30) + Math.floor(Number(v)) * 864e5); return d.toISOString().slice(0, 10); }
  return null;
}
export const toNum = (v: string) => { if (v === undefined || v === null || String(v).trim() === '') return null; const n = Number(String(v).replace(/[,\s]|GH₵|GHS/g, '')); return isFinite(n) ? n : NaN; };
