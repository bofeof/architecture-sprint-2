#!/bin/bash

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

CONFIG_RS="config_server"
CONFIG_NODES=("configSrv1:27017" "configSrv2:27017" "configSrv3:27017")

SHARD1_RS="shard1"
SHARD1_PORT=27018
SHARD1_NODES=("shard1a:27018" "shard1b:27018" "shard1c:27018")

SHARD2_RS="shard2"
SHARD2_PORT=27019
SHARD2_NODES=("shard2a:27019" "shard2b:27019" "shard2c:27019")

MONGOS_CONTAINER="mongos_router1"
MONGOS_PORT=27020

DB_NAME="somedb"
COLLECTION_NAME="helloDoc"

API_URL="http://localhost:8080/${COLLECTION_NAME}/count"

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
CONFIG_MEMBERS=$(for i in "${!CONFIG_NODES[@]}"; do echo "{ _id: $i, host: \"${CONFIG_NODES[$i]}\" },"; done | tr -d '\n' | sed 's/,$//')

if docker exec configSrv1 mongosh --eval "
rs.initiate({
  _id: \"$CONFIG_RS\",
  configsvr: true,
  members: [$CONFIG_MEMBERS]
})"; then
  log_success "Config-сервер инициализирован"
else
  log_error "Ошибка при инициализации config-сервера"
fi

sleep 10

log_info "Инициализация shard1 реплика-сета"
SHARD1_MEMBERS=$(for i in "${!SHARD1_NODES[@]}"; do echo "{ _id: $i, host: \"${SHARD1_NODES[$i]}\" },"; done | tr -d '\n' | sed 's/,$//')

if docker exec shard1a mongosh --port $SHARD1_PORT --eval "
rs.initiate({
  _id: \"$SHARD1_RS\",
  members: [$SHARD1_MEMBERS]
})"; then
  log_success "shard1 реплика-сет инициализирован"
else
  log_error "Ошибка при инициализации shard1 реплика-сета"
fi

sleep 10

log_info "Инициализация shard2 реплика-сета"
SHARD2_MEMBERS=$(for i in "${!SHARD2_NODES[@]}"; do echo "{ _id: $i, host: \"${SHARD2_NODES[$i]}\" },"; done | tr -d '\n' | sed 's/,$//')

if docker exec shard2a mongosh --port $SHARD2_PORT --eval "
rs.initiate({
  _id: \"$SHARD2_RS\",
  members: [$SHARD2_MEMBERS]
})"; then
  log_success "shard2 реплика-сет инициализирован"
else
  log_error "Ошибка при инициализации shard2 реплика-сета"
fi

sleep 10

log_info "Добавление шардов и настройка шардирования через $MONGOS_CONTAINER"
if docker exec $MONGOS_CONTAINER mongosh --port $MONGOS_PORT --eval "
sh.addShard(\"$SHARD1_RS/${SHARD1_NODES[*]// /,}\");
sh.addShard(\"$SHARD2_RS/${SHARD2_NODES[*]// /,}\");
sh.enableSharding(\"$DB_NAME\");
sh.shardCollection(\"$DB_NAME.$COLLECTION_NAME\", { \"name\": \"hashed\" });
db = db.getSiblingDB(\"$DB_NAME\");
for (var i = 0; i < 1000; i++) db.$COLLECTION_NAME.insertOne({age: i, name: \"ly\" + i});
"; then
  log_success "Шарды добавлены и коллекция зашардирована"
else
  log_error "Ошибка при добавлении шардов или при шардировании коллекции"
fi

sleep 10

log_info "Проверка количества документов в базе"
if docker exec $MONGOS_CONTAINER mongosh --port $MONGOS_PORT --eval "
db = db.getSiblingDB(\"$DB_NAME\");
print(\"Всего документов: \" + db.$COLLECTION_NAME.countDocuments());
"; then
  log_success "Документы успешно подсчитаны"
else
  log_error "Ошибка при подсчёте документов"
fi

sleep 5

log_info "Проверка shard1a"
if docker exec shard1a mongosh --port $SHARD1_PORT --eval "
db = db.getSiblingDB(\"$DB_NAME\");
print(\"Количество документов в shard1a: \" + db.$COLLECTION_NAME.countDocuments());
"; then
  log_success "Shard1a проверен"
else
  log_error "Ошибка при проверке shard1a"
fi

sleep 5

log_info "Проверка shard2a"
if docker exec shard2a mongosh --port $SHARD2_PORT --eval "
db = db.getSiblingDB(\"$DB_NAME\");
print(\"Количество документов в shard2a: \" + db.$COLLECTION_NAME.countDocuments());
"; then
  log_success "Shard2a проверен"
else
  log_error "Ошибка при проверке shard2a"
fi

sleep 5

log_info "Проверка доступности методов в http://localhost:8080/docs"
response=$(curl -fs "$API_URL")
if [ $? -eq 0 ]; then
  echo "Ответ от сервера: $response"
  log_success "Методы доступны, данные с БД можно получить"
else
  log_error "Методы недоступны, данные с БД нельзя получить"
fi

sleep 5

log_info "Проверка реплик в первом шарде"
ans=$(docker exec shard1a mongosh --port $SHARD1_PORT --eval '
rs.status().members.forEach(m => print(m.name + " — " + m.stateStr))
')
if [ $? -eq 0 ]; then
  echo "Информация по первому шарду: $ans"
  log_success "ОК"
else
  log_error "Информацию получить нельзя"
fi

sleep 5

log_info "Проверка реплик во втором шарде"
ans=$(docker exec shard2a mongosh --port $SHARD2_PORT --eval '
rs.status().members.forEach(m => print(m.name + " — " + m.stateStr))
')
if [ $? -eq 0 ]; then
  echo "Информация по второму шарду: $ans"
  log_success "ОК"
else
  log_error "Информацию получить нельзя"
fi

log_success "Финиш"
