import { describe, expect, it } from 'vitest';
import { maxImagesFromText } from '../src/replicate/mapping.js';

describe('image limits written only in descriptions', () => {
  it('reads the common wordings', () => {
    expect(maxImagesFromText('List of input images for image-to-image generation. Maximum 5 images. Must be jpeg, png, gif, or webp.')).toBe(5);
    expect(maxImagesFromText('Input images to transform or use as reference (supports up to 14 images)')).toBe(14);
    expect(maxImagesFromText('Input image(s) for image-to-image generation. List of 1-10 images for single or multi-reference generation.')).toBe(10);
    expect(maxImagesFromText('Images to use as reference. Must be jpeg, png, gif, or webp.')).toBeNull();
    expect(maxImagesFromText(undefined)).toBeNull();
  });
});
