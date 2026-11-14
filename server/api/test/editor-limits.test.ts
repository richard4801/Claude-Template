// ci_69fbeae442df: apply_edit_ops refused the owner's real project ("assets: must be a list of at most 60"): 67 main
// clips plus 16 overlays, each its own upload. The asset limit is now 400 (the Mac and Android validators mirror it:
// plans/patches/edit-limits-{mac,android}.patch).
import { describe, expect, it } from 'vitest';
import * as M from '../src/editor/model.js';

function bigProject(mainClips: number, overlays: number): M.EditProject {
  const p = M.fromV1({ version: 1, sourceTakeId: 'take_big', sourceDurationSec: 10, segments: [{ inSec: 0, outSec: 1, speed: 1 }], mute: false }, { width: 1080, height: 1920, fps: 30 });
  const main = p.tracks[0]!;
  main.items = [];
  for (let i = 0; i < mainClips; i++) {
    p.assets.push({ id: `v${i}`, kind: 'video', upload: `up_${i}`, durationSec: 4, width: 1280, height: 720, hasAudio: true } as M.Asset);
    main.items.push({ id: `c${i}`, asset: `v${i}`, inSec: 0, outSec: 2, speed: 1 } as M.Track['items'][number]);
  }
  const ov: M.Track = { id: 'ov', kind: 'video', items: [] } as unknown as M.Track;
  for (let i = 0; i < overlays; i++) {
    p.assets.push({ id: `o${i}`, kind: 'video', upload: `upo_${i}`, durationSec: 3, width: 1280, height: 720, hasAudio: false } as M.Asset);
    ov.items.push({ id: `x${i}`, asset: `o${i}`, startSec: i * 3, inSec: 0, outSec: 2, speed: 1 } as M.Track['items'][number]);
  }
  p.tracks.push(ov);
  return p;
}

describe('edit project limits', () => {
  it('the owner\'s project shape (67 main clips + 16 overlays, 83 uploads) validates', () => {
    expect(M.LIMITS.maxAssets).toBeGreaterThanOrEqual(400);
    const p = bigProject(67, 16);
    expect(p.assets.length).toBe(84);
    expect(() => M.validate(p)).not.toThrow();
  });
  it('per-track and total item limits are well above that', () => {
    expect(M.LIMITS.maxItemsPerTrack).toBeGreaterThanOrEqual(300);
    expect(M.LIMITS.maxItems).toBeGreaterThanOrEqual(600);
    expect(M.LIMITS.maxAssets).toBeGreaterThanOrEqual(60);
  });
  it('past the limit it still says so plainly', () => {
    const p = bigProject(M.LIMITS.maxAssets, 1);
    expect(() => M.validate(p)).toThrow(/edits\.assets: must be a list of at most 400/);
  });
});
