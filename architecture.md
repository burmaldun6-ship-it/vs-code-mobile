# Архитектура: code-server → нативное Android-приложение

> **⚠️ Важно:** Этот документ — **черновик и отправная точка**, а не финальная архитектура. Некоторые решения могут оказаться неоптимальными, избыточными или вовсе неверными. Компоненты и их взаимодействие описаны на основе текущего понимания задачи и требуют валидации. **Не используй как догму.**

---

## 1. Общая концепция

Приложение представляет собой **единый Android APK**, внутри которого работают два основных компонента:

1. **WebView** — отрисовывает VS Code Web UI (frontend code-server).
2. **Node.js Runtime** — встроен как `libnode.so`, выполняет VS Code Server backend (code-server core + Extension Host).

Коммуникация между ними — через **HTTP/WebSocket** (localhost или Unix socket).

---

## 2. Структура проекта

```
code-server-android/
├── android/                          # Android Studio проект
│   ├── app/
│   │   ├── src/main/
│   │   │   ├── java/com/codeserver/
│   │   │   │   ├── MainActivity.java          # Entry point, WebView init
│   │   │   │   ├── NodeService.java           # Foreground Service для Node.js
│   │   │   │   ├── FileSystemBridge.java      # JNI: Android FS ↔ Node.js fs
│   │   │   │   ├── ProcessBridge.java         # JNI: spawn/fork emulation
│   │   │   │   └── WebViewClient.java         # Custom WebViewClient
│   │   │   ├── cpp/
│   │   │   │   ├── nodejs_bridge.cpp          # JNI ↔ libnode.so
│   │   │   │   ├── fs_bridge.cpp              # File system proxy
│   │   │   │   └── pty_bridge.cpp             # PTY emulation layer
│   │   │   ├── assets/
│   │   │   │   ├── vscode-web/                # Статика VS Code Web UI
│   │   │   │   ├── node_modules_bundled/      # Core node_modules (code-server)
│   │   │   │   └── extensions_builtin/        # Встроенные расширения
│   │   │   └── jniLibs/
│   │   │       ├── arm64-v8a/
│   │   │       │   ├── libnode.so             # Node.js runtime
│   │   │       │   ├── libpty.so              # PTY layer (optional)
│   │   │       │   └── libgit2.so             # Git library (optional)
│   │   │       └── armeabi-v7a/
│   │   │           └── ...
│   │   └── build.gradle
│   └── gradle/
│
├── nodejs/                           # Node.js layer
│   ├── src/
│   │   ├── server.js                 # Entry point: стартует code-server
│   │   ├── android-shim.js           # Polyfills: process.platform, fs, etc.
│   │   ├── process-emulator.js       # child_process → worker_threads bridge
│   │   ├── fs-native-proxy.js        # Прокси fs вызовов в JNI
│   │   └── socket-server.js          # HTTP/WebSocket server (code-server wrapper)
│   ├── patches/
│   │   ├── vscode-extensionHost.patch   # fork → Worker Thread
│   │   ├── vscode-spdlog.patch          # spdlog Android build
│   │   ├── vscode-nsfw.patch            # inotify → Android FileObserver
│   │   └── node-pty-android.patch       # PTY Android adaptation
│   └── package.json
│
├── native-modules/                   # Сборка нативных модулей
│   ├── build-scripts/
│   │   ├── android-gyp.sh            # node-gyp wrapper для Android NDK
│   │   ├── build-all.sh              # Batch build топ-N модулей
│   │   └── fetch-sources.sh          # Скачивание исходников модулей
│   ├── prebuilt/
│   │   ├── arm64-v8a/
│   │   │   ├── spdlog.node.so
│   │   │   ├── node-pty.node.so
│   │   │   └── ...
│   │   └── armeabi-v7a/
│   └── recipes/                      # binding.gyp patches для каждого модуля
│
├── extensions/                       # Управление расширениями
│   ├── whitelist.json                # Список совместимых/проверенных расширений
│   ├── compatibility-checker.js      # Проверка расширения перед установкой
│   └── downloader.js                 # Скачивание .vsix из OpenVSX
│
├── tools/
│   ├── bundle-vscode-web.sh          # Экстракция статики из code-server
│   ├── strip-node-modules.sh         # Удаление devDependencies, уменьшение размера
│   └── sign-apk.sh                   # Скрипт сборки и подписи APK
│
└── docs/                             # Дополнительная документация
    └── (этот файл + limitations.md)
```

---

## 3. Компоненты и их роли

### 3.1 Android Layer (Java/Kotlin + JNI)

| Компонент | Технология | Роль |
|-----------|-----------|------|
| `MainActivity` | Java | Инициализация WebView, запуск NodeService, обработка intent (открытие файлов) |
| `NodeService` | Java (Foreground Service) | Держит Node.js процесс живым, управляет жизненным циклом |
| `FileSystemBridge` | Java + JNI | Прокси между Node.js `fs` и Android Storage API (SAF / scoped storage) |
| `ProcessBridge` | Java + JNI | Эмуляция `child_process` через Java `Runtime.exec()` или Worker Threads |
| `WebViewClient` | Java | Intercept URL, inject JS bridge, handle file:// vs http:// |
| `nodejs_bridge.cpp` | C++ (JNI) | Старт/стоп Node.js runtime, передача аргументов, event loop integration |
| `fs_bridge.cpp` | C++ (JNI) | Низкоуровневые файловые операции, обход ограничений scoped storage |
| `pty_bridge.cpp` | C++ (JNI) | PTY эмуляция через `/dev/ptmx` или termios workaround |

### 3.2 Node.js Layer

| Компонент | Технология | Роль |
|-----------|-----------|------|
| `server.js` | Node.js | Entry point. Стартует VS Code Server, настраивает environment |
| `android-shim.js` | Node.js | Polyfills: `process.platform = 'linux'`, `os.homedir()`, `os.tmpdir()`, `fs` patches |
| `process-emulator.js` | Node.js | Перехват `child_process.fork/spawn`. Внутрипроцессная эмуляция через Worker Threads |
| `fs-native-proxy.js` | Node.js | Перехват `fs.*` вызовов, проксирование в JNI для SAF/scoped storage |
| `socket-server.js` | Node.js | HTTP + WebSocket server. Code-server core wrapper |

### 3.3 Web Layer

| Компонент | Технология | Роль |
|-----------|-----------|------|
| VS Code Web UI | TypeScript/React | Стандартный frontend code-server, загружается из `assets/vscode-web/` |
| WebSocket Client | JS (встроенный) | Коммуникация с backend: extension host protocol, file operations |

---

## 4. Потоки данных

### 4.1 Запуск приложения

```
[MainActivity.onCreate]
    │
    ├──► [WebView setup] ──► загружает http://localhost:PORT (или file:// + WS)
    │
    └──► [NodeService.start()]
            │
            └──► [JNI: nodejs_bridge.cpp]
                    │
                    └──► [libnode.so] ──► [server.js]
                                                │
                                                ├──► [android-shim.js] ──► polyfills
                                                ├──► [socket-server.js] ──► HTTP/WS server
                                                └──► [code-server core] ──► VS Code backend
```

### 4.2 Открытие файла

```
[Пользователь открывает файл через SAF picker]
    │
    ├──► [MainActivity] получает Document URI
    │
    ├──► [FileSystemBridge] резолвит URI → виртуальный путь
    │
    ├──► [JNI → fs_bridge.cpp] → [fs-native-proxy.js]
    │
    └──► [VS Code Server] видит файл через прокси fs
            │
            └──► [Extension Host] → Language Server (in-process Worker)
```

### 4.3 Extension Host (fork → Worker)

```
[VS Code core] хочет fork Extension Host
    │
    ├──► [process-emulator.js] перехватывает fork()
    │
    ├──► Вместо child_process.fork() создаёт Worker Thread
    │
    ├──► Worker загружает extensionHostProcess.js
    │
    └──► Communication: parentPort.postMessage() ↔ process.send()
```

### 4.4 Language Server (spawn → in-process)

```
[VS Code] хочет spawn('typescript-language-server')
    │
    ├──► [process-emulator.js] перехватывает spawn()
    │
    ├──► Проверяет whitelist: можно ли запустить in-process?
    │
    ├──► Да: загружает модуль напрямую через require(), создаёт FakeChildProcess
    │
    └──► Нет: fallback на ProcessBridge → Java Runtime.exec() (если бинарник под Android)
```

---

## 5. Ключевые решения (с оговорками)

### 5.1 Node.js runtime: nodejs-mobile vs custom build

**Выбрано:** nodejs-mobile (`libnode.so`)

- **Почему:** Готовая библиотека, поддерживает arm64/armv7/x86, уже используется в продакшене.
- **Риски:** Версия Node.js может отставать от LTS. Нативные модули нужно собирать под ту же версию V8/Node-API.
- **Альтернатива:** Собрать Node.js из исходников под Android NDK. Дает контроль, но требует глубокой экспертизы.

### 5.2 Процессы vs Threads

**Выбрано:** Отказ от `child_process` в пользу `worker_threads` + in-process modules

- **Почему:** Обход phantom process killer, меньше оверхеда, проще IPC.
- **Риски:** Крэш в одном Worker/модуле убивает весь Node.js. Нет изоляции памяти. Нативные модули с thread-unsafe кодом могут segfault.
- **Альтернатива:** Гибрид: JS-only LS → in-process, нативные LS → отдельный процесс с ограничением количества.

### 5.3 Файловая система: прокси vs прямой доступ

**Выбрано:** JNI-прокси для SAF + scoped storage

- **Почему:** Соответствует Android security model, работает на Android 10+ без `MANAGE_EXTERNAL_STORAGE`.
- **Риски:** Производительность ниже нативного fs. Некоторые операции (watch, symlink) не поддерживаются.
- **Альтернатива:** Запросить `MANAGE_EXTERNAL_STORAGE` + работать с raw paths. Проще, но Google Play может отклонить.

### 5.4 Коммуникация: TCP localhost vs Unix socket

**Выбрано:** TCP localhost (127.0.0.1:динамический_порт)

- **Почему:** Простота, VS Code Web UI ожидает HTTP/WebSocket URL.
- **Риски:** Другие приложения могут подключиться к порту. Нужна аутентификация или firewall.
- **Альтернатива:** Unix Domain Socket + прокси в WebView через `shouldInterceptRequest`. Безопаснее, но сложнее в реализации.

### 5.5 Расширения: встроенные vs downloadable

**Выбрано:** Встроенные core extensions + downloadable из OpenVSX с whitelist

- **Почему:** Контроль совместимости, можно предварительно проверить/собрать нативные модули.
- **Риски:** Пользователь не может установить любое расширение. Ограничение функциональности.
- **Альтернатива:** Разрешить любые extensions, но с runtime-check на нативные зависимости. Больше свободы, но нестабильность.

---

## 6. Сборочный pipeline

```
1. Подготовка Node.js runtime
   └── Скачать/собрать libnode.so под target ABI

2. Подготовка VS Code Web UI
   └── Запустить code-server build → извлечь static assets
   └── Скопировать в android/app/src/main/assets/vscode-web/

3. Подготовка Node.js backend
   └── npm install code-server в nodejs/
   └── Применить patches/ (extensionHost, spdlog, nsfw, node-pty)
   └── Удалить devDependencies, минифицировать
   └── Скопировать в android/app/src/main/assets/node_modules_bundled/

4. Сборка нативных модулей
   └── Для каждого модуля из whitelist:
       └── Применить recipe (binding.gyp patch)
       └── Собрать через android-gyp.sh (NDK cross-compile)
       └── Скопировать .so в jniLibs/<abi>/

5. Сборка Android APK
   └── Android Studio / Gradle
   └── Bundle AAB (App Bundle) для Play Store
   └── Или APK для sideload

6. Тестирование
   └── Эмулятор (Android Studio)
   └── Физическое устройство (arm64)
   └── Logcat + Node.js inspector
```

---

## 7. Известные проблемы архитектуры

1. **Единая точка отказа:** Все компоненты в одном процессе Node.js. Segfault = краш всего приложения.
2. **Размер:** Даже с оптимизациями APK будет 100+ MB. Dynamic delivery не решит проблему полностью.
3. **Обновления:** Обновление VS Code / code-server требует пересборки всего pipeline.
4. **Совместимость:** Не все расширения заработают. Нужен механизм graceful degradation.
5. **Performance:** WebView на слабых Android-устройствах может не тянуть VS Code UI.
6. **Memory:** Node.js + WebView + Language Servers в одном приложении = риск OOM на устройствах с 4GB RAM.

---

## 8. Возможные альтернативные архитектуры (не расследованы)

- **Chromium Embedded Framework (CEF)** вместо WebView — лучше performance, но +100MB к APK.
- **Hermes/JSI** вместо полного Node.js — если backend можно переписать на чистом JS без Node API.
- **WebAssembly** для Language Servers — компилировать LSP в WASM, запускать в WebView. Изоляция + безопасность, но сложность сборки.
- **Termux API** — использовать Termux как backend, а приложение как frontend wrapper. Уже работает, но не "нативное".

---

*Файл составлен как черновик для обсуждения и доработки. Любое решение здесь может быть пересмотрено после глубокого анализа и прототипирования.*
