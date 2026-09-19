"""Build BQ-owned shading-attribute diagnostics from the existing optimized focal meshes."""
from pathlib import Path
import bpy
import bmesh

ROOT=Path(__file__).resolve().parents[1]
for key in ['INTERROGATION_FRAME','SKELETAL_RACK']:
    bpy.ops.wm.read_factory_settings(use_empty=True)
    source=ROOT/'tile_library/assets'/('BW_MESHY_'+key)/'derived/runtime_optimized.glb'
    bpy.ops.import_scene.gltf(filepath=str(source))
    for ob in list(bpy.context.scene.objects):
        if ob.type!='MESH':
            continue
        bpy.context.view_layer.objects.active=ob
        ob.select_set(True)
        if ob.data.has_custom_normals:
            bpy.ops.mesh.customdata_custom_splitnormals_clear()
        bm=bmesh.new(); bm.from_mesh(ob.data)
        bmesh.ops.recalc_face_normals(bm,faces=list(bm.faces))
        bm.to_mesh(ob.data); bm.free()
        for face in ob.data.polygons:
            face.use_smooth=True
        ob.data.update()
    bpy.ops.object.select_all(action='SELECT')
    path=ROOT/'assets/blackridge_quarantine'/('diagnostic_'+key.lower()+'.glb')
    bpy.ops.export_scene.gltf(filepath=str(path),export_format='GLB',use_selection=True,export_animations=False)
    print('BQ_NORMALS_DIAGNOSTIC '+str(path),flush=True)
