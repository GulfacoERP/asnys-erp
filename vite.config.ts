import { defineConfig, loadEnv, type Plugin } from 'vite';
import react from '@vitejs/plugin-react';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';

const PRODUCT = 'Asnys ERP';
const esc = (s: string) => s.replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]!));

/** VITE_BRAND_NAME / VITE_BRAND_MARK: a copy set up for one company shows its name in the browser tab,
 *  on the installed phone app and in the icon letter. Left empty, everything says Asnys ERP. */
function brand(name: string, mark: string): Plugin {
  let outDir = 'dist';
  return {
    name: 'asnys-brand',
    configResolved(c) { outDir = resolve(c.root, c.build.outDir); },
    transformIndexHtml: html => name === PRODUCT ? html : html.replaceAll(PRODUCT, esc(name)),
    closeBundle() {
      if (name === PRODUCT) return;
      const mf = resolve(outDir, 'manifest.webmanifest');
      if (existsSync(mf)) {
        const m = JSON.parse(readFileSync(mf, 'utf8'));
        m.name = name; m.short_name = name.length > 12 ? name.split(/\s+/)[0] : name;
        writeFileSync(mf, JSON.stringify(m, null, 2));
      }
      // A branded copy gets a lettered icon instead of the Asnys mark.
      writeFileSync(resolve(outDir, 'favicon.svg'), `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><rect width="32" height="32" rx="8" fill="#1d6b55"/><text x="16" y="22" text-anchor="middle" font-family="Arial,sans-serif" font-weight="700" font-size="${mark.length > 1 ? 14 : 18}" fill="#fff">${esc(mark)}</text></svg>`);
    },
  };
}

export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, process.cwd(), 'VITE_');
  const name = (env.VITE_BRAND_NAME || '').trim() || PRODUCT;
  const mark = ((env.VITE_BRAND_MARK || '').trim() || name.charAt(0)).slice(0, 2).toUpperCase();
  return { plugins: [react(), brand(name, mark)] };
});
