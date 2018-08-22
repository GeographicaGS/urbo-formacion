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
      dimension: 'double bgWhite allHeight',
    });
    App.View.Widgets.Base.prototype.initialize.call(this,options);

    if(!this.hasPermissions()) return;

    var _this = this;
    _.bindAll(this, '_calculeDistance');

    this.$el.addClass('issuesRanking');    

    /**
     * 1. Creamos un Modelo de Backbone con la configuración de la tabla
     *    La configuración que admite es:
     *    - css_class: añade una clase al elemento de tabla
     *    - columns_format: Objeto que define las columnas, buscará en los datos que recibe
     *         de la API los valores de las propiedades cuyo nombre coincidan con el de la columna
     */
    var tableModel = new Backbone.Model({
      'css_class':'issuesRanking',
      'columns_format': {
        'name':{'title': __('Nombre'), 'css_class':'bold darkBlue counter'},
        'category':{'title': __('Categoría'), 'css_class':'textcenter', 'formatFN': function(d) { 
            var response = App.Static.Collection.Students.POIsTypes.get(d).get('name');
            if(d && d.length > 40) {
              response = d.slice(0,40) + '...'
            }
            return response;
          }, 'tooltip': true
        },
        /**
         * 2. En este caso definimos la columna 'distance', con título 'Distancia' y que ejecuta la función 'calculeDistance'
         */
        'distance':  {'title': __('Distancia'), 'formatFN': this._calculeDistance, 'css_class':'textcenter'},
      }
    });

    
    /**
     * 3. En este caso, por lo especial de los datos a pintar, necesitamos llamar a un endpoint de mapas
     *    para recibir un GeoJSON
     */
    this.collection = new App.Collection.MapsCollection([],{
      scope: this.options.id_scope,
      type: 'now',
      entity: 'students.pointofinterest',
      data: {
        filters: options.newFilterModel
      }
    });
    
    this.collection.parse = function(response) {
      if (!response.features) {
        return response;
      }
      return _.map(_.filter(response.features, function(feature) {
          return feature.properties.category !== 29;
        }), function(r) {
          r.name = r.properties.name;
          r.category = r.properties.category;
          r.distance = r.geometry;
          if (r.category === 188 || r.category === 111) {
            r.category = 371;
          }
          return r;
      }) || [];
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
