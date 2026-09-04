# 📚 Документация deploy-baremetal

Все спецификации, роадмапы и промпты для исполнителей собраны здесь.
В корне репозитория остаются `README.md` (обзор проекта) и `AGENTS.md`
(правила для агентов/редакторов — ZCode ищет его только в корне).

| Документ | Назначение | Статус |
|---|---|---|
| [ROADMAP.md](ROADMAP.md) | Роадмап по итогам код-ревью 2026-09-02: блокеры, защита данных, функциональные пробелы | ✅ все 21 задач |
| [ROADMAP-SPLIT-ADAPT.md](ROADMAP-SPLIT-ADAPT.md) | Порядок исполнения SPLIT-ADAPT-SPEC: баги (parted resizepart) + адаптация к новой разметке (p8 Distr → /home на p9) | ✅ A0–A6 |
| [TEST-SPEC.md](TEST-SPEC.md) | ТЗ на систему тестов (6 уровней L0–L5, 55 автотестов) | ✅ T0–T5; T6 (Pester) — опция |
| [FIX-SPEC.md](FIX-SPEC.md) | «Хвост» после первого реального прогона на Windows (WARN, кэш-замер, тайминги, rsync-прогресс) | ✅ T1–T4 |
| [SPLIT-SPEC.md](SPLIT-SPEC.md) | Усиление split-home.sh (guard, fstab до удаления, сверка копии, предрейс места) | ✅ S0–S5 |
| [SPLIT-ADAPT-SPEC.md](SPLIT-ADAPT-SPEC.md) | Адаптация split-home.sh к новой разметке NVMe (появился p8 `Distr` 99 ГБ; /home → новый p9 ~328 ГБ) | ✅ A1–A6 |
| [UNATTEND-SPEC.md](UNATTEND-SPEC.md) | Доработка autounattend.xml: FirstLogonCommands (телеметрия/реклама/debloat), гигиена генератора и пароля | 🆕 к выполнению (W1–W7) |
| [CODER-PROMPT.md](CODER-PROMPT.md) | Промпт исполнителя по ROADMAP (исторический, задача закрыта) | архив |
| [CODER-PROMPT-TESTS.md](CODER-PROMPT-TESTS.md) | Промпт исполнителя по TEST-SPEC (исторический, задача закрыта) | архив |
| [CODER-PROMPT-UNATTEND.md](CODER-PROMPT-UNATTEND.md) | Промпт исполнителя по UNATTEND-SPEC (парный к 🆕 спеке) | 🆕 парный |
| [CODER-PROMPT-SPLIT-ADAPT.md](CODER-PROMPT-SPLIT-ADAPT.md) | Промпт исполнителя по SPLIT-ADAPT (баги + адаптация к новой разметке) | ✅ выполнен |
| [AI-REVIEW-PROMPT.md](AI-REVIEW-PROMPT.md) | Промпт внешним ИИ (Claude/GPT/Gemini): оценка архитектуры + фича «скачивание дистрибутивов» (вставлять в чат, доступ к репо не нужен) | 🆕 к рассылке |
| [AI-SUPPORT-PROMPT.md](AI-SUPPORT-PROMPT.md) | Промпт стороннему ИИ на период недоступности основного агента: аварийное сопровождение ПОСЛЕ самостоятельного прогона split-home.sh — матрица состояний диска, ремонт загрузки, доведение до конца или откат (самодостаточен, доступ к репо не нужен) | 🆕 резервный канал |

Хронология работы зафиксирована в истории git: `snapshot` → `T0.1–T4.3` (ревью)
→ `T0–T5` (тесты) → `fix/check` → `T1–T4` (FIX-SPEC) → `S0–S5` (SPLIT-SPEC)
→ A1–A6 (SPLIT-ADAPT).

Ещё вне папки: `check-files.sh` в корне (статический контроль кодировок
.ps1 — BOM/CRLF/`$var:`), подключён как git pre-commit hook вместе с
`make test-fast`.
