# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Что это

Нативное macOS-приложение (SwiftUI, macOS 26+, Swift 5) для навигации по сессиям
Claude Code — `~/.claude/projects/*.jsonl`. Порт TUI `session-explorer-2`. Без
сэндбокса (нужен доступ к `~/.claude` и Apple Events для интеграции с терминалом).

### Референсы по Claude Code

Формат jsonl закрытый и не специфицирован — поведение выясняется по этим
источникам (читать как референс, не вносить туда правки):

- `~/ws/Claude-code` — распакованный исходник официального CLI (`QueryEngine.ts`,
  `Tool.ts`, `cli/`, …): какие записи и поля Claude Code пишет в jsonl.
- `~/ws/openclaude` — open-source реализация ([github.com/Gitlawb/openclaude](https://github.com/Gitlawb/openclaude)),
  второй взгляд на тот же формат и протокол.

## Сборка и запуск

Проект генерируется из `project.yml` через XcodeGen — `.xcodeproj` не редактируется
вручную. После изменения списка файлов/настроек заново генерируй проект:

```sh
xcodegen generate
xcodebuild -project SessionExplorer.xcodeproj -scheme SessionExplorer -configuration Release build
# либо открыть SessionExplorer.xcodeproj в Xcode и Run (Debug)
```

Тестов в проекте нет.

## Формат сессий (jsonl)

Один файл `<session-id>.jsonl` на сессию, append-only, по записи на строку. Имя
файла = `sessionId`. Каталог `~/.claude/projects/<encoded-cwd>/` кодирует путь
проекта, заменяя `/` и `.` на `-` (lossy — реальный `cwd` берётся из самих записей,
см. `Loader.decodeProjectDirName`). Дискриминатор записи — поле `type`.

**Записи диалога** (`type: "user"` | `"assistant"`) несут общую обёртку:
`uuid` (стабильный id записи — основа идентичности сообщений), `parentUuid`
(`uuid` родительской записи в дереве реплик — см. branch ниже), `sessionId`,
`timestamp`, `cwd`, `gitBranch`, `version`, `userType`, `entrypoint`; опционально
`forkedFrom`, `isSidechain` (см. «Понятия» ниже).
Содержимое — в `message` (форма Anthropic Messages API):

- `message.content` — либо строка, либо массив блоков с `type`:
  - assistant: `text` (`{text}`), `thinking` (`{thinking, signature}`),
    `tool_use` (`{id, name, input, caller}`);
  - user: `text` (`{text}`), `image` (`{source}`), `tool_result`
    (`{tool_use_id, content}` — связывается с `tool_use` по id).
- assistant-записи также несут `requestId` и `message.model`; tool_result-записи —
  `toolUseResult`, `promptId`, `sourceToolAssistantUUID`.

**Служебные записи** (без `message`, лёгкая обёртка `{sessionId, type, …}`):
`custom-title` (`{customTitle}` — заданное пользователем имя), `ai-title`
(`{aiTitle}` — сгенерированное), `last-prompt` (`{lastPrompt, leafUuid}`),
`permission-mode` (`{permissionMode}`), `mode`, `queue-operation`,
`attachment` (`{attachment}` — вложения), `file-history-snapshot`
(`{messageId, snapshot, isSnapshotUpdate}`), `system`, `pr-link`, `slug`.

### Понятия

- **session-id** — UUID сессии. Всегда совпадает с именем файла (инвариант:
  во всех записях `sessionId` == basename без `.jsonl`), фигурирует в
  `claude --resume <id>`. Не путать с порядком в списке: сессии сортируются по
  `mtime` (время последнего промпта пользователя, `metaSchemaVersion v2`).
- **session-name** (заголовок) — приоритет `customTitle` (`type:"custom-title"`,
  задан пользователем) → `aiTitle` (`type:"ai-title"`, авто). Если нет ни того,
  ни другого — `AutoTitle` детерминированно выводит заголовок из первого промпта.
  Эти три записи перетираются: берётся ПОСЛЕДНЯЯ в файле (`Loader` так и читает).
  `titleIsCustom` отличает пользовательский заголовок от авто.
- **slug** — человекочитаемый идентификатор сессии (`humble-snuggling-beacon`),
  стабилен в пределах сессии; используется CLI для имён worktree/tmux. Это НЕ
  заголовок для UI.
  Три РАЗНЫХ механизма ветвления (легко спутать — назначение разное):

- **`/branch`** — создаёт ОТДЕЛЬНУЮ сессию-jsonl в `projects/<cwd>/` с полем
  `forkedFrom: {sessionId, messageUuid}` на первой записи: новый файл ответвлён от
  записи `messageUuid` исходной сессии `sessionId`. Полноценная самостоятельная
  сессия (свой `sessionId` = своё имя файла), `--resume`-абельная; UI показывает её
  как отдельную строку. Одна логическая беседа может быть размазана по цепочке
  файлов, связанных `forkedFrom`. Очень частый случай, не аномалия.
- **`/fork`** — НЕ отдельная сессия, а субагент. Пишется в
  `<session>/subagents/agent-<agentId>.jsonl` (+ `.meta.json` с
  `{agentType:"fork", isFork:true, description, name}`). Первая запись —
  `fork-context-ref` (`{agentId, parentSessionId, parentLastUuid, contextLength}`):
  субагент стартует с копией контекста родителя на записи `parentLastUuid`.
  Реплики идут с `isSidechain: true` и НЕСУТ `sessionId` РОДИТЕЛЯ (не свой); поля
  `forkedFrom` здесь НЕТ. То есть `/fork` — разновидность sidechain (см. ниже), а не
  новая сессия в списке.
- **дерево внутри файла** — внутри одного jsonl записи связаны в дерево через
  `parentUuid` (`uuid` родителя), и у родителя может быть несколько детей
  (rewind/редактирование промпта дописывает расходящиеся реплики в тот же файл).
  «Текущая» линия — путь от корня до активного листа; `last-prompt`
  (`{lastPrompt, leafUuid}`) указывает этот лист. Линейные сессии — частный случай
  (у каждого родителя один ребёнок). Сейчас `Loader` читает записи ЛИНЕЙНО в порядке
  файла и `parentUuid`/`leafUuid` не использует — при таком ветвлении реплики разных
  веток смешаются; если будешь чинить, реконструируй активную линию от `leafUuid`.

  Ни одно из этого не путать с `gitBranch` — это git-ветка `cwd` на момент записи,
  отдельное поле, к ветвлению сессий/диалога отношения не имеет.
- **sidechain** (`isSidechain: true`) — записи побочной ветки (диалог субагента:
  `AgentTool` или `/fork`), а не основной транскрипт. Несут `sessionId` родителя.
  Официальный CLI исключает их из основного представления и статистики
  (`!isSidechain`); делай так же.
- **system-reminder** — блок `<system-reminder>…</system-reminder>` ВНУТРИ текста
  сообщения (служебные инструкции, инжектированные харнессом — caveats, напоминания
  о malware и т.п.), а не отдельный `type`. `Content.swift` отсеивает такой шум из
  отображаемого текста; при добавлении парсинга учитывай, что это не пользователь.

Парсинг устойчив к незнакомым `type`/полям (Claude Code добавляет их со временем):
`Content.swift` извлекает текст и отсеивает служебный шум, неизвестные записи
игнорируются. Истину о формате выясняй по референсам выше и по реальным файлам в
`~/.claude/projects`, не по догадкам.

## Архитектура

Поток данных: jsonl на диске → `Loader` (парсинг) → `Store` (SwiftData-кеш) →
`AppModel` (состояние) → `Views`.

### Слой данных (`Sources/Core/`)

- **`Loader.swift`** — сканирует `~/.claude/projects`, парсит jsonl. Каждая строка
  парсится ровно один раз за жизнь кеша: неизменённые файлы пропускаются по mtime,
  изменённые читаются только с сохранённого `parsedOffset` (jsonl append-only).
  `parseSessionMeta` читает файл один раз и держит только лёгкие поля (без
  транскрипта). Полный диалог грузится лениво и кешируется в памяти (LRU);
  `loadDialogTail` дочитывает только хвост открытой сессии.
- **`Store.swift`** — персистентный кеш на SwiftData (SQLite) в
  `Application Support/SessionExplorer/cache.store`. Хранит **только метаданные**
  (`SessionRecord`). При несовместимости схемы стор удаляется и пересоздаётся.
  `AppModel.metaSchemaVersion` форсирует пересчёт устаревших строк.
- **`Content.swift`** — извлечение текста из форм `message.content`, отсев шума
  (`<command-*>`, caveats, reminders).
- **`Search.swift`** — двухуровневый отменяемый поиск: cheap (мгновенный, по
  заголовкам/последним репликам, на main actor) + deep (инкрементальный по всему
  диалогу, off-thread, дебаунс 250мс, чанки по 40). AND по словам, regex через
  `/pattern/`.
- **`AutoTitle.swift`** — ленивый детерминированный заголовок из первого запроса
  (без сети/LLM), если нет `custom-title`/`ai-title`.
- **`OpenSession.swift`** — открыть сессию в терминале (`claude --resume <id>` через
  clipboard + AppleScript с физическими key codes, работает в русской раскладке).
- **`FolderWatcher.swift`** — FSEvents-наблюдение каталога; список и открытый диалог
  обновляются realtime.

### Модель (`Sources/Models/Models.swift`)

Доменные типы и иерархия рендера диалога:
`DialogMessage` (сырое сообщение) → `DialogTurn` (смежные сообщения одной стороны
сливаются; tool-пинг-понг свёрнут) → `DialogBlock` (пользовательский промпт + его
ответы Claude). **Block — единица скролла, навигации и outline.** `ContentPiece`
(проза/тул в исходном порядке — тулы рендерятся на месте). У сообщений стабильные
id из jsonl `uuid`, чтобы при дочитывании хвоста не терялась идентичность и
SwiftUI ре-рендерил только новое.

### Состояние (`Sources/AppModel.swift`)

`@MainActor ObservableObject` — единый источник истины. Ключевые инварианты:

- **Два независимых фильтра**: `scope` (single-select: all/favorites/today/
  last24h/last2d/week) и `selectedProjectPaths` (multi-select проектов), применяются
  вместе.
- **Коалесинг обновлений списка**: фоновые записи (включая саму активную сессию) НЕ
  должны дёргать список при скролле — обновления списка дебаунсятся (~1.2с),
  применяются на idle и только если изменился `signature()` видимого состояния;
  ждут окончания скролла (`listIsScrolling`). Открытый диалог обновляется сразу и
  отдельно (append-only через `refreshOpenDialog`).
- **Triage-режим** ("Ответь всем поочерёдно") — отдельный полноэкранный режим
  (`triageMode`, не фильтр сайдбара), идёт по `attentionSessions` (нужен ответ + не
  скрыта + проходит фильтр проектов).
- **UI-стейт персистится** в UserDefaults (`persistUIState`/`restoreUIState`); ширины
  колонок коммитятся только на конце драга (`commitWidths`) — синхронная запись на
  каждый дельта-кадр давала джиттер.

### Вью (`Sources/Views/`)

`RootView` (три-четыре колонки), `SidebarView`, `SessionListView`, `DetailView`,
`MessageView` (реплики + компактные тулы), `OutlineView` (оглавление промптов),
`TriageView`, `InspectorView`, `Toolbar`, `HotkeyHelpView`. `Commands.swift` —
меню/хоткеи (`AppCommands`). `Theme.swift`, `Markdown.swift`, `Format.swift`,
`FlowLayout.swift`, `Scaling.swift` — оформление и утилиты.

## Конвенции

- **Не упрощать.** Не выкидывай инварианты, обработку краёв, дебаунсы/коалесинг,
  off-thread-логику и проверки идентичности под видом «упрощения» — каждый такой
  кусок здесь стоит за конкретной болью (джиттер списка, гонки при переключении
  сессии, ветвление/дочитывание хвоста jsonl). Меняй ровно то, что просили; если
  кажется, что код избыточен — сначала спроси.
- Терминология рендера: turn / block / piece (см. Models). Используй эти термины,
  не выдумывай свои.
- Любая операция I/O по сессиям (парсинг, deep-поиск, загрузка диалога/картинок)
  идёт off-thread через `Task.detached`; результат применяется на `MainActor` с
  проверкой, что `selectedID` всё ещё тот же.
- Транскрипт никогда не персистится в БД — только лениво из jsonl.
