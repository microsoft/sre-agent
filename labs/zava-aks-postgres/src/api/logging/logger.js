// Azure Monitor OpenTelemetry SDK. Two load-bearing facts:
//   - `service.name` resource attribute → `cloud_RoleName='zava-api'`. Alert
//     dimension filters and KQL `AppRoleName == 'zava-api'` depend on this.
//   - `logger.emit()` ships logs into the `AppTraces` table (NOT
//     AppExceptions — that requires `recordException` on a span). The
//     `postgres-unreachable` scheduled-query alert in monitoring.bicep
//     queries AppTraces accordingly.
const { useAzureMonitor } = require('@azure/monitor-opentelemetry');
const { resourceFromAttributes } = require('@opentelemetry/resources');
const { ATTR_SERVICE_NAME } = require('@opentelemetry/semantic-conventions');
const { logs } = require('@opentelemetry/api-logs');
const { metrics } = require('@opentelemetry/api');

const aiConnStr = process.env.APPLICATIONINSIGHTS_CONNECTION_STRING;

// Mirror alertProductsSlow's 30 ms latency threshold so the custom metric and
// the log-based alert tell the same story (healthy category query ~3 ms; a
// dropped index pushes the 120k-row scan well past 30 ms).
const SLOW_QUERY_THRESHOLD_MS = 30;

let logger = null;
let categoryQueryDuration = null;
let slowQueryCount = null;

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

  // Custom OTel app metrics. `useAzureMonitor` registers a global MeterProvider
  // whose PeriodicExportingMetricReader ships to the Azure Monitor breeze
  // endpoint — so instruments created off `metrics.getMeter(...)` land in this
  // workspace-based App Insights component's `AppMetrics` table (a.k.a.
  // `customMetrics`), Name = the instrument name. This is what makes metrics a
  // first-class telemetry signal alongside AppTraces (logs) and
  // AppRequests/AppDependencies (traces) for the SAME slow-query incident.
  const meter = metrics.getMeter('zava-api');
  categoryQueryDuration = meter.createHistogram('zava.products.category.query.duration_ms', {
    description: 'Server-side duration of the products-by-category DB query',
    unit: 'ms',
  });
  slowQueryCount = meter.createCounter('zava.products.slow_query.count', {
    description: 'Count of category queries whose DB duration exceeded the slow-query threshold',
  });
}

// Record one category-query duration sample. The only attribute is `category`,
// whose values are the fixed seed categories plus the synthetic `__probe` — a
// bounded set. Do NOT add per-request attributes (id, sku, limit, user): those
// would explode metric series cardinality. The histogram includes `__probe`
// (the 1 Hz self-probe) so the metric stream has continuous data and climbs
// under a missing-index regression; the alert layer excludes `__probe` to mirror
// alertProductsSlow, so synthetic baseline traffic alone never fires it.
function recordCategoryQueryDuration(category, durationMs) {
  if (!categoryQueryDuration) return;
  categoryQueryDuration.record(durationMs, { category });
  if (durationMs > SLOW_QUERY_THRESHOLD_MS && category !== '__probe') {
    slowQueryCount.add(1, { category });
  }
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
  // Warn/error stays — the postgres-unreachable KQL alert depends on
  // AppTraces with severityLevel >= 2.
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

module.exports = { log, recordCategoryQueryDuration };
