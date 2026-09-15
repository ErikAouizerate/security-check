# AGENTS.md — security-check

## Stack

- `Dockerfile.security`: single image bundling Gitleaks, OpenGrep, Trivy,
  Checkov, OSV-Scanner (pinned versions, binaries copied from official images).
- `audit`: bash wrapper, image entrypoint, dispatching the tools and applying
  the exit policy.
- `Makefile`: local entry point only; CI does not use it.
- `.github/workflows/`: GitHub Actions (build/push the image, run the audit).
  `security-audit.yml` is self-contained (inlines its `docker run`) so it can be
  copied into another repository without the `Makefile`.

## Global conventions (content copied from Basic Memory, project "main")

- Communication with the user is in French; all code, documentation, and tests
  are in English. (Réf. « Communication Language Convention (AGENTS.md - CLAUDE.md) »)
- `docs/` and this guidance file (`AGENTS.md`) are committed alongside the code
  they document; update them whenever architecture or scope changes.
  (Réf. « Docs Maintenance Policy »)
- Only specs are versioned: `docs/superpowers/specs/` is committed.
  `docs/superpowers/plans/` and `.superpowers/` are generated locally and are
  gitignored — never committed.
  (Réf. « Superpowers Plans & Artifacts — Specs Only, Never Committed »)
- Basic Memory (project "main") is the persistent memory shared with the user:
  when an instruction says "note", write a Basic Memory note through the MCP
  tools. Search before writing; agents write `raw`/`candidate` notes by default
  and never promote, rewrite or delete `canonical` notes without explicit
  authorization; notes are autonomous (no external vault or file-path
  references).
  (Réf. « Basic Memory Notes — Authoring Guide for AI Assistants »)
- Structural code research must go through the codebase-memory-mcp knowledge
  graph (`search_graph`, `trace_path`, `get_code_snippet`, `get_architecture`,
  `query_graph`, `check_index_coverage`) rather than ad-hoc grep/glob sweeps.
  grep/glob remain fallbacks for string literals, error messages, config values,
  and non-code files (Dockerfile, shell, YAML).
  (Réf. « Code Research — Codebase Memory MCP »)

## Deploy / CI

- This repository deploys no application. It builds and publishes a Docker image
  to GHCR and runs security scans in GitHub Actions. The Dokploy + Traefik,
  Docker Compose, and GitLab CI policies do not apply (GitHub Actions, no
  long-running service).
- Production is the image registry and the CI pipeline. Never push an image, a
  tag, or a workflow run to the registry from the agent: hand the exact commands
  to the user.
  (Réf. « Production Access — No Agent Actions, Only Commands for the User »)
