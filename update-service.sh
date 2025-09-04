#!/bin/bash

# Умный скрипт обновления Docker-сервиса с бэкапом volume
# Имя бэкапа: <volume_name>_<timestamp>.tar.gz
# Использует docker-compose с явным указанием проекта

set -euo pipefail

# === НАСТРОЙКА: Укажите имя проекта Docker Compose ===
PROJECT_NAME="my_project"
# ===================================================

usage() {
    cat <<EOF
Использование: $0 --service <имя_сервиса> --compose <путь_к_docker-compose.yml> --env <путь_к_.env>

Пример:
    $0 --service my_project_frontend --compose ./docker-compose.yml --env ./.env

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
    echo "💡 Убедитесь, что имя сервиса указано точно (с учётом - и _)"
    exit 1
}

# Проверка, запущен ли контейнер
echo "🔍 Проверка статуса контейнера..."
dc ps "$SERVICE_NAME" >/dev/null || {
    echo "❌ Сервис '$SERVICE_NAME' не запущен или не существует в проекте '$PROJECT_NAME'."
    echo "💡 Запустите сервис сначала: docker-compose -p $PROJECT_NAME up -d $SERVICE_NAME"
    exit 1
}

# Получаем ID контейнера
CONTAINER_ID=$(dc ps -q "$SERVICE_NAME" | tr -d '[:space:]')
if [ -z "$CONTAINER_ID" ]; then
    echo "❌ Не удалось получить ID контейнера для сервиса '$SERVICE_NAME'"
    exit 1
fi
echo "✅ Найден контейнер: $CONTAINER_ID"

# === Получение имени volume через docker inspect (надёжно) ===
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
    echo "⚠️  Не найдено volume-маунтов. Используем имя сервиса."
    VOLUME_NAME="$SERVICE_NAME"
fi

# === Генерация имени бэкапа ===
BACKUP_NAME="${VOLUME_NAME}_${TIMESTAMP}.tar.gz"
BACKUP_PATH="$BACKUP_SERVICE_DIR/$BACKUP_NAME"

# === Остановка и бэкап ===
echo "🛑 Остановка сервиса..."
dc stop "$SERVICE_NAME" >/dev/null 2>&1 || true

# === Создание бэкапа ===
echo "📦 Создание бэкапа: $BACKUP_NAME"
if docker export "$CONTAINER_ID" | gzip -c > "$BACKUP_PATH" 2>/dev/null; then
    echo "✅ Бэкап успешно создан: $BACKUP_PATH"
else
    echo "❌ Ошибка при создании бэкапа!"
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
echo "💾 Бэкап сохранён: $BACKUP_PATH"
echo "💡 Для восстановления используйте: restore-service.sh --service $SERVICE_NAME --backup '$BACKUP_PATH'"