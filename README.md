# oracletools

Collect Oracle Database inventory and performance data for **rightsizing** Oracle workloads
on AWS (Amazon RDS for Oracle or Amazon EC2). From the collected data, oracletools produces:

- a consolidated inventory and a human-readable report
- (optional, `--mat`) an input file for the AWS Migrations Acceleration Toolkit (MAT)
- (optional, `--dbc`) a CMDB input file for an AWS Directional Business Case (DBC) analysis

> [!IMPORTANT]
> This sample is provided for demonstration and educational purposes only and is not intended
> for production use without additional security review and testing.
>
> Test and verify oracletools on a non-production database before you use it. It is provided
> "as is", without warranty of any kind, under the MIT-0 licence ([LICENSE](LICENSE)), and you
> use it at your own risk.

> [!WARNING]
> **AWR mode (the default) requires an Oracle Diagnostics Pack licence.**
> AWR mode reads the Automatic Workload Repository (`DBA_HIST_*` views). Using AWR requires
> Oracle Database Enterprise Edition **with the Oracle Diagnostics Pack licensed**.
> **It is the customer's responsibility to make sure every database is licensed for the
> Diagnostics Pack before collecting in AWR mode.** The tool does not check or enforce
> licensing. If a database is not licensed (for example Standard Edition 2), use STATSPACK mode
> (`collect_statspack.sql` or `--mode statspack`, STATSPACK must be installed) or non-AWR mode
> (`collect_noawr.sql` or `--mode noawr`). Neither accesses any AWR view.

## What it collects

All collection is **read-only**: only `SELECT` on data dictionary, dynamic performance, AWR or
STATSPACK views, plus session-level `ALTER SESSION` settings. Nothing is created, changed or
deleted in the database, and no application data is read. The full list of objects read is in
[`docs/data-access.md`](docs/data-access.md).

| Level | Rows | Content |
|---|---|---|
| Instance / host | one per instance, plus a cluster row for RAC | version, edition, RAC, PDB count, vCPU, memory, storage, CPU / IOPS / throughput / network percentiles |
| Database | one per non-CDB, `CDB$ROOT` and open PDB | CPU / IOPS / throughput / redo percentiles, SGA+PGA, allocated and used storage, object counts, tables without primary key |
| Features | one per non-CDB, `CDB$ROOT` and open PDB | feature usage, Enterprise Edition features, DB links, jobs, SA privileges, BI components, HA setup |
| Collection info | one per database | collection mode, metrics window, snapshot count and interval, AWR retention |

**Collection modes**

| Mode | Source | Window | Licence |
|---|---|---|---|
| `AWR` (default, recommended) | `DBA_HIST_SYSMETRIC_SUMMARY`, `DBA_HIST_CON_SYSMETRIC_SUMM`, ... | up to the last 30 days of AWR snapshots | **Diagnostics Pack required** |
| `STATSPACK` | `PERFSTAT.STATS$SNAPSHOT`, `STATS$SYSSTAT`, `STATS$OSSTAT`, `STATS$SYS_TIME_MODEL`, `STATS$SGASTAT`, `STATS$PGASTAT` | up to the last 30 days of STATSPACK snapshots | none (STATSPACK must be installed and taking snapshots) |
| `NOAWR` | `GV$SYSMETRIC_SUMMARY`, `GV$CON_SYSMETRIC_SUMMARY` | the last ~60 minutes only | none |

STATSPACK mode is a best-effort match of the AWR columns: rates are counter deltas between
consecutive snapshots, and because STATSPACK has no within-interval peaks the `Maximum`
columns are percentiles of the interval averages. STATSPACK must be installed in the container
being collected (a non-CDB, or each PDB); containers without it report 0 for performance
metrics. In a PDB, STATSPACK records instance-wide statistics, so PDB values include the whole
instance.

Non-AWR results are only representative if they are collected **during peak load**. Collect
several times (different days, batch windows, month end) and process all runs together:
the processor keeps the highest value of every metric (see [Combining several runs](#combining-several-runs)).

## Supported versions

| Component | Supported | Tested |
|---|---|---|
| Oracle Database | **11.2 and later**: 11.2, 12.1, 12.2, 18c, 19c, 21c, 23ai / 26ai | 11.2.0.2 (XE), 19c (19.32 two-node RAC CDB; single-instance EE and SE2), 21.3 (XE), 23.26 (Free) |
| Configurations | single instance and RAC; non-CDB and multitenant (`CDB$ROOT` and PDBs, 12.1+) | all four on 19c; non-CDB on 11.2; CDB on 21c and 23ai |
| Editions | Enterprise, Standard Edition 2, Standard, Express, Free | Enterprise, Standard Edition 2, Express, Free |
| SQL*Plus (scenario 1) | any SQL*Plus that can connect to the database, for example the one in the database's Oracle home | 11.2, 19c |
| Python | **3.9 or later** for both `process` and `collect`. `collect` (scenario 2) also needs python-oracledb 3.4.2 or later and cryptography 44.0.1 or later (`requirements.txt`; tested with python-oracledb 3.4.2 and cryptography 49.0.0, pinned in `constraints.txt`), which require Python 3.9+; `process` uses only the standard library | 3.9, 3.10, 3.11, 3.12, 3.13 |
| python-oracledb thin mode (default) | Oracle Database 12.1 or later; no Oracle Client needed | 19c, 21c, 23ai |
| python-oracledb thick mode (`thick_mode = true`) | needed for **11.2**, Native Network Encryption and external authentication; requires Oracle Instant Client of a release that supports the database (for 11.2: Instant Client 19 or earlier, see Oracle's client / server interoperability matrix, MOS Doc ID 207303.1) | not tested; for 11.2, scenario 1 (SQL*Plus) was tested |

Collection modes by database version:

| Mode | Database |
|---|---|
| `AWR` | 11.2+ Enterprise Edition with the Diagnostics Pack licensed |
| `STATSPACK` | 11.2+, any edition, with STATSPACK installed and taking snapshots (in a CDB: in each PDB) |
| `NOAWR` | 11.2+, any edition. PDB metrics come from `GV$CON_SYSMETRIC_SUMMARY` on 12.2+ (per instance) and `V$CON_SYSMETRIC_SUMMARY` on 12.1 |

On 11.2, everything that needs 12c objects (multitenant, `ORACLE_MAINTAINED`, `SYSBACKUP` / `SYSDG` / `SYSKM`,
`V$PDBS`) is skipped automatically: those parts of the scripts use dynamic SQL, so the scripts compile on 11.2.

## Requirements

- A supported Oracle Database and Python version (see [Supported versions](#supported-versions)).
- **RAC: collect only when every node that runs the business workload is up.** Do not collect while
  the cluster is degraded (one or more instances down, for example during rolling patching or a node
  outage). See [RAC](#rac) below.
- A **dedicated, read-only collection user**, prepared by your DBA. Do not use `SYS` / `SYSDBA`
  or an application owner. The user needs `CREATE SESSION` and `SELECT ANY DICTIONARY`, plus
  `SET CONTAINER` and `CONTAINER_DATA=ALL` for a CDB, and `SELECT` on the `PERFSTAT.STATS$`
  tables for STATSPACK mode. See [`docs/prerequisites.md`](docs/prerequisites.md) for details and
  example statements. oracletools does not create users or change anything in the database.
- For a security review: [`docs/data-access.md`](docs/data-access.md) lists every object the
  scripts read, per collection mode, and why.
- Python 3.9 or later (both scenarios). Processing uses only the standard library.
- For direct collection with Python (scenario 2 only):
  [python-oracledb](https://python-oracledb.readthedocs.io/). `requirements.txt` sets the minimum versions;
  `constraints.txt` pins the tested versions (python-oracledb 3.4.2, cryptography 49.0.0). Thin mode
  needs no Oracle Client and supports Oracle 12.1+; for 11.2, Native Network Encryption or external
  authentication, install Oracle Instant Client and set `thick_mode = true`, or use scenario 1 (SQL*Plus).

```bash
git clone --depth 1 <this repository> && cd oracletools
python3 -m pip install -r requirements.txt -c constraints.txt   # only needed for scenario 2; tested versions
```

## Scenario 1 – collect with SQL*Plus, process with Python

Use this when Python must not connect to the database. The DBA runs plain SQL scripts with
SQL*Plus; the CSV files are then processed anywhere (for example on a laptop).

1. Copy the `sql/` folder to a machine that has SQL*Plus and can reach the database.
2. **Run from inside the `sql/` folder** (the scripts use relative paths). Connect to the
   non-CDB or to the **CDB root**; every open PDB is collected automatically. For RAC, connect
   to any one instance (or the SCAN), with all instances running.

   ```bash
   cd sql

   # AWR mode (default, Diagnostics Pack licence required)
   sqlplus c##oratools@//dbhost01.example.com:1521/ORCLCDB @collect_awr.sql

   # STATSPACK mode (no Diagnostics Pack; STATSPACK installed; up to 30 days)
   sqlplus oratools@//dbhost02.example.com:1521/ORCLSE2 @collect_statspack.sql

   # Non-AWR mode (no Diagnostics Pack; last ~60 minutes only)
   sqlplus oratools@//dbhost02.example.com:1521/ORCLSE2 @collect_noawr.sql
   ```

   Omitting the password on the command line makes SQL*Plus prompt for it, which keeps it out
   of the shell history. Repeat for every database. The CSV files are written to `sql/output/`:

   ```text
   <server>_<db>_collection_info.csv
   <server>_<db>_oracle_instance_level_data.csv
   <server>_<db>_<container>_oracle_database_level_data.csv   (container = db name, cdb or pdb name)
   <server>_<db>_<container>_oracle_database_features.csv
   ```

3. Copy the CSV files to the machine with Python and process them:

   ```bash
   python3 oracle_collector.py process --input sql/output
   python3 oracle_collector.py process --input sql/output --mat --region ap-southeast-2 --environment prod
   ```

## Scenario 2 – collect and process with Python

Use this when Python can connect to the databases. One `collect` command connects to every
database listed in a configuration file, runs **the same SQL** as scenario 1 and processes the
results, so no separate SQL*Plus step or CSV copy is needed.

1. Create the connection file from the documented sample and edit it:

   ```bash
   cp config/databases.sample.ini config/databases.ini
   ```

   ```ini
   [DEFAULT]
   port = 1521
   collection_mode = awr        ; awr (default, Diagnostics Pack licence required), statspack or noawr

   [sales-prod]                 ; non-CDB, password read from an environment variable
   host = dbhost01.example.com
   service_name = SALESPRD
   user = oratools
   password_env = ORA_PWD_SALES

   [erp-cdb]                    ; CDB root: CDB$ROOT and every open PDB are collected
   host = dbhost02.example.com
   service_name = ERPCDB
   user = C##ORATOOLS           ; no password set -> prompted at run time

   [reporting-se2]              ; no Diagnostics Pack -> non-AWR
   host = dbhost04.example.com
   service_name = RPTSE2
   user = oratools
   collection_mode = noawr
   ```

   [`config/databases.sample.ini`](config/databases.sample.ini) documents every option: SID,
   full connect descriptors, tnsnames.ora aliases, PDB filters, RAC/SCAN, wallets and
   thick mode. Passwords are taken from `password_env`, then `password`, then an interactive
   prompt. Do not store plain-text passwords in the file, and do not commit `databases.ini`
   (it is in `.gitignore`).

2. Run the collection:

   ```bash
   python3 oracle_collector.py collect --config config/databases.ini
   python3 oracle_collector.py collect --config config/databases.ini --mode statspack    # force STATSPACK for all
   python3 oracle_collector.py collect --config config/databases.ini --mode noawr        # force non-AWR for all
   python3 oracle_collector.py collect --config config/databases.ini -d erp-cdb --mat    # one entry, plus MAT file
   ```

   Raw CSV files are written to `<output>/raw/`, and a log to `<output>/oracletools.log`.
   A database that fails (connection or permission error) is logged and skipped; the others
   are still collected.

## Outputs

Both scenarios produce the same files in the output directory (default `./oracletools_output_<timestamp>`, set with `--output`). If the folder given with `--output` already holds outputs of an earlier run, the new files get a `_<YYYYMMDD_HHMMSS>` suffix and nothing is overwritten:

| File | Content |
|---|---|
| `oracle_inventory_report.html` | Self-contained report: overview, findings, key data points for performance sizing, servers, database metrics, objects and features, metric glossary. Open it in any browser. |
| `oracle_inventory.csv` | One row per database (non-CDB, `CDB$ROOT`, PDB) with host, performance, storage, object and feature data joined together. |
| `consolidated_oracle_*.csv` | The raw files of each type merged into one CSV (same columns as collected). For RAC, the instance-level file keeps one row per node plus the cluster row. |
| `mat_oracle_inventory.csv` | Only with `--mat`: see below. |
| `dbc_cmdb_inventory.csv` | Only with `--dbc`: see below. |

A text summary with the main findings is also printed to the console. See
[`samples/report/`](samples/report) for the outputs of a sample collection (19c CDB with one
PDB and a 19c EE non-CDB in AWR mode, a 19c SE2 non-CDB in STATSPACK mode, and a 19c two-node
RAC CDB with one PDB in AWR mode).

The report flags, for example: non-AWR collections, short AWR history, versions below 19c,
RAC, features that need review for Amazon RDS for Oracle (Database Vault, Real Application
Security, ...), Enterprise Edition features in use, tables without a primary key, and hosts
with very low (< 20%) or high (> 80%) peak CPU utilisation.

### Key data points for performance sizing

The report lists, for every database row, the minimum vCPU, memory, storage, IOPS, throughput
and storage type. The formulas are described in [`docs/sizing.md`](docs/sizing.md).

### MAT input file (`--mat`)

`--mat` writes `mat_oracle_inventory.csv` with exactly the columns, in the same order, of the
MAT Oracle inventory template ([`templates/oracle-inventory-template.csv`](templates/oracle-inventory-template.csv),
field definitions in [`templates/oracle-inventory-template-description.csv`](templates/oracle-inventory-template-description.csv)).
[`docs/mat-fields.md`](docs/mat-fields.md) describes every field and where oracletools takes it from.

- Collected fields (`cluster*`, `db*`, storage, objects, features, ...) are filled in.
  `cluster*` values come from the instance-level data (the RAC cluster row for RAC; the per-node rows
  are not used), `db*` values from the database-level data of the row's container.
- Questionnaire fields (`isIsvCotsApplication`, `preferLicenseIncluded`, ...) are user input and are
  left blank; complete them in the CSV or in MAT. Two of them cannot be blank in MAT:
  `targetAWSRegion` (required: use `--region`, e.g. `--region ap-southeast-2`) and `Environment`
  (`prod` or `non-prod`: use `--environment`, default `non-prod`, which is what MAT assumes when no
  environment is set; `prod` excludes burstable instance classes).
- `--mat-skip-cdb-root` leaves out the `CDB$ROOT` rows (keeps non-CDBs and PDBs).

These user-input fields are not part of the normal outputs.

### DBC input file (`--dbc`)

`--dbc` writes `dbc_cmdb_inventory.csv`, the CMDB inventory file for an AWS Directional Business Case (DBC)
analysis: share it with your AWS team when building a business case. There is one row per database
to migrate (non-CDB, or CDB with its PDBs); a RAC database is one row with the cluster totals.

```bash
python3 oracle_collector.py process --input sql/output --dbc                       # on-premises databases
python3 oracle_collector.py process --input sql/output --dbc ec2 --region us-east-1  # databases on EC2
```

Collected values fill the source columns (server, edition, vCPU, memory, storage, storage used,
peak CPU utilisation). For `--dbc ec2`, `Source EC2 OS` is set to `Linux`; change it in the CSV for
other operating systems. Target columns are left blank. Use one location per file.

### Combining several runs

`process` reads folders recursively and accepts `--input` several times. If the same database
appears more than once (for example non-AWR collections taken at different peak times, each
copied into its own folder), the runs are merged and every metric keeps the **highest** value
seen; the run count is shown in `oracle_inventory.csv`.

```bash
python3 oracle_collector.py process -i runs/monday-0900 -i runs/monday-2300 -i runs/month-end
```

## How to read the metrics

- **CPU** values are the **number of CPUs busy** (vCPU-equivalents), not percentages.
  `Average 99th Percentile` is the P99 of the per-snapshot averages, `Maximum 90th Percentile`
  the P90 of the per-snapshot peaks. Host rows use `Host CPU Usage Per Sec`; PDB rows use the
  PDB's own `CPU Usage Per Sec`.
- **IOPS** in I/O requests per second; **throughput**, **network** and **redo** in MB/s.
  IOPS and throughput are total I/O: read + write requests (bytes) per snapshot. `Average 99th
  Percentile` is the P99 of the per-snapshot averages, `Maximum 50th Percentile` the median of
  the per-snapshot peaks (read peak + write peak, a slight over-estimate).
- **Network** `Average` is the P99 of the per-snapshot averages and `Maximum` the median of the
  per-snapshot peaks of `Network Traffic Volume Per Sec` (client and database link traffic).
- **SGA+PGA** in GB: P99 over AWR snapshots (AWR) or current allocation (non-AWR).
- **Storage allocated / used**: datafiles of the container / segments of application schemas.
  The `CDB$ROOT` row covers the root container only; each PDB has its own row. The host-level
  total storage covers every container of a CDB.
- **Objects, jobs, privileges**: Oracle-maintained schemas (`ORACLE_MAINTAINED = 'Y'` on 12c+, plus
  a fixed list) are excluded. Procedures and functions are standalone objects only (package members
  are not counted). Tables without a primary key are counted per table, across schemas. `SA privilege`
  counts users (other than SYS and SYSTEM) with SYSDBA, SYSOPER, SYSBACKUP, SYSDG or SYSKM.
  `DB Link` counts application database links: links owned by Oracle-maintained users (for example
  `SYS.SYS_HUB`, present in every 12.2+ CDB root and PDB) are excluded; `PUBLIC` links are counted.
- **RAC**: see [RAC](#rac).

## RAC

> [!IMPORTANT]
> **Collect a RAC database only when every node that supports the business workload is running.**
> Do not run the collection while the cluster is degraded (one or more instances down, for example
> during rolling patching or a node outage).
>
> The node list, node count, vCPU and memory are read from the *running* instances (`GV$INSTANCE`,
> `GV$OSSTAT`), while AWR / STATSPACK history also contains the stopped instances. A degraded collection
> therefore under-reports the cluster (fewer nodes, vCPUs and memory), overstates CPU utilisation, and is
> keyed on a different host list, so it is not merged with collections taken while all nodes were up
> (the same database then appears twice). If a node was down, start it and collect again.

- **What is collected.** The instance-level data has one row per RAC instance (node) **and** one cluster
  row that lists every node. The per-node rows show how evenly the workload is spread across the nodes;
  they are kept in `consolidated_oracle_instance_level_data.csv`.
- **What is reported.** The inventory, the HTML report (sizing, servers, findings) and the MAT file use
  only the **cluster row** for a RAC database, never the individual node rows, so the cluster is not
  counted twice. The database-level and feature data are already per database (one row per
  `CDB$ROOT` / non-CDB / PDB).
- **How cluster metrics are built.** The cluster row and the database-level metrics are summed across
  instances per AWR snapshot before the percentile is taken, so they reflect the workload of the whole
  cluster (STATSPACK: summed per 10-minute bucket of snapshot time, because each instance has its own
  snapshot ids; non-AWR: summed across instances). Summing per-node peaks (`Maximum` columns) is a slight
  over-estimate when node peaks do not coincide. vCPU and memory of the cluster row are the totals of all
  nodes.
- **Connecting.** Connect to any one instance or to the SCAN service; all instances are collected. Which
  node the session lands on does not matter: collections through different nodes are merged.

## Repository layout

```text
oracle_collector.py            CLI: collect (scenario 2) and process (scenarios 1 and 2)
oratools/                      Python package (config, collect, process, report, mat)
sql/collect_awr.sql            SQL*Plus entry point, AWR mode (default)
sql/collect_statspack.sql      SQL*Plus entry point, STATSPACK mode
sql/collect_noawr.sql          SQL*Plus entry point, non-AWR mode
sql/awr/, sql/statspack/, sql/noawr/, sql/common/   collection scripts, shared by SQL*Plus and Python
config/databases.sample.ini    documented connection file for scenario 2
docs/                          prerequisites, data accessed (security review), sizing formulas, MAT fields
templates/                     MAT Oracle inventory template and field descriptions
samples/                       sample collected CSVs and the resulting report
tests/                         offline unit tests (no database needed)
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| `SP2-0606: Cannot create SPOOL file "output/..."` | Run SQL*Plus from inside the `sql/` folder. |
| Only `CDB$ROOT` collected, PDB files missing or empty | The user needs `SET CONTAINER` in all containers (common user), or collect each PDB with its own connection / config entry. |
| `ORA-00942` or `ORA-01031` in the output | Missing dictionary privileges; see [Requirements](#requirements). The processor reports such lines as warnings. |
| STATSPACK metrics are all 0 | STATSPACK is not installed in that container, has fewer than 2 snapshots in the last 30 days, or the user cannot read `PERFSTAT.STATS$*` (see [`docs/prerequisites.md`](docs/prerequisites.md)). |
| AWR metrics are all 0 | No AWR snapshots in the last 30 days (check `DBA_HIST_SNAPSHOT`, `CONTROL_MANAGEMENT_PACK_ACCESS`), or use non-AWR mode. |
| `DPY-3010` / thin mode not supported | Oracle 11.2 or Native Network Encryption: install Oracle Instant Client and set `thick_mode = true`. |

## Development

```bash
python3 -m unittest discover -s tests -v
```

## Security

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for more information.

## License

This library is licensed under the MIT-0 License. See the [LICENSE](LICENSE) file.
