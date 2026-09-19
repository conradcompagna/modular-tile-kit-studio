"""Measure final native placements and clip full row triangles against actual terrain cells."""
import bpy
import json
import math
import re
import hashlib
from pathlib import Path
from mathutils import Matrix, Vector

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'reports/blackridge_quarantine_revision03'
board = json.loads((ROOT/'boards/blackridge_quarantine.json').read_text())
measured = json.loads((ROOT/'exports/blackridge_quarantine_revision03/native_contact_measurements.json').read_text())
terrain = board['terrain']
ox, oz = terrain['origin_cell']
w, d = terrain['size_cells']
heights = {(x+ox,z+oz): max(terrain['top_heights'][4*(z*w+x):4*(z*w+x)+4]) for z in range(d) for x in range(w) if terrain['cell_mask'][z*w+x]}


# Clip the actual 3D triangle polygon against an XZ cell edge, preserving interpolated height.
def clip(poly, axis, limit, greater):
    result = []
    for a, b in zip(poly, poly[1:]+poly[:1]):
        ina = a[axis] >= limit if greater else a[axis] <= limit
        inb = b[axis] >= limit if greater else b[axis] <= limit
        if ina:
            result.append(a)
        if ina != inb:
            t = (limit-a[axis])/(b[axis]-a[axis])
            result.append(a+(b-a)*t)
    return result


# Inspect every row triangle after applying the exact installed source-to-world native transform.
def row_intersections(entry):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=str(ROOT/entry['source'].replace('res://','')))
    pose = entry['pose']
    matrix = Matrix([pose[0],pose[1],pose[2]]).transposed()
    offset = Vector(pose[3])
    triangles = 0
    intrusions = []
    for obj in list(bpy.context.scene.objects):
        if obj.type != 'MESH':
            continue
        points = []
        for v in obj.data.vertices:
            p = obj.matrix_world @ v.co
            points.append(matrix @ Vector((p.x,p.z,-p.y)) + offset)
        obj.data.calc_loop_triangles()
        for tri in obj.data.loop_triangles:
            triangles += 1
            p = [points[i] for i in tri.vertices]
            if min(q.y for q in p) >= 3.0-0.002:
                continue
            for x in range(math.floor(min(q.x for q in p)+1e-6), math.ceil(max(q.x for q in p)-1e-6)):
                for z in range(math.floor(min(q.z for q in p)+1e-6), math.ceil(max(q.z for q in p)-1e-6)):
                    if (x,z) not in heights:
                        continue
                    poly = p
                    for axis, limit, greater in [(0,x+1e-5,True),(0,x+1-1e-5,False),(2,z+1e-5,True),(2,z+1-1e-5,False)]:
                        if not poly:
                            break
                        poly = clip(poly,axis,limit,greater)
                    if poly:
                        penetration = heights[x,z]-min(q.y for q in poly)
                        if penetration > 0.002:
                            intrusions.append({'cell':[x,z], 'penetration_m':penetration, 'triangle':tri.index})
    return {'id':entry['id'],'triangles_checked':triangles,'intrusion_count':len(intrusions),'maximum_penetration_m':max((i['penetration_m'] for i in intrusions),default=0),'examples':intrusions[:20]}


# Compare all four pen vignettes and the kiosk against ground, roof and authored light bounds.
contacts = []
for entry in measured['props']:
    if not (entry['id'].startswith(('BQ3_ALCHEMY','BQ3_LOCKED','BQ3_WASH','BQ3_INSPECTION','BQR_UPRIGHT','BQR_OCCULT','BQR_SUSPENDED')) or entry['id'] in ['BW_MESHY_WARDENS_DESK','BW_MESHY_INTERROGATION_FRAME','BR3_BARREL_CLUSTER']):
        continue
    vals = [float(n) for n in re.findall(r'-?\d+\.\d+',entry['world_bounds'])]
    low = vals[:3]
    high = [low[i]+vals[i+3] for i in range(3)]
    cells = [(x,z) for x in range(math.floor(low[0]+1e-5),math.ceil(high[0]-1e-5)) for z in range(math.floor(low[2]+1e-5),math.ceil(high[2]-1e-5))]
    inside = [l['name'] for l in board['lighting']['lights'] if all(low[i]<=l['surface_position'][i]<=high[i] for i in range(3))]
    contacts.append({'id':entry['id'],'world_min':low,'world_max':high,'footing_complete':all(c in heights and abs(heights[c]-low[1])<0.002 for c in cells),'lights_inside_bounds':inside,'pen_roof_clearance_m':5.2-high[1] if low[1]>1.5 else None})
rows = [row_intersections(e) for e in measured['props'] if e['id'].startswith('BQ3_TENEMENT')]
support = json.loads((ROOT/'exports/blackridge_quarantine_revision03/row_support_source_audit.json').read_text())
errors = []
world_foundations = []
for s in support:
    xs = range(-6,0) if s['host'].startswith('west') else range(46,52)
    row = next(e for e in measured['props'] if e['id'].startswith('BQ3_TENEMENT_ROW_'+('WEST' if s['host'].startswith('west') else 'EAST')))
    world_bottom = s['foundation_bottom']+row['pose'][3][1]
    world_top = s['foundation_top']+row['pose'][3][1]
    world_foundations.append({'host':s['host'],'world_z_cell':s['world_z_cell'],'world_bottom':world_bottom,'world_top':world_top,'adjacent_street_height':s['adjacent_street_height'],'closed_to_street':world_bottom<=s['adjacent_street_height']+0.002 and world_top>=s['adjacent_street_height']-0.002})
    for x in xs:
        if abs(heights.get((x,s['world_z_cell']),-999)-world_bottom)>0.002:
            errors.append([s['host'],x,s['world_z_cell']])
result = {'canonical_board_sha256':hashlib.sha256((ROOT/'boards/blackridge_quarantine.json').read_bytes()).hexdigest(),'native_row_sources':[{'id':e['id'],'source':e['source'],'source_sha256':hashlib.sha256((ROOT/e['source'].replace('res://','')).read_bytes()).hexdigest(),'actual_world_pose':e['pose'],'actual_world_bounds':e['world_bounds']} for e in measured['props'] if e['id'].startswith('BQ3_TENEMENT')],'method':'All installed row triangles transformed by native pose and clipped to the interior of each native 1 m cell; 2 mm intersection tolerance. Full source foundation segments plus actual native world translation compared to all 432 flat support cells and each adjacent street height. Pen contact uses native measured bounds, with actual runtime views required for final visibility.','row_mesh_terrain':rows,'foundation_world_contact':world_foundations,'foundation_support_errors':errors,'pen_kiosk_barrel_contacts':contacts,'pass':not errors and all(s['closed_to_street'] for s in world_foundations) and all(r['intrusion_count']==0 for r in rows) and all(c['footing_complete'] and not c['lights_inside_bounds'] and (c['pen_roof_clearance_m'] is None or c['pen_roof_clearance_m']>0) for c in contacts)}
(OUT/'CONTACT_AUDIT.json').write_text(json.dumps(result,indent=2))
print('BQ3_CONTACT_AUDIT',json.dumps(result),flush=True)
