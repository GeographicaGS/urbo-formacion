'use strict';

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

    // Skip more code if widget is not allowed
    if(!this.hasPermissions()) return;

    var _this = this;
    _.bindAll(this, '_calculeDistance');

    this.$el.addClass('issuesRanking');    
    var tableModel = new Backbone.Model({
      'css_class':'issuesRanking',
      'csv':false,
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
        'distance':  {'title': __('Distancia'), 'formatFN': this._calculeDistance, 'css_class':'textcenter'},
      }
    });

    this.collection = new App.Collection.MapsCollection([],{
      scope: this.options.id_scope,
      type: 'now',
      entity: 'students.pointofinterest',
      data: {
        filters: options.filterModel
      }
    });
    
    this.collection.parse = function(response) {
      if (!response.features) {
        return response;
      }
      return _.map(_.filter(response.features, function(feature) {
          return feature.properties.category[0] !== '29';
        }), function(r) {
          r.name = r.properties.name;
          r.category = r.properties.category;
          r.distance = r.geometry;
          if (r.category[0] === '188' || r.category[0] === '111') {
            r.category[0] = '371';
          }
          r.category = r.category[0];
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
    if (this.options.filterModel && this.options.filterModel.get('the_geom')) {
      App.View.Widgets.Base.prototype.render.call(this);
    }
    return this;
  },

  _calculeDistance: function(d) {
    return App.nbf(turf.distance(d, this.options.filterModel.clicked.properties.coord)) + " Km.";
  }

});
