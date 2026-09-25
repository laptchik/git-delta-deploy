# git-delta-deploy

`git-delta-deploy` is a small Bash utility that deploys the current Git
worktree's file delta onto an **existing target tree** over SSH. The target must
already represent a compatible baseline.

This is not a full repository synchronization or bootstrap tool. It does not
reconstruct unchanged repository files. If a repository contains 500 files and
only 2 are currently changed, deployment sends those 2 changed paths plus any
applicable deletions, not all 500 files.

By default the tool selects staged and unstaged paths already known to Git,
including staged additions and tracked deletions. It neither updates Git refs
nor contacts a remote during selection.

This repository was extracted from a proven deployment helper. It deliberately
remains a Bash utility with no packaging or installation framework.

## Installation

For a normal user installation, install both commands into `~/.local/bin`:

```bash
./install.sh "$HOME/.local/bin"
```

If that directory is not already on your `PATH`, add it using your shell's
normal startup configuration. Once it is on `PATH`, the command name is
available normally and discoverable with shell command-name completion.

For a system installation:

```bash
sudo ./install.sh /usr/local/bin
```

Running `./install.sh` with no argument also defaults to `$HOME/.local/bin`.
The command operates on the Git worktree containing the current directory, not
on the repository from which the executable was installed.

## Usage

Run the executable from anywhere inside the worktree whose delta you want to
deploy:

```bash
git-delta-deploy [options] first-hop.example /absolute/target/dir
```

### Direct deployment

```text
local Git worktree
    |
    | ssh/scp
    v
target host
```

The remote host does not need `git-delta-deploy` installed and the target does
not need to be a Git repository. It needs an SSH server plus Bash and the
target-side commands used by the apply script: GNU-compatible `tar`, `realpath`,
`readlink`, `base64`, `sha256sum`, `sort`, `mktemp`, and standard file utilities.

Deploy the current staged and unstaged tracked changes, including tracked
deletions and staged additions:

```bash
git-delta-deploy deploy@example.net /srv/my-application
```

Include non-ignored untracked files as well:

```bash
git-delta-deploy --include-untracked deploy@example.net /srv/my-application
```

### Second-hop deployment

```text
local Git worktree
    |
    v
first-hop host
    |
    v
second-hop target
```

Use `--via-target USER@HOST` to name the second-hop target and `--via-port PORT`
when its SSH server does not use port 22. The first-hop host runs the nested
`ssh` and `scp` commands; it does not need `git-delta-deploy` installed.

Generic second-hop deployment with normal SSH authentication:

```bash
git-delta-deploy \
  --via-target deploy@internal.example \
  --via-port 2222 \
  jump@example.net \
  /srv/my-application
```

Both hops use normal SSH authentication and configuration by default, including
host-key checking. An SSH-accessible container on the first-hop host uses this
same second-hop path; there is no separate container transport:

```bash
git-delta-deploy \
  --via-target root@localhost \
  --via-port 2222 \
  remote-host.example \
  /opt/application
```

Use `--via-accept-new-host-key` to explicitly opt in to passing OpenSSH's
`StrictHostKeyChecking=accept-new` to second-hop `ssh` and `scp` only. The flag
requires `--via-target`. It allows previously unseen second-hop host keys to be
accepted and stored automatically, while changed known host keys are still
rejected; it does not disable host-key verification. Without the flag, normal
SSH host-key checking remains unchanged.

```bash
git-delta-deploy \
  --via-target root@localhost \
  --via-port 2222 \
  --via-accept-new-host-key \
  remote-host.example \
  /opt/application
```

When that container's nested SSH server uses a password, pass it directly:

```bash
git-delta-deploy \
  --via-target root@localhost \
  --via-port 2222 \
  --container-password root \
  remote-host.example \
  /opt/application
```

`--container-password` requires `--via-target`. It is used only by the nested
SSH and SCP commands on the first-hop host. It does not affect authentication
to `remote-host.example`; there is no CLI password option for the first hop.
The password is intentionally present in the local command's argv, so use the
hidden-prompt launcher instead when that distinction matters:

```bash
git-delta-deploy-via-password \
  --via-target root@localhost \
  --via-port 2222 \
  remote-host.example \
  /opt/application
```

The launcher prompts for `Second-hop SSH password:` with hidden input. It sets
`GIT_DELTA_DEPLOY_PASSWORD` only for the launched deployment and forwards all
arguments to `git-delta-deploy` unchanged. The password is sent to the first-hop
driver through SSH input and is never placed in command-line arguments. Password
mode requires `sshpass` on the **first-hop host**, not on the local machine or
second-hop target.

Use `--help` for all options.

## Selection and branch deltas

The default selection includes staged and unstaged tracked changes, tracked
deletions, and staged additions. Ordinary untracked files are not candidates.

`--include-untracked` additionally selects non-ignored untracked files using
`git ls-files --others --exclude-standard`. Git's normal ignore rules still
apply, and the optional `.git-delta-deploy.exclude` file filters the combined
candidate set afterward.

`--include-branch-diff=BASE_REF` additionally includes committed changes since
the merge base of `BASE_REF` and `HEAD`. In other words, it catches commits
present on the current branch/`HEAD` but not yet present on the selected local
base branch or ref:

```bash
git-delta-deploy \
  --include-branch-diff=origin/master \
  remote.example \
  /srv/application
```

Current staged and unstaged worktree changes remain selected at the same time,
so one invocation can deploy both the committed branch delta and current work:

```bash
git-delta-deploy \
  --include-branch-diff=origin/master \
  remote.example \
  /srv/application
```

With bare `--include-branch-diff`, the tool resolves a default remote branch
only from local refs. It prefers the current branch's upstream remote `HEAD`,
then `refs/remotes/origin/HEAD`, and finally a single unambiguous remote `HEAD`.
If none can be resolved, it stops and requires an explicit base. Selection is
strictly local: it never fetches, pulls, merges, or updates refs implicitly.

If sources classify the same path as both changed and deleted, current worktree
state wins. Renames are represented as the current path plus deletion of the old
path. Locale-sensitive `sort` and `comm` operations run under `LC_ALL=C`.

## Excludes and output

If `<repository>/.git-delta-deploy.exclude` exists, its nonblank,
non-comment lines are extended regular expressions matched against
repository-relative paths. An absent default file means no extra exclusions.
Use `--exclude-file FILE` for another file or `--no-exclude` to disable it.

Actionable copy, delete, and preserve lists are always printed completely.
Excluded lists are count-only unless `--verbose` is used. `--no-delete` keeps
locally deleted paths on the target and lists them as preserved.

Preview any variant with `--dry-run`, for example:

```bash
git-delta-deploy --dry-run deploy@example.net /srv/my-application
```

Dry-run performs local selection and output only. It creates no bundle and runs
no `ssh` or `scp` command.

## Apply safety

The target directory is required, must be absolute, and must already exist. The
final target canonicalizes it and confines every candidate parent path beneath
that root before backup or mutation. The `.git-delta-deploy-manifest` namespace
is reserved and rejected when selected from a worktree.

Before mutation, existing paths that will be overwritten or removed are saved
in a retained private `/tmp/git-delta-deploy-backup.*.tgz`. Application then
extracts changed files and removes selected deletions. By default it verifies
regular-file SHA256 checksums, exact symlink targets, and that deletions are
absent; `--no-verify` disables those checks. Deployment is non-transactional.

A success message is emitted only after the final target apply command and its
verification have returned successfully. Nested SSH uses `ssh -n`, and nested
SCP reads from `/dev/null`, so neither can consume the outer driver's script.

## Manual live acceptance

`tests/run.sh` is the deterministic local regression suite.
`tests/live-acceptance.sh` is optional, network-dependent dogfood; all
infrastructure-specific values are supplied through environment variables.

Direct target:

```bash
GDD_FIRST_HOP=user@host ./tests/live-acceptance.sh direct
```

SSH-accessible container through a first hop:

```bash
GDD_FIRST_HOP=user@host \
GDD_VIA_TARGET=root@localhost \
GDD_VIA_PORT=2222 \
GDD_CONTAINER_PASSWORD='password' \
./tests/live-acceptance.sh via
```

Successful runs exercise normal deployment and built-in final-target
verification, independently compare SHA256 values, verify symlink and deletion
handling, and in via mode ensure the payload was not applied on the first hop.
They clean up their disposable local and remote `/tmp/git-delta-deploy-live-*`
artifacts automatically. Set `GDD_KEEP_ARTIFACTS=1` to retain them.

## Requirements

The local machine needs Bash, Git, OpenSSH `ssh` and `scp`, GNU-compatible
`tar`, `readlink`, `base64`, `sha256sum`, and standard text utilities. The final
target needs the target-side commands listed under direct deployment. For a
second hop, the first-hop host additionally needs Bash, OpenSSH `ssh` and `scp`,
`base64`, `mktemp`, and standard file utilities; add `sshpass` there when using
either `--container-password` or the password launcher.
