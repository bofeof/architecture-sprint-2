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

log_info "Инициализация shard1 реплика-сета"
if docker exec shard1a mongosh --port 27018 --eval '
rs.initiate({
  _id: "shard1",
  members: [
    { _id: 0, host: "shard1a:27018" },
    { _id: 1, host: "shard1b:27018" },
    { _id: 2, host: "shard1c:27018" }
  ]
})'; then
  log_success "shard1 реплика-сет инициализирован"
else
  log_error "Ошибка при инициализации shard1 реплика-сета"
fi

sleep 10

log_info "Инициализация shard2 реплика-сета"
if docker exec shard2a mongosh --port 27019 --eval '
rs.initiate({
  _id: "shard2",
  members: [
    { _id: 0, host: "shard2a:27019" },
    { _id: 1, host: "shard2b:27019" },
    { _id: 2, host: "shard2c:27019" }
  ]
})'; then
  log_success "shard2 реплика-сет инициализирован"
else
  log_error "Ошибка при инициализации shard2 реплика-сета"
fi

sleep 10

log_info "Добавление шардов и настройка шардирования через mongos_router1"
if docker exec mongos_router1 mongosh --port 27020 --eval '
sh.addShard("shard1/shard1a:27018,shard1b:27018,shard1c:27018");
sh.addShard("shard2/shard2a:27019,shard2b:27019,shard2c:27019");
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

log_info "Проверка количества документов в базе"
if docker exec mongos_router1 mongosh --port 27020 --eval '
db = db.getSiblingDB("somedb");
print("Всего документов: " + db.helloDoc.countDocuments());
'; then
  log_success "Документы успешно подсчитаны"
else
  log_error "Ошибка при подсчёте документов"
fi

log_info "Проверка shard1a"
if docker exec shard1a mongosh --port 27018 --eval '
db = db.getSiblingDB("somedb");
print("Количество документов в shard1a: " + db.helloDoc.countDocuments());
'; then
  log_success "Shard1a проверен"
else
  log_error "Ошибка при проверке shard1a"
fi

log_info "Проверка shard2a"
if docker exec shard2a mongosh --port 27019 --eval '
db = db.getSiblingDB("somedb");
print("Количество документов в shard2a: " + db.helloDoc.countDocuments());
'; then
  log_success "Shard2a проверен"
else
  log_error "Ошибка при проверке shard2a"
fi

sleep 10

log_info "Проверка доступности методов в http://localhost:8080/docs"
response=$(curl -fs http://localhost:8080/helloDoc/count)
if [ $? -eq 0 ]; then
  echo "Ответ от сервера: $response"
  log_success "Методы доступны, данные с БД можно получить"
else
  log_error "Методы недоступны, данные с БД нельзя получить"
fi

log_info "Проверка реплик в первом шарде"
ans=$(docker exec shard1a mongosh --port 27018 --eval 'rs.status().members.forEach(m => print(m.name + " — " + m.stateStr))')
if [ $? -eq 0 ]; then
  echo "Информация по первому шарду: $ans"
  log_success "ОК"
else
  log_error "Информацию получить нельзя"
fi

log_info "Проверка реплик во втором шарде"
ans=$(docker exec shard2a mongosh --port 27019 --eval 'rs.status().members.forEach(m => print(m.name + " — " + m.stateStr))')
if [ $? -eq 0 ]; then
  echo "Информация по второму шарду: $ans"
  log_success "ОК"
else
  log_error "Информацию получить нельзя"
fi


URL="http://localhost:8080/helloDoc/users"
ATTEMPTS=5

log_info "Запуск тестов скорости запросов с использованием кеша. Проверка GET-запроса: $URL"

for i in $(seq 1 $ATTEMPTS); do
  log_info "Попытка №$i"

  # Получаем время выполнения запроса с точностью до миллисекунд
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
