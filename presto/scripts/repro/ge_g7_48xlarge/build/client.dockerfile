# Client image for run_repro.sh on a host without the Docker Compose plugin (the g7 AMI has none): CentOS Stream 9
# with Python 3, git, curl and Compose v5.5.0 (checked against its published sha256). The host's docker CLI, Docker
# socket and AWS CLI are mounted in at run time (README.md, "Run host").
FROM quay.io/centos/centos:stream9
RUN dnf install -y -q python3 python3.12 python3.12-pip procps-ng jq iproute findutils hostname which git tar gzip && dnf clean all
RUN mkdir -p /usr/local/lib/docker/cli-plugins && \
    curl -fsSL -o /usr/local/lib/docker/cli-plugins/docker-compose \
      https://github.com/docker/compose/releases/download/v5.5.0/docker-compose-linux-x86_64 && \
    echo "c57ab918abd5b05ca7e7d0f275875dd1330a695074f309dc9eab1b49efafcd4b  /usr/local/lib/docker/cli-plugins/docker-compose" | sha256sum -c - && \
    chmod 755 /usr/local/lib/docker/cli-plugins/docker-compose
