-- =============================================================================
-- oracletools - Oracle inventory and performance data collection (STATSPACK mode)
--
-- Use this mode when the database is NOT licensed for the Oracle Diagnostics
-- Pack but STATSPACK is installed and taking snapshots (for example Standard
-- Edition 2). It reads up to 30 days of STATSPACK history (STATS$* tables of
-- the PERFSTAT schema) and does not touch any DBA_HIST_* view.
--
-- STATSPACK must be installed in the container being collected (non-CDB, or
-- each PDB). Containers without STATSPACK report 0 for performance metrics;
-- inventory, storage, object and feature data are always collected.
--
-- Usage (run from THIS directory; results are written to ./output):
--   cd sql
--   sqlplus <user>@//<host>:<port>/<service> @collect_statspack.sql
-- The user needs SELECT on the PERFSTAT.STATS$ tables in addition to the dictionary
-- privileges (docs/prerequisites.md).
-- Read-only: SELECT and session settings only. Use a dedicated read-only user (not SYS / SYSDBA);
-- required privileges: docs/prerequisites.md, objects read: docs/data-access.md.
-- =============================================================================
DEFINE collection_mode = STATSPACK
DEFINE collection_dir = statspack
@_collect.sql
