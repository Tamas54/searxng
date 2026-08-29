# Railway deployment target for this fork.
#
# Upstream ships a two-stage podman build (container/builder.dockerfile +
# container/dist.dockerfile); dist.dockerfile pulls from "localhost/...:builder",
# which Railway's builder cannot resolve. Without a Dockerfile, Railpack sees the
# root go.mod (the shfmt devtools module) and misdetects the repo as a Go project.
#
# This file gives Railway one buildable target: the official image plus our
# settings template. Pinned to the image built from this fork's base commit.
FROM docker.io/searxng/searxng:2026.8.29-d226b78bc

# entrypoint.sh seeds $__SEARXNG_CONFIG_PATH/settings.yml from this template on
# first boot and substitutes the "ultrasecretkey" placeholder.
COPY --chown=977:977 container/railway.settings.yml /usr/local/searxng/settings.template.yml

EXPOSE 8080
