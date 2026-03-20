#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════╗
# ║  Matterport HTML Tour — Установщик v1.0                             ║
# ║                                                                      ║
# ║  Устанавливает self-hosted Matterport HTML-экспорт на сервер:        ║
# ║    • Распаковывает архив БЕЗ модификации файлов                      ║
# ║    • Nginx sub_filter: CDN → локальные пути, inject аватаров         ║
# ║    • PHP graph_router: GraphQL API stubs для Showcase                ║
# ║    • CORS, root-level rewrites, кеширование                         ║
# ║                                                                      ║
# ║  Требования: Nginx, PHP-FPM (для GraphQL роутера), Python3          ║
# ║  Принцип: файлы тура НЕ изменяются — все трансформации через nginx   ║
# ╚═══════════════════════════════════════════════════════════════════════╝

# ─── Обработка curl | bash (stdin занят пайпом) ──────────────────────
if [ ! -t 0 ]; then
    _SELF="/tmp/mh-html-installer-$$.sh"
    cat > "$_SELF" < /dev/stdin 2>/dev/null || true
    if [ ! -s "$_SELF" ] && [ -f "$0" ]; then
        cp "$0" "$_SELF"
    fi
    if [ ! -s "$_SELF" ]; then
        _URL="https://raw.githubusercontent.com/verbovoj/matterhub-installer/main/scripts/matterhub-html-installer.sh"
        curl -sSL "$_URL" -o "$_SELF" 2>/dev/null || wget -qO "$_SELF" "$_URL" 2>/dev/null
    fi
    chmod +x "$_SELF"
    exec bash "$_SELF" "$@" < /dev/tty
fi

set -euo pipefail

# ─── Цвета ───────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ─── Глобальные переменные ───────────────────────────────────────────
VERSION="1.0.0"
LOG="/tmp/mh-html-install-$(date +%Y%m%d_%H%M%S).log"
ROLLBACK=()
INSTALL_OWNER=""
INSTALL_GROUP=""

ARCHIVE_SRC=""
ARCHIVE_FILE=""
DOMAIN=""
SLUG=""
WEBROOT=""
NGINX_CONF=""
PHP_SOCK=""
AUTO_YES=false
DO_UNINSTALL=false
INSTALL_DIR=""

# ─── Логирование (всё в stderr, чтобы не ломать $() captures) ────────
log()  { echo -e "${GREEN}[✓]${NC} $*" >&2; echo "[$(date '+%H:%M:%S')] $*" >> "$LOG"; }
info() { echo -e "${BLUE}[i]${NC} $*" >&2; echo "[$(date '+%H:%M:%S')] INFO: $*" >> "$LOG"; }
warn() { echo -e "${YELLOW}[!]${NC} $*" >&2; echo "[$(date '+%H:%M:%S')] WARN: $*" >> "$LOG"; }
err()  { echo -e "${RED}[✗]${NC} $*" >&2; echo "[$(date '+%H:%M:%S')] ERROR: $*" >> "$LOG"; exit 1; }

confirm() {
    if $AUTO_YES; then return 0; fi
    echo -en "${CYAN}[?]${NC} $* [y/N] "
    read -r ans
    [[ "$ans" =~ ^[Yy] ]]
}

register_rollback() { ROLLBACK+=("$1"); }

do_rollback() {
    if [[ ${#ROLLBACK[@]} -eq 0 ]]; then return; fi
    warn "Откат изменений..."
    for ((i=${#ROLLBACK[@]}-1; i>=0; i--)); do
        eval "${ROLLBACK[$i]}" 2>/dev/null || true
    done
    log "Откат завершён"
}
trap 'do_rollback' ERR

# ─── Справка ─────────────────────────────────────────────────────────
usage() {
    cat << 'EOF'
Matterport HTML Tour Installer v1.0

Использование:
  matterhub-html-installer.sh [OPTIONS]

Опции:
  --url URL                URL или путь к ZIP-архиву (слаг из имени файла)
  -a, --archive URL|PATH   Аналог --url
  -d, --domain DOMAIN      Домен сайта (авто-определение из Nginx)
  -s, --slug SLUG          URL-слаг тура (авто-определение из имени архива)
  -w, --webroot PATH       Путь к webroot (авто-определение)
  -n, --nginx-conf PATH    Путь к конфигу Nginx (авто-определение)
  -p, --php-sock PATH      Путь к PHP-FPM сокету (авто-определение)
  -y, --yes                Автоподтверждение всех вопросов
  --uninstall              Удалить тур (нужны --domain и --slug)
  -h, --help               Показать справку

Примеры:
  # Один флаг — слаг и домен определятся автоматически:
  matterhub-html-installer.sh --url https://s16.matterhub.ru/downloads/jr4uZUoEhzK.zip --yes

  # Явный домен и слаг:
  matterhub-html-installer.sh -a ./tour.zip -d yr2.ru -s mySlug

  # Деинсталляция:
  matterhub-html-installer.sh --uninstall -d yr2.ru -s mySlug

  # curl | bash:
  curl -sSL https://raw.githubusercontent.com/verbovoj/matterhub-installer/main/scripts/matterhub-html-installer.sh | sudo bash -s -- --url "https://example.com/jr4uZUoEhzK.zip" --yes
EOF
    exit 0
}

# ─── Парсинг аргументов ──────────────────────────────────────────────
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --url|-a|--archive) ARCHIVE_SRC="$2"; shift 2 ;;
            -d|--domain)     DOMAIN="$2"; shift 2 ;;
            -s|--slug)       SLUG="$2"; shift 2 ;;
            -w|--webroot)    WEBROOT="$2"; shift 2 ;;
            -n|--nginx-conf) NGINX_CONF="$2"; shift 2 ;;
            -p|--php-sock)   PHP_SOCK="$2"; shift 2 ;;
            -y|--yes)        AUTO_YES=true; shift ;;
            --uninstall)     DO_UNINSTALL=true; shift ;;
            -h|--help)       usage ;;
            *) err "Неизвестный аргумент: $1" ;;
        esac
    done
}

# ─── Валидация слага ──────────────────────────────────────────────────
validate_slug() {
    if [[ ! "$SLUG" =~ ^[a-zA-Z0-9]{4,}$ ]]; then
        err "Слаг '$SLUG' некорректен (буквы и цифры, минимум 4 символа)"
    fi
}

# ─── Авто-определение домена из Nginx конфигов ───────────────────────
# Собирает ВСЕ домены с валидным webroot (результат через \n)
auto_detect_all_domains() {
    local -a found=()
    local -A seen=()
    for f in /etc/nginx/sites-enabled/* /etc/nginx/conf.d/*.conf; do
        [[ -f "$f" ]] || continue
        local sn
        sn=$(grep -oP 'server_name\s+\K[^;]+' "$f" 2>/dev/null | head -1 | awk '{print $1}')
        [[ -z "$sn" || "$sn" == "_" || "$sn" == "localhost" ]] && continue
        [[ -n "${seen[$sn]:-}" ]] && continue
        for wr in \
            "/home/admin/web/${sn}/public_html" \
            "/var/www/${sn}/data/www/${sn}" \
            "/var/www/${sn}/public_html" \
            "/var/www/${sn}"; do
            if [[ -d "$wr" ]]; then
                found+=("$sn")
                seen[$sn]=1
                break
            fi
        done
    done
    printf '%s\n' "${found[@]}"
}

# Интерактивный выбор домена: меню если >1, авто если 1, ручной ввод если 0
choose_domain() {
    local -a domains=()
    while IFS= read -r d; do
        [[ -n "$d" ]] && domains+=("$d")
    done < <(auto_detect_all_domains)

    if [[ ${#domains[@]} -eq 0 ]]; then
        echo ""
        return
    fi

    if [[ ${#domains[@]} -eq 1 ]]; then
        info "Домен определён из Nginx: ${domains[0]}"
        echo "${domains[0]}"
        return
    fi

    # Несколько доменов — показываем меню
    echo "" >&2
    echo -e "${BOLD}Найдены домены:${NC}" >&2
    local idx=0
    for d in "${domains[@]}"; do
        idx=$((idx+1))
        echo -e "  ${BOLD}${idx})${NC} ${CYAN}${d}${NC}" >&2
    done
    echo "" >&2

    if $AUTO_YES; then
        # --yes: берём первый, но предупреждаем
        warn "Несколько доменов — выбран первый: ${domains[0]} (передайте -d ДОМЕН для явного выбора)"
        echo "${domains[0]}"
        return
    fi

    local choice
    echo -en "${CYAN}[?]${NC} Выберите домен (1-${#domains[@]}): " >&2
    read -r choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le ${#domains[@]} ]]; then
        echo "${domains[$((choice-1))]}"
    else
        err "Неверный выбор: $choice"
    fi
}

# ─── Определение окружения ───────────────────────────────────────────
detect_environment() {
    # Root
    if [[ $EUID -ne 0 ]]; then
        err "Скрипт требует root. Запустите через sudo."
    fi

    # Nginx
    command -v nginx &>/dev/null || err "Nginx не найден"

    # Python3
    command -v python3 &>/dev/null || err "Python3 не найден (нужен для обработки nginx конфига)"

    # PHP-FPM сокет
    if [[ -z "$PHP_SOCK" ]]; then
        for sock in \
            "/run/php/php8.3-fpm-${DOMAIN}.sock" \
            "/run/php/php8.2-fpm-${DOMAIN}.sock" \
            "/run/php/php8.1-fpm-${DOMAIN}.sock" \
            /run/php/php*-fpm.sock \
            /var/run/php-fpm/*.sock; do
            if [[ -S "$sock" ]]; then
                PHP_SOCK="$sock"
                break
            fi
        done
    fi
    if [[ -z "$PHP_SOCK" ]]; then
        local fpm_service
        fpm_service=$(systemctl list-units --type=service --state=running 2>/dev/null \
                      | grep -oP 'php[\d.]+-fpm' | head -1 || true)
        if [[ -n "$fpm_service" ]]; then
            local pv="${fpm_service#php}"; pv="${pv%-fpm}"
            for c in "/run/php/php${pv}-fpm-${DOMAIN}.sock" "/run/php/php${pv}-fpm.sock"; do
                [[ -S "$c" ]] && { PHP_SOCK="$c"; break; }
            done
        fi
    fi
    if [[ -z "$PHP_SOCK" ]]; then
        warn "PHP-FPM сокет не найден — GraphQL роутер может не работать"
        PHP_SOCK="/run/php/php8.3-fpm.sock"
    fi
    log "PHP-FPM: $PHP_SOCK"

    # Webroot
    if [[ -z "$WEBROOT" ]]; then
        for candidate in \
            "/home/admin/web/${DOMAIN}/public_html" \
            "/var/www/${DOMAIN}/data/www/${DOMAIN}" \
            "/var/www/${DOMAIN}/public_html" \
            "/var/www/${DOMAIN}" \
            "/var/www/html"; do
            if [[ -d "$candidate" ]]; then
                WEBROOT="$candidate"
                break
            fi
        done
    fi
    [[ -z "$WEBROOT" ]] && err "Не удалось определить webroot. Укажите --webroot"
    [[ -d "$WEBROOT" ]] || err "Webroot не существует: $WEBROOT"
    log "Webroot: $WEBROOT"

    INSTALL_DIR="${WEBROOT}/${SLUG}"

    # Nginx конфиг
    if [[ -z "$NGINX_CONF" ]]; then
        for candidate in \
            "/etc/nginx/sites-enabled/${DOMAIN}" \
            "/etc/nginx/sites-enabled/${DOMAIN}.conf" \
            "/etc/nginx/conf.d/${DOMAIN}.conf" \
            "/etc/nginx/conf.d/domains/${DOMAIN}.conf"; do
            if [[ -f "$candidate" ]]; then
                NGINX_CONF="$candidate"
                break
            fi
        done
    fi
    [[ -n "$NGINX_CONF" && -f "$NGINX_CONF" ]] || err "Nginx конфиг не найден для $DOMAIN. Укажите --nginx-conf"
    log "Nginx конфиг: $NGINX_CONF"
}

# ─── Скачивание архива ────────────────────────────────────────────────
download_archive() {
    [[ -z "$ARCHIVE_SRC" ]] && err "Укажите архив через --archive"

    if [[ -f "$ARCHIVE_SRC" ]]; then
        ARCHIVE_FILE="$ARCHIVE_SRC"
        log "Архив: $ARCHIVE_FILE (локальный)"
        return
    fi

    [[ "$ARCHIVE_SRC" =~ ^https?:// ]] || err "Не файл и не HTTP URL: $ARCHIVE_SRC"

    ARCHIVE_FILE="/tmp/mh-html-tour-${SLUG}.zip"
    info "Скачиваю: $ARCHIVE_SRC"
    if command -v curl &>/dev/null; then
        curl -fSL --progress-bar "$ARCHIVE_SRC" -o "$ARCHIVE_FILE"
    elif command -v wget &>/dev/null; then
        wget --show-progress -qO "$ARCHIVE_FILE" "$ARCHIVE_SRC"
    else
        err "Нет curl/wget"
    fi

    local size
    size=$(stat -c%s "$ARCHIVE_FILE" 2>/dev/null || stat -f%z "$ARCHIVE_FILE" 2>/dev/null)
    if [[ "$size" -lt 1000 ]]; then
        head -c 500 "$ARCHIVE_FILE" >&2
        rm -f "$ARCHIVE_FILE"
        err "Файл слишком мал ($size байт) — ошибка скачивания?"
    fi
    log "Скачано: $(numfmt --to=iec "$size" 2>/dev/null || echo "${size} bytes")"
}

# ─── Распаковка ──────────────────────────────────────────────────────
extract_archive() {
    if [[ -d "$INSTALL_DIR" ]]; then
        warn "Директория $INSTALL_DIR уже существует"
        if ! confirm "Перезаписать?"; then
            err "Отменено"
        fi
        local backup="${INSTALL_DIR}.bak.$(date +%Y%m%d_%H%M%S)"
        mv "$INSTALL_DIR" "$backup"
        register_rollback "rm -rf '${INSTALL_DIR}'; mv '${backup}' '${INSTALL_DIR}'"
        log "Бэкап каталога: $backup"
    fi

    mkdir -p "$INSTALL_DIR"

    local tmp_dir
    tmp_dir=$(mktemp -d)
    info "Распаковка..."

    unzip -q "$ARCHIVE_FILE" -d "$tmp_dir" 2>>"$LOG" \
        || tar -xzf "$ARCHIVE_FILE" -C "$tmp_dir" 2>>"$LOG" \
        || tar -xf "$ARCHIVE_FILE" -C "$tmp_dir" 2>>"$LOG" \
        || { rm -rf "$tmp_dir"; err "Не удалось распаковать архив"; }

    # Ищем корень тура: index.html + js/
    local tour_root=""
    if [[ -f "$tmp_dir/index.html" && -d "$tmp_dir/js" ]]; then
        tour_root="$tmp_dir"
    else
        local found
        found=$(find "$tmp_dir" -maxdepth 3 -name "index.html" -type f 2>/dev/null | while read -r f; do
            local d; d=$(dirname "$f")
            [[ -d "$d/js" ]] && echo "$d" && break
        done)
        [[ -n "$found" ]] && tour_root="$found"
    fi

    [[ -z "$tour_root" ]] && { rm -rf "$tmp_dir"; err "index.html + js/ не найдены в архиве"; }

    cp -a "$tour_root"/. "$INSTALL_DIR"/
    rm -rf "$tmp_dir"

    # Владелец файлов — наследуем от webroot, а не гадаем по сервисному юзеру.
    # Для панелей вроде Hestia это критично: webroot часто принадлежит admin:admin.
    local owner group
    owner=$(stat -c '%U' "$WEBROOT" 2>/dev/null || stat -f '%Su' "$WEBROOT" 2>/dev/null || echo "www-data")
    group=$(stat -c '%G' "$WEBROOT" 2>/dev/null || stat -f '%Sg' "$WEBROOT" 2>/dev/null || echo "www-data")
    if [[ -z "$owner" || "$owner" == "root" ]]; then
        owner="www-data"
        id "$owner" &>/dev/null || owner="nginx"
        id "$owner" &>/dev/null || owner="nobody"
    fi
    if [[ -z "$group" || "$group" == "root" ]]; then
        group="$owner"
    fi
    INSTALL_OWNER="$owner"
    INSTALL_GROUP="$group"
    chown -R "$owner":"$group" "$INSTALL_DIR" 2>/dev/null || true

    log "Распаковано: $INSTALL_DIR ($(du -sh "$INSTALL_DIR" | cut -f1))"
}

bootstrap_av3_resources() {
    info "Создаю AV3 resources bootstrap..."

    local owner="${INSTALL_OWNER:-}"
    local group="${INSTALL_GROUP:-}"
    if [[ -z "$owner" ]]; then
        owner=$(stat -c '%U' "$WEBROOT" 2>/dev/null || stat -f '%Su' "$WEBROOT" 2>/dev/null || echo "www-data")
    fi
    if [[ -z "$group" ]]; then
        group=$(stat -c '%G' "$WEBROOT" 2>/dev/null || stat -f '%Sg' "$WEBROOT" 2>/dev/null || echo "$owner")
    fi
    [[ -z "$owner" || "$owner" == "root" ]] && owner="www-data"
    [[ -z "$group" || "$group" == "root" ]] && group="$owner"

    mkdir -p "${INSTALL_DIR}/resources/av3_data"
    mkdir -p "${INSTALL_DIR}/resources/models/avatar"
    mkdir -p "${INSTALL_DIR}/resources/media/face"
    mkdir -p "${INSTALL_DIR}/resources/media/video_avatar"
    mkdir -p "${INSTALL_DIR}/resources/animations"
    mkdir -p "${INSTALL_DIR}/resources/panorama_override"
    mkdir -p "${INSTALL_DIR}/resources/output"

    chown -R "$owner:$group" "${INSTALL_DIR}/resources" 2>/dev/null || true
    find "${INSTALL_DIR}/resources" -type d -exec chmod 775 {} \; 2>/dev/null || true
    find "${INSTALL_DIR}/resources" -type f -exec chmod 664 {} \; 2>/dev/null || true

    log "AV3 resources bootstrap: OK (${owner}:${group})"
}

# ─── GraphQL роутер ──────────────────────────────────────────────────
create_graph_router() {
    local api_dir="${INSTALL_DIR}/api/mp/models"
    mkdir -p "$api_dir"
    mkdir -p "${INSTALL_DIR}/api/mp/accounts"

    cat > "${api_dir}/graph_router.php" << 'ROUTER_PHP'
<?php
/**
 * Matterport GraphQL stub router.
 * Routes by operationName to graph_*.json files.
 * Handles both POST (body) and GET (query param) requests.
 */
header('Content-Type: application/json');
header('Access-Control-Allow-Origin: *');
header('Access-Control-Allow-Methods: GET, POST, OPTIONS');
header('Access-Control-Allow-Headers: Content-Type');

if ($_SERVER['REQUEST_METHOD'] === 'OPTIONS') {
    http_response_code(204);
    exit;
}

$subdir = isset($_SERVER['GRAPH_SUBDIR']) ? $_SERVER['GRAPH_SUBDIR'] : 'models';
if (!in_array($subdir, ['models', 'accounts', 'attachments'], true)) {
    echo '{"data":null}';
    exit;
}

if ($subdir === 'accounts') {
    echo '{"data":{"currentSession":null}}';
    exit;
}

$op = '';
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $body = json_decode(file_get_contents('php://input'), true);
    $op = isset($body['operationName']) ? $body['operationName'] : '';
} else {
    $op = isset($_GET['operationName']) ? $_GET['operationName'] : '';
}

$op = preg_replace('/[^a-zA-Z0-9_]/', '', $op);

$dir = __DIR__;
if ($subdir !== 'models') {
    $dir = dirname($dir) . '/' . $subdir;
}
$file = $dir . '/graph_' . $op . '.json';

if ($op !== '' && file_exists($file)) {
    readfile($file);
} else {
    echo '{"data":null}';
}
ROUTER_PHP
    log "GraphQL роутер создан"

    echo -n '{"data":{"currentSession":null}}' > "${INSTALL_DIR}/api/mp/accounts/graph"
    log "accounts/graph stub создан"

    # API v1 stubs (suppress 404 for /api/v1/user/ etc.)
    mkdir -p "${INSTALL_DIR}/api/v1/user"
    echo -n '{"data":null}' > "${INSTALL_DIR}/api/v1/user/index.html"

    # Empty JSON fallback for any unmatched API paths
    echo -n '{"data":null}' > "${api_dir}/graph_empty.json"
    log "API v1 stubs созданы"
}

# ─── Генерация nginx блока (bash heredoc — надёжнее для кавычек) ─────
write_nginx_block() {
    local outfile="$1"

    # Unquoted heredoc: ${SLUG}, ${WEBROOT} etc. expand; \$var stays literal
    cat > "$outfile" << NGINX_BLOCK_EOF

    # ── Root CDN path rewrites for self-hosted HTML tour: ${SLUG} ──
    location /webgl-vendors/ {
        rewrite ^/(.*)\$ /${SLUG}/\$1 last;
    }
    location /showcase-sdk/ {
        rewrite ^/(.*)\$ /${SLUG}/\$1 last;
    }
    location /geoip/ {
        rewrite ^/(.*)\$ /${SLUG}/\$1 last;
    }
    location /unicode-font-resolver/ {
        rewrite ^/(.*)\$ /${SLUG}/\$1 last;
    }

    # ── Root API rewrites for self-hosted HTML tour: ${SLUG} ──
    # GraphQL: direct fastcgi (rewrite+last can't reach nested locations in ^~ blocks)
    location ~ ^/api/mp/([a-z]+)/graph\$ {
        set \$graph_subdir \$1;
        default_type application/json;
        add_header Access-Control-Allow-Origin "*" always;
        add_header Access-Control-Allow-Methods "GET, POST, OPTIONS" always;
        add_header Access-Control-Allow-Headers "Content-Type" always;

        fastcgi_pass unix:${PHP_SOCK};
        fastcgi_param SCRIPT_FILENAME ${INSTALL_DIR}/api/mp/models/graph_router.php;
        fastcgi_param GRAPH_SUBDIR \$graph_subdir;
        include fastcgi_params;
        fastcgi_param REQUEST_URI \$request_uri;
    }
    # Fallback for non-GraphQL /api/mp/ requests (static JSON stubs)
    location /api/mp/ {
        root ${WEBROOT};
        default_type application/json;
        add_header Access-Control-Allow-Origin "*" always;
        rewrite ^/api/mp/(.*)\$ /${SLUG}/api/mp/\$1 break;
        try_files \$uri /${SLUG}/api/mp/models/graph_empty.json;
    }
    location /api/v1/ {
        rewrite ^/api/v1/(.*)\$ /${SLUG}/api/v1/\$1 last;
    }

    # ── Matterport self-hosted HTML tour: ${SLUG} ──
    location ^~ /${SLUG}/ {
        root ${WEBROOT};
        index index.html;

        # Rewrite CDN URLs to local absolute paths
        sub_filter 'https://static.matterport.com/' '/';
        # Remove external Matterport preconnect/prefetch hints
        sub_filter 'https://cdn-2.matterport.com' '';
        sub_filter 'https://events.matterport.com' '';
        # Inject avatar scripts + footer fix (files not modified — sub_filter at serve-time)
        sub_filter '</head>' '<script src="/av3/footer_fix.js"></script><script src="/av3/avatar_inject.js"></script><script src="/av3/ai_avatar.js" defer></script></head>';
        sub_filter_once off;
        sub_filter_types text/html application/javascript text/javascript;

        # CORS
        add_header Access-Control-Allow-Origin "*" always;
        add_header Access-Control-Allow-Methods "GET, POST, OPTIONS" always;
        add_header Access-Control-Allow-Headers "Content-Type" always;

        # JS/CSS: force revalidate (sub_filter changes visible immediately)
        location ~* ^/${SLUG}/.+\.(?:js|mjs|css)\$ {
            root ${WEBROOT};
            try_files \$uri =404;
            etag on;
            expires off;
            add_header Cache-Control "public, no-cache, must-revalidate";
            add_header Access-Control-Allow-Origin "*" always;
            sub_filter 'https://static.matterport.com/' '/';
            sub_filter_once off;
            sub_filter_types application/javascript text/javascript text/css;
        }

        # Allow POST on static files (GraphQL stubs)
        error_page 405 =200 \$uri;

        if (\$request_method = OPTIONS) {
            return 204;
        }

        # GraphQL API router
        location ~ ^/${SLUG}/api/mp/([a-z]+)/graph\$ {
            default_type application/json;
            add_header Access-Control-Allow-Origin "*" always;
            add_header Access-Control-Allow-Methods "GET, POST, OPTIONS" always;
            add_header Access-Control-Allow-Headers "Content-Type" always;

            if (\$request_method = OPTIONS) {
                return 204;
            }

            fastcgi_pass unix:${PHP_SOCK};
            fastcgi_param SCRIPT_FILENAME ${INSTALL_DIR}/api/mp/models/graph_router.php;
            fastcgi_param GRAPH_SUBDIR \$1;
            include fastcgi_params;
            fastcgi_param REQUEST_URI \$request_uri;
        }

        # API — static JSON (return empty JSON for missing stubs instead of 404)
        location ~* ^/${SLUG}/api/ {
            root ${WEBROOT};
            default_type application/json;
            add_header Access-Control-Allow-Origin "*" always;
            add_header Access-Control-Allow-Methods "GET, POST, OPTIONS" always;
            add_header Access-Control-Allow-Headers "Content-Type" always;
            error_page 405 =200 \$uri;

            if (\$request_method = OPTIONS) {
                return 204;
            }

            try_files \$uri \$uri/ /${SLUG}/api/mp/models/graph_empty.json;
        }

        try_files \$uri /${SLUG}/index.html;
    }
NGINX_BLOCK_EOF
}

# ─── Вставка nginx блока ─────────────────────────────────────────────
inject_nginx_block() {
    info "Настраиваю Nginx..."

    # Уже есть?
    if grep -q "location \^~ /${SLUG}/" "$NGINX_CONF" 2>/dev/null; then
        warn "Блок location ^~ /${SLUG}/ уже в $NGINX_CONF"
        if confirm "Пропустить настройку Nginx?"; then
            log "Nginx: пропущено"
            return
        fi
        remove_html_tour_block
    fi

    # Есть ли root CDN rewrites от другого тура?
    local skip_cdn_rewrites=false
    if grep -q "location /webgl-vendors/" "$NGINX_CONF" 2>/dev/null; then
        skip_cdn_rewrites=true
        warn "Root CDN/API rewrites уже есть — пропускаю (возможен конфликт)"
    fi

    # Бэкап
    local bak="${NGINX_CONF}.bak.$(date +%Y%m%d_%H%M%S)"
    cp "$NGINX_CONF" "$bak"
    register_rollback "cp '${bak}' '${NGINX_CONF}' && nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null"
    log "Бэкап Nginx: $bak"

    # Генерируем блок
    local block_file
    block_file=$(mktemp)
    write_nginx_block "$block_file"

    # Удаляем CDN/API rewrites если уже есть
    if $skip_cdn_rewrites; then
        python3 -c "
import sys
p = sys.argv[1]
with open(p, 'r') as f:
    content = f.read()
idx = content.find('# ── Matterport self-hosted')
if idx > 0:
    content = chr(10) + content[idx:]
with open(p, 'w') as f:
    f.write(content)
" "$block_file"
    fi

    # Вставляем
    python3 -c "
import sys

conf_path = sys.argv[1]
block_path = sys.argv[2]

with open(conf_path, 'r') as f:
    content = f.read()

with open(block_path, 'r') as f:
    block = f.read()

# Вставляем перед 'location / {' или перед последним }
insert_marker = '    location / {'
pos = content.rfind(insert_marker)
if pos == -1:
    pos = content.rfind('}')

if pos == -1:
    print('ERROR: не найден } в конфиге', file=sys.stderr)
    sys.exit(1)

new_content = content[:pos] + block + '\n' + content[pos:]
with open(conf_path, 'w') as f:
    f.write(new_content)

print('OK: блок вставлен')
" "$NGINX_CONF" "$block_file"

    rm -f "$block_file"

    if nginx -t 2>>"$LOG"; then
        systemctl reload nginx
        log "Nginx: блок /${SLUG} добавлен и загружен"
    else
        local err_msg
        err_msg=$(nginx -t 2>&1 || true)
        warn "Ошибка Nginx: $err_msg"
        cp "$bak" "$NGINX_CONF"
        nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null
        err "Nginx некорректен. Бэкап восстановлен: $bak"
    fi
}

# ─── Удаление блока из nginx ─────────────────────────────────────────
remove_html_tour_block() {
    info "Удаляю блок /${SLUG} из Nginx..."

    local bak="${NGINX_CONF}.bak.$(date +%Y%m%d_%H%M%S)"
    cp "$NGINX_CONF" "$bak"

    python3 -c "
import re, sys

slug = sys.argv[1]
conf_path = sys.argv[2]

with open(conf_path, 'r') as f:
    content = f.read()

# 1) Remove root CDN rewrites for this slug
cdn_pat = (
    r'\n\s*# ── Root CDN path rewrites for self-hosted HTML tour: '
    + re.escape(slug)
    + r' ──\n.*?(?=\n\s*# ── Matterport|\n\s*# ── Root API|\n\s*location [^/\s]|\n\s*location /av3|\n\s*location /api/avatar|\n\s*location \^~)'
)
content = re.sub(cdn_pat, '', content, flags=re.DOTALL)

# 2) Remove root API rewrites for this slug
api_pat = (
    r'\n\s*# ── Root API rewrites for self-hosted HTML tour: '
    + re.escape(slug)
    + r' ──\n.*?(?=\n\s*# ── Matterport|\n\s*location [^/\s]|\n\s*location /av3|\n\s*location /api/avatar|\n\s*location \^~)'
)
content = re.sub(api_pat, '', content, flags=re.DOTALL)

# 3) Remove location ^~ /SLUG/ block (track brace nesting)
tour_comment = '# ── Matterport self-hosted HTML tour: ' + slug + ' ──'
idx = content.find(tour_comment)
if idx != -1:
    line_start = content.rfind('\n', 0, idx)
    if line_start == -1:
        line_start = 0

    loc_str = 'location ^~ /' + slug + '/ {'
    brace_idx = content.find(loc_str, idx)
    if brace_idx != -1:
        brace_open = content.index('{', brace_idx)
        depth = 1
        pos = brace_open + 1
        while pos < len(content) and depth > 0:
            if content[pos] == '{':
                depth += 1
            elif content[pos] == '}':
                depth -= 1
            pos += 1
        while pos < len(content) and content[pos] in ' \t\r\n':
            pos += 1
        content = content[:line_start] + '\n' + content[pos:]

with open(conf_path, 'w') as f:
    f.write(content)

print(f'OK: блок /{slug} удалён')
" "$SLUG" "$NGINX_CONF"

    if nginx -t 2>>"$LOG"; then
        systemctl reload nginx
        log "Nginx: блок удалён и перезагружен"
    else
        warn "Ошибка после удаления! Восстанавливаю бэкап..."
        cp "$bak" "$NGINX_CONF"
        nginx -t && systemctl reload nginx
    fi
}

# ─── Деинсталляция ───────────────────────────────────────────────────
do_uninstall() {
    validate_slug
    detect_environment

    echo ""
    echo -e "${BOLD}Удаление тура: /${SLUG}${NC}"
    echo -e "  Домен:    ${CYAN}${DOMAIN}${NC}"
    echo -e "  Каталог:  ${CYAN}${INSTALL_DIR}${NC}"
    echo -e "  Nginx:    ${CYAN}${NGINX_CONF}${NC}"
    echo ""

    confirm "Удалить тур /${SLUG}?" || { info "Отменено"; exit 0; }

    if grep -q "location \^~ /${SLUG}/" "$NGINX_CONF" 2>/dev/null; then
        remove_html_tour_block
    else
        info "Блок Nginx для /${SLUG} не найден"
    fi

    if [[ -d "$INSTALL_DIR" ]]; then
        if confirm "Удалить файлы тура? ($INSTALL_DIR)"; then
            rm -rf "$INSTALL_DIR"
            log "Файлы удалены: $INSTALL_DIR"
        fi
    fi

    echo ""
    log "Тур /${SLUG} деинсталлирован"
}

# ─── Проверка ─────────────────────────────────────────────────────────
verify_install() {
    info "Проверка..."
    local ok=true

    [[ -f "${INSTALL_DIR}/index.html" ]] || { warn "index.html не найден!"; ok=false; }
    [[ -d "${INSTALL_DIR}/js" ]]         || { warn "js/ не найден!"; ok=false; }
    [[ -f "${INSTALL_DIR}/api/mp/models/graph_router.php" ]] || { warn "graph_router.php не найден!"; ok=false; }
    nginx -t 2>/dev/null || { warn "Nginx конфиг некорректен!"; ok=false; }

    local url="https://${DOMAIN}/${SLUG}/"
    local code
    code=$(curl -sS -o /dev/null -w "%{http_code}" --max-time 10 "$url" 2>/dev/null || echo "000")
    if [[ "$code" == "200" ]]; then
        log "HTTP $code — $url"
    else
        warn "HTTP $code — $url (ожидался 200)"
        ok=false
    fi

    if curl -sS --max-time 10 "$url" 2>/dev/null | grep -q "avatar_inject"; then
        log "Avatar inject — ✓"
    else
        warn "Avatar inject не найден в HTML"
    fi

    $ok && log "Все проверки пройдены" || warn "Есть проблемы (см. выше)"
}

# ─── Финальный вывод ──────────────────────────────────────────────────
print_summary() {
    echo ""
    echo -e "${GREEN}╔═════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║${NC}  ${BOLD}Matterport HTML Tour — установлен!${NC}                   ${GREEN}║${NC}"
    echo -e "${GREEN}╚═════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${BOLD}URL:${NC}        ${CYAN}https://${DOMAIN}/${SLUG}/${NC}"
    echo -e "  ${BOLD}Каталог:${NC}    ${CYAN}${INSTALL_DIR}${NC}"
    echo -e "  ${BOLD}Nginx:${NC}      ${CYAN}${NGINX_CONF}${NC}"
    echo -e "  ${BOLD}PHP-FPM:${NC}    ${CYAN}${PHP_SOCK}${NC}"
    echo ""
    echo -e "  ${BOLD}Принцип:${NC}    Файлы тура НЕ изменены"
    echo -e "  ${BOLD}Avatar:${NC}     Инжект через nginx sub_filter"
    echo -e "  ${BOLD}GraphQL:${NC}    graph_router.php (единственный созданный файл)"
    echo ""
    echo -e "  ${YELLOW}Деинсталляция:${NC}"
    echo -e "    $0 --uninstall -d ${DOMAIN} -s ${SLUG}"
    echo ""
    echo -e "  ${BOLD}Лог:${NC}        ${LOG}"
    echo ""
}

# ═════════════════════════════════════════════════════════════════════
# MAIN
# ═════════════════════════════════════════════════════════════════════
main() {
    echo ""
    echo -e "${BOLD}Matterport HTML Tour Installer v${VERSION}${NC}"
    echo ""

    parse_args "$@"

    if $DO_UNINSTALL; then
        [[ -z "$DOMAIN" || -z "$SLUG" ]] && err "Для деинсталляции нужны --domain и --slug"
        do_uninstall
        exit 0
    fi

    # Авто-извлечение slug из имени архива
    if [[ -z "$SLUG" && -n "$ARCHIVE_SRC" ]]; then
        local fname
        fname=$(basename "$ARCHIVE_SRC")
        fname="${fname%%.*}"
        fname=$(echo "$fname" | tr -cd '[:alnum:]_-')
        if [[ -n "$fname" ]]; then
            SLUG="$fname"
            info "Слаг из имени архива: $SLUG"
        fi
    fi

    # Авто-определение домена
    if [[ -z "$DOMAIN" ]]; then
        DOMAIN=$(choose_domain)
    fi

    # Интерактивный ввод
    if [[ -z "$DOMAIN" ]]; then
        echo -en "${CYAN}[?]${NC} Домен (напр. yr2.ru): "
        read -r DOMAIN
        [[ -z "$DOMAIN" ]] && err "Домен обязателен"
    fi

    if [[ -z "$SLUG" ]]; then
        echo -en "${CYAN}[?]${NC} URL-слаг тура: "
        read -r SLUG
        [[ -z "$SLUG" ]] && err "Слаг обязателен"
    fi
    validate_slug

    if [[ -z "$ARCHIVE_SRC" ]]; then
        echo -en "${CYAN}[?]${NC} URL или путь к архиву: "
        read -r ARCHIVE_SRC
        [[ -z "$ARCHIVE_SRC" ]] && err "Архив обязателен"
    fi

    detect_environment

    echo ""
    echo -e "  ${BOLD}Домен:${NC}    ${CYAN}${DOMAIN}${NC}"
    echo -e "  ${BOLD}Слаг:${NC}     ${CYAN}${SLUG}${NC}"
    echo -e "  ${BOLD}Webroot:${NC}  ${CYAN}${WEBROOT}${NC}"
    echo -e "  ${BOLD}Каталог:${NC}  ${CYAN}${INSTALL_DIR}${NC}"
    echo -e "  ${BOLD}Nginx:${NC}    ${CYAN}${NGINX_CONF}${NC}"
    echo -e "  ${BOLD}PHP-FPM:${NC}  ${CYAN}${PHP_SOCK}${NC}"
    echo ""

    confirm "Продолжить установку?" || { info "Отменено"; exit 0; }

    download_archive
    extract_archive
    bootstrap_av3_resources
    create_graph_router
    inject_nginx_block
    verify_install
    print_summary
}

main "$@"
