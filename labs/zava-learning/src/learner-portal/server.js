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
  appInsights.defaultClient.context.tags[appInsights.defaultClient.context.keys.cloudRole] = "learner-portal";
}
const express = require("express");

const app = express();
const PORT = process.env.PORT || 8080;
const SERVICE = "learner-portal";
const COURSE_API_URL = process.env.COURSE_API_URL || "http://course-api";
const ASSESSMENT_API_URL = process.env.ASSESSMENT_API_URL || "http://assessment-api";

async function getJson(url, timeoutMs = 4000) {
  const r = await fetch(url, { signal: AbortSignal.timeout(timeoutMs) });
  if (!r.ok) {
    const e = new Error(`upstream ${r.status}`);
    e.status = r.status;
    throw e;
  }
  return r.json();
}

app.get("/health", (_req, res) => {
  res.status(200).json({ status: "ok", service: SERVICE, ts: new Date().toISOString() });
});

// Liveness of the full path the student depends on (portal -> apis).
app.get("/ready", async (_req, res) => {
  try {
    await getJson(`${COURSE_API_URL}/health`, 3000);
    await getJson(`${ASSESSMENT_API_URL}/health`, 3000);
    res.status(200).json({ status: "ready" });
  } catch (err) {
    res.status(503).json({ status: "degraded", detail: String(err) });
  }
});

app.get("/api/courses", async (_req, res) => {
  try {
    res.json(await getJson(`${COURSE_API_URL}/courses`));
  } catch (err) {
    console.error(`[${SERVICE}] course catalog error:`, String(err));
    res.status(502).json({ error: "course_catalog_unavailable" });
  }
});

// Quiz launch — the student-critical action. Failure here is the headline symptom.
app.get("/api/quiz/:courseId", async (req, res) => {
  try {
    res.json(await getJson(`${ASSESSMENT_API_URL}/quiz/${encodeURIComponent(req.params.courseId)}`, 5000));
  } catch (err) {
    console.error(`[${SERVICE}] quiz launch failed for ${req.params.courseId}:`, String(err));
    res.status(502).json({ error: "quiz_launch_failed", courseId: req.params.courseId });
  }
});

app.get("/", (_req, res) => {
  res.type("html").send(`<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Zava Learning</title>
<style>
 body{font-family:system-ui,Segoe UI,Arial,sans-serif;margin:0;background:#f5f7fa;color:#1b2733}
 header{background:#0b3d63;color:#fff;padding:18px 28px;font-size:22px;font-weight:600}
 main{max-width:880px;margin:24px auto;padding:0 16px}
 .grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(240px,1fr));gap:16px}
 .card{background:#fff;border:1px solid #e1e8ef;border-radius:10px;padding:16px}
 .card h3{margin:0 0 6px;font-size:16px}
 .meta{color:#5b6b7b;font-size:13px;margin-bottom:12px}
 button{background:#0b6bcb;color:#fff;border:0;border-radius:6px;padding:8px 12px;cursor:pointer}
 #quiz{margin-top:20px;padding:16px;background:#fff;border-radius:10px;border:1px solid #e1e8ef;display:none}
 .err{color:#b00020;font-weight:600}
</style></head>
<body>
<header>Zava Learning &mdash; Student Portal</header>
<main>
  <p>Welcome back. Choose a course and launch its quiz.</p>
  <div id="courses" class="grid">Loading courses&hellip;</div>
  <div id="quiz"></div>
</main>
<script>
async function loadCourses(){
  const el=document.getElementById('courses');
  try{
    const r=await fetch('/api/courses'); if(!r.ok) throw new Error(r.status);
    const data=await r.json();
    el.innerHTML=data.courses.map(c=>
      '<div class="card"><h3>'+c.title+'</h3><div class="meta">'+c.id+' &middot; '+c.discipline+'</div>'+
      '<button onclick="launchQuiz(\\''+c.id+'\\')">Launch quiz</button></div>').join('');
  }catch(e){ el.innerHTML='<p class="err">Course catalog is unavailable right now.</p>'; }
}
async function launchQuiz(id){
  const q=document.getElementById('quiz'); q.style.display='block';
  q.innerHTML='Launching quiz for '+id+'&hellip;';
  try{
    const r=await fetch('/api/quiz/'+id); if(!r.ok) throw new Error(r.status);
    const data=await r.json();
    q.innerHTML='<h3>Quiz: '+data.courseId+'</h3>'+data.questions.map((x,i)=>
      '<p><b>'+(i+1)+'. '+x.q+'</b><br>'+x.options.join(' &nbsp; ')+'</p>').join('');
  }catch(e){ q.innerHTML='<p class="err">We could not launch this quiz. Please try again shortly.</p>'; }
}
loadCourses();
</script>
</body></html>`);
});

app.listen(PORT, () => {
  console.log(`[${SERVICE}] listening on :${PORT}`);
});
