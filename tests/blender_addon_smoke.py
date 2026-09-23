"""Run with Blender --background --factory-startup --python-exit-code 1 --python this_file.

Exercises registration, deterministic conversion, editable attributes and scene
save/reopen without touching authored assets. Artifacts go to test-artifacts/.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import sys

import bpy

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("--addon-root", type=Path, default=ROOT / "integrations/blender")
parser.add_argument("--output", type=Path, default=ROOT / "test-artifacts/blender-smoke.json")
args = parser.parse_args(sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else [])
args.output.parent.mkdir(parents=True, exist_ok=True)
spec = importlib.util.spec_from_file_location("mts_heightfield_smoke", args.addon_root / "__init__.py")
addon = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = addon
spec.loader.exec_module(addon)

for _ in range(2):
    addon.register()
    assert hasattr(bpy.types.Scene, "hf_settings")
    addon.unregister()
    assert not hasattr(bpy.types.Scene, "hf_settings")
addon.register()

bpy.ops.object.select_all(action="SELECT")
bpy.ops.object.delete(use_global=False)
bpy.ops.mesh.primitive_plane_add(size=2, location=(0, 0, 1))
source = bpy.context.object
source.name = "SyntheticSource"
settings = bpy.context.scene.hf_settings
settings.grid_size_m = 0.5
settings.height_step_m = 0.25
settings.hide_source = False
settings.boundary_skirt = False
result = bpy.ops.object.convert_grid_heightfield()
assert result == {"FINISHED"}, result
converted = bpy.context.object
assert converted != source
required = {"hf_grid_x", "hf_grid_y", "hf_height_m", "hf_face_kind", "hf_band_index"}
assert required <= set(converted.data.attributes.keys())

geometry = {
    "vertices": [[round(value, 6) for value in vertex.co] for vertex in converted.data.vertices],
    "faces": [list(face.vertices) for face in converted.data.polygons],
    "attributes": {name: [round(item.value, 6) for item in converted.data.attributes[name].data]
                   for name in sorted(required)},
}
fingerprint = hashlib.sha256(json.dumps(geometry, sort_keys=True).encode()).hexdigest()
name = converted.name
blend_path = args.output.with_suffix(".blend").resolve()
bpy.ops.wm.save_as_mainfile(filepath=str(blend_path))
bpy.ops.wm.open_mainfile(filepath=str(blend_path))
assert name in bpy.data.objects
assert required <= set(bpy.data.objects[name].data.attributes.keys())
assert abs(bpy.context.scene.hf_settings.grid_size_m - 0.5) < 1e-6
addon.unregister()
assert not hasattr(bpy.types.Scene, "hf_settings")
args.output.write_text(json.dumps({"blender": bpy.app.version_string, "geometry_sha256": fingerprint,
                                  "vertices": len(geometry["vertices"]), "faces": len(geometry["faces"]),
                                  "registration_cycles": 3, "save_reopen": True}, indent=2) + "\n")
print("BLENDER_ADDON_SMOKE_PASS", fingerprint)
