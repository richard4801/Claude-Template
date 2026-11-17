// Character is her on a model that takes no pictures of her: refused before any charge (owner 2026-11-17).
import { describe, expect, it } from 'vitest';
import { pickRemix, remixModels, pictureRoom } from '../src/suite/remix.js';
import { MODELS } from '../src/suite/registry.js';
import { routeOf } from '../src/suite/remix.js';

describe('New Swap: Character needs a model that can take her pictures', () => {
  const x = { character: { kind: 'model' as const, modelId: 'm_1' } } as any;
  const providers = new Set(MODELS.map(m => m.provider));
  const blind = MODELS.find(m => m.status !== 'removed' && routeOf(m) !== 'edit' && (routeOf(m) === 'text' || pictureRoom(m) === 0));
  it('a frames/words-only model is refused with the reason; edit models stay pickable', () => {
    expect(blind).toBeTruthy();
    const r = pickRemix(x, { providers, engineModel: blind!.id });
    expect(r).toMatchObject({ error: 'engine_unavailable' });
    expect((r as { message: string }).message).toMatch(/can’t put her in/);
    const list = remixModels(x, { providers });
    expect(list.find(c => c.model.id === blind!.id)!.unavailable).toMatch(/can’t put her in/);
    expect(list.find(c => c.model.id === 'genjutsu-light')!.unavailable).toBeNull();
  });
  it('without Character the same model is not refused for this', () => {
    const r = pickRemix({ outfit: { kind: 'words', words: 'a red dress' } } as any, { providers, engineModel: blind!.id });
    expect('error' in r ? r.message : '').not.toMatch(/can’t put her in/);
  });
});
