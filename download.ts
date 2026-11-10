/** Saves a Blob to the user's device. */
export function saveBlob(blob: Blob, filename: string) {
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

/** Downloads rows as a CSV that opens cleanly in Excel (UTF-8 with BOM). */
export function downloadCsv(filename: string, headers: string[], rows: (string | number | null | undefined)[][]) {
  const cell = (v: unknown) => {
    const s = v == null ? '' : String(v);
    return /[",\n]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s;
  };
  const text = [headers, ...rows].map(r => r.map(cell).join(',')).join('\r\n');
  saveBlob(new Blob(['﻿' + text], { type: 'text/csv;charset=utf-8' }), filename.endsWith('.csv') ? filename : filename + '.csv');
}

export const safeName = (s: string) => s.replace(/[^\w.-]+/g, '-').replace(/-+/g, '-').replace(/^-|-$/g, '');
