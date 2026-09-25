#!/usr/bin/env bash
set -Eeuo pipefail

# Docker installer for VLESS + XHTTP + REALITY (Debian/Ubuntu).
# Every option is optional; environment variables with the same names work too.

INSTALL_DIR="${INSTALL_DIR:-/opt/xray-docker}"
BASE_URL="${BASE_URL:-https://raw.githubusercontent.com/flying-develop/tool/master}"
SERVER_ADDRESS="${SERVER_ADDRESS:-}"
VLESS_PORT="${VLESS_PORT:-443}"
SNI="${SNI:-www.dropbox.com}"
DEST="${DEST:-}"
XHTTP_PATH="${XHTTP_PATH:-/}"
DEFAULT_USER="${DEFAULT_USER:-default}"
XRAY_VERSION="${XRAY_VERSION:-v26.3.27}"

usage() {
    cat <<'EOF'
Usage: install.sh [options]
  --server-address IP_OR_DOMAIN
  --port PORT
  --sni DOMAIN
  --dest HOST:PORT
  --path /PATH
  --default-user NAME
  --xray-version VERSION
  -h, --help

Все параметры необязательны. Их также можно передать через переменные:
SERVER_ADDRESS, VLESS_PORT, SNI, DEST, XHTTP_PATH, DEFAULT_USER, XRAY_VERSION.
EOF
}

while (($# > 0)); do
    case "$1" in
        --server-address) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; SERVER_ADDRESS="$2"; shift 2 ;;
        --port) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; VLESS_PORT="$2"; shift 2 ;;
        --sni) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; SNI="$2"; shift 2 ;;
        --dest) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; DEST="$2"; shift 2 ;;
        --path) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; XHTTP_PATH="$2"; shift 2 ;;
        --default-user) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; DEFAULT_USER="$2"; shift 2 ;;
        --xray-version) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; XRAY_VERSION="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Неизвестный параметр: $1" >&2; usage >&2; exit 2 ;;
    esac
done

DEST="${DEST:-${SNI}:443}"

green='\033[1;32m'
red='\033[1;31m'
reset='\033[0m'
log() { echo -e "${green}[+]${reset} $*"; }
fatal() { echo -e "${red}[ERROR]${reset} $*" >&2; exit 1; }

[[ "${EUID}" -eq 0 ]] || fatal "Запусти скрипт от root"
command -v apt >/dev/null 2>&1 || fatal "Поддерживаются Debian/Ubuntu с apt"
[[ "${VLESS_PORT}" =~ ^[0-9]{1,5}$ ]] || fatal "PORT должен быть числом"
((10#${VLESS_PORT} >= 1 && 10#${VLESS_PORT} <= 65535)) || fatal "PORT вне диапазона 1..65535"
VLESS_PORT="$((10#${VLESS_PORT}))"
[[ "${DEFAULT_USER}" =~ ^[a-zA-Z0-9_-]{1,64}$ ]] || fatal "Некорректный DEFAULT_USER"
[[ "${SNI}" =~ ^[a-zA-Z0-9._:-]+$ ]] || fatal "Некорректный SNI"
[[ "${DEST}" =~ ^[^[:space:]]+:[0-9]+$ ]] || fatal "DEST должен иметь формат host:port"
[[ "${XHTTP_PATH}" =~ ^/[a-zA-Z0-9._~!/@%+=,-]*$ ]] || fatal "Некорректный PATH"
[[ "${XRAY_VERSION}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fatal "XRAY_VERSION должен иметь формат v26.3.27"

log "Подготовка Docker"
apt update -y
DEBIAN_FRONTEND=noninteractive apt install -y ca-certificates curl

if ! command -v docker >/dev/null 2>&1; then
    docker_installer="$(mktemp)"
    curl -fsSL https://get.docker.com -o "${docker_installer}"
    sh "${docker_installer}"
    rm -f "${docker_installer}"
fi
docker compose version >/dev/null 2>&1 || fatal "Не найден Docker Compose plugin"

if [[ -z "${SERVER_ADDRESS}" ]]; then
    SERVER_ADDRESS="$(curl -4fsS --max-time 5 https://icanhazip.com | tr -d '[:space:]')"
fi
[[ "${SERVER_ADDRESS}" =~ ^[a-zA-Z0-9._:-]+$ ]] || fatal "Некорректный SERVER_ADDRESS"

log "Загрузка контейнерных файлов"
mkdir -p "${INSTALL_DIR}/docker"

download() {
    local source="$1" destination="$2" mode="${3:-0644}" temporary
    temporary="$(mktemp "${INSTALL_DIR}/.download.XXXXXX")"
    if ! curl -fsSL "${BASE_URL}/${source}" -o "${temporary}"; then
        rm -f "${temporary}"
        fatal "Не удалось скачать ${source}"
    fi
    chmod "${mode}" "${temporary}"
    mv "${temporary}" "${destination}"
}

download Dockerfile "${INSTALL_DIR}/Dockerfile"
download compose.yaml "${INSTALL_DIR}/compose.yaml"
download .dockerignore "${INSTALL_DIR}/.dockerignore"
download docker/xray-config "${INSTALL_DIR}/docker/xray-config" 0755
download docker/entrypoint "${INSTALL_DIR}/docker/entrypoint" 0755
download docker/tool "${INSTALL_DIR}/docker/tool" 0755

env_tmp="$(mktemp "${INSTALL_DIR}/.env.XXXXXX")"
cat >"${env_tmp}" <<EOF
SERVER_ADDRESS=${SERVER_ADDRESS}
VLESS_PORT=${VLESS_PORT}
SNI=${SNI}
DEST=${DEST}
XHTTP_PATH=${XHTTP_PATH}
DEFAULT_USER=${DEFAULT_USER}
XRAY_VERSION=${XRAY_VERSION}
EOF
chmod 600 "${env_tmp}"
mv "${env_tmp}" "${INSTALL_DIR}/.env"

cat >/usr/local/bin/tool <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "\${1:-}" == "logs" ]]; then
    exec docker compose -f "${INSTALL_DIR}/compose.yaml" logs --tail=100 xray
fi
exec docker compose -f "${INSTALL_DIR}/compose.yaml" exec -T xray tool "\$@"
EOF
chmod 755 /usr/local/bin/tool

log "Сборка и запуск Xray"
docker compose -f "${INSTALL_DIR}/compose.yaml" up -d --build

log "Проверка контейнера"
for attempt in {1..30}; do
    if docker compose -f "${INSTALL_DIR}/compose.yaml" exec -T xray tool status >/dev/null 2>&1; then
        echo
        echo -e "${green}[OK] Xray запущен в Docker${reset}"
        echo "Настройки: ${INSTALL_DIR}/.env"
        echo "Команды: tool ${DEFAULT_USER} | tool add phone | tool list | tool logs"
        echo
        tool "${DEFAULT_USER}"
        exit 0
    fi
    sleep 1
done

docker compose -f "${INSTALL_DIR}/compose.yaml" logs --tail=100 xray >&2 || true
fatal "Контейнер Xray не прошёл проверку запуска"
