#!/bin/bash

# Скрипт массового обновления всех Docker-сервисов с бэкапами
# Создает бэкапы volumes и БД для каждого сервиса, затем обновляет все контейнеры

set -euo pipefail

# === НАСТРОЙКА: Укажите имя проекта Docker Compose ===
PROJECT_NAME="my-poject"
# ===================================================

usage() {
    cat <<EOF
Использование: $0 --compose <путь_к_docker-compose.yml> --env <путь_к_.env>

Пример:
    $0 --compose ./docker-compose.yml --env ./.env

Опции:
    --compose   Путь к docker-compose.yml
    --env       Путь к .env файлу
    --help      Показать справку
EOF
    exit 1
}

# Инициализация параметров
COMPOSE_FILE=""
ENV_FILE=""

# Парсинг аргументов
TEMP=$(getopt -o '' --long compose:,env:,help -- "$@")
if [ $? -ne 0 ]; then
    echo "❌ Ошибка парсинга аргументов. Используйте --help."
    exit 1
fi

eval set -- "$TEMP"

while true; do
    case "$1" in
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
if [ -z "$COMPOSE_FILE" ] || [ -z "$ENV_FILE" ]; then
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
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
mkdir -p "$BACKUP_BASE_DIR"

# Функция для запуска docker-compose с общими параметрами
dc() {
    docker-compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" --env-file "$ENV_FILE" "$@"
}

# === Начало выполнения ===
echo "=== 🚀 Массовое обновление всех сервисов ==="
echo "📦 Проект: $PROJECT_NAME"
echo "📄 Docker-compose: $COMPOSE_FILE"
echo "🔐 Env файл: $ENV_FILE"
echo "💾 Бэкапы: $BACKUP_BASE_DIR"
echo

# Получение списка всех сервисов
echo "🔍 Получение списка всех сервисов..."
SERVICES=$(dc config --services 2>/dev/null)

if [ -z "$SERVICES" ]; then
    echo "❌ Не удалось получить список сервисов из docker-compose.yml"
    exit 1
fi

SERVICE_ARRAY=($SERVICES)
SERVICE_COUNT=${#SERVICE_ARRAY[@]}

echo "📋 Найдено сервисов: $SERVICE_COUNT"
echo "--------------------"
for service in "${SERVICE_ARRAY[@]}"; do
    echo "  • $service"
done
echo "--------------------"
echo

# Подтверждение
read -p "🔄 Начать массовое обновление всех сервисов? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "❌ Обновление отменено пользователем"
    exit 0
fi

echo
echo "=== 📦 Создание бэкапов для всех сервисов ==="
echo

# === СОЗДАНИЕ БЭКАПОВ ДЛЯ ВСЕХ СЕРВИСОВ ===
SUCCESS_COUNT=0
FAILED_SERVICES=()
TOTAL_SERVICES=${#SERVICE_ARRAY[@]}

for i in "${!SERVICE_ARRAY[@]}"; do
    SERVICE_NAME="${SERVICE_ARRAY[$i]}"
    current=$((i+1))
    
    echo "================================================================"
    echo "📦 Бэкап сервиса $current из $TOTAL_SERVICES: $SERVICE_NAME"
    echo "================================================================"
    
    # Создание директории бэкапа для сервиса
    BACKUP_SERVICE_DIR="$BACKUP_BASE_DIR/$SERVICE_NAME"
    mkdir -p "$BACKUP_SERVICE_DIR"
    
    # Проверка, существует ли сервис
    echo "🔍 Проверка наличия сервиса '$SERVICE_NAME'..."
    if ! dc config --services | grep -q "^$SERVICE_NAME$"; then
        echo "❌ Сервис '$SERVICE_NAME' не найден в docker-compose.yml"
        FAILED_SERVICES+=("$SERVICE_NAME (сервис не найден)")
        continue
    fi

    # Поиск контейнера через docker-compose
    echo "🔍 Поиск контейнера для сервиса '$SERVICE_NAME'..."
    CONTAINER_ID=$(dc ps -q "$SERVICE_NAME" 2>/dev/null || true)

    if [ -z "$CONTAINER_ID" ]; then
        echo "⚠️  Контейнер для сервиса '$SERVICE_NAME' не найден"
        echo "💡 Попытка запустить сервис перед созданием бэкапа..."
        if dc up -d "$SERVICE_NAME"; then
            echo "✅ Сервис '$SERVICE_NAME' успешно запущен"
            sleep 3
            CONTAINER_ID=$(dc ps -q "$SERVICE_NAME" 2>/dev/null || true)
            if [ -z "$CONTAINER_ID" ]; then
                echo "❌ Не удалось получить ID контейнера после запуска"
                FAILED_SERVICES+=("$SERVICE_NAME (контейнер не найден)")
                continue
            fi
        else
            echo "❌ Не удалось запустить сервис '$SERVICE_NAME'"
            FAILED_SERVICES+=("$SERVICE_NAME (не удалось запустить)")
            continue
        fi
    fi

    echo "✅ Найден контейнер: $CONTAINER_ID"

    # Получение имени volume через docker inspect
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

    # Бэкап БД (если это сервис базы данных)
    if [[ "$SERVICE_NAME" =~ (db|postgres|database|mysql|mongo) ]]; then
        echo "💾 Создание бэкапа базы данных..."
        
        # Для PostgreSQL
        if [[ "$SERVICE_NAME" =~ (postgres|db_postgres) ]]; then
            # Загружаем параметры из .env
            DB_NAME=$(grep "^POSTGRES_DB=" "$ENV_FILE" | cut -d'=' -f2)
            DB_USER=$(grep "^POSTGRES_USER=" "$ENV_FILE" | cut -d'=' -f2)
            
            if [ -n "$DB_NAME" ] && [ -n "$DB_USER" ]; then
                DB_BACKUP_NAME="${DB_NAME}_${TIMESTAMP}.sql"
                DB_BACKUP_PATH="$BACKUP_SERVICE_DIR/$DB_BACKUP_NAME"
                
                echo "📦 Создание бэкапа БД: $DB_BACKUP_NAME"
                if docker exec "$CONTAINER_ID" pg_dump -U "$DB_USER" -d "$DB_NAME" --clean --if-exists > "$DB_BACKUP_PATH"; then
                    echo "✅ Бэкап БД создан: $DB_BACKUP_PATH"
                    SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
                else
                    echo "❌ Ошибка при создании бэкапа БД!"
                    FAILED_SERVICES+=("$SERVICE_NAME (бэкап БД)")
                fi
            else
                echo "❌ Не удалось получить параметры БД из .env"
                FAILED_SERVICES+=("$SERVICE_NAME (параметры БД)")
            fi
        else
            echo "⚠️  Тип базы данных не поддерживается для автоматического бэкапа"
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))  # Считаем как успешный
        fi
    fi

    # Создание бэкапа файловой системы контейнера
    echo "📦 Создание бэкапа файловой системы контейнера..."
    CONTAINER_BACKUP_NAME="${VOLUME_NAME}_${TIMESTAMP}.tar.gz"
    CONTAINER_BACKUP_PATH="$BACKUP_SERVICE_DIR/$CONTAINER_BACKUP_NAME"
    
    if docker export "$CONTAINER_ID" | gzip -c > "$CONTAINER_BACKUP_PATH" 2>/dev/null; then
        echo "✅ Бэкап контейнера создан: $CONTAINER_BACKUP_PATH"
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    else
        echo "❌ Ошибка при создании бэкапа контейнера!"
        FAILED_SERVICES+=("$SERVICE_NAME (бэкап контейнера)")
    fi
    
    echo
done

# === ИТОГОВЫЙ ОТЧЕТ ПО БЭКАПАМ ===
echo "================================================================"
echo "📊 === ИТОГОВЫЙ ОТЧЕТ ПО БЭКАПАМ ==="
echo "================================================================"
echo "✅ Успешно создано бэкапов: $SUCCESS_COUNT"

if [ ${#FAILED_SERVICES[@]} -gt 0 ]; then
    echo "❌ Ошибок: ${#FAILED_SERVICES[@]}"
    echo "   Сервисы с ошибками:"
    for failed in "${FAILED_SERVICES[@]}"; do
        echo "   • $failed"
    done
    echo
    read -p "❓ Продолжить обновление несмотря на ошибки бэкапов? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "❌ Обновление отменено из-за ошибок бэкапов"
        exit 1
    fi
else
    echo "🎉 Все бэкапы успешно созданы!"
fi

echo
echo "=== 🚀 Обновление всех сервисов ==="
echo

# === ОБНОВЛЕНИЕ ВСЕХ СЕРВИСОВ ===
echo "🔄 Остановка всех сервисов..."
dc down 2>/dev/null || true

echo "🔄 Обновление всех образов..."
dc pull

echo "🚀 Запуск всех сервисов..."
dc up -d

echo "🔍 Проверка состояния сервисов..."
sleep 5

echo
echo "📊 === Текущий статус сервисов ==="
dc ps

# === ФИНАЛЬНЫЙ ОТЧЕТ ===
echo
echo "🎉 === Массовое обновление завершено ==="
echo "💾 Бэкапы сохранены в: $BACKUP_BASE_DIR"
echo "💡 Для восстановления отдельных сервисов используйте: restore-service.sh"