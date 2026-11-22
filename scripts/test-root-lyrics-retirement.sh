#!/bin/sh
# Coordinator-only native driver. Use a fresh frozen checkout and fresh evidence directory.
set -eu
project_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$project_root"
: "${VELACANTO_ROOT_LYRICS_RESULT_ROOT:?Set a new absolute evidence directory}"
: "${VELACANTO_PACKAGES_PATH:?Set the existing resolved package cache}"
result_root=$VELACANTO_ROOT_LYRICS_RESULT_ROOT
case "$result_root" in /*) ;; *) exit 2 ;; esac
if [ -e "$result_root" ]; then
  printf '%s\n' 'Refusing to overwrite existing root-lyrics evidence.' >&2
  exit 2
fi
mkdir -p "$result_root"
DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
export DEVELOPER_DIR
source_guard() {
  python3 - "$result_root" "$1" <<'PYHASH'
import hashlib, json, pathlib, sys
root, mode = pathlib.Path(sys.argv[1]), sys.argv[2]
paths = []
for name in ['Sources', 'Tests', 'Shared', 'Widgets', 'Intents', 'Resources']:
    directory = pathlib.Path('NativeFoundation') / name
    if directory.is_dir():
        paths.extend(p for p in directory.rglob('*') if p.is_file())
paths += [pathlib.Path('NativeFoundation/VelacantoFoundation.xcodeproj/project.pbxproj'),
          pathlib.Path('scripts/test-root-lyrics-retirement.sh')]
paths += list(pathlib.Path('NativeFoundation/VelacantoFoundation.xcodeproj/xcshareddata/xcschemes').glob('*.xcscheme'))
snapshot = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(set(paths))}
manifest = root / 'source-before.json'
if mode == 'save':
    if manifest.exists():
        raise SystemExit('Refusing to replace frozen source identity')
    manifest.write_text(json.dumps(snapshot, indent=2) + '\n')
else:
    (root / 'source-after.json').write_text(json.dumps(snapshot, indent=2) + '\n')
    if json.loads(manifest.read_text()) != snapshot:
        raise SystemExit('Frozen source changed during root lyrics verification')
PYHASH
}
# Every native subprocess is bounded; termination is scoped to its own process group.
run_bounded() {
  python3 - "$@" <<'PYBOUND'
import json, os, pathlib, signal, subprocess, sys, time
seconds, log, *command = sys.argv[1:]
start = time.monotonic()
with open(log, 'w') as output:
    process = subprocess.Popen(command, stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
    timed_out = False
    try:
        status = process.wait(timeout=int(seconds))
    except subprocess.TimeoutExpired:
        timed_out = True
        for sig, grace in [(signal.SIGINT, 10), (signal.SIGTERM, 5), (signal.SIGKILL, 5)]:
            try:
                os.killpg(process.pid, sig)
            except ProcessLookupError:
                break
            try:
                process.wait(timeout=grace)
                break
            except subprocess.TimeoutExpired:
                pass
        status = 124
pathlib.Path(log + '.status.json').write_text(json.dumps({
    'command': command, 'returncode': status, 'timed_out': timed_out,
    'elapsed_seconds': time.monotonic() - start,
}, indent=2) + '\n')
raise SystemExit(status if status >= 0 else 128 - status)
PYBOUND
}
export_failure_evidence() {
  if [ -d "$result_root/RootLyricsUI.xcresult" ]; then
    run_bounded 30 "$result_root/export-tests.log" \
      "$DEVELOPER_DIR/usr/bin/xcresulttool" get test-results tests \
      --path "$result_root/RootLyricsUI.xcresult" --format json || :
    if [ -s "$result_root/export-tests.log" ]; then
      cp "$result_root/export-tests.log" "$result_root/tests.json"
    fi
    run_bounded 30 "$result_root/export-summary.log" \
      "$DEVELOPER_DIR/usr/bin/xcresulttool" get test-results summary \
      --path "$result_root/RootLyricsUI.xcresult" --format json || :
    run_bounded 30 "$result_root/export-attachments.log" \
      "$DEVELOPER_DIR/usr/bin/xcresulttool" export attachments \
      --path "$result_root/RootLyricsUI.xcresult" --output-path "$result_root/Attachments" || :
  fi
}
# Preserve structured results and real app captures even when xcodebuild/test verification fails.
source_guard save
trap 'driver_status=$?; trap - 0; export_failure_evidence; source_guard verify || driver_status=1; exit "$driver_status"' 0
run_bounded 900 "$result_root/build.log" "$DEVELOPER_DIR/usr/bin/xcodebuild" \
  -project NativeFoundation/VelacantoFoundation.xcodeproj -scheme VelacantoRootLyricsUI \
  -configuration IsolationTesting -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$result_root/DerivedData" \
  -clonedSourcePackagesDirPath "$VELACANTO_PACKAGES_PATH" -disableAutomaticPackageResolution \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- \
  CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build-for-testing
app="$result_root/DerivedData/Build/Products/IsolationTesting/VelacantoIsolation.app"
python3 - "$app" "$result_root" <<'PY'
import pathlib, plistlib, sys
app = pathlib.Path(sys.argv[1])
root = pathlib.Path(sys.argv[2]).resolve()
if app.is_symlink() or app.resolve().parent != root / 'DerivedData/Build/Products/IsolationTesting':
    raise SystemExit('Refusing to re-sign outside fresh isolated products')
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
if (info.get('CFBundleIdentifier') != 'com.chameleonenterprise.velacanto.isolationtesting'
        or info.get('CFBundleExecutable') != 'VelacantoIsolation'
        or info.get('CFBundleSupportedPlatforms') != ['MacOSX']
        or info.get('DTPlatformName') != 'macosx'):
    raise SystemExit('Unexpected isolated Mac application identity')
if any(app.rglob('*.appex')):
    raise SystemExit('Unexpected isolation app extension')
for key in ['NSUserActivityTypes', 'UIBackgroundModes', 'UIApplicationSceneManifest', 'INIntentsSupported']:
    if key in info:
        raise SystemExit('Unexpected native entry point: ' + key)
PY
/usr/bin/codesign --force --sign - \
  --entitlements NativeFoundation/Resources/IsolationTestHost-macOS.entitlements \
  "$app" > "$result_root/host-normalize-signature.log" 2>&1
/usr/bin/codesign --verify --deep --strict "$app"
/usr/bin/codesign --display --xml --entitlements - "$app" \
  > "$result_root/host-entitlements.plist" 2> "$result_root/host-signature.log"
python3 - "$result_root" "$app" <<'PY'
import pathlib, plistlib, sys
root = pathlib.Path(sys.argv[1])
app = pathlib.Path(sys.argv[2]).resolve()
e = plistlib.loads((root / 'host-entitlements.plist').read_bytes())
expected = plistlib.loads(pathlib.Path('NativeFoundation/Resources/IsolationTestHost-macOS.entitlements').read_bytes())
if e != expected or 'warning:' in (root / 'host-signature.log').read_text().lower():
    raise SystemExit('Isolated host entitlements/signature differ from reviewed exact policy')
products = root / 'DerivedData/Build/Products'
runs = list(products.glob('VelacantoRootLyricsUI_*.xctestrun'))
if len(runs) != 1:
    raise SystemExit('Expected exactly one fresh UI xctestrun')
d = plistlib.loads(runs[0].read_bytes())
if 'TestConfigurations' in d:
    targets = [t for c in d['TestConfigurations'] for t in c.get('TestTargets', [])]
else:
    targets = [v for k, v in d.items() if k != '__xctestrun_metadata__']
if len(targets) != 1:
    raise SystemExit('Unexpected UI test target set')
t = targets[0]
if t.get('IsUITestBundle') is not True:
    raise SystemExit('Expected an external UI test runner')
relative_app = t.get('UITargetAppPath', '')
if not relative_app.startswith('__TESTROOT__/'):
    raise SystemExit('UI target app is not relative to fresh products')
if (products / relative_app.removeprefix('__TESTROOT__/')).resolve() != app:
    raise SystemExit('UI runner does not target the verified isolated app')
if 'VelacantoRootLyricsUITests' not in t.get('TestBundlePath', ''):
    raise SystemExit('Unexpected UI test bundle')
if t.get('SkipTestIdentifiers'):
    raise SystemExit('Unexpected skipped UI tests')
# Default XCUIApplication() must target this exact verified app. Preserve raw products;
# put the qualified plan outside them and resolve its original test-root references.
t.setdefault('TestingEnvironmentVariables', {})['FOUNDATION_ROOT_LYRICS_EXPECTED_APP_PATH'] = str(app)
def qualify(value):
    if isinstance(value, str):
        return value.replace('__TESTROOT__', str(products.resolve()))
    if isinstance(value, dict):
        return {key: qualify(item) for key, item in value.items()}
    if isinstance(value, list):
        return [qualify(item) for item in value]
    return value
qualified = root / 'Qualified-RootLyrics.xctestrun'
qualified.write_bytes(plistlib.dumps(qualify(d)))
(root / 'xctestrun-path').write_text(str(qualified))
(root / 'raw-xctestrun-path').write_text(str(runs[0]))
PY
run_bounded 180 "$result_root/test.log" "$DEVELOPER_DIR/usr/bin/xcodebuild" \
  -xctestrun "$(cat "$result_root/xctestrun-path")" \
  -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO \
  -only-testing:VelacantoRootLyricsUITests/FoundationRootLyricsRetirementUITests/testActualRootSignOutRetiresHeldLyricsWithoutChangingSelectedOccurrence \
  -resultBundlePath "$result_root/RootLyricsUI.xcresult" test-without-building
export_failure_evidence
source_guard verify
# Successful validation has already exported its evidence; suppress duplicate exit exports.
trap - 0
python3 - "$result_root/tests.json" "$result_root/export-summary.log" <<'PY'
import json, sys
root = json.load(open(sys.argv[1]))
expected = 'FoundationRootLyricsRetirementUITests/testActualRootSignOutRetiresHeldLyricsWithoutChangingSelectedOccurrence'
found = []
def walk(node):
    if isinstance(node, dict):
        if node.get('nodeType') == 'Test Case' and node.get('nodeIdentifier', '').removesuffix('()') == expected:
            found.append(node)
        for value in node.values():
            walk(value)
    elif isinstance(node, list):
        for value in node:
            walk(value)
walk(root)
if len(found) != 1 or found[0].get('result') != 'Passed':
    raise SystemExit('Required external root UI test did not execute and pass exactly once')
summary = json.load(open(sys.argv[2]))
if (summary.get('totalTestCount') != 1 or summary.get('passedTests') != 1
        or summary.get('failedTests') != 0 or summary.get('skippedTests') != 0
        or summary.get('expectedFailures') != 0 or summary.get('runtimeWarnings')):
    raise SystemExit('External root UI gate has unexpected discovery, failures, skips or runtime warnings')
print('Required genuine root lyrics retirement UI gate executed and passed.')
PY
