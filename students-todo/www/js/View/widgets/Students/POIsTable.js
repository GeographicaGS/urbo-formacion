'use strict';

/**
 * Widget con tabla de datos.
 */
App.View.Widgets.Students.POIsTable =  App.View.Widgets.Base.extend({

  initialize: function(options) {
    options = _.defaults(options,{
      title:__('Points of interest list'),
      timeMode: 'historic',
      id_category: 'students',
      exportable: true,
      dimension: 'allWidth bgWhite allHeight',
    });
    App.View.Widgets.Base.prototype.initialize.call(this,options);

    if(!this.hasPermissions()) return;

    var _this = this;
    _.bindAll(this, '_calculeDistance');

    this.$el.addClass('issuesRanking');    

    /**
     * 1. TODO: Creamos un Modelo de Backbone con la configuración de la tabla
     *    La configuración que admite es:
     *    - css_class: añade una clase al elemento de tabla
     *    - columns_format: Objeto que define las columnas, buscará en los datos que recibe
     *         de la API los valores de las propiedades cuyo nombre coincidan con el de la columna
     */
    var tableModel = new Backbone.Model({
      
    });

    
    /**
     * 3. TODO: En este caso, por lo especial de los datos a pintar, necesitamos llamar a un endpoint de mapas
     *    para recibir un GeoJSON
     */
    this.collection = null;
    
    this.collection.parse = function(response) {
      return null;
    }
    

    this.subviews.push(new App.View.Widgets.TableNewCSV({
      listenContext: true,
      model: tableModel,
      data: this.collection
    }));

    this.filterables = [this.collection];
  },

  render: function() {
    if (this.options.newFilterModel && this.options.newFilterModel.get('the_geom')) {
      App.View.Widgets.Base.prototype.render.call(this);
    }
    return this;
  },

  /**
   * 4. Utilizando turf y las coordenadas de los POIS y la residencia calculamos la distancia en KM
   *    de un punto a otro.
   */
  _calculeDistance: function(d) {
    return App.nbf(turf.distance(d, this.options.newFilterModel.clicked.properties.coord)) + " Km.";
  }

});
