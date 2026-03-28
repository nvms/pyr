const port = process.argv[2] || 9983

Bun.serve({
  port,
  fetch(req) {
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
    return new Response(body, {
      headers: { 'Content-Type': 'application/json' },
    })
  },
})

console.log(`bun server on :${port}`)
