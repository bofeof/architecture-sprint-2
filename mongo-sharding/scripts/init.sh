#!/bin/bash

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

CONFIG_PORT=27017
SHARD1_PORT=27018
SHARD2_PORT=27019
MONGOS_PORT=27020
DB_NAME="somedb"
COLLECTION_NAME="helloDoc"

CONFIG_HOSTS=("configSrv1" "configSrv2" "configSrv3")
SHARD1_HOST="shard1"
SHARD2_HOST="shard2"
MONGOS_ROUTER="mongos_router1"

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
if docker exec ${CONFIG_HOSTS[0]} mongosh --eval "
rs.initiate({
  _id: 'config_server',
  configsvr: true,
  members: [
    { _id: 0, host: '${CONFIG_HOSTS[0]}:$CONFIG_PORT' },
    { _id: 1, host: '${CONFIG_HOSTS[1]}:$CONFIG_PORT' },
    { _id: 2, host: '${CONFIG_HOSTS[2]}:$CONFIG_PORT' }
  ]
})"; then
  log_success "Config-сервер инициализирован"
else
  log_error "Ошибка при инициализации config-сервера"
fi

sleep 10

log_info "Инициализация shard1"
if docker exec $SHARD1_HOST mongosh --port $SHARD1_PORT --eval "
rs.initiate({
  _id: 'shard1',
  members: [{ _id: 0, host: '$SHARD1_HOST:$SHARD1_PORT' }]
})"; then
  log_success "shard1 инициализирован"
else
  log_error "Ошибка при инициализации shard1"
fi

sleep 10

log_info "Инициализация shard2"
if docker exec $SHARD2_HOST mongosh --port $SHARD2_PORT --eval "
rs.initiate({
  _id: 'shard2',
  members: [{ _id: 0, host: '$SHARD2_HOST:$SHARD2_PORT' }]
})"; then
  log_success "shard2 инициализирован"
else
  log_error "Ошибка при инициализации shard2"
fi

sleep 10

log_info "Добавление шардов и настройка шардирования через $MONGOS_ROUTER"
if docker exec $MONGOS_ROUTER mongosh --port $MONGOS_PORT --eval "
sh.addShard('shard1/$SHARD1_HOST:$SHARD1_PORT');
sh.addShard('shard2/$SHARD2_HOST:$SHARD2_PORT');
sh.enableSharding('$DB_NAME');
sh.shardCollection('$DB_NAME.$COLLECTION_NAME', { 'name': 'hashed' });
db = db.getSiblingDB('$DB_NAME');
for (var i = 0; i < 1000; i++) db.$COLLECTION_NAME.insertOne({ age: i, name: 'ly' + i });
"; then
  log_success "Шарды добавлены и коллекция зашардирована"
else
  log_error "Ошибка при добавлении шардов или при шардировании коллекции"
fi

sleep 10

log_info "Проверка shard1"
if docker exec $SHARD1_HOST mongosh --port $SHARD1_PORT --eval "
db = db.getSiblingDB('$DB_NAME');
print('Количество документов в shard1: ' + db.$COLLECTION_NAME.countDocuments());
"; then
  log_success "Shard1 проверен"
else
  log_error "Ошибка при проверке shard1"
fi

sleep 10

log_info "Проверка shard2"
if docker exec $SHARD2_HOST mongosh --port $SHARD2_PORT --eval "
db = db.getSiblingDB('$DB_NAME');
print('Количество документов в shard2: ' + db.$COLLECTION_NAME.countDocuments());
"; then
  log_success "Shard2 проверен"
else
  log_error "Ошибка при проверке shard2"
fi

log_info "Проверка доступности методов в http://localhost:8080/docs"
response=$(curl -fs http://localhost:8080/$COLLECTION_NAME/count)
if [ $? -eq 0 ]; then
  echo "Ответ от сервера: $response"
  log_success "Методы доступны, данные с бд можно получить"
else
  log_error "Методы недоступны, данные с бд нельзя получить"
fi

log_success "Финиш"
