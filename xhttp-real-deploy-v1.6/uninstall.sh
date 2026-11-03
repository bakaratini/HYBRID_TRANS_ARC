#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

APP_NAME="xhttp-real-deploy"
STATE_DIR="/etc/${APP_NAME}"
INSTALL_STATE_FILE="${STATE_DIR}/install-state.env"
XRAY_CONFIG_PATH="/usr/local/etc/xray/config.json"
NGINX_CONF_PATH="/etc/nginx/conf.d/${APP_NAME}.conf"
NGINX_DEFAULT_SITE_PATH="/etc/nginx/sites-enabled/default"
CLIENT_FILE="/root/${APP_NAME}/client-v2rayn.txt"
CLIENT_DIR="/root/${APP_NAME}"
SITE_DIR="/var/www/${APP_NAME}"
DRY_RUN=0
ASSUME_YES=0

NGINX_WAS_ACTIVE=0
log() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage:
  sudo bash uninstall.sh [--dry-run] [--yes]

Without --yes, the script asks for the word UNINSTALL before making changes.
Firewall rules are not changed.
EOF
}

parse_args() {
  while (($#)); do
    case "$1" in
      --dry-run) DRY_RUN=1 ;;
      --yes|-y) ASSUME_YES=1 ;;
      --help|-h) usage; exit 0 ;;
      *) usage >&2; die "unknown argument: $1" ;;
    esac
    shift
  done
}

require_root() {
  (( DRY_RUN )) && return 0
  [[ $EUID -eq 0 ]] || die "run this script as root"
}

load_state() {
  [[ -f "$INSTALL_STATE_FILE" ]] || die "installation state is missing"
  # shellcheck disable=SC1090
  . "$INSTALL_STATE_FILE"
  [[ "${STATE_VERSION:-}" == 4 ]] || die "unsupported installation state version"
}

show_plan() {
  printf '\n将要移除或恢复以下资源：\n'
  (( XRAY_INSTALLED_BY_TOOL )) && printf '  - Xray 安装文件\n'
  printf '  - Nginx 配置：%s\n' "$NGINX_CONF_PATH"
  printf '  - 客户端链接和站点文件\n'
  [[ "${NGINX_DEFAULT_SITE_DISABLED_BY_TOOL:-0}" == 1 ]] &&
    printf '  - 恢复 Debian 默认 Nginx 站点（如果之前被禁用）\n'
  printf '  - 本地状态和证书副本\n'
  [[ -n "${OWNED_PACKAGES:-}" ]] && printf '  - 新安装的 Debian 软件包\n'
  printf '\n防火墙规则不会被修改。\n'
}

confirm_uninstall() {
  (( ASSUME_YES || DRY_RUN )) && return 0
  local answer
  printf '\n输入 UNINSTALL 确认卸载：'
  read -r answer
  [[ "$answer" == "UNINSTALL" ]] || die "卸载已取消"
}

stop_services() {
  log "stopping services"
  (( DRY_RUN )) && return 0
  
  # 记录 Nginx 初始状态
  if systemctl is-active --quiet nginx 2>/dev/null; then
    NGINX_WAS_ACTIVE=1
  else
    NGINX_WAS_ACTIVE=0
  fi
  
  if (( XRAY_INSTALLED_BY_TOOL )); then
    systemctl stop xray 2>/dev/null || true
  fi
  # 只在有 Reality 节点时才停止 Nginx
  if [[ -f "$NGINX_CONF_PATH" ]]; then
    systemctl stop nginx 2>/dev/null || true
  fi
}

remove_xray() {
  (( XRAY_INSTALLED_BY_TOOL )) || return 0
  log "removing Xray"
  (( DRY_RUN )) && return 0

  systemctl disable xray 2>/dev/null || true
  systemctl stop xray 2>/dev/null || true
  rm -f /usr/local/bin/xray
  rm -rf /usr/local/etc/xray
  rm -f /etc/systemd/system/xray.service
  rm -f /etc/systemd/system/xray@.service
  systemctl daemon-reload

  if (( XRAY_USER_CREATED_BY_TOOL )) && getent passwd xray >/dev/null; then
    userdel xray 2>/dev/null || true
  fi
  if (( XRAY_GROUP_CREATED_BY_TOOL )) && getent group xray >/dev/null; then
    groupdel xray 2>/dev/null || true
  fi
}

remove_configs() {
  log "removing configurations"
  (( DRY_RUN )) && return 0

  rm -f "$NGINX_CONF_PATH"
  rm -f "$CLIENT_FILE"
  [[ -d "$CLIENT_DIR" ]] && rmdir "$CLIENT_DIR" 2>/dev/null || true

  # Remove certificate renewal scripts
  rm -f /usr/local/bin/xhttp-real-renew-cert.sh
  rm -f /etc/cron.daily/xhttp-real-cert-renewal

  if (( SITE_DIR_CREATED_BY_TOOL )); then
    rm -rf "$SITE_DIR"
  elif (( SITE_INDEX_CREATED_BY_TOOL )); then
    rm -f "$SITE_DIR/index.html"
    rmdir "$SITE_DIR" 2>/dev/null || true
  fi
}

restore_nginx_site() {
  [[ "${NGINX_DEFAULT_SITE_DISABLED_BY_TOOL:-0}" == 1 ]] || return 0
  [[ -n "${NGINX_DEFAULT_SITE_TARGET:-}" ]] || return 0
  log "restoring Debian default Nginx site"
  (( DRY_RUN )) && return 0

  local target_path="/etc/nginx/sites-available/default"
  if [[ -f "$target_path" && ! -e "$NGINX_DEFAULT_SITE_PATH" ]]; then
    ln -s "$target_path" "$NGINX_DEFAULT_SITE_PATH"
  fi
}

remove_packages() {
  [[ -n "${OWNED_PACKAGES:-}" ]] || return 0
  log "removing packages: ${OWNED_PACKAGES}"
  (( DRY_RUN )) && return 0

  export DEBIAN_FRONTEND=noninteractive
  # shellcheck disable=SC2086
  apt-get remove -y $OWNED_PACKAGES 2>/dev/null || true
  apt-get autoremove -y 2>/dev/null || true
}

remove_state() {
  log "removing state directory"
  (( DRY_RUN )) && return 0
  rm -rf "$STATE_DIR"
}

restart_services() {
  log "restarting remaining services"
  (( DRY_RUN )) && return 0
  
  # 只在 Nginx 原本运行时才重启
  if (( NGINX_WAS_ACTIVE )) && systemctl is-enabled nginx >/dev/null 2>&1; then
    systemctl restart nginx || warn "nginx failed to restart"
  fi
}

print_summary() {
  printf '\n卸载完成。\n'
  printf '\n请手动清理防火墙规则（如果已配置）。\n'
}

main() {
  parse_args "$@"
  require_root
  load_state
  show_plan
  confirm_uninstall

  stop_services
  remove_xray
  remove_configs
  restore_nginx_site
  remove_packages
  remove_state
  restart_services

  print_summary
}

main "$@"
