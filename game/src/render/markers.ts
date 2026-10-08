// Ball, ground markers, aim reticle and the eval-map heat zones.
import * as THREE from 'three';
import { DEPTH_BOUNDS, type ShotOption, type ShotType } from '../engine/rules';
import { clamp } from '../config';

export function heatRGB(loss: number): [number, number, number] {
  const stops: [number, number[]][] = [[0, [221, 240, 58]], [4, [190, 228, 96]], [8, [242, 196, 72]], [15, [238, 136, 74]], [25, [226, 88, 72]]];
  const L = clamp(loss, 0, 25);
  for (let k = 1; k < stops.length; k++) if (L <= stops[k][0]) {
    const [a, ca] = stops[k - 1], [b, cb] = stops[k], t = (L - a) / (b - a);
    return ca.map((v, j) => Math.round(v + (cb[j] - v) * t)) as [number, number, number];
  }
  return [226, 88, 72];
}

function ring(scene: THREE.Scene, r0: number, r1: number, color: number, opacity: number) {
  const m = new THREE.Mesh(new THREE.RingGeometry(r0, r1, 48), new THREE.MeshBasicMaterial({ color, transparent: true, opacity, depthWrite: false, side: THREE.DoubleSide, toneMapped: false }));
  m.rotation.x = -Math.PI / 2; m.position.y = 0.035; m.visible = false; m.renderOrder = 2; scene.add(m); return m;
}

export function labelSprite(text: string, bg: string, fg: string) {
  const c = document.createElement('canvas'); c.width = 256; c.height = 96;
  const g = c.getContext('2d')!;
  g.fillStyle = bg; g.beginPath(); g.roundRect(48, 12, 160, 72, 36); g.fill();
  g.fillStyle = fg; g.font = '800 54px "Big Shoulders Display", Impact, sans-serif'; g.textAlign = 'center'; g.textBaseline = 'middle'; g.fillText(text, 128, 50);
  const t = new THREE.CanvasTexture(c); t.colorSpace = THREE.SRGBColorSpace;
  const s = new THREE.Sprite(new THREE.SpriteMaterial({ map: t, depthTest: false, transparent: true, toneMapped: false }));
  s.scale.set(2.1, 0.78, 1); s.renderOrder = 10; return s;
}

export class Markers {
  ball: THREE.Mesh; blob: THREE.Mesh; trail: THREE.Line;
  bounce: THREE.Mesh; stand: THREE.Mesh; you: THREE.Mesh; best: THREE.Mesh; chosen: THREE.Mesh;
  aim = new THREE.Group();
  youLabel: THREE.Sprite;
  private trailPos: Float32Array; private trailInit = false;
  private zones: { c: number; d: number; m: THREE.Mesh; sp: THREE.Sprite; canvas: HTMLCanvasElement; tex: THREE.CanvasTexture; last: string }[] = [];

  constructor(private scene: THREE.Scene) {
    this.ball = new THREE.Mesh(new THREE.SphereGeometry(0.21, 24, 16), new THREE.MeshStandardMaterial({ color: 0xdcef3a, emissive: 0x4a5600, roughness: 0.45 }));
    this.ball.castShadow = true; scene.add(this.ball);
    this.blob = new THREE.Mesh(new THREE.CircleGeometry(0.3, 20), new THREE.MeshBasicMaterial({ color: 0x000000, transparent: true, opacity: 0.38, depthWrite: false }));
    this.blob.rotation.x = -Math.PI / 2; this.blob.position.y = 0.02; scene.add(this.blob);
    const N = 18; this.trailPos = new Float32Array(N * 3);
    const tg = new THREE.BufferGeometry(); tg.setAttribute('position', new THREE.BufferAttribute(this.trailPos, 3));
    this.trail = new THREE.Line(tg, new THREE.LineBasicMaterial({ color: 0xf6ffd2, transparent: true, opacity: 0.45, toneMapped: false }));
    this.trail.frustumCulled = false; scene.add(this.trail);
    this.bounce = ring(scene, 0.3, 0.48, 0xddf03a, 0.95);
    this.stand = ring(scene, 0.95, 1.12, 0xf47b4b, 0.9);
    this.you = ring(scene, 1.1, 1.3, 0xf47b4b, 0.5);
    this.best = ring(scene, 0.75, 1.0, 0xddf03a, 1);
    this.chosen = ring(scene, 0.75, 1.0, 0xffffff, 1);
    const r = ring(scene, 0.72, 0.86, 0xffffff, 0.95); scene.remove(r); r.visible = true; this.aim.add(r);
    const lm = new THREE.MeshBasicMaterial({ color: 0xffffff, transparent: true, opacity: 0.95, depthWrite: false, toneMapped: false });
    for (const rot of [0, Math.PI / 2]) { const b = new THREE.Mesh(new THREE.PlaneGeometry(2.2, 0.1), lm); b.rotation.x = -Math.PI / 2; b.rotation.z = rot; b.position.y = 0.04; this.aim.add(b); }
    this.aim.visible = false; scene.add(this.aim);
    this.youLabel = labelSprite('YOU', '#f47b4b', '#1a1208');
    scene.add(this.youLabel);
    for (let d = 0; d < 3; d++) for (let c = 0; c < 3; c++) {
      const [d0, d1] = DEPTH_BOUNDS[d];
      const m = new THREE.Mesh(new THREE.PlaneGeometry(20 / 3 - 0.35, d1 - d0 - 0.35), new THREE.MeshBasicMaterial({ color: 0xffffff, transparent: true, opacity: 0.5, depthWrite: false, toneMapped: false }));
      m.rotation.x = -Math.PI / 2; m.position.set((c + 0.5) * 20 / 3 - 10, 0.03, -(d0 + d1) / 2); m.visible = false; m.renderOrder = 1; scene.add(m);
      const canvas = document.createElement('canvas'); canvas.width = 256; canvas.height = 128;
      const tex = new THREE.CanvasTexture(canvas); tex.colorSpace = THREE.SRGBColorSpace;
      const sp = new THREE.Sprite(new THREE.SpriteMaterial({ map: tex, depthTest: false, transparent: true, toneMapped: false }));
      sp.scale.set(2.6, 1.3, 1); sp.position.set(m.position.x, 0.9, m.position.z); sp.visible = false; sp.renderOrder = 5; scene.add(sp);
      this.zones.push({ c, d, m, sp, canvas, tex, last: '' });
    }
  }

  setBall(p: { x: number; y: number; z: number }, live: boolean) {
    const by = Math.max(p.y, 0.21);
    this.ball.position.set(p.x, by, p.z);
    this.blob.position.set(p.x, 0.02, p.z);
    const hs = clamp(1 - p.y / 14, 0.35, 1); this.blob.scale.setScalar(hs);
    (this.blob.material as THREE.MeshBasicMaterial).opacity = 0.38 * hs;
    const tp = this.trailPos, n = tp.length / 3;
    if (!this.trailInit) { for (let k = 0; k < n; k++) tp.set([p.x, by, p.z], k * 3); this.trailInit = true; }
    tp.copyWithin(3, 0, (n - 1) * 3); tp.set([p.x, by, p.z], 0);
    this.trail.geometry.attributes.position.needsUpdate = true;
    this.trail.visible = live;
  }
  resetTrail() { this.trailInit = false; }

  showHeat(evals: ShotOption[] | null, type: ShotType | null) {
    for (const z of this.zones) {
      const o = evals && type ? evals.find(e => e.type === type && e.col === z.c && e.depth === z.d) : null;
      if (!o || !evals) { z.m.visible = false; z.sp.visible = false; continue; }
      const loss = (evals[0].P - o.P) * 100, rgb = heatRGB(loss);
      (z.m.material as THREE.MeshBasicMaterial).color.setRGB(rgb[0] / 255, rgb[1] / 255, rgb[2] / 255, THREE.SRGBColorSpace);
      z.m.visible = true; z.sp.visible = true;
      const txt = Math.round(o.P * 100) + '%';
      if (z.last !== txt) {
        const g = z.canvas.getContext('2d')!; g.clearRect(0, 0, 256, 128);
        g.fillStyle = 'rgba(10,17,24,.84)'; g.beginPath(); g.roundRect(60, 20, 136, 88, 18); g.fill();
        g.fillStyle = `rgb(${rgb.join(',')})`; g.font = '600 52px "IBM Plex Mono", monospace'; g.textAlign = 'center'; g.textBaseline = 'middle'; g.fillText(txt, 128, 66);
        z.tex.needsUpdate = true; z.last = txt;
      }
    }
  }
}
