# 1. Runtime и процессы

## 1.1 Отсутствие полноценного `child_process`

### Реальность
**Модули `child_process` и `cluster` НЕ поддерживаются в nodejs-mobile.** Официальная документация:

> "The `child_process` and `cluster` modules are not available. nodejs-mobile runs in a mobile application process, which is expected to be a single process in the mobile operating systems."

### Почему fork/spawn не работают на Android
- Android ограничивает приложения **одним процессом** — нельзя `fork()` внутри APK-контекста
- `process.exit()` убивает всё приложение
- `process.getuid()`, `process.getgid()`, `process.setuid()` недоступны
- `os.homedir()` возвращает `/data`

### Может ли `worker_threads` заменить `child_process`?

**Да, и это рекомендуемый подход.** `worker_threads` поддерживается в nodejs-mobile:

| Возможность | child_process | worker_threads |
|-------------|---------------|----------------|
| Создаёт новый процесс | Да (заблокировано на Android) | Нет (потоки в том же процессе) |
| Изоляция памяти | Полная (отдельные V8 инстансы) | Возможен общий памятью через SharedArrayBuffer |
| Коммуникация | IPC каналы (сериализация) | Message passing + SharedArrayBuffer |
| Лимит процессов | Да (Phantom Killer) | Нет (потоки не считаются) |
| Поддерживается в nodejs-mobile | **Нет** | **Да** |

```javascript
const { Worker, isMainThread, parentPort, workerData } = require('worker_threads');

if (isMainThread) {
  const worker = new Worker(__filename, { workerData: script });
  worker.on('message', resolve);
  worker.on('error', reject);
} else {
  const result = heavyComputation(workerData);
  parentPort.postMessage(result);
}
```

---

## 1.2 Phantom Process Killer (Android 12+)

### Как работает
- Мониторит **все форкнутые дочерние процессы** ВСЕХ приложений суммарно
- **Жёсткий лимит: 32 фантомных процесса** в системе (не на приложение)
- Процессы убиваются при **чрезмерном использовании CPU** в фоне
- Приоритет убийства основан на `oom_score_adj`

### Обходные пути (без root)

**Android 14+ (самый простой):**
```
Settings → Developer options → Disable child process restrictions
```

**Android 12/13 (через ADB):**
```bash
adb shell "/system/bin/device_config set_sync_disabled_for_tests persistent"
adb shell "/system/bin/device_config put activity_manager max_phantom_processes 2147483647"
adb shell settings put global settings_enable_monitor_phantom_procs false
```

**Android 14+ через ADB:**
```bash
adb shell settings put global settings_enable_monitor_phantom_procs false
```

### Архитектурное решение (лучший вариант)

**Полностью отказаться от дочерних процессов в пользу `worker_threads`.** Ключевой момент:
- `worker_threads` создают потоки, НЕ дочерние процессы
- Потоки не появляются в списке фантомных процессов
- Лимит на процессы не применяется к потокам

Для code-server это значит:
- Использовать `worker_threads` вместо `child_process.fork()`
- Заменить `child_process.spawn()` для шелл-команд на чистые Node.js реализации
- Заменить `exec` вызовы на альтернативы без порождения процессов

---

## 1.3 Node.js как встроенная библиотека

### Ключевые проекты

#### 1. nodejs-mobile (самый зрелый)
- **GitHub:** [nodejs-mobile/nodejs-mobile](https://github.com/nodejs-mobile/nodejs-mobile)
- Готовый `libnode.so` для Android (arm64-v8a, armeabi-v7a, x86, x86_64)
- Плагины для React Native и Cordova
- Продакшн-тестирован (Manyverse, Mapeo в Play Store)
- **Ограничение:** только один инстанс, нет child_process, нет intl модуля

#### 2. node-android-lib (сборка самостоятельно)
- **GitHub:** [avaer/node-android-lib](https://github.com/avaer/node-android-lib)
- Сборка `libnode.so` прямо на Android через Termux:
```shell
./configure --shared
LDFLAGS="-llog" make -j2
# Результат: ./out/Release/lib.target/libnode.so.59
```

#### 3. linroid/libnode (автоматическая сборка)
- **GitHub:** [linroid/libnode](https://github.com/linroid/libnode)
- Сборка Node.js shared library для нескольких платформ включая Android
- Использует Docker для воспроизводимых сборок

#### 4. viocha/node-android (последний)
- **GitHub:** [viocha/node-android](https://github.com/viocha/node-android)
- Сборка Node.js 24 для Android (arm64-v8a, full-icu)
- Включает примеры Android-приложений

### Встраивание libnode.so в APK

**CMakeLists.txt:**
```cmake
cmake_minimum_required(VERSION 3.18.1)
project("myapp")

include_directories(SYSTEM ${CMAKE_SOURCE_DIR}/libnode/include/node)

add_library(libnode SHARED IMPORTED)
set_target_properties(libnode PROPERTIES
    IMPORTED_LOCATION ${CMAKE_SOURCE_DIR}/libnode/bin/${ANDROID_ABI}/libnode.so)

add_library(native-lib SHARED native-lib.cpp)

find_library(log-lib log)
target_link_libraries(native-lib libnode ${log-lib})
```

**JNI Bridge (native-lib.cpp):**
```cpp
#include <jni.h>
#include <node.h>

extern "C" JNIEXPORT jint JNICALL
Java_com_example_MyActivity_startNode(
    JNIEnv* env, jobject thiz, jobjectArray arguments) {

    int argc = arguments->GetArrayLength();
    char** argv = (char**) malloc(sizeof(char*) * (argc + 1));

    for (int i = 0; i < argc; i++) {
        auto jstr = (jstring) env->GetObjectArrayElement(arguments, i);
        argv[i] = (char*) env->GetStringUTFChars(jstr, nullptr);
    }
    argv[argc] = nullptr;

    int result = node::Start(argc, argv);

    for (int i = 0; i < argc; i++) free(argv[i]);
    free(argv);
    return result;
}
```

**Kotlin:**
```kotlin
class MyActivity : AppCompatActivity() {
    companion object {
        init {
            System.loadLibrary("native-lib")
            System.loadLibrary("node")
        }
    }

    fun startNodeServer() {
        Thread {
            startNode(arrayOf("node", "-e", """
                const http = require('http');
                http.createServer((req, res) => {
                    res.end('Hello from Node.js on Android!');
                }).listen(3000);
            """.trimIndent()))
        }.start()
    }

    external fun startNode(arguments: Array<String>): Int
}
```

**build.gradle:**
```groovy
android {
    defaultConfig {
        externalNativeBuild {
            cmake {
                arguments "-DANDROID_STL=c++_shared"
            }
        }
        ndk {
            abiFilters "arm64-v8a", "armeabi-v7a", "x86_64"
        }
    }
    sourceSets {
        main {
            jniLibs.srcDirs 'libnode/bin/'
        }
    }
}
```

### Переменные окружения

Через аргументы при инициализации Node.js:
```bash
NODE_PATH=/data/app/lib/node_modules
NODE_OPTIONS="--require /path/to/setup.js"
```

Или программно:
```cpp
setenv("NODE_PATH", "/data/data/com.example/files/node_modules", 1);
setenv("HOME", "/data/data/com.example/files", 1);
```

### Ограничения nodejs-mobile

| Возможность | Статус на Android |
|-------------|-------------------|
| `child_process` | **Не поддерживается** |
| `cluster` | **Не поддерживается** |
| `worker_threads` | **Поддерживается** |
| `fs` | Поддерживается (песочница путей) |
| `fs.link()` | **Не поддерживается** (нет хардлинков) |
| `intl` модуль | **Не поддерживается** |
| `os.cpus()` | Возвращает undefined (Android 8+) |
| `os.homedir()` | Возвращает `/data` |
| `process.stdin` | **Недоступен** |
| `process.exit()` | Убивает всё приложение |
| V8 Inspector/Debugger | **Не поддерживается** |
| WebAssembly | Может работать на Android |

---

## Рекомендации

**Использовать `nodejs-mobile` или кастомный `libnode.so` + исключительно `worker_threads`.** Никогда не использовать `child_process` или `cluster`. Это полностью решает проблему Phantom Process Killer и укладывается в ограничения Android.

### Существующий референс: codebian
Проект [codebian](https://github.com/brian200508/codebian) — PoC code-server как самодостаточного Android APK.
