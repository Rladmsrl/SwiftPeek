#!/usr/bin/env python3
"""Fail closed on common private build artifacts; never print matching values."""
import argparse
from pathlib import Path
import plistlib
import re
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument("app", type=Path)
parser.add_argument("--version", required=True)
parser.add_argument("--build", required=True)
args = parser.parse_args()
app = args.app
info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
failures = []
if info.get("CFBundleShortVersionString") != args.version or info.get("CFBundleVersion") != args.build:
    failures.append("bundle version mismatch")
patterns = {
    "local home path": rb"/(?:Users|home)/[A-Za-z0-9_.-]+/",
    "private key": rb"BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY",
    "GitHub credential": rb"gh[pousr]_[A-Za-z0-9]{30,}",
    "API credential": rb"sk-(?:proj-)?[A-Za-z0-9_-]{32,}",
}
for path in app.rglob("*"):
    if path.is_symlink():
        failures.append("unexpected symlink")
        continue
    if not path.is_file():
        continue
    if path.suffix in {".mobileprovision", ".provisionprofile", ".p12", ".p8", ".pem", ".key", ".log", ".jsonl", ".xcconfig", ".simplelivefollows"} or path.name in {"follows.json", "history.json"}:
        failures.append("private resource type")
    data = path.read_bytes()
    for label, pattern in patterns.items():
        if re.search(pattern, data):
            failures.append(label)
for name in ["LICENSE", "THIRD_PARTY_NOTICES.md", "crypto-js.LICENSE", "PRIVACY.md"]:
    if not list(app.rglob(name)):
        failures.append("missing license or privacy resource")
exe = app / "Contents/MacOS" / info["CFBundleExecutable"]
architectures = subprocess.check_output(["lipo", "-archs", str(exe)], text=True).strip().split()
if set(architectures) != {"arm64", "x86_64"}:
    failures.append("expected both arm64 and x86_64")
signature = subprocess.run(["codesign", "-dvv", str(app)], capture_output=True, text=True)
details = signature.stdout + signature.stderr
if "Signature=adhoc" not in details or "Authority=" in details or re.search(r"TeamIdentifier=(?!not set)[^\n]+", details):
    failures.append("unexpected identifying signature")
verify = subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], capture_output=True)
if verify.returncode:
    failures.append("invalid code signature")
if failures:
    raise SystemExit("FAIL: " + "; ".join(sorted(set(failures))))
print(f"PASS: {args.version} ({args.build}); arm64 + x86_64; ad-hoc signature; no scanned private artifacts; licenses included")
