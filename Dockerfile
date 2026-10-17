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

FROM debian:trixie

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# 1. System packages. Only packages.txt participates in this layer's cache key,
#    so bumping a toolchain version does not reinstall apt packages.
COPY packages.txt /tmp/packages.txt
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
    && grep -v '^#' /tmp/packages.txt | xargs apt-get install -y --no-install-recommends \
    && rm -rf /var/lib/apt/lists/*

# 2. LLVM/Clang. Debian trixie does not ship the required LLVM line, so install
#    the maintainer's system clang 22.1.8 (Debian clang version 22.1.8), not the
#    21.1.8 Devbox declares nor CI's version, so install that exact line from
#    apt.llvm.org. The version is hardcoded here (Docker cannot read the manifest
#    at ENV time) and guarded by the sanity check below; the apt suite is named
#    by the major version (llvm-toolchain-trixie-22). The build relies on bare
#    `clang`/`clang++` (see Core's .cargo/config.toml), so create those symlinks
#    explicitly instead of leaning on the versioned apt binaries or Debian's own
#    `clang` package.
ENV LLVM_VERSION=22.1.8
RUN LLVM_MAJOR="${LLVM_VERSION%%.*}" \
    && curl --proto '=https' --tlsv1.2 -fsSL \
         https://apt.llvm.org/llvm-snapshot.gpg.key \
         -o /usr/share/keyrings/llvm.asc \
    && echo "deb [signed-by=/usr/share/keyrings/llvm.asc] https://apt.llvm.org/trixie/ llvm-toolchain-trixie-${LLVM_MAJOR} main" \
         > /etc/apt/sources.list.d/llvm.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
         "clang-${LLVM_MAJOR}" "libclang-${LLVM_MAJOR}-dev" \
    && rm -rf /var/lib/apt/lists/* \
    && ln -sfn "/usr/lib/llvm-${LLVM_MAJOR}/bin/clang" /usr/bin/clang \
    && ln -sfn "/usr/lib/llvm-${LLVM_MAJOR}/bin/clang++" /usr/bin/clang++

# 3. Pinned Rust toolchains, Node.js and Cargo tools.
COPY toolchains.env /tmp/toolchains.env
RUN source /tmp/toolchains.env \
    && export RUSTUP_HOME=/usr/local/rustup CARGO_HOME=/usr/local/cargo \
    && export PATH="/usr/local/cargo/bin:/usr/local/bin:$PATH" \
    && curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs -o /tmp/rustup-init.sh \
    && sh /tmp/rustup-init.sh --no-modify-path --profile minimal --default-toolchain none -y \
    && rm /tmp/rustup-init.sh \
    && rustup toolchain install "$XILA_RUST_TOOLCHAIN" --profile minimal --component rustfmt,clippy,llvm-tools-preview \
    && rustup target add --toolchain "$XILA_RUST_TOOLCHAIN" wasm32-unknown-unknown wasm32-wasip1 \
    && rustup toolchain install "$XILA_NIGHTLY_TOOLCHAIN" --profile minimal --component rust-src,miri \
    && rustup target add --toolchain "$XILA_NIGHTLY_TOOLCHAIN" wasm32-unknown-unknown i686-unknown-linux-gnu powerpc-unknown-linux-gnu \
    && printf 'version = "12"\ndefault_toolchain = "%s"\nprofile = "minimal"\n\n[overrides]\n' "$XILA_RUST_TOOLCHAIN" > "$RUSTUP_HOME/settings.toml" \
    && chmod -R a+rX "$RUSTUP_HOME" \
    && curl -fsSL "https://raw.githubusercontent.com/cargo-bins/cargo-binstall/v${CARGO_BINSTALL_VERSION}/install-from-binstall-release.sh" -o /tmp/binstall.sh \
    && BINSTALL_VERSION="$CARGO_BINSTALL_VERSION" bash /tmp/binstall.sh \
    && rm /tmp/binstall.sh \
    && cargo binstall --no-confirm --no-symlinks \
         "cargo-make@${CARGO_MAKE_VERSION}" "trunk@${TRUNK_VERSION}" \
         "taplo-cli@${TAPLO_VERSION}" "cargo-llvm-cov@${CARGO_LLVM_COV_VERSION}" \
         "sccache@${SCCACHE_VERSION}" \
    && case "$(dpkg --print-architecture)" in amd64) node_arch=x64 ;; arm64) node_arch=arm64 ;; *) echo "unsupported architecture" >&2; exit 1 ;; esac \
    && node_dist_url="https://nodejs.org/dist/v${NODE_VERSION}" \
    && node_tarball="node-v${NODE_VERSION}-linux-${node_arch}.tar.xz" \
    && mkdir -p /tmp/node \
    && curl -fsSL "${node_dist_url}/${node_tarball}" -o "/tmp/node/${node_tarball}" \
    && curl -fsSL "${node_dist_url}/SHASUMS256.txt" -o /tmp/node/SHASUMS256.txt \
    && (cd /tmp/node && grep " ${node_tarball}\$" SHASUMS256.txt | sha256sum -c -) \
    && tar -xJf "/tmp/node/${node_tarball}" -C /usr/local --strip-components=1 \
    && rm -rf /tmp/node \
    && chmod -R a+rwX "$CARGO_HOME" \
    && clang --version && node --version && npm --version \
    && cargo make --version && cargo +"$XILA_NIGHTLY_TOOLCHAIN" miri --version

# 4. Runtime contract consumed by scripts/xila-dev and project CI. The XILA_*
#    pins, RUSTUP_TOOLCHAIN and LIBCLANG_PATH mirror toolchains.env and the
#    LLVM/Clang pinned from apt.llvm.org in step 2. Docker cannot read the
#    manifest here, so they are hardcoded and guarded by the sanity check below;
#    XILA_NIGHTLY_TOOLCHAIN must be exported so callers (including the image
#    smoke tests) can run `rustup +"$XILA_NIGHTLY_TOOLCHAIN" ...`.
ENV CC=clang \
    CXX=clang++ \
    LIBCLANG_PATH=/usr/lib/llvm-22/lib \
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

# 5. Build-time sanity check: the pinned tools, both pinned toolchains, the
#    pinned cargo-binstall, the pinned clang and libclang must be usable.
#    The XILA_*/RUSTUP_TOOLCHAIN/LLVM_VERSION ENV above are hardcoded because
#    Docker cannot read toolchains.env at ENV time, so guard them against drift:
#    save the ENV values, assert the manifest still declares LLVM_VERSION,
#    source the still-present manifest (which overwrites LLVM_VERSION), and fail
#    (naming the key) if they disagree.
#    RUSTUP_AUTO_INSTALL=0 keeps the `cargo +toolchain` checks honest — a missing
#    toolchain fails loudly instead of being downloaded.
RUN set -e; \
    assert_pin_matches() { \
      local docker_key="$1" docker_value="$2" manifest_key="$3" manifest_value="$4"; \
      if [[ "$docker_value" != "$manifest_value" ]]; then \
        printf "error: Dockerfile ENV %s='%s' drifted from toolchains.env %s='%s'\\n" \
          "$docker_key" "$docker_value" "$manifest_key" "$manifest_value" >&2; \
        return 1; \
      fi; \
    }; \
    test -e "$LIBCLANG_PATH/libclang.so"; \
    env_llvm_version="$LLVM_VERSION"; \
    env_rust_toolchain="$XILA_RUST_TOOLCHAIN"; \
    env_nightly_toolchain="$XILA_NIGHTLY_TOOLCHAIN"; \
    env_rustup_toolchain="$RUSTUP_TOOLCHAIN"; \
    grep -qE '^[[:space:]]*LLVM_VERSION=' /tmp/toolchains.env || { echo "error: toolchains.env does not declare LLVM_VERSION" >&2; exit 1; }; \
    source /tmp/toolchains.env; \
    assert_pin_matches "LLVM_VERSION" "$env_llvm_version" "LLVM_VERSION" "$LLVM_VERSION"; \
    assert_pin_matches "XILA_RUST_TOOLCHAIN" "$env_rust_toolchain" "XILA_RUST_TOOLCHAIN" "$XILA_RUST_TOOLCHAIN"; \
    assert_pin_matches "XILA_NIGHTLY_TOOLCHAIN" "$env_nightly_toolchain" "XILA_NIGHTLY_TOOLCHAIN" "$XILA_NIGHTLY_TOOLCHAIN"; \
    assert_pin_matches "RUSTUP_TOOLCHAIN" "$env_rustup_toolchain" "XILA_RUST_TOOLCHAIN" "$XILA_RUST_TOOLCHAIN"; \
    clang --version | grep -Fq "clang version $LLVM_VERSION" || { echo "error: installed clang does not match pinned LLVM_VERSION='$LLVM_VERSION'" >&2; clang --version >&2; exit 1; }; \
    for tool in bash clang cargo rustup node npm trunk taplo sccache cargo-make; do \
      command -v "$tool" >/dev/null || { echo "error: sanity check failed: missing $tool" >&2; exit 1; }; \
    done; \
    cargo llvm-cov --version; \
    binstall_version="$(cargo binstall -V)"; \
    [[ "$binstall_version" == "$CARGO_BINSTALL_VERSION" || "$binstall_version" == "cargo-binstall $CARGO_BINSTALL_VERSION" ]] || { echo "error: cargo-binstall version '$binstall_version' does not match pinned '$CARGO_BINSTALL_VERSION'" >&2; exit 1; }; \
    RUSTUP_AUTO_INSTALL=0 cargo "+$XILA_RUST_TOOLCHAIN" --version; \
    RUSTUP_AUTO_INSTALL=0 cargo "+$XILA_NIGHTLY_TOOLCHAIN" --version

# 6. OCI metadata.
LABEL org.opencontainers.image.source="https://github.com/Xila-Project/development-environment" \
      org.opencontainers.image.title="xila-core-dev" \
      org.opencontainers.image.description="Canonical Xila development environment"

# 7. Defaults for interactive use.
WORKDIR /workspace
CMD ["/bin/bash"]
