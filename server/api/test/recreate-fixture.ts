// The synthetic reference for the Recreate tests (workstream 1): made with ffmpeg, deterministic.
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

export const hasFfmpeg = (() => { try { execFileSync('ffmpeg', ['-version']); execFileSync('ffprobe', ['-version']); return true; } catch { return false; } })();
export const FONT = ['/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf'].find(f => fs.existsSync(f));
export const ENC = ['-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', '-r', '30', '-threads', '1'];
export const ff = (...args: string[]) => execFileSync('ffmpeg', ['-y', '-v', 'error', ...args]);

/** The synthetic reference (4.4 s): pan 0–1.5 · cut · zoom in 1.5–2.4 · crossfade 2.4–2.9 · still with a caption 3.1–4.1 and a flash at 3.73. */
export function makeReference(dir: string) {
  const a = path.join(dir, 'a.mp4'), b = path.join(dir, 'b.mp4'), c = path.join(dir, 'c.mp4'), out = path.join(dir, 'ref.mp4');
  ff('-f', 'lavfi', '-i', 'testsrc2=s=960x640:r=30', '-vf', "trim=end_frame=1,loop=-1:1:0,setpts=N/30/TB,crop=360:640:x='100+t*120':y=0,scale=180:320", '-t', '1.5', ...ENC, a);
  ff('-f', 'lavfi', '-i', 'mandelbrot=s=720x1280:r=30', '-vf', "trim=end_frame=1,loop=-1:1:0,setpts=N/30/TB,zoompan=z='1+0.006*on':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':d=1:s=180x320:fps=30", '-t', '1.5', ...ENC, b);
  const text = FONT ? `drawtext=fontfile=${FONT}:text='SUMMER':fontsize=28:fontcolor=white:borderw=2:bordercolor=black:x=(w-tw)/2:y=h*0.7:enable='between(t,0.7,1.7)',` : '';
  ff('-f', 'lavfi', '-i', 'gradients=s=180x320:r=30:d=2:speed=0.01:nb_colors=2:c0=0xFFD27A:c1=0x7AC8FF:seed=1', '-vf', `${text}drawbox=c=white:t=fill:enable='eq(n,40)'`, '-t', '2', ...ENC, c);
  ff('-i', a, '-i', b, '-i', c, '-f', 'lavfi', '-i', "aevalsrc='0.8*sin(2*PI*880*t)*exp(-60*mod(t,0.5))':s=44100:d=4.4",
    '-filter_complex', '[0]fps=30,settb=1/30[a];[1]fps=30,settb=1/30[b];[2]fps=30,settb=1/30[c];[a][b]concat=n=2:v=1,fps=30,settb=1/30[ab];[ab][c]xfade=transition=fade:duration=0.5:offset=2.4[v]',
    '-map', '[v]', '-map', '3:a', '-c:a', 'aac', '-shortest', ...ENC, out);
  return out;
}

