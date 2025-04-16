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

log_info "Инициализация config-сервера"
if docker exec configSrv1 mongosh --eval '
rs.initiate({
  _id: "config_server",
  configsvr: true,
  members: [
    { _id: 0, host: "configSrv1:27017" },
    { _id: 1, host: "configSrv2:27017" },
    { _id: 2, host: "configSrv3:27017" }
  ]
})'; then
  log_success "Config-сервер инициализирован"
else
  log_error "Ошибка при инициализации config-сервера"
fi

sleep 10

log_info "Инициализация shard1"
if docker exec shard1 mongosh --port 27018 --eval '
rs.initiate({
  _id: "shard1",
  members: [{ _id: 0, host: "shard1:27018" }]
})'; then
  log_success "shard1 инициализирован"
else
  log_error "Ошибка при инициализации shard1"
fi

sleep 10

log_info "Инициализация shard2"
if docker exec shard2 mongosh --port 27019 --eval '
rs.initiate({
  _id: "shard2",
  members: [{ _id: 0, host: "shard2:27019" }]
})'; then
  log_success "shard2 инициализирован"
else
  log_error "Ошибка при инициализации shard2"
fi

sleep 10

log_info "Добавление шардов и настройка шардирования через mongos_router1"
if docker exec mongos_router1 mongosh --port 27020 --eval '
sh.addShard("shard1/shard1:27018");
sh.addShard("shard2/shard2:27019");
sh.enableSharding("somedb");
sh.shardCollection("somedb.helloDoc", { "name": "hashed" });
db = db.getSiblingDB("somedb");
for (var i = 0; i < 1000; i++) db.helloDoc.insertOne({age: i, name: "ly" + i});
'; then
  log_success "Шарды добавлены и коллекция зашардирована"
else
  log_error "Ошибка при добавлении шардов или при шардировании коллекции"
fi

sleep 10


log_info "Проверка shard1"
if docker exec shard1 mongosh --port 27018 --eval '
db = db.getSiblingDB("somedb");
print("Количество документов в shard1: " + db.helloDoc.countDocuments());
'; then
  log_success "Shard1 проверен"
else
  log_error "Ошибка при проверке shard1"
fi

sleep 10

log_info "Проверка shard2"
if docker exec shard2 mongosh --port 27019 --eval '
db = db.getSiblingDB("somedb");
print("Количество документов в shard2: " + db.helloDoc.countDocuments());
'; then
  log_success "Shard2 проверен"
else
  log_error "Ошибка при проверке shard2"
fi


log_info "Проверка доступности методов в http://localhost:8080/docs"
response=$(curl -fs http://localhost:8080/helloDoc/count)
if [ $? -eq 0 ]; then
  echo "Ответ от сервера: $response"
  log_success "Методы доступны, данные с бд можно получить"
else
  log_error "Методы недоступны, данные с бд нельзя получить"
fi

log_success "Финиш"
