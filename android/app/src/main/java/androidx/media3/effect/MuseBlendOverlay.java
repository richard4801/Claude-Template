package androidx.media3.effect;

/**
 * MUSE (Edit blend modes, plans/video-editor.md "Wave 1 additions"): overlay settings that carry a blend mode. The
 * app's {@code LayerOverlaySettings} implements it; {@link MuseCompositorGlProgram} reads it per layer.
 */
public interface MuseBlendOverlay {
  /** 0 normal, 1 multiply, 2 screen, 3 overlay, 4 softLight, 5 darken, 6 lighten, 7 add (BlendMode.ordinal). */
  int getBlendMode();
}
