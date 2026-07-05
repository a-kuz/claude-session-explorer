# Session Explorer Web — дизайн

Веб-версия просмотрщика Claude Code сессий на Cloudflare Workers. Код — в `web/`
этого репозитория. Одно приложение обслуживает два режима:

- **Локальный** — пользователь перетаскивает `.jsonl`-файлы (или папку
  `~/.claude/projects`) в браузер; парсинг и просмотр целиком на клиенте,
  файлы сохраняются в IndexedDB и переживают перезагрузку страницы.
- **Шаринг** — выбранный набор сессий загружается в Workers KV, ссылка вида
  `/s/<id>` открывает тот же вьюер в read-only.

## Стек

- Один Worker: раздаёт статику (assets binding) + JSON API. `wrangler deploy`.
- Фронт: Vite + TypeScript, без фреймворка. Markdown — `marked`, санитизация —
  `DOMPurify` (расшаренный контент — чужой ввод, XSS-риск).
- Хранилище шар: Workers KV, TTL 30 дней.
- Деплой: аккаунт erpprog@gmail.com (`ff1705f31133d22866cbff27abee66e4`),
  auth через Global API Key (`CF_GLOBAL` + `CLOUDFLARE_EMAIL`).

## Парсинг (порт со Swift)

Порт логики `Loader` / `Content.swift` / `Models.swift` / `AutoTitle.swift`:

- envelope-поля записей, дискриминатор `type`; неизвестные типы игнорируются,
  битые строки пропускаются;
- `isSidechain: true` исключается из диалога и статистики;
- титул: `custom-title` → `ai-title` (последняя запись в файле побеждает) →
  детерминированный AutoTitle из первого промпта;
- `stripNoise` (command-теги, system-reminder, caveats), `isMeaningfulUserText`;
- иерархия рендера: DialogMessage → DialogTurn (склейка соседних сообщений
  одной стороны, tool-пинг-понг сворачивается в один ход Claude) →
  DialogBlock (промпт + ответы; единица скролла и outline);
- tool_use связывается с tool_result по id; инструменты рендерятся по месту
  (pieces), свёрнуты, разворачиваются по клику.

## UI

Три колонки: список сессий (заголовок, проект, дата, счётчики сообщений/ходов,
размер) → диалог (markdown, свёрнутые инструменты) → outline по промптам.
Поиск по загруженным сессиям: AND по словам, `/pattern/` — regex. Тёмная и
светлая тема (prefers-color-scheme). Выбор сессий чекбоксами → «Share».

## API шаринга

Тела сессий gzip'ятся на клиенте (CompressionStream) и хранятся отдельными
KV-ключами — обход лимита 25 МБ на значение:

- `POST /api/share` `{sessions: [{name, size…}]}` → `{id, ownerToken}`;
  манифест в `share:<id>` (complete:false, хэш owner-токена).
- `PUT /api/share/:id/:n` (тело — gzip jsonl, `X-Owner-Token`) → `share:<id>:<n>`.
- `POST /api/share/:id/complete` (`X-Owner-Token`) → complete:true.
- `GET /api/share/:id` → манифест; `GET /api/share/:id/:n` → тело
  с `Content-Encoding: gzip` (браузер распаковывает сам).
- `DELETE /api/share/:id` (`X-Owner-Token`) → удаление манифеста и частей.

`id` — 128 бит случайности (base58, unlisted); ownerToken хранится в
localStorage создателя, в KV — только его SHA-256. Все ключи с
`expirationTtl` 30 дней. Лимиты: 25 МБ на сессию (gzip), 100 МБ на шару,
с внятными сообщениями об ошибке.

## Границы

Не портируется в первой версии: triage, избранное, скоупы, hotkeys, ветвление
(BranchGraph) — диалог читается линейно в порядке файла, как делает `Loader`.
Тестов нет; проверка — руками на реальных сессиях из `~/.claude/projects` и
прогоном задеплоенного воркера в браузере.
