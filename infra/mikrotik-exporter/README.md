# MikroTik → Prometheus → Grafana monitoring

Monitors 3 MikroTik routers (`doohickey`, `gizmo`, `gadget` under
`internal.dployr.com`) by running the [`mktxp`](https://github.com/akpw/mktxp)
exporter in Kubernetes. mktxp speaks the RouterOS API over TLS, exposes
Prometheus metrics, kube-prometheus-stack scrapes them, and Grafana renders
them.

## TL;DR — pipeline

```
RouterOS api-ssl (8729, LE cert)
        │
        ▼
   mktxp  ──/metrics:49090──►  Prometheus (ServiceMonitor)  ──►  Grafana
        ▲                                                          dashboard
        │  Let's Encrypt cert (cert-manager DNS-01 via Cloudflare)
   cert-sync CronJob pushes the cert onto each router
```

## What's here

| File | Purpose |
|---|---|
| `namespace.yaml` | `monitoring` namespace (matches kube-prometheus-stack) |
| `mktxp-global.configmap.yaml` | `_mktxp.conf` — global, non-secret exporter settings |
| `mktxp-routers.secret.example.yaml` | `mktxp.conf` — router entries + passwords (**template**) |
| `deployment.yaml` | mktxp Deployment (hardened pod) |
| `service.yaml` | ClusterIP on 49090 |
| `servicemonitor.yaml` | Prometheus Operator scrape config |
| `networkpolicy.yaml` | Ingress = Prometheus only; egress = routers + DNS |
| `grafana-dashboard.configmap.yaml` | Sidecar-loaded starter dashboard |
| `letsencrypt/` | cert-manager Issuer + Certificate + router cert-sync |
| `../../docs/mikrotik-api-setup.md` | **Router-side** RouterOS commands |

## Prerequisites

1. **Routers configured** — run `docs/mikrotik-api-setup.md` on each router
   first (enable api-ssl, create the read-only `mktxp` user, lock down
   services). The exporter cannot connect until this is done.
2. **kube-prometheus-stack** installed in `monitoring` (Prometheus Operator +
   Grafana with the dashboard sidecar).
3. **cert-manager** installed (you confirmed it is).
4. A **NetworkPolicy-enforcing CNI** (Cilium/Calico) — otherwise the policies
   are inert.

## Deploy

### 1. Fill in the placeholders

Search-and-replace before applying:

| Placeholder | In | Set to |
|---|---|---|
| `10.0.0.0/24` | `networkpolicy.yaml`, `letsencrypt/certsync.cronjob.yaml` | CIDR covering the routers' resolved IPs |
| `release: kube-prometheus-stack` | `servicemonitor.yaml` | your Helm release name (`helm ls -n monitoring`) |
| `app.kubernetes.io/name: prometheus` | `networkpolicy.yaml` | your Prometheus pod label |
| `REPLACE_WITH_OPS_EMAIL` | `letsencrypt/clusterissuer-*.yaml` | ops email for LE notices |

### 2. Create the secrets out-of-band (never commit)

```sh
# Router monitoring credentials (fill the 3 passwords in a local copy first):
kubectl -n monitoring create secret generic mktxp-routers \
  --from-file=mktxp.conf=./mktxp.conf

# Cloudflare token for DNS-01 (in cert-manager's namespace):
kubectl -n cert-manager create secret generic cloudflare-api-token \
  --from-literal=api-token='<TOKEN>'

# Cert-sync SSH creds (only if you use the automated cert push):
kubectl -n monitoring create secret generic mktxp-certsync-ssh \
  --from-literal=username=certsync --from-literal=password='<STRONG>'
```

The `*.example.yaml` files show the exact shape; they are templates, not for
`kubectl apply`. Prefer External Secrets Operator / Vault / SOPS in real
environments.

### 3. Apply

```sh
kubectl apply -k infra/mikrotik-exporter/
```

### 4. Let's Encrypt cert onto the routers

cert-manager issues the cert (DNS-01, no public exposure needed). Confirm:

```sh
kubectl -n monitoring get certificate mikrotik-api      # READY=True
```

Then get it onto the routers — **two options**:

- **Automated** (`cert-sync` CronJob): create `mktxp-certsync-ssh` and a
  write-capable `certsync` RouterOS user (see the example Secret header).
  The daily CronJob pushes each renewal. **Treat the reference `sync.py` as
  needs-validation** — test against LE *staging* and one router first;
  RouterOS cert-import naming varies by version.
- **Manual** (see below) if you would rather not hold a write credential in
  the cluster.

## Manual cert install (per router)

```sh
# From a machine with the issued cert (kubectl get secret mikrotik-api-tls):
kubectl -n monitoring get secret mikrotik-api-tls -o jsonpath='{.data.tls\.crt}' | base64 -d > api.crt
kubectl -n monitoring get secret mikrotik-api-tls -o jsonpath='{.data.tls\.key}' | base64 -d > api.key
scp api.crt api.key admin@doohickey.internal.dployr.com:
```

```routeros
/certificate remove [find name~"mktxp-api"]
/certificate import file-name=api.crt passphrase=""
/certificate import file-name=api.key passphrase=""
/ip service set api-ssl certificate=[/certificate find name~"api.crt"] disabled=no
/file remove [find name=api.key]
/file remove [find name=api.crt]
```

## Verify end-to-end

```sh
# 1. Exporter is up and producing metrics for all 3 routers:
kubectl -n monitoring port-forward deploy/mktxp 49090:49090
curl -s localhost:49090 | grep -c '^mktxp_system_uptime'   # expect 3

# 2. Prometheus discovered the target:
#    Prometheus UI -> Status -> Targets -> mktxp is UP.

# 3. Grafana: dashboard "MikroTik — mktxp" appears (folder: Network) and the
#    Router variable lists doohickey/gizmo/gadget with live data.
```

If metrics are missing for one router, check the exporter logs
(`kubectl -n monitoring logs deploy/mktxp`) — a TLS/verify error there points
back at the router's cert or the `ssl_ca_file` path.

## Security posture (from the threat model)

- **Read-only router user** (`policy=api,read`) — no `write`, no `sensitive`.
  Router config is readable (recon-grade) but unchangeable via this user.
- **Per-router unique passwords** — one leaked secret ≠ all three exposed.
- **Encrypted, verified API** — mktxp validates the LE cert + hostname; no
  `ssl_certificate_verify=False`.
- **NetworkPolicy both ways** — `/metrics` is reachable only by Prometheus
  (prevents info-disclosure and scrape-amplification DoS against routers);
  egress is restricted to the router network and DNS.
- **Separate, privileged cert-sync credential** — kept distinct from the
  monitoring user, source-restricted, optional (manual install available).
- **Hardened pods** — non-root, read-only rootfs, all caps dropped,
  seccomp RuntimeDefault, no service-account token.
