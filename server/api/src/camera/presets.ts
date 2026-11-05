// Camera presets for list_presets. The AI suite (workstream 1) owns the real preset library; until it is merged this is
// the starting list from the research (plans/research/ai-video-suite-research.md §3.5), as Blender rig parameters.
import type { Ctx } from '../ctx.js';

export type CameraPreset = { id: string; kind: 'rig' | 'move' | 'angle'; label: string; params: Record<string, unknown> };

const P = (kind: CameraPreset['kind'], id: string, label: string, params: Record<string, unknown>): CameraPreset => ({ id, kind, label, params });

export const FALLBACK_PRESETS: CameraPreset[] = [
  P('rig', 'phone', 'Phone (UGC)', { focalMm: 26, aperture: 'f8', prompt: 'shot on a smartphone, deep focus, natural HDR' }),
  P('rig', 'cinema_digital', 'Cinema digital', { focalMm: 35, aperture: 'f2', prompt: 'clean digital cinema image, 35 mm lens, shallow depth of field' }),
  P('rig', 'film_35', 'Film 35 mm', { focalMm: 35, aperture: 'f2.8', prompt: '35 mm film grain, halation' }),
  P('rig', 'film_16', 'Film 16 mm', { focalMm: 25, aperture: 'f2.8', prompt: '16 mm film grain, soft halation' }),
  P('rig', 'camcorder', 'Camcorder', { focalMm: 30, aperture: 'f4', prompt: 'DV camcorder look, interlaced texture' }),
  P('move', 'static_ugc', 'Locked UGC talking head', { distanceM: [0.8, 1.0], heightAt: 'eye', focalMm: 26, pushM: [0.05, 0.1], notes: 'best for lipsync' }),
  P('move', 'handheld_ugc', 'Handheld UGC', { noiseLocM: [0.008, 0.015], noiseLocHz: [1.5, 3], noiseRotDeg: [0.4, 1.2], noiseRotHz: [0.8, 2], walkMs: [0.3, 0.6], focalMm: 25 }),
  P('move', 'selfie_walk', 'Selfie walk-and-talk', { distanceM: [0.5, 0.7], facing: 'back', armSwayM: [0.01, 0.02], walkMs: [1.0, 1.3], focalMm: 24 }),
  P('move', 'dolly_in', 'Dolly in (push)', { startM: 3.2, travelM: [0.8, 2.0], durationSec: [5, 7], ease: 'in_out', focalMm: 50 }),
  P('move', 'dolly_out', 'Dolly out reveal', { startM: 1.6, endM: [3.5, 5], durationSec: 6, ease: 'out', focalMm: 35 }),
  P('move', 'orbit', 'Orbit / arc', { radiusM: [1.8, 2.6], arcDeg: [60, 180], degPerSec: [15, 30], pivot: 'chest', focalMm: 35 }),
  P('move', 'crane_up', 'Crane up (jib)', { startHeightM: 0.6, riseM: [1.5, 3.5], distanceM: 2.5, durationSec: [5, 7], ease: 'out', focalMm: 28 }),
  P('move', 'tracking_follow', 'Tracking follow', { offset: 'behind 2 m or side 1.5 m', speedMs: [1.2, 1.5], focalMm: 35 }),
  P('move', 'fpv', 'FPV', { speedMs: [6, 12], heightM: [0.5, 4], bankDeg: [20, 35], focalMm: 15, durationSec: [4, 8] }),
  P('move', 'dutch_push', 'Dutch push', { rollDeg: [12, 20], pushM: 0.5, durationSec: [5, 6], focalMm: 35 }),
  P('move', 'rack_focus', 'Rack focus', { focusFromM: 0.8, focusToM: 2.5, atFraction: 0.4, pullSec: [0.6, 1.0], focalMm: 85, aperture: 'f1.4' }),
  P('move', 'whip_pan', 'Whip pan (editor transition)', { yawDeg: [70, 110], whipSec: [0.25, 0.35], notes: 'do as an editor transition between two shots' }),
  P('angle', 'eye', 'Eye level', { heightAt: 'eye', tiltDeg: 0 }),
  P('angle', 'low_hero', 'Low-angle hero', { heightM: [0.3, 0.5], tiltDeg: [15, 25] }),
  P('angle', 'high', 'High angle', { heightAboveEyeM: 0.8, tiltDeg: -20 }),
  P('angle', 'overhead', 'Top-down', { heightM: [3, 4], tiltDeg: -90 }),
  P('angle', 'ground', 'Ground level', { heightM: 0.1, tiltDeg: 5 }),
];

/** The suite's presets when its preset compiler is merged (ctx.suite.presets.list), otherwise the fallback list. */
export async function listPresets(ctx: Ctx, kind?: CameraPreset['kind']): Promise<CameraPreset[]> {
  const suite = (ctx as unknown as { suite?: { presets?: { list?: () => Promise<CameraPreset[]> | CameraPreset[] } } }).suite;
  let all = FALLBACK_PRESETS;
  if (typeof suite?.presets?.list === 'function') {
    try { all = await suite.presets.list(); } catch (e) { ctx.log.warn({ err: (e as Error).message }, 'suite presets failed, using the built-in list'); }
  }
  return kind ? all.filter(p => p.kind === kind) : all;
}
