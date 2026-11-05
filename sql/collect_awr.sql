-- =============================================================================
-- oracletools - Oracle inventory and performance data collection (AWR mode)
--
-- AWR mode is the DEFAULT and recommended mode. It reads up to 30 days of
-- history from the Automatic Workload Repository (DBA_HIST_* views).
--
-- LICENSING: Accessing AWR (DBA_HIST_* views) requires an Oracle Diagnostics
-- Pack licence (Enterprise Edition only). It is the customer's responsibility
-- to make sure the database is licensed for the Diagnostics Pack before
-- running this script. If it is not, use collect_noawr.sql instead.
--
-- Usage (run from THIS directory; results are written to ./output):
--   cd sql
--   sqlplus <user>@//<host>:<port>/<service> @collect_awr.sql
-- Read-only: SELECT and session settings only. Use a dedicated read-only user (not SYS / SYSDBA);
-- required privileges: docs/prerequisites.md, objects read: docs/data-access.md.
--
-- Connect to the CDB root (CDB$ROOT) or to a non-CDB. From the CDB root the
-- script also collects every open PDB automatically. For RAC, connect to any
-- one instance; all instances are collected.
-- =============================================================================
PROMPT
PROMPT *** AWR mode: queries DBA_HIST_* views (Oracle Diagnostics Pack licence required).
PROMPT *** Ensuring the database is licensed is the customer's responsibility.
PROMPT *** Press Ctrl+C now if this database is not licensed, and use collect_noawr.sql instead.
PROMPT
DEFINE collection_mode = AWR
DEFINE collection_dir = awr
@_collect.sql
