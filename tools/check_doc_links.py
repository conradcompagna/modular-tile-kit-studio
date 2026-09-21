"""Check local Markdown file targets; remote URLs and heading anchors are excluded."""
from pathlib import Path
import re
import subprocess
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parents[1]


def main():
    names = subprocess.check_output(
        ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"], cwd=ROOT
    ).decode("utf-8").split("\0")
    failures = []
    checked = 0
    for name in sorted(set(names)):
        path = ROOT / name
        if path.suffix.lower() != ".md" or not path.is_file() or name.startswith("static/foliate-js/"):
            continue
        text = re.sub(r"(?ms)^```.*?^```[^\n]*", "", path.read_text(encoding="utf-8"))
        for match in re.finditer(r"\[[^\]\n]*\]\((<[^>]+>|[^)\n]+)\)", text):
            target = match.group(1).strip()
            if target.startswith("<"):
                target = target[1:target.index(">")]
            else:
                target = target.split(' "', 1)[0].split(" '", 1)[0]
            parsed = urlsplit(target)
            if not parsed.path or parsed.scheme or parsed.netloc:
                continue
            checked += 1
            resolved = (ROOT if target.startswith("/") else path.parent) / unquote(parsed.path).lstrip("/")
            if not resolved.exists():
                failures.append(f"{name}: missing {target}")
    print("\n".join(failures)) if failures else None
    print(f"Checked {checked} local Markdown targets; {len(failures)} missing.")
    return int(bool(failures))


if __name__ == "__main__":
    raise SystemExit(main())
