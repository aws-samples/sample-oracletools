-- Oracle Database Level Data Collection Script (non-AWR mode)
-- One row for the current container: non-CDB, CDB$ROOT or a PDB. The caller runs it once per container.
-- Performance metrics are for the whole database (summed across RAC instances); a PDB row uses the PDB's own metrics.
-- Compatible with Oracle 11.2 and above.
-- Source: GV$SYSMETRIC_SUMMARY / GV$CON_SYSMETRIC_SUMMARY (the last ~60 minutes). No AWR view is used.
--         These views hold one value per instance, so the 'percentile' columns are that value
--         (summed across instances for RAC / cluster figures).
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
