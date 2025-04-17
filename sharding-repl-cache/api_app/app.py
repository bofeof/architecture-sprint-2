import json
import logging
import os
import time
from typing import List, Optional

import motor.motor_asyncio
from bson import ObjectId
from fastapi import Body, FastAPI, HTTPException, status
from fastapi_cache import FastAPICache
from fastapi_cache.backends.redis import RedisBackend
from fastapi_cache.decorator import cache
from logmiddleware import RouterLoggingMiddleware, logging_config
from pydantic import BaseModel, ConfigDict, EmailStr, Field
from pydantic.functional_validators import BeforeValidator
from pymongo import errors
from redis.asyncio import Redis
from typing_extensions import Annotated

# Configure JSON logging
logging.config.dictConfig(logging_config)
logger = logging.getLogger(__name__)

app = FastAPI()
app.add_middleware(
    RouterLoggingMiddleware,
    logger=logger,
)

DATABASE_URL = os.getenv("MONGODB_URL", "mongodb://localhost:27017")
DATABASE_NAME = os.getenv("MONGODB_DATABASE_NAME", "default_db_name")
REDIS_URL = os.getenv("REDIS_URL", "redis://localhost:6379/0")


def nocache(*args, **kwargs):
    def decorator(func):
        return func

    return decorator


if REDIS_URL:
    cache = cache
else:
    cache = nocache


client = motor.motor_asyncio.AsyncIOMotorClient(DATABASE_URL)
db = client[DATABASE_NAME]

# Represents an ObjectId field in the database.
# It will be represented as a `str` on the model so that it can be serialized to JSON.
PyObjectId = Annotated[str, BeforeValidator(str)]


@app.on_event("startup")
async def startup():
    try:
        # Проверка соединения с MongoDB
        await client.server_info()  # Проверка доступности MongoDB
        logger.info("MongoDB connected successfully.")
    except Exception as e:
        logger.error(f"Failed to connect to MongoDB: {str(e)}")
        raise HTTPException(status_code=500, detail="Failed to connect to MongoDB")
    
    if REDIS_URL:
        try:
            redis = Redis.from_url(REDIS_URL, encoding="utf8", decode_responses=True)
            FastAPICache.init(RedisBackend(redis), prefix="api:cache")
            logger.info("Redis connected successfully.")
        except Exception as e:
            logger.error(f"Failed to connect to Redis: {str(e)}")
            raise HTTPException(status_code=500, detail="Failed to connect to Redis")


class UserModel(BaseModel):
    """
    Container for a single user record.
    """
    id: Optional[PyObjectId] = Field(alias="_id", default=None)
    age: int = Field(..., description="User's age")
    name: str = Field(..., description="User's name")


class UserCollection(BaseModel):
    """
    A container holding a list of `UserModel` instances.
    """
    users: List[UserModel]


@app.get("/")
async def root():
    try:
        collection_names = await db.list_collection_names()
        collections = {}
        for collection_name in collection_names:
            collection = db.get_collection(collection_name)
            collections[collection_name] = {
                "documents_count": await collection.count_documents({})
            }
        logger.info("Collections fetched successfully")

        try:
            replica_status = await client.admin.command("replSetGetStatus")
            replica_status = json.dumps(replica_status, indent=2, default=str)
            logger.info("Replica status fetched successfully")
        except errors.OperationFailure:
            replica_status = "No Replicas"
            logger.warning("Failed to get replica status")

        topology_description = client.topology_description
        read_preference = client.client_options.read_preference
        topology_type = topology_description.topology_type_name
        replicaset_name = topology_description.replica_set_name

        # Исправление здесь: используем правильный способ получения серверных адресов
        mongo_nodes = [str(address) for address in topology_description.server_descriptions().keys()]

        shards = None
        if topology_type == "Sharded":
            shards_list = await client.admin.command("listShards")
            shards = {}
            for shard in shards_list.get("shards", {}):
                shards[shard["_id"]] = shard["host"]

        cache_enabled = False
        if REDIS_URL:
            cache_enabled = FastAPICache.get_enable()

        return {
            "mongo_topology_type": topology_type,
            "mongo_replicaset_name": replicaset_name,
            "mongo_db": DATABASE_NAME,
            "read_preference": str(read_preference),
            "mongo_nodes": mongo_nodes,
            "mongo_primary_host": client.primary,
            "mongo_secondary_hosts": client.secondaries,
            "mongo_is_primary": client.is_primary,
            "mongo_is_mongos": client.is_mongos,
            "collections": collections,
            "shards": shards,
            "cache_enabled": cache_enabled,
            "status": "OK",
        }
    except Exception as e:
        logger.error(f"Error occurred: {str(e)}")
        raise HTTPException(status_code=500, detail=f"Internal server error: {str(e)}")


@app.get("/{collection_name}/count")
async def collection_count(collection_name: str):
    try:
        collection = db.get_collection(collection_name)
        items_count = await collection.count_documents({})
        return {"status": "OK", "mongo_db": DATABASE_NAME, "items_count": items_count}
    except Exception as e:
        logger.error(f"Error occurred while counting documents in collection {collection_name}: {str(e)}")
        raise HTTPException(status_code=500, detail=f"Error counting documents: {str(e)}")


@app.get(
    "/{collection_name}/users",
    response_description="List all users",
    response_model=UserCollection,
    response_model_by_alias=False,
)
@cache(expire=60 * 1)
async def list_users(collection_name: str):
    try:
        collection = db.get_collection(collection_name)
        return UserCollection(users=await collection.find().to_list(1000))
    except Exception as e:
        logger.error(f"Error occurred while listing users in collection {collection_name}: {str(e)}")
        raise HTTPException(status_code=500, detail=f"Error listing users: {str(e)}")


@app.get(
    "/{collection_name}/users/{name}",
    response_description="Get a single user",
    response_model=UserModel,
    response_model_by_alias=False,
)
async def show_user(collection_name: str, name: str):
    try:
        collection = db.get_collection(collection_name)
        if (user := await collection.find_one({"name": name})) is not None:
            return user

        raise HTTPException(status_code=404, detail=f"User {name} not found")
    except Exception as e:
        logger.error(f"Error occurred while fetching user {name}: {str(e)}")
        raise HTTPException(status_code=500, detail=f"Error fetching user: {str(e)}")


@app.post(
    "/{collection_name}/users",
    response_description="Add new user",
    response_model=UserModel,
    status_code=status.HTTP_201_CREATED,
    response_model_by_alias=False,
)
async def create_user(collection_name: str, user: UserModel = Body(...)):
    try:
        collection = db.get_collection(collection_name)
        new_user = await collection.insert_one(user.dict(exclude_unset=True, by_alias=True))
        created_user = await collection.find_one({"_id": new_user.inserted_id})
        return created_user
    except Exception as e:
        logger.error(f"Error occurred while creating user: {str(e)}")
        raise HTTPException(status_code=500, detail=f"Error creating user: {str(e)}")
