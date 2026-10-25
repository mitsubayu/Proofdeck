// src/main.js を 1 本の JS と CSS にまとめて ../Resources/web へ出す
import * as esbuild from 'esbuild';
import { copyFileSync, mkdirSync } from 'node:fs';
import './patches/apply.mjs';  // ライブラリへの手直しを先に当てる
const out = new URL('../Resources/web/', import.meta.url).pathname;
mkdirSync(out, { recursive: true });
const result = await esbuild.build({
  entryPoints: { viewer: 'src/main.js' },
  bundle: true,
  format: 'iife',
  minify: true,
  target: 'safari17',
  outdir: out,
  define: { 'process.env.NODE_ENV': '"production"', global: 'globalThis' },
  loader: { '.woff': 'dataurl', '.woff2': 'dataurl', '.ttf': 'dataurl', '.png': 'dataurl', '.svg': 'dataurl', '.wasm': 'binary' },
  logLevel: 'warning',
  metafile: true,
});
copyFileSync('src/index.html', out + 'index.html');
import { writeFileSync } from 'node:fs';
writeFileSync(new URL('./meta.json', import.meta.url).pathname, JSON.stringify(result.metafile));
console.log('built', out);
