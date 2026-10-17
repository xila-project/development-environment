# Project Name Expansion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace project-owned `dev` abbreviations with full `development` names throughout the development image interface.

**Architecture:** Rename the wrapper command, its public environment variables, workspace state directory, image/package references, and cache scopes as one consistent interface migration. Since the repository is not yet used, do not retain compatibility aliases for the old project-owned names.

**Tech Stack:** Bash, Dockerfile, GitHub Actions YAML, Markdown, shell tests.

**Spec:** `docs/superpowers/specs/2026-10-17-project-name-expansion-design.md`

## Global Constraints

- Published image: `ghcr.io/xila-project/core-development`
- Local image: `xila-core-development:local`
- Wrapper command and file: `xila-development`
- Wrapper variables: `XILA_DEVELOPMENT_IMAGE` and `XILA_DEVELOPMENT_ENGINE`
- Workspace state directory: `.xila-development-environment`
- Build cache scopes: `core-development-amd64` and `core-development-arm64`
- Keep platform paths such as `/dev/null` and Debian package names ending in `-dev` unchanged.
- Keep `toolchains.env` and toolchain channel names unchanged.
- Do not provide old-name compatibility aliases.

## Review Focus

- An inherited old `XILA_DEV_IMAGE` must not alter the renamed wrapper's default image; test that only `XILA_DEVELOPMENT_IMAGE` controls the image.
- A workspace with no state directory must create/use `.xila-development-environment`; test the printed mount paths and that `--print` does not create it.
- Local image build and pull commands must still target the expected Dockerfile/context and canonical full-name image; test both command constructions.
- CI must retain both architecture builds and publish manifests to the new package under all regular tags; statically assert architecture suffixes, cache scopes, and manifest source/destination names.
- System names containing `dev` must remain intact; assert `/dev/null` and a representative Debian `*-dev` package remain unchanged.

---

### Task 1: Rename the wrapper interface and workspace state

**Files:**
- Rename: `scripts/xila-dev` → `scripts/xila-development`
- Rename: `scripts/tests/xila-dev.test.sh` → `scripts/tests/xila-development.test.sh`
- Modify: `scripts/xila-development`
- Modify: `scripts/tests/xila-development.test.sh`
- Modify: `.gitignore`

**Interfaces:**
- Produces the command `scripts/xila-development`.
- Reads `XILA_DEVELOPMENT_IMAGE` and `XILA_DEVELOPMENT_ENGINE`.
- Stores workspace state in `.xila-development-environment`.

- [ ] **Step 1: Update tests to specify the new interface**

Rename the test file and update it to invoke `scripts/xila-development`. Replace its test configuration with the expanded variable names, assert the default image is `ghcr.io/xila-project/core-development:main`, and assert all cache mounts point under `.xila-development-environment`. Add a test that setting the former `XILA_DEV_IMAGE` does not override the new default, while `XILA_DEVELOPMENT_IMAGE` does.

```bash
unset XILA_DEVELOPMENT_IMAGE XILA_DEVELOPMENT_ENGINE XILA_WORKSPACE XILA_RUST_TOOLCHAIN
out="$(XILA_DEVELOPMENT_ENGINE=docker XILA_DEV_IMAGE=legacy:test \
  "$WRAPPER" --print --workspace "$tmp" run true)"
assert_contains "$out" "ghcr.io/xila-project/core-development:main"
assert_not_contains "$out" "legacy:test"
out="$(XILA_DEVELOPMENT_ENGINE=docker XILA_DEVELOPMENT_IMAGE=custom:test \
  "$WRAPPER" --print --workspace "$tmp" run true)"
assert_contains "$out" "custom:test"
assert_contains "$out" ".xila-development-environment/cargo"
```

- [ ] **Step 2: Run the renamed test and verify it fails**

Run: `bash scripts/tests/xila-development.test.sh`
Expected: it fails because the renamed wrapper and new variables/state paths have not been implemented yet.

- [ ] **Step 3: Rename and update the wrapper**

Rename `scripts/xila-dev` to `scripts/xila-development`. Replace project-owned `xila-dev`, `XILA_DEV_IMAGE`, `XILA_DEV_ENGINE`, and `.dev-environment` references with their full names. Rename the short local loop variable `dev` to `device`; leave `/dev/dri` and `/dev/null` paths unchanged. Update `.gitignore` to ignore `.xila-development-environment/`.

- [ ] **Step 4: Run wrapper tests**

Run: `bash scripts/tests/xila-development.test.sh`
Expected: `PASS: all xila-development wrapper tests`.

- [ ] **Step 5: Commit the wrapper migration**

```bash
git add -A scripts .gitignore
git commit -m "refactor: expand development wrapper names"
```

### Task 2: Rename image publication and architecture caches

**Files:**
- Modify: `Dockerfile`
- Modify: `.github/workflows/publish-image.yml`
- Modify: `scripts/tests/xila-development.test.sh`

**Interfaces:**
- Consumes: the renamed wrapper test suite from Task 1.
- Produces: image names under `ghcr.io/xila-project/core-development`, cache scopes `core-development-amd64` / `core-development-arm64`, and OCI title `xila-core-development`.

- [ ] **Step 1: Add failing assertions for the full image and cache names**

Update the static assertions in `scripts/tests/xila-development.test.sh` to require the full OCI title, package name, manifest source references, and per-architecture cache scopes.

```bash
assert_contains "$(<"$dockerfile")" 'org.opencontainers.image.title="xila-core-development"'
assert_contains "$(<"$workflow")" "images: ghcr.io/xila-project/core-development"
assert_contains "$(<"$workflow")" 'scope=core-development-${{ matrix.arch }}'
```

- [ ] **Step 2: Verify the new assertions fail against old publication names**

Run: `bash scripts/tests/xila-development.test.sh`
Expected: failure identifies the remaining old image or cache reference.

- [ ] **Step 3: Update Docker and CI references**

Change the Dockerfile local build comment and OCI title to `xila-core-development`. In `.github/workflows/publish-image.yml`, update both metadata image names and both manifest source references to `ghcr.io/xila-project/core-development`; update cache scopes to `core-development-${{ matrix.arch }}`. Keep the existing per-architecture build matrix, native runners, manifest flow, and tag patterns unchanged.

- [ ] **Step 4: Verify wrapper and publication assertions**

Run: `bash scripts/tests/xila-development.test.sh`
Expected: `PASS: all xila-development wrapper tests`.

- [ ] **Step 5: Commit image and CI names**

```bash
git add Dockerfile .github/workflows/publish-image.yml scripts
git commit -m "ci: expand development image names"
```

### Task 3: Update documentation and audit stale project names

**Files:**
- Modify: `README.md`
- Modify: `.gitignore` if any wrapper references remain
- Modify: `scripts/tests/xila-development.test.sh`

- [ ] **Step 1: Add a stale-name regression assertion**

Add a test that checks project-owned files for the old command, environment variables, workspace state directory, GHCR package, local tag, and cache scope. Exclude platform paths and Debian package names from this scan; separately assert representative system names remain intact.

- [ ] **Step 2: Run the test and verify stale references are reported**

Run: `bash scripts/tests/xila-development.test.sh`
Expected: failure lists old project-owned names still present in the README or related files.

- [ ] **Step 3: Update the README and any remaining project-owned references**

Update build/pull examples, default image and environment variable docs, wrapper invocation examples, and state-directory documentation to the canonical names. Keep Debian package identifiers and Linux `/dev/*` paths unchanged.

- [ ] **Step 4: Run complete naming and syntax verification**

Run: `bash scripts/tests/xila-development.test.sh && docker build --check . && git diff --check`
Expected: wrapper tests pass, BuildKit reports no Dockerfile warnings, and `git diff --check` is clean.

- [ ] **Step 5: Commit the documentation and final audit**

```bash
git add README.md .gitignore scripts/tests/xila-development.test.sh
git commit -m "docs: use full development names throughout"
```
