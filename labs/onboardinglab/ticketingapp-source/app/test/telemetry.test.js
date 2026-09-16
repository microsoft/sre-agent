'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { createTelemetry } = require('../telemetry');

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