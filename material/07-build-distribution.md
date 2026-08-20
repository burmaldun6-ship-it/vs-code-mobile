# 7. Сборка и дистрибуция

## 7.1 Размер APK

### Проблема
Node.js runtime (~30-40MB) + VS Code web assets (~50-100MB) + расширения = **150-300MB+**. Google Play ограничивает **200MB** для App Bundles (100MB для APK). Каждое увеличение на 6MB снижает конверсию установки на ~1%.

### Конкретные решения

#### A. Android App Bundle (AAB) — главная выигрышная стратегия
- Загружать как `.aab`, не `.apk`. Google Play генерирует per-device split APKs
- **Результат:** Уменьшение размера скачивания на 30-60% vs universal APK
- Termux использовал это: APK был **~20MB** (split) vs **~80MB** на F-Droid (все 4 архитектуры)

#### B. Dynamic Feature Modules
Разбить приложение на base + feature модули с on-demand доставкой:
- **Base APK** (~20-30MB): Android shell, WebView, минимальный Node.js bootstrap
- **Node.js runtime module**: Скачивается при первом запуске
- **VS Code web assets module**: Отдельный on-demand модуль
- **Extensions module**: Каждое расширение как отдельный asset pack

#### C. Play Asset Delivery (PAD) для больших ассетов
Для ассетов >100MB (VS Code web bundle, расширения), PAD поддерживает **много ГБ** без 200MB лимита base. Три режима: install-time, fast-follow, on-demand.

#### D. Download-on-First-Use (рекомендуемая архитектура)

```
Начальный APK:  ~15-25MB (Android WebView shell + Node.js binary)
Первый запуск:  Скачивает Node.js runtime (~30MB) + VS Code web assets (~40-60MB)
Расширения:     Скачиваются on-demand при установке пользователем
```

- Хранить скачивания во внутреннем хранилище (`/data/data/your.app/files/`)
- Использовать `DownloadManager` или кастомный загрузчик с поддержкой resume

#### E. Сжатие нативных бинарников
- Strip debug symbols с `.so` файлов Node.js (экономия ~30%)
- Использовать `arm-eabi-strip` из NDK
- `useLegacyPackaging = false` для несжатых `.so` в APK
- Целевая архитектура **только arm64-v8a** (экономия ~50% размера нативных библиотек)

#### F. Оптимизация ассетов
- WebP для изображений, vector drawables где возможно
- Включить R8/minification (`minifyEnabled true`, `shrinkResources true`)
- Не размещать updateable контент в `assets/`

#### G. Как решает Termux
- **Google Play версия:** Split APKs → только одна архитектура (~20MB)
- **F-Droid версия:** Universal APK со всеми архитектурами (~80MB)
- Bootstrap zip с бинарниками распаковывается в native lib dir

---

## 7.2 Обновления

### Проблема
VS Code обновляется 2-3 раза в месяц. Пересборка APK при каждом обновлении непрактична.

### Конкретные решения

#### A. Самодостаточная система обновлений (рекомендуемая)

**Модель code-server:**
- Переустановка новой версии поверх старой
- Все пользовательские данные в `~/.local/share/code-server`, сохраняются между установками
- Нет автообновления; пользователи перезапускают скрипт установки

**Адаптированное для Android приложения:**
```
App data directory:
  /data/data/your.app/files/
    node-runtime/       ← скачан, обновляется независимо
    vscode-web/         ← скачан, обновляется независимо
    extensions/         ← установленные пользователем
    user-data/          ← настройки, keybindings, состояние
```

**Поток обновления:**
1. При запуске проверить манифест версий (JSON) на сервере
2. Если Node.js runtime имеет более новую версию → скачать tar.gz, распаковать в temp dir, поменять
3. Если VS Code web assets имеют более новую версию → скачать, распаковать, поменять
4. Расширения обновляются через встроенный механизм VS Code
5. Перезапуск Node.js сервера

**Безопасность:** Использовать atomic swap — скачивание в `.tmp` dir, затем rename поверх старой. При неудаче — откат к предыдущей версии.

#### B. OTA обновления для App Shell

- **Google Play updates:** Стандартный AAB update flow
- **In-app update API:** `com.google.android.play:app-update`
- **Для sideloaded APK:** Самообновление через `PackageInstaller` API

#### C. Стратегии обновления

| Подход | Безопасность | Сложность | Для чего подходит |
|--------|-------------|-----------|-------------------|
| Atomic directory swap | Высокая | Низкая | Runtime/ассеты |
| Скачивание + проверка checksum | Высокая | Низкая | Все скачивания |
| Play Feature Delivery | Высокая | Средняя | Приложения Play Store |
| Self-replacement (стиль code-server) | Средняя | Низкая | Простые настройки |
| Git-based pull | Средняя | Средняя | Dev инструменты |
| Полная переустановка APK | Высокая | Низкая | Редкие обновления |

### Рекомендуемая архитектура

```
┌─────────────────────────────────────┐
│         Android APK (~20MB)          │
│  • WebView shell                     │
│  • Download manager                  │
│  • Минимальный Node.js launcher      │
└──────────────┬──────────────────────┘
               │ Первый запуск / проверка обновлений
               ▼
┌─────────────────────────────────────┐
│    Скачиваемый Runtime (~50-80MB)    │
│  • Node.js binary (arm64, stripped)  │
│  • VS Code web assets               │
│  • Pre-installed extensions         │
└──────────────┬──────────────────────┘
               │ On-demand
               ▼
┌─────────────────────────────────────┐
│    Пользовательские расширения       │
│  • Скачиваются из маркетплейса       │
│  • Обновляются независимо            │
└─────────────────────────────────────┘
```
