// AI suite · the virtual cinema (plans/ai-suite.md "Camera"). One Camera control for every video surface: a CameraSpec
// (rig, lighting, palette, move with intensity, angle and framing, style, optional guide clip) that suite/compile.ts turns
// into what each model can consume. Labels and descriptions here are member-facing; the wording sent to models lives in
// the prompt library (keys suite.camera.*, owner-editable, one "id: wording" per line) with these defaults.
import { z } from 'zod';
import { lutFor, swatchesOf } from './looks.js';
import { PREVIEWS } from './previews.data.js';

export type Option = {
  id: string; label: string; description: string; wording: string;
  /** Composer (plans/video-composer.md "Catalogue"): false = not offered to members (owners and Directed mode keep it). */
  visible?: boolean;
  /** A true duplicate: this id still validates but compiles as its survivor, and pickers show the survivor. */
  mergedInto?: string;
  /** Other words a picker's search finds it by ("single shot" → One take). */
  aliases?: string[];
};
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
/** Hidden from members (still valid, compiles as itself). */
const hidden = (x: Option): Option => ({ ...x, visible: false });
/** Merged into a survivor (still valid, compiles as the survivor). */
const merged = (x: Option, into: string): Option => ({ ...x, visible: false, mergedInto: into });

// ---------------------------------------------------------------- rig
export const BODIES: Option[] = [
  o('phone', 'Phone', 'Modern smartphone: deep focus, natural HDR', 'a modern smartphone camera, deep focus, natural HDR, true-to-life colour'),
  o('vlog', 'Creator camera', 'Compact creator camera, crisp and bright', 'a compact creator camera, crisp detail, bright clean creator look'),
  o('cinema_digital', 'Cinema camera', 'Clean digital cinema, rich skin tones', 'clean digital cinema camera, high-dynamic-range image, rich skin tones'),
  merged(o('super35', 'Super 35 digital', 'Classic S35 cinema sensor', 'Super 35 digital cinema sensor, filmic highlight roll-off'), 'cinema_digital'),
  o('film_35', '35mm film', 'Fine grain, halation, organic colour', '35mm motion-picture film, fine grain, gentle halation, organic colour'),
  o('film_16', '16mm film', 'Visible grain, softer, indie feel', '16mm film, visible grain, softer detail, indie documentary texture'),
  o('film_8', 'Super 8', 'Home-movie grain, gate weave, warm', 'Super 8 home-movie film, heavy grain, slight gate weave, warm faded colour'),
  o('large_format_65', 'Large format 65mm', 'Epic, huge sensor, shallow depth', '65mm large-format film camera, epic scale, extremely shallow depth of field, pristine detail'),
  o('camcorder', 'DV camcorder', '2000s camcorder: video texture, sharpening', 'early-2000s DV camcorder footage, video texture, edge sharpening, slightly blown highlights'),
  merged(o('modular_8k', 'Modular 8K', 'Modular 8K digital: razor detail, big sensor', 'modular 8K digital cinema camera, razor-sharp detail, large sensor rendering'), 'cinema_digital'),
  merged(o('full_frame_cine', 'Full-frame cine', 'Full-frame cinema sensor, creamy depth', 'full-frame digital cinema camera, creamy shallow depth of field, rich colour'), 'cinema_digital'),
  merged(o('creator_cine', 'Creator cine', 'Compact full-frame creator camera, 4K 120', 'compact full-frame creator cinema camera, clean 4K image, smooth high-frame-rate motion'), 'vlog'),
  o('webcam', 'Webcam', 'Laptop webcam look, flat and close', 'laptop webcam footage, flat lighting, slight softness, video-call framing'),
  o('security_cam', 'CCTV', 'High-angle surveillance look', 'security camera footage, high fixed angle, wide lens, muted colour'),
];
export const LENSES: Option[] = [
  o('clean', 'Clean sharp', 'Modern clinical prime', 'clean modern prime lens, edge-to-edge sharpness'),
  merged(o('vintage', 'Vintage prime', 'Soft contrast, gentle flare', 'vintage prime lens, softer contrast, gentle flare'), 'warm_vintage'),
  o('warm_vintage', 'Warm vintage', '70s-style warm prime', 'warm 1970s cinema prime, creamy rendering, amber flare'),
  o('anamorphic', 'Anamorphic', 'Oval bokeh, horizontal flares', 'anamorphic lens, oval bokeh, horizontal blue lens flares'),
  o('vintage_anamorphic', 'Vintage anamorphic', 'Character, falloff, streaks', 'vintage anamorphic lens, strong edge falloff, warm streak flares'),
  o('halation', 'Halation', 'Glowing highlights, dreamy', 'diffusion filter, glowing highlights with halation, dreamy softness'),
  o('swirl', 'Swirl bokeh', 'Petzval-style swirling background', 'Petzval-style portrait lens, swirling bokeh'),
  o('macro', 'Macro', 'Extreme close detail', 'macro lens, extreme close-up detail, razor-thin focus'),
  o('tilt_shift', 'Tilt-shift', 'Miniature-looking focus band', 'tilt-shift lens, narrow slanted focus band, miniature look'),
  o('fisheye', 'Fisheye', 'Ultra-wide barrel distortion', 'fisheye lens, strong barrel distortion'),
  // Zooms are moves now (composer): hidden, still valid.
  hidden(o('cine_zoom', 'Cine zoom', 'Long cinema zoom, crash zooms', 'long cinema zoom lens, smooth zooms, slightly compressed perspective')),
];
export const FOCALS: number[] = [8, 14, 18, 24, 26, 35, 50, 65, 85, 100, 135];
/** The composer's focal wheel: the six steps that read differently to a model (the others share their wording bucket). */
export const FOCAL_STEPS: { mm: number; label: string; description: string }[] = [
  { mm: 14, label: '14mm', description: 'Ultra-wide' }, { mm: 24, label: '24mm', description: 'Wide' }, { mm: 35, label: '35mm', description: 'Everyday' },
  { mm: 50, label: '50mm', description: 'Natural' }, { mm: 85, label: '85mm', description: 'Portrait' }, { mm: 135, label: '135mm', description: 'Telephoto' },
];
export const focalWords = (mm: number) => `${mm}mm lens (${mm <= 14 ? 'ultra-wide' : mm <= 24 ? 'wide' : mm <= 35 ? 'moderate wide' : mm <= 50 ? 'natural perspective' : mm <= 85 ? 'portrait telephoto, compressed background' : 'long telephoto, strongly compressed background'})`;
export const APERTURES: Option[] = [
  // Composer: four visible steps; the in-between stops stay valid (hidden) and compile as themselves.
  hidden(o('f1.2', 'f/1.2', 'Wafer-thin focus', 'f/1.2, wafer-thin depth of field, heavy background blur')),
  o('f1.4', 'f/1.4', 'Dreamy blur', 'f/1.4, very shallow depth of field, creamy bokeh'),
  hidden(o('f2', 'f/2', 'Shallow focus', 'f/2, shallow depth of field')),
  o('f2.8', 'f/2.8', 'Soft background', 'f/2.8, soft background separation'),
  hidden(o('f4', 'f/4', 'Moderate depth', 'f/4, moderate depth of field')),
  o('f5.6', 'f/5.6', 'Natural', 'f/5.6, most of the scene in focus'),
  hidden(o('f8', 'f/8', 'Deep focus', 'f/8, deep focus')),
  o('f11', 'f/11', 'Everything sharp', 'f/11, everything sharp from foreground to background'),
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
  o('reversal_16', '16mm reversal', 'Visible grain, punchy colour, halation', '16mm reversal film, visible grain, punchy saturated colour, halation'),
  o('faded_print', 'Faded print', 'Lifted blacks, nostalgic', 'faded film print, lifted blacks, nostalgic colour'),
];
export const FRAME_RATES: Option[] = [
  o('24', '24 fps · cinematic', '180° shutter, classic motion blur', '24 frames per second with a 180-degree shutter, natural cinematic motion blur'),
  o('25', '25 fps', 'Broadcast cadence', '25 fps broadcast cadence'),
  o('30', '30 fps · video', 'Everyday video motion', '30 fps video motion'),
  o('48', '48 fps', 'Crisp, smooth motion', '48 fps, crisp smooth motion'),
  o('60', '60 fps', 'Hyper-smooth, sports feel', '60 fps hyper-smooth motion'),
  o('slowmo', 'Slow motion', 'High-frame-rate slow motion', 'high-frame-rate slow motion, every movement stretched and graceful'),
// Composer: models output their own frame rate, so members don't see these (Slow motion lives in Style → Tempo, motion
// blur in the "Motion blur streaks" move). Owners and Directed mode keep the raw fields.
].map(hidden);
export const SHUTTERS: Option[] = [
  o('normal', 'Normal shutter', 'Natural blur', ''),
  o('low', 'Low shutter', 'Long streaky motion blur', 'slow shutter, long streaking motion blur on movement'),
  o('narrow', 'Narrow shutter', 'Staccato, crisp action', 'narrow shutter angle, staccato crisp motion, no motion blur'),
].map(hidden);

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
  m('rise_reveal', 'Rise to reveal', 'vertical', 'Start low on the street, rise to find them', 'the shot opens low, below the subject’s eye level, on the street and passing traffic; the camera then rises {amount} on a crane to reveal the subject above', { amount: [2, 5, 'm'], ltx: 'jib_up', aliases: ['reveal', 'rise', 'pedestal up', 'jib up', 'boom up'] }),
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
  m('motion_blur', 'Motion blur streaks', 'specialty', 'Long streaky blur on movement', 'slow shutter look, long streaking motion blur on anything that moves'),
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
  { ...o('single_shot', 'One take', 'One continuous take, no cuts', 'one continuous take with no cuts'), aliases: ['single shot', 'oner', 'continuous take', 'no cuts'] },
  o('slow_motion', 'Slow motion', 'Stretched, graceful movement', 'high-frame-rate slow motion, every movement stretched and graceful'),
];
/** UGC ad formats (composer: the UGC ad tool's Style wheel). */
export const UGC_FORMATS: Option[] = [
  o('unboxing', 'Unboxing', 'Open it on camera, first reaction', 'unboxing video: hands open the package on camera, first genuine reaction to the product'),
  o('review', 'Review', 'Honest take, pros and cons', 'honest product review talking to camera, showing the product while explaining what she likes'),
  o('try_on', 'Try-on', 'Wear it, show the fit', 'try-on video: she puts it on and shows the fit from a few angles in a mirror or to camera'),
  o('before_after', 'Before & after', 'The change it makes', 'before-and-after video: the same moment before the product, then the visible result after'),
  o('grwm', 'GRWM', 'Get ready with me', 'get-ready-with-me video: casual routine to camera, the product used as one natural step'),
  o('haul', 'Haul', 'Several finds, one by one', 'haul video: several items held up to camera one by one with quick excited comments'),
  o('tutorial', 'Tutorial', 'How to use it, step by step', 'quick tutorial: step-by-step how to use the product, close-ups of each step'),
  o('testimonial', 'Testimonial', 'Why she recommends it', 'testimonial: she tells camera sincerely why she recommends the product, product visible in hand'),
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
  style: z.object({ genre: z.enum(ids(GENRES)).optional(), era: z.enum(ids(ERAS)).optional(), tempo: z.enum(ids(TEMPOS)).optional(), format: z.enum(ids(UGC_FORMATS)).optional() }).optional(),
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

/** Every option list by CameraSpec field, for merges and visibility. */
const RIG_LISTS = { body: BODIES, lens: LENSES, aperture: APERTURES, look: LOOKS, fps: FRAME_RATES, shutter: SHUTTERS } as const;
const survivor = (list: Option[], id?: string) => (id ? list.find(x => x.id === id)?.mergedInto ?? id : id);

/** Merged ids (plans/video-composer.md "Catalogue") replaced by their survivors, so an old id compiles as the option members see. */
export function canonicalSpec(spec: CameraSpec): CameraSpec {
  if (!spec.rig && !spec.lighting && !spec.palette) return spec;
  const rig = spec.rig ? Object.fromEntries(Object.entries(spec.rig).map(([k, v]) => [k, k in RIG_LISTS && typeof v === 'string' ? survivor(RIG_LISTS[k as keyof typeof RIG_LISTS] as Option[], v) : v])) as CameraSpec['rig'] : undefined;
  return { ...spec, rig,
    lighting: spec.lighting ? { ...spec.lighting, preset: survivor(LIGHTING, spec.lighting.preset) as never } : undefined,
    palette: spec.palette ? { ...spec.palette, preset: survivor(PALETTES, spec.palette.preset) as never } : undefined };
}

/** The spec with its preset merged underneath (the user's choices win). */
export function resolvePreset(spec: CameraSpec): CameraSpec {
  const p = spec.preset ? PRESETS.find(x => x.id === spec.preset)?.spec : undefined;
  if (!p) return spec;
  const merge = <T extends object>(a?: T, b?: T) => (a || b ? { ...(a ?? {}), ...(b ?? {}) } as T : undefined);
  const base = CameraSpecSchema.parse({ ...p, mode: spec.mode });
  return { ...spec, rig: merge(base.rig, spec.rig), lighting: merge(base.lighting, spec.lighting), palette: merge(base.palette, spec.palette),
    move: spec.move ?? base.move, angle: merge(base.angle, spec.angle), style: merge(base.style, spec.style) };
}

/**
 * The camera bag's photoreal hardware renders (design/hardware, bundled in both apps as `hardware/<file>.webp`) per
 * option, with the spec caption shown under the picture (owner decision: real model names only as a "look" caption).
 */
export const HARDWARE: Record<string, { render: string; name: string; caption: string }> = {
  'bodies.cinema_digital': { render: 'body-02-super35', name: 'Cinema Camera', caption: 'Alexa · Venice · RED look · clean digital cinema' },
  'bodies.large_format_65': { render: 'body-01-large-format', name: 'Large Format 65mm', caption: '65mm look · huge sensor · epic, shallow depth' },
  'bodies.vlog': { render: 'body-07-creator-cine', name: 'Creator Camera', caption: 'FX3 · ZV look · compact · 4K' },
  'bodies.webcam': { render: 'body-11-webcam', name: 'Webcam', caption: 'Webcam · wide · flat light · video-call look' },
  'bodies.security_cam': { render: 'body-12-cctv', name: 'CCTV', caption: 'Security cam · high fixed angle · muted colour' },
  'lenses.swirl': { render: 'lens-09-swirl', name: 'Swirl Bokeh', caption: 'Petzval-style portrait · swirling background' },
  'lenses.tilt_shift': { render: 'lens-10-tilt-shift', name: 'Tilt-shift', caption: 'Slanted focus band · miniature look' },
  'bodies.super35': { render: 'body-02-super35', name: 'Super 35 Digital', caption: 'Alexa 35 look · Super 35 · 4.6K' },
  'bodies.modular_8k': { render: 'body-03-modular8k', name: 'Modular 8K', caption: 'V-Raptor look · VistaVision · 8K' },
  'bodies.full_frame_cine': { render: 'body-04-fullframe', name: 'Full-Frame Cine', caption: 'Venice 2 look · Full frame · 8.6K' },
  'bodies.film_35': { render: 'body-05-film35', name: '35mm Film', caption: '35mm 4-perf · Vision3 500T look' },
  'bodies.film_16': { render: 'body-06-film16', name: 'Super 16 Film', caption: 'Super 16 · grain · documentary' },
  'bodies.creator_cine': { render: 'body-07-creator-cine', name: 'Creator Cine', caption: 'FX3 look · Full frame · 4K 120' },
  'bodies.phone': { render: 'body-08-phone', name: 'Phone UGC', caption: 'Phone · 24 mm · deep focus · HDR' },
  'bodies.camcorder': { render: 'body-09-dv-camcorder', name: 'DV Camcorder', caption: 'MiniDV · 2000s · 480i texture' },
  'bodies.film_8': { render: 'body-10-super8', name: 'Super 8', caption: 'Super 8 · home movie · 18 fps' },
  'lenses.clean': { render: 'lens-01-clean-prime', name: 'Clean Sharp Prime', caption: 'Master Prime look · spherical · T1.3' },
  'lenses.anamorphic': { render: 'lens-02-anamorphic', name: 'Anamorphic 2×', caption: 'Master Anamorphic look · oval bokeh · blue flares' },
  'lenses.vintage_anamorphic': { render: 'lens-03-vintage-anamorphic', name: 'Vintage Anamorphic', caption: '1970s C-series look · amber flares · soft edges' },
  'lenses.warm_vintage': { render: 'lens-04-warm-vintage', name: 'Warm Vintage Prime', caption: 'Speed Panchro look · warm · gentle falloff' },
  'lenses.halation': { render: 'lens-05-halation', name: 'Halation Diffusion', caption: 'Vintage prime + 1/4 mist · bloom on highlights' },
  'lenses.macro': { render: 'lens-06-macro', name: 'Macro', caption: '100 mm macro · 1:1 · product & detail' },
  'lenses.cine_zoom': { render: 'lens-07-cine-zoom', name: 'Cine Zoom', caption: 'Optimo look · 24–290 mm · crash zoom' },
  'lenses.fisheye': { render: 'lens-08-fisheye', name: 'Ultra-wide / Fisheye', caption: '14 mm & fisheye · skate & FPV energy' },
  'optics.aperture': { render: 'optic-01-iris', name: 'Iris · depth of field', caption: 'T1.4 wide open → T11 deep focus' },
  'optics.shutter': { render: 'optic-02-shutter180', name: 'Rotary shutter', caption: '180° natural blur · 90° crisp · 360° smear' },
  'looks.tungsten_stock': { render: 'stock-01-35mm', name: '35mm colour negative', caption: 'Vision3 500T look · tungsten · fine grain' },
  'looks.reversal_16': { render: 'stock-02-16mm', name: '16mm reversal', caption: 'Super 16 · visible grain · halation' },
  'looks.digital_clean': { render: 'stock-03-sensor', name: 'Digital sensor', caption: 'Clean digital · 14+ stops · no grain' },
  'lighting.soft_cross': { render: 'light-01-soft-cross', name: 'Soft Cross', caption: 'Two softboxes crossing · even, flattering' },
  'lighting.contre_jour': { render: 'light-02-contre-jour', name: 'Contre-jour', caption: 'Hard backlight through haze · rim & glow' },
  'lighting.overhead': { render: 'light-03-overhead', name: 'Overhead Fall', caption: 'Butterfly silk overhead · beauty top-light' },
  'lighting.window': { render: 'light-04-window', name: 'Window', caption: 'Soft daylight through sheer · natural & calm' },
  'lighting.practicals': { render: 'light-05-practicals', name: 'Practicals', caption: 'Lamps, neon, bulbs in shot · night mood' },
  'lighting.ring_light': { render: 'light-06-ring-creator', name: 'Creator Ring', caption: 'Ring light + RGB tube · UGC talking head' },
  'grips.dolly_in': { render: 'grip-01-dolly', name: 'Dolly & track', caption: 'Dolly in / out · push · tracking' },
  'grips.crane_up': { render: 'grip-02-jib', name: 'Jib / crane', caption: 'Crane up / down · reveal · overhead' },
  'grips.steadicam': { render: 'grip-03-gimbal', name: 'Gimbal', caption: 'Handheld smooth · walk-and-talk · follow' },
  'grips.fpv': { render: 'grip-04-fpv', name: 'FPV drone', caption: 'FPV fly-through · dives · energy' },
  'grips.truck_left': { render: 'grip-05-slider', name: 'Slider', caption: 'Short parallax slide · product & detail' },
  'palettes.naturalistic': { render: 'palette-01-naturalistic', name: 'Naturalistic Clean', caption: 'True-to-life · neutral · gentle contrast' },
  'palettes.teal_orange': { render: 'palette-02-teal-orange', name: 'Teal & Orange', caption: 'Blockbuster · teal shadows · warm skin' },
  'palettes.hyper_neon': { render: 'palette-03-hyper-neon', name: 'Hyper Neon', caption: 'Magenta & cyan · deep blacks · night' },
  'palettes.bleached_warm': { render: 'palette-04-bleached-warm', name: 'Bleached Warm', caption: 'Sun-faded · milky shadows · nostalgic' },
  'palettes.sodium_decay': { render: 'palette-05-sodium-decay', name: 'Sodium Decay', caption: 'Street-lamp yellow-green · gritty' },
  'palettes.classic_bw': { render: 'palette-06-classic-bw', name: 'Classic B&W', caption: 'Silver tones · rich blacks · grain' },
};

/**
 * The camera bag's move library (owner decision: 16 moves, UGC first, at most two combined), with the filter tag the
 * Move tab shows (All / UGC / Cinematic / Energy / Subtle). The other moves stay available to the API and Claude.
 */
export const FEATURED_MOVES: { id: string; tag: 'ugc' | 'cinematic' | 'energy' | 'subtle'; label?: string }[] = [
  { id: 'static', tag: 'ugc', label: 'Locked-off' }, { id: 'handheld', tag: 'ugc' }, { id: 'selfie', tag: 'ugc' }, { id: 'follow', tag: 'ugc' },
  { id: 'micro_push', tag: 'subtle' }, { id: 'dolly_in', tag: 'cinematic' }, { id: 'dolly_out', tag: 'cinematic' }, { id: 'orbit_left', tag: 'cinematic', label: 'Orbit / arc' },
  { id: 'crane_up', tag: 'cinematic' }, { id: 'rise_reveal', tag: 'cinematic' }, { id: 'track_side', tag: 'cinematic', label: 'Tracking' }, { id: 'fpv', tag: 'energy', label: 'FPV fly-through' },
  { id: 'whip_pan', tag: 'energy' }, { id: 'crash_zoom', tag: 'energy' }, { id: 'handheld_run', tag: 'energy' }, { id: 'rack_focus', tag: 'subtle' }, { id: 'dutch_push', tag: 'subtle' },
];

/** The composer's Movement chips (plans/video-composer.md "Camera picker"); each move belongs to one besides Featured. */
export const MOVE_GROUPS = [
  { id: 'featured', label: 'Featured' }, { id: 'ugc', label: 'UGC' }, { id: 'push', label: 'Push' }, { id: 'pan', label: 'Pan & tilt' },
  { id: 'orbit', label: 'Orbit' }, { id: 'crane', label: 'Crane' }, { id: 'follow', label: 'Follow' }, { id: 'aerial', label: 'Aerial' }, { id: 'special', label: 'Special' },
] as const;
const UGC_MOVES = ['static', 'handheld', 'selfie', 'micro_push'];
export function moveGroup(m: MoveOption): (typeof MOVE_GROUPS)[number]['id'] {
  if (UGC_MOVES.includes(m.id)) return 'ugc';
  if (m.id.startsWith('orbit') || m.id === 'top_down_spin' || m.id === 'bullet_time') return 'orbit';
  switch (m.category) {
    case 'push': case 'zoom': return 'push';
    case 'lateral': case 'rotate': return 'pan';
    case 'vertical': return 'crane';
    case 'follow': return 'follow';
    case 'aerial': return 'aerial';
    default: return 'special';
  }
}

/** Everything the Camera picker shows (member-safe: ids, labels, descriptions, renders and look captions). */
export function cameraCatalog() {
  // Composer previews (design/previews, bundled in the apps as `previews/`): move loops, lighting and angle stills.
  const pv = (group: string, id: string) => (PREVIEWS[`${group}/${id}`] ? { preview: PREVIEWS[`${group}/${id}`] } : {});
  const v = (l: Option[], group?: string, previews?: string) => l.map(({ id, label, description, visible, mergedInto, aliases }) => {
    const h = group ? HARDWARE[`${group}.${id}`] : undefined;
    const vis = { visible: visible !== false, ...(mergedInto ? { mergedInto } : {}), ...(aliases ? { aliases } : {}), ...(previews ? pv(previews, id) : {}) };
    return h ? { id, label, description, render: h.render, name: h.name, caption: h.caption, ...vis } : { id, label, description, ...vis };
  });
  return {
    presets: PRESETS.map(({ id, label, description, spec }) => ({ id, label, description, spec })),
    bodies: v(BODIES, 'bodies'), lenses: v(LENSES, 'lenses'), focalLengths: FOCALS,
    /** The composer's focal wheel (the other lengths stay valid for owners and Directed mode). */
    focals: FOCALS.map(mm => { const s = FOCAL_STEPS.find(x => x.mm === mm); return { mm, label: s?.label ?? `${mm}mm`, description: s?.description ?? '', visible: !!s }; }), apertures: v(APERTURES), looks: v(LOOKS, 'looks').map(x => ({ ...x, swatches: swatchesOf('looks', x.id) ?? [], lut: lutFor('looks', x.id) })), frameRates: v(FRAME_RATES), shutters: v(SHUTTERS),
    lighting: v(LIGHTING, 'lighting', 'lighting'),
    // Look (suite/looks.ts): each palette and film stock has a swatch strip and the LUT the take is graded with.
    palettes: v(PALETTES, 'palettes').map(x => ({ ...x, swatches: swatchesOf('palettes', x.id) ?? [], lut: lutFor('palettes', x.id) })),
    optics: ['aperture', 'shutter'].map(id => ({ id, ...HARDWARE[`optics.${id}`]! })),
    grips: Object.entries(HARDWARE).filter(([k]) => k.startsWith('grips.')).map(([k, h]) => ({ move: k.slice(6), ...h })),
    moves: MOVES.map(x => ({ id: x.id, label: x.label, description: x.description, category: x.category, group: moveGroup(x), editorBetter: !!x.editorBetter, talkSafe: !!x.talkSafe, ...(x.aliases ? { aliases: x.aliases } : {}), ...pv('moves', x.id) })),
    /** The composer's Movement chips, in order ("featured" = `library`). */
    moveGroups: MOVE_GROUPS,
    /** The Auto tile's preview per picker (same subject as the option tiles). */
    autoPreviews: { ...(PREVIEWS['lighting/auto'] ? { lighting: PREVIEWS['lighting/auto'] } : {}) },
    library: FEATURED_MOVES.map(f => { const m = MOVES.find(x => x.id === f.id)!; return { id: m.id, label: f.label ?? m.label, tag: f.tag, description: m.description, category: m.category }; }),
    heights: v(HEIGHTS, undefined, 'angles'), shotSizes: v(SHOT_SIZES, undefined, 'angles'), genres: v(GENRES), eras: v(ERAS), tempos: v(TEMPOS), ugcFormats: v(UGC_FORMATS), emotions: [...EMOTIONS],
    limits: { intensity: [0, 1], dutchDeg: [0, 30], focalMm: [8, 200], paletteColors: 5, mixPairs: 'two moves of different kinds; not static, time or aerial' },
  };
}

// AI suite (workstream 1): a `#Move` chip written out as text ("#Rack focus", pasted or typed past the suggestion list)
// is not prose. Taken out when that move is already compiled into the camera line; otherwise kept as plain words.
const MOVE_TOKEN_RES = [...MOVES].sort((a, b) => b.label.length - a.label.length).map(mv => ({
  id: mv.id, label: mv.label,
  re: new RegExp(`#\\s?(?:${mv.label.replace(/[.*+?^${}()|[\]\\]/g, '\\$&').replace(/\s+/g, '[\\s_-]+')}|${mv.id})(?![\\p{L}\\p{N}_])`, 'giu'),
}));
export function stripMoveTokens(text: string, compiled: readonly string[]): string {
  if (!text.includes('#')) return text;
  let s = text;
  for (const t of MOVE_TOKEN_RES) s = s.replace(t.re, compiled.includes(t.id) ? ' ' : t.label);
  return s.replace(/[ \t]{2,}/g, ' ').replace(/ ([,.!?;:])/g, '$1').replace(/^[ ,]+|[ ,]+$/g, '').trim();
}
