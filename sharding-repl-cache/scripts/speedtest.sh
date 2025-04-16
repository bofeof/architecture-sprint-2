#!/bin/bash

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

log_success() {
  echo -e "${GREEN}[✔] $1${NC}"
}

log_error() {
  echo -e "${RED}[✘] $1${NC}"
}

log_info() {
  echo -e "[...] $1"
}

log_info "Старт"
sleep 3

URL="http://localhost:8080/helloDoc/users"
ATTEMPTS=5

log_info "Запуск тестов скорости запросов с использованием кеша. Проверка GET-запроса: $URL"

for i in $(seq 1 $ATTEMPTS); do
  log_info "Попытка №$i"

  time_output=$(curl -w "Время выполнения: %{time_total} сек\n" -o /dev/null -s "$URL")

  if [ $? -eq 0 ]; then
    log_success "Запрос успешен."
    echo "$time_output"
  else
    log_error "Ошибка при выполнении запроса."
  fi
  sleep 2
done

log_success "Финиш"
