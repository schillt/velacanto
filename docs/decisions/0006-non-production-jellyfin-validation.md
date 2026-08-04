# 0006 — Isolate non-production Jellyfin validation

- Status: Accepted
- Date: 2026-08-04

## Context

Velacanto needs a repeatable Jellyfin environment to validate browsing,
streaming, privacy boundaries, and release smoke tests. A developer's personal
server or media library is not an acceptable shared release dependency: it can
expose private media, account data, endpoints, and authentication material.

This is a maintainer release-validation environment only. It is not Velacanto
product infrastructure and does not require end users to use, share, or expose
their own Jellyfin server.

## Decision

Velacanto will use a dedicated, non-production Jellyfin instance with these
minimum controls:

- The server, Jellyfin database, media storage, and test accounts are separate
  from any personal or production instance.
- The library contains only synthetic, owned, public-domain, or otherwise
  licensed test material. It contains no personal media or personal account
  data.
- The instance is private-LAN or VPN-only by default. It is not exposed
  directly to the public internet. Any later remote access requires trusted
  HTTPS through a reviewed reverse proxy and firewall policy.
- One named Test Server Owner is accountable for access review, software
  updates, backups, restore testing, account revocation, log retention, and
  incident response. The owner's identity, endpoint, credentials, and storage
  location are recorded only in the private operations record.
- The admin account is private. App validation uses non-admin test accounts;
  credentials are held in an approved password manager and are never committed
  to this repository or included in screenshots, bug reports, or logs.
- Reverse-proxy and diagnostic logging must not retain complete request URLs or
  query strings, because Jellyfin requests can contain authentication material.
- The private operations record contains the provisioning, reset, backup,
  rotation, access-revocation, and manual smoke-test procedures.

The public release evidence records only non-sensitive environment facts, such
as Jellyfin version, device and OS version, network class, source codec, and
direct-play or transcode result.

## Consequences

- Issue #9 cannot close until a named owner, isolated instance, private
  operations record, test account, and representative test library exist and
  the manual smoke test has been run.
- Public documentation must never contain the server URL, IP address, account
  names, credentials, private media names, raw logs, or backup locations.
- The test library must cover artwork, large paginated collections, duplicate
  display names across libraries, ordered multi-disc tracks, empty states,
  direct-play media, transcoding media, and an unsupported-media case.
