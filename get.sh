#!/usr/bin/env bash
# codeg-tools 一键安装入口
#
# 用法（复制整行即可）：
#   curl -fsSL https://raw.githubusercontent.com/cilibang123/codeg-tools/main/get.sh | bash
#
# 带参数：
#   curl -fsSL https://raw.githubusercontent.com/cilibang123/codeg-tools/main/get.sh | bash -s -- --desktop
#   curl -fsSL https://raw.githubusercontent.com/cilibang123/codeg-tools/main/get.sh | sudo bash
#
set -euo pipefail

REPO="${CODEG_TOOLS_REPO:-cilibang123/codeg-tools}"
BRANCH="${CODEG_TOOLS_BRANCH:-main}"
# codeload 直链，比 github.com 跳转更稳
TARBALL_URL="${CODEG_TOOLS_TARBALL:-https://codeload.github.com/${REPO}/tar.gz/refs/heads/${BRANCH}}"

log()  { printf '==> %s\n' "$*"; }
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
  curl -fsSL "$TARBALL_URL" -o "$ARCHIVE" \
    || die "下载失败: $TARBALL_URL"
else
  wget -qO "$ARCHIVE" "$TARBALL_URL" \
    || die "下载失败: $TARBALL_URL"
fi

log "解压…"
tar -xzf "$ARCHIVE" -C "$TMP"
# 解压目录名一般是 codeg-tools-main
SRC="$(find "$TMP" -mindepth 1 -maxdepth 1 -type d -name 'codeg-tools-*' | head -1)"
[[ -n "${SRC:-}" && -f "$SRC/install.sh" ]] || die "压缩包里找不到 install.sh"

chmod +x "$SRC/install.sh" "$SRC/uninstall.sh" 2>/dev/null || true
log "开始安装…"
# 透传参数：curl | bash -s -- --desktop
exec bash "$SRC/install.sh" "$@"
