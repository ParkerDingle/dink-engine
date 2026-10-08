// Headless AI-vs-AI rallies. Produces labelled shot rows in the model's feature format, used to
// bootstrap the shot-value model before real tracked footage exists (see ml/README.md).
import { Match } from './match';
import { seeded } from '../config';

export interface SelfPlayResult {
  rows: { features: number[]; won: number; rally: number }[];
  rallies: number; shots: number; serverWins: number; reasons: Record<string, number>;
}

export function runSelfPlay(nRallies: number, seed = 1, tau = 0.05): SelfPlayResult {
  const m = new Match(seeded(seed));
  m.mode = 'selfplay'; m.selfplayTau = tau; m.level = 'pro';
  const res: SelfPlayResult = { rows: [], rallies: 0, shots: 0, serverWins: 0, reasons: {} };
  for (let r = 0; r < nRallies; r++) {
    m.server = r % 2; m.score = [r % 3, (r >> 1) % 3];
    m.newRally();
    let guard = 0;
    while (!m.rallyOver && guard++ < 9000) m.update(1 / 60);
    if (!m.rallyOver) m.point(0, 'Rally reset');
    const rally = m.rally!;
    res.rallies++; res.shots += rally.shots.length;
    if (rally.result!.winner === rally.serverTeam) res.serverWins++;
    res.reasons[rally.result!.reason] = (res.reasons[rally.result!.reason] || 0) + 1;
  }
  const winners = new Map(m.labels.map(l => [l.rally, l.winner]));
  for (const row of m.log) {
    const w = winners.get(row.rally);
    if (w == null) continue;
    res.rows.push({ features: row.features, won: row.team === w ? 1 : 0, rally: row.rally });
  }
  return res;
}
