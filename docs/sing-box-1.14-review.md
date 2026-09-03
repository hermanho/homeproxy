# sing-box 1.14 review and follow-up plan

Reviewed against the official sing-box change log, migration guide, and deprecated-feature list on 2026-09-03.

Sources:

- <https://sing-box.sagernet.org/changelog/>
- <https://sing-box.sagernet.org/migration/>
- <https://sing-box.sagernet.org/deprecated/>

## Compatibility contract

HomeProxy targets sing-box **1.14.0 or newer**. The package dependency and service preflight must agree on this minimum version. Older sing-box versions are not a supported compatibility target.

## P2: optional 1.14 feature work

The following are real sing-box 1.14 capabilities, but are not required to migrate HomeProxy's existing generated configuration:

- Snell inbound/outbound (excluding Snell v5 QUIC proxy support).
- OpenVPN client and server endpoints; OpenConnect client endpoint.
- sing-box API service, Dashboard hosting, remote control, and `sing-box api` CLI.
- L3 forwarding and the `bridge` outbound. This requires careful privilege, TUN, firewall, and procd-jail design.
- Linux network namespaces, which likewise need lifecycle and privilege design before exposing them in LuCI.
- Hysteria Realm service and Hysteria2 NAT traversal.
- Optional DNS additions: optimistic cache, DNS query timeouts, mDNS, search-domain rule items, and `preferred_by`.

DNS response matching is deliberately **not** P2: it is needed for migration of legacy address-filter DNS rules.

## Remaining migration work before P2

### P0: remove legacy DNS `strategy` action use

sing-box 1.14 deprecates the legacy `strategy` DNS rule action option. It also becomes incompatible with `ip_version` / `query_type` in the same DNS configuration when legacy address-filter fields are present. HomeProxy currently emits `strategy` from custom DNS rules, so this needs a generator/UI migration to the current action model before 1.16 removes the field.

Status: HomeProxy no longer emits it. Because sing-box provides no equivalent
per-rule setting, an existing UCI value now produces an explicit migration
error instead of silently changing DNS behaviour.

### P0: preserve remote rule-set default download routing

The HTTP-client migration must preserve the old implicit default: a remote rule-set without an explicit outbound used the routing default outbound. `route.default_http_client` must therefore be generated from that default outbound, not always `direct-out`. Explicit per-rule-set outbound selection continues to use a dedicated HTTP client.

Status: generated from `main-out` in normal modes and from the configured
custom default outbound in custom mode.

### P1: validate DNS address-filter semantics

The supported migration shape is:

1. `evaluate` against the fallback resolver.
2. A `match_response` rule that identifies the address/rule-set result and selects the intended resolver.
3. The ordinary fallback route rule.

Do not regard a mechanical transformation as semantically equivalent without targeted testing. Cover `ip_cidr`, `ip_is_private`, IP-only rule-sets, `rule_set_ip_cidr_accept_empty`, `ip_version`, `query_type`, and reverse mapping when those features are enabled. Legacy address-filter rules can otherwise be rejected at startup, or route a query through a different resolver than before.

### P1: legacy Direct nodes need a user-visible migration path

Direct outbound destination overrides cannot be safely converted automatically: a route action needs matching criteria that an old direct outbound does not contain. Keep the generator rejection as a safety boundary, add a LuCI migration warning/instructions, and preserve the old UCI values until the user creates an equivalent routing rule with `override_address` and/or `override_port`.

Status: the legacy node is labelled in LuCI with migration instructions and is
rejected by the generator until it is replaced with an explicit routing rule.

### P1: runtime validation when affected features are used

No router integration fixture suite is included at this stage. Before enabling
custom DNS address filtering, ACME server mode, legacy Direct-node migration,
or Hysteria2, generate the active configuration and run `sing-box check` on
the router. The router remains the relevant runtime environment because GitHub
Actions does not provide OpenWrt's `ucode` and HomeProxy modules.

## Rollout order

1. Close the P0/P1 gaps above.
2. Build the APK and run `sing-box check --config` on the router before restarting HomeProxy.
3. Keep the previous APK and a UCI backup for rollback.
4. Add user-facing release notes covering full DNS-cache persistence, Direct-node migration, and Hysteria2 Ed25519 certificates.
5. Start P2 as separate, feature-scoped work after the migration path is validated.
