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
  appInsights.defaultClient.context.tags[appInsights.defaultClient.context.keys.cloudRole] = "assessment-api";
}
const express = require("express");

const app = express();
app.use(express.json());

// Per-request timing telemetry -> container console -> Log Analytics. Enables latency
// queries/alerts (ContainerAppConsoleLogs_CL ... extract "ms=").
app.use((req, res, next) => {
  const start = process.hrtime.bigint();
  res.on("finish", () => {
    const ms = Math.round(Number(process.hrtime.bigint() - start) / 1e6);
    console.log(`req method=${req.method} path=${req.path} status=${res.statusCode} ms=${ms}`);
  });
  next();
});
// ZAVA-PERF-INJECT-POINT (chaos/break-perf.ps1 inserts the regression below this line)

const PORT = process.env.PORT || 8080;
const SERVICE = "assessment-api";
// Optional upstream dependency: validates the course exists before serving a quiz.
const COURSE_API_URL = process.env.COURSE_API_URL || "";

// Static quiz bank keyed by course id.
const QUIZZES = {
  "BIO-101": [
    { q: "The basic unit of life is the?", options: ["Atom", "Cell", "Organ", "Tissue"], answer: 1 },
    { q: "DNA is found primarily in the?", options: ["Nucleus", "Membrane", "Cytoplasm", "Wall"], answer: 0 }
  ],
  "MATH-220": [
    { q: "The integral of 1/x dx is?", options: ["ln|x|+C", "x^2+C", "-1/x^2+C", "e^x+C"], answer: 0 },
    { q: "A series that approaches a limit is said to?", options: ["Diverge", "Oscillate", "Converge", "Repeat"], answer: 2 }
  ],
  "ECON-201": [
    { q: "Demand curves typically slope?", options: ["Upward", "Downward", "Flat", "Vertical"], answer: 1 },
    { q: "Opportunity cost is the value of the?", options: ["Best alternative", "Total spend", "Sunk cost", "Tax"], answer: 0 }
  ]
};

function defaultQuiz(courseId) {
  return [
    { q: `Sample question 1 for ${courseId}`, options: ["A", "B", "C", "D"], answer: 0 },
    { q: `Sample question 2 for ${courseId}`, options: ["A", "B", "C", "D"], answer: 2 }
  ];
}

app.get("/health", (_req, res) => {
  res.status(200).json({ status: "ok", service: SERVICE, ts: new Date().toISOString() });
});

app.get("/quiz/:courseId", async (req, res) => {
  const courseId = req.params.courseId.toUpperCase();
  if (COURSE_API_URL) {
    try {
      const r = await fetch(`${COURSE_API_URL}/courses/${courseId}`, { signal: AbortSignal.timeout(4000) });
      if (r.status === 404) return res.status(404).json({ error: "course_not_found", courseId });
    } catch (err) {
      // Upstream course-api unreachable (e.g. blocked network path) -> surface as 502.
      return res.status(502).json({ error: "course_lookup_failed", detail: String(err) });
    }
  }
  const quiz = QUIZZES[courseId] || defaultQuiz(courseId);
  res.json({ courseId, questionCount: quiz.length, questions: quiz.map(({ q, options }) => ({ q, options })) });
});

app.post("/quiz/:courseId/submit", (req, res) => {
  const courseId = req.params.courseId.toUpperCase();
  const quiz = QUIZZES[courseId] || defaultQuiz(courseId);
  const answers = Array.isArray(req.body && req.body.answers) ? req.body.answers : [];
  let correct = 0;
  quiz.forEach((item, i) => { if (answers[i] === item.answer) correct++; });
  res.json({ courseId, total: quiz.length, correct, scorePct: Math.round((correct / quiz.length) * 100) });
});

app.listen(PORT, () => {
  console.log(`[${SERVICE}] listening on :${PORT}`);
});
