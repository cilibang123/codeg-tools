# codeg-tools

给已部署的 **Codeg** 增强状态栏：

- 账号额度（Codex / Grok）— **本地窗口读本地，远程工作区读远端**
- 本机 IP
- 斜杠命令 / Effort 中文说明

## 一键安装

**Linux 服务器**（systemd / nginx 需要 root）：

```bash
curl -fsSL https://raw.githubusercontent.com/cilibang123/codeg-tools/main/get.sh | sudo bash
```

**macOS 桌面（安装时若 App 在运行会自动重启）**（当前登录用户，**不要 sudo**）：

```bash
curl -fsSL https://raw.githubusercontent.com/cilibang123/codeg-tools/main/get.sh | bash -s -- --desktop
```

若出现 `Permission denied`（上次误用 sudo 留下 root 目录），先收回权限再装：

```bash
sudo chown -R "$(whoami)" "$HOME/Library/Application Support/codeg-quota"
curl -fsSL https://raw.githubusercontent.com/cilibang123/codeg-tools/main/get.sh | bash -s -- --desktop
```

## 一键卸载

**Linux：**

```bash
curl -fsSL https://raw.githubusercontent.com/cilibang123/codeg-tools/main/uninstall-get.sh | sudo bash
```

**macOS：**

```bash
curl -fsSL https://raw.githubusercontent.com/cilibang123/codeg-tools/main/uninstall-get.sh | bash
```

只停服务、不还原前端：

```bash
curl -fsSL https://raw.githubusercontent.com/cilibang123/codeg-tools/main/uninstall-get.sh | bash -s -- --keep-web
```

## 额度：本地 vs 远程

| 窗口 | 数据源 |
|------|--------|
| 本机工作区 | 本机 sidecar / 本机同源 `/codeg-quota` |
| **远程工作区**（`remoteConnectionId`） | **仅** `{远程 baseUrl}/codeg-quota/summary`，绝不回退本地 |

远程窗口在 transport 未就绪时会显示加载中，**不会**误显示 Mac 本机额度。

远端需已安装 codeg-tools（HTTPS 站点需反代 `/codeg-quota/`）。远程地址建议 https。

## 安装脚本如何选型

| 环境 | 策略 |
|------|------|
| nginx/caddy 反代到 codeg | 注入 `/codeg-quota/` → sidecar |
| 无反代、codeg 直接对外 | edge 占对外端口（Linux） |
| 本机 / macOS 桌面（安装时若 App 在运行会自动重启） | `127.0.0.1:3091` 直连 |

## 自检

```bash
curl -sS http://127.0.0.1:3091/summary | head -c 200
# HTTPS 远端示例：
curl -skS https://你的域名/codeg-quota/summary | head -c 200
```

浏览器硬刷新；macOS 请完全退出后重开 codeg.app。
