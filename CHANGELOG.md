# Changelog

This fork follows upstream HomeProxy unless an entry below says otherwise.

## Unreleased

### sing-box 1.14 migration

HomeProxy now requires **sing-box 1.14.0 or newer**. The package dependency
and service preflight enforce that minimum version.

- Removed generation of `dns.independent_cache`, which sing-box deprecated.
- Replaced `experimental.cache_file.store_rdrc` and `rdrc_timeout` with the
  `store_dns` setting. The LuCI wording is now **Persist DNS cache**: this has
  wider behaviour than the old rejected-response cache, because it persists
  DNS cache entries.
- Generated ACME TLS now uses a certificate provider instead of inline
  `tls.acme`; existing UCI ACME fields remain compatible.
- Remote rule-set downloads now use HTTP clients instead of
  `download_detour`. A rule-set with no explicit download outbound still uses
  HomeProxy's normal default outbound; an explicit outbound remains per
  rule-set.
- Removed obsolete DNS-rule IP-filter fields from the UI and generator. DNS
  response filtering is emitted as an `evaluate` rule followed by
  `match_response`; a response-filter rule now requires an explicit evaluation
  DNS server.
- Removed the deprecated per-DNS-rule `strategy` output. Existing UCI values
  stop with a clear migration error instead of silently changing resolver
  behaviour; move the preference to an appropriate DNS server/global setting.
- Legacy Direct nodes with `override_address` or `override_port` are no longer
  valid sing-box outbounds. LuCI labels them as legacy and explains that an
  equivalent routing rule must be created. They are deliberately not converted
  automatically: a destination override alone has no routing match condition.
- Added the Hysteria2 **Disable Chrome QUIC parrot** advanced option, for
  servers using an Ed25519 certificate.

### sing-box 1.14 P2 features

- Added Snell client and server configuration (v4/v5 compatibility and v6).
- Added the L3-only Bridge outbound.
- Added OpenConnect and OpenVPN client endpoints, OpenVPN server endpoints,
  and DNS servers that consume resolvers pushed by either VPN endpoint.
- Added the sing-box API service and optional Dashboard. The default API listen
  address is `127.0.0.1`; configure a secret before exposing it elsewhere.
- Added Linux network-namespace definitions and per-node namespace selection.
- Added Hysteria Realm service plus Hysteria2 client/server Realm settings,
  BBR profile, randomized hop interval, and Gecko obfuscation packet sizes.

### Upgrade notes

Back up `/etc/config/homeproxy` before upgrading. If you use custom DNS
response filtering, ACME server mode, Hysteria2, or legacy Direct nodes, run
`sing-box check` against the generated configuration on the router before
restarting HomeProxy.

### References

- [sing-box changelog](https://sing-box.sagernet.org/changelog/)
- [sing-box migration guide](https://sing-box.sagernet.org/migration/)
- [Deprecated features](https://sing-box.sagernet.org/deprecated/)
- [DNS rule action documentation](https://sing-box.sagernet.org/configuration/dns/rule_action/)
- [DNS rule documentation](https://sing-box.sagernet.org/configuration/dns/rule/)
