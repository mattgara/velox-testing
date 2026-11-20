# Sample statistics provider

The coordinator of this repro plans with the sample statistics provider, a Presto plugin on the presto branch
`repro/ge-g7-48s/sample-stats` (modules `presto-sample-stats`, `presto-sample-stats-duckdb`,
`presto-sample-stats-plugin`). This page documents the plugin and the two tools here that go with it,
`sample_tables.py` and `smoke_check.py`.

## What it does

Presto's cost-based planner chooses join orders and join distribution from table statistics. For filters, joins and
aggregations it can only guess selectivities from those statistics (for example a `LIKE '%green%'` filter or a
`HAVING sum(...) > 300`), and wrong guesses give slow or memory-hungry plans on large scale factors. History-based
optimization fixes the guesses with the row counts of earlier runs of the same query, which needs a warm-up run of
every query and a statistics store.

The provider gives the planner the same kind of estimates without history. At planning time Presto asks the
history-based statistics provider (`HistoryBasedPlanStatisticsProvider` SPI) for the output of each plan node.
Statistics that Presto recorded for the node in earlier runs come first. Otherwise, for a node over one table (a scan
with its pushed-down filters, then filters, projections and aggregations), a fragment engine evaluates the subtree on
a small sample of the table and the provider scales the row count to the full table. By default the provider
estimates filter and projection nodes only.

In this repro the coordinator records nothing (`optimizer.track-history-based-plan-statistics=false`), so every query
plans from the samples.

| Module | Contents |
|---|---|
| `presto-sample-stats` | the provider (recorded history first, then sample estimates) and the fragment engine interface |
| `presto-sample-stats-duckdb` | the `duckdb` fragment engine: translates a fragment to SQL and runs it in an embedded DuckDB |
| `presto-sample-stats-plugin` | the coordinator plugin; picks the engine named by `engine` from the engines in its directory |

## Build and install

1. Build the plugin on the sample-stats branch (the rest of Presto is built too, `-am`):

   ```bash
   ./mvnw clean install -DskipTests -Dair.check.skip-all=true -pl presto-sample-stats-plugin -am
   ```

   The plugin directory is `presto-sample-stats-plugin/target/presto-sample-stats-plugin-<version>`.

2. With a cluster running that serves the analyzed tables, write the samples (needs pyarrow). The default sample size
   is 100,000 rows per table:

   ```bash
   python3 sample_tables.py -s <schema> -o <samples dir> -m <hive metastore dir>
   ```

   Tables of at most twice the sample size are copied whole. Larger tables keep the rows whose key is a multiple of
   a prime, so each sampled key keeps all of its rows (whole orders of `lineitem`, for example). The key is the
   table's first integer column unless `--key TABLE=COLUMN` names another.

3. Put the plugin directory in the coordinator's `plugin/sample-stats`, the samples and the provider settings in a
   directory, and point `PRESTO_SAMPLE_STATS_CONFIG` at the settings file. `coordinator_overlay.dockerfile` does this
   for the repro image (samples in `/opt/sample-stats`). Leave out any other history-based statistics provider
   (Presto accepts one) and turn on `optimizer.use-history-based-plan-statistics`.

4. Check that the coordinator plans with the provider:

   ```bash
   python3 smoke_check.py --schema <schema>
   ```

   It fails if a filter that table statistics cannot estimate gets no estimate from the provider. The coordinator log
   also warns once per reason when a node the provider should answer gets no estimate.

## Configuration

`sample_tables.py` writes `sample-stats.properties` into the samples directory if it does not exist. The repro image
uses `sample-stats-dev.properties` (this directory) instead.

| Property | Default | Meaning |
|---|---|---|
| `sample.dir` | the directory of the properties file | samples and `tables.properties` |
| `engine` | `duckdb` | the fragment engine that evaluates fragments on the samples |
| `node.types` | `FilterNode,ProjectNode` | plan nodes the provider estimates from the samples |
| `history.record` | `true` | keep the statistics Presto records from finished queries and prefer them over sample estimates |
| `history.max-nodes` | `100000` | the most plan nodes whose recorded statistics are kept (in memory) |
| `log.file` | none | one line per estimate, for checking what the provider answered |

## Limitations

- Estimates are only as good as the samples. A predicate that matches no sampled row is estimated at half a sample
  row, scaled to the table (rare rather than empty).
- Nodes over more than one table (joins) and subtrees with constructs the translator does not cover (for example
  window functions) get no estimate, and the planner uses its own.
- The samples describe the data when they were written. Write them again after the tables change.
- With Hive filter pushdown (`hive.pushdown-filter-enabled=true`) filters move into the table scan. Add
  `TableScanNode` to `node.types` on such clusters, or the provider has nothing to estimate.
- Recorded statistics live in coordinator memory and are lost on restart.
