"""Measure complete stone components so the intake variant can reuse finished donor geometry."""
import bpy, json, bmesh
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=str(ROOT/'tile_library/assets/BW_PIER_WORN/source/pier_worn.glb'))
out=[]
for ob in bpy.context.scene.objects:
    if ob.type!='MESH': continue
    bm=bmesh.new();bm.from_mesh(ob.data)
    bmesh.ops.remove_doubles(bm,verts=list(bm.verts),dist=0.00001)
    remaining=set(bm.verts)
    while remaining:
        seed=remaining.pop();group={seed};stack=[seed]
        while stack:
            v=stack.pop()
            for edge in v.link_edges:
                other=edge.other_vert(v)
                if other in remaining:
                    remaining.remove(other);group.add(other);stack.append(other)
        points=[ob.matrix_world@v.co for v in group]
        out.append({'verts':len(group),'lo':[min(v[k] for v in points) for k in range(3)],'hi':[max(v[k] for v in points) for k in range(3)]})
    bm.free()
(ROOT/'exports/blackridge_intake/junction_donor_components.json').write_text(json.dumps(out,indent=2))
