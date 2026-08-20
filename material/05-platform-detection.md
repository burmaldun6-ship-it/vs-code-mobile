# 5. Platform detection и совместимость расширений

## 5.1 `process.platform === 'android'` — не существует

### Что происходит на Android

В nodejs-mobile `process.platform` возвращает `'android'` — **не** `'linux'`. Это подтверждено в [nodejs-mobile API docs](https://nodejs-mobile.github.io/docs/api/differences).

VS Code и code-server проверяют `process.platform` и признают только `'win32'`, `'linux'`, `'darwin'`. При `'android'` VS Code считает платформу неподдерживаемой и разрешает только Web Extensions.

### Проверенное решение: `android-as-linux.js`

```js
// android-as-linux.js
Object.defineProperty(process, "platform", {
  get() {
    return "linux";
  },
});
```

Запуск:
```sh
NODE_OPTIONS="--require /path/to/android-as-linux.js" code-server
```

### Побочные эффекты подмены `process.platform = 'linux'`

| Область | Уровень риска | Детали |
|---------|--------------|--------|
| **Установка расширений** | Низкий | Расширения, проверяющие платформу, теперь установятся корректно |
| **Нативные бинарники** | **ВЫСОКИЙ** | Расширения типа clangd, Python, Docker попытаются запустить Linux бинарники — не будут работать |
| **Файловые пути** | Средний | Linux ожидает `/usr/bin`, `/home/` и т.д. |
| **os.networkInterfaces()** | Средний | Android возвращает MAC `00:00:00:00:00:00` из-за приватности |
| **os.homedir()** | Низкий | На Android возвращает `/data`, на Linux — `/home/<user>` |
| **fork/spawn** | Средний | Android ограничивает порождение процессов |
| **fs операции** | Средний | Hard links (`fs.link()`) не поддерживаются на Android |

### Комплексный патч

```js
// Patch process.platform
Object.defineProperty(process, "platform", {
  get() { return "linux"; },
});

// Patch os.networkInterfaces() для исправления MAC адреса
const os = require('os');
const origNI = os.networkInterfaces;
os.networkInterfaces = function() {
  const ifaces = origNI();
  for (const iface in ifaces) {
    if (ifaces[iface]) {
      ifaces[iface].forEach(details => {
        details.mac = '00:00:00:11:11:11';
      });
    }
  }
  return ifaces;
};
```

### Точки патча

Также может потребоваться патч:
- `os.platform()` (возвращает внутренне то же значение)
- `process.arch` — на Android通常 `'arm'` или `'arm64'` (корректно для Linux ARM)
- Переменные окружения (`TERM`, `SHELL` и т.д.)

### Подход с `product.json`

В `product.json` VS Code можно установить:
```json
{
  "quality": "stable",
  "target": "linux"
}
```
Это поможет с фильтрацией маркетплейса, но патч `process.platform` всё равно нужен во время выполнения.

---

## 5.2 Несовместимые расширения

### Категории расширений по совместимости

| Категория | Примеры | Совместимость с Android |
|-----------|---------|------------------------|
| **Чисто JS/Web расширения** | Темы, Prettier, ESLint, Auto Rename Tag, Path Intellisense | **Работает** — нет нативных зависимостей |
| **Расширения с bundled Node модулями** | GitLens, некоторые language servers | **Обычно работает** — только JS модули |
| **Расширения, нуждающиеся во внешних бинарниках** | clangd, Python (MS), Docker, C/C++ (MS) | **Не будут работать** без бинарника в Termux |
| **Расширения с нативными .node bindings** | Некоторые debugging расширения | **Могут не работать** — нативные модули должны быть скомпилированы под Android ARM |
| **Remote development расширения** | Remote SSH, Remote Containers, WSL | **Не будут работать** — Microsoft запрещает использование вне официального VS Code |

### Как определить несовместимые расширения

```sh
# После установки расширения, проверить на нативные модули
find ~/.local/share/code-server/extensions/<ext-name> \
  -name "*.node" -o -name "binding.gyp" -o -name "*.so"
```

### Проверенные совместимые расширения

| Расширение | Статус | Примечания |
|------------|--------|------------|
| **Prettier** | ✅ Работает | Чистый JS formatter |
| **ESLint** | ✅ Работает | Чистый JS linter |
| **Python (ms-python)** | ⚠️ Частично | Нужен Python в Termux |
| **GitLens** | ✅ Работает | Git интеграция, чистый JS |
| **Dracula / One Dark Pro** | ✅ Работает | Темы, чистый CSS |
| **Material Icon Theme** | ✅ Работает | Иконки, чистый CSS |
| **Auto Rename Tag** | ✅ Работает | Чистый JS |
| **Path Intellisense** | ✅ Работает | Чистый JS |
| **HTML CSS Support** | ✅ Работает | Чистый JS |
| **JavaScript (ES6) Snippets** | ✅ Работает | Чистый JS |
| **Kotlin (fwcd)** | ⚠️ Частично | Нужен Kotlin compiler в Termux |
| **clangd** | ❌ Не работает | Нужен бинарник `clangd` |
| **Docker** | ❌ Не работает | Нужен Docker daemon |
| **Remote SSH** | ❌ Не работает | Microsoft proprietary |

### Манифест совместимости расширений

```json
{
  "android_compatible": [
    "esbenp.prettier-vscode",
    "dbaeumer.vscode-eslint",
    "eamodio.gitlens",
    "dracula-theme.theme-dracula",
    "pkief.material-icon-theme",
    "formulahendry.auto-rename-tag",
    "christian-kohler.path-intellisense",
    "ms-python.python",
    "bradlc.vscode-tailwindcss",
    "streetsidesoftware.code-spell-checker"
  ],
  "android_incompatible": [
    "ms-vscode.cpptools",
    "ms-azuretools.vscode-docker",
    "ms-vscode-remote.remote-ssh",
    "ms-vscode-remote.remote-containers",
    "llvm-vs-code-extensions.vscode-clangd"
  ],
  "needs_binary_in_termux": [
    { "ext": "ms-python.python", "binary": "python3", "pkg": "python" },
    { "ext": "fwcd.kotlin", "binary": "kotlin", "pkg": "kotlin" },
    { "ext": "golang.go", "binary": "go", "pkg": "golang" }
  ]
}
```

### Open VSX vs Microsoft Marketplace

code-server использует **Open VSX** (open-vsx.org). Ключевое отличие:
- Open VSX пока не имеет фильтрации по платформе
- Расширения можно устанавливать через `.vsix`: `code-server --install-extension /path/to/extension.vsix`
- Расширения "Web Extensions" установятся; остальные могут быть отфильтрованы

### Рекомендации

1. **Всегда использовать `android-as-linux.js`** — проверенный подход
2. **Также патчить `os.networkInterfaces()`** для исправления ошибок MAC
3. **Поставлять курируемый список расширений** — не давать пользователям устанавливать заведомо сломанные
4. **Для расширений с бинарниками** (Python, Go, Kotlin): определять наличие бинарника перед включением
5. **Использовать Open VSX** для распространения расширений
