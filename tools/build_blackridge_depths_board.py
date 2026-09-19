"""Prepare the smaller broken cavern arena for authoritative native terrain preparation."""
from pathlib import Path
import copy
import json
import math
import random

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'exports/blackridge_depths'
board=json.loads((ROOT/'boards/belowward_cell.json').read_text())
W,D=46,42
tops=[0.]*(W*D)
mask=[0]*(W*D)
random.seed(31631)


# The upper arc descends by half-metre native treads into the lower ring and lift approach.
def height(x,z):
    if z<=10:
        return 2.
    if z<=14:
        return max(0.,2.-.5*(z-10))
    return 0.


# The ragged outer annulus remains a heightfield with a genuinely empty inner shaft.
for z in range(D):
    for x in range(W):
        dx,dz=x+.5-23,z+.5-19
        outer=(abs(dx)/16+abs(dz)/15<1.69 and abs(dx)<16 and abs(dz)<15)
        # Missing rim stones are broad readable corners, not random holes in the walking route.
        outer=outer and not ((x<12 and z<12) or (x>35 and z>28) or (x<13 and z>29))
        shaft=18<=x<28 and 14<=z<24
        entry=2<=x<13 and 17<=z<25
        if (outer and not shaft) or entry:
            mask[z*W+x]=1
            tops[z*W+x]=height(x,z)

sides={}
for z in range(D):
    for x in range(W):
        if not mask[z*W+x]:
            continue
        h=tops[z*W+x]
        for edge,(dx,dz) in enumerate(((0,-1),(1,0),(0,1),(-1,0))):
            nx,nz=x+dx,z+dz
            if 0<=nx<W and 0<=nz<D and mask[nz*W+nx] and h>tops[nz*W+nx]:
                other=tops[nz*W+nx]
                sides[f'{x},{z},{edge}']=[0.,1.,other,h,other,h]
props=[]


# Literal wall-supported placements preserve authored elevation for void and structural pieces.
def place(asset,x,z,y=None,forward='-Z',wall=False):
    if y is None:
        y=int(height(x,z))
    p={'asset':asset,'origin':[x,y,z],'forward':forward,'roll':0,'yaw':0}
    if wall:
        p.update(support='wall',support_face='+Z')
    props.append(p)


# Cave buttresses stand outside the arena; foreground teeth are intentionally lower cutaway silhouettes.
for index,x in enumerate((7,13,19,25,31,37)):
    place('BD_CAVERN_WALL_CEILING' if index%2 else 'BD_CAVERN_WALL_B',x,0,y=-3,wall=True)
for z in (5,11,27,33):
    place('BD_CAVERN_WALL_A',1,z,y=-6,forward='-X',wall=True)
for z in (6,12,18,24,30):
    place('BD_CAVERN_WALL_B',40,z,y=-5,forward='+X',wall=True)
for x in (10,17,24,31,38):
    place('BD_STALAGMITE_TALL',x,36,y=-7,wall=True)
# Attached stalactite scars overhang only the distant rock wall, never the play camera's central view.

for x,z,y in ((6,9,-3),(7,28,-4),(12,33,-5),(33,33,-5),(37,27,-3),(37,9,-3),
              (18,16,-9),(25,20,-9)):
    place('BD_STALAGMITE_TALL',x,z,y=y,wall=True)
for x,z in ((34,10),(33,26),(12,26),(21,5),(31,29)):
    place('BD_STALAGMITE_LOW',x,z)

# Lift and old prison arch make the descent route explicit at the left landing.
place('BD_ARRIVAL_LIFT',2,19,y=0)
place('BD_RUINED_LANDING_ARCH',5,16,y=0)

# Single connected chain-anchor assembly binds the central horror to four masonry piers.
place('BD_CHAINED_ABOMINATION',14,11,y=-2,wall=True)
for x,z in ((16,7),(30,8),(15,28),(32,24)):
    place('BD_CANDLE_SHRINE',x,z)
for x,z in ((28,5),(34,18),(34,20),(17,31),(25,32)):
    place('BW_BROKEN_COPING_WORN',x,z)
for x,z in ((13,8),(32,7),(35,23),(29,29),(10,18)):
    place('BW_RUBBLE_WORN',x,z)
for x,z in ((13,17),(31,17),(20,29)):
    place('BW_DEBRIS_FLAT_WORN',x,z)
for x,z in ((5,18),(11,23),(32,10)):
    place('BW_CRATE_IRON_BOUND',x,z)
place('BW_BARREL_CLUSTER',8,17)
place('BW_MESHY_SKELETAL_RACK',35,14)

lights=[]


# Eight native pools keep pale void-light distinct from the quiet amber ritual flames.
def light(name,x,z,y,color,energy,radius):
    lights.append({'name':name,'type':0,'enabled':True,'surface_position':[x,y,z],
      'height_offset':0.,'rotation_degrees':[-45.,0.,0.],'projector_path':'',
      'color':color,'intensity':energy,'radius':radius,'attenuation':1.4,
      'shadow':0,'light_size':.15,'spot_angle':45.,'spot_attenuation':1.})


light('Madness below the stone',23,19,-3,[.45,.86,.68],7.,16.)
light('Eastern cavern breath',38,23,-4,[.35,.78,.64],5.,15.)
light('Western cavern breath',8,29,-4,[.35,.78,.64],4.,14.)
light('Iron lift lanterns',5,19,4,[1.,.46,.14],3.,10.)
light('Northwest binding candles',16,8,4,[1.,.44,.12],3.2,9.)
light('Northeast binding candles',31,9,4,[1.,.44,.12],3.2,9.)
light('Southern binding candles',16,28,3,[1.,.44,.12],3.,10.)
light('Southeast binding candles',33,25,3,[1.,.44,.12],2.5,9.)

board.update(name='Blackridge Depths',biome='Blackridge Underholm - The Chained Abomination',surfaces=[],props=props,
    imported_assets=sorted(set(p['asset'] for p in props)|{'BW_FLAGSTONES_WORN','BW_ASHLAR_VARIED'}),
    monster_visuals=[],particle_effects=[{'placement_id':'depths_void_breath','preset_id':'FISSURE_MIST','position':[23,-8,19],'attachment':'world','enabled':True}],
    enemy_packs=[{'id':'depths_binding','note':'Existing class encounter staged around the environmental source of madness.'}],gameplay_markers=[],terrain={'origin_cell':[0,0],'size_cells':[W,D],
      'cell_mask':mask,'top_heights':[h for h in tops for _ in range(4)],'top_diagonals':[0]*(W*D),
      'side_faces':sides,'skirt_depth_m':13.},
    surface_material_paint={'version':3,'surfaces':[],'material_slots':[]})
board['lighting'].update(sun_energy=.57,sun_color=[.51,.65,.82],ambient_energy=.55,
    ambient_color=[.27,.39,.48],background_color=[.004,.008,.01],lights=lights)


# Canonical roster markers stage an arena playtest; the bespoke horror is an environmental focal.
def marker(id,type,x,z,monster='',note=''):
    board['gameplay_markers'].append({'id':id,'type':type,'origin':[x,int(tops[z*W+x]),z],
      'monster':monster,'pack':'depths_binding' if monster else '', 'note':note or id.replace('_',' ')})


for id,x,z in (('player_fighter',6,20),('player_mage',6,22),('player_priest',8,20),('player_rogue',8,22)):
    marker(id,'player_spawn',x,z,note='The party disembarks from the cable lift descending from Belowward Cell.')
for id,monster,x,z in (
    ('sedator_nw','sedator',17,9),('sedator_ne','sedator',33,11),('sedator_sw','sedator',17,27),('sedator_se','sedator',31,26),
    ('blackstick_w','blackstick',15,18),('blackstick_e','blackstick',33,20),
    ('catcher_n','catcher',24,9),('catcher_s','catcher',24,29),('warden_remnant','elias',28,10),
    ('bound_handler','handler/mage',29,27)):
    marker(id,'enemy',x,z,monster)
marker('arrival_from_belowward','objective',7,21,note='Arrival/return landing: twin-cable lift to Belowward Cell. Visible travel motif; interaction handled by the dungeon connection pass.')
marker('sever_the_north_binding','objective',23,12,note='Inspect the binding mechanisms. The cage-headed horror is a static art focal; this playtest uses existing combat classes.')
marker('face_the_source','objective',23,26,note='The source of the prisoners madness rises through the open center of the broken prison foundation.')
(OUT/'board_candidate.json').write_text(json.dumps(board,indent=2))
(OUT/'layout_summary.json').write_text(json.dumps({'cells':sum(mask),'props':len(props),'bounds':[W,D],'entry':[7,0,21],'boss_is_environmental':True},indent=2))
print(json.dumps({'cells':sum(mask),'props':len(props),'markers':len(board['gameplay_markers'])}))
