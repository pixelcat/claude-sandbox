# MikroTik RouterOS — enable the API for monitoring

These are the router-side settings that must be in place **before** the
`mktxp` exporter in Kubernetes can collect metrics. Run them once per
router (3 routers total).

## TL;DR

Per router:

1. Generate a self-signed TLS cert for `api-ssl`.
2. Enable `api-ssl` (port 8729), disable the plaintext `api` and other
   insecure services.
3. Restrict the `api-ssl` service (and a firewall rule) to the cluster's
   egress address only.
4. Create a **read-only** monitoring user (`policy=api,read`).

The exporter talks to the encrypted API only. Credentials never cross the
wire in clear.

---

## Fill these in first

| Placeholder | Meaning | Example |
|---|---|---|
| `<ROUTER_IP>` | This router's address / identity | `10.10.0.1` |
| `<K8S_EGRESS_CIDR>` | Source address the cluster leaves from (SNAT / node CIDR the exporter pod egresses as). Lock the API to this. | `10.20.0.0/24` |
| `<MGMT_CIDR>` | Your admin network for winbox/ssh | `10.99.0.0/24` |
| `<STRONG_PASSWORD>` | Per-router monitoring password (unique per router) | generate 24+ random chars |

The three routers each get their **own** unique monitoring password. Do not
reuse one password across all three — a leak of one exporter secret should
not expose all three routers equally. (The blast radius is already limited
by the read-only policy, but distinct passwords keep it tighter.)

---

## 1. Create a TLS certificate for the API

RouterOS 7 syntax. `mktxp` is configured with `ssl_certificate_verify = False`,
so a plain self-signed server certificate is sufficient — no external CA
needed.

```routeros
/certificate
add name=api-ssl-cert common-name=<ROUTER_IP> key-size=2048 days-valid=3650 \
    key-usage=digital-signature,key-encipherment,tls-server
sign api-ssl-cert
```

`sign` runs asynchronously. Confirm it finished (the `KLAT` flags column
should show the key/trust flags):

```routeros
/certificate print detail where name=api-ssl-cert
```

## 2. Enable api-ssl, disable the insecure services

```routeros
# Turn the encrypted API on, bind the cert, restrict the source address,
# force TLS 1.2+.
/ip service set api-ssl certificate=api-ssl-cert tls-version=only-1.2 \
    address=<K8S_EGRESS_CIDR> disabled=no

# Turn OFF everything that is plaintext or unused.
/ip service disable api,telnet,ftp,www

# Keep management planes locked to the admin network.
/ip service set winbox address=<MGMT_CIDR>
/ip service set ssh    address=<MGMT_CIDR>
```

Verify:

```routeros
/ip service print
```

Expected: `api-ssl` enabled with your cert and address; `api`, `telnet`,
`ftp`, `www` disabled.

## 3. Create the read-only monitoring user

`mktxp` needs exactly two policies: `api` (to use the API service) and
`read` (to read config/state). Nothing else.

```routeros
/user group add name=mktxp-monitoring policy=api,read \
    comment="Read-only monitoring for mktxp exporter"

/user add name=mktxp group=mktxp-monitoring password=<STRONG_PASSWORD> \
    address=<K8S_EGRESS_CIDR> comment="mktxp Prometheus exporter"
```

The `address=` on the user is defense in depth: even with valid
credentials, a login is only accepted from the cluster egress range.

> RouterOS v6 only: if you later enable the LTE collector, add `test` to the
> group policy. Not needed on v7 or for the default collector set.

## 4. Firewall the API port (defense in depth)

The `address=` on `/ip service` already restricts access, but an explicit
input-chain rule makes the intent auditable and survives service edits.
Adjust `place-before` to sit above your general accept/drop rules.

```routeros
/ip firewall filter
add chain=input protocol=tcp dst-port=8729 src-address=<K8S_EGRESS_CIDR> \
    action=accept comment="mktxp api-ssl allow" place-before=0
add chain=input protocol=tcp dst-port=8729 \
    action=drop comment="mktxp api-ssl drop others" place-before=1
```

## 5. Verify from the cluster side

Once the exporter is deployed, confirm reachability end-to-end (see
`infra/mikrotik-exporter/README.md`). From inside the exporter pod's
network, port 8729 should be open **only** from the egress range and
refused from anywhere else.

---

## What each router now exposes

- `api-ssl` on **8729/tcp**, TLS 1.2+, self-signed cert, source-restricted.
- A `mktxp` user that can **read** but not change anything.
- No plaintext API, telnet, ftp, or www.

Record the three passwords in your secret manager. They go into the
Kubernetes Secret described in `infra/mikrotik-exporter/README.md` — never
commit them to git.
