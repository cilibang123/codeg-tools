# codeg-tools

给**已部署的 Codeg** 一键挂上：

- 状态栏 **账号额度**（Codex / Grok）
- 状态栏 **本机 IP**
- **斜杠命令 / Effort** 中文说明

不修改 `codeg-server` 二进制。官方升级 Codeg 后**再跑一次安装命令**即可。

## 一行安装

**Linux 服务器**（写 systemd / nginx 需要 root）：

```bash
curl -fsSL https://raw.githubusercontent.com/cilibang123/codeg-tools/main/get.sh | sudo bash
```

**macOS 桌面**（请用当前登录用户，**尽量不要 sudo**；sudo 时脚本会把服务装回你的用户）：

```bash
# 推荐
curl -fsSL https://raw.githubusercontent.com/cilibang123/codeg-tools/main/get.sh | bash -s -- --desktop

# 若必须 sudo 写 /Applications，也可以，服务仍归当前用户
curl -fsSL https://raw.githubusercontent.com/cilibang123/codeg-tools/main/get.sh | sudo bash -s -- --desktop
```

装完后在**同一用户**下登录额度源：

```bash
codex login
grok login
curl -sS http://127.0.0.1:3091/summary | head
```

然后完全退出并重新打开 codeg.app（或硬刷新）。

## 脚本怎么“变聪明”

安装时会**只读探测**环境，再选侵入最小的方案：

| 探测到的环境 | 策略 |
|--------------|------|
| **nginx/caddy** 反代到 codeg（常见 `https://域名`） | 注入 `location /codeg-quota/` → sidecar，**不抢 3080** |
| **无反代**，codeg 直接对外（局域网 `:3080`） | 可选 edge：codeg 挪到内网端口，edge 占对外端口并挂 `/codeg-quota` |
| **本机直连 / 无法改反代** | sidecar 监听 `0.0.0.0:3091`，并尝试放行防火墙 |

前端固定优先请求**与页面同源**的路径：

```text
/codeg-quota/summary
```

因此：

- HTTPS 站点不会触发「混合内容」拦 `http://…:3091`
- 云主机不必对公网开放 3091
- 局域网 IP 打开、域名反代打开都能用

另外会自动：

- 找 WebUI 目录（进程环境 / env 文件 / 常见路径，跳过 backup）
- 找 codeg 的 systemd 单元名（`codeg` / `codeg-server` / …）
- 给 sidecar 配好 `PATH`/`HOME`，写入绝对 `codex` 路径

## 装完自检

```bash
curl -sS http://127.0.0.1:3091/health
curl -sS http://127.0.0.1:3091/summary | head -c 200

# 若走 nginx 同源：
curl -skS https://你的域名/codeg-quota/summary | head -c 200
# 或本机
curl -sS http://127.0.0.1:3080/codeg-quota/summary | head -c 200
```

浏览器：**硬刷新**（Ctrl+Shift+R）。

## 卸载

```bash
# 仓库内
./uninstall.sh
```

## 目录

| 路径 | 说明 |
|------|------|
| `get.sh` | curl \| bash 入口 |
| `install.sh` | 智能安装 |
| `uninstall.sh` | 卸载 |
| `sidecar/` | 额度服务 + edge 代理 |
| `web/` | 预构建前端 |

## 依赖

- Node.js（sidecar）
- 可选：`codex login` / `grok login` 以拉真实额度
