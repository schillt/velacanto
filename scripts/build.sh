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
derived_data_path=${VELACANTO_DERIVED_DATA_PATH:-"${temporary_build_root%/}/VelacantoDerivedData"}

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
    build
}

test_macos() {
  "$xcodebuild_path" \
    -project "$project_path" \
    -scheme Velacanto \
    -configuration Debug \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$derived_data_path" \
    CODE_SIGNING_ALLOWED=NO \
    test
}

build_ios_simulator() {
  "$xcodebuild_path" \
    -project "$project_path" \
    -scheme Velacanto \
    -configuration Debug \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$derived_data_path" \
    CODE_SIGNING_ALLOWED=NO \
    build
}

lint_swift() {
  xcrun swift-format lint \
    --configuration "$project_root/.swift-format" \
    --strict \
    --recursive \
    "$project_root/Velacanto" \
    "$project_root/VelacantoTests"
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
  lint)
    lint_swift
    ;;
  *)
    printf 'Usage: %s [all|macos|test|ios-simulator|lint]\n' "$0" >&2
    exit 2
    ;;
esac
