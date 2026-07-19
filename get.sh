#!/usr/bin/env bash
# codeg-tools 一键安装入口
#
# Linux:
#   curl -fsSL https://raw.githubusercontent.com/cilibang123/codeg-tools/main/get.sh | sudo bash
# macOS（推荐不要 sudo；装桌面 App 资源需要写 /Applications 时再用 sudo）:
#   curl -fsSL https://raw.githubusercontent.com/cilibang123/codeg-tools/main/get.sh | bash
#   curl -fsSL ... | bash -s -- --desktop
#
set -euo pipefail

REPO="${CODEG_TOOLS_REPO:-cilibang123/codeg-tools}"
BRANCH="${CODEG_TOOLS_BRANCH:-main}"
TARBALL_URL="${CODEG_TOOLS_TARBALL:-https://codeload.github.com/${REPO}/tar.gz/refs/heads/${BRANCH}}"

log()  { printf '==> %s\n' "$*"; }
warn() { printf '!!  %s\n' "$*" >&2; }
die()  { printf 'xx  %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

have curl || have wget || die "需要 curl 或 wget"
have tar || die "需要 tar"

TMP="$(mktemp -d 2>/dev/null || mktemp -d -t codeg-tools)"
cleanup() { rm -rf "$TMP" 2>/dev/null || true; }
trap cleanup EXIT

log "下载 ${REPO}@${BRANCH} …"
ARCHIVE="$TMP/codeg-tools.tar.gz"
if have curl; then
  curl -fsSL "$TARBALL_URL" -o "$ARCHIVE" || die "下载失败: $TARBALL_URL"
else
  wget -qO "$ARCHIVE" "$TARBALL_URL" || die "下载失败: $TARBALL_URL"
fi

log "解压…"
tar -xzf "$ARCHIVE" -C "$TMP"
SRC="$(find "$TMP" -mindepth 1 -maxdepth 1 -type d -name 'codeg-tools-*' | head -1)"
[[ -n "${SRC:-}" && -f "$SRC/install.sh" ]] || die "压缩包里找不到 install.sh"
chmod +x "$SRC/install.sh" "$SRC/uninstall.sh" 2>/dev/null || true

# Preserve real user when invoked via sudo (macOS LaunchAgent + auth dirs)
if [[ "$(id -u)" -eq 0 && -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
  export CODEG_TOOLS_REAL_USER="$SUDO_USER"
  export CODEG_TOOLS_REAL_HOME="$(eval echo "~${SUDO_USER}")"
  log "以 root 安装，但服务将归属用户: ${CODEG_TOOLS_REAL_USER} (${CODEG_TOOLS_REAL_HOME})"
fi

log "开始安装…"
exec bash "$SRC/install.sh" "$@"
