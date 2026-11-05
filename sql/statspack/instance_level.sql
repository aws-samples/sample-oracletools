-- Oracle Instance Level Data Collection Script (STATSPACK mode)
-- One row per instance; for RAC an additional cluster row (all hosts) with the cluster totals.
-- Compatible with Oracle 11.2 and above. Run from a non-CDB or CDB$ROOT (a PDB connection reports that PDB).
-- Source: STATSPACK (STATS$SNAPSHOT, STATS$SYSSTAT, STATS$OSSTAT, STATS$SYS_TIME_MODEL, STATS$SGASTAT,
--         STATS$PGASTAT), up to the last 30 days of snapshots. No AWR view is used.
--         Rates are counter deltas between consecutive snapshots divided by the elapsed time.
--         STATSPACK has no within-interval peaks, so the 'Maximum' columns are the stated percentile of the
--         per-interval averages (best-effort match to the AWR columns). On RAC, each instance has its own
--         snapshot ids, so instances are added per 10-minute bucket of snapshot time.
--         In a PDB, STATSPACK records instance-wide statistics, so PDB values include the whole instance.
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
    -- >>> metric source (STATSPACK) >>>
    v_sp_owner VARCHAR2(128);
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

    -- >>> metric source (STATSPACK) >>>
    PROCEDURE init_source IS
    BEGIN
        -- Schema that owns the STATSPACK repository (normally PERFSTAT)
        SELECT OWNER INTO v_sp_owner
        FROM (SELECT OWNER FROM DBA_TABLES WHERE TABLE_NAME = 'STATS$SNAPSHOT'
              ORDER BY CASE OWNER WHEN 'PERFSTAT' THEN 0 ELSE 1 END)
        WHERE ROWNUM = 1;
        v_sp_owner := '"' || v_sp_owner || '"';
    EXCEPTION
        WHEN OTHERS THEN v_sp_owner := NULL;
    END;

    -- STATSPACK stores the DBID of V$DATABASE; inside a PDB that may be the CDB's or the PDB's DBID
    FUNCTION sp_dbid RETURN VARCHAR2 IS
    BEGIN
        RETURN 'DBID IN (' || lit(v_dbid) || ', ' || lit(v_con_dbid) || ')';
    END;

    -- Cumulative counter values per instance and snapshot for one metric
    FUNCTION sp_values(p_kind VARCHAR2) RETURN VARCHAR2 IS
        v_names VARCHAR2(400);
    BEGIN
        IF p_kind = 'CPU' AND v_is_pdb = 'NO' THEN
            -- Host CPU: OS busy time in centiseconds
            RETURN 'SELECT INSTANCE_NUMBER, SNAP_ID, SUM(VALUE) AS VALUE FROM ' || v_sp_owner || '.STATS$OSSTAT' ||
                   ' WHERE ' || sp_dbid ||
                   ' AND OSSTAT_ID IN (SELECT OSSTAT_ID FROM ' || v_sp_owner || '.STATS$OSSTATNAME WHERE STAT_NAME = ''BUSY_TIME'')' ||
                   ' GROUP BY INSTANCE_NUMBER, SNAP_ID';
        ELSIF p_kind = 'CPU' THEN
            -- PDB: database CPU of the container (DB CPU + background CPU, microseconds -> centiseconds)
            RETURN 'SELECT INSTANCE_NUMBER, SNAP_ID, SUM(VALUE) / 10000 AS VALUE FROM ' || v_sp_owner || '.STATS$SYS_TIME_MODEL' ||
                   ' WHERE ' || sp_dbid ||
                   ' AND STAT_ID IN (SELECT STAT_ID FROM ' || v_sp_owner || '.STATS$TIME_MODEL_STATNAME' ||
                   '                 WHERE STAT_NAME IN (''DB CPU'', ''background cpu time''))' ||
                   ' GROUP BY INSTANCE_NUMBER, SNAP_ID';
        END IF;
        v_names := CASE p_kind
            WHEN 'IOPS' THEN '''physical read total IO requests'',''physical write total IO requests'''
            WHEN 'MBPS' THEN '''physical read total bytes'',''physical write total bytes'''
            WHEN 'NET'  THEN '''bytes sent via SQL*Net to client'',''bytes received via SQL*Net from client'',' ||
                             '''bytes sent via SQL*Net to dblink'',''bytes received via SQL*Net from dblink'''
            ELSE '''redo size''' END;
        RETURN 'SELECT INSTANCE_NUMBER, SNAP_ID, SUM(VALUE) AS VALUE FROM ' || v_sp_owner || '.STATS$SYSSTAT' ||
               ' WHERE ' || sp_dbid || ' AND NAME IN (' || v_names || ')' ||
               ' GROUP BY INSTANCE_NUMBER, SNAP_ID';
    END;

    -- Percentile over STATSPACK snapshot intervals (last 30 days). Rate = counter delta / elapsed seconds
    -- between consecutive snapshots of the same instance startup. Instances are added per 10-minute bucket
    -- of snapshot time (RAC instances have their own snapshot ids). There are no within-interval peaks,
    -- so p_stat = 'MAX' uses the same per-interval averages.
    FUNCTION metric(p_kind VARCHAR2, p_stat VARCHAR2, p_pct NUMBER, p_inst NUMBER) RETURN NUMBER IS
        v_names VARCHAR2(400); v_div NUMBER; v_dec PLS_INTEGER; v_val NUMBER;
    BEGIN
        IF v_sp_owner IS NULL THEN RETURN 0; END IF;
        metric_def(p_kind, v_names, v_div, v_dec);
        EXECUTE IMMEDIATE
            'WITH snaps AS (' ||
            '  SELECT INSTANCE_NUMBER, SNAP_ID, SNAP_TIME, STARTUP_TIME,' ||
            '         LAG(SNAP_TIME) OVER (PARTITION BY INSTANCE_NUMBER, STARTUP_TIME ORDER BY SNAP_ID) AS PREV_TIME' ||
            '  FROM ' || v_sp_owner || '.STATS$SNAPSHOT WHERE ' || sp_dbid || ' AND SNAP_TIME >= SYSDATE - 31),' ||
            ' vals AS (' || sp_values(p_kind) || '),' ||
            ' d AS (' ||
            '  SELECT s.INSTANCE_NUMBER, s.SNAP_TIME, (s.SNAP_TIME - s.PREV_TIME) * 86400 AS ELA,' ||
            '         v.VALUE - LAG(v.VALUE) OVER (PARTITION BY s.INSTANCE_NUMBER, s.STARTUP_TIME ORDER BY s.SNAP_ID) AS DELTA' ||
            '  FROM snaps s JOIN vals v ON v.INSTANCE_NUMBER = s.INSTANCE_NUMBER AND v.SNAP_ID = s.SNAP_ID),' ||
            ' b AS (' ||
            '  SELECT TRUNC(SNAP_TIME + 2/1440, ''HH24'') + FLOOR(TO_NUMBER(TO_CHAR(SNAP_TIME + 2/1440, ''MI'')) / 10) * 10/1440 AS BUCKET,' ||
            '         INSTANCE_NUMBER, MAX(DELTA / ELA) AS RATE' ||
            '  FROM d WHERE ELA > 0 AND DELTA >= 0 AND SNAP_TIME >= SYSDATE - 30' ||
            CASE WHEN p_inst IS NOT NULL THEN ' AND INSTANCE_NUMBER = ' || lit(p_inst) END ||
            '  GROUP BY TRUNC(SNAP_TIME + 2/1440, ''HH24'') + FLOOR(TO_NUMBER(TO_CHAR(SNAP_TIME + 2/1440, ''MI'')) / 10) * 10/1440, INSTANCE_NUMBER)' ||
            ' SELECT PERCENTILE_CONT(' || lit(p_pct) || ') WITHIN GROUP (ORDER BY TOTAL)' ||
            ' FROM (SELECT BUCKET, SUM(RATE) AS TOTAL FROM b GROUP BY BUCKET)'
            INTO v_val;
        RETURN NVL(ROUND(v_val / v_div, v_dec), 0);
    EXCEPTION
        WHEN OTHERS THEN RETURN 0;
    END;

    -- 99th percentile of SGA, PGA or SGA + PGA (p_part = 'SGA' | 'PGA' | 'TOTAL') per snapshot,
    -- instances added per 10-minute bucket
    FUNCTION mem_gb(p_part VARCHAR2) RETURN NUMBER IS
        v_val NUMBER;
    BEGIN
        IF v_sp_owner IS NULL THEN RETURN 0; END IF;
        EXECUTE IMMEDIATE
            'WITH mem AS (' ||
            '  SELECT DBID, INSTANCE_NUMBER, SNAP_ID, SUM(VALUE) AS TOTAL FROM (' ||
            CASE WHEN p_part IN ('SGA', 'TOTAL') THEN
            '    SELECT DBID, INSTANCE_NUMBER, SNAP_ID, BYTES AS VALUE FROM ' || v_sp_owner || '.STATS$SGASTAT WHERE ' || sp_dbid END ||
            CASE WHEN p_part = 'TOTAL' THEN
            '    UNION ALL' END ||
            CASE WHEN p_part IN ('PGA', 'TOTAL') THEN
            '    SELECT DBID, INSTANCE_NUMBER, SNAP_ID, VALUE FROM ' || v_sp_owner || '.STATS$PGASTAT WHERE ' || sp_dbid ||
            '    AND NAME = ''total PGA allocated''' END ||
            '  ) GROUP BY DBID, INSTANCE_NUMBER, SNAP_ID),' ||
            ' b AS (' ||
            '  SELECT TRUNC(s.SNAP_TIME + 2/1440, ''HH24'') + FLOOR(TO_NUMBER(TO_CHAR(s.SNAP_TIME + 2/1440, ''MI'')) / 10) * 10/1440 AS BUCKET,' ||
            '         m.INSTANCE_NUMBER, MAX(m.TOTAL) AS TOTAL' ||
            '  FROM mem m JOIN ' || v_sp_owner || '.STATS$SNAPSHOT s' ||
            '    ON s.DBID = m.DBID AND s.INSTANCE_NUMBER = m.INSTANCE_NUMBER AND s.SNAP_ID = m.SNAP_ID' ||
            '  WHERE s.SNAP_TIME >= SYSDATE - 30' ||
            '  GROUP BY TRUNC(s.SNAP_TIME + 2/1440, ''HH24'') + FLOOR(TO_NUMBER(TO_CHAR(s.SNAP_TIME + 2/1440, ''MI'')) / 10) * 10/1440, m.INSTANCE_NUMBER)' ||
            ' SELECT PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY TOTAL) FROM (SELECT BUCKET, SUM(TOTAL) AS TOTAL FROM b GROUP BY BUCKET)'
            INTO v_val;
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
