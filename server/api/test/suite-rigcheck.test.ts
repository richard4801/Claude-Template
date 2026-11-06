// Rig check (workstream 3, plans/video-composer.md "Rig check"): every rule, its one-tap fix applied as a merge patch
// clears it, nothing fires on sensible rigs, and the estimate / rig-check routes carry it. Mock provider, no money.
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { CameraSpecSchema, PRESETS, type CameraSpecInput } from '../src/suite/camera.js';
import { promptWords, rigCheck, type RigInput } from '../src/suite/rigcheck.js';
import { demoModel, makeApp, people, type Client } from './helpers.js';

const camera = (c: CameraSpecInput) => CameraSpecSchema.parse(c);
const check = (c: CameraSpecInput, o: Omit<RigInput, 'camera'> = {}) => rigCheck({ camera: camera(c), ...o });
const ids = (w: ReturnType<typeof rigCheck>) => w.map(x => x.id);
/** RFC 7386: objects merge, null removes, anything else replaces. */
function mergePatch(target: any, patch: any): any {
  if (patch === null || typeof patch !== 'object' || Array.isArray(patch)) return patch;
  const out = target && typeof target === 'object' && !Array.isArray(target) ? { ...target } : {};
  for (const [k, v] of Object.entries(patch)) { if (v === null) delete out[k]; else out[k] = mergePatch(out[k], v); }
  return out;
}
/** Applies a fix to the request and checks the same rule no longer fires. */
function cleared(shot: { prompt?: string; camera: CameraSpecInput; speaking?: boolean }, id: string, which: 'fix' | 'alt' = 'fix') {
  const w = rigCheck({ ...shot, camera: camera(shot.camera) }).find(x => x.id === id);
  expect(w, id).toBeTruthy();
  const f = w![which];
  expect(f, `${id} ${which}`).toBeTruthy();
  const next = mergePatch(shot, f!.patch);
  expect(ids(rigCheck({ ...next, camera: camera(next.camera) })), `${id} after ${f!.label}`).not.toContain(id);
  return w!;
}

describe('rig check · rules', () => {
  it('deep-focus cameras: a rack focus or a shallow aperture won’t show; Cinema camera or dropping the rack fixes it', () => {
    for (const body of ['camcorder', 'phone', 'webcam', 'security_cam']) {
      const w = cleared({ camera: { rig: { body }, move: { id: 'rack_focus' } } }, 'deep_focus');
      expect(w.reason).toMatch(/keeps everything in focus, so the rack focus won’t show$/);
      expect(w.fix.label).toBe('Use Cinema camera');
      cleared({ camera: { rig: { body }, move: { id: 'rack_focus' } } }, 'deep_focus', 'alt');
    }
    expect(check({ rig: { body: 'camcorder' }, move: { id: 'rack_focus' } })[0]!.reason).toBe('DV camcorder keeps everything in focus, so the rack focus won’t show');
    for (const aperture of ['f1.2', 'f1.4', 'f2', 'f2.8']) {
      const w = cleared({ camera: { rig: { body: 'phone', aperture } } }, 'deep_focus');
      expect(w.reason).toMatch(/won’t blur the background/);
      cleared({ camera: { rig: { body: 'phone', aperture } } }, 'deep_focus', 'alt');
    }
    // A rack in the mix is dropped from the mix; a rack as the move with a mix promotes the mix.
    expect(check({ rig: { body: 'webcam' }, move: { id: 'handheld' }, mix: { id: 'rack_focus' } })[0]!.alt!.patch).toEqual({ camera: { mix: null } });
    expect(check({ rig: { body: 'webcam' }, move: { id: 'rack_focus' }, mix: { id: 'dolly_in' } })[0]!.alt!.patch).toMatchObject({ camera: { move: { id: 'dolly_in' }, mix: null } });
    expect(check({ rig: { body: 'cinema_digital', aperture: 'f1.4' }, move: { id: 'rack_focus' } })).toEqual([]);
    expect(check({ rig: { body: 'phone', aperture: 'f5.6' } })).toEqual([]);
  });

  it('a wide lens (≤ 24 mm) on a close-up distorts; 85mm or a medium shot fixes it (fisheye is on purpose)', () => {
    for (const focalMm of [14, 18, 24]) for (const shotSize of ['cu', 'ecu']) {
      const w = cleared({ camera: { rig: { focalMm }, angle: { shotSize } } }, 'wide_close');
      expect(w.reason).toBe(`A ${focalMm}mm lens this close stretches the face`);
      cleared({ camera: { rig: { focalMm }, angle: { shotSize } } }, 'wide_close', 'alt');
    }
    expect(check({ rig: { focalMm: 35 }, angle: { shotSize: 'cu' } })).toEqual([]);
    expect(check({ rig: { focalMm: 14 }, angle: { shotSize: 'ms' } })).toEqual([]);
    expect(check({ rig: { focalMm: 14, lens: 'fisheye' }, angle: { shotSize: 'cu' } })).toEqual([]);
  });

  it('worm’s-eye with a chest-up or closer framing', () => {
    for (const shotSize of ['mcu', 'cu', 'ecu']) {
      cleared({ camera: { angle: { height: 'worm', shotSize } } }, 'worm_close');
      cleared({ camera: { angle: { height: 'worm', shotSize } } }, 'worm_close', 'alt');
    }
    expect(check({ angle: { height: 'worm', shotSize: 'mcu' } })[0]!.reason).toBe('Worm’s-eye from the ground can’t frame a medium close-up');
    expect(check({ angle: { height: 'worm', shotSize: 'full' } })).toEqual([]);
    expect(check({ angle: { height: 'low', shotSize: 'mcu' } })).toEqual([]);
  });

  it('opposing looks: black and white against colour, warm against cold, saturated against muted', () => {
    const w = cleared({ camera: { rig: { look: 'bw_film' }, palette: { preset: 'hyper_neon' } } }, 'look_clash');
    expect(w).toMatchObject({ severity: 'tip', reason: 'Black & white film is black and white, so Hyper neon won’t show' });
    cleared({ camera: { rig: { look: 'bw_film' }, palette: { preset: 'hyper_neon' } } }, 'look_clash', 'alt');
    expect(check({ rig: { look: 'slide_film' }, palette: { preset: 'classic_bw' } })[0]!.reason).toBe('Classic B&W is black and white, so Slide film won’t show');
    expect(check({ rig: { look: 'tungsten_stock' }, palette: { preset: 'golden_warmth' } })[0]!.reason).toBe('Tungsten cinema stock and Golden warmth pull the colour opposite ways');
    expect(ids(check({ rig: { look: 'bleach_bypass' }, palette: { preset: 'candy_pop' } }))).toEqual(['look_clash']);
    // Agreeing or neutral pairs are fine.
    for (const [look, preset] of [['bw_film', 'classic_bw'], ['bw_film', 'sepia'], ['portrait_negative', 'golden_warmth'], ['digital_clean', 'hyper_neon'], ['tungsten_stock', 'moody_blue'], ['bleach_bypass', 'bleach_bypass']])
      expect(check({ rig: { look }, palette: { preset } }), `${look}+${preset}`).toEqual([]);
  });

  it('the prompt names a different move, angle or framing than the chips (keyword map)', () => {
    const w = cleared({ prompt: 'The camera pushes in on her face as she turns.', camera: { move: { id: 'orbit_right' } } }, 'prompt_move');
    expect(w).toMatchObject({ reason: 'The prompt says “pushes in” but the move is Orbit right', fix: { label: 'Use Dolly in' } });
    expect(ids(check({ move: { id: 'static' } }, { prompt: 'Slow pan left across the bar.' }))).toEqual(['prompt_move']);
    expect(ids(check({ move: { id: 'dolly_in' } }, { prompt: 'She runs; the drone follows her.' }))).toEqual(['prompt_move']);
    // Agreeing words, Auto (no move chosen), negations and the composer's own #tokens don't fire.
    expect(check({ move: { id: 'micro_push' } }, { prompt: 'A slow push in on her eyes.' })).toEqual([]);
    expect(check({}, { prompt: 'The camera pushes in.' })).toEqual([]);
    expect(check({ move: { id: 'static' } }, { prompt: 'No zoom, no pan left, she just smiles.' })).toEqual([]);
    expect(check({ move: { id: 'static' } }, { prompt: '#Dolly in She smiles.' })).toEqual([]);
    const a = cleared({ prompt: 'Low angle, looking up at her on the stairs.', camera: { angle: { height: 'high' } } }, 'prompt_angle');
    expect(a.reason).toBe('The prompt says “low angle” but the angle is High angle');
    expect(ids(check({ angle: { height: 'eye' } }, { prompt: 'A bird’s-eye view of the square.' }))).toEqual(['prompt_angle']);
    expect(check({ angle: { height: 'worm' } }, { prompt: 'Shot from below.' })).toEqual([]);
    const s = cleared({ prompt: 'A tight close-up of her hands.', camera: { angle: { shotSize: 'ls' } } }, 'prompt_size');
    expect(s.severity).toBe('tip');
  });

  it('"open on X / reveal" with a move that starts at the subject', () => {
    const w = cleared({ prompt: 'Open on the traffic below, then rise to find her on the balcony.', camera: { move: { id: 'crane_up' } } }, 'no_reveal');
    expect(w.reason).toBe('The prompt opens on something else, but Crane up starts at the subject');
    expect(w.fix.label).toMatch(/^Use (Rise to reveal|Tilt up)$/);
    expect(check({ move: { id: 'static' } }, { prompt: 'Reveal the empty room.' })[0]).toMatchObject({ id: 'no_reveal', fix: { label: 'Use Dolly out reveal' } });
    expect(check({ move: { id: 'dolly_out' } }, { prompt: 'Open on her face, then reveal the crowd.' })).toEqual([]);
    expect(check({ move: { id: 'static' }, mix: { id: 'pan_left' } }, { prompt: 'Reveal the room.' }).filter(x => x.id === 'no_reveal')).toEqual([]);
    // One "use this move" line, not two competing ones.
    expect(ids(check({ move: { id: 'crane_up' } }, { prompt: 'Open on the street and pull back to reveal the city.' }))).toEqual(['no_reveal']);
  });

  it('speaking shots with a move that isn’t talk-safe', () => {
    const w = cleared({ speaking: true, camera: { move: { id: 'orbit_left' } } }, 'talk_move');
    expect(w).toMatchObject({ reason: 'Orbit left can fight lip sync on a speaking shot', fix: { label: 'Lock it off' }, alt: { label: 'Handheld UGC' } });
    cleared({ speaking: true, camera: { move: { id: 'orbit_left' } } }, 'talk_move', 'alt');
    expect(check({ move: { id: 'handheld' }, mix: { id: 'dolly_in' } }, { speaking: true })[0]!.fix).toEqual({ label: 'Drop Dolly in', patch: { camera: { mix: null } } });
    for (const id of ['static', 'micro_push', 'handheld', 'selfie', 'rack_focus']) expect(check({ move: { id } }, { speaking: true }), id).toEqual([]);
    expect(check({ move: { id: 'orbit_left' } }, { speaking: false })).toEqual([]);
  });

  it('reads the preset underneath and the merged ids; the ready-made rigs are clean', () => {
    expect(ids(check({ preset: 'phone_ugc', rig: { aperture: 'f1.4' } }))).toEqual(['deep_focus']);
    expect(ids(check({ rig: { body: 'creator_cine', aperture: 'f1.4' } }))).toEqual([]);
    for (const p of PRESETS) expect(check({ preset: p.id as never }), p.id).toEqual([]);
    expect(rigCheck({})).toEqual([]);
    expect(rigCheck({ prompt: 'She smiles.' })).toEqual([]);
  });

  it('every line is short, member-safe and every fix is a patch on the camera', () => {
    const all = [
      ...check({ rig: { body: 'camcorder', aperture: 'f1.4', focalMm: 14, look: 'bw_film' }, palette: { preset: 'hyper_neon' }, angle: { height: 'worm', shotSize: 'cu' }, move: { id: 'crane_up' } },
        { prompt: 'Open on the street. Low angle wide shot.', speaking: true }),
    ];
    expect(ids(all).sort()).toEqual(['deep_focus', 'look_clash', 'no_reveal', 'prompt_size', 'talk_move', 'wide_close', 'worm_close'].sort());
    for (const w of all) {
      expect(w.reason.length, w.reason).toBeLessThanOrEqual(90);
      expect(Object.keys(w.fix.patch)).toEqual(['camera']);
      expect(() => CameraSpecSchema.partial().parse(mergePatch({}, w.fix.patch).camera)).not.toThrow();
    }
    expect(promptWords('#Rack focus and no tilt up')).not.toMatch(/rack focus|tilt up/);
  });
});

describe('rig check · routes (mock provider)', () => {
  let a: Awaited<ReturnType<typeof makeApp>>, owner: Client, member: Client, model: any;
  beforeAll(async () => {
    a = await makeApp({ SUITE_MODE: 'mock', SUITE_POLL_MS: '10' });
    ({ owner, members: [member] } = await people(a, 1, { topUp: 100 }) as any);
    model = await demoModel(owner);
  });
  afterAll(async () => { await a?.close(); });

  it('the estimate carries the rig check and stays OK (never blocks Generate)', async () => {
    const body = { modelId: model.id, prompt: 'Open on the traffic, then find her.', duration: 6, quality: 'hd', speaking: true,
      camera: { rig: { body: 'phone', aperture: 'f1.4' }, move: { id: 'crane_up' } } };
    const e = (await member.req('POST', '/v1/suite/shots/estimate', body)).body;
    expect(e.ok).toBe(true);
    expect(e.rig.map((w: any) => w.id)).toEqual(['deep_focus', 'no_reveal', 'talk_move']);
    expect(e.rig[0]).toMatchObject({ severity: 'warn', fix: { label: 'Use Cinema camera', patch: { camera: { rig: { body: 'cinema_digital' } } } } });
    const clean = (await member.req('POST', '/v1/suite/shots/estimate', { modelId: model.id, prompt: 'She waves.', duration: 6, quality: 'hd', camera: { preset: 'phone_ugc' } })).body;
    expect(clean.rig).toEqual([]);
  });

  it('POST /v1/suite/rig-check works without planning (no character, no engine)', async () => {
    const r = await member.req('POST', '/v1/suite/rig-check', { prompt: 'Pan left.', camera: { move: { id: 'static' }, rig: { focalMm: 18 }, angle: { shotSize: 'cu' } } });
    expect(r.status).toBe(200);
    expect(r.body.rig.map((w: any) => w.id)).toEqual(['wide_close', 'prompt_move']);
    expect((await member.req('POST', '/v1/suite/rig-check', { camera: { move: { id: 'nope' } } })).status).toBe(400);
    expect((await member.req('POST', '/v1/suite/rig-check', {})).body).toEqual({ rig: [] });
  });
});
