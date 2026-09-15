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

## Exit policy

| Category | Command | Blocking by default |
|---|---|---|
| secrets | `make secrets` | yes |
| sca | `make sca` | yes (HIGH, CRITICAL) |
| sast | `make sast` | no |
| iac | `make iac` | no |

Override with `FAIL_ON_SECRETS`, `FAIL_ON_SCA`, `FAIL_ON_SAST`, `FAIL_ON_IAC`
(`1`/`0`).

## CI

- `.github/workflows/build-image.yml` builds and pushes the image to GHCR.
- `.github/workflows/security-audit.yml` runs the audit and uploads the SARIF
  reports to GitHub code scanning.

`security-audit` runs the published `latest` image (scheduled and default-branch
runs). PR builds are not pushed to GHCR, so a pull request audits the last
published image rather than its own build.

See `docs/superpowers/specs/2026-09-15-security-audit-image-design.md` for the
design.
