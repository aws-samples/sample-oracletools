-- Oracle Database Level Data Collection Script (AWR mode)
-- One row for the current container: non-CDB, CDB$ROOT or a PDB. The caller runs it once per container.
-- Performance metrics are for the whole database (summed across RAC instances); a PDB row uses the PDB's own metrics.
-- Compatible with Oracle 11.2 and above.
-- Source: Automatic Workload Repository (DBA_HIST_SYSMETRIC_SUMMARY / DBA_HIST_CON_SYSMETRIC_SUMM),
--         up to the last 30 days of AWR snapshots.
-- LICENSING: AWR requires the Oracle Diagnostics Pack. Ensuring the database is licensed is the
--            customer's responsibility.
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
