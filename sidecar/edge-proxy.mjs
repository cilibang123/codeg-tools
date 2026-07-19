#!/usr/bin/env node
/**
 * Same-origin edge reverse proxy for Codeg + quota sidecar.
 *   /codeg-quota/*  →  127.0.0.1:3091/*
 *   everything else →  127.0.0.1:13080 (codeg-server)
 */
import http from "node:http"
import { URL } from "node:url"

const EDGE_HOST = process.env.CODEG_EDGE_HOST || "0.0.0.0"
const EDGE_PORT = Number(process.env.CODEG_EDGE_PORT || 3080)
const BACKEND_HOST = process.env.CODEG_BACKEND_HOST || "127.0.0.1"
const BACKEND_PORT = Number(process.env.CODEG_BACKEND_PORT || 13080)
const QUOTA_HOST = process.env.CODEG_QUOTA_HOST || "127.0.0.1"
const QUOTA_PORT = Number(process.env.CODEG_QUOTA_PORT || 3091)
const PREFIX = (process.env.CODEG_QUOTA_PREFIX || "/codeg-quota").replace(/\/$/, "")

function proxy(req, res, targetHost, targetPort, pathRewrite) {
  const headers = { ...req.headers, host: `${targetHost}:${targetPort}` }
  delete headers["accept-encoding"]
  const opts = {
    hostname: targetHost,
    port: targetPort,
    path: pathRewrite(req.url || "/"),
    method: req.method,
    headers,
  }
  const upstream = http.request(opts, (up) => {
    res.writeHead(up.statusCode || 502, up.headers)
    up.pipe(res)
  })
  upstream.on("error", (err) => {
    if (!res.headersSent) {
      res.writeHead(502, { "content-type": "application/json; charset=utf-8" })
    }
    res.end(JSON.stringify({
      error: "edge-proxy upstream error",
      target: `${targetHost}:${targetPort}`,
      message: err instanceof Error ? err.message : String(err),
    }))
  })
  req.pipe(upstream)
}

const server = http.createServer((req, res) => {
  const rawUrl = req.url || "/"
  let pathname = rawUrl
  try { pathname = new URL(rawUrl, "http://local").pathname } catch {}

  if (pathname === PREFIX || pathname.startsWith(PREFIX + "/")) {
    const rest = pathname === PREFIX ? "/" : pathname.slice(PREFIX.length) || "/"
    const q = rawUrl.includes("?") ? rawUrl.slice(rawUrl.indexOf("?")) : ""
    proxy(req, res, QUOTA_HOST, QUOTA_PORT, () => rest + q)
    return
  }
  proxy(req, res, BACKEND_HOST, BACKEND_PORT, (u) => u)
})

server.listen(EDGE_PORT, EDGE_HOST, () => {
  console.log(`[edge] public http://${EDGE_HOST}:${EDGE_PORT} → codeg ${BACKEND_HOST}:${BACKEND_PORT}`)
  console.log(`[edge] ${PREFIX}/* → quota ${QUOTA_HOST}:${QUOTA_PORT}/*`)
})
