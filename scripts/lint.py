#!/usr/bin/env python3
"""Reject new formatting debt while preserving the accepted build 106 source verbatim.

The checked-in diagnostics are existing build 106 formatting findings, to remove in
post-release cleanup. Compilation/tests remain strict and are never baselined.
"""
import pathlib
import subprocess

result = subprocess.run([
    "xcrun", "swift-format", "lint", "--configuration", ".swift-format", "--strict",
    "--recursive", "NativeFoundation/Sources", "NativeFoundation/Tests",
], capture_output=True, text=True)
findings = set((result.stdout + result.stderr).splitlines())
baseline = set(pathlib.Path("scripts/foundation-lint-baseline.txt").read_text().splitlines())
new = findings - baseline
if new or (result.returncode and not findings):
    print("\n".join(sorted(new)))
    raise SystemExit(result.returncode or 1)
print(f"Formatting: no new findings; {len(findings)} existing build 106 findings retained for separate cleanup")
