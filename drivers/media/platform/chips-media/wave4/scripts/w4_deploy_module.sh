#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_HOST="${TARGET_HOST:-root@192.168.45.130}"
TARGET_MODULE="${TARGET_MODULE:-/root/wave4.ko}"
SSH_CMD="${SSH_CMD:-ssh -o StrictHostKeyChecking=no}"
LOCAL_MODULE="$SCRIPT_DIR/../wave4.ko"
SHOW_MODINFO=1

usage() {
  cat <<'EOF'
Usage: w4_deploy_module.sh [options]

Options:
  --module <path>       Local wave4.ko path (default: ../wave4.ko)
  --host <user@host>    SSH target host (default: root@192.168.45.130)
  --target <path>       Remote module path (default: /root/wave4.ko)
  --ssh-cmd <command>   SSH command with options
  --no-modinfo          Skip remote modinfo print
  -h, --help            Show this help

Env overrides:
  TARGET_HOST, TARGET_MODULE, SSH_CMD
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

rsync -az --progress -e "$SSH_CMD" "$LOCAL_MODULE" "$TARGET_HOST:$TARGET_MODULE"
if (( SHOW_MODINFO )); then
  read -r -a ssh_argv <<<"$SSH_CMD"
  "${ssh_argv[@]}" "$TARGET_HOST" "modinfo '$TARGET_MODULE' | grep -E '^filename|^vermagic'"
fi
