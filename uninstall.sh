#!/usr/bin/env bash
# 卸载 codeg-quota-addon（可还原 WebUI 备份）
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OS_MODE="${1:-auto}"
RESTORE_WEB=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --os) OS_MODE="$2"; shift 2 ;;
    --os=*) OS_MODE="${1#*=}"; shift ;;
    --keep-web) RESTORE_WEB=0; shift ;;
    --web-dir) WEB_DIR="$2"; shift 2 ;;
    *) shift ;;
  esac
done

log() { printf '==> %s\n' "$*"; }
warn() { printf '!!  %s\n' "$*" >&2; }

detect_os() {
  case "$(uname -s)" in
    Linux*) echo linux ;;
    Darwin*) echo macos ;;
    *) echo linux ;;
  esac
}

[[ "$OS_MODE" == "auto" || "$OS_MODE" == "ask" ]] && OS_MODE="$(detect_os)"

if [[ "$OS_MODE" == "linux" ]]; then
  PREFIX="${PREFIX:-/opt/codeg-quota}"
  [[ "$(id -u)" -ne 0 ]] && PREFIX="${PREFIX:-$HOME/.local/share/codeg-quota}"
  if command -v systemctl >/dev/null 2>&1 && [[ "$(id -u)" -eq 0 ]]; then
    systemctl disable --now codeg-quota.service 2>/dev/null || true
    rm -f /etc/systemd/system/codeg-quota.service
    systemctl daemon-reload 2>/dev/null || true
    log "已停止 systemd codeg-quota"
  fi
else
  PREFIX="${PREFIX:-$HOME/Library/Application Support/codeg-quota}"
  label=com.codeg.quota
  plist="$HOME/Library/LaunchAgents/${label}.plist"
  launchctl bootout "gui/$(id -u)/${label}" 2>/dev/null || true
  launchctl unload "$plist" 2>/dev/null || true
  rm -f "$plist"
  log "已卸载 launchd ${label}"
fi

restore_one() {
  local target="$1"
  local bak="${target}.official-backup"
  if [[ -d "$bak" ]]; then
    log "还原 WebUI: $target ← $bak"
    rm -rf "$target"
    mv "$bak" "$target"
  else
    warn "无备份，跳过还原: $bak"
  fi
}

if [[ "$RESTORE_WEB" -eq 1 ]]; then
  if [[ -n "${WEB_DIR:-}" ]]; then
    restore_one "$WEB_DIR"
  else
    for d in \
      "${CODEG_STATIC_DIR:-}" \
      /usr/local/share/codeg/web \
      /usr/share/codeg/web \
      "$HOME/.local/share/codeg/web" \
      /opt/homebrew/share/codeg/web
    do
      [[ -z "$d" ]] && continue
      [[ -d "${d}.official-backup" ]] && restore_one "$d"
    done
    # desktop app backups
    for app in /Applications/codeg.app "$HOME/Applications/codeg.app"; do
      [[ -d "$app" ]] || continue
      while IFS= read -r -d '' bak; do
        target="${bak%.official-backup}"
        restore_one "$target"
      done < <(find "$app/Contents/Resources" -type d -name '*.official-backup' -print0 2>/dev/null || true)
    done
  fi
fi

if [[ -d "$PREFIX" ]]; then
  log "移除 $PREFIX"
  rm -rf "$PREFIX"
fi

log "卸载完成"
