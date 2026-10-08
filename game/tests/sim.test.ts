import { describe, expect, it } from 'vitest';
import { launchVelocity, stepBall, clampAim, type BallState } from '../src/sim/physics';
import { Match } from '../src/sim/match';
import { runSelfPlay } from '../src/sim/selfplay';
import { seeded, NET_H } from '../src/config';

function landing(from: { x: number; y: number; z: number }, v: { x: number; y: number; z: number }) {
  const b: BallState = { p: { ...from }, v: { ...v }, netted: false, rolling: false };
  let minNetClear = Infinity;
  for (let k = 0; k < 2000; k++) {
    const ev: any[] = [];
    const pz = b.p.z; stepBall(b, 1 / 240, ev);
    if ((pz > 0) !== (b.p.z > 0)) minNetClear = Math.min(minNetClear, b.p.y - NET_H);
    const bounce = ev.find(e => e.type === 'bounce');
    if (bounce) return { at: bounce.p, netted: b.netted, minNetClear };
  }
  return null;
}

describe('shot solver', () => {
  const rng = seeded(1);
  for (const type of ['dink', 'drop', 'drive', 'speedup', 'lob'] as const) {
    it(`lands a ${type} on target and clears the net`, () => {
      const from = { x: 3, y: 1.8, z: type === 'drop' || type === 'drive' ? 21 : 8 };
      const target = clampAim(type, { x: -4, z: -4 }, 0);
      const v = launchVelocity(from, target, type, { T: 0, exact: true }, rng);
      const r = landing(from, v)!;
      expect(r.netted).toBe(false);
      expect(r.minNetClear).toBeGreaterThan(0);
      expect(Math.hypot(r.at.x - target.x, r.at.z - target.z)).toBeLessThan(0.05);
    });
  }
});

describe('rules', () => {
  it('enforces the two-bounce rule and the kitchen', () => {
    const m = new Match(seeded(2));
    m.ball.lastHitTeam = 1;
    expect(m.contactAllowed({ x: 0, y: 3, z: 10, bounces: 0, netted: false }, 0, 2)).toBe(false); // return must bounce
    expect(m.contactAllowed({ x: 0, y: 3, z: 10, bounces: 0, netted: false }, 0, 5)).toBe(true);  // volley ok later
    expect(m.contactAllowed({ x: 0, y: 3, z: 5, bounces: 0, netted: false }, 0, 5)).toBe(false);  // not from the kitchen
    expect(m.contactAllowed({ x: 0, y: 1, z: 5, bounces: 1, netted: false }, 0, 5)).toBe(true);   // after a bounce is fine
  });
  it('plays complete AI rallies with sensible length', () => {
    const r = runSelfPlay(300, 5, 0.012);
    const avg = r.shots / r.rallies;
    expect(avg).toBeGreaterThan(5);
    expect(avg).toBeLessThan(25);
    expect(r.serverWins / r.rallies).toBeGreaterThan(0.3);
    expect(r.serverWins / r.rallies).toBeLessThan(0.7);
    expect(r.rows.every(x => x.features.length === 21)).toBe(true);
  });
  it('scores a match to 11, win by 2', () => {
    const m = new Match(seeded(3)); m.mode = 'selfplay'; m.score = [10, 9]; m.server = 0; m.mode = 'match';
    m.newRally(); m.point(0, 'test');
    expect(m.gameOver).toBe(true);
  });
});
