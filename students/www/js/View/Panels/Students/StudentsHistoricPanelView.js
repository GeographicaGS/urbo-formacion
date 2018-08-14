'use strict';

App.View.Panels.Students.Historic = App.View.Panels.Splitted.extend({
  _mapInstance: null,
  
  initialize: function (options) {
    options = _.defaults(options, {
      dateView: true,
      id_category: 'students',
      spatialFilter: true,
      master: false,
      title: __('Histórico'),
      id_panel: 'historic',
    });
    App.View.Panels.Splitted.prototype.initialize.call(this, options);

    this.filterModel = new Backbone.Model({
      variable: '((intensity + 0.0) / intensity_sat) * 100',
      status: App.Static.Collection.Students.IntensityLevel.pluck('id'),
    });
    
    this.render();
  },

  customRender: function() {
    this._widgets = [];

    this._widgets.push(new App.View.Widgets.Students.StudentsIntensityValues({
      id_scope: this.scopeModel.get('id'),
      timeMode:'historic'      
    }));
    this._widgets.push(new App.View.Widgets.Students.CongestedRoadsStacked({
      id_scope: this.scopeModel.get('id'),
      timeMode:'historic'      
    }));
    this._widgets.push(new App.View.Widgets.Students.RoadStudentsRanking({
      id_scope: this.scopeModel.get('id'),
      timeMode:'historic'      
    }));
    
    this.subviews.push(new App.View.Widgets.Container({
      widgets: this._widgets,
      el: this.$('.bottom .widgetContainer')
    }));
  },

  onAttachToDOM: function() {
    this._mapView = new App.View.Map.Students.Residences({
      el: this.$('.top'),
      filterModel: this.filterModel,      
      scope: this.scopeModel.get('id'),
      type: 'historic'
    }).render();

    this._heatmapFilter = new App.View.Filter.Students.HeatMapFilter({
      scope: this.scopeModel.get('id'),
      model: this.filterModel,
      open: true
    });

    this.$el.append(this._heatmapFilter.render().$el)
    this.subviews.push(this._mapView);
  },

  onClose: function() {
    this._mapView.close();
    App.View.Panels.Splitted.prototype.onClose.call(this);    
  }
});
