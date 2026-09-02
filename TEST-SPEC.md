# 🧪 ТЗ: система тестов проекта deploy-baremetal

Версия: 1.0 от 2026-09-02. Основано на состоянии репозитория после коммитов
`T0.1–T4.3` и `fix/check` (парсер-фикс `${Label}:`).

---

## 1. Цель и границы

**Цель:** автоматизированная система тестов, ловящая регрессии во всех скриптах
проекта без риска для реальных дисков, и закрывающая классы ошибок, уже
встречавшиеся в проекте (кодировка ps1, `$var:` в строках, потеря данных при
молчаливом сбое бэкапа, дублирование файла).

**В automated-тестах НЕ тестируется (границы):**
- запись на реальные USB/NVMe;
- запуск Windows-части ps1 (runtime) — только статика и парсинг;
- реальная установка Windows по autounattend (ручной чек-лист, §11);
- работа Ventoy на железе (ручной чек-лист).

## 2. Стратегия: уровни тестовой пирамиды

| Уровень | Что | Инструмент | Root | Скорость |
|---|---|---|---|---|
| L0 | Статика: кодировка/BOM/CRLF/`$var:`/shellcheck/bash -n | bash + python3 + shellcheck | нет | сек |
| L1 | Парсинг ps1 настоящим парсером PowerShell | pwsh 7 (Linux) `Parser::ParseFile` | нет | сек |
| L2 | Юнит-тесты функций bash (source + вызов) | bats-core | нет | сек |
| L3 | Интеграция на заглушках (PATH-stub): логика без исполнения команд | bats-core + stubs | нет | сек |
| L4 | Интеграция на loop-устройствах: реальные parted/mkfs на файле-образе | bats-core + losetup | да | мин |
| L5 | Dry-run E2E существующих режимов | bats-core | да | сек |

Правило: **ни один тест не выполняет parted/mkfs/dd/wget на устройстве,
отличном от loop-заглушки или tmp-каталога.** Каждый тест L3/L4 перед запуском
assert-ом проверяет, что целевое устройство — `/dev/loop*` или несуществующее.

## 3. Инфраструктура

На машине-разработчика сейчас есть: `shellcheck`, `losetup`, `truncate`,
`/dev/loop-control`, `fakeroot`. Отсутствуют: `bats`, `pwsh`, `xmllint`.

Создать `tests/setup.sh` (idempotent, без root для bats, с sudo-подсказкой для pwsh):

1. **bats-core** — клон git-репозиториев `bats-core`, `bats-support`,
   `bats-assert` в `tests/.deps/` (версии зафиксировать по коммиту; в `.gitignore`).
2. **PowerShell 7** — установка через пакеты Microsoft (инструкция в setup-скрипте;
   используется ТОЛЬКО для парсинга ps1 — это основной способ ловить
   `$Label:`-подобные ошибки без Windows).
3. **xmllint** — `libxml2-utils` (валидация сгенерированного autounattend.xml).
4. Проверка окружения: `sudo -n true` (для L4/L5 — пропуск с предупр., не падение).

## 4. Рефакторинг тестируемости (этап T0, БЕЗ изменения поведения)

Скрипты исполняют логику на верхнем уровне — `source` в bats невозможен.
Требуется обёртка (шаблон):

```bash
main() { ... весь существующий верхнеуровневый код ... }
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
```

- **T0.1** `deploy.sh`: RAM-копия, разбор аргументов и `main` — внутрь guard.
  Заодно `detect_disk`/`find_isos` остаются вызываемыми отдельно.
- **T0.2** `make-boot-usb.sh`: `select_usb_disk; configure_partitions;
  execute_partitioning` — внутрь `main` с guard.
- **T0.3** `deploy.sh`: выделить чистые функции (если ещё не так):
  `part_dev <disk> <n>` (суффикс `p` для nvme), уже есть `iana_to_windows_tz`.
- `split-home.sh` НЕ рефакторить: сценарий железоспецифичен, тестируется
  подпроцессом (L3/L5) и вручную.

**Регрессия T0:** после рефакторинга dry-run прогоны (см. L5) и `bash -n`
обязаны давать идентичный вывод до/после (тест сравнивает `--dry-run` вывод
с эталоном `tests/fixtures/dry-run-prep.golden`).

## 5. Структура каталога

```
tests/
  setup.sh              # установка bats/pwsh/xmllint (§3)
  run-all.sh            # раннер уровней: fast (L0-L3) / full (L0-L5)
  bats/
    check-deploy.bats   # L2/L3 по deploy.sh
    check-usb-sh.bats   # L2/L3 по make-boot-usb.sh
    check-splithome.bats# L3 CLI-валидация
    loop-integration.bats# L4
    dryrun-e2e.bats     # L5
    ps-parse.bats       # L1 (вызов pwsh)
    meta.bats           # метатесты (§7.7)
  stubs/
    make-stub.sh        # генератор: make-stub.sh <cmd> <exit> [stdout...]
    bin/                # каталог для PATH в тестах (gitignored, создаётся тестом)
  fixtures/
    dry-run-prep.golden # эталон вывода deploy.sh --full --dry-run
    passwords.txt       # спец-символьные пароли для U-D6
    fake-ubuntu.iso     # пустышка (dd 1M) для find_isos
  loop/                 # сценарии L4
  windows/              # Pester (опция) + инструкция
Makefile                # цели: test-fast, test, test-loop, test-ps
```

## 6. Контракты заглушек (L3)

`make-stub.sh <имя> <exit-код> [--stdout "текст"]` создаёт исполняемый файл в
`tests/stubs/bin/`; каждая заглушка пишет вызов (argv + cwd) в
`$STUB_LOG` (env, по одному файлу на команду). Тест кладёт `tests/stubs/bin`
в начало PATH.

| Команда | Поведение заглушки по умолчанию |
|---|---|
| `lsblk` | эмуляция «флешки 32G»: `-dpno NAME,SIZE,MODEL,TRAN` → sdb/32G/FAKE/usb; `-b -dno SIZE` → 34359738368; партиции p1/p3 |
| `udevadm` | `ID_BUS=usb` (для detect_disk: вариант «не usb» — переключаемый) |
| `df` | управляемый объём свободного места (для check_backup_space) |
| `parted`, `mkfs.*`, `partprobe`, `e2fsck`, `resize2fs`, `mkswap` | exit 0 + запись в STUB_LOG |
| `cp`, `rsync` | переключаемый сбой (exit 1) — для тестов бэкапа |
| `mount`, `umount`, `swapon/off` | exit 0 (L3 не монтирует) |
| `wget`, `curl` | отдают локальные fixture-файлы (тема/Ventoy не качаются) |
| `dd` | ЗАПРЕЩЁНАЯ заглушка: всегда exit 1 + предупреждение (dd в CI не исполняется никогда) |

## 7. Матрица тестов

### 7.1 deploy.sh (L2/L3)

| ID | Уровень | Проверка |
|---|---|---|
| U-D1 | L2 | `iana_to_windows_tz`: Москва/Калининград/неизвестная зона → верные имена |
| U-D2 | L2 | `part_dev`: nvme0n1→`p6`, sda→`6` |
| U-D3 | L3 | CLI: `--disk` без аргумента → die; неизвестный флаг → die |
| U-D4 | L3 | `detect_disk AUTO`: udevadm-стаб «usb» на nvme → выбор sda |
| U-D5 | L3 | `find_isos` в tmp-каталоге с fixtures → WIN_ISO/UBUNTU_ISO найдены |
| U-D6 | L3 | `generate_autounattend`: пароли `p&a<b>"c/d`, `//`, пустой → корректное экранирование (grep по выходу); `xmllint --noout` валиден; нет неразрешённых `__[A-Z_]+__` |
| U-D7 | L3 | отказ без ISO Ubuntu: exit ≠ 0, сообщение про debootstrap |
| I-D1 | L3 | PREP_DISK на стабах: последовательность parted (7 mkpart, esp/msftres/msftdata флаги, MiB-арифметика размеров из conf) и mkfs.* (правильные устройства/метки) |
| I-D2 | L3 | `GRUB_DISABLE_OS_PROBER=false` дописан перед update-grub (реальный sed на tmp-файле) |

### 7.2 make-boot-usb.sh (L2/L3)

| ID | Уровень | Проверка |
|---|---|---|
| U-M1 | L2 | `verify_restored_tree`: размер не совпал → rc 1; полное совпадение → rc 0 |
| I-M1 | L3 | `choose_backup_dir`: df-стаб «tmpfs» → путь /var/tmp (или введённый) |
| I-M2 | L3 | `check_backup_space`: мало места → die ДО копирования |
| I-M3 | L3 | **критический**: сбой cp/rsync на бэкапе → die, «Бэкап сохранен», флешка НЕ тронута (parted-заглушка не вызывалась ни разу — проверка по STUB_LOG) |
| I-M4 | L3 | **критический**: сверка восстановления не сошлась → бэкап НЕ удалён |
| I-M5 | L3 | успешный цикл: бэкап → «разметка» (стаб Ventoy2Disk.sh в /tmp/ventoy-*/ предсоздан тестом) → восстановление → сверка → бэкап удалён |
| I-M6 | L3 | `copy_deploy_package`: на tmp-«разделе» появился deploy-baremetal/{deploy.sh,deploy.conf,templates/} |
| I-M7 | L3 | интерактивный ввод piped-строкой: размеры/ФС/метки → строка «Конфигурация:» содержит ожидаемое |
| I-M8 | L3 | выбор nvme-диска → отказ безопасности |

### 7.3 split-home.sh (L3, подпроцесс)

| ID | Уровень | Проверка |
|---|---|---|
| S-H1 | L3 | не-Live система без --dry-run → die «Загрузитесь с Live-USB» |
| S-H2 | L3 | `--help` → вывод заголовка, exit 0 |
| S-H3 | L5 | `--dry-run` на машине с целевым диском → exit 0 (помечен как conditional: пропуск, если /dev/nvme0n1p7 с целевым UUID не найден) |

### 7.4 Loop-интеграция (L4, root, только /dev/loop*)

| ID | Проверка |
|---|---|
| L-T1 | `truncate -s 8G img` + `losetup -fP` → `deploy.sh --disk /dev/loopX` (PREP_DISK без dry): `sfdisk -d` = 7 разделов, корректные типы/флаги; `lsblk -f` = fat32/ntfs/ntfs/exfat/ext4/ext4 |
| L-T2 | повторный PREP_DISK на том же loop (поверх) — exit 0 (переразметка чистая) |
| L-T3 | autounattend.xml после L-T1 сгенерирован, валиден (xmllint), PartitionID=3 |

После каждого теста: `losetup -d`, `rm img` (trap в bats-файле).

### 7.5 PowerShell (L1 + опция)

| ID | Проверка |
|---|---|
| P-1 | pwsh `Parser::ParseFile` на make-boot-usb.ps1: 0 ошибок (поймал бы `$Label:`; отсутствие pwsh = SKIP с жёлтым предупреждением, не провал) |
| P-2 | канарейка: временная копия ps1 с внедрённой строкой `"тест $x: текст"` → ParseFile обязан вернуть ошибку (метатест корректности P-1) |
| P-3 | (опция, Windows) Pester: мок Get-Disk/Get-Partition; запуск только при `$env:COMPUTERNAME` цели |

### 7.6 Dry-run E2E (L5, root)

| ID | Проверка |
|---|---|
| E-1 | `deploy.sh --full --dry-run` → exit 0; вывод соответствует `fixtures/dry-run-prep.golden` |
| E-2 | подтверждение «n» без --dry-run → abort до любых вызовов (STUB_LOG пуст) |

### 7.7 Метатесты

- M-1: `check-files.sh` падает на файле с BOM-нарушением и на `$x:` (синтетика) — т.е. сам детектор жив.
- M-2: все плейсхолдеры `__[A-Z_]+__` из templates имеют sed-подстановку в deploy.sh (grep-соответствие) — защита от забытых заглушек.

## 8. Раннер и интеграция

- `Makefile`: `test-fast` (L0–L3, без root, ~30 сек), `test` (= fast + L1 + L5),
  `test-loop` (L4, требует root, предупреждение перед запуском).
- `tests/run-all.sh <level>` — единая точка, итоговая сводка, ненулевой exit при любом провале.
- Pre-commit hook: добавить `make test-fast` после `check-files.sh` (быстрый уровень только).
- README: раздел «Тестирование» с командами.

## 9. Критерии приёмки (DoD)

1. `make test-fast` зелёный без root; `sudo make test` зелёный; `make test-loop` зелёный на машине с loop.
2. P-1 работает при установленном pwsh; при его отсутствии — SKIP, не FAIL.
3. Критические тесты данных (I-M3, I-M4) присутствуют и проваливаются при
   намеренной порче проверяемого кода (проверить вручную однажды, зафиксировать в отчёте).
4. Метатесты M-1/M-2 зелёные.
5. `shellcheck -S warning` = 0 в L0.
6. Все тесты детерминированы: повторный запуск 3× подряд — одинаковый результат.

## 10. Порядок работ и оценки

| Этап | Содержание | Оценка |
|---|---|---|
| T0 | ✅ Рефакторинг guard + golden-файл dry-run | M |
| T1 | ✅ setup.sh + каркас bats + L0/L1 в раннере | S |
| T2 | ✅ Юниты U-* (deploy, usb-sh) | M |
| T3 | ✅ Стабы + интеграционные I-M1..I-M8, I-D*, U-D6 | M |
| T4 | ✅ Loop-уровень L-T1..L-T3 | M |
| T5 | E2E dry-run + метатесты + Makefile + pre-commit | S |
| T6 | (опция) Pester на Windows-машине | M |

## 11. Ручной чек-лист на железе (вне автоматизации)

1. Windows-машина: запуск make-boot-usb.ps1 на некритимой флешке (полный цикл с бэкапом).
2. Реальная установка Windows по autounattend с Ventoy (§ потока в README).
3. split-home.sh --dry-run → реальный запуск на целевом NVMe.
4. Контрольный замер скорости и восстановление данных на реальной флешке.

## 12. Риски

- **pwsh в окружении недоступен** (нет сети/репозитория MS) — L1 деградирует до SKIP; компенсация: check-files.sh уже ловит `$var:` регексом.
- **loop-устройства запрещены** (контейнер/CI) — L4 помечать SKIP с явным предупреждением, не провалом.
- **Интерактивные read в тестах** — всегда подавать stdin через printf; тест, ожидающий ввод «висящим» read более 5 сек, считать провалившимся (timeout-обёртка в раннере).
- **Заглушки расходятся с реальностью** (сигнатуры lsblk и др.) — контракты §6 фиксировать по фактическому вызову из кода; при изменении вызовов в скриптах — обновлять заглушки в том же коммите.
