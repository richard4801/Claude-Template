// AI suite · the virtual cinema (plans/ai-suite.md "Camera"). One Camera control for every video surface: a CameraSpec
// (rig, lighting, palette, move with intensity, angle and framing, style, optional guide clip) that suite/compile.ts turns
// into what each model can consume. Labels and descriptions here are member-facing; the wording sent to models lives in
// the prompt library (keys suite.camera.*, owner-editable, one "id: wording" per line) with these defaults.
import { z } from 'zod';

export type Option = { id: string; label: string; description: string; wording: string };
export type MoveOption = Option & {
  category: 'static' | 'push' | 'lateral' | 'rotate' | 'vertical' | 'zoom' | 'follow' | 'aerial' | 'specialty' | 'time';
  /** Distance or angle at intensity 0 and 1 ("0.8 m", "60°"), for the {amount} placeholder. */
  amount?: [number, number, string];
  /** The LTX camera_motion value that matches, if any. */
  ltx?: string;
  /** What the model must not do instead ("no zoom"). */
  avoid?: string;
  /** Best done in the editor rather than generated (models smear it). */
  editorBetter?: boolean;
  /** Fine for talking / lip sync shots. */
  talkSafe?: boolean;
};

const o = (id: string, label: string, description: string, wording: string): Option => ({ id, label, description, wording });

// ---------------------------------------------------------------- rig
export const BODIES: Option[] = [
  o('phone', 'Phone', 'Modern smartphone: deep focus, natural HDR', 'a modern smartphone camera, deep focus, natural HDR, true-to-life colour'),
  o('vlog', 'Vlog camera', 'Compact creator camera, crisp and bright', 'a compact vlogging camera, crisp detail, bright creator look'),
  o('cinema_digital', 'Cinema digital', 'Large-format digital cinema camera, clean and rich', 'large-format digital cinema camera, clean high-dynamic-range image, rich skin tones'),
  o('super35', 'Super 35 digital', 'Classic S35 cinema sensor', 'Super 35 digital cinema sensor, filmic highlight roll-off'),
  o('film_35', '35mm film', 'Fine grain, halation, organic colour', '35mm motion-picture film, fine grain, gentle halation, organic colour'),
  o('film_16', '16mm film', 'Visible grain, softer, indie feel', '16mm film, visible grain, softer detail, indie documentary texture'),
  o('film_8', 'Super 8', 'Home-movie grain, gate weave, warm', 'Super 8 home-movie film, heavy grain, slight gate weave, warm faded colour'),
  o('large_format_65', '65mm large format', 'Epic, huge sensor, shallow depth', '65mm large-format film camera, epic scale, extremely shallow depth of field, pristine detail'),
  o('camcorder', 'DV camcorder', '2000s camcorder: video texture, sharpening', 'early-2000s DV camcorder footage, video texture, edge sharpening, slightly blown highlights'),
  o('webcam', 'Webcam / FaceTime', 'Laptop webcam look, flat and close', 'laptop webcam footage, flat lighting, slight softness, video-call framing'),
  o('security_cam', 'CCTV', 'High-angle surveillance look', 'security camera footage, high fixed angle, wide lens, muted colour'),
];
export const LENSES: Option[] = [
  o('clean', 'Clean sharp', 'Modern clinical prime', 'clean modern prime lens, edge-to-edge sharpness'),
  o('vintage', 'Vintage prime', 'Soft contrast, gentle flare', 'vintage prime lens, softer contrast, gentle flare'),
  o('warm_vintage', 'Warm vintage', '70s-style warm prime', 'warm 1970s cinema prime, creamy rendering, amber flare'),
  o('anamorphic', 'Anamorphic', 'Oval bokeh, horizontal flares', 'anamorphic lens, oval bokeh, horizontal blue lens flares'),
  o('vintage_anamorphic', 'Vintage anamorphic', 'Character, falloff, streaks', 'vintage anamorphic lens, strong edge falloff, warm streak flares'),
  o('halation', 'Halation diffusion', 'Glowing highlights, dreamy', 'diffusion filter, glowing highlights with halation, dreamy softness'),
  o('swirl', 'Swirl bokeh', 'Petzval-style swirling background', 'Petzval-style portrait lens, swirling bokeh'),
  o('macro', 'Macro', 'Extreme close detail', 'macro lens, extreme close-up detail, razor-thin focus'),
  o('tilt_shift', 'Tilt-shift', 'Miniature-looking focus band', 'tilt-shift lens, narrow slanted focus band, miniature look'),
  o('fisheye', 'Fisheye', 'Ultra-wide barrel distortion', 'fisheye lens, strong barrel distortion'),
];
export const FOCALS: number[] = [8, 14, 18, 24, 26, 35, 50, 65, 85, 100, 135];
export const focalWords = (mm: number) => `${mm}mm lens (${mm <= 14 ? 'ultra-wide' : mm <= 24 ? 'wide' : mm <= 35 ? 'moderate wide' : mm <= 50 ? 'natural perspective' : mm <= 85 ? 'portrait telephoto, compressed background' : 'long telephoto, strongly compressed background'})`;
export const APERTURES: Option[] = [
  o('f1.2', 'f/1.2', 'Wafer-thin focus', 'f/1.2, wafer-thin depth of field, heavy background blur'),
  o('f1.4', 'f/1.4 · wide open', 'Very shallow focus', 'f/1.4, very shallow depth of field, creamy bokeh'),
  o('f2', 'f/2', 'Shallow focus', 'f/2, shallow depth of field'),
  o('f2.8', 'f/2.8', 'Soft background', 'f/2.8, soft background separation'),
  o('f4', 'f/4 · moderate', 'Moderate depth', 'f/4, moderate depth of field'),
  o('f5.6', 'f/5.6', 'Most of the scene sharp', 'f/5.6, most of the scene in focus'),
  o('f8', 'f/8', 'Deep focus', 'f/8, deep focus'),
  o('f11', 'f/11 · deep focus', 'Everything sharp', 'f/11, everything sharp from foreground to background'),
];
export const LOOKS: Option[] = [
  o('digital_clean', 'Clean digital', 'Neutral and true', 'neutral clean digital colour science'),
  o('phone_hdr', 'Phone HDR', 'Bright, punchy, social-ready', 'bright punchy smartphone HDR processing'),
  o('portrait_negative', 'Portrait negative film', 'Soft warm skin, pastel highlights', 'portrait colour-negative film stock, soft warm skin tones, pastel highlights'),
  o('tungsten_stock', 'Tungsten cinema stock', 'Night-friendly, cool shadows', 'tungsten-balanced cinema film stock, cool shadows, glowing practicals'),
  o('slide_film', 'Slide film', 'Saturated, contrasty', 'saturated slide film, deep contrast'),
  o('bw_film', 'Black & white film', 'Silver grain monochrome', 'black-and-white film, silver grain, rich blacks'),
  o('bleach_bypass', 'Bleach bypass', 'Desaturated, harsh contrast', 'bleach-bypass process, desaturated colour, harsh contrast'),
  o('cross_process', 'Cross-processed', 'Shifted, surreal colour', 'cross-processed film, shifted greens and yellows'),
  o('faded_print', 'Faded print', 'Lifted blacks, nostalgic', 'faded film print, lifted blacks, nostalgic colour'),
];
export const FRAME_RATES: Option[] = [
  o('24', '24 fps · cinematic', '180° shutter, classic motion blur', '24 frames per second with a 180-degree shutter, natural cinematic motion blur'),
  o('25', '25 fps', 'Broadcast cadence', '25 fps broadcast cadence'),
  o('30', '30 fps · video', 'Everyday video motion', '30 fps video motion'),
  o('48', '48 fps', 'Crisp, smooth motion', '48 fps, crisp smooth motion'),
  o('60', '60 fps', 'Hyper-smooth, sports feel', '60 fps hyper-smooth motion'),
  o('slowmo', 'Slow motion', 'High-frame-rate slow motion', 'high-frame-rate slow motion, every movement stretched and graceful'),
];
export const SHUTTERS: Option[] = [
  o('normal', 'Normal shutter', 'Natural blur', ''),
  o('low', 'Low shutter', 'Long streaky motion blur', 'slow shutter, long streaking motion blur on movement'),
  o('narrow', 'Narrow shutter', 'Staccato, crisp action', 'narrow shutter angle, staccato crisp motion, no motion blur'),
];

// ---------------------------------------------------------------- light and colour
export const LIGHTING: Option[] = [
  o('natural', 'Natural', 'Available light, as it is', 'natural available light'),
  o('window', 'Window light', 'Soft side light from a window', 'soft daylight from a window to one side'),
  o('soft_cross', 'Soft cross', 'Two soft sources crossing', 'soft cross-lighting from two diffused sources'),
  o('contre_jour', 'Contre-jour', 'Backlit, glowing rim', 'contre-jour backlight, glowing hair rim, slight haze'),
  o('overhead', 'Overhead fall', 'Top light, sculpted shadows', 'hard overhead light falling on the subject, sculpted shadows'),
  o('practicals', 'Practicals', 'Lamps and screens in shot', 'motivated by practical lamps in the frame, pools of warm light'),
  o('silhouette', 'Silhouette', 'Subject dark against bright', 'subject in silhouette against a bright background'),
  o('golden_hour', 'Golden hour', 'Low warm sun', 'low golden-hour sun, long warm shadows'),
  o('blue_hour', 'Blue hour', 'Cool dusk ambience', 'cool blue-hour dusk light, city lights coming on'),
  o('ring_light', 'Ring light', 'Creator ring light, catchlights', 'ring light in front of the subject, round catchlights, even soft face light'),
  o('studio_3pt', 'Studio three-point', 'Key, fill and rim', 'three-point studio lighting: soft key, gentle fill, crisp rim light'),
  o('neon', 'Neon night', 'Coloured neon spill', 'neon signs spilling magenta and cyan light'),
  o('harsh_sun', 'Harsh noon sun', 'Hard shadows, bright', 'harsh midday sun, hard shadows, bright highlights'),
  o('overcast', 'Overcast', 'Flat soft daylight', 'soft overcast daylight, no hard shadows'),
  o('candle', 'Candle / firelight', 'Warm flicker', 'warm flickering candle and firelight'),
  o('moonlight', 'Moonlight', 'Cool low-key night', 'cool moonlight, low-key night exposure'),
  o('flash', 'On-camera flash', 'Party flash, hard and direct', 'direct on-camera flash, hard light, dark falloff'),
];
export const PALETTES: Option[] = [
  o('naturalistic', 'Naturalistic', 'True colour', 'naturalistic clean colour grade'),
  o('bleached_warm', 'Bleached warm', 'Sun-bleached warmth', 'bleached warm grade'),
  o('hyper_neon', 'Hyper neon', 'Electric saturated neon', 'hyper-saturated neon palette'),
  o('teal_orange', 'Teal & orange', 'Blockbuster contrast', 'teal-and-orange blockbuster grade'),
  o('sodium_decay', 'Sodium decay', 'Urban orange streetlight', 'sodium-vapour orange urban grade'),
  o('cold_steel', 'Cold steel', 'Blue-grey and hard', 'cold steel blue-grey grade'),
  o('bleach_bypass', 'Bleach bypass', 'Silver, low saturation', 'silvery low-saturation bleach-bypass grade'),
  o('classic_bw', 'Classic B&W', 'Monochrome', 'classic black-and-white'),
  o('pastel_dream', 'Pastel dream', 'Soft pastels', 'soft pastel palette, airy and light'),
  o('muted_earth', 'Muted earth', 'Olive, tan, brown', 'muted earth tones, olive and tan'),
  o('golden_warmth', 'Golden warmth', 'Honey and amber', 'honey-gold warm palette'),
  o('moody_blue', 'Moody blue', 'Deep blue shadows', 'moody blue grade with deep shadows'),
  o('vintage_fade', 'Vintage fade', 'Faded 70s colour', 'faded 1970s colour'),
  o('high_key', 'High key', 'Bright and clean', 'bright high-key look, clean whites'),
  o('low_key_noir', 'Low key noir', 'Deep blacks', 'low-key noir look, deep blacks, single source'),
  o('cyber_magenta', 'Cyber magenta', 'Magenta and cyan', 'magenta-and-cyan cyberpunk palette'),
  o('forest_green', 'Forest green', 'Lush greens', 'lush forest-green palette'),
  o('desert_sand', 'Desert sand', 'Dusty beige heat', 'dusty desert beige palette'),
  o('commercial_clean', 'Clean commercial', 'Glossy ad look', 'glossy clean commercial grade, accurate product colour'),
  o('retro_80s', 'Retro 80s', 'Pink sunset synth', 'retro 1980s sunset pink and purple'),
  o('nineties_mall', '90s mall', 'Warm flash, saturated', 'saturated 1990s mall-photo colour'),
  o('y2k_gloss', 'Y2K gloss', 'Chrome, icy blue', 'Y2K glossy chrome and icy blue'),
  o('candy_pop', 'Candy pop', 'Bright playful colours', 'bright candy-pop colours'),
  o('autumn', 'Autumn', 'Rust and gold', 'autumn rust and gold palette'),
  o('winter_frost', 'Winter frost', 'Cool white and blue', 'frosty winter whites and blues'),
  o('sepia', 'Sepia', 'Old brown tint', 'sepia-toned'),
  o('kodachrome_like', 'Rich vintage slide', 'Deep reds, saturated blues', 'rich vintage slide-film colour, deep reds and saturated blues'),
  o('matte_film', 'Matte film', 'Soft contrast, lifted shadows', 'matte film look with lifted shadows'),
];

// ---------------------------------------------------------------- moves
const m = (id: string, label: string, category: MoveOption['category'], description: string, wording: string, extra: Partial<MoveOption> = {}): MoveOption =>
  ({ id, label, category, description, wording, ...extra });
export const MOVES: MoveOption[] = [
  m('static', 'Static', 'static', 'Locked-off tripod', 'locked-off static camera, no camera movement', { ltx: 'static', avoid: 'no camera shake, no zoom', talkSafe: true }),
  m('micro_push', 'Micro push', 'push', 'Barely-there push-in', 'an almost imperceptible push-in {amount}', { amount: [0.05, 0.2, 'm'], ltx: 'dolly_in', talkSafe: true }),
  m('handheld', 'Handheld UGC', 'follow', 'Friend-filmed phone, subtle shake', 'handheld phone footage with subtle natural shake, not chaotic', { talkSafe: true }),
  m('selfie', 'Selfie walk-and-talk', 'follow', 'Arm-length selfie, walking', 'selfie camera held at arm’s length, walking with the subject, gentle arm sway', { talkSafe: true }),
  m('dolly_in', 'Dolly in', 'push', 'Cinematic push toward the subject', 'physical dolly-in toward the subject {amount}', { amount: [0.8, 2.0, 'm'], ltx: 'dolly_in', avoid: 'no zoom' }),
  m('dolly_out', 'Dolly out reveal', 'push', 'Pull back to reveal', 'dolly-out pulling back to reveal the surroundings {amount}', { amount: [1.0, 3.5, 'm'], ltx: 'dolly_out', avoid: 'no zoom' }),
  m('truck_left', 'Truck left', 'lateral', 'Slide sideways to the left', 'camera trucks sideways to the left {amount}', { amount: [0.5, 2.5, 'm'], ltx: 'dolly_left' }),
  m('truck_right', 'Truck right', 'lateral', 'Slide sideways to the right', 'camera trucks sideways to the right {amount}', { amount: [0.5, 2.5, 'm'], ltx: 'dolly_right' }),
  m('pan_left', 'Pan left', 'rotate', 'Turn the camera left', 'smooth pan to the left {amount}', { amount: [20, 90, '°'] }),
  m('pan_right', 'Pan right', 'rotate', 'Turn the camera right', 'smooth pan to the right {amount}', { amount: [20, 90, '°'] }),
  m('tilt_up', 'Tilt up', 'rotate', 'Tilt up to reveal', 'camera tilts up {amount}', { amount: [15, 60, '°'] }),
  m('tilt_down', 'Tilt down', 'rotate', 'Tilt down', 'camera tilts down {amount}', { amount: [15, 60, '°'] }),
  m('orbit_left', 'Orbit left', 'rotate', 'Arc around the subject', 'camera orbits around the subject to the left {amount}, keeping them centred', { amount: [60, 180, '°'] }),
  m('orbit_right', 'Orbit right', 'rotate', 'Arc around the subject', 'camera orbits around the subject to the right {amount}, keeping them centred', { amount: [60, 180, '°'] }),
  m('orbit_360', '360 orbit', 'rotate', 'Full circle around the subject', 'a full 360-degree orbit around the subject', { avoid: 'faces may drift on full orbits' }),
  m('crane_up', 'Crane up', 'vertical', 'Rise up and look down', 'crane shot rising {amount} while tilting down to keep the subject framed', { amount: [1.5, 3.5, 'm'], ltx: 'jib_up' }),
  m('crane_down', 'Crane down', 'vertical', 'Descend toward the subject', 'crane shot descending {amount} toward the subject', { amount: [1.5, 3.5, 'm'], ltx: 'jib_down' }),
  m('crane_overhead', 'Crane over the head', 'vertical', 'Sweep up and over', 'crane sweeps up and over the subject’s head into a top-down view'),
  m('pedestal_up', 'Pedestal up', 'vertical', 'Straight rise, no tilt', 'camera rises straight up {amount} without tilting', { amount: [0.5, 1.5, 'm'], ltx: 'jib_up' }),
  m('pedestal_down', 'Pedestal down', 'vertical', 'Straight drop, no tilt', 'camera lowers straight down {amount} without tilting', { amount: [0.5, 1.5, 'm'], ltx: 'jib_down' }),
  m('zoom_in', 'Zoom in', 'zoom', 'Optical zoom, no travel', 'optical zoom in, camera stays in place'),
  m('zoom_out', 'Zoom out', 'zoom', 'Optical zoom out', 'optical zoom out, camera stays in place'),
  m('crash_zoom', 'Crash zoom', 'zoom', 'Sudden fast zoom', 'sudden crash zoom onto the subject', { editorBetter: true }),
  m('dolly_zoom', 'Dolly zoom', 'zoom', 'Vertigo: background warps', 'dolly zoom (vertigo effect): subject stays the same size while the background stretches'),
  m('rack_focus', 'Rack focus', 'specialty', 'Focus shifts foreground → subject', 'focus racks from the foreground to the subject', { ltx: 'focus_shift', talkSafe: true }),
  m('follow', 'Tracking follow', 'follow', 'Follow behind at constant distance', 'camera follows the subject from behind at a constant distance'),
  m('track_side', 'Side tracking', 'follow', 'Move alongside the subject', 'camera tracks alongside the subject in profile, matching their pace'),
  m('lead', 'Leading', 'follow', 'Camera walks backwards ahead', 'camera leads the subject, moving backwards as they walk toward it'),
  m('steadicam', 'Steadicam', 'follow', 'Gliding follow through space', 'smooth gliding steadicam move through the space'),
  m('snorricam', 'Snorricam', 'specialty', 'Rig mounted on the subject', 'body-mounted snorricam: the face stays locked in frame while the world moves'),
  m('fpv', 'FPV drone', 'aerial', 'Fast swooping drone', 'fast FPV drone flight swooping through the scene, banking on turns'),
  m('drone_reveal', 'Drone reveal', 'aerial', 'Rise and reveal the location', 'aerial drone rising and pulling back to reveal the location'),
  m('flyover', 'Aerial flyover', 'aerial', 'High pass over the scene', 'high aerial flyover above the scene'),
  m('whip_pan', 'Whip pan', 'rotate', 'Very fast pan (best as a transition)', 'fast whip pan with motion blur', { editorBetter: true }),
  m('dutch_push', 'Dutch push', 'push', 'Canted angle with a slow push', 'canted Dutch angle with a slow push-in'),
  m('through_object', 'Through object', 'specialty', 'Pass through a gap or window', 'camera passes through a gap in the foreground into the scene'),
  m('top_down_spin', 'Top-down spin', 'rotate', 'Overhead slow rotation', 'top-down overhead view slowly rotating'),
  m('bullet_time', 'Bullet time', 'time', 'Frozen moment, camera circles', 'frozen moment while the camera circles the subject (bullet time)'),
  m('hyperlapse', 'Hyperlapse', 'time', 'Moving time-lapse', 'hyperlapse: camera moves forward while time speeds up'),
  m('handheld_run', 'Action handheld', 'follow', 'Energetic running camera', 'energetic handheld camera running with the action, urgent'),
];
/** Moves that can be mixed: different categories, never two of the same category, never with static/time. */
export function canMix(a: MoveOption, b: MoveOption) {
  if (a.id === b.id || a.category === b.category) return false;
  const solo = ['static', 'time'];
  return !solo.includes(a.category) && !solo.includes(b.category) && a.category !== 'aerial' && b.category !== 'aerial';
}

// ---------------------------------------------------------------- angle and framing
export const HEIGHTS: Option[] = [
  o('eye', 'Eye level', 'Neutral', 'eye-level camera'),
  o('shoulder', 'Shoulder level', 'Slightly below eye', 'shoulder-height camera'),
  o('low', 'Low angle', 'Heroic, looking up', 'low angle looking up at the subject'),
  o('high', 'High angle', 'Looking down', 'high angle looking down at the subject'),
  o('overhead', 'Overhead', 'Bird’s-eye', 'overhead bird’s-eye view'),
  o('worm', 'Worm’s-eye', 'From the ground up', 'worm’s-eye view from the ground'),
  o('ground', 'Ground level', 'Camera on the floor', 'ground-level camera'),
  o('hip', 'Hip level', 'Western-style', 'hip-level camera'),
];
export const SHOT_SIZES: Option[] = [
  o('els', 'Extreme wide', 'Tiny in a huge space', 'extreme wide shot'),
  o('ls', 'Wide', 'Whole body and place', 'wide shot'),
  o('full', 'Full body', 'Head to toe', 'full-body shot'),
  o('cowboy', 'Cowboy', 'Mid-thigh up', 'cowboy shot from mid-thigh up'),
  o('ms', 'Medium', 'Waist up', 'medium shot from the waist up'),
  o('mcu', 'Medium close-up', 'Chest up', 'medium close-up from the chest up'),
  o('cu', 'Close-up', 'Face', 'close-up on the face'),
  o('ecu', 'Extreme close-up', 'Eyes or a detail', 'extreme close-up'),
  o('insert', 'Insert', 'An object or detail', 'insert shot of a detail'),
  o('ots', 'Over the shoulder', 'From behind another person', 'over-the-shoulder shot'),
  o('pov', 'POV', 'Through her eyes', 'first-person point-of-view shot'),
  o('two_shot', 'Two-shot', 'Two people in frame', 'two-shot with both people in frame'),
];
export const GENRES: Option[] = [
  o('ugc', 'UGC', 'Authentic creator content', 'authentic creator-made social video'), o('commercial', 'Commercial', 'Polished ad', 'polished commercial'),
  o('drama', 'Drama', '', 'dramatic'), o('action', 'Action', '', 'high-energy action'), o('epic', 'Epic', '', 'epic, grand scale'),
  o('comedy', 'Comedy', '', 'light comedic'), o('romance', 'Romance', '', 'romantic, intimate'), o('horror', 'Horror', '', 'tense horror'),
  o('noir', 'Noir', '', 'film-noir'), o('documentary', 'Documentary', '', 'observational documentary'), o('music_video', 'Music video', '', 'stylised music video'),
  o('fashion', 'Fashion film', '', 'editorial fashion film'),
];
export const ERAS: Option[] = ['1960s', '1970s', '1980s', '1990s', '2000s', '2010s', '2020s', 'future'].map(e => o(e, e === 'future' ? 'Near future' : e, '', e === 'future' ? 'near-future' : `${e} era`));
export const TEMPOS: Option[] = [
  o('calm', 'Calm', 'Slow, lingering', 'calm lingering pacing'), o('steady', 'Steady', 'Even pacing', 'steady even pacing'),
  o('dynamic', 'Dynamic', 'Energetic', 'dynamic energetic pacing'), o('chaotic', 'Chaotic', 'Frantic', 'frantic chaotic pacing'),
  o('single_shot', 'Single shot', 'One continuous take, no cuts', 'one continuous take with no cuts'),
];
export const EMOTIONS = ['joy', 'trust', 'fear', 'surprise', 'sadness', 'disgust', 'anger', 'hope', 'calm', 'confidence', 'playful', 'flirty'] as const;

/** Ready-made rigs (UGC first): a partial spec merged under whatever the user sets. */
export const PRESETS: { id: string; label: string; description: string; spec: Partial<CameraSpecInput> }[] = [
  { id: 'phone_ugc', label: 'Phone UGC', description: 'Friend-filmed phone, natural light', spec: { rig: { body: 'phone', lens: 'clean', focalMm: 26, aperture: 'f8', look: 'phone_hdr', fps: '30' }, lighting: { preset: 'natural' }, move: { id: 'handheld', intensity: 0.3 }, angle: { height: 'eye', shotSize: 'ms' }, style: { genre: 'ugc' } } },
  { id: 'talking_head', label: 'Talking head', description: 'Locked tripod, ring light', spec: { rig: { body: 'phone', focalMm: 26, aperture: 'f8', look: 'phone_hdr' }, lighting: { preset: 'ring_light' }, move: { id: 'static', intensity: 0 }, angle: { height: 'eye', shotSize: 'mcu' }, style: { genre: 'ugc', tempo: 'single_shot' } } },
  { id: 'selfie_vlog', label: 'Selfie vlog', description: 'Walk-and-talk at arm’s length', spec: { rig: { body: 'vlog', focalMm: 18, aperture: 'f5.6', look: 'phone_hdr' }, move: { id: 'selfie', intensity: 0.4 }, angle: { height: 'eye', shotSize: 'mcu' }, style: { genre: 'ugc' } } },
  { id: 'creator_studio', label: 'Creator studio', description: 'Clean studio, soft key', spec: { rig: { body: 'cinema_digital', lens: 'clean', focalMm: 35, aperture: 'f2.8', look: 'digital_clean' }, lighting: { preset: 'studio_3pt' }, move: { id: 'micro_push', intensity: 0.3 }, angle: { height: 'eye', shotSize: 'ms' } } },
  { id: 'cinematic', label: 'Cinematic', description: 'Film look, shallow focus, slow push', spec: { rig: { body: 'film_35', lens: 'anamorphic', focalMm: 50, aperture: 'f2', look: 'portrait_negative', fps: '24' }, lighting: { preset: 'contre_jour' }, palette: { preset: 'teal_orange' }, move: { id: 'dolly_in', intensity: 0.5 }, angle: { height: 'eye', shotSize: 'mcu' }, style: { genre: 'drama', tempo: 'calm' } } },
  { id: 'product_hero', label: 'Product hero', description: 'Glossy orbit for products', spec: { rig: { body: 'cinema_digital', lens: 'clean', focalMm: 85, aperture: 'f4', look: 'digital_clean' }, lighting: { preset: 'studio_3pt' }, palette: { preset: 'commercial_clean' }, move: { id: 'orbit_right', intensity: 0.4 }, angle: { height: 'eye', shotSize: 'cu' }, style: { genre: 'commercial' } } },
  { id: 'music_video', label: 'Music video', description: 'Neon, low angle, energy', spec: { rig: { body: 'cinema_digital', lens: 'vintage_anamorphic', focalMm: 24, aperture: 'f2', shutter: 'low' }, lighting: { preset: 'neon' }, palette: { preset: 'hyper_neon' }, move: { id: 'orbit_left', intensity: 0.7 }, angle: { height: 'low', shotSize: 'ms' }, style: { genre: 'music_video', tempo: 'dynamic' } } },
  { id: 'documentary', label: 'Documentary', description: 'Observational 16mm', spec: { rig: { body: 'film_16', lens: 'vintage', focalMm: 35, aperture: 'f4' }, lighting: { preset: 'natural' }, move: { id: 'handheld', intensity: 0.4 }, style: { genre: 'documentary' } } },
  { id: 'noir', label: 'Noir', description: 'Hard light, deep shadows', spec: { rig: { body: 'film_35', lens: 'vintage', focalMm: 50, aperture: 'f2.8', look: 'bw_film' }, lighting: { preset: 'practicals' }, palette: { preset: 'low_key_noir' }, move: { id: 'dolly_in', intensity: 0.3 }, angle: { height: 'low', shotSize: 'mcu' }, style: { genre: 'noir', tempo: 'calm' } } },
  { id: 'fashion_editorial', label: 'Fashion editorial', description: 'Large format, golden hour', spec: { rig: { body: 'large_format_65', lens: 'halation', focalMm: 85, aperture: 'f1.4', look: 'portrait_negative' }, lighting: { preset: 'golden_hour' }, palette: { preset: 'golden_warmth' }, move: { id: 'track_side', intensity: 0.4 }, angle: { height: 'eye', shotSize: 'full' }, style: { genre: 'fashion' } } },
  { id: 'y2k_camcorder', label: 'Y2K camcorder', description: 'Party flash, camcorder', spec: { rig: { body: 'camcorder', focalMm: 24, aperture: 'f5.6' }, lighting: { preset: 'flash' }, palette: { preset: 'y2k_gloss' }, move: { id: 'handheld', intensity: 0.6 }, style: { era: '2000s', genre: 'ugc' } } },
];

// ---------------------------------------------------------------- the spec
const ids = (list: { id: string }[]) => list.map(x => x.id) as [string, ...string[]];
const hex = z.string().regex(/^#[0-9a-fA-F]{6}$/);
/** A video the shot can use: one of our uploads (storage key from uploads), our /uploads/... URL, or an https URL. */
export const VideoRefSchema = z.object({ key: z.string().max(300).optional(), url: z.string().max(2000).optional(), seconds: z.number().positive().max(60).optional() })
  .refine(v => !!v.key || !!v.url, 'a video needs key or url');
export type VideoRef = z.infer<typeof VideoRefSchema>;

export const MoveSchema = z.object({
  id: z.enum(ids(MOVES)), intensity: z.number().min(0).max(1).default(0.5), speed: z.enum(['slow', 'normal', 'fast']).default('normal'),
  ease: z.enum(['linear', 'in', 'out', 'in_out']).default('in_out'), startS: z.number().min(0).max(30).optional(), endS: z.number().min(0).max(30).optional(),
});
export const CameraSpecSchema = z.object({
  mode: z.enum(['preset', 'directed']).default('preset'),
  preset: z.enum(ids(PRESETS)).optional(),
  rig: z.object({
    body: z.enum(ids(BODIES)).optional(), lens: z.enum(ids(LENSES)).optional(), focalMm: z.number().int().min(8).max(200).optional(),
    aperture: z.enum(ids(APERTURES)).optional(), look: z.enum(ids(LOOKS)).optional(), fps: z.enum(ids(FRAME_RATES)).optional(), shutter: z.enum(ids(SHUTTERS)).optional(),
  }).partial().optional(),
  lighting: z.object({ preset: z.enum(ids(LIGHTING)).optional(), direction: z.enum(['front', 'left', 'right', 'back', 'top', 'below']).optional(),
    temperatureK: z.number().int().min(1800).max(12000).optional(), intensity: z.enum(['low', 'normal', 'high']).optional() }).optional(),
  palette: z.object({ preset: z.enum(ids(PALETTES)).optional(), colors: z.array(hex).max(5).optional() }).optional(),
  move: MoveSchema.optional(),
  /** A second move mixed with the first (only compatible pairs; dropped on models that want one move). */
  mix: MoveSchema.optional(),
  angle: z.object({ height: z.enum(ids(HEIGHTS)).optional(), shotSize: z.enum(ids(SHOT_SIZES)).optional(), dutchDeg: z.number().min(0).max(30).optional() }).optional(),
  style: z.object({ genre: z.enum(ids(GENRES)).optional(), era: z.enum(ids(ERAS)).optional(), tempo: z.enum(ids(TEMPOS)).optional() }).optional(),
  /** Character performance: an emotion, optionally changing to another at `atS`. */
  performance: z.object({ emotion: z.enum(EMOTIONS), to: z.enum(EMOTIONS).optional(), atS: z.number().min(0).max(30).optional(), intensity: z.number().min(0).max(1).default(0.6) }).optional(),
  /**
   * Guide clip (Directed mode, workstream 2's camera sessions, or a pre-rendered greybox for a preset move): sent as a
   * reference video to models that take one ("take the camera work from <Video n>"), ignored with a note elsewhere.
   */
  guide: z.object({ video: VideoRefSchema, use: z.enum(['camera', 'motion', 'blocking']).default('camera'), cameraSessionId: z.string().max(80).optional(),
    /** Stills rendered from the session for keyframe models. */
    keyframes: z.object({ start: z.string().max(2000).optional(), middle: z.array(z.string().max(2000)).max(8).optional(), end: z.string().max(2000).optional() }).optional() }).optional(),
}).strict();
export type CameraSpec = z.infer<typeof CameraSpecSchema>;
export type CameraSpecInput = z.input<typeof CameraSpecSchema>;

/** The spec with its preset merged underneath (the user's choices win). */
export function resolvePreset(spec: CameraSpec): CameraSpec {
  const p = spec.preset ? PRESETS.find(x => x.id === spec.preset)?.spec : undefined;
  if (!p) return spec;
  const merge = <T extends object>(a?: T, b?: T) => (a || b ? { ...(a ?? {}), ...(b ?? {}) } as T : undefined);
  const base = CameraSpecSchema.parse({ ...p, mode: spec.mode });
  return { ...spec, rig: merge(base.rig, spec.rig), lighting: merge(base.lighting, spec.lighting), palette: merge(base.palette, spec.palette),
    move: spec.move ?? base.move, angle: merge(base.angle, spec.angle), style: merge(base.style, spec.style) };
}

/** Everything the Camera picker shows (member-safe: ids, labels, descriptions). */
export function cameraCatalog() {
  const v = (l: Option[]) => l.map(({ id, label, description }) => ({ id, label, description }));
  return {
    presets: PRESETS.map(({ id, label, description, spec }) => ({ id, label, description, spec })),
    bodies: v(BODIES), lenses: v(LENSES), focalLengths: FOCALS, apertures: v(APERTURES), looks: v(LOOKS), frameRates: v(FRAME_RATES), shutters: v(SHUTTERS),
    lighting: v(LIGHTING), palettes: v(PALETTES),
    moves: MOVES.map(x => ({ id: x.id, label: x.label, description: x.description, category: x.category, editorBetter: !!x.editorBetter, talkSafe: !!x.talkSafe })),
    heights: v(HEIGHTS), shotSizes: v(SHOT_SIZES), genres: v(GENRES), eras: v(ERAS), tempos: v(TEMPOS), emotions: [...EMOTIONS],
    limits: { intensity: [0, 1], dutchDeg: [0, 30], focalMm: [8, 200], paletteColors: 5, mixPairs: 'two moves of different kinds; not static, time or aerial' },
  };
}
