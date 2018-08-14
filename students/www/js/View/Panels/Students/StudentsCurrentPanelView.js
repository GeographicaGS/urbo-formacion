'use strict';

App.View.Panels.Students.Current = App.View.Panels.Splitted.extend({
  _mapInstance: null,
  
  _events: {
    'click .title_selection  a.back': '_goBack'
  },

  initialize: function (options) {
    options = _.defaults(options, {
      dateView: false,
      id_category: 'students',
      spatialFilter: true,
      master: false,
      title: __('Points of Interest'),
      id_panel: 'current',
      filteView: false,
    });
    App.View.Panels.Splitted.prototype.initialize.call(this, options);

    this.filterModel = new Backbone.Model({
      variable: '10',
      status: App.Static.Collection.Students.POIsTypes.pluck('id'),
      condition: {} // Will be empty, is needed for map's endpoint
    });

    this.events = _.extend({},this._events, this.events);
    this.listenTo(this.filterModel, 'change:the_geom', this._recalculeWidgets);    
    this.delegateEvents();

    this.render();
  },

  customRender: function() {
    this._widgets = [];

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

    this._poisFilter = new App.View.Filter.Students.PoiMapFilter({
      scope: this.scopeModel.get('id'),
      model: this.filterModel,
      open: true
      
    });
    this.$el.append(this._poisFilter.render().$el)    
    this.subviews.push(this._mapView);
    
    this.$('.co_fullscreen_toggle').remove();
    this._forceMapFullScreen(true);
    this.listenTo(this._mapView.mapChanges,'change:clickedResidence', this._openDetails);
  },

  

  _openDetails: function(e) {
    if (!e.get('clickedResidence')) {
      this._forceMapFullScreen(true);
      return this;
    }

    let clicked = e.toJSON().clickedResidence.features[0];
    this.filterModel.clicked = clicked;

    // 1.- Cleaning widget container
    this._forceMapFullScreen(false);
    this.$('.bottom .widgetContainer').html('');

    // 2.- Calling to renderer for detail's widget
    this._recalculeWidgets(clicked);      
    
    // 3.- Reloading Masonry
    this.$('.bottom .widgetContainer').masonry('reloadItems',{
      gutter: 20,
      columnWidth: 360
    });

    // 4 - Set title of selection
    var $title_selection = $('.title_selection');
    $title_selection.html('<a href="#" class="navElement back"></a>' + clicked.properties.name);
  },

  _forceMapFullScreen: function(open) {
    var _this = this;
    if (open) {
      this.$('.split_handler').addClass('hide');
      this.$('.bottom.h50').addClass('collapsed');
      if(this._mapView){
        this._mapView.$el.addClass('expanded');
        setTimeout(function(){
          _this._mapView.resetSize();
        }, 300);
      }
    } else {
      this.$('.split_handler').removeClass('hide');
      this.$('.bottom.h50').removeClass('collapsed');
      if(this._mapView){
        this._mapView.$el.removeClass('expanded');
        setTimeout(function(){
          _this._mapView.resetSize();
        }, 300);
      }
    }
  },

  _goBack: function() {
    this._mapView.mapChanges.set('clickedResidence', null);
    this._mapView.mapChanges.set('the_geom', null);
    this.poisTable.close();
    this.poisByType.close();
    this.poisTable = null;
    this.poisByType = null;
  },

  _customRenderDetails: function(residence) {
    this._widgets = [];
    
    this.poisByType = new App.View.Widgets.Students.POIsByType({
      id_scope: this.scopeModel.get('id'),
      filterModel: this.filterModel,
      timeMode:'now',
    });

    this._widgets.push(this.poisByType);
    
    this.poisTable = new App.View.Widgets.Students.POIsTable({
      id_scope: this.scopeModel.get('id'),
      filterModel: this.filterModel,
      timeMode:'now',
    });
    this._widgets.push(this.poisTable);
    
    this.subviews.push(new App.View.Widgets.Container({
      widgets: this._widgets,
      el: this.$('.bottom .widgetContainer')
    }));
  },

  onClose: function() {
    this._mapView.close();
    App.View.Panels.Splitted.prototype.onClose.call(this);    
  },

  _recalculeWidgets: function(clicked) {
    if (this.poisByType && this.poisTable) {
      this.poisByType.refresh();
      this.poisTable.refresh();
    } else {
      this._customRenderDetails(clicked);
    }

  }
});
