// Minimal SQL helper for the SRE Agent / operators.
// Usage (inside the API container):
//   node bin/run-sql.js "<SQL>"
//
// Why this file exists: PG Flex is private-network only and the SRE Agent has
// no VNet access (deliberate — see README "Design constraint"). DDL like
// CREATE INDEX is data-plane only (no managed-PG control plane exposes it),
// so the agent tunnels SQL through this api pod via
// `az aks command invoke ... kubectl exec ... -- node bin/run-sql.js "<SQL>"`.
// Auth reuses the same DefaultAzureCredential + ossrdbms-aad token pattern as
// db/client.js — the pod's federated workload identity is already a PG admin,
// so no passwords and no new identity to grant.
const { Pool } = require('pg');
const { DefaultAzureCredential } = require('@azure/identity');

const sql = process.argv[2];
if (!sql) {
  console.error('Usage: node bin/run-sql.js "<SQL>"');
  process.exit(2);
}

const credential = new DefaultAzureCredential();
const PG_SCOPE = 'https://ossrdbms-aad.database.windows.net/.default';

async function getAccessToken() {
  const token = await credential.getToken(PG_SCOPE);
  return token.token;
}

const pool = new Pool({
  host: process.env.DB_HOST,
  port: parseInt(process.env.DB_PORT || '5432'),
  database: process.env.DB_NAME,
  user: process.env.DB_USER || process.env.AZURE_CLIENT_ID,
  password: getAccessToken,
  ssl: { rejectUnauthorized: process.env.DB_SSL_REJECT_UNAUTHORIZED !== 'false' },
  max: 1,
  connectionTimeoutMillis: 10000,
});

(async () => {
  try {
    const result = await pool.query(sql);
    // Always print a structured envelope so the agent / scripts can parse a
    // consistent shape. Never print result.command — for SELECTs that return
    // 0 rows, that prints the literal string "SELECT", which a caller
    // checking "does the index exist?" would misread as a positive result.
    console.log(JSON.stringify({
      command: result.command,
      rowCount: result.rowCount,
      rows: result.rows ?? [],
    }));
  } catch (err) {
    console.error(err.message);
    process.exitCode = 1;
  } finally {
    try { await pool.end(); } catch (_) { /* ignore */ }
  }
})();
