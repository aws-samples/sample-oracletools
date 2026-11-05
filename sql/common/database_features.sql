-- Oracle Database Features Collection Script
-- Compatible with Oracle 11g and above
-- Based on aws_awr_miner.sql DBA_FEATURE_USAGE_STATISTICS methodology
-- Run as the read-only collection user (CREATE SESSION + SELECT ANY DICTIONARY)
-- Invoked by collect_awr.sql / collect_noawr.sql / collect_statspack.sql (SQL*Plus) or oracle_collector.py (Python).
-- Do not run stand-alone: session settings and spool files are handled by the caller.

-- CSV Header
PROMPT Server Name,CDB/DB Name,Database Name,Feature Usage,DB Link,SA privilege,Jobs,BI Components,HA Setup,Ent. Edition feature usage

DECLARE
    v_server_name VARCHAR2(4000);
    v_cdb_name VARCHAR2(100);
    v_database_name VARCHAR2(100);
    v_feature_usage VARCHAR2(4000);
    v_db_link_count NUMBER;
    v_sa_privilege_count NUMBER;
    v_jobs_count NUMBER;
    v_bi_components VARCHAR2(400) := 'None';
    v_ha_setup VARCHAR2(200) := 'None';
    v_ee_features VARCHAR2(4000);
    v_db_version_num NUMBER;
    v_is_cdb VARCHAR2(3) := 'NO';
    v_con_id NUMBER := 0;
    v_dbid NUMBER;
    v_db_role VARCHAR2(30);
    v_rac_cluster VARCHAR2(1) := 'N';
    v_pdb_count NUMBER := 0;
    -- Oracle-supplied schemas excluded from counts (on 12c+ ORACLE_MAINTAINED = 'Y' is excluded as well)
    c_system_schemas CONSTANT VARCHAR2(2000) := '''SYS'',''SYSTEM'',''OUTLN'',''DBSNMP'',''APPQOSSYS'',''DBSFWUSER'',''GGSYS'',''ANONYMOUS'',''CTXSYS'',''DVF'',''DVSYS'',''GSMADMIN_INTERNAL'',''LBACSYS'',''MDSYS'',''OJVMSYS'',''OLAPSYS'',''ORDDATA'',''ORDSYS'',''ORDPLUGINS'',''SI_INFORMTN_SCHEMA'',''WMSYS'',''XDB'',''RDSADMIN'',''AUDSYS'',''GSMUSER'',''DIP'',''GSMCATUSER'',''MDDATA'',''APEX_PUBLIC_USER'',''FLOWS_FILES'',''SYSRAC'',''SYSDG'',''SYSKM'',''SYSBACKUP'',''XS$NULL'',''SPATIAL_CSW_ADMIN_USR'',''SPATIAL_WFS_ADMIN_USR'',''EXFSYS'',''MGMT_VIEW'',''SYSMAN'',''OWBSYS'',''OWBSYS_AUDIT'',''REMOTE_SCHEDULER_AGENT'',''PERFSTAT''';
BEGIN
    -- RAC: cluster_database = TRUE, the same rule as the instance and database level scripts (so a RAC with
    -- stopped instances and RAC One Node are reported as RAC too); the server name lists every running host
    BEGIN
        SELECT CASE WHEN UPPER(VALUE) = 'TRUE' THEN 'Y' ELSE 'N' END INTO v_rac_cluster
        FROM V$PARAMETER WHERE NAME = 'cluster_database';
    EXCEPTION
        WHEN OTHERS THEN v_rac_cluster := 'N';
    END;
    IF v_rac_cluster = 'Y' THEN
        -- Get comma-separated list of all hosts for RAC
        SELECT LISTAGG(HOST_NAME, ',') WITHIN GROUP (ORDER BY INSTANCE_NUMBER)
        INTO v_server_name
        FROM GV$INSTANCE;
    ELSE
        -- Get single server name for non-RAC (use HOST_NAME for consistency with instance level)
        SELECT HOST_NAME INTO v_server_name FROM V$INSTANCE;
    END IF;
    
    -- Get CDB/DB Name and DBID
    SELECT NAME, DBID INTO v_cdb_name, v_dbid FROM V$DATABASE;
    
    -- Get DB Version
    SELECT TO_NUMBER(REGEXP_SUBSTR(VERSION, '[0-9]+')) INTO v_db_version_num FROM V$INSTANCE;
    
    -- Determine if CDB and get database/PDB name
    IF v_db_version_num >= 12 THEN
        BEGIN
            EXECUTE IMMEDIATE 'SELECT CDB FROM V$DATABASE' INTO v_is_cdb;
            EXECUTE IMMEDIATE 'SELECT SYS_CONTEXT(''USERENV'',''CON_ID'') FROM DUAL' INTO v_con_id;
            
            IF v_is_cdb = 'YES' THEN
                -- dynamic SQL: V$PDBS does not exist on 11g, a static reference would not compile there
                EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM V$PDBS WHERE NAME <> ''PDB$SEED''' INTO v_pdb_count;
            END IF;
            IF v_is_cdb = 'YES' AND v_con_id != 1 THEN
                EXECUTE IMMEDIATE 'SELECT SYS_CONTEXT(''USERENV'',''CON_NAME'') FROM DUAL' INTO v_database_name;
            ELSE
                v_database_name := v_cdb_name;
            END IF;
        EXCEPTION
            WHEN OTHERS THEN
                v_database_name := v_cdb_name;
        END;
    ELSE
        v_database_name := v_cdb_name;
    END IF;
    
    -- Get Feature Usage from DBA_FEATURE_USAGE_STATISTICS (all features from aws_awr_miner.sql)
    BEGIN
        SELECT LISTAGG(NAME, ', ') WITHIN GROUP (ORDER BY NAME)
        INTO v_feature_usage
        FROM (
            SELECT DISTINCT NAME 
            FROM DBA_FEATURE_USAGE_STATISTICS 
            WHERE DETECTED_USAGES > 0 
            AND CURRENTLY_USED = 'TRUE'
            AND DBID = v_dbid
            AND NAME IN (
                'Active Data Guard',
                'Active Data Guard - Real-Time Query on Physical Standby',
                'Advanced Compression',
                'Advanced Replication',
                'Advanced Security',
                'Application Express',
                'Data Guard',
                'Data Mining',
                'Data Redaction',
                'Database Vault',
                'Diagnostics Pack',
                'Editioning Views',
                'Exadata',
                'Fine Grained Audit',
                'GoldenGate',
                'Hybrid Columnar Compression',
                'In-Memory Column Store',
                'In-Memory Database',
                'Java Virtual Machine (user)',
                'Label Security',
                'Multitenant',
                'Online Redefinition',
                'One Node',
                'Oracle In-Database Hadoop',
                'Oracle Multitenant',
                'Partitioning',
                'Partitioning (user)',
                'Parallel SQL Query Execution',
                'RAC',
                'Real Application Cluster One Node',
                'Real Application Clusters',
                'Real Application Clusters (RAC)',
                'Real Application Security',
                'Resource Manager',
                'Shard Database',
                'Spatial',
                'Transparent Data Encryption',
                'Tuning Pack',
                'Virtual Private Database (VPD)'
            )
        );
    EXCEPTION
        WHEN OTHERS THEN
            v_feature_usage := NULL;
    END;
    
    -- Count DB links of application users. Links owned by Oracle-maintained users (e.g. SYS.SYS_HUB, present
    -- in every 12.2+ CDB root and PDB) are excluded; PUBLIC links are counted (applications create them too)
    BEGIN
        IF v_db_version_num >= 12 THEN
            EXECUTE IMMEDIATE
                'SELECT COUNT(*) FROM DBA_DB_LINKS
                 WHERE OWNER NOT IN (' || c_system_schemas || ')
                 AND (OWNER = ''PUBLIC'' OR OWNER NOT IN (SELECT USERNAME FROM DBA_USERS WHERE ORACLE_MAINTAINED = ''Y''))'
                INTO v_db_link_count;
        ELSE
            EXECUTE IMMEDIATE
                'SELECT COUNT(*) FROM DBA_DB_LINKS WHERE OWNER NOT IN (' || c_system_schemas || ')'
                INTO v_db_link_count;
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            v_db_link_count := 0;
    END;
    
    -- Count users with administrative privileges (SYSDBA, SYSOPER, and on 12c+ SYSBACKUP, SYSDG, SYSKM),
    -- excluding SYS and SYSTEM. These are privileges recorded in the password file, not roles.
    BEGIN
        IF v_db_version_num >= 12 THEN
            EXECUTE IMMEDIATE
                'SELECT COUNT(DISTINCT USERNAME) FROM V$PWFILE_USERS
                 WHERE USERNAME NOT IN (''SYS'', ''SYSTEM'')
                 AND (SYSDBA = ''TRUE'' OR SYSOPER = ''TRUE'' OR SYSBACKUP = ''TRUE'' OR SYSDG = ''TRUE'' OR SYSKM = ''TRUE'')'
                INTO v_sa_privilege_count;
        ELSE
            SELECT COUNT(DISTINCT USERNAME) INTO v_sa_privilege_count FROM V$PWFILE_USERS
            WHERE USERNAME NOT IN ('SYS', 'SYSTEM') AND (SYSDBA = 'TRUE' OR SYSOPER = 'TRUE');
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            v_sa_privilege_count := 0;
    END;

    -- Count enabled jobs owned by application users (Oracle-maintained owners excluded;
    -- ORACLE_MAINTAINED exists from 12c, the fixed list is used on 11g)
    BEGIN
        IF v_db_version_num >= 12 THEN
            EXECUTE IMMEDIATE
                'SELECT COUNT(*) FROM DBA_SCHEDULER_JOBS
                 WHERE ENABLED = ''TRUE''
                 AND OWNER NOT IN (SELECT USERNAME FROM DBA_USERS WHERE ORACLE_MAINTAINED = ''Y'')
                 AND OWNER NOT IN (' || c_system_schemas || ')'
                INTO v_jobs_count;
        ELSE
            EXECUTE IMMEDIATE
                'SELECT (SELECT COUNT(*) FROM DBA_SCHEDULER_JOBS WHERE ENABLED = ''TRUE'' AND OWNER NOT IN (' || c_system_schemas || '))
                      + (SELECT COUNT(*) FROM DBA_JOBS WHERE BROKEN = ''N'' AND LOG_USER NOT IN (' || c_system_schemas || '))
                 FROM DUAL'
                INTO v_jobs_count;
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            v_jobs_count := 0;
    END;

    -- BI / middleware repositories: schemas created by the Fusion Middleware Repository Creation Utility
    -- (RCU) are named <PREFIX>_<COMPONENT>, e.g. DEV_BIPLATFORM, PRD_MDS; unprefixed names are matched too.
    BEGIN
        SELECT NVL(LISTAGG(component, ', ') WITHIN GROUP (ORDER BY component), 'None')
        INTO v_bi_components
        FROM (
            SELECT DISTINCT
                   CASE
                       WHEN REGEXP_LIKE(USERNAME, '(^|_)(BIPLATFORM|BI_CLIENT|BIACOMP|BIACM_IO|BIA_OTBI)$') THEN 'Oracle Business Intelligence'
                       WHEN REGEXP_LIKE(USERNAME, '(^|_)(SOAINFRA|ORASDPM|UMS|ESS)$') THEN 'Oracle SOA Suite'
                       WHEN REGEXP_LIKE(USERNAME, '(^|_)ODI_REPO$') THEN 'Oracle Data Integrator'
                       WHEN REGEXP_LIKE(USERNAME, '(^|_)(MDS|OPSS|IAU|IAU_APPEND|IAU_VIEWER|STB|WLS|WLS_RUNTIME)$') THEN 'Oracle Fusion Middleware'
                   END AS component
            FROM DBA_USERS
            WHERE REGEXP_LIKE(USERNAME, '(^|_)(BIPLATFORM|BI_CLIENT|BIACOMP|BIACM_IO|BIA_OTBI|SOAINFRA|ORASDPM|UMS|ESS|ODI_REPO|MDS|OPSS|IAU|IAU_APPEND|IAU_VIEWER|STB|WLS|WLS_RUNTIME)$')
        );
    EXCEPTION
        WHEN OTHERS THEN
            v_bi_components := 'None';
    END;

    -- HA setup: every mechanism found, e.g. 'RAC, Data Guard'
    DECLARE
        v_items VARCHAR2(200);
        v_cnt NUMBER;
    BEGIN
        SELECT DATABASE_ROLE INTO v_db_role FROM V$DATABASE;
        IF v_rac_cluster = 'Y' THEN
            v_items := 'RAC';
        END IF;
        -- Data Guard: this database is a standby, or a Data Guard configuration / standby destination exists
        SELECT COUNT(*) INTO v_cnt FROM V$ARCHIVE_DEST
        WHERE STATUS = 'VALID' AND TARGET = 'STANDBY';
        IF v_db_role LIKE '%STANDBY%' OR v_cnt > 0 THEN
            v_items := v_items || CASE WHEN v_items IS NOT NULL THEN ', ' END || 'Data Guard';
        ELSE
            SELECT COUNT(*) INTO v_cnt FROM V$DATAGUARD_CONFIG WHERE UPPER(DB_UNIQUE_NAME) <> UPPER(SYS_CONTEXT('USERENV', 'DB_UNIQUE_NAME'));
            IF v_cnt > 0 THEN
                v_items := v_items || CASE WHEN v_items IS NOT NULL THEN ', ' END || 'Data Guard';
            END IF;
        END IF;
        SELECT COUNT(*) INTO v_cnt FROM DBA_FEATURE_USAGE_STATISTICS
        WHERE NAME LIKE 'Active Data Guard%' AND CURRENTLY_USED = 'TRUE' AND DBID = v_dbid;
        IF v_cnt > 0 THEN
            v_items := v_items || CASE WHEN v_items IS NOT NULL THEN ', ' END || 'Active Data Guard';
        END IF;
        v_ha_setup := NVL(v_items, 'None');
    EXCEPTION
        WHEN OTHERS THEN
            v_ha_setup := NVL(v_items, 'None');
    END;

    -- Get Enterprise Edition Feature Usage (features NOT available in Standard Edition)
    -- These features require Enterprise Edition and would need alternatives if downgrading to SE
    BEGIN
        SELECT LISTAGG(feature, '; ') WITHIN GROUP (ORDER BY feature)
        INTO v_ee_features
        FROM (
            -- Partitioning
            SELECT 'Partitioning' AS feature FROM DUAL 
            WHERE EXISTS (
                SELECT 1 FROM DBA_FEATURE_USAGE_STATISTICS 
                WHERE NAME IN ('Partitioning', 'Partitioning (user)')
                AND CURRENTLY_USED = 'TRUE'
                AND DBID = v_dbid
            )
            UNION ALL
            -- Advanced Compression
            SELECT 'Advanced Compression' FROM DUAL 
            WHERE EXISTS (
                SELECT 1 FROM DBA_FEATURE_USAGE_STATISTICS 
                WHERE NAME = 'Advanced Compression'
                AND CURRENTLY_USED = 'TRUE'
                AND DBID = v_dbid
            )
            UNION ALL
            -- Parallel SQL Query Execution
            SELECT 'Parallel SQL Query Execution' FROM DUAL 
            WHERE EXISTS (
                SELECT 1 FROM DBA_FEATURE_USAGE_STATISTICS 
                WHERE NAME = 'Parallel SQL Query Execution'
                AND CURRENTLY_USED = 'TRUE'
                AND DBID = v_dbid
            )
            UNION ALL
            -- Materialized Views with Query Rewrite
            SELECT 'Materialized Views with Query Rewrite' FROM DUAL 
            WHERE EXISTS (SELECT 1 FROM DBA_MVIEWS WHERE REWRITE_ENABLED = 'Y' AND ROWNUM = 1)
            UNION ALL
            -- Data Guard
            SELECT 'Data Guard' FROM DUAL 
            WHERE EXISTS (SELECT 1 FROM V$DATAGUARD_CONFIG WHERE ROWNUM = 1)
            UNION ALL
            -- Active Data Guard
            SELECT 'Active Data Guard' FROM DUAL 
            WHERE EXISTS (
                SELECT 1 FROM DBA_FEATURE_USAGE_STATISTICS 
                WHERE NAME LIKE 'Active Data Guard%'
                AND CURRENTLY_USED = 'TRUE'
                AND DBID = v_dbid
            )
            UNION ALL
            -- RAC (Real Application Clusters)
            SELECT 'Real Application Clusters (RAC)' FROM DUAL 
            WHERE v_rac_cluster = 'Y'
            UNION ALL
            -- Advanced Security / TDE
            SELECT 'Transparent Data Encryption' FROM DUAL 
            WHERE EXISTS (
                SELECT 1 FROM DBA_FEATURE_USAGE_STATISTICS 
                WHERE NAME = 'Transparent Data Encryption'
                AND CURRENTLY_USED = 'TRUE'
                AND DBID = v_dbid
            )
            UNION ALL
            -- Label Security
            SELECT 'Label Security' FROM DUAL 
            WHERE EXISTS (
                SELECT 1 FROM DBA_FEATURE_USAGE_STATISTICS 
                WHERE NAME = 'Label Security'
                AND CURRENTLY_USED = 'TRUE'
                AND DBID = v_dbid
            )
            UNION ALL
            -- Database Vault
            SELECT 'Database Vault' FROM DUAL 
            WHERE EXISTS (
                SELECT 1 FROM DBA_FEATURE_USAGE_STATISTICS 
                WHERE NAME = 'Database Vault'
                AND CURRENTLY_USED = 'TRUE'
                AND DBID = v_dbid
            )
            UNION ALL
            -- In-Memory Database
            SELECT 'In-Memory Column Store' FROM DUAL 
            WHERE EXISTS (
                SELECT 1 FROM DBA_FEATURE_USAGE_STATISTICS 
                WHERE NAME IN ('In-Memory Column Store', 'In-Memory Database')
                AND CURRENTLY_USED = 'TRUE'
                AND DBID = v_dbid
            )
            UNION ALL
            -- Multitenant (>3 PDBs requires EE)
            SELECT 'Multitenant (>3 PDBs)' FROM DUAL 
            WHERE v_pdb_count > 3
            UNION ALL
            -- Online Redefinition
            SELECT 'Online Redefinition' FROM DUAL 
            WHERE EXISTS (
                SELECT 1 FROM DBA_FEATURE_USAGE_STATISTICS 
                WHERE NAME = 'Online Redefinition'
                AND CURRENTLY_USED = 'TRUE'
                AND DBID = v_dbid
            )
            UNION ALL
            -- Fine Grained Audit
            SELECT 'Fine Grained Audit' FROM DUAL 
            WHERE EXISTS (
                SELECT 1 FROM DBA_FEATURE_USAGE_STATISTICS 
                WHERE NAME = 'Fine Grained Audit'
                AND CURRENTLY_USED = 'TRUE'
                AND DBID = v_dbid
            )
            UNION ALL
            -- Virtual Private Database
            SELECT 'Virtual Private Database (VPD)' FROM DUAL 
            WHERE EXISTS (
                SELECT 1 FROM DBA_FEATURE_USAGE_STATISTICS 
                WHERE NAME = 'Virtual Private Database (VPD)'
                AND CURRENTLY_USED = 'TRUE'
                AND DBID = v_dbid
            )
            UNION ALL
            -- Advanced Replication
            SELECT 'Advanced Replication' FROM DUAL 
            WHERE EXISTS (
                SELECT 1 FROM DBA_FEATURE_USAGE_STATISTICS 
                WHERE NAME = 'Advanced Replication'
                AND CURRENTLY_USED = 'TRUE'
                AND DBID = v_dbid
            )
            UNION ALL
            -- Spatial
            SELECT 'Spatial' FROM DUAL 
            WHERE EXISTS (
                SELECT 1 FROM DBA_FEATURE_USAGE_STATISTICS 
                WHERE NAME = 'Spatial'
                AND CURRENTLY_USED = 'TRUE'
                AND DBID = v_dbid
            )
            UNION ALL
            -- Data Mining
            SELECT 'Data Mining' FROM DUAL 
            WHERE EXISTS (
                SELECT 1 FROM DBA_FEATURE_USAGE_STATISTICS 
                WHERE NAME = 'Data Mining'
                AND CURRENTLY_USED = 'TRUE'
                AND DBID = v_dbid
            )
            UNION ALL
            -- Real Application Security
            SELECT 'Real Application Security' FROM DUAL 
            WHERE EXISTS (
                SELECT 1 FROM DBA_FEATURE_USAGE_STATISTICS 
                WHERE NAME = 'Real Application Security'
                AND CURRENTLY_USED = 'TRUE'
                AND DBID = v_dbid
            )
            UNION ALL
            -- Diagnostics Pack
            SELECT 'Diagnostics Pack' FROM DUAL 
            WHERE EXISTS (
                SELECT 1 FROM DBA_FEATURE_USAGE_STATISTICS 
                WHERE NAME = 'Diagnostics Pack'
                AND CURRENTLY_USED = 'TRUE'
                AND DBID = v_dbid
            )
            UNION ALL
            -- Tuning Pack
            SELECT 'Tuning Pack' FROM DUAL 
            WHERE EXISTS (
                SELECT 1 FROM DBA_FEATURE_USAGE_STATISTICS 
                WHERE NAME = 'Tuning Pack'
                AND CURRENTLY_USED = 'TRUE'
                AND DBID = v_dbid
            )
        );
    EXCEPTION
        WHEN OTHERS THEN
            v_ee_features := NULL;
    END;
    
    -- Output CSV row
    DBMS_OUTPUT.PUT_LINE(
        '"' || v_server_name || '",' ||
        v_cdb_name || ',' ||
        v_database_name || ',' ||
        '"' || NVL(v_feature_usage, '') || '",' ||
        v_db_link_count || ',' ||
        v_sa_privilege_count || ',' ||
        v_jobs_count || ',' ||
        '"' || v_bi_components || '",' ||
        '"' || v_ha_setup || '",' ||
        '"' || NVL(v_ee_features, '') || '"'
    );
END;
/
