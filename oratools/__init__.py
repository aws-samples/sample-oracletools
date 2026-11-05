# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
"""oracletools - Oracle inventory and performance data collector for AWS rightsizing."""

__version__ = "1.1.0"

# Output file suffixes shared by the SQL*Plus scripts and the Python collector.
SUFFIX_INFO = "_collection_info.csv"
SUFFIX_INSTANCE = "_oracle_instance_level_data.csv"
SUFFIX_DATABASE = "_oracle_database_level_data.csv"
SUFFIX_FEATURES = "_oracle_database_features.csv"

MODE_AWR = "AWR"
MODE_NOAWR = "NOAWR"
MODE_STATSPACK = "STATSPACK"
MODES = (MODE_AWR, MODE_NOAWR, MODE_STATSPACK)
