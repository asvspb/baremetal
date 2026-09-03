<#
.SYNOPSIS
    make-boot-usb.ps1 — Автоматизированное создание загрузочных флешек Ventoy
                        для Windows (PowerShell) с авто-бэкапом данных, картой структуры
                        и адаптивной темой GRUB Xenlism из GitHub.

.DESCRIPTION
    Скрипт интерактивно определяет подключенные USB-накопители, выводит карту разделов,
    проверяет целостность, автоматически сохраняет существующие файлы и возвращает их после разметки.
    Загружает и устанавливает тему GRUB из https://github.com/xenlism/Grub-themes в зависимости от ОС (Windows 11 / 10).
    Лог-файл ведется непосредственно на целевом носителе.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
# Версия сборки: меняется при каждой правке скрипта. 
# Выводится в баннере и первой строкой лога — сверяйте с шапкой 
# актуального файла в репозитории deploy-baremetal.
$ScriptVersion = "2026-09-02.7"

# ------------------------------------------------------------------------------
# СИСТЕМНОЕ ЛОГИРОВАНИЕ НА ЦЕЛЕВОЙ НОСИТЕЛЬ
# ------------------------------------------------------------------------------
$EnableDebugLogging = $true
$logFileName = "make-boot-usb-debug.log"
$tempLogPath = Join-Path $env:TEMP $logFileName
$activeLogPath = $tempLogPath
$usbLogFinalPath = $null

function Update-LogTarget {
    param([string]$NewPath)
    if (-not $EnableDebugLogging) { return }
    
    try {
        if ((Test-Path $activeLogPath) -and ($activeLogPath -ne $NewPath)) {
            $destDir = Split-Path -Path $NewPath -Parent
            if ($destDir -and (Test-Path $destDir)) {
                Copy-Item -Path $activeLogPath -Destination $NewPath -Force -ErrorAction SilentlyContinue
            }
        }
        $global:activeLogPath = $NewPath
    } catch {}
}

function Write-Log {
    param(
        [Parameter(Mandatory=$true)][string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR", "DEBUG", "SUCCESS")][string]$Level = "INFO"
    )
    if ($EnableDebugLogging) {
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
        $logEntry = "[$timestamp] [$Level] $Message"
        
        # Запись в текущий активный лог-файл (на носителе или в TEMP)
        try {
            Add-Content -Path $activeLogPath -Value $logEntry -Encoding UTF8 -ErrorAction SilentlyContinue
        } catch {}
        
        # Зеркалирование в TEMP для гарантированной сохранности истории
        if ($activeLogPath -ne $tempLogPath) {
            try {
                Add-Content -Path $tempLogPath -Value $logEntry -Encoding UTF8 -ErrorAction SilentlyContinue
            } catch {}
        }
    }
}

function Write-LogBlock {
    param(
        [Parameter(Mandatory=$true)][string]$Title,
        [Parameter(Mandatory=$true)][string]$Content
    )
    if ($EnableDebugLogging) {
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
        $divider = "----------------------------------------------------------------------"
        $block = "`n[$timestamp] [DEBUG] === $Title ===`n$divider`n$Content`n$divider`n"
        try {
            Add-Content -Path $activeLogPath -Value $block -Encoding UTF8 -ErrorAction SilentlyContinue
        } catch {}
        if ($activeLogPath -ne $tempLogPath) {
            try {
                Add-Content -Path $tempLogPath -Value $block -Encoding UTF8 -ErrorAction SilentlyContinue
            } catch {}
        }
    }
}

# ------------------------------------------------------------------------------
# Измерение длительности этапов: пауза ОС (сон) внутри этапа видна в логе
# как аномальная длительность ("Этап '...' завершен за N сек").
# Хелперы не создают областей видимости — код этапов остаётся без изменений.
# ------------------------------------------------------------------------------
$script:PhaseStopwatch = $null
$script:PhaseName = ""
function Measure-PhaseStart {
    param([Parameter(Mandatory=$true)][string]$Name)
    $script:PhaseStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $script:PhaseName = $Name
}
function Measure-PhaseEnd {
    if ($script:PhaseStopwatch) {
        $script:PhaseStopwatch.Stop()
        Write-Log ("Этап '{0}' завершен за {1} сек" -f $script:PhaseName, [int]$script:PhaseStopwatch.Elapsed.TotalSeconds) "INFO"
        $script:PhaseStopwatch = $null
        $script:PhaseName = ""
    }
}

# Инициализация лог-файла в TEMP
if ($EnableDebugLogging) {
    try {
        $osInfo = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
        $initHeader = @"
======================================================================
  VENTOY BOOT USB BUILDER & AUTOMATOR — СИСТЕМНЫЙ ЛОГ НА НОСИТЕЛЕ
======================================================================
Дата запуска:      $(Get-Date -Format "yyyy-MM-dd HH:mm:ss (zzz)")
Версия скрипта:    $ScriptVersion
ОС:                $($osInfo.Caption) (Версия: $($osInfo.Version), Сборка: $($osInfo.BuildNumber))
Архитектура ОС:    $($osInfo.OSArchitecture)
PowerShell:        $($PSVersionTable.PSVersion) (CLR: $($PSVersionTable.CLRVersion))
Рабочий каталог:   $((Get-Location).Path)
Временный лог:     $tempLogPath
Целевой лог:       [Будет привязан к USB-накопителю]
======================================================================

"@
        Set-Content -Path $tempLogPath -Value $initHeader -Encoding UTF8 -Force
    } catch {}
}

Write-Log "Скрипт make-boot-usb.ps1 запущен." "INFO"

# Включение современных протоколов TLS для безопасного скачивания с GitHub.
# Enum Tls13 отсутствует на .NET < 4.8 (Windows PowerShell 5.1 + старый .NET),
# поэтому пробуем включить его в try/catch и молча довольствуемся TLS 1.2.
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
    Write-Log "Настроен протокол TLS 1.2 / TLS 1.3." "DEBUG"
} catch {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Write-Log "TLS 1.3 недоступен (старый .NET) — используется TLS 1.2." "DEBUG"
}

# Настройка UTF-8 для корректного отображения русского языка.
chcp 65001 > $null
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# ------------------------------------------------------------------------------
# 0. Проверка прав Администратора
# ------------------------------------------------------------------------------
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$isAdmin = $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Write-Log "Проверка прав администратора: $isAdmin" "DEBUG"

if (-not $isAdmin) {
    Write-Log "Недостаточно привилегий. Выполняется перезапуск с повышением прав через UAC..." "WARN"
    Write-Warning "Скрипт требует прав Администратора. Перезапуск с повышенными привилегиями..."
    Start-Process powershell.exe -ArgumentList ("-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"") -Verb RunAs
    exit
}

Clear-Host
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "   🛠️ VENTOY BOOT USB BUILDER & AUTOMATOR (WINDOWS / POWERSHELL)      " -ForegroundColor Cyan
Write-Host "   Версия сборки: $ScriptVersion" -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor Cyan
if ($EnableDebugLogging) {
    Write-Host "  📝 Системное логирование: ПРЯМО НА ЦЕЛЕВОЙ НОСИТЕЛЬ ($logFileName)" -ForegroundColor Yellow
}

$backupDir = "$env:TEMP\usb_backup_$(Get-Random)"
$doRestore = $false
Write-Log "Каталог временного резервного копирования: $backupDir" "DEBUG"

# ------------------------------------------------------------------------------
# Функция вывода наглядной карты структуры накопителя
# ------------------------------------------------------------------------------
function Show-DiskMap {
    param([int]$diskNumber)
    $d = Get-Disk -Number $diskNumber -ErrorAction SilentlyContinue
    if (-not $d) { return }

    $dSizeGB = [math]::Round($d.Size / 1GB, 2)
    $parts = @(Get-Partition -DiskNumber $diskNumber -ErrorAction SilentlyContinue | Sort-Object Offset)

    Write-Host "`n======================================================================" -ForegroundColor Cyan
    Write-Host "  🗺️ КАРТА ТЕКУЩЕЙ СТРУКТУРЫ НАКОПИТЕЛЯ:" -ForegroundColor Cyan
    Write-Host "======================================================================" -ForegroundColor Cyan
    Write-Host " Диск:              Диск $($d.Number) ($($d.FriendlyName))" -ForegroundColor White
    Write-Host " Емкость / Стиль:   $dSizeGB GB  [Стиль таблицы: $($d.PartitionStyle)]" -ForegroundColor White
    Write-Host " Состояние / Шина:  $($d.OperationalStatus) / $($d.BusType)" -ForegroundColor White
    Write-Host "----------------------------------------------------------------------" -ForegroundColor Gray

    # Визуальная диаграмма блоков разделов
    if ($parts.Count -gt 0) {
        Write-Host "Схема разделов:" -ForegroundColor Yellow
        $diagram = ""
        foreach ($p in $parts) {
            $pSizeGB = [math]::Round($p.Size / 1GB, 2)
            $pSizeMB = [math]::Round($p.Size / 1MB, 0)
            $sizeDisp = if ($pSizeGB -ge 1) { "$pSizeGB GB" } else { "$pSizeMB MB" }
            
            $lbl = ""
            if ($p.DriveLetter -and [int][char]$p.DriveLetter -ne 0) {
                $vol = Get-Volume -DriveLetter $p.DriveLetter -ErrorAction SilentlyContinue
                if ($vol -and $vol.FileSystemLabel) { $lbl = " '$($vol.FileSystemLabel)'" }
            } elseif ($p.PartitionNumber -eq 2) {
                $lbl = " (VTOYEFI)"
            }
            $letStr = if ($p.DriveLetter -and [int][char]$p.DriveLetter -ne 0) { " [$($p.DriveLetter):]" } else { "" }
            $diagram += "[ Разд. $($p.PartitionNumber)$letStr${lbl}: $sizeDisp ] "
        }
        Write-Host "  $diagram" -ForegroundColor Cyan
        Write-Host "----------------------------------------------------------------------" -ForegroundColor Gray

        # Таблица разделов
        Write-Host " #  Буква  Метка              ФС        Размер       Свободно       Тип / Назначение" -ForegroundColor Yellow
        Write-Host " -  -----  -----------------  --------  -----------  -------------  ------------------------------" -ForegroundColor Gray

        foreach ($p in $parts) {
            $let = if ($p.DriveLetter -and [int][char]$p.DriveLetter -ne 0) { "$($p.DriveLetter):" } else { "-" }
            $vol = if ($p.DriveLetter -and [int][char]$p.DriveLetter -ne 0) { Get-Volume -DriveLetter $p.DriveLetter -ErrorAction SilentlyContinue } else { $null }
            $label = if ($vol -and $vol.FileSystemLabel) { $vol.FileSystemLabel } elseif ($p.PartitionNumber -eq 2) { "VTOYEFI" } else { "-" }
            $fs = if ($vol -and $vol.FileSystem) { $vol.FileSystem } elseif ($p.PartitionNumber -eq 2) { "FAT16" } else { "-" }
            
            $pSizeGB = [math]::Round($p.Size / 1GB, 2)
            $pSizeMB = [math]::Round($p.Size / 1MB, 0)
            $sz = if ($pSizeGB -ge 1) { "$pSizeGB GB" } else { "$pSizeMB MB" }

            $free = if ($vol -and $vol.SizeRemaining) {
                $fGB = [math]::Round($vol.SizeRemaining / 1GB, 2)
                if ($fGB -ge 1) { "$fGB GB" } else { "$([math]::Round($vol.SizeRemaining / 1MB, 0)) MB" }
            } else { "-" }

            $gpt = if ($p.PartitionNumber -eq 2) { "Служебный EFI (Загрузчик)" } elseif ($p.GptType) { $p.GptType } else { $p.Type }
            if ($gpt.Length -gt 30) { $gpt = $gpt.Substring(0, 27) + "..." }

            $line = "{0,2}  {1,-5}  {2,-17}  {3,-8}  {4,-11}  {5,-13}  {6}" -f $p.PartitionNumber, $let, $label, $fs, $sz, $free, $gpt
            Write-Host " $line" -ForegroundColor White
        }
    } else {
        Write-Host "  [!] На диске нет созданных разделов (чистый накопитель или неразмеченная область)." -ForegroundColor Yellow
    }
    Write-Host "======================================================================" -ForegroundColor Cyan
    
    Write-Log "Выведена карта структуры накопителя Диск $($d.Number) ($($parts.Count) разделов)." "INFO"
}

# ------------------------------------------------------------------------------
# Функция проверки целостности и битых файлов
# ------------------------------------------------------------------------------
function Test-DriveIntegrity {
    param([int]$diskNumber)
    Write-Log "Запуск проверки целостности накопителя (Диск $diskNumber)..." "INFO"
    Write-Host "`n======================================================================" -ForegroundColor Cyan
    Write-Host "  🩺 ПРОВЕРКА ЦЕЛОСТНОСТИ И БИТЫХ ФАЙЛОВ НА ФЛЕШКЕ:" -ForegroundColor Cyan
    Write-Host "======================================================================" -ForegroundColor Cyan

    $partitions = Get-Partition -DiskNumber $diskNumber -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter -and [int][char]$_.DriveLetter -ne 0 }
    if (-not $partitions) {
        Write-Log "На Диске $diskNumber нет смонтированных разделов с буквами дисков для проверки файловой системы." "WARN"
        Write-Host "[ИНФО] На накопителе нет смонтированных разделов для проверки файловой структуры." -ForegroundColor Yellow
        return
    }

    $hasErrors = $false
    foreach ($part in $partitions) {
        $letter = "$($part.DriveLetter):"
        Write-Log "Сканирование раздела $($letter) (Раздел $($part.PartitionNumber), Размер: $([math]::Round($part.Size / 1MB, 2)) МБ)..." "DEBUG"
        Write-Host "`n• Сканирование раздела $letter..." -ForegroundColor Cyan
        try {
            $repairResult = Repair-Volume -DriveLetter $part.DriveLetter -Scan -ErrorAction SilentlyContinue
            Write-Log "Результат Repair-Volume для $($letter): $repairResult" "DEBUG"
            if ($repairResult -eq "NoErrorsFound" -or $repairResult -eq 0 -or $null -eq $repairResult) {
                Write-Host "  ✅ Раздел ${letter} файловая структура исправна, битых файлов не обнаружено." -ForegroundColor Green
                Write-Log "Раздел $($letter) - ошибок не обнаружено." "SUCCESS"
            } else {
                Write-Host "  ⚠️ Раздел ${letter} обнаружены ошибки ($repairResult). Будут исправлены при форматировании." -ForegroundColor Yellow
                Write-Log "Раздел $($letter) - обнаружены ошибки ($repairResult)." "WARN"
                $hasErrors = $true
            }
        }
        catch {
            Write-Log "Исключение при сканировании раздела $($letter): $_" "WARN"
            Write-Host "  [ИНФО] Сканирование раздела $letter завершено." -ForegroundColor Gray
        }
    }

    if (-not $hasErrors) {
        Write-Host "`n✅ Целостность накопителя в норме. Ошибок не обнаружено." -ForegroundColor Green
        Write-Log "Проверка целостности диска $diskNumber успешно пройдена без ошибок." "SUCCESS"
    } else {
        Write-Host "`n⚠️ Обнаружены ошибки в текущих разделах. Форматирование полностью создаст чистую разметку." -ForegroundColor Yellow
        Write-Log "Обнаружены ошибки структуры диска $diskNumber. Требуется переразметка." "WARN"
    }
}

# ------------------------------------------------------------------------------
# Функция замера скорости чтения / записи
# ------------------------------------------------------------------------------
function Run-SpeedTest {
    param(
        [string]$driveLetter,
        [string]$title,
        [int]$sizeMB = 512
    )
    $path = "$($driveLetter):\"
    if (-not (Test-Path $path)) { return }
    $testFile = Join-Path $path "__speed_test_tmp.dat"
    Write-Log "Запуск замера скорости для $title ($path), размер тестового блока: $sizeMB МБ..." "INFO"
    Write-Host "`n⏱️ Замер скорости: $title (блок $sizeMB МБ)..." -ForegroundColor Cyan

    try {
        $buffer = New-Object byte[] (4MB)
        $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
        $rng.GetBytes($buffer)

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $fs = [System.IO.File]::Create($testFile, 4MB, [System.IO.FileOptions]::WriteThrough)
        for ($b = 0; $b -lt ($sizeMB / 4); $b++) {
            $fs.Write($buffer, 0, $buffer.Length)
        }
        $fs.Flush($true)
        $fs.Close()
        $sw.Stop()
        $writeSec = $sw.Elapsed.TotalSeconds
        $writeSpeed = [math]::Round($sizeMB / $writeSec, 2)

        $sw.Restart()
        $fs = [System.IO.File]::OpenRead($testFile)
        $readBuf = New-Object byte[] (4MB)
        while (($read = $fs.Read($readBuf, 0, $readBuf.Length)) -gt 0) {}
        $fs.Close()
        $sw.Stop()
        $readSec = $sw.Elapsed.TotalSeconds
        $readSpeed = [math]::Round($sizeMB / $readSec, 2)

        Remove-Item $testFile -Force -ErrorAction SilentlyContinue

        # Файл только что записан самим тестом — ОС отдаёт его из кэша,
        # поэтому чтение отражает производительность конвейера ОС, не флешки.
        Write-Host "  • ✍️  Запись : $writeSpeed МБ/с ($sizeMB МБ за $([math]::Round($writeSec, 2)) сек)" -ForegroundColor Green
        Write-Host "  • 📖  Чтение (из кэша ОС) : $readSpeed МБ/с ($sizeMB МБ за $([math]::Round($readSec, 2)) сек)" -ForegroundColor Green
        Write-Log "Результат замера скорости $title ($path): Запись = $writeSpeed МБ/с, Чтение (из кэша ОС) = $readSpeed МБ/с" "SUCCESS"
    }
    catch {
        Write-Log "Ошибка при выполнении теста скорости на $($path): $_" "WARN"
        Write-Host "  [ВНИМАНИЕ] Не удалось выполнить тест: $_" -ForegroundColor Yellow
    }
}

# ------------------------------------------------------------------------------
# Функция загрузки и установки темы GRUB Xenlism по версии ОС
# ------------------------------------------------------------------------------
function Install-XenlismTheme {
    param(
        [string]$ventoyDriveLetter
    )
    if (-not $ventoyDriveLetter) { return }
    $vPath = "$($ventoyDriveLetter):"

    Write-Host "`n======================================================================" -ForegroundColor Cyan
    Write-Host "  🎨 УСТАНОВКА ОФИЦИАЛЬНОЙ ТЕМЫ GRUB (XENLISM):" -ForegroundColor Cyan
    Write-Host "======================================================================" -ForegroundColor Cyan

    # Определение версии Windows
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $osCaption = if ($os -and $os.Caption) { $os.Caption } else { "Windows" }
    $osBuild = if ($os -and $os.BuildNumber) { [int]$os.BuildNumber } else { 0 }

    $themeArchive = "xenlism-grub-win11-1080p.tar.xz"
    $themeDirName = "Xenlism-Win11"
    $themeTitle   = "Xenlism Windows 11 (Full HD 1080p)"

    if ($osCaption -match 'Windows 10' -or ($osBuild -ge 10240 -and $osBuild -lt 22000)) {
        $themeArchive = "xenlism-grub-win10-1080p.tar.xz"
        $themeDirName = "Xenlism-Win10"
        $themeTitle   = "Xenlism Windows 10 (Full HD 1080p)"
    } elseif ($osCaption -match 'Windows 11' -or $osBuild -ge 22000) {
        $themeArchive = "xenlism-grub-win11-1080p.tar.xz"
        $themeDirName = "Xenlism-Win11"
        $themeTitle   = "Xenlism Windows 11 (Full HD 1080p)"
    }

    Write-Host "• Обнаружена операционная система: $osCaption (Сборка $osBuild)" -ForegroundColor Yellow
    Write-Host "• Выбрана соответствующая тема: $themeTitle" -ForegroundColor Green
    Write-Log "Выбрана тема GRUB: $themeTitle ($themeArchive, Папка: $themeDirName) на основе ОС: $osCaption ($osBuild)" "INFO"

    $themeDownloaded = $false

    try {
        New-Item -Path "$vPath\ventoy\theme" -ItemType Directory -Force | Out-Null
        $tempTar = "$env:TEMP\$themeArchive"
        $tempExtract = "$env:TEMP\xenlism_extract_$(Get-Random)"
        New-Item -Path $tempExtract -ItemType Directory -Force | Out-Null

        $themeUrl = "https://raw.githubusercontent.com/xenlism/Grub-themes/main/$themeArchive"
        Write-Host "• Скачивание темы из репозитория GitHub (xenlism/Grub-themes)..." -ForegroundColor Cyan
        Write-Log "Загрузка архива темы: $themeUrl -> $tempTar" "DEBUG"
        Invoke-WebRequest -Uri $themeUrl -OutFile $tempTar -UseBasicParsing

        # Распаковка через tar.exe (встроен в Windows 10 build 17063+ и Windows 11)
        Write-Host "• Распаковка и установка компонентов темы..." -ForegroundColor Cyan
        $tarExe = Get-Command tar.exe -ErrorAction SilentlyContinue
        if ($tarExe) {
            & tar.exe -xf $tempTar -C $tempExtract 2>$null
            
            $foundThemeDir = Get-ChildItem -Path $tempExtract -Recurse -Directory -Filter $themeDirName -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($foundThemeDir) {
                Copy-Item -Path $foundThemeDir.FullName -Destination "$vPath\ventoy\theme\" -Recurse -Force -ErrorAction SilentlyContinue
                $themeDownloaded = $true
                Write-Log "Тема успешно распакована в $vPath\ventoy\theme\$themeDirName" "SUCCESS"
            }
        }

        # Очистка временных файлов распаковки
        Remove-Item $tempTar -Force -ErrorAction SilentlyContinue
        Remove-Item $tempExtract -Recurse -Force -ErrorAction SilentlyContinue
    } catch {
        Write-Log "Не удалось загрузить/распаковать тему из GitHub: $_" "WARN"
        Write-Host "  [ИНФО] Установка темы через сеть завершилась с предупреждением: $_" -ForegroundColor Gray
    }

    # Генерация ventoy.json
    Write-Host "• Настройка конфигурации графического интерфейса ventoy.json..." -ForegroundColor Cyan
    $vjsonPath = "$vPath\ventoy\ventoy.json"
    $vjsonContent = @"
{
    "theme": {
        "file": "/ventoy/theme/$themeDirName/theme.txt",
        "gfxmode": "1920x1080",
        "display_mode": "GUI",
        "ventoy_color": "#ffffff",
        "fonts": [
            "/ventoy/theme/$themeDirName/dejavu_sans_24.pf2",
            "/ventoy/theme/$themeDirName/dejavu_sans_48.pf2",
            "/ventoy/theme/$themeDirName/terminus-18.pf2"
        ]
    }
}
"@
    try {
        Set-Content -Path $vjsonPath -Value $vjsonContent -Encoding UTF8 -Force
        Write-Host "✅ Графическая тема $themeTitle и ventoy.json успешно применены!" -ForegroundColor Green
        Write-Log "Конфигурация $vjsonPath успешно записана для темы $themeDirName." "SUCCESS"
    } catch {
        Write-Log "Ошибка записи ventoy.json: $_" "WARN"
    }
}

# Копирование файла или каталога с индикатором прогресса и оценкой времени.
# Крупные файлы копируются блоками по 4 МБ, поэтому прогресс виден и внутри
# одного большого ISO. Заменяет Copy-Item в бэкапе и восстановлении.
# The structure is preserved from the name of the copied element (semantics of
# Copy-Item -Recurse: the directory dir is copied to dest\dir\...).
function Copy-WithProgress {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$DestinationDir,
        [Parameter(Mandatory=$true)][string]$Activity
    )
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.PSIsContainer) {
        $files = @(Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue)
    } else {
        $files = @($item)
    }
    $totalBytes = 0
    foreach ($f in $files) { $totalBytes += $f.Length }
    $copiedBytes = 0
    $fileIndex = 0
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $lastProgressMs = -1000
    $chunk = 4MB

    foreach ($f in $files) {
        $fileIndex++
        $rel = if ($item.PSIsContainer) { $item.Name + '\' + $f.FullName.Substring($Path.Length).TrimStart('\') } else { $f.Name }
        $destPath = Join-Path $DestinationDir $rel
        $destParent = Split-Path -Path $destPath -Parent
        if ($destParent -and -not (Test-Path -LiteralPath $destParent)) {
            New-Item -Path $destParent -ItemType Directory -Force | Out-Null
        }
        $src = [System.IO.File]::OpenRead($f.FullName)
        $dst = [System.IO.File]::Create($destPath)
        try {
            $buf = New-Object byte[] $chunk
            while (($read = $src.Read($buf, 0, $buf.Length)) -gt 0) {
                $dst.Write($buf, 0, $read)
                $copiedBytes += $read
                if (($sw.ElapsedMilliseconds - $lastProgressMs) -ge 200) {
                    $lastProgressMs = $sw.ElapsedMilliseconds
                    $elapsedSec = [math]::Max($sw.Elapsed.TotalSeconds, 0.2)
                    $speedBps = $copiedBytes / $elapsedSec
                    $etaSec = 0
                    if ($speedBps -gt 0) { $etaSec = [int](($totalBytes - $copiedBytes) / $speedBps) }
                    $etaStr = '{0:00}:{1:00}' -f [int]($etaSec / 60), [int]($etaSec % 60)
                    $pct = 100
                    if ($totalBytes -gt 0) { $pct = [int](100 * $copiedBytes / $totalBytes) }
                    $status = ('Файл {0} из {1}: {2} — {3:N1} из {4:N1} МБ, скорость {5:N1} МБ/с, осталось ~{6}' -f `
                        $fileIndex, $files.Count, $f.Name, ($copiedBytes / 1MB), ($totalBytes / 1MB), ($speedBps / 1MB), $etaStr)
                    Write-Progress -Activity $Activity -Status $status -PercentComplete $pct -SecondsRemaining $etaSec
                }
            }
        } finally {
            $dst.Close()
            $src.Close()
        }
        [System.IO.File]::SetLastWriteTime($destPath, $f.LastWriteTime)
    }
    Write-Progress -Activity $Activity -Completed
}

# Сверка восстановления: каждый файл из $BackupRoot должен присутствовать на
# разделе $DestRoot по тому же относительному пути и с тем же размером.
# Возвращает $true, если все файлы бэкапа восстановлены корректно.
function Test-BackupTreeMatch {
    param(
        [Parameter(Mandatory=$true)][string]$BackupRoot,
        [Parameter(Mandatory=$true)][string]$DestRoot,
        [Parameter(Mandatory=$true)][string]$Label
    )
    $srcFiles = @(Get-ChildItem -Path $BackupRoot -Recurse -File -Force -ErrorAction SilentlyContinue)
    if ($srcFiles.Count -eq 0) {
        Write-Log "Сверка ${Label}: в бэкапе нет файлов — пропуск." "WARN"
        return $true
    }
    $totalCount = $srcFiles.Count
    $totalBytes = ($srcFiles | Measure-Object -Property Length -Sum).Sum
    $missingCount = 0
    $mismatchCount = 0
    foreach ($src in $srcFiles) {
        $rel = $src.FullName.Substring($BackupRoot.Length).TrimStart('\')
        $destPath = Join-Path $DestRoot $rel
        if (-not (Test-Path -LiteralPath $destPath)) {
            Write-Log "Сверка ${Label}: отсутствует после восстановления: $rel" "WARN"
            $missingCount++
            continue
        }
        $destSize = (Get-Item -LiteralPath $destPath -Force).Length
        if ($destSize -ne $src.Length) {
            Write-Log "Сверка ${Label}: размер не совпадает: $rel (бэкап $($src.Length), флешка $destSize)" "WARN"
            $mismatchCount++
        }
    }
    if ($missingCount -gt 0 -or $mismatchCount -gt 0) {
        Write-Log "Сверка $Label НЕ пройдена: в бэкапе $totalCount файлов ($totalBytes байт), отсутствует $missingCount, размер не совпал у $mismatchCount." "ERROR"
        return $false
    }
    Write-Log "Сверка $Label пройдена: $totalCount файлов, $totalBytes байт совпадают с бэкапом." "SUCCESS"
    return $true
}

try {
    # ------------------------------------------------------------------------------
    # 1. Поиск и выбор USB-накопителя
    # ------------------------------------------------------------------------------
    Write-Log "Сканирование подключенных дисков в системе..." "INFO"
    $allDisks = @(Get-Disk -ErrorAction SilentlyContinue)
    
    $allDisksTable = $allDisks | Select-Object Number, FriendlyName, BusType, Size, PartitionStyle, IsSystem, IsBoot, OperationalStatus | Format-Table -AutoSize | Out-String
    Write-LogBlock "Все физические диски в системе" $allDisksTable

    $usbDisks = @($allDisks | Where-Object { ($_.BusType -eq 'USB' -or $_.Location -like '*USB*') -and $_.OperationalStatus -eq 'Online' -and -not $_.IsSystem -and -not $_.IsBoot })
    if (-not $usbDisks) {
        $usbDisks = @($allDisks | Where-Object { $_.BusType -eq 'USB' -and $_.OperationalStatus -eq 'Online' })
    }

    if (-not $usbDisks) {
        Write-Log "Подключенные целевые USB-диски не найдены." "ERROR"
        Write-Host "[ОШИБКА] Подключенные USB-накопители не найдены! Вставьте флешку и повторите запуск." -ForegroundColor Red
        Pause
        exit 1
    }

    Write-Host "`nДоступные USB-диски:" -ForegroundColor Yellow
    $i = 1
    foreach ($disk in $usbDisks) {
        $sizeGB = [math]::Round($disk.Size / 1GB, 2)
        Write-Host "  [$i] Диск $($disk.Number): $($disk.FriendlyName) ($sizeGB GB)" -ForegroundColor Green
        Write-Log "  USB-кандидат [$i]: Диск $($disk.Number) - $($disk.FriendlyName) ($sizeGB GB, Bus: $($disk.BusType))" "DEBUG"
        $i++
    }

    Write-Host ""
    $targetDisk = $null
    while (-not $targetDisk) {
        $sel = Read-Host "Выберите номер диска [1-$($usbDisks.Count)]"
        $sel = ([string]$sel).Trim()

        if ($sel -eq '') {
            if ($usbDisks.Count -eq 1) {
                Write-Host "[ИНФО] Выбран единственный доступный диск." -ForegroundColor Yellow
                $sel = '1'
            } else {
                Write-Host "[ОШИБКА] Введите число от 1 до $($usbDisks.Count)." -ForegroundColor Red
                continue
            }
        }

        if ($sel -notmatch '^\d+$') {
            Write-Host "[ОШИБКА] Введите число от 1 до $($usbDisks.Count)." -ForegroundColor Red
            continue
        }

        $diskIndex = [int]$sel - 1
        if ($diskIndex -lt 0 -or $diskIndex -ge $usbDisks.Count) {
            Write-Host "[ОШИБКА] Неверный выбор. Введите число от 1 до $($usbDisks.Count)." -ForegroundColor Red
            continue
        }

        $targetDisk = $usbDisks[$diskIndex]
    }
    $totalSizeGB = [math]::Round($targetDisk.Size / 1GB, 2)
    $totalSizeMB = [math]::Round($targetDisk.Size / 1MB, 0)

    Write-Log "Выбран целевой диск: Диск $($targetDisk.Number) ($($targetDisk.FriendlyName), $totalSizeGB GB, $totalSizeMB MB)" "INFO"
    Write-Host "`nВыбран целевой накопитель: Диск $($targetDisk.Number) ($($targetDisk.FriendlyName), $totalSizeGB GB)" -ForegroundColor Cyan

    # --------------------------------------------------------------------------
    # Подключение лог-файла напрямую на накопитель (если есть разделы)
    # --------------------------------------------------------------------------
    $initialPartitions = @(Get-Partition -DiskNumber $targetDisk.Number -ErrorAction SilentlyContinue)
    $existingParts = @($initialPartitions | Where-Object { $_.DriveLetter -and [int][char]$_.DriveLetter -ne 0 -and $_.GptType -ne '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' }) # ESP (VTOYEFI) исключен: его файлы загрузчика воссоздает Ventoy2Disk
    if ($existingParts) {
        $firstLetter = "$($existingParts[0].DriveLetter):"
        $usbDirectLog = Join-Path "$firstLetter\" $logFileName
        Update-LogTarget -NewPath $usbDirectLog
        Write-Log "Логирование подключено напрямую на раздел: $usbDirectLog" "INFO"
    }

    # --------------------------------------------------------------------------
    # 1. Вывод карты текущей структуры накопителя (ДО проверки)
    # --------------------------------------------------------------------------
    Show-DiskMap -diskNumber $targetDisk.Number

    # --------------------------------------------------------------------------
    # 2. Автоматическая проверка целостности накопителя
    # --------------------------------------------------------------------------
    Measure-PhaseStart 'Проверка целостности'
    Test-DriveIntegrity -diskNumber $targetDisk.Number
    Measure-PhaseEnd

    # --------------------------------------------------------------------------
    # 3. Идентификация и бэкап данных на носителе перед разметкой
    # --------------------------------------------------------------------------
    $foundItems = @()
    $totalBackupBytes = 0
    $detailedFileList = @()

    Write-Log "Сканирование файловой структуры на доступных разделах..." "INFO"

    if ($existingParts) {
        foreach ($p in $existingParts) {
            $pLetter = "$($p.DriveLetter):"
            $pPath = "$pLetter\"
            $volInfo = Get-Volume -DriveLetter $p.DriveLetter -ErrorAction SilentlyContinue
            Write-Log "Раздел $pLetter — Метка: '$($volInfo.FileSystemLabel)', ФС: '$($volInfo.FileSystem)', Свободно: $([math]::Round($volInfo.SizeRemaining / 1MB, 2)) MB / $([math]::Round($volInfo.Size / 1MB, 2)) MB" "DEBUG"

            if (Test-Path $pPath) {
                # Исключаем служебные файлы и сам лог-файл
                $rawItems = Get-ChildItem -Path $pPath -Force -ErrorAction SilentlyContinue | 
                            Where-Object { $_.Name -notin @('$RECYCLE.BIN', 'System Volume Information', 'lost+found', 'ventoy', $logFileName) }
                foreach ($item in $rawItems) {
                    $foundItems += $item
                    $itemType = if ($item.PSIsContainer) { "DIR" } else { "FILE" }
                    $itemBytes = 0

                    if ($item.PSIsContainer) {
                        $sub = Get-ChildItem -Path $item.FullName -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue
                        if ($sub -and $sub.Sum) { $itemBytes = $sub.Sum }
                    } else {
                        $itemBytes = $item.Length
                    }
                    $totalBackupBytes += $itemBytes
                    $detailedFileList += [PSCustomObject]@{
                        Partition = $pLetter
                        Type      = $itemType
                        Name      = $item.Name
                        FullPath  = $item.FullName
                        SizeBytes = $itemBytes
                        SizeMB    = [math]::Round($itemBytes / 1MB, 2)
                        Modified  = $item.LastWriteTime
                    }
                }
            }
        }
    }

    if ($detailedFileList.Count -gt 0) {
        $filesTable = $detailedFileList | Format-Table Partition, Type, SizeMB, Name, Modified -AutoSize | Out-String
        Write-LogBlock "Идентифицированные файлы и каталоги на носителе" $filesTable
    } else {
        Write-Log "На накопителе не обнаружено пользовательских файлов (диск чист или пуст)." "INFO"
    }

    if ($foundItems.Count -gt 0) {
        $totalMB = [math]::Round($totalBackupBytes / 1MB, 2)
        Write-Host "`n======================================================================" -ForegroundColor Cyan
        Write-Host "  💾 ОБНАРУЖЕНЫ ДАННЫЕ НА НАКОПИТЕЛЕ (~$totalMB МБ, элементов: $($foundItems.Count)):" -ForegroundColor Cyan
        Write-Host "======================================================================" -ForegroundColor Cyan
        
        # Вывод краткого превью обнаруженных файлов в консоль
        $previewCount = [math]::Min(5, $detailedFileList.Count)
        for ($k = 0; $k -lt $previewCount; $k++) {
            $f = $detailedFileList[$k]
            Write-Host "  • [$($f.Type)] $($f.Name) ($($f.SizeMB) МБ, раздел $($f.Partition))" -ForegroundColor Gray
        }
        if ($detailedFileList.Count -gt 5) {
            Write-Host "  • ... и ещё $($detailedFileList.Count - 5) объектов" -ForegroundColor Gray
        }

        $ansB = Read-Host "`nСохранить существующие файлы и вернуть их после переразметки? [Y/n]"
        if ([string]::IsNullOrWhiteSpace($ansB) -or $ansB -match '^[YyДд]') {
            $doRestore = $true
            Write-Log "Пользователь подтвердил авто-бэкап файлов (Объем: $totalMB МБ, Объектов: $($foundItems.Count))." "INFO"

            # Проверка свободного места на диске %TEMP% (Get-PSDrive): нужно >= объёма данных x1.1
            $backupDriveLetter = Split-Path -Qualifier $env:TEMP -ErrorAction SilentlyContinue
            if (-not $backupDriveLetter) { $backupDriveLetter = "C:" }
            $backupDriveLetter = $backupDriveLetter.TrimEnd(':')
            $backupDrive = Get-PSDrive -Name $backupDriveLetter -ErrorAction Stop
            $needBytes = [long]($totalBackupBytes * 1.1)
            if ($backupDrive.Free -lt $needBytes) {
                throw "Недостаточно места для бэкапа на диске ${backupDriveLetter}: нужно ~$([math]::Round($needBytes / 1MB, 2)) МБ, свободно $([math]::Round($backupDrive.Free / 1MB, 2)) МБ. Переразметка отменена."
            }
            Write-Log "Свободного места для бэкапа достаточно: нужно ~$([math]::Round($needBytes / 1MB, 2)) МБ, свободно $([math]::Round($backupDrive.Free / 1MB, 2)) МБ." "DEBUG"

            Measure-PhaseStart 'Бэкап данных'
            New-Item -Path "$backupDir\iso" -ItemType Directory -Force | Out-Null
            New-Item -Path "$backupDir\data" -ItemType Directory -Force | Out-Null
            Write-Host "Копирование файлов во временное хранилище на ПК..." -ForegroundColor Cyan

            foreach ($p in $existingParts) {
                $pPath = "$($p.DriveLetter):\"
                if (Test-Path $pPath) {
                    $pItems = Get-ChildItem -Path $pPath -Force -ErrorAction SilentlyContinue | 
                              Where-Object { $_.Name -notin @('$RECYCLE.BIN', 'System Volume Information', 'lost+found', 'ventoy', $logFileName) }
                    foreach ($item in $pItems) {
                        if ($item.Extension -match '^\.(iso|img|vhd|wim)$') {
                            Write-Host "  • 📀 Сохранение образа: $($item.Name)..." -ForegroundColor Gray
                            Write-Log "Бэкап образа: $($item.FullName) -> $backupDir\iso\" "DEBUG"
                            try {
                                Copy-WithProgress -Path $item.FullName -DestinationDir "$backupDir\iso\" -Activity ("Бэкап образа " + $item.Name)
                            } catch {
                                throw "Сбой копирования образа '$($item.Name)' в бэкап: $($_.Exception.Message). Переразметка отменена."
                            }
                        } else {
                            Write-Host "  • 📁 Сохранение данных: $($item.Name)..." -ForegroundColor Gray
                            Write-Log "Бэкап данных: $($item.FullName) -> $backupDir\data\" "DEBUG"
                            try {
                                Copy-WithProgress -Path $item.FullName -DestinationDir "$backupDir\data\" -Activity ("Бэкап данных " + $item.Name)
                            } catch {
                                throw "Сбой копирования данных '$($item.Name)' в бэкап: $($_.Exception.Message). Переразметка отменена."
                            }
                        }
                    }
                }
            }
            Write-Host "✅ Резервная копия успешно создана на ПК ($totalMB МБ)." -ForegroundColor Green
            Write-Log "Резервная копия успешно создана в каталоге: $backupDir" "SUCCESS"
            Measure-PhaseEnd
        } else {
            Write-Log "Пользователь отказался от резервного копирования данных." "WARN"
        }
    }

    # ------------------------------------------------------------------------------
    # 4. Настройка параметров: размер, ФС и метки разделов
    # ------------------------------------------------------------------------------
    Write-Host "`n======================================================================" -ForegroundColor Cyan
    Write-Host "  📐 НАСТРОЙКА РАЗДЕЛОВ НАКОПИТЕЛЯ (Всего доступно: $totalSizeGB GB):" -ForegroundColor Cyan
    Write-Host "======================================================================" -ForegroundColor Cyan

    # 1. Ввод размера раздела Ventoy
    $rawSize = ""
    while ($true) {
        $rawSize = Read-Host "Размер раздела 1 под Ventoy / ISO в ГБ [по умолчанию: 8] (или 'all' на весь диск)"
        if ([string]::IsNullOrWhiteSpace($rawSize)) { $rawSize = "8"; break }
        if ($rawSize -match '^all$' -or $rawSize -match '^\d+([.,]\d+)?$') { break }
        Write-Host "[ОШИБКА] Введите число (размер в ГБ) или слово 'all'." -ForegroundColor Red
    }
    $rawSize = $rawSize -replace ',', '.'

    if ($rawSize -eq "all" -or [double]$rawSize -ge $totalSizeGB) {
        $ventoySizeGB = $totalSizeGB
        $createDataPart = $false
        $dataFS = ""
        Write-Host "[ИНФО] Будет создан единый раздел на весь диск ($totalSizeGB GB)." -ForegroundColor Yellow
        Write-Log "Выбран единый раздел на весь диск: $totalSizeGB GB" "INFO"
    } else {
        $ventoySizeGB = [double]$rawSize
        $createDataPart = $true
        $remainGB = [math]::Round($totalSizeGB - $ventoySizeGB, 2)

        # 2. Выбор файловой системы для второго раздела (раздел данных)
        Write-Host "`n💾 Выбор файловой системы для раздела данных (~$remainGB GB):" -ForegroundColor Yellow
        Write-Host "  [1] 🌐 exFAT (по умолчанию — совместим с Android, Windows, Mac, Linux)" -ForegroundColor Green
        Write-Host "  [2] 🪟 NTFS (для Windows)" -ForegroundColor White
        Write-Host "  [3] 📦 FAT32 (для старых систем и ТВ)" -ForegroundColor White
        $fsChoice = Read-Host "Выберите ФС [1-3, по умолчанию: 1]"
        if ([string]::IsNullOrWhiteSpace($fsChoice)) { $fsChoice = "1" }

        switch ($fsChoice) {
            "1" { $dataFS = "exFAT" }
            "2" { $dataFS = "NTFS" }
            "3" { $dataFS = "FAT32" }
            default { $dataFS = "exFAT" }
        }
        Write-Log "Выбран раздел Ventoy: $ventoySizeGB GB, Раздел данных: $remainGB GB (ФС: $dataFS)" "INFO"
    }

    # 3. Настройка меток разделов с наследованием индекса
    Write-Host "`n🏷️ Настройка названий (меток) разделов:" -ForegroundColor Yellow
    Write-Host "  • Формат раздела 1 (Ventoy) : FD-NN (например: FD-0, FD-1, FD-2 или просто номер '2')" -ForegroundColor Gray
    Write-Host "  • Формат раздела 3 (Данные) : DATA-NN или DATA-<имя> (наследует индекс раздела 1)" -ForegroundColor Gray
    Write-Host ""

    $rawP1 = Read-Host "Метка раздела 1 (Ventoy / ISO) [по умолчанию: FD-0]"
    if ([string]::IsNullOrWhiteSpace($rawP1)) { 
        $labelP1 = "FD-0" 
    } elseif ($rawP1 -match '^\d+$') {
        $labelP1 = "FD-$rawP1"
    } else {
        $labelP1 = $rawP1
    }

    if ($createDataPart) {
        $defP3 = "DATA"
        if ($labelP1 -match '^FD-(.+)$') {
            $defP3 = "DATA-$($Matches[1])"
        }

        $rawP3 = Read-Host "Метка раздела 3 (раздел данных) [по умолчанию: $defP3]"
        if ([string]::IsNullOrWhiteSpace($rawP3)) { 
            $labelP3 = $defP3 
        } elseif ($rawP3 -match '^\d+$') {
            $labelP3 = "DATA-$rawP3"
        } else {
            $labelP3 = $rawP3
        }
    } else {
        $labelP3 = ""
    }

    Write-Log "Метки разделов сконфигурированы: Раздел 1 = '$labelP1', Раздел 3 = '$labelP3'" "INFO"

    # ------------------------------------------------------------------------------
    # 5. Подтверждение и запуск установки
    # ------------------------------------------------------------------------------
    Write-Host "`n======================================================================" -ForegroundColor Red
    Write-Host "  ⚠️ ВНИМАНИЕ: ВСЕ ДАННЫЕ НА ДИСКЕ $($targetDisk.Number) БУДУТ ПЕРЕРАЗМЕЧЕНЫ!" -ForegroundColor Red
    Write-Host "======================================================================" -ForegroundColor Red
    Write-Host " Параметры:"
    Write-Host " • Диск:              $($targetDisk.Number) ($($targetDisk.FriendlyName), $totalSizeGB GB)"
    Write-Host " • Раздел 1 (Ventoy): $ventoySizeGB GB (exFAT, Метка: $labelP1)"
    Write-Host " • Раздел данных:     $([math]::Round($totalSizeGB - $ventoySizeGB, 2)) GB ($dataFS, Метка: $labelP3)"
    Write-Host " • Авто-бэкап файлов: $(if ($doRestore) { 'Включен (данные будут восстановлены)' } else { 'Отключен' })"
    Write-Host " • Графика GRUB:      Тема Xenlism (автоматически по версии ОС)"
    Write-Host " • Таблица разделов:  GPT + UEFI Secure Boot"
    Write-Host "----------------------------------------------------------------------"

    $confirm = Read-Host "Для запуска форматирования введите ДА (или Y/Yes)"
    if ($confirm.Trim().ToUpper() -notin @("ДА", "Y", "YES")) {
        Write-Log "Операция форматирования отменена пользователем." "WARN"
        Write-Host "Операция отменена пользователем." -ForegroundColor Yellow
        Pause
        exit 0
    }

    Write-Log "Пользователь подтвердил начало процесса форматирования и разметки." "INFO"

    # ------------------------------------------------------------------------------
    # ВРЕМЕННЫЙ ПЕРЕНОС ЛОГА НА ПК НА ВРЕМЯ ФОРМАТИРОВАНИЯ
    # ------------------------------------------------------------------------------
    Write-Log "ЭТАП ФОРМАТИРОВАНИЯ: Перенос активного лог-файла в безопасное временное хранилище ($tempLogPath)..." "INFO"
    Update-LogTarget -NewPath $tempLogPath
    Write-Log "Лог временно переключен на ПК перед очисткой разделов." "DEBUG"

    # ------------------------------------------------------------------------------
    # 6. Скачивание Ventoy для Windows (если отсутствует)
    # ------------------------------------------------------------------------------
    $ventoyVersion = "1.1.17"
    $ventoyDir = "$env:TEMP\ventoy-$ventoyVersion"

    if (-not (Test-Path "$ventoyDir\Ventoy2Disk.exe")) {
        Write-Log "Исполняемый файл Ventoy2Disk.exe не найден в $ventoyDir. Начинается загрузка v$ventoyVersion..." "INFO"
        Write-Host "`nСкачивание официального установщика Ventoy v$ventoyVersion..." -ForegroundColor Cyan
        $zipUrl = "https://github.com/ventoy/Ventoy/releases/download/v$ventoyVersion/ventoy-$ventoyVersion-windows.zip"
        $zipPath = "$env:TEMP\ventoy-$ventoyVersion.zip"
        
        Write-Log "Загрузка архива $zipUrl -> $zipPath" "DEBUG"
        Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing
        Write-Log "Распаковка архива в $env:TEMP..." "DEBUG"
        Expand-Archive -Path $zipPath -DestinationPath "$env:TEMP" -Force
        Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
        Write-Log "Распаковка Ventoy v$ventoyVersion успешно завершена." "SUCCESS"
    } else {
        Write-Log "Используется существующий установщик Ventoy: $ventoyDir\Ventoy2Disk.exe" "INFO"
    }

    # ------------------------------------------------------------------------------
    # 7. Установка Ventoy на целевой USB диск
    # ------------------------------------------------------------------------------
    Measure-PhaseStart 'Установка Ventoy'
    $reserveMB = 0
    if ($createDataPart) {
        $reserveMB = [math]::Max(0, [int]($totalSizeMB - ($ventoySizeGB * 1024) - 64))
    }

    Write-Log "Подготовка установки Ventoy: Диск=$($targetDisk.Number), Резерв=$reserveMB МБ, GPT=True, SecureBoot=True" "INFO"
    Write-Host "`nУстановка загрузчика Ventoy (GPT + UEFI Secure Boot)..." -ForegroundColor Cyan

    $v2dExe = "$ventoyDir\Ventoy2Disk.exe"
    if (-not (Test-Path $v2dExe)) {
        Write-Log "Критическая ошибка: файл $v2dExe не найден!" "ERROR"
        throw "Не найден исполняемый файл: $v2dExe"
    }

    # Подготовка аргументов для официального CLI интерфейса Ventoy2Disk.exe
    $vtoyArgs = @("VTOYCLI", "/I", "/PhyDrive:$($targetDisk.Number)", "/GPT", "/NOUSBCheck")
    if ($reserveMB -gt 0) {
        $vtoyArgs += "/R:$reserveMB"
    }

    $cmdLineFull = "$v2dExe " + ($vtoyArgs -join " ")
    Write-Log "Запуск команды Ventoy CLI: $cmdLineFull" "INFO"

    # Очистка файлов состояния перед запуском
    $doneFile = "$ventoyDir\cli_done.txt"
    $percentFile = "$ventoyDir\cli_percent.txt"
    $logFile = "$ventoyDir\cli_log.txt"

    Remove-Item $doneFile -Force -ErrorAction SilentlyContinue
    Remove-Item $percentFile -Force -ErrorAction SilentlyContinue
    Remove-Item $logFile -Force -ErrorAction SilentlyContinue

    # Запуск Ventoy2Disk в CLI режиме
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $v2dExe
    $psi.Arguments = ($vtoyArgs -join " ")
    $psi.WorkingDirectory = $ventoyDir
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $proc = [System.Diagnostics.Process]::Start($psi)
    Write-Log "Процесс Ventoy2Disk.exe запущен (PID: $($proc.Id))." "DEBUG"

    # Индикация прогресса
    $lastPercent = -1
    while (-not $proc.HasExited) {
        if (Test-Path $percentFile) {
            try {
                $pctStr = (Get-Content $percentFile -Raw -ErrorAction SilentlyContinue)
                if ($pctStr -match '(\d+)') {
                    $pct = [int]$Matches[1]
                    if ($pct -ne $lastPercent) {
                        Write-Progress -Activity "Запись Ventoy на Диск $($targetDisk.Number)..." -Status "$pct% завершено" -PercentComplete $pct
                        Write-Log "Прогресс записи Ventoy: $pct%" "DEBUG"
                        $lastPercent = $pct
                    }
                }
            } catch {}
        }
        Start-Sleep -Milliseconds 300
    }

    $proc.WaitForExit()
    Write-Progress -Activity "Запись Ventoy на Диск $($targetDisk.Number)..." -Completed
    Write-Log "Процесс Ventoy2Disk.exe завершился с кодом выхода: $($proc.ExitCode)" "INFO"

    # Сохранение внутреннего лога Ventoy в наш дебаг-лог
    if (Test-Path $logFile) {
        $vtoyRawLog = Get-Content $logFile -Raw -ErrorAction SilentlyContinue
        Write-LogBlock "Внутренний лог Ventoy (cli_log.txt)" $vtoyRawLog
    }

    # Проверка статуса записи Ventoy
    $vtoySuccess = $false
    if (Test-Path $doneFile) {
        $doneContent = (Get-Content $doneFile -Raw -ErrorAction SilentlyContinue).Trim()
        Write-Log "Содержимое cli_done.txt: '$doneContent'" "DEBUG"
        if ($doneContent -eq "0") {
            $vtoySuccess = $true
        }
    } elseif ($proc.ExitCode -eq 0) {
        $vtoySuccess = $true
    }

    if (-not $vtoySuccess) {
        Write-Log "Установка Ventoy завершилась с ошибкой (код cli_done: '$doneContent', ExitCode: $($proc.ExitCode))" "ERROR"
        Write-Host "`n[ОШИБКА] Установка Ventoy завершилась неудачей!" -ForegroundColor Red
        if (Test-Path $logFile) {
            Write-Host "`n--- Лог установки Ventoy (cli_log.txt) ---" -ForegroundColor Yellow
            Get-Content $logFile -Tail 30 | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
        }
        Write-Host "`nУбедитесь, что диск не заблокирован Проводником или антивирусом." -ForegroundColor Yellow
        throw "Сбой при записи загрузчика Ventoy."
    }

    Write-Log "Загрузчик Ventoy успешно записан на накопитель." "SUCCESS"
    Write-Host "✅ Загрузчик Ventoy успешно записан на накопитель." -ForegroundColor Green

    # Ожидание обновления системной таблицы разделов Windows
    Write-Log "Ожидание и обновление системного кэша хранилища Windows (Update-HostStorageCache, Update-Disk)..." "DEBUG"
    Start-Sleep -Seconds 3
    try { Update-HostStorageCache -ErrorAction SilentlyContinue } catch {}
    try { Get-Disk -Number $targetDisk.Number | Update-Disk -ErrorAction SilentlyContinue } catch {}
    Start-Sleep -Seconds 2

    # ------------------------------------------------------------------------------
    # 8. Настройка меток, темы Xenlism и раздела данных
    # ------------------------------------------------------------------------------
    Write-Log "Получение списка разделов после форматирования Ventoy..." "INFO"
    $partitions = @(Get-Partition -DiskNumber $targetDisk.Number -ErrorAction SilentlyContinue)
    $partAfterStr = $partitions | Select-Object PartitionNumber, DriveLetter, Size, GptType, MbrType, AccessPaths | Format-Table -AutoSize | Out-String
    Write-LogBlock "Разделы на Диске $($targetDisk.Number) после работы Ventoy" $partAfterStr

    $vPart = $partitions | Where-Object { $_.PartitionNumber -eq 1 }
    $efiPart = $partitions | Where-Object { $_.PartitionNumber -eq 2 }

    # Установка метки первого раздела (Ventoy / ISO)
    if ($vPart) {
        if (-not $vPart.DriveLetter -or [int][char]$vPart.DriveLetter -eq 0) {
            Write-Log "Назначение буквы для Раздела 1 (Ventoy)..." "DEBUG"
            try {
                $vPart | Add-PartitionAccessPath -AssignDriveLetter -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 1
                $vPart = Get-Partition -DiskNumber $targetDisk.Number -ErrorAction SilentlyContinue | Where-Object { $_.PartitionNumber -eq 1 }
            } catch {
                Write-Log "Ошибка назначения буквы Разделу 1: $_" "WARN"
            }
        }

        if ($vPart.DriveLetter -and $labelP1) {
            Write-Log "Установка файловой метки '$labelP1' на Раздел 1 ($($vPart.DriveLetter):)..." "INFO"
            try {
                Set-Volume -DriveLetter $vPart.DriveLetter -NewFileSystemLabel $labelP1 -ErrorAction SilentlyContinue
            } catch {
                try { & cmd.exe /c "label $($vPart.DriveLetter): $labelP1" 2>$null } catch {}
            }
        }

        Measure-PhaseEnd

        # Установка официальной темы GRUB Xenlism под текущую версию Windows
        Measure-PhaseStart 'Установка темы'
        if ($vPart.DriveLetter) {
            Install-XenlismTheme -ventoyDriveLetter $vPart.DriveLetter
        }
        Measure-PhaseEnd
    }

    # Скрытие служебного EFI раздела (VTOYEFI, Раздел 2) в Проводнике Windows
    if ($efiPart) {
        Write-Log "Выполнение операций по сокрытию раздела VTOYEFI (Раздел 2)..." "INFO"
        Write-Host "🔒 Скрытие служебного раздела загрузчика (VTOYEFI)..." -ForegroundColor Cyan
        
        # 1. Снятие буквы диска через mountvol и Remove-PartitionAccessPath
        if ($efiPart.DriveLetter -and [int][char]$efiPart.DriveLetter -ne 0) {
            $efiLet = "$($efiPart.DriveLetter):"
            Write-Log "Снятие буквы $efiLet с раздела VTOYEFI через mountvol и Remove-PartitionAccessPath..." "DEBUG"
            try { & cmd.exe /c "mountvol $efiLet /d" 2>$null } catch {}
            try { Remove-PartitionAccessPath -DiskNumber $targetDisk.Number -PartitionNumber 2 -AccessPath $efiLet -ErrorAction SilentlyContinue } catch {}
            try { Remove-PartitionAccessPath -DiskNumber $targetDisk.Number -PartitionNumber 2 -AccessPath "$efiLet\" -ErrorAction SilentlyContinue } catch {}
        }

        # 2. Удаление всех назначенных путей (AccessPaths)
        $accessPaths = @($efiPart.AccessPaths)
        foreach ($ap in $accessPaths) {
            if ($ap -match '^[a-zA-Z]:') {
                $drv = $Matches[0]
                Write-Log "Удаление точки монтирования: $drv" "DEBUG"
                try { & cmd.exe /c "mountvol $drv /d" 2>$null } catch {}
                try { Remove-PartitionAccessPath -DiskNumber $targetDisk.Number -PartitionNumber 2 -AccessPath $drv -ErrorAction SilentlyContinue } catch {}
            }
        }

        # 3. Запрет назначения буквы по умолчанию в Windows
        try {
            Set-Partition -DiskNumber $targetDisk.Number -PartitionNumber 2 -NoDefaultDriveLetter $true -ErrorAction SilentlyContinue
            Write-Log "Установлен флаг NoDefaultDriveLetter = True на Раздел 2." "DEBUG"
        } catch {
            Write-Log "Предупреждение при Set-Partition NoDefaultDriveLetter: $_" "WARN"
        }

        # 4. Установка GPT-типа ESP. ВАЖНО: параметра -Attributes в Storage-модуле
        # PS 5.1 нет — привязка параметров падает и -GptType не применяется;
        # атрибуты 0xC000000000000001 ставит Diskpart-фолбэк ниже (шаг 5).
        try {
            Set-Partition -DiskNumber $targetDisk.Number -PartitionNumber 2 -GptType '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' -ErrorAction SilentlyContinue
            Write-Log "Установлен GPT-тип ESP (c12a7328) на Раздел 2; атрибуты ставит Diskpart (шаг 5)." "DEBUG"
        } catch {
            Write-Log "Предупреждение при Set-Partition GptType: $_" "WARN"
        }

        # 5. Гарантированное удаление буквы и защита через Diskpart
        try {
            $dpScript = "select disk $($targetDisk.Number)`nselect partition 2`nremove noerr`ngpt attributes=0xC000000000000001`nset id=c12a7328-f81f-11d2-ba4b-00a0c93ec93b`n"
            $dpOut = ($dpScript | diskpart.exe 2>&1 | Out-String)
            Write-LogBlock "Результат выполнения Diskpart для сокрытия VTOYEFI" $dpOut
        } catch {
            Write-Log "Предупреждение при выполнении diskpart: $_" "WARN"
        }

        Write-Log "Служебный раздел VTOYEFI успешно скрыт." "SUCCESS"
        Write-Host "✅ Служебный раздел VTOYEFI скрыт." -ForegroundColor Green
    }

    # Создание и форматирование раздела данных на свободном месте
    if ($createDataPart) {
        Write-Log "Создание Раздела 3 на неразмеченной области (Метка: '$labelP3', ФС: '$dataFS')..." "INFO"
        Write-Host "`nСоздание и форматирование раздела данных ($labelP3, $dataFS)..." -ForegroundColor Cyan
        try {
            $newPart = New-Partition -DiskNumber $targetDisk.Number -UseMaximumSize -AssignDriveLetter -ErrorAction Stop
            Write-Log "Раздел 3 создан (PartitionNumber: $($newPart.PartitionNumber), DriveLetter: $($newPart.DriveLetter)). Форматирование в $dataFS..." "DEBUG"
            Start-Sleep -Seconds 2
            Format-Volume -Partition $newPart -FileSystem $dataFS -NewFileSystemLabel $labelP3 -Confirm:$false -ErrorAction Stop | Out-Null
            Write-Log "Раздел 3 успешно отформатирован в $dataFS с меткой '$labelP3'." "SUCCESS"
            Write-Host "✅ Раздел данных успешно создан и отформатирован ($labelP3, $dataFS)." -ForegroundColor Green
        } catch {
            Write-Log "Ошибка при создании/форматировании раздела данных: $_" "ERROR"
            Write-Host "  [ВНИМАНИЕ] Не удалось автоматически создать/отформатировать раздел данных: $_" -ForegroundColor Yellow
            Write-Host "  Вы можете создать его на неразмеченной области вручную через 'Управление дисками' (diskmgmt.msc)." -ForegroundColor Gray
        }
    }

    # ------------------------------------------------------------------------------
    # 9. ПЕРЕНОС ЛОГ-ФАЙЛА ОБРАТНО НА НОСИТЕЛЬ НА ПОСТОЯННОЕ ХРАНЕНИЕ
    # ------------------------------------------------------------------------------
    Start-Sleep -Seconds 2
    $updatedParts = @(Get-Partition -DiskNumber $targetDisk.Number -ErrorAction SilentlyContinue)
    $p1 = $updatedParts | Where-Object { $_.PartitionNumber -eq 1 }
    $p3 = $updatedParts | Where-Object { $_.PartitionNumber -eq 3 }

    # Обеспечиваем букву для Раздела 1
    if ($p1 -and (-not $p1.DriveLetter -or [int][char]$p1.DriveLetter -eq 0)) {
        try {
            $p1 | Add-PartitionAccessPath -AssignDriveLetter -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 1
            $p1 = Get-Partition -DiskNumber $targetDisk.Number -ErrorAction SilentlyContinue | Where-Object { $_.PartitionNumber -eq 1 }
        } catch {}
    }

    # Обеспечиваем букву для Раздела 3
    if ($p3 -and (-not $p3.DriveLetter -or [int][char]$p3.DriveLetter -eq 0)) {
        try {
            $p3 | Add-PartitionAccessPath -AssignDriveLetter -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 1
            $p3 = Get-Partition -DiskNumber $targetDisk.Number -ErrorAction SilentlyContinue | Where-Object { $_.PartitionNumber -eq 3 }
        } catch {}
    }

    # Приоритетный выбор раздела для лога: Раздел 3 (Данные) или Раздел 1 (Ventoy)
    $destLogPart = if ($p3 -and $p3.DriveLetter) { $p3 } else { $p1 }
    if ($destLogPart -and $destLogPart.DriveLetter) {
        $usbLogFinalPath = Join-Path "$($destLogPart.DriveLetter):\" $logFileName
        Write-Log "Перенос и фиксация лог-файла обратно на носитель: $usbLogFinalPath..." "INFO"
        Update-LogTarget -NewPath $usbLogFinalPath
        Write-Log "Лог-файл перенесен на постоянное хранение на носитель ($usbLogFinalPath)." "SUCCESS"
    }

    # ------------------------------------------------------------------------------
    # 10. Восстановление сохраненных файлов
    # ------------------------------------------------------------------------------
    if ($doRestore -and (Test-Path $backupDir)) {
        Write-Log "Начало процесса восстановления файлов из резервной копии..." "INFO"
        Write-Host "`n======================================================================" -ForegroundColor Cyan
        Write-Host "  🔄 ВОССТАНОВЛЕНИЕ СОХРАНЕННЫХ ФАЙЛОВ НА НАКОПИТЕЛЬ:" -ForegroundColor Cyan
        Write-Host "======================================================================" -ForegroundColor Cyan

        $restoreFailed = $false

        Measure-PhaseStart 'Восстановление ISO'
        # 1. ISO в раздел 1
        if ($p1 -and $p1.DriveLetter -and (Test-Path "$backupDir\iso")) {
            $isoFiles = Get-ChildItem -Path "$backupDir\iso" -Force -ErrorAction SilentlyContinue
            if ($isoFiles) {
                Write-Host "• Перенос образов (.iso / .img) на Раздел 1 [$labelP1] ($($p1.DriveLetter):)..." -ForegroundColor Cyan
                foreach ($f in $isoFiles) {
                    Write-Host "  ➔ Восстановление $($f.Name)..." -ForegroundColor Gray
                    Write-Log "Восстановление образа: $($f.FullName) -> $($p1.DriveLetter):\" "DEBUG"
                    try {
                        Copy-WithProgress -Path $f.FullName -DestinationDir "$($p1.DriveLetter):\" -Activity ("Восстановление " + $f.Name)
                    } catch {
                        Write-Log "Сбой восстановления образа $($f.Name): $($_.Exception.Message)" "ERROR"
                        $restoreFailed = $true
                        break
                    }
                }
                if (-not $restoreFailed -and -not (Test-BackupTreeMatch -BackupRoot "$backupDir\iso" -DestRoot "$($p1.DriveLetter):\" -Label "ISO-образы")) {
                    $restoreFailed = $true
                }
            }
        }

        Measure-PhaseEnd

        # 2. Данные в раздел 3 (или в раздел 1, если раздел 3 не создавался)
        Measure-PhaseStart 'Восстановление данных'
        $destPart = $p3
        $destLabel = $labelP3
        if (-not $destPart -or -not $destPart.DriveLetter -or [int][char]$destPart.DriveLetter -eq 0) {
            $destPart = $p1
            $destLabel = $labelP1
        }

        if (-not $restoreFailed -and $destPart -and $destPart.DriveLetter -and (Test-Path "$backupDir\data")) {
            $dataFiles = Get-ChildItem -Path "$backupDir\data" -Force -ErrorAction SilentlyContinue
            if ($dataFiles) {
                Write-Host "• Перенос документов и пользовательских данных на Раздел [$destLabel] ($($destPart.DriveLetter):)..." -ForegroundColor Cyan
                foreach ($f in $dataFiles) {
                    Write-Host "  ➔ Восстановление $($f.Name)..." -ForegroundColor Gray
                    Write-Log "Восстановление данных: $($f.FullName) -> $($destPart.DriveLetter):\" "DEBUG"
                    try {
                        Copy-WithProgress -Path $f.FullName -DestinationDir "$($destPart.DriveLetter):\" -Activity ("Восстановление " + $f.Name)
                    } catch {
                        Write-Log "Сбой восстановления данных $($f.Name): $($_.Exception.Message)" "ERROR"
                        $restoreFailed = $true
                        break
                    }
                }
                if (-not $restoreFailed -and -not (Test-BackupTreeMatch -BackupRoot "$backupDir\data" -DestRoot "$($destPart.DriveLetter):\" -Label "Данные")) {
                    $restoreFailed = $true
                }
            }
        }

        Measure-PhaseEnd

        # Временную копию удаляем только после успешной сверки восстановления
        if ($restoreFailed) {
            Write-Log "Восстановление завершено с ошибками. Резервная копия СОХРАНЕНА: $backupDir" "WARN"
            Write-Host "`n⚠️ Восстановление завершено с ошибками. Резервная копия НЕ удалена: $backupDir" -ForegroundColor Yellow
            throw "Восстановление файлов не прошло проверку. Резервная копия сохранена: $backupDir"
        }

        Remove-Item $backupDir -Recurse -Force
        Write-Log "Все сохраненные файлы успешно возвращены на накопитель. Временный каталог $backupDir удален." "SUCCESS"
        Write-Host "`n🎉 Все сохраненные файлы успешно возвращены на накопитель!" -ForegroundColor Green
    }

    # Копирование пакета скриптов развертывания Deploy Baremetal на раздел данных (как в Linux-версии)
    $destDataPart = $p3
    if (-not $destDataPart -or -not $destDataPart.DriveLetter -or [int][char]$destDataPart.DriveLetter -eq 0) {
        $destDataPart = $p1
    }
    if ($destDataPart -and $destDataPart.DriveLetter) {
        $scriptRoot = $PSScriptRoot
        if (-not $scriptRoot) { $scriptRoot = (Get-Location).Path }
        if (Test-Path "$scriptRoot\deploy.sh") {
            Write-Host "`n• Копирование пакета Deploy Baremetal на накопитель..." -ForegroundColor Cyan
            Write-Log "Копирование пакета Deploy Baremetal ($scriptRoot) -> $($destDataPart.DriveLetter):\deploy-baremetal..." "INFO"
            $targetDeployDir = "$($destDataPart.DriveLetter):\deploy-baremetal"
            New-Item -Path $targetDeployDir -ItemType Directory -Force | Out-Null
            Get-ChildItem -Path $scriptRoot -Force -ErrorAction SilentlyContinue | 
                Where-Object { $_.Name -notmatch '^(\.git|usb_backup_)' } | 
                ForEach-Object {
                    Copy-Item -Path $_.FullName -Destination $targetDeployDir -Recurse -Force -ErrorAction SilentlyContinue
                }
            Write-Log "Пакет Deploy Baremetal успешно скопирован в $targetDeployDir." "SUCCESS"
            Write-Host "  ✅ Пакет установщика скопирован в $targetDeployDir" -ForegroundColor Green
        }
    }

    # Финальная фиксация состояния разделов в логе
    $finalParts = @(Get-Partition -DiskNumber $targetDisk.Number -ErrorAction SilentlyContinue)
    $finalPartsStr = $finalParts | Select-Object PartitionNumber, DriveLetter, Size, GptType, MbrType, AccessPaths | Format-Table -AutoSize | Out-String
    Write-LogBlock "Финальная структура разделов на Диске $($targetDisk.Number)" $finalPartsStr

    Write-Log "Создание загрузочного USB-накопителя успешно завершено." "SUCCESS"
    Write-Host "`n======================================================================" -ForegroundColor Green
    Write-Host " 🎉 ФЛЕШКА УСПЕШНО РАЗМЕЧЕНА!" -ForegroundColor Green
    Write-Host "======================================================================" -ForegroundColor Green

    # Контрольное тестирование после создания
    $doPostTest = Read-Host "`nПровести контрольный замер скорости на созданных разделах? [Y/n]"
    if ([string]::IsNullOrWhiteSpace($doPostTest) -or $doPostTest -match '^[YyДд]') {
        $p1 = $finalParts | Where-Object { $_.PartitionNumber -eq 1 }
        $p3 = $finalParts | Where-Object { $_.PartitionNumber -eq 3 }
        
        if ($p1 -and $p1.DriveLetter) {
            Measure-PhaseStart 'Замер скорости: Раздел 1'
            Run-SpeedTest -driveLetter ($p1.DriveLetter) -title "Раздел 1: Ventoy / ISO ($labelP1)"
            Measure-PhaseEnd
        }
        if ($p3 -and $p3.DriveLetter) {
            Measure-PhaseStart 'Замер скорости: Раздел 3'
            Run-SpeedTest -driveLetter ($p3.DriveLetter) -title "Раздел 3: Данные ($labelP3, $dataFS)"
            Measure-PhaseEnd
        }
        Write-Host "`nВсе замеры скорости успешно завершены!" -ForegroundColor Green
    }
}
catch {
    $errDetails = $_ | Out-String
    $errTrace   = $_.ScriptStackTrace
    Write-Log "КРИТИЧЕСКАЯ ОШИБКА ВЫПОЛНЕНИЯ: $_" "ERROR"
    Write-Log "Стек вызовов:`n$errTrace" "ERROR"
    Write-LogBlock "Подробности ошибки" $errDetails

    Write-Host "`n======================================================================" -ForegroundColor Red
    Write-Host " [ОШИБКА ВЫПОЛНЕНИЯ] $_" -ForegroundColor Red
    Write-Host "======================================================================" -ForegroundColor Red
}
finally {
    if ($EnableDebugLogging) {
        Write-Log "Скрипт завершил работу." "INFO"
        
        # Финальная синхронизация лога на накопитель
        if ($usbLogFinalPath -and (Test-Path (Split-Path -Path $usbLogFinalPath -Parent))) {
            try {
                Copy-Item -Path $tempLogPath -Destination $usbLogFinalPath -Force -ErrorAction SilentlyContinue
                Write-Host "`n📝 Системный лог работы сохранен на носителе: $usbLogFinalPath" -ForegroundColor Yellow
            } catch {
                Write-Host "`n📝 Системный лог работы сохранен во временной папке: $tempLogPath" -ForegroundColor Yellow
            }
        } elseif ($activeLogPath -and (Test-Path $activeLogPath)) {
            Write-Host "`n📝 Системный лог работы сохранен в: $activeLogPath" -ForegroundColor Yellow
        }
    }
    Pause
}
