# Canonical Xila development image.
#
# Build it from this repository's root, which is the build context, so that the
# COPY sources below are repository-relative:
#
#     docker build --tag xila-core-dev:local .
#
# Layer order keeps rebuilds cheap: system packages (`packages.txt`, rarely
# changing) are installed before the pinned toolchains (`toolchains.env`, bumped
# whenever a tool version changes).

FROM ubuntu:24.04

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# 1. System packages. Only packages.txt participates in this layer's cache key,
#    so bumping a toolchain version does not reinstall apt packages.
COPY packages.txt /tmp/packages.txt
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
    && grep -v '^#' /tmp/packages.txt | xargs apt-get install -y --no-install-recommends \
    && rm -rf /var/lib/apt/lists/*

# 2. Pinned Rust toolchains, Node.js and Cargo tools. install-tools.sh reads the
#    pins from the manifest and performs its own permission fixes and smoke
#    checks; it never runs apt.
COPY install-tools.sh /tmp/install-tools.sh
COPY toolchains.env /tmp/toolchains.env
RUN chmod +x /tmp/install-tools.sh \
    && /tmp/install-tools.sh /tmp/toolchains.env

# 3. Runtime contract consumed by scripts/xila-dev and project CI. The XILA_*
#    pins, RUSTUP_TOOLCHAIN and LIBCLANG_PATH mirror toolchains.env and the base
#    image's clang (ubuntu:24.04 ships LLVM 18). Docker cannot read the manifest
#    here, so they are hardcoded and guarded by the sanity check below;
#    XILA_NIGHTLY_TOOLCHAIN must be exported so callers (including the image
#    smoke tests) can run `rustup +"$XILA_NIGHTLY_TOOLCHAIN" ...`.
ENV CC=clang \
    CXX=clang++ \
    LIBCLANG_PATH=/usr/lib/llvm-18/lib \
    CC_wasm32_unknown_unknown=clang \
    CXX_wasm32_unknown_unknown=clang++ \
    CC_wasm32_wasip1=clang \
    CXX_wasm32_wasip1=clang++ \
    RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    XILA_RUST_TOOLCHAIN=1.99.0 \
    XILA_NIGHTLY_TOOLCHAIN=nightly-2026-10-12 \
    RUSTUP_TOOLCHAIN=1.99.0 \
    PATH=/usr/local/cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# 4. Let a bare `docker run` as any UID write the default CARGO_HOME without a
#    bind mount.
RUN chmod -R a+rwX /usr/local/cargo

# 5. Build-time sanity check: the pinned tools, both pinned toolchains and
#    libclang must be usable. A multi-argument `command -v` reports success even
#    when a name is missing, so assert each tool individually as well.
RUN test -e "$LIBCLANG_PATH/libclang.so" \
    && command -v bash clang cargo rustup node npm trunk taplo sccache cargo-make \
    && for tool in bash clang cargo rustup node npm trunk taplo sccache cargo-make; do \
         command -v "$tool" >/dev/null || { echo "error: sanity check failed: missing $tool" >&2; exit 1; }; \
       done \
    && cargo llvm-cov --version \
    && cargo "+$XILA_RUST_TOOLCHAIN" --version \
    && cargo "+$XILA_NIGHTLY_TOOLCHAIN" --version

# 6. OCI metadata.
LABEL org.opencontainers.image.source="https://github.com/Xila-Project/development-environment" \
      org.opencontainers.image.title="xila-core-dev" \
      org.opencontainers.image.description="Canonical Xila development environment"

# 7. Defaults for interactive use.
WORKDIR /workspace
CMD ["/bin/bash"]
