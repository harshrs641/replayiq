'use strict';
/** Minimal stand-in for ReplayIQ's write API, used by test.js. Records every call. */
const http = require('http');

function createMock() {
  const calls = [];
  const state = { failEvents: false };
  const server = http.createServer((req, res) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => {
      let body = null;
      try { body = JSON.parse(Buffer.concat(chunks).toString('utf8') || 'null'); } catch { /* ignore */ }
      calls.push({ method: req.method, path: req.url, projectHeader: req.headers['x-project-id'], body });
      if (state.failEvents && req.url === '/api/v1/events') { res.writeHead(500); res.end('{}'); return; }
      res.writeHead(req.url === '/api/v1/events' ? 202 : 200, { 'Content-Type': 'application/json' });
      res.end('{"status":"ok"}');
    });
  });
  return { server, calls, state };
}

module.exports = { createMock };
