// Rapier physics layer: keeps players from walking through each other or the net posts, and takes
// over the ball once a rally is dead so it rolls, rattles the fence and bounces off players naturally.
// While a rally is live the ball stays on the deterministic ballistic model in sim/physics.ts so that
// shot planning and the simulation always agree. Everything here is optional: if WebAssembly is blocked,
// the game runs without it.
import type RAPIER_NS from '@dimforge/rapier3d-compat';
type R = typeof RAPIER_NS;
let RAPIER: R;
import { BALL_R, GRAV, NET_H, type Vec2, type Vec3 } from '../config';

export class PhysicsWorld {
  private world: RAPIER_NS.World;
  private controller: RAPIER_NS.KinematicCharacterController;
  private bodies: RAPIER_NS.RigidBody[] = [];
  private colliders: RAPIER_NS.Collider[] = [];
  private ballBody: RAPIER_NS.RigidBody | null = null;

  static async create(): Promise<PhysicsWorld | null> {
    try { RAPIER = (await import('@dimforge/rapier3d-compat')).default; await RAPIER.init(); return new PhysicsWorld(); }
    catch (e) { console.warn('Rapier unavailable, continuing without it', e); return null; }
  }

  private constructor() {
    const w = new RAPIER.World({ x: 0, y: -GRAV, z: 0 });
    this.world = w;
    const fixed = (hx: number, hy: number, hz: number, x: number, y: number, z: number, restitution = 0.3) => {
      const b = w.createRigidBody(RAPIER.RigidBodyDesc.fixed().setTranslation(x, y, z));
      w.createCollider(RAPIER.ColliderDesc.cuboid(hx, hy, hz).setRestitution(restitution).setFriction(0.6), b);
    };
    fixed(40, 0.5, 50, 0, -0.5, 0, 0.55);            // court surface
    fixed(0.1, 4, 32, -16, 4, 0); fixed(0.1, 4, 32, 16, 4, 0); fixed(16, 4, 0.1, 0, 4, -32); // fence
    fixed(11, NET_H / 2, 0.04, 0, NET_H / 2, 0, 0.05);  // net (soft)
    for (const x of [-11, 11]) {
      const b = w.createRigidBody(RAPIER.RigidBodyDesc.fixed().setTranslation(x, 1.55, 0));
      w.createCollider(RAPIER.ColliderDesc.cylinder(1.55, 0.13).setRestitution(0.5), b);
    }
    this.controller = w.createCharacterController(0.05);
    this.controller.setSlideEnabled(true);
    for (let i = 0; i < 4; i++) {
      const b = w.createRigidBody(RAPIER.RigidBodyDesc.kinematicPositionBased().setTranslation(0, 2.9, 22));
      const c = w.createCollider(RAPIER.ColliderDesc.capsule(1.9, 0.85).setRestitution(0.2), b);
      this.bodies.push(b); this.colliders.push(c);
    }
  }

  /** Place players exactly (start of a rally, replays). */
  teleport(players: Vec2[]) {
    players.forEach((p, i) => this.bodies[i].setTranslation({ x: p.x, y: 2.9, z: p.z }, true));
    this.world.propagateModifiedBodyPositionsToColliders();
  }

  /**
   * Resolve this frame's player movement against each other and the net posts.
   * `from` are last frame's resolved positions, `to` the positions the simulation wants.
   * Returns corrected positions.
   */
  resolvePlayers(from: Vec2[], to: Vec2[], dt: number): Vec2[] {
    const out: Vec2[] = [];
    for (let i = 0; i < 4; i++) {
      const d = { x: to[i].x - from[i].x, y: 0, z: to[i].z - from[i].z };
      this.controller.computeColliderMovement(this.colliders[i], d);
      const m = this.controller.computedMovement();
      const p = { x: from[i].x + m.x, z: from[i].z + m.z };
      this.bodies[i].setNextKinematicTranslation({ x: p.x, y: 2.9, z: p.z });
      out.push(p);
    }
    this.world.timestep = Math.min(Math.max(dt, 1 / 240), 1 / 30);
    this.world.step();
    return out;
  }

  /** Hand the ball to rigid-body physics after the rally ends. */
  releaseBall(p: Vec3, v: Vec3) {
    this.clearBall();
    const b = this.world.createRigidBody(
      RAPIER.RigidBodyDesc.dynamic().setTranslation(p.x, Math.max(p.y, BALL_R), p.z).setLinvel(v.x, v.y, v.z).setLinearDamping(0.25).setAngularDamping(0.6).setCcdEnabled(true),
    );
    this.world.createCollider(RAPIER.ColliderDesc.ball(BALL_R).setRestitution(0.62).setFriction(0.45).setDensity(0.6), b);
    this.ballBody = b;
  }
  ballPosition(): Vec3 | null {
    if (!this.ballBody) return null;
    const t = this.ballBody.translation();
    return { x: t.x, y: t.y, z: t.z };
  }
  clearBall() { if (this.ballBody) { this.world.removeRigidBody(this.ballBody); this.ballBody = null; } }
}
