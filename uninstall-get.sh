#!/usr/bin/env bash
# codeg-tools 一键卸载入口
#
# Linux:
#   curl -fsSL https://raw.githubusercontent.com/cilibang123/codeg-tools/main/uninstall-get.sh | sudo bash
# macOS:
#   curl -fsSL https://raw.githubusercontent.com/cilibang123/codeg-tools/main/uninstall-get.sh | bash
# 只停服务不还原前端:
#   curl -fsSL ... | bash -s -- --keep-web
#
set -euo pipefail

REPO="${CODEG_TOOLS_REPO:-cilibang123/codeg-tools}"
BRANCH="${CODEG_TOOLS_BRANCH:-main}"
TARBALL_URL="${CODEG_TOOLS_TARBALL:-https://codeload.github.com/${REPO}/tar.gz/refs/heads/${BRANCH}}"

log()  { printf '==> %s\n' "$*"; }
die()  { printf 'xx  %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

have curl || have wget || die "需要 curl 或 wget"
have tar || die "需要 tar"

TMP="$(mktemp -d 2>/dev/null || mktemp -d -t codeg-tools-un)"
cleanup() { rm -rf "$TMP" 2>/dev/null || true; }
trap cleanup EXIT

log "下载 ${REPO}@${BRANCH} …"
ARCHIVE="$TMP/codeg-tools.tar.gz"
if have curl; then
  curl -fsSL "$TARBALL_URL" -o "$ARCHIVE" || die "下载失败"
else
  wget -qO "$ARCHIVE" "$TARBALL_URL" || die "下载失败"
fi

log "解压…"
tar -xzf "$ARCHIVE" -C "$TMP"
SRC="$(find "$TMP" -mindepth 1 -maxdepth 1 -type d -name 'codeg-tools-*' | head -1)"
[[ -n "${SRC:-}" && -f "$SRC/uninstall.sh" ]] || die "压缩包里找不到 uninstall.sh"
chmod +x "$SRC/uninstall.sh" 2>/dev/null || true

if [[ "$(id -u)" -eq 0 && -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
  export CODEG_TOOLS_REAL_USER="$SUDO_USER"
  export CODEG_TOOLS_REAL_HOME="$(eval echo "~${SUDO_USER}")"
  log "服务归属用户: ${CODEG_TOOLS_REAL_USER}"
fi

log "开始卸载…"
exec bash "$SRC/uninstall.sh" "$@"
