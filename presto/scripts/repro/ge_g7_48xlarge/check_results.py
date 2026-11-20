#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2026, NVIDIA CORPORATION.
# SPDX-License-Identifier: Apache-2.0
"""Checks a run_repro.sh run against the reference run (README.md, "Expected result").

results  RUN_JSON REFERENCE_JSON   per query: the reference warm time, this run's warm time and whether every run's
                                   result checksum equals the reference's; then the 22-query total. Exit 1 when a run
                                   failed, a checksum differs or the session properties differ; exit 2 when the total
                                   is more than TOLERANCE (default 3 %) away from the reference total.
config   LOG_DIR [REFERENCE]       the cluster configuration recorded in the server logs: the coordinator's
                                   properties that differ from Presto's defaults and the first worker's
                                   config.properties, without the per-node values (node id and address). Prints it,
                                   or with REFERENCE prints the differences and exits 1 when there are any.

Warm time of a query = the faster of runs 1 and 2 (run 0 reads the data from S3 into the cleared caches)."""
import glob
import json
import os
import re
import sys

TOLERANCE = float(os.environ.get("TOLERANCE", "0.03"))


def warm(runs):
    times = [r["ms"] / 1000 for r in runs[1:3] if "error" not in r]
    return min(times) if times else None


def results(run_path, reference_path):
    run, reference = json.load(open(run_path)), json.load(open(reference_path))
    failed = []
    if run["session"] != reference["session"]:
        changed = sorted(set(run["session"].items()) ^ set(reference["session"].items()))
        failed.append(f"session properties differ from the reference: {changed}")
    print(f"{'query':6} {'reference s':>12} {'this run s':>11}  checksums")
    total, reference_total = 0.0, 0.0
    for name in sorted(reference["runs"], key=lambda q: int(q[1:])):
        expected = reference["runs"][name][0]["md5"]
        runs = run["runs"].get(name, [])
        errors = [r["error"] for r in runs if "error" in r]
        checksums_ok = len(runs) == 3 and not errors and all(r["md5"] == expected for r in runs)
        if errors:
            failed.append(f"{name}: {len(errors)} failed runs, first error: {errors[0]}")
        elif not checksums_ok:
            failed.append(f"{name}: result checksums {[r.get('md5') for r in runs]}, expected {expected}")
        this, ref = warm(runs), warm(reference["runs"][name])
        reference_total += ref
        total = None if this is None or total is None else total + this
        shown = f"{this:11.2f}" if this is not None else "     failed"
        print(f"{name:6} {ref:12.2f} {shown}  {'ok' if checksums_ok else 'DIFFER'}")
    if total is None:
        print("total: not available (a query has no successful warm run)")
    else:
        print(f"total  {reference_total:12.2f} {total:11.2f}  ({total / reference_total:.3f}x the reference)")
    for line in failed:
        print("FAIL", line)
    if failed:
        return 1
    if abs(total / reference_total - 1) > TOLERANCE:
        print(f"TIME OUTSIDE TOLERANCE: {total:.2f} s is more than {TOLERANCE:.0%} away from {reference_total:.2f} s")
        return 2
    print(f"PASS: all {len(reference['runs'])} queries match the reference results, total within {TOLERANCE:.0%}")
    return 0


def worker_config(path):
    """config.properties as the worker logs it at startup (registered and unregistered properties)."""
    lines, inside = [], False
    for line in open(path, errors="replace"):
        if "properties from '" in line:
            inside = "/config.properties'" in line
            continue
        if inside and line.startswith("  ") and "=" in line:
            lines.append("worker " + line.strip())
        elif not line.startswith("  "):
            inside = False
    return lines


def coordinator_config(path):
    """Properties whose runtime value differs from the default, from the coordinator's Bootstrap table."""
    lines = []
    for line in open(path, errors="replace"):
        fields = line.rstrip("\n").split("\t")
        if len(fields) >= 5 and fields[3] == "Bootstrap":
            parts = re.split(r"\s{2,}", fields[4].strip())
            if len(parts) >= 3 and parts[0] not in ("PROPERTY",) and parts[1] != parts[2]:
                lines.append(f"coordinator {parts[0]}={parts[2]}")
    return lines


def config(log_dir, reference_path=None):
    coordinator = sorted(glob.glob(os.path.join(log_dir, "coordinator_*.log")))
    workers = sorted(glob.glob(os.path.join(log_dir, "worker_0_*.log")))
    if not coordinator or not workers:
        print(f"no coordinator_*.log or worker_0_*.log in {log_dir}", file=sys.stderr)
        return 1
    per_node = re.compile(r"^(coordinator|worker) (node\.id|node\.internal-address)=")
    lines = [
        line
        for line in sorted(set(coordinator_config(coordinator[-1]) + worker_config(workers[-1])))
        if not per_node.match(line)
    ]
    if reference_path is None:
        print("\n".join(lines))
        return 0
    reference = [line.rstrip("\n") for line in open(reference_path) if line.strip()]
    missing, extra = sorted(set(reference) - set(lines)), sorted(set(lines) - set(reference))
    for line in missing:
        print("only in the reference:", line)
    for line in extra:
        print("only in this run:     ", line)
    print(f"{len(lines)} settings, {len(missing) + len(extra)} differences from {os.path.basename(reference_path)}")
    return 1 if missing or extra else 0


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "results":
        sys.exit(results(sys.argv[2], sys.argv[3]))
    if len(sys.argv) in (3, 4) and sys.argv[1] == "config":
        sys.exit(config(*sys.argv[2:]))
    sys.exit(__doc__)
