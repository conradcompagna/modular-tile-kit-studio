# Setup

Use Godot 4.6.2 with the Forward+ renderer. Import `project.godot`, allow script registration to finish, and select the Tile Studio tab. The project is an editor workspace and has no game launch scene.

## Assets

Import your own images and GLB assets through the editor. To generate a small set of procedural surface tiles locally:

```sh
godot --headless --path . --import
godot --headless --path . --script res://tools/make_demo_assets.gd
```

The generated images live in the ignored `tile_library/` directory. The original art library and authored boards are not included.

## Optional integrations

For ComfyUI analysis, run your own ComfyUI service and configure the analysis settings explicitly. Workflow JSON and custom-node source are under `addons/modular_tile_studio/analysis/`; the service installation and model weights are external. Server autostart is disabled in this distribution.

The companion Blender add-on lives in `integrations/blender/` and has its own `blender_manifest.toml`. It is not required to open the Godot editor.

## Validation

See [tests](../tests/README.md) for the headless CI commands and the separate rendering checks. CI imports the editor, parses the focused scripts, and runs the terrain, grid, texture-adjustment, and prop-contact regressions. Interactive checks cover the Forward+ viewport and imported art.
