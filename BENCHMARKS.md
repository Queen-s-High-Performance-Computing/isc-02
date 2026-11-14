# Benchmarks

Log of every measured change. Official metric: `scripts/score.sh <demo> 120 3`
(valid demos in 120 s, median of 3 runs). Only trust differences larger than
the run-to-run spread.

**Machines**
- **Local (dev):** MacBook Air, Apple M3 (4 performance + 4 efficiency cores, 8 CPUs),
  macOS. Compiler: Homebrew **GCC 16.2** (`gcc-16`, picked automatically by the
  Makefile on macOS; plain `gcc` on macOS is Apple clang 21). Run with `SLURM_JOB_ID=local scripts/score.sh ...`
  (needs Homebrew `coreutils` + `util-linux` on PATH for `nproc`/`setsid`).
- **Target:** `frnt201`, 2x Intel Xeon Gold 6430 (64 cores / 128 threads), Linux, gcc.

Local numbers are for relative comparison only. They don't predict frnt201
scores: different ISA, compiler, core count, and the M3 mixes fast and slow cores.

## Results

| # | Date | Machine | Change | Demo | Runs | Score (median) | Per run | Notes |
|---|------|---------|--------|------|------|----------------|---------|-------|
| 0a | 2026-11-14 | Local M3 | Baseline, **Apple clang** (superseded by 0b): stock kit, `-Os`, 1 copy per CPU (8) | demo1 | 120 s x 3 | **216** | 216 / 216 / 216 | 0 invalid. ~4.3 s per demo per copy under full load (vs 3.3 s playing back alone). |
| 0b | 2026-11-14 | Local M3 | **Baseline, GCC 16.2**: stock kit, `-Os`, 1 copy per CPU (8) | demo1 | 120 s x 3 | **176** | 179 / 176 / 169 | 0 invalid. ~19% below clang (216). Spread 10 (~6%): only trust changes bigger than that. **Reference for all later rows.** |
| 1 | 2026-11-14 | Local M3 | Melt advances 1 step per frame without sleeping in `-timedemo` (`d_main.c`, `D_Display`) | demo1 | 120 s x 3 | **192** | 208 / 192 / 190 | 0 invalid. +16 (+9%) over 0b. Every run beat every 0b run, but the gain is far below the ~1 s/demo single-copy saving (predicted ~230). See notes below. |

### Notes on row 1
- Per demo per copy under load: 5.5 s → 5.0 s, so only ~0.45 s saved, against ~1.1 s on a single copy.
- Likely cause: the M3 has 4 fast + 4 slow cores. While a copy slept in the melt, macOS let
  a copy from a slow core run on the freed fast core, so some of the "idle" time was
  already being used. Sustained full load also heats the fanless Air: the first run is
  the highest in every set, so later runs are throttled.
- Lesson: on this laptop, single-copy timings overstate gains under full load. Trust the
  official runs, and treat local numbers as relative only.

| # | Date | Machine | Change | Demo | Runs | Score (median) | Per run | Notes |
|---|------|---------|--------|------|------|----------------|---------|-------|
| 2 | 2026-11-14 | Local M3 | #1 + `cmap_to_fb` fast path (`i_video.c`): 32-bit palette table, one 64-bit store per source pixel, row copy | demo1 | 120 s x 3 | **616** | 671 / 616 / 590 | 0 invalid. **3.2x over row 1, 3.5x over the GCC baseline (176).** |

### Notes on row 2
- Per demo per copy under load: 120 / (616/8) ≈ 1.56 s, against 0.78 s on a single copy:
  a ~2x slowdown under load, up from ~1.3x for earlier builds. Each copy now writes
  ~9 GB/s of framebuffer, so shared memory bandwidth, the slow efficiency cores and
  heat matter much more.
- Clear thermal decline across the set (671 → 590, −12%). Local spread is now ~80 demos.

## Profile: baseline build, Apple clang `-Os` (local M3, `scripts/profile_mac.sh`)

One copy of demo1 alone, macOS `sample` at 1 ms, first 2.5 s of a 3.55 s run
(1342 samples). demo2 and demo3 look the same.

| Where | Samples | Share | What it is |
|-------|---------|-------|------------|
| `usleep` from `D_Display` wipe loop (`d_main.c:319`) | 557 | ~41% | Screen melt at demo start waits on the real-time clock (35 Hz). **Idle, not CPU.** ~1 s per demo. |
| `cmap_to_fb` (`i_video.c`) | ~540 | ~40% | Palette → 32-bit RGBA, 2x upscale to 640x400, every frame. Per-pixel branch on bpp + inner scaling loop. |
| `R_RenderPlayerView` (actual 3D rendering) | ~200 | ~15% | R_DrawColumn, R_DrawSpan, R_RenderSegLoop, ... |
| Game logic, start-up, everything else | rest | ~5% | |

## Profile: baseline build, GCC 16.2 `-Os` (local M3)

Same method (first 2.5 s of each run, ~1330 samples, ~1.9 ms per sample).
The window always contains the whole start-of-demo melt, so the sleep's share
of the *window* is higher than its share of the whole demo.

| demo | wall | `cmap_to_fb` | melt sleep | everything else |
|------|------|--------------|------------|-----------------|
| demo1 | 4.04 s | 635 (clang: 541) | 523 (clang: 557) | ~185 |
| demo2 | 3.99 s | 610 (clang: 601) | 539 (clang: 542) | ~170 |
| demo3 | 3.74 s | 591 (clang: 521) | 519 (clang: 507) | ~210 |

- The melt sleep stays at ~1.0 s whatever the compiler (it follows the wall clock).
- Most of GCC's extra time is in `cmap_to_fb`: ~77% of CPU (non-sleep) samples, against ~69% with clang.
- Estimated whole-demo split (demo1, gcc): `cmap_to_fb` ~2.2 s (~55%), melt ~1.0 s (~25%),
  3D rendering + game logic ~0.65 s (~15%), start-up/exit ~0.2 s (~5%).

## Profile: change #1, melt without sleep, GCC 16.2 `-Os` (local M3)

First 2.0 s of each run (~1700 samples). The melt sleep (`__semwait_signal`) is gone.

| demo | wall | total | `cmap_to_fb` | `R_DrawColumn` | `R_DrawSpan` | other |
|------|------|-------|--------------|----------------|--------------|-------|
| demo1 | 2.94 s | 1677 | 1266 (75%) | 109 | 37 | ~265 |
| demo2 | 2.82 s | 1708 | 1312 (77%) | 93 | 54 | ~250 |

`cmap_to_fb` is now about three quarters of all time: next target.

## Change #2: `cmap_to_fb` fast path (local M3, GCC 16.2 `-Os`)

`i_video.c`: 256-entry 32-bit palette table, rebuilt on palette change; for the
32 bpp / 2x / 640x400 case, one lookup and one 64-bit store per source pixel,
then the row is copied to the row below. The original loop is kept for other modes.
Output is bit-identical (same `matched` counts on all three demos).

Single copy, 3 repeats each (a first cold run of demo1 took 1.24 s, excluded):

| demo | melt fix only | + cmap fast path | Valid |
|------|---------------|------------------|-------|
| demo1 | 2.94–3.16 s | 0.77–0.79 s | 7115/7116 |
| demo2 | 2.75–2.82 s | 0.74–0.75 s | 7088/7088 |
| demo3 | 2.52 s | 0.80 s | 6041/6041 |

Start-up + exit is now only ~0.03–0.05 s per demo (wall minus Doom's own timer).
`sample` can't profile sub-second runs (only 1 sample), so a different profiler is needed from here on.

## Single-copy reference timings (local, baseline `-Os`, one process alone)

Single runs, so expect some noise.

| Demo | Tics | clang wall | gcc-16 wall | Valid (both) |
|------|------|------------|-------------|--------------|
| demo1 | 7116 | 3.57 s | 4.47 s | 7115/7116 matched |
| demo2 | 7088 | 3.28 s | 3.93 s | 7088/7088 matched |
| demo3 | 6041 | 3.16 s | 3.73 s | 6041/6041 matched |
