# Wave4 Test Scripts

These scripts replace the repetitive manual flow for build/deploy/reload/decode testing on Duo 256M.

## Defaults

- Target board: `root@192.168.45.130`
- Remote module path: `/root/wave4.ko`
- Kernel out dir: `out-sg2002-milkv`
- Remote log root: `/root/vpu-test`
- Local pulled logs: `drivers/media/platform/chips-media/wave4/test-logs`

Override using script options or environment variables:
`TARGET_HOST`, `TARGET_MODULE`, `SSH_CMD`, `OUT_DIR`, `REMOTE_ROOT`, `LOCAL_ROOT`.

## Scripts

- `w4_build_module.sh`: build `wave4.ko` from current source.
- `w4_deploy_module.sh`: deploy `wave4.ko` by `rsync`.
- `w4_run_case.sh`: run one decode case (optional deploy + reload + v4l2 + logs).
- `w4_matrix_smoke.sh`: run a small preset matrix of candidate module params.

## Typical Usage

Build:

```bash
./w4_build_module.sh
```

Deploy only:

```bash
./w4_deploy_module.sh
```

Single case:

```bash
./w4_run_case.sh \
  --name hevc-baseline \
  --input /mnt/storage/sintel_272p_head4m.h265 \
  --param w4_init_seq_dump_regs=1
```

Single case with custom command:

```bash
./w4_run_case.sh \
  --name custom-run \
  --skip-deploy \
  --v4l2-cmd "v4l2-ctl -d /dev/video0 --verbose --stream-mmap=6 --stream-out-mmap=6 --stream-from=/mnt/storage/in.h265 --stream-to=/root/vpu-test/custom-run/out.yuv --stream-poll"
```

Matrix smoke:

```bash
./w4_matrix_smoke.sh \
  --input /mnt/storage/sintel_272p_head4m.h265 \
  --sizeimage 4194304
```

## Notes

- `w4_run_case.sh` defaults `W4_BASE_PARAMS` to:
  `w4_use_reserved_mem=1 w4_wait_irq_cap_ms=5000`
- Disable base params by running:
  `W4_BASE_PARAMS='' ./w4_run_case.sh ...`
- Each case creates:
  - remote: `/root/vpu-test/<case>`
  - local copy: `.../wave4/test-logs/<case>` (unless `--no-pull`)
