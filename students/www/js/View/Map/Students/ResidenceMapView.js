'use strict';

App.View.Map.Students.Residences = App.View.Map.MapboxView.extend({
  
  initialize: function (options) {
    var center = App.mv().getScope(App.currentScope).get('location');
    options = _.defaults(options, {
      defaultBasemap: 'positron',
      sprites: '/verticals/students/mapstyle/sprite',      
      center: [center[1],center[0]],
      zoom: 8,
      type: 'now'
    });

    App.View.Map.MapboxView.prototype.initialize.call(this, options);
    this.variableSelector = new App.View.Map.VariableSelector({
      filterModel: this.filterModel,
      variables: [
        {value: '1', name: __('1 Km')},
        {value: '5', name: __('5 Km')},
        {value: '10', name: __('10 Km'), byDefault: true},
      ]
    });

    this.$el.append(this.variableSelector.render().$el)
  },

  _onMapLoaded: function() {
    this.layers = new App.View.Map.Layer.Students.ResidencesLayer(this._options, this._payload, this);
  },

  _applyFilter: function(filter) {
    this.layers.updateSQL(filter)
  },

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
