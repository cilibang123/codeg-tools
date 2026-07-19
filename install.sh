#!/usr/bin/env bash
# codeg-quota-addon — 傻瓜一键安装
#
# 默认：自动识别系统 + 自动找 WebUI 路径 + 装 sidecar + 挂前端
# 可选：--desktop 额外注入 macOS codeg.app
#
#   ./install.sh
#   ./install.sh --desktop
#   ./install.sh --menu          # 需要手动选时
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="1.3.1"

OS_MODE="auto"          # auto | linux | macos | menu
DO_SIDECAR=1
DO_WEB=1
DO_DESKTOP=0
WEB_DIR_OVERRIDE=""
DESKTOP_APP_OVERRIDE=""
BIND_HOST=""            # empty = auto (0.0.0.0 so LAN browsers can reach sidecar)
PORT="3091"
QUIET=0

log()  { printf '==> %s\n' "$*"; }
warn() { printf '!!  %s\n' "$*" >&2; }
die()  { printf 'xx  %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<'EOF'
codeg-quota-addon 傻瓜安装

  ./install.sh                 全自动（推荐）
  ./install.sh --desktop       macOS 额外注入桌面 App
  ./install.sh --menu          交互菜单
  ./install.sh --web-dir PATH  指定 WebUI 目录
  ./install.sh --app PATH      指定 codeg.app
  ./install.sh --sidecar-only
  ./install.sh --web-only
  ./install.sh --os linux|macos|auto
  ./install.sh --bind 0.0.0.0 --port 3091
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
    -q|--quiet) QUIET=1; shift ;;
    -y|--yes) shift ;; # 兼容旧参数，默认已全自动
    *) die "未知参数: $1（试 --help）" ;;
  esac
done

detect_os() {
  case "$(uname -s 2>/dev/null || echo unknown)" in
    Linux*)  echo linux ;;
    Darwin*) echo macos ;;
    *)       echo unknown ;;
  esac
}

resolve_os() {
  local detected
  detected="$(detect_os)"
  case "$OS_MODE" in
    auto)
      [[ "$detected" != "unknown" ]] || die "无法识别系统: $(uname -s 2>/dev/null || true)"
      echo "$detected"
      ;;
    linux|macos) echo "$OS_MODE" ;;
    menu)
      echo ""
      echo "  codeg-quota-addon v${VERSION}  （检测到: ${detected}）"
      echo "  1) Linux WebUI"
      echo "  2) macOS WebUI"
      echo "  3) macOS WebUI + 桌面 App"
      echo "  4) 自动"
      read -r -p "  选择 [4]: " c || true
      c="${c:-4}"
      case "$c" in
        1) echo linux ;;
        2) echo macos ;;
        3) DO_DESKTOP=1; echo macos ;;
        *) [[ "$detected" != "unknown" ]] || die "无法自动识别"; echo "$detected" ;;
      esac
      ;;
    *) die "--os 无效: $OS_MODE" ;;
  esac
}

TARGET_OS="$(resolve_os)"
log "系统: ${TARGET_OS}"
[[ "$DO_DESKTOP" -eq 1 && "$TARGET_OS" != "macos" ]] && DO_DESKTOP=0

# Install prefix
if [[ "$TARGET_OS" == "linux" ]]; then
  if [[ "$(id -u)" -eq 0 ]]; then
    PREFIX="${PREFIX:-/opt/codeg-quota}"
  else
    PREFIX="${PREFIX:-$HOME/.local/share/codeg-quota}"
  fi
else
  PREFIX="${PREFIX:-$HOME/Library/Application Support/codeg-quota}"
fi

# Auto bind host: default 0.0.0.0 so remote browsers on LAN can hit :3091
# Use --bind 127.0.0.1 if you only ever open WebUI on the same machine.
auto_bind_host() {
  if [[ -n "$BIND_HOST" ]]; then
    echo "$BIND_HOST"
    return
  fi
  echo "0.0.0.0"
}

BIND_HOST="$(auto_bind_host)"

# ── discover WebUI paths ──────────────────────────────────────────────
discover_web_dirs() {
  local -a found=()
  local d line val

  # 1) explicit
  if [[ -n "$WEB_DIR_OVERRIDE" ]]; then
    [[ -d "$WEB_DIR_OVERRIDE" ]] || die "--web-dir 不存在: $WEB_DIR_OVERRIDE"
    echo "$WEB_DIR_OVERRIDE"
    return
  fi

  # 2) env
  if [[ -n "${CODEG_STATIC_DIR:-}" && -d "${CODEG_STATIC_DIR}" ]]; then
    found+=("${CODEG_STATIC_DIR}")
  fi

  # 3) process cmdline / env of running codeg-server
  if have pgrep; then
    local pid
    while read -r pid; do
      [[ -z "$pid" ]] && continue
      # Linux /proc env
      if [[ -r "/proc/$pid/environ" ]]; then
        val="$(tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null | grep -E '^CODEG_STATIC_DIR=' | head -1 | cut -d= -f2- || true)"
        if [[ -n "$val" && -d "$val" ]]; then
          found+=("$val")
        fi
      fi
      # macOS: try lsof on cwd of process
    done < <(pgrep -f 'codeg-server' 2>/dev/null || true)
  fi

  # 4) systemd env file
  for f in /etc/codeg/codeg-server.env /usr/local/etc/codeg/codeg-server.env \
           "$HOME/.config/codeg/codeg-server.env"; do
    [[ -f "$f" ]] || continue
    line="$(grep -E '^[[:space:]]*CODEG_STATIC_DIR=' "$f" 2>/dev/null | tail -1 || true)"
    val="${line#*CODEG_STATIC_DIR=}"
    val="${val//\"/}"
    val="${val//\'/}"
    val="$(echo "$val" | xargs 2>/dev/null || echo "$val")"
    if [[ -n "$val" && -d "$val" ]]; then
      found+=("$val")
    fi
  done

  # 5) well-known paths
  local candidates=(
    /usr/local/share/codeg/web
    /usr/share/codeg/web
    /opt/codeg/web
    /opt/homebrew/share/codeg/web
    /usr/local/opt/codeg/share/web
    "$HOME/.local/share/codeg/web"
    "$HOME/Library/Application Support/codeg/web"
  )
  for d in "${candidates[@]}"; do
    if [[ -f "$d/index.html" ]]; then
      found+=("$d")
    fi
  done

  # 6) find under /usr/local /opt (limited depth)
  if have find; then
    while IFS= read -r d; do
      [[ -n "$d" ]] && found+=("$d")
    done < <(find /usr/local/share /usr/share /opt /opt/homebrew/share \
      "$HOME/.local/share" "$HOME/Library/Application Support" \
      -maxdepth 4 -type f -name index.html -path '*/codeg/*' 2>/dev/null \
      | sed 's#/index.html$##' | head -20 || true)
  fi

  # unique preserve order
  local -a uniq=()
  local x u skip
  for x in "${found[@]}"; do
    skip=0
    for u in "${uniq[@]+"${uniq[@]}"}"; do
      [[ "$u" == "$x" ]] && skip=1 && break
    done
    [[ $skip -eq 0 && -d "$x" ]] && uniq+=("$x")
  done

  if ((${#uniq[@]} == 0)); then
    return 1
  fi
  # print all for multi-deploy
  printf '%s\n' "${uniq[@]}"
}

discover_desktop_web() {
  local app res found
  local apps=(
    "${DESKTOP_APP_OVERRIDE}"
    "/Applications/codeg.app"
    "$HOME/Applications/codeg.app"
  )
  # also scan /Applications for *codeg*
  if [[ "$TARGET_OS" == "macos" && -d /Applications ]]; then
    while IFS= read -r app; do
      apps+=("$app")
    done < <(find /Applications -maxdepth 2 -name 'codeg*.app' -type d 2>/dev/null | head -5 || true)
  fi

  for app in "${apps[@]}"; do
    [[ -z "$app" || ! -d "$app" ]] && continue
    for res in \
      "$app/Contents/Resources/web" \
      "$app/Contents/Resources/resources/web"
    do
      if [[ -f "$res/index.html" ]]; then
        echo "${res}|${app}"
        return 0
      fi
    done
    found="$(find "$app/Contents/Resources" -maxdepth 5 -type f -name index.html 2>/dev/null | head -1 || true)"
    if [[ -n "$found" ]]; then
      echo "$(dirname "$found")|${app}"
      return 0
    fi
  done
  return 1
}

need_node() {
  if have node; then
    log "Node: $(node -v)"
    return
  fi
  die "未找到 node。请先安装 Node.js，再重跑本脚本。"
}

# ── sidecar ───────────────────────────────────────────────────────────
install_sidecar() {
  need_node
  log "安装 sidecar → ${PREFIX}"
  mkdir -p "$PREFIX"
  cp -f "$ROOT/sidecar/server.mjs" "$PREFIX/server.mjs"
  if [[ ! -f "$PREFIX/config.json" ]]; then
    cp -f "$ROOT/sidecar/config.example.json" "$PREFIX/config.json"
  fi
  if have python3; then
    python3 - "$PREFIX/config.json" "$BIND_HOST" "$PORT" <<'PY'
import json, sys
path, host, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
cfg = json.load(open(path))
cfg["host"] = host
cfg["port"] = port
json.dump(cfg, open(path, "w"), indent=2, ensure_ascii=False)
open(path, "a").write("\n")
PY
  fi
  chmod 755 "$PREFIX/server.mjs"

  if [[ "$TARGET_OS" == "linux" ]]; then
    install_systemd
  else
    install_launchd
  fi
}

install_systemd() {
  local unit="/etc/systemd/system/codeg-quota.service"
  local node_bin
  node_bin="$(command -v node)"
  if [[ "$(id -u)" -ne 0 ]]; then
    # user unit
    local udir="$HOME/.config/systemd/user"
    mkdir -p "$udir"
    unit="$udir/codeg-quota.service"
    cat > "$unit" <<EOF
[Unit]
Description=Codeg account quota sidecar
After=network-online.target

[Service]
Type=simple
WorkingDirectory=${PREFIX}
ExecStart=${node_bin} ${PREFIX}/server.mjs --config ${PREFIX}/config.json
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
EOF
    systemctl --user daemon-reload 2>/dev/null || true
    systemctl --user enable --now codeg-quota.service 2>/dev/null || {
      warn "user systemd 不可用，后台启动 sidecar…"
      nohup "${node_bin}" "${PREFIX}/server.mjs" --config "${PREFIX}/config.json" \
        >"${PREFIX}/sidecar.log" 2>&1 &
      echo $! >"${PREFIX}/sidecar.pid"
    }
    log "sidecar 已启动（user）"
    return
  fi
  cat > "$unit" <<EOF
[Unit]
Description=Codeg account quota sidecar (codeg-quota-addon)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${PREFIX}
ExecStart=${node_bin} ${PREFIX}/server.mjs --config ${PREFIX}/config.json
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now codeg-quota.service
  log "systemd: codeg-quota.service 已启用"
}

install_launchd() {
  local label="com.codeg.quota"
  local plist="$HOME/Library/LaunchAgents/${label}.plist"
  local node_bin logs
  node_bin="$(command -v node)"
  logs="$PREFIX/logs"
  mkdir -p "$HOME/Library/LaunchAgents" "$logs"
  cat > "$plist" <<EOF
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
</dict>
</plist>
EOF
  launchctl bootout "gui/$(id -u)/${label}" 2>/dev/null || true
  launchctl unload "$plist" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$plist" 2>/dev/null || launchctl load -w "$plist"
  log "launchd: ${label} 已加载"
}

# ── web deploy ────────────────────────────────────────────────────────
backup_and_deploy_web() {
  local target="$1"
  local tag="$2"
  [[ -d "$ROOT/web" ]] || die "安装包损坏：缺少 web/"
  mkdir -p "$target"
  local bak="${target}.official-backup"
  if [[ ! -e "$bak" ]] && [[ -f "$target/index.html" ]]; then
    log "备份原版 → ${bak}"
    rm -rf "$bak"
    cp -a "$target" "$bak"
  fi
  log "部署额度 WebUI → ${target} (${tag})"
  if have rsync; then
    rsync -a --delete "$ROOT/web/" "$target/"
  else
    find "$target" -mindepth 1 -maxdepth 1 ! -name '.official-backup' -exec rm -rf {} + 2>/dev/null || true
    cp -a "$ROOT/web/." "$target/"
  fi
  # apiUrl=auto → 浏览器按当前页面主机名访问 :PORT（远程 WebUI 不会误打 127.0.0.1）
  # 桌面 App / 本机浏览器同样适用（hostname 多为 127.0.0.1 或 localhost）
  cat > "$target/quota-config.json" <<EOF
{
  "enabled": true,
  "apiUrl": "auto",
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
    warn "未自动找到 Codeg WebUI 目录。"
    warn "可指定: $0 --web-dir /path/to/web"
    return 1
  fi

  for d in "${dirs[@]}"; do
    backup_and_deploy_web "$d" "webui-$((++n))"
  done

  if [[ "$TARGET_OS" == "linux" ]] && have systemctl; then
    systemctl try-restart codeg-server.service 2>/dev/null || true
  fi
}

install_web_desktop() {
  local pair web app
  if ! pair="$(discover_desktop_web)"; then
    warn "未找到 macOS codeg.app，跳过桌面注入（WebUI 已处理则仍可用浏览器）"
    return 1
  fi
  web="${pair%%|*}"
  app="${pair##*|}"
  log "桌面 App: $app"
  backup_and_deploy_web "$web" "desktop"
  warn "已改 App 资源；若系统提示损坏/无法打开，请在「隐私与安全性」中允许"
}

health_check() {
  log "健康检查…"
  sleep 0.8
  local url="http://127.0.0.1:${PORT}/summary"
  if have curl; then
    if curl -fsS --max-time 35 "${url}?refresh=1" -o /tmp/codeg-quota-health.json 2>/dev/null; then
      log "sidecar OK ← ${url}"
      if have python3; then
        python3 - <<'PY'
import json
d=json.load(open("/tmp/codeg-quota-health.json"))
for p in d.get("providers",[]):
  if p.get("status")=="disabled": continue
  print(f"  · {p.get('label')}: {p.get('status')}  plan={p.get('plan')}  used={p.get('used')}  reset={p.get('resets_at')}")
PY
      fi
    else
      warn "sidecar 暂未响应 ${url}（稍后执行: curl '${url}'）"
    fi
  fi
}

main() {
  echo ""
  log "codeg-quota-addon v${VERSION} 傻瓜安装"
  log "包: $ROOT"
  log "前缀: $PREFIX | bind ${BIND_HOST}:${PORT}"
  echo ""

  [[ -d "$ROOT/sidecar" ]] || die "安装包损坏：缺少 sidecar/"
  [[ "$DO_WEB" -eq 1 && ! -d "$ROOT/web" ]] && die "安装包损坏：缺少 web/"

  if [[ "$DO_SIDECAR" -eq 1 ]]; then
    install_sidecar
  fi
  if [[ "$DO_WEB" -eq 1 ]]; then
    install_web_all || true
  fi
  # macOS: auto try desktop if --desktop OR app exists and user on macos
  if [[ "$TARGET_OS" == "macos" ]]; then
    if [[ "$DO_DESKTOP" -eq 1 ]]; then
      install_web_desktop || true
    elif discover_desktop_web >/dev/null 2>&1; then
      log "检测到 codeg.app，自动注入桌面 Web 资源"
      install_web_desktop || true
    fi
  fi
  if [[ "$DO_SIDECAR" -eq 1 ]]; then
    health_check
  fi

  echo ""
  log "完成。请硬刷新浏览器（Ctrl+Shift+R / Cmd+Shift+R）"
  echo "  配置: ${PREFIX}/config.json"
  echo "  卸载: ${ROOT}/uninstall.sh"
  echo "  官方更新 Codeg 后：再执行一次 ./install.sh 即可"
  echo ""
}

main
