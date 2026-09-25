# VLESS + XHTTP + REALITY в Docker

Простой установочный скрипт для Xray-core с поддержкой:

- VLESS + XHTTP + REALITY
- нескольких пользователей
- QR-кодов и ссылок подключения
- хранение ключей и пользователей в Docker volume
- CLI-команды с хоста

## Запуск

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/flying-develop/tool/master/install.sh)
```

Скрипт сам установит Docker при необходимости, скачает контейнерные файлы в
`/opt/xray-docker`, соберёт образ, запустит контейнер и установит host-команду
`tool`. Внешний IPv4 определяется автоматически, пользователь `default`
создаётся при первом запуске.

Все параметры необязательны. При необходимости их можно передать флагами:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/flying-develop/tool/master/install.sh) \
  --server-address vpn.example.com \
  --port 443 \
  --sni www.dropbox.com \
  --dest www.dropbox.com:443 \
  --path / \
  --default-user default \
  --xray-version v26.3.27
```

Те же настройки поддерживаются через переменные окружения. Итоговые значения
записываются в `/opt/xray-docker/.env`. Путь должен начинаться с `/`, порт
должен быть в диапазоне `1..65535`.
Для REALITY выбирайте `SNI`/`DEST`, чей TLS-сертификат подходит для указанного SNI;
по возможности цель должна находиться в том же ASN, что и сервер.
Установщик не меняет firewall: TCP-порт `VLESS_PORT` нужно открыть отдельно.

Получить его ссылку:

```bash
tool default
```

Команда `tool` на хосте выполняет CLI внутри контейнера.

## Управление пользователями

Добавить пользователя:

```bash
tool add phone
```

Получить ссылку и QR-код:

```bash
tool phone
```

Посмотреть список пользователей:

```bash
tool list
```

Удалить пользователя:

```bash
tool del phone
```

Посмотреть данные пользователя:

```bash
tool json phone
```

## Полезные команды

```bash
tool status
tool logs
tool sync
tool help
```

Логи и состояние контейнера также доступны напрямую:

```bash
docker compose ps
docker compose -f /opt/xray-docker/compose.yaml logs -f xray
```

## Пример

```bash
tool add iphone
tool add laptop
tool list
tool iphone
```


## Обновление

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/flying-develop/tool/master/install.sh)
```

Повторный запуск перезаписывает контейнерные файлы и `config.json`, но сохраняет
ключи и пользователей в Docker volume.

## Удаление

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/flying-develop/tool/master/uninstall.sh)
```
