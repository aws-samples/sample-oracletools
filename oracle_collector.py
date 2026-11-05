#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
"""oracletools - Oracle inventory and performance data collection for AWS rightsizing.

  collect  Connect with python-oracledb, run the collection scripts, then process the results.
  process  Process CSV files collected with SQL*Plus (sql/collect_awr.sql, collect_noawr.sql or collect_statspack.sql).

Examples:
  python3 oracle_collector.py collect --config config/databases.ini
  python3 oracle_collector.py collect --config config/databases.ini --mode noawr --mat --region ap-southeast-2
  python3 oracle_collector.py process --input sql/output --mat
"""

import argparse
import datetime as dt
import logging
import sys
from pathlib import Path

from oratools import MODE_AWR, __version__
from oratools import config as cfg
from oratools import process as proc
from oratools import report

log = logging.getLogger("oracletools")

LICENCE_NOTE = ("AWR mode (the default) reads DBA_HIST_* views, which requires an Oracle Diagnostics Pack licence. "
                "It is the customer's responsibility to ensure the databases are licensed; otherwise use --mode statspack "
                "(STATSPACK installed) or --mode noawr.")


def _setup_logging(out_dir, verbose):
    out_dir.mkdir(parents=True, exist_ok=True)
    fmt = logging.Formatter("%(asctime)s %(levelname)-7s %(message)s", "%H:%M:%S")
    log.setLevel(logging.DEBUG)
    console = logging.StreamHandler(sys.stdout)
    console.setLevel(logging.DEBUG if verbose else logging.INFO)
    console.setFormatter(fmt)
    logfile = logging.FileHandler(out_dir / "oracletools.log", encoding="utf-8")
    logfile.setLevel(logging.DEBUG)
    logfile.setFormatter(fmt)
    log.handlers[:] = [console, logfile]


def _default_out():
    return Path(f"oracletools_output_{dt.datetime.now():%Y%m%d_%H%M%S}")


def run_process(input_dirs, out_dir, mat=False, region=None, skip_cdb_root=False, environment=None, dbc=None):
    dataset = proc.load_dataset(input_dirs)
    inventory = proc.build_inventory(dataset)
    suffix = proc.output_suffix(out_dir)
    if suffix:
        log.warning("%s already contains outputs of an earlier run; new files are written with the suffix %s "
                    "(nothing is overwritten)", out_dir, suffix)
    files = proc.write_consolidated(dataset, out_dir, suffix)

    inv_path = out_dir / proc.with_suffix("oracle_inventory.csv", suffix)
    proc.write_rows(inv_path, proc.INVENTORY_COLUMNS, inventory)
    files.append(inv_path)

    summary = report.summarise(inventory, dataset)
    html_path = out_dir / proc.with_suffix("oracle_inventory_report.html", suffix)
    html_path.write_text(report.render_html(inventory, dataset, summary, dataset.rows["instance"]), encoding="utf-8")
    files.append(html_path)

    if mat:
        from oratools import mat as matmod
        mat_path, _ = matmod.write_mat(inventory, out_dir, region=region, skip_cdb_root=skip_cdb_root,
                                       filename=proc.with_suffix("mat_oracle_inventory.csv", suffix),
                                       environment=environment)
        files.append(mat_path)
        log.info("MAT file: questionnaire columns are left blank (Environment = %s); complete them in the CSV or in MAT.",
                 environment or matmod.DEFAULT_ENVIRONMENT)
        if not environment:
            log.info("Environment defaults to '%s' for every row; use --environment prod for production databases.",
                     matmod.DEFAULT_ENVIRONMENT)
        if not region:
            log.warning("targetAWSRegion is blank: MAT requires it. Use --region (e.g. --region ap-southeast-2) "
                        "or fill it in before importing.")

    if dbc:
        from oratools import dbc as dbcmod
        dbc_path, _ = dbcmod.write_dbc(inventory, out_dir, location=dbc, region=region,
                                       filename=proc.with_suffix("dbc_cmdb_inventory.csv", suffix))
        files.append(dbc_path)
        if dbc == "ec2":
            if not region:
                log.warning("DBC file: Source EC2 Region is blank (required for EC2 sources); use --region.")
            log.info("DBC file: Source EC2 OS is set to %s; change it in the CSV for other operating systems.",
                     dbcmod.EC2_DEFAULT_OS)

    print(report.render_text(summary))
    print("\nOutput files:")
    for f in files:
        print(f"  {f}")
    return inventory


def cmd_collect(args):
    out_dir = Path(args.output) if args.output else _default_out()
    _setup_logging(out_dir, args.verbose)
    mode = cfg.normalise_mode(args.mode) if args.mode else None
    targets = cfg.load_targets(args.config, mode_override=mode, only=args.database)
    if not targets:
        log.error("No enabled database in %s", args.config)
        return 2
    if any(t.collection_mode == MODE_AWR for t in targets):
        log.warning(LICENCE_NOTE)

    from oratools import collect
    raw_dir = out_dir / "raw"
    errors = collect.collect_all(targets, raw_dir)
    if errors:
        log.warning("%d problem(s) during collection; see %s", len(errors), out_dir / "oracletools.log")
    if args.no_process:
        log.info("Raw CSV files are in %s", raw_dir)
        return 1 if errors else 0
    try:
        run_process([raw_dir], out_dir, mat=args.mat, region=args.region, skip_cdb_root=args.mat_skip_cdb_root,
                    environment=args.environment, dbc=args.dbc)
    except SystemExit as exc:
        log.error(str(exc))
        return 2
    return 1 if errors else 0


def cmd_process(args):
    out_dir = Path(args.output) if args.output else _default_out()
    _setup_logging(out_dir, args.verbose)
    run_process(args.input, out_dir, mat=args.mat, region=args.region, skip_cdb_root=args.mat_skip_cdb_root,
                environment=args.environment, dbc=args.dbc)
    return 0


def build_parser():
    parser = argparse.ArgumentParser(
        prog="oracle_collector.py",
        description="Oracle inventory and performance data collection for AWS rightsizing.",
        epilog=LICENCE_NOTE,
    )
    parser.add_argument("--version", action="version", version=f"oracletools {__version__}")
    sub = parser.add_subparsers(dest="command", required=True)

    def common(p):
        p.add_argument("--output", "-o", help="output directory (default: ./oracletools_output_<timestamp>)")
        p.add_argument("--mat", action="store_true",
                       help="also write mat_oracle_inventory.csv in the MAT Oracle inventory template layout")
        p.add_argument("--region", help="with --mat: value for targetAWSRegion (e.g. ap-southeast-2), required by MAT; "
                                        "with --dbc ec2: the region of the source EC2 instances")
        p.add_argument("--environment", choices=["prod", "non-prod"],
                       help="with --mat: value for Environment on every row (default: non-prod)")
        p.add_argument("--mat-skip-cdb-root", action="store_true",
                       help="with --mat: do not write CDB$ROOT rows (keep non-CDBs and PDBs only)")
        p.add_argument("--dbc", nargs="?", const="on-premises", choices=["on-premises", "ec2"],
                       help="also write dbc_cmdb_inventory.csv, the CMDB input file of the AWS Directional Business Case (DBC) tool; "
                            "value: source location of the databases (default: on-premises)")
        p.add_argument("--verbose", "-v", action="store_true", help="debug logging")

    c = sub.add_parser("collect", help="connect with python-oracledb, collect and process (scenario 2)")
    c.add_argument("--config", "-c", required=True, help="connection file, see config/databases.sample.ini")
    c.add_argument("--mode", choices=["awr", "noawr", "statspack"],
                   help="override collection_mode of every database (default: per database, AWR if not set)")
    c.add_argument("--database", "-d", action="append",
                   help="only collect this section of the config file (repeatable)")
    c.add_argument("--no-process", action="store_true", help="only collect the raw CSV files")
    common(c)
    c.set_defaults(func=cmd_collect)

    p = sub.add_parser("process", help="process CSV files collected with SQL*Plus (scenario 1)")
    p.add_argument("--input", "-i", required=True, action="append",
                   help="folder (searched recursively) or CSV file; repeat to combine several runs")
    common(p)
    p.set_defaults(func=cmd_process)
    return parser


def main(argv=None):
    args = build_parser().parse_args(argv)
    if args.environment and not args.mat:
        print("--environment is only used together with --mat", file=sys.stderr)
    if args.region and not (args.mat or args.dbc == "ec2"):
        print("--region is only used together with --mat or --dbc ec2", file=sys.stderr)
    try:
        return args.func(args)
    except (ValueError, FileNotFoundError) as exc:
        log.error(str(exc)) if log.handlers else print(f"ERROR: {exc}", file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        print("\nInterrupted.", file=sys.stderr)
        return 130


if __name__ == "__main__":
    sys.exit(main())
