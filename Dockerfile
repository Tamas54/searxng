# Railway deployment target for this fork.
#
# Upstream ships a two-stage podman build (container/builder.dockerfile +
# container/dist.dockerfile); dist.dockerfile pulls from "localhost/...:builder",
# which Railway's builder cannot resolve. Without a Dockerfile, Railpack sees the
# root go.mod (the shfmt devtools module) and misdetects the repo as a Go project.
#
# This file gives Railway one buildable target: the official image plus our
# settings templates, and (2026-09-14) a Tor client for the engines' egress —
# from the Railway datacentre IP every web engine was blocked (see
# container/torrc). The official image is Void Linux without a package manager,
# so Tor comes from Debian trixie: same glibc (2.41), and we copy the binary with
# its non-glibc libraries only.

FROM debian:trixie-slim AS tor
RUN apt-get update \
 && apt-get install -y --no-install-recommends tor tor-geoipdb \
 && mkdir -p /opt/tor/bin /opt/tor/lib /opt/tor/share \
 && cp /usr/bin/tor /opt/tor/bin/ \
 && ldd /usr/bin/tor \
    | awk '/=> \// {print $3}' \
    | grep -Ev '/(libc|libm|libpthread|libdl|librt|ld-linux[^/]*)\.so' \
    | xargs -r -I{} cp -L {} /opt/tor/lib/ \
 && cp /usr/share/tor/geoip /usr/share/tor/geoip6 /opt/tor/share/ \
 && rm -rf /var/lib/apt/lists/*

FROM docker.io/searxng/searxng:2026.9.14-ef05645f0

COPY --from=tor /opt/tor /opt/tor
COPY container/torrc /opt/tor/torrc
COPY container/tor-keepalive.py /opt/tor/tor-keepalive.py

# Per-engine suspension cap for the Tor exit pool (fails the build if the
# pinned image's code no longer matches).
COPY container/patch_suspend_cap.py /tmp/patch_suspend_cap.py
RUN /usr/local/searxng/.venv/bin/python /tmp/patch_suspend_cap.py && rm /tmp/patch_suspend_cap.py

# Access key in front of SearXNG (container/echolot_guard.py; no enforcement
# while SEARXNG_ACCESS_KEY is empty). granian serves the guard instead of the
# bare app; the build fails if the upstream exec line changed.
COPY container/echolot_guard.py /usr/local/searxng/echolot_guard.py
RUN grep -qx 'exec /usr/local/searxng/.venv/bin/granian searx.webapp:app' /usr/local/searxng/entrypoint.sh \
 && sed -i 's|^exec /usr/local/searxng/.venv/bin/granian searx.webapp:app$|exec /usr/local/searxng/.venv/bin/granian echolot_guard:app|' /usr/local/searxng/entrypoint.sh \
 && grep -qx 'exec /usr/local/searxng/.venv/bin/granian echolot_guard:app' /usr/local/searxng/entrypoint.sh

# The plain template: the fallback when Tor does not bootstrap (and the file the
# upstream entrypoint would seed from).
COPY --chown=977:977 container/railway.settings.yml /usr/local/searxng/settings.template.yml
COPY --chown=977:977 container/railway-tor.settings.yml /usr/local/searxng/railway-tor.settings.yml
COPY --chmod=755 container/railway-entrypoint.sh /usr/local/searxng/railway-entrypoint.sh

# Concurrency (2026-09-15, measured on production): the image default
# GRANIAN_BLOCKING_THREADS=4 served 4 parallel searches in ~1.4 s and queued
# the next 4 to ~2.2 s — 20 concurrent readers would wait ~7 s, past the
# Echolot client's 5 s share. One worker (the engines' suspension state stays
# shared in one process), more threads: each search mostly waits on the
# network, not the CPU.
ENV GRANIAN_BLOCKING_THREADS=16

ENTRYPOINT ["/usr/local/searxng/railway-entrypoint.sh"]

EXPOSE 8080
