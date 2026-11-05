-- Oracle Instance Level Data Collection Script (AWR mode)
-- One row per instance; for RAC an additional cluster row (all hosts) with the cluster totals.
-- Compatible with Oracle 11.2 and above. Run from a non-CDB or CDB$ROOT (a PDB connection reports that PDB).
-- Source: Automatic Workload Repository (DBA_HIST_SYSMETRIC_SUMMARY / DBA_HIST_CON_SYSMETRIC_SUMM),
--         up to the last 30 days of AWR snapshots.
-- LICENSING: AWR requires the Oracle Diagnostics Pack. Ensuring the database is licensed is the
--            customer's responsibility.
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
    -- >>> metric source (AWR) >>>
    v_min_snap_id NUMBER;
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

    -- >>> metric source (AWR) >>>
    PROCEDURE init_source IS
    BEGIN
        -- Lookback: up to the last 30 days of AWR snapshots of this database
        SELECT MIN(SNAP_ID) INTO v_min_snap_id
        FROM DBA_HIST_SNAPSHOT
        WHERE DBID = v_dbid AND BEGIN_INTERVAL_TIME >= SYSDATE - 30;
    EXCEPTION
        WHEN OTHERS THEN v_min_snap_id := NULL;
    END;

    -- Percentile over AWR snapshots. Per snapshot, the metric's counters (e.g. read + write) and,
    -- when p_inst is NULL, all RAC instances are added together before the percentile is taken.
    FUNCTION metric(p_kind VARCHAR2, p_stat VARCHAR2, p_pct NUMBER, p_inst NUMBER) RETURN NUMBER IS
        v_names VARCHAR2(400); v_div NUMBER; v_dec PLS_INTEGER; v_val NUMBER;
    BEGIN
        IF v_min_snap_id IS NULL THEN RETURN 0; END IF;
        metric_def(p_kind, v_names, v_div, v_dec);
        EXECUTE IMMEDIATE
            'SELECT PERCENTILE_CONT(' || lit(p_pct) || ') WITHIN GROUP (ORDER BY total_value)' ||
            ' FROM (SELECT SNAP_ID, SUM(' || CASE p_stat WHEN 'MAX' THEN 'MAXVAL' ELSE 'AVERAGE' END || ') AS total_value' ||
            '       FROM ' || CASE WHEN v_is_pdb = 'YES' THEN 'DBA_HIST_CON_SYSMETRIC_SUMM' ELSE 'DBA_HIST_SYSMETRIC_SUMMARY' END ||
            '       WHERE DBID = ' || lit(v_dbid) || ' AND SNAP_ID >= ' || lit(v_min_snap_id) ||
            '       AND METRIC_NAME IN (' || v_names || ')' ||
            CASE WHEN p_inst IS NOT NULL THEN ' AND INSTANCE_NUMBER = ' || lit(p_inst) END ||
            '       GROUP BY SNAP_ID)'
            INTO v_val;
        RETURN NVL(ROUND(v_val / v_div, v_dec), 0);
    EXCEPTION
        WHEN OTHERS THEN RETURN 0;
    END;

    -- 99th percentile of SGA, PGA or SGA + PGA (p_part = 'SGA' | 'PGA' | 'TOTAL') per snapshot,
    -- summed across RAC instances
    FUNCTION mem_gb(p_part VARCHAR2) RETURN NUMBER IS
        v_val NUMBER;
        v_expr VARCHAR2(40);
    BEGIN
        IF v_min_snap_id IS NULL THEN RETURN 0; END IF;
        IF v_is_pdb = 'YES' THEN
            -- PDB: DBA_HIST_RSRC_PDB_METRIC (one row per instance and snapshot)
            v_expr := CASE p_part WHEN 'SGA' THEN 'SGA_BYTES' WHEN 'PGA' THEN 'PGA_BYTES' ELSE 'SGA_BYTES + PGA_BYTES' END;
            EXECUTE IMMEDIATE
                'SELECT PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY total_mem)
                 FROM (SELECT SNAP_ID, SUM(' || v_expr || ') AS total_mem
                       FROM DBA_HIST_RSRC_PDB_METRIC
                       WHERE CON_DBID = :1 AND SNAP_ID >= :2
                       GROUP BY SNAP_ID)'
                INTO v_val USING v_con_dbid, v_min_snap_id;
        ELSE
            v_expr := CASE p_part WHEN 'SGA' THEN 'sga.total_sga' WHEN 'PGA' THEN 'pga.total_pga' ELSE 'sga.total_sga + pga.total_pga' END;
            EXECUTE IMMEDIATE
                'SELECT PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY ' || v_expr || ')
                 FROM (SELECT SNAP_ID, SUM(BYTES) AS total_sga
                       FROM DBA_HIST_SGASTAT
                       WHERE DBID = :1 AND SNAP_ID >= :2
                       GROUP BY SNAP_ID) sga
                 JOIN (SELECT SNAP_ID, SUM(VALUE) AS total_pga
                       FROM DBA_HIST_PGASTAT
                       WHERE DBID = :3 AND SNAP_ID >= :4 AND NAME = ''total PGA allocated''
                       GROUP BY SNAP_ID) pga ON sga.SNAP_ID = pga.SNAP_ID'
                INTO v_val USING v_dbid, v_min_snap_id, v_dbid, v_min_snap_id;
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
