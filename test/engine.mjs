// Runs the SDK inside the real Defold engine (dmengine_headless) against a
// local mock of the Ravensight API, and checks what arrived on the wire:
// the settings check, a session that names the SDK, a 429 whose
// Retry-After the engine's HTTP client let the SDK read, gzip bodies the
// server can decode, valid HMAC-SHA256 signatures, and every event.
//
//   node test/engine.mjs <path to bob.jar> <path to dmengine_headless> [java]
//
// The engine also runs every pure spec under its own Lua first.
import { createServer } from 'node:http';
import { gunzipSync } from 'node:zlib';
import { createHmac } from 'node:crypto';
import { spawn, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const [bob, engine, java = 'java'] = process.argv.slice(2);
if (!bob || !engine) {
  console.error('usage: node test/engine.mjs <bob.jar> <dmengine_headless> [java]');
  process.exit(2);
}
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const SECRET = 'engine-test-secret-0123456789abcdefghijklmnopq';
const seen = { settings: [], sessions: [], batches: [], badSignatures: 0 };
let sessionCalls = 0;

const server = createServer((req, res) => {
  const chunks = [];
  req.on('data', c => chunks.push(c));
  req.on('end', () => {
    let raw = Buffer.concat(chunks);
    const encoding = req.headers['content-encoding'];
    if (encoding === 'gzip') raw = gunzipSync(raw);
    const text = raw.toString('utf8');
    const reply = (status, body, headers = {}) => {
      res.writeHead(status, { 'Content-Type': 'application/json', ...headers });
      res.end(JSON.stringify(body));
    };
    if (req.method === 'GET' && req.url.startsWith('/api/v1/settings')) {
      seen.settings.push(req.headers);
      return reply(200, { trackingEnabled: true, errorCapture: { enabled: true, trail: false } });
    }
    if (req.url.startsWith('/api/v1/ingest/config')) return reply(404, { error: 'not_found' });
    if (req.method === 'POST' && req.url === '/api/v1/session') {
      sessionCalls += 1;
      seen.sessions.push(JSON.parse(text));
      if (sessionCalls === 1) return reply(429, { error: 'rate_limited' }, { 'Retry-After': '1' });
      return reply(201, {
        token: 'engine-session', expiresIn: 3600,
        origin: { session: 'ses_engine', build: '0.1.0', platform: 'macOS', stamp: 'o1.x.y' },
        signing: { algorithm: 'HMAC-SHA256', version: 1, secret: SECRET, serverTime: Math.floor(Date.now() / 1000) },
        errorCapture: { enabled: true, trail: false },
      });
    }
    if (req.method === 'POST' && req.url === '/api/v1/track/batch') {
      const t = req.headers['x-ravensight-timestamp'];
      const sig = req.headers['x-ravensight-signature'];
      const expected = 'v1=' + createHmac('sha256', SECRET).update(`v1:${t}:${text}`).digest('hex');
      if (sig !== expected) seen.badSignatures += 1;
      const body = JSON.parse(text);
      seen.batches.push({ encoding, token: req.headers['x-session-token'], events: body.events });
      return reply(202, { accepted: body.events.length });
    }
    reply(404, { error: 'unknown' });
  });
});

const fail = [];
const check = (ok, what) => { console.log(`${ok ? 'ok  ' : 'FAIL'} ${what}`); if (!ok) fail.push(what); };

await new Promise(resolve => server.listen(0, process.env.ENGINE_API_HOST ? "0.0.0.0" : "127.0.0.1", resolve));
const port = server.address().port;

const build = spawnSync(java, ['-jar', bob, '--root', root, '--settings', path.join(root, 'test/engine.settings'),
  '--output', 'build/engine', 'build'], { cwd: root, encoding: 'utf8' });
check(build.status === 0, 'bob built the test project');
if (build.status !== 0) { console.log(build.stdout, build.stderr); process.exit(1); }

const run = spawn(engine, [`--config=ravensight_test.api_url=http://${process.env.ENGINE_API_HOST || "127.0.0.1"}:${port}`, 'build/engine/game.projectc'], { cwd: root, stdio: ['ignore', 'pipe', 'pipe'] });
let output = '';
run.stdout.on('data', d => { output += d; });
run.stderr.on('data', d => { output += d; });
const killer = setTimeout(() => run.kill("SIGKILL"), 120000);
const code = await new Promise(resolve => run.on('exit', resolve));
clearTimeout(killer);
server.close();

const lines = output.split('\n').filter(l => process.env.ENGINE_VERBOSE ? !l.includes('DLIB') : l.includes('ENGINE_TEST'));
console.log(lines.join('\n'));
const specs = /ENGINE_TEST specs (\d+) passed, (\d+) failed/.exec(output);
check(specs && Number(specs[2]) === 0 && Number(specs[1]) > 0, `the pure specs pass inside the engine (${specs ? specs[1] : 0})`);
check(code === 0, `the engine exited 0 through ravensight.quit (got ${code})`);
check(seen.settings.length >= 1 && seen.settings[0]['x-api-key'] === 'gt_pub_enginetest', 'settings carried X-API-Key');
check(seen.sessions[0] && seen.sessions[0].sdk === 'defold/0.1.0', 'the session names defold/0.1.0');
const retry = /ENGINE_TEST retry_wait ([\d.]+)/.exec(output);
check(retry && Math.abs(Number(retry[1]) - 1) < 0.05, 'a 429 Retry-After header reached the SDK through the engine HTTP client');
const events = seen.batches.flatMap(b => b.events);
const names = events.map(e => e.event);
check(names.filter(n => n === 'engine_event').length === 40, 'all 40 tracked events arrived');
check(names.includes('game_started') && names.includes('game_exited'), 'game_started and game_exited arrived');
check(events.some(e => e.data.rs_kind === 'error' && e.data.rs_severity === 'warning'), 'the manual error arrived');
check(seen.batches.some(b => b.encoding === 'gzip'), 'a large batch was sent gzip compressed and decoded');
check(seen.badSignatures === 0 && seen.batches.length > 0, `every batch had a valid signature (${seen.batches.length} batches)`);
check(new Set(events.map(e => e.data.rs_event_id)).size === events.length, 'every event has a unique rs_event_id');
check(events.every(e => e.timestamp > 1e12), 'timestamps are unix milliseconds');

console.log(fail.length ? `${fail.length} check(s) failed` : 'all engine checks passed');
process.exit(fail.length ? 1 : 0);
