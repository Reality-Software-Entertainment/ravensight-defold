# Changelog

## [0.1.0] - 2026-11-06

First release.

### Added

- The shared error queue rules: gameplay before captures in every batch;
  a capture evicts only the oldest capture, never gameplay or the batch in
  flight; `rs_trail` is never persisted; opt-out and reset delete persisted
  captures and temporary files. Scrub vectors at version 6 (home folder
  names with spaces, `Documents and Settings`).

- Sessions, batched events and the saved queue (version 2 format, one file
  per ingest key, atomic writes, origin per session, 500 events, 89 days).
- `game_started` at the real start and `game_exited` on quit, each once;
  the mobile background rule with its marker on iOS and Android.
- Gzip bodies from 1,024 bytes, HMAC-SHA256 signed batches when the session
  signs, `rs_event_id` on every event, the delivery response table and
  backoff with jitter.
- Status reasons (`getStatusReason`, `status_changed`) and the invalid key
  stop with one warning.
- Opt-out and opt-in consent, `resetDeviceId`, the playtest path.
- Typed events, `trackError` and automatic error capture (Lua errors and the
  engine's native crash dump) with on-device scrubbing and per-session
  limits.
- Ads and attribution helpers, remote config with experiment exposure.
- Specs under LuaJIT and inside the Defold engine, with a live wire test.
