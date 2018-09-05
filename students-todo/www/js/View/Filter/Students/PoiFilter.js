'use strict';

/**
 * Leyenda del mapa de POI
 */
App.View.Filter.Students.PoiMapFilter = App.View.Filter.Base.extend({
  /**
   * 1. Definimos la template que se usará
   */
  _template: _.template( $('#Students-filter-filter_pois_template').html()),

  events: {
    'click h3' : '_toggleFilter',
    'click .toggler': '_toggleMultiselector',
    'click .statusesTypes li[data-id]' : '_onClickType'    
  },

  initialize: function(options) {
    App.View.Filter.Base.prototype.initialize.call(this,options);
    this.listenTo(App.ctx, 'change:bbox', this.asynchronousData);
    this.listenTo(this.model, 'change:the_geom', this.asynchronousData);
    
  },

  render: function() {
    /**
     * 2. Cargamos en el DOM la template. A esta le pasamos un modelo (filterModel) y la lista
     *    de POIS
     */
    this.$el.html(this._template({
      m: this.model.toJSON(),
      status: _.filter(App.Static.Collection.Students.POIsTypes.toJSON(), function(poi) {
        return poi.id !== 'pois' && poi.id !== 29;
      }),
      className: 'issues'
    }));

    /**
     * 3. Llamamos a la función asynchronousData, en caso de ser necesario trae datos desde el 
     *    servidor.
     */
    this.asynchronousData();

    return this;
  },

  /**
   * 4. Abre/cierra el filtro
   */
  _toggleFilter:function(){
    this.$el.toggleClass('compact');
  },

  /**
   * 5. Trae del servidor datos específicos, en este caso trae los contadores de categorías
   *  Tenemos que tener en cuenta el BBOX y el intersect con el the_geom
   */
  asynchronousData: function() {
    
  },

  /**
   * En caso de estar habilitado enciende/apaga los filtros
   */
  _onClickType: function(e){
    var $e = $(e.currentTarget);
    
      if ($e.attr('selected')) {
        this.$('.statusesTypes li[data-id="all"]').addClass('disabled');
        this.$('.statusesTypes li[data-id="all"]').attr('selected', false);
        $e.removeAttr('selected');
      } else
        $e.attr('selected',true);
  
      $e.toggleClass('disabled');
      $e.find('span').toggleClass('disabled');

    var ids = _.map(this.$('.statusesTypes li[data-id][selected]'),function(c){
      return $(c).attr('data-id');
    });
    this.model.set('status',ids);
    this.model.set('condition',
      {
        'category__in': ids
      });
  },
});
