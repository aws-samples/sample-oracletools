# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
"""Offline tests: run with  python3 -m unittest discover -s tests -v   (no database needed)."""

import csv
import io
import re
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from oratools import MODE_AWR, MODE_NOAWR, MODE_STATSPACK, MODES, sqlscripts  # noqa: E402
from oratools import dbc as dbcmod  # noqa: E402
from oratools import mat as matmod  # noqa: E402
from oratools import process as proc  # noqa: E402
from oratools import report  # noqa: E402
from oratools.config import load_targets  # noqa: E402

SAMPLES = ROOT / "samples" / "collected"

INST_HDR = ("Server Name,CDB/Instance Name,Database Version,Database Edition,RAC Cluster,Nodes,Total PDB Count,vCPU Count,"
            "Total Memory (GB),Free Memory (GB),Total Storage (GB),CPU Average 99th Percentile,CPU Maximum 90th Percentile,"
            "IOPS Average 99th Percentile,IOPS Maximum 50th Percentile,Throughput Average 99th Percentile (MB/s),"
            "Throughput Maximum 50th Percentile (MB/s),Network Throughput Average (MB/s),Network Throughput Maximum (MB/s)")
DB_HDR = ("Server Name,CDB/DB Name,Database Name,CPU Average 99th Percentile,CPU Maximum 90th Percentile,IOPS Average 99th Percentile,"
          "IOPS Maximum 50th Percentile,Throughput Average 99th Percentile (MB/s),Throughput Maximum 50th Percentile (MB/s),"
          "SGA+PGA Total (GB),Storage Allocated (GB),Storage Used (GB),Table Count,Views Count,Index Count,SP Count,Function Count,"
          "Triggers Count,Trustworthy property,Table w/o PK,RedoRate Average 99th Percentile (MB/s),RedoRate Maximum 50th Percentile (MB/s)")
FEAT_HDR = "Server Name,CDB/DB Name,Database Name,Feature Usage,DB Link,SA privilege,Jobs,BI Components,HA Setup,Ent. Edition feature usage"


class TempDirTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="oratools_test_"))

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def write(self, name, text):
        path = self.tmp / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        return path


class SqlScriptTests(unittest.TestCase):
    def test_every_script_parses_for_every_mode(self):
        for mode in MODES:
            for kind in sqlscripts.SCRIPTS:
                s = sqlscripts.load(kind, mode)
                self.assertTrue(s.header.startswith("Server Name,"), s.name)
                self.assertTrue(s.plsql.upper().startswith("DECLARE"), s.name)
                self.assertTrue(s.plsql.rstrip().endswith("END;"), s.name)
                self.assertNotIn("&", s.plsql, s.name)
                for word in ("SPOOL", "EXIT"):
                    self.assertNotRegex(s.plsql, rf"(?m)^\s*{word}\b", s.name)

    @staticmethod
    def _strip_source(text):
        return re.sub(r"-- >>> metric source \(\w+\) >>>.*?-- <<< metric source <<<", "<source>", text, flags=re.S)

    def test_modes_share_everything_but_the_metric_source(self):
        for kind in ("instance", "database"):
            texts = {m: self._strip_source(sqlscripts.load(kind, m).plsql) for m in MODES}
            self.assertEqual(texts[MODE_AWR], texts[MODE_NOAWR], kind)
            self.assertEqual(texts[MODE_AWR], texts[MODE_STATSPACK], kind)

    def test_only_awr_mode_reads_awr(self):
        self.assertIn("DBA_HIST", sqlscripts.load("instance", MODE_AWR).plsql)
        for mode in (MODE_NOAWR, MODE_STATSPACK):
            for kind in ("instance", "database", "features"):
                self.assertNotIn("DBA_HIST", sqlscripts.load(kind, mode).plsql.upper(), (mode, kind))
        self.assertIn("STATS$SYSSTAT", sqlscripts.load("database", MODE_STATSPACK).plsql)

    def test_iops_and_throughput_are_read_plus_write(self):
        """D3: IOPS and throughput add read and write counters in every mode."""
        for mode in (MODE_AWR, MODE_NOAWR):
            plsql = sqlscripts.load("database", mode).plsql
            self.assertIn("'Physical Read Total IO Requests Per Sec'',''Physical Write Total IO Requests Per Sec'", plsql)
            self.assertIn("'Physical Read Total Bytes Per Sec'',''Physical Write Total Bytes Per Sec'", plsql)
        plsql = sqlscripts.load("database", MODE_STATSPACK).plsql
        self.assertIn("'physical read total IO requests'',''physical write total IO requests'", plsql)

    def test_rac_cluster_row_sums_instances(self):
        """D4: RAC cluster row (p_inst NULL) adds instances per snapshot before the percentile."""
        awr = sqlscripts.load("instance", MODE_AWR).plsql
        self.assertIn("GROUP BY SNAP_ID", awr)
        self.assertIn("put_row(v_server_name, NULL)", awr)
        self.assertIn("SUM(' || v_expr || ') AS total_mem", sqlscripts.load("database", MODE_AWR).plsql)  # D14
        self.assertIn("GROUP BY BUCKET", sqlscripts.load("instance", MODE_STATSPACK).plsql)

    def test_python_sources_parse_on_older_python(self):
        """Python 3.9+ is supported; backslashes inside f-string expressions need 3.12 (PEP 701)."""
        import ast
        for path in [ROOT / "oracle_collector.py", *sorted((ROOT / "oratools").glob("*.py")), Path(__file__)]:
            src = path.read_text(encoding="utf-8")
            for node in ast.walk(ast.parse(src)):
                if isinstance(node, ast.FormattedValue):
                    seg = ast.get_source_segment(src, node.value) or ""
                    self.assertNotIn("\\", seg, f"{path.name}:{node.lineno}: backslash in f-string expression")

    def test_switch_container_only_accepts_identifiers(self):
        from oratools import collect
        self.assertEqual(collect._switch_container_sql("PDB1"), 'ALTER SESSION SET CONTAINER = "PDB1"')
        self.assertEqual(collect._switch_container_sql("HR_PDB$2#"), 'ALTER SESSION SET CONTAINER = "HR_PDB$2#"')
        for bad in ('PDB1"; DROP USER X --', "1PDB", "PDB 1", "", None, "A" * 129):
            with self.assertRaises(ValueError):
                collect._switch_container_sql(bad)

    def test_db_links_exclude_oracle_maintained_owners(self):
        sql = (sqlscripts.SQL_DIR / "common/database_features.sql").read_text(encoding="utf-8")
        block = sql[sql.index("FROM DBA_DB_LINKS"):sql.index("v_db_link_count := 0")]
        self.assertIn("ORACLE_MAINTAINED", block)          # e.g. SYS.SYS_HUB is not an application link
        self.assertIn("c_system_schemas", block)           # 11g: fixed list
        self.assertIn("OWNER = ''PUBLIC''", block)        # PUBLIC links are kept

    def test_collection_sql_is_read_only(self):
        """Only SELECT / PL/SQL / DBMS_OUTPUT and ALTER SESSION: no DML, DDL or grants anywhere in sql/."""
        forbidden = re.compile(r"\b(INSERT\s+INTO|UPDATE\s+\w+\s+SET|DELETE\s+FROM|MERGE\s+INTO|TRUNCATE|"
                               r"CREATE\s+(OR\s+REPLACE\s+)?(TABLE|USER|VIEW|INDEX|PROCEDURE|PACKAGE|SYNONYM)|"
                               r"DROP\s+\w+|GRANT\s|REVOKE\s|ALTER\s+(SYSTEM|USER|TABLE|DATABASE)|"
                               r"STATSPACK\.SNAP|CREATE_SNAPSHOT)", re.I)
        sql_dir = ROOT / "sql"
        files = list(sql_dir.rglob("*.sql"))
        self.assertGreater(len(files), 10)
        for path in files:
            code = "\n".join(line.split("--")[0] for line in path.read_text().splitlines())
            self.assertIsNone(forbidden.search(code), f"{path}: {forbidden.search(code)}")
        self.assertFalse((sql_dir / "setup").exists())

    def test_inventory_fixes(self):
        db = sqlscripts.load("database", MODE_AWR).plsql
        feat = sqlscripts.load("features", MODE_AWR).plsql
        self.assertNotIn("COUNT(DISTINCT", db)                     # D9
        self.assertIn("ORACLE_MAINTAINED", db)                     # D15
        self.assertIn("ORACLE_MAINTAINED", feat)                   # D16
        self.assertIn("V$PWFILE_USERS", feat)                      # D8
        self.assertNotIn("DBA_ROLE_PRIVS", feat)
        self.assertIn("FROM V$DATAFILE", sqlscripts.load("instance", MODE_AWR).plsql)  # D5
        for kind in ("instance", "database"):
            self.assertNotIn("Host CPU Utilization (%)", sqlscripts.load(kind, MODE_NOAWR).plsql)

    def test_python_and_sqlplus_headers_match_samples(self):
        sample = {
            "instance": next(SAMPLES.glob("*_oracle_instance_level_data.csv")),
            "database": next(SAMPLES.glob("*_oracle_database_level_data.csv")),
            "features": next(SAMPLES.glob("*_oracle_database_features.csv")),
            "info": next(SAMPLES.glob("*_collection_info.csv")),
        }
        for kind, path in sample.items():
            header = path.read_text().splitlines()[0]
            self.assertEqual(header, sqlscripts.load(kind, MODE_AWR).header, kind)


class ProcessSampleTests(TempDirTest):
    def test_sample_inventory_and_outputs(self):
        ds = proc.load_dataset([SAMPLES])
        inv = proc.build_inventory(ds)
        self.assertEqual(len(inv), 6)
        by_id = {f'{r["CDB/DB Name"]}/{r["Database Name"]}': r for r in inv}
        self.assertEqual(by_id["ORCLCDB/ORCLCDB"]["Container Type"], "CDB$ROOT")
        self.assertEqual(by_id["ORCLCDB/PDB1"]["Container Type"], "PDB")
        self.assertEqual(by_id["ORCLEE/ORCLEE"]["Container Type"], "Non-CDB")
        self.assertEqual(by_id["ORCLSE2/ORCLSE2"]["Collection Mode"], "STATSPACK")
        self.assertEqual(by_id["ORCLEE/ORCLEE"]["Collection Mode"], "AWR")
        # PDB gets host metrics from the CDB's instance row and its own DB metrics
        self.assertEqual(by_id["ORCLCDB/PDB1"]["Host vCPU Count"], 8)
        self.assertEqual(by_id["ORCLCDB/PDB1"]["Table Count"], 31)
        self.assertEqual(by_id["ORCLCDB/PDB1"]["Host Total Storage (GB)"], 7)  # D5: whole CDB
        self.assertEqual(ds.warnings, [])

        files = proc.write_consolidated(ds, self.tmp)
        self.assertEqual(len(files), 4)
        summary = report.summarise(inv, ds)
        self.assertEqual(summary["totals"]["Servers / clusters"], 2)
        self.assertEqual(summary["totals"]["Pluggable databases"], 2)
        # RAC sample: the PDB is joined to the cluster row (both nodes), not to a node row
        rac = by_id["RACCDB/RACPDB1"]
        self.assertEqual((rac["RAC Cluster"], rac["Nodes"], rac["Host vCPU Count"], rac["Host Total Memory (GB)"]), ("Y", 2, 16, 128))
        self.assertEqual(summary["totals"]["Total vCPU"], 24)
        html = report.render_html(inv, ds, summary, ds.rows["instance"])
        self.assertIn("Key data points for performance sizing", html)
        self.assertIn("<th>HA setup</th>", html)  # the RAC sample has HA setup RAC
        self.assertIn("<td>racnode1-racnode2</td>", html)
        self.assertNotIn("<td>racnode1</td>", html)  # node rows are not reported
        self.assertIn('<details class="glossary">', html)
        self.assertIn("ORCLCDB/PDB1", html)

    def test_mat_matches_template(self):
        inv = proc.build_inventory(proc.load_dataset([SAMPLES]))
        path, rows = matmod.write_mat(inv, self.tmp, region="ap-southeast-2")
        with open(matmod.TEMPLATE_FILE, newline="") as fh:
            template = [c for c in next(csv.reader(fh)) if c]
        with open(path, newline="") as fh:
            reader = csv.DictReader(fh)
            self.assertEqual(reader.fieldnames, template)
            out = list(reader)
        pdb = next(r for r in out if r["dbIdentifier"] == "ORCLCDB/PDB1")
        non_cdb = next(r for r in out if r["dbIdentifier"] == "ORCLEE/ORCLEE")
        self.assertEqual(pdb["sourceEngine"], "oracle")
        self.assertEqual(pdb["cdbName"], "ORCLCDB")
        self.assertEqual(non_cdb["cdbName"], "")
        self.assertEqual(pdb["clusterName"], "dbhost01")
        self.assertEqual(pdb["targetAWSRegion"], "ap-southeast-2")
        # cluster* from instance level, db* from database level
        src = next(r for r in inv if r["Database Name"] == "PDB1")
        self.assertEqual(pdb["clusterVcpuCount"], str(src["Host vCPU Count"]))
        self.assertEqual(pdb["clusterCpuMaxP90"], str(src["Host CPU Maximum 90th Percentile"]))
        self.assertEqual(pdb["dbCpuMaxP90"], str(src["DB CPU Maximum 90th Percentile"]))
        self.assertNotEqual(pdb["clusterCpuMaxP90"], pdb["dbCpuMaxP90"])
        self.assertEqual(pdb["eeFeatureUsage"], "Materialized Views with Query Rewrite, Parallel SQL Query Execution")
        self.assertEqual(non_cdb["featureUsage"], "None")
        self.assertEqual(pdb["tablesWithoutKeyCount"], str(src["Table w/o Key"]))
        self.assertEqual(pdb["tablesWithoutKey"], "")  # table names are not collected
        # questionnaire fields stay blank
        for field in ("isIsvCotsApplication", "preferLicenseIncluded", "requireMultiAZ"):
            self.assertEqual(pdb[field], "")
        # MAT rejects a blank Environment (enum prod | non-prod)
        self.assertEqual(pdb["Environment"], "non-prod")
        _, rows = matmod.to_mat_rows(inv, environment="prod")
        self.assertEqual({r["Environment"] for r in rows}, {"prod"})

    def test_mat_fields_doc_covers_template(self):
        with open(matmod.TEMPLATE_FILE, newline="") as fh:
            template = [c for c in next(csv.reader(fh)) if c]
        documented = re.findall(r"^\| `(\w+)` \|", (ROOT / "docs" / "mat-fields.md").read_text(), re.M)
        self.assertEqual(sorted(documented), sorted(template))

    def test_dbc_file(self):
        inv = proc.build_inventory(proc.load_dataset([SAMPLES]))
        rows = dbcmod.to_dbc_rows(inv)
        self.assertEqual(len(rows), 4)  # one row per CDB / non-CDB, PDBs are part of their CDB
        by_db = {r["Source DB Name"]: r for r in rows}
        self.assertEqual(by_db["ORCLSE2"]["Source DB Edition"], "Standard Two")
        self.assertEqual(by_db["ORCLCDB"]["Source DB Edition"], "Enterprise")
        self.assertEqual((by_db["RACCDB"]["Source Host/Server Name"], by_db["RACCDB"]["Source Host vCPU"]), ("racnode1-racnode2", 16))
        for r in rows:
            self.assertEqual(r["Source Location"], "On-Premises")
            self.assertEqual(r["Source Database Type"], "Oracle")
            self.assertTrue(r["Source Host vCPU"] and r["Source Storage (GB)"])
            self.assertEqual(r["Source EC2 Region"], "")
        ec2 = dbcmod.to_dbc_rows(inv, location="ec2", region="us-west-2")[0]
        self.assertEqual((ec2["Source Location"], ec2["Source EC2 Region"], ec2["Source EC2 OS"], ec2["Source EC2 EBS Volume Type"]),
                         ("EC2", "us-west-2", "Linux", "gp3"))
        # no CPU data collected (e.g. STATSPACK on a CDB root): utilisation blank, not 0
        nocpu = [dict(r, **{"Host CPU Average 99th Percentile": 0, "Host CPU Maximum 90th Percentile": 0}) for r in inv]
        self.assertTrue(all(r["Source CPU Utilization (%)"] == "" for r in dbcmod.to_dbc_rows(nocpu)))
        path, _ = dbcmod.write_dbc(inv, Path(tempfile.mkdtemp(prefix="oratools_dbc_")))
        with open(path, newline="") as fh:
            self.assertEqual(next(csv.reader(fh)), dbcmod.COLUMNS)
        shutil.rmtree(path.parent, ignore_errors=True)

    def test_mat_skip_cdb_root(self):
        inv = proc.build_inventory(proc.load_dataset([SAMPLES]))
        _, rows = matmod.to_mat_rows(inv, skip_cdb_root=True)
        self.assertNotIn("ORCLCDB/ORCLCDB", [r["dbIdentifier"] for r in rows])
        self.assertEqual(len(rows), 4)


class RobustnessTests(TempDirTest):
    def test_rac_quoted_and_legacy_unquoted_hosts(self):
        self.write("rac_racdb_oracle_instance_level_data.csv", "\n".join([
            INST_HDR,
            "node1.example.com,RACDB,19.0.0.0.0,Enterprise Edition,Y,2,0,8,64,10,500,3,4,100,200,10,20,1,2",
            "node2.example.com,RACDB,19.0.0.0.0,Enterprise Edition,Y,2,0,8,64,12,500,3.5,4.5,110,210,11,21,1,2",
            # legacy format: unquoted host list in the cluster row
            "node1.example.com,node2.example.com,RACDB,19.0.0.0.0,Enterprise Edition,Y,2,0,16,128,11,500,6.5,8.5,210,410,21,41,2,4",
        ]))
        self.write("rac_racdb_racdb_oracle_database_level_data.csv", DB_HDR + "\n" +
                   '"node1.example.com,node2.example.com",RACDB,RACDB,6,8,200,400,20,40,24,500,300,10,1,5,0,0,0,N/A,2,1.5,3\n')
        self.write("rac_racdb_racdb_oracle_database_features.csv", FEAT_HDR + "\n" +
                   '"node1.example.com,node2.example.com",RACDB,RACDB,"Partitioning, Real Application Clusters (RAC)",0,0,3,None,RAC,'
                   '"Partitioning; Real Application Clusters (RAC)"' + " " * 300 + "\n")
        ds = proc.load_dataset([self.tmp])
        self.assertEqual(ds.warnings, [])
        inv = proc.build_inventory(ds)
        self.assertEqual(len(inv), 1)
        rec = inv[0]
        self.assertEqual(rec["Host vCPU Count"], 16)  # the cluster row, not a single node
        self.assertEqual(rec["Container Type"], "Non-CDB")
        self.assertEqual(rec["Ent. Edition feature usage"], "Partitioning; Real Application Clusters (RAC)")
        _, rows = matmod.to_mat_rows(inv)
        self.assertEqual(rows[0]["tablesWithoutKeyCount"], "")  # old file without 'Table w/o Key': not collected
        self.assertEqual(rows[0]["tablesWithoutPk"], 2)
        self.assertEqual(rows[0]["clusterName"], "node1-node2")
        self.assertEqual(rows[0]["isRacCluster"], "Y")
        findings = report.summarise(inv, ds)["findings"]
        self.assertTrue(any("RAC cluster with 2 nodes" in f[2] for f in findings))
        html = report.render_html(inv, ds, report.summarise(inv, ds), ds.rows["instance"])
        self.assertIn("<th>HA setup</th>", html)          # shown: RAC has an HA setup
        self.assertNotIn("<th>BI components</th>", html)  # hidden: all None
        # reporting uses the RAC cluster row only; the node rows stay in the consolidated instance-level data
        self.assertEqual([proc.host_key(r["Server Name"]) for r in report.server_rows(ds.rows["instance"])], ["node1+node2"])
        self.assertNotIn("<td>node1</td>", html)
        self.assertIn("<td>node1-node2</td>", html)
        self.assertEqual(len(ds.rows["instance"]), 3)
        dbc_rows = dbcmod.to_dbc_rows(inv)  # RAC: one row with the cluster totals
        self.assertEqual([(r["Source Host/Server Name"], r["Source Host vCPU"]) for r in dbc_rows], [("node1-node2", 16)])

    def test_trailing_spaces_numbers_and_error_lines(self):
        self.write("h_db_db_oracle_database_level_data.csv", DB_HDR + " " * 500 + "\n" +
                   "h.example.com,DB,DB,.16,.3,5,8,.124,.114,.4,1.318,0,7,0,0,12,1,0,N/A,7,.21,.068" + " " * 500 + "\n"
                   "ORA-00942: table or view does not exist\n")
        ds = proc.load_dataset([self.tmp])
        row = ds.rows["database"][0]
        self.assertEqual(row["RedoRate Maximum 50th Percentile (MB/s)"], ".068")
        self.assertTrue(any("ORA-00942" in w for w in ds.warnings))
        inv = proc.build_inventory(ds)
        self.assertEqual(inv[0]["DB CPU Average 99th Percentile"], 0.16)
        self.assertEqual(inv[0]["Collection Mode"], "Unknown")

    def test_repeated_runs_keep_peak_values(self):
        for run, cpu in (("run1", ".5"), ("run2", "2.5")):
            self.write(f"{run}/h_db_db_oracle_database_level_data.csv", DB_HDR + "\n" +
                       f"h,DB,DB,{cpu},1,5,8,.1,.1,.4,1,0,7,0,0,1,1,0,N/A,0,.2,.1\n")
            self.write(f"{run}/h_db_collection_info.csv",
                       "Server Name,CDB/DB Name,Collection Mode,Collection Time,Tool Version,Metrics Window Start,"
                       "Metrics Window End,Metrics Window (Hours),Snapshot Count,Snapshot Interval (Minutes),AWR Retention (Days)\n"
                       f'"h",DB,NOAWR,2026-01-0{run[-1]} 10:00:00 +00:00,1.0.0,,,1,,,\n')
        ds = proc.load_dataset([self.tmp])
        inv = proc.build_inventory(ds)
        self.assertEqual(len(inv), 1)
        self.assertEqual(inv[0]["DB CPU Average 99th Percentile"], 2.5)
        self.assertEqual(inv[0]["Collection Runs"], 2)


class OutputNameTests(TempDirTest):
    def test_reused_output_folder_is_not_overwritten(self):
        import datetime as dt
        self.assertEqual(proc.output_suffix(self.tmp), "")
        self.write("oracle_inventory_report.html", "old")
        now = dt.datetime(2026, 10, 27, 14, 29, 0)
        self.assertEqual(proc.output_suffix(self.tmp, now), "_20261027_142900")
        self.write("oracle_inventory_report_20261027_142900.html", "old")
        self.assertEqual(proc.output_suffix(self.tmp, now), "_20261027_142900_2")
        self.assertEqual(proc.with_suffix("mat_oracle_inventory.csv", "_x"), "mat_oracle_inventory_x.csv")

    def test_cli_second_run_keeps_first(self):
        import contextlib
        import oracle_collector
        out = self.tmp / "out"
        for _ in range(2):
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(oracle_collector.main(["process", "-i", str(SAMPLES), "-o", str(out), "--mat"]), 0)
        reports = sorted(p.name for p in out.glob("oracle_inventory_report*.html"))
        mats = sorted(p.name for p in out.glob("mat_oracle_inventory*.csv"))
        self.assertEqual(len(reports), 2)
        self.assertEqual(len(mats), 2)
        self.assertIn("oracle_inventory_report.html", reports)


class SizingTests(unittest.TestCase):
    BASE = {"Host vCPU Count": 16, "Host CPU Average 99th Percentile": 6, "Host CPU Maximum 90th Percentile": 8,
            "DB CPU Average 99th Percentile": 3, "DB CPU Maximum 90th Percentile": 5, "SGA+PGA Total (GB)": 40,
            "Host Total Memory (GB)": 128, "Storage Allocated (GB)": 1000, "Storage Used (GB)": 500,
            "DB IOPS Average 99th Percentile": 3000, "DB IOPS Maximum 50th Percentile": 5000,
            "DB Throughput Average 99th Percentile (MB/s)": 200, "DB Throughput Maximum 50th Percentile (MB/s)": 150,
            "RAC Cluster": "N", "Nodes": 1}

    def test_mat_formulas(self):
        z = report.sizing(dict(self.BASE))
        self.assertEqual((z["vcpu"], z["memory"], z["storage"], z["iops"], z["mbps"], z["storage_type"]),
                         (5, 40, 800, 5000, 200, "gp3"))

    def test_fallbacks_and_rac(self):
        rec = dict(self.BASE, **{"DB CPU Maximum 90th Percentile": 0, "SGA+PGA Total (GB)": 0, "Storage Used (GB)": 900})
        z = report.sizing(rec)
        self.assertEqual((z["vcpu"], z["memory"], z["storage"]), (12, 115.2, 900))
        # RAC: SGA / nodes x (1 + 0.2 x (nodes - 1)) + PGA
        z = report.sizing(dict(self.BASE, **{"RAC Cluster": "Y", "Nodes": 2, "SGA (GB)": 30, "PGA (GB)": 10}))
        self.assertEqual(z["memory"], 28)  # 30 / 2 x 1.2 + 10
        z = report.sizing(dict(self.BASE, **{"RAC Cluster": "Y", "Nodes": 4, "SGA (GB)": 80, "PGA (GB)": 20}))
        self.assertEqual(z["memory"], 52)  # 80 / 4 x 1.6 + 20
        # files without separate SGA / PGA columns: whole SGA+PGA treated as SGA
        z = report.sizing(dict(self.BASE, **{"RAC Cluster": "Y", "Nodes": 2}))
        self.assertEqual(z["memory"], 24)  # 40 / 2 x 1.2
        z = report.sizing(dict(self.BASE, **{"DB IOPS Maximum 50th Percentile": 70000,
                                              "DB Throughput Maximum 50th Percentile (MB/s)": 5000}))
        self.assertEqual(z["storage_type"], "io2")


class ConfigTests(TempDirTest):
    def test_sample_config_loads(self):
        targets = load_targets(ROOT / "config" / "databases.sample.ini")
        names = {t.name: t for t in targets}
        self.assertIn("sales-prod", names)
        self.assertEqual(names["sales-prod"].connect_string(), "dbhost01.example.com:1521/SALESPRD")
        self.assertEqual(names["reporting-se2"].collection_mode, MODE_NOAWR)
        self.assertEqual(names["erp-cdb"].collection_mode, MODE_AWR)
        self.assertNotIn("billing-se2-statspack", names)  # enabled = false
        self.assertEqual(names["hr-cdb"].pdbs, ["HRPDB1", "HRPDB2"])
        self.assertNotIn("legacy-11g", names)  # enabled = false

    def test_mode_override_and_sid(self):
        path = self.write("db.ini", "[a]\nhost=h\nsid=ORCL\nuser=u\n")
        t = load_targets(path, mode_override=MODE_NOAWR)[0]
        self.assertEqual(t.collection_mode, MODE_NOAWR)
        self.assertIn("(SID=ORCL)", t.connect_string())


if __name__ == "__main__":
    unittest.main()
