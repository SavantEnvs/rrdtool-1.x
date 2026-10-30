#!/usr/bin/env bash
#
# mayhem/test.sh — RUN this repo's OWN functional test suite (already built by mayhem/build.sh).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# RUN the autotools test suite (tests/Makefile.am `TESTS`) that build.sh built in build/test.
# Each script/binary compares rrdtool's actual output with known-good dumps/values, so a neutered
# rrdtool fails them. Do not compile here: `check` finds everything already built.
TESTDIR="$SRC/build/test/tests"
[ -f "$TESTDIR/Makefile" ] || { echo "test.sh: $TESTDIR/Makefile missing — build.sh did not run" >&2; exit 2; }
[ -d "$SRC/build/test/src/.libs" ] || { echo "test.sh: test build missing — build.sh did not run" >&2; exit 2; }

LOG="$(mktemp)"
make -C "$TESTDIR" check -j"$MAYHEM_JOBS" >"$LOG" 2>&1 || true
cat "$TESTDIR/test-suite.log" 2>/dev/null | tail -n 60

sum() { sed -n "s/^# $1: *\([0-9][0-9]*\)\s*$/\1/p" "$LOG" | tail -n1; }
TOTAL="$(sum TOTAL)"; PASS="$(sum PASS)"; SKIP="$(sum SKIP)"; XFAIL="$(sum XFAIL)"
FAIL="$(sum FAIL)"; XPASS="$(sum XPASS)"; ERR="$(sum ERROR)"
if [ -z "$TOTAL" ] || [ "$TOTAL" -eq 0 ]; then
  echo "test.sh: no test summary found in make check output" >&2; tail -n 30 "$LOG" >&2
  emit_ctrf "automake-tests" 0 1 0; exit $?
fi
emit_ctrf "automake-tests" "$(( ${PASS:-0} + ${XFAIL:-0} ))" "$(( ${FAIL:-0} + ${XPASS:-0} + ${ERR:-0} ))" "${SKIP:-0}"
