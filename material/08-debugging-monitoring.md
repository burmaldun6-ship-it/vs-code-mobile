# 8. Отладка и мониторинг

## 8.1 Отладка Node.js внутри APK

### Корневая проблема
`nodejs-mobile` поставляет `libnode.so` — предсобранный shared library с Node.js runtime. V8 inspector **явно отключен** в сборках nodejs-mobile:

> "The V8 inspector is not available on current nodejs-mobile builds, due to a dependency on the `intl` module."

Это значит что `--inspect` / `--inspect-brk` флаги **не работают** из коробки.

`chrome://inspect` не работает потому что он детектит только WebView/Chrome таргеты через `localabstract:webview_devtools_remote_<pid>`. Встроенный `libnode.so` не экспортирует этот сокет.

### Практические обходные пути

| Подход | Как работает | Ограничения |
|--------|-------------|-------------|
| **adb port forwarding + desktop DevTools** | Node с `--inspect=0.0.0.0:9229`, затем `adb forward tcp:9229 tcp:9229`, открыть `chrome://inspect` → configure `localhost:9229` | Требует пересборки `libnode.so` с ICU/intl |
| **Termux + port forwarding** | Node в Termux с `--inspect`, `adb reverse tcp:9229 tcp:9229`, подключение из desktop Chrome | Требует rebuild; Termux усложняет распространение APK |
| **Сборка libnode.so с intl** | Пересобрать из исходников с `--with-intl=small-icu` или `--with-intl=full-icu` | Значительные усилия по сборке; +6MB на архитектуру |
| **WebSocket relay в приложении** | C++ WebSocket сервер в приложении, мостящий inspector protocol | Очень сложно |
| **Программный `inspector.open()`** | `require('inspector').open(9229)` после запуска Node | Требует Node ≥ 8.x и скомпилированный inspector |
| **Logcat-based отладка** | Перенаправление stdout/stderr в logcat через pipe+dup2 | Нет breakpoints, только логирование |
| **Remote debugging через SSH tunnel** | Node слушает на `127.0.0.1:9229`, SSH tunnel, подключение Chrome DevTools | Работает если устройство доступно через SSH |

### Рекомендуемая стратегия отладки

**Для разработки (debug builds):**
1. Пересобрать `libnode.so` с `--with-intl=small-icu` для включения inspector
2. Запустить Node с `--inspect=0.0.0.0:9229`
3. Использовать `adb forward tcp:9229 tcp:9229` для моста
4. Открыть `chrome://inspect` → Configure → Add `localhost:9229`
5. Альтернатива: VS Code Node.js debug adapter на `localhost:9229`

**Для продакшена (без inspector):**
- Структурированное логирование через `console.log()` → logcat
- Кастомный `node:inspector.Session` для программного runtime profiling

---

## 8.2 Crash reporting

### Проблема
Segfault в C++ addon (связанном с `libnode.so`) убивает весь процесс. Нужны out-of-process crash handlers.

### Сравнение библиотек

| Библиотека | Процесс-модель | Поддержка Android | Размер | Статус |
|------------|---------------|-------------------|--------|--------|
| **Breakpad** | In-process | ✅ Поддерживается | ~200-400KB | Устаревший, используется Sentry |
| **Crashpad** | Out-of-process (handler daemon) | ✅ Поддерживается (Chrome использует на Android) | ~1.5-3MB | Рекомендуемый; используется Firebase Crashlytics NDK |
| **Sentry Native SDK** | `inproc` backend на Android | ✅ API 16+ | ~200KB | SaaS dashboard, Breakpad/Crashpad как опции |
| **Firebase Crashlytics NDK** | На базе Crashpad | ✅ API 16+ | ~2-5MB | Managed SaaS, лучший DX |
| **xCrash** | In-process + logcat | ✅ Native + Java | ~300KB | Open-source, собственный бэкенд |

### A) Firebase Crashlytics NDK (рекомендуется для большинства команд)

```kotlin
// build.gradle.kts
dependencies {
    implementation(platform("com.google.firebase:firebase-bom:34.17.0"))
    implementation("com.google.firebase:firebase-crashlytics-ndk")
    implementation("com.google.firebase:firebase-analytics")
}

android {
    buildTypes {
        getByName("release") {
            configure<CrashlyticsExtension> {
                nativeSymbolUploadEnabled = true
            }
        }
    }
}
```

- Использует **Crashpad** как crash handler (out-of-process)
- Собирает **tombstones** на Android 12+
- Загрузка `.sym` файлов через `uploadCrashlyticsSymbolFileRelease` Gradle task
- Поддерживает GWP-ASan для детекции memory corruption

### B) Breakpad (Google, standalone)

```cpp
#include "breakpad/src/client/linux/handler/exception_handler.h"

static bool dumpCallback(const google_breakpad::MinidumpDescriptor& descriptor,
                         void* context, bool succeeded) {
    // descriptor.path() содержит .dmp файл
    return succeeded;
}

google_breakpad::ExceptionHandler eh(
    google_breakpad::MinidumpDescriptor("/data/local/tmp"),
    nullptr, dumpCallback, nullptr, true, -1);
```

### C) Sentry Native SDK

```cpp
#include <sentry.h>

sentry_options_t *options = sentry_options_new();
sentry_options_set_dsn(options, "https://your-dsn@sentry.io/project-id");
sentry_options_set_backend(options, sentry_backend_new("inproc"));
sentry_init(options);
```

### Матрица рекомендаций

| Сценарий | Лучший выбор |
|----------|-------------|
| Firebase уже используется | Firebase Crashlytics NDK |
| Нужен полный контроль, свой бэкенд | Breakpad или xCrash |
| Кросс-платформа (Android + iOS + desktop) | Sentry Native SDK |
| Минимальный размер | xCrash или Breakpad |
| Нужна надёжность out-of-process | Crashpad (через Crashlytics NDK) |

### Обязательно: символизация

1. **Сохранять не-strip `.so` файлы** (с debug symbols)
2. **Проверять GNU build ID**: `readelf -n app/build/.../libnode.so | grep "Build ID"`
3. **Загружать символы** в crash reporting backend после каждой сборки
