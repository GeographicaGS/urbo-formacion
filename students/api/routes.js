'use strict';

var express = require('express');
var router = express.Router();
var utils = require('../../utils.js');
var StudentsModel = require('./model.js');
var responseValidator = utils.responseValidator;
var log = utils.log();
var MetadataInstanceModel = require('../../models/metadatainstancemodel');

var distancesValidator = function(req, next) {
  req.checkQuery('id_entity', 'Residence\'s id is required').notEmpty();
  return next();
};

router.post('/:id_scope/distances',
  distancesValidator,
  responseValidator,
  function(req, res) {

    var opts = {
      scope: req.scope,
      idEntity: req.id_entity
    };

    var model = new StudentsModel();

    return model.getDistances(opts)
    .then(function(data) {
      return res.json(dt);
    })
    .catch(function(err) {
      log.error(err);
      res.status(400).json(err);
    });
});

module.exports = router;
