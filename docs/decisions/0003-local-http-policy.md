# 0003 — Local plain-HTTP server policy

- Status: Accepted
- Date: 2026-07-29

## Context

Many personal Jellyfin servers use plain HTTP on a trusted home network, while
remote servers should use HTTPS. A global App Transport Security exception would
allow insecure traffic to arbitrary internet hosts and is broader than the
product requires.

## Decision

- Prefer and accept HTTPS for Jellyfin servers on any valid host.
- Permit HTTP only for local destinations: loopback, link-local, private IPv4,
  IPv6 unique-local or link-local addresses, unqualified hostnames, and
  `.local` names.
- Set `NSAllowsLocalNetworking` to declare and enable that local access.
- Do not set `NSAllowsArbitraryLoads`,
  `NSAllowsArbitraryLoadsForMedia`, or a wildcard domain exception.
- Enforce the local-only HTTP boundary in server URL validation before making a
  network request.
- Continue to use manual server entry in 0.1.0; Bonjour discovery is not enabled
  by this decision.

## Consequences

- A user can connect directly to a typical home Jellyfin server without
  weakening transport security for remote hosts.
- HTTP credentials and tokens remain unencrypted on the local network, so the
  connection interface must explain that risk.
- The URL validator needs tests for private, loopback, link-local, public,
  `.local`, and unqualified hosts across IPv4 and IPv6.
- Remote plain-HTTP servers are intentionally unsupported.
