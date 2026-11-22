# VelaCanto privacy policy

**Draft for owner review — not yet published or effective.**
Prepared 2026-10-25 for the current app. Publisher: **NovoLuxor**, United States.
Contact: **support@novoluxor.dev**.

## What VelaCanto does

VelaCanto connects your iPhone, iPad or Mac to a Jellyfin music server you choose.
It lets you browse and play music, manage supported playlists and favorites,
save local pins and queues, and download music for offline listening. NovoLuxor
does not provide the music library or operate your chosen server simply because
you use this app.

## Information handled by the app

When you sign in, the app sends your entered sign-in information directly to
your chosen server. It stores the resulting session credentials in the device's
Keychain. On Mac it uses Apple's Data Protection Keychain; it does not read or
migrate credentials from the older Mac credential store. Session credentials are
not configured for iCloud synchronization.

The app sends requests to your server for browsing, search, artwork, lyrics,
streaming, downloads and actions you choose, such as playlist or favorite changes.
It also sends playback start, progress and stop information to support server
session/history features. Requests can identify the account, app/device session,
requested media and playback activity. Your server and network operators can
receive technical connection information such as your IP address. The server
operator controls its own account records, logs and retention.

Your device stores app preferences, account-scoped library information, pins,
queue state, artwork/cache files and requested downloads. These can contain
music titles and other library metadata. Some metadata is stored in ordinary app
preferences/files, not separate application-level encrypted storage. Device/OS
security and backup behavior apply. Account-digest keys and opaque filenames do
not by themselves encrypt their contents.

The app has no advertising or cross-app tracking features and does not
automatically send usage analytics or diagnostic reports to NovoLuxor. Apple's
App Store/TestFlight and operating-system diagnostics may process information
under Apple's own settings and privacy terms. If you send us support email,
feedback, screenshots or logs, we receive the information you choose to include.
Please remove passwords, access tokens, private server addresses and personal
library information before sending support material.

## Why information is used and who receives it

On-device and server processing supports sign-in, requested library/playback
features, local preferences, offline availability, security and troubleshooting.
Information sent to your chosen server is handled by its operator, which may be
you or another organization. Ask that operator about access, account deletion,
playback history and server logs.

System features you use, including Siri, CarPlay, AirPlay and system media
controls, may expose the information needed for those features, such as the
current song and playback controls, on connected devices or system surfaces.
Choose those devices and routes accordingly. Apple's processing is governed by
its own policies. NovoLuxor uses support correspondence to respond and investigate
reported problems; information may also need to be retained or disclosed when
required by law or necessary to address a security incident.

The current app does not synchronize pins through iCloud, transfer playback
through Handoff, provide additional music-server providers or index local folders.
Those planned features will require updated disclosures before they ship.

## Connections and security

The app requires an HTTPS server address and uses native Apple networking,
credential and media facilities. Media request URLs can include an authentication
token. HTTPS protects transit but does not prevent your server or proxy from
recording request information. Server operators should restrict and redact logs.
No system can guarantee complete security, and a device's backup/export settings
can affect retained copies.

## Retention, removal and your choices

You can remove downloads and manage disposable cached media in the app. Removing
one download owner may leave a shared file while another downloaded item still
needs it. A file in active playback may remain until the player releases it.
Disposable caches are bounded and can be refreshed or evicted by the app/OS.

Successful local sign-out removes the saved active credentials and account-owned
local pins, queue and download/catalog data through the app's cleanup flow. A
cleanup failure is reported rather than treated as successful deletion. A Mac
upgrade with unavailable modern credentials can preserve inaccessible local
account data pending reauthentication; deleting unmatched data requires a separate
confirmation. Local cleanup does not erase older backups, copies you exported,
server logs, server accounts or server-held listening history. Local sign-out is
not a guarantee that a server revoked every previously issued token.

Control permissions, connected devices, storage and Apple diagnostic sharing
through the app and system settings. The app signs in to an existing server
account; it does not create or delete that server account. Contact the server
operator to exercise choices about that account and its data.

We retain support correspondence only as needed to handle the request, follow up
on security/product issues and meet applicable legal obligations. Contact
support@novoluxor.dev to ask about information you supplied to NovoLuxor or request
its correction/deletion. Available rights and lawful retention exceptions depend
on applicable law. Do not send credentials to prove your identity.

## Children and changes

VelaCanto is a music client, not a service designed to collect children's personal
information. If you believe a child sent personal information directly to
NovoLuxor, contact support@novoluxor.dev so we can address it. Your server operator
and Apple separately control their account and age requirements.

We will update this policy when the app's processing changes and identify the
effective version when published. Material changes will be explained before the
new processing applies where required. This draft is not a request to accept
future optional sync or other features.
