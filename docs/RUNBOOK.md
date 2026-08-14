# Elasticsearch to OpenSearch migration runbook

Two independent migrations sharing one script. Run them separately, with
separate credentials and separate audit logs.

| | `ops` | `secops` |
|---|---|---|
| Source | Elasticsearch 8, Kibana 8 | Elasticsearch 7, Wazuh 4.5.4, Kibana 7.x |
| Target | OpenSearch 3.3.2, Dashboards 3.3.2 | OpenSearch 2.19.5, Wazuh 4.14.7 |
| Backfill engine | Logstash | Remote reindex |
| Cutover | Logstash output change | Logstash output change |
| Dashboards | Rebuild | Wazuh plugin ships stock; migrate custom only |
| Dominant risk | Feature gaps, dashboard rebuild | Wazuh template drift across nine minors |

## Order of operations

| Phase | What | Gate to proceed |
|---|---|---|
| -1 | `feature-scan` | No unresolved NO-EQUIVALENT findings, or each has a written accepted-risk decision |
| 0 | Config inventory and parity diff | Diff reviewed and signed off |
| 1 | Apply config to target: templates, ISM, pipelines, auth, SAML, service accounts | Parity re-check clean |
| 2 | Cutover: repoint Logstash, record cutover timestamp T | Clients confirmed on the new cluster |
| 3 | Set source indices read-only, confirm zero writes | Write-block confirmed |
| 4 | Backfill everything with timestamp `< T` | — |
| 5 | Verify and report | PASS |
| 6 | Decommission gate | Explicit human approval |

There is no dual-output bake. The cheap substitute is a staged cutover: move
one low-volume pipeline first, verify the resulting mappings, then move the
rest.

## Phase -1: feature-scan

```bash
bin/es-to-opensearch-migrate --profile ops \
  --query-corpus '/var/log/nginx/es-access.log*' \
  --saved-objects ./kibana-saved-objects.ndjson \
  feature-scan
```

Exit 4 means blocking findings. Exit 0 means none were detected — which is
only as strong as the inputs. Without `--query-corpus`, features used solely
at query time (ES|QL, EQL, SQL, `runtime_mappings`) are not examined at all.

### Building a query corpus

Query-time features leave no trace in cluster state. Four sources, cheapest
first:

1. **Proxy or load-balancer access logs.** Path-only matching identifies every
   blocking feature without capturing a single document value. This is the
   boundary-safe option and the one to try first.
2. **Kibana saved objects.** Free once exported, and doubles as the dashboards
   work list.
3. **Search slow log.** Dynamic setting, no restart. Scope it to
   representative indices.
4. **Audit log with `emit_request_body`.** Static setting, requires a restart
   and a Platinum licence.

Check what is already enabled:

```bash
curl -s --netrc-file ~/.netrc.ops "$OPS/_license" | jq '.license.type'

curl -s --netrc-file ~/.netrc.ops \
  "$OPS/_all/_settings/index.search.slowlog*?flat_settings=true" \
  | jq -r 'to_entries[] | select(.value.settings | length > 0) | .key'

# Audit settings are static; they live in elasticsearch.yml, not cluster state.
curl -s --netrc-file ~/.netrc.ops "$OPS/_nodes/settings?flat_settings=true" \
  | jq '.nodes[].settings | with_entries(select(.key | startswith("xpack.security.audit")))'
```

Enabling body capture creates a new in-boundary data-at-rest artefact. It
needs a defined collection window, a disposal date, and in-boundary-only
analysis. A `0ms` slow-log threshold on a busy cluster generates enough volume
to cross the flood-stage watermark, which flips indices to read-only — confirm
rotation and disk headroom before enabling.

## secops: pre-backfill gate

Nine minor versions of Wazuh template drift sit between 4.5.4 and 4.14.7. Most
of it is additive and harmless. The class that breaks the backfill is a field
present in both templates **with a different type** — those documents are
rejected or silently coerced.

```bash
curl -s --netrc-file ~/.netrc.secops    "$SECOPS/wazuh-alerts-4.x-*/_mapping"    > map-src.json
curl -s --netrc-file ~/.netrc.secopsnew "$SECOPSNEW/wazuh-alerts-4.x-*/_mapping" > map-dst.json

flatten() {
  jq -r '[paths(scalars) as $p | select($p[-1]=="type")
          | {k: ($p[:-1] | map(select(. != "properties" and . != "mappings" and . != "_doc")) | join(".")),
             v: getpath($p)}]
         | .[] | "\(.k)\t\(.v)"' "$1" | sort -u
}

flatten map-src.json > fields-src.tsv
flatten map-dst.json > fields-dst.tsv

# The blocker class: same path, different type.
join -t$'\t' fields-src.tsv fields-dst.tsv | awk -F'\t' '$2 != $3'
```

| Diff result | Meaning | Action |
|---|---|---|
| Target only | Additive | Safe. Panels using it show empty for pre-cutover data |
| Source only | Dropped in 4.14 | Check the target's `dynamic` setting. `strict` causes ingestion errors |
| Both, different type | **Blocker** | Resolve before backfill: convert in Logstash, or drop with the loss recorded |

## Known non-migratable

- **Wazuh vulnerability history.** Wazuh 4.8 moved vulnerability state into
  `wazuh-states-vulnerabilities-*`. On 4.5.4 it lived in agent-local SQLite,
  so there is nothing on the source to copy. It repopulates as agents rescan.
- **Kibana 8 saved objects.** Dashboards lineage diverged from Kibana at
  7.10.2. Export them to size the rebuild; they will not import.
- **ML anomaly results.** Detectors are rebuilt and retrained; historical
  anomaly output is lost.

## Footguns

**Logstash `template_overwrite`.** The `secops` Logstash config points at a
4.5.4-era `wazuh-template.json` with `template_overwrite => true`. Against the
new cluster that replaces the 4.14.7 template the Wazuh install ships,
discarding nine minor versions of field definitions at the first connection.
Set `manage_template => false`.

**The `elasticsearch` output plugin rejects OpenSearch.** A product-origin
check added in 7.14 fails outright. `logstash-output-opensearch` must be
installed before cutover.

**Logstash is load-bearing, not vestigial.** The `secops` instance performs
`apiKey` redaction, `data.trace` type coercion, and fan-out to GCS cold
storage. Going native Filebeat silently drops all three. Verify redaction
still fires after cutover — a filter that stops matching fails open.

**Remote reindex runs on the destination's data nodes.** Reachability from the
script's host proves nothing. `reindex.remote.whitelist` must include the
source in `/etc/wazuh-indexer/opensearch.yml` on every node; it is a static
setting requiring a rolling restart.

**ISM ages from index creation, not data time.** Backfilled legacy indices get
a fresh retention clock and outlive their intended expiry. After backfill
creates an index:

```bash
curl -X POST "$DST/_plugins/_ism/remove/<index>"
curl -X POST "$DST/_plugins/_ism/add/<index>"   # with the legacy policy
```

**The boundary day is the only collision.** Everything before cutover
timestamp T lives only on the source, everything after only on the target. The
index spanning T holds a partial day on each side. Backfill it last, preserve
source `_id`, use `op_type: create`, and bound the query at `< T`.

## Audit

Every run writes `audit.jsonl` — one hash-chained JSONL record per action.
The chain head is recorded in `features.json`.

```bash
bin/es-to-opensearch-migrate --profile ops --out-dir ./run-ops-... verify-chain
```

No document content and no credential is written to a log or the terminal.
Credentials are supplied only through netrc files, which must be mode 600 or
400; the script refuses to start otherwise.
