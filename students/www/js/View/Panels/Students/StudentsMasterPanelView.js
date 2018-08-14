'use strict';

App.View.Panels.Students.Master = App.View.Panels.Base.extend({
  _mapInstance: null,
  
  initialize: function (options) {
    options = _.defaults(options, {
      dateView: true,
      id_category: 'students',
      spatialFilter: false,
      master: false,
      title: __('Estado general'),
      id_panel: 'master',
      filteView: false,
    });
    App.View.Panels.Base.prototype.initialize.call(this, options);

    this.render();
  },

  customRender: function() {
    this._widgets = [];

    var m = new App.Model.Widgets.Base({
      entities : ['students.pointofinterest'],
      location : this.scopeModel.get('location'),
      zoom: this.scopeModel.get('zoom'),
      scope: this.scopeModel.get('id'),
      section: this.id_category,
      color: '#FF9900',
      link : '/' + this.scopeModel.get('id') + '/' + this.id_category + '/dashboard/current',
      title: __('Mapa'),
      timeMode:'historic',
      titleLink: __('Tiempo Real')
    });

    this._widgets.push(new App.View.WidgetDeviceMap({model: m}));

    this._widgets.push(new App.View.Widgets.Students.POIsByType({
      id_scope: this.scopeModel.get('id'),
      timeMode:'now',
    }));

    this.subviews.push(new App.View.Widgets.Container({
      widgets: this._widgets,
      el: this.$(".widgets")
    }));
  },
});
