# Лабораторный Matrix Synapse на Debian 13 в локальной сети

Эта инструкция описывает отдельный постоянный стенд Synapse на Debian 13,
доступный по Wi-Fi/LAN с официальными версиями FluffyChat из Apple App Store и
Google Play. Сервер не требуется публиковать в интернет, но клиентские
устройства должны уметь разрешить его DNS-имя, установить TCP-соединение с
портом 443 и доверять TLS-сертификату.

> **Короткий ответ на главный вопрос:** да, сценарий рабочий. Официальный
> FluffyChat позволяет указать собственный Matrix homeserver. Сборка клиента из
> исходников для проверки login, комнат, сообщений, файлов, нескольких устройств
> и E2EE не нужна. Ограничения отдельных подсистем — push, звонков, SSO и
> федерации — разобраны ниже.

## Содержание

1. [Что получится](#1-что-получится)
2. [Ключевые решения до установки](#2-ключевые-решения-до-установки)
3. [Сетевая схема и адресный план](#3-сетевая-схема-и-адресный-план)
4. [DNS без изменения маршрутизатора](#4-dns-без-изменения-маршрутизатора)
5. [TLS для официальных мобильных клиентов](#5-tls-для-официальных-мобильных-клиентов)
6. [Подготовка Debian 13](#6-подготовка-debian-13)
7. [Развёртывание PostgreSQL и Synapse](#7-развёртывание-postgresql-и-synapse)
8. [Настройка nginx и HTTPS](#8-настройка-nginx-и-https)
9. [Создание пользователей](#9-создание-пользователей)
10. [Проверка сервера](#10-проверка-сервера)
11. [Подключение iPhone, iPad и Android](#11-подключение-iphone-ipad-и-android)
12. [Что можно и нельзя проверить](#12-что-можно-и-нельзя-проверить)
13. [E2EE-сценарий для нескольких устройств](#13-e2ee-сценарий-для-нескольких-устройств)
14. [Резервное копирование и обновление](#14-резервное-копирование-и-обновление)
15. [Диагностика](#15-диагностика)
16. [Checklist готовности](#16-checklist-готовности)

---

## 1. Что получится

Рекомендуемая схема:

```text
                    локальная сеть 192.168.10.0/24

 iPhone ─────┐
 iPad ───────┼── Wi-Fi ──► DNS 192.168.10.50:53
 Android ────┘                    │
                                 └─ matrix-lab.example.net
                                           → 192.168.10.50

                         Debian 13: 192.168.10.50
                  ┌──────────────────────────────────┐
 HTTPS :443 ─────►│ nginx                            │
                  │   └─► 127.0.0.1:8008 Synapse    │
                  │           └─► PostgreSQL         │
                  │ dnsmasq :53 (только для LAN)     │
                  └──────────────────────────────────┘
```

В примерах используются:

| Параметр | Значение-пример | Что поставить вместо него |
|---|---|---|
| LAN | `192.168.10.0/24` | Подсеть вашей лаборатории. |
| IP Debian | `192.168.10.50` | Статический адрес сервера. |
| Домен | `example.net` | Ваш реально зарегистрированный домен. |
| Homeserver | `matrix-lab.example.net` | Выбранное стабильное FQDN. |
| Matrix ID | `@alice:matrix-lab.example.net` | Получится из `server_name`. |

Во всех командах сначала замените эти значения. Не копируйте `example.net`
буквально: этот домен зарезервирован для документации.

## 2. Ключевые решения до установки

### 2.1 Имя сервера нельзя безболезненно поменять позже

Matrix `server_name` входит в user ID, room ID и криптографическую идентичность.
Выберите его до создания пользователей. Для стенда удобно, чтобы `server_name`,
публичный URL и имя TLS-сертификата совпадали:

```yaml
server_name: "matrix-lab.example.net"
public_baseurl: "https://matrix-lab.example.net/"
```

Технически Matrix поддерживает делегирование и короткие user IDs вида
`@alice:example.net` при сервере на `matrix.example.net`, но это добавляет
`.well-known`, federation discovery и дополнительные сертификаты. Для первого
стенда это лишняя сложность.

### 2.2 Почему не рекомендуется IP-адрес или `.local`

- Сертификат для `https://192.168.10.50` сложнее получить и сопровождать.
- Публичный CA обычно не выдаёт сертификат для private IP.
- Имя `.local` используется mDNS и может разрешаться по-разному.
- Самоподписанный сертификат официальное приложение может отвергнуть.
- HTTP передаёт login/access token без TLS. Даже если конкретная сборка клиента
  разрешает cleartext, это плохая основа стенда.

Используйте поддомен принадлежащего вам обычного домена и публично доверенный
сертификат. Сам Synapse при этом может оставаться доступным только в LAN.

### 2.3 Контейнеры или системные пакеты

Ниже используется Docker Compose:

- одинаковая процедура на чистом Debian;
- Synapse и PostgreSQL изолированы;
- версии фиксируются image tags;
- проще удалить и повторить стенд;
- nginx, DNS и firewall остаются понятными системными сервисами.

Для production следует сверять актуальные supported versions и upgrade notes
Synapse перед каждым обновлением. Не используйте `latest` в постоянном стенде.

## 3. Сетевая схема и адресный план

### 3.1 Назначьте Debian статический IP

Лучший вариант — DHCP reservation на гипервизоре/маршрутизаторе. Если это
невозможно, настройте статический адрес средствами вашей VM/network stack так,
чтобы он не попадал в динамический DHCP pool.

Проверка на Debian:

```bash
ip -br address
ip route
ping -c 3 192.168.10.1
```

Проверка с обычного компьютера в той же сети:

```bash
ping 192.168.10.50
```

VM должна использовать bridge/external network. NAT-only сеть гипервизора часто
не позволяет телефонам инициировать соединение с VM. Если используется VLAN,
убедитесь, что Wi-Fi клиентов имеет маршрут и firewall rule до VLAN сервера.

### 3.2 Порты

| Порт | Откуда | Назначение |
|---:|---|---|
| TCP 22 | Админская сеть | SSH. |
| TCP 443 | LAN/Wi-Fi устройств | Matrix Client-Server API через nginx. |
| UDP и TCP 53 | LAN/Wi-Fi устройств | Локальный DNS, если выбран `dnsmasq`. |
| TCP 8008 | Только `127.0.0.1` | nginx → Synapse; не открывать в LAN. |
| TCP 5432 | Только Docker network | Synapse → PostgreSQL. |
| TCP 8448 | Не нужен | Нужен только для выбранной схемы федерации. |

Для клиента и сервера также нужен исходящий интернет: App Store/Google Play,
получение сертификата, обновления и, возможно, push gateway. Входящий доступ из
интернета для базового LAN-теста не требуется.

## 4. DNS без изменения маршрутизатора

### 4.1 Почему одного файла `hosts` недостаточно

На Linux/macOS/Windows запись можно добавить в `/etc/hosts` или
`C:\Windows\System32\drivers\etc\hosts`:

```text
192.168.10.50 matrix-lab.example.net
```

На обычных iPhone/iPad и нерутованном Android системный `hosts` редактировать
нельзя. Поэтому для официальных мобильных приложений нужен DNS, доступный по
Wi-Fi. Менять DNS маршрутизатора необязательно: адрес DNS-сервера можно указать
вручную на каждом тестовом устройстве.

### 4.2 Вариант A — локальный dnsmasq на Debian (рекомендуется)

Установите:

```bash
apt update
apt install -y dnsmasq dnsutils
```

Узнайте текущие upstream DNS:

```bash
resolvectl status 2>/dev/null || cat /etc/resolv.conf
```

Создайте `/etc/dnsmasq.d/matrix-lab.conf`:

```ini
# Слушать loopback и LAN IP, но не все интерфейсы.
listen-address=127.0.0.1,192.168.10.50
bind-interfaces

# Локальная статическая запись.
address=/matrix-lab.example.net/192.168.10.50

# Пример внешних resolver. При необходимости используйте корпоративные DNS.
no-resolv
server=1.1.1.1
server=9.9.9.9

# Не передавать upstream имена без точки и private reverse zones.
domain-needed
bogus-priv

cache-size=1000
```

Проверьте и запустите:

```bash
dnsmasq --test
systemctl enable --now dnsmasq
systemctl status dnsmasq --no-pager
ss -lntup | grep ':53 '
dig @192.168.10.50 matrix-lab.example.net A +short
dig @192.168.10.50 example.com A +short
```

Первый `dig` должен вернуть `192.168.10.50`, второй — публичный IP. Если порт 53
занят, найдите процесс через `ss -lntup`. Не выключайте `systemd-resolved`
вслепую: сначала определите текущую DNS-конфигурацию Debian.

### 4.3 Задать DNS на iPhone/iPad

Для каждой тестовой Wi-Fi сети:

1. **Настройки → Wi-Fi**.
2. Нажмите `ⓘ` рядом с сетью.
3. **Настройка DNS → Вручную**.
4. Удалите автоматически полученные серверы.
5. Добавьте `192.168.10.50`.
6. Сохраните, отключите и включите Wi-Fi.

Настройка относится только к этой Wi-Fi сети. Если оставить вторичный публичный
DNS, устройство может случайно обратиться к нему и не получить локальную
запись. Для предсказуемого теста укажите только dnsmasq; он сам пересылает
остальные запросы upstream.

Проверить DNS можно, открыв в Safari:

```text
https://matrix-lab.example.net/_matrix/client/versions
```

### 4.4 Задать DNS на Android

Названия пунктов отличаются у производителей:

1. Откройте параметры подключённой Wi-Fi сети.
2. Выберите редактирование сети и расширенные/IP settings.
3. Некоторые версии требуют переключить DHCP на **Static** и вручную повторить
   IP, gateway, prefix length, затем указать DNS 1 = `192.168.10.50`.
4. Не используйте для этого поля hostname вида `dns.example.net`: обычный
   локальный dnsmasq — не Android Private DNS (DNS-over-TLS).
5. Если включён глобальный **Private DNS**, временно поставьте Automatic/Off,
   иначе он может обойти DNS Wi-Fi.

После теста верните DHCP/Private DNS в исходное состояние.

### 4.5 Вариант B — публичная A-запись с private IP

Можно добавить в публичной DNS-зоне:

```dns
matrix-lab.example.net. 300 IN A 192.168.10.50
```

Тогда обычно не нужен локальный DNS. Минусы: private адрес публикуется, некоторые
resolver/router блокируют DNS rebinding, имя не работает вне LAN, а изменение
кэшируется. Для лаборатории допустимо, но split DNS через dnsmasq чище.

## 5. TLS для официальных мобильных клиентов

### 5.1 Рекомендуемый вариант: публичный CA + DNS-01

DNS-01 challenge позволяет получить сертификат, даже когда сервер не доступен
из интернета: в публичной DNS-зоне временно создаётся TXT-запись
`_acme-challenge.matrix-lab.example.net`. Публичная A-запись для выдачи
сертификата не обязательна.

У вас есть три варианта автоматизации:

1. DNS plugin Certbot для вашего provider;
2. `acme.sh` с DNS API provider;
3. ручной DNS-01 — удобно для первого запуска, но renewal тоже будет ручным.

Ниже показан ручной первый выпуск. Установите Certbot:

> Команды выпуска выполняйте после базовой подготовки Debian из раздела 6.

```bash
apt install -y certbot
certbot certonly --manual --preferred-challenges dns \
  -d matrix-lab.example.net \
  --agree-tos -m admin@example.net --no-eff-email
```

Certbot покажет имя и значение TXT. Создайте запись у **авторитетного DNS
provider вашего домена**, дождитесь распространения и проверьте:

```bash
dig TXT _acme-challenge.matrix-lab.example.net @1.1.1.1
dig TXT _acme-challenge.matrix-lab.example.net @8.8.8.8
```

Только после появления правильного TXT продолжайте Certbot. Сертификаты будут в:

```text
/etc/letsencrypt/live/matrix-lab.example.net/fullchain.pem
/etc/letsencrypt/live/matrix-lab.example.net/privkey.pem
```

Ручной сертификат не обновится без повторного вмешательства. До завершения
стенда настройте DNS plugin/API и проверьте `certbot renew --dry-run`, либо
заведите календарное напоминание задолго до expiry.

### 5.2 Почему локальный CA — запасной вариант

Локальный CA можно установить как доверенный root certificate на каждое
устройство. На iOS/iPadOS после установки profile обычно требуется отдельно
включить full trust для root certificate. На Android поведение user-added CA
зависит от версии ОС и network security policy конкретного приложения.

Следовательно, успешное открытие сайта браузером не гарантирует, что официальный
FluffyChat доверится тому же локальному CA. Публично доверенный сертификат с
DNS-01 максимально близок к реальной эксплуатации и не требует менять trust
store тестовых устройств.

## 6. Подготовка Debian 13

### 6.1 Обновление и базовые пакеты

```bash
apt update
apt full-upgrade -y
apt install -y ca-certificates curl gnupg nginx nftables jq openssl
timedatectl set-timezone Etc/UTC
timedatectl status
```

Корректное время критично для TLS, Matrix events и подписей.

### 6.2 Установка Docker Engine

Не полагайтесь на случайную старую версию из окружения VM. Добавьте официальный
репозиторий Docker для текущего Debian codename:

```bash
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg \
  -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

. /etc/os-release
cat >/etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: ${VERSION_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

apt update
apt install -y docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker
```

Затем проверьте:

```bash
docker version
docker compose version
systemctl enable --now docker
```

Команды стенда выполняются от root; добавлять обычного пользователя в группу
`docker` необязательно, поскольку членство в ней практически эквивалентно root.

### 6.3 Каталоги и секреты

```bash
install -d -m 0750 /opt/matrix-lab
install -d -m 0750 /opt/matrix-lab/synapse
install -d -m 0700 /opt/matrix-lab/secrets
cd /opt/matrix-lab

openssl rand -base64 36 > secrets/postgres_password
chmod 600 secrets/postgres_password
```

Не помещайте `secrets`, signing key, БД, media store или access tokens в Git.

## 7. Развёртывание PostgreSQL и Synapse

### 7.1 Зафиксируйте images по digest

Перед развёртыванием прочитайте release/upgrade notes Synapse и выберите
подходящий release tag. Если tag уже выбран, замените `latest` на него. Команда
ниже загружает image один раз, после чего извлекает неизменяемый digest:

```bash
docker pull matrixdotorg/synapse:latest
docker pull postgres:17-bookworm

SYNAPSE_IMAGE=$(docker image inspect matrixdotorg/synapse:latest \
  --format '{{index .RepoDigests 0}}')
POSTGRES_IMAGE=$(docker image inspect postgres:17-bookworm \
  --format '{{index .RepoDigests 0}}')

printf 'SYNAPSE_IMAGE=%s\nPOSTGRES_IMAGE=%s\n' \
  "$SYNAPSE_IMAGE" "$POSTGRES_IMAGE" > /opt/matrix-lab/.env
chmod 600 /opt/matrix-lab/.env
cat /opt/matrix-lab/.env
```

Digest вида `repository@sha256:...` гарантирует повторный запуск того же image,
даже если floating tag позже передвинется. Использование `latest` допустимо
здесь только как одноразовый способ выбрать начальную версию; для следующего
обновления снова явно получите новый digest после изучения release notes.

### 7.2 Сгенерируйте исходную конфигурацию Synapse

```bash
docker run --rm -it \
  -v /opt/matrix-lab/synapse:/data \
  -e SYNAPSE_SERVER_NAME=matrix-lab.example.net \
  -e SYNAPSE_REPORT_STATS=no \
  "$SYNAPSE_IMAGE" generate
```

Сохраните резервную копию generated config до редактирования:

```bash
cp synapse/homeserver.yaml synapse/homeserver.yaml.generated
```

### 7.3 Compose file

Создайте `/opt/matrix-lab/compose.yaml`:

```yaml
services:
  postgres:
    image: ${POSTGRES_IMAGE}
    restart: unless-stopped
    environment:
      POSTGRES_DB: synapse
      POSTGRES_USER: synapse
      POSTGRES_PASSWORD_FILE: /run/secrets/postgres_password
      POSTGRES_INITDB_ARGS: --encoding=UTF8 --locale=C
    secrets:
      - postgres_password
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U synapse -d synapse"]
      interval: 10s
      timeout: 5s
      retries: 10

  synapse:
    image: ${SYNAPSE_IMAGE}
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
    environment:
      SYNAPSE_CONFIG_PATH: /data/homeserver.yaml
    volumes:
      - ./synapse:/data
    ports:
      - "127.0.0.1:8008:8008"

secrets:
  postgres_password:
    file: ./secrets/postgres_password

volumes:
  postgres_data:
```

Compose автоматически читает `/opt/matrix-lab/.env`. Команда `docker compose
config` должна показать конкретные значения с `@sha256`, а не пустые image.

### 7.4 Настройте `homeserver.yaml`

Отредактируйте ключевые значения:

```yaml
server_name: "matrix-lab.example.net"
public_baseurl: "https://matrix-lab.example.net/"
report_stats: false

enable_registration: false

database:
  name: psycopg2
  args:
    user: synapse
    password: "PASTE_THE_POSTGRES_PASSWORD_HERE"
    database: synapse
    host: postgres
    port: 5432
    cp_min: 5
    cp_max: 10

listeners:
  - port: 8008
    tls: false
    type: http
    x_forwarded: true
    bind_addresses: ['0.0.0.0']
    resources:
      - names: [client, federation]
        compress: false
```

Значение `database.args.password` должно совпадать с
`secrets/postgres_password`. Synapse config не умеет автоматически понимать
Compose `POSTGRES_PASSWORD_FILE`; для более строгого secret management используйте
поддерживаемый вашей системой template/startup mechanism.

Не удаляйте сгенерированные `registration_shared_secret`, `macaroon_secret_key`
и `form_secret`. Первый нужен `register_new_matrix_user`, остальные являются
частью состояния сервера. Не выводите их значения в логи или в описание задачи:

```bash
grep -E '^(registration_shared_secret|macaroon_secret_key|form_secret):' \
  /opt/matrix-lab/synapse/homeserver.yaml | sed 's/:.*/: <present>/'
```

Проверьте права:

```bash
chown -R 991:991 /opt/matrix-lab/synapse
chmod 600 /opt/matrix-lab/synapse/*.signing.key
```

UID образа может измениться — проверьте документацию выбранного tag, если
контейнер сообщает `Permission denied`.

### 7.5 Первый старт

```bash
cd /opt/matrix-lab
docker compose config
docker compose pull
docker compose up -d
docker compose ps
docker compose logs --tail=200 synapse
curl -fsS http://127.0.0.1:8008/health
```

Не продолжайте, пока `/health` не отвечает успешно и в логах нет ошибок БД.

## 8. Настройка nginx и HTTPS

Создайте `/etc/nginx/sites-available/matrix-lab`:

```nginx
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name matrix-lab.example.net;

    ssl_certificate     /etc/letsencrypt/live/matrix-lab.example.net/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/matrix-lab.example.net/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    client_max_body_size 100M;

    location /_matrix {
        proxy_pass http://127.0.0.1:8008;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Host $host;
        proxy_http_version 1.1;
        proxy_read_timeout 600s;
    }

    location /_synapse/client {
        proxy_pass http://127.0.0.1:8008;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Host $host;
    }

    location = /health {
        proxy_pass http://127.0.0.1:8008/health;
    }
}
```

Активируйте и проверьте:

```bash
ln -s /etc/nginx/sites-available/matrix-lab \
  /etc/nginx/sites-enabled/matrix-lab
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl reload nginx
```

Проверяйте с правильным DNS и SNI, а не через IP:

```bash
curl -fsS https://matrix-lab.example.net/health
curl -fsS https://matrix-lab.example.net/_matrix/client/versions | jq
openssl s_client -connect matrix-lab.example.net:443 \
  -servername matrix-lab.example.net -verify_return_error </dev/null
```

Для reload nginx после автоматического renewal создайте deploy hook:

```bash
cat >/etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh <<'EOF'
#!/bin/sh
systemctl reload nginx
EOF
chmod 755 /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
```

## 9. Создание пользователей

Публичную регистрацию мы отключили. Создавайте лабораторных пользователей
административной CLI-командой:

```bash
cd /opt/matrix-lab
docker compose exec synapse \
  register_new_matrix_user -c /data/homeserver.yaml http://localhost:8008
```

Создайте минимум `alice` и `bob`; admin права для обычного теста не нужны. Для
автоматизации можно добавить `--user`, `--password` и `--no-admin`, но пароль
тогда попадёт в shell history/process arguments. Интерактивный ввод безопаснее.

Ожидаемые Matrix IDs:

```text
@alice:matrix-lab.example.net
@bob:matrix-lab.example.net
```

## 10. Проверка сервера

### 10.1 Без access token

```bash
curl -fsS https://matrix-lab.example.net/_matrix/client/versions | jq
curl -fsS https://matrix-lab.example.net/_matrix/client/v3/login | jq
curl -fsS https://matrix-lab.example.net/_matrix/client/v3/register | jq
```

Registration endpoint может вернуть ошибку/flows — важно, что ответ Matrix JSON,
а не nginx 404/502.

### 10.2 Тестовый password login через API

Не выполняйте следующую команду в shared shell history. Введите JSON во временный
файл с правами 600 либо используйте официальный клиент:

```bash
read -rsp 'Alice password: ' MATRIX_PASSWORD; echo
curl -fsS -X POST \
  -H 'Content-Type: application/json' \
  --data "$(jq -n --arg p "$MATRIX_PASSWORD" '{
    type:"m.login.password",
    identifier:{type:"m.id.user", user:"alice"},
    password:$p,
    initial_device_display_name:"curl smoke test"
  }')" \
  https://matrix-lab.example.net/_matrix/client/v3/login | jq
unset MATRIX_PASSWORD
```

Ответ содержит access token — не публикуйте его. После smoke test удалите это
устройство через клиент или authenticated devices API.

### 10.3 Проверка с другого LAN-компьютера

```bash
dig @192.168.10.50 matrix-lab.example.net +short
curl -v https://matrix-lab.example.net/_matrix/client/versions
```

Это одновременно проверяет маршрут, DNS, firewall, SNI, сертификат и reverse
proxy. Только после успеха переходите к телефонам.

## 11. Подключение iPhone, iPad и Android

На каждом устройстве:

1. Подключитесь к той же Wi-Fi/LAN-среде.
2. Настройте DNS этой Wi-Fi сети на `192.168.10.50`.
3. Откройте URL `https://matrix-lab.example.net/_matrix/client/versions` в
   браузере. Должен появиться JSON без предупреждения о сертификате.
4. Установите официальный FluffyChat из App Store/Google Play.
5. На экране выбора homeserver выберите ввод собственного сервера.
6. Введите полный URL `https://matrix-lab.example.net`.
7. Войдите как `alice` или `bob`.

Интерфейс store-версии может отличаться от текущего source tree. Иногда сначала
надо выбрать **Other homeserver**, **Change homeserver** или ввести доменное имя
в поиск. Критерий успеха — приложение обнаружило login flow вашего Synapse.

Не вводите `localhost`: на телефоне это сам телефон. Не вводите LAN IP вместо
FQDN: TLS certificate выдан на имя.

### Можно ли использовать запись `hosts` только на Debian?

Нет. `/etc/hosts` Debian влияет только на запросы самого сервера. Телефон не
получит эту запись. На каждом телефоне должен работать один из вариантов:

- его Wi-Fi DNS указывает на ваш dnsmasq;
- публичная DNS A-запись возвращает private IP;
- на устройстве установлен управляемый DNS/VPN profile.

## 12. Что можно и нельзя проверить

### 12.1 Работает без сборки FluffyChat

- homeserver discovery по введённому URL;
- password login/logout и несколько Matrix devices;
- создание private/group rooms;
- обычные и E2EE-сообщения;
- reactions, reply, edit, redaction, receipts и typing;
- загрузка/скачивание media в пределах настроенного лимита;
- device list, emoji/numeric verification, cross-signing;
- encrypted key backup/recovery, если настроить его в клиентах;
- поведение после restart Synapse и повторной синхронизации;
- совместимость серверной части с выпущенной store-версией клиента.

Это хороший первый этап: он отделяет проблемы Synapse/DNS/TLS от проблем сборки
Flutter-приложения.

### 12.2 Push notifications

Foreground sync будет работать. Background push — отдельная интеграция:

- store-приложение использует push credentials, встроенные его издателем;
- клиент регистрирует Matrix pusher и выбранный push gateway;
- Synapse должен иметь исходящий HTTPS-доступ к gateway;
- iOS/Android должны разрешить notifications/background activity;
- локальный homeserver должен оставаться достижимым, когда приложение проснётся.

Если push не приходит, это не означает, что Matrix messaging сломан. Сначала
проверяйте уведомление при открытом приложении, затем pusher в настройках/логах,
исходящий доступ и только потом APNs/FCM/UnifiedPush.

### 12.3 Звонки

Для надёжного WebRTC через разные сети/NAT нужен TURN server и соответствующая
конфигурация homeserver/client. Без TURN звонок иногда работает в одной LAN, но
это не полноценный тест инфраструктуры. VoIP также может быть experimental или
отличаться между версиями FluffyChat.

### 12.4 Федерация

Для двух локальных пользователей на одном Synapse федерация не требуется. Чтобы
общаться с `matrix.org` и другими серверами, ваш server name должен быть
доступен внешним homeserver, иметь корректные DNS/`.well-known`, TLS и federation
listener/reverse proxy. LAN-only адрес для этого недостаточен.

### 12.5 SSO/OIDC

Password login не требует отдельного identity provider. SSO/OIDC добавляет IdP,
redirect URI и universal/app links; проверяйте его отдельным этапом после
стабильной password-аутентификации.

## 13. E2EE-сценарий для нескольких устройств

Используйте отдельные тестовые аккаунты и сохраните recovery key.

1. Войдите `alice` на iPhone и `bob` на Android.
2. Alice создаёт private encrypted room и приглашает Bob.
3. Отправьте текст, изображение и файл в обе стороны.
4. Войдите `alice` на iPad: это новое Matrix device.
5. Проверьте, что старые сообщения до передачи ключей не становятся plaintext
   «магически».
6. Запустите verification iPad с iPhone, сравните emoji/числа на обоих экранах.
7. Включите encrypted chat backup/recovery и сохраните recovery material вне
   устройств.
8. Проверьте появление истории на iPad после восстановления ключей.
9. Перезапустите контейнеры и повторите отправку:

   ```bash
   cd /opt/matrix-lab
   docker compose restart
   ```

10. Отключите Wi-Fi на одном устройстве, отправьте сообщение, включите сеть и
    наблюдайте pending/retry/sync.
11. Отзовите тестовое устройство и проверьте device list/trust indicators.

Не удаляйте старое trusted устройство, пока не проверили recovery на новом.

## 14. Резервное копирование и обновление

### 14.1 Что резервировать

- PostgreSQL dump;
- `/opt/matrix-lab/synapse/homeserver.yaml`;
- Synapse signing key (`*.signing.key`) — критично для server identity;
- media store внутри `/opt/matrix-lab/synapse`;
- Compose file и отдельно защищённые secrets;
- TLS automation config (приватный TLS key обычно можно перевыпустить).

Encrypted key backup пользователей хранится как серверные данные, но его
расшифровка требует пользовательского recovery material, которого не должно быть
у администратора Synapse.

### 14.2 Пример PostgreSQL dump

```bash
install -d -m 0700 /var/backups/matrix-lab
cd /opt/matrix-lab
docker compose exec -T postgres \
  pg_dump -U synapse -d synapse -Fc \
  > /var/backups/matrix-lab/synapse-$(date +%F-%H%M).dump
```

Проверьте, что файл не пуст, перенесите backup на другое хранилище и обязательно
отрепетируйте restore на отдельном стенде. Непроверенный backup — только надежда.

### 14.3 Обновление

1. Сделайте backup БД, config, signing key и media.
2. Прочитайте release notes всех пропускаемых версий Synapse.
3. Измените только pinned image tag.
4. Выполните:

   ```bash
   cd /opt/matrix-lab
   docker compose pull
   docker compose up -d
   docker compose logs -f --tail=200 synapse
   ```

5. Повторите health, versions, login, message и E2EE smoke tests.
6. Не выполняйте произвольный downgrade БД после миграции.

## 15. Диагностика

### DNS

```bash
dig @192.168.10.50 matrix-lab.example.net A
dig @192.168.10.50 example.com A
journalctl -u dnsmasq -n 100 --no-pager
```

Если компьютер работает, а телефон нет, почти всегда телефон использует другой
DNS, Private DNS/DoH, мобильную сеть либо Wi-Fi с client isolation.

### TLS/nginx

```bash
nginx -t
journalctl -u nginx -n 100 --no-pager
openssl s_client -connect matrix-lab.example.net:443 \
  -servername matrix-lab.example.net -showcerts </dev/null
curl -vk https://matrix-lab.example.net/_matrix/client/versions
```

`curl -k` используйте только для диагностики. Успех с `-k` и ошибка без него
означают проблему trust/chain/name/expiry, которую нельзя «исправлять» отключением
проверки в клиенте.

### Synapse/PostgreSQL

```bash
cd /opt/matrix-lab
docker compose ps
docker compose logs --tail=300 synapse
docker compose logs --tail=100 postgres
curl -v http://127.0.0.1:8008/health
```

- `502 Bad Gateway`: nginx не видит Synapse или тот ещё запускается.
- `Connection refused`: процесс/порт/firewall/Docker binding.
- Matrix JSON `M_FORBIDDEN`: сеть работает, проверяйте credentials/permissions.
- Не расшифровывается одно сообщение: проверяйте device trust/room key/backup, а
  не PostgreSQL.

### Firewall

Покажите текущую конфигурацию до изменения:

```bash
nft list ruleset
ss -lntup
```

Разрешите TCP 443 и DNS TCP/UDP 53 только из вашей LAN, SSH — только из
админской сети. Не копируйте готовый `nft flush ruleset` на удалённый сервер:
можно потерять SSH. Сначала подготовьте rollback через консоль гипервизора.

### Безопасность логов

Перед публикацией удаляйте access tokens, cookies, пароли, event contents,
Matrix IDs и приватные адреса. Не включайте SQL DEBUG logging на стенде с
реальными сообщениями.

## 16. Checklist готовности

### Сервер

- [ ] Debian имеет стабильный LAN IP и корректное время.
- [ ] VM доступна с Wi-Fi устройств, нет client isolation/NAT-only проблемы.
- [ ] Synapse и PostgreSQL images зафиксированы конкретными tags.
- [ ] Public registration выключена.
- [ ] PostgreSQL и порт 8008 не опубликованы в LAN.
- [ ] `/health` и `/_matrix/client/versions` работают через HTTPS.
- [ ] Сертификат публично доверенный, имя совпадает, renewal продуман.
- [ ] Backup включает БД, signing key, config и media; restore проверен.

### DNS и устройства

- [ ] `matrix-lab.example.net` возвращает LAN IP на каждом устройстве.
- [ ] Браузер каждого устройства открывает Matrix versions без TLS warning.
- [ ] На Android Private DNS не обходит лабораторный DNS.
- [ ] В FluffyChat введён FQDN с `https://`, а не `localhost`/IP.

### Функциональность

- [ ] Alice и Bob входят с разных устройств.
- [ ] Обычная и E2EE-комнаты работают.
- [ ] Media upload/download работает.
- [ ] Новое устройство проходит verification и recovery.
- [ ] Restart сервера не теряет комнаты и media.
- [ ] Push, TURN/VoIP, SSO и federation учитываются как отдельные этапы.

---

## Итог

Для первого этапа сборка FluffyChat из source действительно не нужна. Отдельный
Debian 13 с Synapse, PostgreSQL, nginx, корректным DNS и доверенным HTTPS
полностью подходит для проверки основной Matrix-инфраструктуры официальными
FluffyChat на iPhone, iPad и Android.

Самые важные условия для mobile store builds:

1. телефон разрешает FQDN в LAN IP;
2. телефон маршрутизируется до TCP 443 Debian-сервера;
3. сертификат доверен ОС и выдан именно на этот FQDN;
4. FluffyChat получает полный URL homeserver;
5. дополнительные сервисы push/TURN/SSO/federation оцениваются отдельно.

## Ссылки для сверки перед установкой

Инфраструктурные проекты обновляются независимо от этого репозитория. Перед
установкой и особенно обновлением сверяйте команды и supported versions с
первоисточниками:

- [Synapse installation](https://element-hq.github.io/synapse/latest/setup/installation.html)
- [Synapse reverse proxy documentation](https://element-hq.github.io/synapse/latest/reverse_proxy.html)
- [Synapse PostgreSQL documentation](https://element-hq.github.io/synapse/latest/postgres.html)
- [Synapse TURN setup](https://element-hq.github.io/synapse/latest/turn-howto.html)
- [Matrix Client-Server specification](https://spec.matrix.org/latest/client-server-api/)
- [Docker Engine installation on Debian](https://docs.docker.com/engine/install/debian/)
- [Certbot instructions](https://certbot.eff.org/instructions)
