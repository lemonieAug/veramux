#!/usr/bin/env node
// Mock claude-mem worker HTTP API for tests/unit/test_memory.sh. Implements
// just enough of /api/health and /api/context/semantic (including
// upstream's own ~20-char relevance gate) to exercise lib/memory.sh. Not
// part of the production path.
import http from 'node:http'

const port = Number(process.argv[2] || 37799)
const server = http.createServer((req, res) => {
  let body = ''
  req.on('data', (c) => (body += c))
  req.on('end', () => {
    if (req.url === '/api/health') {
      res.writeHead(200, { 'Content-Type': 'application/json' })
      res.end(JSON.stringify({ ok: true }))
      return
    }
    if (req.url === '/api/context/semantic' && req.method === 'POST') {
      let parsed = {}
      try { parsed = JSON.parse(body || '{}') } catch { /* empty */ }
      if (!parsed.q || parsed.q.length < 20) {
        res.writeHead(200, { 'Content-Type': 'application/json' })
        res.end(JSON.stringify({ context: '', count: 0 }))
        return
      }
      res.writeHead(200, { 'Content-Type': 'application/json' })
      res.end(JSON.stringify({
        context: `## Relevant Past Work\n### Prior investigation\nProject "${parsed.project}" — relevant note for: ${parsed.q}`,
        count: 1,
      }))
      return
    }
    res.writeHead(404)
    res.end('not found')
  })
})
server.listen(port, '127.0.0.1', () => console.log(`mock claude-mem worker on ${port}`))
