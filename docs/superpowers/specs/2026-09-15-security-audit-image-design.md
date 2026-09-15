# Security Audit Toolbox — Single Docker Image

Date: 2026-09-15
Status: Approved (design)
Topic: `security-check`

## Context

This repository hosts a security-audit toolbox used both locally (driven by a
`Makefile`) and in GitHub Actions CI. The goal is to run a fixed set of audit
tools **without installing any of them on the host**:

- Gitleaks (secret scanning)
- OpenGrep (SAST)
- Trivy (filesystem / config / vulnerability scanning)
- Checkov (IaC)
- OSV-Scanner (software composition analysis)

Everything runs from a single Docker image. The image must pin exact tool
versions (never `:latest`), and every binary must be **copied from its official
image** rather than installed by a script at runtime, so the build is
reproducible and verifiable.

The repository starts empty (no commits). This spec defines the first
implementation.

## Goals

- One Docker image containing all five tools at pinned versions.
- No local installation of any tool; local usage goes through `make`, CI usage
  goes through the same `make` targets.
- Tool binaries sourced by copy from official images (multi-stage build), with
  no runtime install scripts.
- A published, pinned image on GHCR shared literally between local and CI.
- Auditable, reproducible build (pinned versions, pinned base image, checksum
  verification for the one tool without an official image).
- SARIF reports for every tool, consumable by GitHub code scanning.

## Non-goals

- Multi-architecture builds. The developer machine is Intel x86_64 and CI runs
  on x86_64, so the image targets `linux/amd64` only.
- Auto-fixing findings or gating on custom policy engines beyond per-category
  exit codes.
- Baking vulnerability databases or rule sets into the image (data is fetched
  at run time, with a persistent cache).

## Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Sourcing strategy | Copy binaries from official images; OpenGrep from its official release binary | No runtime installs; reproducible |
| Checkov handling | Use `bridgecrew/checkov` **as the final base image** | Checkov is a Python app, not a standalone binary; avoids `pip install` |
| OpenGrep handling | No official image exists; download and checksum-verify the official standalone binary | Closest to "official binary"; offline-verifiable at build |
| Interface | `audit` wrapper (categories) + raw binaries on `PATH` | Uniform UX, defaults centralized, advanced usage unobstructed |
| Distribution | Build and push to GHCR; local and CI pull the pinned image | Single source of truth |
| Runtime data | Download at run time with a persistent cache volume | Image stays small; data stays fresh |
| Exit policy | Graded by category (secrets + SCA fail, SAST + IaC report) | Usable start, tunable |
| Architecture | `linux/amd64` only | Developer on Intel i7 |

## Architecture

```
Multi-stage build:

  ghcr.io/gitleaks/gitleaks:v8.30.1     ->  /usr/bin/gitleaks       ─┐
  aquasec/trivy:0.74.0                  ->  /usr/local/bin/trivy     ─┤
  ghcr.io/google/osv-scanner:v2.6.0     ->  /osv-scanner             ─┤
                                                                      ├─ COPY
  bridgecrew/checkov:3.3.17  (BASE)     ->  checkov + Python 3.11    ─┤
  opengrep release v1.30.0 (sha256-verified stage) -> /opengrep      ─┘
        |
        v
  Final image (linux/amd64):
    /usr/local/bin/gitleaks
    /usr/local/bin/trivy
    /usr/local/bin/osv-scanner
    /usr/local/bin/opengrep
    /usr/local/bin/checkov          (from base image)
    /usr/local/bin/audit            (wrapper)
    WORKDIR /workspace
    ENTRYPOINT ["audit"]
```

### Why the Checkov image is the base

Checkov is distributed as a Python package, not a standalone binary. Its
official image (`bridgecrew/checkov`) is `python:3.11-slim` (Debian/glibc) with
Checkov plus `helm` and `kustomize` already installed. Using it as the final
base eliminates any `pip install` at build or run time. The other tools are
statically linked Go binaries (`CGO_ENABLED=0`) and the OpenGrep standalone
binary is a glibc (`manylinux`) build, so all of them run unmodified on this
glibc base.

## Tool sourcing and pinned versions

| Tool | Source image / artifact | Source path | Pinned version |
|---|---|---|---|
| Gitleaks | `ghcr.io/gitleaks/gitleaks` | `/usr/bin/gitleaks` | `v8.30.1` |
| Trivy | `aquasec/trivy` | `/usr/local/bin/trivy` | `0.74.0` |
| OSV-Scanner | `ghcr.io/google/osv-scanner` | `/osv-scanner` | `v2.6.0` |
| Checkov | `bridgecrew/checkov` (base) | in image | `3.3.17` |
| OpenGrep | GitHub release `opengrep/opengrep` | `opengrep_manylinux_x86` | `v1.30.0` |

OpenGrep checksum (v1.30.0, `opengrep_manylinux_x86`):

```
sha256:35779bdd72e92129c8df2a77f0c55e8c08356801ea92591ef32108d6b28d564c
```

The OpenGrep download happens in a dedicated build stage using `curl` and
`ca-certificates` (build-time only), and is verified with `sha256sum -c` before
the binary is copied into the final image. The checksum is a pinned `ARG`, so a
changed upstream artifact fails the build. (Optional hardening: also verify the
project's Cosign `.cert`/`.sig`.)

### Notes on source paths

- The published `ghcr.io/google/osv-scanner:v2.6.0` image has `WorkingDir=/`
  and `Entrypoint=["/osv-scanner"]`, so the binary is `/osv-scanner`. This is
  what the published image actually contains; the project's repository
  `Dockerfile` at that tag differs (`/root/osv-scanner`), so the image, not the
  repo Dockerfile, is authoritative.
- The target platform is pinned at the build invocation
  (`docker buildx build --platform linux/amd64`; CI `platforms: linux/amd64`)
  rather than in `FROM` lines, because the OpenGrep asset is x86-64 only and
  BuildKit discourages a constant `--platform` on `FROM`.
- Image tags above were verified to exist at design time.

## Wrapper `audit`

Location: `/usr/local/bin/audit` (bash). Entrypoint of the image.

### Subcommands

| Command | Tools | Default blocking |
|---|---|---|
| `audit secrets` | Gitleaks | yes |
| `audit sast` | OpenGrep | no |
| `audit iac` | Checkov + `trivy config` | no |
| `audit sca` | OSV-Scanner + `trivy fs` | yes (HIGH, CRITICAL) |
| `audit all` | all of the above | per-category, aggregated |

### Behavior

- Writes SARIF to `$REPORTS_DIR` (default `/workspace/security-reports`).
- Any argument that is not a known subcommand is executed verbatim:
  `audit bash`, `audit gitleaks ...`. This keeps raw binaries fully usable.
- Aggregates exit codes for `audit all` according to the blocking policy.
- Creates `$REPORTS_DIR` if missing.

### Environment variables

| Variable | Default | Meaning |
|---|---|---|
| `REPORTS_DIR` | `/workspace/security-reports` | SARIF output directory |
| `FAIL_ON_SECRETS` | `1` | Gitleaks failure is blocking |
| `FAIL_ON_SCA` | `1` | OSV/Trivy HIGH,CRITICAL failure is blocking |
| `FAIL_ON_SAST` | `0` | OpenGrep findings are non-blocking |
| `FAIL_ON_IAC` | `0` | Checkov/Trivy config findings are non-blocking |

### Report files

| File | Tool |
|---|---|
| `gitleaks.sarif` | Gitleaks |
| `opengrep.sarif` | OpenGrep |
| `checkov.sarif` | Checkov |
| `trivy-config.sarif` | Trivy config |
| `osv.sarif` | OSV-Scanner |
| `trivy-fs.sarif` | Trivy filesystem |

## Runtime identity and cache

To let the container run as the host user (`-u $(id -u):$(id -g)`) without
leaving root-owned report files, and to let tools write caches:

- `ENV HOME=/cache`, `XDG_CACHE_HOME=/cache`, `TRIVY_CACHE_DIR=/cache/trivy`.
- `/cache` is created in the image with mode `1777` (writable by any UID).
- `git config --system --add safe.directory '*'` is set in the image, to avoid
  Git "dubious ownership" errors when scanning a mounted repository owned by
  another UID.
- A host cache directory (`$(HOME)/.cache/security-audit` by default) is
  bind-mounted at `/cache`, so data downloaded by the tools (Trivy DB, OpenGrep
  rules) is reused across runs and remains owned by the host user (a named volume
  would be created root-owned and break `-u`).

## Makefile

Variables:

- `IMAGE ?= ghcr.io/erikaouizerate/security-check:latest` (pull target), and a
  local build tag `security-check:local`. The audit CI job runs the published
  `:latest` image (default branch and scheduled runs). PR runs audit the last
  published image, because PR builds are not pushed to GHCR, so no per-PR
  immutable tag is available to the audit job.
- `REPORTS_DIR ?= security-reports`
- Common run prefix: `docker run --rm -u $(id -u):$(id -g) -e HOME=/cache
  -v $(CURDIR):/workspace -w /workspace -v security-audit-cache:/cache`.

Targets:

- `build` — build the local image (`docker buildx build --load`, native amd64).
- `pull` — pull the pinned image from GHCR.
- `audit` — run `audit all`.
- `secrets`, `sast`, `iac`, `sca` — run one category.
- `clean` — remove `$(REPORTS_DIR)` and the local image.

CI reuses these targets so the invocation logic lives in exactly one place.

## CI (GitHub Actions)

### `build-image.yml`

- Triggers: changes to `Dockerfile.security`, the workflow itself, tags, and
  `workflow_dispatch`.
- Permissions: `contents: read`, `packages: write`.
- Steps: checkout; `docker/setup-buildx-action`; log in to GHCR; build and push
  `ghcr.io/${{ github.repository }}` (`linux/amd64`) tagged `sha-<short>`, plus
  `vX.Y.Z`/`latest` on tag; emit provenance and SBOM.

### `security-audit.yml`

- Triggers: `pull_request`, `push` to `main`, weekly `schedule`.
- Permissions: `contents: read`, `packages: read`, `security-events: write`.
- Steps: checkout with `fetch-depth: 0` (Gitleaks needs history); log in to
  GHCR; pull the published `:latest` image (default branch and scheduled runs;
  PRs audit the last published image because PR builds are not pushed); run
  `make audit`; upload each SARIF via
  `github/codeql-action/upload-sarif` with a distinct `category`; upload the
  reports directory as an artifact. The wrapper's graded exit codes decide
  whether the job fails.

## Repository scaffold

Per project conventions, the repository also gets:

- `Dockerfile.security`
- `audit` (wrapper script)
- `Makefile`
- `.dockerignore`
- `.github/workflows/build-image.yml`, `.github/workflows/security-audit.yml`
- `README.md` (English) documenting local usage and CI
- `INSTRUCTIONS.md` (French, next steps; kept even when empty)
- `AGENTS.md` (global + infrastructure/deployment policies copied inline from
  Basic Memory, with plain-text source references; never `memory://` links)
- `.gitignore` ignoring `security-reports/`, `.superpowers/`, and
  `docs/superpowers/plans/` (specs remain versioned)

## Reproducibility and verification

- All upstream images pinned to exact tags; no `:latest`.
- OpenGrep artifact pinned to version **and** sha256.
- Build is fully multi-stage; no package installation at run time.
- CI publishes provenance and an SBOM alongside the image.
- Verification (manual, post-build):
  - `docker run --rm <image> gitleaks version` etc. for each tool.
  - `docker run --rm <image> bash -lc 'command -v gitleaks trivy osv-scanner opengrep checkov audit'`.
  - `make audit` on this repository produces the six SARIF files and the
    expected exit status under the graded policy.

## Testing strategy

- Smoke test: build the image, then assert each tool reports its pinned version.
- Wrapper unit behavior: unknown subcommand execs verbatim; `FAIL_ON_*`
  variables change the exit code as documented.
- End-to-end: run `make audit` on this repository (with a small fixture) and
  assert report files exist and CI exit behavior matches the policy.
- CI validation: the two workflows run on the repository itself.

## Resolved open questions

1. GHCR namespace: `ErikAouizerate/security-check` → `ghcr.io/erikaouizerate/security-check`.
2. Pinned versions: as listed above (approved).
3. Architecture: `linux/amd64` only (Intel i7).
4. Scaffold: included.
