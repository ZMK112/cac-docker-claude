"""Generate sing-box JSON configuration from ProxyConfig + environment parameters."""

from __future__ import annotations

import json
from typing import Any
from urllib.parse import urlparse

from .protocols import ProxyConfig


def render(
    proxy: ProxyConfig,
    *,
    dns_server: str,
    direct_dns_server: str,
    direct_domain_keywords: list[str],
    tun_address: str,
    tun_mtu: int,
) -> dict[str, Any]:
    """Build a complete sing-box config dict."""
    return {
        "log": {"level": "warn"},
        "dns": _dns_section(dns_server, direct_dns_server, direct_domain_keywords),
        "inbounds": [_tun_inbound(tun_address, tun_mtu)],
        "outbounds": [_outbound(proxy), {"type": "direct", "tag": "direct"}],
        "route": _route_section(direct_domain_keywords),
    }


def render_json(proxy: ProxyConfig, **kwargs: Any) -> str:
    return json.dumps(render(proxy, **kwargs), indent=2)


def render_proxy_bridge(
    proxy: ProxyConfig,
    *,
    listen_address: str,
    listen_port: int,
    username: str,
    password: str,
    direct_dns_server: str = "127.0.0.11",
) -> dict[str, Any]:
    return {
        "log": {"level": "warn"},
        "dns": _bridge_dns_section(direct_dns_server),
        "inbounds": [
            {
                "type": "mixed",
                "tag": "mixed-in",
                "listen": listen_address,
                "listen_port": listen_port,
                "users": [{"username": username, "password": password}],
            }
        ],
        "outbounds": [_outbound(proxy), {"type": "direct", "tag": "direct"}],
        "route": {
            "rules": [
                {"ip_is_private": True, "outbound": "direct"},
            ],
            "final": "proxy",
            "auto_detect_interface": True,
        },
    }


def render_proxy_bridge_json(proxy: ProxyConfig, **kwargs: Any) -> str:
    return json.dumps(render_proxy_bridge(proxy, **kwargs), indent=2)


def _bridge_dns_section(direct_server: str) -> dict[str, Any]:
    return {
        "servers": [_dns_server("direct-dns", direct_server, "direct", legacy_https=True)],
        "final": "direct-dns",
        "strategy": "ipv4_only",
    }


def _dns_server(tag: str, server: str, detour: str | None, *, legacy_https: bool = False) -> dict[str, Any]:
    if legacy_https and server.startswith("https://"):
        item: dict[str, Any] = {"tag": tag, "address": server}
        if detour:
            item["detour"] = detour
        return item

    if server.startswith("https://"):
        parsed = urlparse(server)
        host = parsed.hostname or ""
        dns_server: dict[str, Any] = {
            "type": "https",
            "tag": tag,
            "server": host,
            "server_port": parsed.port or 443,
            "path": parsed.path or "/dns-query",
        }
        if detour:
            dns_server["detour"] = detour
        if host:
            dns_server["tls"] = {
                "enabled": True,
                "server_name": host if not host.replace(".", "").isdigit() else "cloudflare-dns.com",
            }
        return dns_server

    item: dict[str, Any] = {"tag": tag, "address": server}
    if detour:
        item["detour"] = detour
    return item


def _dns_section(server: str, direct_server: str, direct_domain_keywords: list[str]) -> dict:
    servers = [_dns_server("direct-dns", direct_server, "direct", legacy_https=True), _dns_server("remote-dns", server, "proxy")]
    dns: dict[str, Any] = {
        "servers": servers,
        "final": "remote-dns",
        "strategy": "ipv4_only",
    }
    if direct_domain_keywords:
        dns["rules"] = [
            {"domain_keyword": direct_domain_keywords, "server": "direct-dns"},
        ]
    return dns


def _tun_inbound(address: str, mtu: int) -> dict:
    return {
        "type": "tun",
        "tag": "tun-in",
        "interface_name": "tun0",
        "address": [address],
        "mtu": mtu,
        "auto_route": True,
        "strict_route": True,
        "stack": "system",
        "auto_redirect": True,
    }


def _route_section(direct_domain_keywords: list[str]) -> dict:
    rules: list[dict[str, Any]] = [
        {"action": "sniff"},
        {"protocol": "dns", "action": "hijack-dns"},
    ]
    if direct_domain_keywords:
        rules.append({"domain_keyword": direct_domain_keywords, "outbound": "direct"})
    rules.append({"ip_is_private": True, "outbound": "direct"})
    return {
        "rules": rules,
        "final": "proxy",
        "auto_detect_interface": True,
    }


def _apply_tls(out: dict, p: ProxyConfig) -> None:
    if p.tls:
        tls: dict[str, Any] = {"enabled": True}
        if p.sni:
            tls["server_name"] = p.sni
        out["tls"] = tls


def _is_ip_address(value: str) -> bool:
    return value.replace(".", "").isdigit() or ":" in value


def _apply_domain_resolver(out: dict, p: ProxyConfig) -> None:
    if p.server and not _is_ip_address(p.server):
        out["domain_resolver"] = "direct-dns"


_OUTBOUND_BUILDERS: dict[str, Any] = {}


def _outbound(proxy: ProxyConfig) -> dict:
    builder = _OUTBOUND_BUILDERS.get(proxy.type)
    if not builder:
        raise ValueError(f"Unsupported proxy type for sing-box: {proxy.type}")
    return builder(proxy)


def _outbound_socks5(p: ProxyConfig) -> dict:
    out: dict[str, Any] = {
        "type": "socks",
        "tag": "proxy",
        "server": p.server,
        "server_port": p.port,
        "version": "5",
    }
    if p.username:
        out["username"] = p.username
    if p.password:
        out["password"] = p.password
    _apply_domain_resolver(out, p)
    return out


def _outbound_shadowsocks(p: ProxyConfig) -> dict:
    out = {
        "type": "shadowsocks",
        "tag": "proxy",
        "server": p.server,
        "server_port": p.port,
        "method": p.method,
        "password": p.password,
    }
    _apply_domain_resolver(out, p)
    return out


def _outbound_http(p: ProxyConfig) -> dict:
    out: dict[str, Any] = {
        "type": "http",
        "tag": "proxy",
        "server": p.server,
        "server_port": p.port,
    }
    if p.username:
        out["username"] = p.username
    if p.password:
        out["password"] = p.password
    _apply_tls(out, p)
    _apply_domain_resolver(out, p)
    return out


def _outbound_vmess(p: ProxyConfig) -> dict:
    out: dict[str, Any] = {
        "type": "vmess",
        "tag": "proxy",
        "server": p.server,
        "server_port": p.port,
        "uuid": p.uuid,
        "alter_id": p.alter_id,
        "security": p.security or "auto",
    }
    _apply_tls(out, p)
    _apply_domain_resolver(out, p)
    return out


def _outbound_vless(p: ProxyConfig) -> dict:
    out: dict[str, Any] = {
        "type": "vless",
        "tag": "proxy",
        "server": p.server,
        "server_port": p.port,
        "uuid": p.uuid,
    }
    flow = p.extra.get("flow", "")
    if flow:
        out["flow"] = flow
    _apply_tls(out, p)
    _apply_domain_resolver(out, p)
    transport = p.extra.get("transport", "tcp")
    if transport and transport != "tcp":
        outbound_transport: dict[str, Any] = {"type": transport}
        if transport == "grpc":
            service_name = p.extra.get("service_name", "")
            if service_name:
                outbound_transport["service_name"] = service_name
        host = p.extra.get("host", "")
        if host and transport == "http":
            outbound_transport["host"] = [host]
        elif host and transport == "httpupgrade":
            outbound_transport["host"] = host
        out["transport"] = outbound_transport
    return out


def _outbound_trojan(p: ProxyConfig) -> dict:
    out: dict[str, Any] = {
        "type": "trojan",
        "tag": "proxy",
        "server": p.server,
        "server_port": p.port,
        "password": p.password,
    }
    _apply_tls(out, p)
    _apply_domain_resolver(out, p)
    return out


_OUTBOUND_BUILDERS.update({
    "socks5": _outbound_socks5,
    "http": _outbound_http,
    "shadowsocks": _outbound_shadowsocks,
    "vmess": _outbound_vmess,
    "vless": _outbound_vless,
    "trojan": _outbound_trojan,
})
