#!/usr/bin/env bash
set -Eeuo pipefail

XRAY_DIR="/usr/local/etc/xray"
TOOL_BIN="/usr/local/bin/tool"
CRON_FILE="/etc/cron.d/xray-update"
BBR_FILE="/etc/sysctl.d/99-xray-bbr.conf"

green='\033[1;32m'
yellow='\033[1;33m'
red='\033[1;31m'
reset='\033[0m'

log()   { echo -e "${yellow}[!]${reset} $*"; }
ok()    { echo -e "${green}[OK]${reset} $*"; }
fatal() { echo -e "${red}[ERROR]${reset} $*" >&2; exit 1; }

[[ "${EUID}" -eq 0 ]] || fatal "Запусти скрипт от root."

if [[ "${1:-}" != "--force" ]]; then
    echo
    echo -e "${red}Будут удалены:${reset}"
    echo "  - Xray-core"
    echo "  - все VLESS-пользователи"
    echo "  - Xray config и server state"
    echo "  - команда tool"
    echo "  - cron автообновления"
    echo "  - BBR-конфиг, созданный установщиком"
    echo
    read -r -p "Для подтверждения введи 'yes': " answer

    [[ "${answer}" == "yes" ]] || {
        echo "Отменено"
        exit 0
    }
fi

log "Остановка Xray"
systemctl stop xray 2>/dev/null || true
systemctl disable xray 2>/dev/null || true

log "Удаление cron"
if [[ -f "${CRON_FILE}" ]] && \
    grep -qxF '# Managed by flying-develop/tool' "${CRON_FILE}"; then
    rm -f "${CRON_FILE}"
fi

log "Удаление конфигурации и пользователей"
rm -rf "${XRAY_DIR}"

log "Удаление CLI tool"
if [[ -f "${TOOL_BIN}" ]] && {
    grep -qF '# Managed by flying-develop/tool' "${TOOL_BIN}" ||
    grep -qF 'show_vless_link()' "${TOOL_BIN}"
}; then
    rm -f "${TOOL_BIN}"
fi

log "Удаление BBR-конфига"
if [[ -f "${BBR_FILE}" ]] && \
    grep -qxF '# Managed by flying-develop/tool' "${BBR_FILE}"; then
    rm -f "${BBR_FILE}"
fi
sysctl --system >/dev/null 2>&1 || true

log "Удаление Xray-core"

tmp_installer="$(mktemp)"

if curl -fsSL \
    https://github.com/XTLS/Xray-install/raw/main/install-release.sh \
    -o "${tmp_installer}"; then

    bash "${tmp_installer}" remove --purge >/dev/null 2>&1 \
        || bash "${tmp_installer}" remove >/dev/null 2>&1 \
        || true
fi

rm -f "${tmp_installer}"

# Fallback cleanup if official uninstall leaves something behind.
rm -f /usr/local/bin/xray
rm -rf /usr/local/share/xray
rm -f /etc/systemd/system/xray.service
rm -f /etc/systemd/system/xray@.service
rm -rf /etc/systemd/system/xray.service.d
rm -rf /etc/systemd/system/xray@.service.d

systemctl daemon-reload 2>/dev/null || true
systemctl reset-failed 2>/dev/null || true

echo
ok "Удаление завершено"
