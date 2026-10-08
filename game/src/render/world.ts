// Static scene: sky, sun, court surface, net, fence, light poles, bleachers and trees.
import * as THREE from 'three';
import { Sky } from 'three/examples/jsm/objects/Sky.js';
import { NET_H } from '../config';

export function courtTexture(renderer: THREE.WebGLRenderer) {
  const P = 48, Wd = 32, Ln = 64;
  const c = document.createElement('canvas'); c.width = Wd * P; c.height = Ln * P;
  const g = c.getContext('2d')!;
  const X = (x: number) => (x + 16) * P, Z = (z: number) => (z + 32) * P;
  g.fillStyle = '#3a7053'; g.fillRect(0, 0, c.width, c.height);
  g.fillStyle = '#29578a'; g.fillRect(X(-10), Z(-22), 20 * P, 44 * P);
  g.fillStyle = '#32659b'; g.fillRect(X(-10), Z(-7), 20 * P, 14 * P);
  // textured acrylic surface
  const img = g.getImageData(0, 0, c.width, c.height), d = img.data;
  for (let k = 0; k < d.length; k += 4) { const n = (Math.random() - 0.5) * 10; d[k] += n; d[k + 1] += n; d[k + 2] += n; }
  g.putImageData(img, 0, 0);
  g.fillStyle = '#eef2ec';
  const lw = Math.round(0.17 * P);
  g.fillRect(X(-10), Z(-22), lw, 44 * P); g.fillRect(X(10) - lw, Z(-22), lw, 44 * P);
  g.fillRect(X(-10), Z(-22), 20 * P, lw); g.fillRect(X(-10), Z(22) - lw, 20 * P, lw);
  g.fillRect(X(-10), Z(-7), 20 * P, lw); g.fillRect(X(-10), Z(7) - lw, 20 * P, lw);
  g.fillRect(X(0) - lw / 2, Z(-22), lw, 15 * P); g.fillRect(X(0) - lw / 2, Z(7), lw, 15 * P);
  g.save(); g.fillStyle = 'rgba(238,242,236,.14)'; g.font = `800 ${2.2 * P}px "Big Shoulders Display", Impact, sans-serif`;
  g.textAlign = 'center'; g.translate(X(0), Z(27)); g.fillText('DINK ENGINE', 0, 0); g.restore();
  const t = new THREE.CanvasTexture(c);
  t.colorSpace = THREE.SRGBColorSpace;
  t.anisotropy = renderer.capabilities.getMaxAnisotropy();
  return t;
}

export function buildWorld(scene: THREE.Scene, renderer: THREE.WebGLRenderer) {
  // sky + sun
  const sky = new Sky();
  sky.scale.setScalar(4000);
  const u = sky.material.uniforms;
  u.turbidity.value = 4.5; u.rayleigh.value = 1.4; u.mieCoefficient.value = 0.004; u.mieDirectionalG.value = 0.82;
  const sunDir = new THREE.Vector3().setFromSphericalCoords(1, THREE.MathUtils.degToRad(58), THREE.MathUtils.degToRad(-35));
  u.sunPosition.value.copy(sunDir);
  scene.add(sky);
  // image-based lighting from the sky
  const pmrem = new THREE.PMREMGenerator(renderer);
  const envScene = new THREE.Scene(); const envSky = new Sky(); envSky.scale.setScalar(4000);
  Object.assign(envSky.material.uniforms, THREE.UniformsUtils.clone(u)); envSky.material.uniforms.sunPosition.value.copy(sunDir);
  envScene.add(envSky);
  scene.environment = pmrem.fromScene(envScene, 0.02).texture;
  scene.environmentIntensity = 0.42;
  scene.fog = new THREE.Fog(0xc9d7dc, 170, 520);

  const hemi = new THREE.HemisphereLight(0xdcecff, 0x4b6a46, 0.45);
  scene.add(hemi);
  const sun = new THREE.DirectionalLight(0xfff0d6, 2.2);
  sun.position.copy(sunDir).multiplyScalar(80);
  sun.castShadow = true;
  sun.shadow.mapSize.set(2048, 2048);
  Object.assign(sun.shadow.camera, { left: -38, right: 38, top: 44, bottom: -44, near: 20, far: 200 });
  sun.shadow.bias = -0.0004; sun.shadow.normalBias = 0.03; sun.shadow.radius = 2.5;
  scene.add(sun, sun.target);

  // ground + court
  const grass = new THREE.Mesh(new THREE.PlaneGeometry(900, 900), new THREE.MeshStandardMaterial({ color: 0x5a7d42, roughness: 1 }));
  grass.rotation.x = -Math.PI / 2; grass.position.y = -0.03; grass.receiveShadow = true; scene.add(grass);
  const court = new THREE.Mesh(new THREE.PlaneGeometry(32, 64), new THREE.MeshStandardMaterial({ map: courtTexture(renderer), roughness: 0.82, metalness: 0 }));
  court.rotation.x = -Math.PI / 2; court.receiveShadow = true; scene.add(court);

  const box = (w: number, h: number, d: number, mat: THREE.Material, x: number, y: number, z: number, shadow = true) => {
    const m = new THREE.Mesh(new THREE.BoxGeometry(w, h, d), mat);
    m.position.set(x, y, z); m.castShadow = shadow; m.receiveShadow = true; scene.add(m); return m;
  };
  const fence = new THREE.MeshStandardMaterial({ color: 0x1d3a2e, roughness: 0.95 });
  const metal = new THREE.MeshStandardMaterial({ color: 0x3a4248, roughness: 0.45, metalness: 0.7 });
  box(0.15, 8, 64, fence, -16, 4, 0); box(0.15, 8, 64, fence, 16, 4, 0); box(32, 8, 0.15, fence, 0, 4, -32);
  box(0.22, 0.22, 64, metal, -16, 8.1, 0); box(0.22, 0.22, 64, metal, 16, 8.1, 0); box(32, 0.22, 0.22, metal, 0, 8.1, -32);
  for (let z = -32; z <= 32; z += 8) { box(0.18, 8.2, 0.18, metal, -16, 4.1, z); box(0.18, 8.2, 0.18, metal, 16, 4.1, z); }
  for (const [x, z] of [[-17.5, -30], [17.5, -30], [-17.5, 30], [17.5, 30]] as const) {
    const pole = new THREE.Mesh(new THREE.CylinderGeometry(0.22, 0.32, 26, 10), metal); pole.position.set(x, 13, z); pole.castShadow = true; scene.add(pole);
    const head = box(2.8, 0.7, 1.3, new THREE.MeshStandardMaterial({ color: 0xf6f2de, emissive: 0x77735a, roughness: 0.3 }), x - Math.sign(x), 26, z, false);
    head.rotation.z = Math.sign(x) * 0.25;
  }
  const bench = new THREE.MeshStandardMaterial({ color: 0xa9b3b8, roughness: 0.35, metalness: 0.65 });
  for (let i = 0; i < 4; i++) box(1.7, (i + 1) * 1.05, 26, bench, 18.6 + i * 1.7, (i + 1) * 0.525, -2);

  // trees (instanced)
  let seed = 11; const rnd = () => ((seed = (seed * 16807) % 2147483647) / 2147483647);
  const coneGeo = new THREE.ConeGeometry(1, 1, 8), trunkGeo = new THREE.CylinderGeometry(0.5, 0.7, 4, 6);
  const N = 60;
  const leaves = new THREE.InstancedMesh(coneGeo, new THREE.MeshStandardMaterial({ color: 0x33603a, roughness: 1, flatShading: true }), N);
  const trunks = new THREE.InstancedMesh(trunkGeo, new THREE.MeshStandardMaterial({ color: 0x5b4632, roughness: 1 }), N);
  leaves.castShadow = true;
  const m4 = new THREE.Matrix4(), q = new THREE.Quaternion(), tint = new THREE.Color();
  for (let k = 0; k < N; k++) {
    let x: number, z: number;
    if (k < 34) { x = -110 + rnd() * 220; z = -50 - rnd() * 90; } else { x = (rnd() < 0.5 ? -1 : 1) * (30 + rnd() * 70); z = -45 + rnd() * 75; }
    const h = 12 + rnd() * 18, r = 4 + rnd() * 4.5;
    leaves.setMatrixAt(k, m4.compose(new THREE.Vector3(x, h / 2 + 3, z), q, new THREE.Vector3(r, h, r)));
    leaves.setColorAt(k, tint.setHSL(0.3 + rnd() * 0.05, 0.38, 0.22 + rnd() * 0.08));
    trunks.setMatrixAt(k, m4.compose(new THREE.Vector3(x, 2, z), q, new THREE.Vector3(1, 1, 1)));
  }
  scene.add(leaves, trunks);

  // net
  const nc = document.createElement('canvas'); nc.width = 1024; nc.height = 128;
  const ng = nc.getContext('2d')!; ng.strokeStyle = 'rgba(12,18,22,.92)'; ng.lineWidth = 2;
  for (let x = 0; x <= 1024; x += 12) { ng.beginPath(); ng.moveTo(x, 0); ng.lineTo(x, 128); ng.stroke(); }
  for (let y = 0; y <= 128; y += 12) { ng.beginPath(); ng.moveTo(0, y); ng.lineTo(1024, y); ng.stroke(); }
  ng.fillStyle = 'rgba(12,18,22,.96)'; ng.fillRect(0, 118, 1024, 10);
  const nt = new THREE.CanvasTexture(nc); nt.colorSpace = THREE.SRGBColorSpace;
  const net = new THREE.Mesh(new THREE.PlaneGeometry(22, NET_H - 0.2), new THREE.MeshStandardMaterial({ map: nt, transparent: true, alphaTest: 0.1, side: THREE.DoubleSide, roughness: 1 }));
  net.position.set(0, 0.2 + (NET_H - 0.2) / 2, 0); net.castShadow = true; scene.add(net);
  const white = new THREE.MeshStandardMaterial({ color: 0xf4f4ef, roughness: 0.5 });
  box(22, 0.2, 0.07, white, 0, NET_H - 0.1, 0);
  box(0.16, NET_H, 0.05, white, 0, NET_H / 2, 0);
  for (const x of [-11, 11]) { const p = new THREE.Mesh(new THREE.CylinderGeometry(0.13, 0.13, 3.1, 12), metal); p.position.set(x, 1.55, 0); p.castShadow = true; scene.add(p); }
  return { sun };
}
