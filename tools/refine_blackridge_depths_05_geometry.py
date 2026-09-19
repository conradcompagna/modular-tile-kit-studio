"""Author reusable metre-sized prison props; the native board owns all level placement."""
from pathlib import Path
import bpy
import math
import random
import json
from mathutils import Matrix, Vector

ROOT = Path(__file__).resolve().parents[1]
SHARED = ROOT / 'assets/belowward_cell'
ART = ROOT / 'assets/blackridge_depths'
OUT = ROOT / 'exports/blackridge_depths'
OUT.mkdir(parents=True, exist_ok=True)
(OUT / '.gdignore').touch()
random.seed(4702)
bpy.ops.wm.read_factory_settings(use_empty=True)
SCENE = bpy.context.scene
SCENE.unit_settings.system = 'METRIC'
ASSETS = {}
PARTS = []


# Convert authored X,Z,height into Blender Z-up, letting glTF export restore Y-up.
def world(x, z, h):
    return (x, -z, h)


# Use exportable albedo and scalar material channels, without fake normal textures.
def material(name, color, texture=None, metallic=0, rough=.8, emission=0):
    m = bpy.data.materials.new(name)
    m.diffuse_color = (*color, 1)
    m.use_nodes = True
    p = m.node_tree.nodes.get('Principled BSDF')
    p.inputs['Base Color'].default_value = (*color, 1)
    p.inputs['Roughness'].default_value = rough
    p.inputs['Metallic'].default_value = metallic
    if texture:
        t = m.node_tree.nodes.new('ShaderNodeTexImage')
        t.image = bpy.data.images.load(str(texture), check_existing=True)
        m.node_tree.links.new(t.outputs['Color'], p.inputs['Base Color'])
        if texture.name=='albedo.png' and texture.parent.name.endswith('_chord'):
            normal=m.node_tree.nodes.new('ShaderNodeTexImage')
            normal.image=bpy.data.images.load(str(texture.parent/'normal.png'),check_existing=True)
            normal.image.colorspace_settings.name='Non-Color'
            convert=m.node_tree.nodes.new('ShaderNodeNormalMap')
            convert.inputs['Strength'].default_value=1.15
            m.node_tree.links.new(normal.outputs['Color'],convert.inputs['Color'])
            m.node_tree.links.new(convert.outputs['Normal'],p.inputs['Normal'])
            roughness=m.node_tree.nodes.new('ShaderNodeTexImage')
            roughness.image=bpy.data.images.load(str(texture.parent/'roughness.png'),check_existing=True)
            roughness.image.colorspace_settings.name='Non-Color'
            m.node_tree.links.new(roughness.outputs['Color'],p.inputs['Roughness'])
    if emission:
        p.inputs['Emission Color'].default_value = (*color, 1)
        p.inputs['Emission Strength'].default_value = emission
    return m


STONE = material('Damp blue-grey prison ashlar', (.24,.27,.29), SHARED/'ashlar_v2_chord/albedo.png')
CAP = material('Worn coping limestone', (.20,.235,.26), SHARED/'ashlar_v2_chord/albedo.png')
DARK = material('Deep iron and mortar shadow', (.013,.019,.022))
IRON = material('Blackened wrought iron', (.038,.049,.052), metallic=.72, rough=.65)
RUST = material('Old rust edges', (.12,.058,.028), metallic=.55)
WOOD = material('Split dark oak', (.09,.051,.024), ROOT/'assets/angel_gate_blender/wood.png')
CRATE_IRON = material('Forged blue-black crate straps', (.085,.10,.105), metallic=.8, rough=.52)
RIVET = material('Worn iron rivet crowns', (.17,.18,.175), metallic=.8, rough=.47)
BRASS = material('Tarnished lamp brass', (.18,.105,.037), metallic=.72, rough=.4)
FLAME = material('Amber lantern flame', (1,.28,.035), rough=.35, emission=5)
HOT = material('Candle flame core', (1,.70,.20), emission=8)
BONE = material('Old ivory', (.41,.37,.27))
MURAL = material('Silence feeds it - authored mural', (.4,.4,.4), SHARED/'mural_v2.png')
BLOOD = material('Old oxblood', (.09,.009,.009), rough=.62)


# Construct metre-scaled UVs and real bevel geometry for close tactical views.
def mesh(name, vertices, faces, mat, bevel=0, weather=True):
    me=bpy.data.meshes.new(name)
    me.from_pydata(vertices, [], faces)
    me.update()
    if weather and mat in (STONE,CAP):
        # Small real edge damage complements CHORD relief without changing the metre-sized asset box.
        for vert in me.vertices:
            if vert.co.z>.05:
                seed=math.sin(vert.co.x*19.73+vert.co.y*31.41+vert.co.z*12.17)
                vert.co.x+=seed*.028
                vert.co.y+=math.sin(seed*17.2)*.028
                vert.co.z+=math.cos(seed*21.3)*.024
        me.update()
    ob=bpy.data.objects.new(name,me)
    SCENE.collection.objects.link(ob)
    PARTS.append(ob)
    if mat:
        me.materials.append(mat)
    uv=me.uv_layers.new(name='Metres')
    for face in me.polygons:
        axis=max(range(3),key=lambda k:abs(face.normal[k]))
        for li in face.loop_indices:
            v=me.vertices[me.loops[li].vertex_index].co
            uv.data[li].uv=((v.x if axis != 0 else -v.y)/4,(v.z if axis != 2 else -v.y)/4)
    if bevel:
        mod=ob.modifiers.new('Chipped stone edge','BEVEL')
        mod.width=bevel
        mod.segments=2
        bpy.context.view_layer.objects.active=ob
        bpy.ops.object.modifier_apply(modifier=mod.name)
    return ob


# Boxes use literal minimum and maximum corners in the asset's local metre grid.
def box(name,lo,hi,mat,bevel=.012,weather=True):
    x0,z0,h0=lo
    x1,z1,h1=hi
    v=[world(x,z,h) for h in (h0,h1) for z in (z0,z1) for x in (x0,x1)]
    return mesh(name,v,[(0,1,3,2),(4,6,7,5),(0,4,5,1),(2,3,7,6),(0,2,6,4),(1,5,7,3)],mat,bevel,weather)


# Extrude an inward-tapered masonry bracket while retaining exact wall and slab contact planes.
def stone_bracket(name,x0,x1,profile):
    vertices=[world(x,z,h) for x in (x0,x1) for z,h in profile]
    n=len(profile)
    faces=[tuple(range(n-1,-1,-1)),tuple(range(n,2*n))]
    faces += [(i,(i+1)%n,(i+1)%n+n,i+n) for i in range(n)]
    return mesh(name,vertices,faces,STONE,.025,weather=False)


# Connect two points with an iron bar, timber, bone, or chain support.
def beam(name,a,b,width,mat):
    a,b=Vector(world(*a)),Vector(world(*b))
    ob=box(name,(-width/2,-width/2,0),(width/2,width/2,(b-a).length),mat,min(.012,width/5))
    ob.location=a
    ob.rotation_mode='QUATERNION'
    ob.rotation_quaternion=(b-a).to_track_quat('Z','Y')
    return ob


# Lathe an open or closed profile around the vertical axis for cages, pots and lamp caps.
def lathe(name,profile,centre,mat,segments=16):
    v=[]
    for radius,h in profile:
        for i in range(segments):
            a=math.tau*i/segments
            v.append(world(centre[0]+radius*math.cos(a),centre[1]+radius*math.sin(a),centre[2]+h))
    f=[]
    for j in range(len(profile)-1):
        for i in range(segments):
            k=(i+1)%segments
            f.append((j*segments+i,j*segments+k,(j+1)*segments+k,(j+1)*segments+i))
    return mesh(name,v,f,mat)


# Model alternating oval links so hanging chains remain legible in silhouette.
def chain(x,z,bottom,top,step=.28):
    for i in range(math.ceil((top-bottom)/step)):
        h=bottom+i*step
        n=12
        v=[]
        for r in (.095,.060):
            for j in range(n):
                a=math.tau*j/n
                dx=r*math.cos(a)
                dz=0
                if i%2:
                    dx,dz=dz,dx
                v.append(world(x+dx,z+dz,h+1.65*r*math.sin(a)))
        mesh('Forged oval chain link',v,[(j,(j+1)%n,n+(j+1)%n,n+j) for j in range(n)],IRON)


# Export one measured native prop; source coordinates remain in the declared integer box.
def finish(name, dimensions):
    bpy.ops.object.select_all(action='DESELECT')
    for ob in PARTS:
        ob.select_set(True)
    bpy.context.view_layer.objects.active=PARTS[0]
    bpy.ops.object.join()
    ob=bpy.context.object
    ob.name=name
    bpy.ops.object.transform_apply(location=True,rotation=True,scale=True)
    dx,dh,dz=dimensions
    points=[v.co for v in ob.data.vertices]
    lo=Vector([min(p[k] for p in points) for k in range(3)])
    hi=Vector([max(p[k] for p in points) for k in range(3)])
    grid=[math.ceil(dx),math.ceil(dh),math.ceil(dz)]
    factor=Vector((dx/(hi.x-lo.x),dz/(hi.y-lo.y),dh/(hi.z-lo.z)))
    shift=Vector(((grid[0]-dx)/2-lo.x*factor.x,-(grid[2]-dz)/2-hi.y*factor.y,-lo.z*factor.z))
    for vert in ob.data.vertices:
        vert.co=vert.co*factor+shift
    ob.data.update()
    path=ART/(name+'.glb')
    bpy.ops.export_scene.gltf(filepath=str(path),export_format='GLB',use_selection=True,export_animations=False,export_yup=True)
    ASSETS[name]={'path':str(path).replace('\\','/'),'asset_id':'BD_'+name.upper(),'grid':grid,'physical':list(dimensions),'driver_axis':0,'triangles':sum(len(p.vertices)-2 for p in ob.data.polygons)}
    ASSETS[name]['fit_factor']=list(factor)
    ASSETS[name]['fit_shift']=list(shift)
    ob.hide_set(True)
    ob.hide_render=True
    ob.select_set(False)
    PARTS.clear()
    print('ASSET_READY '+json.dumps(ASSETS[name]),flush=True)


# Stratified irregular rings produce natural rock with broad facets and taper, not masonry prisms.
def crag(name,x,z,radius,height,mat,seed,down=False,blunt=False):
    rng=random.Random(seed)
    n=9
    levels=8
    vertices=[]
    offsets=[rng.uniform(.76,1.22) for _ in range(n)]
    drift=(rng.uniform(-.2,.2),rng.uniform(-.2,.2))
    for level in range(levels):
        t=level/(levels-1)
        taper=(.72+.24*math.sin(t*math.pi*2.7+seed)) if blunt else (1-t)**.66
        scale=max(.025,taper)*(1+rng.uniform(-.12,.12))
        for j in range(n):
            a=math.tau*j/n
            r=radius*scale*offsets[j]
            y=height*(1-t if down else t)
            vertices.append(world(x+math.cos(a)*r+drift[0]*t,z+math.sin(a)*r+drift[1]*t,y))
    faces=[tuple(range(n-1,-1,-1)),tuple(range((levels-1)*n,levels*n))]
    for level in range(levels-1):
        for j in range(n):
            k=(j+1)%n
            faces.append((level*n+j,level*n+k,(level+1)*n+k,(level+1)*n+j))
    return mesh(name,vertices,faces,mat,weather=False)


# Lay individually chipped block courses with precise load-bearing footprints.
def tower(x,z,h):
    for row in range(math.ceil(h/.45)):
        y=row*.45
        for i in range(3):
            for j in range(3):
                if row>h/.45-2 and (i,j)==(2,2):
                    continue
                box('Ruined prison foundation block',(x+i*.64+.01,z+j*.64+.01,y),(x+i*.64+.63,z+j*.64+.63,min(h,y+.43)),STONE,.045)
    box('Chain anchor iron plate',(x+.2,z+1.89,h-1.05),(x+1.72,z+1.98,h-.62),IRON,.014)
    for px in (.35,1.57):
        box('Stone-fixed anchor bolt',(x+px,z+1.98,h-.9),(x+px+.1,z+2.015,h-.8),RIVET,.022)


# Model a heavy open oval iron link in an arbitrary chain direction with true tube thickness.
def tether(a,b,radius=.17,step=.38):
    start,end=Vector(world(*a)),Vector(world(*b))
    direction=end-start
    count=max(2,math.ceil(direction.length/step))
    along=direction.normalized()
    across=along.cross(Vector((0,0,1))).normalized()
    if across.length<.1:
        across=Vector((1,0,0))
    other=along.cross(across).normalized()
    for i in range(count+1):
        t=i/count
        centre=start.lerp(end,t)+Vector((0,0,-.42*math.sin(math.pi*t)))
        side=across if i%2==0 else other
        verts=[]
        for j in range(14):
            angle=math.tau*j/14
            ring=centre+along*radius*1.65*math.cos(angle)+side*radius*math.sin(angle)
            normal=(along*math.cos(angle)+side*math.sin(angle)).normalized()
            plane=along.cross(side)
            for k in range(5):
                q=math.tau*k/5
                verts.append(ring+.035*(normal*math.cos(q)+plane*math.sin(q)))
        faces=[]
        for j in range(14):
            for k in range(5):
                faces.append((j*5+k,j*5+(k+1)%5,((j+1)%14)*5+(k+1)%5,((j+1)%14)*5+k))
        mesh('Heavy interlocked forged chain',verts,faces,IRON,weather=False)


ROCK=material('Wet fractured cavern limestone',(.19,.23,.25),ART/'cavern_source_chord/albedo.png',rough=.82)
WAX=material('Old beeswax',(.45,.34,.18),rough=.95)


# Import existing mass vertices in their accepted metre pose before attaching the supported overhead shelf.
def include(path,blunt=False):
    previous=set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=str(path))
    bpy.context.view_layer.update()
    for ob in list(bpy.data.objects):
        if ob in previous:continue
        if ob.type=='MESH':
            for v in ob.data.vertices:
                v.co=ob.matrix_world@v.co
                # Lower only the long middle crest into an irregular blunt shoulder; feet and accepted foundation remain exact.
                if blunt and 7<v.co.x<26 and v.co.z>10.3:
                    v.co.z=10.3+(v.co.z-10.3)*.34+.28*math.sin(v.co.x*.7)
            ob.parent=None;ob.matrix_world=Matrix.Identity(4);PARTS.append(ob)
        else:bpy.data.objects.remove(ob,do_unlink=True)

# Jagged closed rock cross sections form a thick projecting shelf with a visible fractured underside.
def overhang(name,x_values,fronts,undersides,tops):
    vertices=[]
    for i,x in enumerate(x_values):
        f=fronts[i];u=undersides[i];t=tops[i]
        for z,h in ((1.3,u-2),(f*.65,u-.5),(f,u+.2),(f-.3,t-.7),(f*.55,t),(1.1,t-.2)):
            vertices.append(world(x,z,h))
    faces=[]
    for i in range(len(x_values)-1):
        for j in range(6):
            a=i*6+j;b=i*6+(j+1)%6;c=(i+1)*6+(j+1)%6;d=(i+1)*6+j
            faces.extend(((a,b,c),(a,c,d)))
    faces.extend((tuple(range(5,-1,-1)),tuple(range((len(x_values)-1)*6,len(x_values)*6))))
    mesh(name,vertices,faces,ROCK,weather=False)

# Unequal broken pendant teeth root deeply into the shelf instead of floating below it.
def tooth(x,z,top,length,radius,seed):
    rng=random.Random(seed);n=7;v=[]
    for row,ratio in enumerate((1,.82,.48,.05)):
        for j in range(n):
            a=j*math.tau/n;r=radius*ratio*rng.uniform(.82,1.17)
            v.append(world(x+math.cos(a)*r+.15*row,z+math.sin(a)*r,top-length*row/3))
    faces=[tuple(range(n-1,-1,-1)),tuple(range(n*3,n*4))]
    for row in range(3):
        for j in range(n):faces.append((row*n+j,row*n+(j+1)%n,(row+1)*n+(j+1)%n,(row+1)*n+j))
    mesh('Attached unequal downward fracture tooth',v,faces,ROCK,weather=False)

# Save exact union coordinates; native sizing will preserve the measured original host placement.
def save_union(name):
    bpy.ops.object.select_all(action='DESELECT')
    for ob in PARTS:ob.select_set(True)
    bpy.context.view_layer.objects.active=PARTS[0]
    bpy.ops.object.join();ob=bpy.context.object
    bpy.ops.object.transform_apply(location=True,rotation=True,scale=True)
    # Restore exact integer contact planes after the glTF round trip's floating-point rotation.
    for vertex in ob.data.vertices:
        for axis in range(3):
            if abs(vertex.co[axis]-round(vertex.co[axis]))<.00001:
                vertex.co[axis]=round(vertex.co[axis])
    path=ART/(name+'.glb')
    points=[v.co for v in ob.data.vertices];lo=Vector([min(v[k] for v in points) for k in range(3)]);hi=Vector([max(v[k] for v in points) for k in range(3)])
    bpy.ops.export_scene.gltf(filepath=str(path),export_format='GLB',use_selection=True,export_animations=False)
    size=[hi.x-lo.x,hi.z-lo.z,hi.y-lo.y]
    ASSETS[name]={'path':str(path).replace('\\','/'),'asset_id':'BD_'+name.upper(),'grid':[math.ceil(s-0.00001) for s in size],'physical':size,'driver_axis':0,'triangles':sum(len(f.vertices)-2 for f in ob.data.polygons)}
    ob.hide_set(True);ob.hide_render=True;ob.select_set(False);PARTS.clear()

include(ART/'cavern_north_mass.glb')
overhang('Supported rear cavern canopy',[5,8,11,14,18,21,25,28],[3,7.4,9.2,11,9.5,10.2,7,3.5],[12,12.4,12,12.8,12.2,12.5,12,12],[14,15.6,16.8,17,16.5,17.3,15.5,14])
for i,(x,z,l,r) in enumerate(((9,6.8,2.0,.9),(13,9.5,3.2,1.1),(17,8.6,1.7,.8),(21,9.1,2.6,.95),(25,6.2,1.3,.75))):tooth(x,z,13.5,l,r,880+i)
save_union('cavern_north_canopy')
include(ART/'cavern_east_mass.glb',blunt=True)
overhang('Supported right cavern overhang',[5,8,11,15,19,22,25],[3,8.4,10.2,12,10.6,8.3,3.7],[13,13.8,13.5,13.7,13.3,13.8,13],[14.8,15.6,16,15.8,15.6,15.8,14.5])
for i,(x,z,l,r) in enumerate(((8,7.5,1.5,.8),(12,9.2,2.7,1.15),(17,10.4,1.8,.7),(21,7.7,2.2,.85))):tooth(x,z,14.8,l,r,920+i)
save_union('cavern_east_canopy')
(OUT/'kit_05.json').write_text(json.dumps(ASSETS,indent=2))
bpy.ops.wm.save_as_mainfile(filepath=str(OUT/'cavern_canopies_05.blend'))
print('DEPTHS_CANOPIES_05_COMPLETE',flush=True)
