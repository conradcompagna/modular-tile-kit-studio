"""Prepare revision03 through explicit native heightfield and prop-placement candidates."""
from pathlib import Path
import copy
import json

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'exports/blackridge_quarantine_revision03'
board=json.loads((OUT/'board_before_revision03.json').read_text())
terrain=board['terrain']; w,d=terrain['size_cells']; ox,oz=terrain['origin_cell']
changed_support=[]


# Keep complete flat native support under the continuous stepped masonry foundations.
def index(x,z):
    return (z-oz)*w+x-ox


for z in range(3,39):
    for xs,donor in ((range(-6,0),0),(range(46,52),45)):
        donor_idx=index(donor,z)
        native_heights=terrain['top_heights'][donor_idx*4:donor_idx*4+4]
        assert terrain['cell_mask'][donor_idx] and len(set(native_heights))==1
        for x in xs:
            idx=index(x,z)
            terrain['cell_mask'][idx]=1
            terrain['top_heights'][idx*4:idx*4+4]=[0.0]*4
            changed_support.append({'cell':[x,z],'height':0.0,'adjacent_street_height':native_heights[0]})
terrain['side_faces']={}
for z in range(oz,oz+d):
    for x in range(ox,ox+w):
        idx=index(x,z)
        if not terrain['cell_mask'][idx]: continue
        h=terrain['top_heights'][idx*4]
        for edge,(dx,dz) in enumerate(((0,-1),(1,0),(0,1),(-1,0))):
            xx,zz=x+dx,z+dz
            if not(ox<=xx<ox+w and oz<=zz<oz+d): continue
            j=index(xx,zz)
            if terrain['cell_mask'][j] and h>terrain['top_heights'][j*4]:
                other=terrain['top_heights'][j*4]
                terrain['side_faces'][f'{x},{z},{edge}']=[0.0,1.0,other,h,other,h]

replacements={
    'BQR_TENEMENT_ROW_WEST':'BQ3_TENEMENT_ROW_WEST_GROUNDED',
    'BQR_TENEMENT_ROW_EAST':'BQ3_TENEMENT_ROW_EAST_GROUNDED',
    'BQR_PRISON_FACADE':'BQ3_PRISON_FACADE',
    'BQ_REGISTRY_KIOSK':'BQ3_INSPECTION_KIOSK',
    'BW_BARREL_CLUSTER':'BR3_BARREL_CLUSTER',
}
board['props']=[p for p in board['props'] if p['asset']!='BI_HOLDING_BENCH']
for prop in board['props']:
    prop['asset']=replacements.get(prop['asset'],prop['asset'])


# Place intentional equipment groupings around the existing approved specimen silhouettes, rather than loose random clutter.
def place(asset,x,y,z):
    board['props'].append({'asset':asset,'origin':[x,y,z],'forward':'-Z','roll':0,'yaw':0})


place('BW_MESHY_WARDENS_DESK',4,2,15)
place('BQ3_ALCHEMY_CART',6,2,20)
place('BQ3_LOCKED_SAMPLES',11,2,15)
place('BQ3_WASH_STATION',13,2,16)
place('BQ3_LOCKED_SAMPLES',29,2,15)
place('BQ3_ALCHEMY_CART',31,2,20)
place('BW_MESHY_INTERROGATION_FRAME',36,2,17)
place('BW_MESHY_WARDENS_DESK',36,2,15)
place('BQ3_WASH_STATION',38,2,20)

# Preserve house brick on buildings while giving native retaining faces the same material family as the city ground.
board['material_blend']['layers'][1]['asset_id']='BQR_CITY_SETTS'
board['surface_material_paint']={'version':3,'surfaces':[],'material_slots':[]}
lighting=board['lighting']
lighting.update(ambient_energy=.16,ambient_color=[.32,.40,.53],sun_energy=.20,
                sun_color=[.40,.51,.70],sun_elevation_degrees=48.,ssil_intensity=.35,
                fog_color=[.022,.030,.046],fog_density=.0012)
for light in lighting['lights']:
    if light['name']=='Prison doorway amber':
        # Reuse the broad facade-fill slot for the fourth purposeful pen instead of exceeding eight rendered local lights.
        light.update(name='Contained pen contamination 37.5',surface_position=[37.5,5.2,21.5],
                     color=[.70,.85,.72],intensity=2.8,radius=6.2)
    elif light['name'].startswith('Contained pen contamination'):
        light.update(intensity=2.8,radius=6.2)
    elif light['name'].startswith('Quarantine lantern'):
        light.update(intensity=4.5,radius=6.0)
    elif light['name']=='Registration lamp':
        light.update(intensity=4.0,radius=5.5,surface_position=[30.15,2.15,36.1])
board['imported_assets']=sorted({p['asset'] for p in board['props']}|{'BQR_CITY_SETTS'})
(OUT/'board_candidate.json').write_text(json.dumps(board,indent=2))
(OUT/'native_support_candidate.json').write_text(json.dumps(changed_support,indent=2))
(OUT/'pen_vignettes.json').write_text(json.dumps({
    'upright':['BQR_UPRIGHT_SPECIMEN','BW_MESHY_WARDENS_DESK','BQ3_ALCHEMY_CART'],
    'examination':['BQR_OCCULT_TABLE','BQ3_LOCKED_SAMPLES','BQ3_WASH_STATION'],
    'suspended':['BQR_SUSPENDED_HUSK','BQ3_LOCKED_SAMPLES','BQ3_ALCHEMY_CART'],
    'interrogation':['BW_MESHY_INTERROGATION_FRAME','BW_MESHY_WARDENS_DESK','BQ3_WASH_STATION']},indent=2))
print(json.dumps({'props':len(board['props']),'cells':sum(terrain['cell_mask']),'support_cells':len(changed_support),'benches':sum(p['asset']=='BI_HOLDING_BENCH' for p in board['props'])}))
