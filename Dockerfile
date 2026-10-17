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

# 4. Build-time sanity check: the pinned tools, both pinned toolchains, the
#    pinned cargo-binstall and libclang must be usable.
#    The XILA_*/RUSTUP_TOOLCHAIN ENV above are hardcoded because Docker cannot
#    read toolchains.env at ENV time, so guard them against drift: save the ENV
#    values, source the still-present manifest, and fail (naming the key) if they
#    disagree. RUSTUP_AUTO_INSTALL=0 keeps the `cargo +toolchain` checks honest —
#    a missing toolchain fails loudly instead of being downloaded. A
#    multi-argument `command -v` reports success even when a name is missing, so
#    assert each tool individually as well.
RUN test -e "$LIBCLANG_PATH/libclang.so" \
    && env_rust_toolchain="$XILA_RUST_TOOLCHAIN" \
    && env_nightly_toolchain="$XILA_NIGHTLY_TOOLCHAIN" \
    && env_rustup_toolchain="$RUSTUP_TOOLCHAIN" \
    && source /tmp/toolchains.env \
    && { [[ "$env_rust_toolchain" == "$XILA_RUST_TOOLCHAIN" ]] \
         || { echo "error: Dockerfile ENV XILA_RUST_TOOLCHAIN='$env_rust_toolchain' drifted from toolchains.env XILA_RUST_TOOLCHAIN='$XILA_RUST_TOOLCHAIN'" >&2; exit 1; }; } \
    && { [[ "$env_nightly_toolchain" == "$XILA_NIGHTLY_TOOLCHAIN" ]] \
         || { echo "error: Dockerfile ENV XILA_NIGHTLY_TOOLCHAIN='$env_nightly_toolchain' drifted from toolchains.env XILA_NIGHTLY_TOOLCHAIN='$XILA_NIGHTLY_TOOLCHAIN'" >&2; exit 1; }; } \
    && { [[ "$env_rustup_toolchain" == "$XILA_RUST_TOOLCHAIN" ]] \
         || { echo "error: Dockerfile ENV RUSTUP_TOOLCHAIN='$env_rustup_toolchain' must mirror toolchains.env XILA_RUST_TOOLCHAIN='$XILA_RUST_TOOLCHAIN'" >&2; exit 1; }; } \
    && command -v bash clang cargo rustup node npm trunk taplo sccache cargo-make \
    && for tool in bash clang cargo rustup node npm trunk taplo sccache cargo-make; do \
         command -v "$tool" >/dev/null || { echo "error: sanity check failed: missing $tool" >&2; exit 1; }; \
       done \
    && cargo llvm-cov --version \
    && binstall_version="$(cargo binstall -V)" \
    && { [[ "$binstall_version" == "$CARGO_BINSTALL_VERSION" || "$binstall_version" == "cargo-binstall $CARGO_BINSTALL_VERSION" ]] \
         || { echo "error: cargo-binstall version '$binstall_version' does not match pinned '$CARGO_BINSTALL_VERSION'" >&2; exit 1; }; } \
    && RUSTUP_AUTO_INSTALL=0 cargo "+$XILA_RUST_TOOLCHAIN" --version \
    && RUSTUP_AUTO_INSTALL=0 cargo "+$XILA_NIGHTLY_TOOLCHAIN" --version

# 5. OCI metadata.
LABEL org.opencontainers.image.source="https://github.com/Xila-Project/development-environment" \
      org.opencontainers.image.title="xila-core-dev" \
      org.opencontainers.image.description="Canonical Xila development environment"

# 6. Defaults for interactive use.
WORKDIR /workspace
CMD ["/bin/bash"]
