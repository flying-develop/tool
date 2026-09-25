#!/usr/bin/env bash
set -Eeuo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/xray-docker}"
COMPOSE_FILE="${INSTALL_DIR}/compose.yaml"

[[ "${EUID}" -eq 0 ]] || { echo "Запусти скрипт от root" >&2; exit 1; }

if [[ "${1:-}" != "--force" ]]; then
    echo "Будут удалены контейнер Xray, его образ, ключи, пользователи и команда tool."
    if [[ -r /dev/tty ]]; then
        read -r -p "Для подтверждения введи 'yes': " answer </dev/tty
    else
        read -r -p "Для подтверждения введи 'yes': " answer
    fi
    answer="${answer//$'\r'/}"
    answer="${answer//[[:space:]]/}"
    answer="${answer#\'}"; answer="${answer%\'}"
    answer="${answer#\"}"; answer="${answer%\"}"
    case "${answer,,}" in
        y|yes) ;;
        *) echo "Отменено"; exit 0 ;;
    esac
fi

if [[ -f "${COMPOSE_FILE}" ]] && command -v docker >/dev/null 2>&1; then
    docker compose -f "${COMPOSE_FILE}" down --rmi local -v --remove-orphans
fi

if [[ -f /usr/local/bin/tool ]] && grep -qF "${COMPOSE_FILE}" /usr/local/bin/tool; then
    rm -f /usr/local/bin/tool
fi

rm -rf "${INSTALL_DIR}"
echo "[OK] Xray Docker удалён"
