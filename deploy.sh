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

REAL_SOURCE="$(realpath "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "$REAL_SOURCE")" && pwd)"

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
    ROOT_FSTYPE="ext4"
    HOME_FSTYPE="ext4"
    USERNAME="asv-spb"
    HOSTNAME="workstation"
    TIMEZONE="Europe/Moscow"
    DEFAULT_LOCALE="ru_RU.UTF-8"
    ENABLE_UTC_TIME=1
    DISABLE_FAST_STARTUP=1
    DISABLE_BITLOCKER=1
    ENABLE_FSTRIM_TIMER=1
    INSTALL_RESTRICTED_DRIVERS=1
    PROTECT_GRUB_REMOVABLE=1
    ENABLE_SHARED_AUTOMOUNT=1
fi

DRY=0
FORCE=0
YES=0
MODE=""

usage() {
    cat << 'EOF'
Использование: sudo bash deploy.sh [РЕЖИМ] [ОПЦИИ]

РЕЖИМЫ:
  --full, -f             Полная чистая установка с переразметкой всего диска
  --reinstall-ubuntu     Переустановка только Ubuntu (корень /), сохраняя /home, Windows и Shared
  --reinstall-windows    Переустановка только Windows (диск C:), сохраняя Linux, /home и Shared
  --repair-boot          Восстановление/переустановка загрузчика Dual-Boot GRUB в EFI
  (без аргументов)       Запуск интерактивного меню с подсказками

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
        --full|-f)             MODE="FULL" ;;
        --reinstall-ubuntu)    MODE="REINSTALL_UBUNTU" ;;
        --reinstall-windows)   MODE="REINSTALL_WINDOWS" ;;
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
    echo -e "Образ Windows 11   : ${WIN_ISO:-${C_YELLOW}Не найден (установка Windows будет пропущена)${C_RESET}}"
    echo -e "Образ Ubuntu       : ${UBUNTU_ISO:-${C_YELLOW}Не найден (будет использован сетевой debootstrap)${C_RESET}}"
    echo -e "Среда исполнения   : ${C_GREEN}RAM (/tmp)${C_RESET} (полная защита от блокировок Live-USB)"
    echo -e "----------------------------------------------------------------------"
    echo -e "Выберите режим работы:"
    echo -e "  ${C_BOLD}[1]${C_RESET} 💥 ${C_RED}ПОЛНОЕ развертывание с нуля${C_RESET} (разметка GPT + Windows + Ubuntu + Shared + /home)"
    echo -e "  ${C_BOLD}[2]${C_RESET} 🔄 ${C_GREEN}Переустановить ТОЛЬКО Ubuntu${C_RESET} (корень /), сохранив /home, Windows и Shared"
    echo -e "  ${C_BOLD}[3]${C_RESET} 🪟 ${C_BLUE}Переустановить ТОЛЬКО Windows${C_RESET} (диск C:), сохранив Linux, /home и Shared"
    echo -e "  ${C_BOLD}[4]${C_RESET} 🔧 ${C_YELLOW}Восстановить загрузчик Dual-Boot GRUB в EFI${C_RESET}"
    echo -e "  ${C_BOLD}[0]${C_RESET} ❌ Выход"
    echo -e "----------------------------------------------------------------------"
    read -rp "Введите номер действия [0-4]: " choice

    case "$choice" in
        1) MODE="FULL" ;;
        2) MODE="REINSTALL_UBUNTU" ;;
        3) MODE="REINSTALL_WINDOWS" ;;
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

# 3. Развертывание Windows
do_deploy_windows() {
    if [[ -z "$WIN_ISO" || ! -f "$WIN_ISO" ]]; then
        warn "Образ Windows не найден, пропуск установки Windows."
        return 0
    fi

    info "Развертывание Windows из $WIN_ISO..."
    if ! (( DRY )); then
        command -v wimlib-imagex >/dev/null || {
            info "Установка wimtools..."
            apt update -qq && apt install -y -qq wimtools
        }
    fi

    local sep=""
    [[ "$TARGET_DISK" =~ [0-9]$ ]] && sep="p"
    local p_win="${TARGET_DISK}${sep}3"

    local iso_mnt="/tmp/win_iso_mnt"
    run mkdir -p "$iso_mnt"
    run mount -o loop,ro "$WIN_ISO" "$iso_mnt"

    if ! (( DRY )); then
        local wim_file=""
        if [[ -f "$iso_mnt/sources/install.wim" ]]; then
            wim_file="$iso_mnt/sources/install.wim"
        elif [[ -f "$iso_mnt/sources/install.esd" ]]; then
            wim_file="$iso_mnt/sources/install.esd"
        fi

        [[ -n "$wim_file" ]] || die "Не найден install.wim/install.esd в $WIN_ISO"

        info "Распаковка образа Windows на $p_win (через wimlib-imagex)..."
        wimlib-imagex apply "$wim_file" 1 "$p_win"

        local win_mnt="/tmp/win_sys_mnt"
        mkdir -p "$win_mnt"
        mount "$p_win" "$win_mnt"
        mkdir -p "$win_mnt/Windows/Panther"

        local template="${SCRIPT_DIR}/templates/unattend.xml.template"
        if [[ -f "$template" ]]; then
            sed -e "s/__USERNAME__/$USERNAME/g" \
                -e "s/__HOSTNAME__/$HOSTNAME/g" \
                "$template" > "$win_mnt/Windows/Panther/unattend.xml"
            success "Файл автоответов unattend.xml успешно внедрен!"
        fi

        umount "$win_mnt"
        umount "$iso_mnt"
    else
        echo -e "  ${C_CYAN}[dry-run]${C_RESET} wimlib-imagex apply /sources/install.wim 1 $p_win"
        echo -e "  ${C_CYAN}[dry-run]${C_RESET} Внедрение unattend.xml (UTC, No FastBoot, No BitLocker)"
    fi
    success "Windows успешно развернута!"
}

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
        info "Установка базовой системы через debootstrap (Noble 24.04 LTS)..."
        run command -v debootstrap >/dev/null || run apt install -y -qq debootstrap
        run debootstrap noble "$root_mnt" http://archive.ubuntu.com/ubuntu/
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
UUID=${u_shared} /mnt/Shared     exfat   defaults,uid=1000,gid=1000,nofail 0 0
/swapfile        none            swap    sw                0       0
EOF

        echo "$HOSTNAME" > "$root_mnt/etc/hostname"
        echo "127.0.0.1 localhost $HOSTNAME" > "$root_mnt/etc/hosts"

        [[ $ENABLE_UTC_TIME -eq 1 ]] && chroot "$root_mnt" timedatectl set-local-rtc 0 2>/dev/null || true
        [[ $ENABLE_FSTRIM_TIMER -eq 1 ]] && chroot "$root_mnt" systemctl enable fstrim.timer 2>/dev/null || true

        chroot "$root_mnt" useradd -m -s /bin/bash -G sudo "$USERNAME" 2>/dev/null || true
        echo "${USERNAME}:${USERNAME}" | chroot "$root_mnt" chpasswd 2>/dev/null || true

        info "Установка загрузчика GRUB в EFI..."
        for dev in /dev /dev/pts /proc /sys /run; do
            mount --bind "$dev" "${root_mnt}${dev}"
        done

        chroot "$root_mnt" apt update -qq 2>/dev/null || true
        chroot "$root_mnt" apt install -y -qq grub-efi-amd64 grub-efi-amd64-signed os-prober 2>/dev/null || true
        chroot "$root_mnt" grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu --recheck
        
        if [[ $PROTECT_GRUB_REMOVABLE -eq 1 ]]; then
            chroot "$root_mnt" grub-install --target=x86_64-efi --efi-directory=/boot/efi --removable
        fi
        
        chroot "$root_mnt" update-grub

        for dev in /run /sys /proc /dev/pts /dev; do
            umount "${root_mnt}${dev}" 2>/dev/null || true
        done
        umount "$root_mnt/boot/efi" "$root_mnt/home" "$root_mnt"
    else
        echo -e "  ${C_CYAN}[dry-run]${C_RESET} Генерация /etc/fstab (Root + Home + EFI + /mnt/Shared + /swapfile)"
        echo -e "  ${C_CYAN}[dry-run]${C_RESET} Создание пользователя $USERNAME, fstrim.timer, RTC UTC"
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
    if (( ! YES )); then
        read -rp "Вы уверены, что хотите продолжить? [Д/Y/н]: " ans
        [[ "${ans,,}" =~ ^(д|да|y|yes)$ ]] || die "Операция отменена пользователем."
    fi

    case "$MODE" in
        FULL)
            do_partition_disk
            do_format_partitions
            do_deploy_windows
            do_deploy_ubuntu
            ;;
        REINSTALL_UBUNTU)
            info "Точечная переустановка Ubuntu (корень /)..."
            local sep=""
            [[ "$TARGET_DISK" =~ [0-9]$ ]] && sep="p"
            run mkfs.ext4 -F -L "UbuntuRoot" "${TARGET_DISK}${sep}6"
            do_deploy_ubuntu
            ;;
        REINSTALL_WINDOWS)
            info "Точечная переустановка Windows..."
            local sep=""
            [[ "$TARGET_DISK" =~ [0-9]$ ]] && sep="p"
            run mkfs.ntfs -f -L "Windows" "${TARGET_DISK}${sep}3"
            do_deploy_windows
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
