#!/usr/bin/env python3
"""Fail when internal diagnostic/test implementation leaks into a Release app."""
import os
import pathlib
import plistlib
import sys

app = pathlib.Path(sys.argv[1])
info_path = app / "Info.plist"
if not info_path.exists():
    info_path = app / "Contents/Info.plist"
info = plistlib.loads(info_path.read_bytes())
assert info["CFBundleIdentifier"] == "com.chameleonenterprise.velacanto"
expected_display_name = os.environ.get("VELACANTO_APP_DISPLAY_NAME", "VelaCanto")
assert expected_display_name in ("VelaCanto Alpha", "VelaCanto")
assert info["CFBundleDisplayName"] == expected_display_name
assert info["CFBundleName"] == expected_display_name
assert info["CFBundleShortVersionString"] == "0.6.0"
assert info["CFBundleVersion"] == os.environ.get("VELACANTO_BUILD_NUMBER", "233")
assert info["ITSAppUsesNonExemptEncryption"] is False
assert "com.chameleonenterprise.velacanto.continuation.v1" in info.get("NSUserActivityTypes", []), "Missing Handoff activity registration"
privacy_path = app / "PrivacyInfo.xcprivacy"
if not privacy_path.exists():
    privacy_path = app / "Contents/Resources/PrivacyInfo.xcprivacy"
privacy = plistlib.loads(privacy_path.read_bytes())
reasons = {entry["NSPrivacyAccessedAPIType"]: entry["NSPrivacyAccessedAPITypeReasons"]
           for entry in privacy["NSPrivacyAccessedAPITypes"]}
for category, reason in (("UserDefaults", "CA92.1"), ("FileTimestamp", "C617.1"), ("DiskSpace", "E174.1")):
    assert reason in reasons.get("NSPrivacyAccessedAPICategory" + category, []), category
executable = app / info["CFBundleExecutable"]
if not executable.exists():
    executable = app / "Contents/MacOS" / info["CFBundleExecutable"]
extension_binaries = []
extensions = list(app.rglob("*.appex"))
if (app / "Contents").exists():
    assert not extensions, "iOS Siri extension bundled on Mac"
    assert "INIntentsSupported" not in info, "Unsupported Siri route advertised on Mac"
else:
    assert info["INIntentsSupported"] == ["INPlayMediaIntent"]
    assert info["NSSiriUsageDescription"]
    assert len(extensions) == 1 and extensions[0].name == "VelacantoIntents.appex"
    extension = extensions[0]
    extension_info = plistlib.loads((extension / "Info.plist").read_bytes())
    assert extension_info["CFBundleIdentifier"] == info["CFBundleIdentifier"] + ".intents"
    assert extension_info["CFBundleVersion"] == info["CFBundleVersion"]
    assert extension_info["CFBundleShortVersionString"] == info["CFBundleShortVersionString"]
    configuration = extension_info["NSExtension"]
    assert configuration["NSExtensionPointIdentifier"] == "com.apple.intents-service"
    assert configuration["NSExtensionPrincipalClass"] == "VelacantoIntents.IntentHandler"
    attributes = configuration["NSExtensionAttributes"]
    assert attributes["IntentsSupported"] == ["INPlayMediaIntent"]
    assert attributes["SupportedMediaCategories"] == ["INMediaCategoryMusic"]
    extension_binaries.append(extension / extension_info["CFBundleExecutable"])
markers = (
    b"player.siri", b"audioSession.activation.denied",
    b"player.hls.copy", b"player.hls.playlist", b"player.hls.negotiation",
    b"player.hls.source", b"player.hls.selection", b"player.comparison.access",
    b"foundationDeliveryComparison", b"player.hls.cleanup", b"MP3 HLS",
    b"Copy-only mode requires MP3", "HLS · original when compatible".encode("utf-8"),
    b"Original-preferred HLS copies",
    b"foundation-journal.log", b"-foundationTesting", b"seek.request direction=",
    b"seek.complete direction=", b"FoundationSystemMediaControlsTests",
    b"-foundationDownloadsUITesting", b"DownloadUITestFixtures", b"FoundationDownloadUIFixture",
    b"FoundationAccountUITestHarness", b"synthetic-not-a-password",
    b"-diagnosticCarPlaySearch", b"-diagnosticCarPlayNativeSearch",
    b"FoundationCarPlayInputDiagnostic", b"CarPlaySearchDiagnostics",
    b"-diagnosticHomeRebound", b"HomeReboundDiagnostics", b"FoundationHomeReboundDiagnostic",
    b"-fixtureSharedChromeEvidence", b"-fixtureRemoteListening", b"FoundationChromeUIScrollProbe",
)
for binary in [executable, *extension_binaries, *app.rglob("*.dylib")]:
    content = binary.read_bytes()
    assert not any(marker in content for marker in markers), f"Internal code in {binary.name}"
assert not list(app.rglob("*.xctest")), "Tests bundled in Release"
print(f"Release identity and diagnostic exclusion passed: {app.name}")
