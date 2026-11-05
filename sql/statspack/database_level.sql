-- Oracle Database Level Data Collection Script (STATSPACK mode)
-- One row for the current container: non-CDB, CDB$ROOT or a PDB. The caller runs it once per container.
-- Performance metrics are for the whole database (summed across RAC instances); a PDB row uses the PDB's own metrics.
-- Compatible with Oracle 11.2 and above.
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
PROMPT Server Name,CDB/DB Name,Database Name,CPU Average 99th Percentile,CPU Maximum 90th Percentile,IOPS Average 99th Percentile,IOPS Maximum 50th Percentile,Throughput Average 99th Percentile (MB/s),Throughput Maximum 50th Percentile (MB/s),SGA+PGA Total (GB),Storage Allocated (GB),Storage Used (GB),Table Count,Views Count,Index Count,SP Count,Function Count,Triggers Count,Table w/o PK,Table w/o Key,RedoRate Average 99th Percentile (MB/s),RedoRate Maximum 50th Percentile (MB/s),SGA (GB),PGA (GB)

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
    v_database_name VARCHAR2(128);
    v_owner_filter VARCHAR2(4000);
    v_storage_allocated NUMBER;
    v_storage_used NUMBER;
    v_table_count NUMBER;
    v_view_count NUMBER;
    v_index_count NUMBER;
    v_sp_count NUMBER;
    v_function_count NUMBER;
    v_trigger_count NUMBER;
    v_table_no_pk NUMBER;
    v_table_no_key NUMBER;
    -- Oracle-supplied schemas excluded from storage and object counts (D15: on 12c+ every
    -- ORACLE_MAINTAINED = 'Y' user is excluded as well; this list covers 11g and tool schemas)
    c_system_schemas CONSTANT VARCHAR2(2000) := '''SYS'',''SYSTEM'',''OUTLN'',''DBSNMP'',''APPQOSSYS'',''DBSFWUSER'',''GGSYS'',''ANONYMOUS'',''CTXSYS'',''DVF'',''DVSYS'',''GSMADMIN_INTERNAL'',''LBACSYS'',''MDSYS'',''OJVMSYS'',''OLAPSYS'',''ORDDATA'',''ORDSYS'',''ORDPLUGINS'',''SI_INFORMTN_SCHEMA'',''WMSYS'',''XDB'',''RDSADMIN'',''AUDSYS'',''GSMUSER'',''DIP'',''GSMCATUSER'',''MDDATA'',''APEX_PUBLIC_USER'',''FLOWS_FILES'',''SYSRAC'',''SYSDG'',''SYSKM'',''SYSBACKUP'',''XS$NULL'',''SPATIAL_CSW_ADMIN_USR'',''SPATIAL_WFS_ADMIN_USR'',''EXFSYS'',''MGMT_VIEW'',''SYSMAN'',''OWBSYS'',''OWBSYS_AUDIT'',''REMOTE_SCHEDULER_AGENT'',''PERFSTAT''';
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

    -- COUNT(*) of a dictionary view restricted to application schemas
    FUNCTION app_count(p_from VARCHAR2, p_owner_col VARCHAR2, p_extra VARCHAR2 DEFAULT NULL) RETURN NUMBER IS
        v_val NUMBER;
    BEGIN
        EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM ' || p_from || ' WHERE ' ||
            REPLACE(v_owner_filter, 'OWNER', p_owner_col) || p_extra
            INTO v_val;
        RETURN v_val;
    EXCEPTION
        WHEN OTHERS THEN RETURN 0;
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

    v_database_name := v_cdb_name;
    IF v_is_pdb = 'YES' THEN
        v_database_name := SYS_CONTEXT('USERENV', 'CON_NAME');
    END IF;

    -- Application schemas: not in the fixed list, not APEX, and (12c+) not Oracle-maintained
    v_owner_filter := 'OWNER NOT IN (' || c_system_schemas || ') AND OWNER NOT LIKE ''APEX%''';
    IF v_db_version_num >= 12 THEN
        v_owner_filter := v_owner_filter ||
            ' AND OWNER NOT IN (SELECT USERNAME FROM DBA_USERS WHERE ORACLE_MAINTAINED = ''Y'')';
    END IF;

    -- Storage allocated: datafiles of this container (GB, 3 decimals)
    SELECT ROUND(NVL(SUM(BYTES), 0) / 1073741824, 3) INTO v_storage_allocated FROM DBA_DATA_FILES;

    -- Storage used: segments of application schemas (GB, 3 decimals)
    EXECUTE IMMEDIATE 'SELECT ROUND(NVL(SUM(BYTES), 0) / 1073741824, 3) FROM DBA_SEGMENTS WHERE ' || v_owner_filter
        INTO v_storage_used;

    v_table_count    := app_count('DBA_TABLES', 'OWNER');
    v_view_count     := app_count('DBA_VIEWS', 'OWNER');
    v_index_count    := app_count('DBA_INDEXES', 'OWNER');
    -- Standalone procedures and functions only (D17: members of packages are not counted)
    v_sp_count       := app_count('DBA_PROCEDURES', 'OWNER', ' AND OBJECT_TYPE = ''PROCEDURE''');
    v_function_count := app_count('DBA_PROCEDURES', 'OWNER', ' AND OBJECT_TYPE = ''FUNCTION''');
    v_trigger_count  := app_count('DBA_TRIGGERS', 'OWNER');
    -- Tables without a primary key: every table counts, also when names repeat across schemas (D9)
    v_table_no_pk    := app_count('DBA_TABLES t', 't.OWNER',
        ' AND NOT EXISTS (SELECT 1 FROM DBA_CONSTRAINTS c WHERE c.OWNER = t.OWNER' ||
        ' AND c.TABLE_NAME = t.TABLE_NAME AND c.CONSTRAINT_TYPE = ''P'')');
    -- Tables without any key AWS DMS can use to identify rows: no primary key and no unique index whose
    -- columns are all NOT NULL table columns (function-based, hidden-column and LOB indexes do not count as a key)
    v_table_no_key   := app_count('DBA_TABLES t', 't.OWNER',
        ' AND NOT EXISTS (SELECT 1 FROM DBA_CONSTRAINTS c WHERE c.OWNER = t.OWNER' ||
        ' AND c.TABLE_NAME = t.TABLE_NAME AND c.CONSTRAINT_TYPE = ''P'')' ||
        ' AND NOT EXISTS (SELECT 1 FROM DBA_INDEXES i WHERE i.TABLE_OWNER = t.OWNER' ||
        ' AND i.TABLE_NAME = t.TABLE_NAME AND i.UNIQUENESS = ''UNIQUE'' AND i.INDEX_TYPE <> ''LOB''' ||
        ' AND EXISTS (SELECT 1 FROM DBA_IND_COLUMNS ic0 WHERE ic0.INDEX_OWNER = i.OWNER AND ic0.INDEX_NAME = i.INDEX_NAME)' ||
        ' AND NOT EXISTS (SELECT 1 FROM DBA_IND_COLUMNS ic WHERE ic.INDEX_OWNER = i.OWNER AND ic.INDEX_NAME = i.INDEX_NAME' ||
        ' AND NOT EXISTS (SELECT 1 FROM DBA_TAB_COLUMNS tc WHERE tc.OWNER = ic.TABLE_OWNER AND tc.TABLE_NAME = ic.TABLE_NAME' ||
        ' AND tc.COLUMN_NAME = ic.COLUMN_NAME AND tc.NULLABLE = ''N'')))');

    DBMS_OUTPUT.PUT_LINE(
        '"' || v_server_name || '",' ||
        v_cdb_name || ',' ||
        v_database_name || ',' ||
        metric('CPU', 'AVG', 0.99, NULL) || ',' ||
        metric('CPU', 'MAX', 0.90, NULL) || ',' ||
        metric('IOPS', 'AVG', 0.99, NULL) || ',' ||
        metric('IOPS', 'MAX', 0.50, NULL) || ',' ||
        metric('MBPS', 'AVG', 0.99, NULL) || ',' ||
        metric('MBPS', 'MAX', 0.50, NULL) || ',' ||
        mem_gb('TOTAL') || ',' ||
        v_storage_allocated || ',' ||
        v_storage_used || ',' ||
        v_table_count || ',' ||
        v_view_count || ',' ||
        v_index_count || ',' ||
        v_sp_count || ',' ||
        v_function_count || ',' ||
        v_trigger_count || ',' ||
        v_table_no_pk || ',' ||
        v_table_no_key || ',' ||
        metric('REDO', 'AVG', 0.99, NULL) || ',' ||
        metric('REDO', 'MAX', 0.50, NULL) || ',' ||
        mem_gb('SGA') || ',' ||
        mem_gb('PGA')
    );
END;
/
