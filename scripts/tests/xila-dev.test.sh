#!/usr/bin/env bash
#
# Self-contained tests for scripts/xila-dev command construction.
#
# The wrapper resolves its container command through the `--print` seam, which
# writes the fully-resolved, shell-quoted command to stdout without running it,
# creating directories or touching an image. Driving the tests through that seam
# lets them run with no container engine and no image present, as long as
# XILA_DEV_ENGINE pins engine detection to docker.
#
# Usage: bash scripts/tests/xila-dev.test.sh   (exits non-zero on first failure)

set -u

# Drop inherited configuration that would make the constructed command depend on
# the caller's environment: these override the image, engine, workspace and the
# toolchain pin checked by the malformed-manifest guard.
unset XILA_DEV_IMAGE XILA_DEV_ENGINE XILA_WORKSPACE XILA_RUST_TOOLCHAIN

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WRAPPER="$REPO_ROOT/scripts/xila-dev"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# assert_contains HAYSTACK NEEDLE — plain substring match (fixed, no regex).
assert_contains() {
  local haystack="$1" needle="$2"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo "  in command: $haystack" >&2
    fail "expected output to contain: $needle"
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "  in command: $haystack" >&2
    fail "expected output to NOT contain: $needle"
  fi
}

assert_absent() {
  local path="$1"
  [[ -e "$path" ]] && fail "expected path to be absent: $path"
  return 0
}

assert_starts_with() {
  local haystack="$1" needle="$2"
  if [[ "$haystack" != "$needle"* ]]; then
    echo "  in command: $haystack" >&2
    fail "expected output to start with: $needle"
  fi
}

[[ -x "$WRAPPER" ]] || fail "wrapper is missing or not executable: $WRAPPER"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# 1. Base invocation: user, workspace mount, caches, default image.
out="$(XILA_DEV_ENGINE=docker "$WRAPPER" --print --workspace "$tmp" run -- echo hi)"
assert_contains "$out" "--user $(id -u):$(id -g)"
assert_contains "$out" "-v $tmp:/workspace"
assert_contains "$out" "-w /workspace"
assert_contains "$out" "CARGO_HOME=/workspace/.dev-environment/cargo"
assert_contains "$out" "CARGO_TARGET_DIR=/workspace/.dev-environment/target"
assert_contains "$out" "ghcr.io/xila-project/development-environment:main"
assert_contains "$out" "echo hi"

# 2. Image override via the environment.
out="$(XILA_DEV_ENGINE=docker XILA_DEV_IMAGE=custom:test "$WRAPPER" --print --workspace "$tmp" run true)"
assert_contains "$out" "custom:test"

# 2b. Image override via the --image flag (distinct from the env form), and the
#     flag must win over an inherited XILA_DEV_IMAGE.
out="$(XILA_DEV_ENGINE=docker XILA_DEV_IMAGE=env-image:test \
  "$WRAPPER" --print --image flag-image:test --workspace "$tmp" run true)"
assert_contains "$out" "flag-image:test"
assert_not_contains "$out" "env-image:test"

# 3. --gui forwards an existing Wayland socket and never escalates privileges.
mkdir -p "$tmp/wl"
: > "$tmp/wl/wayland-0"
out="$(XILA_DEV_ENGINE=docker WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR="$tmp/wl" \
  "$WRAPPER" --print --gui --workspace "$tmp" run true)"
assert_contains "$out" "-v $tmp/wl/wayland-0:$tmp/wl/wayland-0"
assert_contains "$out" "-e XDG_RUNTIME_DIR"
assert_contains "$out" "WAYLAND_DISPLAY"
assert_not_contains "$out" "--privileged"

# 4. --device passes an existing host device through.
out="$(XILA_DEV_ENGINE=docker "$WRAPPER" --print --device /dev/null --workspace "$tmp" run true)"
assert_contains "$out" "--device /dev/null"

# 5. Podman keeps the invoking user via --userns=keep-id.
out="$(XILA_DEV_ENGINE=docker "$WRAPPER" --print --engine podman --workspace "$tmp" run true)"
assert_contains "$out" "--userns=keep-id"

# 6. --print must not create the per-workspace state directory.
rm -rf "$tmp/.dev-environment"
XILA_DEV_ENGINE=docker "$WRAPPER" --print --workspace "$tmp" run true >/dev/null
assert_absent "$tmp/.dev-environment"

# 7. build targets this repository's Dockerfile as the build context.
out="$(XILA_DEV_ENGINE=docker "$WRAPPER" --print --workspace "$tmp" build)"
assert_contains "$out" "build"
assert_contains "$out" "--file"
assert_contains "$out" "$REPO_ROOT/Dockerfile"

# 8. doctor under --print resolves the probe without touching the filesystem.
rm -rf "$tmp/.dev-environment"
out="$(XILA_DEV_ENGINE=docker "$WRAPPER" --print --workspace "$tmp" doctor 2>/dev/null)"
assert_contains "$out" "bash -lc"
assert_contains "$out" "rustc"
assert_contains "$out" "node"
assert_absent "$tmp/.dev-environment"

# 9. --gui is gated on WAYLAND_DISPLAY alone: the flag is forwarded even when
#    XDG_RUNTIME_DIR is unset (and X11 is unavailable), and still no --privileged.
out="$(env -u XDG_RUNTIME_DIR -u DISPLAY XILA_DEV_ENGINE=docker WAYLAND_DISPLAY=wayland-0 \
  "$WRAPPER" --print --gui --workspace "$tmp" run true 2>/dev/null)"
assert_contains "$out" "-e WAYLAND_DISPLAY"
assert_not_contains "$out" "--privileged"

# 10. run/shell/check/doctor must pass the `run` verb to the engine first.
for sub in run shell check doctor; do
  out="$(XILA_DEV_ENGINE=docker "$WRAPPER" --print --workspace "$tmp" "$sub" 2>/dev/null)"
  assert_starts_with "$out" "docker run "
done

# 11. build/pull are engine verbs, never `docker run`.
out="$(XILA_DEV_ENGINE=docker "$WRAPPER" --print --workspace "$tmp" build)"
assert_starts_with "$out" "docker build "
assert_not_contains "$out" "docker run "
out="$(XILA_DEV_ENGINE=docker "$WRAPPER" --print --workspace "$tmp" pull)"
assert_starts_with "$out" "docker pull "
assert_not_contains "$out" "docker run "

# 12. --gui with a Wayland display whose socket does not exist: warn and skip the
#     mount instead of letting the engine create a host directory.
mkdir -p "$tmp/no-sock"
err="$(XILA_DEV_ENGINE=docker WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR="$tmp/no-sock" \
  "$WRAPPER" --print --gui --workspace "$tmp" run true 2>&1 >/dev/null)"
out="$(XILA_DEV_ENGINE=docker WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR="$tmp/no-sock" \
  "$WRAPPER" --print --gui --workspace "$tmp" run true 2>/dev/null)"
assert_not_contains "$out" "$tmp/no-sock/wayland-0"
assert_contains "$out" "-e WAYLAND_DISPLAY"
assert_contains "$err" "Wayland socket not found"

# 13. A malformed manifest (empty XILA_RUST_TOOLCHAIN) fails fast instead of
#     emitting `-e RUSTUP_TOOLCHAIN=`. Copy the wrapper so ENV_ROOT resolves to a
#     throwaway tree with its own toolchains.env.
mkdir -p "$tmp/fake-env/scripts"
cp "$WRAPPER" "$tmp/fake-env/scripts/xila-dev"
: > "$tmp/fake-env/toolchains.env"
if XILA_DEV_ENGINE=docker bash "$tmp/fake-env/scripts/xila-dev" \
     --print --workspace "$tmp" run true >/dev/null 2>&1; then
  fail "wrapper accepted a manifest without XILA_RUST_TOOLCHAIN"
fi

# 14. The image targets Debian Trixie and publishes both supported architectures.
dockerfile="$REPO_ROOT/Dockerfile"
workflow="$REPO_ROOT/.github/workflows/publish-image.yml"
assert_contains "$(<"$dockerfile")" "FROM debian:trixie"
assert_contains "$(<"$dockerfile")" "docker build --tag development-environment:local ."
assert_contains "$(<"$dockerfile")" 'org.opencontainers.image.title="development-environment"'
assert_not_contains "$(<"$dockerfile")" "install-tools.sh"
assert_contains "$(<"$dockerfile")" "arm64) node_arch=arm64"
assert_contains "$(<"$workflow")" "platform: linux/amd64"
assert_contains "$(<"$workflow")" "platform: linux/arm64"
assert_contains "$(<"$workflow")" "images: ghcr.io/xila-project/development-environment"
assert_not_contains "$(<"$workflow")" "ghcr.io/xila-project/core-dev"
assert_not_contains "$(<"$workflow")" "docker/setup-qemu-action@v3"
assert_contains "$(<"$workflow")" 'runs-on: ${{ matrix.runner }}'
assert_contains "$(<"$workflow")" "ubuntu-24.04-arm"
assert_contains "$(<"$workflow")" "docker buildx imagetools create"
assert_contains "$(<"$workflow")" 'flavor: latest=false,suffix=-${{ matrix.arch }}'
assert_contains "$(<"$workflow")" 'cache-to: type=gha,scope=core-dev-${{ matrix.arch }},mode=max'

# The Dockerfile sanity checks keep pin comparisons readable and check tool
# presence only once.
assert_contains "$(<"$dockerfile")" "assert_pin_matches()"
assert_contains "$(<"$dockerfile")" 'assert_pin_matches "RUSTUP_TOOLCHAIN"'
assert_not_contains "$(<"$dockerfile")" "command -v bash clang cargo rustup node npm trunk taplo sccache cargo-make"

echo "PASS: all xila-dev wrapper tests"
