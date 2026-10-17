#!/usr/bin/env bash
#
# Install the pinned Rust toolchains, Node.js and Cargo tools used by the
# canonical Xila development image.
#
# This script runs as root during `docker build`, from the build context root.
# It only relies on the toolchains manifest passed as the first argument and on
# the system packages installed by `packages.txt` (bash, curl, xz, sha256sum,
# tar, clang, ...). It never runs apt.
#
# Usage: ./install-tools.sh [/tmp/toolchains.env]

set -euo pipefail

trap 'echo "error: install-tools.sh failed at line ${LINENO}" >&2' ERR

# Resolve the manifest and load the pins. Defaults to the path the Dockerfile
# copies the manifest to (see Dockerfile).
manifest_path="${1:-/tmp/toolchains.env}"
if [[ ! -f "$manifest_path" ]]; then
  echo "error: toolchains manifest not found: $manifest_path" >&2
  exit 1
fi
# shellcheck source=/dev/null
source "$manifest_path"

# Every value the script consumes must be present in the manifest. Fail with a
# message that names the offending key instead of silently installing "latest".
required_vars=(
  XILA_RUST_TOOLCHAIN
  XILA_NIGHTLY_TOOLCHAIN
  NODE_VERSION
  CARGO_BINSTALL_VERSION
  CARGO_MAKE_VERSION
  TRUNK_VERSION
  TAPLO_VERSION
  CARGO_LLVM_COV_VERSION
  SCCACHE_VERSION
)
for var in "${required_vars[@]}"; do
  if [[ -z "${!var:-}" ]]; then
    echo "error: required variable '$var' is not set in $manifest_path" >&2
    exit 1
  fi
done

# Rustup/Cargo live in shared, world-readable locations so the image works for
# any non-root user, not just the build user.
export RUSTUP_HOME="${RUSTUP_HOME:-/usr/local/rustup}"
export CARGO_HOME="${CARGO_HOME:-/usr/local/cargo}"
export PATH="/usr/local/cargo/bin:/usr/local/bin:$PATH"

# 1. rustup (no default toolchain; we pin explicit toolchains below).
if [[ ! -x "$CARGO_HOME/bin/rustup" ]]; then
  rustup_init="$(mktemp)"
  curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs -o "$rustup_init"
  sh "$rustup_init" --no-modify-path --profile minimal --default-toolchain none -y
  rm -f "$rustup_init"
fi

# 2. Stable toolchain with formatting, linting and LLVM coverage tools, plus the
#    Wasm targets used by guest applications.
rustup toolchain install "$XILA_RUST_TOOLCHAIN" \
  --profile minimal \
  --component rustfmt,clippy,llvm-tools-preview
rustup target add \
  --toolchain "$XILA_RUST_TOOLCHAIN" \
  wasm32-unknown-unknown wasm32-wasip1

# 3. Nightly toolchain with rust-src and Miri, plus the cross-compilation and
#    Wasm targets later phases rely on.
rustup toolchain install "$XILA_NIGHTLY_TOOLCHAIN" \
  --profile minimal \
  --component rust-src,miri
rustup target add \
  --toolchain "$XILA_NIGHTLY_TOOLCHAIN" \
  wasm32-unknown-unknown i686-unknown-linux-gnu powerpc-unknown-linux-gnu

# 4. Persist the default toolchain in settings.toml so rustup never has to
#    create it lazily at runtime under an unpredictable user.
cat > "$RUSTUP_HOME/settings.toml" <<EOF
version = "12"
default_toolchain = "$XILA_RUST_TOOLCHAIN"
profile = "minimal"

[overrides]
EOF

# 5. Make the trees readable/executable by the non-root image users.
chmod -R a+rX "$RUSTUP_HOME" "$CARGO_HOME"

# 6. cargo-binstall downloads prebuilt binaries, keeping image builds fast.
if [[ ! -x "$CARGO_HOME/bin/cargo-binstall" ]]; then
  binstall_installer="$(mktemp)"
  curl -fsSL \
    "https://raw.githubusercontent.com/cargo-bins/cargo-binstall/v${CARGO_BINSTALL_VERSION}/install-from-binstall-release.sh" \
    -o "$binstall_installer"
  bash "$binstall_installer"
  rm -f "$binstall_installer"
fi

# 7. Pinned Cargo tools. --no-symlinks places the binaries directly in
#    $CARGO_HOME/bin instead of symlinking through the binstall bin dir.
cargo binstall --no-confirm --no-symlinks \
  "cargo-make@${CARGO_MAKE_VERSION}" \
  "trunk@${TRUNK_VERSION}" \
  "taplo-cli@${TAPLO_VERSION}" \
  "cargo-llvm-cov@${CARGO_LLVM_COV_VERSION}" \
  "sccache@${SCCACHE_VERSION}"

# 8. Node.js, verified against the official checksums before extraction.
node_dist_url="https://nodejs.org/dist/v${NODE_VERSION}"
node_tarball="node-v${NODE_VERSION}-linux-x64.tar.xz"
node_workdir="$(mktemp -d)"
curl -fsSL "${node_dist_url}/${node_tarball}" -o "${node_workdir}/${node_tarball}"
curl -fsSL "${node_dist_url}/SHASUMS256.txt" -o "${node_workdir}/SHASUMS256.txt"
(
  cd "$node_workdir"
  grep " ${node_tarball}\$" SHASUMS256.txt | sha256sum -c -
)
tar -xJf "${node_workdir}/${node_tarball}" -C /usr/local --strip-components=1
rm -rf "$node_workdir"

# 9. Build-time smoke check: every tool below must answer or the build fails.
clang --version
node --version
npm --version
cargo make --version
cargo +"$XILA_NIGHTLY_TOOLCHAIN" miri --version
