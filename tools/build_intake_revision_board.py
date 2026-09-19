"""Patch the saved Intake checkpoint with measured doors, a native dock and two focal props."""
from pathlib import Path
import json, copy
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'exports/blackridge_intake_revision'
b=json.loads((OUT/'before_revision.json').read_text())

# Change only exterior door instances; the interior queue's shared open arch stays untouched.
for p in b['props']:
    if p['asset']=='BI_AUTHORITY_GATE': p['asset']='BIR_AUTHORITY_DOOR'
    elif p['asset']=='BI_DESCENT_ARCH':
        p['asset']='BIR_SERVICE_DOOR'
        p['origin']=[29,0,36]
    elif p['asset']=='BW_OPEN_GATE_PASSAGE' and p['origin']==[2,0,20]: p['asset']='BIR_ARRIVAL_DOOR'
    elif p['asset']=='BW_LANTERN_CAGED' and p['origin']==[29,0,35]: p['origin']=[28,0,36]
    elif p['asset']=='BI_REGISTRY_WORKSTATION' and p['origin']==[17,0,19]: p['origin']=[16,0,19]

# Four metres of railing open only at the dock; the hoist car's own front rail protects the pit edge.
b['props']=[p for p in b['props'] if not (p['asset']=='BW_RAILING_WORN' and p['origin'] in ([27,0,29],[29,0,29],[31,0,29],[33,0,29]))]
# The new evidence cart replaces the lower ordinary confiscation cart rather than duplicating it.
b['props']=[p for p in b['props'] if not (p['asset']=='BI_PROPERTY_CART' and p['origin']==[9,0,29])]


# Record literal native origin boxes; import poses and native voxels remain authoritative.
def place(asset,origin,forward='-Z'):
    b['props'].append({'asset':asset,'origin':origin,'forward':forward,'roll':0,'yaw':0})


place('BIR_DOCKED_FREIGHT_HOIST',[28,0,24])
place('BI_RAIL_JUNCTION',[27,0,29])
place('BI_RAIL_JUNCTION',[34,0,29])
place('BIR_CENSUS_ENGINE',[19,0,20])
place('BIR_EVIDENCE_ARCHIVE',[8,0,28])

# The dock floor is the existing one-metre terrain, painted timber rather than adding a second mesh floor.
deck={(x,z) for x in range(29,33) for z in range(29,33)}
layer=copy.deepcopy(b['material_blend']['layers'][0])
layer.update(asset_id='BIR_DOCK_PLANKS',enabled=True,application_mode=1,texture_scale_percent=100.0)
b['material_blend']['layers'][2]=layer
for slot in b['surface_material_paint']['material_slots']:
    uid=slot['uid']
    if uid.startswith('t:'):
        parts=uid[2:].split(',')
        if (int(parts[0]),int(parts[1])) in deck:
            slot['palette_indices']=[2,-1,-1,-1]
            slot['rotation_quarters']=[0,0,0,0]

# Place the descent objective inside the car's clear central standing cells.
for m in b['gameplay_markers']:
    if m['id']=='descend_to_belowward':
        m['origin']=[31,0,31]
        m['note']='Board the docked freight car. Its overhead trolley carries it over the shaft before lowering toward Belowward; this board authors the docked state.'

# A visible nearby lantern supplies a restrained light outside the hero's actual occupied volume.
for p in b['props']:
    if p['asset']=='BW_LANTERN_CAGED' and p['origin']==[18,0,17]: p['origin']=[24,0,23]
for light in b['lighting']['lights']:
    if light['surface_position'][0]==18.5 and light['surface_position'][2]==17.5:
        light['surface_position']=[24.5,2.1,23.5]
        light['name']='Census Engine lantern'
        light['radius']=8
        light['intensity']=1.5
        light['color']=[1.0,0.7,0.42]
    elif light['surface_position'][0]==29.5 and light['surface_position'][2]==35.5:
        light['surface_position']=[28.5,2.1,36.5]

b['imported_assets']=sorted(set(b['imported_assets'])|{p['asset'] for p in b['props']}|{'BIR_DOCK_PLANKS'})
(OUT/'candidate.json').write_text(json.dumps(b,indent=2))
print(json.dumps({'props':len(b['props']),'cells':sum(b['terrain']['cell_mask']),'deck_cells':sorted(deck),'markers':len(b['gameplay_markers'])}))
