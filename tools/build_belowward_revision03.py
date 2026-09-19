"""Remove only the redundant ferry guide strands, preserving every retained vertex and adding two functional underframe skids."""
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
helpers=(ROOT/'tools/build_intake_revision03_kit.py').read_text().split("donor('tile_library/assets/BIR_AUTHORITY_DOOR")[0]
exec(compile(helpers.replace("'BI3_'","'BC3_'"),'<measured-donor-helpers>','exec'))
ART=ROOT/'assets/belowward_revision03';OUT=ROOT/'exports/belowward_revision03';ASSETS={}
donor('tile_library/assets/BC_CENTRAL_CABLE_FERRY/source/central_cable_ferry.glb')
original={tuple(round(float(v.co[k]),5) for k in range(3)) for ob in PARTS for v in ob.data.vertices}
removed=0
for ob in PARTS:
    bm=bmesh.new();bm.from_mesh(ob.data);discard=[]
    for f in bm.faces:
        for z in (.7,3.3):
            in_guide_column=all(11.43<=v.co.x<=11.77 and z-.16<=-v.co.y<=z+.16 for v in f.verts)
            heights=[v.co.z for v in f.verts]
            redundant=in_guide_column and (max(heights)-min(heights)>19 or max(heights)<.701 or (min(heights)>20.39 and max(heights)<20.5))
            if redundant: discard.append(f);break
    removed+=len(discard);bmesh.ops.delete(bm,geom=discard,context='FACES');bm.to_mesh(ob.data);bm.free()
retained={tuple(round(float(v.co[k]),5) for k in range(3)) for ob in PARTS for v in ob.data.vertices}
assert retained.issubset(original),'Retained source vertices changed.'
# These two real timber underframe skids connect to the existing floor stringers and give an inspectable integer native anchor.
# Source minimum9m derives native poseY=-9; board originY=-3 therefore preserves the old source-to-world translation of-12m.
for z in (1.10,2.80):
    box('Cargo underframe timber skid',(11.50,z-.13,9.0),(14.50,z+.13,9.8),WOOD,.018,False)
    for x in (11.62,14.25):
        box('Underframe skid iron binding',(x,z-.145,9.08),(x+.13,z+.145,9.80),IRON,.008,False)
publish('central_cable_ferry',[26,12,4])
ASSETS['central_cable_ferry'].update(removed_redundant_faces=removed,retained_vertices_unchanged=True,retained_vertex_count=len(retained),placement_origin=[11,-3,20],expected_native_pose_translation=[0,-9,0],old_world_translation=[11,-12,20],new_world_translation=[11,-12,20])
(OUT/'kit.json').write_text(json.dumps(ASSETS,indent=2))
bpy.ops.wm.save_as_mainfile(filepath=str(ART/'ferry_without_redundant_guides.blend'))
print('BC3_READY '+json.dumps(ASSETS),flush=True)
