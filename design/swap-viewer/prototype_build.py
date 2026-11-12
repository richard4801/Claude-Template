"""Builds the clickable prototype of New Swap and the take viewer (plans/swap-viewer-design.md).

    PHOSPHOR=<unpacked @phosphor-icons/core 2.1.1 package> python3 design/swap-viewer/prototype_build.py

Reads design/swap-viewer/prototype.src.html and inlines everything it needs, so the output is one self-contained file:
- the direction fonts (Barlow, Barlow Condensed, Archivo, Instrument Serif), subset to Latin and woff2 (needs fonttools + brotli);
- the Phosphor Regular icons it uses;
- the library stills and the sample clip frames (the Blender preview moves, cut to 9:16 JPEG frames with ffmpeg).
Writes plans/design/swap-viewer/prototype.html.
"""
import base64, io, json, os, re, subprocess, tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
OUT = REPO / "plans/design/swap-viewer/prototype.html"
FONTS = REPO / "android/app/src/main/res/font"
PV = REPO / "design/previews"
PHOS = Path(os.environ.get("PHOSPHOR", REPO / "design/icons/phosphor")) / "assets/regular"
if not PHOS.exists():
    PHOS = REPO / "design/icons/phosphor"

FONT_SET = [("Barlow", "barlow_400", 400), ("Barlow", "barlow_500", 500), ("Barlow", "barlow_600", 600),
            ("Barlow Condensed", "barlow_condensed_700", 700),
            ("Archivo", "archivo_400", 400), ("Archivo", "archivo_500", 500), ("Archivo", "archivo_600", 600),
            ("Instrument Serif", "instrument_serif_400", 400)]
UNICODES = "U+0020-007E,U+00A0-00FF,U+2013,U+2014,U+2018,U+2019,U+201C,U+201D,U+2022,U+2026,U+2190-2193,U+21E7,U+2318,U+2715,U+00D7,U+00B7"

LIB = [("moves/follow", "Café, golden hour", 8), ("angles/cowboy", "Street, dusk", 10), ("moves/selfie", "Selfie, mirror", 12),
       ("angles/ms", "Studio white", 6), ("moves/orbit_left", "Beach walk", 24), ("angles/hip", "Hallway turn", 10),
       ("moves/lead", "Market lead", 15), ("angles/low", "Low angle", 9), ("moves/dolly_in", "Dolly in", 7), ("angles/full", "Full body", 10)]
CLIP_MOVES = ["follow", "orbit_left", "dolly_in", "lead"]  # 4 × 2.5 s = the 10 s sample take
OUTFITS = ["angles/full", "angles/cowboy", "angles/hip", "angles/ms", "angles/ls", "angles/low"]


def b64(data, mime): return f"data:{mime};base64," + base64.b64encode(data).decode()


def fonts_css():
    from fontTools import subset
    css = []
    for fam, f, w in FONT_SET:
        with tempfile.TemporaryDirectory() as d:
            out = Path(d) / "f.woff2"
            subset.main([str(FONTS / f"{f}.ttf"), f"--unicodes={UNICODES}", "--flavor=woff2", f"--output-file={out}", "--layout-features=*"])
            css.append(f'@font-face{{font-family:"{fam}";src:url({b64(out.read_bytes(), "font/woff2")}) format("woff2");font-weight:{w};font-display:block}}')
    return "\n".join(css)


def icons(src):
    # every quoted word in the source that names a Phosphor icon
    names = sorted(n for n in set(re.findall(r"['\"]([a-z][a-z0-9-]*)['\"]", src)) if (PHOS / f"{n}.svg").exists())
    out = {}
    for n in names:
        svg = (PHOS / f"{n}.svg").read_text()
        out[n] = re.sub(r"^<svg[^>]*>|</svg>$", "", svg.strip())
    return out


def jpeg(path, w, h, q=72):
    from PIL import Image
    im = Image.open(path).convert("RGB")
    sw, sh = im.size
    r = w / h
    if sw / sh > r:
        nw = int(sh * r); im = im.crop(((sw - nw) // 2, 0, (sw - nw) // 2 + nw, sh))
    else:
        nh = int(sw / r); im = im.crop((0, (sh - nh) // 2, sw, (sh - nh) // 2 + nh))
    im = im.resize((w, h), Image.LANCZOS)
    buf = io.BytesIO(); im.save(buf, "JPEG", quality=q, optimize=True)
    return b64(buf.getvalue(), "image/jpeg")


def clip_frames():
    frames = []
    with tempfile.TemporaryDirectory() as d:
        for m in CLIP_MOVES:
            pat = Path(d) / f"{m}_%03d.jpg"
            subprocess.run(["ffmpeg", "-v", "error", "-i", str(PV / f"moves/{m}.mp4"), "-vf", "fps=8,crop=225:400,scale=225:400",
                            "-q:v", "6", str(pat)], check=True)
            for p in sorted(Path(d).glob(f"{m}_*.jpg"))[:20]:
                frames.append(b64(p.read_bytes(), "image/jpeg"))
    return frames


def main():
    src = (HERE / "prototype.src.html").read_text()
    assets = {
        "lib": [dict(src=jpeg(PV / f"{p}.webp", 180, 320), name=n, dur=d, file=n.split(",")[0].lower().replace(" ", "_") + ".mp4") for p, n, d in LIB],
        "outfits": [jpeg(PV / f"{p}.webp", 112, 112) for p in OUTFITS],
        "face": jpeg(PV / "angles/mcu.webp", 72, 72),
        "place": jpeg(PV / "lighting/golden_hour.webp", 72, 72),
        "frames": clip_frames(),
        "landscape": jpeg(PV / "genres/fashion.jpg", 640, 360, 78),
        "poster": jpeg(HERE / "assets/portrait-b.jpg", 225, 400, 80),
    }
    html = (src.replace("/*FONTS*/", fonts_css())
               .replace("/*ICONS*/{}", json.dumps(icons(src)))
               .replace("/*ASSETS*/{}", json.dumps(assets)))
    OUT.write_text(html)
    print("wrote", OUT, f"{OUT.stat().st_size / 1e6:.2f} MB, {len(assets['frames'])} frames")


if __name__ == "__main__":
    main()
