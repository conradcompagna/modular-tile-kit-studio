"""Build the small authored warning and stain pieces for the quarantine containment vignette."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
recipe = (ROOT / 'tools/build_blackridge_quarantine_kit.py').read_text()
exec(compile(recipe.split('# The prison gate is a load-bearing arch')[0], str(ROOT / 'tools/build_blackridge_quarantine_kit.py'), 'exec'))

# The timber warning is braced into a full-depth weighted stone foot.
box('Notice base', (0,0,0),(3,1,.18),CAP,.025)
for x in (.15,2.7):
    box('Notice upright',(x,.40,.1),(x+.15,.58,2.9),WOOD,.015)
box('Notice dark painted board',(.08,.35,.9),(2.92,.55,2.85),DARK,.015)
for h in (.87,2.85):
    box('Notice border',(0,.32,h),(3,.60,h+.07),IRON,.006)
for message, h, size in [('QUARANTINE',2.28,.34),('KEEP OUT',1.62,.43)]:
    curve=bpy.data.curves.new('Painted warning letters','FONT')
    curve.body=message
    curve.size=size
    curve.align_x='CENTER'
    curve.extrude=.001
    curve.resolution_u=2
    ob=bpy.data.objects.new('Warning lettering',curve)
    SCENE.collection.objects.link(ob)
    ob.location=world(1.5,.566,h)
    ob.rotation_euler=(math.pi/2,0,0)
    curve.materials.append(BONE)
    bpy.context.view_layer.objects.active=ob
    ob.select_set(True)
    bpy.ops.object.convert(target='MESH')
    PARTS.append(bpy.context.object)
    ob.select_set(False)
finish('quarantine_notice',(3,3,1))

# A very low irregular residue patch rests on the native pen floor; it is placed beside the remains.
for i in range(11):
    cx,cz=random.uniform(.18,1.8),random.uniform(.18,1.8)
    radius=random.uniform(.10,.35)
    verts=[world(cx,cz,.016)]
    for j in range(9):
        a=math.tau*j/9
        r=radius*random.uniform(.7,1.1)
        verts.append(world(max(0,min(2,cx+r*math.cos(a))),max(0,min(2,cz+r*math.sin(a))),.016))
    mesh('Irregular old residue',verts,[(0,j+1,(j+1)%9+1) for j in range(9)],BLOOD)
box('Residue thickness',(0,0,0),(.02,.02,.02),BLOOD,0,False)
finish('contained_residue',(2,.02,2))
(OUT/'vignette_kit.json').write_text(json.dumps(ASSETS,indent=2))
