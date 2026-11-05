# syntax=docker/dockerfile:1
#
# netdebug — swiss-army-knife container for debugging network, TLS, mail,
# databases and storage inside Kubernetes / Linux PaaS environments.
#
# Debian (not Alpine) on purpose: glibc, FUSE filesystems (s3fs, sshfs,
# rclone), tshark and the DB clients are all first-class packages here,
# while on Alpine several of them are missing or musl-flaky.
#
# Build (multi-arch):
#   docker buildx build --platform linux/amd64,linux/arm64 -t netdebug:latest .

FROM debian:trixie-slim

ARG TARGETARCH
ARG YQ_VERSION=v4.54.1
ARG SQLCMD_VERSION=v1.10.0
ARG GRPCURL_VERSION=1.9.4
ARG WEBSOCAT_VERSION=v1.14.1
ARG KUBECTL_VERSION=v1.37.2

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    TERM=xterm-256color

# tshark asks whether non-root users may capture; answer non-interactively.
RUN echo "wireshark-common wireshark-common/install-setuid boolean false" | debconf-set-selections

RUN apt-get update && apt-get install -y --no-install-recommends \
      # --- base / shell ergonomics ---
      ca-certificates bash bash-completion less vim-nox tmux tree file \
      procps psmisc htop lsof strace sysstat ncdu git gnupg tzdata \
      # --- TLS / certificates ---
      openssl gnutls-bin testssl.sh sslscan \
      # --- HTTP / generic clients ---
      curl wget httpie \
      # --- network diagnostics ---
      iproute2 iputils-ping iputils-arping iputils-tracepath traceroute \
      tcptraceroute mtr-tiny netcat-openbsd socat ncat nmap tcpdump tshark \
      iperf3 ethtool conntrack iptables nftables ipcalc whois \
      # --- DNS ---
      bind9-dnsutils knot-dnsutils ldnsutils \
      # --- remote shells / file transfer ---
      telnet openssh-client sshpass rsync lftp tnftp smbclient \
      # --- mail (IMAP/POP3/SMTP) ---
      neomutt swaks \
      # --- data wrangling (yq: kislyuk/python variant, ships `xq`/`tomlq`) ---
      jq yq \
      # --- compression ---
      zip unzip xz-utils bzip2 zstd lz4 lzop brotli pigz 7zip cpio \
      # --- databases & brokers ---
      postgresql-client mariadb-client sqlite3 redis-tools kcat ldap-utils \
      # --- filesystems / FUSE ---
      fuse3 s3fs sshfs rclone nfs-common cifs-utils \
      # --- minimal python ---
      python3 python3-requests python3-yaml \
    && rm -rf /var/lib/apt/lists/*

# Static upstream binaries the distro doesn't ship (or ships too old).
# mikefarah/yq goes to /usr/local/bin and therefore wins over the apt `yq`
# on PATH; the apt one stays reachable as /usr/bin/yq and provides `xq`.
RUN set -eux; \
    case "${TARGETARCH:-amd64}" in \
      amd64) GRPC_ARCH=x86_64; WS_ARCH=x86_64 ;; \
      arm64) GRPC_ARCH=arm64;  WS_ARCH=aarch64 ;; \
      *) echo "unsupported arch ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    ARCH="${TARGETARCH:-amd64}"; \
    curl -fsSLo /usr/local/bin/yq \
      "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${ARCH}"; \
    curl -fsSL "https://github.com/microsoft/go-sqlcmd/releases/download/${SQLCMD_VERSION}/sqlcmd-linux-${ARCH}.tar.bz2" \
      | tar -xjf - -C /usr/local/bin sqlcmd; \
    curl -fsSL "https://github.com/fullstorydev/grpcurl/releases/download/v${GRPCURL_VERSION}/grpcurl_${GRPCURL_VERSION}_linux_${GRPC_ARCH}.tar.gz" \
      | tar -xzf - -C /usr/local/bin grpcurl; \
    curl -fsSLo /usr/local/bin/websocat \
      "https://github.com/vi/websocat/releases/download/${WEBSOCAT_VERSION}/websocat.${WS_ARCH}-unknown-linux-musl"; \
    curl -fsSLo /usr/local/bin/kubectl \
      "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl"; \
    chmod 0755 /usr/local/bin/*; \
    kubectl completion bash > /etc/bash_completion.d/kubectl; \
    # Debian renames these to avoid package clashes; restore the familiar names.
    ln -s /usr/bin/xq-python /usr/local/bin/xq; \
    ln -s /usr/bin/testssl /usr/local/bin/testssl.sh

COPY --chmod=0755 bin/ /usr/local/bin/
COPY rootfs/ /

WORKDIR /root
# Idle by default so it can run as a Deployment/Pod and be `kubectl exec`'d into.
CMD ["sleep", "infinity"]
