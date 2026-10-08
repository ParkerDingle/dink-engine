// Glue: renderer, input, camera, HUD, replays, and the main loop around the Match simulation.
import * as THREE from 'three';
import { Match, type Decision, type UserShot } from './sim/match';
import { buildWorld } from './render/world';
import { loadCharacters, type Character } from './render/characters';
import { Markers } from './render/markers';
import { createComposer } from './render/effects';
import { Sfx } from './render/audio';
import { PhysicsWorld } from './physics/rapier';
import { loadModel, type ModelCard } from './engine/model';
import { DRILLS } from './engine/drills';
import { ORDER, GRADES, label as shotLabel, zoneCenter, type ShotType, type Grade } from './engine/rules';
import { clampAim } from './sim/physics';
import { clamp, lerp, K, L, W, type Vec2 } from './config';

const $ = (id: string) => document.getElementById(id) as HTMLElement;
const esc = (s: unknown) => String(s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]!));
const pct = (p: number) => Math.round(p * 100) + '%';
const SHOT_SUB: Record<string, string> = {
  dink: 'Soft into the kitchen', drop: 'Soft arc from back', reset: 'Absorb pace, land short', drive: 'Hard and low',
  speedup: 'Hard at the body', counter: 'Fire it back', lob: 'Over their heads', putaway: 'Hit down to finish',
};

export async function startApp() {
  const base = new URL(import.meta.env.BASE_URL, location.href).href;
  const setLoad = (frac: number, msg: string) => { ($('loadBar') as HTMLElement).style.width = Math.round(frac * 100) + '%'; $('loadMsg').textContent = msg; };

  // ------------------------------------------------------------------ settings
  const SKEY = 'dink-engine-settings';
  const S = { level: 'pro' as 'pro' | 'club', evalMap: true, assist: true, sound: true };
  try { Object.assign(S, JSON.parse(localStorage.getItem(SKEY) || '{}')); } catch { /* storage unavailable */ }
  const saveSettings = () => { try { localStorage.setItem(SKEY, JSON.stringify(S)); } catch { /* storage unavailable */ } };

  // ------------------------------------------------------------------ renderer + scene
  const game = $('game'), canvas = $('c') as HTMLCanvasElement;
  let renderer: THREE.WebGLRenderer;
  try { renderer = new THREE.WebGLRenderer({ canvas, antialias: false, powerPreference: 'high-performance', stencil: false }); }
  catch { $('nogl').hidden = false; $('loading').classList.add('done'); return; }
  renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));
  renderer.shadowMap.enabled = true;
  renderer.shadowMap.type = THREE.PCFShadowMap;
  const scene = new THREE.Scene();
  const camera = new THREE.PerspectiveCamera(44, 1, 0.5, 6000);
  camera.position.set(0, 15.5, 41.5);
  setLoad(0.1, 'Building the court');
  buildWorld(scene, renderer);
  const composer = createComposer(renderer, scene, camera);
  const markers = new Markers(scene);
  const sfx = new Sfx();

  setLoad(0.3, 'Loading players');
  const physicsP = PhysicsWorld.create();
  let chars: Character[];
  try { chars = await loadCharacters(new URL('assets/player.glb', base).href, scene); }
  catch (e) { console.error(e); $('loadMsg').textContent = 'Could not load the player model.'; return; }
  setLoad(0.7, 'Starting physics');
  const physics = await physicsP;
  setLoad(0.9, 'Warming up');

  // ------------------------------------------------------------------ match
  const match = new Match();
  match.level = S.level; match.assist = S.assist;
  let modelCard: ModelCard | null = null;
  loadModel(base).then(m => { if (m) { match.scorer = m.scorer; modelCard = m.card; refreshModelTag(); } });

  let afterPoint = 0, paused = false, replay: null | { t: number; fi: number; ev: number; paused: boolean } = null;
  let lastRallyCount = -1, resolved: Vec2[] = match.players.map(p => ({ x: p.x, z: p.z }));
  let bannerT = 0, toastT = 0;

  match.on.hit = (_i, type, power) => sfx.pock(power, type === 'putaway' ? 0.9 : 1);
  match.on.bounce = e => { if (!e.roll) sfx.pock(0.35, 0.55); };
  match.on.point = (winner, reason) => {
    afterPoint = match.mode === 'attract' ? 1.8 : 1.05;
    if (match.mode !== 'attract') banner(winner === 0 ? 'Point · your team' : 'Point · opponents', reason, winner === 0 ? 'win' : 'lose', 2.6);
    physics?.releaseBall(match.ball.p, match.ball.v);
    updateBug();
  };
  match.on.decision = d => showDecision(d);
  match.on.decisionEnd = () => hideDecision();
  match.on.userShot = (s, updated) => {
    if (updated) return;
    toast(s.g, s.auto ? 'Too late: auto block' : s.g.name,
      `${s.opt.label} to the ${s.opt.zone} · ${pct(s.opt.P)}${s.loss > 1.5 ? ` · best ${s.best.label.toLowerCase()} ${pct(s.best.P)}` : ''}${s.modelled ? '' : ' · rule engine'}`);
  };
  match.on.serveWait = () => banner('Your serve', 'Aim into the diagonal box with the mouse · click or Space to serve', '', 0);

  // ------------------------------------------------------------------ HUD helpers
  function banner(big: string, sub: string, cls: string, secs: number) {
    $('bnBig').textContent = big; $('bnSub').textContent = sub || '';
    $('banner').className = 'hud show ' + (cls || ''); bannerT = secs || 0;
  }
  const hideBanner = () => { $('banner').className = 'hud'; bannerT = 0; };
  function toast(g: Grade, title: string, sub: string) {
    const G = $('tsG'); G.className = 'glyph g-' + g.key; G.textContent = g.glyph;
    $('tsT').textContent = title; $('tsS').textContent = sub;
    $('toast').className = 'hud show'; toastT = 2.8;
  }
  const badge = (g: Grade) => `<span class="badge g-${g.key}">${esc(g.glyph)}</span>`;
  function updateBug() {
    const demo = match.mode === 'attract', drill = match.mode === 'drill';
    $('ptA').textContent = demo || drill ? '–' : String(match.score[0]);
    $('ptB').textContent = demo || drill ? '–' : String(match.score[1]);
    $('svA').classList.toggle('on', !demo && !drill && match.server === 0);
    $('svB').classList.toggle('on', !demo && !drill && match.server === 1);
    $('bugMeta').textContent = demo ? 'Demo rally · AI vs AI' : drill ? `Drill ${match.drillIdx + 1} of ${DRILLS.length}` : `Rally scoring · to 11 · ${S.level === 'pro' ? 'Pro' : 'Club'} opponents`;
    $('tEval').setAttribute('aria-pressed', String(S.evalMap));
    $('tAssist').setAttribute('aria-pressed', String(S.assist));
    $('tSound').setAttribute('aria-pressed', String(S.sound));
    $('tPause').hidden = demo;
    $('drillCard').hidden = !drill;
  }
  function modelTagHTML() {
    return modelCard
      ? `<span class="modelTag on" id="modelTag"><i></i>Trained model · ${modelCard.rows.toLocaleString()} shots · AUC ${modelCard.auc.toFixed(2)}</span>`
      : `<span class="modelTag" id="modelTag"><i></i>Rule engine${physics ? '' : ' · basic physics'}</span>`;
  }
  function refreshModelTag() { const t = document.getElementById('modelTag'); if (t) t.outerHTML = modelTagHTML(); }

  // ------------------------------------------------------------------ decision UI
  const shotBtns: Record<string, HTMLButtonElement> = {};
  ORDER.forEach((t, k) => {
    const b = document.createElement('button'); b.className = 'ds'; b.type = 'button'; b.id = 'ds-' + t;
    b.addEventListener('click', e => { e.stopPropagation(); selectShot(t); });
    $('dShots').appendChild(b); shotBtns[t] = b; b.dataset.key = String(k + 1);
  });
  {
    const b = document.createElement('button'); b.className = 'ds leave'; b.type = 'button'; b.id = 'ds-leave';
    b.innerHTML = '<kbd>L</kbd><b>Leave it</b><span>Let an out ball go</span>';
    b.addEventListener('click', e => { e.stopPropagation(); leaveIt(); });
    $('dShots').appendChild(b);
  }
  function showDecision(d: Decision) {
    const p = d.prov;
    const h = ['Low', 'Net height', 'High'][p.height], pc = ['Soft', 'Medium', 'Hard'][p.pace];
    const dist = Math.abs(d.s.z), where = dist <= 9.5 ? 'Kitchen line' : dist <= 16 ? 'Transition' : 'Baseline';
    const O = [match.players[2], match.players[3]].filter(q => Math.abs(q.z) <= 9.5).length;
    $('dChips').innerHTML = `<span><em>Contact</em>${h}</span><span><em>Incoming</em>${pc}</span><span><em>You</em>${where}</span><span><em>Opponents</em>${O === 2 ? 'Both up' : O === 1 ? 'One back' : 'Both back'}</span><span><em>Shot</em>#${p.shotNo}</span><span><em>Engine</em>${d.modelled ? 'Trained model' : 'Rules'}</span>`;
    ORDER.forEach((t, k) => {
      const a = d.avail[t], b = shotBtns[t], lbl = shotLabel(t, p);
      const sub = lbl === 'Reset' ? SHOT_SUB.reset : lbl === 'Counter' ? SHOT_SUB.counter : SHOT_SUB[t];
      b.innerHTML = `<kbd>${k + 1}</kbd><b>${esc(lbl)}</b><span>${esc(a.ok ? sub : a.why)}</span>`;
      b.disabled = !a.ok; b.setAttribute('aria-pressed', String(d.type === t));
    });
    $('decide').hidden = false; $('kitchen').hidden = true;
    decisionHint();
  }
  function decisionHint() {
    const d = match.decision; if (!d) return;
    $('dHint').innerHTML = d.type
      ? `<b>${esc(shotLabel(d.type, d.prov))}</b> selected · aim with the mouse · <b>click</b> or <b>Space</b> to hit`
      : 'Pick a shot with <b>1–6</b> · aim with the mouse · <b>L</b> to leave it · the ball keeps coming';
  }
  function hideDecision() { $('decide').hidden = true; markers.showHeat(null, null); markers.aim.visible = false; }
  function selectShot(t: ShotType) {
    if (!match.selectShot(t)) return;
    for (const k in shotBtns) shotBtns[k].setAttribute('aria-pressed', String(k === t));
    decisionHint();
  }
  function commit() { if (match.decision && !match.commit()) $('dHint').innerHTML = '<b>Pick a shot first</b> with 1–6, then click to hit'; }
  function leaveIt() { if (!match.decision) return; match.leaveIt(); banner('Leave it', 'Watching it go', '', 1.2); }

  // ------------------------------------------------------------------ overlays
  const overlay = $('overlay');
  const showOverlay = (html: string, clear = false) => { overlay.innerHTML = html; overlay.hidden = false; overlay.className = clear ? 'clear' : ''; };
  const hideOverlay = () => { overlay.hidden = true; overlay.innerHTML = ''; };
  function settingsHTML() {
    return `<div class="row spread"><span class="eyebrow">Opponents</span><div class="seg" role="group" aria-label="Opponent level"><button id="lvClub" aria-pressed="${S.level === 'club'}">Club</button><button id="lvPro" aria-pressed="${S.level === 'pro'}">Pro</button></div></div>
      <label class="opt"><input type="checkbox" id="opEval" ${S.evalMap ? 'checked' : ''}> Eval map <small>colors each target zone by win chance once you pick a shot</small></label>
      <label class="opt"><input type="checkbox" id="opAssist" ${S.assist ? 'checked' : ''}> Footwork assist <small>auto-moves you when you aren't pressing keys</small></label>`;
  }
  function wireSettings() {
    const set = (k: keyof typeof S, v: any) => { (S as any)[k] = v; saveSettings(); match.level = S.level; match.assist = S.assist; sfx.enabled = S.sound; updateBug(); };
    $('lvClub').onclick = () => { set('level', 'club'); $('lvClub').setAttribute('aria-pressed', 'true'); $('lvPro').setAttribute('aria-pressed', 'false'); };
    $('lvPro').onclick = () => { set('level', 'pro'); $('lvPro').setAttribute('aria-pressed', 'true'); $('lvClub').setAttribute('aria-pressed', 'false'); };
    ($('opEval') as HTMLInputElement).onchange = e => set('evalMap', (e.target as HTMLInputElement).checked);
    ($('opAssist') as HTMLInputElement).onchange = e => set('assist', (e.target as HTMLInputElement).checked);
  }
  function showMenu() {
    replay = null; paused = false;
    match.mode = 'attract'; match.score = [0, 0]; match.server = 0; match.gameOver = false;
    hideBanner(); match.newRally(); updateBug();
    showOverlay(`<div class="card">
      <div class="row spread"><span class="eyebrow">Pickleball strategy trainer</span>${modelTagHTML()}</div>
      <h1 class="title">Dink <em>Engine</em></h1>
      <p class="lede">Doubles at game speed. When a ball is coming to you, time slows down so you can make the call. Every shot is graded by a model trained on rallies, and replays show the best option at each hit.</p>
      ${settingsHTML()}
      <div class="row"><button class="btn primary" id="goMatch">Play a match</button><button class="btn" id="goDrills">Drills</button></div>
      <div class="ctl">
        <div><span>Move</span><b>WASD / arrows</b></div><div><span>Pick a shot</span><b>1–6</b></div>
        <div><span>Aim</span><b>Mouse</b></div><div><span>Hit</span><b>Click / Space</b></div>
        <div><span>Leave an out ball</span><b>L</b></div><div><span>Replay after a point</span><b>R</b></div>
      </div>
      <p class="note"><b>Best with a keyboard and mouse.</b> The bundled model is trained on simulated rallies; retrain it on tracked pro footage with the ml/ pipeline.</p>
    </div>`);
    wireSettings();
    $('goMatch').onclick = startMatch; $('goDrills').onclick = showDrills;
  }
  function showDrills() {
    showOverlay(`<div class="card">
      <div class="row spread"><span class="eyebrow">Drills · ${DRILLS.length} positions</span><button class="btn" id="drBack">Back</button></div>
      <p class="lede">Each drill sets up a real situation and feeds you the ball. Make the call, then play out the rally.</p>
      <div class="drills">${DRILLS.map((p, k) => `<button data-k="${k}"><span>${k + 1} · ${esc(p.phase)}</span><b>${esc(p.title)}</b></button>`).join('')}</div>
    </div>`);
    $('drBack').onclick = showMenu;
    overlay.querySelectorAll<HTMLButtonElement>('.drills button').forEach(b => b.onclick = () => startDrill(+b.dataset.k!));
  }
  function startDrill(i: number) {
    sfx.unlock(); hideOverlay(); hideBanner(); physics?.clearBall();
    match.startDrill(i);
    const d = DRILLS[match.drillIdx];
    $('dcE').textContent = `Drill ${match.drillIdx + 1} of ${DRILLS.length} · ${d.phase}`; $('dcT').textContent = d.title; $('dcP').textContent = d.text;
    updateBug(); canvas.focus();
  }
  function startMatch() { sfx.unlock(); hideOverlay(); physics?.clearBall(); match.startMatch(); updateBug(); canvas.focus(); }
  function nextRally() { hideOverlay(); hideBanner(); physics?.clearBall(); match.newRally(); updateBug(); canvas.focus(); }
  function shotsListHTML(shots: UserShot[]) {
    if (!shots.length) return '<p class="note">You didn’t hit a ball this rally.</p>';
    return `<ul class="shotList">${shots.map(s => `<li>${badge(s.g)}<span>${esc(s.opt.label)} → ${esc(s.opt.zone)}${s.auto ? ' (auto)' : ''}</span><span class="p">${pct(s.opt.P)} / ${pct(s.best.P)}</span></li>`).join('')}</ul>`;
  }
  function showPointCard() {
    const r = match.rally?.result; if (!r || !match.rally) return;
    if (match.mode === 'drill') {
      const first = match.rally.userShots[0];
      showOverlay(`<div class="card side">
        <span class="eyebrow">Drill ${match.drillIdx + 1} · ${esc(DRILLS[match.drillIdx].title)}</span>
        <h2 class="h2 ${r.winner === 0 ? 'win' : 'lose'}">${r.winner === 0 ? 'You won the rally' : 'You lost the rally'}</h2>
        <p class="note">${esc(r.reason)}.</p>
        ${first ? `<div class="row">${badge(first.g)}<span><b>Your call: ${esc(first.opt.label)} to the ${esc(first.opt.zone)}</b> (${pct(first.opt.P)}). Best was ${esc(first.best.label.toLowerCase())} to the ${esc(first.best.zone)} (${pct(first.best.P)}).</span></div>` : '<p class="note">You didn’t reach the feed. Move toward the coral ring, or turn on footwork assist.</p>'}
        <div class="row"><button class="btn primary" id="pcAgain">Retry <kbd>Space</kbd></button><button class="btn" id="pcNext">Next drill <kbd>N</kbd></button><button class="btn" id="pcRp">Replay <kbd>R</kbd></button><button class="btn" id="pcMenu">Menu</button></div>
      </div>`, true);
      $('pcAgain').onclick = () => startDrill(match.drillIdx); $('pcNext').onclick = () => startDrill(match.drillIdx + 1);
      $('pcRp').onclick = startReplay; $('pcMenu').onclick = showMenu;
      return;
    }
    if (match.gameOver) {
      const won = match.score[0] > match.score[1], st = match.stats, acc = st.accN ? Math.round(st.accSum / st.accN) : 0;
      showOverlay(`<div class="card">
        <span class="eyebrow">Game over · ${S.level === 'pro' ? 'Pro' : 'Club'} opponents</span>
        <h2 class="h2 ${won ? 'win' : 'lose'}">${won ? 'Your team wins' : 'Opponents win'} ${match.score[0]}–${match.score[1]}</h2>
        <div class="row" style="gap:18px"><div><div class="eyebrow">Shot accuracy</div><div class="big">${acc}%</div></div><div><div class="eyebrow">Shots called</div><div class="big">${st.accN}</div></div></div>
        <div class="counts">${GRADES.map(g => `<span>${badge(g)}${esc(g.name)} ${st.grades[g.key] || 0}</span>`).join('')}</div>
        <div class="row"><button class="btn primary" id="goAgain">Play again</button><button class="btn" id="pcRp">Replay last rally <kbd>R</kbd></button><button class="btn" id="pcMenu">Menu</button></div>
      </div>`);
      $('goAgain').onclick = startMatch; $('pcRp').onclick = startReplay; $('pcMenu').onclick = showMenu;
      return;
    }
    showOverlay(`<div class="card side">
      <span class="eyebrow">Rally ${match.score[0] + match.score[1]} · ${match.server === 0 ? 'your team serves next' : 'opponents serve next'}</span>
      <h2 class="h2 ${r.winner === 0 ? 'win' : 'lose'}">${r.winner === 0 ? 'Point · your team' : 'Point · opponents'}</h2>
      <p class="note">${esc(r.reason)}.</p>
      ${shotsListHTML(match.rally.userShots)}
      <div class="row"><button class="btn primary" id="pcNextR">Next rally <kbd>Space</kbd></button><button class="btn" id="pcRp">Watch replay <kbd>R</kbd></button></div>
    </div>`, true);
    $('pcNextR').onclick = nextRally; $('pcRp').onclick = startReplay;
  }
  function pause() {
    if (match.mode === 'attract' || paused || replay) return;
    paused = true;
    showOverlay(`<div class="card"><span class="eyebrow">Paused</span><h2 class="h2">Timeout</h2>${settingsHTML()}
      <div class="row"><button class="btn primary" id="psGo">Resume <kbd>P</kbd></button><button class="btn" id="psMenu">Quit to menu</button></div></div>`);
    wireSettings();
    $('psGo').onclick = resume; $('psMenu').onclick = showMenu;
  }
  function resume() { if (!paused) return; paused = false; hideOverlay(); if (match.rallyOver && afterPoint <= 0) showPointCard(); canvas.focus(); }

  // ------------------------------------------------------------------ replay
  const STRIDE = 8;
  function startReplay() {
    const r = match.rally; if (!r || r.frames.length < 2) return;
    hideOverlay(); hideBanner(); physics?.clearBall();
    replay = { t: r.frames[0][0], fi: 0, ev: 0, paused: false };
    banner('Replay · ½ speed', 'Space pauses · Esc returns', '', 0);
  }
  function applyFrame(f: number[]) {
    match.ball.p = { x: f[1], y: f[2], z: f[3] }; match.ball.live = f[4] === 1;
    match.players.forEach((p, k) => {
      const o = 5 + k * STRIDE;
      p.x = f[o]; p.z = f[o + 1]; p.rot = f[o + 2]; const sp = f[o + 3]; p.vx = sp; p.vz = 0;
      p.swingT = f[o + 4]; p.swingKind = f[o + 5]; p.prep = f[o + 6]; p.prepKind = f[o + 7];
    });
  }
  function updateReplay(dtR: number) {
    const r = match.rally!, fr = r.frames, rp = replay!;
    if (rp.paused) return;
    rp.t += dtR * 0.5;
    if (rp.ev < r.userShots.length && rp.t >= r.userShots[rp.ev].t) { rp.t = r.userShots[rp.ev].t; rp.paused = true; showReplayShot(r.userShots[rp.ev], rp.ev); rp.ev++; }
    while (rp.fi < fr.length - 1 && fr[rp.fi + 1][0] <= rp.t) rp.fi++;
    applyFrame(fr[rp.fi]);
    if (rp.fi >= fr.length - 1 && !rp.paused) endReplay();
  }
  function showReplayShot(s: UserShot, k: number) {
    markers.showHeat(s.evals, s.best.type);
    const bz = zoneCenter(1, s.best.col, s.best.depth);
    markers.best.visible = true; markers.best.position.set(bz.x - 10, 0.04, bz.y - 22);
    markers.chosen.visible = true; markers.chosen.position.set(s.target.x, 0.045, s.target.z);
    const rows = s.evals.slice(0, 4).map((o, n) => ({ o, n }));
    const mi = s.evals.indexOf(s.opt); if (mi >= 4) rows.push({ o: s.opt, n: mi });
    const list = rows.map(({ o, n }) => `<li class="${o === s.opt ? 'mine g-' + s.g.key : ''} ${n === 0 ? 'best' : ''}"><span class="n">${n + 1}</span><span>${esc(o.label)} → ${esc(o.zone)}${o === s.opt ? ' (you)' : ''}</span><span class="bar"><i style="width:${Math.round(o.P / s.best.P * 100)}%"></i></span><span class="v">${pct(o.P)}</span></li>`).join('');
    showOverlay(`<div class="card side">
      <div class="row spread"><span class="eyebrow">Replay · your shot ${k + 1} of ${match.rally!.userShots.length} · shot #${s.shotNo}</span><span class="badge g-${s.g.key}">${esc(s.g.glyph)} ${esc(s.g.name)}</span></div>
      <div><b>${esc(s.opt.label)} to the ${esc(s.opt.zone)}</b> · ${pct(s.opt.P)}${s.auto ? ' (auto block)' : ''}<br><span class="note">Best: ${esc(s.best.label.toLowerCase())} to the ${esc(s.best.zone)} · ${pct(s.best.P)}. White ring is where you aimed, yellow ring is the best target. Zone colors show the best shot type. Scored by the ${s.modelled ? 'trained model' : 'rule engine'}.</span></div>
      <ol class="rank">${list}</ol>
      <div class="row"><button class="btn primary" id="rpGo">Continue <kbd>Space</kbd></button><button class="btn" id="rpEnd">End replay <kbd>Esc</kbd></button></div>
    </div>`, true);
    $('rpGo').onclick = resumeReplay; $('rpEnd').onclick = endReplay;
  }
  function resumeReplay() { if (!replay) return; replay.paused = false; hideOverlay(); markers.showHeat(null, null); markers.best.visible = false; markers.chosen.visible = false; }
  function endReplay() {
    const r = match.rally!; replay = null;
    markers.showHeat(null, null); markers.best.visible = false; markers.chosen.visible = false; hideBanner();
    applyFrame(r.frames[r.frames.length - 1]);
    showPointCard();
  }

  // ------------------------------------------------------------------ input
  const keys = new Set<string>();
  const ray = new THREE.Raycaster(), ndc = new THREE.Vector2(), ground = new THREE.Plane(new THREE.Vector3(0, 1, 0), 0), hit = new THREE.Vector3();
  canvas.addEventListener('pointermove', e => {
    const r = canvas.getBoundingClientRect();
    ndc.set(((e.clientX - r.left) / r.width) * 2 - 1, -((e.clientY - r.top) / r.height) * 2 + 1);
    ray.setFromCamera(ndc, camera);
    if (ray.ray.intersectPlane(ground, hit)) { match.aim.x = hit.x; match.aim.z = hit.z; }
  });
  canvas.addEventListener('pointerdown', e => {
    if (e.button !== 0) return;
    canvas.focus(); sfx.unlock();
    if (match.serveWait) { hideBanner(); match.userServe(); }
    else if (match.decision) commit();
  });
  const toggle = (k: 'evalMap' | 'assist' | 'sound') => { S[k] = !S[k]; saveSettings(); match.assist = S.assist; sfx.enabled = S.sound; if (k === 'sound' && S.sound) sfx.unlock(); updateBug(); };
  $('tEval').onclick = () => toggle('evalMap');
  $('tAssist').onclick = () => toggle('assist');
  $('tSound').onclick = () => toggle('sound');
  $('tPause').onclick = () => (paused ? resume() : pause());
  const MOVE_KEYS = ['w', 'a', 's', 'd', 'arrowup', 'arrowdown', 'arrowleft', 'arrowright'];
  window.addEventListener('keydown', e => {
    const k = e.key.toLowerCase();
    if ([' ', ...MOVE_KEYS].includes(k)) e.preventDefault();
    if (e.repeat && !MOVE_KEYS.includes(k)) return;
    keys.add(k);
    if (replay) {
      if (k === ' ') { if (replay.paused) resumeReplay(); else replay.paused = true; }
      if (k === 'escape') endReplay();
      return;
    }
    if (k === 'p' || k === 'escape') { if (paused) resume(); else pause(); return; }
    if (paused || match.mode === 'attract') return;
    if (k === 'e') toggle('evalMap');
    if (k === 'f') toggle('assist');
    if (k === 'm') toggle('sound');
    if (match.decision) {
      const n = parseInt(k, 10);
      if (n >= 1 && n <= 6) selectShot(ORDER[n - 1]);
      if (k === '7' || k === 'l') leaveIt();
      if (k === ' ' || k === 'enter') commit();
      return;
    }
    if (match.serveWait && (k === ' ' || k === 'enter')) { hideBanner(); match.userServe(); return; }
    if (match.rallyOver && afterPoint <= 0) {
      if (k === 'r') startReplay();
      else if (match.mode === 'drill') { if (k === ' ' || k === 'enter') startDrill(match.drillIdx); if (k === 'n') startDrill(match.drillIdx + 1); }
      else if (!match.gameOver && (k === ' ' || k === 'enter')) nextRally();
    }
  });
  window.addEventListener('keyup', e => keys.delete(e.key.toLowerCase()));
  window.addEventListener('blur', () => keys.clear());
  function readMoveInput() {
    let x = 0, z = 0;
    if (keys.has('a') || keys.has('arrowleft')) x -= 1;
    if (keys.has('d') || keys.has('arrowright')) x += 1;
    if (keys.has('w') || keys.has('arrowup')) z -= 1;
    if (keys.has('s') || keys.has('arrowdown')) z += 1;
    match.input.x = x; match.input.z = z;
  }

  // ------------------------------------------------------------------ camera + per-frame visuals
  const camPos = new THREE.Vector3(0, 15.5, 41.5), look = new THREE.Vector3(0, 0.5, -4);
  let orbit = 0;
  function updateCamera(dtR: number) {
    const u = match.user, back = camera.aspect < 1.25 ? (1.25 / camera.aspect) * 0.6 + 0.4 : 1;
    let tp: THREE.Vector3, tl: THREE.Vector3;
    if (match.mode === 'attract' && !replay) {
      orbit += dtR * 0.06; const a = Math.sin(orbit) * 0.55;
      tp = new THREE.Vector3(Math.sin(a) * 44, 17, Math.cos(a) * 44); tl = new THREE.Vector3(0, 1, 0);
    } else if (match.decision) {
      tp = new THREE.Vector3(clamp(u.x * 0.45, -6, 6), 13 * back, Math.max(u.z + 20, 30) * back); tl = new THREE.Vector3(u.x * 0.2, 0.5, -9);
    } else {
      tp = new THREE.Vector3(clamp(u.x * 0.35, -4, 4), 15.5 * back, 41.5 * back); tl = new THREE.Vector3(clamp(u.x * 0.2, -3, 3), 0.5, -4);
    }
    const k = 1 - Math.exp(-dtR * 3.2);
    camPos.lerp(tp, k); look.lerp(tl, k);
    camera.position.copy(camPos); camera.lookAt(look);
  }
  function updateVisuals(dtGame: number) {
    match.players.forEach((p, i) => chars[i].update({ x: p.x, z: p.z, rot: p.rot, speed: Math.hypot(p.vx, p.vz), swingT: p.swingT, swingKind: p.swingKind, prep: p.prep, prepKind: p.prepKind }, dtGame));
    const dead = match.rallyOver && !replay ? physics?.ballPosition() : null;
    markers.setBall(dead || match.ball.p, match.ball.live && !match.rallyOver);
    const aids = match.mode !== 'attract' && !replay;
    const u = match.user;
    markers.you.visible = aids; markers.you.position.set(u.x, 0.035, u.z);
    markers.youLabel.visible = aids && !match.decision; markers.youLabel.position.set(u.x, 6.9, u.z);
    const fb = match.pred?.firstBounce;
    const showBounce = aids && match.ball.live && !match.rallyOver && match.ball.lastHitTeam === 1 && !!fb && fb.side === 0 && fb.t > match.rallyTime;
    markers.bounce.visible = showBounce;
    if (showBounce && fb) {
      markers.bounce.position.set(fb.x, 0.035, fb.z);
      const out = Math.abs(fb.x) > W + 0.2 || Math.abs(fb.z) > L + 0.2;
      (markers.bounce.material as THREE.MeshBasicMaterial).color.set(out ? 0xf2705e : 0xddf03a);
    }
    const plan = match.plans[1];
    markers.stand.visible = aids && !!plan && !match.rallyOver && !match.pending?.leave;
    if (plan && markers.stand.visible) { markers.stand.position.set(plan.st.x, 0.035, plan.st.z); markers.stand.scale.setScalar(1 + Math.sin(performance.now() / 150) * 0.06); }
    if (!replay && (match.decision || match.serveWait)) {
      const d = match.decision;
      const type = match.serveWait ? 'serve' : d!.type || 'drive';
      const a = clampAim(type as any, match.aim, 0, match.rally?.boxSign ?? 1);
      markers.aim.visible = true; markers.aim.position.set(a.x, 0, a.z);
      markers.showHeat(d && S.evalMap && d.type ? d.evals : null, d?.type ?? null);
      if (d) ($('dTimer') as HTMLElement).style.width = clamp((d.contactT - match.rallyTime) / Math.max(0.05, d.contactT - d.t0), 0, 1) * 100 + '%';
    } else if (!replay) markers.aim.visible = false;
    $('kitchen').hidden = !(aids && !match.decision && Math.abs(u.z) < K && match.ball.live && !match.rallyOver);
    $('keys').hidden = match.mode === 'attract' || !!match.decision;
  }

  // ------------------------------------------------------------------ main loop
  function resize() {
    const w = game.clientWidth, h = game.clientHeight;
    renderer.setSize(w, h, false); composer.setSize(w, h);
    camera.aspect = w / Math.max(1, h);
    camera.fov = camera.aspect < 1.1 ? clamp(44 * Math.pow(1.1 / camera.aspect, 0.5), 44, 70) : 44;
    camera.updateProjectionMatrix();
  }
  new ResizeObserver(resize).observe(game); resize();
  let last = performance.now(), timeScale = 1;
  function frame(now: number) {
    const dtR = clamp((now - last) / 1000, 0, 0.05); last = now;
    timeScale = lerp(timeScale, match.timeTarget, Math.min(1, dtR * (match.timeTarget < timeScale ? 14 : 6)));
    let dtGame = dtR * timeScale;
    if (replay) { updateReplay(dtR); dtGame = dtR * 0.5; }
    else if (!paused) {
      readMoveInput();
      if (match.rallyCount !== lastRallyCount) { lastRallyCount = match.rallyCount; resolved = match.players.map(p => ({ x: p.x, z: p.z })); physics?.teleport(resolved); markers.resetTrail(); }
      match.update(dtGame);
      if (physics) {
        resolved = physics.resolvePlayers(resolved, match.players.map(p => ({ x: p.x, z: p.z })), dtGame);
        resolved.forEach((p, i) => { match.players[i].x = p.x; match.players[i].z = p.z; });
      }
      match.record();
      if (match.rallyOver && afterPoint > 0) {
        afterPoint -= dtR;
        if (afterPoint <= 0) { if (match.mode === 'attract') { physics?.clearBall(); match.newRally(); } else showPointCard(); }
      }
    } else dtGame = 0;
    if (bannerT > 0) { bannerT -= dtR; if (bannerT <= 0) hideBanner(); }
    if (toastT > 0) { toastT -= dtR; if (toastT <= 0) $('toast').className = 'hud'; }
    updateVisuals(dtGame); updateCamera(dtR);
    composer.render(dtR);
    requestAnimationFrame(frame);
  }
  setLoad(1, 'Ready');
  showMenu();
  $('loading').classList.add('done');
  requestAnimationFrame(frame);
  (window as any).__dink = { match, physics: !!physics, model: () => modelCard };
}
