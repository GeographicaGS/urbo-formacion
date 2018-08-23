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
     * 3. Creamos un collection que se encargará de traer los datos de la API.
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
    this.collection = new App.Collection.Histogram([], {
      scope: this.options.id_scope,
      type: 'discrete',
      mode: this.options.timeMode,
      variable: 'students.pointofinterest.category',
      data: {
        filters: options.filterModel,
        ranges: 'all'
      }
    });

    
    var _this = this;

    /**
     * 4. En este caso concreto necesitamos procesar los datos que devuelve el servidor
     *    para adaptarlos al formato necesario por la gráfica. Para eso sobreescribimos la
     *    la función parse de la collection
     */
    this.collection.parse = function(response) {
      const elements = [
        {
          key:"pois",
          values: _.filter(_.map(response, function(r) {
              if (r.category === 188 || r.category === 111) {
                r.category = 371;
              }

              return {x: r.category, y: r.value}
            }), function(poi) {
              return poi.x !== 29;
            })
        }
      ];
      var total = 0;
      _.each(elements[0].values, function(element) {
        total += parseInt(element.y)
      });
      _this._chartModel.set({yAxisDomain:[[0,total]]})

      return elements;
    };

    /**
     * 5. Creamos el modelo de configuración de la gráfica
     */    
    this._chartModel = new App.Model.BaseChartConfigModel({
      colors: function(d,index){
        if (index >= 0) {
          var color = App.Static.Collection.Students.POIsTypes.get(d.values[index].x).get('color');
          return color;
        }
      }.bind(this),
      xAxisFunction: function(d) {
        return App.Static.Collection.Students.POIsTypes.get(d).get('name');
      },
      yAxisFunction: function(d) { return  App.nbf(d); },
      useImageAsLegendX: true,
      yAxisTickFormat: function(d) {
        var name = App.Static.Collection.Students.POIsTypes.get(d).get('icon');
        return name;
      },
      yAxisLabel: ['Residences'],
      hideYAxis2: true,      
      legendNameFunc: function(d) {
        var name = App.Static.Collection.Students.POIsTypes.get(d).get('name');
        return name;
      },
      realTime: true,
      hideLegend: false,
      legendTemplate: function(d) {
        var total = 0;
        _.each(d.data[0].values, function(element) {
          total += parseInt(element.y)
        });
        return '<strong>Total:</strong>' + total;
      },
      keysConfig: {
        '*': {type: 'bar', axis: 1}
      },
      groupSpacing: 0.3,
      margin: {top: 40, right: 50, bottom: 90, left: 50},
      yAxisDomain: [[0, 14]]
    });


    /**
     * 6. Cargamos en la subviews un Chart App.View.Widgets.Charts.D3.BarsLine al que 
     *    le pasamos la configuración del chart y la collection 
     */
    this.subviews.push( new App.View.Widgets.Charts.D3.BarsLine({
      'opts': this._chartModel,
      'data': this.collection
    }));

    this.filterables = [this.collection];
  },
});
