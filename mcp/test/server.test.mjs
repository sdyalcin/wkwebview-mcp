// Runs the MCP server against a fake app, checking the MCP plumbing and the tool formatting
// without needing a simulator. The Swift side is covered by `swift test`.
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { createInterface } from 'node:readline';
import { after, before, test } from 'node:test';

const PORT = 19400;
let app;
let mcp;
let nextId = 1;
const pending = new Map();
const requests = [];

const routes = {
  'GET /info': () => ({
    ok: true, server: 'wkwebview-mcp', version: '0.1.0', port: PORT,
    app: { bundleId: 'dev.example.app', name: 'Example', pid: 1 },
    device: { simulator: true, name: 'iPhone 17', systemVersion: '27.2', udid: 'UDID' },
    webViews: [{ id: 'wv1', name: 'demo', url: 'https://example.com/', title: 'Example', visible: true }],
  }),
  'GET /console': () => ({
    ok: true, matched: 2, lastSeq: 2, entries: [
      { seq: 1, time: 0, level: 'log', message: 'hello' },
      { seq: 2, time: 0, level: 'error', kind: 'exception', message: 'boom', source: 'app.js:1:2', stack: 'f@app.js:1:2' },
    ],
  }),
  'GET /network': () => ({
    ok: true, matched: 1, requests: [{ seq: 1, id: 'a-1', method: 'GET', status: 404, duration: 12, kind: 'fetch', url: 'https://api.example.com/x', state: 'finished' }],
  }),
  'POST /eval': (body) => (body.code === 'boom'
    ? { ok: false, error: 'ReferenceError: boom is not defined', line: 1 }
    : { ok: true, type: 'string', value: `ran: ${body.code}`, durationMs: 1 }),
};

before(async () => {
  app = createServer((req, res) => {
    let raw = '';
    req.on('data', (chunk) => { raw += chunk; });
    req.on('end', () => {
      const path = req.url.split('?')[0];
      const body = raw ? JSON.parse(raw) : {};
      requests.push({ method: req.method, url: req.url, body });
      const route = routes[`${req.method} ${path}`];
      res.setHeader('content-type', 'application/json');
      res.statusCode = route ? 200 : 404;
      res.end(JSON.stringify(route ? route(body) : { ok: false, error: 'no route' }));
    });
  });
  await new Promise((resolve) => app.listen(PORT, '127.0.0.1', resolve));

  mcp = spawn(process.execPath, [new URL('../server.mjs', import.meta.url).pathname], {
    env: { ...process.env, WKWEBVIEW_MCP_PORT: String(PORT), WKWEBVIEW_MCP_PORT_RANGE: '2' },
    stdio: ['pipe', 'pipe', 'inherit'],
  });
  createInterface({ input: mcp.stdout }).on('line', (line) => {
    const message = JSON.parse(line);
    pending.get(message.id)?.(message);
  });
});

after(() => {
  mcp.kill();
  app.close();
});

function rpc(method, params) {
  const id = nextId++;
  return new Promise((resolve) => {
    pending.set(id, resolve);
    mcp.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n');
  });
}

const callTool = async (name, args = {}) => (await rpc('tools/call', { name, arguments: args })).result;

test('initialize negotiates the protocol version', async () => {
  const response = await rpc('initialize', { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'test', version: '1' } });
  assert.equal(response.result.protocolVersion, '2025-06-18');
  assert.equal(response.result.serverInfo.name, 'wkwebview-mcp');
  mcp.stdin.write(JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' }) + '\n');
});

test('lists tools with schemas', async () => {
  const { result } = await rpc('tools/list');
  const names = result.tools.map((tool) => tool.name);
  for (const name of ['list_apps', 'evaluate_javascript', 'console_messages', 'list_network_requests', 'screenshot', 'click', 'fill']) {
    assert.ok(names.includes(name), name);
  }
  assert.ok(result.tools.every((tool) => tool.inputSchema.type === 'object'));
});

test('list_apps finds the app', async () => {
  const result = await callTool('list_apps');
  assert.match(result.content[0].text, /Example on iPhone 17 \(iOS 27\.2\), port 19400/);
  assert.match(result.content[0].text, /wv1 \(demo\): Example — https:\/\/example\.com\//);
});

test('console_messages formats entries and passes filters', async () => {
  const result = await callTool('console_messages', { level: ['error', 'warn'], limit: 5 });
  assert.match(result.content[0].text, /#2 .* ERROR boom {2}\[exception\]/);
  assert.match(result.content[0].text, /at app\.js:1:2/);
  const sent = requests.findLast((r) => r.url.startsWith('/console'));
  assert.match(sent.url, /level=error%2Cwarn/);
  assert.match(sent.url, /limit=5/);
});

test('list_network_requests shows status and id', async () => {
  const result = await callTool('list_network_requests', { failed_only: true });
  assert.match(result.content[0].text, /#1 \[a-1\] GET +404 +12ms +fetch +https:\/\/api\.example\.com\/x/);
  assert.match(requests.findLast((r) => r.url.startsWith('/network')).url, /failed=true/);
});

test('evaluate_javascript returns the value and reports exceptions as tool errors', async () => {
  const ok = await callTool('evaluate_javascript', { code: 'document.title', webview: 'demo' });
  assert.match(ok.content[0].text, /^ran: document\.title/);
  assert.equal(requests.findLast((r) => r.url === '/eval').body.webview, 'demo');

  const failed = await callTool('evaluate_javascript', { code: 'boom' });
  assert.equal(failed.isError, true);
  assert.match(failed.content[0].text, /ReferenceError: boom is not defined \(line 1\)/);
});

test('unknown tools and methods are JSON-RPC errors', async () => {
  assert.equal((await rpc('tools/call', { name: 'nope' })).error.code, -32602);
  assert.equal((await rpc('nope/nope')).error.code, -32601);
});

test('a missing app is a helpful tool error', async () => {
  const result = await callTool('console_messages', { app: 19999 });
  assert.equal(result.isError, true);
  assert.match(result.content[0].text, /Could not reach the app/);
});
