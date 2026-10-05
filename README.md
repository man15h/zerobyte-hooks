# zerobyte-hooks

Webhook sidecar that lets [ZeroByte](https://zerobyte.app) pull a remote
host's files over SSH/rsync before a backup runs, and clear the local copy
after. ZeroByte has no local shell-exec of its own — its pre/post-backup
"hooks" are plain HTTP calls that it makes and waits on. This image answers
those calls.

Config-driven: the image ships two fixed hooks and never bakes in a host
name. Add, remove or reconfigure a target by editing `targets.yaml` — no
rebuild, no new hook, no code change.

## How it works

Every ZeroByte backup job's Directory volume is a path under this
container's staging root (`/staging` by default — see `targets.yaml`
below), e.g. `/staging/web1`, and every job's pre/post-backup webhook
points at the same two URLs on this container: `/hooks/pull` and
`/hooks/cleanup`. ZeroByte's own webhook payload carries that same path
back as `sourcePath` (and, on post-backup, `status`) — see
[Zerobyte's webhook docs](https://zerobyte.app/docs/guides/backup-webhooks).

`scripts/pull.sh` and `scripts/cleanup.sh` take `sourcePath`, derive a
target name from it (the last path segment), and look that name up in
`targets.yaml`. A name that isn't in the config is rejected outright —
`sourcePath` comes straight from the incoming request body, so it's
re-validated here regardless of what else is guarding the webhook.

`pull.sh` rsyncs every folder listed for that target into
`<staging>/<name>/<basename-of-that-folder>/` over SSH — see below for what
that account needs to look like. `cleanup.sh` empties the staging dir once
ZeroByte reports the run as `success` or `warning`; a failed or cancelled
run leaves it alone; since a folder pull never mirrors deletions on the
source, staging accumulates rather than mirrors the source between runs (an
`unpack_tars` target is the exception — see below).

`pull.sh` runs rsync with `--info=progress2` so `docker logs` gets a
per-file percentage/rate/ETA trail instead of one line per folder. Two
things to expect from that: the webhook response buffers the whole run
(`include-command-output-in-response`), so the trail lands post-run, not
live; and at roughly one line/s, a multi-hour first sync turns into a few
thousand lines in that buffered response. Fine for the normal case, just
don't expect a live tail from the webhook call itself.

## targets.yaml

Expected at `/etc/webhook/config/targets.yaml` (override the path with the
`TARGETS_FILE` env var). Not shipped in the image — this is
deployment-specific data (addresses), so whoever runs the image supplies
it, the same way any other app's `.env` is supplied rather than baked in.

**Bind-mount the directory, not the file.** A tool that writes config by
replacing-then-renaming (Ansible's `template`, most editors' "safe save")
gives the new file a new inode; a single-file bind mount stays pinned to
the old one, so the container silently keeps reading the stale copy
forever — no error, no restart, no new targets. Mounting the containing
directory instead means the container follows the directory entry, so a
rename-replace shows up immediately. See "Deploying" below.

```yaml
staging: /staging          # local staging root; defaults to /staging if omitted

targets:
  - name: web1              # staging dir: <staging>/web1
    host: 192.0.2.10         # or a hostname — anything `ssh` will resolve
    user: zerobyte-ro
    folder_path: ["/srv/appdata", "/srv/compose"]  # absolute paths on that host
    confined: true             # this account is wrapped in `rrsync -ro <root>`

  - name: some-other-host
    host: 192.0.2.11
    user: alice
    folder_path: ["/home/alice/data"]
    # confined omitted — defaults to false: a plain, unrestricted ssh user
```

`folder_path` is a list of absolute paths on the remote host — every one of
them ends up under `<staging>/<name>/`, one subdirectory per folder, named
after that folder's own basename (so `/srv/appdata` and `/srv/compose` land
at `<staging>/<name>/appdata` and `<staging>/<name>/compose`). Two entries
that share a basename (e.g. `/srv/a/data` and `/srv/b/data`) are rejected
outright — both would land at the same staging subdirectory and silently mix
their contents. What actually gets sent to `rsync` depends on `confined`:

- **`confined: false`** (the default) — a plain SSH account with no
  restriction, so each `folder_path` entry is sent to `rsync` as-is.
- **`confined: true`** — the account is restricted with
  [`rrsync -ro <root>`](https://linux.die.net/man/1/rrsync) (or an
  equivalent wrapper), which already `chdir`s into `<root>` and refuses
  anything outside it. `<root>` isn't a separate field here — it's derived
  as the longest shared parent directory of every `folder_path` entry (a
  single entry is its own root), and each folder is sent relative to that
  derived root. `/srv/appdata` + `/srv/compose` derives a root of `/srv`;
  a single `/home/alice/data` entry derives a root of `/home/alice/data`
  itself.

  That derived root has to be exactly what got typed into `<root>` in the
  enrollment block when the target host was actually set up — a mismatch
  makes `rrsync` reject the pull outright (a loud failure, not a silent
  one). The sidecar removes this by hand-typing nothing: once a `confined:
  true` target is in `targets.yaml`, every start prints that host's
  enrollment block with its derived root and folder list already filled
  in — see "Enrolling a target host" below.

  A confined target's `folder_path` entries have to actually share a
  parent below `/` — if they don't (e.g. one entry under `/srv` and
  another under `/etc`), `pull.sh` refuses the pull rather than silently
  treating `/` as the restriction.

### `unpack_tars: true` — pull finished archives, not live folders

A read grant on live data (the ACL in "Enrolling a target host" below) has
two failure modes: it rewrites the ACL mask, so a 0600 file an app
mode-checks (a TLS store, an Erlang cookie) suddenly reads as 0640 and the
app refuses it; and it can't reach files an app keeps creating 0600, which
are usually the ones that matter most. `unpack_tars` avoids both by never
reading live data at all:

```yaml
  - name: web1
    host: 192.0.2.10
    user: zerobyte-ro
    folder_path: ["/srv/backup-export"]  # one tar per backed-up folder
    confined: true
    unpack_tars: true
```

Something on the target running as root writes one uncompressed
`<base>.tar` per folder into the listed directory (keep it uncompressed —
Restic already compresses and dedups, and a compressed archive changes
every byte per run). `pull.sh` rsyncs that directory as usual, then
extracts each `<base>.tar` to `<staging>/<name>/<base>/` with owners and
modes preserved, replacing the previous run's copy, and deletes the tar.
Staging ends up holding plain files, same as a folder pull, so a
single-file restore is unchanged. Deletions on the source do propagate
here, since each folder is rebuilt from its tar every run.

The account only ever needs read on that one export directory — no ACL on
anything else. Nothing here produces the tars: the target needs its own
root-owned export script, for example one run from `zerobyte-ro`'s forced
command before `rrsync` starts.

Nothing here assumes that setup — a `confined: false` entry works against any ordinary
SSH account with read access to its `folder_path` entries.

## The SSH key

The sidecar owns its own key — nothing external generates or supplies one.
On first start, if `/config/id_ed25519` doesn't exist yet, entrypoint.sh
generates an ed25519 keypair there, passphrase-protected with the value of
`ZEROBYTE_TOKEN`. That env var *is* the encryption: the file on disk is
useless without it, and it's required at every start (the container refuses
to start without it, even before a key exists to protect). Keep it the same
across restarts — the key on your persisted `/config` volume was encrypted
with whatever value was set the first time it was generated. Namespaced
with a `ZEROBYTE_` prefix specifically so it can't collide with an
unrelated secret of the same generic name in a shared env file.

The public key is never a secret. It's printed to `docker logs zerobyte-hooks`
on *every* start (not just the first), together with a ready-to-paste shell
block per already-configured `confined: true` target (except
`unpack_tars` ones, which need no ACL), plus one generic
block for a host not yet added to `targets.yaml` — copy the key and
whichever block applies to a target host.

## Enrolling a target host

No agent, daemon or extra process needed on the target — its sshd already
does the job, the same trust shape as Beszel's classic hub/agent mode: the
sidecar holds a private key, the target only ever receives the public half,
and nothing ever flows the other way.

1. Add an entry for the host to `targets.yaml` first (see schema above) —
   host, user, `folder_path`, `confined: true`. No restart needed:
   `pull.sh`/`cleanup.sh` read the file fresh on every hook call, as long
   as it's reached through a directory bind mount (see "Deploying" below);
   a single-file bind mount can miss the edit.
2. Restart the sidecar (or just re-read `docker logs zerobyte-hooks` if
   it's already been restarted since the edit) and copy the block now
   printed for that host — its derived root and every `folder_path` entry
   are already filled in, nothing to hand-type. A host not yet in
   `targets.yaml` gets the generic block instead, with `<root>` to edit by
   hand before pasting.
3. As root on the target, run the block. It installs `rsync`+`acl`,
   creates a locked-down `zerobyte-ro` user (`nologin`, no password), adds
   an `authorized_keys` line restricted to
   [`rrsync -ro <root>`](https://linux.die.net/man/1/rrsync) with no
   pty/agent/port/X11 forwarding, and grants `zerobyte-ro` a read-only ACL
   on each listed folder individually (`setfacl`, applied recursively and
   as a default so anything created under a folder later inherits it too)
   — never on the wider derived root, which would otherwise leak read
   access to everything else under it.

   That ACL only grants read access to the listed folders themselves —
   `zerobyte-ro` still needs plain `x` (traverse) on the derived root and
   every intermediate directory down to each folder, which this block
   doesn't grant. Parents at the usual `0755` need nothing extra; a `0700`
   home directory or similarly locked-down parent blocks the pull even
   though the leaf folder's ACL looks right, and fails loud (permission
   denied) rather than silently.

That's it — the target only ever trusted a public key, the account can't do
anything but read under one directory over rsync, and no credential for the
target ever exists on the sidecar's side or vice versa.

**v1 limitation, by design:** host key trust is TOFU-per-connection (no
persisted `known_hosts`), and there's no companion script — the block above
is copy-pasted by hand. An `enroll.sh` and pinned host keys are possible
follow-ups.

## Deploying

```yaml
services:
  zerobyte-hooks:
    image: ghcr.io/<owner>/zerobyte-hooks:<tag>
    environment:
      - ZEROBYTE_TOKEN=<pick one, then never change it>
    volumes:
      - ./zerobyte-config:/etc/webhook/config:ro    # dir holding targets.yaml
      - <key-volume>:/config                        # generated key lives here
      - <staging-volume>:/staging
```

Bind `./zerobyte-config` (a directory containing `targets.yaml`), not the
file directly — see "targets.yaml" above for why a single-file mount can
silently stop picking up edits. `<key-volume>` is a different mount and
must persist across restarts — it's where the generated key lives, and
it's the only thing here that's read-write and container-owned.

## Build and publish

Images are built only when a change lands on `main`. Pull requests don't
build, and there is no manual trigger. A merge that touches the
Dockerfile, `entrypoint.sh`, `hooks.yaml` or `scripts/` makes
`.github/workflows/build.yml` do three things:

1. Bump the patch version from the highest `vX.Y.Z` tag. The first
   release is `v0.1.0`.
2. Build on a native arm64 runner and push
   `ghcr.io/<owner>/zerobyte-hooks` as `<version>`, `latest` and
   `sha-<commit>`.
3. Push the `v<version>` git tag.

The built-in `GITHUB_TOKEN` does the push, so no secret is needed. The
image is `linux/arm64` only, because the Dockerfile downloads an arm64 yq
binary.

## Pinning a deployment

Pin a version and its digest rather than `:latest`. The workflow run's
job summary prints the full reference:

```
ghcr.io/<owner>/zerobyte-hooks:<version>@sha256:<digest>
```
