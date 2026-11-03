#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

APP_NAME="xhttp-real-deploy"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
. "${SCRIPT_DIR}/runtime-versions.sh"
STATE_DIR="/etc/${APP_NAME}"
INSTALL_STATE_FILE="${STATE_DIR}/install-state.env"
XRAY_CONFIG_PATH="/usr/local/etc/xray/config.json"
NGINX_CONF_PATH="/etc/nginx/conf.d/${APP_NAME}.conf"
DRY_RUN=0
ASSUME_YES=0

log() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage:
  sudo bash update.sh [--dry-run] [--yes]

Without --yes, the script asks for the word UPDATE before making changes.
This updates Xray, Nginx, and system packages. Node configuration is not changed.
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

show_update_plan() {
  local current_xray="${XRAY_VERSION_INSTALLED:-未安装}"
  local current_nginx="${NGINX_VERSION_INSTALLED:-未安装}"

  printf '\n当前版本：\n'
  printf '  Xray: %s\n' "$current_xray"
  printf '  Nginx: %s\n' "$current_nginx"

  if (( ! DRY_RUN )); then
    resolve_latest_versions || die "无法解析最新版本"
    printf '\n目标版本：\n'
    printf '  Xray: %s\n' "$XRAY_VERSION"
    printf '  Nginx: 系统仓库最新版\n'
  fi

  printf '\n将要更新：\n'
  printf '  - Xray-core 到最新稳定版\n'
  printf '  - Nginx 和系统依赖包\n'
  printf '\n不会修改：\n'
  printf '  - 节点配置\n'
  printf '  - 客户端链接\n'
  printf '  - 证书\n'
}

confirm_update() {
  (( ASSUME_YES || DRY_RUN )) && return 0
  local answer
  printf '\n输入 UPDATE 确认更新：'
  read -r answer
  [[ "$answer" == "UPDATE" ]] || die "更新已取消"
}

backup_configs() {
  log "backing up configurations"
  (( DRY_RUN )) && return 0

  local backup_dir="${STATE_DIR}/backups/update-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$backup_dir"

  [[ -f "$XRAY_CONFIG_PATH" ]] && cp "$XRAY_CONFIG_PATH" "$backup_dir/"
  [[ -f "$NGINX_CONF_PATH" ]] && cp "$NGINX_CONF_PATH" "$backup_dir/"
}

update_packages() {
  log "updating system packages"
  (( DRY_RUN )) && return 0

  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get upgrade -y nginx ca-certificates curl openssl
}

update_xray() {
  (( XRAY_INSTALLED_BY_TOOL )) || return 0
  log "updating Xray to ${XRAY_VERSION}"
  (( DRY_RUN )) && return 0

  local installer
  installer="$(mktemp)"
  curl -fsSL "https://raw.githubusercontent.com/XTLS/Xray-install/${XRAY_INSTALL_REF}/install-release.sh" -o "$installer"

  if ! bash "$installer" install --version "$XRAY_VERSION"; then
    rm -f "$installer"
    die "Xray 更新失败"
  fi
  rm -f "$installer"

  XRAY_VERSION_INSTALLED="$(/usr/local/bin/xray version 2>/dev/null | sed -n '1p')"
  XRAY_BINARY_SHA256="$(sha256sum /usr/local/bin/xray | awk '{print $1}')"
}

restart_services() {
  log "restarting services"
  (( DRY_RUN )) && return 0

  systemctl daemon-reload
  systemctl restart xray

  if systemctl is-enabled nginx >/dev/null 2>&1; then
    systemctl restart nginx
  fi
}

update_state() {
  (( DRY_RUN )) && return 0

  local state_file="$INSTALL_STATE_FILE"
  local temp_file="${state_file}.tmp"

  # Update relevant fields in state file
  if [[ -f "$state_file" ]]; then
    # shellcheck disable=SC1090
    . "$state_file"

    {
      printf 'STATE_VERSION=4\n'
      printf 'XRAY_INSTALLER_COMMIT=%q\n' "$XRAY_INSTALL_REF"
      printf 'XRAY_VERSION_RESOLVED=%q\n' "$XRAY_VERSION"
      printf 'XRAY_VERSION_INSTALLED=%q\n' "$XRAY_VERSION_INSTALLED"
      printf 'NGINX_VERSION_INSTALLED=%q\n' "$(nginx -v 2>&1)"
      printf 'DEBIAN_PACKAGE_VERSIONS=%q\n' "${DEBIAN_PACKAGE_VERSIONS:-}"
      printf 'COMPONENTS_UPDATED_UTC=%q\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      printf 'XRAY_INSTALLED_BY_TOOL=%q\n' "${XRAY_INSTALLED_BY_TOOL:-0}"
      printf 'XRAY_USER_CREATED_BY_TOOL=%q\n' "${XRAY_USER_CREATED_BY_TOOL:-0}"
      printf 'XRAY_GROUP_CREATED_BY_TOOL=%q\n' "${XRAY_GROUP_CREATED_BY_TOOL:-0}"
      printf 'XRAY_SERVICE_FILE=%q\n' "${XRAY_SERVICE_FILE:-}"
      printf 'XRAY_SERVICE_SHA256=%q\n' "${XRAY_SERVICE_SHA256:-}"
      printf 'XRAY_BINARY_SHA256=%q\n' "$XRAY_BINARY_SHA256"
      printf 'XRAY_SERVICE_USER=%q\n' "${XRAY_SERVICE_USER:-}"
      printf 'XRAY_SERVICE_GROUP=%q\n' "${XRAY_SERVICE_GROUP:-}"
      printf 'XRAY_CONFIG_MODE=%q\n' "${XRAY_CONFIG_MODE:-}"
      printf 'OWNED_PACKAGES=%q\n' "${OWNED_PACKAGES:-}"
      printf 'PACKAGE_BASELINE_FILE=%q\n' "${PACKAGE_BASELINE_FILE:-}"
      printf 'XRAY_CONFIG_BACKUP=%q\n' "${XRAY_CONFIG_BACKUP:-}"
      printf 'NGINX_CONFIG_BACKUP=%q\n' "${NGINX_CONFIG_BACKUP:-}"
      printf 'NGINX_DEFAULT_SITE_TARGET=%q\n' "${NGINX_DEFAULT_SITE_TARGET:-}"
      printf 'NGINX_DEFAULT_SITE_DISABLED_BY_TOOL=%q\n' "${NGINX_DEFAULT_SITE_DISABLED_BY_TOOL:-0}"
      printf 'CLIENT_FILE_BACKUP=%q\n' "${CLIENT_FILE_BACKUP:-}"
      printf 'CLIENT_FILE_CREATED_BY_TOOL=%q\n' "${CLIENT_FILE_CREATED_BY_TOOL:-0}"
      printf 'SITE_DIR_CREATED_BY_TOOL=%q\n' "${SITE_DIR_CREATED_BY_TOOL:-0}"
      printf 'SITE_INDEX_CREATED_BY_TOOL=%q\n' "${SITE_INDEX_CREATED_BY_TOOL:-0}"
      printf 'SITE_INDEX_SHA256=%q\n' "${SITE_INDEX_SHA256:-}"
      printf 'XRAY_CONFIG_SHA256=%q\n' "${XRAY_CONFIG_SHA256:-}"
      printf 'NGINX_CONFIG_SHA256=%q\n' "${NGINX_CONFIG_SHA256:-}"
      printf 'CLIENT_FILE_SHA256=%q\n' "${CLIENT_FILE_SHA256:-}"
    } > "$temp_file"

    chmod 600 "$temp_file"
    mv -f "$temp_file" "$state_file"
  fi
}

print_summary() {
  printf '\n更新完成。\n'
  printf '  Xray: %s\n' "${XRAY_VERSION_INSTALLED}"
  printf '  Nginx: %s\n' "$(nginx -v 2>&1)"
  printf '\n服务已重启，配置未修改。\n'
}

main() {
  parse_args "$@"
  require_root
  load_state
  show_update_plan
  confirm_update

  backup_configs
  update_packages
  update_xray
  restart_services
  update_state

  print_summary
}

main "$@"
