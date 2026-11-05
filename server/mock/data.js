// Seed data, identical to the prototype's `S` and android FakeMuseApi (SampleData).
const SLOT_SAMPLE = { face: 'face', profile: 'profile', front: 'g_front', tq: 'g_tq', side: 'g_side', back: 'g_back', faceTq: 'c_face' }; // faceTq: the 7th sheet image (plans/api.md "Model tools" §1)
export const SLOT_KEYS = Object.keys(SLOT_SAMPLE);
export { SLOT_SAMPLE };
const asset = a => ({ asset: a });
const req = (title, engine, steps, outfitId = 'o_green') => ({ title, modelId: 'm_demo', outfitId, clipId: 'clip_sample', engine, steps, use: 'first', takes: 1, keepAudio: true, lipSync: false, background: 'keep', backgroundMotion: 'subtle' });

export function seed(now = Date.now()) {
  return {
    models: [
      { id: 'm_demo', name: 'Demo model', age: 24, niche: 'Fashion', look: 'young woman, shoulder-length dark brown hair, brown eyes, light olive skin',
        neverAdd: ['tattoos', 'rings'], slots: SLOT_KEYS.map(k => ({ key: k, image: asset(SLOT_SAMPLE[k]), source: 'upload', busy: false })), outfitIds: ['o_green', 'o_crystal'] },
      { id: 'm_noor', name: 'Noor Ellis', age: 27, niche: 'Beauty', look: '', neverAdd: [], slots: SLOT_KEYS.map(k => ({ key: k, image: null, source: 'upload', busy: false })), outfitIds: [] },
    ],
    outfits: [
      { id: 'o_green', modelId: 'm_demo', name: 'Green set', mode: 'own', description: 'Dark green cropped tee and drawstring shorts', angles: ['g_front', 'g_tq', 'g_side', 'g_back'].map(asset), state: 'ready', prompt: '' },
      { id: 'o_crystal', modelId: 'm_demo', name: 'Crystal dress', mode: 'describe', description: 'Silver crystal cowl-neck mini dress', angles: ['c_front', 'c_tq', 'c_face', 'c_front'].map(asset), state: 'ready', prompt: '' },
    ],
    jobs: [
      { id: 'j1', title: 'Kick test', modelId: 'm_demo', modelName: 'Demo model', outfitId: 'o_green', request: req('Kick test', 'viggle', 4), state: 'done', progress: 100, take: 1, step: 4, totalSteps: 4,
        phase: 'Done', secondsLeft: 0, totalSeconds: 95, cost: 0.13, refunded: 0, createdAt: now - 7_200_000, finishedAt: now - 7_000_000, prompt: '', seed: 7, thumb: asset('g_front') },
      { id: 'j2', title: 'Bathroom trend', modelId: 'm_demo', modelName: 'Demo model', outfitId: 'o_crystal', request: req('Bathroom trend', 'h3', 30, 'o_crystal'), state: 'done', progress: 100, take: 1, step: 30, totalSteps: 30,
        phase: 'Done', secondsLeft: 0, totalSeconds: 2760, cost: 3.05, refunded: 0, createdAt: now - 86_400_000, finishedAt: now - 83_640_000, prompt: '', seed: 42, thumb: asset('c_front') },
      { id: 'j0', title: 'Mirror selfie', modelId: 'm_demo', modelName: 'Demo model', outfitId: 'o_green', request: req('Mirror selfie', 'h3', 10), state: 'failed', progress: 18, take: 1, step: 3, totalSteps: 10,
        phase: 'Failed at step 3', secondsLeft: 0, totalSeconds: 608, cost: 0.19, refunded: 0.19, error: 'The GPU disconnected at step 3.', createdAt: now - 3_600_000, prompt: '', seed: 42, thumb: asset('g_tq') },
    ],
    takes: [
      { id: 't_j1', kind: 'take', jobId: 'j1', index: 1, of: 1, title: 'Kick test', label: 'Fast · beta', engineLabel: 'Fast · beta', cost: 0.13, seed: 7, status: 'test', thumb: asset('g_front'), prompt: '', createdAt: now - 7_000_000 },
      { id: 't_j2', kind: 'take', jobId: 'j2', index: 1, of: 1, title: 'Bathroom trend', label: '30 steps', engineLabel: 'Standard · 30 steps', cost: 3.05, seed: 42, status: 'test', thumb: asset('c_front'), prompt: '', createdAt: now - 83_640_000 },
      { id: 't_g1', kind: 'take', jobId: null, index: 1, of: 1, title: 'Living-room dance', label: '10 steps', engineLabel: 'Standard · 10 steps', cost: 0.67, seed: 42, status: 'test', thumb: asset('g_tq'), prompt: '', createdAt: now - 90_000_000 },
      { id: 't_g5', kind: 'take', jobId: null, index: 1, of: 1, title: 'Living-room dance', label: '15 steps', engineLabel: 'Standard · 15 steps', cost: 0.99, seed: 42, status: 'test', thumb: asset('g_side'), prompt: '', createdAt: now - 95_000_000 },
      { id: 't_g4', kind: 'shot', jobId: null, index: 1, of: 1, title: 'Shoot', label: 'Shoot', engineLabel: '', cost: 0.03, seed: 0, status: 'test', thumb: asset('c_front'), prompt: '', createdAt: now - 96_000_000 },
      { id: 't_g6', kind: 'shot', jobId: null, index: 1, of: 1, title: 'Shoot', label: 'Shoot', engineLabel: '', cost: 0.03, seed: 0, status: 'test', thumb: asset('c_tq'), prompt: '', createdAt: now - 97_000_000 },
    ],
    balance: { balance: 6.07, month: 18.93, today: 0.13, perJobLimit: 5, perDayLimit: 15, videos: 11 },
    loras: {},
    accounts: {},
    posts: [],
    clips: {},
    uploads: {},
    failNext: false,
  };
}
