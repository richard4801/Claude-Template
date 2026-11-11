// Metadata cleanup (owner, 2026-11-09): stored videos lose every tag without re-encoding (rotation and colour kept,
// still decodes); photos lose EXIF/XMP/ICC with orientation baked in; MUSE's AI label only when switched on.
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import sharp from 'sharp';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { AI_LABEL_TEXT, cleanBuffer, cleanImageBuffer, cleanVideoFile } from '../src/storage/clean.js';
import { ff, hasFfmpeg } from './recreate-fixture.js';

const probe = (f: string) => JSON.parse(execFileSync('ffprobe', ['-v', 'error', '-show_entries',
  'format_tags:stream_tags:stream=codec_type,codec_name,color_primaries:stream_side_data=rotation:chapter', '-of', 'json', f]).toString());

let dir: string, clip: string;
beforeAll(() => {
  dir = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-meta-'));
  if (!hasFfmpeg) return;
  const a = path.join(dir, 'a.mp4'), chap = path.join(dir, 'chapters.txt');
  fs.writeFileSync(chap, ';FFMETADATA1\ntitle=prompt: a secret prompt\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=0\nEND=1000\ntitle=Provider chapter\n');
  ff('-f', 'lavfi', '-i', 'testsrc2=s=160x120:r=25:d=2', '-f', 'lavfi', '-i', 'sine=d=2', '-i', chap, '-map', '0', '-map', '1', '-map_metadata', '2', '-map_chapters', '2',
    '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', '-color_primaries', 'bt709', '-color_trc', 'bt709', '-colorspace', 'bt709', '-c:a', 'aac',
    '-metadata', 'comment=made by provider-x seed 42', '-metadata:s:v:0', 'handler_name=ProviderVideo', a);
  clip = path.join(dir, 'clip.mp4');
  ff('-display_rotation', '90', '-i', a, '-c', 'copy', '-map_chapters', '0', clip);
}, 60_000);
afterAll(() => fs.rmSync(dir, { recursive: true, force: true }));

describe.skipIf(!hasFfmpeg)('videos', () => {
  it('drops every tag and chapter without re-encoding; rotation and colour stay; it still decodes', async () => {
    const before = probe(clip);
    expect(before.format.tags.comment).toContain('provider-x');
    expect(before.chapters.length).toBe(1);
    const out = (await cleanVideoFile('ffmpeg', clip, 'video/mp4'))!;
    try {
      const p = probe(out), v = p.streams.find((s: any) => s.codec_type === 'video');
      const text = JSON.stringify(p) + fs.readFileSync(out).toString('latin1');
      expect(text).not.toMatch(/provider|secret|seed 42|Lavf/i);
      expect(p.chapters ?? []).toEqual([]);
      expect(p.format.tags?.comment).toBeUndefined();
      expect(v.codec_name).toBe('h264');
      expect(v.color_primaries).toBe('bt709');
      expect(v.side_data_list?.[0]?.rotation).toBe(90);
      expect(p.streams.map((s: any) => s.codec_type).sort()).toEqual(['audio', 'video']);
      execFileSync('ffmpeg', ['-v', 'error', '-i', out, '-f', 'null', '-']);
    } finally { fs.rmSync(out, { force: true }); }
  });

  it('adds MUSE\'s AI label only when it is switched on', async () => {
    const on = (await cleanVideoFile('ffmpeg', clip, 'video/mp4', { label: true }))!;
    const off = (await cleanVideoFile('ffmpeg', clip, 'video/mp4', { label: false }))!;
    try {
      expect(probe(on).format.tags.comment).toBe(AI_LABEL_TEXT);
      expect(probe(off).format.tags?.comment).toBeUndefined();
      expect(fs.readFileSync(off).toString('utf8')).not.toContain('MUSE');
    } finally { fs.rmSync(on, { force: true }); fs.rmSync(off, { force: true }); }
  });

  it('keeps the original when the bytes are not a video', async () => {
    const junk = Buffer.from('not a video');
    expect(await cleanBuffer('ffmpeg', junk, 'video/mp4')).toBe(junk);
  });
});

describe('photos', () => {
  it('re-saves without EXIF/XMP/ICC, orientation baked in', async () => {
    const raw = await sharp({ create: { width: 40, height: 20, channels: 3, background: '#c33' } })
      .withMetadata({ orientation: 6, exif: { IFD0: { Software: 'provider-x', ImageDescription: 'a secret prompt' } } })
      .withXmp('<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description>provider-x</rdf:Description></rdf:RDF></x:xmpmeta>')
      .jpeg().toBuffer();
    expect(raw.toString('latin1')).toContain('provider-x');
    const out = (await cleanImageBuffer(raw, 'image/jpeg'))!;
    const m = await sharp(out).metadata();
    expect(out.toString('latin1')).not.toMatch(/provider-x|secret/);
    expect(m.exif).toBeUndefined();
    expect(m.xmp).toBeUndefined();
    expect(m.icc).toBeUndefined();
    expect([m.width, m.height, m.orientation ?? 1]).toEqual([20, 40, 1]);
    const png = (await cleanImageBuffer(await sharp(raw).png().withMetadata().toBuffer(), 'image/png'))!;
    expect((await sharp(png).metadata()).exif).toBeUndefined();
  });
});
