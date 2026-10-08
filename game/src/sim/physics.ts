// Ball flight. Gravity-only ballistic steps are exact for any step size, so the shot solver
// (which works out launch velocities analytically) and the simulation always agree.
import { BALL_R, COR, FRIC, GRAV, NET_H, K, L, W, clamp, sideSign, gaussFrom, type Rng, type Vec3, type Vec2 } from '../config';
import type { ShotType } from '../engine/rules';

export interface BallState { p: Vec3; v: Vec3; netted: boolean; rolling: boolean }
export interface BounceEvent { type: 'bounce'; p: Vec2; side: number; roll: boolean; speed: number }
export interface NetEvent { type: 'net' }
export type PhysEvent = BounceEvent | NetEvent;

export function stepBall(q: BallState, h: number, ev?: PhysEvent[]) {
  const pz = q.p.z, py = q.p.y;
  q.p.x += q.v.x * h; q.p.z += q.v.z * h;
  if (q.rolling) { q.p.y = BALL_R; q.v.y = 0; q.v.x *= 0.992; q.v.z *= 0.992; }
  else { q.p.y += q.v.y * h - 0.5 * GRAV * h * h; q.v.y -= GRAV * h; }
  if (!q.netted && pz !== 0 && (pz > 0) !== (q.p.z > 0) && Math.abs(q.p.x) < 11) {
    const f = pz / (pz - q.p.z), yc = py + (q.p.y - py) * f;
    if (yc < NET_H + BALL_R * 0.3) {
      q.netted = true;
      const s = Math.sign(pz);
      q.p.z = s * 0.22; q.v.z = -q.v.z * 0.12; q.v.x *= 0.3; q.v.y = Math.min(q.v.y, 0) * 0.4;
      ev?.push({ type: 'net' });
    }
  }
  if (!q.rolling && q.p.y < BALL_R && q.v.y < 0) {
    q.p.y = BALL_R;
    const roll = q.v.y > -2.2;
    ev?.push({ type: 'bounce', p: { x: q.p.x, z: q.p.z }, side: q.p.z > 0 ? 0 : 1, roll, speed: -q.v.y });
    if (!roll) { q.v.y = -q.v.y * COR; q.v.x *= FRIC; q.v.z *= FRIC; }
    else { q.v.y = 0; q.rolling = true; }
  }
}

export interface Sample { t: number; x: number; y: number; z: number; vx: number; vy: number; vz: number; bounces: number; netted: boolean }
export interface Prediction { samples: Sample[]; firstBounce: { t: number; x: number; z: number; side: number } | null }

export function predict(b: BallState, bouncesSoFar: number, t0: number, maxT = 3.4): Prediction {
  const q: BallState = { p: { ...b.p }, v: { ...b.v }, netted: b.netted, rolling: b.rolling };
  const samples: Sample[] = [];
  let t = t0, bounces = bouncesSoFar, firstBounce: Prediction['firstBounce'] = null;
  const h = 1 / 120;
  for (let k = 0; k < maxT / h; k++) {
    const ev: PhysEvent[] = [];
    stepBall(q, h, ev); t += h;
    for (const e of ev) if (e.type === 'bounce') {
      bounces += e.roll ? 2 : 1;
      if (!firstBounce) firstBounce = { t, x: e.p.x, z: e.p.z, side: e.side };
    }
    samples.push({ t, x: q.p.x, y: q.p.y, z: q.p.z, vx: q.v.x, vy: q.v.y, vz: q.v.z, bounces, netted: q.netted });
    if (bounces >= 2) break;
  }
  return { samples, firstBounce };
}

export type Fault = 'net' | 'long' | 'wide' | 'popup' | null;
export interface LaunchOpts {
  T: number;                // hitting team
  mult?: number;            // execution scatter multiplier (skill)
  q?: number;               // footwork quality 0..1
  inSpeed?: number;         // incoming ball speed
  isReturn?: boolean;
  serveSpeed?: number;
  fault?: Fault;            // forced execution error
  exact?: boolean;          // no randomness (feeds, tests)
  clearMul?: number;
  speedMul?: number;
}
const CLEAR: Partial<Record<ShotType, number>> = { dink: 0.95, drop: 1.5, lob: 9.5 };
const SPEED: Partial<Record<ShotType, number>> = { drive: 50, speedup: 46, putaway: 60 };
const SIGMA: Record<string, number> = { dink: 0.45, drop: 0.75, drive: 0.9, speedup: 0.8, lob: 1.2, putaway: 0.7, serve: 0.95 };

/** Launch velocity that lands the ball at `target`, plus execution scatter. */
export function launchVelocity(from: Vec3, target: Vec2, type: ShotType | 'serve', o: LaunchOpts, rng: Rng): Vec3 {
  const gauss = () => gaussFrom(rng);
  const exact = !!o.exact;
  let mult = (o.mult ?? 1) * (1 + 1.3 * (1 - (o.q ?? 0.9)));
  const inSpeed = o.inSpeed ?? 0;
  if (inSpeed > 42) mult *= 1.3;
  const attacking = type === 'drive' || type === 'speedup' || type === 'putaway';
  if (attacking && from.y < 2.0) mult *= 1.35;
  if (type === 'putaway' && from.y > 4.5) mult *= 0.8;
  const sig = exact ? 0 : (SIGMA[type] ?? 1) * mult;
  const tg = { x: target.x + gauss() * sig * 0.8, z: target.z + gauss() * sig };
  const away = -sideSign(o.T);
  if (o.fault === 'long') tg.z = away * (L + 1.2 + rng() * 3);
  if (o.fault === 'wide') tg.x = (Math.sign(tg.x) || 1) * (W + 0.8 + rng() * 2);
  if (o.fault === 'popup') tg.z = away * clamp(Math.abs(tg.z) + 5 + rng() * 3, 6, 15);
  const soft = type === 'dink' || type === 'drop' || type === 'lob';
  const dx = tg.x - from.x, dz = tg.z - from.z;
  const f = clamp(-from.z / dz, 0.04, 0.96);
  const tClear = (c: number) => {
    const num = NET_H + c - from.y * (1 - f) - BALL_R * f;
    return num <= 0 ? 0 : Math.sqrt(num / (0.5 * GRAV * f * (1 - f)));
  };
  let t: number;
  if (soft) {
    let c = (CLEAR[type as ShotType] ?? 1) * (type === 'drop' && inSpeed > 42 ? 0.65 : 1) * (o.clearMul ?? 1);
    if (!exact) c += (type === 'dink' ? Math.abs(gauss()) * 0.55 - 0.12 : gauss() * 0.2) * mult;
    if (o.fault === 'net') c = -0.4 - rng() * 0.6;
    if (o.fault === 'popup') c += 3 + rng() * 1.5;
    t = Math.max(0.42, tClear(c));
  } else {
    const hs = type === 'serve' ? (o.serveSpeed ?? 40) : (o.isReturn && type === 'drive' ? 40 : SPEED[type as ShotType] ?? 45) * (o.speedMul ?? 1);
    t = Math.max(Math.hypot(dx, dz) / hs, tClear(type === 'serve' ? 1.0 : 0.35));
  }
  const v = { x: dx / t, z: dz / t, y: (BALL_R - from.y + 0.5 * GRAV * t * t) / t };
  if (!soft && !exact) v.y += gauss() * 0.45 * mult;
  if (!soft && o.fault === 'net') v.y -= 2.6 + rng() * 1.5;
  return v;
}

/** Clamp an aim point to where a shot type can land, on the side opposite team T. */
export function clampAim(type: ShotType | 'serve', a: Vec2, T: number, serveBoxSign = 1): Vec2 {
  const s = -sideSign(T);
  let lo = 7.4, hi = 21.2, xlo = -9.4, xhi = 9.4;
  if (type === 'dink' || type === 'drop') { lo = 0.9; hi = 6.6; }
  else if (type === 'lob') { lo = 15; hi = 21.2; }
  else if (type === 'putaway') { lo = 1; hi = 21.2; }
  else if (type === 'serve') { lo = K + 1.2; hi = 20.8; if (serveBoxSign > 0) { xlo = 0.6; xhi = 9.0; } else { xlo = -9.0; xhi = -0.6; } }
  return { x: clamp(a.x, xlo, xhi), z: s * clamp(a.z * s, lo, hi) };
}
