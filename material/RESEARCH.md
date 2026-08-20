# VS Code Mobile

Порт code-server / VS Code на нативное Android-приложение (WebView + встроенный Node.js).

---

Port of code-server / VS Code to a native Android app (WebView + embedded Node.js).

---

## Текущий статус / Current Status

Исследование завершено. Определены все критические ограничения и проверенные решения для каждого блока архитектуры.

Research complete. All critical limitations identified with proven solutions for each architecture block.

## Что изучено / What was researched

| Блок | Решение | Status |
|------|---------|--------|
| **Runtime** | `nodejs-mobile` (libnode.so) + `worker_threads` вместо `child_process` | Решено |
| **Phantom Process Killer** | Архитектурно — нет дочерних процессов, нет лимита | Решено |
| **Нативные модули** | Кросс-компиляция через NDK, `node-pty-android-arm64` | Решено |
| **Файловая система** | Внутреннее хранилище (ext4) для проектов, `MANAGE_EXTERNAL_STORAGE` для доступа к файлам | Решено |
| **Сеть** | TCP localhost с `listen(0)`, WebSocket в WebView | Решено |
| **Платформа** | `android-as-linux.js` патч `process.platform` на `'linux'` | Решено |
| **UI/Touch** | `"keyboard.dispatch": "keyCode"`, touch-патчи | Решено |
| **Размер APK** | Тонкий APK (~20MB) + скачивание runtime при первом запуске | Решено |
| **Git** | `wasm-git` (libgit2 в WebAssembly) | Решено |
| **Терминал** | `node-pty-android-arm64` + `xterm.js` | Решено |
| **Безопасность** | Node.js Permission Model + token auth + filesystem socket | Решено |
| **Отладка** | `adb forward` + inspector (debug), logcat (prod) | Решено |

## Архитектура / Architecture

```
Android APK (~20MB)
  WebView shell + Node.js launcher
      |
      v (первый запуск / first launch)
Runtime (~50-80MB)
  libnode.so (arm64) + VS Code web + extensions
      |
      v (on-demand)
Пользовательские расширения / User extensions
```

## Структура проекта / Project Structure

```
vs-code-mobile/
├── material/           # Исследование / Research materials
│   ├── README.md       # Индекс / Index
│   ├── 01-*.md         # Runtime и процессы
│   ├── 02-*.md         # Нативные модули
│   ├── 03-*.md         # Файловая система
│   ├── 04-*.md         # Сеть и IPC
│   ├── 05-*.md         # Platform detection
│   ├── 06-*.md         # UI и WebView
│   ├── 07-*.md         # Сборка и дистрибуция
│   ├── 08-*.md         # Отладка
│   ├── 09-*.md         # Git и терминал
│   └── 10-*.md         # Безопасность
└── .gitignore
```

## Ключевые ссылки / Key References

- [nodejs-mobile](https://github.com/nodejs-mobile/nodejs-mobile) — встроенный Node.js для Android
- [codebian](https://github.com/brian200508/codebian) — PoC code-server как Android APK
- [wasm-git](https://github.com/petersalomonsen/wasm-git) — libgit2 в WebAssembly
- [node-pty-android-arm64](https://github.com/DioNanos/node-pty-android-arm64) — PTY для Android
- [code-server Termux docs](https://coder.com/docs/code-server/termux) — официальная инструкция

---

*Материалы исследования based на анализе ограничений архитектуры code-server → Android WebView + Node.js.*

*Research materials based on analysis of code-server → Android WebView + Node.js architecture limitations.*
