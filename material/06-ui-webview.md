# 6. UI и WebView

## 6.1 Горячие клавиши (физическая клавиатура / DeX / планшеты)

### Проблема
VS Code сильно полагается на Ctrl/Cmd+Key. Android WebView не надёжно пересылает modifier+key комбинации в JavaScript.

### Конкретные решения

**A. Настройка VS Code `"keyboard.dispatch": "keyCode"`**
Это самое важное исправление. VS Code по умолчанию dispatch keybindings через `KeyboardEvent.key` (или `code`), но Android браузеры часто не заполняют эти поля корректно для modifier комбинаций. Установка `"keyboard.dispatch": "keyCode"` в `settings.json` заставляет VS Code использовать `event.keyCode`.

Документировано в [code-server#6480](https://github.com/coder/code-server/issues/6480).

**B. Android-side перехват клавиш:**
- `WebViewClient.shouldOverrideKeyEvent(view, event)` — синхронный, `true` для потребления
- `WebViewClient.onUnhandledKeyEvent(view, event)` — асинхронный fallback
- `View.setOnKeyListener()` — но WebView поглощает многие события
- `dispatchKeyEvent()` override — можно захватить большинство событий
- `onKeyPreIme()` — захват до обработки IME

**C. Конфликты системных шорткатов:**
- **Ctrl+Tab**: Android Chrome потребляет для переключения вкладок. Решение: JavaScript инъекция
- **Alt+key**: На Android Alt часто маппится на meta/option
- **Рекомендация:** Расширение VS Code с экранным палитрой шорткатов (виртуальная Fn строка)

**D. Отсутствующие клавиши без внешней клавиатуры:**
- **Escape**: Нет физической Escape. Маппинг `Ctrl+[` → Escape, или on-screen кнопка
- **F-клавиши (F1-F12)**: Отсутствуют. Плавающий тулбар с кнопками F-клавиш
- **Tab**: Использовать `"keyboard.dispatch": "keyCode"`

---

## 6.2 Touch vs Mouse

### Проблема
VS Code не оптимизирован под touch:
- **Context menu** (right-click): Long-press показывает браузерный контекстное меню вместо VS Code
- **Drag-and-drop**: Панели, вкладки, resize не реагируют на touch drag
- **Text selection**: Touch-drag скроллит вместо выделения
- **Hover-dependent UI**: Действия видны только при hover — невидимы на touch
- **Маленькие click targets**: 10-20px — слишком малы для пальцев
- **Клавиатура при скролле**: Касание области редактора вызывает софт-клавиатуру

### Готовые патчи и подходы

**A. Встроенный Gesture system VS Code (`vs/base/browser/touch.ts`)**
- `Gesture.addTarget(domNode)` — регистрация элементов
- `GestureEventType.Tap` — эквивалент click
- `GestureEventType.Change` — scroll/drag
- `GestureEventType.contextmenu` — long-press → right-click

**B. Критический патч: предотвращение клавиатуры при скролле (code-server#1887)**
```diff
+ private dispatchedEventType: string | undefined;
+ this.dispatchedEventType = EventType.Change;
+ if (this.dispatchedEventType !== EventType.Change) {
+   e.preventDefault();
+ }
+ this.dispatchedEventType = undefined;
```
Доступен в форке: [zongou/vscode](https://github.com/zongou/vscode)

**C. Stylus/pen выделение текста (code-server#7841)**
Патч исправляет `platform.isMobile` detection для Android планшетов:
```diff
- const isPhone = platform.isIOS || (platform.isAndroid && platform.isMobile);
+ const isPhone = platform.isIOS || platform.isAndroid;
```

**D. Touch target sizing (VS Code upstream, 2026)**
VS Code активно добавляет CSS правила:
- 44px минимальные touch targets для `.action-item > .action-label`
- Переработка mobile layout для quick pick и context menu

**E. `enable-user-select` CSS класс**
Убедиться что `user-select: auto` применён для Android WebView — `caretRangeFromPoint()` работает для touch-ориентации курсора.

**F. Рекомендации для кастомного input layer:**
- Переопределить `pointer-events: none` на редакторе при drag операциях
- Добавить CSS `touch-action: manipulation` на кликабельные элементы
- Построить плавающий тулбар расширение: Escape, Ctrl, Alt, Tab, F-клавиши, стрелки
- Использовать `Gesture.addTarget()` на всех интерактивных панелях

---

## 6.3 Производительность

### Лимиты памяти WebView

**Архитектура renderer процесса:**
- Android 8.0+ (API 26): Out-of-process renderer на 64-bit устройствах
- Android 11+ (API 30): Всегда out-of-process renderer
- Low-memory 32-bit на API 26-29: In-process renderer (single process mode)

**Давление памяти и завершение:**
- Android убивает WebView renderer процессы при нехватке памяти
- `onRenderProcessGone(view, detail)` callback **обязателен** — без него приложение падает
- После гибели renderer WebView **мёртв** — нужно destroy и пересоздать

**Приоритет renderer:**
```java
webView.setRendererPriorityPolicy(
    WebView.RENDERER_PRIORITY_WAIVED,
    true // понижать при невидимости
);
```

**Нет документированного лимита памяти** — типичный практический лимит: **~200-500MB** на renderer процесс.

### Оптимизации производительности

**A. Оптимизация запуска WebView:**
```kotlin
WebView.startUpWebView(shouldRunUiThreadStartUpTasks = false)
```

**B. Hardware acceleration:**
- Включена по умолчанию для target API >= 14
- Использовать `View.setLayerType(LAYER_TYPE_HARDWARE, null)` для сложных анимированных представлений

**C. Оптимизации для больших файлов:**
- VS Code уже использует виртуальный скроллинг (Monaco рендерит только видимые строки)
- Отключить `editor.bracketPairColorization`
- **Minimap**: Отключить `"editor.minimap.enabled": false`

### Рекомендуемые настройки

| Настройка | Значение | Почему |
|-----------|----------|--------|
| `editor.minimap.enabled` | `false` | Экономит GPU память |
| `editor.bracketPairColorization` | `false` | Уменьшает работу syntax highlighting |
| `editor.largeFileOptimizations` | `true` | Monaco отключает фичи для больших файлов |
| `terminal.integrated.scrollback` | `1000` | Уменьшить для экономии памяти |
| `"keyboard.dispatch"` | `"keyCode"` | Критично для Android клавиатуры |
| Renderer priority | `RENDERER_PRIORITY_WAIVED` | Позволяет системе забирать в фоне |

### Chrome on Android scroll оптимизации (2026)
Google уменьшил scroll jank на 48% через:
- Input Vizard: Input events маршрутизируются в GPU процесс
- Input Framer: Ожидание до 1/3 refresh цикла
- Input prediction: Синтетические scroll обновления

Это автоматически в современном Android WebView — изменений на стороне приложения не нужно.
