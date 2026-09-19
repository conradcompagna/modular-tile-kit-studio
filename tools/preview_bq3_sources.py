"""Produce explicitly labeled CPU source-construction previews without changing saved artwork or game lighting."""
from pathlib import Path
import bpy
from mathutils import Vector

ROOT=Path(__file__).resolve().parents[1]
bpy.ops.wm.open_mainfile(filepath=str(ROOT/'exports/blackridge_quarantine_revision03/bq3_architecture.blend'))
scene=bpy.context.scene
scene.render.engine='CYCLES'
scene.cycles.device='CPU'
scene.cycles.samples=12
scene.cycles.use_denoising=True
scene.render.threads_mode='FIXED'
scene.render.threads=4
scene.render.resolution_x=1200
scene.render.resolution_y=850
scene.render.resolution_percentage=100
scene.world=bpy.data.worlds.new('Neutral source inspection world')
scene.world.use_nodes=True
scene.world.node_tree.nodes['Background'].inputs['Color'].default_value=(.21,.25,.32,1)
scene.world.node_tree.nodes['Background'].inputs['Strength'].default_value=.65
sun_data=bpy.data.lights.new('Neutral source inspection key','SUN')
sun_data.energy=2.0
sun=bpy.data.objects.new('Neutral source inspection key',sun_data)
scene.collection.objects.link(sun)
sun.rotation_euler=(.52,-.45,-.7)
cam_data=bpy.data.cameras.new('CPU source inspection camera')
cam=bpy.data.objects.new('CPU source inspection camera',cam_data)
scene.collection.objects.link(cam)
cam_data.type='ORTHO'
scene.camera=cam
for name,position,focus,size in [
    ('tenement_row_west',(30,-26,17),(3,-18,6),43),
    ('tenement_row_east',(-26,-29,18),(3,-18,6),43),
    ('prison_facade',(35,-32,23),(14,-3,7),34),
]:
    for ob in scene.objects:
        if ob.type=='MESH':
            ob.hide_render=ob.name!=name
            ob.hide_set(ob.name!=name)
    cam.location=position
    cam.rotation_euler=(Vector(focus)-cam.location).to_track_quat('-Z','Y').to_euler()
    cam_data.ortho_scale=size
    scene.render.filepath=str(ROOT/'captures/blackridge_quarantine_revision03'/('SOURCE_ONLY_'+name+'.png'))
    bpy.ops.render.render(write_still=True)
print('BQ3_CPU_SOURCE_PREVIEWS_COMPLETE',flush=True)
