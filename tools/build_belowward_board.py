"""Author the Belowward Cell as a native 1 m BoardDocument candidate for atomic editor loading."""
from pathlib import Path
import json
import random
import copy

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'exports/belowward_cell'
random.seed(8239)
board=json.loads((OUT/'default_board.json').read_text())
W,D=48,44
tops=[0.0]*(W*D)
mask=[0]*(W*D)


# Gallery elevations are literal half-metre treads on one-metre terrain quads.
def height(x,z):
    if z<=11:
        return 6.
    if z>=33:
        return 0.
    if x<13:
        if z<=17:
            if x<7:
                return 6. if z<15 else 3.
            if x>=11:
                return 6. if z<14 else 3.
            return 6.-.5*(z-11)
        if z>=27:
            if x<7:
                return 3. if z<30 else 0.
            if x>=11:
                return 3. if z<29 else 0.
            return 3.-.5*(z-26)
        return 3.
    if x>=35:
        if z<=15:
            if x<38:
                return 6. if z<14 else 4.
            if x>=42:
                return 6.
            return 6.-.5*(z-11)
        if z>=25:
            if x<38:
                return 4. if z<28 else 0.
            if x>=42:
                return 4. if z<29 else 0.
            return 4.-.5*(z-24)
        return 4.
    return 6.


# The shaft is intentionally absent terrain; no hidden floor or navigation proxy bridges it.
for z in range(2,42):
    for x in range(2,46):
        if 13<=x<35 and 12<=z<33:
            continue
        mask[z*W+x]=1
        tops[z*W+x]=height(x,z)

# A narrow stone spur reaches toward the central inscription as a deliberate dead-end vantage.
for z in range(19,21):
    for x in range(13,16):
        mask[z*W+x]=1
        tops[z*W+x]=3.

sides={}
neighbours=[(0,-1),(1,0),(0,1),(-1,0)]
for z in range(D):
    for x in range(W):
        if not mask[z*W+x]:
            continue
        h=tops[z*W+x]
        for edge,(dx,dz) in enumerate(neighbours):
            nx,nz=x+dx,z+dz
            if not(0<=nx<W and 0<=nz<D) or not mask[nz*W+nx]:
                continue
            other=tops[nz*W+nx]
            if h>other:
                sides[f'{x},{z},{edge}']=[0.,1.,other,h,other,h]

props=[]
kit=json.loads((OUT/'kit.json').read_text())
for name in ('skeletal_rack','wardens_desk','interrogation_frame'):
    kit['meshy_'+name]={'export_name':'meshy_'+name}


# Every prop stores a grid minimum and a literal orientation; the importer owns its source pose.
def place(name,x,z,y=None,forward='-Z'):
    if name=='lantern':
        name='lantern_caged'
    if name=='fissure_mural':
        name='fissure_mural_v2'
    if y is None:
        y=int(height(x,z))
    props.append({'asset':'BW_'+kit[name]['export_name'].upper(),'origin':[x,y,z],'forward':forward,'roll':0,'yaw':0})
    if name=='ledge':
        props[-1].update(support='wall',support_face={ '-X':'+X','+X':'-X','-Z':'+Z'}[forward])
    if name=='fissure_mural_v2':
        props[-1].update(support='wall',support_face='+Z')


# Small warm pools are authored in the same LightingProfile the runtime consumes.
def light(name,x,z,y,color=(1,.47,.16),energy=3,radius=6,shadow=0):
    lights.append({'name':name,'type':0,'enabled':True,'surface_position':[x,y,z],
      'height_offset':0.,'rotation_degrees':[-45.,0.,0.],'projector_path':'',
      'color':list(color),'intensity':energy,'radius':radius,'attenuation':1.4,
      'shadow':shadow,'light_size':.15,'spot_angle':45.,'spot_attenuation':1.})


lights=[]
# Tall north and west prison walls form the reference's enclosing architectural silhouette.
for x in range(3,43,4):
    place('cell_front',x,2)
    if x%8==3:
        place('lantern',x+3,4)
        light('North cell lantern',x+3.5,5.2,8.1)
for z in (6,10,18,22,26,34,38):
    place('cell_front',2,z,forward='-X')
    place('lantern',6 if z==10 else 4,z+2,forward='-X')
    light('West cell lantern',5.1,z+2.5,height(4,z+2)+2.2)

# The east row uses full cells and the near row uses cutaway bars for a readable game view.
for z in (6,10,17,21,25,33,37):
    place('cell_front',43,z,forward='+X')
    place('lantern',41 if z==10 else 42,z+2,forward='+X')
    light('East cell lantern',41.6,z+2.5,height(42,z+2)+2.1)
for x in range(7,43,4):
    place('low_cell',x,41,forward='+Z')
for x in range(2,46,2):
    place('parapet_supported',x,1,y=4)
    props[-1].update(support='wall',support_face='-Z')
    place('parapet_supported',x,42,y=-2,forward='+Z')
    props[-1].update(support='wall',support_face='+Z')

# Inner rails keep edge cells occupied and make the chasm outline legible at tactical zoom.
for x in range(13,35,2):
    if x not in (13,15,25,27):
        place('railing',x,11,y=6)
    if x not in (17,19,29,31):
        place('railing',x,33,y=0)
for z in (14,16,18,22,24,26):
    place('broken_railing' if z==22 else 'railing',12,z,forward='+X')
for z in (14,16,18,20,22,24,26):
    place('railing',35,z,forward='-X')

# Cell gates divide broad gallery landings while leaving the two-metre middle passage open.
for x,z in ((7,10),(38,10),(38,22),(20,37)):
    place('open_gate',x,z)

# The shallow plaster fresco uses the native wall mount to meet the shaft wall exactly.
place('fissure_mural',19,12,y=-6)

# Flush two-metre-thick wall returns join cell rows across the stair height changes.
for z in (4,5,14,15,16,17,30,31,32,33):
    for x in (2,3):
        place('pier',x,z)
for z in (4,5,14,15,16,29,30,31,32):
    for x in (43,44):
        place('pier',x,z)
for z in (2,3):
    place('pier',43,z)
# Lower barred bays retain their facade heights while their closed floors and brackets project below them.
for x,z,y,forward in ((13,14,-3,'-X'),(31,12,-2,'-Z'),(33,22,-5,'+X')):
    place('shaft_cell_floored',x,z,y=y-2,forward=forward)
    props[-1].update(support='wall',support_face={'-X':'+X','-Z':'+Z','+X':'-X'}[forward])
for x,z,y in ((13,12,-6),(13,28,-9),(33,18,-8)):
    place('buttress',x,z,y=y)
for x,z,y,forward in ((13,18,-3,'-X'),(13,23,-6,'-X'),(19,12,2,'-Z'),(23,12,2,'-Z'),(27,12,2,'-Z')):
    place('ledge',x,z,y=y,forward=forward)

# The preserved cage mesh and its anchored support share one measured GLB and native voxel union.
# Wall attachment preserves literal suspended heights rather than snapping them onto nearby galleries.
for name,x,z,y,forward,support_face in (
    ('cage_suspension_5',16,12,-3,'-Z','+Z'),
    ('cage_suspension_5',30,12,-3,'-Z','+Z'),
    ('cage_suspension_5',13,21,-8,'-X','+X'),
    ('cage_suspension_5',29,24,-6,'+X','-X'),
    ('cage_suspension_5',13,25,-7,'-X','+X'),
    ('pillar_cage_suspension',30,29,-10,'-Z','-X'),
    ('cage_suspension_3',24,29,-9,'+Z','-Z')):
    place(name,x,z,y=y,forward=forward)
    props[-1].update(support='wall',support_face=support_face)

# Broken stone teeth rise through the layered haze at deliberately varied depths.
for z in range(14,32,3):
    for x in range(14,34,3):
        cage_positions=((16,16),(30,16),(17,21),(29,24),(17,25),(30,29),(24,29))
        cage_overlap=any(abs(x-cx)<2 and abs(z-cz)<2 for cx,cz in cage_positions)
        cage_overlap=cage_overlap or any(p['asset']=='BW_BUTTRESS_WORN' and abs(x-p['origin'][0])<2 and abs(z-p['origin'][2])<2 for p in props)
        if cage_overlap or (x==14 and z==14) or (z in (17,20) and x<20) or random.random()<.23:
            continue
        spire='spire_tall' if random.random()<.7 else 'spire_short'
        base=random.choice((-14,-12,-10))
        if (x,z)!=(32,23):
            place(spire,x,z,y=base)

# Cover clusters live at the side of routes and in landings, leaving stair lanes clear.
for x,z in ((7,7),(14,6),(25,7),(36,6),(9,19),(7,23),(10,25),(42,17),(37,23),(7,35),(12,38),(22,38),(30,37),(40,36)):
    place('crate',x,z)
for x,z in ((32,6),(5,20)):
    place('meshy_wardens_desk',x,z)
    light('Candle desk',x+1,z+.5,height(x,z)+1.7,energy=1.2,radius=3.8)
for x,z in ((8,21),(28,7),(39,35)):
    place('meshy_skeletal_rack',x,z)
for x,z in ((10,8),(30,9),(5,25),(28,35),(16,37)):
    place('rubble',x,z)

# Set dressing is grouped beside walls and large cover rather than strewn across stair lanes.
for x,z in ((8,5),(17,5),(37,5),(10,18),(5,23),(40,16),(39,33),(8,37),(24,38)):
    place('barrel_cluster',x,z)
for x,z in ((5,17),(37,19)):
    place('meshy_interrogation_frame',x,z,forward='-X')
for x,z in ((4,5),(11,5),(22,5),(33,5),(5,19),(37,17),(40,24),(6,40),(17,40),(27,40),(36,40)):
    place('debris_flat',x,z)

# Crumbled sections replace lengths of intact inner rail and expose varied low edge silhouettes.
for x,z in ((13,11),(25,11),(17,33),(29,33)):
    place('broken_coping',x,z)

# Pale teal uplight is localized inside the fissure, leaving the warm gallery lamps distinct.
for x,z in ((17,16),(24,16),(31,16),(17,25),(25,25),(31,29),(22,30)):
    light('Fissure underlight',x,z,-5,color=(.32,.85,.69),energy=8.0,radius=15.)

# LightingProfile exposes eight local lights; these eight pools are the complete authored rig.
lights=[]
light('Sigil underlight',24,15,-2,color=(.80,.91,.84),energy=9.,radius=15.)
light('West fissure breath',17,25,-5,color=(.34,.82,.68),energy=7.,radius=15.)
light('East fissure breath',30,27,-5,color=(.34,.82,.68),energy=7.,radius=15.)
for name,x,z,y in (('Upper west lamps',8,7,8),('Upper east lamps',30,7,8),
                  ('West prison lamps',6,22,5),('East prison lamps',41,21,6),('Lower prison candles',25,38,2)):
    light(name,x,z,y,energy=3.2,radius=12.)

board.update(name='Belowward Cell',biome='Blackridge Underholm - Lower Prison',surfaces=[],props=props,
    imported_assets=['BW_'+item['export_name'].upper() for item in kit.values()]+['BW_FLAGSTONES_WORN','BW_ASHLAR_VARIED'],
    monster_visuals=[],particle_effects=[],enemy_packs=[],gameplay_markers=[],
    terrain={'origin_cell':[0,0],'size_cells':[W,D],'cell_mask':mask,
      'top_heights':[h for h in tops for _ in range(4)],'top_diagonals':[0]*(W*D),
      'side_faces':sides,'skirt_depth_m':15.},
    surface_material_paint={'version':3,'surfaces':[],'material_slots':[]})

# A procedural material layer selects only by face orientation; no alternate mesh is rendered.
layers=[]
for index,(asset,invert) in enumerate((('BW_FLAGSTONES_WORN',False),('BW_ASHLAR_VARIED',True))):
    layer=copy.deepcopy(board['material_blend']['layers'][0])
    layer.update(enabled=True,asset_id=asset,application_mode=1)
    if index==1:
        layer['texture_scale_percent']=80.
    layer['masks'][0].update(source=11,range_low_percent=50.,range_high_percent=100.,softness_percent=0.,invert=invert)
    layers.append(layer)
board['material_blend'].update(enabled=True,blend_mode=0,layers=layers,paint_texels_per_metre=16)
board['lighting'].update(sun_energy=.6,sun_color=[.51,.65,.82],sun_azimuth_degrees=-35.,sun_elevation_degrees=58.,
    ambient_energy=.58,ambient_color=[.27,.39,.48],background_color=[.006,.01,.014],sun_shadow_opacity=.88,
    ssao_enabled=True,ssao_radius=.85,ssao_intensity=2.2,ssao_power=1.5,
    ssil_enabled=True,ssil_intensity=.7,ssil_radius=4.,glow_enabled=True,glow_intensity=.7,glow_bloom=.06,
    fog_enabled=False,fog_density=0.,fog_color=[.22,.43,.38],fog_height_m=-12.,fog_height_density=.17,
    volumetric_fog_enabled=False,lights=lights)
board['aesthetics'].update(contact_grime=.75,contact_grime_darkening=.22)
board['enemy_packs']=[{'id':'lower_cells','note':'Lower-gallery sentries pressure the west stair and cover the exposed approach.'},
    {'id':'upper_ward','note':'The warden and paired guards hold the upper gallery; the chained pair blocks the eastern route.'}]


# Full marker records use exact content IDs already hydrated by the runtime's unit spawner.
def marker(id,type,x,z,monster='',pack='',note=''):
    board['gameplay_markers'].append({'id':id,'type':type,'origin':[x,int(tops[z*W+x]),z],
      'monster':monster,'pack':pack,'note':note or id.replace('_',' ')})


for id,x,z in (('player_fighter',7,22),('player_mage',9,20),('player_priest',8,18),('player_rogue',10,21)):
    marker(id,'player_spawn',x,z,note='The party enters the lower prison gallery together.')
for id,monster,x,z,pack in (
  ('lower_sedator_w','sedator',8,35,'lower_cells'),('lower_sedator_e','sedator',38,24,'lower_cells'),
  ('upper_sedator_w','sedator',10,7,'upper_ward'),('upper_sedator_e','sedator',36,8,'upper_ward'),
  ('west_blackstick','blackstick',8,26,'lower_cells'),('east_blackstick','blackstick',40,18,'lower_cells'),
  ('west_catcher','catcher',10,35,'lower_cells'),('east_catcher','catcher',37,21,'lower_cells'),
  ('warden_elias','elias',24,8,'upper_ward'),('chains_of_the_void','handler/mage',30,7,'upper_ward')):
    marker(id,'enemy',x,z,monster,pack)
marker('investigate_the_fissure','objective',15,20,note='Reach the narrow stone spur and examine the red inscription.')
marker('reach_the_lower_cells','objective',38,37,note='Search the lower cells after securing both stair approaches.')
marker('wardens_records','loot',33,7,note='The warden records lie beside the candlelit north desk.')

(OUT/'board_candidate.json').write_text(json.dumps(board,indent=2))
print(json.dumps({'cells':sum(mask),'dimensions_m':[W,D],'props':len(props),'lights':len(lights),'markers':len(board['gameplay_markers'])}))
