const http = require('http')
const fs = require('fs')
const path = require('path')

const port = process.argv[2] || 8082
const dir = process.argv[3] || 'www'

const types = {
  '.html': 'text/html', '.css': 'text/css', '.js': 'application/javascript',
  '.json': 'application/json', '.txt': 'text/plain', '.png': 'image/png',
}

http.createServer((req, res) => {
  let p = path.join(dir, req.url === '/' ? '/index.html' : req.url)
  try {
    const body = fs.readFileSync(p)
    const ext = path.extname(p)
    res.writeHead(200, { 'Content-Type': types[ext] || 'application/octet-stream', 'Connection': 'close' })
    res.end(body)
  } catch {
    res.writeHead(404, { 'Connection': 'close' })
    res.end('not found')
  }
}).listen(port, () => console.log(`node serving ${dir} on :${port}`))
