#!/usr/bin/env bash
# Unit tests for the security-check wrapper, using a stub docker on PATH.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SECURITY_CHECK="${SECURITY_CHECK:-$HERE/../bin/security-check}"
FAILURES=0

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
STUB_BIN="$TMP/bin"
mkdir -p "$STUB_BIN"

cat > "$STUB_BIN/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_LOG"
exit "${STUB_DOCKER_RC:-0}"
STUB
chmod +x "$STUB_BIN/docker"

new_case() {
  local case_dir
  case_dir="$(mktemp -d "$TMP/case.XXXXXX")"
  export CASE_DIR="$case_dir"
  export DOCKER_LOG="$case_dir/docker.log"
  : > "$DOCKER_LOG"
  export CACHE_DIR="$case_dir/cache"
  export REPORTS_ROOT="$case_dir/reports-root"
  export PATH="$STUB_BIN:$PATH"
  unset IMAGE REPORTS_DIR STUB_DOCKER_RC
  cd "$case_dir" || exit 1
}

run() {
  bash "$SECURITY_CHECK" "$@"
}

expect_rc() {
  if [ "$1" -eq "$2" ]; then echo "ok: $3"; else
    echo "FAIL: $3 (expected $1, got $2)"; FAILURES=$((FAILURES + 1)); fi
}

expect_log_contains() {
  if grep -qF -- "$1" "$DOCKER_LOG"; then echo "ok: docker got $1"; else
    echo "FAIL: docker missing $1"; FAILURES=$((FAILURES + 1)); fi
}

expect_log_empty() {
  if [ ! -s "$DOCKER_LOG" ]; then echo "ok: docker not called"; else
    echo "FAIL: docker was called"; FAILURES=$((FAILURES + 1)); fi
}

# default: all categories, target = current directory, read-only mount
new_case
run; rc=$?
expect_rc 0 "$rc" "default run exits 0"
expect_log_contains "audit all"
expect_log_contains "-v $CASE_DIR:/workspace:ro"
expect_log_contains "-e REPORTS_DIR=/reports"
expect_log_contains "-v $CASE_DIR/reports-root/$(basename "$CASE_DIR"):/reports"

# explicit category
new_case
run secrets; rc=$?
expect_rc 0 "$rc" "explicit category exits 0"
expect_log_contains "audit secrets"

# target passed as a positional that is not a category
new_case
other="$TMP/other-project"
mkdir -p "$other"
run "$other"; rc=$?
expect_rc 0 "$rc" "target-only positional exits 0"
expect_log_contains "audit all"
expect_log_contains "-v $other:/workspace:ro"
expect_log_contains "-v $CASE_DIR/reports-root/other-project:/reports"

# category + target
new_case
run sast "$CASE_DIR"; rc=$?
expect_rc 0 "$rc" "category + target exits 0"
expect_log_contains "audit sast"

# --image override
new_case
run --image my.image:tag iac; rc=$?
expect_rc 0 "$rc" "--image override exits 0"
expect_log_contains "my.image:tag audit iac"

# IMAGE environment override
new_case
IMAGE=env.image:tag run sca; rc=$?
expect_rc 0 "$rc" "IMAGE env override exits 0"
expect_log_contains "env.image:tag audit sca"

# REPORTS_DIR override is respected and created
new_case
custom="$CASE_DIR/custom-reports"
REPORTS_DIR="$custom" run; rc=$?
expect_rc 0 "$rc" "REPORTS_DIR override exits 0"
expect_log_contains "-v $custom:/reports"
if [ -d "$custom" ]; then echo "ok: REPORTS_DIR created"; else
  echo "FAIL: REPORTS_DIR not created"; FAILURES=$((FAILURES + 1)); fi

# docker exit code is propagated
new_case
STUB_DOCKER_RC=1 run all; rc=$?
expect_rc 1 "$rc" "docker exit code propagated"

# non-directory target is rejected without calling docker
new_case
run "$TMP/nope-does-not-exist" 2>/dev/null; rc=$?
expect_rc 2 "$rc" "non-directory target rejected"
expect_log_empty

# unknown option is rejected
new_case
run --bogus 2>/dev/null; rc=$?
expect_rc 2 "$rc" "unknown option rejected"
expect_log_empty

# --help succeeds without calling docker
new_case
run --help >/dev/null 2>&1; rc=$?
expect_rc 0 "$rc" "--help exits 0"
expect_log_empty

echo
if [ "$FAILURES" -eq 0 ]; then echo "PASS"; exit 0; fi
echo "$FAILURES failure(s)"; exit 1
