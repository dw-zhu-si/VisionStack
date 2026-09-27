#!/usr/bin/env python3
"""Offline version gate. No network, signing or publication. Writes only with --record-success."""
import argparse
import datetime
import json
import os
from pathlib import Path
import re
import sys


def version_tuple(value):
    if not re.fullmatch(r"\d+\.\d+\.\d+", value):
        raise ValueError("version must be three numeric components")
    return tuple(map(int, value.split(".")))


def resolve(root, requested_version=None, requested_build=None, mode="local", reason=""):
    metadata = json.loads((root / "release/version.json").read_text())
    canonical = metadata["version"]
    current_build = metadata["build"]
    version_tuple(canonical)
    if not isinstance(current_build, int) or isinstance(current_build, bool) or current_build < 1:
        raise ValueError("invalid canonical build")
    version = requested_version or canonical
    build = int(requested_build or current_build)
    if build < 1:
        raise ValueError("build must be positive")
    version_tuple(version)
    exceptions = []
    if (version, build) != (canonical, current_build):
        exceptions.append("override differs from the canonical candidate")
    historical = metadata.get("historicalStoreSubmission", {})
    if version_tuple(version) < version_tuple(canonical) or build <= historical.get("build", 0):
        exceptions.append("downgrade or historical build reuse")
    ledger_path = root / "release/local-build-ledger.json"
    ledger = json.loads(ledger_path.read_text()) if ledger_path.exists() else []
    if any(row["mode"] == mode and row["build"] == build for row in ledger):
        exceptions.append("this channel/build already has a successful local build")
    if exceptions and not reason.strip():
        raise ValueError("; ".join(exceptions) + "; provide RELEASE_OVERRIDE_REASON to document intentional reuse")
    return version, build, ledger


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--version")
    parser.add_argument("--build")
    parser.add_argument("--mode", choices=["local", "github", "app-store", "community"], default="local")
    parser.add_argument("--override-reason", default="")
    parser.add_argument("--resolve", action="store_true")
    parser.add_argument("--record-success", action="store_true")
    args = parser.parse_args()
    try:
        version, build, ledger = resolve(args.root, args.version, args.build, args.mode, args.override_reason)
        if args.record_success:
            ledger.append(dict(version=version, build=build, mode=args.mode,
                               at=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                               overrideReason=args.override_reason, status="local-build-only"))
            target = args.root / "release/local-build-ledger.json"
            temp = target.with_suffix(".tmp")
            with temp.open("x") as handle:
                json.dump(ledger, handle, ensure_ascii=False, indent=2)
                handle.write("\n")
            os.replace(temp, target)
        if args.resolve:
            print(version, build)
        else:
            print(f"PASS candidate={version} build={build}; remote availability NOT checked")
        return 0
    except (ValueError, OSError, KeyError) as error:
        print(f"FAIL {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
