#!/usr/bin/env node
/**
 * Local quota aggregator for Codeg status-bar chips.
 * Holds secrets / provider configs; frontend only GETs /summary.
 *
 * Supported provider types:
 *   mock          – static demo numbers
 *   http_json     – GET a JSON URL and map fields
 *   codex_cli         – official Codex app-server `account/rateLimits/read`
 *   grok_cli_billing  – official Grok CLI proxy `/v1/billing` (OIDC session)
 *   grok_cli_auth     – local Grok auth.json only (fallback, no remote usage)
 *
 *   node server.mjs
 *   node server.mjs --config ./config.json
 */
import http from "node:http"
import fs from "node:fs"
import path from "node:path"
import { spawn } from "node:child_process"
import { fileURLToPath } from "node:url"
import os from "node:os"
import readline from "node:readline"

const __dirname = path.dirname(fileURLToPath(import.meta.url))

function parseArgs(argv) {
  let configPath = path.join(__dirname, "config.json")
  for (let i = 2; i < argv.length; i++) {
    if (argv[i] === "--config" && argv[i + 1]) {
      configPath = path.resolve(argv[++i])
    }
  }
  return { configPath }
}

function loadConfig(configPath) {
  const example = path.join(__dirname, "config.example.json")
  if (!fs.existsSync(configPath)) {
    if (fs.existsSync(example)) {
      fs.copyFileSync(example, configPath)
      console.log(
        `[quota] created ${configPath} from example (edit credentials later)`
      )
    } else {
      throw new Error(`missing config: ${configPath}`)
    }
  }
  const raw = JSON.parse(fs.readFileSync(configPath, "utf8"))
  return {
    host: raw.host || "127.0.0.1",
    port: Number(raw.port) || 3091,
    cache_seconds: Number(raw.cache_seconds) || 120,
    cors_origins: Array.isArray(raw.cors_origins) ? raw.cors_origins : ["*"],
    providers: Array.isArray(raw.providers) ? raw.providers : [],
  }
}

function getByPath(obj, dotted) {
  if (!dotted || typeof dotted !== "string") return undefined
  const parts = dotted.replace(/^\$\./, "").split(".").filter(Boolean)
  let cur = obj
  for (const p of parts) {
    if (cur == null) return undefined
    cur = cur[p]
  }
  return cur
}

function expandHome(p) {
  if (!p) return p
  if (p.startsWith("~/")) return path.join(os.homedir(), p.slice(2))
  return p
}

function numOrNull(v) {
  if (v == null || v === "") return null
  const n = Number(v)
  return Number.isFinite(n) ? n : null
}

function formatWindowMins(mins) {
  if (mins == null) return null
  if (mins >= 10080) return "week"
  if (mins >= 1440) return `${Math.round(mins / 1440)}d`
  if (mins >= 60) return `${Math.round(mins / 60)}h`
  return `${mins}m`
}

function unixToIso(sec) {
  if (sec == null || !Number.isFinite(Number(sec))) return null
  try {
    return new Date(Number(sec) * 1000).toISOString()
  } catch {
    return null
  }
}

/**
 * Official Codex path: spawn `codex app-server --stdio` and call
 * account/rateLimits/read (same as TUI /status).
 */
function fetchCodexCli(p) {
  const bin = p.codex_bin || process.env.CODEX_BIN || "codex"
  const timeoutMs = Number(p.timeout_ms) || 20_000
  const limitId = p.limit_id || "codex"

  return new Promise((resolve, reject) => {
    const proc = spawn(bin, ["app-server", "--stdio"], {
      stdio: ["pipe", "pipe", "pipe"],
      env: process.env,
    })

    let settled = false
    const timer = setTimeout(() => {
      finish(new Error(`codex app-server timed out after ${timeoutMs}ms`))
    }, timeoutMs)

    const finish = (err, value) => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      try {
        proc.kill("SIGTERM")
      } catch {
        /* ignore */
      }
      if (err) reject(err)
      else resolve(value)
    }

    const rl = readline.createInterface({ input: proc.stdout })
    let nextId = 1
    const pending = new Map()

    const send = (method, params = {}) => {
      const id = nextId++
      const msg = { jsonrpc: "2.0", id, method, params }
      proc.stdin.write(JSON.stringify(msg) + "\n")
      return new Promise((res, rej) => {
        pending.set(id, { res, rej })
      })
    }

    rl.on("line", (line) => {
      line = line.trim()
      if (!line) return
      let msg
      try {
        msg = JSON.parse(line)
      } catch {
        return
      }
      if (msg.id != null && pending.has(msg.id)) {
        const { res, rej } = pending.get(msg.id)
        pending.delete(msg.id)
        if (msg.error) rej(new Error(JSON.stringify(msg.error)))
        else res(msg.result)
      }
    })

    proc.on("error", (err) => finish(err))
    proc.stderr.on("data", () => {
      /* bubblewrap warning etc. — ignore */
    })

    ;(async () => {
      try {
        await send("initialize", {
          clientInfo: { name: "codeg-quota-sidecar", version: "0.1.0" },
          capabilities: {},
        })
        const result = await send("account/rateLimits/read", {})
        finish(null, result)
      } catch (err) {
        finish(err)
      }
    })()
  }).then((result) => {
    const byId = result?.rateLimitsByLimitId || {}
    const snap =
      byId[limitId] || result?.rateLimits || Object.values(byId)[0] || null
    if (!snap) throw new Error("codex rateLimits response empty")

    const primary = snap.primary || {}
    const secondary = snap.secondary || null
    const used = numOrNull(primary.usedPercent)
    const windowMins = numOrNull(primary.windowDurationMins)
    const resetsAt = unixToIso(primary.resetsAt)
    const plan = snap.planType || null
    const remaining =
      used != null ? Math.max(0, Math.round(100 - used)) : null

    let display =
      used != null ? `${Math.round(used)}% used` : null
    if (remaining != null) display = `${remaining}% left`

    // Prefer primary weekly/5h; append secondary hint if present
    if (secondary && numOrNull(secondary.usedPercent) != null) {
      const sLeft = Math.max(0, Math.round(100 - secondary.usedPercent))
      display = `${display} · 5h ${sLeft}%`
    }

    return {
      id: p.id || "codex",
      label: p.label || "Codex",
      status: "ok",
      plan,
      window: formatWindowMins(windowMins) || p.window || "week",
      used,
      limit: 100,
      unit: "percent",
      display,
      resets_at: resetsAt,
      message: null,
    }
  })
}

function loadGrokAuthEntry(authPath) {
  const resolved = expandHome(authPath || "~/.grok/auth.json")
  if (!fs.existsSync(resolved)) {
    throw new Error(`Grok auth not found: ${resolved} (run: grok login)`)
  }
  const raw = JSON.parse(fs.readFileSync(resolved, "utf8"))
  const key = Object.keys(raw || {})[0]
  const entry = key ? raw[key] : null
  if (!entry) throw new Error("Grok auth.json has no sessions")
  return { authPath: resolved, storageKey: key, entry, raw }
}

function decodeJwtPayload(token) {
  if (typeof token !== "string" || token.split(".").length < 3) return null
  try {
    const payloadB64 = token.split(".")[1]
    const pad = "=".repeat((4 - (payloadB64.length % 4)) % 4)
    return JSON.parse(
      Buffer.from(payloadB64 + pad, "base64url").toString("utf8")
    )
  } catch {
    return null
  }
}

function jwtIsExpired(token, skewSec = 60) {
  const pl = decodeJwtPayload(token)
  if (!pl?.exp) return false
  return pl.exp * 1000 <= Date.now() + skewSec * 1000
}

/**
 * Refresh Grok OIDC access token with the stored refresh_token (same flow
 * as the official CLI). Writes back into auth.json when successful.
 */
async function refreshGrokAccessToken(authPath, storageKey, entry, raw) {
  const refresh = entry.refresh_token
  const clientId = entry.oidc_client_id
  if (!refresh || !clientId) {
    throw new Error("Grok auth missing refresh_token or oidc_client_id")
  }
  const body = new URLSearchParams({
    grant_type: "refresh_token",
    refresh_token: refresh,
    client_id: clientId,
  })
  const res = await fetch("https://auth.x.ai/oauth2/token", {
    method: "POST",
    headers: {
      "Content-Type": "application/x-www-form-urlencoded",
      Accept: "application/json",
    },
    body,
  })
  if (!res.ok) {
    const t = await res.text().catch(() => "")
    throw new Error(`Grok token refresh HTTP ${res.status}: ${t.slice(0, 200)}`)
  }
  const tok = await res.json()
  const access = tok.access_token || tok.id_token
  if (!access) throw new Error("Grok token refresh returned no access_token")

  const pl = decodeJwtPayload(access)
  entry.key = access
  if (tok.refresh_token) entry.refresh_token = tok.refresh_token
  if (pl?.exp) entry.expires_at = new Date(pl.exp * 1000).toISOString()
  raw[storageKey] = entry
  try {
    fs.writeFileSync(authPath, JSON.stringify(raw, null, 2) + "\n", {
      mode: 0o600,
    })
  } catch {
    /* best-effort persist */
  }
  return access
}

async function getGrokAccessToken(p) {
  const { authPath, storageKey, entry, raw } = loadGrokAuthEntry(
    p.auth_path || "~/.grok/auth.json"
  )
  let token = entry.key
  if (!token) throw new Error("Grok auth has empty access token")
  if (jwtIsExpired(token)) {
    token = await refreshGrokAccessToken(authPath, storageKey, entry, raw)
  }
  return { token, entry }
}

/**
 * Official Grok CLI unified weekly billing — same source as interactive
 * `/usage` / ACP `x.ai/billing`:
 *   GET https://cli-chat-proxy.grok.com/v1/billing?format=credits
 *
 * NOTE: without `?format=credits` the endpoint returns monthly "extra
 * credits" (not SuperGrok Heavy weekly %). Must use format=credits.
 */
async function fetchGrokCliBilling(p) {
  // Prefer explicit URL; default is the /usage-equivalent weekly format.
  let baseUrl = (
    p.billing_url ||
    "https://cli-chat-proxy.grok.com/v1/billing?format=credits"
  ).trim()
  // If config still points at bare /billing, force weekly credits format.
  if (
    /\/v1\/billing\/?$/i.test(baseUrl.split("?")[0]) &&
    !/[?&]format=/i.test(baseUrl)
  ) {
    baseUrl += (baseUrl.includes("?") ? "&" : "?") + "format=credits"
  }

  const { token, entry } = await getGrokAccessToken(p)

  const headers = {
    Authorization: `Bearer ${token}`,
    Accept: "application/json",
    "User-Agent": "GrokCLI/0.2.103",
    "x-grok-client-version": "0.2.103",
  }

  const doFetch = async (tok) => {
    const ac = new AbortController()
    const timer = setTimeout(() => ac.abort(), Number(p.timeout_ms) || 12_000)
    try {
      return await fetch(baseUrl, {
        headers: { ...headers, Authorization: `Bearer ${tok}` },
        signal: ac.signal,
      })
    } finally {
      clearTimeout(timer)
    }
  }

  let res = await doFetch(token)

  // One retry after forced refresh on 401
  if (res.status === 401) {
    const { authPath, storageKey, entry: e2, raw } = loadGrokAuthEntry(
      p.auth_path || "~/.grok/auth.json"
    )
    const fresh = await refreshGrokAccessToken(authPath, storageKey, e2, raw)
    res = await doFetch(fresh)
  }

  if (!res.ok) {
    const t = await res.text().catch(() => "")
    throw new Error(`Grok billing HTTP ${res.status}: ${t.slice(0, 200)}`)
  }

  const data = await res.json()
  const cfg = data?.config || data || {}

  // Weekly SuperGrok Heavy pool (matches Settings → 使用量 / /usage)
  const usedPct = numOrNull(cfg.creditUsagePercent)
  const period =
    cfg.currentPeriod ||
    (cfg.billingPeriodStart || cfg.billingPeriodEnd
      ? {
          type: "USAGE_PERIOD_TYPE_WEEKLY",
          start: cfg.billingPeriodStart,
          end: cfg.billingPeriodEnd,
        }
      : null)
  const periodEnd =
    period?.end || cfg.billingPeriodEnd || cfg.billing_period_end || null
  const periodStart =
    period?.start || cfg.billingPeriodStart || cfg.billing_period_start || null
  const periodType = period?.type || ""

  // Prefer GrokBuild product slice when present (what /usage highlights)
  let productPct = null
  let productName = null
  if (Array.isArray(cfg.productUsage)) {
    const build =
      cfg.productUsage.find(
        (x) =>
          String(x.product || "")
            .toLowerCase()
            .includes("build") && x.usagePercent != null
      ) || cfg.productUsage.find((x) => x.usagePercent != null)
    if (build) {
      productPct = numOrNull(build.usagePercent)
      productName = build.product || null
    }
  }

  const used = usedPct != null ? usedPct : productPct
  const left =
    used != null ? Math.max(0, Math.round(100 - Number(used))) : null

  let display = null
  if (used != null) {
    // Match UI wording: "1% 已使用" → chip shows remaining or used clearly
    display = `${Math.round(Number(used))}% used`
    if (left != null && left < 100) {
      display = `${Math.round(Number(used))}% · ${left}% left`
    }
  }

  // Plan: settings-style tier if available on response, else JWT/settings fallback
  let plan =
    data?.subscription_tier ||
    data?.subscriptionTier ||
    p.plan ||
    null
  if (!plan) {
    try {
      const settingsUrl =
        p.settings_url || "https://cli-chat-proxy.grok.com/v1/settings"
      const sres = await fetch(settingsUrl, {
        headers: {
          Authorization: `Bearer ${token}`,
          Accept: "application/json",
          "User-Agent": "GrokCLI/0.2.103",
        },
      })
      if (sres.ok) {
        const s = await sres.json()
        plan = s.subscription_tier_display || s.subscription_tier || null
      }
    } catch {
      /* ignore */
    }
  }
  if (!plan) {
    const pl = decodeJwtPayload(token)
    plan =
      (pl?.tier != null ? `tier ${pl.tier}` : null) ||
      entry.principal_type ||
      "Grok"
  }

  const isWeekly =
    String(periodType).toUpperCase().includes("WEEK") ||
    (periodStart && periodEnd)

  const msgParts = []
  if (productName && productPct != null) {
    msgParts.push(`${productName} ${Math.round(productPct)}%`)
  }
  if (periodStart && periodEnd) {
    msgParts.push(
      `week ${String(periodStart).slice(0, 10)} → ${String(periodEnd).slice(0, 10)}`
    )
  }

  return {
    id: p.id || "grok",
    label: p.label || "Grok",
    status: "ok",
    plan,
    window: isWeekly ? "week" : "month",
    used: used != null ? Number(used) : null,
    limit: 100,
    unit: "percent",
    display,
    resets_at: periodEnd,
    message: msgParts.length ? msgParts.join(" · ") : null,
  }
}

/** Fallback: local auth metadata only (no remote). */
function fetchGrokCliAuth(p) {
  const { entry } = loadGrokAuthEntry(p.auth_path || "~/.grok/auth.json")
  const pl = decodeJwtPayload(entry.key || "")
  const tier = pl?.tier != null ? String(pl.tier) : null
  return {
    id: p.id || "grok",
    label: p.label || "Grok",
    status: "ok",
    plan: tier != null ? `tier ${tier}` : entry.principal_type || "subscribed",
    window: "month",
    used: null,
    limit: null,
    unit: null,
    display: "auth only",
    resets_at: null,
    message: `CLI logged in as ${entry.email || "user"}; enable type grok_cli_billing for usage`,
  }
}

function formatCompactNum(n) {
  if (Math.abs(n) >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`
  if (Math.abs(n) >= 1_000) return `${(n / 1_000).toFixed(1)}K`
  return String(n)
}

async function fetchHttpJson(p, base) {
  if (!p.url) throw new Error("http_json requires url")
  const headers = {
    Accept: "application/json",
    ...(p.headers && typeof p.headers === "object" ? p.headers : {}),
  }
  const ac = new AbortController()
  const timer = setTimeout(() => ac.abort(), Number(p.timeout_ms) || 8000)
  let res
  try {
    res = await fetch(p.url, { headers, signal: ac.signal })
  } finally {
    clearTimeout(timer)
  }
  if (!res.ok) throw new Error(`upstream HTTP ${res.status}`)
  const body = await res.json()
  const used = numOrNull(getByPath(body, p.json_used || "used"))
  const limit = numOrNull(getByPath(body, p.json_limit || "limit"))
  let display = getByPath(body, p.json_display || "display")
  if (display != null) display = String(display)
  else display = null
  return {
    ...base,
    status: "ok",
    used,
    limit,
    display,
    resets_at: getByPath(body, p.json_resets_at || "resets_at") ?? null,
  }
}

async function fetchProvider(p) {
  if (!p.enabled) {
    return {
      id: p.id,
      label: p.label || p.id,
      status: "disabled",
    }
  }

  const base = {
    id: p.id,
    label: p.label || p.id,
    plan: p.plan ?? null,
    window: p.window ?? null,
    unit: p.unit ?? null,
  }

  try {
    if (p.type === "mock" || !p.type) {
      return {
        ...base,
        status: "ok",
        used: p.used ?? null,
        limit: p.limit ?? null,
        display: p.display ?? null,
        resets_at: p.resets_at ?? null,
      }
    }

    if (p.type === "http_json") {
      return await fetchHttpJson(p, base)
    }

    if (p.type === "codex_cli") {
      return await fetchCodexCli(p)
    }

    if (p.type === "grok_cli_billing") {
      return await fetchGrokCliBilling(p)
    }

    if (p.type === "grok_cli_auth") {
      return fetchGrokCliAuth(p)
    }

    throw new Error(`unknown provider type: ${p.type}`)
  } catch (err) {
    return {
      ...base,
      status: "error",
      message: err instanceof Error ? err.message : String(err),
    }
  }
}

function createCache(ttlSec) {
  let entry = null
  return {
    async get(factory) {
      const now = Date.now()
      if (entry && now - entry.at < ttlSec * 1000) return entry.value
      const value = await factory()
      entry = { at: now, value }
      return value
    },
    clear() {
      entry = null
    },
  }
}

async function buildSummary(cfg) {
  const providers = await Promise.all(cfg.providers.map((p) => fetchProvider(p)))
  return {
    updated_at: new Date().toISOString(),
    providers,
  }
}

function sendJson(res, status, body, corsOrigin) {
  const headers = {
    "Cache-Control": "no-store",
  }
  if (status !== 204) {
    headers["Content-Type"] = "application/json; charset=utf-8"
  }
  if (corsOrigin) {
    headers["Access-Control-Allow-Origin"] = corsOrigin
    headers["Access-Control-Allow-Methods"] = "GET, OPTIONS"
    headers["Access-Control-Allow-Headers"] =
      "Accept, Content-Type, Authorization"
  }
  res.writeHead(status, headers)
  if (status === 204) {
    res.end()
    return
  }
  res.end(JSON.stringify(body))
}

function pickCors(cfg, req) {
  const origins = cfg.cors_origins || ["*"]
  if (origins.includes("*")) return "*"
  const origin = req.headers.origin
  if (origin && origins.includes(origin)) return origin
  return origins[0] || "*"
}

/**
 * Collect non-loopback IPv4 addresses for the host status-bar chip.
 * Prefer physical/LAN interfaces over docker/bridge/veth noise.
 */
function collectHostInfo() {
  const ifaces = os.networkInterfaces() || {}
  const addresses = []
  for (const [name, list] of Object.entries(ifaces)) {
    for (const entry of list || []) {
      const family = entry.family
      const isV4 = family === "IPv4" || family === 4
      if (!isV4 || entry.internal) continue
      addresses.push({
        name,
        address: entry.address,
        cidr: entry.cidr || null,
      })
    }
  }

  const score = (item) => {
    const n = String(item.name || "").toLowerCase()
    let s = 0
    if (/^(eth|en|eno|ens|enp|wlan|wlp|wl|wifi|em|bond)/.test(n)) s += 50
    if (/^(docker|br-|veth|virbr|cni|flannel|cali|tun|tap|lo)/.test(n)) s -= 40
    const a = item.address || ""
    if (a.startsWith("192.168.")) s += 20
    else if (a.startsWith("10.")) s += 15
    else if (/^172\.(1[6-9]|2\d|3[0-1])\./.test(a)) s += 10
    // docker default bridge range often 172.17–19
    if (/^172\.(1[7-9]|2[0-9]|3[0-1])\./.test(a) && /docker|br-/.test(n))
      s -= 20
    return s
  }

  addresses.sort((a, b) => score(b) - score(a) || a.address.localeCompare(b.address))

  return {
    hostname: os.hostname(),
    primary: addresses[0]?.address || null,
    addresses,
    updated_at: new Date().toISOString(),
  }
}

async function main() {
  const { configPath } = parseArgs(process.argv)
  const cfg = loadConfig(configPath)
  const cache = createCache(cfg.cache_seconds)

  const server = http.createServer(async (req, res) => {
    const cors = pickCors(cfg, req)
    const url = new URL(req.url || "/", `http://${cfg.host}:${cfg.port}`)

    if (req.method === "OPTIONS") {
      sendJson(res, 204, {}, cors)
      return
    }

    if (
      req.method === "GET" &&
      (url.pathname === "/health" || url.pathname === "/")
    ) {
      sendJson(res, 200, { ok: true, service: "codeg-quota-sidecar" }, cors)
      return
    }

    if (req.method === "GET" && url.pathname === "/host") {
      sendJson(res, 200, collectHostInfo(), cors)
      return
    }

    if (req.method === "GET" && url.pathname === "/summary") {
      try {
        if (url.searchParams.get("refresh") === "1") cache.clear()
        const summary = await cache.get(() => buildSummary(cfg))
        sendJson(res, 200, summary, cors)
      } catch (err) {
        sendJson(
          res,
          500,
          { error: err instanceof Error ? err.message : String(err) },
          cors
        )
      }
      return
    }

    sendJson(res, 404, { error: "not found" }, cors)
  })

  server.listen(cfg.port, cfg.host, () => {
    console.log(
      `[quota] listening on http://${cfg.host}:${cfg.port}  config=${configPath}`
    )
    console.log(`[quota] GET /summary  GET /host  GET /health`)
  })
}

main().catch((err) => {
  console.error("[quota] fatal:", err)
  process.exit(1)
})
