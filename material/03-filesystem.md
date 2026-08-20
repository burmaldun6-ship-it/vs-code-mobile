# 3. Файловая система

## 3.1 Scoped Storage (Android 10+) и проксирование SAF в Node.js fs

### Проблема
Android 10+ навязывает **Scoped Storage**. Приложения не могут свободно обращаться к `/sdcard`. Android 11+ делает это обязательным для приложений с target API 30+.

### Как работает SAF
SAF использует `content://` URI (не файловые пути):
```java
ContentResolver resolver = context.getContentResolver();
InputStream is = resolver.openInputStream(documentUri);
OutputStream os = resolver.openOutputStream(documentUri);
```

### Можно ли использовать DocumentFile + ContentResolver без JNI?
**Да, но только из Java/Kotlin.** SAF — это Android framework API, нет способа вызвать `ContentResolver` из чистого Node.js/JS без моста.

| Подход | Механизм | Плюсы | Минусы |
|--------|----------|-------|--------|
| **Native Activity + JS bridge** | Android activity вызывает SAF intent, получает `content://` URI, передаёт в Node.js через JNI/WebView bridge | Полная поддержка SAF | Требует код на стороне Android |
| **React Native / Capacitor плагины** | `react-native-saf-x`, `capacitor SAF plugin` | Поддерживаются, JS-friendly | Добавляет зависимость фреймворка |
| **Direct FUSE proxy** | Монтировать SAF дерево как FUSE из userspace, отображать как `/` для Node.js | Прозрачный доступ через `fs` | Сложность, проблемы производительности |
| **`xhook` native hooking** | Хукать `fopen`/`mkdir`/`remove` для перенаправления через SAF | Работает для нативного кода прозрачно | Требует JNI, хрупко при обновлениях |

### Как решает Termux
Termux **НЕ проксирует SAF**. Вместо этого:
- Приватная директория данных (`/data/data/com.termux/files/`) находится на **ext4/F2FS** — настоящая POSIX-файловая система
- Для доступа к пользовательским файлам использует `termux-setup-storage` — создаёт **симлинки** в `~/storage/`
- Активная разработка ведётся внутри `~/` (ext4)

### MANAGE_EXTERNAL_STORAGE

```xml
<uses-permission android:name="android.permission.MANAGE_EXTERNAL_STORAGE"
    tools:ignore="ScopedStorage" />
```
```kotlin
val uri = Uri.parse("package:${BuildConfig.APPLICATION_ID}")
startActivity(Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION, uri))
```

- Предоставляет доступ ко **всем файлам** в shared storage
- Google Play **строго ограничивает** — только файловые менеджеры, бэкапы, антивирусы
- Проверка: `Environment.isExternalStorageManager()`

**Рекомендация:** Использовать `MANAGE_EXTERNAL_STORAGE` только для терминала/файлового менеджера. В остальных случаях — SAF pickers или внутреннее хранилище приложения.

---

## 3.2 Отсутствие стандартных Unix-путей

### Approach Termux (золотой стандарт)

| Стандартный Linux | Эквивалент Termux | Примечания |
|-------------------|-------------------|------------|
| `/home` | `/data/data/com.termux/files/home` | Рабочее пространство, ext4 |
| `/usr`, `/usr/bin` | `/data/data/com.termux/files/usr` (`$PREFIX`) | Бинарники, библиотеки |
| `/tmp` | `$PREFIX/tmp` | Стирается при перезапуске |
| `/etc` | `$PREFIX/etc` | Конфиги |
| `/var` | `$PREFIX/var` | Переменные данные |

### Для вашего Node.js приложения на Android

| Node.js ожидает | Android замена | Persistence | Примечания |
|-----------------|----------------|-------------|------------|
| `/home` (HOME) | `context.getFilesDir().parentFile` → `/data/data/<pkg>/files` | Персистентная | Полная POSIX (ext4/F2FS) |
| `/tmp` (TMPDIR) | `context.cacheDir` → `/data/data/<pkg>/cache` | **Эфемерная** | Android может удалить при нехватке памяти |
| `/usr/local` | `context.getFilesDir()` → `/data/data/<pkg>/files` | Персистентная | Подпапки для node_modules, бинарников |
| `/var` | `context.getNoBackupFilesDir()` → `/data/data/<pkg>/no_backup` | Персистентная | Не очищается бэкапом |

### Назначение директорий

- **`getFilesDir()`** → Персистентные файлы приложения. Использовать как `$HOME`. Безопасно для `node_modules`, конфигов, исходников. На ext4 — полная поддержка POSIX.
- **`getCacheDir()`** → Disposable кэш. Использовать как `/tmp`. Android **удалит** при нехватке памяти.
- **`getNoBackupFilesDir()`** → Персистентная, исключена из Android backup. Хорошо для БД, реестров.
- **`getExternalFilesDir()`** → Внешнее хранилище приложения. Без разрешений, но на FUSE/FAT — **нет симлинков, нет exec битов**.

### Рекомендуемая настройка окружения
```javascript
process.env.HOME = '/data/data/com.yourapp/files';
process.env.TMPDIR = '/data/data/com.yourapp/cache';
process.env.PREFIX = '/data/data/com.yourapp/files/usr';
process.env.NODE_PATH = '/data/data/com.yourapp/files/node_modules';
```

### termux-chroot
Для приложений, которым нужны стандартные пути (`/home`, `/tmp`, `/usr`), Termux предоставляет `termux-chroot` — chroot-подобное окружение через mount namespace.

---

## 3.3 Символьные ссылки

### Где симлинки работают
- **Внутреннее хранилище приложения** (`/data/data/<pkg>/`): ext4 или F2FS — **полная поддержка**
- Домашняя директория Termux: **симлинки работают**

### Где симлинки ломаются
- **Внешнее хранилище / SD-карта**: FAT32, exFAT или FUSE эмуляция — **нет поддержки**
- FUSE демон `/dev/fuse` для `/storage/emulated/0` **не поддерживает** создание симлинков

### Влияние на Node.js / npm

**Симлинки в `node_modules/.bin/`:**
- npm создаёт симлинки в `node_modules/.bin/` указывающие на executables пакетов
- **Ломаются на FAT32/exFAT** (SD-карты, shared storage)
- На ext4 (внутреннее хранилище) работают прекрасно

### Решения

| Сценарий | Решение |
|----------|---------|
| Проект на внутреннем хранилище (ext4) | Симлинки работают — изменений не нужно |
| Проект на SD карте / shared storage | `npm config set bin-links false` + shell скрипты-шимы |
| Нужен `npx` | Проект на ext4, или трюк `__TESTING_BIN_LINKS_PLATFORM__=win32` |
| Используется pnpm | `--shamefully-hoist` или проект на ext4 |
| Универсальный fallback | `termux-chroot` + всё в `$HOME` |

### Shell script shims вместо симлинков
```bash
# Обмануть npm чтобы создавал .cmd-style шимы (как на Windows):
export __TESTING_BIN_LINKS_PLATFORM__=win32
npm install
```

---

## Структура директорий

```
/data/data/com.yourapp/
├── files/                    ← getFilesDir() — ваш $HOME
│   ├── node_modules/         ← симлинки работают (ext4)
│   ├── .npm/
│   ├── projects/
│   └── usr/                  ← ваш $PREFIX (как /usr)
│       ├── bin/
│       ├── lib/
│       └── tmp/              ← ваш /tmp (персистентный)
├── cache/                    ← getCacheDir() — ваш /tmp (эфемерный)
├── no_backup/                ← getNoBackupFilesDir() — состояние/БД
└── shared/                   ← симлинк → /sdcard (FAT, нет симлинков)
```
