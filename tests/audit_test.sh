#!/usr/bin/env bash
# Unit tests for the audit wrapper, using stub tool binaries on PATH.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
AUDIT="${AUDIT:-$HERE/../audit}"
FAILURES=0

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
STUB_BIN="$TMP/bin"
mkdir -p "$STUB_BIN"

for tool in gitleaks opengrep checkov trivy osv-scanner; do
  cat > "$STUB_BIN/$tool" <<'STUB'
#!/usr/bin/env bash
name="$(basename "$0")"
printf '%s %s\n' "$name" "$*" >> "$STUB_LOG"
var="STUB_RC_$(printf '%s' "$name" | tr 'a-z-' 'A-Z_')"
eval "rc=\${$var:-0}"
exit "$rc"
STUB
  chmod +x "$STUB_BIN/$tool"
done

new_case() {
  local case_dir
  case_dir="$(mktemp -d "$TMP/case.XXXXXX")"
  export STUB_LOG="$case_dir/log"
  : > "$STUB_LOG"
  export REPORTS_DIR="$case_dir/reports"
  export PATH="$STUB_BIN:$PATH"
  unset STUB_RC_GITLEAKS STUB_RC_OPENGREP STUB_RC_CHECKOV STUB_RC_TRIVY STUB_RC_OSV_SCANNER
  cd "$case_dir" || exit 1
}

expect_rc() {
  if [ "$1" -eq "$2" ]; then echo "ok: $3"; else
    echo "FAIL: $3 (expected $1, got $2)"; FAILURES=$((FAILURES + 1)); fi
}

expect_log_contains() {
  if grep -qF "$1" "$STUB_LOG"; then echo "ok: log contains $1"; else
    echo "FAIL: log missing $1"; FAILURES=$((FAILURES + 1)); fi
}

# secrets: blocking by default
new_case
STUB_RC_GITLEAKS=1 bash "$AUDIT" secrets; rc=$?
expect_rc 1 "$rc" "secrets blocks on findings"
expect_log_contains "report-path"
expect_log_contains "gitleaks.sarif"

# secrets: non-blocking when disabled
new_case
FAIL_ON_SECRETS=0 STUB_RC_GITLEAKS=1 bash "$AUDIT" secrets; rc=$?
expect_rc 0 "$rc" "secrets non-blocking when FAIL_ON_SECRETS=0"

# sast: non-blocking by default
new_case
STUB_RC_OPENGREP=1 bash "$AUDIT" sast; rc=$?
expect_rc 0 "$rc" "sast non-blocking by default"

# sast: blocking when enabled
new_case
FAIL_ON_SAST=1 STUB_RC_OPENGREP=1 bash "$AUDIT" sast; rc=$?
expect_rc 1 "$rc" "sast blocks when FAIL_ON_SAST=1"

# sca: blocking by default
new_case
STUB_RC_OSV_SCANNER=1 bash "$AUDIT" sca; rc=$?
expect_rc 1 "$rc" "sca blocks on findings"

# iac: non-blocking by default
new_case
STUB_RC_CHECKOV=1 bash "$AUDIT" iac; rc=$?
expect_rc 0 "$rc" "iac non-blocking by default"

# unknown subcommand is executed verbatim
new_case
out="$(bash "$AUDIT" echo hello)"; rc=$?
expect_rc 0 "$rc" "unknown subcommand execs verbatim"
if [ "$out" = "hello" ]; then echo "ok: passthrough output"; else
  echo "FAIL: passthrough output ($out)"; FAILURES=$((FAILURES + 1)); fi

# tool error (>1) propagates even when the category is non-blocking
new_case
FAIL_ON_SAST=0 STUB_RC_OPENGREP=128 bash "$AUDIT" sast; rc=$?
expect_rc 128 "$rc" "tool error (>1) propagates"

# all: only non-blocking findings -> exit 0
new_case
STUB_RC_OPENGREP=1 bash "$AUDIT" all; rc=$?
expect_rc 0 "$rc" "all with only sast findings exits 0"

# all: blocking findings -> exit 1
new_case
STUB_RC_GITLEAKS=1 bash "$AUDIT" all; rc=$?
expect_rc 1 "$rc" "all with secrets findings exits 1"

# all: tool error (>1) propagates
new_case
STUB_RC_GITLEAKS=128 bash "$AUDIT" all; rc=$?
expect_rc 128 "$rc" "all propagates tool errors (>1)"

echo
if [ "$FAILURES" -eq 0 ]; then echo "PASS"; exit 0; fi
echo "$FAILURES failure(s)"; exit 1
