#!/usr/bin/env bash
# Tests for the pre-push hook installer: isolated HOME, idempotence, uninstall.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
INSTALLER="${INSTALLER:-$HERE/../git-hooks/install-pre-push-secrets.sh}"
FAILURES=0

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

new_case() {
  local n
  n="$(( ${CASE_N:-0} + 1 ))"
  export CASE_N="$n"
  export HOME="$TMP/home.$n"
  export HOOKS_DIR="$HOME/.config/git-hooks"
  export HOOK="$HOOKS_DIR/pre-push"
  mkdir -p "$HOME"
}

expect_rc() {
  if [ "$1" -eq "$2" ]; then echo "ok: $3"; else
    echo "FAIL: $3 (expected $1, got $2)"; FAILURES=$((FAILURES + 1)); fi
}

expect_grep() {
  if printf '%s' "$2" | grep -qF -- "$1"; then echo "ok: output contains $1"; else
    echo "FAIL: output missing $1"; FAILURES=$((FAILURES + 1)); fi
}

hooks_path() { git config --global --get core.hooksPath 2>/dev/null || true; }

# install from scratch
new_case
out="$(bash "$INSTALLER" 2>&1)"; rc=$?
expect_rc 0 "$rc" "install exits 0"
if [ -x "$HOOK" ]; then echo "ok: hook installed and executable"; else
  echo "FAIL: hook missing"; FAILURES=$((FAILURES + 1)); fi
if [ "$(hooks_path)" = "$HOOKS_DIR" ]; then echo "ok: core.hooksPath set"; else
  echo "FAIL: core.hooksPath not set ($(hooks_path))"; FAILURES=$((FAILURES + 1)); fi

# idempotent: second run leaves it untouched, creates no backup
new_case
bash "$INSTALLER" >/dev/null 2>&1
out="$(bash "$INSTALLER" 2>&1)"; rc=$?
expect_rc 0 "$rc" "second install exits 0"
expect_grep "Already installed" "$out"
if ls "$HOOK".backup-* >/dev/null 2>&1; then
  echo "FAIL: idempotent run created a backup"; FAILURES=$((FAILURES + 1)); else
  echo "ok: idempotent run created no backup"; fi

# --force reinstalls and backs up the previous hook
new_case
bash "$INSTALLER" >/dev/null 2>&1
bash "$INSTALLER" --force >/dev/null 2>&1; rc=$?
expect_rc 0 "$rc" "--force exits 0"
if ls "$HOOK".backup-* >/dev/null 2>&1; then
  echo "ok: --force backed up the previous hook"; else
  echo "FAIL: --force did not back up"; FAILURES=$((FAILURES + 1)); fi

# --dry-run changes nothing
new_case
bash "$INSTALLER" --dry-run >/dev/null 2>&1; rc=$?
expect_rc 0 "$rc" "--dry-run exits 0"
if [ -e "$HOOK" ]; then echo "FAIL: dry-run created the hook"; FAILURES=$((FAILURES + 1)); else
  echo "ok: dry-run created no hook"; fi
if [ -n "$(hooks_path)" ]; then echo "FAIL: dry-run set core.hooksPath"; FAILURES=$((FAILURES + 1)); else
  echo "ok: dry-run left core.hooksPath unset"; fi

# --uninstall removes the hook and unsets core.hooksPath
new_case
bash "$INSTALLER" >/dev/null 2>&1
bash "$INSTALLER" --uninstall >/dev/null 2>&1; rc=$?
expect_rc 0 "$rc" "--uninstall exits 0"
if [ -e "$HOOK" ]; then echo "FAIL: uninstall left the hook"; FAILURES=$((FAILURES + 1)); else
  echo "ok: uninstall removed the hook"; fi
if [ -n "$(hooks_path)" ]; then echo "FAIL: uninstall left core.hooksPath"; FAILURES=$((FAILURES + 1)); else
  echo "ok: uninstall unset core.hooksPath"; fi

# unknown option is rejected
new_case
bash "$INSTALLER" --bogus >/dev/null 2>&1; rc=$?
expect_rc 2 "$rc" "unknown option rejected"

# --- hook behaviour: sensitive file names vs. .env templates ---
ZERO=0000000000000000000000000000000000000000

make_repo_with() { # $1 = path added in the outgoing commit; prints the repo path
  local path="$1" repo
  repo="$(mktemp -d "$TMP/repo.XXXXXX")"
  git -C "$repo" init -q -b main
  git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
  mkdir -p "$repo/$(dirname "$path")"
  printf 'X=1\n' > "$repo/$path"
  git -C "$repo" add -A
  git -C "$repo" -c user.email=t@t -c user.name=t commit -q -m "add $path"
  printf '%s' "$repo"
}

run_hook_on() { # $1 = repo; $2 = optional PATH override; runs the hook as git would on push
  local repo="$1" oid
  oid="$(git -C "$repo" rev-parse HEAD)"
  ( cd "$repo" && printf 'refs/heads/main %s refs/heads/main %s\n' "$oid" "$ZERO" \
      | PATH="${2:-$PATH}" bash "$HOOK" origin placeholder ) 2>&1
}

stub_gitleaks() { # $1 = exit code the stub must return
  mkdir -p "$HOME/.local/bin"
  printf '#!/usr/bin/env bash\nexit %s\n' "$1" > "$HOME/.local/bin/gitleaks"
  chmod +x "$HOME/.local/bin/gitleaks"
}

# a real .env in an outgoing commit is blocked
new_case
bash "$INSTALLER" >/dev/null 2>&1
out="$(run_hook_on "$(make_repo_with api/.env)")"; rc=$?
expect_rc 1 "$rc" "outgoing api/.env is blocked"
expect_grep "BLOCKED: sensitive file" "$out"

# .env templates and frontend dev defaults are safe to publish
new_case
bash "$INSTALLER" >/dev/null 2>&1
stub_gitleaks 0
for tpl in api/.env.example api/.env.prod.example api/.env.local.example webapp/.env.development; do
  out="$(run_hook_on "$(make_repo_with "$tpl")")"; rc=$?
  expect_rc 0 "$rc" "outgoing $tpl is allowed"
  if printf '%s' "$out" | grep -q "BLOCKED"; then
    echo "FAIL: $tpl was blocked"; FAILURES=$((FAILURES + 1)); else
    echo "ok: $tpl is not blocked"; fi
done

# a leak found by gitleaks is blocked
new_case
bash "$INSTALLER" >/dev/null 2>&1
stub_gitleaks 2
out="$(run_hook_on "$(make_repo_with src/config.txt)")"; rc=$?
expect_rc 1 "$rc" "gitleaks leak blocks"
expect_grep "BLOCKED: gitleaks found secrets" "$out"

# a failing gitleaks must not fail open
new_case
bash "$INSTALLER" >/dev/null 2>&1
stub_gitleaks 1
out="$(run_hook_on "$(make_repo_with src/config.txt)")"; rc=$?
expect_rc 1 "$rc" "gitleaks error blocks (no fail-open)"
expect_grep "BLOCKED: gitleaks failed" "$out"

# a missing gitleaks must not fail open
new_case
bash "$INSTALLER" >/dev/null 2>&1
out="$(run_hook_on "$(make_repo_with src/config.txt)" /usr/bin:/bin)"; rc=$?
expect_rc 1 "$rc" "missing gitleaks blocks (no fail-open)"
expect_grep "BLOCKED: gitleaks not found" "$out"

echo
if [ "$FAILURES" -eq 0 ]; then echo "PASS"; exit 0; fi
echo "$FAILURES failure(s)"; exit 1
