"""Runs INSIDE Blender (headless): one extracted model folder -> one .usdz.

    blender -b --factory-startup --python pipeline/blender_convert.py -- \
        <tools_dir> <model.trmdl> <out.usdz> [--rare] [--render preview.png]

<tools_dir> holds the community importer addon (cloned as `sv_importer`,
unlicensed, so it lives outside this repo and is only run, never copied) and
`blender_site/` with its flatbuffers dependency. Textures must already be
decoded to PNG next to the model (pipeline/bntx.py).

The importer builds materials around its own game-shader node group, which
USD can't express, so each material is rebuilt as a plain Principled BSDF
fed by the albedo texture. That loses rim light / fur shading but keeps the
real colours, which is what matters on a phone.
"""

import math
import sys

import bpy
from mathutils import Vector

argv = sys.argv[sys.argv.index("--") + 1:]
tools_dir, trmdl, out_path = argv[0], argv[1], argv[2]
rare = "--rare" in argv
render_path = argv[argv.index("--render") + 1] if "--render" in argv else None

sys.path.insert(0, tools_dir)
sys.path.insert(0, tools_dir + "/blender_site")
import sv_importer  # noqa: E402

sv_importer.register()
bpy.ops.wm.read_factory_settings(use_empty=True)
if bpy.ops.import_scene.trmdl(filepath=trmdl, rare=rare, rotate90=True) != {"FINISHED"}:
    raise SystemExit("import failed")

meshes = [o for o in bpy.data.objects if o.type == "MESH"]
if not meshes:
    raise SystemExit("no meshes imported")


def albedo_image(mat):
    if not mat or not mat.node_tree:
        return None
    images = [n.image for n in mat.node_tree.nodes if n.type == "TEX_IMAGE" and n.image]
    for img in images:
        if "_alb" in img.name:
            return img
    return images[0] if images else None


import os  # noqa: E402

MAX_TEXTURE = 1024
bake_dir = os.path.splitext(out_path)[0] + "_tex"
os.makedirs(bake_dir, exist_ok=True)

# 1. Bake each material's final colour (the importer's shader combines albedo,
#    layer masks and per-material colours: eyes, cheeks, patterns) into a
#    plain texture. Cycles "diffuse colour" bake needs no lighting.
scene = bpy.context.scene
scene.render.engine = "CYCLES"
scene.cycles.device = "CPU"
scene.cycles.samples = 1
scene.render.bake.margin = 8

def expose_base_color(mat):
    """Make the material output exactly its Principled 'Base Color' as emission.

    The importer's group mixes a Principled BSDF with an Emission shader using
    Eevee-only nodes (Shader to RGB) that evaluate to black in Cycles, so a
    normal diffuse bake comes out black for many materials. Instead, give
    each material its own copy of the group whose output is an Emission fed by
    whatever drives the Principled base colour (albedo x layer masks x layer
    colours), and bake EMIT.
    """
    for node in mat.node_tree.nodes:
        if node.type != "GROUP" or not node.node_tree:
            continue
        tree = node.node_tree.copy()
        node.node_tree = tree
        principled = next((n for n in tree.nodes if n.type == "BSDF_PRINCIPLED"), None)
        group_out = next((n for n in tree.nodes if n.type == "GROUP_OUTPUT"), None)
        if principled is None or group_out is None:
            continue
        emission = tree.nodes.new("ShaderNodeEmission")
        base = principled.inputs["Base Color"]
        if base.is_linked:
            tree.links.new(base.links[0].from_socket, emission.inputs["Color"])
        else:
            emission.inputs["Color"].default_value = base.default_value
        for link in list(group_out.inputs[0].links):
            tree.links.remove(link)
        tree.links.new(emission.outputs["Emission"], group_out.inputs[0])
        return True
    return False


def normalise_uvs():
    """Shift each material's UVs by whole tiles into 0..1.

    Game models place different materials in different UV tiles (Pikachu's
    hands sit at v 1..2, its ears at v 2.5..3) and rely on texture wrapping.
    Wrapping makes a whole-number shift invisible, but baking only writes
    inside 0..1, so without this those materials bake to black.
    """
    lowest = {}
    for ob in meshes:
        uv = ob.data.uv_layers.active.data
        for poly in ob.data.polygons:
            name = ob.material_slots[poly.material_index].material.name
            for li in poly.loop_indices:
                u, v = uv[li].uv
                lo = lowest.setdefault(name, [u, v])
                lo[0], lo[1] = min(lo[0], u), min(lo[1], v)
    shifts = {name: (math.floor(u), math.floor(v)) for name, (u, v) in lowest.items()}
    for ob in meshes:
        uv = ob.data.uv_layers.active.data
        for poly in ob.data.polygons:
            du, dv = shifts[ob.material_slots[poly.material_index].material.name]
            if du or dv:
                for li in poly.loop_indices:
                    uv[li].uv = (uv[li].uv[0] - du, uv[li].uv[1] - dv)
    return {n: s for n, s in shifts.items() if s != (0, 0)}


uv_shifts = normalise_uvs()
materials = {s.material.name: s.material for ob in meshes for s in ob.material_slots if s.material}
exposed ={name: expose_base_color(mat) for name, mat in materials.items()}
baked = {}
for name, mat in materials.items():
    src = albedo_image(mat)
    w, h = (src.size[0], src.size[1]) if src and src.size[0] else (512, 512)
    scale = min(1.0, MAX_TEXTURE / max(w, h))
    img = bpy.data.images.new("bake_" + name, max(8, int(w * scale)), max(8, int(h * scale)), alpha=False)
    node = mat.node_tree.nodes.new("ShaderNodeTexImage")
    node.image = img
    mat.node_tree.nodes.active = node
    baked[name] = img

bpy.ops.object.select_all(action="DESELECT")
for ob in meshes:
    ob.select_set(True)
bpy.context.view_layer.objects.active = meshes[0]
# New images start blank; clearing here would wipe a texture shared by two
# objects (e.g. hands and tail) when the second one bakes.
bpy.ops.object.bake(type="EMIT", use_clear=False)

for name, img in baked.items():
    safe = "".join(ch if ch.isalnum() or ch in "-_" else "_" for ch in name)
    img.filepath_raw = os.path.join(bake_dir, f"{safe}.png")
    img.file_format = "PNG"
    img.save()

if "--bake-only" in argv:
    # Shiny variant: the app swaps these textures onto the animated normal
    # model at runtime, so no second model (and second copy of the animation).
    print("TG_OK", bake_dir)
    sys.stdout.flush()
    import os as _os
    _os._exit(0)

# 2. Replace every material with a plain Principled BSDF on the baked texture,
#    which USD/RealityKit understand.
rebuilt = {}
for ob in meshes:
    for slot in ob.material_slots:
        old = slot.material
        if old is None:
            continue
        if old.name not in rebuilt:
            mat = bpy.data.materials.new("tg_" + old.name)
            nodes = mat.node_tree.nodes
            nodes.clear()
            out = nodes.new("ShaderNodeOutputMaterial")
            bsdf = nodes.new("ShaderNodeBsdfPrincipled")
            bsdf.inputs["Roughness"].default_value = 0.65
            mat.node_tree.links.new(bsdf.outputs["BSDF"], out.inputs["Surface"])
            tex = nodes.new("ShaderNodeTexImage")
            tex.image = baked[old.name]
            mat.node_tree.links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])
            rebuilt[old.name] = mat
        slot.material = rebuilt[old.name]

# Keep the model standing on the origin, centred, so the app can place it by its feet.
bpy.context.view_layer.update()
corners = [ob.matrix_world @ Vector(c) for ob in meshes for c in ob.bound_box]
min_z = min(c.z for c in corners)
cx = (min(c.x for c in corners) + max(c.x for c in corners)) / 2
cy = (min(c.y for c in corners) + max(c.y for c in corners)) / 2
roots = [o for o in bpy.data.objects if o.parent is None]
for o in roots:
    o.location -= Vector((cx, cy, min_z))
bpy.context.view_layer.update()

height = max(c.z for c in corners) - min_z
print(f"TG_STATS meshes={len(meshes)} materials={len(rebuilt)} height_m={height:.3f} "
      f"unexposed={[n for n, ok in exposed.items() if not ok]} uv_shifts={uv_shifts}")

if render_path:
    # Front view (Blender's -Y side) for a quick visual check of colours and facing.
    scene = bpy.context.scene
    scene.render.engine = "BLENDER_EEVEE"
    scene.render.resolution_x = scene.render.resolution_y = 512
    scene.render.film_transparent = True
    cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam"))
    scene.collection.objects.link(cam)
    cam.data.type = "ORTHO"
    cam.data.ortho_scale = height * 1.3
    cam.location = (0, -5, height / 2)
    cam.rotation_euler = (math.radians(90), 0, 0)
    scene.camera = cam
    sun = bpy.data.objects.new("sun", bpy.data.lights.new("sun", "SUN"))
    scene.collection.objects.link(sun)
    sun.rotation_euler = (math.radians(50), 0, math.radians(20))
    world = bpy.data.worlds.new("w")
    world.color = (0.6, 0.6, 0.6)
    scene.world = world
    scene.render.filepath = render_path
    bpy.ops.render.render(write_still=True)
    bpy.data.objects.remove(cam)
    bpy.data.objects.remove(sun)

def add_clips(paths):
    """Lay the given .tranm clips end to end on the armature's NLA.

    RealityKit plays one animation timeline per USDZ, so the app plays a clip
    by trimming this timeline to the clip's range (written next to the USDZ).
    """
    import json
    import os
    from sv_importer.gfbanm_importer import import_animation

    armature = next((o for o in bpy.data.objects if o.type == "ARMATURE"), None)
    if armature is None or not paths:
        return []
    bpy.ops.object.select_all(action="DESELECT")
    armature.select_set(True)
    bpy.context.view_layer.objects.active = armature
    # The game animates at 60 fps; export at 30 (strips scaled by half, same
    # real-time length) to halve the file. RealityKit interpolates between samples.
    bpy.context.scene.render.fps = 30
    bpy.context.scene.render.fps_base = 1.0
    clips, frame = [], 1
    for item in paths:
        role, path = item["role"], item["path"]
        tracks_before = len(armature.animation_data.nla_tracks) if armature.animation_data else 0
        try:
            # Import at offset 0 and move the strip afterwards: with a non-zero
            # offset the importer shifts the keys but not the strip's action
            # range, so every clip after the first plays empty frames and freezes.
            import_animation(bpy.context, path, False, 0, False, True)
        except Exception as err:  # a broken clip shouldn't sink the whole model
            print(f"TG_CLIP_FAIL {os.path.basename(path)}: {err}")
            continue
        track = armature.animation_data.nla_tracks[tracks_before]
        strip = track.strips[0]
        bpy.context.scene.render.fps = 30  # the importer resets this to the clip's rate
        strip.scale = 0.5
        strip.frame_start_ui = frame      # moves the whole strip, keeping its length
        strip.extrapolation = "NOTHING"   # don't hold this pose over other clips
        start, end = int(strip.frame_start), int(strip.frame_end)
        clips.append({"name": role, "start": start, "end": end})
        frame = end + 2
    scene = bpy.context.scene
    scene.frame_start, scene.frame_end = 1, max(1, frame - 2)
    fps = scene.render.fps / scene.render.fps_base
    for c in clips:
        c["startTime"] = round((c["start"] - 1) / fps, 4)
        c["endTime"] = round((c["end"] - 1) / fps, 4)
    return clips


def write_meta(clips, usdz_path):
    """Sidecar JSON for the app: clip time ranges, and for each mesh the
    materials in the order RealityKit lists them, so shiny textures can be
    swapped onto the right parts at runtime."""
    import json
    import os
    from pxr import Usd, UsdGeom, UsdShade

    stage = Usd.Stage.Open(usdz_path)
    meshes = {}
    for prim in stage.Traverse():
        if not prim.IsA(UsdGeom.Mesh):
            continue
        subsets = UsdShade.MaterialBindingAPI(prim).GetMaterialBindSubsets()
        targets = [UsdShade.MaterialBindingAPI(s.GetPrim()).ComputeBoundMaterial()[0] for s in subsets] \
            if subsets else [UsdShade.MaterialBindingAPI(prim).ComputeBoundMaterial()[0]]
        meshes[prim.GetName()] = [m.GetPrim().GetName() if m else "" for m in targets]
    meta = {"fps": bpy.context.scene.render.fps, "clips": clips, "meshes": meshes,
            "height": round(height, 4)}
    with open(os.path.splitext(usdz_path)[0] + ".json", "w") as f:
        json.dump(meta, f)


anim_paths = []
if "--anims" in argv:
    import json as _json
    anim_paths = _json.loads(open(argv[argv.index("--anims") + 1]).read())
clips = add_clips(anim_paths)
print(f"TG_CLIPS {len(clips)} frames={bpy.context.scene.frame_end}")

if "--render-clips" in argv and clips:
    # Mid-clip snapshots (front view) to eyeball that the animation deforms sensibly.
    import os
    scene = bpy.context.scene
    scene.render.engine = "BLENDER_EEVEE"
    scene.render.resolution_x = scene.render.resolution_y = 384
    scene.render.film_transparent = True
    cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam"))
    scene.collection.objects.link(cam)
    cam.data.type = "ORTHO"
    cam.data.ortho_scale = height * 1.8
    cam.location = (0, -5, height / 2)
    cam.rotation_euler = (math.radians(90), 0, 0)
    scene.camera = cam
    sun = bpy.data.objects.new("sun", bpy.data.lights.new("sun", "SUN"))
    scene.collection.objects.link(sun)
    sun.rotation_euler = (math.radians(50), 0, math.radians(20))
    base = argv[argv.index("--render-clips") + 1]
    for c in clips:
        scene.frame_set((c["start"] + c["end"]) // 2)
        scene.render.filepath = f"{base}_{c['name']}.png"
        bpy.ops.render.render(write_still=True)
    bpy.data.objects.remove(cam)
    bpy.data.objects.remove(sun)
    scene.frame_set(1)

result = bpy.ops.wm.usd_export(
    filepath=out_path,
    export_animation=bool(clips),
    export_armatures=bool(clips),   # skinned + skeleton only when animated
    export_shapekeys=False,
    export_materials=True,
    generate_preview_surface=True,
    export_textures_mode="NEW",
    overwrite_textures=True,
    convert_orientation=True,   # RealityKit is Y-up
    export_global_forward_selection="NEGATIVE_Z",
    export_global_up_selection="Y",
    usdz_downscale_size="1024",
    export_lights=False,
    export_cameras=False,
    triangulate_meshes=True,
)
if result != {"FINISHED"}:
    raise SystemExit(f"USD export failed: {result}")
write_meta(clips, out_path)
print("TG_OK", out_path)
