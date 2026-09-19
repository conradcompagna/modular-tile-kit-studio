"""Prepare the revised quarantine candidate without replacing the native saved board."""
from pathlib import Path
import copy
import json

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'exports/blackridge_quarantine_revision'
board=json.loads((OUT/'board_before_revision.json').read_text())
old=board['terrain']
oldw,oldd=old['size_cells']
w,d=58,42
mask=[0]*(w*d)
heights=[0.0]*(w*d*4)
diagonals=[0]*(w*d)


# Preserve the complete playfield and extend real native ground beneath both entire tenement rows.
def set_cell(x,z,h,active=True):
    idx=z*w+x+6
    mask[idx]=int(active)
    heights[idx*4:idx*4+4]=[h]*4


for z in range(d):
    for x in range(-6,52):
        if 0<=x<oldw:
            src=z*oldw+x; dst=z*w+x+6
            mask[dst]=old['cell_mask'][src]
            heights[dst*4:dst*4+4]=old['top_heights'][src*4:src*4+4]
            diagonals[dst]=old['top_diagonals'][src]
        elif 3<=z<39:
            set_cell(x,z,0.0)
# The actual prison building has a full supported foundation across the previously clipped rear corners.
for z in range(0,8):
    for x in range(9,37):
        set_cell(x,z,3.0)
# House fronts are offset by real foundations, not by hidden geometry placement compensation.
for x in list(range(0,2))+list(range(44,46)):
    for z in range(3,39):
        if not mask[z*w+x+6]:
            set_cell(x,z,0)
board['terrain']={'origin_cell':[-6,0],'size_cells':[w,d],'cell_mask':mask,
    'top_heights':heights,'top_diagonals':diagonals,'side_faces':{},'skirt_depth_m':8.0}
# Native TerrainMesh regenerates exposed vertical faces from the actual authored lattice during prepare.
for z in range(d):
    for x in range(-6,52):
        idx=z*w+x+6
        if not mask[idx]: continue
        h=heights[idx*4]
        for edge,(dx,dz) in enumerate(((0,-1),(1,0),(0,1),(-1,0))):
            xx,zz=x+dx,z+dz
            if not(-6<=xx<52 and 0<=zz<d): continue
            j=zz*w+xx+6
            if mask[j] and h>heights[j*4]:
                other=heights[j*4]
                board['terrain']['side_faces'][f'{x},{z},{edge}']=[0.0,1.0,other,h,other,h]

remove={'BQ_PRISON_GATE','BQ_PRISON_WALL_WING','BQ_CITY_TENEMENT','BQ_QUARANTINE_BARRICADE',
    'BW_MESHY_INTERROGATION_FRAME','BW_MESHY_SKELETAL_RACK','BQ_WARDEN_MONUMENT'}
props=[]
for p in board['props']:
    if p['asset'] in remove: continue
    if p['asset']=='BW_RUBBLE_WORN' and p['origin']==[35,0,30]: continue
    if p['asset']=='BW_RAILING_WORN' and p['origin'] in ([0,0,30],[45,0,30]): continue
    p=copy.deepcopy(p)
    # Native occupancy found these old gate lanterns inside the deeper facade; move them to its front apron.
    if p['asset']=='BW_LANTERN_CAGED' and p['origin'] in ([14,3,7],[31,3,7]): p['origin'][2]=8
    # The critic's runtime01 review found the old warning board screened the new examination table.
    if p['asset']=='BQ_QUARANTINE_NOTICE': p['origin']=[4,1,24]
    if p['asset']=='BW_RAILING_WORN': p['asset']='BQR_CITY_RAILING'
    if p['asset']=='BW_RUBBLE_WORN': p['asset']='BQR_CITY_RUBBLE'
    if p['asset']=='BW_CRATE_IRON_BOUND' and p['origin']==[33,0,31]: p['origin']=[33,0,32]
    if p['asset']=='BQ_QUARANTINE_STANDARD':
        if p['origin']==[33,0,33]:
            p['asset']='BQR_PROPAGANDA_VIGILANCE'; p['origin']=[26,0,34]
        elif p['origin'][0]==2: p['asset']='BQR_PROPAGANDA_ORDER'
        else: p['asset']='BQR_PROPAGANDA_SILENCE'
    # Clear just the furnishings that occupy the three new measured specimen footprints.
    if p['asset']=='BI_HOLDING_BENCH' and p['origin'] in ([4,2,19],[29,2,21]): continue
    if p['asset']=='BW_CRATE_IRON_BOUND' and p['origin']==[4,2,16]: continue
    props.append(p)
board['props']=props


# These coordinates are explicit placement candidates validated through native measured voxels before installation.
def prop(asset,x,y,z):
    board['props'].append({'asset':asset,'origin':[x,y,z],'forward':'-Z','roll':0,'yaw':0})


prop('BQR_TENEMENT_ROW_WEST',-6,0,3)
prop('BQR_TENEMENT_ROW_EAST',46,0,3)
prop('BQR_PRISON_FACADE',9,3,0)
prop('BQ_WARDEN_MONUMENT',17,3,8)
prop('BQ_WARDEN_MONUMENT',27,3,8)
prop('BQR_BARRICADE_LINE_WEST',0,0,30)
prop('BQR_BARRICADE_LINE_EAST',26,0,30)
prop('BQR_UPRIGHT_SPECIMEN',4,2,17)
prop('BQR_OCCULT_TABLE',12,2,18)
prop('BQR_SUSPENDED_HUSK',29,2,17)
board['material_blend']['layers'][0]['asset_id']='BQR_CITY_SETTS'
board['material_blend']['layers'][0]['texture_scale_percent']=100.0
board['material_blend']['layers'][1]['asset_id']='BQR_EXTERIOR_BRICK'
board['material_blend']['layers'][1]['texture_scale_percent']=100.0
board['surface_material_paint']={'version':3,'surfaces':[],'material_slots':[]}
board['imported_assets']=sorted({p['asset'] for p in board['props']}|{'BQR_CITY_SETTS','BQR_EXTERIOR_BRICK'})
board['biome']='Blackridge Underholm - Weathered City Quarantine'
# The former gate arch was empty at this point; the new solid door requires the amber pool in clear air.
for light in board['lighting']['lights']:
    if light['name']=='Gatehouse amber':
        light['name']='Prison doorway amber'
        light['surface_position']=[23.0,10.5,8.7]
# A door staging point remains immediately outside the opaque prison threshold.
for marker in board['gameplay_markers']:
    if marker['id']=='exit_to_intake':
        marker['note']='The substantial prison door leads into Blackridge Intake; this is visual staging pending travel interaction.'
(OUT/'board_candidate.json').write_text(json.dumps(board,indent=2))
(OUT/'layout_summary.json').write_text(json.dumps({'cells':sum(mask),'props':len(props),
    'bounds':[[-6,0],[52,42]],'preserved_playfield':True,'statues':2,'unique_rows':2,
    'barricade_opening_m':6,'meshy_specimens':3},indent=2))
print(json.dumps({'cells':sum(mask),'props':len(props),'markers':len(board['gameplay_markers'])}))
