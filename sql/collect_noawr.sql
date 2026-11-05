-- =============================================================================
-- oracletools - Oracle inventory and performance data collection (non-AWR mode)
--
-- Use this mode when the database is NOT licensed for the Oracle Diagnostics
-- Pack (for example Standard Edition 2). It does not touch any DBA_HIST_* view.
-- Performance metrics come from GV$SYSMETRIC_SUMMARY / V$CON_SYSMETRIC_SUMMARY,
-- which only cover the LAST ~60 MINUTES. Run it during peak business hours,
-- and preferably several times (different days / batch windows).
--
-- Usage (run from THIS directory; results are written to ./output):
--   cd sql
--   sqlplus <user>@//<host>:<port>/<service> @collect_noawr.sql
-- Read-only: SELECT and session settings only. Use a dedicated read-only user (not SYS / SYSDBA);
-- required privileges: docs/prerequisites.md, objects read: docs/data-access.md.
-- =============================================================================
DEFINE collection_mode = NOAWR
DEFINE collection_dir = noawr
@_collect.sql
