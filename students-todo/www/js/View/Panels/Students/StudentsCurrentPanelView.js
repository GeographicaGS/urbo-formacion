'use strict';

/**
 * Panel de tiempo real. En este caso extiende de Splitted
 * En la parte superior cargamos el mapa, en la parte inferior los widgets
 * Este Panel admite además modificar la parte inferior para cargar detalles de
 * una entidad concreta
 */
App.View.Panels.Students.Current = App.View.Panels.Splitted.extend({
   /**
    * 1. _events: para no sobrescribir la propiedad events que puede estar definida en el padre.
    *    Luego extenderemos events y llamaremos a la función delegateEvents para que los añada.
    */
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


    /**
     * 2. Creamos un filterModel que se utiliza para compartir filtros entre mapa y widgets.
     *    En este caso el único valor dinámico será 'variable', que hace referencia al radio.
     */
    this.filterModel = new Backbone.Model({
      variable: '10',
      status: App.Static.Collection.Students.POIsTypes.pluck('id'),
      condition: {} // Will be empty, is needed for map's endpoint
    });

    this.events = _.extend({},this._events, this.events);
    this.delegateEvents();

    /**
     * 3. TODO: Escuchamos cambios en the_geom de filterModel para recalcular los widgets
     */

    this.render();
  },

  customRender: function() {
    this._widgets = [];

    this.subviews.push(new App.View.Widgets.Container({
      widgets: this._widgets,
      el: this.$('.bottom .widgetContainer')
    }));
  },

  /**
   * 4. OnAttachToDOM se ejecuta una vez el DOM ha cargado en el navegador
   *    En esta función cargamos el mapa, ya que es necesario que la página haya
   *    renderizado para que el mapa se ajuste correctamente a la ventana.
   */
  onAttachToDOM: function() {

    /**
     * 5. TODO: Construye el mapa. Se le indica en que elemento del DOM debe cargarse
     *    y se le pasa el filterModel al que escuchará para modificar su filtro
     *    PRIMERO AÑADIMOS EL MAPA SIN LAYER, DESPUES CONTRUIREMOS LAS CAPAS
     */
    this._mapView = new App.View.Map.Students.Residences({
      el: this.$('.top'),
      filterModel: this.filterModel,      
      scope: this.scopeModel.get('id'),
      type: 'historic'
    }).render();

    /**
     * 6. TODO: Construye el filtro/leyenda de POI. Recibe el modelo de filtro por si
     *    fuese necesario hacer filtrado por algún campo
     *    ESTO DEJAR PARA EL FINAL
     */

    
    this.subviews.push(this._mapView);
    
    this.$('.co_fullscreen_toggle').remove();

    /**
     * 7. En este caso, a pesar de tratarse de un panel Splitted, la primera carga 
     *    debe hacerse con el mapa a pantalla completa.
     */
    this._forceMapFullScreen(true);

    /**
     * 8. Escuchamos el modelo mapChanges (de ResidenceMapView) para saber cuando hay que abrir
     *    los detalles
     */
    this.listenTo(this._mapView.mapChanges,'change:clickedResidence', this._openDetails);
  },
  
  /**
   * 9. TODO: Función _openDetails, se ejecuta al pulsar sobre una residencia o el pulsar sobre el
   *    botón de "BACK" de la misma. 
   *    Si lo que recibe es un NULL entonces entendemos que se esta cerrando el panel de detalles
   *    y en ese caso tan solo forzamos que se vuelva a abrir el mapa a pantalla completa.
   *    En otro caso el proceso es el siguiente:
   *      1.  Cierra pantalla completa
   *      2.  Limpia la pantalla de widgets (si los hubiese)
   *      3.  Refresca/Crea los widgets con la nueva residencia (vuelve a pedir datos a backend)
   *      4.  Refresca Masonry para colocar los widgets correctamente
   *      5.  Modifica el título de la sección de detalles
   */
  _openDetails: function(e) {
    
  },


  /**
   * 10.  Función _forceMapFullScreen
   *      Habilita o deshabilita la pantalla completa del mapa
   */
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

  /**
   * 11.  _goBack: Función de volver atrás
   *      Cierra los detalles de una residencia. Setea clickedResidencie a null
   */
  _goBack: function() {
    this._mapView.mapChanges.set('clickedResidence', null);
    this._mapView.mapChanges.set('the_geom', null);
    this.poisTable.close();
    this.poisByType.close();
    this.distanceToPOIS.close();
    this.poisTable = null;
    this.poisByType = null;
    this.distanceToPOIS = null;
  },

  /**
   * 12.  TODO: Función que dada una residencia carga los widgets de detalles
   */
  _customRenderDetails: function(residence) {
    this._widgets = [];
    
     // TODO:
    
    this.subviews.push(new App.View.Widgets.Container({
      widgets: this._widgets,
      el: this.$('.bottom .widgetContainer')
    }));
  },

  onClose: function() {
    this._mapView.close();
    App.View.Panels.Splitted.prototype.onClose.call(this);    
  },

  /**
   * 13.  TODO: Función que refresca los widgets si existen, si no los crea
   */
  _recalculeWidgets: function(clicked) {
    

  }
});
