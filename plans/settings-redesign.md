# Settings redesign (Mac first)

Owner request, 2026-11-08: "Settings has too much on one page, poorly grouped, and overwhelms people." This file is the audit of every setting that exists today, the proposed structure, and what changes for members. The mock is in Mac CI's screenshots: `mac_settingsmock_<theme>_<shot>.png` (1280 × 800, all four themes), with today's sections beside it as `mac_settingsbefore_<section>.png`. **Nothing is built until the owner approves the mock.**

## 1. Audit: what Settings holds today (11 sections)

| Today's section | Who | What's in it |
|---|---|---|
| Appearance | everyone | Theme (4 tiles); Prompts → "Pro mode" (show and edit prompts); "Click on each camera stop" |
| Render defaults | everyone | Default render (Draft/Standard/HD); Export size (read-only "9:16, as rendered"); Keep test renders for (read-only "30 days"); owner: "House style and never-add lists" (a button to Prompts) |
| Costs & limits | everyone | Balance, This month, Draft video price (facts); Spend cap per job (read-only); Spend cap per day (read-only); Warn before a job goes over budget; Open credit |
| Studio | owner | Spend caps: per job, per person per day, whole studio per day, Save caps; AI editing helpers: switch, daily limit, Save limit |
| Engines | owner | Engine status list; Add-on engine (RunPod): max GPUs, who pays start-up, turn off when idle, time limit; Models (read-only: MiniMax H3, SeedVR2, LatentSync); Image engine (model, endpoint, Use this engine); the Video suite's engines panel (ladder, flags, provider cost) |
| Prompts | owner | The prompt library (every system prompt, the house style) and its editor |
| Archived models | owner | Archived models with Restore |
| Notifications | everyone | Open System Settings; Render finished; Render failed; Balance below $5; Also notify my Android phone; Send a test notification |
| Developer | everyone | Data source (MUSE server / demo); Server base URL with Reconnect, Test connection, Use the MUSE server; Fail next render; Reload everything; Performance readout |
| Connections | owner | Claude tokens (new, copy once, revoke); Claude and MCP setup snippets; Blender relay switch; Blender add-on install steps; In-app chat |
| About | everyone | Version; Fonts and licences; Terms of Service; Acceptable Use Policy; Account email with Sign out |

Outside Settings but related: **Credit** (its own page, highlighted under Settings), **Members** (sidebar, owner).

### What's wrong with it
- **Too many sections, split by implementation rather than by what people want.** Money is spread over Costs & limits, Studio (caps, helper limit) and Engines (who pays GPU start-up). The account and sign-out are at the bottom of About.
- **Members see developer tools** (server address, fail next render, performance) and an empty-looking set of read-only rows.
- **Owner-only internals at the same weight as everyday settings:** RunPod GPU counts and the image engine's endpoint sit next to "Render finished".
- **Jargon:** "Pro mode", "Render defaults", "Data source", "Engines", "Add-on engine (RunPod)".
- **Stale rows:** the Models list names engines the Suite no longer routes to by default, and "Export size" and "Keep test renders" are read-only facts dressed as settings.

## 2. Proposed structure: 6 sections, one hidden

Each section opens with one plain line saying what it's for. Within a section, groups are separated by space (no boxes); rarely-used detail sits behind a disclosure row.

| Section | Who sees it | Contents |
|---|---|---|
| **Account** | everyone | Who you are, role, Sign out (at the top); Appearance (theme tiles); Notifications (4 switches, Send a test, System Settings); About (version, terms); owner: "Show advanced settings" |
| **Studio** | everyone (owner extras) | New videos and photos: start at (Draft/Standard/HD/Cinema), show the prompt behind each render (was "Pro mode"), camera stop click, test renders kept for; owner: Prompts and house style (opens the library), Archived models (count, Show) |
| **Members** | owner | Invite someone; people with today's spend against their cap, Manage; invitations waiting (Resend); defaults for new members. The sidebar's Members (⌘8) opens this section. |
| **AI & spending** | everyone (owner edits) | Balance, this month, a typical price, Add credit (members: Ask for credit); spend caps (members see theirs read-only); warn before a job goes over budget; owner: AI editing helpers (one switch, limit in the hint), **Default models** (one row per purpose: shots per quality, photos, character swap, recast, extend, upscale, remove background, captions; Auto or a model; each screen's owner-only Model pill starts from it), behind disclosures: Our own GPUs, Price corrections |
| **Providers** (new) | owner | Bring your own provider (WS5): connected providers (key's last 4, when added, models on), Replace key, Remove; Add a provider (Replicate or fal, secure key field: checked, never shown again); the provider's models with search, filter (All/Video/Image/On), on/off switch, Rename, Image/Video tag, price. While the server has no key store yet: "Provider keys aren't set up on the server yet." |
| **Apps & devices** | owner | Claude: in-app chat status, each connected Claude app (token) with Revoke, Connect another Claude app, Setup guide; Blender: relay switch, add-on status and how to install; Phones: MUSE for Android |
| **Advanced** (hidden) | owner, when turned on | Server (MUSE server / demo, address, Test connection); Testing (fail next render, reload everything); Performance |

Members get three sections: Account, Studio, AI & spending. They never see provider or engine names (unchanged rule).

### One vocabulary: "Models"
Today the apps say "engines", "models" and "image engine" for the same thing. Everywhere in Settings and the composer it is **Models** ("Photo models", "Your providers' models", the composer's Model pill). "Engine" is dropped. Android (WS7) uses the same words.

### Renames (plain labels)
- "Pro mode" → "Show the prompt behind each render"
- "Render defaults" → "New videos and photos", "Default render" → "Start at"
- "Costs & limits" + "Studio" caps + "Engines" → "AI & spending"
- "Connections" → "Apps & devices"
- "Developer" → "Advanced" (off by default)
- "Data source" → "Server"

### Dropped as rows
- "Export size: 9:16, as rendered" (a fact, not a setting).
- The Engines "Models" list (MiniMax H3, SeedVR2, LatentSync): replaced by "which engine each quality uses", read from the registry.
- "Fonts" (licences move to a disclosure in About).

## 3. Questions for the owner
1. Members: move it from the sidebar into Settings (⌘8 still opens it), or keep both?
2. Advanced: hidden behind the Account switch (as drawn), or always the last item for the owner?
3. Providers: anything else you want on the provider row (spend this month with that key, a test call)?
