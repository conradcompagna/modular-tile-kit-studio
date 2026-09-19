"""Prove each tapered ceiling root enters an actual lower-column cross-section."""
from pathlib import Path
import json
import numpy as np
import trimesh
from scipy.sparse import coo_matrix
from scipy.sparse.csgraph import connected_components
from shapely.geometry import Polygon,Point
from shapely.ops import unary_union

ROOT=Path(__file__).resolve().parents[1]
scene=trimesh.load(ROOT/'assets/blackridge_depths_revision03/cavern_wall_ceiling_rooted.glb',process=False)
lower=[]
for mesh in scene.geometry.values():
    unique,inverse=np.unique(np.round(mesh.vertices,5),axis=0,return_inverse=True)
    faces=inverse[mesh.faces]
    edges=np.concatenate([faces[:,[0,1]],faces[:,[1,2]],faces[:,[2,0]]])
    graph=coo_matrix((np.ones(len(edges)),(edges[:,0],edges[:,1])),shape=(len(unique),len(unique)))
    count,labels=connected_components(graph,directed=False)
    for label in range(count):
        selected=faces[labels[faces[:,0]]==label]
        if unique[np.unique(selected),1].min()<.01:
            lower.append(trimesh.Trimesh(vertices=unique,faces=selected,process=True))
changes=json.loads((ROOT/'exports/blackridge_depths_revision03/source_changes.json').read_text())
results=[]
for asset in changes:
    for root in asset.get('rooted_upper_components',[]):
        source=np.array(root['root_vertices_blender'])
        points=source[:,[0,2,1]].copy();points[:,2]*=-1
        section_polygons=[]
        for mesh in lower:
            section=mesh.section(plane_origin=[0,points[0,1],0],plane_normal=[0,1,0])
            if section is None:continue
            for polyline in section.discrete:
                if len(polyline)<4 or np.linalg.norm(polyline[0]-polyline[-1])>.001:continue
                polygon=Polygon(polyline[:,[0,2]])
                if polygon.is_valid:section_polygons.append(polygon)
        actual_section=unary_union(section_polygons)
        containment=[actual_section.contains(Point(p[[0,2]])) for p in points]
        results.append({'root_center_blender':root['root_center_blender'],'root_vertices':len(points),
                        'all_inside_actual_closed_host_section':all(containment),
                        'minimum_actual_host_edge_clearance_m':min(actual_section.boundary.distance(Point(p[[0,2]])) for p in points)})
(ROOT/'reports/blackridge_depths_revision03/upper_root_actual_mesh_contact.json').write_text(json.dumps(results,indent=2)+'\n')
print(json.dumps(results,indent=2))
assert all(r['all_inside_actual_closed_host_section'] for r in results)
