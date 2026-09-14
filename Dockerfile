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

FROM docker.io/searxng/searxng:2026.8.29-d226b78bc

COPY --from=tor /opt/tor /opt/tor
COPY container/torrc /opt/tor/torrc
COPY container/tor-keepalive.py /opt/tor/tor-keepalive.py

# The plain template: the fallback when Tor does not bootstrap (and the file the
# upstream entrypoint would seed from).
COPY --chown=977:977 container/railway.settings.yml /usr/local/searxng/settings.template.yml
COPY --chown=977:977 container/railway-tor.settings.yml /usr/local/searxng/railway-tor.settings.yml
COPY --chmod=755 container/railway-entrypoint.sh /usr/local/searxng/railway-entrypoint.sh

ENTRYPOINT ["/usr/local/searxng/railway-entrypoint.sh"]

EXPOSE 8080
