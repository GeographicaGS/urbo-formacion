# Desarrollo Urbo
Requisitos:
- Docker
- Docker Compose
- Oracle VirtualBox, en caso de usar la máquina virtual

## Notas sobre Docker
- Podemos usar la IP 172.17.0.1 para acceder a contenedores que tengan mapeados puertos entre nuestro host y ellos mismos. Es importante conocer el puerto al que se ha mapeado en nuestro host.
- Si queremos conocer la IP de un determinado contenedor podemos ejecutar `docker container inspect *container_name/id*`

## Máquina Virtual

1. Descargar en el siguiente [enlace](https://drive.google.com/file/d/1_AgD2uQO6QVkLDCGGwIOD2Y1xItC_87z/view?usp=sharing)
2. Ejecutar VirtualBox. Acceder a _Archivo -> Importar servicio virtualizado..._
3. Dentro de la nueva ventana seleccionamos el lugar en el que se encuentra el archivo descargado.
4. Realizamos la importación de la máquina.
5. (Recomendado) Mapeamos una carpeta de nuestro equipo con la máquina virtual. Para ello hacemos clic derecho sobre el
   nombre de la máquina, accedemos a _Configuración_ y dentro de la sección _Carpetas compartidas_ podemos configurar
   una carpeta compartida. Si posees una carpeta con los repositorios de urbo descargados, realiza el mapeo a dicha carpeta, esto te permitirá usar tu editor/IDE de preferencia y realizar despliegues en la MV.
6. (Opcional) Por defecto la máquina virtual mapea puertos de tu máquina en localhost para acceder a los servicios que
   despliegues dentro de ella. Esto también se puede configurar dentro de la sección _Red -> Avanzado -> Reenvío de puertos_
7. Arrancamos la máquina haciendo doble clic sobre su nombre.

## PostgreSQL + PostGIS

### Parámetros de conexión por defecto

A menos que se haya editado algunos de los archivos existentes en la carpeta `db` los parámetros de conexión a la base de datos son:
- Nombre de la base de datos: `urbo`
- Nombre de usuario del administrador de la base de datos de urbo: `urbo_admin`
- Contraseña para acceder a la base de datos de urbo con el usuario creado: `urbo`
- Nombre de usuario para acceder a la aplicación: `admin@geographica.gs`
- Contraseña para acceder a la aplicación: `admin`

Estos parámetros pueden cambiarse editando las variables existentes en `db/all.sql` tras descargar el repositorio.

### Pasos a seguir
1. Descargamos el repositorio [urbo-pgsql-connector](https://github.com/GeographicaGS/urbo-pgsql-connector.git) y accedemos a la carpeta donde se haya guardado.
2. Creamos un volumen Docker llamado `urbo-db-data` con el comando `docker volume create urbo-db-data`. En caso de querer cambiar el nombre habrá que adaptar la descripción de los volúmenes hecha en `docker-compose.yml`. En este volumen se persistirán los datos guardados en nuestra base de datos.
3. Copiamos todos los ficheros que se encuentran en `deployment/urbo-pgsql-connector/db` en la carpeta `db` del repositorio descargado anteriormente.
4. (Opcional) Configuramos las distintas variables existentes en `db/all.sql` en caso de querer cambiar contraseñas o usuarios, se identifican por las instrucciones de `\set`.
5. Ejecutamos el comando `docker-compose -f docker-compose.yml -f docker-compose.dev.yml up -d postgis`
6. Al hacer esto tendremos una copia de los contenidos del repositorio dentro de la capeta `/usr/src` del contenedor. Cualquier cambio que hagamos dentro de la carpeta del repositorio se trasladará al contenedor.
7. Para inicializar la estructura de la base de datos ejecutamos el comando `docker-compose exec -T postgis psql -U postgres -f /usr/src/db/all.sql`.

### Notas importantes
- En la configuración de desarrollo este contenedor se mantiene a la espera de conexiones en `localhost:5435` o `172.17.0.1:5435`, esta configuración puede cambiarse editando el fichero `docker-compose.dev.yml`. Podemos conectarnos a ambas IPs gracias a que se ha configurado un mapeo de puertos.
- Dado que tenemos creado el volumen `urbo-db-data` no es necesario repetir los pasos de generación de la estructura de tablas en el caso de que eliminemos el contenedor. En caso de querer realizar una instalación limpia desde 0 tendrá que eliminar dicho volumen mediante `docker volume rm urbo-db-data`.


## Urbo API

### Pasos a seguir
1. Descargamos el repositorio [UrboCore-api](https://github.com/GeographicaGS/UrboCore-api.git) y accedemos a la carpeta donde se haya guardado.
2. Configuramos la API a partir de una copia del fichero `config.sample.yml`, creando `config.yml`.
3. Copiamos o montamos como volúmenes los verticales que necesitemos. Para instalar distintos verticales solo es necesario copiar/montar la carpeta `api` del vertical.
4. (En caso de que el vertical sea nuevo) Copiamos los ficheros que se encuentren en la carpeta `api/db` de cada vertical dentro de la carpeta `db` del repositorio de `urbo-pgsql-connector` con un nombre de carpeta que identifique al vertical.
5. (En caso de que el vertical sea nuevo) Cargamos las funciones que nuestro vertical necesite en la base de datos mediante `docker exec -ti urbo_db psql -U postgres -f /usr/src/db/vertical_name/bootstrap.sql`. Esto habría que hacerlo para cada vertical nuevo en nuestra base de datos local.
6. (En caso de que el vertical sea nuevo) Cargamos el nuevo vertical a la base de datos ejecutando la función de creación de metadata, `docker exec urbo_db psql -U postgres -d urbo -c 'SELECT urbo_createmetadata_myvertical'`.
7. (En caso de que el vertical sea nuevo) Cargamos la función de creación de tablas del nuevo vertical en CARTO, bien usando la herramienta `cdb-manager` o la API SQL de Carto.
8. (Opcional) Levantamos el contenedor de Redis para la API con `docker-compose up -d redis`.
9. Tras comprobar que tenemos las funciones necesarias para que se puedan crear tablas del vertical e inicializar el metadata en las bases de datos, arrancamos la API con `docker-compose up -d api`

### Notas importantes
- Si queremos depurar el código de la API, podemos ejecutar el comando `docker-compose -f docker-compose.yml -f docker-compose.dev.yml`
- Si hacemos algún cambio de código, podemos recargar la API ejecutando el comando `docker restart urbo_api`

## Urbo Processing
WIP

## Urbo Connector

### Pasos a seguir
1. Descargamos el repositorio [urbo-pgsql-connector](https://github.com/GeographicaGS/urbo-pgsql-connector.git) y accedemos a la carpeta donde se haya guardado.
2. Creamos el fichero `api/config.yml` a partir de una copia del fichero `api/config.sample.yml`.
3. Realizamos la configuración del conector de acuerdo al modelo de datos. **Importante**: no recibiremos notificaciones del Context Broker a menos que nuestro contenedor esté expuesto a Internet mediante una URL/IP que apunte a nuestro equipo/contenedor.
4. Arrancamos el conector con `docker-compose up -d api`. En caso de querer depurar el código de connector podemos ejecutar `docker-compose -f docker-compose.yml -f docker-compose.dev.yml up -d api`, esto levantará una instancia lista para ser depurada con node inspector.

## Urbo WWW
### Pasos a seguir
1. Descargamos el repositorio [UrboCore-www](https://github.com/GeographicaGS/UrboCore-www.git) y accedemos a la carpeta donde se haya guardado.
2. Creamos el fichero de configuración `src/js/Config.js` a partir de una copia del fichero `src/js/Config.template.js`.
3. Adaptamos el fichero `src/js/Config.js` de acuerdo con nuestras necesidades.
4. Creamos el script de ejecución `start_builder.sh` a partir de una copia del script de ejemplo `start_builder.sh.example`.
5. Adaptamos el script de ejecución de acuerdo a nuestras necesidades. Es importante conocer la _ruta absoluta_ de los ficheros del vertical que queremos desarrollar.
6. Ejecutamos el script `start_builder.sh` y comenzamos a desarrollar. Recuerda que cuando realices cambios sobre el código la aplicación se recargará de forma automática.

**Nota**: en caso de que al ejecutar el script veamos el error `Cannot find module sting-builder` podemos abrir una nueva terminal mientras el script está corriendo con el comando `docker exec -ti urbocorewww_www_builder_run_1 npm install sting-builder`.
