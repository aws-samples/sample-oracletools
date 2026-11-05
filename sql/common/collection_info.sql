-- Oracle Collection Metadata Script
-- Records how and when the data was collected (mode, metrics window, AWR settings)
-- so that the Python processor can label the report correctly.
-- In NOAWR and STATSPACK mode no DBA_HIST_* view is queried (all AWR queries are dynamic and skipped).
-- STATSPACK: snapshot count and median interval come from STATS$SNAPSHOT; retention is not applicable (blank).
-- Invoked by collect_awr.sql / collect_noawr.sql / collect_statspack.sql (SQL*Plus) or oracle_collector.py (Python).
-- Do not run stand-alone: session settings and spool files are handled by the caller.

-- CSV Header
PROMPT Server Name,CDB/DB Name,Collection Mode,Collection Time,Tool Version,Metrics Window Start,Metrics Window End,Metrics Window (Hours),Snapshot Count,Snapshot Interval (Minutes),AWR Retention (Days)

DECLARE
    c_mode CONSTANT VARCHAR2(10) := UPPER('&&collection_mode');
    v_server_name VARCHAR2(4000);
    v_db_name VARCHAR2(100);
    v_dbid NUMBER;
    v_start DATE;
    v_end DATE;
    v_snaps NUMBER;
    v_interval NUMBER;
    v_retention NUMBER;
    v_con_dbid NUMBER;
    v_sp_owner VARCHAR2(130);

    FUNCTION ts(p_date DATE) RETURN VARCHAR2 IS
    BEGIN
        RETURN TO_CHAR(p_date, 'YYYY-MM-DD HH24:MI:SS');
    END;
BEGIN
    SELECT LISTAGG(HOST_NAME, ',') WITHIN GROUP (ORDER BY INSTANCE_NUMBER)
    INTO v_server_name
    FROM GV$INSTANCE;

    SELECT NAME, DBID INTO v_db_name, v_dbid FROM V$DATABASE;

    IF c_mode = 'AWR' THEN
        -- Same lookback as the AWR collection scripts: up to 30 days
        BEGIN
            EXECUTE IMMEDIATE
                'SELECT CAST(MIN(BEGIN_INTERVAL_TIME) AS DATE), CAST(MAX(END_INTERVAL_TIME) AS DATE), COUNT(DISTINCT SNAP_ID)
                 FROM DBA_HIST_SNAPSHOT
                 WHERE DBID = :1 AND BEGIN_INTERVAL_TIME >= SYSDATE - 30'
                INTO v_start, v_end, v_snaps USING v_dbid;
        EXCEPTION
            WHEN OTHERS THEN NULL;
        END;

        BEGIN
            EXECUTE IMMEDIATE
                'SELECT EXTRACT(DAY FROM SNAP_INTERVAL) * 1440 + EXTRACT(HOUR FROM SNAP_INTERVAL) * 60 + EXTRACT(MINUTE FROM SNAP_INTERVAL),
                        EXTRACT(DAY FROM RETENTION)
                 FROM DBA_HIST_WR_CONTROL
                 WHERE DBID = :1'
                INTO v_interval, v_retention USING v_dbid;
        EXCEPTION
            WHEN OTHERS THEN NULL;
        END;
    ELSIF c_mode = 'STATSPACK' THEN
        v_con_dbid := v_dbid;
        BEGIN
            EXECUTE IMMEDIATE 'SELECT SYS_CONTEXT(''USERENV'', ''CON_DBID'') FROM DUAL' INTO v_con_dbid;
        EXCEPTION
            WHEN OTHERS THEN NULL;
        END;
        BEGIN
            SELECT '"' || OWNER || '"' INTO v_sp_owner
            FROM (SELECT OWNER FROM DBA_TABLES WHERE TABLE_NAME = 'STATS$SNAPSHOT'
                  ORDER BY CASE OWNER WHEN 'PERFSTAT' THEN 0 ELSE 1 END)
            WHERE ROWNUM = 1;
            -- Same lookback as the STATSPACK collection scripts: up to 30 days
            EXECUTE IMMEDIATE
                'SELECT MIN(prev_time), MAX(SNAP_TIME), COUNT(*),
                        ROUND(MEDIAN(CASE WHEN prev_time IS NOT NULL THEN (SNAP_TIME - prev_time) * 1440 END))
                 FROM (SELECT SNAP_TIME, LAG(SNAP_TIME) OVER (PARTITION BY INSTANCE_NUMBER, STARTUP_TIME ORDER BY SNAP_ID) prev_time
                       FROM ' || v_sp_owner || '.STATS$SNAPSHOT
                       WHERE DBID IN (:1, :2) AND SNAP_TIME >= SYSDATE - 31)
                 WHERE SNAP_TIME >= SYSDATE - 30'
                INTO v_start, v_end, v_snaps, v_interval USING v_dbid, v_con_dbid;
        EXCEPTION
            WHEN OTHERS THEN
                v_snaps := 0;
        END;
    ELSE
        BEGIN
            SELECT MIN(BEGIN_TIME), MAX(END_TIME) INTO v_start, v_end FROM GV$SYSMETRIC_SUMMARY;
            IF v_start IS NULL THEN
                -- Inside a PDB the container-level view is populated instead
                EXECUTE IMMEDIATE 'SELECT MIN(BEGIN_TIME), MAX(END_TIME) FROM V$CON_SYSMETRIC_SUMMARY' INTO v_start, v_end;
            END IF;
        EXCEPTION
            WHEN OTHERS THEN NULL;
        END;
    END IF;

    DBMS_OUTPUT.PUT_LINE(
        '"' || v_server_name || '",' ||
        v_db_name || ',' ||
        c_mode || ',' ||
        TO_CHAR(SYSTIMESTAMP, 'YYYY-MM-DD HH24:MI:SS TZH:TZM') || ',' ||
        '&&tool_version' || ',' ||
        ts(v_start) || ',' ||
        ts(v_end) || ',' ||
        TO_CHAR(ROUND((v_end - v_start) * 24, 1)) || ',' ||
        v_snaps || ',' ||
        v_interval || ',' ||
        v_retention
    );
END;
/
