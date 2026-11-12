// The free schema walk for Genjutsu (Light's schema isn't published) against a fake that validates like Higgsfield:
// JSON Schema, ONE problem per answer, root problems (missing, unknown fields) first. Every body must be refused.
import { describe, expect, it } from 'vitest';
import { HiggsfieldProvider } from '../src/suite/providers.js';

type Schema = { required: string[]; additional: boolean; props: Record<string, { type: string; enum?: string[] }> };
const LIGHT: Schema = { required: ['video_url', 'image_urls'], additional: false,
  props: { video_url: { type: 'string' }, image_urls: { type: 'array' }, prompt: { type: 'string' }, resolution: { type: 'string', enum: ['480p', '720p', '1080p'] } } };

const typeOf = (v: unknown) => Array.isArray(v) ? 'array' : v === null ? 'null' : typeof v === 'number' ? (Number.isInteger(v) ? 'integer' : 'number') : typeof v;
function firstError(s: Schema, b: Record<string, unknown>): string | null {
  for (const r of s.required) if (!(r in b)) return `: '${r}' is a required property`;
  const extra = Object.keys(b).filter(k => !(k in s.props));
  if (!s.additional && extra.length) return `: Additional properties are not allowed ('${extra[0]}' was unexpected)`;
  for (const [k, p] of Object.entries(s.props)) {
    if (!(k in b)) continue;
    const t = typeOf(b[k]);
    if (!(t === p.type || (p.type === 'number' && t === 'integer'))) return `${k}: ${JSON.stringify(b[k])} is not of type '${p.type}'`;
    if (p.enum && !p.enum.includes(b[k] as string)) return `${k}: '${b[k]}' is not one of [${p.enum.map(e => `'${e}'`).join(', ')}]`;
  }
  return null;
}

function fake(s: Schema) {
  const sent: Record<string, unknown>[] = [];
  let accepted = 0, cancelled = 0;
  const f = (async (url: string, init?: RequestInit) => {
    if (String(url).endsWith('/cancel')) { cancelled++; return new Response('{}', { status: 200 }); }
    const b = JSON.parse(String(init?.body ?? '{}')) as Record<string, unknown>;
    sent.push(b);
    const e = firstError(s, b);
    if (e) return new Response(JSON.stringify({ detail: e }), { status: 400 });
    accepted++;
    return new Response(JSON.stringify({ status: 'queued', request_id: 'r', cancel_url: 'https://hf.test/requests/r/cancel' }), { status: 200 });
  }) as typeof fetch;
  return { f, sent, stats: () => ({ accepted, cancelled }) };
}
const ctx = { config: { HF_CREDENTIALS: 'id:secret', HIGGSFIELD_API_URL: 'https://hf.test' }, log: { warn() {} } } as never;

describe('Genjutsu schema walk (free: every body refused)', () => {
  it('learns the required fields, their types and that unknown fields are refused, without one body passing', async () => {
    const { f, sent, stats } = fake(LIGHT);
    const w = await new HiggsfieldProvider(ctx, f).probeSchema('higgsfield/genjutsu-light/motion-transfer/v1.0');
    expect(w.required).toEqual(['video_url', 'image_urls']);
    expect(w.additionalProperties).toBe(false);
    expect(w.types.video_url).toBe('string');
    expect(w.types.image_urls).toBe('array');
    expect(stats().accepted).toBe(0);
    expect(sent.every(b => firstError(LIGHT, b) !== null)).toBe(true);
    expect(sent.length).toBeLessThanOrEqual(16);
    expect(w.optional).toEqual({ prompt: 'accepted', resolution: 'accepted' });
    expect(JSON.stringify(sent)).not.toMatch(/https:\/\/(?!example\.invalid)/); // placeholders point nowhere
  });

  it('an optional field the model does not take is named as such', async () => {
    const noPrompt: Schema = { ...LIGHT, props: { video_url: { type: 'string' }, image_urls: { type: 'array' } } };
    const { f, stats } = fake(noPrompt);
    const w = await new HiggsfieldProvider(ctx, f).probeSchema('x');
    expect(w.optional).toEqual({ prompt: 'not accepted', resolution: 'not accepted' });
    expect(stats().accepted).toBe(0);
  });

  it('a schema with other names (reference_video, character_images) is learned the same way', async () => {
    const other: Schema = { required: ['reference_video', 'character_images'], additional: true,
      props: { reference_video: { type: 'string' }, character_images: { type: 'array' }, prompt: { type: 'string' } } };
    const { f, sent, stats } = fake(other);
    const w = await new HiggsfieldProvider(ctx, f).probeSchema('x');
    expect(w.required).toEqual(['reference_video', 'character_images']);
    expect(w.types).toMatchObject({ reference_video: 'string', character_images: 'array' });
    expect(stats().accepted).toBe(0);
    expect(sent.every(b => firstError(other, b) !== null)).toBe(true);
  });
});

describe('the clip Genjutsu gets', () => {
  it('a small silent clip gets a sound track and at least 409,600 pixels a frame', async () => {
    const { execFileSync } = await import('node:child_process');
    try { execFileSync('ffmpeg', ['-version']); } catch { return; }
    const fs = await import('node:fs'), os = await import('node:os'), path = await import('node:path');
    const { padTo, probe } = await import('../src/replicate/media.js');
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-gjclip-'));
    try {
      const src = path.join(dir, 'in.mp4'), out = path.join(dir, 'out.mp4');
      execFileSync('ffmpeg', ['-y', '-v', 'error', '-f', 'lavfi', '-i', 'testsrc=size=360x640:rate=24', '-t', '2.5', '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', '-an', src]);
      const info = await probe('ffprobe', src);
      expect(info.audioCodec).toBeNull();
      await padTo('ffmpeg', src, out, 4, info, { silentAudio: true, minPixels: 409_600 });
      const got = await probe('ffprobe', out);
      expect(got.audioCodec).toBe('aac');
      expect(got.width * got.height).toBeGreaterThanOrEqual(409_600);
      expect(got.width % 2 + got.height % 2).toBe(0);
      expect(Math.abs(got.duration - 4)).toBeLessThan(0.2);
    } finally { fs.rmSync(dir, { recursive: true, force: true }); }
  });
});
