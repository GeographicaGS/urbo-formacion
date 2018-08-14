'use strict';

App.View.Widgets.Students.ResidencesByCategory = App.View.Widgets.Base.extend({

  initialize: function(options) {
    options = _.defaults(options,{
      title: __('Residences by category'),
      timeMode:'now',
      id_category: 'students',
      refreshTime : 80000,
      publishable: true,
      classname: 'App.View.Widgets.Students.ResidencesByCategory'
    });

    App.View.Widgets.Base.prototype.initialize.call(this,options);
    if(!this.hasPermissions()) return;

    this.collection = new App.Collection.Histogram([], {
      scope: this.options.id_scope,
      type: 'discrete',
      mode: this.options.timeMode,
      variable: 'transport.vehicle.serviceprovided',
      data: {
        filters: {
        },
        ranges: 'all'
      }
    });

    this.collection.parse = function(response) {
      const elements = [
        {
          key:"private",
          values: [
            { x: 'private', y: 9 },
            { x: 'public', y: 13 }
          ]
        }
      ];

      return elements;
    };

    this._chartModel = new App.Model.BaseChartConfigModel({
      colors: function(d,index){
        if (index >= 0) {
          var color = App.Static.Collection.Students.ResidencesType.get(d.values[index].x).get('color');
          return color;
        }
      }.bind(this),
      xAxisFunction: function(d) {
        return d;
      },
      yAxisFunction: function(d) { return  App.nbf(d); },
      yAxisTickFormat: function(d) {
        var name = App.Static.Collection.Students.ResidencesType.get(d).get('name');
        return name;
      },
      yAxisLabel: ['Residences'],
      hideYAxis2: true,      
      legendNameFunc: function(d) {
        var name = App.Static.Collection.Students.ResidencesType.get(d).get('name');
        return name;
      },
      realTime: true,
      hideLegend: false,
      legendTemplate: function() {
        return '<strong>Total:</strong> 22';
      },
      keysConfig: {
        '*': {type: 'bar', axis: 1}
      },
      yAxisDomain: [[0, 20]]
    });

    this.subviews.push( new App.View.Widgets.Charts.D3.BarsLine({
      'opts': this._chartModel,
      'data': this.collection
    }));

    this.filterables = [this.collection];
  },
});
