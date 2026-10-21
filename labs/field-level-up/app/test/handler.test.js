'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { EventEmitter } = require('node:events');
const { createHandler } = require('../handler');

const env = {
  POSTGRES_HOST: 'private.example.test', POSTGRES_PORT: '5432',
  POSTGRES_DATABASE: 'lab', POSTGRES_USER: 'lab-user',
  AZURE_CLIENT_ID: 'lab-uami-client-id',
};
const token = 'test-token-never-expose';
const secretError = new Error(`connect ECONNREFUSED postgresql://${env.POSTGRES_USER}:${token}@${env.POSTGRES_HOST}/lab`);

function fixture(options = {}) {
  const clients = [];
  const scopes = [];
  const requests = [];
  const dependencies = [];
  const telemetry = {
    trackRequest: (data) => requests.push(data),
    trackDependency: (data) => dependencies.push(data),
  };
  const handler = createHandler({
    env,
    telemetry,
    getAccessToken: async (scope) => {
      scopes.push(scope);
      return { token, expiresOnTimestamp: Date.now() + 60000 };
    },
    createClient: (config) => {
      const client = new EventEmitter();
      Object.assign(client, {
        config, closed: 0, destroyed: 0, queries: [],
        connect: async () => { assert.equal(await config.password(), token); },
        query: async (sql) => { client.queries.push(sql); return { rows: [{ '?column?': 1 }] }; },
        end: async () => { client.closed += 1; },
        connection: { stream: { destroy: () => { client.destroyed += 1; } } },
      }, options.client);
      clients.push(client);
      return client;
    },
    ...options.handler,
  });
  return { handler, clients, scopes, requests, dependencies, telemetry };
}

async function invoke(handler, method = 'POST', url = '/checkout') {
  const response = {
    headers: {},
    setHeader(name, value) { this.headers[name] = value; },
    writeHead(status, headers) { this.status = status; Object.assign(this.headers, headers); },
    end(body) { this.body = String(body); },
  };
  await handler({ method, url, resume() {} }, response);
  return response;
}

test('checkout succeeds with a fresh verified-TLS client, SELECT 1, cleanup and exact telemetry', async () => {
  const f = fixture();
  for (let i = 0; i < 2; i += 1) {
    const response = await invoke(f.handler);
    assert.equal(response.status, 200);
    assert.equal(JSON.parse(response.body).simulated, true);
    assert.equal(JSON.parse(response.body).success, true);
  }
  assert.equal(f.clients.length, 2);
  assert.notEqual(f.clients[0], f.clients[1]);
  for (const client of f.clients) {
    assert.deepEqual(client.queries, ['SELECT 1']);
    assert.equal(client.closed, 1);
    assert.equal(client.destroyed, 1);
    assert.deepEqual(client.config.ssl, { rejectUnauthorized: true });
    assert.equal(client.config.connectionTimeoutMillis, 5000);
    assert.equal(client.config.query_timeout, 5000);
    assert.equal(client.config.statement_timeout, 5000);
    assert.equal(client.config.host, env.POSTGRES_HOST);
    assert.equal(typeof client.config.password, 'function');
  }
  assert.deepEqual(f.scopes, Array(2).fill('https://ossrdbms-aad.database.windows.net/.default'));
  assert.equal(JSON.stringify({ requests: f.requests, dependencies: f.dependencies }).includes(token), false);
  for (const request of f.requests) {
    assert.equal(request.name, 'POST /checkout');
    assert.equal(request.success, true);
    assert.equal(request.resultCode, '200');
    assert.ok(request.duration >= 0);
  }
  assert.equal(f.dependencies.length, 2);
  assert.equal(f.dependencies[0].dependencyTypeName, 'PostgreSQL');
  assert.equal(f.dependencies[0].success, true);
  assert.ok(f.dependencies[0].duration >= 0);
});

for (const phase of ['connect', 'query']) {
  test(`${phase} failure returns sanitized 503, closes client and leaves health available`, async () => {
    const f = fixture({ client: { [phase]: async () => { throw secretError; } } });
    const response = await invoke(f.handler, 'POST', `/checkout?secret=${token}`);
    assert.equal(response.status, 503);
    assert.equal(JSON.parse(response.body).success, false);
    assert.equal(response.headers['Retry-After'], '3');
    assert.equal(f.clients[0].closed, 1);
    assert.equal(f.clients[0].destroyed, 1);
    assert.equal(f.requests[0].name, 'POST /checkout');
    assert.equal(f.requests[0].resultCode, '503');
    assert.equal(f.requests[0].success, false);
    assert.equal(f.dependencies[0].success, false);
    assert.ok(f.dependencies[0].duration >= 0);
    const output = JSON.stringify({ response, requests: f.requests, dependencies: f.dependencies });
    for (const secret of [token, env.POSTGRES_USER, env.POSTGRES_HOST, 'ECONNREFUSED', 'postgresql://']) {
      assert.equal(output.includes(secret), false);
    }
    const health = await invoke(f.handler, 'GET', '/healthz');
    assert.equal(health.status, 200);
    assert.equal(f.clients.length, 1);
  });
}

test('missing configuration affects only checkout; health and assets work without a DB', async () => {
  const f = fixture({ handler: { env: {} } });
  assert.equal((await invoke(f.handler, 'GET', '/healthz')).status, 200);
  assert.equal((await invoke(f.handler, 'GET', '/')).status, 200);
  assert.equal((await invoke(f.handler)).status, 503);
  assert.equal(f.clients.length, 0);
  assert.equal(f.requests[0].success, false);
});

for (const [name, getAccessToken] of [
  ['rejected', async () => { throw secretError; }],
  ['expired', async () => ({ token, expiresOnTimestamp: Date.now() - 1 })],
  ['missing', async () => null],
]) {
  test(`${name} credentials return sanitized 503 and clean up without querying or logging`, async (t) => {
    const logs = [];
    for (const method of ['log', 'info', 'warn', 'error', 'debug']) {
      t.mock.method(console, method, (...args) => logs.push(args));
    }
    const f = fixture({ handler: { getAccessToken } });
    const response = await invoke(f.handler);
    assert.equal(response.status, 503);
    assert.equal(response.headers['Retry-After'], '3');
    assert.deepEqual(f.clients[0].queries, []);
    assert.equal(f.clients[0].closed, 1);
    assert.equal(f.clients[0].destroyed, 1);
    assert.equal(f.requests[0].properties.outcome, 'unavailable');
    assert.equal(f.dependencies[0].success, false);
    assert.deepEqual(logs, []);
    const output = JSON.stringify({ response, requests: f.requests, dependencies: f.dependencies, logs });
    for (const secret of [token, env.POSTGRES_USER, env.POSTGRES_HOST, 'ECONNREFUSED', 'postgresql://']) {
      assert.equal(output.includes(secret), false);
    }
    assert.equal((await invoke(f.handler, 'GET', '/healthz')).status, 200);
  });
}

test('missing UAMI client id fails closed without creating a client or acquiring tokens', async () => {
  const f = fixture({ handler: { env: { ...env, AZURE_CLIENT_ID: '' } } });
  assert.equal((await invoke(f.handler)).status, 503);
  assert.equal(f.clients.length, 0);
  assert.deepEqual(f.scopes, []);
});

test('token acquisition is lazy and a hung credential shares the five-second deadline', async (t) => {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  let tokenCalls = 0;
  let rejectToken;
  const f = fixture({ handler: { getAccessToken: () => {
    tokenCalls += 1;
    return new Promise((_, reject) => { rejectToken = reject; });
  } } });
  assert.equal((await invoke(f.handler, 'GET', '/healthz')).status, 200);
  assert.equal((await invoke(f.handler, 'GET', '/')).status, 200);
  assert.equal(f.clients.length, 0);
  assert.equal(tokenCalls, 0);
  let completed = false;
  const pending = invoke(f.handler).then((response) => { completed = true; return response; });
  assert.equal(tokenCalls, 1);
  t.mock.timers.tick(4999);
  await Promise.resolve();
  assert.equal(completed, false);
  t.mock.timers.tick(1);
  const response = await pending;
  assert.equal(response.status, 503);
  assert.equal(f.requests[0].properties.outcome, 'timeout');
  assert.deepEqual(f.clients[0].queries, []);
  assert.equal(f.clients[0].closed, 1);
  assert.equal(f.clients[0].destroyed, 1);
  // A late SDK rejection remains handled after the request deadline.
  rejectToken(secretError);
  await Promise.resolve();
  assert.equal(JSON.stringify({ response, requests: f.requests, dependencies: f.dependencies }).includes(token), false);
});

test('token acquisition and query share a single total five-second budget', async (t) => {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  let resolveToken;
  let queryStarted;
  const querying = new Promise((resolve) => { queryStarted = resolve; });
  const f = fixture({
    handler: { getAccessToken: () => new Promise((resolve) => { resolveToken = resolve; }) },
    client: { query: () => { queryStarted(); return new Promise(() => {}); } },
  });
  const pending = invoke(f.handler);
  t.mock.timers.tick(4000);
  resolveToken({ token, expiresOnTimestamp: Date.now() + 60000 });
  await querying;
  t.mock.timers.tick(1000);
  assert.equal((await pending).status, 503);
  assert.equal(f.requests[0].properties.outcome, 'timeout');
  assert.equal(f.clients[0].closed, 1);
  assert.equal(f.clients[0].destroyed, 1);
});

for (const phase of ['connect', 'query']) {
  test(`${phase} hang is bounded by 5 seconds and destroyed`, async (t) => {
    t.mock.timers.enable({ apis: ['setTimeout'] });
    const f = fixture({ client: { [phase]: () => new Promise(() => {}) } });
    let completed = false;
    const pending = invoke(f.handler).then((result) => { completed = true; return result; });
    await Promise.resolve();
    t.mock.timers.tick(4999);
    await Promise.resolve();
    assert.equal(completed, false);
    t.mock.timers.tick(1);
    const response = await pending;
    assert.equal(response.status, 503);
    assert.equal(f.clients[0].destroyed, 1);
    assert.equal(f.clients[0].closed, 1);
    assert.equal(f.requests[0].properties.outcome, 'timeout');
  });
}

test('connection and query share one total 5-second budget', async (t) => {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  let connected;
  const f = fixture({ client: {
    connect: () => new Promise((resolve) => { connected = resolve; }),
    query: () => new Promise(() => {}),
  } });
  const pending = invoke(f.handler);
  t.mock.timers.tick(4000);
  connected();
  await Promise.resolve();
  t.mock.timers.tick(1000);
  assert.equal((await pending).status, 503);
  assert.equal(f.clients[0].destroyed, 1);
});

test('four-attempt limit rejects excess traffic; health works and slots recover', async () => {
  const release = [];
  const f = fixture({ client: { connect: () => new Promise((resolve) => release.push(resolve)) } });
  const pending = Array.from({ length: 4 }, () => invoke(f.handler));
  assert.equal((await invoke(f.handler)).status, 503);
  assert.equal(f.clients.length, 4);
  assert.equal(f.requests[0].properties.outcome, 'busy');
  assert.equal(f.dependencies.length, 0);
  assert.equal((await invoke(f.handler, 'GET', '/healthz')).status, 200);
  release.forEach((resolve) => resolve());
  assert.ok((await Promise.all(pending)).every((response) => response.status === 200));
  const next = invoke(f.handler);
  release[4]();
  assert.equal((await next).status, 200);
});

test('idle socket errors are sanitized and cleanup errors cannot expose credentials', async () => {
  const f = fixture({ client: { connect: () => new Promise(() => {}) } });
  const pending = invoke(f.handler);
  f.clients[0].emit('error', secretError);
  const response = await pending;
  assert.equal(response.status, 503);
  assert.equal(f.clients[0].closed, 1);
  const g = fixture({ client: { end: () => { throw secretError; } } });
  assert.equal((await invoke(g.handler)).status, 200);
  assert.equal(g.clients[0].destroyed, 1);
});

test('telemetry errors do not change checkout responses', async () => {
  const f = fixture();
  f.telemetry.trackRequest = () => { throw secretError; };
  f.telemetry.trackDependency = () => { throw secretError; };
  assert.equal((await invoke(f.handler)).status, 200);
});

test('only allowlisted paths and methods are served, including traversal rejection', async () => {
  const f = fixture();
  for (const path of ['/', '/app.js', '/styles.css', '/healthz']) {
    const get = await invoke(f.handler, 'GET', path);
    assert.equal(get.status, 200);
    assert.equal(get.headers['X-Content-Type-Options'], 'nosniff');
    assert.match(get.headers['Content-Security-Policy'], /img-src https:\/\/images\.unsplash\.com/);
    const post = await invoke(f.handler, 'POST', path);
    assert.equal(post.status, 405);
    assert.equal(post.headers.Allow, 'GET');
  }
  for (const method of ['GET', 'PUT', 'DELETE', 'OPTIONS', 'HEAD']) {
    const response = await invoke(f.handler, method);
    assert.equal(response.status, 405);
    assert.equal(response.headers.Allow, 'POST');
  }
  for (const path of ['/fault', '/package.json', '/server.js', '/.env', '/../server.js', '/%2e%2e/server.js', '//healthz', '/checkout/', '/public/app.js']) {
    assert.equal((await invoke(f.handler, 'GET', path)).status, 404);
  }
  assert.equal(f.clients.length, 0);
  assert.equal(f.requests.length, 0);
});