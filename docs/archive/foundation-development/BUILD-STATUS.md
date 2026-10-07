# Foundation verification history

The record below describes the initial minimal candidate only. It is retained
as historical evidence. Later signed candidates carry their own TESTING.md and
ARTIFACT.txt; see UI-STEP files for subsequent scoped changes. Current Library
integration verification will be recorded separately, not inferred from this run.

## Initial minimal candidate

Signed source candidate: 7b997e4566222a8098f56af397f01f3cbf4170f4.
Full test suite candidate: 790071b112b499e654d9b198cf0d0a021b350aad.
The only later executable change encloses the existing synthetic launch flag
in DEBUG; Debug behavior is unchanged. Remaining changes are documentation.
Preserved legacy base: 702b7e87cbe11436ec2f83c1a7a5b72d8c57fe5c.
All executable changes are confined to NativeFoundation; the legacy project
and player/transport sources are not linked into this app.

## Completed

- Repository lint and git diff --check passed.
- macOS arm64 Debug build-for-testing passed with target warnings as errors.
- All 23 synthetic tests passed: 8 API, 9 player, 6 presentation.
- Real native playback of a generated silent local WAV reached playing and
  Stop released its item. This does not test remote streaming or audio-session
  configuration, which the host test deliberately bypasses.
- iOS Debug compilation passed before the final test-only addition.
- Independent read-only source/config review found no remaining blocker at
  the exact source candidate above. Notes were then corrected without changing
  executable code.

- Final iOS Release compilation passed. Binary strings exclude the journal,
  detailed event markers, synthetic launch flag, test class and legacy player/
  transport markers. Project source membership is Foundation-only.
- Final iOS Debug development signing passed after Xcode account setup.
- Independent source review extended through the final signed source candidate.

## Pending

- Owner device installation and acceptance; no physical success is claimed.

## Evidence

Coordinator-local logs: archive-local/velacanto-foundation-build6.log,
archive-local/velacanto-foundation-tests2.log and tests2.xcresult,
archive-local/velacanto-foundation-ios-debug.log,
archive-local/velacanto-foundation-lint.log.

An earlier test run crashed in a query-inspection fixture that incorrectly
assumed generated query keys were unique. The fixture was fixed and the entire
suite rerun successfully; the earlier run is not counted as passing.

Final build logs: archive-local/velacanto-foundation-ios-release2.log and
archive-local/velacanto-foundation-ios-signed3.log. Final lint passed.
