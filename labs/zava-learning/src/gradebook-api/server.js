"use strict";

// Application Insights — initialized before any other module so the diagnostic-channel
// patches are in place. Auto-collects requests, exceptions, dependencies and perf so the
// requests/exceptions/dependencies tables populate for crash and latency investigation.
// Guarded so local runs without a connection string still boot.
const appInsights = require("applicationinsights");
if (process.env.APPLICATIONINSIGHTS_CONNECTION_STRING) {
  appInsights.setup(process.env.APPLICATIONINSIGHTS_CONNECTION_STRING)
    .setAutoCollectRequests(true)
    .setAutoCollectExceptions(true)
    .setAutoCollectDependencies(true)
    .setAutoCollectPerformance(true, true)
    .setSendLiveMetrics(true)
    .start();
  appInsights.defaultClient.context.tags[appInsights.defaultClient.context.keys.cloudRole] = "gradebook-api";
}
// Zava Learning — gradebook-api. Reads student scores from Postgres (the submissions
// table written by quiz-service). Environment-internal (not fronted by the App Gateway).
const express = require("express");
const { Pool } = require("pg");

const app = express();
const PORT = process.env.PORT || 8080;
const SERVICE = "gradebook-api";

const pool = new Pool({
  host: process.env.PGHOST,
  port: Number(process.env.PGPORT || 5432),
  database: process.env.PGDATABASE || "zava",
  user: process.env.PGUSER,
  password: process.env.PGPASSWORD,
  max: Number(process.env.PG_POOL_MAX || 5),
  connectionTimeoutMillis: Number(process.env.PG_CONNECT_TIMEOUT_MS || 5000),
  idleTimeoutMillis: 30000,
  ssl: (process.env.PG_SSL || "require") === "disable" ? false : { rejectUnauthorized: false }
});

pool.on("error", (err) => { console.error(`pool error: ${err.message}`); });

app.get("/health", async (_req, res) => {
  try {
    const c = await pool.connect();
    try { await c.query("SELECT 1"); } finally { c.release(); }
    res.status(200).json({ status: "ok", service: SERVICE, ts: new Date().toISOString() });
  } catch (err) {
    res.status(503).json({ status: "degraded", service: SERVICE, detail: String(err.message || err) });
  }
});

app.get("/grades/:courseId", async (req, res) => {
  const courseId = req.params.courseId.toUpperCase();
  try {
    const r = await pool.query(
      `SELECT count(*)::int AS submissions,
              COALESCE(round(avg(score_pct))::int, 0) AS avg_score,
              COALESCE(max(score_pct), 0) AS top_score
       FROM submissions WHERE course_id = $1`,
      [courseId]
    );
    res.json({ courseId, ...r.rows[0] });
  } catch (err) {
    res.status(500).json({ error: "grades_lookup_failed", detail: String(err.message || err) });
  }
});

app.listen(PORT, () => {
  console.log(`[${SERVICE}] listening on :${PORT}`);
});
