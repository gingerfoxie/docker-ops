# 🐳 docker-ops — умные скрипты для безопасного управления Docker-сервисами

> 🔧 Автоматизируй обновления. Сохрани данные. Возвращайся к рабочему состоянию.

**docker-ops** — это набор **надёжных Bash-скриптов** для безопасного обновления и восстановления Docker-сервисов.  
Скрипты автоматически делают **бэкапы volume и баз данных**, чтобы ты мог обновлять сервисы без страха потерять данные.

> 💡 Подходит для разработки, тестовых сред и небольших продакшенов, где важна простота и контроль.

---

## 📦 Что внутри?

| Скрипт | Описание |
|-------|---------|
| [`update-service.sh`](#update-service) | Обновляет **один сервис** с бэкапом volume и БД |
| [`update-all-services.sh`](#update-all-services) | Массовое обновление **всех сервисов** с бэкапами |
| [`restore-service.sh`](#restore-service) | Восстанавливает сервис из бэкапа (файлы или БД) |

---

## 🚀 Быстрый старт

1. Склонируй репозиторий:
  ```bash
  git clone https://github.com/gingerfoxie/docker-ops.git
  cd docker-ops
  ```

2. Дай права на выполнение:
  ```bash
  chmod +x *.sh
  ```

3.Настрой имя проекта (если нужно):
  ```bash
  #Открой любой скрипт и измени:
  PROJECT_NAME="my-poject"  # ← на своё имя проекта Docker 
  ```
🔧 Требования
bash ≥ 4
docker
docker-compose
gzip, getopt, grep, cut, tr
🔄 update-service.sh — Обновление одного сервиса
Обновляет один сервис с предварительным бэкапом volume и (для PostgreSQL) базы данных.

📌 Использование
```bash
./update-service.sh \
  --service my-poject_frontend \
  --compose ./docker-compose.yml \
  --env ./.env
```
✅ Что делает:
Проверяет существование сервиса
Останавливает контейнер
Делает бэкап:
Файлов через docker export
БД (если db_postgres) через pg_dump
Удаляет старый контейнер
Тянет новый образ и запускает сервис
💾 Бэкап сохраняется в: backups/<service_name>/<volume_name>_<timestamp>.tar.gz 

🔄 update-all-services.sh — Массовое обновление
Обновляет все сервисы из docker-compose.yml, делая бэкап каждого.

📌 Использование
```bash
./update-all-services.sh \
--compose ./docker-compose.yml \
--env ./.env
```
✅ Что делает:
Получает список всех сервисов
По очереди останавливает и бэкапит каждый
После всех бэкапов:
docker-compose down
docker-compose pull
docker-compose up -d
Показывает итоговый отчёт
⚠️ Если бэкап одного сервиса провалился — скрипт спросит, продолжать ли. 

🔁 restore-service.sh — Восстановление из бэкапа
Восстанавливает сервис из сохранённого бэкапа: файлов или базы данных.

📌 Использование
```bash
# Выбор бэкапа из списка
./restore-service.sh \
  --service my-poject_backend \
  --compose ./docker-compose.yml \
  --env ./.env
```
```bash
# Или с указанием конкретного файла
./restore-service.sh \
  --service db_postgres \
  --compose ./docker-compose.yml \
  --env ./.env \
  --backup ./backups/db_postgres/mydb_20250405_100000.sql
```

🛠️ Поддерживаемые типы:
.tar.gz — восстановление файловой системы контейнера
.sql — восстановление PostgreSQL (автоматически определяется)
```
🔐 Скрипт проверяет, что восстановление БД выполняется только для сервисов БД. 
```
💾 Где хранятся бэкапы?
  ```
  backups/
  └── <service_name>/
      ├── volume_20250405_100000.tar.gz
      └── mydb_20250405_100000.sql
  ```
```
📁 Директория backups/ создаётся автоматически. 
```

⚙️ Настройка
Измени имя проекта
В каждом скрипте найди строку:
```bash
PROJECT_NAME="my-poject"
```
и замени на имя своего Docker-проекта (то, что используется с -p в docker-compose).

Поддерживаемые БД
✅ PostgreSQL: автоматический бэкап и восстановление
🚧 MySQL / MongoDB — в планах
🧪 Примеры
```bash
# Обновить API-сервис
./update-service.sh --service my-poject_api --compose docker-compose.yml --env .env

# Обновить всё
./update-all-services.sh --compose docker-compose.yml --env .env

# Восстановить БД
./restore-service.sh --service db_postgres --compose docker-compose.yml --env .env
```

📂 Структура проекта
```
.
├── update-service.sh        # обновление одного сервиса
├── update-all-services.sh   # массовое обновление
├── restore-service.sh       # восстановление
├── backups/                 # (автосоздаётся) бэкапы
├── README.md
└── LICENSE
```
