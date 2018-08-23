'use strict';

App.View.Widgets.Students.DistanceToPOIS = App.View.Widgets.Base.extend({

  initialize: function(options) {
    options = _.defaults(options,{
      title: 'Distance to Points of Interest',
      timeMode:'now',
      id_category: 'students',
      publishable: false,
      classname: 'App.View.Widgets.Students.DistanceToPOIS',
    });
    App.View.Widgets.Base.prototype.initialize.call(this,options);

    var _this = this;

    this._model = new App.Model.Post();
    this._model.url = App.config.api_url + '/' + options.id_scope + '/students/distances';
    this._model.fetch = function(options) {
      options.type = 'POST';
      options.data = {
        "id_entity": 'ResidenzeUniversitarie:MI041' //_this.options.id_entity
      };
      options.data = JSON.stringify(options.data);

      this.constructor.__super__.fetch.call(this, options);
    }
    
    this.subviews.push(new App.View.Widgets.MultipleVariable({
      collection: this._model, 
      variables: [
        {
          label: __('Minimum'),
          param: 'min',
          class: 'min',
          nbf: App.nbf,
          units: 'm'
        },
        {
          label: __('Average'),
          param: 'avg',
          class: 'avg',
          nbf: App.nbf,        
          units: 'm'
        },
        {
          label: __('Maximum'),
          param: 'max',
          class: 'max',
          nbf: App.nbf,        
          units: 'm'
        }],
    }));
  }
});