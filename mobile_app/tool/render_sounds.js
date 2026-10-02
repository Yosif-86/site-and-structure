// Renders the sign-in screen's sound effects to WAV (assets/sounds/).
// Same score as handoff-files/ARC-Login-Blueprint.html, synthesized offline
// so the app ships two small files instead of an audio engine.
// Run: node tool/render_sounds.js
const fs = require('fs');
const path = require('path');
const SR = 44100;

function render(seconds, score, peakTarget) {
  const N = Math.ceil(seconds * SR);
  const buf = new Float32Array(N);
  let seed = 1234567;
  const rnd = () => ((seed = (seed * 1103515245 + 12345) >>> 0) / 4294967296) * 2 - 1;

  const env = (i0, a, dec, peak, i) => {
    const t = (i - i0) / SR;
    if (t < 0) return 0;
    if (t < a) return 0.0001 * Math.pow(peak / 0.0001, t / a);
    const td = t - a;
    if (td > dec) return 0;
    return peak * Math.pow(0.0001 / peak, td / dec);
  };

  const tone = (t, f, o = {}) => {
    const a = o.a ?? 0.005, dec = o.dec ?? 0.6, peak = o.peak ?? 0.05;
    const glide = o.glide ?? 0.1, to = o.to, type = o.type || 'sine';
    const i0 = Math.round(t * SR), i1 = Math.min(N, i0 + Math.ceil((a + dec) * SR));
    let ph = 0;
    for (let i = i0; i < i1; i++) {
      const tt = (i - i0) / SR;
      const fr = to ? (tt < glide ? f * Math.pow(to / f, tt / glide) : to) : f;
      ph += (2 * Math.PI * fr) / SR;
      const s = type === 'triangle' ? (2 / Math.PI) * Math.asin(Math.sin(ph)) : Math.sin(ph);
      buf[i] += s * env(i0, a, dec, peak, i);
    }
  };

  // RBJ biquad on white noise, cutoff swept exponentially f -> f2.
  const noise = (t, dur, o = {}) => {
    const type = o.type || 'bandpass', q = o.q ?? 1, f = o.f ?? 1000, f2 = o.f2 ?? f;
    const peak = o.peak ?? 0.05, a = o.a ?? 0.01;
    const i0 = Math.round(t * SR), i1 = Math.min(N, i0 + Math.ceil(dur * SR));
    let x1 = 0, x2 = 0, y1 = 0, y2 = 0, b0, b1, b2, a1, a2;
    for (let i = i0; i < i1; i++) {
      if ((i - i0) % 32 === 0) {
        const tt = (i - i0) / SR;
        const fc = f * Math.pow(f2 / f, Math.min(1, tt / dur));
        const w = (2 * Math.PI * fc) / SR, cs = Math.cos(w), al = Math.sin(w) / (2 * q);
        let B0, B1, B2;
        if (type === 'lowpass') { B0 = (1 - cs) / 2; B1 = 1 - cs; B2 = (1 - cs) / 2; }
        else if (type === 'highpass') { B0 = (1 + cs) / 2; B1 = -(1 + cs); B2 = (1 + cs) / 2; }
        else { B0 = al; B1 = 0; B2 = -al; }
        const A0 = 1 + al;
        b0 = B0 / A0; b1 = B1 / A0; b2 = B2 / A0; a1 = (-2 * cs) / A0; a2 = (1 - al) / A0;
      }
      const x = rnd();
      const y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2;
      x2 = x1; x1 = x; y2 = y1; y1 = y;
      const tt = (i - i0) / SR;
      const g = tt < a ? 0.0001 * Math.pow(peak / 0.0001, tt / a) : peak * Math.pow(0.0001 / peak, (tt - a) / Math.max(0.001, dur - a));
      buf[i] += y * g;
    }
  };

  score({ tone, noise, rnd });

  // Small Schroeder room (4 combs + 2 allpasses), mixed in at 30%.
  const wet = new Float32Array(N);
  for (const [d, g] of [[1557, 0.82], [1617, 0.81], [1491, 0.8], [1422, 0.79]]) {
    const line = new Float32Array(d); let k = 0, lp = 0;
    for (let i = 0; i < N; i++) {
      const out = line[k];
      lp = out * 0.6 + lp * 0.4;
      line[k] = buf[i] + lp * g;
      k = (k + 1) % d;
      wet[i] += out * 0.25;
    }
  }
  for (const d of [225, 556]) {
    const line = new Float32Array(d); let k = 0;
    for (let i = 0; i < N; i++) {
      const v = line[k], x = wet[i];
      const y = -x + v; line[k] = x + v * 0.5; k = (k + 1) % d; wet[i] = y;
    }
  }
  let max = 0;
  for (let i = 0; i < N; i++) { buf[i] = buf[i] + wet[i] * 0.3; max = Math.max(max, Math.abs(buf[i])); }
  const gain = peakTarget / max;
  const fade = Math.round(0.05 * SR);
  const pcm = Buffer.alloc(44 + N * 2);
  for (let i = 0; i < N; i++) {
    let s = Math.tanh(buf[i] * gain * 1.1) / Math.tanh(1.1);
    if (i > N - fade) s *= (N - i) / fade;
    pcm.writeInt16LE(Math.round(Math.max(-1, Math.min(1, s)) * 32767), 44 + i * 2);
  }
  pcm.write('RIFF', 0); pcm.writeUInt32LE(36 + N * 2, 4); pcm.write('WAVE', 8);
  pcm.write('fmt ', 12); pcm.writeUInt32LE(16, 16); pcm.writeUInt16LE(1, 20); pcm.writeUInt16LE(1, 22);
  pcm.writeUInt32LE(SR, 24); pcm.writeUInt32LE(SR * 2, 28); pcm.writeUInt16LE(2, 32); pcm.writeUInt16LE(16, 34);
  pcm.write('data', 36); pcm.writeUInt32LE(N * 2, 40);
  return pcm;
}

// Timeline (seconds) shared with lib/widgets/blueprint_logo.dart.
const GUIDES = [[0.35, 0.55], [0.55, 0.45], [0.72, 0.5], [0.9, 0.6], [1.08, 0.4], [1.22, 0.25]];
const FILL_AT = 1.9, FILL_DUR = 1.5, SETTLE = FILL_AT + FILL_DUR, TEXT_TRACE = 1.3, TEXT_POUR = 3.2, LIFT = 4.4;

const intro = render(7.2, ({ tone, noise, rnd }) => {
  const T = 0.02;
  noise(T, 1.8, { type: 'lowpass', f: 500, peak: 0.03, a: 0.8 });
  for (const [at, dur] of GUIDES) {
    noise(T + at, 0.03, { type: 'highpass', f: 2500, peak: 0.06, a: 0.002 });
    noise(T + at + 0.02, dur * 0.8, { f: 4200, f2: 3000, q: 2, peak: 0.011, a: 0.05 });
  }
  tone(T + 1.35, 1568, { peak: 0.011, dec: 0.15 });
  noise(T + TEXT_TRACE, 0.8, { f: 3800, f2: 2800, q: 2, peak: 0.009, a: 0.05 });
  noise(T + TEXT_TRACE + 0.2, 0.9, { f: 3400, f2: 2600, q: 2, peak: 0.008, a: 0.05 });
  for (const [d, f] of [[1.5, 1200], [1.62, 900], [1.76, 1200]]) tone(T + d, f, { peak: 0.018, dec: 0.05 });
  tone(T + FILL_AT, 150, { to: 440, glide: FILL_DUR, a: 0.4, dec: 1.4, peak: 0.032 });
  tone(T + FILL_AT, 300, { to: 880, glide: FILL_DUR, a: 0.4, dec: 1.4, peak: 0.01 });
  for (let bt = FILL_AT + 0.05; bt < SETTLE - 0.05; bt += 0.06 + ((rnd() + 1) / 2) * 0.12) {
    const f = 300 + ((rnd() + 1) / 2) * 500 + (bt - FILL_AT) * 250;
    tone(T + bt, f, { to: f * 1.9, glide: 0.06, peak: 0.016, a: 0.004, dec: 0.07 });
  }
  [587.33, 659.25, 880, 987.77, 1174.66, 1318.51].forEach((f, i) =>
    tone(T + TEXT_POUR + 0.05 + i * 0.1, f, { peak: 0.011, dec: 0.5 }));
  [146.83, 293.66, 369.99, 440, 554.37].forEach((f, i) =>
    tone(T + SETTLE, f, { peak: i ? 0.026 : 0.03, a: 0.06, dec: 3.2 }));
  noise(T + LIFT + 0.05, 0.6, { f: 900, f2: 2200, q: 0.8, peak: 0.02, a: 0.25 });
}, 0.5);

const tap = render(0.35, ({ tone, noise }) => {
  tone(0.005, 520, { to: 380, glide: 0.08, peak: 0.05, dec: 0.12 });
  noise(0.005, 0.025, { type: 'highpass', f: 3000, peak: 0.04, a: 0.002 });
}, 0.35);

const out = path.join(__dirname, '..', 'assets', 'sounds');
fs.mkdirSync(out, { recursive: true });
fs.writeFileSync(path.join(out, 'login_intro.wav'), intro);
fs.writeFileSync(path.join(out, 'tap.wav'), tap);
console.log('login_intro.wav', intro.length, 'bytes; tap.wav', tap.length, 'bytes');
