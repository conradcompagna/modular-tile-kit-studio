"""Measure the actual kiosk and its major upward counter surface before choosing native import sizing."""
from pathlib import Path
import bpy
import json
from collections import defaultdict

ROOT=Path(__file__).resolve().parents[1]
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=str(ROOT/'assets/blackridge_quarantine_revision03/meshy/inspection_kiosk.glb'))
bpy.context.view_layer.update()
objects=[o for o in bpy.context.scene.objects if o.type=='MESH']
points=[o.matrix_world@v.co for o in objects for v in o.data.vertices]
lo=[min(p[i] for p in points) for i in range(3)]
hi=[max(p[i] for p in points) for i in range(3)]
height=hi[2]-lo[2]
areas=defaultdict(float)
for ob in objects:
    for face in ob.data.polygons:
        normal=ob.matrix_world.to_3x3()@face.normal
        centre=ob.matrix_world@face.center
        fraction=(centre.z-lo[2])/height
        if normal.z>.82 and .25<fraction<.65:
            areas[round(fraction,2)]+=face.area
peaks=sorted(areas.items(),key=lambda x:x[1],reverse=True)[:8]
record={'source_bounds_blender':[lo,hi],'source_size_y_up':[hi[0]-lo[0],height,hi[1]-lo[1]],
        'counter_upward_surface_height_fraction_peaks':peaks,'native_plan':'Height driver3m, uniform fit, no stretch',
        'counter_height_at_3m_total_height':peaks[0][0]*3,'triangles':sum(len(p.vertices)-2 for o in objects for p in o.data.polygons)}
(ROOT/'exports/blackridge_quarantine_revision03/kiosk_measurement.json').write_text(json.dumps(record,indent=2))
print(json.dumps(record))
