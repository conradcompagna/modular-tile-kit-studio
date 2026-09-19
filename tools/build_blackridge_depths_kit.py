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

# A continuous fractured rock body has broad changing sections, leaning faces and pointed broken crests.
def cavern_mass(name,length,height,depth,seed):
    rng=random.Random(seed)
    count=37
    verts=[]
    for i in range(count):
        t=i/(count-1)
        x=t*length
        crest=height*(.66+.17*math.sin(t*math.tau*1.7+seed)+.13*math.sin(t*math.tau*4.3)+rng.uniform(-.055,.055))
        front=depth*(.68+.12*math.sin(t*math.tau*2.1+seed)+.06*math.sin(t*math.tau*7))
        # Irregular eight-sided sections create a broken roof and broad rock shelves, never capped posts.
        section=[(0,0),(front*.82,0),(front,.22*crest),(front*.91,.40*crest),
                 (front*1.12,.53*crest),(front*.77,.72*crest),(front*.32,crest),(0,.73*crest)]
        for j,(z,h) in enumerate(section):
            lean=math.sin(t*math.tau*2.7+j*.2)*.5*(h/max(crest,.1))
            verts.append(world(x+lean,z,h))
    faces=[]
    for i in range(count-1):
        for j in range(8):
            a=i*8+j;b=i*8+(j+1)%8;c=(i+1)*8+(j+1)%8;d=(i+1)*8+j
            faces.extend([(a,b,c),(a,c,d)])
    faces.extend([tuple(range(7,-1,-1)),tuple(range((count-1)*8,count*8))])
    mesh('Continuous leaning fractured cavern mass',verts,faces,ROCK,weather=False)
    # Three massive embedded breakouts disrupt the long contour with real angled protrusions.
    for j,t in enumerate((.20,.51,.82)):
        crag('Embedded eroded rock breakout',t*length,depth*.61,depth*.47,height*(.46+.14*j),ROCK,seed+90+j)
    finish(name,(length,height,depth))

cavern_mass('cavern_north_mass',36,18,5,431)
cavern_mass('cavern_east_mass',32,16,6,721)
cavern_mass('cavern_west_mass',32,17,5,977)

# Large cave wall modules use fused broad buttresses with varied strata and a few tall teeth.
for variant,h in (('cavern_wall_a',14),('cavern_wall_b',11)):
    for j in range(7):
        crag('Cavern limestone buttress',.7+j*.8,1.6,1.1,h*random.uniform(.65,1.0),ROCK,701+j+(0 if h==14 else 100),blunt=True)
    for j in range(6):
        crag('Natural foreground tooth',.5+j,3,random.uniform(.4,.75),random.uniform(3,7),ROCK,811+j)
    finish(variant,(6,h,4))

# Clustered columns establish natural cave silhouettes at three scales.
for name,h in (('stalagmite_tall',8),('stalagmite_low',3.5)):
    for j,(x,z,r,ratio) in enumerate(((1.5,1.1,.8,1),(.5,1.8,.55,.58),(2.5,2,.48,.7),(1.2,2.5,.42,.35))):
        crag('Eroded tapered stalagmite',x,z,r,h*ratio,ROCK,940+j)
    finish(name,(3,h,3))

# Ceiling fragments carry all downward teeth; their rear edge will meet the tall cavern wall.
for j in range(5):
    crag('Broken bulbous ceiling strata',.6+j*1.13,1.2,1.05,7.4+random.uniform(-.6,.6),ROCK,1160+j,blunt=True)
for j in range(9):
    crag('Hanging stalactite',.35+j*.66,random.uniform(.5,2),random.uniform(.4,.7),random.uniform(4.5,7.8),ROCK,1020+j,True)
finish('ceiling_teeth',(6,8,3))

# One source prop owns its anchors and spanning chains so legitimate contacts share a voxel union.
for x,z in ((0,0),(15,0),(0,12),(15,12)):
    tower(x,z,4.5)
for a,b in (((1,1.9,3.8),(6.8,6.7,4.4)),((16,1.9,3.8),(10.2,6.7,4.4)),((1,13.1,3.8),(5.8,8.3,2.2)),((16,13.1,3.8),(11.2,8.3,2.2))):
    tether(a,b)
finish('binding_chain_anchors',(17,4.7,14))

# Broad candle shrines form two small amber narrative islands at the ring's shoulders.
tower(0,0,1.15)
for i in range(13):
    x=.15+(i%4)*.43
    z=.16+(i//4)*.49
    h=.18+(i*7%9)*.07
    lathe('Wax candle',[(.07,0),(.07,h),(.025,h+.02)],(x,z,1.15),WAX,8)
    lathe('Candle flame',[(.02,0),(.045,.08),(0,.21)],(x,z,1.15+h),HOT,7)
finish('candle_shrine',(2,2,2))

# A three-sided oak cargo platform shares the dungeon's iron-band and twin-cable lift motif.
for i in range(10):
    box('Massive lift deck plank',(0,i*.3,0),(3,i*.3+.285,.24),WOOD,.015)
for z in (.12,1.42,2.82):
    box('Continuous lift deck strap',(0,z,.245),(3,z+.08,.28),IRON,.01)
    for x in (.15,.8,1.5,2.2,2.8):
        box('Deck strap rivet',(x,z,.28),(x+.05,z+.06,.32),RIVET,.02)
for a,b in (((.1,.1,.3),(.1,2.9,.3)),((.1,.1,1.35),(.1,2.9,1.35)),((.1,.1,1.35),(2.9,.1,1.35)),((.1,2.9,1.35),(2.9,2.9,1.35))):
    beam('Lift guard horizontal',a,b,.085,IRON)
for x,z in ((.1,.1),(.1,1.5),(.1,2.9),(2.9,.1),(2.9,2.9)):
    beam('Lift vertical guard',(x,z,.25),(x,z,1.4),.095,IRON)
for z in (.25,2.75):
    beam('Rigid lift guide rail',(.22,z,.15),(.22,z,7.95),.11,IRON)
    beam('Taut suspension cable',(1.5,z,.25),(1.5,z,7.85),.06,IRON)
    beam('Cable deck diagonal yoke',(.2,z,.28),(1.5,z,2.6),.12,IRON)
    beam('Cable deck diagonal yoke',(2.8,z,.28),(1.5,z,2.6),.12,IRON)
beam('Upper shaft cross member',(.1,.1,7.85),(.1,2.9,7.85),.23,IRON)
# Four ground-bearing posts and two pulley beams visibly close the suspension load path.
for x in (.15,2.85):
    for z in (.15,2.85):
        beam('Landing rooted gantry upright',(x,z,0),(x,z,7.65),.22,WOOD)
        box('Gantry foot socket',(x-.13,z-.13,0),(x+.13,z+.13,.45),IRON,.012)
for z in (.25,2.75):
    beam('Load bearing pulley beam',(.12,z,7.65),(2.88,z,7.65),.30,WOOD)
    beam('Gantry knee brace',(.15,z,6.1),(1.3,z,7.65),.16,IRON)
    beam('Gantry knee brace',(2.85,z,6.1),(1.7,z,7.65),.16,IRON)
    lathe('Suspension drum socket',[(.22,0),(.22,.16)],(1.5,z,7.64),IRON,16)
# A conspicuous overhead winding wheel and drum connect to the long ascending shaft cable.
for z in (.25,2.75):
    bpy.ops.mesh.primitive_torus_add(major_radius=.45,minor_radius=.075,major_segments=24,minor_segments=8,location=world(1.5,z,7.35),rotation=(math.pi/2,0,0))
    wheel=bpy.context.object
    wheel.name='Visible hoist sheave rim'
    wheel.data.materials.append(RUST)
    PARTS.append(wheel)
    for i in range(8):
        a=math.tau*i/8
        beam('Hoist wheel spoke',(1.5,z,7.35),(1.5+.43*math.cos(a),z,7.35+.43*math.sin(a)),.065,IRON)
    beam('Upward cable into the shaft',(1.93,z,7.35),(1.93,z,11.8),.065,IRON)
    beam('Wheel axle',(1.5,z-.16,7.35),(1.5,z+.16,7.35),.17,IRON)
beam('Winding drum axle',(1.5,.20,7.35),(1.5,2.8,7.35),.23,IRON)
finish('arrival_lift_hoist',(3,12,3))
# Keep the previous source identifier in the recipe, but the pass04 board uses the hoist variant.
for ob in [o for o in bpy.data.objects if o.name=='arrival_lift_hoist']:
    clone=ob.copy();clone.data=ob.data.copy();SCENE.collection.objects.link(clone);PARTS.append(clone)
finish('arrival_lift',(3,8,3))

# Broken edge stones lie on their broad faces and trail down into the real missing native cells.
for i in range(17):
    x=random.uniform(.12,2.5);z=random.uniform(.12,1.65)
    h=random.uniform(.12,.3)
    ob=box('Collapsed edge slab',(x,z,0),(x+random.uniform(.22,.65),z+random.uniform(.18,.48),h),STONE,.045)
    ob.rotation_euler.z=random.uniform(-.6,.6)
finish('collapse_edge',(3,.45,2))

# A broken masonry arch leaves the lift approach walkable while joining the cave wall backdrop.
tower(0,0,5.5)
tower(6,0,5.5)
box('Ancient arch keystone beam',(1.7,0,4.6),(6.3,1.92,5.5),STONE,.09)
for i in range(8):
    box('Arch upper chipped coping',(i,0,5.5),(i+.96,1.9,5.9),STONE,.06)
finish('ruined_landing_arch',(8,6,2))

(OUT/'kit.json').write_text(json.dumps(ASSETS,indent=2))
bpy.ops.wm.save_as_mainfile(filepath=str(OUT/'blackridge_depths_kit.blend'))
print('DEPTHS_KIT_COMPLETE '+str(len(ASSETS)),flush=True)



