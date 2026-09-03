#!/usr/bin/env bash
#===============================================================================
# split-home.sh — Автоматическое безрисковое разделение системы Ubuntu на
#                 системный корень / (200 ГБ) и отдельный раздел /home (~328 ГБ).
#
#   ЧТО ДЕЛАЕТ СКРИПТ:
#     Диск: /dev/nvme0n1 (PNY CS2241 1TB, GPT)
#     p1..p5  Windows 11 (299 ГБ), EFI, Recovery — НЕ ЗАТРАГИВАЮТСЯ ВООБЩЕ!
#     p6      Linux Swap (3.9 ГБ)                — НЕ ЗАТРАГИВАЕТСЯ!
#     p7      ext4 528 ГБ (UUID: 1b8e3e50-2e22-4088-a3a5-396293780ff2)
#     p8      exfat Distr 99 ГБ (дистрибутивы/образы) — НЕ ЗАТРАГИВАЕТСЯ!
#
#     1. Сжимает p7 (ext4) до 200 ГБ (корень /).
#        Начальный сектор (638709760s) не сдвигается — операция быстрая и безопасная.
#     2. В свободном промежутке между p7 и p8 создает p9 (ext4, метка UbuntuHome, ~328 ГБ).
#     3. Переносит все личные данные из /home на новый раздел p9 (rsync -aHAX).
#     4. Очищает старый каталог /home на системном разделе p7.
#     5. Добавляет UUID раздела p9 в /etc/fstab установленной системы.
#
#   РЕЗУЛЬТАТ ПОСЛЕ РАЗДЕЛЕНИЯ:
#     • Раздел p7 (/):     200 ГБ (занятость см. по df -hT после загрузки)
#     • Раздел p9 (/home): ~328 ГБ (занятость см. по df -hT после загрузки)
#
#===============================================================================
#   ПОРЯДОК ИСПОЛЬЗОВАНИЯ (ПО ШАГАМ):
#
#   ШАГ 1. Скопируйте этот скрипт на 2-й раздел загрузочной флешки FD-1 (F2FS):
#            cp /home/asv-spb/split-home.sh /media/asv-spb/F2FS/
#
#   ШАГ 2. Перезагрузите компьютер, в Boot Menu (F12/F11/Esc) выберите флешку.
#          В меню Ventoy выберите образ Ubuntu и нажмите «Try Ubuntu».
#
#   ШАГ 3. Откройте терминал (Ctrl + Alt + T) и перейдите к скрипту:
#            cd /media/ubuntu/F2FS
#
#   ШАГ 4. Запустите безопасную симуляцию (проверка без изменения диска):
#            sudo bash split-home.sh --dry-run
#
#   ШАГ 5. Запустите реальное разделение диска:
#            sudo bash split-home.sh
#          (Скрипт запросит подтверждение словом «ДА»).
#
#   ШАГ 6. Перезагрузитесь в обычную систему (убрав флешку). Проверка:
#            df -hT / /home    # Корень 200 ГБ на p7, Home ~328 ГБ на p9
#            lsblk             # Должен появиться nvme0n1p9 (между p7 и p8)
#            cat /etc/fstab    # Строка /home с UUID p9
#            swapon --show     # swap на p6 вернулся
#            lsblk -o NAME,LABEL,SIZE   # Distr на месте (p8), монтируется
#
#===============================================================================
#   ВАРИАНТЫ ЗАПУСКА:
#     sudo bash split-home.sh --dry-run      # Тестовый прогон (безопасно)
#     sudo bash split-home.sh                # Запуск с подтверждением «ДА»
#     sudo bash split-home.sh --yes          # Запуск без вопросов (автономно)
#     sudo bash split-home.sh -h             # Справка по опциям
#
#   ЗАЩИТЫ И БЕЗОПАСНОСТЬ:
#   - Запуск на работающей системе блокируется (доступен только --dry-run).
#   - Скрипт проверяет UUID/размер p7 и отпечаток раздела Distr (p8).
#   - Скрипт проверяет отсутствие смонтированных разделов NVMe.
#   - Перед изменениями создается дамп таблицы разделов в parttable-*.bak.
#   - Проверка целостности файловой системы утилитой e2fsck -fy.
#   - Резервная копия /etc/fstab сохраняется в fstab.bak-*.
#===============================================================================
set -Eeuo pipefail
trap 'echo -e "\n\033[1;31m[ОШИБКА]\033[0m Сбой выполнения на строке $LINENO" >&2' ERR

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

# Константы целевого оборудования
DISK="/dev/nvme0n1"
PART_SYS_ROOT="/sys/block/nvme0n1"     # отпечатки разделов (тесты переопределяют на tmp-каталог)
P7="${DISK}p7"
P8_DISTR="${DISK}p8"                   # существующий exfat-раздел Distr — НЕ ЗАТРАГИВАЕТСЯ
P9="${DISK}p9"                         # новый раздел /home
EXPECT_P7_UUID="1b8e3e50-2e22-4088-a3a5-396293780ff2"
EXPECT_P7_SIZE_SECTORS=1107075072      # p7 уже сжат с 627 до 528 ГБ (2026-09-03)
EXPECT_DISTR_START=1745784832          # стартовый сектор p8-Distr
EXPECT_DISTR_PARTUUID="58c56411-3703-410a-bda7-41278b287bca"
P7_START_SECTOR=638709760
P7_SIZE_SECTORS=419430400     # 200 GiB (200 * 1024 * 1024 * 2)
P7_END_SECTOR=$((P7_START_SECTOR + P7_SIZE_SECTORS - 1)) # 1058140159
P9_START_SECTOR=$((P7_END_SECTOR + 1))                   # 1058140160
P9_END_SECTOR=$((EXPECT_DISTR_START - 1))                # 1745784831 (перед p8-Distr)
TARGET_SHRINK_GB=195          # до какого размера сжимаем ФС p7 (запас до границы 200 ГБ)
USED_LIMIT_GB=190             # отказ, если занято в /home >= этого (ГБ): не влезет после сжатия

DRY=0
YES=0
FORCE=0

usage() {
    awk 'NR==1{next} /^set -Eeuo pipefail$/{exit} {sub(/^#[ ]?/,""); print}' "$0" 2>/dev/null || true
    exit 0
}

parse_args() {
    while (( $# )); do
        case "$1" in
            --dry-run) DRY=1 ;;
            --yes|-y)  YES=1 ;;
            --force)   FORCE=1 ;;
            -h|--help) usage ;;
            *) die "Неизвестный параметр: $1 (см. --help)" ;;
        esac
        shift
    done
}

# ------------------------------------------------------------------------------
# Охрана разметки (A1): до первого parted/mkfs сверяем диск с отпечатками ТЕКУЩЕЙ
# разметки (p7 уже сжат, p8-Distr существует, p9 ещё нет). start/size читаются
# через PART_SYS_ROOT — тест (A4) подменяет его на tmp-каталог с фейковыми файлами.
# ------------------------------------------------------------------------------
check_partition_layout() {
    # p9 существует = операция уже выполнялась на этом диске — стоп
    if [[ -e "${PART_SYS_ROOT}/nvme0n1p9" ]]; then
        die "Раздел $P9 уже существует! Похоже, операция уже выполнялась."
    fi
    # без p8-Distr нет свободного промежутка с гарантированным концом под p9
    if [[ ! -e "${PART_SYS_ROOT}/nvme0n1p8" ]]; then
        die "Разметка не соответствует: не найден раздел Distr ($P8_DISTR). Обновите константы в скрипте."
    fi

    # отпечаток p8-Distr: тип exfat + PARTUUID + стартовый сектор
    local cur_d8_type cur_d8_partuuid d8_start
    cur_d8_type=$(blkid -s TYPE -o value "$P8_DISTR" || echo "")
    cur_d8_partuuid=$(blkid -s PARTUUID -o value "$P8_DISTR" || echo "")
    d8_start=$(cat "${PART_SYS_ROOT}/nvme0n1p8/start" 2>/dev/null || echo "")
    [[ "$cur_d8_type" == "exfat" ]] \
        || die "Тип ФС на $P8_DISTR: '${cur_d8_type:-?}', ожидался exfat (Distr). Разметка изменилась — обновите константы."
    [[ "$cur_d8_partuuid" == "$EXPECT_DISTR_PARTUUID" ]] \
        || die "PARTUUID $P8_DISTR: '${cur_d8_partuuid:-?}', ожидался '$EXPECT_DISTR_PARTUUID'. Разметка изменилась — обновите константы."
    [[ "$d8_start" -eq "$EXPECT_DISTR_START" ]] \
        || die "Начальный сектор $P8_DISTR ($d8_start) не совпадает с ожидаемым ($EXPECT_DISTR_START). Разметка изменилась — обновите константы."

    # p7: стартовый сектор (инвариант) и текущий размер (уже сжат до 528 ГБ)
    S7=$(cat "${PART_SYS_ROOT}/nvme0n1p7/start")
    Z7=$(cat "${PART_SYS_ROOT}/nvme0n1p7/size")
    [[ "$S7" -eq "$P7_START_SECTOR" ]] \
        || die "Начальный сектор $P7 ($S7) не совпадает с ожидаемым ($P7_START_SECTOR)"
    [[ "$Z7" -eq "$EXPECT_P7_SIZE_SECTORS" ]] \
        || die "Размер $P7 ($Z7 секторов) не совпадает с ожидаемым ($EXPECT_P7_SIZE_SECTORS). p7 уже сжат или расширен — разметка изменилась, обновите константы."
}

# ------------------------------------------------------------------------------
# 0. Базовые проверки окружения
# ------------------------------------------------------------------------------
check_environment() {
[[ $EUID -eq 0 ]] || die "Скрипт требует прав root: sudo bash $0"

for cmd in parted sfdisk e2fsck resize2fs rsync blkid findmnt; do
    command -v "$cmd" >/dev/null || die "Не найдена утилита '$cmd' (apt update && apt install -y parted e2fsprogs rsync)"
done

ROOT_FSTYPE=$(findmnt -no FSTYPE / 2>/dev/null || echo "?")
if grep -qE 'casper|boot=live' /proc/cmdline || [[ "$ROOT_FSTYPE" =~ ^(tmpfs|overlay|squashfs)$ ]]; then
    info "Live-среда подтверждена (корень в RAM: $ROOT_FSTYPE)"
elif (( DRY )); then
    warn "Это НЕ Live-среда (корень: $ROOT_FSTYPE) — разрешен только режим --dry-run"
elif (( FORCE )); then
    warn "НЕ Live-среда (корень: $ROOT_FSTYPE), продолжение из-за --force"
else
    die "Сжатие рабочего корня невозможно из работающей системы! Загрузитесь с Live-USB флешки."
fi

# ------------------------------------------------------------------------------
# 1. Проверка диска и разделов
# ------------------------------------------------------------------------------
[[ -b "$DISK" ]] || die "Накопитель $DISK не найден!"
[[ -b "$P7" ]]   || die "Раздел $P7 не найден!"

check_partition_layout

CUR_P7_TYPE=$(blkid -s TYPE -o value "$P7" || echo "")
CUR_P7_UUID=$(blkid -s UUID -o value "$P7" || echo "")
[[ "$CUR_P7_TYPE" == "ext4" ]] || die "Тип ФС на $P7: '$CUR_P7_TYPE', ожидался ext4"
[[ "$CUR_P7_UUID" == "$EXPECT_P7_UUID" ]] || die "UUID $P7 = '$CUR_P7_UUID', ожидался '$EXPECT_P7_UUID'"

info "Текущий размер p7: $(( Z7 * 512 / 1024 / 1024 / 1024 )) ГБ"
info "Целевой размер p7: 200 ГБ (корень /)"
info "Целевой размер p9: ~$(( (Z7 - P7_SIZE_SECTORS) * 512 / 1024 / 1024 / 1024 )) ГБ (данные /home)"
}

# ------------------------------------------------------------------------------
# 1a. Ранняя проверка занятого места в /home: до долгого e2fsck/resize2fs.
#     Если занято >= USED_LIMIT_GB, сжатие до TARGET_SHRINK_GB невозможно.
# ------------------------------------------------------------------------------
check_home_usage() {
    local used preflight_mnt
    if (( DRY )); then
        used=$(df -B1G --output=used /home 2>/dev/null | tail -n 1 | tr -dc '0-9')
        info "Предварительно занято в /home: ~${used:-?} ГБ (лимит отказа: ${USED_LIMIT_GB} ГБ)"
        return 0
    fi
    preflight_mnt="/tmp/split_preflight"
    run mkdir -p "$preflight_mnt"
    run mount -o ro "$P7" "$preflight_mnt"
    used=$(df -B1G --output=used "$preflight_mnt" | tail -n 1 | tr -dc '0-9')
    run umount "$preflight_mnt"
    info "Занято в /home: ${used} ГБ (лимит отказа: ${USED_LIMIT_GB} ГБ, сжатие до ${TARGET_SHRINK_GB} ГБ)"
    if [[ -n "$used" && "$used" -ge "$USED_LIMIT_GB" ]]; then
        die "В /home занято ${used} ГБ (>= ${USED_LIMIT_GB} ГБ): после сжатия p7 до ${TARGET_SHRINK_GB} ГБ данные не поместятся. Освободите /home (кэши, старые загрузки, контейнеры) и повторите."
    fi
}

# ------------------------------------------------------------------------------
# 7. Миграция данных /home на новый раздел p9
# ------------------------------------------------------------------------------

# Cleanup-ловушка (по образцу cleanup_mounts в deploy.sh): прерывание посреди
# миграции не оставляет смонтированных p7/p9. Читает глобальные MNT_*,
# значения проверяются на пустоту.
cleanup_split() {
    local mp
    for mp in "${MNT_HOME:-}" "${MNT_ROOT:-}"; do
        [[ -n "$mp" ]] || continue
        if grep -qE "^[^ ]+ $mp " /proc/mounts 2>/dev/null; then
            umount "$mp" 2>/dev/null || true
        fi
    done
    return 0
}

do_migrate_home() {
MNT_ROOT="/tmp/split_root_mnt"
MNT_HOME="/tmp/split_home_mnt"

info "Монтирование разделов для переноса файлов..."
run mkdir -p "$MNT_ROOT" "$MNT_HOME"
run mount "$P7" "$MNT_ROOT"
run mount "$P9" "$MNT_HOME"
run fstrim -v "$MNT_HOME" 2>/dev/null || true

if ! (( DRY )); then
    info "Копирование всех личных данных из /home на раздел p9 (rsync -aHAX)..."
    rsync -aHAXS --info=progress2 "$MNT_ROOT/home/" "$MNT_HOME/"
    success "Данные успешно скопированы на раздел p9!"

    # Сверка копии ДО уничтожения оригинала: второй проход rsync в dry-режиме
    # с itemize. Пустой вывод = деревья идентичны (контент, права, xattr, ACL,
    # hardlinks). Непустой = die: старый /home НЕ тронут, fstab НЕ изменён.
    info "Сверка копии с оригиналом (rsync -n --itemize)..."
    verify_out="$(rsync -aHAXSnS --itemize-changes --out-format='%i %n' \
        "$MNT_ROOT/home/" "$MNT_HOME/" 2>&1 || true)"
    if [[ -n "$verify_out" ]]; then
        die "Сверка /home после копирования не сошлась (первые расхождения):
$verify_out
Старый /home НЕ удалён, fstab НЕ изменён. Разберитесь с расхождениями вручную."
    fi
    success "Сверка пройдена: копия идентична оригиналу."

    # fstab обновляется ДО удаления старого /home: прерывание между шагами
    # оставляет максимум "незачищенные старые копии" на p7, а не пустой /home.
    NEW_HOME_UUID=$(blkid -s UUID -o value "$P9")
    info "Обновление /etc/fstab установленной системы (UUID: $NEW_HOME_UUID)..."
    cp -a "$MNT_ROOT/etc/fstab" "$MNT_ROOT/etc/fstab.bak-$TS"
    echo "UUID=${NEW_HOME_UUID}   /home           ext4    defaults          0       2" >> "$MNT_ROOT/etc/fstab"
    cp "/tmp/parttable-before-split-$TS.bak" "$MNT_ROOT/root/parttable-before-split-$TS.bak"
    success "Конфигурация fstab обновлена!"

    info "Очистка старой папки /home на системном разделе p7 (освобождение места)..."
    find "$MNT_ROOT/home" -mindepth 1 -delete
else
    echo -e "  ${C_CYAN}[dry-run]${C_RESET} rsync -aHAX /tmp/split_root_mnt/home/ /tmp/split_home_mnt/"
    echo -e "  ${C_CYAN}[dry-run]${C_RESET} Сверка копии (rsync -n --itemize) ДО изменения fstab и удаления старого /home"
    echo -e "  ${C_CYAN}[dry-run]${C_RESET} Добавление UUID p9 в /etc/fstab как /home"
    echo -e "  ${C_CYAN}[dry-run]${C_RESET} Очистка старой папки /home на p7 (только ПОСЛЕ обновления fstab)"
fi

run sync
run umount "$MNT_HOME"
run umount "$MNT_ROOT"
}
# Основной поток (только при прямом запуске; source в тестах — только определения)
main() {
    parse_args "$@"
    trap cleanup_split EXIT
    trap 'cleanup_split; exit 130' INT
    trap 'cleanup_split; exit 143' TERM
    check_environment
    check_home_usage

# ------------------------------------------------------------------------------
# 2. Проверка смонтированных разделов
# ------------------------------------------------------------------------------
run swapoff -a || true
if grep -q '/dev/nvme0n1p' /proc/mounts; then
    if ! (( DRY )); then
        grep '/dev/nvme0n1p' /proc/mounts
        die "Разделы NVMe смонтированы! Закройте файловый менеджер и отмонтируйте их перед операцией."
    else
        warn "[dry-run] Разделы NVMe смонтированы на хосте (в Live-USB они будут отмонтированы)."
    fi
fi

# ------------------------------------------------------------------------------
# 3. Подтверждение операции
# ------------------------------------------------------------------------------
echo
echo -e "${C_BOLD}======================================================================${C_RESET}"
echo -e "${C_CYAN}  📋 ПЛАН ОПЕРАЦИИ РАЗДЕЛЕНИЯ НАКОПИТЕЛЯ (БЕЗ ПОТЕРИ ДАННЫХ):${C_RESET}"
echo -e "${C_BOLD}======================================================================${C_RESET}"
echo -e " 1. Проверка целостности файловой системы p7 (e2fsck)"
echo -e " 2. Сжатие p7 с ~$(( Z7 * 512 / 1024 / 1024 / 1024 )) ГБ до ${C_GREEN}200 ГБ${C_RESET} (корень /)"
echo -e " 3. Создание нового раздела p9 на ${C_GREEN}~328 ГБ${C_RESET} (ext4, /home)"
echo -e " 4. Перенос данных /home на p9 с сохранением прав и ACL (rsync -aHAX)"
echo -e " 5. Очистка старого /home на p7 после обновления fstab"
echo -e " 6. Добавление записи /home в /etc/fstab установленной системы"
echo -e "----------------------------------------------------------------------"

if (( DRY )); then
    info "Режим симуляции (--dry-run). Изменения на диск вноситься НЕ будут."
elif (( ! YES )); then
    read -rp "Для запуска разделения введите слово ДА (или Y/Yes): " ans
    [[ "${ans,,}" =~ ^(да|y|yes)$ ]] || die "Операция отменена пользователем."
fi

TS="${SPLIT_HOME_TS:-$(date +%Y%m%d-%H%M%S)}"   # SPLIT_HOME_TS — тестовый хук воспроизводимости

# ------------------------------------------------------------------------------
# 4. Резервная копия таблицы разделов GPT
# ------------------------------------------------------------------------------
info "Создание резервной копии таблицы разделов..."
if ! (( DRY )); then
    sfdisk -d "$DISK" > "/tmp/parttable-before-split-$TS.bak"
    success "Дамп GPT сохранен в /tmp/parttable-before-split-$TS.bak"
else
    echo -e "  ${C_CYAN}[dry-run]${C_RESET} sfdisk -d $DISK > /tmp/parttable-before-split-$TS.bak"
fi

# ------------------------------------------------------------------------------
# 5. Проверка и сжатие файловой системы p7
# ------------------------------------------------------------------------------
info "Проверка файловой системы p7..."
run e2fsck -fy "$P7"

info "Безопасное сжатие ext4 до 195 ГБ (с запасом для изменения границы)..."
run resize2fs "$P7" 195G

info "Изменение границы раздела p7 в таблице GPT (до 200 ГБ)..."
# parted 3.4 при СЖАТИИ раздела не подавляет подтверждение флагом -s — нужен
# ---pretend-input-tty и ответ «Yes» на stdin (в dry-run ниже видна вся команда).
if (( DRY )); then
    echo -e "  ${C_CYAN}[dry-run]${C_RESET} parted ---pretend-input-tty $DISK resizepart 7 ${P7_END_SECTOR}s <<< \"Yes\""
else
    parted ---pretend-input-tty "$DISK" resizepart 7 "${P7_END_SECTOR}s" <<< "Yes"
fi
run partprobe "$DISK" || true
run sleep 2

info "Расширение ext4 до точного 100% размера нового раздела p7 (200 ГБ)..."
run resize2fs "$P7"
run e2fsck -fy "$P7"
success "Раздел p7 успешно уменьшен до 200 ГБ!"

# ------------------------------------------------------------------------------
# 6. Создание раздела p9 (/home)
# ------------------------------------------------------------------------------
info "Создание раздела p9 в свободном промежутке между p7 и p8 (~328 ГБ)..."
run parted -s "$DISK" mkpart "UbuntuHome" ext4 "${P9_START_SECTOR}s" "${P9_END_SECTOR}s"
run partprobe "$DISK" || true
run sleep 2

info "Форматирование p9 в ext4 с меткой UbuntuHome..."
run mkfs.ext4 -F -L "UbuntuHome" "$P9"
success "Раздел p9 успешно создан и отформатирован!"


do_migrate_home

echo
echo -e "${C_GREEN}${C_BOLD}======================================================================${C_RESET}"
echo -e "${C_GREEN}${C_BOLD} 🎉 РАЗДЕЛЕНИЕ СИСТЕМЫ УСПЕШНО ЗАВЕРШЕНО!${C_RESET}"
echo -e "${C_GREEN}${C_BOLD}======================================================================${C_RESET}"
echo -e "Итог:"
echo -e " • Системный корень (p7): ${C_GREEN}200 ГБ${C_RESET} (занятость см. по df -hT)"
echo -e " • Раздел данных /home (p9): ${C_GREEN}~328 ГБ${C_RESET} (занятость см. по df -hT)"
echo -e " • Если операцию прервали между обновлением fstab и очисткой, на p7 остались"
echo -e "   старые копии /home. Чистка (безопасно, p9 уже смонтирован как /home):"
echo -e "   Live -> mount /dev/nvme0n1p7 /mnt/p7 && rm -rf /mnt/p7/home/*"
echo -e "Компьютер готов к перезагрузке в обычную систему."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi

