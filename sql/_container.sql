-- =============================================================================
-- oracletools - collects database level data and features for the CURRENT
-- container (non-CDB, CDB$ROOT or a PDB). Called by _collect.sql and by the
-- generated output/<prefix>_pdb_loop.sql. Do not call directly.
-- =============================================================================
-- Re-apply session state: PL/SQL package state (DBMS_OUTPUT) and NLS are per container
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
ALTER SESSION SET NLS_NUMERIC_CHARACTERS = '.,';

-- File name prefix: <server>_<db name>_<container> (CDB$ROOT -> cdb).
-- The first query works on every version; the second (12c+) overrides it with
-- the container name and silently fails on 11g.
SET TERMOUT OFF
COLUMN db_prefix NEW_VALUE db_prefix NOPRINT
SELECT LOWER(SYS_CONTEXT('USERENV', 'SERVER_HOST')) || '_' || LOWER(NAME) || '_' || LOWER(NAME) AS db_prefix FROM V$DATABASE;
SELECT LOWER(SYS_CONTEXT('USERENV', 'SERVER_HOST')) || '_' || LOWER(NAME) || '_' ||
       LOWER(REPLACE(REPLACE(SYS_CONTEXT('USERENV', 'CON_NAME'), 'CDB$ROOT', 'CDB'), '$', '_')) AS db_prefix
FROM V$DATABASE;
SET TERMOUT ON

PROMPT       database level  -> output/&db_prefix._oracle_database_level_data.csv
SPOOL output/&db_prefix._oracle_database_level_data.csv
@&collection_dir/database_level.sql
SPOOL OFF

PROMPT       features        -> output/&db_prefix._oracle_database_features.csv
SPOOL output/&db_prefix._oracle_database_features.csv
@common/database_features.sql
SPOOL OFF
