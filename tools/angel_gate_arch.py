"""Build the exact six-metre gate opening using the generated ashlar image."""
from pathlib import Path
import math
import bpy

ROOT = Path(__file__).resolve().parents[1]
ART = ROOT / "assets" / "angel_gate"
bpy.ops.object.select_all(action="SELECT")
bpy.ops.object.delete(use_global=False)
stone = bpy.data.materials.new("GPT ancient limestone")
stone.use_nodes = True
shader = stone.node_tree.nodes.get("Principled BSDF")
shader.inputs["Roughness"].default_value = 0.88
image = bpy.data.images.load(str(ART / "ancient_ashlar.png"))
texture = stone.node_tree.nodes.new("ShaderNodeTexImage")
texture.image = image
stone.node_tree.links.new(texture.outputs["Color"], shader.inputs["Base Color"])


# Project the source masonry at its authored four-metre repeat on each mesh face.
def finish(obj):
    obj.data.materials.append(stone)
    uv = obj.data.uv_layers.new(name="Masonry metres")
    obj.data.update()
    for face in obj.data.polygons:
        axis = max(range(3), key=lambda i: abs(face.normal[i]))
        for loop_index in face.loop_indices:
            p = obj.data.vertices[obj.data.loops[loop_index].vertex_index].co
            uv.data[loop_index].uv = ((p.x if axis != 0 else p.y) / 4, (p.z if axis != 2 else p.y) / 4)
    bevel = obj.modifiers.new("Dressed stone edges", "BEVEL")
    bevel.width = 0.025
    bevel.segments = 2
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.modifier_apply(modifier=bevel.name)


# Add a masonry block in local Blender Z-up coordinates before the exporter changes axes.
def block(name, lo, hi):
    vertices = [(x, y, z) for z in (lo[2], hi[2]) for y in (lo[1], hi[1]) for x in (lo[0], hi[0])]
    faces = [(0, 2, 3, 1), (4, 5, 7, 6), (0, 1, 5, 4), (2, 6, 7, 3), (0, 4, 6, 2), (1, 3, 7, 5)]
    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata(vertices, [], faces)
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)
    finish(obj)


# Extrude the true open arch as separate voussoirs, leaving its passage physically empty.
def voussoir(index, low, high):
    points = []
    for y in (0.04, 1.96):
        for radius, angle in ((2.5, low), (2.5, high), (3.0, high), (3.0, low)):
            points.append((3 + radius * math.cos(angle), y, 5 + radius * math.sin(angle)))
    mesh = bpy.data.meshes.new("Arch stone")
    mesh.from_pydata(points, [], [(0, 3, 2, 1), (4, 5, 6, 7), (0, 1, 5, 4), (1, 2, 6, 5), (2, 3, 7, 6), (3, 0, 4, 7)])
    obj = bpy.data.objects.new(f"Voussoir {index:02}", mesh)
    bpy.context.collection.objects.link(obj)
    finish(obj)


for side, x in [("left", 0), ("right", 5.5)]:
    for course in range(10):
        block(f"{side} jamb {course}", (x, 0, course * 0.5), (x + 0.5, 2, course * 0.5 + 0.49))
for i in range(20):
    voussoir(i, i * math.pi / 20 + 0.001, (i + 1) * math.pi / 20 - 0.001)
for i in range(24):
    x0, x1 = i * 0.25, (i + 1) * 0.25
    bottom = 5 + math.sqrt(max(0, 9 - (min(abs(x0 - 3), abs(x1 - 3))) ** 2))
    block(f"Spandrel {i}", (x0, 0.1, bottom), (x1, 1.9, 8.55))
block("Crowning cornice", (0, 0, 8.55), (6, 2, 8.85))
for i in range(6):
    block(f"Parapet {i}", (i, 0.25, 8.85), (i + 0.55, 1.75, 9.5))
source_dir = ROOT / "exports" / "angel_gate_source"
source_dir.mkdir(parents=True, exist_ok=True)
(source_dir / ".gdignore").touch()
bpy.ops.wm.save_as_mainfile(filepath=str(source_dir / "gate_arch.blend"))
bpy.ops.export_scene.gltf(filepath=str(ART / "gate_arch.glb"), export_format="GLB", export_yup=True, export_animations=False)
print("Gate arch exported: 6m wide, 2m deep, 9.5m tall; 5m clear passage.")
