# codeg-quota-addon

给**已部署的 Codeg** 一键挂上状态栏增强：

- **左侧**：本机局域网 IP（点击可复制）
- **右侧**：账号额度（Codex 周额度 + Grok SuperGrok Heavy 周额度）
- **斜杠命令菜单**：常见命令说明汉化（`/` 弹出菜单；未知命令仍显示 Agent 原文）


- **不修改** `codeg-server` 二进制  
- 官方更新后：**再跑一次 `install.sh` 即可**  
- **单脚本**，可选 Linux / macOS（含 macOS WebUI；可选桌面 App）

## 包含内容

| 目录 | 说明 |
|------|------|
| `install.sh` | 一键安装 / 升级（幂等） |
| `uninstall.sh` | 卸载并尽量还原 WebUI 备份 |
| `sidecar/` | 额度聚合服务（Node，调官方 Codex / Grok 接口） |
| `web/` | 已带额度 UI 的前端静态资源（预构建） |

## 依赖

- `node`（sidecar）
- 本机已登录（按需）：`codex login`、`grok login`
- Linux root 可写 systemd；macOS 用 launchd（用户级）

## 安装（推荐：一行命令）

```bash
curl -fsSL https://raw.githubusercontent.com/cilibang123/codeg-tools/main/get.sh | bash
```

需要写系统目录 / systemd 时：

```bash
curl -fsSL https://raw.githubusercontent.com/cilibang123/codeg-tools/main/get.sh | sudo bash
```

macOS 桌面 App 也注入：

```bash
curl -fsSL https://raw.githubusercontent.com/cilibang123/codeg-tools/main/get.sh | bash -s -- --desktop
```

> `get.sh` 会自动下载完整安装包并执行 `install.sh`，无需手动 clone。

### 本地已有仓库时

```bash
cd codeg-tools
chmod +x install.sh uninstall.sh
./install.sh                 # 全自动
./install.sh --os linux
./install.sh --os macos              # macOS WebUI + 本机 sidecar
./install.sh --os macos --desktop    # 再注入 codeg.app
./install.sh --os auto -y            # 自动检测，非交互
./install.sh --sidecar-only
./install.sh --web-only --web-dir /usr/local/share/codeg/web
```

### 常用参数

| 参数 | 含义 |
|------|------|
| `--os ask\|auto\|linux\|macos` | 目标系统 |
| `--desktop` | macOS 同时注入 `/Applications/codeg.app` 内 web |
| `--web-dir PATH` | 手动指定 WebUI 目录 |
| `--app PATH` | 手动指定 `.app` 路径 |
| `--bind 0.0.0.0` | sidecar 监听地址（默认 `0.0.0.0`，LAN 可访问） |
| `--port 3091` | sidecar 端口 |
| `--sidecar-only` / `--web-only` | 分步安装 |
| `-y` | 非交互（`--os ask` 时用自动检测） |

## 官方更新之后

```bash
# 装完官方新版 Codeg 后：
./install.sh --os auto -y
# 或 macOS 桌面也要：
./install.sh --os macos --desktop -y
```

脚本会：

1. 覆盖/更新 sidecar  
2. 若尚无备份则备份当前 `web` → `web.official-backup`  
3. 重新部署带额度的前端  

## 卸载

```bash
./uninstall.sh --os linux
./uninstall.sh --os macos
# 只停服务、不还原 web：
./uninstall.sh --os linux --keep-web
```

## 额度数据从哪来

| 产品 | 方式 |
|------|------|
| Codex | 官方 `codex app-server` → `account/rateLimits/read` |
| Grok | CLI 同源 `GET .../v1/billing?format=credits`（等同 `/usage`） |

密钥只读本机 `~/.codex`、`~/.grok`，不进 Git。

## 显示

状态栏中文示例：

```text
Codex 剩余 41% · 5天
Grok 剩余 99% · 23小时
```

不足 1 天自动改为小时/分钟。

## 架构

```text
浏览器 / macOS WebUI / 桌面壳
    → 静态页内额度条
    → http://<页面主机名>:3091/summary（apiUrl=auto）
        → codeg-quota sidecar
            → Codex / Grok 官方接口
```

Linux Web 与 macOS WebUI 同一套挂载逻辑；macOS 桌面多一步写 App 内 `Resources/.../web`。


## 故障排查：状态栏显示「额度离线」

1. 确认 sidecar 在跑：
   ```bash
   curl -sS http://127.0.0.1:3091/health
   curl -sS http://127.0.0.1:3091/summary
   ```
2. 若用局域网 IP 打开 WebUI（如 `http://192.168.x.x:3080`），请确认：
   - `quota-config.json` 里 `"apiUrl": "auto"`（安装脚本默认已写）
   - sidecar 监听 `0.0.0.0:3091`（不是只绑 127.0.0.1）
   - 浏览器能打开：`http://<同一局域网IP>:3091/summary`
3. 浏览器缓存了错误地址时（旧版曾写入 `127.0.0.1`）：
   - **硬刷新**页面（Ctrl/Cmd+Shift+R）
   - 或在控制台执行：`localStorage.removeItem("codeg.quota.apiUrl")` 后刷新  
   - v1.1.1+ 前端会自动忽略「页面是局域网 IP、但 apiUrl 指向 127.0.0.1」的脏配置
4. 本机需已登录：`codex login`、`grok login`（或 `~/.grok/auth.json` 有效）

