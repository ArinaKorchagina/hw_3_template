#!/usr/bin/env bash
# Автоматическая проверка восстановления (уровень 10).
# Запуск из любого каталога: ./scripts/check.sh
# Нужны только Docker с Compose и curl.
#
# Скрипт создаёт отдельный Compose-проект со случайным именем (своя сеть, свой
# volume, свой порт), проходит все этапы и при любом исходе удаляет только свои
# ресурсы. Резервная копия данных Redis остаётся в ./backups/.

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

N="${N:-5}"                                   # сколько раз вызвать POST /increment
WAIT_TIMEOUT="${WAIT_TIMEOUT:-90}"            # тайм-аут ожидания готовности, секунды
BACKUP_DIR="${BACKUP_DIR:-$ROOT/backups}"
PROJECT="hw3check-$$-$(date +%s)"             # уникальное имя проекта
COMPOSE_FILE="$ROOT/compose.yaml"
BACKUP_NAME="redis-data-$PROJECT.tar"
BACKUP_FILE="$BACKUP_DIR/$BACKUP_NAME"
VOLUME="${PROJECT}_redis_data"
CURL_OPTS=(-sS --connect-timeout 2 --max-time 5)

STAGE="инициализация"

# --- вспомогательные функции -------------------------------------------------

compose() { docker compose -p "$PROJECT" -f "$COMPOSE_FILE" "$@"; }

stage() { STAGE="$*"; printf '\n==> %s\n' "$STAGE"; }
info()  { printf '    %s\n' "$*"; }
fail()  { printf 'ОШИБКА [%s]: %s\n' "$STAGE" "$*" >&2; exit 1; }
need()  { command -v "$1" >/dev/null 2>&1 || fail "не найдена команда: $1"; }

assert_eq() { # фактическое ожидаемое описание
    [ "$1" = "$2" ] || fail "$3: ожидалось '$2', получено '$1'"
    info "ok: $3 = $2"
}

url() { printf 'http://127.0.0.1:%s%s' "$APP_PORT" "$1"; }

http_code() { # метод путь -> HTTP-код (000, если соединиться не удалось)
    curl "${CURL_OPTS[@]}" -o /dev/null -w '%{http_code}' -X "$1" "$(url "$2")" 2>/dev/null || true
}

body() { curl "${CURL_OPTS[@]}" -f -X "$1" "$(url "$2")"; }

json_count()    { sed -n 's/.*"count": *\([0-9][0-9]*\).*/\1/p'; }
json_hostname() { sed -n 's/.*"hostname": *"\([^"]*\)".*/\1/p'; }

get_count()  { body GET /          | json_count; }
post_count() { body POST /increment | json_count; }

wait_code() { # метод путь ожидаемый_код [тайм-аут]
    local method=$1 path=$2 want=$3 timeout=${4:-$WAIT_TIMEOUT} deadline code
    deadline=$((SECONDS + timeout))
    while :; do
        code="$(http_code "$method" "$path")"
        [ "$code" = "$want" ] && return 0
        [ "$SECONDS" -ge "$deadline" ] && \
            fail "тайм-аут ${timeout}с: $method $path вернул $code, ожидался $want"
        sleep 1
    done
}

pick_port() { # свободный порт на localhost
    local p i
    for i in $(seq 1 50); do
        p=$((20000 + RANDOM % 20000))
        if ! (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null; then
            printf '%s' "$p"
            return 0
        fi
    done
    return 1
}

cleanup() {
    local code=$?
    trap - EXIT
    if [ "$code" -ne 0 ]; then
        printf '\nПРОВЕРКА НЕ ПРОЙДЕНА на этапе: %s (код выхода %s)\n' "$STAGE" "$code" >&2
        compose ps -a >&2 2>/dev/null || true
        compose logs --no-color --tail 30 >&2 2>/dev/null || true
    fi
    # Удаляем только ресурсы проекта $PROJECT: контейнеры, сеть, volumes и собранный образ
    compose down -v --remove-orphans --rmi local -t 10 >/dev/null 2>&1 || true
    exit "$code"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# --- этап 0: окружение -------------------------------------------------------

stage "0. Проверка окружения"
need docker
need curl
docker compose version >/dev/null 2>&1 || fail "не найден плагин docker compose"
docker info >/dev/null 2>&1 || fail "демон Docker недоступен"
APP_PORT="$(pick_port)" || fail "не удалось найти свободный порт"
# Переменные окружения важнее .env, поэтому пользовательский .env не влияет на проверку
export APP_PORT GREETING="check-greeting"
info "проект: $PROJECT, порт: $APP_PORT, N=$N"

# --- этап 1: чистый проект и готовность --------------------------------------

stage "1. Создание тестового проекта с пустым хранилищем"
compose up -d --build --wait --wait-timeout "$WAIT_TIMEOUT"
wait_code GET /readyz 200 30
info "приложение и Redis готовы"

stage "1a. Ограничения контейнера app"
APP_CID="$(compose ps -q app)"
uid="$(compose exec -T app id -u | tr -d '\r')"
[ "$uid" != "0" ] || fail "процесс app запущен от root"
info "ok: UID процесса = $uid"
assert_eq "$(docker inspect -f '{{.HostConfig.ReadonlyRootfs}}' "$APP_CID")" true "read_only rootfs"
assert_eq "$(docker inspect -f '{{.HostConfig.Memory}}' "$APP_CID")" 268435456 "лимит памяти (256 MiB)"
assert_eq "$(docker inspect -f '{{.HostConfig.NanoCpus}}' "$APP_CID")" 1000000000 "лимит CPU (1 ядро)"
if compose exec -T app sh -c 'touch /app/.write_test' >/dev/null 2>&1; then
    fail "корневая ФС app доступна на запись"
fi
info "ok: запись в корневую ФС запрещена"

# --- этап 2: счётчик ---------------------------------------------------------

stage "2. Начальное значение 0 и $N запросов POST /increment"
assert_eq "$(get_count)" 0 "исходный счётчик"
for i in $(seq 1 "$N"); do
    assert_eq "$(post_count)" "$i" "счётчик после POST #$i"
done
assert_eq "$(get_count)" "$N" "GET / после $N инкрементов"

# --- этап 3: пересоздание только приложения ----------------------------------

stage "3. Пересоздание контейнера app (Redis не трогаем)"
old_host="$(body GET / | json_hostname)"
old_redis="$(compose ps -q redis)"
compose up -d --no-deps --force-recreate --wait --wait-timeout "$WAIT_TIMEOUT" app
wait_code GET /readyz 200 30
new_host="$(body GET / | json_hostname)"
[ -n "$new_host" ] && [ "$old_host" != "$new_host" ] || \
    fail "контейнер app не был пересоздан (hostname $old_host -> $new_host)"
info "ok: hostname $old_host -> $new_host"
assert_eq "$(compose ps -q redis)" "$old_redis" "контейнер Redis не пересоздавался"
assert_eq "$(get_count)" "$N" "счётчик после пересоздания app"

# --- этап 4: отключение и повторный запуск Redis -----------------------------

stage "4. Остановка и повторный запуск Redis"
compose stop -t 10 redis
assert_eq "$(http_code GET /healthz)" 200 "GET /healthz при остановленном Redis"
wait_code GET /readyz 503 30
assert_eq "$(http_code GET /readyz)" 503 "GET /readyz при остановленном Redis"
assert_eq "$(http_code POST /increment)" 503 "POST /increment при остановленном Redis"
assert_eq "$(http_code GET /healthz)" 200 "приложение всё ещё живо"

compose start redis
wait_code GET /readyz 200 "$WAIT_TIMEOUT"
assert_eq "$(get_count)" "$N" "GET / после возвращения Redis (без перезапуска app)"
assert_eq "$(post_count)" "$((N + 1))" "POST /increment после возвращения Redis"
FINAL=$((N + 1))

# --- этап 5: резервная копия -------------------------------------------------

stage "5. Согласованная резервная копия каталога данных Redis"
# Останавливаем приложение и Redis штатно (Redis сбрасывает данные на диск при SIGTERM)
compose stop -t 10 app redis
docker volume inspect "$VOLUME" >/dev/null 2>&1 || fail "не найден volume $VOLUME"
REDIS_IMAGE="$(docker inspect -f '{{.Config.Image}}' "$(compose ps -aq redis)")"
mkdir -p "$BACKUP_DIR"
docker run --rm --entrypoint sh \
    -v "$VOLUME":/data:ro \
    -v "$BACKUP_DIR":/backup \
    "$REDIS_IMAGE" -c \
    "tar -C /data -cpf /backup/$BACKUP_NAME . && chown $(id -u):$(id -g) /backup/$BACKUP_NAME"
[ -s "$BACKUP_FILE" ] || fail "файл резервной копии пуст или не создан: $BACKUP_FILE"
listing="$(tar -tf "$BACKUP_FILE")"
grep -q 'appendonlydir/' <<<"$listing" || fail "в копии нет каталога appendonlydir"
grep -q 'appendonly.aof.manifest' <<<"$listing" || fail "в копии нет манифеста AOF"
info "ok: копия создана: $BACKUP_FILE ($(wc -c <"$BACKUP_FILE" | tr -d ' ') байт)"
info "(в ней счётчик $FINAL)"

# --- этап 6: удаление проекта вместе с volumes -------------------------------

stage "6. Удаление тестового проекта вместе с volumes (down -v)"
compose down -v --remove-orphans -t 10
if docker volume inspect "$VOLUME" >/dev/null 2>&1; then
    fail "volume $VOLUME остался после down -v"
fi
info "ok: проект и volume удалены"

printf '\nOK: все проверки пройдены\n'
