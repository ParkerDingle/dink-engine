// Rule-based shot evaluator. It encodes basic pro doubles strategy and is the fallback
// whenever a trained model isn't loaded. It also supplies the execution odds (pErr, pWin)
// the simulation uses for every option, trained model or not.
//
// Engine coordinates: x 0..20 across, y 0..44 along the court, net at y = 22.
// Team 0 (you) is on y > 22. Players: 0 your-left, 1 your-right, 2 their-left, 3 their-right
// (left/right as seen from your baseline).
import { clamp, UP_DIST } from '../config';

export type ShotType = 'dink' | 'drop' | 'drive' | 'speedup' | 'lob' | 'putaway';
export const ORDER: ShotType[] = ['dink', 'drop', 'drive', 'speedup', 'lob', 'putaway'];
export const SHOTS: Record<ShotType, { name: string; depths: number[] }> = {
  dink: { name: 'Dink', depths: [0] },
  drop: { name: 'Drop', depths: [0] },
  drive: { name: 'Drive', depths: [1, 2] },
  speedup: { name: 'Speed-up', depths: [1, 2] },
  lob: { name: 'Lob', depths: [2] },
  putaway: { name: 'Put-away', depths: [0, 1] },
};
export const NET_Y = 22;
export const DEPTH_BOUNDS: [number, number][] = [[0, 7], [7, 14.5], [14.5, 22]];
const DEPTH_CENTER = [3.5, 10.75, 18.25];
const COL_NAMES = ['left', 'middle', 'right'];
const DEPTH_NAMES = ['kitchen', 'mid-court', 'deep'];

export interface EnginePoint { x: number; y: number }
export interface EngineState {
  hitTeam: number;
  hitter: number;
  players: EnginePoint[];
  ball: EnginePoint;
  /** 0 below net height, 1 about net height, 2 above the net */
  height: number;
  /** 0 soft, 1 medium, 2 hard */
  pace: number;
  /** number of the shot about to be hit (1 = serve, 2 = return, 3 = third shot) */
  shotNo: number;
  /** optional extra detail used by the trained model */
  contactHeightFt?: number;
  incomingSpeed?: number;
}
export interface ShotOption {
  type: ShotType; label: string; col: number; depth: number; zone: string;
  target: EnginePoint; pErr: number; pWin: number; v: number; P: number;
}
export type Availability = Record<ShotType, { ok: boolean; why?: string }>;

const nd = (y: number) => Math.abs(y - NET_Y);
const sideY = (team: number, dist: number) => (team === 0 ? NET_Y + dist : NET_Y - dist);
const isUp = (p: EnginePoint) => nd(p.y) <= UP_DIST;

export function zoneCenter(team: number, col: number, depth: number): EnginePoint {
  return { x: (col + 0.5) * 20 / 3, y: sideY(team, DEPTH_CENTER[depth]) };
}
export const zoneName = (col: number, depth: number) => `${COL_NAMES[col]} ${DEPTH_NAMES[depth]}`;

export function label(type: ShotType, s: Pick<EngineState, 'pace' | 'shotNo'>): string {
  if (type === 'drop' && s.pace === 2 && s.shotNo !== 2) return 'Reset';
  if (type === 'speedup' && s.pace === 2) return 'Counter';
  return SHOTS[type].name;
}

export function availability(s: EngineState): Availability {
  const up = nd(s.ball.y) <= UP_DIST;
  if (s.shotNo === 2) {
    const no = { ok: false, why: 'Not on the return' };
    return { dink: no, speedup: no, putaway: no, drive: { ok: true }, drop: { ok: true }, lob: { ok: true } };
  }
  return {
    dink: up ? (s.pace <= 1 ? { ok: true } : { ok: false, why: 'Too fast to dink' }) : { ok: false, why: 'Get to the line first' },
    drop: !up || s.pace === 2 ? { ok: true } : { ok: false, why: 'At the line, dink instead' },
    drive: !up ? { ok: true } : { ok: false, why: 'At the line, use a speed-up' },
    speedup: up ? { ok: true } : { ok: false, why: 'Only from the kitchen line' },
    lob: { ok: true },
    putaway: s.height === 2 ? { ok: true } : { ok: false, why: 'Needs a ball above the net' },
  };
}

export function evaluate(s: EngineState): ShotOption[] {
  const T = s.hitTeam, O = 1 - T;
  const d = nd(s.ball.y), h = s.height, p = s.pace;
  const opps = [s.players[O * 2], s.players[O * 2 + 1]];
  const mine = [s.players[T * 2], s.players[T * 2 + 1]];
  const oppUp = opps.filter(isUp).length, myUp = mine.filter(isUp).length;
  const hitterCol = s.ball.x < 20 / 3 ? 0 : s.ball.x > 40 / 3 ? 2 : 1;
  const avail = availability(s);
  const ret = s.shotNo === 2;
  const res: ShotOption[] = [];
  for (const type of ORDER) {
    if (!avail[type].ok) continue;
    for (const depth of SHOTS[type].depths) for (let col = 0; col < 3; col++) {
      const tp = zoneCenter(O, col, depth);
      let dmin = Infinity, nearest = opps[0];
      for (const o of opps) { const dd = Math.hypot(o.x - tp.x, o.y - tp.y); if (dd < dmin) { dmin = dd; nearest = o; } }
      const open = clamp((dmin - 3) / 9, 0, 1);
      const targetBack = !isUp(nearest);
      const wide = col !== 1 ? 1 : 0, middle = col === 1 ? 1 : 0;
      const cross = (hitterCol === 0 && col === 2) || (hitterCol === 2 && col === 0) ? 1 : 0;
      let pErr = 0, pWin = 0, v = 0.5;
      switch (type) {
        case 'dink':
          pErr = 0.025 + (p === 1 ? 0.03 : 0) + (wide && !cross ? 0.03 : 0) - 0.01 * cross + (h === 0 ? 0.01 : 0);
          pWin = 0.01 + 0.02 * open + (targetBack ? 0.05 : 0);
          v = 0.5 + 0.03 * cross + 0.015 * middle + (targetBack ? 0.06 : 0) + 0.04 * (myUp - oppUp) + (h === 1 ? 0.01 : 0);
          break;
        case 'drop':
          if (ret) { pErr = 0.07 + 0.0045 * d + 0.02 * wide; pWin = 0.01; v = 0.46 + 0.02 * middle; break; }
          pErr = 0.05 + 0.0045 * d + (p === 2 ? 0.03 : 0) + 0.02 * wide - (h === 2 ? 0.02 : 0);
          pWin = 0.01 + (oppUp < 2 ? 0.02 : 0) + (targetBack ? 0.03 : 0);
          v = (d > 16 ? 0.46 : d > UP_DIST ? 0.48 : 0.5) + 0.03 * middle + (targetBack ? 0.07 : 0) + 0.03 * (2 - oppUp);
          break;
        case 'drive':
          if (ret) { pErr = 0.04 + 0.03 * wide + (depth === 2 ? 0.02 : 0); pWin = 0.02 + 0.02 * open; v = (depth === 2 ? 0.58 : 0.52) + 0.02 * middle; break; }
          pErr = 0.06 + 0.04 * wide + (depth === 2 ? 0.03 : 0) + (h === 0 ? (d <= 13 ? 0.05 : 0.02) : 0) - (h === 2 ? 0.02 : 0) + (p === 2 ? 0.03 : 0);
          pWin = 0.04 + 0.06 * open + (h === 2 ? 0.1 : 0) + (h === 1 ? 0.02 : 0);
          v = (oppUp === 2 ? 0.4 : oppUp === 1 ? 0.46 : 0.52) + 0.04 * middle + (h === 2 ? 0.05 : 0) - (h === 0 ? 0.03 : 0) + (targetBack && depth === 1 ? 0.03 : 0);
          break;
        case 'speedup':
          pErr = 0.07 + (h === 0 ? 0.1 : 0) - (h === 2 ? 0.03 : 0) + 0.03 * wide + (depth === 2 ? 0.04 : 0) + (p === 2 ? 0.04 : 0);
          pWin = 0.08 + (h === 1 ? 0.1 : 0) + (h === 2 ? 0.22 : 0) - (h === 0 ? 0.04 : 0) + 0.05 * open + (targetBack ? 0.05 : 0);
          v = 0.4 + 0.05 * h + 0.02 * middle;
          break;
        case 'lob':
          pErr = 0.11 + 0.04 * wide + (p === 2 ? 0.06 : 0) + (d > 16 ? 0.02 : 0);
          pWin = (oppUp === 2 && h === 0 && d <= UP_DIST ? 0.08 : 0.03) + 0.02 * cross;
          v = ret ? 0.4 : oppUp === 2 ? (d <= UP_DIST ? 0.42 : 0.36) : 0.34;
          break;
        case 'putaway':
          pErr = 0.05 + 0.03 * wide + (depth === 0 ? 0.02 : 0) + (d > 16 ? 0.04 : 0);
          pWin = 0.36 + 0.15 * open + (targetBack ? 0.05 : 0) + (depth === 0 ? 0.05 : 0) - (d > 16 ? 0.15 : 0);
          v = 0.58;
          break;
      }
      pErr = clamp(pErr, 0.01, 0.6); pWin = clamp(pWin, 0, 0.9);
      const P = clamp(pWin + (1 - pErr - pWin) * v, 0.02, 0.97);
      res.push({ type, label: label(type, s), col, depth, zone: zoneName(col, depth), target: tp, pErr, pWin, v, P });
    }
  }
  res.sort((a, b) => b.P - a.P);
  return res;
}

export interface Grade { max: number; key: 'best' | 'good' | 'inacc' | 'mistake' | 'blunder'; name: string; glyph: string }
export const GRADES: Grade[] = [
  { max: 1.5, key: 'best', name: 'Best shot', glyph: '!' },
  { max: 4, key: 'good', name: 'Good', glyph: '+' },
  { max: 8, key: 'inacc', name: 'Inaccuracy', glyph: '?!' },
  { max: 15, key: 'mistake', name: 'Mistake', glyph: '?' },
  { max: Infinity, key: 'blunder', name: 'Blunder', glyph: '??' },
];
export const grade = (lossPts: number) => GRADES.find(g => lossPts <= g.max)!;
export const accuracy = (lossPts: number) => Math.max(0, 100 - 5 * lossPts);

/** Softmax pick over options. tau ~0.012 plays like a pro, ~0.045 like a club player. */
export function choose(opts: ShotOption[], tau: number, rng: () => number): ShotOption {
  const best = opts[0].P;
  const w = opts.map(o => Math.exp((o.P - best) / tau));
  let r = rng() * w.reduce((a, b) => a + b, 0);
  for (let i = 0; i < opts.length; i++) { r -= w[i]; if (r <= 0) return opts[i]; }
  return opts[0];
}

/** Starting positions for a rally with rally scoring (server side depends on the serving team's score). */
export function rallyStart(serverTeam: number, serverScore: number) {
  const odd = serverScore % 2 === 1;
  const P: EnginePoint[] = [];
  let server: number, receiver: number;
  if (serverTeam === 0) {
    P[0] = { x: 5, y: 45 }; P[1] = { x: 15, y: 45 };
    server = odd ? 0 : 1; receiver = odd ? 3 : 2;
    P[2] = { x: 5, y: receiver === 2 ? -1 : 14 }; P[3] = { x: 15, y: receiver === 3 ? -1 : 14 };
  } else {
    P[2] = { x: 5, y: -1 }; P[3] = { x: 15, y: -1 };
    server = odd ? 3 : 2; receiver = odd ? 0 : 1;
    P[0] = { x: 5, y: receiver === 0 ? 45 : 30 }; P[1] = { x: 15, y: receiver === 1 ? 45 : 30 };
  }
  return { server, receiver, players: P };
}
