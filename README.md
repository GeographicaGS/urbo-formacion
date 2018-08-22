<h1>URBO-FORMACIÓN</H1>

<h2>FRONT: </h2>

1. Crear enlace simbólico al vertical:

    ```bash
    ln -s ~/[RUTA]/urbo-formacion/students/www ~/[RUTA]/UrboCore-www/students
    ```

2. Añadir start-builder.sh:

    ```bash
    docker-compose run -v [RUTA]/urbo-formacion:[RUTA]/urbo-formacion -v [RUTA] -p 8085:80 --rm www > /dev/null &
    docker-compose run -v [RUTA]/urbo-formacion:[RUTA]/urbo-formacion -v --rm www_builder
    ```
<h3> TODOs </h3>

* [X] Documentar StudentsMasterPanelView
* [X] Documentar StudentsCurrentPanelView
* [X] Documentar widgets: POIsByType y POIsTable
* [X] Documentar PoiFilter
* [X] Documentar ResidenceMapView
* [X] Documentar ResidenceLayer
* [X] Documentar Students
* [X] Preparar Frames
* [X] Modificar vertical para integrarlo con BACK para formación
* [ ] Crear un nuevo widget que use agregados
* [X] Habilitar el filtro/leyenda para POIS










