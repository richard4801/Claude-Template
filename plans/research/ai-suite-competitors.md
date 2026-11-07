# AI Suite: competitor UI and UX research for MUSE

Researched 2026-11-07. Sources are official docs, help centres, changelogs and company design write-ups where reachable. Several help centres blocked automated fetching (Runway article pages, Adobe HelpX web pages, Freepik docs, Midjourney HTML docs), so some claims rest on search-result excerpts of those official pages or on third-party guides. Each claim is labelled:

- **[official]**: the vendor's own docs, changelog or blog.
- **[3P]**: a third-party guide or review.
- **UNVERIFIED**: nothing reachable confirmed it.

I did not see any product screenshots directly. Anything about visual styling (spacing, colour, pixel layout) is out of scope and not claimed.

---

## Part 1: Product by product

### 1. Runway (Gen-4.5, References, Act-Two, Aleph, Agent, Workflows)

**Information architecture**
- After login there are four top-level modes: **Tools, Apps, Agent, Workflows**. Tools is described as the "traditional generation interface. Grants precise control over inputs and settings." [official] https://help.runwayml.com/api/v2/help_center/en-us/articles/37425232841875.json
- Using Tools, Apps or Agent automatically creates a **Session**. Sessions are "an organizational structure ... that help keep your outputs organized". [official] same URL
- Since Aug 2026, Agent sessions live inside **Projects**, and Project assets and Brand Kits are reachable from inside a session. [official] https://runway.com/changelog
- **History has moved over time.** Runway redesigned the Assets page in 2024 "to make it easier to find and reuse generations", added asset Tags in Jan 2025, and added a Comments tab on assets in Aug 2026. [official] https://runway.com/changelog
- **Navigation:** a "newly designed navigation sidebar makes it easier to access commonly used tools" (Jul 2024). [official] https://runway.com/changelog
- **Agent and timeline:** Runway is converging on one conversational surface. Chat Mode (Jun 2025) offered "a single conversational interface", and Agent (May 2026) lets you "describe the video you need, refine the direction together and generate it all in one conversation". Studio's timeline editor moved inside Agent in Jul 2026. [official] https://runway.com/changelog
- **Audio:** Text to Speech sits under an **Audio tab** within Tool mode (Dec 2025). [official] https://runway.com/changelog

**Composer**
- The model selector sits in the **bottom-left corner** in Tools mode. [official] https://help.runwayml.com/api/v2/help_center/en-us/articles/37425232841875.json
- You upload an image, write the prompt in the text box, then click "the purple Generate button". [official] same URL
- The aspect ratio is a button on the generation canvas, and the ratios offered depend on the model. [official, search excerpt] https://help.runwayml.com/hc/en-us/articles/37053594806419
- Gen-4.5 pricing is published per second: 12 credits/s, or 125 / 200 / 250 credits for 5 / 8 / 10 s. [official, search excerpt] https://help.runwayml.com/hc/en-us/articles/46974685288467
  - UNVERIFIED: whether the cost is shown on the Generate button itself.
- **References:** Layout Sketch for Gen-4 References (May 2025) lets you "Start from a blank canvas or draw on top of an existing image". [official] https://runway.com/changelog
- **Act-Two:** selected via an icon in the bottom-left of a session when the Gen-4 video model is selected. You upload a driving performance plus a character input, set options, and review the credit cost. [3P] https://monet.vision/blogs/how-to-use-runway-act-two
  - Voice changing happens "directly from within the Act-Two interface" (Aug 2025). [official] https://runway.com/changelog
  - The gesture-control toggle is described only by a third party [3P] https://aiwiki.ai/wiki/runway_act_two

**Results and iteration**
- "Your generations will be scrollable in your session as you generate." This is a vertical feed per session. [official] https://help.runwayml.com/api/v2/help_center/en-us/articles/37425232841875.json
- In the Gen-4 Image guide, new generations appear on the right side of the canvas. [official, search excerpt] https://help.runwayml.com/hc/en-us/articles/37327109429011
- A **"Use"** button under each finished generation opens follow-on actions, such as using the output as input elsewhere. [official] https://help.runwayml.com/api/v2/help_center/en-us/articles/37425232841875.json

**Camera and style controls**
- Gen-3-era Camera Control let you "Choose both the direction and intensity", and a "static checkbox" was added later. [official] https://runway.com/changelog
- Custom presets save "prompt text, camera movements, motion brushes" (Gen-2 era). [official] https://runway.com/changelog
- Custom Styles can be made from reference images in Frames. [official] https://runway.com/changelog
- For Gen-4.5 the UI favours prompt-described motion over dials. The help text says that for image-to-video you describe only the motion. [official] https://help.runwayml.com/api/v2/help_center/en-us/articles/37425232841875.json

**Mobile**
- The iOS app offers Gen-4.5 and Chat Mode. [official App Store] https://apps.apple.com/hk/app/runwayml/id1665024375?l=en-GB
- The mobile app got a generation feed (2024), and Act-One came to iOS (Nov 2024). [official] https://runway.com/changelog

**Clean versus cluttered**
- Clean: model picker in a fixed corner, one Generate button, session-scoped feed, and a single "Use" action that hands an output on.
- Cluttered: four parallel top-level paradigms (Tools, Apps, Agent, Workflows) plus Edit Studio. Users must first choose a way of working before choosing a task. This is my inference from the official mode list.

---

### 2. Kling AI (web app)

**Information architecture**
- The "Creative Studio" lists Image Generation, Video Generation, Motion Control, Agent and More Tools, each linking to app routes (`/app?designerRouteName=image|video|video-motion-control|agent`). Tools are separate routes rather than one composer. [official] https://kling.ai/quickstart and https://kling.ai/quickstart/image-to-video-guide
- An **Assets page** has an Elements section, the reusable character and subject library. [official] https://kling.ai/quickstart/klingai-element-library-3-user-guide

**Composer**
- Standard and Professional modes trade speed for quality. [official] https://kling.ai/quickstart/how-to-choose-video-mode
- Durations of 5 or 10 s and ratios of 16:9, 9:16 and 1:1 for image-to-video (older model). [official] https://kling.ai/quickstart/image-to-video-guide
- **Omni (3.0):**
  - References are named in the prompt as **@Image, @Element1 or a custom element name**.
  - Up to 7 images, or 4 images/elements plus 1 video.
  - Multi-shot is written as prompt lines such as "Shot 1 (2s): ...".
  - The page describes no separate shot-editor panel.
  - Native audio can be on or off. The cost table is per second: 6 to 16 credits depending on audio, resolution and video input.
  - [official] https://kling.ai/quickstart/klingai-video-3-omni-model-user-guide
- **Elements:**
  - Created from a "Create Element" button in the input box, or from Assets.
  - Steps: main image, auto-detected subject type, voice binding for characters, 1 to 3 extra angles, then name and description (with AI auto-description).
  - Inserted by typing **"@"** in the prompt or via "Add from Element Library". "Use Element" on the Assets page opens Omni with it pre-loaded.
  - [official] https://kling.ai/quickstart/klingai-element-library-3-user-guide
- UNVERIFIED: where the credit cost and the Generate button sit on screen.

**Camera and style**
- Six basic moves (horizontal, vertical, zoom, pan, tilt, roll) with adjustable "displacement parameters".
- Four "Master Shot" presets, such as "Move Left and Zoom In", each shown with an example clip.
- [official] https://kling.ai/quickstart/ai-camera-control-guide
- UNVERIFIED: whether the parameters are sliders.

**Mobile**
- Video elements can be recorded on the app only: "Tap to record a character video". [official] https://kling.ai/quickstart/klingai-element-library-3-user-guide

**Clean versus cluttered**
- Clean: the **Element** model, a named, reusable character with images, voice and description, inserted by @-mention. This is the closest analogue to MUSE "models".
- Cluttered: many parallel routes (Image, Video, Motion Control, Avatar, Lip sync, Agent) and many model versions. Multi-shot is hidden inside prompt syntax. These are inferences from the guide list.

---

### 3. Luma Dream Machine (Ray3, Boards)

**Information architecture**
- "Organize your projects in **boards** and view your complete collection under **Ideas**." [official] https://lumalabs.ai/changelog/welcome-to-the-all-new-dream-machine
- Projects, credits and creations sync between app and web. [official] same URL

**Composer**
- A single prompt bar starts a chat-like thread. [3P mobile teardown] https://screensdesign.com/showcase/luma-dream-machine
- Dragging an image into the prompt bar and adding text modifies it. [3P] same URL
- Mobile modes appear as tabs: "Describe", "Keyframe", "Modify" and "Reference". [3P] same URL
- **Draft Mode** is a toggle in the composer window. [official] https://lumalabs.ai/learning-hub/ray3-user-guide
- The model (Ray3 or Ray3 Reasoning) and HDR (a "Dynamic Range dropdown") are in a **settings panel**. [official] same URL
- Keyframes appear as "chiclets", with a scribble icon to open Visual Annotation (draw on the frame to direct it). [official] same URL
- UNVERIFIED: how cost is displayed.

**Results and iteration**
- Results live in the board thread. Iteration is chat-style: "brainstorm", "more like this" and "modify". [3P] https://recapio.com/digest/getting-started-with-dream-machine-by-luma-ai-by-luma-ai
- Brainstorm "explore[s] related ideas ... with guided suggestions". [official] https://lumalabs.ai/changelog/welcome-to-the-all-new-dream-machine
- The **draft-then-master** loop renders drafts cheaply, then "masters" a chosen draft to Hi-Fi 4K HDR. [official] https://lumalabs.ai/ray3

**Camera**
- Camera motions were typed into the prompt bar (12 motions in 1.6). [3P] https://venturebeat.com/ai/luma-ai-debuts-dream-machine-1-6-ai-video-generator-with-camera-motions
- Later "Camera Motion Concepts" let you combine moves through natural language. [official] https://lumalabs.ai/changelog/camera-motion-concepts-launch
- Contextual suggestions for shots and camera angles appear inline on mobile. [3P] https://screensdesign.com/showcase/luma-dream-machine

**Clean versus cluttered**
- Very clean: one bar and suggestions instead of panels.
- The weakness is discoverability. Camera control by typed concept means users must know the vocabulary. This is my inference.

---

### 4. Pika

**Information architecture**
- Feature-branded tools: Pikaffects, Pikaframes, Pikascenes, Pikaswaps, Pikadditions and Pikatwists. [3P] https://www.techradar.com/computing/artificial-intelligence/what-is-pika-art-everything-you-need-to-know-about-the-ai-video-generator
- The Discover area has trending templates by category. [3P] https://www.capcut.com/resource/pika-labs-ai
- Pikaframes length is 1 to 10 s on Pika 2.2. [official] https://pika.art/faq
- Pikaffects are chosen from an option at the bottom of the screen, then you upload an image and generate. [3P] https://www.capcut.com/resource/pika-labs-ai

**Mobile**
- The iOS app ("Pika AI Video") is effect- and template-led. [official App Store] https://apps.apple.com/us/app/pika-ai-video/id6680155400

**Status**
- UNVERIFIED: current composer layout, cost display and camera controls. No official doc was reachable.

**Takeaway**
- Templates and effects as one-tap entry points work for casual users. Branded feature names ("Pika-x") make the information architecture opaque. This is an inference.

---

### 5. Krea (Video, Realtime, Nodes)

**Information architecture**
- Krea's redesign write-up:
  - "Every tool now lives in one sidebar, one click away."
  - "Sessions carry over between them, and live indicators show what's running."
  - Pinning favourite tools and setting defaults.
  - Global session search.
  - "controls that stay hidden until you need them".
  - Homepage cut to "a third the size".
  - Animation delays removed.
  - Mobile "rebuilt as its own experience", not desktop shrunk.
  - The design question was: "is this helping you make something, or is it in the way."
  - [official] https://www.krea.ai/blog/redesign
- Outputs can be dragged between tools ("Upscale something you just generated by dragging it straight into the enhancer"). [official] same URL

**Composer (Video)**
- Central prompt box; settings beneath it (aspect, duration, resolution, start image, end image).
- "Not all models support all settings."
- Model picker in the bottom-left.
- Left panel lists previous sessions.
- [official] https://www.krea.ai/docs/user-guide/features/video
- The model list shows **cost, speed and what it is good at** for every model. [official] https://www.krea.ai/blog/redesign
- Docs tables give speed x/3, quality x/3 and approximate credits per model. [official] https://www.krea.ai/docs/user-guide/features/video

**Iteration**
- Hover a clip and click **Extend**, which continues from the final frame. [official] same URL

**Realtime**
- Canvas on the left, live output on the right.
- Input modes: Draw, Upload, Webcam, Text.
- Image/Video toggle under the prompt.
- [official] https://docs.krea.ai/realtime

**Nodes**
- A node workflow builder whose graphs can be turned into shareable apps. [official] https://www.krea.ai/docs/user-guide/features/nodes

**Clean versus cluttered**
- Krea's redesign is explicitly an anti-bulk exercise. It is the best published rationale for the brief MUSE has.
- Risk: the sidebar list keeps growing (Image, Video, Realtime, Motion Transfer, 3D, Nodes, Edit, Enhancer, Lipsync, Restyle, Train). [3P snapshot] https://www.krea.ai/docs/user-guide

---

### 6. Higgsfield (Cinema Studio, presets)

**Information architecture**
- Cinema Studio is entered from the top navigation bar. [official] https://higgsfield.ai/blog/cinema-studio-guide
- A version selector at the top switches from 2.0 to 4.0. Version 4.0 is the default, and versions were kept because users asked. [official] https://higgsfield.ai/creator-hub/help-center/tools-and-workflows/how-do-i-use-cinema-studio and https://higgsfield.ai/blog/how-we-built-cinema-studio

**Composer (Cinema Studio 4.0)**
- **Prompt box shortcuts:** "#" opens the camera-move picker, and "@" inserts saved characters or locations. A chosen move "appears in the prompt as a **chip**". [official] https://higgsfield.ai/blog/cinema-studio-3.5-full-tutorial
- A "References" button sits above the prompt box. [official] same URL
- **Director's Panel sections** [official] https://higgsfield.ai/creator-hub/help-center/tools-and-workflows/how-do-i-use-cinema-studio and https://higgsfield.ai/blog/cinema-studio-3.5-full-tutorial:
  - **Camera:** body (e.g. 35mm Film, DV Camcorder), lens (Clean Sharp to Anamorphic to vintage), aperture (f/1.4 Wide Open to f/11 Deep Focus), and Movement.
  - **Lighting:** 6 named presets (Contre jour, Soft cross, Silhouette, Practicals) or a custom setup for colour, brightness, diffusion and angle.
  - **Color Palette:** "Auto" by default, 50+ named grades (e.g. "Twilight Fable"), or "New palette".
  - **Film Setup:** genre, era, and tempo (Auto, Single shot, Dynamic, Chaotic).
  - Plus duration, resolution, aspect ratio and sound.
- **Cost shown on the Generate button**: e.g. 80 / 160 / 240 credits for 5 / 10 / 15 s at 1080p with sound. [official] https://higgsfield.ai/blog/cinema-studio-3.5-full-tutorial
- **Project-level style:** in 3.5, genre and Camera MoveSet were global per project and camera, lens, focal length and aperture were per shot. "So the style is chosen once." [official] https://higgsfield.ai/creator-hub/help-center/tools-and-workflows/how-do-i-use-cinema-studio and https://higgsfield.ai/blog/how-we-built-cinema-studio
- The **"Recreate" link** on example prompts opens the generator pre-filled. [official] https://higgsfield.ai/blog/cinema-studio-3.5-full-tutorial
- UNVERIFIED: whether 4.0 pickers are image cards or lists.

**Design rationale (company write-up)** [official] https://higgsfield.ai/blog/how-we-built-cinema-studio
- The first version "kept three settings: camera, lens, and focal length", and everything else was cut.
- The picker was built "to feel like loading a real rig": open the camera picker, "roll the wheel", match lens and focal length.
- Lens effects were exaggerated so that each choice visibly changes the shot.
- "Now you choose a genre, and the camera moves the way that genre moves." Genre is a macro control that replaces manual moves for novices.
- A prompt enhancer means "you don't strain yourself much".

**Results and iteration**
- Image batches show in a 2x2, 3x3 or 4x4 grid. "Create 3D scene" turns a still into a spatial view for picking a new keyframe. [official] https://higgsfield.ai/blog/cinema-studio-guide
- 4.0 video modes: References (new clip), Forward/Backward Extend, and Edit Video. "Save to Elements" reuses a character. [official] https://higgsfield.ai/creator-hub/help-center/tools-and-workflows/how-do-i-use-cinema-studio

**Clean versus cluttered**
- Clean: rig-as-panel with named, opinionated presets and "Auto" defaults, and cost on the button. This mirrors MUSE's rig almost exactly.
- Cluttered: multiple coexisting versions, each with different control sets, and a broad catalogue of preset apps outside Cinema Studio. Reviewers praise the clean UI [3P] https://www.g2.com/products/higgsfield/reviews

---

### 7. Google Flow (Veo, and other models)

**Information architecture**
- **Projects** each hold a media grid.
- The left side lists media types: All media, Images, Videos, Characters, Scenes and Uploads, with search and filters.
- Collections work as nested folders, made by dragging one tile onto another.
- View modes are Grid or Batch ("generations one after another next to details"). Grid size and "Show tile details" are adjustable.
- [official] https://support.google.com/flow/answer/16935308?hl=en
- **Tools** sit in the left menu. These are natural-language-built mini-apps that you can favourite (global) or pin (per project). Output from a Tool goes to the open project. [official] https://support.google.com/flow/answer/17104535?hl=en

**Composer**
- One **prompt box** per project.
  - An **"Agent" toggle** in the prompt box.
  - Standard mode: click the **model name**, choose "Video", then **"Frames"** (start/end: "+ Add start frame" and "+ Add end frame") or **"Ingredients"** (references).
  - Settings: aspect ratio, number of outputs, model, length.
  - [official] https://support.google.com/flow/answer/16353334?hl=en
- Adding ingredients: drag files in, type **"@"** to pull project assets, or use "Add" under the prompt. [official] same URL
- A "Clear prompt on submit" setting governs whether references persist. [official] https://support.google.com/flow/answer/16935308?hl=en
- A personal avatar is inserted with **"@me"** and managed from the profile menu. It is created by phone scan via QR code. [official] https://support.google.com/flow/answer/17102997?hl=en
- UNVERIFIED: in-composer cost display. Credits have their own article: https://support.google.com/flow/answer/16526234?hl=en

**Results and iteration**
- Every edit is saved to the asset's **stack**. A **History panel** shows previous versions and the prompts used. [official] https://support.google.com/flow/answer/16935718?hl=en
- **Extend** sits at the bottom of a clip. [official] same URL
- Conversational edit allows "up to 3 conversational turns". [official] same URL
- Edit modes: insert, remove and camera. [official] same URL
- **Scenebuilder:** "Add to Scene" from a clip's More menu, drag to reorder, trim handles. [official] same URL
- "Save frame" captures a still for reuse. [official] same URL

**Clean versus cluttered**
- Clean: one composer whose mode is chosen through the model-name menu, "@" references, version stacks instead of duplicate tiles, and media-type filters in place of separate galleries.

---

### 8. OpenAI Sora app (discontinued)

- The Sora app and web shut down on 26 Apr 2026, and the API ends 24 Sep 2026. [3P news] https://the-decoder.com/openai-sets-two-stage-sora-shutdown-with-app-closing-april-2026-and-api-following-in-september/ and https://engadget.com/ai/openai-is-shutting-down-its-sora-video-generation-app-211023358.html
- Historical patterns:
  - TikTok-style vertical feed.
  - **Remix** as a primary action ("small changes often beat brand new prompts").
  - **Cameo**: a consented personal likeness with audience permissions such as "Mutuals".
  - Storyboard selected from options in the composer.
  - [3P] https://www.maginative.com/article/openai-launches-sora-2-and-a-tiktok-style-app-to-use-it/ and https://filmora.wondershare.com/trending-topic/how-to-use-sora-2-storyboard.html
- Lesson for MUSE: the likeness and consent model for characters is worth copying. A social feed as the home screen is not, for a creator tool. That is an inference, partly supported by the reported usage decline [3P] https://the-decoder.com/openai-sets-two-stage-sora-shutdown-with-app-closing-april-2026-and-api-following-in-september/

---

### 9. Midjourney (web Create page, video)

**Information architecture**
- Website sections include Create, Organize and Explore. [official, search excerpt] https://docs.midjourney.com/docs/explore-page

**Composer**
- The **Imagine bar** is where you type prompts. Its **settings icon** opens a panel of defaults applied to all prompts: Stylization, Weirdness, Variety, and more. [official, search excerpt] https://docs.midjourney.com/docs/create-page
- Stylize is described as "a slider". [official, search excerpt] https://docs.midjourney.com/docs/stylize
- The image icon in the Imagine bar opens an uploads panel for the starting frame. [official, search excerpt] https://docs.midjourney.com/docs/video
- Settings → More Options holds Video Batch Size and Video Resolution. Text parameters (`--motion`, `--bs`) mirror the UI. [official] https://docs.midjourney.com/api/v2/help_center/en-us/articles/37460773864589.json

**Results and iteration**
- Animate buttons sit under "Creation Actions" when you open an image, with a hover shortcut on the Create page.
- **Auto** generates immediately. **Manual** opens the prompt in the Imagine bar to edit first. **Loop** matches the first and last frames.
- Low or High Motion buttons.
- Extend Auto/Manual on hover: +4 s each, up to 4 times.
- Hover to play, Ctrl/Cmd plus mouse movement to scrub.
- [official] https://docs.midjourney.com/api/v2/help_center/en-us/articles/37460773864589.json
- Cost is expressed as GPU time in docs (e.g. SD batch of 4 is about 8 minutes). UNVERIFIED: an on-screen cost readout.

**Clean versus cluttered**
- Clean: one bar, settings as *defaults* rather than per-job forms, and the **Auto / Manual split** on every follow-up action (one click, or edit first).
- Video is an *action on an image*, not a separate tool.

---

### 10. Freepik AI Suite (reportedly rebranded Magnific, Apr 2026)

**Information architecture**
- Separate generators (Image, Video and others) plus **Spaces**, a node canvas.
- Spaces adds nodes through **Spotlight**, a command palette opened with Space or "/", through the left sidebar "+ Add element", or by right-click.
- One Text node can feed several generators.
- Spaces auto-save.
- [official, search excerpt] https://www.freepik.com/ai/docs/your-first-space and https://pl.freepik.com/ai/docs/nodes-and-connectors
- Rebrand claim: [3P, single source] https://yespress.io/freepik-ai-suite

**Composer (Video Generator)**
- The model picker sits in the settings panel next to the prompt field. You can browse by provider, search by name, or pick **Auto** to let the platform choose. [official, search excerpt] https://www.freepik.es/ai/docs/video-ai-models
- Costs are per second and vary by model and resolution. [official, search excerpt] https://no.freepik.com/ai/docs/video-ai-models
- "Hover over Generate for an exact total". [official, search excerpt] https://www.magnific.com/ai/docs/ai-video-generator-credits
- A prompt-improver button. [search excerpt] https://th.freepik.com/ai/docs/your-first-ai-video
- UNVERIFIED: camera preset UI.

**Clean versus cluttered**
- An aggregator with dozens of models. "Auto" model selection is the main defence against model-picker overload.

---

### 11. Hailuo / MiniMax

- Create page flow: AI Create → Video, then a scene description, camera cues, duration, and optional Subject Reference ("Add Reference Character"). [3P] https://www.nemovideo.com/blog/ai-video-generator/hailuo-ai-beginner-guide and https://hallowed-ravioli-d31.notion.site/Hailuo-AI-tutorial-21b1b78a1a84809faeb1f034cf5c99a9
- Director models take **bracketed camera commands** in the prompt (e.g. `[Pan left,Pedestal up]`, up to 3 combined). Natural language also works, but brackets are more accurate. [3P model host] https://fal.ai/models/fal-ai/minimax/video-01-director/llms.txt
- The official S2V-01 subject reference announcement: https://www.minimax.io/news/s2v-01-release
- UNVERIFIED: the current hailuoai.video layout, cost display, and whether a camera button exists.
- Takeaway: camera moves expressed as insertable tokens in the prompt, which Higgsfield refined into chips.

---

### 12. Hedra (talking characters)

**Information architecture**
- The primary surface is a **Space**: "a persistent, living canvas the agent writes to and reads from".
- **Manual tools** cover the four direct operations: Image, Video, Speech and Edit Video.
- [official] https://www.hedra.com/docs/pages/app/getting-started/manual-tools.md and https://www.hedra.com/docs/pages/app/content-creation/speaker-selection

**Composer**
- Manual-tool flow: choose tool and model → add references or source media → prompt or script → output controls → Generate → review in the **Library**. Library assets can be picked as inputs. [official] https://www.hedra.com/docs/pages/app/getting-started/manual-tools.md
- Avatar: Manual tools → Video → **Avatar**, then a model from a filtered catalogue. [official] https://www.hedra.com/docs/pages/app/content-creation/speaker-selection
- **Speech tool**: voice selector with preview, a script editor with a visible character limit, synthesis settings behind a button, and a **Control menu opened by "/"** that inserts emotion, energy and pacing tags. [official] https://www.hedra.com/docs/pages/app/content-creation/create-audio.md
- Results appear in a History panel on the right. [official, search excerpt] https://hedra.com/docs/pages/studio/content-creation/create-audio

**Takeaway**
- Voice direction as inline slash-tags inside the script, not a separate form. This is directly relevant to MUSE "Talking".

---

### 13. Captions / Mirage

- The Generate Video section lists AI Creator, Prompt to Video, AI Twin, AI Ads and Lipdub. [official] https://help.mirage.app/introduction
- Flow: "pick an avatar, paste or generate a script, then create the full video at once". Captions, editing style and length are adjusted *after* generation. [official] https://captions.ai/help/mirage/mirage-studio-guide
- Script limit 10 to 800 characters, maximum 1 minute. [official] https://captions.ai/help/docs/feature-availability
- Takeaway: three-step linear flow (who, what they say, generate), with refinement deferred to after the result.

### 14. Arcads and Creatify (UGC ads)

- **Arcads**: write or generate a script (including from a product URL), pick an actor from a filterable library (gender, age), and generate. Actor and voice swap allows A/B variants. It is not an editor, and actors reportedly cannot hold the product. [3P] https://www.eesel.ai/blog/arcads-ai and https://www.codingem.com/arcads-ai-review/
- **Creatify Batch Mode**: paste a product URL → pick multiple scripts and avatars → preview → render up to about 10 variations. [official marketing] https://creatify.ai/features/batch-mode and [3P] https://www.unite.ai/creatify-review
- Takeaway: the **product URL is the starting input**, and the matrix (scripts × actors × ratios) is the core UI.

### 15. CapCut desktop

- AI generation lives in the editor's **left media panel**: "AI media" > "AI video". [official] https://www.capcut.com/resource/how-to-use-capcut-on-pc
- The right side holds editors, for example text-to-speech script entry. The player is in the centre and the timeline at the bottom. Export is top right. [official] same URL
- A standalone "AI video maker" on the home screen is in a staged rollout. [official] https://www.capcut.com/help/find-ai-video-maker-in-capcut-desktop
- Takeaway: generation is a *media source* inside the editor. Generated clips land in the same panel as imported media, ready to drag to the timeline.

### 16. Adobe Firefly (video)

- The Generate video settings panel has a **Camera** section with dropdowns [official, search excerpts]:
  - **Shot size**: None (default), Extreme close up, Close up, Medium, Long, Extreme long.
  - **Camera angle**: None, Aerial, Eye level, High, Low, Top down.
  - **Motion**: Zoom in/out, Move left/right, Tilt up/down, Static, Handheld.
  - Sources: https://helpx.adobe.com/ca/firefly/work-with-audio-and-video/work-with-video/generate-videos-using-text-prompts.html and https://helpx.adobe.com/firefly/mobile/work-with-audio-and-video/work-with-video/set-shot-size-and-angle-for-videogeneration.html
- **Motion reference**: upload a video to extract its camera movement. [official, search excerpt] same web URL
- **Explicit conflict handling**: a motion reference disables shot size, angle and motion, and an uploaded image disables them too. In the Figma plugin, first/last frames disable shot size, angle and style. [official, search excerpts] same URLs and https://helpx.adobe.com/firefly/web/app-integrations/figma/generate-videos.html
- Mobile shows different options, and partner models don't support the extra camera settings. [official, search excerpt] https://helpx.adobe.com/firefly/mobile/work-with-audio-and-video/work-with-video/set-shot-size-and-angle-for-videogeneration.html
- Takeaway: "None" as the default for every camera field, which means not forced. Fields are disabled when an input already determines them.

### 17. Cross-industry design note

- A design review of AI-video apps recommends:
  - keeping source, motion, format, duration, audio and cost visible as separate decisions;
  - showing thumbnails of the exact media a video will inherit;
  - named progress stages instead of fake percentages;
  - preserving every input after a failure;
  - targeted refinement before a generic regenerate;
  - upsell only at the moment a premium option is chosen.
  - [3P] https://screensdesign.com/articles/ai-video-generator-app-design/
- Cost on or next to the Generate button is a common convention across many generators. [3P/vendor docs, search excerpts] https://workroom.everypixel.com/help/generate-a-video and https://help.sundaysky.com/hc/en-us/articles/34241920162461

---

## Part 2: Synthesis

### Recurring strong patterns (12)

1. **One composer, mode chosen inside it.**
   - Flow picks Video, Frames or Ingredients from the model-name menu.
   - Midjourney uses one Imagine bar for image and video.
   - Krea puts settings under one central prompt box.
   - Luma uses one prompt bar.
   - Tools differ by *inputs*, not by separate pages with separate layouts.
2. **The model picker lives in a fixed corner chip and explains itself.**
   - Runway and Krea both put it bottom-left.
   - Krea shows cost, speed and strength for each model.
   - Freepik offers "Auto".
3. **@-mention for reusable subjects.**
   - Kling `@Element`, Flow `@asset` and `@me`, Higgsfield `@` characters and locations.
   - The character is a *noun in the sentence*, not a form field.
4. **The persistent character is a first-class library object.**
   - Kling Elements: images, angles, voice, name, description, plus "Use Element".
   - Higgsfield "Save to Elements". Flow avatar. Sora cameo.
   - Each is created once, then referenced everywhere.
5. **Rig expressed as named, opinionated presets with "Auto"/"None" defaults.**
   - Higgsfield: camera body, lens, aperture, 50+ named grades, 6 lighting schemes, genre/era/tempo, everything defaulting to Auto.
   - Firefly: None defaults.
   - The user never has to set anything.
6. **Macro controls over micro controls.**
   - Higgsfield's "choose a genre, and the camera moves the way that genre moves".
   - Midjourney's Low/High motion.
   - Kling's Master Shots.
   - One meaningful choice replaces several parameters.
7. **Camera moves as chips or tokens inserted into the prompt.**
   - Higgsfield `#` makes a chip. Hailuo uses `[Pan left]`. Luma uses typed concepts.
   - The prompt stays the single source of truth, and chips make it legible.
8. **Settings are defaults, not a per-job form.**
   - Midjourney's settings panel applies to all prompts.
   - Krea lets you set defaults.
   - Higgsfield 3.5 sets project-level style "chosen once".
9. **Cost on the Generate button, updating live.**
   - Higgsfield shows it on the button. Freepik/Magnific shows the exact total on hover.
   - Runway and Kling publish per-second tables.
10. **Results as a session feed or project grid, with versions stacked.**
    - Runway session feed. Flow grid/batch views plus asset stacks and a History panel.
    - Krea session list with search.
11. **Every output carries a short, consistent action set.**
    - Runway "Use". Midjourney Animate/Extend with Auto vs Manual. Krea/Flow Extend.
    - Flow Save frame and Add to Scene. Krea drag-to-enhancer.
    - Outputs flow into the next tool rather than being downloaded and re-uploaded.
12. **Progressive disclosure plus speed.**
    - Krea: "controls that stay hidden until you need them", a smaller homepage, no animation delays.
    - Luma: a Draft Mode toggle for cheap iteration, then master the winner.

### Anti-patterns to avoid

- **Parallel paradigms at the top level.** Runway has Tools, Apps, Agent, Workflows and Edit Studio, so users choose *how* to work before *what* to make.
- **A sidebar that lists every model or feature as its own destination.** Krea's growing list, Kling's routes and Pika's branded "Pika-x" names. Each new tool adds a nav item and a new layout.
- **Version sprawl inside the UI.** Higgsfield keeps 2.0 to 4.0 selectable, each with different controls.
- **Hidden syntax as the only control.** Hailuo brackets, Luma typed camera concepts, Kling multi-shot written as "Shot 1 (2s)" text: powerful but undiscoverable without a visual picker.
- **Silently conflicting settings.** Firefly is the counter-example: it disables shot and angle when an image or motion reference determines them. Show *why* a control is disabled.
- **Cost revealed only after the click**, or only in docs (Midjourney GPU-minutes, many per-second tables).
- **A social feed as home** for a creator tool (Sora).
- **Dropdown-only camera lists** (Firefly). They are legible but low-signal. Higgsfield shows the value is in *visible* difference and named looks.

### Recommended IA and composer for MUSE's AI Suite

**Top-level places (four, plus Settings)**
1. **Create**: the single composer plus the current session feed.
2. **Library**: all outputs. It has filters by type (Video, Photo, Audio) and by character, version stacks, collections and search. This mirrors Flow's media-type list and Krea's search.
3. **Models**: MUSE's persistent characters, each with images, angles, voice, a default rig and a "Use" action. This mirrors Kling Elements.
4. **Edit**: the timeline editor plus Storyboard sequencing. Camera stage opens from here or from a shot as a full-screen mode, not a nav item.

**One composer, task chosen by a mode chip**
- **Fold the eight tools into a mode chip at the left of the composer, grouped by input:**
  - **Generate:** Shot, Photo, Storyboard.
  - **From a clip:** Character swap, Recast, Extend & upscale.
  - **Performance:** Talking, UGC ad.
- **The mode only changes the input slots** above the prompt:
  - Shot: optional start/end frame.
  - Swap/Recast: source clip plus a picker for which person.
  - Talking: script or voice with Hedra-style "/" emotion tags.
  - UGC: product URL or image, plus an optional variants matrix.
- **Prompt row:** a large prompt field with `@` for Models, products and Library assets, and `#` to insert a camera-move chip.
- **Rig row (one line of chips under the prompt):**
  - Chips: Camera · Lens · Light · Look · Style · Move.
  - Each chip shows its current value, or "Auto".
  - Tapping a chip opens a popover of **named visual presets** (thumbnail or loop per option), modelled on Higgsfield.
  - Fine values (focal length, aperture, angle/framing) sit inside that popover behind "Custom".
  - Chips the current mode or input already determines are greyed out with a reason, as Firefly does.
- **Rig presets:** the whole rig can be saved as a named preset, and each Model can carry a default rig. Style is then "chosen once", as in Higgsfield.
- **Right of the row:** a model chip (with "Auto") in a fixed position, the output count, aspect and duration, and a **Generate button showing the live credit cost**.
  - On Mac, put Draft/Final toggles here as Luma does.
  - Advanced or rare parameters go behind a single "…".

**Results and iteration**
- Results go in a session feed above or beside the composer, with version stacks.
- Each result gets a fixed action set:
  - **Vary** (Midjourney-style Auto or Manual)
  - **Extend**
  - **Upscale**
  - **Use as frame**
  - **Use as reference**
  - **Add to Storyboard**
  - **Open in Edit**
  - **Save rig**
- Selecting a result loads its full rig and prompt back into the composer.

**Mobile (Android)**
- Same model, rebuilt rather than shrunk (Krea's lesson).
- The composer is a bottom sheet with the mode chip and prompt.
- The rig row scrolls horizontally, and each chip opens a full-height sheet of preset cards.
- Library and Models are tabs.
- Edit and Camera stage can stay Mac-first, or be reduced to a trim-and-sequence view.
