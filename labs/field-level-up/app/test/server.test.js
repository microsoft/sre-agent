'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { EventEmitter } = require('node:events');
const { readFileSync } = require('node:fs');
const { join } = require('node:path');
const { runInNewContext } = require('node:vm');
const { createHandler } = require('../handler');

test('server selects the UAMI and fetches the PostgreSQL scope only on checkout, never on startup', async () => {
  const env = {
    AZURE_CLIENT_ID: 'test-uami-client-id', POSTGRES_USER: 'lab-uami-display-name',
    POSTGRES_HOST: 'private.example.test', POSTGRES_DATABASE: 'lab',
  };
  const token = 'server-token-never-expose';
  const scopes = [];
  const logs = [];
  const clients = [];
  let identityOptions;
  let handler;
  let listening = false;
  const server = {
    listen(port, host, callback) {
      assert.equal(port, 8080);
      assert.equal(host, '0.0.0.0');
      listening = true;
      callback();
    },
  };
  class ManagedIdentityCredential {
    constructor(options) { identityOptions = options; }
    async getToken(scope) {
      scopes.push(scope);
      return { token, expiresOnTimestamp: Date.now() + 60000 };
    }
  }
  class Client extends EventEmitter {
    constructor(config) {
      super();
      this.config = config;
      this.closed = false;
      this.destroyed = false;
      this.connection = { stream: { destroy: () => { this.destroyed = true; } } };
      clients.push(this);
    }
    async connect() { assert.equal(await this.config.password(), token); }
    async query(sql) { assert.equal(sql, 'SELECT 1'); }
    async end() { this.closed = true; }
  }
  const modules = {
    './telemetry': { createTelemetry() { assert.fail('Telemetry must not initialize without config'); } },
    'node:http': { createServer(callback) { handler = callback; return server; } },
    pg: { Client },
    '@azure/identity': { ManagedIdentityCredential },
    './handler': { createHandler: (options) => createHandler({ ...options, env }) },
  };
  // Run the real startup wiring with explicit module doubles: no sockets or MI calls.
  runInNewContext(readFileSync(join(__dirname, '../server.js'), 'utf8'), {
    process: { env },
    console: { info: (...args) => logs.push(args), warn: (...args) => logs.push(args) },
    require(name) {
      assert.ok(Object.hasOwn(modules, name), `Unexpected startup dependency: ${name}`);
      return modules[name];
    },
  });
  assert.equal(identityOptions.clientId, env.AZURE_CLIENT_ID);
  assert.equal(listening, true);
  assert.equal(clients.length, 0);
  assert.deepEqual(scopes, []);

  async function invoke(method, url) {
    const response = {
      setHeader() {},
      writeHead(status) { this.status = status; },
      end(body) { this.body = String(body); },
    };
    await handler({ method, url, resume() {} }, response);
    return response;
  }
  assert.equal((await invoke('GET', '/healthz')).status, 200);
  assert.equal((await invoke('GET', '/')).status, 200);
  assert.equal(clients.length, 0);
  assert.deepEqual(scopes, []);
  const response = await invoke('POST', '/checkout');
  assert.equal(response.status, 200);
  assert.deepEqual(scopes, ['https://ossrdbms-aad.database.windows.net/.default']);
  assert.equal(clients[0].config.user, env.POSTGRES_USER);
  assert.equal(clients[0].closed, true);
  assert.equal(clients[0].destroyed, true);
  assert.equal(JSON.stringify({ response, logs }).includes(token), false);
});