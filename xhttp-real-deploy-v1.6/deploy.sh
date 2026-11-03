#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

APP_NAME="xhttp-real-deploy"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
. "${SCRIPT_DIR}/runtime-versions.sh"
DEFAULT_XHTTP_PATH="/api/v1"
DEFAULT_NODE_COUNT=1
DEFAULT_BASE_PORT=6866
DEFAULT_NODE_ALIAS="xhttp-real"
SS_METHOD="chacha20-ietf-poly1305"

SHORT_ID_POOL=(
  "9a68e6a9"
  "e6a89689"
  "86a9e698"
  "a9e66896"
  "698e9a86"
  "8f6e2a95"
  "8a96e689"
  "69ea88ae"
)

SNI_DOMAIN_POOL=(
  "pvp.qq.com"
  "lol.qq.com"
  "music.163.com"
)

XRAY_INSTALL_REF=""
XRAY_VERSION=""
XRAY_VERSION_INSTALLED=""
NGINX_VERSION_INSTALLED=""
DEBIAN_PACKAGE_VERSIONS=""
COMPONENTS_UPDATED_UTC=""
DEBIAN_PACKAGES=(ca-certificates curl cron iproute2 jq nginx openssl unzip)

DRY_RUN=0
DRY_RUN_OUTPUT=""
PROMPT_FD=0

STATE_DIR="/etc/xhttp-real-deploy"
XRAY_CONFIG_PATH="/usr/local/etc/xray/config.json"
NGINX_CONF_PATH="/etc/nginx/conf.d/xhttp-real-deploy.conf"
NGINX_DEFAULT_SITE_PATH="/etc/nginx/sites-enabled/default"
CLIENT_DIR="/root/xhttp-real-deploy"
CLIENT_FILE="${CLIENT_DIR}/client-v2rayn.txt"
CERT_DIR="${STATE_DIR}/tls"
CERT_FILE="${CERT_DIR}/fullchain.pem"
KEY_FILE="${CERT_DIR}/privkey.pem"
SITE_DIR="/var/www/xhttp-real-deploy"
INSTALL_STATE_FILE="${STATE_DIR}/install-state.env"
PACKAGE_BASELINE_FILE="${STATE_DIR}/packages.before"
BACKUP_DIR="${STATE_DIR}/backups"

NODE_COUNT=0
BASE_PORT=0
NODE_PORTS=()
UUIDS=()
SHORT_IDS=()
SNI_DOMAINS=()
REALITY_PRIVATE_KEY=""
PUBLIC_KEY=""
XHTTP_PATH=""
NODE_ALIAS_BASE=""
NODE_NAMES=()
VPS_IPV4=""
SS_PASSWORD=""

OWNED_PACKAGES=""
XRAY_INSTALLED_BY_TOOL=0
XRAY_USER_CREATED_BY_TOOL=0
XRAY_GROUP_CREATED_BY_TOOL=0
XRAY_SERVICE_FILE=""
XRAY_SERVICE_SHA256=""
XRAY_BINARY_SHA256=""
XRAY_SERVICE_USER=""
XRAY_SERVICE_GROUP=""
XRAY_CONFIG_MODE=""
XRAY_CONFIG_BACKUP=""
NGINX_CONFIG_BACKUP=""
NGINX_DEFAULT_SITE_TARGET=""
NGINX_DEFAULT_SITE_DISABLED_BY_TOOL=0
CLIENT_FILE_BACKUP=""
SITE_DIR_CREATED_BY_TOOL=0
SITE_INDEX_CREATED_BY_TOOL=0
SITE_INDEX_SHA256=""
XRAY_CONFIG_SHA256=""
NGINX_CONFIG_SHA256=""
CLIENT_FILE_SHA256=""

log()  { printf '[INFO] %s\n' "$*"; }
die()  { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage:
  sudo bash deploy.sh
  sudo bash deploy.sh --dry-run OUTPUT_DIR

The dry-run mode renders configs without installing packages or changing system files.
EOF
}

on_error() {
  local status=$?
  printf '[ERROR] deployment failed near line %s (exit %s)\n' "${1:-?}" "$status" >&2
  exit "$status"
}
trap 'on_error "$LINENO"' ERR

parse_args() {
  case "${1:-}" in
    "") ;;
    --help|-h)
      usage
      exit 0
      ;;
    --dry-run)
      DRY_RUN=1
      DRY_RUN_OUTPUT="${2:-}"
      [[ -n "$DRY_RUN_OUTPUT" ]] || die "--dry-run requires an output directory"
      ;;
    *)
      usage >&2
      die "unknown argument: $1"
      ;;
  esac
}

init_paths() {
  if (( DRY_RUN )); then
    mkdir -p "$DRY_RUN_OUTPUT"
    DRY_RUN_OUTPUT="$(cd "$DRY_RUN_OUTPUT" && pwd -P)"
    STATE_DIR="${DRY_RUN_OUTPUT}/state"
    XRAY_CONFIG_PATH="${DRY_RUN_OUTPUT}/xray-config.json"
    NGINX_CONF_PATH="${DRY_RUN_OUTPUT}/nginx.conf"
    CLIENT_DIR="$DRY_RUN_OUTPUT"
    CLIENT_FILE="${DRY_RUN_OUTPUT}/client-v2rayn.txt"
    CERT_DIR="${DRY_RUN_OUTPUT}/tls"
    CERT_FILE="${CERT_DIR}/fullchain.pem"
    KEY_FILE="${CERT_DIR}/privkey.pem"
    SITE_DIR="${DRY_RUN_OUTPUT}/site"
  fi
}

open_prompt_fd() {
  if (( ! DRY_RUN )) && [[ -r /dev/tty ]]; then
    exec {PROMPT_FD}<>/dev/tty
  else
    PROMPT_FD=0
  fi
}

prompt_value() {
  local variable="$1"
  local message="$2"
  local default_value="${3:-}"
  local answer

  if [[ -n "$default_value" ]]; then
    if ! read -r -u "$PROMPT_FD" -p "$message [$default_value]: " answer; then
      die "input ended while reading ${variable}"
    fi
    answer="${answer:-$default_value}"
  else
    if ! read -r -u "$PROMPT_FD" -p "$message: " answer; then
      die "input ended while reading ${variable}"
    fi
  fi
  printf -v "$variable" '%s' "$answer"
}

valid_uuid() {
  [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

valid_ipv4() {
  local value="$1"
  local IFS=.
  local -a octets
  read -r -a octets <<< "$value"
  [[ ${#octets[@]} -eq 4 ]] || return 1
  local octet
  for octet in "${octets[@]}"; do
    [[ "$octet" =~ ^[0-9]{1,3}$ ]] || return 1
    (( 10#$octet <= 255 )) || return 1
  done
  return 0
}

valid_short_id() {
  [[ "$1" =~ ^([0-9a-fA-F]{2}){1,8}$ ]]
}

valid_xhttp_path() {
  [[ "$1" =~ ^/[A-Za-z0-9._~/-]+$ ]]
}

require_debian_root() {
  (( DRY_RUN )) && return 0
  [[ $EUID -eq 0 ]] || die "run this script as root"
  [[ -r /etc/os-release ]] || die "cannot read /etc/os-release"
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ "${ID:-}" == debian ]] || die "only Debian 12 or Debian 13 is supported"
  [[ "${VERSION_ID:-}" =~ ^(12|13)(\.|$) ]] ||
    die "only Debian 12 or Debian 13 is supported"
  command -v systemctl >/dev/null 2>&1 || die "systemd is required"
}

detect_ipv4() {
  if (( DRY_RUN )); then
    printf '%s' "${XHTTP_TEST_IP:-198.51.100.10}"
  else
    curl -4fsS --max-time 8 https://api.ipify.org 2>/dev/null || true
  fi
}

port_listener_details() {
  local port="$1" hex matches
  if command -v ss >/dev/null 2>&1; then
    ss -H -ltnp "( sport = :${port} )" 2>/dev/null || true
    return 0
  fi

  hex="$(printf '%04X' "$port")"
  matches="$(awk -v wanted="$hex" '
    NR > 1 {
      split($2, endpoint, ":")
      if (toupper(endpoint[2]) == wanted) print
    }
  ' /proc/net/tcp /proc/net/tcp6 2>/dev/null || true)"
  if [[ -n "$matches" ]]; then
    printf 'listener on TCP port %s (process owner unavailable; iproute2/ss is not installed)\n' "$port"
  fi
}

listener_is_nginx() {
  local details="$1" line marker='users:(("nginx",'
  [[ -n "$details" ]] || return 1
  while IFS= read -r line; do
    [[ "$line" == *"$marker"* ]] || return 1
  done <<< "$details"
}

check_required_port() {
  local port="$1" allow_nginx="$2" details
  details="$(port_listener_details "$port")"
  [[ -z "$details" ]] && return 0
  if (( allow_nginx )) && listener_is_nginx "$details"; then
    log "reusing Nginx listener on local TCP port ${port}"
    return 0
  fi
  printf '[ERROR] TCP port %s is already in use:\n%s\n' "$port" "$details" >&2
  return 1
}

check_node_ports() {
  (( DRY_RUN )) && return 0
  local port fallback_port
  for port in "${NODE_PORTS[@]}"; do
    check_required_port "$port" 0 || {
      printf '[ERROR] 节点端口 %s 被占用，无法部署。\n' "$port" >&2
      return 1
    }
    fallback_port=$((port + 10000))
    check_required_port "$fallback_port" 1 || {
      printf '[ERROR] 回落端口 %s 被非 Nginx 服务占用，无法安全启动节点。\n' "$fallback_port" >&2
      return 1
    }
  done
}

generate_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr '[:upper:]' '[:lower:]'
  else
    cat /proc/sys/kernel/random/uuid 2>/dev/null || \
      printf '%08x-%04x-%04x-%04x-%012x\n' \
        $RANDOM$RANDOM $RANDOM $((RANDOM & 0x0fff | 0x4000)) \
        $((RANDOM & 0x3fff | 0x8000)) $RANDOM$RANDOM$RANDOM
  fi
}

select_random_short_id() {
  local used_ids="$1"
  local id
  for _ in {1..100}; do
    id="${SHORT_ID_POOL[$((RANDOM % ${#SHORT_ID_POOL[@]}))]}"
    if [[ "$used_ids" != *"$id"* ]]; then
      printf '%s' "$id"
      return 0
    fi
  done
  printf '%s' "${SHORT_ID_POOL[0]}"
}

select_random_sni() {
  local domain="${SNI_DOMAIN_POOL[$((RANDOM % ${#SNI_DOMAIN_POOL[@]}))]}"
  printf '%s' "$domain"
}

stock_nginx_site_target() {
  printf '%s/sites-available/default' "$(dirname "$(dirname "$NGINX_DEFAULT_SITE_PATH")")"
}

stock_nginx_site_enabled() {
  local target expected
  [[ -L "$NGINX_DEFAULT_SITE_PATH" ]] || return 1
  target="$(readlink -f "$NGINX_DEFAULT_SITE_PATH" 2>/dev/null || true)"
  expected="$(stock_nginx_site_target)"
  [[ -n "$target" && "$target" == "$expected" ]]
}

disable_stock_nginx_site() {
  (( DRY_RUN )) && return 0
  if ! stock_nginx_site_enabled; then
    return 0
  fi
  NGINX_DEFAULT_SITE_TARGET="${NGINX_DEFAULT_SITE_TARGET:-$(readlink "$NGINX_DEFAULT_SITE_PATH")}"
  rm -f "$NGINX_DEFAULT_SITE_PATH"
  NGINX_DEFAULT_SITE_DISABLED_BY_TOOL=1
  log "disabled the Debian default Nginx site; the deployment does not use TCP port 80"
}

collect_inputs() {
  local detected_ip value index count_str port_str uuid_input short_id_input
  local sni_choice sni used_short_ids i

  printf '\n%s\n' "${APP_NAME}: Shadowsocks + VLESS Reality + XHTTP deployment"
  printf '%s\n' "第一个端口部署 Shadowsocks，其余端口部署 VLESS+Reality+XHTTP。"

  while :; do
    prompt_value count_str "请输入要部署的节点数量 (1-5)" "$DEFAULT_NODE_COUNT"
    if [[ "$count_str" =~ ^[1-5]$ ]]; then
      NODE_COUNT=$((10#$count_str))
      break
    fi
    printf '[ERROR] 节点数量必须在 1 到 5 之间，请重新输入。\n' >&2
  done

  while :; do
    prompt_value port_str "请输入基础端口" "$DEFAULT_BASE_PORT"
    if [[ ! "$port_str" =~ ^[0-9]{1,5}$ ]]; then
      printf '[ERROR] 端口必须是十进制 TCP 端口，请重新输入。\n' >&2
      continue
    fi
    BASE_PORT=$((10#$port_str))
    local max_base_port=$((65535 - 10000 - NODE_COUNT + 1))
    if (( BASE_PORT < 1 || BASE_PORT > max_base_port )); then
      printf '[ERROR] 基础端口必须在 1 到 %s 之间（确保 %s 个节点的回落端口不超过 65535）。\n' "$max_base_port" "$NODE_COUNT" >&2
      continue
    fi
    break
  done

  NODE_PORTS=()
  for ((i=0; i<NODE_COUNT; i++)); do
    NODE_PORTS+=($((BASE_PORT + i)))
  done
  log "将部署 ${NODE_COUNT} 个节点，端口: ${NODE_PORTS[*]}"

  detected_ip="$(detect_ipv4)"
  while :; do
    prompt_value VPS_IPV4 "VPS 公网 IPv4" "$detected_ip"
    if valid_ipv4 "$VPS_IPV4"; then break; fi
    printf '[ERROR] IPv4 地址格式无效，请重新输入。\n' >&2
  done

  UUIDS=()
  printf '请粘贴 %s 行不同的 UUID（直接回车自动生成）：\n' "$NODE_COUNT" >&2
  if ! mapfile -t -n "$NODE_COUNT" -u "$PROMPT_FD" uuid_input; then
    die "无法读取 UUID 输入"
  fi

  if [[ ${#uuid_input[@]} -eq 0 || -z "${uuid_input[0]}" ]]; then
    log "自动生成 UUID"
    for ((i=0; i<NODE_COUNT; i++)); do
      UUIDS+=("$(generate_uuid)")
    done
  else
    for index in "${!uuid_input[@]}"; do
      value="${uuid_input[$index]%$'\r'}"
      if ! valid_uuid "$value"; then
        printf '[ERROR] 第 %s 个 UUID 格式无效，请重新粘贴 %s 行 UUID。\n' "$((index+1))" "$NODE_COUNT" >&2
        exec 3<&"$PROMPT_FD"
        collect_inputs
        return
      fi
      UUIDS+=("$value")
    done
    if (( ${#UUIDS[@]} < NODE_COUNT )); then
      log "补充生成剩余 UUID"
      for ((i=${#UUIDS[@]}; i<NODE_COUNT; i++)); do
        UUIDS+=("$(generate_uuid)")
      done
    fi
  fi

  # 生成SS密码：UUID前三段，去掉横杠
  local temp="${UUIDS[0]}"
  SS_PASSWORD="${temp%%-*}"                      # 第一段
  temp="${temp#*-}"
  SS_PASSWORD="${SS_PASSWORD}${temp%%-*}"        # 第二段
  temp="${temp#*-}"
  SS_PASSWORD="${SS_PASSWORD}${temp%%-*}"        # 第三段
  log "Shadowsocks 密码（UUID 前三段）: ${SS_PASSWORD}"

  if (( NODE_COUNT > 1 )); then
    SHORT_IDS=()
    printf '请输入 %s 个 Short ID（每行一个，直接回车随机选择）：\n' "$((NODE_COUNT - 1))" >&2
    if ! mapfile -t -n "$((NODE_COUNT - 1))" -u "$PROMPT_FD" short_id_input; then
      die "无法读取 Short ID 输入"
    fi

    used_short_ids=""
    if [[ ${#short_id_input[@]} -eq 0 || -z "${short_id_input[0]}" ]]; then
      log "随机选择 Short ID"
      for ((i=0; i<NODE_COUNT-1; i++)); do
        value="$(select_random_short_id "$used_short_ids")"
        SHORT_IDS+=("$value")
        used_short_ids+=" $value"
      done
    else
      for index in "${!short_id_input[@]}"; do
        value="${short_id_input[$index]%$'\r'}"
        if ! valid_short_id "$value"; then
          printf '[ERROR] 第 %s 个 Short ID 格式无效。\n' "$((index+1))" >&2
          exec 3<&"$PROMPT_FD"
          collect_inputs
          return
        fi
        SHORT_IDS+=("$value")
        used_short_ids+=" $value"
      done
      if (( ${#SHORT_IDS[@]} < NODE_COUNT - 1 )); then
        log "补充随机 Short ID"
        for ((i=${#SHORT_IDS[@]}; i<NODE_COUNT-1; i++)); do
          value="$(select_random_short_id "$used_short_ids")"
          SHORT_IDS+=("$value")
          used_short_ids+=" $value"
        done
      fi
    fi

    printf '\n选择 Reality SNI：\n'
    printf '1) pvp.qq.com\n'
    printf '2) lol.qq.com\n'
    printf '3) music.163.com\n'
    printf '4) 随机选择（每个节点随机）\n'
    prompt_value sni_choice "请选择" "4"

    SNI_DOMAINS=()
    case "$sni_choice" in
      1)
        for ((i=0; i<NODE_COUNT-1; i++)); do
          SNI_DOMAINS+=("pvp.qq.com")
        done
        ;;
      2)
        for ((i=0; i<NODE_COUNT-1; i++)); do
          SNI_DOMAINS+=("lol.qq.com")
        done
        ;;
      3)
        for ((i=0; i<NODE_COUNT-1; i++)); do
          SNI_DOMAINS+=("music.163.com")
        done
        ;;
      *)
        log "随机选择 SNI"
        for ((i=0; i<NODE_COUNT-1; i++)); do
          sni="$(select_random_sni)"
          SNI_DOMAINS+=("$sni")
        done
        ;;
    esac

    while :; do
      prompt_value REALITY_PRIVATE_KEY "Reality 私钥（base64url；输入可见）"
      if [[ "$REALITY_PRIVATE_KEY" =~ ^[A-Za-z0-9_-]+$ ]]; then break; fi
      printf '[ERROR] Reality 私钥必须是非空 base64url 字符串，请重新输入。\n' >&2
    done

    while :; do
      prompt_value XHTTP_PATH "XHTTP 路径" "$DEFAULT_XHTTP_PATH"
      if valid_xhttp_path "$XHTTP_PATH"; then break; fi
      printf '[ERROR] XHTTP 路径格式无效，请重新输入。\n' >&2
    done
  else
    SHORT_IDS=()
    SNI_DOMAINS=()
    REALITY_PRIVATE_KEY=""
    XHTTP_PATH=""
  fi

  prompt_value NODE_ALIAS_BASE "节点的基础别名（将自动追加端口号）" "$DEFAULT_NODE_ALIAS"

  NODE_NAMES=()
  for port in "${NODE_PORTS[@]}"; do
    NODE_NAMES+=("${NODE_ALIAS_BASE}-${port}")
  done

  check_node_ports || die "端口检查失败"
}

backup_file() {
  local path="$1"
  local variable="$2"
  [[ -e "$path" ]] || return 0
  local backup="${BACKUP_DIR}/$(basename "$path").original"
  cp -a "$path" "$backup"
  printf -v "$variable" '%s' "$backup"
}

initialize_install_state() {
  (( DRY_RUN )) && return 0
  if [[ -e "$STATE_DIR" ]]; then
    die "${STATE_DIR} already exists; please remove it or use a different deployment"
  fi
  install -d -m 700 "$STATE_DIR" "$BACKUP_DIR"
  dpkg-query -W -f='${binary:Package}\t${db:Status-Status}\n' |
    awk -F '\t' '$2 == "installed" { print $1 }' | sort -u > "$PACKAGE_BASELINE_FILE"
  backup_file "$XRAY_CONFIG_PATH" XRAY_CONFIG_BACKUP
  backup_file "$NGINX_CONF_PATH" NGINX_CONFIG_BACKUP
  disable_stock_nginx_site
  backup_file "$CLIENT_FILE" CLIENT_FILE_BACKUP
  [[ -d "$SITE_DIR" ]] || SITE_DIR_CREATED_BY_TOOL=1
  if ! getent passwd xray >/dev/null; then XRAY_USER_CREATED_BY_TOOL=1; fi
  if ! getent group xray >/dev/null; then XRAY_GROUP_CREATED_BY_TOOL=1; fi
  write_install_state
}

write_install_state() {
  (( DRY_RUN )) && return 0
  local temporary="${INSTALL_STATE_FILE}.tmp"
  {
    printf 'STATE_VERSION=4\n'
    printf 'XRAY_INSTALLER_COMMIT=%q\n' "$XRAY_INSTALL_REF"
    printf 'XRAY_VERSION_RESOLVED=%q\n' "$XRAY_VERSION"
    printf 'XRAY_VERSION_INSTALLED=%q\n' "$XRAY_VERSION_INSTALLED"
    printf 'NGINX_VERSION_INSTALLED=%q\n' "$NGINX_VERSION_INSTALLED"
    printf 'DEBIAN_PACKAGE_VERSIONS=%q\n' "$DEBIAN_PACKAGE_VERSIONS"
    printf 'COMPONENTS_UPDATED_UTC=%q\n' "$COMPONENTS_UPDATED_UTC"
    printf 'XRAY_INSTALLED_BY_TOOL=%q\n' "$XRAY_INSTALLED_BY_TOOL"
    printf 'XRAY_USER_CREATED_BY_TOOL=%q\n' "$XRAY_USER_CREATED_BY_TOOL"
    printf 'XRAY_GROUP_CREATED_BY_TOOL=%q\n' "$XRAY_GROUP_CREATED_BY_TOOL"
    printf 'XRAY_SERVICE_FILE=%q\n' "$XRAY_SERVICE_FILE"
    printf 'XRAY_SERVICE_SHA256=%q\n' "$XRAY_SERVICE_SHA256"
    printf 'XRAY_BINARY_SHA256=%q\n' "$XRAY_BINARY_SHA256"
    printf 'XRAY_SERVICE_USER=%q\n' "$XRAY_SERVICE_USER"
    printf 'XRAY_SERVICE_GROUP=%q\n' "$XRAY_SERVICE_GROUP"
    printf 'XRAY_CONFIG_MODE=%q\n' "$XRAY_CONFIG_MODE"
    printf 'OWNED_PACKAGES=%q\n' "$OWNED_PACKAGES"
    printf 'PACKAGE_BASELINE_FILE=%q\n' "$PACKAGE_BASELINE_FILE"
    printf 'XRAY_CONFIG_BACKUP=%q\n' "$XRAY_CONFIG_BACKUP"
    printf 'NGINX_CONFIG_BACKUP=%q\n' "$NGINX_CONFIG_BACKUP"
    printf 'NGINX_DEFAULT_SITE_TARGET=%q\n' "$NGINX_DEFAULT_SITE_TARGET"
    printf 'NGINX_DEFAULT_SITE_DISABLED_BY_TOOL=%q\n' "$NGINX_DEFAULT_SITE_DISABLED_BY_TOOL"
    printf 'CLIENT_FILE_BACKUP=%q\n' "$CLIENT_FILE_BACKUP"
    printf 'CLIENT_FILE_CREATED_BY_TOOL=%q\n' "$([[ -z "$CLIENT_FILE_BACKUP" ]] && printf 1 || printf 0)"
    printf 'SITE_DIR_CREATED_BY_TOOL=%q\n' "$SITE_DIR_CREATED_BY_TOOL"
    printf 'SITE_INDEX_CREATED_BY_TOOL=%q\n' "$SITE_INDEX_CREATED_BY_TOOL"
    printf 'SITE_INDEX_SHA256=%q\n' "$SITE_INDEX_SHA256"
    printf 'XRAY_CONFIG_SHA256=%q\n' "$XRAY_CONFIG_SHA256"
    printf 'NGINX_CONFIG_SHA256=%q\n' "$NGINX_CONFIG_SHA256"
    printf 'CLIENT_FILE_SHA256=%q\n' "$CLIENT_FILE_SHA256"
  } > "$temporary"
  chmod 600 "$temporary"
  mv -f "$temporary" "$INSTALL_STATE_FILE"
}

install_packages() {
  (( DRY_RUN )) && return 0
  log "installing Debian dependencies"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends "${DEBIAN_PACKAGES[@]}"
  local installed_packages
  installed_packages="$(dpkg-query -W -f='${binary:Package}\t${db:Status-Status}\n' |
    awk -F '\t' '$2 == "installed" { print $1 }' | sort -u)"
  OWNED_PACKAGES="$(comm -13 "${PACKAGE_BASELINE_FILE}" <(printf '%s\n' "$installed_packages" | sed '/^$/d'))"
  disable_stock_nginx_site
  write_install_state
}

require_fresh_xray() {
  (( DRY_RUN )) && return 0
  if [[ -e /usr/local/bin/xray || -d /usr/local/etc/xray ]] ||
     systemctl list-unit-files --no-legend xray.service 2>/dev/null | grep -q '^xray.service'; then
    die "an Xray installation already exists; refusing to overwrite it"
  fi
}

install_xray() {
  (( DRY_RUN )) && return 0
  log "installing official Xray-core ${XRAY_VERSION}"
  local installer
  installer="$(mktemp)"
  XRAY_INSTALLED_BY_TOOL=1
  write_install_state
  curl -fsSL "https://raw.githubusercontent.com/XTLS/Xray-install/${XRAY_INSTALL_REF}/install-release.sh" -o "$installer"
  if ! bash "$installer" install --version "$XRAY_VERSION"; then
    rm -f "$installer"
    die "official Xray installer failed"
  fi
  rm -f "$installer"
  [[ -x /usr/local/bin/xray ]] || die "Xray installation did not produce /usr/local/bin/xray"
  [[ -f /usr/local/bin/xray && ! -L /usr/local/bin/xray ]] || die "Xray binary is not a regular file"
  XRAY_BINARY_SHA256="$(sha256sum /usr/local/bin/xray | awk '{print $1}')"
  XRAY_VERSION_INSTALLED="$(/usr/local/bin/xray version 2>/dev/null | sed -n '1p')"
  if [[ -f "$XRAY_CONFIG_PATH" && ! -L "$XRAY_CONFIG_PATH" ]]; then
    XRAY_CONFIG_SHA256="$(sha256sum "$XRAY_CONFIG_PATH" | awk '{print $1}')"
  fi
  XRAY_SERVICE_FILE="$(systemctl show --property=FragmentPath --value xray.service 2>/dev/null || true)"
  if [[ -n "$XRAY_SERVICE_FILE" && -f "$XRAY_SERVICE_FILE" && ! -L "$XRAY_SERVICE_FILE" ]]; then
    XRAY_SERVICE_SHA256="$(sha256sum "$XRAY_SERVICE_FILE" | awk '{print $1}')"
  fi
  write_install_state
}

derive_public_key() {
  if (( DRY_RUN )); then
    PUBLIC_KEY="${XHTTP_TEST_PUBLIC_KEY:-test-public-key}"
    return 0
  fi

  if [[ -z "$REALITY_PRIVATE_KEY" ]]; then
    PUBLIC_KEY=""
    return 0
  fi

  local output
  while :; do
    if output="$(/usr/local/bin/xray x25519 -i "$REALITY_PRIVATE_KEY" 2>&1)"; then
      PUBLIC_KEY="$(awk -F': *' 'tolower($1) ~ /publickey/ { print $2; exit }' <<< "$output")"
      if [[ -n "$PUBLIC_KEY" ]]; then return 0; fi
    fi
    printf '[ERROR] Xray 拒绝了 Reality 私钥，请重新输入。\n' >&2
    prompt_value REALITY_PRIVATE_KEY "Reality 私钥（base64url；输入可见）"
    [[ "$REALITY_PRIVATE_KEY" =~ ^[A-Za-z0-9_-]+$ ]] ||
      printf '[ERROR] Reality 私钥必须是非空 base64url 字符串，请重新输入。\n' >&2
  done
}

ensure_state_dirs() {
  install -d -m 700 "$STATE_DIR" "$CERT_DIR" "$CLIENT_DIR"
  install -d -m 755 "$SITE_DIR"
  install -d -m 700 "$STATE_DIR/backups"
  if (( ! DRY_RUN )); then
    install -d -m 755 "$(dirname "$XRAY_CONFIG_PATH")" "$(dirname "$NGINX_CONF_PATH")"
  fi
}

check_certificate_expiry() {
  local cert_file="$1"
  [[ -f "$cert_file" ]] || return 1
  local expiry_date
  expiry_date="$(openssl x509 -in "$cert_file" -noout -enddate 2>/dev/null | cut -d= -f2)" || return 1
  local expiry_epoch
  expiry_epoch="$(date -d "$expiry_date" +%s 2>/dev/null)" || return 1
  local now_epoch
  now_epoch="$(date +%s)"
  local days_left=$(( (expiry_epoch - now_epoch) / 86400 ))
  (( days_left > 30 ))
}

generate_self_signed_certificate() {
  log "generating self-signed certificate (valid for 365 days)"
  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$KEY_FILE" \
    -out "$CERT_FILE" \
    -days 365 \
    -subj "/CN=localhost/O=xhttp-real-deploy" \
    2>/dev/null || die "failed to generate self-signed certificate"
  chmod 600 "$CERT_FILE" "$KEY_FILE"
  log "self-signed certificate generated successfully"
}

prepare_certificate() {
  if (( DRY_RUN )); then
    printf '%s\n' 'dry-run certificate' > "$CERT_FILE"
    printf '%s\n' 'dry-run private key' > "$KEY_FILE"
    chmod 600 "$CERT_FILE" "$KEY_FILE"
    return 0
  fi

  if check_certificate_expiry "$CERT_FILE"; then
    log "existing certificate is valid, reusing it"
    return 0
  fi

  if [[ -f "$CERT_FILE" ]]; then
    log "existing certificate is expired or invalid, regenerating"
  fi

  generate_self_signed_certificate
}

write_site() {
  [[ -e "$SITE_DIR/index.html" ]] && return 0
  cat > "$SITE_DIR/index.html" <<EOF
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>Welcome</title></head>
<body><h1>Welcome</h1><p>This site is served by the origin.</p></body></html>
EOF
  chmod 644 "$SITE_DIR/index.html"
  SITE_INDEX_CREATED_BY_TOOL=1
  SITE_INDEX_SHA256="$(sha256sum "$SITE_DIR/index.html" | awk '{print $1}')"
  write_install_state
}

render_xray_config() {
  local inbounds inbound port uuid fingerprint sni short_id fallback_port i
  inbounds='[]'

  # First port: Shadowsocks
  port="${NODE_PORTS[0]}"
  uuid="${UUIDS[0]}"
  inbound="$(jq -cn \
    --arg password "$SS_PASSWORD" \
    --argjson port "$port" \
    --arg method "$SS_METHOD" \
    '{listen:"0.0.0.0", port:$port, protocol:"shadowsocks", settings:{method:$method, password:$password, level:0}, sniffing:{enabled:true, destOverride:["http","tls","quic"], metadataOnly:false, routeOnly:true}}')"
  inbounds="$(jq -cn --argjson all "$inbounds" --argjson one "$inbound" '$all + [$one]')"

  # Remaining ports: VLESS + Reality + XHTTP
  for ((i=1; i<NODE_COUNT; i++)); do
    port="${NODE_PORTS[$i]}"
    uuid="${UUIDS[$i]}"
    short_id="${SHORT_IDS[$((i-1))]}"
    sni="${SNI_DOMAINS[$((i-1))]}"
    fallback_port=$((port + 10000))

    # Determine fingerprint based on port parity
    if (( port % 2 == 0 )); then
      fingerprint="safari"
    else
      fingerprint="firefox"
    fi

    inbound="$(jq -cn \
      --arg id "$uuid" \
      --argjson port "$port" \
      --arg target "127.0.0.1:${fallback_port}" \
      --arg sni "$sni" \
      --arg private_key "$REALITY_PRIVATE_KEY" \
      --arg short_id "$short_id" \
      --arg path "$XHTTP_PATH" \
      --arg fingerprint "$fingerprint" \
      '{listen:"0.0.0.0", port:$port, protocol:"vless", settings:{clients:[{id:$id, level:0}], decryption:"none"}, streamSettings:{network:"xhttp", security:"reality", realitySettings:{show:false, target:$target, xver:0, serverNames:[$sni], privateKey:$private_key, shortIds:[$short_id], fingerprint:$fingerprint}, xhttpSettings:{host:"", path:$path, mode:"auto"}}, sniffing:{enabled:true, destOverride:["http","tls","quic"], metadataOnly:false, routeOnly:true}}')"
    inbounds="$(jq -cn --argjson all "$inbounds" --argjson one "$inbound" '$all + [$one]')"
  done

  jq -n \
    --argjson inbounds "$inbounds" \
    '{log:{loglevel:"warning"}, inbounds:$inbounds, outbounds:[{protocol:"freedom",tag:"direct"}]}' \
    > "$XRAY_CONFIG_PATH"
  chmod 600 "$XRAY_CONFIG_PATH"
  XRAY_CONFIG_SHA256="$(sha256sum "$XRAY_CONFIG_PATH" | awk '{print $1}')"
}

configure_xray_config_permissions() {
  local service_user service_group
  (( DRY_RUN )) && return 0

  service_user="$(systemctl show --property=User --value xray 2>/dev/null || true)"
  service_group="$(systemctl show --property=Group --value xray 2>/dev/null || true)"
  service_user="${service_user:-root}"
  if [[ -z "$service_group" ]]; then
    service_group="$(id -gn "$service_user" 2>/dev/null || true)"
  fi
  [[ -n "$service_group" ]] || die "could not determine the Xray service group"
  getent passwd "$service_user" >/dev/null || die "Xray service user does not exist: $service_user"
  getent group "$service_group" >/dev/null || die "Xray service group does not exist: $service_group"

  XRAY_SERVICE_USER="$service_user"
  XRAY_SERVICE_GROUP="$service_group"
  if [[ "$service_user" == root ]]; then
    chown root:root "$XRAY_CONFIG_PATH"
    chmod 600 "$XRAY_CONFIG_PATH"
    XRAY_CONFIG_MODE=600
  else
    chown root:"$service_group" "$XRAY_CONFIG_PATH"
    chmod 640 "$XRAY_CONFIG_PATH"
    XRAY_CONFIG_MODE=640
  fi
  [[ -r "$XRAY_CONFIG_PATH" ]] || die "Xray configuration is not readable by root"
  if [[ "$service_user" != root ]]; then
    command -v runuser >/dev/null 2>&1 || die "runuser is required to validate the Xray service account"
    runuser -u "$service_user" -- test -r "$XRAY_CONFIG_PATH" ||
      die "Xray service user cannot read $XRAY_CONFIG_PATH"
  fi
}

render_nginx_config() {
  local port fallback_port sni i
  : > "$NGINX_CONF_PATH"

  # Generate fallback servers for Reality nodes (ports 2-N)
  for ((i=1; i<NODE_COUNT; i++)); do
    port="${NODE_PORTS[$i]}"
    fallback_port=$((port + 10000))
    sni="${SNI_DOMAINS[$((i-1))]}"

    cat >> "$NGINX_CONF_PATH" <<EOF
server {
    listen 127.0.0.1:${fallback_port} ssl;
    server_name ${sni};

    access_log off;
    ssl_certificate ${CERT_FILE};
    ssl_certificate_key ${KEY_FILE};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_tickets off;
    client_max_body_size 0;
    client_body_timeout 1h;

    location / {
        root ${SITE_DIR};
        index index.html;
        try_files \$uri \$uri/ /index.html;
    }
}

EOF
  done

  chmod 644 "$NGINX_CONF_PATH"
  NGINX_CONFIG_SHA256="$(sha256sum "$NGINX_CONF_PATH" | awk '{print $1}')"
}

url_encode() {
  jq -rn --arg value "$1" '$value | @uri'
}

render_client_links() {
  local port uuid name encoded_path xmux extra encoded_extra fingerprint i
  local sni encoded_sni encoded_pubkey encoded_short_id ss_link

  encoded_path="$(url_encode "$XHTTP_PATH")"
  xmux='{"maxConcurrency":"16-32","maxConnections":0,"cMaxReuseTimes":0,"hMaxRequestTimes":"600-900","hMaxReusableSecs":"1800-3000","hKeepAlivePeriod":0}'
  extra="$(jq -cn --argjson xmux "$xmux" '{xmux:$xmux}')"
  encoded_extra="$(url_encode "$extra")"

  : > "$CLIENT_FILE"

  # First port: Shadowsocks
  port="${NODE_PORTS[0]}"
  name="${NODE_NAMES[0]}"
  ss_link="ss://$(printf '%s:%s' "$SS_METHOD" "$SS_PASSWORD" | base64 -w 0)@${VPS_IPV4}:${port}#$(url_encode "$name")"
  printf '%s\n' "$ss_link" >> "$CLIENT_FILE"

  # Remaining ports: VLESS + Reality + XHTTP
  if (( NODE_COUNT > 1 )); then
    encoded_pubkey="$(url_encode "$PUBLIC_KEY")"

    for ((i=1; i<NODE_COUNT; i++)); do
      port="${NODE_PORTS[$i]}"
      uuid="${UUIDS[$i]}"
      name="${NODE_NAMES[$i]}"
      sni="${SNI_DOMAINS[$((i-1))]}"
      encoded_sni="$(url_encode "$sni")"
      encoded_short_id="$(url_encode "${SHORT_IDS[$((i-1))]}")"

      if (( port % 2 == 0 )); then
        fingerprint="safari"
      else
        fingerprint="firefox"
      fi

      printf 'vless://%s@%s:%s?encryption=none&security=reality&sni=%s&fp=%s&pbk=%s&sid=%s&type=xhttp&path=%s&mode=auto&extra=%s#%s\n' \
        "$uuid" "$VPS_IPV4" "$port" \
        "$encoded_sni" "$fingerprint" "$encoded_pubkey" "$encoded_short_id" \
        "$encoded_path" "$encoded_extra" "$(url_encode "$name")" >> "$CLIENT_FILE"
    done
  fi

  chmod 600 "$CLIENT_FILE"
  CLIENT_FILE_SHA256="$(sha256sum "$CLIENT_FILE" | awk '{print $1}')"
}

write_state() {
  local state_file="${STATE_DIR}/config.env"
  local temporary="${state_file}.tmp"
  local i port_list uuid_list

  port_list=""
  for port in "${NODE_PORTS[@]}"; do
    port_list+="${port} "
  done

  {
    printf 'NODE_COUNT=%q\n' "$NODE_COUNT"
    printf 'BASE_PORT=%q\n' "$BASE_PORT"
    printf 'NODE_PORTS=%q\n' "${port_list% }"
    printf 'VPS_IPV4=%q\n' "$VPS_IPV4"
    printf 'SS_PASSWORD=%q\n' "$SS_PASSWORD"

    for ((i=0; i<NODE_COUNT; i++)); do
      printf 'UUID_%s=%q\n' "$i" "${UUIDS[$i]}"
    done

    if [[ -n "$REALITY_PRIVATE_KEY" ]]; then
      printf 'REALITY_PRIVATE_KEY=%q\n' "$REALITY_PRIVATE_KEY"
      printf 'REALITY_PUBLIC_KEY=%q\n' "$PUBLIC_KEY"
    fi

    for ((i=0; i<${#SHORT_IDS[@]}; i++)); do
      printf 'SHORT_ID_%s=%q\n' "$i" "${SHORT_IDS[$i]}"
    done

    for ((i=0; i<${#SNI_DOMAINS[@]}; i++)); do
      printf 'SNI_DOMAIN_%s=%q\n' "$i" "${SNI_DOMAINS[$i]}"
    done

    if [[ -n "$XHTTP_PATH" ]]; then
      printf 'XHTTP_PATH=%q\n' "$XHTTP_PATH"
    fi

    printf 'NODE_ALIAS_BASE=%q\n' "$NODE_ALIAS_BASE"

    for ((i=0; i<NODE_COUNT; i++)); do
      printf 'NODE_NAME_%s=%q\n' "$i" "${NODE_NAMES[$i]}"
    done

    printf 'CERT_FILE=%q\n' "$CERT_FILE"
    printf 'KEY_FILE=%q\n' "$KEY_FILE"
  } > "$temporary"
  chmod 600 "$temporary"
  mv -f "$temporary" "$state_file"
}

validate_nginx_config_loaded() {
  local nginx_dump
  nginx_dump="$(nginx -T 2>&1)" || {
    printf '[ERROR] Nginx configuration dump failed; existing Nginx/OpenResty configuration is not usable.\n%s\n' \
      "$nginx_dump" >&2
    return 1
  }
  if [[ "$nginx_dump" != *"configuration file ${NGINX_CONF_PATH}"* ]]; then
    printf '[ERROR] the active Nginx configuration does not load %s\n' "$NGINX_CONF_PATH" >&2
    return 1
  fi
}

validate_services() {
  (( DRY_RUN )) && return 0
  if (( NODE_COUNT > 1 )); then
    nginx -t
    validate_nginx_config_loaded || die "the active Nginx service does not load the tool configuration"
  fi
  /usr/local/bin/xray run -test -config "$XRAY_CONFIG_PATH"
  if [[ "$XRAY_SERVICE_USER" != root ]]; then
    runuser -u "$XRAY_SERVICE_USER" -- /usr/local/bin/xray run -test -config "$XRAY_CONFIG_PATH" ||
      die "Xray configuration cannot be parsed by the service account"
  fi
}

report_service_failure() {
  local service="$1"
  printf '[ERROR] %s service diagnostics:\n' "$service" >&2
  systemctl status "$service" --no-pager -l >&2 || true
  if command -v journalctl >/dev/null 2>&1; then
    journalctl -u "$service" -b -n 50 --no-pager >&2 || true
  fi
  if command -v ss >/dev/null 2>&1; then
    ss -ltnp >&2 || true
  fi
}

start_services() {
  (( DRY_RUN )) && return 0
  systemctl daemon-reload

  if (( NODE_COUNT > 1 )); then
    if ! systemctl enable nginx >/dev/null; then
      report_service_failure nginx
      die "could not enable nginx.service"
    fi
    if ! systemctl restart nginx; then
      report_service_failure nginx
      die "nginx failed to restart"
    fi
    if ! systemctl is-active --quiet nginx; then
      report_service_failure nginx
      die "nginx did not become active"
    fi
  fi

  if ! systemctl enable xray >/dev/null; then
    report_service_failure xray
    die "could not enable xray.service"
  fi
  if ! systemctl restart xray; then
    report_service_failure xray
    die "xray failed to restart"
  fi
  if ! systemctl is-active --quiet xray; then
    report_service_failure xray
    die "xray did not become active"
  fi
}

setup_certificate_renewal() {
  (( DRY_RUN )) && return 0
  (( NODE_COUNT <= 1 )) && return 0

  log "setting up certificate auto-renewal"

  local renewal_script="/usr/local/bin/xhttp-real-renew-cert.sh"
  cat > "$renewal_script" << 'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

CERT_FILE="%%CERT_FILE%%"
KEY_FILE="%%KEY_FILE%%"
STATE_DIR="%%STATE_DIR%%"

check_certificate_expiry() {
  local cert_file="$1"
  [[ -f "$cert_file" ]] || return 1
  local expiry_date
  expiry_date="$(openssl x509 -in "$cert_file" -noout -enddate 2>/dev/null | cut -d= -f2)" || return 1
  local expiry_epoch
  expiry_epoch="$(date -d "$expiry_date" +%s 2>/dev/null)" || return 1
  local now_epoch
  now_epoch="$(date +%s)"
  local days_left=$(( (expiry_epoch - now_epoch) / 86400 ))
  (( days_left > 30 ))
}

if ! check_certificate_expiry "$CERT_FILE"; then
  logger -t xhttp-real-deploy "Certificate expiring soon, regenerating"
  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$KEY_FILE" \
    -out "$CERT_FILE" \
    -days 365 \
    -subj "/CN=localhost/O=xhttp-real-deploy" \
    2>/dev/null || exit 1
  chmod 600 "$CERT_FILE" "$KEY_FILE"
  systemctl reload nginx
  logger -t xhttp-real-deploy "Certificate renewed successfully"
fi
EOF

  sed -i "s|%%CERT_FILE%%|${CERT_FILE}|g" "$renewal_script"
  sed -i "s|%%KEY_FILE%%|${KEY_FILE}|g" "$renewal_script"
  sed -i "s|%%STATE_DIR%%|${STATE_DIR}|g" "$renewal_script"
  chmod 755 "$renewal_script"

  local cron_file="/etc/cron.daily/xhttp-real-cert-renewal"
  cat > "$cron_file" << EOF
#!/bin/sh
# xhttp-real-deploy certificate auto-renewal
$renewal_script
EOF
  chmod 755 "$cron_file"

  log "certificate will be checked daily and renewed 30 days before expiry"
}

print_summary() {
  local port_list i
  port_list=""
  for port in "${NODE_PORTS[@]}"; do
    port_list+="${port} "
  done

  printf '\n部署完成。\n'
  printf '客户端链接：%s\n' "$CLIENT_FILE"
  printf 'Xray 配置： %s\n' "$XRAY_CONFIG_PATH"
  printf '状态文件：  %s\n' "${STATE_DIR}/config.env"
  printf '\n请在 VPS / 云厂商防火墙放行 TCP 入站端口：%s\n' "${port_list% }"
  printf '\n节点配置：\n'
  printf '  端口 %s：Shadowsocks (%s)\n' "${NODE_PORTS[0]}" "$SS_METHOD"
  for ((i=1; i<NODE_COUNT; i++)); do
    printf '  端口 %s：VLESS+Reality+XHTTP (SNI: %s)\n' "${NODE_PORTS[$i]}" "${SNI_DOMAINS[$((i-1))]}"
  done
  printf '\n'
  cat "$CLIENT_FILE"
}

main() {
  parse_args "$@"
  init_paths
  require_debian_root
  open_prompt_fd
  if (( ! DRY_RUN )); then
    require_fresh_xray
  fi
  collect_inputs

  if (( ! DRY_RUN )); then
    initialize_install_state
    install_packages
    resolve_latest_versions || die "could not resolve latest official component versions"
    install_xray
  fi

  derive_public_key
  ensure_state_dirs
  if (( NODE_COUNT > 1 )); then
    prepare_certificate
  fi
  if (( ! DRY_RUN )); then
    check_node_ports || die "端口检查失败"
  fi
  write_site
  render_xray_config
  configure_xray_config_permissions
  if (( NODE_COUNT > 1 )); then
    render_nginx_config
  fi
  render_client_links
  if (( ! DRY_RUN )); then
    NGINX_VERSION_INSTALLED="$(nginx -v 2>&1)"
    DEBIAN_PACKAGE_VERSIONS="$(dpkg-query -W -f='${binary:Package}=${Version}\n' "${DEBIAN_PACKAGES[@]}" | sort)"
    COMPONENTS_UPDATED_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  fi
  write_state
  write_install_state
  validate_services
  start_services
  setup_certificate_renewal
  print_summary
}

if [[ "${XHTTP_LIBRARY_MODE:-0}" != 1 ]]; then
  main "$@"
fi
