-- The Defold adapter (ravensight/ravensight.lua) over stand-ins for the
-- engine's http, sys, window and zlib modules, and the gzip wrapper.
local Gzip = require('ravensight.gzip')
local Core = require('ravensight.core')
local json = require('ravensight.json')

local function eq(a, b, msg) assert(a == b, (msg or '') .. ' expected ' .. tostring(b) .. ', got ' .. tostring(a)) end

local tmpRoot = os.tmpname()
os.remove(tmpRoot)
os.execute('mkdir -p "' .. tmpRoot .. '"')

--- A zlib stream with one stored block: valid RFC 1950 without a deflater.
local function storedZlib(text)
  assert(#text < 65536)
  local a, b = 1, 0
  for i = 1, #text do a = (a + text:byte(i)) % 65521; b = (b + a) % 65521 end
  local len = #text
  local nlen = 65535 - len
  local adler = b * 65536 + a
  return '\120\1' .. '\1' .. string.char(len % 256, math.floor(len / 256), nlen % 256, math.floor(nlen / 256)) .. text
    .. string.char(math.floor(adler / 16777216) % 256, math.floor(adler / 65536) % 256, math.floor(adler / 256) % 256, adler % 256)
end

local function gunzipWithPython(data)
  local path = tmpRoot .. '/body.gz'
  local f = assert(io.open(path, 'wb')); f:write(data); f:close()
  local p = io.popen('python3 -c "import gzip,sys;sys.stdout.write(gzip.decompress(open(sys.argv[1],\'rb\').read()).decode())" "' .. path .. '" 2>/dev/null')
  local out = p:read('*a'); p:close()
  return out
end

-- The engine's own modules, put back after each test (the specs also run
-- inside the real engine).
local saved = { http = rawget(_G, 'http'), sys = rawget(_G, 'sys'), window = rawget(_G, 'window'), zlib = rawget(_G, 'zlib'), crash = rawget(_G, 'crash') }

local function fakeEngine(opts)
  opts = opts or {}
  local e = { requests = {}, exits = {}, listener = nil, errorHandler = nil, dir = tmpRoot .. '/' .. tostring(math.random(1e9)) }
  os.execute('mkdir -p "' .. e.dir .. '"')
  _G.http = {
    request = function(url, method, cb, headers, body, options)
      if url:find('/ingest/config?', 1, true) then cb(nil, 'id', { status = 404, response = '{}' }) return end
      table.insert(e.requests, { url = url, method = method, cb = cb, headers = headers, body = body, options = options })
    end,
  }
  _G.sys = {
    get_sys_info = function() return { system_name = opts.system or 'Darwin', system_version = '15.1', device_model = opts.model } end,
    get_config_string = function(key, default)
      if opts.config and opts.config[key] then return opts.config[key] end
      if key == 'project.title' then return 'My Game!' end
      return default
    end,
    get_save_file = function(app, file) return e.dir .. '/' .. app .. '-' .. file end,
    exit = function(code) table.insert(e.exits, code) end,
    set_error_handler = function(fn) e.errorHandler = fn end,
  }
  _G.window = {
    WINDOW_EVENT_FOCUS_LOST = 1, WINDOW_EVENT_FOCUS_GAINED = 2, WINDOW_EVENT_ICONIFIED = 3, WINDOW_EVENT_DEICONIFIED = 4,
    set_listener = function(fn) e.listener = fn end,
  }
  _G.zlib = { deflate = storedZlib }
  _G.crash = opts.crash
  package.loaded['ravensight.ravensight'] = nil
  e.rs = require('ravensight.ravensight')
  e.rs._reset()
  function e.answer(path, status, body, headers)
    local r = table.remove(e.requests, 1)
    assert(r, 'expected a request to ' .. path)
    assert(r.url:find(path, 1, true), 'expected ' .. path .. ', got ' .. r.url)
    r.cb(nil, 'id', { status = status, response = body and json.encode(body) or '', headers = headers })
    return r
  end
  function e.file(name)
    local f = io.open(e.dir .. '/My Game-' .. name, 'rb')
    if not f then return nil end
    local t = f:read('*a'); f:close(); return t
  end
  return e
end

local function cleanup()
  for k, v in pairs(saved) do _G[k] = v end
  package.loaded['ravensight.ravensight'] = nil
end

return {
  { 'crc32 matches the IEEE check value', function()
    eq(Gzip.crc32('123456789'), 0xCBF43926)
    eq(Gzip.crc32(''), 0)
  end },
  { 'a zlib stream becomes a gzip stream that a standard reader decodes', function()
    local text = string.rep('{"event":"pickup"},', 80)
    local gz = Gzip.fromZlib(storedZlib(text), text)
    eq(gz:sub(1, 3), '\31\139\8')
    eq(gunzipWithPython(gz), text)
    eq(Gzip.fromZlib('xx', text), nil)
    eq(Gzip.fromZlib('\120\32abcdef', text), nil, 'a preset dictionary is refused')
  end },
  { 'no key: inert, no files and no requests', function()
    local e = fakeEngine()
    local result = e.rs.init({ optional = true })
    eq(result.reason, 'no_key')
    e.rs.track('x', {})
    eq(#e.requests, 0)
    eq(e.rs.getStatusReason(), 'disabled')
    cleanup()
  end },
  { 'enabled = false: zero requests, and the saved choice still works', function()
    local e = fakeEngine()
    e.rs.init({ ingestKey = 'gt_live_k', enabled = false })
    e.rs.track('x', {})
    e.rs.flush()
    eq(#e.requests, 0)
    e.rs.setTrackingEnabled(false)
    eq(e.file('ravensight_optout'), '1')
    cleanup()
  end },
  { 'a saved opt-out makes zero requests across a new start', function()
    local e = fakeEngine()
    e.rs.setTrackingEnabled(false)
    e.rs.init({ ingestKey = 'gt_live_k' })
    e.rs.track('x', {})
    e.rs.update()
    eq(#e.requests, 0)
    eq(e.rs.isTrackingEnabled(), false)
    cleanup()
  end },
  { 'init: settings, session with device fields, a gzip batch signed when the session signs', function()
    local e = fakeEngine({ system = 'Android', model = 'Pixel 7' })
    e.rs.init({ ingestKey = 'gt_pub_k', apiUrl = 'https://api.test/api/v1/' })
    local settings = e.answer('/api/v1/settings', 200, { trackingEnabled = true })
    eq(settings.url, 'https://api.test/api/v1/settings')
    eq(settings.headers['X-API-Key'], 'gt_pub_k')
    eq(settings.options.timeout, 15)
    local session = e.answer('/api/v1/session', 201, {
      token = 'tok', expiresIn = 3600,
      signing = { algorithm = 'HMAC-SHA256', version = 1, secret = 's3cret', serverTime = os.time() },
    })
    local body = json.decode(session.body)
    eq(body.platform, 'Android')
    eq(body.device.model, 'Pixel 7')
    eq(body.device.osVersion, '15.1')
    eq(body.device.gpu, nil)
    assert(body.deviceId:match('^%x+%-android$'), body.deviceId)
    eq(#body.deviceId, 32 + 1 + 7)
    e.answer('/track/batch', 202, { accepted = 1 })
    for i = 1, 60 do e.rs.track('pickup', { n = i, pad = string.rep('z', 30) }) end
    local batch = table.remove(e.requests, 1)
    assert(batch.url:find('/track/batch', 1, true))
    eq(batch.headers['Content-Encoding'], 'gzip')
    assert(batch.headers['X-Ravensight-Signature']:match('^v1=%x+$'))
    local plain = gunzipWithPython(batch.body)
    eq(#json.decode(plain).events, 50, 'a batch of at most 50')
    cleanup()
  end },
  { 'response headers are read in lower case, so Retry-After is obeyed', function()
    local e = fakeEngine()
    e.rs.init({ ingestKey = 'gt_live_k' })
    e.answer('/api/v1/settings', 200, { trackingEnabled = true })
    e.answer('/api/v1/session', 429, { error = 'rate_limited' }, { ['Retry-After'] = '42' })
    local core = e.rs._core()
    assert(core.retryAt > 41 + core.now() - 1, 'waits 42 seconds')
    eq(e.rs.getStatusReason(), 'rate_limited')
    cleanup()
  end },
  { 'a network failure (status 0 or below) is offline', function()
    local e = fakeEngine()
    e.rs.init({ ingestKey = 'gt_live_k' })
    e.answer('/api/v1/settings', 200, { trackingEnabled = true })
    e.answer('/api/v1/session', -1, nil)
    eq(e.rs.getStatusReason(), 'offline')
    cleanup()
  end },
  { 'files: the device id and the queue live in the save folder, written atomically', function()
    local e = fakeEngine()
    e.rs.init({ ingestKey = 'gt_live_k' })
    e.rs.update()
    assert(e.file('ravensight_device_id'):match('^%x+%-macos$'))
    local queue = e.file('ravensight_queue-' .. Core.fnv1a64('gt_live_k') .. '.json')
    assert(queue and json.decode(queue).version == 2, 'the queue file, version 2')
    eq(e.file('ravensight_queue-' .. Core.fnv1a64('gt_live_k') .. '.json.tmp'), nil, 'no temporary file left behind')
    cleanup()
  end },
  { 'quit(): game_exited, a flush, and sys.exit once the batch is answered', function()
    local e = fakeEngine()
    e.rs.init({ ingestKey = 'gt_live_k' })
    e.answer('/api/v1/settings', 200, { trackingEnabled = true })
    e.answer('/api/v1/session', 201, { token = 'tok', expiresIn = 3600 })
    e.answer('/api/v1/track/batch', 202, { accepted = 1 })
    e.rs.quit(3)
    eq(#e.exits, 0, 'held for the flush')
    local batch = e.answer('/api/v1/track/batch', 202, { accepted = 1 })
    eq(json.decode(batch.body).events[1].event, 'game_exited')
    e.rs.update()
    eq(e.exits[1], 3)
    cleanup()
  end },
  { 'final(): game_exited is saved for the next launch', function()
    local e = fakeEngine()
    e.rs.init({ ingestKey = 'gt_live_k' })
    e.rs.final()
    local queue = json.decode(e.file('ravensight_queue-' .. Core.fnv1a64('gt_live_k') .. '.json'))
    local names = {}
    for _, g in ipairs(queue.groups) do for _, ev in ipairs(g.events) do names[#names + 1] = ev.event end end
    eq(table.concat(names, ','), 'game_started,game_exited')
    cleanup()
  end },
  { 'window: on Android, focus lost is the background and writes the marker', function()
    local e = fakeEngine({ system = 'Android' })
    e.rs.init({ ingestKey = 'gt_live_k' })
    e.answer('/api/v1/settings', 200, { trackingEnabled = true })
    e.answer('/api/v1/session', 201, { token = 'tok', expiresIn = 3600 })
    e.answer('/api/v1/track/batch', 202, { accepted = 1 })
    e.listener(nil, window.WINDOW_EVENT_FOCUS_LOST, {})
    assert(e.file('ravensight_background.json'), 'marker written')
    e.listener(nil, window.WINDOW_EVENT_FOCUS_GAINED, {})
    eq(e.file('ravensight_background.json'), nil)
    cleanup()
  end },
  { 'errors: the Lua error handler feeds capture; the SDK skips its own errors', function()
    local e = fakeEngine()
    e.rs.init({ ingestKey = 'gt_live_k' })
    e.answer('/api/v1/settings', 200, { trackingEnabled = true })
    e.answer('/api/v1/session', 201, { token = 'tok', expiresIn = 3600, errorCapture = { enabled = true, trail = false } })
    e.errorHandler('lua', 'main/player.script:12: attempt to index nil', 'stack traceback:\n  main/player.script:12: in function update')
    e.errorHandler('lua', 'ravensight/core.lua:5: own error', '')
    local core = e.rs._core()
    local errors = {}
    for _, ev in ipairs(core.pending) do if ev.data.rs_kind == 'error' then errors[#errors + 1] = ev.data end end
    eq(#errors, 1)
    eq(errors[1].rs_source, 'uncaught')
    eq(errors[1].rs_error_type, 'LuaError')
    cleanup()
  end },
  { 'errors: a crash dump from the last run is reported once, as critical', function()
    local released = 0
    local crash = {
      load_previous = function() return 7 end,
      get_signum = function() return 11 end,
      get_backtrace = function() return { '0x1000', '0x2000' } end,
      release = function() released = released + 1 end,
    }
    local e = fakeEngine({ crash = crash })
    e.rs.init({ ingestKey = 'gt_live_k' })
    eq(released, 1)
    e.answer('/api/v1/settings', 200, { trackingEnabled = true })
    e.answer('/api/v1/session', 201, { token = 'tok', expiresIn = 3600, errorCapture = { enabled = true } })
    local found
    for _, ev in ipairs(e.rs._core().pending) do if ev.data.rs_source == 'crash' then found = ev.data end end
    assert(found, 'the crash was queued')
    eq(found.rs_severity, 'critical')
    eq(found.rs_message, 'Native crash, signal 11')
    cleanup()
  end },
  { 'playtest from engine config: the bare token and a pt- id', function()
    local e = fakeEngine({ config = { ['ravensight.playtest_token'] = 'ptk', ['ravensight.playtest_run_id'] = 'r9' } })
    e.rs.init({ ingestKey = 'gt_live_k' })
    eq(e.rs.isPlaytest(), true)
    eq(e.rs.getDeviceId(), 'pt-r9')
    e.answer('/api/v1/settings', 200, { trackingEnabled = true })
    local session = e.answer('/api/v1/session', 201, { token = 'tok', expiresIn = 3600 })
    eq(session.headers['X-Ravensight-Playtest'], 'ptk')
    eq(e.file('ravensight_device_id'), nil)
    cleanup()
  end },
  { 'random hex from the system source has the asked length', function()
    local rs = require('ravensight.ravensight')
    local a, b = rs._randomHex(16), rs._randomHex(16)
    eq(#a, 32)
    assert(a ~= b)
  end },
  { 'session token is exposed for hand-off, empty until a session opens', function()
    local e = fakeEngine()
    e.rs.init({ ingestKey = 'gt_live_k' })
    eq(e.rs.getSessionToken(), '')
    e.answer('/api/v1/settings', 200, { trackingEnabled = true })
    e.answer('/api/v1/session', 201, { token = 'tok', expiresIn = 3600 })
    eq(e.rs.getSessionToken(), 'tok')
    eq(e.rs.apiBase(), 'https://api.ravensight.io/api/v1')
    cleanup()
  end },
  { 'queue rule 3: opt-out and a reset delete persisted captures, pending records and any .tmp file', function()
    for _, action in ipairs({ 'optout', 'reset' }) do
      local e = fakeEngine()
      e.rs.init({ ingestKey = 'gt_live_k' })
      e.answer('/api/v1/settings', 200, { trackingEnabled = true })
      e.answer('/api/v1/session', 201, { token = 'tok', expiresIn = 3600, errorCapture = { enabled = true } })
      e.rs.captureLuaError('lua', 'main.script:1: boom', '')
      e.rs.update()
      local queue = 'ravensight_queue-' .. Core.fnv1a64('gt_live_k') .. '.json'
      assert(e.file(queue):find('"rs_source":"uncaught"', 1, true), 'the capture was persisted')
      for _, name in ipairs({ queue .. '.tmp', 'ravensight_pending-errors.json', 'ravensight_pending-errors.json.tmp' }) do
        local f = assert(io.open(e.dir .. '/My Game-' .. name, 'wb')); f:write('x'); f:close()
      end
      if action == 'optout' then e.rs.setTrackingEnabled(false) else e.rs.resetDeviceId() end
      for _, name in ipairs({ queue, queue .. '.tmp', 'ravensight_pending-errors.json', 'ravensight_pending-errors.json.tmp' }) do
        eq(e.file(name), nil, action .. ' deletes ' .. name)
      end
      cleanup()
    end
  end },
  { 'consent: no hook before the yes with opt_in; installed at the yes', function()
    local e = fakeEngine()
    e.rs.init({ ingestKey = 'gt_live_k', consent = 'opt_in' })
    eq(e.errorHandler, nil, 'nothing installed before consent')
    e.rs.setTrackingEnabled(true)
    assert(e.errorHandler, 'installed at the yes')
    cleanup()
  end },
}
