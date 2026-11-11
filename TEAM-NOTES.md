# Team notes: optimization log

Draft material for the README section the rules ask for. Numbers so far were
measured off-cluster (2-CPU Intel Sapphire Rapids VM, same CPU generation as
frnt201's Xeon Gold 6430). **Re-measure everything on frnt201 before quoting it.**

## Results so far (off-cluster, 2 CPUs, `scripts/score.sh <demo> 30 1`)

| Build | demo1 | demo2 | demo3 |
|---|---|---|---|
| Original kit (`-Os`, restart per demo) | 8 | 8 | 9 |
| This branch (defaults) | 36 | 37 | 34 |

All runs: 0 invalid demos. Single demo1 playback: 5.6 s → ~1.45 s.

## What changed and why

| # | Change | Files | Effect (demo1, 1 copy) |
|---|---|---|---|
| 1 | Screen-melt transition no longer sleeps on the wall clock. Every melt step is still drawn; all of them belong to one game tic, so only the final frame is fingerprinted, as in the original. | `d_main.c` | 5.6 s → 4.5 s (≈1.1 s of each demo was `usleep`) |
| 2 | Frame-buffer conversion rewritten. gprof showed `cmap_to_fb` at 70% of CPU: a per-pixel branch on bits-per-pixel and reloads of `s_Fb` on every store (char-pointer aliasing). Now: 32-bit palette built once per palette change, each pixel written as a 64-bit pair, finished row copied to the row below. Output is bit-identical; the full 640×400 image is still written every frame. | `i_video.c` | 3.6 s → 1.7 s (at `-O2`) |
| 3 | `-Os` → `-O3 -march=native` (`OPT=` overrides it). | `Makefile` | ~5–10%, within noise off-cluster |
| 4 | 2 MB-aligned frame buffer and zone memory with `MADV_HUGEPAGE` (fewer TLB misses on the 1 MB buffer rewritten every frame). | `doomgeneric.c`, `i_system.c` | not measurable off-cluster; harmless |
| 5 | Game data loaded once per copy. `-demofork` (default): load, then fork a fresh child per demo, so each child starts from untouched pre-demo state and its frames are bit-identical to a fresh process. `-demoloop`: replay inside one process (resets tic counters, D_Display state, status-bar face state and the spectre fuzz position). | `d_main.c`, `d_loop.[ch]`, `g_game.c`, `st_stuff.[ch]` | ~2% off-cluster (start-up is ~15–25 ms); likely more on the cluster's shared filesystem |
| 6 | `run.sh`: one copy per allowed CPU, physical cores first then hyperthread siblings, each pinned with `taskset`. `COPIES`, `MODE`, `PIN` knobs for tuning. | `scripts/run.sh` | to measure on frnt201 |

### Validity notes
- `-demofork`: matched = 7115 / 7088 / 6041 on every run (same as a fresh process).
- `-demoloop`: valid, but repeats lose 1–3 frames (demo1 7113–7115, demo2 7087,
  demo3 6040). That's vanilla Doom reading a byte or two past a graphic, which
  depends on leftover heap memory. It's inside the 5-frame allowance but uses
  some of it, which is why fork is the default.

## frnt201 results (2026-11-09, 16 CPUs = 8 cores x 2 threads, `score.sh <demo> 30 1`)

Raw output: `benchmarks/frnt201-2026-11-09.txt`. Every run 0 invalid.

| Demo | Stock (3 runs) | Optimized (3 runs) | Median | Speedup |
|---|---|---|---|---|
| demo1 | 64, 64, 64 | 214, 220, 224 | 220 | 3.4x |
| demo2 | 64, 64, 64 | 233, 235, 231 | 233 | 3.6x |
| demo3 | 64, 64, 65 | 217, 215, 215 | 215 | 3.4x |

Run-to-run spread: about +/-2%. (That build predates the `restrict` change below.)

### Projecting to the full node (120 s, 128 CPUs)
Scaling the 30 s score by 32 slightly undercounts, because each copy loses
about half a demo when the timer stops, and that loss is the same in a 30 s
and a 120 s run. Per copy:

    t      = seconds per demo = 30 / (score/16 + 0.5)
    score  = 128 x (120 / t - 0.5)

demo1: t = 2.10 s -> about 7,230. demo2: t = 1.99 s -> about 7,640.
demo3: t = 2.15 s -> about 7,080. Stock: about 2,100.

This assumes each core stays as fast with all 64 cores busy as it was with 8.
It won't fully hold: all-core turbo is lower, and 128 copies share two 60 MB L3
caches and memory bandwidth across two sockets. The `copies` sweep measures
per-copy speed at 1-16 copies; if it drops as copies rise, extend that trend
to 128 instead of assuming it stays flat. Only a full-node run gives the real
number.

## Round 2 experiments (off-cluster, CPU time, best of 5, all valid)

| Change | Result | Kept? |
|---|---|---|
| `restrict` locals in `R_DrawColumn` / `R_DrawSpan`: the byte store forced `dc_source`/`dc_colormap` (and `ds_*`) to be reloaded every pixel; now kept in registers (checked in the disassembly) | about 2% faster on all three demos | yes |
| AVX-512 frame conversion (gather + permutes, store both rows) | same on demo1, 7% slower on demo3 | no |
| Scalar conversion writing both rows directly (no memcpy) | 5% slower | no |
| Convert a row into an L1 buffer, then memcpy to both rows | 3-10% slower | no |
| PGO (trained on demo1-3) | 3-5% faster on demo2/3, mixed on demo1 | not by default: needs committed profile data or a training run in `make`; ask organizers whether that counts as precomputing (rule 3) |

Current profile (all demos): R_DrawColumn 22%, frame conversion 14%,
R_DrawSpan 9%, R_RenderSegLoop 8%, R_DrawSprite 5%, DG_DrawFrame (validator,
fixed) 4%.

## Ideas considered and rejected (rules)
- `-nodraw`, lower resolution, skipping frames: breaks rule 2 (and fails validation).
- Other engines (FastDoom, Crispy, GZDoom): frames would not match `reference/`.
- Choosing short demos: the demo is fixed by the organizers.
- `setsid`/`nohup`/GNU parallel daemons: rule 5. Forked children stay in the
  process group, the parent waits for each one, and each child dies with its parent.
- Copying the WAD to `/dev/shm`: allowed in principle, but with fork mode the
  WAD is read once per copy, and files left in `/dev/shm` after the scorer's
  SIGKILL would clutter a shared node.

## To do on frnt201
1. `scripts/score.sh demo1 30 1` two or three times to get the baseline spread.
2. `scripts/sweep.sh flags demo1`: pick the compiler flags.
3. `scripts/sweep.sh copies demo1`: copies per core (hyperthreads on/off), mode, pinning.
4. Profile again (`OPTIMIZATION.md` §3); next hotspots: `R_DrawColumn`, `R_DrawSpan`,
   `R_RenderSegLoop`, the frame-buffer write.
5. Likely limit at full node: memory and cache traffic. Each copy writes a 1 MB
   frame ~5,000 times/s. Two copies per core share a 2 MB L2, so watch whether
   128 copies beat 64.

## AI tools
_(Required by RULES.md: state which AI tools you used, if any, and how. Write this yourself before tagging `final`.)_
