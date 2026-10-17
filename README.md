# Xila development environment

This repository defines the canonical **development image** for building Xila: a
pinned toolchain and system environment that makes "clone and compile" work the
same on every contributor machine, with no host-level setup beyond a container
engine (Docker or Podman).

The image is an environment, **not the Xila runtime**. Xila is an embedded
operating system that runs on microcontrollers; this image never contains the OS
or any device firmware. It only carries the compilers, tooling and libraries
needed to build, test and lint an Xila checkout.

## Contents

Built from `ubuntu:24.04`, the image ships the pinned toolchain:

- Rust stable and nightly toolchains, with `rustfmt`, `clippy`,
  `llvm-tools-preview`, `rust-src`, `miri`, and the `wasm32-unknown-unknown`,
  `wasm32-wasip1`, `i686-unknown-linux-gnu` and `powerpc-unknown-linux-gnu`
  targets.
- Clang / `libclang` with the WASM cross-compilation environment variables set.
- Node.js and npm (for the web tooling).
- Cargo tools: `cargo-make`, `trunk`, `taplo`, `cargo-llvm-cov`, `sccache` and
  `cargo-binstall`.
- System libraries for native and GUI builds (`packages.txt`).

## Version pins

`toolchains.env` is the **single source of truth** for tool versions. The
installer (`install-tools.sh`) and the image read their pins from it; do not
duplicate versions elsewhere. Downstream project CI reads the same file. To
upgrade a tool, edit that file and rebuild the image, which invalidates only the
toolchain layer.

A few values that Docker cannot read from the file at `ENV` time are baked into
the `Dockerfile`: the default `RUSTUP_TOOLCHAIN` mirrors this manifest, and
`LIBCLANG_PATH` points at the base image's `clang`. A build-time sanity check
guards the toolchain and `libclang`.

## Building and pulling

Build locally from this repository's root — the repository is the build context:

```bash
docker build --tag xila-core-dev:local .
```

Pulling is for the published image:

```bash
docker pull ghcr.io/xila-project/core-dev:main
```

GHCR publishing is not part of this phase (see [Scope](#scope)), so today the
local build above is the intended path.

## Using `scripts/xila-dev`

`scripts/xila-dev` is the supported entry point. It picks a container engine,
bind-mounts the **workspace** (the Xila checkout you want to build) at
`/workspace`, runs as your host UID/GID, and wires up the caches below so
container-side builds are fast and host-owned.

Run it from the project you are working on (its current directory is the
workspace), or pass `--workspace <path>` explicitly. The image itself is built
from the `Dockerfile` in this repository.

Subcommands:

| Command | Purpose |
| --- | --- |
| `build` | Build the configured image tag (`$XILA_DEV_IMAGE`, default `ghcr.io/xila-project/core-dev:main`) from this repository's `Dockerfile`. |
| `pull` | Pull the configured image. |
| `shell` | Interactive login shell inside the container, in the workspace. |
| `run <cmd...>` | Run a command in the container. |
| `check` | Run `cargo make check` in the workspace. |
| `doctor` | Print engine, image, mounts and tool versions to diagnose setup. |

Global flags:

| Flag | Purpose |
| --- | --- |
| `--workspace <path>` | Repository to mount at `/workspace` (default: current directory). |
| `--gui` | Opt-in: forward the Wayland socket and environment for GUI builds. |
| `--device <path>` | Opt-in: pass a host device (MCU/serial); repeatable. |
| `--engine docker\|podman` | Choose the container engine explicitly. |
| `--verbose` | Print the resolved command before running it. |
| `--print` | Print the resolved command and exit without running it. |

Examples:

```bash
/path/to/development-environment/scripts/xila-dev build   # build the image
cd /path/to/Xila/Core
/path/to/development-environment/scripts/xila-dev shell    # shell in Core
scripts/xila-dev run -- cargo --version
scripts/xila-dev check                                     # cargo make check
```

The default image is `ghcr.io/xila-project/core-dev:main`; set
`XILA_DEV_IMAGE=xila-core-dev:local` to use a locally built one.

## Caches

The wrapper keeps all persistent state in `.dev-environment/` at the workspace
root, which should be gitignored and is never committed:

| Path | Holds |
| --- | --- |
| `.dev-environment/cargo` | `CARGO_HOME`. |
| `.dev-environment/target` | `CARGO_TARGET_DIR`. |
| `.dev-environment/npm-cache` | npm's cache. |
| `.dev-environment/trunk-cache` | Trunk's cache. |
| `.dev-environment/home` | Container `HOME`. |

Deleting the directory resets the environment.

## Known limitations

- **Git worktrees are not supported as the workspace.** Only the workspace is
  mounted at `/workspace`, so a linked worktree — where `.git` is a *file*
  pointing at a path outside the workspace — leaves the container without a
  usable repository and tasks that shell out to `git` (such as the workspace's
  font generation via a `github:` npm dependency) fail. Use a normal clone of
  the project as the workspace.

## Opt-in host access

Both of these are off by default and only enabled when requested:

- `--gui` forwards **only** the Wayland socket and its environment variables (for
  running GUI examples). It never uses `--privileged` and does not mount the
  whole host.
- `--device <path>` passes a single host device through for microcontroller and
  serial work; repeat the flag for more devices.

## Scope

This image and the `scripts/xila-dev` wrapper are the deliverables of the current
phase of [issue #414](https://github.com/Xila-Project/Core/issues/414). GHCR
publishing, CI migration onto this image, Dev Container support and Devbox
removal are later phases of that issue and are not covered here.
