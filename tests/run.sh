#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="$ROOT/git-delta-deploy"
PASSWORD_LAUNCHER="$ROOT/git-delta-deploy-via-password"
INSTALLER="$ROOT/install.sh"
TEST_ROOT="$(mktemp -d /tmp/git-delta-deploy-tests.XXXXXX)"
PASS_COUNT=0

cleanup() {
  rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "PASS: $*"
}

assert_contains() {
  local file="$1"
  local expected="$2"
  grep -F -- "$expected" "$file" >/dev/null || {
    echo "Expected output to contain: $expected" >&2
    sed -n '1,240p' "$file" >&2
    fail "output assertion"
  }
}

assert_not_contains() {
  local file="$1"
  local unexpected="$2"
  if grep -F -- "$unexpected" "$file" >/dev/null; then
    echo "Expected output not to contain: $unexpected" >&2
    sed -n '1,240p' "$file" >&2
    fail "negative output assertion"
  fi
}

new_repo() {
  local repo="$1"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.name 'Test User'
  git -C "$repo" config user.email test@example.invalid
  printf 'base\n' > "$repo/changed.txt"
  printf 'delete me\n' > "$repo/deleted.txt"
  printf 'keep\n' > "$repo/kept.txt"
  git -C "$repo" add .
  git -C "$repo" commit -qm base
}

run_in_repo() {
  local repo="$1"
  local output="$2"
  shift 2
  (cd "$repo" && "$TOOL" "$@") >"$output" 2>&1
}

test_password_launcher() {
  local launcher_dir="$TEST_ROOT/password-launcher"
  local missing_dir="$TEST_ROOT/password-launcher-missing"
  local isolated_bin="$TEST_ROOT/password-launcher-bin"
  local output="$TEST_ROOT/password-launcher.out"
  local expected_args="$TEST_ROOT/password-launcher-expected-args"
  local actual_args="$TEST_ROOT/password-launcher-actual-args"
  local actual_password="$TEST_ROOT/password-launcher-password"
  local secret='password with spaces and * shell characters'

  mkdir -p "$launcher_dir" "$missing_dir" "$isolated_bin"
  cp -- "$PASSWORD_LAUNCHER" "$launcher_dir/"
  cat > "$launcher_dir/git-delta-deploy" <<'EOF'
#!/usr/bin/env bash
printf '%s' "$GIT_DELTA_DEPLOY_PASSWORD" > "$PASSWORD_CAPTURE"
printf '%s\0' "$@" > "$ARG_CAPTURE"
printf 'mock deployment launched\n'
EOF
  chmod +x "$launcher_dir/git-delta-deploy"

  printf '%s\0' --via-target 'second hop@example' --via-port 2222 \
    'first hop@example' '/srv/path with spaces' '' > "$expected_args"
  printf '%s\n' "$secret" | \
    PASSWORD_CAPTURE="$actual_password" ARG_CAPTURE="$actual_args" \
    "$launcher_dir/git-delta-deploy-via-password" \
      --via-target 'second hop@example' --via-port 2222 \
      'first hop@example' '/srv/path with spaces' '' > "$output" 2>&1

  cmp -s "$expected_args" "$actual_args" || fail 'password launcher changed command arguments'
  [[ "$(<"$actual_password")" == "$secret" ]] || fail 'password launcher did not supply the password through the environment'
  assert_contains "$output" 'Second-hop SSH password:'
  assert_contains "$output" 'mock deployment launched'
  assert_not_contains "$output" "$secret"
  assert_not_contains "$actual_args" "$secret"

  cp -- "$PASSWORD_LAUNCHER" "$missing_dir/"
  ln -s "$(command -v bash)" "$isolated_bin/bash"
  ln -s "$(command -v dirname)" "$isolated_bin/dirname"
  if printf 'unused\n' | PATH="$isolated_bin" \
      "$missing_dir/git-delta-deploy-via-password" > "$output" 2>&1; then
    fail 'password launcher succeeded without the main executable'
  fi
  assert_contains "$output" 'ERROR: Cannot find the git-delta-deploy executable beside this launcher or on PATH.'
  assert_not_contains "$output" 'Second-hop SSH password:'

  pass 'password launcher forwards arguments, scopes a hidden password, and reports a missing main executable'
}

test_installation() {
  local bin="$TEST_ROOT/install-bin"
  local output="$TEST_ROOT/install.out"

  "$INSTALLER" "$bin" >"$output" 2>&1
  [[ -x "$bin/git-delta-deploy" ]] || fail 'installer did not install git-delta-deploy'
  [[ -x "$bin/git-delta-deploy-via-password" ]] || fail 'installer did not install password launcher'
  cmp -s "$TOOL" "$bin/git-delta-deploy" || fail 'installed main command differs from source'
  cmp -s "$PASSWORD_LAUNCHER" "$bin/git-delta-deploy-via-password" || fail 'installed password launcher differs from source'
  PATH="$bin:$PATH" command -v git-delta-deploy >/dev/null || fail 'installed main command is not PATH-visible'
  PATH="$bin:$PATH" command -v git-delta-deploy-via-password >/dev/null || fail 'installed password launcher is not PATH-visible'
  assert_contains "$output" "Installed git-delta-deploy and git-delta-deploy-via-password in $bin"
  pass 'lightweight installer installs both executable commands into PATH'
}

test_selection_and_dry_run() {
  local repo="$TEST_ROOT/selection"
  local unborn_repo="$TEST_ROOT/unborn-selection"
  local output="$TEST_ROOT/selection.out"
  new_repo "$repo"
  printf 'staged tracked change\n' >> "$repo/changed.txt"
  git -C "$repo" add changed.txt
  printf 'unstaged tracked change\n' >> "$repo/kept.txt"
  printf 'staged new file\n' > "$repo/staged-new.txt"
  git -C "$repo" add staged-new.txt
  rm "$repo/deleted.txt"
  printf 'untracked\n' > "$repo/untracked.txt"
  printf 'ignored\n' > "$repo/ignored.tmp"
  printf '*.tmp\n' > "$repo/.gitignore"
  git -C "$repo" add .gitignore

  run_in_repo "$repo" "$output" --dry-run host.example /srv/app
  assert_contains "$output" 'Untracked:     excluded'
  assert_contains "$output" 'Tracked/staged files to deploy (4):'
  assert_contains "$output" '  + changed.txt'
  assert_contains "$output" '  + kept.txt'
  assert_contains "$output" '  + staged-new.txt'
  assert_contains "$output" '  - deleted.txt'
  assert_not_contains "$output" 'untracked.txt'
  assert_not_contains "$output" 'ignored.tmp'
  assert_contains "$output" 'Dry run only. Nothing copied.'

  run_in_repo "$repo" "$output" --dry-run --include-untracked host.example /srv/app
  assert_contains "$output" 'Untracked:     included (non-ignored)'
  assert_contains "$output" 'Tracked/staged and untracked files to deploy (5):'
  assert_contains "$output" '  + untracked.txt'
  assert_not_contains "$output" 'ignored.tmp'

  git -C "$TEST_ROOT" init -q "$unborn_repo"
  printf 'staged before first commit\n' > "$unborn_repo/staged-new.txt"
  printf 'ordinary untracked\n' > "$unborn_repo/untracked.txt"
  git -C "$unborn_repo" add staged-new.txt
  run_in_repo "$unborn_repo" "$output" --dry-run host.example /srv/app
  assert_contains "$output" 'Tracked/staged files to deploy (1):'
  assert_contains "$output" '  + staged-new.txt'
  assert_not_contains "$output" 'untracked.txt'

  pass 'tracked/staged defaults, unborn staged additions, opt-in untracked selection, ignores, and dry-run'
}

test_verbose_excludes_and_no_delete() {
  local repo="$TEST_ROOT/excludes"
  local output="$TEST_ROOT/excludes.out"
  new_repo "$repo"
  printf 'changed\n' >> "$repo/changed.txt"
  printf 'skip\n' > "$repo/skip.local"
  rm "$repo/deleted.txt"
  printf '^changed[.]txt$\n^skip[.]local$\n^deleted[.]txt$\n' > "$repo/.git-delta-deploy.exclude"

  run_in_repo "$repo" "$output" --dry-run --verbose --no-delete --include-untracked host.example /srv/app
  assert_contains "$output" 'Tracked/staged and untracked files skipped by exclude file: 2'
  assert_contains "$output" '  x changed.txt'
  assert_contains "$output" '  x skip.local'
  assert_contains "$output" 'Deleted files skipped by exclude file: 1'
  assert_contains "$output" '  x deleted.txt'

  printf '^skip[.]local$\n' > "$repo/.git-delta-deploy.exclude"
  run_in_repo "$repo" "$output" --dry-run --no-delete --include-untracked host.example /srv/app
  assert_contains "$output" 'Deleted files preserved remotely (1):'
  assert_contains "$output" '  = deleted.txt'

  run_in_repo "$repo" "$output" --dry-run --no-exclude --include-untracked host.example /srv/app
  assert_contains "$output" 'Exclude file:  disabled'
  assert_contains "$output" '  + skip.local'
  assert_contains "$output" '  - deleted.txt'
  pass '--verbose, exclude file, and --no-delete'
}

test_explicit_target_validation() {
  local repo="$TEST_ROOT/target"
  local output="$TEST_ROOT/target.out"
  new_repo "$repo"
  printf 'changed\n' >> "$repo/changed.txt"

  if run_in_repo "$repo" "$output" --dry-run host.example relative/path; then
    fail 'relative target directory was accepted'
  fi
  assert_contains "$output" 'ERROR: TARGET_DIR must be an absolute path'
  run_in_repo "$repo" "$output" --dry-run host.example /explicit/target
  assert_contains "$output" 'Target dir:    /explicit/target'

  if run_in_repo "$repo" "$output" --dry-run host.example; then
    fail 'missing target directory was accepted'
  fi
  assert_contains "$output" 'Usage:'
  pass 'required explicit absolute target directory'
}

test_branch_diff() {
  local repo="$TEST_ROOT/branch"
  local output="$TEST_ROOT/branch.out"
  new_repo "$repo"
  git -C "$repo" branch -M main
  git -C "$repo" update-ref refs/remotes/origin/main HEAD
  git -C "$repo" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  printf 'branch\n' > "$repo/branch-only.txt"
  git -C "$repo" add branch-only.txt
  git -C "$repo" commit -qm branch-change

  run_in_repo "$repo" "$output" --dry-run --include-branch-diff=origin/main host.example /srv/app
  assert_contains "$output" 'Base ref:      origin/main'
  assert_contains "$output" '  + branch-only.txt'

  printf 'staged worktree change\n' >> "$repo/changed.txt"
  git -C "$repo" add changed.txt
  printf 'unstaged worktree change\n' >> "$repo/kept.txt"
  run_in_repo "$repo" "$output" --dry-run --include-branch-diff=origin/main host.example /srv/app
  assert_contains "$output" '  + branch-only.txt'
  assert_contains "$output" '  + changed.txt'
  assert_contains "$output" '  + kept.txt'

  run_in_repo "$repo" "$output" --dry-run --include-branch-diff host.example /srv/app
  assert_contains "$output" 'Base ref:      origin/main'

  git -C "$repo" symbolic-ref --delete refs/remotes/origin/HEAD
  if run_in_repo "$repo" "$output" --dry-run --include-branch-diff host.example /srv/app; then
    fail 'automatic branch base unexpectedly resolved without a remote HEAD'
  fi
  assert_contains "$output" 'ERROR: Cannot resolve a reliable default remote branch from local Git refs.'
  pass 'explicit and automatic branch diff plus unresolved-base failure'
}

test_changed_deleted_conflict() {
  local repo="$TEST_ROOT/conflict"
  local output="$TEST_ROOT/conflict.out"
  new_repo "$repo"
  git -C "$repo" update-ref refs/remotes/origin/main HEAD
  rm "$repo/kept.txt"
  git -C "$repo" add kept.txt
  git -C "$repo" commit -qm delete-kept
  printf 'restored\n' > "$repo/kept.txt"

  run_in_repo "$repo" "$output" --dry-run --include-branch-diff=origin/main host.example /srv/app
  assert_contains "$output" '  + kept.txt'
  assert_not_contains "$output" '  - kept.txt'

  rm "$repo/kept.txt"
  run_in_repo "$repo" "$output" --dry-run --include-branch-diff=origin/main host.example /srv/app
  assert_contains "$output" '  - kept.txt'
  assert_not_contains "$output" '  + kept.txt'
  pass 'current worktree wins changed/deleted conflicts'
}

test_non_c_locale_and_reserved_namespace() {
  local repo="$TEST_ROOT/locale"
  local output="$TEST_ROOT/locale.out"
  local bin="$TEST_ROOT/locale-bin"
  local real_sort
  local real_comm
  new_repo "$repo"
  printf 'z\n' > "$repo/zeta"
  printf 'a\n' > "$repo/Alpha"

  real_sort="$(command -v sort)"
  real_comm="$(command -v comm)"
  mkdir -p "$bin"
  cat > "$bin/sort" <<EOF
#!/usr/bin/env bash
[[ "\${LC_ALL:-}" == C ]] || exit 95
exec "$real_sort" "\$@"
EOF
  cat > "$bin/comm" <<EOF
#!/usr/bin/env bash
[[ "\${LC_ALL:-}" == C ]] || exit 96
exec "$real_comm" "\$@"
EOF
  chmod +x "$bin/sort" "$bin/comm"

  (cd "$repo" && PATH="$bin:$PATH" LC_ALL=C.utf8 \
    "$TOOL" --dry-run --include-untracked host.example /srv/app) >"$output" 2>&1
  assert_contains "$output" '  + Alpha'
  assert_contains "$output" '  + zeta'

  mkdir "$repo/.git-delta-deploy-manifest"
  printf 'reserved\n' > "$repo/.git-delta-deploy-manifest/payload"
  if run_in_repo "$repo" "$output" --dry-run --include-untracked host.example /srv/app; then
    fail 'reserved internal namespace was accepted'
  fi
  assert_contains "$output" 'uses reserved .git-delta-deploy-manifest namespace'
  pass 'LC_ALL=C sort/comm under non-C caller locale and reserved namespace'
}

make_transport_stubs() {
  local bin="$1"
  mkdir -p "$bin"
  apply_stub="$bin/ssh"
  cat > "$apply_stub" <<'EOF'
#!/usr/bin/env bash
printf 'ssh:' >> "$TRANSPORT_LOG"
printf ' <%s>' "$@" >> "$TRANSPORT_LOG"
printf '\n' >> "$TRANSPORT_LOG"

last="${!#}"
if [[ "$last" == *'mktemp -d /tmp/git-delta-deploy.XXXXXX'* ]]; then
  printf '/tmp/git-delta-deploy.ABC123\n'
elif [[ "$last" == *"bash -c 'IFS= read -r AUTH_MODE"* ]]; then
  cat > "$OUTER_CAPTURE"
  printf 'Deployment complete.\n'
elif [[ "$last" == *'bash /tmp/git-delta-deploy.ABC123/apply.sh'* ]]; then
  printf 'Deployment complete.\n'
fi
EOF
  chmod +x "$apply_stub"
  cat > "$bin/scp" <<'EOF'
#!/usr/bin/env bash
printf 'scp:' >> "$TRANSPORT_LOG"
printf ' <%s>' "$@" >> "$TRANSPORT_LOG"
printf '\n' >> "$TRANSPORT_LOG"
EOF
  chmod +x "$bin/scp"
}

test_transport_control_flow() {
  local repo="$TEST_ROOT/transport"
  local output="$TEST_ROOT/transport.out"
  local bin="$TEST_ROOT/fake-bin"
  local log="$TEST_ROOT/transport.log"
  local capture="$TEST_ROOT/outer-driver.txt"
  new_repo "$repo"
  printf 'changed\n' >> "$repo/changed.txt"
  make_transport_stubs "$bin"
  : > "$log"

  (cd "$repo" && PATH="$bin:$PATH" TRANSPORT_LOG="$log" OUTER_CAPTURE="$capture" \
    "$TOOL" first@example /srv/app) >"$output" 2>&1
  assert_contains "$log" 'ssh: <first@example> <umask 077; mktemp -d /tmp/git-delta-deploy.XXXXXX>'
  assert_contains "$log" 'scp:'
  assert_contains "$output" 'Deployment and verification completed successfully.'

  : > "$log"
  (cd "$repo" && PATH="$bin:$PATH" TRANSPORT_LOG="$log" OUTER_CAPTURE="$capture" \
    "$TOOL" --via-target second@example --via-port 2222 first@example /srv/app) >"$output" 2>&1
  assert_contains "$capture" 'via_ssh=(ssh -n -p "$VIA_PORT"'
  assert_contains "$capture" '"${via_scp[@]}" "$OUTER_STAGE/bundle.tgz"'
  assert_contains "$capture" '"${via_ssh[@]}" \'
  assert_not_contains "$capture" 'StrictHostKeyChecking=no'
  assert_not_contains "$capture" 'UserKnownHostsFile=/dev/null'
  assert_contains "$output" 'Deployment and verification completed successfully.'
  assert_not_contains "$output" 'Done.'

  : > "$log"
  (cd "$repo" && PATH="$bin:$PATH" TRANSPORT_LOG="$log" OUTER_CAPTURE="$capture" \
    "$TOOL" --via-target root@localhost --via-port 2222 \
      --container-password 'container secret' first@example /srv/app) >"$output" 2>&1
  assert_contains "$log" 'ssh: <first@example> <umask 077; mktemp -d /tmp/git-delta-deploy.XXXXXX>'
  assert_not_contains "$log" 'container secret'
  assert_contains "$capture" 'password'
  assert_contains "$capture" 'container secret'
  assert_contains "$capture" 'via_ssh=(sshpass -e "${via_ssh[@]}")'
  assert_contains "$output" 'Deployment and verification completed successfully.'

  : > "$log"
  if (cd "$repo" && PATH="$bin:$PATH" TRANSPORT_LOG="$log" OUTER_CAPTURE="$capture" \
      "$TOOL" --container-password 'container secret' first@example /srv/app) >"$output" 2>&1; then
    fail '--container-password succeeded without --via-target'
  fi
  assert_contains "$output" 'ERROR: --container-password requires --via-target.'
  [[ ! -s "$log" ]] || fail '--container-password validation invoked an SSH transport command'
  pass 'direct first-hop flow and second-hop stdin-isolated apply flow'
}

test_dry_run_has_no_transport() {
  local repo="$TEST_ROOT/no-network"
  local output="$TEST_ROOT/no-network.out"
  local bin="$TEST_ROOT/no-network-bin"
  local log="$TEST_ROOT/no-network.log"
  new_repo "$repo"
  printf 'changed\n' >> "$repo/changed.txt"
  mkdir -p "$bin"
  for command in ssh scp; do
    cat > "$bin/$command" <<'EOF'
#!/usr/bin/env bash
echo called >> "$TRANSPORT_LOG"
exit 99
EOF
    chmod +x "$bin/$command"
  done
  : > "$log"

  (cd "$repo" && PATH="$bin:$PATH" TRANSPORT_LOG="$log" \
    "$TOOL" --dry-run --via-target second@example --via-port 2222 \
      first@example /srv/app) >"$output" 2>&1
  [[ ! -s "$log" ]] || fail 'dry-run invoked an SSH transport command'
  assert_contains "$output" 'Dry run only. Nothing copied.'
  pass 'second-hop dry-run performs no network command'
}

make_local_transport_stubs() {
  local bin="$1"
  mkdir -p "$bin"
  cat > "$bin/ssh" <<'EOF'
#!/usr/bin/env bash
[[ $# -eq 2 ]] || exit 90
shift
bash -c "$1"
EOF
  chmod +x "$bin/ssh"
  cat > "$bin/scp" <<'EOF'
#!/usr/bin/env bash
[[ $# -eq 2 ]] || exit 91
source_file="$1"
target_path="${2#*:}"
cp -- "$source_file" "$target_path"
EOF
  chmod +x "$bin/scp"
}

make_symlink_tamper_tar_stub() {
  local bin="$1"
  local real_tar
  real_tar="$(command -v tar)"
  cat > "$bin/tar" <<EOF
#!/usr/bin/env bash
"$real_tar" "\$@"
status=\$?
[[ "\$status" -eq 0 ]] || exit "\$status"
if [[ "\${SYMLINK_TAMPER:-}" != "" && " \$* " == *" -T "*changed-files.txt* ]]; then
  case "\$SYMLINK_TAMPER" in
    regular)
      rm -f -- "\$SYMLINK_TEST_TARGET/link"
      printf 'not a symlink\n' > "\$SYMLINK_TEST_TARGET/link"
      ;;
    target)
      ln -snf -- wrong-target "\$SYMLINK_TEST_TARGET/link"
      ;;
  esac
fi
EOF
  chmod +x "$bin/tar"
}

remove_test_backup() {
  local output="$1"
  local backup
  backup="$(sed -n 's/^Backup: //p; s/^Creating backup: //p' "$output" | tail -n 1)"
  if [[ "$backup" == /tmp/git-delta-deploy-backup.*.tgz ]]; then
    rm -f -- "$backup"
  fi
}

test_symlink_deployment_and_verification() {
  local unborn_repo="$TEST_ROOT/symlink-unborn"
  local changed_repo="$TEST_ROOT/symlink-changed"
  local target="$TEST_ROOT/symlink-target"
  local output="$TEST_ROOT/symlink.out"
  local bin="$TEST_ROOT/symlink-bin"

  git -C "$TEST_ROOT" init -q "$unborn_repo"
  git -C "$unborn_repo" config user.name 'Test User'
  git -C "$unborn_repo" config user.email test@example.invalid
  ln -s -- missing-target "$unborn_repo/link"
  git -C "$unborn_repo" add link
  mkdir -p "$target"
  make_local_transport_stubs "$bin"

  (cd "$unborn_repo" && PATH="$bin:$PATH" "$TOOL" local-test "$target") >"$output" 2>&1
  assert_contains "$output" 'Tracked/staged files to deploy (1):'
  assert_contains "$output" '  + link'
  assert_contains "$output" 'link: symlink OK'
  [[ -L "$target/link" ]] || fail 'staged dangling symlink was not deployed as a symlink'
  [[ "$(readlink -- "$target/link")" == 'missing-target' ]] || fail 'staged dangling symlink target differs'
  remove_test_backup "$output"

  new_repo "$changed_repo"
  ln -s -- first-target "$changed_repo/link"
  git -C "$changed_repo" add link
  git -C "$changed_repo" commit -qm symlink-base
  ln -snf -- second-target "$changed_repo/link"
  rm -rf -- "$target"
  mkdir -p "$target"
  (cd "$changed_repo" && PATH="$bin:$PATH" "$TOOL" local-test "$target") >"$output" 2>&1
  assert_contains "$output" 'link: symlink OK'
  [[ -L "$target/link" ]] || fail 'changed symlink was not deployed as a symlink'
  [[ "$(readlink -- "$target/link")" == 'second-target' ]] || fail 'changed symlink target was not deployed'
  remove_test_backup "$output"

  make_symlink_tamper_tar_stub "$bin"
  rm -rf -- "$target"
  mkdir -p "$target"
  if (cd "$changed_repo" && PATH="$bin:$PATH" SYMLINK_TAMPER=regular SYMLINK_TEST_TARGET="$target" \
      "$TOOL" local-test "$target") >"$output" 2>&1; then
    fail 'verification accepted a regular file in place of a symlink'
  fi
  assert_contains "$output" "ERROR: Expected symlink: $target/link"
  remove_test_backup "$output"

  rm -rf -- "$target"
  mkdir -p "$target"
  if (cd "$changed_repo" && PATH="$bin:$PATH" SYMLINK_TAMPER=target SYMLINK_TEST_TARGET="$target" \
      "$TOOL" local-test "$target") >"$output" 2>&1; then
    fail 'verification accepted a different symlink target'
  fi
  assert_contains "$output" "ERROR: Symlink target differs: $target/link"
  remove_test_backup "$output"

  pass 'dangling and changed symlinks deploy with type-aware target verification'
}

test_final_path_symlink_deletion() {
  local repo="$TEST_ROOT/symlink-delete"
  local target="$TEST_ROOT/symlink-delete-target"
  local outside="$TEST_ROOT/symlink-delete-referent"
  local output="$TEST_ROOT/symlink-delete.out"
  local bin="$TEST_ROOT/symlink-delete-bin"
  new_repo "$repo"
  ln -s -- referent "$repo/link"
  git -C "$repo" add link
  git -C "$repo" commit -qm symlink-delete-base
  rm -- "$repo/link"
  mkdir -p "$target"
  printf 'preserve me\n' > "$outside"
  ln -s -- "$outside" "$target/link"
  make_local_transport_stubs "$bin"

  (cd "$repo" && PATH="$bin:$PATH" "$TOOL" local-test "$target") >"$output" 2>&1
  [[ ! -e "$target/link" && ! -L "$target/link" ]] || fail 'final-path symlink was not removed'
  [[ "$(<"$outside")" == 'preserve me' ]] || fail 'final-path symlink deletion mutated its referent'
  assert_contains "$output" 'Verifying deleted files are absent...'
  remove_test_backup "$output"
  pass 'final-path symlink deletion removes only the link and preserves its referent'
}

test_local_apply_backup_and_verification() {
  local repo="$TEST_ROOT/local-apply"
  local target="$TEST_ROOT/local-target"
  local output="$TEST_ROOT/local-apply.out"
  local bin="$TEST_ROOT/local-bin"
  local backup
  new_repo "$repo"
  mkdir -p "$target"
  cp "$repo/changed.txt" "$repo/deleted.txt" "$repo/kept.txt" "$target/"
  printf 'changed remotely\n' > "$target/changed.txt"
  printf 'changed locally\n' > "$repo/changed.txt"
  printf 'new locally\n' > "$repo/new.txt"
  git -C "$repo" add new.txt
  rm "$repo/deleted.txt"
  make_local_transport_stubs "$bin"

  (cd "$repo" && PATH="$bin:$PATH" "$TOOL" local-test "$target") >"$output" 2>&1
  assert_contains "$output" 'Creating backup: /tmp/git-delta-deploy-backup.'
  assert_contains "$output" 'changed.txt: OK'
  assert_contains "$output" 'new.txt: OK'
  assert_contains "$output" 'Verifying deleted files are absent...'
  assert_contains "$output" 'Deployment complete.'
  assert_contains "$output" 'Deployment and verification completed successfully.'
  [[ "$(<"$target/changed.txt")" == 'changed locally' ]] || fail 'changed file was not applied'
  [[ "$(<"$target/new.txt")" == 'new locally' ]] || fail 'staged new file was not applied'
  [[ ! -e "$target/deleted.txt" ]] || fail 'deleted file remains on target'

  backup="$(sed -n 's/^Backup: //p' "$output")"
  [[ "$backup" =~ ^/tmp/git-delta-deploy-backup\.[[:alnum:]]+\.tgz$ ]] || fail 'invalid backup path in output'
  [[ -f "$backup" ]] || fail 'backup was not retained'
  tar -tzf "$backup" | LC_ALL=C sort > "$TEST_ROOT/backup-list.txt"
  assert_contains "$TEST_ROOT/backup-list.txt" 'changed.txt'
  assert_contains "$TEST_ROOT/backup-list.txt" 'deleted.txt'
  [[ "$(tar -xOf "$backup" changed.txt)" == 'changed remotely' ]] || fail 'backup did not preserve pre-apply changed file'
  [[ "$(tar -xOf "$backup" deleted.txt)" == 'delete me' ]] || fail 'backup did not preserve pre-delete file'
  rm -f -- "$backup"

  printf 'apply without verification\n' > "$repo/new.txt"
  (cd "$repo" && PATH="$bin:$PATH" "$TOOL" --no-verify local-test "$target") >"$output" 2>&1
  assert_contains "$output" 'Target verification skipped (--no-verify).'
  assert_contains "$output" 'Deployment and verification completed successfully.'
  [[ "$(<"$target/new.txt")" == 'apply without verification' ]] || fail '--no-verify apply did not execute'
  backup="$(sed -n 's/^Backup: //p' "$output")"
  [[ -f "$backup" ]] || fail '--no-verify backup was not retained'
  rm -f -- "$backup"
  pass 'local apply backs up, mutates, verifies, and supports --no-verify'
}

make_two_hop_local_stubs() {
  local bin="$1"
  mkdir -p "$bin"
  cat > "$bin/ssh" <<'EOF'
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n)
      shift
      ;;
    -p|-o)
      shift 2
      ;;
    *)
      break
      ;;
  esac
done
[[ $# -eq 2 ]] || exit 92
shift
bash -c "$1"
EOF
  chmod +x "$bin/ssh"
  cat > "$bin/scp" <<'EOF'
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do
  case "$1" in
    -P|-o)
      shift 2
      ;;
    *)
      break
      ;;
  esac
done
[[ $# -ge 2 ]] || exit 93
destination="${!#}"
target_dir="${destination#*:}"
sources=("${@:1:$#-1}")
cp -- "${sources[@]}" "$target_dir"
EOF
  chmod +x "$bin/scp"
}

test_local_second_hop_apply() {
  local repo="$TEST_ROOT/two-hop"
  local target="$TEST_ROOT/two-hop-target"
  local output="$TEST_ROOT/two-hop.out"
  local bin="$TEST_ROOT/two-hop-bin"
  local backup
  new_repo "$repo"
  mkdir -p "$target"
  cp "$repo/changed.txt" "$target/changed.txt"
  printf 'through second hop\n' > "$repo/changed.txt"
  make_two_hop_local_stubs "$bin"

  (cd "$repo" && PATH="$bin:$PATH" \
    "$TOOL" --via-target second-hop --via-port 2222 first-hop "$target") >"$output" 2>&1
  assert_contains "$output" 'Applying bundle through second hop second-hop:2222...'
  assert_contains "$output" 'changed.txt: OK'
  assert_contains "$output" 'Deployment complete.'
  assert_contains "$output" 'Deployment and verification completed successfully.'
  [[ "$(<"$target/changed.txt")" == 'through second hop' ]] || fail 'second-hop apply did not execute'

  backup="$(sed -n 's/^Backup: //p' "$output")"
  [[ -f "$backup" ]] || fail 'second-hop backup was not retained'
  rm -f -- "$backup"
  pass 'second-hop driver executes inner apply without consuming outer stdin'
}

test_path_confinement() {
  local repo="$TEST_ROOT/confinement"
  local target="$TEST_ROOT/confinement-target"
  local outside="$TEST_ROOT/outside"
  local output="$TEST_ROOT/confinement.out"
  local bin="$TEST_ROOT/confinement-bin"
  new_repo "$repo"
  mkdir -p "$repo/linked" "$target" "$outside"
  printf 'base\n' > "$repo/linked/payload"
  git -C "$repo" add linked/payload
  git -C "$repo" commit -qm linked-base
  printf 'changed\n' > "$repo/linked/payload"
  printf 'outside sentinel\n' > "$outside/payload"
  ln -s "$outside" "$target/linked"
  make_local_transport_stubs "$bin"

  if (cd "$repo" && PATH="$bin:$PATH" "$TOOL" local-test "$target") >"$output" 2>&1; then
    fail 'symlink escape path was applied'
  fi
  assert_contains "$output" 'ERROR: Deployment candidate escapes target root through its parent: linked/payload'
  [[ "$(<"$outside/payload")" == 'outside sentinel' ]] || fail 'outside target was mutated'
  assert_not_contains "$output" 'Deployment and verification completed successfully.'
  pass 'target-side path confinement blocks symlink escape before mutation'
}

if [[ "${1:-}" == --symlink-only ]]; then
  test_symlink_deployment_and_verification
  test_final_path_symlink_deletion
  echo "All $PASS_COUNT focused symlink regression groups passed."
  exit 0
fi

test_password_launcher
test_installation
test_selection_and_dry_run
test_verbose_excludes_and_no_delete
test_explicit_target_validation
test_branch_diff
test_changed_deleted_conflict
test_non_c_locale_and_reserved_namespace
test_transport_control_flow
test_dry_run_has_no_transport
test_local_apply_backup_and_verification
test_local_second_hop_apply
test_path_confinement
test_symlink_deployment_and_verification
test_final_path_symlink_deletion

echo "All $PASS_COUNT focused regression groups passed."
