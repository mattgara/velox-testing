# Grouped execution on 8 GPUs: g7.48xlarge TPC-H SF3000 repro

This directory reproduces one result: the 22 TPC-H queries at scale factor 3000 on one AWS g7.48xlarge
(8x RTX PRO 4500), with Presto's grouped execution and its exchanges kept in the GPU workers' exchange store, take
**48.28 s** of warm time in total (reference run of 2026-11-18). Every query result matches the reference checksums.

- "Run" reproduces the result from built images with `run_repro.sh`, which never builds anything.
- "Build" documents how to build the two images from source, with every assumption of the build.

## Run

From a git checkout of this branch on a g7.48xlarge set up as in "Run host":

```bash
presto/scripts/repro/ge_g7_48xlarge/run_repro.sh <image tag> [output dir]
```

The script runs `presto-coordinator:<image tag>` and `presto-native-worker-gpu:<image tag>`. It takes about
10 minutes:

1. Checks that both images exist and that no Presto cluster is running.
2. Copies the Hive metastore of the data from S3 (`$DATA/hive_metastore/`, default
   `s3://rapids-tpch/presto-gpu/sf3k_decimal_hive_flat`) into `presto/docker/.hive_metastore` if it is not there, and
   checks it against `reference/hive_metastore.md5`.
3. Starts a coordinator and 8 GPU workers with `../gepoc_run_tpch_g7_24xlarge.sh --start-only` and the settings in
   the script (see "Settings").
4. Runs the 22 queries 3 times each with `run_queries.py`. The worker caches are cleared before each query's first run.
5. Copies the server logs, stops the cluster, and checks three things:
   - the cluster configuration the servers log equals `reference/cluster_config.txt` (107 settings);
   - every run of every query succeeded and its result checksum equals the reference;
   - the total warm time is within 3 % of the reference (`TOLERANCE` changes the bound).

Exit status 0 means all three checks passed, 1 a setup failure or a wrong result, 2 right results but a time outside
the tolerance. `check.txt` in the output directory has the per-query table; `containers.txt` the container memory
limits and UCX, cuDF and KvikIO environment.

### Expected result

Warm time of a query = the faster of runs 1 and 2 (run 0 reads the data from S3 after the cache reset). The time is
the coordinator's elapsed time.

| Run | Images | Total warm time | Checksums |
|---|---|---|---|
| reference, 2026-11-18 (`reference/s1d_20261118.json`) | original | 48.28 s | reference |
| same-day A/B, 2026-11-19 | original | 48.48 s, 48.54 s | all equal |
| same-day A/B, 2026-11-19 | rebuilt from the branches below | 48.33 s, 48.10 s | all equal |
| `run_repro.sh`, 2026-11-20, fresh checkout | rebuilt | 48.05 s | all equal |

For scale: the same 22 queries without grouped execution on a g7e.48xlarge (4 RTX PRO 6000 GPUs) take 56.16 s, so the
result is 0.86x that time.

### Run host

- AWS g7.48xlarge in us-east-2: 8 RTX PRO 4500 Blackwell Server Edition GPUs (32 GB, sm_120), 192 vCPUs, 768 GiB of
  host memory in two NUMA nodes (GPUs 0-3 on node 0, GPUs 4-7 on node 1). Nothing else runs on the GPUs.
- Two EFA interfaces, one per NUMA node: the primary interface on network card 0 created as EFA, and a second EFA
  interface attached as network card 1, device index 1. On the tested instance the devices are `rdmap83s0` (node 0)
  and `rdmap176s0` (node 1). The launcher gives GPUs 0-3 the node 0 device and GPUs 4-7 the node 1 device. EFA needs
  a security group that allows all traffic from itself, on both interfaces.
- An instance profile that can read the data bucket. The launcher exports the instance credentials to the workers,
  which read Parquet from S3 with KvikIO.
- NVIDIA driver 595.91.07, Docker 25.0.16 with the NVIDIA container runtime.
- On the machine that runs the script: Docker Compose v2 (tested with 5.5.0), Python 3.9 or later (standard library
  only), the AWS CLI v2 on `PATH`, curl and git. The g7 AMI has no Compose plugin, so the tested runs used a client
  container from `build/client.dockerfile`. The launcher's bind mounts use host paths, so the checkout must be mounted
  at the same path inside the container:

  ```bash
  docker build -t ge-repro-client -f presto/scripts/repro/ge_g7_48xlarge/build/client.dockerfile presto/scripts/repro/ge_g7_48xlarge/build
  cd .. && docker run -d --name ge-repro-client --network host -u $(id -u):$(stat -c %g /var/run/docker.sock) -e HOME=$HOME \
    -v /var/run/docker.sock:/var/run/docker.sock -v /usr/bin/docker:/usr/local/bin/docker:ro \
    -v /usr/local/aws-cli:/usr/local/aws-cli:ro -v $PWD:$PWD -w $PWD --entrypoint sleep ge-repro-client infinity
  docker exec -e PATH=/usr/local/bin:/usr/bin:/usr/local/aws-cli/v2/current/bin ge-repro-client \
    velox-testing/presto/scripts/repro/ge_g7_48xlarge/run_repro.sh <image tag>
  ```

- Images built on another machine move with `docker save <images> | zstd` and `zstd -dc | docker load`.

Data: TPC-H SF3000 with decimal columns, Parquet, tables not bucketed, at
`s3://rapids-tpch/presto-gpu/sf3k_decimal_hive_flat` (us-east-2). The Hive metastore next to it holds the table
locations and the `ANALYZE` statistics the planner uses.

### Settings

All settings are in `run_repro.sh`:

- One worker per GPU. Host memory per worker: 32 GB system memory, 24 GB query memory, an 80 GiB container limit.
  The exchange store keeps up to 3 GiB per worker on the GPU and 36 GiB in host memory. The coordinator container is
  limited to 24 GiB.
- UCX exchange without GPU-direct RDMA (`UCX_IB_GPU_DIRECT_RDMA=n`, staging through host memory with
  `UCX_RNDV_FRAG_MEM_TYPES_OVERRIDE=host`). With GPU-direct RDMA the 8-GPU runs were slow: transfers between the two
  EFA cards lost packets.
- Planner statistics: history-based planning answered by the sample statistics plugin in the coordinator image
  (`optimizer.use-history-based-plan-statistics=true`, `build/sample_stats.md`). Nothing is recorded between runs
  (`optimizer.track-history-based-plan-statistics=false`), so every run plans from the samples only.
- The grouped-execution session properties are fixed values (`SESSION` in the script). The two memory-dependent
  values, `exchange_materialization_memory_threshold=9280MB` and `exchange_materialization_bucket_memory_fraction=0.082759`,
  come from a 31 GiB per-GPU budget.

## Build

### Sources

Code that differs from public Presto, Velox, cuDF and velox-testing is on these branches of the forks:

| Repository | Branch | Head | Used for |
|---|---|---|---|
| github.com/mattgara/velox | `repro/ge-g7-48s/velox` | a91334d595 | worker |
| github.com/mattgara/cudf | `local/parquet-reader-skip-copy-when-all-rows-pass-20261023` | bf2290463c | worker (cuDF, fetched by the Velox build) |
| github.com/mattgara/presto | `repro/ge-g7-48s/worker-presto` | 2987516234 | worker (`presto-native-execution`) |
| github.com/mattgara/presto | `repro/ge-g7-48s/coordinator` | ce172992d2 | coordinator: `presto-main-base` and `presto-hive` jars |
| github.com/mattgara/presto | `repro/ge-g7-48s/sample-stats` | bb8a0812f8 | coordinator: sample statistics plugin |
| github.com/mattgara/velox-testing | `repro/ge-g7-48s/velox-testing` | this branch | worker build, launcher, this repro |

The verified images were built from these heads, except sample-stats: its plugin was built from 01eb1ba7f7. The head
after it moves the plugin's scripts and README to this directory, rewords two comments and changes no code.

cuDF is the commit Velox's `CMake/resolve_dependency_modules/cudf.cmake` pins on the Velox branch: a change to the
Parquet reader (return the decoded columns when the read filter keeps every row) on top of rapidsai/cudf pull requests
24494, 24542 and 24261, on cuDF main 568a24b (2026-10-06). Velox downloads it as
`https://github.com/rapidsai/cudf/archive/bf2290463c....tar.gz` and checks the SHA256 in `cudf.cmake`. GitHub serves
the archive of a fork's commit under the upstream name, so the download works while the commit is on the fork branch
above.

Pinned inputs, used without changes:

| Input | Pin |
|---|---|
| Presto base of the coordinator | github.com/kingcrimsontianyu/presto 563e7787ee (`wxd-upstream`) |
| Build dependencies image | `ghcr.io/rapidsai/velox-testing-images:presto-deps-30c1635-velox-7a876d3-cuda12.9-20261113-pinned-43369494090`, amd64 manifest `sha256:78a4723b293947eb1dcb7a421bb3ec87c244ee670a2c3736343a3cbf7f943842` |
| UCX | github.com/openucx/ucx pull request 11979, head 961c63b57e |
| Other Velox dependencies (rapids-cmake, RMM, KvikIO, ...) | the commits and checksums in the Velox branch's `CMake/resolve_dependency_modules/` |

The dependencies image is a private ghcr package: pulling it needs read access to `rapidsai/velox-testing-images`.
Its name carries the Velox commit it was made for (7a876d3); it provides the toolchain and system libraries only, and
the build compiles the Velox branch.

Getting the sources (the Presto trees must be git checkouts, because Presto's Maven build runs git-commit-id-plugin):

```bash
git clone -b repro/ge-g7-48s/velox https://github.com/mattgara/velox.git velox
git clone -b repro/ge-g7-48s/worker-presto https://github.com/mattgara/presto.git presto
git clone -b repro/ge-g7-48s/velox-testing https://github.com/mattgara/velox-testing.git velox-testing
git clone -b repro/ge-g7-48s/coordinator https://github.com/mattgara/presto.git presto-coordinator
git clone -b repro/ge-g7-48s/sample-stats https://github.com/mattgara/presto.git presto-sample-stats
git clone https://github.com/kingcrimsontianyu/presto.git presto-base && git -C presto-base checkout 563e7787ee
```

### Worker image (`presto-native-worker-gpu`)

1. Build context: a directory with `presto/` (worker branch), `velox/` (Velox branch) and `velox-testing/` (this
   branch) side by side, as velox-testing expects. The verified build used plain trees (`git archive` of each branch)
   and a `.dockerignore` of `**/.git`. The Velox sources come from the Velox branch, not from Presto's `velox`
   submodule (the submodule points at 780d58a0ca).
2. Build with `presto/docker/native_build.dockerfile` on the dependencies image, CUDA code for sm_120 only. It needs
   docker buildx (the verified build used a `docker-container` builder limited to 100 GB of memory, with 32 compile
   threads) and network access for the Velox dependencies:

   ```bash
   docker buildx build --load --no-cache -f velox-testing/presto/docker/native_build.dockerfile \
     --build-context base=docker-image://<dependencies image>@sha256:78a4723b293947eb1dcb7a421bb3ec87c244ee670a2c3736343a3cbf7f943842 \
     --build-arg BASE_IMAGE=base --build-arg GPU=ON --build-arg BUILD_TYPE=release --build-arg CUDA_ARCHITECTURES=120 \
     --build-arg NUM_THREADS=32 --build-arg BUILD_BASE_DIR=<fresh build directory> \
     --build-arg ENABLE_SCCACHE=OFF --build-arg SCCACHE_NO_DIST_COMPILE=1 \
     --build-arg PRESTO_SHA=2987516234... --build-arg PRESTO_BRANCH=repro/ge-g7-48s/worker-presto \
     --build-arg VELOX_SHA=a91334d595... --build-arg VELOX_BRANCH=repro/ge-g7-48s/velox \
     -t presto-native-worker-gpu:<tag>-base <build context>
   ```

   The `PRESTO_*` and `VELOX_*` arguments only set provenance labels.
3. UCX: build UCX from the pull request head inside the dependencies image (for its CUDA and toolchain):

   ```bash
   docker run --name ucx-build -v <prefix dir>:/ucx -v <src dir>:/src --entrypoint bash <dependencies image> -c '
     cd /src && git clone https://github.com/openucx/ucx.git && cd ucx
     git fetch origin pull/11979/head && git checkout 961c63b57e
     ./autogen.sh && ./contrib/configure-release --prefix=/ucx/pr11979 --enable-cma --enable-mt --with-gnu-ld \
       --with-rdmacm --with-verbs --without-go --without-java --with-cuda=/usr/local/cuda
     make -j32 && make install'
   ```

   then put it over the worker image's UCX 1.22.0 with `build/ucx_variant.dockerfile` (context = the prefix):

   ```bash
   docker build -f velox-testing/presto/scripts/repro/ge_g7_48xlarge/build/ucx_variant.dockerfile \
     --build-arg BASE_IMAGE=presto-native-worker-gpu:<tag>-base \
     --build-arg UCX_DESCRIPTION="openucx/ucx#11979 head 961c63b57e" -t presto-native-worker-gpu:<tag> <prefix dir>/pr11979
   ```

### Coordinator image (`presto-coordinator`)

The coordinator is the Presto base commit's coordinator with two jars replaced, not a full build of the coordinator
branch. The coordinator branch changes only `presto-main-base` and `presto-hive` (plus their documentation and one
expected-plan test file).

The Java builds ran in `eclipse-temurin:17-jdk-jammy` with git, Node.js 22 and yarn 1.22.22 (for `presto-ui`)
installed, 32 CPUs and 96 GB of memory, and `PRESTO_VERSION=testing` in the environment. Maven flags for every build:
`-DskipTests -Dair.check.skip-all=true --no-transfer-progress -T 16`. Any Maven Central mirror works (the artifacts are
the same).

1. Base, in `presto-base` (as `presto/scripts/build_presto_java_package.sh` does):

   ```bash
   ./mvnw clean install <flags> -pl '!presto-docs' -pl '!presto-openapi'
   cp presto-server/target/presto-server-*.tar.gz docker/presto-server-testing.tar.gz
   cp presto-function-server/target/presto-function-server-*executable.jar docker/presto-function-server-executable.jar
   cp presto-function-server/target/presto-function-server-*executable.jar docker/presto-function-server-testing-executable.jar
   cp presto-cli/target/presto-cli-*-executable.jar docker/presto-cli-testing-executable.jar
   chmod +r docker/presto-cli-testing-executable.jar
   docker build --build-arg PRESTO_VERSION=testing -t presto-coordinator:<tag>-base-unlabeled docker
   docker build -f ../velox-testing/presto/docker/provenance_labels.dockerfile \
     --build-arg BASE_IMAGE=presto-coordinator:<tag>-base-unlabeled --build-arg PRESTO_SHA=563e7787ee27fad295ee196244d11cef694a2722 \
     --build-arg PRESTO_BRANCH=wxd-upstream --build-arg PRESTO_REPOSITORY=https://github.com/kingcrimsontianyu/presto.git \
     --build-arg VELOX_SHA= --build-arg VELOX_BRANCH= --build-arg VELOX_REPOSITORY= \
     -t presto-coordinator:<tag>-base ../velox-testing/presto/docker
   ```

2. Coordinator branch, in `presto-coordinator`: `./mvnw clean install <flags> -pl presto-main-base,presto-hive -am`
   gives `presto-main-base/target/presto-main-base-0.301-SNAPSHOT.jar` and
   `presto-hive/target/presto-hive-0.301-SNAPSHOT.jar`.
3. Sample statistics plugin, in `presto-sample-stats`: `./mvnw clean install <flags> -pl presto-sample-stats-plugin -am`
   gives the directory `presto-sample-stats-plugin/target/presto-sample-stats-plugin-0.301-SNAPSHOT`. That branch is
   based on a newer Presto master (a73a3d8e98); the plugin loads into the 563e7787ee coordinator through the
   statistics provider SPI. See `build/sample_stats.md`.
4. Samples: one sample per table, at most 100,000 rows each, written by `build/sample_tables.py` (needs pyarrow)
   against any running cluster that serves the analyzed tables (for example the images above without the samples):

   ```bash
   python3 build/sample_tables.py -s tpch_sf3k_decimal_hive_flat_s3 -o samples -m presto/docker/.hive_metastore
   ```

   A large table keeps the rows whose key is a multiple of a prime (for example `l_orderkey % 180001 = 0`), so the
   sampled rows are fixed by the data. `build/samples.md5` lists the files of the verified image. `tables.properties`
   must match exactly; the Parquet files can differ in bytes if a different writer produces them.
5. Overlay: a build context with the two jars (step 2), `plugin/` (step 3), `samples/` (step 4) and
   `build/sample-stats-dev.properties`, built with
   `docker build -f build/coordinator_overlay.dockerfile --build-arg BASE=presto-coordinator:<tag>-base -t presto-coordinator:<tag> <context>`.

### Verified images

| Image | Original (2026-11-17) | Rebuilt from the branches (2026-11-19) |
|---|---|---|
| presto-native-worker-gpu | 251b9b3ef8cb | 1d0c6fdb8116 |
| presto-coordinator | faac8fafc450 | bcced13947db |

IDs are as shown by `docker images` on the g7 after `docker load`. A new build gets new IDs (timestamps), so the IDs
only name these builds; `run_repro.sh` is the check for a new build. The original coordinator jars were assembled from
class overlays; the jars rebuilt from the branches contain the same classes (byte for byte, or the same bytecode up to
constant pool order). The rebuilt images gave the A/B and `run_repro.sh` results in "Expected result".

## Files

| File | Contents |
|---|---|
| `run_repro.sh` | the repro |
| `run_queries.py`, `presto_client.py`, `queries.json` | query runner: the 22 queries, cache reset, coordinator elapsed time, md5 of the sorted rows |
| `check_results.py` | result, time and configuration checks |
| `reference/s1d_20261118.json` | the reference run: session properties and every run's time and checksum |
| `reference/cluster_config.txt` | cluster configuration of the verified runs, as the servers log it |
| `reference/hive_metastore.md5` | the metastore files of the data |
| `build/ucx_variant.dockerfile` | UCX layer of the worker image |
| `build/coordinator_overlay.dockerfile`, `build/sample-stats-dev.properties`, `build/samples.md5` | coordinator layer: jars, plugin, samples |
| `build/sample_stats.md`, `build/sample_tables.py`, `build/smoke_check.py` | the sample statistics plugin, its sample writer and its check |
| `build/client.dockerfile` | client container for hosts without Docker Compose |
