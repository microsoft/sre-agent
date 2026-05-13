const http = require('http');

const port = process.env.PORT || 8080;

// =============================================================================
// BUG: Synchronous blocking function that causes latency under load
// This processes data using an O(n² log n) algorithm that blocks the event loop.
// On a single-vCPU B1 App Service Plan, this causes p95 latency to spike >5s.
// The FIX is to use async/streaming processing instead of synchronous sorting.
// =============================================================================
function processLargeDatasetSync(size) {
  const data = Array.from({ length: size }, () => Math.random());
  let result = 0;
  // BUG: Sorting on every iteration is O(n² log n) total — blocks the event loop
  for (let i = 0; i < data.length; i++) {
    data.sort((a, b) => a - b);  // Unnecessary repeated sort
    result += data[i];
  }
  return result;
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url, `http://localhost:${port}`);

  // Health check — returns 200 (everything is fine)
  if (url.pathname === '/' || url.pathname === '/health') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: 'healthy', timestamp: new Date().toISOString() }));
    return;
  }

  // Data processing endpoint — has a synchronous blocking bug
  // Under load, this endpoint causes severe latency on B1 (single vCPU)
  if (url.pathname === '/api/data') {
    const size = parseInt(url.searchParams.get('size') || '10000', 10);
    const startTime = Date.now();
    const result = processLargeDatasetSync(size);
    const duration = Date.now() - startTime;
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({
      result: result,
      itemsProcessed: size,
      processingTimeMs: duration,
      timestamp: new Date().toISOString()
    }));
    return;
  }

  // Crash endpoint — returns 500 (simulates a server error)
  if (url.pathname === '/api/crash') {
    res.writeHead(500, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({
      error: 'Internal Server Error',
      message: 'Simulated crash for SRE Agent demo',
      timestamp: new Date().toISOString()
    }));
    return;
  }

  // Slow endpoint — waits before responding (simulates high latency)
  if (url.pathname === '/api/slow') {
    const delay = parseInt(url.searchParams.get('delay') || '3000', 10);
    setTimeout(() => {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({
        status: 'ok',
        message: `Responded after ${delay}ms delay`,
        timestamp: new Date().toISOString()
      }));
    }, delay);
    return;
  }

  // 404 for everything else
  res.writeHead(404, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ error: 'Not Found', path: url.pathname }));
});

server.listen(port, () => {
  console.log(`Demo app listening on port ${port}`);
});
