# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
"""Human readable outputs: a self-contained HTML report and a plain-text summary."""

import datetime as _dt
import html
from collections import OrderedDict

from . import __version__
from .process import host_key, host_label, num, to_number

# Features worth reviewing before choosing Amazon RDS for Oracle as the target
RDS_REVIEW_FEATURES = [
    # RAC itself is reported from the instance data (RAC Cluster = Y)
    "Real Application Cluster One Node",
    "Database Vault",
    "Real Application Security",
    "Hybrid Columnar Compression",
    "Exadata",
    "Shard Database",
    "Oracle In-Database Hadoop",
]

LOW_UTIL_PCT = 20
HIGH_UTIL_PCT = 80
SHORT_AWR_HOURS = 7 * 24


def _split(value):
    return [i.strip() for i in str(value or "").replace(";", ",").split(",") if i.strip() and i.strip().lower() != "none"]


def _fmt(value, decimals=2):
    n = to_number(value) if not isinstance(value, (int, float)) else value
    if n is None:
        return html.escape(str(value)) if value not in (None, "") else "&ndash;"
    if isinstance(n, int) or float(n).is_integer():
        return f"{int(n):,}"
    return f"{n:,.{decimals}f}"


def _esc(value):
    return html.escape(str(value)) if value not in (None, "") else "&ndash;"


def _major(version):
    try:
        return int(str(version).split(".")[0])
    except (TypeError, ValueError):
        return None


# ----------------------------------------------------------------------------
# Analysis shared by HTML and text output
# ----------------------------------------------------------------------------
def summarise(inventory, dataset):
    hosts = OrderedDict()  # host/cluster -> instance-level facts (one entry per server, not per database)
    for rec in inventory:
        hk = host_key(rec["Server Name"])
        h = hosts.setdefault(hk, {"label": host_label(rec["Server Name"]), "vcpu": 0, "mem": 0, "cpu_peak": 0, "dbs": set()})
        h["vcpu"] = max(h["vcpu"], num(rec, "Host vCPU Count"))
        h["mem"] = max(h["mem"], num(rec, "Host Total Memory (GB)"))
        h["cpu_peak"] = max(h["cpu_peak"], num(rec, "Host CPU Average 99th Percentile"), num(rec, "Host CPU Maximum 90th Percentile"))
        h["dbs"].add(rec["CDB/DB Name"])

    containers = [r for r in inventory if r["Container Type"] in ("CDB$ROOT", "Non-CDB")]
    pdbs = [r for r in inventory if r["Container Type"] == "PDB"]
    modes = sorted({str(r["Collection Mode"]) for r in inventory})

    totals = OrderedDict([
        ("Servers / clusters", len(hosts)),
        ("Databases (CDB or non-CDB)", len(containers)),
        ("Pluggable databases", len(pdbs)),
        ("Total vCPU", sum(h["vcpu"] for h in hosts.values())),
        ("Peak vCPU in use", round(sum(h["cpu_peak"] for h in hosts.values()), 2)),
        ("Total host memory (GB)", sum(h["mem"] for h in hosts.values())),
        ("Storage allocated (GB)", round(sum(num(r, "Storage Allocated (GB)") for r in inventory), 1)),
        ("Storage used (GB)", round(sum(num(r, "Storage Used (GB)") for r in inventory), 1)),
    ])

    editions, versions = OrderedDict(), OrderedDict()
    for r in containers:
        editions[r["Database Edition"] or "Unknown"] = editions.get(r["Database Edition"] or "Unknown", 0) + 1
        v = r["Database Version"] or "Unknown"
        versions[v] = versions.get(v, 0) + 1

    findings = []  # (severity, scope, message)

    def add(sev, scope, msg):
        findings.append((sev, scope, msg))

    for rec in inventory:
        ident = f'{rec["CDB/DB Name"]}/{rec["Database Name"]}'
        is_host_row = rec["Container Type"] in ("CDB$ROOT", "Non-CDB")
        mode = str(rec["Collection Mode"])
        if rec["Container Type"] == "PDB" and mode == "STATSPACK":
            add("info", ident, "STATSPACK in a PDB records instance-wide statistics, so this PDB's CPU, I/O, redo and "
                               "SGA+PGA include the whole instance (a conservative upper bound for this PDB).")
        if is_host_row:
            if mode == "NOAWR":
                add("warning", ident, "Collected without AWR: performance metrics cover only the last ~60 minutes. "
                                      "Make sure this was a peak period, or collect several times and process the runs together.")
            elif mode in ("AWR", "STATSPACK"):
                hours = to_number(rec["Metrics Window (Hours)"])
                snaps = to_number(rec.get("Snapshot Count"))
                if mode == "STATSPACK" and not snaps:
                    add("warning", ident, "STATSPACK mode, but no STATSPACK snapshots were found in this container: "
                                          "performance metrics are 0. Install STATSPACK and schedule snapshots, "
                                          "or use another collection mode.")
                elif hours is not None and hours < SHORT_AWR_HOURS:
                    add("warning", ident, f"Only {hours:g} hours of {mode} history were available (7+ days recommended, "
                                          "30 days ideal). Peaks outside this window are not reflected.")
            else:
                add("info", ident, "Collection mode unknown (no collection_info file); assumed AWR.")
            major = _major(rec["Database Version"])
            if major is not None and major < 19:
                add("warning", ident, f"Oracle {rec['Database Version']}: below 19c, the minimum major version "
                                      "for Amazon RDS for Oracle. An upgrade is part of the migration.")
            if str(rec["RAC Cluster"]).upper() == "Y":
                add("warning", ident, f"RAC cluster with {rec['Nodes']} nodes. Amazon RDS for Oracle does not support RAC; "
                                      "the workload of all nodes must fit a single instance (or consider Amazon EC2).")
            vcpu = num(rec, "Host vCPU Count")
            util = to_number(rec["Host CPU Peak Utilisation (%)"])
            if vcpu and util is not None:
                peak = max(num(rec, "Host CPU Average 99th Percentile"), num(rec, "Host CPU Maximum 90th Percentile"))
                if util < LOW_UTIL_PCT:
                    add("opportunity", ident, f"Low CPU utilisation: peak {peak:g} of {vcpu:g} vCPUs ({util:g}%). "
                                              "Rightsizing to a smaller target is likely possible.")
                elif util > HIGH_UTIL_PCT:
                    add("warning", ident, f"High CPU utilisation: peak {peak:g} of {vcpu:g} vCPUs ({util:g}%). "
                                          "Size the target with headroom.")

        features = set(_split(rec["Feature Usage"])) | set(_split(rec["Ent. Edition feature usage"]))
        review = sorted(f for f in features if f in RDS_REVIEW_FEATURES)
        if review:
            add("warning", ident, "Features to review for Amazon RDS for Oracle compatibility: " + ", ".join(review) + ".")
        ee = _split(rec["Ent. Edition feature usage"])
        if ee and "Enterprise" in str(rec["Database Edition"]):
            add("info", ident, "Enterprise Edition features in use (relevant for a move to Standard Edition 2): " + ", ".join(ee) + ".")
        no_pk = num(rec, "Table w/o PK")
        no_key = to_number(rec.get("Table w/o Key"))
        if no_key:
            add("warning", ident, f"{int(no_key)} table(s) without a primary key or a unique NOT NULL index: AWS DMS "
                                  "cannot identify their rows during change data capture (needs supplemental logging of "
                                  "all columns or another migration method).")
        if no_pk and no_pk != no_key:
            add("info", ident, f"{int(no_pk)} table(s) without a primary key: plan for this if change data capture "
                               "(AWS DMS / GoldenGate) is used for a low-downtime migration.")

    order = {"warning": 0, "opportunity": 1, "info": 2}
    findings.sort(key=lambda f: order.get(f[0], 9))
    return {
        "hosts": hosts, "totals": totals, "editions": editions, "versions": versions,
        "modes": modes, "findings": findings, "warnings": list(dataset.warnings),
    }


# ----------------------------------------------------------------------------
# Sizing data points (see docs/sizing.md)
# ----------------------------------------------------------------------------
GP3_MAX_IOPS = 64000
GP3_MAX_MBPS = 4000
IO2_MAX_IOPS = 256000
IO2_MAX_MBPS = 16000


def sizing(rec):
    """Return the MAT sizing inputs for one inventory row (one MAT assessment per row)."""
    notes = []
    db_cpu_avg, db_cpu_max = num(rec, "DB CPU Average 99th Percentile"), num(rec, "DB CPU Maximum 90th Percentile")
    host_cpu = max(num(rec, "Host CPU Average 99th Percentile"), num(rec, "Host CPU Maximum 90th Percentile"))
    vcpu_count = num(rec, "Host vCPU Count")
    if db_cpu_avg == 0 or db_cpu_max == 0:
        cpu = vcpu_count * 0.75
        notes.append("vCPU = 0.75 x host vCPU count (a DB CPU percentile is 0)")
    else:
        cpu = min(max(db_cpu_avg, db_cpu_max), host_cpu)
        notes.append("vCPU = min(max(DB CPU Avg P99, Max P90), max(host CPU Avg P99, Max P90))")

    sga_pga = num(rec, "SGA+PGA Total (GB)")
    nodes = num(rec, "Nodes", 1) or 1
    if sga_pga == 0:
        memory = num(rec, "Host Total Memory (GB)") * 0.9
        notes.append("memory = 0.9 x host memory (SGA+PGA is 0)")
    elif str(rec.get("RAC Cluster", "")).upper() == "Y" and nodes > 1:
        # RAC: the SGA of every node is consolidated (with 20% per extra node), the PGA is added as is
        sga, pga = to_number(rec.get("SGA (GB)")), to_number(rec.get("PGA (GB)"))
        if sga is None or pga is None:  # files collected before SGA / PGA were split
            sga, pga = sga_pga, 0
        memory = sga / nodes * (1 + 0.2 * (nodes - 1)) + pga
        notes.append(f"memory = SGA / {nodes:g} nodes x (1 + 0.2 x {nodes - 1:g}) + PGA (RAC)")
    else:
        memory = sga_pga

    allocated, used = num(rec, "Storage Allocated (GB)"), num(rec, "Storage Used (GB)")
    storage = max(allocated * 0.8, used)

    # MAT always has database-level values for an inventory row, so it sizes IOPS and throughput from them
    iops = max(num(rec, "DB IOPS Average 99th Percentile"), num(rec, "DB IOPS Maximum 50th Percentile"))
    mbps = max(num(rec, "DB Throughput Average 99th Percentile (MB/s)"), num(rec, "DB Throughput Maximum 50th Percentile (MB/s)"))
    if iops == 0 or mbps == 0:
        notes.append("DB-level IOPS / throughput is 0: MAT does not fall back to host values")

    iops_max = num(rec, "DB IOPS Maximum 50th Percentile")
    mbps_max = num(rec, "DB Throughput Maximum 50th Percentile (MB/s)")
    if iops_max < GP3_MAX_IOPS and mbps_max < GP3_MAX_MBPS:
        storage_type = "gp3"
    elif GP3_MAX_IOPS <= iops_max < IO2_MAX_IOPS and GP3_MAX_MBPS <= mbps_max < IO2_MAX_MBPS:
        storage_type = "io2"
    else:
        storage_type = "none (contact specialist)"
    return {
        "vcpu": round(cpu, 3), "memory": round(memory, 1), "storage": round(storage, 1),
        "iops": round(iops, 2), "mbps": round(mbps, 4), "storage_type": storage_type, "notes": notes,
    }


# ----------------------------------------------------------------------------
# HTML
# ----------------------------------------------------------------------------
CSS = """
body{font-family:-apple-system,Segoe UI,Helvetica,Arial,sans-serif;margin:0;color:#16191f;background:#f2f3f3}
header{background:#232f3e;color:#fff;padding:20px 32px}
header h1{margin:0;font-size:22px} header p{margin:4px 0 0;color:#d1d5db;font-size:13px}
main{padding:20px 32px;max-width:1600px}
section{background:#fff;border-radius:8px;padding:16px 20px;margin-bottom:18px;box-shadow:0 1px 2px rgba(0,0,0,.08)}
h2{font-size:17px;margin:0 0 12px;border-bottom:1px solid #e9ebed;padding-bottom:8px}
.cards{display:grid;grid-template-columns:repeat(auto-fill,minmax(170px,1fr));gap:12px}
.card{border:1px solid #e9ebed;border-radius:6px;padding:10px 12px}
.card .v{font-size:22px;font-weight:600} .card .k{font-size:12px;color:#5f6b7a}
table{border-collapse:collapse;width:100%;font-size:12.5px;border:1px solid #d1d5db}
th,td{border:1px solid #e1e4e8;padding:6px 10px;text-align:left;vertical-align:top}
th{background:#f2f3f3;position:sticky;top:0;font-weight:600;vertical-align:bottom;line-height:1.3}
tbody tr:nth-child(even) td{background:#fafbfc} tbody tr:hover td{background:#eef5fd}
th.n,td.n{text-align:right} td.n{font-variant-numeric:tabular-nums;white-space:nowrap}
td:first-child{white-space:nowrap;font-weight:500}
.scroll{overflow-x:auto}
.badge{display:inline-block;border-radius:10px;padding:1px 8px;font-size:11px;font-weight:600;white-space:nowrap}
.warning{background:#fff4e5;color:#8a4b00} .opportunity{background:#e6f4ea;color:#1d6b33} .info{background:#e8f1fb;color:#0b4f8a}
.banner{border-left:4px solid #ec7211;background:#fff8f0;padding:10px 14px;margin-bottom:18px;border-radius:4px;font-size:13px}
.bar{background:#e9ebed;border-radius:3px;height:8px;width:90px;display:inline-block;vertical-align:middle;margin-right:6px}
.bar span{display:block;height:8px;border-radius:3px;background:#0972d3}
.bar span.hi{background:#d91515} .bar span.lo{background:#1d8102}
section p{font-size:13px}
details.glossary>summary{cursor:pointer;list-style:none;display:flex;align-items:baseline;gap:10px}
details.glossary>summary::-webkit-details-marker{display:none}
details.glossary>summary h2{border:0;margin:0;padding:0}
details.glossary>summary h2::before{content:"▸ ";color:#5f6b7a}
details.glossary[open]>summary h2::before{content:"▾ "}
details.glossary[open]>summary .muted{display:none}
details.glossary[open]>summary{border-bottom:1px solid #e9ebed;padding-bottom:8px;margin-bottom:12px} small,.muted{color:#5f6b7a} dl{font-size:12.5px} dt{font-weight:600;margin-top:6px} dd{margin:2px 0 0 0;color:#414d5c}
"""


def _table(headers, rows, numeric=()):
    out = ['<div class="scroll"><table><thead><tr>']
    for h in headers:
        cls = ' class="n"' if h in numeric else ""  # no backslash inside f-string expressions (Python < 3.12)
        out.append(f"<th{cls}>{html.escape(h)}</th>")
    out.append("</tr></thead><tbody>")
    for row in rows:
        out.append("<tr>")
        for h, cell in zip(headers, row):
            cls = ' class="n"' if h in numeric else ""
            out.append(f"<td{cls}>{cell}</td>")
        out.append("</tr>")
    out.append("</tbody></table></div>")
    return "".join(out)


def _util_cell(util):
    u = to_number(util)
    if u is None:
        return "&ndash;"
    cls = "hi" if u > HIGH_UTIL_PCT else ("lo" if u < LOW_UTIL_PCT else "")
    return f'<span class="bar"><span class="{cls}" style="width:{min(u, 100):.0f}%"></span></span>{u:g}%'


def server_rows(instance_rows):
    """Instance-level rows for reporting: a RAC database is represented by its cluster row only.

    The per-node rows of a RAC (same CDB/instance name, a host that is part of the cluster row's host list)
    are left out so the cluster is not counted twice; they stay in the consolidated instance-level CSV.
    """
    clusters = {}
    for r in instance_rows:
        hk = host_key(r.get("Server Name"))
        if "+" in hk:
            clusters.setdefault(r.get("CDB/Instance Name", "").upper(), []).append(set(hk.split("+")))
    out = []
    for r in instance_rows:
        hk = host_key(r.get("Server Name"))
        db = r.get("CDB/Instance Name", "").upper()
        if "+" not in hk and any(hk in hosts for hosts in clusters.get(db, [])):
            continue
        out.append(r)
    return out


def render_html(inventory, dataset, summary, instance_rows):
    now = _dt.datetime.now().strftime("%Y-%m-%d %H:%M")
    modes = ", ".join(summary["modes"]) or "Unknown"
    parts = [f"""<!DOCTYPE html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Oracle Inventory and Performance Report</title><style>{CSS}</style></head><body>
<header><h1>Oracle Inventory and Performance Report</h1>
<p>Generated {now} by oracletools {__version__} &middot; collection mode: {html.escape(modes)}</p></header><main>"""]

    if "AWR" in summary["modes"]:
        parts.append('<div class="banner"><b>AWR mode</b> reads DBA_HIST_* views, which requires the Oracle Diagnostics '
                     'Pack licence. Ensuring the databases are licensed is the customer\'s responsibility.</div>')
    if "NOAWR" in summary["modes"]:
        parts.append('<div class="banner"><b>Non-AWR collection:</b> performance metrics for these databases cover only '
                     'the last ~60 minutes before collection. Results are only representative if they were collected '
                     'during peak load.</div>')

    # Overview
    cards = "".join(f'<div class="card"><div class="v">{_fmt(v, 1)}</div><div class="k">{html.escape(k)}</div></div>'
                    for k, v in summary["totals"].items())
    ed = ", ".join(f"{html.escape(k)}: {v}" for k, v in summary["editions"].items()) or "&ndash;"
    ver = ", ".join(f"{html.escape(k)}: {v}" for k, v in summary["versions"].items()) or "&ndash;"
    parts.append(f'<section><h2>Overview</h2><div class="cards">{cards}</div>'
                 f'<p class="muted">Editions &ndash; {ed}<br>Versions &ndash; {ver}</p></section>')

    # Findings
    if summary["findings"]:
        rows = [(f'<span class="badge {s}">{s}</span>', _esc(scope), html.escape(msg)) for s, scope, msg in summary["findings"]]
        parts.append("<section><h2>Findings</h2>" + _table(["Type", "Database", "Finding"], rows) + "</section>")

    # Key sizing data points (formulas: docs/sizing.md)
    hdr = ["Database", "Type", "Mode", "vCPU", "Memory (GiB)", "Storage (GiB)", "IOPS", "Throughput (MB/s)",
           "Storage type"]
    numeric = set(hdr[3:8])
    rows = []
    for r in inventory:
        z = sizing(r)
        rows.append([
            _esc(f'{r["CDB/DB Name"]}/{r["Database Name"]}'), _esc(r["Container Type"]), _esc(r["Collection Mode"]),
            _fmt(z["vcpu"], 3), _fmt(z["memory"], 1), _fmt(z["storage"], 1), _fmt(z["iops"], 2), _fmt(z["mbps"], 4),
            _esc(z["storage_type"]),
        ])
    parts.append("<section><h2>Key data points for performance sizing</h2>" + _table(hdr, rows, numeric) + "</section>")

    # Servers / instances
    hdr = ["Server", "CDB / DB", "Version", "Edition", "RAC", "Nodes", "PDBs", "vCPU", "Memory (GB)", "Free Mem (GB)",
           "Storage (GB)", "CPU Avg P99 (vCPU)", "CPU Max P90 (vCPU)", "Peak CPU util.", "IOPS Avg P99", "IOPS Max P50",
           "Thr. Avg P99 (MB/s)", "Thr. Max P50 (MB/s)", "Net Avg (MB/s)", "Net Max (MB/s)"]
    numeric = set(hdr[5:])
    rows = []
    for r in server_rows(instance_rows):
        vcpu = num(r, "vCPU Count")
        peak = max(num(r, "CPU Average 99th Percentile"), num(r, "CPU Maximum 90th Percentile"))
        util = round(peak / vcpu * 100, 1) if vcpu else None
        rows.append([
            _esc(host_label(r.get("Server Name"))), _esc(r.get("CDB/Instance Name")), _esc(r.get("Database Version")),
            _esc(r.get("Database Edition")), _esc(r.get("RAC Cluster")), _fmt(r.get("Nodes")), _fmt(r.get("Total PDB Count")),
            _fmt(r.get("vCPU Count")), _fmt(r.get("Total Memory (GB)")), _fmt(r.get("Free Memory (GB)")),
            _fmt(r.get("Total Storage (GB)")), _fmt(r.get("CPU Average 99th Percentile"), 3),
            _fmt(r.get("CPU Maximum 90th Percentile"), 3), _util_cell(util),
            _fmt(r.get("IOPS Average 99th Percentile")), _fmt(r.get("IOPS Maximum 50th Percentile")),
            _fmt(r.get("Throughput Average 99th Percentile (MB/s)"), 3), _fmt(r.get("Throughput Maximum 50th Percentile (MB/s)"), 3),
            _fmt(r.get("Network Throughput Average (MB/s)"), 3), _fmt(r.get("Network Throughput Maximum (MB/s)"), 3),
        ])
    parts.append("<section><h2>Servers and instances</h2><p class='muted'>One row per server. A RAC database is shown "
                 "as one cluster row listing every node, with metrics summed across instances; the per-node rows are in "
                 "consolidated_oracle_instance_level_data.csv (to check how evenly the workload is spread). "
                 "CPU values are vCPU-equivalents (number of CPUs busy).</p>"
                 + _table(hdr, rows, numeric) + "</section>")

    # Databases: sizing
    hdr = ["Database", "Type", "Mode", "Window (h)", "SGA+PGA (GB)", "Allocated (GB)", "Used (GB)",
           "CPU Avg P99", "CPU Max P90", "IOPS Avg P99", "IOPS Max P50", "Thr. Avg P99 (MB/s)", "Thr. Max P50 (MB/s)",
           "Redo Avg P99 (MB/s)", "Redo Max P50 (MB/s)"]
    numeric = set(hdr[3:])
    rows = [[
        _esc(f'{r["CDB/DB Name"]}/{r["Database Name"]}'), _esc(r["Container Type"]), _esc(r["Collection Mode"]),
        _fmt(r["Metrics Window (Hours)"], 1), _fmt(r["SGA+PGA Total (GB)"], 1), _fmt(r["Storage Allocated (GB)"], 2),
        _fmt(r["Storage Used (GB)"], 2), _fmt(r["DB CPU Average 99th Percentile"], 3), _fmt(r["DB CPU Maximum 90th Percentile"], 3),
        _fmt(r["DB IOPS Average 99th Percentile"]), _fmt(r["DB IOPS Maximum 50th Percentile"]),
        _fmt(r["DB Throughput Average 99th Percentile (MB/s)"], 3), _fmt(r["DB Throughput Maximum 50th Percentile (MB/s)"], 3),
        _fmt(r["RedoRate Average 99th Percentile (MB/s)"], 3), _fmt(r["RedoRate Maximum 50th Percentile (MB/s)"], 3),
    ] for r in inventory]
    parts.append("<section><h2>Databases &ndash; performance and storage</h2>" + _table(hdr, rows, numeric) + "</section>")

    # Databases: objects and features (HA setup / BI components only when some database has one)
    def _has(col):
        return any(_split(r[col]) for r in inventory)

    cols = [("Database", None), ("Tables", "Table Count"), ("Views", "Views Count"), ("Indexes", "Index Count"),
            ("Procedures", "SP Count"), ("Functions", "Function Count"), ("Triggers", "Triggers Count"),
            ("Tables w/o PK", "Table w/o PK"), ("Tables w/o key", "Table w/o Key"), ("DB links", "DB Link"), ("Jobs", "Jobs"), ("SA privileges", "SA privilege")]
    text_cols = [("HA setup", "HA Setup"), ("BI components", "BI Components")]
    text_cols = [c for c in text_cols if _has(c[1])]
    hdr = [c[0] for c in cols] + [c[0] for c in text_cols] + ["Features in use", "Enterprise Edition features"]
    numeric = {c[0] for c in cols[1:]}
    rows = []
    for r in inventory:
        row = [_esc(f'{r["CDB/DB Name"]}/{r["Database Name"]}')] + [_fmt(r[src]) for _, src in cols[1:]]
        row += [_esc(", ".join(_split(r[src])) or "None") for _, src in text_cols]
        row += [_esc(", ".join(_split(r["Feature Usage"])) or "None"),
                _esc(", ".join(_split(r["Ent. Edition feature usage"])) or "None")]
        rows.append(row)
    parts.append("<section><h2>Databases &ndash; objects and features</h2>" + _table(hdr, rows, numeric) + "</section>")

    if summary["warnings"]:
        items = "".join(f"<li>{html.escape(w)}</li>" for w in summary["warnings"])
        parts.append(f"<section><h2>Processing notes</h2><ul class='muted'>{items}</ul></section>")

    parts.append(GLOSSARY)
    parts.append("</main></body></html>")
    return "".join(parts)


GLOSSARY = """<section><details class="glossary"><summary><h2>How to read the metrics</h2>
<span class="muted">(click to expand)</span></summary><dl>
<dt>Key data points for performance sizing</dt><dd>Minimum requirements per database row; no headroom is added.
<b>vCPU</b> = min(max(DB CPU Avg P99, DB CPU Max P90), max(host CPU Avg P99, host CPU Max P90)), or 0.75 &times; host
vCPUs when a DB CPU value is 0. <b>Memory</b> = SGA+PGA (RAC: SGA / nodes &times; (1 + 0.2 &times; (nodes &minus; 1)) + PGA),
or 0.9 &times; host memory when SGA+PGA is 0. <b>Storage</b> = max(0.8 &times; allocated, used).
<b>IOPS</b> = max(DB IOPS Avg P99, DB IOPS Max P50). <b>Throughput</b> = max(DB throughput Avg P99, DB throughput Max P50).
<b>Storage type</b>: gp3 when DB IOPS Max P50 &lt; 64,000 and DB throughput Max P50 &lt; 4,000 MB/s; io2 up to 256,000 IOPS
and 16,000 MB/s. Every row is sized on its own, including CDB$ROOT; the CDB$ROOT row carries host-level CPU, so do not
add it to its PDBs.</dd>
<dt>Collection mode</dt><dd>AWR: percentiles over AWR snapshots (default hourly) for up to the last 30 days
(Diagnostics Pack licence required). STATSPACK: percentiles over STATSPACK snapshot intervals for up to the last
30 days; STATSPACK has no within-interval peaks, so its 'Maximum' columns are percentiles of interval averages.
NOAWR: GV$SYSMETRIC_SUMMARY / GV$CON_SYSMETRIC_SUMMARY, i.e. the last ~60 minutes only.</dd>
<dt>CPU Avg P99 / CPU Max P90</dt><dd>Number of CPUs busy (vCPU-equivalents), not a percentage. Avg P99 is the 99th
percentile of the per-snapshot averages; Max P90 is the 90th percentile of the per-snapshot peaks. Host rows use
'Host CPU Usage Per Sec' (all processes on the server); PDB rows use the PDB's own 'CPU Usage Per Sec'.</dd>
<dt>Peak CPU utilisation</dt><dd>max(CPU Avg P99, CPU Max P90) divided by the vCPU count of the server.</dd>
<dt>IOPS Avg P99 / IOPS Max P50</dt><dd>Total (read + write) I/O requests per second: 'Physical Read Total IO
Requests Per Sec' + 'Physical Write Total IO Requests Per Sec' per snapshot. Avg P99 is the 99th percentile of the
per-snapshot averages, Max P50 the median of the per-snapshot peaks (read peak + write peak, a slight over-estimate).</dd>
<dt>Throughput Avg P99 / Max P50</dt><dd>Total (read + write) MB/s from 'Physical Read/Write Total Bytes Per Sec',
same percentiles as IOPS.</dd>
<dt>Redo Avg P99 / Max P50</dt><dd>Redo generated, MB/s. Useful to size change data capture (AWS DMS / GoldenGate).</dd>
<dt>SGA+PGA, SGA, PGA</dt><dd>99th percentile of SGA, PGA ('total PGA allocated') and their sum per snapshot
(AWR, STATSPACK), or current allocation (NOAWR), in GB, summed across RAC instances. Each is its own percentile,
so SGA + PGA can differ slightly from SGA+PGA.</dd>
<dt>Storage allocated / used</dt><dd>Datafiles of the container / segments of application schemas (Oracle-maintained
schemas excluded), in GB. The CDB$ROOT row covers only the root container's files; each PDB has its own row. Host
total storage covers every container of the CDB.</dd>
<dt>HA setup / BI components</dt><dd>HA setup lists RAC (cluster_database = TRUE), Data Guard (this database is a
standby, has a valid standby archive destination, or a Data Guard configuration with other members) and Active Data
Guard (feature currently used). BI components lists Oracle BI, SOA Suite, Data Integrator and other Fusion Middleware
repository schemas created by RCU (e.g. DEV_BIPLATFORM, DEV_MDS). The columns are hidden when no database has any.</dd>
<dt>Tables w/o PK / w/o key</dt><dd>Tables without a primary key, and tables with neither a primary key nor a unique
index on NOT NULL columns (no key AWS DMS can use to identify rows).</dd>
<dt>Objects</dt><dd>Counts exclude Oracle-maintained schemas. Procedures and functions are standalone objects only;
members of packages are not counted. Jobs are enabled scheduler jobs of application schemas.</dd>
<dt>RAC</dt><dd>The cluster row and the database-level metrics are summed across instances per AWR snapshot
(non-AWR: summed across instances), then the percentile is taken, so they represent the whole cluster.</dd>
<dt>Network Avg / Max</dt><dd>'Network Traffic Volume Per Sec': Oracle client and database link traffic, MB/s.
Despite the column names, 'Average' is the 99th percentile of the per-snapshot averages and 'Maximum' the median of the
per-snapshot peaks.</dd>
</dl></details></section>"""


# ----------------------------------------------------------------------------
# Text
# ----------------------------------------------------------------------------
def render_text(summary):
    lines = ["", "Oracle inventory summary", "=" * 60]
    for k, v in summary["totals"].items():
        lines.append(f"  {k:<30} {v:>12,}" if isinstance(v, int) else f"  {k:<30} {v:>12,.2f}")
    if summary["editions"]:
        lines.append("  Editions: " + ", ".join(f"{k} ({v})" for k, v in summary["editions"].items()))
    if summary["versions"]:
        lines.append("  Versions: " + ", ".join(f"{k} ({v})" for k, v in summary["versions"].items()))
    lines.append("  Collection mode(s): " + (", ".join(summary["modes"]) or "Unknown"))
    if summary["findings"]:
        lines += ["", "Findings", "-" * 60]
        for sev, scope, msg in summary["findings"]:
            lines.append(f"  [{sev.upper():<11}] {scope}: {msg}")
    return "\n".join(lines)
