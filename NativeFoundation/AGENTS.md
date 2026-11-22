# Maintained native app

Read the root [agent instructions](../AGENTS.md), current
[checkpoint](../docs/0.6.0-alpha-checkpoint.md) and
[handoff](../docs/0.6.0-agent-handoff.md). Current owner instructions supersede
historical 0.3/0.4/0.5 exclusions and old guide approvals.

The project and scheme are VelacantoFoundation. Keep the existing targets,
application/storage identities and iOS/macOS shared model boundaries. The
current checkpoint is 0.6 development, not a completed 0.6 release.

One player owns playback/queue intent, native items and activation. Existing
Handoff owns continuation. Shared catalog/actions remain source/account scoped.
Do not add a second player, broad coordinator, retry/polling layer or hidden
catalog scan. Local catalog records remain read-only metadata; do not silently
turn them into playback, downloads, favorites or playlist mutations.

Home must retain its natural viewport/translucency. Shared measured end spacing
must clear the expanded navigation/player across affected panes. Test actual List
row height and automatic expansion, midscroll underlap, upward scrolling, late
content and related-sheet isolation; geometric unit tests alone are insufficient.
Continue Listening uses the existing media card only for another eligible device,
with metadata/progress, instruction action and presentation-only dismissal.

Keep DEBUG fixtures, probes and detailed diagnostics out of Release. Verify
identity, privacy manifest, Handoff registration, encryption declaration and
absence of diagnostic implementation in each exact signed package. A false
ITSAppUsesNonExemptEncryption value is build metadata, not legal advice.

Use the coordinator's single native lane and existing authorized devices. Run
focused tests, combined regressions and the relevant native/physical checks;
record original failures and current source hashes. Do not infer audible/server,
CarPlay, touch/pointer or accessibility acceptance from compilation. Preserve
privacy protections and fail clearly when unavailable instead of weakening them.
No source publication, distribution or device reset is implied by an assignment.
