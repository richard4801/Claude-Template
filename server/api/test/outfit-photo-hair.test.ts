import { describe, it, expect } from 'vitest';
import { outfitSet, slotText } from '../src/prompt/engine.js';
import { lookWithoutHair } from '../src/prompt/scripts/builders.js';
import { DEFAULT_TEXTS } from '../src/prompt/library.js';

// Owner 2026-11-17: an outfit "From a photo" kept her own hair and came out barefoot on the front.
const her = { name: 'Mia', look: 'young woman, blonde braids in space buns, blue eyes, fair skin', referenceCount: 4 };
const photo = { name: 'Space set', source: 'product-photo' as const, description: 'Keep the hair from the photo, and the headset.' };
const bodies = ['her front body photo (image 3)', 'her ¾ body photo (image 3)', 'her side body photo (image 3)', 'her back body photo (image 3)'];

describe('outfit made from a photo', () => {
  const set = outfitSet(her, photo, 1, DEFAULT_TEXTS, bodies, ['image 5', 'image 5', 'image 5', 'image 5']);

  it('names the outfit photo by its number on every angle', () => {
    for (const p of set) expect(p.text).toContain('Wearing: the outfit in image 5 (space set). For this look also: Keep the hair from the photo, and the headset.');
  });
  it('takes her hair from the photo and drops her usual hair from her look', () => {
    for (const p of set) {
      expect(p.text).toContain('Hair for this look: the hairstyle of the person in image 5 (cut, colour, length and styling), replacing her usual hair; her face, skin and features stay exactly hers from her own images.');
      expect(slotText(p, 'identity')).not.toContain('braids');
      expect(slotText(p, 'identity')).toContain('hair as in image 5 for this look');
    }
  });
  it('asks for the whole outfit head to toe, footwear included, on every angle', () => {
    for (const p of set) expect(p.text).toContain('The complete outfit head to toe as in image 5, including the footwear, on every angle.');
  });
  it('no hair line when the description asks for no hair', () => {
    const p = outfitSet(her, { ...photo, description: 'add the headset' }, 1, DEFAULT_TEXTS, bodies, ['panel 5'])[0]!;
    expect(p.text).not.toContain('Hair for this look');
    expect(p.text).toContain('braids');
    expect(p.text).toContain('as in panel 5, including the footwear');
  });
  it('unchanged when the photo number is not known', () => {
    const p = outfitSet(her, photo, 1, DEFAULT_TEXTS, bodies)[0]!;
    expect(p.text).toContain('Wearing: the outfit from the product photo reference (space set).');
    expect(p.text).not.toContain('head to toe');
  });
  it('lookWithoutHair keeps the rest of her look', () => {
    expect(lookWithoutHair('young woman, shoulder-length dark brown hair, brown eyes', 'image 4')).toBe('young woman, brown eyes, hair as in image 4 for this look');
  });
});
