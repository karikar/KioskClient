// =============================================================================
// A generált tinyproxy szűrő minták ellenőrzése.
// Használat: node tests/proxy-filter.test.mjs <proxy-filter-fájl>
//
// A tinyproxy 1.11 filter.c a szűrőfájl sorait így dolgozza fel:
//   - a sor eleji whitespace-t levágja,
//   - a sort az első whitespace-nél vagy az első ESCAPELETLEN '#'-nél elvágja
//     (a '#' tehát a sor belsejében is megjegyzést kezd!),
//   - az üres sorokat/megjegyzéseket kihagyja,
//   - a maradékot a FilterType szerint (nálunk: ere) lefordítja.
// Ha bármelyik sor nem fordítható le, a tinyproxy a filter_init-ben
// "Bad regex in ..." hibával kilép, és a proxy nem indul el. Ezért itt is
// pontosan ugyanezt a feldolgozást szimuláljuk, és a fordfítási hibát
// kemény tesztbukásként kezeljük.
//
// A tinyproxy domain-szűrésnél (FilterURLs Off, ez az alapértelmezés) a
// csupasz hostot illeszti (pl. "www.tippmix.hu"), CONNECT-nél is a hostot,
// port nélkül. Ezért a host alakú eseteket is teszteljük, nem csak az
// URL alakúakat.
// =============================================================================
import { readFileSync } from 'node:fs';

const file = process.argv[2];
if (!file) {
  console.error('Hiányzó argumentum: proxy-filter fájl');
  process.exit(2);
}

let text;
try {
  text = readFileSync(file, 'utf8');
} catch (err) {
  console.error(`Nem olvasható szűrőfájl: ${file} (${err.message})`);
  process.exit(2);
}

const raw = text.split(/\r?\n/);

// A tinyproxy filter.c sorfeldolgozásának pontos utánzása.
function parseTinyproxyLine(line, lineno) {
  let i = 0;
  while (i < line.length && /\s/.test(line[i])) i += 1;

  let end = line.length;
  for (let j = i; j < line.length; j += 1) {
    const ch = line[j];
    if (/\s/.test(ch)) {
      end = j;
      break;
    }
    // Escapeletlen '#' -> a tinyproxy itt elvágja a sort.
    if (ch === '#' && (j === 0 || line[j - 1] !== '\\')) {
      end = j;
      break;
    }
  }

  const text = line.slice(i, end);
  return { text, cutAtHash: end < line.length && line[end] === '#' , lineno };
}

const patterns = [];
const syntaxErrors = [];

for (const [idx, line] of raw.entries()) {
  const { text, cutAtHash } = parseTinyproxyLine(line, idx + 1);
  if (text === '') continue;

  if (cutAtHash) {
    syntaxErrors.push(
      `  FAIL ${idx + 1}. sor: escapeletlen '#' - a tinyproxy itt elvágja, ` +
      `a maradék érvénytelen regex lenne: ${line.trim()}`,
    );
    continue;
  }

  try {
    // A FilterCaseSensitive Off miatt a tinyproxy REG_ICASE-szel illeszt.
    patterns.push({ re: new RegExp(text, 'i'), text });
  } catch (err) {
    syntaxErrors.push(
      `  FAIL ${idx + 1}. sor: érvénytelen regex (${err.message}): ${text}`,
    );
  }
}

if (syntaxErrors.length > 0) {
  for (const msg of syntaxErrors) console.error(msg);
  console.error('  A tinyproxy ezekkel a mintákkal nem indul el.');
  process.exit(1);
}

if (patterns.length === 0) {
  console.error('Nincs minta a szűrőfájlban');
  process.exit(2);
}

const allowed = (value) => patterns.some(({ re }) => re.test(value));

// URL alak (ha valaki FilterURLs-t kapcsolna) és host alak (a valóságban
// ezt illeszti a tinyproxy domain-szűrésnél).
const mustAllow = [
  'http://www.tippmix.hu/',
  'https://www.tippmix.hu/',
  'https://tippmix.hu/',
  'www.tippmix.hu:443',
  'tippmix.hu:443',
  'www.tippmix.hu',
  'tippmix.hu',
  'static.tippmix.hu',
  'https://static.tippmix.hu/assets/app.js',
  'http://schedulerzrh.aitcloud.de/retail_scheduler/display/index/schedule:13a92cec0a3b58c3944f2e4b0f2c1ef6',
  'schedulerzrh.aitcloud.de:80',
  'schedulerzrh.aitcloud.de',
  'https://bet.szerencsejatek.hu/nyeremenyjegyzek',
  'bet.szerencsejatek.hu:443',
  'bet.szerencsejatek.hu',
  'https://szerencsejatek.hu/',
  'https://www.szerencsejatek.hu/',
  'www.szerencsejatek.hu',
  'https://www.hasznaltauto.hu/kereses',
  'hasznaltauto.hu:443',
  'www.hasznaltauto.hu',
  // A FilterCaseSensitive Off miatt a kis/nagybetű nem számít.
  'HTTPS://WWW.TIPPMIX.HU/',
  'WWW.SZERENCSEJATEK.HU',
];

const mustBlock = [
  'http://evil.com/',
  'https://evil.com/',
  'evil.com:443',
  'evil.com',
  'https://szerencsejatek.hu.evil.com/',
  'szerencsejatek.hu.evil.com:443',
  'szerencsejatek.hu.evil.com',
  'http://tippmix.hu.evil.com/',
  'tippmix.hu.evil.com',
  'https://notszerencsejatek.hu/',
  'notszerencsejatek.hu',
  'https://example.org/',
  'example.org',
];

let failed = 0;

for (const url of mustAllow) {
  if (!allowed(url)) {
    console.error(`  FAIL engedélyezni kellett volna: ${url}`);
    failed += 1;
  }
}

for (const url of mustBlock) {
  if (allowed(url)) {
    console.error(`  FAIL tiltani kellett volna: ${url}`);
    failed += 1;
  }
}

console.log(
  `  ${patterns.length} minta, ${mustAllow.length} engedélyezett + ` +
  `${mustBlock.length} tiltott eset`,
);
process.exit(failed === 0 ? 0 : 1);
