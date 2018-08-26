#!/bin/bash

cd "$(dirname "$0")"

docker-compose down

echo -e "\n\t# 1. Retrieving latest changes from master...\n"
git checkout master
git pull origin master
git submodule init && git submodule update

echo -e "\n\t# 2. Retrieving last vertical data...\n"
cd urbo-formacion
git checkout master
git pull origin master

cd ../

echo -e "\n\t# 3. Updating verticals...\n"
# BE/FE verticals
# npm run-script update-vertical -- urbo-formacion/students students
cp -ru urbo-formacion/students/www/. src/verticals/students

echo -e "\n\t# 4. Updating config...\n"
cp src/js/Config.production.js src/js/Config.js

echo -e "\n\t# 5. Building images...\n"
docker-compose build

echo -e "\n\t# 6. Deploying...\n"
docker-compose up -d
