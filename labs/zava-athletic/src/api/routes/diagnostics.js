const express = require('express');
const pool = require('../db/client');
const { log } = require('../logging/logger');
const router = express.Router();

router.get('/', async (req, res) => {
  const diagnostics = { timestamp: new Date().toISOString(), service: 'zava-api' };

  try {
    // Active connections
    const connResult = await pool.query(`SELECT count(*) as active FROM pg_stat_activity WHERE datname = current_database()`);
    diagnostics.active_connections = parseInt(connResult.rows[0].active);

    // Table sizes
    const sizeResult = await pool.query(`
      SELECT relname as table_name, n_live_tup as row_count
      FROM pg_stat_user_tables ORDER BY n_live_tup DESC
    `);
    diagnostics.tables = sizeResult.rows;

    // Index usage (critical for Zava demo — shows missing indexes)
    const indexResult = await pool.query(`
      SELECT schemaname, relname as table_name, indexrelname as index_name,
        idx_scan as times_used, idx_tup_read as rows_read
      FROM pg_stat_user_indexes ORDER BY idx_scan DESC
    `);
    diagnostics.indexes = indexResult.rows;

    // Slow query indicator: check if sequential scans dominate on large tables
    const seqResult = await pool.query(`
      SELECT relname as table_name, seq_scan, idx_scan,
        CASE WHEN seq_scan + idx_scan > 0
          THEN round(100.0 * idx_scan / (seq_scan + idx_scan), 1)
          ELSE 0 END as index_usage_pct
      FROM pg_stat_user_tables WHERE n_live_tup > 10 ORDER BY seq_scan DESC
    `);
    diagnostics.scan_stats = seqResult.rows;

    // Recent health checks
    const healthResult = await pool.query('SELECT * FROM health_checks ORDER BY timestamp DESC LIMIT 10');
    diagnostics.recent_health_checks = healthResult.rows;

    diagnostics.status = 'ok';
    res.json(diagnostics);
  } catch (err) {
    log('error', 'Diagnostics query failed', { error: err.message, code: err.code });
    res.status(503).json({ status: 'error', error: 'Internal server error', ...diagnostics });
  }
});

module.exports = router;
