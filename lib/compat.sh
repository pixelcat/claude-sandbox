# shellcheck shell=bash
#
# compat.sh — Elasticsearch feature to OpenSearch disposition rules.
#
# Rules are parameterised by TARGET OpenSearch version because the two
# migrations in scope land on different baselines:
#
#     ops    → OpenSearch 3.3.2
#     secops → OpenSearch 2.19.5   (Wazuh 4.14.7 indexer)
#
# A feature that is TRANSLATE on 3.3.2 can be NO-EQUIVALENT on an older
# target, so a single global table would give a wrong answer for one of them.
#
# DISPOSITIONS
#     PORTABLE       Works as-is or with trivial config change.
#     TRANSLATE      Equivalent exists; requires deliberate rewrite.
#     REBUILD        No mechanical path; the artefact is recreated by hand.
#     NO-EQUIVALENT  Nothing on the target does this. Gates the migration.
#
# Rules marked VERIFY in the note carry meaningful uncertainty about the
# OpenSearch side. Confirm against the live target before relying on them;
# feature-scan surfaces them separately for that reason.

# Table columns, pipe-separated:
#   id | category | disposition | min_target_version | note
#
# min_target_version of "-" means the disposition is unconditional. Otherwise,
# a target below that version escalates the disposition to NO-EQUIVALENT.

_compat_table() {
  cat <<'TABLE'
esql|query|NO-EQUIVALENT|-|No ES|QL on OpenSearch. PPL is the nearest analogue; every query is rewritten.
eql|query|NO-EQUIVALENT|-|No EQL. Sequence-based detection logic must be re-expressed as bool/aggregation queries.
sql|query|TRANSLATE|-|OpenSearch SQL plugin exists; dialect differs. Expect per-query fixes.
elser|query|NO-EQUIVALENT|-|ELSER / text_expansion / semantic_text have no OpenSearch counterpart. Neural search is a different model and API.
retriever|query|NO-EQUIVALENT|-|ES 8 retriever/RRF syntax absent. Hybrid search on OpenSearch uses a different construct.
async_search|query|TRANSLATE|2.4|OpenSearch asynchronous search plugin; different endpoint.
point_in_time|query|TRANSLATE|2.4|OpenSearch PIT exists; API shape differs from ES.
terms_enum|query|REBUILD|-|VERIFY: no confirmed OpenSearch equivalent of the terms_enum API.
runtime_fields|mapping|TRANSLATE|2.15|Derived fields cover much of the ground from 2.15. Narrower for aggregation-heavy use.
flattened|mapping|TRANSLATE|2.7|flat_object. Query support is narrower than ES flattened.
dense_vector|mapping|TRANSLATE|-|knn_vector. Different parameters; index must enable k-NN.
sparse_vector|mapping|NO-EQUIVALENT|-|No counterpart. Tied to ELSER.
unsigned_long|mapping|PORTABLE|2.8|Present from 2.8.
constant_keyword|mapping|TRANSLATE|-|No equivalent. Downgrade to keyword; records a fidelity loss.
wildcard_type|mapping|TRANSLATE|-|No equivalent wildcard field type. Downgrade to keyword.
version_type|mapping|TRANSLATE|-|No equivalent version field type. Downgrade to keyword; semantic version sort is lost.
match_only_text|mapping|TRANSLATE|-|No equivalent. Downgrade to text; storage cost increases.
histogram_type|mapping|NO-EQUIVALENT|-|No histogram field type. Pre-aggregated histogram data cannot be indexed as such.
aggregate_metric_double|mapping|NO-EQUIVALENT|-|No counterpart. Rollup-style pre-aggregated metrics must be recomputed.
ilm|lifecycle|TRANSLATE|-|ISM. No automatic translation; policies are hand-mapped. Retention drift risk if rushed.
slm|lifecycle|TRANSLATE|-|Snapshot Management plugin. Different API and scheduling model.
data_streams|lifecycle|TRANSLATE|2.6|OpenSearch data streams exist; backing-index naming and policy attachment differ.
searchable_snapshots|lifecycle|TRANSLATE|2.4|Present from 2.4. Maturity differs from ES frozen tier.
watcher|alerting|TRANSLATE|-|OpenSearch Alerting. Different model; each watch is rewritten as a monitor plus notification channel.
transforms|analytics|TRANSLATE|-|Index Transforms plugin. Continuous-mode semantics differ.
rollup|analytics|TRANSLATE|-|Index Rollups plugin. Different API and job definition.
ml_anomaly|analytics|REBUILD|-|Anomaly Detection plugin uses different algorithms. Models and historical anomaly results are not portable.
ml_dfa|analytics|REBUILD|-|Data frame analytics has no direct counterpart. ML Commons is a different framework.
trained_models|analytics|REBUILD|-|Elastic trained models do not load into ML Commons.
graph|analytics|NO-EQUIVALENT|-|No Graph API equivalent.
enrich|ingest|NO-EQUIVALENT|-|VERIFY: no enrich processor or enrich policies on OpenSearch. Workaround is precomputing the join upstream, e.g. in Logstash.
inference_processor|ingest|TRANSLATE|-|ML Commons offers an inference processor with a different configuration shape.
api_keys|security|TRANSLATE|-|No x-pack-style API keys. Clients move to internal users or JWT. Client-side change.
service_tokens|security|TRANSLATE|-|No service account tokens. Internal users are the replacement.
dls_fls|security|TRANSLATE|-|Security plugin supports DLS, FLS and field masking; policy syntax differs.
ccr|replication|TRANSLATE|-|Cross-cluster replication plugin exists; requires matching versions across clusters.
fleet|collection|NO-EQUIVALENT|-|No Fleet or Elastic Agent. Collection architecture changes wholesale.
lens|dashboards|REBUILD|-|No Lens in OpenSearch Dashboards. Default visualisation type in Kibana 8, so expect volume.
canvas|dashboards|REBUILD|-|No Canvas equivalent.
kibana_maps|dashboards|REBUILD|-|OpenSearch Dashboards Maps is a different plugin with its own tile configuration.
kibana_alerting|dashboards|REBUILD|-|Kibana rules and connectors become Alerting monitors plus Notifications channels.
spaces|dashboards|TRANSLATE|-|Kibana spaces map onto OpenSearch tenants. Different isolation model.
saved_objects_8x|dashboards|REBUILD|-|Kibana 8 saved objects do not import into OpenSearch Dashboards. Lineage diverged at 7.10.2.
TABLE
}

# compat_lookup <id> <target_version>
# Prints "DISPOSITION|note" on stdout. Unknown ids yield UNKNOWN.
compat_lookup() {
  local id=$1 target=$2
  local row rid rcat rdisp rmin rnote

  while IFS='|' read -r rid rcat rdisp rmin rnote; do
    [[ $rid == "$id" ]] || continue

    if [[ $rmin != '-' ]] && ! version_ge "$target" "$rmin"; then
      printf 'NO-EQUIVALENT|%s (requires OpenSearch %s+, target is %s)' "$rnote" "$rmin" "$target"
      return 0
    fi

    printf '%s|%s' "$rdisp" "$rnote"
    return 0
  done < <(_compat_table)

  printf 'UNKNOWN|No rule for "%s". Treat as unverified and check against the target manually.' "$id"
}

compat_category() {
  local id=$1 rid rcat rest
  while IFS='|' read -r rid rcat rest; do
    [[ $rid == "$id" ]] && { printf '%s' "$rcat"; return 0; }
  done < <(_compat_table)
  printf 'unknown'
}

# compat_is_blocking <disposition> — true for dispositions that gate the
# migration. REBUILD is deliberately not blocking: it is expensive but it has
# a path. NO-EQUIVALENT and UNKNOWN have no path until a human decides one.
compat_is_blocking() {
  case $1 in
    NO-EQUIVALENT|UNKNOWN) return 0 ;;
    *) return 1 ;;
  esac
}

# compat_rule_count — used by the self-test to catch a truncated table.
compat_rule_count() { _compat_table | grep -c '^[a-z]'; }
