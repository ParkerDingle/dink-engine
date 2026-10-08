// Synthesized paddle "pock" and bounce sounds (no audio files needed).
export class Sfx {
  private ctx: AudioContext | null = null;
  private noise: AudioBuffer | null = null;
  enabled = true;
  unlock() {
    if (!this.ctx) { try { this.ctx = new AudioContext(); } catch { this.ctx = null; } }
    if (this.ctx && this.ctx.state === 'suspended') this.ctx.resume();
    if (this.ctx && !this.noise) {
      this.noise = this.ctx.createBuffer(1, Math.floor(this.ctx.sampleRate * 0.12), this.ctx.sampleRate);
      const d = this.noise.getChannelData(0); for (let k = 0; k < d.length; k++) d[k] = Math.random() * 2 - 1;
    }
  }
  pock(strength = 1, pitch = 1) {
    const a = this.ctx; if (!a || !this.noise || !this.enabled) return;
    const t = a.currentTime;
    const src = a.createBufferSource(); src.buffer = this.noise;
    const bp = a.createBiquadFilter(); bp.type = 'bandpass'; bp.frequency.value = 1500 * pitch; bp.Q.value = 2.4;
    const g = a.createGain(); g.gain.setValueAtTime(0.0001, t); g.gain.exponentialRampToValueAtTime(0.5 * strength, t + 0.004); g.gain.exponentialRampToValueAtTime(0.0001, t + 0.07);
    src.connect(bp).connect(g).connect(a.destination); src.start(t); src.stop(t + 0.1);
    const o = a.createOscillator(); o.frequency.setValueAtTime(860 * pitch, t); o.frequency.exponentialRampToValueAtTime(480 * pitch, t + 0.05);
    const g2 = a.createGain(); g2.gain.setValueAtTime(0.0001, t); g2.gain.exponentialRampToValueAtTime(0.22 * strength, t + 0.003); g2.gain.exponentialRampToValueAtTime(0.0001, t + 0.07);
    o.connect(g2).connect(a.destination); o.start(t); o.stop(t + 0.09);
  }
}
