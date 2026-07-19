#!/usr/bin/env bash
# codeg-tools — smart installer for quota UI + sidecar
#
#   curl -fsSL https://raw.githubusercontent.com/cilibang123/codeg-tools/main/get.sh | sudo bash
#   ./install.sh
#   ./install.sh --desktop
#
# Design goals:
#   1) Work across messy deployments (systemd unit names, env files, nginx/caddy,
#      HTTPS reverse proxy, LAN direct :3080, desktop app).
#   2) Prefer same-origin /codeg-quota/* for the browser (no mixed-content, no
#      extra public port). Choose the least invasive way to provide that path.
#   3) Always leave a working sidecar; never brick codeg.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="1.5.2"

# ── knobs ─────────────────────────────────────────────────────────────
OS_MODE="auto"          # auto | linux | macos | menu
DO_SIDECAR=1
DO_WEB=1
DO_DESKTOP=0
WEB_DIR_OVERRIDE=""
DESKTOP_APP_OVERRIDE=""
BIND_HOST=""            # empty = auto
PORT="${CODEG_QUOTA_PORT:-3091}"
CODEG_PUBLIC_PORT="${CODEG_PUBLIC_PORT:-3080}"
CODEG_BACKEND_PORT="${CODEG_BACKEND_PORT:-13080}"
QUOTA_PREFIX="/codeg-quota"
ACCESS_MODE=""          # filled by probe: nginx | caddy | edge | direct
CODEG_UNIT=""
CODEG_LISTEN_PORT=""
CODEG_LISTEN_HOST=""

log()  { printf '==> %s\n' "$*"; }
warn() { printf '!!  %s\n' "$*" >&2; }
die()  { printf 'xx  %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
is_root() { [[ "$(id -u)" -eq 0 ]]; }

usage() {
  cat <<EOF
codeg-tools installer v${VERSION}

  ./install.sh                 full auto
  ./install.sh --desktop       also inject macOS .app web
  ./install.sh --web-dir PATH  force WebUI static dir
  ./install.sh --sidecar-only / --web-only
  ./install.sh --os linux|macos|auto
  ./install.sh --bind 0.0.0.0 --port 3091

One-liner:
  curl -fsSL https://raw.githubusercontent.com/cilibang123/codeg-tools/main/get.sh | sudo bash
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage ;;
    --os) OS_MODE="${2:-}"; shift 2 ;;
    --os=*) OS_MODE="${1#*=}"; shift ;;
    --linux) OS_MODE=linux; shift ;;
    --macos|--mac) OS_MODE=macos; shift ;;
    --auto) OS_MODE=auto; shift ;;
    --menu) OS_MODE=menu; shift ;;
    --desktop) DO_DESKTOP=1; shift ;;
    --no-desktop) DO_DESKTOP=0; shift ;;
    --sidecar-only) DO_SIDECAR=1; DO_WEB=0; shift ;;
    --web-only) DO_SIDECAR=0; DO_WEB=1; shift ;;
    --web-dir) WEB_DIR_OVERRIDE="${2:-}"; shift 2 ;;
    --web-dir=*) WEB_DIR_OVERRIDE="${1#*=}"; shift ;;
    --app) DESKTOP_APP_OVERRIDE="${2:-}"; shift 2 ;;
    --app=*) DESKTOP_APP_OVERRIDE="${1#*=}"; shift ;;
    --bind) BIND_HOST="${2:-}"; shift 2 ;;
    --port) PORT="${2:-}"; shift 2 ;;
    -q|--quiet) shift ;;
    -y|--yes) shift ;;
    *) die "unknown arg: $1 (try --help)" ;;
  esac
done

# ── OS ────────────────────────────────────────────────────────────────
detect_os() {
  case "$(uname -s 2>/dev/null || echo unknown)" in
    Linux*)  echo linux ;;
    Darwin*) echo macos ;;
    *)       echo unknown ;;
  esac
}

resolve_os() {
  local detected; detected="$(detect_os)"
  case "$OS_MODE" in
    auto)
      [[ "$detected" != "unknown" ]] || die "unknown OS: $(uname -s 2>/dev/null || true)"
      echo "$detected" ;;
    linux|macos) echo "$OS_MODE" ;;
    menu)
      echo ""
      echo "  codeg-tools v${VERSION}  (detected: ${detected})"
      echo "  1) Linux WebUI"
      echo "  2) macOS WebUI"
      echo "  3) macOS WebUI + desktop App"
      echo "  4) auto"
      read -r -p "  choose [4]: " c || true
      c="${c:-4}"
      case "$c" in
        1) echo linux ;;
        2) echo macos ;;
        3) DO_DESKTOP=1; echo macos ;;
        *) [[ "$detected" != "unknown" ]] || die "cannot auto-detect OS"; echo "$detected" ;;
      esac ;;
    *) die "invalid --os: $OS_MODE" ;;
  esac
}

TARGET_OS="$(resolve_os)"
log "OS: ${TARGET_OS}"
[[ "$DO_DESKTOP" -eq 1 && "$TARGET_OS" != "macos" ]] && DO_DESKTOP=0

if [[ "$TARGET_OS" == "linux" ]]; then
  if is_root; then PREFIX="${PREFIX:-/opt/codeg-quota}"
  else PREFIX="${PREFIX:-$HOME/.local/share/codeg-quota}"; fi
else
  PREFIX="${PREFIX:-$HOME/Library/Application Support/codeg-quota}"
fi

# Real interactive user (critical on macOS when using sudo)
REAL_USER="${CODEG_TOOLS_REAL_USER:-${SUDO_USER:-${USER:-$(id -un)}}}"
if [[ "$(id -u)" -eq 0 && -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
  REAL_USER="$SUDO_USER"
fi
if [[ -n "${CODEG_TOOLS_REAL_HOME:-}" ]]; then
  REAL_HOME="$CODEG_TOOLS_REAL_HOME"
elif [[ "$(id -u)" -eq 0 && -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
  REAL_HOME="$(eval echo "~${SUDO_USER}")"
else
  REAL_HOME="${HOME}"
fi
if [[ "$TARGET_OS" == "macos" ]]; then
  PREFIX="${CODEG_TOOLS_PREFIX:-$REAL_HOME/Library/Application Support/codeg-quota}"
fi


# ══════════════════════════════════════════════════════════════════════
# Phase 0 — probe environment (read-only)
# ══════════════════════════════════════════════════════════════════════

find_codeg_unit() {
  local u
  for u in codeg-server codeg codeg-web codeg_server; do
    systemctl cat "${u}.service" >/dev/null 2>&1 || continue
    echo "$u"; return 0
  done
  local f
  for f in /etc/systemd/system/codeg*.service /lib/systemd/system/codeg*.service \
           /usr/lib/systemd/system/codeg*.service; do
    [[ -f "$f" ]] || continue
    case "$(basename "$f")" in
      codeg-quota*|codeg-edge*|codeg-tools*) continue ;;
    esac
    echo "$(basename "$f" .service)"; return 0
  done
  return 1
}

# Print "host:port" of the first codeg-server listen address, or empty.
probe_codeg_listen() {
  local line host port
  # ss: "LISTEN ... 127.0.0.1:3080 ... users:(("codeg-server",..."
  if have ss; then
    line="$(ss -tlnp 2>/dev/null | grep -E 'codeg-server|codeg_server' | head -1 || true)"
    if [[ -n "$line" ]]; then
      # last host:port before users=
      port="$(echo "$line" | grep -oE '[0-9\.:\[\]]+:[0-9]+' | tail -1 || true)"
      if [[ -n "$port" ]]; then
        echo "$port"
        return 0
      fi
    fi
    # fallback: known ports with codeg
    for port in 3080 13080 8080 3000; do
      if ss -tlnp 2>/dev/null | grep -E ":${port}\\b" | grep -qiE 'codeg'; then
        host="$(ss -tlnp 2>/dev/null | grep -E ":${port}\\b" | grep -i codeg | grep -oE '[0-9\.:\[\]]+:'${port} | head -1 || true)"
        echo "${host:-0.0.0.0:$port}"
        return 0
      fi
    done
  fi
  return 1
}

# List reverse-proxy config files that point at a given backend port.
list_rp_configs_for_port() {
  local backend_port="$1"
  local f
  # nginx
  if have nginx; then
    for f in /etc/nginx/sites-enabled/* /etc/nginx/conf.d/*.conf /etc/nginx/nginx.conf; do
      [[ -e "$f" ]] || continue
      if grep -qE "proxy_pass[[:space:]]+https?://(127\\.0\\.0\\.1|localhost|\\[::1\\]):${backend_port}\\b" "$f" 2>/dev/null; then
        echo "$f"
      fi
    done
  fi
  # caddy (Caddyfile often plain text)
  if have caddy; then
    for f in /etc/caddy/Caddyfile /usr/local/etc/caddy/Caddyfile "$HOME/.config/caddy/Caddyfile"; do
      [[ -f "$f" ]] || continue
      if grep -qE ":${backend_port}\\b|localhost:${backend_port}|127\\.0\\.0\\.1:${backend_port}" "$f" 2>/dev/null; then
        echo "$f"
      fi
    done
  fi
}

# Does any reverse proxy terminate TLS for something that hits codeg?
rp_looks_https() {
  local f
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    if grep -qiE 'listen[[:space:]]+[0-9]*443|ssl_certificate|https://|tls ' "$f" 2>/dev/null; then
      return 0
    fi
  done < <(list_rp_configs_for_port "${CODEG_LISTEN_PORT:-3080}" || true)
  # also scan any nginx ssl server that mentions codeg in name
  if have nginx; then
    for f in /etc/nginx/sites-enabled/*; do
      [[ -e "$f" ]] || continue
      if grep -qiE 'ssl_certificate' "$f" 2>/dev/null && \
         grep -qE '3080|codeg' "$f" 2>/dev/null; then
        return 0
      fi
    done
  fi
  return 1
}

probe_environment() {
  log "探测环境…"

  if [[ "$TARGET_OS" == "linux" ]] && have systemctl; then
    CODEG_UNIT="$(find_codeg_unit || true)"
    [[ -n "$CODEG_UNIT" ]] && log "  codeg unit: ${CODEG_UNIT}.service"
  fi

  local listen
  if listen="$(probe_codeg_listen)"; then
    CODEG_LISTEN_HOST="${listen%:*}"
    CODEG_LISTEN_PORT="${listen##*:}"
    # strip brackets from ipv6 if any
    CODEG_LISTEN_HOST="${CODEG_LISTEN_HOST#\[}"
    CODEG_LISTEN_HOST="${CODEG_LISTEN_HOST%\]}"
    log "  codeg listen: ${CODEG_LISTEN_HOST}:${CODEG_LISTEN_PORT}"
    CODEG_PUBLIC_PORT="${CODEG_LISTEN_PORT}"
  else
    CODEG_LISTEN_PORT="${CODEG_PUBLIC_PORT}"
    CODEG_LISTEN_HOST="127.0.0.1"
    log "  codeg listen: (not detected, assume :${CODEG_PUBLIC_PORT})"
  fi

  local rp_count=0
  local f
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    rp_count=$((rp_count + 1))
    log "  reverse-proxy → codeg: $f"
  done < <(list_rp_configs_for_port "$CODEG_LISTEN_PORT" || true)

  if ((rp_count > 0)); then
    if have nginx && list_rp_configs_for_port "$CODEG_LISTEN_PORT" 2>/dev/null | grep -q nginx; then
      ACCESS_MODE="nginx"
    elif have caddy; then
      ACCESS_MODE="caddy"
    else
      ACCESS_MODE="nginx" # treat as generic RP file we can try to patch like nginx
    fi
  elif rp_looks_https; then
    ACCESS_MODE="nginx"
  else
    # No RP: decide edge vs direct later
    if is_root && [[ "$TARGET_OS" == "linux" ]]; then
      ACCESS_MODE="edge"
    else
      ACCESS_MODE="direct"
    fi
  fi

  if [[ "$TARGET_OS" == "macos" ]]; then
    ACCESS_MODE="direct"
  fi

  if [[ "$ACCESS_MODE" == "nginx" || "$ACCESS_MODE" == "caddy" ]]; then
    log "  access mode: reverse-proxy (${ACCESS_MODE}) — inject ${QUOTA_PREFIX}/"
  elif [[ "$ACCESS_MODE" == "edge" ]]; then
    log "  access mode: edge on :${CODEG_PUBLIC_PORT} (codeg → :${CODEG_BACKEND_PORT})"
  else
    log "  access mode: direct sidecar :${PORT}"
  fi

  if [[ -z "$BIND_HOST" ]]; then
    if [[ "$TARGET_OS" == "macos" ]]; then
      BIND_HOST="127.0.0.1"
    elif [[ "$ACCESS_MODE" == "direct" ]]; then
      BIND_HOST="0.0.0.0"
    else
      BIND_HOST="127.0.0.1"
    fi
  fi
  log "  sidecar bind: ${BIND_HOST}:${PORT}"
  log "  service user: ${REAL_USER:-?}  home: ${REAL_HOME:-?}"
}

# ══════════════════════════════════════════════════════════════════════
# Phase 1 — sidecar
# ══════════════════════════════════════════════════════════════════════

need_node() {
  have node || die "node not found — install Node.js first"
  log "Node: $(node -v)"
}

resolve_codex_bin() {
  local p
  for p in \
    "$(command -v codex 2>/dev/null || true)" \
    /root/.local/bin/codex \
    "$HOME/.local/bin/codex" \
    /usr/local/bin/codex \
    /usr/bin/codex
  do
    [[ -n "$p" && -x "$p" ]] && { echo "$p"; return 0; }
  done
  return 1
}

resolve_home_for_service() {
  if [[ -n "${REAL_HOME:-}" ]]; then echo "$REAL_HOME"
  elif is_root; then echo /root
  else echo "$HOME"; fi
}

write_sidecar_config() {
  local cfg="$PREFIX/config.json"
  local host="$1" port="$2"
  if [[ ! -f "$cfg" ]]; then
    cp -f "$ROOT/sidecar/config.example.json" "$cfg"
  fi
  local codex_bin=""
  codex_bin="$(resolve_codex_bin || true)"
  if have python3; then
    python3 - "$cfg" "$host" "$port" "$codex_bin" <<'PY'
import json, sys
path, host, port, codex = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
cfg = json.load(open(path))
cfg["host"] = host
cfg["port"] = port
if codex:
    for p in cfg.get("providers", []):
        if p.get("type") == "codex_cli":
            p["codex_bin"] = codex
json.dump(cfg, open(path, "w"), indent=2, ensure_ascii=False)
open(path, "a").write("\n")
PY
  fi
}

install_sidecar_systemd() {
  local node_bin home_dir path_env unit
  node_bin="$(command -v node)"
  home_dir="$(resolve_home_for_service)"
  path_env="/root/.local/bin:${home_dir}/.local/bin:/usr/local/bin:/usr/bin:/bin:/snap/bin"

  if ! is_root; then
    local udir="$HOME/.config/systemd/user"
    mkdir -p "$udir"
    unit="$udir/codeg-quota.service"
    cat > "$unit" <<EOF
[Unit]
Description=Codeg quota sidecar
After=network-online.target

[Service]
Type=simple
WorkingDirectory=${PREFIX}
Environment=HOME=${home_dir}
Environment=PATH=${path_env}
ExecStart=${node_bin} ${PREFIX}/server.mjs --config ${PREFIX}/config.json
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
EOF
    systemctl --user daemon-reload 2>/dev/null || true
    systemctl --user enable --now codeg-quota.service 2>/dev/null || {
      warn "user systemd unavailable — starting sidecar with nohup"
      nohup "${node_bin}" "${PREFIX}/server.mjs" --config "${PREFIX}/config.json" \
        >"${PREFIX}/sidecar.log" 2>&1 &
      echo $! >"${PREFIX}/sidecar.pid"
    }
    log "sidecar started (user)"
    return
  fi

  unit="/etc/systemd/system/codeg-quota.service"
  cat > "$unit" <<EOF
[Unit]
Description=Codeg quota sidecar (codeg-tools)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${PREFIX}
Environment=HOME=${home_dir}
Environment=USER=root
Environment=PATH=${path_env}
ExecStart=${node_bin} ${PREFIX}/server.mjs --config ${PREFIX}/config.json
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
  mkdir -p /etc/systemd/system/codeg-quota.service.d
  cat > /etc/systemd/system/codeg-quota.service.d/path.conf <<EOF
[Service]
Environment=HOME=${home_dir}
Environment=PATH=${path_env}
EOF
  systemctl daemon-reload
  systemctl enable --now codeg-quota.service
  systemctl restart codeg-quota.service
  log "systemd: codeg-quota.service running"
}

install_sidecar_launchd() {
  # Always install LaunchAgent for the REAL user (not root), so ~/.codex ~/.grok work.
  local label="com.codeg.quota"
  local user_home agent_dir plist logs node_bin uid
  user_home="${REAL_HOME:-$HOME}"
  agent_dir="${user_home}/Library/LaunchAgents"
  plist="${agent_dir}/${label}.plist"
  logs="${PREFIX}/logs"
  node_bin="$(command -v node)"
  mkdir -p "$agent_dir" "$logs" "$PREFIX"

  if is_root && [[ -n "${REAL_USER:-}" && "$REAL_USER" != "root" ]]; then
    chown -R "${REAL_USER}:staff" "$PREFIX" 2>/dev/null || chown -R "${REAL_USER}" "$PREFIX" 2>/dev/null || true
    chown -R "${REAL_USER}:staff" "$agent_dir" 2>/dev/null || true
  fi

  cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${label}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${node_bin}</string>
    <string>${PREFIX}/server.mjs</string>
    <string>--config</string>
    <string>${PREFIX}/config.json</string>
  </array>
  <key>WorkingDirectory</key><string>${PREFIX}</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>${logs}/stdout.log</string>
  <key>StandardErrorPath</key><string>${logs}/stderr.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key><string>${user_home}</string>
    <key>USER</key><string>${REAL_USER:-$USER}</string>
    <key>PATH</key><string>${user_home}/.local/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin</string>
  </dict>
</dict>
</plist>
PLIST

  if is_root && [[ -n "${REAL_USER:-}" && "$REAL_USER" != "root" ]]; then
    chown "${REAL_USER}:staff" "$plist" 2>/dev/null || chown "${REAL_USER}" "$plist" 2>/dev/null || true
    uid="$(id -u "$REAL_USER" 2>/dev/null || true)"
    if [[ -n "$uid" ]]; then
      launchctl bootout "gui/${uid}/${label}" 2>/dev/null || true
      sudo -u "$REAL_USER" launchctl bootout "gui/${uid}/${label}" 2>/dev/null || true
      sudo -u "$REAL_USER" launchctl bootstrap "gui/${uid}" "$plist" 2>/dev/null \
        || sudo -u "$REAL_USER" launchctl load -w "$plist" 2>/dev/null \
        || true
      sudo -u "$REAL_USER" launchctl enable "gui/${uid}/${label}" 2>/dev/null || true
      sudo -u "$REAL_USER" launchctl kickstart -k "gui/${uid}/${label}" 2>/dev/null || true
      log "launchd (user ${REAL_USER}): ${label}"
      return 0
    fi
  fi

  uid="$(id -u)"
  launchctl bootout "gui/${uid}/${label}" 2>/dev/null || true
  launchctl unload "$plist" 2>/dev/null || true
  launchctl bootstrap "gui/${uid}" "$plist" 2>/dev/null || launchctl load -w "$plist" 2>/dev/null || true
  launchctl kickstart -k "gui/${uid}/${label}" 2>/dev/null || true
  log "launchd: ${label} (HOME=${user_home})"
}


install_sidecar() {
  need_node
  log "install sidecar → ${PREFIX}"
  mkdir -p "$PREFIX"
  cp -f "$ROOT/sidecar/server.mjs" "$PREFIX/server.mjs"
  [[ -f "$ROOT/sidecar/edge-proxy.mjs" ]] && cp -f "$ROOT/sidecar/edge-proxy.mjs" "$PREFIX/edge-proxy.mjs"
  chmod 755 "$PREFIX/server.mjs" 2>/dev/null || true
  write_sidecar_config "$BIND_HOST" "$PORT"
  if [[ "$TARGET_OS" == "linux" ]]; then
    install_sidecar_systemd
  else
    install_sidecar_launchd
  fi
}

# ══════════════════════════════════════════════════════════════════════
# Phase 2 — WebUI deploy
# ══════════════════════════════════════════════════════════════════════

discover_web_dirs() {
  local -a found=()
  local d line val f pid

  if [[ -n "$WEB_DIR_OVERRIDE" ]]; then
    [[ -d "$WEB_DIR_OVERRIDE" ]] || die "--web-dir missing: $WEB_DIR_OVERRIDE"
    echo "$WEB_DIR_OVERRIDE"; return 0
  fi

  if [[ -n "${CODEG_STATIC_DIR:-}" && -d "${CODEG_STATIC_DIR}" ]]; then
    found+=("${CODEG_STATIC_DIR}")
  fi

  # running process env
  if have pgrep; then
    while read -r pid; do
      [[ -z "$pid" || ! -r "/proc/$pid/environ" ]] && continue
      val="$(tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null | grep -E '^CODEG_STATIC_DIR=' | head -1 | cut -d= -f2- || true)"
      [[ -n "$val" && -d "$val" ]] && found+=("$val")
    done < <(pgrep -f 'codeg-server' 2>/dev/null || true)
  fi

  # env files (all known names)
  for f in /etc/codeg/codeg.env /etc/codeg/codeg-server.env \
           /usr/local/etc/codeg/codeg-server.env \
           "$HOME/.config/codeg/codeg-server.env" "$HOME/.config/codeg/codeg.env"; do
    [[ -f "$f" ]] || continue
    line="$(grep -E '^[[:space:]]*CODEG_STATIC_DIR=' "$f" 2>/dev/null | tail -1 || true)"
    val="${line#*CODEG_STATIC_DIR=}"; val="${val//\"/}"; val="${val//\'/}"
    val="$(echo "$val" | xargs 2>/dev/null || echo "$val")"
    [[ -n "$val" && -d "$val" ]] && found+=("$val")
  done

  # systemd EnvironmentFile + show
  if have systemctl && [[ -n "${CODEG_UNIT:-}" ]]; then
    line="$(systemctl show -p EnvironmentFiles "${CODEG_UNIT}.service" --value 2>/dev/null | head -1 || true)"
    f="${line%% *}"; f="${f//\"/}"
    if [[ -f "$f" ]]; then
      line="$(grep -E '^[[:space:]]*CODEG_STATIC_DIR=' "$f" 2>/dev/null | tail -1 || true)"
      val="${line#*CODEG_STATIC_DIR=}"; val="${val//\"/}"
      [[ -n "$val" && -d "$val" ]] && found+=("$val")
    fi
  fi

  local candidates=(
    /usr/local/share/codeg/web
    /usr/share/codeg/web
    /opt/codeg/web
    /opt/homebrew/share/codeg/web
    "$HOME/.local/share/codeg/web"
    "$HOME/Library/Application Support/codeg/web"
  )
  for d in "${candidates[@]}"; do
    [[ -f "$d/index.html" ]] && found+=("$d")
  done

  # unique, skip backups
  local -a uniq=()
  local x u skip
  for x in "${found[@]}"; do
    case "$x" in *backup*|*official*) continue ;; esac
    skip=0
    for u in "${uniq[@]+"${uniq[@]}"}"; do
      [[ "$u" == "$x" ]] && skip=1 && break
    done
    [[ $skip -eq 0 && -d "$x" && -f "$x/index.html" ]] && uniq+=("$x")
  done
  ((${#uniq[@]})) || return 1
  printf '%s\n' "${uniq[@]}"
}

backup_and_deploy_web() {
  local target="$1" tag="$2"
  [[ -d "$ROOT/web" ]] || die "package missing web/"
  mkdir -p "$target"
  local bak="${target}.official-backup"
  if [[ ! -e "$bak" && -f "$target/index.html" ]]; then
    log "backup original web → ${bak}"
    rm -rf "$bak"
    cp -a "$target" "$bak"
  fi
  log "deploy WebUI → ${target} (${tag})"
  if have rsync; then
    rsync -a --delete "$ROOT/web/" "$target/"
  else
    find "$target" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
    cp -a "$ROOT/web/." "$target/"
  fi
  local api="auto"
  case "$target" in
    *.app/Contents/Resources/*|*/codeg.app/*) api="http://127.0.0.1:${PORT}/summary" ;;
  esac
  cat > "$target/quota-config.json" <<EOF
{
  "enabled": true,
  "apiUrl": "${api}",
  "refreshMs": 300000
}
EOF
}

install_web_all() {
  local -a dirs=()
  local d n=0
  while IFS= read -r d; do
    [[ -n "$d" ]] && dirs+=("$d")
  done < <(discover_web_dirs || true)

  if ((${#dirs[@]} == 0)); then
    warn "WebUI dir not found — use --web-dir /path/to/web"
    return 1
  fi
  for d in "${dirs[@]}"; do
    backup_and_deploy_web "$d" "webui-$((++n))"
  done
  # restart codeg unit so it re-reads static if needed (usually not)
  if [[ "$TARGET_OS" == "linux" && -n "${CODEG_UNIT:-}" ]]; then
    systemctl try-restart "${CODEG_UNIT}.service" 2>/dev/null || true
  fi
}

discover_desktop_web() {
  local app res found
  local apps=("${DESKTOP_APP_OVERRIDE}" "/Applications/codeg.app" "$HOME/Applications/codeg.app")
  if [[ "$TARGET_OS" == "macos" && -d /Applications ]]; then
    while IFS= read -r app; do apps+=("$app"); done \
      < <(find /Applications -maxdepth 2 -name 'codeg*.app' -type d 2>/dev/null | head -5 || true)
  fi
  for app in "${apps[@]}"; do
    [[ -z "$app" || ! -d "$app" ]] && continue
    for res in "$app/Contents/Resources/web" "$app/Contents/Resources/resources/web"; do
      [[ -f "$res/index.html" ]] && { echo "${res}|${app}"; return 0; }
    done
    found="$(find "$app/Contents/Resources" -maxdepth 5 -type f -name index.html 2>/dev/null | head -1 || true)"
    [[ -n "$found" ]] && { echo "$(dirname "$found")|${app}"; return 0; }
  done
  return 1
}

install_web_desktop() {
  local pair web app
  pair="$(discover_desktop_web)" || { warn "no codeg.app — skip desktop"; return 1; }
  web="${pair%%|*}"; app="${pair##*|}"
  log "desktop app: $app"
  backup_and_deploy_web "$web" "desktop"
}

# ══════════════════════════════════════════════════════════════════════
# Phase 3 — same-origin access path
# ══════════════════════════════════════════════════════════════════════

# Inject location /codeg-quota/ into reverse-proxy configs.
install_rp_same_origin() {
  local backend_port="${CODEG_LISTEN_PORT:-3080}"
  local f real n=0
  local -a confs=()

  while IFS= read -r f; do
    [[ -n "$f" ]] && confs+=("$f")
  done < <(list_rp_configs_for_port "$backend_port" || true)

  # Also match configs that proxy to 3080 even if codeg currently elsewhere
  if ((${#confs[@]} == 0)); then
    while IFS= read -r f; do
      [[ -n "$f" ]] && confs+=("$f")
    done < <(list_rp_configs_for_port 3080 || true)
  fi

  ((${#confs[@]})) || return 1
  have python3 || { warn "python3 required to patch reverse-proxy config"; return 1; }

  for f in "${confs[@]}"; do
    real="$f"
    [[ -L "$f" ]] && real="$(readlink -f "$f" 2>/dev/null || echo "$f")"
    [[ -f "$real" ]] || continue

    # Caddyfile: different syntax — skip auto-patch, print hint
    if [[ "$(basename "$real")" == "Caddyfile" ]] || grep -qE '^\s*reverse_proxy\b' "$real" 2>/dev/null; then
      if ! grep -q 'codeg-quota' "$real" 2>/dev/null; then
        warn "Caddy detected ($real): add manually:"
        warn "  handle_path ${QUOTA_PREFIX}/* { reverse_proxy 127.0.0.1:${PORT} }"
      else
        log "Caddy already mentions codeg-quota ← $real"
        n=$((n+1))
      fi
      continue
    fi

    if grep -q "location ${QUOTA_PREFIX}/" "$real" 2>/dev/null || \
       grep -q "location ${QUOTA_PREFIX}" "$real" 2>/dev/null; then
      log "nginx already has ${QUOTA_PREFIX}/ ← $real"
      n=$((n+1))
      continue
    fi

    cp -a "$real" "${real}.bak-codeg-tools-$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
    if python3 - "$real" "$PORT" "$QUOTA_PREFIX" <<'PY'
import sys
from pathlib import Path
path, port, prefix = sys.argv[1], sys.argv[2], sys.argv[3]
t = Path(path).read_text()
if f"location {prefix}/" in t or f"location {prefix} " in t:
    raise SystemExit(0)
block = f"""
    # codeg-tools: same-origin quota API (auto-injected)
    location {prefix}/ {{
        proxy_pass http://127.0.0.1:{port}/;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_buffering off;
    }}

"""
# Prefer insert before API or root location inside server blocks
for needle in (
    "    location /api/ {",
    "    location /api {",
    "    location /ws/ {",
    "    location / {",
    "\tlocation /api/ {",
    "\tlocation / {",
):
    if needle in t:
        Path(path).write_text(t.replace(needle, block + needle, 1))
        raise SystemExit(0)
# last resort: before last closing brace of file
idx = t.rfind("\n}")
if idx > 0:
    Path(path).write_text(t[:idx] + "\n" + block + t[idx:])
    raise SystemExit(0)
raise SystemExit(1)
PY
    then
      if grep -q "location ${QUOTA_PREFIX}" "$real" 2>/dev/null; then
        n=$((n+1))
        log "nginx injected ${QUOTA_PREFIX}/ → :${PORT}  ($real)"
      fi
    else
      warn "could not patch $real"
    fi
  done

  ((n > 0)) || return 1

  if have nginx; then
    if nginx -t 2>/dev/null; then
      systemctl reload nginx 2>/dev/null || nginx -s reload 2>/dev/null || true
      log "nginx reloaded"
    else
      warn "nginx -t failed — restore *.bak-codeg-tools-* if needed"
      return 1
    fi
  fi

  # Reverse-proxy mode: do NOT steal :3080 with edge
  systemctl stop codeg-edge.service 2>/dev/null || true
  systemctl disable codeg-edge.service 2>/dev/null || true
  local d
  for d in /etc/systemd/system/codeg.service.d /etc/systemd/system/codeg-server.service.d; do
    if [[ -f "$d/codeg-tools-port.conf" ]]; then
      rm -f "$d/codeg-tools-port.conf"
      log "removed $d/codeg-tools-port.conf (keep codeg on public port for RP)"
    fi
  done
  systemctl daemon-reload 2>/dev/null || true
  ACCESS_MODE="nginx"
  return 0
}

# Edge proxy: only when no RP and we can move codeg off the public port.
install_edge_same_origin() {
  [[ "$TARGET_OS" == "linux" ]] || return 1
  is_root || { warn "edge needs root"; return 1; }
  need_node
  [[ -f "$PREFIX/edge-proxy.mjs" || -f "$ROOT/sidecar/edge-proxy.mjs" ]] || return 1
  cp -f "${ROOT}/sidecar/edge-proxy.mjs" "$PREFIX/edge-proxy.mjs"
  chmod 755 "$PREFIX/edge-proxy.mjs"

  local unit node_bin public_port backend_port
  node_bin="$(command -v node)"
  public_port="${CODEG_LISTEN_PORT:-$CODEG_PUBLIC_PORT}"
  backend_port="${CODEG_BACKEND_PORT}"
  unit="${CODEG_UNIT:-}"
  [[ -z "$unit" ]] && unit="$(find_codeg_unit || true)"

  if [[ -z "$unit" ]]; then
    warn "no codeg systemd unit — cannot safely free :${public_port} for edge"
    return 1
  fi

  # If something that is NOT edge already owns public port as codeg, move codeg
  log "edge mode: ${unit}.service → :${backend_port}, edge → :${public_port}"

  mkdir -p "/etc/systemd/system/${unit}.service.d"
  cat > "/etc/systemd/system/${unit}.service.d/codeg-tools-port.conf" <<EOF
[Service]
Environment=CODEG_PORT=${backend_port}
Environment=CODEG_HOST=0.0.0.0
EOF

  # Patch ALL env files (EnvironmentFile wins over drop-in on some setups)
  local envf
  for envf in /etc/codeg/codeg.env /etc/codeg/codeg-server.env \
              /usr/local/etc/codeg/codeg-server.env; do
    [[ -f "$envf" ]] || continue
    [[ -f "${envf}.before-codeg-tools" ]] || cp -a "$envf" "${envf}.before-codeg-tools" 2>/dev/null || true
    if grep -qE '^[[:space:]]*CODEG_PORT=' "$envf"; then
      sed -i -E "s|^[[:space:]]*CODEG_PORT=.*|CODEG_PORT=${backend_port}|" "$envf"
    else
      echo "CODEG_PORT=${backend_port}" >>"$envf"
    fi
    log "patched env $envf → PORT=${backend_port}"
  done

  cat > /etc/systemd/system/codeg-edge.service <<EOF
[Unit]
Description=Codeg same-origin edge proxy (codeg-tools)
After=network-online.target ${unit}.service codeg-quota.service
Wants=network-online.target

[Service]
Type=simple
Environment=CODEG_EDGE_HOST=0.0.0.0
Environment=CODEG_EDGE_PORT=${public_port}
Environment=CODEG_BACKEND_HOST=127.0.0.1
Environment=CODEG_BACKEND_PORT=${backend_port}
Environment=CODEG_QUOTA_HOST=127.0.0.1
Environment=CODEG_QUOTA_PORT=${PORT}
Environment=CODEG_QUOTA_PREFIX=${QUOTA_PREFIX}
ExecStart=${node_bin} ${PREFIX}/edge-proxy.mjs
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl stop codeg-edge.service 2>/dev/null || true
  systemctl restart "${unit}.service"
  sleep 1
  # verify codeg left public port
  if ss -tlnp 2>/dev/null | grep -E ":${public_port}\\b" | grep -qi codeg-server; then
    warn "codeg still on :${public_port} after restart — edge may fail (env override?)"
  fi
  systemctl enable --now codeg-edge.service
  systemctl restart codeg-edge.service
  sleep 0.5
  if ! curl -fsS --max-time 3 "http://127.0.0.1:${public_port}${QUOTA_PREFIX}/health" >/dev/null 2>&1; then
    warn "edge health failed on :${public_port}${QUOTA_PREFIX}/health"
    systemctl status codeg-edge --no-pager -l 2>/dev/null | head -20 || true
    return 1
  fi
  log "edge OK: :${public_port}${QUOTA_PREFIX}/* → sidecar :${PORT}"
  ACCESS_MODE="edge"
  CODEG_PUBLIC_PORT="$public_port"
  return 0
}

# Optional: open local firewall for direct mode
maybe_open_firewall() {
  [[ "$ACCESS_MODE" == "direct" ]] || return 0
  is_root || return 0
  if have ufw && ufw status 2>/dev/null | grep -qi 'Status: active'; then
    ufw allow "${PORT}/tcp" comment 'codeg-quota' 2>/dev/null || true
    log "ufw: allowed ${PORT}/tcp"
  fi
  if have firewall-cmd && firewall-cmd --state 2>/dev/null | grep -qi running; then
    firewall-cmd --permanent --add-port="${PORT}/tcp" 2>/dev/null || true
    firewall-cmd --reload 2>/dev/null || true
    log "firewalld: allowed ${PORT}/tcp"
  fi
}

setup_same_origin_access() {
  log "配置浏览器可达的额度入口（同域优先）…"
  if [[ "$TARGET_OS" == "macos" ]]; then
    ACCESS_MODE="direct"
    log "macOS strategy: http://127.0.0.1:${PORT}/summary"
    return 0
  fi

  case "$ACCESS_MODE" in
    nginx|caddy)
      if install_rp_same_origin; then
        log "strategy: reverse-proxy ${QUOTA_PREFIX}/ → 127.0.0.1:${PORT}"
        return 0
      fi
      warn "reverse-proxy inject failed — trying edge"
      install_edge_same_origin && return 0
      warn "falling back to direct :${PORT} (HTTPS pages may still fail mixed-content)"
      ACCESS_MODE="direct"
      maybe_open_firewall
      return 0
      ;;
    edge)
      if install_edge_same_origin; then
        return 0
      fi
      warn "edge failed — trying reverse-proxy inject"
      if install_rp_same_origin; then
        return 0
      fi
      ACCESS_MODE="direct"
      maybe_open_firewall
      return 0
      ;;
    *)
      # direct first; still try RP if any config appears
      if install_rp_same_origin; then
        return 0
      fi
      ACCESS_MODE="direct"
      maybe_open_firewall
      log "strategy: direct sidecar :${PORT} (open firewall / same machine)"
      return 0
      ;;
  esac
}

# ══════════════════════════════════════════════════════════════════════
# Phase 4 — health
# ══════════════════════════════════════════════════════════════════════

json_providers_ok() {
  local file="$1"
  python3 - "$file" <<'PY' 2>/dev/null
import json,sys
d=json.load(open(sys.argv[1]))
assert isinstance(d.get("providers"), list)
for p in d["providers"]:
    if p.get("status")=="disabled": continue
    print(f"  · {p.get('label')}: {p.get('status')}  plan={p.get('plan')}  display={p.get('display')}")
PY
}

health_check() {
  log "健康检查…"
  sleep 1
  local url="http://127.0.0.1:${PORT}/summary"
  if ! have curl; then
    warn "curl missing — skip health check"
    return 0
  fi

  if curl -fsS --max-time 35 -H "Accept: application/json" "${url}?refresh=1" \
       -o /tmp/codeg-quota-health.json 2>/dev/null \
     && python3 -c "import json;d=json.load(open('/tmp/codeg-quota-health.json')); assert isinstance(d.get('providers'),list)" 2>/dev/null; then
    log "sidecar OK ← ${url}"
    python3 - <<'PY' 2>/dev/null || true
import json
d=json.load(open("/tmp/codeg-quota-health.json"))
for p in d.get("providers",[]):
  if p.get("status")=="disabled": continue
  msg = p.get("message") or ""
  print(f"  · {p.get('label')}: {p.get('status')}  plan={p.get('plan')}  display={p.get('display')}  {msg}")
PY
  else
    warn "sidecar not ready: ${url}"
    if [[ "$TARGET_OS" == "macos" ]]; then
      warn "  logs: ${PREFIX}/logs/stderr.log"
      warn "  auth files must be under: ${REAL_HOME:-$HOME}"
      warn "  run as the login user:  codex login && grok login"
    else
      warn "  journalctl -u codeg-quota -n 30 --no-pager"
    fi
    return 0
  fi

  if [[ "$TARGET_OS" == "macos" ]]; then
    log "macOS: desktop/Web 使用 http://127.0.0.1:${PORT}/summary"
    return 0
  fi

  local c
  for c in \
    "http://127.0.0.1:${CODEG_PUBLIC_PORT}${QUOTA_PREFIX}/summary" \
    "http://127.0.0.1:3080${QUOTA_PREFIX}/summary"
  do
    if curl -fsS --max-time 5 -H "Accept: application/json" "$c" -o /tmp/codeg-quota-same.json 2>/dev/null \
       && python3 -c "import json;d=json.load(open('/tmp/codeg-quota-same.json')); assert isinstance(d.get('providers'),list)" 2>/dev/null; then
      log "same-origin OK ← $c"
      return 0
    fi
  done
  if [[ "$ACCESS_MODE" == "nginx" || "$ACCESS_MODE" == "caddy" ]]; then
    log "same-origin expected via public HTTPS reverse-proxy (${QUOTA_PREFIX}/summary)"
  elif [[ "$ACCESS_MODE" == "direct" ]]; then
    log "direct mode: use http://127.0.0.1:${PORT}/summary"
  else
    warn "same-origin path not verified on loopback"
  fi
}


main() {
  echo ""
  log "codeg-tools v${VERSION}"
  log "package: $ROOT"
  log "prefix:  $PREFIX"
  echo ""

  [[ -d "$ROOT/sidecar" ]] || die "package missing sidecar/"
  [[ "$DO_WEB" -eq 1 && ! -d "$ROOT/web" ]] && die "package missing web/"

  probe_environment

  if [[ "$DO_SIDECAR" -eq 1 ]]; then
    install_sidecar
  fi
  if [[ "$DO_WEB" -eq 1 ]]; then
    install_web_all || true
  fi
  if [[ "$TARGET_OS" == "macos" ]]; then
    if [[ "$DO_DESKTOP" -eq 1 ]]; then
      install_web_desktop || true
    elif discover_desktop_web >/dev/null 2>&1; then
      log "codeg.app found — injecting desktop web"
      install_web_desktop || true
    fi
  fi

  if [[ "$DO_SIDECAR" -eq 1 ]]; then
    setup_same_origin_access || true
    health_check
  fi

  echo ""
  log "done. Hard-refresh the browser (Ctrl+Shift+R / Cmd+Shift+R)."
  echo "  access mode : ${ACCESS_MODE}"
  echo "  sidecar     : ${BIND_HOST}:${PORT}"
  echo "  service user: ${REAL_USER}  home: ${REAL_HOME}"
  if [[ "$TARGET_OS" == "macos" ]]; then
    echo "  desktop API : http://127.0.0.1:${PORT}/summary"
    echo "  tip         : do not use sudo on macOS unless writing /Applications"
    echo "  tip         : as login user run:  codex login && grok login"
  else
    echo "  browser API : ${QUOTA_PREFIX}/summary  (same origin)"
    echo "  direct API  : http://127.0.0.1:${PORT}/summary"
  fi
  echo "  config      : ${PREFIX}/config.json"
  echo "  uninstall   : ${ROOT}/uninstall.sh"
  echo "  after official Codeg upgrade: re-run this installer"
  echo ""
}

main
