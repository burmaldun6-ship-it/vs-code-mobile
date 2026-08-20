# 10. Безопасность

## 10.1 Запуск произвольного кода — изоляция расширений

### Корневая проблема
Расширения VS Code выполняют JavaScript и Node.js код с полным доступом к `fs`, `net`, `child_process` и всей файловой системе. В APK это означает доступ к внутреннему хранилищу приложения.

### Решение A: Node.js Permission Model (рекомендуемый основной слой)

Node.js v20+ (стабильный с v22.13.0) имеет встроенную модель разрешений:

```bash
node --permission \
  --allow-fs-read=/data/user/0/com.your.app/files/projects \
  --allow-fs-write=/data/user/0/com.your.app/files/projects \
  --allow-net=127.0.0.1 \
  your_extension.js
```

Ключевые флаги:
- `--permission` — запретить всё по умолчанию
- `--allow-fs-read=<path>` — whitelist путей для чтения
- `--allow-fs-write=<path>` — whitelist путей для записи
- `--allow-net` — ограничить сетевой доступ
- `--allow-child-process` — контроль порождения дочерних процессов
- `--allow-worker` — контроль worker threads
- `--allow-addons` — контроль нативных аддонов

**Ограничения:**
- Не предотвращает доступ через `node:sqlite` или другие не-`fs` модули
- Существующие file descriptors обходят permission model
- Child process ограничения all-or-nothing

### Решение B: Kernel-Level Sandboxing с Landlock

Для Linux ядра Android (5.13+) Landlock LSM обеспечивает ограничения на уровне ядра:

```json
{
  "filesystem": {
    "read_file": ["/data/user/0/com.app/files/projects/*"],
    "write": ["/data/user/0/com.app/files/projects/"]
  },
  "network": {
    "allow_hosts": ["127.0.0.1"]
  }
}
```

### Решение C: Динамическое патчение require() (In-Process)

```javascript
const Module = require('module');
const allowedModules = new Set(['vscode', 'path', 'os', 'crypto', 'events']);

const originalResolve = Module._resolveFilename;
Module._resolveFilename = function(request, parent, isMain, options) {
  if (!allowedModules.has(request) && !request.startsWith('./')) {
    throw new Error('Module "' + request + '" is not allowed');
  }
  return originalResolve.call(this, request, parent, isMain, options);
};
```

**Слабость:** Обходится через `process.binding()`, `eval()` или нативные аддоны. Использовать только как defense-in-depth.

### Рекомендуемая архитектура

```
Android App (UID: u0_aXX)
  Node.js Main Process
    --permission --allow-net=127.0.0.1
    Landlock: restrict fs/network
    Ext 1 (fork) --permission --allow-fs-read=/ws/*
    Ext 2 (fork) --permission --allow-fs-read=/ws/*
```

---

## 10.2 Localhost exposure — сетевая изоляция

### Проблема
Если Node.js слушает на `0.0.0.0:PORT`, любое приложение на устройстве может подключиться.

### Решение A: Unix Domain Socket в приватной директории

**Критическая находка:** Android local sockets по умолчанию используют abstract namespace без файловых разрешений! Нужно filesystem-based socket:

```javascript
const socketPath = path.join(
  process.env.ANDROID_DATA || '/data/user/0/com.your.app',
  'files',
  'node-server.sock'
);

fs.mkdirSync(path.dirname(socketPath), { recursive: true, mode: 0o700 });
server.listen(socketPath, () => {
  fs.chmodSync(socketPath, 0o600);
});
```

### Решение B: Привязка только к loopback

```javascript
server.listen(PORT, '127.0.0.1', () => {
  console.log('Listening on 127.0.0.1:' + PORT);
});
```

### Решение C: Peer Authentication через UID

```c
struct ucred cred;
socklen_t len = sizeof(cred);
getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &cred, &len);
if (cred.uid != getuid()) {
    close(client_fd);
}
```

### Решение D: Token-Based Authentication

```javascript
const authToken = crypto.randomBytes(32).toString('hex');
wss.on('connection', (ws, req) => {
  const url = new URL(req.url, 'http://localhost');
  if (url.searchParams.get('token') !== authToken) {
    ws.close(4001, 'Unauthorized');
  }
});
```

### Сводная таблица

| Метод | Безопасность | Сложность | Примечания |
|-------|-------------|-----------|------------|
| Abstract namespace socket | НЕТ | Низкая | Любое приложение подключается |
| Filesystem socket в приватной dir | Высокий | Низкая | DAC + SELinux |
| Привязка к 127.0.0.1 | Средний | Низкая | Любое приложение на loopback |
| Unix socket + peercred | Очень высокий | Средняя | Требует N-API/C код |
| Token auth через WebSocket | Высокий | Низкая | На уровне приложения |

---

## Ключевые библиотеки и инструменты

| Инструмент | Назначение | Зрелость |
|------------|-----------|----------|
| --permission (Node.js 22+) | Процесс-уровневые ограничения fs/net/child-process | Стабильный |
| nono (Landlock sandbox) | Ядерные ограничения fs/network | Активный |
| nodejs-mobile | Встраивание Node.js в Android/iOS приложения | Продакшн |

## Критические предупреждения

1. **Модуль `vm` Node.js НЕ является security boundary.** Множество CVE доказывают sandbox escapes. Никогда не полагаться на него для недоверенного кода.
2. **Permission model НЕ покрывает:** `node:sqlite`, существующие fd, OpenSSL engines.
3. **Abstract namespace sockets всегда доступны.** Всегда использовать filesystem-based sockets.
4. **`127.0.0.1` binding НЕ ограничивает WebView.** Другие приложения на loopback могут подключиться.
5. **Supply chain атаки через npm реальны.** 8.5% из 27,261 расширений VS Code раскрывают чувствительные данные.
