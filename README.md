# ДЗ по Docker: веб-приложение со счётчиком

Приложение из `app/` (код не менялся) упаковано в Docker. Финальная конфигурация: `app` + `redis` в Docker Compose, с healthcheck, именованным volume, ограничениями процесса и скриптом автоматической проверки восстановления.

## Структура

| Файл | Назначение |
| --- | --- |
| `app/` | исходное приложение (без изменений) |
| `Dockerfile` | образ приложения на `python:3.13-slim`, процесс от UID 10001 |
| `.dockerignore` | исключает из контекста сборки всё лишнее |
| `compose.yaml` | финальная конфигурация (уровни 8 и 10): `app` + `redis` |
| `compose.sqlite.yaml` | конфигурация уровня 6: одно приложение, SQLite на volume |
| `.env.example` | пример настроек: `APP_PORT`, `GREETING` |
| `scripts/check.sh` | автоматическая проверка восстановления (уровень 10) |

## Уровень 4: один контейнер

```sh
docker build -t hw3-counter .
docker run -d --name counter -p 8080:8000 -e GREETING="Привет из Docker!" hw3-counter

curl -fsS http://127.0.0.1:8080/
curl -fsS -X POST http://127.0.0.1:8080/increment
curl -fsS -X POST http://127.0.0.1:8080/increment
curl -fsS http://127.0.0.1:8080/

docker logs counter

docker rm -f counter
```

Приложение слушает порт 8000 внутри контейнера, `-p 8080:8000` публикует его на порту 8080 хоста. Приветствие передаётся переменной `GREETING`.

## Уровень 6: Compose и volume (SQLite)

```sh
cp .env.example .env            # при желании поменяйте APP_PORT и GREETING
docker compose -f compose.sqlite.yaml up -d --build

curl -fsS -X POST http://127.0.0.1:8080/increment   # повторите несколько раз
curl -fsS http://127.0.0.1:8080/

# удаляем и заново создаём контейнер; volume остаётся (флаг -v НЕ используем)
docker compose -f compose.sqlite.yaml down
docker compose -f compose.sqlite.yaml up -d
curl -fsS http://127.0.0.1:8080/                    # счётчик сохранился

docker compose -f compose.sqlite.yaml down -v       # полная очистка
```

Настройки (через `.env` или переменные окружения):

| Переменная | По умолчанию | Значение |
| --- | --- | --- |
| `APP_PORT` | `8080` | порт на компьютере, на котором доступно приложение |
| `GREETING` | `Hello, Docker!` | приветствие в ответе |

## Уровень 8: отдельное хранилище (Redis)

`compose.yaml` описывает два сервиса.

- **app**: `STORAGE=redis`, `REDIS_URL=redis://redis:6379/0` (по имени сервиса `redis`). Публикуется только порт приложения (`APP_PORT` → 8000). Healthcheck проверяет `GET /readyz`, поэтому `healthy` означает, что приложение видит Redis. Запускается после того, как Redis стал `healthy` (`depends_on: condition: service_healthy`).
- **redis**: `redis:7.4-alpine`, запущен с `--appendonly yes` (AOF на диске), именованный volume `redis_data` примонтирован в `/data`. Порты не публикуются. Healthcheck: `redis-cli ping`.

```sh
cp .env.example .env
docker compose up -d --build --wait
docker compose ps
```

### Проверки

```sh
P=${APP_PORT:-8080}

# 1. данные переживают down/up (без -v!)
for i in 1 2 3; do curl -fsS -X POST http://127.0.0.1:$P/increment; echo; done   # запомните N
docker compose down
docker compose up -d --wait
curl -fsS http://127.0.0.1:$P/                                                    # count == N

# 2. Redis недоступен: приложение живо, но не готово
docker compose stop redis
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:$P/healthz              # 200
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:$P/readyz               # 503
curl -s -o /dev/null -w '%{http_code}\n' -X POST http://127.0.0.1:$P/increment    # 503

# 3. Redis вернулся: приложение само восстанавливается
docker compose start redis
sleep 10
curl -fsS http://127.0.0.1:$P/                                                    # count == N
curl -fsS -X POST http://127.0.0.1:$P/increment                                   # count == N + 1
```

## Уровень 10: ограничения и автоматическая проверка

Для `app` в `compose.yaml` заданы:

- `user: "10001:10001"`: процесс не от root;
- `read_only: true` (плюс `tmpfs: /tmp`): корневая ФС только для чтения;
- `mem_limit: 256m` (и `memswap_limit: 256m`), `cpus: 1.0`: не больше 256 MiB RAM и одного ядра.

Запуск проверки:

```sh
./scripts/check.sh
```

Скрипт создаёт отдельный проект со случайным именем и свободным портом (фиксированных `container_name` и общих volumes нет) и проходит этапы:

1. поднимает проект с пустым хранилищем и ждёт готовности (`up --wait`);
   (1a. дополнительно проверяет UID ≠ 0, read-only rootfs и лимиты 256 MiB / 1 CPU);
2. проверяет счётчик 0, делает `N` (по умолчанию 5) запросов `POST /increment`, проверяет `N`;
3. пересоздаёт только контейнер `app` и проверяет, что счётчик сохранился;
4. останавливает Redis (`/healthz` = 200, `/readyz` и `POST` = 503), запускает снова и проверяет `N` и `N + 1` без перезапуска приложения;
5. штатно останавливает `app` и Redis и копирует весь каталог данных Redis из volume в `backups/redis-data-<проект>.tar` (`tar -cp`, с сохранением структуры и прав);
6. удаляет проект вместе с volumes (`down -v`) и проверяет, что volume исчез.

Все запросы и ожидания имеют тайм-ауты (`curl --max-time`, `--wait-timeout`, свои циклы ожидания). При ошибке скрипт печатает этап, последние логи контейнеров и завершается с ненулевым кодом. Через `trap` он удаляет только ресурсы своего проекта (контейнеры, сеть, volumes, собранный образ). Параметры: `N`, `WAIT_TIMEOUT`, `BACKUP_DIR`.

### Восстановление из копии (для справки)

```sh
docker volume create restored_redis
docker run --rm -v restored_redis:/data -v "$PWD/backups":/backup redis:7.4-alpine \
  sh -c "tar -C /data -xpf /backup/<файл>.tar"
```

## Отчёт о проверках

## Отчёт о проверках

Проверки выполнены на macOS (Docker Desktop, Docker 29.9.3, Compose v5.7.0). Полные логи двух запусков скрипта: [reports/run1.txt](reports/run1.txt), [reports/run2.txt](reports/run2.txt).

### Уровень 4: один контейнер

```sh
docker build -t hw3-counter .
docker run -d --name counter -p 8080:8000 -e GREETING='Привет из Docker!' hw3-counter
docker ps
```
```
CONTAINER ID   IMAGE         COMMAND           CREATED          STATUS          PORTS                                         NAMES
be9a73a6377d   hw3-counter   "python app.py"   24 seconds ago   Up 23 seconds   0.0.0.0:8080->8000/tcp, [::]:8080->8000/tcp   counter
```

Проверка счётчика:
```
$ curl http://127.0.0.1:8080/
{"greeting": "Привет из Docker!", "count": 0, "hostname": "be9a73a6377d", "storage": "sqlite"}
$ curl -X POST http://127.0.0.1:8080/increment
{"greeting": "Привет из Docker!", "count": 1, "hostname": "be9a73a6377d", "storage": "sqlite"}
$ curl -X POST http://127.0.0.1:8080/increment
{"greeting": "Привет из Docker!", "count": 2, "hostname": "be9a73a6377d", "storage": "sqlite"}
$ curl http://127.0.0.1:8080/
{"greeting": "Привет из Docker!", "count": 2, "hostname": "be9a73a6377d", "storage": "sqlite"}
```

Логи (`docker logs counter`):
```
2026-11-22 17:05:15,871 listening port=8000 storage=sqlite
2026-11-22 17:06:14,292 http 192.168.65.1 "GET / HTTP/1.1" 200 -
2026-11-22 17:06:23,255 http 192.168.65.1 "POST /increment HTTP/1.1" 200 -
2026-11-22 17:06:28,789 http 192.168.65.1 "POST /increment HTTP/1.1" 200 -
2026-11-22 17:06:42,419 http 192.168.65.1 "GET / HTTP/1.1" 200 -
```

Вывод: приветствие передаётся через `GREETING`, `POST /increment` увеличивает счётчик (0 → 1 → 2), `GET /` его не меняет.

### Уровень 6: Compose и volume (SQLite)

Настройки в `.env` (создан из `.env.example`, значения изменены):
```
APP_PORT=8090
GREETING=Privet iz compose
```

```sh
docker compose -f compose.sqlite.yaml up -d --build
docker compose -f compose.sqlite.yaml ps
```
```
NAME               IMAGE            COMMAND           SERVICE   CREATED          STATUS          PORTS
hw3-sqlite-app-1   hw3-sqlite-app   "python app.py"   app       43 seconds ago   Up 43 seconds   0.0.0.0:8090->8000/tcp, [::]:8090->8000/tcp
```

Приветствие и порт взяты из `.env`. Счётчик до удаления контейнера:
```
$ curl http://127.0.0.1:8090/
{"greeting": "Privet iz compose", "count": 0, "hostname": "c7655fdd4a36", "storage": "sqlite"}
$ curl -X POST http://127.0.0.1:8090/increment
{"greeting": "Privet iz compose", "count": 1, "hostname": "c7655fdd4a36", "storage": "sqlite"}
```

Удаление и повторное создание контейнера (volume сохраняется, `-v` не используется):
```
$ docker compose -f compose.sqlite.yaml down
 ✔ Container hw3-sqlite-app-1 Removed
 ✔ Network hw3-sqlite_default Removed
$ docker compose -f compose.sqlite.yaml ps
NAME      IMAGE     COMMAND   SERVICE   CREATED   STATUS    PORTS
$ docker compose -f compose.sqlite.yaml up -d
 ✔ Network hw3-sqlite_default Created
 ✔ Container hw3-sqlite-app-1 Started
$ curl http://127.0.0.1:8090/
curl: (56) Recv failure: Connection reset by peer
$ curl http://127.0.0.1:8090/
{"greeting": "Privet iz compose", "count": 1, "hostname": "db55f3363cd0", "storage": "sqlite"}
```
Первый запрос сразу после `up` не прошёл, потому что приложение ещё запускалось. Повторный запрос успешен.

Вывод: контейнер новый (`hostname` изменился с `c7655fdd4a36` на `db55f3363cd0`), а счётчик (`1`) сохранился на именованном volume `hw3-sqlite_counter_data`. После проверки выполнен `docker compose -f compose.sqlite.yaml down -v`.

### Уровень 8: приложение и Redis

`compose.yaml`: сервисы `app` и `redis`. У `app` заданы `STORAGE=redis`, `REDIS_URL=redis://redis:6379/0`, наружу опубликован только порт приложения. У Redis включён `--appendonly yes`, данные в именованном volume `redis_data` (`/data`). У обоих сервисов есть healthcheck.

```sh
docker compose up -d --build --wait
docker compose ps
```
```
NAME                 IMAGE              COMMAND                  SERVICE   CREATED              STATUS                        PORTS
hw3_docker-app-1     hw3_docker-app     "python app.py"          app       About a minute ago   Up About a minute (healthy)   0.0.0.0:8090->8000/tcp, [::]:8090->8000/tcp
hw3_docker-redis-1   redis:7.4-alpine   "docker-entrypoint.s…"   redis     About a minute ago   Up About a minute (healthy)   6379/tcp
```
Оба сервиса `healthy`, у Redis порт наружу не опубликован (только `6379/tcp` внутри сети).

**Проверка 1: данные после `down` и повторного `up -d`** (без `-v`):
```
$ curl http://127.0.0.1:8090/
{"greeting": "Privet iz compose", "count": 0, "hostname": "6b3d6eef1fd7", "storage": "redis"}
$ curl -X POST http://127.0.0.1:8090/increment
{"greeting": "Privet iz compose", "count": 1, "hostname": "6b3d6eef1fd7", "storage": "redis"}
$ docker compose down
 ✔ Container hw3_docker-app-1   Removed
 ✔ Container hw3_docker-redis-1 Removed
 ✔ Network hw3_docker_default   Removed
$ docker compose up -d --wait
 ✔ Container hw3_docker-redis-1 Healthy
 ✔ Container hw3_docker-app-1   Healthy
$ curl http://127.0.0.1:8090/
{"greeting": "Privet iz compose", "count": 1, "hostname": "13c1f9f0586a", "storage": "redis"}
```
N = 1 до `down` и после `up`, контейнеры пересозданы (другой `hostname`).

**Проверка 2: Redis остановлен**
```
$ docker compose stop redis
 ✔ Container hw3_docker-redis-1 Stopped
$ curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8090/healthz
200
$ curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8090/readyz
503
$ curl -s -o /dev/null -w "%{http_code}\n" -X POST http://127.0.0.1:8090/increment
503
```

**Проверка 3: Redis снова запущен, приложение не перезапускалось**
```
$ docker compose start redis
 ✔ Container hw3_docker-redis-1 Started
$ curl http://127.0.0.1:8090/
{"greeting": "Privet iz compose", "count": 1, "hostname": "13c1f9f0586a", "storage": "redis"}
$ curl -X POST http://127.0.0.1:8090/increment
{"greeting": "Privet iz compose", "count": 2, "hostname": "13c1f9f0586a", "storage": "redis"}
```
`GET /` вернул `N = 1`, следующий `POST` дал `N + 1 = 2`, `hostname` прежний, то есть приложение само восстановило связь с Redis.

### Уровень 10: ограничения и автоматическая проверка

Ограничения `app` в `compose.yaml`: `user: "10001:10001"` (не root), `read_only: true` (плюс `tmpfs: /tmp`), `mem_limit: 256m`, `cpus: 1.0`.

Скрипт `scripts/check.sh` создаёт отдельный проект со случайным именем, свободным портом и своим volume, выполняет все шаги (чистое хранилище, N инкрементов, пересоздание только `app`, остановка/запуск Redis, резервная копия в `backups/`, `down -v`) и через `trap` удаляет только свои ресурсы. У всех запросов и ожиданий есть тайм-ауты, при ошибке выводится этап и код возврата ≠ 0.

Запуск 1 (`./scripts/check.sh`, показаны этапы и проверки, полный лог в [reports/run1.txt](reports/run1.txt)):
```
==> 0. Проверка окружения
    проект: hw3check-15039-1795368344, порт: 22432, N=5
==> 1. Создание тестового проекта с пустым хранилищем
    приложение и Redis готовы
==> 1a. Ограничения контейнера app
    ok: UID процесса = 10001
    ok: read_only rootfs = true
    ok: лимит памяти (256 MiB) = 268435456
    ok: лимит CPU (1 ядро) = 1000000000
    ok: запись в корневую ФС запрещена
==> 2. Начальное значение 0 и 5 запросов POST /increment
    ok: исходный счётчик = 0
    ok: счётчик после POST #1 = 1
    ok: счётчик после POST #2 = 2
    ok: счётчик после POST #3 = 3
    ok: счётчик после POST #4 = 4
    ok: счётчик после POST #5 = 5
    ok: GET / после 5 инкрементов = 5
==> 3. Пересоздание контейнера app (Redis не трогаем)
    ok: hostname dac5f98d53c0 -> 9b917a7a370d
    ok: контейнер Redis не пересоздавался = a05c476a2c687327f5aac52258ec5d9d3b34b24d63aa102bea312887e7586ed9
    ok: счётчик после пересоздания app = 5
==> 4. Остановка и повторный запуск Redis
    ok: GET /healthz при остановленном Redis = 200
    ok: GET /readyz при остановленном Redis = 503
    ok: POST /increment при остановленном Redis = 503
    ok: приложение всё ещё живо = 200
    ok: GET / после возвращения Redis (без перезапуска app) = 5
    ok: POST /increment после возвращения Redis = 6
==> 5. Согласованная резервная копия каталога данных Redis
    ok: копия создана: /Users/arina/Downloads/hw3_docker/backups/redis-data-hw3check-15039-1795368344.tar (6144 байт)
    (в ней счётчик 6)
==> 6. Удаление тестового проекта вместе с volumes (down -v)
    ok: проект и volume удалены

OK: все проверки пройдены
```

Запуск 2 сразу после первого (полный лог в [reports/run2.txt](reports/run2.txt)):
```
==> 0. Проверка окружения
    проект: hw3check-15244-1795368393, порт: 22026, N=5
==> 1. Создание тестового проекта с пустым хранилищем
    приложение и Redis готовы
==> 1a. Ограничения контейнера app
    ok: UID процесса = 10001
    ok: read_only rootfs = true
    ok: лимит памяти (256 MiB) = 268435456
    ok: лимит CPU (1 ядро) = 1000000000
    ok: запись в корневую ФС запрещена
==> 2. Начальное значение 0 и 5 запросов POST /increment
    ok: исходный счётчик = 0
    ok: счётчик после POST #1 = 1
    ok: счётчик после POST #2 = 2
    ok: счётчик после POST #3 = 3
    ok: счётчик после POST #4 = 4
    ok: счётчик после POST #5 = 5
    ok: GET / после 5 инкрементов = 5
==> 3. Пересоздание контейнера app (Redis не трогаем)
    ok: hostname deaa9ca3897c -> 18367264460a
    ok: контейнер Redis не пересоздавался = 88c8271f91fdebc7c3ea3c4d111028a9e8315634211333340964d7bebfa02c48
    ok: счётчик после пересоздания app = 5
==> 4. Остановка и повторный запуск Redis
    ok: GET /healthz при остановленном Redis = 200
    ok: GET /readyz при остановленном Redis = 503
    ok: POST /increment при остановленном Redis = 503
    ok: приложение всё ещё живо = 200
    ok: GET / после возвращения Redis (без перезапуска app) = 5
    ok: POST /increment после возвращения Redis = 6
==> 5. Согласованная резервная копия каталога данных Redis
    ok: копия создана: /Users/arina/Downloads/hw3_docker/backups/redis-data-hw3check-15244-1795368393.tar (6144 байт)
    (в ней счётчик 6)
==> 6. Удаление тестового проекта вместе с volumes (down -v)
    ok: проект и volume удалены

OK: все проверки пройдены
```

Проверка, что скрипт убрал за собой все тестовые ресурсы:
```
$ docker ps -a
CONTAINER ID   IMAGE         COMMAND    CREATED          STATUS                      PORTS     NAMES
f0cd1fc5a3d7   hello-world   "/hello"   25 minutes ago   Exited (0) 25 minutes ago             festive_dijkstra
$ docker volume ls
DRIVER    VOLUME NAME
$ ls backups
redis-data-hw3check-15039-1795368344.tar	redis-data-hw3check-15244-1795368393.tar
```
Контейнеров и volumes тестовых проектов не осталось (контейнер `hello-world` остался от проверки установки Docker), резервные копии сохранены в `backups/`.