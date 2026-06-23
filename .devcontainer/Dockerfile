FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

# Base build tools
RUN apt-get update && apt-get install -y \
    autoconf \
    automake \
    libtool \
    pkg-config \
    make \
    git \
    curl \
    wget \
    ca-certificates \
    lsb-release \
    gnupg \
    zip \
    gzip \
    python3 \
    && rm -rf /var/lib/apt/lists/*

# Add Apertium nightly APT repository
RUN curl -sS https://apertium.projectjj.com/apt/install-nightly.sh | bash

# Install Apertium core and HFST tools
RUN apt-get update && apt-get install -y \
    apertium \
    apertium-dev \
    hfst \
    cg3 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace
