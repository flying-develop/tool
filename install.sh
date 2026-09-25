#!/usr/bin/env bash
set -Eeuo pipefail

# VLESS + XHTTP + REALITY installer
# Debian / Ubuntu
#
# Optional environment variables:
#   SNI=www.dropbox.com
#   DEST=www.dropbox.com:443
#   XHTTP_PATH=/
#   SERVER_ADDRESS=1.2.3.4
#   VLESS_PORT=443
#   DEFAULT_USER=default
#   ENABLE_BBR=1
#   ENABLE_AUTOUPDATE=1

XRAY_DIR="/usr/local/etc/xray"
USERS_DIR="${XRAY_DIR}/users"
CONFIG="${XRAY_DIR}/config.json"
SERVER_STATE="${XRAY_DIR}/server.json"
TOOL_BIN="/usr/local/bin/tool"
BBR_FILE="/etc/sysctl.d/99-xray-bbr.conf"

SNI="${SNI:-www.dropbox.com}"
DEST="${DEST:-${SNI}:443}"
XHTTP_PATH="${XHTTP_PATH:-/}"
VLESS_PORT="${VLESS_PORT:-443}"
DEFAULT_USER="${DEFAULT_USER:-default}"
ENABLE_BBR="${ENABLE_BBR:-1}"
ENABLE_AUTOUPDATE="${ENABLE_AUTOUPDATE:-1}"

green='\033[1;32m'
yellow='\033[1;33m'
red='\033[1;31m'
reset='\033[0m'

log()   { echo -e "${green}[+]${reset} $*"; }
warn()  { echo -e "${yellow}[!]${reset} $*"; }
fatal() { echo -e "${red}[ERROR]${reset} $*" >&2; exit 1; }

validate_user_name() {
    local name="$1"

    [[ "${name}" =~ ^[a-zA-Z0-9_-]{1,64}$ ]] || \
        fatal "DEFAULT_USER: только a-z A-Z 0-9 _ -, максимум 64 символа"

    case "${name}" in
        add|del|delete|remove|list|ls|json|sync|status|logs|help|-h|--help)
            fatal "DEFAULT_USER не может совпадать с командой tool: ${name}"
            ;;
    esac
}

validate_port() {
    local value="$1" name="$2"

    [[ "${value}" =~ ^[0-9]{1,5}$ ]] || fatal "${name} должен быть числом от 1 до 65535"
    ((10#${value} >= 1 && 10#${value} <= 65535)) || \
        fatal "${name} должен быть в диапазоне 1..65535"
}

[[ "${EUID}" -eq 0 ]] || fatal "Запусти скрипт от root."

command -v apt >/dev/null 2>&1 || fatal "Поддерживаются Debian/Ubuntu с apt."

validate_port "${VLESS_PORT}" "VLESS_PORT"
VLESS_PORT="$((10#${VLESS_PORT}))"
validate_user_name "${DEFAULT_USER}"
[[ "${ENABLE_BBR}" =~ ^[01]$ ]] || fatal "ENABLE_BBR должен быть 0 или 1"
[[ "${ENABLE_AUTOUPDATE}" =~ ^[01]$ ]] || fatal "ENABLE_AUTOUPDATE должен быть 0 или 1"
[[ "${XHTTP_PATH}" == /* ]] || fatal "XHTTP_PATH должен начинаться с /"
[[ "${SNI}" =~ ^[a-zA-Z0-9._:-]+$ ]] || \
    fatal "SNI содержит недопустимые символы"
[[ "${DEST}" =~ ^[^[:space:]]+:[0-9]+$ ]] || \
    fatal "DEST должен иметь формат host:port"
validate_port "${DEST##*:}" "Порт DEST"
DEST="${DEST%:*}:$((10#${DEST##*:}))"
if [[ -n "${SERVER_ADDRESS:-}" ]]; then
    [[ "${SERVER_ADDRESS}" =~ ^[a-zA-Z0-9._:-]+$ ]] || \
        fatal "SERVER_ADDRESS содержит недопустимые символы"
fi
if [[ -e "${TOOL_BIN}" ]] && \
    ! grep -qF '# Managed by flying-develop/tool' "${TOOL_BIN}" && \
    ! grep -qF 'show_vless_link()' "${TOOL_BIN}"; then
    fatal "${TOOL_BIN} уже существует и не принадлежит этому проекту"
fi
if [[ "${ENABLE_AUTOUPDATE}" == "1" && -e /etc/cron.d/xray-update ]] && \
    ! grep -qxF '# Managed by flying-develop/tool' /etc/cron.d/xray-update; then
    fatal "/etc/cron.d/xray-update уже существует и не принадлежит установщику"
fi

log "Установка VLESS + XHTTP + REALITY"

apt update -y
DEBIAN_FRONTEND=noninteractive apt install -y curl jq qrencode openssl ca-certificates cron

if [[ "${ENABLE_BBR}" == "1" ]]; then
    log "Проверка BBR"

    current_cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"

    if [[ "${current_cc}" == "bbr" ]]; then
        log "BBR уже включён"
    else
        if [[ -e "${BBR_FILE}" ]] && \
            ! grep -qxF '# Managed by flying-develop/tool' "${BBR_FILE}"; then
            warn "${BBR_FILE} уже существует и не принадлежит установщику; файл не изменён"
        else
            cat >"${BBR_FILE}" <<'EOF'
# Managed by flying-develop/tool
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
        fi
        sysctl --system >/dev/null || warn "Не удалось применить sysctl автоматически"
        current_cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"

        if [[ "${current_cc}" == "bbr" ]]; then
            log "BBR включён"
        else
            warn "BBR пока не активен. Проверь поддержку ядра."
        fi
    fi
fi

log "Установка/обновление Xray-core"
bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

command -v xray >/dev/null 2>&1 || fatal "Xray не найден после установки"

mkdir -p "${USERS_DIR}"
chmod 700 "${XRAY_DIR}" "${USERS_DIR}"

if [[ -f "${SERVER_STATE}" ]] && jq -e '
    (.reality.private_key | type == "string" and length > 0) and
    (.reality.public_key | type == "string" and length > 0)
    ' \
    "${SERVER_STATE}" >/dev/null 2>&1; then
    warn "${SERVER_STATE} уже существует — серверные ключи будут сохранены"
    PRIVATE_KEY="$(jq -r '.reality.private_key // empty' "${SERVER_STATE}")"
    PUBLIC_KEY="$(jq -r '.reality.public_key // empty' "${SERVER_STATE}")"
else
    log "Генерация REALITY X25519 key pair"

    X25519_OUTPUT="$(xray x25519)"

    PRIVATE_KEY="$(printf '%s\n' "${X25519_OUTPUT}" \
        | sed -nE 's/^PrivateKey:[[:space:]]*(.+)$/\1/p' \
        | head -n1)"

    # New Xray: "Password (PublicKey): ..."
    # Older Xray: "PublicKey: ..."
    PUBLIC_KEY="$(printf '%s\n' "${X25519_OUTPUT}" \
        | sed -nE \
            -e 's/^Password \(PublicKey\):[[:space:]]*(.+)$/\1/p' \
            -e 's/^Password:[[:space:]]*(.+)$/\1/p' \
            -e 's/^PublicKey:[[:space:]]*(.+)$/\1/p' \
        | head -n1)"

fi

[[ -n "${PRIVATE_KEY}" ]] || fatal "Не удалось получить REALITY private key"

X25519_DERIVED="$(xray x25519 -i "${PRIVATE_KEY}")" || \
    fatal "Сохранённый REALITY private key некорректен"
DERIVED_PUBLIC_KEY="$(printf '%s\n' "${X25519_DERIVED}" \
    | sed -nE \
        -e 's/^Password \(PublicKey\):[[:space:]]*(.+)$/\1/p' \
        -e 's/^Password:[[:space:]]*(.+)$/\1/p' \
        -e 's/^PublicKey:[[:space:]]*(.+)$/\1/p' \
    | head -n1)"
[[ -n "${DERIVED_PUBLIC_KEY}" ]] || fatal "Не удалось получить REALITY public key"
if [[ -n "${PUBLIC_KEY}" && "${PUBLIC_KEY}" != "${DERIVED_PUBLIC_KEY}" ]]; then
    warn "REALITY public key не соответствовал private key и был исправлен"
fi
PUBLIC_KEY="${DERIVED_PUBLIC_KEY}"

if [[ -z "${SERVER_ADDRESS:-}" ]]; then
    SERVER_ADDRESS="$(curl -4fsS --max-time 5 https://icanhazip.com 2>/dev/null | tr -d '[:space:]' || true)"
fi

[[ -n "${SERVER_ADDRESS:-}" ]] || fatal \
    "Не удалось определить внешний IPv4. Запусти: SERVER_ADDRESS=<IP-or-domain> bash install.sh"
[[ "${SERVER_ADDRESS}" =~ ^[a-zA-Z0-9._:-]+$ ]] || \
    fatal "SERVER_ADDRESS содержит недопустимые символы"

state_tmp="$(mktemp "${XRAY_DIR}/server.json.XXXXXX")"
jq -n \
    --arg address "${SERVER_ADDRESS}" \
    --arg sni "${SNI}" \
    --arg dest "${DEST}" \
    --arg path "${XHTTP_PATH}" \
    --arg private_key "${PRIVATE_KEY}" \
    --arg public_key "${PUBLIC_KEY}" \
    --argjson vless_port "${VLESS_PORT}" \
    '{
        address: $address,
        vless: {
            port: $vless_port,
            path: $path,
            mode: "auto"
        },
        reality: {
            sni: $sni,
            target: $dest,
            private_key: $private_key,
            public_key: $public_key,
            fingerprint: "firefox"
        }
    }' > "${state_tmp}" || {
        rm -f "${state_tmp}"
        fatal "Не удалось создать server.json"
    }

chmod 600 "${state_tmp}"
mv "${state_tmp}" "${SERVER_STATE}"

log "Создание базового Xray config"

# The generated config must already contain at least one REALITY client and
# short ID when it is validated. Preserve existing user files across reruns,
# but always rebuild CONFIG below.
if [[ ! -f "${USERS_DIR}/${DEFAULT_USER}.json" ]]; then
    log "Создание первого пользователя '${DEFAULT_USER}'"

    DEFAULT_UUID="$(xray uuid)"
    DEFAULT_SID="$(openssl rand -hex 8)"

    jq -n \
        --arg name "${DEFAULT_USER}" \
        --arg uuid "${DEFAULT_UUID}" \
        --arg short_id "${DEFAULT_SID}" \
        --arg created_at "$(date -Iseconds)" \
        '{
            name: $name,
            uuid: $uuid,
            short_id: $short_id,
            created_at: $created_at
        }' > "${USERS_DIR}/${DEFAULT_USER}.json"

    chmod 600 "${USERS_DIR}/${DEFAULT_USER}.json"
fi

shopt -s nullglob
user_files=("${USERS_DIR}"/*.json)

if ! jq -se '
    length > 0 and
    all(.[ ];
        type == "object" and
        (.name | type == "string" and test("^[a-zA-Z0-9_-]{1,64}$")) and
        (.uuid | type == "string" and length > 0) and
        (.short_id | type == "string" and test("^[0-9a-f]{16}$")) and
        (.created_at | type == "string" and length > 0)
    ) and
    (map(.uuid) | length == (unique | length)) and
    (map(.short_id) | length == (unique | length))
    ' "${user_files[@]}" >/dev/null; then
    fatal "Некорректные или повторяющиеся данные в ${USERS_DIR}/*.json"
fi

INITIAL_CLIENTS_JSON="$(jq -sc 'map({id: .uuid, email: .name})' "${user_files[@]}")"
INITIAL_SHORTIDS_JSON="$(jq -sc 'map(.short_id)' "${user_files[@]}")"

config_tmp="$(mktemp "${XRAY_DIR}/config.json.XXXXXX")"
cat > "${config_tmp}" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "domain": [
          "geosite:category-ads-all",
          "geosite:category-ru",
          "geosite:private"
        ],
        "outboundTag": "block"
      },
      {
        "type": "field",
        "ip": [
          "geoip:cn",
          "geoip:ru",
          "geoip:private"
        ],
        "outboundTag": "block"
      },
      {
        "type": "field",
        "domain": [
          "domain:vk.com",
          "domain:ok.ru",
          "domain:rutube.ru",
          "domain:telega.me",
          "domain:telega.info",
          "domain:ruwiki.ru",
          "domain:max.ru",
          "domain:mail.ru",
          "domain:yandex.ru",
          "domain:ya.ru",
          "domain:yandex.com",
          "domain:yastatic.net",
          "domain:yandex.net",
          "domain:yandex.cloud",
          "domain:dzen.ru",
          "domain:2ip.ru"
        ],
        "outboundTag": "block"
      }
    ]
  },
  "inbounds": [
    {
      "tag": "vless-xhttp-reality",
      "listen": "0.0.0.0",
      "port": ${VLESS_PORT},
      "protocol": "vless",
      "settings": {
        "users": ${INITIAL_CLIENTS_JSON},
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "xhttpSettings": {
          "path": $(jq -Rn --arg v "${XHTTP_PATH}" '$v'),
          "mode": "auto"
        },
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": $(jq -Rn --arg v "${DEST}" '$v'),
          "serverNames": [
            $(jq -Rn --arg v "${SNI}" '$v')
          ],
          "privateKey": $(jq -Rn --arg v "${PRIVATE_KEY}" '$v'),
          "shortIds": ${INITIAL_SHORTIDS_JSON}
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ],
        "metadataOnly": false,
        "routeOnly": false
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ]
}
EOF

chmod 600 "${config_tmp}"
if ! validation_output="$(xray run -test -config "${config_tmp}" 2>&1)"; then
    rm -f "${config_tmp}"
    printf '%s\n' "${validation_output}" >&2
    fatal "Сгенерированный config.json не прошёл проверку Xray"
fi
mv "${config_tmp}" "${CONFIG}"

log "Установка команды tool"

cat > "${TOOL_BIN}" <<'LINK_EOF'
#!/usr/bin/env bash
# Managed by flying-develop/tool
set -Eeuo pipefail

XRAY_DIR="/usr/local/etc/xray"
USERS_DIR="${XRAY_DIR}/users"
CONFIG="${XRAY_DIR}/config.json"
SERVER_STATE="${XRAY_DIR}/server.json"

green='\033[1;32m'
yellow='\033[1;33m'
red='\033[1;31m'
cyan='\033[36m'
blue='\033[1;34m'
reset='\033[0m'

success() { echo -e "${green}[OK]${reset} $*"; }
error()   { echo -e "${red}[ERROR]${reset} $*" >&2; exit 1; }

require_root() {
    [[ "${EUID}" -eq 0 ]] || error "Команда требует root."
}

validate_name() {
    local name="$1"

    [[ -n "${name}" ]] || error "Имя пользователя не указано"
    [[ "${name}" =~ ^[a-zA-Z0-9_-]{1,64}$ ]] || \
        error "Имя: только a-z A-Z 0-9 _ -, максимум 64 символа"

    case "${name}" in
        add|del|delete|remove|list|ls|json|sync|status|logs|help|-h|--help)
            error "Имя совпадает с командой tool: ${name}"
            ;;
    esac
}

user_file() {
    printf '%s/%s.json\n' "${USERS_DIR}" "$1"
}

sync_users() {
    require_root

    local clients_json shortids_json tmp backup
    backup="$(mktemp "${XRAY_DIR}/config.backup.XXXXXX")"
    if ! cp "${CONFIG}" "${backup}"; then
        rm -f "${backup}"
        return 1
    fi

    shopt -s nullglob
    local files=("${USERS_DIR}"/*.json)

    if ((${#files[@]} == 0)); then
        clients_json='[]'
        shortids_json='[]'
    else
        if ! jq -se '
            all(.[ ];
                type == "object" and
                (.name | type == "string" and test("^[a-zA-Z0-9_-]{1,64}$")) and
                (.uuid | type == "string" and length > 0) and
                (.short_id | type == "string" and test("^[0-9a-f]{16}$")) and
                (.created_at | type == "string" and length > 0)
            )
        ' "${files[@]}" >/dev/null; then
            rm -f "${backup}"
            echo "Некорректный файл пользователя в ${USERS_DIR}" >&2
            return 1
        fi

        if ! jq -es '
            (map(.uuid) | length == (unique | length)) and
            (map(.short_id) | length == (unique | length))
        ' "${files[@]}" >/dev/null; then
            rm -f "${backup}"
            echo "UUID и short_id пользователей должны быть уникальны" >&2
            return 1
        fi

        if ! clients_json="$(
            jq -s '
                map({
                    id: .uuid,
                    email: .name
                })
            ' "${files[@]}"
        )"; then
            rm -f "${backup}"
            return 1
        fi

        if ! shortids_json="$(
            jq -s '
                map(.short_id)
            ' "${files[@]}"
        )"; then
            rm -f "${backup}"
            return 1
        fi
    fi

    tmp="$(mktemp "${XRAY_DIR}/config.json.XXXXXX")"

    if ! jq \
        --argjson clients "${clients_json}" \
        --argjson shortids "${shortids_json}" \
        '
        (.inbounds[] | select(.tag == "vless-xhttp-reality") | .settings.users) = $clients
        |
        (.inbounds[] | select(.tag == "vless-xhttp-reality") |
            .streamSettings.realitySettings.shortIds) = $shortids
        ' "${CONFIG}" > "${tmp}"; then
        rm -f "${tmp}" "${backup}"
        return 1
    fi

    if ! xray run -test -config "${tmp}" >/dev/null; then
        rm -f "${tmp}" "${backup}"
        echo "Новый config.json не прошёл проверку Xray" >&2
        return 1
    fi

    if ! chmod 600 "${tmp}" || ! mv "${tmp}" "${CONFIG}"; then
        rm -f "${tmp}" "${backup}"
        return 1
    fi

    if ! systemctl restart xray || ! systemctl is-active --quiet xray; then
        cp "${backup}" "${CONFIG}"
        systemctl restart xray >/dev/null 2>&1 || true
        rm -f "${backup}"
        echo "Xray не запустился; старый конфиг восстановлен" >&2
        return 1
    fi

    rm -f "${backup}"
}

show_vless_link() {
    local name="$1"
    validate_name "${name}"

    local file
    file="$(user_file "${name}")"
    [[ -f "${file}" ]] || error "Пользователь '${name}' не найден"

    local uuid sid address authority port path mode sni fp pbk
    local encoded_path encoded_mode encoded_sni encoded_fp encoded_pbk encoded_sid encoded_name vless_link

    uuid="$(jq -r '.uuid' "${file}")"
    sid="$(jq -r '.short_id' "${file}")"

    address="$(jq -r '.address' "${SERVER_STATE}")"
    port="$(jq -r '.vless.port' "${SERVER_STATE}")"
    path="$(jq -r '.vless.path' "${SERVER_STATE}")"
    mode="$(jq -r '.vless.mode' "${SERVER_STATE}")"
    sni="$(jq -r '.reality.sni' "${SERVER_STATE}")"
    fp="$(jq -r '.reality.fingerprint' "${SERVER_STATE}")"
    pbk="$(jq -r '.reality.public_key' "${SERVER_STATE}")"

    authority="${address}"
    if [[ "${address}" == *:* && "${address}" != \[*\] ]]; then
        authority="[${address}]"
    fi

    encoded_path="$(printf '%s' "${path}" | jq -sRr @uri)"
    encoded_mode="$(printf '%s' "${mode}" | jq -sRr @uri)"
    encoded_sni="$(printf '%s' "${sni}" | jq -sRr @uri)"
    encoded_fp="$(printf '%s' "${fp}" | jq -sRr @uri)"
    encoded_pbk="$(printf '%s' "${pbk}" | jq -sRr @uri)"
    encoded_sid="$(printf '%s' "${sid}" | jq -sRr @uri)"
    encoded_name="$(printf '%s' "${name}" | jq -sRr @uri)"

    vless_link="vless://${uuid}@${authority}:${port}?security=reality&encryption=none&type=xhttp&path=${encoded_path}&mode=${encoded_mode}&sni=${encoded_sni}&fp=${encoded_fp}&pbk=${encoded_pbk}&sid=${encoded_sid}#${encoded_name}"

    echo
    echo -e "${blue}[+] VLESS XHTTP REALITY — ${name}${reset}"
    echo
    echo -e "${cyan}${vless_link}${reset}"
    echo
    echo "QR:"
    printf '%s\n' "${vless_link}" | qrencode -t ansiutf8
}

add_user() {
    require_root

    local name="$1"
    validate_name "${name}"

    local file uuid sid created_at
    file="$(user_file "${name}")"

    [[ ! -e "${file}" ]] || error "Пользователь '${name}' уже существует"

    uuid="$(xray uuid)"
    sid="$(openssl rand -hex 8)"
    created_at="$(date -Iseconds)"

    jq -n \
        --arg name "${name}" \
        --arg uuid "${uuid}" \
        --arg short_id "${sid}" \
        --arg created_at "${created_at}" \
        '{
            name: $name,
            uuid: $uuid,
            short_id: $short_id,
            created_at: $created_at
        }' > "${file}"

    chmod 600 "${file}"

    if ! sync_users; then
        rm -f "${file}"
        error "Не удалось добавить пользователя"
    fi

    success "Пользователь '${name}' создан"
    show_vless_link "${name}"
}

delete_user() {
    require_root

    local name="$1"
    validate_name "${name}"

    local file backup
    file="$(user_file "${name}")"
    [[ -f "${file}" ]] || error "Пользователь '${name}' не найден"

    backup="$(mktemp)"
    cp "${file}" "${backup}"
    rm -f "${file}"

    if ! sync_users; then
        cp "${backup}" "${file}"
        rm -f "${backup}"
        error "Не удалось удалить пользователя"
    fi

    rm -f "${backup}"
    success "Пользователь '${name}' удалён"
}

list_users() {
    shopt -s nullglob
    local files=("${USERS_DIR}"/*.json)

    if ((${#files[@]} == 0)); then
        echo "Пользователей нет"
        return
    fi

    printf "%-20s %-38s %-16s %-25s\n" \
        "NAME" "UUID" "SHORT ID" "CREATED"

    printf '%*s\n' 105 '' | tr ' ' '-'

    local file
    for file in "${files[@]}"; do
        printf "%-20s %-38s %-16s %-25s\n" \
            "$(jq -r '.name' "${file}")" \
            "$(jq -r '.uuid' "${file}")" \
            "$(jq -r '.short_id' "${file}")" \
            "$(jq -r '.created_at' "${file}")"
    done
}

show_user_json() {
    local name="$1"
    validate_name "${name}"

    local file
    file="$(user_file "${name}")"
    [[ -f "${file}" ]] || error "Пользователь '${name}' не найден"

    jq . "${file}"
}

show_help() {
    cat <<'EOF'
Usage:
  tool add <name>       Добавить пользователя
  tool <name>           Показать VLESS-ссылку и QR пользователя
  tool list             Список пользователей
  tool del <name>       Удалить пользователя
  tool json <name>      Показать JSON пользователя
  tool sync             Пересобрать пользователей и shortIds из users/*.json
  tool status           Статус Xray
  tool logs             Последние логи Xray
  tool help             Эта справка
EOF
}

mkdir -p "${USERS_DIR}"

case "${1:-}" in
    add)
        [[ $# -ge 2 ]] || error "Usage: tool add <name>"
        add_user "$2"
        ;;
    del|delete|remove)
        [[ $# -ge 2 ]] || error "Usage: tool del <name>"
        delete_user "$2"
        ;;
    list|ls)
        list_users
        ;;
    json)
        [[ $# -ge 2 ]] || error "Usage: tool json <name>"
        show_user_json "$2"
        ;;
    sync)
        if sync_users; then
            success "config.json синхронизирован с users/*.json"
        else
            error "Не удалось синхронизировать config.json"
        fi
        ;;
    status)
        systemctl status xray --no-pager
        ;;
    logs)
        journalctl -u xray -n 100 --no-pager
        ;;
    help|-h|--help|"")
        show_help
        ;;
    *)
        show_vless_link "$1"
        ;;
esac
LINK_EOF

chmod 755 "${TOOL_BIN}"

log "Синхронизация пользователей с Xray config"
"${TOOL_BIN}" sync

if [[ "${ENABLE_AUTOUPDATE}" == "1" ]]; then
    log "Настройка автообновления Xray каждые 3 дня"

    cat >/etc/cron.d/xray-update <<'EOF'
# Managed by flying-develop/tool
0 6 */3 * * root bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1
EOF

    chmod 644 /etc/cron.d/xray-update
fi

echo
echo -e "${green}==================================================${reset}"
echo -e "${green}      XRAY INSTALLATION COMPLETE${reset}"
echo -e "${green}==================================================${reset}"
echo
echo "Server state: ${SERVER_STATE}"
echo "Users:        ${USERS_DIR}"
echo "Xray config:  ${CONFIG}"
echo
echo "Команды:"
echo "  tool ${DEFAULT_USER}"
echo "  tool add phone"
echo "  tool list"
echo "  tool del phone"
echo
"${TOOL_BIN}" "${DEFAULT_USER}"
