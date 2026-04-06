#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_HOST="${TARGET_HOST:-root@192.168.45.130}"
TARGET_MODULE="${TARGET_MODULE:-/root/wave4.ko}"
SSH_CMD="${SSH_CMD:-ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=2}"
LOCAL_MODULE="$SCRIPT_DIR/../wave4.ko"
# CV1800B/SG2002 force-warm-reset sequence from U-Boot sysreset_cv1800b:
#   pre_req(0x050260cc)=1, unlock(0x05025004)=0xAB18, ctrl(0x05025008)=0xFFFF0810
RESET_CMD="${RESET_CMD:-if [ -x /root/devmem_rw ]; then /root/devmem_rw 0x050260cc 0x1; /root/devmem_rw 0x05025004 0xAB18; /root/devmem_rw 0x05025008 0xFFFF0810; elif command -v devmem >/dev/null 2>&1; then devmem 0x050260cc 32 0x1; devmem 0x05025004 32 0xAB18; devmem 0x05025008 32 0xFFFF0810; elif command -v busybox >/dev/null 2>&1 && busybox --list 2>/dev/null | grep -qx devmem; then busybox devmem 0x050260cc 32 0x1; busybox devmem 0x05025004 32 0xAB18; busybox devmem 0x05025008 32 0xFFFF0810; else reboot -n -f || reboot -f; fi}"
RESET_WAIT_SEC="${RESET_WAIT_SEC:-120}"
RESET_POLL_SEC="${RESET_POLL_SEC:-2}"
SHOW_MODINFO=1
SKIP_LOAD=0
INSMOD_PARAMS=()

usage() {
  cat <<'EOF'
Usage: w4_deploy_module.sh [options]

Options:
  --module <path>       Local wave4.ko path (default: ../wave4.ko)
  --host <user@host>    SSH target host (default: root@192.168.45.130)
  --target <path>       Remote module path (default: /root/wave4.ko)
  --insmod-param <k=v>  Extra insmod parameter (repeatable)
  --skip-load           Do not insmod after upload
  --reset-cmd <cmd>     Reset command when unload fails (default: /root/devmem_rw warm reset, then devmem fallbacks)
  --reset-wait-sec <n>  Max wait for board to come back after reset (default: 120)
  --reset-poll-sec <n>  Poll interval while waiting reset (default: 2)
  --ssh-cmd <command>   SSH command with options
  --no-modinfo          Skip remote modinfo print
  -h, --help            Show this help

Env overrides:
  TARGET_HOST, TARGET_MODULE, SSH_CMD, RESET_CMD, RESET_WAIT_SEC, RESET_POLL_SEC
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
  --module)
    LOCAL_MODULE="$2"
    shift 2
    ;;
  --host)
    TARGET_HOST="$2"
    shift 2
    ;;
  --target)
    TARGET_MODULE="$2"
    shift 2
    ;;
  --insmod-param)
    INSMOD_PARAMS+=("$2")
    shift 2
    ;;
  --skip-load)
    SKIP_LOAD=1
    shift
    ;;
  --reset-cmd)
    RESET_CMD="$2"
    shift 2
    ;;
  --reset-wait-sec)
    RESET_WAIT_SEC="$2"
    shift 2
    ;;
  --reset-poll-sec)
    RESET_POLL_SEC="$2"
    shift 2
    ;;
  --ssh-cmd)
    SSH_CMD="$2"
    shift 2
    ;;
  --no-modinfo)
    SHOW_MODINFO=0
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

if [[ ! -f "$LOCAL_MODULE" ]]; then
  echo "missing module: $LOCAL_MODULE" >&2
  exit 1
fi

read -r -a ssh_argv <<<"$SSH_CMD"

ssh_try_unload_cmd='set -e
killall -q -9 v4l2-ctl 2>/dev/null || true
if lsmod | grep -q "^wave4 "; then
  modprobe -r wave4 2>/dev/null || true
  rmmod wave4 2>/dev/null || true
fi
if lsmod | grep -q "^wave4 "; then
  exit 86
fi'

if ! "${ssh_argv[@]}" "$TARGET_HOST" "$ssh_try_unload_cmd"; then
  echo "wave4 unload failed; forcing reset with: $RESET_CMD"
  before_uptime="$("${ssh_argv[@]}" "$TARGET_HOST" "cut -d. -f1 /proc/uptime 2>/dev/null || echo -1" 2>/dev/null || echo -1)"
  have_before_uptime=0
  if [[ "$before_uptime" =~ ^[0-9]+$ ]] && (( before_uptime >= 0 )); then
    have_before_uptime=1
  fi
  "${ssh_argv[@]}" "$TARGET_HOST" "$RESET_CMD" >/dev/null 2>&1 || true

  deadline=$((SECONDS + RESET_WAIT_SEC))
  reset_ok=0
  saw_ssh_down=0
  while (( SECONDS < deadline )); do
    after_uptime="$("${ssh_argv[@]}" "$TARGET_HOST" "cut -d. -f1 /proc/uptime 2>/dev/null || echo -1" 2>/dev/null || true)"
    if [[ "$after_uptime" =~ ^[0-9]+$ ]] && (( after_uptime >= 0 )); then
      if (( have_before_uptime )); then
        if (( after_uptime < before_uptime )); then
          reset_ok=1
          break
        fi
      elif (( saw_ssh_down )); then
        reset_ok=1
        break
      fi
    else
      saw_ssh_down=1
    fi
    sleep "$RESET_POLL_SEC"
  done

  if (( ! reset_ok )); then
    echo "reset did not complete within ${RESET_WAIT_SEC}s (uptime did not roll over)" >&2
    exit 1
  fi

  if ! "${ssh_argv[@]}" "$TARGET_HOST" "true" >/dev/null 2>&1; then
    echo "target did not return after reset" >&2
    exit 1
  fi
fi

# Use checksum to avoid stale same-size copy cases.
rsync -az --checksum --progress -e "$SSH_CMD" "$LOCAL_MODULE" "$TARGET_HOST:$TARGET_MODULE"

if (( ! SKIP_LOAD )); then
INSMOD_ARGS="${INSMOD_PARAMS[*]}"
INSMOD_ARGS_B64="$(printf '%s' "$INSMOD_ARGS" | base64 -w0)"
if [[ -z "$INSMOD_ARGS_B64" ]]; then
  INSMOD_ARGS_B64="__EMPTY__"
fi
  "${ssh_argv[@]}" "$TARGET_HOST" sh -s -- "$TARGET_MODULE" "$INSMOD_ARGS_B64" <<'EOSH'
set -eu
target_module="$1"
insmod_args_b64="$2"
if [ "$insmod_args_b64" = "__EMPTY__" ]; then
  insmod_args=""
else
  insmod_args="$(printf '%s' "$insmod_args_b64" | base64 -d)"
fi

if lsmod | grep -q "^wave4 "; then
  modprobe -r wave4 2>/dev/null || true
  rmmod wave4 2>/dev/null || true
fi
if lsmod | grep -q "^wave4 "; then
  echo "wave4 is still loaded before insmod; refusing to continue" >&2
  exit 1
fi

for m in videobuf2_common videobuf2_memops videobuf2_v4l2 videobuf2_dma_contig v4l2_mem2mem; do
  modprobe "$m" 2>/dev/null || true
done

if [ -n "$insmod_args" ]; then
  # shellcheck disable=SC2086
  insmod "$target_module" $insmod_args
else
  insmod "$target_module"
fi
EOSH
fi

if (( SHOW_MODINFO )); then
  "${ssh_argv[@]}" "$TARGET_HOST" "modinfo '$TARGET_MODULE' | grep -E '^filename|^vermagic'"
fi
