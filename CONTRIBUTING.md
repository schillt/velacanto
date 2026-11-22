# Contributing to VelaCanto

Read [current instructions](AGENTS.md), the [native source guide](NativeFoundation/AGENTS.md),
the [checkpoint](docs/0.6.0-alpha-checkpoint.md), and the live
[0.6 milestone](https://github.com/schillt/velacanto/milestone/9).
Develop in a local non-synchronized checkout. Agree on bounded file ownership with
the integration maintainer before parallel work; only one agent owns native
builds, simulators or physical installation at a time.

Return focused changes and exact verification scope to the maintainer. Use the
existing build/test scripts and preserve failing evidence. Keep source simple and
bounded, retain the native player and account isolation, and distinguish implemented
behavior from rendered acceptance and actual device results. See the current
[agent handoff](docs/0.6.0-agent-handoff.md) for commands and unfinished gates.

Never commit credentials, signing profiles, generated Cloud registration, private
server/media data, raw traces or device receipts. Temporary branches remain local.
The current owner authorized one reviewed usable checkpoint to GitHub alpha after
installation. Beta/main promotion, tags and TestFlight/App Store distribution need
separate direct authorization. Preserve all permanent branch heads.
