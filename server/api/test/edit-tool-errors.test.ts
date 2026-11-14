// apply_edit_ops errors Claude could not recover from (owner reports ci_a801154189c0, ci_2f7027203409, ci_b21886fc9e4c,
// ci_9e908e5947d3, ci_25ae7588d6c5): what Claude sends is read where it's reasonable, and each refusal names what to fix.
// (The stale-revision rebase, ci_437fd7d7d5db, is in editor-sessions.test.ts: it needs a session.)
import fs from 'node:fs';
import path from 'node:path';
import { describe, expect, it } from 'vitest';
import * as M from '../src/editor/model.js';
import { applyOps, type EditOp } from '../src/editor/ops.js';

const FIX = path.join(path.dirname(new URL(import.meta.url).pathname), 'fixtures/editor');
// main c1 (src 0–10) · video p1 (pip 0.5–5 at 1 s) · image i1 (0–2) · text t1 (0–3), t2 (3–7)
const base = (JSON.parse(fs.readFileSync(path.join(FIX, 'projects.json'), 'utf8')) as { project: M.EditProject }[])[8]!.project;
const run = (ops: EditOp[]) => applyOps(base, ops).project;
const problem = (p: M.EditProject) => { try { M.validate(p); return null; } catch (e) { return (e as Error).message; } };
const item = (p: M.EditProject, id: string) => p.tracks.flatMap(t => t.items).find(i => i.id === id) as M.TextItem & M.VideoClip;

describe('patch op (ci_a801154189c0)', () => {
  it('reads RFC 6902 move/copy/test and the usual near-misses', () => {
    expect(run([{ op: 'patch', patch: [{ op: 'Replace', path: 'canvas/background', value: '#111111' }] }]).canvas.background).toBe('#111111');
    expect(run([{ op: 'patch', patch: [{ op: 'set', path: 'tracks.1.items[0].opacity', value: 0.5 }] }]).tracks[1]!.items[0]).toMatchObject({ opacity: 0.5 });
    expect(run([{ op: 'patch', patch: { patch: [{ op: 'replace', path: ['tracks', 3, 'items', 0, 'text'], value: 'Hi' }] } }]).tracks[3]!.items[0]).toMatchObject({ text: 'Hi' });
    expect(run([{ op: 'patch', patch: [{ op: 'replace', path: '#/canvas/background', value: '#222222' }] }]).canvas.background).toBe('#222222');
    const t = run([{ op: 'patch', patch: [
      { op: 'test', path: '/tracks/3/items/1/id', value: 't2' },
      { op: 'copy', from: '/tracks/3/items/0/style', path: '/tracks/3/items/1/style' },
      { op: 'move', from: '/tracks/2/items/0/startSec', path: '/tracks/2/items/0/startSec' },
      { op: 'delete', path: '/tracks/1/items/0/fit' },
    ] }]);
    expect((t.tracks[3]!.items[1] as M.TextItem).style).toEqual((base.tracks[3]!.items[0] as M.TextItem).style);
    expect(problem(t)).toBeNull();
  });

  it('a bad operation is refused naming its index, op, path, and what is allowed', () => {
    expect(() => run([{ op: 'patch', patch: [{ op: 'replace', path: '/canvas/background', value: '#111111' }, { op: 'merge', path: '/canvas', value: {} }] }]))
      .toThrow(/^ops\.0\.patch\.patch\.1: "merge" at "\/canvas": unknown op · allowed: add, remove, replace .*move and copy .*test/);
    expect(() => run([{ op: 'patch', patch: [{ path: '/canvas/background', value: '#111111' }] }])).toThrow(/patch\.patch\.0: no op .*needs "op"/);
    expect(() => run([{ op: 'patch', patch: [{ op: 'replace', path: '/canvas/background' }] }])).toThrow(/patch\.patch\.0: "replace" .*needs "value"/);
    expect(() => run([{ op: 'patch', patch: [{ op: 'replace', path: '/tracks/9/items', value: [] }] }])).toThrow(/patch\.patch\.0: "replace" at "\/tracks\/9\/items": no \/tracks\/9\/items \(\/tracks\/9 doesn't exist; \/tracks is a list of 4\)/);
    expect(() => run([{ op: 'patch', patch: [{ op: 'replace', path: '/tracks/3/items/5/text', value: 'x' }] }])).toThrow(/\(\/tracks\/3\/items\/5 doesn't exist; \/tracks\/3\/items is a list of 2\)/);
    expect(() => run([{ op: 'patch', patch: [{ op: 'test', path: '/canvas/fps', value: 25 }] }])).toThrow(/test failed: it is 30, not 25/);
    expect(() => run([{ op: 'patch', patch: [{ op: 'move', path: '/canvas/x' }] }])).toThrow(/needs "from"/);
  });
});

describe('keyframe (ci_9e908e5947d3)', () => {
  it('"value" is read as v; a missing value says what v is with an example', () => {
    expect(item(run([{ op: 'keyframe', itemId: 'p1', prop: 'opacity', t: 1, value: 0.4 }]), 'p1').keyframes!.opacity).toEqual([{ t: 1, v: 0.4 }]);
    expect(() => run([{ op: 'keyframe', itemId: 'p1', prop: 'scale', t: 0.5 }])).toThrow(/^ops\.0\.keyframe\.v: required, the scale value at t \(e\.g\. \{"op":"keyframe","itemId":"p1","prop":"scale","t":0\.5,"v":1\.2\}\)/);
  });
});

describe('overlapping items (ci_2f7027203409)', () => {
  it('the refusal names both items with their times, the next one, and the nearest free startSec', () => {
    const p = run([{ op: 'patch', patch: [{ op: 'replace', path: '/tracks/3/items/1/startSec', value: 2.5 }] }]);
    expect(problem(p)).toBe('edits.tracks.3.items.1.startSec: items on a track must be in order and not overlap: t2 (2.5–6.5 s) starts 0.5 s before t1 (0–3 s) ends'
      + ' · nearest free startSec for t2 on this track: 3; or put it on another text track, shorten it, or send the op with "onOverlap":"fit" (nudge/shorten it into the gap) or "onOverlap":"ripple" (push later items on this track along)');
    const q = run([{ op: 'patch', patch: [{ op: 'replace', path: '/tracks/3/items/1/startSec', value: 0 }] }]);
    expect(problem(q)).toMatch(/t2 \(0–4 s\) is listed after t1 \(0–3 s\), which starts later|t2 \(0–4 s\) starts 3 s before t1/);
  });

  it('onOverlap fit nudges or shortens the changed item into its gap; ripple pushes later items along', () => {
    const a = run([{ op: 'add_text', text: 'X', startSec: 8, durationSec: 2 }]); // goes on the text track after t2 (3–7)
    const xId = a.tracks[3]!.items.find(i => (i as M.TextItem).text === 'X')!.id;
    // Moving t2 to 2.6 overlaps t1 by 0.4 s: fit starts it at 3.
    const fit = applyOps(base, [{ op: 'move', itemId: 't2', startSec: 2.6, onOverlap: 'fit' }]);
    expect(item(fit.project, 't2').startSec).toBe(3);
    expect(fit.labels[0]).toMatch(/fitted$/);
    expect(problem(fit.project)).toBeNull();
    // Lengthening t1 into t2 by 0.5 s: fit shortens it back; ripple pushes t2 (and X) on by 0.5 s.
    const f2 = applyOps(a, [{ op: 'edit_text', itemId: 't1', durationSec: 3.5, onOverlap: 'fit' }]).project;
    expect(item(f2, 't1').durationSec).toBe(3);
    const rp = applyOps(a, [{ op: 'edit_text', itemId: 't1', durationSec: 3.5, onOverlap: 'ripple' }]).project;
    expect([item(rp, 't1').durationSec, item(rp, 't2').startSec, item(rp, xId).startSec]).toEqual([3.5, 3.5, 8.5]);
    expect(problem(rp)).toBeNull();
    // A real clash (more than 1 s) is not fitted: the validator names it.
    expect(problem(applyOps(base, [{ op: 'move', itemId: 't2', startSec: 1, onOverlap: 'fit' }]).project)).toMatch(/nearest free startSec for t2 on this track: 3/);
    expect(() => applyOps(base, [{ op: 'move', itemId: 't2', startSec: 1, onOverlap: 'squash' }])).toThrow(/^ops\.0\.onOverlap: "fit" .* or "ripple"/);
  });
});

describe('clip too short (ci_b21886fc9e4c)', () => {
  it('names the clip, its in/out and the source length', () => {
    expect(problem(run([{ op: 'trim', clipId: 'p1', inSec: 4.95, outSec: 5 }]))).toBe('edits.tracks.1.items.0.outSec: a clip must keep at least 0.1 s of its source: p1 has inSec 4.95 and outSec 5 (0.05 s) of pip, 6 s long'
      + ' · inSec/outSec are source seconds (not timeline seconds); keep outSec ≥ inSec + 0.1, or delete the clip');
    expect(problem(run([{ op: 'trim', clipId: 'p1', outSec: 7 }]))).toMatch(/is past the end of its source: p1 has outSec 7 but pip, 6 s long/);
  });
});

describe('blend difference / exclusion (ci_25ae7588d6c5, ci_454cd1cd8ae7)', () => {
  it('the model computes them; they are gated until the apps can draw them', () => {
    expect(M.blendChannel('difference', 1, 0.25)).toBe(0.75);
    expect(M.blendChannel('exclusion', 1, 0.25)).toBe(0.75);
    expect(M.blendChannel('exclusion', 0.5, 0.5)).toBe(0.5);
    expect(M.ALL_BLEND_MODES).toEqual([...M.BLEND_MODES, ...(M.BLEND_NEXT_LIVE ? [] : ['difference', 'exclusion'])]);
    if (M.BLEND_NEXT_LIVE) return;
    expect(() => run([{ op: 'blend', itemId: 'p1', mode: 'difference' }])).toThrow(/blend\.mode: difference comes with the next app update/);
    expect(problem(run([{ op: 'patch', patch: [{ op: 'add', path: '/tracks/1/items/0/blend', value: 'exclusion' }] }]))).toMatch(/blend: exclusion comes with the next app update/);
    expect(() => run([{ op: 'blend', itemId: 'p1', mode: 'dissolve' }])).toThrow(/blend\.mode: one of normal, multiply/);
  });
});
