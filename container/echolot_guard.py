"""Access key in front of the SearXNG WSGI app (2026-09-15).

The Railway instance is public and runs with the bot limiter off (its clients
are our own services). Any stranger who finds the URL could burn the engines'
patience with our single egress IP — and every Echolot reader would pay.

`SEARXNG_ACCESS_KEY` (set by the Kommandant in the Railway variables):
  * empty / unset -> NO enforcement: behaviour is byte-identical to plain
    SearXNG, so this file can ship before the key exists;
  * set -> every request must carry the key, in one of three ways:
      - header  `X-Echolot-Key: <key>`   (Echolot, the Bridge)
      - cookie  `echolot_key=<key>`      (a browser, after the bootstrap below)
      - query   `?key=<key>`             (browser bootstrap: sets the cookie
                                          and redirects to the same URL WITHOUT
                                          the key, so it stays out of history)
    `/healthz` and `/static/...` stay open (Railway health check, the UI assets).
Comparison is constant-time (hmac.compare_digest).

granian serves `echolot_guard:app` instead of `searx.webapp:app` — the
Dockerfile patches the upstream entrypoint's exec line (and fails the build
if that line is not found verbatim).
"""
import hmac
import os
from http.cookies import SimpleCookie
from urllib.parse import parse_qsl, urlencode

from searx.webapp import app as searx_app

KEY = (os.environ.get("SEARXNG_ACCESS_KEY") or "").strip()
COOKIE = "echolot_key"
HEADER = "HTTP_X_ECHOLOT_KEY"
OPEN_PREFIXES = ("/static/",)
OPEN_PATHS = ("/healthz",)
MAX_AGE = 365 * 24 * 3600


def _ok(given: str) -> bool:
    return bool(given) and hmac.compare_digest(given.encode("utf-8"), KEY.encode("utf-8"))


def _cookie_key(environ) -> str:
    raw = environ.get("HTTP_COOKIE") or ""
    try:
        c = SimpleCookie()
        c.load(raw)
        return c[COOKIE].value if COOKIE in c else ""
    except Exception:  # noqa: BLE001 — a malformed cookie is simply no key
        return ""


def _forbidden(start_response):
    body = b"403 Forbidden: this search instance requires an access key.\n"
    start_response("403 Forbidden", [("Content-Type", "text/plain; charset=utf-8"),
                                     ("Content-Length", str(len(body))),
                                     ("Cache-Control", "no-store")])
    return [body]


def app(environ, start_response):
    if not KEY:
        return searx_app(environ, start_response)
    path = environ.get("PATH_INFO") or "/"
    if path in OPEN_PATHS or path.startswith(OPEN_PREFIXES):
        return searx_app(environ, start_response)
    if _ok(environ.get(HEADER, "")) or _ok(_cookie_key(environ)):
        return searx_app(environ, start_response)
    # browser bootstrap: ?key=... -> cookie + redirect without the key
    params = parse_qsl(environ.get("QUERY_STRING") or "", keep_blank_values=True)
    given = next((v for k, v in params if k == "key"), "")
    if _ok(given):
        rest = urlencode([(k, v) for k, v in params if k != "key"])
        target = (environ.get("SCRIPT_NAME") or "") + path + (f"?{rest}" if rest else "")
        https = (environ.get("HTTP_X_FORWARDED_PROTO") or environ.get("wsgi.url_scheme")) == "https"
        cookie = (f"{COOKIE}={KEY}; Max-Age={MAX_AGE}; Path=/; HttpOnly; SameSite=Lax"
                  + ("; Secure" if https else ""))
        start_response("303 See Other", [("Location", target), ("Set-Cookie", cookie),
                                         ("Cache-Control", "no-store"),
                                         ("Content-Length", "0")])
        return [b""]
    return _forbidden(start_response)
