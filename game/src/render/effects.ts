// Post-processing: filmic tone mapping, a little bloom on the lights and ball, vignette, SMAA.
import * as THREE from 'three';
import { EffectComposer, RenderPass, EffectPass, BloomEffect, VignetteEffect, ToneMappingEffect, ToneMappingMode, SMAAEffect } from 'postprocessing';

export function createComposer(renderer: THREE.WebGLRenderer, scene: THREE.Scene, camera: THREE.PerspectiveCamera) {
  renderer.toneMapping = THREE.NoToneMapping;
  const composer = new EffectComposer(renderer, { frameBufferType: THREE.HalfFloatType });
  composer.addPass(new RenderPass(scene, camera));
  composer.addPass(new EffectPass(camera,
    new BloomEffect({ intensity: 0.3, luminanceThreshold: 0.95, luminanceSmoothing: 0.15, mipmapBlur: true }),
    new VignetteEffect({ offset: 0.32, darkness: 0.42 }),
    new ToneMappingEffect({ mode: ToneMappingMode.ACES_FILMIC }),
  ));
  composer.addPass(new EffectPass(camera, new SMAAEffect()));
  return composer;
}
