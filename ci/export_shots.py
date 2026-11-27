"""Export xcresult screenshots under their XCTest attachment names."""
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys

NAMED_PNG = re.compile(r"(store-(?:zh-Hans|en|zh-Hant|ja)-\d{2}-[a-z]+|paid-01-paywall)(?=$|[_.\s-])")


def matching_name(value):
    match = NAMED_PNG.search(value)
    return match.group(1) + ".png" if match else None


def copy_named_shots(exported, output):
    written = set()
    manifest = exported / "manifest.json"
    if manifest.is_file():
        for test in json.loads(manifest.read_text(encoding="utf-8")):
            for item in test.get("attachments", []):
                source = exported / item.get("exportedFileName", "")
                target = matching_name(item.get("suggestedHumanReadableName", "") or "")
                if target and source.is_file() and source.suffix.lower() == ".png":
                    shutil.copy2(source, output / target)
                    written.add(target)
    for source in exported.rglob("*.png"):
        target = matching_name(source.name)
        if target and target not in written:
            shutil.copy2(source, output / target)
            written.add(target)
    return written


def main():
    result, destination = sys.argv[1:3]
    output = Path(destination)
    output.mkdir(parents=True, exist_ok=True)
    exported = output / "xcresult"
    exported.mkdir(exist_ok=True)
    subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", result,
                    "--output-path", str(exported)], check=True)
    names = copy_named_shots(exported, output)
    # Some Xcode runners can also write PNGs directly to the destination via SHOTS_DIR.
    names.update(path.name for path in output.glob("*.png") if matching_name(path.name) == path.name)
    if len(names) != 16:
        sys.exit(f"Expected 16 named screenshots, found {len(names)}: {', '.join(sorted(names))}")
    print(f"Exported {len(names)} screenshots to {output}")


if __name__ == "__main__":
    main()
