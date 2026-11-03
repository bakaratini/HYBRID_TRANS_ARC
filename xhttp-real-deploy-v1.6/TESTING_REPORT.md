# xhttp-real-deploy v1.6 测试报告

## 测试日期
2026-11-03

## 已执行检查
- `bash -n deploy.sh runtime-versions.sh uninstall.sh update.sh`：通过。
- 卸载隔离测试：工具归属标记开启且二进制缺失时，配置目录和 systemd 单元均被删除；标记开启且二进制存在时，二进制、配置目录和单元均被删除；标记关闭时，Xray 文件保持不变且未调用停止或禁用命令。
- 单节点 dry-run：生成的 JSON 含一个 Shadowsocks inbound，密码为 16 个小写十六进制字符；生成一个 Shadowsocks 客户端链接。
- 多节点 dry-run：生成 Shadowsocks 和 VLESS/Reality 两个 inbound；Reality target 为本机 Nginx 回落端口；生成一条 Shadowsocks 和一条 VLESS 客户端链接；状态配置不再写入未使用的 Dest 字段。
- 工具目录文件检查：包含部署、更新、卸载脚本、运行时版本文件、README 和本报告。
- 归档校验：v1.6 归档文件清单与工具目录一致。

## 未执行
- 未在真实 VPS 上运行安装流程或下载官方 Xray 安装器。
- 未使用 v2rayN 等客户端进行实际连接测试。
- 未等待或实际运行 cron 证书续期任务。

上述未执行项目不应视为已通过生产部署验证。
