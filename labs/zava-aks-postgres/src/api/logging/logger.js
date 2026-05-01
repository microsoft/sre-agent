// Azure Monitor OpenTelemetry SDK. Two load-bearing facts:
//   - `service.name` resource attribute → `cloud_RoleName='zava-api'`. Alert
//     dimension filters and KQL `AppRoleName == 'zava-api'` depend on this.
//   - `logger.emit()` ships logs into the `AppTraces` table (NOT
//     AppExceptions — that requires `recordException` on a span). The
//     `postgres-server-down` and `postgres-network-blocked` scheduled-query
//     alerts in monitoring.bicep query AppTraces accordingly.
const { useAzureMonitor } = require('@azure/monitor-opentelemetry');
const { resourceFromAttributes } = require('@opentelemetry/resources');
const { ATTR_SERVICE_NAME } = require('@opentelemetry/semantic-conventions');
const { logs } = require('@opentelemetry/api-logs');

const aiConnStr = process.env.APPLICATIONINSIGHTS_CONNECTION_STRING;

let logger = null;

if (aiConnStr && aiConnStr.startsWith('InstrumentationKey=')) {
  useAzureMonitor({
    azureMonitorExporterOptions: {
      connectionString: aiConnStr,
    },
    resource: resourceFromAttributes({
      [ATTR_SERVICE_NAME]: 'zava-api',
    }),
    // 100% sampling — every exception/failed request ships immediately so
    // alert thresholds are met as fast as possible in a small demo dataset.
    samplingRatio: 1.0,
    enableLiveMetrics: false,
  });

  logger = logs.getLogger('zava-api');
}

function log(level, message, properties = {}) {
  const entry = {
    level,
    message,
    timestamp: new Date().toISOString(),
    service: 'zava-api',
    ...properties,
  };

  console.log(JSON.stringify(entry));

  // Ship to Azure Monitor as OTel logs (lands in AppTraces). Skip info-level
  // events — those are access-log rows for /api/products/* etc, which the
  // HTTP auto-instrumentation already records as AppRequests. Double-shipping
  // them adds ~530 MB/hr of redundant ingestion under Scenario 3 load.
  // Warn/error stays — the postgres-server-down + postgres-network-blocked
  // KQL alerts depend on AppTraces with severityLevel >= 2.
  if (logger && (level === 'warn' || level === 'error')) {
    // OTel SeverityNumber values per
    // https://opentelemetry.io/docs/specs/otel/logs/data-model/#field-severitynumber
    let severityNumber;
    let severityText;
    if (level === 'error') {
      severityNumber = 17;
      severityText = 'ERROR';
    } else if (level === 'warn') {
      severityNumber = 13;
      severityText = 'WARN';
    } else {
      severityNumber = 9;
      severityText = 'INFO';
    }
    logger.emit({
      body: message,
      severityNumber,
      severityText,
      attributes: properties,
    });
  }
}

module.exports = { log };
