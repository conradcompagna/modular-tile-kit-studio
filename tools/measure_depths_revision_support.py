"""Measure actual basal triangles against restored native terrain before authoring support."""
from pathlib import Path
import json
import math
import sys
import numpy as np
import trimesh
from shapely.geometry import Polygon, box
from shapely.ops import unary_union
from scipy.cluster.hierarchy import fclusterdata

ROOT = Path(__file__).resolve().parents[1]
REPORT = ROOT / 'reports/blackridge_depths'
board_path = Path(sys.argv[1]) if len(sys.argv)>1 else ROOT / 'exports/blackridge_depths_revision/board_before_support_materials.json'
report_name = sys.argv[2] if len(sys.argv)>2 else 'revision_support_before.json'
board = json.loads(board_path.read_text())
measured_current_pose = len(sys.argv)>3
poses_path = Path(sys.argv[3]) if measured_current_pose else REPORT / 'restored_native_prop_transforms.json'
poses = json.loads(poses_path.read_text())
terrain = board['terrain']
width, depth = terrain['size_cells']
origin_x, origin_z = terrain['origin_cell']


# Return literal native top corners only where the restored board has a filled cell.
def terrain_top(x, z):
    xx, zz = x-origin_x, z-origin_z
    if not (0 <= xx < width and 0 <= zz < depth):
        return None
    i = zz*width+xx
    if not terrain['cell_mask'][i]:
        return None
    return terrain['top_heights'][i*4:i*4+4]


# Bake the native pose and glTF node transform into world-space triangles for measurement.
def world_meshes(record):
    scene = trimesh.load(ROOT / record['path'].replace('res://', ''), process=False)
    pose = np.eye(4)
    pose[:3, :3] = np.asarray(record['basis']).T
    # Preserve the measured native asset offset while accounting for the one explicit relocation.
    checkpoint = json.loads((ROOT / 'exports/blackridge_depths_revision/board_before_support_materials.json').read_text())
    delta = np.zeros(3) if measured_current_pose else np.asarray(board['props'][record['index']]['origin'])-np.asarray(checkpoint['props'][record['index']]['origin'])
    pose[:3, 3] = np.asarray(record['origin'])+delta
    for node in scene.graph.nodes_geometry:
        local, geometry = scene.graph[node]
        mesh = scene.geometry[geometry].copy()
        mesh.apply_transform(pose @ local)
        yield geometry, mesh


# Intersect the actual near-flat basal triangles with one-metre terrain squares.
def basal_cells(mesh):
    minimum = float(mesh.vertices[:, 1].min())
    tris = mesh.triangles
    selected = tris[np.max(tris[:, :, 1], axis=1) <= minimum + .035]
    polygons = []
    for triangle in selected:
        polygon = Polygon(triangle[:, [0, 2]])
        if polygon.is_valid and polygon.area > .000001:
            polygons.append(polygon)
    footprint = unary_union(polygons)
    cells = []
    if footprint.is_empty:
        return minimum, [], 0.0
    x0, z0, x1, z1 = footprint.bounds
    for z in range(math.floor(z0), math.ceil(z1)):
        for x in range(math.floor(x0), math.ceil(x1)):
            area = footprint.intersection(box(x, z, x+1, z+1)).area
            if area > .005:
                corners = terrain_top(x, z)
                cells.append({'cell':[x,z], 'base_y':minimum, 'basal_area':area,
                              'terrain_corners':corners,
                              'gap_m':None if corners is None else minimum-min(corners)})
    return minimum, cells, footprint.area


records = []
for record in poses:
    if not ('CAVERN_WALL' in record['asset'] or 'STALAGMITE' in record['asset']):
        continue
    parts = []
    meshes = list(world_meshes(record))
    asset_minimum = min(float(mesh.bounds[0, 1]) for _, mesh in meshes)
    for name, mesh in meshes:
        # Elevated ceiling teeth are supported by their wall and are not terrain-contact feet.
        if float(mesh.bounds[0, 1]) > asset_minimum + .1:
            continue
        minimum, cells, area = basal_cells(mesh)
        if cells:
            parts.append({'geometry':name, 'base_y':minimum, 'area':area, 'cells':cells})
    cells = [c for p in parts for c in p['cells']]
    bad = [c for c in cells if c['terrain_corners'] is None or c['gap_m'] > .04]
    records.append({'index':record['index'], 'asset':record['asset'], 'parts':parts,
                    'missing_cells':sum(c['terrain_corners'] is None for c in cells),
                    'positive_gap_cells':sum(c['gap_m'] is not None and c['gap_m']>.04 for c in cells),
                    'max_gap_m':max([c['gap_m'] for c in cells if c['gap_m'] is not None] or [0]),
                    'requires_correction':bool(bad)})

boss_record = next(p for p in poses if p['asset']=='BD_CHAINED_ABOMINATION')
boss = next(mesh for name,mesh in world_meshes(boss_record) if getattr(mesh.visual.material,'name','')=='material_0')
low = boss.vertices[boss.vertices[:,1] < boss.bounds[0,1]+.18]
clusters = fclusterdata(low[:,[0,2]], .55, criterion='distance')
contacts = []
for cluster in sorted(set(clusters)):
    points = low[clusters==cluster]
    contacts.append({'points':len(points), 'minimum':points.min(axis=0).tolist(),
                     'maximum':points.max(axis=0).tolist(), 'centroid':points.mean(axis=0).tolist()})
report = {'terrain_cells':sum(terrain['cell_mask']), 'rock_instances':len(records),
          'instances_needing_support':[r['index'] for r in records if r['requires_correction']],
          'rocks':records, 'boss_world_bounds':boss.bounds.tolist(), 'boss_low_contacts':contacts}
# A horizontal triangle-plane section demonstrates real planted flesh-to-rock contacts.
section = boss.section(plane_origin=[0,-1.98,0],plane_normal=[0,1,0])
report['boss_contact_plane_y'] = -1.98
report['boss_plane_sections'] = []
if section is not None:
    for polyline in section.discrete:
        supported = []
        for point in polyline:
            corners = terrain_top(math.floor(point[0]),math.floor(point[2]))
            supported.append(corners is not None and abs(min(corners)+1.98)<.001)
        report['boss_plane_sections'].append({'points':len(polyline),'min':polyline.min(axis=0).tolist(),'max':polyline.max(axis=0).tolist(),'all_on_native_island':all(supported)})
(REPORT/report_name).write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps({k:v for k,v in report.items() if k!='rocks'},indent=2))
for r in records:
    print(r['index'],r['asset'],'missing',r['missing_cells'],'gap_cells',r['positive_gap_cells'],'max_gap',round(r['max_gap_m'],3))
