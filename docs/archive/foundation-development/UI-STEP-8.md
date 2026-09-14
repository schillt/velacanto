# Home and queue actions

Base: 9c46aae8ec82003a6eae236eaa77a551155765eb (candidate08).
Home API worker75a91886c32608222a6a65216e226578018f8726 and UI worker
37c08472d9be342fe071a9169e3defeed32c0eb8 integrated serially. Root adds shared
menus and small queue mutations. The source lineage is preserved locally;
this is not an alpha promotion or physical acceptance claim.

Home uses retained existing browse models. Cold history/favorite/recent albums:
one24-item page each when visible. Cold genre index: one50-item page; up to five
visible genre shelves each load one50-item page. Loaded/empty retained reentry:
zero metadata reads. Genre child models follow native view lifetime. Artwork
uses existing view-owned requests and placeholders. See All uses explicit paging.
Server-recorded history is read-only; no playback reporting was added.

Song queue additions: zero requests. Explicit album/playlist queue additions:
sequential100-item pages following server cursors to completion, one task owned
by existing source actions, with visible Cancel. Errors/cancellation do not
partially alter the queue. Active native playback remains untouched. Repeated
server tracks retain separate occurrence identities. Now Playing queue actions
move existing occurrences, never duplicate them; the current occurrence stays.
With no selection, the first newly added song uses the existing select command.

No new dependencies, tests, fault injection, retry, session or player managers.
Original Home was observed in the prior simulator design review. Coordinate
control failed during this step, so no new exact-candidate visual acceptance is
claimed. Owner testing should cover Home cold/warm navigation, songs/albums/
playlists Play Next/Last, duplicate entries and cancellation during collection
loading, with audio active. Actual compilation/signing/install gates follow in
the candidate artifact record.
