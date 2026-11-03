# Maintained native app

Read the root [agent instructions](../AGENTS.md), current
[0.7.0 handoff](../docs/0.7.0-agent-handoff.md) and
[playback protection](../docs/playback-protection.md). Older checkpoint exclusions
and worker assignments do not override current owner direction.

The project/scheme are VelacantoFoundation. Keep existing targets, application,
Keychain/storage identities and iOS/macOS shared model boundaries. The accepted
0.6 baseline remains intact; 0.7 preparation has not changed runtime/version/build.

One player owns playback/queue intent, native items and activation. Existing
Handoff owns continuation. Shared catalog/actions remain source/account scoped.
Do not add a second player, broad coordinator, retry/polling layer or hidden scan.
Local catalog groundwork stays distinct from working offline Jellyfin downloads.

Retain natural viewports/translucency and end-of-content player clearance. Test
changed keyboard/focus, sheet and pointer/touch behavior in its actual platform.
Preserve the single remote Continue Listening card, unified song/queue action,
presentation-only dismissal and existing source-stop guards.

Keep DEBUG fixtures/probes out of Release. Verify identity, privacy manifest,
Handoff registration, encryption declaration and diagnostic exclusion on the exact
applicable package. A false ITSAppUsesNonExemptEncryption value is metadata.

Follow the root project coordination and issue ownership instructions: a named
subagent owns each native issue implementation, while the main agent coordinates,
keeps the GitHub Project and issue comments current, and reports to the owner.
Use one coordinator-controlled serialized native lane and existing authorized
devices/simulators. Run proportionate affected tests/builds; retain failures and
exact source evidence.
Do not infer audibility, server behavior, accessibility, CarPlay or Apple delivery
from compilation. Preserve data/privacy protections. Production pin sync is owner
accepted; normal iCloud lag alone is not an open app defect or new retry assignment.
No publication, distribution or device reset is implied by a source assignment.

## Native implementation review

Apply the root engineering standards to the changed native path; do not turn this
checklist into a blanket rewrite or a requirement to repeat unaffected acceptance.

- Keep view-owned state private and distinguish owned state from injected models.
  Give a view the state it reads; investigate broad observation and expensive
  derived work when measuring updates rather than mandating an observation rewrite.
- Use stable item identity for unique catalog entries and stable occurrence identity
  for repeated queue/playlist entries. Position is selection/order information, not
  the identity of a mutable row. Verify deletion, reorder and replacement behavior
  where a change affects retained state, focus or animations.
- Keep storage and projection work from delaying interaction or playback. Inspect
  main-actor execution and measure realistic workloads; preserve persistence and
  account-lifetime ordering when moving work to a narrow storage/worker boundary.
- Prefer native controls and supported public APIs. Preserve accessibility labels,
  focus and keyboard/touch behavior, Dynamic Type and reduced-motion/transparency
  settings in changed UI. Errors and loading/empty/offline states must tell the
  user what happened and the available next action.
- Keep synthetic fixtures isolated from real credentials, data and system services.
  Check critical regression tests' target/scheme membership and applicable Mac/iOS
  execution. Verify DEBUG-only fixtures remain excluded from the Release artifact.
