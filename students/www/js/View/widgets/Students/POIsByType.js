'use strict';

App.View.Widgets.Students.POIsByType = App.View.Widgets.Base.extend({

  initialize: function(options) {
    options = _.defaults(options,{
      title: __('Points of interest'),
      timeMode:'now',
      id_category: 'students',
      refreshTime : 80000,
      publishable: true,
      classname: 'App.View.Widgets.Students.POIsByType'
    });

    App.View.Widgets.Base.prototype.initialize.call(this,options);
    if(!this.hasPermissions()) return;

    this.collection = new App.Collection.Histogram([], {
      scope: this.options.id_scope,
      type: 'discrete',
      mode: this.options.timeMode,
      variable: 'students.pointofinterest.category',
      data: {
        filters: options.filterModel,
        ranges: 'all'
      }
    });

    
    var _this = this;
    this.collection.parse = function(response) {
      const elements = [
        {
          key:"pois",
          values: _.filter(_.map(response, function(r) {
              if (r.category[0] === '188' || r.category[0] === '111') {
                r.category[0] = '371';
              }

              return {x: r.category[0], y: r.value}
            }), function(poi) {
              return poi.x !== '29';
            })
        }
      ];
      var total = 0;
      _.each(elements[0].values, function(element) {
        total += parseInt(element.y)
      });
      _this._chartModel.set({yAxisDomain:[[0,total]]})

      return elements;
    };

    this._chartModel = new App.Model.BaseChartConfigModel({
      colors: function(d,index){
        if (index >= 0) {
          var color = App.Static.Collection.Students.POIsTypes.get(d.values[index].x).get('color');
          return color;
        }
      }.bind(this),
      xAxisFunction: function(d) {
        return App.Static.Collection.Students.POIsTypes.get(d).get('name');
      },
      yAxisFunction: function(d) { return  App.nbf(d); },
      useImageAsLegendX: true,
      yAxisTickFormat: function(d) {
        var name = App.Static.Collection.Students.POIsTypes.get(d).get('icon');
        return name;
      },
      yAxisLabel: ['Residences'],
      hideYAxis2: true,      
      legendNameFunc: function(d) {
        var name = App.Static.Collection.Students.POIsTypes.get(d).get('name');
        return name;
      },
      realTime: true,
      hideLegend: false,
      legendTemplate: function(d) {
        var total = 0;
        _.each(d.data[0].values, function(element) {
          total += parseInt(element.y)
        });
        return '<strong>Total:</strong>' + total;
      },
      keysConfig: {
        '*': {type: 'bar', axis: 1}
      },
      groupSpacing: 0.3,
      margin: {top: 40, right: 50, bottom: 90, left: 50},
      yAxisDomain: [[0, 14]]
    });

    this.subviews.push( new App.View.Widgets.Charts.D3.BarsLine({
      'opts': this._chartModel,
      'data': this.collection
    }));

    this.filterables = [this.collection];
  },
});
