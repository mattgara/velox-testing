#!/usr/bin/env python3
"""Minimal Presto REST client: run(sql, session) -> (columns, rows). Raises on query failure.
After run(), last_query_id and last_elapsed_ms (the coordinator's elapsedTimeMillis, the time velox-testing's
benchmark records) describe the query. clear_worker_caches() is velox-testing's per-query cache reset."""
import hashlib, json, time, urllib.request

import os
URL = os.environ.get("PRESTO_URL", "http://localhost:8080")
last_query_id = None
last_elapsed_ms = None
POLL_SLEEP = float(os.environ.get("PRESTO_POLL_SLEEP", "0.05"))

def run(sql, session=None, catalog="hive", schema="tpch_ge", user="gepoc"):
    headers = {"X-Presto-User": user, "X-Presto-Catalog": catalog, "X-Presto-Schema": schema}
    if session:
        headers["X-Presto-Session"] = ",".join(f"{k}={v}" for k, v in session.items())
    req = urllib.request.Request(URL + "/v1/statement", data=sql.encode(), headers=headers, method="POST")
    resp = json.load(urllib.request.urlopen(req))
    global last_query_id, last_elapsed_ms
    last_query_id = resp.get("id")
    last_elapsed_ms = None
    columns, rows = None, []
    while True:
        if "error" in resp:
            raise RuntimeError(resp["error"].get("message", resp["error"]))
        columns = resp.get("columns", columns)
        rows.extend(resp.get("data", []))
        if "nextUri" not in resp:
            last_elapsed_ms = resp.get("stats", {}).get("elapsedTimeMillis")
            return columns, rows
        # The coordinator holds each request until results or a state change (long poll); a client sleep only adds
        # latency. PRESTO_POLL_SLEEP keeps the old 50 ms behavior for comparisons with earlier runs.
        time.sleep(POLL_SLEEP)
        resp = json.load(urllib.request.urlopen(urllib.request.Request(resp["nextUri"], headers=headers)))

def _get_text(url):
    return urllib.request.urlopen(url, timeout=60).read().decode().strip()

# Success bodies of PrestoServerOperations::serverOperationClearCache, as velox-testing's cache_reset.py matches them
# (the endpoint answers 200 for no-ops too).
_CLEARED = {"memory": "Cleared memory cache", "ssd": "Cleared ssd cache"}
_NOT_CONFIGURED = {"No memory cache set on server", "No ssd cache set on server"}

def clear_worker_caches(connector_id="hive"):
    """Clear every worker's Hive file-handle cache and Velox memory and SSD data caches: velox-testing's
    cache_reset.clear_worker_data_caches, which its cold-once mode runs before each query's iterations (the anchor
    runs). Waits up to 30 s for an idle cluster and raises unless every worker cleared its memory cache. The OS page
    cache drop that velox-testing adds is skipped: the data is on S3."""
    for _ in range(120):
        states = [q["state"] for q in json.load(urllib.request.urlopen(URL + "/v1/query"))]
        if not any(s in ("QUEUED", "PLANNING", "STARTING", "RUNNING", "FINISHING", "DISPATCHING") for s in states):
            break
        time.sleep(0.25)
    else:
        raise RuntimeError("cluster not idle; caches not cleared")
    uris = [n["uri"].rstrip("/").removesuffix("/v1/status") for n in json.load(urllib.request.urlopen(URL + "/v1/node"))]
    if not uris:
        raise RuntimeError("no workers in /v1/node")
    for uri in uris:
        _get_text(f"{uri}/v1/operation/connector/clearCache?name=hive&id={connector_id}")
        for tier, cleared in _CLEARED.items():
            body = _get_text(f"{uri}/v1/operation/server/clearCache?type={tier}")
            if body != cleared and not (tier == "ssd" and body in _NOT_CONFIGURED):
                raise RuntimeError(f"{uri}: {tier} clear returned {body!r}")
    return len(uris)

# Runtime statistics summed over a query's operators, reported per run in GiB: remote file cache hits and misses,
# exchange bytes before and after compression, and the exchange store's logical, device and host bytes written and
# host bytes read back.
_QUERY_BYTES = {"cudfKvikioCacheHitBytes": "cache_hit_gib", "cudfKvikioCacheMissBytes": "cache_miss_gib",
                "compressionInputBytes": "exchange_in_gib", "compressedBytes": "exchange_sent_gib",
                "exchangeStoreLogicalBytes": "store_logical_gib", "exchangeStoreDeviceBytes": "store_device_gib",
                "exchangeStoreHostBytes": "store_host_gib", "exchangeStoreReadHostBytes": "store_read_host_gib"}

def query_bytes(query_id):
    """Sums of the _QUERY_BYTES runtime statistics over the query (GiB, rounded), from the coordinator's query info."""
    info = json.load(urllib.request.urlopen(f"{URL}/v1/query/{query_id}"))
    totals = dict.fromkeys(_QUERY_BYTES.values(), 0)
    def stages(stage):
        yield stage
        for child in stage.get("subStages", []):
            yield from stages(child)
    if info.get("outputStage"):
        for stage in stages(info["outputStage"]):
            execution = stage.get("latestAttemptExecutionInfo", stage)
            for summary in (execution.get("stats") or {}).get("operatorSummaries", []):
                for name, stat in (summary.get("runtimeStats") or {}).items():
                    key = _QUERY_BYTES.get(name.rsplit(".", 1)[-1])
                    if key:
                        totals[key] += stat["sum"]
    return {key: round(value / 2**30, 2) for key, value in totals.items() if value}

def timed_runs(name, sql, session, schema, iters, extra=None):
    """velox-testing's cold-once cadence: clear the worker caches, then run the query ITERS times (the first is the
    warm-up). Per run: ms = the coordinator's elapsed time (client_ms = this client's, which adds result parsing),
    rows and an md5 of the sorted rows (to compare arms) or the error, the query id, the remote file cache's hit and
    miss GiB and its exchange and store bytes (query_bytes), plus EXTRA. Prints each run. After a failed run, waits
    PRESTO_SLEEP_AFTER_ERROR_S seconds (default 0): a failed query's tasks keep device memory for a few seconds after
    they end, and a run started at once fails for that memory instead of its own. PRESTO_SLEEP_BETWEEN_RUNS_S (default 0)
    waits after every run, to tell memory a finished run returns late from memory it keeps."""
    clear_worker_caches()
    runs = []
    for i in range(iters):
        t0 = time.time()
        try:
            cols, rows = run(sql, session=session, schema=schema)
            client_ms = int((time.time() - t0) * 1000)
            digest = hashlib.md5(json.dumps(sorted(json.dumps(r) for r in rows)).encode()).hexdigest()[:12]
            record = {"t0": round(t0, 2), "ms": last_elapsed_ms if last_elapsed_ms is not None else client_ms,
                      "client_ms": client_ms, "rows": len(rows), "md5": digest}
        except Exception as e:
            record = {"t0": round(t0, 2), "ms": int((time.time() - t0) * 1000), "error": str(e)[:300]}
        record["qid"] = last_query_id
        try:
            record.update(query_bytes(last_query_id))
        except Exception:
            pass
        record.update(extra or {})
        print(name, i, record, flush=True)
        runs.append(record)
        if "error" in record:
            time.sleep(float(os.environ.get("PRESTO_SLEEP_AFTER_ERROR_S", "0")))
        time.sleep(float(os.environ.get("PRESTO_SLEEP_BETWEEN_RUNS_S", "0")))
    return runs
