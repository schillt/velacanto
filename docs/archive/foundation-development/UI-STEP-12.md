# Now Playing album and artist destinations

Baseed27fc8b6e595a7b24579b881485a4470ed9c2c4 (candidate12). Owner reports the
Favorite/AirPlay stage did not reproduce the failure and requests navigation next.
This observation does not establish the initial failure cause.

Native overflow adds View Album and View Artist. Existing album reference reused;
optional album-artist reference maps the first valid AlbumArtists entry from
already returned SDK DTOs, without API parameter changes or fallback requests.
Missing references disable their menu actions. Tapping stores the selected target;
subsequent skips do not retarget an open destination. Existing native navigation
and FoundationItemDestination supply catalog pages. Now Playing artwork retains
its current visibility/cancellation and completed-key behavior.

Request budget: opening menu zero; routing reference zero; cold destination one
existing100-song album page or50-album artist page. Further pages/refresh remain
explicit. Existing retained loaded/empty model reentry zero; popping/destroying a
destination and selecting it anew may create a new model and first-page read.
Tagged destination artwork uses existing per-view bounded reads. Current albumart
and playback behavior unchanged. Source queue-loading feedback reused on the
sheet so collection additions inside artist navigation remain cancellable.

No player/transport/credentials/actions/journal changes. No tests, dependencies,
retry, new loading model or diagnostics added. Existing tests and platform gates
recorded in artifact13. Owner tests both destinations/Back during playback, then
rapid skips and queue navigation. Lyrics and volume widgets remain absent. Exact
device acceptance pending; no root-cause or reliability percentage claim.

Review correction: do not fall back to track performers. Existing artist pages
query albums by album-artist identity; mixing performer identity would create
misleading empty pages. Missing album-artist reference leaves View Artist disabled.
