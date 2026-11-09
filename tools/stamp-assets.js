#!/usr/bin/env node
// Stamps every /assets/... reference in the HTML pages with a short content
// hash: /assets/audac-shell.js?v=3f9a1c2b. The service worker keeps stamped
// files on the phone (cache-first), so a changed file MUST get a new stamp --
// run this before every commit that touches /assets:
//
//   node tools/stamp-assets.js          (rewrites the HTML in place)
//   node tools/stamp-assets.js --check  (exit 1 if any stamp is out of date)
//
// No dependencies; works from any working directory.
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const root = path.resolve(__dirname, '..');
const check = process.argv.includes('--check');
const hashes = new Map();
const hashOf = (name) => {
  if (!hashes.has(name)) {
    const file = path.join(root, 'assets', name);
    if (!fs.existsSync(file)) throw new Error(`Missing asset: assets/${name}`);
    hashes.set(name, crypto.createHash('sha1').update(fs.readFileSync(file)).digest('hex').slice(0, 8));
  }
  return hashes.get(name);
};

let stale = 0;
for (const f of fs.readdirSync(root).filter(n => n.endsWith('.html'))) {
  const file = path.join(root, f);
  const before = fs.readFileSync(file, 'utf8');
  const after = before.replace(/((?:src|href)=")\/assets\/([\w.-]+\.(?:js|css|webp|png|svg))(?:\?v=[\w]*)?"/g,
    (_, attr, name) => `${attr}/assets/${name}?v=${hashOf(name)}"`);
  if (after !== before) {
    stale++;
    if (check) console.log(`out of date: ${f}`);
    else { fs.writeFileSync(file, after); console.log(`stamped: ${f}`); }
  }
}
if (check && stale) { console.log(`${stale} page(s) need: node tools/stamp-assets.js`); process.exit(1); }
if (!check && !stale) console.log('all stamps up to date');
