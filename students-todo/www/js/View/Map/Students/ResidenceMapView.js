'use strict';

App.View.Map.Students.Residences = App.View.Map.MapboxView.extend({
  
  initialize: function (options) {
    var center = App.mv().getScope(App.currentScope).get('location');

    /**
     * 1. Definimos la configuración por defecto del mapa
     *    - defaultBasemap: cargamos por defecto positron
     */
    options = _.defaults(options, {
      defaultBasemap: 'positron',
      sprites: '/verticals/students/mapstyle/sprite',      
      center: [center[1],center[0]],
      zoom: 8,
      type: 'now'
    });

    App.View.Map.MapboxView.prototype.initialize.call(this, options);

    /**
     * 2. TODO: Incluimos un selector de variables que utilizaremos para
     *    seleccionar el radio del area de busqueda
     */
  },

  /**
   * 3. TODO: Cuando el mapa carga llama a la función _onMapLoaded que a su vez 
   *  construye las layers
   */
  _onMapLoaded: function() {
    // TODO: Incluir layers
  },

  /**
   * 4. TODO: En este caso las layers son de tipo SQL así que al aplicar un filtro actualizamos la SQL
   */
  _applyFilter: function(filter) {
  },

  /**
   * 5. Al mover el mapa de ejecuta la función _onBBoxChange, está función se encarga de avisar al
   *    contexto de que el BBox ha cambiado.
   */
  _onBBoxChange: function(bbox) {
    if (App.ctx.get('bbox_status')) {
      let __bbox = [bbox.getNorthEast().lng,bbox.getNorthEast().lat,bbox.getSouthWest().lng,bbox.getSouthWest().lat]
      App.ctx.set('bbox', __bbox);
    }
  },

  onClose: function() {
    this.layers.close();
    App.View.Map.MapboxView.prototype.onClose.call(this);
  }
});
