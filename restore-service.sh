#!/bin/bash

# Скрипт восстановления Docker-сервиса из бэкапа
# Поддерживает восстановление volume и бэкапа базы данных

set -euo pipefail

# === НАСТРОЙКА: Укажите имя проекта Docker Compose ===
PROJECT_NAME="my-poject"
# ===================================================

usage() {
    cat <<EOF
Использование: $0 --service <имя_сервиса> --compose <путь_к_docker-compose.yml> --env <путь_к_.env> [--backup <путь_к_бэкапу>]

Примеры:
    $0 --service my-poject_frontend --compose ./docker-compose.yml --env ./.env
    $0 --service my-poject_frontend --compose ./docker-compose.yml --env ./.env --backup ./backups/my-poject_frontend/volume_20231201_120000.tar.gz

Опции:
    --service   Имя сервиса (как в docker-compose.yml)
    --compose   Путь к docker-compose.yml
    --env       Путь к .env файлу
    --backup    Путь к конкретному бэкапу (опционально)
    --help      Показать справку
EOF
    exit 1
}

# Инициализация параметров
SERVICE_NAME=""
COMPOSE_FILE=""
ENV_FILE=""
BACKUP_FILE=""

# Парсинг аргументов
TEMP=$(getopt -o '' --long service:,compose:,env:,backup:,help -- "$@")
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
        --backup)
            BACKUP_FILE="$2"
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
    echo "❌ Обязательные параметры: --service, --compose, --env"
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

# Функция для запуска docker-compose с общими параметрами
dc() {
    docker-compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" --env-file "$ENV_FILE" "$@"
}

# === Начало выполнения ===
echo "=== 🔁 Восстановление сервиса: $SERVICE_NAME ==="
echo "📦 Проект: $PROJECT_NAME"
echo "📄 Docker-compose: $COMPOSE_FILE"
echo "🔐 Env файл: $ENV_FILE"

if [ -n "$BACKUP_FILE" ]; then
    echo "📂 Используется бэкап: $BACKUP_FILE"
else
    echo "📂 Автоматический выбор бэкапа из: $BACKUP_SERVICE_DIR"
fi

# Проверка, существует ли сервис
echo "🔍 Проверка наличия сервиса '$SERVICE_NAME'..."
dc config --services | grep -q "^$SERVICE_NAME$" || {
    echo "❌ Сервис '$SERVICE_NAME' не найден в docker-compose.yml"
    echo
    echo "📋 Доступные сервисы:"
    echo "---------------------"
    dc config --services || echo "Не удалось загрузить список сервисов."
    echo "---------------------"
    exit 1
}

# === Выбор бэкапа ===
if [ -n "$BACKUP_FILE" ]; then
    if [ ! -f "$BACKUP_FILE" ]; then
        echo "❌ Указанный бэкап не найден: $BACKUP_FILE"
        exit 1
    fi
    SELECTED_BACKUP="$BACKUP_FILE"
else
    # Поиск доступных бэкапов
    if [ ! -d "$BACKUP_SERVICE_DIR" ] || [ -z "$(ls -A "$BACKUP_SERVICE_DIR")" ]; then
        echo "❌ Директория бэкапов не найдена или пуста: $BACKUP_SERVICE_DIR"
        exit 1
    fi

    echo "🔍 Доступные бэкапы:"
    echo "--------------------"
    BACKUP_LIST=()
    BACKUP_INDEX=1
    for backup in "$BACKUP_SERVICE_DIR"/*.tar.gz "$BACKUP_SERVICE_DIR"/*.sql; do
        if [ -f "$backup" ]; then
            echo "$BACKUP_INDEX) $(basename "$backup")"
            BACKUP_LIST+=("$backup")
            ((BACKUP_INDEX++))
        fi
    done
    echo "--------------------"

    if [ ${#BACKUP_LIST[@]} -eq 0 ]; then
        echo "❌ Не найдено бэкапов в директории: $BACKUP_SERVICE_DIR"
        exit 1
    fi

    # Выбор бэкапа
    while true; do
        read -p "Выберите номер бэкапа для восстановления (1-${#BACKUP_LIST[@]}): " CHOICE
        if [[ "$CHOICE" =~ ^[0-9]+$ ]] && [ "$CHOICE" -ge 1 ] && [ "$CHOICE" -le ${#BACKUP_LIST[@]} ]; then
            SELECTED_BACKUP="${BACKUP_LIST[$((CHOICE-1))]}"
            break
        else
            echo "❌ Неверный выбор. Введите число от 1 до ${#BACKUP_LIST[@]}"
        fi
    done
fi

echo "✅ Выбран бэкап: $(basename "$SELECTED_BACKUP")"

# === Определение типа бэкапа ===
if [[ "$SELECTED_BACKUP" == *.sql ]]; then
    BACKUP_TYPE="database"
    echo "💾 Тип бэкапа: База данных PostgreSQL"
elif [[ "$SELECTED_BACKUP" == *.tar.gz ]]; then
    BACKUP_TYPE="container"
    echo "💾 Тип бэкапа: Файловая система контейнера"
else
    echo "❌ Неизвестный тип бэкапа: $SELECTED_BACKUP"
    exit 1
fi

# === Восстановление базы данных ===
if [ "$BACKUP_TYPE" = "database" ]; then
    if [[ ! "$SERVICE_NAME" =~ (db|postgres|database|mysql|mongo) ]]; then
        echo "❌ Бэкап базы данных может быть восстановлен только для сервисов БД"
        exit 1
    fi

    echo "🔄 Восстановление базы данных из: $(basename "$SELECTED_BACKUP")"
    
    # Остановка сервиса
    echo "🛑 Остановка сервиса БД..."
    dc stop "$SERVICE_NAME" >/dev/null 2>&1 || true
    
    # Загрузка параметров из .env
    DB_NAME=$(grep "^POSTGRES_DB=" "$ENV_FILE" | cut -d'=' -f2)
    DB_USER=$(grep "^POSTGRES_USER=" "$ENV_FILE" | cut -d'=' -f2)
    
    if [ -z "$DB_NAME" ] || [ -z "$DB_USER" ]; then
        echo "❌ Не удалось получить параметры БД из .env"
        exit 1
    fi
    
    # Запуск контейнера в режиме восстановления
    echo "🚀 Запуск контейнера для восстановления..."
    dc up -d "$SERVICE_NAME"
    
    # Ожидание запуска PostgreSQL
    echo "⏳ Ожидание запуска PostgreSQL..."
    sleep 10
    
    # Получение ID контейнера
    DB_CONTAINER_ID=$(dc ps -q "$SERVICE_NAME" 2>/dev/null || true)
    if [ -z "$DB_CONTAINER_ID" ]; then
        echo "❌ Не удалось получить ID контейнера БД"
        exit 1
    fi
    
    # Копирование бэкапа в контейнер
    echo "📦 Копирование бэкапа в контейнер..."
    docker cp "$SELECTED_BACKUP" "$DB_CONTAINER_ID":/tmp/restore.sql
    
    # Восстановление базы данных
    echo "🔄 Восстановление базы данных..."
    if docker exec "$DB_CONTAINER_ID" psql -U "$DB_USER" -d "$DB_NAME" -f /tmp/restore.sql; then
        echo "✅ База данных успешно восстановлена"
        # Очистка временного файла
        docker exec "$DB_CONTAINER_ID" rm -f /tmp/restore.sql 2>/dev/null || true
        echo "✅ Восстановление базы данных завершено"
    else
        echo "❌ Ошибка при восстановлении базы данных!"
        exit 1
    fi
    
    exit 0
fi

# === Восстановление файловой системы контейнера ===
if [ "$BACKUP_TYPE" = "container" ]; then
    echo "🔄 Восстановление файловой системы из: $(basename "$SELECTED_BACKUP")"
    
    # Остановка сервиса
    echo "🛑 Остановка сервиса..."
    dc stop "$SERVICE_NAME" >/dev/null 2>&1 || true
    
    # Удаление старого контейнера
    echo "🗑️ Удаление старого контейнера..."
    dc rm -f "$SERVICE_NAME" >/dev/null 2>&1 || true
    
    # Создание нового контейнера с тем же образом
    echo "🚀 Создание нового контейнера..."
    dc up -d "$SERVICE_NAME"
    
    # Ожидание запуска контейнера
    echo "⏳ Ожидание запуска контейнера..."
    sleep 5
    
    # Получение ID нового контейнера
    NEW_CONTAINER_ID=$(dc ps -q "$SERVICE_NAME" 2>/dev/null || true)
    if [ -z "$NEW_CONTAINER_ID" ]; then
        echo "❌ Не удалось получить ID нового контейнера"
        exit 1
    fi
    
    echo "✅ Новый контейнер создан: $NEW_CONTAINER_ID"
    
    # Остановка контейнера для восстановления данных
    dc stop "$SERVICE_NAME" >/dev/null 2>&1 || true
    
    # Распаковка бэкапа в контейнер
    echo "📦 Распаковка бэкапа в контейнер..."
    if zcat "$SELECTED_BACKUP" | docker exec -i "$NEW_CONTAINER_ID" tar -C / --exclude=proc --exclude=sys --exclude=dev --exclude=tmp -xf - 2>/dev/null; then
        echo "✅ Файловая система успешно восстановлена"
    else
        echo "⚠️  Предупреждение: возможны ошибки при распаковке (это нормально для некоторых системных директорий)"
    fi
    
    # Запуск контейнера после восстановления
    echo "🚀 Запуск контейнера после восстановления..."
    dc up -d "$SERVICE_NAME"
    
    # Проверка статуса
    echo "🔍 Проверка состояния сервиса..."
    sleep 3
    if dc ps "$SERVICE_NAME" | grep -q "Up "; then
        echo "✅ Сервис '$SERVICE_NAME' успешно восстановлен и запущен"
        echo "✅ Восстановление файловой системы завершено"
    else
        echo "❌ Сервис '$SERVICE_NAME' не запущен. Проверьте логи:"
        dc logs "$SERVICE_NAME"
        exit 1
    fi
fi

# === Финал ===
echo
echo "🎉 === Восстановление завершено ==="
echo "📂 Использован бэкап: $(basename "$SELECTED_BACKUP")"