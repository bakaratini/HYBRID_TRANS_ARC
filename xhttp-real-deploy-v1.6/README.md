# xhttp-real-deploy v1.6

Debian 12/13 VPS 部署工具，支持 Shadowsocks + VLESS Reality + XHTTP 混合节点部署。

## 节点布局

- **第1个端口**：Shadowsocks 协议（chacha20-ietf-poly1305）
- **第2-5个端口**（可选）：VLESS + Reality + XHTTP 协议

所有端口使用连续端口号，从基础端口开始自动分配。

## 版本特性

### 自动证书管理 ✨
- ✅ **自动生成自签名证书**：无需手动准备证书
- ✅ **证书自动续期**：到期前 30 天自动更新
- ✅ **完全自动化**：部署时无需任何证书相关操作

### 核心功能
- 混合协议部署（Shadowsocks + Reality）
- TLS 指纹随机化（奇偶端口）
- 多 Short ID 随机选择
- Reality SNI 选择和随机化
- 输入验证重试机制

## 执行方式

将工具上传到 GitHub 仓库后，在 Debian VPS 上执行：

```bash
sudo install -d -m 755 /opt/xhttp-real-deploy
sudo curl -fsSL https://raw.githubusercontent.com/OWNER/REPOSITORY/main/deploy.sh -o /opt/xhttp-real-deploy/deploy.sh
sudo curl -fsSL https://raw.githubusercontent.com/OWNER/REPOSITORY/main/runtime-versions.sh -o /opt/xhttp-real-deploy/runtime-versions.sh
sudo curl -fsSL https://raw.githubusercontent.com/OWNER/REPOSITORY/main/uninstall.sh -o /opt/xhttp-real-deploy/uninstall.sh
sudo curl -fsSL https://raw.githubusercontent.com/OWNER/REPOSITORY/main/update.sh -o /opt/xhttp-real-deploy/update.sh
sudo bash /opt/xhttp-real-deploy/deploy.sh
```

## 系统要求

- Debian 12 或 Debian 13
- Root 权限
- IPv4 公网地址
- 无现有 Xray 安装

## 准备工作

部署前需要准备：

1. **节点数量**：1-5 个节点
2. **基础端口**：一个可用的 TCP 端口（如 6866）
3. **UUID**：可以手动提供或自动生成
4. **Short ID**：可以手动提供或从预设池随机选择（仅 Reality 节点需要）
5. **Reality 私钥**：base64url 格式（仅 Reality 节点需要）
6. **节点别名**：基础别名，会自动追加端口号

**注意**：无需手动准备 TLS 证书，脚本会自动生成并管理。

### UUID 生成

Windows PowerShell：
```powershell
[guid]::NewGuid().ToString()
```

Linux：
```bash
uuidgen
```

或部署时直接回车自动生成。

### Reality 私钥生成

使用 Xray 生成：
```bash
xray x25519
```

复制输出的 `PrivateKey` 部分。

### Short ID 预设池

工具内置以下 Short ID 池，可直接回车随机选择：
- 9a68e6a9
- e6a89689
- 86a9e698
- a9e66896
- 698e9a86
- 8f6e2a95
- 8a96e689
- 69ea88ae

### Reality SNI

内置以下配置，可选择或随机：
1. pvp.qq.com
2. lol.qq.com
3. music.163.com

## 协议特性

### Shadowsocks 节点（第1个端口）

- **加密方式**：chacha20-ietf-poly1305
- **密码生成**：自动使用第一个 UUID 的前三段（16个十六进制字符，编码长度为 64 bit）
- **适用场景**：简单快速连接

### Reality 节点（第2-5个端口）

- **TLS 指纹随机化**：
  - 偶数端口使用 `safari` 指纹
  - 奇数端口使用 `firefox` 指纹
- **多 Short ID**：每个节点独立的 Short ID
- **SNI 随机化**：可为每个节点选择不同的 SNI 域名
- **XHTTP 路径**：默认 `/api/v1`，可自定义
- **自动证书**：自签名证书自动生成和续期

## 证书管理

### 自动证书功能

**自动生成**：
- 部署时自动生成自签名证书
- 有效期 365 天
- 无需用户任何操作

**自动续期**：
- 每天检查证书有效期
- 到期前 30 天自动更新
- 更新后自动重载 Nginx

**技术细节**：
- 证书位置：`/etc/xhttp-real-deploy/tls/fullchain.pem`
- 私钥位置：`/etc/xhttp-real-deploy/tls/privkey.pem`
- 续期脚本：`/usr/local/bin/xhttp-real-renew-cert.sh`
- Cron 任务：`/etc/cron.daily/xhttp-real-cert-renewal`

## 端口配置

基础端口会自动扩展为连续端口：
- 基础端口 6866，2个节点 → 6866（SS）、6867（Reality）
- 基础端口 6866，5个节点 → 6866（SS）、6867-6870（Reality）

回落端口自动计算：
- Reality 节点端口 + 10000 = Nginx 回落端口（仅监听 127.0.0.1）

端口上限动态计算：
- 1个节点：最大 55535
- 5个节点：最大 55531

## 防火墙配置

部署后需要在 VPS 防火墙放行 TCP 入站端口：
- 所有节点端口（基础端口到基础端口+节点数-1）

示例（3个节点，基础端口 6866）：
```bash
# UFW
sudo ufw allow 6866:6868/tcp

# iptables
sudo iptables -A INPUT -p tcp --match multiport --dports 6866:6868 -j ACCEPT
```

## 客户端配置

部署完成后，客户端链接保存在：
```
/root/xhttp-real-deploy/client-v2rayn.txt
```

### Shadowsocks 链接格式
```
ss://BASE64(method:password)@IP:PORT#节点名称
```

### VLESS Reality 链接格式
```
vless://UUID@IP:PORT?encryption=none&security=reality&sni=DOMAIN&fp=FINGERPRINT&pbk=PUBLIC_KEY&sid=SHORT_ID&type=xhttp&path=PATH&mode=auto&extra=EXTRA#节点名称
```

## 配置文件

- **Xray 配置**：`/usr/local/etc/xray/config.json`
- **Nginx 配置**：`/etc/nginx/conf.d/xhttp-real-deploy.conf`
- **状态文件**：`/etc/xhttp-real-deploy/config.env`
- **安装状态**：`/etc/xhttp-real-deploy/install-state.env`
- **TLS 证书**：`/etc/xhttp-real-deploy/tls/fullchain.pem`
- **TLS 私钥**：`/etc/xhttp-real-deploy/tls/privkey.pem`

## 卸载

```bash
sudo bash /opt/xhttp-real-deploy/uninstall.sh --dry-run  # 查看卸载范围
sudo bash /opt/xhttp-real-deploy/uninstall.sh            # 执行卸载（需要输入 UNINSTALL 确认）
sudo bash /opt/xhttp-real-deploy/uninstall.sh --yes      # 跳过确认直接卸载
```

卸载会自动清理：
- Xray 和 Nginx 配置
- 证书和私钥
- 证书续期脚本和 cron 任务
- 工具安装的系统包

## 更新

```bash
sudo bash /opt/xhttp-real-deploy/update.sh --dry-run  # 查看更新内容
sudo bash /opt/xhttp-real-deploy/update.sh            # 执行更新（需要输入 UPDATE 确认）
sudo bash /opt/xhttp-real-deploy/update.sh --yes      # 跳过确认直接更新
```

更新只处理 Xray、Nginx 和系统依赖包，不会修改节点配置或客户端链接。

## 示例部署流程

### 单节点部署（仅 Shadowsocks）

```bash
sudo bash deploy.sh
```

输入：
- 节点数量：1
- 基础端口：6866（或回车使用默认值）
- VPS IPv4：自动检测或手动输入
- UUID：回车自动生成
- 节点别名：xhttp-real（或回车使用默认值）

### 多节点部署（Shadowsocks + Reality）

```bash
sudo bash deploy.sh
```

输入：
- 节点数量：3
- 基础端口：6866
- VPS IPv4：自动检测
- UUID：回车自动生成3个
- Short ID：回车随机选择2个（Reality 节点用）
- Reality SNI：选择1-3或回车随机
- XHTTP 路径：回车使用 /api/v1
- Reality 私钥：粘贴生成的私钥
- 节点别名：my-proxy

**注意**：证书会自动生成，无需手动准备。

## 注意事项

1. **单节点部署**：只部署1个节点时，只会创建 Shadowsocks 节点，不需要 Reality 私钥和证书
2. **证书自动管理**：自动生成和续期证书，无需用户干预
3. **端口范围**：基础端口动态计算上限，确保回落端口不超过 65535
4. **Nginx 冲突**：工具会自动禁用 Debian 默认的 Nginx 站点，不使用端口 80
5. **协议兼容**：生成的客户端链接兼容 v2rayN 最新版

## 故障排查

### 查看服务状态
```bash
sudo systemctl status xray
sudo systemctl status nginx  # 仅多节点部署
```

### 查看日志
```bash
sudo journalctl -u xray -f
sudo journalctl -u nginx -f  # 仅多节点部署
sudo grep xhttp-real-deploy /var/log/syslog  # 证书续期日志
```

### 检查端口监听
```bash
sudo ss -tulnp | grep -E '6866|6867|6868'
```

### 测试配置
```bash
sudo xray run -test -config /usr/local/etc/xray/config.json
sudo nginx -t  # 仅多节点部署
```

### 检查证书
```bash
# 查看证书有效期
openssl x509 -in /etc/xhttp-real-deploy/tls/fullchain.pem -noout -dates

# 手动触发证书更新
sudo /usr/local/bin/xhttp-real-renew-cert.sh
```

## 技术细节

- **Shadowsocks 密码**：由第一个 UUID 的前三段组成，共16个十六进制字符（编码长度为 64 bit，格式：`xxxxxxxxxxxxxxxx`）
- **TLS 指纹**：根据端口奇偶性自动分配，增强抗检测能力
- **XHTTP Extra**：使用优化的多路复用参数
- **HTTP 版本**：统一使用 HTTP/1.1（Reality 回落站点）
- **证书管理**：自签名证书，365天有效期，自动续期
- **安全性**：所有敏感配置文件权限为 600 或 640

## 版本历史

### v1.6 (2026-11-03)
- 修复 Xray 安装中途失败时卸载可能遗留文件和 systemd 单元的问题
- 清理未使用的 Dest 状态数据

### v1.5 (2026-11-03)
- ✨ 新增：自动生成自签名证书
- ✨ 新增：证书到期前自动续期（30天）
- 🔧 改进：完全自动化部署，无需手动准备证书

### v1.2 (2026-11-03)
- 🐛 修复：SS密码由 UUID 前三段生成（16位十六进制）
- 🐛 修复：更新保留完整状态信息
- 🐛 修复：卸载不影响现有Nginx服务
- 🐛 修复：端口上限动态计算

### v1.0 (2026-11-03)
- 🎉 首次发布
- 支持 Shadowsocks + Reality 混合部署
- TLS 指纹随机化
- 多 Short ID 和 SNI 随机选择
