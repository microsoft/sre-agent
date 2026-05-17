// Bug: Performance — "Added grid integrity checksum validation"
//
// A developer added SHA-256 checksum validation to ensure grid telemetry
// data integrity before returning results. The implementation computes
// checksums synchronously on the main thread using crypto.createHash()
// in a tight loop. On a 0.25 vCPU ACA replica this blocks the Node.js
// event loop for ~3-6 seconds per /regions request.
//
// Root cause: Lines marked with // BUG below
//   - computeGridChecksum() does 750,000 SHA-256 hashes synchronously
//   - Called on EVERY /regions and /capacity request
//   - Blocks the entire event loop — no concurrent requests possible
//
// SRE Agent should find: P95 latency on /regions spikes to >3s,
// correlate with this deployment's release.completedTime, and rollback.

// grid-status-api — Zava Power ZeroOps Lab
// (v2.1.0 — added grid telemetry integrity validation)

const express = require("express");
const crypto = require("crypto");

const app = express();
const PORT = parseInt(process.env.PORT, 10) || 8080;

// ---------------------------------------------------------------------------
// Request logging
// ---------------------------------------------------------------------------
app.use((req, _res, next) => {
  console.log(`[${new Date().toISOString()}] ${req.method} ${req.url}`);
  next();
});

// ---------------------------------------------------------------------------
// Grid integrity checksum — validates telemetry data hasn't been tampered
// Added in v2.1.0 per SEC-2847 security audit requirement
// ---------------------------------------------------------------------------

function computeGridChecksum(data) {
  // BUG: Synchronous CPU-intensive work on the event loop.
  // This was meant to run as a background job but was accidentally
  // placed in the request hot path during the v2.1.0 merge.
  let checksum = JSON.stringify(data);
  for (let i = 0; i < 750000; i++) {  // BUG: 750K iterations blocks for ~3-6s on 0.25 vCPU
    checksum = crypto.createHash("sha256").update(checksum).digest("hex");
  }
  return checksum;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function jitter(value, pct = 0.05) {
  const delta = value * pct;
  return Math.round(value + (Math.random() * 2 - 1) * delta);
}

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
      region: r.region, status, load_pct, capacity_mw: r.capacity_mw,
      current_mw, substations_online, substations_total: r.substations_total,
    };
  });
}

const ALERT_TEMPLATES = [
  { type: "transformer_overload", severity: "high",   message: "Transformer T-4417 at Allentown substation exceeded 95% rated capacity" },
  { type: "line_fault",          severity: "critical", message: "69 kV line fault detected between Harrisburg and Lancaster substations" },
  { type: "voltage_sag",        severity: "medium",   message: "Voltage sag of 8% measured on 12 kV feeder in Scranton district" },
  { type: "frequency_deviation", severity: "low",     message: "Grid frequency deviation of +0.03 Hz observed in Rhode Island interconnect" },
  { type: "breaker_trip",       severity: "high",     message: "Circuit breaker CB-221 tripped at Louisville Metro substation 9" },
];

function buildAlerts() {
  const count = 2 + Math.floor(Math.random() * 3);
  const shuffled = [...ALERT_TEMPLATES].sort(() => Math.random() - 0.5);
  return shuffled.slice(0, count).map((a) => ({
    ...a, timestamp: new Date().toISOString(),
    id: `ALT-${Date.now()}-${Math.random().toString(36).slice(2, 7)}`,
  }));
}

// ---------------------------------------------------------------------------
// Endpoints
// ---------------------------------------------------------------------------

app.get("/health", (_req, res) => {
  res.json({ status: "healthy", service: "grid-status-api", version: "2.1.0" });
});

app.get("/regions", (_req, res) => {
  const regions = buildRegions();

  // v2.1.0: Validate telemetry integrity before returning
  const checksum = computeGridChecksum(regions);  // BUG: blocks event loop 3-5s
  console.log(`Grid checksum: ${checksum.substring(0, 12)}...`);

  res.json(regions);
});

app.get("/capacity", (_req, res) => {
  const regions = buildRegions();

  // v2.1.0: Validate capacity data integrity
  const checksum = computeGridChecksum(regions);  // BUG: blocks event loop 3-5s
  console.log(`Capacity checksum: ${checksum.substring(0, 12)}...`);

  const total_capacity_mw = regions.reduce((s, r) => s + r.capacity_mw, 0);
  const total_current_mw = regions.reduce((s, r) => s + r.current_mw, 0);
  const total_substations_online = regions.reduce((s, r) => s + r.substations_online, 0);
  const total_substations = regions.reduce((s, r) => s + r.substations_total, 0);
  res.json({
    total_capacity_mw, total_current_mw,
    overall_load_pct: Math.round((total_current_mw / total_capacity_mw) * 100),
    total_substations_online, total_substations,
    reserve_margin_mw: total_capacity_mw - total_current_mw,
    integrity_checksum: checksum.substring(0, 16),
    timestamp: new Date().toISOString(),
  });
});

app.get("/alerts", (_req, res) => {
  res.json(buildAlerts());
});

app.listen(PORT, () => {
  console.log(`grid-status-api v2.1.0 listening on port ${PORT}`);
  console.log("Grid integrity checksum validation ENABLED (SEC-2847)");
});
