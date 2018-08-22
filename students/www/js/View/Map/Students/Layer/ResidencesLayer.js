'use strict';

App.View.Map.Layer.Students.ResidencesLayer = Backbone.View.extend({
  /**
   * 1. Definimos los templates de las SQL
   */
  _sql_template: _.template( $("#Students-maps-students_sql_template").html() ),
  _sql_pois_template: _.template( $("#Students-maps-students_pois_sql_template").html() ),

  events: {
    'click .residencesbutton .button': '_clickPoint'
  },   

  initialize: function(options, payload, map) {
    this.map = map;
    
    _.bindAll(this, '_clickPoint');
    _.bindAll(this, '_onBack');

    this.listenTo(this.map.mapChanges,'change:clickedResidence',this._onBack);

    var _this = this;

    /**
     * 2. Precargamos las SQL con los datos por defecto
     */
    var sql_template = this._sql_template({
      scope: App.currentScope,
      variable: '10',
    });
    var sql_pois_template = this._sql_pois_template({
      scope: App.currentScope,
      coord: [],
      categories: null
    });


    /**
     * 3. Definimos los Models que se encargarán de solicitar a la Maps API los MVT
     *    La documentación puede consultarse en: https://carto.com/docs/carto-engine/maps-api
     */
    this.model = new App.Model.TilesModel({
      url: 'https://' + App.Utils.getCartoAccount('students') + '.carto.com/api/v1/map',
      params: {
        layers:[ {
          id: 'cartoLayer',
          options:{
            sql: sql_template
          }
        }],
      }
    });

    this.poisModel = new App.Model.TilesModel({
      url: 'https://' + App.Utils.getCartoAccount('students') + '.carto.com/api/v1/map',
      params: {
        layers:[ {
          id: 'cartoLayer',
          options:{
            sql: sql_pois_template
          }
        }],
      }
    });

    /**
     * 4. Creamos un modelo tipo Function, lo que hace es en lugar de hacer la petición a una API,
     *    ejecuta localmente una función. En este caso ejecutará la función turf.circle
     */
    this.turfModel = new App.Model.FunctionModel({
      function: turf.circle,
      params: [[0,0],1]
    });


    /**
     * 5. Creamos una layer GeoJSON, recibe como source el modelo 'turfModel'.
     *    Por defecto está filtrada (escondida) se muestra el area al pulsar sobre una residencia.
     *    En la propiedad layers se pueden definir N layers que utilicen el mismo source y todo siguiendo
     *    la documentación oficial de Mapbox GL JS.
     */
    this.turfLayer = new App.View.Map.Layer.MapboxGeoJSONLayer({
      source: {
        id: 'turfSource',        
        model: this.turfModel,
      },
      legend: {},
      layers: [
        {
          'id': 'area',
          'type': 'line',
          'source': 'turfSource',
          'paint': {
            'line-color': '#F7A034',
            'line-dasharray': [3,2],
            'line-width': 2,  
          },
          'filter': ['all', false]          
        },
        {
          'id': 'areaFill',
          'type': 'fill',
          'source': 'turfSource',
          'paint': {
            'fill-color': '#F7A034',
            'fill-opacity': 0.1,
          },
          'filter': ['all', false]          
        }
      ],
      map: map,
    });

    /**
     * 7. Definimos las layers que de tipo MapboxSQLLayer, al igual que la anterior
     *    recibe como parametro el modelo que utilizará.
     *    
     *    Se llama a la función setHoverable(true) para que el cursor al pasar por encima 
     *    un elemento de la capa cambie a 'pointer'.
     * 
     *    Por último se llama a setPopup para añadir popups a estas capas.
     */
    this.layer = new App.View.Map.Layer.MapboxSQLLayer({
      source: {
        id: 'cartoSource',        
        model: this.model,
      },
      legend: {},
      layers: [
        {
          'id': 'residences',
          'type': 'symbol',        
          'source': 'cartoSource',
          'source-layer': 'cartoLayer',
          'layout': {
            'icon-image': 'residence',
            'icon-allow-overlap': true
          },
          'filter': ['all', true]
        }
      ],
      map: map
    })
    .setHoverable(true)
    /**
     * 8. Esta función como último parámetro recibe una función o
     *    un array con cada una de las rows que se van a pintar en el popup.
     *    Estas rows son un objeto del siguiente tipo:
     *      - output: Template a utilizar para la fila, hay algunas definidas previamente
     *          pero pueden definirse nuevas.
     *      - properties: Array con las properties a pintar, esto dependerá de la plantilla
     *          que se utlice.
     */
    .setPopup('with-extended-title', __('Residence'), function(e, popup) {
        _this.clicked = e;
        _this.popup = popup;
        e.features[0].properties.coord = JSON.parse(e.features[0].properties.coord).coordinates;        
        e.features[0].properties.fromNow = moment(e.features[0].properties.dateModified).fromNow();

        var template = [ {
          output: App.View.Map.RowsTemplate.EXTENDED_TITLE,
          properties: [{
            value: 'name',
          },{
            value: '| exactly'
          }]
        }, {
          output: App.View.Map.RowsTemplate.ACTION_BUTTON,
          classes: 'residencesbutton',
          properties: [{
            value: 'id_entity'
          },{
            value: 'Select residence | exactly | translate'
          }]
        }];

        return template;
      }
    );

    this.poisLayer = new App.View.Map.Layer.MapboxSQLLayer({
      source: {
        id: 'cartoPoisSource',        
        model: this.poisModel,
      },
      legend: {},
      layers: [
        {
          'id': 'pois',
          'type': 'symbol',        
          'source': 'cartoPoisSource',
          'source-layer': 'cartoPoisLayer',
          'layout': {
            'icon-image': {
              'property': 'category',
              'type': 'categorical',
              'default': 'transparent',
              'stops': [
                [107, 'historic-shops'],
                [311, 'museo'],
                [371, 'reserved'],
                [420, 'itinerary'],
                [435, 'hostel'],
              ]
            },
            'icon-size': 0.8,
            'icon-allow-overlap': true
          }
        }
      ],
      map: map
    })
    .setPopup('with-extended-title', '', function(e, popup) {
      e.features[0].properties.categoryName = App.Static.Collection.Students.POIsTypes.get(e.features[0].properties.category).get('name');

      var template = [ {
        output: App.View.Map.RowsTemplate.EXTENDED_TITLE,
        properties: [{
          value: 'categoryName'
        },{
          value: 'name',
        }]
      }];

      return template;
    });
  },

  onClose: function() {
  },

  /**
   * 9. Esta función se llama al modificarse algun filtro.
   *    En este caso solo se actualizará si se ha cambiado la residencia.
   *    
   */
  updateSQL: function(filter) {
    filter = filter.toJSON();
    this.variable = filter.variable;
    
    if (this.clicked) {
      var kilometers = this.variable;
      var coord = this.clicked.features[0].properties.coord;
      
      var sql_pois_template = this._sql_pois_template({
        scope: App.currentScope,
        coord: coord,
        variable: kilometers,
        categories: this.map.filterModel.get('status')
      });
      this.turfLayer.updateData({params:[coord,kilometers,{units:'kilometers'}]});
      this.poisLayer._updateSQLData(sql_pois_template, 'cartoPoisLayer');

      var the_geom = Object.assign({},this.map.variableSelector.options.filterModel.get('the_geom')) || {};
      the_geom.ST_Intersects = this.turfModel.get('response').geometry;
      this.map.variableSelector.options.filterModel.set('the_geom',the_geom);
    }
  },

  /**
   * 10.  Al pulsar sobre una residencia se actualizan los filtros de las capas para 
   *      causar el efecto de "selección" y además se actualiza el modelo de la capa de 
   *      POIs para que se calculen los datos de POIs cercanos a la residence seleccionada.
   */
  _clickPoint: function(e) {
    this.popup.remove();    
    var residenceId = parseInt(e.currentTarget.getAttribute('data-entity-id'));
    var coord = this.clicked.features[0].properties.coord;
    var id_entity = this.clicked.features[0].properties.id_entity;
    var kilometers = this.map.variableSelector.options.filterModel.get('variable');
    
    
    this.map._map.setFilter("area", ["all", true]);
    this.map._map.setFilter("areaFill", ["all", true]);
    this.map._map.setFilter("residences", ["==", ["get", "id_entity"], id_entity]);
    this.map._map.setFilter("pois", ["all", true]);
    
    this.map.mapChanges.set('clickedResidence',this.clicked);
    var sql_pois_template = this._sql_pois_template({
      scope: App.currentScope,
      coord: coord,
      variable: kilometers,
      categories: this.map.filterModel.get('status')
    });
    this.turfLayer.updateData({params:[coord,kilometers,{units:'kilometers'}]});
    this.poisLayer._updateSQLData(sql_pois_template, 'cartoPoisLayer');

    var the_geom = this.map.variableSelector.options.filterModel.get('the_geom') || {};
    the_geom.ST_Intersects = this.turfModel.get('response').geometry;
    this.map.variableSelector.options.filterModel.set('the_geom',the_geom);
  },

  _onBack: function(change) {
    if (!change.get('clickedResidence')) {
      this.map._map.setFilter("area", ["all", false]);
      this.map._map.setFilter("areaFill", ["all", false]);
      this.map._map.setFilter("residences", ["all", true]);
      this.map._map.setFilter("pois", ["all", false]);
      this.clicked = null;
    }
  }
});
