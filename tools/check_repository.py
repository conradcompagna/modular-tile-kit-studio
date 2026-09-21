"""Check maintained source sizes and Python syntax without importing applications."""
from pathlib import Path
import ast
import json
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
LIMIT = 2000
VENDORED = ("static/vendor/", "static/foliate-js/", "static/marked.min.js")

def main():
    baseline_path = ROOT / "tools/source-size-baseline.json"
    baseline = json.loads(baseline_path.read_text()) if baseline_path.exists() else {}
    paths = subprocess.check_output(
        ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"], cwd=ROOT
    ).decode("utf-8").split("\0")
    failures = []
    oversized = {}
    parsed = 0
    for name in sorted(set(paths) - {""}):
        path = ROOT / name
        if not path.is_file() or name.startswith(VENDORED):
            continue
        data = path.read_bytes()
        if b"\0" in data:
            continue
        lines = len(data.splitlines())
        if lines > LIMIT:
            oversized[name] = lines
            if lines > max(LIMIT, baseline.get(name, LIMIT)):
                failures.append(f"{name}: {lines} lines (limit {max(LIMIT, baseline.get(name, LIMIT))})")
        if path.suffix == ".py":
            try:
                ast.parse(data, filename=name)
                parsed += 1
            except SyntaxError as exc:
                failures.append(f"{name}:{exc.lineno}: {exc.msg}")
    for name in baseline:
        if name not in oversized:
            failures.append(f"Remove resolved size exemption: {name}")
    for failure in failures:
        print(failure, file=sys.stderr)
    print(f"Parsed {parsed} Python files; {len(oversized)} existing size exemptions.")
    return int(bool(failures))

if __name__ == "__main__":
    raise SystemExit(main())
