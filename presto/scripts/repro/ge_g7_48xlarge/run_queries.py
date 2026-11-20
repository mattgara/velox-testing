#!/usr/bin/env python3
"""Run the 22 TPC-H queries against SCHEMA ITERS times each with the given session properties, worker caches cleared
before each query (presto_client.timed_runs: velox-testing's cold-once cadence, coordinator elapsed time, md5 of the
sorted rows, remote file cache hit/miss). Writes OUT.json.
usage: run_queries.py SCHEMA SF OUT ITERS [QFILE=queries.json] [QUERIES=1,2,...] [k=v session ...]"""
import json, sys
import presto_client
schema, sf, out, iters = sys.argv[1], float(sys.argv[2]), sys.argv[3], int(sys.argv[4])
args = sys.argv[5:]
only = None
qfile = "/work/scripts/queries.json"
for a in [a for a in args if a.startswith("QFILE=")]:
    qfile = a.split("=", 1)[1]
    args.remove(a)
if args and args[0].startswith("QUERIES="):
    only = ["Q" + q for q in args[0].split("=", 1)[1].split(",")]
    args = args[1:]
session = dict(kv.split("=", 1) for kv in args)
queries = json.load(open(qfile))
if "Q11" in queries: queries["Q11"] = queries["Q11"].format(SF_FRACTION=f"{0.0001 / sf:.12f}")
if "Q15" in queries: queries["Q15"] = queries["Q15"].replace(" AS supplier_no", "").replace("supplier_no", "l_suppkey")
names = [q for q in sorted(queries, key=lambda q: int(q[1:])) if not only or q in only]
results = {"schema": schema, "session": session, "runs": {}}
for name in names:
    results["runs"][name] = presto_client.timed_runs(name, queries[name].strip().rstrip(";"), session, schema, iters)
    json.dump(results, open(out, "w"), indent=1)
