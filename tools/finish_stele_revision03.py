"""Fit the Meshy body to seven metres and attach exact raised lettering directly to its sampled plaque surface."""
from pathlib import Path
import bpy,json,math
from mathutils import Vector,Matrix
from mathutils.bvhtree import BVHTree
ROOT=Path(__file__).resolve().parents[1]
ART=ROOT/'assets/blackridge_intake_revision03';OUT=ROOT/'exports/blackridge_intake_revision03'
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=str(ART/'meshy/panopticon_stele.glb'))
bpy.context.view_layer.update()
body=[ob for ob in bpy.context.scene.objects if ob.type=='MESH']
points=[ob.matrix_world@v.co for ob in body for v in ob.data.vertices]
lo=Vector([min(p[k] for p in points) for k in range(3)]);hi=Vector([max(p[k] for p in points) for k in range(3)])
scale=7/(hi.z-lo.z)
center=(lo+hi)*.5
for ob in body:
    for v in ob.data.vertices:
        p=ob.matrix_world@v.co
        v.co=Vector((1+(p.x-center.x)*scale,-1+(p.y-center.y)*scale,(p.z-lo.z)*scale))
    ob.matrix_world=Matrix.Identity(4);ob.data.update()
vertices=[];faces=[]
for ob in body:
    start=len(vertices);vertices.extend(v.co.copy() for v in ob.data.vertices)
    faces.extend(tuple(start+i for i in p.vertices) for p in ob.data.polygons)
tree=BVHTree.FromPolygons(vertices,faces)
mat=bpy.data.materials.new('Ivory-gold institutional inlay')
mat.diffuse_color=(.68,.63,.43,1);mat.use_nodes=True
shader=mat.node_tree.nodes.get('Principled BSDF');shader.inputs['Base Color'].default_value=(.68,.63,.43,1)
shader.inputs['Metallic'].default_value=.25;shader.inputs['Roughness'].default_value=.66
font_path=Path('C:/Windows/Fonts/arialbd.ttf')
font=bpy.data.fonts.load(str(font_path))
letters=[];metrics=[]
for word,height in [('PURITY',4.00),('SILENCE',3.20),('OBEDIENCE',2.40)]:
    curve=bpy.data.curves.new('Exact '+word,'FONT');curve.body=word;curve.font=font;curve.size=1;curve.align_x='CENTER';curve.align_y='CENTER';curve.extrude=.012;curve.resolution_u=6
    ob=bpy.data.objects.new('Inscription '+word,curve);bpy.context.scene.collection.objects.link(ob)
    bpy.ops.object.select_all(action='DESELECT');ob.select_set(True);bpy.context.view_layer.objects.active=ob;bpy.ops.object.convert(target='MESH')
    p=[v.co for v in ob.data.vertices]
    low=Vector([min(v[k] for v in p) for k in range(3)]);high=Vector([max(v[k] for v in p) for k in range(3)])
    sy=.24/(high.y-low.y)
    sx=min(sy,.68/(high.x-low.x))
    for v in ob.data.vertices:
        x=1+(v.co.x-(low.x+high.x)/2)*sx
        h=height+(v.co.y-(low.y+high.y)/2)*sy
        hit,normal,index,distance=tree.ray_cast(Vector((x,-8,h)),Vector((0,1,0)))
        assert hit is not None,'Missing inscription support surface.'
        # The letter backs embed2mm into the measured plaque; their18mm visible relief follows its true tapered profile.
        depth=(v.co.z-low.z)/(high.z-low.z)*.020
        v.co=Vector((x,hit.y+.002-depth,h))
    ob.data.materials.append(mat);ob.data.update();letters.append(ob)
    metrics.append({'text':word,'height_m':.24,'width_m':(high.x-low.x)*sx,'center_height_m':height,'back_embed_m':.002,'visible_relief_m':.018})
bpy.ops.object.select_all(action='DESELECT')
for ob in body+letters:ob.select_set(True)
bpy.context.view_layer.objects.active=body[0]
path=ART/'panopticon_stele.glb'
bpy.ops.export_scene.gltf(filepath=str(path),export_format='GLB',use_selection=True,export_animations=False,export_yup=True)
all_points=[v.co for ob in body+letters for v in ob.data.vertices]
minimum=[min(v[k] for v in all_points) for k in range(3)];maximum=[max(v[k] for v in all_points) for k in range(3)]
report={'asset_id':'BI3_PANOPTICON_STELE','path':str(path).replace('\\','/'),'grid':[2,7,2],'driver_axis':1,'height_m':7,'uniform_source_scale':scale,'bounds_blender':[minimum,maximum],'exact_words':metrics,'triangles':sum(len(p.vertices)-2 for ob in body+letters for p in ob.data.polygons)}
(OUT/'stele_finished.json').write_text(json.dumps(report,indent=2))
bpy.ops.wm.save_as_mainfile(filepath=str(ART/'panopticon_stele_lettered.blend'))
print('STELE_FINISHED '+json.dumps(report),flush=True)
