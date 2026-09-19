"""Measure cavern terrain contacts and side penetration against final source triangles."""
from pathlib import Path
import json
import math
import sys
import numpy as np
import trimesh
from shapely.geometry import Polygon, box
from shapely.ops import unary_union

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'reports/blackridge_depths_revision03'


# Bake the native placement and source node matrices without changing original mesh data.
def world_meshes(record):
    scene = trimesh.load(ROOT / record['path'].replace('res://', ''), process=False)
    pose = np.eye(4)
    pose[:3, :3] = np.asarray(record['basis']).T
    pose[:3, 3] = record['origin']
    for node in scene.graph.nodes_geometry:
        local, geometry = scene.graph[node]
        mesh = scene.geometry[geometry].copy()
        mesh.apply_transform(pose @ local)
        yield geometry, mesh


# Return the two exact top triangles for a canonical one-metre native terrain cell.
def cell_triangles(terrain, x, z):
    ox, oz = terrain['origin_cell']
    w, d = terrain['size_cells']
    if not (ox <= x < ox+w and oz <= z < oz+d):
        return []
    i = (z-oz)*w+x-ox
    if not terrain['cell_mask'][i]:
        return []
    h = terrain['top_heights'][i*4:i*4+4]
    vertices = np.array([[x,h[0],z],[x+1,h[1],z],[x,h[2],z+1],[x+1,h[3],z+1]])
    indices = [[0,1,3],[0,3,2]] if terrain['top_diagonals'][i] == 0 else [[0,1,2],[1,3,2]]
    return [vertices[index] for index in indices]


# Intersect source triangle projections with actual terrain triangles to expose cuts above rock bases.
def inspect_rock(record, terrain):
    meshes = list(world_meshes(record))
    base = min(m.bounds[0,1] for _,m in meshes)
    basal = []
    buried = {}
    cuts = set()
    projection = []
    for name, mesh in meshes:
        for triangle in mesh.triangles:
            polygon = Polygon(triangle[:,[0,2]])
            if not polygon.is_valid or polygon.area < 1e-7:
                continue
            projection.append(polygon)
            if triangle[:,1].max() <= base+.035:
                basal.append(polygon)
            if triangle[:,1].max() < base+.08:
                continue
            # Each projected triangle defines a height plane; degenerate vertical faces are excluded.
            coefficients = np.linalg.solve(np.column_stack([triangle[:,0],triangle[:,2],np.ones(3)]),triangle[:,1])
            x0,z0,x1,z1 = polygon.bounds
            for z in range(math.floor(z0),math.ceil(z1)):
                for x in range(math.floor(x0),math.ceil(x1)):
                    for top in cell_triangles(terrain,x,z):
                        overlap = polygon.intersection(Polygon(top[:,[0,2]]))
                        if overlap.is_empty or overlap.area < 1e-6:
                            continue
                        top_coefficients = np.linalg.solve(np.column_stack([top[:,0],top[:,2],np.ones(3)]),top[:,1])
                        p = np.array(overlap.exterior.coords)
                        q = np.column_stack([p,np.ones(len(p))])
                        rock_y = q @ coefficients
                        terrain_y = q @ top_coefficients
                        difference = terrain_y-rock_y
                        above_base = rock_y > base+.08
                        key = f'{x},{z}'
                        if np.any(above_base & (difference>.05)):
                            buried[key] = max(buried.get(key,0),float(difference[above_base].max()))
                        if difference.min() < -.04 and difference.max() > .04 and terrain_y.max() > base+.08:
                            cuts.add(key)
    footprint = unary_union(basal)
    basal_issues = []
    if not footprint.is_empty:
        x0,z0,x1,z1 = footprint.bounds
        for z in range(math.floor(z0),math.ceil(z1)):
            for x in range(math.floor(x0),math.ceil(x1)):
                area = footprint.intersection(box(x,z,x+1,z+1)).area
                if area < .005:
                    continue
                top = cell_triangles(terrain,x,z)
                heights = [v[1] for tri in top for v in tri]
                if not heights or base-min(heights)>.04 or max(heights)-base>.05:
                    basal_issues.append({'cell':[x,z],'area':area,'top_min':min(heights) if heights else None,'top_max':max(heights) if heights else None})
    full = unary_union(projection)
    return {'index':record['index'],'asset':record['asset'],'base_y':float(base),
            'basal_area':float(footprint.area),'projection_bounds':list(full.bounds),
            'basal_issues':basal_issues,'buried_surface_cells':buried,'sliced_surface_cells':sorted(cuts),
            'max_side_burial_m':max(buried.values(),default=0)}


# Save an explicit before or after report without treating geometry contact as an art score.
def main():
    board_path = ROOT / (sys.argv[1] if len(sys.argv)>1 else 'exports/blackridge_depths_revision03/board_before.json')
    poses_path = ROOT / (sys.argv[2] if len(sys.argv)>2 else 'reports/blackridge_depths_revision03/native_poses_before.json')
    suffix = sys.argv[3] if len(sys.argv)>3 else 'before'
    board = json.loads(board_path.read_text())
    records = json.loads(poses_path.read_text())
    rocks = []
    for record in records:
        if not ('CAVERN_WALL' in record['asset'] or 'STALAGMITE' in record['asset']):
            continue
        result = inspect_rock(record,board['terrain'])
        rocks.append(result)
        print(record['index'],record['asset'],'basal',len(result['basal_issues']),'buried',len(result['buried_surface_cells']),'sliced',len(result['sliced_surface_cells']),'max',round(result['max_side_burial_m'],3),flush=True)
    report = {'board':str(board_path),'poses':str(poses_path),'rocks':rocks,
              'tolerances':{'basal_gap_m':.04,'basal_burial_m':.05,'side_burial_m':.05,'exclude_first_base_height_m':.08},
              'instances_with_basal_issues':[r['index'] for r in rocks if r['basal_issues']],
              'instances_with_side_penetration':[r['index'] for r in rocks if r['buried_surface_cells'] or r['sliced_surface_cells']]}
    (OUT/f'contact_audit_{suffix}.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({k:v for k,v in report.items() if k!='rocks'}),flush=True)


if __name__ == '__main__':
    main()
