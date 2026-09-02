# 🗺️ ROADMAP — исправления и доработки deploy-baremetal

Основано на код-ревью от 2026-09-02. Порядок фаз обязателен: сначала страховка (git),
потом блокеры и защита данных, затем функциональные пробелы, полировка, верификация.

Обозначения размера: S (< 30 мин), M (1–3 ч), L (> 3 ч).

---

## Фаза 0 — Страховочная сетка (до любых правок)

- [x] **T0.1 (S)** `git init` + `.gitignore` (`*.bak*`, `parttable-*`, `usb_backup_*`, `*.log`)
      + стартовый коммит `snapshot: state before review fixes`.
      *Приёмка:* `git log --oneline` показывает коммит; `git status` чистый.

## Фаза 1 — Блокеры и защита от потери данных

- [x] **T1.1 (S)** 🔴 Удалить дубликат в `make-boot-usb.ps1`: оставить строки 1–1120,
      хвост (1121–2240 — точная копия) отсечь. Не потерять BOM и CRLF.
      *Приёмка:* `wc -l` = 1120; `grep -c SYNOPSIS` = 1; `grep -c 'param()'` = 1;
      `head -c 3 | xxd` = `efbb bf`; `file` = `UTF-8 (with BOM) ... CRLF`.
- [x] **T1.2 (M)** 🔴 `make-boot-usb.sh`: безопасный бэкап:
      1) путь бэкапа — не `/tmp`, если там tmpfs (Live-среда): спросить путь или `/var/tmp`;
      2) проверка свободного места (`df`) ≥ объём данных × 1.1, иначе `die`;
      3) копирование без `|| true` — сбой rsync/cp = `die` ДО разметки;
      4) `rm -rf "$BACKUP_DIR"` только после успешной сверки восстановления
      (число файлов и сумма байт источник→бэкап→флешка совпадают).
- [x] **T1.3 (M)** 🔴 `make-boot-usb.ps1`: то же самое: `Copy-Item` без
      `-ErrorAction SilentlyContinue` (try/catch + завершение), проверка свободного
      места на диске `%TEMP%` (`Get-PSDrive`), сверка после восстановления,
      `Remove-Item $backupDir` только после успеха.
- [x] **T1.4 (S)** `deploy.sh`: cleanup-ловушка `trap ... EXIT` с отмонтированием
      `/tmp/win_iso_mnt`, `/tmp/win_sys_mnt`, `/tmp/ubu_iso_mnt`, `/tmp/ubuntu_root_mnt`,
      `/tmp/boot_repair_root` (+ бинды chroot) — чтобы сбой не оставлял монтирования.

## Фаза 2 — Функциональные пробелы

- [x] **T2.1 (L)** 🔴 Стратегия установки Windows — **решение: вариант A**
      (текущий wimlib-путь не создаёт загрузчик Windows — система не грузится):
      1) новый режим `--prep-disk`: разметка + форматирование без установки ОС;
      2) генерация полного `autounattend.xml` с `<DiskConfiguration>` под нашу
         разметку (ModifyPartition по размерам, `WillWipeDisk=false`), компоненты
         из текущего `templates/unattend.xml.template` перенести;
      3) код wimlib (`do_deploy_windows`) удалить, режимы FULL/REINSTALL_WINDOWS
         заменить на документированный поток:
         `--prep-disk` → загрузка Windows ISO с Ventoy (autounattend) →
         `--reinstall-ubuntu` (ставит Ubuntu + GRUB c os-prober последним);
      4) обновить `README.md`.
      *Альтернатива B (отклонена):* wimlib + ручной `bcdboot` из WinPE.
- [x] **T2.2 (S)** `deploy.sh`: перед `update-grub` дописать
      `GRUB_DISABLE_OS_PROBER=false` в `/etc/default/grub` (GRUB ≥ 2.06 иначе
      не ищет Windows).
- [x] **T2.3 (S)** `deploy.sh`: путь debootstrap без ядра не загружается —
      заменить на `die "Требуется ISO Ubuntu (debootstrap не поддерживается)"`.
- [x] **T2.4 (M)** Мёртвые опции `deploy.conf` — реализовать или убрать:
      - `TIMEZONE` → `ln -sf /usr/share/zoneinfo/$TIMEZONE` в chroot (+ в unattend);
      - `DEFAULT_LOCALE` → `locale-gen` + `update-locale` в chroot;
      - `INSTALL_RESTRICTED_DRIVERS` → `ubuntu-drivers autoinstall` в chroot (warn при сбое);
      - `ENABLE_SHARED_AUTOMOUNT` → условная запись fstab-строки `/mnt/Shared`;
      - `ROOT_FSTYPE`/`HOME_FSTYPE` → либо реализовать (ext4/btrfs в mkfs+fstab),
        либо удалить из conf; вариант «в комментариях btrfs/f2fs/xfs» убрать.
- [x] **T2.5 (M)** `make-boot-usb.sh`: копировать пакет на раздел данных
      (`split-home.sh`, `deploy.sh`, `deploy.conf`, `templates/`) — как в ps1-версии;
      устранить расхождение с README.
- [x] **T2.6 (S)** `deploy.conf`: `WIN_PASSWORD` (по умолчанию пусто) +
      подстановка в шаблон unattend вместо жёсткого пустого пароля.

## Фаза 3 — Полировка

- [x] **T3.1 (S)** `make-boot-usb.sh:272` — в строке «Чтение» печатать `dur_r_ms`
      (сейчас `dur_w_ms` — копипаста).
- [x] **T3.2 (S)** `split-home.sh:247` — `rm -rf dir/.*` заменить на
      `find "$MNT_ROOT/home" -mindepth 1 -delete` (SC2115).
- [x] **T3.3 (S)** `make-boot-usb.sh` `ensure_ventoy_tool`: убрать блуждание
      `find /home /tmp` — всегда скачивать закреплённую версию в `/tmp`.
- [x] **T3.4 (S)** `make-boot-usb.ps1:111` — строку TLS 1.3 обернуть в try/catch
      (enum нет на .NET < 4.8).
- [x] **T3.5 (S)** `make-boot-usb.sh:227` — `chown` fallback вместо `asv-spb`
      использовать `${SUDO_USER:-$(logname 2>/dev/null || echo root)}`.
- [x] **T3.6 (M)** `shellcheck -S warning` чисто по всем `.sh`
      (осознанные отключки — с комментарием `# shellcheck disable=...`).
- [x] **T3.7 (S)** `deploy.sh` — `timedatectl` в chroot не работает: заменить на
      установку TZ симлинком (см. T2.4), строку с timedatectl удалить.

## Фаза 4 — Верификация и документация

- [x] **T4.1 (M)** Скрипт `check-files.sh`: проверка BOM+CRLF+один SYNOPSIS+
      отсутствие умных кавычек U+201C/U+201D/U+2018/U+2019+ баланс `{}`/`()`
      для `*.ps1`; для `*.sh` — `bash -n`. Подключить как git pre-commit hook.
- [ ] **T4.2 (S)** Прогон сухих тестов: `bash -n` всех `.sh`;
      `bash deploy.sh --full --dry-run`; `bash split-home.sh --dry-run`.
- [ ] **T4.3 (S)** `README.md`: синхронизировать с фактическим поведением
      (новый поток установки Windows из T2.1, копирование пакета, режимы).

---

## Железные правила для исполнителя

1. `.ps1` с кириллицей — **только UTF-8 с BOM + CRLF** (см. `AGENTS.md`).
2. `make-boot-usb.bat` — CP866, не трогать и не перекодировать.
3. Один коммит = одна задача, сообщение вида `T1.2: safe backup in make-boot-usb.sh`.
4. Не рефакторить работающий код за пределами задачи, не переводить русские
   сообщения на английский, не менять интерактивный UX без указания в задаче.
5. После каждой правки `.sh` — `bash -n` и `shellcheck`; после правки `.ps1` —
   `check-files.sh` (T4.1) или ручные проверки кодировки.
