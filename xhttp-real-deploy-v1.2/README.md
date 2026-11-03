# xhttp-real-deploy v1.2

Debian 12/13 VPS 部署工具，支持 Shadowsocks + VLESS Reality + XHTTP 混合节点部署。

## 节点布局

- **第1个端口**：Shadowsocks 协议（chacha20-ietf-poly1305）
- **第2-5个端口**（可选）：VLESS + Reality + XHTTP 协议

所有端口使用连续端口号，从基础端口开始自动分配。

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
6. **TLS 证书**：用于 Reality 回落的证书和私钥（仅 Reality 节点需要）
7. **节点别名**：基础别名，会自动追加端口号

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

### SNI 和回落域名

内置以下配置，可选择或随机：
1. pvp.qq.com
2. lol.qq.com
3. music.163.com

## 协议特性

### Shadowsocks 节点（第1个端口）

- **加密方式**：chacha20-ietf-poly1305
- **密码生成**：自动使用第一个 UUID 的前三段（去掉最后的 `-` 和12位）
- **适用场景**：简单快速连接

### Reality 节点（第2-5个端口）

- **TLS 指纹随机化**：
  - 偶数端口使用 `safari` 指纹
  - 奇数端口使用 `firefox` 指纹
- **多 Short ID**：每个节点独立的 Short ID
- **SNI 随机化**：可为每个节点选择不同的 SNI 域名
- **XHTTP 路径**：默认 `/api/v1`，可自定义

## 端口配置

基础端口会自动扩展为连续端口：
- 基础端口 6866，2个节点 → 6866（SS）、6867（Reality）
- 基础端口 6866，5个节点 → 6866（SS）、6867-6870（Reality）

回落端口自动计算：
- Reality 节点端口 + 10000 = Nginx 回落端口（仅监听 127.0.0.1）

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

## 卸载

```bash
sudo bash /opt/xhttp-real-deploy/uninstall.sh --dry-run  # 查看卸载范围
sudo bash /opt/xhttp-real-deploy/uninstall.sh            # 执行卸载（需要输入 UNINSTALL 确认）
sudo bash /opt/xhttp-real-deploy/uninstall.sh --yes      # 跳过确认直接卸载
```

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
- SNI/Dest：选择4随机
- XHTTP 路径：回车使用 /api/v1
- Reality 私钥：粘贴生成的私钥
- 节点别名：my-proxy
- 证书路径：/path/to/cert.pem
- 私钥路径：/path/to/key.pem

## 注意事项

1. **单节点部署**：只部署1个节点时，只会创建 Shadowsocks 节点，不需要 Reality 私钥和证书
2. **证书要求**：如果部署 Reality 节点，必须提供有效的 TLS 证书和私钥
3. **端口范围**：基础端口最大 55535，确保回落端口（+10000）不超过 65535
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

## 技术细节

- **Shadowsocks 密码**：取第一个 UUID 的前三段并移除分隔符，生成 16 位十六进制字符
- **TLS 指纹**：根据端口奇偶性自动分配，增强抗检测能力
- **XHTTP Extra**：使用优化的多路复用参数
- **HTTP 版本**：统一使用 HTTP/1.1（Reality 回落站点）
- **安全性**：所有敏感配置文件权限为 600 或 640

## 版本信息

- **Xray-core**：自动解析官方最新稳定版
- **Nginx**：使用 Debian 仓库版本
- **依赖包**：ca-certificates、curl、cron、iproute2、jq、nginx、openssl、unzip
