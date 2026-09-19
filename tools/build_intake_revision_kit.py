"""Build sealed intake doors and a docked travelling freight lift in measured metres."""
from pathlib import Path
import bpy, json, math
from mathutils import Matrix, Vector

ROOT=Path(__file__).resolve().parents[1]
source=(ROOT/'tools/build_belowward_kit.py').read_text()
exec(compile(source.split('# Recessed prison cell fronts')[0],str(ROOT/'tools/build_belowward_kit.py'),'exec'))
ART=ROOT/'assets/blackridge_intake_revision'
OUT=ROOT/'exports/blackridge_intake_revision'
ASSETS={}
random.seed(91953)


# Preserve a registered donor's already measured geometry while baking its explicit native pose.
def donor(path, height_scale=1):
    bpy.ops.object.select_all(action='DESELECT')
    bpy.ops.import_scene.gltf(filepath=str(ROOT/path))
    bpy.context.view_layer.update()
    for ob in list(bpy.context.selected_objects):
        if ob.type!='MESH': continue
        for v in ob.data.vertices:
            p=ob.matrix_world@v.co
            p.z*=height_scale
            v.co=p
        ob.matrix_world=Matrix.Identity(4)
        ob.data.update()
        PARTS.append(ob)


# Export without refitting so door leaves and load-bearing contacts preserve their measured dimensions.
def publish(name, grid, driver=0):
    bpy.ops.object.select_all(action='DESELECT')
    for ob in PARTS:
        # Donor glTF meshes call their primary layer UVMap; added geometry must share that exact channel before joining.
        if ob.data.uv_layers.active:
            ob.data.uv_layers.active.name='UVMap'
        ob.hide_set(False);ob.select_set(True)
    bpy.context.view_layer.objects.active=PARTS[0]
    bpy.ops.object.join()
    ob=bpy.context.object
    ob.name='BIR_'+name.upper()
    bpy.ops.object.transform_apply(location=True,rotation=True,scale=True)
    bounds=[Vector(p) for p in ob.bound_box]
    lo=[min(p[k] for p in bounds) for k in range(3)]
    hi=[max(p[k] for p in bounds) for k in range(3)]
    filepath=ART/(name+'.glb')
    bpy.ops.export_scene.gltf(filepath=str(filepath),export_format='GLB',use_selection=True,export_animations=False,export_yup=True)
    ASSETS[name]={'asset_id':ob.name,'path':str(filepath).replace('\\','/'),'grid':grid,'driver_axis':driver,'triangles':sum(len(p.vertices)-2 for p in ob.data.polygons),'bounds_blender':[lo,hi]}
    print('BIR_ASSET '+json.dumps(ASSETS[name]),flush=True)
    PARTS.clear();ob.hide_set(True);ob.hide_render=True;ob.select_set(False)


# Form continuous thick oak leaves with face straps, edge shoes, hinges, bolts and a central lock.
def sealed_leaves(x0,x1,z0,z1,height):
    width=x1-x0
    count=max(6,math.ceil(width/.4))
    for i in range(count):
        a=x0+width*i/count
        b=x0+width*(i+1)/count
        box('Solid oak door plank',(a,z0,0),(b,z1,height),WOOD,.008,False)
    # Both playable sides receive structural ironwork, so rotated arrivals never present an undecorated dark rectangle.
    for face_z,sign in ((z1,1),(z0,-1)):
        def depths(a,b): return sorted((face_z+sign*a,face_z+sign*b))
        for h in (.22,height*.28,height*.62,height-.25):
            d0,d1=depths(0,.045)
            box('Continuous forged binding',(x0,d0,h),(x1,d1,h+.12),CRATE_IRON,.009,False)
            for x in (x0+.12,(x0+x1)/2-.16,(x0+x1)/2+.16,x1-.12):
                d0,d1=depths(.04,.065)
                box('Door iron rivet',(x-.035,d0,h+.025),(x+.035,d1,h+.095),RIVET,.016,False)
        for x in (x0,x1-.10,(x0+x1)/2-.05):
            d0,d1=depths(0,.055)
            box('Rebated leaf iron edge',(x,d0,0),(x+.10,d1,height),IRON,.009,False)
        for x in (x0+.12,x1-.12):
            for h in (.45,height*.53,height-.6):
                d0,d1=depths(-.03,.09)
                box('Hinge knuckle',(x-.10,d0,h),(x+.10,d1,h+.35),IRON,.04,False)
        mid=(x0+x1)/2
        d0,d1=depths(.04,.15)
        box('Central lock housing',(mid-.21,d0,height*.42),(mid+.21,d1,height*.42+.35),CRATE_IRON,.02,False)
        d0,d1=depths(.151,.153)
        box('Key slot',(mid-.025,d0,height*.42+.07),(mid+.025,d1,height*.42+.21),DARK,0,False)


# Build a horizontal cylindrical wheel or drum with an explicit axle direction and circular profile.
def horizontal_wheel(name, centre, radius, thickness, axis, mat, hollow=False):
    x,z,h=centre
    # A narrow axle bore avoids collapsed centre polygons; the separate axle fills this real opening.
    profile=[(radius,-thickness/2),(radius,thickness/2),(.06,thickness/2),(.06,-thickness/2)]
    vs=[]
    n=24
    for r,d in profile:
        for i in range(n):
            a=math.tau*i/n
            if axis=='X': vs.append(world(x+d,z+r*math.cos(a),h+r*math.sin(a)))
            else: vs.append(world(x+r*math.cos(a),z+d,h+r*math.sin(a)))
    faces=[(j*n+i,j*n+(i+1)%n,((j+1)%4)*n+(i+1)%n,((j+1)%4)*n+i) for j in range(4) for i in range(n)]
    return mesh(name,vs,faces,mat,0,False)


# The full-width solid door sits behind the old decorative grate and fills every lower opening.
donor('tile_library/assets/BI_AUTHORITY_GATE/derived/runtime_optimized.glb')
sealed_leaves(1.99,10.01,1.05,1.42,8.75)
publish('authority_door',[12,12,3])

# Close the exterior arrival aperture while leaving the separately placed interior queue arch open.
donor('tile_library/assets/BW_OPEN_GATE_PASSAGE/source/open_gate_passage.glb')
sealed_leaves(.89,3.11,.18,.48,3.32)
publish('arrival_door',[4,4,1])

# The lower access arch keeps its visible masonry and receives a substantial recessed service door.
donor('tile_library/assets/BI_DESCENT_ARCH/source/descent_arch.glb',6/5.5)
sealed_leaves(.94,5.06,.57,.95,5.22)
publish('service_door',[6,6,2])

# The car rests at its docking landing. Its native terrain surface, not this GLB, supplies the floor.
# Local X/Z=1..5 / 5..9 is the four-metre deck; the timber crane travels outward to Z=0.5 over the shaft.
for x in (.30,5.70):
    for z in (5.15,9.65):
        box('Gantry foot plate',(x-.20,z-.22,0),(x+.20,z+.22,.15),CRATE_IRON,.025,False)
        beam('Oak gantry upright',(x,z,.12),(x,z,5.6),.26,WOOD)
        for h in (.24,3.9,5.1):
            box('Upright binding',(x-.15,z-.16,h),(x+.15,z+.16,h+.16),CRATE_IRON,.008,False)
    beam('Travelling hoist runway',(x,.15,5.55),(x,9.9,5.55),.30,WOOD)
    beam('Cantilever diagonal',(x,5.15,2.85),(x,.6,5.4),.18,WOOD)
    beam('Rear knee brace',(x,9.65,3.95),(x,8.2,5.45),.18,WOOD)
    beam('Iron runner track',(x,.15,5.78),(x,9.9,5.78),.09,CRATE_IRON)
for z in (5.15,9.65):
    beam('Gantry transverse tie',(.3,z,5.5),(5.7,z,5.5),.25,WOOD)
beam('Trolley crosshead',(.28,7,5.86),(5.72,7,5.86),.24,IRON)
for x in (.3,5.7):
    for z in (6.7,7.3):
        horizontal_wheel('Trolley flanged roller',(x,z,5.84),.14,.18,'X',RIVET)
# Four sling members terminate at real car corner posts; the south boarding edge stays open.
for x in (1.08,4.92):
    for z in (5.08,8.92):
        box('Car corner shoe',(x-.08,z-.08,0),(x+.08,z+.08,.2),IRON,.01,False)
        beam('Car corner upright',(x,z,.12),(x,z,2.6),.09,IRON)
        beam('Suspension rope',(x,z,2.57),(3,7,5.69),.035,WOOD)
    for h in (.28,1.14,2.60):
        beam('Cage side rail',(x,5.08,h),(x,8.92,h),.075,IRON)
    for z in (5.8,6.6,7.4,8.2):
        beam('Cage side spindle',(x,z,.28),(x,z,1.18),.045,IRON)
for h in (.28,1.14,2.60):
    beam('Cage pit-facing rail',(1.08,5.08,h),(4.92,5.08,h),.075,IRON)
for x in (1.8,2.6,3.4,4.2):
    beam('Pit rail spindle',(x,5.08,.28),(x,5.08,1.18),.045,IRON)
for x in (1.08,4.92):
    beam('Visible dock runner',(x,4.45,.035),(x,9.15,.035),.055,CRATE_IRON)
# Wheel and worm drum sit on the far-right grounded outrigger, visibly roped to the upper tackle.
for z in (8.1,8.9):
    box('Winch trestle',(5.26,z,0),(5.66,z+.2,1.23),WOOD,.02,False)
beam('Winch barrel axle',(5.46,8.02,1.24),(5.46,9.24,1.24),.16,IRON)
horizontal_wheel('Oak winch barrel',(5.46,8.53,1.24),.24,.72,'Z',WOOD)
for z in (8.15,8.9):
    horizontal_wheel('Winch drum flange',(5.46,z,1.24),.35,.10,'Z',IRON)
for i in range(11):
    horizontal_wheel('Wound rope coil',(5.46,8.23+i*.055,1.24),.27,.045,'Z',WOOD,True)
beam('Crank lever',(5.46,9.24,1.24),(5.12,9.24,1.7),.06,IRON)
beam('Crank hand grip',(5.12,9.24,1.7),(5.12,9.47,1.7),.075,WOOD)
beam('Visible lifting haul rope',(5.46,8.53,1.4),(5.46,8.53,5.4),.035,WOOD)
beam('Upper reeved rope',(5.46,8.53,5.4),(3,7,5.69),.035,WOOD)
horizontal_wheel('Overhead haul sheave',(5.46,8.53,5.40),.22,.14,'X',RIVET)
box('Sling equalizer block',(2.84,6.88,5.58),(3.16,7.12,5.88),IRON,.02,False)
# End stops define the exact six-by-ten metre import box without shifting the deck coordinates.
box('Forward iron cross stop',(0,0,5.47),(6,.15,5.65),IRON,.008,False)
box('Rear iron cross stop',(0,9.85,5.47),(6,10,5.65),IRON,.008,False)
publish('docked_freight_hoist',[6,6,10],2)

(OUT/'kit.json').write_text(json.dumps(ASSETS,indent=2))
bpy.ops.wm.save_as_mainfile(filepath=str(ART/'intake_revision_kit.blend'))
