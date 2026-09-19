"""Create intake-specific props in metres using the approved Belowward material family read-only."""
from pathlib import Path
import bpy
import json
import math
import random
from mathutils import Vector

ROOT = Path(__file__).resolve().parents[1]
# Only the geometry helpers and material declarations are reused; no Belowward assets are rebuilt.
source = (ROOT / 'tools/build_belowward_kit.py').read_text(encoding='utf8')
exec(compile(source.split('# Recessed prison cell fronts')[0], str(ROOT / 'tools/build_belowward_kit.py'), 'exec'))
ART = ROOT / 'assets/blackridge_intake'
OUT = ROOT / 'exports/blackridge_intake'
ART.mkdir(parents=True, exist_ok=True)
OUT.mkdir(parents=True, exist_ok=True)
ASSETS = {}
random.seed(9137)
PARCHMENT = material('Yellowed institutional parchment', (.46,.37,.24), rough=.95)
LETTER = material('Faded ivory lettering', (.5,.46,.36), rough=.9)
LEATHER = material('Oxblood ledger leather', (.12,.035,.025), rough=.83)
BANNER = material('Blackridge authority cloth', (.2,.03,.025), ART/'authority_banner.png')
if (ART/'authority_banner_chord/albedo.png').exists():
    BANNER = material('CHORD Blackridge authority cloth', (.2,.03,.025), ART/'authority_banner_chord/albedo.png')


# Bake source transforms and fit only this new asset to its declared physical metre box.
def publish(name, dimensions):
    bpy.ops.object.select_all(action='DESELECT')
    for part in PARTS:
        part.hide_set(False)
        part.select_set(True)
    bpy.context.view_layer.objects.active=PARTS[0]
    bpy.ops.object.join()
    ob=bpy.context.object
    ob.name='BI_'+name.upper()
    bpy.ops.object.transform_apply(location=True,rotation=True,scale=True)
    points=[Vector(p) for p in ob.bound_box]
    lo=Vector([min(p[k] for p in points) for k in range(3)])
    hi=Vector([max(p[k] for p in points) for k in range(3)])
    dx,dh,dz=dimensions
    grid=[math.ceil(dx),math.ceil(dh),math.ceil(dz)]
    fac=Vector((dx/(hi.x-lo.x),dz/(hi.y-lo.y),dh/(hi.z-lo.z)))
    shift=Vector(((grid[0]-dx)/2-lo.x*fac.x,-(grid[2]-dz)/2-hi.y*fac.y,-lo.z*fac.z))
    for v in ob.data.vertices:
        v.co=v.co*fac+shift
    ob.data.update()
    path=ART/(name+'.glb')
    bpy.ops.export_scene.gltf(filepath=str(path),export_format='GLB',use_selection=True,export_animations=False,export_yup=True)
    ASSETS[name]={'path':str(path).replace('\\','/'),'export_name':name,'asset_id':'BI_'+name.upper(),'grid':grid,'driver_axis':0,'physical_dimensions':dimensions,'triangles':sum(len(p.vertices)-2 for p in ob.data.polygons)}
    PARTS.clear()
    ob.hide_set(True)
    ob.hide_render=True
    ob.select_set(False)
    print('ASSET_READY '+json.dumps(ASSETS[name]),flush=True)


# Model small raised paint lettering facing the playable interior, keeping labels inside the host face.
def inscription(text, x, z, h, size, width=None):
    cu=bpy.data.curves.new('Painted institutional inscription','FONT')
    cu.body=text
    cu.align_x='CENTER'
    cu.align_y='CENTER'
    cu.size=size
    cu.extrude=.002
    cu.bevel_depth=.001
    ob=bpy.data.objects.new('Inscription '+text,cu)
    SCENE.collection.objects.link(ob)
    ob.location=world(x,z,h)
    ob.rotation_euler=(math.pi/2,0,0)
    cu.materials.append(LETTER)
    bpy.context.view_layer.objects.active=ob
    ob.select_set(True)
    bpy.ops.object.convert(target='MESH')
    ob=bpy.context.object
    if width and ob.dimensions.x>width:
        ob.scale*=width/ob.dimensions.x
    PARTS.append(ob)
    ob.select_set(False)


# Build a semicircular arch of individually jointed voussoirs rather than a rectangular lintel.
def arch_ring(cx,z0,z1,spring,radius,thickness,segments):
    for i in range(segments):
        a=math.pi*i/segments+.009
        b=math.pi*(i+1)/segments-.009
        ring=[(cx+r*math.cos(t),spring+r*math.sin(t)) for r,t in ((radius,a),(radius,b),(radius+thickness,b),(radius+thickness,a))]
        vs=[world(x,z,h) for z in (z0,z1) for x,h in ring]
        mesh('Jointed arch stone',vs,[(0,3,2,1),(4,5,6,7),(0,1,5,4),(1,2,6,5),(2,3,7,6),(3,0,4,7)],CAP,.035,False)


# The gate is the hall's main landmark: doubled piers, recessed bars, voussoirs and an authority plaque.
for x in (0,10):
    masonry(x,0,2,2.1,10)
    box('Gate pier foot',(x,0,0),(x+2,2.5,.6),CAP,.04)
    box('Gate pier capital',(x,0,9.3),(x+2,2.5,10),CAP,.05)
    for h in (2.6,5.8,8.5):
        box('Pier binding band',(x-.015,0,h),(x+2.015,2.12,h+.22),CAP,.025)
box('Gate rear top',(2,0,8.5),(10,.4,11.6),STONE,.04)
arch_ring(6,.4,2.2,4.5,3.5,.72,17)
for x in [2.65+i*.32 for i in range(22)]:
    top=4.5+math.sqrt(max(0,3.38**2-(x-6)**2))
    beam('Portcullis vertical',(x,1.45,.1),(x,1.45,top),.095,IRON)
for h in (.45,1.85,3.35,4.5):
    box('Portcullis cross strap',(2.55,1.39,h),(9.45,1.52,h+.14),IRON)
box('Authority plaque',(2.2,.35,8.6),(9.8,.72,11.6),DARK,.04)
inscription('ALL\nSERVE\nBLACKRIDGE',6,.745,10.05,.72,6.7)
box('Crowning cornice',(0,0,11.6),(12,2.2,11.85),CAP,.04)
for i in range(16):
    box('Crown stones',(i*.75+.015,0,11.85),((i+1)*.75-.015,2.2,12.2),CAP,.035)
publish('authority_gate',(12,12,3))

# A smaller open threshold is the repeated travel motif with three clear central cells.
for x in (0,5):
    masonry(x,0,1,2,4.2)
    box('Door jamb foot',(x,0,0),(x+1,2,.3),CAP,.02)
arch_ring(3,0,1.9,2.7,2.05,.6,13)
box('Arch top cornice',(0,.05,5.1),(6,1.9,5.45),CAP,.04)
inscription('BELOWWARD',3,1.95,5.2,.32,3.6)
publish('descent_arch',(6,5.5,2))

# Hanging cloth uses its own full-sheet UVs and attaches physically to a crossbar and wall plates.
v=[]
cols,rows=12,22
for j in range(rows+1):
    for i in range(cols+1):
        x=.22+2.56*i/cols
        h=.15+6.85*j/rows
        z=.55+.09*math.sin(i*.72)+.025*math.sin(j*.47+i*.23)
        v.append(world(x,z,h))
faces=[]
for j in range(rows):
    for i in range(cols):
        a=j*(cols+1)+i
        faces.append((a,a+1,a+cols+2,a+cols+1))
ob=mesh('Worn authority banner',v,faces,BANNER)
for poly in ob.data.polygons:
    for li in poly.loop_indices:
        vid=ob.data.loops[li].vertex_index
        ob.data.uv_layers.active.data[li].uv=((vid%(cols+1))/cols,(vid//(cols+1))/rows)
sol=ob.modifiers.new('Two-sided cloth thickness','SOLIDIFY')
sol.thickness=.012
bpy.context.view_layer.objects.active=ob
bpy.ops.object.modifier_apply(modifier=sol.name)
beam('Banner crossbar',(.08,.45,7.1),(2.92,.45,7.1),.10,IRON)
for x in (.3,2.7):
    box('Wall fixing plate',(x-.12,.02,6.9),(x+.12,.18,7.35),IRON,.015)
    beam('Banner wall arm',(x,.1,7.1),(x,.5,7.1),.09,IRON)
publish('authority_banner',(3,7.4,1))

# Records are bound books with paper edges, split boards and purposeful institutional order.
box('Archive back',(0,0,.1),(3,.12,3),WOOD,.018)
for x in (0,2.84):
    box('Archive side',(x,0,0),(x+.16,.85,3),WOOD,.02)
for h in (.15,.85,1.55,2.25,2.9):
    box('Archive shelf',(0,0,h),(3,.9,h+.10),WOOD,.015)
for row in range(4):
    x=.22
    while x<2.68:
        w=random.uniform(.12,.25)
        h=random.uniform(.40,.55)
        y=.25+.7*row
        box('Ledger paper',(x+.025,.23,y+.025),(x+w-.025,.65,y+h-.025),PARCHMENT,.002)
        for a in (x,x+w-.025):
            box('Leather ledger cover',(a,.18,y),(a+.025,.70,y+h),LEATHER,.006)
        box('Ledger spine',(x,.65,y),(x+w,.70,y+h),LEATHER,.012)
        for k in (.12,.32):
            box('Ledger spine ribs',(x,.69,y+k),(x+w,.72,y+k+.022),BRASS,.002)
        x+=w+.055
publish('records_shelf',(3,3,1))

# Intake barriers have a central opening and joined end posts, forming real lanes rather than isolated fences.
for x in (.12,5.88):
    beam('Holding post',(x,.5,0),(x,.5,2.8),.16,IRON)
    box('Holding post foot',(x-.12,.27,0),(x+.12,.73,.18),IRON,.02)
for lo,hi in ((.15,1.65),(4.35,5.85)):
    for h in (.25,1.15,2.3):
        beam('Holding bay rail',(lo,.5,h),(hi,.5,h),.085,IRON)
    for i in range(6):
        x=lo+(hi-lo)*i/5
        beam('Holding bay bar',(x,.5,.25),(x,.5,2.45),.06,IRON)
beam('Holding door header',(.12,.5,2.8),(5.88,.5,2.8),.12,IRON)
publish('holding_gate',(6,3,1))

# Long worn benches and luggage carts group near registration while preserving open movement lanes.
for x in (.2,2.65):
    for z in (.18,.65):
        box('Bench leg',(x,z,0),(x+.15,z+.15,.48),WOOD,.015)
for z in (.12,.39,.66):
    box('Bench seat board',(0,z,.45),(3,z+.22,.58),WOOD,.02)
for x in (.2,2.65):
    beam('Bench rear upright',(x,.82,.2),(x,.82,1.2),.13,WOOD)
for h in (.83,1.08):
    box('Bench back plank',(0,.76,h),(3,.88,h+.18),WOOD,.02)
publish('holding_bench',(3,1.3,1))

# A low open cart carries confiscated clothes and bags without introducing another sculpted centerpiece.
box('Cart planked bed',(0,.1,.3),(3,1.7,.5),WOOD,.025)
for z in (.15,1.62):
    for h in (.5,.85):
        beam('Cart side rail',(.1,z,h),(2.9,z,h),.08,IRON)
    for x in (.1,1.5,2.9):
        beam('Cart stanchion',(x,z,.3),(x,z,1.1),.07,IRON)
for x in (.4,2.6):
    for z in (0,1.8):
        wheel=[world(x+r*math.cos(i*math.tau/16),z+d,.28+r*math.sin(i*math.tau/16)) for r,d in ((.28,-.05),(.28,.05),(.08,.05),(.08,-.05)) for i in range(16)]
        wheel_faces=[(j*16+i,j*16+(i+1)%16,((j+1)%4)*16+(i+1)%16,((j+1)%4)*16+i) for j in range(4) for i in range(16)]
        mesh('Cart iron wheel',wheel,wheel_faces,IRON)
for x,z in ((.3,.4),(1.3,.7),(2.1,.35)):
    box('Confiscated trunk',(x,z,.5),(x+.65,z+.75,1.05),LEATHER,.06)
    for sx in (x+.1,x+.5):
        box('Trunk strap',(sx,z-.01,.52),(sx+.07,z+.76,1.07),IRON,.006)
publish('property_cart',(3,1.2,2))

# Numbered bays inherit the approved finished cell mesh before adding their own flush number plaque.
for number in ('A1','A2','B1'):
    bpy.ops.object.select_all(action='DESELECT')
    bpy.ops.import_scene.gltf(filepath=str(ROOT/'assets/belowward_cell/cell_front_worn.glb'))
    imported=[o for o in bpy.context.selected_objects if o.type=='MESH']
    PARTS.extend(imported)
    box('Numbered bay plaque',(1.15,1.97,3.96),(2.85,2.015,4.38),DARK,.008)
    inscription(number,2,2.028,4.16,.30,1.4)
    publish('cell_'+number.lower(),(4,5,2))

(OUT/'kit.json').write_text(json.dumps(ASSETS,indent=2),encoding='utf8')
bpy.ops.wm.save_as_mainfile(filepath=str(OUT/'blackridge_intake_kit.blend'))
print('INTAKE_KIT_COMPLETE '+str(len(ASSETS)),flush=True)
