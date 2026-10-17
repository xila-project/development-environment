# Project Name Expansion Design

## Goal

Replace project-owned uses of the abbreviation `dev` with the full word
`development`. This repository is not yet in use, so the migration does not
need compatibility aliases for the old names.

## Canonical Names

- Published image: `ghcr.io/xila-project/core-development`
- Local image: `xila-core-development:local`
- Wrapper command and file: `xila-development`
- Wrapper variables: `XILA_DEVELOPMENT_IMAGE` and
  `XILA_DEVELOPMENT_ENGINE`
- Workspace state directory: `.xila-development-environment`
- Build cache scopes: `core-development-amd64` and
  `core-development-arm64`

The OCI image title will become `xila-core-development`. The wrapper test file
will be renamed to `xila-development.test.sh`.

## Scope and Behavior

Update the Dockerfile, wrapper, wrapper tests, publishing workflow, ignore rules,
and README references consistently. The wrapper will use only the new command,
environment-variable names, and workspace state directory; no old-name aliases
will be kept. CI will publish only the new GHCR package name under its existing
branch, commit, latest, and semantic-version tags.

Leave platform paths such as `/dev/null` and Debian package names ending in
`-dev` unchanged; those are system names, not project abbreviations. Leave
`toolchains.env` and toolchain channel names unchanged.

## Validation

- Wrapper tests exercise the renamed command and environment variables.
- Static checks ensure project-owned old names are no longer referenced by the
  Dockerfile, wrapper, workflow, ignore rules, or README.
- Run the wrapper test suite, `docker build --check .`, and `git diff --check`.
- A full image build is not required for this naming-only migration.
