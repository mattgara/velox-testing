# Coordinator image for the GE repro (README.md, "Coordinator image"): the Presto Java coordinator built from the
# Presto base commit, with two jars replaced by the ones built from the coordinator branch, plus the sample statistics
# plugin and its samples.
# Build context: presto-main-base-0.301-SNAPSHOT.jar and presto-hive-0.301-SNAPSHOT.jar (coordinator branch),
# plugin/ (presto-sample-stats-plugin-0.301-SNAPSHOT directory from the sample-stats branch), samples/ (build/samples.md5)
# and sample-stats-dev.properties (this directory).
ARG BASE
FROM ${BASE}
COPY presto-hive-0.301-SNAPSHOT.jar /opt/presto-server/plugin/hive-hadoop2/presto-hive-0.301-SNAPSHOT.jar
COPY presto-main-base-0.301-SNAPSHOT.jar /opt/presto-server/lib/presto-main-base-0.301-SNAPSHOT.jar
# The base's own sample-stats plugin directory, if any, is set aside (Presto accepts one statistics provider). This line
# is kept exactly as in the verified build.
RUN mkdir -p /opt/tbdel && if [ -d /opt/presto-server/plugin/sample-stats ]; then mv /opt/presto-server/plugin/sample-stats /opt/tbdel/sample-stats-base; fi
COPY plugin /opt/presto-server/plugin/sample-stats
COPY samples /opt/sample-stats
COPY sample-stats-dev.properties /opt/sample-stats/sample-stats-dev.properties
ENV PRESTO_SAMPLE_STATS_CONFIG=/opt/sample-stats/sample-stats-dev.properties
