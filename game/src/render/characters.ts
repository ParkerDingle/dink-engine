// Rigged, animated players. The body comes from a skinned glTF character (idle / walk / run clips);
// paddle swings are layered on top procedurally by aiming the arm bones, so any humanoid rig with
// standard Mixamo bone names can be dropped in as public/assets/player.glb later.
import * as THREE from 'three';
import { GLTFLoader } from 'three/examples/jsm/loaders/GLTFLoader.js';
import * as SkeletonUtils from 'three/examples/jsm/utils/SkeletonUtils.js';
import { fetchBinary } from '../fetchBinary';

type V = [number, number, number];
// Upper-arm and forearm directions in the character's own frame (facing +z, its right hand on -x).
const READY: [V, V] = [[-0.35, -0.8, 0.45], [-0.25, -0.25, 0.93]];
const SWINGS: Record<number, { a0: [V, V]; a1: [V, V]; t0: number; t1: number }> = {
  1: { a0: [[-0.9, -0.3, -0.3], [-0.6, 0.15, -0.78]], a1: [[0.35, -0.15, 0.92], [0.85, 0.1, 0.5]], t0: -0.55, t1: 0.45 },   // forehand
  2: { a0: [[0.45, -0.45, 0.6], [0.9, -0.1, 0.1]], a1: [[-0.65, -0.15, 0.7], [-0.9, 0.25, 0.35]], t0: 0.55, t1: -0.3 },     // backhand
  3: { a0: [[-0.45, 0.85, -0.25], [-0.2, 0.5, -0.85]], a1: [[-0.15, -0.25, 0.95], [0.2, -0.65, 0.72]], t0: -0.35, t1: 0.3 }, // overhead
  4: { a0: [[-0.4, -0.85, 0.2], [-0.3, -0.75, 0.55]], a1: [[-0.25, -0.6, 0.75], [-0.05, -0.25, 0.96]], t0: -0.2, t1: 0.15 }, // soft forehand
  5: { a0: [[0.2, -0.85, 0.45], [0.6, -0.6, 0.5]], a1: [[-0.2, -0.6, 0.75], [-0.2, -0.2, 0.96]], t0: 0.25, t1: -0.15 },     // soft backhand
};
const easeOut = (t: number) => 1 - Math.pow(1 - t, 3);
const mixV = (a: V, b: V, t: number) => new THREE.Vector3(a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t).normalize();

export interface PoseInput { x: number; z: number; rot: number; speed: number; swingT: number; swingKind: number; prep: number; prepKind: number }

const TEAM_COLORS = [
  { body: 0xd9542a, joints: 0x18222c, paddle: 0x15304a },
  { body: 0xe0692e, joints: 0x18222c, paddle: 0x15304a },
  { body: 0xe8edf0, joints: 0x22406a, paddle: 0x3a2149 },
  { body: 0xc9d5dc, joints: 0x22406a, paddle: 0x3a2149 },
];

export class Character {
  root = new THREE.Group();
  private mixer: THREE.AnimationMixer;
  private actions: Record<string, THREE.AnimationAction> = {};
  private bones: Record<string, THREE.Bone> = {};
  paddle = new THREE.Group();
  private tmp = { a: new THREE.Vector3(), b: new THREE.Vector3(), c: new THREE.Vector3(), q1: new THREE.Quaternion(), q2: new THREE.Quaternion(), q3: new THREE.Quaternion() };

  constructor(source: THREE.Object3D, clips: THREE.AnimationClip[], idx: number, scene: THREE.Scene) {
    const model = SkeletonUtils.clone(source);
    model.scale.setScalar(3.18);
    const c = TEAM_COLORS[idx];
    model.traverse(o => {
      const m = o as THREE.SkinnedMesh;
      if (m.isMesh) {
        m.castShadow = true; m.frustumCulled = false;
        const mat = (m.material as THREE.MeshStandardMaterial).clone();
        const isJoint = /joint/i.test(mat.name);
        mat.color = new THREE.Color(isJoint ? c.joints : c.body);
        mat.roughness = isJoint ? 0.45 : 0.55; mat.metalness = isJoint ? 0.35 : 0.08;
        m.material = mat;
      }
      if ((o as THREE.Bone).isBone) this.bones[o.name.replace(/^mixamorig:?/, '')] = o as THREE.Bone;
    });
    this.root.add(model);
    scene.add(this.root);
    this.mixer = new THREE.AnimationMixer(model);
    for (const name of ['idle', 'walk', 'run']) {
      const clip = clips.find(k => k.name === name);
      if (!clip) continue;
      const a = this.mixer.clipAction(clip); a.play(); a.setEffectiveWeight(name === 'idle' ? 1 : 0); this.actions[name] = a;
    }
    // paddle: origin at the hand, long axis +y, face normal +z
    const M = (col: number, r = 0.5) => new THREE.MeshStandardMaterial({ color: col, roughness: r });
    const handle = new THREE.Mesh(new THREE.CylinderGeometry(0.07, 0.07, 0.5, 8), M(0x202326)); handle.position.y = 0.12;
    const face = new THREE.Mesh(new THREE.BoxGeometry(0.66, 0.84, 0.05), M(c.paddle, 0.35)); face.position.y = 0.78;
    const edge = new THREE.Mesh(new THREE.BoxGeometry(0.7, 0.88, 0.035), M(0x111417)); edge.position.y = 0.78;
    for (const m of [handle, face, edge]) { m.castShadow = true; this.paddle.add(m); }
    scene.add(this.paddle);
  }

  private aim(bone: THREE.Bone | undefined, child: THREE.Bone | undefined, dirWorld: THREE.Vector3) {
    if (!bone || !child || !bone.parent) return;
    const { a, b, q1, q2, q3 } = this.tmp;
    bone.getWorldPosition(a); child.getWorldPosition(b);
    const cur = b.sub(a).normalize();
    q1.setFromUnitVectors(cur, dirWorld);
    bone.parent.getWorldQuaternion(q2);
    bone.getWorldQuaternion(q3);
    q3.premultiply(q1);
    bone.quaternion.copy(q2.invert().multiply(q3));
    bone.updateMatrixWorld(true);
  }
  private twist(bone: THREE.Bone | undefined, angle: number) {
    if (!bone || !bone.parent) return;
    const { q1, q2, q3 } = this.tmp;
    q1.setFromAxisAngle(new THREE.Vector3(0, 1, 0), angle);
    bone.parent.getWorldQuaternion(q2); bone.getWorldQuaternion(q3);
    q3.premultiply(q1);
    bone.quaternion.copy(q2.invert().multiply(q3));
    bone.updateMatrixWorld(true);
  }

  update(p: PoseInput, dt: number) {
    this.root.position.set(p.x, 0, p.z);
    this.root.rotation.y = p.rot;
    const s = p.speed;
    const wRun = THREE.MathUtils.clamp((s - 5) / 4, 0, 1), wWalk = THREE.MathUtils.clamp(s / 3, 0, 1) * (1 - wRun), wIdle = 1 - Math.max(wRun, wWalk);
    this.actions.idle?.setEffectiveWeight(wIdle);
    if (this.actions.walk) { this.actions.walk.setEffectiveWeight(wWalk); this.actions.walk.timeScale = THREE.MathUtils.clamp(s / 4, 0.6, 1.6); }
    if (this.actions.run) { this.actions.run.setEffectiveWeight(wRun); this.actions.run.timeScale = THREE.MathUtils.clamp(s / 12, 0.7, 1.4); }
    this.mixer.update(dt);
    this.root.updateMatrixWorld(true);

    // paddle arm on top of the body animation
    let upper: THREE.Vector3, fore: THREE.Vector3, tw = 0;
    if (p.swingT >= 0) {
      const S = SWINGS[p.swingKind] || SWINGS[1], u = easeOut(p.swingT);
      upper = mixV(S.a0[0], S.a1[0], u); fore = mixV(S.a0[1], S.a1[1], u); tw = S.t0 + (S.t1 - S.t0) * u;
    } else if (p.prep > 0.001) {
      const S = SWINGS[p.prepKind] || SWINGS[1];
      upper = mixV(READY[0], S.a0[0], p.prep); fore = mixV(READY[1], S.a0[1], p.prep); tw = S.t0 * p.prep;
    } else { upper = mixV(READY[0], READY[0], 0); fore = mixV(READY[1], READY[1], 0); }
    const toWorld = this.root.quaternion;
    this.twist(this.bones.Spine1, tw);
    this.aim(this.bones.RightArm, this.bones.RightForeArm, upper.applyQuaternion(toWorld));
    this.aim(this.bones.RightForeArm, this.bones.RightHand, fore.clone().applyQuaternion(toWorld));

    // paddle follows the hand, face turned toward where the player is looking
    const { a, b, c, q1, q2 } = this.tmp;
    const hand = this.bones.RightHand, fa = this.bones.RightForeArm;
    if (hand && fa) {
      hand.getWorldPosition(a); fa.getWorldPosition(b);
      const D = c.copy(a).sub(b).normalize();
      this.paddle.position.copy(a);
      q1.setFromUnitVectors(new THREE.Vector3(0, 1, 0), D);
      const z1 = new THREE.Vector3(0, 0, 1).applyQuaternion(q1);
      const f = new THREE.Vector3(0, 0, 1).applyQuaternion(toWorld);
      f.addScaledVector(D, -f.dot(D)).normalize();
      const ang = Math.atan2(D.dot(new THREE.Vector3().crossVectors(z1, f)), z1.dot(f));
      q2.setFromAxisAngle(D, ang);
      this.paddle.quaternion.copy(q2.multiply(q1));
    }
  }
}

export async function loadCharacters(url: string, scene: THREE.Scene): Promise<Character[]> {
  const gltf = await new GLTFLoader().parseAsync(await fetchBinary(url), '');
  return [0, 1, 2, 3].map(i => new Character(gltf.scene, gltf.animations, i, scene));
}
