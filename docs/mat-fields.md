# MAT inventory fields

This page describes every column of `mat_oracle_inventory.csv` (written with `--mat`), in
template order: what the field means, and where oracletools takes its value from. The
column layout follows [`templates/oracle-inventory-template.csv`](../templates/oracle-inventory-template.csv).

How to read the *Source* column:

- **Collected column**: the column in the collected CSV files (and in `oracle_inventory.csv`)
  that the field is copied from.
- **Script**: the SQL file that produces it. `<mode>` is `awr`, `statspack` or `noawr`; the
  three versions differ only in where the performance metrics come from (see
  [data-access.md](data-access.md)).
- **Row**: MAT gets one row per database: a non-CDB, the `CDB$ROOT` of a CDB, or each open PDB.
  `cluster*` fields come from the instance-level data of the row's database (the cluster row
  for RAC, so the whole cluster). `db*` and the other *Database* fields come from that row's own
  container.

Numbers keep the collected precision (CPU 3 decimals, IOPS 2, MB/s 4, GB 1–3); fields of
type *integer* in the template are rounded. An empty source value is written as `0`.

## Identity

| Field | Meaning | Source in oracletools |
|---|---|---|
| `dbIdentifier` | Unique name of the row, `<CDB or DB name>/<container name>`, e.g. `ORCLCDB/PDB1`, `ORCLCDB/ORCLCDB` (root), `SALES/SALES` (non-CDB). | `CDB/DB Name` + `/` + `Database Name`. If the same name is collected on two servers, `@<server>` is appended to keep it unique. |
| `sourceEngine` | Source engine. | Always `oracle`. |
| `migrationSchemas` | Application schemas to migrate. | Not collected (needs a decision by the customer); left blank. |

## Cluster (host / RAC cluster of the database)

| Field | Meaning | Source in oracletools |
|---|---|---|
| `clusterName` | Server name, or all node names for RAC. | `Server Name` (`GV$INSTANCE.HOST_NAME`, every instance), short host names joined with `-`, e.g. `racnode1-racnode2`. |
| `cdbName` | Container database the row belongs to. | `CDB/DB Name` (`V$DATABASE.NAME`) for `CDB$ROOT` and PDB rows; blank for a non-CDB. |
| `dbEngineVersion` | Full Oracle version, e.g. `19.0.0.0.0`. | `Database Version`: `V$INSTANCE.VERSION` (`sql/<mode>/instance_level.sql`). |
| `dbEngineEdition` | Edition: `Enterprise Edition`, `Standard Edition 2`, `Standard Edition`, `Express Edition`, `Free` (23ai Free). | `Database Edition`: `V$VERSION` banner (`instance_level.sql`). |
| `isRacCluster` | `Y` for RAC, else `N`. | `RAC Cluster`: `V$PARAMETER cluster_database = TRUE` (`instance_level.sql`). |
| `nodeCount` | Number of RAC instances (1 when not RAC). | `Nodes`: `COUNT(*) FROM GV$INSTANCE` for RAC, else 1. |
| `pdbCount` | Number of PDBs in the CDB, excluding `PDB$SEED`; 0 for a non-CDB. Same value on every row of the CDB. | `Total PDB Count`: `V$PDBS` (`instance_level.sql`). |
| `clusterVcpuCount` | Logical CPUs of the server; RAC: sum over all nodes. | `vCPU Count`: `GV$OSSTAT NUM_CPUS`. |
| `clusterTotalMemoryGb` | Physical memory of the server in GB; RAC: sum over all nodes. | `Total Memory (GB)`: `GV$OSSTAT PHYSICAL_MEMORY_BYTES`. |
| `clusterFreeMemoryGb` | Free memory in GB at the time of collection; RAC: average per node. | `Free Memory (GB)`: `GV$OSSTAT FREE_MEMORY_BYTES`. |
| `clusterTotalStorageGb` | Size of all datafiles of the database in GB; for a CDB, every container. | `Total Storage (GB)`: `SUM(BYTES) FROM V$DATAFILE`, collected from the CDB root or the non-CDB. |
| `clusterCpuAvgP99` | CPUs busy (vCPU-equivalents, not %) on the server, 99th percentile of the per-snapshot averages. RAC: nodes added per snapshot. | `CPU Average 99th Percentile` (instance level). AWR: `DBA_HIST_SYSMETRIC_SUMMARY 'Host CPU Usage Per Sec'` / 100. STATSPACK: `STATS$OSSTAT BUSY_TIME` delta per second / 100. Non-AWR: `GV$SYSMETRIC_SUMMARY 'Host CPU Usage Per Sec'` / 100 (last ~60 min). |
| `clusterCpuMaxP90` | CPUs busy, 90th percentile of the per-snapshot peaks. | `CPU Maximum 90th Percentile`: as above, `MAXVAL` instead of `AVERAGE`. STATSPACK has no peaks: 90th percentile of the interval averages. |
| `clusterIopsAvgP99` | Total (read + write) I/O requests per second on the server, 99th percentile of the per-snapshot averages. | `IOPS Average 99th Percentile`: `Physical Read Total IO Requests Per Sec` + `Physical Write Total IO Requests Per Sec` (AWR / non-AWR); STATSPACK: `STATS$SYSSTAT physical read/write total IO requests` deltas. |
| `clusterIopsMaxP50` | Total IOPS, median of the per-snapshot peaks (read peak + write peak). | `IOPS Maximum 50th Percentile`: as above, `MAXVAL`; STATSPACK: median of interval averages. |
| `clusterThroughputAvgP99` | Total (read + write) I/O throughput in MB/s, 99th percentile of the per-snapshot averages. | `Throughput Average 99th Percentile (MB/s)`: `Physical Read/Write Total Bytes Per Sec`; STATSPACK: `physical read/write total bytes` deltas. |
| `clusterThroughputMaxP50` | Total throughput in MB/s, median of the per-snapshot peaks. | `Throughput Maximum 50th Percentile (MB/s)`: as above, `MAXVAL`. |
| `clusterNetThroughputAvg` | Oracle network traffic (clients and database links) in MB/s. Despite the name, the 99th percentile of the per-snapshot averages. | `Network Throughput Average (MB/s)`: `Network Traffic Volume Per Sec`; STATSPACK: `bytes sent/received via SQL*Net to/from client/dblink` deltas. |
| `clusterNetThroughputMax` | Network traffic in MB/s, median of the per-snapshot peaks. | `Network Throughput Maximum (MB/s)`: as above, `MAXVAL`. |

## Database (the row's own container)

| Field | Meaning | Source in oracletools |
|---|---|---|
| `sgaPgaTotalGb` | SGA + PGA in GB: 99th percentile per snapshot (AWR, STATSPACK) or current allocation (non-AWR), summed across RAC instances. | `SGA+PGA Total (GB)` (`sql/<mode>/database_level.sql`). Non-CDB / `CDB$ROOT`: `DBA_HIST_SGASTAT` + `DBA_HIST_PGASTAT 'total PGA allocated'` (AWR), `STATS$SGASTAT` + `STATS$PGASTAT` (STATSPACK), `GV$SGA` + `GV$PGASTAT` (non-AWR). PDB: `DBA_HIST_RSRC_PDB_METRIC` (AWR) or `GV$RSRCPDBMETRIC` (non-AWR) `SGA_BYTES + PGA_BYTES`. |
| `storageAllocatedGb` | Datafiles of this container in GB (`CDB$ROOT` row: root only; PDB row: that PDB). | `Storage Allocated (GB)`: `SUM(BYTES) FROM DBA_DATA_FILES`. |
| `storageUsedGb` | Space used by application schemas in GB. | `Storage Used (GB)`: `SUM(BYTES) FROM DBA_SEGMENTS`, Oracle-maintained schemas excluded (see note below). |
| `tableCount` | Tables in application schemas. | `Table Count`: `DBA_TABLES`. |
| `viewCount` | Views in application schemas. | `Views Count`: `DBA_VIEWS`. |
| `indexCount` | Indexes in application schemas. | `Index Count`: `DBA_INDEXES`. |
| `storedProcCount` | Standalone procedures (members of packages are not counted). | `SP Count`: `DBA_PROCEDURES OBJECT_TYPE = 'PROCEDURE'`. |
| `functionCount` | Standalone functions (members of packages are not counted). | `Function Count`: `DBA_PROCEDURES OBJECT_TYPE = 'FUNCTION'`. |
| `triggerCount` | Triggers in application schemas. | `Triggers Count`: `DBA_TRIGGERS`. |
| `trustworthyProperty` | SQL Server property with no Oracle equivalent; not used for Oracle. | Not collected. Always written as `None` (the template's default). |
| `tablesWithoutPk` | Tables in application schemas without a primary key, counted per table across schemas. Relevant for change data capture (AWS DMS, GoldenGate). | `Table w/o PK`: `DBA_TABLES` with no `DBA_CONSTRAINTS` row of type `P`. |
| `tablesWithoutKeyCount` | Tables in application schemas with neither a primary key nor a unique index on NOT NULL columns: AWS DMS cannot identify their rows during change data capture. | `Table w/o Key`: `DBA_TABLES` with no primary key (`DBA_CONSTRAINTS`) and no unique index (`DBA_INDEXES`) whose columns (`DBA_IND_COLUMNS`) are all NOT NULL (`DBA_TAB_COLUMNS`); function-based index columns do not count. Blank for files collected before version 1.1.0 (blank = not collected). |
| `tablesWithoutKey` | The tables counted in `tablesWithoutKeyCount`, as `OWNER.TABLE`. | Not collected (oracletools writes no schema or table names); left blank. |
| `featureUsage` | Tracked Oracle features currently in use, comma separated, `None` if empty. | `Feature Usage`: `DBA_FEATURE_USAGE_STATISTICS` with `CURRENTLY_USED = 'TRUE'`, `DETECTED_USAGES > 0`, for a fixed list of 39 features (e.g. Partitioning, Advanced Compression, Database Vault, Oracle Multitenant, Real Application Security, Transparent Data Encryption) (`sql/common/database_features.sql`). Reflects Oracle's last feature-usage sample (weekly by default). |
| `dbLinkCount` | Database links of application users, including PUBLIC links. Links owned by Oracle-maintained users (e.g. `SYS.SYS_HUB`) are excluded. | `DB Link`: `COUNT(*) FROM DBA_DB_LINKS` without Oracle-maintained owners (`ORACLE_MAINTAINED = 'Y'` on 12c+, plus a fixed list; `PUBLIC` kept). |
| `saPrivilegeCount` | Users other than SYS and SYSTEM with SYSDBA, SYSOPER, SYSBACKUP, SYSDG or SYSKM. Only the count is collected. | `SA privilege`: `V$PWFILE_USERS`. |
| `jobCount` | Enabled scheduler jobs owned by application schemas (11g: plus non-broken `DBA_JOBS`). | `Jobs`: `DBA_SCHEDULER_JOBS` (and `DBA_JOBS` on 11g), Oracle-maintained owners excluded. |
| `biComponents` | BI / middleware repositories in the database: Oracle Business Intelligence, Oracle SOA Suite, Oracle Data Integrator, Oracle Fusion Middleware; `None` if none. | `BI Components`: `DBA_USERS` names created by the Repository Creation Utility, with or without prefix (e.g. `DEV_BIPLATFORM`, `DEV_MDS`, `SOAINFRA`, `DEV_ODI_REPO`). |
| `haSetup` | High availability in place, comma separated: `RAC`, `Data Guard`, `Active Data Guard`; `None` if none. | `HA Setup`: RAC when `GV$INSTANCE` has more than one instance; Data Guard when `V$DATABASE.DATABASE_ROLE` is a standby, `V$ARCHIVE_DEST` has a valid standby destination, or `V$DATAGUARD_CONFIG` has other members; Active Data Guard from `DBA_FEATURE_USAGE_STATISTICS`. |
| `eeFeatureUsage` | Enterprise Edition-only features in use (relevant for a move to Standard Edition 2), comma separated, `None` if empty. | `Ent. Edition feature usage` (`;` separated in the collected file): `DBA_FEATURE_USAGE_STATISTICS` currently used for Partitioning, Advanced Compression, Parallel SQL Query Execution, Active Data Guard, Transparent Data Encryption, Label Security, Database Vault, In-Memory, Online Redefinition, Fine Grained Audit, VPD, Advanced Replication, Spatial, Data Mining, Real Application Security, Diagnostics Pack, Tuning Pack; plus materialized views with query rewrite (`DBA_MVIEWS`), Data Guard (`V$DATAGUARD_CONFIG`), RAC (more than one instance) and Multitenant with more than 3 PDBs (`V$PDBS`). |
| `dbCpuAvgP99` | CPUs busy for this row, 99th percentile of the per-snapshot averages, summed across RAC instances. Non-CDB and `CDB$ROOT` rows use host CPU; a PDB row uses the PDB's own CPU. | `CPU Average 99th Percentile` (database level). AWR: `DBA_HIST_SYSMETRIC_SUMMARY 'Host CPU Usage Per Sec'` (non-CDB, root) or `DBA_HIST_CON_SYSMETRIC_SUMM 'CPU Usage Per Sec'` (PDB), / 100. STATSPACK: `STATS$OSSTAT BUSY_TIME` (non-CDB, root) or `STATS$SYS_TIME_MODEL 'DB CPU' + 'background cpu time'` (PDB). Non-AWR: `GV$SYSMETRIC_SUMMARY` / `GV$CON_SYSMETRIC_SUMMARY`. |
| `dbCpuMaxP90` | CPUs busy, 90th percentile of the per-snapshot peaks. | `CPU Maximum 90th Percentile`: as above, `MAXVAL`. |
| `dbIopsAvgP99` | Total (read + write) IOPS of this row, 99th percentile of the per-snapshot averages. | `IOPS Average 99th Percentile`: same metrics as `clusterIopsAvgP99`, from the container's view (`DBA_HIST_CON_SYSMETRIC_SUMM` / `GV$CON_SYSMETRIC_SUMMARY` for a PDB). |
| `dbIopsMaxP50` | Total IOPS, median of the per-snapshot peaks. | `IOPS Maximum 50th Percentile`. |
| `dbThroughputAvgP99` | Total (read + write) throughput in MB/s, 99th percentile of the per-snapshot averages. | `Throughput Average 99th Percentile (MB/s)`. |
| `dbThroughputMaxP50` | Total throughput in MB/s, median of the per-snapshot peaks. | `Throughput Maximum 50th Percentile (MB/s)`. |
| `dbRedoRateAvgP99` | Redo generated in MB/s, 99th percentile of the per-snapshot averages. | `RedoRate Average 99th Percentile (MB/s)`: `Redo Generated Per Sec` (AWR / non-AWR); STATSPACK: `STATS$SYSSTAT 'redo size'` delta per second. |
| `dbRedoRateMaxP50` | Redo generated in MB/s, median of the per-snapshot peaks. | `RedoRate Maximum 50th Percentile (MB/s)`. |

## Questionnaire (not collected)

These fields are the customer's or the migration team's decisions. oracletools leaves them
blank; fill them in the CSV or in MAT.

| Field | Meaning |
|---|---|
| `isIsvCotsApplication` | `Y` if the database serves an ISV / commercial off-the-shelf application. |
| `isCompatibleWithMinimumVersion` | `Y` if the (non-COTS) application supports the minimum target database version. |
| `isCOTSApplicationCompatibleWithMinimumSupportedVersion` | `Y` if the COTS vendor certifies the minimum target version. |
| `osLevelAccessRequired` | `Y` if the application or DBAs need operating-system access to the database host. |
| `systemAccessRequired` | `Y` if the application needs SYSDBA / SYS-level access. |
| `preferLicenseIncluded` | `Y` for License Included pricing, `N` for Bring Your Own License. |
| `optimiseForLicense` | `Y` to prefer the fewest vCPUs (licence cost), `N` to prefer the lowest price. |
| `isReadReplicaRequired` | `Y` if read replicas are needed on the target. |
| `readReplicaCount` | Number of read replicas (0–100). |
| `preferEnterpriseEdition` | `Y` to stay on Enterprise Edition. |
| `minimalCutoverDowntimeRequired` | `Y` if the cutover must have minimal downtime. |
| `preferGoldenGate` | `Y` if Oracle GoldenGate is the preferred replication method. |
| `requireMultiAZ` | `Y` if a Multi-AZ deployment is required. |
| `targetAWSRegion` | Target AWS Region, e.g. `ap-southeast-2`. Required by MAT: filled from `--region`. |
| `Environment` | `prod` or `non-prod`. MAT rejects a blank value, so it is filled from `--environment` (default `non-prod`, MAT's behaviour when no environment is set; `prod` excludes burstable instance classes). |

## Notes

- **Application schemas**: storage used, object counts and jobs exclude Oracle-supplied
  schemas: on 12c and later every user with `DBA_USERS.ORACLE_MAINTAINED = 'Y'`, plus a fixed list
  (SYS, SYSTEM, XDB, MDSYS, CTXSYS, APEX_*, PERFSTAT, ...) that also covers 11g.
- **Lookback**: AWR and STATSPACK use up to the last 30 days of snapshots; non-AWR uses the
  last ~60 minutes (`GV$SYSMETRIC_SUMMARY`), so its percentile fields are single values.
- **STATSPACK in a PDB** records instance-wide statistics, so a PDB row's `db*` values include
  the whole instance.
- **Not in the MAT file**: the inventory also collects `SGA (GB)` and `PGA (GB)` separately (used
  for the RAC memory sizing in [sizing.md](sizing.md)) and the collection information (mode,
  window, snapshot count). They are in `oracle_inventory.csv`, not in the MAT template.
