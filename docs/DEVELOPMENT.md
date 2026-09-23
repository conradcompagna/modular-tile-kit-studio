# Development commands

Use Python 3.10+ and the standard Godot 4.6.2 executable from the repository root:

```sh
python tools/check_repository.py
python tools/run_godot_checks.py --godot /path/to/godot
python tools/run_godot_checks.py --godot /path/to/godot --suite render --render-image /path/to/variants.png
```

The default runner imports a disposable project, parses the test scripts, then runs
15 core and two native-editor suites with real assertions. It disables the regular
plugin and its optional integrations. The explicit render suite needs a real renderer
(Vulkan by default, or `--rendering-driver d3d12` on Windows); it is separate from
headless CI and has a documented Windows shutdown limitation in this validation run.
See [coverage and limitations](../tests/README.md) and the [architecture](ARCHITECTURE.md).

Blender registration, conversion and save/reopen checks have separate instructions
under [the companion integration](../integrations/blender/README.md). A headless test
does not establish interactive modal brush behavior. Preserve Godot resource UIDs,
public class names, undo callbacks and board formats when editing helpers.

See [contributing](../CONTRIBUTING.md) and [security](../SECURITY.md).
