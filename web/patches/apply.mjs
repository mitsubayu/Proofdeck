import { readFileSync, writeFileSync } from 'node:fs';
import { patches } from './patches.mjs';
const root = new URL('../node_modules/', import.meta.url).pathname;
let applied = 0, already = 0;
for (const p of patches) {
  for (const file of p.files) {
    const path = root + file;
    const src = readFileSync(path, 'utf8');
    if (src.includes(p.replace)) { already++; continue; }
    const n = src.split(p.find).length - 1;
    if (p.all ? n < 1 : n !== 1) throw new Error(`patch ${p.id}: 置き換え元が ${n} か所見つかった: ${file}`);
    writeFileSync(path, p.all ? src.split(p.find).join(p.replace) : src.replace(p.find, p.replace));
    applied++;
  }
}
console.log(`patches: ${applied} applied, ${already} already applied`);
