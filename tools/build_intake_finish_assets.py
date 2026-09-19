"""Build measured finishing variants without editing any accepted shared donor."""
from pathlib import Path
import bpy,json,math
from mathutils import Vector,Matrix
ROOT=Path(__file__).resolve().parents[1]
source=(ROOT/'tools/build_blackridge_intake_kit.py').read_text()
exec(compile(source.split('# The gate is the hall')[0],str(ROOT/'tools/build_blackridge_intake_kit.py'),'exec'))

# The current junction recipe preserves finished donor stone instead of the rejected metal tabs.
exec(compile((ROOT/'tools/build_intake_stone_junction.py').read_text(),str(ROOT/'tools/build_intake_stone_junction.py'),'exec'))
ob.hide_set(True);ob.hide_render=True;ob.select_set(False)
SCENE=bpy.context.scene
ASSETS['rail_junction']={'path':str(ROOT/'assets/blackridge_intake/rail_junction.glb').replace('\\','/'),'export_name':'rail_junction','asset_id':'BI_RAIL_JUNCTION','grid':[1,2,1],'driver_axis':0,'physical_dimensions':[1,1.9,1],'triangles':report['triangles']}

# The desktop's broad top lies 0.677796 m above the measured feet in the source.
bpy.ops.import_scene.gltf(filepath=str(ROOT/'tile_library/assets/BW_MESHY_WARDENS_DESK/derived/runtime_optimized.glb'))
desk=[o for o in bpy.context.selected_objects if o.type=='MESH'][0]
factor=.87/.677796099
bpy.context.view_layer.update()
for v in desk.data.vertices:
    q=desk.matrix_world@v.co
    v.co=Vector(((q.x+.95193839)*factor+.25,(q.y-.404797107)*factor-.16,(q.z+.517796099)*factor))
desk.matrix_world=Matrix.Identity(4);desk.data.update();PARTS.append(desk)
# A stool and ledger crate occupy the clerk side, leaving the writing top unobscured.
box('Clerk stool seat',(1.0,1.40,.47),(1.55,1.93,.55),WOOD,.02)
for x in (1.04,1.45):
    for z in (1.44,1.83): box('Stool foot',(x,z,0),(x+.065,z+.065,.50),WOOD,.012)
box('Ledger crate',(2.66,1.2,0),(3,1.8,.45),WOOD,.02)
for n in range(3): box('Bound registry books',(2.68,1.23,.46+n*.05),(2.97,1.72,.505+n*.05),LEATHER,.008)
# A narrow coat stand gives the workstation a meaningful 2 m envelope.
box('Coatstand sole',(0,1.54,0),(.30,2,.07),IRON,.01)
beam('Clerk coatstand',(.15,1.77,.03),(.15,1.77,2),.045,WOOD)
beam('Coat hooks',(.02,1.77,1.83),(.28,1.77,1.83),.025,IRON)
publish('registry_workstation',(3,2,2))
(OUT/'finish_kit.json').write_text(json.dumps(ASSETS,indent=2))
