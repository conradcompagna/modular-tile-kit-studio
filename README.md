# Modular Tile Kit Studio

**A native Godot editor for building modular isometric environments, with terrain, materials, props, lighting, and structured level data in one authoring workspace.**

I built the studio to make visually detailed environments authorable through a constrained spatial vocabulary. Its grid, asset definitions, and board documents make the relationship between authored geometry and structured level data explicit.

[Portfolio](https://github.com/conradcompagna) · [Setup and tests](docs/SETUP.md)

## Engineering highlights

- **A substantial native authoring interface:** a Godot main-screen editor plugin with placement tools, inspectors, terrain sculpting, lighting/material panels, and undo/redo.
- **Graphics and material infrastructure:** heightfield mesh construction, GPU shaders, painted material layers, surface blending, decals, and derived-map processing.
- **Geometry-to-spatial-data pipeline:** GLB import and canonical transforms, proportional sizing, mesh processing, voxel occupancy, and explicit placement validation.
- **Inspectable authoring state:** canonical board/resources, JSON serialization, editor automation, background processing, ComfyUI workflow integration, and focused regression tests.

## Open the editor

Import `project.godot` in **Godot 4.6.2** and select the **Tile Studio** main-screen tab. This checkout is an editor project; it does not contain the unfinished game or a game launch scene.

The large source-art library, authored game boards, generated maps, and model weights are excluded. Start with your own assets. ComfyUI is an optional external analysis service; configure its paths explicitly for your machine. Server autostart is disabled in this distribution.

## Code guide

| Area | Directory |
|---|---|
| Plugin lifecycle and integration | `addons/modular_tile_studio/plugin.gd` |
| Canonical boards, assets and profiles | `addons/modular_tile_studio/data/` |
| Meshes, shaders and materials | `addons/modular_tile_studio/rendering/` |
| Terrain authoring | `addons/modular_tile_studio/generation/` |
| Image and GLB ingestion | `addons/modular_tile_studio/importers/` |
| Panels, camera and interaction | `addons/modular_tile_studio/ui/`, `viewport/` |
| Image analysis and workflow templates | `addons/modular_tile_studio/analysis/` |
| Editor checks and automation | `tests/`, `tools/` |
| Companion Blender integration | `integrations/blender/` |

The data and rendering layers are separate from the editor UI. Boards remain structured authoring documents; the exported repository includes marker-authoring features, not the game that consumes them.

`tools/` also retains asset-authoring and diagnostic scripts. Several operate on named development assets that are not distributed here; they are infrastructure examples, not a bundled art pack.

See [publication contents](docs/PUBLICATION.md) and [third-party notices](THIRD_PARTY_NOTICES.md).
