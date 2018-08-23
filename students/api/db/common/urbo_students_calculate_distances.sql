DROP FUNCTION IF EXISTS urbo_students_calculate_distances(varchar, boolean);
CREATE OR REPLACE FUNCTION urbo_students_calculate_distances(
    id_scope varchar,
    iscarto boolean DEFAULT false
  )
RETURNS void
AS $$
DECLARE
  _residences_qry text;
  _agg_qry text;
  _del_qry text;
  _r record;
BEGIN
  _del_qry = format('
    DELETE FROM %s;
  ',
    urbo_get_table_name(id_scope, 'students_distance_agg_day', iscarto));

  EXECUTE _del_qry;

  _residences_qry = format('
    SELECT id_entity, position FROM %s WHERE category = 29;
  ', urbo_get_table_name(id_scope, 'students_pointofinterest_lastdata', iscarto));

  FOR _r IN EXECUTE _residences_qry
  LOOP
    _agg_qry = format('
      INSERT INTO %1$s (id_entity, min_dist, avg_dist, max_dist)
      SELECT %2$L, MIN(distances.val), AVG(distances.val), MAX(distances.val)
      FROM
      (
        SELECT
            ST_DistanceSphere(%3$L, position) val
        FROM %4$s
        WHERE (
            category != 29
            AND
            ST_DistanceSphere(%3$L, position) <= 10000
        )
      ) distances;
    ',
      urbo_get_table_name(id_scope, 'students_distance_agg_day', iscarto),
      _r.id_entity,
      _r.position,
      urbo_get_table_name(id_scope, 'students_pointofinterest_lastdata', iscarto));
    EXECUTE _agg_qry;
  END LOOP;
END;
$$
LANGUAGE plpgsql;
