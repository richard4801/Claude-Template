// The server render's sound (render parity, audio): every clip's gain over time as model.ts audioEnvelope gives it
// (fades, volume keyframes, transition crossfades, ducking), voice effects as audio.ts voiceChain, project mute.
// Real ffmpeg renders of tones, checked by their loudness in windows.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import * as M from '../src/editor/model.js';
import { envExpr, renderProject } from '../src/editor/render.js';
import { probe } from '../src/replicate/media.js';
import { ENC, ff, hasFfmpeg } from './recreate-fixture.js';
import { rms } from './render-helpers.js';

describe('gain envelopes as expressions (unit)', () => {
  it('a flat sum of the non-silent spans, exact at the corners', () => {
    const env: M.GainPoint[] = [{ t: 1, gain: 0 }, { t: 2, gain: 1 }, { t: 3, gain: 1 }, { t: 4, gain: 0.5 }];
    const e = envExpr(env);
    const at = (t: number) => Function('t', `const between=(x,a,b)=>+(x>=a&&x<=b),lt=(a,b)=>+(a<b),eq=(a,b)=>+(a===b);return ${e};`)(t) as number;
    expect(at(0.5)).toBe(0); expect(at(1.5)).toBeCloseTo(0.5); expect(at(2)).toBeCloseTo(1); expect(at(2.5)).toBeCloseTo(1);
    expect(at(3.5)).toBeCloseTo(0.75); expect(at(4)).toBeCloseTo(0.5); expect(at(5)).toBe(0);
  });
});

describe.skipIf(!hasFfmpeg)('render sound (ffmpeg)', () => {
  let dir: string;
  const files: Record<string, string> = {};
  beforeAll(() => {
    dir = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-render-audio-'));
    files.a = path.join(dir, 'a.mp4'); // red picture, a 440 Hz tone
    ff('-f', 'lavfi', '-i', 'color=c=red:s=180x320:r=30:d=4', '-f', 'lavfi', '-i', 'sine=frequency=440:duration=4', '-shortest', ...ENC, '-c:a', 'aac', files.a);
    files.q = path.join(dir, 'q.mp4'); // blue picture, no sound
    ff('-f', 'lavfi', '-i', 'color=c=blue:s=180x320:r=30:d=4', ...ENC, files.q);
    files.m = path.join(dir, 'm.m4a'); // a 220 Hz bed
    ff('-f', 'lavfi', '-i', 'sine=frequency=220:duration=6', '-c:a', 'aac', files.m);
    files.v = path.join(dir, 'v.m4a'); // a low 100 Hz "voice"
    ff('-f', 'lavfi', '-i', 'sine=frequency=100:duration=3', '-c:a', 'aac', files.v);
  });
  afterAll(() => fs.rmSync(dir, { recursive: true, force: true }));

  const project = (): M.EditProject => ({
    version: 2, sourceTakeId: 'ta', canvas: { width: 360, height: 640, fps: 30, background: '#000000' },
    assets: [{ id: 'a', kind: 'video', take: 'ta', durationSec: 4 }, { id: 'q', kind: 'video', take: 'tq', durationSec: 4 },
      { id: 'm', kind: 'audio', upload: 'up_m', durationSec: 6 }, { id: 'v', kind: 'audio', upload: 'up_v', durationSec: 3 }],
    tracks: [{ id: 'main', kind: 'main', items: [{ id: 'c1', asset: 'q', inSec: 0, outSec: 4, speed: 1 } as M.VideoClip] }],
  });
  const render = async (p: M.EditProject, name: string) => {
    M.validate(p);
    const out = path.join(dir, `${name}.mp4`);
    const r = await renderProject({ ffmpeg: 'ffmpeg', ffprobe: 'ffprobe' }, p, files, out, { maxSide: 320 });
    return { out, r };
  };
  const music = (extra: Partial<M.AudioClip> = {}, track: Partial<M.Track> = {}): M.Track =>
    ({ id: 'mus', kind: 'music', items: [{ id: 'mu', asset: 'm', startSec: 0, inSec: 0, outSec: 4, ...extra } as M.AudioClip], ...track });

  it('fades in and out on a music clip; volume keyframes', async () => {
    const p = project();
    p.tracks.push(music({ fadeInSec: 1, fadeOutSec: 1 }));
    const { out, r } = await render(p, 'fades');
    expect(r.unsupported).toEqual([]);
    const full = rms(out, 1.5, 2.5);
    expect(full).toBeGreaterThan(0.05);
    expect(rms(out, 0, 0.2)).toBeLessThan(full * 0.25); // fading in
    expect(rms(out, 3.8, 4)).toBeLessThan(full * 0.25); // fading out
    expect(rms(out, 0.4, 0.6)).toBeGreaterThan(full * 0.35); expect(rms(out, 0.4, 0.6)).toBeLessThan(full * 0.65); // half-way

    const k = project();
    k.tracks.push(music({ keyframes: { volume: [{ t: 0, v: 1 }, { t: 3, v: 0.1 }] } }));
    const kr = await render(k, 'volkeys');
    expect(kr.r.unsupported).toEqual([]);
    expect(rms(kr.out, 3.3, 3.9)).toBeLessThan(rms(kr.out, 0, 0.5) * 0.2);
  }, 60_000);

  it('a transition crossfades the clips\' sound; a clip\'s own fade out', async () => {
    const p = project();
    p.tracks[0]!.items = [
      { id: 'c1', asset: 'a', inSec: 0, outSec: 2, speed: 1 } as M.VideoClip,
      { id: 'c2', asset: 'q', inSec: 0, outSec: 2, speed: 1, transitionIn: { kind: 'fade', durationSec: 1 } } as M.VideoClip, // silent
    ];
    const { out, r } = await render(p, 'xfade');
    expect(r.unsupported).toEqual([]);
    const before = rms(out, 0.3, 0.8);
    expect(before).toBeGreaterThan(0.05);
    const mid = rms(out, 1.4, 1.6); // half-way through the transition: half the gain
    expect(mid).toBeGreaterThan(before * 0.35); expect(mid).toBeLessThan(before * 0.65);
    expect(rms(out, 2.1, 2.5)).toBeLessThan(0.01);

    const f = project();
    f.tracks[0]!.items = [{ id: 'c1', asset: 'a', inSec: 0, outSec: 3, speed: 1, fadeOutSec: 2 } as M.VideoClip];
    const fr = await render(f, 'clipfade');
    expect(rms(fr.out, 2.7, 2.9)).toBeLessThan(rms(fr.out, 0.2, 0.6) * 0.25);
  }, 60_000);

  it('a speed curve\'s sound plays through to the clip\'s end (one stream, its tempo switched per piece)', async () => {
    const p = project();
    p.tracks[0]!.items = [{ id: 'c1', asset: 'a', inSec: 0, outSec: 3, speed: 1, speedCurve: { preset: 'bullet', points: M.SPEED_PRESETS.bullet } } as M.VideoClip,
      { id: 'c2', asset: 'q', inSec: 0, outSec: 1, speed: 1 } as M.VideoClip];
    const end = M.timeline(p)[0]!.endSec;
    const { out, r } = await render(p, 'curve');
    expect(r.unsupported).toEqual([]);
    expect(rms(out, 0.1, 0.4)).toBeGreaterThan(0.05);
    expect(rms(out, end - 0.25, end - 0.05)).toBeGreaterThan(0.05); // still heard at the end
    expect(rms(out, end + 0.15, end + 0.6)).toBeLessThan(0.01); // and not after
  }, 60_000);

  it('ducking: the bed dips under the voice track, back up after', async () => {
    const p = project();
    p.tracks.push(music({}, { duck: { level: 0.1, fadeSec: 0.2, under: ['voice'] } }));
    // The voice is there (it ducks the bed) but silent, so only the bed is heard.
    p.tracks.push({ id: 'voi', kind: 'voice', items: [{ id: 'vo', asset: 'v', startSec: 1.5, inSec: 0, outSec: 1, volume: 0 } as M.AudioClip] });
    const { out, r } = await render(p, 'duck');
    expect(r.unsupported).toEqual([]);
    const open = rms(out, 0.3, 1), ducked = rms(out, 1.8, 2.3), after = rms(out, 3, 3.8);
    expect(ducked).toBeLessThan(open * 0.2);
    expect(after).toBeGreaterThan(open * 0.8);
  }, 60_000);

  it('voice effects and enhance: the apps\' filters (a phone voice loses its lows); project mute is silent', async () => {
    const plain = project(), phone = project();
    plain.tracks.push({ id: 'voi', kind: 'voice', items: [{ id: 'vo', asset: 'v', startSec: 0, inSec: 0, outSec: 3 } as M.AudioClip] });
    phone.tracks.push({ id: 'voi', kind: 'voice', items: [{ id: 'vo', asset: 'v', startSec: 0, inSec: 0, outSec: 3, voiceEffect: 'phone', enhance: true } as M.AudioClip] });
    const a = await render(plain, 'voice-plain'), b = await render(phone, 'voice-phone');
    expect(b.r.unsupported).toEqual([]);
    expect(rms(b.out, 0.5, 2.5)).toBeLessThan(rms(a.out, 0.5, 2.5) * 0.1); // 100 Hz through 300 Hz high-passes

    const m = project();
    m.tracks[0]!.items = [{ id: 'c1', asset: 'a', inSec: 0, outSec: 3, speed: 1 } as M.VideoClip];
    m.tracks.push(music());
    m.mute = true;
    const mr = await render(m, 'mute');
    const info = await probe('ffprobe', mr.out);
    expect(info.audioCodec ? rms(mr.out, 0, 2.5) : 0).toBeLessThan(0.001);
  }, 60_000);
});
