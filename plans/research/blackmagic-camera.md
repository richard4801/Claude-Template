# Blackmagic Camera (iOS/Android) and its APIs: what MUSE can use

Research date: 6 November 2026. **[P]** marks a primary source (Blackmagic page, Blackmagic PDF, App Store or Play Store). **[S]** marks a secondary source (press, forum, open-source projects that tested the app). Source numbers refer to the list at the end.

## Bottom line on the owner's claim ("API connection and WebSockets protocol")

**Mostly true, but narrower than it sounds.**

- **What is confirmed.** Since **v3.4** (Android mid-July 2026; iOS 22 July 2026), Blackmagic Camera has had "support for remote control via Blackmagic Camera REST API" [P3][S1][S3]. The iOS tech specs list a **Network Access, "Enable HTTP Server"** setting [P2]. The product page says you can "use REST API and Remote Camera Manager to create and save camera lists" [P1].
- **Same API as the hardware cameras.** The API is Blackmagic's **Camera Control REST API** plus its **notification WebSocket**. This is the API Blackmagic documents for its hardware cameras [P6].
  - Projects that tested the app found it serves that API under `/control/api/v1`.
  - It publishes its own OpenAPI/AsyncAPI YAML at `/control/documentation.html`.
  - It pushes property changes over a WebSocket [S6][S7][S8][S9].
- **What is not true or not documented:**
  - **Not documented for the app.** Blackmagic's REST PDF (Aug 2025) lists only hardware cameras [P6]. No Blackmagic page gives the app's port, TLS, authentication or endpoint list. Those details come only from community testing: HTTPS on **port 4444**, a **self-signed certificate**, **no password**, and the server **runs only while the app is in the foreground** [S6][S7][S8].
  - **Local network only.** There is no cloud or remote endpoint. Blackmagic Cloud has **no public API** (none on the developer site or the Cloud help site) [P5][P9][P11].
  - **It controls and observes the camera; it does not hand over footage.** The API gives settings, record/transport, slate, the clip *list*, presets and live-stream configuration. Community testing found **no clip download** (the Android project fetches files over adb) [S8]. There is **no LUT file transfer** [S6], **no gyro/IMU or pose stream**, and **no raw preview frames**. Live video comes only by pointing the app's live stream (RTMP/SRT) at your own server [S6][S7].

---

## 1. Feature set (current versions)

**Current versions:**
- **iOS/iPadOS:** v3.5.3, 23 Oct 2026 [P3].
- **Android:** v3.5.1, Play Store "Updated on Oct 29, 2026" [P4]. v3.5 shipped about 8 Oct 2026 [S4].

### 1.1 iOS / iPadOS (iPhone, iPad, plus a Mac and Apple Watch companion)

All from Blackmagic's iOS tech specs [P2] unless marked.

| Area | iOS / iPadOS |
|---|---|
| Frame rate | 23.98 to 120 fps. Off-speed 4 to 120 fps. Time-lapse. |
| Shutter | Speed 1/24 to 1/8000, or **shutter angle 1.1° to 360°**. Lock on/off. Flicker-free 50/60 Hz. |
| ISO | 21 to 5472 (depends on model and lens). Exposure comp ±3 stops. Auto exposure. |
| White balance / tint | 2500 to 10,000 K. Tint −50 to +50. Presets. Lock WB on record. |
| Focus | AF on/off, tap to focus. Manual focus 0.00 to 1.00 (normalised). **Rack focus** between 3 presets. Focus assist (peaking or coloured lines). |
| Exposure tools | **Zebra** (75 to 100%), **false colour**, **RGB histogram** with clip indicators, safe areas, grids. **No waveform or vectorscope** on any Blackmagic page. |
| Iris | Variable only where the phone has it. App notes for v3.5 (Sep 2026) add variable aperture on the iPhone 18 Pro main camera [P3]. |
| Codecs | **Apple ProRes 422 HQ, 422, 422 LT, Proxy**; **ProRes RAW / RAW HQ** (needs external storage; added in 3.1 for iPhone 17 Pro); **HEVC (H.265)**; **H.264**. Optional automatic 1920×1080 HEVC **proxies**. **No Blackmagic RAW.** |
| Colour space | Rec.709, Rec.2020 HDR, P3 D65, **Apple Log**, **Apple Log 2** (by model). Built-in Apple Log to Rec.709 LUT [P1]. |
| Resolution / aspect | 720p, HD, 4K, **Open Gate** (1920×1440 Open Gate with Apple Log, from 3.1.2 [P3]). Anamorphic de-squeeze 1.33, 1.55 and 2.0. |
| Vertical / social | **"Enable Vertical Video"** records true portrait. Frame guides for 9:16, 4:5, 1:1 and cinema ratios [P1][P2]. |
| 3D LUTs | Import, export and remove. **17- and 33-point 3D LUTs** [P1]. Built-in looks (Rec 709 Neutral, Cinema Teal and others, plus Fujifilm 3513DI D55). Display LUT on screen and on HDMI separately. **"Record LUT to Clip" on/off** [P2]. LUTs "can be applied just for monitoring only, or … recorded into clips" [P1]. |
| Metadata entry | Slate name, lens data, reel, scene, take, good take, int/ext, day/night, production name, camera ident, director, camera operator [P2]. Location data to clip (option) [P2]. |
| Timecode | Record-run or time-of-day. Bluetooth **Tentacle Sync E**. ProDock adds BNC timecode and genlock [P1][P2]. |
| Stabilisation | Off, Standard, Cinematic, Extreme. |
| Presets | Save, **import, export** and overwrite presets ("import the one preset into many cameras") [P1][P2]. |
| Remote / multicam | Phone as **Controller** or **Remote Camera**. Remote password. Control and monitor, or monitor only. **Sync record across cameras**. **Sync clips to controller after record**. Multiview. Remote Cameras Manager with import/export of camera lists [P2]. Controllers can be iPhone, iPad or Mac [P1]. |
| Network API | **Network Access, "Enable HTTP Server"** [P2]. REST API since 3.4 (22 Jul 2026) [P3]. |
| Other control | Apple Watch companion (record, exposure, focus, LUT, lens, zoom) [P1]. ATEM camera control and tally over HDMI via ProDock [P1][P3]. Blackmagic Focus and Zoom Demands. Tilta Nucleus. Volume button or Camera Control button records. |
| Streaming | YouTube, Twitch, Vimeo, Blackmagic Cloud, custom RTMP/SRT [P1][P3]. |
| Blackmagic Cloud | Login. Record into DaVinci Resolve projects. **Live Sync** (upload proxies while recording, then originals). Cloud Folders (2.3, Apr 2025). Upload over Wi-Fi only. Proxy-only or originals + proxies. Chat [P1][P2][P3]. |
| Requirements | App Store says iOS/iPadOS 18.0+ (A12 or later), macOS 15+ (M1 or later), watchOS 10.6+ [P3]. The tech-spec page still says iOS 16.6+ and is out of date. |

### 1.2 Android (phones and tablets)

From Blackmagic's Android tech specs [P2] unless marked.

| Area | Android |
|---|---|
| Frame rate | 24 to 240 fps (depends on model). Off-speed 4 to 60 fps. |
| Shutter / ISO / WB | Shutter angle 1.1 to 360° or speed. ISO 25 to 10666. WB 2500 to 10,000 K. Tint −50 to +50. Exposure comp ±4 stops. |
| Focus | AF/tap focus. **Manual focus in dioptres**. Rack focus (3 presets). Focus assist. |
| Exposure tools | Zebra, false colour, RGB histogram, guides. No waveform listed. |
| Codecs | **HEVC, H.264**, and **APV (Advanced Professional Video)** on supported models. **No ProRes, no Blackmagic RAW.** Optional 1080p HEVC proxies. |
| Colour space | Rec.709, Rec.2020 HLG10, BT.2020 HDR10. v3.5 adds Oppo **O-Log2** on Find X10 and OnePlus 16 [S4]. |
| Resolution | Up to 8K (by model). Open gate and selectable aspect ratios (3.1) [S]. Vertical video. Same frame guides as iOS. |
| 3D LUTs | Display LUT on/off. Import, export and select. **Record LUT to Clip**. Colour-space tag [P2]. Same 17/33-point support [P1]. |
| Metadata entry | Same slate fields as iOS. Location data option [P2]. |
| Stabilisation | Off, Standard, Optical. |
| Remote / multicam | Controller or remote camera, password, sync record [P2]. 3.4 added **"Remote Control via REST API"**, a **Remote Camera Manager**, a Proxy Clip Manager, WearOS control, 4K HDMI with audio, and pause [S3][S5]. 3.5 added 10-bit remote previews and preset shortcuts [S4]. The Android tech-spec page does **not** list the HTTP-server setting, but testers report it under **Settings, Network Access, Enable HTTP Server** [S8][S10]. |
| Accessories | Tentacle Sync E, Nucleus lens control, Insta360 Flow Pro, Xiaomi 14 Ultra grip, Focus/Zoom Demands over USB-C [P1][P2]. |
| Devices | Samsung Galaxy S21 to S25 and Fold, Pixel 6 to 9, OnePlus, Xiaomi, Sony Xperia, Oppo, Vivo, some tablets. Android 13+ [P2]. Later notes add the Galaxy Z Fold 8 (3.5.1) [P4] and Oppo Find X10 / OnePlus 16 (3.5) [S4]. |
| Audio | The spec page says AAC. Coverage of 3.4 mentions a PCM option [S5]. |

**Not available on either platform:** Blackmagic RAW recording; a waveform or vectorscope; native Dropbox or Google Drive upload; any documented gyro/IMU metadata.

---

## 2. APIs and protocols

### 2.1 Does the mobile app expose an official REST and/or WebSocket API?

**REST: yes, official since v3.4. App-specific documentation: not published.**

- **Release notes:** "Support for remote control via Blackmagic Camera REST API" appears in the iOS notes (22 Jul 2026) [P3][S1][S2] and the Android 3.4 notes (about 16 Jul 2026) [S3][S5].
- **Setting:** iOS tech specs list "Network Access: HTTP Server – Enable HTTP Server, on or off" [P2].
- **The document it refers to:** the *REST API for Blackmagic Cameras* PDF (Aug 2025, 94 pp) [P6], with the same content inside *Blackmagic Camera Control* (Aug 2025, 115 pp) [P7]. Both list **only hardware cameras** and predate the app's API by about 11 months.
- **The app documents itself.** Like the hardware cameras, the app serves its own YAML reference at `https://<phone>:4444/control/documentation.html`. That is 16 OpenAPI files plus an AsyncAPI WebSocket spec; one tester counted 131 endpoints on App 3.4 [S6][S9].

**WebSocket: yes.** This is the hardware API's "Notification websocket 1.0.0" [P6 p.70–74], and the app implements it.
- **Messages [P6]:** the client sends `{"type":"request","data":{"action":"subscribe","properties":[…]}}`. The device replies with a `response` (including current values), then sends `event` messages with `action: propertyValueChanged`.
- **Subscribable list:** `GET /control/api/v1/event/list`.
- **Endpoint used on Android:** an Android project (app 3.5.1, Pixel 10) connects to `wss://<phone>:4444/control/api/v1/event/websocket` [S8].
- **Use on iOS:** an iOS project (app 3.5) uses "REST and WebSocket API (port 4444)" [S7].

**Transport, discovery and security [S6][S7][S8][S9], all community-reported:**
- HTTPS on **port 4444** with a **self-signed certificate**.
- Bonjour advertises `_http._tcp`, but the service actually speaks HTTPS.
- **No authentication on reads or writes.** Tested on iOS 3.5.3, iPhone 15 Pro [S6]. The "Remote Password" in settings is for Blackmagic's private phone-to-phone remote protocol, which is a separate thing [P2][S6].
- **The app must be open in the foreground.** HTTP access stops in the background, and on iOS also when the screen locks [S6][S7][S10].
- **LAN only.**
- Blackmagic documents none of this for the app.

### 2.2 What it can read and set

The table shows the hardware API [P6], plus what testers confirmed on the app [S6][S8]. "Confirmed on app" means a community project used it successfully; everything else in [P6] may or may not be implemented by the app. Unsupported endpoints return 404 or 501, and you can probe for them [S9].

| Function | Endpoint(s) [P6] | On app? |
|---|---|---|
| Record start/stop, state | `GET/PUT /transports/0/record`, `/transports/0`, `/transports/0/timecode` | **Confirmed** (iOS and Android) |
| ISO, shutter, WB, tint, auto-exposure | `/video/iso`, `/video/shutter`, `/video/whiteBalance`, `/video/whiteBalanceTint`, `/video/autoExposure`, `…/supported*` | **Confirmed** |
| Lens: zoom, focus, iris, AF | `/lens/zoom`, `/lens/focus`, `PUT /lens/focus/doAutoFocus`, `/lens/iris` (+ `/description`) | **Confirmed**. iPhone iris reports `controllable:false` on fixed-aperture phones [S6]. |
| Physical lens selection | `/lens/cameras`, `/lens/cameras/active` (**app-only, undocumented**) | Confirmed on iOS [S6] |
| Format: codec, resolution, fps, colour space | `/system/format`, `/system/supportedFormats`, `/system/codecFormat`. The app also has `/system/dynamicRange` (undocumented) [S6]. | Confirmed. Some resolution changes only stick via a preset [S8]. |
| Slate / metadata for next clip | `GET/PUT /slates/nextClip` (clip: reel, scene, take, shotType, goodTake, int/ext, day/night; lens: type, iris, focalLength, distance; project: name, director, camera, operator) | **Confirmed** (camera letter = `project.camera`, reel = `clip.reel`) [S6] |
| Presets | `GET /presets`, `PUT /presets/active`, `GET/PUT /presets/{name}`. Upload or download `.cset` / `.bmcpreset` (JSON of app settings, including `lutSelection`). | **Confirmed** [S6][S8] |
| Monitoring overlays | `/monitoring/{Device or HDMI}/displayLUT`, `cleanFeed`, `zebra`, `focusAssist`, `falseColor`, `frameGuide` | Display-LUT on/off and clean feed confirmed [S6]. **No LUT upload.** |
| Clip list | `GET /clips` (filePath, codec, videoFormat, startTimecode, duration, frameCount) | **Confirmed** on Android (returns a media-store URI) [S8] |
| Media download | *No endpoint in [P6].* Hardware cameras use the Web Media Manager or SMB instead [S13]. | **Not available.** Android projects use adb [S8]. |
| Live preview | No frame or JPEG endpoint. Workaround: `PUT /livestreams/customPlatforms/{file}` (Blackmagic streaming XML), `PUT /livestreams/0/activePlatform`, `PUT /livestreams/0/start` to your own RTMP/SRT server. | **Confirmed** as a workaround: SRT (HEVC) [S7]; RTMP needs H.264 recording and an integer fps [S6] |
| Tally | `/camera/tallyStatus` | **Unverified** on app |
| Cloud upload status | `/cloud/projects`, `/cloud/clips/activeUploading` | **Unverified** on app |
| Gyro, IMU, pose | none | **Not available** |

### 2.3 Hardware cameras with the Camera Control REST API, and whether the app shares it

**Listed in the Aug 2025 PDF [P6][P7]:**
- URSA Cine 12K LF, URSA Cine 17K 65, URSA Cine Immersive
- PYXIS 6K, Cinema Camera 6K
- URSA Broadcast G2, Micro Studio Camera 4K G2
- Studio Camera 4K Plus, 4K Pro, 6K Pro, 4K Plus G2, 4K Pro G2

**Added by later firmware [P8]:**
- Camera 10.0 (17 Dec 2025): "new Camera Control REST API commands" for URSA Broadcast G2, **PYXIS 6K and PYXIS 12K**.
- Camera 10.3 (14 Sep 2026): REST API support improvements for URSA Cine 12K LF.

On hardware the API needs **Web Media Manager** enabled under Network Access in Blackmagic Camera Setup [P6]. **Pocket Cinema Cameras are not on the REST list.** They use Bluetooth and SDI camera control [P7].

**Shared?** Yes, it is the same API family: the same `/control/api/v1` base, the same self-description page and the same WebSocket protocol. The app implements a subset plus a few app-only endpoints [S6][S9]. Separately, the **iOS app as controller** can control PYXIS 6K (Camera 9.2, 20 Dec 2024) and URSA Cine (Camera 9.3, 21 Mar 2025) over the network [P8].

### 2.4 Bluetooth

Blackmagic documents a **Bluetooth LE Camera Control** protocol in [P7] (pp.109–110):
- Service UUID `291D567A-6D75-11E6-8B77-86F30CA893D3`.
- Encrypted characteristics for camera-control packets (the SDI Camera Control Protocol), timecode and status.
- Pairing with a 6-digit PIN.

This protocol is for **hardware cameras** (Pocket, URSA and others). **There is no evidence that the phone app exposes it.** In the app, Bluetooth is used only for accessories: Tentacle Sync E, Nucleus, gimbals and grips, mics and headphones [P2]. The Apple Watch and WearOS companions use a private channel. **For MUSE, Bluetooth control of the app is not an option.**

### 2.5 Other official developer material [P5]

- *RESTControl Demo 1.0* (HTML control panel for cameras and HyperDecks, Apr 2025).
- *Blackmagic Cameras Code Samples 1.2* (macOS/iOS: USB, Bluetooth and web camera control).
- Free developer e-mail registration and a developer support contact.

There is no app-specific SDK.

---

## 3. Getting footage and metadata out

### 3.1 Routes for the files themselves

| Route | Status |
|---|---|
| **Phone storage** | iOS saves in-app, to Photos, or to Files (internal or external SSD). Android saves to Gallery or Files, internal or external [P2]. Android testers find clips in `/sdcard/DCIM/Blackmagic Camera` [S8]. Filenames use Blackmagic or OS naming [P2]. |
| **Blackmagic Cloud** | Upload to DaVinci Resolve Cloud projects, Cloud Folders or personal storage. Auto-upload, proxy-only or originals + proxies. **Live Sync** while recording [P1][P2][P9]. **No public Blackmagic Cloud API**: none on [P5], [P9] or [P11], and no API found by search. Media leaves the cloud through DaVinci Resolve or the Cloud web UI. |
| **Dropbox / Google Drive** | **Not in the phone app.** Dropbox sync is a feature of Blackmagic **Cloud Store** NAS hardware. Blackmagic announced in Sep 2024 that Google Drive sync would be removed from Cloud Store [S14]. |
| **Sync clips to controller** | iOS setting "Sync Clips to Controller after Record" (since 3.0, Sep 2025) copies takes from remote phones to the controller (iPhone, iPad or Mac) [P2][P3][S15]. Where the clips land on a Mac controller is **not documented**. The Android spec page does not list this setting. |
| **REST API** | Clip *list* only. **No download** [S8]. |
| **Live stream** | RTMP/SRT to any server, configurable over REST (see 2.2). |

### 3.2 Metadata inside the clip (MOV/MP4)

Blackmagic does not document the key names. Evidence:
- **Official [P1][P2]:** slate fields "stored in the file", time-of-day timecode stored "in the file metadata", optional location data, and the colour-space tag.
- **User dumps [S12] (forum search snippets; forum blocked to direct fetch):** QuickTime `mdta` keys under **`com.blackmagic-design.*`**, e.g. `com.blackmagic-design.camera.iso`, `…camera.whiteBalance`, `…camera.aperture`, `…camera.lensType`, shutter, `…camera.dayNight`, `…camera.environment`, `…sensorFPS`, `…camera.guides.safe`. These sit alongside `com.apple.quicktime.software` ("Blackmagic Cam x.y"), `…model` and `…creationdate`. The same prefix appears on a Pixel 8 Pro clip.
- **Metadata library example (PyPI, May 2026) [S11]:** exiftool shows a `Blackmagic-design:` group (for example `CameraDateRecorded`) plus Apple ProApps production keys (reel, scene, shot, project, director, good take, day/night, int/ext). Extracted values include ISO 320, f/2.4, 1/120, WB 5600 K, sensor fps 59.993, and the lens model string (for example "iPhone 15 Pro Max back triple camera 6.86mm f/1.78").
- **Gyro / IMU:** **not documented and not observed.** Third-party iPhone workflows record gyro with a separate app (GyLog) for Gyroflow [S, kumoinc]. That suggests the app does not embed usable motion data.
- **Readable with standard tools:** `exiftool -a -G1 -s -ee`, `ffprobe` (colour primaries/transfer, timecode track, rotation), MediaInfo.

---

## 4. Licence and terms

- **Camera Control REST API and WebSocket:** the PDFs [P6][P7] contain **no licence text, no key, and no developer-program requirement**. They are published openly "for developers" and invite "custom applications" and tools such as Postman ("We look forward to seeing what you come up with!"). The developer page [P5] offers free e-mail registration and support. **No explicit terms bind third-party use**, and there is no stated permission for commercial integration either. Third-party commercial and OSS controllers exist openly (SKAARHOJ, Bitfocus Companion, others) [S9][S10].
  - **Recommendation:** use it, label it "works with Blackmagic Camera" with no logos or implied endorsement, and e-mail Blackmagic developer support before marketing it.
- **App terms:** the app is free. Blackmagic says it "does not collect any user data from this app" [P2], and the App Store privacy label says "Data Not Collected" [P3]. No app-specific API terms were found.
- **Blackmagic RAW SDK** (relevant only if MUSE ingests BRAW from hardware cameras; the phone app cannot record BRAW) [P10]:
  - Non-exclusive, non-transferable, revocable, royalty-free licence.
  - You may redistribute the **API libraries in object code** inside your own software and sublicense them to end users.
  - You may not redistribute the SDK itself, and may not reverse-engineer the libraries.
  - No warranty, and the licence can change.
- **No "Blackmagic Camera app SDK" exists.**

---

## 5. Ideas for MUSE, ranked by value against effort

**Value:** H, M or L. **Effort:** L, M or H.
**Basis:** ✅ verified in primary sources; ◐ relies on secondary or community-tested details; ✖ depends on something unverified or not available.

| # | Idea | Value | Effort | Basis |
|---|---|---|---|---|
| 1 | **"Shoot for Recast" preset pack and capture checklist** | H | L | ✅ preset import/export, vertical, open gate. ◐ preset file is undocumented JSON. |
| 2 | **MUSE Looks as Blackmagic Camera monitoring LUTs** | H | L | ✅ 17/33-pt 3D LUT import, monitor-only. ◐ `.cube` extension and "Record LUT to Clip" behaviour. |
| 3 | **Clip metadata ingest, auto camera spec and Recast QC on upload** | H | L–M | ◐ key names from user dumps. ✅ ffprobe colour/timecode. |
| 4 | **Android on-device auto-import of takes (prefer proxies)** | H | M | ✅ save to Gallery/Files and HEVC proxies. ◐ folder path. |
| 5 | **LAN remote record, settings and slate from the MUSE Mac/Android app, with the WebSocket bridged into MUSE's SSE** | M–H | M | ✅ REST API exists (3.4+). ◐ port 4444, TLS, no auth, endpoints. |
| 6 | **Phone "bodies" in the virtual camera, and a reverse preset** | M | L–M | ✅ spec ranges. ◐ `/lens/cameras`. |
| 7 | **Live phone preview inside MUSE (framing overlay for Recast)** | M | M–H | ◐ community-proven SRT/RTMP route. |
| 8 | **Mac as Blackmagic Camera controller, synced clips feed MUSE** | M | L | ✖ the Mac storage location for synced clips is undocumented |
| 9 | **Multi-angle performer capture (timecode-synced phones)** | M–L | L | ✅ |
| 10 | **Blackmagic Cloud as the MUSE inbox** | L | H | ✖ no public Cloud API |
| 11 | **Phone as a tracked camera for Blender/Directed mode** | n/a | n/a | ✖ not available |

### Details

1. **"Shoot for Recast" presets (H/L).** Build reference presets on one iPhone and one Android phone. Export them from the app and ship them with MUSE, then users tap **Import Preset** [P2]. Contents:
   - Exposure: manual ISO; shutter angle 180° (or 90 to 120° for crisper limbs and less blur for the swap model).
   - Colour: locked WB/tint. **Rec.709 SDR** (avoid HDR/HLG and Dolby-style HDR unless MUSE converts it).
   - Format: integer 24/25/30 fps; 1080p or 4K; HEVC or ProRes 422 LT.
   - Stabilisation Off or Standard (Cinematic/Extreme crops and warps).
   - **Proxies on.**
   - Vertical video plus a 9:16 guide, or **Open Gate** (iPhone 1920×1440, Android 3.1+) to reframe 9:16 and 16:9 from one take.
   - Slate fields pre-filled.

   This needs no API. Generating presets programmatically needs the undocumented `.cset` JSON (◐), so ship exported files instead.

2. **Looks as LUTs (H/L).** Export the 32 Looks as **33-point** 3D LUTs, because the app accepts only 17 or 33 points [P1].
   - Make **input-specific variants**: Rec.709 input (all phones), and Apple Log / Apple Log 2 input (iPhone Pro: concatenate Apple Log to 709 with the Look). O-Log2 for Oppo/OnePlus is optional.
   - Tell users to use **Display LUT** (monitor only) so MUSE receives clean footage. MUSE then applies the same Look in Edit, and what they saw is what they get.
   - **Limits:** import is manual (Files, then Import LUT). The API can toggle the display LUT but **cannot upload LUT files** [S6]. A preset can *select* an already-imported LUT by name (`lutSelection`) [S6]. Whether "Record LUT to Clip" bakes the LUT into the pixels or only tags the clip is **undocumented**, so test it.

3. **Metadata ingest and QC (H/L–M).** On upload, the server runs `exiftool -ee` and `ffprobe`. It maps `com.blackmagic-design.camera.*`, Apple keys and ProApps keys into the MUSE camera spec:
   - Body: phone model.
   - Lens: actual focal length (for example 6.86 mm) converted to a full-frame equivalent from the lens string.
   - Aperture, ISO, shutter as speed or angle, WB, sensor fps, colour space or transfer, timecode, reel/scene/take, GPS.

   Uses:
   - Recast matches motion blur, grain, DOF and white point.
   - Generated shots inherit the real camera.
   - QC flags HDR/HLG, Log without a LUT, variable fps, heavy stabilisation or low shutter.

   Build the key map from real clips on both platforms. The key names are not documented (◐).

4. **Android auto-import (H/M).** The MUSE Android app on the same phone watches MediaStore for new files in `DCIM/Blackmagic Camera` [S8 path].
   - It offers "Send take to MUSE", uploading the **1080p HEVC proxy** first [P2] for quick swap previews and the original later.
   - On iOS the equivalent is the share sheet or Files. iOS has no background folder watching, so this is a manual pick.

5. **LAN remote and slate (M–H/M).** From the MUSE Mac or Android app (not the cloud Node server, because the API is LAN-only):
   - Discover phones via Bonjour (`_http._tcp`, then try HTTPS :4444).
   - Pin the self-signed certificate on first use.
   - Before each take, `PUT /slates/nextClip` with the MUSE project, scene and take, so the clip carries IDs for automatic matching.
   - Start and stop with `PUT /transports/0/record`.
   - Push settings or presets.
   - Subscribe on the WebSocket and relay `transports/0/record` (take ended) and format changes as MUSE SSE events, for example "take A001_C012 recorded, waiting for upload".

   **Risks:**
   - No authentication: anyone on the LAN can drive the phone. Warn users and keep it on trusted Wi-Fi.
   - The app must stay in the foreground (screen awake on iOS).
   - App-only endpoints are undocumented and may change. Probe `/control/documentation.html` at connect time, as Bitfocus does [S9].

6. **Phone bodies in the virtual camera (M/L–M).** Add "iPhone 15/16/17/18 Pro" and "Galaxy/Pixel" bodies:
   - Real lens set (for example 13, 24, 48, 77 or 100 mm equivalents), fixed f/1.78-type apertures, ISO and shutter-angle ranges, and fps.
   - Colour pipelines: Rec.709, Apple Log, Apple Log 2.

   Generated inserts then intercut with real phone footage. In reverse, MUSE can output a preset that makes the phone match a chosen virtual camera (fps, shutter angle, WB, lens). Live lens enumeration via `/lens/cameras` is ◐.

7. **Live preview (M/M–H).** MUSE Mac runs an SRT or RTMP listener (MediaMTX or ffmpeg) and uploads a custom streaming platform through `/livestreams/customPlatforms/{file}`, then starts the stream.
   - Show the feed in MUSE with a **character silhouette or framing overlay** for the swap, and possibly a low-fps AI preview.
   - **Constraints [S6][S7]:** RTMP needs H.264 recording and an integer fps. SRT with HEVC works. Latency is about 0.2 to 0.5 s. It takes over the phone's active streaming platform, so restore it afterwards.

8. **Mac controller sync (M/L).** If Blackmagic Camera on the Mac (as controller) with "Sync Clips to Controller after Record" writes clips to a reachable folder, the MUSE Mac app can watch it. **Test first** (✖).

9. **Multi-angle capture (M–L/L).** Timecode-synced phones (Tentacle or ProDock) plus iPad/Mac multiview give several angles of one performance. MUSE groups uploads by time-of-day timecode for multi-angle Recast. No API is needed.

10. **Blackmagic Cloud (L/H).** There is no API. The only route is DaVinci Resolve on the Mac syncing a Cloud project, with MUSE scraping Resolve's media folder or using Resolve's scripting API (not verified here). This is fragile, so skip it.

11. **Tracked camera for Blender/Directed mode: not possible with this app.** It provides no pose, IMU stream or gyro metadata, only static lens, zoom and focus values. Use it only to seed the virtual camera's lens, fps and shutter. Live camera tracking needs an ARKit/ARCore app.

---

## Sources

**Primary**
- [P1] Blackmagic Design, *Blackmagic Camera* product page — https://www.blackmagicdesign.com/products/blackmagiccamera (accessed 6 Nov 2026)
- [P2] Blackmagic Design, *Blackmagic Camera Tech Specs* (iOS, Android, ProDock) — https://www.blackmagicdesign.com/products/blackmagiccamera/techspecs (accessed 6 Nov 2026)
- [P3] Apple App Store, *Blackmagic Camera* (v3.5.3, 23 Oct 2026; version history 1.2.1 to 3.5.3) — https://apps.apple.com/us/app/blackmagic-camera/id6449580241
- [P4] Google Play, *Blackmagic Camera* (v3.5.1, updated 29 Oct 2026) — https://play.google.com/store/apps/details?id=com.blackmagicdesign.android.blackmagiccam
- [P5] Blackmagic Developer, *Cameras: SDK and Software* (REST PDF and Camera Control PDF released 7 Aug 2025; RESTControl Demo; Code Samples 1.2) — https://www.blackmagicdesign.com/developer/products/camera/sdk-and-software
- [P6] *REST API for Blackmagic Cameras*, Developer Information, August 2025, 94 pp — https://documents.blackmagicdesign.com/DeveloperManuals/RESTAPIforBlackmagicCameras.pdf
- [P7] *Blackmagic Camera Control*, Developer Information, August 2025, 115 pp (REST, WebSocket, SDI, Bluetooth LE) — https://documents.blackmagicdesign.com/DeveloperManuals/BlackmagicCameraControl.pdf
- [P8] Blackmagic Support, camera firmware release notes (Camera 9.2 20 Dec 2024; 9.3 21 Mar 2025; 10.0 17 Dec 2025; 10.3 14 Sep 2026) — https://www.blackmagicdesign.com/support (downloads feed)
- [P9] Blackmagic Cloud Help, *Uploading to Cloud Storage from Blackmagic Cameras* — https://help.cloud.blackmagicdesign.com/cloud-storage/blackmagic-cameras/
- [P10] Blackmagic RAW / Developer SDK licence terms — https://www.blackmagicdesign.com/support/modal/download-with-terms-start/bmd-braw-sdk-2
- [P11] Blackmagic Cloud product page — https://www.blackmagicdesign.com/products/blackmagiccloud

**Secondary**
- [S1] Newsshooter, *Blackmagic Camera for iOS 3.4*, 21 Jul 2026 — https://www.newsshooter.com/2026/07/21/blackmagic-camera-for-ios-3-4/
- [S2] RedShark News, *Blackmagic Camera for iOS 3.4: what's new*, 23 Jul 2026 — https://www.redsharknews.com/blackmagic-camera-ios-3-4-update
- [S3] No Film School, *Blackmagic Camera for Android 3.4*, 16 Jul 2026 — https://nofilmschool.com/blackmagic-camera-for-android-update-3-4
- [S4] No Film School, *Blackmagic Camera for Android 3.5*, 8 Oct 2026 — https://nofilmschool.com/blackmagic-camera-for-android-3-5
- [S5] ProVideo Coalition, *Blackmagic Camera for Android 3.4 update released* (Jul 2026) — https://www.provideocoalition.com/blackmagic-camera-for-android-3-4-update-released/
- [S6] *LUCam iPhone Remote* README (tested app 3.5.3, iPhone 15 Pro) — https://github.com/lucaungaro/LUCam-iPhone-Remote
- [S7] *bmonitor* README (tested app 3.5) — https://github.com/dantearaujo/bmonitor
- [S8] *blackmagic-cam-remote* README, architecture doc and source (Android, Pixel 10, app 3.5.1) — https://github.com/skeplys83/blackmagic-cam-remote
- [S9] Bitfocus Companion *bmd-cameras* module and PR #7 "support Blackmagic Camera App 3.4 HTTPS Camera Remote API" (22 Jul 2026, open) — https://github.com/bitfocus/companion-module-bmd-cameras/pull/7
- [S10] SKAARHOJ wiki, *Blackmagic Camera App for Android/iOS* (tested 3.4.0) — https://wiki.skaarhoj.com/books/device-core-articles/page/blackmagic-camera-app-for-androidios
- [S11] *kurmann-medien-leser* 0.3.0 (PyPI, May 2026), Blackmagic Camera metadata example — https://pypi.org/project/kurmann-medien-leser/
- [S12] Blackmagic Forum, *Bugs in iPhone Blackmagic camera app* and *Blackmagic Camera App – Issues/Bugs* (metadata dumps; seen via search snippets, forum blocked to direct fetch) — https://forum.blackmagicdesign.com/viewtopic.php?t=202283
- [S13] D. Speiser, *Blackmagic REST API Tutorials: Media Management* — https://dylanspeiser.github.io/BM-API-Tutorial/5-Media-Management.html
- [S14] Newsshooter, *Blackmagic Design to remove Google Drive sync support*, 10 Sep 2024 — https://www.newsshooter.com/2024/09/10/blackmagic-design-to-remove-google-drive-sync-support/
- [S15] Newsshooter, *Blackmagic Camera 3.0 for iOS & Android*, 10 Sep 2025 — https://www.newsshooter.com/2025/09/10/blackmagic-camera-3-0-for-ios-android/
- [S, kumoinc] GyLog / Gyroflow iPhone ProRes RAW workflow — https://kumoinc-website.pages.dev/docs/workflows/iphone-prores-raw-gyroflow/
