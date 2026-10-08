// Usage: npm run selfplay -- [rallies=40000] [out=../ml/data/selfplay.csv] [seed=7]
import { writeFileSync, mkdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { runSelfPlay } from '../src/sim/selfplay';
import { FEATURE_NAMES, FEATURE_VERSION } from '../src/engine/features';

const n = Number(process.argv[2] ?? 40000);
const out = resolve(process.argv[3] ?? '../ml/data/selfplay.csv');
const seed = Number(process.argv[4] ?? 7);
const t0 = Date.now();
const r = runSelfPlay(n, seed);
const lines = [[...FEATURE_NAMES, 'won', 'rally_id'].join(',')];
for (const row of r.rows) lines.push([...row.features.map(v => +v.toFixed(4)), row.won, row.rally].join(','));
mkdirSync(dirname(out), { recursive: true });
writeFileSync(out, lines.join('\n') + '\n');
writeFileSync(out.replace(/\.csv$/, '.meta.json'), JSON.stringify({
  feature_version: FEATURE_VERSION, rallies: r.rallies, rows: r.rows.length, avg_shots: +(r.shots / r.rallies).toFixed(2),
  server_win_rate: +(r.serverWins / r.rallies).toFixed(3), seed, source: 'self-play (rule engine + ballistic sim)', created: new Date().toISOString(),
}, null, 2));
console.log(`${r.rallies} rallies, ${r.rows.length} shots, avg ${(r.shots / r.rallies).toFixed(1)} shots/rally, server wins ${(100 * r.serverWins / r.rallies).toFixed(1)}% → ${out} (${((Date.now() - t0) / 1000).toFixed(1)}s)`);
