# Adds rsync, an SSH client, GNU tar and yq on top of the upstream webhook image —
# none ship in it (alpine:3.22.2 base, apk add curl/jq/tini/tzdata only).
# rsync/ssh reach a target's zerobyte-ro account; GNU tar unpacks an
# `unpack_tars` target's archives with owners intact (busybox tar's option
# set differs, so pull.sh doesn't rely on it); yq is how pull.sh and
# cleanup.sh read targets.yaml (see hooks.yaml and scripts/ for why the
# host list lives there and not in this image).
#
# hooks.yaml and scripts/ are generic — no host names or addresses in
# either — so they're baked into the image here rather than bind-mounted.
# Only targets.yaml (which hosts, which paths — deployment-specific) is
# supplied by whoever runs this image. The SSH private key is never
# supplied at all: entrypoint.sh generates it into the persisted /config
# volume on first start (see entrypoint.sh, README).
#
# Built and pushed to GHCR by .github/workflows/build.yml on a native arm64
# runner.
FROM ghcr.io/thecatlady/webhook:2.8.2@sha256:0507d6c27d87837bcdee5078d63f54e50d9073ae879618233858e3da68d4b0cc
RUN apk add --no-cache rsync openssh-client tar

# yq (mikefarah/yq, Go binary) — fetched and checksum-pinned rather than
# apk add. arm64 only: this image is built and deployed for arm64.
ARG YQ_VERSION=v4.44.3
ARG YQ_SHA256=0e7e1524f68d91b3ff9b089872d185940ab0fa020a5a9052046ef10547023156
RUN wget -qO /usr/local/bin/yq "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_arm64" \
 && echo "${YQ_SHA256}  /usr/local/bin/yq" | sha256sum -c - \
 && chmod +x /usr/local/bin/yq

COPY hooks.yaml /etc/webhook/hooks.yaml
COPY scripts/ /etc/webhook/scripts/
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Upstream's own ENTRYPOINT is `tini -- webhook`; entrypoint.sh sits between
# the two without displacing tini as PID 1 (proper signal forwarding/zombie
# reaping — confirmed via the upstream image config, not assumed), and
# `exec`s webhook itself once key setup is done. WorkingDir stays /config,
# already upstream's own convention — the same path entrypoint.sh writes
# the generated key into, so no new volume convention is being invented.
ENTRYPOINT ["/sbin/tini", "--", "/entrypoint.sh"]
CMD ["-hooks=/etc/webhook/hooks.yaml", "-verbose", "-port=9000"]
