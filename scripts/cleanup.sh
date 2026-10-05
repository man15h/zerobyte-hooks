#!/bin/sh
# Post-backup hook target: remove one target's staged copy once Restic is
# done with it, so it never sits on disk between runs. $1 is the same
# sourcePath payload field pull.sh validates, re-validated here the same way
# — see pull.sh's comment for what that rejects and why.
#
# $2 is ZeroByte's own post-backup payload status field (wired in hooks.yaml
# from the request body, not from $1). Skips the clean unless the backup
# actually finished as success or warning — a failed or cancelled run means
# Restic never read this data, so deleting it then would throw away the one
# local copy for nothing.
set -eu

source_path="${1:-}"
status="${2:-}"
targets_file="${TARGETS_FILE:-/etc/webhook/config/targets.yaml}"
staging="$(yq -r '.staging // "/staging"' "$targets_file")"

name="$(basename -- "$source_path")"
if [ -z "$name" ] || [ "${staging}/${name}" != "$source_path" ]; then
  echo "cleanup.sh: rejected sourcePath '${source_path}' — expected ${staging}/<name>" >&2
  exit 1
fi

if ! yq -e ".targets[] | select(.name == \"${name}\")" "$targets_file" >/dev/null 2>&1; then
  echo "cleanup.sh: '${name}' is not a target in ${targets_file}" >&2
  exit 1
fi

case "$status" in
  success|warning) : ;;
  *)
    echo "cleanup.sh: skipping — backup status was '${status:-unknown}', not success/warning" >&2
    exit 0
    ;;
esac

rm -rf "${staging}/${name:?refusing to clean an empty path}"/*
