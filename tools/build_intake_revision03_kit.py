"""Build fitted grate and grounded banner-standard variants from accepted finished geometry."""
from pathlib import Path
import bpy, bmesh, json, math
from mathutils import Matrix, Vector
ROOT=Path(__file__).resolve().parents[1]
source=(ROOT/'tools/build_belowward_kit.py').read_text()
exec(compile(source.split('# Recessed prison cell fronts')[0],'<approved-intake-helpers>','exec'))
ART=ROOT/'assets/blackridge_intake_revision03'; OUT=ROOT/'exports/blackridge_intake_revision03'; ASSETS={}

# Bake a finished donor into literal native source metres without changing its materials or silhouette.
def donor(path, scale_y=1):
    bpy.ops.object.select_all(action='DESELECT')
    bpy.ops.import_scene.gltf(filepath=str(ROOT/path))
    bpy.context.view_layer.update()
    for ob in list(bpy.context.selected_objects):
        if ob.type!='MESH': continue
        for v in ob.data.vertices:
            p=ob.matrix_world@v.co; p.z*=scale_y; v.co=p
        ob.matrix_world=Matrix.Identity(4);ob.data.update();PARTS.append(ob)

# Preserve the donor-sized native metre box and normalize UV channel names before combining surfaces.
def publish(name,grid,driver=0):
    bpy.ops.object.select_all(action='DESELECT')
    for ob in PARTS:
        if ob.data.uv_layers.active: ob.data.uv_layers.active.name='UVMap'
        ob.select_set(True)
    bpy.context.view_layer.objects.active=PARTS[0];bpy.ops.object.join()
    ob=bpy.context.object;ob.name='BI3_'+name.upper()
    bpy.ops.object.transform_apply(location=True,rotation=True,scale=True)
    path=ART/(name+'.glb')
    bpy.ops.export_scene.gltf(filepath=str(path),export_format='GLB',use_selection=True,export_yup=True,export_animations=False)
    points=[v.co for v in ob.data.vertices]
    ASSETS[name]={'asset_id':ob.name,'path':str(path).replace('\\','/'),'grid':grid,'driver_axis':driver,'triangles':sum(len(p.vertices)-2 for p in ob.data.polygons),'bounds_blender':[[min(v[k] for v in points) for k in range(3)],[max(v[k] for v in points) for k in range(3)]]}
    ob.hide_set(True);ob.hide_render=True;ob.select_set(False);PARTS.clear()

donor('tile_library/assets/BIR_AUTHORITY_DOOR/source/authority_door.glb')
# Remove only the obsolete ironwork in front of the continuous door leaves; rear bindings and masonry remain intact.
removed=0
for ob in PARTS:
    bm=bmesh.new();bm.from_mesh(ob.data)
    selected=[]
    for f in bm.faces:
        mat=ob.data.materials[f.material_index]
        if not any(word in mat.name.lower() for word in ('iron','rivet','crate straps')): continue
        if all(1.8 <= v.co.x <= 10.2 and 1.35 <= -v.co.y <= 2.35 and -.02 <= v.co.z <= 8.81 for v in f.verts): selected.append(f)
    removed+=len(selected)
    bmesh.ops.delete(bm,geom=selected,context='FACES');bm.to_mesh(ob.data);bm.free()
# A single continuous rectangular grate fits the entire 8m by8.75m solid door assembly.
for x in (2.01,9.87): box('Full grate side stile',(x,1.66,0),(x+.14,1.83,8.75),IRON,.012,False)
for h in (0,.90,2.5,4.5,6.5,8.60): box('Full width grate crossrail',(2.01,1.65,h),(10.01,1.84,h+.15),IRON,.012,False)
for i in range(22):
    x=2.28+i*(7.44/21)
    box('Full height grate spindle',(x-.045,1.70,.15),(x+.045,1.79,8.60),IRON,.01,False)
for h in (.95,2.55,4.55,6.55,8.65):
    for x in (2.08,6,9.94): box('Grate structural rivet',(x-.045,1.835,h-.01),(x+.045,1.865,h+.075),RIVET,.016,False)
box('Grate closure lock',(5.77,1.84,3.60),(6.23,2.00,4.04),CRATE_IRON,.02,False)
publish('authority_door',[12,12,3])
ASSETS['authority_door']['removed_undersized_iron_faces']=removed

donor('tile_library/assets/BI_AUTHORITY_BANNER/source/authority_banner.glb',8/7.4)
# Two visibly grounded standards carry a cantilever crossbar and ties, rather than relying on a wall taller than the real host.
for x in (.18,2.82):
    box('Standard foot plate',(x-.18,.05,0),(x+.18,.75,.16),IRON,.015,False)
    beam('Grounded banner standard',(x,.34,.15),(x,.34,7.87),.13,IRON)
    beam('Banner standard knee',(x,.34,7.18),(x,.88,7.72),.08,IRON)
    beam('Banner head arm',(x,.34,7.76),(x,.90,7.76),.10,IRON)
    for h in (.22,1.25,7.2):
        box('Standard worn iron collar',(x-.085,.25,h),(x+.085,.43,h+.11),RIVET,.008,False)
beam('Banner continuous supported headbar',(.10,.87,7.76),(2.90,.87,7.76),.10,IRON)
for x in (.35,1.5,2.65): beam('Cloth suspension tie',(x,.87,7.75),(x,.80,7.53),.042,BRASS)
publish('authority_standard',[3,8,1],1)
(OUT/'kit.json').write_text(json.dumps(ASSETS,indent=2))
bpy.ops.wm.save_as_mainfile(filepath=str(ART/'structural_variants.blend'))
print('BI3_KIT '+json.dumps(ASSETS),flush=True)
