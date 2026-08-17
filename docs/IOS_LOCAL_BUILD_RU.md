# Локальная iOS-сборка FluffyChat: патчи, подпись и как вернуть упрощения

> Документ описывает **учебный стенд** в этом рабочем дереве (FluffyChat 2.8.0,
> Flutter 3.44.9, Intel Mac + физический iPhone). Он не заменяет официальную
> инструкцию автора `README.md` / `scripts/build-ios.sh` и не является рецептом
> публикации в App Store.
>
> Связанные материалы: [`ARCHITECTURE_RU.md`](ARCHITECTURE_RU.md),
> [`SYNAPSE_DEBIAN13_LAN_RU.md`](SYNAPSE_DEBIAN13_LAN_RU.md).

## Содержание

1. [Зачем этот документ](#1-зачем-этот-документ)
2. [Что уже работает на этом стенде](#2-что-уже-работает-на-этом-стенде)
3. [Патч webcrypto: что это и почему его нет у автора](#3-патч-webcrypto-что-это-и-почему-его-нет-у-автора)
4. [Подпись iOS, wildcard-профиль и Apple Developer Agreement](#4-подпись-ios-wildcard-профиль-и-apple-developer-agreement)
5. [Таблица локальных упрощений и как от них избавиться](#5-таблица-локальных-упрощений-и-как-от-них-избавиться)
6. [App Groups, Share, NSE и Push (после PLA)](#6-app-groups-share-nse-и-push-после-pla)
7. [Команды повторной сборки](#7-команды-повторной-сборки)
8. [Чего этот стенд сознательно не делает](#8-чего-этот-стенд-сознательно-не-делает)

---

## 1. Зачем этот документ

Цель стенда — **собрать клиент из исходников и запустить его без ошибок**, чтобы
изучать код, Matrix Client-Server API и (позже) локальный Synapse. На этой
основе может появиться отдельное приложение. Поэтому:

- функциональность клиента **не вырезаем «чтобы завелось»**, если можно обойти
  только инфраструктуру сборки/подписи;
- каждое упрощение записано вместе с **обратным путём**;
- бинарники зависимостей в git приложения **не кладём**.

Два места, которые ломали запуск на этой машине:

1. Native-сборка пакета `webcrypto` на **Intel iOS Simulator** (`ios-x64`).
2. Подпись на **личный Apple Developer Team** с wildcard provisioning profile
   и непринятым Program License Agreement (PLA).

---

## 2. Что уже работает на этом стенде

| Цель | Состояние |
|---|---|
| `flutter build ios --debug --simulator` на Intel Mac | Работает после патча `webcrypto` и установки CMake |
| `flutter run` на физическом iPhone (iOS 26) | Работает как отдельное приложение **FluffyChat Dev** |
| Официальный FluffyChat из App Store | Не затронут: другой Bundle ID |
| Login / комнаты / E2EE к LAN Synapse | Нужно проверить после возврата сетевых настроек |
| Push, Share extension, Notification Service Extension | Entitlements App Groups + Push возвращены. Реальная доставка push с LAN Synapse — отдельный этап |
| Патч `webcrypto` для Intel Simulator | Остаётся: `./scripts/apply-webcrypto-ios-x64-patch.sh` |

Текущие идентификаторы **учебной** установки на устройстве:

| Параметр | Upstream (git) | Этот стенд |
|---|---|---|
| Bundle ID приложения | `im.fluffychat.app` | `com.pawga.fluffychat` |
| Имя на SpringBoard | FluffyChat | FluffyChat Dev |
| Team | `4HV29TJN3A` (автор) | `H8XL8TZH7H` (Sergey Ivannikov) |
| App Group | `group.im.fluffychat.app` | `group.com.pawga.fluffychat` |

Менять Bundle ID пришлось обязательно: `im.fluffychat.app` принадлежит команде
автора. Установка debug-сборки с чужим Team поверх App Store-приложения
невозможна.

---

## 3. Патч webcrypto: что это и почему его нет у автора

### 3.1 Короткий ответ

Это **не бинарный файл и не четыре новых исходника в FluffyChat**.

Это **четыре строки в CMake-списке** пакета `webcrypto` 0.6.1 (зависимость
Matrix/Dart crypto через BoringSSL). Строки говорят компилятору: «собери уже
лежащие в пакете `.S` файлы и для Apple x86_64, а не только для Linux x86_64».

Сами файлы — текстовый ассемблер Fiat/ADX из BoringSSL, они **уже входят** в
`webcrypto` на pub.dev:

```text
~/.pub-cache/hosted/pub.dev/webcrypto-0.6.1/third_party/boringssl/third_party/fiat/asm/
  fiat_curve25519_adx_mul.S
  fiat_curve25519_adx_square.S
  fiat_p256_adx_mul.S
  fiat_p256_adx_sqr.S
```

Их **не нужно** копировать в git FluffyChat. Копирование не поможет: CMake
пакета всё равно не возьмёт файлы, пока они не перечислены в
`crypto_sources_apple_x86_64`.

### 3.2 Какая ошибка была

При `flutter run` на симуляторе Intel Mac падал шаг native assets:

```text
Target dart_build failed: Error: Building native assets failed.
Building assets for package:webcrypto failed.
Undefined symbols for architecture x86_64:
  "_fiat_p256_adx_mul"
  "_fiat_p256_adx_sqr"
```

Цепочка такая:

1. FluffyChat тянет `webcrypto` (транзитивно).
2. `webcrypto` 0.6.1 собирает BoringSSL хуком `hook/build.dart` через **CMake**.
3. C-код (`p256_64.h`) на x86_64 вызывает `fiat_p256_adx_mul` / `_sqr`, если
   не задан `OPENSSL_NO_ASM`.
4. В `sources.cmake` эти `.S` файлы перечислены в
   `crypto_sources_linux_x86_64`, но **забыты** в
   `crypto_sources_apple_x86_64`.
5. Линкер iOS Simulator x86_64 не находит символы → сборка падает.

На Apple Silicon симулятор — `ios-arm64`, этот код не вызывается. На физическом
iPhone тоже `arm64`. Баг проявляется почти только на **Intel Mac + Simulator**.

До этого же падения CMake не был установлен (`Failed to find cmake version:
latest`). Для любой native-сборки `webcrypto` нужны:

```bash
brew install cmake ninja
```

### 3.3 Как автор и CI собирают без этого патча

Официальный репозиторий **не патчит** `webcrypto`. Это нормально.

GitHub Actions job `build_debug_ios` в `.github/workflows/integrate.yaml`:

- runner `macos-15` — у GitHub это **Apple Silicon**;
- команда `flutter build ios --no-codesign` собирает **device arm64**, не
  Intel-симулятор;
- Rust ставится отдельно (`dtolnay/rust-toolchain`), CMake на macos-images
  обычно уже есть.

App Store / TestFlight автора — тоже только `arm64` устройства. Intel
симулятор в их CI, судя по workflow, не гоняется.

Локально автор (Krille) с высокой вероятностью тоже на Apple Silicon. Поэтому
дыры в `crypto_sources_apple_x86_64` они просто не видят. Это баг **пакета
`webcrypto`**, не FluffyChat. Исправлять его «навсегда» правильно upstream:
<https://github.com/google/webcrypto.dart>. Пока этого нет — держим патч у себя.

`--no-codesign` в CI означает: «проверь, что Xcode **компилирует**», без
установки на телефон и без App Groups/Push. Подпись и entitlements там не
проверяются так, как при `flutter run` на устройстве.

### 3.4 Можно ли положить четыре файла в git приложения?

**Не как бинарники и не как копию `.S`.** Причины:

- файлы уже в зависимости; дублирование разъедется с версией `webcrypto`;
- CMake зависимости всё равно читает свой `sources.cmake` в pub-cache;
- `webcrypto` + BoringSSL — сотни исходников, вендорить пакет целиком ради
  четырёх строк списка бессмысленно.

**Да, в git приложения нужно положить сам патч списка.** Он уже здесь:

| Путь | Назначение |
|---|---|
| `patches/webcrypto-0.6.1-apple-x86_64-adx.patch` | diff четырёх строк CMake |
| `scripts/apply-webcrypto-ios-x64-patch.sh` | идемпотентно вписывает их в pub-cache |

После `flutter pub get` или `flutter pub cache repair`:

```bash
./scripts/apply-webcrypto-ios-x64-patch.sh
```

Скрипт ничего не делает, если строки уже есть в блоке `apple_x86_64`.

Когда `webcrypto` обновится выше 0.6.1, патч нужно **пересмотреть**: либо баг
уже исправлен upstream, либо сдвинулся контекст `sources.cmake`.

Физическому iPhone этот патч **не нужен**. Он нужен, если снова собирать
симулятор на этом Intel Mac.

### 3.5 Связь с Vodozemac / Rust

Патч `webcrypto` **не про Matrix E2EE**. E2EE в FluffyChat идёт через
`flutter_vodozemac` (Vodozemac). На iOS при включённом Swift Package Manager
берётся готовый XCFramework, локальный Rust для этого пути не обязателен.

`webcrypto` — отдельная native-библиотека (Web Cryptography API / BoringSSL),
которую тянет граф зависимостей. Без успешной её сборки Flutter не упаковывает
приложение вообще.

README автора по-прежнему требует Rust: он нужен для Android/desktop/CocoaPods
и для CI. Для текущего iOS debug с SPM это не блокер.

---

## 4. Подпись iOS, wildcard-профиль и Apple Developer Agreement

### 4.1 Что означала фраза про wildcard и PLA

Xcode при `flutter run` на устройство делает Automatic Signing командой
`H8XL8TZH7H`. На аккаунте уже был профиль

```text
iOS Team Provisioning Profile: *
```

то есть **wildcard** `H8XL8TZH7H.*`.

Wildcard умеет поставить простое приложение («Здравствуй, мир»). Он **не умеет**
включить в профиль:

- App Groups (`group.…`);
- Push Notifications (`aps-environment`);
- Associated Domains (`applinks:…`).

Чтобы выдать **явный** App ID с этими capability, Xcode ходит в Apple Developer
Portal. Ответ портала был:

```text
PLA Update available: You currently don't have access to this membership
resource. To resolve this issue, agree to the latest Program License Agreement
in your developer account.
```

**Program License Agreement (PLA)** — лицензионное соглашение Apple Developer
Program. Пока новая версия не принята в браузере, API не создаёт App ID с
Push/Groups. Hello World из Xcode это не затронуло: там не было этих
entitlements.

Это **не баг FluffyChat**. Официальная сборка автора подписывается **их** Team
`4HV29TJN3A`, где App ID `im.fluffychat.app` и группа
`group.im.fluffychat.app` уже зарегистрированы годами.

### 4.2 Что мы упростили, чтобы запустить клиент

Код Share extension и Notification Service Extension **не удалялся**. Сначала
из подписи убрали то, чего wildcard не даёт (пустые entitlements, keychain без
группы). После принятия PLA и регистрации `com.pawga.fluffychat` /
`group.com.pawga.fluffychat` App Groups и Push **возвращены** в entitlements
(см. §6). Fallback в `builder.dart` оставлен как защита, не как упрощение.

Associated Domains (`applinks:example.com`) **не** возвращали: это заглушка
автора, для LAN Synapse и login не нужна.

**Что сохранилось:** login, синхронизация, локальная БД, E2EE в приложении,
UI, звонки на уровне клиента (WebRTC-плагины на месте).

**Что всё ещё не даст реальных уведомлений без отдельной работы:**

- удалённые push через APNs / FCM (нужен свой Firebase/APNs на этот Bundle ID;
  `GoogleService-Info.plist` автора к `com.pawga.fluffychat` не привязан);
- LAN Synapse без публичного push-шлюза (см. `SYNAPSE_DEBIAN13_LAN_RU.md`).

App Groups нужны, чтобы NSE и основное приложение делили БД и ключ — это
готовая инфраструктура, даже если push с сервера ещё нет.

### 4.3 Зачем вообще App Groups в оригинале

Официальный клиент кладёт ключ БД и файловый кэш в App Group, чтобы
**Notification Service Extension** (отдельный процесс) читал ту же SQLCipher-БД
и показывал текст зашифрованного сообщения на экране блокировки. Это не нужно
для login.

---

## 5. Таблица локальных упрощений и как от них избавиться

| Упрощение | Зачем сделано | Как вернуть «как у автора / как в будущем своём приложении» |
|---|---|---|
| Патч `webcrypto` apple x86_64 | Intel Simulator | `./scripts/apply-webcrypto-ios-x64-patch.sh`; лучше — PR в `webcrypto.dart`. На arm64 можно не применять. |
| CMake/Ninja через Homebrew | native hook `webcrypto` | Оставить. Это не упрощение, а недостающая toolchain. |
| Bundle ID `com.pawga.fluffychat` | нельзя подписать чужой `im.fluffychat.app` | Для форка оставить **свой** ID. Для апстрим-сборки: `git checkout -- ios lib` и `scripts/build-ios.sh` с `FLUFFYCHAT_NEW_*`. |
| Team `H8XL8TZH7H` | личный сертификат | Для своего приложения — свой Team. Не возвращать Team автора. |
| Пустые entitlements | wildcard + непринятый PLA | **Сделано:** App Groups + Push в трёх entitlements. Associated Domains сознательно не вернули (`applinks:example.com`). |
| Keychain без App Group | иначе SQLCipher-ключ не пишется | **Сделано:** `IOSOptions(groupId: 'group.com.pawga.fluffychat')` в `cipher.dart`. |
| Fallback каталога БД без App Group | не падать на старте | Fallback **оставлен** даже после возврата Groups — это защита, не упрощение. |
| Имя «FluffyChat Dev» | не путать с App Store | Поменять `CFBundleDisplayName` когда решите имя продукта. |
| FCM / `GoogleService-Info.plist` | чужой проект не будит `com.pawga.fluffychat` | **Долг:** свой Firebase + свой gateway, см. §6.5. Авторский стек не одалживаем. |
| Не принят PLA | блокер портала Apple | **Сделано:** соглашение принято. |

Правило для будущего своего приложения: **с первого дня завести свои** Bundle
ID, App Group, Team. Не копировать `im.fluffychat.*`. Скрипт автора
`scripts/build-ios.sh` как раз для ротации ID, но в текущем дереве он ещё
ссылается на старые `FLUFFYCHAT_ORIG_TEAM=4NXF6Z997G` / группу
`im.fluffychat` — сверять с фактическим `project.pbxproj` (`4HV29TJN3A`,
`im.fluffychat.app`).

---

## 6. App Groups, Share, NSE и Push (после PLA)

PLA принят, App ID `com.pawga.fluffychat` и группа `group.com.pawga.fluffychat`
созданы. Entitlements и `groupId` в коде возвращены. Ниже — что ещё нужно
сделать на портале и зачем два «лишних» App ID.

### 6.1 Два App ID, которые не находятся отдельной кнопкой

iOS-приложение из этого репозитория — **три бинарника**, не один:

| Target в Xcode | Bundle ID | Зачем |
|---|---|---|
| Runner | `com.pawga.fluffychat` | Само приложение. Уже создан. |
| FluffyChat Share | `com.pawga.fluffychat.FluffyChat-Share` | Share sheet «Поделиться в FluffyChat». |
| Notification Service Extension | `com.pawga.fluffychat.Notification-Service-Extension` | Фоновый процесс: читает ту же БД и подставляет текст в уведомление. |

У каждого бинарника **свой** App ID. В портале нет пункта «Share» или «NSE».
Это обычные Identifiers → App IDs с другими Bundle ID.

**Рекомендуемый путь (уже подготовлен в git):** не создавать Share/NSE вручную.
Automatic Signing при `flutter run` увидит entitlements, зарегистрирует эти
два App ID и выпустит **explicit** профили (не wildcard `*`). Xcode может
спросить разрешение на регистрацию — согласиться.

**Ручной путь**, если хотите увидеть их в портале до сборки:

1. [Identifiers](https://developer.apple.com/account/resources/identifiers/list) → `+`.
2. **App IDs** → Continue → **App** → Continue.
3. Description: `FluffyChat Share`. Bundle ID: **Explicit** →
   `com.pawga.fluffychat.FluffyChat-Share`.
4. Capabilities: включить **App Groups** → Configure → отметить
   `group.com.pawga.fluffychat` → Save.
5. То же для NSE: Description `FluffyChat NSE`, Bundle ID
   `com.pawga.fluffychat.Notification-Service-Extension`, App Groups → та же
   группа.

Дефисы в Bundle ID обязательны: так записано в `project.pbxproj`.

### 6.2 App Groups уже привязаны. Push в портале выглядит иначе

Группа у `com.pawga.fluffychat` уже On и отмечена — этого достаточно для
контейнера. Дальше портал часто путает.

**Push Notifications** на современном Identifiers **часто без выключателя On**.
Вместо него — «Development SSL Certificate» и «Production SSL Certificate».
Это не «включить push в приложении». Это старый способ, которым **сервер**
(push gateway / ваш бэкенд) предъявляет TLS-сертификат службе APNs.

Для локального `flutter run` эти сертификаты **создавать не нужно**. Подпись
берёт entitlement `aps-environment` из `Runner.entitlements`; Xcode Automatic
Signing кладёт его в explicit-профиль. Сертификаты SSL понадобятся только
когда появится свой отправитель push (или вы сознательно выберете
cert-based APNs вместо ключа `.p8` в разделе Keys).

**Push to Talk** — другая capability (рация / walkie-talkie). У FluffyChat её
нет. Выключатель On у Push to Talk **не включать**.

Итого сейчас на портале для App ID приложения: App Groups с
`group.com.pawga.fluffychat` — готово; SSL-сертификаты Push — пропустить;
Push to Talk — выкл.

### 6.3 Что именно вернули в файлах

Это и есть «вернуть entitlements»: не кнопка в портале, а XML, который Xcode
кладёт в подпись.

`ios/Runner/Runner.entitlements` — Push + App Group. Associated Domains автора
(`applinks:example.com`) не возвращали.

`ios/FluffyChat Share/FluffyChat Share.entitlements` и
`ios/Notification Service Extension/Notification Service Extension.entitlements`
— только App Group.

`cipher.dart`:

```dart
const iosOptions = IOSOptions(groupId: 'group.com.pawga.fluffychat');
```

`builder.dart` и `NotificationService.swift` уже использовали этот group id;
fallback каталога БД оставлен, если контейнер вдруг недоступен.

После первой успешной подписи ключ SQLCipher, который успел записаться в
обычный keychain, мигрирует в группу (ветка `legacyPassword` в `cipher.dart`).
Файл БД копируется из Library в App Group (`_migrateLegacyLocation`).

Альтернатива «Signing & Capabilities → + Capability» в GUI Xcode делает то же
самое: дописывает те же ключи в `.entitlements`. Для Flutter удобнее держать
файлы в git и не открывать GUI, если Automatic Signing справляется.

### 6.4 Нужен ли Firebase для уведомлений

Коротко: **для этого iOS-клиента — да, свой Firebase**, плюс свой (или
самостоятельно поднятый) Matrix push gateway. Файла автора недостаточно.
UnifiedPush/ntfy в этом коде — путь **Android**, не iPhone.

Цепочка официального iOS FluffyChat:

```text
сообщение на Synapse
  → Synapse POST на push gateway (по умолчанию https://push.fluffychat.im/...)
  → gateway шлёт в Firebase Cloud Messaging
  → FCM на iOS всё равно идёт через APNs Apple
  → iPhone будит приложение / Notification Service Extension
  → NSE читает SQLCipher в App Group и подставляет текст
```

В этом дереве FCM **выключен**: строки с `//<GOOGLE_SERVICES>` в
`lib/utils/background_push.dart` закомментированы, `firebaseEnabled = false`.
Поэтому `setupFirebase()` сразу показывает предупреждение и **не регистрирует
pusher**. Entitlements Push только разрешают подпись, токен FCM из-за этого
не появляется. Автор включает FCM скриптом
`./scripts/add-firebase-messaging.sh` (CI App Store), не в публичном git по
умолчанию.

`ios/Runner/GoogleService-Info.plist` — проект автора `fluffychat-ef3e8`.
Локально в нём переписан `BUNDLE_ID` на `com.pawga.fluffychat`, но это всё
ещё **их** Firebase. Их gateway `push.fluffychat.im` умеет будить только
store-приложение `im.fluffychat.app`. Подставить свой Bundle ID в чужой
plist и ждать уведомления нельзя.

Когда решите делать push на учебном форке:

1. Свой проект Firebase → добавить iOS-приложение с Bundle ID
   `com.pawga.fluffychat` → скачать **свой** `GoogleService-Info.plist`.
2. В Firebase Cloud Messaging загрузить APNs Auth Key (`.p8`) с
   developer.apple.com → Keys (не SSL-сертификаты в карточке App ID).
3. `./scripts/add-firebase-messaging.sh` — раскомментирует FCM в Dart.
4. Свой Matrix push gateway (Sygnal / совместимый), которому известен **ваш**
   FCM, либо иной самописный шлюз. URL по умолчанию в настройках —
   `pushNotificationsGatewayUrl` = `https://push.fluffychat.im/_matrix/push/v1/notify`
   — для форка его нужно сменить.
5. У LAN Synapse должен быть исходящий HTTPS до этого gateway. Без этого
   сервер не докричится до телефона, даже если FCM настроен идеально.
   Подробнее: [`SYNAPSE_DEBIAN13_LAN_RU.md`](SYNAPSE_DEBIAN13_LAN_RU.md) §12.2.

Пока приложение открыто, сообщения идут обычным Matrix sync. Push нужен, когда
процесс убит или экран погашен.

Альтернатива «без Firebase, сразу APNs» в этом клиенте **не реализована**:
пришлось бы писать свой регистратор токена и gateway. Для форка это отдельная
задача, не упрощение текущего кода.

### 6.5 Долг: свой Firebase (авторский взять нельзя)

**Нельзя** «временно» включить нотификации в **FluffyChat Dev**, подставив
оригинальный `GoogleService-Info.plist`, `add-firebase-messaging.sh` и
`push.fluffychat.im`. Это не экономия, а нерабочая связка. Заменить «чуть позже
на свой Firebase» можно только после того, как свой стек появится; авторский
промежуточным шагом не служит.

Почему не склеивается:

| Слой | У автора (App Store) | У учебного стенда |
|---|---|---|
| Bundle ID | `im.fluffychat.app` | `com.pawga.fluffychat` |
| Apple Team | `4HV29TJN3A` | `H8XL8TZH7H` |
| Firebase | `fluffychat-ef3e8`, iOS-приложение на `im.fluffychat.app` | доступа к консоли автора нет |
| APNs | ключ `.p8` команды автора, topic = `im.fluffychat.app` | topic был бы `com.pawga.fluffychat` |
| Gateway | `https://push.fluffychat.im/_matrix/push/v1/notify` | шлёт только в FCM автора |

APNs доставляет push приложению с **совпадающими** Bundle ID и Team. Чужой
FCM-токен и чужой gateway не разбудят бинарник, подписанный вашей командой.
Вернуть Bundle ID `im.fluffychat.app` тоже нельзя: его нельзя подписать Team
`H8XL8TZH7H`.

Что **не** делать «на время»:

- не включать `./scripts/add-firebase-messaging.sh` с plist автора;
- не ждать, что правка `BUNDLE_ID` в чужом plist зарегистрирует приложение
  в их Firebase;
- не слать pusher LAN Synapse на `push.fluffychat.im` для FluffyChat Dev.

Как проверить push **сейчас**, без своего Firebase: официальный FluffyChat из
App Store на том же iPhone + LAN Synapse с исходящим HTTPS до
`push.fluffychat.im` (см. [`SYNAPSE_DEBIAN13_LAN_RU.md`](SYNAPSE_DEBIAN13_LAN_RU.md)
§12.2). Это другой бинарник, не эта сборка из git.

**Чеклист долга** (когда понадобятся уведомления у форка):

1. Свой проект Firebase, iOS-приложение `com.pawga.fluffychat`, свой
   `GoogleService-Info.plist` вместо файла в `ios/Runner/` (сейчас там проект
   автора `fluffychat-ef3e8` с локально переписанным Bundle ID — не использовать
   как рабочий FCM).
2. APNs Auth Key `.p8` Team `H8XL8TZH7H` загрузить в этот Firebase.
3. `./scripts/add-firebase-messaging.sh` — включить `fcm_shared_isolate` и снять
   `//<GOOGLE_SERVICES>` в `background_push.dart`.
4. Свой Matrix push gateway с серверными ключами **вашего** FCM; в настройках
   клиента сменить `pushNotificationsGatewayUrl` с `https://push.fluffychat.im/...`.
5. Исходящий HTTPS с LAN Synapse до этого gateway.
6. Проверить: закрыть `--profile`/`--release` сборку, отправить сообщение со
   второго устройства, прийти должен APNs + NSE (App Group уже включён).

Пока долг открыт, у FluffyChat Dev ожидаемо нет фоновых нотификаций. Открытое
приложение по-прежнему синхронизируется по Matrix.

### 6.6 Ошибка `BGTaskSchedulerErrorDomain Code=3`

```text
Could not schedule app refresh: Unrecognized Identifier=com.pravera.flutter_foreground_task.refresh
```

Плагин `flutter_foreground_task` на iOS регистрирует фоновое обновление со
строгим id `com.pravera.flutter_foreground_task.refresh`. iOS принимает только
id из `BGTaskSchedulerPermittedIdentifiers` в `Info.plist`. Code=3 =
`notPermitted`: id нет в списке.

Upstream туда кладёт `im.fluffychat.app` (Bundle ID), не id плагина — та же
ошибка есть и у автора. Для стенда в список добавлен id плагина (и оставлен
`com.pawga.fluffychat`). После пересборки сообщение должно пропасть. Это не
push и не login: плагин пытается продлить работу в фоне ~30 с раз в ~15 мин.
Login к Synapse от этого не зависит.


---

## 7. Команды повторной сборки

Инструменты один раз:

```bash
brew install cmake ninja
# rustup — по README автора; для текущего iOS+SPM не блокер
```

После обновления пакетов или `flutter pub cache repair`:

```bash
cd /Users/sivannikov/FlutterPrograms/fluffychat
flutter pub get
./scripts/apply-webcrypto-ios-x64-patch.sh   # нужно только Intel Simulator
```

Симулятор (Intel):

```bash
flutter run -d "iPhone 17 Pro"
```

Устройство (кабель, Developer Mode, разблокирован):

```bash
flutter devices   # список; для этого стенда iPhone Sergey = 00008150-000268DE3CB8401C
flutter run -d 00008150-000268DE3CB8401C --debug    # JIT, только пока кабель и отладчик
flutter run -d 00008150-000268DE3CB8401C --profile  # AOT, иконка живёт после закрытия
flutter run -d 00008150-000268DE3CB8401C --release  # AOT, как «боевая» debug-установка
```

Имя устройства тоже можно: `-d "iPhone Sergey"`, если оно одно в списке.

### 7.1 Три режима Flutter (для любого проекта)

Одинаково для FluffyChat и других приложений: `debug` / `profile` / `release`.
На физическом iPhone отличаются не «можно ли поставить», а **чем скомпилирован Dart**.

| | `--debug` (по умолчанию) | `--profile` | `--release` |
|---|---|---|---|
| Компиляция Dart | **JIT** (виртуальная машина) | **AOT** (нативный ARM64) | **AOT** (нативный ARM64) |
| Поставить на свой iPhone | да, с кабелем | да | да |
| Запуск с иконки без Mac | нет (iOS убивает JIT без отладчика) | да | да |
| Hot reload / hot restart | да | нет | нет |
| DevTools / таймлайн | полный | да, для профилирования | нет |
| Скорость, размер | самый медленный и большой | близко к release | самый быстрый |
| Зачем | писать и отлаживать код | потыкать как пользователь + замерить FPS | «как будет у людей», без отладки |

**AOT** (ahead-of-time) — Dart заранее превращается в машинный код, как обычное
нативное iOS-приложение. **JIT** (just-in-time) — код компилируется во время
работы; на iPhone это разрешено только отлаживаемому процессу.

Android такого запрета на JIT нет: debug с иконки открывается. На iPhone для
«поставил и пользуюсь» нужны `--profile` или `--release`. Это не обход защиты
и не отдельный тип сертификата: та же подпись Team, тот же Bundle ID.

`00008150-000268DE3CB8401C` — **UDID этого iPhone** (идентификатор устройства
в Xcode / `flutter devices`), не Bundle ID приложения. В другом проекте
смотрите свой список:

```bash
flutter devices
# или: xcrun devicectl list devices
```

Команда по частям:

```text
flutter run
  -d 00008150-000268DE3CB8401C   # куда ставить (этот телефон)
  --profile                     # какой режим собрать
```

`flutter run` = собрать + установить + запустить. После успеха можно отключить
кабель; profile/release останутся на SpringBoard.

Только собрать без запуска:

```bash
flutter build ios --profile
flutter build ios --release
```

Потом поставить уже собранное: `flutter install -d <id>`.

Первая `--profile`/`--release` заметно дольше debug: AOT компилирует весь Dart.
Подпись, Developer Mode и доверие сертификату те же, что для debug.

Не запускайте вторую Xcode-сборку параллельно: `database is locked`.

Debug-сборку **не** ставьте через `simctl launch` без `flutter run`: без
привязки Dart VM на симуляторе уже был белый экран после системного диалога.

На устройстве приложение называется **FluffyChat Dev**. Если iOS спросит
«Доверять разработчику»: Настройки → Основные → VPN и управление устройством.

---

## 8. Чего этот стенд сознательно не делает

- Не публикует IPA в App Store / TestFlight.
- Не использует Team и Bundle ID автора.
- Не одалживает Firebase/gateway автора для FluffyChat Dev — это не работает
  (долг: свой FCM, §6.5). Пока долг открыт, фоновых нотификаций у этой сборки нет.
  Проверка push — официальным клиентом из App Store, не этим бинарником.
- Не считает LAN Synapse полноценной заменой push-инфраструктуры Matrix.
- Не фиксирует в git содержимое `~/.pub-cache`. Патч живёт в
  `patches/` + `scripts/`, применяется к кэшу.

Когда форк станет отдельным приложением, имеет смысл завести **свои** Bundle ID
с первого дня, принять PLA, включить App Groups/Push штатно и выкинуть
wildcard-профиль из процесса. Патч `webcrypto` к тому моменту либо уйдёт в
upstream, либо останется скриптом только для Intel-симулятора.
