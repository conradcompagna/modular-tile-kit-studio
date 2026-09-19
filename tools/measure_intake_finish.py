"""Measure the accepted donor meshes in their actual exported coordinate system."""
import bpy, json
from pathlib import Path
from collections import defaultdict
from mathutils import Vector
ROOT=Path(__file__).resolve().parents[1]
out={}
for name,source in [('desk','tile_library/assets/BW_MESHY_WARDENS_DESK/derived/runtime_optimized.glb'),('rail','tile_library/assets/BW_RAILING_WORN/source/railing_worn.glb'),('arch','tile_library/assets/BW_OPEN_GATE_PASSAGE/source/open_gate_passage.glb')]:
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=str(ROOT/source))
    verts=[]; area=defaultdict(float)
    for ob in bpy.context.scene.objects:
        if ob.type!='MESH': continue
        verts.extend([ob.matrix_world@v.co for v in ob.data.vertices])
        for p in ob.data.polygons:
            if abs(p.normal.z)>.9: area[round((ob.matrix_world@p.center).z,2)]+=p.area
    out[name]={'lo':[min(v[k] for v in verts) for k in range(3)],'hi':[max(v[k] for v in verts) for k in range(3)],'horizontal_area':sorted(area.items(),key=lambda p:-p[1])[:12]}
(ROOT/'exports/blackridge_intake/finish_measurements.json').write_text(json.dumps(out,indent=2))
