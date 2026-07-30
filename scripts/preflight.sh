#!/bin/sh

set -u

project_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$project_root"

skip_xcode=false
if [ "${1:-}" = "--skip-xcode" ]; then
  skip_xcode=true
elif [ "$#" -gt 0 ]; then
  printf 'Usage: %s [--skip-xcode]\n' "$0" >&2
  exit 2
fi

if [ "$skip_xcode" = false ] &&
  [ -z "${DEVELOPER_DIR:-}" ] &&
  [ -d /Applications/Xcode-beta.app/Contents/Developer ]; then
  DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
  export DEVELOPER_DIR
fi

failures=0
warnings=0

pass() {
  printf 'PASS  %s\n' "$1"
}

warn() {
  warnings=$((warnings + 1))
  printf 'WARN  %s\n' "$1"
}

fail() {
  failures=$((failures + 1))
  printf 'FAIL  %s\n' "$1"
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

if [ "$(uname -s)" = "Darwin" ]; then
  pass "Running on macOS $(sw_vers -productVersion)"
else
  fail "Build host is not macOS"
fi

if [ "$(uname -m)" = "arm64" ]; then
  pass "Build host uses Apple silicon"
else
  warn "Build host architecture is $(uname -m), not arm64"
fi

available_kb=$(df -Pk . | awk 'NR == 2 { print $4 }')
if [ -n "$available_kb" ] && [ "$available_kb" -ge 41943040 ]; then
  available_gb=$((available_kb / 1024 / 1024))
  pass "At least 40 GiB is free (${available_gb} GiB available)"
elif [ -n "$available_kb" ] && [ "$available_kb" -ge 10485760 ]; then
  available_gb=$((available_kb / 1024 / 1024))
  warn "Less than 40 GiB is free (${available_gb} GiB available)"
else
  fail "Less than 10 GiB is free for Xcode, simulators, and build products"
fi

for required_command in git curl security plutil rg; do
  if command_exists "$required_command"; then
    pass "$required_command is installed"
  else
    fail "$required_command is missing"
  fi
done

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  pass "Directory is a Git worktree"
else
  fail "Directory is not a Git worktree"
fi

if [ -n "$(git config --get user.name 2>/dev/null || true)" ]; then
  pass "Git user.name is configured"
else
  warn "Git user.name is not configured"
fi

if [ -n "$(git config --get user.email 2>/dev/null || true)" ]; then
  pass "Git user.email is configured"
else
  warn "Git user.email is not configured"
fi

if git remote get-url origin >/dev/null 2>&1; then
  pass "Git remote 'origin' is configured"
else
  warn "Git remote 'origin' is not configured"
fi

if git rev-parse --verify HEAD >/dev/null 2>&1; then
  pass "Repository has an initial commit"
else
  warn "Repository has no initial commit"
fi

if [ -f README.md ] && [ -f docs/0.1-plan.md ]; then
  pass "Product brief and 0.1.0 plan exist"
else
  fail "Product brief or 0.1.0 plan is missing"
fi

if rg -q 'com\.chameleonenterprise\.velacanto' README.md docs/0.1-plan.md; then
  pass "Bundle identifier is documented"
else
  fail "Bundle identifier is not documented consistently"
fi

if find . -maxdepth 2 -name '*.xcodeproj' -print -quit | grep -q .; then
  pass "An Xcode project exists"
else
  warn "No Xcode project exists yet"
fi

if [ -f Velacanto/Resources/PrivacyInfo.xcprivacy ] &&
  plutil -lint Velacanto/Resources/PrivacyInfo.xcprivacy >/dev/null; then
  pass "Privacy manifest exists and is a valid property list"
else
  fail "Privacy manifest is missing or invalid"
fi

if [ -f Velacanto/Resources/Info.plist ] &&
  plutil -extract NSAppTransportSecurity.NSAllowsLocalNetworking raw \
    Velacanto/Resources/Info.plist 2>/dev/null | grep -q '^true$'; then
  pass "Local-network ATS exception is configured"
else
  fail "Local-network ATS exception is missing"
fi

if plutil -extract NSAppTransportSecurity.NSAllowsArbitraryLoads raw \
  Velacanto/Resources/Info.plist >/dev/null 2>&1; then
  fail "Global arbitrary network loads are enabled"
else
  pass "Global arbitrary network loads remain disabled"
fi

if plutil -extract UIBackgroundModes.0 raw \
  Velacanto/Resources/Info.plist 2>/dev/null | grep -q '^audio$'; then
  pass "iOS background audio mode is configured"
else
  fail "iOS background audio mode is missing"
fi

identity_count=$(security find-identity -v -p codesigning 2>/dev/null | awk '/valid identities found/ { print $1 }')
if [ -n "$identity_count" ] && [ "$identity_count" -gt 0 ]; then
  pass "At least one valid code-signing identity is installed"
else
  warn "No valid code-signing identity is currently installed"
fi

tracked_secrets=$(git ls-files '*.mobileprovision' '.env' '.env.*' 'Secrets.xcconfig' 2>/dev/null || true)
if [ -z "$tracked_secrets" ]; then
  pass "No common local credential files are tracked"
else
  fail "Potential credential files are tracked: $tracked_secrets"
fi

if [ "$skip_xcode" = true ]; then
  warn "Xcode checks were skipped by request"
else
  if command_exists xcodebuild; then
    developer_dir=$(xcode-select -p 2>/dev/null || true)
    if [ -n "$developer_dir" ]; then
      pass "Active developer directory is $developer_dir"
    else
      fail "No active Xcode developer directory is selected"
    fi

    if xcodebuild -version >/dev/null 2>&1; then
      xcode_version=$(xcodebuild -version | tr '\n' ' ')
      pass "xcodebuild is ready ($xcode_version)"
    else
      fail "xcodebuild is installed but not ready"
    fi
  else
    fail "xcodebuild is missing"
  fi
fi

printf '\nSummary: %s failure(s), %s warning(s)\n' "$failures" "$warnings"

if [ "$failures" -gt 0 ]; then
  exit 1
fi
