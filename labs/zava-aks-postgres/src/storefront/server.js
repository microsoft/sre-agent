const { useAzureMonitor } = require('@azure/monitor-opentelemetry');
const { resourceFromAttributes } = require('@opentelemetry/resources');
const { ATTR_SERVICE_NAME } = require('@opentelemetry/semantic-conventions');

const aiConnStr = process.env.APPLICATIONINSIGHTS_CONNECTION_STRING;

if (aiConnStr && aiConnStr.startsWith('InstrumentationKey=')) {
  // service.name → cloud_RoleName in Application Insights (used by KQL filters).
  useAzureMonitor({
    azureMonitorExporterOptions: { connectionString: aiConnStr },
    resource: resourceFromAttributes({
      [ATTR_SERVICE_NAME]: 'zava-storefront',
    }),
    samplingRatio: 1.0,
    enableLiveMetrics: false,
  });
}

const express = require('express');
const axios = require('axios');
const path = require('path');

const app = express();
const PORT = process.env.PORT || 3000;
const API_URL = process.env.API_URL || 'http://zava-api:3001';
const REGION = process.env.AZURE_LOCATION || 'unknown';

app.use(express.static(path.join(__dirname, 'views')));

// Landing page — product catalog
app.get('/', async (req, res) => {
  try {
    const [productsRes, healthRes] = await Promise.allSettled([
      axios.get(`${API_URL}/api/products`, { timeout: 5000 }),
      axios.get(`${API_URL}/api/health`, { timeout: 5000 }),
    ]);

    const products = productsRes.status === 'fulfilled' ? productsRes.value.data : [];
    const health = healthRes.status === 'fulfilled'
      ? healthRes.value.data
      : (healthRes.reason?.response?.data || { status: 'unknown', error: healthRes.reason?.code || 'DATABASE_UNREACHABLE' });
    const dbOk = health.db_connected === true;

    res.send(renderPage(products, health, dbOk));
  } catch (err) {
    console.error(JSON.stringify({ level: 'error', message: 'Landing page render failed', error: err.message, timestamp: new Date().toISOString() }));
    res.send(renderPage([], { status: 'error', error: 'Internal server error' }, false));
  }
});

// Product detail page
app.get('/products/:id', async (req, res) => {
  try {
    const { data } = await axios.get(`${API_URL}/api/products/${req.params.id}`, { timeout: 5000 });
    res.send(renderProductPage(data));
  } catch (err) {
    console.error(JSON.stringify({ level: 'error', message: 'Product detail fetch failed', error: err.message, productId: req.params.id, timestamp: new Date().toISOString() }));
    res.status(503).send(renderErrorPage('Internal server error'));
  }
});

// Orders page
app.get('/orders', async (req, res) => {
  try {
    const { data } = await axios.get(`${API_URL}/api/orders`, { timeout: 5000 });
    res.send(renderOrdersPage(data));
  } catch (err) {
    console.error(JSON.stringify({ level: 'error', message: 'Orders fetch failed', error: err.message, timestamp: new Date().toISOString() }));
    res.status(503).send(renderErrorPage('Internal server error'));
  }
});

// Storefront health — proxies to API
app.get('/health', async (req, res) => {
  try {
    const apiHealth = await axios.get(`${API_URL}/api/health`, { timeout: 5000 });
    res.json({ status: 'healthy', api: apiHealth.data, service: 'zava-storefront' });
  } catch (err) {
    console.error(JSON.stringify({ level: 'error', message: 'Storefront health check failed', error: err.message, timestamp: new Date().toISOString() }));
    res.status(503).json({ status: 'unhealthy', error: 'Internal server error', service: 'zava-storefront' });
  }
});

// Shallow liveness check — no API dependency, just confirms the process is alive
app.get('/livez', (req, res) => res.json({ status: 'alive', service: 'zava-storefront' }));

// ── Shared CSS for the Zava Athletic dark theme ──
function zavaCSS() {
  return `@import url('https://fonts.googleapis.com/css2?family=Bebas+Neue&family=Barlow:wght@300;400;500;600;700&family=JetBrains+Mono:wght@400;500&display=swap');
:root{--bg-primary:#07070d;--bg-secondary:#0e0e18;--bg-card:#12121f;--bg-card-hover:#181830;--surface:#1a1a2e;--border:rgba(255,255,255,0.06);--border-hover:rgba(255,255,255,0.12);--text-primary:#f0f0f5;--text-secondary:#8888a0;--text-muted:#55556a;--accent:#00d4ff;--accent-glow:rgba(0,212,255,0.15);--accent-dim:#0099bb;--price:#ff6b35;--success:#00e676;--success-dim:rgba(0,230,118,0.12);--danger:#ff1744;--danger-glow:rgba(255,23,68,0.2);--warning:#ffab00;--gradient-hero:linear-gradient(135deg,#07070d 0%,#0a1628 50%,#07070d 100%);--noise:url("data:image/svg+xml,%3Csvg viewBox='0 0 256 256' xmlns='http://www.w3.org/2000/svg'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.9' numOctaves='4' stitchTiles='stitch'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23n)' opacity='0.03'/%3E%3C/svg%3E")}
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:'Barlow',-apple-system,sans-serif;background:var(--bg-primary);color:var(--text-primary);min-height:100vh;-webkit-font-smoothing:antialiased}
a{color:var(--accent);text-decoration:none}a:hover{text-decoration:underline}
.status-bar{position:sticky;top:0;z-index:100;display:flex;align-items:center;justify-content:space-between;padding:0 2rem;height:42px;background:rgba(7,7,13,0.92);backdrop-filter:blur(20px);border-bottom:1px solid var(--border);font-size:0.78rem;font-weight:500;letter-spacing:0.04em;color:var(--text-secondary)}
.status-bar .status-left{display:flex;align-items:center;gap:1.5rem}
.status-indicator{display:flex;align-items:center;gap:0.5rem;font-family:'JetBrains Mono',monospace;font-size:0.72rem}
.status-dot{width:7px;height:7px;border-radius:50%;background:var(--success);box-shadow:0 0 8px var(--success),0 0 20px rgba(0,230,118,0.3);animation:pulse-dot 2s ease-in-out infinite}
.status-dot.danger{background:var(--danger);box-shadow:0 0 8px var(--danger),0 0 20px var(--danger-glow);animation:pulse-danger 0.8s ease-in-out infinite}
@keyframes pulse-dot{0%,100%{opacity:1}50%{opacity:0.6}}
@keyframes pulse-danger{0%,100%{opacity:1;transform:scale(1)}50%{opacity:0.7;transform:scale(1.3)}}
.status-metric{display:flex;align-items:center;gap:0.4rem}
.status-metric .value{color:var(--accent);font-weight:600}
.status-metric .value.danger{color:var(--danger)}
.status-bar .status-right{font-family:'JetBrains Mono',monospace;font-size:0.68rem;color:var(--text-muted)}
.header{padding:2.5rem 2rem 2rem;background:var(--gradient-hero);position:relative;overflow:hidden}
.header::before{content:'';position:absolute;top:-50%;left:-50%;width:200%;height:200%;background:var(--noise);pointer-events:none}
.header::after{content:'';position:absolute;top:0;right:0;width:40%;height:100%;background:radial-gradient(ellipse at 80% 50%,rgba(0,212,255,0.04) 0%,transparent 70%);pointer-events:none}
.header-inner{max-width:1400px;margin:0 auto;display:flex;align-items:flex-end;justify-content:space-between;position:relative;z-index:1}
.brand{display:flex;flex-direction:column;gap:0.3rem}
.brand-name{font-family:'Bebas Neue',Impact,sans-serif;font-size:3.2rem;letter-spacing:0.08em;line-height:0.9;color:var(--text-primary)}
.brand-name span{color:var(--accent)}
.brand-tagline{font-size:0.75rem;font-weight:400;letter-spacing:0.25em;text-transform:uppercase;color:var(--text-muted)}
.header-nav{display:flex;gap:0.3rem}
.header-nav a{color:var(--text-secondary);text-decoration:none;font-size:0.82rem;font-weight:500;padding:0.5rem 1rem;border-radius:6px;transition:all 0.2s;letter-spacing:0.03em}
.header-nav a:hover,.header-nav a.active{color:var(--text-primary);background:rgba(255,255,255,0.05)}
.header-nav a.active{background:rgba(0,212,255,0.08);color:var(--accent)}
.stats-strip{background:var(--bg-secondary);border-bottom:1px solid var(--border);padding:1rem 2rem}
.stats-inner{max-width:1400px;margin:0 auto;display:flex;gap:2.5rem}
.stat-item{display:flex;align-items:baseline;gap:0.6rem}
.stat-value{font-family:'Bebas Neue',sans-serif;font-size:1.8rem;color:var(--text-primary);letter-spacing:0.02em}
.stat-value.accent{color:var(--accent)}.stat-value.success{color:var(--success)}.stat-value.danger{color:var(--danger)}
.stat-label{font-size:0.72rem;font-weight:500;text-transform:uppercase;letter-spacing:0.1em;color:var(--text-muted)}
.main{max-width:1400px;margin:0 auto;padding:2rem}
.section-header{display:flex;align-items:center;justify-content:space-between;margin-bottom:1.5rem}
.section-title{font-family:'Bebas Neue',sans-serif;font-size:1.4rem;letter-spacing:0.1em;color:var(--text-secondary)}
.section-title::after{content:'';display:inline-block;width:40px;height:2px;background:var(--accent);margin-left:1rem;vertical-align:middle}
.category-filters{display:flex;gap:0.3rem;flex-wrap:wrap}
.cat-pill{padding:0.35rem 0.85rem;font-size:0.7rem;font-weight:600;text-transform:uppercase;letter-spacing:0.08em;border:1px solid var(--border);border-radius:100px;color:var(--text-muted);background:transparent;cursor:default;transition:all 0.2s}
.cat-pill:hover,.cat-pill.active{border-color:var(--accent);color:var(--accent);background:var(--accent-glow)}
.product-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(280px,1fr));gap:1px;background:var(--border);border:1px solid var(--border);border-radius:12px;overflow:hidden}
.product-card{background:var(--bg-card);padding:1.4rem;display:flex;flex-direction:column;gap:0.8rem;transition:all 0.25s ease;cursor:pointer;position:relative;animation:card-in 0.4s ease both}
.product-card:hover{background:var(--bg-card-hover)}
.product-card:hover .product-name{color:var(--accent)}
.product-card:nth-child(1){animation-delay:0.02s}.product-card:nth-child(2){animation-delay:0.04s}.product-card:nth-child(3){animation-delay:0.06s}.product-card:nth-child(4){animation-delay:0.08s}.product-card:nth-child(5){animation-delay:0.10s}.product-card:nth-child(6){animation-delay:0.12s}.product-card:nth-child(7){animation-delay:0.14s}.product-card:nth-child(8){animation-delay:0.16s}
@keyframes card-in{from{opacity:0;transform:translateY(12px)}to{opacity:1;transform:translateY(0)}}
.product-card-top{display:flex;align-items:flex-start;justify-content:space-between}
.product-sku{font-family:'JetBrains Mono',monospace;font-size:0.65rem;color:var(--text-muted);letter-spacing:0.05em}
.product-category{font-size:0.6rem;font-weight:700;text-transform:uppercase;letter-spacing:0.1em;padding:0.2rem 0.5rem;border-radius:3px}
.product-category.running{background:rgba(0,212,255,0.08);color:#00d4ff}
.product-category.training{background:rgba(255,107,53,0.08);color:#ff6b35}
.product-category.yoga{background:rgba(168,85,247,0.08);color:#a855f7}
.product-category.cycling{background:rgba(34,197,94,0.08);color:#22c55e}
.product-category.swimming{background:rgba(59,130,246,0.08);color:#3b82f6}
.product-category.outdoor{background:rgba(234,179,8,0.08);color:#eab308}
.product-category.recovery{background:rgba(236,72,153,0.08);color:#ec4899}
.product-category.accessories{background:rgba(148,163,184,0.08);color:#94a3b8}
.product-name{font-size:1rem;font-weight:600;line-height:1.3;transition:color 0.2s}
.product-bottom{display:flex;align-items:flex-end;justify-content:space-between;margin-top:auto}
.product-price{font-family:'Bebas Neue',sans-serif;font-size:1.5rem;color:var(--price);letter-spacing:0.02em}
.product-stock{font-size:0.7rem;font-weight:500;color:var(--text-muted);display:flex;align-items:center;gap:0.35rem}
.stock-bar{width:40px;height:3px;background:var(--surface);border-radius:2px;overflow:hidden}
.stock-fill{height:100%;border-radius:2px;background:var(--success);transition:width 0.5s ease}
.stock-fill.low{background:var(--warning)}.stock-fill.critical{background:var(--danger)}
.footer{margin-top:3rem;padding:1.5rem 2rem;border-top:1px solid var(--border);text-align:center;font-size:0.7rem;color:var(--text-muted);letter-spacing:0.05em}
.footer span{color:var(--accent)}
.degraded-overlay{position:fixed;inset:0;z-index:200;background:linear-gradient(180deg,rgba(7,7,13,0.97) 0%,rgba(30,5,10,0.98) 100%);display:flex;flex-direction:column;align-items:center;justify-content:center;text-align:center;gap:1.5rem;animation:fade-in 0.4s ease}
@keyframes fade-in{from{opacity:0}to{opacity:1}}
.degraded-icon{width:80px;height:80px;border:3px solid var(--danger);border-radius:50%;display:flex;align-items:center;justify-content:center;font-size:2.5rem;animation:pulse-danger 1.2s ease-in-out infinite;box-shadow:0 0 40px var(--danger-glow),0 0 80px rgba(255,23,68,0.1)}
.degraded-title{font-family:'Bebas Neue',sans-serif;font-size:3rem;letter-spacing:0.15em;color:var(--danger);text-shadow:0 0 40px var(--danger-glow)}
.degraded-subtitle{font-size:1rem;color:var(--text-secondary);max-width:500px;line-height:1.6}
.degraded-details{margin-top:1rem;padding:1.2rem 2rem;background:rgba(255,23,68,0.06);border:1px solid rgba(255,23,68,0.15);border-radius:8px;font-family:'JetBrains Mono',monospace;font-size:0.75rem;color:var(--text-muted);text-align:left;line-height:1.8}
.degraded-details .label{color:var(--text-secondary)}.degraded-details .val-err{color:var(--danger)}.degraded-details .val-ok{color:var(--success)}
table.zava-table{width:100%;border-collapse:collapse;background:var(--bg-card);border:1px solid var(--border);border-radius:12px;overflow:hidden}
table.zava-table th{background:var(--bg-secondary);text-align:left;padding:12px 16px;font-size:0.72rem;font-weight:600;text-transform:uppercase;letter-spacing:0.08em;color:var(--text-muted);border-bottom:1px solid var(--border)}
table.zava-table td{padding:10px 16px;border-bottom:1px solid var(--border);font-size:0.85rem;color:var(--text-secondary)}
table.zava-table tr:hover{background:var(--bg-card-hover)}
table.zava-table td a{color:var(--accent)}
.detail-card{max-width:800px;margin:2rem auto;padding:2rem;background:var(--bg-card);border:1px solid var(--border);border-radius:12px}
.detail-card h2{font-family:'Bebas Neue',sans-serif;font-size:2rem;letter-spacing:0.05em;margin-bottom:0.5rem}
.detail-card .desc{color:var(--text-secondary);margin-bottom:1.5rem;line-height:1.6}
.detail-meta{display:flex;gap:2rem;flex-wrap:wrap;margin-bottom:1.5rem}
.detail-meta .meta-item{display:flex;flex-direction:column;gap:0.2rem}
.detail-meta .meta-label{font-size:0.7rem;text-transform:uppercase;letter-spacing:0.1em;color:var(--text-muted)}
.detail-meta .meta-value{font-family:'Bebas Neue',sans-serif;font-size:1.4rem;color:var(--text-primary)}
.detail-meta .meta-value.price{color:var(--price)}
.detail-meta .meta-value.accent{color:var(--accent)}
.back-link{display:inline-block;margin-bottom:1.5rem;color:var(--accent);font-size:0.85rem;text-decoration:none}
.back-link:hover{text-decoration:underline}`;
}

function escapeHtml(str) {
  if (str == null) return '';
  return String(str).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

function stockClass(qty) {
  if (qty < 50) return 'critical';
  if (qty <= 200) return 'low';
  return '';
}

function stockWidth(qty) {
  return Math.min(Math.max((qty / 1000) * 100, 2), 100).toFixed(0);
}

function categoryClass(cat) {
  return (cat || '').toLowerCase().replace(/[^a-z]/g, '');
}

function renderPage(products, health, dbOk) {
  const categories = [...new Set(products.map(p => p.category))];
  const dbMs = health.response_time_ms || '—';

  const statusBar = dbOk
    ? `<div class="status-bar">
        <div class="status-left">
          <div class="status-indicator"><div class="status-dot"></div><span>ALL SYSTEMS OPERATIONAL</span></div>
          <div class="status-metric"><span>DB</span><span class="value">${dbMs}ms</span></div>
        </div>
        <div class="status-right">v1.0.0 · ${REGION}</div>
      </div>`
    : `<div class="status-bar">
        <div class="status-left">
          <div class="status-indicator"><div class="status-dot danger"></div><span>SERVICE DISRUPTED</span></div>
          <div class="status-metric"><span>DB</span><span class="value danger">OFFLINE</span></div>
        </div>
        <div class="status-right">v1.0.0 · ${REGION}</div>
      </div>`;

  const productCards = products.map((p, i) => {
    const sc = stockClass(p.stock_quantity);
    const sw = stockWidth(p.stock_quantity);
    const cc = categoryClass(p.category);
    return `<a href="/products/${p.id}" class="product-card" data-category="${escapeHtml(p.category)}" style="text-decoration:none;color:inherit;animation-delay:${(i * 0.02).toFixed(2)}s">
      <div class="product-card-top">
        <span class="product-sku">${escapeHtml(p.sku)}</span>
        <span class="product-category ${cc}">${escapeHtml(p.category)}</span>
      </div>
      <div class="product-name">${escapeHtml(p.name)}</div>
      <div class="product-bottom">
        <div class="product-price">$${parseFloat(p.price).toFixed(2)}</div>
        <div class="product-stock">
          <div class="stock-bar"><div class="stock-fill ${sc}" style="width:${sw}%"></div></div>
          <span>${p.stock_quantity}</span>
        </div>
      </div>
    </a>`;
  }).join('');

  const catPills = `<button type="button" class="cat-pill active" data-cat="">All</button>` +
    categories.map(c => `<button type="button" class="cat-pill" data-cat="${escapeHtml(c)}">${escapeHtml(c)}</button>`).join('');

  const degradedOverlay = !dbOk ? `
    <div class="degraded-overlay">
      <div class="degraded-icon">⚡</div>
      <div class="degraded-title">SERVICE DISRUPTION</div>
      <div class="degraded-subtitle">The Zava Athletic platform is experiencing connectivity issues. Our automated systems are investigating and working to restore service.</div>
      <div class="degraded-details">
        <span class="label">status</span>    <span class="val-err">503 Service Unavailable</span>
        <br><span class="label">database</span>  <span class="val-err">unreachable</span>
        <br><span class="label">api</span>       <span class="val-err">${escapeHtml(health.error) || 'DATABASE_UNREACHABLE'}</span>
        <br><span class="label">region</span>    <span class="val-ok">${REGION}</span>
        <br><span class="label">agent</span>     <span class="val-ok">investigating</span>
      </div>
    </div>` : '';

  return `<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"><title>ZAVA. — Engineered for Motion</title>
<style>${zavaCSS()}</style></head><body>
${statusBar}
<div class="header">
  <div class="header-inner">
    <div class="brand">
      <div class="brand-name">ZAVA<span>.</span></div>
      <div class="brand-tagline">Engineered for Motion</div>
    </div>
    <nav class="header-nav">
      <a href="/" class="active">Products</a>
      <a href="/orders">Orders</a>
    </nav>
  </div>
</div>
<div class="stats-strip">
  <div class="stats-inner">
    <div class="stat-item"><div class="stat-value">${products.length}</div><div class="stat-label">Products</div></div>
    <div class="stat-item"><div class="stat-value accent">${dbMs}ms</div><div class="stat-label">DB Response</div></div>
    <div class="stat-item"><div class="stat-value ${dbOk ? 'success' : 'danger'}">${dbOk ? '✓' : '✗'}</div><div class="stat-label">Database</div></div>
    <div class="stat-item"><div class="stat-value">${categories.length}</div><div class="stat-label">Categories</div></div>
  </div>
</div>
<div class="main">
  <div class="section-header">
    <div class="section-title">PRODUCT CATALOG</div>
    <div class="category-filters">${catPills}</div>
  </div>
  ${products.length > 0
    ? `<div class="product-grid">${productCards}</div>`
    : '<p style="text-align:center;color:var(--text-muted);padding:48px;">No products available — database may be unreachable.</p>'}
</div>
<div class="footer"><span>ZAVA</span> ATHLETIC · Engineered for Motion · SRE Agent Demo · Powered by Azure</div>
${degradedOverlay}
<script>
(function(){
  var pills=document.querySelectorAll('.cat-pill');
  var cards=document.querySelectorAll('.product-card');
  pills.forEach(function(btn){
    btn.addEventListener('click',function(){
      var cat=btn.getAttribute('data-cat')||'';
      pills.forEach(function(b){b.classList.toggle('active',b===btn);});
      cards.forEach(function(c){
        c.style.display=(!cat||c.getAttribute('data-category')===cat)?'':'none';
      });
    });
  });
})();
</script>
</body></html>`;
}

function renderProductPage(product) {
  const sc = stockClass(product.stock_quantity);
  const sw = stockWidth(product.stock_quantity);
  const cc = categoryClass(product.category);

  return `<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"><title>${product.name} — ZAVA.</title>
<style>${zavaCSS()}</style></head><body>
<div class="status-bar">
  <div class="status-left">
    <div class="status-indicator"><div class="status-dot"></div><span>ALL SYSTEMS OPERATIONAL</span></div>
  </div>
  <div class="status-right">v1.0.0 · ${REGION}</div>
</div>
<div class="header">
  <div class="header-inner">
    <div class="brand">
      <div class="brand-name">ZAVA<span>.</span></div>
      <div class="brand-tagline">Engineered for Motion</div>
    </div>
    <nav class="header-nav">
      <a href="/">Products</a>
      <a href="/orders">Orders</a>
    </nav>
  </div>
</div>
<div class="main">
  <a class="back-link" href="/">← Back to catalog</a>
  <div class="detail-card">
    <div class="product-card-top" style="margin-bottom:1rem">
      <span class="product-sku">${escapeHtml(product.sku)}</span>
      <span class="product-category ${cc}">${escapeHtml(product.category)}</span>
    </div>
    <h2>${escapeHtml(product.name)}</h2>
    <p class="desc">${escapeHtml(product.description) || ''}</p>
    <div class="detail-meta">
      <div class="meta-item"><div class="meta-label">Price</div><div class="meta-value price">$${parseFloat(product.price).toFixed(2)}</div></div>
      <div class="meta-item"><div class="meta-label">Stock</div><div class="meta-value">${product.stock_quantity}<div class="stock-bar" style="margin-top:4px"><div class="stock-fill ${sc}" style="width:${sw}%"></div></div></div></div>
      <div class="meta-item"><div class="meta-label">Orders</div><div class="meta-value accent">${product.order_count || 0}</div></div>
      <div class="meta-item"><div class="meta-label">Revenue</div><div class="meta-value price">$${parseFloat(product.total_revenue || 0).toFixed(2)}</div></div>
    </div>
  </div>
</div>
<div class="footer"><span>ZAVA</span> ATHLETIC · Engineered for Motion · SRE Agent Demo · Powered by Azure</div>
</body></html>`;
}

function renderOrdersPage(orders) {
  const rows = orders.map(o => {
    const statusColor = o.status === 'completed' ? 'var(--success)' : o.status === 'shipped' ? 'var(--accent)' : 'var(--warning)';
    return `<tr>
      <td>${o.id}</td>
      <td><a href="/products/${o.product_id || ''}">${escapeHtml(o.product_name)} (${escapeHtml(o.sku)})</a></td>
      <td>${escapeHtml(o.customer_name)}</td>
      <td>${escapeHtml(o.region)}</td>
      <td>${o.quantity}</td>
      <td style="font-family:'Bebas Neue',sans-serif;font-size:1.1rem;color:var(--price)">$${parseFloat(o.total_price).toFixed(2)}</td>
      <td><span style="color:${statusColor};font-weight:600;text-transform:uppercase;font-size:0.75rem;letter-spacing:0.05em">${escapeHtml(o.status)}</span></td>
      <td style="font-family:'JetBrains Mono',monospace;font-size:0.78rem">${new Date(o.created_at).toLocaleDateString()}</td>
    </tr>`;
  }).join('');

  return `<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"><title>Orders — ZAVA.</title>
<style>${zavaCSS()}</style></head><body>
<div class="status-bar">
  <div class="status-left">
    <div class="status-indicator"><div class="status-dot"></div><span>ALL SYSTEMS OPERATIONAL</span></div>
  </div>
  <div class="status-right">v1.0.0 · ${REGION}</div>
</div>
<div class="header">
  <div class="header-inner">
    <div class="brand">
      <div class="brand-name">ZAVA<span>.</span></div>
      <div class="brand-tagline">Engineered for Motion</div>
    </div>
    <nav class="header-nav">
      <a href="/">Products</a>
      <a href="/orders" class="active">Orders</a>
    </nav>
  </div>
</div>
<div class="main">
  <div class="section-header">
    <div class="section-title">RECENT ORDERS</div>
  </div>
  <table class="zava-table">
    <thead><tr><th>ID</th><th>Product</th><th>Customer</th><th>Region</th><th>Qty</th><th>Total</th><th>Status</th><th>Date</th></tr></thead>
    <tbody>${rows}</tbody>
  </table>
</div>
<div class="footer"><span>ZAVA</span> ATHLETIC · Engineered for Motion · SRE Agent Demo · Powered by Azure</div>
</body></html>`;
}

function renderErrorPage(error) {
  return `<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"><title>Service Disruption — ZAVA.</title>
<style>${zavaCSS()}</style></head><body>
<div class="status-bar">
  <div class="status-left">
    <div class="status-indicator"><div class="status-dot danger"></div><span>SERVICE DISRUPTED</span></div>
    <div class="status-metric"><span>DB</span><span class="value danger">OFFLINE</span></div>
  </div>
  <div class="status-right">v1.0.0 · ${REGION}</div>
</div>
<div class="degraded-overlay">
  <div class="degraded-icon">⚡</div>
  <div class="degraded-title">SERVICE DISRUPTION</div>
  <div class="degraded-subtitle">The Zava Athletic platform is experiencing connectivity issues. Our automated systems are investigating and working to restore service.</div>
  <div class="degraded-details">
    <span class="label">status</span>    <span class="val-err">503 Service Unavailable</span>
    <br><span class="label">database</span>  <span class="val-err">unreachable</span>
    <br><span class="label">api</span>       <span class="val-err">${escapeHtml(error)}</span>
    <br><span class="label">region</span>    <span class="val-ok">${REGION}</span>
    <br><span class="label">agent</span>     <span class="val-ok">investigating</span>
  </div>
</div>
</body></html>`;
}

const server = app.listen(PORT, '0.0.0.0', () => {
  console.log(JSON.stringify({ level: 'info', message: `Zava Storefront running on port ${PORT}`, timestamp: new Date().toISOString() }));
});

process.on('SIGTERM', () => {
  console.log(JSON.stringify({ level: 'info', message: 'SIGTERM received, shutting down gracefully', timestamp: new Date().toISOString() }));
  server.close(() => process.exit(0));
});
