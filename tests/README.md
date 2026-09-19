# Editor checks

Use Godot 4.6.2. Import the project before invoking individual scripts so global classes are registered.

```sh
godot --headless --path . --import
godot --headless --path . --script res://tests/terrain_heightfield_check.gd
godot --headless --path . --script res://tests/test_grid_sizing.gd
godot --headless --path . --script res://tests/texture_image_adjustment_check.gd
godot --headless --path . --script res://tests/prop_contact_regression_check.gd
```

CI runs these four suites: terrain topology/heightfields, proportional grid sizing, image adjustments, and prop/terrain contact including inspector behavior. A failed assertion produces a nonzero exit status. CI also parses every retained test script with `--check-only`.

Other focused scripts cover import transforms, viewport behavior, material painting, surface seams, and rendering. They remain separate entrypoints because their renderer and fixture requirements differ. Read the selected script before executing it; a parser check is not a completed rendering test.
