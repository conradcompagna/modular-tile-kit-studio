"""Derive a new native board from the Blender-authored quad and prop records."""
from pathlib import Path
import json

ROOT=Path(__file__).resolve().parents[1]
SOURCE=ROOT/'exports'/'angel_gate_blender_source'/'board_source.json'
OUT=ROOT/'exports'/'angel_gate_blender_source'/'board_candidate.json'
source=json.loads(SOURCE.read_text())
previous=json.loads((ROOT/'boards'/'angel_gate.json').read_text())
aliases={'AGB_ANGEL':'ANGEL_GATE_CONQUERING_ANGEL','AGB_PALAZZO':'ANGEL_GATE_PALAZZO','AGB_ARCH':'ANGEL_GATE_ARCH'}
props=[dict(p,asset=aliases.get(p['asset'],p['asset'])) for p in source['props']]
w,d=source['size']
board={k:previous[k] for k in ('version','aesthetics','lighting','material_blend','movement_grid')}
board.update(name='Angel Gate - Blender',biome='The conquerors threshold',surfaces=[],props=props,
    imported_assets=sorted(set(p['asset'] for p in props)),monster_visuals=[],particle_effects=[],
    surface_material_paint={'version':3,'surfaces':[],'material_slots':[]},
    terrain={'origin_cell':[0,0],'size_cells':[w,d],'cell_mask':[1]*(w*d),
        'top_heights':source['top_heights'],'top_diagonals':[0]*(w*d),
        'side_faces':source['side_faces'],'skirt_depth_m':1.0})
palette=['AGB_COBBLE','ANGEL_GATE_ANCIENT_ASHLAR','AGB_PLASTER','AGB_ROOF','ANGEL_GATE_IMPERIAL_PAVING']
layers=[]
for i,id in enumerate(palette):
    layer=json.loads(json.dumps(previous['material_blend']['layers'][0]))
    layer['asset_id']=id
    layer['masks'][0]['paint_channel']=i
    layers.append(layer)
board['material_blend']['layers']=layers
board['material_blend']['blend_mode']=1
board['material_blend']['enabled']=True
board['imported_assets']=sorted(set(board['imported_assets']+palette))
light=board['lighting']
light.update(sun_azimuth_degrees=-34.,sun_elevation_degrees=49.,sun_color=[1.,.85,.68],sun_energy=1.15,
    ambient_color=[.53,.64,.76],ambient_energy=.65,background_color=[.021,.029,.039],
    sun_shadow_opacity=.85,ssao_intensity=1.5,ssao_radius=.8,ssao_power=1.4,
    ssil_enabled=True,ssil_intensity=.65,ssil_radius=4.)
template=previous['lighting']['lights'][0]
local=[]
for name,pos,height,intensity,radius,color in [
    ('Imperial court',[24.,1.5,6.],8.,3.0,17.,[1.,.85,.62]),
    ('Angel votives',[19.,1.5,22.],2.5,1.2,7.,[1.,.60,.29]),
    ('Market lantern',[12.8,0.,23.5],3.1,1.15,5.,[1.,.47,.18]),
    ('East lantern',[27.8,0.,23.5],3.1,1.2,5.,[1.,.47,.18]),
    ('Gate lantern',[22.8,0.,18.5],3.1,1.0,5.,[1.,.55,.22]),
    ('Lower lantern',[16.8,0.,27.5],3.1,1.1,5.,[1.,.47,.18])]:
    record=dict(template,name=name,surface_position=pos,height_offset=height,intensity=intensity,radius=radius,color=color)
    local.append(record)
light['lights']=local
board['enemy_packs']=[{'id':'gate_tithe','note':'Gate guards, rooftop archers and the imperial tax retinue.'}]
board['gameplay_markers']=[]
for id,x,z in [('player_mage',19,31),('player_priest',20,31),('player_fighter',19,30),('player_rogue',20,30)]:
    board['gameplay_markers'].append({'id':id,'type':'player_spawn','origin':[x,0,z],'note':'Authored deployment'})
for id,monster,x,z in [('gate_guard_west','sedator',22,20),('gate_guard_east','sedator',25,20),
    ('roof_marksman_west','sedator',12,18),('roof_marksman_east','sedator',30,21),
    ('market_patrol','blackstick',11,24),('road_patrol','blackstick',25,28),
    ('monument_enforcer','catcher',17,26),('gate_enforcer','catcher',28,17),
    ('tithe_master','elias',23,8),('chained_retinue','handler/mage',22,10)]:
    height=sum(source['top_heights'][(z*w+x)*4:(z*w+x)*4+4])/4
    board['gameplay_markers'].append({'id':id,'type':'enemy','monster':monster,'origin':[x,round(height),z],'pack':'gate_tithe','note':id.replace('_',' ')})
# A candidate is opened through the editor's atomic loader before any live board is saved.
OUT.write_text(json.dumps(board,indent=2))
print(json.dumps({'board':str(OUT),'cells':w*d,'props':len(props),'palette':palette}))
