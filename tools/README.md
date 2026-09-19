# Editor utilities

- `make_demo_assets.gd` generates a small procedural image kit into ignored `tile_library/` storage.
- `rebuild_library.gd` rebuilds library metadata for locally supplied assets.
- `migrations/` contains explicit library-format migrations for existing local libraries.

Run the selected script with `godot --headless --path . --script res://tools/<script>.gd`. Migration scripts write library resources; inspect their input paths and use a copy of your local library. No project-specific art-generation batches or authored game assets are distributed.
