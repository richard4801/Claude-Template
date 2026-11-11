// AI suite · "adapt, don't block" (owner, 2026-11-11): the Camera stage's guide keyframes are hints, never hard frames;
// a picked model that can't take something MUSE can work around gets it adapted (and says so); a real refusal names
// each model's reasons in plain words. Pure planning: no app, no provider, no money.
import { describe, expect, it } from 'vitest';
import { adaptRequest, buildPlan, fit, needOf, pickAdapted, pickModel, refusalLine, ShotRequestSchema, type Character } from '../src/suite/plan.js';
import { modelById, type ProviderId } from '../src/suite/registry.js';

const CHAR: Character = { name: 'Mia', look: 'young woman, dark hair', neverAdd: [],
  images: [{ label: 'face, front', image: { asset: 'face' } }, { label: 'face, profile', image: { asset: 'profile' } }], outfit: null };
const ALL = new Set<ProviderId>(['replicate', 'fal', 'higgsfield', 'runpod', 'mock']);
const req = (o: Record<string, unknown> = {}) => ShotRequestSchema.parse({ prompt: 'She walks to the window.', ...o });
const CONSTRAINTS = 'CONSTRAINTS: keep her face and outfit exactly as in her images. No cuts. No text on screen. '.repeat(8);
/** The owner's case: a directed Camera-stage draft (blocking guide + start/mid/end stills), two moves, Cinema. */
const directed = (o: Record<string, unknown> = {}) => req({
  modelId: 'mia', prompt: `#Crane over the head #Tracking follow ${CONSTRAINTS}`, duration: 10, quality: 'cinema',
  camera: { mode: 'directed', move: { id: 'crane_overhead' }, mix: { id: 'follow' },
    guide: { video: { key: 'guides/g.mp4', seconds: 8 }, use: 'blocking', keyframes: { start: 'https://x/s.png', middle: ['https://x/m.png'], end: 'https://x/e.png' } } },
  ...o,
});
const planOn = (id: string, res: string, r: ReturnType<typeof req>) => {
  const p = pickModel('cinema', needOf(r, CHAR), { providers: ALL, engineModel: id, resolution: res });
  if ('error' in p) throw new Error(`${id}: ${JSON.stringify(p.tried)}`);
  return buildPlan(r, needOf(r, CHAR), p, CHAR, {});
};

describe('guide keyframes are hints, not hard frames', () => {
  it('a directed blocking draft with stills estimates on Seedance 2.0, Seedance 2.5, H3 and H3 (Higgsfield) at Cinema', () => {
    const r = directed();
    expect(needOf(r, CHAR)).toMatchObject({ mode: 'reference', start: false, end: false, middle: 0, guide: true, directed: true });
    for (const [id, res] of [['seedance-2.0', '1080p'], ['seedance-2.5', '720p'], ['h3', '2K'], ['h3-hf', '2K']] as const) {
      const plan = planOn(id, res, r);
      expect(plan.videos[0]?.video.key, id).toBe('guides/g.mp4'); // the blocking rides as the reference video
      expect(plan.images.refs.filter(x => x.role === 'character').length, id).toBeGreaterThan(0); // her look is kept
    }
  });
  it('H3 (Higgsfield): reference-to-video, the stills as reference images after hers, the prompt opens and ends on them', () => {
    const plan = planOn('h3-hf', '2K', directed());
    expect(plan.kind).toBe('ref2v');
    expect(plan.ref).toBe('minimax/h3/reference-to-video');
    expect(plan.images.refs.map(x => x.label)).toEqual(['face, front', 'face, profile', 'opening frame', 'end frame', 'middle frame 1']);
    expect(plan.prompt).toContain('Open on <Image 3>.');
    expect(plan.prompt).toContain('End like <Image 4>.');
    expect(plan.images.start).toBeUndefined();
  });
  it('Seedance (frames without references): the stills go as references, never as keyframes that would drop her images', () => {
    const plan = planOn('seedance-2.0', '1080p', directed());
    expect(plan.images.start).toBeUndefined();
    expect(plan.images.refs.some(x => x.label === 'opening frame')).toBe(true);
  });
  it('directed with only the guide clip (no character) on H3 (Higgsfield) uses reference-to-video', () => {
    const r = directed({ modelId: undefined });
    const p = pickModel('cinema', needOf(r, null), { providers: ALL, engineModel: 'h3-hf', resolution: '2K' });
    expect('error' in p).toBe(false);
    const plan = buildPlan(r, needOf(r, null), p as any, null, {});
    expect(plan.kind).toBe('ref2v');
    expect(plan.videos).toHaveLength(1);
  });
});

describe('adapt, don\'t block (a picked model)', () => {
  const pick = (id: string, r: ReturnType<typeof req>, res?: string) => pickAdapted('cinema', r, CHAR, { providers: ALL, engineModel: id, resolution: res });
  it('the person\'s own frames on H3 (Higgsfield) go as reference images, the opening frame first, and it says so', () => {
    const r = req({ modelId: 'mia', frames: { start: { url: 'https://x/a.png' }, end: { url: 'https://x/b.png' } } });
    expect(fit(modelById('h3-hf')!, '2K', needOf(r, CHAR)).why).toBe('no keyframes');
    const a = pick('h3-hf', r);
    if ('error' in a) throw new Error(JSON.stringify(a.refusals));
    expect(a.adapted.adapted).toContain('frames_as_refs');
    expect(a.adapted.notes.join(' ')).toMatch(/frames are sent as reference images/);
    const plan = buildPlan(a.adapted.request, a.adapted.need, a.pick, CHAR, {});
    expect(plan.images.refs.map(x => x.label)).toEqual(['face, front', 'face, profile', 'opening frame', 'end frame']);
    expect(plan.prompt).toMatch(/Open on <Image 3>\.[\s\S]*End like <Image 4>\./);
  });
  it('a length outside the range is clamped ("made 15 s, … max")', () => {
    const a = pick('h3-hf', req({ modelId: 'mia', duration: 20 }));
    if ('error' in a) throw new Error('refused');
    expect(a.pick.seconds).toBe(15);
    expect(a.adapted.notes).toContain('made 15 s, MiniMax H3 (Higgsfield) max');
    expect(a.adapted.adapted).toContain('length:15');
  });
  it('an aspect the model doesn\'t make moves to the nearest one', () => {
    const a = pickAdapted('hd', req({ aspectRatio: '3:4' }), null, { providers: ALL, engineModel: 'ltx-2.3', resolution: '2k' });
    if ('error' in a) throw new Error('refused');
    expect(a.adapted.request.aspectRatio).toBe('9:16');
    expect(a.adapted.notes[0]).toMatch(/made 9:16 \(LTX-2\.3 Pro doesn't make 3:4\)/);
  });
  it('too many reference images: the first ones are kept and the rest named as left out', () => {
    const m = modelById('wan-2.7')!; // 5 reference images
    const refs = Array.from({ length: 6 }, (_, i) => ({ image: { url: `https://x/${i}.png` }, role: 'product', label: `bottle ${i + 1}` }));
    const r = req({ modelId: 'mia', references: { images: refs } });
    const a = adaptRequest(m, m.resolutions[0]!.id, r, CHAR);
    expect(a.why).toEqual([]);
    expect(a.adapted).toContain('refs_trimmed');
    expect(a.notes.join(' ')).toBe('2 reference images left out (Wan 2.7 takes 5): bottle 5, bottle 6');
  });
});

describe('refusals say exactly why', () => {
  it('per-model reasons in plain words', () => {
    const r = req({ references: { audio: { audio: { url: 'https://x/a.mp3' } } } });
    const a = pickAdapted('hd', r, null, { providers: ALL, engineModel: 'veo-3.1-lite', resolution: '720p' });
    expect('error' in a).toBe(true);
    if (!('error' in a)) return;
    expect(refusalLine(a.refusals[0]!)).toBe("Veo 3.1 Lite: can't use an audio reference; needs an image or video with the audio reference");
  });
  it('a provider that isn\'t set up is said plainly', () => {
    const a = pickAdapted('hd', req(), null, { providers: new Set(['replicate']), engineModel: 'h3-hf' });
    if (!('error' in a)) throw new Error('should refuse');
    expect(refusalLine(a.refusals[0]!)).toBe('MiniMax H3 (Higgsfield): is not set up in this studio yet');
  });
});
