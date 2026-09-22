# 0013 — Rebuilt 0.3 release and original app identity

Status: Accepted by owner, 2026-09-14.

The owner chooses build 106 as the 0.3 checkpoint and authorizes a GitHub alpha
prerelease and internal TestFlight. Import its final native app snapshot in one
focused normal commit on current alpha; do not merge 240 divergent local commits
or force-rewrite history. Remove the old application source/tests/project from
the active tree. Preserve release tags, archives and historical decisions.

The new app is Velacanto, bundle com.chameleonenterprise.velacanto. Existing
users may sign in again. Preserve the rebuilt Keychain format with no legacy
credential migration or cross-app sharing. Internal module/project names may
remain Foundation to avoid runtime refactoring. Version 0.3.0 (108) is a newly
signed package, not byte-identical 106. Build 107 is explicitly excluded.

Runtime sources/tests/resources are preserved from 106 except approved packaging
metadata. The Mac distribution package adds only App Sandbox and outgoing-network
entitlements, scoped to macOS. iPad declares all four orientations for native
multitasking. Both platforms are approved for internal TestFlight. These packaging
changes require new signed-platform validation. Keep current declared iOS 18/macOS 14 minimums and availability checks;
Xcode 27 is the current required development gate, not proof of older-device
acceptance. This supersedes older planned mandatory OS 27-only deployment for
this package. SDK/dependency resolution is pinned. Current functionality is
specified by 0.3 release notes; incomplete old 0.3 milestone promises remain
separately deferred/open and do not authorize restoring legacy mechanisms.

Root CI/preflight/lint builds the rebuilt product. Existing 106 formatting debt
is recorded without changing source, new debt fails, and strict compilation/tests
are required. Exact new-package signing, Release exclusion, hosted and physical
results must be recorded honestly. TestFlight processing is a separate state
from upload; no external/public release is authorized.

## 0.3.5 development platform update

Issue #161 (2026-09-22) raises current development minimums to iOS/iPadOS 27 and
macOS 27 for app and tests in Debug and Release. The project-level settings are
inherited by both targets; there is no tracked project generator. This supersedes
the older-minimum requirement above for future development only, without rewriting
the published 0.3.0 release or its evidence. Swift language mode, version 0.3.0
(108) and signing configuration are unchanged. The scoped compatibility exception
uses AVPlayerItem.didPlayToEndTimeNotification and failedToPlayToEndTimeNotification
in place of deprecated aliases; observer behavior and lifetime remain unchanged.

Use regular Xcode 27 or newer, defaulting to `/Applications/Xcode.app`, with an
explicit `DEVELOPER_DIR` honored. Preflight requires iPhoneOS, iPhoneSimulator and
macOS SDKs 27 or newer. The OS 27 Quality Gate remains required; retire the Xcode
26 advisory rather than extending support below the deployment minimum. CI must
select an existing available simulator or fail clearly. Local simulator selection
requires an explicit authorized destination; never create or overwrite references.

Hosted candidate validation, signed artifacts, physical acceptance and distribution
remain separate gates. Issue #149 owns Xcode Cloud/signing/export/Apple processing;
this settings change does not establish distribution compatibility or availability.
