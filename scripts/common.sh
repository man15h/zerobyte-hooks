# Shared by pull.sh and entrypoint.sh — not a hook target itself, not listed
# in hooks.yaml. One function: derive the confined-target rrsync root from a
# `folder_path` list.
#
# The derived root has to be exactly what gets typed into a target's
# authorized_keys `rrsync -ro <root>` restriction, so both the sidecar's
# printed enrollment block and pull.sh's own rsync invocation compute it the
# same way — this is the one place that logic lives.

# Longest shared parent of two absolute paths, segment-aware: /srv/app is not
# a parent of /srv/appdata, only of /srv/app and things under /srv/app/.
_common_parent_of_two() {
  a="$1"
  b="$2"
  while :; do
    case "$b" in
      "$a") printf '%s' "$a"; return ;;
      "$a"/*) printf '%s' "$a"; return ;;
    esac
    [ "$a" = "/" ] && { printf '/'; return; }
    a=$(dirname "$a")
  done
}

# Longest shared parent across a list of absolute paths, one per line on
# stdin. A single path is its own parent — the caller treats that as offset
# "." the same way a one-entry folder_path list always has.
common_parent() {
  acc=""
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    if [ -z "$acc" ]; then
      acc="$p"
    else
      acc=$(_common_parent_of_two "$acc" "$p")
    fi
  done
  printf '%s' "$acc"
}
