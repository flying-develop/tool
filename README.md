# VLESS + XHTTP + REALITY installer

Простой установочный скрипт для Xray-core с поддержкой:

- VLESS + XHTTP + REALITY
- нескольких пользователей
- QR-кодов и ссылок подключения
- BBR
- автообновления Xray

## Установка

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/flying-develop/tool/master/install.sh)
```

После установки автоматически создаётся пользователь `default`.

При необходимости параметры задаются перед запуском:

```bash
SNI=example.com DEST=example.com:443 VLESS_PORT=443 DEFAULT_USER=default bash install.sh
```

`XHTTP_PATH` должен начинаться с `/`, порт должен быть в диапазоне `1..65535`.
Для REALITY выбирайте `SNI`/`DEST`, чей TLS-сертификат подходит для указанного SNI;
по возможности цель должна находиться в том же ASN, что и сервер.
Установщик не меняет firewall: TCP-порт `VLESS_PORT` нужно открыть отдельно.

Получить его ссылку:

```bash
tool default
```

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

## Пример

```bash
tool add iphone
tool add laptop
tool list
tool iphone
```


## Удаление

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/flying-develop/tool/master/uninstall.sh)
```
