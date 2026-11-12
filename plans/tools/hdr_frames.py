#!/usr/bin/env python3
"""Frame-by-frame colour of an HDR (HEVC 10-bit, BT.2020 / HLG) export, for the owner's HDR colour bug (2026-11-12).

Usage:  python3 -I hdr_frames.py HDR.mp4 [SDR.mp4] [--csv out.csv]

Reads the file's own 10-bit Y'CbCr codes (ffmpeg, no colour conversion), decodes them with the BT.2020 matrix and HLG,
and tone-maps back to SDR BT.709 the same way MuseCore EditV2.HDRColor does (SDR white = HLG 75 %, BT.2408). Per frame:
mean SDR RGB of the centre third and its warmth (R - B). With the SDR export of the same edit, also the per-frame
difference HDR - SDR. Flags frames whose warmth is off the clip's median by more than 6/255 (or off the SDR export).
Also prints per-frame stream tags and frame type (ffprobe) for the flagged frames and the first 20, so we can see whether
the hot frames are the first GOP, a tag change, or something else.
"""
import json
import subprocess
import sys

import numpy as np

A, B, C = 0.17883277, 0.28466892, 0.55991073
M2020_709 = np.array([[1.660491, -0.587641, -0.072850], [-0.124550, 1.132900, -0.008349], [-0.018151, -0.100579, 1.118730]])
REF = 0.203


def hlg_inv(v):
    v = np.clip(v, 0, None)
    return np.where(v <= 0.5, v * v / 3, (np.exp((v - C) / A) + B) / 12)


def oetf709(l):
    l = np.clip(l, 0, None)
    return np.where(l < 0.018, 4.5 * l, 1.099 * np.power(l, 0.45) - 0.099)


def ycc_to_rgb(y, cb, cr, kr, kb, bits):
    s = 1 << (bits - 8)
    y = (y - 16 * s) / (219 * s)
    cb = (cb - 128 * s) / (224 * s)
    cr = (cr - 128 * s) / (224 * s)
    r = y + 2 * (1 - kr) * cr
    b = y + 2 * (1 - kb) * cb
    g = (y - kr * r - kb * b) / (1 - kr - kb)
    return np.stack([r, g, b], -1)


def hlg_to_sdr(rgb):
    s = hlg_inv(rgb)
    ys = 0.2627 * s[..., 0] + 0.6780 * s[..., 1] + 0.0593 * s[..., 2]
    k = np.power(np.maximum(ys, 1e-9), 0.2)[..., None]
    d = (s * k / REF) @ M2020_709.T
    return np.clip(oetf709(d), 0, 1) * 255


def probe(path):
    out = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
                          "stream=width,height,pix_fmt,color_primaries,color_transfer,color_space,color_range,codec_name",
                          "-show_entries", "frame=pts_time,pict_type,key_frame,color_primaries,color_transfer,color_space,side_data_list",
                          "-of", "json", path], capture_output=True, text=True, check=True)
    return json.loads(out.stdout)


def frames(path, hdr, w=192):
    info = probe(path)
    st = info["streams"][0]
    h = int(round(st["height"] * w / st["width"] / 2)) * 2
    fmt = "yuv420p10le" if hdr else "yuv420p"
    cmd = ["ffmpeg", "-v", "error", "-i", path, "-vf", f"scale={w}:{h}:flags=area", "-pix_fmt", fmt, "-f", "rawvideo", "-"]
    raw = subprocess.run(cmd, capture_output=True, check=True).stdout
    dt = np.uint16 if hdr else np.uint8
    data = np.frombuffer(raw, dt)
    n = w * h * 3 // 2
    out = []
    for i in range(len(data) // n):
        f = data[i * n:(i + 1) * n].astype(np.float64)
        y = f[:w * h].reshape(h, w)
        u = f[w * h:w * h + w * h // 4].reshape(h // 2, w // 2).repeat(2, 0).repeat(2, 1)
        v = f[w * h + w * h // 4:].reshape(h // 2, w // 2).repeat(2, 0).repeat(2, 1)
        sl = (slice(h // 3, 2 * h // 3), slice(w // 3, 2 * w // 3))
        if hdr:
            rgb = hlg_to_sdr(ycc_to_rgb(y[sl], u[sl], v[sl], 0.2627, 0.0593, 10))
        else:
            rgb = np.clip(ycc_to_rgb(y[sl], u[sl], v[sl], 0.2126, 0.0722, 8), 0, 1) * 255
        out.append(rgb.reshape(-1, 3).mean(0))
    return np.array(out), info


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    csv = sys.argv[sys.argv.index("--csv") + 1] if "--csv" in sys.argv else None
    if csv in args:
        args.remove(csv)
    hdr, info = frames(args[0], True)
    st = info["streams"][0]
    print("stream:", {k: st.get(k) for k in ("codec_name", "pix_fmt", "color_primaries", "color_transfer", "color_space", "color_range")})
    sdr = frames(args[1], False)[0] if len(args) > 1 else None
    warm = hdr[:, 0] - hdr[:, 2]
    med = np.median(warm)
    fr = info.get("frames", [])
    flagged = []
    for i, px in enumerate(hdr):
        off = warm[i] - med
        d = (px - sdr[i]) if sdr is not None and i < len(sdr) else None
        bad = abs(off) > 6 or (d is not None and np.abs(d).max() > 8)
        if bad:
            flagged.append(i)
    print(f"{len(hdr)} frames, median warmth (R-B) {med:.1f}, flagged {len(flagged)}: {flagged[:60]}")
    lines = ["frame,time,type,R,G,B,warmth_off" + (",dR,dG,dB" if sdr is not None else "") + ",tags"]
    for i, px in enumerate(hdr):
        f = fr[i] if i < len(fr) else {}
        tags = f"{f.get('color_primaries', '-')}/{f.get('color_transfer', '-')}/{f.get('color_space', '-')}"
        row = f"{i},{f.get('pts_time', '')},{f.get('pict_type', '')},{px[0]:.1f},{px[1]:.1f},{px[2]:.1f},{warm[i] - med:+.1f}"
        if sdr is not None and i < len(sdr):
            d = px - sdr[i]
            row += f",{d[0]:+.1f},{d[1]:+.1f},{d[2]:+.1f}"
        lines.append(row + "," + tags)
    show = sorted(set(range(min(20, len(hdr)))) | set(flagged[:40]))
    for i in show:
        print(lines[i + 1] + ("   <-- off" if i in flagged else ""))
    if csv:
        with open(csv, "w") as fh:
            fh.write("\n".join(lines) + "\n")
        print("wrote", csv)


if __name__ == "__main__":
    main()
