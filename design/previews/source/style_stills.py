"""Style → Genre / Era / Tempo preview stills for the composer (resume item 12c).

Built only from the existing hardware renders in design/hardware (no paid generation, no Blender): each option gets a
scene that suits it, graded and processed in the way that genre / decade / pacing reads on screen. Tempo stills also
carry an amber cut-rhythm strip (one unbroken bar for "One take", many uneven cuts for "Chaotic").

Writes design/previews/{genres,eras,tempos}/<id>.jpg (640x400, like the lighting stills) and adds their rows to
design/previews/manifest.tsv. Then run `npx tsx scripts/suite-previews.ts` in server/api to regenerate previews.data.ts.

    python3 design/previews/source/style_stills.py
"""
from pathlib import Path
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[2]          # design/
HW, OUT = ROOT / "hardware", ROOT / "previews"
W, H = 640, 400
AMBER = (231, 165, 74)
rng = np.random.default_rng(7)                        # deterministic grain


def load(name, y=0.5, x=0.5, zoom=1.0):
    """The render cropped to 640x400 around (x, y) (0..1 of the source), as floats 0..1."""
    im = Image.open(HW / f"{name}.webp").convert("RGB")
    s = im.width * zoom
    side = int(W / H * s) if W / H * s <= im.width else im.width
    cw, ch = min(im.width, int(s * W / max(W, H))), min(im.height, int(s * H / max(W, H)))
    cx, cy = int(x * im.width), int(y * im.height)
    box = (max(0, min(im.width - cw, cx - cw // 2)), max(0, min(im.height - ch, cy - ch // 2)))
    im = im.crop((box[0], box[1], box[0] + cw, box[1] + ch)).resize((W, H), Image.LANCZOS)
    return np.asarray(im).astype(np.float32) / 255.0


def save(a, kind, oid):
    (OUT / kind).mkdir(parents=True, exist_ok=True)
    p = OUT / kind / f"{oid}.jpg"
    Image.fromarray((np.clip(a, 0, 1) * 255).astype(np.uint8)).save(p, "JPEG", quality=78, optimize=True, progressive=True)
    return p


# ---------------------------------------------------------------- treatments
def luma(a): return a @ np.array([0.2126, 0.7152, 0.0722], np.float32)

def grade(a, sat=1.0, contrast=1.0, lift=0.0, gain=1.0, tint=(1, 1, 1), gamma=1.0):
    l = luma(a)[..., None]
    a = l + (a - l) * sat
    a = (a - 0.5) * contrast + 0.5
    a = lift + a * (gain - lift)
    a = a * np.array(tint, np.float32)
    return np.clip(a, 0, 1) ** gamma

def split_tone(a, shadows, highlights, amount=0.25):
    l = luma(a)[..., None]
    return np.clip(a + amount * ((1 - l) * (np.array(shadows) - 0.5) + l * (np.array(highlights) - 0.5)), 0, 1)

def vignette(a, strength=0.5, roundness=1.0):
    yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
    d = np.sqrt(((xx - W / 2) / (W / 2)) ** 2 + ((yy - H / 2) / (H / 2 * roundness)) ** 2)
    return a * (1 - strength * np.clip(d - 0.35, 0, 1) ** 1.6)[..., None]

def grain(a, amount=0.05, size=1):
    n = rng.normal(0, amount * 0.55, (H // size + 1, W // size + 1)).astype(np.float32)
    n = np.kron(n, np.ones((size, size), np.float32))[:H, :W]
    n = np.asarray(Image.fromarray(((n + .5) * 255).clip(0, 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(.6))).astype(np.float32) / 255 - .5
    return np.clip(a + n[..., None] * (1 - luma(a)[..., None] * 0.5), 0, 1)

def blur(a, r):
    return np.asarray(Image.fromarray((a * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(r))).astype(np.float32) / 255

def motion(a, length=24, dx=1, dy=0):
    acc = np.zeros_like(a)
    for k in range(length):
        acc += np.roll(a, (int(k * dy), int(k * dx)), axis=(0, 1))
    return acc / length

def ghosts(a, n=4, step=18, fade=0.55):
    out, w = a.copy(), 1.0
    for k in range(1, n + 1):
        w *= fade
        out = np.maximum(out, np.roll(a, k * step, axis=1) * w)
    return out

def bloom(a, threshold=0.7, radius=10, amount=0.6):
    hi = np.clip((a - threshold) / (1 - threshold), 0, 1)
    return np.clip(a + blur(hi, radius) * amount, 0, 1)

def lowres(a, f=4):
    im = Image.fromarray((a * 255).astype(np.uint8))
    im = im.resize((W // f, H // f), Image.BILINEAR).resize((W, H), Image.NEAREST).filter(ImageFilter.SHARPEN)
    return np.asarray(im).astype(np.float32) / 255

def scanlines(a, gap=3, depth=0.22):
    m = np.ones((H, 1, 1), np.float32); m[::gap] = 1 - depth
    return a * m

def chroma(a, px=3):
    out = a.copy(); out[..., 0] = np.roll(a[..., 0], px, axis=1); out[..., 2] = np.roll(a[..., 2], -px, axis=1)
    return out

def blinds(a, n=11, angle=-0.35, depth=0.6):
    yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
    band = np.sin((yy + xx * angle) / H * n * np.pi) > 0.15
    return a * np.where(band, 1.0, 1 - depth)[..., None]

def rounded_gate(a, r=36):
    m = Image.new("L", (W, H), 0); ImageDraw.Draw(m).rounded_rectangle((10, 8, W - 10, H - 8), r, fill=255)
    m = np.asarray(m.filter(ImageFilter.GaussianBlur(6))).astype(np.float32)[..., None] / 255
    return a * m

def rhythm(a, cuts, y=H - 34, h=8):
    """An amber strip at the bottom: one segment per shot (fractions summing to 1), separated by cut gaps."""
    im = Image.fromarray((np.clip(a, 0, 1) * 255).astype(np.uint8)); d = ImageDraw.Draw(im)
    x0, x1, gap = 36, W - 36, 5
    d.rounded_rectangle((x0 - 10, y - 12, x1 + 10, y + h + 12), 10, fill=(0, 0, 0))
    x = x0
    for i, f in enumerate(cuts):
        w = (x1 - x0) * f
        d.rounded_rectangle((x + (0 if i == 0 else gap / 2), y, x + w - (0 if i == len(cuts) - 1 else gap / 2), y + h), 3, fill=AMBER)
        x += w
    return np.asarray(im).astype(np.float32) / 255

def uneven(n, seed, spread=0.8):
    r = np.random.default_rng(seed).uniform(1 - spread, 1 + spread, n)
    return list(r / r.sum())


# ---------------------------------------------------------------- the stills
GENRES = {
    "ugc": lambda: vignette(grade(load("light-06-ring-creator", y=.55), sat=1.15, lift=.03, gain=1.08), .3),
    "commercial": lambda: vignette(bloom(grade(load("light-01-soft-cross", y=.45), contrast=1.08, gain=1.12), .75, 14, .45), .25),
    "drama": lambda: vignette(split_tone(grade(load("light-02-contre-jour", y=.5), contrast=1.15, sat=.85), (.35, .45, .6), (.75, .6, .45), .3), .7),
    "action": lambda: vignette(motion(split_tone(grade(load("grip-04-fpv", y=.48, zoom=.8), contrast=1.25, sat=1.2), (.25, .5, .6), (.85, .55, .3), .45), 30, 1, 0) * .35
                               + split_tone(grade(load("grip-04-fpv", y=.48, zoom=.8), contrast=1.25, sat=1.2), (.25, .5, .6), (.85, .55, .3), .45) * .65, .55),
    "epic": lambda: vignette(bloom(split_tone(grade(load("palette-02-teal-orange", y=.25, zoom=.9), contrast=1.15, sat=1.1), (.2, .45, .55), (.9, .6, .3), .35), .7, 16, .5), .45),
    "comedy": lambda: grade(load("palette-04-bleached-warm", y=.55), sat=1.2, contrast=.95, lift=.06, gain=1.08, tint=(1.03, 1.01, .96)),
    "romance": lambda: vignette(bloom(grade(load("light-04-window", y=.5), sat=.9, lift=.04, tint=(1.12, .98, .95)), .6, 18, .55), .45),
    "horror": lambda: grain(vignette(grade(load("light-05-practicals", y=.5), sat=.3, contrast=1.15, lift=.03, gain=1.35, gamma=.95, tint=(.82, 1.05, .9)), .8, .85), .04, 2),
    "noir": lambda: grain(vignette(blinds(grade(load("palette-06-classic-bw", y=.5), sat=0, contrast=1.45, gamma=1.1), 9, -.4, .55), .75), .045, 1),
    "documentary": lambda: grain(grade(load("palette-01-naturalistic", y=.6, x=.4), sat=.9, contrast=.95, lift=.04), .06, 2),
    "music_video": lambda: chroma(bloom(grade(load("palette-03-hyper-neon", y=.45), sat=1.35, contrast=1.15), .55, 12, .8), 4),
    "fashion": lambda: vignette(grade(load("light-03-overhead", y=.42), sat=.6, contrast=1.3, tint=(1.02, 1.0, 1.04)), .4),
}

STREET = lambda **k: load("palette-01-naturalistic", **{"y": .55, **k})
ERAS = {
    "1960s": lambda: grain(vignette(rounded_gate(grade(load("palette-04-bleached-warm", y=.55), sat=.75, contrast=.85, lift=.08, tint=(1.08, 1.0, .82))), .6, .9), .08, 2),
    "1970s": lambda: grain(bloom(grade(STREET(), sat=.7, contrast=.82, lift=.12, gain=1.05, tint=(1.18, .98, .66)), .55, 16, .6), .05, 2),
    "1980s": lambda: scanlines(chroma(bloom(grade(load("palette-03-hyper-neon", y=.5), sat=1.25, contrast=1.05, lift=.04), .6, 10, .6), 3), 3, .25),
    "1990s": lambda: grain(split_tone(grade(STREET(), sat=1.35, contrast=1.3, tint=(.98, 1.06, .94)), (.25, .5, .35), (.8, .65, .4), .5), .05, 2),
    "2000s": lambda: scanlines(lowres(bloom(grade(STREET(), sat=1.15, contrast=1.25, gain=1.35, tint=(.95, 1.0, 1.1)), .5, 6, .9), 7), 2, .12),
    "2010s": lambda: vignette(split_tone(grade(load("palette-02-teal-orange", y=.55), contrast=1.1, sat=1.05), (.25, .5, .55), (.85, .6, .35), .3), .4),
    "2020s": lambda: grade(load("palette-04-bleached-warm", y=.55), sat=1.15, contrast=1.12, gain=1.04),
    "future": lambda: bloom(grade(load("palette-03-hyper-neon", y=.5), sat=.15, contrast=1.35, gain=1.2, tint=(.72, .98, 1.25)), .5, 18, .9),
}

TEMPOS = {
    "calm": lambda: rhythm(vignette(blur(grade(STREET(), sat=.7, contrast=.85, lift=.06, tint=(.95, 1.0, 1.05)), 2.5), .5), [.55, .45]),
    "steady": lambda: rhythm(grade(STREET(), sat=1.0, contrast=1.05), [.25] * 4),
    "dynamic": lambda: rhythm(motion(grade(STREET(), contrast=1.2, sat=1.2), 48, 1, 0) * .7 + grade(STREET(), contrast=1.2, sat=1.2) * .3, uneven(7, 3, .5)),
    "chaotic": lambda: rhythm(chroma(motion(ghosts(grade(STREET(x=.45, y=.6), contrast=1.35, sat=1.25), 4, 34, .75), 14, 1, 1), 6), uneven(14, 5, .9)),
    "single_shot": lambda: rhythm(motion(grade(STREET(), sat=1.0), 10, 1, 0) * .3 + grade(STREET(), sat=1.0) * .7, [1.0]),
    "slow_motion": lambda: rhythm(bloom(ghosts(grade(STREET(), sat=.85, contrast=1.05, tint=(1.0, 1.0, 1.06)), 6, 9, .82), .6, 10, .4), [.4, .6]),
}


def main():
    rows = []
    for kind, table in (("genres", GENRES), ("eras", ERAS), ("tempos", TEMPOS)):
        for oid, make in table.items():
            p = save(make(), kind, oid)
            rows.append(f"{kind}/{oid}\t{kind}/{oid}.jpg\t\t0.00\t{p.stat().st_size}")
    man = OUT / "manifest.tsv"
    keep = [l for l in man.read_text().splitlines() if l and not l.split("\t")[0].split("/")[0] in ("genres", "eras", "tempos")]
    man.write_text("\n".join(keep + rows) + "\n")
    print(f"wrote {len(rows)} stills")


if __name__ == "__main__":
    main()
