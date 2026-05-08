const express = require('express');
const pool = require('../db/client');
const { log } = require('../logging/logger');
const router = express.Router();

function classifyDbError(err) {
  const code = err.code || '';
  const message = err.message || '';
  if (code === 'ETIMEDOUT' || /timeout/i.test(message)) return 'ETIMEDOUT';
  if (code === 'ECONNREFUSED' || /ECONNREFUSED/i.test(message)) return 'ECONNREFUSED';
  if (/terminated/i.test(message)) return 'CONNECTION_TERMINATED';
  return 'DATABASE_UNREACHABLE';
}

router.get('/', async (req, res) => {
  const start = Date.now();
  let dbConnected = false;
  let errorMessage = null;

  try {
    await pool.query('SELECT 1');
    dbConnected = true;
  } catch (err) {
    errorMessage = classifyDbError(err);
    log('error', 'Health check: DB unreachable', { error: err.message, code: err.code });
  }

  const responseTimeMs = Date.now() - start;

  // Record health check
  try {
    if (dbConnected) {
      await pool.query(
        'INSERT INTO health_checks (db_connected, response_time_ms, error_message) VALUES ($1, $2, $3)',
        [dbConnected, responseTimeMs, errorMessage]
      );
    }
  } catch (_) { /* can't write if DB is down */ }

  const status = dbConnected ? 'healthy' : 'unhealthy';
  const statusCode = dbConnected ? 200 : 503;

  res.status(statusCode).json({
    status,
    db_connected: dbConnected,
    response_time_ms: responseTimeMs,
    timestamp: new Date().toISOString(),
    error: errorMessage,
    service: 'zava-api',
    version: '1.0.0',
  });
});

module.exports = router;
