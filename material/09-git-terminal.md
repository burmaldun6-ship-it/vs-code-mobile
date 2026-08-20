# 9. Git и терминал

## 9.1 Git на Android

### Вариант A: Системный Git через Termux (рекомендуется для полного git)
Termux предоставляет полностью рабочий пакет `git` (`pkg install git`).

- **Статус:** Работает сегодня, проверено
- **Ограничение:** Git не работает на `/sdcard` (ограничения FS Android)
- **Обходной путь:** Симлинк из внутреннего хранилища к папкам sdcard
- **Источник:** [code-server termux docs](https://coder.com/docs/code-server/termux)

### Вариант B: wasm-git (libgit2 скомпилированный в WebAssembly)
**Пакет:** `wasm-git` на npm (839 звёзд, на базе libgit2 v1.9.4)

- **Как работает:** libgit2 скомпилирован в WebAssembly через Emscripten. Работает в Node.js или браузере
- **Плюсы:** Не нужна нативная компиляция, нет зависимости от системного git, кросс-платформенность
- **Минусы:** Overhead производительности (WASM), неполное покрытие git CLI, персистентность через MEMS/IDBFS/NODEFS/OPFS
- **Варианты:** Sync, Async, OPFS (pthreads, JSPI, ASYNCIFY), auto-loader
- **Источник:** [github.com/petersalomonsen/wasm-git](https://github.com/petersalomonsen/wasm-git)

**Вероятно лучший подход для встраивания git в Node.js Android приложение.** Обеспечивает clone, add, commit, push, pull, branch операции без системного git.

### Вариант C: nodegit (нативный libgit2 binding для Node.js)
- **Статус:** Официальные Node.js bindings для libgit2
- **Проблема:** Нативный модуль требует компиляции против Android/Bionic. Нет предсобранных Android бинарников
- **Вероятно нежизнеспособен** без значительной инфраструктуры сборки

### Вариант D: Статический git бинарник для Android
- Система сборки пакетов Termux может компилировать git из исходников
- XDA Forums хостят статические ARM бинарники, скомпилированные против musl-libc

### Рекомендация для Git
**Основной:** Использовать `wasm-git` для встроенных git операций. Не требует системного git, работает в userspace.

**Фоллбэк:** Бандлить предсобранный статический git бинарник для операций, которые wasm-git не покрывает хорошо (сложные merge, SSH).

---

## 9.2 Терминал

### Проблема
Встроенный терминал VS Code зависит от `node-pty`, который использует `forkpty(3)` — POSIX PTY API. Android предоставляет те же POSIX PTY syscall'ы (`openpty`, `forkpty`), поэтому syscall'ы работают. Барьер в том, что `node-pty` никогда не публиковал Android-specific сборки.

### Вариант A: node-pty-android-arm64 (проверенное решение)
**Пакет:** `node-pty-android-arm64` на npm

- **Статус:** Рабочий форк специально для Termux/Android ARM64
- **Установка:** `npm install node-pty-android-arm64`
- **Алиас:** `npm install node-pty@npm:node-pty-android-arm64` (сохраняет `require('node-pty')`)
- **Зависимости сборки в Termux:** `pkg install nodejs python make clang pkg-config git`
- **Источник:** [github.com/DioNanos/node-pty-android-arm64](https://github.com/DioNanos/node-pty-android-arm64)

### Вариант B: @lydell/node-pty-linux-arm64
Альтернативный нативный PTY модуль для Linux ARM64.

### Вариант C: PTY Termux Utils (абстрактный слой)
**Пакет:** `@mmmbuto/pty-termux-utils` на npm

- **Multi-provider стратегия** с приоритетом:
  1. Termux native: `@mmmbuto/node-pty-android-arm64`
  2. Linux ARM64 native: `@lydell/node-pty-linux-arm64`
  3. Fallback: `child_process` adapter (деградированный, без настоящего PTY)
- **Graceful degradation:** Работает без нативных модулей
- **Source:** [github.com/DioNanos/pty-termux-utils](https://github.com/DioNanos/pty-termux-utils)

### Вариант D: libtermux-android (Android Library с JNI PTY)
- Kotlin/Java библиотека, создающая полное Termux окружение
- **JNI PTY Layer:** Полная поддержка псевдо-терминалов через нативный C код
- **TerminalView:** Drop-in Android View widget для рендеринга терминала
- **Source:** [github.com/libtermux/libtermux-android](https://github.com/libtermux/libtermux-android)

### Вариант E: Portable-PTY (Rust подход)
Rust `portable-pty` crate работает на Android после патча `termios` crate — Android использует идентичные termios structs как Linux.

### Как это делает Termux
Стек эмуляции терминала Termux:
1. **JNI слой** (`termux.c`): Открывает `/dev/ptmx` для создания PTY master/slave пар
2. **Java TerminalSession:** Multi-threaded I/O мост JNI PTY → Java streams
3. **Android TerminalView:** Рендеринг вывода терминала, обработка touch/клавиатуры
4. **termux-exec** (`LD_PRELOAD`): Перехватывает `exec()` для корректного разрешения путей

Ключевой момент: **Ядро Android полностью поддерживает POSIX PTY syscall'ы.** Барьер только в компиляции нативного модуля Node.js (glibc vs bionic).

---

## Рекомендуемая архитектура

```
Android App (Kotlin/Java)
├── WebView (рендерит VS Code UI)
├── Node.js Runtime (встроенный через Termux или бандл)
│   ├── WASM-git (встроенные git операции)
│   ├── node-pty-android-arm64 (настоящий терминальный PTY)
│   ├── xterm.js (рендеринг UI терминала)
│   └── VS Code / code-server
├── Опционально: libtermux-android (полное Termux окружение)
└── JNI Bridge (для PTY если нужно на нативном уровне)
```

### Сводная таблица библиотек

| Потребность | Решение | Зрелость |
|-------------|---------|----------|
| Git операции | `wasm-git` (npm) | Активный, 833 звезды |
| Системный git | Termux `pkg install git` | Проверено |
| PTY/Терминал | `node-pty-android-arm64` (npm) | Рабочий |
| PTY абстракция | `@mmmbuto/pty-termux-utils` (npm) | Активный |
| Полное Termux окружение | `libtermux-android` (Gradle) | Новый, комплексный |
| VS Code на Android | `code-server` (Termux) | Официально поддерживается |

### Ключевые замечания
- **Нет `/sdcard` для git:** Android FAT32 не поддерживает POSIX файловые разрешения
- **Bionic vs glibc:** Android использует Bionic libc. Нативные модули должны быть скомпилированы против Bionic
- **Управление памятью:** Android агрессивно убивает фоновые процессы. Использовать `termux-wake-lock`
- **process.platform override:** Для Android установить `'linux'` для разблокировки установки расширений
