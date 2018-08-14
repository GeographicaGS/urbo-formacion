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

<h3> TODOS </h3>
- [x] Documentar StudentsMasterPanelView
- [ ] Documentar StudentsCurrentPanelView










