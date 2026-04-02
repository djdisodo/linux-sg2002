# Wave4 Runtime PM Debug Test Plan

## Goal
Isolate whether async encode failures are caused by runtime PM suspend/resume transitions or by unrelated encode path issues.

## Scope
- Target board: `root@58.235.71.8`
- Device: `/dev/video1`
- Input: `/root/vpu-test/in_416x240_yu12.yuv`
- Encoder mode under test: async (`w4_sync_enc_pic_done=0`)
- Runtime PM module knob: `w4_forbid_runtime_pm=0` unless noted

## Preconditions
1. Build and deploy latest module:
```bash
cd /root/sg2002/linux-upstream/drivers/media/platform/chips-media/wave4/scripts
./w4_build_module.sh
```
2. Ensure target PM sysfs path exists:
```bash
ssh root@58.235.71.8 'ls /sys/bus/platform/devices/b020000.video-codec/power'
```
3. Use one fixed ffmpeg command for all PM experiments:
```bash
ffmpeg -hide_banner -loglevel info -y \
  -f rawvideo -pix_fmt yuv420p -s:v 416x240 -r 30 \
  -i /root/vpu-test/in_416x240_yu12.yuv \
  -frames:v 60 \
  -c:v hevc_v4l2m2m \
  -num_output_buffers 6 -num_capture_buffers 6 \
  -f hevc /root/vpu-test/<case>/out.h265
```

## Phase A: PM enabled, transitions blocked
Purpose: prove whether failures still happen when runtime PM framework is active but suspend/resume transitions are prevented.

Setup:
```bash
ssh root@58.235.71.8 'echo on > /sys/bus/platform/devices/b020000.video-codec/power/control'
```

Run:
- 10 async ffmpeg iterations
- Module params: `w4_sync_enc_pic_done=0`

Expected:
- If stable: failures likely require suspend/resume transition.
- If unstable: root cause is elsewhere (driver queueing, ffmpeg interaction, or PM refcount bug).

## Phase B: PM enabled, normal autosuspend
Purpose: baseline with regular autosuspend policy.

Setup:
```bash
ssh root@58.235.71.8 '
  echo auto > /sys/bus/platform/devices/b020000.video-codec/power/control
  echo 500 > /sys/bus/platform/devices/b020000.video-codec/power/autosuspend_delay_ms
'
```

Run:
- 10 async ffmpeg iterations

Expected:
- Compare failure rate vs Phase A.

## Phase C: PM enabled, aggressive autosuspend
Purpose: maximize transition frequency to amplify suspend/resume bugs.

Setup:
```bash
ssh root@58.235.71.8 '
  echo auto > /sys/bus/platform/devices/b020000.video-codec/power/control
  echo 10 > /sys/bus/platform/devices/b020000.video-codec/power/autosuspend_delay_ms
'
```

Run:
- 20 async ffmpeg iterations

Expected:
- Higher failure probability if resume path or PM refcount is broken.

## Phase D: Control run with PM forbidden
Purpose: verify known-good behavior for comparison.

Run:
- 5 async ffmpeg iterations
- Module params: `w4_sync_enc_pic_done=0 w4_forbid_runtime_pm=1`

Expected:
- Should pass consistently.

## Data To Capture Per Iteration
- `v4l2.rc`
- output size (`output_size.txt`)
- `module_params.log`
- `dmesg.log`
- PM state snapshot from target:
```bash
cat /sys/bus/platform/devices/b020000.video-codec/power/runtime_status
cat /sys/bus/platform/devices/b020000.video-codec/power/runtime_active_time
cat /sys/bus/platform/devices/b020000.video-codec/power/runtime_suspended_time
cat /sys/bus/platform/devices/b020000.video-codec/power/control
cat /sys/bus/platform/devices/b020000.video-codec/power/autosuspend_delay_ms
```

## Pass/Fail Criteria
- Pass: no ffmpeg `VIDIOC_STREAMON failed on capture context`, no kernel oops/warnings, non-zero output for all iterations in a phase.
- Fail: any `VIDIOC_STREAMON` failure, zero-sized output, kernel fault/warning tied to wave4.

## Priority After This Plan
1. Run Phase A first.
2. If Phase A passes and B/C fail, focus on runtime suspend/resume path.
3. Patch known PM refcount bug in `wave5_vpu_enc_close()` error paths.
4. Re-run Phase B/C to confirm improvement.

## Execution Notes (2026-04-02)
- `pmA-on-20260402-224258` (Phase A style, `control=on`, async, PM allowed):
  - result: `ok=1 fail=9` (1 run was transport timeout/NA)
  - dominant failure: ffmpeg `VIDIOC_STREAMON failed on capture context`
  - representative kernel failure line: `w4 enc seq_info failed ... Sequence not found: -5`
- `pmA2-on-refcntfix-20260402-225009` (after `enc_close` PM refcount fix):
  - result: `ok=3 fail=7`
  - still unstable, but improved pass rate vs previous run
- `pmA3-on-pmguard-20260402-230239` (after guarding PM resume return in encoder paths):
  - result: `ok=2 fail=8` (2 transport timeout/NA included in fail count)
  - still unstable when PM is allowed
- `pmD-forbid-refcntfix-20260402-225638` (Phase D control, PM forbidden):
  - result: `ok=5 fail=0` (+1 transport NA entry from network timeout)
  - indicates async encode is stable when runtime PM is disabled
- `pmNR-on-singleload-20260402-231826` (PM allowed, single module load, no reload between runs):
  - result: `ok=6 fail=0`
  - no `VIDIOC_STREAMON failed`, no `Sequence not found`
  - strong indication that the dominant instability is in module reload/probe resident-fw re-init path, not steady-state async encode operation
- `pmA4-reload-on-20260402-233555` (PM allowed, `control=on`, reload each iteration):
  - loop summary reported `ok=2 fail=4`, but failures were dominated by SSH/transport timeouts during wrapper/log collection
  - captured case logs (`r2/r3/r4/r6`) show `v4l2.rc=0`, output size `2205`, and no `Sequence not found`
  - this run is inconclusive for PM behavior due network transport noise
- `pmNR2-on-singleload-20260402-233900` (PM allowed, `control=on`, single load/no reload):
  - result: `ok=6 fail=0`
  - all runs had `v4l2.rc=0`, output size `2205`, and no sequence errors
  - reinforces that no-reload path is stable when suspend/resume transitions are blocked
- `pmC2-auto10-singleload-20260402-323487385` (PM allowed, `control=auto`, `autosuspend_delay_ms=10`, single load/no reload):
  - wrapper summary: `ok=6 fail=0`; strict result: `5/6` good outputs
  - `r6` had `v4l2.rc=0` but output size `0` and dmesg:
    - `w4 enc seq_info failed ...`
    - `Sequence not found: -5`
  - `runtime_status` observed as `suspended` after each iteration, confirming suspend/resume transitions are happening
  - indicates runtime PM path is still unstable under aggressive autosuspend even without module reload
- PM fix under test: hold runtime-PM ref across async ENC job until `finish_encode` callback (release via race-safe guard in completion/streamoff paths)
- `pmC3-auto10-singleload-pmhold-20260402-1576415209` (after async PM ref-hold patch):
  - wrapper summary: `ok=8 fail=0`
  - strict result: `8/8` (`v4l2.rc=0`, output size `2205`, no `Sequence not found`)
  - same aggressive autosuspend setup (`control=auto`, `autosuspend_delay_ms=10`)
  - strongly suggests previous autosuspend instability was caused by dropping PM ref too early in async mode
- `pmC3b-auto10-smoke-20260402-244658322` (post-fix regression smoke):
  - strict result: `3/3` clean outputs, no sequence errors
