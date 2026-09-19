"""Author the quarantined city approach kit; the native board owns placement and terrain."""
from pathlib import Path
import bpy
import math
import random
import json
import bmesh
from mathutils import Matrix, Vector

ROOT = Path(__file__).resolve().parents[1]
ART = ROOT / 'assets/belowward_cell'
BQART = ROOT / 'assets/blackridge_quarantine'
OUT = ROOT / 'exports/blackridge_quarantine'
OUT.mkdir(parents=True, exist_ok=True)
(OUT / '.gdignore').touch()
random.seed(19833)
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


# Export a measured canonical source box without moving its deliberately open passage.
def finish(name, dimensions):
    bpy.ops.object.select_all(action='DESELECT')
    for ob in PARTS:
        ob.select_set(True)
    bpy.context.view_layer.objects.active=PARTS[0]
    bpy.ops.object.join()
    ob=bpy.context.object
    ob.name=name
    bpy.ops.object.transform_apply(location=True,rotation=True,scale=True)
    pts=[Vector(v) for v in ob.bound_box]
    lo=Vector([min(p[k] for p in pts) for k in range(3)])
    hi=Vector([max(p[k] for p in pts) for k in range(3)])
    dx,dh,dz=dimensions
    factor=Vector((dx/(hi.x-lo.x),dz/(hi.y-lo.y),dh/(hi.z-lo.z)))
    for vert in ob.data.vertices:
        vert.co=(vert.co-Vector((lo.x,hi.y,lo.z)))*factor
    ob.data.update()
    path=BQART/(name+'.glb')
    bpy.ops.export_scene.gltf(filepath=str(path),export_format='GLB',use_selection=True,export_animations=False,export_yup=True)
    ASSETS[name]={'path':str(path).replace('\\','/'),'asset_id':'BQ_'+name.upper(),'export_name':name,
      'grid':[math.ceil(dx),math.ceil(dh),math.ceil(dz)],'physical_size':[dx,dh,dz],
      'driver_axis':0,'triangles':sum(len(p.vertices)-2 for p in ob.data.polygons)}
    ob.hide_set(True)
    ob.hide_render=True
    ob.select_set(False)
    PARTS.clear()
    print('ASSET_READY '+json.dumps(ASSETS[name]),flush=True)


# Dressed wall faces use the approved Belowward texture at identical metre-scale UVs.
def masonry(x,z,w,d,h,base=0):
    box('Mortar mass',(x+.03,z+.03,base),(x+w-.03,z+d-.03,base+h-.02),STONE,.02)
    rows=math.ceil(h/.45)
    for row in range(rows):
        h0=base+row*.45
        h1=min(base+h,h0+.45)-.022
        cuts=[0,w]
        a=.38 if row%2 else .75
        while a<w:
            cuts.append(a)
            a+=random.uniform(.60,1.0)
        cuts.sort()
        for a,b in zip(cuts[:-1],cuts[1:]):
            box('Weathered ashlar face',(x+a+.012,z+d-.11,h0+.012),(x+b-.012,z+d,h1),STONE,.02)


# The eye and stem repeat the institutional symbol without baking illegible text into surfaces.
def sigil(x,z,h,r=.4):
    for i in range(24):
        a,b=math.tau*i/24,math.tau*(i+1)/24
        beam('Pale eye seal',(x+r*math.cos(a),z,h+r*math.sin(a)),(x+r*math.cos(b),z,h+r*math.sin(b)),.022,BONE)
    beam('Seal vertical stem',(x,z,h-r*1.6),(x,z,h+r*1.55),.022,BONE)
    for sign in (-1,1):
        for i in range(12):
            a,b=math.pi*i/12,math.pi*(i+1)/12
            beam('Institutional eye',(x+r*.78*math.cos(a),z,h+sign*r*.32*math.sin(a)),(x+r*.78*math.cos(b),z,h+sign*r*.32*math.sin(b)),.020,BONE)


# Banners hang from connected rods, with mild cloth sag and an intentionally restrained red field.
def banner(x,z,h,w=1.6,length=4.8):
    beam('Banner support rod',(x-.10,z,h),(x+w+.10,z,h),.06,IRON)
    vertices=[]
    for row in range(9):
        for col in range(5):
            u,v=col/4,row/8
            vertices.append(world(x+w*u,z+.05+.055*math.sin(u*math.pi*4)*(v+.25),h-v*length+.14*math.sin(u*math.pi)))
    faces=[(r*5+c,r*5+c+1,(r+1)*5+c+1,(r+1)*5+c) for r in range(8) for c in range(4)]
    mesh('Weathered oxblood cloth',vertices,faces,BANNER)
    sigil(x+w*.5,z+.15,h-length*.38,min(w*.24,.42))


# Slate uses the new generated texture and its actual CHORD channels; glass remains real translucent geometry.
ROOF=material('BQ rain-worn blue slate',(.15,.18,.21),BQART/'slate_roof_chord/albedo.png')
BANNER=material('BQ muted oxblood canvas',(.20,.018,.027),rough=.94)
GLASS=material('BQ dirty quarantine glass',(.17,.31,.28),metallic=.05,rough=.27)
gp=GLASS.node_tree.nodes.get('Principled BSDF')
gp.inputs['Alpha'].default_value=.28
GLASS.diffuse_color=(.17,.31,.28,.28)
GLASS.surface_render_method='DITHERED'
MISTGLASS=material('BQ pale contaminated glass grime',(.13,.27,.22),rough=.8,emission=.24)
WINDOW=material('BQ distant city window',(.64,.27,.07),emission=1.2)


# The prison gate is a load-bearing arch with a raised grille and a genuinely open four-metre passage.
for x in (0,12):
    masonry(x,0,4,3,12)
    box('Tower crown',(x,0,11.8),(x+4,3,12.4),CAP,.045)
    for i in range(4):
        box('Crenellated crown',(x+i+.1,.1,12.4),(x+i+.85,2.9,13.4),STONE,.045)
    banner(x+1.15,3.10,10.8,w=1.7,length=5.6)
for x in (4,10):
    masonry(x,0,2,2.5,6.4)
for i in range(18):
    a,b=math.pi*i/18+.012,math.pi*(i+1)/18-.012
    verts=[world(8+r*math.cos(t),z,6.35+r*math.sin(t)) for z in (0,2.55) for r,t in ((2,a),(2,b),(3,b),(3,a))]
    mesh('Radial arch voussoir',verts,[(0,1,2,3),(4,7,6,5),(0,4,5,1),(1,5,6,2),(2,6,7,3),(3,7,4,0)],STONE,.025)
masonry(4,0,8,2.5,2.8,base=9.3)
box('Central entablature',(3.8,0,12),(12.2,2.7,12.55),CAP,.045)
for x in [6.1+i*.23 for i in range(17)]:
    beam('Raised portcullis',(x,1.45,6),(x,1.45,10.3),.07,IRON)
for h in (6.25,7.25,8.3,9.3,10.15):
    box('Portcullis tie',(6.0,1.39,h),(10,1.52,h+.08),IRON)
box('Gate name tablet',(5.6,2.54,10.0),(10.4,2.66,11.7),DARK,.025)
sigil(8,2.69,10.9,.59)
for x in (3.6,12.1):
    box('Gate buttress foot',(x,2.5,0),(x+.3,3.6,1),CAP,.03)
    beam('Gate lamp bracket',(x+.15,2.55,4.2),(x+.15,3.5,4.8),.08,IRON)
finish('prison_gate',(16,13.4,4))


# Each wall wing ends in the same ashlar courses and carries a low iron sentry parapet.
masonry(0,0,6,2,9.8)
box('Wing coping',(0,0,9.65),(6,2,10.05),CAP,.04)
for x in [i*.42+.08 for i in range(15)]:
    beam('Wing rail',(x,1.55,10),(x,1.55,11.05),.05,IRON)
for h in (10.3,10.9):
    beam('Wing top rail',(0,1.55,h),(6,1.55,h),.065,IRON)
for x in (.3,5.1):
    masonry(x,1.75,.6,1,10.0)
banner(2.15,2.05,8.8,w=1.7,length=5.6)
finish('prison_wall_wing',(6,11.1,3))


# Glass pens have a solid perimeter sill, real transparent panes and tied gable frames; the interior uses native terrain.
for x in (.0,4.8):
    box('Pen stone sill',(x,0,0),(x+.2,9,.32),STONE,.02)
for z in (0,8.8):
    box('Pen end sill',(0,z,0),(5,z+.2,.32),STONE,.02)
for z in [i*1.5 for i in range(7)]:
    for x in (.12,4.88):
        beam('Pen upright',(x,z,.2),(x,z,3.2),.10,IRON)
        beam('Roof rib',(x,z,3.2),(2.5,z,4.65),.09,IRON)
    beam('Roof cross tie',(.12,z,3.2),(4.88,z,3.2),.07,IRON)
for x in (.12,4.88):
    for h in (.6,1.65,3.15):
        beam('Pen longitudinal rail',(x,0,h),(x,9,h),.065,IRON)
    for i in range(6):
        z0,z1=i*1.5+.08,(i+1)*1.5-.08
        mesh('Dirty glass wall',[world(x,z0,.40),world(x,z1,.40),world(x,z1,3.12),world(x,z0,3.12)],[(0,1,2,3)],GLASS)
        mesh('Dirty glass roof',[world(x,z0,3.18),world(x,z1,3.18),world(2.5,z1,4.62),world(2.5,z0,4.62)],[(0,1,2,3)],GLASS)
        for stripe in range(3):
            z=z0+.22+stripe*.35
            hh=random.uniform(.35,1.30)
            beam('Faint glass runoff',(x-.009 if x>2 else x+.009,z,.38),(x-.009 if x>2 else x+.009,z,.38+hh),.019,MISTGLASS)
beam('Roof ridge',(2.5,0,4.65),(2.5,9,4.65),.10,IRON)
for z in (.02,8.98):
    mesh('End glazing',[world(.2,z,.32),world(4.8,z,.32),world(4.8,z,3.2),world(2.5,z,4.65),world(.2,z,3.2)],[(0,1,2,3,4)],GLASS)
    for x in (1.6,3.4):
        beam('Pen door stile',(x,z,.3),(x,z,3.2),.06,IRON)
    for h in (1.05,2.3):
        beam('Pen gate strap',(1.6,z,h),(3.4,z,h),.05,IRON)
banner(.4,9.02,3.1,w=.85,length=2.4)
finish('glass_quarantine_pen',(5,4.7,9))

# This local damaged variant retains the intact sill and roof while exposing a forced-open end.
damaged = bpy.data.objects['glass_quarantine_pen'].copy()
damaged.data = damaged.data.copy()
SCENE.collection.objects.link(damaged)
damaged.hide_set(False)
damaged.hide_render = False
bm = bmesh.new()
bm.from_mesh(damaged.data)
remove = []
for face in bm.faces:
    centre = face.calc_center_median()
    name = damaged.data.materials[face.material_index].name
    if centre.y < -8.80 and name == GLASS.name:
        remove.append(face)
    elif centre.y < -8.80 and 1.45 < centre.x < 3.55 and .70 < centre.z < 2.65 and name == IRON.name:
        remove.append(face)
bmesh.ops.delete(bm, geom=remove, context='FACES')
bm.to_mesh(damaged.data)
bm.free()
PARTS.append(damaged)
beam('Forced gate strap',(1.6,8.92,1.05),(2.3,8.6,.38),.07,IRON)
beam('Bent gate strap',(3.4,8.92,2.3),(2.95,8.55,1.85),.07,IRON)
for i in range(12):
    x=1.5+random.random()*2
    z=8.0+random.random()*.8
    mesh('Resting broken glass',[world(x,z,.025),world(x+.12,z+.08,.025),world(x+.04,z+.27,.025)],[(0,1,2)],GLASS)
finish('glass_quarantine_pen_breached',(5,4.7,9))


# A city tenement shows plaster, framed windows, gutters, chimneys and an actual slate gable roof.
masonry(.2,.2,5.6,4.6,5.8)
box('Storey belt',(.1,.15,2.8),(5.9,4.9,3.02),WOOD,.02)
for x in (.28,2.85,5.55):
    box('Vertical timber',(x,.16,0),(x+.17,4.92,5.9),WOOD,.018)
for x in (.9,3.85):
    for h in (1.2,3.7):
        box('Window recess',(x,4.81,h),(x+1.15,4.90,h+1.5),DARK,.012)
        box('Dim city glazing',(x+.1,4.91,h+.1),(x+1.05,4.92,h+1.4),WINDOW,.002)
        for xx in (x,x+.54,x+1.09):
            box('Window mullion',(xx,4.92,h),(xx+.06,4.99,h+1.5),WOOD,.005)
        box('Window cross rail',(x,4.93,h+.75),(x+1.15,5,h+.83),WOOD,.005)
        box('Projecting window sill',(x-.10,4.88,h-.1),(x+1.25,5.05,h+.04),CAP,.018)
mesh('Slate roof left',[world(0,0,5.75),world(0,5,5.75),world(3,5,8.8),world(3,0,8.8)],[(0,1,2,3)],ROOF)
mesh('Slate roof right',[world(3,0,8.8),world(3,5,8.8),world(6,5,5.75),world(6,0,5.75)],[(0,1,2,3)],ROOF)
for z in (.1,4.9):
    mesh('Stone gable',[world(.2,z,5.7),world(5.8,z,5.7),world(3,z,8.6)],[(0,1,2)],STONE)
    beam('Gable bargeboard',(.02,z,5.8),(3,z,8.83),.1,WOOD)
    beam('Gable bargeboard',(3,z,8.83),(5.98,z,5.8),.1,WOOD)
for x in (.05,5.95):
    beam('Iron gutter',(x,0,5.73),(x,5,5.73),.12,IRON)
masonry(4,1.2,.9,1,3.0,base=6.4)
box('Chimney cap',(3.9,1.1,9.3),(5,2.3,9.55),CAP,.025)
finish('city_tenement',(6,9.6,6))


# Quarantine barricades have feet and diagonal braces, with strapped boards rather than unsupported fence fragments.
for x in (.28,2.72):
    for z in (.12,1.38):
        beam('Splayed barricade foot',(x,z,0),(x,.75,1.6),.15,WOOD)
    beam('Barricade peg',(x,.75,.3),(x,.75,2.05),.13,WOOD)
for h in (.55,1.22):
    box('Strapped barricade plank',(.05,.63,h),(2.95,.86,h+.23),WOOD,.025)
    for x in (.24,2.69):
        box('Iron binding',(x,.61,h-.025),(x+.095,.88,h+.26),IRON,.007)
beam('Barricade diagonal',(.25,.9,.5),(2.8,.9,1.7),.1,WOOD)
finish('quarantine_barricade',(3,2.1,2))


# The small registration kiosk is a contextual checkpoint with overhanging slate and a connected service counter.
for x in (.1,2.7):
    for z in (.2,2.7):
        box('Kiosk timber post',(x,z,0),(x+.18,z+.18,2.75),WOOD,.02)
box('Kiosk back',(0,.05,0),(3,.16,2.75),WOOD,.015)
for x in (.02,2.83):
    box('Kiosk side',(x,.1,0),(x+.15,2.85,1.4),WOOD,.015)
box('Service counter',(.1,2.2,1.18),(2.9,3,1.36),WOOD,.025)
mesh('Kiosk roof front',[world(0,3,2.55),world(3,3,2.55),world(3,1.5,3.45),world(0,1.5,3.45)],[(0,1,2,3)],ROOF)
mesh('Kiosk roof rear',[world(0,1.5,3.45),world(3,1.5,3.45),world(3,0,2.55),world(0,0,2.55)],[(0,1,2,3)],ROOF)
box('Kiosk folio',(.4,2.4,1.36),(1.1,2.85,1.43),BONE,.008)
banner(.7,.18,2.6,w=1.6,length=2.3)
finish('registry_kiosk',(3,3.5,3))


# Free banners have a weighted plinth and twin uprights so every support lands inside its asset footprint.
box('Banner stone foot',(0,.08,0),(2,.9,.24),CAP,.035)
for x in (.1,1.9):
    beam('Banner iron post',(x,.5,.2),(x,.5,4.8),.08,IRON)
banner(.2,.55,4.55,w=1.6,length=3.8)
finish('quarantine_standard',(2,4.8,1))


# Save the editable source scene and exact per-asset grid records used by native import.
(OUT/'kit.json').write_text(json.dumps(ASSETS,indent=2))
bpy.ops.wm.save_as_mainfile(filepath=str(OUT/'quarantine_kit.blend'))
print('BQ_KIT_COMPLETE '+str(sum(a['triangles'] for a in ASSETS.values())),flush=True)


