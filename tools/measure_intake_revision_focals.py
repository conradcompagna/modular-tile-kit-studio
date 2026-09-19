"""Measure the two untouched Meshy sources without modifying their scene or material data."""
from pathlib import Path
import bpy,json,math
from mathutils import Vector
ROOT=Path(__file__).resolve().parents[1]
report={}
for name in ('census_engine','evidence_archive'):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=str(ROOT/'assets/blackridge_intake_revision/meshy'/(name+'.glb')))
    bpy.context.view_layer.update()
    points=[];areas={}
    for ob in bpy.context.scene.objects:
        if ob.type!='MESH':continue
        points.extend(ob.matrix_world@v.co for v in ob.data.vertices)
        ob.data.calc_loop_triangles()
        for tri in ob.data.loop_triangles:
            a,b,c=[ob.matrix_world@ob.data.vertices[i].co for i in tri.vertices]
            cross=(b-a).cross(c-a)
            if cross.length and cross.z/cross.length>.95:
                center=(a+b+c)/3
                key=round(center.z,2)
                areas[key]=areas.get(key,0)+cross.length/2
    lo=Vector([min(p[k] for p in points) for k in range(3)])
    hi=Vector([max(p[k] for p in points) for k in range(3)])
    report[name]={'minimum_blender':list(lo),'maximum_blender':list(hi),'size_xyz_blender':list(hi-lo),'horizontal_surface_area_by_height':sorted(areas.items(),key=lambda a:-a[1])[:30]}
(ROOT/'exports/blackridge_intake_revision/focal_measurements.json').write_text(json.dumps(report,indent=2))
print(json.dumps(report))
