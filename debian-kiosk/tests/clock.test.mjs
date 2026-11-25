// =============================================================================
// A fejléc dátum/névnap formázásának tesztje (Node).
// Használat: node tests/clock.test.mjs
// =============================================================================
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const clock = require('../web/clock.js');

const cases = [
  {
    date: new Date(2026, 10, 22, 23, 10),
    want: '2026. november 22. (vasárnap) · 23:10 · Névnap: Cecília',
  },
  {
    date: new Date(2026, 0, 1, 0, 0),
    want: '2026. január 1. (csütörtök) · 00:00 · Névnap: Fruzsina',
  },
  {
    date: new Date(2026, 2, 15, 12, 0),
    want: '2026. március 15. (vasárnap) · 12:00 · Névnap: Kristóf',
  },
  {
    // Szökőév: február 29. a 28-i névnapot kapja (Mátyás ugrása).
    date: new Date(2024, 1, 29, 8, 5),
    want: '2024. február 29. (csütörtök) · 08:05 · Névnap: Elemér',
  },
  {
    // Szökőévben február 24. szökőnap - nincs névnap.
    date: new Date(2024, 1, 24, 8, 5),
    want: '2024. február 24. (szombat) · 08:05',
  },
  {
    date: new Date(2023, 1, 28, 8, 5),
    want: '2023. február 28. (kedd) · 08:05 · Névnap: Elemér',
  },
];

let failed = 0;

for (const c of cases) {
  const got = clock.format(c.date);
  if (got === c.want) {
    console.log(`  ok   ${c.date.toISOString().slice(0, 10)}: ${got}`);
  } else {
    console.error(`  FAIL ${c.date.toISOString().slice(0, 10)}\n    kapott: ${got}\n    várt:   ${c.want}`);
    failed += 1;
  }
}

// Szökőévi eltolás ellenőrzése.
const shift = [
  [new Date(2024, 1, 25), ['Mátyás', 'Jázmin']],
  [new Date(2024, 1, 26), ['Géza']],
  [new Date(2024, 1, 27), ['Edina']],
  [new Date(2024, 1, 28), ['Ákos', 'Bátor']],
  [new Date(2024, 1, 29), ['Elemér']],
];

for (const [date, want] of shift) {
  const got = clock.namesFor(date);
  if (JSON.stringify(got) === JSON.stringify(want)) {
    console.log(`  ok   szökőnap ${date.getMonth() + 1}. ${date.getDate()}. -> ${got.join(', ')}`);
  } else {
    console.error(`  FAIL szökőnap ${date.getMonth() + 1}. ${date.getDate()}. -> ${got.join(', ')} (várt: ${want.join(', ')})`);
    failed += 1;
  }
}

// Az adatbázis teljessége: 365 nap, mindegyikhez 1-3 név.
const keys = Object.keys(clock.NAMEDAYS);
if (keys.length === 365) {
  console.log('  ok   365 nap az adatbázisban');
} else {
  console.error(`  FAIL ${keys.length} nap van 365 helyett`);
  failed += 1;
}

for (const key of keys) {
  const names = clock.NAMEDAYS[key];
  if (!Array.isArray(names) || names.length < 1 || names.length > 3) {
    console.error(`  FAIL érvénytelen névnap: ${key}`);
    failed += 1;
  }
}

if (failed > 0) {
  console.error(`  ${failed} hiba a dátum/névnap tesztben`);
  process.exit(1);
}

console.log(`  ${cases.length + shift.length + 1} ellenőrzés, mind OK`);
