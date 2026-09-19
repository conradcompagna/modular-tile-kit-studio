"""Author reusable metre-sized prison props; the native board owns all level placement."""
from pathlib import Path
import bpy
import math
import random
import json
from mathutils import Matrix, Vector

ROOT = Path(__file__).resolve().parents[1]
SHARED = ROOT / 'assets/belowward_cell'
ART = ROOT / 'assets/belowward_connections'
ART.mkdir(parents=True,exist_ok=True)
OUT = ROOT / 'exports/belowward_connections'
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
    ASSETS[name]={'path':str(path).replace('\\','/'),'asset_id':'BC_'+name.upper(),'grid':grid,'physical':list(dimensions),'driver_axis':0,'triangles':sum(len(p.vertices)-2 for p in ob.data.polygons)}
    ASSETS[name]['fit_factor']=list(factor)
    ASSETS[name]['fit_shift']=list(shift)
    ob.hide_set(True)
    ob.hide_render=True
    ob.select_set(False)
    PARTS.clear()
    print('ASSET_READY '+json.dumps(ASSETS[name]),flush=True)



# Export fixed world-contact geometry without the dimensional normalization used by ordinary kit pieces.
def fixed_finish(name,dimensions):
    bpy.ops.object.select_all(action='DESELECT')
    for ob in PARTS:ob.select_set(True)
    bpy.context.view_layer.objects.active=PARTS[0]
    bpy.ops.object.join()
    ob=bpy.context.object
    bpy.ops.object.transform_apply(location=True,rotation=True,scale=True)
    path=ART/(name+'.glb')
    bpy.ops.export_scene.gltf(filepath=str(path),export_format='GLB',use_selection=True,export_animations=False,export_yup=True)
    ASSETS[name]={'path':str(path).replace('\\','/'),'asset_id':'BC_'+name.upper(),'grid':list(dimensions),'physical':list(dimensions),'driver_axis':0,'triangles':sum(len(p.vertices)-2 for p in ob.data.polygons)}
    ob.hide_set(True);ob.hide_render=True;ob.select_set(False);PARTS.clear()

# The entry replaces exactly one 4 x 5 x 2 m cell front with matching masonry and an unmistakable oak door.
for x in (0,3.2):
    for row in range(10):
        box('Arrival door ashlar jamb',(x,0,row*.45),(x+.8,2,row*.45+.44),STONE,.025,False)
for i in range(4):
    box('Arrival lintel voussoir',(i,0,4.45),(i+.995,2,5),STONE,.02,False)
for i in range(8):
    box('Recessed door oak plank',(.8+i*.3,.30,.06),(1.085+i*.3,.43,4.43),WOOD,.009)
for y in (.7,2.0,3.6):
    box('Continuous forged door strap',(.82,.43,y),(3.18,.49,y+.13),IRON,.008)
    for x in (.95,1.6,2.4,3.05):
        box('Strap rivet',(x,.49,y+.03),(x+.07,.53,y+.10),RIVET,.012)
box('Door centre seam',(1.985,.43,.04),(2.015,.5,4.44),DARK)
for x in (1.72,2.17):
    box('Bronze door pull backplate',(x,.5,1.6),(x+.11,.55,1.95),BRASS,.015)
    beam('Door pull',(x+.055,.6,1.67),(x+.055,.6,1.88),.04,IRON)
fixed_finish('arrival_doorway',(4,5,2))

# A cable ferry links the existing west spur to a central descending cage without filling the pit with terrain.
# Local origin becomes world (11,-12,20); feet meet west Y=3 and east Y=4 exactly.
for x,ground in ((.3,15),(25.7,16)):
    for z in (.3,3.7):
        box('Grounded gantry iron foot',(x-.3,z-.3,ground),(x+.3,z+.3,ground+.36),IRON,.015)
        beam('Load bearing oak gantry',(x,z,ground+.2),(x,z,20.8),.3,WOOD)
        beam('Upper gantry knee brace',(x,z,19),(x,2,20.65),.18,IRON)
    box('Gantry top transverse beam',(x-.3,0,20.55),(x+.3,4,21),WOOD,.015)
    for z in (.7,3.3):
        lathe('Track cable anchor collar',[(.19,0),(.19,.23)],(x,z,20.55),IRON)
for z in (.7,3.3):
    beam('Tensioned cross shaft carrier cable',(.3,z,20.65),(25.7,z,20.65),.075,IRON)
    # A visible trolley sits on the carrier and supplies the vertical hoist instead of a floating chain.
    box('Trolley pulley chassis',(11.4,z-.19,20.4),(14.6,z+.19,20.85),IRON,.025)
    for x in (11.7,14.3):
        lathe('Trolley bearing wheel',[(.18,0),(.18,.14)],(x,z,20.6),BRASS)
    beam('Central suspension line',(13,z,13),(13,z,20.55),.075,IRON)
    beam('Descending guide into darkness',(11.6,z,0),(11.6,z,20.45),.055,IRON)
    box('Guide lower tension weight',(11.45,z-.14,0),(11.75,z+.14,.6),IRON,.02)
for z in (1.1,2.8):
    beam('Oak deck bearing stringer',(11.5,z,9.65),(14.5,z,9.65),.25,WOOD)
for i in range(10):
    box('Cargo car deck plank',(11.5,.5+i*.3,9.8),(14.5,.785+i*.3,10),WOOD,.008)
for z in (.65,2,3.2):
    box('Continuous car deck iron hoop',(11.5,z,10),(14.5,z+.09,10.05),IRON,.008)
    for x in (11.7,12.5,13.5,14.3):box('Deck hoop rivet',(x,z,10.05),(x+.05,z+.07,10.1),RIVET,.01)
for z in (.7,3.3):
    for x in (11.6,14.4):
        beam('Platform lifting yoke',(x,z,9.7),(13,z,13),.15,IRON)
    beam('Car side guard',(11.6,z,11.3),(14.4,z,11.3),.09,IRON)
    for x in (11.6,12.5,13.5,14.4):beam('Guard upright',(x,z,10),(x,z,11.3),.08,IRON)
# A latched gate faces the existing west loading spur; the hoist is shown lowered in the central shaft.
for z in (.7,1.4,2.1,2.8,3.3):beam('Latched ferry gate upright',(11.6,z,10),(11.6,z,11.25),.065,IRON)
beam('Latched ferry gate top',(11.6,.7,11.25),(11.6,3.3,11.25),.1,IRON)
box('West return winch base',(.03,1,15),(.85,2,15.25),WOOD,.018)
for z in (1.1,1.8):beam('Winch bearing frame',(.2,z,15.2),(.2,z,16.15),.13,IRON)
beam('Winch winding barrel',(.25,1.1,15.95),(.25,1.9,15.95),.42,WOOD)
beam('Winch hand crank',(.2,1.94,15.95),(.7,1.94,16.35),.08,IRON)
beam('Return winch cable',(.2,1.5,16),(.3,1.5,20.6),.045,IRON)
# Keep the two-cell stone spur entrance clear while placing the winch beside its gantry post.
for ob in PARTS:
    if 'winch' in ob.name.lower():
        ob.location.y -= 1.5
fixed_finish('central_cable_ferry',(26,21,4))
(OUT/'kit.json').write_text(json.dumps(ASSETS,indent=2))
bpy.ops.wm.save_as_mainfile(filepath=str(OUT/'belowward_connections_kit.blend'))
print('BELOWWARD_CONNECTION_KIT_COMPLETE',flush=True)

