// Child process for test/render-cjk.test.ts: renders a 1080p edit with a Japanese caption in a fresh Node and reports
// its own peak memory (VmHWM catches the synchronous font parse a timer can't sample), whether anything was
// unsupported, and how many CJK faces are still loaded after the render.
//   node --import tsx test/cjk-render-child.ts <source.mp4> <out.mp4> <ffmpeg>
import fs from 'node:fs';
import * as M from '../src/editor/model.js';
import { CAPTION_STYLES } from '../src/editor/presets.js';
import { renderProject } from '../src/editor/render.js';
import * as TD from '../src/editor/textdraw.js';

const [src, out, ffmpeg] = process.argv.slice(2) as [string, string, string];
const hwm = () => Number(/VmHWM:\s+(\d+)/.exec(fs.readFileSync('/proc/self/status', 'utf8'))?.[1] ?? 0) / 1024;
const p: M.EditProject = {
  version: 2, sourceTakeId: 'tg', canvas: { width: 1080, height: 1920, fps: 30, background: '#000000' },
  assets: [{ id: 'g', kind: 'video', take: 'tg', durationSec: 4 }],
  tracks: [{ id: 'main', kind: 'main', items: [{ id: 'c1', asset: 'g', inSec: 0, outSec: 4, speed: 1 } as M.VideoClip] },
    { id: 'cap', kind: 'caption', items: [], caption: {
      asset: 'g', language: 'ja',
      words: [{ text: '今日は', startSec: 0.3, endSec: 1 }, { text: 'みなさん', startSec: 1, endSec: 1.8 }, { text: '元気ですか', startSec: 1.8, endSec: 3 }],
      style: { ...CAPTION_STYLES.highlight, color: '#FFFFFF', highlightColor: '#FFD400', shadow: undefined, wordsPerPage: 3 } } as M.CaptionTrack }],
};
M.validate(p);
const before = hwm();
const r = await renderProject({ ffmpeg, ffprobe: 'ffprobe' }, p, { g: src }, out, { maxSide: 1920, audio: 'none' });
console.log(JSON.stringify({ unsupported: r.unsupported, cjkLoaded: TD.cjkLoaded(), startMb: Math.round(before), peakMb: Math.round(hwm()) }));
