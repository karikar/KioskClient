// =============================================================================
// A web/style.css világos témájának kontraszt-ellenőrzése (WCAG 2.1).
// Használat: node tests/contrast.test.mjs web/style.css
//
// Cél: a linkek és a szöveg soha ne tűnhessenek el a háttéren. A teszt a
// :root változóiból számolja a kontrasztarányokat, és 4,5:1 alatt bukik
// (WCAG AA normál szövegre). A linkek színe és a háttér is innen jön, így
// a téma módosításakor automatikusan kiderül, ha valami olvashatatlanná vált.
// =============================================================================
import { readFileSync } from 'node:fs';

const file = process.argv[2] || 'web/style.css';

let css;
try {
  css = readFileSync(file, 'utf8');
} catch (err) {
  console.error(`Nem olvasható CSS: ${file} (${err.message})`);
  process.exit(2);
}

const root = css.match(/:root\s*\{([\s\S]*?)\}/);
if (!root) {
  console.error('HIBA: nincs :root blokk a CSS-ben');
  process.exit(2);
}

const vars = {};
for (const m of root[1].matchAll(/--([a-z0-9-]+)\s*:\s*(#[0-9a-fA-F]{3,8})\s*;/g)) {
  vars[m[1].toLowerCase()] = m[2];
}

function parseHex(hex) {
  let h = hex.replace('#', '');
  if (h.length === 3) h = h.split('').map((c) => c + c).join('');
  return [0, 2, 4].map((i) => parseInt(h.slice(i, i + 2), 16));
}

function luminance(hex) {
  const [r, g, b] = parseHex(hex).map((v) => {
    const s = v / 255;
    return s <= 0.04045 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4;
  });
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

function contrast(a, b) {
  const la = luminance(a);
  const lb = luminance(b);
  const hi = Math.max(la, lb);
  const lo = Math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

let failed = 0;

if (!/color-scheme\s*:\s*light/.test(css)) {
  console.error('  FAIL a téma nem rögzíti a világos színsémát (color-scheme: light)');
  failed += 1;
}

// Minden pár legalább 4,5:1 legyen (WCAG AA, normál szöveg).
const pairs = [
  ['link', 'panel'],
  ['link', 'bg'],
  ['link-visited', 'panel'],
  ['link-visited', 'bg'],
  ['text', 'panel'],
  ['text', 'bg'],
  ['muted', 'panel'],
  ['muted', 'bg'],
];

for (const [fg, bg] of pairs) {
  if (!(fg in vars) || !(bg in vars)) {
    console.error(`  FAIL hiányzó színváltozó: --${fg} vagy --${bg}`);
    failed += 1;
    continue;
  }
  const ratio = contrast(vars[fg], vars[bg]);
  const ok = ratio >= 4.5;
  console.log(`  ${ok ? 'ok  ' : 'FAIL'} ${fg}/${bg}: ${ratio.toFixed(2)}:1`);
  if (!ok) failed += 1;
}

if (failed > 0) {
  console.error(`  ${failed} kontraszt-hiba - a linkek/szöveg nem elég látható`);
  process.exit(1);
}

console.log(`  ${pairs.length} pár, mind legalább 4,5:1`);
