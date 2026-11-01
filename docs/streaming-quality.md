# Streaming quality

> Historical development record. Candidate-stage status below describes that
> checkpoint, not current availability. The 0.5.0 integration includes the accepted
> HLS, quality/download and modern Mac credential work; see the authoritative
> [0.5.0 acceptance and release record](0.5.0-acceptance.md) for current scope,
> superseding evidence and pending publication/TestFlight gates. Earlier DEBUG-only
> restrictions and “not installed” statements must not be read as current policy.

All remote playback remains HLS. Quality is sampled once when a new resource is
prepared; settings and path changes do not replace the active player item.
Retained downloads continue to use their local files without sampling network
quality. Authentication, playback ownership and protected admission are unchanged.

On iOS, quality controls live in the system Settings app, with independent
**Wi-Fi & Wired Quality** and **Cellular Quality** choices. Each offers Original,
Auto and AAC ceilings of 320, 192 and 128 kbps. The cellular-access permission remains
separate. The existing scene-active hook refreshes preferences when returning from
system Settings; no additional polling or path monitor is introduced.

A known available Wi-Fi or wired path selects the Wi-Fi profile. Cellular wins for
mixed paths; unknown or unavailable observations select the cellular profile.
An Auto profile resolves as follows:

| Observation | Selected policy |
| --- | --- |
| Available unmetered Wi-Fi/wired, without cellular | Original |
| Cellular, expensive or unknown | AAC up to 192 kbps |
| Constrained / Low Data Mode | AAC up to 128 kbps |

This is a connection heuristic, not measured bandwidth or an adaptive rendition
ladder. Original preserves compatible encoding through HLS stream copy and uses
the established AAC fallback for unsupported formats; it does not guarantee
lossless delivery. A fixed quality is an explicit AAC ceiling and does not change
because a path becomes constrained.

Mac playback always selects Original, ignoring persisted quality choices. The
Mac app does not expose these selectors; its other library/settings behavior is
unchanged.

## Preference migration

The existing preferences owner manages `audio.streaming.wifiQuality` and
`audio.streaming.cellularQuality`. A valid legacy `audio.streaming.quality` value
seeds each missing new profile independently. Existing new values remain
authoritative; invalid new values fall back deterministically to Wi-Fi Original
or Cellular Auto. Without a valid legacy setting, those are also the fresh defaults.
The legacy key is retained unchanged for downgrade compatibility. Refresh reads
the new profiles without repeating migration or resetting independent choices.

## Validation status

The 211 candidate is local and uninstalled until its platform tests, production
Release HLS/cleanup checks, shipping checks and coordinated installation complete.
The 210 owner reported Auto and Standard 192 playback working; that does not establish
all seek, Next, background, route or 211 acceptance. Physical 211 checks must cover
new-resource application after system Settings changes, Wi-Fi/cellular/unknown
selection, Low Data Mode, playback while browsing, seeking and queued advance.
