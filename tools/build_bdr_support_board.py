"""Derive the explicit native support revision from measured restored geometry."""
from pathlib import Path
import copy
import json
from shapely.geometry import Polygon,box

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'exports/blackridge_depths_revision'
board=json.loads((OUT/'board_before_support_materials.json').read_text())
before=json.loads((ROOT/'reports/blackridge_depths/revision_support_before.json').read_text())
t=board['terrain']; w,d=t['size_cells']; changes=[]


# Author a literal filled one-metre top quad and document its former state.
def fill(x,z,h,reason,only_missing=True):
    if not 0<=x<w or not 0<=z<d:
        raise ValueError(f'Footing exceeds existing native bounds: {x},{z}')
    i=z*w+x
    if only_missing and t['cell_mask'][i]:
        return
    old=None if not t['cell_mask'][i] else t['top_heights'][i*4:i*4+4]
    t['cell_mask'][i]=1; t['top_heights'][i*4:i*4+4]=[h]*4
    changes.append({'cell':[x,z],'before':old,'top':h,'reason':reason})


# Contact cells rise two centimetres into each planar rock base; old playable treads stay intact.
for rock in before['rocks']:
    if rock['index']==28:
        continue
    for part in rock['parts']:
        for cell in part['cells']:
            x,z=cell['cell']
            if cell['terrain_corners'] is None:
                fill(x,z,round(cell['base_y']+.02,3),f'rock_{rock["index"]}_actual_base')

# A shallow native fringe makes the bearing rock visible at the outside of each occupied footprint.
contact_changes=list(changes)
for change in contact_changes:
    x,z=change['cell']
    if 18<=x<28 and 14<=z<24:
        continue
    for dx,dz in [(0,-1),(1,0),(0,1),(-1,0)]:
        nx,nz=x+dx,z+dz
        if 0<=nx<w and 0<=nz<d:
            fill(nx,nz,change['top']-.35,'rock_bearing_fringe')

# A nearby existing three-by-three level shelf clears the complete northeast staircase again.
board['props'][28]['origin']=[34,2,8]

# The irregular low island is native terrain, leaving the east and west fissures open.
island=Polygon([(23,14.8),(25.5,14.8),(26.2,16.4),(25.6,18.1),(26.1,20.8),
                (24.5,21.8),(22.0,21.4),(20.6,22.1),(18.4,21.7),(18.5,20.0),
                (19.0,18.3),(21.0,17.5),(22.3,16.9)])
for z in range(14,23):
    for x in range(18,28):
        if island.intersection(box(x,z,x+1,z+1)).area>.10:
            fill(x,z,-1.98,'boss_native_island',only_missing=False)

# The two-metre south access descends in readable half-metre native treads.
for z,h in [(23,-.5),(22,-1.0),(21,-1.5),(20,-1.98)]:
    for x in [22,23]:
        fill(x,z,h,'south_island_approach',only_missing=False)

# Side topology is deterministically rebuilt from the new canonical top heights.
sides={}
for z in range(d):
    for x in range(w):
        i=z*w+x
        if not t['cell_mask'][i]:
            continue
        h=t['top_heights'][i*4]
        for edge,(dx,dz) in enumerate([(0,-1),(1,0),(0,1),(-1,0)]):
            nx,nz=x+dx,z+dz
            if 0<=nx<w and 0<=nz<d and t['cell_mask'][nz*w+nx]:
                other=t['top_heights'][(nz*w+nx)*4]
                if h>other:
                    sides[f'{x},{z},{edge}']=[0.,1.,other,h,other,h]
t['side_faces']=sides

# The approved architecture and monster remain byte-for-byte identical except the stated rock move.
for index,prop in enumerate(board['props']):
    if index!=28:
        assert prop==json.loads((OUT/'board_before_support_materials.json').read_text())['props'][index]
(OUT/'board_support_candidate.json').write_text(json.dumps(board,indent=2)+'\n')
(OUT/'support_changes.json').write_text(json.dumps({'changes':changes,'relocated_prop':{'index':28,'before':[34,2,10],'after':[34,2,8]},'cells_before':810,'cells_after':sum(t['cell_mask'])},indent=2)+'\n')

# New material variants retain exact geometry; one side shrine becomes the commissioned relic.
for prop in board['props']:
    if prop['asset'].startswith('BD_CAVERN_WALL') or prop['asset'].startswith('BD_STALAGMITE'):
        prop['asset']=prop['asset'].replace('BD_','BDR_',1)
board['props'][36]['asset']='BDR_BINDING_RELIQUARY'
board['material_blend']['layers'][0]['asset_id']='BDR_FRACTURED_FLOOR'
board['material_blend']['layers'][0]['texture_scale_percent']=100.0
board['material_blend']['layers'][1]['asset_id']='BDR_MINERAL_WALL'
board['material_blend']['layers'][1]['texture_scale_percent']=100.0
board['surface_material_paint']={'version':3,'surfaces':[],'material_slots':[]}
board['imported_assets']=sorted({prop['asset'] for prop in board['props']}|{'BDR_FRACTURED_FLOOR','BDR_MINERAL_WALL'})

# The old green sources were inside solid rock; place them in measured open fissures instead.
lighting_changes=[]
for index,position in enumerate([[27.5,-3.0,17.5],[39.5,-4.0,23.5],[6.5,-4.0,29.5]]):
    light=board['lighting']['lights'][index]
    lighting_changes.append({'name':light['name'],'before':light['surface_position'],'after':position})
    light['surface_position']=position
(OUT/'lighting_changes.json').write_text(json.dumps(lighting_changes,indent=2)+'\n')
(OUT/'board_candidate.json').write_text(json.dumps(board,indent=2)+'\n')
print(json.dumps({'cells':sum(t['cell_mask']),'authored_quad_operations':len(changes),'prop_relocations':1,'boss_unchanged':True}))
