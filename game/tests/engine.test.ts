import { describe, expect, it } from 'vitest';
import { evaluate, availability, grade } from '../src/engine/rules';
import { DRILLS } from '../src/engine/drills';
import { FEATURE_NAMES, N_FEATURES } from '../src/engine/features';
import { buildFixture } from './fixture';
import fixture from '../../ml/tests/fixtures/feature_parity.json';

const state = (key: string) => {
  const d = DRILLS.find(x => x.key === key)!;
  return { hitTeam: 0, hitter: d.hitter, players: d.players.map(([x, y]) => ({ x, y })), ball: { x: d.ball[0], y: d.ball[1] }, height: d.height, pace: d.pace, shotNo: d.shotNo };
};

describe('rule engine', () => {
  it('puts away a pop-up', () => expect(evaluate(state('popup'))[0].type).toBe('putaway'));
  it('dinks a low ball at the line', () => expect(evaluate(state('dink-low'))[0].type).toBe('dink'));
  it('returns serve deep', () => { const b = evaluate(state('return'))[0]; expect(b.type).toBe('drive'); expect(b.depth).toBe(2); });
  it('only allows return shots on the return', () => {
    const a = availability(state('return'));
    expect(a.dink.ok || a.speedup.ok || a.putaway.ok).toBe(false);
  });
  it('grades by points given up', () => {
    expect(grade(0).key).toBe('best'); expect(grade(3).key).toBe('good'); expect(grade(20).key).toBe('blunder');
  });
});

describe('model feature contract', () => {
  it('has a fixed width', () => expect(FEATURE_NAMES.length).toBe(N_FEATURES));
  it('matches the fixture the Python pipeline tests against', () => {
    expect(buildFixture()).toEqual(fixture);
  });
});
