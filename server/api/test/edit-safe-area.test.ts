// Edit's platform preview for Claude (plans/edit-platform-preview.md): the red box per view, captions and text outside it,
// and the view the app reports with its presence ping.
import fs from 'node:fs';
import path from 'node:path';
import { describe, expect, it } from 'vitest';
import * as M from '../src/editor/model.js';
import { applyOps } from '../src/editor/ops.js';
import { everyApp, newSafeIssues, previewOf, previewView, safeIssues, TITLE_SAFE, zoneFor } from '../src/editor/safeArea.js';
import { PREVIEW_LANDSCAPE, PREVIEW_ZONES, previewLayouts } from '../src/suite/previewLayouts.js';

const FIX = path.join(path.dirname(new URL(import.meta.url).pathname), 'fixtures/editor');
const projects = JSON.parse(fs.readFileSync(path.join(FIX, 'projects.json'), 'utf8')) as { name: string; project: M.EditProject }[];
const withCaptions = projects.find(p => p.name === 'captions pop 2')!.project;
// Captions at height y, wrapped no wider than 60 % of the frame (so only the height decides).
const capY = (p: M.EditProject, y: number, maxWidthPct = 0.6): M.EditProject =>
  ({ ...p, tracks: p.tracks.map(t => (t.caption ? { ...t, caption: { ...t.caption, style: { ...t.caption.style, y, maxWidthPct } } } : t)) });

describe('Edit safe area', () => {
  it('gives a box in every view: the app\'s own, every app\'s in Clean, title-safe in landscape Clean, none when off', () => {
    expect(zoneFor(withCaptions, { view: 'tiktok', safeArea: true })).toEqual(PREVIEW_ZONES.tiktok);
    expect(zoneFor(withCaptions, { view: 'clean', safeArea: true })).toEqual(everyApp());
    expect(everyApp()).toMatchObject({ top: 0.11, bottom: 0.3, right: 0.17 });
    const wide = { ...withCaptions, canvas: { ...withCaptions.canvas, width: 1920, height: 1080 } };
    expect(zoneFor(wide, { view: 'youtube', safeArea: true })).toEqual(PREVIEW_LANDSCAPE.youtube);
    expect(zoneFor(wide, { view: 'tiktok', safeArea: true })).toEqual(TITLE_SAFE); // TikTok on 16:9 shows as Clean
    expect(zoneFor(withCaptions, { view: 'tiktok', safeArea: false })).toBeNull();
    expect(previewLayouts().landscape).toEqual(PREVIEW_LANDSCAPE);
  });

  it('finds captions under TikTok\'s buttons, and not once they are moved up', () => {
    const low = capY(withCaptions, 0.85), z = PREVIEW_ZONES.tiktok;
    const found = safeIssues(low, z);
    expect(found[0]).toMatchObject({ kind: 'captions', edges: ['bottom'] });
    expect(found[0]!.toSec).toBeGreaterThan(found[0]!.fromSec);
    // Wide pages also reach under the right-hand buttons.
    expect(safeIssues(capY(withCaptions, 0.5, 0.95), z)[0]?.edges).toContain('right');
    expect(safeIssues(capY(withCaptions, 0.5), z)).toEqual([]);
    const v = previewView(low, { view: 'tiktok', safeArea: true });
    expect(v).toMatchObject({ view: 'tiktok', label: 'TikTok', safeBox: z, covers: "TikTok's caption and buttons" });
    expect((v as { unsafe: unknown[] }).unsafe).toHaveLength(1);
    expect(previewView(low, null)).toMatchObject({ view: null });
  });

  it('warns about what a change newly puts outside the box, with the line to say', () => {
    const p = capY(withCaptions, 0.5), pv = { view: 'tiktok' as const, safeArea: true };
    const moved = applyOps(p, [{ op: 'add_text', text: 'Wait for it', startSec: 0, durationSec: 2 } as never]).project;
    const id = moved.tracks.find(t => t.kind === 'text')!.items[0]!.id;
    const off = applyOps(moved, [{ op: 'transform', itemId: id, transform: { x: 0.92 } } as never]).project;
    const w = newSafeIssues(moved, off, pv)!;
    expect(w.issues).toEqual([expect.objectContaining({ kind: 'text', itemId: id, edges: ['right'] })]);
    expect(w.tell).toMatch(/A text now sit under TikTok's caption and buttons/);
    expect(newSafeIssues(off, off, pv)).toBeNull(); // nothing new
    expect(newSafeIssues(moved, off, null)).toBeNull(); // no app reported a view
    expect(newSafeIssues(moved, off, { view: 'tiktok', safeArea: false })).toBeNull();
  });

  it('reads the app\'s preview leniently', () => {
    expect(previewOf({ view: 'reels', safeArea: false })).toEqual({ view: 'reels', safeArea: false });
    expect(previewOf({ view: 'reels' })).toEqual({ view: 'reels', safeArea: true });
    expect(previewOf({ view: 'myspace' })).toBeNull();
    expect(previewOf(undefined)).toBeNull();
  });
});
