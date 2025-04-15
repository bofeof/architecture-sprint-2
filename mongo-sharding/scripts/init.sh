#!/bin/bash

echo "Старт"
sleep 3

echo "Инициализация config-сервера"
docker exec configSrv1 mongosh --eval '
rs.initiate({
  _id: "config_server",
  configsvr: true,
  members: [
    { _id: 0, host: "configSrv1:27017" },
    { _id: 1, host: "configSrv2:27017" },
    { _id: 2, host: "configSrv3:27017" }
  ]
})
'

sleep 5

echo "Инициализация shard1"
docker exec shard1 mongosh --port 27018 --eval '
rs.initiate({
  _id: "shard1",
  members: [
    { _id: 0, host: "shard1:27018" }
  ]
})
'

sleep 5

echo "Инициализация shard2"
docker exec shard2 mongosh --port 27019 --eval '
rs.initiate({
  _id: "shard2",
  members: [
    { _id: 0, host: "shard2:27019" }
  ]
})
'

sleep 5

echo "Добавление шардов в кластер через mongos_router1 и наполнение БД"
docker exec mongos_router1 mongosh --port 27020 --eval '
sh.addShard("shard1/shard1:27018");
sh.addShard("shard2/shard2:27019");
sh.enableSharding("somedb");
sh.shardCollection("somedb.helloDoc", { "name" : "hashed" });
db = db.getSiblingDB("somedb");
for(var i = 0; i < 1000; i++) db.helloDoc.insertOne({age:i, name:"ly"+i});
'

sleep 5 

echo "Проверка shard1"
docker exec shard1 mongosh --port 27018 --eval '
db = db.getSiblingDB("somedb");
print("Количество документов: " + db.helloDoc.countDocuments());
'

sleep 2

echo "Проверка shard2"
docker exec shard2 mongosh --port 27019 -eval '
db = db.getSiblingDB("somedb");
print("Количество документов: " + db.helloDoc.countDocuments());
'

echo "Финиш"
