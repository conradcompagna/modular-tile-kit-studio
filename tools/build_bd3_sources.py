"""Author bounded cavern crest and hoist variants while retaining the accepted material family."""
from pathlib import Path
import json
import math
import bpy
from mathutils import Matrix, Vector

ROOT=Path(__file__).resolve().parents[1]
ART=ROOT/'assets/blackridge_depths_revision03'
OUT=ROOT/'exports/blackridge_depths_revision03'
kit={}
details=[]
bpy.ops.wm.read_factory_settings(use_empty=True)


# Import a source into literal metre coordinates, retaining all embedded material channels.
def include(asset, filename):
    before=set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=str(ROOT/'tile_library/assets'/asset/'source'/filename))
    objects=[o for o in bpy.data.objects if o not in before and o.type=='MESH']
    bpy.context.view_layer.update()
    for ob in objects:
        transform=ob.matrix_world.copy()
        for vertex in ob.data.vertices:
            vertex.co=transform@vertex.co
        ob.parent=None
        ob.matrix_world=Matrix.Identity(4)
    return objects


# Recover actual disconnected rock and hardware pieces despite glTF UV seam vertex duplication.
def components(mesh):
    parent=list(range(len(mesh.vertices)))
    def root(index):
        while parent[index]!=index:
            parent[index]=parent[parent[index]]
            index=parent[index]
        return index
    def join(a,b):
        parent[root(a)]=root(b)
    coordinate_map={}
    for vertex in mesh.vertices:
        key=tuple(round(x,5) for x in vertex.co)
        if key in coordinate_map:
            join(vertex.index,coordinate_map[key])
        else:
            coordinate_map[key]=vertex.index
    for edge in mesh.edges:
        join(*edge.vertices)
    groups={}
    for vertex in mesh.vertices:
        groups.setdefault(root(vertex.index),[]).append(vertex.index)
    return list(groups.values())


# Export without another fit so measured original metre widths remain the native importer driver.
def export(name,objects):
    bpy.ops.object.select_all(action='DESELECT')
    for ob in objects:
        ob.hide_set(False)
        ob.select_set(True)
    bpy.context.view_layer.objects.active=objects[0]
    bpy.ops.object.join()
    objects=[bpy.context.object]
    points=[v.co for ob in objects for v in ob.data.vertices]
    lo=Vector([min(p[k] for p in points) for k in range(3)])
    hi=Vector([max(p[k] for p in points) for k in range(3)])
    physical=[hi.x-lo.x,hi.z-lo.z,hi.y-lo.y]
    path=ART/(name+'.glb')
    bpy.ops.export_scene.gltf(filepath=str(path),export_format='GLB',use_selection=True,export_animations=False,export_yup=True)
    record={'asset_id':'BD3_'+name.upper(),'path':str(path),'grid':[math.ceil(v-.00001) for v in physical],
            'physical':physical,'axis':0,'triangles':sum(sum(len(p.vertices)-2 for p in ob.data.polygons) for ob in objects)}
    kit[name]=record
    for ob in objects:
        ob.hide_set(True)
        ob.hide_render=True
    print(json.dumps(record),flush=True)


# Recut only broad blunt crests into sloping fractured shoulders, retaining the individual narrow teeth.
for old,name in [('BDR_CAVERN_WALL_A','cavern_wall_a'),('BDR_CAVERN_WALL_B','cavern_wall_b'),('BDR_CAVERN_WALL_CEILING','cavern_wall_ceiling')]:
    objects=include(old,old.lower()+'.glb')
    altered=[]
    lower_columns=[]
    for ob in objects:
        for indices in components(ob.data):
            points=[ob.data.vertices[i].co.copy() for i in indices]
            low=min(p.z for p in points);high=max(p.z for p in points)
            cap=[p for p in points if p.z>high-.001]
            width=max(p.x for p in points)-min(p.x for p in points)
            if low<.01 and max(p.x for p in cap)-min(p.x for p in cap)>width*.35:
                ring_height=high*4/7
                ring=[p for p in points if abs(p.z-ring_height)<.005]
                if ring:
                    center=sum(ring,Vector())/len(ring)
                    lower_columns.append({'center':center,'ring':[tuple(p) for p in ring]})
    rooted=[]
    for ob in objects:
        rooted_vertices=set()
        for indices in components(ob.data):
            points=[ob.data.vertices[i].co.copy() for i in indices]
            low=min(p.z for p in points); high=max(p.z for p in points); height=high-low
            cap=[p for p in points if p.z>high-.001]
            width=max(p.x for p in points)-min(p.x for p in points)
            cap_width=max(p.x for p in cap)-min(p.x for p in cap)
            bottom=[p for p in points if p.z<low+.001]
            bottom_width=max(p.x for p in bottom)-min(p.x for p in bottom)
            if low>9 and bottom_width>width*.35:
                rooted_vertices.update(indices)
                old_center=sum(bottom,Vector())/len(bottom)
                host=min(lower_columns,key=lambda c:(c['center'].x-old_center.x)**2+(c['center'].y-old_center.y)**2)
                center=host['center']
                # The wide upper mass narrows over its lower46% into the actual lower-column core.
                # The tiny buried root cap replaces the exposed broad horizontal underside.
                for index in indices:
                    p=ob.data.vertices[index].co
                    u=max(0,min(1,((p.z-low)/height)/.46))
                    blend=u*u*(3-2*u)
                    root_x=center.x+(p.x-old_center.x)*.09
                    root_y=center.y+(p.y-old_center.y)*.09
                    p.x=root_x*(1-blend)+p.x*blend
                    p.y=root_y*(1-blend)+p.y*blend
                    p.z=p.z-(low-center.z)*(1-blend)
                rooted.append({'root_center_blender':list(center),'host_ring_blender':host['ring'],'old_underside_y':low,'taper_upper_fraction':.46,'root_vertices_blender':[list(ob.data.vertices[i].co) for i in indices if abs(points[indices.index(i)].z-low)<.001]})
            if height<3 or cap_width<width*.35:
                continue
            zmin=min(-p.y for p in points); zmax=max(-p.y for p in points)
            xmin=min(p.x for p in points)
            # Descending mineral breaks retain broad asymmetric shoulders instead of uniform cone tips.
            for index in indices:
                p=ob.data.vertices[index].co
                t=max(0,(p.z-low)/height)
                u=max(0,min(1,(t-.52)/.48))
                smooth=u*u*(3-2*u)
                front=(-p.y-zmin)/(zmax-zmin)
                lateral=(p.x-xmin)/width
                lowering=height*(.23*front+.035*math.sin(lateral*math.pi))*smooth
                p.z-=lowering
            altered.append({'source_component_min_y':low,'source_height':height,'cap_width':cap_width,'maximum_front_descent':height*.23})
        ob.data.update()
        # Reproject only the stretched upper masses at the existing four-metre material scale.
        # Their new descending geometry must not stretch the mineral veins into long rubbery streaks.
        if rooted_vertices:
            uv=ob.data.uv_layers.active
            for face in ob.data.polygons:
                if not any(i in rooted_vertices for i in face.vertices):continue
                axis=max(range(3),key=lambda k:abs(face.normal[k]))
                for loop_index in face.loop_indices:
                    v=ob.data.vertices[ob.data.loops[loop_index].vertex_index].co
                    uv.data[loop_index].uv=((v.x if axis!=0 else -v.y)/4,(v.z if axis!=2 else -v.y)/4)
    final_name=name+'_rooted' if name=='cavern_wall_ceiling' else name
    export(final_name,objects)
    if final_name!=name:kit[name]=kit.pop(final_name)
    details.append({'asset':'BD3_'+final_name.upper(),'changed_blunt_components':altered,'rooted_upper_components':rooted,'ground_basal_vertices_unchanged':True,'xz_coordinates_unchanged':not bool(rooted)})

# A narrower existing pit cluster fits the remaining two-metre fissure without changing its height.
objects=include('BDR_STALAGMITE_TALL','bdr_stalagmite_tall.glb')
for ob in objects:
    for vertex in ob.data.vertices:
        vertex.co.x=.15+vertex.co.x*(1.7/3)
        vertex.co.y=-.15+vertex.co.y*(1.7/3)
    ob.data.update()
export('stalagmite_fissure',objects)
kit['stalagmite_fissure']['axis']=1

objects=include('BD_ARRIVAL_LIFT_HOIST','arrival_lift_hoist.glb')
iron=next(m for ob in objects for m in ob.data.materials if 'wrought iron' in m.name)
removed=[]
for ob in objects:
    remove=set()
    for indices in components(ob.data):
        points=[ob.data.vertices[i].co for i in indices]
        lo=[min(p[k] for p in points) for k in range(3)]
        hi=[max(p[k] for p in points) for k in range(3)]
        # The two source extensions stop at y12, well above the self-supported eight-metre gantry.
        loose=hi[2]>8.5 and hi[2]-lo[2]>3
        # Replace the two centerline suspension strands with a genuine rim-to-drum cable route.
        center_cable=hi[2]-lo[2]>7 and lo[0]>1.4 and hi[0]<1.6
        if loose or center_cable:
            remove.update(indices)
            removed.append({'kind':'loose_upward_extension' if loose else 'centerline_cable','min_blender':lo,'max_blender':hi})
    if remove:
        import bmesh
        bm=bmesh.new();bm.from_mesh(ob.data);bm.verts.ensure_lookup_table()
        bmesh.ops.delete(bm,geom=[bm.verts[i] for i in remove],context='VERTS')
        bm.to_mesh(ob.data);bm.free()


# Make an explicit cylindrical cable segment between literal glTF X,Y,Z endpoints.
def cable(name,a,b,radius=.027,material=iron):
    aa=Vector((a[0],-a[2],a[1]));bb=Vector((b[0],-b[2],b[1]));direction=bb-aa
    bpy.ops.mesh.primitive_cylinder_add(vertices=10,radius=radius,depth=direction.length,location=(aa+bb)/2)
    ob=bpy.context.object;ob.name=name;ob.rotation_euler=direction.to_track_quat('Z','Y').to_euler()
    ob.data.materials.append(material);objects.append(ob)
    bpy.context.view_layer.update()
    matrix=ob.matrix_world.copy()
    for v in ob.data.vertices:v.co=matrix@v.co
    ob.matrix_world=Matrix.Identity(4)


# Add a genuine bearing block whose lower axle socket and upper beam socket overlap their hosts.
def bearing(name,center,size):
    bpy.ops.mesh.primitive_cube_add(size=1,location=(center[0],-center[2],center[1]))
    ob=bpy.context.object;ob.name=name;ob.scale=(size[0],size[2],size[1]);ob.data.materials.append(iron)
    bpy.context.view_layer.update();matrix=ob.matrix_world.copy()
    for v in ob.data.vertices:v.co=matrix@v.co
    ob.matrix_world=Matrix.Identity(4);objects.append(ob)


cx=1.5074628;cy=7.474576;radius=.46
for z in [.251256,2.763819]:
    yoke=(cx,2.65,z)
    start=(cx-radius,2.95,z)
    cable('Deck yoke cable socket',yoke,start,.043)
    cable('Suspension cable to sheave rim',start,(cx-radius,cy,z))
    arc=[(cx+radius*math.cos(math.pi-i*math.pi/18),cy+radius*math.sin(math.pi-i*math.pi/18),z) for i in range(19)]
    for a,b in zip(arc,arc[1:]):cable('Cable seated around sheave rim',a,b)
    # The return winds onto the shared central axle drum inside the supported gantry.
    drum_z=.67 if z<1 else 2.35
    cable('Sheave return into winding drum',arc[-1],(cx+.20,cy,drum_z))
    bearing('Bolted axle bearing into crossbeam',(cx,7.67,z),(.36,.47,.28))
cable('Winding drum around existing axle',(cx,cy,.6),(cx,cy,2.41),.20)
coil=[(cx+.217*math.cos(i*math.tau/16),cy+.217*math.sin(i*math.tau/16),.67+i/160*1.68) for i in range(161)]
for a,b in zip(coil,coil[1:]):cable('Continuous wound hoist cable',a,b,.024)
export('arrival_lift_anchored',objects)
details.append({'asset':'BD3_ARRIVAL_LIFT_ANCHORED','removed':removed,'sheave_centers':[[cx,cy,.251256],[cx,cy,2.763819]],'drum_axis':[[cx,cy,.6],[cx,cy,2.41]],'bearing_y_range':[7.435,7.905],'host_beam_y_range':[7.62712,7.9322]})

(OUT/'kit.json').write_text(json.dumps(kit,indent=2)+'\n')
(OUT/'source_changes.json').write_text(json.dumps(details,indent=2)+'\n')
bpy.ops.wm.save_as_mainfile(filepath=str(OUT/'depths_revision03_sources.blend'))
