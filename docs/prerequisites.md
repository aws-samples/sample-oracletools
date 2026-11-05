# Prerequisites: collection user

> [!IMPORTANT]
> This sample is provided for demonstration and educational purposes only and is not intended
> for production use without additional security review and testing.
>
> Test and verify the collection user and the privilege statements below on a non-production
> database before you use them. oracletools is provided "as is", without warranty of any kind,
> under the MIT-0 licence ([LICENSE](../LICENSE)), and you use it at your own risk.

oracletools does **not** create, change or drop anything in your database, including users
and grants. Before collecting, a DBA prepares a database user that can read the data dictionary.
This page lists what that user needs; the exact objects read are listed in
[data-access.md](data-access.md).

## Recommendation

- Use a **dedicated user** for the assessment (for example `ORATOOLS`, or `C##ORATOOLS` in a CDB).
- Do **not** use `SYS`, `SYSDBA` or an application owner. They are not needed and grant far
  more than the collection requires.
- Drop or lock the user when the assessment is finished.

## Privileges required

| Privilege | Needed for | Required in |
|---|---|---|
| `CREATE SESSION` | connecting | all modes |
| `SELECT ANY DICTIONARY` (or `SELECT_CATALOG_ROLE`) | reading the `DBA_*`, `V$` / `GV$` and, in AWR mode, `DBA_HIST_*` views listed in [data-access.md](data-access.md) | all modes |
| `SET CONTAINER` | switching from `CDB$ROOT` into each open PDB to collect it | CDB only |
| `CONTAINER_DATA = ALL` (user attribute) | seeing every container's rows in `V$` / `GV$` views from `CDB$ROOT` | CDB only |
| `SELECT` on the `PERFSTAT.STATS$` tables listed in [data-access.md](data-access.md) | STATSPACK history | STATSPACK mode only, in every container where STATSPACK is installed |

`SELECT ANY DICTIONARY` only gives read access to dictionary objects (owned by `SYS`); it does not
give access to application data. `SELECT_CATALOG_ROLE` is an alternative, but it does not cover
every view on every version; if you use it, check the output for `ORA-00942` / `ORA-01031`.

The scripts read no application tables or data. Object counts and sizes come from the data
dictionary (`DBA_TABLES`, `DBA_SEGMENTS`, ...), not from the tables themselves.

## Licensing (AWR mode)

AWR mode (the default) reads `DBA_HIST_*` views, which requires the **Oracle Diagnostics Pack**
licence (Enterprise Edition). It is the customer's responsibility to ensure the database is
licensed. Otherwise use STATSPACK mode (STATSPACK must already be installed) or non-AWR mode.
oracletools does not install STATSPACK.

## Example statements (for the DBA)

These are examples to adapt to your own standards (password policy, profile, tablespaces,
auditing). They are not part of oracletools and are not run by it.

CDB, run in `CDB$ROOT` (one common user collects every PDB):

```sql
CREATE USER C##ORATOOLS IDENTIFIED BY "<password>" CONTAINER=ALL;
GRANT CREATE SESSION, SET CONTAINER TO C##ORATOOLS CONTAINER=ALL;
GRANT SELECT ANY DICTIONARY TO C##ORATOOLS CONTAINER=ALL;
ALTER USER C##ORATOOLS SET CONTAINER_DATA=ALL CONTAINER=CURRENT;
```

Non-CDB:

```sql
CREATE USER ORATOOLS IDENTIFIED BY "<password>";
GRANT CREATE SESSION, SELECT ANY DICTIONARY TO ORATOOLS;
```

STATSPACK mode only, in each container (non-CDB or PDB) where STATSPACK is installed:

```sql
GRANT SELECT ON PERFSTAT.STATS$SNAPSHOT            TO <user>;
GRANT SELECT ON PERFSTAT.STATS$SYSSTAT             TO <user>;
GRANT SELECT ON PERFSTAT.STATS$OSSTAT              TO <user>;
GRANT SELECT ON PERFSTAT.STATS$OSSTATNAME          TO <user>;
GRANT SELECT ON PERFSTAT.STATS$SYS_TIME_MODEL      TO <user>;
GRANT SELECT ON PERFSTAT.STATS$TIME_MODEL_STATNAME TO <user>;
GRANT SELECT ON PERFSTAT.STATS$SGASTAT             TO <user>;
GRANT SELECT ON PERFSTAT.STATS$PGASTAT             TO <user>;
```

After the assessment:

```sql
DROP USER C##ORATOOLS CASCADE;   -- or ORATOOLS for a non-CDB
```

A local user created directly in a PDB (without access to `CDB$ROOT`) also works; it collects
that PDB only. Connect to the PDB's service and add it as its own entry.
