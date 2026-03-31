# Wave420L BSP Compare And Trace Notes

Date: 2026-03-30
Target: Milk-V Duo 256M (SG2002, Wave420L HEVC decode)

## Scope

Manual compare between:

- Current upstream port:
  - `drivers/media/platform/chips-media/wave4/wave5-vpu.c`
  - `drivers/media/platform/chips-media/wave4/wave5-hw.c`
  - `drivers/media/platform/chips-media/wave4/wave5-vpuapi.c`
  - `drivers/media/platform/chips-media/wave4/wave5-vpu-dec.c`
- BSP reference:
  - `osdrv/interdrv/cvi_vc_drv/vcodec/vpuapi/wave/wave4/wave4.c`
  - `osdrv/interdrv/cvi_vc_drv/vcodec/vpuapi/wave/common/common.c`
  - `osdrv/interdrv/cvi_vc_drv/vcodec/vpuapi/vpuapi.c`
  - `osdrv/interdrv/vcodec/cvi_vcodec.c` (platform bring-up context)

## Runtime Symptoms Seen During Porting

1. `w4 wait_interrupt timeout ... cmd=0x4 ... vcpu_pc=0x3148`, followed by seq-init failure.
2. Kernel Oops in `list_del()` from `flag_last_buffer_done()` path.
3. Kernel Oops in `wave5_vpu_dec_device_run+0x...` after seq-init timeout.
4. When Oops happens in kworker path, WLAN often falls out shortly after (likely secondary effect).

## Decode Init Trace (BSP)

1. `VPU_DecIssueSeqInit()` (`vpuapi.c:773`)
2. `ProductVpuDecInitSeq()`
3. `Wave4VpuDecInitSeq()` (`wave4.c:212`)
4. `PrepareDecodingPicture(DEC_PIC_HDR)` programs:
   - `W4_BS_START_ADDR`, `W4_BS_SIZE`, `W4_BS_RD_PTR`, `W4_BS_WR_PTR`
   - secondary AXI, work/temp buffers, user buffers
5. `Wave4BitIssueCommand(DEC_PIC_HDR)`
6. `VPU_DecCompleteSeqInit()` (`vpuapi.c:805`) waits/collects:
   - `ProductVpuWaitInterrupt()` -> `Wave4VpuWaitInterrupt()` (`common.c:569`)
   - `ProductVpuDecGetSeqInfo()` -> `Wave4VpuDecGetSeqInfo()` (`wave4.c:498`)

## Decode Init Trace (Current Port)

1. V4L2 M2M worker `wave5_vpu_dec_device_run()` (`wave5-vpu-dec.c:1674`)
2. `initialize_sequence()` (`wave5-vpu-dec.c:1626`)
3. `wave5_vpu_dec_issue_seq_init()` (`wave5-vpuapi.c:292`)
4. `wave4_vpu_dec_init_seq()` (`wave5-hw.c:963`)
5. `wave4_vpu_wait_interrupt()` (`wave5-vpu.c:57`)
6. `wave5_vpu_dec_complete_seq_init()` (`wave5-vpuapi.c:308`)
7. `wave4_vpu_dec_get_seq_info()` (`wave5-hw.c:1123`)

## Manual Delta Table

### 1) Platform bring-up (reset/clock/remap/irq)

- BSP: Vcodec stack enables clocks, reset handling, VC remap windows, IRQ wiring.
- Current port: same class of setup exists in `wave5-vpu.c`:
  - reset deassert + clock bulk enable
  - DRAM remap programming + VC SRAM share mux programming
  - threaded IRQ or polling fallback
- Status: **Mostly aligned**.

### 2) Interrupt wait semantics

- BSP `Wave4VpuWaitInterrupt()` waits with caller timeout (`VPU_DEC_TIMEOUT` path typically 10s).
- Current `wave4_vpu_wait_interrupt()` clamps wait to max 3000ms.
- Status: **Diverged**.
- Risk: **High**. False timeout can push seq-init into failure path even if firmware is late but alive.

### 3) INIT_SEQ bitstream RD/WR programming

- BSP `Wave4VpuDecInitSeq()` writes absolute DMA addresses to `W4_BS_RD_PTR/W4_BS_WR_PTR`.
- Current `wave4_vpu_dec_init_seq()` currently contains temporary conversion to ring offsets before register write.
- Status: **Diverged (temporary experiment still present)**.
- Risk: **High**. Decode path and other code paths still assume absolute pointers.

### 4) Bitstream flag update behavior

- BSP `Wave4VpuDecSetBitstreamFlag()` focuses on `W4_BS_OPTION` update when running.
- Current `wave4_vpu_dec_set_bitstream_flag()` writes both `BS_OPTION` and `BS_WR_PTR` every call.
- Status: **Diverged**.
- Risk: **Medium**. Possible pointer update race against command sequencing.

### 5) Ring buffer room accounting

- BSP `VPU_DecGetBitstreamBuffer()` uses `prevFrameEndPos` and margin rules (`bitstreamBufferMargin`) for Wave4 class.
- Current `wave5_vpu_dec_get_bitstream_buffer()` uses simplified cached `rd_ptr/wr_ptr` distance only.
- Status: **Diverged**.
- Risk: **Medium**. Can skew host-side feed/drain behavior and edge conditions.

### 6) Streamoff/drain behavior in V4L2 glue

- Current code has `max_drain_attempts = 0` and `max_drain_outputs = 0` in stop/streamoff paths.
- This effectively skips drain loops, then flush/reset proceeds immediately.
- BSP userspace API flow does not map 1:1 to V4L2 M2M queue teardown, so this is port-local behavior.
- Status: **Port-specific divergence**.
- Risk: **Medium/High** under repeated init-fail + streamoff cycles.

### 7) M2M last-buffer handling after failures

- Oops stack showed `list_del` from `flag_last_buffer_done()` path in prior runs.
- Current code includes one-shot guards (`has_stopped` / `next_buf_last`) but failures still cascade in other paths.
- Status: **Partially mitigated, not fully stable**.

### 8) Wave4 common-memory sizing (code/temp split)

- BSP Wave420L constants:
  - `WAVE4_MAX_CODE_BUF_SIZE = 256 KiB`
  - `DEFAULT_TEMPBUF_SIZE = 512 KiB`
  - total common memory = `768 KiB`
- Current port previously used:
  - `W4_MAX_CODE_BUF_SIZE = 1 MiB`
  - `W4_TEMPBUF_SIZE = 1 MiB`
  - total common memory = `2 MiB`
- Status: **Diverged (fixed in current tree)**.
- Risk: **Medium/High**. Larger non-BSP layout can perturb Wave4 command/runtime assumptions around temp workspace and remap sizing.

## Likely Failure Chain (Current Evidence)

1. INIT_SEQ command issued.
2. Interrupt wait times out early (3s cap path) with no reason bits.
3. Sequence completion not reached; state transitions continue in error handling/streamoff.
4. Queue teardown and ring state become inconsistent across retries.
5. Later worker run hits invalid queue/list/pointer state and Oops.

## Priority Fix Order (from comparison)

1. Remove INIT_SEQ RD/WR offset conversion experiment; keep absolute DMA pointer semantics.
2. Remove or relax the 3s cap in `wave4_vpu_wait_interrupt()` to BSP-equivalent timeout behavior.
3. Align `wave4_vpu_dec_set_bitstream_flag()` semantics closer to BSP (option update first; WR_PTR update only where required).
4. Reintroduce Wave4-style bitstream room rules (`prevFrameEndPos` + margin) or equivalent safe accounting.
5. Harden streamoff/drain path for init-fail retry cycles (do not rely on zero-attempt loops).

## Validation Checklist After Each Patch

1. `rmmod wave4; insmod wave4.ko`
2. Run one HEVC decode (`stream-count=1`) and capture dmesg.
3. Confirm:
   - no `wait_interrupt timeout` for INIT_SEQ
   - no `Unable to handle kernel paging request`
   - output file size > 0
4. Repeat 10x open/decode/streamoff cycle to stress queue teardown.

## Current Candidates (2026-03-30, post-endian fix)

1. VPU DRAM read path mismatch (address translation / AXI visibility):
   - CPU ring head bytes are valid VPS/SPS.
   - Firmware-side debug still reports `bs_data=0x0`, `bus_busy=0x4`, then `fail_reason=0x1`, `dec_err=0x1000000`.
2. INIT_SEQ register sequencing delta vs BSP:
   - Need strict parity for `W4_BS_*`, command option, and work/temp/user report programming order.
3. Secondary AXI configuration:
   - Current runtime sec-axi is enabled with all decoder bits.
   - A/B test with sec-axi fully disabled still reproduces identical seq-init failure.
   - Status: likely **not the primary root cause**.
4. DRAM remap state retention:
   - `0x0B050064` bit24 is set, but runtime path may still differ from BSP bus context.

### Live register snapshot (during decode worker)

- `W4_ADDR_SEC_AXI` (`0x0B020150`) = `0x00000000`
- `W4_SEC_AXI_SIZE` (`0x0B020154`) = `0x00019400`
- `W4_USE_SEC_AXI` (`0x0B020158`) = `0x00008201` (bit0, bit9, bit15 enabled)
- `0x0B050064` (VC remap) = `0xe994be6d` (bit24 set)
- `0x0B030024` (VC SRAM share) = `0x00000002`

## Sec-AXI A/B Control Test (2026-03-30)

Test setup:

- Added runtime module parameter `w4_dec_sec_axi_mask` in `wave5-hw.c`.
- Same stream, same V4L2 command path, only sec-axi mask changed.

Case A (`w4_dec_sec_axi_mask=0x8201`):

- Runtime regs: `W4_SEC_AXI_SIZE=0x00019400`, `W4_USE_SEC_AXI=0x00008201`.
- Failure signature:
  - `w4 fio debug: bs_data=0x0 bus_busy=0x4 bit_pc=0x29c`
  - `seq init failed: fail_reason=0x1 dec_err=0x1000000 ... bs_param=0x20f`

Case B (`w4_dec_sec_axi_mask=0`):

- Runtime regs: `W4_SEC_AXI_SIZE=0x00000000`, `W4_USE_SEC_AXI=0x00000000`.
- Failure signature is effectively identical:
  - `w4 fio debug: bs_data=0x0 bus_busy=0x4 bit_pc=0x29c`
  - `seq init failed: fail_reason=0x1 dec_err=0x1000000 ... bs_param=0x20f`

Conclusion:

- Sec-axi on/off does change programmed sec-axi registers as expected.
- It does **not** change the observed init-seq failure mode.
- Focus should move to init command sequencing and memory/bus visibility parity vs BSP.

## Additional Notes (2026-03-30, later)

1. BSP-alignment patch applied:
   - `wave5-vpu-dec.c`: clear Wave4 decode ring DMA memory immediately after allocation.
   - `wave5-hw.c`: `wave4_vpu_dec_set_bitstream_flag()` now writes `BS_OPTION/BS_WR_PTR` only when `running==true`, matching BSP `Wave4VpuDecSetBitstreamFlag()`.

2. Remap register variability observed across reloads:
   - Earlier snapshot: `0x0B050064 = 0xe994be6d`.
   - Later snapshot: `0x0B050064 = 0x01000020`.
   - Both include bit24 set, but upper/lower fields differ significantly. This keeps DRAM/VC remap programming as an open platform candidate.

3. BSP constant correction (local `jh7110_soft_3rdpart/wave420l`):
   - `WAVE4_MAX_CODE_BUF_SIZE = 1 MiB`
   - `DEFAULT_TEMPBUF_SIZE = 1 MiB`
   - `WAVE4_TEMPBUF_OFFSET = 1 MiB`
   - Port constants were updated back to `W4_MAX_CODE_BUF_SIZE=1 MiB` and `W4_TEMPBUF_SIZE=1 MiB` to restore layout parity for code/temp windows.

4. Added INIT_SEQ runtime override knobs for controlled A/B tests (no source rewrite per test):
   - `w4_init_seq_bs_ring` (default `1`): toggles `W4_BS_PARAM` ring-buffer bit.
   - `w4_init_seq_bs_opt` (default `-1`): raw override for `W4_BS_OPTION`.
   - `w4_init_seq_cmd_opt` (default `-1`): raw override for `W4_COMMAND_OPTION`.
   - Rationale: quickly test parser-mode assumptions around `INIT_SEQ` without stacking temporary patches.

## New A/B Results (2026-03-30, cap=5s runs)

Test method:

- Force short wait with `w4_wait_irq_cap_ms=5000` to avoid 60s blocking state in `wave4_vpu_wait_interrupt()`.
- Same HEVC input (`sintel_272p_head4m.h265`), same `v4l2-ctl` invocation.
- Compare only one variable at a time.

### 1) VC remap override (`w4_vc_remap64`)

- Baseline (`w4_vc_remap64=-1`) and forced (`w4_vc_remap64=0x01000020`) both fail identically:
  - `fail_reason=0x1`
  - `dec_err=0x1000000`
  - `bs_data=0x0`
  - ring head bytes still show valid VPS/SPS prefix (`00 00 00 01 40 01 ...`).
- Conclusion: forcing `0x0B050064` to `0x01000020` does **not** resolve init-seq failure.

### 2) BS pointer write-mode experiment (now removed)

- Failure persists (`fail_reason=0x1`, `dec_err=0x1000000`).
- `bs_wr` log becomes offset-like (`0x1fa40`) but no decode progress.
- Conclusion: pointer-as-offset is not a fix.

### 3) Ring-buffer bit (`w4_init_seq_bs_ring=0`)

- `bs_param` changes from `0x20f` to `0x0f` as expected.
- Failure signature still unchanged (`fail_reason=0x1`, `dec_err=0x1000000`, `bs_data=0x0`).
- Conclusion: ring bit is not root cause.

### 4) Command option override (`w4_init_seq_cmd_opt=0`)

- Behavior changes:
  - no `seq init failed: fail_reason=0x1` line
  - `SOURCE CHANGE EVENT` seen in userspace
  - then `wave5_vpu_dec_start_streaming: no support for 0 bit depth`
- Conclusion: command option affects flow, but still not decoding; `cmd_opt=0` yields invalid seq info (`luma_bitdepth=0`), so this is not a valid fix.

### 5) Endian mode using BSP stream-endian input (`w4_bs_endian=16`)

- Ends up with same effective `bs_param=0x20f` and same failure signature as baseline.
- Conclusion: this mode does not change outcome.

## Working hypothesis after latest A/B

1. Failure is stable before successful sequence parse; data feed is visible on CPU side but parser path still reports `bs_data=0x0`.
2. Pure INIT_SEQ knob changes (ring/endian/pointer/remap64) do not clear failure.

## DT Reserved-Memory Status (2026-03-30, live board check)

- Runtime check on board (`/proc/device-tree/soc/video-codec@b020000`) showed `memory-region` was still **missing**.
- Driver-side `of_reserved_mem_device_init()` hookup is now present, but cannot activate without that DT property.
- Added board DTS update in `arch/riscv/boot/dts/sophgo/sg2002-milkv-duo256m.dts`:
  - reserved region `vpu_reserved: region@8c000000` (`shared-dma-pool`, `reusable`, 32 MiB)
  - `&vpu { memory-region = <&vpu_reserved>; }`
- Next verification after DTB reboot:
  - dmesg contains `attached memory-region DMA pool for wave4 allocations`
  - decode retry checks if seq-init failure signature changes.

## New Candidate (2026-03-30, pending target run)

### BSP parity gap found in bitstream payload writes

- BSP `vdi_write_memory()` calls `swap_endian()` on payload before storing into VPU-visible memory.
- Current port decode path (`wave5-vpu-dec.c` ring write path) used raw `memcpy` semantics.
- This means `W4_BS_PARAM` endian nibble and actual payload layout could be inconsistent.

### Local patch prepared

- Added `w4_bs_data_swap` module parameter in decoder path:
  - `0` (default): keep current raw payload write.
  - `1`: apply BSP-style byte/word/dword/lword swaps before ring write, derived from `w4_bs_endian` mode.
- Added shared helper `wave4_get_bs_endian_mode()` in `wave5-hw.c` so decode feeder can use the same runtime endian mode source as register setup.
- Patch is compile-verified locally; target A/B run was delayed by temporary board network loss.

### Planned A/B once target is back

1. baseline: `w4_bs_data_swap=0`
2. parity candidate: `w4_bs_data_swap=1 w4_bs_endian=31`
3. control: `w4_bs_data_swap=1 w4_bs_endian=16`

Success criterion remains unchanged: INIT_SEQ completion without `fail_reason=0x1/dec_err=0x1000000` and non-zero decode output.
3. Next likely root-cause area is platform memory visibility/translation path not covered by current single-register remap override (or an unported Wave4 query/result path difference that leaves parser status invalid).

## New candidate patch (2026-03-30, local build ready)

Change:

- `wave5-vdi.c`: `wave5_vdi_allocate_dma_memory()` now prefers coherent allocation with `GFP_KERNEL | GFP_DMA`, with fallback to `GFP_KERNEL`.

Reasoning:

- Wave420L BSP Linux VDI fallback allocator uses `GFP_DMA` for coherent buffers.
- Current failures show parser-side no-data symptoms (`bs_data=0x0`, `bus_busy=0x4`) despite CPU-visible bitstream contents.
- This points to a potential DMA address-range visibility issue between host allocations and VPU bus access.

Status:

- Module rebuild succeeded.
- Runtime A/B test pending board reconnect/reboot.

## Stability parity patch queued (2026-03-30, not yet board-verified)

Applied in `wave5-hw.c` (`wave4_vpu_dec_get_result()`):

1. Add RET_SUCCESS gate before consuming PIC result registers; return `-EIO` on firmware failure with decoded fail/error registers logged.
2. Decode display/decoded indices using Wave4 packed-index semantics:
   - linear index from high 16 bits when linear display buffers are active.
   - tiled index from low 16 bits (`index_frame_decoded_for_tiled`).
3. Mask `sequence_changed` with `0x7fffffff` as in BSP.
4. Align `temporal_id` extract to full low byte (`& 0xff`).
5. Align sequence-change width/height fallback behavior with BSP (`0x0` when decoded index is invalid, otherwise keep prior sequence dimensions).

Rationale:

- Prior path consumed raw 32-bit packed indices as direct frame indices and did not gate on firmware decode-success. That can feed invalid indices into V4L2 queue operations on error paths and trigger teardown/list corruption crashes.

Status:

- Module builds cleanly.
- Runtime test pending board reconnect (current host cannot route to `192.168.45.130`).

## Vendor kernel config cross-check (cvitek `cvi_vcodec`, 2026-03-30)

Compared against:

- `duo-buildroot-sdk-v2/osdrv/interdrv/vcodec/hal/cv180x/cvi_vcodec_cfg.c`
- `duo-buildroot-sdk-v2/osdrv/interdrv/vcodec/vcodec_common.c`
- `duo-buildroot-sdk-v2/osdrv/interdrv/vcodec/cvi_vcodec.c`

Observed behavior in vendor stack:

1. Explicitly configures VC SRAM mux (`ctrl + 0x24`) to H265 path (`0x2`) for Wave4.
2. Enables multiple codec clocks (`vc_src0/cfg_reg_vc/axi_video_codec/h265c/apb_h265c`, etc.); may disable non-selected core clocks afterward.
3. Maps `vc_addr_remap` and `vc_sbm` windows, but no direct steady-state programming of `vc_addr_remap + 0x64` was found in this driver path.
4. Contains optional DDR remap helper (`0x03000064 bit24`), but this helper is quirk-gated and not clearly exercised in the asic quirk set used here.
5. Saves/restores VC SBM and VC CTRL regs during PM suspend/resume (`ctrl[0x10]/[0x28]/[0x40]`, `sbm[0x00]` and `sbm[0x20..]`), which suggests those windows are platform-relevant state.

Implication for upstream port:

- Current probe path already covers clocks/resets and SRAM mux plus direct DRAM remap bit24 programming.
- Remaining platform-risk candidate is incomplete parity around VC SBM / VC CTRL side-state persistence or expected boot-time pre-programming outside the VPU register block.

## Dynamic-debug snapshot (2026-03-30, clean baseline repro)

Captured with `module wave4 +p` and baseline knobs (`w4_bs_data_swap=0`):

- Ring feed before INIT_SEQ is valid:
  - `rd_ptr=wr_ptr=0x89000000` before write
  - `wave4_vpu_dec_init_seq: bs start=0x89000000 ... wr=0x8901fa40`
  - ring bytes at head show Annex-B VPS prefix.
- INIT_SEQ is issued as expected:
  - `wave5_bit_issue_command: cmd=0x40 hw=0x2 (W5_INIT_SEQ)`
- Firmware returns deterministic failure:
  - `RET_SUCCESS=0x0`, `RET_FAIL_REASON=0x1`, `W4_RET_DEC_ERR_INFO=0x1000000`
  - parser debug remains `bs_data=0x0`, `bus_busy=0x4`.
- Post-fail `W4_BS_RD_PTR` reads as `0x00100000` while `W4_BS_WR_PTR` remains absolute (`0x8901fa40`).
  - This reinforces the address-domain/visibility hypothesis over payload-content issues.

## New patch candidate (local, built; target test pending reboot)

- File: `wave5-vpu.c`
- Added module parameter:
  - `w4_dma_mask_bits` (default `32`, valid `24..32`)
- Probe now applies:
  - `dma_set_mask_and_coherent(... DMA_BIT_MASK(w4_dma_mask_bits))`
  - logs chosen mask width.

Rationale:

- Current failing bitstream/work allocations are consistently in high 32-bit physical range (`0x89xxxxxx`).
- BSP address-remap/MMU paths are sensitive to address-bit domain (bit31/bit30 modes).
- Forcing narrower DMA windows (e.g. `31`/`30`) is the next direct A/B to verify whether VPU visibility depends on allocation address band.

## Deployment note (2026-03-30, corrected)

- Found a test-deploy mismatch:
  - `out-sg2002-milkv/.../wave4.ko` was stale (older module, missing recent `w4_*` parameters).
  - Active/test module is `drivers/media/platform/chips-media/wave4/wave4.ko` (contains current wave4 debug knobs and crash guards).
- Target copy path remains `/root/wave4.ko`, but source for rsync should be the in-tree module above.

## New A/B knob added (2026-03-30, pending post-reboot run)

- `wave5-vpu.c`: `w4_use_reserved_mem` module parameter (default `1`)
  - `1`: attach DT `memory-region` pool (`of_reserved_mem_device_init()` path)
  - `0`: skip `memory-region` attach and use regular DMA allocation path (CMA/system allocator)
- Purpose:
  - Isolate whether Wave420L init-seq failure depends on reserved pool address band/visibility.
  - Run direct same-stream comparison without changing DTB between tests.

## Address-band A/B and DTS alignment (2026-03-30, late)

### Runtime matrix results

1. `w4_use_reserved_mem=1` (DT pool attached):
   - `INIT_SEQ` still fails deterministically with the same signature:
     - `fail_reason=0x1`
     - `dec_err=0x1000000`
     - `w4 fio debug: bs_data=0x0 bus_busy=0x4`
   - Reproduced across:
     - `sizeimage=4MiB` (ring `0xA00000`)
     - `sizeimage=1MiB` (ring `0x400000`)
     - `sizeimage=128KiB` (ring `0x100000`)
   - Endian/payload A/B (`w4_bs_endian` / `w4_bs_data_swap`) also did not change the failure class.

2. `w4_dma_mask_bits` A/B:
   - `31` and `30` are rejected by `dma_set_mask_and_coherent()` on this platform (`-5`), fallback remains `32-bit`.
   - So low-address-band forcing via DMA mask is currently unavailable.

3. `w4_use_reserved_mem=0` (CMA/system allocator):
   - `VIDIOC_STREAMON` returns `-ENOMEM` before decode starts.
   - No `init-seq` logs are produced on this path.
   - Teardown shows `wave5_vdi_free_dma_memory: requested free of unmapped buffer` (allocation failure cleanup path).

### New platform clue and applied DTS update

- BSP vendor driver (`cvi_vcodec.c`) reserves VPU memory at:
  - base `0x86c00000`
  - size `62 MiB` (`0x03e00000`)
- Our DT carveout had been:
  - base `0x8c000000`
  - size `32 MiB`

Patch applied:

- `arch/riscv/boot/dts/sophgo/sg2002-milkv-duo256m.dts`
  - `vpu_reserved` moved to `<0x86c00000 0x03e00000>`

Build/deploy:

- Rebuilt DTB: `out-sg2002-milkv/.../sg2002-milkv-duo256m.dtb`
- Deployed to active boot entry DTB:
  - `/boot/sg2002-milkv-duo256m-wave4-stableport.dtb`
  - backup created beside it.

Next check after reboot:

1. Confirm active DTB exposes `memory-region` with base `0x86c00000`.
2. Re-run baseline decode (`w4_use_reserved_mem=1`, `w4_bs_endian=15`, `w4_bs_data_swap=0`).
3. Compare whether `INIT_SEQ` still returns `fail_reason=0x1 / dec_err=0x1000000`.

## Post-reboot finding and DTS correction (2026-03-31)

Observed on target after reboot with the `0x86c00000/62MiB` DT:

- `/proc/device-tree/reserved-memory/region@86c00000` exists with:
  - `compatible = "shared-dma-pool"`
  - `reusable`
  - `reg = <0x86c00000 0x03e00000>`
- Probe with `w4_use_reserved_mem=1` fails at:
  - `of_reserved_mem_device_init()` -> `failed to attach memory-region (-22)`
- Runtime memory summary shows:
  - `CmaTotal: 0 kB`
  - `CmaFree: 0 kB`

Root cause:

- On this kernel branch, `shared-dma-pool + reusable` routes through CMA init.
- The BSP window (`0x86c00000`, `62MiB`) is rejected as a CMA area here, so no device ops are attached and `of_reserved_mem_device_init()` returns `-EINVAL`.

Corrective patch applied:

- `arch/riscv/boot/dts/sophgo/sg2002-milkv-duo256m.dts`
  - keep base/size at BSP window (`0x86c00000`, `0x03e00000`)
  - switch node from reusable CMA pool to non-reusable coherent pool:
    - remove `reusable`
    - add `no-map`

Rebuild/deploy:

- Rebuilt `sophgo/sg2002-milkv-duo256m.dtb` in `out-sg2002-milkv`.
- Deployed to `/boot/sg2002-milkv-duo256m-wave4-stableport.dtb` with backup:
  - `/boot/sg2002-milkv-duo256m-wave4-stableport.dtb.bak-20260331-0015`

Next run after reboot:

1. Verify module probe shows `attached memory-region DMA pool for wave4 allocations`.
2. Run baseline decode with `w4_use_reserved_mem=1`.
3. Compare init-seq signature against prior failure (`fail_reason=0x1`, `dec_err=0x1000000`, `bs_data=0x0`).

## BSP fail-reason map (2026-03-31)

Reference files checked:

- BSP header: `duo-buildroot-sdk-v2/osdrv/interdrv/cvi_vc_drv/vcodec/vpuapi/vpuerror.h`
- BSP decode seq/result paths:
  - `.../wave/wave4/wave4.c:535-543` (`W4_RET_SUCCESS==0` handling in seq-info path)
  - `.../wave/wave4/wave4.c:336-343` (decode-result failure path)

Confirmed meanings for current observed values:

- `W4_RET_FAIL_REASON = 0x00000001` maps to `WAVE4_CODEC_ERROR` (Wave4), not Wave5 queueing-fail semantics.
- In BSP INIT_SEQ handling, when `W4_RET_FAIL_REASON == WAVE4_CODEC_ERROR`, driver reads `W4_RET_DEC_ERR_INFO` and uses that as sequence error reason.
- `W4_RET_DEC_ERR_INFO = 0x01000000` in INIT_SEQ context maps to `WAVE4_SPSERR_NOT_FOUND` ("NO SEQUENCE INFORMATION" section).

Context note:

- `0x01000000` is also reused in Wave4 DEC_PIC ETC section (`WAVE4_ETCERR_NEXT_AU_SLICE`), so command context matters.
- For INIT_SEQ (`DEC_PIC_HDR`) failures, BSP intent is SPS-not-found interpretation.

Porting implication:

- Any Wave420L path that treats `fail_reason==0x1` as `WAVE5_SYSERR_QUEUEING_FAIL` is semantically wrong for this product and can trigger incorrect retry/queue logic on codec parse errors.

### Negative map for current signature (`fail_reason=0x1`, `dec_err=0x01000000`)

What this does **not** map to in Wave4 (BSP constants):

- Not `WAVE4_SYSERR_BUS_ERROR` (`0x00000200`)
- Not `WAVE4_SYSERR_DOUBLE_FAULT` (`0x00000400`)
- Not `WAVE4_SYSERR_ACCESS_VIOLATION_HW` (`0x00001000`)
- Not `WAVE4_SYSERR_WRITEPROTECTION` (`0x00004000`)
- Not `WAVE4_SYSERR_WATCHDOG_TIMEOUT` (`0x00008000`)
- Not `WAVE4_ETCERR_PPS_NOT_FOUND` (`0x08000000`)
- Not `WAVE4_ETCERR_SPS_NOT_FOUND` (`0x10000000`) (DEC_PIC ETC class, different value/order of magnitude)
- Not `WAVE4_ETCERR_LACK_OF_STREAM` (`0x40000000`)

What this does **not** map to in upstream Wave5 tables:

- Not `WAVE5_SYSERR_ACCESS_VIOLATION_HW` (`0x00000040`)
- Not `WAVE5_SYSERR_BUS_ERROR` (`0x00000200`)
- Not `WAVE5_SYSERR_DOUBLE_FAULT` (`0x00000400`)
- Not `WAVE5_SYSERR_VPU_STILL_RUNNING` (`0x00001000`)
- Not `HEVC_ETCERR_INIT_SEQ_SPS_NOT_FOUND` (`0x00005000`)
- Not `AVC_ETCERR_INIT_SEQ_SPS_NOT_FOUND` (`0x00005000`)

Operational interpretation:

- The repeated signature is a codec-parser class failure at INIT_SEQ, not a hardware bus/watchdog/access fault signature.

## Candidate 1 check result (2026-03-31)

Scope:

- Remove Wave5-specific fail-reason assumptions from Wave420L decode/close paths:
  - do not treat `fail_reason=0x1` as queueing-retry condition in decode worker.
  - gate `WAVE5_SYSERR_VPU_STILL_RUNNING` (`0x1000`) busy handling away from Wave4 product.

Runtime:

- Module rebuilt and deployed (`wave4.ko`).
- Test cases run on target:
  - `cand1-failreason-girlshy`
  - `cand1-failreason-girlshy-r2`
  - `cand1-failreason-girlshy-r3`
- All runs keep the same init failure signature:
  - `fail_reason=0x1`
  - `dec_err=0x1000000`
  - output size `0`
- No kernel Oops/list_del/scheduling-while-atomic signatures observed in pulled dmesg for these runs.

Conclusion:

- Candidate 1 does not fix decode bring-up (INIT_SEQ still fails).
- It does improve failure-path semantics/stability by avoiding Wave5-misinterpreted retry/busy behavior on Wave420L.

## Candidate 3 follow-up patch (2026-03-31, pending target verification)

Rationale:

- BSP allocates decoder WORK and bitstream ring through VDI DMA allocations.
- Current port still had a fixed-layout A/B path mapping both into `common_mem` offsets.

Local changes prepared:

- `wave5-hw.c`
  - decoder WORK buffer allocation switched from fixed common-layout slice to dedicated DMA allocation (`wave5_vdi_allocate_dma_memory` + clear).
- `wave5-vpu-dec.c`
  - decoder bitstream ring allocation switched from fixed common-layout slice to dedicated DMA allocation (`wave5_vdi_allocate_dma_memory` + clear).
- `wave5-vdi.c`
  - `common_mem.size` reduced back to `W4_SIZE_COMMON` (code + temp), removing dependency on oversized fixed-layout common buffer.

Status:

- Module rebuild succeeded locally.
- Deployment/test blocked temporarily by target network loss (`ssh: No route to host` to `192.168.45.130`).
- Next immediate step after reconnect: deploy `wave4.ko`, rerun baseline HEVC case, compare `fail_reason/dec_err` and crash behavior.

## Post-reboot checks (2026-03-31, later)

### Baseline re-check with current tree

- Case: `postreboot-baseline-girlshy`
- Result unchanged:
  - `fail_reason=0x1`
  - `dec_err=0x1000000`
  - output size `0`
- Probe confirms reserved pool attach is active:
  - `assigned reserved memory node region@86c00000`
  - `attached memory-region DMA pool for wave4 allocations`

### INIT_SEQ full register dump

- Enabled `w4_init_seq_dump_regs=1` and captured pre/fail snapshots.
- Key values are internally consistent:
  - pre: `bs_start=0x86e00000`, `bs_wr=0x86e0c484`
  - fail: `bs_rd=0x100000` (advanced to ring end)
  - work/temp/user fields are programmed and non-garbage.
- A 200-byte head-only stream containing VPS/SPS/PPS still fails with the same signature:
  - `bs_wr=0x86e000c8`
  - `fail_reason=0x1`, `dec_err=0x1000000`
- Interpretation: failure is not tied to first-chunk size; parser still behaves as if SPS is not visible.

### Sec-AXI parity retest

- Restored BSP-style sec-axi programming (removed temporary force-off path).
- Runtime confirms:
  - `sec_axi[use=0x8201 size=0x19400]` on INIT_SEQ
- Outcome unchanged (`fail_reason=0x1`, `dec_err=0x1000000`).

### Next candidate prepared (pending board reconnect)

- Address-domain probe patch built locally:
  - Bitstream register addresses are now programmed with low 31-bit form (`addr & 0x7fffffff`) via `wave4_bs_addr()`.
- Purpose:
  - Directly test whether Wave420L parser path expects low-domain translated bus addresses while host allocations are in `0x8xxxxxxx`.
- Runtime test is pending because target became unreachable (`No route to host`).

## Candidate result: low31 BS register addressing (2026-03-31)

Change tested:

- Programmed bitstream register addresses via low 31-bit form (`addr & 0x7fffffff`) for:
  - `W4_BS_START_ADDR`
  - `W4_BS_RD_PTR`
  - `W4_BS_WR_PTR`

Observed runtime:

- `w4 init-seq pre` confirms the patch was active:
  - `bs[start=0x06e00000 ... wr=0x06e0c484]` (was `0x86e00000` domain before).
- Failure class unchanged:
  - `fail_reason=0x1`
  - `dec_err=0x1000000`
  - `w4 fio debug: bs_data=0x0 bus_busy=0x4`
  - output size `0`

Conclusion:

- Address low31 translation for BS registers alone does **not** fix INIT_SEQ parsing.
- Patch was reverted after the A/B run to keep baseline behavior.

## Control sweep status (2026-03-31, latest)

- Began `w4_vc_ctrl40` sweep (`ctrl40=0` first) on reverted baseline.
- Target lost SSH reachability during the first run (timeout / no route), so the case did not complete and no result is recorded yet.
- Test scripts were updated to fail fast on link drops:
  - `scripts/w4_run_case.sh`
  - `scripts/w4_deploy_module.sh`
  - default SSH options now include `ConnectTimeout=5`, `ServerAliveInterval=5`, `ServerAliveCountMax=2`.

## Follow-up controls (2026-03-31, 04:49~05:01)

### BS pointer domain restore (absolute) re-check

- Reverted temporary RD/WR offset write and restored absolute BS pointer register programming.
- Baseline rerun (`cont-abs-bs-ptr-girlshy-r1`) remains unchanged:
  - `fail_reason=0x1`
  - `dec_err=0x1000000`
  - output size `0`

### Error-bank reliability control

- Reran minimal-stream controls while logging both banks:
  - `cont-abs-bs-ptr-girlshy90-r1` (VPS+SPS+PPS)
  - `cont-probe-vps-sps-only-r1` (no PPS NAL)
  - `cont-probe-pps-only-r1`
- All three still report:
  - `err_w4=0x1000000`
  - `err_w5=0x2000`
- Since `err_w5=0x2000` persists even when PPS is absent, Wave5 error-bank value is not trustworthy as a Wave420L semantic signal.
- Working rule updated: treat `W4_RET_FAIL_REASON` + `W4_RET_DEC_ERR_INFO` as authoritative; use `W5_RET_DEC_ERR_INFO` only as non-authoritative debug noise.

### Stale-VINT-before-INIT_SEQ candidate

- A/B patch tested: explicit stale VINT clear immediately before issuing INIT_SEQ.
- Outcome unchanged (`fail_reason=0x1`, `dec_err=0x1000000`), so the patch was dropped and source reverted.

## 2026-03-31 ongoing controls (post-reboot continuation)

### Added BSP-style decoder probe dump on INIT_SEQ fail

- Added `CDBG_INFO_CONTROL/DATA/READY` probes (`0x8074/0x8078/0x807c`) in `wave5-hw.c`.
- Captured indexes:
  - SDMA: `0x120,0x121,0x122,0x123,0x124,0x126,0x127,0x129,0x130`
  - GDI: `0x13b,0x13c`
  - SHU: `0x143,0x14c,0x14d`
- Result on every INIT_SEQ failure:
  - all probed values are `0x0`
  - `w4 fio debug` remains `bs_data=0x0 bus_busy=0x4`
  - failure signature unchanged (`fail_reason=0x1`, `dec_err=0x1000000`)

### Sec-AXI off control (re-validated)

- Case: `cont-dbgprobe-secoff-girlshy-r1` (`w4_dec_sec_axi_mask=0`)
- INIT_SEQ pre/fail and error signature are unchanged versus baseline.
- Conclusion: sec-axi enable bits are not the blocking factor for current failure.

### Reserved-memory off + low31 controls

- `w4_use_reserved_mem=0`:
  - case `cont-dbgprobe-norsv-girlshy-r1`
  - same failure signature and same all-zero probe dump.
- `w4_use_reserved_mem=0 + w4_addr_low31=1`:
  - case `cont-dbgprobe-low31-norsv-girlshy-r1`
  - same failure signature and same all-zero probe dump.
- Conclusion: current INIT_SEQ failure is not specific to reserved-memory attach or high-address form.

### “More initial data before INIT_SEQ” control

- Valid larger feed case: `cont-bigfeed-girlshyx20-r2` (`girlshy.h265` repeated x20).
- First queued write became much larger (`bs_wr=...1fa40`) before INIT_SEQ.
- Signature still unchanged:
  - `fail_reason=0x1`
  - `dec_err=0x1000000`
  - all probe indexes remain `0x0`.
- Conclusion: under-fed first chunk is ruled out.

### H.264 control path note

- Case: `cont-dbgprobe-h264-r1`
- Fails earlier at `CREATE_INSTANCE` with `fail=0x1` and `inst=0x100000` (codec-mode field = AVC path).
- This is consistent with Wave420L HEVC-focused behavior and does not explain HEVC INIT_SEQ failure.

### DRAM remap write-path hardening

- Removed direct fallback writes to:
  - VC addr-remap window (`0x0B050000 + 0x64`)
  - legacy raw register (`0x03000064`)
- Kept only syscon-based remap programming attempt.
- Purpose: avoid writing uncertain fallback paths that read back non-sane values.
- Runtime with this change: failure signature still unchanged.

### SDK-v2 constant parity test (code/temp sizes)

- Aligned local constants to Duo SDK-v2 values:
  - `W4_MAX_CODE_BUF_SIZE = 256KiB`
  - `W4_TEMPBUF_SIZE = 512KiB`
- Case: `cont-bspcfg-codesz256-temp512-girlshy-r1`
- Registers confirm new layout (`temp_size=0x80000`, `bs_start=0x86e00000`).
- Failure signature remains unchanged.

### wait_interrupt stale-latch guard test

- Removed BUSY+RET short-circuit completion in `wave4_vpu_wait_interrupt()`
  to avoid false completion on stale `RET_FAIL`.
- Case: `cont-no-stalewait-girlshy-r1`
- No behavioral change: still `fail_reason=0x1`, `dec_err=0x1000000`.

### Current state after these controls

- Newly ruled out in this round:
  - sec-axi enable path
  - reserved-memory attach path
  - low31 address programming
  - first-chunk underfeed
  - stale wait-interrupt completion
  - code/temp size mismatch vs SDK-v2
- Remaining strong observation:
  - firmware reaches command path (`bit_pc` changes across runs),
    but parser-side debug probes stay all zero and INIT_SEQ ends with the same codec error class.

## 2026-03-31 continuation (07:05~07:15)

### Source cleanup completed

- Removed the old BS pointer offset mode from source:
  - no `w4_bs_ptr_as_offset` module parameter in driver code
  - BS RD/WR programming is now absolute-only in `wave5-hw.c`
- Fresh baseline (`cont-absbs-cleanup-girlshy-r1`) remains unchanged:
  - `fail_reason=0x1`
  - `dec_err=0x1000000`

### Clock/reset gating control (SAIF force)

- Case: `cont-saif-force-girlshy-r1` with `w4_force_saif_enable=1`
- Result: unchanged failure signature (`fail_reason=0x1`, `dec_err=0x1000000`, output size `0`).
- Probe log:
  - `SAIF force: clk[axi=0x0 bpu=0x0 vce=0x0 apb=0x0 noc=0x0] ...`
- Interpretation:
  - this forced write path did not improve decode init on current board/kernel.

### Interrupt completion sanity check (stale-VINT hypothesis)

- Added temporary wait-completion trace and ran `cont-vinttrace-girlshy-r1`.
- Captured:
  - `cmd=0x2`
  - `vint_sts=0x1`
  - `vint_reason=0x2`
  - `vint_reason_usr=0x2`
  - `ret_success=0x0`
  - `ret_fail=0x1`
- This confirms INIT_SEQ is completing with a real DEC_PIC_HDR interrupt, then returning codec failure.
- Conclusion:
  - stale/unrelated interrupt completion is ruled out.
  - The failure is genuine firmware-side INIT_SEQ parse failure in current configuration.

### Clock tree cross-check on live target

- Checked `/sys/kernel/debug/clk/clk_summary` during module load.
- All expected VPU clocks are enabled and attached to `video-codec@b020000`:
  - `clk_axi_video_codec`, `clk_h264c`, `clk_apb_h264c`
  - `clk_h265c`, `clk_apb_h265c`
  - `clk_vc_src0`, `clk_vc_src1`, `clk_vc_src2`
  - `clk_cfg_reg_vc`
- So missing clock acquisition is unlikely to be the blocker.

### Fixed-layout address control (work lower, ring moved) 

- Ran an additional fixed common-layout control to shift decode WORK lower while keeping BSP command flow:
  - `work[base=0x86d00000 size=0x300000]`
  - `bs[start=0x87000000 size=0x100000]`
  - case: `cont-layout-work1m-bs4m-girlshy-r1` (`w4_common_layout_mode=1`, `w4_init_seq_dump_regs=1`)
- Failure signature remained identical:
  - `fail_reason=0x1`
  - `dec_err=0x1000000`
  - `bs_rd=0x100000`
  - ring head bytes still valid VPS/SPS prefix.
- This reduces the likelihood that only the prior high WORK address (`0x87000000` in default allocator runs) was the root cause.

## 2026-03-31 continuation (12:46~12:52)

### Runtime bitstream-window sweep (no reboot)

New runtime knobs added:

- `w4_common_work_offset_mb`
- `w4_common_bs_offset_mb`
- `w4_common_bs_size_mb`

These are used when `w4_common_layout_mode=1` and allow address-window sweeps without source edits/rebuilds per point.

Sweep setup (fixed):

- `w4_common_layout_mode=1`
- `w4_common_work_offset_mb=4`
- `w4_common_bs_size_mb=1`
- `w4_init_seq_dump_regs=1`
- input: `girlshy.h265`

Helper script:

- `drivers/media/platform/chips-media/wave4/scripts/w4_bs_window_sweep.sh`
  - runs the above offset matrix sequentially and prints one-line result per case.

Sweep results:

- `bs_offset=8MiB` (`bs_start=0x87400000`): same fail (`0x1 / 0x1000000`)
- `bs_offset=12MiB` (`bs_start=0x87800000`): same fail
- `bs_offset=16MiB` (`bs_start=0x87c00000`): same fail
- `bs_offset=20MiB` (`bs_start=0x88000000`): same fail
- `bs_offset=24MiB` (`bs_start=0x88400000`): same fail
- `bs_offset=26MiB` (`bs_start=0x88600000`): same fail
- `bs_offset=27MiB` (`bs_start=0x88700000`): same fail

High-offset allocation ceiling observed:

- `bs_offset=28MiB` and `40MiB` failed at probe with:
  - `unable to allocate common buffer`
  - `wave4_vdi_init, fail: -12`
- This is a memory-allocation limit in current reserved-pool path for enlarged common buffer size, not a decode semantic change.

Conclusion from sweep:

- Across all successful allocation points (`0x87400000` .. `0x88700000`), INIT_SEQ failure class is invariant:
  - `fail_reason=0x1`
  - `dec_err=0x1000000`
  - `bs_rd=0x100000`
- So the issue is not tied to one narrow BS physical window within that tested range.

Additional controls on top of sweep:

- `w4_addr_low31=1` at `bs_offset=27MiB` (`bs_start=0x08700000` in regs):
  - same failure class (`0x1 / 0x1000000`).
- `w4_allow_resident_fw_fallback=0` at `bs_offset=27MiB`:
  - same failure class, no decode output.

### VC SBM map override controls

Added runtime knobs in probe path:

- `w4_sbm_map_enable`
- `w4_sbm_map_base`
- `w4_sbm_map_step`

Control A:

- `w4_sbm_map_enable=1`
- `w4_sbm_map_base=0x86c00000`
- `w4_sbm_map_step=0x00100000`
- Observed readback mixed high-bit domains in map entries and no decode improvement.

Control B (explicit low31 map):

- `w4_sbm_map_enable=1`
- `w4_sbm_map_base=0x06c00000`
- `w4_sbm_map_step=0x00100000`
- Readback map became fully low31 linear (`0x06c00000`..`0x07b00000`) as expected.
- INIT_SEQ failure class remained unchanged (`fail_reason=0x1`, `dec_err=0x1000000`).

Combined control:

- `w4_sbm_map_enable=1` (low31 map) + `w4_addr_low31=1`
- INIT_SEQ still fails with the same class (`0x1 / 0x1000000`), now with low31 BS registers (`bs_start=0x06e00000`).

## 2026-03-31 continuation (13:56~13:58)

### BSP temp/code window parity (1MiB/1MiB)

- Updated local constants to match Wave420L BSP common layout:
  - `W4_MAX_CODE_BUF_SIZE = 1024*1024`
  - `W4_TEMPBUF_SIZE = 1024*1024`
- Case: `cont-codesz1m-temp1m-dump-girlshy-r1`
- Verified runtime register programming reflects the new layout:
  - `temp[base=0x86d00000 size=0x100000]`
  - `bs[start=0x86f00000 size=0x100000]`
- Result unchanged:
  - `fail_reason=0x1`
  - `dec_err=0x1000000`
  - `bs_rd=0x100000`
  - output size `0`

### Sec-AXI off re-check on top of 1MiB/1MiB layout

- Case: `cont-codesz1m-temp1m-secaxi0-girlshy-r1`
- Confirmed `sec_axi[use=0x0 addr=0x0 size=0x0]` in init-seq pre/fail dumps.
- INIT_SEQ failure class is still identical (`0x1 / 0x1000000`).

### New remap control hook prepared (pending target reconnect)

- Re-added test-only module parameter:
  - `w4_vc_remap64` (default `-1`)
  - When set, writes `0x0B050064` and logs readback.
- Purpose:
  - run direct VC remap register A/B on this current codebase even when syscon readback stays `0x0`.
- Build is complete locally; deployment/test was attempted next but board went offline (`192.168.45.130` SSH timeout).

## 2026-03-31 continuation (15:15~15:20)

### Ruled-out low31/offset path removed from driver

- Removed runtime address-domain toggle `w4_addr_low31`.
- `wave4_cmd_addr()` is now always absolute 32-bit DMA address programming.
- Removed RD-pointer offset translation fallback in `wave4_dec_get_rd_ptr()`.
  - The driver now treats `W4_BS_RD_PTR` as an address value only.
- Rationale:
  - low31 and offset-interpretation controls were already ruled out by prior A/B runs,
    and keeping them increases ambiguity during failure triage.

### Next on reconnect (ordered)

1. Run `scripts/w4_remap64_ab.sh` (baseline vs `w4_vc_remap64=0x01000020`).
2. Compare only these deltas from logs:
   - `VC remap[0x64]` readback
   - INIT_SEQ class (`fail_reason`, `dec_err`)
   - `bs_rd` progression
3. If no delta, continue to non-remap candidate path (memory visibility/integration), not endian/low31.
