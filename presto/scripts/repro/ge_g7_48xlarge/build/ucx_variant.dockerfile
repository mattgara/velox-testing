# Worker image variant with a different UCX build in place of the image's UCX 1.22.0. The build context is
# a UCX install prefix (README.md, "UCX"). The 1.22.0 files are moved to /opt/ucx-orig
# inside the image, the new libraries are installed where the old ones were (/usr/local/lib and the copies in
# /usr/lib64/presto-native-libs, which the loader searches first), and UCX_MODULE_DIR points the new UCX at its
# transport modules, since its compiled-in module path is the build prefix.
ARG BASE_IMAGE
FROM ${BASE_IMAGE}
ARG UCX_DESCRIPTION
COPY . /opt/ucx-variant/
RUN set -eux; \
    mkdir -p /opt/ucx-orig/usr-local-lib /opt/ucx-orig/presto-native-libs; \
    mv /usr/local/lib/libuc[mpst]* /usr/local/lib/ucx /opt/ucx-orig/usr-local-lib/; \
    mv /usr/lib64/presto-native-libs/libuc[mpst]* /opt/ucx-orig/presto-native-libs/; \
    cp -a /opt/ucx-variant/lib/libuc[mpst]* /opt/ucx-variant/lib/ucx /usr/local/lib/; \
    cp -a /opt/ucx-variant/lib/libuc[mpst]*.so* /usr/lib64/presto-native-libs/; \
    cp -a /opt/ucx-variant/bin/. /usr/local/bin/; \
    ldconfig; \
    UCX_MODULE_DIR=/usr/local/lib/ucx /usr/local/bin/ucx_info -v; \
    ldd /usr/bin/presto_server | grep -E "libuc[mpst]"
ENV UCX_MODULE_DIR=/usr/local/lib/ucx
LABEL velox-testing.ucx="${UCX_DESCRIPTION}"
