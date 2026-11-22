#!/bin/sh
# Synthetic UI only. Preserve the production simulator app and all real sessions.
set -eu

# Named selections are deliberately small affected-flow checks, not a full-suite
# substitute. Keep names tied to real test methods in FoundationDownloadsUITests.
if [ "${1:-}" = --list-smokes ]; then
  [ "$#" -eq 1 ] || { printf '%s\n' 'Usage: test-downloads-ui.sh --list-smokes' >&2; exit 2; }
  printf '%s\n' search downloads signin queue playlist adaptive
  exit 0
fi
if [ "${1:-}" = --smoke ]; then
  [ "$#" -eq 2 ] || { printf '%s\n' 'Usage: test-downloads-ui.sh --smoke {search|downloads|signin|queue|playlist|adaptive}' >&2; exit 2; }
  case "$2" in
    search)
      set -- \
        -only-testing:VelacantoDownloadsUITests/FoundationDownloadsUITests/testSearchUpdatesWhileTypingWithoutSubmitAndRetiresRapidReplacement \
        -only-testing:VelacantoDownloadsUITests/FoundationDownloadsUITests/testSearchReportsUnwalkedFallbackWithNoVisibleMatches \
        -only-testing:VelacantoDownloadsUITests/FoundationDownloadsUITests/testSearchEmptyFallbackContinuesAtVisibleEndWithoutScanningFurtherPages \
        -only-testing:VelacantoDownloadsUITests/FoundationDownloadsUITests/testPlaylistSearchStartsBelowFoldAndSharesProgressWithSeeAll \
        -only-testing:VelacantoDownloadsUITests/FoundationDownloadsUITests/testPlaylistSearchCancelsHeldBatchWhenLeavingSearch
      ;;
    downloads)
      set -- \
        -only-testing:VelacantoDownloadsUITests/FoundationDownloadsUITests/testWaitingCancellationFailureRetryAndRemoval \
        -only-testing:VelacantoDownloadsUITests/FoundationDownloadsUITests/testRelaunchDuplicateTracksLocalPlaybackAndRemoveAll
      ;;
    signin)
      set -- \
        -only-testing:VelacantoDownloadsUITests/FoundationDownloadsUITests/testMobileSignInBrandingSecureFieldsAndServerErrorsLightAndDark \
        -only-testing:VelacantoDownloadsUITests/FoundationDownloadsUITests/testMobileSignInLargeTextKeyboardFocusAndInProgressCancellation \
        -only-testing:VelacantoDownloadsUITests/FoundationDownloadsUITests/testCancelledSyntheticSignInCannotOpenAccount
      ;;
    queue)
      set -- -only-testing:VelacantoDownloadsUITests/FoundationDownloadsUITests/testNativeQueuePresentationActionsReorderAndPlaybackContinuity
      ;;
    playlist)
      set -- -only-testing:VelacantoDownloadsUITests/FoundationDownloadsUITests/testNativePlaylistOccurrenceDragAndActionsPreservePlayingQueue
      ;;
    adaptive)
      set -- \
        -only-testing:VelacantoDownloadsUITests/FoundationDownloadsUITests/testAdaptivePlayerControlsAndQueuePreservePlaybackContext \
        -only-testing:VelacantoDownloadsUITests/FoundationDownloadsUITests/testQueueArtworkZoomAndNativeSwipeActionsPreserveOccurrencePlayback
      ;;
    *) printf '%s\n' 'Unknown smoke selection. Use --list-smokes.' >&2; exit 2 ;;
  esac
fi
project_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$project_root"
: "${VELACANTO_IOS_SIMULATOR_DESTINATION:?Set an existing authorized iOS Simulator destination}"
DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
export DEVELOPER_DIR
if [ -n "${XCODE_XCCONFIG_FILE:-}" ]; then
  printf '%s\n' 'XCODE_XCCONFIG_FILE overrides test build settings and is not supported.' >&2
  exit 2
fi
# Refuse ambiguous, unavailable or different devices before Xcode can launch.
# Extra arguments are restricted to concrete UI test selections so callers
# cannot override the destination, signing, configuration or test action.
python3 - "$VELACANTO_IOS_SIMULATOR_DESTINATION" "$@" <<'PYTHON'
import json
import re
import subprocess
import sys
from pathlib import Path

destination, *arguments = sys.argv[1:]
pattern = r"platform=iOS Simulator,id=[0-9A-Fa-f]{8}-(?:[0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}"
if re.fullmatch(pattern, destination) is None:
    raise SystemExit("Set VELACANTO_IOS_SIMULATOR_DESTINATION to platform=iOS Simulator,id=<existing simulator UUID>.")

# Selection follows the actual UI target source phase, including feature extensions.
try:
    project = json.loads(subprocess.check_output([
        "/usr/bin/plutil", "-convert", "json", "-o", "-",
        "NativeFoundation/VelacantoFoundation.xcodeproj/project.pbxproj",
    ], text=True))["objects"]
    targets = [item for item in project.values()
               if item.get("isa") == "PBXNativeTarget" and item.get("name") == "VelacantoDownloadsUITests"]
    if len(targets) != 1:
        raise ValueError("Expected one UI test target")
    phases = [project[key] for key in targets[0]["buildPhases"]
              if project[key].get("isa") == "PBXSourcesBuildPhase"]
    if len(phases) != 1:
        raise ValueError("Expected one UI test source phase")
    test_root = Path("NativeFoundation/Tests").resolve()
    source_paths = []
    for build in phases[0]["files"]:
        reference = project[project[build]["fileRef"]]
        if reference.get("sourceTree") != "<group>":
            raise ValueError("UI test source must belong to the native source group")
        path = (Path("NativeFoundation") / reference["path"]).resolve(strict=True)
        if path.parent != test_root or path.suffix != ".swift" or path in source_paths:
            raise ValueError("Invalid or duplicate UI test source membership")
        source_paths.append(path)
    methods = set()
    for path in source_paths:
        source = path.read_text(encoding="utf-8")
        declared = re.findall(r"^\s*(?:@objc\s+)?func\s+(test[A-Za-z0-9_]+)\s*\(", source, re.MULTILINE)
        owners = re.findall(r"^\s*(?:final\s+)?(?:class|extension)\s+([A-Za-z0-9_]+)", source, re.MULTILINE)
        if declared and (not owners or any(owner != "FoundationDownloadsUITests" for owner in owners)):
            raise ValueError("Test source changed the established selector class")
        if len(declared) != len(set(declared)) or methods.intersection(declared):
            raise ValueError("Duplicate UI test selector")
        methods.update(declared)
    if not methods:
        raise ValueError("UI test target has no discoverable source selectors")
except (OSError, KeyError, ValueError, subprocess.CalledProcessError) as error:
    raise SystemExit(f"Could not verify UI test source membership: {error}")
prefix = "-only-testing:VelacantoDownloadsUITests/FoundationDownloadsUITests/"
whole_target = "-only-testing:VelacantoDownloadsUITests"
whole_class = "-only-testing:VelacantoDownloadsUITests/FoundationDownloadsUITests"
for argument in arguments:
    if argument in (whole_target, whole_class):
        continue
    if not argument.startswith(prefix) or argument[len(prefix):] not in methods:
        raise SystemExit("Only known VelacantoDownloadsUITests target, class or existing test-method selections are supported.")
try:
    inventory = json.loads(subprocess.check_output(
        ["xcrun", "simctl", "list", "devices", "available", "--json"], text=True))
    devices = inventory["devices"]
    matches = [device for group in devices.values() for device in group
               if device.get("name") == "VelaCanto Duo Test Sim" and device.get("isAvailable") is True]
except (OSError, ValueError, KeyError, TypeError, AttributeError, subprocess.CalledProcessError) as error:
    raise SystemExit(f"Could not verify the iOS Simulator inventory: {error}")
failure = "Select the unique available iPhone Duo named VelaCanto Duo Test Sim; do not create or use another simulator."
if (len(matches) != 1
        or matches[0].get("deviceTypeIdentifier") != "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo"
        or matches[0].get("udid", "").lower() != destination.split("id=", 1)[1].lower()):
    raise SystemExit(failure)
PYTHON
worktree_key=$(printf '%s' "$project_root" | cksum | awk '{print $1}')
derived_data_path=${VELACANTO_DERIVED_DATA_PATH:-"${TMPDIR:-/private/tmp}/VelacantoDerivedData-${worktree_key}"}
"$DEVELOPER_DIR/usr/bin/xcodebuild" \
  -project NativeFoundation/VelacantoFoundation.xcodeproj \
  -scheme VelacantoDownloadsUI -derivedDataPath "$derived_data_path" \
  -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- \
  -destination "$VELACANTO_IOS_SIMULATOR_DESTINATION" \
  -parallel-testing-enabled NO -collect-test-diagnostics never test "$@"
