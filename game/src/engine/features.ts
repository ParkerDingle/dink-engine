// Model input contract shared by the game (TypeScript) and the training pipeline (ml/dink_ml/features.py).
// Every value is from the hitter's point of view: x is feet to the hitter's right of the center line,
// d is feet from the net. Changing this list means bumping FEATURE_VERSION and retraining.
import type { EngineState, EnginePoint, ShotType } from './rules';
import { ORDER, NET_Y } from './rules';
import { UP_DIST } from '../config';

export const FEATURE_VERSION = 'dink-features-v1';
export const FEATURE_NAMES = [
  'hit_x', 'hit_d', 'hit_h', 'in_speed', 'shot_no',
  'partner_x', 'partner_d', 'oppA_x', 'oppA_d', 'oppB_x', 'oppB_d',
  'opp_up', 'my_up',
  't_dink', 't_drop', 't_drive', 't_speedup', 't_lob', 't_putaway',
  'tgt_x', 'tgt_d',
] as const;
export const N_FEATURES = FEATURE_NAMES.length;

const HEIGHT_FT = [1.3, 3.1, 5.0];
const PACE_FTS = [18, 34, 50];

export function featuresFor(s: EngineState, type: ShotType, target: EnginePoint): number[] {
  const T = s.hitTeam, O = 1 - T;
  const mx = (x: number) => (T === 0 ? x - 10 : 10 - x);
  const d = (y: number) => Math.abs(y - NET_Y);
  const partner = s.players[s.hitter ^ 1];
  const opps = [s.players[O * 2], s.players[O * 2 + 1]].sort((a, b) => mx(a.x) - mx(b.x));
  const up = (p: EnginePoint) => (d(p.y) <= UP_DIST ? 1 : 0);
  const mine = [s.players[T * 2], s.players[T * 2 + 1]];
  return [
    mx(s.ball.x), d(s.ball.y),
    s.contactHeightFt ?? HEIGHT_FT[s.height],
    s.incomingSpeed ?? PACE_FTS[s.pace],
    Math.min(s.shotNo, 12),
    mx(partner.x), d(partner.y),
    mx(opps[0].x), d(opps[0].y), mx(opps[1].x), d(opps[1].y),
    up(opps[0]) + up(opps[1]), up(mine[0]) + up(mine[1]),
    ...ORDER.map(t => (t === type ? 1 : 0)),
    mx(target.x), d(target.y),
  ];
}
