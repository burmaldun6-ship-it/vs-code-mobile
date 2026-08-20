# 4. Сеть и IPC

## 4.1 Localhost внутри APK

### Как работает на практике
Каждый реальный проект (code-server на Android, VSCodroid, code_lfa) использует **один паттерн**:

1. Node.js запускает TCP HTTP/WebSocket сервер на `127.0.0.1` с динамическим портом
2. Android загружает `http://localhost:<port>` в WebView
3. Оба живут в одном процессе — localhost полностью доступен

**Рабочие проекты:**
- `nightmare-space/code_lfa` — Flutter + WebView загружает code-server на `localhost:8080`
- `node-on-mobile/node-on-android` — Node.js как shared library, `server.listen(0)` (рандомный порт)
- `okatu-loli/Use-Code-on-Your-Android-Tablet` — WebView shell → `http://127.0.0.1:8080/`
- Termux-based setup — code-server в proot/Ubuntu, WebView подключается к localhost

### Решение проблемы конфликта портов

Использовать `server.listen(0)` — ОС назначает рандомный доступный порт:
```js
const server = http.createServer(handler);
server.listen(0, '127.0.0.1', () => {
  const port = server.address().port;
  android.loadUrl(`http://localhost:${port}`);
});
```

### Unix Domain Sockets — может ли WebView их использовать?

**Короткий ответ: Нет.** WebView (на базе Chromium) **не поддерживает** подключение к Unix domain sockets напрямую.

- **Браузеры не поддерживают Unix сокеты** — подтверждено в [webview/webview #1162](https://github.com/webview/webview/discussions/1162)
- **`file://` + WebSocket на Unix сокете** — невозможно. Android WebView блокирует WebSocket из `file://` origins
- **`socat` bridge паттерн** — можно запустить мост, но это добавляет TCP хоп

**Вывод:** Все успешные проекты code-server на Android используют TCP localhost, а не Unix сокеты.

### WebViewAssetLoader — раздача локальных файлов через HTTP

```kotlin
val assetLoader = WebViewAssetLoader.Builder()
    .addPathHandler("/", WebViewAssetLoader.AssetsPathHandler(this))
    .build()

webView.webViewClient = object : WebViewClientCompat() {
    override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? {
        return assetLoader.shouldInterceptRequest(request.url)
    }
}
webView.loadUrl("https://appassets.androidplatform.net/index.html")
```

---

## 4.2 WebSocket в Android WebView

### Поддержка и минимальная версия

| Платформа | WebSocket с | Статус |
|-----------|-------------|--------|
| Android Browser | 4.4 (KitKat, 2013) | Полная поддержка |
| Android WebView (Chromium-based) | 4.4+ | Полная поддержка |
| Android System WebView (Google Play) | Текущий v151 | Полная поддержка |

**WebSocket полностью поддерживается во всех современных Android WebView.**

### Известные ограничения

1. **`file://` origin** — WebSocket соединения из `file://` страниц **заблокированы** в современном WebView. Нужно serving через `http://localhost` или `WebViewAssetLoader`
2. **Service Workers обязательны для VS Code web** — требуют secure context (HTTPS или localhost). `localhost` считается secure context
3. **Проблема белого экрана** — почти всегда из-за:
   - Контент загружен из `file://` (нет Service Workers → сломанные webview)
   - WebSocket соединение падает из-за неправильного origin
   - Старая версия WebView

### VS Code Server / code-server

- code-server **требует WebSocket** — для терминала, extension host, file watching
- Service Workers **обязательны** для webview panels
- **HTTPS не требуется** на localhost (localhost — secure context)

---

## 4.3 Native ↔ WebView IPC

### Вариант A: HTTP/WebSocket (рекомендуемый для Node.js)

```kotlin
webView.loadUrl("http://localhost:${nodePort}")
```
- **Плюсы:** Стандартные web API, работает везде, совместимость с VS Code
- **Минусы:** Управление портами
- **Когда использовать:** Нужна совместимость с VS Code / code-server

### Вариант B: `addWebMessageListener` (современный Android Bridge)

```kotlin
WebViewCompat.addWebMessageListener(
    webView, "androidBridge",
    setOf("https://appassets.androidplatform.net"),
    WebViewCompat.WebMessageListener { view, message, sourceOrigin, isMainFrame, replyProxy ->
        replyProxy.postMessage("response from native")
    }
)
```
```javascript
window.androidBridge.postMessage("hello native");
window.androidBridge.onmessage = (event) => { /* ... */ };
```
- **Плюсы:** Безопасный (origin-based), двунаправленный, async
- **Минусы:** Только `http(s)://` origins, минимальный WebView 82
- **Когда использовать:** Контролируете оба кода, не нужен VS Code

### Вариант C: `addJavascriptInterface` (устаревший)

```kotlin
class WebBridge {
    @JavascriptInterface
    fun sendToNative(data: String) { /* ... */ }
}
webView.addJavascriptInterface(WebBridge(), "AndroidBridge")
```
- **Минусы:** Синхронный (блокирует JS поток), нет проверки origin

### Вариант D: `shouldInterceptRequest` + Custom Protocol

```kotlin
override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? {
    if (request.url.scheme == "custom") {
        return WebResourceResponse("text/plain", "UTF-8", inputStream)
    }
    return super.shouldInterceptRequest(view, request)
}
```

---

## Рекомендуемая архитектура

```
┌─────────────────────────────────────────┐
│            Android App                   │
│                                          │
│  ┌──────────┐     ┌───────────────────┐ │
│  │ WebView  │◄───►│ Node.js Process   │ │
│  │          │ TCP │ (code-server)     │ │
│  │ loadUrl  │     │ 127.0.0.1:<port>  │ │
│  │ (http:// │     │                   │ │
│  │ localhost│     │ WebSocket server  │ │
│  │ :port)   │     │ HTTP server       │ │
│  └──────────┘     └───────────────────┘ │
│                                          │
│  ┌──────────────────────────────────┐   │
│  │ Опционально: Native Bridge       │   │
│  │ addWebMessageListener()          │   │
│  │ для native ↔ WebView IPC         │   │
│  └──────────────────────────────────┘   │
└─────────────────────────────────────────┘
```

### Сводная таблица

| Подход | Работает с WebView? | Риск конфликта портов | Совместимость с VS Code | Сложность |
|--------|--------------------|-----------------------|------------------------|-----------|
| TCP localhost (port 0) | ✅ Да | Нет (использовать port 0) | ✅ Да | Низкая |
| Unix Domain Socket | ❌ Нет | N/A | ❌ Нет | N/A |
| `addWebMessageListener` | ✅ Да | Нет | ❌ Нет (отдельный канал) | Средняя |
| `shouldInterceptRequest` | ✅ Да | Нет | ❌ Нет | Высокая |

**Вывод:** Использовать TCP localhost с `listen(0)`. Все успешные проекты code-server на Android делают именно так.
