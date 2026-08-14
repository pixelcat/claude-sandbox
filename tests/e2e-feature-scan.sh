#!/usr/bin/env bash
#
# e2e-feature-scan.sh — exercise feature-scan end to end against stub clusters.
#
# Verifies the whole path, not just the units: preflight, every collector,
# report generation, the audit hash chain, and the exit code contract.

set -euo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d)
SRC_PORT=19200
DST_PORT=19201
failures=0

cleanup() {
  [[ -n ${SRC_PID:-} ]] && kill "$SRC_PID" 2>/dev/null || true
  [[ -n ${DST_PID:-} ]] && kill "$DST_PID" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

check() {
  local name=$1 expected=$2 actual=$3
  if [[ $expected == "$actual" ]]; then
    printf '  ok    %s\n' "$name"
  else
    printf '  FAIL  %s (expected %s, got %s)\n' "$name" "$expected" "$actual"
    failures=$((failures + 1))
  fi
}

check_contains() {
  local name=$1 needle=$2 haystack=$3
  if [[ $haystack == *"$needle"* ]]; then
    printf '  ok    %s\n' "$name"
  else
    printf '  FAIL  %s (missing: %s)\n' "$name" "$needle"
    failures=$((failures + 1))
  fi
}

printf 'e2e: feature-scan\n'

# A stale stub left bound to either port would silently serve a previous
# fixture set and make the results meaningless, so refuse to start.
for port in "$SRC_PORT" "$DST_PORT"; do
  if curl -s --max-time 1 "http://127.0.0.1:$port/" >/dev/null 2>&1; then
    printf '  FAIL  port %s is already in use; stop the stale listener first\n' "$port"
    exit 1
  fi
done

python3 "$REPO_ROOT/tests/fake-cluster.py" --port "$SRC_PORT" --flavor es8 & SRC_PID=$!
python3 "$REPO_ROOT/tests/fake-cluster.py" --port "$DST_PORT" --flavor opensearch --version 3.3.2 & DST_PID=$!

# Wait for both stubs rather than sleeping a fixed interval.
for _ in $(seq 50); do
  if curl -sf "http://127.0.0.1:$SRC_PORT/" >/dev/null 2>&1 \
  && curl -sf "http://127.0.0.1:$DST_PORT/" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

printf 'machine 127.0.0.1 login test password test\n' >"$WORK/netrc"
chmod 600 "$WORK/netrc"

mkdir -p "$WORK/profiles"
cat >"$WORK/profiles/e2e.conf" <<EOF
SRC_URL='http://127.0.0.1:$SRC_PORT'
SRC_NETRC='$WORK/netrc'
DST_URL='http://127.0.0.1:$DST_PORT'
DST_NETRC='$WORK/netrc'
DST_VERSION_EXPECTED='3.3.2'
EOF

# A corpus containing paths that only appear at query time.
cat >"$WORK/proxy-access.log" <<'EOF'
10.0.0.1 - - "POST /_sql?format=json HTTP/1.1" 200
10.0.0.2 - - "POST /_query HTTP/1.1" 200
10.0.0.3 - - "POST /_eql/search HTTP/1.1" 200
10.0.0.4 - - "POST /logs-*/_search HTTP/1.1" 200 {"runtime_mappings":{}}
EOF

set +e
out=$("$REPO_ROOT/bin/es-to-opensearch-migrate" \
        --profile e2e \
        --profile-dir "$WORK/profiles" \
        --out-dir "$WORK/run" \
        --query-corpus "$WORK/proxy-access.log" \
        feature-scan 2>"$WORK/stderr.log")
rc=$?
set -e

check 'exit code is 4 (blocking findings present)' 4 "$rc"

report="$WORK/run/features.json"
if [[ ! -f $report ]]; then
  printf '  FAIL  features.json not written; scan stderr follows:\n'
  sed 's/^/      /' "$WORK/stderr.log"
  exit 1
fi

# Blocking findings the fixture is designed to produce.
for id in esql eql enrich fleet; do
  n=$(jq --arg id "$id" '[.findings[] | select(.id == $id)] | length' "$report")
  check "finding present: $id" 1 "$n"
done

# esql and eql must be blocking on any target.
blocking=$(jq '[.findings[] | select(.blocking)] | length' "$report")
[[ $blocking -ge 2 ]] \
  && printf '  ok    at least 2 blocking findings (%s)\n' "$blocking" \
  || { printf '  FAIL  expected >=2 blocking, got %s\n' "$blocking"; failures=$((failures+1)); }

# Version-sensitive rule: flattened is TRANSLATE on 3.3.2 (needs 2.7+).
disp=$(jq -r '.findings[] | select(.id == "flattened") | .disposition' "$report")
check 'flattened is TRANSLATE on 3.3.2' TRANSLATE "$disp"

# unsigned_long needs 2.8+; on 3.3.2 it is PORTABLE.
disp=$(jq -r '.findings[] | select(.id == "unsigned_long") | .disposition' "$report")
check 'unsigned_long is PORTABLE on 3.3.2' PORTABLE "$disp"

# Query-corpus detection must fire for a feature absent from cluster state.
n=$(jq '[.findings[] | select(.id == "esql")] | length' "$report")
check 'esql detected' 1 "$n"

# Human report reaches stdout.
check_contains 'human report names the profile' 'FEATURE SCAN — profile e2e' "$out"
check_contains 'human report has NO-EQUIVALENT section' 'NO-EQUIVALENT' "$out"

# The audit chain must validate.
set +e
"$REPO_ROOT/bin/es-to-opensearch-migrate" \
  --profile e2e --profile-dir "$WORK/profiles" --out-dir "$WORK/run" \
  verify-chain >"$WORK/chain.log" 2>&1
chain_rc=$?
set -e
check 'audit chain verifies' 0 "$chain_rc"

# Tampering must be detected. Rewrite a record's evidence field in place.
cp "$WORK/run/audit.jsonl" "$WORK/tampered.jsonl"
sed -i '2s/"kind":"[^"]*"/"kind":"tampered"/' "$WORK/tampered.jsonl"
set +e
( source "$REPO_ROOT/lib/common.sh"; audit_verify "$WORK/tampered.jsonl" ) >/dev/null 2>&1
tamper_rc=$?
set -e
check 'tampered audit chain is rejected' 1 "$tamper_rc"

# No credential material may appear in any produced artefact.
if grep -rqi 'password test\|login test' "$WORK/run" 2>/dev/null; then
  printf '  FAIL  netrc credentials leaked into run artefacts\n'
  failures=$((failures + 1))
else
  printf '  ok    no credentials in run artefacts\n'
fi

# --------------------------------------------------------------------------
# Second target, older baseline. The whole point of per-profile version
# parameterisation is that the same source yields different dispositions
# against ops-new (3.3.2) and secops-new (2.19.5), so prove it end to end
# rather than only in the unit test.

printf '\ne2e: feature-scan against a 2.6 target (pre-derived-fields)\n'

OLD_PORT=19202
if curl -s --max-time 1 "http://127.0.0.1:$OLD_PORT/" >/dev/null 2>&1; then
  printf '  FAIL  port %s already in use\n' "$OLD_PORT"
  exit 1
fi
python3 "$REPO_ROOT/tests/fake-cluster.py" --port "$OLD_PORT" --flavor opensearch --version 2.6.0 & OLD_PID=$!
for _ in $(seq 50); do
  curl -sf "http://127.0.0.1:$OLD_PORT/" >/dev/null 2>&1 && break
  sleep 0.1
done

sed "s|127.0.0.1:$DST_PORT|127.0.0.1:$OLD_PORT|; s|DST_VERSION_EXPECTED='3.3.2'|DST_VERSION_EXPECTED='2.6.0'|" \
  "$WORK/profiles/e2e.conf" >"$WORK/profiles/e2e-old.conf"

set +e
"$REPO_ROOT/bin/es-to-opensearch-migrate" \
  --profile e2e-old --profile-dir "$WORK/profiles" --out-dir "$WORK/run-old" \
  --query-corpus "$WORK/proxy-access.log" \
  feature-scan >/dev/null 2>&1
set -e
kill "$OLD_PID" 2>/dev/null || true

old_report="$WORK/run-old/features.json"

# runtime_fields needs 2.15+; on 2.6 it escalates to NO-EQUIVALENT.
disp=$(jq -r '.findings[] | select(.id == "runtime_fields") | .disposition' "$old_report")
check 'runtime_fields escalates to NO-EQUIVALENT on 2.6' NO-EQUIVALENT "$disp"

# unsigned_long needs 2.8+; on 2.6 it also escalates.
disp=$(jq -r '.findings[] | select(.id == "unsigned_long") | .disposition' "$old_report")
check 'unsigned_long escalates to NO-EQUIVALENT on 2.6' NO-EQUIVALENT "$disp"

# Same source, more blocking findings on the older target. That difference is
# the feature being tested.
new_blocking=$(jq '[.findings[] | select(.blocking)] | length' "$report")
old_blocking=$(jq '[.findings[] | select(.blocking)] | length' "$old_report")
if (( old_blocking > new_blocking )); then
  printf '  ok    older target yields more blocking findings (%s > %s)\n' "$old_blocking" "$new_blocking"
else
  printf '  FAIL  expected more blocking on 2.6 (got %s vs %s)\n' "$old_blocking" "$new_blocking"
  failures=$((failures + 1))
fi

printf '\n%d failure(s)\n' "$failures"
exit $(( failures > 0 ? 1 : 0 ))
