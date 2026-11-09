"""Runs the Android compositor's blend shader (MuseCompositorGlProgram.BLEND_FRAGMENT) on a software GL (Mesa llvmpipe
via moderngl) against every blend case of the shared fixture functions.json -> wave1.blend (the TypeScript reference).

    pip install moderngl && Xvfb :99 & DISPLAY=:99 python3 android/tools/check_blend_shader.py

Robolectric has no GL, so this is how the shader itself is checked. Exit 0 = every case within 1e-4.
"""
import json, re, struct, sys, pathlib
import moderngl

root = pathlib.Path(__file__).resolve().parents[2]
java = (root / "android/app/src/main/java/androidx/media3/effect/MuseCompositorGlProgram.java").read_text()
block = java[java.index("BLEND_FRAGMENT ="):java.index(";\n", java.index("BLEND_FRAGMENT ="))]
frag = "".join(json.loads('"' + m + '"') for m in re.findall(r'"((?:[^"\\]|\\.)*)"', block))
# GLSL ES 1.00 → desktop GLSL 1.20 (same language for this shader; no precision qualifiers there).
frag = frag.replace("#version 100", "#version 120").replace("precision highp float;", "")
vert = """#version 120
attribute vec2 aPos; varying vec2 vTexSamplingCoord;
void main() { gl_Position = vec4(aPos, 0.0, 1.0); vTexSamplingCoord = aPos * 0.5 + 0.5; }"""
ctx = moderngl.create_standalone_context()
prog = ctx.program(vertex_shader=vert, fragment_shader=frag)
vbo = ctx.buffer(struct.pack("8f", -1, -1, 1, -1, -1, 1, 1, 1))
vao = ctx.vertex_array(prog, [(vbo, "2f", "aPos")])
fbo = ctx.framebuffer(color_attachments=[ctx.texture((1, 1), 4, dtype="f4")])
modes = ["normal", "multiply", "screen", "overlay", "softLight", "darken", "lighten", "add"]
cases = json.loads((root / "server/api/test/fixtures/editor/functions.json").read_text())["wave1"]["blend"]
bad = 0
for c in cases:
    top = ctx.texture((1, 1), 4, struct.pack("4f", *c["top"], 1.0), dtype="f4")
    below = ctx.texture((1, 1), 4, struct.pack("4f", *c["below"], 1.0), dtype="f4")
    top.use(0); below.use(1)
    prog["uTexSampler"].value = 0; prog["uBackdrop"].value = 1
    prog["uOutputSize"].value = (1.0, 1.0); prog["uAlphaScale"].value = c["a"]; prog["uMode"].value = modes.index(c["mode"])
    fbo.use(); fbo.clear(); vao.render(moderngl.TRIANGLE_STRIP)
    got = struct.unpack("4f", fbo.read(components=4, dtype="f4"))[:3]
    if any(abs(g - w) > 1e-4 for g, w in zip(got, c["out"])):
        bad += 1; print("MISMATCH", c["mode"], c["top"], c["below"], c["a"], "want", c["out"], "got", got)
print(f"{len(cases) - bad}/{len(cases)} blend cases match the reference")
sys.exit(1 if bad else 0)
