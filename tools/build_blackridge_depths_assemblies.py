"""Join intentional structural contacts after native boss optimization while preserving measured poses."""
from pathlib import Path
import json
import math
import bpy
from mathutils import Matrix,Vector
from mathutils.bvhtree import BVHTree
ROOT=Path(__file__).resolve().parents[1]
ART=ROOT/'assets/blackridge_depths'
OUT=ROOT/'exports/blackridge_depths'
bpy.ops.wm.read_factory_settings(use_empty=True)
kit=json.loads((OUT/'kit.json').read_text())


# Bake an imported source's local glTF hierarchy into the measured Blender world basis.
def include(path,scale=1.,translation=(0,0,0)):
    before=set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=str(path))
    imported=[o for o in bpy.data.objects if o not in before]
    bpy.context.view_layer.update()
    result=[]
    for ob in imported:
        if ob.type!='MESH':
            continue
        for v in ob.data.vertices:
            v.co=(ob.matrix_world@v.co)*scale+Vector(translation)
        ob.parent=None
        ob.matrix_world=Matrix.Identity(4)
        result.append(ob)
    for ob in imported:
        if ob.type!='MESH':
            bpy.data.objects.remove(ob,do_unlink=True)
    return result


# Export a union without fitting again, preserving the already accepted constituent art poses.
def export(name,objects):
    bpy.ops.object.select_all(action='DESELECT')
    for ob in objects:
        ob.select_set(True)
    bpy.context.view_layer.objects.active=objects[0]
    bpy.ops.object.join()
    ob=bpy.context.object
    ob.name=name
    lo=Vector([min(v.co[k] for v in ob.data.vertices) for k in range(3)])
    hi=Vector([max(v.co[k] for v in ob.data.vertices) for k in range(3)])
    dimensions=[hi.x-lo.x,hi.z-lo.z,hi.y-lo.y]
    grid=[math.ceil(d-0.00001) for d in dimensions]
    path=ART/(name+'.glb')
    bpy.ops.export_scene.gltf(filepath=str(path),export_format='GLB',use_selection=True,export_animations=False)
    kit[name]={'path':str(path).replace('\\','/'),'asset_id':'BD_'+name.upper(),'grid':grid,'physical':dimensions,'driver_axis':0,'triangles':sum(len(p.vertices)-2 for p in ob.data.polygons)}
    ob.hide_set(True)
    ob.select_set(False)
    print(json.dumps(kit[name]),flush=True)


parts=include(ART/'cavern_wall_a.glb')
parts+=include(ART/'ceiling_teeth.glb',translation=(0,-1,10))
export('cavern_wall_ceiling',parts)
parts=include(ART/'binding_chain_anchors.glb',translation=(0,0,2))
# Native importer pose and wall-contact offset are recorded in the import audit.
boss=include(ROOT/'tile_library/assets/BD_ABOMINATION/derived/runtime_optimized.glb',
    scale=4.247568,translation=(7.963294,-7.475882,3.524755))
parts+=boss
# Extend the four existing terminals to measured flesh/harness surfaces, with embedded shackle eyes.
vertices=[]
faces=[]
for ob in boss:
    start=len(vertices)
    vertices.extend([v.co.copy() for v in ob.data.vertices])
    faces.extend([tuple(start+i for i in p.vertices) for p in ob.data.polygons])
tree=BVHTree.FromPolygons(vertices,faces)
iron=bpy.data.materials.new('Forged binding shackle iron')
iron.diffuse_color=(.08,.10,.105,1)
iron.use_nodes=True
iron.node_tree.nodes['Principled BSDF'].inputs['Base Color'].default_value=(.08,.10,.105,1)
iron.node_tree.nodes['Principled BSDF'].inputs['Metallic'].default_value=.8
iron.node_tree.nodes['Principled BSDF'].inputs['Roughness'].default_value=.55
fit=kit['binding_chain_anchors']
contacts=[]
for point in ((6.8,6.7,4.4),(10.2,6.7,4.4),(5.8,8.3,2.2),(11.2,8.3,2.2)):
    end=Vector((point[0],-point[1],point[2]))*Vector(fit['fit_factor'])+Vector(fit['fit_shift'])+Vector((0,0,2))
    contact,normal,_,distance=tree.find_nearest(end)
    # The large closed ring enters the host surface; its external eye receives the final chain link.
    centre=contact+normal*.03
    bpy.ops.mesh.primitive_torus_add(major_radius=.24,minor_radius=.065,major_segments=20,minor_segments=8,location=centre)
    ring=bpy.context.object
    ring.name='Surface embedded boss shackle eye'
    ring.rotation_mode='QUATERNION'
    ring.rotation_quaternion=normal.to_track_quat('Z','Y')
    ring.data.materials.append(iron)
    parts.append(ring)
    along=(centre-end).normalized()
    count=max(1,math.ceil(distance/.26))
    for i in range(count+1):
        pos=end.lerp(centre,i/count)
        axis=along.cross(normal).normalized() if i%2 else normal
        if axis.length<.1:
            axis=Vector((0,0,1))
        bpy.ops.mesh.primitive_torus_add(major_radius=.13,minor_radius=.035,major_segments=14,minor_segments=6,location=pos)
        link=bpy.context.object
        link.name='Continuous terminal binding link'
        link.rotation_mode='QUATERNION'
        link.rotation_quaternion=axis.to_track_quat('Z','Y')
        link.data.materials.append(iron)
        parts.append(link)
    contacts.append({'old_terminal':list(end),'surface_contact':list(contact),'extension_m':distance})
(OUT/'binding_contacts_03.json').write_text(json.dumps(contacts,indent=2))
export('chained_abomination',parts)
(OUT/'kit.json').write_text(json.dumps(kit,indent=2))
bpy.ops.wm.save_as_mainfile(filepath=str(OUT/'depths_assemblies.blend'))
