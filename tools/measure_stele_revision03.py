"""Measure the generated stele and ray-sample both candidate inscription faces before attaching deterministic letters."""
from pathlib import Path
import bpy,json
from mathutils import Vector
from mathutils.bvhtree import BVHTree
ROOT=Path(__file__).resolve().parents[1]
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=str(ROOT/'assets/blackridge_intake_revision03/meshy/panopticon_stele.glb'))
bpy.context.view_layer.update()
vertices=[];faces=[]
for ob in bpy.context.scene.objects:
    if ob.type!='MESH':continue
    start=len(vertices);vertices.extend(ob.matrix_world@v.co for v in ob.data.vertices)
    faces.extend(tuple(start+i for i in p.vertices) for p in ob.data.polygons)
lo=Vector([min(p[k] for p in vertices) for k in range(3)]);hi=Vector([max(p[k] for p in vertices) for k in range(3)])
tree=BVHTree.FromPolygons(vertices,faces)
samples=[]
for sign in (-1,1):
    for height in (.30,.40,.50,.60,.70):
        for lateral in (-.18,0,.18):
            p=Vector(((lo.x+hi.x)/2+(hi.x-lo.x)*lateral,sign*3,lo.z+(hi.z-lo.z)*height))
            hit,normal,index,distance=tree.ray_cast(p,Vector((0,-sign,0)))
            samples.append({'side':sign,'height_fraction':height,'lateral_fraction':lateral,'point':list(hit) if hit else None,'normal':list(normal) if normal else None})
report={'min_blender':list(lo),'max_blender':list(hi),'size_blender':list(hi-lo),'samples':samples}
(ROOT/'exports/blackridge_intake_revision03/stele_measurements.json').write_text(json.dumps(report,indent=2))
print('STELE_MEASURE '+json.dumps(report),flush=True)
