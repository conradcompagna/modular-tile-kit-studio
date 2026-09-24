# Building a modular environment editor

The studio connects geometric assets, spatial rules, persistent board data and a
live Godot editor viewport. The construction work is visible in the boundaries
between these systems and the contracts that keep them synchronized.

## Construction stages

| Stage | Engineering work | Implementation |
|---|---|---|
| Asset preparation | Image/GLB ingestion, canonical transforms, proportional sizing and geometric processing | [Importers](../addons/modular_tile_studio/importers/), [Blender integration](../integrations/blender/README.md). |
| Spatial authoring | Grid sizing, occupancy, placement candidates, terrain contact and validation | [Board model](../addons/modular_tile_studio/data/board/), [placement features](../addons/modular_tile_studio/viewport/placement/). |
| Terrain and surfaces | Heightfield generation, material layers, sparse paint, decals and derived maps | [Generation](../addons/modular_tile_studio/generation/), [rendering](../addons/modular_tile_studio/rendering/). |
| Editor interaction | Main-screen plugin lifecycle, panels, selection, brushes and undo/redo | [Plugin](../addons/modular_tile_studio/plugin.gd), [UI](../addons/modular_tile_studio/ui/), [viewport](../addons/modular_tile_studio/viewport/). |
| Persistence | Versioned board JSON, validation, atomic writes and paint sidecars | [Board features](../addons/modular_tile_studio/data/board/), [paint features](../addons/modular_tile_studio/rendering/paint/). |
| Image analysis | Optional workflows connecting generated/processed imagery to asset preparation | [Analysis workflows](../addons/modular_tile_studio/analysis/). |

## Runtime architecture

Public Godot classes define `class_name`, script UIDs, exported properties,
signals, and method signatures. They own canonical resources or scene nodes;
feature modules receive a typed host and implement one area of behavior. A module never copies a board, creates a second occupancy index, or
silently takes ownership of a viewport node.

| Public class | Implementation directory | Responsibilities |
|---|---|---|
| `BoardDocument` | `data/board/` | Movement, gameplay, asset references, spatial indexes, validation, mutations, serialization and atomic file IO |
| `MTSPlacementController` | `viewport/placement/` | Brush settings, picking, hover, fill geometry/candidates/previews, selection, terrain contact and undo transactions |
| `MTSStudioViewport` | `viewport/studio/` | Scene lifecycle and binding, incremental synchronization, terrain/material rendering, contacts, lighting, sculpting, painting and input |
| `MaterialPaintPanel` | `ui/material_paint/` | Layout, dialogs, selection, mask recipes, splatmap import, profile actions and viewport binding |
| `MTSSurfaceMaterialPaint` | `rendering/paint/` | Palette slots, sparse strokes, image snapshots, splatmaps, GPU batches and PNG sidecars |
| `SurfaceMaterialFactory` | `rendering/materials/` | Texture preparation, ORM, shader variants, layer binding, board fields and material caching |

All paths above are below `addons/modular_tile_studio/`. Search for a method in its
public class to find the feature that implements it. Comments describing the
algorithm live beside that implementation. Small delegation methods preserve
external callers, Godot signal connections, and string-addressed undo callbacks.

## Authoritative state

`BoardDocument` owns terrain, placements, gameplay records and look profiles.
Its private spatial maps are rebuilt derivatives. Board version 13 uses a
portable JSON format. File writes stage, validate, preserve
the prior file as a backup, and then rename into place. Paint sidecars retain
checksums and explicit per-face palette mappings.

The viewport owns its `World3D`, renderer nodes and derived GPU resources. Feature
modules borrow that host; they do not register independent process loops or
signals. The existing node lifecycle handles cleanup. Placement transactions
mutate the document before sending refresh signals in both undo directions.

## Shader source

`rendering/mts_surface_gpu.gdshader` declares the shader type and feature defines,
then includes named files from `rendering/shader/`: uniforms, varyings, texture
sampling, paint weights, parallax, normals, world fields, material layers/masks,
and the vertex/fragment stages. Include order follows shader dependencies.

`rendering/shader_source.gd` recursively expands includes for the material factory.
Both variant rewriting and source hashing consume that expanded text, so changing
an included function refreshes live editor materials too. Cyclic or missing
includes fail visibly. `tests/shader_compile_check.gd` records a SHA-256 contract
for the expanded shader. The contract records the expanded shader source used by the material factory.
