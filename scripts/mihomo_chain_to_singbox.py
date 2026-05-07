#!/usr/bin/env python3
"""Convert a Mihomo proxy chain slice to sing-box TUN JSON.

This intentionally ignores Mihomo listeners. The generated sing-box config is
for container-wide TUN interception: all unmatched traffic falls through to the
selected chain policy. Optional DIRECT rules are restricted to explicit internal
CIDR/domain allowlists supplied by the caller.
"""

from __future__ import annotations

import argparse
import ipaddress
import json
import sys
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

try:
    import yaml
except ImportError:  # pragma: no cover - optional dependency
    yaml = None


DEFAULT_POLICY = "Claude-专用链路"
DEFAULT_INTERNAL_CIDRS = [
    "127.0.0.0/8",
    "169.254.0.0/16",
    "172.31.255.0/24",
]
DEFAULT_INTERNAL_DOMAINS = [
    "localhost",
    "host.docker.internal",
]


def load_yaml(path: Path) -> dict[str, Any]:
    if yaml is None:
        return load_mihomo_subset(path)
    with path.open("r", encoding="utf-8") as fh:
        data = yaml.safe_load(fh)
    if not isinstance(data, dict):
        raise SystemExit(f"{path} is not a YAML mapping")
    return data


def parse_scalar(raw: str) -> Any:
    value = raw.strip()
    if not value:
        return ""
    if value[0:1] in {"'", '"'} and value[-1:] == value[0]:
        return value[1:-1]
    lowered = value.lower()
    if lowered == "true":
        return True
    if lowered == "false":
        return False
    try:
        return int(value)
    except ValueError:
        return value


def load_mihomo_subset(path: Path) -> dict[str, Any]:
    """Parse the Mihomo subset needed by this converter without PyYAML."""
    data: dict[str, Any] = {"proxies": [], "proxy-groups": [], "rules": []}
    section = ""
    current: dict[str, Any] | None = None
    current_list_key = ""

    for raw_line in path.read_text(encoding="utf-8").splitlines():
        stripped = raw_line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        indent = len(raw_line) - len(raw_line.lstrip(" "))

        if not raw_line.startswith((" ", "-")):
            key = stripped.split(":", 1)[0]
            section = key if key in data else ""
            current = None
            current_list_key = ""
            continue

        if section in {"proxies", "proxy-groups"}:
            if indent >= 4 and stripped.startswith("-") and current is not None and current_list_key:
                current.setdefault(current_list_key, []).append(parse_scalar(stripped[1:].strip()))
                continue

            if stripped in {"-", "- "}:
                current = {}
                data[section].append(current)
                current_list_key = ""
                continue
            if stripped.startswith("- "):
                current = {}
                data[section].append(current)
                stripped = stripped[2:].strip()
                current_list_key = ""
                if not stripped:
                    continue
            if current is None:
                continue

            if ":" not in stripped:
                continue
            key, value = stripped.split(":", 1)
            key = key.strip()
            value = value.strip()
            if not value:
                current[key] = []
                current_list_key = key
            else:
                current[key] = parse_scalar(value)
                current_list_key = ""
            continue

        if section == "rules":
            if stripped.startswith("- "):
                data["rules"].append(stripped[2:].strip())

    if not data["proxies"] or not data["proxy-groups"]:
        raise SystemExit(f"{path} could not be parsed as a Mihomo proxy config")
    return data


def by_name(items: list[dict[str, Any]], section: str) -> dict[str, dict[str, Any]]:
    result: dict[str, dict[str, Any]] = {}
    for item in items or []:
        if not isinstance(item, dict):
            continue
        name = str(item.get("name", "")).strip()
        if not name:
            continue
        if name in result:
            raise SystemExit(f"duplicate {section} name: {name}")
        result[name] = item
    return result


def tls_from_proxy(proxy: dict[str, Any]) -> dict[str, Any]:
    tls: dict[str, Any] = {"enabled": True}
    sni = proxy.get("sni") or proxy.get("servername") or proxy.get("server")
    if sni:
        tls["server_name"] = str(sni)
    if bool(proxy.get("skip-cert-verify", False)):
        tls["insecure"] = True
    return tls


def proxy_to_outbound(proxy: dict[str, Any]) -> dict[str, Any]:
    typ = str(proxy.get("type", "")).lower()
    tag = str(proxy.get("name", "")).strip()
    server = str(proxy.get("server", "")).strip()
    port = int(proxy.get("port", 0) or 0)
    detour = proxy.get("dialer-proxy")

    if not tag:
        raise SystemExit("proxy without name")
    if not server or port <= 0:
        raise SystemExit(f"proxy {tag} has invalid server/port")

    if typ == "trojan":
        out: dict[str, Any] = {
            "type": "trojan",
            "tag": tag,
            "server": server,
            "server_port": port,
            "password": str(proxy.get("password", "")),
            "tls": tls_from_proxy(proxy),
        }
    elif typ in {"ss", "shadowsocks"}:
        out = {
            "type": "shadowsocks",
            "tag": tag,
            "server": server,
            "server_port": port,
            "method": str(proxy.get("cipher", proxy.get("method", ""))),
            "password": str(proxy.get("password", "")),
        }
    elif typ == "vmess":
        out = {
            "type": "vmess",
            "tag": tag,
            "server": server,
            "server_port": port,
            "uuid": str(proxy.get("uuid", "")),
            "alter_id": int(proxy.get("alterId", proxy.get("alter-id", 0)) or 0),
            "security": str(proxy.get("cipher", proxy.get("security", "auto")) or "auto"),
        }
        if proxy.get("tls"):
            out["tls"] = tls_from_proxy(proxy)
        network = str(proxy.get("network", "tcp") or "tcp").lower()
        if network and network != "tcp":
            out["transport"] = {"type": network}
    elif typ in {"socks", "socks5"}:
        out = {
            "type": "socks",
            "tag": tag,
            "server": server,
            "server_port": port,
            "version": "5",
        }
        if proxy.get("username"):
            out["username"] = str(proxy["username"])
        if proxy.get("password"):
            out["password"] = str(proxy["password"])
    elif typ in {"http", "https"}:
        out = {
            "type": "http",
            "tag": tag,
            "server": server,
            "server_port": port,
        }
        if proxy.get("username"):
            out["username"] = str(proxy["username"])
        if proxy.get("password"):
            out["password"] = str(proxy["password"])
        if typ == "https":
            out["tls"] = tls_from_proxy(proxy)
    else:
        raise SystemExit(f"unsupported proxy type for {tag}: {typ}")

    if detour:
        out["detour"] = str(detour)
    return out


def group_to_selector(group: dict[str, Any], reachable: set[str]) -> dict[str, Any]:
    tag = str(group.get("name", "")).strip()
    members = [str(x) for x in group.get("proxies", []) if str(x) in reachable]
    if not tag or not members:
        raise SystemExit(f"group {tag or '<unnamed>'} has no reachable proxy members")
    return {
        "type": "selector",
        "tag": tag,
        "outbounds": members,
        "default": members[0],
    }


def collect_reachable(
    tag: str,
    proxies: dict[str, dict[str, Any]],
    groups: dict[str, dict[str, Any]],
    seen: set[str] | None = None,
) -> list[str]:
    seen = seen or set()
    if tag in seen:
        return []
    if tag in {"DIRECT", "REJECT"}:
        raise SystemExit(f"policy chain contains bypass target: {tag}")
    seen.add(tag)

    ordered = [tag]
    if tag in groups:
        for member in groups[tag].get("proxies", []):
            member_tag = str(member)
            if member_tag in {"DIRECT", "REJECT"}:
                continue
            ordered.extend(collect_reachable(member_tag, proxies, groups, seen))
    elif tag in proxies:
        detour = proxies[tag].get("dialer-proxy")
        if detour:
            ordered.extend(collect_reachable(str(detour), proxies, groups, seen))
    else:
        raise SystemExit(f"policy/proxy referenced but not found: {tag}")
    return ordered


def describe_chain(
    policy: str,
    proxies: dict[str, dict[str, Any]],
    groups: dict[str, dict[str, Any]],
) -> dict[str, Any]:
    """Describe the effective single-path chain for operator-facing summaries."""
    selected = policy
    if policy in groups:
        members = [str(x) for x in groups[policy].get("proxies", []) if str(x) not in {"DIRECT", "REJECT"}]
        if members:
            selected = members[0]

    detours: list[str] = []
    cursor = selected
    seen: set[str] = set()
    while cursor in proxies and cursor not in seen:
        seen.add(cursor)
        detour = proxies[cursor].get("dialer-proxy")
        if not detour:
            break
        cursor = str(detour)
        detours.append(cursor)

    return {
        "selected_outbound": selected,
        "dial_first_hop": detours[-1] if detours else selected,
        "exit_outbound": selected,
        "logical_path": list(reversed(detours)) + [selected],
    }


def dns_section(server: str, final_policy: str) -> dict[str, Any]:
    if server.startswith("https://"):
        parsed = urlparse(server)
        host = parsed.hostname or ""
        remote: dict[str, Any] = {
            "type": "https",
            "tag": "remote-dns",
            "server": host,
            "server_port": parsed.port or 443,
            "path": parsed.path or "/dns-query",
            "detour": final_policy,
        }
        if host:
            remote["tls"] = {
                "enabled": True,
                "server_name": host if not host.replace(".", "").isdigit() else "cloudflare-dns.com",
            }
        return {"servers": [remote], "final": "remote-dns", "strategy": "ipv4_only"}

    return {
        "servers": [{"tag": "remote-dns", "address": server, "detour": final_policy}],
        "final": "remote-dns",
        "strategy": "ipv4_only",
    }


def tun_inbound(address: str, mtu: int) -> dict[str, Any]:
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


def mixed_inbound(listen: str, port: int, username: str, password: str) -> dict[str, Any]:
    inbound: dict[str, Any] = {
        "type": "mixed",
        "tag": "mixed-in",
        "listen": listen,
        "listen_port": port,
    }
    if username or password:
        inbound["users"] = [{"username": username, "password": password}]
    return inbound


def convert_rule(line: str, policy: str) -> dict[str, Any] | None:
    raw = line.strip()
    if not raw or raw.startswith("#"):
        return None
    parts = [part.strip() for part in raw.split(",")]
    if len(parts) < 2 or parts[-1] != policy:
        return None

    kind = parts[0].upper()
    value = ",".join(parts[1:-1]).strip()
    rule: dict[str, Any] = {"outbound": policy}
    if kind == "DOMAIN":
        rule["domain"] = [value]
    elif kind == "DOMAIN-SUFFIX":
        rule["domain_suffix"] = [value.lstrip(".")]
    elif kind == "DOMAIN-KEYWORD":
        rule["domain_keyword"] = [value]
    elif kind in {"IP-CIDR", "IP-CIDR6"}:
        rule["ip_cidr"] = [value]
    elif kind == "GEOIP":
        rule["geoip"] = [value.lower()]
    elif kind == "GEOSITE":
        rule["geosite"] = [value]
    else:
        return None
    return rule


def build_config(
    data: dict[str, Any],
    *,
    policy: str,
    dns_server: str,
    tun_address: str,
    tun_mtu: int,
    internal_cidrs: list[str],
    internal_domains: list[str],
    inbound_mode: str,
    listen: str,
    listen_port: int,
    listen_user: str,
    listen_password: str,
) -> tuple[dict[str, Any], dict[str, Any]]:
    proxies = by_name(data.get("proxies") or [], "proxy")
    groups = by_name(data.get("proxy-groups") or [], "proxy group")
    reachable_chain = collect_reachable(policy, proxies, groups)
    chain_description = describe_chain(policy, proxies, groups)
    reachable = set(reachable_chain)

    outbounds: list[dict[str, Any]] = []
    for tag in reachable_chain:
        if tag in groups:
            outbounds.append(group_to_selector(groups[tag], reachable))
        elif tag in proxies:
            outbounds.append(proxy_to_outbound(proxies[tag]))
    outbounds.append({"type": "direct", "tag": "internal-direct"})

    rules = []
    internal_rules = []
    if internal_cidrs:
        internal_rules.append({"ip_cidr": internal_cidrs, "outbound": "internal-direct"})
    if internal_domains:
        internal_rules.append({"domain": internal_domains, "outbound": "internal-direct"})

    ignored_direct = 0
    ignored_other = 0
    for raw_rule in data.get("rules") or []:
        text = str(raw_rule).strip()
        if not text:
            continue
        target = text.split(",")[-1].strip()
        if target == policy:
            rule = convert_rule(text, policy)
            if rule:
                rules.append(rule)
        elif target == "DIRECT":
            ignored_direct += 1
        else:
            ignored_other += 1

    if inbound_mode == "tun":
        inbounds = [tun_inbound(tun_address, tun_mtu)]
        inbound_summary = "tun0"
    elif inbound_mode == "mixed":
        inbounds = [mixed_inbound(listen, listen_port, listen_user, listen_password)]
        inbound_summary = f"mixed://{listen}:{listen_port}"
    else:
        raise SystemExit(f"unsupported inbound mode: {inbound_mode}")

    config = {
        "log": {"level": "info", "timestamp": True},
        "dns": dns_section(dns_server, policy),
        "inbounds": inbounds,
        "outbounds": outbounds,
        "route": {
            "rules": [{"action": "sniff"}, {"protocol": "dns", "action": "hijack-dns"}] + internal_rules + rules,
            "final": policy,
            "auto_detect_interface": True,
        },
    }
    summary = {
        "policy": policy,
        "reachable_chain": reachable_chain,
        "dial_first_hop": chain_description["dial_first_hop"],
        "exit_outbound": chain_description["exit_outbound"],
        "logical_path": chain_description["logical_path"],
        "converted_policy_rules": len(rules),
        "ignored_direct_rules": ignored_direct,
        "ignored_other_rules": ignored_other,
        "internal_direct_cidrs": internal_cidrs,
        "internal_direct_domains": internal_domains,
        "route_final": policy,
        "inbound": inbound_summary,
    }
    return config, summary


def verify_no_bypass(config: dict[str, Any], summary: dict[str, Any]) -> None:
    policy = summary["policy"]
    if config.get("route", {}).get("final") != policy:
        raise SystemExit("route.final is not the chain policy")

    for rule in config.get("route", {}).get("rules", []):
        outbound = rule.get("outbound")
        if outbound is None:
            continue
        if outbound == policy:
            continue
        if outbound == "internal-direct":
            if not any(key in rule for key in ("ip_cidr", "domain")):
                raise SystemExit(f"internal-direct rule is too broad: {rule}")
            continue
        raise SystemExit(f"route rule bypasses chain policy: {outbound}")

    outbounds = {item.get("tag"): item for item in config.get("outbounds", [])}
    for tag in summary["reachable_chain"]:
        if tag not in outbounds:
            raise SystemExit(f"missing outbound in chain: {tag}")

    if not any(item.get("detour") for item in config.get("outbounds", [])):
        raise SystemExit("no dialer-proxy/detour chain was generated")

    for item in config.get("outbounds", []):
        if item.get("type") == "direct" and item.get("tag") != "internal-direct":
            raise SystemExit(f"unexpected direct outbound tag: {item.get('tag')}")


def split_csv(values: list[str]) -> list[str]:
    result: list[str] = []
    for value in values:
        for item in value.split(","):
            item = item.strip()
            if item:
                result.append(item)
    return result


def validate_internal_cidrs(cidrs: list[str]) -> None:
    for cidr in cidrs:
        try:
            network = ipaddress.ip_network(cidr, strict=False)
        except ValueError as exc:
            raise SystemExit(f"invalid internal CIDR: {cidr}") from exc
        if not (network.is_private or network.is_loopback or network.is_link_local):
            raise SystemExit(f"refusing non-internal direct CIDR: {cidr}")


def validate_internal_domains(domains: list[str]) -> None:
    for domain in domains:
        normalized = domain.rstrip(".").lower()
        allowed = (
            normalized == "localhost"
            or normalized == "host.docker.internal"
            or "." not in normalized
            or normalized.endswith(".localhost")
            or normalized.endswith(".local")
            or normalized.endswith(".internal")
            or normalized.endswith(".docker.internal")
        )
        if not allowed:
            raise SystemExit(f"refusing non-internal direct domain: {domain}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path, help="Mihomo YAML input")
    parser.add_argument("-o", "--output", type=Path, help="sing-box JSON output")
    parser.add_argument("--policy", default=DEFAULT_POLICY, help="Mihomo policy/group to use as route.final")
    parser.add_argument("--dns-server", default="https://1.1.1.1/dns-query")
    parser.add_argument("--inbound-mode", choices=("tun", "mixed"), default="tun")
    parser.add_argument("--tun-address", default="172.19.0.1/30")
    parser.add_argument("--tun-mtu", type=int, default=9000)
    parser.add_argument("--listen", default="0.0.0.0")
    parser.add_argument("--listen-port", type=int, default=17891)
    parser.add_argument("--listen-user", default="")
    parser.add_argument("--listen-password", default="")
    parser.add_argument(
        "--internal-cidr",
        action="append",
        default=[],
        help="CIDR allowed to use internal-direct. Can be repeated or comma-separated.",
    )
    parser.add_argument(
        "--internal-domain",
        action="append",
        default=[],
        help="Exact domain allowed to use internal-direct. Can be repeated or comma-separated.",
    )
    parser.add_argument(
        "--no-default-internal",
        action="store_true",
        help="do not include the conservative default internal allowlist",
    )
    parser.add_argument("--summary", action="store_true", help="print a redacted summary to stderr")
    parser.add_argument("--verify-no-bypass", action="store_true")
    args = parser.parse_args()

    data = load_yaml(args.input)
    internal_cidrs = split_csv(args.internal_cidr)
    internal_domains = split_csv(args.internal_domain)
    if not args.no_default_internal:
        internal_cidrs = DEFAULT_INTERNAL_CIDRS + internal_cidrs
        internal_domains = DEFAULT_INTERNAL_DOMAINS + internal_domains
    validate_internal_cidrs(internal_cidrs)
    validate_internal_domains(internal_domains)
    config, summary = build_config(
        data,
        policy=args.policy,
        dns_server=args.dns_server,
        tun_address=args.tun_address,
        tun_mtu=args.tun_mtu,
        internal_cidrs=internal_cidrs,
        internal_domains=internal_domains,
        inbound_mode=args.inbound_mode,
        listen=args.listen,
        listen_port=args.listen_port,
        listen_user=args.listen_user,
        listen_password=args.listen_password,
    )
    if args.verify_no_bypass:
        verify_no_bypass(config, summary)

    rendered = json.dumps(config, ensure_ascii=False, indent=2)
    if args.output:
        args.output.write_text(rendered + "\n", encoding="utf-8")
    else:
        print(rendered)

    if args.summary:
        print(json.dumps(summary, ensure_ascii=False, indent=2), file=sys.stderr)


if __name__ == "__main__":
    main()
