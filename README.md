# security-check

A single Docker image bundling the security-audit toolchain, usable locally via
`make` and in GitHub Actions. No tool is installed on the host.

## Tools (pinned)

| Tool | Version | Role |
|---|---|---|
| Gitleaks | v8.30.1 | secret scanning |
| OpenGrep | v1.30.0 | SAST |
| Trivy | 0.74.0 | filesystem / config / vulnerabilities |
| Checkov | 3.3.17 | IaC |
| OSV-Scanner | v2.6.0 | software composition analysis |

All binaries are copied from the tools' official images during the build
(multi-stage), except OpenGrep which has no official image: its official
standalone binary is downloaded and verified against a pinned sha256. Checkov,
a Python application rather than a standalone binary, is provided by its
official image used as the final build stage (base). The build is therefore
reproducible and involves no runtime install script.

## Local usage

```bash
make build          # build the image locally (security-check:local)
make audit          # run the full audit (all categories)
make secrets        # Gitleaks only
make sast           # OpenGrep only
make iac            # Checkov + trivy config
make sca            # OSV-Scanner + trivy fs
```

Reports are written as SARIF to `security-reports/`.

The image runs as your host UID (`-u $(id -u):$(id -g)`), so report files are not
owned by root. Caches (Trivy DB, OpenGrep rules) are persisted in
`~/.cache/security-audit` (override with `CACHE_DIR=...`).

### Using the published image

```bash
make audit IMAGE=ghcr.io/erikaouizerate/security-check:latest
```

### Auditing another project

By default `make` audits this repository. Point it at any folder with `TARGET`:

```bash
make audit TARGET=/path/to/project
make sast TARGET=/path/to/project   # one category only: secrets|sast|iac|sca
```

The folder is mounted at `/workspace` and every tool scans the current
directory, so reports land in `/path/to/project/security-reports/`. Add that
directory to the target project's `.gitignore`, or use the read-only recipe
below.

#### The installed wrapper: audit from any folder

Install the wrapper once, then run it from inside the project you want to audit;
the current directory becomes the target automatically.

```bash
make install                     # -> ~/.local/bin/security-check (+ sec alias)
make install PREFIX=/usr/local   # system-wide
```

`make install` also installs the global, secrets-only `pre-push` hook through
`git-hooks/install-pre-push-secrets.sh` (in addition to the wrapper). It is
idempotent: if the guardrail is already installed it is left untouched. Use the
installer directly with `--force` to reinstall, `--dry-run` to preview, or
`--uninstall` to remove it.

```bash
security-check                   # all categories, current directory
security-check sast              # one category: all|secrets|sast|iac|sca
security-check all /path/project # explicit target
security-check --help
sec sca                          # short alias
```

Reports are written **outside** the audited folder, under
`~/.local/share/security-check/reports/<project>/` (override with `--reports DIR`
or `REPORTS_DIR=...`), so the target needs no `.gitignore` change. The target is
mounted read-only at `/workspace`. Select the image with `--image` or `IMAGE`
(default: the published GHCR image; use `IMAGE=security-check:local` for a local
build). The `FAIL_ON_*` variables are forwarded, so the exit policy is the same
as `make`.

The `secrets` category runs `gitleaks git`, so the target must be a Git
repository (it scans the history). For a non-Git directory, run Gitleaks in
directory mode through the wrapper's verbatim passthrough:

```bash
docker run --rm -u "$(id -u):$(id -g)" \
  -v "/path/to/tree:/workspace" \
  -v "$HOME/.cache/security-audit:/cache" \
  -w /workspace security-check:local \
  audit gitleaks dir --report-format sarif \
    --report-path /workspace/security-reports/gitleaks.sarif .
```

#### Auditing third-party code without modifying it

To keep the scanned folder read-only and write reports outside it, mount the
target at `/workspace` read-only, add a writable reports mount, and redirect the
wrapper with `REPORTS_DIR`:

```bash
TARGET=/path/to/project
REPORTS="$PWD/reports/$(basename "$TARGET")"
mkdir -p "$REPORTS" "$HOME/.cache/security-audit"

docker run --rm \
  -u "$(id -u):$(id -g)" \
  -v "$TARGET:/workspace:ro" \
  -v "$REPORTS:/reports" \
  -v "$HOME/.cache/security-audit:/cache" \
  -w /workspace \
  -e REPORTS_DIR=/reports \
  security-check:local audit all
```

To change the exit policy for a run, add the matching variable, e.g.
`-e FAIL_ON_SAST=1` or `-e FAIL_ON_SECRETS=0` (see "Exit policy" below). Use the
pinned `ghcr.io/erikaouizerate/security-check:latest` image in place of
`security-check:local` once it is published.

## Exit policy

| Category | Command | Blocking by default |
|---|---|---|
| secrets | `make secrets` | yes |
| sca | `make sca` | yes (HIGH, CRITICAL) |
| sast | `make sast` | no |
| iac | `make iac` | no |

Override with `FAIL_ON_SECRETS`, `FAIL_ON_SCA`, `FAIL_ON_SAST`, `FAIL_ON_IAC`
(`1`/`0`).

### Checkov configuration

Every scan runs Checkov with the bundled `.checkov.yaml` (installed at
`/etc/security-check/checkov.yaml`). It skips generated, vendored and cache
directories (`node_modules`, `.venv`, `__pycache__`, `.cache`,
`fastembed_cache`, …) that otherwise trigger false positives such as high-entropy
strings in model caches. It disables no check, so detection quality is preserved.

Because Checkov is invoked with `--config-file`, a `.checkov.yaml` found in the
scanned project is ignored. To use your own config, set `CHECKOV_CONFIG_FILE` to
a path inside the container (mount the file there).

## CI

- `.github/workflows/build-image.yml` builds and pushes the image to GHCR.
- `.github/workflows/security-audit.yml` runs the audit and uploads the SARIF
  reports to GitHub code scanning. It is self-contained (inlines its
  `docker run`, no `Makefile` needed), so it can be copied into another
  repository as-is.

`security-audit` runs the published `latest` image (scheduled and default-branch
runs). PR builds are not pushed to GHCR, so a pull request audits the last
published image rather than its own build.

See `docs/superpowers/specs/2026-09-15-security-audit-image-design.md` for the
design.
