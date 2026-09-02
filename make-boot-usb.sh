#!/usr/bin/env bash
# ==============================================================================
# make-boot-usb.sh — Автоматизированное создание и форматирование загрузочных
#                    флешек Ventoy с сохранением данных и тестами скорости
# ==============================================================================
set -Eeuo pipefail

C_RESET="\033[0m"
C_BOLD="\033[1m"
C_GREEN="\033[1;32m"
C_BLUE="\033[1;34m"
C_CYAN="\033[1;36m"
C_YELLOW="\033[1;33m"
C_RED="\033[1;31m"

info()    { echo -e "${C_BLUE}[ИНФО]${C_RESET} $*"; }
success() { echo -e "${C_GREEN}[УСПЕХ]${C_RESET} $*"; }
warn()    { echo -e "${C_YELLOW}[ВНИМАНИЕ]${C_RESET} $*" >&2; }
die()     { echo -e "${C_RED}[ОШИБКА]${C_RESET} $*" >&2; exit 1; }

# ------------------------------------------------------------------------------
# 0. Автоматический перезапуск от root при запуске обычным пользователем
# ------------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    exec sudo bash "$0" "$@"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENTOY_VERSION="1.1.17"
VENTOY_DIR="/tmp/ventoy-${VENTOY_VERSION}"
BACKUP_DIR="/tmp/usb_backup_$$"
DO_RESTORE=0

for cmd in parted mkfs.exfat mkfs.f2fs wget tar dd dosfsck rsync; do
    if ! command -v "$cmd" &>/dev/null; then
        info "Установка недостающей утилиты: $cmd..."
        apt-get update -qq && apt-get install -y -qq parted exfatprogs f2fs-tools ntfs-3g dosfstools wget tar rsync coreutils || true
    fi
done

ensure_ventoy_tool() {
    if [[ -x "${VENTOY_DIR}/Ventoy2Disk.sh" ]]; then
        return 0
    fi
    local local_v2d
    local_v2d=$(find /home /tmp -name "Ventoy2Disk.sh" 2>/dev/null | head -n 1 || true)
    if [[ -n "$local_v2d" && -x "$local_v2d" ]]; then
        VENTOY_DIR="$(dirname "$local_v2d")"
        return 0
    fi

    info "Скачивание Ventoy v${VENTOY_VERSION}..."
    mkdir -p "$VENTOY_DIR"
    wget -qO- "https://github.com/ventoy/Ventoy/releases/download/v${VENTOY_VERSION}/ventoy-${VENTOY_VERSION}-linux.tar.gz" | \
        tar -xz -C "/tmp"
    VENTOY_DIR="/tmp/ventoy-${VENTOY_VERSION}"
}

# ------------------------------------------------------------------------------
# 1. Проверка целостности и битых файлов накопителя
# ------------------------------------------------------------------------------
check_drive_integrity() {
    echo -e "\n${C_BOLD}======================================================================${C_RESET}"
    echo -e "${C_CYAN}  🩺 ПРОВЕРКА ЦЕЛОСТНОСТИ И БИТЫХ ФАЙЛОВ НА ФЛЕШКЕ:${C_RESET}"
    echo -e "${C_BOLD}======================================================================${C_RESET}"

    local parts=()
    while IFS= read -r p; do
        [[ -n "$p" ]] && parts+=("$p")
    done < <(lsblk -npo NAME "$TARGET_DISK" | grep -v "^${TARGET_DISK}$" || true)

    if [[ ${#parts[@]} -eq 0 ]]; then
        info "На флешке нет разделов. Проверка прямого чтения первых 100 МБ блоков..."
        if dd if="$TARGET_DISK" of=/dev/null bs=1M count=100 status=none 2>/dev/null; then
            success "Блоки памяти считываются без аппаратных ошибок (I/O OK)."
        else
            warn "Обнаружены ошибки ввода-вывода (I/O errors) при чтении накопителя!"
        fi
        return 0
    fi

    info "Найдено разделов для проверки: ${#parts[@]}"
    local has_errors=0

    for part in "${parts[@]}"; do
        local fstype label
        fstype=$(lsblk -no FSTYPE "$part" || true)
        label=$(lsblk -no LABEL "$part" || true)
        echo -e "\n• Сканирование раздела ${C_CYAN}${part}${C_RESET} [${fstype^^:-Неизвестно}, Метка: ${label:-Без метки}]..."
        
        umount "$part" 2>/dev/null || true
        local check_out=""

        case "$fstype" in
            vfat|fat16|fat32)
                if command -v fsck.vfat &>/dev/null; then
                    check_out=$(fsck.vfat -v -n "$part" 2>&1 || true)
                fi
                ;;
            exfat)
                if command -v fsck.exfat &>/dev/null; then
                    check_out=$(fsck.exfat "$part" 2>&1 || true)
                fi
                ;;
            f2fs)
                if command -v fsck.f2fs &>/dev/null; then
                    check_out=$(fsck.f2fs -a "$part" 2>&1 || true)
                fi
                ;;
            ntfs)
                if command -v ntfsfix &>/dev/null; then
                    check_out=$(ntfsfix -n "$part" 2>&1 || true)
                fi
                ;;
            *)
                check_out="Чтение блоков..."
                dd if="$part" of=/dev/null bs=1M count=50 status=none 2>/dev/null || check_out="Ошибка чтения блоков"
                ;;
        esac

        if echo "$check_out" | grep -iE "corrupt|dirty bit|error|bad cluster|mismatch|failed|damage|unable to read" | grep -v "0 dirty" | grep -v "0 errors" >/dev/null; then
            warn "На разделе ${part} обнаружены ошибки или поврежденные структуры!"
            echo "$check_out" | head -n 4
            has_errors=1
        else
            success "Раздел ${part}: файловая система исправна, битых файлов не обнаружено."
        fi
    done

    if (( has_errors == 0 )); then
        echo
        success "✅ Целостность накопителя в норме. Ошибок файловой структуры не обнаружено."
    else
        echo
        warn "⚠️ Обнаружены ошибки в текущих разделах. Переразметка создаст чистую файловую систему."
    fi
}

# ------------------------------------------------------------------------------
# 2. Сканирование и резервное копирование данных (Backup)
# ------------------------------------------------------------------------------

# Выбор каталога временного хранения бэкапа. Если /tmp — tmpfs (Live-среда,
# данные в нём живут в ОЗУ и не переживут перезагрузку), предлагаем путь
# пользователя или /var/tmp. Возвращает каталог в переменной BACKUP_DIR.
choose_backup_dir() {
    local tmp_fs
    tmp_fs=$(df -T /tmp 2>/dev/null | awk 'NR==2 {print $2}')
    if [[ "$tmp_fs" == "tmpfs" ]]; then
        local def_dir="/var/tmp/usb_backup_$$"
        read -rp "Каталог /tmp — это tmpfs (Live-среда). Укажите путь для бэкапа [${def_dir}]: " custom_dir
        BACKUP_DIR="${custom_dir:-$def_dir}"
    else
        BACKUP_DIR="/tmp/usb_backup_$$"
    fi
    mkdir -p "$BACKUP_DIR" || die "Не удалось создать каталог бэкапа: $BACKUP_DIR"
}

# Проверка свободного места: на носителе бэкапа должно быть >= объёма данных x1.1.
check_backup_space() {
    local need_kb avail_kb
    need_kb=$(( $1 * 11 / 10 / 1024 + 1 ))
    avail_kb=$(df -Pk "$BACKUP_DIR" 2>/dev/null | awk 'NR==2 {print $4}')
    if [[ -z "$avail_kb" || "$avail_kb" -lt "$need_kb" ]]; then
        die "Недостаточно места для бэкапа в $BACKUP_DIR: нужно ~$(( need_kb / 1024 )) МБ, свободно ${avail_kb:-0} КБ."
    fi
    info "Места для бэкапа достаточно: нужно ~$(( need_kb / 1024 )) МБ, свободно $(( avail_kb / 1024 )) МБ."
}

backup_existing_files() {
    local parts=()
    while IFS= read -r p; do
        [[ -n "$p" ]] && parts+=("$p")
    done < <(lsblk -npo NAME "$TARGET_DISK" | grep -v "^${TARGET_DISK}$" || true)

    [[ ${#parts[@]} -eq 0 ]] && return 0

    local total_bytes=0
    local tmp_scan="/tmp/mnt_scan_$$"
    mkdir -p "$tmp_scan"

    for part in "${parts[@]}"; do
        if mount -o ro "$part" "$tmp_scan" 2>/dev/null; then
            local part_bytes
            part_bytes=$(du -sb --exclude="lost+found" --exclude="System Volume Information" "$tmp_scan" 2>/dev/null | awk '{print $1}' || echo 0)
            total_bytes=$(( total_bytes + part_bytes ))
            umount "$tmp_scan" 2>/dev/null || true
        else
            warn "Раздел $part не удалось примонтировать для оценки данных."
        fi
    done
    rm -rf "$tmp_scan"

    local total_mb=$(( total_bytes / 1024 / 1024 ))
    if (( total_mb > 5 )); then
        echo -e "\n${C_BOLD}======================================================================${C_RESET}"
        echo -e "${C_CYAN}  💾 ОБНАРУЖЕНЫ ДАННЫЕ НА НАКОПИТЕЛЕ (~${total_mb} МБ):${C_RESET}"
        echo -e "${C_BOLD}======================================================================${C_RESET}"
        read -rp "Сохранить существующие файлы и вернуть их после переразметки? [Y/n]: " ans_b
        ans_b="${ans_b:-Y}"

        if [[ "${ans_b,,}" =~ ^(д|да|y|yes)$ ]]; then
            DO_RESTORE=1
            choose_backup_dir
            check_backup_space "$total_bytes"
            mkdir -p "$BACKUP_DIR/iso" "$BACKUP_DIR/data"
            info "Копирование файлов во временное хранилище на ПК..."

            local tmp_m="/tmp/mnt_bak_$$"
            mkdir -p "$tmp_m"
            for part in "${parts[@]}"; do
                if mount -o ro "$part" "$tmp_m" 2>/dev/null; then
                    # Копируем ISO/IMG/VHD в папку ISO, остальное в папку DATA
                    if ! find "$tmp_m" -maxdepth 2 -type f \( -name "*.iso" -o -name "*.img" -o -name "*.vhd" -o -name "*.wim" \) -exec cp -v {} "$BACKUP_DIR/iso/" \;; then
                        umount "$tmp_m" 2>/dev/null || true
                        die "Сбой копирования ISO-образов с раздела $part — переразметка отменена. Бэкап сохранен: $BACKUP_DIR"
                    fi

                    # Копируем все остальные пользовательские файлы и каталоги (кроме ISO и служебных)
                    if ! rsync -a --exclude="*.iso" --exclude="*.img" --exclude="*.vhd" --exclude="*.wim" \
                          --exclude="System Volume Information" --exclude="lost+found" --exclude="ventoy" \
                          "$tmp_m/" "$BACKUP_DIR/data/"; then
                        umount "$tmp_m" 2>/dev/null || true
                        die "Сбой копирования данных с раздела $part — переразметка отменена. Бэкап сохранен: $BACKUP_DIR"
                    fi
                    umount "$tmp_m" 2>/dev/null || true
                else
                    rm -rf "$tmp_m"
                    die "Раздел $part не удалось примонтировать для бэкапа — данные с него не сохранить. Переразметка отменена."
                fi
            done
            rm -rf "$tmp_m"
            success "Резервная копия успешно создана на ПК ($(du -sh "$BACKUP_DIR" | awk '{print $1}'))."
        fi
    fi
}

# ------------------------------------------------------------------------------
# 3. Восстановление сохраненных файлов
# ------------------------------------------------------------------------------

# Сверка восстановления: каждый файл из $1 (каталог бэкапа) должен присутствовать
# в $2 (смонтированный раздел флешки) с тем же размером. Возвращает 1 при
# расхождении, подробности пишет в warn.
verify_restored_tree() {
    local backup_root="$1" dest_root="$2"
    local f rel size dsize n_files=0 n_bytes=0 bad=0
    while IFS= read -r -d '' f; do
        rel="${f#"$backup_root"/}"
        if [[ ! -e "$dest_root/$rel" ]]; then
            warn "После восстановления не найден файл: $rel"
            bad=1
            continue
        fi
        size=$(stat -c %s "$f")
        dsize=$(stat -c %s "$dest_root/$rel")
        n_files=$(( n_files + 1 ))
        n_bytes=$(( n_bytes + dsize ))
        if (( size != dsize )); then
            warn "Размер файла $rel после восстановления отличается (бэкап: $size, флешка: $dsize байт)."
            bad=1
        fi
    done < <(find "$backup_root" -type f -print0 2>/dev/null)

    if (( bad )); then
        warn "Сверка восстановления НЕ пройдена: $n_files файлов из $backup_root."
        return 1
    fi
    info "Сверка восстановления пройдена: $n_files файлов, $n_bytes байт совпадают с бэкапом."
}

restore_files() {
    (( DO_RESTORE == 1 )) || return 0
    [[ -d "$BACKUP_DIR" ]] || return 0

    info "Восстановление сохраненных файлов на флешку..."

    # 1. Возвращаем ISO-образы на раздел 1
    if [[ -d "$BACKUP_DIR/iso" ]] && [[ $(ls -A "$BACKUP_DIR/iso" 2>/dev/null) ]]; then
        info "Перенос образов (.iso / .img) на Раздел 1 [${LABEL_P1}]..."
        local mnt_p1="/tmp/mnt_res_p1_$$"
        mkdir -p "$mnt_p1"
        mount "$P1" "$mnt_p1" || die "Не удалось примонтировать раздел $P1 для восстановления ISO."
        if ! cp -a "$BACKUP_DIR/iso/." "$mnt_p1/"; then
            umount "$mnt_p1" 2>/dev/null || true
            rm -rf "$mnt_p1"
            die "Сбой копирования ISO-образов на раздел $P1. Бэкап сохранен: $BACKUP_DIR"
        fi
        chown -R "${SUDO_USER:-asv-spb}:${SUDO_USER:-asv-spb}" "$mnt_p1/" 2>/dev/null || true
        local iso_ok=1
        verify_restored_tree "$BACKUP_DIR/iso" "$mnt_p1" || iso_ok=0
        umount "$mnt_p1" 2>/dev/null || true
        rm -rf "$mnt_p1"
        if (( iso_ok != 1 )); then
            die "ISO-образы восстановлены с ошибками. Резервная копия НЕ удалена: $BACKUP_DIR"
        fi
    fi

    # 2. Возвращаем пользовательские данные на раздел 3 (или раздел 1, если разделов нет)
    if [[ -d "$BACKUP_DIR/data" ]] && [[ $(ls -A "$BACKUP_DIR/data" 2>/dev/null) ]]; then
        local dest_part="$P1"
        [[ "$DATA_FS" != "none" && -b "$P3" ]] && dest_part="$P3"

        info "Перенос документов и пользовательских файлов на [${LABEL_P3:-$LABEL_P1}]..."
        local mnt_pd="/tmp/mnt_res_pd_$$"
        mkdir -p "$mnt_pd"
        mount "$dest_part" "$mnt_pd" || die "Не удалось примонтировать раздел $dest_part для восстановления данных."
        if ! cp -a "$BACKUP_DIR/data/." "$mnt_pd/"; then
            umount "$mnt_pd" 2>/dev/null || true
            rm -rf "$mnt_pd"
            die "Сбой копирования данных на раздел $dest_part. Бэкап сохранен: $BACKUP_DIR"
        fi
        chown -R "${SUDO_USER:-asv-spb}:${SUDO_USER:-asv-spb}" "$mnt_pd/" 2>/dev/null || true
        local data_ok=1
        verify_restored_tree "$BACKUP_DIR/data" "$mnt_pd" || data_ok=0
        umount "$mnt_pd" 2>/dev/null || true
        rm -rf "$mnt_pd"
        if (( data_ok != 1 )); then
            die "Данные восстановлены с ошибками. Резервная копия НЕ удалена: $BACKUP_DIR"
        fi
    fi

    # Временную копию удаляем только после успешной сверки восстановления
    rm -rf "$BACKUP_DIR"
    success "🎉 Все сохраненные файлы успешно возвращены на накопитель!"
}

# ------------------------------------------------------------------------------
# 3b. Копирование пакета Deploy Baremetal на раздел данных (как в ps1-версии)
# ------------------------------------------------------------------------------
copy_deploy_package() {
    local pkg_part="$P1"
    if [[ "$DATA_FS" != "none" && -b "$P3" ]]; then
        pkg_part="$P3"
    fi

    # Пакет должен лежать рядом со скриптом make-boot-usb.sh
    local src_dir="$SCRIPT_DIR"
    if [[ ! -f "$src_dir/deploy.sh" || ! -d "$src_dir/templates" ]]; then
        warn "Пакет deploy-baremetal (deploy.sh / templates/) не найден рядом со скриптом — копирование пропущено."
        return 0
    fi

    info "Копирование пакета Deploy Baremetal на раздел данных [$pkg_part]..."
    local mnt_pkg="/tmp/mnt_pkg_$$"
    mkdir -p "$mnt_pkg"
    if ! mount "$pkg_part" "$mnt_pkg"; then
        rm -rf "$mnt_pkg"
        warn "Не удалось примонтировать раздел данных $pkg_part — копирование пакета пропущено."
        return 0
    fi

    local target_dir="$mnt_pkg/deploy-baremetal"
    mkdir -p "$target_dir"

    local ok=1
    # Основные скрипты развертывания + конфигурация + шаблоны autounattend
    for f in split-home.sh deploy.sh deploy.conf; do
        if [[ -f "$src_dir/$f" ]]; then
            cp -r "$src_dir/$f" "$target_dir/" || { warn "Ошибка копирования $f на раздел данных."; ok=0; }
        fi
    done
    cp -r "$src_dir/templates" "$target_dir/" || { warn "Ошибка копирования templates/ на раздел данных."; ok=0; }

    umount "$mnt_pkg" 2>/dev/null || true
    rm -rf "$mnt_pkg"

    if (( ok == 1 )); then
        success "Пакет Deploy Baremetal скопирован в ${pkg_part}:/deploy-baremetal/ (split-home.sh, deploy.sh, deploy.conf, templates/)."
    else
        warn "Копирование пакета завершилось с ошибками — проверьте раздел данных."
    fi
}

# ------------------------------------------------------------------------------
# Замер скорости чтения / записи
# ------------------------------------------------------------------------------
run_speed_test() {
    local mnt_path="$1"
    local title="$2"
    local size_mb="${3:-512}"

    [[ -d "$mnt_path" ]] || return 0
    local test_file="${mnt_path}/__speed_test_${RANDOM}__.tmp"

    echo -e "\n${C_BOLD}⏱️ Замер скорости: ${C_CYAN}${title}${C_RESET} (размер блока: ${size_mb} МБ)..."
    
    local start_w end_w dur_w_ms speed_w
    start_w=$(date +%s%N)
    dd if=/dev/zero of="$test_file" bs=4M count=$(( size_mb / 4 )) conv=fdatasync status=none
    end_w=$(date +%s%N)
    dur_w_ms=$(( (end_w - start_w) / 1000000 ))
    (( dur_w_ms < 1 )) && dur_w_ms=1
    speed_w=$(awk "BEGIN {printf \"%.2f\", ($size_mb * 1000) / $dur_w_ms}")

    sync
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true

    local start_r end_r dur_r_ms speed_r
    start_r=$(date +%s%N)
    dd if="$test_file" of=/dev/null bs=4M status=none
    end_r=$(date +%s%N)
    dur_r_ms=$(( (end_r - start_r) / 1000000 ))
    (( dur_r_ms < 1 )) && dur_r_ms=1
    speed_r=$(awk "BEGIN {printf \"%.2f\", ($size_mb * 1000) / $dur_r_ms}")

    rm -f "$test_file"
    sync

    echo -e "  • ✍️  Запись : ${C_GREEN}${speed_w} МБ/с${C_RESET} ($(( size_mb )) МБ за $(( dur_w_ms / 1000 )).$(( (dur_w_ms % 1000) / 100 )) сек)"
    echo -e "  • 📖  Чтение : ${C_GREEN}${speed_r} МБ/с${C_RESET} ($(( size_mb )) МБ за $(( dur_r_ms / 1000 )).$(( (dur_r_ms % 1000) / 100 )) сек)"
}

# ------------------------------------------------------------------------------
# 4. Интерактивный выбор USB-накопителя
# ------------------------------------------------------------------------------
select_usb_disk() {
    echo -e "\n${C_BOLD}======================================================================${C_RESET}"
    echo -e "${C_CYAN}  🔍 ПОИСК ПОДКЛЮЧЕННЫХ USB-НАКОПИТЕЛЕЙ:${C_RESET}"
    echo -e "${C_BOLD}======================================================================${C_RESET}"

    local disks=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && disks+=("$line")
    done < <(lsblk -dpno NAME,SIZE,MODEL,TRAN | grep -E "usb|DISK" | grep -v "nvme" || true)

    if [[ ${#disks[@]} -eq 0 ]]; then
        die "Подходящие USB-накопители не найдены! Вставьте флешку и повторите запуск."
    fi

    echo "Доступные USB-устройства:"
    for i in "${!disks[@]}"; do
        echo -e "  ${C_BOLD}[$((i+1))]${C_RESET} ${disks[$i]}"
    done
    echo

    local sel=""
    while true; do
        read -rp "Выберите номер флешки [1-${#disks[@]}]: " sel
        sel="$(echo "$sel" | xargs)"

        if [[ -z "$sel" ]]; then
            if [[ ${#disks[@]} -eq 1 ]]; then
                info "Выбран единственный доступный диск [1]."
                sel=1
                break
            else
                warn "Введите число от 1 до ${#disks[@]}."
                continue
            fi
        fi

        if [[ ! "$sel" =~ ^[0-9]+$ ]] || (( sel < 1 || sel > ${#disks[@]} )); then
            warn "Неверный выбор. Введите число от 1 до ${#disks[@]}."
            continue
        fi
        break
    done

    TARGET_DISK=$(echo "${disks[$((sel-1))]}" | awk '{print $1}')
    [[ -b "$TARGET_DISK" ]] || die "Устройство $TARGET_DISK не является блочным!"
    
    if [[ "$TARGET_DISK" =~ nvme0n1 ]]; then
        die "ОШИБКА БЕЗОПАСНОСТИ: Выбран системный NVMe накопитель! Операция отменена."
    fi

# ------------------------------------------------------------------------------
# Функция вывода карты текущей структуры накопителя
# ------------------------------------------------------------------------------
show_disk_map() {
    echo -e "\n${C_BOLD}======================================================================${C_RESET}"
    echo -e "${C_CYAN}  🗺️ КАРТА ТЕКУЩЕЙ СТРУКТУРЫ НАКОПИТЕЛЯ (${TARGET_DISK}):${C_RESET}"
    echo -e "${C_BOLD}======================================================================${C_RESET}"
    lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS,PARTTYPE,TYPE "$TARGET_DISK" 2>/dev/null || fdisk -l "$TARGET_DISK" 2>/dev/null
    echo -e "${C_CYAN}======================================================================${C_RESET}"
}

    info "Выбран целевой накопитель: ${C_CYAN}${TARGET_DISK}${C_RESET} ($(lsblk -dno SIZE "$TARGET_DISK"))"

    show_disk_map
    check_drive_integrity
    backup_existing_files
}

# ------------------------------------------------------------------------------
# 5. Настройка параметров: размер, ФС и согласованные метки разделов
# ------------------------------------------------------------------------------
configure_partitions() {
    TOTAL_BYTES=$(lsblk -b -dno SIZE "$TARGET_DISK")
    TOTAL_MIB=$(( TOTAL_BYTES / 1024 / 1024 ))
    TOTAL_GIB=$(( TOTAL_MIB / 1024 ))

    echo -e "\n${C_BOLD}======================================================================${C_RESET}"
    echo -e "${C_CYAN}  📐 НАСТРОЙКА РАЗДЕЛОВ НАКОПИТЕЛЯ (Всего доступно: ${TOTAL_GIB} ГБ):${C_RESET}"
    echo -e "${C_BOLD}======================================================================${C_RESET}"

    # 1. Размер раздела 1 (Ventoy / ISO)
    read -rp "Размер раздела 1 под Ventoy / ISO в ГБ [по умолчанию: 8] (или 'all' на весь диск): " raw_size
    raw_size="${raw_size:-8}"

    if [[ "$raw_size" =~ ^(all|ALL|100%|0)$ ]] || (( raw_size >= TOTAL_GIB )); then
        VENTOY_SIZE_G="$TOTAL_GIB"
        DATA_FS="none"
        info "Будет создан единый раздел на весь диск ($VENTOY_SIZE_G ГБ)."
    else
        VENTOY_SIZE_G="$raw_size"
        local remain_gib=$(( TOTAL_GIB - VENTOY_SIZE_G ))

        # 2. Выбор файловой системы для второго раздела (раздел данных)
        echo -e "\n${C_BOLD}💾 Выбор файловой системы для раздела данных (~${remain_gib} ГБ):${C_RESET}"
        echo -e "  ${C_BOLD}[1]${C_RESET} 🌐 ${C_GREEN}exFAT (по умолчанию — совместим с Android, Windows, Mac, Linux)${C_RESET}"
        echo -e "  ${C_BOLD}[2]${C_RESET} 🐧 F2FS (со сжатием — максимальная скорость и ресурс ячеек под Linux)"
        echo -e "  ${C_BOLD}[3]${C_RESET} 🪟 NTFS (для Windows)"
        read -rp "Выберите ФС [1-3, по умолчанию: 1]: " fs_choice
        fs_choice="${fs_choice:-1}"

        case "$fs_choice" in
            1|exfat|EXFAT) DATA_FS="exfat" ;;
            2|f2fs|F2FS)   DATA_FS="f2fs" ;;
            3|ntfs|NTFS)   DATA_FS="ntfs" ;;
            *) DATA_FS="exfat" ;;
        esac
    fi

    # 3. Настройка меток разделов с автоматической сквозной нумерацией
    echo -e "\n${C_BOLD}🏷️ Настройка названий (меток) разделов:${C_RESET}"
    echo -e "  • Формат раздела 1 (Ventoy) : ${C_CYAN}FD-NN${C_RESET} (например: FD-0, FD-1, FD-2 или просто номер '2')"
    echo -e "  • Формат раздела 3 (Данные) : ${C_CYAN}DATA-NN${C_RESET} или ${C_CYAN}DATA-<имя>${C_RESET} (наследует индекс раздела 1)"
    echo

    read -rp "Метка раздела 1 (Ventoy / ISO) [по умолчанию: FD-0]: " raw_p1
    raw_p1="${raw_p1:-FD-0}"
    if [[ "$raw_p1" =~ ^[0-9]+$ ]]; then
        LABEL_P1="FD-${raw_p1}"
    else
        LABEL_P1="$raw_p1"
    fi

    if [[ "$DATA_FS" != "none" ]]; then
        local def_p3="DATA"
        if [[ "$LABEL_P1" =~ ^FD-(.+)$ ]]; then
            local fd_suffix="${BASH_REMATCH[1]}"
            def_p3="DATA-${fd_suffix}"
        fi

        read -rp "Метка раздела данных (раздел 3) [по умолчанию: ${def_p3}]: " raw_p3
        raw_p3="${raw_p3:-$def_p3}"
        
        if [[ "$raw_p3" =~ ^[0-9]+$ ]]; then
            LABEL_P3="DATA-${raw_p3}"
        else
            LABEL_P3="$raw_p3"
        fi
    else
        LABEL_P3=""
    fi

    info "Конфигурация: Раздел 1 ➔ [${C_GREEN}${LABEL_P1}${C_RESET} (${VENTOY_SIZE_G} ГБ, exFAT)], Раздел 3 ➔ [${C_GREEN}${LABEL_P3:-Нет}${C_RESET} (${DATA_FS^^})]"
}

# ------------------------------------------------------------------------------
# 6. Выполнение разметки и установки
# ------------------------------------------------------------------------------
execute_partitioning() {
    echo -e "\n${C_BOLD}======================================================================${C_RESET}"
    echo -e "${C_RED}  ⚠️ ВНИМАНИЕ: ВСЕ ДАННЫЕ НА НАКОПИТЕЛЕ ${TARGET_DISK} БУДУТ ПЕРЕРАЗМЕЧЕНЫ!${C_RESET}"
    echo -e "${C_BOLD}======================================================================${C_RESET}"
    echo -e " Параметры:"
    echo -e " • Накопитель       : ${C_CYAN}${TARGET_DISK}${C_RESET} (${TOTAL_GIB} ГБ)"
    echo -e " • Раздел 1 (Ventoy): ${C_GREEN}${VENTOY_SIZE_G} ГБ (exFAT, Метка: ${LABEL_P1})${C_RESET}"
    echo -e " • Раздел данных    : ${C_GREEN}$([[ "$DATA_FS" == "none" ]] && echo "Нет" || echo "Остаток (~$(( TOTAL_GIB - VENTOY_SIZE_G )) ГБ, ФС: ${DATA_FS^^}, Метка: ${LABEL_P3})") ${C_RESET}"
    echo -e " • Авто-бэкап файлов: $([[ $DO_RESTORE -eq 1 ]] && echo -e "${C_GREEN}Включен (данные будут восстановлены)${C_RESET}" || echo "Отключен")"
    echo -e " • Тема оформления  : Xenlism-Ubuntu (1080p, Dark)"
    echo -e "----------------------------------------------------------------------"
    read -rp "Для продолжения введите ДА (или Y/Yes): " confirm
    [[ "${confirm,,}" =~ ^(да|y|yes)$ ]] || die "Операция отменена."

    ensure_ventoy_tool

    info "Отмонтирование существующих разделов ${TARGET_DISK}..."
    umount "${TARGET_DISK}"* 2>/dev/null || true

    local reserve_mib=0
    if [[ "$DATA_FS" != "none" ]]; then
        reserve_mib=$(( TOTAL_MIB - (VENTOY_SIZE_G * 1024) - 32 ))
        if (( reserve_mib < 100 )); then
            warn "Размер накопителя слишком мал для создания второго раздела, будет создан единый раздел."
            reserve_mib=0
            DATA_FS="none"
        fi
    fi

    info "Установка Ventoy (GPT, Зарезервировано: ${reserve_mib} MiB)..."
    local v_opts=("-I" "-g" "-L" "$LABEL_P1")
    if (( reserve_mib > 0 )); then
        v_opts+=("-r" "$reserve_mib")
    fi

    echo -e "y\ny\n" | bash "${VENTOY_DIR}/Ventoy2Disk.sh" "${v_opts[@]}" "$TARGET_DISK"
    sleep 2
    partprobe "$TARGET_DISK" || true

    P1="${TARGET_DISK}1"
    P2="${TARGET_DISK}2"
    P3="${TARGET_DISK}3"
    [[ -b "${TARGET_DISK}p1" ]] && P1="${TARGET_DISK}p1"
    [[ -b "${TARGET_DISK}p2" ]] && P2="${TARGET_DISK}p2"
    [[ -b "${TARGET_DISK}p3" ]] && P3="${TARGET_DISK}p3"

    # Скрытие и защита EFI раздела (VTOYEFI)
    info "Установка защитных атрибутов на раздел EFI (VTOYEFI)..."
    parted -s "$TARGET_DISK" set 2 esp on 2>/dev/null || true
    if command -v sgdisk &>/dev/null; then
        sgdisk --attributes=2:set:0 --attributes=2:set:62 --attributes=2:set:63 "$TARGET_DISK" 2>/dev/null || true
    fi

    # Создание 3-го раздела данных
    if [[ "$DATA_FS" != "none" ]]; then
        info "Создание 3-го раздела данных (${DATA_FS^^}, Метка: ${LABEL_P3})..."
        
        if command -v sgdisk &>/dev/null; then
            sgdisk -n 3:0:0 -c 3:"$LABEL_P3" -t 3:0700 "$TARGET_DISK" &>/dev/null || true
        else
            local p2_end
            p2_end=$(parted -s "$TARGET_DISK" unit s print 2>/dev/null | awk '$1=="2"{print $3}' | tr -d 's')
            local p3_start=$(( ((p2_end / 2048) + 1) * 2048 )) # 1MiB flash alignment
            parted -s "$TARGET_DISK" -- mkpart "$LABEL_P3" "${p3_start}s" 100% 2>/dev/null || \
                parted -s "$TARGET_DISK" -- mkpart primary "${p3_start}s" 100% 2>/dev/null || true
        fi

        partprobe "$TARGET_DISK" 2>/dev/null || true
        sleep 2

        P3="${TARGET_DISK}3"
        [[ -b "${TARGET_DISK}p3" ]] && P3="${TARGET_DISK}p3"
        if [[ ! -b "$P3" ]]; then
            local found_p3
            found_p3=$(lsblk -rnpo NAME "$TARGET_DISK" | grep -v "^${TARGET_DISK}$" | sed -n '3p')
            [[ -n "$found_p3" && -b "$found_p3" ]] && P3="$found_p3"
        fi

        [[ -b "$P3" ]] || die "Не удалось обнаружить созданный 3-й раздел ($P3)!"

        if [[ "$DATA_FS" == "f2fs" ]]; then
            info "Форматирование раздела $P3 в F2FS со сжатием (-O extra_attr,compression)..."
            mkfs.f2fs -f -l "$LABEL_P3" -O extra_attr,compression "$P3"
        elif [[ "$DATA_FS" == "exfat" ]]; then
            info "Форматирование раздела $P3 в exFAT (Метка: ${LABEL_P3})..."
            mkfs.exfat -n "$LABEL_P3" "$P3"
        elif [[ "$DATA_FS" == "ntfs" ]]; then
            info "Форматирование раздела $P3 в NTFS (Метка: ${LABEL_P3})..."
            mkfs.ntfs -f -L "$LABEL_P3" "$P3"
        fi
    fi

    # ------------------------------------------------------------------------------
    # Установка темы GRUB Xenlism по версии Linux-дистрибутива
    # ------------------------------------------------------------------------------
    local os_id="ubuntu"
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        os_id="${ID:-ubuntu}"
    fi

    local theme_archive="xenlism-grub-1080p-ubuntu.tar.xz"
    local theme_dir="Xenlism-Ubuntu"
    local theme_title="Xenlism Ubuntu (Full HD 1080p)"

    case "${os_id,,}" in
        arch|manjaro|endeavouros)
            theme_archive="xenlism-grub-arch-1080p.tar.xz"
            theme_dir="Xenlism-Arch"
            theme_title="Xenlism Arch Linux (Full HD 1080p)"
            ;;
        debian)
            theme_archive="xenlism-grub-1080p-Debian.tar.xz"
            theme_dir="Xenlism-Debian"
            theme_title="Xenlism Debian (Full HD 1080p)"
            ;;
        fedora|rhel|centos|rocky|almalinux)
            theme_archive="xenlism-grub-1080p-Fedora.tar.xz"
            theme_dir="Xenlism-Fedora"
            theme_title="Xenlism Fedora (Full HD 1080p)"
            ;;
        linuxmint|mint)
            theme_archive="xenlism-grub-1080p-mint.tar.xz"
            theme_dir="Xenlism-Mint"
            theme_title="Xenlism Linux Mint (Full HD 1080p)"
            ;;
        kali)
            theme_archive="xenlism-grub-1080p-kali.tar.xz"
            theme_dir="Xenlism-Kali"
            theme_title="Xenlism Kali Linux (Full HD 1080p)"
            ;;
        pop|popos)
            theme_archive="xenlism-grub-popos-1080p.tar.xz"
            theme_dir="Xenlism-PopOS"
            theme_title="Xenlism Pop!_OS (Full HD 1080p)"
            ;;
        opensuse*|suse)
            theme_archive="xenlism-grub-opensuse-1080p.tar.xz"
            theme_dir="Xenlism-OpenSuse"
            theme_title="Xenlism openSUSE (Full HD 1080p)"
            ;;
        gentoo)
            theme_archive="xenlism-grub-gentoo-1080p.tar.xz"
            theme_dir="Xenlism-Gentoo"
            theme_title="Xenlism Gentoo (Full HD 1080p)"
            ;;
        nixos)
            theme_archive="xenlism-grub-1080p-nixos.tar.xz"
            theme_dir="Xenlism-Nixos"
            theme_title="Xenlism NixOS (Full HD 1080p)"
            ;;
        *)
            theme_archive="xenlism-grub-1080p-ubuntu.tar.xz"
            theme_dir="Xenlism-Ubuntu"
            theme_title="Xenlism Ubuntu (Full HD 1080p)"
            ;;
    esac

    info "Установка темы GRUB: ${theme_title}..."
    local mnt_v="/tmp/mnt_ventoy_$$"
    mkdir -p "$mnt_v"
    mount "$P1" "$mnt_v"
    mkdir -p "$mnt_v/ventoy/theme"

    if [[ -d "/boot/grub/themes/$theme_dir" ]]; then
        cp -r "/boot/grub/themes/$theme_dir" "$mnt_v/ventoy/theme/"
    else
        local theme_url="https://raw.githubusercontent.com/xenlism/Grub-themes/main/$theme_archive"
        local tmp_tar="/tmp/$theme_archive"
        local tmp_extract="/tmp/xenlism_extract_$$"
        mkdir -p "$tmp_extract"
        
        info "Скачивание темы из GitHub (xenlism/Grub-themes)..."
        if curl -fsSL "$theme_url" -o "$tmp_tar" 2>/dev/null || wget -q "$theme_url" -O "$tmp_tar" 2>/dev/null; then
            tar -xJf "$tmp_tar" -C "$tmp_extract" 2>/dev/null || true
            local found_dir
            found_dir=$(find "$tmp_extract" -type d -name "$theme_dir" 2>/dev/null | head -n 1)
            if [[ -n "$found_dir" && -d "$found_dir" ]]; then
                cp -r "$found_dir" "$mnt_v/ventoy/theme/"
            fi
        fi
        rm -rf "$tmp_tar" "$tmp_extract"
    fi

    cat << VJSON_EOF | tee "$mnt_v/ventoy/ventoy.json" >/dev/null
{
    "theme": {
        "file": "/ventoy/theme/$theme_dir/theme.txt",
        "gfxmode": "1920x1080",
        "display_mode": "GUI",
        "ventoy_color": "#ffffff",
        "fonts": [
            "/ventoy/theme/$theme_dir/dejavu_sans_24.pf2",
            "/ventoy/theme/$theme_dir/dejavu_sans_48.pf2",
            "/ventoy/theme/$theme_dir/terminus-18.pf2"
        ]
    }
}
VJSON_EOF
    umount "$mnt_v"
    rm -rf "$mnt_v"

    # Восстановление файлов пользователя
    restore_files

    # Копирование пакета развертывания на раздел данных (как в ps1-версии)
    copy_deploy_package

    echo
    success "======================================================================"
    success " 🎉 ФЛЕШКА УСПЕШНО РАЗМЕЧЕНА!"
    success "======================================================================"
    lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS "$TARGET_DISK"

    # Завершающее контрольное тестирование скорости
    echo
    read -rp "Провести контрольный замер скорости на созданных разделах? [Y/n]: " do_post_test
    do_post_test="${do_post_test:-Y}"
    if [[ "${do_post_test,,}" =~ ^(д|да|y|yes)$ ]]; then
        local mnt_p1="/tmp/mnt_post_p1_$$"
        mkdir -p "$mnt_p1"
        mount "$P1" "$mnt_p1"
        run_speed_test "$mnt_p1" "Раздел 1: Ventoy / ISO ($LABEL_P1)"
        umount "$mnt_p1"
        rm -rf "$mnt_p1"

        if [[ "$DATA_FS" != "none" && -b "$P3" ]]; then
            local mnt_p3="/tmp/mnt_post_p3_$$"
            mkdir -p "$mnt_p3"
            mount "$P3" "$mnt_p3"
            run_speed_test "$mnt_p3" "Раздел 3: Данные ($LABEL_P3, ${DATA_FS^^})"
            umount "$mnt_p3"
            rm -rf "$mnt_p3"
        fi
        echo
        success "Все замеры скорости успешно завершены!"
    fi
}

# Запуск
select_usb_disk
configure_partitions
execute_partitioning
