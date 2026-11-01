#!/bin/sh
# Archives only. Export/validation/upload remain explicit distribution steps.
set -eu
project_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$project_root"
case ${1:-} in
  macos) destination='generic/platform=macOS' ;;
  ios) destination='generic/platform=iOS' ;;
  *) printf 'Usage: %s [macos|ios] <archive-path>\n' "$0" >&2; exit 2 ;;
esac
: "${2:?Provide a distinct archive path for this platform}"
worktree_key=$(printf '%s' "$project_root" | cksum | awk '{print $1}')
DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
export DEVELOPER_DIR
set -- -project NativeFoundation/VelacantoFoundation.xcodeproj -scheme VelacantoFoundation \
  -configuration Release -destination "$destination" -archivePath "$2" \
  -derivedDataPath "${TMPDIR:-/private/tmp}/VelacantoDerivedData-${worktree_key}" \
  -disableAutomaticPackageResolution
if [ -n "${VELACANTO_PACKAGES_PATH:-}" ]; then
  set -- "$@" -clonedSourcePackagesDirPath "$VELACANTO_PACKAGES_PATH"
fi
if [ -n "${VELACANTO_BUILD_NUMBER:-}" ]; then
  case "$VELACANTO_BUILD_NUMBER" in *[!0-9]*|'') printf 'Build number must be numeric.\n' >&2; exit 2 ;; esac
  set -- "$@" "CURRENT_PROJECT_VERSION=$VELACANTO_BUILD_NUMBER"
fi
# Explicit distribution-only opt-in; ordinary/development archive defaults stay intact.
case ${VELACANTO_DISTRIBUTION_PIN_SYNC:-} in
  '') ;;
  production)
    set -- "$@" \
      "VELACANTO_APP_BUNDLE_IDENTIFIER=com.chameleonenterprise.velacanto" \
      "VELACANTO_APP_DISPLAY_NAME=VelaCanto" \
      "VELACANTO_PIN_SYNC_CONTAINER_IDENTIFIER=iCloud.com.chameleonenterprise.velacanto" \
      "VELACANTO_IOS_ENTITLEMENTS_FILE=Resources/Velacanto-iOS-PinSyncProduction.entitlements" \
      "VELACANTO_MACOS_ENTITLEMENTS_FILE=Resources/Velacanto-macOS-PinSyncProduction.entitlements"
    ;;
  *) printf 'Unsupported distribution pin-sync configuration.\n' >&2; exit 2 ;;
esac
"$DEVELOPER_DIR/usr/bin/xcodebuild" "$@" archive
