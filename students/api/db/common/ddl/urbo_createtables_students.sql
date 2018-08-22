
DROP FUNCTION IF EXISTS urbo_createtables_students(text, boolean, boolean, text);

CREATE OR REPLACE FUNCTION urbo_createtables_students(
    id_scope text,
    isdebug boolean DEFAULT FALSE,
    iscarto boolean DEFAULT FALSE,
    cartouser text DEFAULT NULL
)
RETURNS TEXT AS
$$
DECLARE
    tb_students_name text;
    tb_names text[];
    _sql text;
    _checktable bool;
BEGIN

    tb_students_name = urbo_get_table_name(id_scope, 'students_pointofinterest', iscarto, true);

    tb_names = ARRAY[tb_students_name];

    _sql = NULL;

    _checktable = urbo_checktable_ifexists_arr(id_scope, tb_names, true);
    IF _checktable IS NULL OR NOT _checktable THEN

        _sql = format('

            CREATE TABLE IF NOT EXISTS %s (
                name text,
                description text,
                position public.geometry(Point,4326),
                address jsonb,
                category integer,
                refseealso text[],
                "TimeInstant" timestamp without time zone,
                id_entity character varying(64) NOT NULL,
                created_at timestamp without time zone DEFAULT timezone(''utc''::text, now()),
                updated_at timestamp without time zone DEFAULT timezone(''utc''::text, now())
            );

        ', tb_students_name);

        _sql = _sql || urbo_pk_qry(tb_names);
        _sql = _sql || urbo_time_idx_qry(tb_names);
        _sql = _sql || urbo_unique_lastdata_qry(tb_names);

        IF iscarto THEN
            _sql = _sql || urbo_cartodbfy_tables_qry(cartouser, tb_names);
        ELSE
            _sql = _sql || urbo_geom_idx_qry('position', tb_names);
            _sql = _sql || urbo_tbowner_qry(tb_names);
        END IF;


        IF isdebug then
            RAISE NOTICE '%', _sql;
        END IF;

        EXECUTE _sql;

    END IF;

    RETURN _sql;

END;
$$ LANGUAGE plpgsql;
