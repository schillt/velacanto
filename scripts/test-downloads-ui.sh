#!/bin/sh
# Synthetic UI only. Preserve the production simulator app and all real sessions.
set -eu
project_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$project_root"
: "${VELACANTO_IOS_SIMULATOR_DESTINATION:?Set an existing authorized iOS Simulator destination}"
case "$VELACANTO_IOS_SIMULATOR_DESTINATION" in
  'platform=iOS Simulator,'*) ;;
  *) printf '%s\n' 'Only an explicit iOS Simulator destination is supported.' >&2; exit 2 ;;
esac
DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
export DEVELOPER_DIR
worktree_key=$(printf '%s' "$project_root" | cksum | awk '{print $1}')
derived_data_path=${VELACANTO_DERIVED_DATA_PATH:-"${TMPDIR:-/private/tmp}/VelacantoDerivedData-${worktree_key}"}
"$DEVELOPER_DIR/usr/bin/xcodebuild" \
  -project NativeFoundation/VelacantoFoundation.xcodeproj \
  -scheme VelacantoDownloadsUI -derivedDataPath "$derived_data_path" \
  -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- \
  -destination "$VELACANTO_IOS_SIMULATOR_DESTINATION" \
  -parallel-testing-enabled NO -collect-test-diagnostics never test
