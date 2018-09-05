'use strict';

/**
 * Panel Maestro, Dashboard o Estado General
 */
App.View.Panels.Students.Master = App.View.Panels.Base.extend({
  
  /**
   * 1. Función initialize: Es el equivalente a un constructor en Java.
   * @param options: Object => Objeto con la configuración del panel, desde el Router.js se le envía un scopeModel y el id_category.
   *  Además se definen por defecto otras opciones, en este caso:
   *  - dateView: Boolean que indica que si el panel tiene filtro de fecha
   *  - id_category: Este panel siempre pertenecerá a students (a no ser que se sobreescriba)
   *  - spatialFilter: Boolean que indica si se añade en esta pantalla un filtro de BBox
   *  - master: <Deprecated> se utllizaba para indicar si era o no un panel maestro, en estos momentos no hace nada.
   *  - title: Título del panel
   *  - id_panel: Identificado único (en el vertical) del panel. Se utiliza para 'marcar' como seleccionado el panel en el selector de paneles superior.
   *  - framesList: Indica si en esta pantalla se van pintar/crear frames.
   * 
   * Después se llama al initialize del padre, que añade en caso necesario otras tantas configuraciones por defecto.
   * Por último se llama al render del panel. La función render no suele ser necesario sobreescribirla, el render de App.View.Panels.Base termina llamando
   * a la función customRender que se implementa en el panel.
   */
  initialize: function (options) {
    options = _.defaults(options, {
      dateView: true,
      id_category: 'students',
      spatialFilter: false,
      master: false,
      title: __('Estado general'),
      id_panel: 'master',
      // **** TODO: Uncomment next line ****
      // framesList: true 
    });
    App.View.Panels.Base.prototype.initialize.call(this, options);

    this.render();
  },


  /**
   * 2. Función customRender: en esta función delegamos el dibujado de los distintos widgets disponibles
   */
  customRender: function() {
    this._widgets = [];

    /**
     * 3. TODO: Creamos modelo base de widget, en este caso es exclusivamente para dibujar en minimapa.
     * Enviamos un objeto con la configuración del base:
     *  - entities: Array de entidades que se van a pintar
     *  - location: Array de coordenadas centrales
     *  - zoom: Nivel de zoom inicial
     *  - scope: Identificador del ambito (ej. distrito_telefonica)
     *  - section: Identificador de categoría (ej. lighting)
     *  - color: Color de los puntos del mapa
     *  - link: Enlace al que dirige el widget al pulsar sobre él
     *  - title: Título del widget
     *  - timeMode: historic ó now
     *  - titleLink: Título del enlace
     */
    

    /**
     * 4. TODO: Con el modelo anterior construimos un widget de tipo App.View.WidgetDeviceMap
     */

    /**
     * 5. TODO: Construimos un widget de tipo App.View.Widgets.Students.POIsByType
     * Tenemos que tener previamente creado este Widget
     */

    /**
     * 6. TODO: Subviews es una propiedad heredada de los paneles, esto se hace para al cerrar el vertical
     *    destruir los widgets. No sería necesario incluirlos para que se pinten, quien hace que se añadan
     *    al DOM es App.View.Widgets.Container
     * 
     *    El container recibe el array de widgets y el elemento del DOM donde se tiene que pintar.
     */
  },
});
