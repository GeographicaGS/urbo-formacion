#!/bin/bash
DOCKER_HOST=$(ip -4 addr show docker0 | grep -Po 'inet \K[\d.]+')
cd "$(dirname "$0")"

git checkout master
git pull

# Pulling verticals
cd urbo-formacion
git pull
cd ..

# Creating images and containers
docker build -t geographica/urbo_processing .

docker rm -f urbo_redis_processing
docker rm -f urbo_processing

docker run -d --name='urbo_redis_processing' -p $DOCKER_HOST:6380:6379 --restart='always' -v $(pwd)/redis.conf:/usr/local/etc/redis/redis.conf redis redis-server /usr/local/etc/redis/redis.conf
docker run -d --name='urbo_processing' -p 3010:3000 --restart='always' -v $(pwd)/../urbo-logs:/logs geographica/urbo_processing

# Installing verticals
docker exec -i urbo_processing npm run-script install-vertical -- urbo-formacion/students students

# Transpiling JS
docker exec -i urbo_processing npm run-script transpile

# RELOAD API
docker restart urbo_processing

