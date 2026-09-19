"""Prepare measured flat prop pockets and restrained native cavern sculpting for editor authoring."""
from pathlib import Path
import copy
import json
import math
import numpy as np
from scipy.ndimage import distance_transform_edt

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'exports/blackridge_depths_revision03'
board=json.loads((OUT/'board_before.json').read_text())
poses=json.loads((ROOT/'reports/blackridge_depths_revision03/native_poses_before.json').read_text())
original=json.loads((ROOT/'exports/blackridge_depths_revision/board_before_support_materials.json').read_text())
kit=json.loads((OUT/'kit.json').read_text())
t=board['terrain'];width,depth=t['size_cells'];before=copy.deepcopy(t)
changes=[];pockets={};moves={21:[6,-4,30],22:[10,-5,33],23:[35,-5,33],24:[36,-3,30],25:[9,-3,8],26:[18,-9,14],27:[26,-9,17]}


# Change one explicitly authored top quad while retaining a reason and the prior native values.
def set_quad(x,z,heights,reason):
    i=z*width+x
    old=t['top_heights'][4*i:4*i+4] if t['cell_mask'][i] else None
    if old==heights:return
    changes.append({'cell':[x,z],'before':old,'after':heights,'reason':reason})
    t['cell_mask'][i]=1;t['top_heights'][4*i:4*i+4]=heights


# Apply approved source variants and explicit relocations before calculating any pocket.
for record in poses:
    i=record['index'];prop=board['props'][i]
    if i in moves:
        delta=np.array(moves[i])-np.array(prop['origin'])
        record['origin']=(np.array(record['origin'])+delta).tolist()
        record['footprint']=[[x+int(delta[0]),z+int(delta[2])] for x,z in record['footprint']]
        prop['origin']=moves[i]
    if record['asset'].startswith('BDR_CAVERN_WALL'):
        suffix=record['asset'].removeprefix('BDR_').lower()
        record['asset']=prop['asset']=kit[suffix]['asset_id']
        record['path']='res://assets/blackridge_depths_revision03/'+Path(kit[suffix]['path']).name
    if i==27:
        record['asset']=prop['asset']='BD3_STALAGMITE_FISSURE'
        record['path']='res://assets/blackridge_depths_revision03/stalagmite_fissure.glb'
        record['basis']=[[1,0,0],[0,1,0],[0,0,1]]
        record['grid_bounds']=[2,8,2]
        record['footprint']=[[x,z] for z in range(17,19) for x in range(26,28)]
    if i==33:
        record['asset']=prop['asset']='BD3_ARRIVAL_LIFT_ANCHORED'
        record['path']='res://assets/blackridge_depths_revision03/arrival_lift_anchored.glb'
        record['grid_bounds']=[3,9,3]
    if i==56:
        record['asset']=prop['asset']='BR3_BARREL_CLUSTER'
        record['path']='res://tile_library/assets/BR3_BARREL_CLUSTER/source/barrel_cluster.glb'

# Complete native footprints are flat; the boss assembly preserves its separate island and four piers.
for record in poses:
    i=record['index']
    if i==35:continue
    h=float(board['props'][i]['origin'][1])
    if i<28:h+=.015
    for x,z in record['footprint']:
        key=(x,z)
        if key in pockets and abs(pockets[key]['height']-h)>.05:
            raise ValueError(f'Incompatible pockets at {key}: {pockets[key]} vs {i}, {h}')
        pockets[key]={'height':h,'prop':i}

# Remove obsolete support fragments only where neither original terrain nor current contact owns them.
keep=set(pockets)
for x,z in list(pockets):
    if pockets[(x,z)]['prop']<28:
        keep.update((x+dx,z+dz) for dx,dz in [(-1,0),(1,0),(0,-1),(0,1)] if 0<=x+dx<width and 0<=z+dz<depth)
for z in range(depth):
    for x in range(width):
        i=z*width+x
        boss_island=18<=x<28 and 14<=z<24 and t['cell_mask'][i] and t['top_heights'][i*4]>-3
        if t['cell_mask'][i] and not original['terrain']['cell_mask'][i] and (x,z) not in keep and not boss_island:
            changes.append({'cell':[x,z],'before':t['top_heights'][i*4:i*4+4],'after':None,'reason':'obsolete moved-rock support'})
            t['cell_mask'][i]=0

# Native stone extends under each entire pocket, then drops toward its measured outside bearing edge.
for (x,z),pocket in pockets.items():
    set_quad(x,z,[pocket['height']]*4,'complete flat pocket for prop '+str(pocket['prop']))
for (x,z),pocket in pockets.items():
    if pocket['prop']>=28:continue
    for dx,dz in [(-1,0),(1,0),(0,-1),(0,1)]:
        nx,nz=x+dx,z+dz
        if not (0<=nx<width and 0<=nz<depth) or (nx,nz) in pockets:continue
        i=nz*width+nx
        if not t['cell_mask'][i]:
            set_quad(nx,nz,[pocket['height']-.30]*4,'lower bearing fringe')

# Protected corners hold complete prop pockets, original stairs and the boss's existing contact planes.
locked=np.zeros((depth+1,width+1),dtype=bool)
for z in range(depth):
    for x in range(width):
        i=z*width+x
        h=t['top_heights'][4*i]
        protected=(x,z) in pockets or [x,z] in poses[35]['footprint'] or abs(h-round(h))>.01 or h not in [0,2] or z in [11,12,13]
        if protected or not t['cell_mask'][i]:locked[z:z+2,x:x+2]=True
dist=distance_transform_edt(~locked)
field=np.zeros((depth+1,width+1))
for z in range(depth+1):
    for x in range(width+1):
        amplitude=(.68*math.exp(-((x-24)**2+(z-29)**2)/26)
                   +.48*math.exp(-((x-26)**2+(z-7)**2)/20)
                   +.44*math.exp(-((x-35)**2+(z-16)**2)/20)
                   -.38*math.exp(-((x-10)**2+(z-23)**2)/16)
                   -.32*math.exp(-((x-16)**2+(z-32)**2)/14))
        fade=min(1,dist[z,x]/2.0)
        field[z,x]=round(amplitude*fade,3)
for z in range(depth):
    for x in range(width):
        i=z*width+x
        if not t['cell_mask'][i]:continue
        old=np.array(t['top_heights'][4*i:4*i+4])
        if not np.allclose(old,old[0]) or old[0] not in [0,2]:continue
        relief=np.array([field[z,x],field[z,x+1],field[z+1,x],field[z+1,x+1]])
        if np.any(abs(relief)>.001):set_quad(x,z,(old+relief).round(3).tolist(),'sculpted mineral rise or shallow depression')

# Source variants and terrain edits remain a candidate until native pose and side-face regeneration.
board['lighting']['lights'][0]['surface_position']=[21.5,-3,15.5]
board['surface_material_paint']={'version':3,'surfaces':[],'material_slots':[]}
board['imported_assets']=sorted({p['asset'] for p in board['props']}|{'BDR_FRACTURED_FLOOR','BDR_MINERAL_WALL'})
(OUT/'board_candidate.json').write_text(json.dumps(board,indent=2)+'\n')
(ROOT/'reports/blackridge_depths_revision03/candidate_source_poses.json').write_text(json.dumps(poses,indent=2)+'\n')
sculpted=[c for c in changes if c['reason'].startswith('sculpted')]
(OUT/'terrain_changes.json').write_text(json.dumps({'moves':moves,'flat_pockets':len(pockets),'quad_operations':changes,'sculpted_cells':len(sculpted),'relief_min':float(field.min()),'relief_max':float(field.max()),'boss_contact_terrain_preserved':True},indent=2)+'\n')
print(json.dumps({'native_cells':sum(t['cell_mask']),'flat_pocket_cells':len(pockets),'sculpted_cells':len(sculpted),'relief_range':[float(field.min()),float(field.max())],'moved_rocks':moves}))
