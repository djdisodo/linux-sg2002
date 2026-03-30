#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_SCRIPT="$SCRIPT_DIR/w4_deploy_module.sh"

TARGET_HOST="${TARGET_HOST:-root@192.168.45.130}"
TARGET_MODULE="${TARGET_MODULE:-/root/wave4.ko}"
SSH_CMD="${SSH_CMD:-ssh -o StrictHostKeyChecking=no}"
REMOTE_ROOT="${REMOTE_ROOT:-/root/vpu-test}"
LOCAL_ROOT="${LOCAL_ROOT:-$SCRIPT_DIR/../test-logs}"
LOCAL_MODULE="$SCRIPT_DIR/../wave4.ko"

REMOTE_DEVICE="${REMOTE_DEVICE:-/dev/video0}"
REMOTE_INPUT="${REMOTE_INPUT:-}"
REMOTE_OUTPUT=""
PIX_FMT="${PIX_FMT:-HEVC}"
SIZEIMAGE="${SIZEIMAGE:-}"
CAP_BUFS="${CAP_BUFS:-6}"
OUT_BUFS="${OUT_BUFS:-6}"
TIMEOUT_SEC="${TIMEOUT_SEC:-45}"
CASE_NAME=""
CUSTOM_V4L2_CMD=""

DO_DEPLOY=1
DO_RELOAD=1
PULL_LOGS=1

W4_BASE_PARAMS_DEFAULT="w4_use_reserved_mem=1 w4_wait_irq_cap_ms=5000"
W4_BASE_PARAMS="${W4_BASE_PARAMS:-$W4_BASE_PARAMS_DEFAULT}"

BASE_MODULE_PARAMS=()
EXTRA_MODULE_PARAMS=()

usage() {
  cat <<'EOF'
Usage: w4_run_case.sh [options]

Required (unless --v4l2-cmd is used):
  --input <remote path>       Bitstream file on target board

Common options:
  --name <case>               Case name (default: timestamp)
  --input <remote path>       Input bitstream path on target
  --output <remote path>      Output YUV path on target (default: <case_dir>/out.yuv)
  --device <node>             Video node (default: /dev/video0)
  --pixfmt <fmt>              Output queue pixfmt (default: HEVC)
  --sizeimage <bytes>         Output queue sizeimage override
  --cap-bufs <n>              --stream-mmap value (default: 6)
  --out-bufs <n>              --stream-out-mmap value (default: 6)
  --timeout-sec <n>           Remote v4l2 timeout in seconds (default: 45)
  --param <k=v>               Extra insmod parameter (repeatable)
  --v4l2-cmd <command>        Full remote command to run instead of generated v4l2-ctl

Deployment / target:
  --module <path>             Local module path (default: ../wave4.ko)
  --host <user@host>          Target host (default: root@192.168.45.130)
  --target-module <path>      Remote module path (default: /root/wave4.ko)
  --ssh-cmd <command>         SSH command with options
  --remote-root <path>        Remote case root dir (default: /root/vpu-test)
  --local-root <path>         Local pulled-log root (default: ../test-logs)
  --skip-deploy               Skip rsync deploy
  --skip-reload               Skip module reload
  --no-pull                   Do not pull remote logs to local
  -h, --help                  Show this help

Environment:
  W4_BASE_PARAMS defaults to "w4_use_reserved_mem=1 w4_wait_irq_cap_ms=5000"
  Set W4_BASE_PARAMS='' to disable built-in module params.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
  --name)
    CASE_NAME="$2"
    shift 2
    ;;
  --input)
    REMOTE_INPUT="$2"
    shift 2
    ;;
  --output)
    REMOTE_OUTPUT="$2"
    shift 2
    ;;
  --device)
    REMOTE_DEVICE="$2"
    shift 2
    ;;
  --pixfmt)
    PIX_FMT="$2"
    shift 2
    ;;
  --sizeimage)
    SIZEIMAGE="$2"
    shift 2
    ;;
  --cap-bufs)
    CAP_BUFS="$2"
    shift 2
    ;;
  --out-bufs)
    OUT_BUFS="$2"
    shift 2
    ;;
  --timeout-sec)
    TIMEOUT_SEC="$2"
    shift 2
    ;;
  --param)
    EXTRA_MODULE_PARAMS+=("$2")
    shift 2
    ;;
  --v4l2-cmd)
    CUSTOM_V4L2_CMD="$2"
    shift 2
    ;;
  --module)
    LOCAL_MODULE="$2"
    shift 2
    ;;
  --host)
    TARGET_HOST="$2"
    shift 2
    ;;
  --target-module)
    TARGET_MODULE="$2"
    shift 2
    ;;
  --ssh-cmd)
    SSH_CMD="$2"
    shift 2
    ;;
  --remote-root)
    REMOTE_ROOT="$2"
    shift 2
    ;;
  --local-root)
    LOCAL_ROOT="$2"
    shift 2
    ;;
  --skip-deploy)
    DO_DEPLOY=0
    shift
    ;;
  --skip-reload)
    DO_RELOAD=0
    shift
    ;;
  --no-pull)
    PULL_LOGS=0
    shift
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    echo "unknown argument: $1" >&2
    usage
    exit 1
    ;;
  esac
done

if [[ -z "$CASE_NAME" ]]; then
  CASE_NAME="$(date +%Y%m%d-%H%M%S)"
fi

REMOTE_CASE_DIR="$REMOTE_ROOT/$CASE_NAME"
if [[ -z "$REMOTE_OUTPUT" ]]; then
  REMOTE_OUTPUT="$REMOTE_CASE_DIR/out.yuv"
fi

if [[ -z "$CUSTOM_V4L2_CMD" && -z "$REMOTE_INPUT" ]]; then
  echo "--input is required when --v4l2-cmd is not provided" >&2
  exit 1
fi

if [[ -n "$W4_BASE_PARAMS" ]]; then
  # shellcheck disable=SC2206
  BASE_MODULE_PARAMS=($W4_BASE_PARAMS)
fi

MODULE_PARAMS=("${BASE_MODULE_PARAMS[@]}" "${EXTRA_MODULE_PARAMS[@]}")
INSMOD_ARGS=""
for param in "${MODULE_PARAMS[@]}"; do
  INSMOD_ARGS+="$param "
done
INSMOD_ARGS="${INSMOD_ARGS%" "}"
INSMOD_ARGS_B64="$(printf '%s' "$INSMOD_ARGS" | base64 -w0)"

if [[ -z "$CUSTOM_V4L2_CMD" ]]; then
  fmt_opt="pixelformat=$PIX_FMT"
  if [[ -n "$SIZEIMAGE" ]]; then
    fmt_opt+=",sizeimage=$SIZEIMAGE"
  fi

  v4l2_cmd=(
    v4l2-ctl
    -d "$REMOTE_DEVICE"
    --verbose
    "--set-fmt-video-out-mplane=$fmt_opt"
    "--stream-mmap=$CAP_BUFS"
    "--stream-out-mmap=$OUT_BUFS"
    "--stream-from=$REMOTE_INPUT"
    "--stream-to=$REMOTE_OUTPUT"
    --stream-poll
  )
  printf -v CUSTOM_V4L2_CMD '%q ' "${v4l2_cmd[@]}"
fi
CUSTOM_V4L2_CMD_B64="$(printf '%s' "$CUSTOM_V4L2_CMD" | base64 -w0)"

read -r -a ssh_argv <<<"$SSH_CMD"

if (( DO_DEPLOY )); then
  TARGET_HOST="$TARGET_HOST" TARGET_MODULE="$TARGET_MODULE" SSH_CMD="$SSH_CMD" \
    "$DEPLOY_SCRIPT" --module "$LOCAL_MODULE"
fi

echo "running case: $CASE_NAME"
echo "  target      : $TARGET_HOST"
echo "  remote dir  : $REMOTE_CASE_DIR"
echo "  module path : $TARGET_MODULE"
if [[ -n "$INSMOD_ARGS" ]]; then
  echo "  insmod args : $INSMOD_ARGS"
fi

"${ssh_argv[@]}" "$TARGET_HOST" sh -s -- \
  "$REMOTE_CASE_DIR" \
  "$REMOTE_ROOT" \
  "$TARGET_MODULE" \
  "$DO_RELOAD" \
  "$INSMOD_ARGS_B64" \
  "$TIMEOUT_SEC" \
  "$CUSTOM_V4L2_CMD_B64" \
  "$REMOTE_OUTPUT" <<'EOSH'
set -eu

case_dir=$1
remote_root=$2
target_module=$3
do_reload=$4
insmod_args_b64=$5
timeout_sec=$6
v4l2_cmd_b64=$7
output_file=$8

mkdir -p "$case_dir"
ln -sfn "$case_dir" "$remote_root/latest"

dmesg -C >/dev/null 2>&1 || true

insmod_args="$(printf '%s' "$insmod_args_b64" | base64 -d)"
v4l2_cmd="$(printf '%s' "$v4l2_cmd_b64" | base64 -d)"

if [ "$do_reload" = "1" ]; then
  modprobe -r wave4 2>/dev/null || true
  rmmod wave4 2>/dev/null || true
  if [ -n "$insmod_args" ]; then
    # shellcheck disable=SC2086
    insmod "$target_module" $insmod_args
  else
    insmod "$target_module"
  fi
fi

if [ -d /sys/module/wave4/parameters ]; then
  {
    for p in /sys/module/wave4/parameters/*; do
      [ -f "$p" ] || continue
      printf '%s=%s\n' "$(basename "$p")" "$(cat "$p")"
    done
  } >"$case_dir/module_params.log"
fi

printf '%s\n' "$v4l2_cmd" >"$case_dir/v4l2.command"

set +e
if command -v timeout >/dev/null 2>&1; then
  timeout "$timeout_sec" sh -c "$v4l2_cmd" >"$case_dir/v4l2.log" 2>&1
  rc=$?
else
  sh -c "$v4l2_cmd" >"$case_dir/v4l2.log" 2>&1
  rc=$?
fi
set -e
printf '%s\n' "$rc" >"$case_dir/v4l2.rc"

dmesg -T >"$case_dir/dmesg.log" 2>/dev/null || dmesg >"$case_dir/dmesg.log"

if [ -n "$output_file" ] && [ -f "$output_file" ]; then
  stat -c '%n %s' "$output_file" >"$case_dir/output_size.txt" 2>/dev/null || true
fi

grep -E \
  "w4 wait_interrupt timeout|seq init failed|fail_reason=|dec_err=|Oops|BUG:|Unable to handle kernel paging request" \
  "$case_dir/dmesg.log" >"$case_dir/highlights.log" || true
EOSH

rc="$("${ssh_argv[@]}" "$TARGET_HOST" "cat '$REMOTE_CASE_DIR/v4l2.rc'")"

if (( PULL_LOGS )); then
  LOCAL_CASE_DIR="$LOCAL_ROOT/$CASE_NAME"
  mkdir -p "$LOCAL_CASE_DIR"
  rsync -az -e "$SSH_CMD" "$TARGET_HOST:$REMOTE_CASE_DIR/" "$LOCAL_CASE_DIR/"
  echo "  local logs  : $LOCAL_CASE_DIR"
fi

echo "  v4l2 rc     : $rc"
"${ssh_argv[@]}" "$TARGET_HOST" "cat '$REMOTE_CASE_DIR/output_size.txt' 2>/dev/null || true"
"${ssh_argv[@]}" "$TARGET_HOST" "sed -n '1,40p' '$REMOTE_CASE_DIR/highlights.log' 2>/dev/null || true"

exit "$rc"
