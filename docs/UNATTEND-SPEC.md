# 🪟 UNATTEND-SPEC — доработка autounattend.xml: пост-установочная настройка Windows и гигиена генератора

Версия: 1.0 от 2026-09-03. Источник: аудит механизма autounattend (шаблон
`templates/unattend.xml.template` + `generate_autounattend()` в `deploy.sh`)
и разбор сторонних рекомендаций ИИ (блок `FirstLogonCommands` и альтернативный
полный шаблон — «на рассмотрение»).

Общие правила (обязательны): один коммит = одна задача, формат сообщения —
`W1: first-logon telemetry+ads in unattend template`; после каждой правки —
`bash -n`, `shellcheck -S warning` (допустимы только комментированные disable)
и `make test-fast` зелёный; шаблон после правки — well-formed XML:
`xmllint --noout templates/unattend.xml.template`; задачах не затрагиваются
`.ps1`-файлы (правила BOM/CRLF из AGENTS.md здесь не требуются, но и не
нарушаются). Поведение `--dry-run` остаётся рабочим во всех режимах.

---

## 0. Контекст: как механизм устроен сейчас

Windows ставится штатным установщиком по варианту «A» (ROADMAP T2.1):
`deploy.sh --prep-disk` размечает диск (7 разделов GPT) и генерирует
`autounattend.xml`, Ventoy передаёт файл установщику при загрузке Windows ISO.

- **Шаблон** `templates/unattend.xml.template` — 6 плейсхолдеров:
  `__USERNAME__`, `__HOSTNAME__`, `__WIN_PARTITION_ID__`, `__WIN_IMAGE_INDEX__`,
  `__WIN_PASSWORD__`, `__WIN_TIMEZONE__`. Три прохода: `windowsPE`
  (локали, `DiskConfiguration` с `WillWipeDisk=false` и `ModifyPartition`
  PartitionID=3, `InstallTo`, выбор редакции по `/IMAGE/INDEX`), `specialize`
  (ComputerName, TimeZone, SkipAutoActivation + три RunSynchronous «золотых
  правила»: UTC-часы, `powercfg /h off`, запрет BitLocker), `oobeSystem`
  (скрытие OOBE, локальная учётка-админ с паролем, автологон, локали).
- **Генератор** `generate_autounattend()` (`deploy.sh:384`) — sed-подстановка;
  пароль экранируется дважды (XML-спецсимволы, затем sed-спецсимволы);
  `win_part_id=3`; TZ через `iana_to_windows_tz()` (только РФ-зоны, молчаливый
  fallback на Russian Standard Time); файл кладётся рядом с найденным Windows
  ISO, иначе — в каталог запуска с предупреждением.
- **Тесты-барьер** (не должны сломаться): M-2 (плейсхолдеры шаблона ↔
  sed-подстановки), U-D6 (экранирование паролей + `xmllint --noout` + нет
  остаточных `__X__`), I-D1 и L-T3 (PREP_DISK на заглушках и loop: XML создан,
  валиден, PartitionID=3), I-M6 (шаблон копируется на раздел данных флешки).

## 1. Решения по сторонним рекомендациям (зафиксировано, не пересматривать)

| Предложение | Вердикт | Куда |
|---|---|---|
| `FirstLogonCommands`: телеметрия `AllowTelemetry=0` | ✅ принять (с оговоркой: на Home/Pro уровень 0 трактуется как 1 — это минимум, не ноль; полный ноль только Enterprise/Education) | W1 |
| `FirstLogonCommands`: отключение рекламы Пуска (`SystemPaneSuggestionsEnabled=0`) | ✅ принять, расширить под Win10+Win11 (+`Start_IrisRecommendations`, `SilentInstalledAppsEnabled`) | W1 |
| Удаление bloatware `Get-AppxPackage \| Remove-AppxPackage` | ⚠️ принять идею, заменить реализацию: без `-AllUsers` сносится только текущему пользователю; провижиненные пакеты вернутся новым профилям. Правильно `Remove-AppxProvisionedPackage -Online` + `Get-AppxPackage -AllUsers`. Список перекураторен: `3DBuilder` в Win11 не существует — убран | W2 |
| Альтернативный полный шаблон как замена | ❌ отклонить: нет `DiskConfiguration`/`InstallTo`/`WillWipeDisk=false` (появятся запросы установщика + риск форматирования чужих разделов); нет pass `specialize` — теряются три «золотых правила» (UTC/FastStartup/BitLocker) и ComputerName/TimeZone; `HideOEMRegistrationScreen` — невалидное имя (правильно `HideOEMRegistrationScreens`, как в нашем шаблоне); хардкод пользователя вместо плейсхолдеров ломает генератор и M-2; `InputLocale` en-first хуже нашего ru-first при русском UI | — |
| `NetworkLocation=Home` | ❌ отклонено (мёртвый параметр с Win10); заодно чистим наш такой же `Work` | W7 |

## 2. Общие требования к реализации

1. **Новых плейсхолдеров не добавлять** — мета-тест M-2 не должен требовать
   правок. Все значения FirstLogonCommands — статические, по философии
   «золотых правил» (всегда включены), как DISABLE_FAST_STARTUP/DISABLE_BITLOCKER.
2. `FirstLogonCommands` добавляется **внутрь существующего** компонента
   `Microsoft-Windows-Shell-Setup` pass `oobeSystem` — сразу после `</AutoLogon>`
   и до `</component>`. Второй компонент с тем же именем в том же проходе
   невалиден — это мердж, а не добавление нового.
3. Контекст выполнения FirstLogonCommands — первый вход пользователя из
   `AutoLogon` (наш локальный админ): записи `HKCU` попадают в правильный
   hive, `HKLM`-записи выполняются с правами администратора.
4. Нумерация `<Order>` фиксирована и уникальна в пределах блока:
   W1 → 1–5, W2 → 6, W4 → 7. Между задачами не перенумеровывать.
5. В командных строках шаблона не использовать символы `<`, `>`, `&`
   (ломают XML-текст); кавычки `"` в тексте элементов допустимы.

---

## W1 (S) 🟢 FirstLogonCommands: телеметрия + реклама/рекомендации

**Проблема.** После установки Windows никто в систему повторно не заходит —
unattend единственный носитель пост-установочной автоматизации. Сейчас
телеметрия, «рекомендации» Пуска и тихая установка рекламы-приложений
остаются включёнными.

**Решение.** Добавить в `templates/unattend.xml.template` (в компонент
Shell-Setup pass `oobeSystem`, после `</AutoLogon>`) блок:

```xml
<FirstLogonCommands>
    <!-- Телеметрия: минимум для Home/Pro (уровень 0/Security доступен только Enterprise/Education) -->
    <SynchronousCommand wcm:action="add">
        <Order>1</Order>
        <CommandLine>reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection" /v AllowTelemetry /t REG_DWORD /d 0 /f</CommandLine>
        <Description>Disable Telemetry</Description>
    </SynchronousCommand>
    <SynchronousCommand wcm:action="add">
        <Order>2</Order>
        <CommandLine>reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection" /v DoNotShowFeedbackNotifications /t REG_DWORD /d 1 /f</CommandLine>
        <Description>Disable Feedback Notifications</Description>
    </SynchronousCommand>
    <!-- Реклама и «рекомендации»: Win10 (ContentDeliveryManager) + Win11 (Start_IrisRecommendations) -->
    <SynchronousCommand wcm:action="add">
        <Order>3</Order>
        <CommandLine>reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SystemPaneSuggestionsEnabled /t REG_DWORD /d 0 /f</CommandLine>
        <Description>Disable Start Suggestions (Win10)</Description>
    </SynchronousCommand>
    <SynchronousCommand wcm:action="add">
        <Order>4</Order>
        <CommandLine>reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SilentInstalledAppsEnabled /t REG_DWORD /d 0 /f</CommandLine>
        <Description>Disable Silent App Installs</Description>
    </SynchronousCommand>
    <SynchronousCommand wcm:action="add">
        <Order>5</Order>
        <CommandLine>reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v Start_IrisRecommendations /t REG_DWORD /d 0 /f</CommandLine>
        <Description>Disable Start Recommendations (Win11)</Description>
    </SynchronousCommand>
</FirstLogonCommands>
```

**Приёмка.** `xmllint --noout` шаблона и сгенерированного XML зелёные;
`make test-fast` зелёный (M-2/U-D6 без правок — регресс-барьер); добавить
мета-тест **M-3** (см. §8). На железе (вне автоматизации, §11 TEST-SPEC):
после установки в `regedit` видны все пять значений.

## W2 (M) 🟡 FirstLogonCommands: удаление bloatware (исправленная реализация)

**Проблема.** Предустановленные UWP-приложения (BingNews, Solitaire и т.п.)
ставятся каждому новому профилю. Сторонний вариант `Get-AppxPackage ... |
Remove-AppxPackage` без `-AllUsers` удаляет только текущему пользователю и
не трогает провижиненные пакеты. Плюс: на первом входе AppX-служба может быть
ещё не готова — команды обязаны молча переживать ошибки.

**Решение.** Добавить в тот же `FirstLogonCommands` (продолжение блока W1,
`AsynchronousCommand` — долгая операция, не блокирует первый вход):

```xml
    <!-- Удаление предустановленных UWP (bloatware): провижиненные пакеты + текущий профиль.
         Список консервативный; Store/Calculator/Photos/Widgets НЕ трогать. -->
    <AsynchronousCommand wcm:action="add">
        <Order>6</Order>
        <CommandLine>powershell -NoProfile -ExecutionPolicy Bypass -Command "$log='C:\Windows\Temp\deploy-debloat.log'; $pat='^(Microsoft.BingNews|Microsoft.BingWeather|Microsoft.MicrosoftSolitaireCollection|Microsoft.WindowsFeedbackHub|Microsoft.Getstarted|Microsoft.GetHelp|Microsoft.MicrosoftOfficeHub|Microsoft.549981C3F5F10)$'; Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -match $pat } | ForEach-Object { $_.DisplayName | Out-File $log -Append; Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction SilentlyContinue | Out-Null }; Get-AppxPackage -AllUsers | Where-Object { $_.Name -match $pat } | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue"</CommandLine>
        <Description>Remove Bloatware (provisioned + all users)</Description>
    </AsynchronousCommand>
```

Требования:
- список — кураторский, менять только по решению владельца проекта;
  `3DBuilder` из стороннего списка убран (в Win11 отсутствует);
- `Get-AppxProvisionedPackage -Online` (не даёт ставиться новым профилям) +
  `Get-AppxPackage -AllUsers` (чистит уже установленное);
- `-ErrorAction SilentlyContinue` на обоих удалениях — первый вход не должен
  падать из-за неготовности AppX;
- журнал удалений пишется в `C:\Windows\Temp\deploy-debloat.log`.

**Приёмка.** `xmllint --noout` шаблона зелёный (команда не содержит `<`/`>`/`&`);
`make test-fast` зелёный; автотестом проверяется только well-formed-ность и
наличие `Remove-AppxProvisionedPackage` в шаблоне (расширить M-3, см. §8);
реальное удаление — ручная проверка §11 (лог `deploy-debloat.log` существует,
приложения из списка отсутствуют у нового пользователя).

## W3 (S) 🟢 Документировать WIN_IMAGE_INDEX в deploy.conf

**Проблема.** `generate_autounattend()` читает `WIN_IMAGE_INDEX` (дефолт 1),
но переменная нигде не документирована: в мультиредакционном ISO индекс 1 —
обычно Home, и пользователь, желающий Pro, о рычаге не узнает.

**Решение.** В `deploy.conf` рядом с блоком пользователя (после `WIN_PASSWORD`)
добавить закомментированную подсказку:

```bash
# Редакция Windows в мультиредакционном ISO (индекс из `dism /Get-WimInfo`):
# 1 = Home (по умолчанию), 2 = Pro. Раскомментируйте и укажите свою:
# WIN_IMAGE_INDEX=2
```

Поведение кода не меняется (переменная и так читается через
`${WIN_IMAGE_INDEX:-1}`).

**Приёмка.** `bash -n deploy.conf` чист; строка присутствует; коммит не
трогает `deploy.sh`.

## W4 (S) 🟢 Гигиена пароля: самоочистка Panther + напоминания

**Проблема.** Пароль лежит открытым текстом в двух местах после установки:
в `autounattend.xml` на флешке и в копии `C:\Windows\Panther\unattend.xml`,
которую оставляет установщик. Напоминаний пользователю нет.

**Решение.**
1. Самоочистка Panther — добавить в `FirstLogonCommands` (после W2):

```xml
    <!-- Удаляем копию autounattend из Panther: в ней пароль в открытом виде -->
    <SynchronousCommand wcm:action="add">
        <Order>7</Order>
        <CommandLine>cmd /c del /f /q "%WINDIR%\Panther\unattend.xml"</CommandLine>
        <Description>Remove answer file with plaintext password</Description>
    </SynchronousCommand>
```

2. `deploy.sh`, `generate_autounattend()`: после `success "autounattend.xml
   создан: ..."` при непустом `WIN_PASSWORD` выводить
   `warn "autounattend.xml содержит пароль в открытом виде — удалите файл с флешки после установки Windows."`
   (одной строкой `[[ -n "$WIN_PASSWORD" ]] && warn ...`, не последней в функции).
3. `deploy.sh`, `do_prep_disk()`: в финальных подсказках после пункта 2)
   добавить пункт 3): «После установки Windows удалите autounattend.xml
   с флешки (в нём пароль в открытом виде; копия в C:\Windows\Panther
   удаляется автоматически)».
4. `README.md`, раздел «🪟 Как ставится Windows»: дополнить шаг 2 примечанием
   об удалении `autounattend.xml` с флешки после установки.

**Приёмка.** `xmllint --noout` шаблона зелёный; `bash -n`/`shellcheck` чисты;
`make test-fast` зелёный; dry-run `--prep-disk` показывает новую подсказку;
README дополнен.

## W5 (M) 🟡 XML-экранирование USERNAME и HOSTNAME

**Проблема.** Экранируется только пароль. `&` в `USERNAME`/`HOSTNAME` даст
невалидный XML — установщик молча откатится в интерактивный режим.

**Решение.** Вынести экранирование в хелперы (рядом с `iana_to_windows_tz`)
и применять ко всем трём подстановкам:

```bash
xml_escape() { printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g'; }
sed_escape() { printf '%s' "$1" | sed 's/[&/\]/\\&/g'; }
```

В `generate_autounattend()`:

```bash
local user_esc host_esc pwd_esc
user_esc=$(sed_escape "$(xml_escape "$USERNAME")")
host_esc=$(sed_escape "$(xml_escape "$HOSTNAME")")
pwd_esc=$(sed_escape  "$(xml_escape "$WIN_PASSWORD")")
```

и использовать `user_esc`/`host_esc`/`pwd_esc` в соответствующих `sed -e`
строках (поведение для прежних значений без спецсимволов — идентично).

**Приёмка.** Новый сценарий **U-D8** (см. §8): `USERNAME='a&b<c>"d'`,
`HOSTNAME='h&ost'` → XML валиден (`xmllint`), есть
`<Name>a&amp;b&lt;c&gt;&quot;d</Name>` и `<ComputerName>h&amp;ost</ComputerName>`;
существующие U-D6 (корпус паролей) и все остальные — зелёные без правок
тестов.

## W6 (S) 🟢 Предупреждение при неизвестном часовом поясе

**Проблема.** `iana_to_windows_tz()` для незнакомой зоны молча подставляет
Russian Standard Time — пользователь не узнает о подмене.

**Решение.** В ветку `*)` case добавить предупреждение в stderr (функция
продолжает возвращать только значение через stdout):

```bash
*)  warn "Неизвестный часовой пояс '$1' — используется Russian Standard Time (см. deploy.conf TIMEZONE)."
    echo "Russian Standard Time" ;;
```

`warn()` уже пишет в stderr — stdout-контракт `$(iana_to_windows_tz ...)`
не меняется.

**Приёмка.** Новый тест **U-D9** (см. §8): для `Europe/Berlin` stdout =
`Russian Standard Time` и stderr содержит «Неизвестный часовой пояс»;
для `Europe/Moscow` предупреждения нет; `make test-fast` зелёный.

## W7 (S) 🟢 (опция, можно пропустить) Чистка мёртвых элементов шаблона

**Проблема.** `NetworkLocation` игнорируется начиная с Windows 10; локальные
дубли объявления `xmlns:wcm` в `RunSynchronousCommand` (×3) и `LocalAccount`
избыточны — префикс уже объявлен в корне.

**Решение.** Удалить строку `<NetworkLocation>Work</NetworkLocation>` и
атрибуты `xmlns:wcm="..."` из четырёх перечисленных элементов. `wcm:action`
остаются валидными за счёт объявления в корне.

**Приёмка.** `xmllint --noout` шаблона зелёный; `make test-fast` зелёный.

---

## 8. Реестр тестов (изменения к TEST-SPEC)

Новые тесты регистрируются по правилам TEST-SPEC (добавить строки в таблицу
§5 документа; сам TEST-SPEC — ведущий реестр, не архив):

| ID | Уровень | Что проверяет |
|---|---|---|
| M-3 | L0 | `templates/unattend.xml.template` — well-formed (`xmllint --noout`), содержит `<FirstLogonCommands>`, `AllowTelemetry` и `Remove-AppxProvisionedPackage`. Без хрупких счётчиков Order |
| U-D8 | L3 | Сценарий `scenarios/d8-escape-user.sh` (по образцу d6): экранирование `USERNAME`/`HOSTNAME` со спецсимволами + `xmllint` + нет остаточных `__X__` |
| U-D9 | L2 | Юнит в `check-deploy.bats`: `iana_to_windows_tz Europe/Berlin` → stdout `Russian Standard Time` + stderr «Неизвестный часовой пояс»; для `Europe/Moscow` — без предупреждения |

Регресс-барьер (меняются, но правки тестов не требуют): M-2, U-D6, I-D1,
L-T3, I-M6. В `docs/TEST-SPEC.md` §11 (ручной чек-лист) дополнить пункт 2:
после реальной установки проверить reg-политики телеметрии, чистый Пуск,
`C:\Windows\Temp\deploy-debloat.log`, отсутствие `C:\Windows\Panther\unattend.xml`.

## 9. Порядок выполнения и коммиты

Строго по ID: W1 → W2 → W3 → W4 → W5 → W6 → W7 (W7 — опция). Файлы по задачам:

| Задача | Файлы |
|---|---|
| W1 | `templates/unattend.xml.template`, `tests/bats/meta.bats` (M-3), `docs/TEST-SPEC.md` (реестр) |
| W2 | `templates/unattend.xml.template`, `tests/bats/meta.bats` (M-3), `docs/TEST-SPEC.md` |
| W3 | `deploy.conf` |
| W4 | `templates/unattend.xml.template`, `deploy.sh`, `README.md`, `docs/TEST-SPEC.md` (§11) |
| W5 | `deploy.sh`, `tests/bats/check-deploy.bats`, `tests/bats/scenarios/d8-escape-user.sh` (новый) |
| W6 | `deploy.sh`, `tests/bats/check-deploy.bats` |
| W7 | `templates/unattend.xml.template` |

Коммит = задача, отмечать выполнение галочкой в этом файле (секция ниже) в том
же коммите.

## Чек-лист выполнения

- [x] W1 — FirstLogonCommands: телеметрия + реклама (orders 1–5)
- [x] W2 — bloatware через provisioned+AllUsers (order 6, лог)
- [x] W3 — WIN_IMAGE_INDEX документирован в deploy.conf
- [ ] W4 — самоочистка Panther (order 7) + напоминания в deploy.sh и README
- [ ] W5 — xml_escape/sed_escape для USERNAME/HOSTNAME + U-D8
- [ ] W6 — warn при неизвестной TZ + U-D9
- [ ] W7 — (опция) чистка NetworkLocation и дублей xmlns:wcm
