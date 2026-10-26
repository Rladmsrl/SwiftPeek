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
parser.add_argument("--minimum-system", default="26.0")
parser.add_argument("--platform", choices=["macos", "ios"], default="macos")
args = parser.parse_args()
app = args.app
ios = args.platform == "ios"
info = plistlib.loads((app / ("Info.plist" if ios else "Contents/Info.plist")).read_bytes())
failures = []
if info.get("CFBundleShortVersionString") != args.version or info.get("CFBundleVersion") != args.build:
    failures.append("bundle version mismatch")
if info.get("MinimumOSVersion" if ios else "LSMinimumSystemVersion") != args.minimum_system:
    failures.append("minimum system mismatch")
if ios and info.get("CFBundleSupportedPlatforms") != ["iPhoneOS"]:
    failures.append("expected physical iOS device build")
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
    if ios and path.name == "_CodeSignature":
        failures.append("unexpected iOS signature directory")
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
exe = app / ("" if ios else "Contents/MacOS") / info["CFBundleExecutable"]
architectures = subprocess.check_output(["lipo", "-archs", str(exe)], text=True).strip().split()
expected_architectures = {"arm64"} if ios else {"arm64", "x86_64"}
if set(architectures) != expected_architectures:
    failures.append("architecture mismatch")
load_commands = subprocess.check_output(["otool", "-l", str(exe)], text=True)
minimums = re.findall(r"\bminos\s+([0-9.]+)", load_commands)
if len(minimums) != len(expected_architectures) or any(value != args.minimum_system for value in minimums):
    failures.append("architecture deployment target mismatch")
signature = subprocess.run(["codesign", "-dvv", str(app)], capture_output=True, text=True)
details = signature.stdout + signature.stderr
if ios:
    if signature.returncode == 0 or "code object is not signed at all" not in details:
        failures.append("expected unsigned iOS app")
else:
    if "Signature=adhoc" not in details or "Authority=" in details or re.search(r"TeamIdentifier=(?!not set)[^\n]+", details):
        failures.append("unexpected identifying signature")
    verify = subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], capture_output=True)
    if verify.returncode:
        failures.append("invalid code signature")
if failures:
    raise SystemExit("FAIL: " + "; ".join(sorted(set(failures))))
platform = "iOS" if ios else "macOS"
signing = "unsigned" if ios else "ad-hoc signature"
print(f"PASS: {args.version} ({args.build}); {platform} {args.minimum_system}+; {' + '.join(sorted(expected_architectures))}; {signing}; no scanned private artifacts; licenses included")
