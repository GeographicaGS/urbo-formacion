// Copyright 2017 Telefónica Digital España S.L.
// 
// PROJECT: urbo-telefonica
// 
// This software and / or computer program has been developed by 
// Telefónica Digital España S.L. (hereinafter Telefónica Digital) and is protected as 
// copyright by the applicable legislation on intellectual property.
// 
// It belongs to Telefónica Digital, and / or its licensors, the exclusive rights of
// reproduction, distribution, public communication and transformation, and any economic
// right on it, all without prejudice of the moral rights of the authors mentioned above.
// It is expressly forbidden to decompile, disassemble, reverse engineer, sublicense or
// otherwise transmit by any means, translate or create derivative works of the software and
// / or computer programs, and perform with respect to all or part of such programs, any
// type of exploitation.
// 
// Any use of all or part of the software and / or computer program will require the
// express written consent of Telefónica Digital. In all cases, it will be necessary to make
// an express reference to Telefónica Digital ownership in the software and / or computer
// program.
// 
// Non-fulfillment of the provisions set forth herein and, in general, any violation of
// the peaceful possession and ownership of these rights will be prosecuted by the means
// provided in both Spanish and international law. Telefónica Digital reserves any civil or
// criminal actions it may exercise to protect its rights.

App.Collection.Students.PanelList = Backbone.Collection.extend({
  initialize: function(models,options) {
    var base = '/' + options.scopeModel.get('id') + '/' + options.id_category;
    var _verticalOptions = [{
        id : 'master',
        title: __('Estado general'),
        url:base + '/dashboard',
      },
      {
        id : 'current',
        title: __('Points of Interest'),
        url:base + '/dashboard/current',
      }
    ];

    this.set(_verticalOptions);    
  }
});
App.Utils.Students.calculatedValue = function(realValue,c) {
  return Math.pow((1/100)*realValue, c) * 100;
},

App.Static.Collection.Students.ResidencesType =  new Backbone.Collection([
  {id: 'private', name: 'Private', color: '#FBCF99'},
  {id: 'public', name: 'Public', color: '#F7A034'}
]);

App.Static.Collection.Students.POIsTypes =  new Backbone.Collection([
  {id: 'pois', name: 'Points of Interest', color: '#58BC8F', icon: '/verticals/students/img/pois_negative.svg'},  
  {id: '107', name: 'Landmarks', color: '#DB6CA2', icon: '/verticals/students/img/historic-shop-white.svg'},
  {id: '29', name: 'Colleges and Universities', color: '#ACB35D', icon: '/verticals/students/img/reserved-white.svg'},  
  {id: '311', name: 'Museums', color: '#857DC9', icon: '/verticals/students/img/museo-white.svg'},
  {id: '371', name: 'Protected Area', color: '#98C16C', icon: '/verticals/students/img/reserved-white.svg'},
  {id: '420', name: 'Itinerary', color: '#3081C9', icon: '/verticals/students/img/itinerary-white.svg'},
  {id: '435', name: 'Hostels', color: '#E16464', icon: '/verticals/students/img/hostel-white.svg'},
]);