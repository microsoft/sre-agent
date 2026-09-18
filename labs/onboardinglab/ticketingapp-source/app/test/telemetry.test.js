'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { EventEmitter } = require('node:events');
const { createRequire } = require('node:module');
const { dirname, join } = require('node:path');
const { Socket } = require('node:net');
const { createHandler } = require('../handler');
const { createTelemetry } = require('../telemetry');

function offlineTelemetry(t) {
  const sdk = require('applicationinsights');
  const sdkRequire = createRequire(require.resolve('applicationinsights'));
  const { BasicTracerProvider, InMemorySpanExporter, SimpleSpanProcessor } =
    sdkRequire('@opentelemetry/sdk-trace-base');
  // Exercise the installed exporter's real wire-envelope conversion, without
  // constructing Azure exporters (which initialize senders and background work).
  const { readableSpanToEnvelope } = require(join(
    dirname(sdkRequire.resolve('@azure/monitor-opentelemetry-exporter')), 'utils', 'spanUtils.js'));
  const exporter = new InMemorySpanExporter();
  const provider = new BasicTracerProvider({
    spanProcessors: [new SimpleSpanProcessor(exporter)],
  });
  t.after(() => provider.shutdown());
  const connect = t.mock.method(Socket.prototype, 'connect', () => {
    assert.fail('Offline telemetry tests must not open sockets');
  });
  t.after(() => assert.equal(connect.mock.callCount(), 0));
  // Replace only initialization and tracer acquisition; trackRequest and
  // trackDependency run unchanged against real, locally scoped OTel spans.
  t.mock.method(sdk.TelemetryClient.prototype, 'initialize', function () {
    this._isInitialized = true;
  });
  t.mock.method(sdk.TelemetryClient.prototype, '_getTracerInstance',
    () => provider.getTracer('ApplicationInsightsTracer'));
  const key = '00000000-0000-0000-0000-000000000000';
  const client = createTelemetry(
    `InstrumentationKey=${key};IngestionEndpoint=https://example.invalid/`, sdk);
  return {
    client,
    async envelopes() {
      await provider.forceFlush();
      const envelopes = exporter.getFinishedSpans().map((span) => readableSpanToEnvelope(span, key));
      exporter.reset();
      return envelopes;
    },
  };
}

test('missing connection string does not initialize the SDK', () => {
  assert.equal(createTelemetry(undefined, {}), undefined);
});

test('manual-only SDK configuration disables sampling and automatic sensitive collection before initialization', () => {
  let initialized = false;
  class TelemetryClient {
    constructor(connectionString) {
      assert.equal(connectionString, 'test-connection-string');
      this.config = {};
    }
    initialize() {
      initialized = true;
      assert.equal(this.config.samplingPercentage, 100);
      assert.equal(this.config.noDiagnosticChannel, true);
      for (const setting of [
        'enableAutoCollectRequests', 'enableAutoCollectDependencies',
        'enableAutoCollectExceptions', 'enableAutoCollectConsole',
        'enableAutoCollectExternalLoggers', 'enableSendLiveMetrics',
        'enableUseDiskRetryCaching', 'enableWebInstrumentation',
      ]) assert.equal(this.config[setting], false, setting);
    }
  }
  createTelemetry('test-connection-string', { TelemetryClient });
  assert.equal(initialized, true);
});

test('installed SDK maps configuration to unsampled manual-only instrumentation without network initialization', () => {
  const sdk = require('applicationinsights');
  const original = sdk.TelemetryClient.prototype.initialize;
  sdk.TelemetryClient.prototype.initialize = function () {};
  try {
    const client = createTelemetry(
      'InstrumentationKey=00000000-0000-0000-0000-000000000000;IngestionEndpoint=https://example.invalid/', sdk);
    const options = client.config.parseConfig();
    assert.equal(options.samplingRatio, 1);
    for (const [name, instrumentation] of Object.entries(options.instrumentationOptions)) {
      assert.equal(instrumentation.enabled, false, name);
    }
    assert.equal(options.enableAutoCollectExceptions, false);
    assert.equal(options.enableLiveMetrics, false);
    assert.equal(options.azureMonitorExporterOptions.disableOfflineStorage, true);
  } finally {
    sdk.TelemetryClient.prototype.initialize = original;
  }
});

test('pinned SDK reproduces response code zero for named requests without an HTTP method', async (t) => {
  assert.equal(require('applicationinsights/package.json').version, '3.16.0');
  const telemetry = offlineTelemetry(t);
  for (const [resultCode, success] of [['200', true], ['503', false]]) {
    telemetry.client.trackRequest({
      name: 'POST /checkout', url: 'http://localhost/checkout',
      duration: 1, resultCode, success,
      properties: { simulated: 'true' },
    });
    const [envelope] = await telemetry.envelopes();
    assert.equal(envelope.data.baseType, 'RequestData');
    assert.equal(envelope.data.baseData.name, 'POST /checkout');
    assert.equal(envelope.data.baseData.responseCode, '0');
    assert.equal(envelope.data.baseData.success, success);
  }
});

test('checkout emits sanitized 200/503 request envelopes through the installed SDK and exporter', async (t) => {
  const telemetry = offlineTelemetry(t);
  const secret = 'checkout-secret-never-export';
  for (const success of [true, false]) {
    const handler = createHandler({
      telemetry: telemetry.client,
      env: {
        POSTGRES_HOST: 'private.example.test', POSTGRES_DATABASE: 'private-database',
        POSTGRES_USER: 'private-user', AZURE_CLIENT_ID: 'private-client-id',
      },
      getAccessToken: async () => ({ token: secret, expiresOnTimestamp: Date.now() + 60000 }),
      createClient: () => Object.assign(new EventEmitter(), {
        async connect() {
          if (!success) throw new Error(`ECONNREFUSED private.example.test ${secret}`);
        },
        async query() {},
        async end() {},
        connection: { stream: { destroy() {} } },
      }),
    });
    const response = {
      setHeader() {},
      writeHead(status) { this.status = status; },
      end(body) { this.body = JSON.parse(body); },
    };
    await handler({
      method: 'POST', url: `/checkout?token=${secret}`,
      headers: { host: `${secret}.example.test`, authorization: `Bearer ${secret}` },
      resume() {},
    }, response);
    const status = success ? 200 : 503;
    assert.equal(response.status, status);
    assert.equal(response.body.success, success);
    const envelopes = await telemetry.envelopes();
    assert.equal(envelopes.length, 2);
    const requests = envelopes.filter((item) => item.data.baseType === 'RequestData');
    assert.equal(requests.length, 1);
    const request = requests[0].data.baseData;
    assert.equal(request.name, 'POST /checkout');
    assert.equal(request.responseCode, String(status));
    assert.equal(request.success, success);
    assert.equal(request.url, 'http://localhost/checkout');
    assert.deepEqual(request.properties, {
      simulated: 'true', outcome: success ? 'connected' : 'unavailable',
    });
    const dependency = envelopes.find((item) => item.data.baseType === 'RemoteDependencyData');
    assert.equal(dependency.data.baseData.name, 'PostgreSQL connectivity');
    assert.equal(dependency.data.baseData.success, success);
    for (const value of [secret, 'private.example.test', 'private-database',
      'private-user', 'private-client-id', 'ECONNREFUSED']) {
      assert.equal(JSON.stringify(envelopes).includes(value), false, value);
    }
  }
});