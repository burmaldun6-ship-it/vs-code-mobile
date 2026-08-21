# Android `libnode.so` builds

Этот репозиторий содержит GitHub Actions для сборки `libnode.so` под Android ARM64 из исходников. Локальная сборка не требуется.

## Workflows

- **Build nodejs-mobile 18.20.4 for Android** — стабильная сборка `nodejs-mobile` 18.20.4 через Android NDK r24 (`24.0.8215888`), по умолчанию `arm64`, API 24.
- **Build upstream Node.js 24.19.0 for Android** — экспериментальная сборка upstream Node.js 24.19.0 через NDK r27 (`27.0.12077973`), API 24 по умолчанию.

Оба workflow выполняются на `ubuntu-24.04`, создают ZIP и SHA-256 файл при успешной сборке и загружают логи независимо от результата.

## Как запустить

Откройте **Actions**, выберите нужный workflow и нажмите **Run workflow**.

Для стабильной сборки выберите архитектуру (`arm64`, `arm`, `x86` или `x86_64`).

Для экспериментальной сборки задайте `android_api` не ниже 24.

## Если Node.js 24.19.0 падает

Скачайте артефакт `build-logs-upstream-node-24` из запуска workflow и пришлите логи для анализа. В первую очередь нужны `download.log`, `configure.log`, `build.log`, `file.log`, `readelf.log`, `verify.log` и `package.log`.
