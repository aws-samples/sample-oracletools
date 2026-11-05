# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
"""Reads the database connection configuration file (INI format).

See ``config/databases.sample.ini`` for a documented example.
"""

import configparser
import getpass
import os
from dataclasses import dataclass, field
from typing import List, Optional

from . import MODE_AWR, MODE_NOAWR, MODE_STATSPACK

TRUE_VALUES = {"1", "true", "yes", "y", "on"}


def _bool(value, default=False):
    if value is None or str(value).strip() == "":
        return default
    return str(value).strip().lower() in TRUE_VALUES


def normalise_mode(value, default=MODE_AWR):
    if value is None or str(value).strip() == "":
        return default
    v = str(value).strip().upper().replace("-", "").replace("_", "")
    if v == "AWR":
        return MODE_AWR
    if v in ("NOAWR", "NONAWR"):
        return MODE_NOAWR
    if v in ("STATSPACK", "SP"):
        return MODE_STATSPACK
    raise ValueError(f"collection_mode must be 'awr', 'noawr' or 'statspack', got '{value}'")


@dataclass
class Target:
    name: str
    host: Optional[str] = None
    port: int = 1521
    service_name: Optional[str] = None
    sid: Optional[str] = None
    dsn: Optional[str] = None
    user: Optional[str] = None
    password: Optional[str] = field(default=None, repr=False)
    password_env: Optional[str] = None
    auth_mode: str = "normal"
    external_auth: bool = False
    collection_mode: str = MODE_AWR
    pdbs: List[str] = field(default_factory=list)  # empty = all open PDBs
    thick_mode: bool = False
    oracle_client_lib_dir: Optional[str] = None
    config_dir: Optional[str] = None
    wallet_location: Optional[str] = None
    wallet_password_env: Optional[str] = None
    enabled: bool = True

    def connect_string(self):
        if self.dsn:
            return self.dsn
        if not self.host:
            raise ValueError(f"[{self.name}] set either 'dsn' or 'host' (+ 'service_name' or 'sid')")
        if self.service_name:
            return f"{self.host}:{self.port}/{self.service_name}"
        if self.sid:
            # Easy Connect has no SID syntax, so use a full connect descriptor
            return (f"(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST={self.host})(PORT={self.port}))"
                    f"(CONNECT_DATA=(SID={self.sid})))")
        raise ValueError(f"[{self.name}] set 'service_name' or 'sid'")

    def resolve_password(self):
        """Password lookup order: password_env, password, interactive prompt."""
        if self.external_auth:
            return None
        if self.password_env:
            value = os.environ.get(self.password_env)
            if value:
                return value
        if self.password:
            return self.password
        return getpass.getpass(f"Password for {self.user}@{self.name}: ")


def load_targets(path, mode_override=None, only=None):
    parser = configparser.ConfigParser(interpolation=None)
    with open(path, encoding="utf-8") as fh:
        parser.read_file(fh)

    targets = []
    for section in parser.sections():
        if only and section not in only:
            continue
        s = parser[section]
        pdbs_raw = (s.get("pdbs") or "").strip()
        pdbs = [] if pdbs_raw.lower() in ("", "all") else [p.strip().upper() for p in pdbs_raw.split(",") if p.strip()]
        t = Target(
            name=section,
            host=s.get("host") or None,
            port=int(s.get("port") or 1521),
            service_name=s.get("service_name") or None,
            sid=s.get("sid") or None,
            dsn=s.get("dsn") or None,
            user=s.get("user") or None,
            password=s.get("password") or None,
            password_env=s.get("password_env") or None,
            auth_mode=(s.get("auth_mode") or "normal").strip().lower(),
            external_auth=_bool(s.get("external_auth")),
            collection_mode=mode_override or normalise_mode(s.get("collection_mode")),
            pdbs=pdbs,
            thick_mode=_bool(s.get("thick_mode")),
            oracle_client_lib_dir=s.get("oracle_client_lib_dir") or None,
            config_dir=s.get("config_dir") or None,
            wallet_location=s.get("wallet_location") or None,
            wallet_password_env=s.get("wallet_password_env") or None,
            enabled=_bool(s.get("enabled"), default=True),
        )
        if t.auth_mode not in ("normal", "sysdba", "sysoper"):
            raise ValueError(f"[{section}] auth_mode must be normal, sysdba or sysoper")
        if not t.external_auth and not t.user:
            raise ValueError(f"[{section}] 'user' is required unless external_auth = true")
        if t.external_auth:
            t.thick_mode = True  # external authentication needs Oracle Client libraries
        t.connect_string()  # validate early
        if t.enabled:
            targets.append(t)
    if only:
        missing = set(only) - {t.name for t in targets}
        if missing:
            raise ValueError(f"Database(s) not found or disabled in {path}: {', '.join(sorted(missing))}")
    return targets
