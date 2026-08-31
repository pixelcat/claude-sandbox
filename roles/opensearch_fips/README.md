# opensearch_fips

Configures FIPS 140-3 mode for OpenSearch and Logstash: OS FIPS mode, the
BouncyCastle FIPS provider in the JVM, BCFKS keystores, and approved TLS
suites.

## Read this before using it

**This role configures FIPS mode. It does not make OpenSearch FIPS-validated.**

Elastic ships a documented, supported `xpack.security.fips_mode.enabled`.
OpenSearch has no vendor-supported equivalent — running it on a validated
cryptographic module is possible and is what this role sets up, but it is not
a product certification. Verify the current state against your target
OpenSearch version before relying on it; treat the gap as a written, accepted
deviation rather than an assumption.

What the role establishes, and can prove:

| Property | Verified by |
|---|---|
| Kernel in FIPS mode | `/proc/sys/crypto/fips_enabled == 1` |
| JVM loaded the validated provider | `-XshowSettings:security` reports BCFIPS |
| Keystores in an approved format | `keytool -list -storetype BCFKS` succeeds |
| Wire uses an approved suite | live `openssl s_client` handshake |

## Safety

**Enabling OS FIPS mode requires a reboot and can leave a host unreachable.**
SSH host keys, the boot chain, and existing certificates that use non-approved
algorithms all stop working. `fips_reboot` defaults to `false` for that
reason — stage the change, then reboot during a window where you have console
access.

The role never deletes a source keystore. Conversion writes a new `.bcfks`
file, so a bad conversion is recovered by pointing the config back at the
original.

## Required input: the provider jars

The BouncyCastle FIPS jars *are* the validated cryptographic module. The role
does not download them — under a compliance boundary the artefacts must come
from an internal, checksum-verified source, and an unverified jar cannot be
attested as the validated module. The role refuses to run without a `sha256`
for each.

Both `bc-fips` (the module) and `bctls-fips` (the JSSE provider) are required.
Without `bctls`, TLS silently falls back to a non-approved provider while
everything else looks correct.

```yaml
fips_provider_jars:
  - src: files/bc-fips-2.0.0.jar
    sha256: "0123…"          # 64 hex chars, enforced
  - src: files/bctls-fips-2.0.19.jar
    sha256: "4567…"
```

## Usage

```yaml
- hosts: opensearch_nodes
  become: true
  roles:
    - role: opensearch_fips
      vars:
        fips_target_opensearch: true
        fips_reboot: false            # reboot by hand, with console access
        fips_provider_jars: "{{ vault_fips_jars }}"
        fips_keystores:
          - src: /etc/opensearch/certs/node.p12
            src_type: PKCS12
            dest: /etc/opensearch/certs/node.bcfks
            password_var: opensearch_keystore_password
```

Keystore passwords are referenced **by variable name**, not by value, so the
secret never appears in task arguments where callback plugins would log it.
Supply the named variable from vault.

Staging the JVM layer before the reboot:

```yaml
fips_require_os_mode: false   # configure now, kernel not yet in FIPS mode
fips_verify_strict: false     # verification will not pass yet, and shouldn't
```

Reset both to their defaults for the compliance run.

## Variables

See `defaults/main.yml`. The ones that change behaviour materially:

| Variable | Default | Effect |
|---|---|---|
| `fips_enable_os` | `true` | Enable kernel FIPS mode |
| `fips_reboot` | `false` | Reboot automatically to activate it |
| `fips_require_os_mode` | `true` | Refuse JVM config while kernel is not in FIPS mode |
| `fips_approved_only` | `true` | Reject non-approved algorithms at runtime |
| `fips_verify_strict` | `true` | Fail the play when FIPS cannot be proven |

Setting `fips_approved_only: false` makes the node non-compliant. It exists as
a diagnostic escape hatch and the role logs a warning when it is used.

## Platform notes

**RHEL family** — `fips-mode-setup --enable`, then reboot.

**Ubuntu** — FIPS ships through Ubuntu Pro and needs an attached subscription.
The role asserts that a `fips*` service is enabled rather than enrolling: the
token is a credential and attaching changes the machine's entitlement state,
neither of which belongs in an unattended play.

## Testing

```bash
molecule test
```

Kernel FIPS mode cannot be exercised in a container — `/proc/sys/crypto/fips_enabled`
is host state and `fips-mode-setup` needs a reboot. The default scenario runs
with `fips_enable_os: false` and covers what is testable: assertions, template
rendering, provider placement, and idempotence. **Kernel-level behaviour needs
a VM.** Do not read a green `molecule test` as evidence that FIPS works.

The verify play checks provider *ordering*, not just presence. A `java.security`
containing the right provider names in the wrong order passes a naive grep and
leaves the JVM on SunJCE — which is the failure mode most likely to reach
production unnoticed.

## Known gaps

- **Logstash pipeline configs are not edited.** The `opensearch` output plugin
  needs `truststore` pointed at a BCFKS store, and that is pipeline-specific.
  The role prints a reminder; confirm the plugin negotiates an approved suite
  before calling it done.
- **OpenSearch Dashboards is out of scope.** It is Node.js, not JVM, and needs
  a separate approach.
- **The security plugin's own dependencies** have historically included
  non-FIPS crypto. Enabling this role does not audit them.
