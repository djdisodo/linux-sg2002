#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WAVE4_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
KERNEL_SRC="${KERNEL_SRC:-$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)}"
OUT_DIR="${OUT_DIR:-$KERNEL_SRC/out-sg2002-milkv}"
ARCH="${ARCH:-riscv}"
CROSS_COMPILE="${CROSS_COMPILE:-riscv64-linux-gnu-}"
JOBS="${JOBS:-$(nproc)}"

usage() {
  cat <<'EOF'
Usage: w4_build_module.sh [options]

Options:
  --kernel-src <path>      Kernel source root (default: git top-level)
  --out-dir <path>         Kernel O= out dir (default: <kernel>/out-sg2002-milkv)
  --arch <arch>            Build arch (default: riscv)
  --cross-compile <pref>   Toolchain prefix (default: riscv64-linux-gnu-)
  -j, --jobs <n>           Parallel jobs (default: nproc)
  -h, --help               Show this help

Env overrides:
  KERNEL_SRC, OUT_DIR, ARCH, CROSS_COMPILE, JOBS
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
  --kernel-src)
    KERNEL_SRC="$2"
    shift 2
    ;;
  --out-dir)
    OUT_DIR="$2"
    shift 2
    ;;
  --arch)
    ARCH="$2"
    shift 2
    ;;
  --cross-compile)
    CROSS_COMPILE="$2"
    shift 2
    ;;
  -j|--jobs)
    JOBS="$2"
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

if [[ -z "$KERNEL_SRC" || ! -d "$KERNEL_SRC" ]]; then
  echo "invalid kernel source path: $KERNEL_SRC" >&2
  exit 1
fi

if [[ ! -d "$OUT_DIR" ]]; then
  echo "missing out dir: $OUT_DIR" >&2
  echo "build kernel first, or pass --out-dir to the configured O= tree" >&2
  exit 1
fi

echo "building wave4 module"
echo "  kernel src: $KERNEL_SRC"
echo "  out dir   : $OUT_DIR"
echo "  module dir: $WAVE4_DIR"

make -C "$KERNEL_SRC" \
  O="$OUT_DIR" \
  M="$WAVE4_DIR" \
  ARCH="$ARCH" \
  CROSS_COMPILE="$CROSS_COMPILE" \
  -j"$JOBS" \
  modules

echo "done: $WAVE4_DIR/wave4.ko"
