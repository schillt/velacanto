#!/usr/bin/env python3
"""Require zero formatting findings across maintained native source and test trees."""
import pathlib
import subprocess

source_roots = [
    str(path)
    for name in ("Sources", "Tests", "Shared", "Widgets", "Intents", "UITests")
    if (path := pathlib.Path("NativeFoundation") / name).is_dir()
]
if not source_roots:
    raise SystemExit("No maintained native source or test trees found for formatting.")

result = subprocess.run([
    "xcrun", "swift-format", "lint", "--configuration", ".swift-format", "--strict",
    "--recursive", *source_roots,
], capture_output=True, text=True)
output = result.stdout + result.stderr
if result.returncode or output.strip():
    print(output, end="" if output.endswith("\n") else "\n")
    raise SystemExit(result.returncode or 1)
print(f"Formatting: zero findings across {len(source_roots)} maintained native trees")
