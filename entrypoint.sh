#!/bin/sh
# Runs before /usr/local/bin/webhook starts (see Dockerfile — tini stays
# PID 1, this just runs in between). Owns the sidecar's own SSH identity so
# no private key is ever generated, copied or held anywhere outside this
# container's own /config volume.
#
# The key is passphrase-protected with ZEROBYTE_TOKEN. That's the
# "encrypted using an env variable" ask: the passphrase is the env value,
# not a separate encryption step, so the file on disk is useless without
# it. scripts/pull.sh decrypts with the same env var at hook time via
# SSH_ASKPASS (see scripts/ssh-askpass.sh) rather than an ssh-agent, so the
# decrypted key never sits in memory between hook calls. Named with a
# zerobyte-hooks-specific prefix, not a generic TOKEN, so it can't collide
# with an unrelated secret of the same generic name in a shared env file on
# the same host.
set -eu

. /etc/webhook/scripts/common.sh

key_path="/config/id_ed25519"
passphrase="${ZEROBYTE_TOKEN:-}"

if [ -z "$passphrase" ]; then
  echo "entrypoint: ZEROBYTE_TOKEN is required — it becomes the passphrase on the key generated below, and pull.sh needs the same value at hook time to unlock it" >&2
  exit 1
fi

if [ ! -f "$key_path" ]; then
  ssh-keygen -t ed25519 -N "$passphrase" -C "zerobyte-hooks" -f "$key_path"
fi
chmod 600 "$key_path"

pubkey="$(cat "${key_path}.pub")"

echo "=== zerobyte-hooks public key ==="
echo "$pubkey"
echo

# One filled-in block per target already in targets.yaml with confined:
# true — derived rrsync root and folder list substituted in, nothing left
# to hand-type or get wrong (that mismatch would otherwise fail rrsync at
# pull time). confined: false targets use an account set up outside this
# flow, so there's nothing to print for them. Wrapped in a subshell so a
# malformed targets.yaml can't take the whole container down — worst case
# is falling back to the generic block below.
targets_file="${TARGETS_FILE:-/etc/webhook/config/targets.yaml}"
if [ -f "$targets_file" ]; then
  (
    set -eu
    names="$(yq -r '.targets[].name' "$targets_file")"
    printf '%s\n' "$names" | while IFS= read -r tname; do
      [ -z "$tname" ] && continue
      tconfined="$(yq -r ".targets[] | select(.name == \"${tname}\") | .confined // \"false\"" "$targets_file")"
      [ "$tconfined" = "true" ] || continue
      # An unpack_tars target reads only the host's own export directory,
      # never live data — the setfacl grant below is exactly what that
      # design avoids, so its setup lives with whatever produces the tars.
      tunpack="$(yq -r ".targets[] | select(.name == \"${tname}\") | .unpack_tars // \"false\"" "$targets_file")"
      if [ "$tunpack" = "true" ]; then
        echo "=== ${tname}: unpack_tars target — enroll with the host's own export setup (see README), not a setfacl block ==="
        continue
      fi

      thost="$(yq -r ".targets[] | select(.name == \"${tname}\") | .host" "$targets_file")"
      tfolders="$(yq -r ".targets[] | select(.name == \"${tname}\") | .folder_path[]" "$targets_file")"
      [ -z "$tfolders" ] && continue

      troot="$(printf '%s\n' "$tfolders" | common_parent)"
      if [ "$troot" = "/" ]; then
        echo "entrypoint: skipping ${tname}'s enrollment block — its folder_path entries share no common parent below / (check targets.yaml)" >&2
        continue
      fi

      echo "=== Run as root on ${tname} (${thost}) to grant read-only access ==="
      echo "apt-get update -qq && apt-get install -y -qq rsync acl"
      echo "groupadd -f zerobyte-ro"
      echo "id -u zerobyte-ro >/dev/null 2>&1 || useradd -g zerobyte-ro -s /usr/sbin/nologin -m -d /home/zerobyte-ro zerobyte-ro"
      echo "passwd -l zerobyte-ro"
      echo "install -d -m 0700 -o zerobyte-ro -g zerobyte-ro /home/zerobyte-ro/.ssh"
      echo "echo 'command=\"/usr/bin/rrsync -ro ${troot}\",no-pty,no-agent-forwarding,no-port-forwarding,no-X11-forwarding,no-user-rc ${pubkey}' > /home/zerobyte-ro/.ssh/authorized_keys"
      echo "chmod 600 /home/zerobyte-ro/.ssh/authorized_keys"
      echo "chown zerobyte-ro:zerobyte-ro /home/zerobyte-ro/.ssh/authorized_keys"
      # One setfacl pair per listed folder, never on the derived root above:
      # rrsync's -ro <root> is only the SSH-level path fence, the ACL below
      # is the actual read grant. Granting it on the wider derived root
      # would silently expose everything else under that root too.
      printf '%s\n' "$tfolders" | while IFS= read -r f; do
        [ -z "$f" ] && continue
        echo "setfacl -R -m u:zerobyte-ro:rX ${f}"
        echo "setfacl -R -d -m u:zerobyte-ro:rX ${f}"
      done
      echo "==========================================================================="
    done
  ) || echo "entrypoint: warning — couldn't generate per-host enrollment blocks from ${targets_file} (check its YAML); the generic block below still works" >&2
fi

# Generic block for a host not yet in targets.yaml — v1 has no enroll
# script yet, so <root> is the one thing to edit by
# hand before pasting. Printed every start, not just the first, so
# `docker logs` alone is always enough to (re-)enroll a host.
cat <<EOF
=== Run as root on a target host not yet in targets.yaml (edit <root> first) ===
apt-get update -qq && apt-get install -y -qq rsync acl
groupadd -f zerobyte-ro
id -u zerobyte-ro >/dev/null 2>&1 || useradd -g zerobyte-ro -s /usr/sbin/nologin -m -d /home/zerobyte-ro zerobyte-ro
passwd -l zerobyte-ro
install -d -m 0700 -o zerobyte-ro -g zerobyte-ro /home/zerobyte-ro/.ssh
echo 'command="/usr/bin/rrsync -ro <root>",no-pty,no-agent-forwarding,no-port-forwarding,no-X11-forwarding,no-user-rc ${pubkey}' > /home/zerobyte-ro/.ssh/authorized_keys
chmod 600 /home/zerobyte-ro/.ssh/authorized_keys
chown zerobyte-ro:zerobyte-ro /home/zerobyte-ro/.ssh/authorized_keys
setfacl -R -m u:zerobyte-ro:rX <root>
setfacl -R -d -m u:zerobyte-ro:rX <root>
===========================================================================
EOF

exec /usr/local/bin/webhook "$@"
