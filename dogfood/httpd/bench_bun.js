import { file } from 'bun'
import { join, extname } from 'path'

const port = process.argv[2] || 8083
const dir = process.argv[3] || 'www'

const types = {
  '.html': 'text/html', '.css': 'text/css', '.js': 'application/javascript',
  '.json': 'application/json', '.txt': 'text/plain', '.png': 'image/png',
}

Bun.serve({
  port,
  async fetch(req) {
    const url = new URL(req.url)
    const p = join(dir, url.pathname === '/' ? '/index.html' : url.pathname)
    const f = file(p)
    if (!await f.exists()) {
      return new Response('not found', { status: 404 })
    }
    const ext = extname(p)
    return new Response(f, {
      headers: { 'Content-Type': types[ext] || 'application/octet-stream' },
    })
  },
})

console.log(`bun serving ${dir} on :${port}`)
