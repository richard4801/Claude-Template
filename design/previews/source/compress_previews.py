#!/usr/bin/env python3
"""Compress the bundled composer previews and hardware renders (AI suite, workstream 1; plans/perf-audit.md).

Run after render_previews.py (or after new hardware renders). Needs ffmpeg and Pillow; no Blender, no network.

  python3 design/previews/source/compress_previews.py               # previews: loops + plain stills, manifest
  python3 design/previews/source/compress_previews.py --hardware    # also design/hardware (+ the Android copy)

- Move loops (moves/*.mp4, 320x400, 2.5 s): H.264 CRF 24 (x264 veryslow, High@3.1, yuv420p, GOP 60), no audio,
  faststart. A loop already under 450 kbps is left alone, so running it twice doesn't re-encode twice.
- Plain stills (moves/*.jpg posters, angles/*.jpg, lighting/*.jpg) -> WebP q80, same size (they are already at about
  their largest display size at 2x). The JPEG is removed and manifest.tsv points at the .webp.
- The Style stills (genres/, eras/, tempos/: style_stills.py) stay JPEG: their film grain and VHS lines lose detail at
  WebP q80, and at q88 WebP is larger than the JPEG.
- --hardware: design/hardware/*.webp re-encoded at WebP q80 (1024 px kept; the apps decode them at 512 px or less).
  Run it once per new set of renders: re-running re-encodes again. The Android copy (assets/hardware) is rewritten
  to match.

Checked 2026-11-06 against the originals: loops SSIM >= 0.990 (8.4 MB -> 1.2 MB), stills >= 0.991, hardware >= 0.987
at display size, and side by side at display size.
"""
import csv
import json
import os
import shutil
import subprocess
import sys

from PIL import Image

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..', '..'))
PREVIEWS = os.path.join(ROOT, 'design', 'previews')
HARDWARE = os.path.join(ROOT, 'design', 'hardware')
ANDROID_HARDWARE = os.path.join(ROOT, 'android', 'app', 'src', 'main', 'assets', 'hardware')
WEBP_DIRS = ('moves', 'angles', 'lighting')  # plain stills -> WebP
LOOP_CRF, LOOP_SKIP_KBPS, WEBP_Q = 24, 450, 80


def kbps(path):
    out = subprocess.run(['ffprobe', '-v', 'error', '-show_entries', 'format=bit_rate', '-of', 'json', path],
                         capture_output=True, text=True, check=True).stdout
    return int(json.loads(out)['format'].get('bit_rate') or 0) / 1000


def loop(path):
    if kbps(path) <= LOOP_SKIP_KBPS:
        return False
    tmp = path + '.tmp.mp4'
    subprocess.run(['ffmpeg', '-v', 'error', '-y', '-i', path, '-an', '-c:v', 'libx264', '-preset', 'veryslow', '-crf', str(LOOP_CRF),
                    '-profile:v', 'high', '-level', '3.1', '-pix_fmt', 'yuv420p', '-g', '60', '-movflags', '+faststart', tmp], check=True)
    os.replace(tmp, path)
    return True


def webp(src, dst):
    im = Image.open(src)
    im.load()
    im.convert('RGB').save(dst + '.tmp', 'WEBP', quality=WEBP_Q, method=6)
    os.replace(dst + '.tmp', dst)


def previews():
    loops = stills = 0
    for d in WEBP_DIRS:
        folder = os.path.join(PREVIEWS, d)
        for name in sorted(os.listdir(folder)):
            p = os.path.join(folder, name)
            if name.endswith('.mp4'):
                loops += loop(p)
            elif name.endswith('.jpg'):
                webp(p, p[:-4] + '.webp')
                os.remove(p)
                stills += 1
    # The manifest: .jpg -> .webp for those folders; bytes re-read for every row.
    path = os.path.join(PREVIEWS, 'manifest.tsv')
    with open(path, newline='') as f:
        rows = list(csv.reader(f, delimiter='\t'))
    head, body = rows[0], rows[1:]
    fi, pi, bi = head.index('file'), head.index('poster'), head.index('bytes')
    for r in body:
        for i in (fi, pi):
            if r[i] and r[i].split('/')[0] in WEBP_DIRS and r[i].endswith('.jpg'):
                r[i] = r[i][:-4] + '.webp'
        r[bi] = str(os.path.getsize(os.path.join(PREVIEWS, r[fi])))
    with open(path, 'w', newline='') as f:
        csv.writer(f, delimiter='\t', lineterminator='\n').writerows([head] + body)
    print(f'previews: {loops} loops re-encoded, {stills} stills -> WebP, manifest updated')


def hardware():
    n = 0
    for name in sorted(os.listdir(HARDWARE)):
        if name.endswith('.webp'):
            p = os.path.join(HARDWARE, name)
            webp(p, p)
            if os.path.isdir(ANDROID_HARDWARE):
                shutil.copyfile(p, os.path.join(ANDROID_HARDWARE, name))
            n += 1
    print(f'hardware: {n} renders re-encoded at WebP q{WEBP_Q}')


if __name__ == '__main__':
    previews()
    if '--hardware' in sys.argv:
        hardware()
