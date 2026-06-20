// grid-status-api — Zava Power ZeroOps Lab
//
// Simulates Zava Power's internal grid management status system, providing
// real-time region status, capacity summaries, and grid alerts.
//
// Set SIMULATE_DELAY_MS to inject artificial latency on all endpoints

// App Insights MUST be loaded before anything else
const aiKey = process.env.APPLICATIONINSIGHTS_CONNECTION_STRING;
if (aiKey) {
  const { useAzureMonitor } = require("applicationinsights");
  useAzureMonitor({
    azureMonitorExporterOptions: { connectionString: aiKey },
  });
  console.log("Application Insights enabled (v3)");
}

const express = require("express");

const app = express();
const PORT = parseInt(process.env.PORT, 10) || 8080;
const SIMULATE_DELAY_MS = parseInt(process.env.SIMULATE_DELAY_MS, 10) || 0;

// ---------------------------------------------------------------------------
// Chaos mode — activated via POST /chaos/latency to simulate server-side load
// Deactivated via DELETE /chaos/latency or auto-expires after duration
// ---------------------------------------------------------------------------
let chaosLatencyMs = 0;
let chaosExpiry = 0;

// ---------------------------------------------------------------------------
// Request logging
// ---------------------------------------------------------------------------
app.use((req, _res, next) => {
  console.log(`[${new Date().toISOString()}] ${req.method} ${req.url}`);
  next();
});

// ---------------------------------------------------------------------------
// Simulated-delay middleware (performance regression simulation)
// ---------------------------------------------------------------------------
if (SIMULATE_DELAY_MS > 0) {
  console.log(`⚠  SIMULATE_DELAY_MS=${SIMULATE_DELAY_MS} — artificial latency enabled on all endpoints`);
  app.use((_req, _res, next) => {
    setTimeout(next, SIMULATE_DELAY_MS);
  });
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const crypto = require("crypto");

/** Return a value randomly jittered by ±pct (0-1). */
function jitter(value, pct = 0.05) {
  const delta = value * pct;
  return Math.round(value + (Math.random() * 2 - 1) * delta);
}

/**
 * Compute SCADA telemetry integrity checksum — real per-request work.
 * Grid management systems verify data integrity on every read.
 * Uses CPU-bound computation that App Insights measures as server
 * duration. On 0.25 vCPU this takes ~300-500ms per request. Under
 * heavy concurrency, requests serialize on the single core pushing
 * server-side duration well above the 1500ms alert threshold.
 */
function computeTelemetryChecksum(regions) {
  const payload = JSON.stringify(regions);
  // Deliberately CPU-intensive: pbkdf2Sync is synchronous and blocks
  // the event loop, so App Insights measures the full duration.
  const key = crypto.pbkdf2Sync(payload, "scada-grid-salt", 50000, 64, "sha512");
  return key.toString("hex");
}

/** Base region definitions — load values are jittered on every request. */
const REGIONS_BASE = [
  { region: "Zava Power Electric - Eastern PA",  baseLoad: 67, capacity_mw: 4200, substations_online: 142, substations_total: 145 },
  { region: "Zava Power Electric - Central PA",  baseLoad: 54, capacity_mw: 3100, substations_online: 98,  substations_total: 100 },
  { region: "Zava Power Electric - Western PA",  baseLoad: 72, capacity_mw: 2800, substations_online: 76,  substations_total: 80  },
  { region: "LG&E - Louisville Metro",    baseLoad: 61, capacity_mw: 3600, substations_online: 112, substations_total: 115 },
  { region: "Narragansett - Rhode Island", baseLoad: 48, capacity_mw: 1900, substations_online: 54,  substations_total: 55  },
];

function buildRegions() {
  return REGIONS_BASE.map((r) => {
    const load_pct = Math.min(100, Math.max(0, jitter(r.baseLoad, 0.08)));
    const current_mw = Math.round(r.capacity_mw * (load_pct / 100));
    const substations_online = Math.min(
      r.substations_total,
      Math.max(r.substations_total - 5, jitter(r.substations_online, 0.02))
    );
    const status = load_pct > 90 ? "critical" : load_pct > 80 ? "warning" : "normal";
    return {
      region: r.region,
      status,
      load_pct,
      capacity_mw: r.capacity_mw,
      current_mw,
      substations_online,
      substations_total: r.substations_total,
    };
  });
}

const ALERT_TEMPLATES = [
  { type: "transformer_overload", severity: "high",   message: "Transformer T-4417 at Allentown substation exceeded 95% rated capacity" },
  { type: "line_fault",          severity: "critical", message: "69 kV line fault detected between Harrisburg and Lancaster substations" },
  { type: "voltage_sag",        severity: "medium",   message: "Voltage sag of 8% measured on 12 kV feeder in Scranton district" },
  { type: "frequency_deviation", severity: "low",     message: "Grid frequency deviation of +0.03 Hz observed in Rhode Island interconnect" },
  { type: "breaker_trip",       severity: "high",     message: "Circuit breaker CB-221 tripped at Louisville Metro substation 9" },
  { type: "load_shed_warning",  severity: "medium",   message: "Approaching load-shed threshold in Western PA region during peak demand" },
];

function buildAlerts() {
  // Return a random subset (2–4 alerts) so the response varies.
  const count = 2 + Math.floor(Math.random() * 3);
  const shuffled = [...ALERT_TEMPLATES].sort(() => Math.random() - 0.5);
  return shuffled.slice(0, count).map((a) => ({
    ...a,
    timestamp: new Date().toISOString(),
    id: `ALT-${Date.now()}-${Math.random().toString(36).slice(2, 7)}`,
  }));
}

// ---------------------------------------------------------------------------
// Chaos latency middleware — adds delay when chaos mode is active
// ---------------------------------------------------------------------------
app.use((req, _res, next) => {
  if (chaosLatencyMs > 0 && Date.now() < chaosExpiry) {
    setTimeout(next, chaosLatencyMs);
  } else if (chaosLatencyMs > 0 && Date.now() >= chaosExpiry) {
    chaosLatencyMs = 0;
    chaosExpiry = 0;
    console.log("Chaos latency expired — back to normal");
    next();
  } else {
    next();
  }
});

// ---------------------------------------------------------------------------
// Chaos control endpoints
// ---------------------------------------------------------------------------
app.use(express.json());

app.post("/chaos/latency", (req, res) => {
  const ms = parseInt(req.body.latency_ms, 10) || 2000;
  const durationMin = parseInt(req.body.duration_min, 10) || 10;
  chaosLatencyMs = ms;
  chaosExpiry = Date.now() + durationMin * 60 * 1000;
  console.log(`⚠  CHAOS: Adding ${ms}ms server-side latency for ${durationMin} min`);
  res.json({ status: "chaos_enabled", latency_ms: ms, expires_in_min: durationMin });
});

app.delete("/chaos/latency", (_req, res) => {
  chaosLatencyMs = 0;
  chaosExpiry = 0;
  console.log("✓ CHAOS: Latency removed");
  res.json({ status: "chaos_disabled" });
});

app.get("/chaos/status", (_req, res) => {
  const active = chaosLatencyMs > 0 && Date.now() < chaosExpiry;
  res.json({
    active,
    latency_ms: active ? chaosLatencyMs : 0,
    remaining_sec: active ? Math.round((chaosExpiry - Date.now()) / 1000) : 0,
  });
});

// ---------------------------------------------------------------------------
// Endpoints
// ---------------------------------------------------------------------------

app.get("/health", (_req, res) => {
  res.json({ status: "healthy", service: "grid-status-api", version: "1.0.0" });
});

app.get("/regions", (_req, res) => {
  const regions = buildRegions();
  const checksum = computeTelemetryChecksum(regions);
  res.json({ regions, checksum, timestamp: new Date().toISOString() });
});

app.get("/capacity", (_req, res) => {
  const regions = buildRegions();
  const total_capacity_mw = regions.reduce((s, r) => s + r.capacity_mw, 0);
  const total_current_mw = regions.reduce((s, r) => s + r.current_mw, 0);
  const total_substations_online = regions.reduce((s, r) => s + r.substations_online, 0);
  const total_substations = regions.reduce((s, r) => s + r.substations_total, 0);
  res.json({
    total_capacity_mw,
    total_current_mw,
    overall_load_pct: Math.round((total_current_mw / total_capacity_mw) * 100),
    total_substations_online,
    total_substations,
    reserve_margin_mw: total_capacity_mw - total_current_mw,
    timestamp: new Date().toISOString(),
  });
});

app.get("/alerts", (_req, res) => {
  res.json(buildAlerts());
});

// ---------------------------------------------------------------------------
// Start
// ---------------------------------------------------------------------------
app.listen(PORT, () => {
  console.log(`grid-status-api listening on port ${PORT}`);
});
