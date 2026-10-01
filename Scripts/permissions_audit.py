#!/usr/bin/env python3
"""Issue #6 audit: permissions, entitlements, device family and offline independence.

A pure-function auditor over the repository tree so the exact rules are
unit-testable on Linux and enforced inside the pinned macOS CI lane. This is
static evidence: it proves the *source/build-configuration* posture (no
entitlements, iPhone-only family, no permissioned or network APIs), never a
signed archive or a runtime permission sheet. Real-device checks stay separate
gates in docs/issue-5-6-evidence.md.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

# APIs that would require a user-facing permission we deliberately do not
# request. MVP promises: no camera, microphone, location, contacts, calendar,
# notifications, or broad photo-library access.
FORBIDDEN_PERMISSION_APIS = {
    "CLLocationManager": "location access",
    "CNContactStore": "contacts access",
    "AVCaptureDevice": "camera/microphone capture",
    "AVAudioRecorder": "microphone recording",
    "EKEventStore": "calendar access",
    "PHPhotoLibrary.requestAuthorization": "broad photo library access",
    "UNUserNotificationCenter": "notification permission",
    "requestTrackingAuthorization": "app tracking permission",
}

# Anything that could make the app network-dependent (MVP: no runtime network
# features, PLAN: "Test network independence").
FORBIDDEN_NETWORK_APIS = {
    "URLSession": "networking via URLSession",
    "NWConnection": "Network.framework connection",
    "NWListener": "Network.framework listener",
    "NWConnectionGroup": "Network.framework group",
    "CFNetwork": "CFNetworking",
    "WCSession": "watchOS connectivity",
    "MultipeerConnectivity": "peer-to-peer networking",
    "CloudKit": "CloudKit sync",
    "MKMapView": "map networking",
}

# Usage-description keys would signal an intended permission prompt. The MVP
# requests none (PhotosPicker needs no library usage string), so none may be
# declared in the generated Info.plist settings.
PERMISSION_USAGE_KEY = re.compile(r"NS[A-Za-z]*UsageDescription")

ENTITLEMENT_FILE = re.compile(r"\.entitlements$")
DEVICE_FAMILY_ASSIGN = re.compile(r"TARGETED_DEVICE_FAMILY\s*=\s*([^;]+);")
ENTITLEMENTS_SETTING = re.compile(r"CODE_SIGN_ENTITLEMENTS\s*=")
# Any TARGETED_DEVICE_FAMILY value other than a bare "1" (e.g. "1,2") would
# silently enable native iPad support.
ALLOWED_DEVICE_FAMILY_VALUES = {"1"}

SCAN_ROOTS = ("App", "Packages")
PROJECT_FILE = "SplitSlip.xcodeproj/project.pbxproj"


def _swift_sources(repo_root: Path):
    for root in SCAN_ROOTS:
        base = repo_root / root
        if not base.is_dir():
            continue
        for path in sorted(base.rglob("*.swift")):
            if "Tests" in path.parts:
                continue  # test code may simulate hostile/network inputs
            yield path


def audit_tree(repo_root: Path) -> list[str]:
    """Return a list of human-readable violations; empty means the audit passed."""
    violations: list[str] = []

    # 1. No custom entitlements anywhere (no CloudKit, app groups, keychain
    #    sharing, associated domains, push).
    for path in repo_root.rglob("*"):
        if path.is_file() and ENTITLEMENT_FILE.search(path.name):
            violations.append(f"{path.relative_to(repo_root)}: custom entitlements file exists")
    project = repo_root / PROJECT_FILE
    if not project.is_file():
        violations.append(f"{PROJECT_FILE} is missing")
        return violations
    project_text = project.read_text(encoding="utf-8")
    if ENTITLEMENTS_SETTING.search(project_text):
        violations.append(f"{PROJECT_FILE}: CODE_SIGN_ENTITLEMENTS is set")

    # 2. iPhone-only device family in EVERY configuration that declares one.
    families = set(DEVICE_FAMILY_ASSIGN.findall(project_text))
    if not families:
        violations.append(f"{PROJECT_FILE}: no TARGETED_DEVICE_FAMILY declarations found")
    for value in sorted(families):
        if value.strip() not in ALLOWED_DEVICE_FAMILY_VALUES:
            violations.append(
                f"{PROJECT_FILE}: TARGETED_DEVICE_FAMILY = {value.strip()} (must be exactly 1)"
            )

    # 3. No permission usage descriptions in generated Info.plist settings.
    for match in set(PERMISSION_USAGE_KEY.findall(project_text)):
        violations.append(f"{PROJECT_FILE}: permission usage key declared: {match}")

    # 4. No permissioned or network APIs in shipped Swift sources.
    for path in _swift_sources(repo_root):
        text = path.read_text(encoding="utf-8")
        rel = path.relative_to(repo_root)
        for token, reason in FORBIDDEN_PERMISSION_APIS.items():
            if token in text:
                violations.append(f"{rel}: forbidden permission API {token} ({reason})")
        for token, reason in FORBIDDEN_NETWORK_APIS.items():
            if token in text:
                violations.append(f"{rel}: forbidden network API {token} ({reason})")

    # 5. Photo access must stay picker-scoped: PhotosUI may be imported for
    #    PhotosPicker, but never the raw library mutation/authorization surface.
    for path in _swift_sources(repo_root):
        text = path.read_text(encoding="utf-8")
        rel = path.relative_to(repo_root)
        if re.search(r"import\s+Photos\b", text):
            violations.append(f"{rel}: imports Photos framework (use PhotosPicker only)")

    return violations


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=".", help="repository root (default: .)")
    parser.add_argument("--report", default="", help="optional path to write the audit log")
    args = parser.parse_args(argv)

    violations = audit_tree(Path(args.root))
    lines = ["Split Slip permissions/offline audit"]
    if violations:
        lines.extend(f"VIOLATION: {v}" for v in violations)
    else:
        lines.append(
            "PASS: no entitlements, no permission usage keys, TARGETED_DEVICE_FAMILY=1 "
            "in all configurations, no permissioned or network APIs in shipped sources"
        )
    report = "\n".join(lines) + "\n"
    if args.report:
        Path(args.report).write_text(report, encoding="utf-8")
    sys.stdout.write(report)
    return 1 if violations else 0


if __name__ == "__main__":
    raise SystemExit(main())
