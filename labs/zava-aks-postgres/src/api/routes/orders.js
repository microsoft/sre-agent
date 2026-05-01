const express = require('express');
const pool = require('../db/client');
const { log } = require('../logging/logger');
const router = express.Router();

router.get('/', async (req, res) => {
  try {
    const { rows } = await pool.query(`
      SELECT o.id, o.product_id, o.quantity, o.total_price, o.status, o.created_at,
        p.name as product_name, p.sku,
        c.name as customer_name, c.region
      FROM orders o
      JOIN products p ON o.product_id = p.id
      JOIN customers c ON o.customer_id = c.id
      ORDER BY o.created_at DESC
      LIMIT 50
    `);
    res.json(rows);
  } catch (err) {
    log('error', 'Failed to fetch orders', { error: err.message, code: err.code });
    res.status(503).json({ error: 'Internal server error' });
  }
});

module.exports = router;
