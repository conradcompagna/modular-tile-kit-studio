"""Measure proposed camera clearances using actual installed prop triangles and native terrain."""
from pathlib import Path
import json
import numpy as np
import trimesh
from audit_bd3_contacts import world_meshes, cell_triangles

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'reports/blackridge_depths_revision03'
board=json.loads((ROOT/'boards/blackridge_depths.json').read_text())
poses=json.loads((OUT/'native_poses_final.json').read_text())
views=[
 {'name':'runtime_pocket_24_north_03','eye':[37.2,-1,29.25],'focus':[37.5,-2.9,31.3],'fov':68},
 {'name':'runtime_fissure_27_close_03','eye':[27.85,-7.95,19.1],'focus':[26.95,-8.85,18.15],'fov':85},
 {'name':'runtime_fissure_27_low_03','eye':[27.85,-8.5,18.8],'focus':[27.15,-8.94,18.35],'fov':85},
 {'name':'runtime_fissure_26_low_03','eye':[21.25,-8.3,15.5],'focus':[20.4,-8.94,15.5],'fov':85},
]
meshes=[(p['index'],m) for p in poses for _,m in world_meshes(p)]
for view in views:
 eye=np.array(view['eye']); nearest=[]
 for index,mesh in meshes:
  bound_distance=np.linalg.norm(np.maximum(np.maximum(mesh.bounds[0]-eye,eye-mesh.bounds[1]),0))
  if bound_distance>3: continue
  point,distance,face=trimesh.proximity.closest_point_naive(mesh,[eye])
  nearest.append({'prop_index':index,'surface_distance_m':float(distance[0]),'surface_point':point[0].tolist()})
 view['nearest_prop_surfaces']=sorted(nearest,key=lambda x:x['surface_distance_m'])[:4]
 cell=np.floor(eye[[0,2]]).astype(int)
 tops=cell_triangles(board['terrain'],*cell)
 view['terrain_cell']=cell.tolist()
 view['terrain_top_max']=float(max(t[:,1].max() for t in tops)) if tops else None
 view['eye_above_cell_top_m']=float(eye[1]-view['terrain_top_max']) if tops else None
 assert not nearest or min(x['surface_distance_m'] for x in nearest)>.12
 assert not tops or view['eye_above_cell_top_m']>.12
(OUT/'review_camera_plan03.json').write_text(json.dumps(views,indent=2)+'\n')
print(json.dumps(views,indent=2))
