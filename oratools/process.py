# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
"""Scenario 1 and 2: read the collected CSV files, consolidate them and build a per-database inventory.

Works on files produced by the SQL*Plus scripts or by the Python collector. It also
tolerates older outputs of the same scripts (trailing spaces from missing TRIMSPOOL,
unquoted RAC host lists, no collection_info file).
"""

import csv
import io
import logging
import re
from pathlib import Path

from . import SUFFIX_DATABASE, SUFFIX_FEATURES, SUFFIX_INFO, SUFFIX_INSTANCE

log = logging.getLogger("oracletools")

KINDS = {
    "info": SUFFIX_INFO,
    "instance": SUFFIX_INSTANCE,
    "database": SUFFIX_DATABASE,
    "features": SUFFIX_FEATURES,
}

CONSOLIDATED_NAMES = {
    "info": "consolidated_oracle_collection_info.csv",
    "instance": "consolidated_oracle_instance_level_data.csv",
    "database": "consolidated_oracle_database_level_data.csv",
    "features": "consolidated_oracle_database_features.csv",
}

# Lines that SQL*Plus may spool when something goes wrong
ERROR_LINE = re.compile(r"^\s*(ORA-\d+|SP2-\d+|PLS-\d+|ERROR at line|ERROR:|Help: https://docs.oracle.com)")

# ----------------------------------------------------------------------------
# Unified per-database inventory (human friendly column names, no MAT questionnaire fields)
# ----------------------------------------------------------------------------
INVENTORY_COLUMNS = [
    "Server Name", "CDB/DB Name", "Database Name", "Container Type",
    "Database Version", "Database Edition", "RAC Cluster", "Nodes", "Total PDB Count",
    "Collection Mode", "Collection Runs", "Metrics Window (Hours)", "Snapshot Count", "Collection Time",
    "Host vCPU Count", "Host Total Memory (GB)", "Host Free Memory (GB)", "Host Total Storage (GB)",
    "Host CPU Average 99th Percentile", "Host CPU Maximum 90th Percentile", "Host CPU Peak Utilisation (%)",
    "Host IOPS Average 99th Percentile", "Host IOPS Maximum 50th Percentile",
    "Host Throughput Average 99th Percentile (MB/s)", "Host Throughput Maximum 50th Percentile (MB/s)",
    "Network Throughput Average (MB/s)", "Network Throughput Maximum (MB/s)",
    "DB CPU Average 99th Percentile", "DB CPU Maximum 90th Percentile",
    "DB IOPS Average 99th Percentile", "DB IOPS Maximum 50th Percentile",
    "DB Throughput Average 99th Percentile (MB/s)", "DB Throughput Maximum 50th Percentile (MB/s)",
    "RedoRate Average 99th Percentile (MB/s)", "RedoRate Maximum 50th Percentile (MB/s)",
    "SGA+PGA Total (GB)", "SGA (GB)", "PGA (GB)", "Storage Allocated (GB)", "Storage Used (GB)",
    "Table Count", "Views Count", "Index Count", "SP Count", "Function Count", "Triggers Count", "Table w/o PK", "Table w/o Key",
    "Feature Usage", "Ent. Edition feature usage", "DB Link", "SA privilege", "Jobs", "BI Components", "HA Setup",
]


def to_number(value):
    """'.16' -> 0.16, '5' -> 5, '' / 'N/A' / None -> None."""
    if value is None:
        return None
    s = str(value).strip()
    if s == "" or s.upper() in ("N/A", "NA", "NULL", "NONE"):
        return None
    try:
        f = float(s)
    except ValueError:
        return None
    return int(f) if f.is_integer() and "." not in s else f


def num(row, key, default=0.0):
    v = to_number(row.get(key)) if row else None
    return default if v is None else v


def short_host(name):
    return (name or "").strip().lower().split(".")[0]


def host_key(server_name):
    """Normalise 'node1.example.com,node2.example.com' -> 'node1+node2' (order independent)."""
    hosts = [short_host(h) for h in (server_name or "").split(",") if h.strip()]
    return "+".join(sorted(set(hosts)))


def host_label(server_name):
    hosts = [short_host(h) for h in (server_name or "").split(",") if h.strip()]
    return "-".join(hosts)


# ----------------------------------------------------------------------------
# Reading
# ----------------------------------------------------------------------------
class Dataset:
    def __init__(self):
        self.rows = {k: [] for k in KINDS}
        self.headers = {k: [] for k in KINDS}
        self.files = {k: [] for k in KINDS}
        self.warnings = []

    def warn(self, msg):
        log.warning(msg)
        self.warnings.append(msg)


def classify(path):
    name = path.name.lower()
    for kind, suffix in KINDS.items():
        if name.endswith(suffix) and not name.startswith("consolidated_"):
            return kind
    return None


def read_csv_file(path, dataset, kind):
    text = Path(path).read_text(encoding="utf-8-sig", errors="replace")
    lines = []
    for raw in text.splitlines():
        line = raw.rstrip()
        if not line.strip():
            continue
        if ERROR_LINE.match(line):
            dataset.warn(f"{path.name}: Oracle/SQL*Plus error in output: {line.strip()}")
            continue
        lines.append(line)
    if not lines:
        dataset.warn(f"{path.name}: empty file")
        return
    records = list(csv.reader(io.StringIO("\n".join(lines))))
    header = [h.strip() for h in records[0]]
    if len(records) == 1:
        dataset.warn(f"{path.name}: header only, no data rows (check the collection log for errors)")
    for rec in records[1:]:
        rec = [v.strip() for v in rec]
        if len(rec) > len(header) and header and header[0] == "Server Name":
            # Older outputs: unquoted RAC host list "node1,node2" in the first column
            extra = len(rec) - len(header)
            rec = [",".join(rec[: extra + 1])] + rec[extra + 1:]
        if len(rec) != len(header):
            dataset.warn(f"{path.name}: skipped row with {len(rec)} fields (expected {len(header)}): {rec[:3]}...")
            continue
        row = dict(zip(header, rec))
        row["_source_file"] = path.name
        dataset.rows[kind].append(row)
    for h in header:
        if h not in dataset.headers[kind]:
            dataset.headers[kind].append(h)
    dataset.files[kind].append(path.name)


def load_dataset(input_dirs):
    dataset = Dataset()
    seen = set()
    for input_dir in input_dirs:
        root = Path(input_dir)
        if root.is_file():
            candidates = [root]
        else:
            candidates = sorted(p for p in root.rglob("*.csv") if p.is_file())
        for path in candidates:
            kind = classify(path)
            if not kind:
                continue
            key = path.resolve()
            if key in seen:
                continue
            seen.add(key)
            read_csv_file(path, dataset, kind)
    if not dataset.rows["database"] and not dataset.rows["instance"]:
        raise SystemExit(f"No collection CSV files found in: {', '.join(map(str, input_dirs))}")
    _deduplicate(dataset)
    return dataset


def _merge(old, new):
    """Merge two collections of the same database: numeric values keep the maximum (peak), text keeps the newest."""
    merged = dict(old)
    for k, v in new.items():
        a, b = to_number(old.get(k)), to_number(v)
        if k in ("Collection Time", "Metrics Window Start", "Metrics Window End", "_source_file"):
            merged[k] = v
        elif a is not None and b is not None:
            merged[k] = old.get(k) if a >= b else v
        elif v not in (None, ""):
            merged[k] = v
    merged["_runs"] = old.get("_runs", 1) + new.get("_runs", 1)
    return merged


def _deduplicate(dataset):
    """Same database collected more than once (e.g. several non-AWR runs at different peak times):
    keep one row per database with the highest value of every metric."""
    keys = {
        "info": lambda r: (host_key(r.get("Server Name")), r.get("CDB/DB Name", "").upper()),
        "instance": lambda r: (host_key(r.get("Server Name")), r.get("CDB/Instance Name", "").upper()),
        "database": lambda r: (host_key(r.get("Server Name")), r.get("CDB/DB Name", "").upper(),
                               r.get("Database Name", "").upper()),
        "features": lambda r: (host_key(r.get("Server Name")), r.get("CDB/DB Name", "").upper(),
                               r.get("Database Name", "").upper()),
    }
    for kind, keyf in keys.items():
        unique = {}
        for row in dataset.rows[kind]:
            k = keyf(row)
            unique[k] = _merge(unique[k], row) if k in unique else row
        if len(unique) != len(dataset.rows[kind]):
            dropped = len(dataset.rows[kind]) - len(unique)
            if kind == "info":
                dataset.warn(f"{dropped} repeated collection(s) of the same database merged: "
                             "metrics use the highest value seen across runs")
            dataset.rows[kind] = list(unique.values())


# ----------------------------------------------------------------------------
# Joining
# ----------------------------------------------------------------------------
def _lookup(index, by_db, key, db_key, what, dataset, label):
    if key in index:
        return index[key]
    candidates = by_db.get(db_key, [])
    if len(candidates) == 1:
        return candidates[0]
    if candidates:
        dataset.warn(f"{label}: {what} is ambiguous (same name on several servers); left blank")
    else:
        dataset.warn(f"{label}: no {what} found")
    return {}


def instance_for_database(dataset):
    """Pick the host/cluster row for each CDB/non-CDB: the RAC cluster row if present, else the single instance."""
    best = {}
    for row in dataset.rows["instance"]:
        hk = host_key(row.get("Server Name"))
        db = row.get("CDB/Instance Name", "").upper()
        nodes = len(hk.split("+")) if hk else 0
        key = db
        current = best.get(key, [])
        current.append((nodes, hk, row))
        best[key] = current
    index, by_db = {}, {}
    for db, entries in best.items():
        # The cluster row lists every host; index it under its own key and the per-node keys
        entries.sort(key=lambda e: -e[0])
        for nodes, hk, row in entries:
            index.setdefault((hk, db), row)
        cluster_rows = [e for e in entries if e[0] == entries[0][0]]
        by_db[db] = [e[2] for e in cluster_rows]
    return index, by_db


def container_type(db_row, inst_row):
    name = db_row.get("Database Name", "").upper()
    cdb = db_row.get("CDB/DB Name", "").upper()
    pdb_count = num(inst_row, "Total PDB Count", 0)
    if name != cdb:
        return "PDB"
    return "CDB$ROOT" if pdb_count and pdb_count > 0 else "Non-CDB"


def build_inventory(dataset):
    inst_index, inst_by_db = instance_for_database(dataset)

    feat_index, feat_by_db = {}, {}
    for row in dataset.rows["features"]:
        k = (row.get("CDB/DB Name", "").upper(), row.get("Database Name", "").upper())
        feat_index[(host_key(row.get("Server Name")),) + k] = row
        feat_by_db.setdefault(k, []).append(row)

    info_index, info_by_db = {}, {}
    for row in dataset.rows["info"]:
        db = row.get("CDB/DB Name", "").upper()
        info_index[(host_key(row.get("Server Name")), db)] = row
        info_by_db.setdefault(db, []).append(row)

    inventory = []
    for db in dataset.rows["database"]:
        hk = host_key(db.get("Server Name"))
        cdb = db.get("CDB/DB Name", "").upper()
        name = db.get("Database Name", "").upper()
        label = f"{cdb}/{name}"
        inst = _lookup(inst_index, inst_by_db, (hk, cdb), cdb, "instance level data", dataset, label)
        feat = _lookup(feat_index, feat_by_db, (hk, cdb, name), (cdb, name), "feature data", dataset, label)
        info = info_index.get((hk, cdb)) or (info_by_db.get(cdb, [None])[0] if len(info_by_db.get(cdb, [])) == 1 else None) or {}

        vcpu = num(inst, "vCPU Count", 0)
        cpu_peak = max(num(inst, "CPU Average 99th Percentile"), num(inst, "CPU Maximum 90th Percentile"))
        util = round(cpu_peak / vcpu * 100, 1) if vcpu else None

        rec = {
            "Server Name": db.get("Server Name", ""),
            "CDB/DB Name": db.get("CDB/DB Name", ""),
            "Database Name": db.get("Database Name", ""),
            "Container Type": container_type(db, inst),
            "Database Version": inst.get("Database Version", ""),
            "Database Edition": inst.get("Database Edition", ""),
            "RAC Cluster": inst.get("RAC Cluster", ""),
            "Nodes": inst.get("Nodes", ""),
            "Total PDB Count": inst.get("Total PDB Count", ""),
            "Collection Mode": info.get("Collection Mode", "Unknown"),
            "Collection Runs": info.get("_runs", 1) if info else "",
            "Metrics Window (Hours)": info.get("Metrics Window (Hours)", ""),
            # 'AWR Snapshot Count' in files from version 1.0.0
            "Snapshot Count": info.get("Snapshot Count", info.get("AWR Snapshot Count", "")),
            "Collection Time": info.get("Collection Time", ""),
            "Host vCPU Count": inst.get("vCPU Count", ""),
            "Host Total Memory (GB)": inst.get("Total Memory (GB)", ""),
            "Host Free Memory (GB)": inst.get("Free Memory (GB)", ""),
            "Host Total Storage (GB)": inst.get("Total Storage (GB)", ""),
            "Host CPU Average 99th Percentile": inst.get("CPU Average 99th Percentile", ""),
            "Host CPU Maximum 90th Percentile": inst.get("CPU Maximum 90th Percentile", ""),
            "Host CPU Peak Utilisation (%)": "" if util is None else util,
            "Host IOPS Average 99th Percentile": inst.get("IOPS Average 99th Percentile", ""),
            "Host IOPS Maximum 50th Percentile": inst.get("IOPS Maximum 50th Percentile", ""),
            "Host Throughput Average 99th Percentile (MB/s)": inst.get("Throughput Average 99th Percentile (MB/s)", ""),
            "Host Throughput Maximum 50th Percentile (MB/s)": inst.get("Throughput Maximum 50th Percentile (MB/s)", ""),
            "Network Throughput Average (MB/s)": inst.get("Network Throughput Average (MB/s)", ""),
            "Network Throughput Maximum (MB/s)": inst.get("Network Throughput Maximum (MB/s)", ""),
            "DB CPU Average 99th Percentile": db.get("CPU Average 99th Percentile", ""),
            "DB CPU Maximum 90th Percentile": db.get("CPU Maximum 90th Percentile", ""),
            "DB IOPS Average 99th Percentile": db.get("IOPS Average 99th Percentile", ""),
            "DB IOPS Maximum 50th Percentile": db.get("IOPS Maximum 50th Percentile", ""),
            "DB Throughput Average 99th Percentile (MB/s)": db.get("Throughput Average 99th Percentile (MB/s)", ""),
            "DB Throughput Maximum 50th Percentile (MB/s)": db.get("Throughput Maximum 50th Percentile (MB/s)", ""),
            "RedoRate Average 99th Percentile (MB/s)": db.get("RedoRate Average 99th Percentile (MB/s)", ""),
            "RedoRate Maximum 50th Percentile (MB/s)": db.get("RedoRate Maximum 50th Percentile (MB/s)", ""),
            "SGA+PGA Total (GB)": db.get("SGA+PGA Total (GB)", ""),
            "SGA (GB)": db.get("SGA (GB)", ""),
            "PGA (GB)": db.get("PGA (GB)", ""),
            "Storage Allocated (GB)": db.get("Storage Allocated (GB)", ""),
            "Storage Used (GB)": db.get("Storage Used (GB)", ""),
            "Table Count": db.get("Table Count", ""),
            "Views Count": db.get("Views Count", ""),
            "Index Count": db.get("Index Count", ""),
            "SP Count": db.get("SP Count", ""),
            "Function Count": db.get("Function Count", ""),
            "Triggers Count": db.get("Triggers Count", ""),
            "Table w/o PK": db.get("Table w/o PK", ""),
            "Table w/o Key": db.get("Table w/o Key", ""),  # not in files collected before 1.1.0
            "Feature Usage": feat.get("Feature Usage", ""),
            "Ent. Edition feature usage": feat.get("Ent. Edition feature usage", ""),
            "DB Link": feat.get("DB Link", ""),
            "SA privilege": feat.get("SA privilege", ""),
            "Jobs": feat.get("Jobs", ""),
            "BI Components": feat.get("BI Components", ""),
            "HA Setup": feat.get("HA Setup", ""),
        }
        rec = {k: _clean(v) for k, v in rec.items()}
        inventory.append(rec)

    order = {"CDB$ROOT": 0, "Non-CDB": 0, "PDB": 1}
    inventory.sort(key=lambda r: (host_key(r["Server Name"]), r["CDB/DB Name"], order.get(r["Container Type"], 2), r["Database Name"]))
    return inventory


def _clean(value):
    """Normalise numbers like '.16' to '0.16' so spreadsheets and readers handle them consistently."""
    if isinstance(value, (int, float)):
        return value
    n = to_number(value)
    if n is not None and re.fullmatch(r"-?\d*\.?\d+", str(value).strip()):
        return n
    return value


# ----------------------------------------------------------------------------
# Writing
# ----------------------------------------------------------------------------
REPORT_NAMES = ["oracle_inventory.csv", "oracle_inventory_report.html", "mat_oracle_inventory.csv",
                "dbc_cmdb_inventory.csv"]


def with_suffix(filename, suffix):
    """'oracle_inventory.csv' + '_20261027_142900' -> 'oracle_inventory_20261027_142900.csv'."""
    if not suffix:
        return filename
    stem, dot, ext = filename.rpartition(".")
    return f"{stem}{suffix}{dot}{ext}"


def output_suffix(out_dir, now=None):
    """'' when the output folder has no previous outputs, otherwise '_<YYYYMMDD_HHMMSS>' so nothing is overwritten."""
    import datetime as _dt
    out_dir = Path(out_dir)
    names = list(CONSOLIDATED_NAMES.values()) + REPORT_NAMES
    if not any((out_dir / n).exists() for n in names):
        return ""
    stamp = (now or _dt.datetime.now()).strftime("%Y%m%d_%H%M%S")
    suffix = f"_{stamp}"
    n = 1
    while any((out_dir / with_suffix(name, suffix)).exists() for name in names):  # same second
        n += 1
        suffix = f"_{stamp}_{n}"
    return suffix


def write_rows(path, columns, rows):
    with open(path, "w", encoding="utf-8", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=columns, extrasaction="ignore")
        writer.writeheader()
        for row in rows:
            writer.writerow({c: row.get(c, "") for c in columns})


def write_consolidated(dataset, out_dir, suffix=""):
    out_dir = Path(out_dir)
    written = []
    for kind, filename in CONSOLIDATED_NAMES.items():
        rows = dataset.rows[kind]
        if not rows:
            continue
        cleaned = [{k: _clean(v) for k, v in r.items()} for r in rows]
        path = out_dir / with_suffix(filename, suffix)
        write_rows(path, dataset.headers[kind], cleaned)
        written.append(path)
    return written
