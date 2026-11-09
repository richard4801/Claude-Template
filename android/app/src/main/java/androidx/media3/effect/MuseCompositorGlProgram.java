/*
 * Copyright 2024 The Android Open Source Project
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 * Modified by MUSE (2026-11-09): blend modes. A copy of Media3 1.11.1's DefaultCompositorGlProgram; the build rewrites
 * Media3's own references to that class to this one (AGP class instrumentation, app/build.gradle.kts
 * "MuseCompositorRemap"), so the preview player (CompositionPlayer) and the export (Transformer, which can't take a
 * custom video graph in Media3 1.11) both composite layers through it. Layers whose overlay settings carry a blend mode
 * ({@link MuseBlendOverlay}) are blended with what is below them using the reference formulas
 * (server/api/src/editor/model.ts blendChannel / blendPixel); every other layer is alpha-blended exactly as before.
 */
package androidx.media3.effect;

import static com.google.common.base.Preconditions.checkNotNull;

import android.content.Context;
import android.opengl.GLES20;
import androidx.media3.common.GlTextureInfo;
import androidx.media3.common.OverlaySettings;
import androidx.media3.common.VideoFrameProcessingException;
import androidx.media3.common.util.GlProgram;
import androidx.media3.common.util.GlUtil;
import androidx.media3.common.util.Log;
import androidx.media3.common.util.Size;
import java.io.IOException;
import java.util.List;

/**
 * Wraps {@link GlProgram}s to draw multiple input {@link GlCompositionFrame}s onto one output {@link GlTextureInfo}.
 *
 * <p>All methods must be called on a GL thread, unless otherwise stated.
 */
public final class MuseCompositorGlProgram
    implements DefaultGlTextureFrameCompositingProcessor.CompositorGlProgram {

  private static final String TAG = "CompositorGlProgram";

  /** The blend shader: the layer (uTexSampler) over a copy of what is below it (uBackdrop), in output pixels. */
  private static final String BLEND_FRAGMENT =
      "#version 100\n"
          + "precision highp float;\n"
          + "uniform sampler2D uTexSampler;\n"
          + "uniform sampler2D uBackdrop;\n"
          + "uniform vec2 uOutputSize;\n"
          + "uniform float uAlphaScale;\n"
          + "uniform int uMode;\n"
          + "varying vec2 vTexSamplingCoord;\n"
          + "float ch(float s, float b) {\n"
          + "  if (uMode == 1) return b * s;\n"
          + "  if (uMode == 2) return b + s - b * s;\n"
          + "  if (uMode == 3) return b <= 0.5 ? 2.0 * b * s : 1.0 - 2.0 * (1.0 - b) * (1.0 - s);\n"
          + "  if (uMode == 4) {\n"
          + "    if (s <= 0.5) return b - (1.0 - 2.0 * s) * b * (1.0 - b);\n"
          + "    float d = b <= 0.25 ? ((16.0 * b - 12.0) * b + 4.0) * b : sqrt(b);\n"
          + "    return b + (2.0 * s - 1.0) * (d - b);\n"
          + "  }\n"
          + "  if (uMode == 5) return min(b, s);\n"
          + "  if (uMode == 6) return max(b, s);\n"
          + "  if (uMode == 7) return min(1.0, b + s);\n"
          + "  return s;\n"
          + "}\n"
          + "void main() {\n"
          + "  vec4 top = texture2D(uTexSampler, vTexSamplingCoord);\n"
          + "  vec4 below = texture2D(uBackdrop, gl_FragCoord.xy / uOutputSize);\n"
          + "  vec3 blended = clamp(vec3(ch(top.r, below.r), ch(top.g, below.g), ch(top.b, below.b)), 0.0, 1.0);\n"
          + "  float a = clamp(top.a * uAlphaScale, 0.0, 1.0);\n"
          + "  gl_FragColor = vec4(below.rgb + (blended - below.rgb) * a, a + below.a * (1.0 - a));\n"
          + "}\n";

  private final Context context;
  private final OverlayMatrixProvider overlayMatrixProvider;
  private @androidx.annotation.Nullable GlProgram glProgram;
  private @androidx.annotation.Nullable GlProgram blendProgram;
  private int backdropTexId = -1;
  private int backdropWidth;
  private int backdropHeight;

  /**
   * Creates an instance.
   *
   * <p>May be called on any thread.
   */
  public MuseCompositorGlProgram(Context context) {
    this.context = context;
    this.overlayMatrixProvider = new OverlayMatrixProvider();
  }

  /** The blend mode of a layer (0 = normal). */
  /* package */ static int blendModeOf(OverlaySettings settings) {
    return settings instanceof MuseBlendOverlay ? ((MuseBlendOverlay) settings).getBlendMode() : 0;
  }

  // Enhanced for-loops are discouraged in media3.effect due to short-lived allocations.
  @SuppressWarnings("ListReverse")
  @Override
  public void drawFrame(List<GlCompositionFrame> framesToComposite, GlTextureInfo outputTexture)
      throws GlUtil.GlException, VideoFrameProcessingException {
    ensureConfigured();
    GlUtil.focusFramebufferUsingCurrentContext(
        outputTexture.fboId, outputTexture.width, outputTexture.height);
    overlayMatrixProvider.configure(new Size(outputTexture.width, outputTexture.height));
    GlUtil.clearFocusedBuffers();

    // Draw textures from back to front.
    for (int i = framesToComposite.size() - 1; i >= 0; i--) {
      GlCompositionFrame frame = framesToComposite.get(i);
      int mode = blendModeOf(frame.overlaySettings);
      if (mode == 0) {
        alphaBlendOntoFocusedTexture(frame);
      } else {
        blendModeOntoFocusedTexture(frame, mode, outputTexture);
      }
    }
    GlUtil.checkGlError();
  }

  @Override
  public void release() {
    try {
      if (glProgram != null) {
        glProgram.delete();
      }
      if (blendProgram != null) {
        blendProgram.delete();
      }
      if (backdropTexId != -1) {
        GlUtil.deleteTexture(backdropTexId);
        backdropTexId = -1;
      }
    } catch (GlUtil.GlException e) {
      Log.e(TAG, "Error releasing GL Program", e);
    }
  }

  private void ensureConfigured() throws VideoFrameProcessingException, GlUtil.GlException {
    if (glProgram != null) {
      return;
    }
    try {
      glProgram =
          new GlProgram(
              context,
              /* vertexShaderResId= */ R.raw.vertex_shader_transformation_es2,
              /* fragmentShaderResId= */ R.raw.fragment_shader_alpha_scale_es2);
      glProgram.setBufferAttribute(
          "aFramePosition",
          GlUtil.getNormalizedCoordinateBounds(),
          GlUtil.HOMOGENEOUS_COORDINATE_VECTOR_SIZE);
      glProgram.setFloatsUniform("uTexTransformationMatrix", GlUtil.create4x4IdentityMatrix());
      blendProgram =
          new GlProgram(
              readRaw(R.raw.vertex_shader_transformation_es2), BLEND_FRAGMENT);
      blendProgram.setBufferAttribute(
          "aFramePosition",
          GlUtil.getNormalizedCoordinateBounds(),
          GlUtil.HOMOGENEOUS_COORDINATE_VECTOR_SIZE);
      blendProgram.setFloatsUniform("uTexTransformationMatrix", GlUtil.create4x4IdentityMatrix());
    } catch (IOException e) {
      throw new VideoFrameProcessingException(e);
    }
  }

  private String readRaw(int resId) throws IOException {
    try (java.io.InputStream in = context.getResources().openRawResource(resId)) {
      return new String(com.google.common.io.ByteStreams.toByteArray(in), java.nio.charset.StandardCharsets.UTF_8);
    }
  }

  private float[] matrixFor(GlCompositionFrame frame) {
    float[] m = frame.transformationMatrix;
    if (m == null) {
      GlTextureInfo t = frame.glTextureInfo;
      m = overlayMatrixProvider.getTransformationMatrix(new Size(t.width, t.height), frame.overlaySettings);
    }
    return m;
  }

  private void alphaBlendOntoFocusedTexture(GlCompositionFrame inputFrameInfo) throws GlUtil.GlException {
    GlProgram program = checkNotNull(this.glProgram);
    program.use();
    // dst.rgb = src.rgb * src.a + dst.rgb * (1 - src.a); dst.a = src.a + dst.a * (1 - src.a)
    GLES20.glEnable(GLES20.GL_BLEND);
    GLES20.glBlendFuncSeparate(
        GLES20.GL_SRC_ALPHA, GLES20.GL_ONE_MINUS_SRC_ALPHA, GLES20.GL_ONE, GLES20.GL_ONE_MINUS_SRC_ALPHA);
    program.setSamplerTexIdUniform("uTexSampler", inputFrameInfo.glTextureInfo.texId, /* texUnitIndex= */ 0);
    program.setFloatsUniform("uTransformationMatrix", matrixFor(inputFrameInfo));
    program.setFloatUniform("uAlphaScale", inputFrameInfo.overlaySettings.getAlphaScale());
    program.bindAttributesAndUniforms();
    GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, /* first= */ 0, /* count= */ 4);
    GLES20.glDisable(GLES20.GL_BLEND);
    GlUtil.checkGlError();
  }

  /** Copies what is drawn so far into the backdrop texture, then draws the layer blended with it (no GL blending). */
  private void blendModeOntoFocusedTexture(GlCompositionFrame frame, int mode, GlTextureInfo output)
      throws GlUtil.GlException {
    if (backdropTexId == -1 || backdropWidth != output.width || backdropHeight != output.height) {
      if (backdropTexId != -1) {
        GlUtil.deleteTexture(backdropTexId);
      }
      backdropTexId = GlUtil.createTexture(output.width, output.height, /* useHighPrecisionColorComponents= */ false);
      backdropWidth = output.width;
      backdropHeight = output.height;
    }
    GLES20.glActiveTexture(GLES20.GL_TEXTURE1);
    GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, backdropTexId);
    GLES20.glCopyTexSubImage2D(GLES20.GL_TEXTURE_2D, 0, 0, 0, 0, 0, output.width, output.height);
    GlUtil.checkGlError();
    GlProgram program = checkNotNull(this.blendProgram);
    program.use();
    GLES20.glDisable(GLES20.GL_BLEND);
    program.setSamplerTexIdUniform("uTexSampler", frame.glTextureInfo.texId, /* texUnitIndex= */ 0);
    program.setSamplerTexIdUniform("uBackdrop", backdropTexId, /* texUnitIndex= */ 1);
    program.setFloatsUniform("uOutputSize", new float[] {output.width, output.height});
    program.setFloatsUniform("uTransformationMatrix", matrixFor(frame));
    program.setFloatUniform("uAlphaScale", frame.overlaySettings.getAlphaScale());
    program.setIntUniform("uMode", mode);
    program.bindAttributesAndUniforms();
    GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, /* first= */ 0, /* count= */ 4);
    GlUtil.checkGlError();
  }
}
