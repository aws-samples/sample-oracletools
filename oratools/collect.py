# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
"""Scenario 2: connect to Oracle with python-oracledb and run the collection scripts directly.

The same PL/SQL blocks used by the SQL*Plus scripts are executed here, so the CSV
files produced by both paths are identical and are processed the same way.
"""

import logging
import re
from pathlib import Path

from . import SUFFIX_DATABASE, SUFFIX_FEATURES, SUFFIX_INFO, SUFFIX_INSTANCE
from . import sqlscripts

log = logging.getLogger("oracletools")

# Oracle identifier as used for PDB names: letter first, then letters, digits, _ $ # (max 128 bytes)
_IDENTIFIER = re.compile(r"[A-Za-z][A-Za-z0-9_$#]{0,127}")

DBMS_OUTPUT_CHUNK = 200
DBMS_OUTPUT_LINE_SIZE = 32767


def _import_oracledb():
    try:
        import oracledb  # noqa: WPS433 (optional dependency, only needed for 'collect')
    except ImportError as exc:  # pragma: no cover - depends on environment
        raise SystemExit(
            "python-oracledb is required for the 'collect' command:\n"
            "    python3 -m pip install -r requirements.txt -c constraints.txt\n"
            "(The 'process' command does not need it.)"
        ) from exc
    return oracledb


_thick_initialised = False


def _init_thick(oracledb, lib_dir):
    global _thick_initialised
    if not _thick_initialised:
        kwargs = {"lib_dir": lib_dir} if lib_dir else {}
        oracledb.init_oracle_client(**kwargs)
        _thick_initialised = True


def connect(target):
    oracledb = _import_oracledb()
    if target.thick_mode:
        _init_thick(oracledb, target.oracle_client_lib_dir)

    params = {"dsn": target.connect_string()}
    if target.auth_mode == "sysdba":
        params["mode"] = oracledb.AUTH_MODE_SYSDBA
    elif target.auth_mode == "sysoper":
        params["mode"] = oracledb.AUTH_MODE_SYSOPER
    if target.config_dir:
        params["config_dir"] = target.config_dir
    if target.wallet_location:
        params["wallet_location"] = target.wallet_location
        if target.wallet_password_env:
            import os
            params["wallet_password"] = os.environ.get(target.wallet_password_env)
    if target.external_auth:
        params["externalauth"] = True
    else:
        params["user"] = target.user
        params["password"] = target.resolve_password()
    return oracledb.connect(**params)


def run_block(cursor, plsql):
    """Execute an anonymous PL/SQL block and return everything it printed with DBMS_OUTPUT."""
    # DBMS_OUTPUT state is per container, so enable it every time (also after ALTER SESSION SET CONTAINER)
    cursor.execute("BEGIN DBMS_OUTPUT.ENABLE(NULL); END;")
    cursor.execute(plsql)
    lines_var = cursor.arrayvar(str, DBMS_OUTPUT_CHUNK, DBMS_OUTPUT_LINE_SIZE)
    count_var = cursor.var(int)
    output = []
    while True:
        count_var.setvalue(0, DBMS_OUTPUT_CHUNK)
        cursor.callproc("DBMS_OUTPUT.GET_LINES", (lines_var, count_var))
        count = count_var.getvalue()
        output.extend((line or "") for line in lines_var.getvalue()[:count])
        if count < DBMS_OUTPUT_CHUNK:
            break
    return [line.rstrip() for line in output if line and line.strip()]


def _write_csv(path, header, rows):
    with open(path, "w", encoding="utf-8", newline="") as fh:
        fh.write(header + "\n")
        for row in rows:
            fh.write(row + "\n")
    log.info("    wrote %s (%d row%s)", path.name, len(rows), "" if len(rows) == 1 else "s")


def _run_to_file(cursor, kind, mode, path, errors, label):
    script = sqlscripts.load(kind, mode)
    try:
        rows = run_block(cursor, script.plsql)
    except Exception as exc:  # oracledb.Error and anything unexpected; keep collecting
        msg = f"{label}: {script.name} failed: {exc}"
        log.error("    %s", msg)
        errors.append(msg)
        return None
    _write_csv(path, script.header, rows)
    return path


def _session_info(cursor):
    cursor.execute("SELECT LOWER(SYS_CONTEXT('USERENV','SERVER_HOST')), NAME, "
                   "TO_NUMBER(REGEXP_SUBSTR((SELECT VERSION FROM V$INSTANCE), '[0-9]+')) FROM V$DATABASE")
    host, db_name, version = cursor.fetchone()
    is_cdb, con_id, con_name = "NO", 0, db_name
    if version >= 12:
        cursor.execute("SELECT CDB, SYS_CONTEXT('USERENV','CON_ID'), SYS_CONTEXT('USERENV','CON_NAME') FROM V$DATABASE")
        is_cdb, con_id, con_name = cursor.fetchone()
        con_id = int(con_id)
    return host, db_name, version, is_cdb, con_id, con_name


def _switch_container_sql(name):
    """ALTER SESSION SET CONTAINER for a PDB name read from V$PDBS.

    DDL cannot use bind variables, so the name is validated as an Oracle identifier and quoted.
    """
    if not _IDENTIFIER.fullmatch(name or ""):
        raise ValueError(f"unexpected PDB name {name!r}")
    return f'ALTER SESSION SET CONTAINER = "{name}"'


def _container_prefix(cursor, host, db_name):
    con_name = db_name
    try:
        cursor.execute("SELECT SYS_CONTEXT('USERENV','CON_NAME') FROM DUAL")
        con_name = cursor.fetchone()[0] or db_name
    except Exception as exc:  # 11g has no CON_NAME
        log.debug("    CON_NAME not available (%s); using the database name", exc)
    con = con_name.replace("CDB$ROOT", "CDB").replace("$", "_").lower()
    return f"{host}_{db_name.lower()}_{con}"


def _collect_container(cursor, mode, host, db_name, out_dir, errors, label):
    cursor.execute("ALTER SESSION SET NLS_NUMERIC_CHARACTERS = '.,'")
    prefix = _container_prefix(cursor, host, db_name)
    _run_to_file(cursor, "database", mode, out_dir / f"{prefix}{SUFFIX_DATABASE}", errors, label)
    _run_to_file(cursor, "features", mode, out_dir / f"{prefix}{SUFFIX_FEATURES}", errors, label)


def collect_target(target, out_dir):
    """Collect one configured database. Returns a list of error messages (empty on success)."""
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    mode = target.collection_mode
    errors = []
    if (target.user or "").upper() in ("SYS", "SYSTEM") or target.auth_mode in ("sysdba", "sysoper"):
        log.warning("[%s] connecting as %s%s: a dedicated read-only user is recommended "
                    "(see docs/prerequisites.md)", target.name, target.user,
                    f" AS {target.auth_mode.upper()}" if target.auth_mode != "normal" else "")
    log.info("[%s] connecting to %s (mode %s)", target.name, target.connect_string(), mode)
    try:
        conn = connect(target)
    except Exception as exc:
        msg = f"{target.name}: connection failed: {exc}"
        log.error("    %s", msg)
        return [msg]

    try:
        cursor = conn.cursor()
        cursor.execute("ALTER SESSION SET NLS_NUMERIC_CHARACTERS = '.,'")
        host, db_name, version, is_cdb, con_id, con_name = _session_info(cursor)
        log.info("    connected: server=%s db=%s version=%s cdb=%s container=%s", host, db_name, version, is_cdb, con_name)
        base = f"{host}_{db_name.lower()}"

        _run_to_file(cursor, "info", mode, out_dir / f"{base}{SUFFIX_INFO}", errors, target.name)
        _run_to_file(cursor, "instance", mode, out_dir / f"{base}{SUFFIX_INSTANCE}", errors, target.name)
        _collect_container(cursor, mode, host, db_name, out_dir, errors, target.name)

        if version >= 12 and is_cdb == "YES" and con_id == 1:
            cursor.execute("SELECT NAME FROM V$PDBS WHERE NAME <> 'PDB$SEED' AND OPEN_MODE LIKE 'READ%' ORDER BY CON_ID")
            pdbs = [r[0] for r in cursor.fetchall()]
            if target.pdbs:
                missing = sorted(set(target.pdbs) - set(pdbs))
                if missing:
                    msg = f"{target.name}: PDB(s) not found or not open: {', '.join(missing)}"
                    log.warning("    %s", msg)
                    errors.append(msg)
                pdbs = [p for p in pdbs if p in target.pdbs]
            for pdb in pdbs:
                log.info("    PDB %s", pdb)
                try:
                    # validated identifier from V$PDBS; DDL cannot be parameterised
                    cursor.execute(_switch_container_sql(pdb))  # nosemgrep
                except Exception as exc:
                    msg = (f"{target.name}: cannot switch to PDB {pdb} ({exc}). "
                           "Use a common user with SET CONTAINER privilege, or add the PDB as its own entry.")
                    log.error("    %s", msg)
                    errors.append(msg)
                    continue
                _collect_container(cursor, mode, host, db_name, out_dir, errors, target.name)
            if pdbs:
                cursor.execute("ALTER SESSION SET CONTAINER = CDB$ROOT")
    except Exception as exc:
        msg = f"{target.name}: collection failed: {exc}"
        log.error("    %s", msg)
        errors.append(msg)
    finally:
        try:
            conn.close()
        except Exception as exc:
            log.debug("    closing the connection failed: %s", exc)
    return errors


def collect_all(targets, out_dir):
    all_errors = []
    for target in targets:
        all_errors.extend(collect_target(target, out_dir))
    return all_errors
