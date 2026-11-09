# Edit XL options: research and prices

_WS8, 2026-11-09. Research only: nothing here is built or paid for. The owner decides before any spend. Prices are from
the vendors' pages as read on 2026-11-09 (links below); anything not confirmed on a primary page is marked
**unverified**. "Light use" means about 200 minutes of video, or about 200 exports, a month._

## At a glance

| Feature | Recommended option | Extra cost a month (light use) | Build size | Main catch |
|---|---|---|---|---|
| **Smooth slow motion** | Mac: Apple's built-in frame interpolation. Android: fal.ai RIFE (hosted) | Mac $0. Android ≈ $16–32 | M (Mac), M (Android) | No good free option on Android phones; our server is too small |
| **Stabilisation** | Our server, ffmpeg vidstab | $0 | M | Crops the edges a little; doesn't fix rolling-shutter wobble |
| **Auto reframe (follow faces)** | On the device: ML Kit (Android), Vision (Mac) | $0 | M | Picking the right face when several people talk |
| **Translated captions** | Claude Haiku via our server (Sonnet as "high quality") | ≈ $0.10 (Haiku) to ≈ $2 (Sonnet) | S | Word timing in the new language is spread evenly, not exact |
| **AI music** | ElevenLabs Music API (licensed training data) | ≈ $23 | M | Licence terms must be read before launch |
| **HDR export** | Mac first (AVFoundation), Android later | $0 | M (Mac), L (Android) | Few Android phones support it; social apps often flatten HDR |
| **C2PA content credentials** | c2pa SDKs + an SSL.com certificate | $0–500 a year | M, plus weeks of paperwork | TikTok, Instagram and YouTube strip it on upload |

**If the owner wants one cheap win first:** stabilisation. It's free to run, fits our server, and it's the one most
creators notice. Translated captions are next: cheap, small to build, and they reuse the transcript we already make.

---

## 1. Smooth slow motion (frame interpolation)

Slowing a clip below about 0.5× shows stutter, because there are too few frames. Interpolation invents the in-between frames.

| Option | Quality | Limits | Cost |
|---|---|---|---|
| **Mac: Apple VTFrameProcessor frame-rate conversion** (macOS 15.4+, Apple Silicon) ([WWDC25](https://developer.apple.com/videos/play/wwdc2025/300), [docs](https://developer.apple.com/documentation/videotoolbox/vtframerateconversionconfiguration)) | High (Apple's ML model, made for editing) | Apple Silicon only; speed at 1080p **unverified**; one report of it refusing small input sizes | $0 |
| **Android on the phone** (RIFE/FILM ports) | Would be good | No maintained Android port found. Research code reaches real time only on flagship chips; on a mid phone, my estimate is 10+ minutes for a 60 s clip (**unverified**) | $0 |
| **Our server: ffmpeg minterpolate** | Medium, with warping on fast motion | **Does not fit.** Measured on 1080×1920: 700–970 MB of memory (server has 512 MB) and 17–70× slower than real time. The cheap "blend" mode just cross-fades (ghosting) | $0 |
| **Hosted: fal.ai RIFE or FILM video** ([RIFE](https://fal.ai/models/fal-ai/rife/video), [FILM](https://fal.ai/models/fal-ai/film/video)) | Good (RIFE/FILM are the standard open models) | Upload needed; up to 60 fps output; run time **unverified** | $0.0013 per compute-second; ≈ $0.08–0.16 per minute of video, **≈ $16–32 a month** |
| Hosted: WaveSpeed RIFE ([page](https://wavespeed.ai/models/wavespeed-ai/rife)) | Good | Same | $0.01 per input second ≈ $0.60/min, ≈ $120 a month (**unverified**) |

On Replicate today, the public RIFE model doesn't run, and FILM takes image pairs, not video (about $20 per minute
if called frame by frame). Our own RIFE image on a T4 would be about $0.05/min plus cold starts (**unverified**).

**Build size:** M on each platform. Android: an upload, a hosted job and a download, the same as our other helpers (a
"Smooth" toggle next to Speed). Mac: local.
**Recommendation:** Mac uses Apple's built-in interpolation ($0). Android uses fal.ai RIFE as a paid helper, priced per clip
like the others, with the cost shown before running. Measure fal's run time on our clips before committing.

## 2. Stabilisation

| Option | Quality | Limits | Cost |
|---|---|---|---|
| **Our server: ffmpeg vidstab** (2 passes) | Good for handheld shake (the same engine as Kdenlive/Shotcut) | Measured on 1080×1920: detect 80–120 MB, transform 290–300 MB with 2 threads and short lookahead, so it **fits 512 MB with those limits**. About 1.5–2× the clip length (a 60 s clip takes 1.5–2 min). Crops or zooms the edges; no rolling-shutter fix. Needs the same "one at a time" queue as reverse | $0 |
| Mac: Vision image registration + our own smoothing | Similar (2D) | We'd write the camera-path smoothing ourselves | $0 |
| Android on the phone (OpenCV videostab via NDK) | Similar | Custom OpenCV build, speed unknown. vid.stab itself is GPL, so it can't ship in the app | $0 |
| Hosted | — | No production-grade per-minute stabilisation API found (one untested Replicate model) | — |

- **Licence note:** vid.stab is GPL. Running it on our own server is fine, because we don't distribute it. Shipping it inside the apps is not.
- **Deployment check:** production's ffmpeg comes from Debian bookworm. It should include libvidstab, but confirm before building (**unverified**).
- **Build size:** M. A server helper job like reverse, plus a "Stabilise" toggle in the clip tools.
- **Recommendation:** vidstab on the server, free. It's the best value on this list.

## 3. Auto reframe that follows faces

This turns a wide video into a vertical one with the speaker kept in frame. The method is the same everywhere: find faces about 5 times a second, smooth the path,
crop.

| Option | Quality | Limits | Cost |
|---|---|---|---|
| **On the device: ML Kit Face Detection (Android)** ([docs](https://developers.google.com/ml-kit/vision/face-detection/android)) + **Apple Vision (Mac)** | Good for one or two talking heads | Faces must be at least 100 × 100 px. Analysing a 60 s clip takes about 5–15 s on a mid phone (**unverified**). ML Kit adds about 0.8 MB to the app (Play Services model) | $0 (free on-device; **unverified** wording) |
| Our server (a small face model such as YuNet) | Similar | Decoding 1080p on our small CPU plus the upload is slow, and parallel jobs risk running out of memory | $0, but slow |
| Hosted: Replicate community reframe ([nicolascoutureau/ac](https://replicate.com/nicolascoutureau/ac)) | Unknown (no documentation) | Community model, about 3 min per run | ≈ $0.035 per run, ≈ $14 a month |

Google's AutoFlip (MediaPipe) is no longer supported. Luma's reframe on Replicate is generative and 720p only, so it's not suitable.

- **Build size:** M (the smoothing and "who's speaking" logic is most of the work).
- **Recommendation:** on the device, $0. The coordinator is already taking this row to the owner, so these numbers go with it.

## 4. Translated captions

We already have word-timed transcripts. This translates the caption lines and keeps each line's timing; the words
inside a line are spread evenly.

| Option | Quality | Cost per minute of speech | Light use a month |
|---|---|---|---|
| **Claude Haiku 5.5 via our server** ([pricing](https://claude.com/pricing): $0.10 / $0.50 per million tokens in/out) | Very good. Understands context and can be asked to keep lines short for captions | ≈ $0.0004 | **≈ $0.10** |
| Claude Sonnet 5.5 ($2 / $10 per million tokens) | Best | ≈ $0.008 | ≈ $1.60 |
| Google Cloud Translation ([pricing](https://cloud.google.com/translate/pricing): first 500K characters a month free, then $20 per million characters) | Good, literal; doesn't know line lengths | ≈ $0.018 past the free tier | $0 (within the free tier) |
| DeepL API ([page](https://www.deepl.com/en/pro-api)) | Good, literal | Plans changed in 2026 (**unverified**) | ≈ $0–30 |
| On the device: ML Kit Translation (Android), Apple Translation (Mac) | OK for common languages; Google calls it "for casual translations" | $0 | $0 (about 30 MB download per language on Android) |

- **Build size:** S. A server route, one prompt, a language picker and a "translated" caption track.
- **Recommendation:** Claude Haiku, practically free at our volume, with Sonnet as an optional "best quality" setting.

## 5. AI music

**Licences matter more than price here: the music ends up in members' public posts.**

| Option | Licence for commercial use | Cost | Light use (200 tracks of about 45 s) |
|---|---|---|---|
| **ElevenLabs Eleven Music API** ([pricing](https://elevenlabs.io/pricing/api)) | Commercial use on paid plans; trained on licensed music according to ElevenLabs. Film/TV/games may need Enterprise (**unverified**) | $0.15 per minute generated | **≈ $23** |
| Stability Stable Audio API ([pricing](https://docs.stability.ai/pricing)) | Output terms not yet read (**unverified**) | $0.08 per track | ≈ $16 |
| ACE-Step on Replicate ([model](https://replicate.com/lucataco/ace-step)) | Apache-2.0 weights; no protection against claims over the training data | ≈ $0.013 per run | ≈ $3 |
| ~~Meta MusicGen~~ | **Non-commercial licence (CC-BY-NC). Do not use.** | — | — |
| ~~Suno / Udio~~ | No public API (Suno) / output can't leave the platform (Udio). **Not usable.** | — | — |

- **Build size:** M. A music helper: genre and mood prompt, length matched to the edit, then added as a music track.
- **Recommendation:** ElevenLabs, for the clearest licence position. Have the owner or a lawyer read its terms for "music in members' social posts" first. ACE-Step is a cheap fallback only if the owner accepts its risk.

## 6. HDR export

No vendor, so it's engineering time only.

- **Mac (AVFoundation):** HEVC 10-bit HLG or HDR10 export is supported. Our effects have to run in 10-bit (Core Image/Metal). About 1–2 weeks of work. Size **M**.
- **Android (Media3 Transformer)** ([docs](https://developer.android.com/media/media3/transformer/supported-formats)):
  - Supported only on Android 13+ phones whose encoder supports HDR editing, mostly recent flagships (**estimate**). Otherwise it quietly falls back to SDR.
  - Every one of our OpenGL effects (looks, masks, transitions, text) would need an HDR-safe version.
  - Mixed SDR/HDR timelines are limited.
  - About 3–5 weeks of work. Size **L**.
- **Value caveat:** TikTok and Instagram often re-encode or flatten HDR uploads, so members may see little difference.
- **Recommendation:** Mac only, and only if members ask for it. Not worth it on Android yet.

## 7. C2PA content credentials

This attaches a signed "made with MUSE, AI used here" record to exported files.

- **SDKs:** open source (c2pa-rs, c2pa-ios, c2pa-android, c2pa-node; MIT/Apache licences, partly **unverified**).
- **Certificate:** since 2026 it must come from a CA on the C2PA Trust List, after passing the C2PA Conformance Program (paperwork).
  - [SSL.com](https://www.ssl.com/products/content-authenticity/content-credentials/c2pa/): a free tier (one certificate a year), or $500 a year for Premium.
  - DigiCert: price on request.
- **Reality check:** in an October 2025 test, **none of eight major platforms kept the credentials** on uploaded video ([IPTC](https://iptc.org/news/ai-disclosure-on-social-media-a-work-in-progress/)). It proves origin for the downloaded file, not the posted one.
- **Build size:** M, about 1–2 weeks to sign exports, plus weeks of conformance paperwork. The signing key must stay on the server or in hardware, never in the app.
- **Recommendation:** wait. Low visible value today. Revisit if a platform starts keeping credentials, or if AI-disclosure rules require it.
