'use strict';

function createTelemetry(connectionString, sdk) {
  if (!connectionString) return undefined;

  const client = new sdk.TelemetryClient(connectionString);
  Object.assign(client.config, {
    samplingPercentage: 100,
    enableAutoCollectRequests: false,
    enableAutoCollectDependencies: false,
    enableAutoCollectExceptions: false,
    enableAutoCollectConsole: false,
    enableAutoCollectExternalLoggers: false,
    enableAutoCollectPerformance: false,
    enableAutoCollectPreAggregatedMetrics: false,
    enableSendLiveMetrics: false,
    enableUseDiskRetryCaching: false,
    enableInternalDebugLogging: false,
    enableInternalWarningLogging: false,
    enableWebInstrumentation: false,
    noDiagnosticChannel: true,
  });
  client.initialize();
  return client;
}

module.exports = { createTelemetry };