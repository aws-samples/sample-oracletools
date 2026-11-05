# Key data points for performance sizing

The section *Key data points for performance sizing* of `oracle_inventory_report.html` shows the
minimum requirements of every database row (non-CDB, `CDB$ROOT`, PDB). They are computed from the
collected values as follows. No headroom is added.

| Data point | Formula | Fallback |
|---|---|---|
| vCPU | `min(max(DB CPU Avg P99, DB CPU Max P90), max(host CPU Avg P99, host CPU Max P90))` | `0.75 x host vCPU count` when DB CPU Avg P99 or DB CPU Max P90 is 0 |
| Memory (GiB) | `SGA+PGA`; RAC: `SGA / nodes x (1 + 0.2 x (nodes - 1)) + PGA` | `0.9 x host total memory` when SGA+PGA is 0 |
| Storage (GiB) | `max(0.8 x storage allocated, storage used)` | – |
| IOPS | `max(DB IOPS Avg P99, DB IOPS Max P50)` | none: a database-level value of 0 is used as is |
| Throughput (MB/s) | `max(DB throughput Avg P99, DB throughput Max P50)` | none: a database-level value of 0 is used as is |
| Storage type | `gp3` when DB IOPS Max P50 < 64,000 and DB throughput Max P50 < 4,000 MB/s; `io2` when 64,000 <= IOPS < 256,000 and 4,000 <= MB/s < 16,000 | otherwise no storage type fits (contact a specialist) |

`DB ...` values come from the database-level data of the row's container; `host ...` values come
from the instance-level data (the RAC cluster row for RAC).

## Notes

- RAC memory: `SGA` and `PGA` are the cluster totals (summed across instances). The SGA of the
  nodes is consolidated into one instance with 20% extra per additional node, and the PGA is
  added in full. Example, 2 nodes with SGA 30 GB and PGA 10 GB in total: `30 / 2 x 1.2 + 10 = 28 GiB`.
  Files collected before SGA and PGA were reported separately use `SGA+PGA` as SGA.

- Every row is sized on its own, including `CDB$ROOT`. The `CDB$ROOT` row carries host-level CPU
  (`Host CPU Usage Per Sec`), so do not add it to the requirements of its PDBs.
- CPU values are numbers of CPUs busy (vCPU-equivalents), not percentages.
- The collector keeps 3 decimals for CPU, 2 for IOPS and 4 for MB/s, so a lightly used database
  reports a small non-zero value instead of 0. A value of exactly 0 therefore means no data
  (for example no AWR or STATSPACK snapshots for that container), which triggers the vCPU fallback.
- IOPS and throughput are total I/O (read + write). See *How to read the metrics* in the
  [README](../README.md#how-to-read-the-metrics) for how each percentile is collected.
- With STATSPACK, a PDB row includes the whole instance's statistics (STATSPACK is not
  container-aware), which makes its requirements an upper bound.
