#!/usr/bin/env python3
"""Render isolated UCI fixtures with OpenWrt tools; never edit live configuration.

Usage: python3 tests/check_fakeip.py --ssh-target root@router --ssh-key /path/to/key
Requires ucode, utpl, sing-box and nft on the target. A temporary loopback DNS service is used for reply TTL checks.
"""
import argparse
import io
import json
from pathlib import Path
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--ssh-target', required=True)
parser.add_argument('--ssh-key', required=True)
args = parser.parse_args()

fixture = """config homeproxy 'config'
 option routing_mode 'custom'
 option proxy_mode 'tun'
 option ipv6_support '0'
 option routing_port 'common'
config homeproxy 'infra'
 option tun_name 'singtun0'
 option tun_mark '102'
config homeproxy 'control'
 option lan_proxy_mode 'except_listed'
 list listen_interfaces 'br-lan'
 list lan_direct_ipv4_ips '192.168.10.101'
config homeproxy 'routing'
 option default_outbound 'direct-out'
 option default_outbound_dns 'real'
config homeproxy 'dns'
 option default_server 'real'
 option reverse_mapping '1'
 option fakeip_enabled '0'
 option fakeip_range '198.18.0.0/15'
config dns_server 'real'
 option enabled '1'
 option type 'udp'
 option server '127.0.0.1'
 option server_port '16554'
 option outbound 'direct-out'
config dns_rule 'real_rule'
 option enabled '1'
 list domain_suffix 'example.com'
 option action 'route'
 option server 'real'
 option rewrite_ttl '120'
config routing_rule 'real_route'
 option enabled '1'
 list domain_suffix 'example.com'
 option action 'route'
 option outbound 'direct-out'
config fakeip_rule 'pilot'
 option enabled '1'
 list domain 'a.example.com'
 list domain_suffix 'example.com'
 list domain_regex '^cdn[0-9]+[.]example[.]com$'
"""

payload = io.BytesIO()
with tarfile.open(fileobj=payload, mode='w:gz') as archive:
    def add(name, text):
        data = text.encode()
        entry = tarfile.TarInfo(name)
        entry.size = len(data)
        archive.addfile(entry, io.BytesIO(data))

    for filename in ['homeproxy.uc', 'generate_client.uc', 'firewall_post.ut']:
        text = (ROOT / 'root/etc/homeproxy/scripts' / filename).read_text()
        text = text.replace("cursor()", "cursor('@TEST_ROOT@/config', '@TEST_ROOT@/delta')")
        text = text.replace("'/etc/homeproxy'", "'@TEST_ROOT@'")
        text = text.replace("'/var/run/homeproxy'", "'@TEST_ROOT@/run'")
        text = text.replace("'/etc/homeproxy/scripts/homeproxy.uc'", "'@TEST_ROOT@/homeproxy.uc'")
        add(filename, text)
    add('base', fixture)
    add('config/dhcp', "config dnsmasq\n option local '/local/'\n option domain 'local'\n")
    add('rules.json', json.dumps({'version': 3, 'rules': [{'domain_suffix': ['example.com']}]}))

script = r'''set -eu
TTL_PID=
trap '[ -z "$TTL_PID" ] || kill "$TTL_PID" 2>/dev/null || true' EXIT INT TERM
mkdir -p "$TASK_DIR/run" "$TASK_DIR/delta" "$TASK_DIR/results"
for SCRIPT in homeproxy.uc generate_client.uc firewall_post.ut; do
 sed -i "s|@TEST_ROOT@|$TASK_DIR|g" "$TASK_DIR/$SCRIPT"
done
run_case() {
 CASE_NAME=$1
 ucode -L "$TASK_DIR" -S "$TASK_DIR/generate_client.uc"
 sing-box check -c "$TASK_DIR/run/sing-box-c.json"
 cp "$TASK_DIR/run/sing-box-c.json" "$TASK_DIR/results/$CASE_NAME.json"
 utpl -L "$TASK_DIR" -S "$TASK_DIR/firewall_post.ut" > "$TASK_DIR/results/$CASE_NAME.nft"
 { echo 'table inet homeproxy_fakeip_fixture {'; cat "$TASK_DIR/results/$CASE_NAME.nft"; echo '}'; } > "$TASK_DIR/check.nft"
 nft -c -f "$TASK_DIR/check.nft"
}
check_ttl() {
 TTL_CASE=$1
 ucode -D task_root="$TASK_DIR" -D ttl_case="$TTL_CASE" -e '
  import { readfile, writefile } from "fs";
  const c = json(readfile(task_root + "/results/" + ttl_case + ".json"));
  c.inbounds = [{ type: "direct", tag: "ttl-in", listen: "127.0.0.1", listen_port: 16653 }];
  c.route = { rules: [{ inbound: "ttl-in", action: "hijack-dns" }], final: "direct-out", default_domain_resolver: { server: "cfg-real-dns" }, auto_detect_interface: true };
  c.experimental.cache_file.path = task_root + "/ttl-cache.db";
  c.log.output = task_root + "/ttl.log";
  writefile(task_root + "/ttl.json", sprintf("%.J", c));
 '
 sing-box run -c "$TASK_DIR/ttl.json" > "$TASK_DIR/ttl-stderr" 2>&1 &
 TTL_PID=$!
 sleep 1
 if ! kill -0 "$TTL_PID" 2>/dev/null; then
  cat "$TASK_DIR/ttl-stderr" "$TASK_DIR/ttl.log" >&2
  exit 1
 fi
 dig @127.0.0.1 -p 16653 a.example.com A +time=2 +tries=1 +noall +answer | awk '$4 == "A" { print $2 }' > "$TASK_DIR/results/$TTL_CASE.ttl"
 kill "$TTL_PID"
 wait "$TTL_PID" || true
 TTL_PID=
}
cp "$TASK_DIR/base" "$TASK_DIR/config/homeproxy"
run_case disabled >&2
sed "s/option fakeip_enabled '0'/option fakeip_enabled '1'/" "$TASK_DIR/base" > "$TASK_DIR/config/homeproxy"
run_case enabled >&2
sed -i "/config fakeip_rule 'pilot'/a\\ list source_ip_cidr '192.168.10.101'" "$TASK_DIR/config/homeproxy"
run_case legacy_source >&2
check_ttl enabled >&2
sed "s/option reverse_mapping '1'/option reverse_mapping '0'/" "$TASK_DIR/config/homeproxy" > "$TASK_DIR/no-reverse"
cp "$TASK_DIR/no-reverse" "$TASK_DIR/config/homeproxy"
run_case no_reverse >&2
sed "s/option reverse_mapping '0'/option reverse_mapping '1'/" "$TASK_DIR/config/homeproxy" > "$TASK_DIR/custom-ttl"
cp "$TASK_DIR/custom-ttl" "$TASK_DIR/config/homeproxy"
sed -i "/config homeproxy 'dns'/a\\ option fakeip_ttl '15'" "$TASK_DIR/config/homeproxy"
run_case custom_ttl >&2
check_ttl custom_ttl >&2
echo '198.18.0.0/15' > "$TASK_DIR/run/fakeip-range"
cp "$TASK_DIR/base" "$TASK_DIR/config/homeproxy"
run_case draining >&2
rm -f "$TASK_DIR/run/fakeip-range" "$TASK_DIR/run/cache.db"
run_case after_reboot >&2
sed "s/option fakeip_enabled '0'/option fakeip_enabled '1'/" "$TASK_DIR/base" > "$TASK_DIR/config/homeproxy"
cat >> "$TASK_DIR/config/homeproxy" <<RULESET
config ruleset 'domains'
 option enabled '1'
 option type 'local'
 option format 'source'
 option path '$TASK_DIR/rules.json'
RULESET
sed -i '/list domain /d; /list domain_suffix /d; /list domain_regex /d' "$TASK_DIR/config/homeproxy"
sed -i "/config fakeip_rule 'pilot'/a\\ list rule_set 'domains'" "$TASK_DIR/config/homeproxy"
run_case ruleset >&2
expect_failure() {
 if ucode -L "$TASK_DIR" -S "$TASK_DIR/generate_client.uc" > "$TASK_DIR/error" 2>&1; then
  echo "Expected generation failure: $1" >&2
  exit 1
 fi
 cp "$TASK_DIR/error" "$TASK_DIR/results/$1.error"
}
sed "s/option fakeip_enabled '0'/option fakeip_enabled '1'/; s/option ipv6_support '0'/option ipv6_support '1'/" "$TASK_DIR/base" > "$TASK_DIR/config/homeproxy"
expect_failure ipv6
sed "s/option fakeip_enabled '0'/option fakeip_enabled '1'/; s/198.18.0.0\/15/192.168.0.0\/16/" "$TASK_DIR/base" > "$TASK_DIR/config/homeproxy"
expect_failure range
sed "s/option fakeip_enabled '0'/option fakeip_enabled '1'/; /list domain /d; /list domain_suffix /d; /list domain_regex /d" "$TASK_DIR/base" > "$TASK_DIR/config/homeproxy"
expect_failure matcher
sed "s/option fakeip_enabled '0'/option fakeip_enabled '1'/" "$TASK_DIR/base" > "$TASK_DIR/config/homeproxy"
sed -i "/config homeproxy 'dns'/a\\ option fakeip_ttl '0'" "$TASK_DIR/config/homeproxy"
expect_failure ttl_zero
sed -i "s/option fakeip_ttl '0'/option fakeip_ttl '301'/" "$TASK_DIR/config/homeproxy"
expect_failure ttl_high
echo '198.19.0.0/16' > "$TASK_DIR/run/fakeip-range"
sed "s/option fakeip_enabled '0'/option fakeip_enabled '1'/" "$TASK_DIR/base" > "$TASK_DIR/config/homeproxy"
expect_failure changed_range
tar -czf - -C "$TASK_DIR/results" .
'''
complete = io.BytesIO()
with tarfile.open(fileobj=io.BytesIO(payload.getvalue()), mode='r:gz') as source:
    with tarfile.open(fileobj=complete, mode='w:gz') as target:
        for item in source:
            target.addfile(item, source.extractfile(item))
        content = script.encode()
        entry = tarfile.TarInfo('run.sh')
        entry.size = len(content)
        target.addfile(entry, io.BytesIO(content))
remote = "TASK_DIR=$(mktemp -d /tmp/homeproxy-fakeip-check.XXXXXX); export TASK_DIR; trap 'rm -rf \"$TASK_DIR\"' EXIT INT TERM; tar -xz -C \"$TASK_DIR\" && sh \"$TASK_DIR/run.sh\""
command = ['ssh', '-i', args.ssh_key, '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes',
           '-o', 'ConnectTimeout=7', args.ssh_target, remote]
result = subprocess.run(command, input=complete.getvalue(), capture_output=True)
if result.returncode:
    raise SystemExit(result.stderr.decode(errors='replace'))
data = result.stdout
with tarfile.open(fileobj=io.BytesIO(data), mode='r:gz') as archive:
    contents = {item.name.removeprefix('./'): archive.extractfile(item).read().decode()
                for item in archive if item.isfile()}

configs = {case: json.loads(contents[case + '.json'])
           for case in ['disabled', 'enabled', 'legacy_source', 'draining', 'after_reboot', 'ruleset', 'no_reverse', 'custom_ttl']}
disabled = configs['disabled']
assert not any(server['type'] == 'fakeip' for server in disabled['dns']['servers'])
assert 'store_fakeip' not in disabled['experimental']['cache_file']
assert 'Fake-IP' not in contents['disabled.nft']
assert not any(server['type'] == 'fakeip' for server in configs['after_reboot']['dns']['servers'])
assert 'store_fakeip' not in configs['after_reboot']['experimental']['cache_file']
assert 'Fake-IP' not in contents['after_reboot.nft']
for case in ['enabled', 'draining', 'ruleset', 'no_reverse', 'custom_ttl']:
    config = configs[case]
    assert any(server.get('inet4_range') == '198.18.0.0/15' for server in config['dns']['servers'])
    assert config['experimental']['cache_file']['store_fakeip'] is True
    assert '/run/cache.db' in config['experimental']['cache_file']['path']
    assert config['route']['default_domain_resolver']['server'] == 'cfg-real-dns'
    assert not any(rule.get('action') == 'resolve' for rule in config['route']['rules'])
    nft = contents[case + '.nft']
    assert 'ip daddr 198.18.0.0/15 counter meta mark set 0x66 return' in nft
    tun = nft.split('chain homeproxy_mangle_tun {', 1)[1]
    assert tun.index('!homeproxy: Fake-IP') < tun.index('ip daddr @homeproxy_local_addr_v4')
    lan = nft.split('chain homeproxy_mangle_lanac {', 1)[1].split('chain homeproxy_mangle_tun_mark', 1)[0]
    assert lan.index('ip daddr 198.18.0.0/15') < lan.index('ip saddr { 192.168.10.101 }')

enabled_rules = configs['enabled']['dns']['rules']
fake = next(rule for rule in enabled_rules if rule.get('server') == 'fakeip-dns')
assert fake['domain'] == ['a.example.com']
assert fake['domain_suffix'] == ['example.com']
assert fake['domain_regex'] == ['^cdn[0-9]+[.]example[.]com$']
assert all('source_ip_cidr' not in rule for rule in enabled_rules
           if rule.get('server') == 'fakeip-dns' or rule.get('action') == 'predefined')
assert all('source_ip_cidr' not in rule for rule in configs['legacy_source']['dns']['rules']
           if rule.get('server') == 'fakeip-dns' or rule.get('action') == 'predefined')
assert fake['query_type'] == ['A']
assert fake['rewrite_ttl'] == 120
assert contents['enabled.ttl'].strip() == '120'
assert contents['custom_ttl.ttl'].strip() == '15'
assert next(r for r in configs['custom_ttl']['dns']['rules'] if r.get('server') == 'fakeip-dns')['rewrite_ttl'] == 15
for case in ['enabled', 'custom_ttl']:
    assert next(r for r in configs[case]['dns']['rules'] if r.get('server') == 'cfg-real-dns')['rewrite_ttl'] == 120
assert 'reverse_mapping' not in configs['no_reverse']['dns']
assert not any('sniff' in inbound for inbound in configs['no_reverse']['inbounds'])
assert enabled_rules.index(fake) < next(i for i, rule in enumerate(enabled_rules) if rule.get('server') == 'cfg-real-dns')
assert enabled_rules[0]['server'] == 'dnsmasq-local'
assert any(rule.get('query_type') == ['AAAA', 'HTTPS', 'SVCB'] and rule.get('rcode') == 'NOERROR'
           for rule in enabled_rules)
assert not any(rule.get('server') == 'fakeip-dns' for rule in configs['draining']['dns']['rules'])
assert next(rule for rule in configs['ruleset']['dns']['rules'] if rule.get('server') == 'fakeip-dns')['rule_set'] == ['cfg-domains-rule']
for case in ['ipv6', 'range', 'matcher', 'changed_range', 'ttl_zero', 'ttl_high']:
    assert contents[case + '.error']
print('PASS: disabled, enabled, draining, runtime-state loss, Fake-IP without reverse mapping, domain/suffix/regex/ruleset matching, unrestricted sources,')
print('      runtime cache, rule ordering, nft syntax/ordering default/custom DNS reply TTL and six invalid configurations.')
