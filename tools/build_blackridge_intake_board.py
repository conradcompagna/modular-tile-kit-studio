"""Author the Blackridge Intake Hall as a native one metre BoardDocument candidate."""
from pathlib import Path
import copy
import json
import random


ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "exports" / "blackridge_intake"
OUT.mkdir(parents=True, exist_ok=True)
random.seed(11743)

# The approved Belowward default is only a schema/template source; the intake board owns
# a new name, terrain, placements, lighting and marker set in its BI namespace.
board = json.loads((ROOT / "exports" / "belowward_cell" / "default_board.json").read_text(encoding="utf8"))
W, D = 44, 42
tops = [0.0] * (W * D)
mask = [0] * (W * D)


def height(x: int, z: int) -> float:
    """Return the intake's stepped gallery elevation for the one metre terrain cell."""
    if z <= 8:
        return 4.0
    if 9 <= z <= 16 and (19 <= x < 23 or 33 <= x < 37):
        return 4.0 - 0.5 * (z - 8)
    if z <= 10:
        return 4.0
    if 12 <= x < 24 and 26 <= z < 40:
        return 2.0
    if 13 <= x < 17 and 22 <= z < 26 and not (x == 13 and z == 22):
        return 0.5 * (z - 21)
    return 0.0


def is_playable(x: int, z: int) -> bool:
    """Keep the masonry envelope continuous while leaving one real central shaft absent."""
    if not (2 <= x < 42 and 2 <= z < 40):
        return False
    if 27 <= x < 37 and 17 <= z < 29:
        return False
    return True


for z in range(D):
    for x in range(W):
        if is_playable(x, z):
            mask[z * W + x] = 1
            tops[z * W + x] = height(x, z)

# Native side faces close the visible risers at the half-metre gallery transitions.
sides = {}
for z in range(D):
    for x in range(W):
        if not mask[z * W + x]:
            continue
        current = tops[z * W + x]
        for edge, (dx, dz) in enumerate(((0, -1), (1, 0), (0, 1), (-1, 0))):
            nx, nz = x + dx, z + dz
            if not (0 <= nx < W and 0 <= nz < D) or not mask[nz * W + nx]:
                continue
            neighbour = tops[nz * W + nx]
            if current > neighbour:
                sides[f"{x},{z},{edge}"] = [0.0, 1.0, neighbour, current, neighbour, current]

props = []


def place(asset: str, x: int, z: int, y: float | None = None, forward: str = "-Z", support_face: str = "") -> None:
    """Append a literal prop placement; the native importer remains the occupancy authority."""
    if y is None:
        y = height(x, z)
    prop = {"asset": asset, "origin": [x, y, z], "forward": forward, "roll": 0, "yaw": 0}
    if support_face:
        prop.update({"support": "wall", "support_face": support_face})
    props.append(prop)


lights = []


def light(name: str, x: float, z: float, y: float, color=(1.0, 0.47, 0.16), energy: float = 3.0, radius: float = 9.0) -> None:
    """Add one authored local pool while reserving green contamination for the shaft."""
    lights.append({
        "name": name,
        "type": 0,
        "enabled": True,
        "surface_position": [x, y, z],
        "height_offset": 0.0,
        "rotation_degrees": [-45.0, 0.0, 0.0],
        "projector_path": "",
        "color": list(color),
        "intensity": energy,
        "radius": radius,
        "attenuation": 1.4,
        "shadow": 0,
        "light_size": 0.15,
        "spot_angle": 45.0,
        "spot_attenuation": 1.0,
    })




# Director pass 02 replaces the disconnected study with a connected holding hall.
cells = ("BI_CELL_A1", "BI_CELL_A2", "BI_CELL_B1")

# Cell backs abut continuous native masonry strips; the north gate has a real rear passage.
for x in range(2, 26, 4):
    place(cells[(x // 4) % 3], x, 2, y=4)
place("BI_AUTHORITY_GATE", 28, 2, y=4)
place("BI_AUTHORITY_BANNER", 25, 4, y=4, support_face="+Z")
for z in (6, 14, 26, 30, 34):
    place(cells[(z // 4) % 3], 2, z, forward="+X")
for z in (6, 14, 18, 22, 26, 30, 34):
    place(cells[(z // 4) % 3], 40, z, forward="-X")
place("BW_OPEN_GATE_PASSAGE", 2, 20, forward="+X")
place("BW_PIER_WORN", 2, 19)
place("BW_PIER_WORN", 2, 24)

# The low southern holding wing encloses the arrival hall without screening the whole view.
for x in (4, 8, 12, 16, 20, 24, 28, 32, 36):
    place("BW_LOW_CELL_WORN", x, 39, forward="+Z")
for x in (12, 16, 20):
    place(cells[(x // 4) % 3], x, 34, y=2, forward="-Z")
for x in (12, 14, 16, 18, 20, 22):
    place("BW_RAILING_WORN", x, 26, y=2)
# Entry onto the holding platform is a four-metre opening above a localized stair.
props[:] = [p for p in props if not (p["asset"] == "BW_RAILING_WORN" and p["origin"][2] == 26 and p["origin"][0] in (12, 14, 16))]
for z in (28, 30, 32):
    place("BW_RAILING_WORN", 12, z, y=2, forward="+X")
    place("BW_RAILING_WORN", 23, z, y=2, forward="-X")
place("BI_HOLDING_BENCH", 16, 32, y=2)
place("BW_CRATE_IRON_BOUND", 21, 32, y=2)

# Upper gallery balustrades stop only at the two stair mouths. Cell fronts below the
# gallery make the four-metre retaining wall read as inhabited stacked architecture.
for x in tuple(range(4, 18, 2)) + tuple(range(24, 32, 2)) + (38,):
    place("BW_RAILING_WORN", x, 10, y=4)
for x in (4, 8, 12, 24, 28):
    place("BW_LOW_CELL_WORN", x, 11, y=0)

# Gate flanks, records and a proper sculpted desk make a single authority vignette.
place("BQ_WARDEN_MONUMENT", 27, 6, y=4)
place("BQ_WARDEN_MONUMENT", 38, 6, y=4)
place("BI_RECORDS_SHELF", 5, 6, y=4)
place("BI_RECORDS_SHELF", 14, 6, y=4)
place("BI_REGISTRY_WORKSTATION", 30, 6, y=4)
place("BI_PROPERTY_CART", 24, 7, y=4)

# An L-shaped registry partition organizes the arrival square into a real queue and
# clerks' station. Rail/cell endpoints meet; the gate opening remains a tactical lane.
for z in (15, 17):
    place("BW_RAILING_WORN", 13, z, forward="+X")
place("BW_OPEN_GATE_PASSAGE", 13, 19, forward="+X")
for x in (14, 16, 18):
    place("BW_RAILING_WORN", x, 15)
place("BI_RECORDS_SHELF", 17, 16)
place("BI_REGISTRY_WORKSTATION", 17, 19)
place("BI_HOLDING_BENCH", 6, 17)
place("BI_HOLDING_BENCH", 6, 25)
place("BI_PROPERTY_CART", 9, 29)
place("BW_CRATE_IRON_BOUND", 10, 27)
place("BW_BARREL_CLUSTER", 5, 31)

# Continuous shaft coping and a complete load-bearing beam/cage assembly replace the
# orphan chain. The beam is anchored into the east shaft's native masonry face.
for z in range(17, 29, 2):
    place("BW_RAILING_WORN", 26, z, forward="+X")
    place("BW_RAILING_WORN", 37, z, forward="-X")
for x in range(27, 37, 2):
    place("BW_RAILING_WORN", x, 16)
    place("BW_RAILING_WORN", x, 29)
place("BI_DESCENT_ARCH", 29, 33, forward="+Z")
place("BW_CAGE_SUSPENSION_2", 34, 22, y=-10, forward="+X", support_face="-X")

# Measured one-cell posts bridge the absent corner cells between perpendicular runs.
props[:] = [p for p in props if not (p['asset']=='BW_RAILING_WORN' and p['origin'] in ([13,0,15],[22,2,26]))]
for x,z,y in ((26,16,0),(37,16,0),(26,29,0),(37,29,0),(23,27,2),(12,27,2),(20,15,0),(13,15,0),(13,16,0),(22,26,2),(23,26,2)):
    place("BI_RAIL_JUNCTION",x,z,y=y)

# Compact pools make functional stations legible; contamination is held below the rim.
for x, z, y in ((6, 5, 4), (14, 5, 4), (25, 6, 4), (37, 5, 4),
                 (4, 15, 0), (4, 28, 0), (39, 14, 0), (39, 30, 0),
                 (18, 17, 0), (17, 33, 2), (29, 35, 0)):
    place("BW_LANTERN_CAGED", x, z, y=y)
    if (x, z) in ((6, 5), (25, 6), (37, 5), (4, 28), (18, 17), (17, 33), (29, 35)):
        light("Intake lantern", x + .5, z + .5, y + 2.1, energy=2.4, radius=7)
light("Shaft depth", 32, 23, -6, color=(.22, .56, .43), energy=2.5, radius=8)
for x, z in ((5, 35), (7, 33), (23, 16), (24, 30), (36, 36)):
    place("BW_DEBRIS_FLAT_WORN", x, z)

# Close the cell backs and corner returns with the same canonical terrain material.
# These are real heightfield masses, with no overlapping second terrain representation.
for z in range(2, 40):
    for x in (1, 42):
        if x == 1 and 20 <= z < 24:
            continue
        mask[z * W + x] = 1
        tops[z * W + x] = height(x, z) + 5
for x in range(1, 43):
    if not 30 <= x < 38:
        mask[W + x] = 1
        tops[W + x] = 9
# Explicit passage floor behind the authority gate, with an architectural back limit.
for x in range(30, 38):
    mask[1 * W + x] = 1
    tops[1 * W + x] = 4
# A short dark continuation has literal floor and masonry cheek walls behind the gate.
for x in range(30,38):
    mask[x]=1
    tops[x]=4 if 31 <= x < 37 else 8

# Rebuild native vertical faces after the enclosure masses change the source heights.
sides.clear()
for z in range(D):
    for x in range(W):
        if not mask[z * W + x]:
            continue
        current = tops[z * W + x]
        for edge, (dx, dz) in enumerate(((0, -1), (1, 0), (0, 1), (-1, 0))):
            nx, nz = x + dx, z + dz
            if 0 <= nx < W and 0 <= nz < D and mask[nz * W + nx]:
                neighbour = tops[nz * W + nx]
                if current > neighbour:
                    sides[f"{x},{z},{edge}"] = [0.0, 1.0, neighbour, current, neighbour, current]


def marker(identifier: str, marker_type: str, x: int, z: int, monster: str = "", note: str = "") -> None:
    """Write a gameplay marker at a real standing cell with no hidden level offset."""
    board["gameplay_markers"].append({
        "id": identifier,
        "type": marker_type,
        "origin": [x, int(tops[z * W + x]), z],
        "monster": monster,
        "pack": "intake_ward" if monster else "",
        "note": note or identifier.replace("_", " "),
    })


# Markers tell the runtime the intended flow: quarantine arrival, registration pressure, then
# the shaft descent. Their coordinates are all on filled terrain cells.
for identifier, x, z in (("player_fighter", 5, 20), ("player_mage", 5, 22), ("player_priest", 7, 20), ("player_rogue", 7, 22)):
    marker(identifier, "player_spawn", x, z, note="The party arrives from the quarantine gate into intake registration.")
for identifier, monster, x, z in (
    ("upper_sedator_w", "sedator", 11, 7),
    ("upper_sedator_e", "sedator", 34, 8),
    ("holding_catcher", "catcher", 12, 15),
    ("holding_blackstick", "blackstick", 32, 15),
    ("warden_elias", "elias", 29, 8),
    ("intake_handler", "handler/mage", 38, 31),
):
    marker(identifier, "enemy", x, z, monster)
marker("arrive_from_quarantine", "objective", 7, 21, note="Reach the intake registry after crossing the quarantine gate.")
marker("find_the_warden_records", "loot", 6, 8, note="The registration ledgers identify the prison's compromised ward.")
marker("descend_to_belowward", "objective", 31, 31, note="Take the small lift through the southeast shaft toward Belowward Cell.")

board.update(
    name="Blackridge Intake",
    biome="Blackridge Underholm - Upper Intake Hall",
    surfaces=[],
    props=props,
    imported_assets=sorted({prop["asset"] for prop in props} | {"BW_FLAGSTONES_WORN", "BW_ASHLAR_VARIED"}),
    monster_visuals=[],
    particle_effects=[],
    enemy_packs=[{"id": "intake_ward", "note": "Wardens and compromised prisoners contest the registry galleries and shaft approach."}],
    terrain={
        "origin_cell": [0, 0],
        "size_cells": [W, D],
        "cell_mask": mask,
        "top_heights": [h for h in tops for _ in range(4)],
        "top_diagonals": [0] * (W * D),
        "side_faces": sides,
        "skirt_depth_m": 12.0,
    },
    surface_material_paint={"version": 3, "surfaces": [], "material_slots": []},
)

# The native material stack keeps the exact cool masonry/slab family used by Belowward while
# the BI banner and warm lighting provide the institutional tier's restrained identity.
layers = []
for index, asset in enumerate(("BW_FLAGSTONES_WORN", "BW_ASHLAR_VARIED")):
    layer = copy.deepcopy(board["material_blend"]["layers"][0])
    layer.update(enabled=True, asset_id=asset, application_mode=1, texture_scale_percent=100.0 if index == 0 else 82.0)
    layer["masks"][0].update(source=11, range_low_percent=50.0 if index else 0.0, range_high_percent=100.0, softness_percent=0.0, invert=bool(index))
    layers.append(layer)
board["material_blend"].update(enabled=True, blend_mode=0, layers=layers, paint_texels_per_metre=16)
board["lighting"].update(
    sun_energy=0.59,
    sun_color=[0.51, 0.65, 0.82],
    sun_azimuth_degrees=-35.0,
    sun_elevation_degrees=58.0,
    ambient_energy=0.56,
    ambient_color=[0.27, 0.39, 0.48],
    background_color=[0.006, 0.009, 0.013],
    sun_shadow_opacity=0.88,
    ssao_enabled=True,
    ssao_radius=0.85,
    ssao_intensity=2.1,
    ssao_power=1.5,
    ssil_enabled=True,
    ssil_intensity=0.65,
    ssil_radius=4.0,
    glow_enabled=True,
    glow_intensity=0.6,
    glow_bloom=0.05,
    fog_enabled=False,
    fog_density=0.0,
    fog_color=[0.22, 0.43, 0.38],
    fog_height_m=-8.0,
    fog_height_density=0.12,
    volumetric_fog_enabled=False,
    lights=lights,
)
board["aesthetics"].update(contact_grime=0.72, contact_grime_darkening=0.24)
(OUT / "board_candidate.json").write_text(json.dumps(board, indent=2), encoding="utf8")
(OUT / "layout_summary.json").write_text(json.dumps({"cells": sum(mask), "props": len(props), "bounds": [W, D], "shaft": [27, 17, 10, 12], "markers": len(board["gameplay_markers"])}, indent=2), encoding="utf8")
print(json.dumps({"cells": sum(mask), "dimensions_m": [W, D], "props": len(props), "lights": len(lights), "markers": len(board["gameplay_markers"])}))
