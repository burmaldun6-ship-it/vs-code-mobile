# 2. Нативные модули (C++ addons)

## 2.1 Кросс-компиляция .node → .so под Android

### Подход A: node-gyp с NDK (рекомендуемый)

```bash
# 1. Скачать заголовки Node.js
curl -fsSL "https://nodejs.org/download/release/v${NODE_VERSION}/node-v${NODE_VERSION}-headers.tar.gz" -o /tmp/node-headers.tar.gz
mkdir -p /tmp/node-headers && tar -xzf /tmp/node-headers.tar.gz -C /tmp/node-headers --strip-components=1

# 2. Настроить переменные NDK тулчейна
TOOLCHAIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64"
export CC="$TOOLCHAIN/bin/aarch64-linux-android${API_LEVEL}-clang"
export CXX="$TOOLCHAIN/bin/aarch64-linux-android${API_LEVEL}-clang++"
export AR="$TOOLCHAIN/bin/llvm-ar"
export RANLIB="$TOOLCHAIN/bin/llvm-ranlib"
export STRIP="$TOOLCHAIN/bin/llvm-strip"

# 3. Критические флаги
export CFLAGS="-fPIC -DANDROID"
export CXXFLAGS="-fPIC -DANDROID -std=c++20"
export LDFLAGS="-static-libstdc++"
export GYP_DEFINES="OS=android target_arch=arm64 host_os=linux android_ndk_path=$ANDROID_NDK_HOME"

# 4. Запуск node-gyp
npx node-gyp configure \
  --target_arch=arm64 \
  --target_platform=android \
  --nodedir=/tmp/node-headers
npx node-gyp build
```

**Важно:** Node 24+ `common.gypi` ссылается на `android_ndk_path` — обязательно установите эту переменную.

### Подход B: prebuild-for-nodejs-mobile

```bash
npx prebuild-for-nodejs-mobile android-arm64 --sdk28
# Цели: android-arm, android-arm64, android-x64
```

### Подход C: Автоматическая сборка через nodejs-mobile-react-native

Плагин автоматически определяет `.gyp` файлы и кросс-компилирует.

### Статус по модулям

| Модуль | Статус | Подход |
|--------|--------|--------|
| **spdlog** | ✅ Работает | Header-only или CMake кросс-компиляция. Использовать `android_sink.h` для logcat. Связать `-llog` |
| **node-pty** | ⚠️ Требует fork | Использовать [`node-pty-android-arm64`](https://github.com/DioNanos/node-pty-android-arm64) или `@mmmbuto/node-pty-android-arm64` |
| **native-is-elevated** | ⚠️ Платформо-зависимый | Заглушка (всегда `false` для non-root) |
| **vscode-nsfw** | ⚠️ Зависимость от inotify | inotify работает на Android ядре, но нужны обработчики имён |
| **keytar** | ⚠️ Credential API | Зависит от libsecret/kwallet; на Android — Android Keystore JNI обёртка |

---

## 2.2 Ограничения POSIX-API на Android

### PTY (Псевдо-терминалы)

**Хорошая новость:** Bionic libc **реализует** `openpty()`, `forkpty()`, `posix_openpt()` — они оборачивают `/dev/ptmx`.

**Реальная проблема:** не POSIX API, а:
1. **Ограничения пространства имён Android**: `dlopen()` блокирует загрузку `.node` файлов вне пространства имён приложения
2. **Баг node-gyp `android_ndk_path`**: С Node 24, `common.gypi` ссылается на переменную `android_ndk_path`. Исправление: `export GYP_DEFINES="android_ndk_path=''"`

**Рабочие форки:**
- `node-pty-android-arm64` (npm) — ARM64/Termux-only
- `@mmmbuto/pty-termux-utils` — Multi-provider с fallback на `child_process`

### inotify

**inotify работает на Android.** Ядро Android включает полную поддержку inotify. `max_user_watches` по умолчанию — 8192.

### Модули, которые ломаются

| Модуль | Причина поломки | Альтернатива |
|--------|-----------------|--------------|
| **node-pty** | загрузка пространства имён + `android_ndk_path` | `@mmmbuto/node-pty-android-arm64` или форк |
| **sharp** (libvips) | нет android prebuilt | Пересобрать через Termux toolchain |
| **native-keymap** | требует X11/xkbfile | Заглушка/omit на Android |
| **keytar** | требует libsecret/kwallet | Android Keystore JNI обёртка |
| **native-is-elevated** | платформо-зависимая проверка | Заглушка → `false` |

---

## 2.3 Архитектурные ABI

### Поддерживаемые ABI

| ABI | Архитектура | Использование |
|-----|-------------|---------------|
| `arm64-v8a` | 64-bit ARM | **Обязателен** — Google Play требует 64-bit с августа 2019 |
| `armeabi-v7a` | 32-bit ARM | Устаревшие устройства, ~15% установок |
| `x86_64` | 64-bit Intel | Только эмуляторы (API 30+ поддерживает ARM трансляцию) |
| `x86` | 32-bit Intel | Старые эмуляторы |

**Рекомендация:** поставлять `arm64-v8a` + `armeabi-v7a`. Отбросить `x86`/`x86_64`. Это экономит **50-70%** размера нативных библиотек.

### App Bundle (AAB) ABI Splitting

```kotlin
// build.gradle.kts
android {
    bundle {
        abi {
            enableSplit = true  // по умолчанию
        }
    }
}
```

### Не-Play Store (APK splits):

```groovy
android {
    splits {
        abi {
            enable true
            include "armeabi-v7a", "arm64-v8a"
            universalApk false
        }
    }
}
```

### Оптимизация размера

1. **Strip debug symbols**: `llvm-strip` — типичное уменьшение 3MB → 700KB
2. **Статическая линковка libstdc++**: `-static-libstdc++`
3. **`-fvisibility=hidden`** + version scripts для скрытия не-публичных символов
4. **Сжатые нативные библиотеки**: Android 6.0+ читает несжатые `.so` через mmap. `android:extractNativeLibs="false"`
5. **Хранить `.node` файлы в app assets**

### Конвейер сборки

```
┌─────────────────────────────────────┐
│  CI: Кросс-компиляция каждого модуля│
│  Для каждого ABI (arm64, armv7):    │
│    1. npm install --ignore-scripts  │
│    2. Установить env vars NDK       │
│    3. node-gyp configure + build    │
│    4. llvm-strip .node              │
│    5. Загрузить как артефакт        │
└─────────────────────────────────────┘
              ↓
┌─────────────────────────────────────┐
│  Android сборка:                    │
│    .node в assets/prebuilds/        │
│    AAB с abi split                  │
│    Загрузка во время выполнения     │
└─────────────────────────────────────┘
```

### Ключевые переменные окружения

```
CC=aarch64-linux-android30-clang
CXX=aarch64-linux-android30-clang++
AR=llvm-ar
CFLAGS="-fPIC -DANDROID"
CXXFLAGS="-fPIC -DANDROID"
LDFLAGS="-static-libstdc++"
GYP_DEFINES="OS=android target_arch=arm64 host_os=linux android_ndk_path=$NDK_HOME"
npm_config_platform=android
npm_config_arch=arm64
```
