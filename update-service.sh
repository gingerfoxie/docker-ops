#!/bin/bash

# Умный скрипт обновления Docker-сервиса с бэкапом volume и БД
# Имя бэкапа: <volume/db_name>_<timestamp>.tar.gz / .sql

set -euo pipefail

# === НАСТРОЙКА: Укажите имя проекта Docker Compose ===
PROJECT_NAME="my-poject"
# ===================================================

usage() {
    cat <<EOF
Использование: $0 --service <имя_сервиса> --compose <путь_к_docker-compose.yml> --env <путь_к_.env>

Пример:
    $0 --service my-poject_frontend --compose ./docker-compose.yml --env ./.env

Опции:
    --service   Имя сервиса (как в docker-compose.yml)
    --compose   Путь к docker-compose.yml
    --env       Путь к .env файлу
    --help      Показать справку
EOF
    exit 1
}

# Инициализация параметров
SERVICE_NAME=""
COMPOSE_FILE=""
ENV_FILE=""

# Парсинг аргументов
TEMP=$(getopt -o '' --long service:,compose:,env:,help -- "$@")
if [ $? -ne 0 ]; then
    echo "❌ Ошибка парсинга аргументов. Используйте --help."
    exit 1
fi

eval set -- "$TEMP"

while true; do
    case "$1" in
        --service)
            SERVICE_NAME="$2"
            shift 2
            ;;
        --compose)
            COMPOSE_FILE="$2"
            shift 2
            ;;
        --env)
            ENV_FILE="$2"
            shift 2
            ;;
        --help)
            usage
            ;;
        --)
            shift
            break
            ;;
        *)
            echo "❌ Внутренняя ошибка!"
            exit 1
            ;;
    esac
done

# Проверка обязательных параметров
if [ -z "$SERVICE_NAME" ] || [ -z "$COMPOSE_FILE" ] || [ -z "$ENV_FILE" ]; then
    echo "❌ Все параметры обязательны."
    usage
fi

# Проверка существования файлов
for file in "$COMPOSE_FILE" "$ENV_FILE"; do
    if [ ! -f "$file" ]; then
        echo "❌ Файл не найден: $file"
        exit 1
    fi
done

# Директории бэкапов
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_BASE_DIR="$SCRIPT_DIR/backups"
BACKUP_SERVICE_DIR="$BACKUP_BASE_DIR/$SERVICE_NAME"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
mkdir -p "$BACKUP_SERVICE_DIR"

# Функция для запуска docker-compose с общими параметрами
dc() {
    docker-compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" --env-file "$ENV_FILE" "$@"
}

# === Начало выполнения ===
echo "=== 🔄 Обновление сервиса: $SERVICE_NAME ==="
echo "📦 Проект: $PROJECT_NAME"
echo "📄 Docker-compose: $COMPOSE_FILE"
echo "🔐 Env файл: $ENV_FILE"
echo "💾 Бэкапы: $BACKUP_SERVICE_DIR"

# Проверка, существует ли сервис
echo "🔍 Проверка наличия сервиса '$SERVICE_NAME'..."
dc config --services | grep -q "^$SERVICE_NAME$" || {
    echo "❌ Сервис '$SERVICE_NAME' не найден в docker-compose.yml"
    echo
    echo "📋 Доступные сервисы:"
    echo "---------------------"
    dc config --services || echo "Не удалось загрузить список сервисов."
    echo "---------------------"
    echo "💡 Убедитесь, что имя сервиса указано точно"
    exit 1
}

# === Поиск контейнера через docker-compose ===
echo "🔍 Поиск контейнера для сервиса '$SERVICE_NAME'..."

CONTAINER_ID=$(dc ps -q "$SERVICE_NAME" 2>/dev/null)

if [ -z "$CONTAINER_ID" ]; then
    echo "❌ Контейнер для сервиса '$SERVICE_NAME' не найден."
    echo "💡 Убедитесь, что сервис запущен."
    echo "📋 Запущенные контейнеры (фильтр по имени сервиса):"
    docker ps --filter "name=${SERVICE_NAME}" --format "table {{.Names}}\t{{.Status}}"
    exit 1
fi

echo "✅ Найден контейнер: $CONTAINER_ID"

# === Получение имени volume через docker inspect ===
echo "🔍 Определение volume через docker inspect..."

VOLUME_NAME=$(docker inspect "$CONTAINER_ID" --format '
{{- range .Mounts }}
  {{- if eq .Type "volume" }}
    {{- .Name }}
  {{- end }}
{{- end }}
' | tr -d '[:space:]' | head -n1)

if [ -n "$VOLUME_NAME" ]; then
    echo "✅ Найден volume: $VOLUME_NAME"
else
    echo "⚠️  У сервиса нет volume-маунтов. Используем имя сервиса."
    VOLUME_NAME="$SERVICE_NAME"
fi

# === Бэкап БД (если это сервис db_postgres) ===
if [ "$SERVICE_NAME" = "db_postgres" ]; then
    echo "💾 Создание бэкапа базы данных PostgreSQL..."

    # Загружаем параметры из .env
    DB_NAME=$(grep "^POSTGRES_DB=" "$ENV_FILE" | cut -d'=' -f2)
    DB_USER=$(grep "^POSTGRES_USER=" "$ENV_FILE" | cut -d'=' -f2)
    DB_CONTAINER="my-poject_db"

    if [ -z "$DB_NAME" ] || [ -z "$DB_USER" ]; then
        echo "❌ Не удалось получить параметры БД из .env"
        exit 1
    fi

    DB_BACKUP_NAME="${DB_NAME}_${TIMESTAMP}.sql"
    DB_BACKUP_PATH="$BACKUP_SERVICE_DIR/$DB_BACKUP_NAME"

    echo "📦 Создание бэкапа БД: $DB_BACKUP_NAME"
    if docker exec "$DB_CONTAINER" pg_dump -U "$DB_USER" -d "$DB_NAME" --clean --if-exists > "$DB_BACKUP_PATH"; then
        echo "✅ Бэкап БД создан: $DB_BACKUP_PATH"
    else
        echo "❌ Ошибка при создании бэкапа БД!"
        exit 1
    fi
fi

# === Генерация имени бэкапа контейнера ===
CONTAINER_BACKUP_NAME="${VOLUME_NAME}_${TIMESTAMP}.tar.gz"
CONTAINER_BACKUP_PATH="$BACKUP_SERVICE_DIR/$CONTAINER_BACKUP_NAME"

# === Остановка и бэкап контейнера ===
echo "🛑 Остановка сервиса..."
dc stop "$SERVICE_NAME" >/dev/null 2>&1 || true

# === Создание бэкапа файловой системы контейнера ===
echo "📦 Создание бэкапа контейнера: $CONTAINER_BACKUP_NAME"
if docker export "$CONTAINER_ID" | gzip -c > "$CONTAINER_BACKUP_PATH" 2>/dev/null; then
    echo "✅ Бэкап контейнера создан: $CONTAINER_BACKUP_PATH"
else
    echo "❌ Ошибка при создании бэкапа контейнера!"
    exit 1
fi

# === Удаление старого контейнера ===
echo "🗑️ Удаление старого контейнера..."
dc rm -f "$SERVICE_NAME" >/dev/null 2>&1 || true

# === Обновление образа ===
echo "🔄 Обновление образа..."
dc pull "$SERVICE_NAME"

# === Запуск нового контейнера ===
echo "🚀 Запуск обновлённого сервиса..."
dc up -d "$SERVICE_NAME"

# === Проверка статуса ===
echo "🔍 Проверка состояния сервиса..."
sleep 3
if dc ps "$SERVICE_NAME" | grep -q "Up "; then
    echo "✅ Сервис '$SERVICE_NAME' успешно обновлён и запущен"
else
    echo "❌ Сервис '$SERVICE_NAME' не запущен. Проверьте логи:"
    dc logs "$SERVICE_NAME"
    exit 1
fi

# === Финал ===
echo
echo "🎉 === Обновление завершено ==="
echo "💾 Бэкап контейнера: $CONTAINER_BACKUP_PATH"
if [ "$SERVICE_NAME" = "db_postgres" ]; then
    echo "💾 Бэкап БД: $DB_BACKUP_PATH"
fi
echo "💡 Для восстановления используйте: restore-service.sh"