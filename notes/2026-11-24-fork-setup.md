# 24 ноября 2026. Настройка форка Shotnix

- В рабочую папку клонирован `OMARVII/Shotnix` с историей Git и тегами. База — `v0.33.2-beta` (`f69eb14`).
- На GitHub создан публичный форк `pavelshubskiy/Shotnix`. Оригинал подключён как `upstream`, форк — как `origin`. Локальная `main` отслеживает `origin/main`.
- Добавлены инструкции по работе с форком и журнал проекта. Исходная документация и лицензия сохранены.
- GitHub API подтвердил, что `pavelshubskiy/Shotnix` — форк `OMARVII/Shotnix`. На момент настройки `origin/main` и `upstream/main` указывали на один коммит.
- `swift package dump-package` прочитал манифест и обнаружил цели `ShotnixCore`, `Shotnix` и `ShotnixCoreTests`. Первый запуск упёрся в запрет записи в домашний кэш Clang. Проверка прошла с кэшами во временной папке. Сборку и тесты не запускали.
