#!/usr/bin/env bash
# mh-deploy — деплой 3D-тура на сервер С МАКА.
#
# Зачем отдельно от matterhub-installer.sh: тот скрипт бежит НА СЕРВЕРЕ и видит
# только публичный интернет. Приватные источники (файл на маке, iCloud Drive,
# приватный iCloud-шар) доступны только маку — значит качает мак, а серверу
# отдаёт готовый файл (scp) и запускает установщик в локальном режиме (-a).
#
# Три источника:
#   1) Файл на маке / в iCloud Drive → scp → установщик -a
#   2) Публичная ссылка (Я.Диск/GDrive/Dropbox/OneDrive/Mail.ru) → сервер качает сам (--url)
#   3) Приватный iCloud-шар → открыть в Safari, дождаться загрузки в ~/Downloads → scp → -a
#
# Без флагов — интерактивное меню. С флагами — можно гонять в скриптах/тестах.
set -euo pipefail

# ─── Настройки по умолчанию (переопределяются флагами / env) ──────────
SERVER="${MH_SERVER:-new-vps}"          # ssh-таргет сервера
DOMAIN="${MH_DOMAIN:-yr2.ru}"           # домен, куда ставим тур
RAW_HTML="https://raw.githubusercontent.com/verbovoj/matterhub-installer/main/scripts/matterhub-html-installer.sh"
DOWNLOADS="${HOME}/Downloads"

SLUG=""
SRC_FILE=""      # режим 1
SRC_URL=""       # режим 2
SRC_ICLOUD=""    # режим 3

# ─── Цвета / логгеры ─────────────────────────────────────────────────
if [[ -t 1 ]]; then
    C='\033[0;36m'; G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; B='\033[1m'; N='\033[0m'
else
    C=''; G=''; Y=''; R=''; B=''; N=''
fi
info() { echo -e "${C}[i]${N} $*" >&2; }
ok()   { echo -e "${G}[✓]${N} $*" >&2; }
warn() { echo -e "${Y}[!]${N} $*" >&2; }
die()  { echo -e "${R}[✗]${N} $*" >&2; exit 1; }

usage() {
    cat << EOF
mh-deploy — деплой 3D-тура на сервер с мака

Использование:
  mh-deploy                          # интерактивно (спросит источник)
  mh-deploy --file ./tour.zip        # файл на маке / iCloud Drive
  mh-deploy --url  <ссылка>          # публичная ссылка файлообменника
  mh-deploy --icloud <ссылка-шара>   # приватный iCloud — откроет Safari

Опции:
  --file PATH        локальный файл (scp на сервер → установка)
  --url  URL         публичная ссылка (сервер скачает сам через резолвер)
  --icloud URL       приватный iCloud-шар (Safari → ~/Downloads → scp)
  -d, --domain DOM   домен (по умолчанию: ${DOMAIN})
  -s, --slug SLUG    слаг тура (по умолчанию из имени файла)
  --server SSH       ssh-таргет сервера (по умолчанию: ${SERVER})
  -h, --help         эта справка
EOF
    exit 0
}

# ─── Парсинг аргументов ──────────────────────────────────────────────
# значение-требующие флаги: проверяем наличие $2 до потребления (иначе set -u
# роняет «unbound variable» вместо понятного сообщения)
need_val() { [[ $# -ge 2 ]] || die "Опция $1 требует значение"; }
while [[ $# -gt 0 ]]; do
    case "$1" in
        --file)      need_val "$@"; SRC_FILE="$2"; shift 2 ;;
        --url)       need_val "$@"; SRC_URL="$2"; shift 2 ;;
        --icloud)    need_val "$@"; SRC_ICLOUD="$2"; shift 2 ;;
        -d|--domain) need_val "$@"; DOMAIN="$2"; shift 2 ;;
        -s|--slug)   need_val "$@"; SLUG="$2"; shift 2 ;;
        --server)    need_val "$@"; SERVER="$2"; shift 2 ;;
        -h|--help)   usage ;;
        *) die "Неизвестный аргумент: $1 (--help для справки)" ;;
    esac
done

# ─── Утилиты ─────────────────────────────────────────────────────────
# Снять кавычки и backslash-экранирование (drag&drop в Терминал macOS экранирует
# ВСЕ спецсимволы: пробел, ( ) & ' $ [ ] ! … — не только пробел). Напр. дубль-загрузка
# «tour (1).zip» вставляется как tour\ \(1\).zip → разэкранируем любой \X → X.
clean_path() {
    local p="$1"
    p="${p%\"}"; p="${p#\"}"
    p="${p%\'}"; p="${p#\'}"
    p=$(printf '%s' "$p" | sed -E 's/\\(.)/\1/g')
    printf '%s' "$p"
}

# Слаг из имени файла: убрать расширение, оставить [alnum_-]
slug_from() {
    local base; base=$(basename "$1")
    base="${base%.*}"
    printf '%s' "$base" | tr -cd '[:alnum:]_-'
}

# Проверки безопасности значений, уходящих в ssh-строку
validate_domain() { [[ "$DOMAIN" =~ ^[a-zA-Z0-9.-]+$ ]] || die "Домен '$DOMAIN' некорректен"; }
validate_slug()   { [[ "$SLUG"   =~ ^[a-zA-Z0-9_-]{4,}$ ]] || die "Слаг '$SLUG' некорректен (буквы/цифры/_/-, ≥4)"; }
validate_server() { [[ "$SERVER" =~ ^[a-zA-Z0-9_.@-]+$ ]] || die "ssh-таргет '$SERVER' некорректен"; }

# ─── Режим 3: приватный iCloud-шар через Safari ──────────────────────
fetch_via_safari() {
    local url="$1"
    command -v open >/dev/null || die "Нет команды open — это точно macOS?"
    # снимок .zip в ~/Downloads ДО открытия (чтобы вычислить новый файл)
    local before; before=$(ls -1 "$DOWNLOADS"/*.zip 2>/dev/null || true)

    info "Открываю ссылку в Safari — нажми «Загрузить» (⌘S / кнопка скачивания)."
    open -a Safari "$url"

    info "Жду появления нового .zip в ~/Downloads (до 5 мин)…"
    local waited=0 found=""
    while (( waited < 300 )); do
        sleep 3; waited=$(( waited + 3 ))
        local newest
        newest=$(ls -1t "$DOWNLOADS"/*.zip 2>/dev/null | head -1 || true)
        # новый (не был в before) и докачан (нет соседнего .download)
        if [[ -n "$newest" ]] \
           && ! grep -qxF "$newest" <<< "$before" \
           && [[ ! -e "${newest}.download" ]]; then
            found="$newest"; break
        fi
        printf '.' >&2
    done
    echo >&2
    [[ -n "$found" ]] || die "За 5 минут новый .zip в ~/Downloads не появился. Скачал ли файл? Можно указать путь напрямую: mh-deploy --file <путь>"
    ok "Скачан: $found"
    printf '%s' "$found"
}

# ─── Заливка файла на сервер + установка (режимы 1 и 3) ──────────────
deploy_file() {
    local f="$1"
    [[ -f "$f" ]] || die "Файл не найден: $f"
    [[ "$(head -c 2 "$f" 2>/dev/null || true)" == "PK" ]] || die "Это не ZIP-архив: $f"

    [[ -n "$SLUG" ]] || SLUG=$(slug_from "$f")
    [[ -n "$SLUG" ]] || die "Не удалось вывести слаг из имени '$f' — задай явно: -s <slug>"
    validate_slug

    local size; size=$(du -h "$f" | cut -f1)
    # безопасное имя на сервере: слаг определяем ЛОКАЛЬНО и передаём через -s,
    # поэтому имя загрузки может быть любым — берём предсказуемое.
    local remote="/tmp/mh-upload-${SLUG}.zip"

    info "Заливаю на ${SERVER}: $(basename "$f") (${size}) → ${remote}"
    scp "$f" "${SERVER}:${remote}" >&2 || die "scp не удался"
    ok "Файл на сервере"

    info "Запускаю установщик (домен ${DOMAIN}, слаг ${SLUG})…"
    ssh "$SERVER" "curl -fsSL '$RAW_HTML' -o /tmp/mh-inst.sh \
        && sudo bash /tmp/mh-inst.sh -a '$remote' -d '$DOMAIN' -s '$SLUG' --yes; \
        rc=\$?; rm -f '$remote' /tmp/mh-inst.sh; exit \$rc" \
        || die "Установка на сервере завершилась с ошибкой"
}

# ─── Установка с публичной ссылки (режим 2, сервер качает сам) ───────
deploy_url() {
    local url="$1"
    case "$url" in *\'*) die "URL содержит одинарную кавычку — так нельзя";; esac
    local slug_opt=""
    [[ -n "$SLUG" ]] && { validate_slug; slug_opt="-s '$SLUG'"; }

    info "Сервер ${SERVER} скачает сам (резолвер): $url"
    ssh "$SERVER" "curl -fsSL '$RAW_HTML' | sudo bash -s -- --url '$url' -d '$DOMAIN' $slug_opt --yes" \
        || die "Установка на сервере завершилась с ошибкой"
}

# ─── Интерактивное меню (если источник не задан флагом) ──────────────
interactive() {
    echo -e "${B}=== Деплой 3D-тура на ${SERVER} (${DOMAIN}) ===${N}" >&2
    echo "" >&2
    echo -e "  ${B}1)${N} Файл на маке / в iCloud Drive" >&2
    echo -e "  ${B}2)${N} Публичная ссылка (Я.Диск/GDrive/Dropbox/OneDrive/Mail.ru)" >&2
    echo -e "  ${B}3)${N} Приватный iCloud-шар (открою в Safari)" >&2
    echo "" >&2
    local choice; read -r -p "Выбор [1/2/3]: " choice

    case "$choice" in
        1)
            local p; read -r -e -p "Путь к .zip (можно перетащить файл в терминал): " p
            p=$(clean_path "$p")
            SRC_FILE="$p" ;;
        2)
            local u; read -r -p "Публичная ссылка: " u
            SRC_URL="$u" ;;
        3)
            local u; read -r -p "Ссылка iCloud-шара: " u
            SRC_ICLOUD="$u" ;;
        *) die "Неверный выбор" ;;
    esac
}

# ─── main ────────────────────────────────────────────────────────────
main() {
    validate_domain
    validate_server

    # если ни один источник не задан флагом — спросить
    if [[ -z "$SRC_FILE$SRC_URL$SRC_ICLOUD" ]]; then
        interactive
    fi

    if [[ -n "$SRC_FILE" ]]; then
        deploy_file "$(clean_path "$SRC_FILE")"
    elif [[ -n "$SRC_URL" ]]; then
        deploy_url "$SRC_URL"
    elif [[ -n "$SRC_ICLOUD" ]]; then
        local f; f=$(fetch_via_safari "$SRC_ICLOUD")
        deploy_file "$f"
    else
        die "Источник не задан"
    fi

    echo "" >&2
    # в --url режиме слаг мог не задаваться (установщик берёт его из имени архива сам) —
    # тогда точного адреса мы не знаем, не печатаем битый https://DOMAIN//
    if [[ -n "$SLUG" ]]; then
        ok "Готово. Тур: ${G}https://${DOMAIN}/${SLUG}/${N}"
        info "Проверь в браузере: https://${DOMAIN}/${SLUG}/"
    else
        ok "Готово."
        info "Слаг не задавался — фактический адрес тура смотри в выводе установщика выше."
    fi
}

main
