"""Build the revised quarantine's distinct city rows and occupied prison facade."""
from pathlib import Path
import json
import math
import random
import bpy
import bmesh
from mathutils import Vector, Matrix

ROOT = Path(__file__).resolve().parents[1]
recipe_path = ROOT / 'tools/build_blackridge_quarantine_kit.py'
exec(compile(recipe_path.read_text().split('# The prison gate is a load-bearing arch')[0], str(recipe_path), 'exec'))
BQART = ROOT / 'assets/blackridge_quarantine_revision'
OUT = ROOT / 'exports/blackridge_quarantine_revision'
ASSETS = {}
random.seed(9411)
STONE = material('BQR weathered urban umber brick',(.24,.20,.17),BQART/'exterior_brick_chord/albedo.png')
CAP = material('BQR rain-polished pale city stone',(.29,.28,.25),BQART/'lime_plaster_chord/albedo.png')
PLASTER = material('BQR soot-stained lime plaster',(.40,.37,.30),BQART/'lime_plaster_chord/albedo.png')
ROOF = material('BQR rain-worn blue slate',(.15,.18,.21),ROOT/'assets/blackridge_quarantine/slate_roof_chord/albedo.png')
BANNER = material('BQR oxblood institutional canvas',(.17,.024,.026),rough=.94)
WINDOW = material('BQR few lit tenement windows',(.42,.20,.065),emission=.45)
GLASSDARK = material('BQR unlit barred windows',(.023,.034,.035),rough=.35)
LETTER = material('BQR aged ivory lettering',(.49,.43,.30),rough=.94)


# Export literal metre geometry and derive the grid from its actual bounds without fitting it again.
def finish_literal(name):
    bpy.ops.object.select_all(action='DESELECT')
    for ob in PARTS:
        ob.hide_set(False)
        ob.select_set(True)
    bpy.context.view_layer.objects.active=PARTS[0]
    bpy.ops.object.join()
    ob=bpy.context.object
    bpy.ops.object.transform_apply(location=True,rotation=True,scale=True)
    if name.startswith('tenement_row_'):
        # Row boundary planes remain exact so gutters and bargeboards never escape the authored six-metre lot.
        for vert in ob.data.vertices:
            vert.co.x=max(0,min(6,vert.co.x))
            vert.co.y=max(-36,min(0,vert.co.y))
    bm=bmesh.new(); bm.from_mesh(ob.data)
    bmesh.ops.recalc_face_normals(bm,faces=list(bm.faces))
    bm.to_mesh(ob.data); bm.free()
    # Twelve brick courses cover two metres; exterior brickwork is visibly finer than Belowward's giant ashlar.
    if ob.data.uv_layers.active:
        for face in ob.data.polygons:
            if ob.data.materials[face.material_index] == STONE:
                for li in face.loop_indices:
                    ob.data.uv_layers.active.data[li].uv *= 2.0
    pts=[v.co for v in ob.data.vertices]
    lo=Vector([min(p[k] for p in pts) for k in range(3)])
    hi=Vector([max(p[k] for p in pts) for k in range(3)])
    # The authored local world origin is retained explicitly as part of the source recipe.
    physical=[hi.x-lo.x,hi.z-lo.z,hi.y-lo.y]
    ob.name=name
    bpy.ops.export_scene.gltf(filepath=str(BQART/(name+'.glb')),export_format='GLB',use_selection=True,export_animations=False,export_yup=True)
    ASSETS[name]={'asset_id':'BQR_'+name.upper(),'path':str(BQART/(name+'.glb')).replace('\\','/'),
        'grid':[math.ceil(v-.0001) for v in physical],'physical_size':physical,
        'source_min':[lo.x,lo.z,-hi.y], 'triangles':sum(len(p.vertices)-2 for p in ob.data.polygons),
        'literal_pose':True}
    ob.hide_set(True); ob.hide_render=True; ob.select_set(False)
    PARTS.clear()
    print('BQR_ASSET '+json.dumps(ASSETS[name]),flush=True)


# Convert text to retained mesh lettering on a solid surface with a measured small projection.
def text_front(message,x,z,h,size=.30):
    curve=bpy.data.curves.new('Legible institutional lettering','FONT')
    curve.body=message; curve.size=size; curve.align_x='CENTER'
    curve.extrude=.0008; curve.resolution_u=2
    ob=bpy.data.objects.new(message,curve); SCENE.collection.objects.link(ob)
    ob.location=world(x,z,h); ob.rotation_euler=(math.pi/2,0,0)
    curve.materials.append(LETTER)
    bpy.ops.object.select_all(action='DESELECT')
    ob.select_set(True); bpy.context.view_layer.objects.active=ob
    bpy.ops.object.convert(target='MESH'); PARTS.append(bpy.context.object)
    ob.select_set(False)


# Carve window depth visually with opaque dark glass, thick frames and a projecting stone sill.
def window_front(x,z,h,w=1.1,hh=1.5,lit=False,bars=False,boarded=False):
    box('Deep window recess',(x,z-.045,h),(x+w,z+.045,h+hh),DARK,.008,False)
    box('Opaque window pane',(x+.09,z+.05,h+.09),(x+w-.09,z+.055,h+hh-.09),WINDOW if lit else GLASSDARK,0,False)
    frame=IRON if bars else WOOD
    for xx in (x,x+w-.08):
        box('Window jamb',(xx,z+.055,h),(xx+.08,z+.13,h+hh),frame,.009,False)
    for yy in (h,h+hh-.08):
        box('Window head and sill',(x,z+.055,yy),(x+w,z+.13,yy+.08),frame,.009,False)
    for xx in ([x+w*i/5 for i in range(1,5)] if bars else [x+w*.5]):
        beam('Window vertical iron' if bars else 'Window mullion',(xx,z+.145,h+.08),(xx,z+.145,h+hh-.08),.045,frame)
    beam('Window horizontal tie',(x+.04,z+.15,h+hh*.53),(x+w-.04,z+.15,h+hh*.53),.048,frame)
    box('Projecting sill',(x-.12,z-.02,h-.13),(x+w+.12,z+.26,h-.025),CAP,.014,False)
    if boarded:
        for i in range(2):
            beam('Hastily nailed window board',(x-.06,z+.19,h+.25+i*.7),(x+w+.06,z+.20,h+.50+i*.7),.18,WOOD)


# Each banner is visibly fixed to a rod and wall and spells a fictional Glasshouse message.
def propaganda(x,z,top,w,length,lines):
    beam('Banner wall rod',(x-.13,z,top),(x+w+.13,z,top),.065,IRON)
    for xx in (x-.10,x+w+.1):
        beam('Banner wall anchor',(xx,z-.25,top),(xx,z+.02,top),.08,IRON)
    vs=[]
    for r in range(13):
        for c in range(9):
            u,v=c/8,r/12
            vs.append(world(x+w*u,z+.06+.020*math.sin(u*math.pi*6)*v,top-length*v+.06*math.sin(u*math.pi)))
    mesh('Heavy weathered propaganda cloth',vs,[(r*9+c,r*9+c+1,(r+1)*9+c+1,(r+1)*9+c) for r in range(12) for c in range(8)],BANNER)
    sigil(x+w*.5,z+.13,top-length*.26,min(.40,w*.22))
    for i,line in enumerate(lines):
        text_front(line,x+w*.5,z+.135,top-length*.48-i*.40,min(.29,w/max(len(line),1)*1.62))
    for xx in (x+.09,x+w-.09):
        beam('Stitched banner border',(xx,z+.12,top-.16),(xx,z+.12,top-length+.1),.018,LETTER)


# Bake all just-created house geometry before turning its front toward the central street.
def orient_house(start,z_start,w,west):
    bpy.context.view_layer.update()
    for ob in PARTS[start:]:
        matrix=ob.matrix_world.copy()
        for vert in ob.data.vertices:
            p=matrix@vert.co; xx,zz,hh=p.x,-p.y,p.z
            nx,nz=(zz,z_start+w-xx) if west else (6-zz,z_start+xx)
            vert.co=world(nx,nz,hh)
        ob.matrix_world=Matrix.Identity(4)
        ob.data.update()


# Author one unique facade and roof, with floor heights, windows and stacks determined by its measured lot.
def tenement(w,z_start,base,eave,ridge,variant,west):
    start=len(PARTS); depth=5.45+(variant%3)*.17
    box('Continuous grounded brick foundation',(0,0,0),(w,depth,base+.40),STONE,.018,False)
    box('Occupied brick lower storey',(.08,.1,base),(w-.08,depth-.07,base+2.8),STONE,.018,False)
    upper=PLASTER if variant%3 else STONE
    box('Upper inhabited storeys',(.08,.12,base+2.72),(w-.08,depth-.08,eave),upper,.018,False)
    for h in (base+2.76,eave-.15):
        box('Crooked timber storey belt',(.015,.05,h),(w-.015,depth,h+.16),WOOD,.01,False)
    for xx in (.13,w-.27):
        box('Timber corner frame',(xx,depth-.13,base+2.7),(xx+.14,depth+.025,eave),WOOD,.01,False)
    # Most panes are dark or boarded; scattered warm lights avoid repeated bright window grids.
    storeys=max(1,int((eave-base-.4)/2.45))
    count=2 if w<5.9 else 3
    for row in range(storeys):
        yy=base+.68+row*2.42
        if yy+1.45>eave-.25: continue
        for j in range(count):
            xx=.56+j*(w-1.75)/max(1,count-1)
            window_front(xx,depth+.014,yy,.93,1.40,lit=((variant*5+row*3+j)%7==1),boarded=((variant+row+j)%6==0))
    # One real solid street door and an occasional attached porch create inhabited scale.
    doorx=w*.45
    box('Solid tenement door',(doorx,depth+.025,base+.04),(doorx+.84,depth+.12,base+1.95),WOOD,.014,False)
    for k in range(5):
        box('Door plank seam',(doorx+.04+k*.16,depth+.122,base+.08),(doorx+.052+k*.16,depth+.135,base+1.88),DARK,0,False)
    for h in (base+.38,base+1.54):
        box('Tenement door strap',(doorx+.05,depth+.137,h),(doorx+.76,depth+.17,h+.07),IRON,.005,False)
    # Rotate the roof ridge orientation across adjacent lots, breaking any repeated silhouette.
    if variant%3!=1:
        mid=w*(.46+(variant%2)*.08)
        mesh('Unique left slate pitch',[world(0,0,eave),world(0,6,eave),world(mid,6,ridge),world(mid,0,ridge)],[(0,1,2,3)],ROOF)
        mesh('Unique right slate pitch',[world(mid,0,ridge),world(mid,6,ridge),world(w,6,eave),world(w,0,eave)],[(0,1,2,3)],ROOF)
        for z in (.08,5.87):
            mesh('Closed plaster gable',[world(.08,z,eave-.04),world(w-.08,z,eave-.04),world(mid,z,ridge-.10)],[(0,1,2)],upper)
            beam('Gable bargeboard',(0,z,eave),(mid,z,ridge),.12,WOOD)
            beam('Gable bargeboard',(mid,z,ridge),(w,z,eave),.12,WOOD)
        if ridge-eave>1.5:
            window_front(mid-.36,5.90,eave+.2,.72,.92,False)
    else:
        mesh('Crosswise slate roof',[world(0,0,eave),world(w,0,eave),world(w,3,ridge),world(0,3,ridge)],[(0,1,2,3)],ROOF)
        mesh('Crosswise street pitch',[world(0,3,ridge),world(w,3,ridge),world(w,6,eave),world(0,6,eave)],[(0,1,2,3)],ROOF)
        for xx in (.04,w-.04):
            mesh('Closed crosswise gable',[world(xx,0,eave),world(xx,6,eave),world(xx,3,ridge)],[(0,1,2)],upper)
        # Narrow front dormer breaks the otherwise long roof plane.
        dx=w*.32
        box('Dormer cheeks',(dx,4.5,eave-.05),(dx+1.35,5.8,eave+1.38),PLASTER,.01,False)
        window_front(dx+.18,5.82,eave+.16,1,1.02,variant%2==0)
        mesh('Dormer slate cap',[world(dx-.1,4.4,eave+1.40),world(dx+1.45,4.4,eave+1.40),world(dx+1.45,5.96,eave+1.2),world(dx-.1,5.96,eave+1.2)],[(0,1,2,3)],ROOF)
    # Tall and short chimney groups differ between all twelve houses.
    for c in range(1+(variant%3==0)):
        cx=.5+c*.95
        ch=ridge+.35+(variant%4)*.23-c*.5
        box('Unique brick chimney',(cx,1.0,eave),(cx+.66,1.74,ch),STONE,.018,False)
        box('Chimney cap',(cx-.06,.94,ch-.09),(cx+.72,1.80,ch+.08),CAP,.015,False)
        for xx in (cx+.16,cx+.43):
            lathe('Terracotta chimney pot',[(.13,0),(.13,.38),(.17,.43)],(xx,1.38,ch+.04),RUST,10)
    for x in (.06,w-.06):
        beam('Rain gutter',(x,.0,eave),(x,6,eave),.10,IRON)
    beam('Street rain downpipe',(.23,depth+.21,eave-.05),(.23,depth+.21,base+.15),.10,IRON)
    if variant%2:
        for i in range(3):
            beam('Exposed patch timber',(.28+i*.15,depth+.045,base+2.88),(1.6+i*.15,depth+.045,eave-.3),.085,WOOD)
    orient_house(start,z_start,w,west)


# Six adjoining lots on each side make two unique slumscapes, not four isolated copied houses.
for west,widths,bases,eaves,rises,offset in [
    (True,[5.8,6.1,4.6,7.0,5.0,7.5],[3,3,2,1,1,0],[10.2,8.9,10.8,7.0,8.2,5.8],[2.6,2.1,2.7,2.4,2.0,2.1],0),
    (False,[6.5,4.7,6.8,5.2,7.2,5.6],[3,3,2,1,1,0],[9.6,11.0,8.1,9.2,6.6,7.3],[2.1,2.5,2.7,1.8,2.5,2.2],7)]:
    cursor=0
    for i,w in enumerate(widths):
        tenement(w,cursor,bases[i],eaves[i],eaves[i]+rises[i],i+offset,west)
        cursor+=w
    finish_literal('tenement_row_west' if west else 'tenement_row_east')


# The prison is an occupied deep building mass with an inset iron-clad door, rather than a city arch.
box('Grounded prison plinth',(0,0,0),(28,7,.45),CAP,.035,False)
box('Massive occupied prison block',(.2,.1,.38),(27.8,5.62,11.8),STONE,.025,False)
for x in (0,18):
    box('Projected prison wing',(x,.12,.42),(x+10,6.42,11.7),STONE,.025,False)
    for band in (.45,3.20,6.65,10.4,11.7):
        box('Prison wing stone stringcourse',(x-.0,.03,band),(x+10,6.55,band+.25),CAP,.024,False)
    for xx in [x+.6,x+3.25,x+5.9,x+8.55]:
        for h in (4.0,7.4):
            window_front(xx,6.44,h,.95,1.85,lit=False,bars=True)
    for xx in (x+.18,x+9.12):
        box('Prison engaged buttress',(xx,5.95,.40),(xx+.65,6.8,12.25),CAP,.02,False)
    mesh('Shallow slate wing roof',[world(x,0,12.0),world(x+10,0,12.0),world(x+10,6.4,11.98),world(x,6.4,11.98)],[(0,1,2,3)],ROOF)
    for xx in (x+.6,x+9.0):
        box('Roof flue',(xx,1.1,11.8),(xx+.58,1.9,13.5),STONE,.017,False)
        box('Flue crown',(xx-.05,1.05,13.45),(xx+.63,1.95,13.68),CAP,.015,False)
box('Central entry projecting pediment',(10,5.7,.45),(18,6.66,12.25),STONE,.022,False)
for x in (10,17.3):
    box('Door jamb foundation',(x,6.2,.45),(x+.70,7.2,6.8),CAP,.028,False)
box('Door lintel',(10,6.2,6.45),(18,7.2,7.10),CAP,.024,False)
box('Actual heavy prison double door',(10.74,6.69,.46),(17.26,6.92,6.44),WOOD,.02,False)
for i in range(18):
    x=10.78+i*.36
    box('Individual iron-clad door plank',(x,6.93,.50),(x+.31,6.97,6.4),IRON,.008,False)
for x0,x1 in ((10.78,13.95),(14.05,17.22)):
    for h in (.85,2.0,4.2,5.7):
        box('Forged door cross strap',(x0,6.985,h),(x1,7.08,h+.17),RUST,.013,False)
        for i in range(8):
            lathe('Door rivet',[(.042,0),(.034,.035),(0,.045)],(x0+.16+i*.39,7.082,h+.08),IRON,8)
for x in [11.1+i*.4 for i in range(15)]:
    beam('Decorative security grille',(x,7.13,.6),(x,7.13,6.2),.055,IRON)
for h in (1.4,3.3,5.1):
    beam('Door grille strap',(10.82,7.13,h),(17.18,7.13,h),.065,IRON)
box('Substantial central threshold',(10.5,6.35,0),(17.5,7.45,.46),CAP,.018,False)
box('Prison name stone plaque',(10.55,6.68,7.46),(17.45,6.83,9.34),CAP,.02,False)
text_front('BLACKRIDGE',14,6.85,8.56,.63)
text_front('HOUSE OF CORRECTION',14,6.85,7.85,.34)
for xx in (11.0,12.65,14.3,15.95):
    window_front(xx,6.71,10.02,.83,1.4,bars=True)
box('Central pediment cornice',(9.72,5.80,12.18),(18.28,6.98,12.6),CAP,.02,False)
mesh('Substantial civic pediment',[world(x,z,h) for z in (5.84,6.84) for x,h in [(9.75,12.58),(18.25,12.58),(14,14.35)]],[(0,2,1),(3,4,5),(0,1,4,3),(1,2,5,4),(2,0,3,5)],STONE,.018,False)
for a,b in [((9.75,6.87,12.6),(14,6.87,14.37)),((14,6.87,14.37),(18.25,6.87,12.6))]:
    beam('Stone pediment rim',a,b,.18,CAP)
sigil(14,6.97,13.22,.50)
propaganda(1.3,6.86,10.2,2.0,6.9,['ORDER','PRESERVES'])
propaganda(24.7,6.86,10.2,2.0,6.9,['YOUR SILENCE','PROTECTS US'])
finish_literal('prison_facade')


# A continuous twenty-metre barricade reaches each street edge and leaves one central six-metre inspection passage.
for side in ('west','east'):
    for x in [i*2.6+.2 for i in range(8)]:
        if x>20: continue
        for z in (.05,1.65):
            beam('Barricade splayed brace',(x,z,0),(x,.85,1.72),.17,WOOD)
        beam('Joined defensive stake',(x,.85,.05),(x,.85,2.20),.14,WOOD)
    for h in (.55,1.27):
        for i in range(10):
            box('Connected overlapping timber line',(i*2,.74,h),(min(20,i*2+2.07),.99,h+.27),WOOD,.015,False)
            for x in (i*2+.22,i*2+1.72):
                box('Barricade iron strap',(x,.72,h-.02),(x+.10,1.01,h+.30),IRON,.006,False)
    for i in range(7):
        beam('Diagonal braced field',(i*2.6+.2,1.02,.45),(i*2.6+2.5,1.02,1.55),.12,WOOD)
    for x in (.12,19.65):
        box('Terminal weighted upright',(x,.55,0),(x+.23,1.22,2.25),IRON,.018,False)
    # Different small plaque placements distinguish the two long connected structures.
    px=10.0 if side=='west' else 2.4
    box('Barricade painted warning plate',(px,1.04,.82),(px+3.1,1.12,1.91),BANNER,.012,False)
    text_front('GLASSHOUSE',px+1.55,1.135,1.52,.34)
    text_front('INSPECTION LINE',px+1.55,1.135,1.08,.25)
    finish_literal('barricade_line_'+side)


# Three inspectable free-standing banner variants keep the propaganda readable from the game camera.
for name,lines in [('order',['ORDER','PRESERVES']),('vigilance',['PURITY THROUGH','VIGILANCE']),('silence',['YOUR SILENCE','PROTECTS US'])]:
    box('Weighted banner feet',(0,0,0),(2.2,.85,.22),CAP,.025,False)
    for x in (.12,2.08):
        beam('Banner upright',(x,.4,.2),(x,.4,4.7),.08,IRON)
    propaganda(.25,.46,4.5,1.7,3.7,lines)
    finish_literal('propaganda_'+name)


# Retain the approved railing and ordinary rubble geometry while replacing only their exterior-facing stone materials.
for source,name in [('railing_worn','city_railing'),('rubble_worn','city_rubble')]:
    bpy.ops.object.select_all(action='DESELECT')
    before=set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=str(ROOT/'assets/belowward_cell'/(source+'.glb')))
    for ob in set(bpy.data.objects)-before:
        if ob.type!='MESH': continue
        for slot in ob.material_slots:
            if slot.material and ('ashlar' in slot.material.name.lower() or 'coping' in slot.material.name.lower() or 'limestone' in slot.material.name.lower()):
                slot.material=STONE if 'ashlar' in slot.material.name.lower() else CAP
        PARTS.append(ob)
    finish_literal(name)

(OUT/'kit.json').write_text(json.dumps(ASSETS,indent=2))
bpy.ops.wm.save_as_mainfile(filepath=str(OUT/'bqr_architecture.blend'))
print('BQR_ARCHITECTURE_COMPLETE',flush=True)
