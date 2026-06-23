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
  appInsights.defaultClient.context.tags[appInsights.defaultClient.context.keys.cloudRole] = "course-api";
}
const express = require("express");

const app = express();
const PORT = process.env.PORT || 8080;
const SERVICE = "course-api";

// McGraw-Hill-style course catalog for the Zava Learning platform.
const COURSES = [
  { id: "BIO-101", title: "Introduction to Biology", discipline: "Science", units: 12, enrolled: 4821 },
  { id: "MATH-220", title: "Calculus II", discipline: "Mathematics", units: 10, enrolled: 3110 },
  { id: "HIST-180", title: "World History Since 1500", discipline: "Humanities", units: 8, enrolled: 2675 },
  { id: "CHEM-110", title: "General Chemistry", discipline: "Science", units: 14, enrolled: 3902 },
  { id: "ECON-201", title: "Principles of Microeconomics", discipline: "Business", units: 9, enrolled: 5240 },
  { id: "PSY-100", title: "Foundations of Psychology", discipline: "Social Science", units: 7, enrolled: 6188 }
];

app.get("/health", (_req, res) => {
  res.status(200).json({ status: "ok", service: SERVICE, ts: new Date().toISOString() });
});

app.get("/courses", (_req, res) => {
  res.json({ count: COURSES.length, courses: COURSES });
});

app.get("/courses/:id", (req, res) => {
  const course = COURSES.find(c => c.id.toLowerCase() === req.params.id.toLowerCase());
  if (!course) return res.status(404).json({ error: "course_not_found", id: req.params.id });
  res.json(course);
});

app.listen(PORT, () => {
  console.log(`[${SERVICE}] listening on :${PORT}`);
});
