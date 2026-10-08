// Court and physics constants. Units are feet and seconds.
// World axes: x across the court (sidelines at ±10), z along it (net at 0, your team on +z), y up.
export const W = 10;          // half court width
export const L = 22;          // half court length (baseline at ±22)
export const K = 7;           // kitchen (non-volley zone) depth
export const NET_H = 2.86;    // net height (34" center, 36" posts)
export const BALL_R = 0.125;  // ball radius
export const GRAV = 32.2;     // gravity, ft/s²
export const COR = 0.6;       // bounce restitution
export const FRIC = 0.84;     // horizontal speed kept on a bounce
export const REACH = 3.1;     // horizontal paddle reach from body center
export const REACH_H = 7.4;   // highest contact (overhead)
export const SUB = 1 / 240;   // physics substep
export const UP_DIST = 9.5;   // within this distance of the net counts as "at the kitchen line"

export const teamOf = (i: number) => (i < 2 ? 0 : 1);
export const sideSign = (t: number) => (t === 0 ? 1 : -1);
export const clamp = (v: number, a: number, b: number) => Math.max(a, Math.min(b, v));
export const lerp = (a: number, b: number, t: number) => a + (b - a) * t;

export type Vec2 = { x: number; z: number };
export type Vec3 = { x: number; y: number; z: number };
export type Rng = () => number;

export function gaussFrom(rng: Rng) {
  let u = 0, v = 0;
  while (!u) u = rng();
  while (!v) v = rng();
  return Math.sqrt(-2 * Math.log(u)) * Math.cos(2 * Math.PI * v);
}

// Small seedable RNG (mulberry32) for tests and reproducible self-play.
export function seeded(seed: number): Rng {
  let a = seed >>> 0;
  return () => {
    a |= 0; a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
