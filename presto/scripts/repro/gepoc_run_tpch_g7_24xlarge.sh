#!/bin/bash
# g7.24xlarge copy (2026-11-17, wdx-4500rtx-grouped-exec): 4x RTX PRO 4500 on NUMA node 0 with one ENA NIC (enp71s0) and
# one EFA device (rdmap95s0 there, rdmap83s0 on the g7.48xlarge: EFA_DEVICE, default the only one in
# /sys/class/infiniband); every GPU uses them (UCX and, with --no-nic-bind, KvikIO). Worker memory for ~371 GiB host
# RAM and 4 workers: system-memory-gb 80, query-memory-gb 56 (g7e: 219, 153).

# SPDX-FileCopyrightText: Copyright (c) 2026, NVIDIA CORPORATION.
# SPDX-License-Identifier: Apache-2.0

# GE POC copy (mgara 2026-11-13, adds EXTRA_COORDINATOR_HIVE_PROPERTIES). TPC-H on S3 with 8 GPU workers (or the GPUs in PRESTO_GPU_IDS) on one g7e.48xlarge; see print_help below. The NIC, EFA and
# memory settings are specific to that instance type.
#
# Common runs (images presto-coordinator:<tag> and presto-native-worker-gpu:<tag> must exist):
#   Async data cache ON, cleared before each query (iteration 1 cold, the rest hot):
#     ./run_tpch_g7e_48xlarge.sh --image-tag <tag> --async-data-cache on --cache-mode cold-once
#   Async data cache ON, cleared once before the first query:
#     ./run_tpch_g7e_48xlarge.sh --image-tag <tag> --async-data-cache on --cache-mode lukewarm
#   Async data cache OFF:
#     ./run_tpch_g7e_48xlarge.sh --image-tag <tag> --async-data-cache off
#   SF3K instead of SF1K:
#     ./run_tpch_g7e_48xlarge.sh --image-tag <tag> --async-data-cache off -s tpch_sf3k_v2_float_s3
#   A few queries with the HTTP exchange:
#     ./run_tpch_g7e_48xlarge.sh --image-tag <tag> -q 1,6 --exchange http
#   Start the cluster for ad-hoc queries, then stop it:
#     ./run_tpch_g7e_48xlarge.sh --image-tag <tag> --async-data-cache on --start-only
#     ../stop_presto.sh
# On a shared host, also pass --compose-project <name> so other people's clusters are not
# stopped, and use the same COMPOSE_PROJECT_NAME and PRESTO_IMAGE_TAG for stop_presto.sh.
# Results go to presto/scripts/benchmark_output/<run tag> (see -t).
#
# Free host memory first if either NUMA node has < 500 GiB MemFree:
#   grep MemFree /sys/devices/system/node/node*/meminfo
#   sync && sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches' && sudo sh -c 'echo 1 > /proc/sys/vm/compact_memory'

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

print_help() {
  cat << EOF

Usage: $0 [OPTIONS]

This script runs TPC-H on S3 with 8 GPU workers on one g7e.48xlarge (8x RTX PRO 6000), set up to
match the WXD-launch runs: UCX GPU exchange over EFA, KvikIO S3 reads with each GPU pair on its
NUMA-local NIC, and the Velox async data cache enabled or disabled. It never builds images.

OPTIONS:
    -h, --help              Show this help message.
    -s, --schema-name       Name of the schema to query. Its metastore must be in presto/docker/.hive_metastore.
                            By default, "tpch_sf1k_v2_float_s3".
    -q, --queries           Set of benchmark queries to run. This should be a comma separate list of query numbers.
                            By default, all benchmark queries are run.
    -i, --iterations        Number of query run iterations. By default, 3 iterations are run.
    -t, --tag               Tag associated with the benchmark run. By default, a tag is built from the options.
    --async-data-cache      Enable ("on") or disable ("off") the Velox async data cache on the workers.
                            By default, "off".
    --cache-mode            When to clear caches between queries, passed on to run_benchmark.sh: "off", "lukewarm",
                            "cold-once", "cold" or "hot". By default, "off".
    --image-tag             Tag of the presto-coordinator and presto-native-worker-gpu images to run.
                            By default, \$USER (as in start_native_gpu_presto.sh).
    --compose-project       Docker Compose project name. By default, Docker Compose chooses it.
    --exchange              Shuffle transport: "ucx" or "http". "ucx" needs images built with the Velox and Presto
                            UCX exchange changes. By default, "ucx".
    --dispatch              KvikIO reactor dispatch: "SHARED_QUEUE" or "PER_CHUNK". By default, "SHARED_QUEUE".
    --no-nontemporal-copy   Disable KvikIO's non-temporal copy.
    --no-nic-bind           Send all S3 traffic through the primary NIC instead of each GPU pair's NUMA-local NIC.
    --start-only            Start the cluster and exit. Stop it with stop_presto.sh.

EXAMPLES:
    $0 --async-data-cache on --cache-mode cold-once
    $0 --async-data-cache on --cache-mode lukewarm --image-tag wxd-upstream
    $0 -s tpch_sf3k_v2_float_s3
    $0 -q "1,6" --exchange http

EOF
}

SCHEMA_NAME=tpch_sf1k_v2_float_s3
ITERATIONS=3
ASYNC_DATA_CACHE=off
CACHE_MODE=off
IMAGE_TAG=${USER:-latest}
EXCHANGE=ucx
DISPATCH=SHARED_QUEUE
NONTEMPORAL_COPY=true
NIC_BIND=true
START_ONLY=false

parse_args() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      -h|--help)
        print_help
        exit 0
        ;;
      -s|--schema-name|-q|--queries|-i|--iterations|-t|--tag|--async-data-cache|--cache-mode|--image-tag|\
      --compose-project|--exchange|--dispatch)
        if [[ -z $2 ]]; then
          echo "Error: $1 requires a value"
          exit 1
        fi
        case $1 in
          -s|--schema-name) SCHEMA_NAME=$2 ;;
          -q|--queries) QUERIES=$2 ;;
          -i|--iterations) ITERATIONS=$2 ;;
          -t|--tag) TAG=$2 ;;
          --async-data-cache) ASYNC_DATA_CACHE=$2 ;;
          --cache-mode) CACHE_MODE=$2 ;;
          --image-tag) IMAGE_TAG=$2 ;;
          --compose-project) COMPOSE_PROJECT=$2 ;;
          --exchange) EXCHANGE=$2 ;;
          --dispatch) DISPATCH=$2 ;;
        esac
        shift 2
        ;;
      --no-nontemporal-copy)
        NONTEMPORAL_COPY=false
        shift
        ;;
      --no-nic-bind)
        NIC_BIND=false
        shift
        ;;
      --start-only)
        START_ONLY=true
        shift
        ;;
      *)
        echo "Error: Unknown argument $1"
        print_help
        exit 1
        ;;
    esac
  done
}

parse_args "$@"

case $ASYNC_DATA_CACHE in
  on) ASYNC_DATA_CACHE_ENABLED=true ;;
  off) ASYNC_DATA_CACHE_ENABLED=false ;;
  *)
    echo "Error: --async-data-cache must be on or off"
    exit 1
    ;;
esac
if [[ ! $CACHE_MODE =~ ^(off|lukewarm|cold-once|cold|hot)$ ]]; then
  echo "Error: --cache-mode must be off, lukewarm, cold-once, cold or hot"
  exit 1
fi
if [[ $ASYNC_DATA_CACHE == off && $CACHE_MODE =~ ^(lukewarm|cold-once|cold)$ ]]; then
  echo "Warning: --cache-mode ${CACHE_MODE} with --async-data-cache off: there is no async data cache to clear," \
    "so only the Hive file-handle cache is cleared."
fi
if [[ ! $EXCHANGE =~ ^(ucx|http)$ ]]; then
  echo "Error: --exchange must be ucx or http"
  exit 1
fi
if [[ ! $DISPATCH =~ ^(SHARED_QUEUE|PER_CHUNK)$ ]]; then
  echo "Error: --dispatch must be SHARED_QUEUE or PER_CHUNK"
  exit 1
fi

# run_benchmark.sh writes benchmark_output under the current directory.
cd "${SCRIPT_DIR}/.."

if [[ ! -d ../docker/.hive_metastore/${SCHEMA_NAME} ]]; then
  dataset=${SCHEMA_NAME#tpch_}
  echo "Error: no metastore for ${SCHEMA_NAME} in presto/docker/.hive_metastore. For the rapids-tpch data sets:"
  echo "  aws s3 cp --recursive s3://rapids-tpch/presto-gpu/${dataset%_s3}/hive_metastore/ ../docker/.hive_metastore/"
  exit 1
fi
# start_native_gpu_presto.sh builds any missing image; fail instead.
for image in presto-coordinator:${IMAGE_TAG} presto-native-worker-gpu:${IMAGE_TAG}; do
  if ! docker image inspect "$image" > /dev/null 2>&1; then
    echo "Error: image $image not found"
    exit 1
  fi
done
# The g7's EFA devices: rdmap95s0 on the g7.24xlarge; on the g7.48xlarge rdmap83s0 (NUMA node 0) and, with a second EFA
# interface on network card 1 (2026-11-18, as the g7e has one per GPU pair), one on node 1 for GPUs 4-7.
efa_on_node() {
  local d
  for d in /sys/class/infiniband/*; do
    [[ $(cat $d/device/numa_node 2>/dev/null) == "$1" ]] && { basename $d; return; }
  done
}
EFA_DEVICE=${EFA_DEVICE:-$(efa_on_node 0)}
EFA_DEVICE=${EFA_DEVICE:-$(ls /sys/class/infiniband 2>/dev/null | head -1)}
EFA_DEVICE_NODE1=${EFA_DEVICE_NODE1:-$(efa_on_node 1)}
EFA_DEVICE_NODE1=${EFA_DEVICE_NODE1:-$EFA_DEVICE}
echo "EFA devices: GPUs 0-3 $EFA_DEVICE, GPUs 4-7 $EFA_DEVICE_NODE1"
for dev in /sys/class/net/enp71s0 /sys/class/infiniband/${EFA_DEVICE:-none}; do
  if [[ ! -e $dev ]]; then
    echo "Error: $dev not found; this script expects a g7 (one ENA NIC enp71s0, one EFA device)"
    exit 1
  fi
done

export PRESTO_IMAGE_TAG=${IMAGE_TAG}
if [[ -n $COMPOSE_PROJECT ]]; then
  export COMPOSE_PROJECT_NAME=${COMPOSE_PROJECT}
fi

# Workers on the host network with EFA devices (rendered by the compose template).
export PRESTO_GPU_HOST_NETWORK=true
HOST_IP=$(ip -4 -o addr show dev enp71s0 | awk '{ split($4, a, "/"); print a[1]; exit }')
if [[ -z $HOST_IP ]]; then
  echo "Error: no IPv4 address on enp71s0"
  exit 1
fi
echo "Worker internal address: $HOST_IP"
# The TPC-H data sets live in us-east-2. KvikIO signs S3 requests with AWS_* from the
# environment, which the compose files pass into the workers. Without exported credentials,
# use the instance role (IMDS) and skip any configured profile.
export AWS_REGION=us-east-2 AWS_DEFAULT_REGION=us-east-2
if [[ -z ${AWS_ACCESS_KEY_ID} ]]; then
  eval "$(AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null aws configure export-credentials --format env)"
fi

# Exchange over EFA: one NUMA-local EFA device per GPU pair, with the WXD-launch rendezvous tuning.
# UCX_TLS_OVERRIDE (local experiment hook), e.g. tcp,srd,cuda_copy,cuda_ipc,self to add CUDA IPC.
export PRESTO_GPU_UCX_TLS=${UCX_TLS_OVERRIDE:-tcp,srd,cuda_copy,self}
export PRESTO_GPU_UCX_RNDV_PIPELINE_ERROR_HANDLING=n
# UCX_RNDV_FRAG_SIZE_OVERRIDE (local experiment hook) replaces the rendezvous fragment size.
export UCX_MAX_RNDV_RAILS=1 UCX_RNDV_FRAG_SIZE=${UCX_RNDV_FRAG_SIZE_OVERRIDE:-cuda:32M}
# UCX_RNDV_FRAG_MEM_TYPES_OVERRIDE (local experiment hook), e.g. host with UCX_IB_GPU_DIRECT_RDMA=n (passed through by the
# compose template) to stage EFA transfers through host memory (g7.48xlarge cross-card test, 2026-11-18).
export UCX_RNDV_FRAG_MEM_TYPES=${UCX_RNDV_FRAG_MEM_TYPES_OVERRIDE:-cuda} UCX_SOCKADDR_TLS_PRIORITY=tcp
# UCX_RNDV_FRAG_ALLOC_COUNT_OVERRIDE (local experiment hook) replaces the fragment allocation count.
export UCX_RNDV_FRAG_ALLOC_COUNT=${UCX_RNDV_FRAG_ALLOC_COUNT_OVERRIDE:-host:128,cuda:32}
export UCX_CUDA_IPC_CACHE_MAX_REGIONS=inf UCX_CUDA_IPC_CACHE_MAX_SIZE=16G
export UCX_NET_DEVICES_GPU_0=${EFA_DEVICE}:1,enp71s0 UCX_NET_DEVICES_GPU_1=${EFA_DEVICE}:1,enp71s0
export UCX_NET_DEVICES_GPU_2=${EFA_DEVICE}:1,enp71s0 UCX_NET_DEVICES_GPU_3=${EFA_DEVICE}:1,enp71s0
export UCX_NET_DEVICES_GPU_4=${EFA_DEVICE_NODE1}:1,enp71s0 UCX_NET_DEVICES_GPU_5=${EFA_DEVICE_NODE1}:1,enp71s0
export UCX_NET_DEVICES_GPU_6=${EFA_DEVICE_NODE1}:1,enp71s0 UCX_NET_DEVICES_GPU_7=${EFA_DEVICE_NODE1}:1,enp71s0
# Experiments: emulate less network per GPU by sharing fewer EFA cards. EFA_CARDS=2 puts GPUs 0-3 on
# the node-0 EFA device and 4-7 on the node-1 one (the default); EFA_CARDS=1 puts all eight on the node-0 device.
case ${EFA_CARDS:-4} in
  4) ;;
  2)
    for i in 0 1 2 3; do export UCX_NET_DEVICES_GPU_$i=${EFA_DEVICE}:1,enp71s0; done
    for i in 4 5 6 7; do export UCX_NET_DEVICES_GPU_$i=${EFA_DEVICE_NODE1}:1,enp71s0; done
    ;;
  1) for i in 0 1 2 3 4 5 6 7; do export UCX_NET_DEVICES_GPU_$i=${EFA_DEVICE}:1,enp71s0; done ;;
  *)
    echo "Error: EFA_CARDS must be 4, 2 or 1"
    exit 1
    ;;
esac

# S3 through KvikIO: each GPU pair on its NUMA-local ENA NIC.
if [[ $NIC_BIND == true ]]; then
  export KVIKIO_REMOTE_IO_INTERFACE_GPU_0='if!enp71s0' KVIKIO_REMOTE_IO_INTERFACE_GPU_1='if!enp71s0'
  export KVIKIO_REMOTE_IO_INTERFACE_GPU_2='if!enp153s0' KVIKIO_REMOTE_IO_INTERFACE_GPU_3='if!enp153s0'
  export KVIKIO_REMOTE_IO_INTERFACE_GPU_4='if!enp170s0' KVIKIO_REMOTE_IO_INTERFACE_GPU_5='if!enp170s0'
  export KVIKIO_REMOTE_IO_INTERFACE_GPU_6='if!enp187s0' KVIKIO_REMOTE_IO_INTERFACE_GPU_7='if!enp187s0'
fi

# Local experiment hook: PRESTO_GPU_IDS runs one worker per listed GPU instead of all eight, e.g.
# PRESTO_GPU_IDS=0,1,2,3 for half the instance (one socket with its two EFA cards and two ENA NICs).
GPU_LIST=${PRESTO_GPU_IDS:-0,1,2,3,4,5,6,7}
IFS=, read -r -a GPUS <<< "$GPU_LIST"
NUM_GPU_WORKERS=${#GPUS[@]}

# KvikIO as in the WXD-launch runs (KVIKIO_NTHREADS=16 comes from --kvikio-threads below).
# MULTI_POLL needs the task size to be at most the bounce buffer size.
export KVIKIO_REMOTE_IO_BACKEND=MULTI_POLL KVIKIO_REMOTE_IO_NUM_REACTORS=4
export KVIKIO_REMOTE_IO_REACTOR_DISPATCH=${DISPATCH} KVIKIO_REMOTE_IO_MAX_CONCURRENT_REQUESTS=128
export KVIKIO_TASK_SIZE=33554432 KVIKIO_BOUNCE_BUFFER_SIZE=33554432
export KVIKIO_REMOTE_IO_NONTEMPORAL_COPY=${NONTEMPORAL_COPY}

# 1. Generate configs: one worker per GPU, 2 drivers each.
VARIANT_TYPE=gpu NUM_WORKERS=$NUM_GPU_WORKERS GPU_IDS=$GPU_LIST VCPU_PER_WORKER=2 OVERWRITE_CONFIG=true \
  ./generate_presto_config.sh

# 2. Align the generated configs with the WXD-launch runs.
G=../docker/config/generated/gpu
setprop() { if grep -q "^$2=" "$1"; then sed -i "s|^$2=.*|$2=$3|" "$1"; else echo "$2=$3" >> "$1"; fi; }
for i in "${GPUS[@]}"; do
  W=$G/etc_worker_$i
  setprop $W/node.properties node.internal-address "$HOST_IP"
  setprop $W/config_native.properties discovery.uri http://127.0.0.1:8080
  setprop $W/config_native.properties async-data-cache-enabled $ASYNC_DATA_CACHE_ENABLED
  # g7.24xlarge (2026-11-17): 80/56 let the four workers' host caches fill the 362 GiB host (it hung in S1d Q9).
  setprop $W/config_native.properties system-memory-gb ${WORKER_SYSTEM_MEMORY_GB:-52}
  setprop $W/config_native.properties query-memory-gb ${WORKER_QUERY_MEMORY_GB:-40}
  setprop $W/config_native.properties system-mem-limit-gb 229
  setprop $W/config_native.properties query.max-memory-per-node 153GB
  setprop $W/config_native.properties cudf.partitioned_output_batch_rows 10000000
  setprop $W/config_native.properties cudf.batch_size_min_threshold 40000000
  setprop $W/config_native.properties cudf.kvikio_cache_copy_threads 16
  setprop $W/config_native.properties driver.max-split-preload 2
  setprop $W/config_native.properties exchange.max-buffer-size 512MB
  setprop $W/config_native.properties exchange.max-response-size 64MB
  setprop $W/config_native.properties sink.max-buffer-size 512MB
  setprop $W/config_native.properties local-exchange.max-buffer-size 536870912
  setprop $W/config_native.properties announcement-max-frequency-ms 1000
  setprop $W/catalog/hive.properties hive.s3.max-connections 96
  setprop $W/catalog/hive.properties cudf.hive.preload-column-chunks false
  # The worker configs already carry cudf.exchange=true, a per-worker
  # cudf.exchange.server.port and cudf.intra_node_exchange=true; the coordinator only
  # names the UCX transport when the native_cudf_exchange_enabled session property is set.
  if [[ $EXCHANGE == ucx ]]; then
    setprop $W/config_native.properties ucxx.error_handling false
    setprop $W/config_native.properties ucxx.blocking_progress false
  fi
  # Extra worker properties for experiments, e.g.
  # EXTRA_WORKER_PROPERTIES="cudf.exchange_compression=fused-for-bitpacked".
  for kv in ${EXTRA_WORKER_PROPERTIES:-}; do
    setprop $W/config_native.properties "${kv%%=*}" "${kv#*=}"
  done
  # Extra worker Hive catalog properties for experiments, e.g.
  # EXTRA_WORKER_HIVE_PROPERTIES="parquet.reader.chunk-read-limit=536870912".
  for kv in ${EXTRA_WORKER_HIVE_PROPERTIES:-}; do
    setprop $W/catalog/hive.properties "${kv%%=*}" "${kv#*=}"
  done
done
C=$G/etc_coordinator/config_native.properties
setprop $C join-max-broadcast-table-size 20788MB
setprop $C node-scheduler.schedule-splits-based-on-task-load true
setprop $C exchange.max-buffer-size 512MB
setprop $C exchange.max-response-size 64MB
setprop $C sink.max-buffer-size 512MB
setprop $C query.max-execution-time 100m
# Extra coordinator properties for experiments, e.g.
# EXTRA_COORDINATOR_PROPERTIES="join-max-broadcast-table-size=2GB".
for kv in ${EXTRA_COORDINATOR_PROPERTIES:-}; do
  setprop $C "${kv%%=*}" "${kv#*=}"
done
# GE POC (mgara, 2026-11-13): coordinator Hive catalog properties, e.g. the temporary table format.
H=$G/etc_coordinator/catalog/hive.properties
for kv in ${EXTRA_COORDINATOR_HIVE_PROPERTIES:-}; do
  setprop $H "${kv%%=*}" "${kv#*=}"
done
# g7.24xlarge (mgara, 2026-11-17): generate_presto_config.sh sizes the Java heap at 90 % of host RAM (-Xmx330G here).
# The four workers share this host, and the kernel OOM-killed the coordinator at 213 GB RSS during Q5. Cap the heap the
# way patch_ci_configs.sh does (same sed; etc_common/jvm.config is read only by the Java coordinator).
COORD_HEAP_GB=${COORD_HEAP_GB:-16}
sed -i "s/-Xmx[0-9]*G/-Xmx${COORD_HEAP_GB}G/;s/-Xms[0-9]*G/-Xms${COORD_HEAP_GB}G/" $G/etc_common/jvm.config
# The coordinator refuses to start when headroom + max total query memory per node exceed the heap, so derive both
# from the capped heap with the generator's percentages (params.json: headroom 0.2 of heap, total 0.8 of heap,
# max memory per node 0.9 of total).
coord_total_gb=$(( COORD_HEAP_GB * 8 / 10 ))
setprop $C memory.heap-headroom-per-node $(( COORD_HEAP_GB * 2 / 10 ))GB
setprop $C query.max-total-memory-per-node ${coord_total_gb}GB
setprop $C query.max-memory-per-node $(( coord_total_gb * 9 / 10 ))GB

# 3. Start the cluster with the configs above.
# Local experiment hook: PRESTO_PROFILE_ARGS starts the workers under nsys with these arguments,
# e.g. PRESTO_PROFILE_ARGS="-t nvtx,cuda --cuda-memory-usage=true".
profile_args=()
[[ -n ${PRESTO_PROFILE_ARGS:-} ]] && profile_args=(--profile --profile-args "$PRESTO_PROFILE_ARGS")
./start_native_gpu_presto.sh --skip-generate-config -w "$NUM_GPU_WORKERS" -g "$GPU_LIST" --kvikio-threads 16 --num-drivers 2 \
  "${profile_args[@]}"

# 4. The start script does not wait for the workers; wait until all of them are registered.
for _ in $(seq 150); do
  [[ $(curl -s localhost:8080/v1/node | jq length 2>/dev/null || echo 0) == "$NUM_GPU_WORKERS" ]] && break
  sleep 2
done
echo "Registered workers: $(curl -s localhost:8080/v1/node | jq length)"
# g7.24xlarge (2026-11-17): hard memory limits so a runaway container is OOM-killed alone instead of hanging the host
# (S1d Q9 hung it with 18 GiB left). 4 x 74 GiB + 24 GiB fits the ~337 GiB the host has free with nothing running.
for i in "${GPUS[@]}"; do
  docker update --memory ${WORKER_MEM_LIMIT:-74g} --memory-swap ${WORKER_MEM_LIMIT:-74g} presto-native-worker-gpu-$i > /dev/null
done
docker update --memory ${COORD_MEM_LIMIT:-24g} --memory-swap ${COORD_MEM_LIMIT:-24g} presto-coordinator > /dev/null
docker stats --no-stream --format '{{.Name}} limit {{.MemUsage}}' | grep -E '^presto-'

# 5. Record what one worker (GPU 3 by default) actually runs with.
inspect_worker=presto-native-worker-gpu-${GPUS[$(( NUM_GPU_WORKERS > 3 ? 3 : 0 ))]}
docker inspect "$inspect_worker" --format 'network={{.HostConfig.NetworkMode}}'
docker exec "$inspect_worker" env | grep -E '^(KVIKIO_|UCX_TLS|UCX_NET_DEVICES)' | sort

if [[ $START_ONLY == true ]]; then
  exit 0
fi

# 6. Run the benchmark.
if [[ -z $TAG ]]; then
  TAG="${SCHEMA_NAME}_g7e_48xlarge_${IMAGE_TAG}_${EXCHANGE}_adc_${ASYNC_DATA_CACHE}_${CACHE_MODE}"
  [[ $DISPATCH != SHARED_QUEUE ]] && TAG+="_${DISPATCH,,}"
  [[ $NONTEMPORAL_COPY == false ]] && TAG+=_no_nontemporal_copy
  [[ $NIC_BIND == false ]] && TAG+=_no_nic_bind
  TAG+="_q${QUERIES:-all}_$(date -u +%Y%m%dT%H%M%SZ)"
  TAG=${TAG//[,.-]/_}
fi
# Session properties from the WXD-launch runs. The last two exist only in a coordinator
# built with the Presto UCX exchange and split placement changes.
SESSION=(hive.file_splittable=false schedule_splits_based_on_task_load=true
         hive.node_selection_strategy=SOFT_AFFINITY native_max_split_preload_per_driver=2)
if [[ $EXCHANGE == ucx ]]; then
  SESSION+=(native_cudf_exchange_enabled=true experimental_deterministic_bounded_splits=true)
fi
SESSION_ARGS=()
for p in "${SESSION[@]}"; do
  SESSION_ARGS+=(--session-property "$p")
done
./run_benchmark.sh -b tpch -s "${SCHEMA_NAME}" -i "${ITERATIONS}" -t "${TAG}" -m ${QUERIES:+-q "$QUERIES"} \
  "${SESSION_ARGS[@]}" --cache-mode "${CACHE_MODE}" --skip-drop-cache --skip-analyze-check \
  || echo "run_benchmark.sh reported failures; stopping the cluster anyway"

./stop_presto.sh
