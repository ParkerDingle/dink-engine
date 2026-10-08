import { seeded } from '../src/config';
import { evaluate, type EngineState } from '../src/engine/rules';
import { featuresFor, FEATURE_VERSION } from '../src/engine/features';

export function buildFixture() {
  const rng = seeded(42);
  const cases = [] as { state: EngineState; type: string; target: { x: number; y: number }; features: number[] }[];
  for (let k = 0; k < 40; k++) {
    const hitTeam = k % 2, hitter = hitTeam * 2 + (k >> 1) % 2;
    const side = (t: number, d: number) => (t === 0 ? 22 + d : 22 - d);
    const players = [0, 1, 2, 3].map(i => ({ x: +(rng() * 20).toFixed(2), y: +side(i < 2 ? 0 : 1, 1 + rng() * 22).toFixed(2) }));
    const state: EngineState = {
      hitTeam, hitter, players, ball: { ...players[hitter] }, height: k % 3, pace: (k >> 2) % 3, shotNo: 2 + (k % 9),
      ...(k % 4 === 0 ? {} : { contactHeightFt: +(0.5 + rng() * 6).toFixed(2), incomingSpeed: +(10 + rng() * 45).toFixed(1) }),
    };
    const opt = evaluate(state)[k % 3] ?? evaluate(state)[0];
    cases.push({ state, type: opt.type, target: opt.target, features: featuresFor(state, opt.type, opt.target) });
  }
  return { feature_version: FEATURE_VERSION, cases };
}
