CREATE FUNCTION show_partition_name(p_parent_table text, p_value text, OUT partition_schema text, OUT partition_table text, OUT suffix_timestamp timestamptz, OUT suffix_id bigint, OUT table_exists boolean) RETURNS record
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE

v_child_exists          text;
v_control               text;
v_control_type          text;
v_datetime_string       text;
v_epoch                 text;
v_max_range             timestamptz;
v_min_range             timestamptz;
v_parent_schema         text;
v_parent_tablename      text;
v_partition_interval    text;
v_type                  text;

BEGIN
/*
 * Given a parent table and partition value, return the name of the child partition it would go in.
 * If using epoch time partitioning, give the text representation of the timestamp NOT the epoch integer value (use to_timestamp() to convert epoch values).
 * Also returns just the suffix value and true if the child table exists or false if it does not
 */

SELECT partition_type 
    , control
    , partition_interval
    , datetime_string
    , epoch
INTO v_type
    , v_control
    , v_partition_interval
    , v_datetime_string 
    , v_epoch
FROM @extschema@.part_config 
WHERE parent_table = p_parent_table;

IF v_type IS NULL THEN
    RAISE EXCEPTION 'Parent table given is not managed by pg_partman (%)', p_parent_table;
END IF;

SELECT n.nspname, c.relname INTO v_parent_schema, v_parent_tablename
FROM pg_catalog.pg_class c
JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
WHERE n.nspname = split_part(p_parent_table, '.', 1)::name
AND c.relname = split_part(p_parent_table, '.', 2)::name;
IF v_parent_tablename IS NULL THEN
    RAISE EXCEPTION 'Parent table given does not exist (%)', p_parent_table;
END IF;

partition_schema := v_parent_schema;

SELECT general_type INTO v_control_type FROM @extschema@.check_control_type(v_parent_schema, v_parent_tablename, v_control);

IF ( (v_control_type = 'time') OR (v_control_type = 'id' AND v_epoch <> 'none') )
     AND (v_type <> 'time-custom') AND (v_type <> 'native' OR (v_partition_interval::interval IN ('15 mins', '30mins', '1 hour', '1 day', '1 week', '1 month', '3 months', '1 year')))
THEN
    CASE
        WHEN v_partition_interval::interval = '15 mins' THEN
            suffix_timestamp := date_trunc('hour', p_value::timestamptz) + 
                '15min'::interval * floor(date_part('minute', p_value::timestamptz) / 15.0);
        WHEN v_partition_interval::interval = '30 mins' THEN
            suffix_timestamp := date_trunc('hour', p_value::timestamptz) + 
                '30min'::interval * floor(date_part('minute', p_value::timestamptz) / 30.0);
        WHEN v_partition_interval::interval = '1 hour' THEN
            suffix_timestamp := date_trunc('hour', p_value::timestamptz);
        WHEN v_partition_interval::interval = '1 day' THEN
            suffix_timestamp := date_trunc('day', p_value::timestamptz);
        WHEN v_partition_interval::interval = '1 week' THEN
            suffix_timestamp := date_trunc('week', p_value::timestamptz);
        WHEN v_partition_interval::interval = '1 month' THEN
            suffix_timestamp := date_trunc('month', p_value::timestamptz);
        WHEN v_partition_interval::interval = '3 months' THEN
            suffix_timestamp := date_trunc('quarter', p_value::timestamptz);
        WHEN v_partition_interval::interval = '1 year' THEN
            suffix_timestamp := date_trunc('year', p_value::timestamptz);
    END CASE;
    partition_schema := v_parent_schema;
    partition_table := @extschema@.check_name_length(v_parent_tablename, to_char(suffix_timestamp, v_datetime_string), TRUE);

ELSIF v_control_type = 'id' AND v_type <> 'time-custom' THEN
    suffix_id := (p_value::bigint - (p_value::bigint % v_partition_interval::bigint));
    partition_table := @extschema@.check_name_length(v_parent_tablename, suffix_id::text, TRUE);

ELSIF v_type = 'time-custom' OR (v_type = 'native' AND (v_partition_interval::interval NOT IN ('15 mins', '30 mins', '1 hour', '1 day', '1 week', '1 month', '3 months', '1 year'))) THEN

    SELECT child_table, lower(partition_range) INTO partition_table, suffix_timestamp FROM @extschema@.custom_time_partitions 
        WHERE parent_table = p_parent_table AND partition_range @> p_value::timestamptz;

    IF partition_table IS NULL THEN
        SELECT max(upper(partition_range)) INTO v_max_range FROM @extschema@.custom_time_partitions WHERE parent_table = p_parent_table;
        SELECT min(lower(partition_range)) INTO v_min_range FROM @extschema@.custom_time_partitions WHERE parent_table = p_parent_table;
        IF p_value::timestamptz >= v_max_range THEN
            suffix_timestamp := v_max_range;
            LOOP
                -- Keep incrementing higher until given value is below the upper range
                suffix_timestamp := suffix_timestamp + v_partition_interval::interval;
                IF p_value::timestamptz < suffix_timestamp THEN
                    -- Have to subtract one interval because the value would actually be in the partition previous 
                    --      to this partition timestamp since the partition names contain the lower boundary
                    suffix_timestamp := suffix_timestamp - v_partition_interval::interval;
                    EXIT;
                END IF;
            END LOOP;
        ELSIF p_value::timestamptz < v_min_range THEN
            suffix_timestamp := v_min_range;
            LOOP
                -- Keep decrementing lower until given value is below or equal to the lower range
                suffix_timestamp := suffix_timestamp - v_partition_interval::interval;
                IF p_value::timestamptz >= suffix_timestamp THEN
                    EXIT;
                END IF;
            END LOOP;
        ELSE
            RAISE EXCEPTION 'Unable to determine a valid child table for the given parent table and value';
        END IF;

        partition_table := @extschema@.check_name_length(v_parent_tablename, to_char(suffix_timestamp, v_datetime_string), TRUE);
    END IF;
END IF;

SELECT tablename INTO v_child_exists
FROM pg_catalog.pg_tables
WHERE schemaname = partition_schema::name
AND tablename = partition_table::name;

IF v_child_exists IS NOT NULL THEN
    table_exists := true;
ELSE
    table_exists := false;
END IF;

RETURN;

END
$$;


