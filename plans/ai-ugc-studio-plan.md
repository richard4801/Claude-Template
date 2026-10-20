# AI UGC Studio — Project Plan

_Status: **paused until funds are available** · Drafted 2026-10-20_

## 1. Goal
Build our own system (no OpenArt or similar third-party apps) that can:
- **Swap a full body and face** into a real recorded clip while keeping the original gestures, lip sync, and background (the style seen in @meerhustles' TikTok).
- **Generate images** (AI influencers, promo stills) tuned to our standard of realism.

**Phase 1 — Experiment:** Run a fresh TikTok account with AI influencer / UGC / promo content made by the system.
**Phase 2 — Business (only if Phase 1 proves it works):** Offer a subscription so companies can create UGC videos.

Target quality: as close to perfect realism as possible. Known weak spots to watch: fast hands, hair edges, teeth close-ups.

## 2. Key decisions so far
| Topic | Decision |
|---|---|
| Hardware | M1 MacBook runs the **app only**. AI work runs on a **rented cloud GPU** (an M3 wouldn't change this; these models need NVIDIA GPUs). |
| Video model | **MiniMax H3 (Hailuo 3.0)**, open weights, 33B, the **Ref2VA** (reference-to-video+audio) variant. To be confirmed by the test phase. |
| Interface | **Native Mac app**, no ComfyUI or node graphs. |
| Cloud | RunPod or Vast.ai, pay-per-use, GPU shuts down automatically when idle. |

## 3. MiniMax H3: facts & risks
- **License:** MiniMax H3 Community License. Excludes US, EU, UK, South Korea. **Nigeria is not excluded.** Commercial use is free under $20M annual revenue, **with attribution**.
- **Resolution:** open weights max out at **768p**. 2K is API-only. Plan: add an open-source upscaler step (768p → 1080p+).
- **Unproven:** no public demo yet of H3 doing a true performance-preserving body/face swap on existing footage. It may instead *recreate* the clip with the character. **The test phase decides this.**
- **Hardware need:** an 80GB GPU (H100 class).
- **Rules:** the acceptable use policy bans using real people's likeness without consent. Use original AI characters or ourselves only. Label AI content on TikTok.

## 4. Image generation
- **House style preset:** standard lighting, skin texture, camera feel, phone-photo realism, applied automatically.
- **Custom style LoRA** trained on our reference folder of best-quality images.
- **Character library:** influencers made in Images are reused directly in Video.
- ⚠️ **Licensing:** some image models are non-commercial (e.g. Flux **dev**). Before Phase 2, pick a commercially licensed model.

## 5. Mac app features
1. **Characters:** store each influencer (reference photos, LoRA, notes).
2. **Images:** generate with the house style; save picks to a character.
3. **New Video:** drag in a clip → pick character → choose number of takes → Generate.
4. **Automation:** start GPU → upload → run model → upscale (+ optional face cleanup) → download → **shut GPU down**.
5. **Results:** compare takes side by side; export for TikTok/Reels.
6. **Cost tracker:** cost per video and per month.

## 6. Budget (estimates, to be confirmed by testing)
**One-time**
| Item | Cost |
|---|---|
| Video test phase | $10–20 |
| Image test phase | ~$10 |
| Per character LoRA training | $5–15 |
| Mac app | $0 |

**Monthly**
| Item | Cost |
|---|---|
| Cloud storage for model files (100–150GB) | $7–15 |
| GPU time (~$2–3/hr, 10–15s clips, ~5–10 min each incl. retakes) | usage-based |

| Usage | ~Monthly total |
|---|---|
| Light (~20 videos) | $20–35 |
| Regular (~60 videos) | $45–80 |
| Heavy (150+) | $100+ |

**Bare minimum to start: ~$50**, then ~$25–40/month.
**Paying from Nigeria:** RunPod and Vast.ai accept crypto (USDT/USDC). A virtual dollar card (Grey, Chipper, etc.) is the alternative.

## 7. Content, accounts & earning model (corrected 2026-10-20)

**Content & accounts**
- Each AI influencer has **their own page** (presented as the creator). Multiple accounts, each run by a different person (e.g. one by girlfriend).
- Content: **trending sounds, dances, trending sayings/actions**, aimed at a **US/UK audience** (English trends, US/UK posting times and hashtags).
- **Label every realistic AI video** with TikTok's "AI-generated" label (rule updated Sept 2026). Consider "AI creator" in the bio.

**❌ Rejected: running a "UK" account from Nigeria to earn**
- Creator Rewards payouts verify **real residency** (local ID, tax info, bank). VPN or borrowed details → ban + withheld earnings.
- Creator Rewards only counts videos **over 1 minute**; trend clips (10–20s) don't qualify anyway.
- Sources conflict on whether **fully AI-generated** videos can earn from Creator Rewards; one official TikTok program excludes videos "produced primarily by AI". Treat creator payouts as a bonus, not the plan.

**❌ Rejected: undisclosed "casual" promotions**
- Illegal: UK (ASA/CMA) and US (FTC) require clear disclosure (e.g. **#ad**). TikTok requires the **Branded content** toggle.
- Instead: **natural but disclosed** promos, with the product built into the trend or a GRWM-style video, plus a small #ad.

**✅ Earning model**
1. **Brand deals & UGC orders** from US/UK companies, paid via Payoneer, Wise, or crypto (residency doesn't matter). Main income, and it becomes Phase 2.
2. **Affiliate links** where available.
3. **Canada partner (legit route to Creator Rewards):** a trusted person who **really lives in Canada** owns one account in **their own name, ID, and bank**, with a **written revenue-split agreement**. Canada appears on 2026 eligibility lists (confirm in TikTok Studio). They'd need long-form (1 min+) original content on that account to qualify. Thresholds: 18+, 10k followers, 100k views in 30 days, Personal account.

## 8. Free prep to do now
- [ ] Create the new TikTok account; post a little manually to warm it up (week 1: scroll in niche only; weeks 2–3: 1 simple post/day).
- [ ] Build a **reference folder** of 20–50 images and clips showing the exact realism/look we want.
- [ ] Sketch the first influencer: name, age, look, personality, niche.
- [ ] Set up a payment route (USDT or a virtual dollar card), plus Payoneer/Wise for receiving brand payments.
- [ ] Talk to the Canada contact about partnering on one account; draft a simple written split agreement.

## 9. Steps when funds arrive
1. Create a RunPod account and fund $15–20.
2. **Video test:** run MiniMax H3 Ref2VA on one of our clips plus one dedicated swap model for comparison. Judge realism, lip sync, and hands.
3. **Image test:** compare 1–2 image models against the reference folder.
4. Pick the winners and lock in settings.
5. Train the first character LoRA and the house style LoRA.
6. Build the Mac app around the chosen pipeline.
7. Produce content for the TikTok account and measure results.
8. **Phase 2 gate:** re-check MiniMax's license for offering it *as a service to clients*, confirm the image model is commercially licensed, then design the subscription.

## Sources
- [TikTok Creator Growth Challenge terms (official)](https://www.tiktok.com/legal/page/global/tiktok-creator-follower-challenge-program-terms-conditions/en)
- [Storrito: TikTok AI rules & Creator Rewards](https://storrito.com/resources/what-tiktoks-ai-monetization-restrictions-signal-for-creator-income/)
- [Storrito: TikTok AI labeling rules](https://storrito.com/resources/tiktoks-2026-ai-labeling-rules-and-what-they-signal-for-platform-governance/)
- [Toptal: joining Creator Rewards (Canada listed)](https://www.toptal.com/creator/post/how-to-join-the-tiktok-creator-rewards-program)
- [TT Calculator: Creator Fund countries 2026](https://ttcalculator.net/data/reference/creator-fund-countries/)
- [RunPod: MiniMax H3 open-weight video model](https://www.runpod.io/blog/minimax-h3-the-open-weight-omni-modal-video-model-and-what-it-takes-to-run-it)
- [Hugging Face: What is MiniMax H3 (Hailuo 3.0)?](https://huggingface.co/blog/ResterChed/minimax-h3-hailuo-3-0)
- [Atoms: MiniMax H3 license limits](https://atoms.dev/blog/minimax-h3-open-weights-multimodal-video-model)
- [Creative AI Show: H3 license catch](https://creativeaishow.com/minimax-h3-open-weights-the-free-33b-ai-video-model-with-native-audio-and-the-license-catch-for-us-creators/)
- [WaveSpeed: AI video models 2026 guide](https://wavespeed.ai/blog/posts/ai-video-generation-models-2026/)
