#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-}"
FIRST_HOP="${GDD_FIRST_HOP:-}"
VIA_TARGET="${GDD_VIA_TARGET:-}"
VIA_PORT="${GDD_VIA_PORT:-22}"
CONTAINER_PASSWORD="${GDD_CONTAINER_PASSWORD:-}"
TOOL="${GDD_TOOL:-$ROOT/git-delta-deploy}"
KEEP_ARTIFACTS="${GDD_KEEP_ARTIFACTS:-0}"
LOCAL_FIXTURE=""

if [[ "${GDD_TARGET_DIR+x}" == x ]]; then
  TARGET_DIR="$GDD_TARGET_DIR"
else
  TARGET_DIR="/tmp/git-delta-deploy-live-${MODE:-unset}-$(date +%Y%m%d-%H%M%S)-$$-$RANDOM"
fi

show_locations() {
  [[ -n "$LOCAL_FIXTURE" ]] && echo "Local fixture: $LOCAL_FIXTURE" >&2
  echo "Target dir: $TARGET_DIR" >&2
}

on_exit() {
  local status=$?
  if [[ "$status" -ne 0 ]]; then
    if [[ -n "$LOCAL_FIXTURE" ]]; then
      echo "FAIL: live acceptance did not complete; artifacts were retained." >&2
      show_locations
    else
      echo "FAIL: live acceptance validation failed; no artifacts were created." >&2
    fi
  elif [[ "$KEEP_ARTIFACTS" -eq 1 ]]; then
    echo "Artifacts retained (GDD_KEEP_ARTIFACTS=1)."
    show_locations
  fi
}
trap on_exit EXIT

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

if [[ $# -ne 1 ]]; then
  fail 'Usage: ./tests/live-acceptance.sh {direct|via}'
fi
case "$MODE" in
  direct|via)
    ;;
  *)
    fail "Invalid mode '$MODE'; expected direct or via."
    ;;
esac

[[ -n "$FIRST_HOP" ]] || fail 'GDD_FIRST_HOP is required.'
[[ "$FIRST_HOP" != -* && "$FIRST_HOP" != *$'\n'* ]] || fail 'GDD_FIRST_HOP is invalid.'
if [[ "$MODE" == via ]]; then
  [[ -n "$VIA_TARGET" ]] || fail 'GDD_VIA_TARGET is required in via mode.'
  [[ "$VIA_TARGET" != -* && "$VIA_TARGET" != *$'\n'* ]] || fail 'GDD_VIA_TARGET is invalid.'
  [[ -n "$CONTAINER_PASSWORD" ]] || fail 'GDD_CONTAINER_PASSWORD is required in via mode.'
  [[ "$CONTAINER_PASSWORD" != *$'\n'* ]] || fail 'GDD_CONTAINER_PASSWORD must not contain a newline.'
fi
if [[ ! "$VIA_PORT" =~ ^[0-9]+$ ]] || (( 10#$VIA_PORT < 1 || 10#$VIA_PORT > 65535 )); then
  fail "GDD_VIA_PORT must be an integer from 1 to 65535: $VIA_PORT"
fi
[[ "$KEEP_ARTIFACTS" == 0 || "$KEEP_ARTIFACTS" == 1 ]] || fail 'GDD_KEEP_ARTIFACTS must be 0 or 1.'
[[ "$TARGET_DIR" =~ ^/tmp/git-delta-deploy-live-[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || \
  fail 'GDD_TARGET_DIR must match /tmp/git-delta-deploy-live-* without subdirectories.'
[[ -x "$TOOL" ]] || fail "GDD_TOOL is not executable: $TOOL"
TOOL="$(realpath -e -- "$TOOL")"

run_via_command() {
  local command="$1"
  local command_b64
  local via_target_b64
  command_b64="$(printf '%s' "$command" | base64 | tr -d '\n')"
  via_target_b64="$(printf '%s' "$VIA_TARGET" | base64 | tr -d '\n')"

  {
    printf '%s\n' "$CONTAINER_PASSWORD"
    printf '%s\n' "$command_b64"
  } | ssh "$FIRST_HOP" \
    "VIA_TARGET_B64=$via_target_b64 VIA_PORT=$VIA_PORT bash -c 'IFS= read -r SSHPASS; export SSHPASS; IFS= read -r COMMAND_B64; VIA_TARGET=\"\$(printf %s \"\$VIA_TARGET_B64\" | base64 --decode)\"; COMMAND=\"\$(printf %s \"\$COMMAND_B64\" | base64 --decode)\"; exec sshpass -e ssh -n -p \"\$VIA_PORT\" \"\$VIA_TARGET\" \"\$COMMAND\"'"
}

run_target_command() {
  if [[ "$MODE" == direct ]]; then
    ssh "$FIRST_HOP" "$1"
  else
    run_via_command "$1"
  fi
}

LOCAL_FIXTURE="$(mktemp -d /tmp/git-delta-deploy-live-local.XXXXXX)"
git -C "$LOCAL_FIXTURE" init -q
git -C "$LOCAL_FIXTURE" config user.name 'Live Acceptance'
git -C "$LOCAL_FIXTURE" config user.email live-acceptance@example.invalid
printf 'baseline changed\n' > "$LOCAL_FIXTURE/changed.txt"
printf 'baseline deleted\n' > "$LOCAL_FIXTURE/deleted.txt"
git -C "$LOCAL_FIXTURE" add changed.txt deleted.txt
git -C "$LOCAL_FIXTURE" commit -qm baseline

printf 'deployed changed\n' > "$LOCAL_FIXTURE/changed.txt"
rm -- "$LOCAL_FIXTURE/deleted.txt"
ln -s -- changed.txt "$LOCAL_FIXTURE/link.txt"
git -C "$LOCAL_FIXTURE" add -A

echo "Mode: $MODE"
echo "First hop: $FIRST_HOP"
if [[ "$MODE" == via ]]; then
  echo "Via target: $VIA_TARGET:$VIA_PORT"
  ssh "$FIRST_HOP" "test ! -e $TARGET_DIR && test ! -L $TARGET_DIR" || \
    fail 'The disposable target path already exists on the first-hop host.'
fi
echo "Target dir: $TARGET_DIR"

run_target_command \
  "umask 077; mkdir -- $TARGET_DIR && printf 'baseline changed\\n' > $TARGET_DIR/changed.txt && printf 'baseline deleted\\n' > $TARGET_DIR/deleted.txt"

echo 'Deployment output:'
if [[ "$MODE" == direct ]]; then
  (cd "$LOCAL_FIXTURE" && "$TOOL" "$FIRST_HOP" "$TARGET_DIR")
else
  (cd "$LOCAL_FIXTURE" && "$TOOL" \
    --via-target "$VIA_TARGET" \
    --via-port "$VIA_PORT" \
    --container-password "$CONTAINER_PASSWORD" \
    "$FIRST_HOP" "$TARGET_DIR")
fi

LOCAL_SHA256="$(sha256sum -- "$LOCAL_FIXTURE/changed.txt" | awk '{print $1}')"
FINAL_SHA256="$(run_target_command "sha256sum -- $TARGET_DIR/changed.txt" | awk 'NF { value=$1 } END { print value }')"
echo "Local SHA256: $LOCAL_SHA256"
echo "Final-target SHA256: $FINAL_SHA256"
[[ "$LOCAL_SHA256" == "$FINAL_SHA256" ]] || fail 'Local and final-target SHA256 values differ.'

run_target_command \
  "test ! -e $TARGET_DIR/deleted.txt && test ! -L $TARGET_DIR/deleted.txt && test -L $TARGET_DIR/link.txt && test \"\$(readlink -- $TARGET_DIR/link.txt)\" = changed.txt" || \
  fail 'Final-target deletion or symlink verification failed.'

if [[ "$MODE" == via ]]; then
  ssh "$FIRST_HOP" "test ! -e $TARGET_DIR && test ! -L $TARGET_DIR" || \
    fail 'Disposable payload was unexpectedly applied on the first-hop host.'
fi

if [[ "$KEEP_ARTIFACTS" -eq 0 ]]; then
  run_target_command "rm -rf -- $TARGET_DIR" || fail 'Could not remove the disposable final target.'
  rm -rf -- "$LOCAL_FIXTURE"
  LOCAL_FIXTURE=""
fi

echo "PASS: $MODE live acceptance completed."
