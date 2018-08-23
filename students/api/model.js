'use strict';

var PGSQLModel = require('../../models/pgsqlmodel');
var DummyFormatter = require('../../protools/dummyformatter');

class StudentsModel extends PGSQLModel {
  constructor(cfg) {
    super(cfg);
  }

  get this() {
    return this;
  }

  getDistances(opts) {
    var sql = `
      SELECT min_dist AS min,
             avg_dist AS avg,
             max_dist AS max
      FROM ${ opts.scope }.students_distance_agg_day
      WHERE id_entity LIKE '${ opts.id_entity }';
    `;

    return this.query(sql)
      .then(function(data) {
        return new DummyFormatter().firstRow(data);
      });
  }
}

module.exports = StudentsModel;
