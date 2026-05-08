const pool = require('./client');

async function seed() {
  console.log('Seeding database...');

  // Fast pre-check: is the catalog already provisioned? If products has any
  // rows, the schema + indexes were created on a prior boot. Skip the DDL
  // block entirely so we don't silently re-create indexes that an operator
  // (or the SRE Agent demo's break-db-perf scenario) intentionally dropped.
  // The DDL itself is `IF NOT EXISTS` and harmless on a fresh DB; the
  // problem is specifically the category lookup indexes un-doing the
  // missing-index break on every pod
  // restart, which makes the demo non-deterministic.
  let catalogReady = false;
  try {
    const probe = await pool.query(
      "SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='products' LIMIT 1"
    );
    if (probe.rowCount > 0) {
      const rows = await pool.query('SELECT 1 FROM products LIMIT 1');
      catalogReady = rows.rowCount > 0;
    }
  } catch (err) {
    console.log('Pre-check failed, falling through to full seed:', err.message);
  }

  if (catalogReady) {
    console.log('Catalog already provisioned (products has rows) — skipping schema + index DDL');
  } else {
    await pool.query(`
      CREATE TABLE IF NOT EXISTS products (
        id SERIAL PRIMARY KEY,
        sku VARCHAR(50) UNIQUE NOT NULL,
        name VARCHAR(200) NOT NULL,
        description TEXT,
        price DECIMAL(10,2) NOT NULL,
        category VARCHAR(100) NOT NULL,
        stock_quantity INT DEFAULT 0,
        created_at TIMESTAMPTZ DEFAULT NOW()
      );

      CREATE TABLE IF NOT EXISTS customers (
        id SERIAL PRIMARY KEY,
        name VARCHAR(200) NOT NULL,
        email VARCHAR(200) UNIQUE NOT NULL,
        region VARCHAR(100),
        created_at TIMESTAMPTZ DEFAULT NOW()
      );

      CREATE TABLE IF NOT EXISTS orders (
        id SERIAL PRIMARY KEY,
        product_id INT REFERENCES products(id),
        customer_id INT REFERENCES customers(id),
        quantity INT NOT NULL,
        total_price DECIMAL(10,2) NOT NULL,
        status VARCHAR(50) DEFAULT 'completed',
        created_at TIMESTAMPTZ DEFAULT NOW()
      );

      CREATE TABLE IF NOT EXISTS health_checks (
        id SERIAL PRIMARY KEY,
        timestamp TIMESTAMPTZ DEFAULT NOW(),
        db_connected BOOLEAN NOT NULL,
        response_time_ms INT,
        error_message TEXT
      );
    `);

    // Create performance-critical indexes (only on first-ever boot — see
    // catalogReady gate above).
    await pool.query(`
      CREATE INDEX IF NOT EXISTS idx_products_category ON products(category);
      CREATE INDEX IF NOT EXISTS idx_products_category_name ON products(category, name);
      CREATE INDEX IF NOT EXISTS idx_products_sku ON products(sku);
      CREATE INDEX IF NOT EXISTS idx_orders_product_id ON orders(product_id);
      CREATE INDEX IF NOT EXISTS idx_orders_customer_id ON orders(customer_id);
      CREATE INDEX IF NOT EXISTS idx_orders_created_at ON orders(created_at DESC);
    `);
  }

  // Seed products if empty
  const { rowCount } = await pool.query('SELECT 1 FROM products LIMIT 1');
  if (rowCount === 0) {
    const categories = ['Running', 'Training', 'Yoga', 'Cycling', 'Swimming', 'Outdoor', 'Recovery', 'Accessories'];

    const productNames = {
      'Running': ['Trail Runner Pro', 'Marathon Elite', 'Sprint Racer', 'Distance Glide', 'Tempo Trainer', 'Road King', 'Pace Setter'],
      'Training': ['Power Lift Shorts', 'Cross-Fit Tank', 'Gym Essential Tee', 'Training Jogger', 'Performance Hoodie', 'Flex Fit Legging', 'Muscle Tee'],
      'Yoga': ['Zen Flow Mat', 'Balance Legging', 'Breathe Tank', 'Harmony Capri', 'Serenity Hoodie', 'Flow Shorts', 'Lotus Top'],
      'Cycling': ['Aero Jersey', 'Padded Short', 'Wind Vest', 'Clip Shoe Cover', 'Thermal Tight', 'Race Glove', 'Hill Climber'],
      'Swimming': ['Chlorine Resistant Suit', 'Lap Jammer', 'Open Water Wetsuit', 'Dive Cap', 'Training Goggle Set', 'Splash Guard', 'Aqua Short'],
      'Outdoor': ['Summit Shell', 'Trail Pant', 'Base Layer Crew', 'Alpine Vest', 'Weather Shield Jacket', 'Ridge Walker', 'Peak Performer'],
      'Recovery': ['Compression Sleeve', 'Foam Roller Pro', 'Cool Down Tight', 'Rest Day Hoodie', 'Recovery Sock', 'Chill Pant', 'Relax Tee'],
      'Accessories': ['Performance Headband', 'Sport Watch Band', 'Gym Bag Pro', 'Hydration Belt', 'Grip Glove', 'Sweat Towel', 'Sport Visor']
    };

    const descriptions = {
      'Running': 'Engineered for motion with responsive cushioning and breathable mesh',
      'Training': 'Built for high-intensity workouts with moisture-wicking fabric',
      'Yoga': 'Designed for flexibility and comfort during mindful movement',
      'Cycling': 'Aerodynamic performance gear for road and trail riders',
      'Swimming': 'Chlorine-resistant construction for serious swimmers',
      'Outdoor': 'Weather-resistant gear built for trail and summit adventures',
      'Recovery': 'Compression and comfort technology for post-workout recovery',
      'Accessories': 'Essential athletic accessories for every workout'
    };

    let productNum = 1;
    for (const cat of categories) {
      const names = productNames[cat];
      for (let j = 0; j < names.length && productNum <= 50; j++) {
        const price = (Math.random() * 250 + 15).toFixed(2);
        const stock = Math.floor(Math.random() * 1000);
        const sku = `ZV-${String(productNum).padStart(4, '0')}`;
        const desc = descriptions[cat];
        await pool.query(
          'INSERT INTO products (sku, name, description, price, category, stock_quantity) VALUES ($1, $2, $3, $4, $5, $6) ON CONFLICT (sku) DO NOTHING',
          [sku, names[j], desc, price, cat, stock]
        );
        productNum++;
      }
    }

    // Seed customers
    const regions = ['West Europe', 'East US', 'Australia East', 'Brazil South', 'UK South', 'Southeast Asia'];
    for (let i = 1; i <= 20; i++) {
      const region = regions[i % regions.length];
      await pool.query(
        'INSERT INTO customers (name, email, region) VALUES ($1, $2, $3) ON CONFLICT (email) DO NOTHING',
        [`Customer ${i}`, `customer${i}@zava.com`, region]
      );
    }

    // Seed orders
    for (let i = 1; i <= 200; i++) {
      const prodId = (i % 50) + 1;
      const custId = (i % 20) + 1;
      const qty = Math.floor(Math.random() * 10) + 1;
      const price = (Math.random() * 500 + 10).toFixed(2);
      const status = ['completed', 'completed', 'completed', 'processing', 'shipped'][i % 5];
      const daysAgo = Math.floor(Math.random() * 30);
      await pool.query(
        'INSERT INTO orders (product_id, customer_id, quantity, total_price, status, created_at) VALUES ($1, $2, $3, $4, $5, NOW() - $6::interval)',
        [prodId, custId, qty, price, status, `${daysAgo} days`]
      );
    }

    console.log('Seeded originals: 50 products + 20 customers + 200 orders');
  } else {
    console.log('Originals already seeded, skipping');
  }

  // Variant expansion runs every startup (idempotent via ON CONFLICT) so existing
  // deployments get topped off when we change the dimensions. Cheap when fully
  // populated -- PG short-circuits on conflict.
  // Expand 50 originals into realistic size/color/edition variants via CROSS JOIN.
  // ~120k-row catalog defensible (real derivatives) and big enough that a
  // sequential scan over `category` is measurably slower than an indexed lookup
  // -- required for the missing-index demo scenario to actually trip its
  // App Insights duration-based alert (small datasets fit pg shared buffers
  // and stay sub-10ms even when seq-scanned).
  // SKU pattern: ZV-NNNN-CCC-SS-EE  e.g. ZV-0001-BLK-M-CL ("Trail Runner Pro - Black, Medium, Classic")
  const variantCount = await pool.query(`SELECT count(*)::int AS n FROM products WHERE sku ~ '^ZV-[0-9]{4}-'`);
  const TARGET_VARIANTS = 120000;
  if (variantCount.rows[0].n < TARGET_VARIANTS) {
    console.log(`Expanding variants (have ${variantCount.rows[0].n}, target ${TARGET_VARIANTS})...`);
    await pool.query(`
      INSERT INTO products (sku, name, description, price, category, stock_quantity)
      SELECT
        p.sku || '-' || c.code || '-' || s.code || '-' || e.code,
        p.name || ' - ' || c.label || ', ' || s.label || ' (' || e.label || ')',
        p.description || ' Available in ' || c.label || ', size ' || s.label || ', ' || e.label || ' edition.',
        GREATEST((p.price + s.upcharge + e.upcharge)::numeric(10,2), 5.00::numeric(10,2)),
        p.category,
        (50 + random() * 800)::int
      FROM products p
      CROSS JOIN (VALUES
        ('XS','XS',-2.00),
        ('S','Small',-1.00),
        ('M','Medium',0.00),
        ('L','Large',2.00),
        ('XL','X-Large',3.00),
        ('XXL','XX-Large',5.00),
        ('XXXL','XXX-Large',7.00),
        ('OS','One Size',0.00)
      ) AS s(code, label, upcharge)
      CROSS JOIN (VALUES
        ('BLK','Black'),('WHT','White'),('GRY','Gray'),('NVY','Navy'),
        ('RED','Red'),('BLU','Blue'),('GRN','Green'),('CHR','Charcoal'),
        ('BUR','Burgundy'),('OLV','Olive'),('CRM','Cream'),('RYL','Royal')
      ) AS c(code, label)
      CROSS JOIN (VALUES
        ('CL','Classic',0.00),('PR','Pro',5.00),('EL','Elite',12.00),
        ('LT','Limited',8.00),('VN','Vintage',3.00),('SG','Signature',15.00),
        ('TR','Tour',7.00),('RC','Race',10.00),('TM','Team',4.00),
        ('CM','Commemorative',18.00),('AN','Anniversary',20.00),('FE','First-Edition',25.00),
        ('RT','Retro',2.00),('MD','Modern',1.00),('HE','Heritage',6.00),
        ('PM','Premium',9.00),('ES','Essential',-1.00),('CR','Core',0.00),
        ('FX','Flex',2.00),('UL','Ultra',11.00),('XE','XE',13.00),
        ('NX','NX',8.00),('SX','SX',6.00),('PX','PX',4.00),('ZX','ZX',5.00)
      ) AS e(code, label, upcharge)
      WHERE p.sku ~ '^ZV-[0-9]{4}$'
      ON CONFLICT (sku) DO NOTHING
    `);
    await pool.query('ANALYZE products');
    const after = await pool.query(`SELECT count(*)::int AS n FROM products`);
    console.log(`Variants ready: ${after.rows[0].n} total products (50 originals + 8 sizes x 12 colors x 25 editions = 120,000 variants)`);
  } else {
    console.log(`Variants already at target (${variantCount.rows[0].n} >= ${TARGET_VARIANTS}), skipping`);
  }
}

if (require.main === module) {
  seed().then(() => { console.log('Done'); process.exit(0); }).catch(err => { console.error(err); process.exit(1); });
}

module.exports = seed;
