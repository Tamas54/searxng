"""Keep the Tor circuits to the engines' onion services warm.

Measured 2026-09-14: the FIRST connection to an onion service (descriptor
lookup + rendezvous) takes ~40 s; SearXNG's engine timeout is 10+5 s, so a
cold onion engine times out, raises httpx.ProxyError and gets suspended.
Warm, the Brave Search onion answers in 1.6-4.3 s.

So: `--warm` blocks at boot until every onion answered once (or the budget
runs out — then SearXNG starts anyway, the engine just begins cold); the
default mode loops forever in the background and touches each onion every
KEEPALIVE_S seconds, well inside Tor's 10-minute circuit dirtiness.

Runs with the SearXNG venv's own httpx + httpx_socks — nothing extra installed.
"""
import os
import sys
import time

import httpx
from httpx_socks import SyncProxyTransport

# httpx_socks rejects the `socks5h://` scheme; remote DNS (mandatory for
# .onion names) is its `rdns=True` flag on a plain `socks5://` URL.
PROXY = os.environ.get("SEARXNG_TOR_SOCKS", "socks5://127.0.0.1:9050")
RETRY_PAUSE_S = 3.0
ONIONS = [u for u in os.environ.get(
    "SEARXNG_TOR_KEEPALIVE_URLS",
    "https://search.brave4u7jddbv7cyviptqjc7jusxh72uik7zt6adtckl5f4nwy2v72qd.onion/",
).split(",") if u.strip()]
KEEPALIVE_S = float(os.environ.get("SEARXNG_TOR_KEEPALIVE_S", "180"))
WARM_BUDGET_S = float(os.environ.get("SEARXNG_TOR_WARM_BUDGET_S", "75"))
UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:128.0) Gecko/20100101 Firefox/128.0"


def touch(url: str, timeout: float) -> tuple[bool, str]:
    t0 = time.monotonic()
    try:
        with httpx.Client(transport=SyncProxyTransport.from_url(PROXY, rdns=True),
                          timeout=timeout, headers={"User-Agent": UA},
                          follow_redirects=False) as c:
            r = c.get(url)
        return True, f"HTTP {r.status_code} in {time.monotonic() - t0:.1f}s"
    except Exception as exc:  # noqa: BLE001 — a keepalive must never crash
        return False, f"{type(exc).__name__} after {time.monotonic() - t0:.1f}s"


def warm() -> None:
    deadline = time.monotonic() + WARM_BUDGET_S
    for url in ONIONS:
        while True:
            left = deadline - time.monotonic()
            if left <= 1:
                print(f"[keepalive] {url[:40]}… NOT warm within budget", flush=True)
                break
            ok, detail = touch(url, timeout=min(60.0, left))
            print(f"[keepalive] warm {url[:40]}…: {detail}", flush=True)
            if ok:
                break
            time.sleep(RETRY_PAUSE_S)   # never spin: a failure can be instant


def loop() -> None:
    """Keepalive only. Supervising Tor is the entrypoint's job (one owner):
    it exits non-zero when Tor dies, so Railway restarts the container."""
    while True:
        time.sleep(KEEPALIVE_S)
        for url in ONIONS:
            ok, detail = touch(url, timeout=60.0)
            if not ok:
                print(f"[keepalive] {url[:40]}…: {detail}", flush=True)


if __name__ == "__main__":
    warm() if "--warm" in sys.argv else loop()
