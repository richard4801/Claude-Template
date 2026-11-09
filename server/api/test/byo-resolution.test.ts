// Owner 2026-11-09: custom image models run at their largest size (a refused size steps down).
import { describe, expect, it } from 'vitest';
import { largestFirst, resolutionRank } from '../src/byo/service.js';

describe('custom image models: largest size first', () => {
  it('ranks K, p, MP and WxH sizes', () => {
    expect(resolutionRank('2K')).toBeGreaterThan(resolutionRank('1K'));
    expect(resolutionRank('4K')).toBeGreaterThan(resolutionRank('2K'));
    expect(resolutionRank('1080p')).toBeGreaterThan(resolutionRank('720p'));
    expect(resolutionRank('4 MP')).toBeGreaterThan(resolutionRank('1 MP'));
    expect(resolutionRank('2048x2048')).toBeGreaterThan(resolutionRank('1024x1024'));
    expect(resolutionRank('auto')).toBe(0);
  });
  it('orders the model sizes largest first; none when the owner fixed one or the model has no size', () => {
    const a = { map: { resolution: 'resolution' }, inputs: { resolutions: ['1K', '2K', 'auto'] } } as any;
    expect(largestFirst(a, {})).toEqual(['2K', '1K']);
    expect(largestFirst(a, { resolution: '1K' })).toEqual([]);
    expect(largestFirst({ map: {}, inputs: { resolutions: [] } } as any, {})).toEqual([]);
  });
});
