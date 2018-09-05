SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET client_min_messages = warning;
SET row_security = off;

--
-- TOC entry 38 (class 2615 OID 21339)
-- Name: metadata; Type: SCHEMA; Schema: -; Owner: :owner
--

CREATE SCHEMA metadata;


ALTER SCHEMA metadata OWNER TO :owner;

--
-- TOC entry 2947 (class 1247 OID 47683)
-- Name: frame_type; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE public.frame_type AS ENUM (
    'cityanalytics',
    'scope',
    'vertical'
);


ALTER TYPE public.frame_type OWNER TO postgres;

--
-- TOC entry 4943 (class 1247 OID 95347)
-- Name: tentitesmapcounters; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE public.tentitesmapcounters AS (
	id_entity text,
	nfilter integer,
	nall integer
);


ALTER TYPE public.tentitesmapcounters OWNER TO postgres;

--
-- TOC entry 2403 (class 1255 OID 22947)
-- Name: array_avg(double precision[]); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.array_avg(double precision[]) RETURNS double precision
    LANGUAGE sql
    AS $_$
SELECT avg(v) FROM unnest($1) g(v)
$_$;


ALTER FUNCTION public.array_avg(double precision[]) OWNER TO postgres;

--
-- TOC entry 2404 (class 1255 OID 22948)
-- Name: cdb_jenksbins(numeric[], integer, integer, boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.cdb_jenksbins(in_array numeric[], breaks integer, iterations integer DEFAULT 5, invert boolean DEFAULT false) RETURNS numeric[]
    LANGUAGE plpgsql IMMUTABLE
    AS $$
DECLARE
    element_count INT4;
    arr_mean NUMERIC;
    bot INT;
    top INT;
    tops INT[];
    classes INT[][];
    i INT := 1; j INT := 1;
    curr_result NUMERIC[];
    best_result NUMERIC[];
    seedtarget TEXT;
    quant NUMERIC[];
    shuffles INT;
BEGIN
    -- get the total size of our row
    element_count := array_length(in_array, 1); --array_upper(in_array, 1) - array_lower(in_array, 1);
    -- ensure the ordering of in_array
    SELECT array_agg(e) INTO in_array FROM (SELECT unnest(in_array) e ORDER BY e) x;
    -- stop if no rows
    IF element_count IS NULL THEN
        RETURN NULL;
    END IF;
    -- stop if our breaks are more than our input array size
    IF element_count < breaks THEN
        RETURN in_array;
    END IF;

    shuffles := LEAST(GREATEST(floor(2500000.0/(element_count::float*iterations::float)), 1), 750)::int;
    -- get our mean value
    SELECT avg(v) INTO arr_mean FROM (  SELECT unnest(in_array) as v ) x;

    -- assume best is actually Quantile
    SELECT CDB_QuantileBins(in_array, breaks) INTO quant;

    -- if data is very very large, just return quant and be done
    IF element_count > 5000000 THEN
        RETURN quant;
    END IF;

    -- change quant into bottom, top markers
    LOOP
        IF i = 1 THEN
            bot = 1;
        ELSE
            -- use last top to find this bot
            bot = top+1;
        END IF;
        IF i = breaks THEN
            top = element_count;
        ELSE
            SELECT count(*) INTO top FROM ( SELECT unnest(in_array) as v) x WHERE v <= quant[i];
        END IF;
        IF i = 1 THEN
            classes = ARRAY[ARRAY[bot,top]];
        ELSE
            classes = ARRAY_CAT(classes,ARRAY[bot,top]);
        END IF;
        IF i > breaks THEN EXIT; END IF;
        i = i+1;
    END LOOP;

    best_result = CDB_JenksBinsIteration( in_array, breaks, classes, invert, element_count, arr_mean, shuffles);

    --set the seed so we can ensure the same results
    SELECT setseed(0.4567) INTO seedtarget;
    --loop through random starting positions
    LOOP
        IF j > iterations-1 THEN  EXIT;  END IF;
        i = 1;
        tops = ARRAY[element_count];
        LOOP
            IF i = breaks THEN  EXIT;  END IF;
            SELECT array_agg(distinct e) INTO tops FROM (SELECT unnest(array_cat(tops, ARRAY[floor(random()*element_count::float)::int])) as e ORDER BY e) x WHERE e != 1;
            i = array_length(tops, 1);
        END LOOP;
        i = 1;
        LOOP
            IF i > breaks THEN  EXIT;  END IF;
            IF i = 1 THEN
                bot = 1;
            ELSE
                bot = top+1;
            END IF;
            top = tops[i];
            IF i = 1 THEN
                classes = ARRAY[ARRAY[bot,top]];
            ELSE
                classes = ARRAY_CAT(classes,ARRAY[bot,top]);
            END IF;
            i := i+1;
        END LOOP;
        curr_result = CDB_JenksBinsIteration( in_array, breaks, classes, invert, element_count, arr_mean, shuffles);

        IF curr_result[1] > best_result[1] THEN
            best_result = curr_result;
            j = j-1; -- if we found a better result, add one more search
        END IF;
        j = j+1;
    END LOOP;

    RETURN (best_result)[2:array_upper(best_result, 1)];
END;
$$;


ALTER FUNCTION public.cdb_jenksbins(in_array numeric[], breaks integer, iterations integer, invert boolean) OWNER TO postgres;

--
-- TOC entry 2405 (class 1255 OID 22949)
-- Name: cdb_jenksbinsiteration(numeric[], integer, integer[], boolean, integer, numeric, integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.cdb_jenksbinsiteration(in_array numeric[], breaks integer, classes integer[], invert boolean, element_count integer, arr_mean numeric, max_search integer DEFAULT 50) RETURNS numeric[]
    LANGUAGE plpgsql IMMUTABLE
    AS $$
DECLARE
    tmp_val numeric;
    new_classes int[][];
    tmp_class int[];
    i INT := 1;
    j INT := 1;
    side INT := 2;
    sdam numeric;
    gvf numeric := 0.0;
    new_gvf numeric;
    arr_gvf numeric[];
    class_avg numeric;
    class_max_i INT;
    class_min_i INT;
    class_max numeric;
    class_min numeric;
    reply numeric[];
BEGIN

    -- Calculate the sum of squared deviations from the array mean (SDAM).
    SELECT sum((arr_mean - e)^2) INTO sdam FROM (  SELECT unnest(in_array) as e ) x;
    --Identify the breaks for the lowest GVF
    LOOP
        i = 1;
        LOOP
            -- get our mean
            SELECT avg(e) INTO class_avg FROM ( SELECT unnest(in_array[classes[i][1]:classes[i][2]]) as e) x;
            -- find the deviation
            SELECT sum((class_avg-e)^2) INTO tmp_val FROM (   SELECT unnest(in_array[classes[i][1]:classes[i][2]]) as e  ) x;
            IF i = 1 THEN
                arr_gvf = ARRAY[tmp_val];
                -- init our min/max map for later
                class_max = arr_gvf[i];
                class_min = arr_gvf[i];
                class_min_i = 1;
                class_max_i = 1;
            ELSE
                arr_gvf = array_append(arr_gvf, tmp_val);
            END IF;
            i := i+1;
            IF i > breaks THEN EXIT; END IF;
        END LOOP;
        -- calculate our new GVF
        SELECT sdam-sum(e) INTO new_gvf FROM (  SELECT unnest(arr_gvf) as e  ) x;
        -- if no improvement was made, exit
        IF new_gvf < gvf THEN EXIT; END IF;
        gvf = new_gvf;
        IF j > max_search THEN EXIT; END IF;
        j = j+1;
        i = 1;
        LOOP
            --establish directionality (uppward through classes or downward)
            IF arr_gvf[i] < class_min THEN
                class_min = arr_gvf[i];
                class_min_i = i;
            END IF;
            IF arr_gvf[i] > class_max THEN
                class_max = arr_gvf[i];
                class_max_i = i;
            END IF;
            i := i+1;
            IF i > breaks THEN EXIT; END IF;
        END LOOP;
        IF class_max_i > class_min_i THEN
            class_min_i = class_max_i - 1;
        ELSE
            class_min_i = class_max_i + 1;
        END IF;
            --Move from higher class to a lower gid order
            IF class_max_i > class_min_i THEN
                classes[class_max_i][1] = classes[class_max_i][1] + 1;
                classes[class_min_i][2] = classes[class_min_i][2] + 1;
            ELSE -- Move from lower class UP into a higher class by gid
                classes[class_max_i][2] = classes[class_max_i][2] - 1;
                classes[class_min_i][1] = classes[class_min_i][1] - 1;
            END IF;
    END LOOP;

    i = 1;
    LOOP
        IF invert = TRUE THEN
            side = 1; --default returns bottom side of breaks, invert returns top side
        END IF;
        reply = array_append(reply, in_array[classes[i][side]]);
        i = i+1;
        IF i > breaks THEN  EXIT; END IF;
    END LOOP;

    RETURN array_prepend(gvf, reply);

END;
$$;


ALTER FUNCTION public.cdb_jenksbinsiteration(in_array numeric[], breaks integer, classes integer[], invert boolean, element_count integer, arr_mean numeric, max_search integer) OWNER TO postgres;

--
-- TOC entry 2406 (class 1255 OID 22950)
-- Name: cdb_quantilebins(numeric[], integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.cdb_quantilebins(in_array numeric[], breaks integer) RETURNS numeric[]
    LANGUAGE plpgsql IMMUTABLE
    AS $$
DECLARE
    element_count INT4;
    break_size numeric;
    tmp_val numeric;
    i INT := 1;
    reply numeric[];
BEGIN
    -- sort our values
    SELECT array_agg(e) INTO in_array FROM (SELECT unnest(in_array) e ORDER BY e ASC) x;
    -- get the total size of our data
    element_count := array_length(in_array, 1);
    break_size :=  element_count::numeric / breaks;
    -- slice our bread
    LOOP
        IF i < breaks THEN
            IF break_size * i % 1 > 0 THEN
                SELECT e INTO tmp_val FROM ( SELECT unnest(in_array) e LIMIT 1 OFFSET ceil(break_size * i) - 1) x;
            ELSE
                SELECT avg(e) INTO tmp_val FROM ( SELECT unnest(in_array) e LIMIT 2 OFFSET ceil(break_size * i) - 1 ) x;
            END IF;
        ELSIF i = breaks THEN
            -- select the last value
            SELECT max(e) INTO tmp_val FROM ( SELECT unnest(in_array) e ) x;
        ELSE
            EXIT;
        END IF;

        reply = array_append(reply, tmp_val);
        i := i+1;
    END LOOP;
    RETURN reply;
END;
$$;


ALTER FUNCTION public.cdb_quantilebins(in_array numeric[], breaks integer) OWNER TO postgres;

--
-- TOC entry 2524 (class 1255 OID 95456)
-- Name: container_status(text, timestamp without time zone, timestamp without time zone); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.container_status(vid_entity text, start timestamp without time zone, finish timestamp without time zone) RETURNS text
    LANGUAGE plpgsql
    AS $$
  DECLARE
    maxseconds real;
    csecs real;
    cdate timestamp;
    d record;
  BEGIN
    maxseconds = 0;
    cdate = null;

    IF not EXISTS (SELECT 1 FROM contenedor where id_entity=vid_entity AND timeinstant between start and finish AND nivel >= 90) THEN
      return 'ok';
    END IF;

    FOR d in (select nivel,timeinstant from contenedor where id_entity=vid_entity AND timeinstant between start and finish order by timeinstant ) LOOP
      --raise notice '%',d;
      maxseconds = maxseconds +1;

      if d.nivel>= 90 then
        if cdate is null then
          csecs = 0;
        else
          csecs = csecs + (select extract(epoch from age(d.timeinstant,cdate)));
        end if;
        -- raise notice '%',csecs;
        cdate = d.timeinstant;
      else
        cdate = null;
        maxseconds = greatest(maxseconds,csecs);
      end if;
    END LOOP;

    --raise notice 'maxminutes: %',maxseconds/(60*60);

    if maxseconds/(60*60)>= 1.5 then
      return 'error';
    else
      return 'warning';
    end if;

  END;
  $$;


ALTER FUNCTION public.container_status(vid_entity text, start timestamp without time zone, finish timestamp without time zone) OWNER TO postgres;

--
-- TOC entry 2426 (class 1255 OID 95348)
-- Name: entitesmapcounters(text, text[], public.geometry, text, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.entitesmapcounters(scope text, entities text[], bbox public.geometry, start text, finish text) RETURNS SETOF public.tentitesmapcounters
    LANGUAGE plpgsql
    AS $_$
DECLARE
  r tEntitesMapCounters;
  date_filter text;
  row RECORD;
  sql text;
BEGIN

  FOR row in SELECT table_name,id_entity
              FROM metadata.entities_scopes
              WHERE id_entity=ANY(entities)
              AND id_scope=scope
  LOOP

    sql = 'SELECT count(*) FROM '||scope||'.'||row.table_name||'_lastdata';
    EXECUTE sql INTO r.nall;

    r.id_entity = row.id_entity;

    IF start IS NOT NULL AND finish IS NOT NULL THEN
      date_filter = FORMAT(' AND "TimeInstant" >= $2::timestamp AND "TimeInstant" < $3::timestamp', start, finish);
    ELSE
      date_filter = '';
    END IF;

    IF bbox IS NOT NULL AND start IS NOT NULL AND finish IS NOT NULL THEN
      EXECUTE sql||' WHERE position && $1 AND "TimeInstant" >= $2::timestamp AND "TimeInstant" < $3::timestamp' INTO r.nfilter USING bbox, start, finish;
    ELSIF bbox IS NOT NULL THEN
      EXECUTE sql||' WHERE position && $1' INTO r.nfilter USING bbox;
    ELSIF start IS NOT NULL AND finish IS NOT NULL THEN
      EXECUTE sql||' WHERE "TimeInstant" >= $1::timestamp AND "TimeInstant" < $2::timestamp' INTO r.nfilter USING start, finish;
    ELSE
      r.nfilter = r.nall;
    END IF;

    return next r;

  END LOOP;
END;
$_$;


ALTER FUNCTION public.entitesmapcounters(scope text, entities text[], bbox public.geometry, start text, finish text) OWNER TO postgres;

--
-- TOC entry 2418 (class 1255 OID 43629)
-- Name: last_agg(anyelement, anyelement); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.last_agg(anyelement, anyelement) RETURNS anyelement
    LANGUAGE sql IMMUTABLE STRICT
    AS $_$
      SELECT $2;
$_$;


ALTER FUNCTION public.last_agg(anyelement, anyelement) OWNER TO postgres;

--
-- TOC entry 2530 (class 1255 OID 95462)
-- Name: solenoidvalve_histogram(text, timestamp without time zone, timestamp without time zone); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.solenoidvalve_histogram(vid_entity text, start timestamp without time zone, finish timestamp without time zone) RETURNS double precision
    LANGUAGE plpgsql
    AS $$
  DECLARE
    psecs real;
    tsecs real;
    date_reg timestamp;
    date_dur timestamp;
    d record;
  BEGIN
    tsecs := 0;

    IF not EXISTS (SELECT 1 FROM osuna.solenoidvalve
                    WHERE id_entity=vid_entity
                    AND "TimeInstant" BETWEEN start AND finish
                    AND status ='Regando'
                  ) THEN
      return tsecs;
    END IF;

    FOR d in (SELECT status,"TimeInstant"
              FROM osuna.solenoidvalve
              WHERE id_entity=vid_entity
              AND "TimeInstant" BETWEEN start AND finish)
    LOOP
      -- raise notice '%',d;

      IF d.status ='Regando' THEN
        date_reg := d."TimeInstant";
      ELSE
        IF d.status ='Durmiendo' THEN
          date_dur := d."TimeInstant";
          psecs := (SELECT extract(epoch FROM age(date_dur,date_reg)));
          tsecs := tsecs + psecs;
          -- raise notice '%',psecs;
        END if;
      END if;

    END LOOP;
    -- raise notice 'Total: %',tsecs;
    return tsecs;

  END;
  $$;


ALTER FUNCTION public.solenoidvalve_histogram(vid_entity text, start timestamp without time zone, finish timestamp without time zone) OWNER TO postgres;

--
-- TOC entry 2529 (class 1255 OID 95461)
-- Name: solenoidvalve_histogramclasses(text, timestamp without time zone, timestamp without time zone, integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.solenoidvalve_histogramclasses(vid_entity text, start timestamp without time zone, finish timestamp without time zone, classstep integer) RETURNS integer
    LANGUAGE plpgsql
    AS $$
  DECLARE
    psecs real;
    tsecs real;
    date_reg timestamp;
    date_dur timestamp;
    d record;
  BEGIN
    tsecs := 0;

    IF not EXISTS (SELECT 1 FROM osuna.solenoidvalve
                    WHERE id_entity=vid_entity
                    AND "TimeInstant" BETWEEN start AND finish
                    AND status ='Regando'
                  ) THEN
      return tsecs;
    END IF;

    FOR d in (SELECT status,"TimeInstant"
              FROM osuna.solenoidvalve
              WHERE id_entity=vid_entity
              AND "TimeInstant" BETWEEN start AND finish)
    LOOP
      -- raise notice '%',d;

      IF d.status ='Regando' THEN
        date_reg := d."TimeInstant";
      ELSE
        IF d.status ='Durmiendo' THEN
          date_dur := d."TimeInstant";
          psecs := (SELECT extract(epoch FROM age(date_dur,date_reg)));
          tsecs := tsecs + psecs;
          -- raise notice '%',psecs;
        END if;
      END if;

    END LOOP;

    tsecs := tsecs / 60;

    IF tsecs = 0 THEN
      return 0;
    ELSIF tsecs < (classstep) THEN
      return classstep;
    ELSIF tsecs < (classstep * 2) THEN
      return classstep * 2;
    ELSIF tsecs < (classstep * 3) THEN
      return classstep * 3;
    ELSIF tsecs < (classstep * 4) THEN
      return classstep * 4;
    ELSE
      return classstep * 5;
    END if;

  END;
  $$;


ALTER FUNCTION public.solenoidvalve_histogramclasses(vid_entity text, start timestamp without time zone, finish timestamp without time zone, classstep integer) OWNER TO postgres;

--
-- TOC entry 2528 (class 1255 OID 95460)
-- Name: solenoidvalve_hoursarray(text, timestamp without time zone, timestamp without time zone); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.solenoidvalve_hoursarray(vid_entity text, start timestamp without time zone, finish timestamp without time zone) RETURNS integer[]
    LANGUAGE plpgsql
    AS $$
  DECLARE
    hour_reg integer;
    hour_dur integer;
    hours_array integer[];
    hours_range integer[];
    date_reg timestamp;
    date_dur timestamp;
    d record;
  BEGIN

    IF not EXISTS (SELECT 1 FROM osuna.solenoidvalve
                    WHERE id_entity=vid_entity
                    AND "TimeInstant" BETWEEN start AND finish
                    AND status ='Regando'
                  ) THEN
      return ARRAY[]::integer[];
    END IF;

    FOR d in (SELECT status,"TimeInstant"
              FROM osuna.solenoidvalve
              WHERE id_entity=vid_entity
              AND "TimeInstant" BETWEEN start AND finish)
    LOOP
      -- raise notice '%',d;

      IF d.status ='Regando' THEN
        date_reg := d."TimeInstant";
      ELSE
        IF d.status ='Durmiendo' and date_reg IS NOT NULL THEN
          date_dur := d."TimeInstant";

          hour_reg := (SELECT extract(hour from date_reg::timestamp));
          hour_dur := (SELECT extract(hour from date_dur::timestamp));
          -- raise notice '% --- hour_reg %, hour_dur %, %',date_reg,hour_reg,hour_dur,vid_entity;
          IF hour_reg != hour_dur THEN
            hours_range := ARRAY[]::integer[];
            hours_range := (SELECT array_agg(extract(hour from dates::timestamp))
                          FROM generate_series(date_reg::timestamp,
                            date_dur::timestamp, '1 hours') as dates);

            hours_array := (SELECT array_cat(hours_array, hours_range));

            IF NOT hours_array @> ARRAY[hour_dur]::integer[]  THEN
              hours_array := (SELECT array_append(hours_array, hour_dur));

            END if;

          ELSE
            hours_array := (SELECT array_append(hours_array, hour_reg));

          END if;
          -- raise notice 'start %, finish %, %',date_reg,date_dur,hours_array;
        END if;
      END if;

    END LOOP;

    return hours_array;

  END;
  $$;


ALTER FUNCTION public.solenoidvalve_hoursarray(vid_entity text, start timestamp without time zone, finish timestamp without time zone) OWNER TO postgres;

--
-- TOC entry 2407 (class 1255 OID 22956)
-- Name: update_geom_hydra_tables(text, text, jsonb, boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.update_geom_hydra_tables(scope text, id_ent text, geom jsonb, iscarto boolean DEFAULT false) RETURNS text
    LANGUAGE plpgsql
    AS $$
  DECLARE
    _crt_op text;
    _geom text;
  BEGIN

  IF iscarto IS TRUE then
    _crt_op := '_';
    _geom := 'the_geom';
  ELSE
    _crt_op := '.';
    _geom := 'position';
  END IF;

  EXECUTE format('UPDATE %I%slighting_stcabinet
    SET %I=ST_SetSRID(ST_GeomFromGeoJSON(%s), 4326)
    WHERE id_entity=%s',
    scope, _crt_op, _geom, quote_literal(geom),
    quote_literal(id_ent));

  EXECUTE format('UPDATE %I%slighting_stcabinet_lastdata
    SET %I=ST_SetSRID(ST_GeomFromGeoJSON(%s), 4326)
    WHERE id_entity=%s',
    scope, _crt_op, _geom, quote_literal(geom),
    quote_literal(id_ent));

  return id_ent;

  END;
  $$;


ALTER FUNCTION public.update_geom_hydra_tables(scope text, id_ent text, geom jsonb, iscarto boolean) OWNER TO postgres;

--
-- TOC entry 2438 (class 1255 OID 95360)
-- Name: urbo_cartodbfy_tables_qry(text, text[]); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_cartodbfy_tables_qry(cartouser text, _tb_arr text[]) RETURNS text
    LANGUAGE plpgsql
    AS $$
  DECLARE
    _tb text;
    _stm text;
    _cartodbfy text;
  BEGIN
    FOREACH _tb IN ARRAY _tb_arr
      LOOP
        _stm = format(
          'SELECT CDB_Cartodbfytable(%L, %L);',
          cartouser, _tb
        );
        _cartodbfy = concat(_cartodbfy, _stm);
      END LOOP;

    RETURN _cartodbfy;

  END;
  $$;


ALTER FUNCTION public.urbo_cartodbfy_tables_qry(cartouser text, _tb_arr text[]) OWNER TO postgres;

--
-- TOC entry 2435 (class 1255 OID 95357)
-- Name: urbo_categories_ddl(text, text, text, boolean, boolean, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_categories_ddl(id_scope text, category text, category_name text, isdebug boolean DEFAULT false, iscarto boolean DEFAULT false, cartouser text DEFAULT NULL::text) RETURNS void
    LANGUAGE plpgsql
    AS $_$
  DECLARE
    _ddl_qry text;
  BEGIN

    IF iscarto IS TRUE then
      _ddl_qry = format('
        SELECT urbo_createtables_%s(%L, ''%s'', ''%s'', %L);',
        category,id_scope, isdebug, iscarto, cartouser);

    ELSE
      _ddl_qry = format('
        SET client_encoding = ''UTF8'';

        INSERT INTO metadata.categories_scopes
            (id_scope, id_category, category_name,config)
            VALUES
            (
              %1$L,
              %2$L,
              %3$L,
              (
                  select jsonb_set(
                      config,
                      ''{carto}'',
                      (
                          select
                              config->''carto''
                          from metadata.scopes
                          where id_scope=%1$L
                      )
                  )
                  from metadata.categories
                  where id_category=%2$L
              )
            )
        ;

        INSERT INTO metadata.entities_scopes (
              SELECT DISTINCT
                  %1$L,
                  e.*
              FROM metadata.entities e
              WHERE id_category=%2$L
        );

        INSERT INTO metadata.variables_scopes (
              SELECT DISTINCT
                  %1$L,
                  v.*
              FROM metadata.variables v
              where id_entity like ''%2$s%%''
        );

        SELECT urbo_createtables_%2$s(%1$L, ''%4$s'');

        SELECT urbo_create_graph_for_scope(%1$L, %2$L);
    ',
        id_scope,
        category,
        category_name,
        isdebug
    );

    END IF;

    IF isdebug IS TRUE then
      RAISE NOTICE '%', _ddl_qry;
    END IF;

    EXECUTE _ddl_qry;

  END;
  $_$;


ALTER FUNCTION public.urbo_categories_ddl(id_scope text, category text, category_name text, isdebug boolean, iscarto boolean, cartouser text) OWNER TO postgres;

--
-- TOC entry 2434 (class 1255 OID 95356)
-- Name: urbo_categories_usergraph(text, integer, boolean, boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_categories_usergraph(id_scope text, id_user integer, is_parent boolean DEFAULT false, is_superadmin boolean DEFAULT false) RETURNS SETOF text
    LANGUAGE sql
    AS $_$
    WITH RECURSIVE multiscope_childs(id_category, id_scope) AS (
      SELECT
        DISTINCT ON (cs.id_category)
          cs.id_category, cs.id_scope
      FROM metadata.categories_scopes cs
      JOIN public.users_graph ug ON (
      cs.id_category=ug.name
      AND (TRUE = $4 OR
        ($2 = ANY(ug.read_users)
        OR $2 = ANY(ug.write_users))
      )
    ) WHERE cs.id_scope = ANY(
        CASE WHEN $3 THEN array(
           SELECT sp.id_scope::text
           FROM metadata.scopes sp
           WHERE sp.parent_id_scope = $1
        )
        ELSE array(SELECT $1) END
      )
    )
    SELECT id_category::text FROM multiscope_childs;

$_$;


ALTER FUNCTION public.urbo_categories_usergraph(id_scope text, id_user integer, is_parent boolean, is_superadmin boolean) OWNER TO postgres;

--
-- TOC entry 2436 (class 1255 OID 95358)
-- Name: urbo_checktable_ifexists(text, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_checktable_ifexists(id_scope text, tablename text) RETURNS integer
    LANGUAGE plpgsql
    AS $$
  DECLARE
    _result int;
  BEGIN
    EXECUTE format('SELECT 1
       FROM   information_schema.tables
       WHERE  table_schema = %L
       AND    table_name = %L',
       id_scope, tablename)
    INTO
      _result;

    RETURN _result;
  END;
  $$;


ALTER FUNCTION public.urbo_checktable_ifexists(id_scope text, tablename text) OWNER TO postgres;

--
-- TOC entry 2437 (class 1255 OID 95359)
-- Name: urbo_checktable_ifexists_arr(text, text[], boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_checktable_ifexists_arr(id_scope text, tablenames_arr text[], remove_sch_from_tb boolean DEFAULT false) RETURNS integer
    LANGUAGE plpgsql
    AS $$
  DECLARE
    _tb text;
    _result int;
  BEGIN

    FOREACH _tb IN ARRAY tablenames_arr
      LOOP
        IF remove_sch_from_tb then
          _tb = replace(_tb, format('%s.',id_scope), '');
        END IF;

        _result = urbo_checktable_ifexists(id_scope, _tb);
        --RAISE NOTICE '%', _result;

        IF _result = 1 then
          RETURN _result;
        END IF;
      END LOOP;

    RETURN _result;
  END;
  $$;


ALTER FUNCTION public.urbo_checktable_ifexists_arr(id_scope text, tablenames_arr text[], remove_sch_from_tb boolean) OWNER TO postgres;

--
-- TOC entry 2431 (class 1255 OID 95353)
-- Name: urbo_create_graph_for_scope(text, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_create_graph_for_scope(id_scope text, id_category text) RETURNS numeric
    LANGUAGE plpgsql
    AS $$
  DECLARE
    _rootid numeric;
    _scopeid numeric;
    _categoryid numeric;
    _entityid numeric;
    _q text;
    _qent text;
    _qvar text;
    _insertvars text;
    _rq text;
    _r record;
    _ra record;
    _rvar record;
  BEGIN


    _q := format('SELECT id FROM public.users_graph where name=''root''');
    EXECUTE _q INTO _r;
    if _r IS NULL THEN
      RETURN NULL;
    END IF;
    _rootid := _r.id;

    -- FIRST INSERT scope

    _q := format('SELECT id FROM public.users_graph where name=''%s''', id_scope);
    EXECUTE _q INTO _r;
    -- raise notice '%', _r;
    IF _r is NULL THEN
      _q := format('
        WITH insertion as (
          INSERT INTO public.users_graph (
            name,
            parent,
            read_users,
            write_users
          )
          VALUES (
            ''%s'',
            %s,
            array[]::bigint[],
            array[]::bigint[]
          )
          RETURNING id
        )
        SELECT id FROM insertion
      ', id_scope, _rootid);

      -- raise notice '%', _q;
      EXECUTE _q into _r;
      -- raise notice '%', _r;
    END IF;
    _scopeid := _r.id;


    -- THEN INSERT category IF EXISTS

    _q := format('
        SELECT id_category
        FROM metadata.categories_scopes
        WHERE id_scope=''%s'' AND id_category=''%s''
    ', id_scope, id_category);

    -- RAISE NOTICE '%', _q;
    EXECUTE _q INTO _r;
    IF _r IS NULL THEN
      RETURN NULL;
    END IF;

    _q := format('
      WITH insertion as (
        INSERT INTO
          public.users_graph (
            name,
            parent,
            read_users,
            write_users
          )
        VALUES (
          ''%s'',
          %s,
          array[]::bigint[],
          array[]::bigint[]
        ) RETURNING id
      )
      SELECT id FROM insertion
    ', id_category, _scopeid);
    EXECUTE _q INTO _r;

    _categoryid := _r.id;

    -- SEARCH ENTITIES FOR CATEGORY

    _q := format('
      SELECT
        DISTINCT id_entity
      FROM metadata.entities_scopes
      WHERE id_scope=''%s''
      AND id_category =''%s''',
      id_scope, id_category);
    FOR _r IN EXECUTE _q LOOP

      -- raise notice '%', _r;
      _qent := format('
      WITH insertion as (
        INSERT INTO public.users_graph (name, parent, read_users, write_users)
        VALUES (''%s'', %s, array[]::bigint[],array[]::bigint[]) RETURNING id
      )
      SELECT id FROM insertion',
      _r.id_entity, _categoryid);
      -- RAISE NOTICE '%', _qent;
      EXECUTE _qent INTO _rq;
      -- RAISE NOTICE '%', _rq;

      _entityid = _rq;
      -- RAISE NOTICE '%', _entityid;

      -- SEARCH VARIABLES FOR ENTITY
      _qvar := format('
        SELECT
          DISTINCT id_variable
        FROM metadata.variables_scopes
        WHERE id_scope=''%s''
        AND id_entity=''%s''',
        id_scope, _r.id_entity);

      FOR _rvar IN EXECUTE _qvar LOOP
        _insertvars = format('
          INSERT INTO public.users_graph (name, parent, read_users, write_users)
          VALUES (''%s'', %s, array[]::bigint[],array[]::bigint[])',
        _rvar.id_variable, _entityid);

        -- raise notice '%', _insertvars;
        EXECUTE _insertvars;

      END LOOP;

    END LOOP;

    RETURN _categoryid;

  END;
  $$;


ALTER FUNCTION public.urbo_create_graph_for_scope(id_scope text, id_category text) OWNER TO postgres;

ALTER FUNCTION public.urbo_dumps_calculate_agg_filling_historic(id_scope character varying, start date, finish date, iscarto boolean) OWNER TO postgres;

--
-- TOC entry 2456 (class 1255 OID 95378)
-- Name: urbo_dumps_calculate_agg_filling_historic(character varying, date, date, numeric, numeric, boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_dumps_calculate_agg_filling_historic(id_scope character varying, start date, finish date, alert_threshold numeric DEFAULT 90, time_threshold numeric DEFAULT 7200, iscarto boolean DEFAULT false) RETURNS void
    LANGUAGE plpgsql
    AS $$
  DECLARE
    _q text;
    _d timestamp;

  BEGIN

    EXECUTE format('DELETE FROM %s WHERE day BETWEEN %L AND %L',
          urbo_get_table_name(id_scope, 'dumps_fillingagg', iscarto), start, finish);

    FOR _d IN select generate_series(start, finish, '1 day') LOOP
      _q = format('INSERT INTO %s
        SELECT id_entity, %L::date,
            urbo_dumps_container_status(%L::text, id_entity::text, %L::timestamp, %L::timestamp, %L::numeric, %L::numeric, %L::boolean)
          FROM %s',
        urbo_get_table_name(id_scope, 'dumps_fillingagg', iscarto), _d, id_scope, _d,
        _d + '1 day'::interval - '1 second'::interval, alert_threshold, time_threshold,
        iscarto, urbo_get_table_name(id_scope, 'dumps_wastecontainer', iscarto, true));
      EXECUTE _q;
    END LOOP;

  END
  $$;


ALTER FUNCTION public.urbo_dumps_calculate_agg_filling_historic(id_scope character varying, start date, finish date, alert_threshold numeric, time_threshold numeric, iscarto boolean) OWNER TO postgres;

--
-- TOC entry 2455 (class 1255 OID 95377)
-- Name: urbo_dumps_calculate_emptyings(character varying, timestamp without time zone, timestamp without time zone, boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_dumps_calculate_emptyings(id_scope character varying, start timestamp without time zone, finish timestamp without time zone, iscarto boolean DEFAULT false) RETURNS void
    LANGUAGE plpgsql
    AS $$
  DECLARE
    _q text;
  BEGIN
  --
  _q = format('DELETE FROM %s WHERE dateemptying BETWEEN %s::timestamp AND %s::timestamp',
      urbo_get_table_name(id_scope,'dumps_emptyings',iscarto),
      quote_literal(start),quote_literal(finish));

  EXECUTE _q;

  _q = format('INSERT INTO %s (id_entity,dateemptying,fillinglevel)
      SELECT id_entity,datelastemptying,
        (
          SELECT fillinglevel FROM %s b
          WHERE b.id_entity=a.id_entity
          AND b.datelastemptying<a.datelastemptying
          AND b."TimeInstant" BETWEEN (a.datelastemptying - ''96 hours''::interval) AND a.datelastemptying
          ORDER BY b."TimeInstant" DESC
          LIMIT 1
        ) as  fillinglevel
      FROM %s as a
      WHERE datelastemptying BETWEEN %s::timestamp AND %s::timestamp
      GROUP BY id_entity,datelastemptying',
      urbo_get_table_name(id_scope,'dumps_emptyings',iscarto),
      urbo_get_table_name(id_scope,'dumps_wastecontainer',iscarto),
      urbo_get_table_name(id_scope,'dumps_wastecontainer',iscarto),
      quote_literal(start),quote_literal(finish)
    );

  EXECUTE _q;

  END
  $$;


ALTER FUNCTION public.urbo_dumps_calculate_emptyings(id_scope character varying, start timestamp without time zone, finish timestamp without time zone, iscarto boolean) OWNER TO postgres;

--
-- TOC entry 2452 (class 1255 OID 95374)
-- Name: urbo_dumps_container_ranking(text, text, text, text, text, numeric, numeric, numeric, numeric); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_dumps_container_ranking(filter text, nschema text, ntable text, start text, finish text, llim numeric DEFAULT 80, ulim numeric DEFAULT 90, low numeric DEFAULT 80, up numeric DEFAULT 90) RETURNS SETOF jsonb
    LANGUAGE plpgsql
    AS $$
    DECLARE
        _d record;
        _freqs jsonb;
        _ret jsonb;
        _id int := 1;
        _ok int[];
        _warn int[];
        _error int[];
        _q text;
        _preQry text;
        _rQry text;
        _aQry text;
        _query text;
        _eff numeric;
        _ineff numeric;
        _synth numeric;
    BEGIN

        _q := format('SELECT id_entity, storedwastekind,
                urbo_dumps_emptying_freq(%s, %s, id_entity,%s,%s,%s,%s) AS raw
                FROM %I.%I WHERE true %s',
                quote_literal(nschema),
                quote_literal('dumps_emptyings'),
                quote_literal(start),
                quote_literal(finish),
                llim, ulim, quote_ident(nschema), quote_ident(ntable||'_lastdata'),
                convert_from(decode(filter,'base64'), 'UTF-8')
                );

        _preQry := format('SELECT
                id_entity,
                storedwastekind,
                replace(raw::json->>%s,%s,%s) as ok,
                replace(raw::json->>%s,%s,%s) as warn,
                replace(raw::json->>%s,%s,%s) as error
                FROM q',
                quote_literal('ok'),
                quote_literal('['),
                quote_literal('{'),
                quote_literal('warn'),
                quote_literal('['),
                quote_literal('{'),
                quote_literal('error'),
                quote_literal('['),
                quote_literal('{'));

        _rQry := format('SELECT
                id_entity,
                storedwastekind,
                replace(ok,%s,%s) as ok,
                replace(warn,%s,%s) as warn,
                replace(error,%s,%s) as error
                FROM preQry',
                quote_literal(']'),
                quote_literal('}'),
                quote_literal(']'),
                quote_literal('}'),
                quote_literal(']'),
                quote_literal('}'));

        _aQry := 'SELECT
                id_entity,
                storedwastekind,
                urbo_dumps_flatten(array_cat(array_cat(ok::double precision[][], warn::double precision[][]), error::double precision[][])) as fulldata,
                ok, warn, error
                FROM rQry GROUP BY id_entity, storedwastekind, ok, warn, error';


        _query := format('WITH
            q as (%s),
            preQry as (%s),
            rQry as (%s),
            aQry as (%s)
            SELECT id_entity,
                storedwastekind,
                ok, warn, error,
                urbo_dumps_efficiency_calculator(fulldata, %s, %s) AS efficiency,
                urbo_dumps_synthetic_calculator(fulldata, %s, %s) AS synthetic
                FROM aQry ORDER BY efficiency ASC',
            _q, _preQry, _rQry, _aQry, low, up, low, up);

        -- RAISE NOTICE '%', _query;

        FOR _d in EXECUTE _query
        LOOP

            IF _d.ok IS NOT NULL THEN
                _ok := urbo_dumps_flatten(_d.ok::numeric[][], 1);
            ELSE
                _ok := ARRAY[]::numeric[];
            END IF;

            IF _d.warn IS NOT NULL THEN
                _warn := urbo_dumps_flatten(_d.warn::numeric[][], 1);
            ELSE
                _warn := ARRAY[]::numeric[];
            END IF;

            IF _d.error IS NOT NULL THEN
                _error := urbo_dumps_flatten(_d.error::numeric[][], 1);
            ELSE
                _error := ARRAY[]::numeric[];
            END IF;

            -- RAISE NOTICE '%', _ok;
            -- RAISE NOTICE '%', _warn;
            -- RAISE NOTICE '%', _error;

            _freqs := urbo_dumps_freq_agg(_ok, _warn, _error);
            IF _d.efficiency IS NULL THEN
                _eff := null;
                _ineff := null;
            ELSE
                _eff := _d.efficiency;
                _ineff := 1 - _eff;
            END IF;


            _ret := json_build_object(
                'id', _id,
                'id_entity', _d.id_entity,
                'storedwastekind', _d.storedwastekind,
                'ok', _ok,
                'warn', _warn,
                'error', _error,
                'efficiency', _eff,
                'inefficiency', _ineff,
                'synthetic', _d.synthetic,
                'freqs', _freqs
                );

            _id := _id +1;

            RETURN NEXT _ret;

        END LOOP;
    END;
    $$;


ALTER FUNCTION public.urbo_dumps_container_ranking(filter text, nschema text, ntable text, start text, finish text, llim numeric, ulim numeric, low numeric, up numeric) OWNER TO postgres;

--
-- TOC entry 2409 (class 1255 OID 22977)
-- Name: urbo_dumps_container_status(text, text, timestamp without time zone, timestamp without time zone, boolean, numeric); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_dumps_container_status(id_scope text, id_entity text, start timestamp without time zone, finish timestamp without time zone, iscarto boolean DEFAULT false, threshold numeric DEFAULT 90) RETURNS integer
    LANGUAGE plpgsql
    AS $$
  DECLARE
    maxseconds real;
    csecs real;
    cdate timestamp;
    _table_name text;
    _q text;
    _r record;
    d record;
  BEGIN
    maxseconds = 0;
    cdate = null;
    _table_name := urbo_get_table_name(id_scope, 'dumps_wastecontainer', iscarto);

    _q := format('
        SELECT 1 FROM %s WHERE id_entity=''%s''
        AND "TimeInstant" BETWEEN ''%s'' and ''%s'' AND fillinglevel >= %s',
        _table_name, id_entity, start, finish, threshold);

    -- raise notice '%', _q;

    EXECUTE _q INTO _r;
    -- raise notice 'NUM: %', _r;

    IF _r IS NULL THEN
      return 0;
    END IF;

    --raise notice '%',start;
    --raise notice '%',finish;

    _q := format('
      SELECT "TimeInstant", fillinglevel FROM %s WHERE id_entity=''%s''
      AND "TimeInstant" BETWEEN ''%s'' AND ''%s''
      ORDER BY "TimeInstant"',
      _table_name, id_entity, start, finish);

    FOR d in EXECUTE _q  LOOP
      -- raise notice '%',d;

      if d.fillinglevel >= threshold then
        if cdate is null then
          csecs = 0;
        else
          csecs = csecs + (SELECT extract(epoch FROM age(d."TimeInstant",cdate)));
        end if;
        -- raise notice 'Csecs %',csecs;
        cdate = d."TimeInstant";
      else
        cdate = null;
        maxseconds = greatest(maxseconds,csecs);
      end if;
    END LOOP;

    maxseconds = greatest(maxseconds,csecs);

    -- raise notice 'maxseconds: %',maxseconds;
    -- raise notice 'maxhours: %',maxseconds/(60*60);

    if maxseconds/(60*60)>= 2.0 then
      return 2;
    else
      return 1;
    end if;

  END;
$$;


ALTER FUNCTION public.urbo_dumps_container_status(id_scope text, id_entity text, start timestamp without time zone, finish timestamp without time zone, iscarto boolean, threshold numeric) OWNER TO postgres;

--
-- TOC entry 2454 (class 1255 OID 95376)
-- Name: urbo_dumps_container_status(text, text, timestamp without time zone, timestamp without time zone, numeric, numeric, boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_dumps_container_status(id_scope text, id_entity text, start timestamp without time zone, finish timestamp without time zone, alert_threshold numeric DEFAULT 90, time_threshold numeric DEFAULT 7200, iscarto boolean DEFAULT false) RETURNS integer
    LANGUAGE plpgsql
    AS $$
  DECLARE
    maxseconds real;
    csecs real;
    cdate timestamp;
    _table_name text;
    _q text;
    _r record;
    d record;
  BEGIN
    maxseconds = 0;
    cdate = null;
    _table_name := urbo_get_table_name(id_scope, 'dumps_wastecontainer', iscarto);

    _q := format('
        SELECT 1 FROM %s WHERE id_entity=''%s''
        AND "TimeInstant" BETWEEN ''%s'' and ''%s'' AND fillinglevel >= %s',
        _table_name, id_entity, start, finish, alert_threshold);
    EXECUTE _q INTO _r;

    IF _r IS NULL THEN
      return 0;
    END IF;

    _q := format('
      SELECT "TimeInstant", fillinglevel FROM %s WHERE id_entity=''%s''
      AND "TimeInstant" BETWEEN ''%s'' AND ''%s''
      ORDER BY "TimeInstant"',
      _table_name, id_entity, start, finish);

    FOR d in EXECUTE _q  LOOP
      -- raise notice '%',d;

      if d.fillinglevel >= alert_threshold then
        if cdate is null then
          csecs = 0;
        else
          csecs = csecs + (SELECT extract(epoch FROM age(d."TimeInstant", cdate)));
        end if;
        -- raise notice 'Csecs %',csecs;
        cdate = d."TimeInstant";
      else
        cdate = null;
        maxseconds = greatest(maxseconds, csecs);
      end if;
    END LOOP;

    maxseconds = greatest(maxseconds, csecs);

    if maxseconds >= time_threshold then
      return 2;
    else
      return 1;
    end if;

  END;
$$;


ALTER FUNCTION public.urbo_dumps_container_status(id_scope text, id_entity text, start timestamp without time zone, finish timestamp without time zone, alert_threshold numeric, time_threshold numeric, iscarto boolean) OWNER TO postgres;

--
-- TOC entry 2450 (class 1255 OID 95372)
-- Name: urbo_dumps_efficiency_calculator(double precision[], integer, integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_dumps_efficiency_calculator(data double precision[], low integer, up integer) RETURNS double precision
    LANGUAGE plpgsql
    AS $$
    DECLARE
        d record;
        inrange double precision;
        total double precision;
        ret double precision;
    BEGIN
        inrange = 0;
        total = 0;
        FOR d in (SELECT unnest(data) as column)
        LOOP
            IF d.column >= low AND d.column <= up THEN
                inrange = inrange + 1;
            END IF;
            total = total + 1;
        END LOOP;

        IF total != 0 THEN
            ret = inrange / total;
        ELSE
            ret = null;
        END IF;
        RETURN ret;
    END;
    $$;


ALTER FUNCTION public.urbo_dumps_efficiency_calculator(data double precision[], low integer, up integer) OWNER TO postgres;

--
-- TOC entry 2446 (class 1255 OID 95368)
-- Name: urbo_dumps_emptying_freq(text, text, text, text, text, numeric, numeric, boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_dumps_emptying_freq(nschema text, ntable text, id_ent text, start text, finish text, llim numeric DEFAULT 80, ulim numeric DEFAULT 90, iscarto boolean DEFAULT false) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
  DECLARE
    _maxlev double precision;
    _dsecs double precision;
    _xy jsonb;
    _xy_ok double precision[][];
    _xy_wrn double precision[][];
    _xy_err double precision[][];
    _xy_r double precision[];
    _date_prev timestamp;
    _date_curr timestamp;
    _crt_op text;
    _d record;
  BEGIN
    _dsecs := 0;
    _date_prev := null;

    IF iscarto IS TRUE then
      _crt_op := '_';
    ELSE
      _crt_op := '.';
    END IF;

    FOR _d in EXECUTE
              format('SELECT dateemptying as dtle,
              fillinglevel as _maxlevel FROM %I%s%I
              WHERE (%I BETWEEN %s::timestamp AND %s::timestamp)
              AND id_entity=%s ORDER BY dtle desc',
              nschema,_crt_op,ntable,'dateemptying',
              quote_literal(start),quote_literal(finish),
              quote_literal(id_ent))
    LOOP
      -- raise notice '%',_d;

      IF _date_prev IS NOT NULL then
          _date_curr := _d.dtle;
          _dsecs := extract(epoch FROM age(_date_prev,_date_curr));

          _maxlev := _d._maxlevel;
          _xy_r := ARRAY[_dsecs,_maxlev];

          IF _maxlev >= ulim then
            _xy_err := ARRAY[_xy_r] || _xy_err;

          ELSIF _maxlev >= llim AND _maxlev < ulim then
            _xy_wrn := ARRAY[_xy_r] || _xy_wrn;

          ELSE
            _xy_ok := ARRAY[ _xy_r] || _xy_ok;

          END IF;

          -- raise notice '%',_xy_r;

      END if;

      _date_prev := _d.dtle;
    --
    END LOOP;
    -- raise notice '_xy_err: %',_xy_err;
    -- raise notice '_xy_wrn: %',_xy_wrn;
    -- raise notice '_xy_ok: %',_xy_ok;

    _xy := json_build_object('error',_xy_err,'warn', _xy_wrn,'ok', _xy_ok);

    return _xy;

  END;
  $$;


ALTER FUNCTION public.urbo_dumps_emptying_freq(nschema text, ntable text, id_ent text, start text, finish text, llim numeric, ulim numeric, iscarto boolean) OWNER TO postgres;

--
-- TOC entry 2447 (class 1255 OID 95369)
-- Name: urbo_dumps_flatten(double precision[], integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_dumps_flatten(data double precision[], index integer DEFAULT 2) RETURNS double precision[]
    LANGUAGE plpgsql
    AS $$
    DECLARE
        x double precision[];
        result double precision[] := ARRAY[]::double precision[];
        len int;
    BEGIN
        len := (SELECT array_length(data, 1));
        -- raise notice '%', len;
        IF len >= 1 THEN
            FOREACH x SLICE 1 IN ARRAY data LOOP
                result := (SELECT array_append(result, x[index]));
            END LOOP;
        END IF;

        RETURN result;
    END;
    $$;


ALTER FUNCTION public.urbo_dumps_flatten(data double precision[], index integer) OWNER TO postgres;

--
-- TOC entry 2448 (class 1255 OID 95370)
-- Name: urbo_dumps_freq(double precision[]); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_dumps_freq(data double precision[]) RETURNS integer[]
    LANGUAGE plpgsql
    AS $$
    DECLARE
        lt__24 int := 0;
        lt__48 int := 0;
        lt__72 int := 0;
        gt__72 int := 0;
        x int;
        _ret int[4];
    BEGIN
        FOREACH x IN ARRAY data
        LOOP
            IF x > 0 AND x <= 86400 THEN
                lt__24 := lt__24 + 1;
            ELSIF x >86400 AND x <= 86400*2 THEN
                lt__48 := lt__48 + 1;
            ELSIF x >86400*2 AND x <= 86400*3 THEN
                lt__72 := lt__72 + 1;
            ELSIF x >86400*3 THEN
                gt__72 := gt__72 + 1;
            END IF;
        END LOOP;
        _ret[1] := lt__24;
        _ret[2] := lt__48;
        _ret[3] := lt__72;
        _ret[4] := gt__72;
        RETURN _ret;
    END;
    $$;


ALTER FUNCTION public.urbo_dumps_freq(data double precision[]) OWNER TO postgres;

--
-- TOC entry 2449 (class 1255 OID 95371)
-- Name: urbo_dumps_freq_agg(double precision[], double precision[], double precision[]); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_dumps_freq_agg(ok double precision[], warn double precision[], error double precision[]) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
    DECLARE
        _ret jsonb;
        _ok int[];
        _warn int[];
        _error int[];
    BEGIN
        _ok := urbo_dumps_freq(ok);
        _warn := urbo_dumps_freq(warn);
        _error := urbo_dumps_freq(error);

        -- RAISE NOTICE '%', _ok;
        -- RAISE NOTICE '%', _warn;
        -- RAISE NOTICE '%', _error;
        _ret := json_build_object(
            'lt__24', ARRAY[_ok[1], _warn[1], _error[1]],
            'lt__48', ARRAY[_ok[2], _warn[2], _error[2]],
            'lt__72', ARRAY[_ok[3], _warn[3], _error[3]],
            'gt__72', ARRAY[_ok[4], _warn[4], _error[4]]);
        RETURN _ret;
    END;
    $$;


ALTER FUNCTION public.urbo_dumps_freq_agg(ok double precision[], warn double precision[], error double precision[]) OWNER TO postgres;

--
-- TOC entry 2453 (class 1255 OID 95375)
-- Name: urbo_dumps_level_at_emptying(text, text, text, text, text, text, text, numeric, numeric, boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_dumps_level_at_emptying(nschema text, ntable text, id_ent text, start text, finish text, tm_resol text DEFAULT 'second'::text, filter text DEFAULT ''::text, llim numeric DEFAULT 80, ulim numeric DEFAULT 90, iscarto boolean DEFAULT false) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
  DECLARE
    _maxlev double precision;
    _dsecs double precision;
    _xy jsonb;
    _xy_ok jsonb[] DEFAULT '{}';
    _xy_wrn jsonb[] DEFAULT '{}';
    _xy_err jsonb[] DEFAULT '{}';
    _xy_r jsonb;
    _date_prev timestamp;
    _date_curr timestamp;
    _crt_op text;
    _d record;
  BEGIN
    _dsecs := 0;
    _date_prev := null;

    IF iscarto IS TRUE then
      _crt_op := '_';
    ELSE
      _crt_op := '.';
    END IF;

    FOR _d in EXECUTE
      format('SELECT date_trunc(%s, datelastemptying) as dtle,
                  MAX(fillinglevel) as _maxlevel FROM %I%s%I
                WHERE (%I BETWEEN %s::timestamp AND %s::timestamp)
                  AND id_entity = %s %s
                GROUP BY dtle ORDER BY dtle DESC',
              quote_literal(tm_resol), nschema, _crt_op, ntable, 'TimeInstant',
              quote_literal(start), quote_literal(finish),
              quote_literal(id_ent), filter)
    LOOP
      -- RAISE NOTICE '%', _d;

      IF _date_prev IS NOT NULL THEN
          _date_curr := _d.dtle;
          _dsecs := extract(epoch FROM _date_prev::time)::int;

          _maxlev := _d._maxlevel;
          _xy_r := json_build_object('x', _dsecs, 'y', _maxlev, 'id', id_ent);

          IF _maxlev >= ulim THEN
            _xy_err := array_append(_xy_err, _xy_r);

          ELSIF _maxlev >= llim AND _maxlev < ulim THEN
            _xy_wrn := array_append(_xy_wrn, _xy_r);

          ELSE
            _xy_ok := array_append(_xy_ok, _xy_r);

          END IF;

          -- RAISE NOTICE '%', _xy_r;
      END IF;

      _date_prev := _d.dtle;
    --
    END LOOP;
    -- RAISE NOTICE '_xy_err: %', _xy_err;
    -- RAISE NOTICE '_xy_wrn: %', _xy_wrn;
    -- RAISE NOTICE '_xy_ok: %', _xy_ok;

    _xy := json_build_object('error', _xy_err, 'warning',  _xy_wrn, 'ok', _xy_ok);
    return _xy;

  END;
  $$;


ALTER FUNCTION public.urbo_dumps_level_at_emptying(nschema text, ntable text, id_ent text, start text, finish text, tm_resol text, filter text, llim numeric, ulim numeric, iscarto boolean) OWNER TO postgres;

--
-- TOC entry 2457 (class 1255 OID 95379)
-- Name: urbo_dumps_replicate(text, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_dumps_replicate(_from text, _to text) RETURNS void
    LANGUAGE plpgsql
    AS $$
  DECLARE
    _q text;
    _r record;
  BEGIN

    _q := format('

      DELETE FROM %s.dumps_wastecontainer;
      insert into %s.dumps_wastecontainer select DISTINCT ON (id_entity, "TimeInstant") "TimeInstant", datelastemptying, fillinglevel, weight, temperature, methaneconcentration, id_entity, created_at, updated_at, id FROM  %s.dumps_wastecontainer;

      DELETE FROM %s.dumps_wastecontainermodel;
      insert into %s.dumps_wastecontainermodel select width, height, depth, volumestored, brandname, modelname, madeof, maximumload, id_entity, created_at, updated_at, id from %s.dumps_wastecontainermodel;

      DELETE FROM %s.dumps_indicators;
      insert into %s.dumps_indicators select * from %s.dumps_indicators;

      DELETE FROM %s.dumps_wastecontainer_lastdata;
      insert into %s.dumps_wastecontainer_lastdata select position, "TimeInstant", dateupdated, datelastemptying, datenextactuation,
        fillinglevel, weight, temperature, methaneconcentration, refwastecontainermodel, containerisle, isleid, serialnumber, category, storedwasteorigin,
        storedwastekind, status, areaserved, id_entity, created_at, updated_at, id from %s.dumps_wastecontainer_lastdata;

      DELETE FROM %s.dumps_wastecontainerisle;
      insert into %s.dumps_wastecontainerisle select name, description, address, areaserved, id_entity, created_at, updated_at, id from %s.dumps_wastecontainerisle;

      DELETE FROM %s.dumps_emptyings;
      insert into %s.dumps_emptyings select id_entity, dateemptying, fillinglevel from %s.dumps_emptyings;

    ',
    _to, _to, _from,
    _to, _to, _from,
    _to, _to, _from,
    _to, _to, _from,
    _to, _to, _from,
    _to, _to, _from
    );

    EXECUTE _q;

  END;
  $$;


ALTER FUNCTION public.urbo_dumps_replicate(_from text, _to text) OWNER TO postgres;

--
-- TOC entry 2458 (class 1255 OID 95380)
-- Name: urbo_dumps_replicate_carto(text, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_dumps_replicate_carto(_from text, _to text) RETURNS void
    LANGUAGE plpgsql
    AS $$
  DECLARE
    _q text;
    _r record;
  BEGIN

    _q := format('

      DELETE FROM %s_dumps_wastecontainer;
      insert into %s_dumps_wastecontainer select cartodb_id, the_geom, the_geom_webmercator, "TimeInstant",
        datelastemptying, fillinglevel, weight, temperature, methaneconcentration, id_entity  FROM  %s_dumps_wastecontainer;

      DELETE FROM %s_dumps_wastecontainermodel;
      insert into %s_dumps_wastecontainermodel select cartodb_id, the_geom, the_geom_webmercator, width, height, depth, volumestored, brandname, modelname, madeof, maximumload, id_entity, created_at, updated_at from %s_dumps_wastecontainermodel;

      DELETE FROM %s_dumps_fillingagg;
      insert into %s_dumps_fillingagg select * from %s_dumps_fillingagg;

      DELETE FROM %s_dumps_wastecontainer_lastdata;
      insert into %s_dumps_wastecontainer_lastdata select cartodb_id, the_geom, the_geom_webmercator, "TimeInstant", dateupdated, datelastemptying, datenextactuation,
        fillinglevel, weight, temperature, methaneconcentration, refwastecontainermodel, containerisle, isleid, serialnumber, category, storedwasteorigin,
        storedwastekind, status, areaserved, id_entity, created_at, updated_at from %s_dumps_wastecontainer_lastdata;

      DELETE FROM %s_dumps_wastecontainerisle;
      insert into %s_dumps_wastecontainerisle select cartodb_id, the_geom, the_geom_webmercator,
        name, description, address::jsonb, areaserved, id_entity, created_at, updated_at from %s_dumps_wastecontainerisle;

      DELETE FROM %s_dumps_emptyings;
      insert into %s_dumps_emptyings select id_entity, dateemptying, fillinglevel from %s_dumps_emptyings;

    ',
    _to, _to, _from,
    _to, _to, _from,
    _to, _to, _from,
    _to, _to, _from,
    _to, _to, _from,
    _to, _to, _from
    );

  EXECUTE _q;

  END;
  $$;


ALTER FUNCTION public.urbo_dumps_replicate_carto(_from text, _to text) OWNER TO postgres;

--
-- TOC entry 2410 (class 1255 OID 22987)
-- Name: urbo_dumps_stress_calculator(double precision[], integer, integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_dumps_stress_calculator(data double precision[], low integer, up integer) RETURNS double precision
    LANGUAGE plpgsql
    AS $$
    DECLARE
        d record;
        inrange double precision;
        total double precision;
        ret double precision;
    BEGIN
        inrange = 0;
        total = 0;
        FOR d in (SELECT unnest(data) as column)
        LOOP
            IF d.column >= low AND d.column <= up THEN
                inrange = inrange + 1;
            END IF;
            total = total + 1;
        END LOOP;

        IF total != 0 THEN
            ret = inrange / total;
        ELSE
            ret = 0;
        END IF;
        RETURN ret;
    END;
    $$;


ALTER FUNCTION public.urbo_dumps_stress_calculator(data double precision[], low integer, up integer) OWNER TO postgres;

--
-- TOC entry 2451 (class 1255 OID 95373)
-- Name: urbo_dumps_synthetic_calculator(double precision[], integer, integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_dumps_synthetic_calculator(data double precision[], low integer, up integer) RETURNS double precision
    LANGUAGE plpgsql
    AS $$
    DECLARE
        d record;
        total double precision;
        ret double precision;
        datas double precision[];
        adder double precision = 0;
    BEGIN

        total := (SELECT array_length(data, 1));

        FOR d in (SELECT unnest(data) as column)
        LOOP
            IF d.column >= low AND d.column <= up THEN
                NULL;
            ELSIF d.column < low THEN
                adder := adder - ((low - d.column)/low);
            ELSE
                adder := adder + (d.column - up)/(100 - up);
            END IF;
        END LOOP;

        IF total != 0 THEN
            ret := adder / total;
        ELSE
            ret = null;
        END IF;
        RETURN ret;
    END;
    $$;


ALTER FUNCTION public.urbo_dumps_synthetic_calculator(data double precision[], low integer, up integer) OWNER TO postgres;

--
-- TOC entry 2475 (class 1255 OID 95399)
-- Name: urbo_environment_append_day(json, boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_environment_append_day(data json, iscarto boolean DEFAULT false) RETURNS void
    LANGUAGE plpgsql
    AS $$
  DECLARE
    _table text;
    _q text;
  BEGIN
    _table = urbo_get_table_name(data->>'id_scope', 'environment_aqobserved_measurand_agg', iscarto);


    -- raise notice '%', data;
    _q = format('
        INSERT INTO %s
          (id_entity, "TimeInstant", ica, ica_co, ica_so2, ica_no2, ica_o3, ica_pm10, ica_pm2_5)
          VALUES
        (''%s'', ''%s'', ''%s'', ''%s'', ''%s'', ''%s'', ''%s'', ''%s'', ''%s'')',
          _table,
          data->>'id_entity', data->>'time', data->>'ica',
          data->>'ica_co', data->>'ica_so2', data->>'ica_no2',
          data->>'ica_o3', data->>'ica_pm10', data->>'ica_pm2_5');

    -- raise notice '%', _q;
    EXECUTE _q;

  END;
  $$;


ALTER FUNCTION public.urbo_environment_append_day(data json, iscarto boolean) OWNER TO postgres;

--
-- TOC entry 2460 (class 1255 OID 95384)
-- Name: urbo_environment_co(text, text, timestamp without time zone, timestamp without time zone, boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_environment_co(id_scope text, id_entity text, start timestamp without time zone, finish timestamp without time zone, iscarto boolean DEFAULT false) RETURNS text
    LANGUAGE plpgsql
    AS $$
  DECLARE
    _r numeric;
  BEGIN

    _r := (SELECT urbo_threshold_calculation(id_scope,
        'environment_airqualityobserved_measurand', 'co',
        id_entity, start::timestamp, finish::timestamp, '8h'::interval, iscarto));

    -- raise notice '%', _r;
    IF _r >= 15 THEN
      RETURN 'very bad';
    ELSIF _r >= 10 AND _r < 15 THEN
      RETURN 'bad';
    ELSIF _r >= 6 AND _r < 10 THEN
      RETURN 'defficient';
    ELSIF _r >= 3 AND _r < 6 THEN
      RETURN 'admisible';
    ELSIF _r >= 0 AND _r < 3 THEN
      RETURN 'good';
    ELSE
      RETURN '--';
    END IF;

  END;

$$;


ALTER FUNCTION public.urbo_environment_co(id_scope text, id_entity text, start timestamp without time zone, finish timestamp without time zone, iscarto boolean) OWNER TO postgres;

--
-- TOC entry 2467 (class 1255 OID 95391)
-- Name: urbo_environment_co_now(text, text, boolean, timestamp without time zone); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_environment_co_now(text, text, boolean DEFAULT false, timestamp without time zone DEFAULT now()) RETURNS text
    LANGUAGE sql
    AS $_$
    SELECT urbo_environment_co($1, $2, ($4-'8h'::interval)::timestamp, $4::timestamp, $3);
$_$;


ALTER FUNCTION public.urbo_environment_co_now(text, text, boolean, timestamp without time zone) OWNER TO postgres;

--
-- TOC entry 2476 (class 1255 OID 95400)
-- Name: urbo_environment_daily_agg(text, text, timestamp without time zone, timestamp without time zone, boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_environment_daily_agg(id_scope text, id_entity text, _start timestamp without time zone, _finish timestamp without time zone, iscarto boolean DEFAULT false) RETURNS SETOF jsonb
    LANGUAGE plpgsql
    AS $$
  DECLARE
    d record;
    _q text;
    _table text;
    _table_last text;
  BEGIN

    _table = urbo_get_table_name(id_scope, 'environment_airqualityobserved_measurand', iscarto);
    _table_last = urbo_get_table_name(id_scope, 'environment_airqualityobserved', iscarto);

    _q := format('
      SELECT
        start as "TimeInstant",
        ''%s'' AS id_scope,
        id_entity,
        urbo_environment_historic(''%s'', ''%s'', start, start+''1day''::interval, ''%s'') as ica,
        urbo_environment_o3(''%s'', ''%s'', start, start+''1day''::interval, ''%s'') as ica_o3,
        urbo_environment_co(''%s'', ''%s'', start, start+''1day''::interval, ''%s'') as ica_co,
        urbo_environment_so2(''%s'', ''%s'', start, start+''1day''::interval, ''%s'') as ica_so2,
        urbo_environment_no2(''%s'', ''%s'', start, start+''1day''::interval, ''%s'') as ica_no2,
        urbo_environment_pm10(''%s'', ''%s'', start, start+''1day''::interval, ''%s'') as ica_pm10,
        urbo_environment_pm2_5(''%s'', ''%s'', start, start+''1day''::interval, ''%s'') as ica_pm2_5
      FROM
      (
        SELECT DISTINCT ts.start, d.id_entity
        FROM %s d
        JOIN (
          SELECT generate_series(
            date_trunc(''minute'', ''%s''::timestamp),
            (date_trunc(''minute'', ''%s''::timestamp) - ''1s''::interval)::timestamp,
            ''1d''::interval) as start
        ) as ts
        ON d."TimeInstant" >= ts.start AND d."TimeInstant" < (ts.start + ''1d''::interval)
        WHERE id_entity=''%s''
        ORDER BY ts.start, d.id_entity
      ) as t
      ORDER BY id_entity, start',
        id_scope,
        id_scope, id_entity, iscarto,
        id_scope, id_entity, iscarto,
        id_scope, id_entity, iscarto,
        id_scope, id_entity, iscarto,
        id_scope, id_entity, iscarto,
        id_scope, id_entity, iscarto,
        id_scope, id_entity, iscarto,
        _table, _start, _finish, id_entity);



    -- raise notice '%', _q;


    FOR d IN EXECUTE _q LOOP
      RETURN NEXT json_build_object(
        'id_scope', d.id_scope,
        'id_entity', d.id_entity,
        'time', d."TimeInstant",
        'ica', d.ica,
        'ica_o3', d.ica_o3,
        'ica_co', d.ica_co,
        'ica_so2', d.ica_so2,
        'ica_no2', d.ica_no2,
        'ica_pm10', d.ica_pm10,
        'ica_pm2_5', d.ica_pm2_5
        );
    END LOOP;


  END;
  $$;


ALTER FUNCTION public.urbo_environment_daily_agg(id_scope text, id_entity text, _start timestamp without time zone, _finish timestamp without time zone, iscarto boolean) OWNER TO postgres;

--
-- TOC entry 2474 (class 1255 OID 95398)
-- Name: urbo_environment_daily_agg_redo(text, text, boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_environment_daily_agg_redo(start text, id_scope text, iscarto boolean DEFAULT false) RETURNS void
    LANGUAGE plpgsql
    AS $$
  DECLARE
    _table text;
    _q text;
  BEGIN
    _table = urbo_get_table_name(id_scope, 'environment_aqobserved_measurand_agg', iscarto);

    _q = format('
      WITH gs AS (SELECT generate_series::text AS time
        FROM generate_series(''%s''::timestamp + ''1h''::interval, ''%s''::timestamp + ''24h''::interval, ''1h''::interval)
      )
      INSERT INTO %s (id_entity, "TimeInstant", ica, ica_co, ica_so2, ica_no2, ica_o3, ica_pm10, ica_pm2_5)
      SELECT id_entity, ''%s''::timestamp AS time,
          CASE WHEN ''very bad'' = ANY(array_agg(aqi)) THEN ''very bad''
            WHEN ''bad'' = ANY(array_agg(aqi)) THEN ''bad''
            WHEN ''defficient'' = ANY(array_agg(aqi)) THEN ''defficient''
            WHEN ''admisible'' = ANY(array_agg(aqi)) THEN ''admisible''
            WHEN ''good'' = ANY(array_agg(aqi)) THEN ''good''
            ELSE ''--'' END AS aqi,
          CASE WHEN ''very bad'' = ANY(array_agg(co)) THEN ''very bad''
            WHEN ''bad'' = ANY(array_agg(co)) THEN ''bad''
            WHEN ''defficient'' = ANY(array_agg(co)) THEN ''defficient''
            WHEN ''admisible'' = ANY(array_agg(co)) THEN ''admisible''
            WHEN ''good'' = ANY(array_agg(co)) THEN ''good''
            ELSE ''--'' END AS co,
          CASE WHEN ''very bad'' = ANY(array_agg(so2)) THEN ''very bad''
            WHEN ''bad'' = ANY(array_agg(so2)) THEN ''bad''
            WHEN ''defficient'' = ANY(array_agg(so2)) THEN ''defficient''
            WHEN ''admisible'' = ANY(array_agg(so2)) THEN ''admisible''
            WHEN ''good'' = ANY(array_agg(so2)) THEN ''good''
            ELSE ''--'' END AS so2,
          CASE WHEN ''very bad'' = ANY(array_agg(no2)) THEN ''very bad''
            WHEN ''bad'' = ANY(array_agg(no2)) THEN ''bad''
            WHEN ''defficient'' = ANY(array_agg(no2)) THEN ''defficient''
            WHEN ''admisible'' = ANY(array_agg(no2)) THEN ''admisible''
            WHEN ''good'' = ANY(array_agg(no2)) THEN ''good''
            ELSE ''--'' END AS no2,
          CASE WHEN ''very bad'' = ANY(array_agg(o3)) THEN ''very bad''
            WHEN ''bad'' = ANY(array_agg(o3)) THEN ''bad''
            WHEN ''defficient'' = ANY(array_agg(o3)) THEN ''defficient''
            WHEN ''admisible'' = ANY(array_agg(o3)) THEN ''admisible''
            WHEN ''good'' = ANY(array_agg(o3)) THEN ''good''
            ELSE ''--'' END AS o3,
          CASE WHEN ''very bad'' = ANY(array_agg(pm10)) THEN ''very bad''
            WHEN ''bad'' = ANY(array_agg(pm10)) THEN ''bad''
            WHEN ''defficient'' = ANY(array_agg(pm10)) THEN ''defficient''
            WHEN ''admisible'' = ANY(array_agg(pm10)) THEN ''admisible''
            WHEN ''good'' = ANY(array_agg(pm10)) THEN ''good''
            ELSE ''--'' END AS pm10,
          CASE WHEN ''very bad'' = ANY(array_agg(pm2_5)) THEN ''very bad''
            WHEN ''bad'' = ANY(array_agg(pm2_5)) THEN ''bad''
            WHEN ''defficient'' = ANY(array_agg(pm2_5)) THEN ''defficient''
            WHEN ''admisible'' = ANY(array_agg(pm2_5)) THEN ''admisible''
            WHEN ''good'' = ANY(array_agg(pm2_5)) THEN ''good''
            ELSE ''--'' END AS pm2_5
        FROM (
          SELECT id_entity, time::timestamp without time zone,
              CASE WHEN ''very bad'' = ANY(ARRAY[co, so2, no2, o3, pm10, pm2_5]) THEN ''very bad''
                WHEN ''bad'' = ANY(ARRAY[co, so2, no2, o3, pm10, pm2_5]) THEN ''bad''
                WHEN ''defficient'' = ANY(ARRAY[co, so2, no2, o3, pm10, pm2_5]) THEN ''defficient''
                WHEN ''admisible'' = ANY(ARRAY[co, so2, no2, o3, pm10, pm2_5]) THEN ''admisible''
                WHEN ''good'' = ANY(ARRAY[co, so2, no2, o3, pm10, pm2_5]) THEN ''good''
                ELSE ''--'' END AS aqi,
              co, so2, no2, o3, pm10, pm2_5
            FROM gs, urbo_environment_now_all(''%s''::text, true, true, gs.time)
        ) q
        GROUP BY id_entity',
      start, start, _table, start, id_scope);

    EXECUTE _q;

  END;
  $$;


ALTER FUNCTION public.urbo_environment_daily_agg_redo(start text, id_scope text, iscarto boolean) OWNER TO postgres;

--
-- TOC entry 2466 (class 1255 OID 95390)
-- Name: urbo_environment_historic(text, text, timestamp without time zone, timestamp without time zone, boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_environment_historic(id_scope text, id_entity text, start timestamp without time zone, finish timestamp without time zone, iscarto boolean DEFAULT false) RETURNS text
    LANGUAGE plpgsql
    AS $$
  DECLARE
    _r text;
    _all text[];
  BEGIN

    -- 6 measures
    _r := (SELECT urbo_environment_no2(id_scope, id_entity, start, finish, iscarto));
    IF _r::text='very bad' THEN
        RETURN 'very bad';
    END IF;
    _all := (SELECT array_append(_all, _r::text));

    _r := (SELECT urbo_environment_co(id_scope, id_entity, start::timestamp, finish::timestamp, iscarto));
    IF _r::text='very bad' THEN
        RETURN 'very bad';
    END IF;
    _all := (SELECT array_append(_all, _r::text));

    _r := (SELECT urbo_environment_so2(id_scope, id_entity, start, finish, iscarto));
    IF _r::text='very bad' THEN
        RETURN 'very bad';
    END IF;
    _all := (SELECT array_append(_all, _r::text));

    _r := (SELECT urbo_environment_o3(id_scope, id_entity, start, finish, iscarto));
    IF _r::text='very bad' THEN
        RETURN 'very bad';
    END IF;
    _all := (SELECT array_append(_all, _r::text));

    _r := (SELECT urbo_environment_pm10(id_scope, id_entity, start::timestamp, finish::timestamp, iscarto));
    IF _r::text='very bad' THEN
        RETURN 'very bad';
    END IF;
    _all := (SELECT array_append(_all, _r::text));

    _r := (SELECT urbo_environment_pm2_5(id_scope, id_entity, start::timestamp, finish::timestamp, iscarto));
    IF _r::text='very bad' THEN
        RETURN 'very bad';
    END IF;
    _all := (SELECT array_append(_all, _r::text));

    -- raise notice '%', _all;

    IF 'very bad' = ANY(_all) THEN
        RETURN 'very bad';
    ELSIF 'bad' = ANY(_all) THEN
        RETURN 'bad';
    ELSIF 'defficient' = ANY(_all) THEN
        RETURN 'defficient';
    ELSIF 'admisible' = ANY(_all) THEN
        RETURN 'admisible';
    ELSIF 'good' = ANY(_all) THEN
        RETURN 'good';
    ELSE
        RETURN '--';
    END IF;



  END;

$$;


ALTER FUNCTION public.urbo_environment_historic(id_scope text, id_entity text, start timestamp without time zone, finish timestamp without time zone, iscarto boolean) OWNER TO postgres;

--
-- TOC entry 2477 (class 1255 OID 95401)
-- Name: urbo_environment_ica_redux(character varying[]); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_environment_ica_redux(_all character varying[]) RETURNS character varying
    LANGUAGE plpgsql
    AS $$
DECLARE
BEGIN
    IF 'very bad' = ANY(_all) THEN
        RETURN 'very bad';
    ELSIF 'bad' = ANY(_all) THEN
        RETURN 'bad';
    ELSIF 'defficient' = ANY(_all) THEN
        RETURN 'defficient';
    ELSIF 'admisible' = ANY(_all) THEN
        RETURN 'admisible';
    ELSIF 'good' = ANY(_all) THEN
        RETURN 'good';
    ELSE
        RETURN '--';
    END IF;
END;
$$;


ALTER FUNCTION public.urbo_environment_ica_redux(_all character varying[]) OWNER TO postgres;

--
-- TOC entry 2461 (class 1255 OID 95385)
-- Name: urbo_environment_no2(text, text, timestamp without time zone, timestamp without time zone, boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_environment_no2(id_scope text, id_entity text, start timestamp without time zone, finish timestamp without time zone, iscarto boolean DEFAULT false) RETURNS text
    LANGUAGE plpgsql
    AS $$
  DECLARE
    _r boolean;
    _value3h numeric;
    _value numeric;
  BEGIN

    -- Worst case checks first
    _value3h := (SELECT urbo_threshold_calculation(id_scope,
        'environment_airqualityobserved_measurand', 'no2',
        id_entity, start::timestamp, finish::timestamp, '3h'::interval, iscarto));


    IF _value3h >= 400 THEN
        RETURN 'very bad';
    ELSE
        _value := (SELECT urbo_threshold_calculation(id_scope,
            'environment_airqualityobserved_measurand', 'no2',
            id_entity, start::timestamp, finish::timestamp, '1h'::interval, iscarto));

        IF _value >= 200 THEN
            RETURN 'bad';
        ELSIF _value >= 80 AND _value < 200 THEN
            RETURN 'defficient';
        ELSIF _value >= 40 AND _value < 80 THEN
            RETURN 'admisible';
        ELSIF _value >= 0 AND _value < 40 THEN
            RETURN 'good';
        ELSE
            RETURN '--';
        END IF;
    END IF;

  END;

$$;


ALTER FUNCTION public.urbo_environment_no2(id_scope text, id_entity text, start timestamp without time zone, finish timestamp without time zone, iscarto boolean) OWNER TO postgres;

--
-- TOC entry 2468 (class 1255 OID 95392)
-- Name: urbo_environment_no2_now(text, text, boolean, timestamp without time zone); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_environment_no2_now(id_scope text, id_entity text, iscarto boolean DEFAULT false, _when timestamp without time zone DEFAULT now()) RETURNS text
    LANGUAGE plpgsql
    AS $$
  DECLARE
    _r boolean;
    _value3h numeric;
    _value numeric;

  BEGIN

    -- Very bad

    -- Worst case checks first
    _value3h := (SELECT urbo_threshold_calculation(id_scope,
        'environment_airqualityobserved_measurand', 'no2',
        id_entity, (_when-'3 hour'::interval)::timestamp, _when::timestamp, '3h'::interval, iscarto));


    IF _value3h >= 400 THEN
        RETURN 'very bad';
    ELSE

        _value := (SELECT urbo_threshold_calculation(id_scope,
            'environment_airqualityobserved_measurand', 'no2',
            id_entity, (_when-'1 hour'::interval)::timestamp, _when::timestamp, '1h'::interval, iscarto));

        IF _value >= 200 THEN
            RETURN 'bad';
        ELSIF _value >= 80 AND _value < 200 THEN
            RETURN 'defficient';
        ELSIF _value >= 40 AND _value < 80 THEN
            RETURN 'admisible';
        ELSIF _value >= 0 AND _value < 40 THEN
            RETURN 'good';
        ELSE
            RETURN '--';
        END IF;
    END IF;


  END;

$$;


ALTER FUNCTION public.urbo_environment_no2_now(id_scope text, id_entity text, iscarto boolean, _when timestamp without time zone) OWNER TO postgres;

--
-- TOC entry 2473 (class 1255 OID 95397)
-- Name: urbo_environment_now(text, text, boolean, timestamp without time zone); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_environment_now(id_scope text, id_entity text, iscarto boolean DEFAULT false, _when timestamp without time zone DEFAULT now()) RETURNS text
    LANGUAGE plpgsql
    AS $$
  DECLARE
    _r text;
    _all text[];
  BEGIN

    -- 6 measures
    _r := (SELECT urbo_environment_no2_now(id_scope, id_entity, iscarto, _when));
    IF _r::text='very bad' THEN
        RETURN 'very bad';
    END IF;
    _all := (SELECT array_append(_all, _r::text));

    _r := (SELECT urbo_environment_co_now(id_scope, id_entity, iscarto, _when));
    IF _r::text='very bad' THEN
        RETURN 'very bad';
    END IF;
    _all := (SELECT array_append(_all, _r::text));

    _r := (SELECT urbo_environment_so2_now(id_scope, id_entity,iscarto, _when));
    IF _r::text='very bad' THEN
        RETURN 'very bad';
    END IF;
    _all := (SELECT array_append(_all, _r::text));

    _r := (SELECT urbo_environment_o3_now(id_scope, id_entity, iscarto, _when));
    IF _r::text='very bad' THEN
        RETURN 'very bad';
    END IF;
    _all := (SELECT array_append(_all, _r::text));

    _r := (SELECT urbo_environment_pm10_now(id_scope, id_entity, iscarto, _when));
    IF _r::text='very bad' THEN
        RETURN 'very bad';
    END IF;
    _all := (SELECT array_append(_all, _r::text));

    _r := (SELECT urbo_environment_pm2_5_now(id_scope, id_entity, iscarto, _when));
    IF _r::text='very bad' THEN
        RETURN 'very bad';
    END IF;
    _all := (SELECT array_append(_all, _r::text));

    -- raise notice '%', _all;

    IF 'very bad' = ANY(_all) THEN
        RETURN 'very bad';
    ELSIF 'bad' = ANY(_all) THEN
        RETURN 'bad';
    ELSIF 'defficient' = ANY(_all) THEN
        RETURN 'defficient';
    ELSIF 'admisible' = ANY(_all) THEN
        RETURN 'admisible';
    ELSIF 'good' = ANY(_all) THEN
        RETURN 'good';
    ELSE
        RETURN '--';
    END IF;



  END;

$$;


ALTER FUNCTION public.urbo_environment_now(id_scope text, id_entity text, iscarto boolean, _when timestamp without time zone) OWNER TO postgres;

--
-- TOC entry 2481 (class 1255 OID 95405)
-- Name: urbo_environment_now_all(text, boolean, boolean, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_environment_now_all(id_scope text, iscarto boolean DEFAULT false, use_time boolean DEFAULT false, use_this_time text DEFAULT now()) RETURNS TABLE(id_entity text, no2 text, co text, o3 text, pm10 text, pm2_5 text, so2 text)
    LANGUAGE plpgsql
    AS $$
  DECLARE
    _table text;
    _tablelast text;
    _time text := '';
  BEGIN
    _table := urbo_get_table_name(id_scope, 'environment_airqualityobserved_measurand', iscarto);
    _tablelast := urbo_get_table_name(id_scope, 'environment_airqualityobserved_lastdata', iscarto);

    IF use_time THEN
      _time := format('''%s''::timestamp without time zone AS ', use_this_time);
    END IF;

    RETURN QUERY EXECUTE format('
      WITH lastdata AS (
        SELECT id_entity, %s"TimeInstant" FROM %s
      )

      SELECT twenty_four.id_entity::text AS id_entity,

        (CASE WHEN no2_3 >= 400 THEN ''very bad''
          WHEN no2_1 >= 200 THEN ''bad''
          WHEN no2_1 >= 80 AND no2_1 < 200 THEN ''defficient''
          WHEN no2_1 >= 40 AND no2_1 < 80 THEN ''admisible''
          WHEN no2_1 >= 0 AND no2_1 < 40 THEN ''good''
          ELSE ''--'' END)::text AS no2,

        (CASE WHEN co_8 >= 15 THEN ''very bad''
          WHEN co_8 >= 10 AND co_8 < 15 THEN ''bad''
          WHEN co_8 >= 6 AND co_8 < 10 THEN ''defficient''
          WHEN co_8 >= 3 AND co_8 < 6 THEN ''admisible''
          WHEN co_8 >= 0 AND co_8 < 3 THEN ''good''
          ELSE ''--'' END)::text AS co,

        (CASE WHEN o3_1 >= 240 OR o3_8 >= 180 THEN ''very bad''
          WHEN (o3_1 >= 180 AND o3_1 < 240) OR (o3_8 >= 120 AND o3_8 < 180) THEN ''bad''
          WHEN (o3_1 >= 120 AND o3_1 < 180) OR (o3_8 >= 80 AND o3_8 < 120) THEN ''defficient''
          WHEN (o3_1 >= 80 AND o3_1 < 120) OR (o3_8 >= 60 AND o3_8 < 80) THEN ''admisible''
          WHEN (o3_1 >= 0 AND o3_1 < 80) OR (o3_8 >= 0 AND o3_8 < 60) THEN ''good''
          ELSE ''--'' END)::text AS o3,

        (CASE WHEN pm10_24 >= 75 THEN ''very bad''
          WHEN pm10_24 >= 50 AND pm10_24 < 75 THEN ''bad''
          WHEN pm10_24 >= 40 AND pm10_24 < 50 THEN ''defficient''
          WHEN pm10_24 >= 25 AND pm10_24 < 40 THEN ''admisible''
          WHEN pm10_24 >= 0 AND pm10_24 < 25 THEN ''good''
          ELSE ''--'' END)::text AS pm10,

        (CASE WHEN pm2_5_24 >= 60 THEN ''very bad''
          WHEN pm2_5_24 >= 40 AND pm2_5_24 < 60 THEN ''bad''
          WHEN pm2_5_24 >= 25 AND pm2_5_24 < 40 THEN ''defficient''
          WHEN pm2_5_24 >= 15 AND pm2_5_24 < 25 THEN ''admisible''
          WHEN pm2_5_24 >= 0 AND pm2_5_24 < 15 THEN ''good''
          ELSE ''--'' END)::text AS pm2_5,

        (CASE WHEN so2_3 >= 500 OR so2_24 >= 200 THEN ''very bad''
          WHEN so2_1 >= 350 OR (so2_24 >= 125 AND so2_24 < 200) THEN ''bad''
          WHEN (so2_1 >= 125 AND so2_1 < 350) OR (so2_24 >= 90 AND so2_24 < 125) THEN ''defficient''
          WHEN (so2_1 >= 70 AND so2_1 < 125) OR (so2_24 >= 50 AND so2_24 < 90) THEN ''admisible''
          WHEN (so2_1 >= 0 AND so2_1 < 70) OR (so2_24 >= 0 AND so2_24 < 50) THEN ''good''
          ELSE ''--'' END)::text AS so2

        FROM (
          SELECT avg(am.no2) AS no2_24, avg(am.co) AS co_24, avg(am.o3) AS o3_24, avg(am.pm10) AS pm10_24, avg(am.pm2_5) AS pm2_5_24, avg(am.so2) AS so2_24, am.id_entity
            FROM %s am
            INNER JOIN lastdata ld
            ON am.id_entity = ld.id_entity
            WHERE am."TimeInstant" >= ld."TimeInstant" - ''24h''::interval
            GROUP BY am.id_entity ) twenty_four

        INNER JOIN (
          SELECT avg(am.no2) AS no2_8, avg(am.co) AS co_8, avg(am.o3) AS o3_8, avg(am.pm10) AS pm10_8, avg(am.pm2_5) AS pm2_5_8, avg(am.so2) AS so2_8, am.id_entity
            FROM %s am
            INNER JOIN lastdata ld
            ON am.id_entity = ld.id_entity
            WHERE am."TimeInstant" >= ld."TimeInstant" - ''8h''::interval
            GROUP BY am.id_entity ) eight

        ON twenty_four.id_entity = eight.id_entity

        INNER JOIN (
          SELECT avg(am.no2) AS no2_3, avg(am.co) AS co_3, avg(am.o3) AS o3_3, avg(am.pm10) AS pm10_3, avg(am.pm2_5) AS pm2_5_3, avg(am.so2) AS so2_3, am.id_entity
            FROM %s am
            INNER JOIN lastdata ld
            ON am.id_entity = ld.id_entity
            WHERE am."TimeInstant" >= ld."TimeInstant" - ''3h''::interval
            GROUP BY am.id_entity ) three

        ON eight.id_entity = three.id_entity

        INNER JOIN (
          SELECT avg(am.no2) AS no2_1, avg(am.co) AS co_1, avg(am.o3) AS o3_1, avg(am.pm10) AS pm10_1, avg(am.pm2_5) AS pm2_5_1, avg(am.so2) AS so2_1, am.id_entity
            FROM %s am
            INNER JOIN lastdata ld
            ON am.id_entity = ld.id_entity
            WHERE am."TimeInstant" >= ld."TimeInstant" - ''1h''::interval
            GROUP BY am.id_entity ) one

        ON three.id_entity = one.id_entity',
      _time, _tablelast, _table, _table, _table, _table);

  END;

$$;


ALTER FUNCTION public.urbo_environment_now_all(id_scope text, iscarto boolean, use_time boolean, use_this_time text) OWNER TO postgres;

--
-- TOC entry 2462 (class 1255 OID 95386)
-- Name: urbo_environment_o3(text, text, timestamp without time zone, timestamp without time zone, boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_environment_o3(id_scope text, id_entity text, start timestamp without time zone, finish timestamp without time zone, iscarto boolean DEFAULT false) RETURNS text
    LANGUAGE plpgsql
    AS $$
  DECLARE
    _r boolean;
    _value1h numeric;
    _value8h numeric;
  BEGIN

    _value1h = (SELECT urbo_threshold_calculation(id_scope,
        'environment_airqualityobserved_measurand', 'o3',
        id_entity,start::timestamp, finish::timestamp, '1h'::interval, iscarto));

    _value8h := (SELECT urbo_threshold_calculation(id_scope,
        'environment_airqualityobserved_measurand', 'o3',
        id_entity,start::timestamp, finish::timestamp, '8h'::interval, iscarto));


    IF _value1h >= 240 OR _value8h >= 180 THEN
        RETURN 'very bad';
    ELSIF (_value1h>=180 AND _value1h<240) OR (_value8h>=120 AND _value8h>180) THEN
        RETURN 'bad';
    ELSIF (_value1h>=120 AND _value1h<180) OR (_value8h>=80 AND _value8h>120) THEN
        RETURN 'defficient';
    ELSIF (_value1h>=80 AND _value1h<120) OR (_value8h>=60 AND _value8h>80) THEN
        RETURN 'admisible';
    ELSIF (_value1h>=0 AND _value1h<80) OR (_value8h>=0 AND _value8h>60) THEN
        RETURN 'good';
    ELSE
        RETURN '--';
    END IF;

  END;

$$;


ALTER FUNCTION public.urbo_environment_o3(id_scope text, id_entity text, start timestamp without time zone, finish timestamp without time zone, iscarto boolean) OWNER TO postgres;

--
-- TOC entry 2469 (class 1255 OID 95393)
-- Name: urbo_environment_o3_now(text, text, boolean, timestamp without time zone); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_environment_o3_now(id_scope text, id_entity text, iscarto boolean DEFAULT false, _when timestamp without time zone DEFAULT now()) RETURNS text
    LANGUAGE plpgsql
    AS $$
  DECLARE
    _r boolean;
    _value1h numeric;
    _value8h numeric;
  BEGIN

    _value1h = (SELECT urbo_threshold_calculation(id_scope,
        'environment_airqualityobserved_measurand', 'o3',
        id_entity,(_when-'1 hour'::interval)::timestamp, _when::timestamp, '1h'::interval, iscarto));

    _value8h := (SELECT urbo_threshold_calculation(id_scope,
        'environment_airqualityobserved_measurand', 'o3',
        id_entity,(_when-'8 hour'::interval)::timestamp, _when::timestamp, '8h'::interval, iscarto));


    IF _value1h >= 240 OR _value8h >= 180 THEN
        RETURN 'very bad';
    ELSIF (_value1h>=180 AND _value1h<240) OR (_value8h>=120 AND _value8h>180) THEN
        RETURN 'bad';
    ELSIF (_value1h>=120 AND _value1h<180) OR (_value8h>=80 AND _value8h>120) THEN
        RETURN 'defficient';
    ELSIF (_value1h>=80 AND _value1h<120) OR (_value8h>=60 AND _value8h>80) THEN
        RETURN 'admisible';
    ELSIF (_value1h>=0 AND _value1h<80) OR (_value8h>=0 AND _value8h>60) THEN
        RETURN 'good';
    ELSE
        RETURN '--';
    END IF;


  END;

$$;


ALTER FUNCTION public.urbo_environment_o3_now(id_scope text, id_entity text, iscarto boolean, _when timestamp without time zone) OWNER TO postgres;

--
-- TOC entry 2463 (class 1255 OID 95387)
-- Name: urbo_environment_pm10(text, text, timestamp without time zone, timestamp without time zone, boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_environment_pm10(id_scope text, id_entity text, start timestamp without time zone, finish timestamp without time zone, iscarto boolean DEFAULT false) RETURNS text
    LANGUAGE plpgsql
    AS $$
  DECLARE
    _r boolean;
    _value24h numeric;
  BEGIN

    _value24h := (SELECT urbo_threshold_calculation(id_scope,
        'environment_airqualityobserved_measurand', 'pm10',
        id_entity, start::timestamp, finish::timestamp, '24h'::interval, iscarto));


    IF _value24h >= 75 THEN
        RETURN 'very bad';
    ELSIF _value24h >= 50 AND _value24h < 75 THEN
        RETURN 'bad';
    ELSIF _value24h >= 40 AND _value24h < 50 THEN
        RETURN 'defficient';
    ELSIF _value24h >=25 AND _value24h < 40 THEN
        RETURN 'admisible';
    ELSIF _value24h >= 0 AND _value24h < 25 THEN
        RETURN 'good';
    ELSE
        RETURN '--';
    END IF;


  END;

$$;


ALTER FUNCTION public.urbo_environment_pm10(id_scope text, id_entity text, start timestamp without time zone, finish timestamp without time zone, iscarto boolean) OWNER TO postgres;

--
-- TOC entry 2470 (class 1255 OID 95394)
-- Name: urbo_environment_pm10_now(text, text, boolean, timestamp without time zone); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_environment_pm10_now(text, text, boolean DEFAULT false, timestamp without time zone DEFAULT now()) RETURNS text
    LANGUAGE sql
    AS $_$
    SELECT urbo_environment_pm10($1, $2, ($4-'24h'::interval)::timestamp, $4::timestamp, $3);
$_$;


ALTER FUNCTION public.urbo_environment_pm10_now(text, text, boolean, timestamp without time zone) OWNER TO postgres;

--
-- TOC entry 2464 (class 1255 OID 95388)
-- Name: urbo_environment_pm2_5(text, text, timestamp without time zone, timestamp without time zone, boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_environment_pm2_5(id_scope text, id_entity text, start timestamp without time zone, finish timestamp without time zone, iscarto boolean DEFAULT false) RETURNS text
    LANGUAGE plpgsql
    AS $$
  DECLARE
    _r boolean;
    _q text;
    _value24h numeric;
  BEGIN

    -- _q := format('SELECT urbo_threshold_calculation(''%s'',
    --     ''environment_airqualityobserved_measurand'', ''pm2_5'',
    --     ''%s'', ''%s''::timestamp, ''%s''::timestamp, ''24h''::interval, ''%s'')',
    --     id_scope, id_entity, start, finish, iscarto);
    -- raise notice '%', _q;

    _value24h := (SELECT urbo_threshold_calculation(id_scope,
        'environment_airqualityobserved_measurand', 'pm2_5',
        id_entity, start::timestamp, finish::timestamp, '24h'::interval, iscarto));

    IF _value24h >= 60 THEN
        RETURN 'very bad';
    ELSIF _value24h >= 40 AND _value24h < 60 THEN
        RETURN 'bad';
    ELSIF _value24h >= 25 AND _value24h < 40 THEN
        RETURN 'defficient';
    ELSIF _value24h >= 15 AND _value24h < 25 THEN
        RETURN 'admisible';
    ELSIF _value24h >= 0 AND _value24h < 15 THEN
        RETURN 'good';
    ELSE
        RETURN '--';
    END IF;


  END;

$$;


ALTER FUNCTION public.urbo_environment_pm2_5(id_scope text, id_entity text, start timestamp without time zone, finish timestamp without time zone, iscarto boolean) OWNER TO postgres;

--
-- TOC entry 2471 (class 1255 OID 95395)
-- Name: urbo_environment_pm2_5_now(text, text, boolean, timestamp without time zone); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_environment_pm2_5_now(text, text, boolean DEFAULT false, timestamp without time zone DEFAULT now()) RETURNS text
    LANGUAGE sql
    AS $_$
    SELECT urbo_environment_pm2_5($1, $2, ($4-'24h'::interval)::timestamp, $4::timestamp, $3);
$_$;


ALTER FUNCTION public.urbo_environment_pm2_5_now(text, text, boolean, timestamp without time zone) OWNER TO postgres;

--
-- TOC entry 2479 (class 1255 OID 95403)
-- Name: urbo_environment_replicate(text, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_environment_replicate(_from text, _to text) RETURNS void
    LANGUAGE plpgsql
    AS $$
  DECLARE
    _q text;
    _r record;
  BEGIN

    -- AIR QUALITY
    _q := format('

      DELETE FROM %s.environment_airqualityobserved;
      INSERT INTO %s.environment_airqualityobserved
      SELECT DISTINCT ON (id_entity, "TimeInstant")
        position,
        "TimeInstant",
        source,
        refpointofinterest,
        address,
        id_entity,
        created_at,
        updated_at,
        id
      FROM  %s.environment_airqualityobserved;

      DELETE FROM %s.environment_airqualityobserved_lastdata;
      INSERT INTO %s.environment_airqualityobserved_lastdata
      SELECT DISTINCT ON (id_entity, "TimeInstant")
        position,
        "TimeInstant",
        source,
        refpointofinterest,
        so2,
        no2,
        pm10,
        pm2_5,
        co,
        o3,
        id_entity,
        created_at,
        updated_at,
        id
      FROM  %s.environment_airqualityobserved_lastdata;


      DELETE FROM %s.environment_airqualityobserved_measurand;
      INSERT INTO %s.environment_airqualityobserved_measurand
      SELECT DISTINCT ON (id_entity, "TimeInstant")
        "TimeInstant",
        so2,
        no2,
        pm10,
        pm2_5,
        co,
        o3,
        id_entity,
        created_at,
        updated_at,
        id
      FROM  %s.environment_airqualityobserved_measurand;
    ',
    _to, _to, _from,
    _to, _to, _from,
    _to, _to, _from
    );

    EXECUTE _q;


    -- NOISE
    _q := format('

      DELETE FROM %s.environment_noiseobserved;
      INSERT INTO %s.environment_noiseobserved
      SELECT DISTINCT ON (id_entity, "TimeInstant")
        position,
        "TimeInstant",
        source,
        dataprovider,
        refpointofinterest,
        address,
        id_entity,
        created_at,
        updated_at,
        id
      FROM  %s.environment_noiseobserved;

      DELETE FROM %s.environment_noiseobserved_lastdata;
      INSERT INTO %s.environment_noiseobserved_lastdata
      SELECT DISTINCT ON (id_entity, "TimeInstant")
        position,
        "TimeInstant",
        source,
        dataprovider,
        refpointofinterest,
        instantsoundlevel,
        id_entity,
        created_at,
        updated_at,
        id
      FROM  %s.environment_noiseobserved_lastdata;


      DELETE FROM %s.environment_noiseobserved_instantlevel;
      INSERT INTO %s.environment_noiseobserved_instantlevel
      SELECT DISTINCT ON (id_entity, "TimeInstant")
        "TimeInstant",
        instantsoundlevel,
        id_entity,
        created_at,
        updated_at,
        id
      FROM  %s.environment_noiseobserved_instantlevel;
    ',
    _to, _to, _from,
    _to, _to, _from,
    _to, _to, _from
    );
    EXECUTE _q;


    -- WEATHER
    _q := format('

      DELETE FROM %s.environment_weatherobserved;
      INSERT INTO %s.environment_weatherobserved
      SELECT DISTINCT ON (id_entity, "TimeInstant")
        position,
        "TimeInstant",
        source,
        dataprovider,
        refpointofinterest,
        address,
        id_entity,
        created_at,
        updated_at,
        id
      FROM  %s.environment_weatherobserved;

      DELETE FROM %s.environment_weatherobserved_lastdata;
      INSERT INTO %s.environment_weatherobserved_lastdata
      SELECT DISTINCT ON (id_entity, "TimeInstant")
        position,
        "TimeInstant",
        temperature,
        precipitation,
        weathertype,
        visibility,
        source,
        dataprovider,
        refpointofinterest,
        address,
        id_entity,
        created_at,
        updated_at,
        id
      FROM  %s.environment_weatherobserved_lastdata;


      DELETE FROM %s.environment_weatherobserved_measurand;
      INSERT INTO %s.environment_weatherobserved_measurand
      SELECT DISTINCT ON (id_entity, "TimeInstant")
        "TimeInstant",
        temperature,
        precipitation,
        weathertype,
        visibility,
        id_entity,
        created_at,
        updated_at,
        id
      FROM  %s.environment_weatherobserved_measurand;
    ',
    _to, _to, _from,
    _to, _to, _from,
    _to, _to, _from
    );
    EXECUTE _q;

  END;
  $$;


ALTER FUNCTION public.urbo_environment_replicate(_from text, _to text) OWNER TO postgres;

--
-- TOC entry 2480 (class 1255 OID 95404)
-- Name: urbo_environment_replicate_carto(text, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_environment_replicate_carto(_from text, _to text) RETURNS void
    LANGUAGE plpgsql
    AS $$
  DECLARE
    _q text;
    _r record;
  BEGIN

    -- AIR QUALITY
    _q := format('

      DELETE FROM %s_environment_airqualityobserved;
      INSERT INTO %s_environment_airqualityobserved
      SELECT DISTINCT ON (id_entity, "TimeInstant")
        cartodb_id,
        the_geom,
        the_geom_webmercator,
        "TimeInstant",
        source,
        refpointofinterest,
        address,
        id_entity,
        created_at,
        updated_at
      FROM  %s_environment_airqualityobserved;

      DELETE FROM %s_environment_airqualityobserved_lastdata;
      INSERT INTO %s_environment_airqualityobserved_lastdata
      SELECT DISTINCT ON (id_entity, "TimeInstant")
        cartodb_id,
        the_geom,
        the_geom_webmercator,
        "TimeInstant",
        source,
        refpointofinterest,
        so2,
        no2,
        pm10,
        pm2_5,
        co,
        o3,
        id_entity,
        created_at,
        updated_at
      FROM  %s_environment_airqualityobserved_lastdata;


      DELETE FROM %s_environment_airqualityobserved_measurand;
      INSERT INTO %s_environment_airqualityobserved_measurand
      SELECT DISTINCT ON (id_entity, "TimeInstant")
        cartodb_id,
        the_geom,
        the_geom_webmercator,
        "TimeInstant",
        so2,
        no2,
        pm10,
        pm2_5,
        co,
        o3,
        id_entity,
        created_at,
        updated_at
      FROM  %s_environment_airqualityobserved_measurand;

      DELETE FROM %s_environment_aqobserved_measurand_agg;
      INSERT INTO %s_environment_aqobserved_measurand_agg
      SELECT
        "TimeInstant",
        id_entity,
        ica,
        ica_so2,
        ica_no2,
        ica_co,
        ica_o3,
        ica_pm10,
        ica_pm2_5
      FROM %s_environment_aqobserved_measurand_agg;
    ',
    _to, _to, _from,
    _to, _to, _from,
    _to, _to, _from,
    _to, _to, _from
    );

    EXECUTE _q;


    -- NOISE
    _q := format('

      DELETE FROM %s_environment_noiseobserved;
      INSERT INTO %s_environment_noiseobserved
      SELECT DISTINCT ON (id_entity, "TimeInstant")
        cartodb_id,
        the_geom,
        the_geom_webmercator,
        "TimeInstant",
        source,
        dataprovider,
        refpointofinterest,
        address,
        id_entity,
        created_at,
        updated_at
      FROM  %s_environment_noiseobserved;

      DELETE FROM %s_environment_noiseobserved_lastdata;
      INSERT INTO %s_environment_noiseobserved_lastdata
      SELECT DISTINCT ON (id_entity, "TimeInstant")
        cartodb_id,
        the_geom,
        the_geom_webmercator,
        "TimeInstant",
        source,
        dataprovider,
        refpointofinterest,
        instantsoundlevel,
        id_entity,
        created_at,
        updated_at
      FROM  %s_environment_noiseobserved_lastdata;


      DELETE FROM %s_environment_noiseobserved_instantlevel;
      INSERT INTO %s_environment_noiseobserved_instantlevel
      SELECT DISTINCT ON (id_entity, "TimeInstant")
        cartodb_id,
        the_geom,
        the_geom_webmercator,
        "TimeInstant",
        instantsoundlevel,
        id_entity,
        created_at,
        updated_at
      FROM  %s_environment_noiseobserved_instantlevel;
    ',
    _to, _to, _from,
    _to, _to, _from,
    _to, _to, _from
    );
    EXECUTE _q;


    -- WEATHER
    _q := format('

      DELETE FROM %s_environment_weatherobserved;
      INSERT INTO %s_environment_weatherobserved
      SELECT DISTINCT ON (id_entity, "TimeInstant")
        cartodb_id,
        the_geom,
        the_geom_webmercator,
        "TimeInstant",
        source,
        dataprovider,
        refpointofinterest,
        address,
        id_entity,
        created_at,
        updated_at
      FROM  %s_environment_weatherobserved;

      DELETE FROM %s_environment_weatherobserved_lastdata;
      INSERT INTO %s_environment_weatherobserved_lastdata
      SELECT DISTINCT ON (id_entity, "TimeInstant")
        cartodb_id,
        the_geom,
        the_geom_webmercator,
        "TimeInstant",
        temperature,
        precipitation,
        weathertype,
        visibility,
        source,
        dataprovider,
        refpointofinterest,
        address,
        id_entity,
        created_at,
        updated_at
      FROM  %s_environment_weatherobserved_lastdata;


      DELETE FROM %s_environment_weatherobserved_measurand;
      INSERT INTO %s_environment_weatherobserved_measurand
      SELECT DISTINCT ON (id_entity, "TimeInstant")
        cartodb_id,
        the_geom,
        the_geom_webmercator,
        "TimeInstant",
        precipitation,
        weathertype,
        visibility,
        id_entity,
        created_at,
        updated_at
      FROM  %s_environment_weatherobserved_measurand;
    ',
    _to, _to, _from,
    _to, _to, _from,
    _to, _to, _from
    );


  END;
  $$;


ALTER FUNCTION public.urbo_environment_replicate_carto(_from text, _to text) OWNER TO postgres;

--
-- TOC entry 2465 (class 1255 OID 95389)
-- Name: urbo_environment_so2(text, text, timestamp without time zone, timestamp without time zone, boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_environment_so2(id_scope text, id_entity text, start timestamp without time zone, finish timestamp without time zone, iscarto boolean DEFAULT false) RETURNS text
    LANGUAGE plpgsql
    AS $$
  DECLARE
    _r boolean;
    _value3h numeric;
    _value24h numeric;
    _value1h numeric;
  BEGIN


    _value3h := (SELECT urbo_threshold_calculation(id_scope,
        'environment_airqualityobserved_measurand', 'so2',
        id_entity, start::timestamp, finish::timestamp, '3h'::interval, iscarto));

    _value24h := (SELECT urbo_threshold_calculation(id_scope,
        'environment_airqualityobserved_measurand', 'so2',
        id_entity, start::timestamp, finish::timestamp, '24h'::interval, iscarto));


    IF _value3h >= 500 OR _value24h >= 200 THEN
        RETURN 'very bad';
    ELSE
        _value1h := (SELECT urbo_threshold_calculation(id_scope,
            'environment_airqualityobserved_measurand', 'so2',
            id_entity, start::timestamp, finish::timestamp, '1h'::interval, iscarto));
        IF _value1h >= 350 OR (_value24h>=125 AND _value24h < 200) THEN
            RETURN 'bad';
        ELSIF (_value1h >= 125 AND _value1h < 250) OR (_value24h>=90 AND _value24h < 125) THEN
            RETURN 'defficient';
        ELSIF (_value1h >= 70 AND _value1h < 125) OR (_value24h>=50 AND _value24h < 90) THEN
            RETURN 'admisible';
        ELSIF (_value1h >= 0 AND _value1h < 70) OR (_value24h>=0 AND _value24h < 50) THEN
            RETURN 'good';
        ELSE
            RETURN '--';
        END IF;
    END IF;


  END;

$$;


ALTER FUNCTION public.urbo_environment_so2(id_scope text, id_entity text, start timestamp without time zone, finish timestamp without time zone, iscarto boolean) OWNER TO postgres;

--
-- TOC entry 2472 (class 1255 OID 95396)
-- Name: urbo_environment_so2_now(text, text, boolean, timestamp without time zone); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_environment_so2_now(id_scope text, id_entity text, iscarto boolean DEFAULT false, _when timestamp without time zone DEFAULT now()) RETURNS text
    LANGUAGE plpgsql
    AS $$
  DECLARE
    _r boolean;
    _value3h numeric;
    _value1h numeric;
    _value24h numeric;
  BEGIN


    _value3h := (SELECT urbo_threshold_calculation(id_scope,
        'environment_airqualityobserved_measurand', 'so2',
        id_entity, (_when-'3 hour'::interval)::timestamp, _when::timestamp,  '3h'::interval, iscarto));

    _value24h := (SELECT urbo_threshold_calculation(id_scope,
        'environment_airqualityobserved_measurand', 'so2',
        id_entity, (_when-'24 hour'::interval)::timestamp, _when::timestamp, '24h'::interval, iscarto));



    IF _value3h >= 500 OR _value24h >= 200 THEN
        RETURN 'very bad';
    ELSE

        _value1h := (SELECT urbo_threshold_calculation(id_scope,
            'environment_airqualityobserved_measurand', 'so2',
            id_entity, (_when-'1 hour'::interval)::timestamp, _when::timestamp,  '1h'::interval, iscarto));

        IF _value1h >= 350 OR (_value24h>=125 AND _value24h < 200) THEN
            RETURN 'bad';
        ELSIF (_value1h >= 125 AND _value1h < 250) OR (_value24h>=90 AND _value24h < 125) THEN
            RETURN 'defficient';
        ELSIF (_value1h >= 70 AND _value1h < 125) OR (_value24h>=50 AND _value24h < 90) THEN
            RETURN 'admisible';
        ELSIF (_value1h >= 0 AND _value1h < 70) OR (_value24h>=0 AND _value24h < 50) THEN
            RETURN 'good';
        ELSE
            RETURN '--';
        END IF;
    END IF;


  END;

$$;


ALTER FUNCTION public.urbo_environment_so2_now(id_scope text, id_entity text, iscarto boolean, _when timestamp without time zone) OWNER TO postgres;

--
-- TOC entry 2478 (class 1255 OID 95402)
-- Name: urbo_environment_sound_pressure(text, text, timestamp without time zone, timestamp without time zone, boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_environment_sound_pressure(id_scope text, id_entity text, start timestamp without time zone, finish timestamp without time zone, iscarto boolean DEFAULT false) RETURNS numeric
    LANGUAGE plpgsql
    AS $$
  DECLARE
    _table text;
    _q text;
    _r record;
  BEGIN
    _table := urbo_get_table_name(id_scope, 'environment_noiseobserved_instantlevel', iscarto);
    _q := format('
        SELECT 10* LOG( (1.0/count(instantsoundlevel))*SUM( power(10, 0.1*instantsoundlevel)) ) AS iac
        FROM %s
        WHERE id_entity=''%s''
        AND "TimeInstant" >= ''%s''::timestamp AND "TimeInstant" < ''%s''::timestamp
        GROUP BY id_entity',
        _table, id_entity, start, finish);

    -- raise notice '%', _q;
    EXECUTE _q INTO _r;
    -- raise notice '%', _r;

    RETURN _r.iac;

  END;
$$;


ALTER FUNCTION public.urbo_environment_sound_pressure(id_scope text, id_entity text, start timestamp without time zone, finish timestamp without time zone, iscarto boolean) OWNER TO postgres;

--
-- TOC entry 2411 (class 1255 OID 23009)
-- Name: urbo_flow_partialconsumption(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_flow_partialconsumption() RETURNS trigger
    LANGUAGE plpgsql
    AS $_$
  DECLARE
    _tb_nm text;
    _trg_arg text;
    _fld_vals text;
    _fld_list text;
  BEGIN

    IF TG_OP = 'UPDATE' then

      IF OLD.flow IS NULL then
        NEW.flow_partial := 0;
      ELSE
        IF NEW.flow >= OLD.flow then
          NEW.flow_partial := NEW.flow - OLD.flow;
        ELSE
          NEW.flow_partial := OLD.flow_partial;
        END IF;

      END IF;

      _tb_nm := TG_ARGV[0];

      IF TG_NARGS > 1 then
        _fld_vals := format('SELECT $1.%I ', TG_ARGV[1]);
        _fld_list := quote_ident(TG_ARGV[1]);

        FOREACH _trg_arg IN ARRAY TG_ARGV[2:TG_NARGS] LOOP
          _fld_vals := concat(_fld_vals, format(', $1.%I ', _trg_arg));
          _fld_list := concat(_fld_list, format(',%s ',quote_ident(_trg_arg)));
        END LOOP;

        EXECUTE
          format('INSERT INTO %I.%I (%s) %s', TG_TABLE_SCHEMA,_tb_nm,_fld_list,_fld_vals)
        USING NEW;

      ELSE
        EXECUTE
          format('INSERT INTO %I.%I SELECT $1.*', TG_TABLE_SCHEMA,_tb_nm)
        USING NEW;

      END IF;

    END IF;

    RETURN NEW;

  END;
$_$;


ALTER FUNCTION public.urbo_flow_partialconsumption() OWNER TO postgres;

--
-- TOC entry 2412 (class 1255 OID 23010)
-- Name: urbo_flow_partialconsumption_fill_table(text, text, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_flow_partialconsumption_fill_table(sch_name text, tab_name text, id_ent text) RETURNS double precision
    LANGUAGE plpgsql
    AS $$
  DECLARE
    _d record;
    _flw_o double precision;
    _flw_n double precision;
  BEGIN
    _flw_o := 0;
    FOR _d in (select id,flow
              from osuna.watermetering
              where id_entity=id_ent
              order by "TimeInstant")
    LOOP
      _flw_n := _d.flow - _flw_o;
      -- raise notice '% % %',_d.flow,_flw_o,_flw_n;

      IF _flw_n IS NOT NULL then
        IF _flw_n < 0 then
          _flw_n := 0;
        ELSE
          EXECUTE format('UPDATE %I.%I SET flow_partial=%s
                          WHERE id_entity=%L AND id=%s',
                          sch_name,tab_name,_flw_n,id_ent,_d.id);
        END IF;
      END IF;

      _flw_o := _d.flow;

    END LOOP;
    return _flw_n;
  END;
  $$;


ALTER FUNCTION public.urbo_flow_partialconsumption_fill_table(sch_name text, tab_name text, id_ent text) OWNER TO postgres;

--
-- TOC entry 2439 (class 1255 OID 95361)
-- Name: urbo_geom_idx_qry(text, text[]); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_geom_idx_qry(_geom_fld text, _tb_arr text[]) RETURNS text
    LANGUAGE plpgsql
    AS $$
  DECLARE
    _tb text;
    _stm text;
    _pg_geom_idx text;
  BEGIN
    FOREACH _tb IN ARRAY _tb_arr
      LOOP
        _stm = format(
          'CREATE INDEX IF NOT EXISTS %s_gidx ON %s
            USING gist (%s);',
          replace(_tb, '.', '_'), _tb, _geom_fld
        );
        _pg_geom_idx = concat(_pg_geom_idx, _stm);
      END LOOP;

    RETURN _pg_geom_idx;

  END;
  $$;


ALTER FUNCTION public.urbo_geom_idx_qry(_geom_fld text, _tb_arr text[]) OWNER TO postgres;

--
-- TOC entry 2427 (class 1255 OID 95349)
-- Name: urbo_get_table_name(text, text, boolean, boolean, boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_get_table_name(id_scope text, table_name text, iscarto boolean DEFAULT false, lastdata boolean DEFAULT false, view boolean DEFAULT false) RETURNS text
    LANGUAGE plpgsql
    AS $$
  DECLARE
    _sep char;
    _resp text;
  BEGIN

    IF iscarto THEN
      _sep = '_';
    ELSE
      _sep = '.';
    END IF;

    _resp = id_scope||_sep||table_name;

    IF lastdata THEN
      _resp = _resp||'_lastdata';
    END IF;

    IF view THEN
      _resp = _resp||'_view';
    END IF;

    RETURN _resp;
  END;
  $$;


ALTER FUNCTION public.urbo_get_table_name(id_scope text, table_name text, iscarto boolean, lastdata boolean, view boolean) OWNER TO postgres;

--
-- TOC entry 2443 (class 1255 OID 95365)
-- Name: urbo_indicators_qry(text, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_indicators_qry(tb_indic text, tb_indic_nm text) RETURNS text
    LANGUAGE plpgsql
    AS $$
  DECLARE
    _indicators_tb text;
  BEGIN

    _indicators_tb = format('
      CREATE TABLE IF NOT EXISTS %s (
          id bigint NOT NULL,
          bonus_max double precision,
          description text,
          indicatortype text,
          name text,
          penalty_bonus double precision,
          penalty_max double precision,
          performed_detail text,
          period text,
          periodicity text,
          update_date timestamp without time zone,
          value double precision,
          id_entity character varying(64) NOT NULL,
          created_at timestamp without time zone DEFAULT timezone(''utc''::text, now()),
          updated_at timestamp without time zone DEFAULT timezone(''utc''::text, now())
      );

      CREATE TABLE IF NOT EXISTS %s (
          id integer NOT NULL,
          description_es text,
          periodicity_es text,
          name_es text,
          description_en text,
          periodicity_en text,
          name_en text,
          id_entity character varying(64) NOT NULL
      );

      ALTER TABLE ONLY %s
          ADD CONSTRAINT %s_pk PRIMARY KEY (id);

      ALTER TABLE ONLY %s
          ADD CONSTRAINT %s_pk PRIMARY KEY (id);

      ALTER TABLE %s OWNER TO :owner;

      ALTER TABLE %s OWNER TO :owner;

      CREATE INDEX %s_idx
          ON %s USING btree (update_date);
      ', tb_indic, tb_indic_nm, tb_indic,
      replace(tb_indic, '.', '_'), tb_indic_nm,
      replace(tb_indic_nm, '.', '_'), tb_indic,
      tb_indic_nm, replace(tb_indic, '.', '_'), tb_indic
    );

    RETURN _indicators_tb;

  END;
  $$;


ALTER FUNCTION public.urbo_indicators_qry(tb_indic text, tb_indic_nm text) OWNER TO postgres;

--
-- TOC entry 2485 (class 1255 OID 95410)
-- Name: urbo_indoor_air_co2(text, text, timestamp without time zone, timestamp without time zone, boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_indoor_air_co2(id_scope text, id_entity text, start timestamp without time zone, finish timestamp without time zone, iscarto boolean DEFAULT false) RETURNS text
    LANGUAGE plpgsql
    AS $$
  DECLARE
    _r numeric;
  BEGIN

    _r := (SELECT urbo_threshold_calculation(id_scope,
        'indoor_air_quality_measurand', 'co2',
        id_entity, start::timestamp, finish::timestamp, '8h'::interval, iscarto));

    -- raise notice '%', _r;
    IF _r >= 1200 THEN
      RETURN 'very bad';
    ELSIF _r >= 800 AND _r < 1200 THEN
      RETURN 'bad';
    ELSIF _r >= 500 AND _r < 800 THEN
      RETURN 'defficient';
    ELSIF _r >= 350 AND _r < 500 THEN
      RETURN 'admisible';
    ELSIF _r >= 0 AND _r < 350 THEN
      RETURN 'good';
    ELSE
      RETURN '--';
    END IF;

  END;

$$;


ALTER FUNCTION public.urbo_indoor_air_co2(id_scope text, id_entity text, start timestamp without time zone, finish timestamp without time zone, iscarto boolean) OWNER TO postgres;

--
-- TOC entry 2488 (class 1255 OID 95413)
-- Name: urbo_indoor_air_co2_now(text, text, boolean, timestamp without time zone); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_indoor_air_co2_now(text, text, boolean DEFAULT false, timestamp without time zone DEFAULT now()) RETURNS text
    LANGUAGE sql
    AS $_$
    SELECT urbo_indoor_air_co2($1, $2, ($4-'8h'::interval)::timestamp, $4::timestamp, $3);
$_$;


ALTER FUNCTION public.urbo_indoor_air_co2_now(text, text, boolean, timestamp without time zone) OWNER TO postgres;

--
-- TOC entry 2491 (class 1255 OID 95416)
-- Name: urbo_indoor_air_daily_agg(text, text, boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_indoor_air_daily_agg(start text, id_scope text, iscarto boolean DEFAULT false) RETURNS void
    LANGUAGE plpgsql
    AS $$
  DECLARE
    _table text;
    _q text;
  BEGIN
    _table = urbo_get_table_name(id_scope, 'indoor_air_quality_measurand_agg', iscarto);

    _q = format('
      WITH gs AS (SELECT generate_series::text AS time
        FROM generate_series(''%s''::timestamp, ''%s''::timestamp + ''24h''::interval, ''1h''::interval)
      )
      INSERT INTO %s (id_entity, "TimeInstant", ica, ica_co2, ica_tvoc)
      SELECT id_entity, ''%s''::timestamp AS time,
          CASE WHEN ''very bad'' = ANY(array_agg(aqi)) THEN ''very bad''
            WHEN ''bad'' = ANY(array_agg(aqi)) THEN ''bad''
            WHEN ''defficient'' = ANY(array_agg(aqi)) THEN ''defficient''
            WHEN ''admisible'' = ANY(array_agg(aqi)) THEN ''admisible''
            WHEN ''good'' = ANY(array_agg(aqi)) THEN ''good''
            ELSE ''--'' END AS aqi,
          CASE WHEN ''very bad'' = ANY(array_agg(co2)) THEN ''very bad''
            WHEN ''bad'' = ANY(array_agg(co2)) THEN ''bad''
            WHEN ''defficient'' = ANY(array_agg(co2)) THEN ''defficient''
            WHEN ''admisible'' = ANY(array_agg(co2)) THEN ''admisible''
            WHEN ''good'' = ANY(array_agg(co2)) THEN ''good''
            ELSE ''--'' END AS co2,
          CASE WHEN ''very bad'' = ANY(array_agg(tvoc)) THEN ''very bad''
            WHEN ''bad'' = ANY(array_agg(tvoc)) THEN ''bad''
            WHEN ''defficient'' = ANY(array_agg(tvoc)) THEN ''defficient''
            WHEN ''admisible'' = ANY(array_agg(tvoc)) THEN ''admisible''
            WHEN ''good'' = ANY(array_agg(tvoc)) THEN ''good''
            ELSE ''--'' END AS tvoc
        FROM (
          SELECT id_entity, time::timestamp without time zone,
              CASE WHEN ''very bad'' = ANY(ARRAY[co2, tvoc]) THEN ''very bad''
                WHEN ''bad'' = ANY(ARRAY[co2, tvoc]) THEN ''bad''
                WHEN ''defficient'' = ANY(ARRAY[co2, tvoc]) THEN ''defficient''
                WHEN ''admisible'' = ANY(ARRAY[co2, tvoc]) THEN ''admisible''
                WHEN ''good'' = ANY(ARRAY[co2, tvoc]) THEN ''good''
                ELSE ''--'' END AS aqi,
              co2, tvoc
            FROM gs, urbo_indoor_air_now_all(''%s''::text, ''%s'', true, gs.time)
        ) q
        GROUP BY id_entity',
      start, start, _table, start, id_scope, iscarto);

    EXECUTE _q;

  END;
  $$;


ALTER FUNCTION public.urbo_indoor_air_daily_agg(start text, id_scope text, iscarto boolean) OWNER TO postgres;

--
-- TOC entry 2487 (class 1255 OID 95412)
-- Name: urbo_indoor_air_historic(text, text, timestamp without time zone, timestamp without time zone, boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_indoor_air_historic(id_scope text, id_entity text, start timestamp without time zone, finish timestamp without time zone, iscarto boolean DEFAULT false) RETURNS text
    LANGUAGE plpgsql
    AS $$
  DECLARE
    _r text;
    _all text[];
  BEGIN

    -- 6 measures
    _r := (SELECT urbo_indoor_air_co2(id_scope, id_entity, start, finish, iscarto));
    IF _r::text='very bad' THEN
        RETURN 'very bad';
    END IF;
    _all := (SELECT array_append(_all, _r::text));

    _r := (SELECT urbo_indoor_air_tvoc(id_scope, id_entity, start::timestamp, finish::timestamp, iscarto));
    IF _r::text='very bad' THEN
        RETURN 'very bad';
    END IF;
    _all := (SELECT array_append(_all, _r::text));

    -- raise notice '%', _all;

    IF 'very bad' = ANY(_all) THEN
        RETURN 'very bad';
    ELSIF 'bad' = ANY(_all) THEN
        RETURN 'bad';
    ELSIF 'defficient' = ANY(_all) THEN
        RETURN 'defficient';
    ELSIF 'admisible' = ANY(_all) THEN
        RETURN 'admisible';
    ELSIF 'good' = ANY(_all) THEN
        RETURN 'good';
    ELSE
        RETURN '--';
    END IF;



  END;

$$;


ALTER FUNCTION public.urbo_indoor_air_historic(id_scope text, id_entity text, start timestamp without time zone, finish timestamp without time zone, iscarto boolean) OWNER TO postgres;

--
-- TOC entry 2492 (class 1255 OID 95417)
-- Name: urbo_indoor_air_ica_redux(character varying[]); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_indoor_air_ica_redux(_all character varying[]) RETURNS character varying
    LANGUAGE plpgsql
    AS $$
DECLARE
BEGIN
    IF 'very bad' = ANY(_all) THEN
        RETURN 'very bad';
    ELSIF 'bad' = ANY(_all) THEN
        RETURN 'bad';
    ELSIF 'defficient' = ANY(_all) THEN
        RETURN 'defficient';
    ELSIF 'admisible' = ANY(_all) THEN
        RETURN 'admisible';
    ELSIF 'good' = ANY(_all) THEN
        RETURN 'good';
    ELSE
        RETURN '--';
    END IF;
END;
$$;


ALTER FUNCTION public.urbo_indoor_air_ica_redux(_all character varying[]) OWNER TO postgres;

--
-- TOC entry 2490 (class 1255 OID 95415)
-- Name: urbo_indoor_air_now(text, text, boolean, timestamp without time zone); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_indoor_air_now(id_scope text, id_entity text, iscarto boolean DEFAULT false, _when timestamp without time zone DEFAULT now()) RETURNS text
    LANGUAGE plpgsql
    AS $$
  DECLARE
    _r text;
    _all text[];
  BEGIN

    -- 6 measures
    _r := (SELECT urbo_indoor_air_co2_now(id_scope, id_entity, iscarto, _when));
    IF _r::text='very bad' THEN
        RETURN 'very bad';
    END IF;
    _all := (SELECT array_append(_all, _r::text));

    _r := (SELECT urbo_indoor_air_tvoc_now(id_scope, id_entity, iscarto, _when));
    IF _r::text='very bad' THEN
        RETURN 'very bad';
    END IF;
    _all := (SELECT array_append(_all, _r::text));

    -- raise notice '%', _all;

    IF 'very bad' = ANY(_all) THEN
        RETURN 'very bad';
    ELSIF 'bad' = ANY(_all) THEN
        RETURN 'bad';
    ELSIF 'defficient' = ANY(_all) THEN
        RETURN 'defficient';
    ELSIF 'admisible' = ANY(_all) THEN
        RETURN 'admisible';
    ELSIF 'good' = ANY(_all) THEN
        RETURN 'good';
    ELSE
        RETURN '--';
    END IF;



  END;

$$;


ALTER FUNCTION public.urbo_indoor_air_now(id_scope text, id_entity text, iscarto boolean, _when timestamp without time zone) OWNER TO postgres;

--
-- TOC entry 2493 (class 1255 OID 95418)
-- Name: urbo_indoor_air_now_all(text, boolean, boolean, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_indoor_air_now_all(id_scope text, iscarto boolean DEFAULT false, use_time boolean DEFAULT false, use_this_time text DEFAULT now()) RETURNS TABLE(id_entity text, co2 text, tvoc text)
    LANGUAGE plpgsql
    AS $$
  DECLARE
    _table text;
    _tablelast text;
    _time text := '';
  BEGIN
    _table := urbo_get_table_name(id_scope, 'indoor_air_quality_measurand', iscarto);
    _tablelast := urbo_get_table_name(id_scope, 'indoor_air_quality_lastdata', iscarto);

    IF use_time THEN
      _time := format('''%s''::timestamp without time zone AS ', use_this_time);
    END IF;

    RETURN QUERY EXECUTE format('
      WITH lastdata AS (
        SELECT id_entity, %s"TimeInstant" FROM %s
      )

      SELECT twenty_four.id_entity::text AS id_entity,

        (CASE WHEN co2_1 >= 1200 THEN ''very bad''
          WHEN co2_1 >= 800 AND co2_1 < 1200 THEN ''bad''
          WHEN co2_1 >= 500 AND co2_1 < 800 THEN ''defficient''
          WHEN co2_1 >= 350 AND co2_1 < 500 THEN ''admisible''
          WHEN co2_1 >= 0 AND co2_1 < 350 THEN ''good''
          ELSE ''--'' END)::text AS co2,

        (CASE WHEN tvoc_1 >= 2200 THEN ''very bad''
          WHEN tvoc_1 >= 660 AND tvoc_1 < 2200 THEN ''bad''
          WHEN tvoc_1 >= 220 AND tvoc_1 < 660 THEN ''defficient''
          WHEN tvoc_1 >= 65 AND tvoc_1 < 220 THEN ''admisible''
          WHEN tvoc_1 >= 0 AND tvoc_1 < 65 THEN ''good''
          ELSE ''--'' END)::text AS tvoc

        FROM (
          SELECT avg(am.co2) AS co2_24, avg(am.tvoc) AS tvoc_24, am.id_entity
            FROM %s am
            INNER JOIN lastdata ld
            ON am.id_entity = ld.id_entity
            WHERE am."TimeInstant" >= ld."TimeInstant" - ''24h''::interval
            GROUP BY am.id_entity ) twenty_four

        INNER JOIN (
          SELECT avg(am.co2) AS co2_8, avg(am.tvoc) AS tvoc_8, am.id_entity
            FROM %s am
            INNER JOIN lastdata ld
            ON am.id_entity = ld.id_entity
            WHERE am."TimeInstant" >= ld."TimeInstant" - ''8h''::interval
            GROUP BY am.id_entity ) eight

        ON twenty_four.id_entity = eight.id_entity

        INNER JOIN (
          SELECT avg(am.co2) AS co2_3, avg(am.tvoc) AS tvoc_3, am.id_entity
            FROM %s am
            INNER JOIN lastdata ld
            ON am.id_entity = ld.id_entity
            WHERE am."TimeInstant" >= ld."TimeInstant" - ''3h''::interval
            GROUP BY am.id_entity ) three

        ON eight.id_entity = three.id_entity

        INNER JOIN (
          SELECT avg(am.co2) AS co2_1, avg(am.tvoc) AS tvoc_1, am.id_entity
            FROM %s am
            INNER JOIN lastdata ld
            ON am.id_entity = ld.id_entity
            WHERE am."TimeInstant" >= ld."TimeInstant" - ''1h''::interval
            GROUP BY am.id_entity ) one

        ON three.id_entity = one.id_entity',
      _time, _tablelast, _table, _table, _table, _table);

  END;

$$;


ALTER FUNCTION public.urbo_indoor_air_now_all(id_scope text, iscarto boolean, use_time boolean, use_this_time text) OWNER TO postgres;

--
-- TOC entry 2486 (class 1255 OID 95411)
-- Name: urbo_indoor_air_tvoc(text, text, timestamp without time zone, timestamp without time zone, boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_indoor_air_tvoc(id_scope text, id_entity text, start timestamp without time zone, finish timestamp without time zone, iscarto boolean DEFAULT false) RETURNS text
    LANGUAGE plpgsql
    AS $$
  DECLARE
    _r numeric;
  BEGIN

    _r := (SELECT urbo_threshold_calculation(id_scope,
        'indoor_air_quality_measurand', 'tvoc',
        id_entity, start::timestamp, finish::timestamp, '8h'::interval, iscarto));

    -- raise notice '%', _r;
    IF _r >= 2200 THEN
      RETURN 'very bad';
    ELSIF _r >= 660 AND _r < 2200 THEN
      RETURN 'bad';
    ELSIF _r >= 220 AND _r < 660 THEN
      RETURN 'defficient';
    ELSIF _r >= 65 AND _r < 220 THEN
      RETURN 'admisible';
    ELSIF _r >= 0 AND _r < 65 THEN
      RETURN 'good';
    ELSE
      RETURN '--';
    END IF;

  END;

$$;


ALTER FUNCTION public.urbo_indoor_air_tvoc(id_scope text, id_entity text, start timestamp without time zone, finish timestamp without time zone, iscarto boolean) OWNER TO postgres;

--
-- TOC entry 2489 (class 1255 OID 95414)
-- Name: urbo_indoor_air_tvoc_now(text, text, boolean, timestamp without time zone); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_indoor_air_tvoc_now(text, text, boolean DEFAULT false, timestamp without time zone DEFAULT now()) RETURNS text
    LANGUAGE sql
    AS $_$
    SELECT urbo_indoor_air_tvoc($1, $2, ($4-'8h'::interval)::timestamp, $4::timestamp, $3);
$_$;


ALTER FUNCTION public.urbo_indoor_air_tvoc_now(text, text, boolean, timestamp without time zone) OWNER TO postgres;

--
-- TOC entry 2424 (class 1255 OID 93301)
-- Name: urbo_irrigation_flow_partialconsumption(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_irrigation_flow_partialconsumption() RETURNS trigger
    LANGUAGE plpgsql
    AS $_$
  DECLARE
    _tb_nm text;
    _trg_arg text;
    _fld_vals text;
    _fld_list text;
  BEGIN

    IF TG_OP = 'UPDATE' then

      IF OLD.flow IS NULL then
        NEW.flow_partial := 0;
      ELSE
        IF NEW.flow >= OLD.flow then
          NEW.flow_partial := NEW.flow - OLD.flow;
        ELSE
          NEW.flow_partial := OLD.flow_partial;
        END IF;

      END IF;

      _tb_nm := TG_ARGV[0];

      IF TG_NARGS > 1 then
        _fld_vals := format('SELECT $1.%I ', TG_ARGV[1]);
        _fld_list := quote_ident(TG_ARGV[1]);

        FOREACH _trg_arg IN ARRAY TG_ARGV[2:TG_NARGS] LOOP
          _fld_vals := concat(_fld_vals, format(', $1.%I ', _trg_arg));
          _fld_list := concat(_fld_list, format(',%s ',quote_ident(_trg_arg)));
        END LOOP;

        EXECUTE
          format('INSERT INTO %I.%I (%s) %s', TG_TABLE_SCHEMA,_tb_nm,_fld_list,_fld_vals)
        USING NEW;

      ELSE
        EXECUTE
          format('INSERT INTO %I.%I SELECT $1.*', TG_TABLE_SCHEMA,_tb_nm)
        USING NEW;

      END IF;

    END IF;

    RETURN NEW;

  END;
$_$;


ALTER FUNCTION public.urbo_irrigation_flow_partialconsumption() OWNER TO postgres;

--
-- TOC entry 2419 (class 1255 OID 51351)
-- Name: urbo_irrigation_pumping_consumption(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_irrigation_pumping_consumption() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
  DECLARE
    _tb_nm text;
    _q text;
    _iscarto boolean;
    _ret record;
  BEGIN

    -- Lastdata
    IF TG_OP = 'UPDATE'  THEN
      IF OLD.vol IS NULL then
        NEW.consumption := 0;
      ELSE
        IF NEW.vol >= OLD.vol then
          NEW.consumption := NEW.vol - OLD.vol;
        ELSE
          NEW.consumption := OLD.consumption;
        END IF;
      END IF;

    -- Historic
    ELSIF TG_OP = 'INSERT' THEN

      _tb_nm = TG_argv[0];

      -- raise notice '%', _tb_nm;

      _q := format('SELECT vol, consumption, "TimeInstant" as time FROM %s WHERE id_entity=''%s'' AND "TimeInstant" < ''%s'' ORDER BY "TimeInstant" DESC LIMIT 1',
        _tb_nm, NEW.id_entity, NEW."TimeInstant"
      );

      EXECUTE _q INTO _ret;

      -- raise notice 'ret %', _ret;
      -- raise notice 'NEW %', NEW;

      IF _ret IS NOT NULL THEN
        IF NEW."TimeInstant" > _ret.time THEN
          NEW.consumption = NEW.vol - _ret.vol;

          -- Recalcular para todas las medidas posteriores ya insertadas
          -- RAISE NOTICE 'CALCULANDO';
          PERFORM urbo_irrigation_pumping_consumption_calculate(_tb_nm, NEW.id_entity, NEW."TimeInstant");
        END IF;
      END IF;

    END IF;

    RETURN NEW;

  END;
$$;


ALTER FUNCTION public.urbo_irrigation_pumping_consumption() OWNER TO postgres;

--
-- TOC entry 2500 (class 1255 OID 95427)
-- Name: urbo_irrigation_pumping_consumption_calculate(text, text, timestamp without time zone, boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_irrigation_pumping_consumption_calculate(_table_name text, id_entity text, start timestamp without time zone DEFAULT '1999-01-01 00:00:00'::timestamp without time zone, iscarto boolean DEFAULT false) RETURNS SETOF double precision
    LANGUAGE plpgsql
    AS $$
    DECLARE
      _q text;
      _ret record;
      _old record;
      _counter integer default 0;
      _vol double precision;
      _acc double precision;
      _insertion text;
    BEGIN

      _q := format('SELECT * FROM %s WHERE id_entity=''%s'' AND "TimeInstant" >= ''%s'' ORDER BY "TimeInstant" ASC',
        _table_name, id_entity, start
      );

      -- raise notice '%', _q;

      FOR _ret IN EXECUTE _q LOOP
        IF _counter != 0 THEN
          _acc = _ret.vol - _old.vol;

        ELSE
          _acc = _ret.consumption;
          _ret.consumption = 0;
        END IF;
        _old = _ret;

        _counter = _counter + 1;
        IF _acc IS NOT NULL THEN
          IF iscarto THEN
            _insertion = format('UPDATE %s SET consumption = %s where cartodb_id=%s', _table_name, _acc, _ret.cartodb_id);
          ELSE
            _insertion = format('UPDATE %s SET consumption = %s where id=%s', _table_name, _acc, _ret.id);
          END IF;

          EXECUTE _insertion;
        END IF;

        -- RAISE NOTICE '%', _insertion;
        RETURN NEXT _acc;

      END LOOP;

    END;
  $$;


ALTER FUNCTION public.urbo_irrigation_pumping_consumption_calculate(_table_name text, id_entity text, start timestamp without time zone, iscarto boolean) OWNER TO postgres;

--
-- TOC entry 2501 (class 1255 OID 95428)
-- Name: urbo_irrigation_pumping_consumption_calculate_shortcut(text, text, timestamp without time zone, boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_irrigation_pumping_consumption_calculate_shortcut(id_scope text, id_entity text, start timestamp without time zone DEFAULT '1999-01-01 00:00:00'::timestamp without time zone, iscarto boolean DEFAULT false) RETURNS void
    LANGUAGE plpgsql
    AS $$
    DECLARE
      _q text;
      _tb text;
      _ret record;
    BEGIN
      _tb = urbo_get_table_name(id_scope, 'irrigation_pumping', iscarto);
      raise notice '%',  _tb;
      _q = format('SELECT urbo_irrigation_pumping_consumption_calculate(''%s'', ''%s'', ''%s'', ''%s'')',
        _tb, id_entity, start, iscarto);

      EXECUTE _q INTO _ret;


    END;
  $$;


ALTER FUNCTION public.urbo_irrigation_pumping_consumption_calculate_shortcut(id_scope text, id_entity text, start timestamp without time zone, iscarto boolean) OWNER TO postgres;

--
-- TOC entry 2502 (class 1255 OID 95429)
-- Name: urbo_irrigation_pumping_trig(text, boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_irrigation_pumping_trig(id_scope text, iscarto boolean DEFAULT false) RETURNS void
    LANGUAGE plpgsql
    AS $$
  DECLARE
    _q text;
    _sep text DEFAULT '.';
  BEGIN

    IF (iscarto) THEN
      _sep = '_';
    END IF;

    _q = format('

      DROP TRIGGER IF EXISTS urbo_irrigation_pumping_consumption_changes_ld
        ON %s%sirrigation_pumping_lastdata;

      DROP TRIGGER IF EXISTS urbo_irrigation_pumping_consumption_changes_ld_%s
        ON %s%sirrigation_pumping_lastdata;

      CREATE TRIGGER urbo_irrigation_pumping_consumption_changes_ld_%s
        BEFORE UPDATE
        ON %s%sirrigation_pumping_lastdata
        FOR EACH ROW
          EXECUTE PROCEDURE urbo_irrigation_pumping_consumption(''%s%sirrigation_pumping'', ''false'');


      DROP TRIGGER IF EXISTS urbo_irrigation_pumping_consumption_changes
        ON %s%sirrigation_pumping;

      DROP TRIGGER IF EXISTS urbo_irrigation_pumping_consumption_changes_%s
        ON %s%sirrigation_pumping;

      CREATE TRIGGER urbo_irrigation_pumping_consumption_changes_%s
        BEFORE INSERT
        ON %s%sirrigation_pumping
        FOR EACH ROW
          EXECUTE PROCEDURE urbo_irrigation_pumping_consumption(''%s%sirrigation_pumping'', ''false'');',
      id_scope, _sep,
      id_scope, id_scope, _sep,
      id_scope, id_scope, _sep, id_scope, _sep,
      id_scope, _sep,
      id_scope, id_scope, _sep,
      id_scope, id_scope, _sep, id_scope, _sep
    );

    raise notice '%', _q;

    EXECUTE _q;

  END;
  $$;


ALTER FUNCTION public.urbo_irrigation_pumping_trig(id_scope text, iscarto boolean) OWNER TO postgres;

--
-- TOC entry 2495 (class 1255 OID 95420)
-- Name: urbo_irrigation_solenoidvalve_histogram(regclass, text, timestamp without time zone, timestamp without time zone); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_irrigation_solenoidvalve_histogram(table_name regclass, vid_entity text, start timestamp without time zone, finish timestamp without time zone) RETURNS double precision
    LANGUAGE plpgsql
    AS $_$
  DECLARE
    psecs real;
    tsecs real;
    date_reg timestamp;
    date_dur timestamp;
    d record;
  BEGIN
    tsecs := 0;

    EXECUTE format('
      SELECT 1 FROM %1$s
      WHERE id_entity = %2$L
      AND "TimeInstant" BETWEEN %3$L AND %4$L
      AND status = 1
    ', table_name, vid_entity, start, finish)
    INTO d;

    IF d IS NULL THEN
      return tsecs;
    END IF;

    FOR d IN
    EXECUTE format('
      SELECT status, "TimeInstant"
      FROM %1$s
      WHERE id_entity = %2$L
      AND "TimeInstant" BETWEEN %3$L AND %4$L
    ', table_name, vid_entity, start, finish)
    LOOP
      -- raise notice '%',d;

      IF d.status = 1 THEN
        date_reg := d."TimeInstant";
      ELSE
        IF d.status = 0 THEN
          date_dur := d."TimeInstant";
          psecs := (SELECT extract(epoch FROM age(date_dur,date_reg)));
          tsecs := tsecs + psecs;
          -- raise notice '%',psecs;
        END IF;
      END IF;

    END LOOP;
    -- raise notice 'Total: %',tsecs;
    return tsecs;

  END;
  $_$;


ALTER FUNCTION public.urbo_irrigation_solenoidvalve_histogram(table_name regclass, vid_entity text, start timestamp without time zone, finish timestamp without time zone) OWNER TO postgres;

--
-- TOC entry 2496 (class 1255 OID 95421)
-- Name: urbo_irrigation_solenoidvalve_histogramclasses(regclass, text, timestamp without time zone, timestamp without time zone, integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_irrigation_solenoidvalve_histogramclasses(table_name regclass, vid_entity text, start timestamp without time zone, finish timestamp without time zone, classstep integer) RETURNS integer
    LANGUAGE plpgsql
    AS $_$
  DECLARE
    psecs real;
    tsecs real;
    date_reg timestamp;
    date_dur timestamp;
    d record;
    _sql text;
  BEGIN
    tsecs := 0;

    EXECUTE format('
      SELECT 1 FROM %1$s
      WHERE id_entity = %2$L
      AND "TimeInstant" BETWEEN %3$L AND %4$L
      AND status = 1
    ', table_name, vid_entity, start, finish)
    INTO d;

    IF d IS NULL THEN
      return tsecs;
    END IF;

    FOR d IN
    EXECUTE format('
      SELECT status, "TimeInstant"
      FROM %1$s
      WHERE id_entity = %2$L
      AND "TimeInstant" BETWEEN %3$L AND %4$L
    ', table_name, vid_entity, start, finish)
    LOOP
      -- raise notice '%',d;

      IF d.status = 1 THEN
        date_reg := d."TimeInstant";
      ELSE
        IF d.status = 0 THEN
          date_dur := d."TimeInstant";
          psecs := (SELECT extract(epoch FROM age(date_dur,date_reg)));
          tsecs := tsecs + psecs;
          -- raise notice '%',psecs;
        END if;
      END if;

    END LOOP;

    tsecs := tsecs / 60;

    IF tsecs = 0 THEN
      return 0;
    ELSIF tsecs < (classstep) THEN
      return classstep;
    ELSIF tsecs < (classstep * 2) THEN
      return classstep * 2;
    ELSIF tsecs < (classstep * 3) THEN
      return classstep * 3;
    ELSIF tsecs < (classstep * 4) THEN
      return classstep * 4;
    ELSE
      return classstep * 5;
    END if;

  END;
  $_$;


ALTER FUNCTION public.urbo_irrigation_solenoidvalve_histogramclasses(table_name regclass, vid_entity text, start timestamp without time zone, finish timestamp without time zone, classstep integer) OWNER TO postgres;

--
-- TOC entry 2497 (class 1255 OID 95422)
-- Name: urbo_irrigation_solenoidvalve_hoursarray(regclass, text, timestamp without time zone, timestamp without time zone); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_irrigation_solenoidvalve_hoursarray(table_name regclass, vid_entity text, start timestamp without time zone, finish timestamp without time zone) RETURNS integer[]
    LANGUAGE plpgsql
    AS $_$
  DECLARE
    hour_reg integer;
    hour_dur integer;
    hours_array integer[];
    hours_range integer[];
    date_reg timestamp;
    date_dur timestamp;
    d record;
  BEGIN

    EXECUTE format('
      SELECT 1 FROM %1$s
      WHERE id_entity = %2$L
      AND "TimeInstant" BETWEEN %3$L AND %4$L
      AND status = 1
    ', table_name, vid_entity, start, finish)
    INTO d;

    IF d IS NULL THEN
      return ARRAY[]::integer[];
    END IF;

    FOR d IN
    EXECUTE format('
      SELECT status, "TimeInstant"
      FROM %1$s
      WHERE id_entity = %2$L
      AND "TimeInstant" BETWEEN %3$L AND %4$L
    ', table_name, vid_entity, start, finish)
    LOOP
      -- raise notice '%',d;

      IF d.status = 1 THEN
        date_reg := d."TimeInstant";
      ELSE
        IF d.status = 0 and date_reg IS NOT NULL THEN
          date_dur := d."TimeInstant";

          hour_reg := (SELECT extract(hour from date_reg::timestamp));
          hour_dur := (SELECT extract(hour from date_dur::timestamp));
          -- raise notice '% --- hour_reg %, hour_dur %, %',date_reg,hour_reg,hour_dur,vid_entity;
          IF hour_reg != hour_dur THEN
            hours_range := ARRAY[]::integer[];
            hours_range := (SELECT array_agg(extract(hour from dates::timestamp))
                          FROM generate_series(date_reg::timestamp,
                            date_dur::timestamp, '1 hours') as dates);

            hours_array := (SELECT array_cat(hours_array, hours_range));

            IF NOT hours_array @> ARRAY[hour_dur]::integer[]  THEN
              hours_array := (SELECT array_append(hours_array, hour_dur));

            END if;

          ELSE
            hours_array := (SELECT array_append(hours_array, hour_reg));

          END if;
          -- raise notice 'start %, finish %, %',date_reg,date_dur,hours_array;
        END if;
      END if;

    END LOOP;

    return hours_array;

  END;
  $_$;


ALTER FUNCTION public.urbo_irrigation_solenoidvalve_hoursarray(table_name regclass, vid_entity text, start timestamp without time zone, finish timestamp without time zone) OWNER TO postgres;

--
-- TOC entry 2413 (class 1255 OID 23014)
-- Name: urbo_lighting_agg_energy(text, timestamp with time zone, timestamp with time zone, boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_lighting_agg_energy(id_scope text, start timestamp with time zone, finish timestamp with time zone, iscarto boolean DEFAULT false) RETURNS void
    LANGUAGE plpgsql
    AS $$
  DECLARE
    _table_last text;
    _r record;
    _q text;
  BEGIN


    _table_last = urbo_get_table_name(id_scope, 'lighting_stcabinet', iscarto, true);

    _q:=format('
      SELECT urbo_lighting_append_energy(''%s'', id_entity, ''%s'', ''%s''::timestamp with time zone + ''1h''::interval, ''%s'')
      FROM (SELECT DISTINCT id_entity FROM %s) as foo',
      id_scope, start, start, iscarto, _table_last);

    -- RAISE NOTICE '%', _q;

    EXECUTE _q INTO _r;

    -- RAISE NOTICE '%', _r;

  END;
  $$;


ALTER FUNCTION public.urbo_lighting_agg_energy(id_scope text, start timestamp with time zone, finish timestamp with time zone, iscarto boolean) OWNER TO postgres;

--
-- TOC entry 2505 (class 1255 OID 95432)
-- Name: urbo_lighting_append_energy(text, text, timestamp with time zone, timestamp with time zone, boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_lighting_append_energy(id_scope text, id_entity text, start timestamp with time zone, finish timestamp with time zone, iscarto boolean DEFAULT false) RETURNS void
    LANGUAGE plpgsql
    AS $$
  DECLARE
    _state_table text;
    _table_name text;
    _counter_table text;
    _r json;
    _q text;
    _re record;
    _ret json;
  BEGIN

    _state_table = urbo_get_table_name(id_scope, 'lighting_stcabinet_state', iscarto, false);
    _table_name = urbo_get_table_name(id_scope, 'lighting_stcabinet', iscarto, false);
    _counter_table = urbo_get_table_name(id_scope, 'lighting_stcabinet_state_agg_hour', iscarto, false);


    _q := format('SELECT urbo_lighting_energy_counters(''%s'', ''%s'', ''%s'', ''%s'', ''%s'') as foo',
      id_scope, id_entity, start, finish, iscarto);

    EXECUTE _q INTO _r;

    -- RAISE NOTICE '%', _r;

    IF (_r::json->>'energyconsumed') IS NOT NULL
    AND (_r::json->>'reactiveenergyconsumed') IS NOT NULL
    THEN

      _q := format('
        INSERT INTO %s ("TimeInstant", id_entity, energyconsumed, reactiveenergyconsumed)
        VALUES (''%s'', ''%s'', %s, %s)',
        _counter_table, start, id_entity, _r::json->>'energyconsumed', _r::json->>'reactiveenergyconsumed');

      -- raise notice '%', _q;

      EXECUTE _q;

    END IF;
  END;
  $$;


ALTER FUNCTION public.urbo_lighting_append_energy(id_scope text, id_entity text, start timestamp with time zone, finish timestamp with time zone, iscarto boolean) OWNER TO postgres;

--
-- TOC entry 2414 (class 1255 OID 23016)
-- Name: urbo_lighting_energy_counters(text, text, timestamp with time zone, timestamp with time zone, boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_lighting_energy_counters(id_scope text, id_entity text, start timestamp with time zone, finish timestamp with time zone, iscarto boolean DEFAULT false) RETURNS json
    LANGUAGE plpgsql
    AS $$
  DECLARE
    _state_table text;
    _table_name text;
    _counter_table text;
    _qmax text;
    _qmin text;
    _rmax record;
    _rmin record;
    _ret json;
  BEGIN
    _state_table = urbo_get_table_name(id_scope, 'lighting_stcabinet_state', iscarto, false);
    _table_name = urbo_get_table_name(id_scope, 'lighting_stcabinet', iscarto, false);

    -- finish := finish + '1 minute'::interval;
    _qmax := format('
      SELECT
        date_trunc(''minute'', "TimeInstant") as time,
        energyconsumed as energyconsumed,
        reactiveenergyconsumed as reactiveenergyconsumed
      FROM %s g
      WHERE id_entity=''%s''
      AND "TimeInstant" = (SELECT
          MAX("TimeInstant")
          FROM %s
          WHERE id_entity=g.id_entity
          AND date_trunc(''minute'', "TimeInstant") BETWEEN ''%s'' AND ''%s'')',
      _state_table, id_entity, _state_table, start, finish);

      -- raise notice '%; ', _qmax;
      EXECUTE _qmax INTO _rmax;

    _qmin := format('
      SELECT
        date_trunc(''minute'', "TimeInstant") as time,
        energyconsumed as energyconsumed,
        reactiveenergyconsumed as reactiveenergyconsumed
      FROM %s g
      WHERE id_entity=''%s''
      AND "TimeInstant" = (SELECT
          MIN("TimeInstant")
          FROM %s
          WHERE id_entity=g.id_entity
          AND date_trunc(''minute'', "TimeInstant") BETWEEN ''%s'' AND ''%s'')',
      _state_table, id_entity, _state_table, start, finish);

      -- raise notice '%; ', _qmin;
      EXECUTE _qmin INTO _rmin;

    _ret = json_build_object(
      'energyconsumed', _rmax.energyconsumed - _rmin.energyconsumed,
      'reactiveenergyconsumed', _rmax.reactiveenergyconsumed - _rmin.reactiveenergyconsumed);

    RETURN _ret;
  END;
  $$;


ALTER FUNCTION public.urbo_lighting_energy_counters(id_scope text, id_entity text, start timestamp with time zone, finish timestamp with time zone, iscarto boolean) OWNER TO postgres;

--
-- TOC entry 2506 (class 1255 OID 95433)
-- Name: urbo_lighting_replicate(text, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_lighting_replicate(_from text, _to text) RETURNS void
    LANGUAGE plpgsql
    AS $$
  DECLARE
    _q text;
    _r record;
  BEGIN

    _q := format('

      DELETE FROM %s.lighting_stcabinet;
      INSERT INTO %s.lighting_stcabinet
      SELECT DISTINCT ON(id_entity, "TimeInstant")
        position,
        "TimeInstant",
        customerid,
        premisesid,
        groupid,
        devicetype,
        energytype,
        energyuse,
        id_entity,
        created_at,
        updated_at,
        id
      FROM %s.lighting_stcabinet;

      DELETE FROM %s.lighting_stcabinet_lastdata;
      INSERT INTO %s.lighting_stcabinet_lastdata
      SELECT
        position,
        "TimeInstant",
        energyconsumed,
        reactiveenergyconsumed,
        totalactivepower,
        customerid,
        powerstate_general,
        powerstate_reduced,
        premisesid,
        groupid,
        devicetype,
        energytype,
        energyuse,
        id_entity,
        created_at,
        updated_at,
        id
      FROM %s.lighting_stcabinet_lastdata;

      DELETE FROM %s.lighting_stcabinet_state;
      INSERT INTO %s.lighting_stcabinet_state
      SELECT DISTINCT ON(id_entity, "TimeInstant")
        "TimeInstant",
        energyconsumed,
        reactiveenergyconsumed,
        totalactivepower,
        id_entity,
        created_at,
        updated_at,
        id
      FROM %s.lighting_stcabinet_state;


      DELETE FROM %s.lighting_stcabinet_powerstate;
      INSERT INTO %s.lighting_stcabinet_powerstate
      SELECT
        "TimeInstant",
        powerstate_general,
        powerstate_reduced,
        id_entity,
        created_at,
        updated_at,
        id
      FROM %s.lighting_stcabinet_powerstate;




      DELETE FROM metadata.variables_scopes where id_scope = ''%s'';
      INSERT INTO metadata.variables_scopes (id_scope, id_variable, id_entity, entity_field, var_name, var_units, var_thresholds, var_agg, var_reverse, config, table_name, type, mandatory, editable)
      SELECT ''%s'', id_variable, id_entity, entity_field, var_name, var_units, var_thresholds, var_agg, var_reverse, config, table_name, type, mandatory, editable
      FROM metadata.variables_scopes where id_scope=''%s''
      ',
      _to, _to, _from,
      _to, _to, _from,
      _to, _to, _from,
      _to, _to, _from,
      _to, _to, _from);

    EXECUTE _q;

  END;
  $$;


ALTER FUNCTION public.urbo_lighting_replicate(_from text, _to text) OWNER TO postgres;

--
-- TOC entry 2507 (class 1255 OID 95434)
-- Name: urbo_lighting_replicate_carto(text, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_lighting_replicate_carto(_from text, _to text) RETURNS void
    LANGUAGE plpgsql
    AS $$
  DECLARE
    _q text;
    _r record;
  BEGIN

  _q := format('
    DELETE FROM %s_lighting_stcabinet;
    INSERT INTO %s_lighting_stcabinet
    SELECT
      cartodb_id,
      the_geom,
      the_geom_webmercator,
      "TimeInstant",
      customerid,
      premisesid,
      groupid,
      devicetype,
      energytype,
      energyuse,
      id_entity,
      created_at,
      updated_at
    FROM %s_lighting_stcabinet;

    DELETE FROM %s_lighting_stcabinet_lastdata;
    INSERT INTO %s_lighting_stcabinet_lastdata
    SELECT
      cartodb_id,
      the_geom,
      the_geom_webmercator,
      "TimeInstant",
      energyconsumed,
      reactiveenergyconsumed,
      totalactivepower,
      customerid,
      powerstate_general,
      powerstate_reduced,
      premisesid,
      groupid,
      devicetype,
      energytype,
      energyuse,
      id_entity,
      created_at,
      updated_at
    FROM %s_lighting_stcabinet_lastdata;

    DELETE FROM %s_lighting_stcabinet_state;
    INSERT INTO %s_lighting_stcabinet_state
    SELECT
      cartodb_id,
      the_geom,
      the_geom_webmercator,
      "TimeInstant",
      energyconsumed,
      reactiveenergyconsumed,
      totalactivepower,
      id_entity,
      created_at,
      updated_at
    FROM %s_lighting_stcabinet_state;


    DELETE FROM %s_lighting_stcabinet_powerstate;
    INSERT INTO %s_lighting_stcabinet_powerstate
    SELECT
      cartodb_id,
      the_geom,
      the_geom_webmercator,
      "TimeInstant",
      powerstate_general,
      powerstate_reduced,
      id_entity,
      created_at,
      updated_at
    FROM %s_lighting_stcabinet_powerstate;

  ',
  _to, _to, _from,
  _to, _to, _from,
  _to, _to, _from,
  _to, _to, _from);

  EXECUTE _q;

  END;
  $$;


ALTER FUNCTION public.urbo_lighting_replicate_carto(_from text, _to text) OWNER TO postgres;

--
-- TOC entry 2425 (class 1255 OID 95344)
-- Name: urbo_metadata(text, boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_metadata(t_owner text, isdebug boolean DEFAULT false) RETURNS void
    LANGUAGE plpgsql
    AS $_$
  DECLARE
    _ddl_qry text;
    _t_count integer;
  BEGIN
    SELECT COUNT(*) INTO _t_count FROM information_schema.schemata WHERE schema_name = 'metadata';
    IF isdebug IS TRUE then
        RAISE NOTICE '%', _ddl_qry;
    END IF;

    IF _t_count = 0 IS TRUE THEN
      _ddl_qry = format('
      CREATE SCHEMA metadata;

      ALTER SCHEMA metadata OWNER TO %1$s;

      CREATE TABLE metadata.categories (
          id_category character varying(255) NOT NULL,
          category_name character varying(255),
          nodata boolean DEFAULT false,
          config jsonb DEFAULT ''{}''::jsonb
      );

      ALTER TABLE metadata.categories OWNER TO %1$s;

      CREATE TABLE metadata.categories_scopes (
          id_scope character varying(255) NOT NULL,
          id_category character varying(255) NOT NULL,
          category_name character varying(255),
          nodata boolean DEFAULT false,
          config jsonb DEFAULT ''{}''::jsonb
      );

      ALTER TABLE metadata.categories_scopes OWNER TO %1$s;

      CREATE TABLE metadata.entities (
          id_entity character varying(255) NOT NULL,
          entity_name character varying(255),
          id_category character varying(255),
          table_name character varying(255),
          mandatory boolean DEFAULT false,
          editable boolean DEFAULT false
      );

      ALTER TABLE metadata.entities OWNER TO %1$s;

      CREATE TABLE metadata.entities_scopes (
          id_scope character varying(255) NOT NULL,
          id_entity character varying(255) NOT NULL,
          entity_name character varying(255),
          id_category character varying(255),
          table_name character varying(255),
          mandatory boolean DEFAULT false,
          editable boolean DEFAULT false
      );

      ALTER TABLE metadata.entities_scopes OWNER TO %1$s;

      CREATE TABLE metadata.scope_widgets_tokens (
          id_scope character varying(255) NOT NULL,
          id_widget character varying(255) NOT NULL,
          publish_name character varying(255) NOT NULL,
          token text NOT NULL,
          payload jsonb,
          id integer NOT NULL,
          description text,
          created_at timestamp without time zone DEFAULT timezone(''utc''::text, now())
      );

      ALTER TABLE metadata.scope_widgets_tokens OWNER TO %1$s;

      CREATE SEQUENCE metadata.scope_widgets_tokens_id_seq
          START WITH 1
          INCREMENT BY 1
          NO MINVALUE
          NO MAXVALUE
          CACHE 1;


      ALTER TABLE metadata.scope_widgets_tokens_id_seq OWNER TO %1$s;

      ALTER SEQUENCE metadata.scope_widgets_tokens_id_seq OWNED BY metadata.scope_widgets_tokens.id;

      CREATE TABLE metadata.scopes (
          id_scope character varying(255) NOT NULL,
          scope_name character varying(255),
          geom public.geometry(Point,4326),
          zoom smallint,
          dbschema character varying(255),
          parent_id_scope character varying(255) DEFAULT NULL::character varying,
          status smallint DEFAULT 0,
          timezone character varying(255),
          config jsonb
      );

      ALTER TABLE metadata.scopes OWNER TO %1$s;

      CREATE TABLE metadata.variables (
          id_variable character varying(255) NOT NULL,
          id_entity character varying(255),
          entity_field character varying(255),
          var_name character varying(255),
          var_units character varying(255),
          var_thresholds double precision[],
          var_agg character varying[],
          var_reverse boolean,
          config jsonb,
          table_name character varying(255),
          type character varying(255) DEFAULT ''catalogue''::character varying,
          mandatory boolean DEFAULT false,
          editable boolean DEFAULT false
      );


      ALTER TABLE metadata.variables OWNER TO %1$s;

      CREATE TABLE metadata.variables_scopes (
          id_scope character varying(255) NOT NULL,
          id_variable character varying(255) NOT NULL,
          id_entity character varying(255) NOT NULL,
          entity_field character varying(255),
          var_name character varying(255),
          var_units character varying(255),
          var_thresholds double precision[],
          var_agg character varying[],
          var_reverse boolean,
          config jsonb,
          table_name character varying(255),
          type character varying(255) DEFAULT ''catalogue''::character varying,
          mandatory boolean DEFAULT false,
          editable boolean DEFAULT false
      );

      ALTER TABLE metadata.variables_scopes OWNER TO %1$s;

      ALTER TABLE ONLY metadata.scope_widgets_tokens ALTER COLUMN id SET DEFAULT nextval(''scope_widgets_tokens_id_seq''::regclass);

      ALTER TABLE ONLY metadata.categories
          ADD CONSTRAINT categories_pkey PRIMARY KEY (id_category);

      ALTER TABLE ONLY metadata.categories_scopes
          ADD CONSTRAINT categories_scopes_pkey PRIMARY KEY (id_scope, id_category);

      ALTER TABLE ONLY metadata.entities
          ADD CONSTRAINT entities_pkey PRIMARY KEY (id_entity);

      ALTER TABLE ONLY metadata.entities_scopes
          ADD CONSTRAINT entities_scopes_pkey PRIMARY KEY (id_scope, id_entity);

      ALTER TABLE ONLY metadata.scope_widgets_tokens
          ADD CONSTRAINT scope_widgets_tokens_id_scope_id_widget_publish_name_token_key UNIQUE (id_scope, id_widget, publish_name, token);

      ALTER TABLE ONLY metadata.scope_widgets_tokens
          ADD CONSTRAINT scope_widgets_tokens_pkey PRIMARY KEY (id);

      ALTER TABLE ONLY metadata.scopes
          ADD CONSTRAINT scopes_dbschema_key UNIQUE (dbschema);

      ALTER TABLE ONLY metadata.scopes
          ADD CONSTRAINT scopes_pkey PRIMARY KEY (id_scope);

      ALTER TABLE ONLY metadata.variables
          ADD CONSTRAINT variables_pkey PRIMARY KEY (id_variable);

      ALTER TABLE ONLY metadata.variables_scopes
          ADD CONSTRAINT variables_scopes_pkey PRIMARY KEY (id_scope, id_entity, id_variable);

      CREATE INDEX idx_scope_geom ON metadata.scopes USING gist (geom);

      ALTER TABLE ONLY metadata.categories_scopes
          ADD CONSTRAINT categories_scopes_id_category_fkey FOREIGN KEY (id_category) REFERENCES metadata.categories(id_category);

      ALTER TABLE ONLY metadata.categories_scopes
          ADD CONSTRAINT categories_scopes_id_scope_fkey FOREIGN KEY (id_scope) REFERENCES metadata.scopes(id_scope) ON UPDATE CASCADE ON DELETE CASCADE;

      ALTER TABLE ONLY metadata.entities
          ADD CONSTRAINT entities_id_category_fkey FOREIGN KEY (id_category) REFERENCES metadata.categories(id_category);

      ALTER TABLE ONLY metadata.entities_scopes
          ADD CONSTRAINT entities_scopes_id_category_fkey FOREIGN KEY (id_category) REFERENCES metadata.categories(id_category);

      ALTER TABLE ONLY metadata.entities_scopes
          ADD CONSTRAINT entities_scopes_id_entity_fkey FOREIGN KEY (id_entity) REFERENCES metadata.entities(id_entity);

      ALTER TABLE ONLY metadata.entities_scopes
          ADD CONSTRAINT entities_scopes_id_scope_fkey FOREIGN KEY (id_scope) REFERENCES metadata.scopes(id_scope) ON UPDATE CASCADE ON DELETE CASCADE;

      ALTER TABLE ONLY metadata.variables
          ADD CONSTRAINT variables_id_entity_fkey FOREIGN KEY (id_entity) REFERENCES metadata.entities(id_entity);

      ALTER TABLE ONLY metadata.variables_scopes
          ADD CONSTRAINT variables_scopes_id_entity_fkey FOREIGN KEY (id_entity) REFERENCES metadata.entities(id_entity);

      ALTER TABLE ONLY metadata.variables_scopes
          ADD CONSTRAINT variables_scopes_id_scope_fkey FOREIGN KEY (id_scope) REFERENCES metadata.scopes(id_scope) ON UPDATE CASCADE ON DELETE CASCADE;

      ALTER TABLE ONLY metadata.variables_scopes
          ADD CONSTRAINT variables_scopes_id_variable_fkey FOREIGN KEY (id_variable) REFERENCES metadata.variables(id_variable);
      ',
      t_owner);
      EXECUTE _ddl_qry;
    ELSE
      RAISE NOTICE 'metadata schema already exists';
    END IF;
  END;
  $_$;


ALTER FUNCTION public.urbo_metadata(t_owner text, isdebug boolean) OWNER TO postgres;

--
-- TOC entry 2432 (class 1255 OID 95354)
-- Name: urbo_metadata_usergraph(text, integer, boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_metadata_usergraph(id_scope text, id_user integer, is_superadmin boolean DEFAULT false) RETURNS SETOF record
    LANGUAGE sql
    AS $_$
      WITH RECURSIVE search_graph(id,name) AS
      (
        SELECT
          id,
          name
        FROM users_graph WHERE id IN (
          SELECT
            g.id
          FROM metadata.scopes s JOIN public.users_graph g
          ON s.id_scope=g.name
          WHERE (
            s.parent_id_scope IS NOT NULL
            AND s.parent_id_scope != 'orphan'
            AND s.parent_id_scope = $1)
          OR g.name = $1)
        UNION ALL
        SELECT
          ug.id,
          ug.name
          FROM search_graph sg
          INNER JOIN users_graph ug ON ug.parent=sg.id
          WHERE TRUE = $3 OR (
            $2 = ANY(ug.read_users)
            OR $2 = ANY(ug.write_users)
          )
      )
      SELECT
        id_category as id,
        category_name as name,
        nodata,
        category_config as config,
        json_agg(
          json_build_object(
            'id', id_entity,
            'name', entity_name,
            'mandatory', entity_mandatory,
            'editable', entity_editable,
            'table', entity_table_name,
            'variables', variables
          )
        ) as entities
      FROM (
        SELECT
          mdt.category_name,
          mdt.id_category,
          mdt.nodata,
          mdt.category_config,
          mdt.id_entity,
          mdt.entity_name,
          mdt.entity_mandatory,
          mdt.entity_table_name,
          mdt.entity_editable,
          array_remove(array_agg(
            CASE
              WHEN mdt.id_variable IS NOT NULL THEN
                jsonb_build_object(
                  'id', mdt.id_variable,
                  'id_entity', mdt.id_entity,
                  'name', mdt.var_name,
                  'units', mdt.var_units,
                  'var_thresholds', mdt.var_thresholds,
                  'var_agg', mdt.var_agg,
                  'reverse', mdt.var_reverse,
                  'mandatory', mdt.var_mandatory,
                  'editable', mdt.var_editable,
                  'table_name', mdt.table_name,
                  'config', mdt.config
                )
              ELSE NULL
            END
          ), NULL) as variables
        FROM search_graph sg
        JOIN (
          SELECT DISTINCT
            c.category_name,
            c.id_category,
            c.nodata,
            c.config AS category_config,
            (CASE
                WHEN v.table_name IS NULL THEN e.table_name
                ELSE v.table_name
              END) AS table_name,
            e.id_entity,
            e.entity_name,
            e.mandatory AS entity_mandatory,
            e.table_name AS entity_table_name,
            e.editable AS entity_editable,
            v.id_variable AS id_variable,
            v.var_name,
            v.var_units,
            v.var_thresholds,
            v.var_agg,
            v.var_reverse,
            v.mandatory AS var_mandatory,
            v.editable AS var_editable,
            v.entity_field AS column_name,
            v.config
          FROM metadata.scopes s
          LEFT JOIN metadata.categories_scopes c
            ON c.id_scope = s.id_scope
          LEFT JOIN metadata.entities_scopes e
            ON e.id_category = c.id_category AND e.id_scope = s.id_scope
          LEFT JOIN metadata.variables_scopes v
            ON v.id_entity = e.id_entity AND v.id_scope = s.id_scope
          WHERE s.id_scope = $1
        ) mdt ON (sg.name = mdt.id_variable OR (mdt.id_variable IS NULL AND sg.name=mdt.id_entity))
        GROUP BY mdt.category_name, mdt.id_category, mdt.nodata,
        mdt.category_config, mdt.id_entity, mdt.entity_name,
        mdt.entity_mandatory, mdt.entity_editable, mdt.entity_table_name
      ) _e GROUP BY id_category, category_name, nodata, category_config;

$_$;


ALTER FUNCTION public.urbo_metadata_usergraph(id_scope text, id_user integer, is_superadmin boolean) OWNER TO postgres;

--
-- TOC entry 2433 (class 1255 OID 95355)
-- Name: urbo_multiscope_childs_usergraph(text, integer, boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_multiscope_childs_usergraph(id_multiscope text, id_user integer, is_superadmin boolean DEFAULT false) RETURNS SETOF text
    LANGUAGE sql
    AS $_$
    WITH RECURSIVE multiscope_childs(id_scope) AS (
      SELECT
        sc.id_scope
      FROM metadata.scopes sc
      JOIN public.users_graph ug ON (
      sc.id_scope=ug.name
      AND (TRUE = $3 OR
        ($2 = ANY(ug.read_users)
        OR $2 = ANY(ug.write_users))
      )
    ) WHERE sc.parent_id_scope = $1
    )
    SELECT id_scope::text FROM multiscope_childs;

$_$;


ALTER FUNCTION public.urbo_multiscope_childs_usergraph(id_multiscope text, id_user integer, is_superadmin boolean) OWNER TO postgres;

--
-- TOC entry 2520 (class 1255 OID 95450)
-- Name: urbo_parking_agg_day(character varying, timestamp without time zone, boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_parking_agg_day(id_scope character varying, day timestamp without time zone, iscarto boolean DEFAULT false) RETURNS record
    LANGUAGE plpgsql
    AS $$
  DECLARE
    _q text;
    _onstreet text;
    _offstreet text;
    _ret record;
  BEGIN

    _onstreet = urbo_get_table_name(id_scope, 'parking_onstreetparking', iscarto);
    _offstreet = urbo_get_table_name(id_scope, 'parking_offstreetparking', iscarto);

    _q := format('
        WITH parkings AS (
          (SELECT DISTINCT id_entity, ''parking.onstreet'' AS kind FROM %s)
          UNION ALL
          (SELECT DISTINCT id_entity, ''parking.offstreet'' AS kind FROM %s)
        )
        SELECT urbo_parking_append_day(''%s'', id_entity, kind, ''%s'', ''%s'') FROM parkings',
        _onstreet, _offstreet, id_scope, day, iscarto);

    -- raise notice '%', _q;
    EXECUTE _q INTO _ret;
    return _ret;

  END;
  $$;


ALTER FUNCTION public.urbo_parking_agg_day(id_scope character varying, day timestamp without time zone, iscarto boolean) OWNER TO postgres;

--
-- TOC entry 2519 (class 1255 OID 95449)
-- Name: urbo_parking_agg_hour(character varying, timestamp without time zone, boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_parking_agg_hour(id_scope character varying, hour timestamp without time zone, iscarto boolean DEFAULT false) RETURNS record
    LANGUAGE plpgsql
    AS $$
  DECLARE
    _q text;
    _onstreet text;
    _offstreet text;
    _ret record;
  BEGIN

    _onstreet = urbo_get_table_name(id_scope, 'parking_onstreetparking', iscarto);
    _offstreet = urbo_get_table_name(id_scope, 'parking_offstreetparking', iscarto);

    _q := format('
        WITH parkings AS (
          (SELECT DISTINCT id_entity, ''parking.onstreet'' AS kind FROM %s)
          UNION ALL
          (SELECT DISTINCT id_entity, ''parking.offstreet'' AS kind FROM %s)
        )
        SELECT urbo_parking_append_hour(''%s'', id_entity, kind, ''%s'', ''%s'') FROM parkings',
        _onstreet, _offstreet, id_scope, hour, iscarto);

    -- raise notice '%', _q;
    EXECUTE _q INTO _ret;
    return _ret;

  END;
  $$;


ALTER FUNCTION public.urbo_parking_agg_hour(id_scope character varying, hour timestamp without time zone, iscarto boolean) OWNER TO postgres;

--
-- TOC entry 2518 (class 1255 OID 95448)
-- Name: urbo_parking_append_day(text, text, text, text, boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_parking_append_day(id_scope text, id_entity text, kind text, day text, iscarto boolean DEFAULT false) RETURNS record
    LANGUAGE plpgsql
    AS $$
  DECLARE
    _q text;
    _ret json;
    _r record;
  BEGIN

    _q := format('SELECT urbo_parking_status_day(%s, %s, %s, %s, ''%s'') AS row',
      quote_literal(id_scope),
      quote_literal(id_entity),
      quote_literal(kind),
      quote_literal(day),
      iscarto);


    EXECUTE _q INTO _ret;
    -- RAISE NOTICE '%', _ret;

    EXECUTE format('SELECT urbo_parking_insert_day_row(%s)', quote_literal(_ret)) INTO _r;
    return _r;


  END;
  $$;


ALTER FUNCTION public.urbo_parking_append_day(id_scope text, id_entity text, kind text, day text, iscarto boolean) OWNER TO postgres;

--
-- TOC entry 2516 (class 1255 OID 95446)
-- Name: urbo_parking_append_hour(text, text, text, text, boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_parking_append_hour(id_scope text, id_entity text, kind text, hour text, iscarto boolean DEFAULT false) RETURNS record
    LANGUAGE plpgsql
    AS $$
  DECLARE
    _q text;
    _ret json;
    _r record;
  BEGIN


    _q := format('SELECT urbo_parking_status_hour(''%s'',''%s'', ''%s'', ''%s'', ''%s'') AS row',
      id_scope, id_entity, kind, hour, iscarto);


    EXECUTE _q INTO _ret;
    -- RAISE NOTICE '%', _ret;

    EXECUTE format('SELECT urbo_parking_insert_hour_row(%s)', quote_literal(_ret::json)) INTO _r;
    return _r;

  END;
  $$;


ALTER FUNCTION public.urbo_parking_append_hour(id_scope text, id_entity text, kind text, hour text, iscarto boolean) OWNER TO postgres;

--
-- TOC entry 2510 (class 1255 OID 95439)
-- Name: urbo_parking_average_rotation_freq(text, text, text, text, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_parking_average_rotation_freq(dbschema text, table_name text, filter text, start text DEFAULT (now() - '2 days'::interval), finish text DEFAULT now()) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
  DECLARE
    lt__1 int :=0;
    lt__2 int :=0;
    lt__4 int :=0;
    lt__8 int :=0;
    lt__24 int :=0;
    lt__48 int :=0;
    _ocuppied int := 0;
    _d record;
    _q text;
    _ret bigint;
    _counting boolean := false;
    _previousTimeInstant int;
    _previousId text := NULL;
    _previousStatus text := 'other';
    _times bigint[];
    _row jsonb;

  BEGIN
    _q := format('
      SELECT distinct ps.id_entity,
        date_trunc(%s, ps."TimeInstant") as "TimeInstant",
        (CASE
          WHEN ps.status != %s THEN %s
          ELSE ps.status
          END
        ) as status,
        (extract(EPOCH FROM ps."TimeInstant")::int) as _timestamp,
        parkings.parkingsite,
        parkings.area
      FROM %I.%I ps JOIN %I.%I p ON ps.id_entity=p.id_entity
      JOIN (
        (SELECT DISTINCT id_entity as parkingsite, "areaServed" as area FROM %s.parking_onstreetparking)
        UNION ALL
        (SELECT DISTINCT id_entity as parkingsite, "areaServed" as area FROM %s.parking_offstreetparking)
        ORDER BY area, parkingsite
        ) AS parkings
      ON parkings.parkingsite=p.refparkingsite
      WHERE ps."TimeInstant">=date_trunc(''minute'', %s::timestamp)
      AND ps."TimeInstant"< date_trunc(''minute'', %s::timestamp)
      AND ps.status IS NOT NULL
      %s
      ORDER BY ps.id_entity, "TimeInstant"',
      quote_literal('minute'),
      quote_literal('occupied'),
      quote_literal('other'),
      quote_ident(dbschema),
      quote_ident(table_name),
      quote_ident(dbschema),
      quote_ident('parking_parkingspot_lastdata'),
      quote_ident(dbschema),
      quote_ident(dbschema),
      quote_literal(start),
      quote_literal(finish),
      convert_from(decode(filter,'base64'), 'UTF-8'));

    -- RAISE NOTICE '%', _q;

    FOR _d in EXECUTE _q
    LOOP


      -- CHECKS when id_entity changes
      IF _previousId IS NOT NULL AND _previousId != _d.id_entity THEN
          -- RAISE NOTICE '%', _d.id_entity;
        _counting := false;
      END IF;

      IF _d.status = 'occupied' THEN
        _counting := true;
        _previousTimeInstant := _d._timestamp;
      ELSE
        IF _counting = true THEN
          _ret := _d._timestamp - _previousTimeInstant;
          _times := (SELECT array_append(_times, _ret));
          IF _ret>=0 AND _ret<3600 THEN
            lt__1 := lt__1 + 1;
          ELSIF _ret>=3600 AND _ret <=3600*2 THEN
            lt__2 := lt__2 + 1;
          ELSIF _ret>=3600*2 AND _ret<=3600*4 THEN
            lt__4 := lt__4 + 1;
          ELSIF _ret>=3600*4 AND _ret<=3600*8 THEN
            lt__8 := lt__8 + 1;
          ELSIF _ret>=3600*8 AND _ret<=3600*24 THEN
            lt__24 := lt__24 + 1;
          ELSE
            lt__48 := lt__48 + 1;
          END IF;
          _counting := false;
        END IF;
      END IF;


      _previousId := _d.id_entity;

    END LOOP;

    -- raise notice '%', _times;

    _row := json_build_object(
      'avg', (SELECT array_avg(_times))::int,
      'lt__1', lt__1,
      'lt__2', lt__2,
      'lt__4', lt__4,
      'lt__8', lt__8,
      'lt__24', lt__24,
      'lt__48', lt__48
      );

    RETURN _row;

  END;
  $$;


ALTER FUNCTION public.urbo_parking_average_rotation_freq(dbschema text, table_name text, filter text, start text, finish text) OWNER TO postgres;

--
-- TOC entry 2517 (class 1255 OID 95447)
-- Name: urbo_parking_insert_day_row(json); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_parking_insert_day_row(data json) RETURNS record
    LANGUAGE plpgsql
    AS $$
  DECLARE
    _q text;
    _r record;
    _table_name text := 'parking_onstreetparking_agg_day';
  BEGIN

    IF data::json->>'kind'='parking.offstreet' THEN
      _table_name := 'parking_offstreetparking_agg_day';
    END IF;

    _table_name = urbo_get_table_name(data::json->>'id_scope', _table_name, (data::json->>'iscarto')::boolean);
    IF data::json->>'available' IS NOT NULL AND data::json->>'total' IS NOT NULL THEN
      _q := format('INSERT INTO %s ("TimeInstant", id_entity, available, total)
          VALUES (%s, %s, %s::numeric, %s::numeric) RETURNING *',
        _table_name,
        quote_literal(data::json->>'TimeInstant'),
        quote_literal(data::json->>'id_entity'),
        quote_literal(data::json->>'available'),
        quote_literal(data::json->>'total'));

      -- raise notice 'INSERTING DAY % FOR %', data::json->>'TimeInstant', data::json->>'id_entity';
      EXECUTE _q INTO _r;
    END IF;
    RETURN _r;
  END;
  $$;


ALTER FUNCTION public.urbo_parking_insert_day_row(data json) OWNER TO postgres;

--
-- TOC entry 2515 (class 1255 OID 95445)
-- Name: urbo_parking_insert_hour_row(json); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_parking_insert_hour_row(data json) RETURNS record
    LANGUAGE plpgsql
    AS $$
  DECLARE
    _q text;
    _r record;
    _table_name text := 'parking_onstreetparking_agg_hour';
  BEGIN

    IF data::json->>'kind'='parking.offstreet' THEN
      _table_name := 'parking_offstreetparking_agg_hour';
    END IF;

    _table_name = urbo_get_table_name(data::json->>'id_scope', _table_name, (data::json->>'iscarto')::boolean);
    IF data::json->>'available' IS NOT NULL AND data::json->>'total' IS NOT NULL THEN
      _q := format('INSERT INTO %s ("TimeInstant", id_entity, available, total)
          VALUES (%s, %s, %s::numeric, %s::numeric) RETURNING *',
        _table_name,
        quote_literal(data::json->>'TimeInstant'),
        quote_literal(data::json->>'id_entity'),
        quote_literal(data::json->>'available'),
        quote_literal(data::json->>'total'));

      -- raise notice 'INSERTING DAY % FOR %', data::json->>'TimeInstant', data::json->>'id_entity';
      EXECUTE _q INTO _r;
    END IF;
    RETURN _r;
  END;
  $$;


ALTER FUNCTION public.urbo_parking_insert_hour_row(data json) OWNER TO postgres;

--
-- TOC entry 2511 (class 1255 OID 95440)
-- Name: urbo_parking_status(text, text, text, boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_parking_status(id_scope text, id_entity text, kind text DEFAULT 'parking.offstreet'::text, iscarto boolean DEFAULT false) RETURNS json
    LANGUAGE plpgsql
    AS $$
  DECLARE
    _table_name text;
    _q text;
    _r record;
    _gr record;
    _total integer;
    _available integer;
    _i integer;
  BEGIN

    IF kind='parking.offstreet' THEN
      _table_name = urbo_get_table_name(id_scope,'parking_offstreetparking',iscarto,true);
    ELSE
      _table_name = urbo_get_table_name(id_scope,'parking_onstreetparking',iscarto,true);
    END IF;

    _q = format('SELECT totalspotnumber as total,availablespotnumber as available,
          occupancydetectiontype as dt
          FROM %s WHERE id_entity=%s',
          _table_name,
          quote_literal(id_entity));

    EXECUTE _q INTO _r;

    -- raise notice '%', _r;

    IF _r is null THEN
      -- Parking not found
      RETURN null;
    END IF;

    IF 'singleSpaceDetection' != ANY(_r.dt) THEN
      _q := format('
        SELECT SUM(availablespotnumber) AS available FROM %s
        WHERE refparkingsite=''%s'' GROUP BY id_entity',
        urbo_get_table_name(id_scope,'parking_parkinggroup',iscarto,true),
        id_entity);
      EXECUTE _q into _gr;

      IF _gr is NULL THEN
        -- Return only if no groups for parking
        -- raise notice 'NO GROUP';
        RETURN json_build_object('available',_r.available,'total',_r.total);

      ELSE
        -- raise notice 'AVAILABLE SUM: %', _gr.available;
        RETURN json_build_object('available',_gr.available,'total',_r.total);
      END IF;
    ELSE

      -- `_total` was `0`
      _total = _r.total;
      _available = 0;

      -- Check the parking spots

      -- 1. Plazas de los parking groups que tengan singleSpaceDetection
      -- Available
      _q = format('SELECT count(*) FROM %s a
            INNER JOIN %s b ON b.refparkinggroup=a.id_entity
            WHERE a.refparkingsite=%s AND a.occupancydetectiontype=''singleSpaceDetection'' AND b.status=''free''',
            urbo_get_table_name(id_scope,'parking_parkinggroup',iscarto,true),
            urbo_get_table_name(id_scope,'parking_parkingspot',iscarto,true),
            quote_literal(id_entity));
      EXECUTE _q INTO _i;
      _available = _available + _i;

      -- Total  -- COMMENTED BECAUSE `_total` is now `_r.total`
      -- _q = format('SELECT count(*) FROM %s a
      --       INNER JOIN %s b ON b.refparkinggroup=a.id_entity
      --       WHERE a.refparkingsite=%s AND a.occupancydetectiontype=''singleSpaceDetection''
      --         AND b.status in (''occupied'',''unknown'')',
      --       urbo_get_table_name(id_scope,'parking_parkinggroup',iscarto,true),
      --       urbo_get_table_name(id_scope,'parking_parkingspot',iscarto,true),
      --       quote_literal(id_entity));
      -- EXECUTE _q INTO _i;
      -- _total = _total + _i;
      -- RAISE NOTICE 'Parking groups singleSpaceDetection: %/%',_total,_available;

      -- 2. Plazas de los parking groups que no tengan singleSpaceDetection
      -- _q = format('SELECT COALESCE(SUM(totalspotnumber),0) as total,  -- COMMENTED BECAUSE `_total` is now `_r.total`
      _q = format('SELECT COALESCE(SUM(availablespotnumber),0) as available
            FROM %s WHERE refparkingsite=%s AND occupancydetectiontype!=''singleSpaceDetection''',
            urbo_get_table_name(id_scope,'parking_parkinggroup',iscarto,true),
            quote_literal(id_entity));
      EXECUTE _q INTO _r;
      -- _total = _total + _r.total;  -- COMMENTED BECAUSE `_total` is now `_r.total`
      _available = _available + _r.available;
      -- WOULB BE BETTER TO DO THE PREVIOUS EXECUTE INTO `_i` INSTEAD OF `_r`?
      -- RAISE NOTICE 'Parking groups NO singleSpaceDetection: %/%',_total,_available;

      -- 3. Plazas de los spots que no tengan parking groups
      _q = format('SELECT count(*) FROM %s
            WHERE refparkingsite=%s AND refparkinggroup is NULL AND status=''free''',
            urbo_get_table_name(id_scope,'parking_parkingspot',iscarto,true),
            quote_literal(id_entity));
      EXECUTE _q INTO _i;
      _available = _available + _i;

      -- Total  -- COMMENTED BECAUSE `_total` is now `_r.total`
      -- _q = format('SELECT count(*) FROM %s
      --       WHERE refparkingsite=%s AND refparkinggroup is NULL
      --           AND status in (''occupied'',''unknown'')',
      --       urbo_get_table_name(id_scope,'parking_parkingspot',iscarto,true),
      --       quote_literal(id_entity));
      -- EXECUTE _q INTO _i;
      -- _total = _total + _i;
      -- RAISE NOTICE 'No parking groups: %/%',_total,_available;

      return json_build_object('available',_available,'total',_total);
      RETURN null;

    END IF;
    RETURN NULL;

  END;
  $$;


ALTER FUNCTION public.urbo_parking_status(id_scope text, id_entity text, kind text, iscarto boolean) OWNER TO postgres;

--
-- TOC entry 2514 (class 1255 OID 95444)
-- Name: urbo_parking_status_day(text, text, text, text, boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_parking_status_day(id_scope text, id_entity text, kind text, day text, iscarto boolean DEFAULT false) RETURNS json
    LANGUAGE plpgsql
    AS $$
  DECLARE
    _start text;
    _finish text;
    _q text;
    _ret json;
  BEGIN

    _start := (SELECT date_trunc('minute', day::timestamp));
    _finish := _start::timestamp + '1 DAY'::interval;

    _q := format('SELECT urbo_parking_status_historic(%s, %s, %s, %s, %s, ''%s'') AS row',
      quote_literal(id_scope),
      quote_literal(id_entity),
      quote_literal(kind),
      quote_literal(_start),
      quote_literal(_finish),
      iscarto);

      -- RAISE NOTICE '%', _q;
      EXECUTE _q INTO _ret;

      RETURN json_build_object(
        'id_scope', id_scope,
        'id_entity', id_entity,
        'kind', kind,
        'available', _ret::json->>'available',
        'total', _ret::json->>'total',
        'TimeInstant', _start,
        'iscarto', iscarto
      );
  END;
  $$;


ALTER FUNCTION public.urbo_parking_status_day(id_scope text, id_entity text, kind text, day text, iscarto boolean) OWNER TO postgres;

--
-- TOC entry 2512 (class 1255 OID 95441)
-- Name: urbo_parking_status_historic(text, text, text, text, text, boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_parking_status_historic(id_scope text, id_entity text, kind text DEFAULT 'parking.offstreet'::text, start text DEFAULT (now() - '01:00:00'::interval), finish text DEFAULT now(), iscarto boolean DEFAULT false) RETURNS json
    LANGUAGE plpgsql
    AS $$
  DECLARE
    _table_name text;
    _q text;
    _r record;
    _gr record;
    _total integer;
    _available integer;
    _i integer;
    _join text;
    _pk_available text;
    _pk text;
    _group_table text;
    _group_table_last text;
    _group_available_table text;
    _spot_table text;
    _spot_table_last text;
    _spot_status_table text;
    _parkinglast_table text;
    _ts text;
    _detec text[];
  BEGIN

    -- No group parkings
    IF kind='parking.offstreet' THEN

      _pk = urbo_get_table_name(id_scope, 'parking_offstreetparking', iscarto, false);
      _pk_available = urbo_get_table_name(id_scope, 'parking_offstreetparking_availablespotnumber', iscarto, false);
      _parkinglast_table = urbo_get_table_name(id_scope, 'parking_offstreetparking',iscarto, true);

    ELSE

       _pk = urbo_get_table_name(id_scope, 'parking_onstreetparking', iscarto, false);
      _pk_available = urbo_get_table_name(id_scope, 'parking_onstreetparking_availablespotnumber', iscarto, false);
      _parkinglast_table = urbo_get_table_name(id_scope, 'parking_onstreetparking',iscarto, true);

    END IF;

      _group_available_table = urbo_get_table_name(id_scope, 'parking_parkinggroup_availablespotnumber', iscarto, false);
      _group_table = urbo_get_table_name(id_scope, 'parking_parkinggroup', iscarto, false);
      _group_table_last = urbo_get_table_name(id_scope, 'parking_parkinggroup', iscarto, true);
      _spot_table = urbo_get_table_name(id_scope, 'parking_parkingspot', iscarto, false);
      _spot_status_table = urbo_get_table_name(id_scope, 'parking_parkingspot_status', iscarto, false);
      _spot_table_last = urbo_get_table_name(id_scope, 'parking_parkingspot', iscarto, true);


    _table_name := format('
            %s m JOIN
            %s a ON m.id_entity=a.id_entity
              WHERE true
              AND m.refparkinggroup = ARRAY[]::text[]
              AND ''singleSpaceDetection'' != ANY(m.occupancydetectiontype)
              AND m.id_entity=''%s''
              AND m."TimeInstant" = (SELECT MAX("TimeInstant") FROM %s WHERE "TimeInstant" <= ''%s'' AND id_entity=m.id_entity)
              AND a."TimeInstant" >=
              coalesce(
                (SELECT MIN("TimeInstant") FROM %s WHERE "TimeInstant" >= ''%s'' AND "TimeInstant" < ''%s'' AND id_entity=a.id_entity),
                (SELECT MAX("TimeInstant") FROM %s WHERE "TimeInstant" < ''%s'' AND id_entity=a.id_entity))
              AND a."TimeInstant" < ''%s''',
              _pk, _pk_available, id_entity,
              _pk, finish,
              _pk_available, start, _pk_available, finish, start, finish);



    _ts := format('
            SELECT DISTINCT date_trunc(''minute'', a."TimeInstant") as "TimeInstant"
            FROM %s a JOIN %s m
            ON a.id_entity = m.id_entity
            WHERE a."TimeInstant" >=
              coalesce(
                (SELECT MIN("TimeInstant") FROM %s WHERE "TimeInstant" >= ''%s'' AND "TimeInstant" < ''%s'' AND id_entity=a.id_entity),
                (SELECT MAX("TimeInstant") FROM %s WHERE "TimeInstant" < ''%s'' AND id_entity=a.id_entity))
            AND a."TimeInstant" < ''%s''
            AND m.refparkinggroup = ARRAY[]::text[]
            AND ''singleSpaceDetection'' != ANY(m.occupancydetectiontype)
            AND m.id_entity=''%s''
            ORDER BY "TimeInstant"',
            _pk_available, _parkinglast_table,
            _pk_available, start, finish,
            _pk_available, finish,
             finish, id_entity);

    EXECUTE _ts INTO _r;
    -- raise notice '%', _r;

    _q = format('
        WITH timeserie AS (
          %s
        ),
        dataserie AS (
          SELECT DISTINCT
            t."TimeInstant",
            AVG(a.availablespotnumber) as availablespotnumber,
            totalspotnumber
          FROM %s m JOIN %s a ON m.id_entity=a.id_entity JOIN
          timeserie t
          ON a."TimeInstant" >=
            coalesce(
                (SELECT MIN("TimeInstant") FROM %s
                WHERE "TimeInstant" >= t."TimeInstant"
                AND "TimeInstant" < t."TimeInstant" + ''1 minute''::interval
                AND id_entity=m.id_entity),
                (SELECT MAX("TimeInstant")
                  FROM %s
                  WHERE "TimeInstant" < t."TimeInstant" + ''1 minute''::interval
                  AND id_entity=m.id_entity)
            )
          AND a."TimeInstant" < (t."TimeInstant" + ''1 minute''::interval)
          WHERE m.refparkinggroup = ARRAY[]::text[]
          AND totalspotnumber!=''-1''
          AND ''singleSpaceDetection'' != ANY(m.occupancydetectiontype)
          AND m.id_entity=''%s''
          GROUP BY t."TimeInstant", m.totalspotnumber
        )
        SELECT DISTINCT
          totalspotnumber as total,
          AVG(availablespotnumber)::int AS available
        FROM dataserie GROUP BY totalspotnumber',
        _ts,
        _pk, _pk_available,
        _pk_available, _pk_available,
        id_entity);


    EXECUTE _q INTO _r;
    IF _r is NOT null THEN
      -- Parking not found
      RETURN json_build_object('available', _r.available, 'total', _r.total);
    END IF;



    _q := format('SELECT totalspotnumber as total, occupancydetectiontype as dt FROM %s WHERE id_entity=''%s''',
        _parkinglast_table, id_entity);
    EXECUTE _q into _r;

    -- raise notice '%', _r;

    -- raise notice 'not single space detected Groups only';

    _detec = _r.dt;




    _ts := format('
            SELECT DISTINCT date_trunc(''minute'', a."TimeInstant") as "TimeInstant"
            FROM %s a JOIN %s pg
            ON a.id_entity = pg.id_entity
            WHERE a."TimeInstant" >=
              coalesce(
                (SELECT MIN("TimeInstant") FROM %s WHERE "TimeInstant" >= ''%s'' AND "TimeInstant" < ''%s'' AND id_entity=a.id_entity),
                (SELECT MAX("TimeInstant") FROM %s WHERE "TimeInstant" < ''%s'' AND id_entity=a.id_entity))
            AND a."TimeInstant" < ''%s''
            AND pg.refparkingsite=''%s''
            AND pg.occupancydetectiontype!=''singleSpaceDetection''
            ORDER BY "TimeInstant"',
            _group_available_table, _group_table_last,
            _group_available_table, start, finish,
            _group_available_table, finish,
             finish, id_entity);


      -- raise notice '%', _ts;

    _q := format('
      WITH timeserie AS (
        %s
        ),
      dataserie AS (
        SELECT DISTINCT
          t."TimeInstant",
          a.id_entity,
          AVG(a.availablespotnumber) as available,
          SUM(pg.totalspotnumber) as total
        FROM %s a
        JOIN %s pg ON a.id_entity=pg.id_entity
        JOIN timeserie t
        ON a."TimeInstant" >=
          coalesce(
              (SELECT MIN("TimeInstant") FROM %s WHERE "TimeInstant" >= t."TimeInstant" AND "TimeInstant" < t."TimeInstant" + ''1 minute''::interval AND id_entity=pg.id_entity),
              (SELECT MAX("TimeInstant") FROM %s WHERE "TimeInstant" < t."TimeInstant" + ''1 minute''::interval AND id_entity=pg.id_entity)
          )
        AND a."TimeInstant" < (t."TimeInstant" + ''1 minute''::interval)
        WHERE pg.refparkingsite=''%s''
        AND pg.occupancydetectiontype!=''singleSpaceDetection''
        AND pg.totalspotnumber!=''-1''
        GROUP BY t."TimeInstant", a.id_entity
      ),
      _pre AS (select id_entity, AVG(available) as available from dataserie GROUP BY id_entity)
      SELECT SUM(available)::int as available FROM _pre',
      _ts,
      _group_available_table, _group_table_last,
      _group_available_table,
      _group_available_table,
      id_entity);

    -- raise notice '%', _q;
    EXECUTE _q into _gr;

    -- RAISE NOTICE '%', _gr;

    -- RAISE notice 'Just before';

    IF 'singleSpaceDetection' != ANY(_detec) THEN
      -- No more groups, stop counting
      RETURN json_build_object('available',coalesce(_gr.available, _r.total), 'total', _r.total);

    ELSE
      -- _available = _total;
      _total = _r.total;

      -- raise notice 'The real deal %/%', _available, _total;

      -- Check the parking spots

      -- 1. Plazas de los parking groups que tengan singleSpaceDetection o de los que no tengan parking group
      -- Available


      _q = format('
          WITH timeserie AS (
            SELECT DISTINCT date_trunc(''minute'', s."TimeInstant") as "TimeInstant"
            FROM %s s JOIN %s p
            ON s.id_entity = p.id_entity
            WHERE s."TimeInstant" >=
              (SELECT MAX("TimeInstant") FROM %s
                  WHERE id_entity=p.id_entity AND "TimeInstant" < ''%s''
                  AND (status=''free'' OR status=''closed'')
                  )
            AND s."TimeInstant" < ''%s''
            AND (p.refparkinggroup IS NULL OR p.refparkinggroup IN (SELECT DISTINCT id_entity FROM %s WHERE occupancydetectiontype=''singleSpaceDetection''))
            AND (s.status=''free'' OR s.status=''closed'')
            AND p.refparkingsite=''%s''
            ORDER BY "TimeInstant"
          ),
          dataserie AS (
            SELECT DISTINCT
              t."TimeInstant",
              count(s.id_entity) as available
            FROM %s s JOIN %s p ON s.id_entity=p.id_entity JOIN
            timeserie t
            ON s."TimeInstant" >=
              (CASE
                WHEN NOT EXISTS (SELECT DISTINCT "TimeInstant"
                  FROM %s
                  WHERE "TimeInstant" >= t."TimeInstant"
                  AND "TimeInstant" < t."TimeInstant" + ''1 minute''::interval
                  AND id_entity=s.id_entity)
                THEN
                  (SELECT MAX("TimeInstant")
                    FROM %s
                    WHERE "TimeInstant" < t."TimeInstant" + ''1 minute''::interval
                    AND id_entity=s.id_entity)
                ELSE t."TimeInstant"
              END)
            AND s."TimeInstant" < (t."TimeInstant" + ''1 minute''::interval)
            WHERE (s.status=''free'' OR s.status=''closed'')
            AND p.refparkingsite=''%s''
            AND (p.refparkinggroup is NULL OR p.refparkinggroup IN (SELECT DISTINCT id_entity FROM %s WHERE occupancydetectiontype=''singleSpaceDetection''))
            GROUP BY t."TimeInstant"
          )
          SELECT DISTINCT AVG(available) as available FROM dataserie',
          _spot_status_table, _spot_table_last, _spot_status_table, start, finish, _group_table_last, id_entity,
          _spot_status_table, _spot_table_last, _spot_status_table,
          _spot_status_table,
          id_entity,
          _group_table_last);

      -- raise notice 'Alone and with single detection group spots: %', _q;

      EXECUTE _q INTO _i;


      IF _gr.available IS NULL AND _i IS NULL THEN
        RETURN json_build_object('available',_total, 'total',_r.total);
      ELSIF _gr.available IS NULL AND _i IS NOT NULL THEN
        RETURN json_build_object('available',_i, 'total',_r.total);
      ELSIF _gr.available IS NOT NULL AND _i IS NULL THEN
        RETURN json_build_object('available',_gr.available + (_r.total - _gr.total), 'total',_r.total);
      ELSIF _gr.available IS NOT NULL AND _i IS NOT NULL THEN
        RETURN json_build_object('available',_i + _gr.available, 'total',_r.total);
      END IF;

    END IF;
    RETURN NULL;
  END;
  $$;


ALTER FUNCTION public.urbo_parking_status_historic(id_scope text, id_entity text, kind text, start text, finish text, iscarto boolean) OWNER TO postgres;

--
-- TOC entry 2513 (class 1255 OID 95443)
-- Name: urbo_parking_status_hour(text, text, text, text, boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_parking_status_hour(id_scope text, id_entity text, kind text, hour text, iscarto boolean DEFAULT false) RETURNS json
    LANGUAGE plpgsql
    AS $$
  DECLARE
    _start text;
    _finish text;
    _q text;
    _ret json;
  BEGIN

    _start := (SELECT date_trunc('minute', hour::timestamp));
    _finish := _start::timestamp + '1 HOUR'::interval;

    _q := format('SELECT urbo_parking_status_historic(%s, %s, %s, %s, %s, ''%s'') AS row',
      quote_literal(id_scope),
      quote_literal(id_entity),
      quote_literal(kind),
      quote_literal(_start),
      quote_literal(_finish),
      iscarto);

      -- RAISE NOTICE '%', _q;
      EXECUTE _q INTO _ret;

      RETURN json_build_object(
        'id_scope', id_scope,
        'id_entity', id_entity,
        'kind', kind,
        'available', _ret::json->>'available',
        'total', _ret::json->>'total',
        'TimeInstant', _start,
        'iscarto', iscarto
      );
  END;
  $$;


ALTER FUNCTION public.urbo_parking_status_hour(id_scope text, id_entity text, kind text, hour text, iscarto boolean) OWNER TO postgres;

--
-- TOC entry 2440 (class 1255 OID 95362)
-- Name: urbo_pk_qry(text[]); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_pk_qry(_tb_arr text[]) RETURNS text
    LANGUAGE plpgsql
    AS $$
  DECLARE
    _tb text;
    _stm text;
    _pg_pk text;
  BEGIN
    FOREACH _tb IN ARRAY _tb_arr
      LOOP
        _stm = format(
          -- FIXME: IF NOT EXISTS is missing and causes problems with ./cartofunctions.
          -- When all carto accounts are migrated to PG 9.6+, we should add
          -- IF NOT EXISTS
          -- 'ALTER TABLE %s ADD COLUMN IF NOT EXISTS id bigserial NOT NULL;
          'ALTER TABLE %s ADD COLUMN id bigserial NOT NULL;
           ALTER TABLE ONLY %s
               ADD CONSTRAINT %s_pk PRIMARY KEY (id);',
          _tb, _tb, replace(_tb, '.', '_')
        );
        _pg_pk = concat(_pg_pk, _stm);
      END LOOP;

    RETURN _pg_pk;

  END;
  $$;


ALTER FUNCTION public.urbo_pk_qry(_tb_arr text[]) OWNER TO postgres;

--
-- TOC entry 2429 (class 1255 OID 95351)
-- Name: urbo_size_scope(character varying, character varying, boolean, boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_size_scope(id_scope character varying, vertical character varying, iscarto boolean DEFAULT false, vacuum boolean DEFAULT false) RETURNS SETOF json
    LANGUAGE plpgsql
    AS $$
  DECLARE
    _r RECORD;
    _t varchar;
    _q varchar;
  BEGIN
    _q = format('SELECT table_name from information_schema.tables WHERE table_schema=%L AND table_name like ''%s_%s'' ORDER BY table_name',id_scope,vertical,'%');
    FOR _t IN EXECUTE _q LOOP
      RETURN NEXT json_build_object(_t, urbo_size_table_row(id_scope,_t)::integer);
    END LOOP;
    RETURN;
  END;
  $$;


ALTER FUNCTION public.urbo_size_scope(id_scope character varying, vertical character varying, iscarto boolean, vacuum boolean) OWNER TO postgres;

--
-- TOC entry 2430 (class 1255 OID 95352)
-- Name: urbo_size_scope_pretty(text, text, text, boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_size_scope_pretty(schemaname text, category text, id_scope text DEFAULT NULL::text, iscarto boolean DEFAULT false) RETURNS SETOF json
    LANGUAGE plpgsql
    AS $$
  DECLARE
    _tb text;
    _tb_prefix text;
  BEGIN
    IF iscarto IS TRUE then
      _tb_prefix = format('%s_%s',id_scope,category);
    ELSE
      _tb_prefix = format('%s',category);
    END IF;

    FOR _tb IN EXECUTE format('SELECT table_name
          FROM   information_schema.tables
          WHERE  table_schema = %L
          AND    table_name LIKE ''%s%%'' ',
          schemaname, _tb_prefix)
      LOOP
        RETURN NEXT json_build_object(
          'tot_sz',pg_size_pretty(pg_total_relation_size(format('%I.%s',schemaname, _tb))),
          'tab_szr',pg_size_pretty(pg_relation_size(format('%I.%s',schemaname, _tb))),
          'table',_tb
        );

      END LOOP;

  END;
  $$;


ALTER FUNCTION public.urbo_size_scope_pretty(schemaname text, category text, id_scope text, iscarto boolean) OWNER TO postgres;

--
-- TOC entry 2428 (class 1255 OID 95350)
-- Name: urbo_size_table_row(character varying, character varying, boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_size_table_row(id_scope character varying, table_name character varying, iscarto boolean DEFAULT false) RETURNS numeric
    LANGUAGE plpgsql
    AS $$
  DECLARE
    _t varchar;
    _n numeric;
    _total numeric;
  BEGIN
    _t = urbo_get_table_name(id_scope,table_name,iscarto);
    EXECUTE format('select count(*) from %s',_t) into _n;
    IF _n = 0 THEN
      RETURN _n;
    END IF;
    EXECUTE format('select pg_total_relation_size(%L)',_t) into _total;
    RETURN _total / _n;
  END;
  $$;


ALTER FUNCTION public.urbo_size_table_row(id_scope character varying, table_name character varying, iscarto boolean) OWNER TO postgres;

--
-- TOC entry 2423 (class 1255 OID 92789)
-- Name: urbo_solenoidvalve_histogramclasses(regclass, text, timestamp without time zone, timestamp without time zone, integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_solenoidvalve_histogramclasses(table_name regclass, vid_entity text, start timestamp without time zone, finish timestamp without time zone, classstep integer) RETURNS integer
    LANGUAGE plpgsql
    AS $_$
  DECLARE
    psecs real;
    tsecs real;
    date_reg timestamp;
    date_dur timestamp;
    d record;
    _sql text;
  BEGIN
    tsecs := 0;

    EXECUTE format('
      SELECT 1 FROM %1$I
      WHERE id_entity = %2$s
      AND "TimeInstant" BETWEEN %3$L AND %4$L
      AND status = 1
    ', table_name, vid_entity, start, finish)
    INTO d;

    IF NOT EXISTS d THEN
      return tsecs;
    END IF;

    FOR d IN
    EXECUTE format('
      SELECT status, "TimeInstant"
      FROM %1$I
      WHERE id_entity = %2$s
      AND "TimeInstant" BETWEEN %3$L AND %4$L
    ', table_name, vid_entity, start, finish)
    LOOP
      -- raise notice '%',d;

      IF d.status = 1 THEN
        date_reg := d."TimeInstant";
      ELSE
        IF d.status = 0 THEN
          date_dur := d."TimeInstant";
          psecs := (SELECT extract(epoch FROM age(date_dur,date_reg)));
          tsecs := tsecs + psecs;
          -- raise notice '%',psecs;
        END if;
      END if;

    END LOOP;

    tsecs := tsecs / 60;

    IF tsecs = 0 THEN
      return 0;
    ELSIF tsecs < (classstep) THEN
      return classstep;
    ELSIF tsecs < (classstep * 2) THEN
      return classstep * 2;
    ELSIF tsecs < (classstep * 3) THEN
      return classstep * 3;
    ELSIF tsecs < (classstep * 4) THEN
      return classstep * 4;
    ELSE
      return classstep * 5;
    END if;

  END;
  $_$;


ALTER FUNCTION public.urbo_solenoidvalve_histogramclasses(table_name regclass, vid_entity text, start timestamp without time zone, finish timestamp without time zone, classstep integer) OWNER TO postgres;

--
-- TOC entry 2441 (class 1255 OID 95363)
-- Name: urbo_tbowner_qry(text[], text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_tbowner_qry(_tb_arr text[], _tb_owner text DEFAULT 'urbo_admin'::text) RETURNS text
    LANGUAGE plpgsql
    AS $$
  DECLARE
    _tb text;
    _stm text;
    _pg_tbowner text;
  BEGIN
    FOREACH _tb IN ARRAY _tb_arr
      LOOP
        _stm = format(
          'ALTER TABLE %s OWNER TO %s;',
          _tb, _tb_owner
        );
        _pg_tbowner = concat(_pg_tbowner, _stm);
      END LOOP;

    RETURN _pg_tbowner;

  END;
  $$;


ALTER FUNCTION public.urbo_tbowner_qry(_tb_arr text[], _tb_owner text) OWNER TO postgres;

--
-- TOC entry 2484 (class 1255 OID 95409)
-- Name: urbo_threshold_calculation(text, text, text, text, timestamp without time zone, timestamp without time zone, interval, boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_threshold_calculation(id_scope text, table_name text, id_variable text, id_entity text, start timestamp without time zone, finish timestamp without time zone, _range interval DEFAULT '01:00:00'::interval, iscarto boolean DEFAULT false) RETURNS numeric
    LANGUAGE plpgsql
    AS $$
  DECLARE
    _table text;
    _tablelast text;
    _q text;
    _r record;
    _start timestamp DEFAULT start;
    _finish timestamp DEFAULT finish;
    _counting boolean DEFAULT false;
  BEGIN
    _table = urbo_get_table_name(id_scope, table_name, iscarto);
    _tablelast = urbo_get_table_name(id_scope, table_name, iscarto, true);

    -- -- First checks if finish - start > _range
    -- _q := format('SELECT (age(date_trunc(''second'', ''%s''::timestamp), date_trunc(''second'', ''%s''::timestamp)) >= ''%s'') as int', finish, start, _range);
    -- EXECUTE _q INTO _r;
    -- if _r.int is false THEN
    --   RETURN false;
    -- END IF;

    _q := format('
      SELECT
      MIN("TimeInstant") as ts
      FROM %s
      WHERE id_entity=''%s''
      AND "TimeInstant" >= (''%s''::timestamp - ''%s''::interval)::timestamp',
      _table, id_entity, finish, _range);

    EXECUTE _q INTO _r;

    IF _r IS NOT NULL THEN
      _finish = _r.ts;
      _start = start - (finish - _finish)::interval;
    END IF;

    -- raise notice '% %', finish, _finish;

    -- WITH WINDOW FUNCTION
    _q = format('
      SELECT MAX(value) as value
      FROM
      (
        SELECT DISTINCT
          AVG(d.%s) OVER (PARTITION BY timeserie.ts) as value
        FROM %s d
        JOIN (
          SELECT DISTINCT
            date_trunc(''minute'', "TimeInstant") as ts
          FROM %s WHERE "TimeInstant">= date_trunc(''minute'', ''%s''::timestamp)
          AND "TimeInstant" < (''%s''::timestamp + ''1 second''::interval)::timestamp
          AND id_entity=''%s''
          ORDER BY ts
        ) timeserie
        ON d."TimeInstant" >= timeserie.ts AND d."TimeInstant" < (timeserie.ts::timestamp + ''%s''::interval)::timestamp
        WHERE id_entity=''%s''

      ) AS foo',
      id_variable, _table,
      _table, _start, _finish,
      id_entity,
      _range, id_entity);


    -- raise notice '%', _q;

    EXECUTE _q INTO _r;
    RETURN _r.value;

    EXCEPTION WHEN undefined_column THEN RETURN -1;

  END;
  $$;


ALTER FUNCTION public.urbo_threshold_calculation(id_scope text, table_name text, id_variable text, id_entity text, start timestamp without time zone, finish timestamp without time zone, _range interval, iscarto boolean) OWNER TO postgres;

--
-- TOC entry 2442 (class 1255 OID 95364)
-- Name: urbo_time_idx_qry(text[]); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_time_idx_qry(_tb_arr text[]) RETURNS text
    LANGUAGE plpgsql
    AS $$
  DECLARE
    _tb text;
    _stm text;
    _time_idx text;
  BEGIN
    FOREACH _tb IN ARRAY _tb_arr
      LOOP
        _stm = format(
          'ALTER TABLE ONLY %s
              ADD CONSTRAINT %s_unique UNIQUE (id_entity, "TimeInstant");

          CREATE INDEX IF NOT EXISTS %s_tm_idx
              ON %s USING btree ("TimeInstant");',
          _tb, replace(_tb, '.', '_'), replace(_tb, '.', '_'), _tb
        );
        _time_idx = concat(_time_idx, _stm);
      END LOOP;

    RETURN _time_idx;

  END;
  $$;


ALTER FUNCTION public.urbo_time_idx_qry(_tb_arr text[]) OWNER TO postgres;

--
-- TOC entry 2522 (class 1255 OID 95453)
-- Name: urbo_transport_people_observatory(character varying, character varying, character varying); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_transport_people_observatory(id_scope character varying, the_geom character varying, id_entity character varying) RETURNS record
    LANGUAGE plpgsql
    AS $$
  DECLARE
    _q text;
    _ret record;
  BEGIN


        -- DELETE FROM malaga_transport_bikehiredockingstation_obs;
        -- INSERT INTO malaga_transport_bikehiredockingstation_obs (density, people, id_entity)
        --   ( SELECT
        --       OBS_GetMeasure(the_geom, 'es.ine.t1_1') AS density,
        --       OBS_GetMeasure(the_geom, 'es.ine.t1_1') * 0.12566368 AS people,
        --       id_entity
        --     FROM malaga_transport_bikehiredockingstation_lastdata)



    _q := format(
        'INSERT INTO %s_transport_bikehiredockingstation_obs (people, id_entity) VALUES
          (OBS_GetMeasure(st_transform(st_buffer(st_transform(''%s'',25830),200), 3857),''es.ine.t1_1''),
          ''%s'') ', id_scope, the_geom, id_entity);

    raise notice '%', _q;
    EXECUTE _q INTO _ret;
    return _ret;

  END;
  $$;


ALTER FUNCTION public.urbo_transport_people_observatory(id_scope character varying, the_geom character varying, id_entity character varying) OWNER TO postgres;

--
-- TOC entry 2415 (class 1255 OID 23039)
-- Name: urbo_unique_lastdata_qry(text[]); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_unique_lastdata_qry(_tb_arr text[]) RETURNS text
    LANGUAGE plpgsql
    AS $$
  DECLARE
    _tb text;
    _stm text;
    _unique_ld text;
  BEGIN
    FOREACH _tb IN ARRAY _tb_arr
      LOOP
        _stm = format(
          'ALTER TABLE ONLY %s
              ADD CONSTRAINT %s_ld_unique UNIQUE (id_entity);',
          _tb, replace(_tb, '.', '_')
        );
        _unique_ld = concat(_unique_ld, _stm);
      END LOOP;

    RETURN _unique_ld;

  END;
  $$;


ALTER FUNCTION public.urbo_unique_lastdata_qry(_tb_arr text[]) OWNER TO postgres;

--
-- TOC entry 2420 (class 1255 OID 52799)
-- Name: urbo_water_quality_consumption(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_water_quality_consumption() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
  DECLARE
    _tb_nm text;
    _q text;
    _iscarto boolean;
    _ret record;
  BEGIN

    -- Lastdata
    IF TG_OP = 'UPDATE'  THEN
      IF OLD.vol IS NULL then
        NEW.consumption := 0;
      ELSE
        IF NEW.vol >= OLD.vol then
          NEW.consumption := NEW.vol - OLD.vol;
        ELSE
          NEW.consumption := OLD.consumption;
        END IF;
      END IF;

    -- Historic
    ELSIF TG_OP = 'INSERT' THEN

      _tb_nm = TG_argv[0];

      -- raise notice '%', _tb_nm;

      _q := format('SELECT vol, consumption, "TimeInstant" as time FROM %s WHERE id_entity=''%s'' AND "TimeInstant" < ''%s'' ORDER BY "TimeInstant" DESC LIMIT 1',
        _tb_nm, NEW.id_entity, NEW."TimeInstant"
      );

      EXECUTE _q INTO _ret;

      -- raise notice 'ret %', _ret;
      -- raise notice 'NEW %', NEW;

      IF _ret IS NOT NULL THEN
        IF NEW."TimeInstant" > _ret.time THEN
          NEW.consumption = NEW.vol - _ret.vol;

          -- Recalcular para todas las medidas posteriores ya insertadas
          -- RAISE NOTICE 'CALCULANDO';
          PERFORM urbo_water_quality_consumption_calculate(_tb_nm, NEW.id_entity, NEW."TimeInstant");
        END IF;
      END IF;

    END IF;

    RETURN NEW;

  END;
$$;


ALTER FUNCTION public.urbo_water_quality_consumption() OWNER TO postgres;

--
-- TOC entry 2531 (class 1255 OID 95463)
-- Name: urbo_water_quality_consumption_calculate(text, text, timestamp without time zone, boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_water_quality_consumption_calculate(_table_name text, id_entity text, start timestamp without time zone DEFAULT '1999-01-01 00:00:00'::timestamp without time zone, iscarto boolean DEFAULT false) RETURNS SETOF double precision
    LANGUAGE plpgsql
    AS $$
    DECLARE
      _q text;
      _ret record;
      _old record;
      _counter integer default 0;
      _vol double precision;
      _acc double precision;
      _insertion text;
    BEGIN

      _q := format('SELECT * FROM %s WHERE id_entity=''%s'' AND "TimeInstant" >= ''%s'' ORDER BY "TimeInstant" ASC',
        _table_name, id_entity, start
      );

      -- raise notice '%', _q;

      FOR _ret IN EXECUTE _q LOOP
        IF _counter != 0 THEN
          _acc = _ret.vol - _old.vol;

        ELSE
          _acc = _ret.consumption;
          _ret.consumption = 0;
        END IF;
        _old = _ret;

        _counter = _counter + 1;
        IF _acc IS NOT NULL THEN
          IF iscarto THEN
            _insertion = format('UPDATE %s SET consumption = %s where cartodb_id=%s', _table_name, _acc, _ret.cartodb_id);
          ELSE
            _insertion = format('UPDATE %s SET consumption = %s where id=%s', _table_name, _acc, _ret.id);
          END IF;

          EXECUTE _insertion;
        END IF;

        -- RAISE NOTICE '%', _insertion;
        RETURN NEXT _acc;

      END LOOP;

    END;
  $$;


ALTER FUNCTION public.urbo_water_quality_consumption_calculate(_table_name text, id_entity text, start timestamp without time zone, iscarto boolean) OWNER TO postgres;

--
-- TOC entry 2532 (class 1255 OID 95464)
-- Name: urbo_water_quality_consumption_calculate_shortcut(text, text, timestamp without time zone, boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_water_quality_consumption_calculate_shortcut(id_scope text, id_entity text, start timestamp without time zone DEFAULT '1999-01-01 00:00:00'::timestamp without time zone, iscarto boolean DEFAULT false) RETURNS void
    LANGUAGE plpgsql
    AS $$
    DECLARE
      _q text;
      _tb text;
      _ret record;
    BEGIN
      _tb = urbo_get_table_name(id_scope, 'water_quality', iscarto);
      raise notice '%',  _tb;
      _q = format('SELECT urbo_water_quality_consumption_calculate(''%s'', ''%s'', ''%s'', ''%s'')',
        _tb, id_entity, start, iscarto);

      EXECUTE _q INTO _ret;


    END;
  $$;


ALTER FUNCTION public.urbo_water_quality_consumption_calculate_shortcut(id_scope text, id_entity text, start timestamp without time zone, iscarto boolean) OWNER TO postgres;

--
-- TOC entry 2533 (class 1255 OID 95465)
-- Name: urbo_water_quality_trig(text, boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_water_quality_trig(id_scope text, iscarto boolean DEFAULT false) RETURNS void
    LANGUAGE plpgsql
    AS $$
  DECLARE
    _q text;
    _sep text DEFAULT '.';
  BEGIN

    IF (iscarto) THEN
      _sep = '_';
    END IF;

    _q = format('

      DROP TRIGGER IF EXISTS urbo_water_quality_consumption_changes_ld
        ON %s%swater_quality_lastdata;

      DROP TRIGGER IF EXISTS urbo_water_quality_consumption_changes_ld_%s
        ON %s%swater_quality_lastdata;

      CREATE TRIGGER urbo_water_quality_consumption_changes_ld_%s
        BEFORE UPDATE
        ON %s%swater_quality_lastdata
        FOR EACH ROW
          EXECUTE PROCEDURE urbo_water_quality_consumption(''%s%swater_quality'', ''false'');


      DROP TRIGGER IF EXISTS urbo_water_quality_consumption_changes
        ON %s%swater_quality;

      DROP TRIGGER IF EXISTS urbo_water_quality_consumption_changes_%s
        ON %s%swater_quality;

      CREATE TRIGGER urbo_water_quality_consumption_changes_%s
        BEFORE INSERT
        ON %s%swater_quality
        FOR EACH ROW
          EXECUTE PROCEDURE urbo_water_quality_consumption(''%s%swater_quality'', ''false'');',
      id_scope, _sep,
      id_scope, id_scope, _sep,
      id_scope, id_scope, _sep, id_scope, _sep,
      id_scope, _sep,
      id_scope, id_scope, _sep,
      id_scope, id_scope, _sep, id_scope, _sep
    );

    raise notice '%', _q;

    EXECUTE _q;

  END;
  $$;


ALTER FUNCTION public.urbo_water_quality_trig(id_scope text, iscarto boolean) OWNER TO postgres;

--
-- TOC entry 2416 (class 1255 OID 23040)
-- Name: urbo_watmeter_a_consumption(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_watmeter_a_consumption() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
  DECLARE
    _tb_nm text;
    _q text;
    _iscarto boolean;
    _ret record;
  BEGIN

    -- Lastdata
    IF TG_OP = 'UPDATE'  THEN
      IF OLD.vol IS NULL then
        NEW.consumption := 0;
      ELSE
        IF NEW.vol >= OLD.vol then
          NEW.consumption := NEW.vol - OLD.vol;
        ELSE
          NEW.consumption := OLD.consumption;
        END IF;
      END IF;

    -- Historic
    ELSIF TG_OP = 'INSERT' THEN

      _tb_nm = TG_argv[0];

      -- raise notice '%', _tb_nm;

      _q := format('SELECT vol, consumption, "TimeInstant" as time FROM %s WHERE id_entity=''%s'' AND "TimeInstant" < ''%s'' ORDER BY "TimeInstant" DESC LIMIT 1',
        _tb_nm, NEW.id_entity, NEW."TimeInstant"
      );

      EXECUTE _q INTO _ret;

      -- raise notice 'ret %', _ret;
      -- raise notice 'NEW %', NEW;

      IF _ret IS NOT NULL THEN
        IF NEW."TimeInstant" > _ret.time THEN
          NEW.consumption = NEW.vol - _ret.vol;

          -- Recalcular para todas las medidas posteriores ya insertadas
          -- RAISE NOTICE 'CALCULANDO';
          PERFORM urbo_watmeter_a_consumption_calculate(_tb_nm, NEW.id_entity, NEW."TimeInstant");
        END IF;
      END IF;

    END IF;

    RETURN NEW;

  END;
$$;


ALTER FUNCTION public.urbo_watmeter_a_consumption() OWNER TO postgres;

--
-- TOC entry 2536 (class 1255 OID 95468)
-- Name: urbo_watmeter_a_consumption_calculate(text, text, timestamp without time zone, boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_watmeter_a_consumption_calculate(_table_name text, id_entity text, start timestamp without time zone DEFAULT '1999-01-01 00:00:00'::timestamp without time zone, iscarto boolean DEFAULT false) RETURNS SETOF double precision
    LANGUAGE plpgsql
    AS $$
    DECLARE
      _q text;
      _ret record;
      _old record;
      _counter integer default 0;
      _vol double precision;
      _acc double precision;
      _insertion text;
    BEGIN

      _q := format('SELECT * FROM %s WHERE id_entity=''%s'' AND "TimeInstant" >= ''%s'' ORDER BY "TimeInstant" ASC',
        _table_name, id_entity, start
      );

      -- raise notice '%', _q;

      FOR _ret IN EXECUTE _q LOOP
        IF _counter != 0 THEN
          _acc = _ret.vol - _old.vol;

        ELSE
          _acc = _ret.consumption;
          _ret.consumption = 0;
        END IF;
        _old = _ret;

        _counter = _counter + 1;
        IF _acc IS NOT NULL THEN
          IF iscarto THEN
            _insertion = format('UPDATE %s SET consumption = %s where cartodb_id=%s', _table_name, _acc, _ret.cartodb_id);
          ELSE
            _insertion = format('UPDATE %s SET consumption = %s where id=%s', _table_name, _acc, _ret.id);
          END IF;

          EXECUTE _insertion;
        END IF;

        -- RAISE NOTICE '%', _insertion;
        RETURN NEXT _acc;

      END LOOP;

    END;
  $$;


ALTER FUNCTION public.urbo_watmeter_a_consumption_calculate(_table_name text, id_entity text, start timestamp without time zone, iscarto boolean) OWNER TO postgres;

--
-- TOC entry 2537 (class 1255 OID 95469)
-- Name: urbo_watmeter_a_consumption_calculate_shortcut(text, text, timestamp without time zone, boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_watmeter_a_consumption_calculate_shortcut(id_scope text, id_entity text, start timestamp without time zone DEFAULT '1999-01-01 00:00:00'::timestamp without time zone, iscarto boolean DEFAULT false) RETURNS void
    LANGUAGE plpgsql
    AS $$
    DECLARE
      _q text;
      _tb text;
      _ret record;
    BEGIN
      _tb = urbo_get_table_name(id_scope, 'watmeter_a', iscarto);
      raise notice '%',  _tb;
      _q = format('SELECT urbo_watmeter_a_consumption_calculate(''%s'', ''%s'', ''%s'', ''%s'')',
        _tb, id_entity, start, iscarto);

      EXECUTE _q INTO _ret;


    END;
  $$;


ALTER FUNCTION public.urbo_watmeter_a_consumption_calculate_shortcut(id_scope text, id_entity text, start timestamp without time zone, iscarto boolean) OWNER TO postgres;

--
-- TOC entry 2538 (class 1255 OID 95470)
-- Name: urbo_watmeter_a_trig(text, boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.urbo_watmeter_a_trig(id_scope text, iscarto boolean DEFAULT false) RETURNS void
    LANGUAGE plpgsql
    AS $$
  DECLARE
    _q text;
    _sep text DEFAULT '.';
  BEGIN

    IF (iscarto) THEN
      _sep = '_';
    END IF;

    _q = format('

      DROP TRIGGER IF EXISTS urbo_watmeter_a_consumption_changes_ld
        ON %s%swatmeter_a_lastdata;

      DROP TRIGGER IF EXISTS urbo_watmeter_a_consumption_changes_ld_%s
        ON %s%swatmeter_a_lastdata;

      CREATE TRIGGER urbo_watmeter_a_consumption_changes_ld_%s
        BEFORE UPDATE
        ON %s%swatmeter_a_lastdata
        FOR EACH ROW
          EXECUTE PROCEDURE urbo_watmeter_a_consumption(''%s%swatmeter_a'', ''false'');


      DROP TRIGGER IF EXISTS urbo_watmeter_a_consumption_changes
        ON %s%swatmeter_a;

      DROP TRIGGER IF EXISTS urbo_watmeter_a_consumption_changes_%s
        ON %s%swatmeter_a;

      CREATE TRIGGER urbo_watmeter_a_consumption_changes_%s
        BEFORE INSERT
        ON %s%swatmeter_a
        FOR EACH ROW
          EXECUTE PROCEDURE urbo_watmeter_a_consumption(''%s%swatmeter_a'', ''false'');',
      id_scope, _sep,
      id_scope, id_scope, _sep,
      id_scope, id_scope, _sep, id_scope, _sep,
      id_scope, _sep,
      id_scope, id_scope, _sep,
      id_scope, id_scope, _sep, id_scope, _sep
    );

    raise notice '%', _q;

    EXECUTE _q;

  END;
  $$;


ALTER FUNCTION public.urbo_watmeter_a_trig(id_scope text, iscarto boolean) OWNER TO postgres;

--
-- TOC entry 2417 (class 1255 OID 23044)
-- Name: users_graph_node_op(integer, bigint, text, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.users_graph_node_op(node_id integer, user_id bigint, mode text, op text) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
  nodes integer[];
BEGIN

  if mode!='read' and mode!='write' then
    RAISE EXCEPTION 'Unsupported mode'
    USING HINT = 'Please use mode ''read'' or ''write''';
    return;
  end if;

  if op!='add' and op!='rm' then
    RAISE EXCEPTION 'Unsupported operation'
    USING HINT = 'Please use operation ''add'' or ''rm''';
    return;
  end if;


  nodes :=
    -- childs
    array(WITH RECURSIVE search_graph(id) AS (
            SELECT id FROM users_graph WHERE id=node_id
          UNION ALL
            SELECT ug.id FROM search_graph sg
            INNER JOIN users_graph ug ON ug.parent=sg.id
        )
        select id from search_graph);

  IF op = 'add' THEN
    -- APPEND parents only of adding
    -- parents
    nodes := nodes ||
      array(WITH RECURSIVE search_graph(id,parent) AS (
        SELECT id,parent FROM users_graph WHERE id=node_id
        UNION ALL
          SELECT ug.id,ug.parent FROM search_graph sg
          INNER JOIN users_graph ug ON ug.id=sg.parent
        )
        SELECT id FROM search_graph);
  END IF;

  -- remove duplicates
  nodes := uniq(sort(nodes));

  -- raise notice '%', nodes;

  if op = 'add' then
    if mode = 'read' then
      UPDATE users_graph set read_users=read_users||user_id
      WHERE not user_id=ANY(read_users) AND id=ANY(nodes);
    elsif mode = 'write' then
      UPDATE users_graph set write_users=write_users||user_id
      WHERE not user_id=ANY(write_users) AND id=ANY(nodes);
    end if;
  elsif op = 'rm' then
    if mode = 'read' then
      raise notice 'here';
      UPDATE users_graph set read_users=array_remove(read_users,user_id) WHERE id=ANY(nodes);
      -- TODO: Handle parent drop when no brothers
    elsif mode = 'write' then
      UPDATE users_graph set write_users=array_remove(write_users,user_id) WHERE id=ANY(nodes);
      -- TODO: Handle parent drop when no brothers
    end if;
  end if;
END;
$$;


ALTER FUNCTION public.users_graph_node_op(node_id integer, user_id bigint, mode text, op text) OWNER TO postgres;

--
-- TOC entry 4997 (class 1255 OID 44776)
-- Name: last(anyelement); Type: AGGREGATE; Schema: public; Owner: postgres
--

CREATE AGGREGATE public.last(anyelement) (
    SFUNC = public.last_agg,
    STYPE = anyelement
);


ALTER AGGREGATE public.last(anyelement) OWNER TO postgres;

SET default_tablespace = '';

SET default_with_oids = false;

--
-- TOC entry 607 (class 1259 OID 24849)
-- Name: categories; Type: TABLE; Schema: metadata; Owner: :owner
--

CREATE TABLE metadata.categories (
    id_category character varying(255) NOT NULL,
    category_name character varying(255),
    nodata boolean DEFAULT false,
    config jsonb DEFAULT '{}'::jsonb
);


ALTER TABLE metadata.categories OWNER TO :owner;

--
-- TOC entry 608 (class 1259 OID 24857)
-- Name: categories_scopes; Type: TABLE; Schema: metadata; Owner: :owner
--

CREATE TABLE metadata.categories_scopes (
    id_scope character varying(255) NOT NULL,
    id_category character varying(255) NOT NULL,
    category_name character varying(255),
    nodata boolean DEFAULT false,
    config jsonb DEFAULT '{}'::jsonb
);


ALTER TABLE metadata.categories_scopes OWNER TO :owner;

--
-- TOC entry 609 (class 1259 OID 24865)
-- Name: entities; Type: TABLE; Schema: metadata; Owner: :owner
--

CREATE TABLE metadata.entities (
    id_entity character varying(255) NOT NULL,
    entity_name character varying(255),
    id_category character varying(255),
    table_name character varying(255),
    mandatory boolean DEFAULT false,
    editable boolean DEFAULT false
);


ALTER TABLE metadata.entities OWNER TO :owner;

--
-- TOC entry 610 (class 1259 OID 24873)
-- Name: entities_scopes; Type: TABLE; Schema: metadata; Owner: :owner
--

CREATE TABLE metadata.entities_scopes (
    id_scope character varying(255) NOT NULL,
    id_entity character varying(255) NOT NULL,
    entity_name character varying(255),
    id_category character varying(255),
    table_name character varying(255),
    mandatory boolean DEFAULT false,
    editable boolean DEFAULT false
);


ALTER TABLE metadata.entities_scopes OWNER TO :owner;

--
-- TOC entry 611 (class 1259 OID 24881)
-- Name: scope_widgets_tokens; Type: TABLE; Schema: metadata; Owner: :owner
--

CREATE TABLE metadata.scope_widgets_tokens (
    id_scope character varying(255) NOT NULL,
    id_widget character varying(255) NOT NULL,
    publish_name character varying(255) NOT NULL,
    token text NOT NULL,
    payload jsonb,
    id integer NOT NULL,
    description text,
    created_at timestamp without time zone DEFAULT timezone('utc'::text, now())
);


ALTER TABLE metadata.scope_widgets_tokens OWNER TO :owner;

--
-- TOC entry 612 (class 1259 OID 24888)
-- Name: scope_widgets_tokens_id_seq; Type: SEQUENCE; Schema: metadata; Owner: :owner
--

CREATE SEQUENCE metadata.scope_widgets_tokens_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE metadata.scope_widgets_tokens_id_seq OWNER TO :owner;

--
-- TOC entry 6795 (class 0 OID 0)
-- Dependencies: 612
-- Name: scope_widgets_tokens_id_seq; Type: SEQUENCE OWNED BY; Schema: metadata; Owner: :owner
--

ALTER SEQUENCE metadata.scope_widgets_tokens_id_seq OWNED BY metadata.scope_widgets_tokens.id;


--
-- TOC entry 613 (class 1259 OID 24890)
-- Name: scopes; Type: TABLE; Schema: metadata; Owner: :owner
--

CREATE TABLE metadata.scopes (
    id_scope character varying(255) NOT NULL,
    scope_name character varying(255),
    geom public.geometry(Point,4326),
    zoom smallint,
    dbschema character varying(255),
    parent_id_scope character varying(255) DEFAULT NULL::character varying,
    status smallint DEFAULT 0,
    timezone character varying(255),
    config jsonb
);


ALTER TABLE metadata.scopes OWNER TO :owner;

--
-- TOC entry 614 (class 1259 OID 24898)
-- Name: variables; Type: TABLE; Schema: metadata; Owner: :owner
--

CREATE TABLE metadata.variables (
    id_variable character varying(255) NOT NULL,
    id_entity character varying(255),
    entity_field character varying(255),
    var_name character varying(255),
    var_units character varying(255),
    var_thresholds double precision[],
    var_agg character varying[],
    var_reverse boolean,
    config jsonb,
    table_name character varying(255),
    type character varying(255) DEFAULT 'catalogue'::character varying,
    mandatory boolean DEFAULT false,
    editable boolean DEFAULT false
);


ALTER TABLE metadata.variables OWNER TO :owner;

--
-- TOC entry 615 (class 1259 OID 24907)
-- Name: variables_scopes; Type: TABLE; Schema: metadata; Owner: :owner
--

CREATE TABLE metadata.variables_scopes (
    id_scope character varying(255) NOT NULL,
    id_variable character varying(255) NOT NULL,
    id_entity character varying(255) NOT NULL,
    entity_field character varying(255),
    var_name character varying(255),
    var_units character varying(255),
    var_thresholds double precision[],
    var_agg character varying[],
    var_reverse boolean,
    config jsonb,
    table_name character varying(255),
    type character varying(255) DEFAULT 'catalogue'::character varying,
    mandatory boolean DEFAULT false,
    editable boolean DEFAULT false
);


ALTER TABLE metadata.variables_scopes OWNER TO :owner;

--
-- TOC entry 652 (class 1259 OID 25100)
-- Name: dashboard_categories; Type: TABLE; Schema: public; Owner: :owner
--

CREATE TABLE public.dashboard_categories (
    id_category character varying(255) NOT NULL,
    category_name character varying(255),
    category_colour character varying(10)
);


ALTER TABLE public.dashboard_categories OWNER TO :owner;

--
-- TOC entry 653 (class 1259 OID 25106)
-- Name: dashboard_entities; Type: TABLE; Schema: public; Owner: :owner
--

CREATE TABLE public.dashboard_entities (
    id_entity character varying(255) NOT NULL,
    entity_name character varying(255),
    id_category character varying(255),
    id_table character varying(255),
    icon character varying(255)
);


ALTER TABLE public.dashboard_entities OWNER TO :owner;

--
-- TOC entry 654 (class 1259 OID 25112)
-- Name: dashboard_scopes; Type: TABLE; Schema: public; Owner: :owner
--

CREATE TABLE public.dashboard_scopes (
    id_scope character varying(255) NOT NULL,
    scope_name character varying(255),
    geom public.geometry(Point,4326),
    zoom smallint,
    dbschema character varying(255),
    devices_map boolean DEFAULT true,
    parent_id_scope character varying(255)
);


ALTER TABLE public.dashboard_scopes OWNER TO :owner;

--
-- TOC entry 655 (class 1259 OID 25119)
-- Name: dashboard_scopesentities; Type: TABLE; Schema: public; Owner: :owner
--

CREATE TABLE public.dashboard_scopesentities (
    id_scope character varying(255),
    id_entity character varying(255)
);


ALTER TABLE public.dashboard_scopesentities OWNER TO :owner;

--
-- TOC entry 656 (class 1259 OID 25125)
-- Name: dashboard_variables; Type: TABLE; Schema: public; Owner: :owner
--

CREATE TABLE public.dashboard_variables (
    id_variable character varying(255) NOT NULL,
    id_entity character varying(255),
    entity_field character varying(255),
    var_name character varying(255),
    var_units character varying(255),
    var_thresholds double precision[],
    var_tempalarmvalue integer,
    var_tempalarmactive boolean,
    var_agg character varying[],
    var_reverse boolean
);


ALTER TABLE public.dashboard_variables OWNER TO :owner;

--
-- TOC entry 770 (class 1259 OID 29601)
-- Name: frames_scope; Type: TABLE; Schema: public; Owner: :owner
--

CREATE TABLE public.frames_scope (
    id bigint NOT NULL,
    title text NOT NULL,
    url text NOT NULL,
    description text,
    source text,
    datatype text,
    scope_id character varying(255) NOT NULL,
    type public.frame_type DEFAULT 'cityanalytics'::public.frame_type NOT NULL,
    vertical character varying(255)
);


ALTER TABLE public.frames_scope OWNER TO :owner;

--
-- TOC entry 769 (class 1259 OID 29599)
-- Name: frames_scope_id_seq; Type: SEQUENCE; Schema: public; Owner: :owner
--

CREATE SEQUENCE public.frames_scope_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.frames_scope_id_seq OWNER TO :owner;

--
-- TOC entry 6796 (class 0 OID 0)
-- Dependencies: 769
-- Name: frames_scope_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: :owner
--

ALTER SEQUENCE public.frames_scope_id_seq OWNED BY public.frames_scope.id;


--
-- TOC entry 657 (class 1259 OID 25131)
-- Name: migrations; Type: TABLE; Schema: public; Owner: :owner
--

CREATE TABLE public.migrations (
    id integer NOT NULL,
    name character varying(255) NOT NULL,
    run_on timestamp without time zone NOT NULL
);


ALTER TABLE public.migrations OWNER TO :owner;

--
-- TOC entry 658 (class 1259 OID 25134)
-- Name: migrations_id_seq; Type: SEQUENCE; Schema: public; Owner: :owner
--

CREATE SEQUENCE public.migrations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.migrations_id_seq OWNER TO :owner;

--
-- TOC entry 6797 (class 0 OID 0)
-- Dependencies: 658
-- Name: migrations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: :owner
--

ALTER SEQUENCE public.migrations_id_seq OWNED BY public.migrations.id;


--
-- TOC entry 659 (class 1259 OID 25136)
-- Name: parques; Type: TABLE; Schema: public; Owner: :owner
--

CREATE TABLE public.parques (
    id character varying(80) NOT NULL,
    id_scope character varying(80),
    park_name character varying(255),
    park_name_compl character varying(255),
    the_geom public.geometry(MultiPolygon,4326)
);


ALTER TABLE public.parques OWNER TO :owner;

--
-- TOC entry 660 (class 1259 OID 25142)
-- Name: subscriptions; Type: TABLE; Schema: public; Owner: :owner
--

CREATE TABLE public.subscriptions (
    subs_id character varying(255) NOT NULL,
    id_name character varying(255),
    schema text
);


ALTER TABLE public.subscriptions OWNER TO :owner;

--
-- TOC entry 661 (class 1259 OID 25148)
-- Name: tmp_import_incidences; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.tmp_import_incidences (
    latitude numeric,
    longitude numeric,
    incidencecode character varying(255) NOT NULL,
    category character varying(255),
    status_datetime timestamp without time zone,
    priority integer,
    jurisdiction character varying(50),
    status character varying(10),
    subject character varying(1000),
    id_entity character varying(50) NOT NULL
);


ALTER TABLE public.tmp_import_incidences OWNER TO postgres;

--
-- TOC entry 662 (class 1259 OID 25154)
-- Name: users; Type: TABLE; Schema: public; Owner: :owner
--

CREATE TABLE public.users (
    users_id bigint NOT NULL,
    name character varying(128) NOT NULL,
    surname character varying(256) NOT NULL,
    email character varying(256) NOT NULL,
    password character varying(64) NOT NULL,
    superadmin boolean NOT NULL,
    address text,
    telephone text,
    ldap boolean DEFAULT false
);


ALTER TABLE public.users OWNER TO :owner;

--
-- TOC entry 663 (class 1259 OID 25161)
-- Name: users_graph; Type: TABLE; Schema: public; Owner: :owner
--

CREATE TABLE public.users_graph (
    id integer NOT NULL,
    name character varying(64) NOT NULL,
    parent integer,
    read_users bigint[] NOT NULL,
    write_users bigint[] NOT NULL
);


ALTER TABLE public.users_graph OWNER TO :owner;

--
-- TOC entry 664 (class 1259 OID 25167)
-- Name: users_graph2; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.users_graph2 (
    id integer,
    name character varying(64),
    parent integer,
    read_users bigint[],
    write_users bigint[]
);


ALTER TABLE public.users_graph2 OWNER TO postgres;

--
-- TOC entry 665 (class 1259 OID 25173)
-- Name: users_graph_id_seq; Type: SEQUENCE; Schema: public; Owner: :owner
--

CREATE SEQUENCE public.users_graph_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.users_graph_id_seq OWNER TO :owner;

--
-- TOC entry 6798 (class 0 OID 0)
-- Dependencies: 665
-- Name: users_graph_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: :owner
--

ALTER SEQUENCE public.users_graph_id_seq OWNED BY public.users_graph.id;


--
-- TOC entry 666 (class 1259 OID 25175)
-- Name: users_tokens; Type: TABLE; Schema: public; Owner: :owner
--

CREATE TABLE public.users_tokens (
    users_id bigint NOT NULL,
    token text NOT NULL,
    expiration timestamp without time zone NOT NULL
);


ALTER TABLE public.users_tokens OWNER TO :owner;

--
-- TOC entry 667 (class 1259 OID 25181)
-- Name: users_users_id_seq; Type: SEQUENCE; Schema: public; Owner: :owner
--

CREATE SEQUENCE public.users_users_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.users_users_id_seq OWNER TO :owner;

--
-- TOC entry 6799 (class 0 OID 0)
-- Dependencies: 667
-- Name: users_users_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: :owner
--

ALTER SEQUENCE public.users_users_id_seq OWNED BY public.users.users_id;


--
-- TOC entry 6583 (class 2604 OID 25721)
-- Name: scope_widgets_tokens id; Type: DEFAULT; Schema: metadata; Owner: :owner
--

ALTER TABLE ONLY metadata.scope_widgets_tokens ALTER COLUMN id SET DEFAULT nextval('metadata.scope_widgets_tokens_id_seq'::regclass);


--
-- TOC entry 6598 (class 2604 OID 29604)
-- Name: frames_scope id; Type: DEFAULT; Schema: public; Owner: :owner
--

ALTER TABLE ONLY public.frames_scope ALTER COLUMN id SET DEFAULT nextval('public.frames_scope_id_seq'::regclass);


--
-- TOC entry 6594 (class 2604 OID 25738)
-- Name: migrations id; Type: DEFAULT; Schema: public; Owner: :owner
--

ALTER TABLE ONLY public.migrations ALTER COLUMN id SET DEFAULT nextval('public.migrations_id_seq'::regclass);


--
-- TOC entry 6595 (class 2604 OID 25739)
-- Name: users users_id; Type: DEFAULT; Schema: public; Owner: :owner
--

ALTER TABLE ONLY public.users ALTER COLUMN users_id SET DEFAULT nextval('public.users_users_id_seq'::regclass);


--
-- TOC entry 6597 (class 2604 OID 25740)
-- Name: users_graph id; Type: DEFAULT; Schema: public; Owner: :owner
--

ALTER TABLE ONLY public.users_graph ALTER COLUMN id SET DEFAULT nextval('public.users_graph_id_seq'::regclass);


--
-- TOC entry 6601 (class 2606 OID 26905)
-- Name: categories categories_pkey; Type: CONSTRAINT; Schema: metadata; Owner: :owner
--

ALTER TABLE ONLY metadata.categories
    ADD CONSTRAINT categories_pkey PRIMARY KEY (id_category);


--
-- TOC entry 6603 (class 2606 OID 26907)
-- Name: categories_scopes categories_scopes_pkey; Type: CONSTRAINT; Schema: metadata; Owner: :owner
--

ALTER TABLE ONLY metadata.categories_scopes
    ADD CONSTRAINT categories_scopes_pkey PRIMARY KEY (id_scope, id_category);


--
-- TOC entry 6605 (class 2606 OID 26909)
-- Name: entities entities_pkey; Type: CONSTRAINT; Schema: metadata; Owner: :owner
--

ALTER TABLE ONLY metadata.entities
    ADD CONSTRAINT entities_pkey PRIMARY KEY (id_entity);


--
-- TOC entry 6607 (class 2606 OID 26911)
-- Name: entities_scopes entities_scopes_pkey; Type: CONSTRAINT; Schema: metadata; Owner: :owner
--

ALTER TABLE ONLY metadata.entities_scopes
    ADD CONSTRAINT entities_scopes_pkey PRIMARY KEY (id_scope, id_entity);


--
-- TOC entry 6609 (class 2606 OID 26913)
-- Name: scope_widgets_tokens scope_widgets_tokens_id_scope_id_widget_publish_name_token_key; Type: CONSTRAINT; Schema: metadata; Owner: :owner
--

ALTER TABLE ONLY metadata.scope_widgets_tokens
    ADD CONSTRAINT scope_widgets_tokens_id_scope_id_widget_publish_name_token_key UNIQUE (id_scope, id_widget, publish_name, token);


--
-- TOC entry 6611 (class 2606 OID 26915)
-- Name: scope_widgets_tokens scope_widgets_tokens_pkey; Type: CONSTRAINT; Schema: metadata; Owner: :owner
--

ALTER TABLE ONLY metadata.scope_widgets_tokens
    ADD CONSTRAINT scope_widgets_tokens_pkey PRIMARY KEY (id);


--
-- TOC entry 6614 (class 2606 OID 26917)
-- Name: scopes scopes_dbschema_key; Type: CONSTRAINT; Schema: metadata; Owner: :owner
--

ALTER TABLE ONLY metadata.scopes
    ADD CONSTRAINT scopes_dbschema_key UNIQUE (dbschema);


--
-- TOC entry 6616 (class 2606 OID 26919)
-- Name: scopes scopes_pkey; Type: CONSTRAINT; Schema: metadata; Owner: :owner
--

ALTER TABLE ONLY metadata.scopes
    ADD CONSTRAINT scopes_pkey PRIMARY KEY (id_scope);


--
-- TOC entry 6618 (class 2606 OID 26921)
-- Name: variables variables_pkey; Type: CONSTRAINT; Schema: metadata; Owner: :owner
--

ALTER TABLE ONLY metadata.variables
    ADD CONSTRAINT variables_pkey PRIMARY KEY (id_variable);


--
-- TOC entry 6620 (class 2606 OID 26923)
-- Name: variables_scopes variables_scopes_pkey; Type: CONSTRAINT; Schema: metadata; Owner: :owner
--

ALTER TABLE ONLY metadata.variables_scopes
    ADD CONSTRAINT variables_scopes_pkey PRIMARY KEY (id_scope, id_entity, id_variable);


--
-- TOC entry 6622 (class 2606 OID 26967)
-- Name: dashboard_categories dashboard_categories_pkey; Type: CONSTRAINT; Schema: public; Owner: :owner
--

ALTER TABLE ONLY public.dashboard_categories
    ADD CONSTRAINT dashboard_categories_pkey PRIMARY KEY (id_category);


--
-- TOC entry 6624 (class 2606 OID 26969)
-- Name: dashboard_entities dashboard_entities_pkey; Type: CONSTRAINT; Schema: public; Owner: :owner
--

ALTER TABLE ONLY public.dashboard_entities
    ADD CONSTRAINT dashboard_entities_pkey PRIMARY KEY (id_entity);


--
-- TOC entry 6626 (class 2606 OID 26971)
-- Name: dashboard_scopes dashboard_scopes_pkey; Type: CONSTRAINT; Schema: public; Owner: :owner
--

ALTER TABLE ONLY public.dashboard_scopes
    ADD CONSTRAINT dashboard_scopes_pkey PRIMARY KEY (id_scope);


--
-- TOC entry 6629 (class 2606 OID 26973)
-- Name: dashboard_variables dashboard_variables_pkey; Type: CONSTRAINT; Schema: public; Owner: :owner
--

ALTER TABLE ONLY public.dashboard_variables
    ADD CONSTRAINT dashboard_variables_pkey PRIMARY KEY (id_variable);


--
-- TOC entry 6644 (class 2606 OID 29609)
-- Name: frames_scope frames_scope_pkey; Type: CONSTRAINT; Schema: public; Owner: :owner
--

ALTER TABLE ONLY public.frames_scope
    ADD CONSTRAINT frames_scope_pkey PRIMARY KEY (id);


--
-- TOC entry 6631 (class 2606 OID 26975)
-- Name: migrations migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: :owner
--

ALTER TABLE ONLY public.migrations
    ADD CONSTRAINT migrations_pkey PRIMARY KEY (id);


--
-- TOC entry 6633 (class 2606 OID 26977)
-- Name: parques parques_pkey; Type: CONSTRAINT; Schema: public; Owner: :owner
--

ALTER TABLE ONLY public.parques
    ADD CONSTRAINT parques_pkey PRIMARY KEY (id);


--
-- TOC entry 6635 (class 2606 OID 26979)
-- Name: subscriptions subscriptions_pkey; Type: CONSTRAINT; Schema: public; Owner: :owner
--

ALTER TABLE ONLY public.subscriptions
    ADD CONSTRAINT subscriptions_pkey PRIMARY KEY (subs_id);


--
-- TOC entry 6637 (class 2606 OID 26981)
-- Name: subscriptions subscriptions_scope_unique; Type: CONSTRAINT; Schema: public; Owner: :owner
--

ALTER TABLE ONLY public.subscriptions
    ADD CONSTRAINT subscriptions_scope_unique UNIQUE (subs_id, schema);


--
-- TOC entry 6642 (class 2606 OID 26983)
-- Name: users_graph users_graph_pkey; Type: CONSTRAINT; Schema: public; Owner: :owner
--

ALTER TABLE ONLY public.users_graph
    ADD CONSTRAINT users_graph_pkey PRIMARY KEY (id);


--
-- TOC entry 6640 (class 2606 OID 26985)
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: :owner
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (users_id);


--
-- TOC entry 6612 (class 1259 OID 27430)
-- Name: idx_scope_geom; Type: INDEX; Schema: metadata; Owner: :owner
--

CREATE INDEX idx_scope_geom ON metadata.scopes USING gist (geom);


--
-- TOC entry 6627 (class 1259 OID 27467)
-- Name: idx_scope_geom; Type: INDEX; Schema: public; Owner: :owner
--

CREATE INDEX idx_scope_geom ON public.dashboard_scopes USING gist (geom);


--
-- TOC entry 6638 (class 1259 OID 27468)
-- Name: users_email_idx; Type: INDEX; Schema: public; Owner: :owner
--

CREATE UNIQUE INDEX users_email_idx ON public.users USING btree (email);


--
-- TOC entry 6646 (class 2606 OID 27537)
-- Name: categories_scopes categories_scopes_id_category_fkey; Type: FK CONSTRAINT; Schema: metadata; Owner: :owner
--

ALTER TABLE ONLY metadata.categories_scopes
    ADD CONSTRAINT categories_scopes_id_category_fkey FOREIGN KEY (id_category) REFERENCES metadata.categories(id_category);


--
-- TOC entry 6645 (class 2606 OID 27542)
-- Name: categories_scopes categories_scopes_id_scope_fkey; Type: FK CONSTRAINT; Schema: metadata; Owner: :owner
--

ALTER TABLE ONLY metadata.categories_scopes
    ADD CONSTRAINT categories_scopes_id_scope_fkey FOREIGN KEY (id_scope) REFERENCES metadata.scopes(id_scope) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- TOC entry 6647 (class 2606 OID 27547)
-- Name: entities entities_id_category_fkey; Type: FK CONSTRAINT; Schema: metadata; Owner: :owner
--

ALTER TABLE ONLY metadata.entities
    ADD CONSTRAINT entities_id_category_fkey FOREIGN KEY (id_category) REFERENCES metadata.categories(id_category);


--
-- TOC entry 6650 (class 2606 OID 27552)
-- Name: entities_scopes entities_scopes_id_category_fkey; Type: FK CONSTRAINT; Schema: metadata; Owner: :owner
--

ALTER TABLE ONLY metadata.entities_scopes
    ADD CONSTRAINT entities_scopes_id_category_fkey FOREIGN KEY (id_category) REFERENCES metadata.categories(id_category);


--
-- TOC entry 6649 (class 2606 OID 27557)
-- Name: entities_scopes entities_scopes_id_entity_fkey; Type: FK CONSTRAINT; Schema: metadata; Owner: :owner
--

ALTER TABLE ONLY metadata.entities_scopes
    ADD CONSTRAINT entities_scopes_id_entity_fkey FOREIGN KEY (id_entity) REFERENCES metadata.entities(id_entity);


--
-- TOC entry 6648 (class 2606 OID 27562)
-- Name: entities_scopes entities_scopes_id_scope_fkey; Type: FK CONSTRAINT; Schema: metadata; Owner: :owner
--

ALTER TABLE ONLY metadata.entities_scopes
    ADD CONSTRAINT entities_scopes_id_scope_fkey FOREIGN KEY (id_scope) REFERENCES metadata.scopes(id_scope) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- TOC entry 6651 (class 2606 OID 27567)
-- Name: variables variables_id_entity_fkey; Type: FK CONSTRAINT; Schema: metadata; Owner: :owner
--

ALTER TABLE ONLY metadata.variables
    ADD CONSTRAINT variables_id_entity_fkey FOREIGN KEY (id_entity) REFERENCES metadata.entities(id_entity);


--
-- TOC entry 6654 (class 2606 OID 27572)
-- Name: variables_scopes variables_scopes_id_entity_fkey; Type: FK CONSTRAINT; Schema: metadata; Owner: :owner
--

ALTER TABLE ONLY metadata.variables_scopes
    ADD CONSTRAINT variables_scopes_id_entity_fkey FOREIGN KEY (id_entity) REFERENCES metadata.entities(id_entity);


--
-- TOC entry 6653 (class 2606 OID 27577)
-- Name: variables_scopes variables_scopes_id_scope_fkey; Type: FK CONSTRAINT; Schema: metadata; Owner: :owner
--

ALTER TABLE ONLY metadata.variables_scopes
    ADD CONSTRAINT variables_scopes_id_scope_fkey FOREIGN KEY (id_scope) REFERENCES metadata.scopes(id_scope) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- TOC entry 6652 (class 2606 OID 27582)
-- Name: variables_scopes variables_scopes_id_variable_fkey; Type: FK CONSTRAINT; Schema: metadata; Owner: :owner
--

ALTER TABLE ONLY metadata.variables_scopes
    ADD CONSTRAINT variables_scopes_id_variable_fkey FOREIGN KEY (id_variable) REFERENCES metadata.variables(id_variable);


--
-- TOC entry 6655 (class 2606 OID 27587)
-- Name: users_tokens users_tokens_users_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: :owner
--

ALTER TABLE ONLY public.users_tokens
    ADD CONSTRAINT users_tokens_users_id_fkey FOREIGN KEY (users_id) REFERENCES public.users(users_id);
