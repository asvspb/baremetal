# 🚀 Deploy Baremetal & Boot USB Engine

Комплекс инструментов для автоматического создания загрузочных мультизагрузочных флешек Ventoy и полностью автономного развертывания операционных систем **Ubuntu 24.04/22.04 LTS** и **Windows 11/10 Pro** на чистый диск или в режиме Dual-Boot.

---

## 🛠️ Создание загрузочной флешки

В проект включены интерактивные скрипты для подготовки любой флешки в **Linux** и **Windows**:

### 🐧 Для Linux (Bash):
```bash
sudo bash ~/Dev/deploy-baremetal/make-boot-usb.sh
```
* **Автоматически:**
  * Находит подключенные USB-флешки и защищает системные диски.
  * Размечает в GPT с поддержкой UEFI Secure Boot.
  * Создает раздел **Ventoy (exFAT)** с меткой (`FD-0`, `FD-1`, `FD-2` и т.д.) нужного размера (8 ГБ / 16 ГБ / кастомный).
  * Устанавливает темную тему **Xenlism-Ubuntu (1080p)** и `ventoy.json`.
  * Создает раздел данных (по выбору: **F2FS со сжатием**, **exFAT** для совместимости с Android/Windows или **NTFS**).
  * Скрывает служебный EFI раздел `VTOYEFI`.
  * Автоматически копирует пакет развертывания `deploy-baremetal/` (`deploy.sh`, `deploy.conf`, `split-home.sh`, `templates/`) на раздел данных.

### 🪟 Для Windows (PowerShell):
Самый простой способ — двойной клик по **`make-boot-usb.bat`**: он сам запросит права Администратора через UAC и запустит мастер.

Либо запустите PowerShell от имени Администратора вручную:
```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
.\make-boot-usb.ps1
```
* Скачивает официальный Ventoy, создает разделы (`exFAT` под ISO + раздел данных `DATA`), настраивает конфигурацию и скрывает служебный раздел EFI в Проводнике Windows.

> ⚠️ **Важно про кодировки файлов:**
> * `make-boot-usb.bat` — **CP866 (OEM/DOS) + CRLF**: единственная кодировка, которую cmd.exe корректно разбирает вместе с русским текстом. Не пересохраняйте его в UTF-8 и не добавляйте `chcp 65001` — иначе строки скрипта начнут «рваться» и исполняться как команды (`'...' is not recognized as an internal or external command`).
> * `make-boot-usb.ps1` — **UTF-8 with BOM + CRLF**: без BOM Windows PowerShell 5.1 прочитает файл как ANSI и русский текст сломается.

---

## 📐 Архитектура разметки накопителей серии FD:

```text
[ USB Накопитель ]
├── Раздел 1 (exFAT, 8 / 16 ГБ) — Метка «FD-0 / FD-1 / FD-2»
│   ├── /ventoy/theme/Xenlism-Ubuntu/ (Full HD 1080p)
│   ├── /ventoy/ventoy.json (Разрешение и шрифты)
│   └── (Свободное место для загрузочных .iso образов)
│
├── Раздел 2 (FAT16, 32 МБ) — «VTOYEFI» (Скрытый системный загрузчик)
│
└── Раздел 3 (F2FS / exFAT, остаток диска) — Метка «F2FS / DATA»
    └── deploy-baremetal/ (Автономный пакет развертывания OS)
        ├── deploy.sh      (Установщик Dual-Boot: разметка, autounattend, Ubuntu + GRUB)
        ├── deploy.conf    (Конфигурация размеров разделов и параметров)
        ├── split-home.sh  (Разделение существующей системы на / и /home)
        └── templates/     (unattend.xml.template для Windows Setup)
```

---

## 🧪 Тестирование (TEST-SPEC.md)

```bash
bash tests/setup.sh     # один раз: bats-core, pwsh, xmllint (idempotent)
make test-fast          # L0–L3: статика + юниты + интеграция на заглушках (без root, ~1 мин)
sudo -n make test       # = test-fast + L1 (парсинг ps1 через pwsh) + L5 (dry-run E2E против golden)
sudo -n make test-loop  # L4: реальные parted/mkfs на loop-устройствах (только /dev/loop*)
```

* Уровни: L0 статика → L1 парсинг ps1 → L2 юниты → L3 интеграция на стабах → L4 loop → L5 dry-run E2E (см. `TEST-SPEC.md`).
* **Безопасность:** тесты никогда не пишут на реальные диски; L3 крутится вокруг несуществующих `/dev/fakedisk*`, L4 — только `/dev/loop*` с проверкой имени устройства; заглушка `dd` всегда возвращает ошибку.
* `make test-fast` подключен к pre-commit hook (при отсутствии deps — предупреждение, коммит не блокируется).
* pwsh недоступен → уровень L1 выдаёт SKIP (штатная деградация), статический контроль остаётся в `check-files.sh`.

---

## 📜 Основные скрипты проекта:

1. 🔌 [**`make-boot-usb.sh`**](file:///home/asv-spb/Dev/deploy-baremetal/make-boot-usb.sh) — создание загрузочных флешек под Linux.
2. 🔌 [**`make-boot-usb.ps1`**](file:///home/asv-spb/Dev/deploy-baremetal/make-boot-usb.ps1) — создание загрузочных флешек под Windows.
3. ⚡ [**`split-home.sh`**](file:///home/asv-spb/Dev/deploy-baremetal/split-home.sh) — безрисковое разделение текущей Ubuntu на корень (200 ГБ) и `/home` (~427 ГБ).
4. 💻 [**`deploy.sh`**](file:///home/asv-spb/Dev/deploy-baremetal/deploy.sh) — модульный установщик чистых ОС с нуля (Ubuntu + Windows Dual-Boot).

---

## 🪟 Как ставится Windows (вариант A: autounattend.xml + Ventoy)

Windows больше **не** распаковывается из ISO через `wimlib-imagex` (такой способ не создавал загрузчик Windows, и система не стартовала). Вместо этого используется штатный установщик Windows, запущенный загрузкой ISO с флешки Ventoy:

1. **`sudo bash deploy.sh --prep-disk`** — разметка GPT + форматирование всех разделов **без установки ОС**. Скрипт дополнительно генерирует полный `autounattend.xml` (файл кладётся рядом с Windows ISO на флешке): в нём `<DiskConfiguration>` под нашу разметку (`WillWipeDisk=false`, переформатируется только раздел Windows C:), настройки UTC / Fast Startup / BitLocker, локали и OOBE.
2. **Перезагрузка** → в меню Ventoy выбираем Windows ISO. Установщик автоматически применяет `autounattend.xml`, ставит Windows на раздел C: и сам создаёт загрузчик.
3. **`sudo bash deploy.sh --reinstall-ubuntu`** — Ubuntu ставится **последней**; GRUB с `os-prober` обнаруживает установленную Windows и создаёт полноценное меню Dual-Boot.

> Старые режимы `--full` (автоматическая распаковка Windows) и `--reinstall-windows` удалены — они заменены этим документированным потоком. `--full` / `-f` оставлен как синоним этапа `--prep-disk`.
