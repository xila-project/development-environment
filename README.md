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
- Clang / `libclang` 21.1.8 (from apt.llvm.org) with the WASM cross-compilation
  environment variables set.
- Node.js and npm (for the web tooling).
- Cargo tools: `cargo-make`, `trunk`, `taplo`, `cargo-llvm-cov`, `sccache` and
  `cargo-binstall`.
- System libraries for native and GUI builds (`packages.txt`).

## Version pins

`toolchains.env` is the **single source of truth** for tool versions. The
installer (`install-tools.sh`) and the image read their pins from it; do not
duplicate versions elsewhere. Downstream project CI will consume the same file in
a later phase. To upgrade a tool, edit that file and rebuild the image. For most
tools this invalidates only the toolchain layer; `LLVM_VERSION` is the exception,
since the `Dockerfile` also bakes it into an `ENV` and uses it to select the apt
suite, so bumping it means updating the `Dockerfile` too and rebuilds the
apt.llvm.org layer as well.

A few values that Docker cannot read from the file at `ENV` time are baked into
the `Dockerfile`: the default `RUSTUP_TOOLCHAIN` mirrors this manifest, and
`LIBCLANG_PATH` points at the pinned `clang`. `LLVM_VERSION` lives in
`toolchains.env`, while the `Dockerfile` pins the matching apt.llvm.org `clang`
and `libclang` and sets the `CC`/`CXX` (including the `wasm32` overrides) that
resolve to it. A build-time sanity check guards the toolchains, the pinned
`cargo-binstall` version, `libclang` and the installed `clang` version, and fails
the build when those hardcoded `ENV` values drift from the manifest.

> **Clang version divergence (temporary).** This image ships clang 21.1.8, which
> is what Devbox resolved and what builds Xila on the maintainer's machine.
> Project CI still uses the `ubuntu-latest` apt `clang` (18). The two will be
> aligned in the later CI-migration phase; until then, native and WASM builds
> that succeed here are validated against 21.1.8, not CI's 18.

> **Residual LLVM runtime.** No clang or `libclang` 18 remains in the image — the
> compilers are 21.1.8. The GUI stack still pulls in a transitive runtime
> `libllvm20` (via mesa/`libgl-dev`); that is a library dependency of the GUI
> stack, not a compiler, and does not change the toolchain version.

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

### Download trust boundary

The build downloads a few things over the network. Node.js is verified: the
tarball is checked against the official `SHASUMS256.txt` before extraction. The
`rustup` bootstrap script and the `cargo-binstall` installer are fetched over TLS
(`curl --proto '=https'`, certificate validation on) and executed without an
independent checksum or signature check, so their integrity rests on TLS plus
the pinned GitHub tag/URL they are fetched from.

Clang and `libclang` come from the third-party `apt.llvm.org` repository (the
`llvm-toolchain-noble-21` suite). Its signing key is fetched over HTTPS and the
repository is scoped with `signed-by`, but the key is not pinned to a
fingerprint: trust in it is trust-on-first-use over TLS.

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
| `--gui` | Opt-in: forward the display for GUI builds — the Wayland socket/env when a Wayland session is available, otherwise X11 as a fallback. |
| `--device <path>` | Opt-in: pass a host device (MCU/serial); repeatable. |
| `--engine docker\|podman` | Choose the container engine explicitly. |
| `--verbose` | Print the resolved command before running it. |
| `--print` | Print the resolved command and exit without running it. |

Examples:

```bash
/path/to/development-environment/scripts/xila-dev build   # build the image
cd /path/to/Xila/Core
/path/to/development-environment/scripts/xila-dev shell    # shell in Core
/path/to/development-environment/scripts/xila-dev run -- cargo --version
/path/to/development-environment/scripts/xila-dev check     # cargo make check
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

- **The LLVM apt pin is major-version only, so rebuilds are not byte-reproducible
  over time.** The apt suite is `llvm-toolchain-noble-21`, while the guard pins
  the exact `LLVM_VERSION=21.1.8`. If `apt.llvm.org` republishes a package within
  the 21.x line, the archive no longer serves 21.1.8 and the build-time version
  assertion fails loudly until the pin is bumped — deliberately, so a different
  patch level is never installed silently.

## Opt-in host access

Both of these are off by default and only enabled when requested:

- `--gui` forwards **only** the Wayland socket and its environment variables when
  a Wayland session is available, falling back to the X11 socket
  (`/tmp/.X11-unix`) and `DISPLAY` otherwise (for running GUI examples). It never
  uses `--privileged` and does not mount the whole host.
- `--device <path>` passes a single host device through for microcontroller and
  serial work; repeat the flag for more devices.

## Scope

This image and the `scripts/xila-dev` wrapper are the deliverables of the current
phase of [issue #414](https://github.com/Xila-Project/Core/issues/414). GHCR
publishing, CI migration onto this image, Dev Container support and Devbox
removal are later phases of that issue and are not covered here.
