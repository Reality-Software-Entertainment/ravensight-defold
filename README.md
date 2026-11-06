# Ravensight for Defold

Player analytics for Defold games: sessions, events, retention, levels,
errors, ads and attribution, remote config and experiments, sent to
[Ravensight](https://ravensight.io). Pure Lua, no native extension, so it
needs no build server and works wherever the engine's `http` module does.

Version 0.1.0. Beta: the specs and a live run pass inside the Defold 1.14
engine on Linux (see "Running the tests"), but no shipped game has proven it
on a device yet.

## Install

Add the library to your `game.project` dependencies, then Project > Fetch
Libraries:

```
[project]
dependencies#0 = https://github.com/Reality-Software-Entertainment/ravensight-defold/archive/refs/tags/v0.1.0.zip
```

The library shares one folder, `ravensight/` (`[library] include_dirs`).
You can also copy that folder into your project.

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
- Defold has no hook on its log, so this SDK sends no log trail.

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

## What it sends, and what it does not

- **A random device id per install**: 32 hex characters, a dash and the OS
  name, saved in your game's save folder. It comes from `/dev/urandom` on
  macOS, Linux, iOS and Android, and from `crypto.getRandomValues` on the
  web. Defold gives Lua no system random source on Windows, so there it is
  a SHA-256 over the time and process state. It is never derived from
  hardware or an account, and `resetDeviceId()` replaces it.
- **The events you track**, with a timestamp, your game version and the OS.
- **Device fields on the session**: the device model on iOS and Android
  (`sys.get_sys_info().device_model`) and the OS version. Defold reports no
  GPU name, so none is sent. Country is never sent by the SDK.
- **Error text** as described in "Errors", scrubbed on the device when it
  is captured automatically.
- **No advertising identifier, no names, no emails, no accounts.**

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

## License

MIT. See [LICENSE](LICENSE).
