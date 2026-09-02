#!/usr/bin/env bash
# ==============================================================================
# deploy.sh — Универсальный автономный диспетчер развертывания Dual-Boot
#             (Windows 10/11 + Ubuntu 24.04/22.04 + Shared exFAT + отдельный /home)
# ==============================================================================
set -Eeuo pipefail
trap 'echo -e "\n\033[1;31m[ОШИБКА]\033[0m Сбой выполнения на строке $LINENO" >&2' ERR

# Цветовая палитра для вывода
C_RESET="\033[0m"
C_BOLD="\033[1m"
C_RED="\033[1;31m"
C_GREEN="\033[1;32m"
C_YELLOW="\033[1;33m"
C_BLUE="\033[1;34m"
C_CYAN="\033[1;36m"

info()    { echo -e "${C_BLUE}[ИНФО]${C_RESET} $*"; }
success() { echo -e "${C_GREEN}[УСПЕХ]${C_RESET} $*"; }
warn()    { echo -e "${C_YELLOW}[ВНИМАНИЕ]${C_RESET} $*" >&2; }
die()     { echo -e "${C_RED}[ОШИБКА]${C_RESET} $*" >&2; exit 1; }
run()     { if (( DRY )); then echo -e "  ${C_CYAN}[dry-run]${C_RESET} $*"; else "$@"; fi; }

# GRUB >= 2.06 не запускает os-prober, пока GRUB_DISABLE_OS_PROBER не
# установлен явно в false — без этого Windows не появится в меню Dual-Boot.
enable_os_prober() {
    local grub_cfg="${1}/etc/default/grub"
    if [[ -f "$grub_cfg" ]]; then
        sed -i '/^[[:space:]]*GRUB_DISABLE_OS_PROBER=/d' "$grub_cfg"
        echo "GRUB_DISABLE_OS_PROBER=false" >> "$grub_cfg"
    fi
}

# Перевод IANA-часового пояса (deploy.conf TIMEZONE) в имя Windows для
# autounattend.xml. Для неизвестных зон оставляем значение по умолчанию.
iana_to_windows_tz() {
    case "$1" in
        Europe/Kaliningrad)                     echo "Kaliningrad Standard Time" ;;
        Europe/Moscow|Europe/Kirov|Europe/Volgograd) echo "Russian Standard Time" ;;
        Europe/Samara)                          echo "Russia Time Zone 3" ;;
        Asia/Yekaterinburg)                     echo "Russia Time Zone 4" ;;
        Asia/Omsk)                              echo "Omsk Standard Time" ;;
        Asia/Novosibirsk)                       echo "N. Central Asia Standard Time" ;;
        Asia/Krasnoyarsk)                       echo "North Asia Standard Time" ;;
        Asia/Irkutsk)                           echo "North Asia East Standard Time" ;;
        Asia/Chita)                             echo "Transbaikal Standard Time" ;;
        Asia/Yakutsk)                           echo "Yakutsk Standard Time" ;;
        Asia/Vladivostok|Asia/Sakhalin)         echo "Vladivostok Standard Time" ;;
        Asia/Magadan)                           echo "Magadan Standard Time" ;;
        Asia/Kamchatka)                         echo "Kamchatka Standard Time" ;;
        *)                                      echo "Russian Standard Time" ;;
    esac
}

REAL_SOURCE="$(realpath "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "$REAL_SOURCE")" && pwd)"
# Каталог, из которого скрипт реально запущен (флешка). После переноса в RAM
# SCRIPT_DIR указывает на /tmp, а этот путь нужен для записи autounattend.xml.
ORIG_SCRIPT_DIR="$SCRIPT_DIR"

# ==============================================================================
# 🧹 Cleanup-ловушка: при любом завершении скрипта (успех или сбой) отмонтируем
# ISO-образы, точки монтирования Ubuntu и бинды chroot, чтобы сбой не оставлял
# «висящих» монтирований в /proc/mounts.
# ==============================================================================
cleanup_mounts() {
    local root mp

    # 1. Всё, что смонтировано ВНУТРИ корней chroot (разделы + бинды /dev, /proc,
    #    /sys, /run), размонтируем от самых вложенных путей к корню.
    for root in /tmp/ubuntu_root_mnt /tmp/boot_repair_root; do
        [[ -d "$root" ]] || continue
        local targets=()
        while IFS= read -r mp; do
            [[ -n "$mp" ]] && targets+=("$mp")
        done < <(awk -v r="$root/" '$2 ~ "^" r {print $2}' /proc/self/mounts 2>/dev/null | sort -r || true)

        for mp in "${targets[@]}"; do
            umount "$mp" 2>/dev/null || true
        done
    done

    # 2. Сами точки монтирования (если ещё смонтированы)
    for mp in /tmp/ubuntu_root_mnt /tmp/boot_repair_root /tmp/win_iso_mnt /tmp/win_sys_mnt /tmp/ubu_iso_mnt; do
        if grep -qE "^[^ ]+ $mp " /proc/self/mounts 2>/dev/null; then
            umount "$mp" 2>/dev/null || true
        fi
    done

    # 3. Диагностика: что-то осталось смонтированным — предупредим пользователя
    for mp in /tmp/ubuntu_root_mnt /tmp/boot_repair_root /tmp/win_iso_mnt /tmp/win_sys_mnt /tmp/ubu_iso_mnt; do
        if grep -qE "^[^ ]+ $mp( |/)" /proc/self/mounts 2>/dev/null; then
            warn "Не удалось автоматически отмонтировать $mp — проверьте вручную."
        fi
    done
    return 0
}
trap cleanup_mounts EXIT

# ==============================================================================
# 🛡️ ЗАЩИТА ОТ БЛОКИРОВКИ LIVE-USB:
# Автоматический перенос скрипта в оперативную память (RAM /tmp).
# Если Live-образ заблокировал раздел флешки (loop/casper/ro), скрипт
# мгновенно копирует себя в RAM и работает полностью изолированно.
# ==============================================================================
RAM_TARGET="/tmp/deploy-baremetal"
if [[ "$SCRIPT_DIR" != "$RAM_TARGET" && -d /tmp ]]; then
    mkdir -p "$RAM_TARGET"
    cp -r "$SCRIPT_DIR"/* "$RAM_TARGET/" 2>/dev/null || true
    chmod +x "$RAM_TARGET/deploy.sh" 2>/dev/null || true
    if [[ -f "$RAM_TARGET/deploy.sh" ]]; then
        exec bash "$RAM_TARGET/deploy.sh" "$@"
    fi
fi

CONF_FILE="${SCRIPT_DIR}/deploy.conf"

# Загрузка конфигурации
if [[ -f "$CONF_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONF_FILE"
else
    TARGET_DISK="AUTO"
    EFI_SIZE_MB=500
    MSR_SIZE_MB=16
    WINDOWS_SIZE_GB=250
    RECOVERY_SIZE_MB=1000
    SHARED_SIZE_GB=100
    UBUNTU_ROOT_SIZE_GB=120
    SWAPFILE_SIZE_GB=4
    SHARED_FSTYPE="exfat"
    USERNAME="asv-spb"
    HOSTNAME="workstation"
    WIN_PASSWORD=""
    TIMEZONE="Europe/Moscow"
    DEFAULT_LOCALE="ru_RU.UTF-8"
    ENABLE_UTC_TIME=1
    # Значения DISABLE_FAST_STARTUP / DISABLE_BITLOCKER зашиты в шаблон
    # templates/unattend.xml.template (Windows Setup отключает Fast Startup и
    # BitLocker всегда). Переменные читаются скриптом через source deploy.conf.
    # shellcheck disable=SC2034
    DISABLE_FAST_STARTUP=1
    # shellcheck disable=SC2034
    DISABLE_BITLOCKER=1
    ENABLE_FSTRIM_TIMER=1
    INSTALL_RESTRICTED_DRIVERS=1
    PROTECT_GRUB_REMOVABLE=1
    ENABLE_SHARED_AUTOMOUNT=1
fi

DRY=0
YES=0
MODE=""

usage() {
    cat << 'EOF'
Использование: sudo bash deploy.sh [РЕЖИМ] [ОПЦИИ]

РЕЖИМЫ:
  --prep-disk            Разметка GPT + форматирование разделов БЕЗ установки ОС
                         (готовит диск под Windows 11 + Ubuntu Dual-Boot и
                         генерирует autounattend.xml для установки Windows)
  --full, -f             Полный поток подготовки (= --prep-disk): разметка и
                         форматирование диска под Dual-Boot
  --reinstall-ubuntu     Переустановка только Ubuntu (корень /), сохраняя /home, Windows и Shared
  --repair-boot          Восстановление/переустановка загрузчика Dual-Boot GRUB в EFI
  (без аргументов)       Запуск интерактивного меню с подсказками

ПОТОК УСТАНОВКИ WINDOWS (вариант A — через autounattend.xml и Ventoy):
  1) sudo bash deploy.sh --prep-disk
     → диск размечен и отформатирован, рядом с Windows ISO создан autounattend.xml
  2) Загрузите Windows ISO с Ventoy — установщик применит autounattend.xml
     и поставит Windows на раздел C: без запросов
  3) sudo bash deploy.sh --reinstall-ubuntu
     → Ubuntu ставится последней, GRUB с os-prober увидит Windows

ОПЦИИ:
  --dry-run              Режим симуляции (команды выводятся, но не исполняются)
  --yes, -y              Пропуск запросов подтверждения
  --disk /dev/sdX        Принудительный выбор целевого накопителя
  -h, --help             Показать эту справку
EOF
    exit 0
}

# Разбор аргументов командной строки
while (( $# )); do
    case "$1" in
        --prep-disk)           MODE="PREP_DISK" ;;
        --full|-f)             MODE="PREP_DISK" ;;
        --reinstall-ubuntu)    MODE="REINSTALL_UBUNTU" ;;
        --reinstall-windows)   die "Режим --reinstall-windows удалён: Windows ставится загрузкой ISO с Ventoy (autounattend.xml), затем --reinstall-ubuntu (см. --help)." ;;
        --repair-boot)         MODE="REPAIR_BOOT" ;;
        --dry-run)             DRY=1 ;;
        --yes|-y)              YES=1 ;;
        --disk)                TARGET_DISK="${2:?Укажите диск после --disk}"; shift ;;
        -h|--help)             usage ;;
        *) die "Неизвестный параметр: $1 (используйте --help)" ;;
    esac
    shift
done

# Проверка прав суперпользователя
[[ $EUID -eq 0 ]] || die "Скрипт должен запускаться с правами root: sudo bash $0"

# Определение целевого диска
detect_disk() {
    if [[ "$TARGET_DISK" == "AUTO" ]]; then
        local found=""
        for d in /dev/nvme0n1 /dev/sda /dev/vda; do
            if [[ -b "$d" ]]; then
                local is_usb
                is_usb=$(udevadm info -q property -n "$d" 2>/dev/null | grep -E "^ID_BUS=usb" || true)
                if [[ -z "$is_usb" ]]; then
                    found="$d"
                    break
                fi
            fi
        done
        TARGET_DISK="${found:-/dev/nvme0n1}"
    fi
    [[ -b "$TARGET_DISK" ]] || die "Целевой диск $TARGET_DISK не найден!"
}

# Поиск ISO образов (включая точки монтирования Ventoy /isodevice и /cdrom)
find_isos() {
    WIN_ISO=""
    UBUNTU_ISO=""
    local search_dirs=("$SCRIPT_DIR" "/isodevice" "/cdrom" "/media" "/mnt" "/tmp" "$HOME")
    
    for dir in "${search_dirs[@]}"; do
        if [[ -d "$dir" ]]; then
            if [[ -z "$WIN_ISO" ]]; then
                WIN_ISO=$(find "$dir" -maxdepth 3 -type f \( -iname "*win*.iso" -o -iname "*windows*.iso" \) 2>/dev/null | head -n 1 || true)
            fi
            if [[ -z "$UBUNTU_ISO" ]]; then
                UBUNTU_ISO=$(find "$dir" -maxdepth 3 -type f \( -iname "*ubuntu*.iso" -o -iname "*noble*.iso" -o -iname "*jammy*.iso" \) 2>/dev/null | head -n 1 || true)
            fi
        fi
    done
}

# Интерактивное меню
show_menu() {
    detect_disk
    find_isos
    local disk_size
    disk_size=$(lsblk -bno SIZE "$TARGET_DISK" | head -n 1 | awk '{printf "%.1f GB", $1/1024/1024/1024}')
    local disk_model
    disk_model=$(lsblk -no MODEL "$TARGET_DISK" | head -n 1 | xargs)

    echo -e "${C_BOLD}======================================================================${C_RESET}"
    echo -e "${C_CYAN}    🚀 УНИВЕРСАЛЬНЫЙ ДИСПЕТЧЕР РАЗВЕРТЫВАНИЯ DUAL-BOOT (PROVISIONING) ${C_RESET}"
    echo -e "${C_BOLD}======================================================================${C_RESET}"
    echo -e "Целевой накопитель : ${C_GREEN}${TARGET_DISK}${C_RESET} (${disk_model}, ${disk_size})"
    echo -e "Образ Windows 11   : ${WIN_ISO:-${C_YELLOW}Не найден (Windows ставится загрузкой ISO с Ventoy)${C_RESET}}"
    echo -e "Образ Ubuntu       : ${UBUNTU_ISO:-${C_YELLOW}Не найден (требуется ISO Ubuntu 24.04)${C_RESET}}"
    echo -e "Среда исполнения   : ${C_GREEN}RAM (/tmp)${C_RESET} (полная защита от блокировок Live-USB)"
    echo -e "----------------------------------------------------------------------"
    echo -e "ПОТОК УСТАНОВКИ (этапы):"
    echo -e "  ${C_BOLD}[1]${C_RESET} 💥 ${C_RED}Разметить и подготовить диск${C_RESET} (GPT + autounattend.xml для Windows)"
    echo -e "  ${C_BOLD}[2]${C_RESET} 🪟 ${C_BLUE}Загрузить Windows ISO с Ventoy${C_RESET} (установит Windows на C: по autounattend.xml)"
    echo -e "  ${C_BOLD}[3]${C_RESET} 🔄 ${C_GREEN}Установить ТОЛЬКО Ubuntu${C_RESET} (корень /), сохранив /home, Windows и Shared"
    echo -e "  ${C_BOLD}[4]${C_RESET} 🔧 ${C_YELLOW}Восстановить загрузчик Dual-Boot GRUB в EFI${C_RESET}"
    echo -e "  ${C_BOLD}[0]${C_RESET} ❌ Выход"
    echo -e "----------------------------------------------------------------------"
    read -rp "Введите номер действия [0-4]: " choice

    case "$choice" in
        1) MODE="PREP_DISK" ;;
        2) info "Этап 2 — ВРУЧНУЮ: перезагрузите компьютер и выберите Windows ISO в меню Ventoy."
           info "Установщик сам применит autounattend.xml и поставит Windows на раздел C:."
           info "Затем снова загрузите Live-среду и выполните: sudo bash $0 --reinstall-ubuntu"
           exit 0 ;;
        3) MODE="REINSTALL_UBUNTU" ;;
        4) MODE="REPAIR_BOOT" ;;
        0) exit 0 ;;
        *) die "Неверный выбор" ;;
    esac
}

# 1. Полная разметка диска
do_partition_disk() {
    info "Разметка диска $TARGET_DISK в стиле GPT..."
    
    run swapoff -a || true
    for p in $(lsblk -lno NAME "$TARGET_DISK" | tail -n +2); do
        run umount "/dev/$p" 2>/dev/null || true
    done

    run parted -s "$TARGET_DISK" mklabel gpt

    local cur_mb=1
    # p1: EFI System Partition (500 MB)
    local efi_end=$((cur_mb + EFI_SIZE_MB))
    run parted -s "$TARGET_DISK" mkpart "EFI" fat32 "${cur_mb}MiB" "${efi_end}MiB"
    run parted -s "$TARGET_DISK" set 1 boot on
    run parted -s "$TARGET_DISK" set 1 esp on
    cur_mb=$efi_end

    # p2: Microsoft Reserved Partition (16 MB)
    local msr_end=$((cur_mb + MSR_SIZE_MB))
    run parted -s "$TARGET_DISK" mkpart "Microsoft reserved partition" "${cur_mb}MiB" "${msr_end}MiB"
    run parted -s "$TARGET_DISK" set 2 msftres on
    cur_mb=$msr_end

    # p3: Windows C: (250 GB)
    local win_end=$((cur_mb + WINDOWS_SIZE_GB * 1024))
    run parted -s "$TARGET_DISK" mkpart "Windows" ntfs "${cur_mb}MiB" "${win_end}MiB"
    run parted -s "$TARGET_DISK" set 3 msftdata on
    cur_mb=$win_end

    # p4: Windows Recovery (1000 MB)
    local rec_end=$((cur_mb + RECOVERY_SIZE_MB))
    run parted -s "$TARGET_DISK" mkpart "Recovery" ntfs "${cur_mb}MiB" "${rec_end}MiB"
    run parted -s "$TARGET_DISK" set 4 hidden on
    run parted -s "$TARGET_DISK" set 4 diag on
    cur_mb=$rec_end

    # p5: Shared Data D: (100 GB exFAT)
    local shared_end=$((cur_mb + SHARED_SIZE_GB * 1024))
    run parted -s "$TARGET_DISK" mkpart "SHARED" "${cur_mb}MiB" "${shared_end}MiB"
    run parted -s "$TARGET_DISK" set 5 msftdata on
    cur_mb=$shared_end

    # p6: Ubuntu Root / (120 GB ext4)
    local root_end=$((cur_mb + UBUNTU_ROOT_SIZE_GB * 1024))
    run parted -s "$TARGET_DISK" mkpart "UbuntuRoot" ext4 "${cur_mb}MiB" "${root_end}MiB"
    cur_mb=$root_end

    # p7: Ubuntu Home /home (на все оставшееся место)
    run parted -s "$TARGET_DISK" mkpart "UbuntuHome" ext4 "${cur_mb}MiB" 100%

    run partprobe "$TARGET_DISK" || true
    run sleep 2
    success "Таблица разделов успешно создана!"
}

# 2. Форматирование разделов
do_format_partitions() {
    info "Форматирование разделов..."
    local sep=""
    [[ "$TARGET_DISK" =~ [0-9]$ ]] && sep="p"

    local p_efi="${TARGET_DISK}${sep}1"
    local p_win="${TARGET_DISK}${sep}3"
    local p_rec="${TARGET_DISK}${sep}4"
    local p_shared="${TARGET_DISK}${sep}5"
    local p_root="${TARGET_DISK}${sep}6"
    local p_home="${TARGET_DISK}${sep}7"

    run mkfs.fat -F32 -n "EFI" "$p_efi"
    run mkfs.ntfs -f -L "Windows" "$p_win"
    run mkfs.ntfs -f -L "Recovery" "$p_rec"
    
    if [[ "$SHARED_FSTYPE" == "exfat" ]]; then
        run mkfs.exfat -L "SHARED" "$p_shared" || run mkexfatfs -l "SHARED" "$p_shared"
    else
        run mkfs.ntfs -f -L "SHARED" "$p_shared"
    fi

    run mkfs.ext4 -F -L "UbuntuRoot" "$p_root"
    run mkfs.ext4 -F -L "UbuntuHome" "$p_home"
    success "Все файловые системы отформатированы!"
}

# 3. Подготовка диска под Dual-Boot (Windows ставится загрузкой ISO с Ventoy)
# ------------------------------------------------------------------------------
# Генерация полного autounattend.xml из templates/unattend.xml.template:
# DiskConfiguration (WillWipeDisk=false, ModifyPartition по размерам нашей
# разметки) + все компоненты (локали, OOBE, UTC, Fast Startup, BitLocker).
# Файл кладётся рядом с Windows ISO на флешке, чтобы Ventoy передал его
# установщику при загрузке ISO.
generate_autounattend() {
    local template="${SCRIPT_DIR}/templates/unattend.xml.template"
    if [[ ! -f "$template" ]]; then
        # RAM-копия могла не забрать шаблон — берём из оригинального каталога
        template="${ORIG_SCRIPT_DIR}/templates/unattend.xml.template"
    fi
    [[ -f "$template" ]] || die "Шаблон autounattend.xml не найден: $template"

    # Наша GPT-разметка: 1=EFI, 2=MSR, 3=Windows(C:), 4=Recovery, 5=Shared,
    # 6=UbuntuRoot, 7=UbuntuHome. Windows Setup нумерует разделы так же.
    local win_part_id=3
    local img_index="${WIN_IMAGE_INDEX:-1}"

    # Определяем каталог Windows ISO (обычно это флешка Ventoy)
    local out_dir=""
    if [[ -n "$WIN_ISO" && -f "$WIN_ISO" ]]; then
        out_dir="$(dirname "$WIN_ISO")"
        [[ -w "$out_dir" ]] || out_dir=""
    fi
    if [[ -z "$out_dir" ]]; then
        warn "Windows ISO не найден или каталог не доступен на запись — autounattend.xml будет создан в $ORIG_SCRIPT_DIR (скопируйте его рядом с Windows ISO)."
        out_dir="$ORIG_SCRIPT_DIR"
    fi
    local out_file="${out_dir}/autounattend.xml"

    if (( DRY )); then
        echo -e "  ${C_CYAN}[dry-run]${C_RESET} sed-подстановка $template → $out_file"
        echo -e "  ${C_CYAN}[dry-run]${C_RESET} (USERNAME=$USERNAME, HOSTNAME=$HOSTNAME, Windows-раздел=$win_part_id, index образа=$img_index, TZ=$(iana_to_windows_tz "$TIMEZONE"))"
        return 0
    fi

    info "Генерация autounattend.xml (DiskConfiguration под нашу разметку, WillWipeDisk=false)..."
    # Пароль вставляется в XML — сначала экранируем XML-спецсимволы, затем
    # спецсимволы sed (& и разделитель), чтобы подстановка была безопасной.
    local pwd_xml pwd_esc
    pwd_xml=$(printf '%s' "$WIN_PASSWORD" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g')
    pwd_esc=$(printf '%s' "$pwd_xml" | sed 's/[&/\]/\\&/g')
    if ! sed -e "s/__USERNAME__/${USERNAME}/g" \
             -e "s/__HOSTNAME__/${HOSTNAME}/g" \
             -e "s/__WIN_PARTITION_ID__/${win_part_id}/g" \
             -e "s/__WIN_IMAGE_INDEX__/${img_index}/g" \
             -e "s/__WIN_PASSWORD__/${pwd_esc}/g" \
             -e "s/__WIN_TIMEZONE__/$(iana_to_windows_tz "$TIMEZONE")/g" \
             "$template" > "$out_file"; then
        die "Не удалось сгенерировать autounattend.xml: $out_file"
    fi
    success "autounattend.xml создан: $out_file"
    info "Загрузите Windows ISO с Ventoy — установщик применит этот файл автоматически."
}

# 3a. Разметка + форматирование БЕЗ установки ОС (этап подготовки к Windows)
do_prep_disk() {
    do_partition_disk
    do_format_partitions
    generate_autounattend
    echo
    info "Диск подготовлен. Дальнейший поток установки:"
    info "  1) Перезагрузитесь и загрузите Windows ISO с Ventoy — autounattend.xml"
    info "     поставит Windows на раздел C: (раздел 3) без запросов."
    info "  2) После установки Windows снова загрузите Live-среду и выполните:"
    info "     sudo bash $0 --reinstall-ubuntu   # Ubuntu + GRUB с os-prober последним"
}

# 3b. Установка Windows загрузкой ISO с Ventoy (autounattend). Этот этап
# выполняется ВРУЧНУЮ пользователем (перезагрузка + выбор ISO в меню Ventoy),
# поэтому в CLI отдельного режима не имеет: см. do_prep_disk.
# 4. Развертывание Ubuntu и настройка /swapfile + 7 правил
do_deploy_ubuntu() {
    info "Развертывание Ubuntu..."
    local sep=""
    [[ "$TARGET_DISK" =~ [0-9]$ ]] && sep="p"
    local p_efi="${TARGET_DISK}${sep}1"
    local p_shared="${TARGET_DISK}${sep}5"
    local p_root="${TARGET_DISK}${sep}6"
    local p_home="${TARGET_DISK}${sep}7"

    local root_mnt="/tmp/ubuntu_root_mnt"
    run mkdir -p "$root_mnt"
    run mount "$p_root" "$root_mnt"
    run mkdir -p "$root_mnt/home" "$root_mnt/boot/efi" "$root_mnt/mnt/Shared" "$root_mnt/etc"
    run mount "$p_home" "$root_mnt/home"
    run mount "$p_efi" "$root_mnt/boot/efi"

    if [[ -n "$UBUNTU_ISO" && -f "$UBUNTU_ISO" ]]; then
        info "Извлечение системы из $UBUNTU_ISO..."
        local ubu_iso_mnt="/tmp/ubu_iso_mnt"
        run mkdir -p "$ubu_iso_mnt"
        run mount -o loop,ro "$UBUNTU_ISO" "$ubu_iso_mnt"
        
        if ! (( DRY )); then
            local squash=""
            for sq in "$ubu_iso_mnt/casper/filesystem.squashfs" "$ubu_iso_mnt/casper/ubuntu-desktop.squashfs"; do
                [[ -f "$sq" ]] && squash="$sq" && break
            done

            if [[ -n "$squash" ]]; then
                command -v unsquashfs >/dev/null || apt install -y -qq squashfs-tools
                unsquashfs -f -d "$root_mnt" "$squash"
            fi
            umount "$ubu_iso_mnt"
        else
            echo -e "  ${C_CYAN}[dry-run]${C_RESET} unsquashfs -f -d $root_mnt /casper/filesystem.squashfs"
        fi
    else
        if (( DRY )); then
            echo -e "  ${C_CYAN}[dry-run]${C_RESET} Требуется ISO Ubuntu (debootstrap не поддерживается) — реальный запуск будет остановлен"
        else
            # debootstrap даёт систему без ядра и загрузчика — не поддерживается.
            # Ubuntu ставится только из ISO (unsquashfs), как и задокументировано.
            die "Требуется ISO Ubuntu (debootstrap не поддерживается). Поместите Ubuntu ISO рядом со скриптом или укажите путь в конфигурации."
        fi
    fi

    # Генерация /swapfile на 4 ГБ
    info "Создание динамического /swapfile ($SWAPFILE_SIZE_GB ГБ)..."
    run fallocate -l "${SWAPFILE_SIZE_GB}G" "$root_mnt/swapfile" || run dd if=/dev/zero of="$root_mnt/swapfile" bs=1M count=$((SWAPFILE_SIZE_GB * 1024)) status=progress
    run chmod 600 "$root_mnt/swapfile"
    run mkswap "$root_mnt/swapfile"

    if ! (( DRY )); then
        local u_root u_home u_efi u_shared
        u_root=$(blkid -s UUID -o value "$p_root" || echo "ROOT_UUID")
        u_home=$(blkid -s UUID -o value "$p_home" || echo "HOME_UUID")
        u_efi=$(blkid -s UUID -o value "$p_efi" || echo "EFI_UUID")
        u_shared=$(blkid -s UUID -o value "$p_shared" || echo "SHARED_UUID")

        cat << EOF > "$root_mnt/etc/fstab"
# /etc/fstab — Автоматически сгенерировано deploy.sh
UUID=${u_root}   /               ext4    errors=remount-ro 0       1
UUID=${u_home}   /home           ext4    defaults          0       2
UUID=${u_efi}    /boot/efi       vfat    umask=0077        0       1
/swapfile        none            swap    sw                0       0
EOF
        if [[ $ENABLE_SHARED_AUTOMOUNT -eq 1 ]]; then
            echo "UUID=${u_shared} /mnt/Shared     exfat   defaults,uid=1000,gid=1000,nofail 0 0" >> "$root_mnt/etc/fstab"
        fi

        echo "$HOSTNAME" > "$root_mnt/etc/hostname"
        echo "127.0.0.1 localhost $HOSTNAME" > "$root_mnt/etc/hosts"

        # Часовой пояс из deploy.conf: симлинк zoneinfo (в chroot timedatectl не работает)
        if [[ -n "$TIMEZONE" && -e "/usr/share/zoneinfo/$TIMEZONE" ]]; then
            ln -sf "/usr/share/zoneinfo/$TIMEZONE" "$root_mnt/etc/localtime"
            echo "$TIMEZONE" > "$root_mnt/etc/timezone"
            info "Установлен часовой пояс: $TIMEZONE"
        else
            warn "TIMEZONE=$TIMEZONE не найден в /usr/share/zoneinfo — часовой пояс оставлен по умолчанию."
        fi

        # Язык системы по умолчанию из deploy.conf
        if [[ -n "$DEFAULT_LOCALE" ]]; then
            if chroot "$root_mnt" locale-gen "$DEFAULT_LOCALE" 2>/dev/null; then
                chroot "$root_mnt" update-locale "LANG=$DEFAULT_LOCALE" 2>/dev/null || \
                    warn "update-locale не смог применить DEFAULT_LOCALE=$DEFAULT_LOCALE."
            else
                warn "locale-gen не смог сгенерировать DEFAULT_LOCALE=$DEFAULT_LOCALE."
            fi
        fi

        # RTC в UTC (часы не сбиваются с Windows): timedatectl в chroot не
        # работает, поэтому пишем /etc/adjtime напрямую
        if [[ $ENABLE_UTC_TIME -eq 1 ]]; then
            printf '0.0 0 0\n0\nUTC\n' > "$root_mnt/etc/adjtime"
        fi
        [[ $ENABLE_FSTRIM_TIMER -eq 1 ]] && chroot "$root_mnt" systemctl enable fstrim.timer 2>/dev/null || true

        chroot "$root_mnt" useradd -m -s /bin/bash -G sudo "$USERNAME" 2>/dev/null || true
        echo "${USERNAME}:${USERNAME}" | chroot "$root_mnt" chpasswd 2>/dev/null || true

        info "Установка загрузчика GRUB в EFI..."
        for dev in /dev /dev/pts /proc /sys /run; do
            mount --bind "$dev" "${root_mnt}${dev}"
        done

        chroot "$root_mnt" apt update -qq 2>/dev/null || true
        chroot "$root_mnt" apt install -y -qq grub-efi-amd64 grub-efi-amd64-signed os-prober 2>/dev/null || true

        # Проприетарные драйверы (Nvidia/Wi-Fi) — не критично при сбое
        if [[ $INSTALL_RESTRICTED_DRIVERS -eq 1 ]]; then
            info "Установка проприетарных драйверов (ubuntu-drivers autoinstall)..."
            if ! chroot "$root_mnt" ubuntu-drivers autoinstall 2>/dev/null; then
                warn "ubuntu-drivers autoinstall завершился с ошибкой — драйверы можно доустановить позже."
            fi
        fi

        chroot "$root_mnt" grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu --recheck
        
        if [[ $PROTECT_GRUB_REMOVABLE -eq 1 ]]; then
            chroot "$root_mnt" grub-install --target=x86_64-efi --efi-directory=/boot/efi --removable
        fi

        enable_os_prober "$root_mnt"
        chroot "$root_mnt" update-grub

        for dev in /run /sys /proc /dev/pts /dev; do
            umount "${root_mnt}${dev}" 2>/dev/null || true
        done
        umount "$root_mnt/boot/efi" "$root_mnt/home" "$root_mnt"
    else
        echo -e "  ${C_CYAN}[dry-run]${C_RESET} Генерация /etc/fstab (Root + Home + EFI + /swapfile; /mnt/Shared — при ENABLE_SHARED_AUTOMOUNT=1)"
        echo -e "  ${C_CYAN}[dry-run]${C_RESET} Создание пользователя $USERNAME, fstrim.timer, RTC UTC, TZ=$TIMEZONE, locale=$DEFAULT_LOCALE"
        echo -e "  ${C_CYAN}[dry-run]${C_RESET} ubuntu-drivers autoinstall (при INSTALL_RESTRICTED_DRIVERS=1)"
        echo -e "  ${C_CYAN}[dry-run]${C_RESET} grub-install --target=x86_64-efi --removable + os-prober (Dual-Boot)"
    fi
    success "Ubuntu успешно установлена и настроена!"
}

# Запуск
main() {
    [[ -z "$MODE" ]] && show_menu
    detect_disk
    find_isos

    info "Запуск режима: $MODE на диске $TARGET_DISK"
    # В dry-run подтверждение не требуется: команды не исполняются
    if (( ! YES && ! DRY )); then
        read -rp "Вы уверены, что хотите продолжить? [Д/Y/н]: " ans
        [[ "${ans,,}" =~ ^(д|да|y|yes)$ ]] || die "Операция отменена пользователем."
    fi

    case "$MODE" in
        PREP_DISK)
            # Полный поток, этап 1: разметка+формат+autounattend. Windows
            # ставится загрузкой ISO с Ventoy, Ubuntu — позже (--reinstall-ubuntu),
            # чтобы GRUB с os-prober увидел Windows последним (см. usage/README).
            do_prep_disk
            ;;
        REINSTALL_UBUNTU)
            info "Точечная переустановка Ubuntu (корень /)..."
            local sep=""
            [[ "$TARGET_DISK" =~ [0-9]$ ]] && sep="p"
            run mkfs.ext4 -F -L "UbuntuRoot" "${TARGET_DISK}${sep}6"
            do_deploy_ubuntu
            ;;
        REPAIR_BOOT)
            info "Восстановление загрузчика GRUB..."
            local sep=""
            [[ "$TARGET_DISK" =~ [0-9]$ ]] && sep="p"
            local root_mnt="/tmp/boot_repair_root"
            run mkdir -p "$root_mnt"
            run mount "${TARGET_DISK}${sep}6" "$root_mnt"
            run mount "${TARGET_DISK}${sep}1" "$root_mnt/boot/efi"
            if ! (( DRY )); then
                for dev in /dev /dev/pts /proc /sys /run; do mount --bind "$dev" "${root_mnt}${dev}"; done
                chroot "$root_mnt" grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu --removable
                enable_os_prober "$root_mnt"
                chroot "$root_mnt" update-grub
                for dev in /run /sys /proc /dev/pts /dev; do umount "${root_mnt}${dev}" 2>/dev/null || true; done
                umount "$root_mnt/boot/efi" "$root_mnt"
            else
                echo -e "  ${C_CYAN}[dry-run]${C_RESET} grub-install --removable && update-grub"
            fi
            success "Загрузчик успешно восстановлен!"
            ;;
    esac

    echo
    echo -e "${C_GREEN}${C_BOLD}======================================================================${C_RESET}"
    echo -e "${C_GREEN}${C_BOLD} 🎉 ВСЕ ОПЕРАЦИИ УСПЕШНО ЗАВЕРШЕНЫ!${C_RESET}"
    echo -e "${C_GREEN}${C_BOLD}======================================================================${C_RESET}"
    echo -e "Компьютер готов к работе. Извлеките Live-флешку и перезагрузитесь."
}

main
