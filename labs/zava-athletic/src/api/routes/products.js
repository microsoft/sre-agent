const express = require('express');
const pool = require('../db/client');
const { log } = require('../logging/logger');
const router = express.Router();

router.get('/', async (req, res) => {
  try {
    const limit = parseInt(req.query.limit) || 50;
    const offset = parseInt(req.query.offset) || 0;
    const safeLimit = Math.min(Math.max(limit, 1), 100);
    const safeOffset = Math.max(offset, 0);
    const { rows } = await pool.query('SELECT id, sku, name, price, category, stock_quantity FROM products ORDER BY id LIMIT $1 OFFSET $2', [safeLimit, safeOffset]);
    res.json(rows);
  } catch (err) {
    log('error', 'Failed to fetch products', { error: err.message, code: err.code, endpoint: '/api/products' });
    res.status(503).json({ error: 'Internal server error' });
  }
});

router.get('/category/:category', async (req, res) => {
  try {
    const limit = parseInt(req.query.limit) || 50;
    const offset = parseInt(req.query.offset) || 0;
    const safeLimit = Math.min(Math.max(limit, 1), 100);
    const safeOffset = Math.max(offset, 0);
    const { rows } = await pool.query('SELECT id, sku, name, price, category, stock_quantity FROM products WHERE category = $1 ORDER BY name LIMIT $2 OFFSET $3', [req.params.category, safeLimit, safeOffset]);
    res.json(rows);
  } catch (err) {
    log('error', 'Failed to fetch products by category', { error: err.message, code: err.code, category: req.params.category });
    res.status(503).json({ error: 'Internal server error' });
  }
});

router.get('/:id', async (req, res) => {
  try {
    const { rows } = await pool.query(`
      SELECT p.*, 
        (SELECT COUNT(*) FROM orders o WHERE o.product_id = p.id) as order_count,
        (SELECT COALESCE(SUM(o.total_price), 0) FROM orders o WHERE o.product_id = p.id) as total_revenue
      FROM products p WHERE p.id = $1
    `, [req.params.id]);
    if (rows.length === 0) return res.status(404).json({ error: 'Product not found' });
    res.json(rows[0]);
  } catch (err) {
    log('error', 'Failed to fetch product detail', { error: err.message, productId: req.params.id });
    res.status(503).json({ error: 'Internal server error' });
  }
});

module.exports = router;
