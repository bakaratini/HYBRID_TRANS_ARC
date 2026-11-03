# xhttp-real-deploy v1.2 测试报告

## 测试日期
2026-11-03

## 测试环境与范围
- 沙盒环境，Bash 5.2.37。
- 对四个 Bash 脚本执行语法检查。
- 用部署 dry-run 检查单节点和三节点配置生成。
- 在重定向到隔离目录的卸载脚本副本中验证 Xray 清理行为，使用 systemctl stub；未访问系统服务路径。

## 测试结果
- `bash -n`：deploy.sh、runtime-versions.sh、update.sh、uninstall.sh 均通过。
- 单节点 dry-run：生成的 JSON 可由 jq 解析；包含 1 个 Shadowsocks inbound 和 1 条客户端链接。
- 三节点 dry-run：生成的 JSON 可由 jq 解析；包含 1 个 Shadowsocks inbound、2 个 VLESS inbound、2 个 Nginx 回落 server 和 3 条客户端链接。
- 五节点端口边界 dry-run：基础端口 `55531` 生成节点端口至 `55535`，最高回落端口为 `65535`。
- 固定 UUID dry-run：SS 客户端链接中的密码为 `12345678abcdef01`，符合脚本的前三段取值逻辑。
- 卸载隔离测试：归属标记开启且 Xray 二进制缺失时，配置目录与 systemd 单元被清理；标记开启且二进制存在时也能清理；标记关闭时，Xray 文件保留且不会调用 Xray 的 stop、disable 或 daemon-reload。
- 发布包检查：归档文件清单与 v1.2 工具包目录一致。

## 密码格式
Shadowsocks 密码由第一个 UUID 的前三段去掉分隔符后组成，共 16 个十六进制字符。自动生成的 UUID 为 UUIDv4；手动输入 UUID 的随机强度取决于输入值。

## 未覆盖范围
未在真实 Debian VPS 上安装或启动服务；未验证 Xray 对配置的运行时接受情况，也未测试 v2rayN 等客户端的实际连接。未执行 ShellCheck（环境中未安装）。
