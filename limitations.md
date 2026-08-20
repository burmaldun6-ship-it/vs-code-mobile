# Ограничения и проблемы: code-server → нативное Android-приложение (WebView + Node.js)

> **Примечание:** Этот файл составлен на основе текущего понимания архитектуры. Список не исчерпывающий, некоторые пункты могут оказаться несущественными, а критичные проблемы могут быть упущены. Используй как отправную точку для поиска решений.Для поиска решения проблем используй интернет,конечно же

---

## 1. Runtime и процессы

### 1.1 Отсутствие полноценного `child_process`
- Android не является POSIX-системой в полном смысле. `fork()`/`exec()` работают ограниченно или не работают внутри обычного APK-контекста.
- VS Code Extension Host запускается через `child_process.fork()`.
- Language Servers (TypeScript, Python, Rust и др.) запускаются через `child_process.spawn()`.
- **Вопрос:** Как обеспечить запуск и коммуникацию с дочерними процессами внутри одного Android-приложения? Можно ли заменить `fork/spawn` на `worker_threads` без потери функциональности?

### 1.2 Phantom Process Killer (Android 12+)
- Google ограничивает количество дочерних процессов в фоне (обычно 32).
- При превышении лимита система жёстко убивает приложение.
- **Вопрос:** Какие есть способы обойти ограничение без root? Можно ли архитектурно отказаться от дочерних процессов в пользу потоков?

### 1.3 Node.js как встроенная библиотека
- Нужно встроить `libnode.so` (например, из nodejs-mobile) в APK.
- Node.js ожидает стандартную файловую структуру (`/usr/lib/node_modules` и т.д.), которой нет на Android.
- **Вопрос:** Как корректно инициализировать Node.js runtime внутри Android-приложения? Как задать `NODE_PATH`, `prefix` и другие переменные окружения?

---

## 2. Нативные модули (C++ addons)

### 2.1 Кросс-компиляция `.node` → `.so` под Android
- VS Code и расширения используют нативные модули: `spdlog`, `node-pty`, `native-is-elevated`, `vscode-nsfw`, `keytar` и др.
- `.node` файлы — это ELF shared libraries, скомпилированные под хост-платформу (Linux x64 / macOS / Windows).
- **Вопрос:** Как автоматизировать сборку нативных модулей под Android NDK (arm64-v8a)? Есть ли готовые тулчейны или патчи для `node-gyp` под Android?

### 2.2 Отсутствие или ограниченность POSIX-API на Android
- `node-pty` требует PTY (`/dev/ptmx`, `openpty`). Android имеет ограниченную поддержку.
- Некоторые модули используют `inotify` (`vscode-nsfw`) — заменяется ли `inotify` на Android-специфичные механизмы?
- **Вопрос:** Какие нативные модули точно сломаются на Android? Есть ли альтернативные реализации (например, `node-pty` через Termux-совместимый слой)?

### 2.3 Архитектурные ABI
- Android устройства: `arm64-v8a`, `armeabi-v7a`, `x86_64`.
- Нужно либо собирать под все ABI, либо ограничиться `arm64-v8a`.
- **Вопрос:** Как минимизировать размер APK при наличии нескольких `.so` под разные архитектуры? Поддерживает ли App Bundle разделение по ABI?

---

## 3. Файловая система

### 3.1 Scoped Storage (Android 10+)
- Прямой доступ к `/sdcard`, `/storage/emulated/0` ограничен.
- `MANAGE_EXTERNAL_STORAGE` — требует специального разрешения.
- SAF (Storage Access Framework) — URI-based, не файловые пути.
- **Вопрос:** Как проксировать Android SAF / scoped storage в Node.js `fs` API? Нужен ли JNI-мост или можно обойтись `DocumentFile` + ContentResolver?

### 3.2 Отсутствие стандартных Unix-путей
- Нет `/home`, `/tmp`, `/usr/local`.
- Node.js и VS Code ожидают эти пути для кэша, конфигов, extensions.
- **Вопрос:** Какие директории в Android-приложении можно использовать как замену? `getFilesDir()`, `getCacheDir()`, `getNoBackupFilesDir()` — какие подходят под что?

### 3.3 Символические ссылки
- FAT32/exFAT на SD-картах не поддерживают symlinks.
- `node_modules` с `bin` ссылками может сломаться.
- **Вопрос:** Как Node.js ведёт себя с symlink на Android? Нужно ли патчить `npm`/`yarn` для копирования вместо symlink?

---

## 4. Сеть и IPC

### 4.1 Localhost внутри APK
- WebView ↔ Node.js общаются через HTTP/WebSocket.
- `localhost:8080` может быть занят другим приложением.
- **Вопрос:** Можно ли использовать Unix Domain Socket вместо TCP-порта? Поддерживает ли WebView загрузку через `file://` с WebSocket на Unix socket?

### 4.2 WebSocket в WebView
- Нужно убедиться, что Android WebView поддерживает WebSocket для VS Code server communication.
- **Вопрос:** Есть ли известные ограничения WebSocket в Android WebView? Какая минимальная версия Android WebView требуется?

---

## 5. Platform detection и совместимость расширений

### 5.1 `process.platform === 'android'` — не существует
- VS Code проверяет `process.platform`. На Android через nodejs-mobile это может быть `'android'` или `'linux'`.
- Многие расширения отключают функциональность, если платформа не Linux/macOS/Windows.
- **Вопрос:** Как корректно замаскировать платформу? Какие побочные эффекты от `process.platform = 'linux'` на Android?

### 5.2 Несовместимые расширения
- Расширения, зависящие от внешних бинарников (`clangd`, `python`, `docker`) — не будут работать без их портирования.
- **Вопрос:** Как определить, какие расширения точно не заработают? Можно ли сделать sandbox/whitelist совместимых расширений?

---

## 6. UI и WebView

### 6.1 Keyboard shortcuts
- VS Code использует `Ctrl/Cmd+Key`. Android — физическая клавиатура редкость, но для DeX/планшетов критично.
- **Вопрос:** Как перехватывать системные хоткеи Android в WebView? Конфликтуют ли они с системными (например, `Ctrl+Tab`)?

### 6.2 Touch vs Mouse
- VS Code не оптимизирован под touch.
- Context menu, drag-and-drop, resize панелей — работают плохо на touch.
- **Вопрос:** Есть ли готовые патчи для touch-оптимизации VS Code Web? Нужно ли писать кастомный input layer?

### 6.3 Performance
- WebView на Android медленнее десктопного Chrome.
- Большие файлы, syntax highlighting, tree view — могут лагать.
- **Вопрос:** Какие оптимизации WebView (hardware acceleration, offscreen rendering) применимы? Есть ли лимиты памяти на WebView процесс?

---

## 7. Сборка и дистрибуция

### 7.1 Размер APK
- Node.js runtime + VS Code web assets + extensions = сотни мегабайт.
- **Вопрос:** Какие техники уменьшения размера применимы? Dynamic delivery? Downloadable extensions? Split APK?

### 7.2 Обновления
- VS Code обновляется часто. Code-server — тоже.
- **Вопрос:** Как обновлять Node.js backend и web assets без полной пересборки APK? OTA-обновления безопасны?


---

## 8. Отладка и мониторинг

### 8.1 Отладка Node.js внутри APK
- Нет доступа к консоли, `chrome://inspect` работает только для WebView, не для встроенного Node.js.
- **Вопрос:** Как подключить DevTools/inspector к Node.js, запущенному через `libnode.so`? Поддерживает ли nodejs-mobile `--inspect`?

### 8.2 Crash reporting
- Нативные краши (segfault в C++ addon) убивают всё приложение.
- **Вопрос:** Какие механизмы crash reporting доступны для C++ кода в Android? 

---

## 9. Git и терминал

### 9.1 Git
- VS Code использует встроенный Git или системный `git`.
- Android не имеет системного Git.
- **Вопрос:** Можно ли встроить `libgit2` через Node.js binding? Или собрать статический `git` бинарник под Android?

### 9.2 Терминал
- `node-pty` — основа встроенного терминала VS Code.
- **Вопрос:** Есть ли работающие альтернативы `node-pty` на Android? Можно ли использовать Termux-API или эмулировать PTY через JNI?

---

## 10. Безопасность

### 10.1 Запуск произвольного кода
- VS Code extensions могут выполнять произвольный JavaScript и Node.js код.
- В APK это означает доступ к файловой системе приложения.
- **Вопрос:** Как изолировать extensions? Можно ли ограничить `require()` только вайтлистом модулей?

### 10.2 Localhost exposure
- Если Node.js слушает TCP-порт, другие приложения на устройстве могут подключиться.
- **Вопрос:** Как ограничить доступ к Node.js server только WebView приложения? Unix socket + file permissions?

---
*Может содержать неточности и неполноту.*
