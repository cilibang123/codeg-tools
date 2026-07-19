# codeg quota sidecar

Local account-quota aggregator for the Codeg status bar (Claude / Codex / Grok chips).

- **Frontend** (shared Web + macOS/Windows desktop): reads `GET /summary`
- **This service**: holds tokens, calls provider / relay APIs, normalizes JSON

## Quick start

```bash
cd tools/quota-sidecar
# first run copies config.example.json → config.json
node server.mjs
```

Then open Codeg (desktop or web). The bottom status bar shows:

`Claude 42%  Codex $18.5/$50  Grok 1.2M/5M`

## Config

Edit `config.json`:

| `type` | Meaning | Risk |
|--------|---------|------|
| `mock` | Static demo numbers | none |
| `http_json` | `GET` a JSON URL you control (e.g. relay) | low |
| `codex_cli` | **Official** `codex app-server` → `account/rateLimits/read` (same as TUI `/status`) | **low / recommended** |
| `grok_cli_billing` | **Official Grok CLI** OIDC → `GET .../v1/billing?format=credits`（与交互里 `/usage` / ACP `x.ai/billing` 同源；**周额度 % + 重置日**） | **low / recommended** |
| `grok_cli_auth` | Local `~/.grok/auth.json` only (no remote usage) | low fallback |

### Codex (ChatGPT Pro/Plus subscription)

Requires `codex` on PATH and a prior `codex login` (ChatGPT auth). No API key needed.

```json
{ "id": "codex", "label": "Codex", "enabled": true, "type": "codex_cli" }
```

### Grok (CLI OAuth / SuperGrok)

There is **no documented remaining-quota API** for the SuperGrok weekly usage pool. Official visibility is the product Usage tab. This sidecar will **not** scrape grok.com.

Example for a relay:

```json
{
  "id": "claude",
  "label": "Claude",
  "enabled": true,
  "type": "http_json",
  "url": "https://your-relay.example/api/user/self",
  "headers": { "Authorization": "Bearer xxx" },
  "json_used": "data.quota.used",
  "json_limit": "data.quota.limit",
  "unit": "usd",
  "window": "month"
}
```

## Frontend config

`public/quota-config.json` (shipped with the UI build):

```json
{
  "enabled": true,
  "apiUrl": "auto",
  "refreshMs": 300000
}
```

Overrides in the browser/desktop webview:

```js
// Prefer apiUrl "auto" in quota-config.json (follows page hostname).
// Only set localStorage for non-loopback overrides, e.g. a reverse proxy URL:
// localStorage.setItem("codeg.quota.apiUrl", "https://codeg.example.com/quota/summary")
// localStorage.setItem("codeg.quota.enabled", "true")
// Clear a bad loopback override:
// localStorage.removeItem("codeg.quota.apiUrl")
```

## Why a sidecar?

Secrets never enter the React bundle. Codeg core stays untouched for billing logic, so upstream upgrades stay easy.
