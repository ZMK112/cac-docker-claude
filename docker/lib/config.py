#!/usr/bin/env python3
"""CCImage config entry point.

Read PROXY_URI from environment, generate sing-box JSON to stdout.
"""

from __future__ import annotations

import os
import socket
import sys

from .protocols import parse
from .singbox import render_json


def split_csv(raw: str) -> list[str]:
    result: list[str] = []
    for item in raw.split(","):
        item = item.strip()
        if item:
            result.append(item)
    return result


def main() -> None:
    uri = os.environ.get("PROXY_URI", "").strip()
    if not uri:
        print("Error: PROXY_URI is required.", file=sys.stderr)
        sys.exit(1)

    proxy = parse(uri)
    if proxy.server and not proxy.server.replace(".", "").isdigit():
        try:
            proxy.server = socket.gethostbyname(proxy.server)
        except OSError:
            pass
    dns = os.environ.get("DNS_SERVER", "https://1.1.1.1/dns-query")
    direct_dns = os.environ.get("CAC_DIRECT_DNS_SERVER", "").strip() or dns
    direct_keywords = split_csv(os.environ.get("CAC_DIRECT_DOMAIN_KEYWORDS", "akamai-access.com,timeresearch,rockbund"))
    tun_addr = os.environ.get("TUN_ADDRESS", "172.19.0.1/30")
    tun_mtu = int(os.environ.get("TUN_MTU", "9000"))
    print(render_json(
        proxy,
        dns_server=dns,
        direct_dns_server=direct_dns,
        direct_domain_keywords=direct_keywords,
        tun_address=tun_addr,
        tun_mtu=tun_mtu,
    ))


if __name__ == "__main__":
    main()
