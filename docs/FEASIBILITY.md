# Defold: feasibility against the SDK contract

Checked on 2026-11-06 against the Defold API reference (defold.com/ref) and
manuals, and by running Defold 1.14.0 (`d295ed4`): `bob.jar`, the macOS
arm64 headless engine, and the Linux arm64 full engine on a virtual
display. "Observed" means a run here showed it; "documented" means the
reference says so and nothing here contradicted it.

| Contract need | Engine API | Verdict |
|---|---|---|
| Persistent file storage | `sys.get_save_file(app_id, name)` gives a path in the per-user save folder; Lua `io` and `os.rename` work on it (desktop, mobile). On HTML5 the SDK uses `sys.save`/`sys.load`, which the engine persists in the browser. | Possible. Atomic replace by temporary file and rename; on Windows, where `os.rename` cannot replace, the old file is removed first and a read falls back to the temporary file. HTML5 path not run here. |
| HTTP with custom headers and a body | `http.request(url, method, callback, headers, post_data, {timeout})`. `post_data` is a string, which carries gzip bytes. | Possible, observed (custom `X-API-Key`, `X-Session-Token`, `X-Ravensight-*` and `Content-Encoding` headers arrived; a gzip body decoded). The reference says response headers come "for status 200 or 206"; observed on 1.14.0 Linux, a 429's `Retry-After` reached Lua too. Header names are lower-cased by the SDK either way. A network failure is mapped to status 0. |
| The `http` module itself | Present in the full engine; **absent from `dmengine_headless`** (observed on macOS and Linux). | A headless server build sends nothing; the specs still run there. |
| Request timeout | `options.timeout` per request, else `network.http_timeout`. | Possible: 15 s per request. |
| gzip | `zlib.deflate(string)` returns a zlib (RFC 1950) stream, not gzip. | Possible: the SDK strips the 2 byte header and Adler-32 trailer and adds a gzip header and CRC-32 trailer (pure Lua CRC-32). Observed decoding on the server side of the live test. |
| HMAC-SHA256 | No hash in the core API (`crypt` is a separate extension). | Possible: pure Lua SHA-256 over the BitOp library, checked against the delivery contract's vectors under LuaJIT and inside the engine. |
| Random bytes for the device id | No Lua call for system random bytes. | Degraded on Windows only: `/dev/urandom` on macOS, Linux, iOS and Android, `crypto.getRandomValues` through `html5.run` on the web; on Windows a SHA-256 over time and process state, said once in the log. The id is unique per install, not secret. |
| Quit hook | No quit callback. `final()` of a script runs on a normal exit; `sys.exit(code)` ends the app. | Degraded: `ravensight.quit(code)` holds the quit for up to 1.5 s while the last batch is sent, then calls `sys.exit`. A window closed by the player reaches `final()`, which cannot wait for a request, so `game_exited` is saved in the queue and sent on the next launch with its original session's origin. |
| Background hook | `window.set_listener`: `FOCUS_LOST`, `FOCUS_GAINED`, `ICONIFIED`, `DEICONIFIED`, `RESIZED`. The reference does not say which fire on mobile. | Possible as designed: on iOS and Android, focus lost or iconified is the move to the background. Not run on a device. Only one window listener exists; `windowListener = false` lets a game keep its own and forward events. |
| JSON that escapes correctly | `json.decode` exists; the SDK carries its own encoder for byte-exact, signed bodies. | Possible, covered by the JSON specs. |
| Error capture | `sys.set_error_handler(fn(source, message, traceback))`; the `crash` module reads the last native crash dump once (`crash.load_previous`, deleted after loading). | Possible. There is one error handler and no way to read the old one, so chaining is not possible: a game with its own handler turns capture off and forwards. No log hook, so no trail. |
| Device fields | `sys.get_sys_info()`: `device_model` (iOS, Android), `system_version`. No GPU name. | Model and OS version sent; GPU omitted. |
| Playtest command line | No raw command line in Lua. | Degraded: environment variables, or `--config=ravensight.playtest_token=...` read through `sys.get_config_string`. |
| Packaging | A library project: `[library] include_dirs = ravensight` in `game.project`; a game lists the repository's zip archive URL in `project.dependencies`. | Possible. Every `require` is a literal string, because bob only bundles modules it can see. |

## Contract items degraded

- Native crash and Lua error capture cannot chain to another handler.
- `game_exited` on a player-closed window is delivered on the next launch.
- No log trail (`rs_trail` is never sent).
- Device id randomness on Windows is not from a system generator.
- No GPU name on the session.
- A headless (server) Defold build has no HTTP and sends nothing.
