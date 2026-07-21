# Threat Modeler — Project Memory

## Auth models in use
- **RouterOS API (MikroTik routers)**: api-ssl (TLS, port 8729) with a
  username/password RO user. RouterOS permission model uses group
  `policy=` flags: `api`,`read`,`write`,`policy`,`password`,`sensitive`,
  `romon`, etc. `read` alone grants near-full config-tree read access
  (firewall, routes, DHCP leases w/ hostnames+MACs, wireless clients,
  VPN peer identities) — it is recon-grade, not just "metrics." Secret
  *values* (passwords/keys in config) require the separate `sensitive`
  policy, which should never be granted to a monitoring user. RouterOS
  has no finer-grained read ACL than this — accept the recon exposure,
  protect the credential instead.
- No cluster-wide SSO/OIDC/session-cookie model has been established in
  this project yet as of 2026-07-21 (first threat-modeling pass).

## Trust boundaries that recur
- **Router management plane ↔ cluster**: controlled by (a) RouterOS
  service-address restriction to the monitoring workload's egress CIDR,
  and (b) NetworkPolicy egress from the monitoring pod restricted to
  router IPs on the specific management port only.
- **Any-pod-in-cluster ↔ exporter `/metrics`**: Prometheus exporters are
  unauthenticated at the app layer by convention; the *only* control is
  NetworkPolicy ingress scoped to the real Prometheus pod/namespace
  selector. Default k8s networking is allow-all, so an unspecified
  NetworkPolicy here defaults to "everyone can read."

## Recurring exporter-pattern threat
- Prometheus exporters that proxy to a live backend (routers, DBs, etc.)
  typically query the backend live at scrape time. An open `/metrics`
  ingress isn't just an info-disclosure risk — it's a DoS-amplification
  path against the backend (repeated scrapes = repeated backend load).
  Always pair the NetworkPolicy fix with scrape_interval sanity and ask
  whether the exporter retries aggressively on backend timeout.

## Standard mitigations already recommended once (don't re-derive)
- Custom RouterOS group with minimal explicit policy (`api,read`), not a
  built-in group — built-in group membership can drift or over-grant via
  UI/API defaults. Verify with `/user group print` after creation.
- Per-router unique credentials (not one shared RO user across multiple
  routers) to cap blast radius — flagged as a judgment call on ops
  overhead, not a hard requirement.
- Third-party/community-maintained exporter images (e.g., akpw/mktxp,
  not vendor-official): pin to digest, run non-root/read-only-rootfs/
  drop-caps, queue vulnerability-scanner once a lock/manifest exists.

## Project-specific tool findings
- `akpw/mktxp` (Python RouterOS Prometheus exporter): config exposes
  `use_ssl`, `no_ssl_certificate`, `ssl_certificate_verify`,
  `ssl_check_hostname`, `ssl_ca_file` keys (mktxp/cli/config/config.py).
  From the source's boolean-default key groupings (not a directly-read
  default assignment — ~75% confidence), `ssl_certificate_verify`
  appears to default to **off**. Always recommend explicitly setting
  verify=True + ssl_ca_file rather than trusting the library default.
  Worth re-confirming with a direct source read if this comes up again
  and certainty matters more.
- gh CLI is not installed in this sandbox; GitHub API access via curl is
  also gated to repos explicitly enabled for the session. Use WebFetch
  against github.com/raw.githubusercontent.com blob URLs instead (raw.
  githubusercontent.com 404's easily on branch-name guesses — the
  github.com/.../blob/ URL via WebFetch worked better).

## Past threats that turned into incidents
- None recorded yet for this project.
