#!/usr/bin/env bash
# install-pre-push-secrets.sh
# Installs a GLOBAL, secrets-only pre-push hook: gitleaks leak scan plus a
# sensitive-file-name deny list. It replaces any existing global hook, backing
# the previous one up first (unless --uninstall restores it).
#
# Usage:
#   ./install-pre-push-secrets.sh [--dry-run]
#   ./install-pre-push-secrets.sh --force [--dry-run]
#   ./install-pre-push-secrets.sh --uninstall [--dry-run]
#
# Idempotent: if this guardrail is already installed it is left untouched
# (use --force to reinstall). Bypass at push time: SKIP_SECURITY=1 or
# `git push --no-verify`.
set -euo pipefail

HOOKS_DIR="${HOOKS_DIR:-$HOME/.config/git-hooks}"
HOOK="$HOOKS_DIR/pre-push"
HOOK_MARKER='pre-push secret guardrail (secrets-only)'
DRY_RUN=0
FORCE=0
ACTION=install

usage() {
  cat <<'USAGE'
Usage: install-pre-push-secrets.sh [OPTIONS]

Installs a global, secrets-only git pre-push hook (gitleaks + sensitive file
names) through core.hooksPath. Replaces the existing global hook, keeping a
timestamped backup. If the guardrail is already installed, it is left as-is.

Options:
  --dry-run     Print actions without changing anything.
  --force       Reinstall even when the guardrail is already installed.
  --uninstall   Restore the latest backup, or remove the hook and unset
                core.hooksPath when no backup exists.
  -h, --help    Show this help.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --force) FORCE=1 ;;
    --uninstall) ACTION=uninstall ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

is_installed() {
  local current
  current="$(git config --global --get core.hooksPath 2>/dev/null || true)"
  [ "$current" = "$HOOKS_DIR" ] \
    && [ -x "$HOOK" ] \
    && grep -qF "$HOOK_MARKER" "$HOOK" 2>/dev/null
}

run() {
  if [ "$DRY_RUN" = 1 ]; then
    echo "DRY-RUN: $*"
  else
    "$@"
  fi
}

install_hook() {
  if [ "$FORCE" != 1 ] && is_installed; then
    echo "Already installed: $HOOK (core.hooksPath -> $HOOKS_DIR); use --force to reinstall"
    return 0
  fi

  if [ "$DRY_RUN" = 1 ]; then
    echo "DRY-RUN: would write secrets-only pre-push hook to $HOOK"
    [ -f "$HOOK" ] && echo "DRY-RUN: would backup existing hook to $HOOK.backup-<timestamp>"
    echo "DRY-RUN: git config --global core.hooksPath $HOOKS_DIR"
    return 0
  fi

  mkdir -p "$HOOKS_DIR"

  if [ -f "$HOOK" ]; then
    local backup="$HOOK.backup-$(date +%Y%m%d%H%M%S)"
    cp -p "$HOOK" "$backup"
    echo "Backed up existing hook to $backup"
  fi

  local tmp
  tmp="$(mktemp "$HOOKS_DIR/.pre-push.XXXXXX")"
  cat > "$tmp" <<'HOOK'
#!/usr/bin/env bash
# pre-push secret guardrail (secrets-only).
# Blocks outgoing commits that introduce a secret leak or a sensitive file name.
# Installed globally through core.hooksPath by install-pre-push-secrets.sh.
# Guardrail, not a boundary: bypass with SKIP_SECURITY=1 or `git push --no-verify`.
set -uo pipefail

# Make sure a user-local gitleaks is found regardless of the push environment.
export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:/usr/local/sbin:/usr/local/bin:$PATH"

if [ "${SKIP_SECURITY:-}" = "1" ]; then
  echo "!! pre-push secret guardrail BYPASSED (SKIP_SECURITY=1)" >&2
  exit 0
fi

ZERO=0000000000000000000000000000000000000000
LOCAL_OIDS=()

while read -r local_ref local_oid remote_ref remote_oid; do
  [ -z "${local_oid:-}" ] && continue
  [ "$local_oid" = "$ZERO" ] && continue
  LOCAL_OIDS+=("$local_oid")
done

if [ "${#LOCAL_OIDS[@]}" -eq 0 ]; then exit 0; fi

REVS=("${LOCAL_OIDS[@]}" --not --remotes)
mapfile -t FILES < <(git log --name-only --pretty=format: "${REVS[@]}" | sed '/^[[:space:]]*$/d' | sort -u)

# 1. sensitive file names
DENY_RE='(^|/)\.env($|\.)|\.(pem|key|p12|pfx)$|(^|/)id_(rsa|ed25519|ecdsa|dsa)$|(^|/)credentials[^/]*$|(^|/)secrets/|\.tfstate$'
for f in "${FILES[@]}"; do
  [ "$(basename "$f")" = ".env.example" ] && continue
  if printf '%s' "$f" | grep -Eq "$DENY_RE"; then
    echo "BLOCKED: sensitive file in outgoing commits: $f" >&2
    exit 1
  fi
done

# 2. secret leaks. gitleaks --exit-code 2 separates leaks (2) from tool errors,
#    so an infrastructure failure warns and continues (fail-open) instead of blocking.
if command -v gitleaks >/dev/null 2>&1; then
  GL_OUT="$(gitleaks git -v --no-banner --redact --exit-code 2 --log-opts="${LOCAL_OIDS[*]} --not --remotes" . 2>&1)"; GL_RC=$?
  if [ "$GL_RC" -eq 2 ]; then
    printf '%s\n' "$GL_OUT" >&2
    echo "BLOCKED: gitleaks found secrets in outgoing commits." >&2
    exit 1
  elif [ "$GL_RC" -ne 0 ]; then
    printf '%s\n' "$GL_OUT" >&2
    echo "WARN: gitleaks failed (rc=$GL_RC) - secret scan skipped (fail-open)" >&2
  fi
else
  echo "WARN: gitleaks not found - secret scan skipped" >&2
fi

echo "pre-push secret guardrail: OK" >&2
exit 0
HOOK

  chmod +x "$tmp"
  mv -f "$tmp" "$HOOK"

  git config --global core.hooksPath "$HOOKS_DIR"
  echo "Installed secrets-only pre-push hook: $HOOK"
  echo "core.hooksPath -> $HOOKS_DIR"
}

uninstall_hook() {
  local latest
  latest="$(ls -1t "$HOOK".backup-* 2>/dev/null | head -1 || true)"

  if [ -n "$latest" ]; then
    run cp -p "$latest" "$HOOK"
    echo "Restored $HOOK from $latest"
    return 0
  fi

  run rm -f "$HOOK"
  run git config --global --unset core.hooksPath
  echo "Removed $HOOK and unset core.hooksPath"
}

case "$ACTION" in
  install) install_hook ;;
  uninstall) uninstall_hook ;;
esac
