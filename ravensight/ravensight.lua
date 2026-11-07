-- ravensight: player analytics for Defold games.
--
--   local ravensight = require("ravensight.ravensight")
--
--   function init(self)
--     ravensight.init({ ingestKey = "gt_live_...", gameVersion = "1.0.0" })
--   end
--   function update(self, dt) ravensight.update(dt) end
--   function final(self) ravensight.final() end
--
--   ravensight.track("level_start", { level = "forest_1" })
--
-- Quit through ravensight.quit(code) to give the last events up to 1.5
-- seconds to leave; a window closed by the player reaches final(), which
-- saves game_exited for the next launch. See README.md for the reference.
--
-- MIT licensed, part of ravensight-defold.

local Core = require('ravensight.core')
local Typed = require('ravensight.typed')
local Gzip = require('ravensight.gzip')
local Hmac = require('ravensight.hmac')

local M = { VERSION = Core.VERSION, FEEDBACK_CATEGORIES = { 'bug', 'suggestion', 'complaint', 'praise', 'playtest', 'other' } }

local core
local config
local initialized = false
local quitCode = nil
local exited = false

-- The engine, reached through globals so the tests can stand in for it.
local function engine(name) return rawget(_G, name) end

local function log(level, message)
  if level == 'info' and not (config and config.debug) then return end
  print('Ravensight: ' .. message)
end

-- ---------------------------------------------------------------- platform

local PLATFORMS = {
  Darwin = { 'macOS', 'macos' },
  Windows = { 'Windows', 'windows' },
  Linux = { 'Linux', 'linux' },
  ['iPhone OS'] = { 'iOS', 'ios' },
  Android = { 'Android', 'android' },
  HTML5 = { 'Web', 'web' },
}

local function sysInfo()
  local sys = engine('sys')
  local ok, info = pcall(function() return sys.get_sys_info() end)
  if ok and type(info) == 'table' then return info end
  return {}
end

local function platformNames(info)
  local name = tostring(info.system_name or 'unknown')
  local pair = PLATFORMS[name]
  if pair then return pair[1], pair[2] end
  return name, (name:lower():gsub('[^a-z0-9]', ''))
end

--- Device fields the engine reports without a prompt: the model on iOS
--- and Android and the OS version. Defold reports no GPU name.
local function deviceFields(info)
  return { model = info.device_model, osVersion = info.system_version }
end

local function toHex(bytes)
  return (bytes:gsub('.', function(c) return string.format('%02x', c:byte()) end))
end

--- Random bytes as hex: the operating system's generator where it can be
--- read (/dev/urandom on macOS, Linux, iOS and Android), the browser's
--- crypto.getRandomValues on the web, and otherwise (Windows) a SHA-256
--- over every source that differs between installs and launches, said
--- out loud once. Defold has no Lua call for system random bytes.
local warnedRandom = false
function M._randomHex(count)
  local f = io.open('/dev/urandom', 'rb')
  if f then
    local bytes = f:read(count)
    f:close()
    if bytes and #bytes == count then return toHex(bytes) end
  end
  local html5 = engine('html5')
  if html5 and html5.run then
    local ok, hex = pcall(html5.run, 'Array.from(crypto.getRandomValues(new Uint8Array(' .. count .. ')),function(b){return("0"+b.toString(16)).slice(-2)}).join("")')
    if ok and type(hex) == 'string' and #hex == count * 2 and hex:match('^%x+$') then return hex:lower() end
  end
  if not warnedRandom then
    warnedRandom = true
    log('warn', 'no system random source on this platform; the device id comes from a hash of time and process state')
  end
  local socket = engine('socket')
  local parts = {
    tostring(os.time()), tostring(os.clock()), tostring({}), tostring(collectgarbage('count')),
    socket and socket.gettime and tostring(socket.gettime()) or '', tostring(math.random()),
  }
  local out, counter = '', 0
  while #out < count * 2 do
    counter = counter + 1
    out = out .. toHex(Hmac.sha256(table.concat(parts, '|') .. '|' .. counter))
  end
  return out:sub(1, count * 2)
end

-- ----------------------------------------------------------------- storage

--- Files live in the game's save folder (sys.get_save_file). The core's
--- names may hold a slash; here they become flat file names. On the web,
--- sys.save and sys.load keep each file as a table, because they are the
--- calls the engine persists in the browser.
local function makeStorage(appId, web)
  local sys = engine('sys')
  local function path(name) return sys.get_save_file(appId, (name:gsub('/', '_'))) end
  if web then
    return {
      read = function(name)
        local ok, t = pcall(sys.load, path(name))
        if ok and type(t) == 'table' and type(t.text) == 'string' then return t.text end
        return nil
      end,
      write = function(name, text) pcall(sys.save, path(name), { text = text }) end,
      remove = function(name) pcall(sys.save, path(name), {}) end,
    }
  end
  local function writeFile(p, text)
    local f = io.open(p, 'wb')
    if not f then return false end
    local ok = f:write(text)
    f:close()
    return ok ~= nil
  end
  local function readFile(p)
    local f = io.open(p, 'rb')
    if not f then return nil end
    local text = f:read('*a')
    f:close()
    return text
  end
  return {
    read = function(name)
      local p = path(name)
      -- A replace interrupted between its two steps leaves only the
      -- temporary file, which holds the newer copy.
      return readFile(p) or readFile(p .. '.tmp')
    end,
    write = function(name, text) writeFile(path(name), text) end,
    remove = function(name)
      local p = path(name)
      os.remove(p)
      os.remove(p .. '.tmp')
    end,
    --- A temporary file renamed over the old one, so a partial write never
    --- replaces a good file. Where rename cannot replace (Windows), the old
    --- file is removed first; a read then finds the temporary copy.
    replace = function(name, text)
      local p = path(name)
      local tmp = p .. '.tmp'
      if not writeFile(tmp, text) then return writeFile(p, text) end
      if os.rename(tmp, p) then return true end
      os.remove(p)
      if os.rename(tmp, p) then return true end
      return writeFile(p, text)
    end,
  }
end

-- ----------------------------------------------------------------- network

local function lowerHeaders(headers)
  local out = {}
  for k, v in pairs(headers or {}) do out[tostring(k):lower()] = v end
  return out
end

local function send(req, callback)
  local http = engine('http')
  if not http then
    callback(0, '', {})
    return
  end
  local ok, err = pcall(http.request, req.url, req.method, function(_, _, response)
    local status = tonumber(response and response.status) or 0
    if status < 0 then status = 0 end
    callback(status, response and response.response or '', lowerHeaders(response and response.headers))
  end, req.headers, req.body, { timeout = req.timeout or config.timeout })
  if not ok then
    log('warn', 'request failed to start: ' .. tostring(err))
    callback(0, '', {})
  end
end

-- ---------------------------------------------------------------- playtest

--- From the environment, then from engine config, which a desktop build
--- takes on its command line: --config=ravensight.playtest_token=...
--- (Defold gives Lua no raw command line).
local function playtestContext()
  local sys = engine('sys')
  local function configValue(key)
    if not (sys and sys.get_config_string) then return nil end
    local ok, value = pcall(sys.get_config_string, 'ravensight.' .. key, '')
    if ok and value ~= '' then return value end
    return nil
  end
  local token = os.getenv('RAVENSIGHT_PLAYTEST_TOKEN') or configValue('playtest_token')
  if not token or token == '' then return nil end
  return {
    token = token,
    run_id = os.getenv('RAVENSIGHT_PLAYTEST_RUN_ID') or configValue('playtest_run_id') or '',
    job_id = os.getenv('RAVENSIGHT_PLAYTEST_JOB_ID') or configValue('playtest_job_id'),
    persona = os.getenv('RAVENSIGHT_PLAYTEST_PERSONA') or configValue('playtest_persona'),
  }
end

-- ------------------------------------------------------------ errors hooks

--- Feeds a Lua error to automatic capture. Installed with
--- sys.set_error_handler unless captureErrors = false; a game with its own
--- handler calls this from it instead.
function M.captureLuaError(source, message, traceback)
  if not core then return end
  local text = tostring(message or '')
  -- Never capture the SDK's own errors.
  if text:find('ravensight/', 1, true) == 1 then return end
  core:captureError({ source = 'uncaught', severity = 'error', message = text, stack = traceback, errorType = 'LuaError' })
end

--- Installs the hooks once the player may be tracked: never without a
--- key, never before consent (an opt_in game installs them at the yes),
--- never once the game's capture switch is known to be off. Defold keeps
--- one error handler and cannot hand back the engine's own, so a handler
--- installed earlier stays and does nothing while capture is off.
local installedCapture = false
local function installErrorCapture()
  if installedCapture or not core or not core.captureErrors or not core.trackingEnabled then return end
  if core.errorCapture and not core.errorCapture.enabled then return end
  installedCapture = true
  local sys = engine('sys')
  if sys and sys.set_error_handler then
    pcall(sys.set_error_handler, function(source, message, traceback) M.captureLuaError(source, message, traceback) end)
  end
  -- A native crash in the last run, from the engine's crash dump. Loading it
  -- deletes it, so it is read only while collecting.
  local crash = engine('crash')
  if crash and crash.load_previous then
    local ok, handle = pcall(crash.load_previous)
    if ok and handle then
      local signum = crash.get_signum and crash.get_signum(handle) or 0
      local frames = crash.get_backtrace and crash.get_backtrace(handle) or {}
      core:captureError({
        source = 'crash', severity = 'critical', errorType = 'signal ' .. tostring(signum),
        message = 'Native crash, signal ' .. tostring(signum),
        stack = type(frames) == 'table' and table.concat(frames, '\n') or nil,
      })
      pcall(crash.release, handle)
    end
  end
end

-- -------------------------------------------------------------- lifecycle

--- The window listener: on iOS and Android, losing focus is the move to
--- the background and gaining it is the return; on the desktop a focus
--- change is not an exit, and only flushes.
function M.window_event(event, data)
  if not core then return end
  local window = engine('window')
  if not window then return end
  if event == window.WINDOW_EVENT_FOCUS_LOST or event == window.WINDOW_EVENT_ICONIFIED then
    if core.mobile then core:enterBackground() else core:flush() end
  elseif event == window.WINDOW_EVENT_FOCUS_GAINED or event == window.WINDOW_EVENT_DEICONIFIED then
    if core.mobile then core:enterForeground() end
  end
end

local function appIdFrom(options, sys)
  if options.appId then return options.appId end
  local ok, title = pcall(sys.get_config_string, 'project.title', 'defold-game')
  local id = ok and title or 'defold-game'
  return (id:gsub('[^%w%-_ ]', ''))
end

--- Starts the SDK. Call once, from a script's init().
---   ingestKey      your game's publishable key. Missing or empty, the SDK
---                  is inert: no files, no network, every call a no-op.
---   apiUrl         default "https://api.ravensight.io", with or without /api/v1
---   gameVersion    default the project's project.version, else "1.0.0"
---   enabled        false sends and queues nothing this run (not saved)
---   consent        "opt_out" (default) or "opt_in"
---   maxQueueSize   default 500; flushInterval default 2 seconds
---   timeout        seconds per request, default 15
---   sessionTimeout seconds in the background before a return is a new
---                  session (iOS, Android), default 1800
---   captureErrors  automatic error capture, default true
---   windowListener install a window listener for focus and background,
---                  default true (call ravensight.window_event from yours
---                  when false)
---   distribution   a short label sent on the session
---   appId          the save folder name, default the project title
---   debug          print informational lines too
---   optional       true silences the one warning an inert start prints
function M.init(options)
  assert(type(options) == 'table', 'ravensight.init: pass a table of options')
  if initialized then
    log('warn', 'init() called twice; the second call is ignored')
    return
  end
  initialized = true
  local sys = engine('sys')
  local info = sysInfo()
  local platform, osName = platformNames(info)
  local versionOk, projectVersion = pcall(sys.get_config_string, 'project.version', '1.0.0')
  config = {
    apiUrl = options.apiUrl or 'https://api.ravensight.io',
    ingestKey = options.ingestKey or '',
    gameVersion = options.gameVersion or (versionOk and projectVersion) or '1.0.0',
    enabled = options.enabled ~= false,
    timeout = options.timeout or 15,
    debug = options.debug == true,
    consent = Core.normalizeConsent(options.consent),
    windowListener = options.windowListener ~= false,
  }
  config.storage = makeStorage(appIdFrom(options, sys), platform == 'Web')
  if not config.enabled then
    log('info', 'disabled by the enabled option; nothing is sent this run')
    return { sessionReady = false, reason = 'disabled' }
  end
  if config.ingestKey == '' then
    if not options.optional then
      log('warn', 'no ingestKey, so analytics is off for this run (pass optional = true to silence this line)')
    end
    return { sessionReady = false, reason = 'no_key' }
  end
  local zlib = engine('zlib')
  local socket = engine('socket')
  core = Core.new({
    apiUrl = config.apiUrl,
    ingestKey = config.ingestKey,
    gameVersion = config.gameVersion,
    maxQueueSize = options.maxQueueSize,
    flushInterval = options.flushInterval,
    send = function(req, callback)
      req.timeout = config.timeout
      send(req, callback)
    end,
    now = socket and socket.gettime or os.clock,
    time = os.time,
    storage = config.storage,
    randomHex = M._randomHex,
    platform = platform,
    osName = osName,
    log = log,
    playtest = playtestContext(),
    consent = config.consent,
    distribution = options.distribution,
    gzip = zlib and Gzip.over(zlib.deflate) or nil,
    device = deviceFields(info),
    mobile = platform == 'iOS' or platform == 'Android',
    sessionTimeout = options.sessionTimeout,
    captureErrors = options.captureErrors,
  })
  if socket and socket.gettime then
    -- socket.gettime is wall time with a fraction: a better event clock.
    core.timeMs = function() return math.floor(socket.gettime() * 1000) end
  end
  core:start()
  installErrorCapture()
  -- An opt_in game, or a yes after an opt-out, installs the hooks then.
  core:on('status_changed', function() installErrorCapture() end)
  local window = engine('window')
  if config.windowListener and window and window.set_listener then
    pcall(window.set_listener, function(_, event, data) M.window_event(event, data) end)
  end
end

--- Runs the batching and retry timers. Call from a script's update().
function M.update()
  if not core then return end
  core:update()
  if quitCode ~= nil and core.quitReady and not exited then
    exited = true
    local sys = engine('sys')
    if sys and sys.exit then sys.exit(quitCode) end
  end
end

--- Quits the game after the last events are sent or 1.5 seconds pass.
--- Use it in place of sys.exit(code).
function M.quit(code)
  code = code or 0
  local sys = engine('sys')
  if not core then
    if sys and sys.exit then sys.exit(code) end
    return
  end
  quitCode = code
  if not core:beginQuit() then
    exited = true
    if sys and sys.exit then sys.exit(code) end
  end
end

--- Call from final(): records game_exited if quit() did not, and saves the
--- queue, so what could not be sent goes on the next launch.
function M.final()
  if not core or core.quitReady then return end
  core:beginQuit()
  core:finishQuit()
end

-- ------------------------------------------------------------- the events

function M.track(name, data) if core then core:track(name, data) end end

function M.purchase(amount, currency, itemType, itemId, opts)
  local name, props = Typed.purchase(amount, currency, itemType, itemId, opts)
  return M.track(name, props)
end

function M.resource(flow, resource, amount, opts)
  local name, props = Typed.resource(flow, resource, amount, opts)
  return M.track(name, props)
end

function M.progression(status, p1, opts)
  local name, props = Typed.progression(status, p1, opts)
  return M.track(name, props)
end

--- An error the game reports itself. severity: debug, info, warning,
--- error or critical. opts: stack, errorType, name, props.
function M.trackError(severity, message, opts)
  if not core then return false end
  return core:trackError(severity, message, opts)
end

function M.trackAd(network, format, result, opts)
  local name, props = Typed.ad(network, format, result, opts)
  if not name then
    log('warn', 'ad event not sent: ' .. props)
    return false, props
  end
  M.track(name, props)
  return true
end

function M.trackAdRevenue(network, format, placement, revenueMicros, currency, opts)
  local merged = {}
  for k, v in pairs(opts or {}) do merged[k] = v end
  merged.placement, merged.revenueMicros, merged.currency = placement, revenueMicros, currency
  return M.trackAd(network, format, 'shown', merged)
end

M.microsFromDecimalString = Typed.microsFromDecimalString
M.microsFromRevenue = Typed.microsFromRevenue

function M.setAttribution(attribution)
  if not core then return false, 'not_started' end
  return core:setAttribution(attribution)
end

function M.fetchConfig() return core and core:fetchConfig() or false end
function M.getConfig(key, fallback)
  if not core then return fallback end
  return core:getConfig(key, fallback)
end

function M.flush() if core then core:flush() end end

function M.submitFeedback(message, category, rating)
  if not core then return false, 'disabled' end
  return core:submitFeedback(message, category, rating)
end

-- ----------------------------------------------------------------- privacy

--- The player's choice, saved at once. Callable before init() (it writes
--- storage with the default save folder) and after init({ enabled = false }).
function M.setTrackingEnabled(enabled)
  if core then
    core:setTrackingEnabled(enabled)
  elseif config then
    Core.saveChoice(config.storage, config.consent, enabled and true or false)
  else
    local sys = engine('sys')
    Core.saveChoice(makeStorage(appIdFrom({}, sys), platformNames(sysInfo()) == 'Web'), Core.CONSENT_OPT_OUT, enabled and true or false)
  end
end

function M.isTrackingEnabled()
  if core then return core:isTrackingEnabled() end
  return config ~= nil and Core.savedChoice(config.storage, config.consent)
end

--- True only while the SDK is collecting.
function M.enabled() return core ~= nil and core:isTrackingEnabled() == true end

function M.resetDeviceId()
  if not core then return nil end
  core:resetDeviceId()
  return core.deviceId
end

function M.getDeviceId() return core and core.deviceId or nil end
--- The open session's token, for a game server's joinToken; '' until one opens.
function M.getSessionToken() return core and core.sessionToken or '' end
function M.isPlaytest() return core ~= nil and core.playtestToken ~= '' end
--- disabled, invalid_key, tracking_disabled, offline, rate_limited,
--- session_failed, playtest_job_closed, or nil when ready.
function M.getStatusReason()
  if not core then return 'disabled' end
  return core:getStatusReason()
end
function M.apiBase() return core and (core.apiUrl .. '/api/v1') or (Core.normalizeApiUrl(config and config.apiUrl or 'https://api.ravensight.io') .. '/api/v1') end
function M.getDeliveryStats() return core and core:getDeliveryStats() or {} end
function M.setPlaytestContext(ctx) if core then core:setPlaytestContext(ctx) end end

--- Subscribe to an SDK event; returns a function that unsubscribes. Events:
--- session_ready, session_failed(reason), status_changed(reason),
--- tracking_disabled(source), events_flushed(count), flush_failed(reason),
--- feedback_submitted, feedback_failed(reason), event_tracked(name, data),
--- config_ready(source).
function M.on(name, fn)
  if not core then return function() end end
  return core:on(name, fn)
end

--- For the tests only: forget everything so init() can run again.
function M._reset()
  core, config, initialized, quitCode, exited = nil, nil, false, nil, false
  installedCapture = false
end
function M._core() return core end

return M
