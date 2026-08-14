# shellcheck shell=bash
#
# common.sh — shared helpers for es-to-opensearch-migrate.
#
# Provides:
#   - Tamper-evident audit log (hash-chained JSONL)
#   - Secret redaction for anything bound for a log or the terminal
#   - HTTP wrappers that keep credentials off argv and out of the transcript
#   - Version comparison
#
# Sourced, never executed. Every function assumes `set -euo pipefail`.

# ---------------------------------------------------------------- constants

readonly REDACT_PLACEHOLDER='[REDACTED]'

# Exit codes. Documented in the man-page header of the main script; keep in sync.
readonly EX_OK=0
readonly EX_FATAL=1
readonly EX_USAGE=2
readonly EX_PREFLIGHT=3
readonly EX_FINDINGS=4

# ------------------------------------------------------------------ output
#
# Human-facing output goes to stderr so stdout stays clean for machine-readable
# payloads. Every message is redacted on the way out.

_stamp() { date -u +%Y-%m-%dT%H:%M:%SZ; }

log_info()  { printf '%s  %s\n'       "$(_stamp)" "$(redact <<<"$*")" >&2; }
log_warn()  { printf '%s  WARN  %s\n' "$(_stamp)" "$(redact <<<"$*")" >&2; }
log_error() { printf '%s  ERROR %s\n' "$(_stamp)" "$(redact <<<"$*")" >&2; }

# Progress lines for long-running phases. Same stream, distinct prefix so the
# operator can filter them out of a captured session.
log_step() { printf '%s  ..    %s\n' "$(_stamp)" "$(redact <<<"$*")" >&2; }

die() {
  local code=$1; shift
  log_error "$*"
  exit "$code"
}

# --------------------------------------------------------------- redaction
#
# Applied to every byte that reaches a log, the audit trail, or the terminal.
#
# This is deliberately aggressive. Under the boundary rule a false positive
# (over-redacting) costs nothing; a false negative writes a credential to a
# durable artifact. The patterns cover the shapes that actually show up in
# Elasticsearch and OpenSearch responses and in Logstash configs.

redact() {
  sed -E \
    -e "s/(\"?password\"?[[:space:]]*[:=>]+[[:space:]]*\"?)[^\",[:space:]}]+/\1${REDACT_PLACEHOLDER}/gI" \
    -e "s/(\"?(api_?key|secret|token|passwd|pwd)\"?[[:space:]]*[:=>]+[[:space:]]*\"?)[^\",[:space:]}]+/\1${REDACT_PLACEHOLDER}/gI" \
    -e "s/(apiKey=)[^&\"[:space:]]+/\1${REDACT_PLACEHOLDER}/gI" \
    -e "s/(Authorization:[[:space:]]*(Basic|Bearer|ApiKey)[[:space:]]+)[A-Za-z0-9._~+\/=-]+/\1${REDACT_PLACEHOLDER}/gI" \
    -e "s#(https?://)[^:/@[:space:]]+:[^@[:space:]]+@#\1${REDACT_PLACEHOLDER}@#g" \
    -e "s/(machine[[:space:]]+\S+[[:space:]]+login[[:space:]]+\S+[[:space:]]+password[[:space:]]+)\S+/\1${REDACT_PLACEHOLDER}/gI"
}

# Document bodies are boundary-sensitive in a way credentials are not: they are
# customer data, not secrets, and no pattern can reliably scrub them. So they
# are never logged at all. Callers that need to report a failing document log
# its _id and the error type via audit_event and nothing else.
#
# strip_hits collapses a search/bulk response down to counts and error types,
# discarding _source entirely. Use it on anything that might carry documents.
strip_hits() {
  jq -c '
    if type == "object" then
      del(.hits.hits[]?._source)
      | del(.items[]?.index?.error?.caused_by?.reason)
      | del(.failures[]?.cause?.reason)
    else . end
  ' 2>/dev/null || printf '{"error":"unparseable response withheld"}'
}

# ------------------------------------------------------------- audit trail
#
# One JSONL record per action, each carrying the SHA-256 of the previous
# record. Truncation or mid-file edits break the chain and are detectable by
# audit_verify. The chain head is written to the report at the end of a run.

# The chain head is derived from the log file itself, never from a shell
# variable. Audit events legitimately fire from inside command substitutions
# (any non-2xx response inside `x=$(http_get ...)` runs in a subshell), and a
# variable updated there is lost to the parent — which would silently write
# the next record with a stale prev and break the chain. Reading the head back
# from the file makes correctness independent of which shell wrote last.

audit_init() {
  local log_path=$1
  AUDIT_LOG=$log_path
  AUDIT_LOCK="${log_path}.lock"

  mkdir -p "$(dirname "$AUDIT_LOG")"
  chmod 0700 "$(dirname "$AUDIT_LOG")"
  : >>"$AUDIT_LOG"

  if command -v flock >/dev/null 2>&1; then
    AUDIT_USE_LOCK=1
  else
    AUDIT_USE_LOCK=0
    log_warn "flock unavailable; audit log appends are unserialised"
  fi

  export AUDIT_LOG AUDIT_LOCK AUDIT_USE_LOCK
}

_audit_genesis() { printf 'GENESIS' | sha256sum | cut -d' ' -f1; }

# audit_head — SHA-256 of the log's last record, or the genesis value when
# empty. This is the value the next record must carry as its prev.
audit_head() {
  if [[ -s ${AUDIT_LOG:-} ]]; then
    tail -n1 "$AUDIT_LOG" | tr -d '\n' | sha256sum | cut -d' ' -f1
  else
    _audit_genesis
  fi
}

# audit_event <kind> [key=value ...]
#
# Values are redacted and recorded as JSON strings. Keys must be bare
# identifiers. A value containing '=' keeps everything after the first one.
audit_event() {
  local kind=$1; shift

  local -a jq_args=(--arg kind "$kind"
                    --arg ts "$(_stamp)"
                    --arg actor "${USER:-unknown}"
                    --arg uid "$(id -u)"
                    --arg host "$(hostname -f 2>/dev/null || hostname)"
                    --arg profile "${PROFILE_NAME:-none}")
  local -a jq_fields=()

  local pair key value
  for pair in "$@"; do
    key=${pair%%=*}
    value=${pair#*=}
    value=$(redact <<<"$value")
    jq_args+=(--arg "f_${key}" "$value")
    jq_fields+=("\"${key}\": \$f_${key}")
  done

  local fields_json=''
  if (( ${#jq_fields[@]} > 0 )); then
    fields_json=$(IFS=,; echo "${jq_fields[*]}")
    fields_json=", ${fields_json}"
  fi

  # Read-head and append must be atomic against each other, or two writers
  # produce records claiming the same predecessor.
  if [[ ${AUDIT_USE_LOCK:-0} == 1 ]]; then
    exec 9>>"$AUDIT_LOCK"
    flock 9
  fi

  local prev record
  prev=$(audit_head)
  record=$(jq -cn "${jq_args[@]}" --arg prev "$prev" \
    "{ts: \$ts, kind: \$kind, actor: \$actor, uid: \$uid, host: \$host, profile: \$profile, prev: \$prev ${fields_json}}")
  printf '%s\n' "$record" >>"$AUDIT_LOG"

  if [[ ${AUDIT_USE_LOCK:-0} == 1 ]]; then
    flock -u 9
    exec 9>&-
  fi
}

# audit_verify <log> — recompute the chain and report the first break.
# Exit 0 if intact, 1 if broken or unreadable.
audit_verify() {
  local log_path=$1
  [[ -r $log_path ]] || { log_error "audit log unreadable: $log_path"; return 1; }

  local expected line actual lineno=0
  expected=$(_audit_genesis)

  while IFS= read -r line; do
    lineno=$((lineno + 1))
    actual=$(jq -r '.prev' <<<"$line" 2>/dev/null) || {
      log_error "audit chain: line $lineno is not valid JSON"; return 1; }
    if [[ $actual != "$expected" ]]; then
      log_error "audit chain broken at line $lineno (expected prev=$expected, found $actual)"
      return 1
    fi
    expected=$(printf '%s' "$line" | sha256sum | cut -d' ' -f1)
  done <"$log_path"

  log_info "audit chain intact over $lineno records; head=$expected"
  return 0
}

# ------------------------------------------------------------------- HTTP
#
# Credentials are supplied only via --netrc-file. Nothing authentication-
# related ever appears on argv, where `ps` would expose it to every local user.
#
# TLS verification is mandatory. --insecure-i-accept-the-risk sets
# HTTP_ALLOW_INSECURE=1, which is recorded in the audit log at the point of use
# so the exception is visible to anyone reading the trail.

_curl_common=()

http_init() {
  _curl_common=(--silent --show-error --location
                --max-time "${HTTP_TIMEOUT:-60}"
                --retry 2 --retry-delay 2
                -H 'Content-Type: application/json')

  # --fail-with-body (curl 7.76+) keeps the error body for diagnosis. Older
  # curl loses it, which turns a 400 with a useful reason into a bare exit 22.
  if curl --help all 2>/dev/null | grep -q -- '--fail-with-body'; then
    _curl_common+=(--fail-with-body)
  else
    _curl_common+=(--fail)
    log_warn "curl lacks --fail-with-body; HTTP error bodies will not be captured"
  fi
}

# http_get <side> <path>
#   side: "src" or "dst" — selects base URL, netrc file, and CA bundle from the
#         loaded profile.
# Response body goes to stdout. Callers that might receive documents pipe
# through strip_hits before logging.
http_get() {
  local side=$1 path=$2
  _http_request "$side" GET "$path"
}

# http_post <side> <path> [body]
http_post() {
  local side=$1 path=$2 body=${3:-}
  _http_request "$side" POST "$path" "$body"
}

_http_request() {
  local side=$1 method=$2 path=$3 body=${4:-}
  local base netrc ca

  case $side in
    src) base=$SRC_URL; netrc=$SRC_NETRC; ca=${SRC_CA:-} ;;
    dst) base=$DST_URL; netrc=$DST_NETRC; ca=${DST_CA:-} ;;
    *)   die "$EX_FATAL" "internal: unknown side '$side'" ;;
  esac

  local -a args=("${_curl_common[@]}" --netrc-file "$netrc" -X "$method")

  if [[ ${HTTP_ALLOW_INSECURE:-0} == 1 ]]; then
    args+=(--insecure)
  elif [[ -n $ca ]]; then
    args+=(--cacert "$ca")
  fi

  [[ -n $body ]] && args+=(--data-binary "$body")

  local url="${base%/}/${path#/}"
  local response status
  # Capture status separately so a non-2xx still yields a usable body.
  response=$(curl "${args[@]}" --write-out '\n%{http_code}' "$url" 2>&1) || true
  status=$(tail -n1 <<<"$response")
  body=$(sed '$d' <<<"$response")

  if [[ ! $status =~ ^2 ]]; then
    audit_event http_error side="$side" method="$method" path="$path" status="$status"
    printf '%s' "$body" | strip_hits
    return 1
  fi

  printf '%s' "$body"
}

# --------------------------------------------------------------- versions

# version_ge <a> <b> — true when a >= b under version ordering.
# Trailing qualifiers (-SNAPSHOT, -rc1) are dropped before comparison.
version_ge() {
  local a=${1%%-*} b=${2%%-*}
  [[ $a == "$b" ]] && return 0
  [[ $(printf '%s\n%s\n' "$a" "$b" | sort -V | head -n1) == "$b" ]]
}

version_major() { printf '%s' "${1%%.*}"; }

# ------------------------------------------------------------ preconditions

require_deps() {
  local -a missing=()
  local dep
  for dep in curl jq sha256sum sort sed; do
    command -v "$dep" >/dev/null 2>&1 || missing+=("$dep")
  done

  if (( ${#missing[@]} > 0 )); then
    die "$EX_PREFLIGHT" "missing required commands: ${missing[*]}"
  fi

  # Associative arrays and ${var^^} need bash 4.
  if (( BASH_VERSINFO[0] < 4 )); then
    die "$EX_PREFLIGHT" "bash 4+ required (found ${BASH_VERSION})"
  fi
}

# A netrc readable by anyone but the owner is a finding in its own right, and
# curl will refuse some of them anyway. Fail early with a clear reason.
require_netrc() {
  local path=$1 label=$2
  [[ -f $path ]] || die "$EX_PREFLIGHT" "$label netrc not found: $path"
  [[ -r $path ]] || die "$EX_PREFLIGHT" "$label netrc not readable: $path"

  local mode
  mode=$(stat -c '%a' "$path" 2>/dev/null || stat -f '%Lp' "$path")
  if [[ $mode != 600 && $mode != 400 ]]; then
    die "$EX_PREFLIGHT" "$label netrc has mode $mode; must be 600 or 400: $path"
  fi
}
