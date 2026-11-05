# Data accessed by oracletools

This page is meant for security and DBA review. It lists everything the collection scripts read
from the database, why, and what they do **not** do. The same SQL files are used by both
scenarios (SQL*Plus and Python), so this list applies to both.

## Summary

| | |
|---|---|
| Statements executed | `SELECT` on data dictionary, dynamic performance, AWR or STATSPACK views/tables; anonymous PL/SQL blocks that only run those `SELECT`s and print the results with `DBMS_OUTPUT` |
| Session settings | `ALTER SESSION SET NLS_NUMERIC_CHARACTERS = '.,'` (decimal point in the CSV); `ALTER SESSION SET CONTAINER = <pdb>` / `CDB$ROOT` (CDB only, to visit each open PDB). Both last only for the session. |
| Not executed | no `INSERT`, `UPDATE`, `DELETE`, `MERGE`; no `CREATE`, `ALTER` (other than the session settings above), `DROP`, `GRANT`, `TRUNCATE`; no `ALTER SYSTEM`; no AWR / STATSPACK snapshots; no installation of objects, packages or users |
| Application data | not read. Object counts and sizes come from the data dictionary, not from application tables. |
| Data leaving the database | CSV files written on the machine that runs SQL*Plus or Python (`sql/output/` or `<output>/raw/`). Nothing is sent over the network by oracletools. |
| Personal data in the output | host names, database / PDB names, and counts. Usernames are not written to the CSV files (only counts). |
| Load | a few seconds to minutes per database: aggregate queries over up to 30 days of AWR or STATSPACK history and dictionary counts. |

The SQL files are plain text in `sql/` and can be reviewed before running:
`sql/collect_*.sql` (entry points), `sql/_collect.sql`, `sql/_container.sql`, `sql/common/*.sql`,
and `sql/awr/`, `sql/statspack/`, `sql/noawr/` (one folder per mode). Locally, SQL*Plus also writes a
small generated script `sql/output/<server>_<db>_pdb_loop.sql` that lists the open PDBs to visit.

## Objects read in every mode

| Object | Data used | Purpose |
|---|---|---|
| `V$DATABASE` | name, DBID, CDB flag, database role | identify the database; standby role for HA setup |
| `V$INSTANCE`, `GV$INSTANCE` | version, instance number, host name | version; RAC instances and hosts |
| `V$VERSION` | banner | edition (Enterprise / Standard Edition 2) |
| `V$PARAMETER` | `cluster_database` | detect RAC |
| `V$PDBS` | PDB names and open mode | PDB count; list of PDBs to collect |
| `GV$OSSTAT` | `NUM_CPUS`, `PHYSICAL_MEMORY_BYTES`, `FREE_MEMORY_BYTES` | host vCPU and memory |
| `V$DATAFILE` | file sizes | host total storage (all containers of a CDB) |
| `DBA_DATA_FILES` | file sizes | storage allocated to the container |
| `DBA_SEGMENTS` | segment sizes (application schemas) | storage used |
| `DBA_TABLES`, `DBA_VIEWS`, `DBA_INDEXES`, `DBA_PROCEDURES`, `DBA_TRIGGERS` | counts per object type (application schemas) | object inventory |
| `DBA_CONSTRAINTS` | primary key constraints | tables without a primary key (migration with change data capture) |
| `DBA_INDEXES`, `DBA_IND_COLUMNS`, `DBA_TAB_COLUMNS` | unique indexes, their columns and the columns' NULLABLE flag | tables without any usable key (count only) |
| `DBA_USERS` | `ORACLE_MAINTAINED` flag; names of BI / middleware repository schemas | exclude Oracle-supplied schemas from counts; detect BI components |
| `DBA_FEATURE_USAGE_STATISTICS` | features currently used | feature usage; Enterprise Edition features |
| `DBA_MVIEWS` | materialized views with query rewrite | Enterprise Edition feature |
| `DBA_DB_LINKS` | count (owners other than Oracle-maintained users; PUBLIC included) | database links |
| `DBA_SCHEDULER_JOBS`, `DBA_JOBS` | count of enabled jobs (application schemas) | job inventory |
| `V$PWFILE_USERS` | count of users with SYSDBA / SYSOPER / SYSBACKUP / SYSDG / SYSKM | administrative privilege count (no usernames are written) |
| `V$DATAGUARD_CONFIG`, `V$ARCHIVE_DEST` | Data Guard members, standby destinations | HA setup |
| `SYS_CONTEXT('USERENV', ...)` | `SERVER_HOST`, `CON_ID`, `CON_NAME`, `CON_DBID`, `DB_UNIQUE_NAME` | current host and container |

## Additional objects per mode

### AWR mode (default) – requires the Oracle Diagnostics Pack licence

| Object | Data used | Purpose |
|---|---|---|
| `DBA_HIST_SNAPSHOT` | snapshot ids and times (last 30 days) | lookback window |
| `DBA_HIST_WR_CONTROL` | snapshot interval, retention | collection information |
| `DBA_HIST_SYSMETRIC_SUMMARY` | `Host CPU Usage Per Sec`, `Physical Read/Write Total IO Requests Per Sec`, `Physical Read/Write Total Bytes Per Sec`, `Network Traffic Volume Per Sec`, `Redo Generated Per Sec` | CPU, IOPS, throughput, network and redo percentiles (non-CDB, `CDB$ROOT`) |
| `DBA_HIST_CON_SYSMETRIC_SUMM` | `CPU Usage Per Sec` and the I/O, network and redo metrics above | the same percentiles for a PDB |
| `DBA_HIST_SGASTAT`, `DBA_HIST_PGASTAT` | SGA size, `total PGA allocated` | SGA+PGA percentile |
| `DBA_HIST_RSRC_PDB_METRIC` | `SGA_BYTES`, `PGA_BYTES` | SGA+PGA percentile of a PDB |

### STATSPACK mode – STATSPACK must already be installed

| Object | Data used | Purpose |
|---|---|---|
| `DBA_TABLES` | owner of `STATS$SNAPSHOT` | locate the STATSPACK schema (normally `PERFSTAT`) |
| `PERFSTAT.STATS$SNAPSHOT` | snapshot ids and times (last 30 days) | lookback window and interval |
| `PERFSTAT.STATS$SYSSTAT` | `physical read/write total IO requests`, `physical read/write total bytes`, `bytes sent/received via SQL*Net to/from client/dblink`, `redo size` | IOPS, throughput, network and redo |
| `PERFSTAT.STATS$OSSTAT`, `PERFSTAT.STATS$OSSTATNAME` | `BUSY_TIME` | host CPU |
| `PERFSTAT.STATS$SYS_TIME_MODEL`, `PERFSTAT.STATS$TIME_MODEL_STATNAME` | `DB CPU`, `background cpu time` | database CPU (PDB rows) |
| `PERFSTAT.STATS$SGASTAT`, `PERFSTAT.STATS$PGASTAT` | SGA size, `total PGA allocated` | SGA+PGA percentile |

### Non-AWR mode – no licence or STATSPACK needed

| Object | Data used | Purpose |
|---|---|---|
| `GV$SYSMETRIC_SUMMARY` | the metrics listed for AWR mode, last ~60 minutes | CPU, IOPS, throughput, network and redo (non-CDB, `CDB$ROOT`) |
| `GV$CON_SYSMETRIC_SUMMARY` (fallback `V$CON_SYSMETRIC_SUMMARY`) | the same metrics for the current PDB | PDB metrics |
| `GV$SGA`, `GV$PGASTAT` | current SGA, `total PGA allocated` | SGA+PGA |
| `GV$RSRCPDBMETRIC` (fallback `V$RSRCPDBMETRIC`) | `SGA_BYTES`, `PGA_BYTES` | SGA+PGA of a PDB |

In non-AWR and STATSPACK mode, no `DBA_HIST_*` view is queried. The AWR queries in the shared
collection-information script are dynamic SQL that only runs in AWR mode.

## Python collector (scenario 2)

`oracle_collector.py collect` connects with python-oracledb and runs the PL/SQL blocks from the
same SQL files. In addition it runs:

- `SELECT ... FROM V$DATABASE / V$INSTANCE / V$PDBS` and `SYS_CONTEXT('USERENV', ...)` to name the
  output files and find the open PDBs;
- `DBMS_OUTPUT.ENABLE` and `DBMS_OUTPUT.GET_LINES` to read the rows the blocks print (session
  buffer only);
- the same `ALTER SESSION` settings as SQL*Plus.

Passwords are read from an environment variable, the configuration file or an interactive
prompt; they are never written to the output or the log.

## Privileges

See [prerequisites.md](prerequisites.md).
