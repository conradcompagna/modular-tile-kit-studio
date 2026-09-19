"""Build a source-sized two-metre cluster of ordinary human-scale casks, preserving all three literal heights."""
from pathlib import Path
import bpy, json, math
from mathutils import Vector

ROOT=Path(__file__).resolve().parents[1]
recipe=(ROOT/'tools/build_belowward_kit.py').read_text()
exec(compile(recipe.split('# Recessed prison cell fronts')[0],'<approved-barrel-helpers>','exec'))
ART=ROOT/'assets/blackridge_barrels_revision03'
OUT=ROOT/'exports/blackridge_barrels_revision03'
groups=[]
for cx,cz,r,h in ((.4,.4,.34,1.10),(1.65,1.65,.30,.90),(1.7,.35,.26,.70)):
    start=len(PARTS)
    for i in range(16):
        a0=math.tau*(i+.018)/16; a1=math.tau*(i+.982)/16
        vertices=[]
        for t in (0,.08,.3,.7,.94,1):
            radius=r*(.82+.18*math.sin(math.pi*t))
            for a in (a0,a1): vertices.append(world(cx+radius*math.cos(a),cz+radius*math.sin(a),h*t))
        mesh('Coopered oak stave',vertices,[(j*2,j*2+1,j*2+3,j*2+2) for j in range(5)],WOOD)
    for t in (.08,.25,.76,.94):
        radius=r*(.82+.18*math.sin(math.pi*t))+.009
        lathe('Fitted iron hoop',[(radius,h*t),(radius,h*t+.04)],(cx,cz,0),IRON,32)
    lathe('Recessed cask lid',[(0,h-.025),(.81*r,h-.025)],(cx,cz,0),WOOD,16)
    for d in (-r*.4,0,r*.4): beam('Lid seam',(cx-r*.7,cz+d,h-.015),(cx+r*.7,cz+d,h-.015),.010,DARK)
    groups.append(PARTS[start:])

# The native driver is X=2m; only plan spacing is fitted, while all physical vertical dimensions stay exact.
bpy.context.view_layer.update()
points=[ob.matrix_world@v.co for ob in PARTS for v in ob.data.vertices]
lo=Vector([min(v[k] for v in points) for k in range(3)])
hi=Vector([max(v[k] for v in points) for k in range(3)])
factor=Vector((2/(hi.x-lo.x),2/(hi.y-lo.y),1))
for ob in PARTS:
    for v in ob.data.vertices:
        p=ob.matrix_world@v.co
        v.co=Vector(((p.x-lo.x)*factor.x,(p.y-hi.y)*factor.y,p.z))
    ob.matrix_world=Matrix.Identity(4)
measurements=[]
for group in groups:
    p=[v.co for ob in group for v in ob.data.vertices]
    measurements.append({'height_m':max(v.z for v in p)-min(v.z for v in p),'width_m':max(v.x for v in p)-min(v.x for v in p),'depth_m':max(v.y for v in p)-min(v.y for v in p)})
bpy.ops.object.select_all(action='DESELECT')
for ob in PARTS: ob.select_set(True)
bpy.context.view_layer.objects.active=PARTS[0]
bpy.ops.object.join()
ob=bpy.context.object;ob.name='BR3_BARREL_CLUSTER'
path=ART/'barrel_cluster.glb'
bpy.ops.export_scene.gltf(filepath=str(path),export_format='GLB',use_selection=True,export_yup=True,export_animations=False)
report={'asset_id':ob.name,'path':str(path).replace('\\','/'),'grid':[2,2,2],'driver_axis':0,'physical':[2,1.1,2],'individual_casks':measurements,'triangles':sum(len(p.vertices)-2 for p in ob.data.polygons),'source': 'New ordinary casks; no stacked barrels; heights explicitly preserved.'}
(OUT/'kit.json').write_text(json.dumps(report,indent=2))
bpy.ops.wm.save_as_mainfile(filepath=str(ART/'barrels.blend'))
print('BR3_READY '+json.dumps(report),flush=True)
