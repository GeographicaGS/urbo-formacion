#!/bin/bash

cd "$(dirname "$0")"
git checkout master && git pull

docker build -t geographica/urbo_lombardia_students_connector api

docker rm -f urbo_lombardia_students_connector

docker run -d --name='urbo_lombardia_students_connector' -p 3001:3000 --restart='always' -v $(pwd)/../urbo-logs:/logs geographica/urbo_lombardia_students_connector
