#!/usr/bin/env python3
"""Advance both app versions through the shared XcodeGen configuration."""
import argparse
from pathlib import Path
import re

parser = argparse.ArgumentParser()
parser.add_argument("version", nargs="?", help="New x.y.z; defaults to next patch")
args = parser.parse_args()
path = Path(__file__).resolve().parents[1] / "shared/version.yml"
text = path.read_text()
old = re.search(r"MARKETING_VERSION: '([0-9.]+)'", text).group(1)
build = int(re.search(r"CURRENT_PROJECT_VERSION: '(\d+)'", text).group(1))
parts = tuple(map(int, old.split(".")))
version = args.version or f"{parts[0]}.{parts[1]}.{parts[2] + 1}"
if not re.fullmatch(r"(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)", version):
    parser.error("version must be x.y.z")
if tuple(map(int, version.split("."))) <= parts:
    parser.error("new version must be greater than the current version")
text = text.replace(f"MARKETING_VERSION: '{old}'", f"MARKETING_VERSION: '{version}'")
text = text.replace(f"CURRENT_PROJECT_VERSION: '{build}'", f"CURRENT_PROJECT_VERSION: '{build + 1}'")
path.write_text(text)
print(f"Both platforms: {old} ({build}) -> {version} ({build + 1})")
