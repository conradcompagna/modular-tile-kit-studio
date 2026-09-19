"""Render the actual underlying terrain quads as a technical review image."""
from pathlib import Path
import bpy

ROOT=Path(__file__).resolve().parents[1]
scene=bpy.context.scene
bpy.data.collections['02 GLB obstacles and wall ornaments'].hide_render=True
terrain=bpy.data.collections['01 WALKABLE - native 1m quads'].objects[0]
clay=bpy.data.materials.new('Grid review clay')
clay.diffuse_color=(.27,.35,.39,1)
clay.use_nodes=True
clay.node_tree.nodes['Principled BSDF'].inputs['Base Color'].default_value=(.27,.35,.39,1)
terrain.data.materials.clear()
terrain.data.materials.append(clay)
for face in terrain.data.polygons:
    face.material_index=0
wire=terrain.copy()
wire.data=terrain.data.copy()
bpy.data.collections['01 WALKABLE - native 1m quads'].objects.link(wire)
line=bpy.data.materials.new('One metre grid lines')
line.diffuse_color=(.012,.018,.021,1)
wire.data.materials.clear()
wire.data.materials.append(line)
modifier=wire.modifiers.new('Every actual quad edge','WIREFRAME')
modifier.thickness=.012
modifier.use_replace=True
scene.camera=bpy.data.objects['Gameplay overview']
scene.cycles.samples=24
scene.render.filepath=str(ROOT/'captures'/'angel_blender_heightfield.png')
bpy.ops.render.render(write_still=True)
print('Rendered the authored terrain with its actual one-metre quad edges.')
