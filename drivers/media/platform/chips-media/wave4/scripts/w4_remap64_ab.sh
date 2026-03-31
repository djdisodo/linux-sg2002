#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_CASE="$SCRIPT_DIR/w4_run_case.sh"

INPUT="${INPUT:-/root/teststreams/girlshy.h265}"
PREFIX="${PREFIX:-cont-remap64-ab-$(date +%Y%m%d-%H%M%S)}"
PIX_FMT="${PIX_FMT:-HEVC}"
SIZEIMAGE="${SIZEIMAGE:-}"
TIMEOUT_SEC="${TIMEOUT_SEC:-45}"
REMAP64_VALUE="${REMAP64_VALUE:-0x01000020}"

usage() {
  cat <<'EOF'
Usage: w4_remap64_ab.sh [options]

Runs two decode cases:
  1) baseline (no w4_vc_remap64 override)
  2) remap64  (with w4_vc_remap64=<value>)

Options:
  --input <remote path>      Bitstream path on target (default: /root/teststreams/girlshy.h265)
  --prefix <name>            Case-name prefix
  --pixfmt <fmt>             Output queue pixfmt (default: HEVC)
  --sizeimage <bytes>        Optional sizeimage override
  --timeout-sec <n>          Per-case timeout in seconds (default: 45)
  --remap64 <value>          Value for w4_vc_remap64 (default: 0x01000020)
  -h, --help                 Show this help

Environment pass-through:
  TARGET_HOST, TARGET_MODULE, SSH_CMD, REMOTE_ROOT, LOCAL_ROOT, W4_BASE_PARAMS
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
  --input)
    INPUT="$2"
    shift 2
    ;;
  --prefix)
    PREFIX="$2"
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
  --remap64)
    REMAP64_VALUE="$2"
    shift 2
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

common_args=(
  --input "$INPUT"
  --pixfmt "$PIX_FMT"
  --timeout-sec "$TIMEOUT_SEC"
)

if [[ -n "$SIZEIMAGE" ]]; then
  common_args+=(--sizeimage "$SIZEIMAGE")
fi

echo "=== baseline ==="
"$RUN_CASE" \
  "${common_args[@]}" \
  --name "${PREFIX}-baseline" \
  --param "w4_init_seq_dump_regs=1"

echo "=== remap64 ==="
"$RUN_CASE" \
  "${common_args[@]}" \
  --name "${PREFIX}-remap64" \
  --skip-deploy \
  --param "w4_init_seq_dump_regs=1" \
  --param "w4_vc_remap64=${REMAP64_VALUE}"

echo
echo "completed A/B cases:"
echo "  ${PREFIX}-baseline"
echo "  ${PREFIX}-remap64"
