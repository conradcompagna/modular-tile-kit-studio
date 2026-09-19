"""Identify the disputed orange hoist detail by its actual runtime-camera ray and source component."""
from pathlib import Path
import json
import numpy as np
from scipy.sparse import coo_matrix
from scipy.sparse.csgraph import connected_components
from shapely.geometry import Polygon
from shapely.ops import unary_union
import trimesh
from audit_bd3_contacts import world_meshes

ROOT=Path(__file__).resolve().parents[1]
record=json.loads((ROOT/'reports/blackridge_depths_revision03/native_poses_prepared.json').read_text())[33]
meshes=dict(world_meshes(record))
iron=meshes['Massive lift deck plank_1']
wood=meshes['Massive lift deck plank']


# Recover the complete geometry piece containing a known hit triangle despite UV vertex splits.
def component(mesh,face_index):
    unique,inverse=np.unique(np.round(mesh.vertices,5),axis=0,return_inverse=True)
    faces=inverse[mesh.faces]
    edges=np.concatenate([faces[:,[0,1]],faces[:,[1,2]],faces[:,[2,0]]])
    graph=coo_matrix((np.ones(len(edges)),(edges[:,0],edges[:,1])),shape=(len(unique),len(unique)))
    _,labels=connected_components(graph,directed=False)
    label=labels[faces[face_index,0]]
    selected=faces[labels[faces[:,0]]==label]
    return trimesh.Trimesh(vertices=unique,faces=selected,process=True)


# Form an exact closed horizontal cross-section of the selected hardware or post.
def section_polygon(mesh,height):
    section=mesh.section(plane_origin=[0,height,0],plane_normal=[0,1,0])
    polygons=[]
    for polyline in section.discrete:
        if len(polyline)>3 and np.linalg.norm(polyline[0]-polyline[-1])<.001:
            polygon=Polygon(polyline[:,[0,2]])
            if polygon.is_valid:polygons.append(polygon)
    return unary_union(polygons)


brace=component(iron,2695)
post=component(wood,1397)
sections=[]
for height in [6.22,6.25,6.30,6.35]:
    overlap=section_polygon(brace,height).intersection(section_polygon(post,height))
    sections.append({'world_y':height,'actual_cross_section_overlap_m2':overlap.area})
report={'image':'captures/blackridge_depths_revision03/runtime_hoist_endpoints_01.png',
        'pixel':[1400,945],'camera_eye':[7,9,25],'camera_focus':[3.5,7.65,20.5],'ortho_height_m':4.8,
        'ray_first_hit_world':[4.8209661553,6.2054927999,19.3316582737],
        'asset':record['asset'],'material':'Blackened wrought iron','part':'existing lower end of right-front gantry knee brace',
        'recipe_source':'tools/build_blackridge_depths_kit.py, Gantry knee brace from (2.85,.25,6.1) to (1.7,.25,7.65) before recorded export fit',
        'brace_bounds_world':brace.bounds.tolist(),'upright_bounds_world':post.bounds.tolist(),
        'actual_attachment_sections':sections,'is_loose_cable':False,'geometry_change_required':False}
(ROOT/'reports/blackridge_depths_revision03/hoist_orange_detail_identification.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
assert all(s['actual_cross_section_overlap_m2']>.005 for s in sections)
