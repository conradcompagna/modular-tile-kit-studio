# Setup and verification

Use Godot 4.6.2 with the Forward+ renderer. Import `project.godot`, allow script registration to finish, and select the Tile Studio tab. No additional editor tooling add-on is required by this published project.

For optional ComfyUI analysis, run your own ComfyUI service and configure the existing analysis settings. Workflow JSON and the custom-node source are under `addons/modular_tile_studio/analysis/`; model weights and the ComfyUI installation are external.

## Checks

From the repository root:

```sh
godot --headless --path . --import
```

Additional focused checks cover materials, terrain, placement, textures, and viewport behavior. Some require a rendering-capable process or named source assets. See each test's setup before running it.

The `tools/make_demo_assets.gd` script generates small procedural tiles locally. Its generated images belong in the ignored `tile_library/` directory, not in source control.

## Published boundary

The editor's add-on, shaders, resource models, workflow definitions, tests, and source utilities are included. The game directory, its launch scene and tests, the development-tool runtime autoload, large art packs, source GLBs, authored game boards, and generated render caches are excluded.

The companion Blender add-on is preserved in `integrations/blender/`. It has its own `blender_manifest.toml`; it is not needed to open the Godot editor.

## Export validation

The editor imports successfully in Godot 4.6.2. The focused terrain heightfield
regression (`tests/terrain_heightfield_check.gd`) passes with zero failures.
The historical aggregate runner,
`tests/run_tests.gd`, currently fails to parse against the current editor API
(including an unavailable `BlockoutCompiler` and a changed `add_light` signature).
It remains in the source publication as historical test infrastructure; it is not
a passing release gate. Focused tests have separate entrypoints and requirements.
