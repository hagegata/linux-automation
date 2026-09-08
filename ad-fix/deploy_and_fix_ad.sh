#!/bin/bash
# Скрипт диагностики и автоматического исправления проблем интеграции с Active Directory в ALT Linux.
# Используется для устранения ошибок вида "getpwuid failed", "Failed to get machine token", "NoneType object is not iterable".


set -euo pipefail
IFS=$'\n\t'

# === Настройки по умолчанию ===
BACKUP_DIR="/var/backups/ad-fix-$(date +%Y%m%d%H%M%S)"
LOG_FILE="/var/log/ad-fix.log"
INTERACTIVE=true
FORCE=false
CHECK_ONLY=false
DOMAIN_ADMIN=""
DOMAIN_ADMIN_PASS=""

# === Цветной вывод ===
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' 

# === Функции логирования ===
log() {
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"
}

info() {
    log "${GREEN}[INFO]${NC} $*"
}

warn() {
    log "${YELLOW}[WARN]${NC} $*"
}

error() {
    log "${RED}[ERROR]${NC} $*" >&2
}

# === Функция подтверждения действия ===
confirm() {
    if [ "$FORCE" = true ]; then
        return 0
    fi
    if [ "$INTERACTIVE" = true ]; then
        read -p "$1 (y/n): " -n 1 -r
        echo
        [[ $REPLY =~ ^[Yy]$ ]]
    else
        return 1
    fi
}

# === Резервное копирование файла ===
backup_file() {
    local file="$1"
    if [ -f "$file" ]; then
        mkdir -p "$BACKUP_DIR"
        cp -a "$file" "$BACKUP_DIR/$(basename "$file").bak.$(date +%s)"
        info "Резервная копия $file сохранена в $BACKUP_DIR"
    fi
}

# === Проверка прав суперпользователя ===
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        error "Этот скрипт должен выполняться от root. Завершение."
        exit 1
    fi
}

# === Определение используемого бэкенда (winbind/sssd) ===
detect_backend() {
    if systemctl is-active --quiet winbind 2>/dev/null || rpm -q samba-winbind &>/dev/null; then
        echo "winbind"
    elif systemctl is-active --quiet sssd 2>/dev/null || rpm -q sssd &>/dev/null; then
        echo "sssd"
    else
        echo "unknown"
    fi
}

# === Проверка и исправление /etc/nsswitch.conf ===
fix_nsswitch() {
    local backend="$1"
    local file="/etc/nsswitch.conf"
    local changed=false

    info "Проверка $file для $backend..."

    if [ ! -f "$file" ]; then
        error "Файл $file не найден!"
        return 1
    fi

    backup_file "$file"

    if [ "$backend" = "winbind" ]; then
        if ! grep -E '^passwd:.*winbind' "$file" >/dev/null; then
            if confirm "Добавить 'winbind' в строку passwd файла $file?"; then
                sed -i 's/^passwd:\(.*\)/passwd:\1 winbind/' "$file"
                changed=true
            fi
        fi
        if ! grep -E '^group:.*winbind' "$file" >/dev/null; then
            if confirm "Добавить 'winbind' в строку group файла $file?"; then
                sed -i 's/^group:\(.*\)/group:\1 winbind/' "$file"
                changed=true
            fi
        fi
    elif [ "$backend" = "sssd" ]; then
        if ! grep -E '^passwd:.*sss' "$file" >/dev/null; then
            if confirm "Добавить 'sss' в строку passwd файла $file?"; then
                sed -i 's/^passwd:\(.*\)/passwd:\1 sss/' "$file"
                changed=true
            fi
        fi
        if ! grep -E '^group:.*sss' "$file" >/dev/null; then
            if confirm "Добавить 'sss' в строку group файла $file?"; then
                sed -i 's/^group:\(.*\)/group:\1 sss/' "$file"
                changed=true
            fi
        fi
    else
        warn "Неизвестный бэкенд, пропускаем правку nsswitch.conf"
        return 0
    fi

    if $changed; then
        info "Файл $file обновлён."
    else
        info "Файл $file уже настроен корректно."
    fi
}

# === Проверка hostname ===
check_hostname() {
    local current_hostname
    current_hostname=$(hostname -s)
    info "Текущее короткое имя хоста: $current_hostname"

    # Для winbind попробуем вытащить имя из AD
    if command -v net &>/dev/null; then
        if net ads status -k &>/dev/null; then
            local ad_hostname
            ad_hostname=$(net ads status -k 2>/dev/null | awk -F '=' '/^Workstation/ {print $2}' | tr -d ' ')
            if [ -n "$ad_hostname" ] && [ "$ad_hostname" != "$current_hostname" ]; then
                warn "Имя хоста в AD ($ad_hostname) отличается от локального ($current_hostname)."
                if confirm "Изменить локальное имя хоста на $ad_hostname (требуется перезагрузка)?"; then
                    hostnamectl set-hostname "$ad_hostname"
                    warn "Имя хоста изменено. Перезагрузка ОБЯЗАТЕЛЬНА после завершения скрипта."
                fi
            fi
        fi
    fi
}

# === Проверка Kerberos ===
fix_kerberos() {
    local backend="$1"
    info "Проверка конфигурации Kerberos..."

    # Проверка /etc/krb5.conf
    local krb5_conf="/etc/krb5.conf"
    if [ ! -f "$krb5_conf" ]; then
        krb5_conf="/etc/krb5/krb5.conf"
    fi
    if [ ! -f "$krb5_conf" ]; then
        error "Конфигурационный файл Kerberos не найден!"
        return 1
    fi

    # Проверка наличия default_realm
    if ! grep -q 'default_realm' "$krb5_conf"; then
        warn "В $krb5_conf не указан default_realm."
    fi

    # Проверка keytab
    local keytab="/etc/krb5.keytab"
    if [ ! -f "$keytab" ]; then
        error "Файл keytab $keytab отсутствует!"
        if confirm "Попытаться создать новый keytab (требуется admin домена)?"; then
            if [ "$backend" = "winbind" ]; then
                net ads keytab create -U "$DOMAIN_ADMIN"  # Запросим пароль интерактивно, если не задан
            elif [ "$backend" = "sssd" ]; then
                warn "Для SSSD keytab обычно управляется через sssd, перезапустите sssd после присоединения."
            fi
        fi
    else
        info "Keytab присутствует."
        # Попытка получить тикет
        local hostname_short
        hostname_short=$(hostname -s)
        if kinit -k "${hostname_short}\$" &>/dev/null; then
            info "Успешно получен тикет Kerberos для ${hostname_short}\$."
            kdestroy
        else
            warn "Не удалось получить тикет Kerberos для ${hostname_short}\$."
            if confirm "Пересоздать keytab и обновить пароль компьютера в домене?"; then
                if [ "$backend" = "winbind" ]; then
                    net ads changetrustpw
                    net ads keytab create
                elif [ "$backend" = "sssd" ]; then
                    warn "Для SSSD: переприсоединитесь к домену (realm leave && realm join) или обновите пароль через adcli."
                fi
            fi
        fi
    fi
}

# === Исправление Winbind ===
fix_winbind() {
    info "=== Исправление Winbind ==="

    # Проверка smb.conf
    local smb_conf="/etc/samba/smb.conf"
    if [ ! -f "$smb_conf" ]; then
        error "Файл $smb_conf не найден!"
        return 1
    fi

    backup_file "$smb_conf"

    # Проверка workgroup и realm
    local workgroup realm
    workgroup=$(grep -i '^\s*workgroup\s*=' "$smb_conf" | awk -F '=' '{print $2}' | xargs)
    realm=$(grep -i '^\s*realm\s*=' "$smb_conf" | awk -F '=' '{print $2}' | xargs)
    info "Workgroup: $workgroup, Realm: $realm"

    # Проверка idmap диапазона
    local idmap_range
    idmap_range=$(grep -A1 'idmap config \*' "$smb_conf" | grep 'range' | awk -F '=' '{print $2}' | xargs)
    if [ -z "$idmap_range" ]; then
        warn "Не задан диапазон idmap для домена '*'."
        if confirm "Добавить диапазон idmap 10000-200000?"; then
            # Добавим перед первой секцией или в конец
            sed -i '/\[global\]/a\        idmap config * : range = 10000-200000\n        idmap config * : backend = tdb' "$smb_conf"
            changed=true
        fi
    else
        # Проверим, входит ли 200000 в диапазон
        local min max
        min=$(echo "$idmap_range" | cut -d'-' -f1)
        max=$(echo "$idmap_range" | cut -d'-' -f2)
        if [ "$max" -lt 200000 ]; then
            warn "Диапазон idmap ($idmap_range) не включает UID 200000."
            if confirm "Расширить диапазон до 200000 (макс. значение)?"; then
                sed -i "s/range = $idmap_range/range = $min-200000/" "$smb_conf"
                info "Диапазон idmap обновлён."
            fi
        else
            info "Диапазон idmap в порядке."
        fi
    fi

    # Проверка службы winbind
    if ! systemctl is-active --quiet winbind; then
        warn "Служба winbind не запущена. Запускаем..."
        systemctl start winbind
    fi
    if ! systemctl is-enabled --quiet winbind; then
        if confirm "Включить автозапуск winbind?"; then
            systemctl enable winbind
        fi
    fi

    # Очистка кэша
    if confirm "Очистить кэш Winbind (net cache flush)?"; then
        net cache flush
        info "Кэш Winbind очищен."
    fi

    # Перезапуск winbind для применения изменений
    systemctl restart winbind
}

# === Исправление SSSD ===
fix_sssd() {
    info "=== Исправление SSSD ==="

    local sssd_conf="/etc/sssd/sssd.conf"
    if [ ! -f "$sssd_conf" ]; then
        error "Файл $sssd_conf не найден!"
        return 1
    fi

    backup_file "$sssd_conf"

    # Проверка, что файл имеет правильные права (600)
    if [ "$(stat -c %a "$sssd_conf")" != "600" ]; then
        warn "Неправильные права доступа у $sssd_conf. Исправляем..."
        chmod 600 "$sssd_conf"
    fi

    # Проверка доменов
    local domains
    domains=$(grep -i '^\s*domains\s*=' "$sssd_conf" | cut -d'=' -f2 | xargs)
    info "Домены SSSD: $domains"

    # Проверка idmap диапазона для первого домена
    local domain_section
    domain_section=$(grep -E '^\[domain/' "$sssd_conf" | head -1 | tr -d '[]')
    if [ -n "$domain_section" ]; then
        local min_id max_id
        min_id=$(awk -F '=' '/id_min/ {print $2}' "$sssd_conf" | xargs)
        max_id=$(awk -F '=' '/id_max/ {print $2}' "$sssd_conf" | xargs)
        if [ -n "$min_id" ] && [ -n "$max_id" ]; then
            if [ "$max_id" -lt 200000 ]; then
                warn "id_max ($max_id) в $domain_section меньше 200000."
                if confirm "Установить id_max = 200000?"; then
                    sed -i "/^\[${domain_section}\]/,/^\[/ s/id_max = .*/id_max = 200000/" "$sssd_conf"
                fi
            fi
        fi
    fi

    # Проверка службы sssd
    if ! systemctl is-active --quiet sssd; then
        warn "Служба sssd не запущена. Запускаем..."
        systemctl start sssd
    fi
    if ! systemctl is-enabled --quiet sssd; then
        if confirm "Включить автозапуск sssd?"; then
            systemctl enable sssd
        fi
    fi

    # Очистка кэша
    if confirm "Очистить кэш SSSD (sss_cache -E)?"; then
        sss_cache -E
        info "Кэш SSSD очищен."
    fi

    systemctl restart sssd
}

# === Проверка присоединения к домену ===
check_domain_membership() {
    local backend="$1"
    info "Проверка членства в домене..."

    if [ "$backend" = "winbind" ]; then
        if net ads testjoin &>/dev/null; then
            info "Компьютер состоит в домене (Winbind)."
        else
            error "Компьютер НЕ в домене или нарушено доверие."
            if confirm "Переприсоединить компьютер к домену? Потребуются права администратора домена."; then
                if [ -z "$DOMAIN_ADMIN" ]; then
                    read -p "Введите имя администратора домена (user@domain): " DOMAIN_ADMIN
                fi
                net ads leave -U "$DOMAIN_ADMIN"
                # Попробуем определить OU, если сохранился smb.conf
                local ou
                ou=$(grep -i 'createcomputer' /etc/samba/smb.conf | head -1 | awk -F '=' '{print $2}' | xargs)
                if [ -n "$ou" ]; then
                    net ads join -U "$DOMAIN_ADMIN" createcomputer="$ou"
                else
                    net ads join -U "$DOMAIN_ADMIN"
                fi
                if [ $? -eq 0 ]; then
                    info "Переприсоединение выполнено успешно."
                else
                    error "Ошибка при присоединении к домену."
                fi
            fi
        fi
    elif [ "$backend" = "sssd" ]; then
        if realm list | grep -q "$(hostname -d)"; then
            info "Компьютер состоит в домене (SSSD)."
        else
            error "Компьютер НЕ в домене."
            if confirm "Присоединить компьютер к домену через realm?"; then
                if [ -z "$DOMAIN_ADMIN" ]; then
                    read -p "Введите имя администратора домена (user@domain): " DOMAIN_ADMIN
                fi
                realm join -U "$DOMAIN_ADMIN" "$(hostname -d)"
            fi
        fi
    fi
}

# === Главная функция ===
main() {
    check_root

    # Обработка аргументов
    while [[ $# -gt 0 ]]; do
        case $1 in
            --check)
                CHECK_ONLY=true
                INTERACTIVE=false
                shift
                ;;
            --fix)
                CHECK_ONLY=false
                shift
                ;;
            --force)
                FORCE=true
                INTERACTIVE=false
                shift
                ;;
            --backup-dir)
                BACKUP_DIR="$2"
                shift 2
                ;;
            --admin)
                DOMAIN_ADMIN="$2"
                shift 2
                ;;
            *)
                echo "Неизвестный аргумент: $1"
                echo "Использование: $0 [--check|--fix] [--force] [--admin user] [--backup-dir dir]"
                exit 1
                ;;
        esac
    done

    info "=== Начало диагностики и исправления AD ==="
    info "Бэкенд резервного копирования: $BACKUP_DIR"
    info "Режим: $(if $CHECK_ONLY; then echo 'Только проверка'; else echo 'Исправление'; fi)"

    local backend
    backend=$(detect_backend)
    info "Определён бэкенд: $backend"

    if [ "$backend" = "unknown" ]; then
        error "Не удалось определить бэкенд аутентификации (ни winbind, ни sssd не активны)."
        if confirm "Установить winbind (samba-winbind) и настроить?"; then
            apt-get update && apt-get install -y samba-winbind
            backend="winbind"
        else
            exit 1
        fi
    fi

    # Шаг 1: NSS
    fix_nsswitch "$backend"

    # Шаг 2: Hostname
    check_hostname

    # Шаг 3: Kerberos
    fix_kerberos "$backend"

    # Шаг 4: Бэкенд
    if [ "$backend" = "winbind" ]; then
        fix_winbind
    elif [ "$backend" = "sssd" ]; then
        fix_sssd
    fi

    # Шаг 5: Членство в домене
    check_domain_membership "$backend"

    info "=== Работа скрипта завершена ==="
    if [ "$CHECK_ONLY" = false ]; then
        warn "Рекомендуется перезагрузить систему для применения всех изменений."
    fi
}

main "$@"

