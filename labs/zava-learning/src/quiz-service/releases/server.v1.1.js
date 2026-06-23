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
// Zava Learning — quiz-service v1.1 ("tamper-evident quiz integrity receipts").
//
// THIS IS THE PLANTED BAD RELEASE (perf lane). It is a REAL, complete source variant —
// not a runtime toggle. chaos/break-perf.ps1 copies this file over server.js, commits it
// ("release: v1.1 quiz integrity receipts"), and builds quiz-service:v1.1. The only diff
// from v1.0 is the synchronous KDF middleware below: it computes a per-request integrity
// receipt on the quiz hot path with a deliberately expensive sync pbkdf2, spiking latency.
// The SRE Agent diagnoses the regression, rolls the revision back live, and opens a real
// git-revert PR; fix-perf/reset.ps1 reverts to v1.0 and redeploys the clean image.
const express = require("express");
const { Pool } = require("pg");
const crypto = require("crypto");

const app = express();
app.use(express.json());

const PORT = process.env.PORT || 8080;
const SERVICE = "quiz-service";

app.use((req, res, next) => {
  const start = process.hrtime.bigint();
  res.on("finish", () => {
    const ms = Math.round(Number(process.hrtime.bigint() - start) / 1e6);
    console.log(`req method=${req.method} path=${req.path} status=${res.statusCode} ms=${ms}`);
  });
  next();
});
// ZAVA-PERF-INJECT-POINT (the v1.1 "quiz integrity receipts" regression lives below this line)

// >>> v1.1: tamper-evident quiz integrity receipts.
// Stamp every quiz response with a cryptographic integrity receipt so downloaded quizzes
// can be verified offline. Implemented as a SYNCHRONOUS KDF on the request path — which
// blocks the event loop and turns a fast quiz load into a multi-hundred-ms request.
app.use((req, res, next) => {
  if (req.method === "GET" && req.path.startsWith("/quiz/")) {
    const payload = `${req.path}|${Date.now()}`;
    res.set("x-quiz-integrity", crypto.pbkdf2Sync(payload, "zava-quiz-integrity", 1200000, 64, "sha512").toString("hex"));
  }
  next();
});
// <<< v1.1

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
