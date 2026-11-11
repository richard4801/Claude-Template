// One label per model, "<Model> · <Provider>" (owner 2026-11-11: "Make sure each provider has their name on their models
// so it doesn't mix up with each other"). engines/labels.ts builds it; the registry names carry no provider themselves.
import { describe, expect, it } from 'vitest';
import { baseName, labelList, modelLabel, providerLabel, relabelText } from '../src/engines/labels.js';
import { SWAP_ENGINES } from '../src/engines/purposes.js';
import { modelName } from '../src/suite/plan.js';
import { MODELS, modelById, modelView } from '../src/suite/registry.js';

describe('model labels', () => {
  it('"<Model> · <Provider>", with any old provider suffix taken out of the name', () => {
    expect(modelLabel('MiniMax H3', 'replicate')).toBe('MiniMax H3 · Replicate');
    expect(modelLabel('MiniMax H3 (Higgsfield)', 'higgsfield')).toBe('MiniMax H3 · Higgsfield');
    expect(modelLabel('MiniMax H3 · Higgsfield', 'higgsfield')).toBe('MiniMax H3 · Higgsfield');
    expect(modelLabel('SeedVR2 (own GPU)', 'runpod')).toBe('SeedVR2 · MUSE');
    expect(modelLabel('House Motion', 'muapi')).toBe('House Motion · Muapi');
    expect(modelLabel('Kling 4.0', null)).toBe('Kling 4.0');
    expect(baseName('Kling O1 Edit')).toBe('Kling O1 Edit');
    expect(baseName('Edit · MiniMax H3 open weights')).toBe('Edit · MiniMax H3 open weights');
    expect(providerLabel('assemblyai')).toBe('AssemblyAI');
    expect(providerLabel('fal')).toBe('fal');
  });

  it('no built-in name carries its provider; every built-in label is distinct', () => {
    for (const m of MODELS) expect(baseName(m.name), m.id).toBe(m.name);
    for (const e of SWAP_ENGINES) expect(baseName(e.name), e.id).toBe(e.name);
    const labels = MODELS.map(modelName);
    expect(new Set(labels).size).toBe(labels.length);
    expect(modelName(modelById('h3')!)).toBe('MiniMax H3 · Replicate');
    expect(modelName(modelById('h3-hf')!)).toBe('MiniMax H3 · Higgsfield');
    expect(modelName(modelById('h3-max-recast')!)).toBe('MiniMax H3 Max Recast · fal');
    expect(modelView(modelById('h3-hf')!)).toMatchObject({ name: 'MiniMax H3', label: 'MiniMax H3 · Higgsfield' });
  });

  it('a list never shows two models the same way', () => {
    const list = [
      { model: 'h3', name: 'MiniMax H3', provider: 'replicate' },
      { model: 'h3-hf', name: 'MiniMax H3 (Higgsfield)', provider: 'higgsfield' },
      { model: 'c_1', name: 'MiniMax H3', provider: 'replicate' }, // the owner's own Replicate key, same name
      { model: 'kling-v4', name: 'Kling 4.0', provider: 'replicate' },
    ];
    expect(labelList(list, { showProviders: true }).map(e => [e.name, e.label, e.providerName])).toEqual([
      ['MiniMax H3', 'MiniMax H3 · Replicate', 'Replicate'],
      ['MiniMax H3', 'MiniMax H3 · Higgsfield', 'Higgsfield'],
      ['MiniMax H3', 'MiniMax H3 · Replicate (2)', 'Replicate'],
      ['Kling 4.0', 'Kling 4.0 · Replicate', 'Replicate'],
    ]);
    // Provider names hidden from members (4c switch off): a neutral "Option n" instead of the same bare name twice.
    const hidden = labelList(list.map(({ provider: _p, ...e }) => e), { showProviders: false });
    expect(hidden.map(e => e.label)).toEqual(['MiniMax H3 · Option 1', 'MiniMax H3 · Option 2', 'MiniMax H3 · Option 3', 'Kling 4.0']);
    expect(hidden.every(e => e.name === e.label && !('providerName' in e))).toBe(true);
  });

  it('text written with full labels reads as the member sees the models', () => {
    const swaps = [{ from: 'MiniMax H3 · Replicate', to: 'MiniMax H3 · Option 1' }, { from: 'MiniMax H3 · Higgsfield', to: 'MiniMax H3 · Option 2' },
      { from: 'MiniMax H3 Lite · Replicate', to: 'MiniMax H3 Lite' }];
    expect(relabelText("Can't make this shot · MiniMax H3 · Higgsfield: needs 5–15 s. MiniMax H3 Lite · Replicate: no 2K", swaps))
      .toBe("Can't make this shot · MiniMax H3 · Option 2: needs 5–15 s. MiniMax H3 Lite: no 2K");
  });
});
