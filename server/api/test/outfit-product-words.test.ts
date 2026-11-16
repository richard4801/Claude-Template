import { describe, it, expect } from 'vitest';
import { outfitWords } from '../src/prompt/engine.js';
import { DEFAULT_TEXTS } from '../src/prompt/library.js';

describe('outfit from a reference photo carries the person\'s own words', () => {
  it('adds the description (hairstyle, piercing) after the product-photo line', () => {
    const s = outfitWords({ name: 'Street set', source: 'product-photo', description: 'platinum blonde high ponytail, small silver nose stud.' }, DEFAULT_TEXTS);
    expect(s).toBe('Wearing: the outfit from the product photo reference (street set). For this look also: platinum blonde high ponytail, small silver nose stud.');
  });
  it('is unchanged without a description', () => {
    expect(outfitWords({ name: 'Street set', source: 'product-photo', description: '  ' }, DEFAULT_TEXTS)).toBe('Wearing: the outfit from the product photo reference (street set).');
  });
});
