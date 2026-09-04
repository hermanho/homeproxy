#!/usr/bin/ucode
/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * Copyright (C) 2023 ImmortalWrt.org
 */

'use strict';

import { writefile } from 'fs';
import { cursor } from 'uci';

import {
	isEmpty, strToBool, strToInt, strToTime,
	removeBlankAttrs, HP_DIR, RUN_DIR
} from 'homeproxy';

/* UCI config start */
const uci = cursor();

const uciconfig = 'homeproxy';
uci.load(uciconfig);

const uciserver = 'server';

const log_level = uci.get(uciconfig, uciserver, 'log_level') || 'warn';
/* UCI config end */

const config = {};

function server_tls(cfg) {
	return (cfg.tls === '1') ? {
		enabled: true,
		server_name: cfg.tls_sni,
		certificate_path: cfg.tls_cert_path,
		key_path: cfg.tls_key_path
	} : null;
}

/* Log */
config.log = {
	disabled: false,
	level: log_level,
	output: RUN_DIR + '/sing-box-s.log',
	timestamp: true
};

config.inbounds = [];
config.services = [];
config.endpoints = [];

uci.foreach(uciconfig, uciserver, (cfg) => {
	if (cfg.enabled !== '1')
		return;

	if (cfg.type === 'hysteria-realm') {
		push(config.services, {
			type: 'hysteria-realm',
			listen: cfg.address || '::',
			listen_port: strToInt(cfg.port),
			tls: server_tls(cfg),
			users: (cfg.realm_token) ? [{
				name: cfg.realm_user || 'homeproxy',
				token: cfg.realm_token,
				max_realms: strToInt(cfg.realm_max_realms)
			}] : null
		});
		return;
	}
	if (cfg.type === 'openvpn-server') {
		push(config.endpoints, {
			type: 'openvpn-server',
			tag: 'cfg-' + cfg['.name'] + '-endpoint',
			listen: cfg.address || '::',
			listen_port: strToInt(cfg.port),
			system: false,
			name: cfg.label,
			mtu: strToInt(cfg.openvpn_mtu),
			mode: cfg.openvpn_mode,
			network: cfg.openvpn_network,
			max_clients: strToInt(cfg.openvpn_max_clients),
			address: cfg.openvpn_address,
			users: (cfg.username || cfg.password) ? [{ username: cfg.username, password: cfg.password }] : null,
			static_key_path: cfg.openvpn_static_key_path,
			tls: (cfg.openvpn_mode !== 'static_key') ? {
				certificate_path: cfg.tls_cert_path,
				key_path: cfg.tls_key_path,
				client_certificate_path: cfg.openvpn_client_certificate_path,
				verify_client_certificate: cfg.openvpn_verify_client_certificate || 'none'
			} : null,
			push: {
				dns_servers: cfg.openvpn_push_dns_servers,
				search_domains: cfg.openvpn_push_search_domains,
				redirect_gateway: strToBool(cfg.openvpn_push_redirect_gateway)
			}
		});
		return;
	}

	push(config.inbounds, {
		type: cfg.type,
		tag: 'cfg-' + cfg['.name'] + '-in',

		listen: cfg.address || '::',
		listen_port: strToInt(cfg.port),
		bind_interface: cfg.bind_interface,
		reuse_addr: strToBool(cfg.reuse_addr),
		tcp_fast_open: strToBool(cfg.tcp_fast_open),
		tcp_multi_path: strToBool(cfg.tcp_multi_path),
		udp_fragment: strToBool(cfg.udp_fragment),
		udp_timeout: strToTime(cfg.udp_timeout),
		network: cfg.network,

		/* AnyTLS */
		padding_scheme: cfg.anytls_padding_scheme,
		/* Snell */
		version: (cfg.type === 'snell') ? strToInt(cfg.snell_version) : null,
		psk: (cfg.type === 'snell') ? cfg.snell_psk : null,
		obfs_mode: (cfg.type === 'snell') ? cfg.snell_obfs_mode : null,
		mode: (cfg.type === 'snell') ? cfg.snell_mode : null,

		/* Hysteria */
		up_mbps: strToInt(cfg.hysteria_up_mbps),
		down_mbps: strToInt(cfg.hysteria_down_mbps),
		obfs: cfg.hysteria_obfs_type ? {
			type: cfg.hysteria_obfs_type,
			password: cfg.hysteria_obfs_password,
			min_packet_size: (cfg.hysteria_obfs_type === 'gecko') ? strToInt(cfg.hysteria_obfs_min_packet_size) : null,
			max_packet_size: (cfg.hysteria_obfs_type === 'gecko') ? strToInt(cfg.hysteria_obfs_max_packet_size) : null
		} : cfg.hysteria_obfs_password,
		recv_window_conn: strToInt(cfg.hysteria_recv_window_conn),
		recv_window_client: strToInt(cfg.hysteria_recv_window_client),
		max_conn_client: strToInt(cfg.hysteria_max_conn_client),
		disable_mtu_discovery: strToBool(cfg.hysteria_disable_mtu_discovery),
		ignore_client_bandwidth: strToBool(cfg.hysteria_ignore_client_bandwidth),
		masquerade: cfg.hysteria_masquerade,
		bbr_profile: (cfg.type === 'hysteria2') ? cfg.hysteria_bbr_profile : null,
		realm: (cfg.type === 'hysteria2' && cfg.hysteria_realm_enabled === '1') ? {
			server_url: cfg.hysteria_realm_server_url,
			token: cfg.hysteria_realm_token,
			realm_id: cfg.hysteria_realm_id,
			stun_servers: cfg.hysteria_realm_stun_servers,
			ip_version: strToInt(cfg.hysteria_realm_ip_version),
			port_mapping: (cfg.hysteria_realm_port_mapping === '1') ? {
				enabled: true,
				timeout: strToTime(cfg.hysteria_realm_port_mapping_timeout),
				lifetime: strToTime(cfg.hysteria_realm_port_mapping_lifetime)
			} : null
		} : null,

		/* Shadowsocks */
		method: (cfg.type === 'shadowsocks') ? cfg.shadowsocks_encrypt_method : null,
		password: (cfg.type in ['shadowsocks', 'shadowtls']) ? cfg.password : null,

		/* Tuic */
		congestion_control: cfg.tuic_congestion_control,
		auth_timeout: strToTime(cfg.tuic_auth_timeout),
		zero_rtt_handshake: strToBool(cfg.tuic_enable_zero_rtt),
		heartbeat: strToTime(cfg.tuic_heartbeat),

		/* AnyTLS / HTTP / Hysteria (2) / Mixed / Socks / Trojan / Tuic / VLESS / VMess */
		users: (cfg.type === 'snell' && cfg.snell_userkey) ? [{
			name: cfg.username || 'homeproxy',
			userkey: cfg.snell_userkey
		}] : ((cfg.type !== 'shadowsocks') ? [
			{
				name: !(cfg.type in ['http', 'mixed', 'naive', 'socks']) ? 'cfg-' + cfg['.name'] + '-server' : null,
				username: cfg.username,
				password: cfg.password,

				/* Hysteria */
				auth: (cfg.hysteria_auth_type === 'base64') ? cfg.hysteria_auth_payload : null,
				auth_str: (cfg.hysteria_auth_type === 'string') ? cfg.hysteria_auth_payload : null,

				/* Tuic */
				uuid: cfg.uuid,

				/* VLESS / VMess */
				flow: cfg.vless_flow,
				alterId: strToInt(cfg.vmess_alterid)
			}
		] : null),

		multiplex: (cfg.multiplex === '1') ? {
			enabled: true,
			padding: strToBool(cfg.multiplex_padding),
			brutal: (cfg.multiplex_brutal === '1') ? {
				enabled: true,
				up_mbps: strToInt(cfg.multiplex_brutal_up),
				down_mbps: strToInt(cfg.multiplex_brutal_down)
			} : null
		} : null,

		tls: (cfg.tls === '1') ? {
			enabled: true,
			server_name: cfg.tls_sni,
			alpn: cfg.tls_alpn,
			min_version: cfg.tls_min_version,
			max_version: cfg.tls_max_version,
			cipher_suites: cfg.tls_cipher_suites,
			certificate_path: cfg.tls_cert_path,
			key_path: cfg.tls_key_path,
			certificate_provider: (cfg.tls_acme === '1') ? {
				type: 'acme',
				domain: cfg.tls_acme_domain,
				data_directory: HP_DIR + '/certs',
				default_server_name: cfg.tls_acme_dsn,
				email: cfg.tls_acme_email,
				provider: cfg.tls_acme_provider,
				disable_http_challenge: strToBool(cfg.tls_acme_dhc),
				disable_tls_alpn_challenge: strToBool(cfg.tls_acme_dtac),
				alternative_http_port: strToInt(cfg.tls_acme_ahp),
				alternative_tls_port: strToInt(cfg.tls_acme_atp),
				external_account: (cfg.tls_acme_external_account === '1') ? {
					key_id: cfg.tls_acme_ea_keyid,
					mac_key: cfg.tls_acme_ea_mackey
				} : null,
				dns01_challenge: (cfg.tls_dns01_challenge === '1') ? {
					provider: cfg.tls_dns01_provider,
					access_key_id: cfg.tls_dns01_ali_akid,
					access_key_secret: cfg.tls_dns01_ali_aksec,
					region_id: cfg.tls_dns01_ali_rid,
					api_token: cfg.tls_dns01_cf_api_token
				} : null
			} : null,
			ech: (cfg.tls_ech_key) ? {
				enabled: true,
				key: split(cfg.tls_ech_key, '\n'),
				// config: split(cfg.tls_ech_config, '\n')
			} : null,
			reality: (cfg.tls_reality === '1') ? {
				enabled: true,
				private_key: cfg.tls_reality_private_key,
				short_id: cfg.tls_reality_short_id,
				max_time_difference: strToTime(cfg.tls_reality_max_time_difference),
				handshake: {
					server: cfg.tls_reality_server_addr,
					server_port: strToInt(cfg.tls_reality_server_port)
					}
			} : null
		} : null,

		transport: !isEmpty(cfg.transport) ? {
			type: cfg.transport,
			host: cfg.http_host || cfg.httpupgrade_host,
			path: cfg.http_path || cfg.ws_path,
			headers: cfg.ws_host ? {
				Host: cfg.ws_host
			} : null,
			method: cfg.http_method,
			max_early_data: strToInt(cfg.websocket_early_data),
			early_data_header_name: cfg.websocket_early_data_header,
			service_name: cfg.grpc_servicename,
			idle_timeout: strToTime(cfg.http_idle_timeout),
			ping_timeout: strToTime(cfg.http_ping_timeout)
		} : null
	});
});

if (length(config.inbounds) === 0 && length(config.services) === 0 && length(config.endpoints) === 0)
	exit(1);

if (length(config.services) === 0)
	config.services = null;
if (length(config.endpoints) === 0)
	config.endpoints = null;

system('mkdir -p ' + RUN_DIR);
writefile(RUN_DIR + '/sing-box-s.json', sprintf('%.J\n', removeBlankAttrs(config)));
