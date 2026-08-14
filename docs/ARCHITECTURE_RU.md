<!--
SPDX-FileCopyrightText: 2026-Present Contributors to FluffyChat

SPDX-License-Identifier: AGPL-3.0-or-later
-->

# FluffyChat: архитектура клиента и практическое изучение с Matrix Synapse

> Документ описывает состояние исходного кода в этой ветке (FluffyChat `2.8.0`, Dart `>=3.11.1`, `matrix` `^10.0.1`). При обновлении зависимостей детали API могут измениться.

## Содержание

1. [Что это за проект](#1-что-это-за-проект)
2. [Matrix и Synapse: важное различие](#2-matrix-и-synapse-важное-различие)
3. [Общая архитектура](#3-общая-архитектура)
4. [Запуск приложения](#4-запуск-приложения)
5. [State Management](#5-state-management)
6. [Routing](#6-routing)
7. [Хранение данных](#7-хранение-данных)
8. [Криптография и сквозное шифрование](#8-криптография-и-сквозное-шифрование)
9. [Сеть, синхронизация и сообщения](#9-сеть-синхронизация-и-сообщения)
10. [Структура UI и адаптивность](#10-структура-ui-и-адаптивность)
11. [Аутентификация](#11-аутентификация)
12. [Уведомления и фоновые процессы](#12-уведомления-и-фоновые-процессы)
13. [Медиа, VoIP и платформенные возможности](#13-медиа-voip-и-платформенные-возможности)
14. [Основные библиотеки](#14-основные-библиотеки)
15. [Локализация, конфигурация и темы](#15-локализация-конфигурация-и-темы)
16. [Развёртывание собственного Synapse](#16-развёртывание-собственного-synapse)
17. [Подключение FluffyChat к своему серверу](#17-подключение-fluffychat-к-своему-серверу)
18. [Отладка полного сценария](#18-отладка-полного-сценария)
19. [Тестирование и качество кода](#19-тестирование-и-качество-кода)
20. [План изучения для Junior](#20-план-изучения-для-junior)
21. [Глоссарий и источники](#21-глоссарий-и-источники)

---

## 1. Что это за проект

**FluffyChat** — свободный кроссплатформенный Matrix-клиент на Flutter. Один код используется для Android, iOS, Web, Linux, Windows и macOS. Приложение умеет работать с личными и групповыми комнатами, Spaces, файлами, реакциями, звонками, push-уведомлениями и Matrix E2EE.

Главная технологическая цепочка:

```text
Flutter widgets
    ↓
экраны и их State-контроллеры
    ↓
MatrixState (контекст приложения)
    ↓
matrix Dart SDK: Client → Room → Timeline → Event
    ↓
Matrix Client-Server API по HTTPS
    ↓
Homeserver (например, Synapse)
    ↔ federation ↔ другие Matrix homeserver
```

Репозиторий — именно **клиент**, а не сервер. Бизнес-объекты протокола (`Client`, `Room`, `Timeline`, `Event`, устройства, ключи) в основном предоставляет пакет `matrix`; код FluffyChat связывает SDK с UI и платформенными API.

Лицензия проекта — AGPL-3.0-or-later. Перед распространением изменённой версии следует прочитать `LICENSES/AGPL-3.0-or-later.txt` и требования REUSE.

## 2. Matrix и Synapse: важное различие

Фраза «протокол Matrix-Synapse» не совсем точна:

- **Matrix** — открытая спецификация: Client-Server API, Server-Server federation API, события комнат, идентификаторы и E2EE;
- **Synapse** — одна из реализаций Matrix homeserver;
- **FluffyChat** — Matrix-клиент и не должен зависеть исключительно от Synapse. Он может подключаться к совместимому homeserver другой реализации;
- клиент обычно обращается к `/_matrix/client/...`; federation между серверами работает отдельно и клиентом напрямую не реализуется.

Основные идентификаторы:

| Объект | Пример | Смысл |
|---|---|---|
| User ID (MXID) | `@alice:example.org` | пользователь и его домашний сервер |
| Room ID | `!opaqueId:example.org` | стабильный технический ID комнаты |
| Alias | `#team:example.org` | человекочитаемая ссылка на комнату |
| Event ID | `$opaqueEventId` | идентификатор события |
| MXC URI | `mxc://example.org/mediaId` | ссылка Matrix на медиа |
| Device ID | `ABCDEF` | конкретная сессия/устройство пользователя |

Сообщение — не отдельная «строка в чате», а событие `m.room.message` в графе событий комнаты. Название, участники, права и включение шифрования — тоже state events. Поэтому `Room` и `Timeline` являются центральными моделями.

## 3. Общая архитектура

### 3.1 Слои

В проекте нет жёстко оформленной Clean Architecture с `domain/data/presentation`. Фактически используются следующие слои:

| Слой | Каталоги/файлы | Ответственность |
|---|---|---|
| Entry point | `lib/main.dart` | Flutter binding, настройки, crypto runtime, клиенты, foreground/background режим |
| App composition | `lib/widgets/fluffy_chat_app.dart`, `lib/widgets/matrix.dart` | тема, router, app lock, глобальный Matrix-контекст, подписки |
| Navigation/config | `lib/config/` | маршруты, темы, runtime-настройки |
| Features/pages | `lib/pages/<feature>/` | экран, контроллер состояния, действия пользователя |
| Shared UI | `lib/widgets/` | переиспользуемые виджеты и диалоги |
| Infrastructure | `lib/utils/` | создание SDK Client, БД, HTTP, push, файлы, VoIP, platform abstraction |
| Protocol SDK | пакет `matrix` | Matrix API, sync, локальные модели, timeline, E2EE |
| Native crypto | `flutter_vodozemac` | безопасные примитивы Olm/Megolm через Vodozemac |

Это прагматичная feature-oriented архитектура: код конкретной функции находится рядом, но UI-контроллер иногда напрямую вызывает SDK. Для небольшого изменения это удобно; для Junior важно не искать обязательные repository/use-case слои — их здесь в классическом виде нет.

### 3.2 Модель страницы «controller + view»

Часто feature разделён на:

```text
chat.dart       → ChatPage + StatefulWidget + ChatController
chat_view.dart  → Stateless UI, получающий ChatController
```

`State<T>` играет роль view model/controller: хранит локальные поля, вызывает `setState`, выполняет async-операции SDK. `build()` обычно делегируется отдельному `...View(this)`. Такое разделение уменьшает размер визуального файла, но контроллер всё ещё связан с Flutter (`BuildContext`, dialogs, widgets), то есть это не независимый domain ViewModel.

## 4. Запуск приложения

Последовательность `main()`:

1. Определяется режим integration test.
2. На Android создаётся `ReceivePort`, координирующий основной и push-isolate.
3. На Web исправляется hash для OIDC callback.
4. Инициализируется `WidgetsFlutterBinding`.
5. `AppSettings.init()` открывает `SharedPreferences` и, на Web, при необходимости читает `config.json`.
6. Инициализируется Vodozemac (`vod.init`) — native/WASM crypto backend.
7. В Android detached/background режиме создаются клиенты без GUI, отключается online presence, запускается обработка push.
8. В foreground `ClientManager.getClients()` восстанавливает все локальные аккаунты и инициализирует SDK.
9. До `runApp` ожидается первичная загрузка комнат и account data первого клиента.
10. `FluffyChatApp` строит `MaterialApp.router`, тему, app lock и `Matrix` provider.

Упрощённо:

```text
main
 ├─ AppSettings.init
 ├─ Vodozemac.init
 ├─ ClientManager.getClients
 │   ├─ create Client
 │   ├─ open MatrixSdkDatabase
 │   └─ client.initWithRestore
 └─ startGui
     └─ FluffyChatApp
         └─ MaterialApp.router
             └─ AppLockWidget
                 └─ Matrix (global integration state)
                     └─ current route/page
```

Особенность: запуск может быть **headless/background-first** на Android. Поэтому нельзя бездумно переносить раннюю инициализацию в UI — push isolate тоже нуждается в части инфраструктуры.

## 5. State Management

### 5.1 Здесь нет одного глобального Redux/BLoC

State management гибридный:

1. **`StatefulWidget` + `setState`** — локальное состояние feature;
2. **`Provider<MatrixState>`** — доступ к глобальному integration state;
3. **SDK streams + `StreamBuilder`** — реакция на sync/room changes/notifications;
4. **`FutureBuilder`** — ожидание timeline и разовых загрузок;
5. **`SharedPreferences`** — персистентные пользовательские настройки;
6. **`ValueNotifier`/listenables** используются точечно, например темами;
7. состояние маршрута хранит `GoRouter`.

Пакет `provider` здесь не создаёт дерево `ChangeNotifier`. `MatrixState` — обычный `State<Matrix>`, который публикуется через:

```dart
Provider(create: (_) => this, child: widget.child)
```

и читается без подписки:

```dart
Matrix.of(context).client
```

Следовательно, сам `Provider` **не перестраивает** dependents при каждой перемене клиента. Перестройки обеспечиваются `setState`, router и stream/future builders.

### 5.2 Три масштаба состояния

#### Глобальное/integration state — `MatrixState`

Хранит и координирует:

- список SDK-клиентов (multi-account);
- индекс активного клиента и bundles аккаунтов;
- временный login client;
- подписки на запросы ключей и верификацию устройств;
- logout и UIA-запросы;
- push/notifications и VoIP plugin;
- lifecycle foreground/background;
- пароль, кешируемый в памяти на 10 минут для UIA;
- переходы router после login/logout.

#### Feature state — `State` конкретной страницы

Например `ChatController` хранит:

- `Room`, `Timeline`, текущий thread;
- выбранные события, reply/edit event;
- scrolling, drag-and-drop, emoji picker;
- typing timers;
- pending input и async initialization.

Он вызывает методы `Room`/`Timeline`, а UI получает controller. Аналогично устроены login, settings, new group и другие функции.

#### Server/SDK state

`matrix` SDK является фактическим источником истины о комнатах и событиях. `/sync` обновляет локальную БД и in-memory модели; UI слушает SDK streams. Не следует дублировать весь список сообщений в отдельный Flutter store.

### 5.3 Как проходит изменение

Пример входящего события:

```text
Synapse
  → /sync response
  → matrix Client обновляет БД, Room и Timeline
  → SDK публикует stream event
  → StreamBuilder/подписка получает update
  → Flutter перестраивает нужный участок UI
```

Пример локального действия:

```text
нажатие Send
  → метод ChatController
  → Room.send...
  → SDK шифрует (если надо), отправляет HTTP request
  → local echo появляется в timeline
  → server event/sync подтверждает результат
  → UI обновляется из timeline stream
```

### 5.4 Практические правила изменения state

- Временный флаг одного экрана — поле `State` + `setState`.
- Matrix-данные — получать из `Client`/`Room`/`Timeline`, подписываться на поток.
- Настройка, переживающая перезапуск — добавить типизированный ключ в `AppSettings`.
- Общеприложенческая интеграция — осторожно расширять `MatrixState`.
- Всегда отменять `StreamSubscription` и `Timer` в `dispose`; в `MatrixState` для этого есть `_cancelSubs`.
- После `await` перед использованием `context` проверять `mounted`.
- Не выполнять сетевой вызов непосредственно в `build()`; исключение — правильно кешированный `Future`, иначе он стартует при каждой перестройке.

## 6. Routing

### 6.1 Библиотека и корень

Используется декларативный `go_router`. Статический `GoRouter` находится вне `build`, чтобы hot reload не сбрасывал текущий URL. `MaterialApp.router` получает `routerConfig`.

Маршруты объявлены централизованно в `lib/config/routes.dart`. Основные ветки:

```text
/
├─ /home
│  ├─ sign_in
│  ├─ sign_up
│  └─ login
├─ /logs
├─ /configs
├─ /backup
└─ /rooms                         (auth required)
   ├─ archive[/:roomid]
   ├─ newprivatechat
   ├─ newgroup
   ├─ newspace
   ├─ settings/...
   └─ :roomid                     (chat and nested room tools)
```

Полный список следует читать в `AppRoutes.routes`, потому что settings и room имеют много вложенных экранов.

### 6.2 Guards/redirects

- `/` проверяет наличие хотя бы одного logged-in client и ведёт в `/rooms` либо `/home`;
- `loggedInRedirect` не даёт авторизованному пользователю снова пройти login flow;
- `loggedOutRedirect` защищает комнаты и настройки;
- глобальный redirect игнорирует URI content-sharing и преобразует Matrix deep link в `/rooms/newprivatechat#...`.

Это client-side guards, а не механизм безопасности: сервер всё равно обязан проверить access token и права.

### 6.3 ShellRoute и адаптивный master-detail

`ShellRoute` оборачивает дочернюю страницу. На широком экране используется `TwoColumnLayout`:

- слева `ChatList`, справа выбранная комната;
- аналогично settings list + выбранная настройка;
- на телефоне показывается один экран и обычная навигация.

Один и тот же URL поэтому может иметь разную композицию UI в зависимости от ширины, но остаётся deep-linkable.

### 6.4 Передача данных

- стабильные идентификаторы передаются в path: `:roomid`;
- необязательные фильтры — query (`event`, `spaceId`);
- deep link — fragment;
- уже открытый `Timeline` может передаваться через `state.extra` для оптимизации.

`extra` не стоит считать персистентным: после web refresh объект пропадёт. Страница обязана уметь восстановиться по URL/SDK state, если маршрут рассчитан на refresh.

### 6.5 Переходы

Общие `defaultPageBuilder`/`noTransitionPageBuilder` унифицируют platform transitions. Shell route намеренно не анимируется: комментарий предупреждает о двойном рендере одного `GlobalKey` при смене responsive layout.

## 7. Хранение данных

Здесь несколько хранилищ с разными задачами.

### 7.1 Матрица хранилищ

| Данные | Механизм | Где |
|---|---|---|
| комнаты, события, sync token, аккаунт, crypto state | `MatrixSdkDatabase` | IndexedDB-подобное web storage или SQLite/SQLCipher native |
| имена локальных SDK clients | `SharedPreferences` | ключ `im.fluffychat.store.clients` |
| UI-настройки | `SharedPreferences` через `AppSettings` | key-value |
| ключ шифрования локальной БД | `flutter_secure_storage` | Keychain/Keystore/libsecret и т. п. |
| PIN app lock и biometric flag | `flutter_secure_storage` | отдельные secure keys |
| media cache | файловая cache/temp directory | лимит файла и удаление через SDK DB policy |
| Web runtime config | `config.json` → defaults в preferences | загружается при старте |

### 7.2 MatrixSdkDatabase

`ClientManager.createClient()` передаёт SDK результат `flutterMatrixSdkDatabaseBuilder(clientName)`. Для каждого локального аккаунта создаётся собственная БД `<clientName>.sqlite`.

На native/desktop:

1. определяется application support/library directory;
2. мигрируется старое расположение файла;
3. создаётся `sqflite_common_ffi` factory;
4. при наличии cipher применяется SQLCipher `PRAGMA key`;
5. БД передаётся `MatrixSdkDatabase.init`;
6. file storage имеет `maxFileSize` 10 MB и политику удаления через 30 дней.

На Web вызываются `navigator.storage.persist()` и `MatrixSdkDatabase.init(clientName)` без нативного SQLite path. Конкретное браузерное хранилище инкапсулировано Matrix SDK; браузер всё равно может применить свои quota/eviction rules.

Если native БД не открылась, builder логирует ошибку, пытается уведомить пользователя, удаляет файл и создаёт БД заново. Это обеспечивает восстановление запуска ценой локального кеша; серверные данные можно синхронизировать снова, однако локальные crypto/session данные требуют особенно осторожного отношения и recovery/backup.

### 7.3 Шифрование БД «at rest»

`getDatabaseCipher()`:

- читает пароль `database_password` из secure storage;
- если его нет, генерирует 32 случайных байта через `Random.secure()` и кодирует Base64URL;
- на iOS использует App Group и мигрирует legacy key;
- если secure storage недоступно, возвращает `null` и показывает предупреждение — БД откроется без SQLCipher.

Это **не E2EE Matrix**. SQLCipher защищает локальный файл на диске; E2EE защищает содержимое события между устройствами.

### 7.4 SharedPreferences

`AppSettings<T>` — enum с key/default value и typed extensions для `bool`, `String`, `int`, `double`. Там находятся тема, homeserver default, typing/read receipt preferences, push gateway, timeout, UI filters и feature flags.

`SharedPreferences` нельзя использовать для секретов: storage предназначен для удобных настроек. Access tokens/crypto material хранит SDK database, а её disk key — secure storage.

## 8. Криптография и сквозное шифрование

> Криптографические примитивы реализует не UI FluffyChat, а Matrix SDK вместе с Vodozemac. Не следует писать собственную криптографию вместо этих компонентов.

### 8.1 Уровни защиты

| Уровень | Что защищает | Механизм |
|---|---|---|
| transport | клиент ↔ homeserver | HTTPS/TLS (обязан корректно настроить оператор) |
| Matrix E2EE | содержимое encrypted room между устройствами | Olm/Megolm и Matrix key management |
| local at-rest | SQLite-файл | SQLCipher + случайный ключ в secure storage |
| app access | открытие UI | PIN/biometrics через app lock |
| key recovery | восстановление ключей на новом устройстве | Matrix secret storage/key backup/bootstrap |

Они не заменяют друг друга. Например TLS завершается на reverse proxy/Synapse, но E2EE не позволяет homeserver прочитать plaintext сообщения зашифрованной комнаты. При этом homeserver видит метаданные, необходимые протоколу: аккаунты, room membership, timing, размеры событий и т. п.

### 8.2 Olm и Megolm на понятном уровне

- **Olm** создаёт защищённые device-to-device сессии и используется для небольших to-device payloads, включая доставку room keys.
- **Megolm** оптимизирован для групповой комнаты: устройство-отправитель имеет outbound group session и шифрует последовательность сообщений; участникам безопасно передаётся соответствующий session key.
- В encrypted room клиент отправляет `m.room.encrypted`, а plaintext message content получают только устройства с подходящим ключом.
- Новое устройство не получает автоматически все старые plaintext messages: ему нужны forwarded keys или server-side encrypted key backup/recovery.

### 8.3 Vodozemac

`flutter_vodozemac` предоставляет binding к Vodozemac. В `main()` backend инициализируется до создания UI; Web загружает WASM из assets. `ClientManager.nativeImplementations` выбирает:

- Web Worker на Web (`native_executor.js`), чтобы тяжёлые операции не блокировали UI;
- isolate/`compute` на native, с отдельной инициализацией Vodozemac.

Это одновременно security boundary библиотеки и performance-механизм.

### 8.4 Устройства, доверие и verification

Каждый login создаёт Matrix device с собственными ключами. В проекте разрешены SAS verification methods:

- сравнение чисел;
- emoji verification на поддерживаемых платформах.

`MatrixState` слушает `onKeyVerificationRequest` и показывает `KeyVerificationDialog`. Пользователи должны сравнить данные по независимому доверенному контексту, а не просто нажать «совпадает».

Для `onRoomKeyRequest` код автоматически пересылает ключ, только если запрос пришёл от одного из собственных clients и совпал `userId` и Curve25519 identity key. Это важно: key request нельзя удовлетворять любому устройству без проверки.

### 8.5 Cross-signing, secure storage и bootstrap

`lib/pages/bootstrap/` ведёт пользователя через:

- настройку/восстановление security bootstrap;
- recovery key или passphrase;
- восстановление encrypted key backup.

Cross-signing формирует доверие между master/self-signing/user-signing keys и устройствами. Secret storage хранит зашифрованные секреты в account data на homeserver; recovery key/passphrase разблокирует их. Это не пароль учётной записи.

### 8.6 Что означает UTD

UTD (unable to decrypt) означает, что ciphertext есть, а нужного session key локально нет или он пока не доступен. Причины:

- устройство новое и backup не восстановлен;
- sender ещё не поделился ключом;
- устройство не верифицировано согласно key-sharing policy;
- key request/backup/network завершился ошибкой;
- локальное crypto storage удалено.

При отладке нельзя «исправлять» UTD выводом ciphertext или отключением E2EE. Нужно проверить devices, verification, key backup и логи key requests.

### 8.7 Ограничения модели угроз

E2EE не спасает, если:

- устройство или ОС скомпрометированы;
- пользователь подтвердил чужое устройство;
- plaintext попал в notification preview, screenshot, clipboard или незашифрованный export;
- комната изначально не encrypted;
- malicious client сам раскрывает plaintext.

Для production используйте HTTPS, обновляйте клиент/Synapse, защищайте БД сервера и секреты, настройте retention/backup осознанно.

## 9. Сеть, синхронизация и сообщения

### 9.1 SDK Client

`ClientManager.createClient` собирает `matrix.Client` и задаёт:

- кастомный HTTP client;
- Matrix database;
- password + SSO login types;
- verification methods;
- Vodozemac native implementations;
- dehydrated devices;
- soft logout callback (опционально);
- key-sharing policy;
- network timeout и send-event timeout;
- custom image resizer.

Это главный composition root инфраструктуры Matrix. При изучении поведения SDK начните с параметров здесь, а затем переходите в исходники пакета `matrix` в pub cache.

### 9.2 Sync

После login SDK запускает Matrix sync loop. Концептуально клиент передаёт предыдущий `since` token и получает изменения:

- joined/invited/left rooms;
- timeline и state events;
- ephemeral typing/read receipts;
- to-device encrypted payloads;
- device lists и account data.

SDK сохраняет token и результат локально, обновляет модели и streams. Поэтому UI не опрашивает каждую комнату отдельно.

В background lifecycle код меняет `backgroundSync`, presence и `requestHistoryOnLimitedTimeline`, чтобы балансировать актуальность и расход ресурсов.

### 9.3 Timeline

`Timeline` — представление событий комнаты с пагинацией, local echo, relations и дешифрованием. `ChatController` создаёт/принимает timeline, загружает историю порциями и фильтрует события для GUI. `Event` может быть message, state, reaction, redaction, membership change и т. д.

Полезная трассировка отправки:

1. `chat_input_row.dart`/`input_bar.dart` получает ввод;
2. `ChatController` определяет reply/edit/thread context;
3. вызывается API `Room`;
4. SDK формирует event content, при E2EE шифрует и отправляет;
5. local echo отображается немедленно;
6. `/sync` возвращает каноническое событие/event id.

### 9.4 Custom HTTP

`lib/utils/custom_http_client.dart` выбирает platform implementation. Native вариант может использовать Cronet и platform networking; stub обеспечивает совместимую сборку. Для сетевой отладки полезно включить verbose logs, но нельзя публиковать access tokens, decrypted messages и ключевой материал.

### 9.5 Federation не проходит через клиент

Если Alice на `example.org` пишет Bob на `another.org`, FluffyChat общается со своим homeserver. Доставку между доменами выполняют homeserver через federation. Поэтому проблема может быть:

- Client-Server API/TLS — клиент не логинится/не sync;
- federation DNS/TLS/signing — локально всё работает, удалённый сервер недоступен;
- room permissions — сервер доступен, но действие запрещено.

## 10. Структура UI и адаптивность

- Flutter Material используется как базовый UI framework.
- `ThemeBuilder` и `FluffyThemes` строят light/dark/Material You схемы.
- `TwoColumnLayout` даёт desktop/tablet master-detail.
- platform checks сосредоточены в `PlatformInfos`.
- adaptive dialogs/bottom sheets позволяют одному feature работать на mobile/desktop.
- общие Matrix widgets: `Avatar`, `MxcImage`, event rendering, unread badges, presence.

Правило чтения feature:

1. найти route;
2. открыть `<feature>.dart` — state/actions;
3. открыть `<feature>_view.dart` — widget tree;
4. найти обращения к `Matrix.of(context)`;
5. перейти к `Room`/`Client` API в Matrix SDK;
6. найти stream, который вызывает последующую перестройку.

## 11. Аутентификация

Поддерживаются password и SSO; есть отдельные flows для SSO и OIDC. Общий сценарий:

1. пользователь вводит homeserver/domain;
2. выполняется discovery (`.well-known`) и определяется base URL;
3. клиент запрашивает поддерживаемые login flows;
4. password login отправляется API либо browser-based SSO/OIDC возвращает callback;
5. SDK сохраняет user ID, device ID, access/refresh information;
6. client добавляется в список local clients;
7. router переходит к security bootstrap/backup.

UIA (User-Interactive Authentication) — серверный многошаговый flow для чувствительных действий: смена пароля, удаление устройства и т. п. `MatrixState` слушает `onUiaRequest` и вызывает централизованный handler. Временно кешируемый пароль очищается таймером через 10 минут.

Multi-account реализован как несколько независимых `Client`/БД. `SharedPreferences` содержит только их локальные имена, а `MatrixState` выбирает активный.

## 12. Уведомления и фоновые процессы

Есть несколько путей:

- Android background isolate/foreground service;
- platform local notifications;
- Web Notifications API;
- UnifiedPush;
- опциональный Firebase flow, добавляемый скриптом;
- Matrix pusher, указывающий на push gateway.

Важно понимать приватность push: gateway желательно передавать минимум данных (`event_id_only`), после чего клиент делает sync и дешифрует событие локально. Push не заменяет sync и не должен требовать передачи plaintext E2EE сообщения стороннему сервису.

`MatrixState` подписывает каждый client на notifications, login/logout и lifecycle. При добавлении аккаунта нужно зарегистрировать подписки, при logout/dispose — отменить их, иначе появятся дублирующиеся уведомления и leaks.

## 13. Медиа, VoIP и платформенные возможности

### Медиа

- `file_picker`, `file_selector`, `image_picker`, `cross_file` — выбор файлов;
- `image`, `native_imaging`, `crop_image`, `video_compress` — подготовка изображений/видео;
- `mime` — content type;
- `MxcImage` и расширения SDK — download/decrypt/cache `mxc://`;
- `blurhash_dart` — placeholder;
- `video_player` + `chewie`, `just_audio` — playback;
- `record` + Opus/CAF converter — voice messages;
- `desktop_drop`, clipboard/share plugins — desktop/mobile UX.

Encrypted attachment обычно загружается как ciphertext, а ключ/IV/hash находятся в encrypted event content. Поэтому обычный HTTP URL недостаточен: decrypt выполняется клиентом.

### VoIP

`flutter_webrtc`/`webrtc_interface` дают media transport, а `utils/voip/` и Matrix call events связывают signalling с комнатой. Для реальной работы за NAT часто нужен TURN (например Coturn); одного Synapse недостаточно для надёжного media path.

### Геолокация и карты

`geolocator`, `flutter_map`, `latlong2` обеспечивают location sharing/rendering. Следует учитывать platform permissions и приватность координат.

## 14. Основные библиотеки

Версии смотрите в `pubspec.yaml`; ниже — роль, а не полный API.

### Ядро

| Пакет | Роль |
|---|---|
| `flutter` | UI/runtime и multi-platform abstraction |
| `matrix` | Client-Server API, sync, models, timeline, database/E2EE orchestration |
| `flutter_vodozemac` | Olm/Megolm crypto backend |
| `go_router` | declarative URL routing, redirects, nested shells |
| `provider` | публикация `MatrixState` в widget tree |
| `shared_preferences` | несекретные настройки и список clients |
| `flutter_secure_storage` | DB password, app-lock secrets |
| `sqflite_common_ffi` + SQLCipher hook | native encrypted SQLite |

### Сеть, platform и system integration

| Пакеты | Роль |
|---|---|
| `http`, `cronet_http` | HTTP и native transport |
| `path_provider`, `path_provider_foundation`, `path` | DB/cache paths |
| `device_info_plus`, `package_info_plus` | device/app metadata |
| `url_launcher`, `flutter_web_auth_2` | external auth/browser links |
| `local_auth` | biometrics для app lock |
| `flutter_local_notifications`, `unifiedpush*`, `flutter_foreground_task` | push/background notifications |
| `receive_sharing_intent`, `share_plus`, `pasteboard` | OS share/clipboard integration |

### UI/content

| Пакеты | Роль |
|---|---|
| `dynamic_color` | Material You colors |
| `emoji_picker_flutter`, `badges`, `flutter_linkify`, `highlight` | chat/UI rendering |
| `pretty_qr_code`, `qr_code_scanner_plus`, `qr_image` | QR login/share/verification UX |
| `flutter_map`, `geolocator` | maps/location |
| audio/video/image/file packages | capture, transform, select and play media |
| `flutter_webrtc` | calls |

### Development

- `flutter_test` — unit/widget tests;
- `integration_test` — end-to-end app tests;
- `flutter_lints` и `dart_code_linter` — static analysis;
- `license_checker` — dependency licensing;
- `flutter_launcher_icons` — platform icon generation.

## 15. Локализация, конфигурация и темы

### Локализация

ARB-файлы лежат в `lib/l10n/`. Flutter code generation создаёт типизированный API, доступный через `L10n.of(context)`. Новую пользовательскую строку нельзя хардкодить только на одном языке: добавьте ключ в source locale и переводы по процессу проекта.

### Конфигурация

- compile/repository defaults — `AppSettings` и `AppConfig`;
- пользовательские overrides — `SharedPreferences`;
- Web deployment overrides — `config.json` рядом с web app;
- `config.sample.json` показывает допустимые поля.

При чтении Web config значение применяется только если пользователь ещё не сохранил соответствующую настройку. Это сохраняет выбор пользователя поверх deployment default.

### Темы

`ThemeBuilder` передаёт `themeMode` и seed color в `FluffyThemes.buildTheme`. `MaterialApp.router` получает light/dark theme. Responsive column mode также определяется helper-методами темы, поэтому theme/layout здесь частично связаны.

## 16. Развёртывание собственного Synapse

Ниже — **учебная** Docker-схема. Перед production-развёртыванием сверяйте параметры с актуальной официальной документацией Synapse, фиксируйте конкретные версии образов, используйте PostgreSQL, резервные копии и reverse proxy. Не публикуйте development server напрямую.

### 16.1 Выберите неизменяемое имя сервера

Пусть MXID будет `@alice:matrix.example.org`. `server_name` входит в идентификаторы пользователей и комнат; менять его после начала эксплуатации сложно. Возможны две модели:

- простой вариант: `server_name: matrix.example.org`, API там же;
- красивый MXID `@alice:example.org`, а API на `matrix.example.org` — требует корректных `/.well-known/matrix/client` и `/.well-known/matrix/server` на `example.org`.

Для первого стенда берите простой вариант.

### 16.2 DNS и порты

- A/AAAA `matrix.example.org` → публичный сервер;
- наружу открыть 80/443 для ACME и HTTPS;
- Synapse port `8008` оставить во внутренней Docker network;
- TLS завершать на reverse proxy;
- federation предпочтительно публиковать через 443 с корректным delegation; не выставлять админские endpoints без необходимости.

Для локального стенда без federation можно использовать `localhost`, но мобильное устройство не считает `localhost` адресом компьютера, а self-signed TLS усложнит login. Удобнее настоящий test domain с доверенным сертификатом.

### 16.3 Минимальная структура

```text
matrix-lab/
├── compose.yaml
├── .env
├── synapse-data/       # homeserver.yaml появится здесь
└── postgres-data/
```

Создайте `.env` и не коммитьте его:

```dotenv
POSTGRES_DB=synapse
POSTGRES_USER=synapse
POSTGRES_PASSWORD=ЗАМЕНИТЕ_НА_ДЛИННЫЙ_СЛУЧАЙНЫЙ_СЕКРЕТ
```

Сначала сгенерируйте конфигурацию официальным образом (версию `X.Y.Z` замените на выбранный и проверенный тег, не используйте плавающий тег в production):

```bash
mkdir -p synapse-data postgres-data

docker run --rm \
  -v "$(pwd)/synapse-data:/data" \
  -e SYNAPSE_SERVER_NAME=matrix.example.org \
  -e SYNAPSE_REPORT_STATS=no \
  matrixdotorg/synapse:X.Y.Z generate
```

### 16.4 Compose

```yaml
services:
  postgres:
    image: postgres:17
    restart: unless-stopped
    environment:
      POSTGRES_DB: ${POSTGRES_DB}
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_INITDB_ARGS: --encoding=UTF8 --locale=C
    volumes:
      - ./postgres-data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U $POSTGRES_USER -d $POSTGRES_DB"]
      interval: 10s
      timeout: 5s
      retries: 10

  synapse:
    image: matrixdotorg/synapse:X.Y.Z
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
    volumes:
      - ./synapse-data:/data
    ports:
      # Для отладки bind только на loopback; reverse proxy обращается сюда.
      - "127.0.0.1:8008:8008"
```

В `synapse-data/homeserver.yaml` настройте PostgreSQL вместо SQLite:

```yaml
database:
  name: psycopg2
  args:
    user: synapse
    password: "тот же длинный секрет"
    database: synapse
    host: postgres
    cp_min: 5
    cp_max: 10
```

Не вставляйте второй ключ `database`, если он уже существует: замените сгенерированный блок. Проверьте также:

```yaml
public_baseurl: "https://matrix.example.org/"
```

Секреты signing key и registration/shared secrets храните с правами только для администратора и резервируйте. Утрата signing key критична для federation identity.

### 16.5 Reverse proxy и TLS

Пример смысловой конфигурации Nginx:

```nginx
server {
    listen 443 ssl http2;
    server_name matrix.example.org;

    # ssl_certificate /.../fullchain.pem;
    # ssl_certificate_key /.../privkey.pem;

    client_max_body_size 100M;

    location ~ ^(/_matrix|/_synapse/client) {
        proxy_pass http://127.0.0.1:8008;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Host $host;
        proxy_read_timeout 600s;
    }
}
```

В Synapse настройте trusted proxy (`x_forwarded: true` у listener) строго согласно официальной документации и вашей topology. Не проксируйте весь `/_synapse/admin` публично без access controls. Ограничение upload size должно согласовываться в Synapse и proxy.

### 16.6 Регистрация первого пользователя

Безопаснее отключить открытую регистрацию и создать тестового пользователя admin-командой внутри контейнера:

```bash
docker compose up -d
docker compose exec synapse register_new_matrix_user \
  -c /data/homeserver.yaml \
  http://localhost:8008
```

Команда интерактивно запросит имя, пароль и admin flag. Для автоматизации используйте секреты безопасно, не помещайте пароль в shell history/репозиторий.

### 16.7 Проверки сервера

```bash
curl -fsS https://matrix.example.org/_matrix/client/versions
curl -fsS https://matrix.example.org/_matrix/federation/v1/version

docker compose logs -f synapse
```

Второй endpoint проверяет публикацию federation API, но полноценную federation/delegation/TLS проверку лучше делать специализированным federation tester. Проверяйте также DNS, сертификат, `.well-known`, время системы и доступность с внешней сети.

### 16.8 TURN для звонков

Для лабораторных сообщений TURN не нужен. Для надёжного WebRTC разверните Coturn, откройте UDP/TCP relay range и задайте в Synapse:

```yaml
turn_uris:
  - "turn:turn.example.org:3478?transport=udp"
  - "turn:turn.example.org:3478?transport=tcp"
turn_shared_secret: "ОТДЕЛЬНЫЙ_СЛУЧАЙНЫЙ_СЕКРЕТ"
turn_user_lifetime: 1h
turn_allow_guests: false
```

TLS TURN (`turns:`), firewall и advertised external IP зависят от окружения.

### 16.9 Production checklist

- PostgreSQL вместо SQLite;
- фиксированные image versions и план обновления;
- HTTPS с доверенным сертификатом;
- registration закрыта либо защищена token/captcha/approval;
- rate limiting и firewall;
- отдельный непривилегированный runtime user где возможно;
- backups PostgreSQL, media store, signing keys и конфигурации;
- тест восстановления backup;
- monitoring диска, federation, DB connections, error rate;
- политика retention/moderation/abuse reports;
- SMTP для password reset, если нужен;
- TURN для звонков;
- privacy policy и защита логов;
- регулярное чтение security advisories Synapse.

## 17. Подключение FluffyChat к своему серверу

### 17.1 Без изменения кода

Запустите приложение и укажите `matrix.example.org` в homeserver picker. Клиент выполнит discovery/login flow. Для локальной разработки:

```bash
flutter pub get
flutter run
```

Потребуются Flutter и Rust, потому что crypto backend связан с Vodozemac. Для Web сначала выполните:

```bash
./scripts/prepare-web.sh
flutter run -d chrome
```

Web требует CORS и HTTPS, особенно если app и homeserver на разных origins. Не отключайте browser security для обхода неправильной server configuration.

### 17.2 Deployment default

Чтобы ваш Web build предлагал свой homeserver, разместите рядом с `index.html` минимальный `config.json`:

```json
{
  "defaultHomeserver": "matrix.example.org"
}
```

Не копируйте все значения из sample без необходимости. Это default, а не жёсткая привязка. Для white-label также доступны application name, logo, website, privacy/TOS и colors.

### 17.3 Локальная сеть

Android emulator обращается к host не через `localhost` (часто используется специальный host alias), а физический телефон — через LAN IP/DNS. Но Matrix discovery, secure storage, SSO callback и Web обычно гораздо стабильнее тестировать с настоящим DNS + TLS.

Никогда не добавляйте глобальное отключение проверки TLS в production client. Если нужен лабораторный CA, установите его только на тестовое устройство и документируйте риск.

## 18. Отладка полного сценария

### 18.1 Базовый сценарий

Создайте **два пользователя и два устройства**, иначе нельзя полноценно изучить E2EE:

1. Alice регистрируется/логинится во FluffyChat A.
2. Bob логинится в другом профиле/устройстве/клиенте.
3. Alice создаёт unencrypted test room — проверяет базовый sync.
4. Alice создаёт encrypted room и приглашает Bob.
5. Отправляются text, image, reply, reaction, edit, redaction.
6. Проверяются typing, read receipts и offline delivery.
7. Alice логинится на втором устройстве.
8. Выполняется emoji/number verification.
9. Настраивается key backup/recovery, затем восстанавливается на чистом профиле.
10. Проверяется logout, soft logout и multi-account.

### 18.2 Что наблюдать

| Действие | Клиент | Synapse |
|---|---|---|
| login | route, новый `Client`, local DB | login request, device/access token |
| open room | `Room`, `Timeline`, pagination | `/sync`, messages/context APIs |
| send | local echo → confirmed event | send event и следующий sync |
| E2EE send | key share + `m.room.encrypted` | ciphertext, to-device traffic |
| verify | verification dialog/state machine | to-device verification events |
| media | encrypt/upload, `mxc://`, cache | media repository request |
| offline/online | lifecycle + sync resume | long-poll disconnect/reconnect |

### 18.3 Полезные точки останова

- `main()` и `startGui()`;
- `ClientManager.getClients/createClient`;
- `MatrixState.initMatrix/_registerSubs/setActiveClient`;
- login submit/callback;
- `ChatController` timeline initialization и send methods;
- route redirects;
- database builder/cipher;
- notification background handlers.

### 18.4 Логи и безопасность

Во FluffyChat есть `/logs`, а SDK создаётся с verbose log level. Synapse:

```bash
docker compose logs --since=10m synapse
```

При публикации issue удаляйте:

- access/refresh tokens;
- passwords/recovery keys;
- device/session keys;
- decrypted message content;
- personal MXIDs/room IDs/IPs, если они чувствительны.

### 18.5 Типичные неисправности

| Симптом | Проверить |
|---|---|
| homeserver не найден | `.well-known`, base URL, DNS, JSON content type |
| login работает только локально | public DNS/firewall/TLS/reverse proxy |
| Web login блокируется | CORS, HTTPS mixed content, callback URL |
| сообщения локально есть, federation нет | federation delegation, signing key, TLS, port/path |
| UTD | device trust, key backup, key request, новый crypto store |
| media 413 | proxy и Synapse upload limits |
| звонок соединяется без звука/не соединяется | permissions, ICE candidates, TURN/firewall |
| после reinstall старая история не расшифрована | recovery/key backup не восстановлен |
| уведомления не приходят | pusher, gateway/UnifiedPush/FCM, background restrictions, sync |

## 19. Тестирование и качество кода

### 19.1 Команды

```bash
flutter pub get
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test
```

Integration tests требуют Docker и подготовительный скрипт:

```bash
./scripts/prepare_integration_test.sh
flutter test integration_test/mobile_test.dart
```

Скрипт поднимает предназначенное проектом тестовое окружение; не заменяйте его production Synapse и не запускайте destructive test against реальными данными.

### 19.2 Виды тестов

- unit tests — helpers/filtering/commands;
- widget tests — Flutter tree и interaction;
- integration tests — реальный пользовательский flow с backend;
- manual matrix — mobile/desktop/web, encrypted/unencrypted, multi-device;
- static analysis — типы, lints и lifecycle mistakes.

Для нового feature желательно отделять pure logic от `BuildContext`: её проще unit-test. UI side effects оставлять в controller/view и проверять widget/integration test.

## 20. План изучения для Junior

### Этап 1. Flutter-каркас

1. Прочитать `pubspec.yaml`.
2. Пройти `main.dart` по шагам до `runApp`.
3. Нарисовать widget tree `FluffyChatApp`.
4. Разобрать `StatefulWidget`, `setState`, `StreamBuilder`, `FutureBuilder`, `Provider`.
5. Запустить приложение с breakpoint.

**Результат:** понятно, кто создаёт router, Matrix context и SDK clients.

### Этап 2. Навигация

1. Прочитать `AppRoutes.routes` сверху вниз.
2. Выписать URL для login, rooms, settings, room details.
3. Сравнить телефон и wide window.
4. Открыть deep link и web refresh.

**Результат:** понятны `GoRoute`, `ShellRoute`, redirect, path/query/fragment/extra.

### Этап 3. Matrix без E2EE

1. Развернуть Synapse.
2. Создать Alice/Bob.
3. Проследить login и `/sync`.
4. Создать незашифрованную room.
5. Поставить breakpoints на создание timeline/send.

**Результат:** понятны `Client`, `Room`, `Timeline`, `Event` и local echo.

### Этап 4. Storage

1. Изменить UI setting и найти его key.
2. Найти список clients в SharedPreferences.
3. Найти SQLite path на тестовой платформе.
4. Понять, почему DB password хранится отдельно.
5. Очистить app data и увидеть полную resync.

Не открывайте production SQLCipher DB небезопасными инструментами и не публикуйте её.

### Этап 5. E2EE

1. Создать encrypted room.
2. Сравнить client plaintext и server event ciphertext.
3. Добавить второе устройство.
4. Верифицировать устройства.
5. Воспроизвести UTD, затем восстановить backup.
6. Разделить в конспекте TLS, SQLCipher и E2EE.

### Этап 6. Небольшая задача

Хорошие первые изменения:

- UI-only настройка;
- небольшой reusable widget;
- улучшение empty/error state;
- unit test pure helper;
- новая строка локализации.

Перед изменением ответьте:

1. Кто source of truth?
2. Как состояние переживает rebuild/restart?
3. Какой stream инициирует UI update?
4. Что происходит offline?
5. Не раскрывает ли изменение plaintext/ключи/token?
6. Работает ли mobile, desktop и web?

## 21. Глоссарий и источники

### Глоссарий

- **Homeserver** — сервер, обслуживающий Matrix-аккаунт и комнаты.
- **Synapse** — реализация homeserver.
- **Client** — локальная SDK-сессия одного аккаунта/device.
- **Sync** — поток изменений от homeserver к клиенту.
- **Room state** — текущие state events комнаты.
- **Timeline** — упорядоченное клиентское представление событий.
- **Local echo** — временное отображение отправляемого события до подтверждения.
- **E2EE** — end-to-end encryption.
- **Olm/Megolm** — Matrix crypto ratchets для device-to-device/group messaging.
- **SAS** — short authentication string для сравнения при verification.
- **Cross-signing** — иерархия ключей доверия пользователя и устройств.
- **SSSS/secret storage** — зашифрованное хранение recovery secrets в account data.
- **UIA** — многоэтапная повторная аутентификация чувствительного действия.
- **Pusher** — регистрация доставки push-сигнала через gateway.
- **Federation** — обмен событиями между homeserver.

### Что читать в репозитории

1. `README.md` — назначение, features, build.
2. `pubspec.yaml` — зависимости и platforms.
3. `lib/main.dart` — lifecycle/startup.
4. `lib/widgets/fluffy_chat_app.dart` — composition и router host.
5. `lib/widgets/matrix.dart` — глобальная интеграция с SDK.
6. `lib/config/routes.dart` — navigation graph.
7. `lib/utils/client_manager.dart` — создание и восстановление clients.
8. `lib/utils/matrix_sdk_extensions/flutter_matrix_dart_sdk_database/` — БД/SQLCipher.
9. `lib/pages/chat/chat.dart` + `chat_view.dart` — показательный feature.
10. `lib/pages/bootstrap/` и `lib/pages/key_verification/` — E2EE UX.
11. `lib/utils/background_push.dart` и notification handlers — background flow.
12. `test/` и `integration_test/` — ожидаемое поведение.

### Внешние первичные источники

Сверяйте детали протокола и deployment с актуальными версиями:

- [Matrix specification](https://spec.matrix.org/latest/)
- [Matrix Client-Server API](https://spec.matrix.org/latest/client-server-api/)
- [Matrix encryption guide](https://matrix.org/docs/matrix-concepts/end-to-end-encryption/)
- [Synapse documentation](https://element-hq.github.io/synapse/latest/)
- [Synapse installation](https://element-hq.github.io/synapse/latest/setup/installation.html)
- [Synapse reverse proxy](https://element-hq.github.io/synapse/latest/reverse_proxy.html)
- [Synapse TURN setup](https://element-hq.github.io/synapse/latest/turn-howto.html)
- [Flutter documentation](https://docs.flutter.dev/)
- [go_router documentation](https://pub.dev/packages/go_router)
- [matrix Dart SDK](https://pub.dev/packages/matrix)

---

## Короткая ментальная модель

Если оставить пять тезисов:

1. **FluffyChat — UI/integration layer над Matrix Dart SDK**, а не реализация Synapse.
2. **Source of truth для чатов — SDK + его локальная БД + server sync**, не единый Flutter store.
3. **State management гибридный:** `State/setState`, streams, futures и небольшой global `Provider<MatrixState>`.
4. **Три защиты различны:** HTTPS, Matrix E2EE и SQLCipher at-rest.
5. **Лучший способ изучения — два пользователя, несколько устройств и трассировка** `route → controller → Room/Timeline → HTTP/sync → stream → rebuild`.
