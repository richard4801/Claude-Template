// The starter pack (plans/templates.md): seven public templates per studio, owned by the studio owner. Our own
// recreations: prompt layers written here, covers made from the bundled placeholder stills with the template's
// grade and after-effects applied. No third-party photos are used, as references or as covers.
import type { TemplateLayers, VariationPool } from '../db/schema.js';

export type Starter = { slug: string; name: string; tags: string[]; layers: TemplateLayers; variationPool: VariationPool; coverAsset: string };

export const STARTERS: Starter[] = [
  {
    slug: 'motion-blur-face', name: 'Motion-blur face', tags: ['Faceless', 'Motion', 'Editorial'], coverAsset: 'face',
    layers: {
      style: 'candid phone photo taken a split second too late, the subject moving while the background holds still',
      scene: 'a plain lived-in space: a hallway, a kitchen corner or a quiet street, nothing staged',
      camera: 'phone main camera, 26mm equivalent, eye level, 1/30 s handheld so movement smears while static things stay crisp',
      light: 'flat indoor daylight or overcast daylight, no flash, no rim light',
      negative: 'blurred background, bokeh, tack-sharp face, studio backdrop',
      afterEffects: { faceMotionBlur: 0.85, blurAngle: 0, grade: 'phone-natural', grain: 0.15 },
    },
    variationPool: {
      pose: ['turning her head quickly towards the camera', 'mid-laugh, head tipping back', 'spinning round, hair swinging', 'brushing hair off her face as she turns'],
      bodyAngle: ['three-quarter to camera', 'side-on, head turning back', 'facing camera'],
      framing: ['waist up, slightly off-centre', 'head and shoulders, cropped at the crown', 'three-quarter length'],
      expression: ['open mouth laugh', 'surprised half smile', 'neutral, caught mid-word'],
      background: ['a white door and a light switch', 'kitchen cabinets and a kettle', 'a brick wall and a bike'],
    },
  },
  {
    slug: 'mirror-selfie', name: 'Mirror selfie', tags: ['Faceless', 'Selfie', 'At home'], coverAsset: 'g_front',
    layers: {
      style: 'real mirror selfie posted straight from the camera roll, slight smudges on the mirror, no retouching',
      scene: 'a candid bedroom or bathroom with everyday clutter: a chair with clothes on it, a plant, a charger cable',
      camera: 'shot on the phone in the mirror, the phone visible in her hand, slight upward tilt, vertical 9:16, mirror edge in frame',
      light: 'one window or ceiling light, a little underexposed, soft shadows, no ring light',
      negative: 'ring light reflection, perfect symmetry, empty showroom room, phone floating without a hand',
      afterEffects: { grade: 'underexposed', grain: 0.12 },
    },
    variationPool: {
      pose: ['phone held up covering the face', 'phone held low at the chest, face visible over it', 'one hip popped, phone at eye level, face hidden', 'leaning a shoulder on the door frame, phone covering the face'],
      bodyAngle: ['three-quarter turn to the mirror', 'square to the mirror', 'side-on, looking at the screen'],
      framing: ['full length in the mirror', 'mirror cropped at the knees', 'tight on the torso and phone'],
      hands: ['free hand tugging the hem', 'free hand in her hair', 'free hand resting on the sink'],
      background: ['unmade bed in the corner', 'clothes over a chair', 'a bathroom shelf with bottles', 'a laundry basket by the door'],
    },
  },
  {
    slug: 'harsh-sun-close-up', name: 'Harsh-sun close-up', tags: ['Close-up', 'Sun', 'Beauty'], coverAsset: 'face',
    layers: {
      style: 'extreme close-up in direct midday sun, visible pores, fine hairs and skin texture, real and slightly unflattering',
      scene: 'outdoors, sky or a sunlit wall just visible behind',
      camera: 'phone held at arm’s length, very tight crop that cuts part of the face, slight lens distortion, sharp skin detail',
      light: 'hard direct sun, crisp dark shadows under the nose, chin and brows, specular highlights on the skin',
      negative: 'soft light, smooth airbrushed skin, makeup filter, glow',
      afterEffects: { grade: 'harsh-sun', grain: 0.08 },
    },
    variationPool: {
      pose: ['chin lifted to the sun', 'head tilted, cheek to the light', 'looking just past the lens'],
      framing: ['extreme close-up cropped at the forehead', 'lips and jaw only', 'one eye and cheek, very tight', 'nose to chin, off-centre'],
      expression: ['squinting slightly', 'soft, lips parted', 'small closed-mouth smile'],
      hands: ['fingertips at the jaw', 'no hands in frame', 'hand shading the eyes, shadow across the face'],
    },
  },
  {
    slug: 'moody-low-light', name: 'Moody low-light', tags: ['Night', 'Moody', 'At home'], coverAsset: 'c_front',
    layers: {
      style: 'underexposed phone photo at night, noisy shadows, calm and a little lonely',
      scene: 'a dim room lit only by practical lights',
      camera: 'phone night mode, handheld, eye level or slightly above, 26mm equivalent',
      light: 'low light from a lamp, a screen or a window, deep shadows, cool blue and purple tones with one warm practical',
      negative: 'bright even exposure, flash, clean noise-free shadows',
      afterEffects: { grade: 'moody-blue', grain: 0.45 },
    },
    variationPool: {
      pose: ['sitting on the edge of the bed', 'leaning on a window frame', 'curled on a sofa', 'standing in a doorway'],
      bodyAngle: ['side profile', 'three-quarter away from camera', 'facing camera'],
      expression: ['distant, unsmiling', 'tired half smile', 'eyes down'],
      background: ['a lamp glowing out of focus', 'city lights through the window', 'a TV glow off frame', 'fairy lights on the wall'],
      timeOfDay: ['late evening', 'after midnight', 'blue hour just ending'],
    },
  },
  {
    slug: 'reflection', name: 'Reflection', tags: ['Reflection', 'Street', 'Editorial'], coverAsset: 'c_tq',
    layers: {
      style: 'the subject and her reflection together, the mirrored surface working as a second image in the frame',
      scene: 'a reflective surface outdoors: a glossy car roof, a shop window or still water',
      camera: 'phone held low near the reflective surface, 26mm equivalent, both the subject and the reflection in focus',
      light: 'natural daylight, reflections slightly darker and cooler than the subject',
      negative: 'perfect mirror copy, missing reflection, warped body in the reflection',
      afterEffects: { grade: 'faded', grain: 0.1 },
    },
    variationPool: {
      pose: ['leaning over the surface', 'crouched beside it', 'standing with her reflection below her', 'resting her arms on the car roof'],
      bodyAngle: ['three-quarter to camera', 'side-on', 'facing camera'],
      framing: ['subject top, reflection bottom', 'reflection only, subject cropped out at the top', 'off-centre, reflection on the right'],
      background: ['a wet street after rain', 'a glossy black car roof', 'a shop window at dusk', 'a still canal'],
    },
  },
  {
    slug: 'product-moment', name: 'Product moment', tags: ['Product', 'UGC', 'Close-up'], coverAsset: 'c_face',
    layers: {
      style: 'casual UGC product photo: the product is the hero and in sharp focus, the person only partly in frame',
      scene: 'a real everyday surface: a bathroom counter, a bedside table or a café table',
      camera: 'phone main camera close to the product, shallow natural depth of field, slight tilt',
      light: 'soft window light from one side, true product colours',
      product: 'the product from the product photo, exactly as it is (shape, colour and label), held or placed as the hero',
      negative: 'invented logos, misspelled label, product floating, studio packshot look',
      afterEffects: { grade: 'phone-natural' },
    },
    variationPool: {
      pose: ['product held up next to the cheek', 'product in hand at the hip', 'applying or using it', 'reaching for it on the table'],
      framing: ['product sharp in the foreground, her face soft behind', 'hand and product only, her body cropped', 'product on a surface, her hand entering'],
      hands: ['fingertips around the cap', 'product resting on the palm', 'both hands holding it'],
      background: ['a bathroom counter with a towel', 'a bedside table with a book', 'a café table with a coffee'],
    },
  },
  {
    slug: 'candid-pov', name: 'Candid POV', tags: ['POV', 'Candid', 'Lifestyle'], coverAsset: 'g_tq',
    layers: {
      style: 'point-of-view phone photo as if taken by a friend or partner, unposed, slightly imperfect',
      scene: 'out together: a café, a street, a car or a park',
      camera: 'phone main camera at chest height, off-centre framing, slight tilt, a hand or object entering the frame edge',
      light: 'whatever light is there, natural and uneven',
      negative: 'centred symmetric composition, posed model stance, studio light',
      afterEffects: { grade: 'phone-natural', grain: 0.1 },
    },
    variationPool: {
      pose: ['reaching for the camera', 'walking ahead, glancing back', 'sitting across a café table', 'laughing at something off frame'],
      bodyAngle: ['three-quarter to camera', 'back to camera, looking over her shoulder', 'facing camera'],
      framing: ['off-centre left, lots of space', 'tilted horizon', 'cut at the chin', 'her hand blocking part of the lens'],
      hands: ['the photographer’s hand entering frame', 'holding a drink towards the lens', 'pointing at something'],
      timeOfDay: ['late afternoon', 'midday', 'just after sunset'],
    },
  },
];
