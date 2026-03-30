#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_CASE="$SCRIPT_DIR/w4_run_case.sh"

REMOTE_INPUT="${REMOTE_INPUT:-}"
BASE_NAME="${BASE_NAME:-smoke-$(date +%Y%m%d-%H%M%S)}"
REMOTE_DEVICE="${REMOTE_DEVICE:-/dev/video0}"
PIX_FMT="${PIX_FMT:-HEVC}"
SIZEIMAGE="${SIZEIMAGE:-}"
TIMEOUT_SEC="${TIMEOUT_SEC:-45}"
SKIP_DEPLOY=0
SKIP_RELOAD=0

usage() {
  cat <<'EOF'
Usage: w4_matrix_smoke.sh --input <remote bitstream> [options]

Options:
  --input <path>          Bitstream path on target board (required)
  --base-name <name>      Prefix for case directories
  --device <node>         Video node (default: /dev/video0)
  --pixfmt <fmt>          Bitstream format for OUT queue (default: HEVC)
  --sizeimage <bytes>     sizeimage override for generated v4l2 command
  --timeout-sec <n>       Per-case timeout (default: 45)
  --skip-deploy           Skip module deploy after first case
  --skip-reload           Skip module reload for all cases
  -h, --help              Show this help

Environment pass-through:
  TARGET_HOST, TARGET_MODULE, SSH_CMD, REMOTE_ROOT, LOCAL_ROOT, W4_BASE_PARAMS
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
  --input)
    REMOTE_INPUT="$2"
    shift 2
    ;;
  --base-name)
    BASE_NAME="$2"
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
  --timeout-sec)
    TIMEOUT_SEC="$2"
    shift 2
    ;;
  --skip-deploy)
    SKIP_DEPLOY=1
    shift
    ;;
  --skip-reload)
    SKIP_RELOAD=1
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

if [[ -z "$REMOTE_INPUT" ]]; then
  echo "--input is required" >&2
  usage
  exit 1
fi

common_args=(
  --input "$REMOTE_INPUT"
  --device "$REMOTE_DEVICE"
  --pixfmt "$PIX_FMT"
  --timeout-sec "$TIMEOUT_SEC"
)

if [[ -n "$SIZEIMAGE" ]]; then
  common_args+=(--sizeimage "$SIZEIMAGE")
fi

cases=(
  "baseline|"
  "secaxi_off|w4_dec_sec_axi_mask=0"
  "bs_swap31|w4_bs_data_swap=1 w4_bs_endian=31"
  "cmdopt0|w4_init_seq_cmd_opt=0"
)

summary=""
overall_rc=0
first_case=1

for row in "${cases[@]}"; do
  case_name="${row%%|*}"
  params="${row#*|}"

  args=("${common_args[@]}" --name "${BASE_NAME}-${case_name}")

  if (( SKIP_RELOAD )); then
    args+=(--skip-reload)
  fi

  if (( SKIP_DEPLOY )) || (( first_case == 0 )); then
    args+=(--skip-deploy)
  fi

  if [[ -n "$params" ]]; then
    # shellcheck disable=SC2206
    param_list=($params)
    for p in "${param_list[@]}"; do
      args+=(--param "$p")
    done
  fi

  echo "=== case: $case_name ==="
  set +e
  "$RUN_CASE" "${args[@]}"
  rc=$?
  set -e

  summary+="$case_name:$rc"$'\n'
  if (( rc != 0 )); then
    overall_rc=1
  fi
  first_case=0
done

echo
echo "matrix summary"
printf '%s' "$summary"

exit "$overall_rc"
