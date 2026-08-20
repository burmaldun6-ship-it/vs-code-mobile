# Материалы исследования: code-server → Android (WebView + Node.js)

Исследование ограничений и проблем портирования code-server/VS Code на нативное Android-приложение.

## Содержание

| # | Файл | Тема |
|---|------|------|
| 1 | [01-runtime-and-processes.md](01-runtime-and-processes.md) | Runtime и процессы (child_process, Phantom Killer, Node.js embedded) |
| 2 | [02-native-modules.md](02-native-modules.md) | Нативные модули (кросс-компиляция, POSIX, ABI) |
| 3 | [03-filesystem.md](03-filesystem.md) | Файловая система (Scoped Storage, Unix пути, symlinks) |
| 4 | [04-network-ipc.md](04-network-ipc.md) | Сеть и IPC (localhost, WebSocket) |
| 5 | [05-platform-detection.md](05-platform-detection.md) | Platform detection и совместимость расширений |
| 6 | [06-ui-webview.md](06-ui-webview.md) | UI и WebView (hotkeys, touch, perf) |
| 7 | [07-build-distribution.md](07-build-distribution.md) | Сборка и дистрибуция (APK size, updates) |
| 8 | [08-debugging-monitoring.md](08-debugging-monitoring.md) | Отладка и мониторинг |
| 9 | [09-git-terminal.md](09-git-terminal.md) | Git и терминал |
| 10 | [10-security.md](10-security.md) | Безопасность |

## Ключевые выводы

### Критические решения
1. **child_process** — полностью заменить на `worker_threads` (nodejs-mobile не поддерживает fork/spawn)
2. **Phantom Process Killer** — решается архитектурно через отказ от дочерних процессов
3. **Node.js runtime** — использовать `nodejs-mobile` или кастомный `libnode.so`
4. **process.platform** — патчить на `'linux'` через `android-as-linux.js`
5. **node-pty** — использовать `node-pty-android-arm64`
6. **Git** — использовать `wasm-git` (libgit2 в WebAssembly)
7. **WebSocket** — TCP localhost с `listen(0)` для рандомного порта
8. **Файловая система** — внутреннее хранилище (ext4) для рабочих файлов
9. **Безопасность** — Node.js Permission Model + Landlock + token auth
10. **Размер APK** — тонкий APK (~20MB) + скачивание runtime при первом запуске

### Рекомендуемая архитектура
```
Android APK (~20MB)
  WebView shell
  Download manager
  Минимальный Node.js launcher
      |
      v (первый запуск)
Скачиваемый Runtime (~50-80MB)
  libnode.so (arm64, stripped)
  VS Code web assets
  Pre-installed extensions
      |
      v (on-demand)
Пользовательские расширения
```

### Источники
- nodejs-mobile documentation
- code-server Termux docs
- termux-packages repository
- ovalRaptor/VSCodeOnAndroid
- codebian (PoC)
- wasm-git project
- Android developer documentation
