require('./logging/logger'); // Initialize App Insights before anything else
const express = require('express');
const cors = require('cors');
const seed = require('./db/seed');
const { log } = require('./logging/logger');

const app = express();
const PORT = process.env.PORT || 3001;

app.use(cors());
app.use(express.json());

// Self-probe paths — the self-probe (see startSelfProbe below) hits these from
// inside the pod every PROBE_INTERVAL_MS. Listed here so the access-log middleware
// can skip them and keep stdout small. The synthetic `__probe` category name
// ensures real traffic to legitimate categories (Running, Outdoor, etc.) is
// never accidentally filtered. (We do NOT drop probe RequestData at the SDK
// layer — see the warning in logging/logger.js. Endpoint-specific filtering
// happens in KQL at the alert layer in monitoring.bicep.)
const PROBE_PATHS = new Set(['/api/health', '/api/products', '/api/products/category/__probe', '/livez']);

// Request logging middleware — only logs non-probe requests + any non-2xx response
app.use((req, res, next) => {
  const start = Date.now();
  res.on('finish', () => {
    if (PROBE_PATHS.has(req.originalUrl) && res.statusCode < 400) return;
    log('info', `${req.method} ${req.originalUrl}`, {
      method: req.method, path: req.originalUrl, statusCode: res.statusCode,
      duration_ms: Date.now() - start,
    });
  });
  next();
});

// Routes
app.use('/api/products', require('./routes/products'));
app.use('/api/orders', require('./routes/orders'));
app.use('/api/health', require('./routes/health'));
app.use('/api/diagnostics', require('./routes/diagnostics'));

// Shallow liveness check — no DB dependency, just confirms the process is alive
app.get('/livez', (req, res) => res.json({ status: 'alive' }));

// Self-health probe — generates steady App Insights telemetry from inside the cluster.
// When DB goes down or network breaks, these requests fail and trigger Azure Monitor alerts
// without needing an external load generator.
// Default 30s for local dev; k8s/configmap.yaml overrides to 1000 ms in-cluster.
const PROBE_INTERVAL_MS = parseInt(process.env.PROBE_INTERVAL_MS || '30000'); // 30s default
function startSelfProbe() {
  if (PROBE_INTERVAL_MS <= 0) return; // set to 0 to disable
  const http = require('http');
  const probe = (path) => {
    const req = http.get(`http://localhost:${PORT}${path}`, { timeout: 10000 }, (res) => {
      res.resume(); // drain response
    });
    req.on('error', () => {}); // swallow — App Insights already tracked it
  };
  setInterval(() => {
    probe('/api/health');
    probe('/api/products');
    probe('/api/products/category/__probe'); // synthetic — avoids dropping real category traffic
  }, PROBE_INTERVAL_MS);
  log('info', `Self-health probe started (every ${PROBE_INTERVAL_MS / 1000}s)`);
}

// Auto-seed on startup
const pool = require('./db/client');
seed().then(() => {
  const server = app.listen(PORT, '0.0.0.0', () => {
    console.log(JSON.stringify({ level: 'info', message: `Zava API server running on port ${PORT}`, timestamp: new Date().toISOString() }));
    startSelfProbe();
  });

  process.on('SIGTERM', () => {
    log('info', 'SIGTERM received, shutting down gracefully');
    server.close(() => {
      pool.end().then(() => process.exit(0)).catch(() => process.exit(1));
    });
  });
}).catch(err => {
  log('error', 'Failed to seed database — starting anyway', { error: err.message });
  const server = app.listen(PORT, '0.0.0.0', () => {
    console.log(JSON.stringify({ level: 'warn', message: `Zava API server running on port ${PORT} (DB seed failed)`, timestamp: new Date().toISOString() }));
    startSelfProbe();
  });

  process.on('SIGTERM', () => {
    log('info', 'SIGTERM received, shutting down gracefully');
    server.close(() => {
      pool.end().then(() => process.exit(0)).catch(() => process.exit(1));
    });
  });
});
