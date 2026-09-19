"""Reuse finished BW stone courses and cap for the intake's one-cell rail terminations."""
import bpy, bmesh, json
from pathlib import Path
from mathutils import Matrix, Vector
ROOT=Path(__file__).resolve().parents[1]
# The full finish recipe already owns a clean scene and its workstation materials.
if 'PARTS' not in globals():
    bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=str(ROOT/'tile_library/assets/BW_PIER_WORN/source/pier_worn.glb'))
ob=next(o for o in bpy.context.selected_objects if o.type=='MESH')
bpy.context.view_layer.update()
for v in ob.data.vertices: v.co=ob.matrix_world@v.co
ob.matrix_world=Matrix.Identity(4)
bm=bmesh.new();bm.from_mesh(ob.data)
bmesh.ops.remove_doubles(bm,verts=list(bm.verts),dist=.00001)
remaining=set(bm.verts);retained=[];discard=[]
while remaining:
    seed=remaining.pop();group={seed};stack=[seed]
    while stack:
        v=stack.pop()
        for edge in v.link_edges:
            other=edge.other_vert(v)
            if other in remaining:
                remaining.remove(other);group.add(other);stack.append(other)
    lo=Vector([min(v.co[k] for v in group) for k in range(3)])
    hi=Vector([max(v.co[k] for v in group) for k in range(3)])
    is_core=hi.z-lo.z>4
    is_cap=hi.x-lo.x>.99 and lo.z>4.6
    if is_core:
        # The full cell is a real bearing surface at both rail heights, without metal tabs.
        # Its original UVs retain the approved stone texture; the top is covered by the cap.
        for v in group:
            v.co.x=(v.co.x-lo.x)/(hi.x-lo.x)
            v.co.y=-1+(v.co.y-lo.y)/(hi.y-lo.y)
            v.co.z=min(v.co.z,1.63)
        # The donor was five metres tall: remap the shortened core at the kit's
        # four-metres-per-UV scale instead of compressing five metres of ashlar.
        uv=bm.loops.layers.uv.active
        for face in {f for v in group for f in v.link_faces}:
            axis=max(range(3),key=lambda k:abs(face.normal[k]))
            for loop in face.loops:
                q=loop.vert.co
                loop[uv].uv=((q.x if axis!=0 else -q.y)/4,(q.z if axis!=2 else -q.y)/4)
    elif is_cap:
        for v in group: v.co.z+=1.9-hi.z
    elif hi.z<1.61:
        # Four original half-metre-ish courses preserve real joint/chip silhouettes.
        for v in group: v.co.y-=.015
    else:
        discard.extend(group);continue
    retained.append({'kind':'core' if is_core else 'cap' if is_cap else 'course','source_lo':list(lo),'source_hi':list(hi)})
bmesh.ops.delete(bm,geom=discard,context='VERTS')
bm.to_mesh(ob.data);bm.free();ob.data.update()
ob.name='BI_RAIL_JUNCTION'
bpy.ops.object.select_all(action='DESELECT');ob.select_set(True);bpy.context.view_layer.objects.active=ob
out=ROOT/'assets/blackridge_intake/rail_junction.glb'
bpy.ops.export_scene.gltf(filepath=str(out),export_format='GLB',use_selection=True,export_animations=False,export_yup=True)
points=[v.co for v in ob.data.vertices]
report={'donor':'BW_PIER_WORN','lo':[min(v[k] for v in points) for k in range(3)],'hi':[max(v[k] for v in points) for k in range(3)],'triangles':sum(len(p.vertices)-2 for p in ob.data.polygons),'retained_components':retained,'materials':[m.name for m in ob.data.materials]}
(ROOT/'exports/blackridge_intake/stone_junction_measurements.json').write_text(json.dumps(report,indent=2))
print(json.dumps({k:v for k,v in report.items() if k!='retained_components'}),flush=True)
