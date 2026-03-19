const express = require('express');
const { CosmosClient } = require('@azure/cosmos');
const { DefaultAzureCredential } = require('@azure/identity');

const app = express();
app.use(express.json());

// Use managed identity — no keys needed
const credential = new DefaultAzureCredential();
const client = new CosmosClient({
  endpoint: process.env.COSMOS_ENDPOINT,
  aadCredentials: credential,
});
const dbName = process.env.COSMOS_DB_NAME || 'ecommerce';

let productsContainer, ordersContainer;

async function initDb() {
  try {
    const { database } = await client.databases.createIfNotExists({ id: dbName });
    const { container: pc } = await database.containers.createIfNotExists({ id: 'products', partitionKey: '/category' });
    const { container: oc } = await database.containers.createIfNotExists({ id: 'orders', partitionKey: '/status' });
    productsContainer = pc;
    ordersContainer = oc;

    // Seed products if empty
    const { resources } = await pc.items.readAll().fetchAll();
    if (resources.length === 0) {
      const products = [
        { id: '1', name: 'ERP Core License', category: 'Software', price: 15000, stock: 50 },
        { id: '2', name: 'HANA DB Instance', category: 'Infrastructure', price: 8500, stock: 20 },
        { id: '3', name: 'Frontend Server', category: 'Software', price: 3200, stock: 100 },
        { id: '4', name: 'Integration Suite', category: 'Middleware', price: 5600, stock: 35 },
        { id: '5', name: 'Analytics Cloud Seat', category: 'Analytics', price: 1200, stock: 200 },
        { id: '6', name: 'Business Network License', category: 'Network', price: 2800, stock: 75 },
        { id: '7', name: 'HCM Module', category: 'HR', price: 4500, stock: 60 },
        { id: '8', name: 'Procurement Module', category: 'Procurement', price: 3800, stock: 45 },
      ];
      for (const p of products) await pc.items.create(p);
    }
    console.log('Cosmos DB initialized');
  } catch (err) {
    console.error('DB init error:', err.message);
  }
}

// ---- Frontend ----
app.get('/', (req, res) => {
  res.send(`<!DOCTYPE html>
<html><head><title>E-Commerce Portal</title>
<style>
body{font-family:'Segoe UI',sans-serif;margin:0;background:#f4f4f4}
.header{background:#0070f2;color:#fff;padding:20px 40px}.header h1{margin:0;font-size:24px}.header small{opacity:.8}
.content{max-width:1000px;margin:20px auto;padding:0 20px}
.card{background:#fff;border-radius:8px;padding:20px;margin:15px 0;box-shadow:0 1px 3px rgba(0,0,0,.1)}.card h2{margin-top:0;color:#333}
table{width:100%;border-collapse:collapse}th,td{padding:10px 12px;text-align:left;border-bottom:1px solid #eee}th{background:#f8f9fa;font-weight:600}
.status{display:inline-block;padding:3px 10px;border-radius:12px;font-size:12px}.status.ok{background:#d4edda;color:#155724}.status.error{background:#f8d7da;color:#721c24}
.btn{background:#0070f2;color:#fff;border:none;padding:8px 16px;border-radius:4px;cursor:pointer}.btn:hover{background:#0058c7}
</style></head><body>
<div class="header"><h1>E-Commerce Portal</h1><small>Enterprise Resource Planning — Demo</small></div>
<div class="content">
<div class="card"><h2>System Health</h2><button class="btn" onclick="checkHealth()">Check Health</button><div id="hs"></div></div>
<div class="card"><h2>Product Catalog</h2><div id="products">Loading...</div></div>
<div class="card"><h2>Recent Orders</h2><div id="orders">Loading...</div></div></div>
<script>
async function checkHealth(){const e=document.getElementById('hs');try{const r=await fetch('/api/health'),d=await r.json();e.innerHTML='<span class="status '+(d.database==='connected'?'ok':'error')+'">DB: '+d.database+'</span> <span class="status ok">App: '+d.status+'</span>'}catch(x){e.innerHTML='<span class="status error">Error: '+x.message+'</span>'}}
async function loadProducts(){try{const r=await fetch('/api/products'),p=await r.json();document.getElementById('products').innerHTML='<table><tr><th>Product</th><th>Category</th><th>Price</th><th>Stock</th><th></th></tr>'+p.map(i=>'<tr><td>'+i.name+'</td><td>'+i.category+'</td><td>$'+i.price+'</td><td>'+i.stock+'</td><td><button class="btn" onclick="order(\\''+i.id+'\\',\\''+i.category+'\\')">Order</button></td></tr>').join('')+'</table>'}catch(x){document.getElementById('products').innerHTML='<span class="status error">'+x.message+'</span>'}}
async function loadOrders(){try{const r=await fetch('/api/orders'),o=await r.json();document.getElementById('orders').innerHTML=o.length?'<table><tr><th>#</th><th>Product</th><th>Qty</th><th>Status</th></tr>'+o.map(i=>'<tr><td>'+i.id.slice(0,8)+'</td><td>'+i.productName+'</td><td>'+i.quantity+'</td><td><span class="status ok">'+i.status+'</span></td></tr>').join('')+'</table>':'<p>No orders yet.</p>'}catch(x){document.getElementById('orders').innerHTML='<span class="status error">'+x.message+'</span>'}}
async function order(pid,cat){try{await fetch('/api/orders',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({productId:pid,category:cat,quantity:1})});loadOrders();loadProducts()}catch(x){alert(x.message)}}
loadProducts();loadOrders();checkHealth()
</script></body></html>`);
});

// ---- API ----
app.get('/api/health', async (req, res) => {
  try {
    await productsContainer.items.readAll().fetchNext();
    res.json({ status: 'healthy', database: 'connected', type: 'CosmosDB', timestamp: new Date().toISOString() });
  } catch (err) {
    res.status(500).json({ status: 'unhealthy', database: 'disconnected', error: err.message, timestamp: new Date().toISOString() });
  }
});

app.get('/api/products', async (req, res) => {
  try {
    const { resources } = await productsContainer.items.readAll().fetchAll();
    res.json(resources);
  } catch (err) {
    res.status(500).json({ error: 'Database error', detail: err.message });
  }
});

app.get('/api/orders', async (req, res) => {
  try {
    const { resources } = await ordersContainer.items.query('SELECT * FROM c ORDER BY c._ts DESC OFFSET 0 LIMIT 20').fetchAll();
    res.json(resources);
  } catch (err) {
    res.status(500).json({ error: 'Database error', detail: err.message });
  }
});

app.post('/api/orders', async (req, res) => {
  try {
    const { productId, category, quantity } = req.body;
    const { resource: product } = await productsContainer.item(productId, category).read();
    const order = {
      id: Date.now().toString(),
      productId, productName: product.name, quantity: quantity || 1,
      status: 'confirmed', category: 'confirmed',
    };
    const { resource } = await ordersContainer.items.create(order);
    await productsContainer.item(productId, category).replace({ ...product, stock: product.stock - (quantity || 1) });
    res.status(201).json(resource);
  } catch (err) {
    res.status(500).json({ error: 'Order failed', detail: err.message });
  }
});

const PORT = process.env.PORT || 3000;
initDb().then(() => {
  app.listen(PORT, '0.0.0.0', () => console.log(`E-Commerce API on port ${PORT}`));
}).catch(err => {
  console.error('DB init failed:', err.message);
  app.listen(PORT, '0.0.0.0', () => console.log(`E-Commerce API on port ${PORT} (no DB)`));
});
