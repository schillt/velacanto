#!/bin/sh
set -eu
project_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$project_root"
if [ -z "${DEVELOPER_DIR:-}" ]; then
  if [ -d /Applications/Xcode-beta.app/Contents/Developer ]; then
    DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
  else
    DEVELOPER_DIR=$(xcode-select -p)
  fi
fi
export DEVELOPER_DIR
worktree_key=$(printf '%s' "$project_root" | cksum | awk '{print $1}')
derived_data_path=${VELACANTO_DERIVED_DATA_PATH:-"${TMPDIR:-/private/tmp}/VelacantoDerivedData-${worktree_key}"}
ios_destination=${VELACANTO_IOS_SIMULATOR_DESTINATION:-'platform=iOS Simulator,name=iPhone Air,OS=27.0'}
run_xcode() {
  set -- -project NativeFoundation/VelacantoFoundation.xcodeproj -scheme VelacantoFoundation \
    -derivedDataPath "$derived_data_path" -disableAutomaticPackageResolution \
    CODE_SIGNING_ALLOWED=NO "$@"
  if [ -n "${VELACANTO_PACKAGES_PATH:-}" ]; then
    set -- -clonedSourcePackagesDirPath "$VELACANTO_PACKAGES_PATH" "$@"
  fi
  "$DEVELOPER_DIR/usr/bin/xcodebuild" "$@"
}
lint() { python3 scripts/lint.py; }

macos() { run_xcode -configuration Debug -destination 'generic/platform=macOS' build; }
test_macos() { run_xcode -configuration Debug -destination 'platform=macOS' -parallel-testing-enabled NO test; }
ios() { run_xcode -configuration Debug -destination 'generic/platform=iOS Simulator' build; }
test_ios() { run_xcode -configuration Debug -destination "$ios_destination" -parallel-testing-enabled NO test; }
release() {
  run_xcode -configuration Release -destination 'generic/platform=macOS' build
  run_xcode -configuration Release -destination 'generic/platform=iOS' build
  python3 scripts/verify-release.py "$derived_data_path/Build/Products/Release-iphoneos/Velacanto.app"
  python3 scripts/verify-release.py "$derived_data_path/Build/Products/Release/Velacanto.app"
}
case ${1:-all} in
  lint) lint ;;
  macos) macos ;;
  test) test_macos ;;
  ios-simulator) ios ;;
  ios-simulator-test) test_ios ;;
  release) release ;;
  all) ./scripts/preflight.sh --skip-xcode; lint; macos; test_macos; ios ;;
  pr|pr-os27-preview|pr-hosted)
    ./scripts/preflight.sh --skip-xcode
    lint
    test_macos
    test_ios
    release
    ;;
  *) printf 'Usage: %s [all|lint|macos|test|ios-simulator|ios-simulator-test|release|pr]\n' "$0" >&2; exit 2 ;;
esac
