"""Author reusable metre-sized prison props; the native board owns all level placement."""
from pathlib import Path
import bpy
import math
import random
import json
from mathutils import Matrix, Vector

ROOT = Path(__file__).resolve().parents[1]
ART = ROOT / 'assets/belowward_cell'
OUT = ROOT / 'exports/belowward_cell'
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


STONE = material('Damp blue-grey prison ashlar', (.24,.27,.29), ART/'ashlar_v2_chord/albedo.png')
CAP = material('Worn coping limestone', (.20,.235,.26), ART/'ashlar_v2_chord/albedo.png')
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
MURAL = material('Silence feeds it - authored mural', (.4,.4,.4), ART/'mural_v2.png')
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


# Export each finished prop as one mesh with material surfaces and record its measured box.
def finish(name, width):
    bpy.ops.object.select_all(action='DESELECT')
    for ob in PARTS:
        ob.select_set(True)
    bpy.context.view_layer.objects.active=PARTS[0]
    bpy.ops.object.join()
    ob=bpy.context.object
    ob.name=name
    bpy.ops.object.transform_apply(location=True,rotation=True,scale=True)
    pts=[ob.matrix_world@Vector(v) for v in ob.bound_box]
    lo=Vector([min(p[k] for p in pts) for k in range(3)])
    hi=Vector([max(p[k] for p in pts) for k in range(3)])
    dimensions={'cell_front':(4,5,2),'pier':(1,5,1),'low_cell':(4,2.4,1),
                'railing':(2,1.9,1),'open_gate':(4,4,1),'hanging_cage':(2,9,2),
                'lantern':(1,3,1),'crate':(1,1,1),'wardens_table':(2,2,1),
                'bone_rack':(2,.8,1),'spire_tall':(2,8,2),'spire_short':(2,4,2),
                'fissure_mural_v2':(12,8,.025),'rubble':(2,.6,2),'parapet':(2,1.4,1),
                'buttress':(2,12,2),'ledge':(4,.8,1),'lantern_v2':(1,3,1),
                'barrel_cluster':(2,1.6,2),'broken_coping':(4,.65,1),
                'debris_drift':(3,.4,1),'torture_frame':(3,2.5,2),
                'broken_railing':(2,1.65,1),'lantern_caged':(1,3,1),
                'debris_flat':(3,.18,1),'cage_bracket_2':(2,2.3,3),
                'cage_bracket_3':(2,2.3,4),'cage_bracket_5':(2,2.3,6),
                'cage_suspension_2':(2,9.3,3),'cage_suspension_3':(2,9.3,4),
                'cage_suspension_5':(2,9.3,6),'parapet_supported':(2,3.4,1),
                'shaft_cell_floored':(4,7,2),'pillar_cage_suspension':(5,12.3,2)}
    dx,dh,dz=dimensions[name]
    # Author the source mesh to its declared physical box before import; tiny bevel
    # protrusions must not turn a one-metre crate into a two-cell obstacle.
    factor=Vector((dx/(hi.x-lo.x),dz/(hi.y-lo.y),dh/(hi.z-lo.z)))
    size=Vector((dx,dz,dh))
    grid=[math.ceil(dx),math.ceil(dh),math.ceil(dz)]
    shift=Vector(((grid[0]-dx)/2-lo.x*factor.x,-(grid[2]-dz)/2-hi.y*factor.y,-lo.z*factor.z))
    # Finished donor geometry must retain its exact dimensions and placement in these assemblies.
    if name not in ('broken_railing','pillar_cage_suspension'):
        for vert in ob.data.vertices:
            vert.co=vert.co*factor+shift
    if name=='railing':
        for vert in RAIL_COPING.vertices:
            vert.co=vert.co*factor+shift
        RAIL_COPING.update()
    ob.data.update()
    worn=any(mat in (STONE,CAP) for mat in ob.data.materials)
    export_name=name+'_worn' if worn else name
    if name=='open_gate':
        export_name='open_gate_passage'
    if name=='crate':
        export_name='crate_iron_bound'
    if name=='broken_railing':
        export_name='broken_railing_matched_worn'
    if name=='fissure_mural_v2':
        export_name='fissure_mural_flush'
    path=ART/(export_name+'.glb')
    bpy.ops.export_scene.gltf(filepath=str(path),export_format='GLB',use_selection=True,export_animations=False,export_yup=True)
    ASSETS[name]={'path':str(path).replace('\\','/'),'export_name':export_name,'grid':grid,'driver_axis':0,'width':width,'triangles':sum(len(p.vertices)-2 for p in ob.data.polygons)}
    ob.hide_set(True)
    ob.hide_render=True
    ob.select_set(False)
    PARTS.clear()
    print('ASSET_READY '+json.dumps(ASSETS[name]),flush=True)


# Build uneven masonry with small course offsets instead of a perfectly smooth cube.
def masonry(x,z,w,d,h,course=.4):
    box('Mortar core',(x+.04,z+.04,0),(x+w-.04,z+d-.04,h-.04),STONE,.025)
    rows=math.ceil(h/course)
    for row in range(rows):
        y0=row*course
        y1=min(h,y0+course)-.018
        cuts=[0,w]
        pos=(.3 if row%2 else .65)
        while pos<w:
            cuts.append(pos)
            pos+=random.uniform(.5,.85)
        cuts.sort()
        for a,b in zip(cuts[:-1],cuts[1:]):
            box('Uneven face block',(x+a+.012,z+d-.13,y0+.012),(x+b-.012,z+d+random.uniform(-.025,.025),y1),STONE,.025)


# Recessed prison cell fronts are real bars in front of a dark stone chamber.
box('Cell rear wall',(0,0,0),(4,.35,5),STONE,.045)
masonry(0,0,.65,2,5)
masonry(3.35,0,.65,2,5)
box('Massive cell lintel',(.6,.8,3.7),(3.4,2,4.45),STONE,.06)
box('Cell cornice',(0,0,4.45),(4,2,4.7),CAP,.055)
for i in range(8):
    box('Loose cornice cap',(i*.5+.02,.05,4.7),(i*.5+.48,1.95,5),CAP,.04)
box('Cell bed',(.85,.4,.35),(2.75,1.4,.62),WOOD)
for x in [ .78+i*.235 for i in range(11) ]:
    beam('Cell upright bar',(x,1.8,.1),(x,1.8,3.73),.065,IRON)
for h in (.16,1.2,2.65,3.58):
    box('Cell horizontal strap',(.65,1.72,h),(3.35,1.88,h+.10),IRON)
box('Lock plate',(2.65,1.87,1.5),(2.92,1.91,1.88),RUST)
finish('cell_front',4)

# Full-height dressed piers punctuate cell rows and support gallery corners.
masonry(0,0,1,1,5)
box('Pier cap',(-.05,-.05,4.7),(1.05,1.05,5),CAP,.06)
finish('pier',1)

# Lower cutaway cell fronts preserve the foreground while still reading as confinement.
masonry(0,0,.5,1,2.4)
masonry(3.5,0,.5,1,2.4)
for x in [.7+i*.26 for i in range(11)]:
    beam('Cutaway prison bars',(x,.65,0),(x,.65,2.4),.055,IRON)
for h in (.1,1,2.25):
    box('Cutaway strap',(.45,.58,h),(3.55,.73,h+.08),IRON)
finish('low_cell',4)

# A coping with pointed iron rails is narrow enough to leave the gallery route open.
RAIL_COPING=box('Gallery coping',(0,.1,0),(2,.9,.35),CAP,.045).data.copy()
for x in (.12,.55,1,1.45,1.88):
    beam('Rail upright',(x,.5,.25),(x,.5,1.6),.065,IRON)
    lathe('Rail spear',[(0,0),(.095,.13),(0,.34)],(x,.5,1.53),IRON,4)
for h in (.73,1.4):
    box('Rail horizontal',(0,.44,h),(2,.56,h+.065),IRON)
finish('railing',2)

# The gateway has a genuinely open two-metre centre in the measured obstacle voxel scan.
masonry(0,0,.8,1,4)
masonry(3.2,0,.8,1,4)
box('Gate header',(.75,0,3.25),(3.25,1,4),STONE,.065)
for x in (.65,3.35):
    beam('Door hinge',(x,.6,0),(x,.6,3.15),.09,IRON)
finish('open_gate',4)

# Suspended iron cages include a shallow domed cap and alternating chain links.
for h in (.1,.3,1.4,2.65):
    lathe('Cage hoop',[(.82,h),(.85,h),(.85,h+.10),(.82,h+.10),(.82,h)],(.9,.9,0),IRON,24)
for i in range(16):
    a=math.tau*i/16
    x,z=.9+.82*math.cos(a),.9+.82*math.sin(a)
    beam('Cage upright',(x,z,.14),(x,z,2.7),.055,IRON)
    beam('Domed cage rib',(x,z,2.7),(.9,.9,3.15),.052,IRON)
for t in range(-3,4):
    length=math.sqrt(max(0,.75**2-(t*.2)**2))
    beam('Cage floor grating',(.9-length,.9+t*.2,.17),(.9+length,.9+t*.2,.17),.06,IRON)
chain(.9,.9,3.15,8)
finish('hanging_cage',2)

# A lantern includes luminous panes, cage ribs, wall bracket and candle core.
box('Lantern wall plate',(.35,0,.1),(.65,.08,2),IRON)
beam('Lantern bracket',(.5,.04,1.8),(.5,.75,2.5),.085,IRON)
chain(.5,.72,1.9,2.5)
box('Amber panes',(.27,.48,1.1),(.73,.94,1.83),FLAME,.01)
for x in (.25,.75):
    for z in (.46,.96):
        beam('Lantern iron rib',(x,z,1.04),(x,z,1.91),.05,BRASS)
lathe('Lantern roof',[(.42,1.87),(.12,2.13),(0,2.2)],(.5,.71,0),IRON,4)
lathe('Lantern foot',[(0,1.02),(.4,1.06),(.4,1.15)],(.5,.71,0),IRON,4)
finish('lantern',1)

# Continuous forged hoops wrap the same oak body, with modest thickness and sparse domed rivets.
box('Crate dark core',(.025,.025,.025),(.975,.975,.935),DARK)
for i in range(5):
    box('Crate plank',(i*.2+.012,0,.04),(i*.2+.185,1,.96),WOOD,.009)
    box('Crate lid plank',(.01,i*.2+.01,.96),(.99,i*.2+.19,1),WOOD,.009)
for x in (.12,.78):
    for z in (-.016,.99):
        box('Wrapped upright iron strap',(x,z,.015),(x+.10,z+.026,1.016),CRATE_IRON,.006)
    for h in (.008,1.):
        box('Continuous hoop across lid and underside',(x,-.016,h),(x+.10,1.016,h+.025),CRATE_IRON,.006)
    for z in (.15,.84):
        lathe('Domed lid rivet',[(.016,0),(.017,.006),(.009,.015),(0,.018)],(x+.05,z,1.026),RIVET,8)
    for z,normal in ((-.017,Vector((0,1,0))),(1.017,Vector((0,-1,0)))):
        for h in (.13,.51,.89):
            rivet=lathe('Hammered face rivet',[(.016,0),(.017,.006),(.009,.015),(0,.018)],(0,0,0),RIVET,8)
            rivet.location=world(x+.05,z,h)
            rivet.rotation_mode='QUATERNION'
            rivet.rotation_quaternion=normal.to_track_quat('Z','Y')
# Short folded corner shoes protect the exposed board ends and give the side faces readable construction.
for x in (0,.90):
    for z in (0,.90):
        for h in (.06,.80):
            side_x=-.017 if x==0 else 1.
            side_z=-.017 if z==0 else 1.
            box('Folded corner shoe face',(x,side_z,h),(x+.10,side_z+.017,h+.13),CRATE_IRON,.004)
            box('Folded corner shoe return',(side_x,z,h),(side_x+.017,z+.10,h+.13),CRATE_IRON,.004)
finish('crate',1)

# An evidence table groups candles, papers, an old skull and tools into one authored prop.
for x in (.12,1.85):
    for z in (.1,.84):
        box('Desk leg',(x,z,0),(x+.10,z+.10,.92),WOOD)
for i in range(6):
    box('Desk top plank',(0,i*.17,.9),(2,i*.17+.155,1.04),WOOD)
for x,z,h in ((.2,.3,.5),(.45,.7,.32),(1.65,.2,.65)):
    lathe('Candlestick',[(.10,0),(.06,.15),(.05,h)],(x,z,1.04),BONE)
    lathe('Candle flame',[(.025,0),(.065,.09),(0,.21)],(x,z,1.04+h),HOT)
box('Dusty folio',(.8,.22,1.04),(1.37,.68,1.09),BONE,.007)
beam('Rusty prison tool',(.9,.83,1.07),(1.7,.75,1.07),.045,IRON)
lathe('Small skull',[(0,0),(.13,.03),(.17,.17),(.14,.29),(0,.34)],(1.55,.7,1.06),BONE,12)
finish('wardens_table',2)

# The rack silhouette supplies a recognizable human-scale story prop without a new game unit.
for z in (.06,.86):
    beam('Rack oak side',(0,z,.22),(2,z,.22),.12,WOOD)
for x in [i*.22 for i in range(10)]:
    box('Rack cross plank',(x,0,.25),(x+.16,1,.33),WOOD)
beam('Skeleton spine',(.48,.5,.42),(1.42,.5,.42),.09,BONE)
for i in range(6):
    x=.7+i*.10
    beam('Old rib',(x,.25,.43),(x,.75,.43),.043,BONE)
for z in (.37,.63):
    beam('Leg bone',(1.25,z,.42),(1.87,z,.40),.055,BONE)
    beam('Arm bone',(.78,z,.42),(.48,.12 if z<.5 else .88,.41),.047,BONE)
lathe('Rack skull',[(0,0),(.17,.08),(.15,.28),(0,.31)],(.3,.5,.34),BONE,12)
finish('bone_rack',2)

# Jagged masonry spires descend into the chasm and remain distinct from the terrain lattice.
for name,h in [('spire_tall',8),('spire_short',4)]:
    masonry(.1,.1,1.8,1.8,h-.6,.45)
    for i in range(4):
        for j in range(3):
            top=h-random.uniform(0,.95)
            box('Broken crown',(.1+i*.45,.1+j*.6,h-1.1),(.51+i*.45,.66+j*.6,top),CAP,.045)
    finish(name,2)

# Apply the entire mural image to one shallow architectural panel, with no texture tiling.
box('Mural support',(0,0,0),(12,.1,8),DARK,.01)
ob=mesh('Silence feeds it fresco',[world(0,.11,0),world(12,.11,0),world(12,.11,8),world(0,.11,8)],[(0,1,2,3)],MURAL)
for i,uv in enumerate(((0,0),(1,0),(1,1),(0,1))):
    ob.data.uv_layers.active.data[i].uv=uv
finish('fissure_mural_v2',12)

# Rubble clusters give walls grounded irregular bases and create small tactical obstacles.
for i in range(16):
    x,z=random.uniform(.12,1.65),random.uniform(.12,1.65)
    w,d,h=random.uniform(.22,.45),random.uniform(.18,.4),random.uniform(.16,.40)
    ob=box('Fallen masonry',(x,z,0),(x+w,z+d,h),STONE,.035)
finish('rubble',2)

# Low parapet fragments articulate the outer silhouette without hiding the foreground path.
masonry(0,0,2,1,1.15)
for x in (.03,.7,1.37):
    box('Broken parapet coping',(x,0,1.1),(x+.61,1,1.4),CAP,.05)
finish('parapet',2)

# Tall stepped buttresses give the chasm walls load-bearing intermediate silhouettes.
masonry(.2,.2,1.6,1.6,10.7,.45)
box('Buttress foot',(0,0,0),(2,2,1.1),CAP,.08)
box('Middle belt',(.07,.07,5.3),(1.93,1.93,5.8),CAP,.065)
box('Corbel crown',(0,0,10.7),(2,2,11.4),CAP,.07)
for x in (.02,.68,1.34):
    box('Crown course',(x,.02,11.4),(x+.63,1.98,12),CAP,.04)
finish('buttress',2)

# The ledge is a real projecting stone band that joins wall piers below the galleries.
box('Deep ledge moulding',(0,0,0),(4,.75,.55),STONE,.05)
for x in (0,1,2,3):
    box('Ledge coping',(x+.012,0,.55),(x+.988,1,.8),CAP,.04)
finish('ledge',4)

# Narrow luminous panes remain enclosed by readable iron rather than becoming bright cubes.
box('Lantern mounting plate',(.17,0,.1),(.83,.08,2.6),IRON)
beam('Sconce arm',(.5,.03,2.5),(.5,.78,2.8),.07,IRON)
chain(.5,.72,2.10,2.8)
box('Recessed amber panes',(.36,.55,1.25),(.64,.83,1.92),FLAME,.005)
for x in (.32,.68):
    for z in (.51,.87):
        beam('Thick enclosing lamp rib',(x,z,1.19),(x,z,2.0),.06,IRON)
for h in (1.18,1.56,1.98):
    box('Lantern cage cross strap',(.30,.49,h),(.70,.89,h+.055),IRON,.004)
lathe('Hipped lantern cap',[(.3,2.02),(.12,2.27),(0,2.34)],(.5,.69,0),IRON,4)
lathe('Lantern brass foot',[(0,1.10),(.3,1.15),(.3,1.25)],(.5,.69,0),BRASS,4)
finish('lantern_v2',1)

# Bulging coopered barrels and spilled hoops form a grounded two-metre cover cluster.
for cx,cz,r,h in ((.52,.56,.46,1.5),(1.5,1.38,.43,1.2),(1.48,.4,.32,.85)):
    for i in range(16):
        a0=math.tau*(i+.018)/16
        a1=math.tau*(i+.982)/16
        vertices=[]
        for t in (0,.08,.3,.7,.94,1):
            radius=r*(.82+.18*math.sin(math.pi*t))
            for a in (a0,a1):
                vertices.append(world(cx+radius*math.cos(a),cz+radius*math.sin(a),h*t))
        mesh('Curved individual oak stave',vertices,[(j*2,j*2+1,j*2+3,j*2+2) for j in range(5)],WOOD)
    for t in (.08,.25,.76,.94):
        radius=r*(.82+.18*math.sin(math.pi*t))+.009
        lathe('Forged barrel hoop',[(radius,h*t),(radius,h*t+.065)],(cx,cz,0),IRON,32)
    lathe('Recessed cask lid',[(0,h-.035),(.81*r,h-.035)],(cx,cz,0),WOOD,16)
    for d in (-.18,0,.18):
        beam('Lid stave seam',(cx-.28,cz+d,h-.02),(cx+.28,cz+d,h-.02),.014,DARK)
finish('barrel_cluster',2)

# Broken coping varies the top silhouette with displaced stones and missing corners.
for i in range(7):
    x=i*.57
    h=random.uniform(.22,.62)
    ob=box('Dislodged coping stone',(x,random.uniform(0,.12),0),(x+random.uniform(.36,.54),random.uniform(.78,1),h),CAP,random.uniform(.035,.08))
    ob.rotation_euler.z=random.uniform(-.08,.08)
    ob.rotation_euler.x=random.uniform(-.04,.04)
finish('broken_coping',4)

# A tapered drift combines tiny angular masonry, splinters and spent iron at wall feet.
for i in range(40):
    x,z=random.uniform(.05,2.7),random.uniform(.02,.76)
    w,d,h=random.uniform(.06,.3),random.uniform(.06,.22),random.uniform(.035,.28)
    ob=box('Masonry fragment',(x,z,0),(x+w,z+d,h),STONE,random.uniform(.008,.035))
    ob.rotation_euler.z=random.uniform(-.7,.7)
for i in range(7):
    x,z=random.uniform(.2,2.4),random.uniform(.15,.8)
    beam('Broken oak splinter',(x,z,.04),(x+random.uniform(.25,.5),z+random.uniform(-.15,.15),.07),.04,WOOD)
finish('debris_drift',3)

# An iron-bound torture frame gives one substantial narrative obstacle to each encounter landing.
for x in (.12,2.72):
    for z in (.14,1.7):
        box('Oak frame upright',(x,z,0),(x+.16,z+.16,2.25),WOOD,.028)
        for h in (.1,.9,1.9):
            box('Iron post binding',(x-.025,z-.025,h),(x+.185,z+.185,h+.10),IRON,.008)
for z in (.18,1.78):
    beam('Heavy cross beam',(.08,z,2.23),(2.94,z,2.23),.18,WOOD)
    beam('Stretcher rail',(.15,z,.65),(2.85,z,.65),.15,WOOD)
for x in [i*.25+.2 for i in range(11)]:
    box('Stained rack board',(x,.15,.68),(x+.225,1.86,.8),WOOD,.012)
for z in (.55,1.1,1.55):
    beam('Rack restraining strap',(.15,z,.82),(2.85,z,.82),.045,IRON)
for x in (.4,2.5):
    chain(x,.2,1,2.15)
for i in range(12):
    x,z=random.uniform(.55,2.3),random.uniform(.45,1.55)
    lathe('Dried stain',[(0,0),(random.uniform(.07,.22),0)],(x,z,.807),BLOOD,7)
finish('torture_frame',3)

# Only the iron is damaged; the finished coping mesh and UVs are exactly the regular railing's base.
coping=bpy.data.objects.new('Identical intact gallery coping',RAIL_COPING.copy())
SCENE.collection.objects.link(coping)
PARTS.append(coping)
for x,h,lean in ((.17,1.6,.12),(.49,1.16,-.19),(1.35,.86,.24),(1.84,1.46,-.08)):
    beam('Bent surviving iron bar',(x,.48,.22),(x+lean,.57,h),.065,IRON)
beam('Sheared left handrail',(.05,.5,1.58),(.65,.62,1.32),.08,IRON)
beam('Drooping broken right handrail',(1.06,.71,.91),(1.94,.52,1.45),.08,IRON)
# Retain the cut rail's original boundary so native width fitting leaves the identical coping at unit scale.
box('Sheared rail boundary stub',(0,.44,1.53),(.06,.56,1.60),IRON,.006)
finish('broken_railing',2)

# A narrow bracket and open hexagonal cage keep the warm flame visibly inside an old iron lantern.
LAMP_GLOW=material('Small sheltered lantern flame',(1,.34,.055),emission=2.2)
beam('Slim vertical mounting iron',(.5,.04,0),(.5,.04,2.88),.075,IRON)
for h in (.28,2.55):
    box('Small square wall anchor',(.38,0,h),(.62,.08,h+.16),IRON,.014)
beam('Top lantern bracket',(.05,.03,2.90),(.95,.03,2.90),.06,IRON)
beam('Projecting forged arm',(.5,.02,2.9),(.5,.72,2.9),.065,IRON)
beam('Diagonal bracket brace',(.5,.04,2.35),(.5,.62,2.88),.045,IRON)
chain(.5,.67,2.40,2.84,.19)
lathe('Lantern peaked iron roof',[(.40,2.15),(.41,2.21),(.19,2.41),(.065,2.48),(0,2.53)],(.5,.59,0),IRON,6)
lathe('Lantern antique brass lip',[(.38,2.12),(.40,2.15)],(.5,.59,0),BRASS,6)
lathe('Lantern solid iron floor',[(0,1.22),(.17,1.28),(.37,1.41),(.36,1.46)],(.5,.59,0),IRON,6)
for i in range(6):
    a=math.tau*i/6
    x,z=.5+.31*math.cos(a),.59+.31*math.sin(a)
    beam('Visible cage corner rib',(x,z,1.43),(x,z,2.17),.052,IRON)
for h in (1.48,1.84,2.13):
    lathe('Hexagonal iron cage band',[(.32,h),(.32,h+.038)],(.5,.59,0),IRON,6)
lathe('Lamp wax candle',[(.085,1.45),(.085,1.70)],(.5,.59,0),BONE,12)
lathe('Sheltered flickering flame',[(.055,1.70),(.11,1.79),(.055,1.95),(0,2.02)],(.5,.59,0),LAMP_GLOW,12)
finish('lantern_caged',1)

# These low irregular prisms rest on broad undersides, avoiding upright rectangular flakes.
for i in range(32):
    x,z=random.uniform(.08,2.55),random.uniform(.05,.6)
    w,d,h=random.uniform(.18,.42),random.uniform(.16,.34),random.uniform(.025,.10)
    outline=[(x+.04,z),(x+w*.7,z+.01),(x+w,z+d*.35),
             (x+w*.75,z+d),(x+.03,z+d*.83),(x,z+d*.3)]
    vertices=[world(px,pz,y) for y in (0,h) for px,pz in outline]
    mesh('Low fallen stone chip',vertices,[(5,4,3,2,1,0),(6,7,8,9,10,11)]+
         [(j,(j+1)%6,(j+1)%6+6,j+6) for j in range(6)],STONE,.008)
finish('debris_flat',3)

# Cage and support form one connected assembly, so the native voxel scan unions their contact surfaces.
for reach,pillar_mount in ((2,False),(3,False),(5,False),(2,True)):
    if pillar_mount:
        # The narrow shaft retreats behind its crown; inset the lower anchors and keep upper bolts below the cap.
        box('Narrow shaft anchor strap',(.4,-.32,.15),(1.6,-.20,.31),IRON,0)
        box('Narrow crown anchor strap',(.4,-.08,1.35),(1.6,.01,1.80),IRON,0)
        profile=[(-.32,0),(-.32,.70),(-.08,.70),(-.08,2.3),(.18,2.3),(.18,0)]
        mesh('Stepped pillar spine',[world(x,z,h) for x in (.82,1.18) for z,h in profile],
             [(5,4,3,2,1,0),(6,7,8,9,10,11)]+[(j,(j+1)%6,(j+1)%6+6,j+6) for j in range(6)],IRON,0)
    else:
        box('Two metre masonry anchor strap',(0,0,.15),(2,.09,.31),IRON,0)
        box('Upper masonry anchor strap',(0,0,1.85),(2,.09,2.3),IRON,0)
        box('Forged wall spine',(.82,0,0),(1.18,.18,2.3),IRON,0)
    box('Cantilever oak arm',(.84,.05,2),(1.16,reach+1,2.3),WOOD,0)
    for distance in (.4,reach-.1,reach+.7):
        box('Arm iron binding',(.81,distance,2),(1.19,distance+.12,2.3),IRON,0)
    beam('Triangular load brace',(1,.18,.15),(1,max(.7,reach-1.2),2.01),.14,IRON)
    for x in ((.58,1.42) if pillar_mount else (.18,1.82)):
        for h,depth in (((.22,-.20),(1.52,.01)) if pillar_mount else ((.22,.08),(2.02,.08))):
            lathe('Hammered anchor bolt',[(.055,0),(.055,.06)],(x,depth,h),RUST,8)
    for part in PARTS:
        part.location.z+=7
    cage=bpy.data.objects['hanging_cage'].copy()
    cage.data=cage.data.copy()
    SCENE.collection.objects.link(cage)
    cage.hide_set(False)
    cage.hide_render=False
    cage.location=world(0,reach-1,0)
    PARTS.append(cage)
    if pillar_mount:
        # Bake the existing cage orientation and untouched pillar into one native voxel union, preserving both world poses.
        bpy.context.view_layer.update()
        for part in PARTS:
            posed=[part.matrix_world@v.co for v in part.data.vertices]
            part.matrix_world=Matrix.Identity(4)
            for vert,co in zip(part.data.vertices,posed):
                vert.co=world(3+co.y,co.x,co.z+3)
        pillar=bpy.data.objects['buttress'].copy()
        pillar.data=pillar.data.copy()
        SCENE.collection.objects.link(pillar)
        pillar.hide_set(False)
        pillar.hide_render=False
        pillar.location=world(3,0,0)
        PARTS.append(pillar)
        finish('pillar_cage_suspension',5)
    else:
        finish('cage_suspension_'+str(reach),2)

# The preserved parapet rests on a continuous bearing course and two brackets tapering into the host wall.
box('Parapet bearing course',(0,0,1.62),(2,1,2),STONE,.025,weather=False)
for x0,x1 in ((.10,.65),(1.35,1.90)):
    stone_bracket('Inward outer-wall corbel',x0,x1,[(0,1.62),(1,1.62),(1,0),(.82,0),(.50,.63),(.20,1.14)])
parapet=bpy.data.objects['parapet'].copy()
parapet.data=parapet.data.copy()
SCENE.collection.objects.link(parapet)
parapet.hide_set(False)
parapet.hide_render=False
parapet.location=world(0,0,2)
PARTS.append(parapet)
finish('parapet_supported',2)

# Projecting shaft cells have a closed flagstone floor and corbels connected to the rear wall, not an open drop.
box('Solid prison cell floor and sill',(0,0,1.50),(4,2,2.10),STONE,.025,weather=False)
for x0,x1 in ((.10,.64),(3.36,3.90)):
    stone_bracket('Cell floor masonry corbel',x0,x1,[(0,1.5),(2,1.5),(.20,0),(0,0)])
cell=bpy.data.objects['cell_front'].copy()
cell.data=cell.data.copy()
SCENE.collection.objects.link(cell)
cell.hide_set(False)
cell.hide_render=False
cell.location=world(0,0,2)
PARTS.append(cell)
finish('shaft_cell_floored',4)

for image in bpy.data.images:
    if image.source=='FILE' and not image.packed_file:
        image.pack()
(OUT/'kit.json').write_text(json.dumps(ASSETS,indent=2))
bpy.ops.wm.save_as_mainfile(filepath=str(OUT/'belowward_kit.blend'))
print('BELOWWARD_KIT_COMPLETE '+json.dumps({'assets':len(ASSETS),'triangles':sum(a['triangles'] for a in ASSETS.values())}),flush=True)
