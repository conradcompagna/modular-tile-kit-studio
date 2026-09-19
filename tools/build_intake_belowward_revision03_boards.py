"""Apply only the revision03 user-requested prop changes to checkpointed native board documents."""
from pathlib import Path
import json
ROOT=Path(__file__).resolve().parents[1]
for level,folder in [('blackridge_intake','blackridge_intake_revision03'),('belowward_cell','belowward_revision03')]:
    out=ROOT/'exports'/folder
    board=json.loads((out/'before.json').read_text())
    props=[]
    for prop in board['props']:
        asset=prop['asset']
        if asset=='BW_BARREL_CLUSTER':prop['asset']='BR3_BARREL_CLUSTER'
        if level=='blackridge_intake':
            if asset=='BIR_AUTHORITY_DOOR':prop['asset']='BI3_AUTHORITY_DOOR'
            elif asset=='BI_AUTHORITY_BANNER':prop['asset']='BI3_AUTHORITY_STANDARD'
            elif asset=='BIR_CENSUS_ENGINE':
                prop['asset']='BI3_PANOPTICON_STELE';prop['origin']=[20,0,21]
            elif asset=='BIR_SERVICE_DOOR':continue
            elif asset=='BW_LANTERN_CAGED' and prop['origin']==[28,0,36]:continue
        elif asset=='BC_CENTRAL_CABLE_FERRY':
            prop['asset']='BC3_CENTRAL_CABLE_FERRY';prop['origin']=[11,-3,20]
        props.append(prop)
    board['props']=props
    if level=='blackridge_intake':
        # Removing the freestanding false exit exposes only the existing supported apron; the real rear wall remains continuous.
        board['lighting']['lights']=[light for light in board['lighting']['lights'] if not(light['surface_position'][0]==28.5 and light['surface_position'][2]==36.5)]
        for light in board['lighting']['lights']:
            if light['name']=='Census Engine lantern':light['name']='Panopticon stele lantern'
    board['imported_assets']=sorted(set(board['imported_assets'])|{p['asset'] for p in props})
    (out/'candidate.json').write_text(json.dumps(board,indent=2))
    print(json.dumps({'level':level,'props':len(props),'markers':len(board['gameplay_markers']),'terrain_unchanged':True}))
