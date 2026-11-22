#!/usr/bin/env python3
"""Fail when internal diagnostic/test implementation leaks into a Release app."""
import os
import pathlib
import plistlib
import subprocess
import json
import sys

app = pathlib.Path(sys.argv[1])
info_path = app / "Info.plist"
if not info_path.exists():
    info_path = app / "Contents/Info.plist"
info = plistlib.loads(info_path.read_bytes())
canonical_bundle_id = "com.chameleonenterprise.velacanto"
expected_bundle_id = os.environ.get("VELACANTO_APP_BUNDLE_IDENTIFIER", canonical_bundle_id)
is_mac = (app / "Contents").exists()
assert expected_bundle_id == canonical_bundle_id or (
    is_mac and expected_bundle_id == canonical_bundle_id + ".siri-validation"
), "Unexpected application identity"
assert info["CFBundleIdentifier"] == expected_bundle_id
expected_display_name = os.environ.get("VELACANTO_APP_DISPLAY_NAME", "VelaCanto")
assert expected_display_name in ("VelaCanto Alpha", "VelaCanto")
assert info["CFBundleDisplayName"] == expected_display_name
assert info["CFBundleName"] == expected_display_name
# Read the app target's checked-in Release settings, never the artifact under test.
# This keeps default verification aligned without trusting its own Info.plist.
project_file = pathlib.Path(__file__).resolve().parents[1] / (
    "NativeFoundation/VelacantoFoundation.xcodeproj/project.pbxproj"
)
project = json.loads(subprocess.check_output(["/usr/bin/plutil", "-convert", "json", "-o", "-", str(project_file)]))
objects = project["objects"]
targets = [value for value in objects.values()
           if value.get("isa") == "PBXNativeTarget" and value.get("name") == "VelacantoFoundation"]
assert len(targets) == 1, "Expected one app target"
configurations = objects[targets[0]["buildConfigurationList"]]["buildConfigurations"]
release_settings = [objects[key]["buildSettings"] for key in configurations
                    if objects[key]["name"] == "Release"]
assert len(release_settings) == 1, "Expected one Release configuration"
settings = release_settings[0]
expected_version = os.environ.get("VELACANTO_MARKETING_VERSION", settings["MARKETING_VERSION"])
expected_build = os.environ.get("VELACANTO_BUILD_NUMBER", settings["CURRENT_PROJECT_VERSION"])
assert expected_version in ("0.6.0", "0.7.0"), "Unexpected marketing version"
assert isinstance(expected_build, str) and expected_build.isascii() and expected_build.isdigit(), "Invalid build number"
assert info["CFBundleShortVersionString"] == expected_version
assert info["CFBundleVersion"] == expected_build
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
expected_extensions = {"VelaCantoWidgets.appex"}
if is_mac:
    assert "INIntentsSupported" not in info, "Unsupported Siri route advertised on Mac"
else:
    expected_extensions.add("VelacantoIntents.appex")
    assert info["INIntentsSupported"] == ["INPlayMediaIntent"]
    assert info["NSSiriUsageDescription"]
assert len(extensions) == len(expected_extensions) and {
    extension.name for extension in extensions
} == expected_extensions, "Unexpected or missing app extension"
widget_group = "group.com.chameleonenterprise.velacanto.widgets"
assert info["VelacantoWidgetAppGroupIdentifier"] == widget_group
for extension in extensions:
    assert not extension.is_symlink()
    assert extension.parent == app / ("Contents/PlugIns" if is_mac else "PlugIns")
    resources = extension / "Contents/Resources" if is_mac else extension
    extension_info_path = extension / ("Contents/Info.plist" if is_mac else "Info.plist")
    extension_info = plistlib.loads(extension_info_path.read_bytes())
    assert extension_info["CFBundleVersion"] == info["CFBundleVersion"]
    assert extension_info["CFBundleShortVersionString"] == info["CFBundleShortVersionString"]
    assert extension_info["CFBundleSupportedPlatforms"] == info["CFBundleSupportedPlatforms"]
    configuration = extension_info["NSExtension"]
    if extension.name == "VelaCantoWidgets.appex":
        assert extension_info["CFBundleIdentifier"] == info["CFBundleIdentifier"] + ".widgets"
        assert configuration["NSExtensionPointIdentifier"] == "com.apple.widgetkit-extension"
        assert extension_info["VelacantoWidgetAppGroupIdentifier"] == widget_group
        widget_privacy = plistlib.loads((resources / "PrivacyInfo.xcprivacy").read_bytes())
        assert widget_privacy["NSPrivacyTracking"] is False
        assert widget_privacy["NSPrivacyCollectedDataTypes"] == []
        widget_reasons = {
            entry["NSPrivacyAccessedAPIType"]: entry["NSPrivacyAccessedAPITypeReasons"]
            for entry in widget_privacy["NSPrivacyAccessedAPITypes"]
        }
        assert "C617.1" in widget_reasons.get("NSPrivacyAccessedAPICategoryFileTimestamp", [])
    else:
        assert not is_mac
        assert extension_info["CFBundleIdentifier"] == info["CFBundleIdentifier"] + ".intents"
        assert configuration["NSExtensionPointIdentifier"] == "com.apple.intents-service"
        assert configuration["NSExtensionPrincipalClass"] == "VelacantoIntents.IntentHandler"
        attributes = configuration["NSExtensionAttributes"]
        assert attributes["IntentsSupported"] == ["INPlayMediaIntent"]
        assert attributes["SupportedMediaCategories"] == ["INMediaCategoryMusic"]
        # The unchanged Siri forwarding shim uses no required-reason APIs. If a
        # manifest is packaged, it may not introduce tracking or collected data.
        siri_privacy_path = resources / "PrivacyInfo.xcprivacy"
        if siri_privacy_path.exists():
            siri_privacy = plistlib.loads(siri_privacy_path.read_bytes())
            assert siri_privacy["NSPrivacyTracking"] is False
            assert siri_privacy["NSPrivacyCollectedDataTypes"] == []
    binary_root = extension / "Contents/MacOS" if is_mac else extension
    extension_binaries.append(binary_root / extension_info["CFBundleExecutable"])
markers = (
    b"player.siri", b"audioSession.activation.denied", b"queueMorph", b"queueCompleted", b"queuePhase", b"metadataCompleted",
    b"player.hls.copy", b"player.hls.playlist", b"player.hls.negotiation",
    b"player.hls.source", b"player.hls.selection", b"player.comparison.access",
    b"foundationDeliveryComparison", b"player.hls.cleanup", b"MP3 HLS",
    b"Copy-only mode requires MP3", "HLS · original when compatible".encode("utf-8"),
    b"Original-preferred HLS copies",
    b"foundation-journal.log", b"-foundationTesting", b"seek.request direction=",
    b"seek.complete direction=", b"FoundationSystemMediaControlsTests",
    b"-foundationDownloadsUITesting", b"DownloadUITestFixtures", b"FoundationDownloadUIFixture",
    b"FoundationAccountUITestHarness", b"synthetic-not-a-password",
    b"-foundationRootLyricsRetirement", b"FoundationIsolatedLyricsRetirement",
    b"Complete delayed authentication",
    b"-diagnosticCarPlaySearch", b"-diagnosticCarPlayNativeSearch",
    b"-diagnosticNativeDownload", b"download.native stage=", b"FoundationNativeDownloadErrorFields",
    b"FoundationCarPlayInputDiagnostic", b"CarPlaySearchDiagnostics",
    b"-diagnosticHomeRebound", b"HomeReboundDiagnostics", b"FoundationHomeReboundDiagnostic",
    b"-fixtureQueueArtworkTransition", b"-fixtureSharedChromeEvidence", b"-fixtureRemoteListening", b"FoundationChromeUIScrollProbe",
)
for binary in [executable, *extension_binaries, *app.rglob("*.dylib")]:
    content = binary.read_bytes()
    assert not any(marker in content for marker in markers), f"Internal code in {binary.name}"
assert not list(app.rglob("*.xctest")), "Tests bundled in Release"
print(f"Release identity and diagnostic exclusion passed: {app.name}")
