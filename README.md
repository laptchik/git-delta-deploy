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

Install both commands side-by-side in a directory on your `PATH`. For example:

```bash
mkdir -p "$HOME/.local/bin"
install -m 0755 git-delta-deploy git-delta-deploy-via-password "$HOME/.local/bin/"
```

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

Direct dry-run and deployment:

```bash
git-delta-deploy --dry-run deploy@example.net /srv/my-application
git-delta-deploy deploy@example.net /srv/my-application
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

Second-hop dry-run with normal SSH authentication:

```bash
git-delta-deploy \
  --dry-run \
  --via-target deploy@internal.example \
  --via-port 2222 \
  jump@example.net \
  /srv/my-application
```

Both hops use normal SSH authentication and configuration by default, including
host-key checking. For password-based second-hop authentication, use the
explicit launcher:

```bash
git-delta-deploy-via-password \
  --via-target deploy@internal.example \
  --via-port 2222 \
  jump@example.net \
  /srv/my-application
```

The launcher prompts for `Second-hop SSH password:` with hidden input. It sets
`GIT_DELTA_DEPLOY_PASSWORD` only for the launched deployment and forwards all
arguments to `git-delta-deploy` unchanged. The password is sent to the first-hop
driver through SSH input and is never placed in command-line arguments. Password
mode requires `sshpass` on the **first-hop host**, not on the local machine or
second-hop target.

A host or container reachable over SSH from a jump host is one possible
second-hop target; no container-specific behavior is assumed.

Use `--help` for all options.

## Selection and branch deltas

The default selection includes staged and unstaged tracked changes, tracked
deletions, and staged additions. Ordinary untracked files are not candidates.

`--include-untracked` additionally selects non-ignored untracked files using
`git ls-files --others --exclude-standard`. Git's normal ignore rules still
apply, and the optional `.git-delta-deploy.exclude` file filters the combined
candidate set afterward.

`--include-branch-diff=BASE_REF` additionally includes committed changes since
the merge base of `BASE_REF` and `HEAD`. With bare `--include-branch-diff`, the
tool resolves a default remote branch only from local refs. It prefers the
current branch's upstream remote `HEAD`, then `refs/remotes/origin/HEAD`, and
finally a single unambiguous remote `HEAD`. If none can be resolved, it stops
and requires an explicit base. It never fetches, pulls, merges, or mutates refs.

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

`--dry-run` performs local selection and output only. It creates no bundle and
runs no `ssh` or `scp` command.

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

## Requirements

The local machine needs Bash, Git, OpenSSH `ssh` and `scp`, GNU-compatible
`tar`, `readlink`, `base64`, `sha256sum`, and standard text utilities. The final
target needs the target-side commands listed under direct deployment. For a
second hop, the first-hop host additionally needs Bash, OpenSSH `ssh` and `scp`,
`base64`, `mktemp`, and standard file utilities; add `sshpass` there only when
using the password launcher.
