# Editor checks

Use Python 3.10+ and **Godot 4.6.2**; these public fixtures need no private asset library, ComfyUI server, API credentials, or model weights.

```sh
python tools/check_repository.py
python tools/run_godot_checks.py --godot /path/to/godot
```

The runner copies the source into a disposable project, disables the normal service plugins, imports resources, parses retained test entrypoints, and runs 15 core checks plus two native-editor checks. `GODOT` can supply the executable instead of `--godot`. A timeout, nonzero engine exit, script error, or shader compilation error fails the run; a Godot process exiting zero alone is insufficient.

| Suite | Coverage |
|---|---|
| `--suite core` | Heightfields, grid sizing, image processing, prop contact, sparse paint and sidecars, viewport brush integration, tile targets, golden board saves/reloads/backups, decals, PBR baking, seams, stamps, tint, skirts and expanded shader source |
| `--suite editor` | Placement mutation/undo/redo and incremental identity; material panel, palette removal, resolution changes, splatmap import, UI resynchronization and live material updates |
| `--suite render` | 18 actual Vulkan/Forward+ shader draws covering opaque/cutout/blend, texture variation on/off, and zero/one/four compiled layers |

The editor suite loads fixtures through a test-only plugin inside the native editor lifecycle. Passing `--editor --script` to a custom `SceneTree` can leak editor resources or crash during shutdown on Windows; that is not the test entrypoint. No test plugin is enabled in the normal project.

Rendering is separate because it needs a display and working Vulkan renderer:

```sh
python tools/run_godot_checks.py --godot /path/to/godot --suite render --render-image shader-variants.png
```

This captures real rendered pixels, checks that every variant draws visible textured geometry, and rejects the dummy headless renderer. It is a shader smoke test, not an exhaustive visual correctness or performance benchmark. CI runs the core/editor suites; local GPU validation is reported separately.

`fixtures/board_v13.json` was recorded from the original implementation at `824fa54`, using `fixtures/public_board.gd`; stable placement IDs make it deterministic. Update it only for a reviewed serialization change. The fixture covers paint and decal face ownership, enemy packs, terrain heights and movement state; it does not redistribute authored game boards.

Two pre-heightfield tests are explicitly [archived](legacy/README.md). `alpha_channel_check.gd` is an optional report over a user's own asset library, not a self-contained CI assertion. The remaining focused scripts are retained for manual diagnosis; their parser checks do not imply their external fixtures or old assertions were exercised.

The Blender companion uses a separate [registration/conversion/save/reopen smoke test](../integrations/blender/README.md).
