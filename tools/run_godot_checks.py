"""Run public fixtures in a disposable Godot project with service plugins disabled."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CORE = (
    "terrain_heightfield_check", "test_grid_sizing", "texture_image_adjustment_check",
    "prop_contact_regression_check", "material_paint_check", "material_paint_viewport_check",
    "material_tile_targeting_check", "board_document_check", "decal_surface_check",
    "runtime_map_bake_check", "surface_seam_solver_check", "stamp_presentation_check",
    "texture_tint_check", "terrain_skirt_fingerprint", "shader_compile_check",
)
EDITOR = ("placement_viewport_check", "material_paint_ui_check")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", default=os.environ.get("GODOT", "godot"))
    parser.add_argument("--suite", choices=("core", "editor", "render", "all"), default="all",
                        help="all runs core and editor; rendering is an explicit separate suite")
    parser.add_argument("--render-image", type=Path)
    parser.add_argument("--rendering-driver", choices=("vulkan", "d3d12"), default="vulkan",
                        help="GPU driver for the explicit render suite (D3D12 requires Windows)")
    args = parser.parse_args()
    executable = shutil.which(args.godot)
    if executable is None:
        parser.error(f"Godot executable not found: {args.godot}")
    # The Windows console launcher spawns a child; use the actual engine so
    # timeout termination also terminates the fixture and closes its log pipe.
    if executable.endswith("_console.exe"):
        native = Path(executable.replace("_console.exe", ".exe"))
        if native.exists():
            executable = str(native)
    version = subprocess.check_output([executable, "--version"], text=True).strip()
    if not version.startswith("4.6.2."):
        parser.error(f"These fixtures target Godot 4.6.2; found {version}")
    startup = None
    if os.name == "nt":
        startup = subprocess.STARTUPINFO()
        startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
        startup.wShowWindow = 0

    with tempfile.TemporaryDirectory(prefix="mts-checks-") as temporary:
        project = Path(temporary)
        for directory in ("addons", "tests"):
            shutil.copytree(ROOT / directory, project / directory)
        shutil.copy2(ROOT / "icon.svg", project / "icon.svg")
        source_settings = (ROOT / "project.godot").read_text(encoding="utf-8")
        settings = source_settings.replace(
            'enabled=PackedStringArray("res://addons/modular_tile_studio/plugin.cfg")',
            "enabled=PackedStringArray()",
        )
        if settings == source_settings:
            raise RuntimeError("Expected editor plugin setting was not found; refusing an unisolated run")
        (project / "project.godot").write_text(settings, encoding="utf-8")

        def run(label: str, arguments: list[str], timeout: int = 120) -> None:
            command = [executable, "--path", str(project), *arguments]
            try:
                result = subprocess.run(command, capture_output=True, text=True, encoding="utf-8",
                                        errors="replace", timeout=timeout, startupinfo=startup)
            except subprocess.TimeoutExpired as exc:
                print(exc.stdout or "")
                print(exc.stderr or "")
                raise RuntimeError(f"{label}: timed out after {timeout}s") from exc
            output = result.stdout + result.stderr
            failed = result.returncode or re.search(
                r"SCRIPT ERROR:|SHADER ERROR:|Shader compilation failed|Failed to compile", output
            )
            if failed:
                print(output)
                raise RuntimeError(f"{label}: Godot failed (exit {result.returncode})")
            print(f"PASS {label}", flush=True)

        run("import isolated project", ["--headless", "--import"])
        for script in sorted((project / "tests").glob("*.gd")):
            run(f"parse {script.name}", ["--headless", "--check-only", "--script", f"res://tests/{script.name}"])
        if args.suite in ("core", "all"):
            for name in CORE:
                run(name, ["--headless", "--script", f"res://tests/{name}.gd"])
        if args.suite in ("editor", "all"):
            (project / "project.godot").write_text(settings.replace(
                "enabled=PackedStringArray()", 'enabled=PackedStringArray("res://tests/editor/plugin.cfg")'
            ), encoding="utf-8")
            for name in EDITOR:
                run(name, ["--headless", "--editor", "--", f"--fixture={name}"])
        if args.suite == "render":
            options = ["--disable-render-loop", "--rendering-driver", args.rendering_driver, "--rendering-method", "forward_plus",
                       "--audio-driver", "Dummy", "--position", "-10000,-10000",
                       "--script", "res://tests/shader_render_check.gd"]
            if args.render_image:
                options.extend(["--", f"--image={args.render_image.resolve()}"])
            run(f"18 surface shader variants on {args.rendering_driver}", options, timeout=900)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
