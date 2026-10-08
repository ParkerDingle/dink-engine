// Match simulation: rules, scoring, AI movement and shot choice, and the user's slow-motion shot calls.
// No rendering or DOM here, so the same code runs in the browser, in tests and in headless self-play.
import {
  K, L, W, BALL_R, GRAV, NET_H, REACH, REACH_H, SUB, UP_DIST,
  teamOf, sideSign, clamp, lerp, type Rng, type Vec2, type Vec3,
} from '../config';
import {
  evaluate, availability, choose, rallyStart, zoneCenter, label as shotLabel, grade as gradeFor, accuracy,
  ORDER, SHOTS, type EngineState, type ShotOption, type ShotType, type Availability, type Grade,
} from '../engine/rules';
import { DRILLS } from '../engine/drills';
import { featuresFor } from '../engine/features';
import { stepBall, predict, launchVelocity, clampAim, type BallState, type BounceEvent, type Prediction, type Sample, type Fault } from './physics';

export type Mode = 'attract' | 'match' | 'drill' | 'selfplay';
export type Level = 'club' | 'pro';

export interface Player {
  i: number; team: number; x: number; z: number; vx: number; vz: number; rot: number;
  speed: number; react: number; reactLeft: number; depthGoal: number; forced: boolean;
  swingT: number; swingKind: number; prep: number; prepKind: number;
}
export interface Plan { s: Sample; st: Vec2; t: number; need: number; fail?: boolean; evals?: ShotOption[] }
export interface Decision { contactT: number; t0: number; s: Sample; prov: EngineState; avail: Availability; evals: ShotOption[]; type: ShotType | null; modelled: boolean }
export interface UserShot {
  t: number; shotNo: number; evals: ShotOption[]; opt: ShotOption; best: ShotOption; loss: number; g: Grade;
  target: Vec2; auto: boolean; modelled: boolean;
}
export interface Rally {
  serverTeam: number; serverIdx: number; receiverIdx: number; boxSign: number; drill: boolean;
  shots: { t: number; idx: number; type: string; label: string }[];
  userShots: UserShot[]; result: { winner: number; reason: string } | null;
  frames: number[][]; bounceChecked: boolean; softRun: number;
}
export interface LogRow { features: number[]; team: number; rally: number }
export interface MatchEvents {
  hit(idx: number, type: string, power: number): void;
  bounce(e: BounceEvent): void;
  point(winner: number, reason: string): void;
  decision(d: Decision): void;
  decisionEnd(): void;
  userShot(s: UserShot, updated: boolean): void;
  serveWait(): void;
}
/** Async scorer (e.g. the ONNX model). Returns the same options re-scored and sorted. */
export interface Scorer { score(state: EngineState, options: ShotOption[]): Promise<ShotOption[] | null> }

const TAU: Record<Level, number> = { pro: 0.012, club: 0.045 };

export class Match {
  mode: Mode = 'attract';
  level: Level = 'pro';
  assist = true;
  rng: Rng;
  players: Player[];
  ball: BallState & { live: boolean; bounces: number; shotNo: number; lastHitTeam: number; lastHitter: number; lastType: string; lastLabel: string; winP: number };
  rallyTime = 0;
  timeTarget = 1;
  score = [0, 0];
  server = 0;
  rally: Rally | null = null;
  rallyOver = false;
  serveWait = false;
  serveDelay = 0;
  gameOver = false;
  pred: Prediction | null = null;
  plans: (Plan | null)[] = [null, null, null, null];
  decision: Decision | null = null;
  pending: { type?: ShotType; aim?: Vec2; leave?: boolean } | null = null;
  aim: Vec2 = { x: 0, z: -12 };
  input = { x: 0, z: 0 };
  drillIdx = 0;
  rallyCount = 0;
  stats = { grades: {} as Record<string, number>, accSum: 0, accN: 0 };
  on: Partial<MatchEvents> = {};
  scorer: Scorer | null = null;
  selfplayTau = 0.05;
  log: LogRow[] = [];
  labels: { rally: number; winner: number }[] = [];
  /** Optional collision-aware movement (Rapier character controller). */
  moveResolver: ((i: number, dx: number, dz: number) => Vec2) | null = null;

  constructor(rng: Rng = Math.random) {
    this.rng = rng;
    this.players = [0, 1, 2, 3].map(i => ({
      i, team: teamOf(i), x: 0, z: 0, vx: 0, vz: 0, rot: teamOf(i) === 0 ? Math.PI : 0,
      speed: 15, react: 0.15, reactLeft: 0, depthGoal: 22.8, forced: false,
      swingT: -1, swingKind: 1, prep: 0, prepKind: 1,
    }));
    this.ball = { p: { x: 0, y: 2, z: 20 }, v: { x: 0, y: 0, z: 0 }, netted: false, rolling: false, live: false, bounces: 0,
      shotNo: 0, lastHitTeam: -1, lastHitter: -1, lastType: '', lastLabel: '', winP: 0 };
  }

  get user() { return this.players[1]; }
  isAI(i: number) { return i !== 1 || this.mode === 'attract' || this.mode === 'selfplay'; }
  private gauss() { let u = 0, v = 0; while (!u) u = this.rng(); while (!v) v = this.rng(); return Math.sqrt(-2 * Math.log(u)) * Math.cos(2 * Math.PI * v); }
  private rand(a: number, b: number) { return a + this.rng() * (b - a); }

  // ---------------------------------------------------------------- state helpers
  engineState(idx: number, bp: Vec3, bv: Vec3): EngineState {
    const sp = Math.hypot(bv.x, bv.y, bv.z);
    return {
      hitTeam: teamOf(idx), hitter: idx,
      players: this.players.map(p => ({ x: p.x + 10, y: p.z + 22 })),
      ball: { x: bp.x + 10, y: bp.z + 22 },
      height: bp.y < 2.3 ? 0 : bp.y < 4.0 ? 1 : 2, pace: sp < 27 ? 0 : sp < 42 ? 1 : 2,
      shotNo: this.ball.shotNo + 1, contactHeightFt: bp.y, incomingSpeed: sp,
    };
  }
  /** Engine-coordinate target for an option, as a world point. */
  static worldTarget(o: ShotOption): Vec2 { return { x: o.target.x - 10, z: o.target.y - 22 }; }
  static zoneOf(t: Vec2) {
    const c = clamp(Math.floor((t.x + 10) / (20 / 3)), 0, 2), d = Math.abs(t.z);
    return { col: c, depth: d < 7 ? 0 : d < 14.5 ? 1 : 2 };
  }
  static optionFor(evals: ShotOption[], type: ShotType, target: Vec2) {
    const z = Match.zoneOf(target);
    const cands = evals.filter(o => o.type === type && o.col === z.col);
    if (!cands.length) return evals.find(o => o.type === type) || evals[0];
    return cands.reduce((a, b) => (Math.abs(a.depth - z.depth) <= Math.abs(b.depth - z.depth) ? a : b));
  }
  static convertType(type: ShotType, avail: Availability): ShotType {
    const alt: Record<ShotType, ShotType[]> = { dink: ['drop', 'speedup'], drop: ['dink', 'drive'], drive: ['speedup', 'drop'], speedup: ['drive', 'dink'], putaway: ['speedup', 'drive'], lob: ['drop'] };
    for (const t of alt[type]) if (avail[t].ok) return t;
    return ORDER.find(t => avail[t].ok) || 'drop';
  }

  // ---------------------------------------------------------------- contact rules
  contactAllowed(s: { x: number; y: number; z: number; bounces: number; netted: boolean }, T: number, incomingShotNo: number) {
    if (s.netted || this.ball.lastHitTeam === T) return false;
    if (T === 0 ? s.z < 0.4 : s.z > -0.4) return false;
    if (s.bounces === 0) {
      if (incomingShotNo <= 2) return false;        // two-bounce rule
      if (Math.abs(s.z) < K + 0.3) return false;    // no volleys from the kitchen
      return s.y >= 0.6 && s.y <= REACH_H;
    }
    if (s.bounces === 1) return s.y >= 0.2 && s.y <= 6.2;
    return false;
  }
  private ballSample() { const b = this.ball; return { x: b.p.x, y: b.p.y, z: b.p.z, bounces: b.bounces, netted: b.netted }; }

  // ---------------------------------------------------------------- movement goals
  homeFor(pl: Player): Vec2 {
    const T = pl.team, sg = sideSign(T);
    const sideX = (pl.i % 2 === 0 ? -1 : 1) * 4.6;
    let depth = pl.depthGoal;
    const r = this.rally;
    if (r && !r.drill) {
      if (T === r.serverTeam && this.ball.shotNo < 3) depth = 22.8;
      if (T !== r.serverTeam && this.ball.shotNo < 2 && pl.i === r.receiverIdx) depth = 22.8;
    }
    const bx = clamp(this.ball.p.x, -8, 8);
    let x = sideX + bx * 0.3;
    if (this.plans[pl.i ^ 1]) x = sideX * 0.55 + bx * 0.4;
    return { x, z: sg * depth };
  }
  stanceFor(s: Sample, pl: Player): Vec2 {
    const sg = sideSign(pl.team);
    const off = pl.x - s.x >= 0 ? 1.45 : -1.45;
    let z = s.z + sg * 0.5;
    if (s.bounces === 0) z = sg * Math.max(Math.abs(s.z) + 0.5, 7.6);
    return { x: clamp(s.x + off, -15.5, 15.5), z };
  }
  planFor(idx: number, P: Prediction, now: number): Plan | null {
    const pl = this.players[idx], T = pl.team, up = Math.abs(pl.z) < 10.5;
    let best: Plan | null = null, bs = Infinity, near: Plan | null = null, nd = Infinity;
    for (const s of P.samples) {
      if (s.t < now) continue;
      if (!this.contactAllowed(s, T, this.ball.shotNo)) continue;
      const st = this.stanceFor(s, pl);
      const dist = Math.hypot(st.x - pl.x, st.z - pl.z);
      if (dist < nd) { nd = dist; near = { s, st, t: s.t, need: dist / pl.speed }; }
      const need = Math.max(0, dist - 0.8) / pl.speed;
      if (need > s.t - now - pl.react) continue;
      let sc = s.bounces === 0 ? (up ? 0 : 1.1) : 0.5 + Math.abs(s.y - 2.3) * 0.35;
      if (s.bounces === 0 && s.y > 5.4) sc -= 0.5;
      sc += need * 0.4 + (s.t - now) * 0.05;
      if (sc < bs) { bs = sc; best = { s, st, t: s.t, need }; }
    }
    if (best) return best;
    if (near) return { ...near, fail: true };
    return null;
  }
  assignTeam(T: number, forceUser = false) {
    const idxs = T === 0 ? [0, 1] : [2, 3];
    for (const i of idxs) this.plans[i] = null;
    if (!this.pred) return;
    const fb = this.pred.firstBounce;
    const willBeOut = !!fb && fb.side === T && (Math.abs(fb.x) > W + 0.35 || Math.abs(fb.z) > L + 0.35);
    const cand = idxs.map(i => ({ i, plan: this.planFor(i, this.pred!, this.rallyTime) })).filter(c => c.plan) as { i: number; plan: Plan }[];
    if (!cand.length) return;
    let pick: { i: number; plan: Plan };
    if (forceUser) pick = cand.find(c => c.i === 1) || cand[0];
    else {
      const ok = cand.filter(c => !c.plan.fail);
      pick = (ok.length ? ok : cand).reduce((a, b) => (a.plan.need <= b.plan.need ? a : b));
    }
    if (willBeOut && this.isAI(pick.i)) {
      const playIt = T === 1 && this.level === 'club' && this.rng() < 0.3;
      if (!playIt) return;
    }
    const pl = this.players[pick.i];
    pl.forced = false;
    if (this.isAI(pick.i) && this.ball.winP > 0 && this.rng() < this.ball.winP) {
      if (this.rng() < 0.5) return;   // can't get there in time
      pl.forced = true;               // gets a paddle on it but can't control it
    }
    this.plans[pick.i] = pick.plan;
    // Pre-score the AI's choice with the trained model while the ball is in the air.
    if (this.scorer && this.isAI(pick.i) && this.mode !== 'selfplay') {
      const s = pick.plan.s, plan = pick.plan;
      const st = this.engineState(pick.i, { x: s.x, y: s.y, z: s.z }, { x: s.vx, y: s.vy, z: s.vz });
      this.scorer.score(st, evaluate(st)).then(ev => { if (ev && this.plans[pick.i] === plan) plan.evals = ev; }).catch(() => {});
    }
  }

  // ---------------------------------------------------------------- hitting
  private kindFor(pl: Player, bp: { x: number; y: number }, type: string | null) {
    if (bp.y > 5.0) return 3;
    const right = pl.team === 0 ? 1 : -1;
    const fore = (bp.x - pl.x) * right > -0.3;
    if ((type === 'dink' || type === 'drop') && bp.y < 2.8) return fore ? 4 : 5;
    return fore ? 1 : 2;
  }
  private doHit(idx: number, type: ShotType | 'serve', target: Vec2, o: {
    mult?: number; q?: number; label?: string; serveSpeed?: number; pErr?: number; pWin?: number; errScale?: number; forced?: boolean; exact?: boolean; features?: number[];
  }) {
    const pl = this.players[idx], T = pl.team, b = this.ball;
    pl.swingT = 0; pl.prep = 0;
    pl.swingKind = type === 'serve' ? 4 : this.kindFor(pl, b.p, type);
    if (type !== 'serve') {
      const volley = b.bounces === 0;
      if (volley && Math.abs(pl.z) < K) return this.point(1 - T, 'Fault: volley from the kitchen');
      if (volley && b.shotNo <= 2) return this.point(1 - T, 'Fault: two-bounce rule');
    }
    const from = { ...b.p };
    const inSpeed = Math.hypot(b.v.x, b.v.y, b.v.z);
    const isReturn = b.shotNo + 1 === 2;
    let fault: Fault = null, winP = 0;
    if (o.pErr != null && !o.exact) {
      const run = this.rally ? this.rally.softRun : 0;
      const errP = clamp(o.pErr * (o.errScale ?? 1) * (1 + 0.09 * run), 0, 0.75);
      if (this.rng() < errP) {
        const soft = type === 'dink' || type === 'drop' || type === 'lob';
        const r2 = this.rng();
        fault = soft ? (r2 < 0.6 ? 'net' : type === 'lob' ? 'long' : 'popup') : (r2 < 0.5 ? 'net' : (r2 < 0.75 && Math.abs(target.x) > 3.4) ? 'wide' : 'long');
      }
      if (o.forced) fault = this.rng() < 0.6 ? 'net' : 'long';
      const defend = T === 0 ? (this.level === 'pro' ? 0.9 : 1.35) : 1.0;
      if (!fault) winP = clamp((o.pWin ?? 0) * defend, 0, 0.9);
    }
    b.v = launchVelocity(from, target, type, { T, mult: o.mult, q: o.q, inSpeed, isReturn, serveSpeed: o.serveSpeed, fault, exact: o.exact }, this.rng);
    b.winP = winP;
    if (this.rally) { this.rally.softRun = type === 'dink' ? this.rally.softRun + 1 : 0; this.rally.bounceChecked = false; }
    b.live = true; b.rolling = false; b.netted = false; b.bounces = 0;
    b.lastHitTeam = T; b.lastHitter = idx; b.shotNo += 1; b.lastType = type;
    b.lastLabel = o.label || (type === 'serve' ? 'Serve' : SHOTS[type].name);
    if (o.features && this.mode === 'selfplay') this.log.push({ features: o.features, team: T, rally: this.rallyCount });
    this.on.hit?.(idx, type, type === 'drive' || type === 'speedup' || type === 'putaway' ? 1.2 : 0.75);
    for (const i of T === 0 ? [0, 1] : [2, 3]) {
      if (type === 'serve') continue;
      const p = this.players[i];
      if (b.shotNo === 2) { if (i === idx) p.depthGoal = 7.9; continue; }
      p.depthGoal = type === 'dink' || type === 'drop' || type === 'lob' ? 7.9 : Math.max(7.9, Math.abs(p.z) - 6.5);
    }
    this.plans = [null, null, null, null];
    this.pred = predict(b, 0, this.rallyTime);
    this.assignTeam(1 - T);
    for (const i of T === 0 ? [2, 3] : [0, 1]) this.players[i].reactLeft = this.players[i].react;
    this.rally?.shots.push({ t: this.rallyTime, idx, type, label: b.lastLabel });
  }
  private aiHit(idx: number) {
    const pl = this.players[idx];
    const st = this.engineState(idx, this.ball.p, this.ball.v);
    const ruleEvals = evaluate(st);
    const plan = this.plans[idx];
    // trained-model scores (if they arrived in time) drive the choice; rule odds drive execution
    let evals = ruleEvals;
    if (plan?.evals && plan.evals.length) {
      const byKey = new Map(plan.evals.map(o => [o.type + o.col + o.depth, o.P]));
      evals = ruleEvals.map(o => ({ ...o, P: byKey.get(o.type + o.col + o.depth) ?? o.P })).sort((a, b) => b.P - a.P);
    }
    const tau = this.mode === 'selfplay' ? this.selfplayTau : pl.team === 1 ? TAU[this.level] : TAU.pro;
    const opt = choose(evals, tau, this.rng);
    const zc = zoneCenter(1 - pl.team, opt.col, opt.depth);
    const tgt = clampAim(opt.type, { x: zc.x - 10 + this.rand(-1.6, 1.6), z: zc.y - 22 + this.rand(-1.1, 1.1) }, pl.team);
    const mult = pl.team === 1 ? (this.level === 'pro' ? 0.8 : 1.3) : 0.85;
    const errScale = pl.team === 1 ? (this.level === 'pro' ? 0.85 : 1.35) : 0.95;
    const forced = pl.forced; pl.forced = false;
    const features = featuresFor(st, opt.type, { x: tgt.x + 10, y: tgt.z + 22 });
    this.doHit(idx, opt.type, tgt, { mult, q: 0.92, label: opt.label, pErr: opt.pErr, pWin: opt.pWin, errScale, forced, features });
  }
  serve(idx: number, target: Vec2) {
    const pl = this.players[idx], b = this.ball;
    b.p = { x: pl.x + (pl.team === 0 ? 0.9 : -0.9), y: 1.7, z: pl.z };
    b.v = { x: 0, y: 0, z: 0 }; b.shotNo = 0; b.bounces = 0; b.lastHitTeam = -1;
    const sp = pl.team === 1 ? (this.level === 'pro' ? 44 : 38) : (idx === 1 && !this.isAI(1) ? 41 : 42);
    const mult = pl.team === 1 ? (this.level === 'pro' ? 0.8 : 1.25) : 0.9;
    this.doHit(idx, 'serve', target, { mult, q: 1, label: 'Serve', serveSpeed: sp });
  }
  userServe() {
    if (!this.serveWait || !this.rally) return;
    this.serveWait = false;
    this.serve(1, clampAim('serve', this.aim, 0, this.rally.boxSign));
  }
  private aiServeTarget(idx: number): Vec2 {
    const s = -sideSign(teamOf(idx));
    return { x: this.rally!.boxSign * this.rand(2.2, 6.8), z: s * this.rand(15, 19.8) };
  }

  // ---------------------------------------------------------------- rules
  private onBounce(e: BounceEvent) {
    this.on.bounce?.(e);
    if (this.rallyOver) return;
    const b = this.ball, T = b.lastHitTeam, r = this.rally!;
    if (T < 0) return;
    if (e.side === T) return this.point(1 - T, b.netted ? `${b.lastLabel} into the net` : `${b.lastLabel} fault`);
    b.bounces += e.roll ? 2 : 1;
    if (b.bounces === 1 || (e.roll && b.bounces === 2 && !r.bounceChecked)) {
      r.bounceChecked = true;
      const outX = Math.abs(e.p.x) > W + BALL_R, outZ = Math.abs(e.p.z) > L + BALL_R;
      if (outX || outZ) return this.point(1 - T, `${b.lastLabel} ${outZ ? 'long' : 'wide'}`);
      if (b.shotNo === 1) {
        if (Math.abs(e.p.z) <= K + BALL_R) return this.point(1 - T, 'Serve landed in the kitchen');
        if (Math.sign(e.p.x) !== r.boxSign && Math.abs(e.p.x) > BALL_R) return this.point(1 - T, 'Serve in the wrong box');
      }
    }
    if (b.bounces >= 2) return this.point(T, b.shotNo === 1 ? 'Ace' : `${b.lastLabel} winner`);
  }
  point(winner: number, reason: string) {
    if (this.rallyOver || !this.rally) return;
    this.rallyOver = true;
    this.endDecision();
    this.pending = null; this.timeTarget = 1;
    this.plans = [null, null, null, null];
    this.rally.result = { winner, reason };
    this.labels.push({ rally: this.rallyCount, winner });
    if (this.mode === 'match') {
      this.score[winner]++; this.server = winner;
      if ((this.score[0] >= 11 || this.score[1] >= 11) && Math.abs(this.score[0] - this.score[1]) >= 2) this.gameOver = true;
    }
    this.on.point?.(winner, reason);
  }

  // ---------------------------------------------------------------- rally setup
  private resetRally() {
    this.rallyOver = false; this.rallyTime = 0; this.plans = [null, null, null, null]; this.pred = null;
    this.endDecision(); this.pending = null; this.timeTarget = 1; this.serveWait = false;
    for (const p of this.players) {
      p.vx = p.vz = 0; p.swingT = -1; p.prep = 0; p.reactLeft = 0; p.forced = false;
      p.speed = p.team === 1 ? (this.level === 'pro' ? 15 : 12.5) : 15;
      p.react = p.team === 1 ? (this.level === 'pro' ? 0.14 : 0.3) : 0.15;
    }
    const b = this.ball; b.netted = false; b.rolling = false; b.bounces = 0; b.winP = 0;
    this.rallyCount++;
  }
  newRally() {
    this.resetRally();
    const st = rallyStart(this.server, this.score[this.server]);
    st.players.forEach((p, i) => { const pl = this.players[i]; pl.x = p.x - 10; pl.z = p.y - 22; pl.depthGoal = Math.abs(pl.z) < 12 ? 7.9 : 22.8; });
    this.rally = { serverTeam: this.server, serverIdx: st.server, receiverIdx: st.receiver, boxSign: Math.sign(this.players[st.receiver].x) || 1,
      drill: false, shots: [], userShots: [], result: null, frames: [], bounceChecked: false, softRun: 0 };
    const b = this.ball; b.live = false; b.shotNo = 0; b.lastHitTeam = -1;
    b.p = this.heldBallPos();
    if (st.server === 1 && !this.isAI(1)) { this.serveWait = true; this.on.serveWait?.(); }
    else this.serveDelay = this.mode === 'selfplay' ? 0.05 : this.mode === 'attract' ? 0.9 : 1.1;
  }
  startMatch() { this.mode = 'match'; this.score = [0, 0]; this.server = 0; this.gameOver = false; this.stats = { grades: {}, accSum: 0, accN: 0 }; this.newRally(); }
  heldBallPos(): Vec3 {
    const pl = this.players[this.rally ? this.rally.serverIdx : 1];
    return { x: pl.x + (pl.team === 0 ? 0.9 : -0.9), y: 2.2, z: pl.z };
  }
  startDrill(i: number) {
    this.mode = 'drill';
    this.drillIdx = (i + DRILLS.length) % DRILLS.length;
    const dr = DRILLS[this.drillIdx];
    this.resetRally(); this.gameOver = false;
    dr.players.forEach(([x, y], k) => { const pl = this.players[k]; pl.x = x - 10; pl.z = y - 22; pl.depthGoal = Math.abs(pl.z) < 10 ? 7.9 : Math.abs(pl.z); });
    this.rally = { serverTeam: dr.shotNo === 2 ? 1 : 0, serverIdx: -1, receiverIdx: -1, boxSign: 1, drill: true,
      shots: [], userShots: [], result: null, frames: [], bounceChecked: false, softRun: 0 };
    const u = this.user;
    const from = { x: dr.from[0] - 10, y: 2.6, z: dr.from[1] - 22 };
    const C = { x: u.x + (u.x >= 0 ? -1.5 : 1.5), z: u.z - 0.4 };
    const needBounce = dr.shotNo <= 3 || dr.height === 0;
    let v: Vec3;
    if (!needBounce) {
      const hY = [1.5, 3.1, 5.3][dr.height];
      let t = [1.05, 0.72, 0.42][dr.pace];
      v = { x: 0, y: 0, z: 0 };
      for (let k = 0; k < 30; k++) {
        v = { x: (C.x - from.x) / t, z: (C.z - from.z) / t, y: (hY - from.y + 0.5 * GRAV * t * t) / t };
        const tc = -from.z / v.z, yc = from.y + v.y * tc - 0.5 * GRAV * tc * tc;
        if (yc > NET_H + 0.3) break;
        t *= 1.07;
      }
    } else {
      const d = dr.pace === 0 ? 2.2 : 5.5;
      const B = { x: C.x + (from.x - C.x) * 0.08, z: Math.max(1.0, C.z - d) };
      v = launchVelocity(from, B, dr.pace === 0 ? 'dink' : 'drive', { T: 1, exact: true, clearMul: 1.2, speedMul: dr.pace === 2 ? 0.95 : 0.72 }, this.rng);
    }
    const b = this.ball;
    b.p = from; b.v = v; b.live = true; b.lastHitTeam = 1; b.shotNo = dr.shotNo - 1; b.lastLabel = 'Feed'; b.lastType = 'feed';
    b.lastHitter = Math.abs(this.players[2].x - from.x) < Math.abs(this.players[3].x - from.x) ? 2 : 3;
    this.pred = predict(b, 0, 0);
    this.assignTeam(0, true);
  }

  // ---------------------------------------------------------------- user shot calls
  private startDecision(s: Sample) {
    const prov = this.engineState(1, { x: s.x, y: s.y, z: s.z }, { x: s.vx, y: s.vy, z: s.vz });
    const d: Decision = { contactT: s.t, t0: this.rallyTime, s, prov, avail: availability(prov), evals: evaluate(prov), type: null, modelled: false };
    this.decision = d;
    this.timeTarget = 0.085;
    this.on.decision?.(d);
    if (this.scorer) this.scorer.score(prov, d.evals).then(ev => {
      if (ev && this.decision === d) { d.evals = ev; d.modelled = true; this.on.decision?.(d); }
    }).catch(() => {});
  }
  private endDecision() { if (this.decision) { this.decision = null; this.on.decisionEnd?.(); } }
  selectShot(t: ShotType) {
    const d = this.decision;
    if (!d || !d.avail[t].ok) return false;
    d.type = t; return true;
  }
  commit(): boolean {
    const d = this.decision;
    if (!d || !d.type) return false;
    this.pending = { type: d.type, aim: { ...this.aim } };
    this.endDecision(); this.timeTarget = 1;
    return true;
  }
  leaveIt() { if (!this.decision) return; this.pending = { leave: true }; this.endDecision(); this.timeTarget = 1; }
  private positionQuality(pl: Player, bp: Vec3) {
    const d = Math.hypot(bp.x - pl.x, bp.z - pl.z);
    let q = 1 - clamp(Math.abs(d - 1.6) / 1.6, 0, 1) * 0.75;
    if (Math.hypot(pl.vx, pl.vz) > 9) q *= 0.85;
    return clamp(q, 0.25, 1);
  }
  private userHit(auto: boolean) {
    const bp = { ...this.ball.p }, bv = { ...this.ball.v };
    const st = this.engineState(1, bp, bv);
    const evals = evaluate(st), avail = availability(st);
    let type: ShotType = auto ? (avail.drop.ok ? 'drop' : avail.dink.ok ? 'dink' : Match.convertType('drop', avail)) : this.pending!.type!;
    if (!avail[type].ok) type = Match.convertType(type, avail);
    const target = clampAim(type, auto ? { x: 0, z: -3.5 } : this.pending!.aim!, 0);
    const opt = Match.optionFor(evals, type, target), best = evals[0];
    const loss = (best.P - opt.P) * 100, g = gradeFor(loss);
    const q = this.positionQuality(this.user, bp);
    const rec: UserShot = { t: this.rallyTime, shotNo: this.ball.shotNo + 1, evals, opt, best, loss, g, target: { ...target }, auto, modelled: false };
    this.rally!.userShots.push(rec);
    const statKey = () => { if (this.mode === 'match') { this.stats.grades[rec.g.key] = (this.stats.grades[rec.g.key] || 0) + 1; this.stats.accSum += accuracy(rec.loss); this.stats.accN++; } };
    this.pending = null; this.endDecision(); this.timeTarget = 1;
    const features = featuresFor(st, type, { x: target.x + 10, y: target.z + 22 });
    if (this.scorer) {
      // grade with the trained model; fall back to the rule engine if it doesn't answer quickly
      let done = false;
      const fallback = setTimeout(() => { if (!done) { done = true; statKey(); this.on.userShot?.(rec, false); } }, 250);
      this.scorer.score(st, evals).then(ev => {
        if (!ev) return;
        const mo = Match.optionFor(ev, type, target), mb = ev[0];
        Object.assign(rec, { evals: ev, opt: mo, best: mb, loss: (mb.P - mo.P) * 100, g: gradeFor((mb.P - mo.P) * 100), modelled: true });
        if (!done) { done = true; clearTimeout(fallback); statKey(); this.on.userShot?.(rec, false); }
        else this.on.userShot?.(rec, true);
      }).catch(() => {});
    } else { statKey(); this.on.userShot?.(rec, false); }
    this.doHit(1, type, target, { mult: auto ? 1.8 : 1.0, q, label: opt.label, pErr: opt.pErr, pWin: opt.pWin, errScale: 1 + 1.2 * (1 - q) + (auto ? 0.8 : 0), features });
  }

  // ---------------------------------------------------------------- update loop
  private accelTo(pl: Player, tvx: number, tvz: number, dt: number) {
    const dvx = tvx - pl.vx, dvz = tvz - pl.vz, dv = Math.hypot(dvx, dvz), a = 60 * dt;
    const k = dv > a ? a / dv : 1; pl.vx += dvx * k; pl.vz += dvz * k;
  }
  private moveToward(pl: Player, tgt: Vec2, dt: number, vmax: number) {
    const dx = tgt.x - pl.x, dz = tgt.z - pl.z, d = Math.hypot(dx, dz);
    const want = d > 0.05 ? Math.min(vmax, d * 4.5) : 0;
    this.accelTo(pl, d > 0.05 ? (dx / d) * want : 0, d > 0.05 ? (dz / d) * want : 0, dt);
  }
  private updatePlayers(dt: number) {
    const b = this.ball;
    for (const pl of this.players) {
      if (pl.reactLeft > 0) pl.reactLeft -= dt;
      const plan = this.plans[pl.i];
      const hold = this.serveWait || (!b.live && !!this.rally && !this.rally.drill && !this.rallyOver);
      if (!this.isAI(pl.i)) {
        const { x: ix, z: iz } = this.input;
        if (!hold && (ix || iz)) { const n = Math.hypot(ix, iz); this.accelTo(pl, (ix / n) * 14.5, (iz / n) * 14.5, dt); }
        else if (this.assist && !hold && !this.rallyOver) {
          if (pl.reactLeft > 0) this.accelTo(pl, 0, 0, dt);
          else this.moveToward(pl, plan && !this.pending?.leave ? plan.st : this.homeFor(pl), dt, 13.2);
        } else this.accelTo(pl, 0, 0, dt);
      } else if (hold || pl.reactLeft > 0) this.accelTo(pl, 0, 0, dt);
      else this.moveToward(pl, plan && !this.rallyOver ? plan.st : this.homeFor(pl), dt, pl.speed);
      let dx = pl.vx * dt, dz = pl.vz * dt;
      if (this.moveResolver) { const m = this.moveResolver(pl.i, dx, dz); dx = m.x; dz = m.z; }
      pl.x = clamp(pl.x + dx, -15.4, 15.4);
      pl.z = pl.team === 0 ? clamp(pl.z + dz, 0.7, 31) : clamp(pl.z + dz, -31, -0.7);
      if (pl.swingT >= 0) { pl.swingT += dt / 0.24; if (pl.swingT >= 1) pl.swingT = -1; }
      let wantPrep = 0;
      if (plan && !this.rallyOver && plan.t - this.rallyTime < 0.34 && (this.isAI(pl.i) || this.pending)) { wantPrep = 1; pl.prepKind = this.kindFor(pl, plan.s, null); }
      if (pl.i === 1 && this.decision) { wantPrep = 0.5; pl.prepKind = this.kindFor(pl, this.decision.s, this.decision.type); }
      pl.prep = lerp(pl.prep, wantPrep, Math.min(1, dt * 14));
      pl.rot = (pl.team === 0 ? Math.PI : 0) + clamp(-pl.vx * 0.02 * sideSign(pl.team), -0.3, 0.3);
    }
  }
  private tryHits() {
    const b = this.ball;
    if (!b.live || this.rallyOver) return;
    const bs = this.ballSample();
    for (let i = 0; i < 4; i++) {
      const pl = this.players[i];
      if (pl.team === b.lastHitTeam) continue;
      if (!this.contactAllowed(bs, pl.team, b.shotNo)) continue;
      if (Math.hypot(b.p.x - pl.x, b.p.z - pl.z) > REACH) continue;
      if (this.isAI(i)) {
        const plan = this.plans[i];
        if (!plan || this.rallyTime < plan.t - 0.03) continue;
        this.aiHit(i); return;
      }
      if (this.pending && !this.pending.leave) { this.userHit(false); return; }
      if (this.decision && this.rallyTime >= this.decision.contactT + 0.05) { this.userHit(true); return; }
    }
  }
  private checkDecision() {
    if (this.isAI(1) || this.decision || this.pending || this.rallyOver || this.ball.lastHitTeam !== 1 || !this.plans[1] || !this.pred) return;
    for (const s of this.pred.samples) {
      if (s.t < this.rallyTime) continue;
      if (s.t > this.rallyTime + 0.5) break;
      if (!this.contactAllowed(s, 0, this.ball.shotNo)) continue;
      if (Math.hypot(s.x - this.user.x, s.z - this.user.z) <= REACH + 1.0) { this.startDecision(s); return; }
    }
  }
  /** Advance the simulation by dt seconds of game time. */
  update(dt: number) {
    const r = this.rally;
    if (!r) return;
    if (this.serveWait) { this.updatePlayers(dt); this.ball.p = this.heldBallPos(); return; }
    if (!this.ball.live && !this.rallyOver && !r.drill) {
      this.serveDelay -= dt; this.ball.p = this.heldBallPos();
      if (this.serveDelay <= 0) this.serve(r.serverIdx, this.aiServeTarget(r.serverIdx));
    }
    const n = Math.max(1, Math.ceil(dt / SUB)), h = dt / n;
    for (let k = 0; k < n; k++) {
      this.rallyTime += h;
      if (this.ball.live) {
        const ev: any[] = [];
        stepBall(this.ball, h, ev);
        for (const e of ev) if (e.type === 'bounce') this.onBounce(e);
        this.tryHits();
      }
      this.updatePlayers(h);
    }
    if (!this.rallyOver) this.checkDecision();
    const lastShot = r.shots.length ? r.shots[r.shots.length - 1].t : 0;
    if (this.ball.live && !this.rallyOver && this.rallyTime - lastShot > 6) this.point(1 - Math.max(0, this.ball.lastHitTeam), 'Rally reset');
  }

  // ---------------------------------------------------------------- replay recording
  record() {
    const r = this.rally; if (!r || this.mode === 'attract' || this.mode === 'selfplay') return;
    const b = this.ball;
    const f = [this.rallyTime, b.p.x, b.p.y, b.p.z, b.live ? 1 : 0];
    for (const p of this.players) f.push(p.x, p.z, p.rot, Math.hypot(p.vx, p.vz), p.swingT, p.swingKind, p.prep, p.prepKind);
    r.frames.push(f);
  }
  static FRAME_STRIDE = 8;

  label(type: ShotType, s: EngineState) { return shotLabel(type, s); }
}
