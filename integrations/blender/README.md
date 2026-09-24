# Grid Heightfield Tools

The Blender extension supports grid-heightfield conversion and editing. Its
entrypoint owns registration and version metadata; focused modules implement
sampling, conversion, editable cells, modal brushes and viewport drawing.

| Module | Responsibility |
| --- | --- |
| `registration.py` | Class lifecycle and the scene settings property |
| `settings.py`, `panels.py` | Persistent settings and editor controls |
| `units.py`, `sampling.py` | Scene-unit conversion, quantization and BVH sampling |
| `conversion.py`, `mesh_builder.py` | Conversion operator and mesh creation |
| `edit_model.py` | Editable cell representation and mesh reconstruction |
| `height_brush.py`, `slope_brush.py` | Undoable modal brush operators |
| `brush_geometry.py`, `brush_drawing.py`, `gpu_support.py` | Viewport interaction and overlays |

I checked the modularized integration against the original implementation using
the same grid-conversion input on Blender 5.1.1. Both produced the same geometry
fingerprint: `d262f76ad0a1695310c5e48acef0d7ac773e5da2d33e6d371e600e2fb87bba7b`.
The recorded comparison covers mesh output and scene save/reopen; the brush and
overlay implementations are mapped above.
