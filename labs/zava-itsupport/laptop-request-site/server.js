const http = require("http");
const fs = require("fs");
const path = require("path");

const mimeTypes = { ".html": "text/html", ".css": "text/css", ".js": "text/javascript", ".png": "image/png", ".jpg": "image/jpeg", ".svg": "image/svg+xml" };

const server = http.createServer((req, res) => {
  let filePath = req.url === "/" ? "/index.html" : req.url;
  filePath = path.join(__dirname, filePath);
  const ext = path.extname(filePath);
  fs.readFile(filePath, (err, data) => {
    if (err) { res.writeHead(404); res.end("Not found"); return; }
    res.writeHead(200, { "Content-Type": mimeTypes[ext] || "text/plain" });
    res.end(data);
  });
});

server.listen(process.env.PORT || 8080, () => console.log("Zava IT Portal running"));
