// Cross-checks the database's fee arithmetic (billing_compute_fee) against a second, independent implementation written with whole-number (BigInt) arithmetic and no decimals at all,
// over thousands of generated cases, including every case that lands exactly on half a pesewa. Any disagreement is a bug in one of them.
//
//   npx tsx tests/local-supabase/platform-billing-fee-reference.local.mjs
//
// Needs the local Docker database with migrations through 20261202110000. It only calls a pure function; it reads and writes nothing.
import { execFileSync } from "node:child_process";

// The SQL goes in through standard input (a long VALUES list does not fit on a Windows command line).
const psql = (sql) =>
  execFileSync("docker", ["exec", "-i", "supabase_db_drugxone-local-validation", "psql", "-U", "postgres", "-At", "-F", "|"], { input: sql, maxBuffer: 64 * 1024 * 1024 }).toString().trim();

// The reference. Money in pesewas (cents), the percentage in ten-thousandths of a percent; everything is a BigInt.
//   fee = billable x percent / 100 = cents x pct_e4 / 1_000_000 (cents), rounded half up once, after the per-order minimum and maximum.
const SCALE = 1_000_000n;
const roundHalfUp = (numerator) => (numerator * 2n + SCALE) / (2n * SCALE); // numerator is in millionths of a cent; non-negative
const reference = (billableCents, pctE4, minCents, maxCents) => {
  const raw = billableCents * pctE4;
  const calculated = roundHalfUp(raw);
  if (pctE4 === 0n || billableCents === 0n) return { calculated, after: 0n };
  let v = raw;
  if (minCents !== null && v < minCents * SCALE) v = minCents * SCALE;
  if (maxCents !== null && v > maxCents * SCALE) v = maxCents * SCALE;
  return { calculated, after: roundHalfUp(v) };
};
const money = (cents) => `${cents / 100n}.${String(cents % 100n).padStart(2, "0")}`;
const decimal = (cents) => (cents === null ? "NULL" : money(cents));
const pct = (e4) => `${e4 / 10000n}.${String(e4 % 10000n).padStart(4, "0")}`;

// A small deterministic generator, so a failure can be reproduced.
let seed = 123456789n;
const next = () => {
  seed = (seed * 6364136223846793005n + 1442695040888963407n) & ((1n << 64n) - 1n);
  return seed >> 11n;
};
const between = (lo, hi) => lo + (next() % (hi - lo + 1n));

const cases = [];
// Exactly on half a pesewa: fee is k + 0.5 cents.
for (let b = 1n; b <= 400n; b += 1n) for (const p of [5000n, 2500n, 7500n, 10000n, 500n]) cases.push([b, p, null, null]);
for (let i = 0; i < 3000; i += 1) {
  const billable = [between(0n, 500n), between(0n, 100000n), between(0n, 100000000n), between(0n, 5000000000n)][Number(between(0n, 3n))];
  const percent = [between(0n, 100n), between(0n, 10000n), between(0n, 1000000n)][Number(between(0n, 2n))];
  const min = between(0n, 3n) === 0n ? between(0n, 5000n) : null;
  const max = between(0n, 3n) === 0n ? between(min ?? 0n, (min ?? 0n) + between(0n, 100000n)) : null;
  cases.push([billable, percent, min, max]);
}

const BATCH = 500;
let checked = 0;
let bad = 0;
for (let start = 0; start < cases.length; start += BATCH) {
  const chunk = cases.slice(start, start + BATCH);
  const values = chunk.map(([b, p, mn, mx], i) => `(${start + i}, ${decimal(b)}::numeric, ${pct(p)}::numeric, ${decimal(mn)}::numeric, ${decimal(mx)}::numeric)`).join(",");
  const out = psql(`SELECT v.i, f.calculated_fee, f.fee_after_limits FROM (VALUES ${values}) v(i, b, p, mn, mx), LATERAL public.billing_compute_fee(v.b, v.p, v.mn, v.mx) f ORDER BY v.i`);
  const rows = out.split("\n").map((line) => line.split("|"));
  if (rows.length !== chunk.length) throw new Error(`expected ${chunk.length} rows, got ${rows.length}`);
  rows.forEach(([i, calc, after]) => {
    const [b, p, mn, mx] = cases[Number(i)];
    const ref = reference(b, p, mn, mx);
    checked += 1;
    if (calc !== money(ref.calculated) || after !== money(ref.after)) {
      bad += 1;
      if (bad <= 10) console.log(`MISMATCH case ${i}: billable ${money(b)} at ${pct(p)}% min ${decimal(mn)} max ${decimal(mx)} -> database ${calc}/${after}, reference ${money(ref.calculated)}/${money(ref.after)}`);
    }
  });
}
console.log(`${bad === 0 ? "PASS" : "FAIL"} | ${checked} generated fee cases agree with the independent whole-number reference (${bad} disagreements)`);
if (bad > 0) process.exitCode = 1;
