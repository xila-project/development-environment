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
assert_contains "$out" "ghcr.io/xila-project/core-dev:main"
assert_contains "$out" "echo hi"

# 2. Image override via the environment.
out="$(XILA_DEV_ENGINE=docker XILA_DEV_IMAGE=custom:test "$WRAPPER" --print --workspace "$tmp" run true)"
assert_contains "$out" "custom:test"

# 3. --gui forwards the Wayland socket and never escalates privileges.
out="$(XILA_DEV_ENGINE=docker WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR=/run/user/1000 \
  "$WRAPPER" --print --gui --workspace "$tmp" run true)"
assert_contains "$out" "/run/user/1000/wayland-0"
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
assert_contains "$out" "$REPO_ROOT"

# 8. doctor under --print resolves the probe without touching the filesystem.
rm -rf "$tmp/.dev-environment"
out="$(XILA_DEV_ENGINE=docker "$WRAPPER" --print --workspace "$tmp" doctor 2>/dev/null)"
assert_contains "$out" "bash -lc"
assert_contains "$out" "rustc"
assert_contains "$out" "node"
assert_absent "$tmp/.dev-environment"

echo "PASS: all xila-dev wrapper tests"
