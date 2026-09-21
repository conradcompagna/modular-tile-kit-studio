# Source ownership and feature boundaries

The existing public Godot classes retain their `class_name`, script UID, exported
properties, signals, and method signatures. They own canonical resources or scene
nodes; their feature modules receive a typed host and implement one area of
behavior. A module never copies a board, creates a second occupancy index, or
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
New code should use the narrowest existing feature boundary; do not put another
subsystem into the facade just because it can access the host.

## Authoritative state

`BoardDocument` owns terrain, placements, gameplay records and look profiles.
Its private spatial maps are rebuilt derivatives. Board version 13 and the
portable JSON format are unchanged. File writes still stage, validate, preserve
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
includes fail visibly. The initial extraction reconstructs the original shader
exactly; its SHA-256 contract is recorded in `tests/shader_compile_check.gd`.
Intentional later shader changes must update that contract after review and a
renderer check.

## Refactor evidence

The extraction preserved the bodies of 866 GDScript methods after accounting for
explicit host/class qualification; the remaining method intentionally changed to
read expanded shader source. A golden version-13 board was generated with commit
`824fa54` before the Godot extraction. The current save/reload test checks that
serialization, face indexes, movement state, gameplay indexes and backups agree.

The [test guide](../tests/README.md) distinguishes core, native-editor, and actual
renderer checks. The [Blender integration](../integrations/blender/README.md) has
its own module map and registration/conversion test.
