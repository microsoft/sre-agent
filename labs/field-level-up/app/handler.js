'use strict';

const { readFileSync } = require('node:fs');
const { join } = require('node:path');
const { performance } = require('node:perf_hooks');

const DB_TIMEOUT_MS = 5000;
const MAX_DB_ATTEMPTS = 4;
const assets = new Map([
  ['/', ['index.html', 'text/html; charset=utf-8']],
  ['/app.js', ['app.js', 'text/javascript; charset=utf-8']],
  ['/styles.css', ['styles.css', 'text/css; charset=utf-8']],
].map(([path, [file, type]]) => [path, {
  body: readFileSync(join(__dirname, 'public', file)), type,
}]));

function databaseConfig(env, getAccessToken) {
  const port = Number(env.POSTGRES_PORT || 5432);
  if (!env.POSTGRES_HOST || !env.POSTGRES_DATABASE || !env.POSTGRES_USER ||
      !env.AZURE_CLIENT_ID || typeof getAccessToken !== 'function' ||
      !Number.isInteger(port) || port < 1 || port > 65535) {
    throw new Error('Database configuration unavailable');
  }
  return {
    host: env.POSTGRES_HOST,
    port,
    database: env.POSTGRES_DATABASE,
    user: env.POSTGRES_USER,
    password: async () => {
      const accessToken = await getAccessToken('https://ossrdbms-aad.database.windows.net/.default');
      if (!accessToken || typeof accessToken.token !== 'string' || !accessToken.token ||
          !Number.isFinite(accessToken.expiresOnTimestamp) || accessToken.expiresOnTimestamp <= Date.now()) {
        throw new Error('Database credential unavailable');
      }
      return accessToken.token;
    },
    ssl: { rejectUnauthorized: true },
    connectionTimeoutMillis: DB_TIMEOUT_MS,
    query_timeout: DB_TIMEOUT_MS,
    statement_timeout: DB_TIMEOUT_MS,
  };
}

function json(response, status, body) {
  response.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8' });
  response.end(JSON.stringify(body));
}

// Production supplies pg.Client, managed-identity token acquisition and telemetry.
function createHandler({ createClient, getAccessToken, telemetry, env = process.env }) {
  let activeAttempts = 0;

  function track(method, data) {
    try {
      telemetry?.[method](data);
    } catch {
      // Telemetry availability must never affect checkout or reveal SDK errors.
    }
  }

  return async function handler(request, response) {
    response.setHeader('Cache-Control', 'no-store');
    response.setHeader('X-Content-Type-Options', 'nosniff');
    response.setHeader('Referrer-Policy', 'no-referrer');
    response.setHeader('Content-Security-Policy',
      "default-src 'none'; script-src 'self'; style-src 'self'; img-src https://images.unsplash.com; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'");
    request.resume(); // No endpoint reads request bodies or accepts caller-supplied SQL.

    // Compare raw paths, without URL normalization or filesystem interpolation.
    const path = (request.url || '').split('?')[0];
    const asset = assets.get(path);
    const allowedMethod = path === '/checkout' ? 'POST' : 'GET';
    if (!asset && path !== '/healthz' && path !== '/checkout') {
      return json(response, 404, { error: 'Not found' });
    }
    if (request.method !== allowedMethod) {
      response.setHeader('Allow', allowedMethod);
      return json(response, 405, { error: 'Method not allowed' });
    }
    if (path === '/healthz') {
      return json(response, 200, { status: 'healthy' });
    }
    if (asset) {
      response.writeHead(200, { 'Content-Type': asset.type });
      return response.end(asset.body);
    }

    const started = performance.now();
    let success = false;
    let outcome = 'busy';
    if (activeAttempts < MAX_DB_ATTEMPTS) {
      activeAttempts += 1;
      let client;
      let timer;
      outcome = 'unavailable';
      try {
        client = createClient(databaseConfig(env, getAccessToken));
        const connectionError = new Promise((_, reject) => client.on('error', reject));
        const deadline = new Promise((_, reject) => {
          timer = setTimeout(() => {
            outcome = 'timeout';
            reject(new Error('Database deadline exceeded'));
          }, DB_TIMEOUT_MS);
        });
        await Promise.race([
          (async () => {
            await client.connect();
            await client.query('SELECT 1');
          })(),
          connectionError,
          deadline,
        ]);
        success = true;
        outcome = 'connected';
      } catch {
        // Never serialize or log pg errors, connection settings, or credentials.
      } finally {
        clearTimeout(timer);
        if (client) {
          try {
            Promise.resolve(client.end()).catch(() => {});
          } catch {
            // Force-close below even if graceful shutdown failed.
          } finally {
            // pg has no public force-close method. Its socket is destroyed after
            // end() so a timed-out handshake/query (or close) cannot linger.
            client.connection.stream.destroy();
          }
        }
        activeAttempts -= 1;
      }
      track('trackDependency', {
        name: 'PostgreSQL connectivity',
        target: 'PostgreSQL',
        dependencyTypeName: 'PostgreSQL',
        data: 'SELECT 1',
        duration: performance.now() - started,
        success,
        resultCode: success ? '0' : '1',
        properties: { simulated: 'true', outcome },
      });
    }

    const status = success ? 200 : 503;
    track('trackRequest', {
      name: 'POST /checkout',
      url: 'http://localhost/checkout', // Never trust Host/query parameters in telemetry.
      duration: performance.now() - started,
      resultCode: String(status),
      success,
      properties: { simulated: 'true', outcome },
    });
    if (success) {
      return json(response, status, {
        success: true, simulated: true,
        message: 'Simulated checkout succeeded. Database connectivity verified; no purchase was made.',
      });
    }
    response.setHeader('Retry-After', '3');
    return json(response, status, {
      success: false, simulated: true,
      message: 'Simulated checkout unavailable. Please try again shortly.',
    });
  };
}

module.exports = { createHandler };