# Форк Shotnix

[Оригинал Shotnix](https://github.com/OMARVII/Shotnix) подключён как `upstream`. Локальная `main` отслеживает `origin/main` в [форке Павла](https://github.com/pavelshubskiy/Shotnix).

Стартовая версия — `v0.33.2-beta`, коммит `f69eb149ec38ceff453eb65e2f2c089bed4e972c`. Лицензия проекта — [MIT](LICENSE). Сведения о сторонних компонентах хранятся в [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Сборка и тесты

Пакет рассчитан на macOS 13 и новее, манифест требует Swift 5.9 или новее. Выполняй команды из корня репозитория.

```sh
swift build
swift test
```

Для обновления форка закрой `Shotnix Fork` и запусти `bash build-app.sh --local-fork`. Скрипт обновляет `Shotnix Fork.app` в корне репозитория с постоянным идентификатором `ru.shubskiy.shotnix.fork` и сертификатом `Shotnix Fork Local Code Signing` из связки ключей login. Сборка требует полный Xcode для SwiftUI-превью в KeyboardShortcuts. Если бинарник и ресурсы уже собраны, укажи их каталог через `SHOTNIX_FORK_BUILD_DIR`.

Запуск `build-app.sh` без аргументов предназначен для обычной сборки Shotnix и заменяет `/Applications/Shotnix.app`.

## Обновление из оригинала

```sh
git fetch upstream --tags
git log --oneline main..upstream/main
```

Просмотри изменения перед переносом в форк. Решения по обновлениям и результаты проверок записывай в `notes/`.
