'use strict';
/**
 * Widget con gráfica de barras, representa el número de puntos de interes
 * por categoría (histogram).
 */
App.View.Widgets.Students.POIsByType = App.View.Widgets.Base.extend({

  /**
   * 1. Recibe el objeto de configuración enviado desde el panel. Además
   *    se añaden ciertas configuraciones por defecto, como por ejemplo el título.
   *    
   *    Se invoca a la función initialize del padre para que termine de configurar
   *    adecuadamente el widget
   */
  initialize: function(options) {
    options = _.defaults(options,{
      title: __('Points of interest'),
      timeMode:'now',
      id_category: 'students',
      refreshTime : 80000,
      publishable: true,
      classname: 'App.View.Widgets.Students.POIsByType',
      dimension: 'double',
      permissions: {'variables': ['students.pointofinterest.category']}
    });

    App.View.Widgets.Base.prototype.initialize.call(this,options);

    /**
     * 2. Llamando a la función 'hasPermissions' comprobamos si el usuario tiene permisos
     *    para renderizar el widget. Utiliza el parámetro de configuracion 'permissions' para
     *    checkear los permisos del usuario en las entidades y variables que se indiquen.
     * 
     *    Ej. 1:       permissions: {'variables': ['dumps.container.storedwastekind']}
     *    Ej. 2:       permissions: {'entities': ['dumps.container']}
     */
    if(!this.hasPermissions()) return;


    /**
     * 3. TODO: Creamos un collection que se encargará de traer los datos de la API.
     *    Hay muchos tipos de Collections definidas previamente, por ejemplo este caso.
     *    La Collection recibe como segundo parámetro la configuración que utilizará para 
     *    formar la petición.
     * 
     *    - scope: el identificador del scope
     *    - type: el tipo de variables del histrograma (discretas ó continuas)
     *    - mode: now ó historic
     *    - variable: la variable sobre la que se consulta el histograma
     *    - data: el payload que se envía con el POST
     * 
     *    Ej:
     *      POST => api/{SCOPE}/variables/{VARIABLE}/histogram/{TYPE}/{MODE}
     *      REQUEST PAYLOAD => data
     */
    
    var _this = this;

    /**
     * 4. TODO: En este caso concreto necesitamos procesar los datos que devuelve el servidor
     *    para adaptarlos al formato necesario por la gráfica. Para eso sobreescribimos la
     *    la función parse de la collection
     */
    this.collection.parse = function(response) {
      return [];
    };

    /**
     * 5. TODO: Creamos el modelo de configuración de la gráfica
     */    
    this._chartModel = new App.Model.BaseChartConfigModel({
      
    });


    /**
     * 6. Cargamos en la subviews un Chart App.View.Widgets.Charts.D3.BarsLine al que 
     *    le pasamos la configuración del chart y la collection 
     */
    this.subviews.push( new App.View.Widgets.Charts.D3.BarsLine({
      
    }));

    // this.filterables = [this.collection];
  },
});
