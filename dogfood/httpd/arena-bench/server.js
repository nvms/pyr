const http = require('http')

const port = process.argv[2] || 9982

http.createServer((req, res) => {
  const records = []
  for (let i = 0; i < 10; i++) {
    records.push({
      id: i,
      name: `user_${i}`,
      email: `user${i}@example.com`,
      score: i * 17 + 42,
    })
  }
  const body = JSON.stringify(records)
  res.writeHead(200, {
    'Content-Type': 'application/json',
    'Content-Length': Buffer.byteLength(body),
    'Connection': 'close',
  })
  res.end(body)
}).listen(port, () => console.log(`node server on :${port}`))
