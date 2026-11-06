# MUSE composer previews, rendered free in Blender (headless, Cycles CPU). One studio set, one grey mannequin; only the
# camera (moves, angles) or the lights (lighting) change. Spec: plans/video-composer.md "Assets needed".
#
#   blender -b --factory-startup --python design/previews/source/render_previews.py -- [--only moves|lighting|angles] [--ids a,b] [--samples 24]
#
# Writes design/previews/{moves,lighting,angles}/ and design/previews/manifest.tsv (id, file, poster, seconds, bytes),
# and saves the set as design/previews/source/muse_preview_set.blend. Moves: 320x400, 24 fps, 60 frames (2.5 s), H.264
# under 300 KB plus a poster JPG. Lighting: 640x400 JPG. Angles: 320x400 JPG. Ids come from server/api/src/suite/camera.ts.
import math, os, shutil, sys, tempfile

import bpy
from mathutils import Euler, Vector

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.normpath(os.path.join(HERE, '..'))
FPS, FRAMES, MAX_BYTES = 24, 60, 300 * 1024
CHEST, HEAD = Vector((0, 0, 1.2)), Vector((0, 0, 1.62))

args = sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else []
def arg(name, default=None):
    return args[args.index(name) + 1] if name in args else default
ONLY, IDS, SAMPLES = arg('--only'), set(filter(None, (arg('--ids') or '').split(','))), int(arg('--samples', '24'))

# ------------------------------------------------------------------ the set
def clear():
    bpy.ops.wm.read_factory_settings(use_empty=True)

def mat(name, rgb, rough=0.6, emit=None, strength=0.0):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    b = m.node_tree.nodes['Principled BSDF']
    b.inputs['Base Color'].default_value = (*rgb, 1)
    b.inputs['Roughness'].default_value = rough
    if emit:
        b.inputs['Emission Color'].default_value = (*emit, 1)
        b.inputs['Emission Strength'].default_value = strength
    return m

def obj(o, name, m=None, parent=None):
    o.name = name
    if m: o.data.materials.append(m)
    if parent: o.parent = parent
    for p in o.data.polygons if hasattr(o.data, 'polygons') else []: p.use_smooth = True
    return o

def cyclorama(m):
    # Floor that curves up into the back wall (one seamless studio sweep), 24 m wide.
    import bmesh
    me = bpy.data.meshes.new('cyc'); bm = bmesh.new()
    prof = [(-14.0, 0.0), (3.0, 0.0)] + [(3.0 + 2.0 * math.sin(a), 2.0 - 2.0 * math.cos(a)) for a in [i * math.pi / 2 / 12 for i in range(1, 13)]] + [(5.0, 9.0)]
    rows = [[bm.verts.new((x, y, z)) for (y, z) in prof] for x in (-12.0, 12.0)]
    for i in range(len(prof) - 1):
        bm.faces.new((rows[0][i], rows[1][i], rows[1][i + 1], rows[0][i + 1]))
    bm.to_mesh(me); bm.free()
    o = bpy.data.objects.new('MUSE_cyc', me); bpy.context.collection.objects.link(o)
    o.data.materials.append(m)
    for p in me.polygons: p.use_smooth = True
    return o

def limb(name, length, radius, m, parent, at):
    bpy.ops.mesh.primitive_cylinder_add(radius=radius, depth=length, vertices=24, location=(0, 0, -length / 2))
    c = obj(bpy.context.object, name, m)
    pivot = bpy.data.objects.new(name + '_pivot', None); bpy.context.collection.objects.link(pivot)
    pivot.parent, pivot.location = parent, at
    c.parent = pivot
    bpy.ops.mesh.primitive_uv_sphere_add(radius=radius * 1.05, location=(0, 0, -length))
    obj(bpy.context.object, name + '_joint', m, pivot)
    return pivot

def mannequin(name, m, height=1.75):
    root = bpy.data.objects.new(name, None); bpy.context.collection.objects.link(root)
    s = height / 1.75
    body = bpy.data.objects.new(name + '_body', None); bpy.context.collection.objects.link(body); body.parent = root
    bpy.ops.mesh.primitive_uv_sphere_add(radius=0.17, location=(0, 0, 1.25 * s)); t = obj(bpy.context.object, name + '_torso', m, body); t.scale = (1.0, 0.62, 1.7)
    bpy.ops.mesh.primitive_uv_sphere_add(radius=0.15, location=(0, 0, 0.95 * s)); p = obj(bpy.context.object, name + '_pelvis', m, body); p.scale = (1.05, 0.7, 0.8)
    bpy.ops.mesh.primitive_uv_sphere_add(radius=0.1, location=(0, 0, 1.46 * s)); sh = obj(bpy.context.object, name + '_shoulders', m, body); sh.scale = (2.05, 0.72, 0.62)
    for x in (-1, 1):
        bpy.ops.mesh.primitive_uv_sphere_add(radius=0.058, location=(x * 0.19, 0, 1.45 * s)); obj(bpy.context.object, f'{name}_shoulder_{x}', m, body)
    bpy.ops.mesh.primitive_cylinder_add(radius=0.05, depth=0.12, location=(0, 0, 1.55 * s)); obj(bpy.context.object, name + '_neck', m, body)
    bpy.ops.mesh.primitive_uv_sphere_add(radius=0.115, location=(0, 0, 1.66 * s)); h = obj(bpy.context.object, name + '_head', m, body); h.scale = (0.85, 0.95, 1.12)
    legs = [limb(f'{name}_leg_{sd}', 0.88 * s, 0.065, m, body, (x * 0.1, 0, 0.9 * s)) for sd, x in (('l', -1), ('r', 1))]
    arms = [limb(f'{name}_arm_{sd}', 0.66 * s, 0.045, m, body, (x * 0.19, 0, 1.45 * s)) for sd, x in (('l', -1), ('r', 1))]
    for a, x in zip(arms, (-1, 1)): a.rotation_euler = (0, x * math.radians(8), 0)
    root['legs'], root['arms'] = [l.name for l in legs], [a.name for a in arms]
    return root

def build_set():
    clear()
    sc = bpy.context.scene
    sc.render.engine = 'CYCLES'; sc.cycles.device = 'CPU'; sc.cycles.samples = SAMPLES
    sc.cycles.use_denoising = True; sc.render.fps = FPS
    sc.view_settings.view_transform = 'AgX'; sc.view_settings.look = 'AgX - Medium High Contrast'
    world = bpy.data.worlds.new('MUSE_world'); sc.world = world; world.use_nodes = True
    world.node_tree.nodes['Background'].inputs['Color'].default_value = (0.012, 0.012, 0.014, 1)
    cyclorama(mat('MUSE_studio', (0.075, 0.072, 0.07), 0.85))
    clay = mat('MUSE_clay', (0.55, 0.54, 0.52), 0.45)
    prop = mat('MUSE_prop', (0.16, 0.155, 0.15), 0.6)
    bpy.ops.mesh.primitive_cube_add(size=1, location=(-1.7, 0.9, 0.45)); o = obj(bpy.context.object, 'MUSE_plinth', prop); o.scale = (0.6, 0.6, 0.9)
    bpy.ops.mesh.primitive_uv_sphere_add(radius=0.22, location=(-1.7, 0.9, 1.12)); obj(bpy.context.object, 'MUSE_sphere', clay)
    bpy.ops.mesh.primitive_cylinder_add(radius=0.22, depth=2.6, location=(1.9, 1.8, 1.3)); obj(bpy.context.object, 'MUSE_column', prop)
    bpy.ops.mesh.primitive_cube_add(size=1, location=(1.2, -1.1, 0.25)); o = obj(bpy.context.object, 'MUSE_box', prop); o.scale = (0.5, 0.5, 0.5)
    # Only for some shots: a doorway to pass through, a foreground pole for the rack focus, a second person, practical lamps.
    door = []
    for x in (-0.75, 0.75):
        bpy.ops.mesh.primitive_cube_add(size=1, location=(x, -2.2, 1.15)); o = obj(bpy.context.object, f'MUSE_door_{x}', prop); o.scale = (0.12, 0.12, 2.3); door.append(o)
    bpy.ops.mesh.primitive_cube_add(size=1, location=(0, -2.2, 2.35)); o = obj(bpy.context.object, 'MUSE_door_top', prop); o.scale = (1.62, 0.12, 0.12); door.append(o)
    bpy.ops.mesh.primitive_cylinder_add(radius=0.045, depth=2.2, location=(0.45, -2.6, 1.1)); pole = obj(bpy.context.object, 'MUSE_pole', clay)
    lamps = []
    for i, (x, y, z) in enumerate(((-1.7, 0.9, 1.25), (1.2, -1.1, 0.65))):
        bpy.ops.mesh.primitive_cylinder_add(radius=0.13, depth=0.2, location=(x, y, z))
        lamps.append(obj(bpy.context.object, f'MUSE_lamp_{i}', mat(f'MUSE_lamp_{i}', (1, 0.8, 0.5), 0.5, (1.0, 0.62, 0.3), 30.0)))
    hero = mannequin('MUSE_hero', clay)
    second = mannequin('MUSE_second', clay, 1.68)
    cam_data = bpy.data.cameras.new('MUSE_cam'); cam = bpy.data.objects.new('MUSE_cam', cam_data); bpy.context.collection.objects.link(cam)
    sc.camera = cam; cam_data.sensor_width = 36; cam_data.clip_start = 0.05
    extras = {'door': door, 'pole': [pole], 'lamps': lamps, 'second': [second] + [c for c in second.children_recursive]}
    return sc, cam, hero, second, extras

def show(extras, *names):
    for k, objs in extras.items():
        for o in objs: o.hide_render = k not in names

# ------------------------------------------------------------------ lights
def light(name, kind, loc, target=CHEST, energy=500.0, color=(1, 1, 1), size=1.0, angle=None):
    d = bpy.data.lights.new(name, kind); d.energy, d.color = energy, color
    if kind == 'AREA': d.size = size
    if kind in ('POINT', 'SPOT'): d.shadow_soft_size = size
    if kind == 'SUN' and angle is not None: d.angle = angle
    o = bpy.data.objects.new(name, d); bpy.context.collection.objects.link(o); o.location = loc
    o.rotation_euler = (Vector(target) - Vector(loc)).to_track_quat('-Z', 'Y').to_euler()
    return o

def clear_lights(sc):
    for o in [o for o in sc.objects if o.type == 'LIGHT']: bpy.data.objects.remove(o)

def world(sc, rgb, strength=1.0):
    bg = sc.world.node_tree.nodes['Background']; bg.inputs['Color'].default_value = (*rgb, 1); bg.inputs['Strength'].default_value = strength

WARM, COOL = (1.0, 0.78, 0.55), (0.65, 0.78, 1.0)
def moody(sc):
    # The default look of every move and angle: dark studio, soft warm key from front-left, cool rim, a pool on the wall.
    clear_lights(sc); world(sc, (0.012, 0.012, 0.014))
    light('key', 'AREA', (-2.6, -2.4, 2.8), energy=380, color=(1.0, 0.9, 0.8), size=1.6)
    light('rim', 'AREA', (2.2, 2.2, 2.6), energy=260, color=COOL, size=1.0)
    light('wall', 'SPOT', (0, -1.5, 4.5), target=(0, 4.4, 2.2), energy=900, color=(1.0, 0.85, 0.7), size=0.3).data.spot_size = math.radians(55)

LIGHTING = {
    'natural': lambda sc: (world(sc, (0.5, 0.5, 0.52), 0.35), light('k', 'AREA', (-1.5, -3.5, 3.5), energy=250, size=3)),
    'window': lambda sc: (world(sc, (0.02, 0.02, 0.025)), light('win', 'AREA', (-3.4, 0.2, 1.9), energy=900, color=(0.92, 0.96, 1.0), size=2.2)),
    'soft_cross': lambda sc: (world(sc, (0.015, 0.015, 0.015)), light('a', 'AREA', (-2.5, -2.5, 2.4), energy=420, size=1.8), light('b', 'AREA', (2.5, 1.8, 2.4), energy=380, size=1.8)),
    'contre_jour': lambda sc: (world(sc, (0.01, 0.01, 0.012)), light('back', 'AREA', (0, 2.2, 2.0), target=(0, -2, 1.2), energy=1600, color=WARM, size=1.2), light('fill', 'AREA', (0, -4, 1.5), energy=25, size=3)),
    'overhead': lambda sc: (world(sc, (0.005, 0.005, 0.005)), light('top', 'SPOT', (0, 0, 4.2), target=(0, 0, 0), energy=1800, size=0.15)),
    'practicals': lambda sc: (world(sc, (0.01, 0.009, 0.008)), light('lamp0', 'POINT', (-1.7, 0.9, 1.25), energy=120, color=WARM, size=0.12), light('lamp1', 'POINT', (1.2, -1.1, 0.7), energy=90, color=WARM, size=0.12)),
    'silhouette': lambda sc: (world(sc, (0.0, 0.0, 0.0)), light('wall', 'AREA', (0, 2.6, 0.4), target=(0, 4.5, 3), energy=2600, color=(1.0, 0.92, 0.85), size=5)),
    'golden_hour': lambda sc: (world(sc, (0.25, 0.16, 0.1), 0.4), light('sun', 'SUN', (-6, -4, 1.2), energy=4.5, color=(1.0, 0.62, 0.32), angle=math.radians(2))),
    'blue_hour': lambda sc: (world(sc, (0.06, 0.09, 0.2), 1.0), light('sky', 'AREA', (0, -2, 4), energy=160, color=COOL, size=4)),
    'ring_light': lambda sc: (world(sc, (0.02, 0.02, 0.02)), light('ring', 'AREA', (0, -2.6, 1.62), target=HEAD, energy=320, size=0.5)),
    'studio_3pt': lambda sc: (world(sc, (0.01, 0.01, 0.01)), light('key', 'AREA', (-2.4, -2.4, 2.6), energy=520, size=1.4), light('fill', 'AREA', (2.6, -2.6, 1.8), energy=140, size=2.0), light('rim', 'AREA', (1.6, 2.0, 2.6), energy=420, size=0.8)),
    'neon': lambda sc: (world(sc, (0.005, 0.0, 0.01)), light('mag', 'AREA', (-2.4, -0.6, 1.8), energy=650, color=(1.0, 0.1, 0.6), size=1.4), light('cyan', 'AREA', (2.4, -0.4, 1.8), energy=600, color=(0.1, 0.8, 1.0), size=1.4)),
    'harsh_sun': lambda sc: (world(sc, (0.35, 0.45, 0.6), 0.6), light('sun', 'SUN', (-2, -3, 6), energy=7.0, color=(1.0, 0.96, 0.9), angle=math.radians(0.5))),
    'overcast': lambda sc: (world(sc, (0.62, 0.64, 0.66), 1.3),),
    'candle': lambda sc: (world(sc, (0.003, 0.002, 0.001)), light('flame', 'POINT', (0.45, -0.7, 1.0), energy=60, color=(1.0, 0.5, 0.18), size=0.04)),
    'moonlight': lambda sc: (world(sc, (0.01, 0.015, 0.035), 0.5), light('moon', 'SUN', (3, -2, 3), energy=0.9, color=(0.55, 0.68, 1.0), angle=math.radians(1))),
    'flash': lambda sc: (world(sc, (0.002, 0.002, 0.002)), light('flash', 'POINT', (0.1, -4.3, 1.5), energy=900, size=0.03)),
}
LIGHTING['auto'] = LIGHTING['natural']

# ------------------------------------------------------------------ camera moves: u in 0..1 → camera state
def ease(u): return 0.5 - 0.5 * math.cos(math.pi * min(1.0, max(0.0, u)))
def lerp(a, b, u): return Vector(a).lerp(Vector(b), u)
def orbit(deg, r=3.8, z=1.45, c=CHEST): a = math.radians(deg); return Vector((c.x + r * math.cos(a), c.y + r * math.sin(a), z))
def shake(f, amp, seed=1.0):
    # Periodic over the clip (integer cycles), so the loop wraps without a jump.
    t = 2 * math.pi * f / FRAMES
    return Vector((amp * (math.sin(3 * t + seed) + 0.5 * math.sin(7 * t + 2 * seed)),
                   amp * 0.4 * math.sin(5 * t + 3 * seed), amp * (math.sin(4 * t + seed * 1.7) + 0.4 * math.sin(9 * t))))
def mv(u): return ease(min(1.0, u / 0.85))  # move for 85 % of the clip, then hold

# Each move: f(frame) -> dict(loc, target | rot, lens, roll, focus, fstop, walk=(start, end, facingDeg, pace), blur, pose)
def walker(start, end, facing, pace=1.0):
    return {'walk': (Vector(start), Vector(end), facing, pace)}

def hero_at(st, f):
    if 'walk' not in st: return Vector((0, 0, 0))
    a, b, _, _ = st['walk']; return a.lerp(b, f / (FRAMES - 1))

MOVES = {
    'static': lambda f, u: dict(loc=(0, -4.5, 1.45), target=CHEST, lens=35),
    'micro_push': lambda f, u: dict(loc=lerp((0, -4.5, 1.45), (0, -4.15, 1.45), mv(u)), target=CHEST, lens=35),
    'handheld': lambda f, u: dict(loc=Vector((0, -3.2, 1.5)) + shake(f, 0.012), target=CHEST + shake(f, 0.02, 2.0), lens=28),
    'selfie': lambda f, u: dict(walker((0, 1.2, 0), (0, -0.8, 0), 0, 1.0), cam_offset=(0.12, -0.62, 1.55), target_offset=(0, 0, 1.62), lens=20, sway=0.012),
    'dolly_in': lambda f, u: dict(loc=lerp((0, -5.8, 1.45), (0, -2.6, 1.45), mv(u)), target=CHEST, lens=35),
    'dolly_out': lambda f, u: dict(loc=lerp((0, -2.4, 1.45), (0, -6.8, 1.6), mv(u)), target=CHEST, lens=35),
    'truck_left': lambda f, u: (lambda p: dict(loc=p, target=p + Vector((0, 4.2, -0.25)), lens=35))(lerp((1.4, -4.2, 1.45), (-1.4, -4.2, 1.45), mv(u))),
    'truck_right': lambda f, u: (lambda p: dict(loc=p, target=p + Vector((0, 4.2, -0.25)), lens=35))(lerp((-1.4, -4.2, 1.45), (1.4, -4.2, 1.45), mv(u))),
    'pan_left': lambda f, u: dict(loc=(0, -4.5, 1.45), target=lerp((2.2, 0, 1.2), (-2.2, 0, 1.2), mv(u)), lens=35),
    'pan_right': lambda f, u: dict(loc=(0, -4.5, 1.45), target=lerp((-2.2, 0, 1.2), (2.2, 0, 1.2), mv(u)), lens=35),
    'tilt_up': lambda f, u: dict(loc=(0, -3.6, 1.3), target=lerp((0, 0, 0.15), (0, 0, 1.75), mv(u)), lens=35),
    'tilt_down': lambda f, u: dict(loc=(0, -3.6, 1.3), target=lerp((0, 0, 1.75), (0, 0, 0.15), mv(u)), lens=35),
    'orbit_left': lambda f, u: dict(loc=orbit(-90 - 90 * mv(u)), target=CHEST, lens=35),
    'orbit_right': lambda f, u: dict(loc=orbit(-90 + 90 * mv(u)), target=CHEST, lens=35),
    'orbit_360': lambda f, u: dict(loc=orbit(-90 + 360 * f / FRAMES), target=CHEST, lens=35),
    'crane_up': lambda f, u: dict(loc=lerp((0, -4.4, 0.55), (0, -4.4, 3.4), mv(u)), target=CHEST, lens=32),
    'crane_down': lambda f, u: dict(loc=lerp((0, -4.4, 3.4), (0, -4.4, 0.55), mv(u)), target=CHEST, lens=32),
    'crane_overhead': lambda f, u: dict(loc=lerp((0, -3.6, 1.6), (0, -0.35, 4.3), mv(u)), target=(0, 0, 1.1), lens=28),
    'pedestal_up': lambda f, u: (lambda z: dict(loc=(0, -3.8, z), target=(0, 0, z - 0.1), lens=35))(0.7 + 1.5 * mv(u)),
    'pedestal_down': lambda f, u: (lambda z: dict(loc=(0, -3.8, z), target=(0, 0, z - 0.1), lens=35))(2.2 - 1.5 * mv(u)),
    'zoom_in': lambda f, u: dict(loc=(0, -6.0, 1.45), target=CHEST, lens=28 + 57 * mv(u)),
    'zoom_out': lambda f, u: dict(loc=(0, -6.0, 1.45), target=CHEST, lens=85 - 57 * mv(u)),
    'crash_zoom': lambda f, u: dict(loc=(0, -6.0, 1.5), target=HEAD, lens=28 + 92 * ease(min(1.0, max(0.0, (u - 0.38) / 0.14))), blur=True),
    'dolly_zoom': lambda f, u: (lambda d: dict(loc=(0, -d, 1.45), target=CHEST, lens=24 * d / 2.4))(2.4 + 4.6 * mv(u)),
    'rack_focus': lambda f, u: dict(loc=(0.75, -3.6, 1.25), target=(0.1, 0, 1.2), lens=85, fstop=1.4, show=('pole',),
                                    focus=1.15 + (3.5 - 1.15) * ease(min(1.0, max(0.0, (u - 0.35) / 0.3)))),
    'follow': lambda f, u: dict(walker((0, -2.4, 0), (0, 0.9, 0), 180, 1.0), cam_offset=(0.15, -2.1, 1.6), target_offset=(0, 0.5, 1.25), lens=32, sway=0.006),
    'track_side': lambda f, u: dict(walker((-1.6, 0, 0), (1.6, 0, 0), 90, 1.0), cam_offset=(0, -3.0, 1.4), target_offset=(0, 0, 1.15), lens=35),
    'lead': lambda f, u: dict(walker((0, 1.4, 0), (0, -1.2, 0), 0, 1.0), cam_offset=(0, -2.5, 1.55), target_offset=(0, 0, 1.35), lens=35, sway=0.005),
    'steadicam': lambda f, u: dict(walker((-0.6, -2.2, 0), (0.4, 0.9, 0), 160, 0.9), cam_offset=(0.5 * math.sin(math.pi * u), -2.2, 1.6), target_offset=(0, 0.4, 1.3), lens=28, sway=0.004),
    'snorricam': lambda f, u: dict(walker((0, 1.6, 0), (0, -0.9, 0), 0, 1.1), cam_offset=(0, -0.68, 1.3), target_offset=(0, 0, 1.6), lens=16, rigid=True),
    'fpv': lambda f, u: (lambda p, q: dict(loc=p, target=q, lens=16, roll=-28 * math.sin(math.pi * u), blur=True))(
        Vector((-3.4 + 6.4 * u, -7.0 + 6.2 * math.sin(math.pi * u * 0.9), 0.7 + 0.5 * math.sin(math.pi * u))),
        Vector((-2.6 + 6.0 * u, 1.0 - 0.6 * u, 1.0))),
    'drone_reveal': lambda f, u: dict(loc=lerp((0, -2.0, 0.45), (0, -8.5, 5.8), mv(u)), target=lerp((0, 0, 1.0), (0, 0.5, 0.6), mv(u)), lens=24),
    'flyover': lambda f, u: (lambda p: dict(loc=p, target=p + Vector((2.2, 2.6, -3.8)), lens=24))(lerp((-4.5, -6.5, 4.4), (2.5, 1.5, 4.4), u)),
    'whip_pan': lambda f, u: dict(loc=(0, -4.2, 1.45), target=lerp((-2.6, 1.0, 1.0), (0, 0, 1.2), ease(min(1.0, max(0.0, (u - 0.42) / 0.1)))), lens=35, blur=True),
    'dutch_push': lambda f, u: dict(loc=lerp((0, -5.2, 1.45), (0, -3.0, 1.45), mv(u)), target=CHEST, lens=35, roll=15 * mv(u)),
    'through_object': lambda f, u: dict(loc=lerp((0, -5.6, 1.35), (0, -1.5, 1.4), mv(u)), target=CHEST, lens=28, show=('door',)),
    'top_down_spin': lambda f, u: dict(loc=(0, 0, 5.4), rot=(0, 0, 2 * math.pi * f / FRAMES), lens=24),
    'bullet_time': lambda f, u: dict(loc=orbit(-120 + 180 * u, r=3.2, z=1.5), target=(0, 0, 1.4), lens=35, pose='jump'),
    'hyperlapse': lambda f, u: dict(loc=lerp((0, -8.0, 1.5), (0, -2.8, 1.45), (f // 5) * 5 / (FRAMES - 1)) + shake(f // 5 * 5, 0.02, 4.0), target=CHEST, lens=28),
    'handheld_run': lambda f, u: dict(walker((-2.2, -0.4, 0), (2.0, 0.4, 0), 80, 1.8), cam_offset=(-1.6, -1.9, 1.5), target_offset=(0, 0, 1.2), lens=24, sway=0.035, blur=True),
}

def pose(hero, f, st):
    legs = [bpy.data.objects[n] for n in hero['legs']]; arms = [bpy.data.objects[n] for n in hero['arms']]
    hero.location = (0, 0, 0); hero.rotation_euler = (0, 0, 0)
    for l in legs: l.rotation_euler = (0, 0, 0)
    for i, a in enumerate(arms): a.rotation_euler = (0, (1 if i else -1) * math.radians(8), 0)
    if st.get('pose') == 'jump':
        hero.location = (0, 0, 0.32)
        legs[0].rotation_euler = (math.radians(-55), 0, 0); legs[1].rotation_euler = (math.radians(25), 0, 0)
        arms[0].rotation_euler = (math.radians(-150), 0, 0); arms[1].rotation_euler = (math.radians(40), 0, 0)
    if 'walk' in st:
        a, b, facing, pace = st['walk']
        hero.location = hero_at(st, f); hero.rotation_euler = (0, 0, math.radians(facing))
        ph = 2 * math.pi * 3 * pace * f / FRAMES  # whole steps per clip: the legs wrap with the loop
        swing = math.radians(28 * min(1.6, pace))
        legs[0].rotation_euler = (swing * math.sin(ph), 0, 0); legs[1].rotation_euler = (-swing * math.sin(ph), 0, 0)
        arms[0].rotation_euler = (-0.8 * swing * math.sin(ph), arms[0].rotation_euler.y, 0); arms[1].rotation_euler = (0.8 * swing * math.sin(ph), arms[1].rotation_euler.y, 0)
        hero.location.z = 0.025 * abs(math.sin(ph))

def camera_state(sc, cam, hero, extras, move, f):
    u = f / (FRAMES - 1)
    st = MOVES[move](f, u)
    pose(hero, f, st)
    if 'walk' in st:
        base = hero.location.copy(); rz = Euler((0, 0, math.radians(st['walk'][2])))
        off = Vector(st['cam_offset']); toff = Vector(st['target_offset'])
        if st.get('rigid'): off.rotate(rz); toff.rotate(rz)
        loc = base + off + shake(f, st.get('sway', 0.0), 3.0); target = base + toff
    else:
        loc, target = Vector(st['loc']), Vector(st.get('target', CHEST))
    cam.location = loc
    if 'rot' in st:
        cam.rotation_euler = Euler(st['rot'])
    else:
        cam.rotation_euler = (target - loc).to_track_quat('-Z', 'Y').to_euler()
        if st.get('roll'): cam.rotation_euler.rotate_axis('Z', math.radians(st['roll']))
    cam.data.lens = st.get('lens', 35)
    cam.data.dof.use_dof = 'fstop' in st
    if 'fstop' in st:
        cam.data.dof.aperture_fstop = st['fstop']; cam.data.dof.focus_distance = st['focus']
    sc.render.use_motion_blur = bool(st.get('blur')); sc.render.motion_blur_shutter = 0.5
    show(extras, *st.get('show', ()))

def key_all(sc, cam, hero):
    objs = [cam, hero] + [bpy.data.objects[n] for n in list(hero['legs']) + list(hero['arms'])]
    for o in objs:
        o.keyframe_insert('location', frame=sc.frame_current); o.keyframe_insert('rotation_euler', frame=sc.frame_current)
    cam.data.keyframe_insert('lens', frame=sc.frame_current)
    cam.data.dof.keyframe_insert('focus_distance', frame=sc.frame_current)

# ------------------------------------------------------------------ rendering and encoding
def render_png(sc, path):
    sc.render.image_settings.file_format = 'PNG'; sc.render.filepath = path
    bpy.ops.render.render(write_still=True)

def png_to_jpg(png, jpg, w, h, quality=82):
    img = bpy.data.images.load(png); sc = bpy.context.scene
    s = sc.render.image_settings; old = (s.file_format, s.quality)
    s.file_format, s.quality = 'JPEG', quality
    img.save_render(jpg, scene=sc); bpy.data.images.remove(img)
    s.file_format, s.quality = old

def encode(frames_dir, mp4, kbps):
    # A throwaway scene whose sequencer plays the PNG frames, written as H.264 at the given bitrate.
    enc = bpy.data.scenes.new('MUSE_encode'); enc.sequence_editor_create()
    files = sorted(os.listdir(frames_dir))
    strip = enc.sequence_editor.sequences.new_image('frames', os.path.join(frames_dir, files[0]), 1, 1)
    for f in files[1:]: strip.elements.append(f)
    enc.frame_start, enc.frame_end = 1, len(files); enc.render.fps = FPS
    enc.render.resolution_x, enc.render.resolution_y, enc.render.resolution_percentage = 320, 400, 100
    r = enc.render; r.image_settings.file_format = 'FFMPEG'; r.ffmpeg.format = 'MPEG4'; r.ffmpeg.codec = 'H264'
    r.ffmpeg.constant_rate_factor = 'NONE'; r.ffmpeg.video_bitrate = kbps; r.ffmpeg.maxrate = int(kbps * 1.5); r.ffmpeg.buffersize = kbps * 2
    r.ffmpeg.gopsize = 12; r.ffmpeg.audio_codec = 'NONE'; r.use_sequencer = True
    r.filepath = mp4; r.use_file_extension = False
    with bpy.context.temp_override(scene=enc):
        bpy.ops.render.render(animation=True, scene=enc.name)
    bpy.data.scenes.remove(enc)

MANIFEST = []
def record(kind, id_, file, poster, seconds):
    MANIFEST.append((f'{kind}/{id_}', f'{kind}/{file}', f'{kind}/{poster}' if poster else '', seconds, os.path.getsize(os.path.join(OUT, kind, file))))

def render_moves(sc, cam, hero, extras):
    os.makedirs(os.path.join(OUT, 'moves'), exist_ok=True)
    sc.render.resolution_x, sc.render.resolution_y, sc.render.resolution_percentage = 320, 400, 100
    for move in MOVES:
        if IDS and move not in IDS: continue
        moody(sc); tmp = tempfile.mkdtemp(prefix=f'muse_{move}_')
        cam.animation_data_clear(); hero.animation_data_clear()
        for f in range(FRAMES):
            sc.frame_set(f + 1); camera_state(sc, cam, hero, extras, move, f); key_all(sc, cam, hero)
        for f in range(FRAMES):
            sc.frame_set(f + 1); render_png(sc, os.path.join(tmp, f'{f:04d}.png'))
        mp4 = os.path.join(OUT, 'moves', f'{move}.mp4')
        for kbps in (760, 560, 420, 300):
            encode(tmp, mp4, kbps)
            if os.path.getsize(mp4) < MAX_BYTES: break
        png_to_jpg(os.path.join(tmp, f'{int(FRAMES * 0.6):04d}.png'), os.path.join(OUT, 'moves', f'{move}.jpg'), 320, 400)
        shutil.rmtree(tmp, ignore_errors=True)
        record('moves', move, f'{move}.mp4', f'{move}.jpg', FRAMES / FPS)
        print(f'MUSE move {move}: {os.path.getsize(mp4)} bytes', flush=True)

def still(sc, kind, id_, w, h):
    sc.render.resolution_x, sc.render.resolution_y, sc.render.resolution_percentage = w, h, 100
    tmp = tempfile.mkdtemp(prefix='muse_still_'); png = os.path.join(tmp, 'f.png')
    render_png(sc, png); png_to_jpg(png, os.path.join(OUT, kind, f'{id_}.jpg'), w, h, 86)
    shutil.rmtree(tmp, ignore_errors=True); record(kind, id_, f'{id_}.jpg', '', 0)

def set_cam(cam, loc, target, lens=35, roll=0.0):
    cam.animation_data_clear(); cam.data.animation_data_clear()
    cam.location = Vector(loc); cam.rotation_euler = (Vector(target) - Vector(loc)).to_track_quat('-Z', 'Y').to_euler()
    if roll: cam.rotation_euler.rotate_axis('Z', math.radians(roll))
    cam.data.lens = lens; cam.data.dof.use_dof = False

def render_lighting(sc, cam, hero, extras):
    os.makedirs(os.path.join(OUT, 'lighting'), exist_ok=True)
    hero.animation_data_clear(); pose(hero, 0, {})
    set_cam(cam, (0.9, -4.6, 1.45), (0.1, 0, 1.15), 35)
    for id_, fn in LIGHTING.items():
        if IDS and id_ not in IDS: continue
        clear_lights(sc); show(extras, *(('lamps',) if id_ in ('practicals', 'candle') else ()))
        fn(sc); still(sc, 'lighting', id_, 640, 400)

ANGLES = {  # HEIGHTS and SHOT_SIZES (server/api/src/suite/camera.ts)
    'eye': dict(loc=(0, -3.6, 1.62), target=(0, 0, 1.5)), 'shoulder': dict(loc=(0, -3.6, 1.42), target=(0, 0, 1.45)),
    'low': dict(loc=(0, -3.0, 0.55), target=(0, 0, 1.45), lens=28), 'high': dict(loc=(0, -3.0, 2.9), target=(0, 0, 1.0), lens=30),
    'overhead': dict(loc=(0, -0.05, 5.2), target=(0, 0, 0), lens=28), 'worm': dict(loc=(0, -1.6, 0.08), target=(0, 0, 1.7), lens=18),
    'ground': dict(loc=(0, -3.4, 0.12), target=(0, 0, 0.5), lens=24), 'hip': dict(loc=(0, -3.2, 0.95), target=(0, 0, 1.15)),
    'els': dict(loc=(0, -11.0, 2.0), target=(0, 0, 1.4), lens=18), 'ls': dict(loc=(0, -7.0, 1.5), target=(0, 0, 1.2), lens=24),
    'full': dict(loc=(0, -4.6, 1.3), target=(0, 0, 0.9), lens=35), 'cowboy': dict(loc=(0, -3.4, 1.35), target=(0, 0, 1.15), lens=35),
    'ms': dict(loc=(0, -2.6, 1.45), target=(0, 0, 1.3), lens=40), 'mcu': dict(loc=(0, -2.0, 1.55), target=(0, 0, 1.45), lens=50),
    'cu': dict(loc=(0, -1.6, 1.64), target=(0, 0, 1.62), lens=65), 'ecu': dict(loc=(0, -0.75, 1.66), target=(0, 0, 1.66), lens=85),
    'insert': dict(loc=(-1.7, 0.15, 1.45), target=(-1.7, 0.9, 1.12), lens=60),
    'ots': dict(loc=(0.3, -2.6, 1.62), target=(0, 0, 1.5), lens=40, second=((0.45, -1.7, 0), 180)),
    'pov': dict(loc=(0, -0.05, 1.62), target=(-1.6, 0.8, 1.1), lens=24, hide_hero=True),
    'two_shot': dict(loc=(0, -4.2, 1.5), target=(0, 0, 1.3), lens=35, second=((0.75, 0.1, 0), 0), hero_at=(-0.45, 0, 0)),
}

def render_angles(sc, cam, hero, second, extras):
    os.makedirs(os.path.join(OUT, 'angles'), exist_ok=True)
    moody(sc); hero.animation_data_clear(); pose(hero, 0, {})
    for id_, a in ANGLES.items():
        if IDS and id_ not in IDS: continue
        show(extras, *(('second',) if 'second' in a else ()))
        if 'second' in a: second.location, second.rotation_euler = Vector(a['second'][0]), (0, 0, math.radians(a['second'][1]))
        hero.location = Vector(a.get('hero_at', (0, 0, 0)))
        for o in [hero] + list(hero.children_recursive): o.hide_render = bool(a.get('hide_hero'))
        set_cam(cam, a['loc'], a['target'], a.get('lens', 35))
        still(sc, 'angles', id_, 320, 400)
        for o in [hero] + list(hero.children_recursive): o.hide_render = False

def write_manifest():
    path = os.path.join(OUT, 'manifest.tsv')
    rows = {}
    if os.path.exists(path):  # keep rows of kinds/ids not rendered this time
        for line in open(path).read().splitlines()[1:]:
            parts = line.split('\t'); rows[parts[0]] = parts
    for id_, file, poster, seconds, size in MANIFEST: rows[id_] = [id_, file, poster, f'{seconds:.2f}', str(size)]
    with open(path, 'w') as f:
        f.write('id\tfile\tposter\tseconds\tbytes\n')
        for k in sorted(rows): f.write('\t'.join(rows[k]) + '\n')

def main():
    sc, cam, hero, second, extras = build_set()
    moody(sc); show(extras)
    bpy.ops.wm.save_as_mainfile(filepath=os.path.join(HERE, 'muse_preview_set.blend'), compress=True)
    if ONLY in (None, 'moves'): render_moves(sc, cam, hero, extras)
    if ONLY in (None, 'lighting'): render_lighting(sc, cam, hero, extras)
    if ONLY in (None, 'angles'): render_angles(sc, cam, hero, second, extras)
    write_manifest()
    print(f'MUSE previews: {len(MANIFEST)} files', flush=True)

main()
