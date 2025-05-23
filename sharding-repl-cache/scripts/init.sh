#!/bin/bash

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

# Порты и адреса
CONFIG_RS_PORT=27017
SHARD1_RS_PORT=27018
SHARD2_RS_PORT=27019
MONGOS_PORT=27020
APP_URL="http://localhost:8080"
CHECK_URL="$APP_URL/helloDoc/users"

# Имена базы и коллекции
DB_NAME="somedb"
COLLECTION_NAME="helloDoc"

ATTEMPTS=5

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

log_info "Инициализация config-сервера"
if docker exec configSrv1 mongosh --eval "
rs.initiate({
  _id: 'config_server',
  configsvr: true,
  members: [
    { _id: 0, host: 'configSrv1:$CONFIG_RS_PORT' },
    { _id: 1, host: 'configSrv2:$CONFIG_RS_PORT' },
    { _id: 2, host: 'configSrv3:$CONFIG_RS_PORT' }
  ]
})"; then
  log_success "Config-сервер инициализирован"
else
  log_error "Ошибка при инициализации config-сервера"
fi

sleep 10

log_info "Инициализация shard1 реплика-сета"
if docker exec shard1a mongosh --port $SHARD1_RS_PORT --eval "
rs.initiate({
  _id: 'shard1',
  members: [
    { _id: 0, host: 'shard1a:$SHARD1_RS_PORT' },
    { _id: 1, host: 'shard1b:$SHARD1_RS_PORT' },
    { _id: 2, host: 'shard1c:$SHARD1_RS_PORT' }
  ]
})"; then
  log_success "shard1 реплика-сет инициализирован"
else
  log_error "Ошибка при инициализации shard1 реплика-сета"
fi

sleep 10

log_info "Инициализация shard2 реплика-сета"
if docker exec shard2a mongosh --port $SHARD2_RS_PORT --eval "
rs.initiate({
  _id: 'shard2',
  members: [
    { _id: 0, host: 'shard2a:$SHARD2_RS_PORT' },
    { _id: 1, host: 'shard2b:$SHARD2_RS_PORT' },
    { _id: 2, host: 'shard2c:$SHARD2_RS_PORT' }
  ]
})"; then
  log_success "shard2 реплика-сет инициализирован"
else
  log_error "Ошибка при инициализации shard2 реплика-сета"
fi

sleep 10

log_info "Добавление шардов и настройка шардирования через mongos_router1"
if docker exec mongos_router1 mongosh --port $MONGOS_PORT --eval "
sh.addShard('shard1/shard1a:$SHARD1_RS_PORT,shard1b:$SHARD1_RS_PORT,shard1c:$SHARD1_RS_PORT');
sh.addShard('shard2/shard2a:$SHARD2_RS_PORT,shard2b:$SHARD2_RS_PORT,shard2c:$SHARD2_RS_PORT');
sh.enableSharding('$DB_NAME');
sh.shardCollection('$DB_NAME.$COLLECTION_NAME', { 'name': 'hashed' });
db = db.getSiblingDB('$DB_NAME');
for (var i = 0; i < 1000; i++) db.$COLLECTION_NAME.insertOne({age: i, name: 'ly' + i});
"; then
  log_success "Шарды добавлены и коллекция зашардирована"
else
  log_error "Ошибка при добавлении шардов или при шардировании коллекции"
fi

sleep 10

log_info "Проверка количества документов в базе"
if docker exec mongos_router1 mongosh --port $MONGOS_PORT --eval "
db = db.getSiblingDB('$DB_NAME');
print('Всего документов: ' + db.$COLLECTION_NAME.countDocuments());
"; then
  log_success "Документы успешно подсчитаны"
else
  log_error "Ошибка при подсчёте документов"
fi

sleep 3

log_info "Проверка shard1a"
if docker exec shard1a mongosh --port $SHARD1_RS_PORT --eval "
db = db.getSiblingDB('$DB_NAME');
print('Количество документов в shard1a: ' + db.$COLLECTION_NAME.countDocuments());
"; then
  log_success "Shard1a проверен"
else
  log_error "Ошибка при проверке shard1a"
fi

sleep 3

log_info "Проверка shard2a"
if docker exec shard2a mongosh --port $SHARD2_RS_PORT --eval "
db = db.getSiblingDB('$DB_NAME');
print('Количество документов в shard2a: ' + db.$COLLECTION_NAME.countDocuments());
"; then
  log_success "Shard2a проверен"
else
  log_error "Ошибка при проверке shard2a"
fi

sleep 3

log_info "Проверка доступности методов в $APP_URL/docs"
response=$(curl -fs "$APP_URL/$COLLECTION_NAME/count")
if [ $? -eq 0 ]; then
  echo "Ответ от сервера: $response"
  log_success "Методы доступны, данные с БД можно получить"
else
  log_error "Методы недоступны, данные с БД нельзя получить"
fi

sleep 3

log_info "Проверка доступности методов в $APP_URL/"
response=$(curl -fs "$APP_URL/")
if [ $? -eq 0 ]; then
  echo "Ответ от сервера: $response"
  log_success "Localhost:8080/ доступен"
else
  log_error "Localhost:8080/ недоступен"
fi

sleep 3

log_info "Проверка реплик в первом шарде"
ans=$(docker exec shard1a mongosh --port $SHARD1_RS_PORT --eval "rs.status().members.forEach(m => print(m.name + ' — ' + m.stateStr))")
if [ $? -eq 0 ]; then
  echo "Информация по первому шарду: $ans"
  log_success "ОК"
else
  log_error "Информацию получить нельзя"
fi

sleep 3

log_info "Проверка реплик во втором шарде"
ans=$(docker exec shard2a mongosh --port $SHARD2_RS_PORT --eval "rs.status().members.forEach(m => print(m.name + ' — ' + m.stateStr))")
if [ $? -eq 0 ]; then
  echo "Информация по второму шарду: $ans"
  log_success "ОК"
else
  log_error "Информацию получить нельзя"
fi

sleep 3

log_info "Запуск тестов скорости запросов с использованием кеша. Проверка GET-запроса: $CHECK_URL"
for i in $(seq 1 $ATTEMPTS); do
  log_info "Попытка №$i"
  time_output=$(curl -w "Время выполнения: %{time_total} сек\n" -o /dev/null -s "$CHECK_URL")
  if [ $? -eq 0 ]; then
    log_success "Запрос успешен."
    echo "$time_output"
  else
    log_error "Ошибка при выполнении запроса."
  fi
  sleep 2
done

log_success "Финиш"
