import Foundation

/// The fixed MUSE Python scripts the relay sends through the add-on's `execute_code`. Arguments are data, never code:
/// the validated args are JSON-encoded and base64-encoded into the one line `A = json.loads(base64.b64decode("…"))`
/// (base64 has no quotes or backslashes, so nothing a caller sends can change the program). Every script prints one
/// `MUSE_RESULT:<json>` line. Scripts only touch objects named `MUSE_*` and only write files into the session's `out` folder.
/// Conventions: metres, Z up, a character faces -Y at facingDeg 0, an object's position is its bottom centre.
public enum BlenderScripts {
    public static let resultPrefix = "MUSE_RESULT:"

    /// The full script for a scripted tool; nil for the native ones (status, scene info, screenshot).
    public static func code(_ tool: BlenderTool, data: [String: JSONValue]) -> String? {
        let body: String
        switch tool {
        case .setupScene: body = setupScene
        case .placeCharacter: body = placeCharacter
        case .animateCharacter: body = animateCharacter
        case .addProp: body = addProp
        case .setCamera: body = setCamera
        case .renderGuides: body = renderGuides
        case .status, .sceneInfo, .screenshot: return nil
        }
        return prelude(encode(data)) + helpers + "\ndef muse_main():\n" + body + epilogue
    }

    /// The args as base64 of their JSON (sorted keys).
    public static func encode(_ data: [String: JSONValue]) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return ((try? enc.encode(JSONValue.object(data))) ?? Data("{}".utf8)).base64EncodedString()
    }

    /// The last `MUSE_RESULT:` line of the captured stdout, parsed.
    public static func parseResult(_ stdout: String) -> JSONValue? {
        let lines = stdout.split(whereSeparator: \.isNewline)
        guard let line = lines.last(where: { $0.hasPrefix(resultPrefix) }) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: Data(line.dropFirst(resultPrefix.count).utf8))
    }

    static func prelude(_ b64: String) -> String {
        // b64 is [A-Za-z0-9+/=] only (Data.base64EncodedString).
        "import bpy, bmesh, math, json, base64\nfrom mathutils import Vector, Quaternion\nA = json.loads(base64.b64decode(\"\(b64)\").decode(\"utf-8\"))\n"
    }

    static let helpers = #"""

def muse_done(d):
    if "ok" not in d:
        d["ok"] = True
    print("MUSE_RESULT:" + json.dumps(d))

def muse_fail(msg):
    muse_done({"ok": False, "error": msg})

def muse_set(obj, attr, value):
    try:
        setattr(obj, attr, value)
        return True
    except Exception:
        return False

def muse_remove(name):
    o = bpy.data.objects.get(name)
    if o is not None and o.name.startswith("MUSE_"):
        bpy.data.objects.remove(o, do_unlink=True)

def muse_part(bm, kind, dims, center):
    n0 = len(bm.verts)
    if kind == "box":
        bmesh.ops.create_cube(bm, size=1.0)
    elif kind == "cylinder":
        bmesh.ops.create_cone(bm, cap_ends=True, segments=24, radius1=1.0, radius2=1.0, depth=2.0)
    elif kind == "sphere":
        bmesh.ops.create_uvsphere(bm, u_segments=24, v_segments=12, radius=1.0)
    else:
        vs = [bm.verts.new((x, y, 0.0)) for (x, y) in ((-1.0, -1.0), (1.0, -1.0), (1.0, 1.0), (-1.0, 1.0))]
        bm.faces.new(vs)
    bm.verts.ensure_lookup_table()
    new = [bm.verts[i] for i in range(n0, len(bm.verts))]
    for i in range(3):
        lo = min(v.co[i] for v in new)
        hi = max(v.co[i] for v in new)
        ext = hi - lo
        mid = (hi + lo) / 2.0
        for v in new:
            v.co[i] = center[i] + ((v.co[i] - mid) / ext * dims[i] if ext > 1e-9 else 0.0)

def muse_mesh_object(name, parts, grey):
    o = bpy.data.objects.get(name)
    if o is not None and o.type != 'MESH':
        muse_remove(name)
        o = None
    me = bpy.data.meshes.new(name)
    bm = bmesh.new()
    for p in parts:
        muse_part(bm, p[0], p[1], p[2])
    bm.to_mesh(me)
    bm.free()
    if o is None:
        o = bpy.data.objects.new(name, me)
        bpy.context.scene.collection.objects.link(o)
    else:
        old = o.data
        o.data = me
        if old is not None and old.users == 0 and old.name.startswith("MUSE_"):
            bpy.data.meshes.remove(old)
    o.color = (grey, grey, grey, 1.0)
    return o

def muse_fcurves(idblock):
    ad = getattr(idblock, "animation_data", None)
    if ad is None or ad.action is None:
        return []
    act = ad.action
    out = []
    try:
        out = list(act.fcurves)
    except Exception:
        out = []
    if not out:
        for layer in getattr(act, "layers", []):
            for strip in layer.strips:
                for bag in getattr(strip, "channelbags", []):
                    out.extend(bag.fcurves)
    return out

MUSE_EASE = {"linear": ("LINEAR", None), "in": ("SINE", "EASE_IN"), "out": ("SINE", "EASE_OUT"), "in_out": ("BEZIER", None), "cut": ("CONSTANT", None)}

def muse_set_interp(idblock, by_frame):
    for fc in muse_fcurves(idblock):
        for kp in fc.keyframe_points:
            e = by_frame.get(int(round(kp.co[0])))
            if e is None or e not in MUSE_EASE:
                continue
            interp, easing = MUSE_EASE[e]
            kp.interpolation = interp
            if easing:
                kp.easing = easing

def muse_r6(v):
    return round(float(v), 6)

"""#

    static let epilogue = #"""

try:
    muse_main()
except Exception as e:
    muse_fail(type(e).__name__ + ": " + str(e)[:300])
"""#

    // MARK: Tools

    /// A: fps, frameEnd, width, height, clear.
    static let setupScene = #"""
    sc = bpy.context.scene
    removed = 0
    if A["clear"]:
        for o in [o for o in bpy.data.objects if o.name.startswith("MUSE_")]:
            bpy.data.objects.remove(o, do_unlink=True)
            removed += 1
    sc.render.fps = int(A["fps"])
    sc.render.fps_base = 1.0
    sc.frame_start = 1
    sc.frame_end = int(A["frameEnd"])
    sc.render.resolution_x = int(A["width"])
    sc.render.resolution_y = int(A["height"])
    sc.render.resolution_percentage = 100
    sc.render.pixel_aspect_x = 1.0
    sc.render.pixel_aspect_y = 1.0
    muse_mesh_object("MUSE_floor", [("plane", (40.0, 40.0, 0.0), (0.0, 0.0, 0.0))], 0.8)
    sc.frame_set(1)
    names = sorted(o.name for o in bpy.data.objects if o.name.startswith("MUSE_"))
    muse_done({"fps": sc.render.fps, "frameStart": sc.frame_start, "frameEnd": sc.frame_end,
               "width": sc.render.resolution_x, "height": sc.render.resolution_y, "removed": removed, "objects": names})
"""#

    /// A: modelId, label, heightM, position, facingDeg.
    static let placeCharacter = #"""
    H = float(A["heightM"])
    name = "MUSE_char_" + A["modelId"]
    o = muse_mesh_object(name, [
        ("cylinder", (0.26 * H, 0.2 * H, 0.84 * H), (0.0, 0.0, 0.42 * H)),
        ("sphere", (0.13 * H, 0.13 * H, 0.13 * H), (0.0, 0.0, 0.935 * H)),
        ("box", (0.04 * H, 0.05 * H, 0.03 * H), (0.0, -0.075 * H, 0.93 * H)),
    ], 0.45)
    o.animation_data_clear()
    o.rotation_mode = 'XYZ'
    o.location = A["position"]
    o.rotation_euler = (0.0, 0.0, math.radians(A["facingDeg"]))
    o.scale = (1.0, 1.0, 1.0)
    o["muse_model_id"] = A["modelId"]
    o["muse_label"] = A["label"]
    o["muse_height_m"] = H
    muse_done({"object": o.name, "position": [muse_r6(v) for v in o.location], "facingDeg": A["facingDeg"], "heightM": H,
               "origin": "bottom_center"})
"""#

    /// A: modelId, keyframes [{t, position, facingDeg?, action?}].
    static let animateCharacter = #"""
    sc = bpy.context.scene
    name = "MUSE_char_" + A["modelId"]
    o = bpy.data.objects.get(name)
    if o is None:
        muse_fail("No " + name + " in the scene: place the character first")
        return
    fps = sc.render.fps / sc.render.fps_base
    o.animation_data_clear()
    o.rotation_mode = 'XYZ'
    prev = math.degrees(o.rotation_euler[2])
    frames = []
    for k in A["keyframes"]:
        f = sc.frame_start + int(round(k["t"] * fps))
        if frames and f <= frames[-1]:
            f = frames[-1] + 1
        o.location = k["position"]
        if k.get("facingDeg") is not None:
            prev = prev + ((k["facingDeg"] - prev + 180.0) % 360.0) - 180.0
        o.rotation_euler = (0.0, 0.0, math.radians(prev))
        o.keyframe_insert(data_path="location", frame=f)
        o.keyframe_insert(data_path="rotation_euler", index=2, frame=f)
        frames.append(f)
    muse_set_interp(o, dict((f, "linear") for f in frames))
    o["muse_actions"] = json.dumps([{"t": k["t"], "action": k["action"]} for k in A["keyframes"] if k.get("action")])
    sc.frame_set(sc.frame_current)
    muse_done({"object": o.name, "keys": len(frames), "frames": frames})
"""#

    /// A: id, shape, size, position, rotationDeg.
    static let addProp = #"""
    name = "MUSE_prop_" + A["id"]
    sx, sy, sz = A["size"]
    shape = A["shape"]
    o = muse_mesh_object(name, [(shape, (sx, sy, sz), (0.0, 0.0, 0.0 if shape == "plane" else sz / 2.0))], 0.62)
    o.animation_data_clear()
    o.rotation_mode = 'XYZ'
    o.location = A["position"]
    o.rotation_euler = [math.radians(v) for v in A["rotationDeg"]]
    o.scale = (1.0, 1.0, 1.0)
    o["muse_shape"] = shape
    muse_done({"object": o.name, "shape": shape, "size": [sx, sy, sz], "origin": "bottom_center"})
"""#

    /// A: keyframes [{t, position, target, focalMm, rollDeg, ease}] (all resolved by the relay), cuts, sensorMm.
    static let setCamera = #"""
    sc = bpy.context.scene
    fps = sc.render.fps / sc.render.fps_base
    cam = bpy.data.objects.get("MUSE_camera")
    if cam is not None and cam.type != 'CAMERA':
        muse_remove("MUSE_camera")
        cam = None
    if cam is None:
        cam = bpy.data.objects.new("MUSE_camera", bpy.data.cameras.new("MUSE_camera"))
        sc.collection.objects.link(cam)
    cd = cam.data
    cam.animation_data_clear()
    cd.animation_data_clear()
    cd.type = 'PERSP'
    cd.sensor_fit = 'AUTO'
    cd.sensor_width = float(A["sensorMm"])
    cd.shift_x = 0.0
    cd.shift_y = 0.0
    cd.clip_start = 0.05
    cd.clip_end = 500.0
    tgt = bpy.data.objects.get("MUSE_camera_target")
    if tgt is not None and tgt.type != 'EMPTY':
        muse_remove("MUSE_camera_target")
        tgt = None
    if tgt is None:
        tgt = bpy.data.objects.new("MUSE_camera_target", None)
        tgt.empty_display_type = 'PLAIN_AXES'
        tgt.empty_display_size = 0.2
        sc.collection.objects.link(tgt)
    tgt.animation_data_clear()
    tgt.rotation_mode = 'QUATERNION'
    for c in list(cam.constraints):
        if c.name.startswith("MUSE_"):
            cam.constraints.remove(c)
    con = cam.constraints.new(type='TRACK_TO')
    con.name = "MUSE_track"
    con.target = tgt
    con.track_axis = 'TRACK_NEGATIVE_Z'
    con.up_axis = 'UP_Y'
    con.use_target_z = True
    cam.rotation_mode = 'XYZ'
    cam.rotation_euler = (0.0, 0.0, 0.0)
    ease = {}
    frames = []
    for k in A["keyframes"]:
        f = sc.frame_start + int(round(k["t"] * fps))
        if frames and f <= frames[-1]:
            f = frames[-1] + 1
        pos = Vector(k["position"])
        tp = Vector(k["target"])
        cam.location = pos
        tgt.location = tp
        # Roll: the target's Z axis is the camera's up (use_target_z), tilted about the view direction.
        up = Vector((0.0, 0.0, 1.0))
        d = tp - pos
        if d.length > 1e-6 and abs(k["rollDeg"]) > 1e-6:
            up = Quaternion(d.normalized(), math.radians(k["rollDeg"])) @ up
        tgt.rotation_quaternion = Vector((0.0, 0.0, 1.0)).rotation_difference(up)
        cd.lens = float(k["focalMm"])
        cam.keyframe_insert(data_path="location", frame=f)
        tgt.keyframe_insert(data_path="location", frame=f)
        tgt.keyframe_insert(data_path="rotation_quaternion", frame=f)
        cd.keyframe_insert(data_path="lens", frame=f)
        ease[f] = k["ease"]
        frames.append(f)
    for idb in (cam, tgt, cd):
        muse_set_interp(idb, ease)
    sc.camera = cam
    cam["muse_cuts"] = json.dumps(A["cuts"])
    sc.frame_set(sc.frame_current)
    muse_done({"camera": cam.name, "target": tgt.name, "keys": len(frames), "frames": frames, "sceneCamera": True})
"""#

    /// A: outDir (absolute, ~/MUSE/CameraSessions/<id>/out), passes, resolutionShort (0 = keep).
    static let renderGuides = #"""
    import os
    from bpy_extras.object_utils import world_to_camera_view
    sc = bpy.context.scene
    out = A["outDir"]
    norm = out.replace("\\", "/").rstrip("/")
    if not os.path.isabs(out) or "/MUSE/CameraSessions/cs_" not in norm or not norm.endswith("/out") or ".." in norm.split("/"):
        muse_fail("Bad output folder")
        return
    if sc.camera is None:
        muse_fail("No scene camera: set the camera first (blender_set_camera)")
        return
    os.makedirs(out, exist_ok=True)
    passes = A["passes"]
    r = sc.render
    img = r.image_settings
    sh = sc.display.shading
    saved = []
    for obj, attrs in ((r, ("engine", "filepath", "resolution_x", "resolution_y", "resolution_percentage", "use_file_extension", "film_transparent", "use_stamp")),
                       (sh, ("light", "color_type", "show_object_outline", "show_shadows", "show_cavity", "show_xray")),
                       (img, ("media_type", "file_format", "color_mode"))):
        for a in attrs:
            if hasattr(obj, a):
                saved.append((obj, a, getattr(obj, a)))
    f0 = sc.frame_current
    files = []

    def settle(name):
        target = os.path.join(out, name)
        if os.path.exists(target):
            return True
        stem, ext = os.path.splitext(name)
        for n in sorted(os.listdir(out)):
            if n.startswith(stem) and n.endswith(ext) and n != name:
                os.replace(os.path.join(out, n), target)
                return True
        return False

    def fresh(name):
        target = os.path.join(out, name)
        if os.path.exists(target):
            os.remove(target)
        return target

    try:
        r.engine = 'BLENDER_WORKBENCH'
        sh.light = 'FLAT'
        sh.color_type = 'OBJECT'
        muse_set(sh, "show_object_outline", True)
        muse_set(sh, "show_shadows", False)
        muse_set(sh, "show_cavity", False)
        muse_set(sh, "show_xray", False)
        r.film_transparent = False
        r.use_stamp = False
        r.use_file_extension = True
        W0, H0 = r.resolution_x * r.resolution_percentage // 100, r.resolution_y * r.resolution_percentage // 100
        short = int(A["resolutionShort"]) if A["resolutionShort"] else min(W0, H0)
        s = short / float(max(1, min(W0, H0)))
        r.resolution_x = max(2, int(round(W0 * s / 2.0)) * 2)
        r.resolution_y = max(2, int(round(H0 * s / 2.0)) * 2)
        r.resolution_percentage = 100
        W, H = r.resolution_x, r.resolution_y
        fps = r.fps / r.fps_base
        fs, fe = sc.frame_start, sc.frame_end

        if "greybox" in passes:
            muse_set(img, "media_type", 'VIDEO')
            img.file_format = 'FFMPEG'
            ff = r.ffmpeg
            muse_set(ff, "format", 'MPEG4')
            muse_set(ff, "codec", 'H264')
            muse_set(ff, "constant_rate_factor", 'MEDIUM')
            muse_set(ff, "ffmpeg_preset", 'GOOD')
            muse_set(ff, "audio_codec", 'NONE')
            r.filepath = fresh("greybox.mp4")
            bpy.ops.render.render(animation=True)
            if settle("greybox.mp4"):
                files.append("greybox.mp4")

        if "keyframes" in passes:
            muse_set(img, "media_type", 'IMAGE')
            img.file_format = 'PNG'
            img.color_mode = 'RGB'
            for nm, f in (("keyframe_start.png", fs), ("keyframe_mid.png", (fs + fe) // 2), ("keyframe_end.png", fe)):
                sc.frame_set(f)
                r.filepath = fresh(nm)
                bpy.ops.render.render(write_still=True)
                if settle(nm):
                    files.append(nm)

        want_cam = "camera_json" in passes
        want_chars = "characters_json" in passes
        if want_cam or want_chars:
            chars = sorted([o for o in sc.objects if o.name.startswith("MUSE_char_")], key=lambda o: o.name)
            cam_frames = []
            char_frames = []
            sensor_out = 0.0
            for f in range(fs, fe + 1):
                sc.frame_set(f)
                t = muse_r6((f - fs) / fps)
                cam = sc.camera
                mw = cam.matrix_world
                loc, rot, _scale = mw.decompose()
                if want_cam:
                    cd = cam.data
                    if cd.sensor_fit == 'VERTICAL':
                        size, px = cd.sensor_height, H
                    elif cd.sensor_fit == 'HORIZONTAL':
                        size, px = cd.sensor_width, W
                    else:
                        size, px = cd.sensor_width, max(W, H)
                    fpx = cd.lens / size * px
                    m = float(max(W, H))
                    cx = W / 2.0 - cd.shift_x * m
                    cy = H / 2.0 + cd.shift_y * m
                    sensor_out = size
                    Rb = rot.to_matrix().transposed()
                    tb = -(Rb @ loc)
                    sign = (1.0, -1.0, -1.0)
                    w2c = [[muse_r6(sign[i] * Rb[i][0]), muse_r6(sign[i] * Rb[i][1]), muse_r6(sign[i] * Rb[i][2]), muse_r6(sign[i] * tb[i])] for i in range(3)]
                    cam_frames.append({"t": t, "frame": f, "position": [muse_r6(v) for v in loc],
                                       "quaternion": [muse_r6(rot.w), muse_r6(rot.x), muse_r6(rot.y), muse_r6(rot.z)],
                                       "focal_mm": muse_r6(cd.lens), "sensor_mm": muse_r6(size),
                                       "fx": muse_r6(fpx), "fy": muse_r6(fpx), "cx": muse_r6(cx), "cy": muse_r6(cy), "w2c": w2c})
                if want_chars:
                    entries = []
                    for o in chars:
                        ow = o.matrix_world
                        p = ow.translation
                        fwd = ow.to_3x3() @ Vector((0.0, -1.0, 0.0))
                        facing = math.degrees(math.atan2(fwd.x, -fwd.y))
                        xs = []
                        ys = []
                        for c in o.bound_box:
                            v = world_to_camera_view(sc, cam, ow @ Vector(c))
                            if v.z > 0:
                                xs.append(v.x)
                                ys.append(1.0 - v.y)
                        bbox = [muse_r6(min(xs)), muse_r6(min(ys)), muse_r6(max(xs)), muse_r6(max(ys))] if xs else None
                        visible = bbox is not None and bbox[2] > 0 and bbox[0] < 1 and bbox[3] > 0 and bbox[1] < 1
                        entries.append({"modelId": str(o.get("muse_model_id", o.name[len("MUSE_char_"):])),
                                        "position": [muse_r6(v) for v in p], "facing_deg": muse_r6(facing),
                                        "bbox": bbox, "visible": visible})
                    char_frames.append({"t": t, "frame": f, "characters": entries})
            header = {"version": 1, "fps": fps, "width": W, "height": H, "aspect": muse_r6(W / float(H)), "frameStart": fs, "frameEnd": fe}
            if want_cam:
                doc = dict(header)
                doc.update({"convention": "Blender world, metres, Z up. quaternion wxyz = camera rotation (looks down its -Z). "
                                          "w2c = OpenCV world-to-camera [R|t] (x right, y down, z forward). fx, fy, cx, cy in pixels.",
                            "sensor_mm": muse_r6(sensor_out), "frames": cam_frames})
                with open(fresh("camera.json"), "w") as fh:
                    json.dump(doc, fh)
                files.append("camera.json")
            if want_chars:
                doc = dict(header)
                doc.update({"convention": "position = root (bottom centre), metres; facing_deg 0 = facing -Y; "
                                          "bbox = [x0, y0, x1, y1] normalised to the frame, origin top-left (null when behind the camera).",
                            "characters": [{"modelId": str(o.get("muse_model_id", "")), "label": str(o.get("muse_label", "")),
                                            "heightM": float(o.get("muse_height_m", 0.0))} for o in chars],
                            "frames": char_frames})
                with open(fresh("characters.json"), "w") as fh:
                    json.dump(doc, fh)
                files.append("characters.json")
        if "set_json" in passes:
            # The set as boxes for the app's 3D preview: MUSE props with their shape, every other visible mesh (not the
            # characters, the floor or the camera) as its world-aligned bounding box. Frame 1, at most 400 objects.
            sc.frame_set(fs)
            objs = []
            for o in sorted(sc.objects, key=lambda o: o.name):
                if len(objs) >= 400:
                    break
                if o.type != 'MESH' or o.name.startswith("MUSE_char_") or o.name == "MUSE_floor" or o.hide_render:
                    continue
                mw = o.matrix_world
                if o.name.startswith("MUSE_prop_"):
                    shape = str(o.get("muse_shape", "box"))
                    d = o.dimensions
                    p = mw.translation
                    rot = [muse_r6(math.degrees(v)) for v in mw.to_euler('XYZ')]
                    objs.append({"name": o.name, "shape": shape, "size": [muse_r6(d.x), muse_r6(d.y), muse_r6(d.z)],
                                 "position": [muse_r6(p.x), muse_r6(p.y), muse_r6(p.z)],
                                 "rotationDeg": rot})
                else:
                    ws = [mw @ Vector(c) for c in o.bound_box]
                    lo = [min(v[i] for v in ws) for i in range(3)]
                    hi = [max(v[i] for v in ws) for i in range(3)]
                    objs.append({"name": o.name[:63], "shape": "box", "size": [muse_r6(hi[i] - lo[i]) for i in range(3)],
                                 "position": [muse_r6((lo[0] + hi[0]) / 2.0), muse_r6((lo[1] + hi[1]) / 2.0), muse_r6(lo[2])],
                                 "rotationDeg": [0.0, 0.0, 0.0]})
            with open(fresh("set.json"), "w") as fh:
                json.dump({"version": 1, "convention": "Blender world, metres, Z up; position = bottom centre (a plane's centre)", "objects": objs}, fh)
            files.append("set.json")
        muse_done({"files": files, "width": W, "height": H, "fps": fps, "frameStart": fs, "frameEnd": fe})
    finally:
        for obj, a, v in saved:
            muse_set(obj, a, v)
        sc.frame_set(f0)
"""#
}
