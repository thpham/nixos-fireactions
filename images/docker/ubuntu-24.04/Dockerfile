# Multi-target Dockerfile for Firecracker VM runner images
#
# Supports three targets:
#   - github-runner: GitHub Actions with fireactions agent
#   - gitea-runner:  Gitea Actions with fireteact agent
#   - gitlab-runner: GitLab CI with fireglab agent
#
# Build examples:
#   docker build --target github-runner -t ghcr.io/thpham/fireactions-images/ubuntu-24.04-github:latest .
#   docker build --target gitea-runner -t ghcr.io/thpham/fireactions-images/ubuntu-24.04-gitea:latest .
#   docker build --target gitlab-runner -t ghcr.io/thpham/fireactions-images/ubuntu-24.04-gitlab:latest .

# =============================================================================
# Global ARGs - must be declared before any FROM statement
# =============================================================================

ARG FIREACTIONS_VERSION=0.4.0
ARG FIRETEACT_VERSION=latest
ARG FIREGLAB_VERSION=latest

# =============================================================================
# Builder stages - fetch orchestrator binaries
# =============================================================================

# GitHub Actions orchestrator (upstream)
FROM ghcr.io/hostinger/fireactions:${FIREACTIONS_VERSION} AS fireactions-bin

# Gitea Actions orchestrator (built from this repo)
FROM ghcr.io/thpham/fireteact:${FIRETEACT_VERSION} AS fireteact-bin

# GitLab CI orchestrator (built from this repo)
FROM ghcr.io/thpham/fireglab:${FIREGLAB_VERSION} AS fireglab-bin

# =============================================================================
# Base stage - common packages and configuration
# =============================================================================

FROM ubuntu:24.04 AS base

ARG TARGETARCH

ENV DEBIAN_FRONTEND=noninteractive

# Install common system packages
RUN apt-get update -y                              \
  && apt-get install -y software-properties-common \
  && add-apt-repository -y ppa:git-core/ppa        \
  && apt-get update -y                             \
  && apt-get install -y --no-install-recommends    \
    acl                                            \
    bzip2                                          \
    ca-certificates                                \
    cmake                                          \
    build-essential                                \
    curl                                           \
    dbus                                           \
    file                                           \
    git                                            \
    git-lfs                                        \
    gnupg                                          \
    haveged                                        \
    iproute2                                       \
    iptables                                       \
    iptables-persistent                            \
    iputils-ping                                   \
    jq                                             \
    kmod                                           \
    libssl-dev                                     \
    locales                                        \
    lsb-release                                    \
    net-tools                                      \
    openssh-server                                 \
    patch                                          \
    pkg-config                                     \
    python3                                        \
    python3-pip                                    \
    python3-venv                                   \
    rsync                                          \
    sudo                                           \
    systemd                                        \
    time                                           \
    udev                                           \
    unzip                                          \
    vim-tiny                                       \
    wget                                           \
    xz-utils                                       \
    zip                                            \
    zstd                                           \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# Configure locale for UTF-8 support (required by many actions)
RUN locale-gen en_US.UTF-8
ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

RUN systemctl enable haveged.service

RUN update-alternatives --set iptables /usr/sbin/iptables-legacy && \
    update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy

# Create runner user (same UID for consistency across both platforms)
RUN adduser --disabled-password --gecos "" --uid 1001 runner  \
    && groupadd docker --gid 121                              \
    && usermod -aG docker runner                              \
    && usermod -aG sudo runner                                \
    && echo "%sudo   ALL=(ALL:ALL) NOPASSWD:ALL" > /etc/sudoers

# Create tool cache directory
RUN mkdir -p /opt/hostedtoolcache \
    && chown -R runner:docker /opt/hostedtoolcache \
    && chmod -R 777 /opt/hostedtoolcache

# Install Docker
RUN install -m 0755 -d /etc/apt/keyrings                                                                            \
    && curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg      \
    && chmod a+r /etc/apt/keyrings/docker.gpg                                                                       \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg]                         \
            https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable"         \
        | tee /etc/apt/sources.list.d/docker.list > /dev/null                                                       \
    && apt-get update && apt-get install --no-install-recommends -y                                                 \
        docker-ce                                                                                                   \
        docker-ce-cli                                                                                               \
        containerd.io                                                                                               \
        docker-buildx-plugin                                                                                        \
        docker-compose-plugin                                                                                       \
    && apt-get clean && rm -rf /var/lib/apt/lists/*                                                                 \
    && systemctl enable docker.service

# Install Node.js (required for JavaScript-based actions like actions/checkout)
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
    && apt-get install -y --no-install-recommends nodejs      \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Install Go (latest with security patches for crypto/x509 CVE fixes)
ARG GO_VERSION="1.24.11"
RUN curl -fsSL https://go.dev/dl/go${GO_VERSION}.linux-$(dpkg --print-architecture).tar.gz \
    | tar -C /usr/local -xzf - \
    && mkdir -p /home/runner/go /home/runner/.cache/go-build \
    && chown -R runner:runner /home/runner/go /home/runner/.cache

ENV GOROOT="/usr/local/go" \
    GOPATH="/home/runner/go" \
    GOCACHE="/home/runner/.cache/go-build" \
    GOMODCACHE="/home/runner/go/pkg/mod" \
    PATH="/home/runner/go/bin:/usr/local/go/bin:${PATH}"

# Configure SSH (for debug access)
RUN sed -i -e 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config \
    && sed -i -e 's/^AcceptEnv LANG LC_\*$/#AcceptEnv LANG LC_*/'            /etc/ssh/sshd_config

# Clear machine-id for proper cloud-init initialization
RUN echo "" > /etc/machine-id && echo "" > /var/lib/dbus/machine-id

# Install cloud-init for CA certificate and DNS configuration via MMDS
RUN apt-get update && apt-get install -y --no-install-recommends \
    cloud-init \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Copy common overlay files (network, docker service drop-in)
COPY overlay/common/etc /etc

# Enable systemd-resolved for DNS caching (without systemctl during build)
# DNS servers are obtained via DHCP when using systemd-networkd (UseDNS=yes)
RUN mkdir -p /etc/systemd/system/multi-user.target.wants \
    && ln -sf /lib/systemd/system/systemd-resolved.service \
              /etc/systemd/system/multi-user.target.wants/systemd-resolved.service

# Configure resolv.conf symlink at runtime (cannot modify during build - Docker bind-mount)
# This oneshot service runs before systemd-resolved and sets up the stub resolver symlink
RUN printf '[Unit]\n\
Description=Setup resolv.conf symlink for systemd-resolved\n\
DefaultDependencies=no\n\
Before=systemd-resolved.service\n\
Before=network.target\n\
\n\
[Service]\n\
Type=oneshot\n\
RemainAfterExit=yes\n\
ExecStart=/bin/sh -c "rm -f /etc/resolv.conf && ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf"\n\
\n\
[Install]\n\
WantedBy=sysinit.target\n' > /etc/systemd/system/resolv-conf-symlink.service \
    && mkdir -p /etc/systemd/system/sysinit.target.wants \
    && ln -sf /etc/systemd/system/resolv-conf-symlink.service \
              /etc/systemd/system/sysinit.target.wants/resolv-conf-symlink.service

# Harden systemd-resolved for Firecracker VMs (disable unused features)
RUN mkdir -p /etc/systemd/resolved.conf.d \
    && printf '[Resolve]\nLLMNR=no\nMulticastDNS=no\nDNSSEC=no\nDNSOverTLS=no\n' \
      > /etc/systemd/resolved.conf.d/firecracker.conf

# Enable cloud-init services (runs before Docker starts)
RUN systemctl enable cloud-init-local.service \
    cloud-init.service \
    cloud-config.service \
    cloud-final.service

# =============================================================================
# GitHub Actions Runner target
# =============================================================================

FROM base AS github-runner

ARG RUNNER_VERSION="2.330.0"
ARG TARGETARCH

# Set root password for debug access
RUN echo 'root:fireactions' | chpasswd

# Install GitHub Actions runner
RUN case "$TARGETARCH" in amd64|x86_64|i386) export RUNNER_ARCH="x64";; arm64) export RUNNER_ARCH="arm64";; esac                                                         \
    && mkdir -p /opt/runner && cd /opt/runner                                                                                                                             \
    && curl -fLo runner.tar.gz https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz \
    && tar xzf ./runner.tar.gz && rm -rf runner.tar.gz                                                                                                             \
    && ./bin/installdependencies.sh                                                                                                                                \
    && chown -R runner:docker /opt/runner

# Install GitHub CLI
RUN install -m 0755 -d /etc/apt/keyrings                                                                                           \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | gpg --dearmor -o /etc/apt/keyrings/githubcli.gpg \
    && chmod a+r /etc/apt/keyrings/githubcli.gpg                                                                                   \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli.gpg]                                     \
            https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null                 \
    && apt-get update && apt-get install --no-install-recommends -y gh                                                             \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Copy GitHub-specific overlay (hosts, cloud-init config, systemd service)
COPY overlay/github/etc /etc

# Copy fireactions binary
COPY --from=fireactions-bin /usr/bin/fireactions /usr/bin/fireactions

# Enable fireactions runner service
RUN systemctl enable fireactions.service

# =============================================================================
# Gitea Actions Runner target
# =============================================================================

FROM base AS gitea-runner

ARG ACT_RUNNER_VERSION="0.2.13"
ARG TARGETARCH

# Set root password for debug access
RUN echo 'root:fireteact' | chpasswd

# Install act_runner (Gitea Actions runner)
RUN case "$TARGETARCH" in amd64|x86_64|i386) export RUNNER_ARCH="amd64";; arm64) export RUNNER_ARCH="arm64";; esac                              \
    && mkdir -p /opt/act_runner && cd /opt/act_runner                                                                                           \
    && curl -fLo act_runner https://gitea.com/gitea/act_runner/releases/download/v${ACT_RUNNER_VERSION}/act_runner-${ACT_RUNNER_VERSION}-linux-${RUNNER_ARCH} \
    && chmod +x act_runner                                                                                                                       \
    && ln -s /opt/act_runner/act_runner /usr/local/bin/act_runner                                                                               \
    && chown -R runner:docker /opt/act_runner

# Copy Gitea-specific overlay (hosts, cloud-init config, systemd service)
COPY overlay/gitea/etc /etc

# Copy fireteact binary from GHCR image
COPY --from=fireteact-bin /usr/bin/fireteact /usr/bin/fireteact

# Enable fireteact runner service
RUN systemctl enable fireteact.service

# =============================================================================
# GitLab CI Runner target
# =============================================================================

FROM base AS gitlab-runner

ARG GITLAB_RUNNER_VERSION="18.7.0"
ARG TARGETARCH

# Set root password for debug access
RUN echo 'root:fireglab' | chpasswd

# Install gitlab-runner
RUN case "$TARGETARCH" in amd64|x86_64|i386) export RUNNER_ARCH="amd64";; arm64) export RUNNER_ARCH="arm64";; esac                              \
    && mkdir -p /opt/gitlab-runner && cd /opt/gitlab-runner                                                                                      \
    && curl -fLo gitlab-runner https://gitlab-runner-downloads.s3.amazonaws.com/v${GITLAB_RUNNER_VERSION}/binaries/gitlab-runner-linux-${RUNNER_ARCH} \
    && chmod +x gitlab-runner                                                                                                                     \
    && ln -s /opt/gitlab-runner/gitlab-runner /usr/local/bin/gitlab-runner                                                                       \
    && chown -R runner:docker /opt/gitlab-runner                                                                                                 \
    && mkdir -p /home/runner/.gitlab-runner                                                                                                      \
    && chown -R runner:docker /home/runner/.gitlab-runner

# Install GitLab CLI (glab)
RUN curl -fsSL https://raw.githubusercontent.com/upciti/wakemeops/main/assets/install_repository | bash \
    && apt-get update && apt-get install --no-install-recommends -y glab \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Copy GitLab-specific overlay (hosts, cloud-init config, systemd service)
COPY overlay/gitlab/etc /etc

# Copy fireglab binary from GHCR image
COPY --from=fireglab-bin /usr/bin/fireglab /usr/bin/fireglab

# Enable fireglab runner service
RUN systemctl enable fireglab.service
