-- Oracle Instance Level Data Collection Script (non-AWR mode)
-- One row per instance; for RAC an additional cluster row (all hosts) with the cluster totals.
-- Compatible with Oracle 11.2 and above. Run from a non-CDB or CDB$ROOT (a PDB connection reports that PDB).
-- Source: GV$SYSMETRIC_SUMMARY / GV$CON_SYSMETRIC_SUMMARY (the last ~60 minutes). No AWR view is used.
--         These views hold one value per instance, so the 'percentile' columns are that value
--         (summed across instances for RAC / cluster figures).
-- Invoked by collect_awr.sql / collect_noawr.sql / collect_statspack.sql (SQL*Plus) or oracle_collector.py (Python).
-- Do not run stand-alone: session settings and spool files are handled by the caller.
-- Only the section between the 'metric source' markers differs between the AWR, NOAWR and STATSPACK
-- versions of this script; everything else is identical (checked by tests/test_oratools.py).

-- CSV Header
PROMPT Server Name,CDB/Instance Name,Database Version,Database Edition,RAC Cluster,Nodes,Total PDB Count,vCPU Count,Total Memory (GB),Free Memory (GB),Total Storage (GB),CPU Average 99th Percentile,CPU Maximum 90th Percentile,IOPS Average 99th Percentile,IOPS Maximum 50th Percentile,Throughput Average 99th Percentile (MB/s),Throughput Maximum 50th Percentile (MB/s),Network Throughput Average (MB/s),Network Throughput Maximum (MB/s)

DECLARE
    v_db_version VARCHAR2(20);
    v_db_version_num NUMBER;
    v_is_cdb VARCHAR2(3) := 'NO';
    v_con_id NUMBER := 0;
    v_is_pdb VARCHAR2(3) := 'NO';
    v_dbid NUMBER;
    v_con_dbid NUMBER;
    v_cdb_name VARCHAR2(128);
    v_server_name VARCHAR2(4000);
    v_rac_cluster VARCHAR2(1) := 'N';
    v_nodes NUMBER := 1;
    v_db_edition VARCHAR2(50);
    v_total_pdb_count NUMBER := 0;
    v_total_storage NUMBER := 0;
    -- >>> metric source (NOAWR) >>>
    v_metric_view VARCHAR2(30);
    v_view_has_inst BOOLEAN := TRUE;
    -- <<< metric source <<<

    -- Number literal that is independent of NLS settings (used to build dynamic SQL)
    FUNCTION lit(p_value NUMBER) RETURN VARCHAR2 IS
    BEGIN
        RETURN TO_CHAR(p_value, 'TM9', 'NLS_NUMERIC_CHARACTERS=''.,''');
    END;

    -- Metric definition shared by every mode: which counters make up a metric, unit divisor and decimals.
    --   CPU  : number of CPUs busy. Host CPU for a non-CDB / CDB$ROOT, the container's own CPU in a PDB.
    --   IOPS : read + write I/O requests per second (D3: total I/O, not reads or writes only)
    --   MBPS : read + write MB per second
    --   NET  : Oracle network traffic (client and database links), MB per second
    --   REDO : redo generated, MB per second
    PROCEDURE metric_def(p_kind VARCHAR2, p_names OUT VARCHAR2, p_div OUT NUMBER, p_dec OUT PLS_INTEGER) IS
    BEGIN
        IF p_kind = 'CPU' THEN
            p_names := CASE WHEN v_is_pdb = 'YES' THEN '''CPU Usage Per Sec''' ELSE '''Host CPU Usage Per Sec''' END;
            p_div := 100; p_dec := 3;
        ELSIF p_kind = 'IOPS' THEN
            p_names := '''Physical Read Total IO Requests Per Sec'',''Physical Write Total IO Requests Per Sec''';
            p_div := 1; p_dec := 2;
        ELSIF p_kind = 'MBPS' THEN
            p_names := '''Physical Read Total Bytes Per Sec'',''Physical Write Total Bytes Per Sec''';
            p_div := 1048576; p_dec := 4;
        ELSIF p_kind = 'NET' THEN
            p_names := '''Network Traffic Volume Per Sec''';
            p_div := 1048576; p_dec := 4;
        ELSE -- REDO
            p_names := '''Redo Generated Per Sec''';
            p_div := 1048576; p_dec := 4;
        END IF;
    END;

    -- >>> metric source (NOAWR) >>>
    PROCEDURE init_source IS
        v_dummy NUMBER;
    BEGIN
        IF v_is_pdb = 'YES' THEN
            -- PDB: the container's own metrics (GV$ on 12.2+ RAC aware, V$ as fallback)
            BEGIN
                EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM GV$CON_SYSMETRIC_SUMMARY WHERE ROWNUM = 1' INTO v_dummy;
                v_metric_view := 'GV$CON_SYSMETRIC_SUMMARY';
            EXCEPTION
                WHEN OTHERS THEN
                    v_metric_view := 'V$CON_SYSMETRIC_SUMMARY';
                    v_view_has_inst := FALSE;
            END;
        ELSE
            v_metric_view := 'GV$SYSMETRIC_SUMMARY';
        END IF;
    END;

    -- GV$SYSMETRIC_SUMMARY holds one row per instance and metric for the last ~60 minutes, so the value is
    -- the sum of the metric's counters (e.g. read + write), for one instance or all instances (p_inst NULL).
    -- p_pct is not used: there is a single sample per instance.
    FUNCTION metric(p_kind VARCHAR2, p_stat VARCHAR2, p_pct NUMBER, p_inst NUMBER) RETURN NUMBER IS
        v_names VARCHAR2(400); v_div NUMBER; v_dec PLS_INTEGER; v_val NUMBER;
    BEGIN
        metric_def(p_kind, v_names, v_div, v_dec);
        EXECUTE IMMEDIATE
            'SELECT SUM(' || CASE p_stat WHEN 'MAX' THEN 'MAXVAL' ELSE 'AVERAGE' END || ')' ||
            ' FROM ' || v_metric_view ||
            ' WHERE METRIC_NAME IN (' || v_names || ')' ||
            CASE WHEN p_inst IS NOT NULL AND v_view_has_inst THEN ' AND INST_ID = ' || lit(p_inst) END
            INTO v_val;
        RETURN NVL(ROUND(v_val / v_div, v_dec), 0);
    EXCEPTION
        WHEN OTHERS THEN RETURN 0;
    END;

    -- Current SGA, PGA or SGA + PGA (p_part = 'SGA' | 'PGA' | 'TOTAL'), summed across RAC instances
    FUNCTION mem_gb(p_part VARCHAR2) RETURN NUMBER IS
        v_val NUMBER;
        v_expr VARCHAR2(40);
        v_sga NUMBER;
        v_pga NUMBER;
    BEGIN
        IF v_is_pdb = 'YES' THEN
            -- PDB: memory used by this PDB (last minute), 12.2+
            v_expr := CASE p_part WHEN 'SGA' THEN 'SGA_BYTES' WHEN 'PGA' THEN 'PGA_BYTES' ELSE 'SGA_BYTES + PGA_BYTES' END;
            BEGIN
                EXECUTE IMMEDIATE 'SELECT SUM(' || v_expr || ') FROM GV$RSRCPDBMETRIC' INTO v_val;
            EXCEPTION
                WHEN OTHERS THEN
                    EXECUTE IMMEDIATE 'SELECT SUM(' || v_expr || ') FROM V$RSRCPDBMETRIC' INTO v_val;
            END;
        ELSE
            SELECT SUM(VALUE) INTO v_sga FROM GV$SGA;
            SELECT SUM(VALUE) INTO v_pga FROM GV$PGASTAT WHERE NAME = 'total PGA allocated';
            v_val := CASE p_part WHEN 'SGA' THEN v_sga WHEN 'PGA' THEN v_pga ELSE v_sga + v_pga END;
        END IF;
        RETURN NVL(ROUND(v_val / 1073741824, 1), 0);
    EXCEPTION
        WHEN OTHERS THEN RETURN 0;
    END;
    -- <<< metric source <<<

    -- OS statistic for one instance (or the sum over all instances when p_inst is NULL)
    FUNCTION osstat(p_name VARCHAR2, p_inst NUMBER) RETURN NUMBER IS
        v_val NUMBER;
    BEGIN
        SELECT SUM(VALUE) INTO v_val FROM GV$OSSTAT
        WHERE STAT_NAME = p_name AND (p_inst IS NULL OR INST_ID = p_inst);
        RETURN NVL(v_val, 0);
    EXCEPTION
        WHEN OTHERS THEN RETURN 0;
    END;

    -- One CSV row: p_inst = instance number, or NULL for the RAC cluster row (metrics summed over instances)
    PROCEDURE put_row(p_hosts VARCHAR2, p_inst NUMBER) IS
    BEGIN
        DBMS_OUTPUT.PUT_LINE(
            '"' || p_hosts || '",' ||
            v_cdb_name || ',' ||
            v_db_version || ',' ||
            v_db_edition || ',' ||
            v_rac_cluster || ',' ||
            v_nodes || ',' ||
            v_total_pdb_count || ',' ||
            osstat('NUM_CPUS', p_inst) || ',' ||
            ROUND(osstat('PHYSICAL_MEMORY_BYTES', p_inst) / 1073741824) || ',' ||
            -- free memory: per instance, or the average across nodes for the cluster row
            CASE WHEN p_inst IS NULL THEN ROUND(osstat('FREE_MEMORY_BYTES', NULL) / v_nodes / 1073741824)
                 ELSE ROUND(osstat('FREE_MEMORY_BYTES', p_inst) / 1073741824) END || ',' ||
            v_total_storage || ',' ||
            metric('CPU', 'AVG', 0.99, p_inst) || ',' ||
            metric('CPU', 'MAX', 0.90, p_inst) || ',' ||
            metric('IOPS', 'AVG', 0.99, p_inst) || ',' ||
            metric('IOPS', 'MAX', 0.50, p_inst) || ',' ||
            metric('MBPS', 'AVG', 0.99, p_inst) || ',' ||
            metric('MBPS', 'MAX', 0.50, p_inst) || ',' ||
            metric('NET', 'AVG', 0.99, p_inst) || ',' ||
            metric('NET', 'MAX', 0.50, p_inst)
        );
    END;
BEGIN
    -- Version, database name and DBID (V$DATABASE.DBID is the CDB's DBID inside a PDB, as used by AWR)
    SELECT VERSION, TO_NUMBER(REGEXP_SUBSTR(VERSION, '[0-9]+')) INTO v_db_version, v_db_version_num FROM V$INSTANCE;
    SELECT NAME, DBID INTO v_cdb_name, v_dbid FROM V$DATABASE;
    v_con_dbid := v_dbid;

    -- Multitenant: CDB$ROOT (CON_ID 1) or a PDB
    IF v_db_version_num >= 12 THEN
        BEGIN
            EXECUTE IMMEDIATE 'SELECT CDB, SYS_CONTEXT(''USERENV'', ''CON_ID''), SYS_CONTEXT(''USERENV'', ''CON_DBID'') FROM V$DATABASE'
                INTO v_is_cdb, v_con_id, v_con_dbid;
            IF v_is_cdb = 'YES' AND v_con_id > 1 THEN
                v_is_pdb := 'YES';
            END IF;
        EXCEPTION
            WHEN OTHERS THEN NULL;
        END;
    END IF;

    -- RAC: all instances; the server name lists every host
    SELECT COUNT(*), LISTAGG(HOST_NAME, ',') WITHIN GROUP (ORDER BY INSTANCE_NUMBER)
    INTO v_nodes, v_server_name
    FROM GV$INSTANCE;
    BEGIN
        SELECT CASE WHEN UPPER(VALUE) = 'TRUE' THEN 'Y' ELSE 'N' END INTO v_rac_cluster
        FROM V$PARAMETER WHERE NAME = 'cluster_database';
    EXCEPTION
        WHEN OTHERS THEN v_rac_cluster := 'N';
    END;
    IF v_rac_cluster = 'N' THEN
        v_nodes := 1;
    END IF;

    init_source;

    -- Edition from the banner: 'Oracle Database ...' up to 23ai, 'Oracle AI Database ...' from 23.26
    BEGIN
        SELECT CASE
            WHEN UPPER(BANNER) LIKE '%ENTERPRISE%' THEN 'Enterprise Edition'
            WHEN UPPER(BANNER) LIKE '%STANDARD EDITION 2%' THEN 'Standard Edition 2'
            WHEN UPPER(BANNER) LIKE '%STANDARD%' THEN 'Standard Edition'
            WHEN UPPER(BANNER) LIKE '%EXPRESS%' THEN 'Express Edition'
            WHEN UPPER(BANNER) LIKE '%FREE%' THEN 'Free'
            ELSE 'Unknown Edition'
        END INTO v_db_edition
        FROM V$VERSION WHERE BANNER LIKE 'Oracle%Database%' AND ROWNUM = 1;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN v_db_edition := 'Unknown Edition';
    END;

    IF v_is_cdb = 'YES' THEN
        EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM V$PDBS WHERE NAME <> ''PDB$SEED''' INTO v_total_pdb_count;
    END IF;

    -- Total datafile storage (GB). V$DATAFILE covers every container when connected to CDB$ROOT (D5),
    -- the whole database for a non-CDB, and only the PDB's own files inside a PDB.
    SELECT ROUND(NVL(SUM(BYTES), 0) / 1073741824) INTO v_total_storage FROM V$DATAFILE;

    -- One row per instance
    FOR inst IN (SELECT INSTANCE_NUMBER, HOST_NAME FROM GV$INSTANCE ORDER BY INSTANCE_NUMBER) LOOP
        put_row(inst.HOST_NAME, inst.INSTANCE_NUMBER);
    END LOOP;

    -- RAC: cluster row listing every host; metrics are summed across instances (per snapshot)
    IF v_rac_cluster = 'Y' THEN
        put_row(v_server_name, NULL);
    END IF;
END;
/
