// Configure the Zava Learning SRE Agent via the public Azure MCP SRE tools (azmcp).
//
// Bicep deploys the agent; THIS script applies all agent configuration:
//   MCP connector -> skills -> PagerDuty incident connector -> response plan -> knowledge base
// (+ ServiceNow connector/tools when SERVICENOW creds are present).
//
// We invoke the native azmcp binary directly (not `npx`) because Node refuses to
// execFile a .cmd shim with shell:false, and we must pass multi-line skill/runbook
// content verbatim (PowerShell/`npx` mangle embedded newlines).
//
// Usage:  node scripts/configure-agent.mjs
// Env/args: AGENT, RESOURCE_GROUP, AZURE_SUBSCRIPTION_ID (else read from the values below).
// Secrets are read from sre-config/.env (gitignored): PAGERDUTY_API_TOKEN, PAGERDUTY_SUBDOMAIN,
//   GITHUB_REPO, SERVICENOW_URL/USER/PASS.

import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.join(__dirname, "..");

// ---- inputs -------------------------------------------------------------
const AGENT = process.env.AGENT || "sre-zavalearning-ops";
const RG = process.env.RESOURCE_GROUP || "rg-zava-learning-demo";
const SUB = process.env.AZURE_SUBSCRIPTION_ID || "";
if (!SUB) {
  console.error("Set AZURE_SUBSCRIPTION_ID to your lab subscription before running configure-agent.mjs.");
  process.exit(1);
}
process.env.AZURE_SUBSCRIPTION_ID = SUB;

// ---- load gitignored secrets from sre-config/.env -----------------------
const envFile = path.join(repoRoot, "sre-config", ".env");
if (fs.existsSync(envFile)) {
  for (const line of fs.readFileSync(envFile, "utf8").split(/\r?\n/)) {
    const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)$/);
    if (m && !line.trimStart().startsWith("#")) process.env[m[1]] = m[2];
  }
}
const REPO = process.env.GITHUB_REPO || "";

// ---- locate the azmcp native binary -------------------------------------
function findAzmcp() {
  if (process.env.AZMCP_EXE && fs.existsSync(process.env.AZMCP_EXE)) return process.env.AZMCP_EXE;
  const exe = os.platform() === "win32" ? "azmcp.exe" : "azmcp";
  let root;
  try {
    root = execFileSync(os.platform() === "win32" ? "npm.cmd" : "npm", ["root", "-g"], { encoding: "utf8", shell: true }).trim();
  } catch { root = ""; }
  const base = path.join(root, "@azure", "mcp", "node_modules", "@azure");
  if (fs.existsSync(base)) {
    for (const d of fs.readdirSync(base)) {
      const cand = path.join(base, d, "dist", exe);
      if (fs.existsSync(cand)) return cand;
    }
  }
  throw new Error("azmcp not found. Run: npm i -g @azure/mcp@latest  (or set AZMCP_EXE)");
}
const AZMCP = findAzmcp();

// srectl (the full SRE Agent CLI, installed as a dotnet global tool) applies skills with
// their structured `tools` list — azmcp `skills create` cannot. See applySkillsWithSrectl.
function findSrectl() {
  if (process.env.SRECTL_EXE && fs.existsSync(process.env.SRECTL_EXE)) return process.env.SRECTL_EXE;
  const exe = os.platform() === "win32" ? "srectl.exe" : "srectl";
  const dotnetTool = path.join(os.homedir(), ".dotnet", "tools", exe);
  return fs.existsSync(dotnetTool) ? dotnetTool : exe;
}
const SRECTL = findSrectl();
console.log(`azmcp: ${AZMCP}`);
console.log(`srectl: ${SRECTL}`);
console.log(`target: ${AGENT}  rg=${RG}\n`);

// ---- helper -------------------------------------------------------------
function run(label, args) {
  process.stdout.write(`-> ${label} ... `);
  try {
    const out = execFileSync(AZMCP, args, { encoding: "utf8", maxBuffer: 32 * 1024 * 1024 });
    let status = "?";
    try { status = JSON.parse(out.slice(out.indexOf("{"))).status; } catch {}
    console.log(`status ${status}`);
    return true;
  } catch (e) {
    const msg = (e.stdout || "") + (e.stderr || "") + (e.message || "");
    console.log("FAILED");
    console.log(msg.split(/\r?\n/).slice(0, 8).join("\n"));
    return false;
  }
}
const base = ["--agent", AGENT, "--resource-group", RG];
const SN_URL = process.env.SERVICENOW_URL || "";
const SN_USER = process.env.SERVICENOW_USER || "";
const SN_PASS = process.env.SERVICENOW_PASS || "";

// ---- discover live resource identifiers ---------------------------------
// Pre-resolve the exact IDs the agent would otherwise have to look up at runtime, so the
// knowledge base (and skills) can hand them to the agent directly and save a tool call.
// Critically, `az monitor log-analytics query --workspace` and `az monitor app-insights
// query --app` want the workspace GUID / App Insights appId, NOT the resource name. Passing
// the name returns ResourceNotFound, which the runtime escalates to a human approval
// (PendingAuthorization) and stalls the investigation. Resolved at apply time, so these
// always match the current deployment (the resource-name token changes on every redeploy).
const AZ_BIN = os.platform() === "win32" ? "az.cmd" : "az";
function azJson(args) {
  try {
    return JSON.parse(execFileSync(AZ_BIN, [...args, "--subscription", SUB, "-o", "json"],
      { encoding: "utf8", shell: os.platform() === "win32", maxBuffer: 32 * 1024 * 1024 }));
  } catch { return null; }
}
// Pick the PLATFORM resource (log-zava*/appi-zava*), never the agent's own workspace/app-insights.
const pick = (arr, re) => (Array.isArray(arr) ? arr.find((x) => re.test(x?.name || "")) : null) || {};
const law = pick(azJson(["monitor", "log-analytics", "workspace", "list", "-g", RG,
  "--query", "[].{name:name,customerId:customerId}"]), /^log-zava/);
const appi = pick(azJson(["monitor", "app-insights", "component", "show", "-g", RG,
  "--query", "[].{name:name,appId:appId}"]), /^appi-zava/);
const acr = pick(azJson(["acr", "list", "-g", RG, "--query", "[].{name:name}"]), /^acr/);
const cae = pick(azJson(["containerapp", "env", "list", "-g", RG, "--query", "[].{name:name}"]), /./);
const LAW_NAME = law.name || "", LAW_GUID = law.customerId || "";
const APPI_NAME = appi.name || "", APPI_APPID = appi.appId || "";
const ACR_NAME = acr.name || "", CAE_NAME = cae.name || "";
if (LAW_GUID) console.log(`law: ${LAW_NAME} (${LAW_GUID})`);
if (APPI_APPID) console.log(`appinsights: ${APPI_NAME} (${APPI_APPID})`);
if (!LAW_GUID || !APPI_APPID) console.log("(WARNING: some resource IDs unresolved; knowledge placeholders will be blank)");

// ServiceNow creds are injected into staged tool copies at apply time (never committed): the
// PythonTool sandbox cannot read env/.env, so the creds must be literal in functionCode.
const sub = (s) => s
  .split("@@RG@@").join(RG)
  .split("@@REPO@@").join(REPO)
  .split("@@LAW_NAME@@").join(LAW_NAME)
  .split("@@LAW_GUID@@").join(LAW_GUID)
  .split("@@APPINSIGHTS_NAME@@").join(APPI_NAME)
  .split("@@APPINSIGHTS_APPID@@").join(APPI_APPID)
  .split("@@ACR_NAME@@").join(ACR_NAME)
  .split("@@CAE_NAME@@").join(CAE_NAME)
  .split("@@SERVICENOW_URL@@").join(SN_URL)
  .split("@@SERVICENOW_USER@@").join(SN_USER)
  .split("@@SERVICENOW_PASS@@").join(SN_PASS);

// ---- tools + skills + agent via srectl ----------------------------------
// azmcp `sreagent skills create` cannot set a skill's structured `tools` list (only
// name/description/content), so the portal shows no tools selected. srectl applies
// SKILL.md frontmatter (including `tools:`) and ExtendedAgentTool YAMLs to the same store
// (/api/v2/extendedAgent/*). We register custom PythonTools FIRST so skills that reference
// them (e.g. servicenow-change-management) resolve, then apply each skill, then the custom
// ExtendedAgent (whose allowedSkills must resolve against the just-applied skills). Sources:
//   sre-config/tools/<name>/<name>.yaml             (ExtendedAgentTool PythonTools)
//   sre-config/agent-config/skills/<name>/SKILL.md  (with @@RG@@/@@REPO@@ placeholders)
//   sre-config/agent-config/agents/<name>/<name>.yaml  (ExtendedAgent; @@RG@@/@@REPO@@)
// We stage substituted copies in a temp workspace and temporarily point srectl's global
// config (~/.sreagent/config.json) at this agent's data-plane endpoint (backed up, restored).
function applyToolsSkillsAndAgentsWithSrectl() {
  const toolSrc = path.join(repoRoot, "sre-config", "tools");
  const skillSrc = path.join(repoRoot, "sre-config", "agent-config", "skills");
  const agentSrc = path.join(repoRoot, "sre-config", "agent-config", "agents");

  const tools = fs.existsSync(toolSrc)
    ? fs.readdirSync(toolSrc, { withFileTypes: true })
        .filter((d) => d.isDirectory() && fs.existsSync(path.join(toolSrc, d.name, `${d.name}.yaml`)))
        .map((d) => d.name)
    : [];
  const skills = fs.existsSync(skillSrc)
    ? fs.readdirSync(skillSrc, { withFileTypes: true })
        .filter((d) => d.isDirectory() && fs.existsSync(path.join(skillSrc, d.name, "SKILL.md")))
        .map((d) => d.name)
    : [];
  // Custom agents (ExtendedAgent YAML): scope skills via allowedSkills and prescribe the
  // ordered runbook via instructions; the incident filter routes to one by name (handlingAgent).
  const agents = fs.existsSync(agentSrc)
    ? fs.readdirSync(agentSrc, { withFileTypes: true })
        .filter((d) => d.isDirectory() && fs.existsSync(path.join(agentSrc, d.name, `${d.name}.yaml`)))
        .map((d) => d.name)
    : [];
  if (tools.length === 0 && skills.length === 0 && agents.length === 0) { console.log("-> tools/skills/agents ... none found, skipped"); return; }
  if (!agentEndpoint) { console.log("-> tools/skills/agents ... skipped (agent data-plane endpoint not resolved)"); return; }

  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "zava-srectl-"));
  for (const name of tools) {
    const dst = path.join(tmp, "tools", name);
    fs.mkdirSync(dst, { recursive: true });
    fs.writeFileSync(path.join(dst, `${name}.yaml`), sub(fs.readFileSync(path.join(toolSrc, name, `${name}.yaml`), "utf8")));
  }
  for (const name of skills) {
    const dst = path.join(tmp, "skills", name);
    fs.mkdirSync(dst, { recursive: true });
    fs.writeFileSync(path.join(dst, "SKILL.md"), sub(fs.readFileSync(path.join(skillSrc, name, "SKILL.md"), "utf8")));
  }
  for (const name of agents) {
    const dst = path.join(tmp, "agents", name);
    fs.mkdirSync(dst, { recursive: true });
    fs.writeFileSync(path.join(dst, `${name}.yaml`), sub(fs.readFileSync(path.join(agentSrc, name, `${name}.yaml`), "utf8")));
  }

  const cfgPath = path.join(os.homedir(), ".sreagent", "config.json");
  const backup = fs.existsSync(cfgPath) ? fs.readFileSync(cfgPath, "utf8") : null;
  fs.mkdirSync(path.dirname(cfgPath), { recursive: true });
  const now = new Date().toISOString();
  fs.writeFileSync(cfgPath, JSON.stringify({ resource_url: agentEndpoint, auth_required: true, last_updated: now, created_at: now }, null, 2));

  const applyOne = (kind, name) => {
    process.stdout.write(`-> ${kind} ${name} (srectl) ... `);
    try {
      execFileSync(SRECTL, [kind, "apply", "--name", name, "--quiet"], { cwd: tmp, encoding: "utf8", maxBuffer: 32 * 1024 * 1024 });
      console.log("applied");
    } catch (e) {
      console.log("FAILED");
      console.log(((e.stdout || "") + (e.stderr || "") + (e.message || "")).split(/\r?\n/).slice(0, 8).join("\n"));
    }
  };

  try {
    for (const name of tools) applyOne("tool", name);
    for (const name of skills) applyOne("skill", name);
    // Agents last: their allowedSkills must resolve against skills applied just above.
    for (const name of agents) applyOne("agent", name);
  } finally {
    if (backup !== null) fs.writeFileSync(cfgPath, backup); else fs.rmSync(cfgPath, { force: true });
    fs.rmSync(tmp, { recursive: true, force: true });
  }
}

// ---- ARM helpers --------------------------------------------------------
// The agent's incident-management type and incident filters (response plans) are
// configured as ARM child resources / properties. The azmcp `incidents plans_create`
// targets a data-plane route that is read-only on current agent builds (HTTP 405),
// so we apply these two pieces declaratively over ARM instead.
const API_VERSION = "2025-05-01-preview";
const ARM = "https://management.azure.com";
const DATAPLANE_AUDIENCE = "https://azuresre.ai";
const AZ = os.platform() === "win32" ? "az.cmd" : "az";
const AGENT_URL = `${ARM}/subscriptions/${SUB}/resourceGroups/${RG}/providers/Microsoft.App/agents/${AGENT}`;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function azToken(resource) {
  return execFileSync(AZ, ["account", "get-access-token", "--resource", resource, "--query", "accessToken", "-o", "tsv"],
    { encoding: "utf8", shell: os.platform() === "win32" }).trim();
}
async function arm(method, urlNoApi, body) {
  const r = await fetch(`${urlNoApi}?api-version=${API_VERSION}`, {
    method,
    headers: { Authorization: `Bearer ${azToken(ARM)}`, "Content-Type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await r.text();
  return { ok: r.ok, status: r.status, text };
}

// Resolve the PagerDuty "on behalf of" user email used for the From header on write
// actions. Prefer an explicit env value; otherwise look up the account's first user
// (typically the owner) via the PagerDuty REST API.
async function resolvePagerDutyOboUser() {
  const explicit = (process.env.PAGERDUTY_OBO_USER || process.env.PAGERDUTY_FROM_EMAIL || "").trim();
  if (explicit) return explicit;
  const token = process.env.PAGERDUTY_API_TOKEN;
  if (!token) return null;
  try {
    const r = await fetch("https://api.pagerduty.com/users?limit=1", {
      headers: { Authorization: `Token token=${token}`, Accept: "application/vnd.pagerduty+json;version=2" },
    });
    if (!r.ok) return null;
    return (await r.json())?.users?.[0]?.email ?? null;
  } catch {
    return null;
  }
}

// Resolve the agent's data-plane endpoint once; used by srectl (skills) and the
// PagerDuty platform-sync wait below.
let agentEndpoint = null;
try {
  const r = await arm("GET", AGENT_URL);
  agentEndpoint = JSON.parse(r.text)?.properties?.agentEndpoint ?? null;
} catch {}

// ---- 1. Microsoft Learn MCP connector -----------------------------------
run("connector microsoft-learn", ["sreagent", "connectors", "create_mcp", ...base,
  "--name", "microsoft-learn", "--type", "http", "--endpoint", "https://learn.microsoft.com/api/mcp"]);

// ---- 2. Custom tools + skills + agent (with structured tools) -----------
applyToolsSkillsAndAgentsWithSrectl();

// ---- 3. PagerDuty: incident connector + incident-management platform ------
// setup_pagerduty creates the "pagerduty" MCP connector used by the
// pagerduty_incident_management skill (ack/note/resolve). The agent's incident
// platform (type/connectionKey) is a top-level ARM property, set separately so
// the runtime scans PagerDuty and accepts PagerDuty incident filters.
if (process.env.PAGERDUTY_API_TOKEN) {
  const args = ["sreagent", "incidents", "setup_pagerduty", ...base,
    "--name", "pagerduty", "--api-key-env", "PAGERDUTY_API_TOKEN"];
  if (process.env.PAGERDUTY_SUBDOMAIN) args.push("--subdomain", process.env.PAGERDUTY_SUBDOMAIN);
  run("pagerduty connector", args);

  process.stdout.write("-> pagerduty incident platform (ARM) ... ");
  // Write actions (acknowledge/resolve/add-note) require PagerDuty's "From" header,
  // which the runtime sends from IncidentManagementSettings.OboUser. Without it PD returns
  // illegitimate_requester_error / code 1027. Resolve a real PD user email: explicit env
  // (PAGERDUTY_FROM_EMAIL/PAGERDUTY_OBO_USER) else the account's first/owner user.
  const oboUser = await resolvePagerDutyOboUser();
  if (oboUser) console.log(`(obo user: ${oboUser})`);
  else console.log("(WARNING: no PagerDuty obo user resolved; write actions will fail)");
  const imConfig = {
    type: "PagerDuty",
    connectionName: "pagerduty",
    connectionKey: process.env.PAGERDUTY_API_TOKEN,
  };
  if (oboUser) imConfig.oboUser = oboUser;
  process.stdout.write("-> pagerduty incident platform PATCH ... ");
  const imRes = await arm("PATCH", AGENT_URL, {
    properties: {
      incidentManagementConfiguration: imConfig,
    },
  });
  console.log(imRes.ok ? `status ${imRes.status}` : `FAILED ${imRes.status}\n${imRes.text.slice(0, 400)}`);

  // The runtime syncs the platform from ARM into its reloadable settings store
  // asynchronously; the incident-filter PUT is rejected until it reports PagerDuty.
  process.stdout.write("-> waiting for runtime to sync incident platform ");
  const endpoint = agentEndpoint;
  let synced = false;
  for (let i = 0; i < 30 && !synced; i++) {
    try {
      const r = await fetch(`${endpoint}/api/v1/incidentplayground/incidentPlatformType`,
        { headers: { Authorization: `Bearer ${azToken(DATAPLANE_AUDIENCE)}` } });
      if ((await r.json())?.incidentPlatformType === "PagerDuty") { synced = true; break; }
    } catch {}
    process.stdout.write(".");
    await sleep(10000);
  }
  console.log(synced ? " ok" : " timed out (filter PUT may fail; re-run script)");
} else {
  console.log("-> pagerduty connector ... skipped (PAGERDUTY_API_TOKEN not set)");
}

// ---- 4. Incident response plan / trigger (symptom-keyed, autonomous) ------
// Created as a Microsoft.App/agents/incidentFilters child resource over ARM.
// Symptom-only: titleContains "Zava" routes every student-facing Zava incident to the
// custom zava-incident-responder agent, which scopes the skill menu (allowedSkills + system
// skills) and prescribes the ordered runbook (triage -> mitigate -> RCA -> evidence ->
// recommendations -> PR -> Change Request -> report) via its instructions + critic-on-handoff
// gate. The cause-level split (NSG vs LB vs AppGW vs app) is decided inside the skills from
// telemetry, never by alert name.
const filterSpec = {
  incidentPlatform: process.env.PAGERDUTY_API_TOKEN ? "PagerDuty" : "AzMonitor",
  titleContains: "Zava",
  agentMode: "autonomous",
  handlingAgent: "zava-incident-responder",
  isEnabled: true,
  maxAutomatedInvestigationAttempts: 3,
};
process.stdout.write("-> incident filter zava-learning-response (ARM) ... ");
const fRes = await arm("PUT", `${AGENT_URL}/incidentFilters/zava-learning-response`, {
  properties: { value: Buffer.from(JSON.stringify(filterSpec)).toString("base64") },
});
console.log(fRes.ok ? `status ${fRes.status}` : `FAILED ${fRes.status}\n${fRes.text.slice(0, 400)}`);

// ---- 5. Knowledge base --------------------------------------------------
const kbFile = path.join(repoRoot, "sre-config", "knowledge-base", "zava-learning-architecture.md");
if (fs.existsSync(kbFile)) {
  run("knowledge zava-learning-architecture", ["sreagent", "docs", "memories_add", ...base,
    "--name", "zava-learning-architecture", "--content", sub(fs.readFileSync(kbFile, "utf8"))]);
}

// Reporting standard + report skeleton — retrieved by the reporting skills (rca-analysis,
// evidence-before-after, recommendations-next-steps, zava-reporting) via SearchMemory.
for (const [name, rel] of [
  ["zava-brand", path.join("sre-config", "templates", "zava-brand.md")],
  ["zava-report-template", path.join("sre-config", "templates", "zava-report-template.md")],
  ["zava-audit-report", path.join("sre-config", "templates", "zava-audit-report.md")],
  ["zava-redaction", path.join("sre-config", "templates", "zava-redaction.md")],
]) {
  const f = path.join(repoRoot, rel);
  if (fs.existsSync(f)) {
    run(`knowledge ${name}`, ["sreagent", "docs", "memories_add", ...base,
      "--name", name, "--content", sub(fs.readFileSync(f, "utf8"))]);
  }
}

// ---- 6. Knowledge already applied above. ServiceNow integration is change-management
// only: it is delivered through the CreateServiceNowChangeRequest / UploadServiceNowAttachment
// PythonTools (applied in step 2, owned by the servicenow-change-management skill). The PythonTool
// sandbox cannot read env vars, so SERVICENOW_URL/USER/PASS are injected as literals into the tool
// functionCode at apply time by sub() from the gitignored sre-config/.env (committed source keeps
// @@SERVICENOW_*@@ placeholders). We deliberately do NOT create a ServiceNow *incident* connector
// here — incident management is PagerDuty's job (step 3/4).

// ---- 6. Weekly governance audit scheduled tasks (VERIFY-ONLY) ----------
// Three weekly audits (NSG, RBAC, cost), each run by its own custom ExtendedAgent (applied in
// step 2: zava-nsg-auditor / zava-rbac-auditor / zava-cost-analyst) and producing a branded PPTX
// via the zava-audit-report skill.
//
// These scheduled tasks are USER-MANAGED and intentionally NOT created, deleted, or edited here.
// This script only verifies the expected tasks exist by name (the demo's --audits launches them by
// name). The reference YAML under sre-config/scheduled-tasks/ is kept for documentation only.
// Task name == YAML file stem == spec.name by construction.
async function applyScheduledTasks() {
  const taskSrc = path.join(repoRoot, "sre-config", "scheduled-tasks");
  const expected = fs.existsSync(taskSrc)
    ? fs.readdirSync(taskSrc).filter((f) => /\.ya?ml$/i.test(f)).map((f) => f.replace(/\.ya?ml$/i, ""))
    : [];
  if (expected.length === 0) { console.log("-> scheduled tasks ... none expected, skipped"); return; }
  if (!agentEndpoint) { console.log("-> scheduled tasks ... skipped (agent data-plane endpoint not resolved)"); return; }

  const epBase = agentEndpoint.replace(/\/+$/, "");
  const liveNames = new Set();
  try {
    const token = azToken(DATAPLANE_AUDIENCE);
    const r = await fetch(`${epBase}/api/v1/scheduledtasks`, { headers: { Authorization: `Bearer ${token}` } });
    if (r.ok) {
      const list = await r.json();
      if (Array.isArray(list)) for (const t of list) { if (t?.name) liveNames.add(t.name); }
    }
  } catch {}

  // Verify only — never create/delete/edit (these tasks are user-managed).
  for (const name of expected) {
    console.log(liveNames.has(name)
      ? `-> scheduledtask ${name} (user-managed) ... present`
      : `-> scheduledtask ${name} (user-managed) ... MISSING — create it manually (reference YAML in sre-config/scheduled-tasks/)`);
  }
}
await applyScheduledTasks();

console.log("\nDone. Verify with: node scripts/configure-agent.mjs (idempotent) or `azmcp sreagent skills list`.");
