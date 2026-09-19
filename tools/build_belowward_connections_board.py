"""Apply only the accepted doorway and cable-ferry additions to the preserved native board."""
from pathlib import Path
import json

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'exports/belowward_connections'
board = json.loads((OUT / 'board_before_connections.json').read_text())
for prop in board['props']:
    if prop['asset'] == 'BW_CELL_FRONT_WORN' and prop['origin'] == [2, 3, 22]:
        prop['asset'] = 'BC_ARRIVAL_DOORWAY'
board['props'].append({'asset': 'BC_CENTRAL_CABLE_FERRY', 'origin': [11, -12, 20], 'forward': '-Z', 'roll': 0, 'yaw': 0, 'support': 'wall', 'support_face': '+Z'})
board['imported_assets'] += ['BC_ARRIVAL_DOORWAY', 'BC_CENTRAL_CABLE_FERRY']
board['gameplay_markers'] += [
    {'id': 'arrival_from_intake', 'type': 'trigger', 'origin': [4, 3, 22], 'note': 'Upper intake stair door: arrival from blackridge_intake. Architectural connection only; select the board through the ordinary level selector.', 'monster': '', 'pack': ''},
    {'id': 'recall_depths_cable_ferry', 'type': 'objective', 'origin': [14, 3, 20], 'note': 'Return winch: recall the central cargo car to this west loading spur, then descend to blackridge_depths. The lowered car and cable route are visual; no travel interaction is implemented.', 'monster': '', 'pack': ''},
]
(OUT / 'board_candidate.json').write_text(json.dumps(board, indent=2))
