#!/usr/bin/env bash
# codeg-tools — smart uninstaller (macOS + Linux)
#
#   ./uninstall.sh
#   ./uninstall.sh --keep-web          # stop services only, leave WebUI
#   ./uninstall.sh --web-dir PATH
#
# One-liner:
#   curl -fsSL https://raw.githubusercontent.com/cilibang123/codeg-tools/main/uninstall-get.sh | bash
#   curl -fsSL ... | sudo bash          # Linux server (systemd/nginx)
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="1.5.2"

OS_MODE="auto"
RESTORE_WEB=1
WEB_DIR_OVERRIDE=""
STRIP_NGINX=1
STRIP_EDGE=1

log()  { printf '==> %s\n' "$*"; }
warn() { printf '!!  %s\n' "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }
is_root() { [[ "$(id -u)" -eq 0 ]]; }

usage() {
  cat <<EOF
codeg-tools uninstaller v${VERSION}

  ./uninstall.sh                 full uninstall + restore web backups
  ./uninstall.sh --keep-web      stop services, keep patched WebUI
  ./uninstall.sh --web-dir PATH  restore only this web dir
  ./uninstall.sh --os linux|macos|auto

One-liner:
  curl -fsSL https://raw.githubusercontent.com/cilibang123/codeg-tools/main/uninstall-get.sh | bash
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage ;;
    --os) OS_MODE="${2:-}"; shift 2 ;;
    --os=*) OS_MODE="${1#*=}"; shift ;;
    --keep-web) RESTORE_WEB=0; shift ;;
    --web-dir) WEB_DIR_OVERRIDE="${2:-}"; shift 2 ;;
    --web-dir=*) WEB_DIR_OVERRIDE="${1#*=}"; shift ;;
    --no-nginx) STRIP_NGINX=0; shift ;;
    --no-edge) STRIP_EDGE=0; shift ;;
    -y|--yes) shift ;;
    *) shift ;;
  esac
done

detect_os() {
  case "$(uname -s 2>/dev/null || echo unknown)" in
    Linux*)  echo linux ;;
    Darwin*) echo macos ;;
    *)       echo linux ;;
  esac
}

[[ "$OS_MODE" == "auto" || "$OS_MODE" == "ask" ]] && OS_MODE="$(detect_os)"
TARGET_OS="$OS_MODE"

# Real user when sudo (macOS LaunchAgents live under the login user)
REAL_USER="${CODEG_TOOLS_REAL_USER:-${SUDO_USER:-${USER:-$(id -un)}}}"
if is_root && [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
  REAL_USER="$SUDO_USER"
fi
if [[ -n "${CODEG_TOOLS_REAL_HOME:-}" ]]; then
  REAL_HOME="$CODEG_TOOLS_REAL_HOME"
elif is_root && [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
  REAL_HOME="$(eval echo "~${SUDO_USER}")"
else
  REAL_HOME="${HOME}"
fi

if [[ "$TARGET_OS" == "linux" ]]; then
  if is_root; then PREFIX="${PREFIX:-/opt/codeg-quota}"
  else PREFIX="${PREFIX:-$HOME/.local/share/codeg-quota}"; fi
else
  PREFIX="${PREFIX:-$REAL_HOME/Library/Application Support/codeg-quota}"
fi

log "codeg-tools uninstall v${VERSION}"
log "OS: ${TARGET_OS}  user: ${REAL_USER}  home: ${REAL_HOME}"

# ── stop services ─────────────────────────────────────────────────────
stop_linux() {
  if have systemctl; then
    if is_root; then
      systemctl disable --now codeg-quota.service 2>/dev/null || true
      systemctl disable --now codeg-edge.service 2>/dev/null || true
      rm -f /etc/systemd/system/codeg-quota.service
      rm -f /etc/systemd/system/codeg-edge.service
      rm -rf /etc/systemd/system/codeg-quota.service.d
      # remove port drop-ins we may have added
      if [[ "$STRIP_EDGE" -eq 1 ]]; then
        for d in /etc/systemd/system/codeg.service.d /etc/systemd/system/codeg-server.service.d; do
          if [[ -f "$d/codeg-tools-port.conf" ]]; then
            rm -f "$d/codeg-tools-port.conf"
            log "removed $d/codeg-tools-port.conf"
            # restart unit so original port returns
            local unit
            unit="$(basename "$(dirname "$d")" .d)"
            systemctl try-restart "${unit}" 2>/dev/null || true
          fi
          # clean empty drop-in dir
          rmdir "$d" 2>/dev/null || true
        done
      fi
      systemctl daemon-reload 2>/dev/null || true
      log "stopped systemd codeg-quota / codeg-edge"
    else
      systemctl --user disable --now codeg-quota.service 2>/dev/null || true
      rm -f "$HOME/.config/systemd/user/codeg-quota.service"
      systemctl --user daemon-reload 2>/dev/null || true
      log "stopped user systemd codeg-quota"
    fi
  fi
  # nohup leftover
  if [[ -f "${PREFIX}/sidecar.pid" ]]; then
    kill "$(cat "${PREFIX}/sidecar.pid")" 2>/dev/null || true
    rm -f "${PREFIX}/sidecar.pid"
  fi
}

stop_macos() {
  local label="com.codeg.quota"
  local uid plist
  uid="$(id -u "$REAL_USER" 2>/dev/null || id -u)"
  plist="${REAL_HOME}/Library/LaunchAgents/${label}.plist"

  # user agent
  if [[ -n "$uid" ]]; then
    if is_root && [[ "$REAL_USER" != "root" ]]; then
      sudo -u "$REAL_USER" launchctl bootout "gui/${uid}/${label}" 2>/dev/null || true
      sudo -u "$REAL_USER" launchctl unload "$plist" 2>/dev/null || true
    else
      launchctl bootout "gui/${uid}/${label}" 2>/dev/null || true
      launchctl unload "$plist" 2>/dev/null || true
    fi
  fi
  rm -f "$plist"

  # root mistakes from older installs
  if is_root; then
    launchctl bootout "system/${label}" 2>/dev/null || true
    rm -f "/Library/LaunchAgents/${label}.plist" "/Library/LaunchDaemons/${label}.plist"
  fi
  log "removed launchd ${label} (user ${REAL_USER})"
}

if [[ "$TARGET_OS" == "linux" ]]; then
  stop_linux
else
  stop_macos
fi

# ── nginx: remove injected location blocks ────────────────────────────
strip_nginx_injections() {
  [[ "$STRIP_NGINX" -eq 1 ]] || return 0
  [[ "$TARGET_OS" == "linux" ]] || return 0
  is_root || return 0
  have nginx || return 0
  have python3 || return 0

  local f real n=0
  for f in /etc/nginx/sites-enabled/* /etc/nginx/conf.d/*.conf \
           /etc/nginx/sites-available/*; do
    [[ -e "$f" || -L "$f" ]] || continue
    real="$f"
    [[ -L "$f" ]] && real="$(readlink -f "$f" 2>/dev/null || echo "$f")"
    [[ -f "$real" ]] || continue
    grep -q 'codeg-tools' "$real" 2>/dev/null || \
      grep -q 'location /codeg-quota/' "$real" 2>/dev/null || continue

    python3 - "$real" <<'PY' || true
import re, sys
from pathlib import Path
path = Path(sys.argv[1])
t = path.read_text()
# remove auto-injected block (comment marker or bare location /codeg-quota/)
pat = re.compile(
    r"\n[ \t]*# codeg-tools[^\n]*\n[ \t]*location /codeg-quota/[^\n]*\{.*?\n[ \t]*\}\n",
    re.S,
)
t2, n = pat.subn("\n", t)
if n == 0:
    pat2 = re.compile(
        r"\n[ \t]*location /codeg-quota/[^\n]*\{.*?\n[ \t]*\}\n",
        re.S,
    )
    t2, n = pat2.subn("\n", t)
if n:
    path.write_text(t2)
    print(f"stripped {n} block(s) from {path}")
PY
    n=$((n+1))
  done

  if ((n > 0)); then
    if nginx -t 2>/dev/null; then
      systemctl reload nginx 2>/dev/null || nginx -s reload 2>/dev/null || true
      log "nginx: removed /codeg-quota/ injections and reloaded"
    else
      warn "nginx -t failed after strip — check configs / restore *.bak-codeg-tools-*"
    fi
  fi
}

strip_nginx_injections

# ── restore env files we may have rewritten ───────────────────────────
restore_env_backups() {
  local f
  for f in /etc/codeg/codeg.env /etc/codeg/codeg-server.env \
           /usr/local/etc/codeg/codeg-server.env; do
    if [[ -f "${f}.before-codeg-tools" ]]; then
      log "restore env $f ← ${f}.before-codeg-tools"
      cp -a "${f}.before-codeg-tools" "$f"
    fi
  done
}
if is_root; then restore_env_backups; fi

# ── restore WebUI backups ─────────────────────────────────────────────
restore_one() {
  local target="$1"
  local bak="${target}.official-backup"
  if [[ -d "$bak" ]]; then
    log "restore WebUI: $target ← $bak"
    rm -rf "$target"
    mv "$bak" "$target"
  else
    warn "no backup for $target (skip)"
  fi
}

if [[ "$RESTORE_WEB" -eq 1 ]]; then
  if [[ -n "$WEB_DIR_OVERRIDE" ]]; then
    restore_one "$WEB_DIR_OVERRIDE"
  else
    for d in \
      "${CODEG_STATIC_DIR:-}" \
      /usr/local/share/codeg/web \
      /usr/share/codeg/web \
      /opt/codeg/web \
      "$REAL_HOME/.local/share/codeg/web" \
      /opt/homebrew/share/codeg/web
    do
      [[ -z "$d" ]] && continue
      [[ -d "${d}.official-backup" ]] && restore_one "$d"
    done
    # desktop app (macOS)
    for app in /Applications/codeg.app "$REAL_HOME/Applications/codeg.app"; do
      [[ -d "$app" ]] || continue
      while IFS= read -r bak; do
        [[ -z "$bak" ]] && continue
        target="${bak%.official-backup}"
        restore_one "$target"
      done < <(find "$app/Contents/Resources" -type d -name 'web.official-backup' 2>/dev/null || true)
    done
  fi
else
  log "keeping WebUI (--keep-web)"
fi

# ── remove install prefix ─────────────────────────────────────────────
PREFIXES=("$PREFIX")
if [[ "$TARGET_OS" == "macos" ]]; then
  PREFIXES+=("$REAL_HOME/Library/Application Support/codeg-quota")
  PREFIXES+=("/opt/codeg-quota")
fi
if [[ "$TARGET_OS" == "linux" ]]; then
  PREFIXES+=("$REAL_HOME/.local/share/codeg-quota" "/opt/codeg-quota")
fi

for p in "${PREFIXES[@]}"; do
  [[ -d "$p" ]] || continue
  log "remove $p"
  rm -rf "$p"
done

log "uninstall complete"
echo "  Restart Codeg / hard-refresh the browser if the UI still shows old chips."
