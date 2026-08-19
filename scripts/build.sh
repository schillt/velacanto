#!/bin/sh

set -eu

project_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
build_mode=${1:-all}
cd "$project_root"

if [ -z "${DEVELOPER_DIR:-}" ]; then
  if [ -d /Applications/Xcode-beta.app/Contents/Developer ]; then
    DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
  else
    DEVELOPER_DIR=$(xcode-select -p)
  fi
fi
export DEVELOPER_DIR

xcodebuild_path="$DEVELOPER_DIR/usr/bin/xcodebuild"
project_path="$project_root/Velacanto.xcodeproj"
temporary_build_root=${TMPDIR:-/private/tmp}
worktree_build_key=$(printf '%s' "$project_root" | cksum | awk '{print $1}')
derived_data_path=${VELACANTO_DERIVED_DATA_PATH:-"${temporary_build_root%/}/VelacantoDerivedData-${worktree_build_key}"}
ios_simulator_destination=${VELACANTO_IOS_SIMULATOR_DESTINATION:-'platform=iOS Simulator,name=iPhone Air,OS=27.0'}

if [ ! -x "$xcodebuild_path" ]; then
  printf 'Xcode is not ready at %s\n' "$DEVELOPER_DIR" >&2
  exit 1
fi

build_macos() {
  "$xcodebuild_path" \
    -project "$project_path" \
    -scheme Velacanto \
    -configuration Debug \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$derived_data_path" \
    CODE_SIGNING_ALLOWED=NO \
    SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
    build
}

test_macos() {
  "$xcodebuild_path" \
    -project "$project_path" \
    -scheme Velacanto \
    -configuration Debug \
    -destination 'platform=macOS' \
    -only-testing:VelacantoTests \
    -derivedDataPath "$derived_data_path" \
    CODE_SIGNING_ALLOWED=NO \
    SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
    test
}

test_macos_when_host_supported() {
  host_macos_major=$(sw_vers -productVersion | awk -F. '{print $1}')

  if [ "$host_macos_major" -lt 27 ]; then
    printf 'Skipping macOS tests: runner host macOS %s cannot launch the macOS 27 test bundle; iOS 27 simulator tests remain required.\n' "$host_macos_major"
    return
  fi

  test_macos
}

build_ios_simulator() {
  "$xcodebuild_path" \
    -project "$project_path" \
    -scheme Velacanto \
    -configuration Debug \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$derived_data_path" \
    CODE_SIGNING_ALLOWED=NO \
    SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
    build
}

test_ios_simulator() {
  "$xcodebuild_path" \
    -project "$project_path" \
    -scheme Velacanto \
    -configuration Debug \
    -destination "$ios_simulator_destination" \
    -derivedDataPath "$derived_data_path" \
    CODE_SIGNING_ALLOWED=NO \
    SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
    test
}

build_macos_release() {
  "$xcodebuild_path" \
    -project "$project_path" \
    -scheme Velacanto \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$derived_data_path" \
    CODE_SIGNING_ALLOWED=NO \
    SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
    build
}

analyze_macos() {
  "$xcodebuild_path" \
    -project "$project_path" \
    -scheme Velacanto \
    -configuration Debug \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$derived_data_path" \
    CODE_SIGNING_ALLOWED=NO \
    SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
    analyze
}

lint_swift() {
  xcrun swift-format lint \
    --configuration "$project_root/.swift-format" \
    --strict \
    --recursive \
    "$project_root/Velacanto" \
    "$project_root/VelacantoTests" \
    "$project_root/VelacantoUITests"
}

case "$build_mode" in
  all)
    "$project_root/scripts/preflight.sh"
    lint_swift
    build_macos
    test_macos
    build_ios_simulator
    ;;
  macos)
    build_macos
    ;;
  test)
    test_macos
    ;;
  ios-simulator)
    build_ios_simulator
    ;;
  ios-simulator-test)
    test_ios_simulator
    ;;
  lint)
    lint_swift
    ;;
  pr)
    "$project_root/scripts/preflight.sh"
    lint_swift
    build_macos
    test_macos
    build_ios_simulator
    build_macos_release
    analyze_macos
    ;;
  pr-hosted)
    "$project_root/scripts/preflight.sh"
    lint_swift
    build_macos
    build_macos_release
    analyze_macos
    ;;
  pr-os27-preview)
    "$project_root/scripts/preflight.sh"
    lint_swift
    build_macos
    test_macos_when_host_supported
    build_ios_simulator
    test_ios_simulator
    build_macos_release
    analyze_macos
    ;;
  *)
    printf 'Usage: %s [all|macos|test|ios-simulator|ios-simulator-test|lint|pr|pr-hosted|pr-os27-preview]\n' "$0" >&2
    exit 2
    ;;
esac
