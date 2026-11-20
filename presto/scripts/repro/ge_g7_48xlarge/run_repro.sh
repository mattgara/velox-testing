#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026, NVIDIA CORPORATION.
# SPDX-License-Identifier: Apache-2.0
#
# Reproduces the 8-GPU grouped-execution TPC-H SF3000 result on one g7.48xlarge from already built images
# (README.md): starts a coordinator and 8 GPU workers, runs the 22 queries 3 times each under the single
# configuration of the reference run, stops the cluster, then checks the cluster configuration, every query result and
# the warm time against reference/. It never builds images (README.md, "Build").
#
# usage: run_repro.sh IMAGE_TAG [OUTPUT_DIR]
#   IMAGE_TAG   runs presto-coordinator:IMAGE_TAG and presto-native-worker-gpu:IMAGE_TAG
#   OUTPUT_DIR  results, logs and settings; default ./ge_repro_<UTC time>
# Environment: DATA (default s3://rapids-tpch/presto-gpu/sf3k_decimal_hive_flat), the S3 prefix of the data and its Hive
# metastore. Exit status: 0 pass, 1 setup failure or wrong results, 2 results right but time outside tolerance.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "${HERE}/../.." && pwd)"
IMAGE_TAG=${1:?usage: run_repro.sh IMAGE_TAG [OUTPUT_DIR]}
OUT=${2:-ge_repro_$(date -u +%Y%m%dT%H%M%S)}
mkdir -p "${OUT}" && OUT="$(cd "${OUT}" && pwd)"
DATA=${DATA:-s3://rapids-tpch/presto-gpu/sf3k_decimal_hive_flat}
SCHEMA=tpch_sf3k_decimal_hive_flat_s3
METASTORE="${SCRIPTS}/../docker/.hive_metastore"
COMPOSE_PROJECT=ge-repro
WORKERS=8

log() { echo "$(date -u +%FT%TZ) $*" | tee -a "${OUT}/run.log"; }
fail() { log "FAILED: $*"; exit 1; }

# Settings of the reference run (README.md, "Settings"). Worker config.properties:
WORKER_PROPERTIES=(
  cudf.compact_aggregation_state_enabled=true cudf.decimal_groupby_narrow_accumulation=true
  cudf.compact_decimal_intermediate_state=true cudf.narrow_decimal_sum_state=true cudf.streaming_groupby_partitions=8
  cudf.partial_aggregation_abandonment=true cudf.batch_size_min_threshold=20000000 cudf.batch_size_min_bytes=402653184
  cudf.exchange_max_queued_bytes=1610612736 driver.max-split-preload=1 system-mem-limit-gb=70
  cudf.exchange_store=true cudf.exchange_store_device_bytes=3221225472 cudf.exchange_store_host_bytes=38654705664
  cudf.exchange_compression=fused-for-bitpacked-lanes
)
# Worker Hive catalog:
WORKER_HIVE_PROPERTIES=(
  cudf.hive.preload-column-chunks=true cudf.hive.preload-chunking-setup=true cudf.hive.high-priority-scan-streams=true
  max-partitions-per-writers=1024 parquet.reader.chunk-read-limit=1610612736
)
# Coordinator config.properties (history-based planning reads the sample statistics plugin; nothing is recorded):
COORDINATOR_PROPERTIES=(
  optimizer.use-history-based-plan-statistics=true optimizer.track-history-based-plan-statistics=false
  optimizer.history-canonical-plan-node-limit=1000000 optimizer.push-selective-join-below-aggregation=true
  task.status-refresh-max-wait=100ms
)
COORDINATOR_HIVE_PROPERTIES=(hive.temporary-table-storage-format=PARQUET)
# Session properties of every query (the grouped-execution configuration):
SESSION=(
  hive.file_splittable=false schedule_splits_based_on_task_load=true hive.node_selection_strategy=SOFT_AFFINITY
  native_max_split_preload_per_driver=1 native_cudf_exchange_enabled=true experimental_deterministic_bounded_splits=true
  grouped_execution=true exchange_materialization_strategy=AUTOMATIC partitioning_provider_catalog=hive
  task_partitioned_writer_count=1 hash_partition_count=64 concurrent_lifespans_per_task=1
  max_concurrent_materializations=1 hive.list_temporary_tables_by_bucket=true
  exchange_materialization_max_bucket_count=256 exchange_materialization_memory_threshold=9280MB
  exchange_materialization_bucket_memory_fraction=0.082759
)
# Launcher environment: host memory per worker and container limits for 8 workers in ~726 GiB, cuDF pinned host pool,
# UCX without GPU-direct RDMA (README.md, "Assumptions").
LAUNCH_ENV=(
  PRESTO_GPU_IDS=0,1,2,3,4,5,6,7 WORKER_SYSTEM_MEMORY_GB=32 WORKER_QUERY_MEMORY_GB=24 WORKER_MEM_LIMIT=80g
  COORD_MEM_LIMIT=24g LIBCUDF_PINNED_POOL_SIZE=4294967296 LIBCUDF_PINNED_POOL_MAX_SIZE=8589934592
  UCX_IB_GPU_DIRECT_RDMA=n UCX_RNDV_FRAG_MEM_TYPES_OVERRIDE=host
  "EXTRA_WORKER_PROPERTIES=${WORKER_PROPERTIES[*]}" "EXTRA_WORKER_HIVE_PROPERTIES=${WORKER_HIVE_PROPERTIES[*]}"
  "EXTRA_COORDINATOR_PROPERTIES=${COORDINATOR_PROPERTIES[*]}"
  "EXTRA_COORDINATOR_HIVE_PROPERTIES=${COORDINATOR_HIVE_PROPERTIES[*]}"
)

stop_cluster() {
  (cd "${SCRIPTS}" && COMPOSE_PROJECT_NAME=${COMPOSE_PROJECT} PRESTO_IMAGE_TAG=${IMAGE_TAG} ./stop_presto.sh) \
    >> "${OUT}/stop.log" 2>&1 || true
}

presto_sql() {
  (cd "${HERE}" && PRESTO_URL=http://localhost:8080 python3 -c "
import sys, presto_client
print(presto_client.run(sys.argv[1], schema='${SCHEMA}')[1])" "$1")
}

# 1. Preconditions: both images, no Presto cluster already running, idle GPUs when nvidia-smi is available.
for image in presto-coordinator:${IMAGE_TAG} presto-native-worker-gpu:${IMAGE_TAG}; do
  id=$(docker image inspect "${image}" --format '{{.Id}}' 2> /dev/null) || fail "image ${image} not found"
  log "image ${image} ${id:7:12}"
done
[ -z "$(docker ps --format '{{.Names}}' | grep -E '^presto-' || true)" ] || fail "a Presto cluster is running"
if command -v nvidia-smi > /dev/null; then
  busy=$(nvidia-smi --query-gpu=index,memory.used --format=csv,noheader,nounits | awk -F', ' '$2 > 1024 { print $1 }' | xargs)
  [ -z "${busy}" ] || fail "GPUs in use: ${busy}"
fi
printf '%s\n' "${LAUNCH_ENV[@]}" "${SESSION[@]}" > "${OUT}/settings.txt"

# 2. Hive metastore of the data (table locations and statistics), from S3 next to the data, checked against reference/.
if [ ! -d "${METASTORE}/${SCHEMA}" ]; then
  log "fetching the Hive metastore from ${DATA}/hive_metastore/"
  aws s3 cp --quiet --recursive "${DATA}/hive_metastore/" "${METASTORE}/"
fi
(cd "${METASTORE}" && md5sum --quiet -c "${HERE}/reference/hive_metastore.md5") \
  || fail "the metastore in ${METASTORE}/${SCHEMA} differs from reference/hive_metastore.md5"

# 3. Cluster: coordinator + 8 GPU workers, one per GPU, through the g7 launcher.
trap stop_cluster EXIT
log "starting the cluster (log: start.log)"
(cd "${SCRIPTS}/repro" && env "${LAUNCH_ENV[@]}" ./gepoc_run_tpch_g7_24xlarge.sh --start-only --no-nic-bind \
  --image-tag "${IMAGE_TAG}" --compose-project ${COMPOSE_PROJECT} --async-data-cache on --cache-mode cold-once \
  -s ${SCHEMA}) > "${OUT}/start.log" 2>&1 || fail "cluster start (start.log)"
workers=$(curl -s localhost:8080/v1/node | python3 -c 'import json, sys; print(len(json.load(sys.stdin)))' 2> /dev/null || echo 0)
[ "${workers}" -eq ${WORKERS} ] || fail "${workers} of ${WORKERS} workers registered"
# Materialized exchanges are temporary tables in hive.default. The coordinator can still be initializing after the
# workers register, so retry for up to 2 minutes.
for attempt in $(seq 24); do
  presto_sql "CREATE SCHEMA IF NOT EXISTS hive.default" > /dev/null 2>&1 && break
  [ "${attempt}" -lt 24 ] || fail "CREATE SCHEMA hive.default"
  sleep 5
done
# Container memory limits and the UCX, cuDF and KvikIO environment (other variables, such as credentials, are left out).
for container in presto-coordinator presto-native-worker-gpu-0; do
  docker inspect "${container}" --format '{{.Name}} memory {{.HostConfig.Memory}}{{println}}{{range .Config.Env}}{{println .}}{{end}}' \
    2> /dev/null | grep -E '^/|^(UCX|LIBCUDF|KVIKIO|CUDA_VISIBLE)' >> "${OUT}/containers.txt" || true
done

# 4. The 22 queries, 3 runs each; worker caches are cleared before each query's first run.
log "running the 22 queries (log: queries.log)"
(cd "${HERE}" && PRESTO_POLL_SLEEP=0 PRESTO_SLEEP_AFTER_ERROR_S=15 python3 run_queries.py ${SCHEMA} 3000 \
  "${OUT}/results.json" 3 QFILE="${HERE}/queries.json" "${SESSION[@]}") > "${OUT}/queries.log" 2>&1 \
  || fail "query runner (queries.log)"
log "$(grep -c '^Q[0-9]* [0-9] {' "${OUT}/queries.log") runs, $(grep -c "'error'" "${OUT}/queries.log" || true) failed"

# 5. Server logs of this cluster, then stop it.
mkdir -p "${OUT}/logs"
for f in $(ls -t "${SCRIPTS}"/presto_logs/worker_*.log | head -${WORKERS}) $(ls -t "${SCRIPTS}"/presto_logs/coordinator_*.log | head -1); do
  cp "${f}" "${OUT}/logs/"
done
stop_cluster
trap - EXIT

# 6. Checks: configuration as recorded by the servers, then results and time.
python3 "${HERE}/check_results.py" config "${OUT}/logs" > "${OUT}/cluster_config.txt"
if python3 "${HERE}/check_results.py" config "${OUT}/logs" "${HERE}/reference/cluster_config.txt" \
    > "${OUT}/cluster_config_check.txt"; then
  log "cluster configuration matches reference/cluster_config.txt"
else
  log "cluster configuration differs from reference/cluster_config.txt:"; tee -a "${OUT}/run.log" < "${OUT}/cluster_config_check.txt"
  exit 1
fi
status=0
python3 "${HERE}/check_results.py" results "${OUT}/results.json" "${HERE}/reference/s1d_20261118.json" \
  | tee "${OUT}/check.txt" || status=$?
log "done, exit ${status} (results in ${OUT})"
exit ${status}
