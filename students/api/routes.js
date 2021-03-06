'use strict';

var express = require('express');
var router = express.Router();
var utils = require('../../utils.js');
var StudentsModel = require('./model.js');
var responseValidator = utils.responseValidator;
var log = utils.log();
var MetadataInstanceModel = require('../../models/metadatainstancemodel');

var distancesValidator = function(req, res, next) {
  req.checkBody('id_entity', 'Residence\'s id is required').notEmpty();
  return next();
};

router.post('/distances',
  distancesValidator,
  responseValidator,
  function(req, res) {

    var opts = {
      scope: req.scope,
      idEntity: req.body.id_entity
    };

    var model = new StudentsModel();

    return model.getDistances(opts)
    .then(function(data) {
      return res.json(data);
    })
    .catch(function(err) {
      log.error(err);
      res.status(400).json(err);
    });
});

module.exports = router;
