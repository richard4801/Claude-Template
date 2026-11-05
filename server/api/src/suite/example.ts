// AI suite · the whole prompt a suite library entry is part of, for the prompt editor's preview (prompt/service.ts exampleFor).
import type { PromptTexts } from '../prompt/library.js';
import type { CameraSpec } from './camera.js';
import { compileCamera } from './compile.js';
import { buildPlan, needOf, type Character, type ShotRequest } from './plan.js';
import { MODELS, modelById, type CameraVocab } from './registry.js';

const CAMERA: CameraSpec = { mode: 'preset', preset: 'cinematic', rig: { focalMm: 50, fps: '24', shutter: 'normal' }, mix: { id: 'crane_up', intensity: 0.4, speed: 'slow', ease: 'in_out' },
  angle: { height: 'low', shotSize: 'mcu', dutchDeg: 0 }, style: { genre: 'drama', era: '2020s', tempo: 'calm' }, performance: { emotion: 'hope', to: 'joy', atS: 3, intensity: 0.6 },
  palette: { preset: 'teal_orange' }, lighting: { preset: 'golden_hour', temperatureK: 3200 } };
const CHARACTER: Character = { name: 'Demo model', look: 'young woman, shoulder-length dark brown hair, brown eyes, light olive skin', neverAdd: ['tattoos', 'rings'],
  images: [{ label: 'face, front', image: { asset: 'face' } }, { label: 'face, profile', image: { asset: 'profile' } }, { label: 'body, front', image: { asset: 'g_front' } }],
  outfit: { name: 'Green set', images: [{ label: 'outfit, front', image: { asset: 'g_front' } }] } };

export function suiteExample(key: string, t: PromptTexts): string {
  const vocab = /^suite\.camera\.format\.(\w+)$/.exec(key)?.[1] as CameraVocab | undefined;
  const model = (vocab && MODELS.find(m => m.camera.vocab === vocab && m.status === 'active' && !m.licence.blockNewFeatures)) || modelById('kling-v4')!;
  if (key.startsWith('suite.camera.')) return compileCamera(CAMERA, model, { texts: t, durationS: 8 }).text || '(empty)';
  const req: ShotRequest = { prompt: 'She walks into the café, sees the camera and smiles.', duration: 8, aspectRatio: '9:16', quality: 'cinema', takes: 1, audio: true, speaking: false, camera: CAMERA,
    references: { images: [{ image: { asset: 'g_front' }, role: 'product', label: 'the perfume bottle' }] },
    ...(key === 'suite.shot.frames' ? { frames: { start: { asset: 'g_front' }, end: { asset: 'g_tq' } } } : {}),
    ...(key === 'suite.shot.guide' ? { camera: { ...CAMERA, guide: { video: { url: 'https://example.com/greybox.mp4' }, use: 'camera' } } } : {}) };
  const need = needOf(req, CHARACTER);
  const m = key === 'suite.shot.negative' ? modelById('wan-2.7')! : model;
  const plan = buildPlan(req, need, { model: m, resolution: m.resolutions.at(-1)!, seconds: 8, tried: [] }, CHARACTER, { texts: t });
  return key === 'suite.shot.negative' ? plan.negative ?? '' : plan.prompt;
}
