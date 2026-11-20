# Grouped execution on 8 GPUs: g7.48xlarge TPC-H SF3000 repro

This directory reproduces one result: the 22 TPC-H queries at scale factor 3000 on one AWS g7.48xlarge
(8x RTX PRO 4500), with Presto's grouped execution and its exchanges kept in the GPU workers' exchange store, take
**48.28 s** of warm time in total (reference run of 2026-11-18). Every query result matches the reference checksums.

- "Run" reproduces the result from built images with `run_repro.sh`, which never builds anything.
- "Build" documents how to build the two images from source, with every assumption of the build.

## Run

From the directory holding a git checkout of this branch, on a g7.48xlarge set up as in "Run host":

```bash
velox-testing/presto/scripts/repro/ge_g7_48xlarge/run_repro.sh <image tag> [output dir]
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
| from scratch with "Build steps" 1-9, 2026-11-20 | built with this README | 48.30 s | all equal |

For scale: the same 22 queries without grouped execution on a g7e.48xlarge (4 RTX PRO 6000 GPUs) take 56.16 s, so the
result is 0.86x that time.

### Run host

Machine:

- AWS g7.48xlarge in us-east-2 (the data's region): 8 RTX PRO 4500 Blackwell Server Edition GPUs (32 GB, sm_120),
  192 vCPUs, 768 GiB of host memory in two NUMA nodes (GPUs 0-3 on node 0, GPUs 4-7 on node 1). Nothing else runs on
  the GPUs.
- Operating system image: Amazon Linux 2023 with the NVIDIA driver (tested: 595.91.07) and CUDA, the EFA driver, Docker
  (tested: 25.0.16) with the NVIDIA Container Toolkit, and the AWS CLI v2. The tested instance was launched from an
  internal image of that kind.
- Two EFA interfaces, one per NUMA node, in a security group that allows all inbound traffic from itself and all
  outbound traffic (EFA needs the self-referencing rule). The launcher gives GPUs 0-3 the node 0 device and GPUs 4-7
  the node 1 device (tested names: `rdmap83s0` and `rdmap176s0`).
- An instance profile that can read `s3://rapids-tpch`. The launcher exports the instance credentials to the workers,
  which read Parquet from S3 with KvikIO.
- IMDSv2, a 1000 GB gp3 root volume (images and logs; the data stays on S3).

Launch, then add the second EFA interface while the instance is stopped:

```bash
aws ec2 run-instances --region us-east-2 --instance-type g7.48xlarge --image-id <AMI> \
  --iam-instance-profile Name=<profile> --metadata-options HttpTokens=required \
  --network-interfaces "DeviceIndex=0,NetworkCardIndex=0,InterfaceType=efa,SubnetId=<subnet>,Groups=<efa group>" \
  --block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=1000,VolumeType=gp3}'
aws ec2 stop-instances --instance-ids <instance>
aws ec2 create-network-interface --interface-type efa --subnet-id <subnet> --groups <efa group>
aws ec2 attach-network-interface --instance-id <instance> --network-interface-id <new interface> \
  --network-card-index 1 --device-index 1
aws ec2 start-instances --instance-ids <instance>
```

Software on the machine that runs the scripts:

- Docker Compose v2 (tested: 5.5.0), git, curl, the AWS CLI v2 on `PATH`.
- Python 3.12 with `venv`, and access to PyPI: starting a cluster renders the Compose template in a Python 3.12
  virtual environment with Jinja2 (`scripts/py_env_functions.sh`). The repro's own Python scripts need only the
  standard library; the sample writer (build step 7) needs pyarrow.
- A git checkout of this branch (velox-testing's scripts expect one).

The g7 image has no Compose plugin, so the tested runs used a client container from `build/client.dockerfile`
(CentOS Stream 9 with Python 3.12, git and Compose 5.5.0; the host's docker CLI and AWS CLI mounted in). The
launcher's bind mounts use host paths, so the working directory must be mounted at the same path inside the container;
it also serves as the home directory there (for pip):

```bash
docker build -t ge-repro-client -f velox-testing/presto/scripts/repro/ge_g7_48xlarge/build/client.dockerfile velox-testing/presto/scripts/repro/ge_g7_48xlarge/build
docker run -d --name ge-repro-client --network host -u $(id -u):$(stat -c %g /var/run/docker.sock) -e HOME=$PWD \
  -v /var/run/docker.sock:/var/run/docker.sock -v /usr/bin/docker:/usr/local/bin/docker:ro \
  -v /usr/local/aws-cli:/usr/local/aws-cli:ro -v $PWD:$PWD -w $PWD --entrypoint sleep ge-repro-client infinity
docker exec -e PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/usr/local/aws-cli/v2/current/bin ge-repro-client \
  velox-testing/presto/scripts/repro/ge_g7_48xlarge/run_repro.sh <image tag>
```

(run from the directory that holds the `velox-testing` checkout). Images built on another machine move with
`docker save <images> | zstd` and `zstd -dc | docker load`.

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

Inputs used without changes:

| Input | Pin |
|---|---|
| Presto base of the coordinator | 563e7787ee (kingcrimsontianyu/presto `wxd-upstream`; also in mattgara/presto as an ancestor of the coordinator branch) |
| UCX | github.com/openucx/ucx pull request 11979, head 961c63b57e |
| Velox's other dependencies (rapids-cmake, RMM, KvikIO, ...) and the dependencies image's libraries | the commits and checksums in the Velox branch's `CMake/resolve_dependency_modules/` and `scripts/` |

### Build steps

Everything below runs in one empty working directory, as the same user throughout. Steps 1-6 need an x86_64 Linux
host with Docker and its buildx plugin (BuildKit; steps 2 and 3 use `RUN --mount`), and network access to GitHub,
Maven Central and the other download sites of the dependency scripts. Steps 7-9 run on the g7.48xlarge (they need the
data), in the client container of "Run host" if the host has no Compose; that container has no buildx, which only
step 8's plain Dockerfile tolerates, so run steps 1-6 on the host itself. Images built on another machine move with
`docker save <images> | zstd` and `zstd -dc | docker load`.

Tested from scratch on a g7.48xlarge on 2026-11-20 by running these code blocks (with `NUM_THREADS=64`): steps 1-6
took about 40 minutes (dependencies image 25, worker 10, UCX 2, Java 7 while the dependencies image built), steps 7-8
about 3 minutes, and step 9 gave 48.30 s with every check passing ("Expected result"). The test found three gaps that
are fixed here: the ownership hand-back in steps 4 and 5, and the client container's `HOME` and `PATH` in "Run host".

1. Sources. One Presto clone serves the worker, the coordinator base, the coordinator jars and the plugin:

   ```bash
   git clone https://github.com/mattgara/presto.git presto
   git clone --depth 1 -b repro/ge-g7-48s/velox https://github.com/mattgara/velox.git velox
   git clone -b repro/ge-g7-48s/velox-testing https://github.com/mattgara/velox-testing.git velox-testing
   R=velox-testing/presto/scripts/repro/ge_g7_48xlarge
   ```

2. Dependencies image: the toolchain and third-party libraries the worker compiles against, built the way
   velox-testing's CI and `presto/scripts/build_centos_deps_image.sh` build it: Presto's
   `centos-dependency.dockerfile` with Velox's dependency scripts and CMake files. CUDA 12.9.

   ```bash
   mkdir -p deps-ctx/velox
   git -C presto archive origin/repro/ge-g7-48s/worker-presto presto-native-execution | tar -x -C deps-ctx --strip-components=1
   git -C velox archive HEAD scripts CMake | tar -x -C deps-ctx/velox
   docker build --build-arg CUDA_VERSION=12.9 -f deps-ctx/scripts/dockerfiles/centos-dependency.dockerfile \
     -t ge-repro-deps:cuda12.9 deps-ctx
   ```

   The verified build used the image velox-testing's CI published for the same purpose
   (`ghcr.io/rapidsai/velox-testing-images:presto-deps-30c1635-velox-7a876d3-cuda12.9-20261113-pinned-43369494090`,
   amd64 manifest `sha256:78a4723b293947eb1dcb7a421bb3ec87c244ee670a2c3736343a3cbf7f943842`, a private package). Pulling
   it instead of step 2 saves the build; a local build gets the libraries' current packages, so it is not byte
   identical. The build downloads sources and jars from many sites (GitHub, Maven Central, Apache mirrors) without
   retries, in one long step (25 minutes on a g7.48xlarge); a rate limit or a cut-off download fails that step near
   its end (seen: HTTP 429 from Maven Central on a host it rate-limits). Run it again, from a host that is not
   rate-limited.

3. Worker image: velox-testing's `native_build.dockerfile` on the dependencies image, with the sources as plain trees
   side by side (the Velox sources come from the Velox branch, not from Presto's `velox` submodule, which points at
   780d58a0ca). CUDA code for sm_120 only. `NUM_THREADS` is the number of compile jobs: raise it on a host with more
   cores and memory. The build keeps its objects in a BuildKit cache mount at `BUILD_BASE_DIR`, which `--no-cache`
   does not clear: give each clean build a new `BUILD_BASE_DIR`.

   ```bash
   mkdir -p ctx/presto ctx/velox ctx/velox-testing
   git -C presto archive origin/repro/ge-g7-48s/worker-presto | tar -x -C ctx/presto
   git -C velox archive HEAD | tar -x -C ctx/velox
   git -C velox-testing archive HEAD | tar -x -C ctx/velox-testing
   printf '**/.git\n' > ctx/.dockerignore
   docker build --no-cache -f ctx/velox-testing/presto/docker/native_build.dockerfile \
     --build-arg BASE_IMAGE=ge-repro-deps:cuda12.9 --build-arg GPU=ON --build-arg BUILD_TYPE=release \
     --build-arg CUDA_ARCHITECTURES=120 --build-arg NUM_THREADS=32 --build-arg BUILD_BASE_DIR=/ge_repro_build_$(date +%s) \
     --build-arg ENABLE_SCCACHE=OFF --build-arg SCCACHE_NO_DIST_COMPILE=1 \
     -t presto-native-worker-gpu:ge-repro-ucx122 ctx
   ```

4. UCX: build UCX from the pull request head inside the dependencies image (for its CUDA and toolchain), then put it
   over the worker image's UCX 1.22.0 with `build/ucx_variant.dockerfile`:

   ```bash
   mkdir -p ucx
   docker run --name ge-repro-ucx -v $PWD/ucx:/ucx -e OWNER=$(id -u):$(id -g) --entrypoint bash ge-repro-deps:cuda12.9 -c '
     cd /tmp && git clone https://github.com/openucx/ucx.git && cd ucx
     git fetch origin pull/11979/head && git checkout 961c63b57e
     ./autogen.sh && ./contrib/configure-release --prefix=/ucx/pr11979 --enable-cma --enable-mt --with-gnu-ld \
       --with-rdmacm --with-verbs --without-go --without-java --with-cuda=/usr/local/cuda
     make -j32 && make install && chown -R $OWNER /ucx'
   docker build -f $R/build/ucx_variant.dockerfile --build-arg BASE_IMAGE=presto-native-worker-gpu:ge-repro-ucx122 \
     --build-arg UCX_DESCRIPTION="openucx/ucx#11979 head 961c63b57e" -t presto-native-worker-gpu:ge-repro ucx/pr11979
   ```

5. Java: the coordinator is the Presto base commit's coordinator with two jars replaced, not a full build of the
   coordinator branch (that branch changes only `presto-main-base` and `presto-hive`, plus their documentation and one
   expected-plan test file). The sample statistics plugin comes from the sample-stats branch, which is based on a
   newer Presto master (a73a3d8e98) and loads into the coordinator through the statistics provider SPI
   (`build/sample_stats.md`). One container builds the three in turn in the Presto clone (git-commit-id-plugin needs
   the `.git` directory), with Java 17, Node.js 22 and yarn 1.22.22 for `presto-ui`:

   ```bash
   docker run --name ge-repro-java -v $PWD:/w -w /w/presto -e PRESTO_VERSION=testing -e OWNER=$(id -u):$(id -g) \
     eclipse-temurin:17-jdk-jammy bash -c '
     set -e
     apt-get update -qq && apt-get install -y -qq git curl > /dev/null
     curl -fsSL https://deb.nodesource.com/setup_22.x | bash - > /dev/null && apt-get install -y -qq nodejs > /dev/null
     npm install -g yarn@1.22.22 > /dev/null
     git config --global --add safe.directory "*"
     F="-DskipTests -Dair.check.skip-all=true --no-transfer-progress -T 16"
     git checkout -q --detach 563e7787ee27fad295ee196244d11cef694a2722
     ./mvnw clean install $F -pl "!presto-docs" -pl "!presto-openapi"
     cp -r docker /w/coord-base
     cp presto-server/target/presto-server-*.tar.gz /w/coord-base/presto-server-testing.tar.gz
     cp presto-function-server/target/presto-function-server-*executable.jar /w/coord-base/presto-function-server-executable.jar
     cp presto-function-server/target/presto-function-server-*executable.jar /w/coord-base/presto-function-server-testing-executable.jar
     cp presto-cli/target/presto-cli-*-executable.jar /w/coord-base/presto-cli-testing-executable.jar
     chmod +r /w/coord-base/presto-cli-testing-executable.jar
     git checkout -q --detach origin/repro/ge-g7-48s/coordinator
     ./mvnw clean install $F -pl presto-main-base,presto-hive -am
     mkdir -p /w/overlay
     cp presto-main-base/target/presto-main-base-0.301-SNAPSHOT.jar presto-hive/target/presto-hive-0.301-SNAPSHOT.jar /w/overlay/
     git checkout -q --detach origin/repro/ge-g7-48s/sample-stats
     ./mvnw clean install $F -pl presto-sample-stats-plugin -am
     cp -r presto-sample-stats-plugin/target/presto-sample-stats-plugin-0.301-SNAPSHOT /w/overlay/plugin
     chown -R $OWNER /w/presto /w/coord-base /w/overlay'
   ```

   The containers in steps 4 and 5 run as root (they install packages) and give what they write back to the calling
   user, who runs steps 7 and 8. The base copies are what `presto/scripts/build_presto_java_package.sh` does. Any
   Maven Central mirror works (the artifacts are the same). A download that the server cuts off fails the build;
   adding `-Daether.connector.http.retryHandler.count=5` to `F` retries it.

6. Coordinator base image, from the base commit's `docker/` directory:

   ```bash
   docker build --build-arg PRESTO_VERSION=testing -t presto-coordinator:ge-repro-base coord-base
   ```

7. Samples for the sample statistics provider, on the g7.48xlarge from the working directory, with the software of
   "Run host" (in the client container: `docker exec -e PATH=... ge-repro-client bash -c '<these commands>'`, with
   the `PATH` shown there). Fetch the metastore, start a cluster from the new worker and the base coordinator, write
   the samples, stop the cluster:

   ```bash
   python3.12 -m pip install --user pyarrow
   aws s3 cp --quiet --recursive s3://rapids-tpch/presto-gpu/sf3k_decimal_hive_flat/hive_metastore/ velox-testing/presto/docker/.hive_metastore/
   docker tag presto-native-worker-gpu:ge-repro presto-native-worker-gpu:ge-repro-sampling
   docker tag presto-coordinator:ge-repro-base presto-coordinator:ge-repro-sampling
   (cd velox-testing/presto/scripts/repro && PRESTO_GPU_IDS=0,1,2,3,4,5,6,7 WORKER_SYSTEM_MEMORY_GB=32 \
     WORKER_QUERY_MEMORY_GB=24 WORKER_MEM_LIMIT=80g COORD_MEM_LIMIT=24g ./gepoc_run_tpch_g7_24xlarge.sh --start-only \
     --no-nic-bind --image-tag ge-repro-sampling --compose-project ge-repro -s tpch_sf3k_decimal_hive_flat_s3)
   python3.12 $R/build/sample_tables.py -s tpch_sf3k_decimal_hive_flat_s3 -o samples -m velox-testing/presto/docker/.hive_metastore
   (cd velox-testing/presto/scripts && COMPOSE_PROJECT_NAME=ge-repro PRESTO_IMAGE_TAG=ge-repro-sampling ./stop_presto.sh)
   ```

   One sample per table, at most 100,000 rows. A large table keeps the rows whose key is a multiple of a prime (for
   example `l_orderkey % 180001 = 0`), so the sampled rows are fixed by the data. `build/samples.md5` lists the files
   of the verified image: `tables.properties` and `sample-stats.properties` must match it exactly. The Parquet files
   differ in bytes (the writer and row order differ); in the 2026-11-20 test they held the same schema and the same
   rows as the verified image's, table by table.

8. Coordinator image: the base with the two jars, the plugin, the samples and the provider settings:

   ```bash
   cp -r samples overlay/samples && cp $R/build/sample-stats-dev.properties overlay/
   docker build -f $R/build/coordinator_overlay.dockerfile --build-arg BASE=presto-coordinator:ge-repro-base \
     -t presto-coordinator:ge-repro overlay
   ```

9. Run: `$R/run_repro.sh ge-repro` (see "Run").

### Verified images

| Image | Original (2026-11-17) | Rebuilt from the branches (2026-11-19) | Built with "Build steps" (2026-11-20) |
|---|---|---|---|
| presto-native-worker-gpu | 251b9b3ef8cb | 1d0c6fdb8116 | 101706258604 |
| presto-coordinator | faac8fafc450 | bcced13947db | a570cffafe33 |

IDs are as shown by `docker images` on the g7 after `docker load`. A new build gets new IDs (timestamps), so the IDs
only name these builds; `run_repro.sh` is the check for a new build. The original coordinator jars were assembled from
class overlays; the jars rebuilt from the branches contain the same classes (byte for byte, or the same bytecode up to
constant pool order). The jars built with "Build steps" are byte-identical, class for class, to those in bcced13947db.
All of these images gave the results in "Expected result".

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
