#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════╗
# ║  MatterHub Tour — Универсальный автоустановщик v3.0                 ║
# ║                                                                      ║
# ║  Работает на ЛЮБОМ Linux-сервере:                                    ║
# ║    • Apache / Nginx / Nginx+Apache (reverse proxy)                   ║
# ║    • HestiaCP, VestaCP, ISPmanager, cPanel, Plesk, без панели        ║
# ║    • PHP 8.2 (через PPA, изолированный FPM-пул для MatterHub)        ║
# ║    • ionCube Loader (только для PHP-версии тура)                     ║
# ║                                                                      ║
# ║  Принцип: изолированная установка — НЕ трогает существующие конфиги  ║
# ║  • PHP 8.2 ставится ПАРАЛЛЕЛЬНО другим версиям                       ║
# ║  • Отдельный FPM-пул «matterhub» со своим сокетом                    ║
# ║  • Nginx location только для тура, не трогает другие сайты           ║
# ╚═══════════════════════════════════════════════════════════════════════╝
set -euo pipefail

# ─── Цвета ───────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ─── Глобальные переменные ───────────────────────────────────────────
VERSION="3.0.0"
LOG="/tmp/matterhub-install-$(date +%Y%m%d_%H%M%S).log"
ROLLBACK=()

# Определяемые автоматически
WEB_SERVER=""        # nginx | apache | nginx+apache
PHP_VER=""           # 8.3, 8.2, 8.1, 7.4 ...
PHP_BIN=""           # /usr/bin/php8.3
IONCUBE_OK=false
PANEL=""             # hestia | vesta | ispmanager | cpanel | plesk | none
PANEL_BIN=""         # /usr/local/hestia/bin  (если есть)

# Вводимые пользователем
INSTALL_DIR=""       # Куда распаковывать тур
ARCHIVE_SRC=""       # URL или путь к архиву
ARCHIVE_FILE=""      # Локальный путь к скачанному архиву
AUTO_YES=false       # --yes / -y — автоподтверждение

# ─── Утилиты ─────────────────────────────────────────────────────────
log()  { echo -e "${GREEN}[✓]${NC} $*"; echo "[$(date +%T)] OK   $*" >> "$LOG"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; echo "[$(date +%T)] WARN $*" >> "$LOG"; }
err()  { echo -e "${RED}[✗]${NC} $*"; echo "[$(date +%T)] ERR  $*" >> "$LOG"; }
info() { echo -e "${CYAN}[i]${NC} $*"; echo "[$(date +%T)] INFO $*" >> "$LOG"; }

ask() {
    local prompt="$1" default="${2:-}" result
    # В --yes режиме возвращаем дефолт без чтения stdin
    if $AUTO_YES && [[ -n "$default" ]]; then
        echo -e "${CYAN}$prompt${NC} [${BOLD}$default${NC}]: $default (--yes)" >&2
        echo "$default"
        return
    fi
    if [[ -n "$default" ]]; then
        echo -en "${CYAN}$prompt${NC} [${BOLD}$default${NC}]: " >&2; read -r result
        echo "${result:-$default}"
    else
        echo -en "${CYAN}$prompt${NC}: " >&2; read -r result; echo "$result"
    fi
}

confirm() {
    if $AUTO_YES; then
        echo -e "${YELLOW}$1${NC} [${2:-y}]: y (--yes)" >&2
        return 0
    fi
    local yn; echo -en "${YELLOW}$1${NC} [${2:-y}]: " >&2; read -r yn
    yn="${yn:-${2:-y}}"; [[ "$yn" =~ ^[Yy] ]]
}

register_rollback() { ROLLBACK+=("$1"); }

do_rollback() {
    [[ ${#ROLLBACK[@]} -eq 0 ]] && return
    echo ""; warn "Откатываю изменения..."
    for (( i=${#ROLLBACK[@]}-1; i>=0; i-- )); do
        info "  <- ${ROLLBACK[$i]}"
        eval "${ROLLBACK[$i]}" 2>/dev/null || true
    done
    log "Откат завершён"
}
trap 'if [[ $? -ne 0 ]]; then do_rollback; fi' EXIT

# ═══════════════════════════════════════════════════════════════════════
# ЭТАП 1: ДИАГНОСТИКА СЕРВЕРА
# ═══════════════════════════════════════════════════════════════════════

check_root() {
    if [[ $EUID -ne 0 ]]; then
        err "Запустите от root: sudo $0"
        exit 1
    fi
}

check_dependencies() {
    echo ""
    echo -e "${BOLD}${BLUE}=== ПРОВЕРКА ЗАВИСИМОСТЕЙ ===${NC}"
    echo ""

    local missing=()

    # unzip
    if command -v unzip &>/dev/null; then
        log "unzip: $(unzip -v 2>&1 | head -1 | grep -oP '[\d.]+' | head -1 || echo ok)"
    else
        err "unzip -- не установлен"
        missing+=("unzip")
    fi

    # wget или curl
    if command -v wget &>/dev/null; then
        log "wget: ok"
    elif command -v curl &>/dev/null; then
        log "curl: ok (вместо wget)"
    else
        err "wget/curl -- не установлены"
        missing+=("wget")
    fi

    # --- PHP 8.2+ (требуется MatterHub) ---
    PHP_BIN="" PHP_VER=""
    # Ищем PHP 8.2+ — MatterHub требует именно 8.2
    for v in 8.2 8.3 8.4; do
        local bin="/usr/bin/php${v}"
        if [[ -x "$bin" ]]; then
            PHP_BIN="$bin"; PHP_VER="$v"; break
        fi
    done
    if [[ -z "$PHP_BIN" ]] && command -v php &>/dev/null; then
        local sys_ver
        sys_ver=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || true)
        case "$sys_ver" in
            8.2|8.3|8.4) PHP_BIN=$(command -v php); PHP_VER="$sys_ver" ;;
        esac
    fi

    if [[ -n "$PHP_BIN" ]]; then
        local full_ver
        full_ver=$("$PHP_BIN" -r 'echo phpversion();' 2>/dev/null || echo "$PHP_VER")
        log "PHP $full_ver ($PHP_BIN)"

        # Проверяем обязательные расширения
        check_php_extensions
    else
        # Информируем о старых версиях PHP, если есть
        local other_php=""
        for v in 8.1 8.0 7.4; do
            [[ -x "/usr/bin/php${v}" ]] && { other_php="$v"; break; }
        done
        if [[ -n "$other_php" ]]; then
            warn "Найден PHP $other_php, но MatterHub требует 8.2+"
            info "  PHP 8.2 будет установлен ПАРАЛЛЕЛЬНО (не затрагивает PHP $other_php)"
        else
            err "PHP не найден (нужен 8.2+)"
        fi
        missing+=("php8.2")
    fi

    # --- ionCube Loader ---
    IONCUBE_OK=false
    if [[ -n "$PHP_BIN" ]]; then
        local ic_ver
        ic_ver=$("$PHP_BIN" -r 'if(function_exists("ioncube_loader_version")) echo ioncube_loader_version(); else echo "";' 2>/dev/null || echo "")
        if [[ -n "$ic_ver" ]]; then
            IONCUBE_OK=true
            log "ionCube Loader v$ic_ver"
        elif "$PHP_BIN" -m 2>/dev/null | grep -qi ioncube; then
            IONCUBE_OK=true
            log "ionCube Loader: активен"
        else
            err "ionCube Loader -- не установлен"
            missing+=("ionCube")
        fi
    else
        # PHP нет → ionCube тоже точно нет
        missing+=("ionCube")
    fi

    # --- Результат ---
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo ""
        err "Отсутствуют компоненты: ${missing[*]}"
        echo ""

        local can_autoinstall=false
        if command -v apt-get &>/dev/null || command -v yum &>/dev/null || command -v dnf &>/dev/null; then
            can_autoinstall=true
        fi

        if $can_autoinstall && confirm "Установить недостающие компоненты автоматически?"; then
            install_missing "${missing[@]}"
        else
            echo ""
            info "Установите вручную:"
            info "  Ubuntu/Debian: apt install unzip wget php8.2-fpm php8.2-cli php8.2-{curl,mbstring,xml,gd,zip}"
            info "  CentOS/RHEL:   yum install unzip wget php82-fpm php82-cli php-{curl,mbstring,xml,gd,zip}"
            info "  ionCube:       https://www.ioncube.com/loaders.php"
            exit 1
        fi
    fi
}

install_missing() {
    local items=("$@")
    echo ""
    info "Устанавливаю: ${items[*]} ..."

    if command -v apt-get &>/dev/null; then
        apt-get update -qq 2>>"$LOG"
        for item in "${items[@]}"; do
            case "$item" in
                unzip|wget) apt-get install -y -qq "$item" 2>>"$LOG" && log "$item установлен" ;;
                php8.2) install_php82 ;;
                php-ext) ensure_php_extensions ;;
                ionCube) install_ioncube ;;
            esac
        done
    elif command -v yum &>/dev/null || command -v dnf &>/dev/null; then
        local PKG="yum"
        command -v dnf &>/dev/null && PKG="dnf"
        for item in "${items[@]}"; do
            case "$item" in
                unzip|wget) $PKG install -y -q "$item" 2>>"$LOG" && log "$item установлен" ;;
                php8.2) install_php82 ;;
                php-ext) ensure_php_extensions ;;
                ionCube) install_ioncube ;;
            esac
        done
    fi
}

install_ioncube() {
    info "Устанавливаю ionCube Loader..."

    [[ -z "$PHP_BIN" ]] && { err "Сначала установите PHP"; return 1; }

    local arch; arch=$(uname -m)
    local url=""
    case "$arch" in
        x86_64)  url="https://downloads.ioncube.com/loader_downloads/ioncube_loaders_lin_x86-64.tar.gz" ;;
        aarch64) url="https://downloads.ioncube.com/loader_downloads/ioncube_loaders_lin_aarch64.tar.gz" ;;
        *)       err "Архитектура $arch не поддерживается"; return 1 ;;
    esac

    local tmp="/tmp/ioncube_dl.tar.gz"
    curl -sSL -o "$tmp" "$url" || wget -q -O "$tmp" "$url"
    tar xzf "$tmp" -C /tmp/

    local ext_dir; ext_dir=$("$PHP_BIN" -r "echo ini_get('extension_dir');" 2>/dev/null)
    local so_file="/tmp/ioncube/ioncube_loader_lin_${PHP_VER}.so"

    if [[ ! -f "$so_file" ]]; then
        so_file=$(ls /tmp/ioncube/ioncube_loader_lin_${PHP_VER%%.*}.*.so 2>/dev/null | tail -1 || true)
    fi

    if [[ -z "$so_file" || ! -f "$so_file" ]]; then
        err "Не найден ionCube loader для PHP $PHP_VER"
        rm -rf /tmp/ioncube "$tmp"
        return 1
    fi

    cp "$so_file" "$ext_dir/"

    local so_name; so_name=$(basename "$so_file")
    for ini_type in fpm cli; do
        local conf_d="/etc/php/${PHP_VER}/$ini_type/conf.d"
        if [[ -d "$conf_d" ]]; then
            echo "zend_extension=${ext_dir}/${so_name}" > "$conf_d/00-ioncube.ini"
            register_rollback "rm -f '$conf_d/00-ioncube.ini'"
        fi
    done

    for svc in "php${PHP_VER}-fpm" "php-fpm" "php-fpm-${PHP_VER}"; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            systemctl restart "$svc" 2>>"$LOG"
            break
        fi
    done

    local ic_check
    ic_check=$("$PHP_BIN" -r 'if(function_exists("ioncube_loader_version")) echo ioncube_loader_version();' 2>/dev/null || echo "")
    if [[ -n "$ic_check" ]] || "$PHP_BIN" -m 2>/dev/null | grep -qi ioncube; then
        IONCUBE_OK=true
        log "ionCube Loader v${ic_check:-ok} установлен!"
    else
        err "ionCube установлен, но не загружается"
    fi

    rm -rf /tmp/ioncube "$tmp"
}

install_php82() {
    info "Устанавливаю PHP 8.2 (изолированно от существующих версий)..."

    if command -v apt-get &>/dev/null; then
        # Проверяем доступность php8.2 в текущих репозиториях
        if ! apt-cache show php8.2-fpm >/dev/null 2>&1; then
            info "PHP 8.2 нет в репозиториях — добавляю PPA ondrej/php..."
            if ! command -v add-apt-repository &>/dev/null; then
                apt-get install -y -qq software-properties-common 2>>"$LOG"
            fi
            add-apt-repository -y ppa:ondrej/php 2>>"$LOG"
            apt-get update -qq 2>>"$LOG"
            log "PPA ondrej/php добавлен"
        fi

        apt-get install -y -qq php8.2-fpm php8.2-cli 2>>"$LOG"
        PHP_BIN="/usr/bin/php8.2"; PHP_VER="8.2"

        # Ставим все нужные расширения сразу
        ensure_php_extensions

        # Запускаем php8.2-fpm (НЕ трогает php8.1-fpm, php8.3-fpm и т.д.)
        systemctl enable php8.2-fpm 2>>"$LOG" || true
        systemctl start php8.2-fpm 2>>"$LOG" || true
        log "PHP 8.2 установлен и запущен (параллельно с другими версиями)"

    elif command -v yum &>/dev/null || command -v dnf &>/dev/null; then
        local PKG="yum"
        command -v dnf &>/dev/null && PKG="dnf"
        warn "CentOS/RHEL: устанавливаю PHP 8.2 через remi-release..."
        if ! rpm -q remi-release >/dev/null 2>&1; then
            $PKG install -y -q epel-release 2>>"$LOG" || true
            local rhel_ver; rhel_ver=$(rpm -E %rhel 2>/dev/null || echo "8")
            $PKG install -y -q "https://rpms.remirepo.net/enterprise/remi-release-${rhel_ver}.rpm" 2>>"$LOG"
        fi
        $PKG module reset php -y 2>>"$LOG" || true
        $PKG module enable php:remi-8.2 -y 2>>"$LOG"
        $PKG install -y -q php-fpm php-cli php-curl php-mbstring php-xml php-gd php-zip php-intl php-bcmath 2>>"$LOG"
        PHP_BIN=$(command -v php); PHP_VER="8.2"
        systemctl enable php-fpm 2>>"$LOG" || true
        systemctl start php-fpm 2>>"$LOG" || true
        log "PHP 8.2 установлен и запущен"
    else
        err "Пакетный менеджер не найден — установите PHP 8.2 вручную"
        return 1
    fi
}

# Список PHP-расширений, необходимых MatterHub
# (ionCube-encoded index.php вызывает функции из этих модулей)
MATTERHUB_PHP_EXTS=(curl mbstring xml gd zip)

check_php_extensions() {
    # Проверяет наличие расширений, если чего-то нет — добавляет в missing
    [[ -z "$PHP_BIN" ]] && return
    local ext_missing=()
    for ext in "${MATTERHUB_PHP_EXTS[@]}"; do
        if ! "$PHP_BIN" -m 2>/dev/null | grep -qi "^${ext}$"; then
            ext_missing+=("$ext")
        fi
    done
    if [[ ${#ext_missing[@]} -gt 0 ]]; then
        warn "Отсутствуют PHP-расширения: ${ext_missing[*]}"
        missing+=("php-ext")
    else
        log "PHP-расширения: все на месте (${MATTERHUB_PHP_EXTS[*]})"
    fi
}

ensure_php_extensions() {
    # Устанавливает недостающие расширения для текущей PHP_VER
    [[ -z "$PHP_VER" ]] && return
    local to_install=()
    local bin="${PHP_BIN:-/usr/bin/php${PHP_VER}}"

    for ext in "${MATTERHUB_PHP_EXTS[@]}"; do
        if ! "$bin" -m 2>/dev/null | grep -qi "^${ext}$"; then
            to_install+=("$ext")
        fi
    done

    if [[ ${#to_install[@]} -eq 0 ]]; then
        log "PHP-расширения: все на месте"
        return
    fi

    info "Доустанавливаю PHP-расширения: ${to_install[*]}..."

    if command -v apt-get &>/dev/null; then
        local pkgs=()
        for ext in "${to_install[@]}"; do
            pkgs+=("php${PHP_VER}-${ext}")
        done
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${pkgs[@]}" 2>>"$LOG"

        # Рестартим FPM чтобы подхватил новые модули
        systemctl restart "php${PHP_VER}-fpm" 2>>"$LOG" || true
        log "PHP-расширения установлены: ${to_install[*]}"

    elif command -v yum &>/dev/null || command -v dnf &>/dev/null; then
        local PKG="yum"
        command -v dnf &>/dev/null && PKG="dnf"
        local pkgs=()
        for ext in "${to_install[@]}"; do
            pkgs+=("php-${ext}")
        done
        $PKG install -y -q "${pkgs[@]}" 2>>"$LOG"
        systemctl restart php-fpm 2>>"$LOG" || systemctl restart "php${PHP_VER}-fpm" 2>>"$LOG" || true
        log "PHP-расширения установлены: ${to_install[*]}"
    else
        warn "Не удалось установить расширения автоматически"
        info "  Установите вручную: ${to_install[*]}"
    fi
}

create_matterhub_fpm_pool() {
    # Создаёт ИЗОЛИРОВАННЫЙ PHP-FPM пул для MatterHub
    # Не трогает существующие пулы, другие сайты не затронуты
    [[ -z "$PHP_VER" ]] && return

    local pool_dir="/etc/php/${PHP_VER}/fpm/pool.d"
    [[ ! -d "$pool_dir" ]] && return

    local pool_conf="$pool_dir/matterhub.conf"
    local sock="/run/php/php${PHP_VER}-fpm-matterhub.sock"

    # Пул уже существует
    if [[ -f "$pool_conf" ]]; then
        log "PHP-FPM пул matterhub: уже настроен"
        systemctl is-active --quiet "php${PHP_VER}-fpm" 2>/dev/null || systemctl start "php${PHP_VER}-fpm" 2>>"$LOG"
        return
    fi

    # На управляемых серверах (HestiaCP и т.д.) пулы управляются панелью
    if [[ "$PANEL" != "none" && -n "$PANEL" ]]; then
        info "Панель $PANEL управляет PHP-FPM — используем существующие пулы"
        return
    fi

    info "Создаю изолированный PHP-FPM пул для MatterHub..."

    # Определяем пользователя webroot
    local pool_user="www-data" pool_group="www-data"
    if [[ -n "${_WEBROOT:-}" && -d "$_WEBROOT" ]]; then
        pool_user=$(stat -c '%U' "$_WEBROOT" 2>/dev/null || echo "www-data")
        pool_group=$(stat -c '%G' "$_WEBROOT" 2>/dev/null || echo "www-data")
        [[ "$pool_user" == "root" ]] && pool_user="www-data"
        [[ "$pool_group" == "root" ]] && pool_group="www-data"
    fi

    cat > "$pool_conf" << POOL_EOF
; ===================================================
; MatterHub — изолированный FPM-пул
; Автосоздан matterhub-install v${VERSION}
; Безопасно удалить: rm $pool_conf && systemctl restart php${PHP_VER}-fpm
; ===================================================
[matterhub]
user = ${pool_user}
group = ${pool_group}

listen = ${sock}
listen.owner = ${pool_user}
listen.group = ${pool_group}

pm = ondemand
pm.max_children = 5
pm.process_idle_timeout = 30s

; MatterHub требует UTF-8
php_admin_value[default_charset] = UTF-8

; Безопасность
php_admin_flag[expose_php] = off
POOL_EOF

    systemctl restart "php${PHP_VER}-fpm" 2>>"$LOG"
    register_rollback "rm -f '$pool_conf'; systemctl restart php${PHP_VER}-fpm 2>/dev/null"

    # Даём время на создание сокета
    sleep 1

    if [[ -S "$sock" ]]; then
        log "PHP-FPM пул matterhub создан ($sock)"
    else
        warn "PHP-FPM пул: сокет не появился — используем стандартный"
    fi
}

install_nginx() {
    # Ставит Nginx, НЕ трогает существующие сервисы
    info "Устанавливаю Nginx..."

    if command -v apt-get &>/dev/null; then
        apt-get install -y -qq nginx 2>>"$LOG"
    elif command -v yum &>/dev/null || command -v dnf &>/dev/null; then
        local PKG="yum"
        command -v dnf &>/dev/null && PKG="dnf"
        $PKG install -y -q nginx 2>>"$LOG"
    else
        err "Не удалось установить Nginx — пакетный менеджер не найден"
        return 1
    fi

    if command -v nginx &>/dev/null; then
        # Удаляем дефолтный сайт Ubuntu (мешает)
        rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
        systemctl enable nginx 2>>"$LOG" || true
        systemctl start nginx 2>>"$LOG" || true
        WEB_SERVER="nginx"
        log "Nginx установлен и запущен"
    else
        err "Nginx: установка не удалась"
        return 1
    fi
}

# ═══════════════════════════════════════════════════════════════════════
# ЭТАП 2: ОПРЕДЕЛЕНИЕ СРЕДЫ
# ═══════════════════════════════════════════════════════════════════════

detect_environment() {
    echo ""
    echo -e "${BOLD}${BLUE}=== СРЕДА СЕРВЕРА ===${NC}"
    echo ""

    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        log "ОС: $PRETTY_NAME"
    fi

    # --- Веб-сервер ---
    WEB_SERVER=""
    local nginx_active=false apache_active=false

    if pgrep -x nginx &>/dev/null || systemctl is-active --quiet nginx 2>/dev/null; then
        nginx_active=true
        log "Nginx: $(nginx -v 2>&1 | grep -oP 'nginx/\K[\d.]+' || echo active)"
    fi

    if pgrep -x apache2 &>/dev/null || pgrep -x httpd &>/dev/null \
       || systemctl is-active --quiet apache2 2>/dev/null \
       || systemctl is-active --quiet httpd 2>/dev/null; then
        apache_active=true
        local av
        av=$(apache2 -v 2>&1 | head -1 | grep -oP 'Apache/\K[\d.]+' 2>/dev/null || httpd -v 2>&1 | head -1 | grep -oP 'Apache/\K[\d.]+' 2>/dev/null || echo active)
        log "Apache: $av"
    fi

    if $nginx_active && $apache_active; then
        WEB_SERVER="nginx+apache"
        info "Режим: Nginx (frontend) + Apache (backend)"
    elif $nginx_active; then
        WEB_SERVER="nginx"
    elif $apache_active; then
        WEB_SERVER="apache"
    else
        warn "Активный веб-сервер не найден"
        WEB_SERVER="unknown"
    fi

    # --- Панель управления ---
    PANEL="none"; PANEL_BIN=""

    if [[ -d /usr/local/hestia ]]; then
        PANEL="hestia"; PANEL_BIN="/usr/local/hestia/bin"
        export PATH="$PANEL_BIN:$PATH"
        log "Панель: HestiaCP"
    elif [[ -d /usr/local/vesta ]]; then
        PANEL="vesta"; PANEL_BIN="/usr/local/vesta/bin"
        export PATH="$PANEL_BIN:$PATH"
        log "Панель: VestaCP"
    elif [[ -d /usr/local/mgr5 || -f /usr/local/ispmgr/bin/ispmgr ]]; then
        PANEL="ispmanager"; log "Панель: ISPmanager"
    elif [[ -d /usr/local/cpanel ]]; then
        PANEL="cpanel"; log "Панель: cPanel"
    elif [[ -d /usr/local/psa ]] || command -v plesk &>/dev/null; then
        PANEL="plesk"; log "Панель: Plesk"
    elif [[ -d /usr/local/CyberCP ]]; then
        PANEL="cyberpanel"; log "Панель: CyberPanel"
    else
        log "Панель: не обнаружена (standalone)"
    fi
}

# ═══════════════════════════════════════════════════════════════════════
# ЭТАП 3: ВЫБОР ДИРЕКТОРИИ
# ═══════════════════════════════════════════════════════════════════════

choose_directory() {
    echo ""
    echo -e "${BOLD}${BLUE}=== КУДА УСТАНОВИТЬ ТУР ===${NC}"
    echo ""

    info "Нужно указать директорию, куда распаковать тур."
    info "Тур будет доступен по URL: https://домен/slug/"
    echo ""

    # --- Показываем доступные сайты ---
    local sites=()
    local idx=0

    case "$PANEL" in
        hestia|vesta)
            for user_dir in /home/*/web/*/public_html; do
                [[ -d "$user_dir" ]] || continue
                local domain
                domain=$(echo "$user_dir" | sed 's|.*/web/\([^/]*\)/public_html|\1|')
                idx=$((idx+1))
                sites+=("$domain|$user_dir")
                echo -e "  ${BOLD}$idx)${NC} $domain  ->  ${CYAN}$user_dir${NC}"
            done
            ;;
        cpanel)
            for user_dir in /home/*/public_html; do
                [[ -d "$user_dir" ]] || continue
                local user
                user=$(echo "$user_dir" | cut -d/ -f3)
                idx=$((idx+1))
                sites+=("$user|$user_dir")
                echo -e "  ${BOLD}$idx)${NC} $user  ->  ${CYAN}$user_dir${NC}"
            done
            ;;
        plesk)
            for wr in /var/www/vhosts/*/httpdocs; do
                [[ -d "$wr" ]] || continue
                local domain
                domain=$(basename "$(dirname "$wr")")
                idx=$((idx+1))
                sites+=("$domain|$wr")
                echo -e "  ${BOLD}$idx)${NC} $domain  ->  ${CYAN}$wr${NC}"
            done
            ;;
        ispmanager)
            for wr in /var/www/*/data/www/*/; do
                [[ -d "$wr" ]] || continue
                local domain
                domain=$(basename "$wr")
                idx=$((idx+1))
                sites+=("$domain|$wr")
                echo -e "  ${BOLD}$idx)${NC} $domain  ->  ${CYAN}$wr${NC}"
            done
            ;;
        *)
            for conf in /etc/nginx/sites-enabled/* /etc/nginx/conf.d/*.conf; do
                [[ -f "$conf" ]] || continue
                local d
                d=$(grep -oP 'server_name\s+\K[^;]+' "$conf" 2>/dev/null | head -1 | awk '{print $1}')
                local wr
                wr=$(grep -oP '^\s*root\s+\K[^;]+' "$conf" 2>/dev/null | head -1)
                if [[ -n "$d" && -n "$wr" && -d "$wr" && "$d" != "_" ]]; then
                    idx=$((idx+1))
                    sites+=("$d|$wr")
                    echo -e "  ${BOLD}$idx)${NC} $d  ->  ${CYAN}$wr${NC}"
                fi
            done
            for conf in /etc/apache2/sites-enabled/*.conf /etc/httpd/conf.d/*.conf; do
                [[ -f "$conf" ]] || continue
                local d
                d=$(grep -oP 'ServerName\s+\K\S+' "$conf" 2>/dev/null | head -1)
                local wr
                wr=$(grep -oP 'DocumentRoot\s+\K\S+' "$conf" 2>/dev/null | head -1 | tr -d '"')
                if [[ -n "$d" && -n "$wr" && -d "$wr" ]]; then
                    idx=$((idx+1))
                    sites+=("$d|$wr")
                    echo -e "  ${BOLD}$idx)${NC} $d  ->  ${CYAN}$wr${NC}"
                fi
            done
            ;;
    esac

    echo ""

    local webroot=""
    local domain=""

    if [[ ${#sites[@]} -gt 0 ]]; then
        echo -e "  ${BOLD}0)${NC} Ввести путь вручную"
        echo ""
        local choice
        choice=$(ask "Выберите сайт (номер) или 0 для ручного ввода" "1")

        if [[ "$choice" =~ ^[1-9][0-9]*$ ]] && [[ "$choice" -le ${#sites[@]} ]]; then
            local entry="${sites[$((choice-1))]}"
            domain="${entry%%|*}"
            webroot="${entry#*|}"
        fi
    else
        warn "Домены не найдены на сервере"
        # Ищем стандартные webroot
        local default_wr="/var/www/html"
        for candidate in /var/www/html /usr/share/nginx/html /var/www; do
            if [[ -d "$candidate" ]]; then
                default_wr="$candidate"
                break
            fi
        done
        info "Используем стандартный webroot: $default_wr"
        info "Тур будет доступен по IP: http://$(hostname -I 2>/dev/null | awk '{print $1}' || echo '127.0.0.1')/<slug>/"
    fi

    if [[ -z "$webroot" ]]; then
        local default_wr="${default_wr:-/var/www/html}"
        webroot=$(ask "Введите полный путь к webroot" "$default_wr")
    fi

    echo ""
    info "Webroot: $webroot"

    if [[ -d "$webroot" ]]; then
        local existing
        existing=$(find "$webroot" -maxdepth 1 -type d -not -name "$(basename "$webroot")" -printf '%f\n' 2>/dev/null | sort | head -20)
        if [[ -n "$existing" ]]; then
            info "Существующие папки:"
            echo "$existing" | while read -r d; do
                echo -e "    ${YELLOW}*${NC} $d"
            done
        fi
    fi

    echo ""
    # Извлечь имя тура из архива (EpfRaivJYbB.zip -> EpfRaivJYbB)
    local default_slug="tour"
    if [[ -n "${ARCHIVE_SRC:-}" ]]; then
        local fname
        fname=$(basename "$ARCHIVE_SRC")
        fname="${fname%%.*}"                         # убрать расширение
        fname=$(echo "$fname" | tr -cd '[:alnum:]_-') # только безопасные символы
        [[ -n "$fname" ]] && default_slug="$fname"
    fi
    local slug
    slug=$(ask "Имя папки для тура (slug)" "$default_slug")
    slug=$(echo "$slug" | tr -cd '[:alnum:]_-')
    [[ -z "$slug" ]] && slug="$default_slug"

    INSTALL_DIR="$webroot/$slug"

    if [[ -d "$INSTALL_DIR" ]]; then
        local count
        count=$(find "$INSTALL_DIR" -type f 2>/dev/null | wc -l)
        warn "Директория $INSTALL_DIR уже существует ($count файлов)"
        if ! confirm "Перезаписать содержимое?"; then
            slug=$(ask "Введите другое имя")
            slug=$(echo "$slug" | tr -cd '[:alnum:]_-')
            INSTALL_DIR="$webroot/$slug"
        fi
    fi

    export _WEBROOT="$webroot"
    export _SLUG="$slug"
    if [[ -n "$domain" ]]; then
        export _DOMAIN="$domain"
    else
        # Пробуем определить домен из webroot (Nginx/Apache конфиги)
        local detected_domain=""
        for f in /etc/nginx/sites-available/* /etc/nginx/conf.d/*.conf; do
            [[ -f "$f" ]] || continue
            if grep -q "root.*${webroot}" "$f" 2>/dev/null; then
                detected_domain=$(grep -oP 'server_name\s+\K[^;]+' "$f" 2>/dev/null | head -1 | awk '{print $1}')
                [[ "$detected_domain" == "_" ]] && detected_domain=""
                [[ -n "$detected_domain" ]] && break
            fi
        done
        export _DOMAIN="${detected_domain:-}"
    fi

    echo ""
    log "Тур: $INSTALL_DIR"
    if [[ -n "$_DOMAIN" ]]; then
        log "URL: https://$_DOMAIN/$slug"
    else
        local _IP; _IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo '127.0.0.1')
        log "URL: http://$_IP/$slug/"
    fi
}

# ═══════════════════════════════════════════════════════════════════════
# ЭТАП 4: СКАЧИВАНИЕ АРХИВА
# ═══════════════════════════════════════════════════════════════════════

get_archive() {
    echo ""
    echo -e "${BOLD}${BLUE}=== АРХИВ ТУРА ===${NC}"
    echo ""

    if [[ -n "$ARCHIVE_SRC" ]]; then
        if [[ "$ARCHIVE_SRC" =~ ^https?:// ]]; then
            download_archive "$ARCHIVE_SRC"
        elif [[ -f "$ARCHIVE_SRC" ]]; then
            ARCHIVE_FILE="$ARCHIVE_SRC"
            log "Файл: $ARCHIVE_FILE ($(du -sh "$ARCHIVE_FILE" | cut -f1))"
        else
            err "Не найдено: $ARCHIVE_SRC"
            exit 1
        fi
        return
    fi

    echo -e "  ${BOLD}1)${NC} Скачать по URL"
    echo -e "  ${BOLD}2)${NC} Указать файл на сервере"
    echo ""

    local method
    method=$(ask "Выбор" "1")

    case "$method" in
        1)
            local url
            url=$(ask "URL архива (.zip)")
            download_archive "$url"
            ;;
        2)
            ARCHIVE_FILE=$(ask "Полный путь к архиву")
            if [[ ! -f "$ARCHIVE_FILE" ]]; then
                err "Файл не найден: $ARCHIVE_FILE"
                exit 1
            fi
            log "Файл: $ARCHIVE_FILE ($(du -sh "$ARCHIVE_FILE" | cut -f1))"
            ;;
        *)
            err "Неверный выбор"
            exit 1
            ;;
    esac
}

download_archive() {
    local url="$1"
    ARCHIVE_FILE="/tmp/matterhub_$(date +%s).zip"

    info "Скачиваю: $url"
    if command -v wget &>/dev/null; then
        wget -q --show-progress -O "$ARCHIVE_FILE" "$url" 2>&1 | tail -1
    else
        curl -L --progress-bar -o "$ARCHIVE_FILE" "$url"
    fi

    register_rollback "rm -f '$ARCHIVE_FILE'"
    log "Скачано: $(du -sh "$ARCHIVE_FILE" | cut -f1)"
}

# ═══════════════════════════════════════════════════════════════════════
# ЭТАП 5: РАСПАКОВКА
# ═══════════════════════════════════════════════════════════════════════

unpack_tour() {
    echo ""
    echo -e "${BOLD}${BLUE}=== РАСПАКОВКА ===${NC}"
    echo ""

    mkdir -p "$INSTALL_DIR"
    register_rollback "rm -rf '$INSTALL_DIR'"

    local tmp_dir="/tmp/matterhub_extract_$$"
    mkdir -p "$tmp_dir"

    info "Распаковываю..."
    if ! unzip -q -o "$ARCHIVE_FILE" -d "$tmp_dir" 2>>"$LOG"; then
        err "Ошибка распаковки"
        rm -rf "$tmp_dir"
        exit 1
    fi

    # Ищем корень тура (где index.php)
    local tour_root=""
    if [[ -f "$tmp_dir/index.php" ]]; then
        tour_root="$tmp_dir"
    else
        local found
        found=$(find "$tmp_dir" -maxdepth 3 -name "index.php" -type f 2>/dev/null | head -1)
        [[ -n "$found" ]] && tour_root=$(dirname "$found")
    fi

    if [[ -z "$tour_root" ]]; then
        err "index.php не найден в архиве. Это не MatterHub-тур?"
        rm -rf "$tmp_dir"
        exit 1
    fi

    # Валидация
    if head -3 "$tour_root/index.php" | grep -qi "ioncube\|SG_FREE_LOADER"; then
        log "index.php: ionCube-encoded"
    else
        warn "index.php: ionCube-кодировка не обнаружена"
    fi

    if [[ -f "$tour_root/.htaccess" ]]; then
        log ".htaccess: найден"
    else
        warn ".htaccess: отсутствует"
    fi

    if [[ -d "$tour_root/resources" ]]; then
        log "resources/: найден"
    else
        warn "resources/: не найден"
    fi

    # Копируем
    cp -a "$tour_root"/. "$INSTALL_DIR/"
    rm -rf "$tmp_dir"

    local fcount
    fcount=$(find "$INSTALL_DIR" -type f | wc -l)
    local fsize
    fsize=$(du -sh "$INSTALL_DIR" | cut -f1)
    log "Установлено: $fcount файлов, $fsize"
}

# ═══════════════════════════════════════════════════════════════════════
# ЭТАП 6: ПРАВА
# ═══════════════════════════════════════════════════════════════════════

set_permissions() {
    echo ""
    echo -e "${BOLD}${BLUE}=== ПРАВА ДОСТУПА ===${NC}"
    echo ""

    local owner group
    owner=$(stat -c '%U' "$_WEBROOT" 2>/dev/null || stat -f '%Su' "$_WEBROOT" 2>/dev/null || echo "www-data")
    group=$(stat -c '%G' "$_WEBROOT" 2>/dev/null || stat -f '%Sg' "$_WEBROOT" 2>/dev/null || echo "www-data")

    chown -R "$owner:$group" "$INSTALL_DIR"
    find "$INSTALL_DIR" -type d -exec chmod 755 {} \;
    find "$INSTALL_DIR" -type f -exec chmod 644 {} \;

    log "Владелец: $owner:$group"
    log "Директории: 755, файлы: 644"
}

# ═══════════════════════════════════════════════════════════════════════
# ЭТАП 7: НАСТРОЙКА ВЕБ-СЕРВЕРА (ИЗОЛИРОВАННО!)
# ═══════════════════════════════════════════════════════════════════════

configure_webserver() {
    echo ""
    echo -e "${BOLD}${BLUE}=== НАСТРОЙКА ВЕБ-СЕРВЕРА ===${NC}"
    echo ""

    # Создаём изолированный FPM-пул для MatterHub (если нужен)
    create_matterhub_fpm_pool

    case "$WEB_SERVER" in
        apache)
            configure_apache_standalone
            ;;
        nginx)
            configure_nginx_standalone
            ;;
        nginx+apache)
            # Nginx frontend -> Apache backend
            # Apache обрабатывает PHP через .htaccess
            # Nginx отдаёт статику для скорости
            configure_nginx_proxy_static
            configure_apache_checks
            ;;
        *)
            warn "Веб-сервер не определён"
            if confirm "Установить Nginx автоматически?"; then
                install_nginx
                if [[ "$WEB_SERVER" == "nginx" ]]; then
                    configure_nginx_standalone
                fi
            else
                info "Установите веб-сервер вручную: apt install nginx"
            fi
            ;;
    esac
}

# --- Apache standalone ---
configure_apache_standalone() {
    info "Apache: тур работает через .htaccess -- проверяю зависимости"

    # mod_rewrite
    if command -v a2enmod &>/dev/null; then
        if apache2ctl -M 2>/dev/null | grep -q rewrite; then
            log "mod_rewrite: включён"
        else
            warn "mod_rewrite: выключен"
            if confirm "Включить mod_rewrite?"; then
                a2enmod rewrite 2>>"$LOG"
                log "mod_rewrite включён"
                restart_apache
            fi
        fi
    elif command -v httpd &>/dev/null; then
        if httpd -M 2>/dev/null | grep -q rewrite; then
            log "mod_rewrite: включён"
        else
            warn "mod_rewrite: выключен. Включите вручную"
        fi
    fi

    # AllowOverride
    check_allowoverride
}

# --- Nginx standalone (PHP-FPM) ---
configure_nginx_standalone() {
    info "Nginx: нужен location-блок для PHP-FPM"

    local nginx_conf
    nginx_conf=$(find_nginx_config_for_domain)

    if [[ -z "$nginx_conf" ]]; then
        # Домена нет — создаём default vhost
        nginx_conf=$(create_default_nginx_vhost)
        if [[ -z "$nginx_conf" ]]; then
            warn "Nginx-конфиг не создан"
            nginx_conf=$(ask "Путь к Nginx-конфигу (пусто -- пропустить)" "")
            [[ -z "$nginx_conf" ]] && return
        fi
    fi

    inject_nginx_location "$nginx_conf"
}

# --- Nginx+Apache (reverse proxy) ---
configure_nginx_proxy_static() {
    info "Nginx+Apache: добавляю location с PHP-FPM (статика + PHP-роутинг)"

    local nginx_conf
    nginx_conf=$(find_nginx_config_for_domain)

    if [[ -z "$nginx_conf" ]]; then
        # Попробуем создать default vhost
        nginx_conf=$(create_default_nginx_vhost)
        if [[ -z "$nginx_conf" ]]; then
            info "Nginx-конфиг не найден -- Apache обработает всё через proxy"
            return
        fi
    fi

    # Полный location (PHP-FPM + статика), т.к. Apache-бэкенд может не обрабатывать этот путь
    inject_nginx_location "$nginx_conf"
}

configure_apache_checks() {
    info "Apache backend: проверяю .htaccess"
    check_allowoverride
}

# --- Вспомогательные ---

check_allowoverride() {
    local found=false

    for conf in /etc/apache2/apache2.conf /etc/apache2/sites-enabled/*.conf \
                /etc/httpd/conf/httpd.conf /etc/httpd/conf.d/*.conf; do
        [[ -f "$conf" ]] || continue

        if grep -A10 "<Directory.*$_WEBROOT" "$conf" 2>/dev/null | grep -qi "AllowOverride.*All"; then
            log "AllowOverride All: OK ($conf)"
            found=true
            break
        elif grep -A10 "<Directory.*$_WEBROOT" "$conf" 2>/dev/null | grep -qi "AllowOverride.*None"; then
            warn "AllowOverride None в $conf"
            if confirm "Исправить на AllowOverride All?"; then
                local esc_wr
                esc_wr=$(echo "$_WEBROOT" | sed 's/[\/&]/\\&/g')
                sed -i "/<Directory.*${esc_wr}/,/<\/Directory>/s/AllowOverride.*/AllowOverride All/" "$conf"
                register_rollback "sed -i '/<Directory.*${esc_wr}/,/<\\/Directory>/s/AllowOverride.*/AllowOverride None/' '$conf'"
                log "AllowOverride исправлен на All"
                restart_apache
                found=true
            fi
            break
        fi
    done

    if ! $found; then
        local global_ao
        global_ao=$(grep -r "AllowOverride" /etc/apache2/apache2.conf /etc/httpd/conf/httpd.conf 2>/dev/null | grep -v "#" | head -3 || true)
        if echo "$global_ao" | grep -qi "All"; then
            log "AllowOverride All: OK (глобально)"
        else
            warn "Не удалось проверить AllowOverride"
            info "Убедитесь: AllowOverride All для $_WEBROOT"
        fi
    fi
}

restart_apache() {
    if systemctl is-active --quiet apache2 2>/dev/null; then
        systemctl reload apache2 2>>"$LOG" && log "Apache перезагружен"
    elif systemctl is-active --quiet httpd 2>/dev/null; then
        systemctl reload httpd 2>>"$LOG" && log "httpd перезагружен"
    fi
}

find_nginx_config_for_domain() {
    # 1. По точному имени домена
    if [[ -n "$_DOMAIN" ]]; then
        for f in "/etc/nginx/sites-available/$_DOMAIN" \
                 "/etc/nginx/sites-available/$_DOMAIN.conf" \
                 "/etc/nginx/conf.d/$_DOMAIN.conf"; do
            if [[ -f "$f" ]]; then echo "$f"; return; fi
        done

        for f in /etc/nginx/sites-available/* /etc/nginx/conf.d/*.conf; do
            [[ -f "$f" ]] || continue
            if grep -q "server_name.*$_DOMAIN" "$f" 2>/dev/null; then
                echo "$f"; return
            fi
        done
    fi

    # 2. По webroot — может быть конфиг с server_name _ (default)
    for f in /etc/nginx/sites-available/* /etc/nginx/conf.d/*.conf; do
        [[ -f "$f" ]] || continue
        if grep -q "root.*${_WEBROOT}" "$f" 2>/dev/null; then
            echo "$f"; return
        fi
    done

    # 3. Default server
    for f in /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default \
             /etc/nginx/conf.d/default.conf; do
        if [[ -f "$f" ]]; then echo "$f"; return; fi
    done

    echo ""
}

create_default_nginx_vhost() {
    # Создаёт минимальный Nginx server-блок для работы по IP (без домена)
    [[ ! -d /etc/nginx ]] && { echo ""; return; }

    local fpm_sock
    fpm_sock=$(find_php_fpm_socket)
    [[ -z "$fpm_sock" ]] && { echo ""; return; }

    local conf_dir=""
    if [[ -d /etc/nginx/sites-available ]]; then
        conf_dir="/etc/nginx/sites-available"
    elif [[ -d /etc/nginx/conf.d ]]; then
        conf_dir="/etc/nginx/conf.d"
    else
        echo ""; return
    fi

    local conf_name="matterhub-default"
    local conf_file="${conf_dir}/${conf_name}.conf"

    # Не перезаписываем если уже есть
    if [[ -f "$conf_file" ]]; then
        echo "$conf_file"; return
    fi

    info "Создаю Nginx default vhost для работы по IP..."

    # Проверяем, не занят ли default_server
    local listen_directive="listen 80"
    if ! grep -rq "default_server" /etc/nginx/sites-enabled/ /etc/nginx/conf.d/ 2>/dev/null; then
        listen_directive="listen 80 default_server"
    fi

    cat > "$conf_file" << NGINX_EOF
# MatterHub default server — автосоздан matterhub-install
server {
    ${listen_directive};
    server_name _;
    root ${_WEBROOT};
    index index.php index.html;

    # Отдаём статику напрямую
    location / {
        try_files \$uri \$uri/ =404;
    }

    # PHP через FPM
    location ~ \.php\$ {
        fastcgi_pass unix:${fpm_sock};
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }
}
NGINX_EOF

    # Создаём симлинк если sites-enabled
    if [[ -d /etc/nginx/sites-enabled && "$conf_dir" == *sites-available* ]]; then
        ln -sf "$conf_file" "/etc/nginx/sites-enabled/${conf_name}.conf"
    fi

    register_rollback "rm -f '$conf_file' '/etc/nginx/sites-enabled/${conf_name}.conf' 2>/dev/null; nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null"

    if nginx -t 2>>"$LOG"; then
        systemctl reload nginx 2>/dev/null
        log "Nginx: создан default vhost ($conf_file)"
    else
        warn "Nginx default vhost — ошибка конфига, удаляю"
        rm -f "$conf_file" "/etc/nginx/sites-enabled/${conf_name}.conf" 2>/dev/null
        echo ""; return
    fi

    echo "$conf_file"
}

find_php_fpm_socket() {
    # 0. MatterHub dedicated pool (изолированный сокет)
    local mh_sock="/run/php/php${PHP_VER}-fpm-matterhub.sock"
    [[ -S "$mh_sock" ]] && { echo "$mh_sock"; return; }

    # 1. По домену (HestiaCP)
    for s in /run/php/php*-fpm-${_DOMAIN}.sock /var/run/php/php*-fpm-${_DOMAIN}.sock; do
        [[ -S "$s" ]] && { echo "$s"; return; }
    done

    # 2. По пользователю
    local owner
    owner=$(stat -c '%U' "$_WEBROOT" 2>/dev/null || echo "")
    if [[ -n "$owner" ]]; then
        for s in /run/php/php*-fpm-${owner}.sock /var/run/php/php*-fpm-${owner}.sock; do
            [[ -S "$s" ]] && { echo "$s"; return; }
        done
    fi

    # 3. Из nginx конфига
    local conf
    conf=$(find_nginx_config_for_domain)
    if [[ -n "$conf" ]]; then
        local sock
        sock=$(grep -oP 'fastcgi_pass\s+unix:\K[^;]+' "$conf" 2>/dev/null | head -1)
        [[ -n "$sock" && -S "$sock" ]] && { echo "$sock"; return; }
    fi

    # 4. Стандартные
    for s in /run/php/php${PHP_VER}-fpm.sock /var/run/php/php${PHP_VER}-fpm.sock /run/php-fpm/www.sock; do
        [[ -S "$s" ]] && { echo "$s"; return; }
    done

    # 5. Любой
    local any
    any=$(find /run/php/ /var/run/php/ -name "php*.sock" -type s 2>/dev/null | head -1 || true)
    [[ -n "$any" ]] && { echo "$any"; return; }

    echo ""
}

inject_nginx_location() {
    local conf="$1"

    if grep -q "location /$_SLUG" "$conf" 2>/dev/null; then
        warn "location /$_SLUG уже есть в $conf"
        if ! confirm "Заменить?"; then return; fi
        remove_nginx_location "$conf"
    fi

    local fpm_sock
    fpm_sock=$(find_php_fpm_socket)
    if [[ -z "$fpm_sock" ]]; then
        err "PHP-FPM сокет не найден! php${PHP_VER}-fpm запущен?"
        return
    fi
    log "PHP-FPM: $fpm_sock"

    # Бэкап
    local bak="${conf}.bak.$(date +%Y%m%d_%H%M%S)"
    cp "$conf" "$bak"
    register_rollback "cp '$bak' '$conf' && nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null"
    log "Бэкап Nginx: $bak"

    # Генерируем блок
    local block=""
    block="${block}
    # --- MatterHub: /${_SLUG} ---
    location /${_SLUG}/resources {
        root ${_WEBROOT};
        try_files \$uri =404;
        expires 30d;
        add_header Cache-Control \"public, immutable\";
    }

    location = /${_SLUG} {
        return 301 /${_SLUG}/;
    }

    location /${_SLUG}/ {
        root ${_WEBROOT};
        index index.php;
        location ~ \\.php\$ {
            fastcgi_pass unix:${fpm_sock};
            fastcgi_index index.php;
            fastcgi_param SCRIPT_FILENAME ${INSTALL_DIR}/index.php;
            include fastcgi_params;
            fastcgi_param REQUEST_URI \$request_uri;
        }
        try_files /dev/null /${_SLUG}/index.php?\$args;
    }
    # --- /MatterHub ---"

    # Вставляем
    do_inject_block "$conf" "$block"

    # Синхронизация + проверка
    sync_nginx_conf "$conf"

    if nginx -t 2>>"$LOG"; then
        systemctl reload nginx
        log "Nginx: location /${_SLUG} добавлен"
    else
        err "Ошибка Nginx! Восстанавливаю бэкап..."
        cp "$bak" "$conf"
        sync_nginx_conf "$conf"
        nginx -t && systemctl reload nginx
    fi
}

inject_nginx_static_only() {
    local conf="$1"

    if grep -q "location /$_SLUG" "$conf" 2>/dev/null; then
        warn "location /$_SLUG уже есть в Nginx"
        return
    fi

    local bak="${conf}.bak.$(date +%Y%m%d_%H%M%S)"
    cp "$conf" "$bak"
    register_rollback "cp '$bak' '$conf' && nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null"

    local block=""
    block="${block}
    # --- MatterHub static: /${_SLUG} ---
    location /${_SLUG}/resources {
        root ${_WEBROOT};
        try_files \$uri =404;
        expires 30d;
        add_header Cache-Control \"public, immutable\";
    }
    # --- /MatterHub ---"

    do_inject_block "$conf" "$block"
    sync_nginx_conf "$conf"

    if nginx -t 2>>"$LOG"; then
        systemctl reload nginx
        log "Nginx: статика /${_SLUG}/resources добавлена"
    else
        err "Ошибка Nginx! Восстанавливаю..."
        cp "$bak" "$conf"
        sync_nginx_conf "$conf"
        nginx -t && systemctl reload nginx
    fi
}

do_inject_block() {
    local conf="$1"
    local block="$2"
    local tmp="/tmp/nginx_inject_$$"

    # Стратегия 1: перед первым "location / {"
    local line_num
    line_num=$(grep -nP '^\s*location\s+/\s*\{' "$conf" | head -1 | cut -d: -f1 || true)

    if [[ -n "$line_num" ]]; then
        head -n $((line_num - 1)) "$conf" > "$tmp"
        echo "$block" >> "$tmp"
        tail -n +$line_num "$conf" >> "$tmp"
        mv "$tmp" "$conf"
        return
    fi

    # Стратегия 2: перед последней "}"
    local last_brace
    last_brace=$(grep -n '^}' "$conf" | tail -1 | cut -d: -f1)
    if [[ -n "$last_brace" ]]; then
        head -n $((last_brace - 1)) "$conf" > "$tmp"
        echo "$block" >> "$tmp"
        tail -n +$last_brace "$conf" >> "$tmp"
        mv "$tmp" "$conf"
        return
    fi

    err "Не удалось вставить блок в $conf"
}

remove_nginx_location() {
    local conf="$1"
    local tmp="/tmp/nginx_remove_$$"
    local in_block=0 braces=0

    while IFS= read -r line; do
        if echo "$line" | grep -q "MatterHub"; then continue; fi
        if [[ $in_block -eq 0 ]]; then
            if echo "$line" | grep -qP "location\s+/$_SLUG"; then
                in_block=1; braces=0
                braces=$(( braces + $(echo "$line" | tr -cd '{' | wc -c) ))
                braces=$(( braces - $(echo "$line" | tr -cd '}' | wc -c) ))
                [[ $braces -le 0 ]] && in_block=0
                continue
            fi
            echo "$line"
        else
            braces=$(( braces + $(echo "$line" | tr -cd '{' | wc -c) ))
            braces=$(( braces - $(echo "$line" | tr -cd '}' | wc -c) ))
            [[ $braces -le 0 ]] && in_block=0
        fi
    done < "$conf" > "$tmp"

    mv "$tmp" "$conf"
}

sync_nginx_conf() {
    local conf="$1"
    local name
    name=$(basename "$conf")
    local available="/etc/nginx/sites-available/$name"
    local enabled="/etc/nginx/sites-enabled/$name"

    [[ ! -d /etc/nginx/sites-enabled ]] && return

    if [[ "$conf" == "$available" ]]; then
        if [[ -L "$enabled" ]]; then
            : # симлинк ok
        elif [[ -f "$enabled" ]]; then
            cp "$available" "$enabled"
        else
            ln -sf "$available" "$enabled"
        fi
    fi
}

# ═══════════════════════════════════════════════════════════════════════
# ЭТАП 8: ПРОВЕРКИ
# ═══════════════════════════════════════════════════════════════════════

run_checks() {
    echo ""
    echo -e "${BOLD}${BLUE}=== ПРОВЕРКА ===${NC}"
    echo ""

    local errors=0
    local url=""

    if [[ -n "$_DOMAIN" ]]; then
        url="https://$_DOMAIN/$_SLUG"
    else
        local ip
        ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")
        url="http://$ip/$_SLUG"
    fi

    sleep 1

    # Главная (с trailing slash!)
    info "Проверяю $url/ ..."
    local code size
    code=$(curl -sSk -o /dev/null -w "%{http_code}" "$url/" 2>/dev/null || echo "000")
    size=$(curl -sSk -o /dev/null -w "%{size_download}" "$url/" 2>/dev/null || echo "0")

    if [[ "$code" == "200" && "$size" -gt 500 ]]; then
        log "HTTP $code ($size байт)"
    elif [[ "$code" == "500" ]]; then
        err "HTTP 500 -- проверьте PHP и ionCube"
        errors=$((errors+1))
    elif [[ "$code" == "403" ]]; then
        err "HTTP 403 -- проверьте права"
        errors=$((errors+1))
    elif [[ "$code" == "404" ]]; then
        err "HTTP 404 -- маршрутизация не работает"
        errors=$((errors+1))
    else
        warn "HTTP $code ($size байт)"
        [[ "$code" != "200" ]] && errors=$((errors+1))
    fi

    # Статика
    local css_file
    css_file=$(find "$INSTALL_DIR/resources/css/" -name "*.css" -type f 2>/dev/null | head -1)
    if [[ -n "$css_file" ]]; then
        local css_name
        css_name=$(basename "$css_file")
        code=$(curl -sSk -o /dev/null -w "%{http_code}" "$url/resources/css/$css_name" 2>/dev/null || echo "000")
        if [[ "$code" == "200" ]]; then
            log "Статика: HTTP $code"
        else
            err "Статика: HTTP $code"
            errors=$((errors+1))
        fi
    fi

    echo ""
    if [[ $errors -eq 0 ]]; then
        log "Все проверки пройдены!"
    else
        warn "Проблем: $errors (лог: $LOG)"
    fi
}

# ═══════════════════════════════════════════════════════════════════════
# ФИНАЛ
# ═══════════════════════════════════════════════════════════════════════

print_result() {
    local url=""
    if [[ -n "$_DOMAIN" ]]; then
        url="https://$_DOMAIN/$_SLUG"
    else
        local ip
        ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")
        url="http://$ip/$_SLUG"
    fi

    echo ""
    echo -e "${BOLD}${GREEN}=======================================${NC}"
    echo -e "${BOLD}${GREEN}  УСТАНОВКА ЗАВЕРШЕНА!${NC}"
    echo -e "${BOLD}${GREEN}=======================================${NC}"
    echo ""
    echo -e "  ${BOLD}Директория:${NC}  $INSTALL_DIR"
    [[ -n "$url" ]] && echo -e "  ${BOLD}URL:${NC}         ${CYAN}$url${NC}"
    echo -e "  ${BOLD}Веб-сервер:${NC}  $WEB_SERVER"
    echo -e "  ${BOLD}PHP:${NC}         $PHP_VER"
    echo -e "  ${BOLD}ionCube:${NC}     $(if $IONCUBE_OK; then echo -e "${GREEN}да${NC}"; else echo -e "${RED}нет${NC}"; fi)"
    echo -e "  ${BOLD}Панель:${NC}      $PANEL"
    echo -e "  ${BOLD}Лог:${NC}         $LOG"
    echo ""
    [[ -n "$url" ]] && echo -e "  ${YELLOW}-> Откройте: $url${NC}"
    echo ""
    echo -e "  ${CYAN}Если не работает:${NC}"
    echo -e "    1. PHP + ionCube: php -m | grep -i ioncube"
    echo -e "    2. Apache: AllowOverride All"
    echo -e "    3. PHP: default_charset = UTF-8"
    echo -e "    4. Лог: cat $LOG"
    echo ""
}

# ═══════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════

show_banner() {
    echo ""
    echo -e "${BOLD}${CYAN}"
    echo '  __  __       _   _           _  _       _'
    echo ' |  \/  | __ _| |_| |_ ___ _ _| || |_   _| |__'
    echo ' | |\/| |/ _` |  _|  _/ -_) ._) __ | | | |  _ \'
    echo ' |_|  |_|\__,_|\__|\__\___|_| |_||_|\_,_|_.__/'
    echo -e "${NC}"
    echo -e "  ${BOLD}v$VERSION${NC}  --  Универсальный автоустановщик 3D-туров"
    echo ""
}

parse_args() {
    ARCHIVE_SRC=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --url)     ARCHIVE_SRC="$2"; shift 2 ;;
            --dir)     INSTALL_DIR="$2"; shift 2 ;;
            --yes|-y)  AUTO_YES=true; shift ;;
            --help|-h)
                echo "MatterHub Tour Installer v$VERSION"
                echo ""
                echo "Использование: $(basename "$0") [опции]"
                echo ""
                echo "Опции:"
                echo "  --url URL    URL архива тура (.zip)"
                echo "  --dir PATH   Полный путь куда распаковать"
                echo "  --yes, -y    Автоподтверждение (без вопросов)"
                echo "  -h, --help   Справка"
                echo ""
                echo "Требования:"
                echo "  unzip, wget/curl, PHP 8.2+, ionCube Loader"
                echo "  Apache: mod_rewrite + AllowOverride All"
                echo "  Nginx: PHP-FPM"
                echo ""
                echo "Примеры:"
                echo "  $(basename "$0")"
                echo "  $(basename "$0") --url https://example.com/tour.zip --dir /var/www/html/tour"
                exit 0
                ;;
            *) err "Неизвестный аргумент: $1"; exit 1 ;;
        esac
    done
}

main() {
    parse_args "$@"
    show_banner
    check_root

    echo -e "  ${CYAN}Лог: $LOG${NC}"
    echo ""

    # 1. Зависимости
    check_dependencies

    # 2. Среда
    detect_environment

    # 3. Директория
    if [[ -z "$INSTALL_DIR" ]]; then
        choose_directory
    else
        _WEBROOT=$(dirname "$INSTALL_DIR")
        _SLUG=$(basename "$INSTALL_DIR")
        # Определяем домен из пути: /home/*/web/DOMAIN/public_html/...
        _DOMAIN=$(echo "$INSTALL_DIR" | grep -oP '/web/\K[^/]+' || true)
        export _WEBROOT _SLUG _DOMAIN
        log "Директория: $INSTALL_DIR"
    fi

    # 4. Подтверждение
    echo ""
    echo -e "${BOLD}-- Итого --${NC}"
    echo -e "  Директория: ${CYAN}$INSTALL_DIR${NC}"
    echo -e "  Веб-сервер: ${CYAN}$WEB_SERVER${NC}"
    echo -e "  PHP:        ${CYAN}$PHP_VER${NC}"
    echo -e "  ionCube:    $(if $IONCUBE_OK; then echo -e "${GREEN}да${NC}"; else echo -e "${RED}нет${NC}"; fi)"
    echo ""

    if ! confirm "Продолжить установку?"; then
        info "Отменено"
        exit 0
    fi

    # 5. Архив
    get_archive

    # 6. Распаковка
    unpack_tour

    # 7. Права
    set_permissions

    # 8. Веб-сервер (изолированно!)
    configure_webserver

    # 9. Проверка
    run_checks

    # OK -- убираем rollback
    trap - EXIT

    # 10. Результат
    print_result
}

main "$@"
