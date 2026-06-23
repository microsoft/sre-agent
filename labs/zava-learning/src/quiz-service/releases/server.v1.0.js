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
  appInsights.defaultClient.context.tags[appInsights.defaultClient.context.keys.cloudRole] = "quiz-service";
}
// Zava Learning — quiz-service (DB-backed).
//
// This single, real codebase is the breakable surface for the DB-flavored fault lanes.
// It owns NO fault toggles: every fault is injected via real backend state so the SRE
// Agent sees an authentic failure mode.
//   * query lane  -> /quiz runs a count over question_bank that depends on
//                    idx_question_bank_course; break-query DROPs the index -> seq scan.
//   * pool lane   -> connects with a dedicated DB role; break-pool sets a real
//                    CONNECTION LIMIT on that role -> "too many connections" under load.
//   * secret lane -> PGPASSWORD is sourced from Key Vault; break-secret rotates it to an
//                    invalid value -> authentication failures.
//   * perf lane   -> the v1.1 source variant adds a synchronous KDF on the hot path
//                    (a real bad release shipped as quiz-service:v1.1).
const express = require("express");
const { Pool } = require("pg");

const app = express();
app.use(express.json());

const PORT = process.env.PORT || 8080;
const SERVICE = "quiz-service";

// Per-request timing telemetry -> container console -> Log Analytics (ms= for latency
// queries/alerts), matching the rest of the platform.
app.use((req, res, next) => {
  const start = process.hrtime.bigint();
  res.on("finish", () => {
    const ms = Math.round(Number(process.hrtime.bigint() - start) / 1e6);
    console.log(`req method=${req.method} path=${req.path} status=${res.statusCode} ms=${ms}`);
  });
  next();
});
// ZAVA-PERF-INJECT-POINT (the v1.1 "quiz integrity receipts" regression lives below this line)

const pool = new Pool({
  host: process.env.PGHOST,
  port: Number(process.env.PGPORT || 5432),
  database: process.env.PGDATABASE || "zava",
  user: process.env.PGUSER,
  password: process.env.PGPASSWORD,
  max: Number(process.env.PG_POOL_MAX || 10),
  connectionTimeoutMillis: Number(process.env.PG_CONNECT_TIMEOUT_MS || 5000),
  idleTimeoutMillis: 30000,
  ssl: (process.env.PG_SSL || "require") === "disable" ? false : { rejectUnauthorized: false }
});

pool.on("error", (err) => {
  console.error(`pool error: ${err.message}`);
});

// Lightweight readiness ping. Surfaces secret/pool/connectivity faults as 503 so both the
// AppGw probe and Azure Monitor see the lane as unhealthy.
app.get("/health", async (_req, res) => {
  try {
    const c = await pool.connect();
    try { await c.query("SELECT 1"); } finally { c.release(); }
    res.status(200).json({ status: "ok", service: SERVICE, ts: new Date().toISOString() });
  } catch (err) {
    res.status(503).json({ status: "degraded", service: SERVICE, detail: String(err.message || err) });
  }
});

app.get("/quiz/:courseId", async (req, res) => {
  const courseId = req.params.courseId.toUpperCase();
  let client;
  try {
    client = await pool.connect();
    // Hot-path lookup over the large question bank. Index scan when healthy; the query
    // lane fault DROPs idx_question_bank_course -> sequential scan over ~500k rows.
    const bank = await client.query(
      "SELECT count(*)::int AS available FROM question_bank WHERE course_id = $1 AND active",
      [courseId]
    );
    const q = await client.query(
      "SELECT prompt, options FROM quiz_questions WHERE course_id = $1 ORDER BY id",
      [courseId]
    );
    const questions = q.rows.length
      ? q.rows.map(r => ({ q: r.prompt, options: r.options }))
      : [
          { q: `Sample question 1 for ${courseId}`, options: ["A", "B", "C", "D"] },
          { q: `Sample question 2 for ${courseId}`, options: ["A", "B", "C", "D"] }
        ];
    res.json({ courseId, available: bank.rows[0].available, questionCount: questions.length, questions });
  } catch (err) {
    // DB unreachable / auth failure / role connection limit -> 500 (or 502-style upstream).
    res.status(500).json({ error: "quiz_lookup_failed", detail: String(err.message || err) });
  } finally {
    if (client) client.release();
  }
});

app.post("/quiz/:courseId/submit", async (req, res) => {
  const courseId = req.params.courseId.toUpperCase();
  const studentId = (req.body && req.body.studentId) || "anonymous";
  const answers = Array.isArray(req.body && req.body.answers) ? req.body.answers : [];
  let client;
  try {
    client = await pool.connect();
    const q = await client.query(
      "SELECT answer_idx FROM quiz_questions WHERE course_id = $1 ORDER BY id",
      [courseId]
    );
    const key = q.rows.map(r => r.answer_idx);
    const total = key.length || answers.length || 1;
    let correct = 0;
    key.forEach((a, i) => { if (answers[i] === a) correct++; });
    const scorePct = Math.round((correct / total) * 100);
    await client.query(
      "INSERT INTO submissions (course_id, student_id, total, correct, score_pct) VALUES ($1,$2,$3,$4,$5)",
      [courseId, studentId, total, correct, scorePct]
    );
    res.json({ courseId, total, correct, scorePct });
  } catch (err) {
    res.status(500).json({ error: "submit_failed", detail: String(err.message || err) });
  } finally {
    if (client) client.release();
  }
});

app.listen(PORT, () => {
  console.log(`[${SERVICE}] listening on :${PORT}`);
});
