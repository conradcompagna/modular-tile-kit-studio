"""Audit measured installed specimen bounds against their saved native placements and light positions."""
from pathlib import Path
import json
import re
import math

root = Path(__file__).resolve().parents[1]
board = json.loads((root/'boards/blackridge_quarantine.json').read_text())
imports = json.loads((root/'exports/blackridge_quarantine_revision/native_import_report.json').read_text())
assets = {x['id']:x for x in imports['results'] if x.get('metrics')}
results = []


# Parse the Godot diagnostic vectors whose exact values were recorded during native import.
def values(text):
    return [float(x) for x in re.findall(r'-?\d+\.\d+', text)]


for prop in board['props']:
    if prop['asset'] not in assets:
        continue
    asset = assets[prop['asset']]
    bounds = values(asset['metrics']['output']['bounds'])
    pose = values(asset['pose'])
    assert prop['forward']=='-Z' and prop['roll']==0 and prop['yaw']==0
    low = [prop['origin'][i]+pose[9+i]+bounds[i]*pose[i*4] for i in range(3)]
    high = [low[i]+bounds[3+i]*pose[i*4] for i in range(3)]
    lights_inside = []
    for light in board['lighting']['lights']:
        point = light['surface_position']
        if all(low[i] <= point[i] <= high[i] for i in range(3)):
            lights_inside.append(light['name'])
    terrain = board['terrain']
    supports = []
    ox,oz = terrain['origin_cell']
    w,d = terrain['size_cells']
    for x in range(math.floor(low[0]),math.ceil(high[0])):
        for z in range(math.floor(low[2]),math.ceil(high[2])):
            idx = (z-oz)*w+x-ox
            supports.append(bool(terrain['cell_mask'][idx]) and abs(max(terrain['top_heights'][4*idx:4*idx+4])-low[1])<0.002)
    results.append({'id':prop['asset'],'native_origin':prop['origin'],'installed_world_min':low,'installed_world_max':high,
                    'all_bounds_footing_cells_present_at_base_height':all(supports),'local_lights_inside_actual_bounds':lights_inside,
                    'eaves_clearance_m':5.2-high[1],'roof_ridge_clearance_m':6.7-high[1]})
payload = {'source':'Installed optimized AABBs and native pose measurements from successful import; canonical saved board and unchanged lights.',
           'assets':results,'pass':all(x['all_bounds_footing_cells_present_at_base_height'] and not x['local_lights_inside_actual_bounds'] and x['eaves_clearance_m']>0 for x in results)}
(root/'reports/blackridge_quarantine_revision/SPECIMEN_CONTACT_AUDIT.json').write_text(json.dumps(payload,indent=2))
print(json.dumps(payload,indent=2))
