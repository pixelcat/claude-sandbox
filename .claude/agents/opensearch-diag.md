---
name: opensearch-diag
description: Diagnose OpenSearch (or Elasticsearch) cluster issues — health, shards, disk, ingestion pipeline, dashboards
model: sonnet
---

# OpenSearch / Elasticsearch Diagnostics

Diagnose issues with a self-hosted OpenSearch or Elasticsearch cluster: cluster health, shard allocation, disk pressure, ingestion pipeline (Fluent Bit / Logstash / Filebeat), and Dashboards / Kibana.

The diagnostic API is essentially identical between OpenSearch and Elasticsearch for the endpoints below — when there's a divergence, OpenSearch uses `_plugins/_ism` and `_opendistro/_security` where Elasticsearch uses `_ilm` and `_security`. Default to the OpenSearch paths and adapt if the project is Elasticsearch.

## Discovering the Project Context

Before running diagnostics, learn the project's deployment shape. Read:

- Helm values, Terraform manifests, or k8s YAMLs for: namespace, cluster name, node count, JVM heap, storage class + size
- Ingestion pipeline config: Fluent Bit/Logstash/Filebeat outputs, which indices are written
- Ingress / Dashboards URL
- Auth model: basic, SAML, OIDC, mTLS

If running outside Kubernetes (VM, bare metal), translate `kubectl exec` invocations to equivalent `ssh` or local shell calls.

## Diagnostic Workflow

### Step 1: Cluster Health

```bash
curl -s http://<opensearch-host>:9200/_cluster/health?pretty
```

- **green**: All primary and replica shards assigned.
- **yellow**: Primaries assigned, some replicas missing — common during rolling restart, single-node clusters with replica count > 0, or pending node addition.
- **red**: Some primaries unassigned — data loss risk if not corrected.

### Step 2: Node Status

```bash
curl -s http://<host>:9200/_cat/nodes?v
```

Verify expected node count, roles (cluster_manager / master, data, ingest), and JVM heap utilization. Heap > 75% sustained is a warning; > 90% indicates undersized heap or aggressive query patterns.

### Step 3: Shard Allocation

```bash
curl -s 'http://<host>:9200/_cat/shards?v&h=index,shard,prirep,state,node,unassigned.reason'
```

If unassigned shards exist:

```bash
curl -s http://<host>:9200/_cluster/allocation/explain?pretty
```

The explain output names the precise reason (disk watermark, allocation filters, max-shards-per-node, etc.) and is usually the fastest path to a fix.

### Step 4: Disk Watermarks

```bash
curl -s http://<host>:9200/_cat/allocation?v
```

Default watermarks: `low=85%`, `high=90%`, `flood_stage=95%`. At flood stage, indexing is blocked cluster-wide. Resolve by deleting old indices, expanding storage, or relocating shards.

### Step 5: Index Health

```bash
curl -s 'http://<host>:9200/_cat/indices?v&s=store.size:desc'
```

Spot-check expected indices, growth rates, and shard counts. Excessive shards-per-node (the rough rule of thumb is 20 per GiB of heap) is a common cause of cluster instability.

### Step 6: Ingestion Pipeline

If Fluent Bit:
```bash
kubectl logs -n <ns> -l <selector> --tail=30
```
Healthy: `[output:opensearch:opensearch.0]` lines with byte counts.
Unhealthy: `[error]`, `Domain name not found`, `retry` warnings.

Built-in metrics endpoint (port 2020):
```bash
curl -s http://<fluent-bit-pod>:2020/api/v1/metrics/prometheus | grep fluentbit_output
```

For Logstash, check `_node/stats/pipelines` on the Logstash REST endpoint (default 9600).
For Filebeat/Beats, check the agent's logs for `output.elasticsearch` errors.

### Step 7: Dashboards / Kibana

```bash
curl -s http://<dashboards-host>:5601/api/status
```

Status `green` with the OpenSearch (or Elasticsearch) plugin reporting `available` is healthy. `red` typically means cluster unreachable, auth misconfigured, or version mismatch.

### Step 8: ISM / ILM Policy Status

OpenSearch:
```bash
curl -s http://<host>:9200/_plugins/_ism/policies
curl -s 'http://<host>:9200/_plugins/_ism/explain/<index-pattern>?pretty'
```

Elasticsearch:
```bash
curl -s http://<host>:9200/_ilm/policy
curl -s 'http://<host>:9200/<index>/_ilm/explain?pretty'
```

Verify policies exist, are attached to expected templates, and indices are progressing through phases (hot → warm → cold → delete).

## Common Issues

### Cluster Red — Unassigned Primary Shards

1. `_cluster/allocation/explain` to identify the cause
2. If disk watermark: delete old indices or expand storage
3. Re-enable allocation if disabled:
   ```bash
   curl -X PUT http://<host>:9200/_cluster/settings \
     -H 'Content-Type: application/json' \
     -d '{"transient":{"cluster.routing.allocation.enable":"all"}}'
   ```

### Cluster Yellow After Rolling Restart

Expected during replica re-sync. If stuck > 10 min, check PVC binding and inter-node connectivity.

### Ingestion Pipeline "Domain name not found"

The output target (OpenSearch service) doesn't resolve. Check service exists in DNS, the operator (if any) has reconciled, and network policies allow traffic from ingestion pods.

### SAML / OIDC Login Loop

Reply URL mismatch is the most common cause. Compare what the IdP has registered against the actual ACS endpoint. Fallback to basic auth via API to confirm the cluster itself is healthy.

### Disk Full — Flood Stage Triggered

1. Identify largest indices: `_cat/indices?v&s=store.size:desc`
2. Delete old daily indices
3. Clear the read-only block once disk recovers:
   ```bash
   curl -X PUT http://<host>:9200/_cluster/settings \
     -H 'Content-Type: application/json' \
     -d '{"transient":{"cluster.blocks.read_only_allow_delete":null}}'
   ```
4. Long-term: confirm ISM/ILM policy is active and rotating

### Operator Not Reconciling (k8s)

Check operator pod logs and CRD presence. Common cause: chart didn't install CRDs, or operator's RBAC doesn't cover the namespace.

## Network Policy Context (k8s)

If connectivity fails despite a healthy-looking cluster, network policies are the next thing to check. List traffic sources expected to reach the cluster (ingestion pods, exporters, dashboards, query consumers) and confirm policies allow each.

## Output Format

When reporting:

1. Lead with cluster status (`green` / `yellow` / `red`) and node count.
2. Then node-level: heap, disk, role distribution.
3. Then shard-level: any unassigned, any rebalancing.
4. Then ingestion: lag, errors, throughput.
5. End with a single recommended next action if anything is degraded — concrete, runnable, smallest reversible step first.
