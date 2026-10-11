# Queue storage — issue #12

The rebuilt player saves one versioned playback-session snapshot in an opaque
account-digest directory under Application Support. The snapshot contains queue
occurrence UUIDs, track IDs, titles/subtitles, durations, artwork tags, related
catalog references, favorite/play-count snapshots, selected occurrence and
shuffle/repeat modes. It contains no credentials, server origins, media URLs or
playback position. No snapshot contents are logged.

Writes replace the file atomically. The root, account directory and file are
excluded from backups and restricted to the app user; iOS files use complete
protection until first user authentication so background playback can access
metadata after device unlock. This is local account metadata, not encrypted
application-level storage or iCloud synchronization.

Relaunch retains only the signed-in account's snapshot. With no usable saved
sign-in, all snapshots are removed. Successful local sign-out and new sign-in
clear all account snapshots; failed credential removal retains the active
account's snapshot. Storage, decoding and cleanup failures are reported instead
of being represented as successful persistence. Cleanup applies to current
app storage and does not erase older backups or independently exported copies.

Restoration is paused and makes no playback-resolution request. Explicit Play
starts the selected occurrence from the beginning. Duplicate tracks retain
separate occurrence identities. Shuffle changes only upcoming order; disabling
shuffle keeps the realized order, including explicit user edits. History and the
current occurrence cannot be removed or reordered. Explicit queue edits cancel pending
collection expansion so late Play or Enqueue results cannot overwrite those edits.
