# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
"""--mat: write the inventory in the exact column layout of the MAT Oracle inventory template.

Column order, scope and type come from ``templates/oracle-inventory-template.csv`` and
``templates/oracle-inventory-template-description.csv``. Questionnaire fields are user
input (not collected from the database) and are left blank, except ``targetAWSRegion``
when ``--region`` is given. Fill them in the CSV or in MAT's Review Inventory step.
"""

import csv
import logging
from pathlib import Path

from .process import host_label, to_number

log = logging.getLogger("oracletools")

TEMPLATE_DIR = Path(__file__).resolve().parent.parent / "templates"
TEMPLATE_FILE = TEMPLATE_DIR / "oracle-inventory-template.csv"
DESCRIPTION_FILE = TEMPLATE_DIR / "oracle-inventory-template-description.csv"

# MAT field -> inventory column (see process.INVENTORY_COLUMNS)
DIRECT_MAP = {
    "dbEngineVersion": "Database Version",
    "dbEngineEdition": "Database Edition",
    "isRacCluster": "RAC Cluster",
    "nodeCount": "Nodes",
    "pdbCount": "Total PDB Count",
    "sgaPgaTotalGb": "SGA+PGA Total (GB)",
    "storageAllocatedGb": "Storage Allocated (GB)",
    "storageUsedGb": "Storage Used (GB)",
    "tableCount": "Table Count",
    "viewCount": "Views Count",
    "indexCount": "Index Count",
    "storedProcCount": "SP Count",
    "functionCount": "Function Count",
    "triggerCount": "Triggers Count",
    "tablesWithoutPk": "Table w/o PK",
    "tablesWithoutKeyCount": "Table w/o Key",
    "dbLinkCount": "DB Link",
    "saPrivilegeCount": "SA privilege",
    "jobCount": "Jobs",
    "clusterVcpuCount": "Host vCPU Count",
    "clusterTotalMemoryGb": "Host Total Memory (GB)",
    "clusterFreeMemoryGb": "Host Free Memory (GB)",
    "clusterTotalStorageGb": "Host Total Storage (GB)",
    "clusterCpuAvgP99": "Host CPU Average 99th Percentile",
    "clusterCpuMaxP90": "Host CPU Maximum 90th Percentile",
    "clusterIopsAvgP99": "Host IOPS Average 99th Percentile",
    "clusterIopsMaxP50": "Host IOPS Maximum 50th Percentile",
    "clusterThroughputAvgP99": "Host Throughput Average 99th Percentile (MB/s)",
    "clusterThroughputMaxP50": "Host Throughput Maximum 50th Percentile (MB/s)",
    "clusterNetThroughputAvg": "Network Throughput Average (MB/s)",
    "clusterNetThroughputMax": "Network Throughput Maximum (MB/s)",
    "dbCpuAvgP99": "DB CPU Average 99th Percentile",
    "dbCpuMaxP90": "DB CPU Maximum 90th Percentile",
    "dbIopsAvgP99": "DB IOPS Average 99th Percentile",
    "dbIopsMaxP50": "DB IOPS Maximum 50th Percentile",
    "dbThroughputAvgP99": "DB Throughput Average 99th Percentile (MB/s)",
    "dbThroughputMaxP50": "DB Throughput Maximum 50th Percentile (MB/s)",
    "dbRedoRateAvgP99": "RedoRate Average 99th Percentile (MB/s)",
    "dbRedoRateMaxP50": "RedoRate Maximum 50th Percentile (MB/s)",
}

NUMERIC_TYPES = {"integer", "float", "percentage"}

# Optional fields where blank means "not collected" (template), so a missing value stays blank instead of 0
BLANK_IF_MISSING = {"tablesWithoutKeyCount"}


def load_template():
    with open(TEMPLATE_FILE, encoding="utf-8-sig", newline="") as fh:
        columns = [c.strip() for c in next(csv.reader(fh)) if c.strip()]
    spec = {}
    with open(DESCRIPTION_FILE, encoding="utf-8-sig", newline="") as fh:
        for row in csv.DictReader(fh):
            spec[row["Field Name"].strip()] = row
    return columns, spec


def _list_value(value):
    """Comma separated list, 'None' when empty. The EE feature list uses '; ' in the CSV."""
    text = (str(value or "")).replace(";", ",")
    items = [i.strip() for i in text.split(",") if i.strip() and i.strip().lower() != "none"]
    return ", ".join(items) if items else "None"


def _number(value, ftype):
    n = to_number(value)
    if n is None:
        n = 0
    if ftype == "integer":
        return int(round(n))
    return n


# Values written for questionnaire fields that MAT's CSV import does not accept blank.
# MAT rejects an empty 'Environment' (enum prod | non-prod); 'non-prod' is what MAT assumes when no
# environment is set (only 'prod' changes sizing: it removes burstable instance classes).
DEFAULT_ENVIRONMENT = "non-prod"


def to_mat_rows(inventory, region=None, skip_cdb_root=False, environment=None):
    columns, spec = load_template()
    rows = []
    for rec in inventory:
        if skip_cdb_root and rec.get("Container Type") == "CDB$ROOT":
            continue
        cdb = str(rec.get("CDB/DB Name", ""))
        name = str(rec.get("Database Name", ""))
        is_container = rec.get("Container Type") in ("CDB$ROOT", "PDB")
        values = {
            "dbIdentifier": f"{cdb}/{name}",
            "clusterName": host_label(rec.get("Server Name")),
            "cdbName": cdb if is_container else "",
            "sourceEngine": "oracle",
            "trustworthyProperty": "None",  # SQL Server property: not collected, MAT template default
            "featureUsage": _list_value(rec.get("Feature Usage")),
            "eeFeatureUsage": _list_value(rec.get("Ent. Edition feature usage")),
            "biComponents": _list_value(rec.get("BI Components")),
            "haSetup": rec.get("HA Setup") or "None",
        }
        for field, source in DIRECT_MAP.items():
            values[field] = rec.get(source, "")

        row = {}
        for col in columns:
            meta = spec.get(col, {})
            scope = (meta.get("Scope") or "").strip()
            ftype = (meta.get("Type") or "").strip().lower()
            if scope == "Questionnaire":
                if col == "targetAWSRegion":
                    row[col] = region or ""
                elif col == "Environment":
                    row[col] = environment or DEFAULT_ENVIRONMENT
                else:
                    row[col] = ""
                continue
            value = values.get(col, "")
            if col in BLANK_IF_MISSING and to_number(value) is None:
                row[col] = ""
                continue
            if ftype in NUMERIC_TYPES:
                value = _number(value, ftype)
            elif ftype == "boolean":
                value = "Y" if str(value).strip().upper() in ("Y", "YES", "TRUE") else "N"
            row[col] = value
        rows.append(row)

    ids = [r["dbIdentifier"] for r in rows]
    for dup in sorted({i for i in ids if ids.count(i) > 1}):
        # Same CDB/PDB name on different servers: make the MAT key unique
        log.warning("dbIdentifier %s appears on several servers; suffixing with @<server>", dup)
        for r in rows:
            if r["dbIdentifier"] == dup:
                r["dbIdentifier"] = f"{dup}@{r['clusterName']}"
    return columns, rows


def write_mat(inventory, out_dir, region=None, skip_cdb_root=False, filename="mat_oracle_inventory.csv",
              environment=None):
    columns, rows = to_mat_rows(inventory, region=region, skip_cdb_root=skip_cdb_root, environment=environment)
    path = Path(out_dir) / filename
    with open(path, "w", encoding="utf-8", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=columns)
        writer.writeheader()
        writer.writerows(rows)
    return path, rows
