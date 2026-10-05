#!/bin/sh
# SSH_ASKPASS target for pull.sh — see entrypoint.sh for why the key is
# passphrase-protected with this same env var. Never invoked interactively:
# SSH_ASKPASS_REQUIRE=force in pull.sh makes ssh call this instead of
# prompting, so the passphrase never touches a log or a process list.
printf '%s' "${ZEROBYTE_TOKEN:-}"
