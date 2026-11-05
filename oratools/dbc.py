# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
"""--dbc: write the inventory as a CMDB import file for the AWS Directional Business Case (DBC) tool.

One row per database to migrate (non-CDB or CDB with its PDBs); a RAC database is one row with the
cluster totals. Columns follow the DBC 'Input' sheet; target selection columns are left blank.
"""

import csv
import logging
from pathlib import Path

from .process import host_label, num

log = logging.getLogger("oracletools")

COLUMNS = [
    "Source Location", "Source Host/Server Name", "Source DB Name", "Source Database Type", "Source DB Edition",
    "Source Host vCPU", "Source Host Memory (GB)", "Source Storage (GB)", "Source Storage Used (GB)",
    "Source CPU Utilization (%)", "Source EC2 Region", "Source EC2 OS", "Source EC2 SQL License",
    "Source EC2 Instance Type", "Source EC2 EBS Volume Type", "Source EC2 Pricing Model",
    "Target RDS/Aurora  Instance Family/ Type", "Target RDS/Aurora Optimized Instance Family/ Type",
]

LOCATIONS = {"on-premises": "On-Premises", "ec2": "EC2"}

# Database Edition (instance_level.sql) -> DBC Oracle edition
EDITIONS = {
    "Enterprise Edition": "Enterprise",
    "Standard Edition 2": "Standard Two",
    "Standard Edition": "Standard",
    "Express Edition": "Express",
    "Free": "Express",
}

EC2_DEFAULT_OS = "Linux"  # not collected: edit in the CSV for RHEL, SUSE, Ubuntu Pro or Windows hosts
EC2_EBS_VOLUME_TYPE = "gp3"


def _blank_zero(value):
    return value if value else ""


def to_dbc_rows(inventory, location="on-premises", region=None):
    loc = LOCATIONS[location]
    by_db = {}
    for rec in inventory:
        by_db.setdefault((rec.get("Server Name"), rec.get("CDB/DB Name")), []).append(rec)

    rows = []
    for (server, cdb), recs in by_db.items():
        head = next((r for r in recs if r.get("Container Type") in ("CDB$ROOT", "Non-CDB")), recs[0])
        vcpu = num(head, "Host vCPU Count", 0)
        cpu_known = num(head, "Host CPU Average 99th Percentile", 0) or num(head, "Host CPU Maximum 90th Percentile", 0)
        util = num(head, "Host CPU Peak Utilisation (%)", 0) if vcpu and cpu_known else None
        # Host total storage covers every container of a CDB; fall back to the containers' allocations
        storage = num(head, "Host Total Storage (GB)", 0) or round(sum(num(r, "Storage Allocated (GB)", 0) for r in recs), 1)
        used = round(sum(num(r, "Storage Used (GB)", 0) for r in recs), 2)
        edition = str(head.get("Database Edition") or "")
        if edition and edition not in EDITIONS:
            log.warning("DBC: %s has edition '%s'; Source DB Edition left blank (required by DBC for Oracle)", cdb, edition)
        rows.append({
            "Source Location": loc,
            "Source Host/Server Name": host_label(server),
            "Source DB Name": cdb,
            "Source Database Type": "Oracle",
            "Source DB Edition": EDITIONS.get(edition, ""),
            "Source Host vCPU": _blank_zero(vcpu),
            "Source Host Memory (GB)": _blank_zero(num(head, "Host Total Memory (GB)", 0)),
            "Source Storage (GB)": _blank_zero(storage),
            "Source Storage Used (GB)": _blank_zero(used),  # blank: DBC uses the allocated storage
            "Source CPU Utilization (%)": "" if util is None else min(util, 100),
            "Source EC2 Region": (region or "") if loc == "EC2" else "",
            "Source EC2 OS": EC2_DEFAULT_OS if loc == "EC2" else "",
            "Source EC2 EBS Volume Type": EC2_EBS_VOLUME_TYPE if loc == "EC2" else "",
        })
    return rows


def write_dbc(inventory, out_dir, location="on-premises", region=None, filename="dbc_cmdb_inventory.csv"):
    rows = to_dbc_rows(inventory, location=location, region=region)
    path = Path(out_dir) / filename
    with open(path, "w", encoding="utf-8", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=COLUMNS, restval="")
        writer.writeheader()
        writer.writerows(rows)
    return path, rows
