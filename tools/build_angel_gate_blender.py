"""Author Angel Gate II in Blender and emit its native one-metre board inputs."""
from pathlib import Path
import json
import math
import random
import sys
import bpy
from mathutils import Vector, Matrix

ROOT = Path(__file__).resolve().parents[1]
ART = ROOT / 'assets' / 'angel_gate_blender'
OLD = ROOT / 'assets' / 'angel_gate'
OUT = ROOT / 'exports' / 'angel_gate_blender_source'
OUT.mkdir(parents=True, exist_ok=True)
(OUT / '.gdignore').touch()
random.seed(1841)
bpy.ops.object.select_all(action='SELECT')
bpy.ops.object.delete(use_global=False)
for item in list(bpy.data.collections):
    if item.name != 'Collection':
        bpy.data.collections.remove(item)
SCENE = bpy.context.scene
SCENE.unit_settings.system = 'METRIC'
SCENE.unit_settings.scale_length = 1.0
# This rotation is the standard glTF Y-up to Blender Z-up conversion, not a level offset.
C = Matrix(((1,0,0,0),(0,0,-1,0),(0,1,0,0),(0,0,0,1)))
PROPS = []
ASSETS = {}


# Give each artistic layer an inspectable Blender collection.
def collection(name):
    c = bpy.data.collections.new(name)
    SCENE.collection.children.link(c)
    return c


TERRAIN = collection('01 WALKABLE - native 1m quads')
PROPCOL = collection('02 GLB obstacles and wall ornaments')
LIGHTS = collection('03 Lighting and review cameras')
STAGING = collection('99 Asset workshop - hidden after export')
ACTIVE = STAGING


# Convert the board's X,Z,height coordinates into Blender's Z-up space.
def world(x, z, h):
    return (x, -z, h)


# Build an exportable principled material, optionally with an image and relief preview.
def material(name, color, image_path=None, roughness=.85, metallic=0.0, emission=0.0):
    m = bpy.data.materials.new(name)
    m.diffuse_color = (*color, 1)
    m.use_nodes = True
    n, links = m.node_tree.nodes, m.node_tree.links
    p = n.get('Principled BSDF')
    p.inputs['Base Color'].default_value = (*color, 1)
    p.inputs['Roughness'].default_value = roughness
    p.inputs['Metallic'].default_value = metallic
    if image_path:
        t = n.new('ShaderNodeTexImage')
        t.image = bpy.data.images.load(str(image_path), check_existing=True)
        links.new(t.outputs['Color'], p.inputs['Base Color'])
        if image_path.suffix.lower() == '.png':
            links.new(t.outputs['Alpha'], p.inputs['Alpha'])
        bump = n.new('ShaderNodeBump')
        bump.inputs['Strength'].default_value = .2
        bump.inputs['Distance'].default_value = .055
        links.new(t.outputs['Color'], bump.inputs['Height'])
        links.new(bump.outputs['Normal'], p.inputs['Normal'])
    if emission:
        p.inputs['Emission Color'].default_value = (*color, 1)
        p.inputs['Emission Strength'].default_value = emission
    return m


STONE = material('Ancient ashlar - Angel Gate GPT source', (.3,.32,.31), OLD/'ancient_ashlar.png')
PAVING = material('Imperial inlaid marble - Angel Gate GPT source', (.65,.62,.48), OLD/'imperial_paving.png', .55)
PLASTER = material('New peeling lime plaster', (.5,.42,.3), ART/'plaster.png')
ROOF = material('New weathered slate', (.12,.18,.20), ART/'roof.png')
COBBLE = material('New old slum cobbles', (.18,.16,.13), ART/'cobble.png', .8)
WOOD = material('Dark split oak', (.075,.045,.026), ART/'wood.png', roughness=.92)
WOODLIGHT = material('Exposed oak edges', (.20,.115,.058), ART/'wood.png', roughness=.92)
SHUTTER = material('Old teal shutter paint', (.075,.16,.16), roughness=.9)
IRON = material('Oxidized wrought iron', (.065,.073,.065), roughness=.65, metallic=.62)
GOLD = material('Old burnished brass', (.37,.23,.065), roughness=.42, metallic=.72)
CREAM = material('Carved warm limestone', (.40,.35,.26), roughness=.8)
DARK = material('Window interior shadow', (.012,.018,.017))
GLASS = material('Small amber panes', (.4,.17,.045), roughness=.4, emission=.55)
CANVAS = material('Faded oxblood cloth', (.24,.065,.048), roughness=.98)
SACK = material('Dirty woven linen', (.34,.26,.15), roughness=1)
POT = material('Unglazed terracotta', (.31,.12,.065), roughness=.88)
GREEN = material('Cypress deep green', (.045,.09,.046), roughness=.93)
WATER = material('Dark fountain water', (.055,.17,.17), roughness=.16, metallic=.2)
BANNER = material('Old empire sun banner', (.06,.07,.11), OLD/'sun_banner.png')


# Create a mesh with metre-scaled planar UVs and a stable explicit collection owner.
def mesh(name, vertices, faces, mat, bevel=0):
    me = bpy.data.meshes.new(name)
    me.from_pydata(vertices, [], faces)
    me.update()
    ob = bpy.data.objects.new(name, me)
    ACTIVE.objects.link(ob)
    if mat:
        me.materials.append(mat)
    uv = me.uv_layers.new(name='Metres')
    for face in me.polygons:
        axis = max(range(3), key=lambda k: abs(face.normal[k]))
        for li in face.loop_indices:
            v = me.vertices[me.loops[li].vertex_index].co
            uv.data[li].uv = ((v.x if axis != 0 else -v.y)/4, (v.z if axis != 2 else -v.y)/4)
    if bevel:
        b = ob.modifiers.new('Worn physical edge', 'BEVEL')
        b.width, b.segments = bevel, 2
        bpy.context.view_layer.objects.active = ob
        ob.select_set(True)
        bpy.ops.object.modifier_apply(modifier=b.name)
        ob.select_set(False)
    return ob


# Add an architectural box in local board coordinates without altering terrain.
def box(name, lo, hi, mat, bevel=.012):
    x0,z0,h0 = lo
    x1,z1,h1 = hi
    v = [world(x,z,h) for h in (h0,h1) for z in (z0,z1) for x in (x0,x1)]
    return mesh(name,v,[(0,1,3,2),(4,6,7,5),(0,4,5,1),(2,3,7,6),(0,2,6,4),(1,5,7,3)],mat,bevel)


# Connect two authored points with a square timber or metal member.
def beam(name, start, end, width, mat):
    a,b = Vector(world(*start)),Vector(world(*end))
    d = b-a
    ob=box(name,(-width/2,-width/2,0),(width/2,width/2,d.length),mat,.01)
    ob.location=a
    ob.rotation_mode='QUATERNION'
    ob.rotation_quaternion=d.to_track_quat('Z','Y')
    return ob


# Lathe a radial profile for pottery, fountain stonework and chimney crowns.
def lathe(name, profile, centre, mat, segments=24):
    verts=[]
    for radius,height in profile:
        for i in range(segments):
            a=math.tau*i/segments
            verts.append(world(centre[0]+radius*math.cos(a),centre[1]+radius*math.sin(a),centre[2]+height))
    faces=[]
    for j in range(len(profile)-1):
        for i in range(segments):
            k=(i+1)%segments
            faces.append((j*segments+i,j*segments+k,(j+1)*segments+k,(j+1)*segments+i))
    return mesh(name,verts,faces,mat)


# Add a four-corner artwork plane with the complete source image rather than tiled UVs.
def artwork(name, corners, mat):
    ob=mesh(name,[world(*p) for p in corners],[(0,1,2,3)],mat)
    for i,uv in enumerate(((0,0),(1,0),(1,1),(0,1))):
        ob.data.uv_layers.active.data[i].uv=uv
    return ob


# Fit a source GLB exactly as Tile Studio does: uniform width, horizontal centring, bottom at zero.
def fit_asset(objects, width):
    points=[ob.matrix_world@Vector(v) for ob in objects if ob.type=='MESH' for v in ob.bound_box]
    lo=Vector(tuple(min(p[i] for p in points) for i in range(3)))
    hi=Vector(tuple(max(p[i] for p in points) for i in range(3)))
    scale=width/(hi.x-lo.x)
    size=(hi-lo)*scale
    grid=(round(width), math.ceil(size.z-.0001), math.ceil(size.y-.0001))
    # The Godot grid minimum becomes Blender's X minimum and negative Y maximum.
    offset=Vector(((grid[0]-size.x)/2-lo.x*scale,-(grid[2]-size.y)/2-hi.y*scale,-lo.z*scale))
    mat=Matrix.Translation(offset)@Matrix.Scale(scale,4)
    for ob in objects:
        ob.matrix_world=mat@ob.matrix_world
    return grid,(size.x,size.z,size.y)


# Export a newly authored prop and retain the same normalized source for scene instances.
def finish_asset(name, width, source=None):
    objects=list(STAGING.objects)
    if not objects:
        raise RuntimeError('Empty asset '+name)
    if source is None:
        source=ART/(name+'.glb')
        bpy.ops.object.select_all(action='DESELECT')
        for ob in objects:
            ob.select_set(True)
        # Joining retains material slots while avoiding hundreds of scene nodes per wall panel.
        bpy.context.view_layer.objects.active=objects[0]
        bpy.ops.object.join()
        objects=[bpy.context.object]
        # glTF cannot encode a height-to-normal shader; never export albedo as a normal map.
        removed=[]
        for m in {slot.material for ob in objects for slot in ob.material_slots if slot.material}:
            if not m.use_nodes:
                continue
            for link in list(m.node_tree.links):
                if link.from_node.type=='BUMP':
                    removed.append((m,link.from_socket,link.to_socket))
                    m.node_tree.links.remove(link)
        bpy.ops.export_scene.gltf(filepath=str(source),export_format='GLB',use_selection=True,export_animations=False,export_yup=True)
        for m,out_socket,in_socket in removed:
            m.node_tree.links.new(out_socket,in_socket)
    grid,size=fit_asset(objects,width)
    ASSETS[name]={'source':str(source.relative_to(ROOT)).replace('\\','/'),'width':width,'grid':list(grid),'size':list(size),'objects':objects}
    for ob in objects:
        ob.hide_render=True
        ob.hide_set(True)
        STAGING.objects.unlink(ob)
    return name


# Load only an Angel Gate source or an asset newly commissioned for this board.
def load_asset(name, source, width):
    before=set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=str(source))
    for ob in set(bpy.data.objects)-before:
        for col in list(ob.users_collection):
            col.objects.unlink(ob)
        STAGING.objects.link(ob)
    return finish_asset(name,width,source)


# Place a prop using the game's oriented grid box and explicit floor or wall support.
def place(name, x,z,h, quarter=0, wall=False, face='+Z'):
    a=ASSETS[name]
    gx,gy,gz=a['grid']
    sy=a['size'][2]
    angle=quarter*math.pi/2
    rot=Matrix.Rotation(angle,4,'Y')
    points=[rot@Vector((px,0,pz,1)) for px in (0,gx) for pz in (0,gz)]
    origin=Vector((min(p.x for p in points),0,min(p.z for p in points)))
    offset=Vector((x,h,z))-origin
    if wall:
        inset=(gz-sy)/2
        normal=Vector((1,0,0)) if face=='+X' else Vector((0,0,1))
        offset-=normal*inset
    transform=C@(Matrix.Translation(offset)@rot)@C.inverted()
    for src in a['objects']:
        ob=src.copy()
        PROPCOL.objects.link(ob)
        ob.name=name+' @ '+str((x,z))+' / '+src.name
        ob.hide_render=False
        ob.hide_set(False)
        ob.matrix_world=transform@src.matrix_world
    PROPS.append({'asset':'AGB_'+name.upper(),'origin':[x,round(h),z],'forward':['-Z','-X','+Z','+X'][quarter%4],'roll':0,'yaw':0,'support':'wall' if wall else 'floor',**({'support_face':face} if wall else {})})


# Build windows, shutters and timber work as thin wall-mounted GLBs, leaving roofs native.
def facade(width,height,peak,seed):
    random.seed(seed)
    box('Lower weather beam',(0,0,0),(width,.14,.16),WOOD)
    box('Upper eaves',(0,0,height-.14),(width,.25,height),WOODLIGHT)
    for x in (0,width-.16):
        box('Corner post',(x,0,0),(x+.16,.18,height),WOOD)
    for y in (2.0,4.0):
        if y < height-.2:
            box('Floor beam',(0,.01,y-.09),(width,.17,y+.09),WOOD)
    bays=max(2,int(width/1.5))
    for i in range(1,bays):
        x=width*i/bays
        box('Uneven upright',(x-.06,.02,.15),(x+.07,.15,height-.12),WOOD)
    for level in range(max(1,int(height/2))):
        for i in range(bays):
            cx=width*(i+.5)/bays
            bottom=.65+level*2
            if level==0 and i==bays//2:
                box('Door recess',(cx-.44,.012,.16),(cx+.44,.035,1.92),DARK)
                for k in range(6):
                    xx=cx-.40+k*.133
                    box('Door planks',(xx,.05,.17),(xx+.125,.08,1.84),WOODLIGHT if k%4==0 else WOOD)
                for yy in (.4,1.4):
                    box('Door iron strap',(cx-.41,.085,yy),(cx+.41,.12,yy+.055),IRON)
                continue
            box('Window recess',(cx-.42,.008,bottom),(cx+.42,.025,bottom+.9),DARK)
            panes=GLASS if random.random()<.28 else DARK
            box('Recessed panes',(cx-.34,.03,bottom+.1),(cx+.34,.045,bottom+.83),panes)
            for xx in (cx-.43,cx+.38,cx-.025):
                box('Window mullion',(xx,.04,bottom),(xx+.05,.12,bottom+.95),WOOD)
            for yy in (bottom,bottom+.46,bottom+.91):
                box('Window rail',(cx-.43,.04,yy),(cx+.43,.12,yy+.05),WOOD)
            box('Window sill',(cx-.49,.02,bottom-.09),(cx+.49,.29,bottom),WOODLIGHT)
            shutter_side=-1 if (i+level)%2 else 1
            sx=max(.24,min(width-.24,cx+shutter_side*.65))
            for k in range(3):
                xx=sx-.18+k*.12
                box('Shutter boards',(xx,.055,bottom),(xx+.11,.14,bottom+.94),SHUTTER)
            for yy in (bottom+.15,bottom+.73):
                box('Shutter brace',(sx-.19,.14,yy),(sx+.18,.19,yy+.055),WOODLIGHT)
    if peak:
        beam('Left gable timber',(.09,.12,height),(width/2,.12,height+peak),.12,WOODLIGHT)
        beam('Right gable timber',(width/2,.12,height+peak),(width-.09,.12,height),.12,WOODLIGHT)
        beam('Gable king post',(width/2,.12,height),(width/2,.12,height+peak),.10,WOOD)
    # A small uneven cloth brow adds silhouette without consuming a second ground cell.
    if width >= 3:
        cx=width*.5
        vertices=[]
        for j in range(5):
            for i in range(9):
                xx=cx-1.1+i*.275
                zz=.16+j*.21
                hh=2.1-j*.085-.07*math.sin(i*math.pi/8)
                vertices.append(world(xx,zz,hh))
        faces=[(j*9+i,j*9+i+1,(j+1)*9+i+1,(j+1)*9+i) for j in range(4) for i in range(8)]
        mesh('Sagging shop awning',vertices,faces,CANVAS)
        for xx in (cx-1.1,cx+1.1):
            beam('Awning brace',(xx,.05,1.25),(xx,.9,1.75),.06,WOOD)


WIDTH,DEPTH=36,34
TOPS=[[[0.0]*4 for x in range(WIDTH)] for z in range(DEPTH)]
MAT=[['cobble']*WIDTH for z in range(DEPTH)]
SIDE=[['ashlar']*WIDTH for z in range(DEPTH)]
HOUSES=[(0,16,5,6,5,1),(6,16,4,5,6,1),(10,17,3,4,4,0),(0,24,4,5,4,1),(5,24,3,6,3,1),(10,28,4,5,4,1),(0,31,5,3,2,0),(31,18,5,5,4,1),(32,27,4,4,3,1),(28,31,3,3,2,0)]


# Edit native quad corners in bounded rectangles; every value is stored in the board source.
def region(x,z,w,d,height,mat='ashlar',side='ashlar'):
    for zz in range(z,z+d):
        for xx in range(x,x+w):
            TOPS[zz][xx]=[float(height)]*4
            MAT[zz][xx]=mat
            SIDE[zz][xx]=side


region(0,0,36,12,1.5,'paving')
region(0,12,21,2,10)
region(27,12,9,2,10)
for x in (18,27):
    region(x,11,3,4,12)
for x in (0,6,12,33):
    region(x,12,2,3,10.5)
for x in (2,4,8,10,14,16,30,32):
    region(x,12,1,1,10.7)
for z in range(12,19):
    region(21,z,6,1,max(0,1.5-max(0,z-14)*.3),'paving' if z<16 else 'cobble')
region(14,17,8,8,.3,'ashlar')
region(15,18,6,6,.8,'ashlar')
region(16,19,4,4,1.5,'ashlar')
for i,(x,z,w,d,h,gable) in enumerate(HOUSES):
    region(x,z,w,d,h,'roof','plaster')
    if gable:
        for zz in range(z,z+d):
            for xx in range(x,x+w):
                TOPS[zz][xx]=[h+.42*min(dx,w-dx) for dx in (xx-x,xx-x+1,xx-x,xx-x+1)]
    peak=.42*w/2 if gable else 0
    key=f'facade_{w}_{h}_{gable}'
    if key not in ASSETS:
        facade(w,h,peak,i+20)
        finish_asset(key,w)
    place(key,x,z+d,0,wall=True)
    sidekey=f'side_{d}_{h}'
    if sidekey not in ASSETS:
        facade(d,h,0,i+41)
        finish_asset(sidekey,d)
    if x+w<36:
        place(sidekey,x+w,z,0,quarter=1,wall=True,face='+X')
for z in range(17,25):
    region(13,z,2,1,(25-z)*.5,'ashlar')
for z in range(21,29):
    region(29,z,2,1,(29-z)*.5,'ashlar')


# Construct every visible terrain face directly from the native top quads and their edge gaps.
def terrain_mesh():
    global ACTIVE
    ACTIVE=TERRAIN
    verts=[];faces=[];materials=[];kinds=[]
    edges=[(0,1,0,-1),(1,3,1,0),(3,2,0,1),(2,0,-1,0)]
    corners=[(0,0),(1,0),(0,1),(1,1)]
    sidefaces={}
    for z in range(DEPTH):
        for x in range(WIDTH):
            hh=TOPS[z][x]
            pts=[world(x+dx,z+dz,hh[i]) for i,(dx,dz) in enumerate(corners)]
            start=len(verts);verts.extend(pts);faces.append(tuple(start+i for i in (0,2,3,1)))
            materials.append(MAT[z][x]);kinds.append((x,z,0))
            for e,(a,b,dx,dz) in enumerate(edges):
                nx,nz=x+dx,z+dz
                if 0<=nx<WIDTH and 0<=nz<DEPTH:
                    opposite=edges[(e+2)%4]
                    nh=TOPS[nz][nx]
                    lowa,lowb=nh[opposite[1]],nh[opposite[0]]
                    if max(hh[a]-lowa,hh[b]-lowb)<.0005:
                        continue
                    if min(hh[a]-lowa,hh[b]-lowb)<-.0005:
                        raise RuntimeError('Crossing edge requires explicit split')
                    sidefaces[f'{x},{z},{e}']=[0.,1.,lowa,hh[a],lowb,hh[b]]
                else:
                    lowa=lowb=min(-1.,min(hh)-1)
                va,vb=pts[a],pts[b]
                start=len(verts)
                verts.extend([va,vb,(vb[0],vb[1],lowb),(va[0],va[1],lowa)])
                faces.append(tuple(start+i for i in (0,1,2,3)))
                materials.append(SIDE[z][x]);kinds.append((x,z,1))
    ob=mesh('Angel Gate II - authoritative 1224 grid cells',verts,faces,None)
    palette={'ashlar':STONE,'paving':PAVING,'plaster':PLASTER,'roof':ROOF,'cobble':COBBLE}
    for m in palette.values():
        ob.data.materials.append(m)
    keys=list(palette)
    for face,key in zip(ob.data.polygons,materials):
        face.material_index=keys.index(key)
    for name,index in [('cell_x',0),('cell_z',1),('is_wall',2)]:
        attr=ob.data.attributes.new(name,'INT','FACE')
        for item,kind in zip(attr.data,kinds):
            item.value=kind[index]
    ob['grid_size_m']=1.0
    ob['game_contract']='Native top quads plus explicit vertical edge profiles; no alternate walk mesh.'
    ACTIVE=STAGING
    return sidefaces


SIDES=terrain_mesh()

# Give the ancient masonry a carved structural rhythm with thin wall ornaments.
for height in (10,12):
    for x in (.02,2.70):
        box('Pilaster base',(x,0,0),(x+.28,.42,.45),STONE)
        box('Pilaster shaft',(x+.045,0,.45),(x+.235,.26,height-.45),STONE)
        box('Carved capital',(x,0,height-.5),(x+.28,.42,height),CREAM)
    for h in (3.5,7.3,height-.22):
        box('Masonry string course',(0,0,h),(3,.34,h+.16),CREAM)
    artwork('Imperial hanging cloth',[(1,.37,3.8),(2,.37,3.8),(2,.37,height-1),(1,.37,height-1)],BANNER)
    finish_asset('wall_'+str(height),3)
for x in (3,9,15,30):
    place('wall_10',x,14,0,wall=True)
for x in (18,27):
    place('wall_12',x,15,0,wall=True)

load_asset('angel',OLD/'conquering_angel.glb',4)
place('angel',16,19,1.5)
load_asset('palazzo',OLD/'palazzo.glb',9)
place('palazzo',9,0,1.5,quarter=3)
place('palazzo',28,1,1.5,quarter=3)
load_asset('arch',OLD/'gate_arch.glb',6)
place('arch',21,12,1.5)
load_asset('market',ART/'market.glb',3)
place('market',8,22,0,quarter=2)
place('market',25,25,0,quarter=1)
place('market',6,31,0)

# Use the commissioned Meshy sculpture for the sagging sacks and damaged cargo.
load_asset('salvage',ART/'salvage.glb',2)
for x,z,q in ((17,28,0),(25,30,1),(27,18,0),(15,25,2),(5,22,0)):
    place('salvage',x,z,0,q)

# Author slender street lanterns whose lights remain board-owned in the game.
box('Stone lantern foot',(0,0,0),(1,1,.2),STONE)
beam('Iron lantern post',(.5,.5,.2),(.5,.5,3.6),.075,IRON)
beam('Lantern top arm',(.5,.5,3.55),(.84,.5,3.55),.07,IRON)
box('Lantern amber glass',(.67,.33,2.83),(.97,.67,3.35),GLASS)
for xx in (.65,.97):
    for zz in (.31,.67):
        beam('Lantern cage',(xx,zz,2.79),(xx,zz,3.4),.035,IRON)
box('Lantern rain cap',(.61,.27,3.36),(1,.71,3.44),IRON)
finish_asset('lantern',1)
for x,z in ((12,23),(27,23),(22,18),(16,27)):
    place('lantern',x,z,0)

# Build an upper-class court fountain with lathed stone and a restrained brass crown.
lathe('Octagonal fountain base',[(1.4,0),(1.5,.15),(1.5,.25),(1.37,.28),(1.37,.5),(1.27,.55),(1.17,.45),(1.17,.2)],(1.5,1.5,0),CREAM,32)
lathe('Fountain basin water',[(0,.26),(1.17,.26)],(1.5,1.5,0),WATER,48)
lathe('Central baluster',[(.35,.1),(.35,.3),(.22,.36),(.15,1.1),(.32,1.18),(.33,1.28),(.20,1.33)],(1.5,1.5,0),CREAM)
lathe('Upper fountain bowl',[(.12,1.25),(.65,1.5),(.68,1.58),(.55,1.6),(.15,1.4)],(1.5,1.5,0),GOLD,32)
finish_asset('fountain',3)
place('fountain',22,4,1.5)

# Assemble deliberately pruned cypresses from small irregular foliage clusters.
random.seed(57)
box('Planter square',(0,0,0),(2,2,.3),CREAM)
box('Planter rim',(.1,.1,.3),(1.9,1.9,.52),CREAM)
beam('Cypress trunk',(1,1,.4),(1,1,4.5),.12,WOOD)
for i in range(65):
    h=random.uniform(.85,4.8)
    r=.67*(1-(h-.8)/4.6)**.6
    theta=random.random()*math.tau
    cx=1+math.cos(theta)*r*.45
    cz=1+math.sin(theta)*r*.45
    bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=1,radius=1,location=world(cx,cz,h))
    ob=bpy.context.object
    for col in list(ob.users_collection):
        col.objects.unlink(ob)
    STAGING.objects.link(ob)
    ob.name='Pruned cypress foliage'
    ob.scale=(r*.7,r*.68,.34+random.random()*.25)
    ob.data.materials.append(GREEN)
finish_asset('court_cypress',2)
for x,z in ((19,2),(26,7),(17,7),(26,0)):
    place('court_cypress',x,z,1.5)

# Roof chimneys are ordinary obstacles resting on explicitly level roof cells.
box('Brick chimney stack',(.1,.1,0),(.9,.9,1.75),STONE)
box('Chimney coping',(0,0,1.65),(1,1,1.88),CREAM)
lathe('Sooted chimney pot',[(.24,1.8),(.25,2.1),(.18,2.4),(.21,2.5),(.13,2.5),(.13,2.2)],(.5,.5,0),POT)
finish_asset('chimney',1)
for x,z in ((2,18),(7,18),(1,26),(11,30),(33,20),(33,28)):
    # Keep the existing corner heights: support is the quad-centre height, never a separate art offset.
    place('chimney',x,z,sum(TOPS[z][x])/4)

# Persist the board inputs beside the editable blend, with no legacy library assets.
source={'name':'Angel Gate - Blender','size':[WIDTH,DEPTH],'top_heights':[h for row in TOPS for cell in row for h in cell],
        'side_faces':SIDES,'top_materials':MAT,'side_materials':SIDE,'houses':HOUSES,'props':PROPS,
        'assets':{k:{p:v for p,v in a.items() if p!='objects'} for k,a in ASSETS.items()}}
(OUT/'board_source.json').write_text(json.dumps(source,indent=2))
STAGING.hide_render=True
STAGING.hide_viewport=True


# Aim an object using Blender's conventional camera/light local axes.
def aim(ob,target):
    ob.rotation_euler=(Vector(target)-ob.location).to_track_quat('-Z','Y').to_euler()


# Set up fixed review views, retaining all cameras in the editable source.
def camera(name,target,scale,offset):
    data=bpy.data.cameras.new(name)
    ob=bpy.data.objects.new(name,data)
    LIGHTS.objects.link(ob)
    ob.location=Vector(world(*target))+Vector(offset)
    aim(ob,world(*target))
    data.type='ORTHO';data.ortho_scale=scale;data.lens=45
    return ob


overview=camera('Gameplay overview',(18,17,3.5),54,(37,-37,37))
detail=camera('Gate and slum',(18,19,4.5),34,(37,-37,37))
SCENE.camera=detail
worldmat=bpy.data.worlds.new('Cool overcast fill')
worldmat.use_nodes=True
worldmat.node_tree.nodes['Background'].inputs['Color'].default_value=(.20,.29,.38,1)
worldmat.node_tree.nodes['Background'].inputs['Strength'].default_value=.55
SCENE.world=worldmat
# Camera rays see the same dark backdrop intended for the game, while sky rays still fill shadows.
wn=worldmat.node_tree.nodes;wl=worldmat.node_tree.links
camera_bg=wn.new('ShaderNodeBackground');camera_bg.inputs['Color'].default_value=(.018,.026,.035,1)
ray=wn.new('ShaderNodeLightPath');mix=wn.new('ShaderNodeMixShader')
wl.new(ray.outputs['Is Camera Ray'],mix.inputs[0]);wl.new(wn['Background'].outputs[0],mix.inputs[1]);wl.new(camera_bg.outputs[0],mix.inputs[2]);wl.new(mix.outputs[0],wn['World Output'].inputs[0])
sun_data=bpy.data.lights.new('Late sun across the imperial court','SUN')
sun_data.energy=2.4;sun_data.color=(1,.84,.65);sun_data.angle=.10
sun=bpy.data.objects.new(sun_data.name,sun_data);LIGHTS.objects.link(sun)
sun.location=(3,-40,30);aim(sun,(18,-18,0))
court_data=bpy.data.lights.new('Warm light in the imperial court','AREA')
court_data.energy=1600;court_data.shape='DISK';court_data.size=9;court_data.color=(1,.84,.6)
court=bpy.data.objects.new(court_data.name,court_data);LIGHTS.objects.link(court)
court.location=(23,-4,15);aim(court,(23,-5,0))
for x,z,energy in ((12,23,80),(27,23,90),(22,18,70),(16,27,65)):
    ld=bpy.data.lights.new('Warm street lamp','POINT');ld.energy=energy;ld.color=(1,.43,.12);ld.shadow_soft_size=.18
    lo=bpy.data.objects.new(ld.name,ld);LIGHTS.objects.link(lo);lo.location=world(x+.8,z+.5,3.1)
SCENE.render.engine='CYCLES'
SCENE.cycles.samples=48
SCENE.cycles.use_denoising=True
preferences=bpy.context.preferences.addons['cycles'].preferences
preferences.compute_device_type='OPTIX'
preferences.get_devices()
for device in preferences.devices:
    device.use=device.type=='OPTIX'
SCENE.cycles.device='GPU'
SCENE.render.resolution_x=1600;SCENE.render.resolution_y=1400;SCENE.render.resolution_percentage=100
SCENE.view_settings.view_transform='AgX'
SCENE.render.image_settings.file_format='PNG'
for image in bpy.data.images:
    if image.source=='FILE' and image.packed_file is None:
        image.pack()
# Open the editable source at its review camera with the authored lights and world.
for screen in bpy.data.screens:
    for area in screen.areas:
        if area.type=='VIEW_3D':
            area.spaces.active.region_3d.view_perspective='CAMERA'
            area.spaces.active.shading.type='MATERIAL'
            area.spaces.active.shading.use_scene_world=True
            area.spaces.active.shading.use_scene_lights=True
            area.spaces.active.overlay.show_overlays=False
bpy.ops.wm.save_as_mainfile(filepath=str(OUT/'angel_gate.blend'))
SCENE.render.filepath=str(ROOT/'captures'/'angel_blender_detail_final.png')
bpy.ops.render.render(write_still=True)
SCENE.camera=overview
SCENE.render.filepath=str(ROOT/'captures'/'angel_blender_overview_final.png')
bpy.ops.render.render(write_still=True)
SCENE.camera=detail
print('ANGEL_BLENDER_COMPLETE '+json.dumps({'cells':WIDTH*DEPTH,'props':len(PROPS),'assets':len(ASSETS)}))
