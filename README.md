# Ravensight for Defold

Player analytics for Defold games: sessions, events, retention, levels,
errors, ads and attribution, remote config and experiments, sent to
[Ravensight](https://ravensight.io). Pure Lua, no native extension, so it
needs no build server and works wherever the engine's `http` module does.

Preview: not yet verified inside Defold on a device; tested with the specs
under LuaJIT, and in CI with the same specs and a live run against a local
mock API inside the Defold 1.14 engine on Linux.

Version 0.2.0. See [docs/FEASIBILITY.md](docs/FEASIBILITY.md) for what each
engine API gives and where the SDK degrades.

## Install

The source is the public repository
[ravensight-defold](https://github.com/Reality-Software-Entertainment/ravensight-defold).
Nothing is published to an asset store. Add the archive of its `v0.2.0` tag
to your `game.project` dependencies, then Project > Fetch Libraries:

```
[project]
dependencies#0 = https://github.com/Reality-Software-Entertainment/ravensight-defold/archive/refs/tags/v0.2.0.zip
```

The library shares one folder, `ravensight/` (`[library] include_dirs`).
You can also copy that folder from a clone into your project.

## Use

```lua
-- main.script, on a game object in your bootstrap collection
local ravensight = require("ravensight.ravensight")

function init(self)
	ravensight.init({ ingestKey = "gt_live_...", gameVersion = "1.0.0" })
end

function update(self, dt)
	ravensight.update(dt)
end

function final(self)
	ravensight.final()
end

-- anywhere
ravensight.track("level_start", { level = "forest_1" })
```

Quit through `ravensight.quit(code)` in place of `sys.exit(code)`: it
records `game_exited`, sends the last events and exits once they are
answered or 1.5 seconds pass. A window closed by the player runs `final()`,
which records `game_exited` and saves it; it is sent on the next launch
under the session it happened in.

Without an `ingestKey` the SDK is inert: no files, no network, every call a
no-op. Pass `optional = true` to silence the one warning that prints.

The key is publishable: it ships inside your build. It can open sessions,
read the tracking kill switch and read this game's design suggestions, and
nothing else.

## Options

| Option | Default | What it does |
|---|---|---|
| `ingestKey` | none | Your game's publishable key. Empty means inert. |
| `apiUrl` | `https://api.ravensight.io` | With or without `/api/v1`; whitespace and trailing slashes are ignored. |
| `gameVersion` | `project.version`, else `"1.0.0"` | Sent on every session. |
| `enabled` | `true` | `false` sends and queues nothing this run. Not saved. |
| `consent` | `"opt_out"` | `"opt_in"` sends nothing, and makes no device id, until `setTrackingEnabled(true)`. |
| `maxQueueSize` | `500` | Unsent events kept, oldest dropped first. |
| `flushInterval` | `2` | Seconds an event waits to be batched. |
| `timeout` | `15` | Seconds per request. |
| `sessionTimeout` | `1800` | Seconds in the background (iOS, Android) before a return is a new session. |
| `captureErrors` | `true` | Automatic error capture (see "Errors"). |
| `windowListener` | `true` | Installs a `window.set_listener` for focus and background. With `false`, call `ravensight.window_event(event, data)` from your own listener. |
| `distribution` | none | A short label sent on the session, such as `"steam"` or `"itch"`. |
| `appId` | the project title | The save folder name passed to `sys.get_save_file`. |
| `debug` | `false` | Print informational lines too. |
| `optional` | `false` | Silence the warning an inert start prints. |

## Functions

| Function | What it does |
|---|---|
| `init(options)` | Start. Call once. |
| `update(dt)` | Timers, retries and the quit hold. Call every frame. |
| `final()` | Record `game_exited` and save the queue. Call from `final()`. |
| `quit(code)` | Record `game_exited`, flush, then `sys.exit(code)` within 1.5 s. |
| `track(name, data)` | Queue an event. `data` is a flat table. |
| `flush()` | Send now. Cuts a backoff wait short, never a server's Retry-After. |
| `purchase`, `resource`, `progression` | Typed events (see "Typed events"). |
| `trackError(severity, message, opts)` | A manual error (see "Errors"). |
| `trackAd`, `trackAdRevenue`, `setAttribution` | Ads and attribution. |
| `microsFromDecimalString(text)`, `microsFromRevenue(number)` | Revenue in micros without a float multiply. |
| `getConfig(key, fallback)`, `fetchConfig()` | Remote config. |
| `submitFeedback(message, category, rating)` | Player feedback. Returns `true`, or `false` and a reason. |
| `setTrackingEnabled(on)`, `isTrackingEnabled()` | The player's choice, saved at once. Works before `init`. |
| `resetDeviceId()` | A fresh random id; the queue and the session are dropped. Returns the new id. |
| `identify(accountId)` | Link this device to your game's own account after sign-in. Returns `true`, or `false` and a reason. See "Identify players who sign in". |
| `resetIdentity()` | On sign-out: forget the account and switch to a fresh device id. |
| `isIdentified()` | `true` while an account is set by `identify()`. |
| `setCampaignLink(linkId)` | Send a Ravensight campaign link id with the next session. Returns `true`, or `false` and `"invalid_link"`. An HTML5 build reads it from the page address itself. See "Campaign links". |
| `getDeviceId()`, `getSessionToken()`, `isPlaytest()` | Identity. The session token is `""` until a session opens; pass it to your game server as `joinToken`. |
| `getStatusReason()` | Why nothing is being sent, or `nil` when ready. |
| `enabled()` | True only while collecting. |
| `getDeliveryStats()` | Events let go of since launch: `dropped_overflow`, `dropped_too_old`, `dropped_refused`. |
| `on(name, fn)` | Subscribe to an SDK event; returns an unsubscribe function. |
| `FEEDBACK_CATEGORIES` | `bug`, `suggestion`, `complaint`, `praise`, `playtest`, `other`. |

Events for `on`: `session_ready`, `session_failed(reason)`,
`status_changed(reason)`, `tracking_disabled(source)`,
`events_flushed(count)`, `flush_failed(reason)`, `feedback_submitted`,
`feedback_failed(reason)`, `event_tracked(name, data)`,
`config_ready(source)`.

### Status reasons

`getStatusReason()` and `status_changed` use one vocabulary: `disabled`
(switched off or opted out), `invalid_key`, `tracking_disabled` (the kill
switch), `offline`, `rate_limited`, `session_failed`,
`playtest_job_closed`, or `nil` when ready.

A refused key (a 401, or a 403 that is not the kill switch) stops sending
for the run and logs once, at warning level, whatever `debug` says:
`Ravensight: ingest key refused (invalid_key), sending stopped for this run. Check your gt_live_ key.`
The queue stays on disk for the next launch.

## Automatic events

Exactly two: `game_started`, queued once when the SDK starts (first in the
queue, at the real start time; the settings check then decides whether it
is sent), and `game_exited`, queued once on the quit path. Desktop focus
loss is not an exit and sends nothing; it flushes.

**iOS and Android.** Losing focus is the move to the background: the SDK
records the time, saves the queue, flushes, and writes a small marker
(`ravensight_background.json`: the session token, its expiry and that
time). No event. On the return the marker is deleted; after
`sessionTimeout` seconds (30 minutes by default) away, `game_exited` is
queued at the time the player left, under the old session, and a new
session starts with `game_started`. Under 30 minutes nothing is queued. A
cold launch that finds an unexpired marker (the app was killed in the
background) sends one `game_exited` under the old token, once, and deletes
the marker whatever the answer.

Timestamps are unix milliseconds, taken when the event happened.

## Levels and deaths

Give a level or death event a reserved `rs_kind` so the Levels view reads
it without setup: `level_start`, `level_complete`, `death` or `none`.

```lua
ravensight.track("boss_defeated", { rs_kind = "level_complete", level = "forest_1" })
ravensight.track("fell_in_pit", { rs_kind = "death", level = "forest_1" })
```

Keys starting with `rs_` are reserved for the SDK and the platform. Do not
invent your own.

## Typed events

```lua
ravensight.purchase(499, "usd", "gems", "gem_pack_small")       -- 4.99 in minor units
ravensight.resource("source", "gold", 50, { itemType = "quest" })
ravensight.progression("complete", "forest_1", { score = 1200 })
```

## Errors

- `trackError(severity, message, opts)` sends an error you report yourself:
  `rs_kind = "error"`, the severity (`debug`, `info`, `warning`, `error`,
  `critical`), the message cut to 200 characters and `opts.stack` to
  2,000. `opts.errorType` names the error's type. It is sent as written;
  the server scrubs it.
- **Automatic capture** is on by default. The SDK installs
  `sys.set_error_handler`, so a Lua error anywhere in your scripts is sent
  as `rs_source = "uncaught"`, and a native crash from the last run (the
  engine's crash dump, through the `crash` module) is sent once as
  `rs_source = "crash"`, severity `critical`. Automatic text is scrubbed on
  the device first (emails, tokens and keys, IP addresses, home folder
  names, URL queries), with the same rules and cases as the server.
- Limits per session: 30 captures, 3 for one message pattern, 6 a minute.
  Before the session answer arrives at most 5 are held; they are sent once
  the answer says your game's capture switch is on, and discarded unsent
  when it is off.
- Defold keeps one error handler. If your game sets its own, pass
  `captureErrors = false` and call
  `ravensight.captureLuaError(source, message, traceback)` from yours.
- Defold has no hook on its log, so this SDK sends no log trail, and an
  `rs_trail` key is never written to disk: it is stripped before the queue
  is saved and from anything read back.
- **The queue under a storm.** Gameplay events (a manual `trackError`
  included) go before automatic captures in every batch. When the queue is
  full, an incoming capture evicts the oldest capture or is dropped itself;
  it never evicts a gameplay event, and nothing in the batch in flight is
  ever evicted.
- The hooks are installed only with a key and after consent (with
  `consent = "opt_in"`, at the yes). Defold keeps one error handler and
  cannot restore its own, so after an opt-out or when your game's capture
  switch is off the installed handler stays and does nothing.
- Opting out or resetting the device id deletes the saved queue (captures
  included), any pending error records and any temporary `.tmp` copies.
- **Backups.** The queue and pending error records live in the save folder
  from `sys.get_save_file`. Defold gives Lua no way to mark a file as
  excluded from iOS or Android backups, so they can be included in a device
  backup; a game that must exclude them sets the attribute natively.

## Delivery

- Events are batched: a request goes out `flushInterval` seconds after the
  first waiting event, at once when 50 are waiting, on `flush()`, on the
  move to the background and on quit. At most 50 events per request.
- **Saved queue.** Unsent events are written to
  `ravensight_queue-<16 hex>.json` in the save folder (one file per ingest
  key, named by a hash of the key) whenever the queue changes. A temporary
  file is renamed over the old one, so a partial write never replaces a
  good file. At most 500 events are kept, oldest dropped first, and events
  older than 89 days are dropped when it is read. An event leaves the file
  only after a 2xx answer, or a 400 that refuses it.
- **Origin.** Each session's events are saved with the session answer's
  `origin`, and a later launch sends them with it, so the server files them
  under the session, build and platform they happened in. The origin's
  `stamp` is a credential for that old session, kept only in the queue file.
- **Compression.** A body of 1,024 bytes or more is sent gzip compressed.
  Defold's `zlib.deflate` makes a zlib stream; the SDK rewraps the same
  deflate data as gzip.
- **Signing.** When the session answer has `signing` (public keys), every
  batch carries `X-Ravensight-Timestamp` and an HMAC-SHA256
  `X-Ravensight-Signature` over the uncompressed body. The secret stays in
  memory.
- **Retries.** 10 seconds, doubling to 5 minutes, each wait multiplied by a
  random factor from 0.5 up to 1. A 429, or a 503 with Retry-After, waits
  exactly the server's time. A batch 401 opens a new session once.
- **Refusals.** A 400 naming one event by `index` drops that event; a
  `batch_too_large` or 413 halves the batch; any other 400 drops the
  request's events. A refused key or the kill switch stops the SDK for the
  run.
- Every event carries an `rs_event_id`, so a resend within the server's
  duplicate window is recognised and not stored twice.

## Ads and attribution

```lua
-- a paid impression: revenue in micros as a digit string, never a float
ravensight.trackAdRevenue("admob", "rewarded", "level_end", "1500", "USD")
-- from a mediation callback's revenue in major units
ravensight.trackAdRevenue("applovin", "interstitial", "menu", ravensight.microsFromRevenue(0.0015), "USD")
ravensight.trackAd("admob", "banner", "clicked")
-- where this install came from, sent once per install
ravensight.setAttribution({ source = "organic" })
```

Pass `ravensight.getDeviceId()` to an attribution partner as its customer
user id before the partner's SDK starts.

## Remote config and experiments

`ravensight.getConfig("player_speed", 3)` returns the value from the last
fetched config, or the fallback. The first read in a session marks every
running experiment as exposed: from then on each event carries
`rs_exp_<key> = <variant>`, and one `rs_exposure` event is sent. A fetch
alone tags nothing.

## Identify players who sign in

If your game has its own login, call `identify()` once the player signs in
and `resetIdentity()` when they sign out. One person on two devices, or
before and after signing in, then counts as one player.

```lua
ravensight.identify(account.analyticsId)  -- after your own sign-in: a random id stored with the account
ravensight.resetIdentity()                -- on sign-out
```

- **What is sent:** a salted hash of the id (`accountHash`, 64 hex
  characters, keyed with your game's own salt from the session answer) and
  the session token, once per session. The raw account id, an email or a
  name is never sent and never saved; until the first session answer the id
  is held in memory only.
- **Pass a random, high-entropy id**, such as a random UUID or a random
  analytics id you make once for each account and store with it, never a
  sequential database key, an email, a name or a handle. Your game's salt
  reaches every copy of the game, so anyone could hash 1, 2, 3 and onward
  and match a guessable id; a random one cannot be guessed. The hash is
  still a pseudonymous identifier for the player: declare it in your game's
  privacy notice. Pass it as a string; a whole number is accepted and used
  as its decimal digits, but a sequential number is exactly the guessable
  kind. A value that is
  empty, over 256 bytes of UTF-8 or contains `@` is refused: `identify()`
  returns `false` and the reason (`"not_text"`, `"empty"`, `"too_long"` or
  `"looks_like_email"`), prints one warning, and nothing changes. Before
  `init` it returns `false, "not_started"`.
- **One event per identified session** on your usage balance. The same
  account again in the same session sends nothing; a refused or failed
  request is tried once more at the next session, never in a loop. A server
  that does not offer identify turns it off until the next launch. If the
  server answers twice in a row that the session was not live
  (`no_session`), identify stops until `resetIdentity()`.
- **A different account** on the same device first does `resetIdentity()`,
  which deletes the saved hash and switches to a fresh device id (as
  `resetDeviceId()` does), so the next player is not linked to the last
  one. `resetDeviceId()` alone keeps the identity.
- The hash is saved as `ravensight_identity` in the save folder (in the
  engine's browser storage on HTML5), beside the device id. It never enters
  the event queue and never delays an event. Without a key, with
  `enabled = false`, before an opt-in yes, or in a playtest run it is held
  in memory only; `setTrackingEnabled(false)` deletes it.

## Campaign links

A Ravensight campaign link adds `rs_link=<link id>` to the address it
redirects to, when that address is your own web page.

- **HTML5: nothing to call.** The SDK reads `rs_link` from the page address
  (`location.search`) once, at `init`, and sends it as `campaignLink` with
  the first session it opens. It reads the address of the page the game
  runs on: a game inside a frame on another site sees the frame's own
  address, which carries no tag.
- **Desktop and mobile: pass it on yourself**, from the address your game
  was opened with, if it handles one (a deep link or a custom URL scheme).
  Call `setCampaignLink()` before `init` if you can; a later call goes with
  the next session the SDK opens.

```lua
-- The rs_link value of an address such as
-- mygame://open?rs_link=64b0000000000000000000a1
local function rs_link_from(address)
	local query = address:match("^[^#?]*%?([^#]*)") or ""
	for pair in query:gmatch("[^&]+") do
		local key, value = pair:match("^([^=]*)=?(.*)$")
		if key == "rs_link" then return value end
	end
end

-- wherever your game receives the address it was opened with
local id = rs_link_from(address)
if id then ravensight.setCampaignLink(id) end
```

`setCampaignLink(linkId)` returns `true` when the value is a link id (24 hex
characters, in any case), which then replaces a link still waiting, and a
link set before `init` replaces the one on an HTML5 page address. For
anything else it returns `false, "invalid_link"` and nothing changes. The
id goes lowercased, as `campaignLink`, on the session:

- **Sent once.** Only a session answer with a token clears it, so a failed
  attempt keeps it for the next one. Later sessions carry none.
- **Same consent as everything else.** With `consent = "opt_in"` it goes
  with the first session after the player's yes. An opted out player, a run
  with `enabled = false` or without a key sends nothing, and a playtest run
  never sends it.
- **Nothing is stored.** The id is one your studio made, not personal data.
- The server keeps it only when it names a link of the same game. The player
  and the session are then counted on the Campaign links page, by link.

## What it sends, and what it does not

- **A random device id per install**: 32 hex characters, a dash and the OS
  name, saved in your game's save folder. It comes from `/dev/urandom` on
  macOS, Linux, iOS and Android, and from `crypto.getRandomValues` on the
  web. Defold gives Lua no system random source on Windows, so there it is
  a SHA-256 over the time and process state. It is never derived from
  hardware or an account, and `resetDeviceId()` replaces it.
- **A salted hash of your own account id**, only when your game calls
  `identify()`, once per session (see "Identify players who sign in").
- **A campaign link id**, once, on the first session after it is read from
  an HTML5 page address or your game calls `setCampaignLink()` (see
  "Campaign links").
- **The events you track**, with a timestamp, your game version and the OS.
- **Device fields on the session**: the device model on iOS and Android
  (`sys.get_sys_info().device_model`) and the OS version. Defold reports no
  GPU name, so none is sent. Country is never sent by the SDK.
- **Error text** as described in "Errors", scrubbed on the device when it
  is captured automatically.
- **No advertising identifier, no names, no emails.** There is no field for
  them, and `identify()` refuses any value containing `@`.

A game using it needs no tracking permission prompt. The
[privacy label section of the docs](https://ravensight.io/docs/#privacy-label)
has the answers for the store forms. Ravensight ships no consent screen;
wire yours to `setTrackingEnabled` and `resetDeviceId`. To send nothing
until the player agrees, pass `consent = "opt_in"`.

## Telling players

You do not need a permission prompt, but saying what the game sends is good
manners. A paragraph your game can show, in a settings screen or on its
store page:

> This game sends anonymous gameplay events (what happens in the game, never
> who you are) to Ravensight so we can improve it. You can turn this off in
> Settings at any time.

And the toggle behind "turn this off":

```lua
-- an "Analytics" switch in your settings screen
local function set_analytics(on)
	ravensight.setTrackingEnabled(on) -- remembered across launches
end

-- a "Forget me" button: a fresh random identity from now on
local function forget_me()
	ravensight.resetDeviceId()
end
```

## Playtest

A Ravensight playtest run passes a token and a run id. The SDK reads
`RAVENSIGHT_PLAYTEST_TOKEN` and `RAVENSIGHT_PLAYTEST_RUN_ID` (and
`RAVENSIGHT_PLAYTEST_JOB_ID`, `RAVENSIGHT_PLAYTEST_PERSONA`) from the
environment, or the engine config keys `ravensight.playtest_token` and
`ravensight.playtest_run_id`, which a desktop build takes on its command
line (`--config=ravensight.playtest_token=...`; Defold gives Lua no raw
command line). In a playtest run the device id is `pt-<runId>` in memory
only, every request carries `X-Ravensight-Playtest`, nothing is written,
and the saved opt-out is ignored. `isPlaytest()` says so.

## Compatibility

| Target | State |
|---|---|
| Linux | Specs and a live run pass inside the Defold 1.14.0 engine (arm64 locally, x86_64 in CI) |
| macOS | Specs pass inside the 1.14.0 headless engine; the headless engine has no `http` module, so no live run |
| Windows, iOS, Android, HTML5 | Not yet verified on a device |

Defold runs LuaJIT, and plain Lua 5.1 on HTML5. The SDK uses only Lua 5.1
and the BitOp library Defold ships everywhere. See
[docs/FEASIBILITY.md](docs/FEASIBILITY.md) for what each engine API gives
and where the SDK degrades.

## Running the tests

```sh
luajit spec/run.lua
```

runs every spec under LuaJIT with a fake clock and network. To run them
inside the engine, plus a live run against a local mock API that checks
the wire (settings, session, Retry-After, gzip, signatures, every event):

```sh
node test/engine.mjs path/to/bob.jar path/to/dmengine java
```

`bob.jar` and the engine come from `https://d.defold.com/archive/stable/<sha1>/`
(bob needs Java 25). On Linux, pass `test/engine-xvfb.sh` as the engine with
`DMENGINE` set to the full engine: the headless engine has no `http` module.
CI runs both (`.github/workflows/test.yml`).

Install the local checks once per clone: `git config core.hooksPath .githooks`. The pre-push hook then runs this repository's tests before every push, with a time limit, and refuses the push if they fail. CI runs nightly and on demand, not on pushes or pull requests, so this hook is where a change is checked first.

The hook runs `luajit spec/run.lua`. The engine test downloads the engine,
so it runs in CI only.

## License

MIT. See [LICENSE](LICENSE).
