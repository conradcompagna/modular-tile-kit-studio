"""Author a compact set of purposeful laboratory furnishings for the four Quarantine pens."""
from pathlib import Path
import json
import math
import bpy

ROOT=Path(__file__).resolve().parents[1]
recipe=ROOT/'tools/build_bq3_architecture.py'
exec(compile(recipe.read_text().split('# Six adjoining lots')[0],str(recipe),'exec'))
JADE=material('BQ3 clouded jade specimen glass',(.12,.23,.18),metallic=.15,rough=.29)
AMBER=material('BQ3 stained amber medicine glass',(.25,.12,.035),metallic=.08,rough=.32)
LINEN=material('BQ3 stained linen bandage',(.36,.32,.22),rough=.98)
CERAMIC=material('BQ3 worn ivory enamel',(.40,.42,.35),rough=.48)


# Give each sealed specimen a visibly attached cap and restrained institutional label.
def bottle(x,z,y,h,mat):
    lathe('Sealed specimen jar',[(.10,0),(.12,.04),(.12,h-.09),(.08,h-.04),(.08,h)],(x,z,y),mat,16)
    lathe('Jar metal seal',[(.088,0),(.088,.035),(.078,.05)],(x,z,y+h-.008),BRASS,14)
    box('Ivory specimen label',(x-.054,z+.105,y+h*.35),(x+.054,z+.121,y+h*.65),LINEN,.003,False)


# Keep the mobile cart's four wheels, legs, shelves and instruments on one compact grounded assembly.
box('Cart lower iron frame',(0,0,.14),(1,1,.22),IRON,.016,False)
for x in (.10,.90):
    for z in (.10,.90):
        lathe('Cart grounded wheel',[(.085,0),(.10,.035),(.10,.12),(.085,.15)],(x,z,0),IRON,16)
        beam('Cart upright',(x,z,.15),(x,z,.89),.052,IRON)
for h in (.30,.79):
    box('Oak instrument cart shelf',(.045,.045,h),(.955,.955,h+.065),WOOD,.011,False)
for x in (.025,.945):
    box('Tray raised rim',(x,.025,.85),(x+.03,.975,.94),BRASS,.004,False)
for z in (.025,.945):
    box('Tray end rim',(.025,z,.85),(.975,z+.03,.94),BRASS,.004,False)
for i,(x,z,h) in enumerate(((.22,.24,.29),(.51,.22,.35),(.79,.24,.26),(.26,.68,.33),(.61,.66,.30))):
    bottle(x,z,.855,h,JADE if i%2 else AMBER)
for i in range(3):
    box('Rolled sterilized linen',(.15+i*.22,.35,.375),(.31+i*.22,.65,.53),LINEN,.04,False)
finish_literal('alchemy_cart')


# A locked sample cupboard supports jars behind its own integral protective grille.
box('Locked samples footing',(0,0,0),(1,.75,.14),IRON,.015,False)
box('Locked samples back',(.04,.02,.12),(.96,.12,1.50),WOOD,.013,False)
for x in (.02,.88):
    box('Sample cupboard side',(x,.02,.12),(x+.10,.72,1.50),WOOD,.012,False)
for h in (.14,.65,1.12,1.44):
    box('Sample cupboard shelf',(.05,.05,h),(.95,.73,h+.06),WOOD,.009,False)
for yy in (.71,1.18):
    for i,xx in enumerate((.24,.50,.76)):
        bottle(xx,.42,yy,.23,JADE if i%2 else AMBER)
for x in (.08,.29,.50,.71,.92):
    beam('Integral cupboard grille',(x,.745,.24),(x,.745,1.44),.035,IRON)
for h in (.25,.84,1.43):
    beam('Cupboard grille cross tie',(.065,.745,h),(.94,.745,h),.042,IRON)
box('Cupboard lock plate',(.40,.76,.77),(.60,.805,.98),BRASS,.007,False)
finish_literal('locked_samples')


# The wash station keeps basin, pipe and linen on an obvious load-bearing floor stand.
box('Wash stand feet',(0,0,0),(1,1,.12),IRON,.016,False)
for x in (.13,.87):
    for z in (.14,.86):
        beam('Wash stand leg',(x,z,.10),(x,z,.78),.06,IRON)
box('Wash stand shelf',(.06,.06,.27),(.94,.94,.32),WOOD,.01,False)
lathe('Broad enamel wash basin',[(.32,0),(.42,.12),(.44,.23),(.40,.26),(.37,.21),(.31,.08),(.15,.03)],(.5,.5,.68),CERAMIC,28)
beam('Supported basin tap pipe',(.83,.27,.31),(.83,.27,1.20),.05,BRASS)
beam('Basin swan neck',(.83,.27,1.20),(.54,.39,1.20),.045,BRASS)
beam('Downturned tap',(.54,.39,1.20),(.54,.39,1.10),.045,BRASS)
box('Folded linen on shelf',(.18,.19,.33),(.56,.72,.46),LINEN,.026,False)
bottle(.73,.62,.33,.24,AMBER)
finish_literal('wash_station')

(OUT/'furnishing_kit.json').write_text(json.dumps(ASSETS,indent=2))
bpy.ops.wm.save_as_mainfile(filepath=str(OUT/'bq3_pen_furnishings.blend'))
print('BQ3_FURNISHINGS_COMPLETE',flush=True)
