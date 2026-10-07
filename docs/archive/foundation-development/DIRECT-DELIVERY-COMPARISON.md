# Build98: direct delivery on accepted66

Exact baseline0cb5f1553b165c02ee87ae49acf0efe6476722f4. Restore only delivery policy and its existing endpoint test from190ee9b70532dc83de4e91082b07a3d85f54813d. Remove Now Playing AirPlay picker per owner; volume remains inactive baseline placeholder. No later player, seek, reporting, transport, artwork, UI or diagnostics integration.

Official universal audio endpoint requests supported native audio formats, with server-selected AAC/HLS for incompatible media. Changes media request shape and potentially bandwidth; catalog/artwork request budgets unchanged. No additional negotiation, retry or custom connection manager.

Owner device gate: starting tracks, rapid forward/back, Play Next albums, queue selection, mixed formats and browsing. Confirm server delivery mode when available; not every track is guaranteed direct. Seeking/scrubber candidate103540d explicitly held until owner accepts98. Original66 preserved.
