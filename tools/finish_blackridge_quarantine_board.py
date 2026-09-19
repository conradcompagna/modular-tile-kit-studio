"""Preserve the saved BQ board and add a small connected containment threshold."""
from pathlib import Path
import json

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'exports/blackridge_quarantine'
source=ROOT/'boards/blackridge_quarantine.json'
backup=OUT/'board_before_finish_pass04.json'
if not backup.exists():
    backup.write_bytes(source.read_bytes())
board=json.loads(backup.read_text())


# Use the native measured two-metre rail footprint, leaving the eight-metre stair opening clear.
def prop(asset,x,y,z):
    board['props'].append({'asset':asset,'origin':[x,y,z],'forward':'-Z','roll':0,'yaw':0})


for x in list(range(10,20,2))+list(range(28,36,2)):
    prop('BW_RAILING_WORN',x,1,26)
prop('BI_HOLDING_BENCH',4,2,19)
prop('BW_CRATE_IRON_BOUND',4,2,16)
prop('BI_HOLDING_BENCH',36,2,20)
board['imported_assets']=sorted(set(board['imported_assets'])|{p['asset'] for p in board['props']})
(OUT/'board_candidate.json').write_text(json.dumps(board,indent=2))
print(json.dumps({'props':len(board['props']),'markers':len(board['gameplay_markers'])}))
