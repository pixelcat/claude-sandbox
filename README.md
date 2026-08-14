# es-to-opensearch-migrate

Audited Elasticsearch to OpenSearch migration tooling.

Runs on the destination system, one source/target pair per invocation. Every
action lands in a hash-chained JSONL audit log. No document content and no
credential is ever written to a log or the terminal.

## Status

| Subcommand | State |
|---|---|
| `feature-scan` | Implemented |
| `verify-chain` | Implemented |
| `self-test` | Implemented |
| `config-audit` / `config-apply` | Not yet written |
| `backfill` / `verify-data` / `report` | Not yet written |

`feature-scan` is the gate the later phases depend on, so it lands first.

## Quick start

```bash
cp profiles/ops.conf.example profiles/ops.conf   # then edit
chmod 600 ~/.netrc.ops ~/.netrc.ops-new

bin/es-to-opensearch-migrate --profile ops \
  --query-corpus '/var/log/nginx/es-access.log*' \
  feature-scan
```

Exit 4 means blocking findings were reported. See `docs/RUNBOOK.md`.

## What feature-scan does

Inventories capabilities in use on the source and classifies each against the
target's **live** OpenSearch version:

| Disposition | Meaning |
|---|---|
| `PORTABLE` | Works as-is or with a trivial config change |
| `TRANSLATE` | Equivalent exists; requires deliberate rewrite |
| `REBUILD` | No mechanical path; recreated by hand |
| `NO-EQUIVALENT` | Nothing on the target does this. Gates the migration |

`NO-EQUIVALENT` and `UNKNOWN` are blocking. `REBUILD` is not — it is expensive
but it has a path.

Rules are parameterised by target version because the two migrations land on
different baselines (3.3.2 and 2.19.5), and a feature that is `TRANSLATE` on
one can be `NO-EQUIVALENT` on the other.

### Signal sources

1. `GET /_xpack/usage` — which licensed features are enabled and how much they
   are used. The highest-value single call; works on ES 7 and 8.
2. Direct endpoints — enrich policies, ILM/SLM, transforms, data streams,
   ingest processors, roles with DLS/FLS, API keys.
3. Index mappings — field types actually in use, including anything dynamic
   mapping added beyond the templates.
4. `--query-corpus` — query-time features leave no trace in cluster state.
   Path-only matching catches every blocking feature without reading a single
   document value.
5. `--saved-objects` — Kibana export, classified into portable and rebuild.

Without `--query-corpus`, query-time features are not examined and the scan
says so.

## Tests

```bash
bin/es-to-opensearch-migrate self-test   # units, no cluster access
tests/e2e-feature-scan.sh                # full path against stub clusters
```

The end-to-end test exercises preflight, every collector, report generation,
the audit chain including tamper detection, and the exit-code contract. It
also asserts that the same source yields different dispositions against
different target versions.

## Layout

```
bin/es-to-opensearch-migrate   Main script; man-page header documents usage
lib/common.sh                  Audit log, redaction, HTTP, versions
lib/compat.sh                  Version-parameterised compatibility rules
profiles/                      One per source/target pair
tests/                         Stub clusters and end-to-end coverage
docs/RUNBOOK.md                Phase order, gates, footguns
```

## Design constraints

- **One pair per invocation.** Handling several would concentrate credentials
  across security domains and blur the audit trail.
- **Credentials only via netrc**, mode 600 or 400, enforced at preflight.
  Nothing authentication-related reaches argv, where `ps` would expose it.
- **TLS verification is mandatory.** Disabling it requires an explicit flag
  and is recorded in the audit log at the point of use.
- **Document bodies are never logged.** Failures are recorded as counts, index
  names, and error types. Responses that might carry documents are stripped of
  `_source` before anything is written.
- **No outbound calls** other than to the two clusters.
