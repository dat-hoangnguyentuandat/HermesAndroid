#!/usr/bin/env python3
"""HermesAndroid — DoH proxy (stdlib only).

UDP DNS queries on 127.0.0.1:$DOH_PORT are forwarded to a DNS-over-HTTPS
upstream by IP literal (no local DNS needed). Paired with an iptables
OUTPUT redirect of port 53, this gives glibc getaddrinfo working DNS on
Android (where /etc/resolv.conf does not exist).
"""
import base64
import os
import socket
import sys
import threading
import urllib.request

PORT = int(os.environ.get('DOH_PORT', '5353'))
UPSTREAM = os.environ.get('DOH_UPSTREAM', 'https://8.8.8.8/dns-query')
TIMEOUT = 5


def handle(msg, addr, sock):
    try:
        b64 = base64.urlsafe_b64encode(msg).rstrip(b'=')
        req = urllib.request.Request(
            f"{UPSTREAM}?dns={b64.decode()}",
            headers={'accept': 'application/dns-message'},
        )
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            sock.sendto(r.read(), addr)
    except Exception as e:
        print(f"[doh] {addr[0]}: {e}", file=sys.stderr, flush=True)


def main():
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(('127.0.0.1', PORT))
    print(f"[doh] listening 127.0.0.1:{PORT} -> {UPSTREAM}", flush=True)
    while True:
        msg, addr = sock.recvfrom(4096)
        threading.Thread(target=handle, args=(msg, addr, sock), daemon=True).start()


if __name__ == '__main__':
    main()
