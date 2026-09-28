#!/usr/bin/env python3
"""Fail when internal diagnostic/test implementation leaks into a Release app."""
import pathlib
import plistlib
import sys

app = pathlib.Path(sys.argv[1])
info_path = app / "Info.plist"
if not info_path.exists():
    info_path = app / "Contents/Info.plist"
info = plistlib.loads(info_path.read_bytes())
assert info["CFBundleIdentifier"] == "com.chameleonenterprise.velacanto"
assert info["CFBundleDisplayName"] == "Velacanto"
assert info["CFBundleShortVersionString"] == "0.3.5"
assert info["CFBundleVersion"] == "109"
executable = app / info["CFBundleExecutable"]
if not executable.exists():
    executable = app / "Contents/MacOS" / info["CFBundleExecutable"]
markers = (
    b"foundation-journal.log", b"-foundationTesting", b"seek.request direction=",
    b"seek.complete direction=", b"FoundationSystemMediaControlsTests",
)
for binary in [executable, *app.rglob("*.dylib")]:
    content = binary.read_bytes()
    assert not any(marker in content for marker in markers), f"Internal code in {binary.name}"
assert not list(app.rglob("*.xctest")), "Tests bundled in Release"
print(f"Release identity and diagnostic exclusion passed: {app.name}")
