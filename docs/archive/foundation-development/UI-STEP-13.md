# Page-attribution diagnostic candidate

Based ondd5ebb7b56d3c524ff35ce9f75f85c4c0626b574. Owner reports View Artist/Album
preceded a temporary device connectivity drop, recovering without reset/restart.
Preserved trace cannot identify the initiating page. No native failure or final
API failure in latest launch; three catalog operations ended canceled in the
longest timing bucket, then later reads succeeded. Lyrics are not present.

DEBUG only: existing finite1MiB journal adds TaskLocal ephemeral page owners,
origin (Home/New/Library/Search/NowPlaying), page category, finite API purpose,
page task/visibility and player/queue/destination presentation events, cancellation
requested separately from actual load await returned, and browse retained/load/
publication committed/discarded events. API fields captured at invocation so
cancellation from another execution context retains the same owner. No personal
items, titles, query contents, URLs, credentials, raw error data or exact network
metrics. Native on-wire/task metrics not available; these are application await
boundaries, not proof of socket drain. Existing success is HTTP-stage; model logs
now distinguish decode completion and publication.

No behavior or task identity changes, new requests, probes, polling, retry, delay,
cache/admission layers, tests or dependencies. View load helpers are DEBUG-only;
Release-preprocessed changed sources match candidate13 ignoring whitespace.
Root verifies compile, existing checks, Release marker exclusion and signing.
Internal logging adds overhead and may affect timing. Playback pipeline unchanged.

Owner repeats View Artist/Back and View Album/Back with playback and skips; report
last action when drop occurs and leave state intact. Purpose+origin distinguishes
player.artistAlbums/player.albumTracks from Home shelves or Library tasks below.
No page blamed until matching trace supports attribution; no causal guarantee or
reliability percentage. Candidate13 evidence preserved separately.
