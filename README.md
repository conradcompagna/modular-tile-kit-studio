# Modular Tile Kit Studio

**A native Godot editor for building modular isometric environments, with terrain, materials, props, lighting, and structured level data in one workspace.**

I built the studio to make detailed environments authorable through a constrained spatial vocabulary. Its grid, asset definitions, and board documents make the relationship between authored geometry and structured level data explicit.

[Setup](docs/SETUP.md) · [Tests](tests/README.md) · [Portfolio](https://github.com/conradcompagna)

[![Checks](https://github.com/conradcompagna/modular-tile-kit-studio/actions/workflows/checks.yml/badge.svg)](https://github.com/conradcompagna/modular-tile-kit-studio/actions/workflows/checks.yml)

## Engineering highlights

- **Native editor tooling:** a Godot main-screen plugin with placement tools, inspectors, terrain sculpting, lighting/material panels, and undo/redo.
- **Graphics infrastructure:** heightfield mesh construction, GPU shaders, painted material layers, surface blending, decals, and derived-map processing.
- **Geometry-to-spatial-data pipeline:** GLB import and canonical transforms, proportional sizing, mesh processing, voxel occupancy, and placement validation.
- **Structured authoring state:** canonical board/resources, JSON serialization, editor automation, background processing, optional ComfyUI integration, and focused regression tests.

## Open the editor

Import `project.godot` in **Godot 4.6.2**, allow the project to import, and select the **Tile Studio** main-screen tab. Start with your own assets or generate the small procedural demo tiles described in [setup](docs/SETUP.md).

## Explore the code

| Area | Starting point |
|---|---|
| Plugin lifecycle | [plugin.gd](addons/modular_tile_studio/plugin.gd) |
| Boards, assets, and profiles | [data/](addons/modular_tile_studio/data/) |
| Meshes, shaders, and materials | [rendering/](addons/modular_tile_studio/rendering/) |
| Terrain authoring | [generation/](addons/modular_tile_studio/generation/) |
| Image and GLB ingestion | [importers/](addons/modular_tile_studio/importers/) |
| Panels and interaction | [ui/](addons/modular_tile_studio/ui/), [viewport/](addons/modular_tile_studio/viewport/) |
| Image analysis and workflows | [analysis/](addons/modular_tile_studio/analysis/) |
| Checks and source utilities | [tests/](tests/), [tools/](tools/) |
| Companion Blender add-on | [integrations/blender/](integrations/blender/) |

The editor data and rendering layers are separate from the UI. This source release includes the editor, shaders, tests, and asset-preparation infrastructure, ready to use with your own art and board documents.

See [test coverage](tests/README.md), [publication contents](docs/PUBLICATION.md), and [third-party notices](THIRD_PARTY_NOTICES.md).
