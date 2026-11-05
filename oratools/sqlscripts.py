# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
"""Loads the SQL*Plus collection scripts so the Python collector runs exactly the same SQL.

Every collection script under ``sql/`` has the same shape::

    -- comments
    PROMPT <csv header>
    DECLARE ... END;
    /

The PROMPT line is the CSV header and the anonymous PL/SQL block prints one CSV
row per ``DBMS_OUTPUT.PUT_LINE``. SQL*Plus substitution variables used inside
the block (``&&collection_mode``, ``&&tool_version``) are replaced here.
"""

import re
from pathlib import Path

from . import MODE_AWR, MODE_NOAWR, MODE_STATSPACK, __version__

SQL_DIR = Path(__file__).resolve().parent.parent / "sql"

SCRIPTS = {
    "info": "common/collection_info.sql",
    "instance": "{mode_dir}/instance_level.sql",
    "database": "{mode_dir}/database_level.sql",
    "features": "common/database_features.sql",
}


class SqlScript:
    def __init__(self, name, header, plsql):
        self.name = name
        self.header = header
        self.plsql = plsql


def mode_dir(mode):
    if mode == MODE_AWR:
        return "awr"
    if mode == MODE_NOAWR:
        return "noawr"
    if mode == MODE_STATSPACK:
        return "statspack"
    raise ValueError(f"Unknown collection mode: {mode}")


def parse_script(text, name="<script>"):
    """Split a collection script into its CSV header and PL/SQL block."""
    header = None
    lines = text.splitlines()
    start = end = None
    for i, line in enumerate(lines):
        stripped = line.strip()
        if header is None and stripped.upper().startswith("PROMPT "):
            header = stripped[len("PROMPT "):].strip()
        elif start is None and re.match(r"^DECLARE\b", stripped, re.IGNORECASE):
            start = i
        elif start is not None and stripped == "/":
            end = i
            break
    if header is None or start is None or end is None:
        raise ValueError(f"{name}: expected a 'PROMPT <header>' line and a DECLARE ... / block")
    # python-oracledb needs the block without the SQL*Plus terminator, ending with 'END;'
    plsql = "\n".join(lines[start:end]).rstrip()
    return header, plsql


def load(kind, mode):
    rel = SCRIPTS[kind].format(mode_dir=mode_dir(mode))
    path = SQL_DIR / rel
    header, plsql = parse_script(path.read_text(encoding="utf-8"), rel)
    plsql = plsql.replace("&&collection_mode", mode).replace("&&tool_version", __version__)
    leftover = re.findall(r"&&?\w+", plsql)
    if leftover:
        raise ValueError(f"{rel}: unresolved substitution variables {sorted(set(leftover))}")
    return SqlScript(rel, header, plsql)
