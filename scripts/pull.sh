#!/bin/sh
# Pre-backup hook target: rsync-pull one target's configured paths into its
# staging dir. $1 is ZeroByte's own sourcePath payload field (see hooks.yaml)
# — e.g. <staging>/web1, the Directory volume path set on that host's backup
# job — never a name typed into a URL. Re-derived and re-validated against
# targets.yaml here regardless: a malformed job config or a future
# non-webhook caller shouldn't be able to point rsync anywhere outside a
# listed target's own staging dir.
#
# Exits non-zero on failure. That's what makes ZeroByte's pre-backup webhook
# answer non-2xx and cancel the job before Restic ever touches a stale or
# partial copy.
set -eu

. /etc/webhook/scripts/common.sh

source_path="${1:-}"
targets_file="${TARGETS_FILE:-/etc/webhook/config/targets.yaml}"
staging="$(yq -r '.staging // "/staging"' "$targets_file")"

# Must be exactly <staging>/<name> — no traversal, no nested segments, no
# trailing-slash tricks. Reconstructing from basename and comparing back to
# the input catches all of those in one check.
name="$(basename -- "$source_path")"
if [ -z "$name" ] || [ "${staging}/${name}" != "$source_path" ]; then
  echo "pull.sh: rejected sourcePath '${source_path}' — expected ${staging}/<name>" >&2
  exit 1
fi

if ! yq -e ".targets[] | select(.name == \"${name}\")" "$targets_file" >/dev/null 2>&1; then
  echo "pull.sh: '${name}' is not a target in ${targets_file}" >&2
  exit 1
fi

host="$(yq -r ".targets[] | select(.name == \"${name}\") | .host" "$targets_file")"
user="$(yq -r ".targets[] | select(.name == \"${name}\") | .user" "$targets_file")"
confined="$(yq -r ".targets[] | select(.name == \"${name}\") | .confined // \"false\"" "$targets_file")"
unpack_tars="$(yq -r ".targets[] | select(.name == \"${name}\") | .unpack_tars // \"false\"" "$targets_file")"
folder_paths="$(yq -r ".targets[] | select(.name == \"${name}\") | .folder_path[]" "$targets_file")"

if [ -z "$host" ] || [ -z "$user" ] || [ -z "$folder_paths" ]; then
  echo "pull.sh: incomplete config for '${name}' in ${targets_file} (need host, user, folder_path)" >&2
  exit 1
fi

if printf '%s\n' "$folder_paths" | grep -q '^[^/]'; then
  echo "pull.sh: '${name}' has a folder_path entry that isn't an absolute path" >&2
  exit 1
fi

# Every entry lands at <staging>/<name>/<basename>/ — two entries with the
# same basename (e.g. /srv/a/data and /srv/b/data) would silently rsync
# into the same destination and mix their contents.
dupes="$(printf '%s\n' "$folder_paths" | while IFS= read -r fp; do [ -z "$fp" ] && continue; basename -- "$fp"; done | sort | uniq -d)"
if [ -n "$dupes" ]; then
  echo "pull.sh: '${name}' has folder_path entries with duplicate basenames — would collide in ${staging}/${name}/: ${dupes}" >&2
  exit 1
fi

mkdir -p "${staging}/${name}"

# `confined: true` derives the rrsync restriction as the longest shared
# parent of every listed folder (segment-aware — see common.sh) and sends
# each folder relative to it, matching whatever root got typed into that
# target's `rrsync -ro <root>` restriction at enrollment time. A single
# folder is its own root, offset "." (all of it). `confined: false` has no
# such chdir, so the full absolute path goes over the wire as-is.
if [ "$confined" = "true" ]; then
  root="$(printf '%s\n' "$folder_paths" | common_parent)"
  if [ "$root" = "/" ]; then
    echo "pull.sh: '${name}'s folder_path entries share no common parent below / — refusing (check targets.yaml)" >&2
    exit 1
  fi
fi

# rsync's --info=progress2 meter repaints in place with \r, not \n
# (confirmed locally: piped to a non-tty, it's still \r-separated, not one
# update per line) — captured raw, that's one run-on blob in `docker logs`
# instead of a readable trail. A plain `rsync ... | tr '\r' '\n'` pipe would
# fix the formatting but silently break the one thing pull.sh most needs:
# a pipeline's exit status is its last command's, so a failed rsync would
# report as tr's exit 0 and the pre-backup webhook would wave through a
# stale/partial copy. The fifo keeps rsync's own $? on the un-piped side of
# the redirect, so `tr` only ever touches the log formatting.
_run_rsync_logged() {
  fifo="$(mktemp -u)"
  mkfifo "$fifo"
  tr '\r' '\n' <"$fifo" | grep -v '^[[:space:]]*$' &
  tr_pid=$!
  set +e
  "$@" >"$fifo" 2>&1
  rc=$?
  set -e
  wait "$tr_pid" 2>/dev/null || true
  rm -f "$fifo"
  return "$rc"
}

echo "$folder_paths" | while IFS= read -r fp; do
  [ -z "$fp" ] && continue
  base="$(basename -- "$fp")"
  dest="${staging}/${name}/${base}"

  if [ "$confined" = "true" ]; then
    if [ "$fp" = "$root" ]; then
      rel=""
    else
      rel="${fp#$root/}/"
    fi
    remote="${user}@${host}:${rel}"
  else
    remote="${user}@${host}:${fp}/"
  fi

  mkdir -p "$dest"
  echo "pull.sh: ${name}/${base} <- ${remote}"
  # No --delete: a confined account's rrsync -ro implies -no-del and
  # hard-fails the whole transfer if asked for it, so staging accumulates
  # rather than mirrors deletions on the source — accepted trade-off,
  # documented in the README. Applied uniformly (even for unconfined
  # accounts) so behaviour doesn't change based on `confined`.
  #
  # The key at /config/id_ed25519 is passphrase-protected (see
  # entrypoint.sh); SSH_ASKPASS_REQUIRE=force makes ssh unlock it via
  # ssh-askpass.sh instead of trying to prompt on a tty that doesn't exist
  # here. No BatchMode=yes: that disables passphrase querying entirely,
  # which would also disable askpass. Host key trust is TOFU-per-connection
  # for v1 (no persisted known_hosts yet).
  # An env-prefix directly on a function call ("VAR=x func ...") is POSIX-
  # unspecified for whether VAR reaches the function's own children. dash,
  # bash and busybox ash all happen to export it today, but nothing
  # guarantees that; routing through `env` makes the export shell-
  # independent — ssh (and therefore the askpass unlock) sees it either way.
  _run_rsync_logged env SSH_ASKPASS=/etc/webhook/scripts/ssh-askpass.sh SSH_ASKPASS_REQUIRE=force rsync -a --info=progress2 \
    -e "setsid ssh -i /config/id_ed25519 -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=accept-new" \
    "$remote" "${dest}/"
done

# `unpack_tars: true` — the target publishes one tar per backed-up folder
# (made by root on the host, so owner-only files come along without a read
# grant on the live data) instead of the folders themselves. Each pulled
# <base>.tar is extracted to <staging>/<name>/<base>/, replacing whatever
# the last run left there, and then deleted — staging ends up holding plain
# files either way, so a single-file restore works the same. Runs as root in
# the container, so --same-owner/--numeric-owner put back the host's own
# uids and modes rather than whatever this container's passwd maps them to.
if [ "$unpack_tars" = "true" ]; then
  echo "$folder_paths" | while IFS= read -r fp; do
    [ -z "$fp" ] && continue
    pulled="${staging}/${name}/$(basename -- "$fp")"
    for tarball in "$pulled"/*.tar; do
      [ -f "$tarball" ] || continue
      base="$(basename -- "$tarball" .tar)"
      case "$base" in
        ''|.|..|.*) echo "pull.sh: skipping unexpected archive name '${tarball}'" >&2; continue ;;
      esac
      out="${staging}/${name}/${base}"
      if [ "$out" = "$pulled" ]; then
        echo "pull.sh: '${tarball}' would unpack over its own pull dir — rename it on the host" >&2
        exit 1
      fi
      echo "pull.sh: ${name}/${base} <- $(basename -- "$tarball")"
      rm -rf "$out"
      mkdir -p "$out"
      tar -x -p --same-owner --numeric-owner -f "$tarball" -C "$out"
      rm -f "$tarball"
    done
    rmdir "$pulled" 2>/dev/null || true
  done
fi

date -Iseconds > "${staging}/${name}/.last-sync"
