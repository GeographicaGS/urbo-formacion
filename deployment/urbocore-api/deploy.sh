#!/bin/bash
DOCKER_HOST=$(ip -4 addr show docker0 | grep -Po 'inet \K[\d.]+')
cd "$(dirname "$0")"

git pull

# Pulling verticals
cd urbo-formacion
git pull
cd ..

# Creating containers
docker build -t geographica/urbo_api .

docker rm -f urbo_api
# docker rm -f urbo_redis

# docker run -d --name='urbo_redis' -p $DOCKER_HOST:6379:6379 --restart='always' -v $(pwd)/redis.conf:/usr/local/etc/redis/redis.conf redis redis-server /usr/local/etc/redis/redis.conf
docker run -d --name='urbo_api' -p 3000:3000 -e 'NODE_ENV=production' --restart='always' -v $(pwd)/../urbo-logs:/logs geographica/urbo_api

# Installing verticals
docker exec -i urbo_api npm run-script install-vertical -- urbo-formacion/students students

# RELOAD API
docker restart urbo_api

# RELOAD PLGSQL (local docker mode)
#echo "Refresh Urbo plpgsql"
# docker exec -i urbo_db psql -d urbo -U postgres -f /usr/src/api/db/bootstrap.sql
# ls -1a urbo-formacion/*/api/db/bootstrap.sql | xargs -i echo "/usr/src/api/{}" | xargs -n 1 docker exec -i urbo_db psql -d urbo -U postgres -f

# Update Carto stuff
docker exec -i urbo_api npm run-script cartofunctions
# docker exec -i urbo_api npm run-script namedmaps master
