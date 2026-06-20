const { Pool } = require('pg');
const { DefaultAzureCredential } = require('@azure/identity');

const credential = new DefaultAzureCredential();
const PG_SCOPE = 'https://ossrdbms-aad.database.windows.net/.default';

// Cache the token and deduplicate concurrent refreshes
let cachedToken = null;
let pendingRefresh = null;

async function getAccessToken() {
  if (cachedToken && cachedToken.expiresOnTimestamp > Date.now() + 300_000) {
    return cachedToken.token;
  }
  if (!pendingRefresh) {
    pendingRefresh = credential.getToken(PG_SCOPE)
      .then(token => { cachedToken = token; return token; })
      .catch(err => { cachedToken = null; throw err; })
      .finally(() => { pendingRefresh = null; });
  }
  const token = await pendingRefresh;
  return token.token;
}

const pool = new Pool({
  host: process.env.DB_HOST || 'localhost',
  port: parseInt(process.env.DB_PORT || '5432'),
  database: process.env.DB_NAME || 'zava_store',
  user: process.env.DB_USER || process.env.AZURE_CLIENT_ID || 'zavaadmin',
  password: getAccessToken,  // pg calls this function before each connect
  // Azure PG Flexible Server presents a publicly-trusted DigiCert cert, so
  // verification works out-of-the-box. Set DB_SSL_REJECT_UNAUTHORIZED=false
  // only for local/dev scenarios with a self-signed cert.
  ssl: { rejectUnauthorized: process.env.DB_SSL_REJECT_UNAUTHORIZED !== 'false' },
  max: 10,
  idleTimeoutMillis: 30000,
  connectionTimeoutMillis: 5000,
});

pool.on('error', (err) => {
  console.error(JSON.stringify({ level: 'error', message: 'Unexpected PostgreSQL pool error', error: err.message, code: err.code, timestamp: new Date().toISOString() }));
});

module.exports = pool;
