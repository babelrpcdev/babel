FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV SOLANA_VERSION=1.18.22

# Install dependencies
RUN apt-get update && apt-get install -y \
    curl \
    bzip2 \
    libssl-dev \
    libudev-dev \
    pkg-config \
    zlib1g-dev \
    llvm \
    clang \
    cmake \
    make \
    libprotobuf-dev \
    protobuf-compiler \
    jq \
    && rm -rf /var/lib/apt/lists/*

# Install Solana
RUN curl -sSfL https://release.solana.com/v${SOLANA_VERSION}/install | sh

ENV PATH="/root/.local/share/solana/install/active_release/bin:${PATH}"

# Create directories
RUN mkdir -p /ledger /accounts /snapshots /config

# Copy entrypoint script
COPY entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint.sh

# Expose ports
# 8899 - RPC
# 8900 - WebSocket
# 9091 - Metrics
EXPOSE 8899 8900 9091

WORKDIR /

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

