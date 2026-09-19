"""Author the Blackridge quarantine approach as a native one-metre board candidate."""
from pathlib import Path
import json
import random

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "exports/blackridge_quarantine"
OUT.mkdir(parents=True, exist_ok=True)

# Keep the full BoardDocument schema from the accepted level while authoring a distinct BQ board.
board = json.loads((ROOT / "boards/belowward_cell.json").read_text())
W, D = 46, 42
random.seed(4417)


def height(x: int, z: int) -> float:
    """Return the stepped forecourt height, rising toward the institutional gate."""
    # Each nine-metre pen has one level native masonry foundation, never a stair through its interior.
    if 14 <= z <= 22 and any(a <= x < a+5 for a in (3,10,28,35)):
        return 2.0
    if z <= 9:
        return 3.0
    if z == 10 and 20 <= x <= 27:
        return 2.5
    if z <= 17:
        return 2.0
    if z == 18 and 20 <= x <= 27:
        return 1.5
    if z <= 26:
        return 1.0
    if z == 27 and 20 <= x <= 27:
        return 0.5
    return 0.0


# Preserve a compact city-approach silhouette while leaving the two side alleys and central route clear.
mask = [0] * (W * D)
tops = [0.0] * (W * D)
for z in range(D):
    for x in range(W):
        edge_trim = (x < 2 or x >= W - 2) and z >= 34
        rear_block = (x < 5 or x >= W - 5) and z < 3
        if not edge_trim and not rear_block:
            mask[z * W + x] = 1
            tops[z * W + x] = height(x, z)

sides = {}
for z in range(D):
    for x in range(W):
        if not mask[z * W + x]:
            continue
        h = tops[z * W + x]
        for edge, (dx, dz) in enumerate(((0, -1), (1, 0), (0, 1), (-1, 0))):
            nx, nz = x + dx, z + dz
            if 0 <= nx < W and 0 <= nz < D and mask[nz * W + nx] and h > tops[nz * W + nx]:
                other = tops[nz * W + nx]
                sides[f"{x},{z},{edge}"] = [0.0, 1.0, other, h, other, h]

props = []


def place(asset: str, x: int, z: int, y: int | None = None, forward: str = "-Z", wall: bool = False) -> None:
    """Append a measured prop placement, using the terrain tier when floor-supported."""
    if y is None:
        y = int(height(x, z))
    item = {"asset": asset, "origin": [x, y, z], "forward": forward, "roll": 0, "yaw": 0}
    if wall:
        item.update({"support": "wall", "support_face": "-Y"})
    props.append(item)


# The north gate and its two wall wings form the institutional landmark and a readable exit route.
place("BQ_PRISON_GATE", 15, 3, y=3)
place("BQ_PRISON_WALL_WING", 9, 3, y=3)
place("BQ_PRISON_WALL_WING", 31, 3, y=3)
place("BQ_CITY_TENEMENT", 1, 0, y=3)
place("BQ_CITY_TENEMENT", 39, 0, y=3)
place("BQ_CITY_TENEMENT", 2, 34, y=0, forward="-X")
place("BQ_CITY_TENEMENT", 38, 34, y=0, forward="+X")

# Four glass pens divide the middle quarantine yard without erasing the central tactical lane.
for x in (3, 10, 28, 35):
    place("BQ_GLASS_QUARANTINE_PEN_BREACHED" if x == 10 else "BQ_GLASS_QUARANTINE_PEN", x, 14, y=2)

# Detailed reused restraint/remains art makes these occupied confinement buildings, not empty greenhouses.
place("BW_MESHY_INTERROGATION_FRAME", 11, 17, y=2)
place("BW_MESHY_SKELETAL_RACK", 11, 21, y=2)
place("BI_HOLDING_BENCH", 11, 15, y=2)
place("BW_MESHY_INTERROGATION_FRAME", 29, 15, y=2)
place("BW_MESHY_SKELETAL_RACK", 29, 19, y=2)
place("BI_HOLDING_BENCH", 29, 21, y=2)
place("BQ_QUARANTINE_NOTICE", 15, 24, y=1)
place("BQ_CONTAINED_RESIDUE", 11, 23, y=1)
place("BQ_CONTAINED_RESIDUE", 29, 23, y=1)

# Barricades and the registration kiosk make the southern arrival feel actively contained.
for x, z in ((8, 30), (17, 33), (26, 33), (29, 37)):
    place("BQ_QUARANTINE_BARRICADE", x, z)
place("BQ_REGISTRY_KIOSK", 30, 33, y=0)
place("BQ_QUARANTINE_STANDARD", 33, 33, y=0)
place("BW_MESHY_WARDENS_DESK", 34, 32, y=0)
for x, z in ((2, 9), (41, 9)):
    place("BQ_QUARANTINE_STANDARD", x, z, y=3)

# The Meshy warden is used once as a gate-side civic focal; ordinary clutter stays procedural/shared.
place("BQ_WARDEN_MONUMENT", 33, 8, y=2)
for asset, locations in {
    "BW_LANTERN_CAGED": ((14, 7), (31, 7), (5, 12), (41, 12), (19, 28), (29, 28)),
    "BW_CRATE_IRON_BOUND": ((16, 35), (17, 35), (28, 35), (33, 31), (16, 22), (16, 23)),
    "BW_BARREL_CLUSTER": ((8, 32), (35, 34)),
    "BW_RUBBLE_WORN": ((1, 24), (18, 18), (35, 30), (42, 24), (24, 12)),
    "BW_DEBRIS_FLAT_WORN": ((9, 28), (22, 34), (32, 29)),
}.items():
    for x, z in locations:
        place(asset, x, z)

# Connected rail runs mark the high gate terrace and side drops; no detached single fence fragments.
for x, z, forward in ((0, 18, "+X"), (0, 20, "+X"), (45, 18, "-X"), (45, 20, "-X")):
    place("BW_RAILING_WORN", x, z, y=int(height(x, z)), forward=forward)

# Low connected coping encloses the forecourt while leaving the central city entrance open.
for x in list(range(8, 20, 2)) + list(range(28, 38, 2)):
    place("BW_RAILING_WORN", x, 40, y=0)
for z in (22, 24, 28, 30, 32):
    for x, face in ((0, "+X"), (45, "-X")):
        place("BW_RAILING_WORN", x, z, forward=face)

lights = []


def light(name: str, x: float, z: float, y: float, color: list[float], energy: float, radius: float) -> None:
    """Add one authored native light pool, keeping amber fixtures separate from cold city fill."""
    lights.append({
        "name": name, "type": 0, "enabled": True, "surface_position": [x, y, z], "height_offset": 0.0,
        "rotation_degrees": [-45.0, 0.0, 0.0], "projector_path": "", "color": color,
        "intensity": energy, "radius": radius, "attenuation": 1.4, "shadow": 0,
        "light_size": 0.15, "spot_angle": 45.0, "spot_attenuation": 1.0,
    })


for x, z in ((14, 7), (31, 7), (19, 28)):
    light("Quarantine lantern %s %s" % (x, z), x + .5, z + .5, height(x, z) + 2.3,
          [1.0, 0.48, 0.19], 6.0, 8.0)
light("Gatehouse amber", 23, 7, 9, [1.0, 0.51, 0.23], 6.0, 13)
light("Registration lamp", 31.5, 35.6, 2.5, [1.0, 0.47, 0.18], 5.0, 8)
for x in (5.5, 12.5, 30.5):
    light("Contained pen contamination %s" % x, x, 19, 3.0, [0.26, 0.72, 0.40], 5.0, 6)

board.update(
    name="Blackridge Quarantine",
    biome="Blackridge Underholm - Prison Approach",
    surfaces=[],
    props=props,
    imported_assets=sorted(set(p["asset"] for p in props) | {"BW_FLAGSTONES_WORN", "BW_ASHLAR_VARIED"}),
    monster_visuals=[],
    particle_effects=[],
    enemy_packs=[{"id": "quarantine_line", "note": "Containment guards and infected prisoners hold the quarantine approach."}],
    gameplay_markers=[],
    terrain={
        "origin_cell": [0, 0], "size_cells": [W, D], "cell_mask": mask,
        "top_heights": [h for h in tops for _ in range(4)], "top_diagonals": [0] * (W * D),
        "side_faces": sides, "skirt_depth_m": 8.0,
    },
    surface_material_paint={"version": 3, "surfaces": [], "material_slots": []},
)
board["lighting"].update(
    sun_enabled=True, sun_energy=0.72, sun_color=[0.66, 0.73, 0.82], ambient_energy=0.32,
    ambient_color=[0.20, 0.27, 0.36], background_color=[0.008, 0.012, 0.021],
    fog_enabled=True, fog_color=[0.035, 0.047, 0.06], fog_density=0.0012, fog_height_density=0.0,
    fog_height_m=1.0, glow_enabled=True, glow_bloom=0.05, glow_intensity=0.65,
    lights=lights, ssao_enabled=True, ssao_intensity=1.9, ssao_radius=0.85,
)
board["material_blend"].update(
    enabled=True, paint_texels_per_metre=16,
    layers=[
        {"application_mode": 1, "asset_id": "BW_FLAGSTONES_WORN", "enabled": True, "height_blend_percent": 0.0,
         "masks": [{"channel": 0, "combine": 0, "invert": False, "noise_angle_degrees": 0.0, "noise_scale_m": 2.0,
                    "noise_seed": 0, "paint_channel": 0, "range_high_percent": 100.0, "range_low_percent": 50.0,
                    "softness_percent": 0.0, "source": 11, "strength_percent": 100.0}],
         "opacity_percent": 100.0, "texture_scale_percent": 100.0},
        {"application_mode": 1, "asset_id": "BW_ASHLAR_VARIED", "enabled": True, "height_blend_percent": 0.0,
         "masks": [{"channel": 0, "combine": 0, "invert": True, "noise_angle_degrees": 0.0, "noise_scale_m": 2.0,
                    "noise_seed": 0, "paint_channel": 0, "range_high_percent": 100.0, "range_low_percent": 50.0,
                    "softness_percent": 0.0, "source": 11, "strength_percent": 100.0}],
         "opacity_percent": 100.0, "texture_scale_percent": 80.0},
    ] + board["material_blend"]["layers"][2:],
)


def marker(marker_id: str, marker_type: str, x: int, z: int, monster: str = "", note: str = "") -> None:
    """Record a gameplay marker at a known walkable tier for native/runtime checks."""
    board["gameplay_markers"].append({
        "id": marker_id, "type": marker_type, "origin": [x, int(height(x, z)), z],
        "monster": monster, "pack": "quarantine_line" if monster else "", "note": note or marker_id.replace("_", " "),
    })


for marker_id, x, z in (("player_fighter", 22, 37), ("player_mage", 24, 37), ("player_priest", 22, 39), ("player_rogue", 24, 39)):
    marker(marker_id, "player_spawn", x, z, note="The party enters the outer quarantine yard from the city approach.")
for marker_id, monster, x, z in (
    ("sedator_west", "sedator", 7, 23), ("sedator_east", "sedator", 34, 24),
    ("blackstick_gate", "blackstick", 25, 11), ("blackstick_pen", "blackstick", 20, 20),
    ("catcher_north", "catcher", 18, 12), ("catcher_south", "catcher", 29, 29),
    ("warden_quarantine", "elias", 34, 10), ("bound_handler", "handler/mage", 25, 24),
):
    marker(marker_id, "enemy", x, z, monster)
marker("reach_outer_gate", "objective", 23, 32, note="Enter the quarantine line through the city barricades.")
marker("hold_the_pens", "objective", 23, 18, note="Break through the green glass quarantine pens.")
marker("exit_to_intake", "objective", 23, 8, note="The institutional gate leads upward to Blackridge Intake.")

(OUT / "board_candidate.json").write_text(json.dumps(board, indent=2))
(OUT / "layout_summary.json").write_text(json.dumps({
    "cells": sum(mask), "props": len(props), "bounds": [W, D],
    "arrival": [23, 0, 38], "exit": [23, 3, 8], "focal": "BQ_WARDEN_MONUMENT",
}, indent=2))
print(json.dumps({"cells": sum(mask), "props": len(props), "markers": len(board["gameplay_markers"]), "lights": len(lights)}))
