# Changelog

## 0.2.0 - 2026-11-19

Needs a Ravensight server with `POST /identify` and `identify.salt` on the
session answer; until then identify sends nothing.

### Added

- `ravensight.identify(accountId)`, `ravensight.resetIdentity()` and `ravensight.isIdentified()` for games with their own login. Only a salted hash of the id (`accountHash`, HMAC-SHA256 keyed with the game's salt from the session answer) is sent, with the session token, once per session; the raw id is never sent or saved and is held in memory only until the salt is known. The hash is saved as `ravensight_identity` beside the device id, in the save folder or the engine's browser storage on HTML5. A value that is not a string or whole number, is empty, is over 256 bytes of UTF-8 or contains `@` is refused (`false` and the reason, one warning). A different account first resets the identity, which also switches to a fresh device id; `resetDeviceId()` alone keeps it. A failed or refused request is tried again at the next session, never in a loop; a second `no_session` answer in a row stops identify until `resetIdentity()`. Without a key, with `enabled = false`, before an opt-in yes or in a playtest run nothing is saved or sent, and opting out deletes the saved hash.
- `ravensight.setCampaignLink(linkId)` passes a Ravensight campaign link on from the address a game was opened with. A link id (24 hex characters, sent lowercased) goes as `campaignLink` on the next session the SDK opens for its own player, never in a playtest run, and is cleared only when that session answers with a token; a call before `init` goes with the first session. Returns `true`, or `false` and `"invalid_link"`. Memory only, with the same consent and key rules as everything else. An HTML5 build reads `rs_link` from the page address itself, once, at `init`.

### Changed

- The README opens with a preview line saying what has and has not been verified, and installs from the public repository's `v0.2.0` tag. CI runs nightly on weekdays and on demand, not on pushes or pull requests, and a pre-push hook in `.githooks` runs the specs before every push.

## 0.1.0 - 2026-11-06

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
