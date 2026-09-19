"""Surgically refine the saved native arena while retaining its accepted terrain and encounter data."""
from pathlib import Path
import json
import copy

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'exports/blackridge_depths'
source=ROOT/'boards/blackridge_depths.json'
board=json.loads(source.read_text())
backup=OUT/'board_before04.json'
if not backup.exists():
    backup.write_text(json.dumps(board,indent=2))
board['props']=[p for p in board['props'] if p['asset'] not in ('BD_CAVERN_WALL_A','BD_CAVERN_WALL_B','BD_CAVERN_WALL_CEILING')]
for prop in board['props']:
    if prop['asset']=='BD_ARRIVAL_LIFT':
        prop['asset']='BD_ARRIVAL_LIFT_HOIST'
for asset,origin,forward in (
    ('BD_CAVERN_NORTH_MASS',[7,-3,0],'-Z'),
    ('BD_CAVERN_EAST_MASS',[40,-5,6],'+X'),
    ('BD_COLLAPSE_EDGE',[16,0,15],'-Z'),
    ('BD_COLLAPSE_EDGE',[34,0,30],'-Z'),
):
    board['props'].append({'asset':asset,'origin':origin,'forward':forward,'roll':0,'yaw':0,'support':'wall','support_face':'+Z'})
w,d=board['terrain']['size_cells']
removed=[]
for x,z in ((17,14),(17,15),(18,13),(35,28),(35,29)):
    index=z*w+x
    if board['terrain']['cell_mask'][index]:
        board['terrain']['cell_mask'][index]=0
        removed.append([x,z])
board['imported_assets']=sorted(set(p['asset'] for p in board['props'])|{'BW_FLAGSTONES_WORN','BW_ASHLAR_VARIED'})
(OUT/'board_candidate_04.json').write_text(json.dumps(board,indent=2))
(OUT/'refinement04.json').write_text(json.dumps({'removed_cells':removed,'props':len(board['props']),'filled_cells':sum(board['terrain']['cell_mask'])},indent=2))
print(json.dumps({'removed_cells':removed,'props':len(board['props']),'filled_cells':sum(board['terrain']['cell_mask'])}))
